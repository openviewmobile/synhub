// Phase 9：免打扰（snooze）—— 服务端存储 + 本地镜像 + 通知门禁。
//
// 原版的三块拼图（都在 APK 里核对过）：
//
//   1. `AccountManager.setSnooze(duration)`：
//      `snooze = System.currentTimeMillis() + timeDiff + duration`，
//      再 `User.Preference / set`（**v1**，字段 `snooze`）；返回值是服务端时钟的
//      绝对毫秒，客户端 `preferencesHelper.setSnooze(值)` 直接存。
//      `duration == 0` 就是"关闭免打扰"（弹窗里那个 off）。
//   2. `AccountManager.getSnooze()`：`User.Preference / get`
//      （版本 `maxAvailableVersion(3, 1)`），`snooze > 0` 时换算成本地时钟存下来。
//      **登录/每次同步都会拉一次**（`SyncWorker.fetchData` 里的一个 flatMap）。
//   3. 定时免打扰：`snooze_schedule_enable/start/end`，`start/end` 是**当天秒数**；
//      `set` 走 **v3**（老服务端 `maxVersion < 3` 直接报版本错，界面也不显示这项）。
//
// 时间窗判定是照抄 `SubItem.bindSnoozeIcon`（原版唯一一处"现在算不算免打扰"的逻辑）：
//
//     start >= end ? (start <= now || now <= end)   // 跨午夜
//                  : (start <= now && now <= end)   // 同一天
//
// 两端都是**闭区间**（`<=`）。原版用的是"我现在在哪个时区"（设备本地），
// 只是顺带把服务端下发的 `timezoneUTC` 显示在定时免打扰页上，所以我们也按
// **设备本地时区**算（同一台手机就是用户所在时区，也省掉一个 tz 数据库依赖）。
//
// 与原版的差异（有意）：
//   * 原版靠**服务端不推推送**来静音；我们走本地通知，所以在弹通知前自己判一次
//     [SnoozeState.suppressesAt]（通知栏动作「贪睡」= 设 1 小时全局免打扰，
//     与 `NotificationActionWorker.setSnooze` 一致）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../data/chat_api.dart';
import '../../data/dto/user_preference_dto.dart';
import '../chat/chat_session_controller.dart';
import '../../core/settings/app_settings.dart';

/// 免打扰时长档位（照抄 `SnoozeFragment.onSnoozeClicked`：20 分钟 / 1·2·4·8·24 小时）
class SnoozeOption {
  const SnoozeOption(this.label, this.duration);

  /// 中文标签（**回落**：无 context 的地方与老测试还用得上；界面走 [labelIn]）
  final String label;
  final Duration duration;

  /// 本地化标签
  String labelIn(AppText t) => switch (duration.inMinutes) {
    0 => t.snoozeDisable,
    20 => t.snooze20Minutes,
    60 => t.snooze1Hour,
    120 => t.snooze2Hours,
    240 => t.snooze4Hours,
    480 => t.snooze8Hours,
    1440 => t.snooze24Hours,
    _ => label,
  };

  /// 「关闭免打扰」
  static const SnoozeOption off = SnoozeOption('关闭免打扰', Duration.zero);

  static const List<SnoozeOption> all = <SnoozeOption>[
    SnoozeOption('20 分钟', Duration(minutes: 20)),
    SnoozeOption('1 小时', Duration(hours: 1)),
    SnoozeOption('2 小时', Duration(hours: 2)),
    SnoozeOption('4 小时', Duration(hours: 4)),
    SnoozeOption('8 小时', Duration(hours: 8)),
    SnoozeOption('24 小时', Duration(hours: 24)),
  ];
}

