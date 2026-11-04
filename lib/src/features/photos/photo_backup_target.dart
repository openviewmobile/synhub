// 相册备份的**落点抽象**：两个落点的"目标目录 / 去重清单 / 上传"三件事。
//
// 落点事实（逐字证据）：
//   * **Drive**（官方相机备份的落点）：`/mydrive/PhotoBackup/<设备名>/`
//     —— `docs/drive-parity-audit.md:264`（`BackupTarget.java:177-190` +
//     `Constants.java:33 MYDRIVE_PATH="/mydrive"` + `strings.xml:1844
//     photo_backup_folder_name="PhotoBackup"`）；上传 `SYNO.SynologyDrive.Photos`
//     `upload`（`docs/api-server-authoritative.md:785` 服务端注册表 +
//     `ApiSynoDrivePhotos.java:162-187` 客户端参数）。
//   * **Synology Photos**（我们历史落点）：`Browse.Folder` 下的「手机备份」目录
//     + `Upload.Item/upload_to_folder`（`docs/photo-parity-audit.md` §4.2）。
//
// **统一降级规则**（用户钦定，不许删）：
//   * `105`（noPermission）/ `160`（noAppPrivilege）→ 该选项**隐藏** + 原因；
//   * `102`（apiNotFound，套件没装）/ `103`（methodNotFound）→ **只影响该选项**
//     （置灰），另一个落点照常可用；
//   * 没连上 NAS → 两个都置灰。
// 区分"隐藏"与"置灰"是刻意的：105/160 是账号级确定性拒绝，留着入口点了也只会
// 反复报错；102/103 是这台 NAS 上没这套件，但用户换一台 NAS 就有了 —— 入口留着
// 并说明原因更有用。
import '../../core/i18n/l10n.dart';
import '../../data/drive_api.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/foto_api.dart';
import '../../data/media/device_media_library.dart';
import '../../dsm/webapi.dart';
import 'photo_backup_queue.dart';
import 'photo_backup_text.dart';

/// 未选目标时的兜底目录名（原 `photo_backup_page.dart` 的默认值，保持原字面量）
const String kPhotoBackupDefaultFolder = '手机备份';

/// 一个落点当前能不能用、为什么不能用。
enum PhotoBackupTargetGate {
  /// 可用
  ready,

  /// 没连上 NAS（两个落点都置灰）
  notConnected,

  /// `102`/`103`：这台 NAS 上没有这套服务/方法（**只影响该选项**，置灰）
  missingService,

  /// `105`/`160`：账号无权限（**隐藏该选项** + 给原因）
  noPermission;

  bool get isUsable => this == PhotoBackupTargetGate.ready;

  /// 105/160 → 隐藏；其它不可用状态 → 置灰（仍显示入口与原因）。
  bool get isHidden => this == PhotoBackupTargetGate.noPermission;
}

/// 一个落点的可用性快照。
class PhotoBackupTargetInfo {
  const PhotoBackupTargetInfo({
    required this.destination,
    required this.gate,
    this.reason = '',
  });

  final PhotoBackupDestination destination;
  final PhotoBackupTargetGate gate;

  /// 给人看的原因（[gate] 为 [PhotoBackupTargetGate.ready] 时为空）
  final String reason;

  bool get isUsable => gate.isUsable;
  bool get isHidden => gate.isHidden;
}

/// 目标目录的落点坐标（`ref` 对 Photos 是 folder id，对 Drive 是目录路径）。
typedef PhotoBackupTargetRef = ({String ref, String name});

/// 落点所在的 NAS 还没连上。
///
/// 单独一个类型是为了让调用方能给**明确的指引**（"还没连接"），而不是把
/// `StateError` 的 `Bad state:` 前缀当文案贴到界面上。`toString()` 直接回
/// 人话，后台报告/通知文案也能复用。
class PhotoBackupNotConnectedException implements Exception {
  const PhotoBackupNotConnectedException([this.reason = '']);

  final String reason;

  @override
  String toString() => reason.isEmpty ? '还没连接 NAS' : reason;
}

/// 两个落点的操作集。
///
/// 三个 `*Of` 是**取当前连接**的回调（provider 侧绑 `ref.read`，测试侧直接给假
/// 对象）：会话中途重连/换空间不会拿到过期 API（与既有
/// `FotoBackupUploaderAdapter` 同一套路）。
class PhotoBackupTargets {
  PhotoBackupTargets({
    required this.fotoOf,
    required this.driveOf,
    required this.deviceNameOf,
  });

