// 相册备份的**共享编排**：准备（权限 → 目标目录 → 枚举 → 去重 → 计划）+ 跑完。
//
// 为什么单独抽出来：需求是"后台真正跑 Dart 备份逻辑，**复用现有上传器**而不是
// 重写一遍"。所以前台页面与后台 isolate 都只走这一条路：
//   * 前台：`prepare()` 拿回装好计划的 [PhotoBackupQueue]，自己 `start()` 以便
//     实时渲染每一项的进度/失败；
//   * 后台：`run()` = `prepare()` + `start()` + 等收尾 + 出报告。
// 两条路用的是**同一个** `PhotoBackupQueue`、同一个 `PhotoBackupUploader`、
// 同一套去重（`PhotoBackupPlanner` + 抽样 MD5 + 服务端哈希）。
//
// 并发：**恒为 1**（官方 `PhotoBackupManager.java:493` `ThreadPoolExecutor(1,1,…)`
// + `BackupExecutor.java:112-146` 串行 `peek()`；`docs/drive-parity-audit.md:278`）。
import 'dart:async';

import '../../data/media/device_media_library.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'photo_backup_queue.dart';
import 'photo_upload_quality.dart';
import 'photo_backup_target.dart';

/// 一轮备份的结局（后台要把它回给原生做成通知文案）。
class PhotoBackupRunReport {
  const PhotoBackupRunReport({
    required this.destination,
    required this.total,
    required this.done,
    required this.failed,
    required this.skipped,
    this.error,
  });

  final PhotoBackupDestination destination;
  final int total;
  final int done;
  final int failed;
  final int skipped;

  /// 准备阶段就失败时的原因（没权限/没连上/目标建不出来…）
  final String? error;

  bool get ok => error == null;

  Map<String, Object?> toMap() => {
    'ok': ok,
    'destination': destination.id,
    'total': total,
    'done': done,
    'failed': failed,
    'skipped': skipped,
    'error': error,
  };

  static PhotoBackupRunReport fromMap(Map<String, Object?>? map) {
    final m = map ?? const {};
    int i(String k) => (m[k] as num?)?.toInt() ?? 0;
    final error = '${m['error'] ?? ''}';
    return PhotoBackupRunReport(
      destination: PhotoBackupDestination.fromId(m['destination'] as String?),
      total: i('total'),
      done: i('done'),
      failed: i('failed'),
      skipped: i('skipped'),
      error: error.isEmpty ? null : error,
    );
  }
}

/// 共享编排器。
class PhotoBackupRunner {
  PhotoBackupRunner({
    required this.media,
    required this.uploader,
    required this.store,
    required this.targets,
    this.hasher = const NoopPhotoBackupHasher(),
    this.maxConcurrent = 1,
    this.maxAttempts = 2,
    this.assetLimit = 5000, // ★ D77：官方枚举上限 5000（旧值 2000）
    this.pageLimit = 200, // ★ D77：官方 200 个 id 一批
    PhotoUploadCompressor? compressor,
  }) : compressor = compressor ?? ImageUploadCompressor();

  final DeviceMediaLibrary media;
  final PhotoBackupUploader uploader;
  final PhotoBackupStore store;
  final PhotoBackupTargets targets;

  /// 内容哈希（抽样 MD5 + 全文件 MD4）
  final PhotoBackupHasher hasher;

  /// P43：上传质量压缩器（默认真实现；原图档时它内部直接返回原路径）
  final PhotoUploadCompressor compressor;

  /// **官方恒为 1**（严格串行）
  final int maxConcurrent;

  /// 单项最多试几次（>1 = 失败后自动再试；不做无限重试）
  final int maxAttempts;

  /// 本机相册枚举的**总上限**。
  ///
  /// ★ 官方（`drive-parity-audit.md:262`，`PBTaskManager.java:100-121`）：
  /// **按 200 个 id 一批**重查、目录枚举上限 **5000**。
  /// ⇒ 第 101 轮起改成"**分页 200、总上限 5000**"（D77），
  ///   不再是旧的单次 2000。
  final int assetLimit;

  /// 官方分页批大小（`PBTaskManager.java:100-121`：200 个 id 一批）。
  final int pageLimit;