/// 「现在」是否落在定时免打扰的时间窗里（纯函数，照抄 `SubItem.bindSnoozeIcon`）。
///
/// [secondsOfDay] 是**本地**当天已过秒数（0..86399）。
bool snoozeScheduleActive({
  required int secondsOfDay,
  required int startSecond,
  required int endSecond,
}) {
  final now = secondsOfDay.clamp(0, 86399);
  if (startSecond >= endSecond) {
    // 跨午夜（例如 22:00–06:00）：start 之后，或 end 之前
    return startSecond <= now || now <= endSecond;
  }
  return startSecond <= now && now <= endSecond;
}

/// 本地当天已过秒数
int secondsOfLocalDay(DateTime local) =>
    local.hour * 3600 + local.minute * 60 + local.second;

/// `HH:mm`（原版 `String.format("%02d:%02d", s/3600, (s%3600)/60)`）
String formatSecondsOfDay(int seconds) {
  final s = seconds.clamp(0, 86399);
  final h = s ~/ 3600;
  final m = (s - h * 3600) ~/ 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// 「剩余 HH:MM:SS」（原版 `SnoozeFragment.invalidate` 的格式）
String formatSnoozeRemaining(Duration left) {
  final total = left.isNegative ? Duration.zero : left;
  final h = total.inHours;
  final m = total.inMinutes - h * 60;
  final s = total.inSeconds - total.inMinutes * 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}';
}

/// 免打扰状态（服务端偏好 + 本地镜像）
@immutable
class SnoozeState {
  const SnoozeState({
    this.snoozeUntilMs = 0,
    this.scheduleEnabled = false,
    this.scheduleStartSecond = UserPreferenceDto.kDefaultSnoozeScheduleStart,
    this.scheduleEndSecond = UserPreferenceDto.kDefaultSnoozeScheduleEnd,
    this.maxVersion = 0,
    this.timezoneUtc = '',
    this.loaded = false,
  });

  /// 免打扰截止（**设备时钟**毫秒；0 = 没开）
  final int snoozeUntilMs;

  final bool scheduleEnabled;
  final int scheduleStartSecond;
  final int scheduleEndSecond;

  /// `SYNO.Chat.User.Preference` 的 maxVersion（0 = 还没探测到 / 不支持）
  final int maxVersion;

  /// 服务端下发的 IANA 时区（`user_props.timezoneUTC`，只用于展示）
  final String timezoneUtc;

  /// 是否已经从服务端/缓存读到过
  final bool loaded;

  /// 定时免打扰这项在当前服务端是否可见（原版 `support(User.Preference, 3)`）
  bool get supportsSchedule => maxVersion >= 3;

  /// 手动免打扰还剩多久（没开 = 0）
  Duration remainingAt(DateTime now) {
    final left = snoozeUntilMs - now.millisecondsSinceEpoch;
    return left <= 0 ? Duration.zero : Duration(milliseconds: left);
  }

  bool get manualActiveNow => remainingAt(DateTime.now()) > Duration.zero;

  /// 这一刻该不该静音（手动免打扰 或 定时免打扰命中）
  bool suppressesAt(DateTime now) {
    if (remainingAt(now) > Duration.zero) return true;
    if (!scheduleEnabled) return false;
    return snoozeScheduleActive(
      secondsOfDay: secondsOfLocalDay(now),
      startSecond: scheduleStartSecond,
      endSecond: scheduleEndSecond,
    );
  }

  SnoozeState copyWith({
    int? snoozeUntilMs,
    bool? scheduleEnabled,
    int? scheduleStartSecond,
    int? scheduleEndSecond,
    int? maxVersion,
    String? timezoneUtc,
    bool? loaded,
  }) => SnoozeState(
    snoozeUntilMs: snoozeUntilMs ?? this.snoozeUntilMs,
    scheduleEnabled: scheduleEnabled ?? this.scheduleEnabled,
    scheduleStartSecond: scheduleStartSecond ?? this.scheduleStartSecond,
    scheduleEndSecond: scheduleEndSecond ?? this.scheduleEndSecond,
    maxVersion: maxVersion ?? this.maxVersion,
    timezoneUtc: timezoneUtc ?? this.timezoneUtc,
    loaded: loaded ?? this.loaded,
  );
}