  /// 当前个人空间的 `SYNO.Foto.*` API（未连接 → null）
  final FotoApi? Function() fotoOf;

  /// 当前 `SYNO.SynologyDrive.*` API（未连接 → null）
  final DriveApi? Function() driveOf;

  /// 本机设备名（Drive 的设备子目录名；原生 `Build.MODEL`）
  final String Function() deviceNameOf;

  /// ★ D72 **当前生效的备份目录结构**（官方 `BackupStructure`）。
  ///
  /// 由 [PhotoBackupRunner.prepare] 按当前快照写入（`current.structure`）——
  /// 之所以做成可变字段而不是构造参数：两个落点共用同一个
  /// [PhotoBackupTargets] 实例，而结构属于**每落点快照**（切换落点要跟着换）。
  /// 默认 `none`：**没经 runner 的调用方/老用例行为不变**；
  /// 真实运行路径一定会先过 runner，所以默认值不会漏进用户路径。
  DriveBackupStructure structure = DriveBackupStructure.none;

  /// 运行期探测到的降级（key = 落点 id）。
  final Map<PhotoBackupDestination, PhotoBackupTargetGate> _runtimeGate = {};

  /// 把一次真实调用的错误码折进降级状态（只升不降：`ready` 之外的都留着，
  /// 会话重连后由 [resetGates] 清）。
  void noteError(PhotoBackupDestination destination, Object error) {
    if (error is! DsmApiException) return;
    final gate = _gateForCode(error.code);
    if (gate == null) return;
    _runtimeGate[destination] = gate;
  }

  void resetGates() => _runtimeGate.clear();

  /// 错误码 → 降级档；不认识的码回 null（不改状态）。
  static PhotoBackupTargetGate? _gateForCode(int code) {
    if (code == DsmErrorCode.noPermission ||
        code == DsmErrorCode.noAppPrivilege) {
      return PhotoBackupTargetGate.noPermission;
    }
    if (code == DsmErrorCode.apiNotFound ||
        code == DsmErrorCode.methodNotFound) {
      return PhotoBackupTargetGate.missingService;
    }
    return null;
  }

  /// 这个落点现在能不能用。**先看运行期探测**（真实调用说过不行就是不行），
  /// 再看能力表里有没有这个 API。
  PhotoBackupTargetInfo info(PhotoBackupDestination destination) {
    final runtime = _runtimeGate[destination];
    if (runtime != null) {
      return PhotoBackupTargetInfo(
        destination: destination,
        gate: runtime,
        reason: _reasonFor(destination, runtime),
      );
    }
    switch (destination) {
      case PhotoBackupDestination.synologyPhotos:
        final api = fotoOf();
        if (api == null) {
          return PhotoBackupTargetInfo(
            destination: destination,
            gate: PhotoBackupTargetGate.notConnected,
            reason: currentText().setNotConnected,
          );
        }
        // 服务端注册表里没有 `Upload.Item` → 这套照片服务没装/不支持备份上传
        if (api.api.apiTable != null &&
            !api.api.apiTable!.containsKey('${api.space.prefix}Upload.Item')) {
          return PhotoBackupTargetInfo(
            destination: destination,
            gate: PhotoBackupTargetGate.missingService,
            reason: pbText(
              PhotoBackupTextKeys.targetPhotosMissing,
              '这台 NAS 上没装/不支持 Synology Photos 备份上传',
            ),
          );
        }
        return PhotoBackupTargetInfo(
          destination: destination,
          gate: PhotoBackupTargetGate.ready,
        );
      case PhotoBackupDestination.drive:
        final api = driveOf();
        if (api == null) {
          return PhotoBackupTargetInfo(
            destination: destination,
            gate: PhotoBackupTargetGate.notConnected,
            reason: currentText().setNotConnected,
          );
        }
        if (api.api.apiTable != null &&
            !api.api.apiTable!.containsKey('SYNO.SynologyDrive.Photos')) {
          return PhotoBackupTargetInfo(
            destination: destination,
            gate: PhotoBackupTargetGate.missingService,
            reason: pbText(
              PhotoBackupTextKeys.targetDriveMissing,
              '这台 NAS 上没装/不支持 Synology Drive 照片上传',
            ),
          );
        }
        return PhotoBackupTargetInfo(
          destination: destination,
          gate: PhotoBackupTargetGate.ready,
        );
    }
  }

