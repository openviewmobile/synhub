// 相册「释放手机空间」的**纯逻辑层**：从"本机相册 + 备份账本 + NAS 清单"算出
// 哪些本地照片**已经安全备份过**、可以删掉本地副本，以及可释放多少字节。
//
// 本文件不碰 UI、不碰 `dart:io`、不 import l10n —— 离线单测直接构造即可。
//
// ## 判定口径：**复用相机备份，不另建一套记录**
//
// 这里直接调用 [PhotoBackupPlanner.plan]：相机备份用来"不重复上传"的判据，
// 正是"NAS 上已经有同一张"的判据 ——
//   * [BackupSkipReason.alreadyDone] —— 本地账本里记着这张**精确到这个文件**
//     （`stableKey` = 相对路径 + 文件名 + 大小 + 拍摄时间）已成功上传；
//   * [BackupSkipReason.existsOnNas] —— 目标相册里已有**同名 + 同大小**的文件
//     （官方 `BackupExecutor` 同款去重口径，见 `photo_backup_queue.dart`）。
//
// 其余结局（`pending` / `uploading` / `failed` / `videoExcluded` / `null`）一律
// **不算已备份** ⇒ 绝不进候选。**未备份的照片绝不删。**
//
// ## 宁少删不多删：备份口径之上再加两道**只收紧**的阀门
//
//   * ① `existsOnNas` 要求 `size > 0` —— 0 字节的清单条目不算证据；
//     （`stableKey` 精确到大小，已隐含同一条要求。）
//   * ② 只认上面那两条 [BackupSkipReason]，别的跳过原因一律不算。
//
// 这两道阀门只能让候选**变少**，不可能让一张"备份还没确认"的照片被误删。
//
// ## ⚠️ 与相机备份共用同一份"范围"设置
//
// [dcimOnly] / [includeVideos] 必须传**相机备份那一份快照**里的值：备份没扫到
// 的范围（比如关掉了视频备份时的视频、`dcimOnly` 时的截图目录）本来就没上传，
// 拿它们当"已备份"就是误判。
import 'package:flutter/foundation.dart';

import '../../data/media/device_media_library.dart';
import 'photo_backup_queue.dart';

/// 一张本地照片"为什么可以删"（都是"已备份"的子类）。
enum FreeUpReason {
  /// 本机备份记录记着这张已成功上传（最硬的证据）
  backupLedger,

  /// NAS 目标相册里已有同名 + 同大小的文件
  remoteListing,
}

/// 一条可释放项（本地照片 + 它被判定的依据 + 执行结局）。
class FreeUpEntry {
  FreeUpEntry(this.asset, this.reason);

  final DeviceMediaAsset asset;
  final FreeUpReason reason;

  /// 执行结局（默认还没动过）
  FreeUpEntryOutcome outcome = FreeUpEntryOutcome.pending;

  /// 这一项真实被删掉了吗（只有 [FreeUpEntryOutcome.deleted] 才算）
  bool get isDeleted => outcome == FreeUpEntryOutcome.deleted;
}

/// 一项在执行后的结局。
enum FreeUpEntryOutcome {
  /// 还没处理 / 用户取消了
  pending,

  /// 系统确认后真的删掉了
  deleted,

  /// 保留（用户拒绝、或不支持代删、或执行失败）
  kept,
}

/// 一次扫描的计划结果。
@immutable
class FreeUpPlan {
  const FreeUpPlan({
    required this.entries,
    required this.scannedCount,
    required this.keptCount,
  });

  /// 可安全删除的本地照片（**只含已备份的**）
  final List<FreeUpEntry> entries;

  /// 本轮枚举到的本机照片总数
  final int scannedCount;

  /// 因"备份未确认"而**明确保留**的张数（绝不删）
  final int keptCount;

  /// 可释放的字节数（**只统计候选**，不是整个相册）
  int get reclaimableBytes =>
      entries.fold(0, (sum, e) => sum + (e.asset.size < 0 ? 0 : e.asset.size));

  int get reclaimableCount => entries.length;

  bool get isEmpty => entries.isEmpty;
}

/// 释放空间的计划器（纯函数，无副作用）。
abstract final class PhotoFreeUpPlanner {
  const PhotoFreeUpPlanner._();

  /// 相机备份里被认定为"NAS 上已经有了"的两条跳过原因 —— **这就是**本功能的
  /// 判定口径，别的跳过原因不算。
  static const Set<BackupSkipReason> backedUpReasons = {
    BackupSkipReason.alreadyDone,
    BackupSkipReason.existsOnNas,
  };

  /// [assets] 已按拍摄时间倒序；[doneKeys] 是当前落点的本地账本；
  /// [remote] 是目标相册现有内容。
  ///
  /// ⚠️ [dcimOnly] / [includeVideos] 必须与相机备份那一份快照一致。
  static FreeUpPlan plan({
    required List<DeviceMediaAsset> assets,
    required Set<String> doneKeys,
    required List<RemotePhotoEntry> remote,
    bool includeVideos = true,
    bool dcimOnly = true,
  }) {
    // 直接复用相机备份的计划器 —— 判定逻辑**只有一份**。
    final planned = PhotoBackupPlanner.plan(
      assets: assets,
      doneKeys: doneKeys,
      remote: remote,
      includeVideos: includeVideos,
      dcimOnly: dcimOnly,
    );
    final entries = <FreeUpEntry>[];
    var kept = 0;
    var scanned = 0;
    for (final item in planned) {
      scanned++;
      if (item.state != BackupItemState.skipped) {
        // 还没传 / 传失败 / 正在传 → **保留**
        kept++;
        continue;
      }
      final reason = item.skipReason;
      if (reason == null || !backedUpReasons.contains(reason)) {
        // `videoExcluded` 之类的"没进备份范围"→ **保留**
        kept++;
        continue;
      }
      if (reason == BackupSkipReason.existsOnNas && item.asset.size <= 0) {
        // 额外保守阀门：0 字节清单条目不算证据 → **保留**
        kept++;
        continue;
      }
      entries.add(
        FreeUpEntry(
          item.asset,
          reason == BackupSkipReason.alreadyDone
              ? FreeUpReason.backupLedger
              : FreeUpReason.remoteListing,
        ),
      );
    }
    return FreeUpPlan(
      entries: entries,
      scannedCount: scanned,
      keptCount: kept,
    );
  }
}
