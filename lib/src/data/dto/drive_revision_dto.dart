// Drive 版本（`SYNO.SynologyDrive.Revisions`）的 VO。
//
// 权威来源：真机实测（`tool/drive_p3_impl_probe.dart` / `drive_p3_shape2.dart`，
// 2026-09-19），形状逐字对齐官方 Web 客户端（`drive/synodrive_common.js` 的
// `SYNO.SDS.Drive.WebAPIDesc`：`list_revisions`/`restore_revisions`/
// `download_revisions` 全是 `Revisions` **v1**）。
//
// 回包：`{items:[{version_id, size, created_time, modified_time, hash,
//               editor_uid, editor_display_name, editor_nickname, editors}], total}`
// `version_id` 是**服务端全局递增的变更号**（不是 1/2/3 这种局部序号）。
import '../../core/i18n/data_text.dart';
import 'drive_entry_dto.dart' show driveHumanSize;

class DriveRevisionDto {
  const DriveRevisionDto({
    required this.versionId,
    required this.size,
    required this.createdTime,
    required this.modifiedTime,
    required this.hash,
    required this.editorName,
    required this.editorNickname,
  });

  /// `version_id`（字符串形态；请求时原样回传）
  final String versionId;
  final int size;
  final int createdTime;
  final int modifiedTime;
  final String hash;

  /// `editor_display_name`（空则退到 `editor_nickname`）
  final String editorName;
  final String editorNickname;

  /// 展示用的编辑人：官方 Web 端把 `#` 开头的 uid 翻译成"已删除用户"
  ///
  /// 数据层走 `data_text.dart`（docs §4.6）；没装翻译器回落中文原文。
  String get editorLabel {
    final n = editorName.isEmpty ? editorNickname : editorName;
    if (n.isEmpty) return '';
    if (n.startsWith('#')) return dataText('dtoEditorDeleted', '已删除用户');
    return n;
  }

  String get humanSize => driveHumanSize(size);

  /// 已不是最新版本（`Files/get` 的 `version_id` 与之一致的就是最新）
  bool isCurrent(String currentVersionId) =>
      currentVersionId.isNotEmpty && currentVersionId == versionId;

  static List<DriveRevisionDto> listFromJson(Map<String, dynamic> data) {
    final raw = (data['items'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => DriveRevisionDto.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  static DriveRevisionDto fromJson(Map<String, dynamic> json) =>
      DriveRevisionDto(
        versionId: '${json['version_id'] ?? ''}',
        size: _int(json['size']),
        createdTime: _int(json['created_time']),
        modifiedTime: _int(json['modified_time']),
        hash: '${json['hash'] ?? ''}',
        editorName: '${json['editor_display_name'] ?? ''}',
        editorNickname: '${json['editor_nickname'] ?? ''}',
      );
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}
