// 多 NAS / 多账号的落盘层。
//
// 背景：以前本机只记「上次登录的那一个 NAS」（`saved_session` 单条记录）。
// 官方 APK 能同时记住多个 NAS（地址 / 账号 / 设备令牌），并在其间切换；
// 我们缺这块（P64 相册 / N5 笔记 / D3 音频）。
//
// 存储形状（同一张键值表）：
//   * `nas_configs`   —— 一个 JSON 对象 `{v, items: [<entry json 字符串>]}`，
//                        每条 entry 的格式与老的 `saved_session` 完全兼容，
//                        只多一个 `id`；
//   * `nas_active_id` —— 当前活动条目的 id；**没有这个键 = 当前没有已登录的 NAS**
//                        （登出后就是这样，条目还在，但不会再自动登）；
//   * `saved_session` —— 老键，保留为「活动条目的镜像」，让老代码/后台任务
//                        （如相册备份的 `SavedSessionStore.load()`）无感读到当前 NAS；
//                        当前没有活动条目时这个键会被删掉（老语义：`load()==null`）。
//
// 三条硬约束（都有用例）：
//   1. **迁移不清空**：老用户只有 `saved_session` 时，第一次读就升级成一条列表项，
//      地址/账号/密码/did 原样保留；
//   2. **坏一条不拖垮全部**：`items` 里某条解析失败 → 跳过它，其余照常读；
//      整块 `nas_configs` 坏掉 → 不覆写、不删除，尽量从老键恢复或返回空；
//   3. **凭据按条隔离**：每条各自封各自的密码，改 B 不会动到 A 的 sid/did。
import 'dart:convert';

import '../../data/e2ee/e2ee_service.dart' show E2eeStore;
import '../../data/e2ee/secret_keeper.dart';
import 'server_profile.dart';
import 'saved_session.dart';

/// 一次 [NasStore.load] 的结果。
class NasSnapshot {
  const NasSnapshot({
    this.configs = const [],
    this.activeId,
    this.partial = false,
  });

  final List<SavedSession> configs;

  /// 当前活动条目的 id；null = 当前没有已登录的 NAS
  final String? activeId;

  /// 读取时有条目坏掉（已跳过）——界面可以提示，但**不能**因此清空
  final bool partial;

  bool get isEmpty => configs.isEmpty;

  /// 当前活动条目。id 指向了一条不存在的记录（部分损坏）时回落到第一条。
  SavedSession? get active {
    if (activeId == null || configs.isEmpty) return null;
    for (final c in configs) {
      if (c.id == activeId) return c;
    }
    return configs.first;
  }

  SavedSession? byId(String? id) {
    if (id == null) return null;
    for (final c in configs) {
      if (c.id == id) return c;
    }
    return null;
  }

  NasSnapshot copyWith({
    List<SavedSession>? configs,
    String? activeId,
    bool? partial,
    bool clearActive = false,
  }) {
    return NasSnapshot(
      configs: configs ?? this.configs,
      activeId: clearActive ? null : (activeId ?? this.activeId),
      partial: partial ?? this.partial,
    );
  }
}

/// 多 NAS 列表的读写。
class NasStore {
  NasStore(this._store, {SecretKeeper? keeper})
    : _keeper = keeper ?? const NoopSecretKeeper();

  final E2eeStore _store;
  final SecretKeeper _keeper;

  /// 列表键；写格式时抬 [formatVersion]。
  static const String configsKey = 'nas_configs';

  /// 活动条目 id 键。
  static const String activeKey = 'nas_active_id';

  /// 老的单条记录键（[SavedSessionStore.storageKey] 的实体）。
  static const String legacyKey = 'saved_session';

  static const int formatVersion = 1;

  static int _seq = 0;

  /// 生成一个进程内唯一的条目 id（不引第三方 uuid：本机单进程足够）。
  static String newId() {
    _seq++;
    final t = DateTime.now().microsecondsSinceEpoch;
    return 'nas_${t.toRadixString(36)}_${_seq.toRadixString(36)}';
  }

