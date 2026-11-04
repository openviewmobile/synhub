// 本地设置（偏好）层。
//
// 原版把这些散在 4 套存储里（`PreferencesHelper` 自己一套、`androidx.preference`
// 默认 SharedPreferences 一套、passcode 一套、其余零散），key 名也各不相同。
// 我们统一放 **Drift 的键值表**（`keyValueRows`，E2EE 身份也用这张表）：
//   * 不新增插件依赖，离线测试里也能真读写；
//   * key 名沿用原版的（`dark_mode` / `upload_quality` / `set_cache_limit` …），
//     便于跟反编译结果对照。
//
// 已核对的 key 与取值（`docs/recheck/g-settings-misc.md` §3）：
//   * `dark_mode`：int，`-1` 跟随系统（默认）、`1` 浅色、`2` 深色
//     （`arrays.xml` 的 `dark_mode_values`）
//   * `upload_quality`：String，`standard`（默认）/ `original`
//     （⚠️ 不是 `image_upload_quality`，那个只是 UI key）
//   * `set_cache_limit`：int 字节，默认 524288000；候选值 10485760 / 52428800 /
//     104857600 / 524288000 / 1073741814 / 0（0 = 不限；`1073741814` 是原版
//     写死的"1GB"，**照抄别"修正"成 2^30**）
//   * 应用锁：`passcode_enable`(bool) / `passcode_change`(String) /
//     `passcode_expiration`(String，默认 `ALWAYS`) /
//     `passcode_fingerprint_enable`(bool)
import 'dart:async';
import 'dart:convert';
import '../i18n/data_text.dart';
import '../i18n/l10n.dart';
import '../../features/notes/note_leave_encrypt.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/channel_sort.dart';
import '../media/cache_service.dart';
import '../../features/chat/media_stream.dart';
import '../../data/local/chat_store.dart';
import '../device/device_profile.dart';
import '../../data/ai/image_edit_pricing.dart' show kImageEditDefaultDailyCap;
import 'native_locale_mirror.dart';
import '../../features/chat/chat_session_controller.dart'
    show chatStoreProvider;

/// 界面语言（**本地偏好**，我们的键；原版 Chat 是跟系统语言走，
/// 我们用 `AndroidManifest` 的 `android:localeConfig` 同时接系统 per-app 语言，
/// 这里再给一个 app 内开关）。
enum LocaleChoice {
  system('system', null),
  zh('zh', Locale('zh')),
  en('en', Locale('en'));

  const LocaleChoice(this.rawValue, this.locale);

  final String rawValue;

  /// `null` = 跟随系统（交给 Flutter 的 localeResolutionCallback）
  final Locale? locale;

  static LocaleChoice fromName(String raw) => switch (raw) {
    'zh' => LocaleChoice.zh,
    'en' => LocaleChoice.en,
    _ => LocaleChoice.system,
  };
}

/// 界面语言偏好的 key（本地偏好，不跟原版共用）
const String kLocaleKey = 'app_locale';

/// 主题偏好：对应原版 `dark_mode` 的 `-1/1/2`
enum AppThemeChoice {
  system(-1, ThemeMode.system),
  light(1, ThemeMode.light),
  dark(2, ThemeMode.dark);

  const AppThemeChoice(this.rawValue, this.mode);

  /// 原版存进偏好的整数值
  final int rawValue;
  final ThemeMode mode;

  /// 主题文案（**中文回落**，走 dataText；界面也可用 `t.themeSystem` 等）
  String get label => switch (this) {
    AppThemeChoice.system => dataText('themeSystem', '跟随系统'),
    AppThemeChoice.light => dataText('themeLight', '浅色'),
    AppThemeChoice.dark => dataText('themeDark', '深色'),
  };

  static AppThemeChoice fromRaw(int raw) => switch (raw) {
    1 => AppThemeChoice.light,
    2 => AppThemeChoice.dark,
    _ => AppThemeChoice.system,
  };

  static AppThemeChoice fromName(String name) => switch (name) {
    'light' => AppThemeChoice.light,
    'dark' => AppThemeChoice.dark,
    _ => AppThemeChoice.system,
  };
}

/// 发送图片的质量（原版 `upload_quality`）
enum ImageQuality {
  standard('standard', '标准', '压缩后再发，省流量'),
  original('original', '原图', '不重新编码，保留原始画质');

  const ImageQuality(this.rawValue, this.label, this.description);

  final String rawValue;
  final String label;
  final String description;

  static ImageQuality fromRaw(String raw) =>
      raw == 'original' ? ImageQuality.original : ImageQuality.standard;
}

/// 缓存上限的 6 档（原版 `cache_size_values`，字节）
const List<({int bytes, String label})> kCacheLimitOptions = [
  (bytes: 10485760, label: '10 MB'),
  (bytes: 52428800, label: '50 MB'),
  (bytes: 104857600, label: '100 MB'),
  (bytes: 524288000, label: '500 MB'),
  (bytes: 1073741814, label: '1 GB'),
  // 0 = 不限制；展示一律走 `_limitLabel(t, 0)` / `photoCacheLimitLabel(0)`，
  // 这里不再放中文（否则英文模式下会漏出去）。
  (bytes: 0, label: ''),
];

/// 默认缓存上限：500 MB（原版默认值）
const int kDefaultCacheLimitBytes = 524288000;

/// 回车发送的偏好 key（原版 `Common.ARG_SEND_BY_ENTER`）
const String kSendByEnterKey = 'sendByEnter';

/// UI 风格的本地偏好（**不是**原版设置，纯本地）：
/// Material You 动态取色、性能模式、减少动效。
const String kDynamicColorKey = 'ui_dynamic_color';

/// AI 悬浮球的停靠位置（见 `AiOrbState`）
const String kAiOrbKey = 'ai_orb_pos';

/// 日历环境信息设置（地区 / 单位 / 天气源覆盖）
const String kCalendarEnvKey = 'calendar_env';

/// 节假日缓存（`{ "CN|2026": {...} }`）
const String kCalendarHolidayCacheKey = 'calendar_holiday_cache';
const String kPerfModeKey = 'ui_perf_mode';
const String kReducedMotionKey = 'ui_reduced_motion';

/// 聊天页的 HUD 网格底纹（默认开，纯本地偏好）
const String kChatGridKey = 'ui_chat_grid';

/// 消息预加载档位的偏好 key（原版 `Common.ARG_POST_PREVIEW_MODE`）
const String kPostPreviewModeKey = 'post_preview_mode';

