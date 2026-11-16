// 把共享账号池的凭据同步进本地 Vault。
//
// 关键设计（与"直接覆盖本地账号"的做法不同）：
// - 共享账号一律**单独建一条记录**，不碰用户或朋友自己登录的账号。
// - 平台当前没有任何账号时，共享账号会被激活，开箱即用。
// - 平台已有本地账号时只建不激活，朋友可在账号列表里手动切换。
// - 每个平台的共享账号 id 记在 store 里，下次同步原地更新而不是越建越多。
// - 拉不到就保持本地不动（离线可用）；失败原因留给设置界面显示。

import '../core/json.dart';
import '../domain/models.dart';
import 'cloud_credential_source.dart';
import 'state_store.dart';

/// 共享账号配置，持久化在 StateStore 顶层的 cloudShare 键下。
class CloudShareConfig {
  const CloudShareConfig({
    this.server = '',
    this.code = '',
    this.enabled = true,
    this.accounts = const {},
    this.lastSync = 0,
  });

  /// 账号池地址，形如 http://example.dynv6.net:5301
  final String server;

  /// 朋友自己的邀请码
  final String code;

  final bool enabled;

  /// platform.key -> 本地共享账号 id
  final Map<String, String> accounts;

  /// 上次成功同步的毫秒时间戳
  final int lastSync;

  bool get isConfigured => server.trim().isNotEmpty && code.trim().isNotEmpty;

  CloudShareConfig copyWith({
    String? server,
    String? code,
    bool? enabled,
    Map<String, String>? accounts,
    int? lastSync,
  }) => CloudShareConfig(
    server: server ?? this.server,
    code: code ?? this.code,
    enabled: enabled ?? this.enabled,
    accounts: accounts ?? this.accounts,
    lastSync: lastSync ?? this.lastSync,
  );

  Json toJson() => {
    'server': server,
    'code': code,
    'enabled': enabled,
    'accounts': accounts,
    'lastSync': lastSync,
  };

  factory CloudShareConfig.fromJson(Json j) => CloudShareConfig(
    server: j.str('server'),
    code: j.str('code'),
    enabled: j.boolean('enabled', true),
    accounts: strings(j['accounts']),
    lastSync: j.integer('lastSync'),
  );
}

/// 一次同步的结果，给界面显示用。
class CloudShareSyncResult {
  const CloudShareSyncResult({
    required this.updated,
    this.invalid = const [],
    this.error = '',
    this.notRequested = false,
  });

  const CloudShareSyncResult.notRequested()
    : updated = const [],
      invalid = const [],
      error = '',
      notRequested = true;

  final List<CloudPlatform> updated;

  /// 服务端给了值但格式没过校验的平台
  final List<CloudPlatform> invalid;

  final String error;
  final bool notRequested;

  bool get ok => error.isEmpty;
}

class CloudCredentialSync {
  CloudCredentialSync(
    this.store,
    this.vault, {
    DateTime Function()? clock,
    Duration minInterval = const Duration(minutes: 30),
  }) : _clock = clock ?? DateTime.now,
       _minInterval = minInterval;

  final StateStore store;
  final Vault vault;
  final DateTime Function() _clock;
  final Duration _minInterval;

  /// 冷启动的防抖窗口，只用来避开“连着被杀重开”这种抖动。
  static const _coldStartGrace = Duration(seconds: 60);

  /// 共享账号不能覆盖本地账号，标记只用来在界面上区分。
  static const storageKey = 'cloudShare';

  DateTime? _lastAttempt;
  CloudShareSyncResult _lastResult = const CloudShareSyncResult.notRequested();

  CloudShareSyncResult get lastResult => _lastResult;

  CloudShareConfig get config =>
      CloudShareConfig.fromJson(store.data.obj(storageKey));

  bool get isConfigured => config.isConfigured;

  /// 某个平台的共享账号 id（没有则 null）。
  String? sharedAccountId(CloudPlatform platform) =>
      config.accounts[platform.key];

  bool isShared(CloudPlatform platform, String accountId) =>
      config.accounts[platform.key] == accountId;

  Set<CloudPlatform> get sharedPlatforms => {
    for (final key in config.accounts.keys)
      for (final platform in CloudPlatform.values)
        if (platform.key == key) platform,
  };

  Future<void> configure({
    String? server,
    String? code,
    bool? enabled,
  }) => store.put(
    storageKey,
    config
        .copyWith(
          server: server?.trim(),
          code: code?.trim(),
          enabled: enabled,
        )
        .toJson(),
  );