  static String _reasonFor(
    PhotoBackupDestination destination,
    PhotoBackupTargetGate gate,
  ) => switch (gate) {
    PhotoBackupTargetGate.ready => '',
    PhotoBackupTargetGate.notConnected => currentText().setNotConnected,
    PhotoBackupTargetGate.missingService =>
      destination == PhotoBackupDestination.drive
          ? pbText(
              PhotoBackupTextKeys.targetDriveMissing,
              '这台 NAS 上没装/不支持 Synology Drive 照片上传',
            )
          : pbText(
              PhotoBackupTextKeys.targetPhotosMissing,
              '这台 NAS 上没装/不支持 Synology Photos 备份上传',
            ),
    PhotoBackupTargetGate.noPermission => pbText(
      PhotoBackupTextKeys.targetNoPermission,
      '当前账号没有这个备份落点的权限',
    ),
  };

  /// 确保目标目录存在，返回落点坐标。
  ///
  /// * Photos：沿用老逻辑 —— 已经选过就复用；否则找「手机备份」相册，没有就在
  ///   个人空间根目录建一个（`kPhotoBackupDefaultFolder`）。
  /// * Drive：`/mydrive/PhotoBackup/` 与设备子目录缺就建
  ///   （`DriveApi.ensurePhotoBackupFolder`，官方 `ensureBackupFolder` 同构）。
  Future<PhotoBackupTargetRef> ensureTarget(
    PhotoBackupDestination destination, {
    required String currentRef,
    required String currentName,
  }) async {
    if (currentRef.isNotEmpty) {
      return (ref: currentRef, name: currentName);
    }
    switch (destination) {
      case PhotoBackupDestination.synologyPhotos:
        final api = fotoOf();
        if (api == null) {
          throw PhotoBackupNotConnectedException(currentText().setNotConnected);
        }
        final folders = await api.folders();
        final existing = folders
            .where((f) => f.name == kPhotoBackupDefaultFolder)
            .firstOrNull;
        if (existing != null) {
          return (ref: existing.id, name: existing.name);
        }
        final root = await api.folderRoot();
        final created = await api.createFolder(
          parentId: root.id,
          name: kPhotoBackupDefaultFolder,
        );
        return (ref: created.id, name: created.name);
      case PhotoBackupDestination.drive:
        final api = driveOf();
        if (api == null) {
          throw PhotoBackupNotConnectedException(currentText().setNotConnected);
        }
        final path = await api.ensurePhotoBackupFolder(device: deviceNameOf());
        return (ref: path, name: path.split('/').last);
    }
  }

  /// 目标目录里已有的文件（文件名 + 大小），给 `PhotoBackupPlanner` 去重。
  Future<List<RemotePhotoEntry>> remoteEntries(
    PhotoBackupDestination destination, {
    required String ref,
  }) async {
    if (ref.isEmpty) return const [];
    switch (destination) {
      case PhotoBackupDestination.synologyPhotos:
        final api = fotoOf();
        if (api == null) return const [];
        final List<FotoItemDto> items;
        try {
          items = await api.folderItems(ref, limit: 1000);
        } catch (err) {
          noteError(destination, err);
          return const [];
        }
        return [
          for (final item in items)
            RemotePhotoEntry(name: item.filename, size: item.filesize),
        ];
      case PhotoBackupDestination.drive:
        final api = driveOf();
        if (api == null) return const [];
        try {
          final entries = await api.photoBackupRemoteEntries(folderPath: ref);
          return [
            for (final e in entries)
              RemotePhotoEntry(name: e.name, size: e.size),
          ];
        } catch (err) {
          noteError(destination, err);
          return const [];
        }
    }
  }

