import '../platform/app_platform.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 把 **Dart 侧已经采纳的 TLS 政策**同步给**原生媒体栈**。
///
/// ## 为什么需要这个文件（2026-09-26 真机缺陷）
///
/// 用户报："从文件打开视频无法播放（之前可以播）"、"音频一直无法播放"。
/// 真机 logcat（LGE-AN10，NAS `https://nas.example.com:5001`，证书
/// `CN=nas.example.com`）拿到的是：
///
/// ```
/// E ExoPlayerImplInternal: Caused by: javax.net.ssl.SSLPeerUnverifiedException:
///     Hostname nas.example.com not verified:
///     DN: CN=nas.example.com
///     subjectAltNames: [*.nas.example.com, nas.example.com]
/// W SynologyChatPlayer: 播放失败：ERROR_CODE_IO_NETWORK_CONNECTION_FAILED(2001)
/// ```
///
/// **根因是"两套 TLS 政策不一致"**：
///
/// * Dart 侧（`DioFactory` + `TrustStore`）本来就按设计放行"自签 / 域名不匹配"
///   —— 所以列目录、看缩略图、看文档全都正常；
/// * 原生侧（Android `ExoPlayer`，`just_audio` 在 Android 上也建在同一个
///   `HttpURLConnection` 上）用的是**平台默认信任链 + 严格主机名校验**
///   —— 于是同一个 URL 一点开就挂。
///
/// 视频和音频"不能播"其实是**同一个**原因，只是音频那条路（`just_audio`）
/// 连错误都没露出来。
///
/// ## 政策与边界
///
/// * 只在 **Android** 上生效（宿主/测试环境没有平台通道，直接 no-op）；
/// * 只对**当前会话那一台主机**放宽主机名校验，且**证书链仍由系统 CA 校验**；
/// * 若首连信任库里有这台主机的指纹，则额外按**那一枚证书**钉住
///   （自签证书场景，与 `TrustStore` 同一枚 SHA-256）；
/// * 退出登录 / 断连时用 [clearMediaTlsPolicy] **还原**成平台默认。
///
/// 与 `MediaPlayerBridge.kt` 的 `setTlsPolicy` 一一对应。
abstract final class MediaTlsPolicy {
  /// 与原生播放器同一个通道（`MediaPlayerBridge.CHANNEL`）。
  static const MethodChannel channel = MethodChannel('synhub/player');

  /// 已经下发过的组合（`host|fingerprint`）—— 同一个会话不重复过通道。
  static String? _installedKey;

  /// 只用来让单测能断言"装了什么"。生产不使用。
  static String? get installedKeyForTest => _installedKey;

  /// ★ 第 293 轮：这台主机的 TLS 政策**已经下发过**吗？
  ///
  /// 媒体可用性判定（`media_source.dart` 的 `certPinned` 分支）过去只看
  /// "证书是否被固定"。r259 把原生播放器的 TLS 政策接好之后，该判定仍然把
  /// 所有媒体拦在门外 —— 真机现象就是"File Station 所有音视频都只给
  /// 『下载 / 交给别的 App』"。正确判据是"**播放器能不能信任这台主机**"，
  /// 也就是政策是否已按 `host|fingerprint` 下发。
  static bool isInstalledFor(String baseUrl) {
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    if (host.isEmpty) return false;
    final key = _installedKey;
    if (key == null) return false;
    return key.startsWith('$host|');
  }

  /// 单测里把"是否 Android"这一关打开（宿主上跑不了真平台通道）。
  @visibleForTesting
  static bool debugForceAndroid = false;

  /// ★ 第 296 轮：macOS 上是否启用**自研原生播放器**
  /// （`macos/Runner/MediaPlayerBridge.swift` 的 AVPlayer 桥）。
  ///
  /// 为什么默认 **false**：
  ///   * 自研桥（`synhub/player`）**已实现并随包**，它的
  ///     `AVAssetResourceLoaderDelegate` + `URLSession` 是 macOS 上**唯一**
  ///     能放行"证书链合法但主机名不匹配"（真 NAS `https://nas.example.com:5001`，
  ///     `CN=nas.example.com`）那条流的实现；
  ///   * 但它**还没有在真 NAS 的流上验证过播放** ⇒ 按"没验证就不默认启用"的
  ///     纪律，macOS 默认明确走 `video_player`（该插件声明并注册了 macOS）。
  ///
  /// 打开方式（验证通过后二选一，Dart 侧不需要别的改动）：
  ///   * 构建期：`flutter build macos --dart-define=SYNHUB_MACOS_NATIVE_PLAYER=true`
  ///   * 或把本字段的初值直接写成 `true`。
  /// r87：**默认开**。
  ///
  /// 第 296 轮默认关的理由是"自研桥还没在真 NAS 的流上验证过播放"；
  /// r87 已经用真 NAS 走完整条链路验证（见 `docs/platform-macos.md` §3.7.7）：
  /// 同一条流在平台默认校验下 `-1202`，装好 scoped 政策后 URLSession `206`、
  /// `AVPlayerItem` `readyToPlay` 并出真帧。既然验证通过，就按"可用即默认"
  /// 放行；要退回旧行为仍可构建期 `--dart-define=SYNHUB_MACOS_NATIVE_PLAYER=false`。
  static const bool macosNativePlayerFromEnv = bool.fromEnvironment(
    'SYNHUB_MACOS_NATIVE_PLAYER',
    defaultValue: true,
  );

  /// 运行时开关（生产取 dart-define 的默认；单测可直接改）。
  static bool macosNativePlayerEnabled = macosNativePlayerFromEnv;

