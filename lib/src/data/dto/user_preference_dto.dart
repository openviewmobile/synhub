// 用户偏好（`SYNO.Chat.User.Preference`）—— 目前我们只关心"免打扰"相关字段，
// 但整个 `preferences` 对象原样保留，将来要接别的偏好（主题/侧边栏/邮件格式）
// 不用再改这一层。
//
// 逆向依据：原版 `data/vo/chat/PreferenceVo.java`（字段名逐个对齐）+
// `PreferencesHelper.getScheduleSnoozeStart/End` 的默认值（09:00 / 18:00）。
//
// 真机（NAS 2.4.7-22203）实测 `get` 的原始返回：
//   {"preferences":{"calendar_enable":true,"notification_browser_active":false,
//    "notification_mute":false,"notification_showmessage":true,
//    "prefer_user_name_format":"nickname","sidebar_pinning_unread":false,
//    "snooze":0,"snooze_schedule_enable":false,"theme_background":0,
//    "theme_style":"light"}}
// 注意：**关闭定时免打扰时服务端不下发 start/end**，所以必须给默认值兜底。
import 'dart:convert';

/// `SYNO.Chat.User.Preference / get` 里的 `preferences` 对象。
class UserPreferenceDto {
  const UserPreferenceDto({
    this.snooze = 0,
    this.scheduleEnabled = false,
    this.scheduleStartSecond = kDefaultSnoozeScheduleStart,
    this.scheduleEndSecond = kDefaultSnoozeScheduleEnd,
    this.notificationShowMessage = true,
    this.raw = const <String, dynamic>{},
  });

  /// 原版 `PreferencesHelper.getScheduleSnoozeStart()` 的默认值：09:00
  static const int kDefaultSnoozeScheduleStart = 32400;

  /// 原版 `PreferencesHelper.getScheduleSnoozeEnd()` 的默认值：18:00
  static const int kDefaultSnoozeScheduleEnd = 64800;

  /// 免打扰截止时间（**服务端时钟**毫秒；0 = 没开）
  final int snooze;

  /// 定时免打扰开关
  final bool scheduleEnabled;

  /// 定时免打扰起始时间（**当天秒数**，0..86399）
  final int scheduleStartSecond;

  /// 定时免打扰结束时间（当天秒数）
  final int scheduleEndSecond;

  /// 「通知里显示消息内容」（`notification_showmessage`）
  final bool notificationShowMessage;

  /// 原始 preferences（未知字段靠它透传/落库）
  final Map<String, dynamic> raw;

  factory UserPreferenceDto.fromJson(Map<String, dynamic> json) {
    final p = json['preferences'] is Map
        ? Map<String, dynamic>.from(json['preferences'] as Map)
        : Map<String, dynamic>.from(json);
    int sec(Object? v) {
      final n = v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
      return n < 0 ? 0 : (n > 86399 ? 86399 : n);
    }

    final start = sec(p['snooze_schedule_start']);
    final end = sec(p['snooze_schedule_end']);
    return UserPreferenceDto(
      snooze: p['snooze'] is num ? (p['snooze'] as num).toInt() : 0,
      scheduleEnabled: p['snooze_schedule_enable'] == true,
      // 服务端关着定时免打扰时**不发**这两个字段；原版读偏好也是给默认值
      scheduleStartSecond: p['snooze_schedule_start'] == null
          ? kDefaultSnoozeScheduleStart
          : start,
      scheduleEndSecond: p['snooze_schedule_end'] == null
          ? kDefaultSnoozeScheduleEnd
          : end,
      notificationShowMessage: p['notification_showmessage'] != false,
      raw: p,
    );
  }

  Map<String, dynamic> toJson() => {
    ...raw,
    'snooze': snooze,
    'snooze_schedule_enable': scheduleEnabled,
    'snooze_schedule_start': scheduleStartSecond,
    'snooze_schedule_end': scheduleEndSecond,
    'notification_showmessage': notificationShowMessage,
  };

  String encode() => jsonEncode(toJson());

  static UserPreferenceDto? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is Map) {
        return UserPreferenceDto.fromJson(Map<String, dynamic>.from(json));
      }
    } catch (_) {
      // 缓存坏了就当没有
    }
    return null;
  }

  @override
  String toString() =>
      'UserPreference(snooze=$snooze, schedule=$scheduleEnabled '
      '$scheduleStartSecond..$scheduleEndSecond)';
}
