// ★★★ 应用级**平台能力层**（第 279 轮引入）—— "这台机器能不能做 X" 的**唯一**入口。
//
// ## 为什么要有这一层
//
// 这个 App 原来是 Android-only，于是"能力判断"散落在各处的
// `if (Platform.isAndroid)` / `if (!Platform.isAndroid) return false;`
// （第 279 轮普查：`Platform.isAndroid` 18 处、`Platform.isIOS` 5 处、
//  `Platform.isMacOS/Windows/Linux` 4 处，另有 43 处 `MethodChannel(` 调用点）。
// 这样有三个毛病：
//
//   ① **说不清"为什么不行"**：`Platform.isAndroid == false` 到底是"这个平台
//      没有这个能力"还是"这个平台的桥还没写"？调用点答不出来 ⇒ 界面只能
//      静默降级成 `false`，用户看到的是"功能莫名其妙没了"；
//   ② **加一个平台就要改 N 个文件** —— 每加一个 `Platform.isMacOS` 分支，
//      都要重新想一遍"这一处该不该放行"；
//   ③ **能力≠平台**：同一个平台上还要看桥在不在、插件注册没注册
//      （`MethodChannel` 在宿主上会抛 `MissingPluginException`）。
//
// 所以这里把"能力"提成一等公民，并且强制**三态**：
//
// | 状态 | 含义 | 界面该做什么 |
// |---|---|---|
// | [CapabilityState.available] | 问过了/静态就知道**能** | 正常给入口 |
// | [CapabilityState.unavailable] | 问过了/静态就知道**不能**，且带 [CapabilityStatus.reason] | 入口降级并**写明原因**（不静默） |
// | [CapabilityState.unknown] | **还没问完**（探测中） | 显示"探测中"，**不吞掉**功能、也不假装能用 |
//
// ## 铁律（改这一层之前先读）
//
// 1. **只有 `available` 才放行**：`can()` 用 `isAvailable` 判定，
//    `unknown` **不**当 `true`（否则就是在假装能用）；
// 2. **桥缺失不是崩溃，是 `unavailable` + `bridge-missing`**：
//    所有探测都 `try/catch`，宿主上抛 `MissingPluginException` 是**预期路径**；
// 3. **宿主不编事实**：非 Android/iOS 的宿主按静态表给结论，需要手机事实的
//    能力直接回 `unavailable:needs-mobile-host`；与 `device_capability.dart` 的
//    `source: 'host'` 同一口径（AGENTS §2.0.6 第 3 条）；
// 4. **原因码是机器可读的**（`kebab-case` ASCII），人话在 [CapabilityStatus.label]；
//    不要拿中文串当判据（`test/platform_capability_test.dart` 钉住这一点）；
// 5. 单测要能**强制指定宿主**：用 [debugForceAppHost]（与
//    `media_tls_policy.dart` 的 `debugForceAndroid` 同一手法），
//    否则宿主测试永远只能覆盖 macOS 那一列。
import 'dart:async' show TimeoutException;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'desktop_notify_linux.dart';
import 'desktop_notify_windows.dart';
import 'package:flutter/services.dart';

import '../i18n/data_text.dart';

/// 宿主平台（`unknown` = 拿不到，宁可承认不知道也不要猜）。
enum AppHost {
  android,
  ios,
  macos,
  linux,
  windows,
  web,
  unknown;

  /// 手机（有"端侧模型 / FGS / AppWidget"这些概念的两家）。
  bool get isMobile => this == AppHost.android || this == AppHost.ios;

  /// 桌面（有真正的窗口、文件系统、没有"主屏小组件"）。
  bool get isDesktop =>
      this == AppHost.macos || this == AppHost.linux || this == AppHost.windows;

  /// Apple 生态（AVFoundation / Keychain / 沙箱）。
  bool get isApple => this == AppHost.macos || this == AppHost.ios;

  /// 诊断面板 / 日志里用的短标签。
  String get tag => name;
}

/// 本进程实际跑在哪个宿主上。
///
/// `kIsWeb` 优先（web 上 `dart:io` 的 `Platform` 会抛）；
/// 其余平台判断全部包在 `try` 里 —— **拿不到就是 `unknown`**。
AppHost detectAppHost() {
  if (kIsWeb) return AppHost.web;
  try {
    if (Platform.isAndroid) return AppHost.android;
    if (Platform.isIOS) return AppHost.ios;
    if (Platform.isMacOS) return AppHost.macos;
    if (Platform.isLinux) return AppHost.linux;
    if (Platform.isWindows) return AppHost.windows;
  } catch (_) {
    // `dart:io` 在某些嵌入环境下不可用
  }
  return AppHost.unknown;
}

/// 单测里强制宿主（生产不使用）。
@visibleForTesting
AppHost? debugForceAppHost;

/// 当前宿主（考虑 [debugForceAppHost]）。
AppHost get currentAppHost => debugForceAppHost ?? detectAppHost();

/// 这台设备/宿主**可能**具备的能力（本层的枚举就是"能力字典"）。
enum AppCapability {
  /// 本地媒体播放（音频/视频解码播放）。
  localMediaPlayback,

  /// 视频抽帧（缩略图）。
  videoFrameExtraction,

  /// 音频频谱可视化。
  audioVisualizer,

  /// 设备硬件/型号信息（SoC/GPU/NPU/内存…，端侧模型按机器给的依据）。
  deviceHardwareInfo,

  /// 网络流量计数（按 uid 的收发字节数）。
  networkTrafficCounters,

  /// 后台执行 / 保活（前台服务、后台任务）。
  backgroundExecution,

  /// 文档选择器（SAF / NSOpenPanel / 文件对话框）。
  documentPicker,

  /// 投屏（Chromecast / AirPlay 之类）。
  cast,

  /// 主屏小组件。
  homeScreenWidgets,

  /// Office 文档**离屏渲染**（缩略图/只读阅读器不依赖任何原生桥）。
  officeOffscreenRender,

  /// 本地通知。
  localNotifications,

  // ───────────────────────────────────────────────────────────────────────
  // 第 55 轮新增：**只有 Kotlin 一侧实现**的 Android 桥（普查见
  // `docs/platform-macos.md` §5）。宿主上必须由能力层报
  // `unavailable:not-implemented-on-host`，而不是让调用点去撞
  // `MissingPluginException`。这些能力在 Android 上是**静态 `available`**
  // —— Kotlin 桥随包编译进去，不需要探测。
  // ───────────────────────────────────────────────────────────────────────

  /// 深链 / URL scheme 接收（Kotlin `DeepLinkBridge` + Android intent-filter）。
  deepLink,

  /// 系统分享：读 `ACTION_SEND` 进来的内容 / 发出分享文本。
  systemShare,

  /// 主屏快捷方式（`ShortcutManager.requestPinShortcut`）。
  fileShortcut,

  /// Drive 外部目录的 SAF 会话（DocumentsProvider 冷启动自己下）。
  driveSafSession,

  /// 导出到系统「下载」目录（MediaStore）。
  mediaStoreExport,