  /// 读全部配置。绝不因为坏数据删除/覆写已有存储。
  Future<NasSnapshot> load() async {
    final raw = await _store.setting(configsKey);
    var configs = <SavedSession>[];
    var partial = false;

    final top = raw == null ? null : decodeMap(raw);
    // ★ r707：**遗留明文行要在读的时候顺手封掉**（不是只记一句"历史遗留"）。
    //   guest 实测（`C:\Users\dev\Documents\synhub.sqlite`）里同时躺着
    //   `secret_sealed":true`（新行）与 `secret_sealed":false` + **明文口令**
    //   （旧行）⇒ 只翻能力位不改历史行 = 明文永远留在盘上。
    //   判据：任一条目不是 `secret_sealed:true` ⇒ 读完立刻 `persist()` 重封
    //   （`persist` 会走 `_encodeEntry` → `_keeper.seal`；封不住时行为不变，
    //   所以这条迁移**幂等且不会把能封的机器写坏**）。
    var needsReseal = false;
    if (top != null && top['items'] is List) {
      for (final item in top['items'] as List) {
        Map<String, dynamic>? map;
        if (item is String) {
          map = decodeMap(item);
        } else if (item is Map) {
          map = Map<String, dynamic>.from(item);
        }
        if (map != null && map['secret_sealed'] != true) needsReseal = true;
        final entry = map == null ? null : await decodeEntry(map);
        if (entry == null) {
          // 单条坏 → 跳过它，剩下的继续（不清空）
          partial = true;
          continue;
        }
        configs.add(entry.id == null || entry.id!.isEmpty
            ? entry.copyWith(id: newId())
            : entry);
      }
    } else if (raw != null && raw.isNotEmpty) {
      // 整块坏 → 标记但不覆写
      partial = true;
    }

    var activeId = (await _store.setting(activeKey))?.trim();
    if (activeId != null && activeId.isEmpty) activeId = null;

    // 迁移：老用户只有 `saved_session`，还没有列表 → 升级成一条，保留全部字段。
    if (configs.isEmpty && activeId == null) {
      final legacyRaw = await _store.setting(legacyKey);
      final legacyMap = legacyRaw == null ? null : decodeMap(legacyRaw);
      if (legacyMap != null && legacyMap['secret_sealed'] != true) {
        needsReseal = true;
      }
      final legacy = await _loadLegacy();
      if (legacy != null) {
        final entry = legacy.id == null || legacy.id!.isEmpty
            ? legacy.copyWith(id: newId())
            : legacy;
        configs = [entry];
        activeId = entry.id;
        await persist(configs, activeId);
      }
    }

    // active 指向不存在的条目（部分损坏）→ 回落到第一条，别整体丢弃
    if (activeId != null && !configs.any((c) => c.id == activeId)) {
      activeId = configs.isEmpty ? null : configs.first.id;
      partial = true;
    }

    if (needsReseal && configs.isNotEmpty) {
      // 重封一次（幂等）；失败由 `_encodeEntry` 的既有降级兜住，不在这里抛。
      await persist(configs, activeId);
    }

    return NasSnapshot(
      configs: configs,
      activeId: activeId,
      partial: partial,
    );
  }

  /// 全量写回（列表 + 活动 id + 老键镜像）。
  Future<void> persist(List<SavedSession> configs, String? activeId) async {
    final items = <String>[];
    // 每条只封一次密码；活动那条的字符串直接复用到老键镜像上（少封一次，
    // 也避免同一份凭据出现两份密文）。
    String? activeEncoded;
    for (final c in configs) {
      final encoded = await _encodeEntry(c);
      items.add(encoded);
      if (c.id != null && c.id == activeId) activeEncoded = encoded;
    }
    await _store.setSetting(
      configsKey,
      jsonEncode({'v': formatVersion, 'items': items}),
    );

    if (activeId == null || activeId.isEmpty) {
      await _store.deleteSetting(activeKey);
    } else {
      await _store.setSetting(activeKey, activeId);
    }

    // 老键 = 活动条目的镜像（老代码/相册后台任务继续能读到当前 NAS）
    if (activeEncoded == null) {
      await _store.deleteSetting(legacyKey);
    } else {
      await _store.setSetting(legacyKey, activeEncoded);
    }
  }

