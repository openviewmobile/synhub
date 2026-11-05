// Phase 9：设置主页。
//
// 这一版先把「本地偏好层」做实（`core/settings/app_settings.dart`），页面只做
// 已经真正生效的项，避免摆一堆点了没反应的开关：
//   * 主题三档（跟随系统 / 浅色 / 深色）→ 立刻改 `MaterialApp.themeMode` 并落盘；
//   * 图片质量（标准 / 原图）→ 上传路径读取；
//   * 缓存上限（6 档，含"不限制"）→ 落盘（清理逻辑见 `CacheService`）；
//   * 通知与后台 → 转到 Phase 8 的通知设置页；
//   * 加密（E2EE）→ 转到 Phase 7 的设置页；
//   * 关于：版本、服务器、我的账号、诊断入口。
//
// 原版把设置分散在 4 套存储里；我们统一进 Drift 键值表，key 名尽量沿用原版
//（`dark_mode` / `upload_quality` / `set_cache_limit`），详见
// `docs/recheck/g-settings-misc.md`。
import 'package:flutter/material.dart';

import '../../design/kit/design_kit.dart';
import '../../core/theme/wallpaper_seed.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/dev/dev_tools.dart';
import '../../core/i18n/l10n.dart';
import '../../core/provider_retry.dart';
import '../../core/router/app_routes.dart';
import '../../core/media/cache_service.dart';
import '../../core/security/biometric_auth.dart';
import '../../core/security/passcode_service.dart';
import '../../core/device/device_profile.dart';
import '../../core/platform/app_platform.dart';
import '../../core/settings/app_settings.dart';
import '../ai/ai_model_page.dart';
import '../notifications/notification_service.dart';
import '../photos/image_edit_providers.dart';
import '../photos/photo_ai_edit_settings_page.dart';
import '../photos/photo_ai_edit_text.dart';
import '../analytics/analytics_page.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../chat/channel_sort.dart';
import '../chat/chat_session_controller.dart';
import '../servers/server_source_label.dart';
import '../servers/nas_manager_page.dart';
import '../servers/session_controller.dart';
import '../admin/admin_gate.dart';
import '../admin/admin_gaps_text.dart';
import '../admin/admin_tools_page.dart';
import 'oem_keepalive_page.dart';
import 'personal_profile_page.dart';
import 'settings_gaps_text.dart';
import 'snooze_controller.dart';

