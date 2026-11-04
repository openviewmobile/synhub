import 'package:flutter/widgets.dart';

/// ★★★ r131：把 child **撑到视口大小**，再交给 `BoxFit` 去缩放。
///
/// 为什么需要它（macOS 逐屏走查 D20，真机像素 + 机制量双重取证）：
/// `Center(child: Image.memory(bytes, fit: BoxFit.contain))` 里 `Center` 给的是
/// **松约束**，而 `RenderImage` 在松约束下会缩到**图自己的固有尺寸**
/// —— 于是 `BoxFit.contain` 根本没有可缩放的空间：一张 64×32 的小图就按 1:1
/// 画在画布正中间（实测 `p16_photo_viewer.png` 里只占 0.84%），
/// 而同一张图在给了**紧约束**的列表磁贴里却被正常放大（`p10`，527 px）。
///
/// 契约：
/// * 有界约束 ⇒ child 拿到**恰好等于包围盒**的紧约束；
/// * 无界约束（`Stack`/`Row` 里没给尺寸那种）⇒ 退到 `MediaQuery` 的屏尺寸，
///   **不抛** `BoxConstraints forces an infinite width`。
///
/// 回归用例钉的是机制量（布局尺寸 + `scale = min(box/img)`），
/// 见 `test/fit_to_viewport_test.dart`（含"旧写法会 1:1"的反向验证）。
class FitToViewport extends StatelessWidget {
  const FitToViewport({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final mq = MediaQuery.sizeOf(ctx);
        final w = c.maxWidth.isFinite ? c.maxWidth : mq.width;
        final h = c.maxHeight.isFinite ? c.maxHeight : mq.height;
        return SizedBox(width: w, height: h, child: child);
      },
    );
  }
}
