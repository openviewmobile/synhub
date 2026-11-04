// ★★★ ③Drive **D65「App 被杀后仍真的搬文件」** —— 第 248 轮。
//
// ## 前情（228 轮）
// 原生 `DriveFileWatchService`（`FileObserver`）+ `DriveWatchWorker` 已经能在
// App 被杀后**盯着本地目录并起 headless 引擎唤醒 Dart**；但 Dart 那一侧只做
// **记账**（`pending_watch.json`），真正的文件搬运要等用户回到前台。
// 官方 `SyncRunner` 是在后台**直接把文件搬掉**的。
//
// ## 本轮补齐什么
// 把后台入口从"只记账"升级成"**记账 + 真的跑一轮同步**"：
//
//   `DriveWatchWorker`（原生，被杀也能起）
//     → headless `FlutterEngine`（**本轮补挂 `KeystoreBridge`**，否则解不开凭据）
//     → 通道 `synhub/drive_watch_bg`
//        ├─ `wake`      : 记账（228 轮既有语义，**保留**）
//        └─ `runSync`   : **本轮新增** —— 静默重登 → 拉远端 → `planDriveSync`
//                          → `DriveSyncExecutor` 真的上传/下载/删除 → 回执
//
// ## 与前台的关系
// 复用**同一个**判定与执行器（`driveSyncDue` / `planDriveSync` / `DriveSyncExecutor`
// / `DriveApiSyncIo` / 扫描器），所以同一条任务在前台点「立即执行」与在后台被唤醒
// 得到的结果一致 —— 不另写一套"后台专用同步"。
//
// ## 诚实边界
//   * 后台**不弹任何框**；没有可用凭据就如实回 `no-saved-session`，**不动用户数据**；
//   * 只在"任务被唤醒的本地根"或"真的到点了（`driveSyncDue`）"时才跑，
//     不做全量无差别扫描；
//   * 单条动作失败**只记录不中断**（与执行器一致），并写进后台日志；
//   * 原生侧的 WorkManager/headless 时序**真机未验**（见 `docs/device-verification.md`）。
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/net/trust_store.dart';
import '../../core/security/keystore_secret_keeper.dart';
import '../../data/drive_api.dart';
import '../../data/local/chat_store.dart';
import '../../data/local/database.dart';
import '../servers/connection_service.dart';
import '../servers/saved_session.dart';
import 'drive_sync_runner.dart';
import 'drive_sync_task.dart';
import 'drive_watch_bridge.dart';

/// 后台通道名（与 Kotlin `DriveWatchWorker.BG_CHANNEL` 一致）。
const String kDriveSyncBackgroundChannel = kDriveWatchBackgroundChannel;

/// headless 入口的方法名（Kotlin 侧 invokeMethod 用）。
const String kDriveSyncBgWakeMethod = 'wake';
const String kDriveSyncBgRunMethod = 'runSync';

/// 后台日志文件名（前台可读回来显示"上次后台同步"）。
const String kDriveSyncBackgroundLogFile = 'drive_sync_bg_log.json';

/// headless 入口。**函数名必须与 `PluginUtilities.getCallbackHandle(...)` 对应**
/// —— 原生侧存的是 `driveWatchBackgroundMain` 的 raw handle（228 轮就登记了它），
/// 所以这里先把 `runSync` 挂到**同一个入口**上，避免再改原生存的 handle。
@pragma('vm:entry-point')
void driveSyncBackgroundMain() => driveWatchBackgroundMain();

/// 后台一轮同步的可序列化回执。
class DriveSyncBackgroundReport {
  const DriveSyncBackgroundReport({
    required this.ok,
    required this.tasks,
    required this.executed,
    required this.failed,
    required this.uploaded,
    required this.downloaded,
    required this.removed,
    required this.skipped,
    this.error = '',
  });

  final bool ok;
  final int tasks;
  final int executed;
  final int failed;
  final int uploaded;
  final int downloaded;
  final int removed;
  final int skipped;
  final String error;

  Map<String, Object?> toMap() => {
    'ok': ok,
    'tasks': tasks,
    'executed': executed,
    'failed': failed,
    'uploaded': uploaded,
    'downloaded': downloaded,
    'removed': removed,
    'skipped': skipped,
    if (error.isNotEmpty) 'error': error,
  };

  static DriveSyncBackgroundReport failure(String error) =>
      DriveSyncBackgroundReport(
        ok: false,
        tasks: 0,
        executed: 0,
        failed: 0,
        uploaded: 0,
        downloaded: 0,
        removed: 0,
        skipped: 0,
        error: error,
      );
}

/// 后台依赖图（用例可替换成假件，不碰真库/真磁盘）。
class DriveSyncBackgroundContext {
  const DriveSyncBackgroundContext({
    required this.store,
    required this.api,
    required this.scanLocal,
    required this.now,
    this.close,
    this.clearWakes,
    this.logFile,
  });