/// App 版本（**必须**与 `pubspec.yaml` 的 `version:` 逐字一致）。
///
/// ★ D74（r349，真机发现）：这里原本写死 `'0.1.0+1'`，而 `pubspec.yaml` 是
/// `1.0.0+1`、装到手机上的 APK `versionName` 也是 `1.0.0`
/// ⇒ **「关于」页显示的版本号与真实产物不符**。
/// 注释里那句"保持一致"是**愿望**，不是**机制** —— 所以补了守卫
/// `test/app_version_match_test.dart`（读 `pubspec.yaml` 逐字断言），
/// 它**装回旧值就会红**，这才叫"机制"。
const String kAppVersion = '0.1.0+1';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 使用日志：设置页曝光（稳定页面 id，不记标题）
    trackView(UsageModule.settings, screen: 'settings');
    final t = context.t;
    final themeChoice = ref.watch(themeChoiceProvider);
    final quality = ref.watch(imageQualityProvider);
    final cacheLimit = ref.watch(cacheLimitProvider);
    final sync = ref.watch(chatSessionControllerProvider);
    // ★ r343 D51：「我的账号」行要显示**用户名**（NAS 账号），不用内部主键。
    final username = ref.watch(sessionControllerProvider).session?.account;

    return DesignScaffold(
      appBar: AppBar(title: Text(t.setTitle)),
      body: ListView(
        children: [
          _section(context, t.setSectionAppearance),
          // 语言：跟随系统 / 简体中文 / English（本地偏好，见 LocaleChoice）
          DesignRowTile(
            leading: const Icon(Icons.translate_outlined),
            title: Text(t.setLanguage),
            subtitle: Text(_languageLabel(t, ref.watch(localeChoiceProvider))),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickLanguage(context, ref),
          ),
          DesignRowTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: Text(t.setTheme),
            subtitle: Text(_themeLabel(t, themeChoice)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickTheme(context, ref, themeChoice),
          ),

          // 设备性能遥测：下面三个开关"没存过"时就是按这个档位来的
          _DeviceTierTile(profile: ref.watch(deviceProfileProvider)),

          // 外观的本地开关（原版没有，属自愿增强；都能随时关掉）
          DesignSwitchRow(
            key: const Key('set-dynamic-color'),
            secondary: const Icon(Icons.auto_awesome_outlined),
            title: Text(t.setDynamicColor),
            // ★ 第 231 轮（用户裁定"要真正取到壁纸色"）：副标题**说实话**——
            //   取到了就写来源与色值，取不到就说"本机取不到、暂用品牌蓝"。
            //   以前这里永远写"跟随系统壁纸"，而 EMUI 上其实一直是品牌蓝。
            subtitle: Consumer(
              builder: (context, subRef, _) {
                final on = subRef.watch(dynamicColorProvider);
                if (!on) return Text(t.setDynamicColorHint);
                final seed = subRef.watch(wallpaperSeedProvider).asData?.value;
                if (seed == null) return Text(t.setDynamicColorHint);
                if (!seed.usable) {
                  return Text(
                    t.setDynamicColorUnavailable,
                    key: const Key('set-dynamic-source-unavailable'),
                  );
                }
                final hex = seed.color!.toARGB32().toRadixString(16).padLeft(8, '0');
                return Text(
                  t.setDynamicColorSource(_sourceLabel(seed.source), '#${hex.substring(2)}'),
                  key: const Key('set-dynamic-source'),
                );
              },
            ),
            value: ref.watch(dynamicColorProvider),
            onChanged: (on) => ref.read(dynamicColorProvider.notifier).set(on),
          ),
          // ★ r494：**删掉「Chat grid backdrop」这一行** —— 它是死功能。
          //
          // r492 把 `FieldBackdrop` 的科幻底纹（网格/星尘/扫描线）整体退役了，
          // 但这个开关还在设置页里：拨它不会有任何像素变化（`FieldBackdrop`
          // 已经不看 `showGrid` 了）。**控件还在、效果没了 = 死功能**，
          // 比"没有这个开关"更糟。`chatGridProvider` 留着（旧偏好能读，
          // 设计样张页与 `device_profile` 用例还在用它）。
          _EffectSwitch(
            kind: EffectKind.perfMode,
            icon: Icons.speed_outlined,
            title: t.setPerfMode,
            hint: t.setPerfModeHint,
            value: ref.watch(perfModeProvider),
            deviceDefault: !ref.watch(deviceProfileProvider).preferBlur,
            onChanged: (on) => ref
                .read(effectOverrideProvider(EffectKind.perfMode).notifier)
                .set(on),
          ),
          _EffectSwitch(
            kind: EffectKind.reducedMotion,
            icon: Icons.motion_photos_off_outlined,
            title: t.setReducedMotion,
            hint: t.setReducedMotionHint,
            value: ref.watch(reducedMotionProvider),
            deviceDefault: ref.watch(deviceProfileProvider).preferReducedMotion,
            onChanged: (on) => ref
                .read(effectOverrideProvider(EffectKind.reducedMotion).notifier)
                .set(on),
          ),

          _section(context, t.setSectionMedia),
          DesignRowTile(
            leading: const Icon(Icons.image_outlined),
            title: Text(t.setImageQuality),
            subtitle: Text(
              '${_qualityLabel(t, quality)} · '
              '${_qualityHint(t, quality)}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickQuality(context, ref, quality),
          ),
          // 「回车发送」（原版 `sendByEnter`，默认关；pref_setting.xml 里排在
          // `preview_new_message` 之后、缓存管理之前）
          DesignSwitchRow(
            secondary: const Icon(Icons.keyboard_return_outlined),
            title: Text(t.setSendByEnter),
            subtitle: Text(
              ref.watch(sendByEnterProvider)
                  ? t.setSendByEnterOn
                  : t.setSendByEnterOff,
            ),
            value: ref.watch(sendByEnterProvider),
            onChanged: (on) => ref.read(sendByEnterProvider.notifier).set(on),
          ),
          DesignRowTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: Text(t.setCacheLimit),
            subtitle: Text(_limitLabel(t, cacheLimit)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickCacheLimit(context, ref, cacheLimit),
          ),
          DesignRowTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: Text(t.setClearCache),
            subtitle: Text(_usageLabel(context, ref)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _manageCache(context, ref),
          ),
          // 「收到消息通知时预加载消息」（原版 `preview_new_message` /
          // `PostPreviewWorker`：弹通知后顺手把该频道前后各 40 条拉下来）
          DesignRowTile(
            leading: const Icon(Icons.download_for_offline_outlined),
            title: Text(t.setPostPreview),
            subtitle: Text(
              ref.watch(postPreviewModeProvider).labelIn(context.t),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickPostPreviewMode(context, ref),
          ),
          // 「频道和对话排序方式」（原版 `preference_sort_method.xml`：四个分组
          // 各自选 名称 / 接收时间）
          DesignRowTile(
            leading: const Icon(Icons.sort_outlined),
            title: Text(t.setSort),
            subtitle: Text(
              _sortSummary(context.t, ref.watch(channelSortPrefsProvider)),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickSortTarget(context, ref),
          ),

          _section(context, t.setSectionSecurity),
          // ★ r450：**登录态下也能进「管理 NAS」**。
          //   在此之前 `NasManagerPage` 的唯一生产入口在**未登录/断连**的服务器页
          //   （`server_setup_page.dart` 的 `NasSwitcherBar`），而登录态通往那个页面
          //   只有"登出"一条路 ⇒ 已登录用户**够不到**自己的多 NAS 列表。
          //   管理页本身零网络调用（只读本地 `nas_registry`），所以这一行不产生 NAS 请求。
          DesignRowTile(
            key: const Key('settings-nas-manager'),
            leading: const Icon(Icons.lan_outlined),
            title: Text(t.nasManage),
            subtitle: Text(t.setNasManageHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => NasManagerPage.open(context),
          ),
          const _AppLockTile(),
          DesignRowTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: Text(t.setCertificates),
            subtitle: Text(t.setCertificatesHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.certificates),
          ),
          DesignRowTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(t.serviceCheckTitle),
            subtitle: Text(t.serviceCheckSubtitle),
            onTap: () => context.push(AppRoutes.serviceCheck),
          ),
          // ★ r342 D45：这一行的状态**实时问系统**（原来读会话内存快照 ⇒ 会说谎）。
          _ForegroundServiceTile(
            title: t.setNotifications,
            runningText: t.setForegroundRunning,
            stoppedText: t.setForegroundStopped,
            onTap: () => context.push(AppRoutes.notifications),
          ),
          // ★ 第 278 轮：**厂商保活指引**入口（紧跟"通知"）。
          // 本 App 不用 FCM ⇒ 国内 ROM 的「应用启动管理 / 智能省电」是通知能否
          // 到达的唯一决定因素，把用户带到正确的系统设置页是功能的一部分。
          // ★ r693 DA332：这一页整页都是**安卓系统设置**（电池优化白名单 / 厂商路径），
          //   桌面宿主上没有对应系统页 ⇒ 开关点了不动＝**死控件**（比没控件更坏）。
          //   按能力位 fail-closed：桌面**不摆入口**，安卓/iOS 照旧。
          if (capabilityGateAllows(AppCapability.backgroundExecution))
            DesignRowTile(
              key: const Key('settings-oem-keepalive'),
              leading: const Icon(Icons.battery_saver_outlined),
              title: Text(t.oemKeepaliveTitle),
              // ★ r342 D44：行摘要**不许复用页内那句**「下面的放行项建议全部打开——…」
              //   （那是**页内**说明，脱离上下文在列表里读不通）。行摘要要能独立读。
              subtitle: Text(t.oemKeepaliveRowSummary),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(
                  builder: (_) => const OemKeepalivePage(),
                ),
              ),
            ),
          Consumer(
            builder: (context, ref, _) {
              final snooze = ref.watch(snoozeControllerProvider);
              final now = DateTime.now();
              return DesignRowTile(
                leading: Icon(
                  snooze.suppressesNow
                      ? Icons.notifications_off
                      : Icons.notifications_none,
                ),
                title: Text(t.setSnooze),
                subtitle: Text(snooze.subtitleIn(t, now)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.snooze),
              );
            },
          ),
          DesignRowTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(t.setE2ee),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.e2ee),
          ),

          _section(context, t.setSectionPrivacy),
          DesignRowTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text(t.setOnDeviceAi),
            subtitle: Text(t.setOnDeviceAiHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(builder: (_) => const AiModelPage()),
            ),
          ),
          // ★ 第 255 轮：图生图（照片 AI 美化）**独立入口**。
          // 用户要求把它与大语言模型设置拆开 ⇒ 不再挂在「AI 服务」页里，
          // 副标题直接把"开没开 / 发给谁 / 每天几张"说清楚。
          Consumer(
            builder: (context, ref, _) {
              final s = ref.watch(photoAiEditSettingsProvider).value;
              return DesignRowTile(
                key: const Key('set-photo-ai-edit'),
                leading: const Icon(Icons.auto_fix_high_outlined),
                title: Text(
                  photoAiEdit(PhotoAiEditTextKeys.settingsEntry, 'AI 美化（图生图）'),
                ),
                subtitle: Text(_photoAiEditSubtitle(s)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PhotoAiEditSettingsPage(),
                  ),
                ),
              );
            },
          ),
          DesignRowTile(
            leading: const Icon(Icons.insights_outlined),
            title: Text(t.setUsageAnalytics),
            subtitle: Text(t.setUsageAnalyticsHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const UsageAnalyticsPage(),
              ),
            ),
          ),

          _section(context, t.setSectionAbout),
          DesignRowTile(
            leading: const Icon(Icons.info_outline),
            title: Text(t.setVersion),
            subtitle: const Text(kAppVersion),
          ),
          DesignRowTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(t.setServer),
            subtitle: Text(serverLabelOf(ref, context.t)),
          ),
          DesignRowTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(t.setMyAccount),
            // ★★ r343 D51：这里原来把内部主键印给用户 —— 真机像素逐字
            //   `user_id = 14`（连键名一起）。`user_id` 是**服务端主键**，不是用户词汇；
            //   同一屏上面的「账号信息」页问的才是服务端资料。
            //   ⇒ 改成"**用户名 + 角色**"（会话里就有 `DsmSession.account`）：
            //   用户名取不到时只显示角色，**永不显示内部主键**（D39/D43/D46 同族，§2.0.26）。
            //   ★ 主键没有丢：它仍在会话/日志里，诊断页负责技术读数。
            subtitle: Text(
              sync.myUserId > 0
                  ? [
                      if (username != null && username.isNotEmpty) username,
                      if (sync.isAdmin) t.setRoleAdmin else t.setRoleMember,
                    ].join(' · ')
                  : t.meNotLoggedIn,
            ),
          ),
          // 账号信息（`SYNO.Personal.Profile / get`，**只读**）：
          // 昵称 / 邮箱 / 账号类型。与上面那行（本地会话里的 user_id）分开，
          // 因为这一行问的是**服务端**的资料（真机实测：昵称与主邮箱可为空串、
          // `emails` 可为空数组 ⇒ 页内如实显示"未设置"）。
          //
          // ⚠️ 标题用「账号信息」而不是「个人资料」：后者的名字已经被
          // 「我的」tab 里的**编辑页**（`ProfileEditPage`，写路径）占了
          // —— 两个入口同名会让用户以为点进去能改。本页**只读**。
          // ★★★ 第 74 轮：**管理员入口**（新规 R2/R3 的第一个真实消费者）。
          //
          // 用 `AdminOnly` 包住 ⇒ 非管理员**看不到这一条目**
          //（不是禁用、不是报错），管理员正常看到。
          // 门控实现集中在 `features/admin/admin_gate.dart`，
          // **不允许**在这里写 `if (isAdmin)`。
          //
          // 之所以先挂这一个：Active Insight 是本仓**已经实现对**的
          // adminOnly 能力（`SYNO.ActiveInsight.Package/get_status`），
          // 而 §9.4 记着旧计划把它排除的理由（"与只做普通用户功能冲突"）
          // 已被新规作废 —— 这里就是撤回排除的落点。
          AdminOnly(
            child: DesignRowTile(
              key: const Key('set-admin-tools'),
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: Text(
                adminGap(AdminGapTextKeys.adminToolsTitle, '管理工具'),
              ),
              subtitle: Text(
                adminGap(
                  AdminGapTextKeys.adminToolsEntryHint,
                  '仅管理员可见',
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AdminToolsPage(),
                ),
              ),
            ),
          ),

          DesignRowTile(
            key: const Key('set-personal-profile'),
            leading: const Icon(Icons.contact_page_outlined),
            title: Text(
              settingsGap(SettingsGapTextKeys.profileEntry, '账号信息'),
            ),
            subtitle: Text(
              settingsGap(
                SettingsGapTextKeys.profileEntryHint,
                '昵称 / 邮箱 / 账号类型（只读）',
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const PersonalProfilePage(),
              ),
            ),
          ),
          if (kDevTools) ...<Widget>[
            DesignRowTile(
              leading: const Icon(Icons.monitor_heart_outlined),
              title: Text(t.setDiagnostics),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRoutes.diagnostics),
            ),
            // 设计稿画廊：154 屏 × 暗/亮 × 中/英，只在 dev 档出现（评审用）。
            DesignRowTile(
              leading: const Icon(Icons.photo_library_outlined),
              // dev-only：字符串刻意用英文，避免进 ARB（它不进正式界面）。
              title: const Text('Design gallery'),
              subtitle: const Text('154 screens · dark/light · zh/en'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRoutes.designGallery),
            ),
          ],
        ],
      ),
    );
  }

  /// 当前缓存用量（异步读一次目录；加载中显示"正在统计…"）
  static String _usageLabel(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final usage = ref.watch(cacheUsageProvider);
    return usage.when(
      loading: () => t.cacheCounting,
      error: (e, __) => t.cacheCountFailed,
      data: (u) =>
          u.files == 0 ? t.cacheNone : t.cacheUsed(u.humanSize, u.files),
    );
  }

  /// 主题三档的文案（枚举里存的是中文标签，界面按语言取）
  static /// 动态取色的"色从哪来"的人话说法（避免把 `wallpaperColors` 这种标识符直接上屏）。