  /// 登录成功后把这一条写进列表并置为活动。
  ///
  /// 匹配规则：带 [SavedSession.id] 就按 id；否则按「地址 + 账号」找同一条
  /// （同 NAS 同账号重登 = 更新；同 NAS 换账号 = 新的一条，于是支持多账号）。
  Future<SavedSession> upsertActive(SavedSession s) async {
    final snap = await load();
    final list = List<SavedSession>.of(snap.configs);

    var idx = -1;
    if (s.id != null && s.id!.isNotEmpty) {
      idx = list.indexWhere((c) => c.id == s.id);
    }
    if (idx < 0) {
      idx = list.indexWhere((c) => _sameAccount(c, s));
    }
    // 之前用「添加 NAS」只记了地址（账号为空）的那条：登录成功后补进同一条，
    // 不能再多出一条重复的。
    if (idx < 0) {
      idx = list.indexWhere(
        (c) => c.account.trim().isEmpty && sameServer(c.profile, s.profile),
      );
    }

    SavedSession entry;
    if (idx >= 0) {
      final old = list[idx];
      entry = s.copyWith(
        id: old.id,
        // 登录流里 profile 可能不带 displayName：别把用户起的名字冲掉
        profile: _mergeProfile(old.profile, s.profile),
      );
      list[idx] = entry;
    } else {
      entry = s.id == null || s.id!.isEmpty ? s.copyWith(id: newId()) : s;
      list.add(entry);
    }

    await persist(list, entry.id);
    return entry;
  }

  /// 新增一条（只有地址，还没有账号/凭据）——"添加 NAS"用。
  Future<SavedSession> add(ServerProfile profile, {String? displayName}) async {
    final snap = await load();
    final list = List<SavedSession>.of(snap.configs);
    final entry = SavedSession(
      id: newId(),
      profile: ServerProfile(
        kind: profile.kind,
        value: profile.value,
        displayName: displayName ?? profile.displayName,
      ),
      account: '',
    );
    list.add(entry);
    // 只加进列表，不抢当前活动（活动由显式切换/登录决定）
    await persist(list, snap.activeId);
    return entry;
  }

  /// 重命名（只改展示名，id/凭据不动）。
  Future<void> rename(String id, String? displayName) async {
    final snap = await load();
    final list = List<SavedSession>.of(snap.configs);
    final idx = list.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    final old = list[idx];
    final name = (displayName ?? '').trim();
    list[idx] = old.copyWith(
      profile: ServerProfile(
        kind: old.profile.kind,
        value: old.profile.value,
        displayName: name.isEmpty ? null : name,
      ),
    );
    await persist(list, snap.activeId);
  }

  /// 移除一条。返回移除后新的活动 id（可能回落到剩余的第一条）。
  ///
  /// **只动这一条**：别的条目原样保留。
  Future<NasSnapshot> remove(String id) async {
    final snap = await load();
    final list = snap.configs.where((c) => c.id != id).toList();
    var activeId = snap.activeId;
    if (activeId == id) {
      activeId = list.isEmpty ? null : list.first.id;
    }
    if (activeId != null && !list.any((c) => c.id == activeId)) {
      activeId = list.isEmpty ? null : list.first.id;
    }
    await persist(list, activeId);
    return NasSnapshot(
      configs: list,
      activeId: activeId,
      partial: snap.partial,
    );
  }

  /// 显式切换活动条目（只改"当前"，不碰任何凭据）。
  Future<void> setActive(String id) async {
    final snap = await load();
    if (!snap.configs.any((c) => c.id == id)) return;
    await persist(snap.configs, id);
  }

  /// 登出：清掉当前条目的凭据，并把"当前"标为空（条目保留，可重新登录）。
  Future<void> clearActive() async {
    final snap = await load();
    final activeId = snap.activeId;
    final list = snap.configs.map((c) {
      if (c.id != activeId) return c;
      // 明确丢掉密码与设备令牌（`copyWith(deviceId: null)` 是"不改"，这里要真清）
      return SavedSession(
        id: c.id,
        profile: c.profile,
        account: c.account,
        rememberDevice: c.rememberDevice,
        lastBaseUrl: c.lastBaseUrl,
      );
    }).toList();
    await persist(list, null); // activeId = null → 老键也被删掉
  }