  final DriveSyncTaskStore store;
  final DriveApi api;
  final Future<List<DriveSyncLocalEntry>> Function(String localRoot) scanLocal;
  final DateTime Function() now;
  final Future<void> Function()? close;

  /// 清掉这些本地根的待办账（跑完了就不该再挂账）
  final Future<void> Function(Set<String> roots)? clearWakes;
  final File? logFile;
}

/// 后台跑一轮同步。`open == null`/回 null ⇒ 没有可用会话，如实失败。
///
/// [roots] 是**本次被唤醒的本地根**（原生只知道路径，不知道任务 id）。
/// 为空 = 没有唤醒来源（例如周期任务）⇒ 只跑"真的到点了"的任务。
///
/// ## ★ 249 轮：先"便宜地"看有没有活，再决定要不要登录
///
/// 原实现**一上来就装配依赖图并静默重登**（Drift + Keystore + QuickConnect），
/// 哪怕一条任务都没有 —— 意味着原生每被 `FileObserver` 唤醒一次，
/// 就向 NAS 发一次登录。这既费电，也让"真机上验证后台链路"变成一件危险的事
/// （会真的登录用户 NAS）。
///
/// 现在分两段：
///   ① **preflight（不碰网络/不碰数据库）**：读任务表 JSON + 判断"有没有该跑的"；
///      没有 ⇒ 顺手把待办账摘掉、直接回 `tasks:0`，**`open` 一次都不调用**；
///   ② 真的有活 ⇒ 才 `open()` 装配依赖图 + 登录 + 跑执行器。
///
/// 这条"没有活就不登录"的判据被用例钉住（`open` 传一个会 `fail()` 的回调，
/// 空任务表时它必须**一次都没被调用**）。
Future<DriveSyncBackgroundReport> runDriveSyncInBackground(
  List<String> roots, {
  Future<DriveSyncBackgroundContext?> Function()? open,
  Future<DriveSyncTaskStore> Function()? taskStoreFor,
  Future<File?> Function()? logFileFor,
  DrivePendingWakeStore? wakeStore,
  DateTime Function()? now,
}) async {
  final clock = now ?? DateTime.now;
  try {
    // ① preflight：只看任务表（JSON 文件），不建库、不登录
    final store = await (taskStoreFor ?? _defaultTaskStore)();
    final wakes = wakeStore ?? JsonDrivePendingWakeStore(
      await defaultDrivePendingWakeFile(),
    );
    final want = roots
        .map(normalizeDriveLocalRoot)
        .where((e) => e.isNotEmpty)
        .toSet();
    final pre = await planDriveSyncBackground(store, roots: roots, now: clock());
    if (pre.picked.isEmpty) {
      if (want.isNotEmpty) await wakes.removeAll(want);
      final report = const DriveSyncBackgroundReport(
        ok: true,
        tasks: 0,
        executed: 0,
        failed: 0,
        uploaded: 0,
        downloaded: 0,
        removed: 0,
        skipped: 0,
      );
      await _appendLogTo(
        await (logFileFor ?? _defaultLogFile)(),
        clock,
        report,
      );
      return report;
    }
    // ② 有活才装配依赖图（登录）
    DriveSyncBackgroundContext? ctx;
    try {
      ctx = await (open ?? openDriveSyncBackgroundContext)();
      if (ctx == null) {
        return DriveSyncBackgroundReport.failure('no-saved-session');
      }
      final report = await runDriveSyncWith(ctx, roots: roots);
      await _appendLog(ctx, report);
      return report;
    } finally {
      try {
        await ctx?.close?.call();
      } catch (_) {
        // 收尾失败不影响回执
      }
    }
  } catch (e) {
    return DriveSyncBackgroundReport.failure('$e');
  }
}

/// preflight 结果：该跑哪些任务 + 归一的唤醒根（**不碰网络/数据库**）。
class DriveSyncBackgroundPlan {
  const DriveSyncBackgroundPlan({required this.picked, required this.roots});

  final List<DriveSyncTask> picked;
  final Set<String> roots;
}

/// 只读任务表判断"这次有没有活"（后台入口与用例共用同一判据）。
Future<DriveSyncBackgroundPlan> planDriveSyncBackground(
  DriveSyncTaskStore store, {
  required List<String> roots,
  required DateTime now,
}) async {
  final all = await store.load();
  final want = roots
      .map(normalizeDriveLocalRoot)
      .where((e) => e.isNotEmpty)
      .toSet();
  return DriveSyncBackgroundPlan(
    roots: want,
    picked: [
      for (final t in all)
        if (!t.deleted &&
            (want.isEmpty
                ? driveSyncDue(t, now)
                : want.contains(normalizeDriveLocalRoot(t.localRoot))))
          t,
    ],
  );
}