String _sourceLabel(WallpaperColorSource source) => switch (source) {
  WallpaperColorSource.materialYou => 'Material You',
  WallpaperColorSource.wallpaperColors => 'WallpaperManager',
  WallpaperColorSource.bitmap => 'Wallpaper bitmap',
  WallpaperColorSource.systemAccent => 'System accent',
  WallpaperColorSource.none => '-',
};

String _themeLabel(AppText t, AppThemeChoice c) => switch (c) {
    AppThemeChoice.system => t.themeSystem,
    AppThemeChoice.light => t.themeLight,
    AppThemeChoice.dark => t.themeDark,
  };

  /// 图片质量（同上）
  static String _qualityLabel(AppText t, ImageQuality q) => switch (q) {
    ImageQuality.original => t.qualityOriginal,
    ImageQuality.standard => t.qualityStandard,
  };

  static String _qualityHint(AppText t, ImageQuality q) => switch (q) {
    ImageQuality.original => t.qualityOriginalHint,
    ImageQuality.standard => t.qualityStandardHint,
  };

  /// 语言（语言名用**本语言自称**，切错了也能认出来）
  static String _languageLabel(AppText t, LocaleChoice c) => switch (c) {
    LocaleChoice.system => t.langSystem,
    LocaleChoice.zh => t.langZh,
    LocaleChoice.en => t.langEn,
  };

  /// 缓存管理：清空（二次确认）
  Future<void> _manageCache(BuildContext context, WidgetRef ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.t.dialogClearCacheTitle),
        content: Text(context.t.dialogClearCacheBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.t.actionClear),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final freed = await ref.read(cacheServiceProvider).clear();
    ref.invalidate(cacheUsageProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t.cacheCleared(humanBytes(freed)))),
      );
    }
  }

  static String _limitLabel(AppText t, int bytes) {
    if (bytes <= 0) return t.cacheUnlimited;
    for (final o in kCacheLimitOptions) {
      if (o.bytes == bytes) return o.label;
    }
    return '${(bytes / 1048576).toStringAsFixed(0)} MB';
  }

  /// 图生图入口的副标题：**开没开 / 发给谁 / 每天几张**，一眼看完。
  static String _photoAiEditSubtitle(PhotoAiEditSettings? s) {
    if (s == null || !s.enabled) {
      return photoAiEdit(
        PhotoAiEditTextKeys.settingsEntryOff,
        '已关闭（照片不会被发送）',
      );
    }
    final backend = s.backend.labelText;
    final cap = s.dailyCap == 0
        ? photoAiEdit(PhotoAiEditTextKeys.settingsCapOff, '关闭（0 张/日）')
        : photoAiEditFill(PhotoAiEditTextKeys.settingsCapValue, '{count} 张/日', {
            'count': '${s.dailyCap}',
          });
    return photoAiEditFill(
      PhotoAiEditTextKeys.settingsEntryOn,
      '已启用 · {backend} · {count}',
      {'backend': backend, 'count': cap},
    );
  }

  Widget _section(BuildContext context, String title) =>
      DesignSectionHeader(title);

  Future<void> _pickTheme(
    BuildContext context,
    WidgetRef ref,
    AppThemeChoice current,
  ) async {
    final picked = await showModalBottomSheet<AppThemeChoice>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<AppThemeChoice>(
          groupValue: current,
          onChanged: (v) => Navigator.of(ctx).pop(v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final choice in AppThemeChoice.values)
                RadioListTile<AppThemeChoice>(
                  value: choice,
                  title: Text(_themeLabel(context.t, choice)),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      await ref.read(themeChoiceProvider.notifier).set(picked);
      // 使用日志：主题/外观偏好（稳定 id system/light/dark）
      trackSelect(UsageModule.settings, picked.name, kind: 'theme');
    }
  }

  Future<void> _pickQuality(
    BuildContext context,
    WidgetRef ref,
    ImageQuality current,
  ) async {
    final picked = await showModalBottomSheet<ImageQuality>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<ImageQuality>(
          groupValue: current,
          onChanged: (v) => Navigator.of(ctx).pop(v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final q in ImageQuality.values)
                RadioListTile<ImageQuality>(
                  value: q,
                  title: Text(_qualityLabel(context.t, q)),
                  subtitle: Text(_qualityHint(context.t, q)),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      await ref.read(imageQualityProvider.notifier).set(picked);
    }
  }

  /// 语言：跟随系统 / 简体中文 / English
  Future<void> _pickLanguage(BuildContext context, WidgetRef ref) async {
    final current = ref.read(localeChoiceProvider);
    final picked = await showModalBottomSheet<LocaleChoice>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<LocaleChoice>(
          groupValue: current,
          onChanged: (v) => Navigator.of(ctx).pop(v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in LocaleChoice.values)
                RadioListTile<LocaleChoice>(
                  value: c,
                  title: Text(_languageLabel(ctx.t, c)),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      await ref.read(localeChoiceProvider.notifier).set(picked);
      // 使用日志：语言偏好（稳定语言代码 system/zh/en）+ 切换语言动作
      trackSelect(UsageModule.settings, picked.rawValue, kind: 'language');
      trackOnce(
        UsageModule.settings,
        UsageAction.switchLanguage,
        objectType: picked.rawValue,
      );
    }
  }

  /// 「收到消息通知时预加载消息」三档选择（原版 `preview_new_message`）
  Future<void> _pickPostPreviewMode(BuildContext context, WidgetRef ref) async {
    final current = ref.read(postPreviewModeProvider);
    final picked = await showModalBottomSheet<PostPreviewMode>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<PostPreviewMode>(
          groupValue: current,
          onChanged: (v) => Navigator.of(ctx).pop(v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final m in PostPreviewMode.values)
                RadioListTile<PostPreviewMode>(
                  value: m,
                  title: Text(m.labelIn(ctx.t)),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      await ref.read(postPreviewModeProvider.notifier).set(picked);
    }
  }

  /// 排序方式的一句话摘要（四个分组都同档时只显示一档）
  String _sortSummary(AppText t, ChannelSortPrefs p) {
    final all = {p.favorite, p.channel, p.conversation, p.chatbot};
    if (all.length == 1) return all.first.labelIn(t);
    return t.sortSummaryMixed(
      p.favorite.labelIn(t),
      p.channel.labelIn(t),
      p.conversation.labelIn(t),
      p.chatbot.labelIn(t),
    );
  }

  /// 先选哪个分组（原版是四个独立选项）
  Future<void> _pickSortTarget(BuildContext context, WidgetRef ref) async {
    final prefs = ref.read(channelSortPrefsProvider);
    final target = await showModalBottomSheet<ChannelSortTarget>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in ChannelSortTarget.values)
              DesignRowTile(
                title: Text(t.labelIn(ctx.t)),
                trailing: Text(switch (t) {
                  ChannelSortTarget.favorite => prefs.favorite.labelIn(ctx.t),
                  ChannelSortTarget.channel => prefs.channel.labelIn(ctx.t),
                  ChannelSortTarget.conversation => prefs.conversation.labelIn(
                    ctx.t,
                  ),
                  ChannelSortTarget.chatbot => prefs.chatbot.labelIn(ctx.t),
                }, style: Theme.of(ctx).textTheme.bodySmall),
                onTap: () => Navigator.of(ctx).pop(t),
              ),
          ],
        ),
      ),
    );
    if (target == null || !context.mounted) return;
    final picked = await showModalBottomSheet<ChannelSortMethod>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in ChannelSortMethod.values)
              DesignRowTile(
                title: Text(m.labelIn(ctx.t)),
                onTap: () => Navigator.of(ctx).pop(m),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await ref.read(channelSortPrefsProvider.notifier).set(target, picked);
  }

  Future<void> _pickCacheLimit(
    BuildContext context,
    WidgetRef ref,
    int current,
  ) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<int>(
          groupValue: current,
          onChanged: (v) => Navigator.of(ctx).pop(v),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final o in kCacheLimitOptions)
                RadioListTile<int>(
                  value: o.bytes,
                  title: Text(_limitLabel(ctx.t, o.bytes)),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      await ref.read(cacheLimitProvider.notifier).set(picked);
    }
  }
}

