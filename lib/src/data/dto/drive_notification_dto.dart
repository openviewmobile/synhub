// `SYNO.SynologyDrive.Notifications`（Drive 通知中心）的 VO。
//
// 权威来源（NAS 上装的 Synology Drive 4.2.0-30058 解包产物）：
//   * 方法表 `webapi/SYNO.SynologyDrive.lib` → `SYNO.SynologyDrive.Notifications`
//     **v1-2** = `create list delete`，`allowUser` 含 `normal.*`
//     （`/tmp/spk/out/SynologyDrive.apis.txt:112-114`）。
//   * 官方 `SYNO.SDS.Drive.WebAPIDesc` 三个描述符都是 **v1**：
//     `list_notifications` / `create_notification` / `delete_notifications`
//     （`drive/synodrive_common.js:513417` 起）。
//   * 列表调用点：轮询任务 `params:{limit:100}`，回包读 `result.items[]`，
//     每个条目读 `notification_id`（idProperty）（`drive/synodrive_common.js`
//     `:331025` 与 `getStore` 的 fields 列表）：
//     `["notification_id","type","time","content","sender","recipient","extra_info"]`。
//   * 创建调用点：`SYNO.SDS.Drive.WebAPICore.send("create_notification",
//     {content:t, type:"drive#upload_task"})`（`drive/synodrive_common.js:635884`）。
//   * 删除调用点（清空全部）：`clearNotifications({params:{}, …})`
//     （`drive/synodrive_common.js:329203`）——**空参数**，这是 `delete` 的原文证据。
import '../../core/i18n/data_text.dart';

class DriveNotificationDto {
  const DriveNotificationDto({
    required this.notificationId,
    required this.type,
    required this.time,
    required this.content,
    required this.sender,
    required this.recipient,
    required this.extraInfo,
  });

  /// `notification_id`（官方 store 的 idProperty）
  final String notificationId;

  /// `type`：官方上传任务通知用的是 `drive#upload_task`
  final String type;

  /// `time`：epoch 秒
  final int time;

  /// `content`：通知正文（上传任务时是 `{action,names,errors,success}` 结构）
  final Object? content;

  final String sender;
  final String recipient;
  final Object? extraInfo;

  static DriveNotificationDto fromJson(Map<String, dynamic> json) =>
      DriveNotificationDto(
        notificationId: _str(json['notification_id']),
        type: _str(json['type']),
        time: _int(json['time']),
        content: json['content'],
        sender: _str(json['sender']),
        recipient: _str(json['recipient']),
        extraInfo: json['extra_info'],
      );

  /// `{items, total}` 形态回包
  static List<DriveNotificationDto> listFromJson(Map<String, dynamic> data) {
    final raw = (data['items'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => DriveNotificationDto.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// `content` 的 map 形态（拿不到就回空 map，调用方不必到处判类型）
  Map<String, Object?> get contentMap =>
      content is Map ? (content as Map).cast<String, Object?>() : const {};

  /// ★ D45：通知里带的**评论文本**。
  ///
  /// 官方 `NotificationVo$ContentVo` 的字段里有 `comment`
  /// （`smali_classes3/.../api/response/NotificationVo$ContentVo.smali`，
  /// getter `getComment()`），只有 `drive#comment` / `drive#comment_reply` /
  /// `drive#mention` 三种类型会带 —— 官方 Drive Android **没有评论编辑器**，
  /// 评论只以通知形式到达客户端（`NotificationAdapter` 读 `Notification.getComment()`）。
  String get commentText {
    final v = contentMap['comment'];
    return v == null ? '' : '$v';
  }

  /// `content.name` —— 通知指向的文件名（评论 / 分享 / 访问请求都用它）
  String get fileName {
    final v = contentMap['name'];
    return v == null ? '' : '$v';
  }

  /// `content.names` —— 上传/后台任务涉及的文件列表
  List<String> get names =>
      ((contentMap['names'] as List?) ?? const []).map((e) => '$e').toList();

  /// 通知标题：官方 `create` 传进来的业务类型（`drive#upload_task`）。
  ///
  /// 类型全集来自官方枚举 `NotificationVo$Type`
  /// （`value = "drive#…"`，共 11 个），逐个给中文标签；
  /// **不认识的类型原样显示**（官方也是把 type 串直接显示，不硬猜）。
  String get typeLabel => switch (type) {
    'drive#upload_task' => 'upload',
    'drive#background_task' => dataText('dtoNotifBackgroundTask', '后台任务'),
    'drive#comment' => dataText('dtoNotifComment', '评论'),
    'drive#comment_reply' => dataText('dtoNotifCommentReply', '评论回复'),
    'drive#mention' => dataText('dtoNotifMention', '@提到'),
    'drive#share_with_me' => dataText('dtoNotifShareWithMe', '分享给我'),
    'drive#shared_label' => dataText('dtoNotifSharedLabel', '共享标签'),
    'drive#shared_label_owner_transfer' => dataText(
      'dtoNotifLabelOwnerTransfer',
      '标签所有者转移',
    ),
    'drive#request' => dataText('dtoNotifRequest', '访问请求'),
    'drive#request_unlock' => dataText('dtoNotifRequestUnlock', '解锁请求'),
    'drive#request_office_template' => dataText(
      'dtoNotifRequestOfficeTemplate',
      'Office 模板请求',
    ),
    _ => type,
  };

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  static String _str(Object? v) => v == null ? '' : '$v';
}