  /// 系统媒体库（相册 / 视频聚合）。
  localMediaLibrary,

  /// 设备定位（`LocationManager` / FusedLocation）。
  deviceLocation,

  /// 当前网络类型（`ConnectivityManager`）。
  networkInfo,

  /// 系统音效均衡器（`android.media.audiofx.Equalizer`）。
  audioEqualizer,

  /// Drive 后台目录监视（WorkManager）。
  driveWatch,

  /// 笔记提醒（AlarmManager + 通知）。
  noteReminders,

  /// 笔记后台同步（WorkManager）。
  scheduledNoteSync,

  /// 相册后台备份（WorkManager）。
  photoBackup,

  /// 睡眠时段备份（WorkManager + 亮度）。
  sleepBackup,

  /// 国产 ROM 保活引导（Android 独有）。
  oemCompat,

  /// 下载进度系统通知。
  downloadNotifications,

  // ───────────────────────────────────────────────────────────────────────
  // 第 79 轮新增：守卫泛型盲区暴露出的两个**没有对应能力位**的桥。
  // ───────────────────────────────────────────────────────────────────────

  /// 用系统关联程序打开本地文件（Kotlin `synhub/media_open` 的 `viewLocal`）。
  /// 与 [systemShare]（`ACTION_SEND`）不是一回事：这是 `ACTION_VIEW`。
  systemOpen,

  /// 安全凭据保管：Android 走 `synhub/keystore`（Keystore），
  /// macOS 走 `flutter_secure_storage` 的 Keychain（见 `KeystoreSecretKeeper`）。
  secureStorage,

  // ───────────────────────────────────────────────────────────────────────
  // 第 328 轮新增：**只有 Swift macOS 一份实现**的桥（backlog §3.4）。
  // ───────────────────────────────────────────────────────────────────────

  /// 安全作用域书签（`synhub/fsbookmark`）：把"用户选的目录"跨启动记住。
  ///
  /// ★ 只编进 **macOS** 的 target ⇒ 其余宿主**故意不 put**
  /// （`statusOf` 的默认值就是 `unavailable:bridge-missing`，那是如实的）；
  /// 平台矩阵的补全只在 macOS 那一行做。entitlement
  /// `com.apple.security.files.bookmarks.app-scope` 由
  /// `test/fs_bookmark_test.dart` 逐字读两份 entitlements 守卫。
  fsBookmark,
}

/// 能力的三种状态（**只有三种**，不要加"大概能用"这种模糊档）。
enum CapabilityState {
  available,
  unavailable,

  /// **还没探测完** —— 与"不可用"严格区分：界面显示"探测中"而不是灰掉。
  unknown,
}

/// 原因码常量（机器可读；界面文案走 [CapabilityStatus.label]）。
abstract final class CapabilityReason {
  /// 能用。
  static const String ok = 'ok';

  /// 这个宿主**结构上**就没有这个概念（例：Linux 没有主屏小组件）。
  static const String notSupportedOnHost = 'not-supported-on-host';

  /// 这个宿主还没实现（**本轮的 macOS 大多落在这里**）—— 是待办，不是缺陷。
  static const String notImplementedOnHost = 'not-implemented-on-host';

  /// 需要手机宿主的原生事实（SoC/GPU/NPU），桌面按 AGENTS §2.0.6 不编结论。
  static const String needsMobileHost = 'needs-mobile-host';

  /// 这个能力只有原生桥能给答案，而桥**不在**（宿主/未注册/老构建）。
  static const String bridgeMissing = 'bridge-missing';

  /// 探测**还没回来**。
  static const String probePending = 'probe-pending';

  /// 探测超时（桥在但没应答）。
  static const String probeTimeout = 'probe-timeout';

  /// 桥自己报错（`PlatformException`）。
  static const String probeError = 'probe-error';

  /// 桥回了"这台设备上没有"（例：没有 NNAPI / 没有频谱权限）。
  static const String deviceSaysNo = 'device-says-no';
}

/// 一次能力查询的结论。**不可变**、可 `==` 比较（单测直接断言）。
@immutable
class CapabilityStatus {
  const CapabilityStatus(
    this.capability,
    this.state,
    this.reason, {
    this.bridge,
  });

  const CapabilityStatus.available(this.capability, {this.bridge})
    : state = CapabilityState.available,
      reason = CapabilityReason.ok;

  const CapabilityStatus.unavailable(this.capability, this.reason, {this.bridge})
    : state = CapabilityState.unavailable;

  const CapabilityStatus.unknown(
    this.capability, [
    this.reason = CapabilityReason.probePending,
    this.bridge,
  ]) : state = CapabilityState.unknown;

  final AppCapability capability;
  final CapabilityState state;

  /// 机器可读原因码（见 [CapabilityReason]）。
  final String reason;

  /// 这个结论是问哪条通道得到的（静态结论为 null）。
  final String? bridge;

  bool get isAvailable => state == CapabilityState.available;

  bool get isUnavailable => state == CapabilityState.unavailable;

  bool get isUnknown => state == CapabilityState.unknown;

  /// 一句话人话（**英文/ASCII**，给诊断面板用；界面文案另走 ARB）。
  String get label => switch (state) {
    CapabilityState.available => 'AVAILABLE',
    CapabilityState.unavailable => 'UNAVAILABLE',
    CapabilityState.unknown => 'PROBING',
  };

  CapabilityStatus withState(CapabilityState next, String why, {String? bridge}) =>
      CapabilityStatus(capability, next, why, bridge: bridge ?? this.bridge);

  @override
  bool operator ==(Object other) =>
      other is CapabilityStatus &&
      other.capability == capability &&
      other.state == state &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(capability, state, reason);

  @override
  String toString() =>
      '${capability.name}=${state.name}($reason${bridge == null ? '' : ' via $bridge'})';
}

/// 需要**问原生桥**才知道的能力 → 通道 + 方法。
///
/// 只登记"方法存在且回非 null 就算桥在"的探测点；真正的"这台设备有没有"
/// 由原生侧自己判断（`audio_visualizer` 的 `probe` 就额外查了录音权限状态）。
@immutable
class CapabilityBridge {
  const CapabilityBridge(this.channel, this.method);

  final String channel;
  final String method;
}