/// 缓存用量（设置页展示）
///
/// ★ 第 425 轮（`DA84`）：改 `autoDispose`。原先是**会话级缓存**，只在"清空后
/// `invalidate`"这一处刷新 ⇒ 真机复现：`Clear` 后去掉进视频目录（首帧重新抽出来、
/// `video_frames` 已有 68 KB 4 个文件），回到设置页这一行仍写着 `No cache`
/// —— 用户看到的数字与设备上的缓存不一致。`autoDispose` 让它**每次进设置页重算**；
/// 加载态走 `t.cacheCounting`（"正在统计…"），不会把"还在数"谎报成"没有缓存"。
final cacheUsageProvider = FutureProvider.autoDispose<CacheUsage>((ref) async {
  final limit = ref.watch(cacheLimitProvider);
  return ref.watch(cacheServiceProvider).usage(limitBytes: limit);
}, retry: noRetry);

/// 当前服务器（地址 + 连接方式），没连上就显示"未连接"
String serverLabelOf(WidgetRef ref, AppText t) {
  final session = ref.watch(sessionControllerProvider);
  final conn = session.connection;
  if (conn == null) return t.setNotConnected;
  final src = conn.endpoint.source;
  final base = conn.endpoint.baseUrl;
  if (src.isEmpty) return base;
  // ★ r343 D54：`src` 是内部 token（`direct`/`lan`/…）⇒ 走唯一的标签生产者。
  return settingsGap(SettingsGapTextKeys.serverLabel, '$base（{source}）')
      .replaceAll('{base}', base)
      .replaceAll('{source}', connectSourceLabel(src, t));
}

