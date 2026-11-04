// 视频缩略图「取不到」的**统一、能说出原因**的占位（第 267 轮）。
//
// ## 为什么要有它
// 第 261/263 轮把"抽帧"接上了，但两条渲染路各画一份占位：
//   * `features/files/file_thumb.dart` 的视频分支 ⇒ 画**调用方的 fallback**
//     （一个"场记板"图标），**一条 Dart 日志都没有**；
//   * `features/photos/photo_widgets.dart` ⇒ 画 `videocam_off_outlined`。
// 结果就是用户看到的「这个视频没有缩略图，而且没有任何解释」。
//
// 第 267 轮查清了那条 AVI 为什么取不到（**平台没有 RIFF/AVI 解析器**，见
// `docs/device-verification.md §⑩.7`），于是这里的口径是：
//   1. 仍然是一个**视频格子**（影片图标 + 播放角标）—— 不能看着像"损坏文件"；
//   2. `Semantics(label:)` 说**具体原因**（容器名 + 编码 fourcc，如
//      `格式不支持 · AVI/RIFF · FMP4`）；
//   3. **不用 `Tooltip`**：`Tooltip` 默认长按触发，会把相册网格的"长按进多选"
//      吞掉（第 261 轮实测，见 `photo_widgets.dart` 的同类注释）。
//
// ⚠️ 文案**不许**写"编码不支持"：`FMP4` 本机有解码器（`c2.android.mpeg4.decoder`），
// 卡住的是容器解析。见 `video_thumb_failure_text.dart` 的文件头。
library;

import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import 'video_frame_thumb.dart';
import 'video_thumb_failure_text.dart';

/// 视频缩略图占位（带原因）。可以当 `fallback` 直接丢进列表/网格。
class VideoThumbUnavailable extends StatelessWidget {
  const VideoThumbUnavailable({
    super.key,
    required this.failure,
    this.size,
    this.iconSize = 20,
    this.radius,
    this.showReason = false,
    this.background,
    this.playBadge = true,
  });

  /// 失败原因；null = 没有（例如"服务端不提供视频缩略图"这种已知常态）
  final VideoFrameThumbFailure? failure;

  /// 需要显式撑满时的边长（放进 `SizedBox` 的场合）
  final double? size;

  final double iconSize;
  final double? radius;

  /// true = 除了图标，**还画一行短标签**（列表行有空间时用；格子太小别开）
  final bool showReason;

  final Color? background;

  /// 要不要右下角的播放角标（视频身份必须保留）
  final bool playBadge;

  @override
  Widget build(BuildContext context) {
    final text = videoThumbFailureText(context.t, failure);
    Widget content = ColoredBox(
      color: background ?? DesignPalette.of(context).bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 与第 261 轮起的既有外观**逐字一致**（`videocam_off_outlined`）：
                // 老用例（`test/photo_video_thumb_test.dart` ③/⑦）钉的就是它，
                // 这里只是**多说了原因**，不去改用户已经认识的那个图标。
                Icon(
                  Icons.videocam_off_outlined,
                  color: DesignPalette.of(context).dim,
                  size: iconSize,
                ),
                if (showReason) ...[
                  const SizedBox(height: 4),
                  Text(
                    text.label,
                    key: const Key('video-thumb-unavailable-label'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: DesignPalette.of(context).dim, fontSize: 10),
                  ),
                ],
              ],
            ),
          ),
          if (playBadge)
            Positioned(
              right: 6,
              bottom: 6,
              child: Icon(
                Icons.play_circle_fill,
                size: iconSize,
                color: Colors.white70,
              ),
            ),
        ],
      ),
    );
    // 读屏读到的是**带事实的那句**（如「格式不支持 · AVI/RIFF · FMP4」）。
    content = Semantics(
      label: text.detail,
      image: true,
      child: content,
    );
    if (size != null) {
      content = SizedBox(width: size, height: size, child: content);
    }
    if (radius != null) {
      content = ClipRRect(borderRadius: BorderRadius.circular(radius!), child: content);
    }
    return content;
  }
}
