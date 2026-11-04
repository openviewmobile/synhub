import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

import 'src/app.dart';
import 'src/core/device/device_profile.dart';
import 'src/core/i18n/l10n.dart';
import 'src/core/platform/desktop_notify_linux.dart';
import 'src/core/platform/desktop_tray_linux.dart';
import 'src/core/platform/status_notifier_linux.dart';
import 'src/core/security/biometric_auth.dart';
import 'src/core/security/keystore_secret_keeper.dart';
import 'src/core/settings/app_settings.dart';
import 'src/data/note_api.dart';
import 'src/features/audio/audio_player.dart';
import 'src/features/media/audio_handler.dart';
import 'src/features/notes/note_background_sync_scheduler.dart';

Future<void> main() async {
  // `AudioService.init` 要用平台通道（渠道注册 / 媒体会话），必须先确保 binding。
  WidgetsFlutterBinding.ensureInitialized();

  // ★ r701 · `DA340`：Linux 的钥匙串起飞前检查**先异步预热**（文件在 **且**
  //   至少一个 collection 未锁，才允许碰 libsecret）。锁着的 collection 一碰就弹
  //   「Unlock Login Keyring」，而那个调用同步阻塞 GTK 主循环 ⇒ 整页停帧。
  //   **失败绝不许拦住启动**：最坏结果是"这台机器不记住口令"。
  if (defaultTargetPlatform == TargetPlatform.linux) {
    try {
      await KeystoreSecretKeeper.warmUpLinuxKeyringProbe();
    } catch (e) {
      debugPrint('[keyring] 预热失败（按不可用处理）：$e');
    }
  }

  // ★ r655：libmpv 兜底引擎（AC3/EAC3/DTS/APE 软解）要求先初始化 media_kit，
  //   否则 `Player()` 一构造就抛。**必须在 runApp 之前**，且只初始化一次。
  //
  // ★★ `DA282`（r664）：**只在带 `Mpv.framework` 的平台初始化**。
  //   当时 `media_kit_libs_*` 只带了 Android 那份，iOS/macOS/Windows/Linux
  //   上没有 `Mpv.framework` ⇒ 无条件调用会在 `runApp` 之前抛
  //   `Unhandled Exception: Cannot find Mpv.framework/Mpv`，**整个 App 白屏**
  //   （真机取证：iOS 模拟器白屏；macOS Release 二进制 stderr 同一句）。
  //   r678 起 iOS 也有那份 framework（`media_kit_libs_ios_video`）⇒ 加进这一列；
  //   macOS/Windows/Linux 仍**不**初始化。**失败也不许拦住启动**。
  //   ★ r678：**iOS 也走这条路**（`media_kit_libs_ios_video` 已随包，`Mpv.framework`
  //   在 `Runner.app/Frameworks/` 里）—— `.mkv`/`.AVI` 的 AVFoundation 兜底引擎。
  //   仍然保留 try/catch：万一某台构建没有那份 framework，顶多退回主引擎，
  //   **不许拦住启动**（`DA282` 的原始教训）。
  //   ★ r690：**Linux 并入这一列** —— `media_kit_libs_linux` 随包带 Linux 版
  //   libmpv，视频走 `MpvPlayerAdapter`、音频走 `just_audio_media_kit`，两条都以
  //   media_kit 为底座；不初始化 ⇒ Linux 上 `Player()` 一构造就抛。
  //   ★ r703：**Windows 一并纳入** —— `media_kit_libs_windows_video` 已进 pubspec，
  //   构建期把 libmpv 摆到 runner 旁边；不初始化 ⇒ 音频后端（just_audio_media_kit）
  //   与视频兜底引擎（mpv）在 Windows 上第一条 `Player()` 就抛。
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows) {
    try {
      MediaKit.ensureInitialized();
    } catch (e, st) {
      debugPrint('[media] MediaKit 初始化失败（视频退回主引擎/插件）：$e');
      debugPrintStack(stackTrace: st, maxFrames: 6);
    }
  }

  // 先探一次目标机规格（同步读 /proc/meminfo + 核数）：三档（入门/中端/高端）
  // 决定"毛玻璃 / 动效 / 网格底纹"的**默认**开关，用户在设置里可随时覆盖。
  // ★ r690：Linux 上的 `just_audio` 本身没有实现 —— 后端换成 media_kit（libmpv）。
  //   必须先于**任何** `AudioPlayer()` 构造。只在 Linux 打开（Windows 站没装
  //   media_kit 的 Windows 库，别替它改行为）。
  if (defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows) {
    try {
      // ★ r703：Windows 也接这条（`media_kit_libs_windows_video` 带 libmpv）。
      JustAudioMediaKit.ensureInitialized(
        linux: defaultTargetPlatform == TargetPlatform.linux,
        windows: defaultTargetPlatform == TargetPlatform.windows,
      );
    } catch (e) {
      debugPrint('[audio] just_audio_media_kit 初始化失败（音频退回插件）：$e');
    }
  }

  final profile = DeviceProfile.detect();

  // 设备型号（官方 DSnote `commit_msg.device` = `Build.MODEL`，第 112 轮）。
  // 拿不到就保持 `'Flutter'`（测试/桌面/通道缺失都不会抛）。
  await NoteStationApi.initNoteDeviceName();

  // 笔记后台同步：登记 entrypoint 并（用户开着的话）排上周期任务（M3，114 轮）
  await registerNoteBackgroundSync();

  // 音频后台 handler（通知栏 / 锁屏 / 耳机按键）—— 渠道 id / 名称见方案 §3.4。
  //
  // R6：该 handler 只接收页面**已解析**的播放 URL 与元数据；它自己**不做**
  // 登录 / 读会话 / QuickConnect（`audio_handler.dart` 顶部有完整说明）。
  final audioHandler = await createBackgroundAudioHandler();

  // ★ DA342：Linux 上"跟随系统"要自己读 GTK/GNOME 的深色偏好（Flutter 嵌入层
  //   不送 `platformBrightness`）。读不到就是 `null`，界面上仍按 system 走。
  bool? systemPrefersDark;
  if (defaultTargetPlatform == TargetPlatform.linux) {
    try {
      systemPrefersDark = await linuxSystemPrefersDark();
      debugPrint('[theme] Linux 系统深色读数：$systemPrefersDark');
    } catch (e) {
      debugPrint('[theme] 读系统主题失败（按未知处理）：$e');
    }
  }

  runApp(
    ProviderScope(
      overrides: [
        deviceProfileProvider.overrideWithValue(profile),
        systemPrefersDarkProvider.overrideWithValue(systemPrefersDark),
        // 真机上才接 local_auth（离线测试默认是"不可用"实现，不会碰平台通道）
        biometricAuthenticatorProvider.overrideWithValue(
          LocalAuthBiometricAuthenticator(),
        ),
        // 媒体会话背后的那个 handler 就是页面用的那个（同一个实例，单一状态源）
        audioHandlerProvider.overrideWithValue(audioHandler),
        // ★ 368：**播放器也只能有一个实例**。handler 自己建了一个（真正在播、
        // 带 audio session / 原生均衡器 / 真频谱的那个），而容器里
        // `audioStationPlayerProvider` 默认还会再懒建一个闲置的 —— 页面若读到
        // 那个，会话 id 恒 null、真频谱回落推导动效、均衡器永远"还没接上"。
        // 这里覆盖成 handler 内的同一个实例。
        audioStationPlayerProvider.overrideWithValue(audioHandler.player),
      ],
      child: const SynologyChatApp(),
    ),
  );

  // ★ r701 · `DA341`：Linux 的托盘项（`org.kde.StatusNotifierItem`）。
  //   起来之后用户最小化/被盖住时能从面板把主窗口叫回来。
  //   **失败绝不许拦住启动**：没有宿主（watcher）/ 没有会话总线都会退化成 null。
  if (defaultTargetPlatform == TargetPlatform.linux) {
    unawaited(
      startLinuxDesktopTray(label: currentText().trayShowMainWindow)
          .then((svc) {
        debugPrint(
          svc == null
              ? '[tray] 没有宿主/总线（本轮没有托盘项）'
              : '[tray] 已注册：${StatusNotifierLinuxService.busName} 菜单 ${svc.menuItems.length} 项',
        );
      }).catchError((Object e) {
        debugPrint('[tray] 起服务失败（忽略）：$e');
        return null;
      }),
    );
  }
}