/// 能力 → 探测点（**没有条目 = 纯静态结论，不用探测**）。
///
/// 与 Kotlin 侧逐条对应（第 279 轮核对过方法名）：
///   * `synhub/video_frame` :: `isSupported`  ← `VideoFrameBridge.kt:157`
///   * `synhub/audio_visualizer` :: `probe`   ← `AudioVisualizerBridge.kt:87`
///   * `synhub/traffic` :: `uidSnapshot`      ← `TrafficStatsBridge.kt:34`
///   * `synhub/cast` :: `availability`        ← `CastBridge.kt:50`
///   * `synhub/background` :: `isServiceRunning` ← `BackgroundBridge.kt:64`
///   * `synhub/device` :: `capability`        ← `DeviceModelBridge.kt`
///   * `synhub/widget` :: `requestRefresh`    ← `SynologyWidgetBridge.kt:62`
///   * `synhub/drive_saf` :: `status`         ← `DriveSafBridge.kt:50`
const Map<AppCapability, CapabilityBridge> kCapabilityBridges = {
  AppCapability.videoFrameExtraction: CapabilityBridge(
    'synhub/video_frame',
    'isSupported',
  ),
  AppCapability.audioVisualizer: CapabilityBridge(
    'synhub/audio_visualizer',
    'probe',
  ),
  AppCapability.networkTrafficCounters: CapabilityBridge(
    'synhub/traffic',
    'uidSnapshot',
  ),
  AppCapability.cast: CapabilityBridge('synhub/cast', 'availability'),
  AppCapability.backgroundExecution: CapabilityBridge(
    'synhub/background',
    'isServiceRunning',
  ),
  AppCapability.deviceHardwareInfo: CapabilityBridge(
    'synhub/device',
    'capability',
  ),
  AppCapability.homeScreenWidgets: CapabilityBridge(
    'synhub/widget',
    'requestRefresh',
  ),
  AppCapability.documentPicker: CapabilityBridge('synhub/drive_saf', 'status'),
  AppCapability.localNotifications: CapabilityBridge(
    'synhub/background',
    'requestNotificationPermission',
  ),
};

/// **只有 Kotlin 一侧实现**的桥能力集合（第 55 轮普查）。
///
/// 这张表存在的理由：Android 的桥是**编译期就随包进去**的（不是"某台设备
/// 可能有、可能没有"），所以 Android 上这些能力是静态 `available`；而
/// iOS/macOS/Linux/Windows 上**结构上没有对应实现** ⇒
/// `unavailable:not-implemented-on-host`。两条都是**静态结论**，不用探测，
/// 因此也不需要登记到 [kCapabilityBridges]。
///
/// 与"某台设备可能没有"的能力（`deviceHardwareInfo` / `videoFrameExtraction`
/// 的硬件差异）严格区分：那些在 Android 上仍是 `unknown`，要问桥。
/// **Android 与 iOS 都有实现**的桥能力（r680 起：只有深链一条）。
///
/// 与 [kAndroidOnlyBridgeCapabilities] 一样是**静态结论**（两侧都是随包编译进去的
/// 原生桥，不需要探测），区别只是宿主集合多了 iOS：
///   * Android：`DeepLinkBridge.kt` ＋ `AndroidManifest.xml` 的 intent-filter
///   * iOS：`ios/Runner/DeepLinkBridge.swift` ＋ `Info.plist` 的 `CFBundleURLTypes`
///     （两条**成对**存在才算数：只写 Swift 不声明 scheme ⇒ 系统不投递；
///      只声明 scheme 不写桥 ⇒ 应用被拉起却没人收）
///
/// macOS / Linux / Windows / web 仍然没有对应实现 ⇒ `unavailable:not-implemented-on-host`。
const Set<AppCapability> kMobileBridgeCapabilities = {
  AppCapability.deepLink,
  // r687：iOS 也有了系统分享面板（`ios/Runner/ShareBridge.swift` 的
  // `UIActivityViewController`）⇒ 从 `kAndroidOnlyBridgeCapabilities` 移过来。
  // 两侧成对的判据：Android `ShareTextBridge.kt`（ACTION_SEND）／
  // iOS `ShareBridge.swift`（`synhub/share_text` ＋ `synhub/media_open`）。
  AppCapability.systemShare,
  // r688：iOS 也有了主屏小组件（WidgetKit 扩展 `ios/Widget/SynHubHomeWidget.swift`
  // ＋ App 侧 `ios/Runner/WidgetBridge.swift` 的 `synhub/widget` 通道）。
  // Android 那一份是 6 个 `AppWidgetProvider`；iOS 是 1 个 WidgetKit 扩展
  // （small/medium/large 三档）。两侧都要 App Group / 落盘快照。
  AppCapability.homeScreenWidgets,
  // r689：iOS 也接上了**视频抽帧**（`ios/Runner/VideoFrameBridge.swift` 的
  // `synhub/video_frame`：`isSupported` + `extractFrame`）。Android 那一份是
  // `MediaMetadataRetriever`，两边都回 JPEG。
  AppCapability.videoFrameExtraction,
  // r689：**网络计数**。两边都有桥，但**能给的粒度不同**：
  //   * Android `TrafficStats`：按 UID 的字节数（`uidRx/uidTx` 可选）；
  //   * iOS `getifaddrs`：只有**接口级**累计 ⇒ 桥如实回 `uidRx/uidTx = -1`
  //     （"读不到" ≠ "没流量"），Dart 侧 `supported == false` ⇒ 估算档不可用。
  AppCapability.networkTrafficCounters,
  // r689：**投屏**。Android = Google Cast（发现设备 → 把 URL 交给接收端）；
  // iOS = **AirPlay**（系统把当前输出路由过去，没有"交 URL"这一步）⇒
  // `availability` 的 `kind` 会告诉调用方是哪一种，UI 据此换文案。
  AppCapability.cast,
  // r689：**真频谱**。Android = `AudioRecord` playback capture（`REMOTE_SUBMIX`）；
  // iOS = **`MTAudioProcessingTap`**（挂在 `AVPlayerItem.audioMix` 上）＋ vDSP FFT。
  // 两边都是"从正在播的那一路输出取 PCM"，事件形状也一致
  // （`List<double>`，长度 = bars，每项 0..1）。
  AppCapability.audioVisualizer,
};

const Set<AppCapability> kAndroidOnlyBridgeCapabilities = {
  AppCapability.fileShortcut,
  AppCapability.driveSafSession,
  AppCapability.mediaStoreExport,
  AppCapability.localMediaLibrary,
  AppCapability.deviceLocation,
  AppCapability.networkInfo,
  AppCapability.audioEqualizer,
  AppCapability.driveWatch,
  AppCapability.noteReminders,
  AppCapability.scheduledNoteSync,
  AppCapability.photoBackup,
  AppCapability.sleepBackup,
  AppCapability.oemCompat,
  AppCapability.downloadNotifications,
  AppCapability.systemOpen,
};