/// 应用锁开关（4 位数字口令）。开/关/改口令都走 [PasscodeService]。
class _AppLockTile extends ConsumerStatefulWidget {
  const _AppLockTile();

  @override
  ConsumerState<_AppLockTile> createState() => _AppLockTileState();
}

class _AppLockTileState extends ConsumerState<_AppLockTile> {
  bool _loading = true;
  bool _enabled = false;
  PasscodeExpiration _expiration = PasscodeExpiration.always;

  /// 设备真的支持生物识别（且已录入）时才显示这一项
  bool _bioAvailable = false;
  bool _bioEnabled = false;
  BiometricKind _bioKind = BiometricKind.none;

  /// 生物识别类型标签（界面按语言取；`BiometricKind.label` 只是中文回落）
  static String _bioLabelIn(AppText t, BiometricKind kind) => switch (kind) {
    BiometricKind.face => t.passcodeFace,
    BiometricKind.fingerprint => t.passcodeFingerprint,
    BiometricKind.other => t.passcodeBiometric,
    BiometricKind.none => t.passcodeBiometric,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = ref.read(settingsServiceProvider);
    final on = await s.passcodeEnabled();
    final exp = await s.passcodeExpiration();
    final bioOn = await s.fingerprintEnabled();
    final auth = ref.read(biometricAuthenticatorProvider);
    final bioAvailable = on && await auth.isAvailable();
    final kind = bioAvailable ? await auth.kind() : BiometricKind.none;
    if (!mounted) return;
    setState(() {
      _enabled = on;
      _expiration = exp;
      _bioEnabled = bioOn;
      _bioAvailable = bioAvailable;
      _bioKind = kind;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return DesignRowTile(
        leading: const Icon(Icons.password_outlined),
        title: Text(context.t.setAppLock),
        subtitle: Text(context.t.setAppLockLoading),
      );
    }
    return Column(
      children: [
        DesignSwitchRow(
          secondary: const Icon(Icons.password_outlined),
          title: Text(context.t.setAppLock),
          subtitle: Text(
            _enabled
                ? context.t.setAppLockOn(_passcodeLen)
                : context.t.setAppLockOff,
          ),
          value: _enabled,
          onChanged: (on) => on ? _enable() : _disable(),
        ),
        if (_enabled) ...[
          // 原版只在"应用锁已开 + 设备支持"时才显示生物识别项
          if (_bioAvailable)
            DesignSwitchRow(
              secondary: Icon(
                _bioKind == BiometricKind.face
                    ? Icons.face_outlined
                    : Icons.fingerprint,
              ),
              title: Text(
                context.t.passcodeUnlockWithLabel(
                  _bioLabelIn(context.t, _bioKind),
                ),
              ),
              subtitle: Text(context.t.passcodeBioHint),
              value: _bioEnabled,
              onChanged: (on) async {
                await ref
                    .read(settingsServiceProvider)
                    .setFingerprintEnabled(on);
                if (!mounted) return;
                ref.invalidate(biometricUnlockAvailableProvider);
                setState(() => _bioEnabled = on);
              },
            ),
          DesignRowTile(
            leading: const Icon(Icons.timer_outlined),
            title: Text(context.t.passcodeReauthInterval),
            // ★ r371（DA17）：走本地化出口（原来的 `_expiration.label` 是中文成品串）
            subtitle: Text(_expiration.labelIn(context.t)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickExpiration,
          ),
          DesignRowTile(
            leading: const Icon(Icons.lock_clock_outlined),
            title: Text(context.t.passcodeLockNow),
            onTap: () {
              ref.read(passcodeLockProvider.notifier).lockNow();
              Navigator.of(context).maybePop();
            },
          ),
        ],
      ],
    );
  }

  static const int _passcodeLen = 4;

  Future<void> _enable() async {
    final code = await _askPasscode(
      context,
      title: context.t.passcodeSetTitle,
      confirm: true,
    );
    if (code == null) return;
    await ref.read(passcodeServiceProvider).setPasscode(code);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.t.passcodeEnabledToast)));
    // 原版 `promoteBiometricUnlock()`：开了应用锁就主动建议开生物识别
    if (_bioAvailable && !_bioEnabled) {
      await _promoteBiometric();
    }
  }

  /// 询问是否启用生物识别（原版 `passcode_allow_biometrics_unlock_*` 文案）
  Future<void> _promoteBiometric() async {
    final label = _bioLabelIn(context.t, _bioKind);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.t.passcodeEnableBioTitle(label)),
        content: Text(
          context.t.passcodeEnableBioBody(platformAppName(), label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t.passcodeNotNow),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.t.passcodeEnable),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await ref.read(settingsServiceProvider).setFingerprintEnabled(true);
    if (!mounted) return;
    ref.invalidate(biometricUnlockAvailableProvider);
    setState(() => _bioEnabled = true);
  }

  Future<void> _disable() async {
    final code = await _askPasscode(
      context,
      title: context.t.passcodeEnterToDisable,
    );
    if (code == null) return;
    final svc = ref.read(passcodeServiceProvider);
    if (!await svc.verify(code)) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.t.passcodeWrong)));
      }
      return;
    }
    await svc.disable();
    ref.read(passcodeLockProvider.notifier).markDisabled();
    await _load();
  }

  Future<void> _pickExpiration() async {
    final picked = await showModalBottomSheet<PasscodeExpiration>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<PasscodeExpiration>(
          groupValue: _expiration,
          onChanged: (v) => Navigator.of(ctx).pop(v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in PasscodeExpiration.values)
                RadioListTile<PasscodeExpiration>(
                  value: e,
                  title: Text(e.labelIn(ctx.t)),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    await ref.read(settingsServiceProvider).setPasscodeExpiration(picked);
    await _load();
  }
}

/// 弹一个 4 位数字输入框；[confirm] 时要求输两遍
Future<String?> _askPasscode(
  BuildContext context, {
  required String title,
  bool confirm = false,
}) async {
  final first = TextEditingController();
  final second = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        String? error;
        void submit() {
          final a = first.text;
          if (!PasscodeService.isValidFormat(a)) {
            setState(() => error = context.t.passcodeMust4Digits);
            return;
          }
          if (confirm && a != second.text) {
            setState(() => error = context.t.passcodeMismatch);
            return;
          }
          Navigator.of(ctx).pop(a);
        }

        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: first,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                decoration: InputDecoration(
                  labelText: context.t.passcodeFieldLabel4,
                ),
              ),
              if (confirm)
                TextField(
                  controller: second,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  decoration: InputDecoration(
                    labelText: context.t.passcodeRepeat,
                  ),
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(context.t.actionCancel),
            ),
            FilledButton(onPressed: submit, child: Text(context.t.actionOk)),
          ],
        );
      },
    ),
  );
  return result;
}

