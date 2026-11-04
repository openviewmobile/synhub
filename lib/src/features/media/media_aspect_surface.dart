// 画面比例布局（`MediaAspectMode` 的**渲染侧**实现）。
//
// 为什么单独一个文件：原生侧画面走的是 `TextureRegistry` **纹理**，没有
// Media3 `AspectRatioFrameLayout` 可调（`MediaPlayerBridge.kt` 的 `setAspectMode`
// 只回读状态、不改布局）⇒ 四个档位**全部**由这里决定。从
// `media_player_view.dart` 抽出来是为了能被 widget 用例单独驱动（见
// `test/media_aspect_surface_test.dart`）。
//
// ★ DA88 教训：`FittedBox(fit: cover)` 是**尺度无关**的 —— 把放大倍数写进
// child 的尺寸（`ratio*1000*scale`）会被 cover 的同比例缩小**精确抵消**，
// 于是 `Zoom` 和 `Fill` 出画**逐字节相同**（真机 2026-10-16 量到，见
// `docs/android-ui-audit-r432.md`）。放大必须做在 `FittedBox` **外面**。
import 'package:flutter/widgets.dart';

import 'media_tracks.dart';

/// 画面比例布局：把 `child`（播放器画面）按 [mode] 摆放。
///
/// 语义逐档（与 `media_tracks.dart` 的枚举注释一一对应）：
///   * [MediaAspectMode.fit]     → 整幅放得下，四周留黑边（contain，等比）；
///   * [MediaAspectMode.fill]    → 等比铺满容器，多出来的裁掉（cover）；
///   * [MediaAspectMode.zoom]    → 在 [MediaAspectMode.fill] 基础上再放大
///                                 [kMediaZoomScale] 倍（裁得更狠）；
///   * [MediaAspectMode.stretch] → 拉伸铺满（**会变形**，两个方向倍数不同）。
///
/// [aspectRatio] 不是有限正数时回落 16/9（与界面别处的兜底一致）。
class MediaAspectSurface extends StatelessWidget {
  const MediaAspectSurface({
    super.key,
    required this.mode,
    required this.aspectRatio,
    required this.child,
  });

  final MediaAspectMode mode;
  final double aspectRatio;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ratio = (aspectRatio.isFinite && aspectRatio > 0)
        ? aspectRatio
        : 16 / 9;
    if (mode == MediaAspectMode.fit) {
      return Center(
        child: AspectRatio(aspectRatio: ratio, child: child),
      );
    }
    // 用一个"比例正确的大盒子"当 FittedBox 的 child：contain/cover/fill 才有
    // 稳定的参照物（`Texture` 自己尺寸未知）。
    final box = SizedBox(
      width: ratio * 1000,
      height: 1000,
      child: child,
    );
    final fit = mode == MediaAspectMode.stretch ? BoxFit.fill : BoxFit.cover;
    final covered = SizedBox.expand(
      child: FittedBox(fit: fit, child: box),
    );
    if (mode == MediaAspectMode.zoom) {
      // ★ 放大放在 FittedBox **外面**：写进 child 尺寸会被 cover 抵消（DA88）。
      // `Transform.scale` 默认绕中心缩放，`ClipRect` 保证不画出容器。
      return ClipRect(
        child: Transform.scale(
          scale: kMediaZoomScale,
          child: covered,
        ),
      );
    }
    return ClipRect(child: covered);
  }
}
