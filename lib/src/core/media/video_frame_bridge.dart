// 视频首帧抽帧的 **Dart ↔ 原生 薄桥**（第 261 轮）。
//
// 与 `android/.../VideoFrameBridge.kt` 一一对应。设计边界（照任务书）：
//   * **不申请任何新权限**（抽帧不需要权限；尤其**不碰 `RECORD_AUDIO`**）；
//   * **不新建 MethodChannel 插件工程** —— 照 `MediaStoreBridge` / `MediaPlayerBridge`
//     的先例：原生单文件 + `MainActivity.configureFlutterEngine` 里注册；
//   * **网络不在这里做**：Dart 侧先把文件头部若干 MB 下成本地临时文件
//     （见 `lib/src/features/media/video_frame_thumb.dart`），这里只吃**本地路径**。
//
// ## 返回编码（**明确写死**）
// 原生 `Bitmap.compress(Bitmap.CompressFormat.JPEG, 85, …)` ⇒ 返回的是 **JPEG**
// （不是 PNG），`mime == 'image/jpeg'`、`encoding == 'jpeg'`。
// 之所以选 JPEG：列表/网格里一张 320px 缩略图用 PNG 会大好几倍，而抽帧出来的
// 画面本身就是有损来源，PNG 的无损没有意义。
//
// ## 纯 Dart 环境（测试/桌面）
// 没有平台通道 ⇒ [MethodChannelVideoFrameExtractor.extract] 直接返回 null，
// 界面回退占位图标；单测用 `TestDefaultBinaryMessengerBinding` 装一个假通道
// 或直接注入 [VideoFrameExtractor] 的假实现（见 `test/video_frame_thumb_test.dart`）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';

/// 原生通道名（与 `VideoFrameBridge.CHANNEL` 逐字一致）
const String kVideoFrameChannel = 'synhub/video_frame';

/// 原生默认目标宽度（Kotlin 侧 `DEFAULT_MAX_WIDTH`）
const int kVideoFrameDefaultMaxWidth = 320;

/// 一张抽出来的、**已经编码好的**首帧图。
class VideoFrameResult {
  const VideoFrameResult({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
  });

  /// 编码后的图片字节（本实现恒为 JPEG）
  final Uint8List bytes;

  /// MIME（本实现恒为 `image/jpeg`）
  final String mime;

  /// 实际像素宽（原生已按 [kVideoFrameDefaultMaxWidth] 等比缩放）
  final int width;

  /// 实际像素高
  final int height;

  int get length => bytes.length;

  /// 把通道回包的 Map 解成 [VideoFrameResult]；形状不对 → null（**绝不抛**）。
  ///
  /// 单独抽成纯函数是为了让单测能**不依赖 Android 运行时**地钉死：
  /// 空字节 / 缺 `bytes` / 不是 Map / `bytes` 类型不对 一律 null。
  static VideoFrameResult? fromPlatform(Object? raw) {
    if (raw is! Map) return null;
    final bytes = raw['bytes'];
    if (bytes is! Uint8List || bytes.isEmpty) return null;
    final mime = raw['mime'];
    final width = raw['width'];
    final height = raw['height'];
    return VideoFrameResult(
      bytes: bytes,
      mime: (mime is String && mime.isNotEmpty) ? mime : 'image/jpeg',
      width: width is int ? width : 0,
      height: height is int ? height : 0,
    );
  }

  @override
  String toString() =>
      'VideoFrameResult($mime, ${bytes.length}B, ${width}x$height)';
}

/// 抽帧能力（**接口注入**：测试不许依赖 Android 运行时）。
abstract class VideoFrameExtractor {
  /// 从**本地文件** [localPath] 的 [atMs] 处抽一帧，缩到宽度不超过 [maxWidth]。
  ///
  /// 返回 null = 抽不出来（容器解不了 / `moov` 在文件尾而我们只有头部片段 /
  /// 平台通道缺席）。**不抛异常** —— 调用方按 null 回退占位图标。
  Future<VideoFrameResult?> extract(
    String localPath, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
  });

  /// 本机能不能抽帧（非 Android / 通道缺席 → false）。
  Future<bool> isSupported();
}