final snoozeControllerProvider =
    NotifierProvider<SnoozeController, SnoozeState>(SnoozeController.new);

class SnoozeController extends Notifier<SnoozeState> {
  @override
  SnoozeState build() {
    // 服务端支持度可以从 API 表直接读（表里没这个 API = 老服务端）
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    return SnoozeState(
      maxVersion:
          api?.api.apiTable?['SYNO.Chat.User.Preference']?.maxVersion ?? 0,
    );
  }

  SettingsService get _settings => ref.read(settingsServiceProvider);

  /// 启动时把上次的本地镜像读进来（离线也知道自己在免打扰）
  Future<void> preload() async {
    final cached = await _settings.userPreferenceJson();
    final tz = await _settings.myTimezoneUtc();
    final dto = UserPreferenceDto.tryDecode(cached);
    _applyDto(dto, timezoneUtc: tz, loaded: false);
  }

  /// 登录后/每次同步拉一次服务端偏好（原版在 `SyncWorker.fetchData` 里做）
  Future<void> refresh() async {
    final sync = ref.read(chatSessionControllerProvider);
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    if (api == null) return;
    // 服务端时差：服务端时钟 = 设备时钟 + skew
    final skew = sync.clockSkewMillis;
    try {
      final pref = await api.userPreferenceGet();
      state = state.copyWith(
        maxVersion:
            api.api.apiTable?['SYNO.Chat.User.Preference']?.maxVersion ??
            state.maxVersion,
      );
      _applyDto(pref, timezoneUtc: state.timezoneUtc, skewMillis: skew);
      await _settings.setUserPreferenceJson(pref.encode());
      // 顺手把用户时区存下来（`user_props.timezoneUTC`）
      await _cacheTimezoneFromUsers(api);
      debugPrint(
        '[snooze] 服务端偏好：$pref（+skew=${skew}ms → 本地 '
        '${state.snoozeUntilMs}）',
      );
    } catch (e) {
      debugPrint('[snooze] 拉用户偏好失败（用本地镜像）：$e');
    }
  }

  /// 从 `User/list` 里抠出我自己的 `timezoneUTC`（原版存在 users 表的 timezone_utc）
  Future<void> _cacheTimezoneFromUsers(ChatApi api) async {
    final me = ref.read(chatSessionControllerProvider).myUserId;
    if (me <= 0) return;
    try {
      final users = await api.listUsersByIds([me]);
      if (users.isEmpty) return;
      final tz = users.first.timezoneUtc;
      if (tz.isEmpty || tz == state.timezoneUtc) return;
      state = state.copyWith(timezoneUtc: tz);
      await _settings.setMyTimezoneUtc(tz);
    } catch (e) {
      debugPrint('[snooze] 取用户时区失败：$e');
    }
  }

  /// 设免打扰：`duration` 为 0 = 关闭。返回服务端确认后的本地截止时间（0 = 关）。
  ///
  /// 原版 `AccountManager.setSnooze` 返回的是**服务端时钟**的截止时间，
  /// 客户端直接用；我们也按服务端返回校准（拿不到就用本地推算值）。
  Future<int> setSnooze(Duration duration) async {
    final sync = ref.read(chatSessionControllerProvider);
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    final now = DateTime.now();
    if (duration <= Duration.zero) {
      if (api != null) {
        await api.setUserSnooze(0);
      }
      state = state.copyWith(snoozeUntilMs: 0, loaded: true);
      await _persistLocal();
      return 0;
    }
    if (api == null) throw StateError(platformText().meNotLoggedIn);
    final skew = sync.clockSkewMillis;
    final serverTarget =
        now.millisecondsSinceEpoch + skew + duration.inMilliseconds;
    await api.setUserSnooze(serverTarget);
    // 服务端不返回截止时间（`BasicVo`），按本地时钟记下同一时刻
    final localUntil = now.millisecondsSinceEpoch + duration.inMilliseconds;
    state = state.copyWith(snoozeUntilMs: localUntil, loaded: true);
    await _persistLocal();
    debugPrint(
      '[snooze] 免打扰到 ${DateTime.fromMillisecondsSinceEpoch(localUntil)} '
      '（服务端时钟 $serverTarget）',
    );
    return localUntil;
  }

