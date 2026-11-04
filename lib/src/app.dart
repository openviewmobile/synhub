import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/i18n/l10n.dart';
import 'core/router/app_router.dart';
import 'features/servers/certificate_trust_dialog.dart';
import 'core/security/passcode_service.dart';
import 'core/settings/app_settings.dart';
import 'core/settings/acl.dart';
import 'core/settings/server_settings.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/wallpaper_seed.dart';
import 'core/theme/app_tokens.dart';
import 'core/ui/fold_posture.dart';
import 'core/ui/system_bars.dart';
import 'features/notifications/notification_service.dart';
import 'features/notifications/reminder_scheduler.dart';
import 'features/security/passcode_screen.dart';
import 'features/ai/ai_providers.dart';
import 'features/admin/admin_identity.dart' show adminIdentityProvider;
import 'features/files/book_providers.dart';
import 'features/analytics/analytics_providers.dart';
import 'core/net/device_traffic.dart';
import 'core/net/traffic_meter.dart';
import 'features/analytics/analytics_track.dart';
import 'core/services/service_availability.dart';
import 'features/shell/workspace_providers.dart';
import 'features/shell/workspace_recent.dart';
import 'features/servers/session_controller.dart';
import 'features/settings/snooze_controller.dart';
import 'features/chat/chat_deep_link_host.dart' show ChatDeepLinkHost;

/// 应用根组件。状态容器由 `main.dart` 的 ProviderScope 提供。
///
/// Phase 8：这里挂两个后台相关的东西
///   * `WidgetsBindingObserver` → 通知服务要知道 App 在不在前台
///     （在前台看那个频道时不弹通知）；
///   * `setActionHandler` → 通知栏里的「回复/已读/贪睡」回传到 Dart。
class SynologyChatApp extends ConsumerStatefulWidget {
  const SynologyChatApp({super.key});

  @override
  ConsumerState<SynologyChatApp> createState() => _SynologyChatAppState();
}