/// 由**平台安全存储插件**（`flutter_secure_storage` 的联邦实现）支撑的能力。
///
/// 目前只有 [AppCapability.secureStorage]。判定依据**只有一条**：该宿主的联邦
/// 插件出现在 `.flutter-plugins-dependencies` 的对应列里（Linux 那还有一份
/// **生成产物**可直接核对：`linux/flutter/generated_plugin_registrant.cc`）。
///
/// | 宿主 | 插件 | 后端 | 依据 |
/// |---|---|---|---|
/// | Android | `synhub/keystore` 通道（Kotlin） | Keystore | 第 279 轮 |
/// | macOS / iOS | `flutter_secure_storage_darwin` | Keychain | `[取证]` 插件列 |
/// | **Linux** | **`flutter_secure_storage_linux` 3.0.3** | **libsecret**（GNOME Keyring / KWallet） | `[取证]` 插件列 + Linux 注册表生成产物 |
/// | **Windows** | **`flutter_secure_storage_windows` 4.2.2** | **DPAPI**（`CryptProtectData` → `flutter_secure_storage.dat`） | `[取证]` 插件列 + Windows 注册表生成产物 + **第 293 轮真机跑通**（见 §6.6/§15） |
///
/// ★ 第 92 轮口径修正：**iOS 原来被漏在这张表外**（当时 Dart 侧
/// `KeystoreSecretKeeper._hostSupports` 只认 Android/macOS），于是
/// iOS 上 `secureStorage` 是 `unavailable` 而 Keychain 其实随手可用
/// ⇒ 端侧 E2EE 私钥会退化成"存不了"。第 92 轮把 iOS 补进来 + 反向验证。
///
/// ★★ 第 108 轮（Linux 站）是**同一个漏的第三次**：
/// `flutter_secure_storage_linux` 早就随包解析进来了
/// （`linux/flutter/generated_plugin_registrant.cc` 里
/// `flutter_secure_storage_linux_plugin_register_with_registrar` 是**生成产物**
/// 里的硬事实），能力层却因为 `_hostSupports` 只认 Android/Apple 而报
/// `unavailable:not-implemented-on-host` ⇒ Linux 上 E2EE 私钥同样"存不了"。
/// 本轮把 Linux 补进来；**反向用例同步收窄到 Windows/web/unknown**
/// （Linux 由"必须拦住"改成"必须放行"，口径变化有上表逐条取证支撑，
/// 不是放宽）。运行时**还需要 libsecret + 一个在跑的 keyring**
/// （gnome-keyring / KWallet / secret-service），见 `docs/platform-linux.md` §3.4。
///
/// ★★★ 第 293 轮（Windows 站）是**同一个漏的第四次**，也是第一次**先把根因钉住、
/// 再修、再在真 Windows 上逐条验收**：真机上插桩到
/// `[p1] _r293Probe seal BLOCKED … isSupported=false capAllowed=false
/// hostSupports=false targetPlatform=windows usesPluginSecureStorage=false`，
/// 而**同一个进程里直连插件**是成功的（`plugin-direct write/read OK`）
/// ⇒ 根因**不是**"插件没就绪"、**不是**"选项不兼容"、**不是**"异常被吞"，
/// 而是**被排除在选择之外**（能力层白名单 + keeper 的宿主集合都漏了 Windows）。
/// 修法 = 上面那张表 Windows 行 + 下面这个循环 + `keystore_secret_keeper.dart`
/// 的 `usesPluginSecureStorageFor()`；**不改 pub-cache 里的插件源码**。
/// 后端是 **DPAPI 文件**（不是 Credential Manager —— 插件 4.2.2 的默认
/// `write` 写 `flutter_secure_storage.dat`，并**主动删除**旧的凭据管理器条目），
/// 所以 `cmdkey /list` **本来就该是 `* NONE *`**，判据要看那个 DPAPI 文件。
const Set<AppCapability> kPlatformSecureStorageCapabilities = {
  AppCapability.secureStorage,
};