  /// 定时免打扰（v3）：开关 + 起止（当天秒数）
  Future<void> setSchedule({
    required bool enable,
    required int startSecond,
    required int endSecond,
  }) async {
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    if (api == null) throw StateError(platformText().meNotLoggedIn);
    await api.setUserSnoozeSchedule(
      enable: enable,
      startSecond: startSecond,
      endSecond: endSecond,
    );
    state = state.copyWith(
      scheduleEnabled: enable,
      scheduleStartSecond: startSecond,
      scheduleEndSecond: endSecond,
      loaded: true,
    );
    await _persistLocal();
  }

  /// 把服务端偏好合成进状态（[skewMillis] = 服务端 - 设备）
  void _applyDto(
    UserPreferenceDto? dto, {
    String? timezoneUtc,
    int skewMillis = 0,
    bool loaded = true,
  }) {
    if (dto == null) {
      state = state.copyWith(
        loaded: loaded || state.loaded,
        timezoneUtc: timezoneUtc ?? state.timezoneUtc,
      );
      return;
    }
    final localUntil = dto.snooze > 0
        ? dto.snooze - skewMillis
        : state.snoozeUntilMs;
    state = state.copyWith(
      // 服务端说 0 = 没开；但本地镜像比服务端新时（离线设的）保留本地值
      snoozeUntilMs: dto.snooze > 0 ? localUntil : state.snoozeUntilMs,
      scheduleEnabled: dto.scheduleEnabled,
      scheduleStartSecond: dto.scheduleStartSecond,
      scheduleEndSecond: dto.scheduleEndSecond,
      timezoneUtc: timezoneUtc ?? state.timezoneUtc,
      loaded: loaded,
    );
  }

  Future<void> _persistLocal() async {
    final dto = UserPreferenceDto(
      snooze: state.snoozeUntilMs,
      scheduleEnabled: state.scheduleEnabled,
      scheduleStartSecond: state.scheduleStartSecond,
      scheduleEndSecond: state.scheduleEndSecond,
    );
    await _settings.setUserPreferenceJson(dto.encode());
  }
}

/// 免打扰的便利判断（通知里用）
extension SnoozeQuery on SnoozeState {
  /// 现在该不该静音（手动 + 定时）
  bool get suppressesNow => suppressesAt(DateTime.now());

  /// 界面上那行副标题（**中文回落**；界面走 [subtitleIn]）
  String subtitleAt(DateTime now) {
    if (supportsSchedule && scheduleEnabled) {
      return '定时 ${formatSecondsOfDay(scheduleStartSecond)}'
          '–${formatSecondsOfDay(scheduleEndSecond)}'
          '${remainingAt(now) > Duration.zero ? '，手动剩 ${formatSnoozeRemaining(remainingAt(now))}' : ''}';
    }
    final left = remainingAt(now);
    return left > Duration.zero ? '剩余 ${formatSnoozeRemaining(left)}' : '关闭';
  }

  /// 界面上那行副标题（按当前语言取文案）
  String subtitleIn(AppText t, DateTime now) {
    final left = remainingAt(now);
    if (supportsSchedule && scheduleEnabled) {
      final start = formatSecondsOfDay(scheduleStartSecond);
      final end = formatSecondsOfDay(scheduleEndSecond);
      return left > Duration.zero
          ? t.snoozeSubtitleScheduleManual(
              start,
              end,
              formatSnoozeRemaining(left),
            )
          : t.snoozeSubtitleSchedule(start, end);
    }
    return left > Duration.zero
        ? t.snoozeSubtitleRemaining(formatSnoozeRemaining(left))
        : t.snoozeStatusOff;
  }
}