/// 「收到消息通知时预加载消息」（原版 `PostPreviewWorker.PreviewMode`）。
///
/// 取值/文案逐行对位 `arrays.xml` 的 `preview_new_message_values` 与
/// `strings.xml` 的 `preview_*`。
enum PostPreviewMode {
  close('CLOSE', '关闭'),
  onlyWifi('ONLY_WIFI', '仅在使用 Wi-Fi 时'),
  wifiAndOther('WIFI_AND_OTHER', '使用 Wi-Fi 或移动数据时');

  const PostPreviewMode(this.rawValue, this.label);

  final String rawValue;
  final String label;

  /// 本地化文案：界面用 `labelIn(context.t)`（英文环境才真的会变英文）。
  /// `label` 保留为**中文回落**，给没有 context 的地方与老测试用。
  String labelIn(AppText t) => switch (this) {
    PostPreviewMode.close => t.previewModeClose,
    PostPreviewMode.onlyWifi => t.previewModeWifi,
    PostPreviewMode.wifiAndOther => t.previewModeWifiAndData,
  };

  /// 原版 `PreviewMode.fromName`：认不出的（含空串）→ 默认档 `ONLY_WIFI`
  static PostPreviewMode fromName(String name) =>
      PostPreviewMode.values.firstWhere(
        (m) => m.rawValue == name,
        orElse: () => PostPreviewMode.onlyWifi,
      );
}

/// 应用锁的重新认证间隔（原版 `passcode_expiration`）
enum PasscodeExpiration {
  always('ALWAYS', '每次都要求', Duration.zero),
  oneMinute('MIN_1', '1 分钟后', Duration(minutes: 1)),
  twoMinutes('MIN_2', '2 分钟后', Duration(minutes: 2)),
  fiveMinutes('MIN_5', '5 分钟后', Duration(minutes: 5)),
  tenMinutes('MIN_10', '10 分钟后', Duration(minutes: 10)),
  thirtyMinutes('MIN_30', '30 分钟后', Duration(minutes: 30));

  const PasscodeExpiration(this.rawValue, this.label, this.grace);

  final String rawValue;

  /// **中文回落**（不带 i18n 的场合用）。界面一律走 [labelIn]。
  ///
  /// ★★ DA17（r360 真机）：这一列原来被 `settings_page.dart` **直接**渲染
  /// （`Text(_expiration.label)`）⇒ 英文界面里这一行永远是中文 `每次都要求`。
  /// 根因**不是**"key 漏登记"，而是**根本没有 key** —— 枚举里塞的是中文成品串。
  /// 修法同 DA11：给枚举配一个显式的本地化出口 [labelIn]。
  final String label;

  /// 退到后台多久之内回来不用重新输密码
  final Duration grace;

  /// 界面用的本地化文案（英文界面上**不许**再出现中文）。
  ///
  /// 与 `settings_page.dart` 里生物识别那行（`_bioLabelIn`）、
  /// `ChannelSortTarget.labelIn` 同一套写法：中文成品串只做回落，
  /// 界面取的是 `AppText` 里登记的 key。
  String labelIn(AppText t) => switch (this) {
    PasscodeExpiration.always => t.passcodeReauthAlways,
    PasscodeExpiration.oneMinute => t.passcodeReauthMinutes(1),
    PasscodeExpiration.twoMinutes => t.passcodeReauthMinutes(2),
    PasscodeExpiration.fiveMinutes => t.passcodeReauthMinutes(5),
    PasscodeExpiration.tenMinutes => t.passcodeReauthMinutes(10),
    PasscodeExpiration.thirtyMinutes => t.passcodeReauthMinutes(30),
  };

  static PasscodeExpiration fromRaw(String raw) =>
      PasscodeExpiration.values.firstWhere(
        (e) => e.rawValue == raw,
        orElse: () => PasscodeExpiration.always,
      );
}

/// 侧栏「排序方式」的四个分组（原版 `preference_sort_method.xml` 的四个 key）
enum ChannelSortTarget {
  favorite('favorite_sort_by', '已加星标'),
  channel('channel_sort_by', '频道'),
  conversation('conversation_sort_by', '会话'),
  chatbot('chat_bot_sort_by', '机器人');

  const ChannelSortTarget(this.key, this.label);

  final String key;
  final String label;

  /// 本地化文案（`label` 是中文回落）
  String labelIn(AppText t) => switch (this) {
    ChannelSortTarget.favorite => t.sortTargetFavorite,
    ChannelSortTarget.channel => t.sortTargetChannel,
    ChannelSortTarget.conversation => t.sortTargetConversation,
    ChannelSortTarget.chatbot => t.sortTargetChatbot,
  };
}

/// 设置的读写门面。所有方法都不抛：读失败给默认值，写失败静默。
class SettingsService {
  SettingsService(this._store);

  final ChatStore _store;