/// 静态能力表：**只写"不用探测就能确定"的结论**。
///
/// 凡是"桥在不在 / 插件注册没注册"才知道的，一律 [CapabilityState.unknown]
/// —— 让 [probeAppCapabilities] 去问。这也是为什么 macOS 的
/// `localMediaPlayback` 是 `available`（`just_audio` / `video_player` 都随包
/// 带 AVFoundation 实现，见 `pubspec.lock`），而 `videoFrameExtraction` 是
/// `unavailable:not-implemented-on-host`（抽帧桥只有 Kotlin 那一份）。
AppPlatformCapabilities staticCapabilitiesFor(AppHost host) {
  CapabilityStatus ok(AppCapability c) => CapabilityStatus.available(c);
  CapabilityStatus no(AppCapability c, String why) =>
      CapabilityStatus.unavailable(c, why);
  CapabilityStatus probe(AppCapability c, [String? why]) => why == null
      ? CapabilityStatus.unknown(c)
      : CapabilityStatus.unknown(c, why);

  final out = <AppCapability, CapabilityStatus>{};

  void put(AppCapability c, CapabilityStatus s) => out[c] = s;

  switch (host) {
    case AppHost.android:
      put(AppCapability.localMediaPlayback, ok(AppCapability.localMediaPlayback));
      put(
        AppCapability.officeOffscreenRender,
        ok(AppCapability.officeOffscreenRender),
      );
      // 需要问桥（原生在不在）
      for (final c in const [
        AppCapability.videoFrameExtraction,
        AppCapability.audioVisualizer,
        AppCapability.networkTrafficCounters,
        AppCapability.cast,
        AppCapability.backgroundExecution,
        AppCapability.homeScreenWidgets,
        AppCapability.localNotifications,
        AppCapability.documentPicker,
      ]) {
        put(c, probe(c));
      }
      // 手机事实（桥在才给结论；宿主不编）
      put(
        AppCapability.deviceHardwareInfo,
        probe(AppCapability.deviceHardwareInfo),
      );

    case AppHost.ios:
      // ★ 第 92 轮 iOS 列（每条都带依据，别用"未知"糊过去）：
      //   * 播放 / 离屏渲染 / 文档选择：见下；
      //   * `secureStorage` **不在这里写** —— 由文件末尾的
      //     `kPlatformSecureStorageCapabilities` 循环统一给 `available`
      //     （iOS Keychain，与 macOS 同源）；
      //   * 其余 Kotlin-only 的桥**如实 unavailable**，理由码
      //     `not-implemented-on-host`（= 待办，不是"这个平台没有"）。
      // 播放：`just_audio` / `video_player` / `audio_service` 的 darwin 实现
      // 随包（AVFoundation）；并且 iOS target 已**直接引用 macOS 那一份**
      // 自研 AVPlayer 桥（`#if os(macOS)` 只收口 registrar 形态），
      // 所以"证书链合法但主机名不匹配"的真 NAS 流在 iOS 上也有实现，
      // 不再依赖插件那套严格主机名校验（见 `docs/platform-ios.md`）。
      put(AppCapability.localMediaPlayback, ok(AppCapability.localMediaPlayback));
      put(
        AppCapability.officeOffscreenRender,
        ok(AppCapability.officeOffscreenRender),
      );
      put(
        AppCapability.documentPicker,
        ok(AppCapability.documentPicker),
      ); // file_picker_darwin
      // 通知：**r682 起 iOS 有 Swift 实现**（`BackgroundBridge.swift` 的
      // `UNUserNotificationCenter` 那一段；含直接回复/已读/贪睡动作）⇒ 静态
      // `available`。真实弹框（`requestAuthorization`）在无头模拟器上点不了，
      // 未授权时 `showMessage` **如实返回 false**（见 `docs/platform-ios.md` §20）。
      put(AppCapability.localNotifications, ok(AppCapability.localNotifications));
      // ★ r689：这份"iOS 没有实现"的名单从 4 条缩到 **1 条**。
      //   * `videoFrameExtraction` → `ios/Runner/VideoFrameBridge.swift`
      //     （`AVAssetImageGenerator`，零容差 + `maximumSize` 等比缩）；
      //   * `networkTrafficCounters` → `TrafficBridge`（`getifaddrs`）；
      //     ★ iOS **没有按 App/按 UID 的字节计数 API** ⇒ 桥如实回 uid=-1，
      //       Dart 的 `DeviceTrafficSnapshot.supported` 因此为 false，
      //       "估算档"如实地不可用（**这是平台限制，不是我们的缺口**）；
      //   * `cast` → `CastBridge`（**AirPlay**：`AVRouteDetector` 检测有没有接收端，
      //     `AVRoutePickerView` 摆系统面板；没有"把 URL 交给远端"这一步）；
      //   * `homeScreenWidgets`（r688）→ `ios/Widget/` 的 WidgetKit 扩展。
      // ★★ r689：**"iOS 未实现"的名单已经空了** —— 最后一条
      //   `audioVisualizer` 也接上了：真频谱走 **`MTAudioProcessingTap`**
      //   （`ios/Runner/AudioVisualizerBridge.swift`，tap 在
      //   `MediaPlayerBridge.loadItem` 里随 item 装上）＋ Accelerate/vDSP 做 FFT。
      //   至此 iOS 的能力位与 `docs/platform-ios.md` §19–§29 的落地一一对应；
      //   **"未实现"不再有任何一条**（别的平台是另一张表，不在这个分支里）。
      // 后台执行：**r682 起 iOS 有实现**，但语义与 Android **不同** ——
      //   `startService` = `beginBackgroundTask` 的**后台执行窗口**（约 30 s），
      //   `scheduleRefresh` = `BGAppRefreshTask` 的一次性刷新机会（系统按使用
      //   习惯排，提交成功 ≠ 会跑）。所以这里给 `available`，但 `start()`
      //   的成功**不**等于"常驻保活"—— 调用方要读 `keepAliveStatus()` 的
      //   `kind == 'background-window'`（见 `docs/platform-ios.md` §20）。
      put(
        AppCapability.backgroundExecution,
        ok(AppCapability.backgroundExecution),
      );
      // 手机事实：**r681 起 iOS 有 Swift 实现**（`DeviceCapabilityBridge.swift`，
      // 随包编译 ⇒ 静态 `available`，与 Android 的 Kotlin 桥同档），不再
      // "探测中/未实现"。读数口径见 `docs/platform-ios.md` §19：
      // 内存/核数/GPU 是真事实；`cpuMaxFreqKhz` iOS 不公开 ⇒ 0；
      // 模拟器上的内存是**宿主的**（另有 `isSimulator` 标识）。
      put(
        AppCapability.deviceHardwareInfo,
        ok(AppCapability.deviceHardwareInfo),
      );

    case AppHost.macos:
      // just_audio / video_player 的 darwin 实现随包（AVFoundation）
      put(AppCapability.localMediaPlayback, ok(AppCapability.localMediaPlayback));
      // 离屏渲染是**纯 Dart**（OOXML 解析 + canvas），与宿主无关
      put(
        AppCapability.officeOffscreenRender,
        ok(AppCapability.officeOffscreenRender),
      );
      // file_picker_darwin = NSOpenPanel/NSSavePanel
      put(AppCapability.documentPicker, ok(AppCapability.documentPicker));
      // ★ r328：安全作用域书签桥（`FsBookmarkBridge.swift`，随 macOS target
      //   编译进去 ⇒ 与 Kotlin 桥同口径，静态 `available`，不用探测）。
      put(AppCapability.fsBookmark, ok(AppCapability.fsBookmark));
      // 以下都是 Kotlin-only 的桥，macOS 上**结构上没有**对应实现
      for (final c in const [
        AppCapability.videoFrameExtraction,
        AppCapability.audioVisualizer,
        AppCapability.networkTrafficCounters,
        AppCapability.cast,
        AppCapability.homeScreenWidgets,
      ]) {
        put(c, no(c, CapabilityReason.notImplementedOnHost));
      }
      // macOS 没有"前台服务保活"这套语义（App Nap 会主动降频后台 App）
      put(
        AppCapability.backgroundExecution,
        no(AppCapability.backgroundExecution, CapabilityReason.notSupportedOnHost),
      );
      // 通知：Flutter 侧没有桌面实现接入（`audio_service` 也只有
      // web/android/ios）⇒ **静态**结论，桌面上不必空打一次通道
      // （这一点也让诊断面板在桌面宿主上"零通道调用"，不会留下 pending timer）。
      put(
        AppCapability.localNotifications,
        no(AppCapability.localNotifications, CapabilityReason.notImplementedOnHost),
      );
      // 桌面**不编**手机硬件事实（AGENTS §2.0.6 第 3 条：`source: 'host'`）
      put(
        AppCapability.deviceHardwareInfo,
        no(AppCapability.deviceHardwareInfo, CapabilityReason.needsMobileHost),
      );

    // ★★ 第 108 轮（Linux 站）：Linux **不再和 Windows 合并**。两家在
    //    "插件列"上确实都缺 just_audio/video_player，但 Linux 有**逐条取证**
    //    的结论（`docs/platform-linux.md` §3），所以单独一列写清楚；
    //    `secureStorage` 不在这里写 —— 由文件末尾的
    //    `kPlatformSecureStorageCapabilities` 循环给 `available`
    //    （`flutter_secure_storage_linux` 3.0.3，libsecret 后端）。
    case AppHost.linux:
      // ① 本地播放：★ r690 **已接上** —— 视频走 `MpvPlayerAdapter`（libmpv，
      //    `media_kit_libs_linux` 随包带 Linux 版动态库），音频走
      //    `just_audio_media_kit`（把 just_audio 的后端换成 media_kit）。
      //    在此之前这里是 `not-implemented-on-host`：Linux 插件列里既没有
      //    `just_audio` 也没有 `video_player`，调用必撞 `MissingPluginException`。
      //    判据不再靠"插件列里有谁"，而是"我们有没有给这家平台一份实现"。
      put(AppCapability.localMediaPlayback, ok(AppCapability.localMediaPlayback));
      // ② 离屏渲染是**纯 Dart**（OOXML 解析 + canvas），与宿主无关。
      put(
        AppCapability.officeOffscreenRender,
        ok(AppCapability.officeOffscreenRender),
      );
      // ③ 文档选择：`file_picker_linux` / `file_selector_linux` 都在 Linux
      //    插件列里（生成注册表同名），走 GTK 的 FileChooser ⇒ 真可用。
      put(AppCapability.documentPicker, ok(AppCapability.documentPicker));
      // ④⑤⑥⑦⑧ Kotlin-only 的桥（Linux 上没有任何一份原生实现）：
      //    抽帧 / 频谱 / 流量计数 / 投屏 / 后台保活。
      for (final c in const [
        AppCapability.videoFrameExtraction,
        AppCapability.audioVisualizer,
        AppCapability.networkTrafficCounters,
        AppCapability.cast,
        AppCapability.backgroundExecution,
      ]) {
        put(c, no(c, CapabilityReason.notImplementedOnHost));
      }
      // ⑨ 主屏小组件：Linux 桌面**结构上没有**"主屏"这个概念 ⇒
      //    理由码用 `not-supported-on-host`（与 `not-implemented` 区分开）。
      put(
        AppCapability.homeScreenWidgets,
        no(AppCapability.homeScreenWidgets, CapabilityReason.notSupportedOnHost),
      );
      // ⑩ 手机硬件事实（SoC/NPU/内存门槛）：能力位指的是 `synhub/device` 那条
      //    **手机桥**。Linux 虽然能读 `/proc`，但按 AGENTS §2.0.6 第 3 条
      //    "宿主不编事实"，这里如实报"需要手机宿主"，不拿残缺数据编结论。
      put(
        AppCapability.deviceHardwareInfo,
        no(AppCapability.deviceHardwareInfo, CapabilityReason.needsMobileHost),
      );
      // ⑪ 本地通知：★ r693 **已接上** —— 走 `org.freedesktop.Notifications`
      //    （`desktop_notify_linux.dart`：`notify-send` 发、`dunstctl` 收起；
      //    `flutter_local_notifications` 与 `audio_service` 确实都没有 linux 列，
      //    所以这份实现是我们自己的，不靠插件列）。
      //    判据钉在**客户端在不在 PATH 上**：缺 `notify-send` ⇒ 如实未实现，
      //    不许让"发送测试通知"假装成功。
      put(
        AppCapability.localNotifications,
        linuxDesktopNotifyAvailable()
            ? ok(AppCapability.localNotifications)
            : no(
                AppCapability.localNotifications,
                CapabilityReason.notImplementedOnHost,
              ),
      );

    case AppHost.windows:
      // ★ r703：**本地播放已接上**（不再是"未实现"）。
      //   依据 = ① `pubspec.yaml` 有 `media_kit_libs_windows_video`（构建期把
      //   `mpv-dev-x86_64-*.7z` 摆进 runner，校验 MD5）；
      //   ② `main()` 在 Windows 上也调 `MediaKit.ensureInitialized()` 与
      //   `JustAudioMediaKit.ensureInitialized(windows: true)`；
      //   ③ guest 真机上量到"进度真的在走 / 视频出真帧"（见
      //   `docs/windows-page-coverage.md` §4.5 的读数）。
      //   ⚠️ 只有第 ③ 条成立才允许翻这一位 —— 只改代码不验证 = 假绿。
      put(AppCapability.localMediaPlayback, ok(AppCapability.localMediaPlayback));
      put(
        AppCapability.officeOffscreenRender,
        ok(AppCapability.officeOffscreenRender),
      );
      put(AppCapability.documentPicker, ok(AppCapability.documentPicker));
      // ★ r707：**抽帧已接上** —— 后端是 `MpvVideoFrameExtractor`
      //   （`lib/src/core/media/mpv_video_frame_extractor.dart`）：纯 Dart 调
      //   libmpv 的 `screenshot-raw`，**不建 `VideoController`**、不依赖窗口。
      //   三条依据（缺一不许翻）：
      //   ① 代码：`videoFrameExtractorProvider` 在 `AppHost.windows` 上返回它；
      //   ② guest 实测：`setVideoTrack(VideoTrack.auto())` 之后同一条 mp4
      //      从 `width=nullxnull / 0B` 变成 `1280x720 / 513321B / 采样色数=6872`；
      //   ③ 整条生产流水线（下头片段 → 落盘 → 抽帧 → 缩放）在同一台 guest 上
      //      出 `271_video_frame.png`（见 `docs/evidence-r707-win/` 与
      //      `docs/windows-page-coverage.md` §4.6）。
      put(
        AppCapability.videoFrameExtraction,
        ok(AppCapability.videoFrameExtraction),
      );
      for (final c in const [
        AppCapability.audioVisualizer,
        AppCapability.networkTrafficCounters,
        AppCapability.cast,
        AppCapability.homeScreenWidgets,
        AppCapability.backgroundExecution,
      ]) {
        put(
          c,
          no(
            c,
            c == AppCapability.homeScreenWidgets
                ? CapabilityReason.notSupportedOnHost
                : CapabilityReason.notImplementedOnHost,
          ),
        );
      }
      put(
        AppCapability.deviceHardwareInfo,
        no(AppCapability.deviceHardwareInfo, CapabilityReason.needsMobileHost),
      );
      // ★ r709：**本地通知已接上** —— 后端是 `desktop_notify_windows.dart`
      //   （`powershell.exe` + WinRT `ToastNotificationManager`，不引新依赖）。
      //   判据只认**安装形态**（r708 才具备这个前提）：
      //   ① 打包态（跑在 `C:\Program Files\WindowsApps\<PFN 目录>\`）⇒ 天然有 AUMID
      //      ⇒ 可用；免安装的 dev 版推导不出 AUMID ⇒ **如实报未实现**（不猜）；
      //   ② guest 实测（r709）：同一条 AUMID 发 toast，像素里真出横幅、
      //      操作中心里真有条目（读数见 `docs/platform-windows.md` §23）。
      //   ⚠️ 与 Linux 那条同位：`show()` 返回 true 只代表"调用通了"，
      //   "真弹出来了"只认消费方读数 —— 只改代码不验证 = 假绿。
      put(
        AppCapability.localNotifications,
        windowsToastAumidAvailable()
            ? ok(AppCapability.localNotifications)
            : no(
                AppCapability.localNotifications,
                CapabilityReason.notImplementedOnHost,
              ),
      );

    case AppHost.web:
    case AppHost.unknown:
      for (final c in AppCapability.values) {
        put(
          c,
          no(
            c,
            host == AppHost.web
                ? CapabilityReason.notSupportedOnHost
                : CapabilityReason.bridgeMissing,
          ),
        );
      }
  }

  // 第 55 轮：Android-only 桥能力的**统一结论**（放在 switch 之后，
  // 免得每个 host 分支各写一遍；`out` 里已有结论的不覆盖 —— web/unknown
  // 的全量循环优先）。
  for (final c in kAndroidOnlyBridgeCapabilities) {
    out.putIfAbsent(
      c,
      () => host == AppHost.android
          ? CapabilityStatus.available(c)
          : CapabilityStatus.unavailable(
              c,
              CapabilityReason.notImplementedOnHost,
            ),
    );
  }

  // r680：深链这类的"移动端两侧都有"的桥 —— Android 与 iOS 放行，其余宿主如实报未实现。
  for (final c in kMobileBridgeCapabilities) {
    out.putIfAbsent(
      c,
      () => (host == AppHost.android || host == AppHost.ios)
          ? CapabilityStatus.available(c)
          : CapabilityStatus.unavailable(
              c,
              CapabilityReason.notImplementedOnHost,
            ),
    );
  }

  // Android + macOS + iOS + Linux + Windows 都有实现的安全存储插件（五家的
  // 插件列 / 生成产物都能核，见集合定义与 `test/secret_keeper_host_matrix_test.dart`）。
  // web / unknown 仍如实 `unavailable`（它们在 switch 里已整表写成 unavailable）。
  for (final c in kPlatformSecureStorageCapabilities) {
    out.putIfAbsent(
      c,
      () => (host == AppHost.android ||
              host == AppHost.macos ||
              host == AppHost.ios ||
              host == AppHost.linux ||
              host == AppHost.windows)
          ? CapabilityStatus.available(c)
          : CapabilityStatus.unavailable(
              c,
              CapabilityReason.notImplementedOnHost,
            ),
    );
  }

  return AppPlatformCapabilities(host, out);
}

