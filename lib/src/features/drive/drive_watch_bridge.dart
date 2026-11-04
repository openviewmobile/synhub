// ★★★ ③Drive **D65「App 被杀后仍常驻监听」的原生半边（Dart 侧契约）** —— 第 228 轮。
//
// ## 为什么还要这一块
// 224 轮的监听是 `dart:io` `Directory.watch` —— **只在 App 进程存活时有效**。
// 官方 `DriveFileWatchService` 是 Android **Service + FileObserver**：App 被杀
// 之后照样盯着目录，变化了就唤醒任务。
//
// ## 本轮的分工（诚实边界）
// 原生这一层做"**看 + 唤醒 + 记账**"，Dart 这一层做"**记账 + 前台认领**"：
//
//   ① 前台开启监听时，把要盯的本地根交给原生（通道 `synhub/drive_watch`）；
//   ② 原生 `DriveFileWatchService` 用 `FileObserver` 盯这些根（含子目录，深度≤2），
//      变化去抖后由 `DriveWatchWorker` 起 headless 引擎 → 通道
//      `synhub/drive_watch_bg` 的 `wake`；
//   ③ Dart 后台入口把"哪些任务被唤醒了"写进 `pending_watch.json`（**只记账，不搬文件**）；
//   ④ 回到前台时读这份账，提示/触发一次同步，然后清账。
//
// ⚠️ 与官方的差距（挂账）：官方**在被杀状态也会真的跑同步**（后台登录 + 上传）；
// 我方后台只做"记账 + 唤醒"，真正的文件搬运回到前台才做。
// 原因：后台驱动器需要**静默重登**整条链路（Keystore + QuickConnect + 信任库），
// 那是相册备份那一套（`photo_backup_background.dart`）才有的装配，Drive 侧要单独
// 做一轮并真机验证 —— 本轮不假装已经做到。
import 'dart:convert';
import 'dart:io';

import 'dart:ui' show PluginUtilities;


import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import 'package:path_provider/path_provider.dart';

import 'drive_background_sync.dart';

/// 前台登记监听用的通道（Kotlin `DriveFileWatchBridge`）
const String kDriveWatchChannel = 'synhub/drive_watch';

/// 后台被唤醒时用的通道（Kotlin `DriveWatchWorker`）
const String kDriveWatchBackgroundChannel = 'synhub/drive_watch_bg';

/// 原生监听的去抖窗口（秒）——与官方"停手 3 秒再动手"一致，也便于用例钉住。
const int kDriveWatchDebounceSeconds = 3;

/// 原生递归深度上限（Android 的 `FileObserver` 不递归，得自己走子目录）
const int kDriveWatchMaxDepth = 2;

abstract class DriveWatchBridge {
  /// 交给原生要盯的本地根（会**替换**之前登记的全部根）
  Future<bool> start(List<String> roots);

  Future<bool> stop();

  Future<bool> isRunning();
}

class MethodChannelDriveWatchBridge implements DriveWatchBridge {
  const MethodChannelDriveWatchBridge();

  static const MethodChannel _channel = MethodChannel(kDriveWatchChannel);

  /// 第 55 轮：`synhub/drive_watch[_bg]` 只有 Kotlin 一份（WorkManager +
  /// `FileObserver`）⇒ 宿主上能力层报 `unavailable:not-implemented-on-host`，
  /// **不碰通道**，如实回 false。
  static bool get _allowed => capabilityGateAllows(AppCapability.driveWatch);

  static void _logBlocked(String what) =>
      debugPrint(capabilityGateLog(AppCapability.driveWatch, 'drive_watch.$what'));

