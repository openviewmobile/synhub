// ★★★ ③Drive **D65「同步任务」的后台常驻文件监听** —— 第 224 轮（Dart 半边）。
//
// ## 官方对照
// 官方 Drive Android 有 `DriveFileWatchService`：常驻监听本地同步目录的变化
// （`FileObserver`），变化了就触发一次同步。第 220 轮我们把 `planDriveSync` 的
// 结论**真的执行**掉了，但"谁在盯着本地目录"还是空的 —— 只有用户手动点「立即执行」。
//
// ## 本轮做到哪儿
// * `IoDriveWatchSource`：`dart:io` 的 `Directory.watch(recursive: true)`
//   （Android 上走 inotify）**真的监听**本地根；
// * `debounceDriveWatch`：窗口内合并（一个编辑器保存会炸出 3~5 个事件），
//   忽略 `*.tmp` / `*.crdownload` / `~$*` 这类"正在写"的噪音；
// * `DriveAutoSyncCoordinator`：监听 → 去抖 → 算差异 → **调已核实的执行器**，
//   把每轮结果以 `DriveAutoSyncRun` 抛给界面；尊重任务的 `autoSyncEnabled`
//   与 `autoSyncIntervalMinutes`（没到间隔不发车，避免抖动时打爆服务端）。
//
// ⚠️ 诚实边界：本轮是**App 进程存活期间**的常驻监听。官方那个"App 被杀后
// 仍由 Service/FileObserver 盯着"的原生半边**仍未做**（挂账，见台账 D65）。
import 'dart:async';
import 'dart:io';

import 'drive_gaps_text.dart';
import 'drive_sync_runner.dart';
import 'drive_sync_task.dart';

enum DriveWatchChange { created, modified, deleted }

class DriveWatchEvent {
  const DriveWatchEvent({
    required this.relPath,
    required this.change,
    required this.atMs,
  });

  /// 相对任务本地根的路径（统一用 `/` 分隔）
  final String relPath;
  final DriveWatchChange change;
  final int atMs;

  @override
  String toString() => '${change.name}:$relPath@$atMs';
}

/// 监听来源（可注入 ⇒ 用例不依赖真实文件系统）。
abstract class DriveWatchSource {
  Stream<DriveWatchEvent> watch(String root);
}

/// `dart:io` 实现：`Directory.watch(recursive: true)`（Android = inotify）。
class IoDriveWatchSource implements DriveWatchSource {
  const IoDriveWatchSource();

  @override
  Stream<DriveWatchEvent> watch(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) {
      return const Stream<DriveWatchEvent>.empty();
    }
    // ⚠️ macOS 上 `/var` 是 `/private/var` 的软链：`Directory.watch` 回的事件路径
    // 用的是**解析后**的真实路径，直接和入参前缀比对会剥不掉前缀（用例当场抓到）。
    // 所以两个前缀都试：入参 root + `resolveSymbolicLinksSync()` 的结果。
    final prefixes = <String>{root, dir.path};
    try {
      prefixes.add(dir.resolveSymbolicLinksSync());
    } catch (_) {
      // 解析失败（权限/不存在）就只用已有前缀
    }
    final withSlash = prefixes
        .map((p) => p.endsWith('/') ? p : '$p/')
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return dir.watch(recursive: true).map((e) {
      var p = e.path.replaceAll('\\', '/');
      for (final prefix in withSlash) {
        if (p.startsWith(prefix)) {
          p = p.substring(prefix.length);
          break;
        }
      }
      return DriveWatchEvent(
        relPath: p,
        change: switch (e.type) {
          FileSystemEvent.create => DriveWatchChange.created,
          FileSystemEvent.delete => DriveWatchChange.deleted,
          _ => DriveWatchChange.modified,
        },
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
    })
        // `Directory.watch` 也会对被监听的**根目录本身**发事件（relPath 被剥成空串）。
        // 那不是"文件变化" ⇒ 丢掉（用例里第一批就是它，导致断言先拿到空路径）。
        .where((e) => e.relPath.isNotEmpty);
  }
}

/// "正在写"的噪音（官方同样忽略临时文件；这些是常见编辑器/浏览器后缀）
bool driveWatchNoisePath(String relPath) {
  final n = relPath.split('/').last.toLowerCase();
  return n.endsWith('.tmp') ||
      n.endsWith('.crdownload') ||
      n.endsWith('.part') ||
      n.endsWith('.swp') ||
      n.startsWith(r'~$') ||
      n.startsWith('.ds_store');
}

