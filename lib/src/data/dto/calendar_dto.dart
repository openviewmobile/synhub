// Synology Calendar 的数据模型（Calendar 3.0.3-21434）。
//
// 字段全部照**真机原始回包**写（2026-09-18 实测，`docs/api-server-authoritative.md` §18）：
//   * `Cal/list` v5 `{cal_type:"event"}` → `{list:[{cal_id, cal_displayname, cal_color,
//     cal_privilege, is_hidden_in_list, original_cal_id, …}]}`（键是复数 `list`）；
//   * `Event/list` / `Event/get` / `Event/create` → `{list:[…]}` / 事件对象本身，
//     事件字段：`evt_id, cal_id, original_cal_id, summary, description, dtstart, dtend,
//     dtstart_string, dtend_string, is_all_day, tz_id, color, is_repeat_evt, dav_etag,
//     ical_uid, create_time, modify_time, last_modify_user,
//     location_info{name,address,map_type,gps{lat,lng},place_id}, participant[], attachments[]`。
//
// 时间有两套表示，**两套都要留着**：
//   * `dtstart`/`dtend` = **UTC epoch 秒**（`int`）；
//   * `dtstart_string`/`dtend_string` = 该事件时区下的**墙上时间** `yyyyMMddTHHmmss`。
//   显示优先用 `*_string`（它才是用户在日历上看到的那一刻），没有才用 epoch 本地换算。

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/i18n/data_text.dart';
import '../region/china_gps.dart' as gps;

/// 日历（`Cal/list` 的一条）
class CalendarDto {
  const CalendarDto({
    required this.calId,
    required this.displayName,
    this.color = '',
    this.description = '',
    this.privilege = '',
    this.calType = 'event',
    this.isHiddenInList = false,
    this.isHiddenInCal = false,
    this.isDefault = false,
    this.originalCalId = '',
    this.originalUserName = '',
    this.originalUserNo = 0,
  });

  final String calId;
  final String displayName;

  /// `#RRGGBB`（官方 App 会截到 7 位，见包内 UI `color.substr(0,7)`）
  final String color;
  final String description;

  /// `RW` / `RO`
  final String privilege;
  final String calType;
  final bool isHiddenInList;
  final bool isHiddenInCal;
  final bool isDefault;
  final String originalCalId;
  final String originalUserName;
  final int originalUserNo;

  bool get canWrite => privilege.toUpperCase().contains('W');

  factory CalendarDto.fromJson(Map<String, dynamic> json) => CalendarDto(
    calId: _text(json['cal_id']),
    displayName: _text(json['cal_displayname']),
    color: _text(json['cal_color']),
    description: _text(json['cal_description']),
    privilege: _text(json['cal_privilege']),
    calType: _text(json['cal_type'], fallback: 'event'),
    isHiddenInList: _bool(json['is_hidden_in_list']),
    isHiddenInCal: _bool(json['is_hidden_in_cal']),
    isDefault: _bool(json['default_calendar']),
    originalCalId: _text(json['original_cal_id']),
    originalUserName: _text(json['original_ug_name']),
    originalUserNo: _int(json['original_user_no']),
  );

  static List<CalendarDto> listFromJson(Map<String, dynamic> data) => [
    for (final item in (data['list'] as List? ?? const []))
      if (item is Map) CalendarDto.fromJson(item.cast<String, dynamic>()),
  ];
}

/// 重复规则（服务端字段名 **`repeat_setting`**，逐字来自包内 Web UI 的
/// `SYNO.Cal.EventUtils.repeat`，2026-09-20 取证）：
///
/// ```json
/// { "type":"day|week|month|year", "interval":1, "weekday":["monday",...],
///   "month_option":"day_of_month|day_of_week", "week_start_day":"sunday",
///   "end": {"type":"never|count|date", "count":1, "date":1789718400} }
/// ```
///
/// 枚举值取自 `SYNO.Cal.RepeatUtils`（`rpType`/`monthOption`/`rpEndType`），
/// 与 `synocalendar.bundle.min.js` 里的 `e.Day="day"` / `e.Never="never"` 两处独立印证。
@immutable
class CalRepeatRule {
  const CalRepeatRule({
    this.type = 'day',
    this.interval = 1,
    this.weekday = const [],
    this.monthOption = 'day_of_month',
    this.weekStartDay = 'sunday',
    this.endType = 'never',
    this.endCount = 1,
    this.endDate = '',
  });

  /// `day` / `week` / `month` / `year`
  final String type;

  /// 间隔（每 N 天/周/月/年）
  final int interval;

  /// 每周重复时选中的星期（`monday` … `sunday`）
  final List<String> weekday;

  /// 每月重复的方式：按日期（`day_of_month`）或按第几个星期几（`day_of_week`）
  final String monthOption;

  final String weekStartDay;

  /// `never` / `count` / `date`
  final String endType;
  final int endCount;

  /// `endType == date` 时的结束日期（`yyyy-MM-dd`）
  final String endDate;

  bool get isNone => type.isEmpty;

  static const List<String> kWeekdays = [
    'sunday',
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
  ];

  /// 按类型新建：每周时默认勾**事件开始日**那一星期几（官方表单默认也是那天）
  factory CalRepeatRule.ofType(String type, {DateTime? start}) {
    final weekday = <String>[];
    if (type == 'week' && start != null) {
      weekday.add(kWeekdays[start.weekday % 7]);
    }
    return CalRepeatRule(type: type, weekday: weekday);
  }

  CalRepeatRule copyWith({
    String? type,
    int? interval,
    List<String>? weekday,
    String? monthOption,
    String? weekStartDay,
    String? endType,
    int? endCount,
    String? endDate,
  }) => CalRepeatRule(
    type: type ?? this.type,
    interval: interval ?? this.interval,
    weekday: weekday ?? this.weekday,
    monthOption: monthOption ?? this.monthOption,
    weekStartDay: weekStartDay ?? this.weekStartDay,
    endType: endType ?? this.endType,
    endCount: endCount ?? this.endCount,
    endDate: endDate ?? this.endDate,
  );