  @override
  Future<bool> start(List<String> roots) async {
    if (!_allowed) {
      _logBlocked('start');
      return false;
    }
    try {
      // ★ 先把自己的后台入口 handle 交上去：Kotlin 侧没有"函数名 → handle"的 API，
      // 只能由 Dart 给（与 `PhotoBackupPlugin.registerCallback` 同一套路）。
      await _channel.invokeMethod<bool>('registerCallback', {
        'handle':
            PluginUtilities.getCallbackHandle(driveWatchBackgroundMain)
                ?.toRawHandle() ??
            0,
      });
      return await _channel.invokeMethod<bool>('start', {
            'roots': roots,
            'debounce_seconds': kDriveWatchDebounceSeconds,
            'max_depth': kDriveWatchMaxDepth,
          }) ??
          false;
    } on MissingPluginException {
      // 桌面/测试环境没有原生实现 —— 不抛，回 false 让调用方如实处理
      return false;
    } on PlatformException catch (e) {
      // ★ 249 轮：Android 12+ 不在前台时系统会拒绝启动常驻服务
      // （原生侧已改成"回滚 + 回 false"，这里再兜一层，避免任何 PlatformException
      // 把界面炸掉）。失败就是失败，**不假装已经盯上**。
      debugPrint('DriveWatch start 被原生拒绝：${e.code} ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> stop() async {
    if (!_allowed) {
      _logBlocked('stop');
      return false;
    }
    return await _channel.invokeMethod<bool>('stop') ?? false;
  }

  @override
  Future<bool> isRunning() async {
    if (!_allowed) {
      _logBlocked('isRunning');
      return false;
    }
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }
}

class RecordingDriveWatchBridge implements DriveWatchBridge {
  final calls = <String>[];
  final startedRoots = <List<String>>[];
  bool running = false;

  @override
  Future<bool> start(List<String> roots) async {
    calls.add('start');
    startedRoots.add(roots);
    running = true;
    return true;
  }

  @override
  Future<bool> stop() async {
    calls.add('stop');
    running = false;
    return true;
  }

  @override
  Future<bool> isRunning() async {
    calls.add('isRunning');
    return running;
  }
}

final driveWatchBridgeProvider = Provider<DriveWatchBridge>(
  (ref) => const MethodChannelDriveWatchBridge(),
  name: 'driveWatchBridge',
);

/// 后台被唤醒的记账（"哪些任务在 App 不在时被动过"）。
abstract class DrivePendingWakeStore {
  Future<List<String>> read();

  /// 追加（去重、保序）
  Future<List<String>> add(Iterable<String> taskIds);

  Future<void> clear();
}

/// ★ 248 轮：把**已经处理掉**的根从账本里摘掉（剩下的继续挂着）。
///
/// 写成 **extension** 而不是抽象成员 —— 抽象成员会让所有 `implements` 的实现
/// （含用例里的假件）**编译不过**；extension 只挂在接口上，任何实现都能用。
///
/// 为什么需要：228 轮的账本是"根路径的集合"，前台回来看一眼就把**整本**清掉；
/// 248 轮后台**真的搬了文件**之后，只能摘掉这次处理过的根，不能把别人也抹了。
extension DrivePendingWakeStoreMaintenance on DrivePendingWakeStore {
  Future<List<String>> removeAll(Iterable<String> ids) async {
    final kill = ids.toSet();
    final remain = [
      for (final e in await read())
        if (!kill.contains(e)) e,
    ];
    await clear();
    if (remain.isNotEmpty) await add(remain);
    return remain;
  }
}

class MemoryDrivePendingWakeStore implements DrivePendingWakeStore {
  MemoryDrivePendingWakeStore([List<String>? initial])
    : _ids = [...?initial];

  final List<String> _ids;

  /// 测试断言用（拷贝）
  List<String> get snapshot => List.unmodifiable(_ids);

  @override
  Future<List<String>> read() async => List.unmodifiable(_ids);

  @override
  Future<List<String>> add(Iterable<String> taskIds) async {
    for (final id in taskIds) {
      if (id.isEmpty || _ids.contains(id)) continue;
      _ids.add(id);
    }
    return List.unmodifiable(_ids);
  }

  @override
  Future<void> clear() async => _ids.clear();
}

class JsonDrivePendingWakeStore implements DrivePendingWakeStore {
  JsonDrivePendingWakeStore(this.file);

  final File file;

  @override
  Future<List<String>> read() async {
    try {
      if (!file.existsSync()) return const [];
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return const [];
      final list = raw['pending'];
      if (list is! List) return const [];
      return [for (final e in list) '$e'];
    } catch (_) {
      // 坏文件按"没有待办"处理（不猜）
      return const [];
    }
  }

  @override
  Future<List<String>> add(Iterable<String> taskIds) async {
    final ids = [...await read()];
    for (final id in taskIds) {
      if (id.isEmpty || ids.contains(id)) continue;
      ids.add(id);
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'version': 1, 'pending': ids}),
      flush: true,
    );
    return ids;
  }