  /// ★ D77：**分页枚举**本机相册 —— 每批 [pageLimit]（官方 200），
  /// 直到某批不满（已到底）或累计到 [assetLimit]（官方上限 5000）。
  ///
  /// 旧实现是单次 `limit: 2000`：超过 2000 张的相册**永远扫不全**，
  /// 且与官方"200/批、5000 上限"不符。
  Future<List<DeviceMediaAsset>> _enumerateAll(bool includeVideos) async {
    final out = <DeviceMediaAsset>[];
    while (out.length < assetLimit) {
      final batch = await media.list(
        includeVideos: includeVideos,
        limit: pageLimit,
        offset: out.length,
      );
      out.addAll(batch);
      if (batch.length < pageLimit) break; // 到底了
    }
    return out.length > assetLimit ? out.sublist(0, assetLimit) : out;
  }

  /// 组装本轮计划，返回**还没开跑**的队列。准备失败回 null 并给出原因。
  Future<({PhotoBackupQueue? queue, String? error, MediaPermission permission})>
  prepare(PhotoBackupSnapshot snapshot, {bool interactive = true}) async {
    var permission = MediaPermission.denied;
    try {
      permission = await media.ensurePermission(interactive: interactive);
      if (!permission.isUsable) {
        return (queue: null, error: 'permission', permission: permission);
      }
      var current = snapshot;
      final target = await targets.ensureTarget(
        current.destination,
        currentRef: current.targetFolderId,
        currentName: current.targetFolderName,
      );
      if (target.ref != current.targetFolderId ||
          target.name != current.targetFolderName) {
        current = current.copyWith(
          targetFolderId: target.ref,
          targetFolderName: target.name,
        );
        // 目标目录一旦确定就落盘：下次不用再探测/再建
        await store.save(current);
      }

      // ★ D72：当前结构交给落点层（上传时按拍摄时间落日期目录）
      targets.structure = current.structure;

      final assets = await _enumerateAll(current.includeVideos);
      // ★ D72：去重清单要**跨日期目录**列（结构 none 时等价旧行为）
      final remote = await targets.remoteEntriesForStructure(
        current.destination,
        ref: target.ref,
        assets: assets,
      );
      final planned = PhotoBackupPlanner.plan(
        assets: assets,
        doneKeys: current.doneKeys,
        remote: remote,
        includeVideos: current.includeVideos,
        // 官方恒扫 DCIM；可配置但默认 true
        dcimOnly: current.dcimOnly,
      );
      final remoteHashes = await targets.remoteHashes(
        current.destination,
        ref: target.ref,
      );
      final queue = PhotoBackupQueue(
        media: media,
        uploader: uploader,
        store: store,
        snapshot: current,
        maxConcurrent: maxConcurrent,
        maxAttempts: maxAttempts,
        hasher: hasher,
        remoteHashes: remoteHashes,
        // P43：上传质量档（原图档时压缩器内部直接返回原路径，零额外开销）
        compressor: compressor,
      )..load(planned);
      return (queue: queue, error: null, permission: permission);
    } catch (err) {
      targets.noteError(snapshot.destination, err);
      // 使用日志：备份准备失败（用户可见的失败分支；只记稳定原因码与错误类型，
      // 绝不把 message 写进埋点）
      trackOnceFailure(
        UsageModule.photos,
        UsageAction.upload,
        objectType: 'backup',
        reason: err is PhotoBackupNotConnectedException
            ? 'not_connected'
            : 'prepare_failed',
        error: err,
      );
      // 两类**可操作**的原因给稳定的机器可读标记；其余回原文，让调用方
      // 走 `describePhotoError` 那套错误码文案（那个出口已收敛到
      // `core/user_facing_error.dart`，原文只进诊断通道，不上界面）。
      final error = err is PhotoBackupNotConnectedException
          ? 'not-connected'
          : '$err';
      return (queue: null, error: error, permission: permission);
    }
  }

  /// 后台路径：准备 + 跑完 + 报告。
  Future<PhotoBackupRunReport> run(PhotoBackupSnapshot snapshot) async {
    final prepared = await prepare(snapshot, interactive: false);
    final queue = prepared.queue;
    if (queue == null) {
      return PhotoBackupRunReport(
        destination: snapshot.destination,
        total: 0,
        done: 0,
        failed: 0,
        skipped: 0,
        error: prepared.error ?? 'prepare-failed',
      );
    }
    try {
      final finished = Completer<void>();
      queue.onFinished = () {
        if (!finished.isCompleted) finished.complete();
      };
      // start() 可能在"没得传"时同步收尾，所以 onFinished 必须先挂上
      queue.start();
      await finished.future;
      final counts = queue.counts;
      return PhotoBackupRunReport(
        destination: snapshot.destination,
        total: counts.total,
        done: counts.done,
        failed: counts.failed,
        skipped: counts.skipped,
      );
    } finally {
      queue.dispose();
    }
  }
}