  /// ★ 第 92 轮：iOS 上是否启用**同一份**自研 AVPlayer 桥。
  ///
  /// 与 macOS 同源：`macos/Runner/MediaPlayerBridge.swift` +
  /// `macos/Runner/MediaPlayerTransport.swift` 被 iOS target **直接引用同一份源码**
  /// （AVFoundation 两边一致；只有 `registrar` 的 API 形态不同，用
  /// `#if os(macOS)` 收口 ⇒ 不存在"两份实现各自漂移"）。
  ///
  /// 默认 **true**：macOS 侧已在真 NAS 上验证过整条 TLS 链路
  /// （`docs/platform-macos.md` §3.7.7），iOS 侧本轮在模拟器上补齐了
  /// "桥注册 + 纹理出帧 + 事件通道"的验证（见 `docs/platform-ios.md`）。
  /// 要退回旧行为仍可构建期 `--dart-define=SYNHUB_IOS_NATIVE_PLAYER=false`。
  static const bool iosNativePlayerFromEnv = bool.fromEnvironment(
    'SYNHUB_IOS_NATIVE_PLAYER',
    defaultValue: true,
  );

  /// 运行时开关（生产取 dart-define 的默认；单测可直接改）。
  static bool iosNativePlayerEnabled = iosNativePlayerFromEnv;

  /// 自研原生播放器在当前平台**会不会真的被使用**。
  ///
  /// * Android ⇒ 恒 true（既有行为不变）；
  /// * iOS ⇒ 只在 [iosNativePlayerEnabled] 打开时 true；
  /// * macOS ⇒ 只在 [macosNativePlayerEnabled] 打开时 true；
  /// * 其余平台 ⇒ false。
  ///
  /// **只有它为 true 时 [install] 才把 TLS 政策下发给原生栈**：否则政策下不去，
  /// 而 `certPinned` 的媒体闸门（`file_preview_page._certPinned`）
  /// 也不该被误开 —— 那会变成"闸门说能播、播放器根本握不上手"。
  ///
  /// ⚠️ 宿主判据用 **[currentAppHost]（能力层）而不是裸 `dart:io Platform`**：
  /// 这样单测能用 `debugForceAppHost` 把宿主钉成 iOS/Android，去验证
  /// "这个平台上政策会不会下发"；否则在本机（macOS 宿主）上**永远只能测
  /// macOS 那一列**（AGENTS §2.0.11 第 2 条：`Platform.isIOS` 与
  /// `defaultTargetPlatform` 语义不同，判定要写清用哪个）。
  /// `debugForceAndroid`（第 79 轮起的单测开关）语义不变，仍优先放行。
  static bool get nativePlayerEnabled {
    if (kIsWeb) return false;
    if (debugForceAndroid) return true;
    final host = currentAppHost;
    if (host == AppHost.android) return true;
    if (host == AppHost.ios) return iosNativePlayerEnabled;
    if (host == AppHost.macos) return macosNativePlayerEnabled;
    return false;
  }

  /// 组装下发给原生的参数（**纯函数**，可离线单测）。
  ///
  /// 返回 `null` = 这个 baseUrl 里没有主机名，**不下发**（宁可不放宽，
  /// 也不放宽到一个空主机上）。
  @visibleForTesting
  static Map<String, Object?>? payloadFor({
    required String baseUrl,
    String? fingerprintSha256,
  }) {
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    if (host.isEmpty) return null;
    final fp = (fingerprintSha256 == null || fingerprintSha256.isEmpty)
        ? null
        : fingerprintSha256.toUpperCase();
    return <String, Object?>{'host': host, 'fingerprint': fp};
  }

  /// 装上当前会话的 TLS 政策。
  ///
  /// [baseUrl] 是会话的基地址（如 `https://nas.example.com:5001`）；
  /// [fingerprintSha256] 是首连信任库里这台主机的证书指纹（没有就传 null）。
  static Future<void> install({
    required String baseUrl,
    String? fingerprintSha256,
  }) async {
    if (!nativePlayerEnabled) return;
    // 第 79 轮：碰通道前再过一次能力门（`localMediaPlayback` 在 Android/macOS
    // 上 available；Linux/Windows 上 unavailable ⇒ 连通道都不碰）。
    if (!capabilityGateAllows(AppCapability.localMediaPlayback)) return;
    final payload = payloadFor(
      baseUrl: baseUrl,
      fingerprintSha256: fingerprintSha256,
    );
    if (payload == null) return;
    final key = '${payload['host']}|${payload['fingerprint'] ?? ''}';
    if (key == _installedKey) return;
    try {
      await channel.invokeMethod<bool>('setTlsPolicy', payload);
      _installedKey = key;
    } on Object {
      // 通道不在（宿主/测试/老构建）→ 静默跳过：这是**尽力而为**的加固，
      // 不能让"装不上 TLS 政策"反过来打断连接流程。
    }
  }

  /// 还原平台默认（登出 / 断连 / 切服务器）。
  static Future<void> clear() async {
    if (!nativePlayerEnabled) return;
    if (!capabilityGateAllows(AppCapability.localMediaPlayback)) return;
    if (_installedKey == null) return;
    _installedKey = null;
    try {
      await channel.invokeMethod<bool>('setTlsPolicy', <String, Object?>{
        'host': null,
        'fingerprint': null,
      });
    } on Object {
      // 同上：还原失败不阻塞登出
    }
  }

  /// 测试用：清掉"已下发"记忆。
  static void resetForTest() => _installedKey = null;
}