  @override
  Future<void> clear() async {
    if (file.existsSync()) await file.delete();
  }
}

/// 待办账本文件（`<documents>/drive/pending_watch.json`）
Future<File> defaultDrivePendingWakeFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/drive/pending_watch.json');
}

final drivePendingWakeStoreProvider = Provider<DrivePendingWakeStore>((ref) {
  // 懒解析：只有真读/写时才碰 path_provider
  return _LazyJsonDrivePendingWakeStore();
});

class _LazyJsonDrivePendingWakeStore implements DrivePendingWakeStore {
  JsonDrivePendingWakeStore? _inner;

  Future<JsonDrivePendingWakeStore> _resolve() async =>
      _inner ??= JsonDrivePendingWakeStore(await defaultDrivePendingWakeFile());

  @override
  Future<List<String>> read() async => (await _resolve()).read();

  @override
  Future<List<String>> add(Iterable<String> taskIds) async =>
      (await _resolve()).add(taskIds);

  @override
  Future<void> clear() async => (await _resolve()).clear();
}

/// 后台入口：**只记账**（原生 worker 起 headless 引擎后调 `wake`）。
@pragma('vm:entry-point')
void driveWatchBackgroundMain() {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kDriveWatchBackgroundChannel);
  // 第 55 轮：后台通道只有 Android 侧注册；能力层不放行就不监听。
  if (!capabilityGateAllows(AppCapability.driveWatch)) {
    debugPrint(
      capabilityGateLog(AppCapability.driveWatch, 'drive_watch_bg.subscribe'),
    );
    return;
  }
  channel.setMethodCallHandler((call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    if (call.method == 'wake') {
      // 228 轮语义：只记账（**保留**，前台回来看账用）
      return recordDriveWatchWake(args);
    }
    if (call.method == 'runSync') {
      // ★ 248 轮 D65：**真的跑一轮同步**（静默重登 + 差异 + 搬运）
      final roots = <String>[
        for (final e in (args['task_ids'] as List?) ?? const []) '$e',
      ];
      final report = await runDriveSyncInBackground(roots);
      return report.toMap();
    }
    return null;
  });
}

/// 处理一次后台唤醒：把 `task_ids` 写进待办账本，返回 `{ok, pending}`。
///
/// [store] 是给用例的注入缝（默认走落盘账本）。
Future<Map<String, Object?>> recordDriveWatchWake(
  Map<String, Object?> args, {
  DrivePendingWakeStore? store,
}) async {
  final raw = args['task_ids'];
  final ids = <String>[
    if (raw is List)
      for (final e in raw)
        if ('$e'.isNotEmpty) '$e',
  ];
  try {
    final s = store ?? _backgroundStore;
    final pending = await s.add(ids);
    return <String, Object?>{
      'ok': true,
      'pending': pending.length,
      'ids': pending,
      'debounce_seconds': kDriveWatchDebounceSeconds,
    };
  } catch (e) {
    return <String, Object?>{'ok': false, 'pending': 0, 'error': '$e'};
  }
}

/// 后台 isolate 用的账本（懒解析，避免在没平台通道时崩）
DrivePendingWakeStore get _backgroundStore =>
    _bgStore ??= _LazyJsonDrivePendingWakeStore();

DrivePendingWakeStore? _bgStore;
