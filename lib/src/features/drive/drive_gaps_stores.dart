// Drive「wave1 剩余可直接做项」的**本地持久化**（D51 搜索历史 / D81 首次运行范围）。
//
// 为什么不用新的 KV 依赖：本批**禁改 `pubspec.yaml`**，而且 core 的设置门面
// (`SettingsService`) 的 key 都是写死的、没有公开的裸 KV 写入口。安全存储
// (`flutter_secure_storage`) 是**既有依赖**，也是仓库里处理"可持久化且不动
// core"的既有最短路径（同 `photo_map_prefs.dart`）。值本身不是秘密，放这里
// 只是"能持久化"。
//
// 降级纪律（很重要，决定测试环境是否有打扰）：
//   * 读盘**抛异常**（桌面/`flutter test` 没有插件、Keystore 损坏）一律当作
//     "**存储不可用**"：搜索历史回空表；首次运行**视为已看过**（绝不在存储
//     坏掉时反复弹引导）。
//   * 写盘失败只影响"下次还在不在"，不影响本次会话的内存状态。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/platform/app_secure_storage.dart';

/// 搜索历史最多留几条（官方 `SearchHistoryManager` 是本地列表，长度上限未取证；
/// 这里取一个保守的小值，只作为 UI 便利，不冒充官方数值）。
const int kDriveSearchHistoryMax = 10;

/// 搜索历史的存取。
abstract class DriveSearchHistoryStore {
  Future<List<String>> read();
  Future<void> write(List<String> items);
}

class SecureDriveSearchHistoryStore implements DriveSearchHistoryStore {
  SecureDriveSearchHistoryStore([FlutterSecureStorage? storage])
    : _storage =
          storage ?? appSecureStorage(android: const AndroidOptions());

  static const String slot = 'drive_search_history_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<List<String>> read() async {
    try {
      final raw = await _storage.read(key: slot);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (e is String && e.trim().isNotEmpty) e,
      ];
    } catch (_) {
      // 存储不可用 / 旧值损坏 → 当作没有历史
      return const [];
    }
  }

  @override
  Future<void> write(List<String> items) async {
    try {
      if (items.isEmpty) {
        await _storage.delete(key: slot);
        return;
      }
      await _storage.write(key: slot, value: jsonEncode(items));
    } catch (_) {
      // 写不进去只影响"下次还在不在"
    }
  }
}

/// 内存实现（单测用）。
class MemoryDriveSearchHistoryStore implements DriveSearchHistoryStore {
  MemoryDriveSearchHistoryStore([List<String>? initial])
    : _items = [...?initial];

  List<String> _items;

  /// 供测试直接检查"到底有没有落盘"。
  List<String> get items => List.unmodifiable(_items);

  @override
  Future<List<String>> read() async => [..._items];

  @override
  Future<void> write(List<String> items) async => _items = [...items];
}

final driveSearchHistoryStoreProvider = Provider<DriveSearchHistoryStore>(
  (ref) => SecureDriveSearchHistoryStore(),
);

/// 最近搜索（去重、最新在前）。持久化见 [DriveSearchHistoryStore]。
class DriveSearchHistoryNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  /// 页面 `initState` 调一次，把落盘的历史读回内存。
  Future<void> preload() async {
    final items = await ref.read(driveSearchHistoryStoreProvider).read();
    if (ref.mounted) state = items;
  }

  /// 记录一次搜索（[[keyword]] 为空则忽略；重复关键词提到最前）。
  Future<void> record(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    final next = [
      k,
      ...state.where((e) => e != k),
    ].take(kDriveSearchHistoryMax).toList(growable: false);
    state = next;
    await ref.read(driveSearchHistoryStoreProvider).write(next);
  }

  Future<void> clear() async {
    state = const [];
    await ref.read(driveSearchHistoryStoreProvider).write(const []);
  }

  /// 删掉一条历史（页面上的单条 ×）
  Future<void> remove(String keyword) async {
    final next = state.where((e) => e != keyword).toList(growable: false);
    state = next;
    await ref.read(driveSearchHistoryStoreProvider).write(next);
  }
}

final driveSearchHistoryProvider =
    NotifierProvider<DriveSearchHistoryNotifier, List<String>>(
      DriveSearchHistoryNotifier.new,
    );

/// D81「首次运行范围说明」是否已看过。
abstract class DriveScopeIntroStore {
  /// `true` = 已经看过（或**存储不可用**，保守地不打扰）。
  Future<bool> isSeen();

  Future<void> markSeen();
}

class SecureDriveScopeIntroStore implements DriveScopeIntroStore {
  SecureDriveScopeIntroStore([FlutterSecureStorage? storage])
    : _storage =
          storage ?? appSecureStorage(android: const AndroidOptions());

  static const String slot = 'drive_scope_intro_seen_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<bool> isSeen() async {
    try {
      return await _storage.read(key: slot) == '1';
    } catch (_) {
      // 读不出来 → 当作已看过（宁可不弹，也别在存储坏掉时每次进来都弹）
      return true;
    }
  }

  @override
  Future<void> markSeen() async {
    try {
      await _storage.write(key: slot, value: '1');
    } catch (_) {
      // 写不进去只影响"下次要不要再弹"
    }
  }
}

/// 内存实现（单测用）。
class MemoryDriveScopeIntroStore implements DriveScopeIntroStore {
  MemoryDriveScopeIntroStore({this.seen = false});

  bool seen;

  @override
  Future<bool> isSeen() async => seen;

  @override
  Future<void> markSeen() async => seen = true;
}

final driveScopeIntroStoreProvider = Provider<DriveScopeIntroStore>(
  (ref) => SecureDriveScopeIntroStore(),
);

/// `true` = 已经看过范围说明（不显示引导条）。
///
/// 默认 `true`：异步读盘完成前首帧不闪。真正是否显示由 `preload()` 从存储读回；
/// 存储不可用时 [DriveScopeIntroStore.isSeen] 返回 `true`，不会打扰。
class DriveScopeIntroNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  Future<void> preload() async {
    final seen = await ref.read(driveScopeIntroStoreProvider).isSeen();
    if (ref.mounted) state = seen;
  }

  /// 用户看过/关掉引导。
  Future<void> dismiss() async {
    state = true;
    await ref.read(driveScopeIntroStoreProvider).markSeen();
  }
}

final driveScopeIntroProvider =
    NotifierProvider<DriveScopeIntroNotifier, bool>(
      DriveScopeIntroNotifier.new,
    );