  Future<String?> _get(String key) async {
    try {
      return await _store.setting(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _set(String key, String value) async {
    try {
      await _store.setSetting(key, value);
    } catch (_) {
      // 设置写不进去不该影响使用
    }
  }

  /// 删除一个小状态（原版 `ChatChannelPosting` 里草稿清空是 **DELETE 行**，
  /// 不是存空串 —— 见 `DatabaseHelper.saveChannelPostingText:3040-3055`）。
  Future<void> _remove(String key) async {
    try {
      await _store.deleteSetting(key);
    } catch (_) {
      // 同上：删不掉就当没存过
    }
  }

  // ------------------------------------------------------------ 主题

  Future<AppThemeChoice> themeChoice() async =>
      AppThemeChoice.fromRaw(int.tryParse(await _get('dark_mode') ?? '') ?? -1);

  Future<void> setThemeChoice(AppThemeChoice choice) =>
      _set('dark_mode', '${choice.rawValue}');

  // ------------------------------------------------------------ 图片质量

  Future<ImageQuality> imageQuality() async =>
      ImageQuality.fromRaw(await _get('upload_quality') ?? 'standard');

  Future<void> setImageQuality(ImageQuality q) =>
      _set('upload_quality', q.rawValue);

  // ------------------------------------------------------------ 缓存

  Future<int> cacheLimitBytes() async =>
      int.tryParse(await _get('set_cache_limit') ?? '') ??
      kDefaultCacheLimitBytes;

  Future<void> setCacheLimitBytes(int bytes) =>
      _set('set_cache_limit', '$bytes');

  // ------------------------------------------------------------ 工作台

  /// 工作台入口的使用次数（JSON `{入口 id: 次数}`，**纯本地**
  /// —— 用来把常用的模块排到第一屏，见 `workspace_providers.dart`）。
  Future<String?> workspaceUsageRaw() => _get('workspace_usage');

  /// 传空串 = 清空统计（"恢复默认顺序"）。
  Future<void> setWorkspaceUsageRaw(String json) =>
      _set('workspace_usage', json);

  /// 被收进第二屏的工作台入口（JSON 数组，**纯本地**）。
  ///
  /// 由「使用分析」的"从没用过的模块"结论一键应用，工作台里也能随时「显示全部」
  /// 还原 —— 策略调整必须可逆、可见，见 `docs/usage-analytics-plan.md` §6。
  Future<String?> workspaceHiddenRaw() => _get('workspace_hidden');

  Future<void> setWorkspaceHiddenRaw(String json) =>
      _set('workspace_hidden', json);

  /// 工作台「最近常用」的记录（JSON 数组，**纯本地**）。
  ///
  /// 与 `workspace_usage`（点击次数）分开存：次数是"长期习惯"、只用来排网格；
  /// 这里是"最近真的打开过谁"，用来做动态入口，见
  /// `lib/src/features/shell/workspace_recent.dart`。
  Future<String?> workspaceRecentRaw() => _get('workspace_recent');

  /// 传空串 = 清空记录。
  Future<void> setWorkspaceRecentRaw(String json) =>
      _set('workspace_recent', json);

  // ---------------------------------------------------------- 阅读器

  /// 正文字号（逻辑像素；14 / 16 / 18 / 20 / 22 五档，默认 16）
  Future<double> readerFontSize() async =>
      double.tryParse(await _get('reader_font_size') ?? '') ?? 16;

  Future<void> setReaderFontSize(double v) =>
      _set('reader_font_size', v.toStringAsFixed(1));

  /// 正文行距倍数（1.3 / 1.5 / 1.7 / 2.0，默认 1.5）
  Future<double> readerLineHeight() async =>
      double.tryParse(await _get('reader_line_height') ?? '') ?? 1.5;

  Future<void> setReaderLineHeight(double v) =>
      _set('reader_line_height', v.toStringAsFixed(2));

  /// 阅读主题：`normal`（默认，跟 App 主题）/ `sepia`（护眼米黄）/ `night`（纯黑）
  Future<String> readerTheme() async => await _get('reader_theme') ?? 'normal';

  Future<void> setReaderTheme(String v) => _set('reader_theme', v);

  /// 正文两端对齐（默认关：中文长段落两端对齐会出现大空隙）
  Future<bool> readerJustify() async =>
      (await _get('reader_justify') ?? 'false') == 'true';

  // ------------------------------------- I5：退出加密时删附件（官方同名偏好）

  /// ★ 官方 DSnote 偏好 `delete_attachments_when_leave_encrypt`
  /// （Java 常量 `DELETE_ATTACH_WHEN_LEAVE_ENCRYPT`）。
  Future<bool> leaveEncryptDeleteAttachments() async =>
      decodeLeaveEncryptPreference(
        await _get('delete_attachments_when_leave_encrypt'),
      );

  Future<void> setLeaveEncryptDeleteAttachments(bool v) => _set(
    'delete_attachments_when_leave_encrypt',
    encodeLeaveEncryptPreference(v),
  );

  Future<void> setReaderJustify(bool v) =>
      _set('reader_justify', v ? 'true' : 'false');

  // ---------------------------------------------------------- 端侧 AI

  /// 端侧 AI 功能总开关（默认开：入口可见，没装模型时用内置摘要兜底）
  Future<bool> aiEnabled() async =>
      (await _get('ai_enabled') ?? 'true') == 'true';

  Future<void> setAiEnabled(bool v) => _set('ai_enabled', v ? 'true' : 'false');

  /// 只在 WiFi 下下载模型（默认开：几百 MB 不该吃掉流量）
  Future<bool> aiWifiOnly() async =>
      (await _get('ai_wifi_only') ?? 'true') == 'true';

  Future<void> setAiWifiOnly(bool v) =>
      _set('ai_wifi_only', v ? 'true' : 'false');

  /// 选中的端侧模型 id（目录里的 id；空 = 用推荐档）
  Future<String?> aiModelId() => _get('ai_model_id');

  Future<void> setAiModelId(String id) => _set('ai_model_id', id);

  /// 模型目录版本：以后换默认档位时，用它判断"要不要提示重下"
  Future<int> aiCatalogVersion() async =>
      int.tryParse(await _get('ai_catalog_version') ?? '') ?? 1;

  Future<void> setAiCatalogVersion(int v) => _set('ai_catalog_version', '$v');

  // ------------------------------------------------------------ 云端大模型
  //
  // 存什么、不存什么（安全边界）：
  //   * **API Key 不在这里** —— 它走 `cloud_key_store.dart` 的系统安全存储
  //     （Android Keystore / iOS Keychain），普通偏好表里只留"用哪家、哪个模型"。
  //   * 这里存：档位（云端/端侧/内置摘要）、厂商 id、base URL、模型 id、
  //     采样参数、以及**拉回来的模型列表缓存**（离线也能把上次的候选列出来）。

  /// 服务档位：`cloud` / `onDevice` / `auto`（默认 cloud —— 端侧能力弱，
  /// 云端才是主力；没配好的时候会自动回落到端侧/内置摘要，功能不会消失）
  Future<String> aiTier() async => await _get('ai_tier') ?? 'cloud';

  Future<void> setAiTier(String v) => _set('ai_tier', v);

  /// 云端厂商 id（`kCloudProviders` 里的 id）
  Future<String?> aiCloudProviderId() => _get('ai_cloud_provider');

  Future<void> setAiCloudProviderId(String id) => _set('ai_cloud_provider', id);

  /// base URL（自定义厂商必填；预设厂商允许用户改，比如换成中转地址）
  Future<String?> aiCloudBaseUrl() => _get('ai_cloud_base_url');

  Future<void> setAiCloudBaseUrl(String v) => _set('ai_cloud_base_url', v);

  /// 选中的云端模型 id
  Future<String?> aiCloudModel() => _get('ai_cloud_model');

  Future<void> setAiCloudModel(String v) => _set('ai_cloud_model', v);

  /// 自定义厂商的协议（`openai` / `anthropic` / `gemini`）
  Future<String> aiCloudProtocol() async =>
      await _get('ai_cloud_protocol') ?? 'openai';

  Future<void> setAiCloudProtocol(String v) => _set('ai_cloud_protocol', v);

  /// 采样参数（云端）：温度和最大输出
  Future<double> aiCloudTemperature() async =>
      double.tryParse(await _get('ai_cloud_temperature') ?? '') ?? 0.6;

  Future<void> setAiCloudTemperature(double v) =>
      _set('ai_cloud_temperature', '$v');

  Future<int> aiCloudMaxTokens() async =>
      int.tryParse(await _get('ai_cloud_max_tokens') ?? '') ?? 1024;

  Future<void> setAiCloudMaxTokens(int v) => _set('ai_cloud_max_tokens', '$v');

  /// 模型列表缓存：`{providerId: [id, ...]}`（JSON 串）
  Future<String?> aiCloudModelCache() => _get('ai_cloud_model_cache');

  Future<void> setAiCloudModelCache(String v) =>
      _set('ai_cloud_model_cache', v);

  /// **多套配置并存**：配置列表（JSON 数组）+ 当前选中的配置 id。
  ///
  /// 老版本的单套配置键（上面那几个 `ai_cloud_*`）仍然会同步写，
  /// 一是兼容老读法，二是老用户升级时的**迁移来源**（见 `cloud_settings.dart`
  /// 的 `preload`：没有配置列表就把老键收成第一套配置，id 用老 providerId，
  /// 于是安全存储里老的 key 槽位原样命中）。key 本身依旧不在这里。
  Future<String?> aiCloudProfiles() => _get('ai_cloud_profiles');

  Future<void> setAiCloudProfiles(String v) => _set('ai_cloud_profiles', v);

  Future<String?> aiCloudActiveProfile() => _get('ai_cloud_active_profile');

  Future<void> setAiCloudActiveProfile(String v) =>
      _set('ai_cloud_active_profile', v);

  /// 云端调用用量记录（JSON 数组，**纯本地**，条数有上限）。
  ///
  /// 注意这是"本机估算"的原料，**不是服务商账单**；界面上会原样标注。
  Future<String?> aiCloudUsage() => _get('ai_cloud_usage');

  Future<void> setAiCloudUsage(String v) => _set('ai_cloud_usage', v);

  // ------------------------------------------------- 相册 AI 美化（图生图）
  //
  // 存什么、不存什么（安全边界，与云端大模型同一套）：
  //   * **API Key 不在这里** —— 走 `cloud_key_store.dart` 的系统安全存储，
  //     槽位是 [kImageEditKeySlot]（`image_edit`），普通偏好表里一个字节都不留。
  //   * 这里存：总开关、一次性同意、后端类型、base URL、模型 id、单日上限、仅 WiFi。
  //
  // 默认值比 AI 其它开关**更保守**：`image_edit_enabled` 默认 **false**。
  // 理由：这是本仓库第一条"照片离开设备"的通道（相册照片含人脸/证件/位置），
  // 所以"关闭"必须是默认态（方案 §6.3）。

  /// 图生图 key 在安全存储里的槽位（**不是**偏好表 key）
  static const String kImageEditKeySlot = 'image_edit';

  /// 图生图总开关（**默认 false**）
  Future<bool> imageEditEnabled() async =>
      (await _get('image_edit_enabled') ?? 'false') == 'true';

  Future<void> setImageEditEnabled(bool v) =>
      _set('image_edit_enabled', v ? 'true' : 'false');

  /// 一次性同意（`image_edit_consent_v1`；写进去的值只作留痕，不参与逻辑）。
  /// 撤销走 [clearImageEditConsent]（DELETE 行，不是存空串）。
  Future<String?> imageEditConsentV1() => _get('image_edit_consent_v1');

  Future<void> setImageEditConsentV1(String v) =>
      _set('image_edit_consent_v1', v);

  Future<void> clearImageEditConsent() => _remove('image_edit_consent_v1');

  /// 单日额度（张/日；0 = 关闭功能；默认 [kImageEditDefaultDailyCap] = 3）
  Future<int> imageEditDailyCap() async =>
      int.tryParse(await _get('image_edit_daily_cap') ?? '') ??
      kImageEditDefaultDailyCap;

  Future<void> setImageEditDailyCap(int v) =>
      _set('image_edit_daily_cap', v < 0 ? '0' : '$v');

  /// 后端类型 id（`ImageEditBackend.id`；空 = 未配置）
  Future<String> imageEditBackend() =>
      _get('image_edit_backend').then((v) => v ?? '');

  Future<void> setImageEditBackend(String v) => _set('image_edit_backend', v);

  /// 图生图后端 base URL（用户自配；客户端只拼端点后缀）
  Future<String?> imageEditBaseUrl() => _get('image_edit_base_url');

  Future<void> setImageEditBaseUrl(String v) => _set('image_edit_base_url', v);

  /// 图生图模型 id（A1111 不需要）
  Future<String?> imageEditModel() => _get('image_edit_model');

  Future<void> setImageEditModel(String v) => _set('image_edit_model', v);

  /// 图生图仅 WiFi（**默认 true**；查不出网络类型按"不是 WiFi"保守处理）
  Future<bool> imageEditWifiOnly() async =>
      (await _get('image_edit_wifi_only') ?? 'true') == 'true';

  Future<void> setImageEditWifiOnly(bool v) =>
      _set('image_edit_wifi_only', v ? 'true' : 'false');

  // -------------------------------------------------- 回车发送 / 消息预加载

  /// 回车发送（原版 `sendByEnter`，**默认 false** = 回车换行、点按钮才发）。
  ///
  /// 注意 key 是 `sendByEnter`（`Common.ARG_SEND_BY_ENTER`）；设置界面里的
  /// androidx key 叫 `send_by_enter` —— 存的以**消费端**为准。
  Future<bool> sendByEnter() async =>
      (await _get(kSendByEnterKey) ?? 'false') == 'true';

  Future<void> setSendByEnter(bool on) => _set(kSendByEnterKey, '$on');

  /// 收到推送时预加载消息（原版 `post_preview_mode`；界面 key 是
  /// `preview_new_message`，**默认 `ONLY_WIFI`**）。
  Future<PostPreviewMode> postPreviewMode() async =>
      PostPreviewMode.fromName(await _get(kPostPreviewModeKey) ?? '');

  Future<void> setPostPreviewMode(PostPreviewMode mode) =>
      _set(kPostPreviewModeKey, mode.rawValue);

  // ------------------------------------------------------ 界面语言（本地）

  /// 界面语言（默认跟随系统）
  Future<LocaleChoice> localeChoice() async =>
      LocaleChoice.fromName(await _get(kLocaleKey) ?? '');

  Future<void> setLocaleChoice(LocaleChoice choice) async {
    await _set(kLocaleKey, choice.rawValue);
    // ★ 第 41 轮：镜像给原生侧，供**由 Kotlin 生成**的通知/前台服务文案选语言
    // （设置存在 Drift 键值表里，原生读不到 —— 见 native_locale_mirror.dart）。
    unawaited(mirrorAppLocaleToNative(choice.rawValue));
  }

  // ------------------------------------------------------ AI 悬浮球（本地）

  /// AI 悬浮球的位置（`'left|0.42|0'` = 贴哪边 | 垂直位置 0..1 | 是否收起）。
  ///
  /// 这一层只当"不透明字符串"存取，解析成模型的事交给
  /// `features/ai/ai_floating_orb.dart`（核心层不认识 UI 概念）。
  Future<String?> aiOrbRaw() async => _get(kAiOrbKey);

  Future<void> setAiOrbRaw(String value) => _set(kAiOrbKey, value);

  // ------------------------------------------------- 日历环境信息（本地）

  /// 日历"环境信息"（天气 + 节假日）的地区与单位设置。
  ///
  /// 同样只当不透明字符串存取，解析交给
  /// `features/calendar/calendar_env.dart`；**和风的 key 不在这里**
  /// （它走系统安全存储，见 `core/settings/cloud_key_store.dart`）。
  Future<String?> calendarEnvRaw() async => _get(kCalendarEnvKey);

  Future<void> setCalendarEnvRaw(String value) => _set(kCalendarEnvKey, value);

  /// 节假日缓存（按 `国家|年份` 存，避免每次开日历都打网络）
  Future<String?> calendarHolidayCacheRaw() async =>
      _get(kCalendarHolidayCacheKey);

  Future<void> setCalendarHolidayCacheRaw(String value) =>
      _set(kCalendarHolidayCacheKey, value);

  // ------------------------------------------------------ UI 风格（本地）

  /// Material You 动态取色（默认开）。拿不到动态色时自动回退品牌种子色。
  Future<bool> dynamicColor() async =>
      (await _get(kDynamicColorKey) ?? 'true') == 'true';

  Future<void> setDynamicColor(bool on) => _set(kDynamicColorKey, '$on');

  /// 读一个"可空覆盖"：**没存过 = null**（跟随设备性能自动判定）。
  Future<bool?> _override(String key) async {
    final raw = await _get(key);
    if (raw == null) return null;
    return raw == 'true';
  }

  Future<void> _setOverride(String key, bool? value) async {
    if (value == null) {
      try {
        await _store.deleteSetting(key);
      } catch (_) {
        // 清不掉也不该影响使用
      }
      return;
    }
    await _set(key, '$value');
  }

  /// 性能模式（关毛玻璃）的手动覆盖：null = 按设备档位自动。
  Future<bool?> perfModeOverride() => _override(kPerfModeKey);

  Future<void> setPerfModeOverride(bool? on) => _setOverride(kPerfModeKey, on);

  /// 减少动效的手动覆盖：null = 按设备档位自动。
  Future<bool?> reducedMotionOverride() => _override(kReducedMotionKey);

  Future<void> setReducedMotionOverride(bool? on) =>
      _setOverride(kReducedMotionKey, on);

  /// 聊天页网格底纹的手动覆盖：null = 按设备档位自动。
  Future<bool?> chatGridOverride() => _override(kChatGridKey);

  Future<void> setChatGridOverride(bool? on) => _setOverride(kChatGridKey, on);

  // ------------------------------------------------------ 侧栏排序方式

  /// 四个分组各自的排序方式（原版 `favorite_sort_by` / `channel_sort_by` /
  /// `conversation_sort_by` / `chat_bot_sort_by`，默认都是 `TIME`）
  Future<ChannelSortPrefs> channelSortPrefs() async {
    Future<ChannelSortMethod> read(ChannelSortTarget t) async =>
        ChannelSortMethod.fromName(await _get(t.key) ?? '');
    return ChannelSortPrefs(
      favorite: await read(ChannelSortTarget.favorite),
      channel: await read(ChannelSortTarget.channel),
      conversation: await read(ChannelSortTarget.conversation),
      chatbot: await read(ChannelSortTarget.chatbot),
    );
  }

  Future<void> setChannelSortMethod(
    ChannelSortTarget target,
    ChannelSortMethod method,
  ) => _set(target.key, method.rawValue);

  // ---------------------------------------------------- 侧栏分组折叠状态

  /// 四个分组头的折叠状态（原版 `hideFavorite` / `hideChannel` /
  /// `hideConversation` / `hideChatBot`，**默认 false = 展开**）
  Future<SidebarCollapsed> sidebarCollapsed() async {
    Future<bool> read(String key) async =>
        (await _get(key) ?? 'false') == 'true';
    return SidebarCollapsed(
      favorite: await read('hideFavorite'),
      channel: await read('hideChannel'),
      conversation: await read('hideConversation'),
      chatbot: await read('hideChatBot'),
    );
  }

  Future<void> setSidebarCollapsed(SidebarSection s, bool collapsed) =>
      _set(switch (s) {
        SidebarSection.favorite => 'hideFavorite',
        SidebarSection.channel => 'hideChannel',
        SidebarSection.conversation => 'hideConversation',
        SidebarSection.chatbot => 'hideChatBot',
        _ => 'hideChannel',
      }, '$collapsed');

  // ------------------------------------------------------------ 服务端设置

  /// 服务端下发的能力/限制（`SYNO.Chat.Admin.Setting` + `setting.update` 广播），
  /// 整块 JSON 存一条 —— 字段随版本增减，拆成多个 key 反而更难维护。
  /// 我的权限表（`SYNO.Chat.Misc acl` 的 JSON），原版存在自己那行 User 上。
  Future<String?> myAclJson() => _get('my_acl_json');

  Future<void> setMyAclJson(String raw) => _set('my_acl_json', raw);

  // ------------------------------------------------- 每个频道的消息草稿
  //
  // 对位原版 `ChatChannelPosting` 表（`channel_id PRIMARY KEY, posting_text`）
  // 与 `ChannelPresenter.savePostingText/fetchPostingText`
  // （`ChannelPresenter.java:1270,1295`）：
  //   * 进频道 `fetchPostingText` → 回填（`ChannelFragment.java:436`）
  //   * 离开频道 `savePostingText` → 落盘（`ChannelFragment.java:582`）
  //   * 文本清空 = **删行**（`DatabaseHelper.java:3040-3055`）
  // 这里一个频道一条 KV 行（key 里带 channel_id，与官方"按 channel_id 查/删"
  // 语义等价，且不会因为一条坏 JSON 丢掉所有频道的草稿）。

  /// 频道草稿的 KV key（原版 `ChatChannelPosting.channel_id` → 这里放进 key）
  static String channelPostingKey(int channelId) =>
      'chat_posting_text_$channelId';

  /// 读某个频道的草稿；没有就是空串
  Future<String> channelPostingText(int channelId) async =>
      await _get(channelPostingKey(channelId)) ?? '';

  /// 存某个频道的草稿；[text] 为空 = 删掉该频道的草稿行
  Future<void> setChannelPostingText(int channelId, String text) async {
    final key = channelPostingKey(channelId);
    if (text.isEmpty) {
      await _remove(key);
      return;
    }
    await _set(key, text);
  }

  // ------------------------------------------------------------ 免打扰（snooze）

  /// 用户偏好（`User.Preference`）的本地镜像 —— key 名沿用原版
  /// `PreferencesHelper`（`snooze` / `snooze_schedule_*`），但存成一整块 JSON，
  /// 免得加字段就要动表。
  Future<String?> userPreferenceJson() => _get('snooze_preferences_json');

  Future<void> setUserPreferenceJson(String raw) =>
      _set('snooze_preferences_json', raw);

  /// 我自己的 IANA 时区（`user_props.timezoneUTC`），定时免打扰页上显示用
  Future<String> myTimezoneUtc() async => await _get('my_timezone_utc') ?? '';

  Future<void> setMyTimezoneUtc(String tz) => _set('my_timezone_utc', tz);

  // ---------------------------------------------------- 均衡器（B10）
  //
  // 官方把 EQ 的开关与自定义曲线存在本机偏好里
  // （`AudioPreference.PREFERENCE_ENABLE_EQUALIZER` +
  //  `EqualizerSettings` 的 `EQUALIZER_CUSTOM_INFO` 文件），
  // 我们同样只落本地：`{"enabled":bool,"preset":"名称"}`。

  Future<String?> equalizerJson() => _get('audio_equalizer_json');

  Future<void> setEqualizerJson(String raw) =>
      _set('audio_equalizer_json', raw);

  // ---------------------------------------------------------- 服务端设置

  Future<String?> serverSettingsJson() => _get('server_settings_json');

  Future<void> setServerSettingsJson(String raw) =>
      _set('server_settings_json', raw);

  // ------------------------------------------- 音频/视频串流的一次性确认
  //
  // 原版 `PreferencesHelper` 的 key 就是这两个（`Common.ARG_VIDEO_*`）。
  // 语义：勾了"不再提示"之后，遇到加密频道/不受信任的证书就直接走下载。

  /// 加密频道的视频不再问「要不要改为下载」
  Future<bool> streamingEncryptedMessage() async =>
      (await _get('video_encrypted')) == 'true';

  Future<void> setStreamingEncryptedMessage(bool on) =>
      _set('video_encrypted', on ? 'true' : 'false');

  /// 证书不受信任的视频不再问「要不要改为下载」
  Future<bool> streamingIllegalCertificate() async =>
      (await _get('video_illegal_certificate')) == 'true';

  Future<void> setStreamingIllegalCertificate(bool on) =>
      _set('video_illegal_certificate', on ? 'true' : 'false');

  // ------------------------------------------------------------ 手机自动备份

  /// 相册「手机自动备份」的本地账本与开关（**整块 JSON 存一条**）。
  ///
  /// 内容见 `features/photos/photo_backup_queue.dart` 的 [PhotoBackupSnapshot]：
  /// 已备份的本地文件身份（stableKey）、目标相册、上次完成时间、是否含视频、
  /// 仅 Wi-Fi、自动开关。不新增 drift 表，老库直接能用。
  Future<String?> photoBackupRaw() => _get('photo_backup_state');

  Future<void> setPhotoBackupRaw(String raw) => _set('photo_backup_state', raw);

  // ------------------------------------------------------------ 应用锁

  Future<bool> passcodeEnabled() async =>
      (await _get('passcode_enable')) == 'true';

  Future<void> setPasscodeEnabled(bool on) =>
      _set('passcode_enable', on ? 'true' : 'false');

  Future<bool> fingerprintEnabled() async =>
      (await _get('passcode_fingerprint_enable')) == 'true';

  Future<void> setFingerprintEnabled(bool on) =>
      _set('passcode_fingerprint_enable', on ? 'true' : 'false');

  Future<PasscodeExpiration> passcodeExpiration() async =>
      PasscodeExpiration.fromRaw(await _get('passcode_expiration') ?? 'ALWAYS');

  Future<void> setPasscodeExpiration(PasscodeExpiration e) =>
      _set('passcode_expiration', e.rawValue);

  /// 口令本身存散列（原版用 KeyStore 加密后存 SharedPreferences；
  /// 我们用 PBKDF2/散列 + 盐，见 PasscodeService）。
  Future<String?> passcodeHash() => _get('passcode_hash');

  Future<String?> passcodeSalt() => _get('passcode_salt');

  Future<void> setPasscodeHash(String hash, String salt) async {
    await _set('passcode_hash', hash);
    await _set('passcode_salt', salt);
  }

  Future<void> clearPasscode() async {
    await _set('passcode_hash', '');
    await _set('passcode_salt', '');
    await _set('passcode_enable', 'false');
    await _set('passcode_fingerprint_enable', 'false');
  }

  // ------------------------------------------------- 提醒：已弹过的记账

  /// 已经弹过本地通知的提醒（post_id 集合）。
  ///
  /// 为什么要在本地记账：服务端把「提醒」当**推送**下发（FCM），我们是用本地
  /// 通知顶上的（见 `ReminderScheduler`），而提醒一旦到期，服务端就把
  /// `props.remind_at` 抹了（`Reminder/list` 变空）。抹之前我们可能已经弹过、
  /// 也可能还没弹（进程被杀），所以"弹没弹过"只能自己存。
  ///
  /// 不限制条数的话这个 key 会一直长，所以只留最近 [kMaxFiredReminders] 条。
  static const int kMaxFiredReminders = 500;
  static const String firedRemindersKey = 'notified_reminders';

  Future<Set<int>> firedReminders() async {
    final raw = await _get(firedRemindersKey);
    if (raw == null || raw.isEmpty) return <int>{};
    try {
      final list = jsonDecode(raw);
      if (list is! List) return <int>{};
      return list.whereType<num>().map((e) => e.toInt()).toSet();
    } catch (_) {
      return <int>{}; // 脏数据当没有，别让它把提醒功能整个卡死
    }
  }

  Future<void> setFiredReminders(Set<int> ids) async {
    final list = ids.where((e) => e > 0).toList();
    final capped = list.length > kMaxFiredReminders
        ? list.sublist(list.length - kMaxFiredReminders)
        : list;
    await _set(firedRemindersKey, jsonEncode(capped));
  }

  /// 我设过、还没到点的提醒（`{post_id: {c: 频道, t: 提醒时间}}` 的 JSON）。
  ///
  /// 为什么要单独存一份、而不是直接扫本地 `props.remind_at`：
  /// 提醒是**每个用户私有**的（`Reminder/list` 只返回自己的；`Post/list` 里别人的
  /// 消息连 `remind_at` 都不带）。直接扫 props 的话，一旦服务端把
  /// `post.reminder.set` 广播给了频道里所有人，我们就会替别人弹提醒。
  /// 存"我自己的"最保险：来源只有三个 —— 我自己 set 成功、
  /// `post.reminder.set` 广播、`Reminder/list` 回读（权威）。
  static const String armedRemindersKey = 'my_reminders';

  Future<String?> armedRemindersRaw() => _get(armedRemindersKey);

  Future<void> setArmedRemindersRaw(String json) =>
      _set(armedRemindersKey, json);
}

// ---------------------------------------------------------------- providers

/// 设置服务（依赖已打开的本地库）
final settingsServiceProvider = Provider<SettingsService>(
  (ref) => SettingsService(ref.watch(chatStoreProvider)),
);

/// 主题偏好。`main.dart` 在启动时先 `preload()` 把它变成同步可读。
/// Linux 上"系统是否深色"的**外部读数**（`null` = 不知道，交回 Flutter）。
///
/// `main()` 启动时把 [linuxSystemPrefersDark] 的结果写进来；其它平台保持 `null`。
/// ★ `DA342`：Flutter 的 Linux 嵌入层不送 `platformBrightness`，只能自己读。
final systemPrefersDarkProvider = Provider<bool?>((ref) => null);

/// 把主题偏好 + 系统深色读数合成 `ThemeMode`（纯函数，好测）。
///
/// * 用户明确选了浅色/深色 ⇒ 听用户的；
/// * 选了「跟随系统」：有外部读数就按读数（Linux），没有就交回
///   `ThemeMode.system`（Android/iOS/macOS/Windows/Web 的 `platformBrightness`
///   本来就是对的，不许我们多管）。
ThemeMode resolveThemeMode(AppThemeChoice choice, {bool? systemPrefersDark}) {
  if (choice != AppThemeChoice.system) return choice.mode;
  if (systemPrefersDark == null) return ThemeMode.system;
  return systemPrefersDark ? ThemeMode.dark : ThemeMode.light;
}

final themeChoiceProvider =
    NotifierProvider<ThemeChoiceNotifier, AppThemeChoice>(
      ThemeChoiceNotifier.new,
    );

class ThemeChoiceNotifier extends Notifier<AppThemeChoice> {
  @override
  AppThemeChoice build() => AppThemeChoice.system;

  /// 启动时把持久化的值读进来
  Future<void> preload() async {
    final choice = await ref.read(settingsServiceProvider).themeChoice();
    if (ref.mounted) state = choice;
  }

  Future<void> set(AppThemeChoice choice) async {
    state = choice;
    await ref.read(settingsServiceProvider).setThemeChoice(choice);
  }
}

/// 界面语言偏好。`app.dart` 启动时先 `preload()`，切语言立刻生效。
final localeChoiceProvider =
    NotifierProvider<LocaleChoiceNotifier, LocaleChoice>(
      LocaleChoiceNotifier.new,
    );

class LocaleChoiceNotifier extends Notifier<LocaleChoice> {
  @override
  LocaleChoice build() => LocaleChoice.system;

  Future<void> preload() async {
    final choice = await ref.read(settingsServiceProvider).localeChoice();
    // ★ 第 41 轮：每次启动同步一次镜像（覆盖"装了旧版本、还没镜像过"的情况）
    unawaited(mirrorAppLocaleToNative(choice.rawValue));
    if (ref.mounted) state = choice;
  }

  Future<void> set(LocaleChoice choice) async {
    state = choice;
    await ref.read(settingsServiceProvider).setLocaleChoice(choice);
  }
}

/// 图片质量偏好
final imageQualityProvider =
    NotifierProvider<ImageQualityNotifier, ImageQuality>(
      ImageQualityNotifier.new,
    );

class ImageQualityNotifier extends Notifier<ImageQuality> {
  @override
  ImageQuality build() => ImageQuality.standard;

  Future<void> preload() async {
    final q = await ref.read(settingsServiceProvider).imageQuality();
    if (ref.mounted) state = q;
  }

  Future<void> set(ImageQuality q) async {
    state = q;
    await ref.read(settingsServiceProvider).setImageQuality(q);
  }
}

/// 附件下载缓存（受 `set_cache_limit` 管理）
final cacheServiceProvider = Provider<CacheService>((ref) => CacheService());

/// "把音频/视频串流交给外部应用"这一步（测试里可覆盖成假的）
final mediaStreamOpenerProvider = Provider<MediaStreamOpener>(
  (ref) => defaultMediaStreamOpener,
);

/// 缓存上限（字节；0 = 不限）
final cacheLimitProvider = NotifierProvider<CacheLimitNotifier, int>(
  CacheLimitNotifier.new,
);

class CacheLimitNotifier extends Notifier<int> {
  @override
  int build() => kDefaultCacheLimitBytes;

  Future<void> preload() async {
    final b = await ref.read(settingsServiceProvider).cacheLimitBytes();
    if (ref.mounted) state = b;
  }

  Future<void> set(int bytes) async {
    state = bytes;
    await ref.read(settingsServiceProvider).setCacheLimitBytes(bytes);
  }
}

/// 回车发送（默认关；开着时输入框是**单行** + 回车即发）
final sendByEnterProvider = NotifierProvider<SendByEnterNotifier, bool>(
  SendByEnterNotifier.new,
);

class SendByEnterNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  Future<void> preload() async {
    final on = await ref.read(settingsServiceProvider).sendByEnter();
    if (ref.mounted) state = on;
  }

  Future<void> set(bool on) async {
    state = on;
    await ref.read(settingsServiceProvider).setSendByEnter(on);
  }
}

/// Material You 动态取色开关（默认开）
final dynamicColorProvider = NotifierProvider<DynamicColorNotifier, bool>(
  DynamicColorNotifier.new,
);

class DynamicColorNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  Future<void> preload() async {
    final on = await ref.read(settingsServiceProvider).dynamicColor();
    if (ref.mounted) state = on;
  }

  Future<void> set(bool on) async {
    state = on;
    await ref.read(settingsServiceProvider).setDynamicColor(on);
  }
}

/// 三种"炫酷效果"的手动覆盖值（`null` = 跟随设备性能自动）
enum EffectKind {
  /// 性能模式：开 = 关掉毛玻璃（`AppEffects.reducedBlur`）
  perfMode,

