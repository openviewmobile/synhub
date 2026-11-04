// `SYNO.SynologyDrive.FileRequest`（"请求文件" / File Request）的 VO。
//
// 权威来源（NAS 上装的 Synology Drive 4.2.0-30058 解包产物）：
//   * 方法表 `webapi/SYNO.SynologyDrive.lib` → `SYNO.SynologyDrive.FileRequest`
//     **v1** = `get delete update create list verify`，`allowUser` 含 `normal.*`
//     （`/tmp/spk/out/SynologyDrive.apis.txt:39-40`）；`.Public` v1 =
//     `auth get notify`（同文件 :42-43，authLevel=0）。
//   * 官方 `SYNO.SDS.Drive.WebAPIDesc`：
//     `list_file_request:{api:"SYNO.SynologyDrive.FileRequest",method:"list",version:1}`
//     `create_file_request` … `update_file_request` … `delete_file_request`
//     （`drive/synodrive_common.js:515851` 起）。
//   * 列表读字段（`ViewStore.FileRequest.getReaderFields`，
//     `drive/synodrive_common.js:496067`）逐个抄在下面；列表默认排序是
//     `{field:"created_time", direction:"DESC"}`，分页参数 `offset`/`limit`，
//     过滤参数是 `status`（`getBaseParams`/`getLoadParam`，同文件）。
//   * 列表列定义（`drive/synodrive_common.js:416046`）：
//     `file_request:["title","destination_folder","created_time","expire_time",
//     "file_request_status"]`。
//
// ⚠️ 未取证：`FileRequest/verify` **没有任何客户端调用点/参数原文**，故本仓库
// **不实现**（登记为待取证，见 docs/workspace-expansion-evaluation.md 实施记录）。
class DriveFileRequestDto {
  const DriveFileRequestDto({
    required this.fileId,
    required this.title,
    required this.description,
    required this.name,
    required this.displayPath,
    required this.destinationFolder,
    required this.dueDate,
    required this.hasDueDateHour,
    required this.fileRequestStatus,
    required this.isExpired,
    required this.identifier,
    required this.permanentLink,
    required this.sharingLink,
    required this.url,
    required this.uid,
    required this.createdTime,
    required this.modifiedTime,
  });

  /// `file_id`（列表里回的是字符串形态）
  final String fileId;

  /// `title`：请求的标题（列表主列）
  final String title;

  final String description;
  final String name;

  /// `display_path`：目标文件夹的展示路径
  final String displayPath;

  /// `destination_folder`：上传落地的文件夹
  final String destinationFolder;

  /// `due_date`：有效期（epoch 秒；0 = 不过期）
  final int dueDate;

  /// `has_due_date_hour`：有效期是否带"时:分"精度
  final bool hasDueDateHour;

  /// `file_request_status`：`active` / `inactive` / `error` / `readonly` …
  final String fileRequestStatus;

  /// `is_expired`：服务端判定的"已过期"（官方 `checkActiveFileRequest` 用它）
  final bool isExpired;

  /// `identifier`：上传者目录命名策略（官方两个取值见 file-request Vue 包）
  final String identifier;

  /// `permanent_link`：编辑时 `path` 用 `link:<permanent_link>`
  final String permanentLink;

  /// `sharing_link`：删除/编辑时回传的链接 id
  final String sharingLink;

  /// `url`：可直接分享的公开地址
  final String url;

  final String uid;
  final int createdTime;
  final int modifiedTime;

  /// 官方 `checkActiveFileRequest`（`drive/synodrive.js:92304`）：
  /// 未过期且状态不在 `[error, readonly, inactive]` 里才算"可编辑/可关闭"。
  bool get isActive =>
      !isExpired &&
      !const ['error', 'readonly', 'inactive'].contains(fileRequestStatus);

  static DriveFileRequestDto fromJson(Map<String, dynamic> json) =>
      DriveFileRequestDto(
        fileId: _str(json['file_id']),
        title: _str(json['title']).isEmpty
            ? _str(json['name'])
            : _str(json['title']),
        description: _str(json['description']),
        name: _str(json['name']),
        displayPath: _str(json['display_path']),
        destinationFolder: _str(json['destination_folder']),
        dueDate: _int(json['due_date']),
        hasDueDateHour: _bool(json['has_due_date_hour']),
        fileRequestStatus: _str(json['file_request_status']),
        isExpired: _bool(json['is_expired']),
        identifier: _str(json['identifier']),
        permanentLink: _str(json['permanent_link']),
        sharingLink: _str(json['sharing_link']),
        url: _str(json['url']),
        uid: _str(json['uid']),
        createdTime: _int(json['created_time']),
        modifiedTime: _int(json['modified_time']),
      );

  /// `{items, total}` 形态的回包（与 `Files/list` 一致）
  static ({List<DriveFileRequestDto> items, int total}) listFromJson(
    Map<String, dynamic> data,
  ) {
    final raw = (data['items'] as List?) ?? const [];
    final items = raw
        .whereType<Map>()
        .map((e) => DriveFileRequestDto.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
    return (items: items, total: _int(data['total']));
  }
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}

String _str(Object? v) => v == null ? '' : '$v';

bool _bool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return false;
}
