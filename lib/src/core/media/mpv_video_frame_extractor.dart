// Windows / Linux 桌面的**抽帧后端**：走 `media_kit`（libmpv）的
// `screenshot-raw`，不写任何一行原生代码。
//
// ── 为什么这条路成立（三条事实，逐条可核） ───────────────────────────
// ① `media_kit` 1.2.6 的 `Player.screenshot(format:)` 是**纯 Dart 调 mpv 命令**
//    （`lib/src/player/native/player/real.dart` 里 `_screenshot` → `screenshot-raw`），
//    **不需要 `VideoController`**（不建纹理、不开窗口）⇒ 桌面能"离线抽一帧"。
// ② 桌面这两家的 libmpv 是**随包带**的：Linux `media_kit_libs_linux`、
//    Windows `media_kit_libs_windows_video`（r703 加的那条，构建期把
//    `mpv-dev-x86_64-*.7z` 摆进 runner）⇒ 与 Android 的
//    `MediaMetadataRetriever` 等价的一份后端。
// ③ 校验口径与 Android 侧**同一套**：成功给 `VideoFrameResult(bytes, mime, w, h)`，
//    失败给 `null`（**绝不抛**），调用方照旧回退场记板图标。
//
// ── 与 Android 后端的差异（如实写清） ───────────────────────────────
// * Android 吃的是"本地路径 + 毫秒偏移"，由 `MediaMetadataRetriever` 直接出 JPEG；
//   这里由 libmpv 解码后出 JPEG，**缩放**用 Flutter 引擎自己画（`dart:ui`），
//   因为 mpv 的 `screenshot-raw` 不给缩放参数。
// * 缩放后统一回 **PNG**（`ui.Image.toByteData` 只有 PNG 编码器；不引第三方
//   图片库）。`VideoFrameResult.mime` 本来就带 mime，消费侧按字段走。
// * libmpv 要"真有帧"：先 `open`（不播）→ `seek` → 等一帧到位再截。视频头片段
//   （6 MiB）里 `moov` 在尾部的容器解不出来 ⇒ 回 `null`，与 Android 同款回退。
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'video_frame_bridge.dart';

/// 一次"取原始截图"的抽象（单测注入它，就不必真起 libmpv）。
typedef MpvScreenshot = Future<Uint8List?> Function(
  String localPath, {
  required int atMs,
});

/// 用 libmpv 抽帧（桌面后端）。
class MpvVideoFrameExtractor implements VideoFrameExtractor {
  const MpvVideoFrameExtractor({
    this.maxWidth = kVideoFrameDefaultMaxWidth,
    this.openTimeout = const Duration(seconds: 8),
    this.frameTimeout = const Duration(seconds: 4),
    this.screenshot,
  });

  /// 出图宽度上限（超过就等比缩）。
  final int maxWidth;
  final Duration openTimeout;
  final Duration frameTimeout;

  /// 单测注入点；为 null 时真起 `media_kit` 的 `Player`。
  final MpvScreenshot? screenshot;

  /// 桌面后端在**本宿主**上有没有（不碰文件、不碰网络）。
  ///
  /// 判据只有一条：这两家的 libmpv 是随包带的，Android/iOS 走各自的原生后端。
  static bool hostSupported() {
    if (kIsWeb) return false;
    final p = defaultTargetPlatform;
    return p == TargetPlatform.windows || p == TargetPlatform.linux;
  }

  @override
  Future<bool> isSupported() async => hostSupported();

