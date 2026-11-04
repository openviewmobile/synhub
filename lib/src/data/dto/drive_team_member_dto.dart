// `SYNO.SynologyDrive.TeamFolders/list_members`（团队文件夹成员）的 VO。
//
// 原文证据（NAS 上装的 Synology Drive 4.2.0-30058 解包产物）：
//   * 方法表 `webapi/SYNO.SynologyDrive.lib` → `SYNO.SynologyDrive.TeamFolders`
//     **v1** = `list list_members`，authLevel=2，`allowUser` 含 `normal.*`
//     （`/tmp/spk/out/SynologyDrive.apis.txt:181-182`）。
//   * 官方 `SYNO.SDS.Drive.WebAPIDesc.list_team_folders_members` =
//     `{api:"SYNO.SynologyDrive.TeamFolders", version:1, method:"list_members"}`
//     （`drive/synodrive_common.js:511427`）。
//   * **参数原文**：成员 grid store 的 baseParams
//     `{team_id: this.rec.get("team_id"), offset: 0, limit: this.pageSize}`
//     且 `pageSize=100`（`drive/synodrive_common.js:225431`）。
//   * 读字段原文：`[{name:"display_name"},{name:"name"},{name:"uid"},{name:"role"}]`
//     （同上一处）。回包 root 是 `items`。
class DriveTeamMemberDto {
  const DriveTeamMemberDto({
    required this.name,
    required this.displayName,
    required this.uid,
    required this.role,
  });

  /// `name`：账号名
  final String name;

  /// `display_name`：显示名（官方列表优先显示它）
  final String displayName;

  /// `uid`
  final String uid;

  /// `role`：官方团队文件夹里的权限角色串
  final String role;

  /// 显示用名字
  String get label => displayName.isEmpty ? name : displayName;

  static DriveTeamMemberDto fromJson(Map<String, dynamic> json) =>
      DriveTeamMemberDto(
        name: _str(json['name']),
        displayName: _str(json['display_name']),
        uid: _str(json['uid']),
        role: _str(json['role']),
      );

  static List<DriveTeamMemberDto> listFromJson(Map<String, dynamic> data) {
    final raw = (data['items'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => DriveTeamMemberDto.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  static String _str(Object? v) => v == null ? '' : '$v';
}
