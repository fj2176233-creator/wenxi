// 共享账号池客户端：从 NAS 上的 cred-center 拉取网盘凭据。
//
// 服务端：/vol1/1000/nas/cred-center.py 的 GET /api/credentials?code=XXX
// 返回：{"ok": true, "accounts": [{"platform": "Quark", "label": "...",
//        "cookie": "...", "extra": "{\"k\":\"v\"}"}]}
//
// 设计约束：
// - 只用 dart:io 的 HttpClient，不新增依赖。
// - 任何异常都返回空列表，绝不让 NAS 失联拖住启动。
// - 凭据格式的最终判定复用 LoginCredentials.candidate()，与手动登录
//   走的同一套校验，避免各平台字段名写错。

import 'dart:convert';
import 'dart:io';

import '../domain/auth.dart';
import '../domain/models.dart';

/// 一条从云端取到的账号。
class SharedCredential {
  const SharedCredential({
    required this.platform,
    required this.credential,
    required this.plausible,
  });

  final CloudPlatform platform;

  /// 已经按平台整理好字段的凭据，可直接交给 Vault.putCredential。
  final Credential credential;

  /// 凭据格式是否通过了与手动登录相同的校验。
  /// false 时仍然写入，但要提示用户去 NAS 换一份正确的值。
  final bool plausible;
}

class CloudCredentialSource {
  CloudCredentialSource({
    required this.baseUrl,
    required this.code,
    this.timeout = const Duration(seconds: 12),
  });

  /// 形如 http://example.dynv6.net:5301，结尾斜杠会被忽略。
  final String baseUrl;
  final String code;
  final Duration timeout;

  bool get isConfigured => baseUrl.trim().isNotEmpty && code.trim().isNotEmpty;

  Uri get uri {
    final root = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse(
      '$root/api/credentials',
    ).replace(queryParameters: {'code': code.trim()});
  }

  /// 拉取账号。失败一律返回空列表，调用方不必 catch。
  Future<List<SharedCredential>> fetch() async {
    if (!isConfigured) return const [];
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return const [];
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['ok'] != true) return const [];
      final accounts = decoded['accounts'];
      if (accounts is! List) return const [];
      final result = <SharedCredential>[];
      for (final raw in accounts) {
        if (raw is! Map) continue;
        final parsed = _parse(raw);
        if (parsed != null) result.add(parsed);
      }
      return result;
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  SharedCredential? _parse(Map raw) {
    final platform = platformFromKey(
      raw['platform']?.toString() ?? raw['key']?.toString() ?? '',
    );
    if (platform == null) return null;
    final value = _rawValue(raw);
    if (value.isEmpty) return null;
    final label = raw['label']?.toString().trim() ?? '';
    final extra = _extraFields(raw['extra']);
    // 服务端存的是该平台的原始登录值（cookie / refresh_token /
    // authorization）。交给 candidate() 走与手动登录一致的解析与校验，
    // 它会补齐 authorization、accessToken、appId 这类派生字段。
    Credential? built;
    var plausible = false;
    try {
      final candidate = LoginCredentials.candidate(platform, value, null);
      plausible = LoginCredentials.plausible(platform, candidate.primary);
      built = Credential(
        label.isNotEmpty ? label : platform.label,
        {...candidate.fields, ...extra},
      );
    } catch (_) {
      built = null;
    }
    built ??= Credential(
      label.isNotEmpty ? label : platform.label,
      {...extra, 'primary': value},
    );
    return SharedCredential(
      platform: platform,
      credential: built,
      plausible: plausible,
    );
  }

  static String _rawValue(Map raw) {
    for (final key in [
      'cookie',
      'credential',
      'primary',
      'token',
      'authorization',
      'value',
    ]) {
      final text = raw[key]?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static Map<String, String> _extraFields(Object? extra) {
    if (extra == null) return const {};
    Object? value = extra;
    if (value is String) {
      if (value.trim().isEmpty) return const {};
      try {
        value = jsonDecode(value);
      } catch (_) {
        return const {};
      }
    }
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.value != null && '${entry.value}'.trim().isNotEmpty)
          '${entry.key}': '${entry.value}'.trim(),
    };
  }

  /// 服务端的 platform 字符串 -> CloudPlatform。
  /// 服务端存的是枚举 key（Pan115 / Baidu / Quark / Aliyun / C139），
  /// 与 CloudPlatform.key 完全一致；另外兼容 OpenList driver 名与中文名。
  static CloudPlatform? platformFromKey(String key) {
    final value = key.trim();
    if (value.isEmpty) return null;
    for (final platform in CloudPlatform.values) {
      if (platform.key.toLowerCase() == value.toLowerCase()) return platform;
    }
    const alias = {
      'baidunetdisk': 'Baidu',
      'baidu': 'Baidu',
      '115 cloud': 'Pan115',
      '115': 'Pan115',
      'aliyundriveopen': 'Aliyun',
      'aliyundrive': 'Aliyun',
      'ali': 'Aliyun',
      'yun139': 'C139',
      '139yun': 'C139',
      '139': 'C139',
      'quark': 'Quark',
    };
    final mapped = alias[value.toLowerCase()];
    if (mapped != null) {
      for (final platform in CloudPlatform.values) {
        if (platform.key.toLowerCase() == mapped.toLowerCase()) {
          return platform;
        }
      }
    }
    for (final platform in CloudPlatform.values) {
      if (platform.label == value || platform.shortName == value) {
        return platform;
      }
    }
    return null;
  }
}