  /// 减少动效：开 = 所有过渡立即完成
  reducedMotion,

  /// 聊天页 HUD 网格底纹
  chatGrid,
}

/// 覆盖值 provider（family 版，省三份样板）
final effectOverrideProvider =
    NotifierProvider.family<EffectOverrideNotifier, bool?, EffectKind>(
      EffectOverrideNotifier.new,
    );

class EffectOverrideNotifier extends Notifier<bool?> {
  EffectOverrideNotifier(this.kind);

  final EffectKind kind;

  @override
  bool? build() => null;

  Future<void> preload() async {
    final svc = ref.read(settingsServiceProvider);
    final value = await switch (kind) {
      EffectKind.perfMode => svc.perfModeOverride(),
      EffectKind.reducedMotion => svc.reducedMotionOverride(),
      EffectKind.chatGrid => svc.chatGridOverride(),
    };
    if (ref.mounted) state = value;
  }

  /// `null` = 恢复自动（把存的那条删掉）
  Future<void> set(bool? value) async {
    state = value;
    final svc = ref.read(settingsServiceProvider);
    await switch (kind) {
      EffectKind.perfMode => svc.setPerfModeOverride(value),
      EffectKind.reducedMotion => svc.setReducedMotionOverride(value),
      EffectKind.chatGrid => svc.setChatGridOverride(value),
    };
  }
}

/// 性能模式**生效值**：手动覆盖优先，否则跟设备档位（只有高端默认开毛玻璃）
final perfModeProvider = Provider<bool>((ref) {
  final override = ref.watch(effectOverrideProvider(EffectKind.perfMode));
  return override ?? !ref.watch(deviceProfileProvider).preferBlur;
});

/// 减少动效**生效值**：手动覆盖优先，否则跟设备档位（入门机默认开）
final reducedMotionProvider = Provider<bool>((ref) {
  final override = ref.watch(effectOverrideProvider(EffectKind.reducedMotion));
  return override ?? ref.watch(deviceProfileProvider).preferReducedMotion;
});

/// 网格底纹**生效值**：手动覆盖优先，否则跟设备档位（入门机默认关）
final chatGridProvider = Provider<bool>((ref) {
  final override = ref.watch(effectOverrideProvider(EffectKind.chatGrid));
  return override ?? ref.watch(deviceProfileProvider).preferChatGrid;
});

/// 收到通知时预加载消息的档位（默认 `ONLY_WIFI`）
final postPreviewModeProvider =
    NotifierProvider<PostPreviewModeNotifier, PostPreviewMode>(
      PostPreviewModeNotifier.new,
    );

class PostPreviewModeNotifier extends Notifier<PostPreviewMode> {
  @override
  PostPreviewMode build() => PostPreviewMode.onlyWifi;