/// 某一台宿主的**完整能力表**（每个 [AppCapability] 都有一条结论，不会有缺项）。
@immutable
class AppPlatformCapabilities {
  const AppPlatformCapabilities(this.host, this._byCapability);

  factory AppPlatformCapabilities.forHost(AppHost host) =>
      staticCapabilitiesFor(host);

  /// 当前宿主。
  factory AppPlatformCapabilities.current() =>
      staticCapabilitiesFor(currentAppHost);

  final AppHost host;
  final Map<AppCapability, CapabilityStatus> _byCapability;

  CapabilityStatus statusOf(AppCapability capability) =>
      _byCapability[capability] ??
      CapabilityStatus.unavailable(capability, CapabilityReason.bridgeMissing);

  /// ★ **只有 `available` 才为 true**（`unknown` 不算能用，见文件头铁律 1）。
  ///
  /// 用途：**放行界面入口**。`unknown`（还在探测）时不要用它 ——
  /// 那会把"还没问完"当成"不能"，正是 §2.0.6 第 2 条要避免的冷启动降级。
  bool can(AppCapability capability) => statusOf(capability).isAvailable;

  /// 「可以试一试」：**不是静态确定的不能**。
  ///
  /// 与 [can] 的分工：
  ///   * [can] = "已经确定能用"（界面放行）；
  ///   * [mayTry] = "排除掉确定不能的"（交给原生桥试一下的调用点用）。
  ///
  /// 为什么必须有这个区分：Android 上**每一条桥能力**的静态结论都是
  /// `unknown`（桥在不在要问了才知道）。旧的 `Platform.isAndroid` 判断做的事
  /// 就是"先放过去试"，语义上等于 [mayTry]。若拿 [can] 去替换，
  /// Android 会被**误判为不能**（回归）。macOS/Linux/Windows 上这些能力是
  /// `unavailable` ⇒ [mayTry] 为 false ⇒ 连通道都不碰，直接给明确原因。
  bool mayTry(AppCapability capability) => !statusOf(capability).isUnavailable;