Future<DriveSyncTaskStore> _defaultTaskStore() async =>
    JsonDriveSyncTaskStore(await defaultDriveSyncTasksFile());

/// 用给定依赖图跑一轮（用例直接调它）。
Future<DriveSyncBackgroundReport> runDriveSyncWith(
  DriveSyncBackgroundContext ctx, {
  required List<String> roots,
}) async {
  final all = await ctx.store.load();
  final live = all.where((t) => !t.deleted).toList();
  final wantNorm = roots
      .map(normalizeDriveLocalRoot)
      .where((e) => e.isNotEmpty)
      .toSet();
  final picked = <DriveSyncTask>[
    for (final t in live)
      // 有唤醒来源 ⇒ 精确到那些根（**被唤醒就算到点**：用户刚改过文件）；
      // 没有唤醒来源（周期任务）⇒ 只跑真的到点的。
      if (wantNorm.isEmpty
          ? driveSyncDue(t, ctx.now())
          : wantNorm.contains(normalizeDriveLocalRoot(t.localRoot)))
        t,
  ];
  if (picked.isEmpty) {
    if (wantNorm.isNotEmpty) await ctx.clearWakes?.call(wantNorm);
    return const DriveSyncBackgroundReport(
      ok: true,
      tasks: 0,
      executed: 0,
      failed: 0,
      uploaded: 0,
      downloaded: 0,
      removed: 0,
      skipped: 0,
    );
  }

  var executed = 0, failed = 0, up = 0, down = 0, removed = 0, skipped = 0;
  final next = List<DriveSyncTask>.of(all);
  for (final task in picked) {
    try {
      final local = await ctx.scanLocal(task.localRoot);
      final remote = await ctx.api.list(path: task.remoteRoot, limit: 500);
      final diff = planDriveSync(
        local: local,
        remote: [
          for (final e in remote.items)
            DriveSyncRemoteEntry(
              path: e.name,
              isDir: e.isDir,
              size: e.size,
              modifiedMs: e.modifiedTime * 1000,
            ),
        ],
        task: task,
      );
      skipped += diff.actions
          .where((a) => a.kind == DriveSyncActionKind.skip)
          .length;
      final runner = DriveSyncExecutor(
        remote: DriveApiSyncIo(ctx.api, remoteRoot: task.remoteRoot),
        local: LocalDriveSyncIo(task.localRoot),
      );
      final result = await runner.run(diff);
      executed += result.executed;
      failed += result.failed;
      for (final o in result.outcomes.where((o) => o.ok)) {
        switch (o.action.kind) {
          case DriveSyncActionKind.upload:
            up++;
          case DriveSyncActionKind.download:
            down++;
          case DriveSyncActionKind.removeLocal:
          case DriveSyncActionKind.removeRemote:
            removed++;
          case DriveSyncActionKind.renameLocal:
          case DriveSyncActionKind.skip:
            break;
        }
      }
      final idx = next.indexWhere((t) => t.id == task.id);
      if (idx >= 0) {
        next[idx] = next[idx].copyWith(
          lastSyncAtMs: ctx.now().millisecondsSinceEpoch,
          // 与官方 `SyncStatus` 对齐的取值：全成功 ⇒ done，有失败 ⇒ error
          status: result.allOk ? DriveSyncStatus.done : DriveSyncStatus.error,
        );
      }
    } catch (e) {
      failed++;
      final idx = next.indexWhere((t) => t.id == task.id);
      if (idx >= 0) {
        next[idx] = next[idx].copyWith(status: DriveSyncStatus.error);
      }
    }
  }
  await ctx.store.save(next);
  if (wantNorm.isNotEmpty) await ctx.clearWakes?.call(wantNorm);
  return DriveSyncBackgroundReport(
    ok: failed == 0,
    tasks: picked.length,
    executed: executed,
    failed: failed,
    uploaded: up,
    downloaded: down,
    removed: removed,
    skipped: skipped,
  );
}

