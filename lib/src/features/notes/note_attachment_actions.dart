// 笔记附件的两个本地动作（第 120 轮 / J9 真机可用性）：
//   * **用其他应用打开** —— 落盘后交给系统选择器（`ACTION_SEND`/`SEND_MULTIPLE`，
//     官方 DSnote 也是"下载后交给系统打开"，它没有内建预览器）；
//   * **保存到"下载"** —— 落盘后走原生 `saveToDownloads`（官方 smali 里
//     有两条同名分支：legacy 拷贝 / SAF）。
//
// 这两个动作都需要附件先在本地 —— 复用第 119 轮的缓存落盘（`Note/download` v1）。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/system_open.dart' show isTestEnvironment;
import '../../data/dto/note_dto.dart';
import '../../data/note_api.dart';
import '../files/file_link_share.dart' show TextShareBridge;
import 'note_attachment_cache.dart';
import 'note_storage_location.dart';

/// 附件动作的结果（页面按它给提示，**不假装成功**）。
enum NoteAttachmentActionOutcome { ok, noBridge, failed }

extension NoteAttachmentActionOutcomeX on NoteAttachmentActionOutcome {
  bool get isOk => this == NoteAttachmentActionOutcome.ok;
}

class NoteAttachmentActions {
  NoteAttachmentActions({
    TextShareBridge? bridge,
    bool? platformTouching,
    NoteStorageLocation Function()? storageLocation,
  }) : _bridge = bridge ?? const TextShareBridge(),
       // 测试环境默认**不碰平台通道**（与 note_mail 同一道门）
       _touch = platformTouching ?? !isTestEnvironment,
       _storageLocation = storageLocation;

  final TextShareBridge _bridge;
  final bool _touch;

  /// N9：附件落点（内部/外置）。为空时按"内部"处理（不碰平台通道）。
  final NoteStorageLocation Function()? _storageLocation;

  /// 用其他应用打开（系统选择器）。选择器本身"打开"由用户在系统里完成。
  Future<NoteAttachmentActionOutcome> openWith({
    required NoteStationApi api,
    required String noteId,
    required NoteAttachmentDto attachment,
    String? rootDir,
  }) async {
    final path = await _localPath(
      api: api,
      noteId: noteId,
      attachment: attachment,
      rootDir: rootDir,
    );
    if (path == null) return NoteAttachmentActionOutcome.failed;
    if (!_touch) return NoteAttachmentActionOutcome.noBridge;
    final ok = await _bridge.shareFiles(
      paths: [path],
      subject: attachment.name,
      mime: attachment.type.isEmpty ? '*/*' : attachment.type,
    );
    return ok ? NoteAttachmentActionOutcome.ok : NoteAttachmentActionOutcome.noBridge;
  }

  /// 保存到系统"下载"目录。
  Future<NoteAttachmentActionOutcome> saveToDownloads({
    required NoteStationApi api,
    required String noteId,
    required NoteAttachmentDto attachment,
    String? rootDir,
  }) async {
    final path = await _localPath(
      api: api,
      noteId: noteId,
      attachment: attachment,
      rootDir: rootDir,
    );
    if (path == null) return NoteAttachmentActionOutcome.failed;
    if (!_touch) return NoteAttachmentActionOutcome.noBridge;
    final ok = await _bridge.saveToDownloads(
      path: path,
      name: safeAttachmentName(attachment.name),
      mime: attachment.type.isEmpty ? '*/*' : attachment.type,
    );
    return ok ? NoteAttachmentActionOutcome.ok : NoteAttachmentActionOutcome.noBridge;
  }

  Future<String?> _localPath({
    required NoteStationApi api,
    required String noteId,
    required NoteAttachmentDto attachment,
    String? rootDir,
  }) async {
    try {
      // ★ N9（235 轮）：没显式给目录时按设置解析（内部/外置；外置不可用会
      // 回退内部，`fellBack` 由调用方决定要不要提示）。
      var root = rootDir;
      if (root == null) {
        final resolved = await resolveNoteStorageRoot(
          _storageLocation?.call() ?? NoteStorageLocation.internal,
        );
        root = resolved.path.isEmpty ? null : resolved.path;
      }
      return await downloadNoteAttachmentToCache(
        api: api,
        noteId: noteId,
        attachment: attachment,
        rootDir: root,
      );
    } catch (e) {
      debugPrint('[notes] 附件下载失败：$e');
      return null;
    }
  }
}

final noteAttachmentActionsProvider = Provider<NoteAttachmentActions>(
  (ref) => NoteAttachmentActions(),
);