  bool isUnknown(AppCapability capability) => statusOf(capability).isUnknown;

  /// 人话原因（机器可读；界面文案另走 ARB）。
  String reasonOf(AppCapability capability) => statusOf(capability).reason;

  /// 覆盖某条结论（探测回来后合并用）。
  AppPlatformCapabilities withStatus(CapabilityStatus status) =>
      AppPlatformCapabilities(host, {
        ..._byCapability,
        status.capability: status,
      });

  Map<AppCapability, CapabilityStatus> get entries =>
      Map.unmodifiable(_byCapability);

  /// 诊断面板用：一行一条 `files=available(ok)`。
  List<String> get diagLines => [
    for (final c in AppCapability.values)
      '${c.name}=${statusOf(c).state.name}(${statusOf(c).reason})',
  ];

  @override
  String toString() =>
      'AppPlatformCapabilities(${host.name}: ${diagLines.join(', ')})';
}

/// 一次探测的签名（测试注入假桥）。
typedef CapabilityProbeFn = Future<Object?> Function(String channel, String method);

/// 用真实平台通道探测。
///
/// gate-exempt: capability-prober —— 这里**就是**能力层自己的探测入口，
/// 必须先打一次通道才知道桥在不在；给它加能力门等于用结论证明结论。
Future<Object?> _platformProbe(String channel, String method) =>
    MethodChannel(channel).invokeMethod<Object?>(method);

/// 探测结果 → 结论（**纯函数**，把"异常类型"映射成原因码）。
///
/// 宿主上 `MissingPluginException` 是**预期路径**，映射成
/// `unavailable:bridge-missing` —— 这正是"桥缺失不许崩"的落点。
CapabilityStatus classifyProbeResult(
  AppCapability capability, {
  required String channel,
  Object? value,
  Object? error,
}) {
  if (error != null) {
    if (error is TimeoutException) {
      // ★ **超时是"没问出来"，不是"问了说不能"** —— 必须留在 `unknown`
      //   （AGENTS §2.0.17：中间态与失败态要分得清）。
      return CapabilityStatus.unknown(
        capability,
        CapabilityReason.probeTimeout,
        channel,
      );
    }
    if (error is MissingPluginException) {
      return CapabilityStatus.unavailable(
        capability,
        CapabilityReason.bridgeMissing,
        bridge: channel,
      );
    }
    if (error is PlatformException) {
      return CapabilityStatus.unavailable(
        capability,
        CapabilityReason.probeError,
        bridge: channel,
      );
    }
    return CapabilityStatus.unavailable(
      capability,
      CapabilityReason.probeError,
      bridge: channel,
    );
  }
  // 桥应答了：
  //   * 显式 `false` / `{available:false}` / `{ok:false}` → "设备说没有"
  //   * `null` → 方法存在但没回值 ⇒ 通道是通的，算可用（例：`requestRefresh`）
  //   * 其余非 null → 可用
  final available = switch (value) {
    null => true,
    false => false,
    true => true,
    Map m when m.containsKey('available') => m['available'] == true,
    Map m when m.containsKey('ok') => m['ok'] == true,
    _ => true,
  };
  return available
      ? CapabilityStatus.available(capability, bridge: channel)
      : CapabilityStatus.unavailable(
          capability,
          CapabilityReason.deviceSaysNo,
          bridge: channel,
        );
}

/// 把所有**需要探测**的能力问一遍，返回合并后的完整表。
///
/// * 静态就确定的能力**不探测**（不浪费一次通道往返）；
/// * 每条探测独立 `try/catch`：一条炸了不影响其它条；
/// * [timeout] 内没回应 → `unknown:probe-timeout`（**不是** unavailable）。
Future<AppPlatformCapabilities> probeAppCapabilities({
  AppPlatformCapabilities? base,
  CapabilityProbeFn? probe,
  Duration? timeout = const Duration(seconds: 3),
}) async {
  final start = base ?? AppPlatformCapabilities.current();
  var result = start;
  final fn = probe ?? _platformProbe;

  for (final capability in AppCapability.values) {
    final current = start.statusOf(capability);
    if (!current.isUnknown) continue;
    final bridge = kCapabilityBridges[capability];
    if (bridge == null) {
      // 标了 unknown 却没登记探测点 ⇒ 配置错误，如实说"桥缺失"
      result = result.withStatus(
        CapabilityStatus.unavailable(capability, CapabilityReason.bridgeMissing),
      );
      continue;
    }
    Object? value;
    Object? error;
    try {
      final pending = fn(bridge.channel, bridge.method);
      value = timeout == null ? await pending : await pending.timeout(timeout);
    } on Object catch (e) {
      error = e;
    }
    result = result.withStatus(
      classifyProbeResult(
        capability,
        channel: bridge.channel,
        value: value,
        error: error,
      ),
    );
  }
  return result;
}