/// 装配后台那套最小依赖图（真库 + Keystore 凭据 + 静默重登）。
///
/// **不碰 UI、不弹框、不改用户数据**：只读本地库/任务表 + 读上次登录凭据登录。
Future<DriveSyncBackgroundContext?> openDriveSyncBackgroundContext({
  Future<File?> Function()? taskFileFor,
  Future<File?> Function()? logFileFor,
  DrivePendingWakeStore? wakeStore,
}) async {
  final db = ChatDatabase.open();
  final chatStore = ChatStore(db);
  final savedStore = SavedSessionStore(
    chatStore,
    keeper: const KeystoreSecretKeeper(),
  );
  final saved = await savedStore.load();
  if (saved == null || !saved.canAutoLogin) {
    await db.close();
    return null;
  }
  final trust = TrustPolicy.of(
    read: (k) => chatStore.setting(k),
    write: (k, v) => chatStore.setSetting(k, v),
    remove: (k) => chatStore.deleteSetting(k),
    all: () => chatStore.allSettings(),
  );
  await trust.load();
  final service = ConnectionService(trustPolicy: trust);
  final conn = await service.connect(saved.profile);
  // 会话名用 App 登录时同一档（`Chat`）——DSM 只把它当标签，sid 是全账号的
  await conn.api.login(
    account: saved.account,
    password: saved.password!,
    session: 'Chat',
    deviceId: saved.deviceId,
    enableDeviceToken: saved.rememberDevice,
  );
  final api = DriveApi(conn.api);
  final taskFile = await (taskFileFor ?? () async => defaultDriveSyncTasksFile())();
  final logFile = await (logFileFor ?? _defaultLogFile)();
  final store = JsonDriveSyncTaskStore(taskFile!);
  final wakes = wakeStore ?? JsonDrivePendingWakeStore(
    await defaultDrivePendingWakeFile(),
  );
  return DriveSyncBackgroundContext(
    store: store,
    api: api,
    scanLocal: scanDriveSyncLocal,
    now: DateTime.now,
    close: db.close,
    clearWakes: (roots) async {
      try {
        await wakes.removeAll(roots);
      } catch (_) {
        // 账本清不掉不影响本次同步结果
      }
    },
    logFile: logFile,
  );
}

/// 本地目录扫描（与前台 `driveSyncLocalScannerProvider` 同实现）。
///
/// 这里**复制**一份而不是 import 页面文件：页面文件牵出整套 UI/Riverpod 依赖，
/// 后台 isolate 不该为了一个扫描函数把它们全拉起来。两处行为由用例对齐。
Future<List<DriveSyncLocalEntry>> scanDriveSyncLocal(String localRoot) async {
  final root = Directory(normalizeDriveLocalRoot(localRoot));
  if (!await root.exists()) return const [];
  final out = <DriveSyncLocalEntry>[];
  final base = normalizeDriveLocalRoot(root.path);
  await for (final e in root.list(recursive: true, followLinks: false)) {
    var rel = e.path.replaceAll('\\', '/');
    if (rel.startsWith('$base/')) rel = rel.substring(base.length + 1);
    if (e is Directory) {
      out.add(
        DriveSyncLocalEntry(path: rel, isDir: true, size: 0, modifiedMs: 0),
      );
      continue;
    }
    if (e is! File) continue;
    final st = await e.stat();
    out.add(
      DriveSyncLocalEntry(
        path: rel,
        isDir: false,
        size: st.size,
        modifiedMs: st.modified.millisecondsSinceEpoch,
      ),
    );
  }
  return out;
}

/// 追加一条后台日志（只保留最近 20 条）。
Future<void> _appendLog(
  DriveSyncBackgroundContext ctx,
  DriveSyncBackgroundReport report,
) => _appendLogTo(ctx.logFile, ctx.now, report);

/// 追加一条后台日志（只保留最近 20 条；`.part` + rename 原子写）。
///
/// 与 [DriveSyncBackgroundContext] 解耦：**preflight 阶段（还没有依赖图）也要能记账**。
Future<void> _appendLogTo(
  File? f,
  DateTime Function() now,
  DriveSyncBackgroundReport report,
) async {
  if (f == null) return;
  try {
    final list = <Map<String, Object?>>[];
    if (await f.exists()) {
      final raw = jsonDecode(await f.readAsString());
      if (raw is List) {
        list.addAll(raw.whereType<Map>().map((e) => e.cast<String, Object?>()));
      }
    }
    list.insert(0, {
      'at': now().millisecondsSinceEpoch,
      ...report.toMap(),
    });
    if (list.length > 20) list.removeRange(20, list.length);
    await f.parent.create(recursive: true);
    final part = File('${f.path}.part');
    await part.writeAsString(jsonEncode(list), flush: true);
    await part.rename(f.path);
  } catch (_) {
    // 后台日志写不进去不影响同步本身
  }
}

/// 任务表落盘文件 —— **必须与前台 `defaultDriveSyncStoreFile()` 是同一个路径**
/// （`<documents>/drive_sync_tasks.json`；用例用"读源码"的方式钉住，见
/// `test/drive_background_sync_test.dart`）。
///
/// 这里不 import 页面文件（`drive_sync_tasks_page.dart` 会拖进整套 UI/Riverpod），
/// 后台 isolate 只为拿一个路径不值得。
Future<File> defaultDriveSyncTasksFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/drive_sync_tasks.json');
}

Future<File?> _defaultLogFile() async {
  try {
    final f = await defaultDriveSyncTasksFile();
    return File('${f.parent.path}/$kDriveSyncBackgroundLogFile');
  } catch (_) {
    return null;
  }
}