  Future<void> preload() async {
    final m = await ref.read(settingsServiceProvider).postPreviewMode();
    if (ref.mounted) state = m;
  }

  Future<void> set(PostPreviewMode mode) async {
    state = mode;
    await ref.read(settingsServiceProvider).setPostPreviewMode(mode);
  }
}

/// 侧栏排序方式（原版 `SortMethodPreferences`，默认四个都 TIME）
final channelSortPrefsProvider =
    NotifierProvider<ChannelSortPrefsNotifier, ChannelSortPrefs>(
      ChannelSortPrefsNotifier.new,
    );

class ChannelSortPrefsNotifier extends Notifier<ChannelSortPrefs> {
  @override
  ChannelSortPrefs build() => const ChannelSortPrefs();

  Future<void> preload() async {
    final p = await ref.read(settingsServiceProvider).channelSortPrefs();
    if (ref.mounted) state = p;
  }

  Future<void> set(ChannelSortTarget target, ChannelSortMethod method) async {
    state = switch (target) {
      ChannelSortTarget.favorite => state.copyWith(favorite: method),
      ChannelSortTarget.channel => state.copyWith(channel: method),
      ChannelSortTarget.conversation => state.copyWith(conversation: method),
      ChannelSortTarget.chatbot => state.copyWith(chatbot: method),
    };
    await ref
        .read(settingsServiceProvider)
        .setChannelSortMethod(target, method);
  }
}

/// 侧栏分组折叠状态（原版那四个 `hide*` 偏好）
final sidebarCollapsedProvider =
    NotifierProvider<SidebarCollapsedNotifier, SidebarCollapsed>(
      SidebarCollapsedNotifier.new,
    );

class SidebarCollapsedNotifier extends Notifier<SidebarCollapsed> {
  @override
  SidebarCollapsed build() => const SidebarCollapsed();

  Future<void> preload() async {
    final c = await ref.read(settingsServiceProvider).sidebarCollapsed();
    if (ref.mounted) state = c;
  }

  Future<void> toggle(SidebarSection s) async {
    final next = state.toggled(s);
    state = next;
    await ref
        .read(settingsServiceProvider)
        .setSidebarCollapsed(s, next.isCollapsed(s));
  }
}