/// 真机实现：走 `synhub/video_frame` 通道。
class MethodChannelVideoFrameExtractor implements VideoFrameExtractor {
  const MethodChannelVideoFrameExtractor({
    this.channel = const MethodChannel(kVideoFrameChannel),
  });

  final MethodChannel channel;

  /// 单测里把"是否 Android"这一关打开（宿主上跑不了真平台通道）。
  @visibleForTesting
  static bool debugForceAndroid = false;

  /// 第 279 轮：能力判断走平台层（`debugForceAndroid` 仍然生效，
  /// 单测靠它把"宿主的静态结论 = unavailable"这一关打开）。
  ///
  /// ★★ **第 64 轮（r64）真机回归修复**：这里原来写的是
  /// `canUse(AppCapability.videoFrameExtraction)`，而 `canUse` = `capabilities.can`
  /// = **只有 `available` 才为 true**。Android 上这条能力的**静态结论是 `unknown`**
  /// （桥在不在要问了才知道，见 `app_platform.staticCapabilitiesFor`），
  /// 而且 `AppPlatformCapabilities.current()` 是**工厂**（每次重新按宿主算静态表，
  /// 不读任何探测结果）⇒ 真机上 `canUse(...)` **恒为 false**
  /// ⇒ `extract()`/`isSupported()` **连通道都不碰**就返回 null
  /// ⇒ 所有视频行只剩场记板图标、`cache/video_frames/` 永远是空的。
  /// 这正是 `app_platform.dart:601-605` 那段注释警告过的"拿 `can` 替换
  /// `Platform.isAndroid` ⇒ Android 被误判为不能（**回归**）"。
  ///
  /// 正解是 **`capabilityGateAllows`**（= `mayTry`：只有"确定不能"才拦，
  /// `unknown` 与 `available` 都放行）：Android 放行去试桥、
  /// macOS/iOS/Linux/Windows（静态 `unavailable:not-implemented-on-host`）照旧不碰通道。
  ///
  /// ★ 为什么第 279 轮没被守卫抓住：`method_channel_gate_guard_test` 只匹配字面
  /// `invokeMethod(`，而本文件的两次调用都带泛型实参（`invokeMethod<bool>(` /
  /// `invokeMethod<Object?>(`）⇒ **一个都没扫到**（守卫对泛型调用有盲区，已在
  /// `docs/device-verification.md §⑫.8` 记录，本轮不改守卫口径）。
  /// ★ r707：**宿主也要钉**。Windows 的能力位翻成 `available` 之后（走 libmpv
  /// 后端，见 `mpv_video_frame_extractor.dart`），只看能力门会把 Windows 也放进来，
  /// 而那一侧**没有** Kotlin 通道 ⇒ 每次抽帧都 `MissingPluginException`。
  /// 这里只认 Android（或单测的 `debugForceAndroid`）。
  static bool get _isAndroid =>
      debugForceAndroid ||
      (AppPlatformCapabilities.current().host == AppHost.android &&
          capabilityGateAllows(AppCapability.videoFrameExtraction));

  @override
  Future<bool> isSupported() async {
    if (!_isAndroid) return false;
    try {
      return await channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      // 通道缺席 / 老构建没注册这个桥 → 当"不支持"，界面回退图标
      return false;
    }
  }

  @override
  Future<VideoFrameResult?> extract(
    String localPath, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
  }) async {
    if (!_isAndroid) return null;
    if (localPath.isEmpty) return null;
    try {
      final raw = await channel.invokeMethod<Object?>('extractFrame', {
        'path': localPath,
        'atMs': atMs,
        'maxWidth': maxWidth,
      });
      return VideoFrameResult.fromPlatform(raw);
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
