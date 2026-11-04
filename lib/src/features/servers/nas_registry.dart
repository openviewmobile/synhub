// 多 NAS / 多账号的「内存视图 + 动作」层。
//
// 数据在 [NasStore]（键值表）里；本文件把它读进 [NasListState] 供界面 watch，
// 并提供添加 / 切换 / 重命名 / 移除这些动作。**凭据与连接不在这里** ——
// 那是 `SessionController` 的事（它负责"切过去"真的要连上），本层只管"存了哪些、
// 当前选的是哪个"。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'nas_store.dart';
import 'saved_session.dart';
import 'server_profile.dart';
import 'session_controller.dart' show savedSessionStoreProvider;

/// 本机保存的 NAS/账号列表 + 当前活动项。
class NasListState {
  const NasListState({
    this.configs = const [],
    this.activeId,
    this.loaded = false,
    this.partial = false,
  });

  final List<SavedSession> configs;

  /// 当前活动条目 id；null = 当前没有已登录的 NAS（登出后 / 还没登录过）
  final String? activeId;

  /// 是否已经从存储读过一次
  final bool loaded;

  /// 读取时有条目损坏被跳过（提示用；数据没被清）
  final bool partial;

  /// 有多个可切换的 NAS（只有一条时界面不显示"切换器"）
  bool get hasMultiple => configs.length > 1;

  bool get isEmpty => configs.isEmpty;

  /// 当前活动条目（id 悬空时回落第一条，见 [NasSnapshot.active]）
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

  /// 当前活动 NAS 的展示名（用户自己起的名优先，否则地址）。
  String get activeLabel => active?.profile.label ?? '';

  NasListState copyWith({
    List<SavedSession>? configs,
    String? activeId,
    bool? loaded,
    bool? partial,
    bool clearActive = false,
  }) {
    return NasListState(
      configs: configs ?? this.configs,
      activeId: clearActive ? null : (activeId ?? this.activeId),
      loaded: loaded ?? this.loaded,
      partial: partial ?? this.partial,
    );
  }

  factory NasListState.fromSnapshot(NasSnapshot s) => NasListState(
    configs: s.configs,
    activeId: s.activeId,
    loaded: true,
    partial: s.partial,
  );
}

/// 多 NAS 列表的唯一入口。界面 watch 它；`SessionController` 也用它。
final nasRegistryProvider = NotifierProvider<NasRegistry, NasListState>(
  NasRegistry.new,
);

class NasRegistry extends Notifier<NasListState> {
  Future<void>? _loading;

  NasStore get _store => ref.read(savedSessionStoreProvider).nas;

  @override
  NasListState build() => const NasListState();

  /// 保证已从存储读过一次（幂等；并发调用共享同一个 Future）。
  Future<void> ensureLoaded() {
    if (state.loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final snap = await _store.load();
      state = NasListState.fromSnapshot(snap);
    } catch (_) {
      // 读失败：标记已尝试，但**保留**内存里已经有的列表（绝不清空）
      state = state.copyWith(loaded: true);
    } finally {
      _loading = null;
    }
  }

  /// 强制重读（存储被外部改过时用）。
  Future<void> reload() {
    _loading = null;
    return _load();
  }

  /// 添加一条（只有地址，无凭据）；返回新条目。
  Future<SavedSession> add(ServerProfile profile, {String? displayName}) async {
    await ensureLoaded();
    final entry = await _store.add(profile, displayName: displayName);
    await reload();
    return entry;
  }

  /// 重命名（只改展示名）。
  Future<void> rename(String id, String? displayName) async {
    await ensureLoaded();
    await _store.rename(id, displayName);
    await reload();
  }

  /// 移除一条。**只删这一条**，其余原样保留；活动项被删则回落到剩余第一条。
  Future<NasListState> remove(String id) async {
    await ensureLoaded();
    final snap = await _store.remove(id);
    state = NasListState.fromSnapshot(snap);
    return state;
  }

  /// 显式切换"当前"（不碰凭据）。
  Future<void> setActive(String id) async {
    await ensureLoaded();
    await _store.setActive(id);
    await reload();
  }

  /// 登录成功后写入/更新一条并置为活动，返回落盘后的条目。
  Future<SavedSession> upsertActive(SavedSession s) async {
    await ensureLoaded();
    final entry = await _store.upsertActive(s);
    await reload();
    return entry;
  }

  /// 登出：清掉当前条目的凭据，activity 置空（条目保留）。
  Future<void> clearActive() async {
    await ensureLoaded();
    await _store.clearActive();
    await reload();
  }
}