/// 某个能力能否用（便利读法；默认查当前宿主）。
bool canUse(AppCapability capability) =>
    AppPlatformCapabilities.current().can(capability);

/// 单测里强制"能力门放行"（**生产不使用**）。
///
/// 为什么需要：宿主测试跑在 macOS 上，而这些桥的真实实现只在 Android。
/// 用例要验证"桥被调用时发什么载荷"（也叫**反向验证**：证明这道门不是
/// 恒假），就必须先把门打开 —— 与 `video_frame_bridge.dart` 的
/// `debugForceAndroid` 是同一手法。
@visibleForTesting
bool debugForceCapabilityGate = false;

/// **能力门的统一入口**：Android-only 桥的每个调用点在碰通道之前先问它。
///
/// 语义 = [AppPlatformCapabilities.mayTry]：**只有"确定不能"（`unavailable`）
/// 才拦下**；`unknown`（Android 上还没探测）与 `available` 都放行 —— 这正是
/// `Platform.isAndroid` 的等价替换，所以 Android 行为一字不变。
///
/// 被拦下时调用点**不许抛 `MissingPluginException`**，要降级成"没有这项能力"
/// 的正常分支，并用 [capabilityGateReason] 把机器可读原因带出去（界面据此说明）。
bool capabilityGateAllows(AppCapability capability) =>
    debugForceCapabilityGate ||
    AppPlatformCapabilities.current().mayTry(capability);

/// 被能力门拦下时的**机器可读原因码**（`not-implemented-on-host` 等）。
///
/// 界面文案走 [capabilityReasonText] / ARB，**不要**拿这个码当人话。
String capabilityGateReason(AppCapability capability) =>
    AppPlatformCapabilities.current().reasonOf(capability);

/// 能力门拦下时的**一句话诊断**（进日志；`grep capability-gate` 一次捞全）。
String capabilityGateLog(AppCapability capability, String what) =>
    'capability-gate blocked $what: ${capability.name} '
    '= ${capabilityGateReason(capability)}';

// ---------------------------------------------------------------------------
// 按能力组织的**接口**（"能力适配器"）
//
// 目的：让功能依赖"这个能力有没有、给我一个实现"，而不是依赖"平台是不是安卓"。
// 每个能力有一个默认的"不支持"实现（[UnavailableAdapter]），所以**永远有东西可用**，
// 不会因为某个平台没写桥就 NullPointer。
// ---------------------------------------------------------------------------

/// 能力适配器的公共形状：先报状态，再给实现。
abstract interface class CapabilityAdapter {
  AppCapability get capability;

  CapabilityStatus status();
}

/// "做不到"的适配器：状态如实，动作抛 `UnsupportedError`（**不会被静默忽略**）。
///
/// 约定：调用方必须先看 [status]，别直接调动作；直接调是编程错误，
/// 应当**响**而不是静默 no-op（静默 no-op 就是"假装能用"）。
class UnavailableAdapter implements CapabilityAdapter {
  const UnavailableAdapter(this.capability, this._status);

  factory UnavailableAdapter.from(AppPlatformCapabilities caps, AppCapability c) =>
      UnavailableAdapter(c, caps.statusOf(c));

  @override
  final AppCapability capability;

  final CapabilityStatus _status;

  @override
  CapabilityStatus status() => _status;

  Never _refuse(String action) => throw UnsupportedError(
    'capability ${capability.name} is ${_status.state.name}'
    '(${_status.reason}); $action is not available on this host',
  );

  /// 任何"动作"都从这里过，保证原因码被带出来。
  Never refuse(String action) => _refuse(action);
}

/// 硬件/型号信息（端侧模型按机器给的依据）。
abstract interface class DeviceHardwareInfoAdapter implements CapabilityAdapter {
  @override
  AppCapability get capability => AppCapability.deviceHardwareInfo;

  /// 采集一次只读事实；不可用时返回 null（调用方按"不知道"处理）。
  Future<Map<String, Object?>?> read();
}

/// 网络流量计数。
abstract interface class TrafficCountersAdapter implements CapabilityAdapter {
  @override
  AppCapability get capability => AppCapability.networkTrafficCounters;

  Future<Map<String, Object?>?> snapshot();
}

/// 后台执行 / 保活。
abstract interface class BackgroundExecutionAdapter implements CapabilityAdapter {
  @override
  AppCapability get capability => AppCapability.backgroundExecution;

  Future<bool> isRunning();

  Future<bool> start();
}

/// 投屏。
abstract interface class CastAdapter implements CapabilityAdapter {
  @override
  AppCapability get capability => AppCapability.cast;

  Future<bool> availability();
}

/// 主屏小组件。
abstract interface class HomeWidgetAdapter implements CapabilityAdapter {
  @override
  AppCapability get capability => AppCapability.homeScreenWidgets;

  Future<void> requestRefresh();
}

/// 文档选择器（SAF / NSOpenPanel 的同一抽象）。
abstract interface class DocumentPickerAdapter implements CapabilityAdapter {
  @override
  AppCapability get capability => AppCapability.documentPicker;

  /// 让用户选一个目录；返回 null = 用户取消或本平台没有目录选择。
  Future<String?> pickDirectory();
}

/// 按能力取一个适配器；没有实现的平台回 [UnavailableAdapter]（不是 null）。
CapabilityAdapter adapterFor(
  AppPlatformCapabilities caps,
  AppCapability capability,
) => UnavailableAdapter.from(caps, capability);

/// 数据层可用的原因文案 key（i18n 三步：ARB + dataTextMap，见 AGENTS §2.0.13）。
///
/// `dataText` 查不到就回落中文原文 —— 这里只给**数据层**用的中文回落；
/// 界面请用 `context.t` 的对应 getter。
String capabilityReasonText(String reason) => switch (reason) {
  CapabilityReason.ok => dataText('capReasonOk', '可用'),
  CapabilityReason.notSupportedOnHost =>
    dataText('capReasonNotSupported', '此平台不支持'),
  CapabilityReason.notImplementedOnHost =>
    dataText('capReasonNotImplemented', '此平台尚未实现'),
  CapabilityReason.needsMobileHost => dataText('capReasonNeedsMobile', '需要手机设备'),
  CapabilityReason.bridgeMissing => dataText('capReasonBridgeMissing', '原生模块缺失'),
  CapabilityReason.probePending => dataText('capReasonProbing', '正在探测'),
  CapabilityReason.probeTimeout => dataText('capReasonTimeout', '探测超时'),
  CapabilityReason.probeError => dataText('capReasonProbeError', '探测失败'),
  CapabilityReason.deviceSaysNo => dataText('capReasonDeviceNo', '本机不支持'),
  _ => dataText('capReasonUnknown', '原因未知'),
};