/// 目标机性能档位（遥测行）：告诉用户"自动"到底选了哪一档。
class _DeviceTierTile extends StatelessWidget {
  const _DeviceTierTile({required this.profile});

  final DeviceProfile profile;

  @override
  Widget build(BuildContext context) {
    return DesignRowTile(
      leading: const Icon(Icons.memory_outlined),
      title: Text(context.t.setDeviceTier(profile.tierLabelIn(context.t))),
      subtitle: Text(
        context.t.setDeviceTierSpec(
          profile.specLabelIn(context.t),
          profile.preferBlur ? context.t.setOn : context.t.setOff,
          profile.preferReducedMotion
              ? context.t.setMotionReduced
              : context.t.setMotionFull,
          // ★ r494：不再列"网格底纹" —— 底纹退役后这一项没有意义
          // （档位里的 `preferChatGrid` 字段保留，仅设计样张页还在读）。
        ),
      ),
      isThreeLine: true,
    );
  }
}

/// 带"自动"语义的效果开关：值没被手动改过时显示当前档位的自动判定，
/// 手动改过之后多一个「恢复自动」把覆盖值清掉。
class _EffectSwitch extends ConsumerWidget {
  const _EffectSwitch({
    required this.kind,
    required this.icon,
    required this.title,
    required this.hint,
    required this.value,
    required this.deviceDefault,
    required this.onChanged,
  });