  /// 启动时调用。未到间隔或未配置时直接返回，不发请求。
  ///
  /// 两个间隔是有意的：
  /// - 同一次运行内 30 分钟才重复拉一次；
  /// - 冷启动只避开 60 秒内的抖动，这样在 NAS 换了 cookie 之后，
  ///   朋友把 App 杀了重开就能立刻拿到新的，不用干等半小时。
  Future<CloudShareSyncResult> syncIfNeeded({bool force = false}) {
    final current = config;
    if (!current.enabled || !current.isConfigured) {
      return Future.value(const CloudShareSyncResult.notRequested());
    }
    final now = _clock();
    final last = _lastAttempt;
    if (!force && last != null) {
      if (now.difference(last) < _minInterval) {
        return Future.value(const CloudShareSyncResult.notRequested());
      }
    } else if (!force && current.lastSync > 0) {
      final previous = DateTime.fromMillisecondsSinceEpoch(current.lastSync);
      if (now.difference(previous) < _coldStartGrace) {
        return Future.value(const CloudShareSyncResult.notRequested());
      }
    }
    _lastAttempt = now;
    return sync();
  }

  /// 强制同步一次。任何失败都记在 lastResult 里，不抛。
  Future<CloudShareSyncResult> sync() async {
    final current = config;
    if (!current.isConfigured) {
      return _remember(
        const CloudShareSyncResult(
          updated: [],
          error: '未填写账号池地址或邀请码',
        ),
      );
    }
    final source = CloudCredentialSource(
      baseUrl: current.server,
      code: current.code,
    );
    final fetched = await source.fetch();
    if (fetched.isEmpty) {
      return _remember(
        const CloudShareSyncResult(
          updated: [],
          error: '账号池没有返回可用账号，检查地址、邀请码或 NAS 是否在线',
        ),
      );
    }
    final updated = <CloudPlatform>[];
    final invalid = <CloudPlatform>[];
    var accounts = Map<String, String>.from(current.accounts);
    for (final shared in fetched) {
      if (!shared.plausible) invalid.add(shared.platform);
      try {
        final applied = await _apply(shared, accounts[shared.platform.key]);
        if (applied != null) {
          accounts[shared.platform.key] = applied.id;
          updated.add(shared.platform);
        }
      } catch (_) {
        // 单个平台写失败不能影响其它平台
        invalid.add(shared.platform);
      }
    }
    await store.put(
      storageKey,
      current
          .copyWith(accounts: accounts, lastSync: _clock().millisecondsSinceEpoch)
          .toJson(),
    );
    return _remember(
      CloudShareSyncResult(updated: updated, invalid: invalid),
    );
  }

  /// 某个平台鉴权失败时调用，只刷新这一个平台。
  ///
  /// 返回 true 表示**确实写入了新凭据**，调用方可以重试一次；
  /// 账号池里的值没变时返回 false（否则重试会变成空转）。
  Future<bool> refreshOne(CloudPlatform platform) async {
    final current = config;
    if (!current.isConfigured) return false;
    final source = CloudCredentialSource(
      baseUrl: current.server,
      code: current.code,
    );
    final fetched = await source.fetch();
    for (final shared in fetched) {
      if (shared.platform != platform) continue;
      try {
        final applied = await _apply(shared, current.accounts[platform.key]);
        if (applied == null) return false;
        if (current.accounts[platform.key] != applied.id) {
          await store.put(
            storageKey,
            current
                .copyWith(
                  accounts: {...current.accounts, platform.key: applied.id},
                )
                .toJson(),
          );
        }
        // 值没变就没有“新的东西可以试”，返回 false 让上层别再来一轮，
        // 否则结合 refreshAccount 的 finally 会自己转圈。
        return applied.changed;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// 写入一个平台的共享账号。
  ///
  /// 返回 (id, changed)；账号池里的值和本地完全一致时 changed=false，
  /// 这时什么都不会写——否则每次同步都会产生新的 updatedAt，把上层
  /// 所有依赖 revision 的缓存全部作废，鉴权失败时还会引起反复重试。
  Future<({String id, bool changed})?> _apply(
    SharedCredential shared,
    String? existingId,
  ) async {
    final platform = shared.platform;
    final credential = shared.credential;
    if (existingId != null) {
      final existing = vault.credentialFor(platform, existingId);
      if (existing != null) {
        if (_sameFields(existing, credential)) {
          return (id: existingId, changed: false);
        }
        await vault.withAccount(
          platform,
          existingId,
          () => vault.putCredential(platform, credential),
        );
        return (id: existingId, changed: true);
      }
    }
    final id = await vault.createAccount(platform);
    await vault.withAccount(
      platform,
      id,
      () => vault.putCredential(platform, credential),
    );
    await vault.renameAccount(platform, id, '共享·${platform.shortName}');
    // 平台还没有任何账号时才自动激活，绝不顶掉已有的本地账号。
    if (vault.activeAccountId(platform) == null) {
      await vault.activate(platform, id);
    }
    return (id: id, changed: true);
  }

  static bool _sameFields(Credential left, Credential right) =>
      left.label == right.label &&
      left.fields.length == right.fields.length &&
      left.fields.entries.every((e) => right.fields[e.key] == e.value);

  CloudShareSyncResult _remember(CloudShareSyncResult result) {
    _lastResult = result;
    return result;
  }
}