/// 去抖：窗口内的事件合并成一批（按路径去重，保留最后一次变化）。
Stream<List<DriveWatchEvent>> debounceDriveWatch(
  Stream<DriveWatchEvent> src, {
  Duration window = const Duration(seconds: 3),
  bool Function(String relPath)? ignore,
}) {
  final skip = ignore ?? driveWatchNoisePath;
  final pending = <String, DriveWatchEvent>{};
  Timer? timer;
  late StreamController<List<DriveWatchEvent>> ctl;
  StreamSubscription<DriveWatchEvent>? sub;

  void flush() {
    timer?.cancel();
    timer = null;
    if (pending.isEmpty) return;
    final batch = pending.values.toList()
      ..sort((a, b) => a.relPath.compareTo(b.relPath));
    pending.clear();
    ctl.add(batch);
  }

  ctl = StreamController<List<DriveWatchEvent>>(
    onListen: () {
      sub = src.listen(
        (e) {
          if (skip(e.relPath)) return;
          pending[e.relPath] = e;
          timer?.cancel();
          timer = Timer(window, flush);
        },
        onError: ctl.addError,
        onDone: () {
          flush();
          ctl.close();
        },
      );
    },
    onCancel: () async {
      timer?.cancel();
      await sub?.cancel();
    },
  );
  return ctl.stream;
}

/// 一轮自动同步的结果。
class DriveAutoSyncRun {
  const DriveAutoSyncRun({
    required this.atMs,
    required this.changedPaths,
    required this.result,
    this.skippedReason,
  });

  final int atMs;
  final List<String> changedPaths;

  /// 真跑了才有；被跳过（未启用/未到间隔）时为 `null`
  final DriveSyncRunResult? result;
  final String? skippedReason;

  int get executed => result?.executed ?? 0;
  int get failed => result?.failed ?? 0;
  bool get ran => result != null;
}

/// 监听 → 去抖 → 算差异 → 执行。**只有**任务启用自动同步时才发车。
class DriveAutoSyncCoordinator {
  DriveAutoSyncCoordinator({
    required this.source,
    required this.task,
    required this.diffBuilder,
    required this.executor,
    this.window = const Duration(seconds: 3),
    this.now,
    this.ignore,
  });

  final DriveWatchSource source;
  final DriveSyncTask task;

  /// 由调用方提供（页面里就是 `_diffFor(task)`）
  final Future<DriveSyncDiff> Function() diffBuilder;
  final DriveSyncExecutor executor;
  final Duration window;
  final int Function()? now;
  final bool Function(String relPath)? ignore;

  StreamSubscription<List<DriveWatchEvent>>? _sub;
  final _runs = StreamController<DriveAutoSyncRun>.broadcast();
  int _lastRunAtMs = 0;
  bool _running = false;

  Stream<DriveAutoSyncRun> get runs => _runs.stream;
  bool get isListening => _sub != null;

  int _now() => (now ?? () => DateTime.now().millisecondsSinceEpoch)();

  Future<void> start() async {
    if (_sub != null) return;
    _sub = debounceDriveWatch(
      source.watch(task.localRoot),
      window: window,
      ignore: ignore,
    ).listen((batch) async {
      if (_running) return; // 上一轮还没跑完 ⇒ 不叠加
      final at = _now();
      final changed = [for (final e in batch) e.relPath];
      if (!task.autoSyncEnabled || task.deleted) {
        _runs.add(
          DriveAutoSyncRun(
            atMs: at,
            changedPaths: changed,
            result: null,
            skippedReason: task.deleted
                ? driveGap('driveWatchTaskDeleted', '任务已删除')
                : driveGap('driveWatchAutoSyncDisabled', '未启用自动同步'),
          ),
        );
        return;
      }
      final interval = Duration(minutes: task.autoSyncInterval);
      if (_lastRunAtMs != 0 && at - _lastRunAtMs < interval.inMilliseconds) {
        _runs.add(
          DriveAutoSyncRun(
            atMs: at,
            changedPaths: changed,
            result: null,
            skippedReason: driveGapFill(
              'driveWatchTooSoon',
              '距上次同步不足 {minutes} 分钟',
              {'minutes': '${task.autoSyncInterval}'},
            ),
          ),
        );
        return;
      }
      _running = true;
      try {
        final diff = await diffBuilder();
        final r = await executor.run(diff);
        _lastRunAtMs = _now();
        _runs.add(
          DriveAutoSyncRun(atMs: at, changedPaths: changed, result: r),
        );
      } catch (e) {
        _runs.add(
          DriveAutoSyncRun(
            atMs: at,
            changedPaths: changed,
            result: const DriveSyncRunResult([]),
            skippedReason: driveGapFill('driveWatchFailed', '失败：{error}', {
              'error': '$e',
            }),
          ),
        );
      } finally {
        _running = false;
      }
    });
  }

  Future<void> stop() async {
    final s = _sub;
    _sub = null;
    await s?.cancel();
  }

  Future<void> dispose() async {
    await stop();
    await _runs.close();
  }
}