  @override
  Future<VideoFrameResult?> extract(
    String localPath, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
  }) async {
    final limit = maxWidth <= 0 ? kVideoFrameDefaultMaxWidth : maxWidth;
    try {
      final raw = await (screenshot ?? _screenshotViaMpv)(
        localPath,
        atMs: atMs < 0 ? 0 : atMs,
      );
      if (raw == null || raw.isEmpty) return null;
      return await _finish(raw, limit);
    } on Object catch (e) {
      // 与 Android 后端同款：抽不出来就 null，绝不把异常甩给 UI
      debugPrint('[videoFrame] mpv extract failed path=$localPath err=$e');
      return null;
    }
  }

  /// 真起 libmpv：`open` → **`setVideoTrack(auto)`** → 等首帧 → `seek` → `screenshot`。
  ///
  /// ★★★ **`setVideoTrack(VideoTrack.auto())` 这一步不是可选项**（r707 实测）：
  /// media_kit 在 `_create()` 里写死 `--vid=no`（"省得白解码"），只有
  /// `VideoController` attach 时才改 `--vid=auto`。没有它时读数长这样：
  /// `dur=15665ms playing=true video=3 audio=3 width=nullxnull errors=[]`
  /// —— 轨道表里有 3 条视频轨、文件在播、**一个视频帧都不解**，
  /// `screenshot()` 恒 0 字节（`vo=null` / `vo=libmpv` / `vo=gpu` 三种都一样）。
  /// 加上这一行之后同一条文件立刻变成 `width=1280x720 jpeg=513321B 采样色数=6872`。
  ///
  /// 另一条实测：**建 `VideoController` 会在没有 widget 的宿主里挂住**
  /// （pw10 把整轮 walk 卡了 15 min，只能 taskkill）⇒ 桌面抽帧**不许**走那条路。
  Future<Uint8List?> _screenshotViaMpv(
    String localPath, {
    required int atMs,
  }) async {
    final player = Player(
      configuration: const PlayerConfiguration(muted: true),
    );
    try {
      await player.open(Media(localPath), play: true).timeout(openTimeout);
      // ★ 唯一能让"没有 widget 也能解码"的开关，见方法头注释
      await player.setVideoTrack(VideoTrack.auto());
      // 等 `width` 事件（libmpv 已经解到一帧）；等不到也照截一次
      final gotFrame = Completer<void>();
      final sub = player.stream.width.listen((w) {
        if (w != null && w > 0 && !gotFrame.isCompleted) gotFrame.complete();
      });
      try {
        await gotFrame.future.timeout(frameTimeout);
      } on TimeoutException {
        // 不影响后面的截图尝试
      } finally {
        await sub.cancel();
      }
      await player.pause();
      if (atMs > 0) {
        await player.seek(Duration(milliseconds: atMs));
        // seek 之后那一帧要落地才有得截
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      final shot = await player.screenshot(format: 'image/jpeg');
      if (shot != null && shot.isNotEmpty) return shot;
      // 少数容器首帧慢半拍：再等一次（不是重试循环，只多给 400 ms）
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return await player.screenshot(format: 'image/jpeg');
    } finally {
      // 释放顺序：先 dispose 播放器，避免后台线程还抓着文件
      unawaited(player.dispose());
    }
  }

  /// 解码 → 视需要等比缩到 [limit] 宽 → 回 [VideoFrameResult]。
  Future<VideoFrameResult?> _finish(Uint8List raw, int limit) async {
    final codec = await ui.instantiateImageCodec(raw);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final w = image.width;
      final h = image.height;
      if (w <= 0 || h <= 0) return null;
      if (w <= limit) {
        return VideoFrameResult(
          bytes: raw,
          // 猜一次容器类型就够：libmpv 的 `image/jpeg` 是硬事实
          mime: _looksPng(raw) ? 'image/png' : 'image/jpeg',
          width: w,
          height: h,
        );
      }
      final targetW = limit;
      final targetH = (h * limit / w).round().clamp(1, 100000);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final dst = ui.Rect.fromLTWH(
        0,
        0,
        targetW.toDouble(),
        targetH.toDouble(),
      );
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        dst,
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      final scaled = await recorder.endRecording().toImage(targetW, targetH);
      try {
        final data = await scaled.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return null;
        return VideoFrameResult(
          bytes: data.buffer.asUint8List(),
          mime: 'image/png',
          width: targetW,
          height: targetH,
        );
      } finally {
        scaled.dispose();
      }
    } finally {
      image.dispose();
      codec.dispose();
    }
  }

  static bool _looksPng(Uint8List b) =>
      b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
}