  /// 服务端已有的**内容哈希**（`name|size` → hash），给全文件 MD4 比对用。
  ///
  /// ⚠️ **生产侧目前恒为空**，如实登记：`Browse.Item/list` 与 `Files/list` 的
  /// 响应里都**没有**内容哈希字段，`SYNO.SynologyDrive.Photos:get_metadata`
  /// 只有方法名原文、请求/响应结构未取证 —— 不许编。所以"服务端哈希"这条腿
  /// 只在调用方真的拿得到哈希时才生效（单测用注入的映射钉住逻辑）。
  /// ★ D72：**按当前结构**去重用的远端清单。
  ///
  /// 结构为 `none` 时等价于 [remoteEntries]；否则把**本批资产各自会落到的
  /// 日期目录**（`assets` 的拍摄时间 → `yyyy[/MM]`）连同设备根目录一起列出，
  /// 合并去重（`name|size`）—— 否则已经传进 `2026/09` 的文件会被再传一次。
  Future<List<RemotePhotoEntry>> remoteEntriesForStructure(
    PhotoBackupDestination destination, {
    required String ref,
    required List<DeviceMediaAsset> assets,
  }) async {
    if (destination != PhotoBackupDestination.drive ||
        structure == DriveBackupStructure.none ||
        assets.isEmpty) {
      return remoteEntries(destination, ref: ref);
    }
    final api = driveOf();
    if (api == null) return const [];
    final folders = <String>{ref};
    for (final a in assets) {
      folders.add(
        DriveApi.photoBackupFolderPathFor(
          device: deviceNameOf(),
          structure: structure,
          taken: DateTime.fromMillisecondsSinceEpoch(a.takenTimeMs),
        ),
      );
    }
    final out = <RemotePhotoEntry>[];
    final seen = <String>{};
    for (final folder in folders) {
      if (folder.isEmpty) continue;
      try {
        for (final e in await api.photoBackupRemoteEntries(folderPath: folder)) {
          if (seen.add('${e.name}|${e.size}')) {
            out.add(RemotePhotoEntry(name: e.name, size: e.size));
          }
        }
      } catch (err) {
        noteError(destination, err);
      }
    }
    return out;
  }

  Future<Map<String, String>> remoteHashes(
    PhotoBackupDestination destination, {
    required String ref,
  }) async => const {};
}

/// 按落点分派的上传器（前台队列与后台 isolate 共用同一个实现）。
class DestinationPhotoBackupUploader implements PhotoBackupUploader {
  DestinationPhotoBackupUploader(this.targets);

  final PhotoBackupTargets targets;

  @override
  Future<String> upload({
    required DeviceMediaAsset asset,
    required String localPath,
    required String targetFolderId,
    required PhotoBackupDestination destination,
    void Function(int sent, int total)? onProgress,
  }) async {
    try {
      switch (destination) {
        case PhotoBackupDestination.synologyPhotos:
          final api = targets.fotoOf();
          if (api == null) {
            throw PhotoBackupNotConnectedException(
              currentText().setNotConnected,
            );
          }
          return await api.uploadToFolder(
            folderId: targetFolderId,
            filePath: localPath,
            fileName: asset.displayName,
            mtimeMs: asset.modifiedTimeMs,
            mimeType: asset.mimeType.isEmpty ? null : asset.mimeType,
            onProgress: onProgress,
          );
        case PhotoBackupDestination.drive:
          final api = targets.driveOf();
          if (api == null) {
            throw PhotoBackupNotConnectedException(
              currentText().setNotConnected,
            );
          }
          // ★ D72：官方 `PhotoBackupManager:1596-1600` 把
          // `BackupStructure.getStructure(asset.getTakenTime())` 拼在设备目录后
          // ⇒ 每条资产按**自己的拍摄时间**落年/年月目录（可能跨目录）。
          var folder = targetFolderId;
          if (targets.structure != DriveBackupStructure.none) {
            folder = await api.ensurePhotoBackupFolderFor(
              device: targets.deviceNameOf(),
              structure: targets.structure,
              taken: DateTime.fromMillisecondsSinceEpoch(asset.takenTimeMs),
            );
          }
          final result = await api.uploadPhotoForBackup(
            folderPath: folder,
            filePath: localPath,
            fileName: asset.displayName,
            modifiedTimeMs: asset.modifiedTimeMs,
            mimeType: asset.mimeType.isEmpty ? null : asset.mimeType,
            onProgress: onProgress,
          );
          return result.id;
      }
    } catch (err) {
      targets.noteError(destination, err);
      rethrow;
    }
  }
}