  factory CalRepeatRule.fromJson(Map<String, dynamic> json) {
    final end = json['end'] is Map
        ? (json['end'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final rawWeekday = json['weekday'];
    final interval = _int(json['interval']);
    final count = _int(end['count']);
    return CalRepeatRule(
      type: '${json['type'] ?? ''}',
      interval: interval == 0 ? 1 : interval,
      weekday: [
        for (final w in (rawWeekday is List ? rawWeekday : const [])) '$w',
      ],
      // 服务端字段是 snake_case（`month_option`/`week_start_day`）；camelCase 只是
      // 新版 Vue 前端的内部模型，**别往服务端发**（真机回 9009）。这里两个都收，
      // 免得将来服务端换成 camel 时炸。
      monthOption: _pick(
        '${json['month_option'] ?? json['monthOption'] ?? ''}',
        'day_of_month',
      ),
      weekStartDay: _pick(
        '${json['week_start_day'] ?? json['weekStartDay'] ?? ''}',
        'sunday',
      ),
      endType: _pick('${end['type'] ?? ''}', 'never'),
      endCount: count == 0 ? 1 : count,
      endDate: _formatEndDate(end['date']),
    );
  }

  static String _pick(String v, String fallback) => v.isEmpty ? fallback : v;

  /// `end.date` 服务端是 **epoch 秒**（openapi：`End date and time in Epoch seconds`），
  /// 界面上是 `yyyy-MM-dd`。回包给 epoch 就换算，给字符串（老格式）就原样留。
  static String _formatEndDate(Object? raw) {
    if (raw == null) return '';
    if (raw is num) {
      final d = DateTime.fromMillisecondsSinceEpoch(raw.toInt() * 1000);
      return '${d.year}-${d.month.toString().padLeft(2, '0')}'
          '-${d.day.toString().padLeft(2, '0')}';
    }
    final t = '$raw';
    if (t.isEmpty || t.length <= 10) return t;
    final parsed = DateTime.tryParse(t);
    if (parsed == null) return t;
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}'
        '-${parsed.day.toString().padLeft(2, '0')}';
  }

  /// 服务端要的形态 —— **内层键也是 snake_case**（`week_start_day`/`month_option`）。
  ///
  /// 2026-09-20 真机逐条实测（探针见 `docs/calendar-weather-research.md`）：
  /// ```text
  /// snake + 小写星期名 + end.date 数字(或省略) → OK
  /// camel（weekStartDay/monthOption）        → 9009
  /// weekday 大写名/下标/字符串/数组包一层      → 9009
  /// 容器键写成 repeat_rule                    → 9009
  /// ```
  /// 与包内 `webapi/openapi.json` 的 `repeat_obj_0` 完全一致（字段
  /// `type/interval/weekday/month_option/week_start_day/end{type,count,date}`，
  /// `weekday` 是**字符串数组**，`end.date` 是 **epoch 秒**）。
  Map<String, Object?> toJson({bool allDay = false}) => {
    'type': type,
    'interval': interval,
    // 只带当前类型用得上的那两个键（服务端两个都收，多带反而容易踩解析）
    if (type == 'week') 'weekday': weekday,
    if (type == 'month') 'month_option': monthOption,
    'week_start_day': weekStartDay,
    // `date` 一直带：never/count 给 0（**数字**，空串会让 Gson 解析崩），
    // date 结束方式给"结束日的最后一秒"（官方是「次日零点 -1 秒」）。
    'end': {'type': endType, 'count': endCount, 'date': _endDateEpoch(allDay)},
  };

  /// `endType == date` 时把 `yyyy-MM-dd` 换成 epoch 秒。官方对"全天 / 非全天"
  /// 是**两套算法**（包内 `_evtSetRequiredParams`）：
  ///   * 非全天 → `getUTCSecondsByTzId(结束日+1天, tz) - 1`，即事件时区里结束日的
  ///     **23:59:59**（我们按"设备时区 = 事件时区"处理 → 本地时间）；
  ///   * 全天 → `getAllDayUTCSeconds(结束日+1天) - 1`，即 **UTC** 的 23:59:59。
  ///
  /// [allDay] 为真时走后者。
  int _endDateEpoch(bool allDay) {
    if (endType != 'date' || endDate.isEmpty) return 0;
    final d = DateTime.tryParse(endDate);
    if (d == null) return 0;
    if (allDay) {
      final next = DateTime.utc(
        d.year,
        d.month,
        d.day,
      ).add(const Duration(days: 1));
      return next.millisecondsSinceEpoch ~/ 1000 - 1;
    }
    return DateTime(
          d.year,
          d.month,
          d.day,
          23,
          59,
          59,
        ).millisecondsSinceEpoch ~/
        1000;
  }

  /// 人话（列表/详情里显示；口径与官方 Web UI 的 `toDisplayString` 一致）
  ///
  /// 数据层拿不到 `BuildContext`、也不能碰 `AppText`（纯 Dart 探针要能加载），
  /// 所以按 docs §4.6 走 `data_text.dart` 的 [dataText]；没装翻译器就回落中文原文。
  String describe() {
    final every = switch (type) {
      'day' => dataText('dtoCalEveryDay', '每天'),
      'week' => dataText('dtoCalEveryWeek', '每周'),
      'month' => dataText('dtoCalEveryMonth', '每月'),
      'year' => dataText('dtoCalEveryYear', '每年'),
      _ => dataText('dtoCalRepeat', '重复'),
    };
    final parts = <String>[
      interval > 1
          ? dataText('dtoCalEvery', '每 {interval} {unit}')
                .replaceAll('{interval}', '$interval')
                .replaceAll('{unit}', _unitCn(type))
          : every,
    ];
    if (type == 'week' && weekday.isNotEmpty) {
      parts.add(
        weekday.map(_weekdayCn).join(dataText('dtoCalWeekdaySep', '、')),
      );
    }
    if (type == 'month' && monthOption == 'day_of_week') {
      parts.add(dataText('dtoCalMonthWeekday', '按月内第几个星期几'));
    }
    switch (endType) {
      case 'count':
        parts.add(
          dataText(
            'dtoCalEndCount',
            '共 {count} 次',
          ).replaceAll('{count}', '$endCount'),
        );
      case 'date':
        if (endDate.isNotEmpty) {
          parts.add(
            dataText('dtoCalEndDate', '到 {date}').replaceAll('{date}', endDate),
          );
        }
    }
    return parts.join(' · ');
  }

  static String _unitCn(String type) => switch (type) {
    'day' => dataText('dtoCalUnitDay', '天'),
    'week' => dataText('dtoCalUnitWeek', '周'),
    'month' => dataText('dtoCalUnitMonth', '个月'),
    'year' => dataText('dtoCalUnitYear', '年'),
    _ => dataText('dtoCalUnitTimes', '次'),
  };

  static String _weekdayCn(String w) => switch (w) {
    'sunday' => dataText('dtoCalWeekdaySunday', '周日'),
    'monday' => dataText('dtoCalWeekdayMonday', '周一'),
    'tuesday' => dataText('dtoCalWeekdayTuesday', '周二'),
    'wednesday' => dataText('dtoCalWeekdayWednesday', '周三'),
    'thursday' => dataText('dtoCalWeekdayThursday', '周四'),
    'friday' => dataText('dtoCalWeekdayFriday', '周五'),
    'saturday' => dataText('dtoCalWeekdaySaturday', '周六'),
    _ => w,
  };

  @override
  bool operator ==(Object other) =>
      other is CalRepeatRule &&
      other.type == type &&
      other.interval == interval &&
      other.monthOption == monthOption &&
      other.weekStartDay == weekStartDay &&
      other.endType == endType &&
      other.endCount == endCount &&
      other.endDate == endDate &&
      _sameList(other.weekday, weekday);

  @override
  int get hashCode => Object.hash(
    type,
    interval,
    monthOption,
    weekStartDay,
    endType,
    endCount,
    endDate,
    Object.hashAll(weekday),
  );

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 事件（`Event/list` / `Event/get` / `Event/create` 的一条）
class CalEventDto {
  const CalEventDto({
    required this.evtId,
    required this.calId,
    required this.summary,
    this.originalCalId = '',
    this.description = '',
    this.dtstart = 0,
    this.dtend = 0,
    this.dtstartString = '',
    this.dtendString = '',
    this.isAllDay = false,
    this.tzId = '',
    this.color = '',
    this.isRepeatEvt = false,
    this.recurrenceId = '',
    this.repeat,
    this.davEtag = '',
    this.icalUid = '',
    this.createTime = 0,
    this.modifyTime = 0,
    this.lastModifyUser = '',
    this.ownerName = '',
    this.ownerId = 0,
    this.locationName = '',
    this.locationAddress = '',
    this.locationMapType = '',
    this.locationLat,
    this.locationLng,
    this.participants = const [],
    this.participantsRaw = const [],
    this.notifySetting = const [],
    this.attachments = const [],
    this.locationRaw = const {},
  });

  final String evtId;
  final String calId;
  final String summary;
  final String originalCalId;
  final String description;

  /// UTC epoch 秒（服务端原始值）
  final int dtstart;
  final int dtend;

  /// 事件时区下的墙上时间 `yyyyMMddTHHmmss`（显示优先用它）
  final String dtstartString;
  final String dtendString;

  final bool isAllDay;
  final String tzId;
  final String color;
  final bool isRepeatEvt;

  /// 这条是重复事件的**某一次**时，服务端给的这次的身份（`recurrence_id`）；
  /// 母事件为空。删"仅这一次"要用它当 `exdate`。
  final String recurrenceId;

  /// 重复规则（`repeat_setting`）；一次性事件为 null
  final CalRepeatRule? repeat;

  /// 这条**属于一个重复系列**吗（母事件或被单独改过的那一次）？
  ///
  /// ⚠️ 真机现场（2026-09-20 探针）：被 `subevent_set` 单独改过的那一次在
  /// `Event/list` 里 **`is_repeat_evt` 会消失（null）、`repeat_setting` 也没有了**，
  /// 只有 `recurrence_id` 变成这一次的开始串，`evt_id` 仍然是母事件的。
  /// 只看 `isRepeatEvt` 会把它当成一次性事件 —— 用它的 id 去 `Event/set` / `Event/delete`
  /// 会**把整个系列打散/删掉**。所以判定"是不是系列成员"要看这三样。
  bool get isSeriesMember =>
      isRepeatEvt || recurrenceId.isNotEmpty || repeat != null;

  /// 这条是**被单独改过/删过的那一次**（`subevent_set` / `set_exdate` 之后
  /// `recurrence_id` 才有值）；母事件为 false。
  bool get isOverriddenInstance => recurrenceId.isNotEmpty;
  final String davEtag;
  final String icalUid;
  final int createTime;
  final int modifyTime;
  final String lastModifyUser;
  final String ownerName;
  final int ownerId;
  final String locationName;
  final String locationAddress;

  /// 地点的地图类型（`baidu` / `google` …）：**决定坐标要不要纠偏**
  final String locationMapType;

  /// 地点坐标（**原始值**，按 [locationMapType] 可能带偏移）
  final double? locationLat;
  final double? locationLng;

  /// 归一成 WGS84 的坐标（境内 BD09/GCJ02 会自动纠偏）
  ({double lat, double lng})? get locationGpsWgs84 {
    final lat = locationLat;
    final lng = locationLng;
    if (lat == null || lng == null) return null;
    if (lat == 0 && lng == 0) return null;
    return gps.toWgs84(lat, lng, mapType: locationMapType);
  }

  final List<String> participants;

  /// `participant` 的**原始 JSON**（每项含 type/role/status/user_name/email…）。
  /// 编辑日程时 `Event/set` 会**整体替换**这个字段，所以必须原样回传，
  /// 否则会把已有的受邀人/状态全部清掉。
  final List<Object?> participantsRaw;

  final List<Object?> notifySetting;
  final List<Object?> attachments;

  /// `location_info` 的**原始 JSON**（含 `place_id`/`gps`，我们的强类型字段装不下）。
  /// 同样为了 `Event/set` 原样回传。
  final Map<String, Object?> locationRaw;

  /// 显示用的开始时间：优先 `dtstart_string`（带时区语义），退化到 epoch 本地时间。
  DateTime? get start =>
      parseCalStamp(dtstartString) ??
      (dtstart > 0
          ? DateTime.fromMillisecondsSinceEpoch(dtstart * 1000)
          : null);

  DateTime? get end =>
      parseCalStamp(dtendString) ??
      (dtend > 0 ? DateTime.fromMillisecondsSinceEpoch(dtend * 1000) : null);

  bool get hasLocation => locationName.isNotEmpty || locationAddress.isNotEmpty;

  factory CalEventDto.fromJson(Map<String, dynamic> json) {
    final loc = json['location_info'];
    final locMap = loc is Map
        ? loc.cast<String, dynamic>()
        : const <String, dynamic>{};
    return CalEventDto(
      evtId: _text(json['evt_id']),
      calId: _text(json['cal_id']),
      summary: _text(json['summary']),
      originalCalId: _text(json['original_cal_id']),
      description: _text(json['description']),
      dtstart: _int(json['dtstart']),
      dtend: _int(json['dtend']),
      dtstartString: _text(json['dtstart_string']),
      dtendString: _text(json['dtend_string']),
      isAllDay: _bool(json['is_all_day']),
      tzId: _text(json['tz_id']),
      color: _text(json['color']),
      isRepeatEvt: _bool(json['is_repeat_evt']),
      recurrenceId: _text(json['recurrence_id']),
      repeat: _repeat(json['repeat_setting']) ?? _repeat(json['repeat']),
      davEtag: _text(json['dav_etag']),
      icalUid: _text(json['ical_uid']),
      createTime: _int(json['create_time']),
      modifyTime: _int(json['modify_time']),
      lastModifyUser: _text(json['last_modify_user']),
      ownerName: _text(json['owner_name']),
      ownerId: _int(json['owner_id']),
      locationName: _text(locMap['name']),
      locationAddress: _text(locMap['address']),
      locationMapType: _text(locMap['map_type']),
      locationLat: _dbl(_map(locMap['gps'])['lat']),
      locationLng: _dbl(_map(locMap['gps'])['lng']),
      participants: _stringList(json['participant']),
      participantsRaw: _objectList(json['participant']),
      notifySetting: _objectList(json['notify_setting']),
      attachments: _objectList(json['attachments']),
      locationRaw: locMap,
    );
  }

  /// 重复规则可能是"对象"或"JSON 字符串"（两种真机回包都见过），都收
  static CalRepeatRule? _repeat(Object? o) {
    if (o == null) return null;
    if (o is String) {
      final t = o.trim();
      if (t.isEmpty || t == 'null') return null;
      try {
        final decoded = jsonDecode(t);
        if (decoded is Map) {
          final rule = CalRepeatRule.fromJson(decoded.cast<String, dynamic>());
          return rule.type.isEmpty ? null : rule;
        }
      } catch (_) {
        return null;
      }
      return null;
    }
    if (o is Map) {
      final rule = CalRepeatRule.fromJson(o.cast<String, dynamic>());
      return rule.type.isEmpty ? null : rule;
    }
    return null;
  }

  static Map<String, dynamic> _map(Object? o) =>
      o is Map ? o.cast<String, dynamic>() : const <String, dynamic>{};

  static double? _dbl(Object? o) {
    if (o is num) return o.toDouble();
    if (o is String) return double.tryParse(o);
    return null;
  }

  /// 受邀人列表（把 [participantsRaw] 解成强类型）。
  ///
  /// 官方回包的 `participant` 每项就是 `participant_obj_0`
  /// （`webapi/openapi.json`）：`type / status / role / user_name / email / is_real_email`。
  List<CalParticipantDto> get participantList => [
    for (final p in participantsRaw)
      if (p is Map) CalParticipantDto.fromJson(p.cast<String, dynamic>()),
  ];

  static List<CalEventDto> listFromJson(Map<String, dynamic> data) => [
    for (final item in (data['list'] as List? ?? const []))
      if (item is Map) CalEventDto.fromJson(item.cast<String, dynamic>()),
  ];
}

/// 事件受邀人（`participant` 数组的一项）。
///
/// 逐字证据（Calendar 3.0.3-21434 包内原文）：
///
/// * `webapi/openapi.json` 的 `participant_obj_0`
///   `{type, status, role, user_name, email, is_real_email}`（`/event` POST/PUT 的
///   `participant` 数组元素）；
/// * `ui/synocalendar-common_utils.js` 的 `SYNO.Cal.AttendeeUtils`：
///   ```js
///   attendeeStatus:{accepted:"accepted",declined:"declined",
///                   tentative:"tentative",needsAction:"needs_action"}
///   attendeeType:{email:"email",dsm:"dsm"}
///   attendeeRole:{organizer:"organizer",attendee:"attendee"}
///   ```
/// * `ui/synocalendar-app.js` 构造一条受邀人（选 DSM 用户 / 手输邮箱）：
///   ```js
///   getAttendeeBySelection -> {display_name,user_name,email,is_real_email,
///                              type,status:needs_action,role:attendee}
///   getAttendeeByRawEmail  -> {display_name:<email>,user_name:<email>,email:<email>,
///                              is_real_email:true,type:"email",
///                              status:needs_action,role:attendee}
///   ```
/// * **发请求时的键**（`_convertAttendeeForAPI`，就是这里 [toApiJson] 的形状）：
///   ```js
///   {user_name,email,type,status,role,is_real_email}
///   ```
///   —— **`display_name` 不进请求**（openapi 的 participant schema 里也没有它），
///   只有 `Contact/list` 的用户候选才带 `display_name`。
class CalParticipantDto {
  const CalParticipantDto({
    this.type = '',
    this.userName = '',
    this.email = '',
    this.displayName = '',
    this.isRealEmail = false,
    this.status = '',
    this.role = '',
  });

  /// `dsm`（NAS 用户）或 `email`（外部邮箱）
  final String type;
  final String userName;
  final String email;
  final String displayName;
  final bool isRealEmail;

  /// `accepted` / `declined` / `tentative` / `needs_action`
  final String status;

  /// `organizer` / `attendee`
  final String role;

  static const String typeDsm = 'dsm';
  static const String typeEmail = 'email';
  static const String statusAccepted = 'accepted';
  static const String statusDeclined = 'declined';
  static const String statusTentative = 'tentative';
  static const String statusNeedsAction = 'needs_action';
  static const String roleOrganizer = 'organizer';
  static const String roleAttendee = 'attendee';

  /// 界面上显示的名字：`display_name` → `user_name` → `email`
  String get label {
    if (displayName.isNotEmpty) return displayName;
    if (userName.isNotEmpty) return userName;
    return email;
  }

  /// 从 NAS 用户候选建一条受邀人（官方 `getAttendeeBySelection`）。
  factory CalParticipantDto.forDsm(CalContactDto user) => CalParticipantDto(
    type: typeDsm,
    userName: user.userName,
    email: user.email,
    displayName: user.displayName,
    isRealEmail: user.isRealEmail,
    status: statusNeedsAction,
    role: roleAttendee,
  );

  /// 从手输邮箱建一条受邀人（官方 `getAttendeeByRawEmail`）。
  factory CalParticipantDto.forEmail(String raw) => CalParticipantDto(
    type: typeEmail,
    userName: raw,
    email: raw,
    displayName: raw,
    isRealEmail: true,
    status: statusNeedsAction,
    role: roleAttendee,
  );

  /// 发请求的**逐字形状**（`_convertAttendeeForAPI` / openapi `participant_obj_0`）：
  /// 只有这 6 个键，`display_name` **不发**。
  Map<String, Object?> toApiJson() => {
    'user_name': userName,
    'email': email,
    'type': type,
    'status': status,
    'role': role,
    'is_real_email': isRealEmail,
  };

  /// 回包同时见过 snake_case（服务端）与新 bundle 的 camelCase，两种都收。
  factory CalParticipantDto.fromJson(Map<String, dynamic> json) =>
      CalParticipantDto(
        type: _dualText(json, 'type', 'type'),
        userName: _dualText(json, 'user_name', 'userName'),
        email: _dualText(json, 'email', 'email'),
        displayName: _dualText(json, 'display_name', 'displayName'),
        isRealEmail: _bool(json['is_real_email'] ?? json['isRealEmail']),
        status: _dualText(json, 'status', 'status'),
        role: _dualText(json, 'role', 'role'),
      );

  @override
  bool operator ==(Object other) =>
      other is CalParticipantDto &&
      other.type == type &&
      other.userName == userName &&
      other.email == email &&
      other.status == status &&
      other.role == role;

  @override
  int get hashCode => Object.hash(type, userName, email, status, role);
}

/// Calendar 的 NAS 用户候选（`SYNO.Cal.Contact/list`）。
///
/// 逐字证据：
/// * 方法表 `Contact_list:{api:"SYNO.Cal.Contact",method:"list",version:1}`
///   （`ui/synocalendar.bundle.min.js`）；调用点
///   `listContactUsers(){const e=await this.runAPI("Contact_list",{});…}`
///   —— **空参数**；
/// * 回包元素 schema `user_contact_obj_0`（`webapi/openapi.json`，GET `/contact`）：
///   `{user_name, display_name, email, is_real_email, type, has_set_email}`；
/// * 老 Web UI 是 `{api:"Contact_list"}` + `processFetchedData: t.list`
///   ⇒ data 的键是 **`list`**。
class CalContactDto {
  const CalContactDto({
    this.userName = '',
    this.displayName = '',
    this.email = '',
    this.isRealEmail = false,
    this.type = '',
    this.hasSetEmail = false,
  });

  final String userName;
  final String displayName;
  final String email;
  final bool isRealEmail;
  final String type;
  final bool hasSetEmail;

  String get label => displayName.isNotEmpty
      ? displayName
      : (userName.isNotEmpty ? userName : email);

  factory CalContactDto.fromJson(Map<String, dynamic> json) => CalContactDto(
    userName: _dualText(json, 'user_name', 'userName'),
    displayName: _dualText(json, 'display_name', 'displayName'),
    email: _dualText(json, 'email', 'email'),
    isRealEmail: _bool(json['is_real_email'] ?? json['isRealEmail']),
    type: _dualText(json, 'type', 'type'),
    hasSetEmail: _bool(json['has_set_email'] ?? json['hasSetEmail']),
  );

  static List<CalContactDto> listFromJson(Map<String, dynamic> data) => [
    for (final item in (data['list'] as List? ?? const []))
      if (item is Map) CalContactDto.fromJson(item.cast<String, dynamic>()),
  ];
}

/// 个人设置（`Setting/get`）
///
/// 字段名与枚举**逐字来自包内 `webapi/openapi.json` 的 `GET/PUT /setting`**
/// （`x-syno-version: 5`，`x-syno-api: SYNO.Cal.Setting`），真机 `Setting/get` v1
/// 也回同一份键。wave1 **只读**：`set` 虽有 openapi 的 requestBody 属性表，
/// 但走的是 REST 通道、**没有 entry.cgi 的真机写取证**，所以按纪律
/// "写不确定就只读并登记"（见 `docs/calendar-gaps-wave1.md`）。
class CalSettingDto {
  const CalSettingDto({
    this.timeZone = '',
    this.dateFormat = 'Y-m-d',
    this.timeFormat = '24',
    this.weekStartDay = 0,
    this.defaultView = 'week',
    this.defaultCalId = '',
    this.showWeekNumbers = false,
    this.enableKeyboardShortcut = false,
    this.defaultTodoView = '',
    this.lastUsedMapType = '',
    this.defaultPluginMode = '',
  });

  final String timeZone;
  final String dateFormat;
  final String timeFormat;
  final int weekStartDay;
  final String defaultView;
  final String defaultCalId;

  /// `show_week_numbers`（openapi：boolean）
  final bool showWeekNumbers;

  /// `enable_keyboard_shortcut`（openapi：boolean）
  final bool enableKeyboardShortcut;

  /// `default_todo_view`（openapi：`todo_view_obj_0`，形状未取证 ⇒ 存原始串）
  final String defaultTodoView;

  /// `last_used_map_type`（openapi：`none` / `google` / `baidu`）
  final String lastUsedMapType;

  /// `default_plugin_mode`（openapi：`nav_panel` / `todo_plugin`）
  final String defaultPluginMode;

  factory CalSettingDto.fromJson(Map<String, dynamic> json) => CalSettingDto(
    timeZone: _text(json['time_zone']),
    dateFormat: _text(json['date_format'], fallback: 'Y-m-d'),
    timeFormat: _text(json['time_format'], fallback: '24'),
    weekStartDay: _int(json['week_start_day']),
    defaultView: _text(json['default_view'], fallback: 'week'),
    defaultCalId: _text(json['default_cal']),
    showWeekNumbers: _bool(json['show_week_numbers']),
    enableKeyboardShortcut: _bool(json['enable_keyboard_shortcut']),
    defaultTodoView: _text(json['default_todo_view']),
    lastUsedMapType: _text(json['last_used_map_type']),
    defaultPluginMode: _text(json['default_plugin_mode']),
  );
}

/// 外部日历账号下的一个**远端日历**（`SYNO.Cal.Proxy/cal_list`）。
///
/// 字段与来源（官方打包产物的**明文 JS**）：
///
/// ```js
/// // 老 Web UI（ui/synocalendar-app.js）：拿远端日历列表
/// Proxy_cal_list:{api:"SYNO.Cal.Proxy",method:"cal_list",version:1}
/// SYNO.Cal.WebAPI.sendPromise("Proxy_cal_list",{auth_id:t.auth_id})
/// // 每个远端日历的字段（同文件的导入流程）
/// {remote_cal_id:a.data.remote_cal_id,
///  remote_cal_displayname:a.data.remote_cal_displayname,
///  remote_cal_type:"VCALENDAR", cal_color:t}
/// ```
/// 新 Vue UI 同形（`synocalendar.bundle.min.js`：
/// `remoteCalendarList(e){return this.runAPI("Proxy_cal_list",{authId:e})}`，
/// `authId` 经参数层转成 `auth_id`；元素字段用 `remoteCalId`/`remoteCalDisplayname`）。
///
/// ⚠️ 它**需要 `auth_id`**，而 `auth_id` 只能由 `SYNO.Cal.AuthForeign/create`
/// 拿到（Google OAuth，`auth_type:"google"` + `auth_info{access_token,refresh_token}`）。
/// 本 App 没有 Google OAuth 流程，且真机上 `AuthForeign/list` 回 **117**
/// （`internalError`，见 `docs/live-nas-verification.md` §6.1）——
/// 所以这个只读能力**有参数证据、但没有可用的 auth_id 来源**，UI 入口按
/// 「暂不支持（原因见文档）」处理，见 `docs/calendar-contacts-c4.md`。
class RemoteCalendarDto {
  const RemoteCalendarDto({
    required this.remoteCalId,
    this.displayName = '',
    this.type = 'VCALENDAR',
    this.color = '',
  });

  final String remoteCalId;
  final String displayName;

  /// 服务端回的都是 `VCALENDAR`
  final String type;
  final String color;

  factory RemoteCalendarDto.fromJson(Map<String, dynamic> json) =>
      RemoteCalendarDto(
        remoteCalId: _dualText(json, 'remote_cal_id', 'remoteCalId'),
        displayName: _dualText(
          json,
          'remote_cal_displayname',
          'remoteCalDisplayname',
        ),
        type: _text(json['remote_cal_type'], fallback: 'VCALENDAR'),
        color: _text(json['cal_color']),
      );

  /// 回包是**数组**（老 UI 直接 `store.loadData(t)`；新 UI `e.map(...)`）
  static List<RemoteCalendarDto> listFromJson(Object? data) {
    final raw = data is Map ? (data['list'] ?? data['cal_list']) : data;
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) RemoteCalendarDto.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

/// 日历待办（`Todo/list`）
class CalTodoDto {
  const CalTodoDto({
    required this.evtId,
    required this.summary,
    this.calId = '',
    this.originalCalId = '',
    this.description = '',
    this.percentComplete = 0,
    this.due = 0,
    this.dueString = '',
    this.start = 0,
    this.startString = '',
    this.isAllDay = false,
    this.tzId = '',
    this.priorityOrder = 0,
    this.davEtag = '',
    this.hasStartTime = false,
    this.hasEndTime = false,
    this.icalUid = '',
    this.ownerName = '',
    this.lastModifyUser = '',
    this.fromSynoAppUrl = '',
  });

  final String evtId;
  final String summary;
  final String calId;
  final String originalCalId;
  final String description;
  final int percentComplete;
  final int due;
  final String dueString;
  final int start;
  final String startString;
  final bool isAllDay;
  final String tzId;
  final int priorityOrder;

  /// `dav_etag` —— `Todo/set` 的**乐观锁**（回包带了就必须原样回传，否则 1019 冲突）
  final String davEtag;

  /// 服务端明确标记"有没有开始/截止时间"（`has_start_time`/`has_end_time`）。
  ///
  /// ⚠️ 不能只看 epoch 是不是 0：全天待办的 0 点也可能是合法值，官方 Web UI
  /// 也是靠这两个布尔决定 `dtstart`/`due` 要不要进请求。
  final bool hasStartTime;
  final bool hasEndTime;
  final String icalUid;
  final String ownerName;
  final String lastModifyUser;
  final String fromSynoAppUrl;

  bool get done => percentComplete >= 100;

  DateTime? get dueAt =>
      parseCalStamp(dueString) ??
      (due > 0 ? DateTime.fromMillisecondsSinceEpoch(due * 1000) : null);

  DateTime? get startAt =>
      parseCalStamp(startString) ??
      (start > 0 ? DateTime.fromMillisecondsSinceEpoch(start * 1000) : null);

  /// 真正带"截止"语义：布尔标记或 epoch 任一成立（老回包没有布尔）
  bool get hasDue => hasEndTime || due > 0 || dueString.isNotEmpty;

  /// 真正带"开始"语义
  bool get hasStart => hasStartTime || start > 0 || startString.isNotEmpty;

  CalTodoDto copyWith({
    String? summary,
    String? description,
    int? percentComplete,
    String? davEtag,
  }) => CalTodoDto(
    evtId: evtId,
    summary: summary ?? this.summary,
    calId: calId,
    originalCalId: originalCalId,
    description: description ?? this.description,
    percentComplete: percentComplete ?? this.percentComplete,
    due: due,
    dueString: dueString,
    start: start,
    startString: startString,
    isAllDay: isAllDay,
    tzId: tzId,
    priorityOrder: priorityOrder,
    davEtag: davEtag ?? this.davEtag,
    hasStartTime: hasStartTime,
    hasEndTime: hasEndTime,
    icalUid: icalUid,
    ownerName: ownerName,
    lastModifyUser: lastModifyUser,
    fromSynoAppUrl: fromSynoAppUrl,
  );

  /// ⚠️ 字段名以**服务端为准**：`webapi/openapi.json` 的 `/task` GET 回包用的是
  /// `evt_cal` / `dtstart` / `dtstart_string` / `tzid`（不是 `cal_id` / `start` /
  /// `start_string` / `tz_id`）。这里两种都收，老回包/新回包都不会丢字段。
  factory CalTodoDto.fromJson(Map<String, dynamic> json) => CalTodoDto(
    evtId: _text(json['evt_id']),
    summary: _text(json['summary']),
    calId: _dualText(json, 'evt_cal', 'cal_id'),
    originalCalId: _text(json['original_cal_id']),
    description: _text(json['description']),
    percentComplete: _int(json['percent_complete']),
    due: _int(json['due']),
    dueString: _text(json['due_string']),
    start: _dualInt(json, 'dtstart', 'start'),
    startString: _dualText(json, 'dtstart_string', 'start_string'),
    isAllDay: _bool(json['is_all_day']),
    tzId: _dualText(json, 'tzid', 'tz_id'),
    priorityOrder: _int(json['priority_order']),
    davEtag: _text(json['dav_etag']),
    hasStartTime: _bool(json['has_start_time']),
    hasEndTime: _bool(json['has_end_time']),
    icalUid: _text(json['ical_uid']),
    ownerName: _text(json['owner_name']),
    lastModifyUser: _text(json['last_modify_user']),
    fromSynoAppUrl: _text(json['from_syno_app_url']),
  );

  static List<CalTodoDto> listFromJson(Map<String, dynamic> data) => [
    for (final item in (data['list'] as List? ?? const []))
      if (item is Map) CalTodoDto.fromJson(item.cast<String, dynamic>()),
  ];
}

/// 同一个字段的两种命名里取第一个非空的（见 [CalTodoDto.fromJson] 的注释）。
String _dualText(Map<String, dynamic> json, String a, String b) {
  final va = _text(json[a]);
  return va.isNotEmpty ? va : _text(json[b]);
}

int _dualInt(Map<String, dynamic> json, String a, String b) {
  final va = _int(json[a]);
  return va != 0 ? va : _int(json[b]);
}

/// 把服务端的墙上时间串（`20260919T070539`）解析成本地 [DateTime]。
///
/// ⚠️ 这里**故意按本地时区**还原：串里没有时区偏移，事件时区在 `tz_id` 里单列；
/// 对绝大多数用户（事件时区 = 设备时区）它和官方 App 的显示完全一致。
DateTime? parseCalStamp(String raw) {
  if (raw.length < 15 || raw[8] != 'T') return null;
  int? num(int from, int len) => int.tryParse(raw.substring(from, from + len));
  final y = num(0, 4);
  final mo = num(4, 2);
  final d = num(6, 2);
  final h = num(9, 2);
  final mi = num(11, 2);
  final s = num(13, 2);
  if (y == null || mo == null || d == null || h == null || mi == null) {
    return null;
  }
  return DateTime(y, mo, d, h, mi, s ?? 0);
}

String _text(Object? v, {String fallback = ''}) {
  if (v == null) return fallback;
  final s = '$v';
  return s.isEmpty ? fallback : s;
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v == null) return 0;
  return int.tryParse('$v') ?? 0;
}

bool _bool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = '$v'.toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

List<String> _stringList(Object? v) => [
  if (v is List)
    for (final e in v) '$e',
];

List<Object?> _objectList(Object? v) => v is List ? v.toList() : const [];

// ---------------------------------------------------------------------------
// 日历 wave1 新增：配色 / 共享 / 时区
//
// 取证口径（**没取证的一律不写死**，逐条注明）：
//
// | 项 | 证据 | 状态 |
// |---|---|---|
// | `Cal.Timezone/list` | 真机 2026-09-22 普通用户**无参** → **裸数组** `[{tzid, temp, vtimezone}]`；包内 `webapi/openapi.json` 的 `GET /timezone`（`x-syno-version:5`）同义，回 `data.list`。 | 回包 ✅（两种形状都收） |
// | `Cal.Share.Priv/list` | 真机 2026-09-22 无参 → `{list:[{name:"admin",type:"user",uid:1024,value:"user:admin"}]}` | ✅ |
// | `Cal.Sharing/get` | 真机 2026-09-22 `{cal_id:"/demo_user/home/"}` → `{"/demo_user/home/":{DSM_GROUP:[],DSM_USER:[]}}`（**按 cal_id 分组**）；传 `id` 回 117 | ✅ |
// | `Cal.Sharing/set` | 官方客户端 `ui/synocalendar.bundle.min.js` 的 `setSharingCalendar()`：`{calId, calShareSetting:{DSM_USER:[{ug_name, cal_privilege}], DSM_GROUP:[…]}}`（参数层转 snake_case） | 客户端取证，**未真机验回包** |
// | `Cal.Event/list_color` v6 | 方法/版本真机 ✅（v1–v5 全 103）；包内 `webapi/SYNO.Cal.Event.so` 有 `GetEventColorList_v6` | **回包形状未取证** ⇒ 宽松解析 |

/// 事件/日历配色的一个候选（`Cal.Event/list_color` v6）。
///
/// ⚠️ **回包形状未取证**：真机只确认了"v6 无参调用成功"，官方客户端也**没有**
/// 调用点（`ui/` 全目录 grep `list_color` = 0 命中），包内 `openapi.json` 也没有
/// 对应 path。所以 [listFromJson] 走**宽松解析**：
///
/// * 顶层可以直接是数组，也可以是 `{…: […]}`（取第一个列表值）；
/// * 元素可以是颜色串，也可以是对象（取对象里**看起来像颜色**的那个字符串值）；
/// * `#RRGGBB` 与 `RRGGBB` 两种写法都收（官方老 UI 的 `evtColors` 就是不带 `#` 的）。
///
/// 解析不出来就回**空列表**，由界面显示"服务端没有回配色"，**绝不回退到写死的
/// 调色板** —— 那样会把"接口没接通"伪装成"功能正常"（本项目的 falsification ①）。
class CalEventColorDto {
  const CalEventColorDto({required this.color, this.name = ''});

  /// `#RRGGBB`（服务端回的裸 `RRGGBB` 会被补上 `#`，见 [_normalizeCalColor]）
  final String color;

  /// 可读名（服务端若有；没有就空串，界面只显示色块）
  final String name;

  factory CalEventColorDto.fromJson(Map<String, dynamic> json) {
    final c = _firstColorLike(json);
    return CalEventColorDto(
      color: _normalizeCalColor(c),
      name: _dualText(json, 'name', 'display_name').isNotEmpty
          ? _dualText(json, 'name', 'display_name')
          : _text(json['title']),
    );
  }

  /// 宽松解析（形状未取证，见类注释）
  static List<CalEventColorDto> listFromJson(Object? data) {
    final raw = data is Map ? _firstListValue(data) : data;
    if (raw is! List) return const [];
    final out = <CalEventColorDto>[];
    for (final e in raw) {
      if (e is String) {
        final c = _normalizeCalColor(e);
        if (c.isNotEmpty) out.add(CalEventColorDto(color: c));
      } else if (e is Map) {
        final dto = CalEventColorDto.fromJson(e.cast<String, dynamic>());
        if (dto.color.isNotEmpty) out.add(dto);
      }
    }
    return out;
  }
}

/// `data` 是 Map 时，取**第一个**值为列表的键（形状未取证时的兜底；
/// **不猜键名** —— 只按"值是不是列表"挑，避免臆造字段名）。
List<Object?> _firstListValue(Map<dynamic, dynamic> data) {
  for (final v in data.values) {
    if (v is List) return v;
  }
  return const [];
}

/// 从一个 Map 里挑第一个"看起来像颜色"的字符串值（`#RRGGBB` / `RRGGBB`）。
String _firstColorLike(Map<String, dynamic> json) {
  for (final v in json.values) {
    if (v is String && _looksLikeColor(v)) return v;
  }
  return '';
}

bool _looksLikeColor(String v) =>
    RegExp(r'^#?[0-9A-Fa-f]{6}$').hasMatch(v.trim());

/// 统一成 `#RRGGBB`；不是颜色就回空串。
String _normalizeCalColor(String raw) {
  final v = raw.trim();
  if (!_looksLikeColor(v)) return '';
  return v.startsWith('#') ? v.toUpperCase() : '#${v.toUpperCase()}';
}

/// 共享日历上的一个成员（`Cal.Sharing/get` 的 `DSM_USER`/`DSM_GROUP` 项）。
///
/// 回包形状（真机逐字）：
/// ```json
/// {"/demo_user/home/": {"DSM_GROUP": [], "DSM_USER": []}}
/// ```
/// `set` 时每一项发 `{ug_name, cal_privilege}`（官方客户端原文）。
class CalShareMemberDto {
  const CalShareMemberDto({
    required this.name,
    this.privilege = 'RO',
    this.isUser = true,
  });

  /// `ug_name` —— 用户名或群组名
  final String name;

  /// `cal_privilege` —— `RO` / `RW`
  final String privilege;

  /// true = 来自 `DSM_USER`，false = 来自 `DSM_GROUP`
  final bool isUser;

  bool get canWrite => privilege.toUpperCase().contains('W');

  /// 发回服务端的形状（官方客户端 `setSharingCalendar` 逐字）
  Map<String, Object> toApiJson() => {
    'ug_name': name,
    'cal_privilege': privilege,
  };

  factory CalShareMemberDto.fromJson(
    Map<String, dynamic> json, {
    required bool isUser,
  }) => CalShareMemberDto(
    name: _dualText(json, 'ug_name', 'name'),
    privilege: _text(json['cal_privilege'], fallback: 'RO'),
    isUser: isUser,
  );

  /// `Sharing/get` 回包 → 成员列表。
  ///
  /// 回包**按 cal_id 分组**（真机），所以先按 [calId] 取那一组；取不到就退化成
  /// "第一组"（老服务端可能只回一层）。`DSM_USER` / `DSM_GROUP` 两个数组都收。
  static List<CalShareMemberDto> listFromJson(
    Map<String, dynamic> data,
    String calId,
  ) {
    Map<String, dynamic> group = data;
    final byCal = data[calId];
    if (byCal is Map) {
      group = Map<String, dynamic>.from(byCal);
    } else {
      // 退化成第一层就是组（服务端回包没有外层 cal_id 键）
      final hasArrays = data['DSM_USER'] is List || data['DSM_GROUP'] is List;
      if (!hasArrays) {
        for (final v in data.values) {
          if (v is Map && (v['DSM_USER'] is List || v['DSM_GROUP'] is List)) {
            group = Map<String, dynamic>.from(v);
            break;
          }
        }
      }
    }
    return [
      for (final e in (group['DSM_USER'] as List? ?? const []))
        if (e is Map)
          CalShareMemberDto.fromJson(e.cast<String, dynamic>(), isUser: true),
      for (final e in (group['DSM_GROUP'] as List? ?? const []))
        if (e is Map)
          CalShareMemberDto.fromJson(e.cast<String, dynamic>(), isUser: false),
    ];
  }
}

/// 共享候选账号（`Cal.Share.Priv/list` v1，真机无参）。
///
/// 真机回包逐字：
/// `{list:[{name:"admin", type:"user", uid:1024, value:"user:admin"}, …]}`，
/// `type` = `user` / `group`。⚠️ 它和 NoteStation 的 `SYNO.NoteStation.Share.Priv/list`
/// 是**两个不同的 API**（后者回包只有 `{name, type}`），别互相套用。
class CalSharePrincipalDto {
  const CalSharePrincipalDto({
    required this.name,
    this.type = 'user',
    this.uid = 0,
    this.value = '',
  });

  final String name;

  /// `user` / `group`（服务端原文）
  final String type;

  /// `uid`（用户）/ `gid`（群组）—— **只用于匹配，不显示给用户**
  final int uid;

  /// `user:admin` 这种带类型前缀的值（服务端原文）
  final String value;

  bool get isUser => type != 'group';

  factory CalSharePrincipalDto.fromJson(Map<String, dynamic> json) =>
      CalSharePrincipalDto(
        name: _text(json['name']),
        type: _text(json['type'], fallback: 'user'),
        uid: _int(json['uid'] ?? json['gid']),
        value: _text(json['value']),
      );

  static List<CalSharePrincipalDto> listFromJson(Map<String, dynamic> data) => [
    for (final item in (data['list'] as List? ?? const []))
      if (item is Map)
        CalSharePrincipalDto.fromJson(item.cast<String, dynamic>()),
  ];
}

/// 时区（`Cal.Timezone/list`）。
///
/// 真机 2026-09-22 普通用户**无参**回的是**裸数组**（不是 `{data:{list}}`）：
/// ```json
/// [{"temp":"Africa/Abidjan","tzid":"Africa/Abidjan","vtimezone":"BEGIN:VTIMEZONE…"}]
/// ```
/// 包内 `openapi.json` 的 `GET /timezone` 是同一份语义、包成 `data.list`。
/// 所以 [listFromJson] **两种形状都收**。
class CalTimezoneDto {
  const CalTimezoneDto({required this.tzId, this.label = ''});

  /// IANA 时区 id（`Asia/Shanghai`）—— `Event/create` 的 `tz_id` 就用它
  final String tzId;

  /// 展示名（服务端 `temp` 字段；真机上与 `tzid` 相同）
  final String label;

  factory CalTimezoneDto.fromJson(Map<String, dynamic> json) => CalTimezoneDto(
    tzId: _dualText(json, 'tzid', 'time_zone'),
    label: _dualText(json, 'temp', 'display_name'),
  );

  /// 宽松解析：**裸数组**（真机）与 `{list:[…]}`（openapi）都收。
  static List<CalTimezoneDto> listFromJson(Object? data) {
    final raw = data is Map ? _firstListValue(data) : data;
    if (raw is! List) return const [];
    final out = <CalTimezoneDto>[];
    final seen = <String>{};
    for (final e in raw) {
      if (e is! Map) continue;
      final dto = CalTimezoneDto.fromJson(e.cast<String, dynamic>());
      if (dto.tzId.isEmpty || !seen.add(dto.tzId)) continue;
      out.add(dto);
    }
    out.sort((a, b) => a.tzId.compareTo(b.tzId));
    return out;
  }
}

/// 待办搜索结果（`SYNO.Cal.Todo/search` **v1**）。
///
/// 真机回包**逐字**（2026-09-22，普通用户；`cal_id` 或 `keyword` 都实测可调）：
/// ```json
/// {"data":{"evt_list_result":[],"total":0}}
/// ```
///
/// ⚠️ **root 是 `evt_list_result`，不是 `todolist`**（也不是 `list`）——
/// `evt_list_result` 这个键名在包内二进制 `lib/libsynocalcore.so.6.1`
/// 里能直接查到，`SYNO.Cal.Todo/search` 就是拿它当结果数组。
/// 取错键会把"有结果"显示成"空"，是本轮 falsification ③ 的靶子。
///
/// ⚠️ 元素形状按 [CalTodoDto.fromJson] 的**双命名兼容**解析
/// （`evt_cal`/`cal_id`、`dtstart`/`start`、`tzid`/`tz_id`）——与 `Todo/list`
/// 同一套，`search` 没有单独取证到元素键名，所以不复用会丢字段。
class CalTodoSearchResultDto {
  const CalTodoSearchResultDto({this.items = const [], this.total = 0});

  final List<CalTodoDto> items;

  /// 服务端的 `total`（**不一定等于 `items.length`**：服务端可能分页/截断，
  /// 所以"空态"要看这个值，不能只看列表长不长）。
  final int total;

  /// `total` 缺失时退回 `items.length`（老回包/空对象）——"空"与"未知"都落 0。
  int get count => total > 0 ? total : items.length;

  bool get isEmpty => items.isEmpty;

  factory CalTodoSearchResultDto.fromJson(Map<String, dynamic> data) =>
      CalTodoSearchResultDto(
        items: [
          for (final item in (data['evt_list_result'] as List? ?? const []))
            if (item is Map) CalTodoDto.fromJson(item.cast<String, dynamic>()),
        ],
        total: _int(data['total']),
      );
}