class _SynologyChatAppState extends ConsumerState<SynologyChatApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final service = ref.read(notificationServiceProvider);
    ref.read(backgroundServiceProvider).setActionHandler((action) {
      service.handleAction(action);
    });
    // Phase 9：把持久化的本地设置读进内存（主题/图片质量/缓存上限）
    unawaited(ref.read(themeChoiceProvider.notifier).preload());
    // 界面语言（跟随系统 / 中文 / English）
    unawaited(ref.read(localeChoiceProvider.notifier).preload());
    unawaited(ref.read(imageQualityProvider.notifier).preload());
    unawaited(ref.read(cacheLimitProvider.notifier).preload());
    unawaited(ref.read(sendByEnterProvider.notifier).preload());
    unawaited(ref.read(postPreviewModeProvider.notifier).preload());
    unawaited(ref.read(channelSortPrefsProvider.notifier).preload());
    unawaited(ref.read(sidebarCollapsedProvider.notifier).preload());
    // 工作台：把「最常用的入口排第一屏」的点击统计读进来
    unawaited(ref.read(workspaceUsageProvider.notifier).preload());
    // 工作台：被「使用分析」收起过的入口（本地偏好，可一键还原）
    unawaited(ref.read(workspaceHiddenProvider.notifier).preload());
    // 工作台：「最近常用」的记录（最近真的打开过谁，倒序）
    unawaited(ref.read(workspaceRecentProvider.notifier).preload());
    // 服务检测安全阀：「临时显示隐藏的模块」本地偏好
    unawaited(ref.read(showHiddenServicesProvider.notifier).preload());
    // 端侧 AI：开关 / 仅 WiFi / 选中的模型档位
    unawaited(preloadAiSettings(ref));
    unawaited(preloadReaderPrefs(ref));
    // 使用日志（本地）：读开关/盐，并把单例挂到全局（没有 ref 的地方也能记）
    unawaited(() async {
      await ref.read(analyticsEnabledProvider.notifier).load();
      setGlobalUsageLog(ref.read(usageLogProvider));
      final account = ref
          .read(sessionControllerProvider)
          .connection
          ?.session
          ?.account;
      ref.read(usageLogProvider).setAccount(account);
    }());
    // 网络流量计量（本地聚合，不上传）：
    //   * 精确档 —— Dio 适配器按"字节真的流过"计数，写入端挂全局；
    //   * 估算档 —— 原生播放器绕过 Dart，用 UID 计数在**已知活动会话**窗口差分；
    //   * 系统 UID 基线 —— 流量页的"系统对比"基准（没有就现在存一份）。
    unawaited(() async {
      final trafficLog = ref.read(trafficLogProvider);
      await ref.read(analyticsEnabledProvider.notifier).load();
      trafficLog.enabled = ref.read(analyticsEnabledProvider);
      setGlobalTrafficSink(trafficLog);
      setGlobalEstimatedTraffic(
        EstimatedTrafficTracker(
          probe: ref.read(deviceTrafficProbeProvider),
          sink: trafficLog,
        ),
      );
      if (await trafficLog.osBaseline() == null) {
        final snap = await ref.read(deviceTrafficProbeProvider).snapshot();
        if (snap != null) await trafficLog.saveOsBaseline(snap.toJson());
      }
    }());
    // Phase 10（UI 现代化）：Material You 动态取色 / 性能模式 / 减少动效
    // 后三个是"三态"：存的是**手动覆盖值**（null = 跟随设备性能自动），
    // 所以这里 preload 的是覆盖值，生效值由 `perfModeProvider` 等派生。
    unawaited(ref.read(dynamicColorProvider.notifier).preload());
    for (final kind in EffectKind.values) {
      unawaited(ref.read(effectOverrideProvider(kind).notifier).preload());
    }
    // 服务端设置（文件大小上限 / 编辑窗口 / 加密开关…）：先用上次缓存，登录后再拉
    unawaited(ref.read(serverSettingsProvider.notifier).preload());
    unawaited(ref.read(myAclProvider.notifier).preload());
    // Phase 9：免打扰（手动 snooze + 定时）的本地镜像，登录后再从服务端校准
    unawaited(ref.read(snoozeControllerProvider.notifier).preload());
    // Phase 9：应用锁（开了的话冷启动就停在锁屏）
    unawaited(ref.read(passcodeLockProvider.notifier).init());
    // Phase 6+8：提醒到点 → 本地通知（原版靠 FCM，我们不用 FCM，见
    // `ReminderScheduler` 文件头）。启动就扫一遍，补上"进程被杀期间"到点的提醒。
    ref.read(reminderSchedulerProvider).start();
    // Phase 9：首连信任 —— 把"问用户"接到全局导航上（后台任务里没人问就拒绝）
    final trust = ref.read(trustPolicyProvider);
    trust.prompt = (challenge) async {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return false;
      return showCertificateTrustDialog(ctx, challenge);
    };
    unawaited(trust.load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final service = ref.read(notificationServiceProvider);
    service.appInForeground = state == AppLifecycleState.resumed;
    // Phase 9：退到后台记时间戳，回前台按 `passcode_expiration` 决定要不要重锁
    final lock = ref.read(passcodeLockProvider.notifier);
    if (state == AppLifecycleState.resumed) {
      unawaited(lock.onResumed());
      // 回前台**先探一次会话存活**：官方 DSfile 用
      // `SYNO.Core.Desktop.Timeout / check` v1 做这件事
      // （`WebApiConnectionManager.smali:3458`，方法名 `check`）。
      // NAS 的空闲超时（真机实测 15 分钟）会把 sid 挂掉，不探的话
      // 用户回来后**第一个动作**才吃 119；探到已经挂了就顺手刷新服务状态，
      // UI 才能如实显示"需要重连"而不是假装一切都好。
      unawaited(_probeSessionAlive());
      // ★ D7 残留修复（触发点②）：**回到前台**时，如果会话身份上一次是
      // `failed`，自动补一次解析（每会话至多一次 —— 两个触发点共用同一份
      // 预算，见 `AdminIdentityController.triggerAutoRetry`）。
      // 非 `failed` 时它什么都不做，所以这里不必先判断。
      ref.read(adminIdentityProvider.notifier).triggerAutoRetry();
      // 回前台补扫：退后台期间定时器可能被系统冻住，醒着的时候总得把欠的提醒弹掉
      ref.read(reminderSchedulerProvider).wake();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      lock.onPaused();
    }
  }

  /// 会话存活探针（见 [DsmWebApi.checkSessionAlive]）。
  ///
  /// **只读**：`check` 不改服务端任何状态。
  /// 探到会话没了**不自己重登** —— 重登要凭据、要走 `SessionController`
  /// 的既有流程，这里只负责把"需要重连"这件事暴露出去。
  Future<void> _probeSessionAlive() async {
    final api = ref.read(availabilityApiProvider);
    if (api == null) return;
    bool alive;
    try {
      alive = await api.checkSessionAlive();
    } catch (_) {
      return; // 探测本身失败不代表会话失效，静默即可
    }
    if (alive || !mounted) return;
    // 服务可用性快照是按"当前会话"算的，会话没了就该重算。
    ref.invalidate(serviceAvailabilityProvider);
  }

  @override
  Widget build(BuildContext context) {
    // Phase 9：主题三档（原版 `dark_mode` = -1/1/2）
    final themeChoice = ref.watch(themeChoiceProvider);
    final localeChoice = ref.watch(localeChoiceProvider);
    // Phase 10：Material You 动态取色（可关）+ 效果开关
    final useDynamic = ref.watch(dynamicColorProvider);
    final perfMode = ref.watch(perfModeProvider);
    final reduceMotion = ref.watch(reducedMotionProvider);
    // 效果开关是全局静态（组件里不必都变成 ConsumerWidget）
    AppEffects.sync(reducedMotion: reduceMotion, reducedBlur: perfMode);

    // 数据层（异常文案表）拿不到 context，这里把"当前语言的文案表"同步过去
    //
    // ★★ P0-1（Linux 站，第 109 轮）：**必须先归一化再查表**。
    // 之前这里是 `setCurrentText(lookupAppText(resolvedLocale))`：容器 / 最小
    // Linux 上 `LANG` 未设置 ⇒ 平台 locale = `Locale('C')` ⇒
    // `lookupAppText` 抛 `FlutterError` ⇒ **build 当场炸 ⇒ 整屏红屏**
    // （原始像素 `r108-linux-locale-C-redscreen.png`，见 docs/platform-linux.md §8.4）。
    // `resolveAppLocale` 只回落不抛，且与下面 `localeResolutionCallback` 用同一套
    // 映射，保证界面层与数据层**不会是两种语言**。
    final resolvedLocale = resolveAppLocale(
      localeChoice.locale ??
          WidgetsBinding.instance.platformDispatcher.locale,
    );
    setCurrentText(lookupAppTextSafe(resolvedLocale));

    Widget app(ColorScheme? lightDynamic, ColorScheme? darkDynamic) =>
        MaterialApp.router(
          // 任务切换器/最近任务里显示的名字（跟随当前界面语言；跟随系统时
          // 用平台 locale 判定，别在英文系统上显示中文名）
          title: appNameIn(resolvedLocale),
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(dynamic: useDynamic ? lightDynamic : null),
          darkTheme: AppTheme.dark(dynamic: useDynamic ? darkDynamic : null),
          // ★ DA342：Linux 的系统深色偏好由我们自己读（见 `systemPrefersDarkProvider`）
          themeMode: resolveThemeMode(
            themeChoice,
            systemPrefersDark: ref.watch(systemPrefersDarkProvider),
          ),
          // flutter_quill 的工具栏/对话框要它自己的本地化资源，缺了会直接抛
          // `MissingFlutterQuillLocalizationException`（笔记编辑器发现）
          localizationsDelegates: const [
            // 我们自己的文案（ARB → AppText）
            AppText.delegate,
            FlutterQuillLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          // 我们自己的 zh/en + flutter_quill 支持的语言并集：
          // 少一个 quill 就会在它的工具栏里抛 MissingFlutterQuillLocalizationException
          supportedLocales: {
            ...AppText.supportedLocales,
            ...FlutterQuillLocalizations.supportedLocales,
          }.toList(),
          // 语言：默认跟随系统；设置里可以钉死中文/英文。
          // 钉死之后 flutter_quill 的工具栏也不会在英文系统上冒出 Undo/Bold。
          //
          // ★★ P0-1：未知 locale（`LANG=C` / `POSIX` / 引擎给的怪值）在这里
          // **一律归一到受支持的语言**，不让它落到任何 delegate 里去抛。
          localeResolutionCallback: (locale, supported) =>
              resolveAppLocale(locale),
          locale: localeChoice.locale,
          // 应用锁：锁上时盖住整个界面（含路由）
          // 审计行 262：聊天深链必须在**应用级**消费。
          // 只挂在 `channel_list_page` 是不够的 —— 冷启动点链接时用户**还没登录**，
          // 那条页面根本还没出现，深链就会丢。这里包在最外层：
          // ChatDeepLinkHost 收深链 → 写 `chatDeepLinkPrefillProvider`
          // → 连接页/登录页在各自 initState 里读取预填。
          //
          // ★ 第 294 轮：外面再包一层 `FoldPostureLayout` —— 本机
          // `MediaQuery.displayFeatures` **恒空**（真机取证见
          // `lib/src/core/ui/fold_posture.dart` 文件头），半折时由传感器
          // 角度**合成**一条 `fold` 带塞回 `displayFeatures`，下游
          // `FoldAvoidingLayout` / `AdaptiveScaffold` **一行都不用改**。
          // 姿态未知 / 摊平 / 合上 ⇒ 它原样 `return child`（连 `MediaQuery`
          // 都不包）⇒ 与改造前逐字节一致。
          //
          // ★★ DA102（第 455 轮）：最外层再包一层 `SystemBarsScope` ——
          // **App 自己声明状态栏口径**。此前全仓没人声明（`grep` 0 命中），
          // 于是"状态栏什么颜色"只由 Material `AppBar` 或 ROM 主题默认值决定：
          // 新窗口回 ROM 的 `#40000000`（25% 黑）⇒ 外壳五个 Tab / 连接页 /
          // 登录页顶部一条灰带，而进过 AppBar 页之后该值**残留**成透明。
          // 本层给"没有 AppBar 的页"补上 AppBar 已经发布的那一套（M3 口径，
          // 逐字对齐 ⇒ 有 AppBar 的页一字不变）。取证见
          // `docs/android-ui-audit-r454.md` / `r455.md`，口径见
          // `lib/src/core/ui/system_bars.dart`。
          builder: (context, child) => SystemBarsScope(
            child: FoldPostureLayout(
              child: ChatDeepLinkHost(
                child: PasscodeGate(child: child ?? const SizedBox.shrink()),
              ),
            ),
          ),
          routerConfig: appRouter,
        );

    if (!useDynamic) return app(null, null);
    // ★ 第 231 轮（用户裁定"要想办法真正取到壁纸色"）：
    //   `DynamicColorBuilder` 只在**有 Material You** 的机器上给方案；EMUI/HarmonyOS、
    //   Android<12、OEM 关掉的 ROM 一律回调 null ⇒ 以前这里就落到品牌蓝，
    //   "跟随壁纸"是假开关。现在补一条不依赖 M3 的通道：读 `WallpaperManager`
    //   的主色（或自读壁纸图算的加权平均色）当 seed，仍然只借它的**色相**。
    final wallpaper = ref.watch(wallpaperSeedProvider).asData?.value;
    ColorScheme? wallpaperLight;
    ColorScheme? wallpaperDark;
    final wallColor = wallpaper?.usable == true ? wallpaper!.color : null;
    if (wallColor != null) {
      wallpaperLight = ColorScheme.fromSeed(seedColor: wallColor);
      wallpaperDark = ColorScheme.fromSeed(
        seedColor: wallColor,
        brightness: Brightness.dark,
      );
    }
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => app(
        lightDynamic ?? wallpaperLight,
        darkDynamic ?? wallpaperDark,
      ),
    );
  }
}