  /// 当前活动条目（给 `SavedSessionStore.load()` / 冷启动恢复用）。
  Future<SavedSession?> loadActive() async => (await load()).active;

  // ---- 编解码（单条 entry 与老格式逐字段兼容，只多 id）----

  /// 解析一段 JSON 文本为 Map；坏 JSON / 非对象 → null。
  static Map<String, dynamic>? decodeMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 把一条记录的 map 解成 [SavedSession]；缺地址等关键字段 → null。
  ///
  /// 注意：凭据解不开（换机/Keystore 密钥丢）**不算坏**——记录照旧返回，
  /// 只是 `password == null`（上层降级成"请重输密码"）。
  Future<SavedSession?> decodeEntry(Map<String, dynamic> map) async {
    final value = map['value'] as String?;
    if (value == null || value.trim().isEmpty) return null;

    final kindName = map['kind'] as String?;
    final kind = ServerAddressKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => ServerAddressKind.quickConnect,
    );

    String? password;
    final secret = map['secret'] as String?;
    if (secret != null && secret.isNotEmpty) {
      final sealed = map['secret_sealed'] == true;
      final plain = sealed ? await _keeper.open(secret) : secret;
      if (plain != null && plain.isNotEmpty) {
        final s = decodeMap(plain);
        if (s != null) password = s['password'] as String?;
      }
    }

    final id = map['id'] as String?;
    return SavedSession(
      id: id == null || id.isEmpty ? null : id,
      profile: ServerProfile(
        kind: kind,
        value: value,
        displayName: map['display_name'] as String?,
      ),
      account: (map['account'] as String?) ?? '',
      password: password,
      rememberDevice: map['remember_device'] == true,
      deviceId: map['did'] as String?,
      lastBaseUrl: map['last_base_url'] as String?,
    );
  }

  /// 把一条记录编成 JSON 文本（密码单独封壳；OTP 永不落盘）。
  Future<String> _encodeEntry(SavedSession s) async {
    final plain = jsonEncode({'password': s.password});
    final sealed = await _keeper.seal(plain);
    return jsonEncode({
      'v': formatVersion,
      'id': s.id,
      'kind': s.profile.kind.name,
      'value': s.profile.value,
      'display_name': s.profile.displayName,
      'account': s.account,
      'secret': sealed ?? plain,
      'secret_sealed': sealed != null,
      'remember_device': s.rememberDevice,
      'did': s.deviceId,
      'last_base_url': s.lastBaseUrl,
      'saved_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<SavedSession?> _loadLegacy() async {
    final raw = await _store.setting(legacyKey);
    if (raw == null || raw.isEmpty) return null;
    final map = decodeMap(raw);
    if (map == null) return null;
    return decodeEntry(map);
  }

  static SavedSession? byIdIn(List<SavedSession> list, String? id) {
    if (id == null) return null;
    for (final c in list) {
      if (c.id == id) return c;
    }
    return null;
  }


  /// 两条记录是不是"同一个 NAS 上的同一个账号"。
  static bool _sameAccount(SavedSession a, SavedSession b) {
    if (a.account.trim().isEmpty || a.account.trim() != b.account.trim()) {
      return false;
    }
    return sameServer(a.profile, b.profile);
  }

  /// 地址是否是同一个（QuickConnect ID 不分大小写；直连忽略末尾斜杠）。
  static bool sameServer(ServerProfile a, ServerProfile b) {
    if (a.kind != b.kind) return false;
    return _normValue(a) == _normValue(b);
  }

  static String _normValue(ServerProfile p) {
    var v = p.value.trim().toLowerCase();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  /// 保留用户起的展示名（登录流带的 profile 通常没有它）。
  static ServerProfile _mergeProfile(ServerProfile old, ServerProfile next) {
    if (next.displayName != null && next.displayName!.trim().isNotEmpty) {
      return next;
    }
    if (old.displayName != null && old.displayName!.trim().isNotEmpty) {
      return ServerProfile(
        kind: next.kind,
        value: next.value,
        displayName: old.displayName,
      );
    }
    return next;
  }
}