  final EffectKind kind;
  final IconData icon;
  final String title;
  final String hint;
  final bool value;

  /// 设备档位给出的**本开关默认值**（性能模式是"反着来"的：默认开 = 关毛玻璃）
  final bool deviceDefault;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final override = ref.watch(effectOverrideProvider(kind));
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DesignSwitchRow(
          secondary: Icon(icon),
          title: Text(title),
          subtitle: Text(
            override == null
                // 与原文案逐字一致：中文里"·"前不留空格
                ? '${context.t.setAutoHint(deviceDefault ? context.t.setOn : context.t.setOff)}· '
                      '$hint'
                : '${context.t.setManualHint(value ? context.t.setOn : context.t.setOff, deviceDefault ? context.t.setOn : context.t.setOff)}· '
                      '$hint',
          ),
          value: value,
          onChanged: onChanged,
        ),
        if (override != null)
          Padding(
            padding: const EdgeInsets.only(left: 72, bottom: 4),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                foregroundColor: cs.primary,
                textStyle: text.labelMedium,
              ),
              icon: const Icon(Icons.restart_alt, size: 16),
              label: Text(context.t.setRestoreAuto),
              onPressed: () =>
                  ref.read(effectOverrideProvider(kind).notifier).set(null),
            ),
          ),
      ],
    );
  }
}


