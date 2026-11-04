// Drive 共享（`SYNO.SynologyDrive.Sharing`）的 VO：成员权限 + 公开链接。
//
// 权威来源：官方 Android 端 `ApiSynoDriveSharing.setAsUpdate/convertMemberInfo/
// convertPermissionRecordTo(Update|Delete)` 的形状 + 真机双向实测
// （`tool/drive_share_probe.dart`，2026-09-19）：
//   * 邀请/改权限：`Sharing/update` v1
//       `{path:'id:<file_id>', permissions:'[{"action":"update",
//         "member":{"type":"user"|"group","name":"<账号>"},"role":"viewer"}]'}`
//     → 回 `{}`；`Sharing/list` 立刻能看到该成员；
//   * 移除：把 `action` 换成 `"delete"`（`member` 保留、`role` 不要）→ `{}`；
//   * `Sharing/list` v1：`{path, offset, limit}` →
//       `{items:[{permission_id, name, type:'user'|'group', role, inherited}], total}`
//   * 公开链接：`Sharing/create_link` v1 `{path:'id:<file_id>'}` → `{url}`。
import '../../core/i18n/data_text.dart';

/// 权限角色（官方 Web 的 role 词表；`internal`/`public` 是分享类型不是角色）
enum DriveShareRole {
  viewer('viewer', '仅查看'),
  previewer('previewer', '仅预览'),
  commenter('commenter', '可评论'),
  previewCommenter('preview_commenter', '仅预览+评论'),
  editor('editor', '可编辑'),
  organizer('organizer', '可管理');

  const DriveShareRole(this.value, this.label);
  final String value;

  /// 中文回落（界面侧读 [labelText]；`lib/src/features/**` 本轮不在迁移范围内）
  final String label;

  /// ARB key（多语言用；数据层不能碰 `AppText`）
  String get labelKey => switch (this) {
    DriveShareRole.viewer => 'dtoShareRoleViewer',
    DriveShareRole.previewer => 'dtoShareRolePreviewer',
    DriveShareRole.commenter => 'dtoShareRoleCommenter',
    DriveShareRole.previewCommenter => 'dtoShareRolePreviewComment',
    DriveShareRole.editor => 'dtoCanEdit',
    DriveShareRole.organizer => 'dtoShareRoleOrganizer',
  };

  /// 当前语言文案（走 `data_text.dart` 的 [dataText]；没装翻译器时回落 [label]）
  String labelText() => dataText(labelKey, label);

  static DriveShareRole fromValue(String v) => values.firstWhere(
    (e) => e.value == v,
    orElse: () => DriveShareRole.viewer,
  );
}

/// 共享成员（用户或群组）
class DriveShareDto {
  const DriveShareDto({
    required this.permissionId,
    required this.name,
    required this.type,
    required this.role,
    required this.inherited,
  });

  final String permissionId;

  /// 账号名或群组名（官方回包就是 `name`，没有 display/nickname）
  final String name;

  /// `user` / `group`
  final String type;
  final DriveShareRole role;

  /// 从上级目录继承来的权限（不能在这里单独改）
  final bool inherited;

  bool get isGroup => type == 'group';

  static List<DriveShareDto> listFromJson(Map<String, dynamic> data) {
    final raw = (data['items'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => DriveShareDto.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  static DriveShareDto fromJson(Map<String, dynamic> json) => DriveShareDto(
    permissionId: '${json['permission_id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    type: '${json['type'] ?? 'user'}',
    role: DriveShareRole.fromValue('${json['role'] ?? 'viewer'}'),
    inherited: json['inherited'] == true,
  );
}

/// 一条"邀请/移除"指令（`permissions` 数组里的一项）
class DriveShareChange {
  const DriveShareChange.invite({
    required this.name,
    required this.type,
    required this.role,
  }) : remove = false,
       assert(true);

  const DriveShareChange.remove({required this.name, required this.type})
    : role = DriveShareRole.viewer,
      remove = true;

  final String name;

  /// `user` / `group`
  final String type;
  final DriveShareRole role;
  final bool remove;

  Map<String, dynamic> toJson() => {
    'action': remove ? 'delete' : 'update',
    'member': {'type': type, 'name': name},
    if (!remove) 'role': role.value,
  };
}

/// 高级共享（`SYNO.SynologyDrive.AdvanceSharing`）的**公开链接**信息。
///
/// 原文证据（`/tmp/spk/export_SynologyDrive/drive/synodrive_common.js`）：
///   * 描述符 `get_adv_sharing` = `{api:"SYNO.SynologyDrive.AdvanceSharing",
///     method:"get", version:1}`（`:514992` 起），调用参数 `{path}`（`:294847`）；
///   * 回包字段由 `_onSetLinkInfo`（`:294700` 附近）逐字读出：`url`、`role`、
///     `protect_password`、`due_date`，另有 `sharing_link` 供 update/delete 回传；
///   * `role` 还会出现 `previewer`/`preview_commenter`（官方在 UI 里把它映射回
///     `viewer`/`commenter` 并把"允许下载"勾掉）。
class DriveAdvanceSharingDto {
  const DriveAdvanceSharingDto({
    required this.sharingLink,
    required this.url,
    required this.role,
    required this.protectPassword,
    required this.dueDate,
  });

  /// `sharing_link`：update/delete 必须原样回传
  final String sharingLink;

  /// `url`：可分享的公开地址
  final String url;

  /// `role`：`viewer`/`previewer`/`commenter`/`preview_commenter`
  final String role;

  /// `protect_password`：**服务端回显的密码**（官方前端直接填回输入框）
  final String protectPassword;

  /// `due_date`：有效期（epoch 秒；0 = 不过期）
  final int dueDate;

  /// 是否设置了密码保护（官方用 `Ext.isEmpty(protect_password)` 判断）
  bool get hasPassword => protectPassword.isNotEmpty;

  /// 是否设置了有效期
  bool get hasExpiry => dueDate > 0;

  /// 把官方 `previewer`/`preview_commenter` 归一成 [DriveShareRole]
  DriveShareRole get normalizedRole => switch (role) {
    'previewer' => DriveShareRole.viewer,
    'preview_commenter' => DriveShareRole.commenter,
    _ => DriveShareRole.fromValue(role),
  };

  static DriveAdvanceSharingDto fromJson(Map<String, dynamic> json) =>
      DriveAdvanceSharingDto(
        sharingLink: '${json['sharing_link'] ?? ''}',
        url: '${json['url'] ?? ''}',
        role: '${json['role'] ?? ''}',
        protectPassword: '${json['protect_password'] ?? ''}',
        dueDate: json['due_date'] is num
            ? (json['due_date'] as num).toInt()
            : int.tryParse('${json['due_date'] ?? 0}') ?? 0,
      );
}