/// `设置` 列表里「通知与后台」那一行 —— 状态**实时问系统**。
///
/// ★ r342 D45：原来读的是会话内存里的 `foregroundService` 快照，只在
/// "socket 就绪"与"用户拨开关"两条路上更新 ⇒ 只要服务是由别的原因在跑的
/// （真机：`install -r` 之后系统把上一进程的常驻服务又拉起来了），
/// 这一行就会显示「前台服务未运行」，**与 `dumpsys activity services` 相反**。
class _ForegroundServiceTile extends ConsumerStatefulWidget {
  const _ForegroundServiceTile({
    required this.title,
    required this.runningText,
    required this.stoppedText,
    required this.onTap,
  });

  final String title;
  final String runningText;
  final String stoppedText;
  final VoidCallback onTap;

  @override
  ConsumerState<_ForegroundServiceTile> createState() =>
      _ForegroundServiceTileState();
}

class _ForegroundServiceTileState
    extends ConsumerState<_ForegroundServiceTile> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 回到前台重新问一次（值可能被 App 之外的东西改：系统回收/重启服务、用户改放行）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(foregroundServiceRunningProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final running =
        ref.watch(foregroundServiceRunningProvider).value ?? false;
    return DesignRowTile(
      leading: const Icon(Icons.notifications_outlined),
      title: Text(widget.title),
      subtitle: Text(running ? widget.runningText : widget.stoppedText),
      trailing: const Icon(Icons.chevron_right),
      onTap: widget.onTap,
    );
  }
}
