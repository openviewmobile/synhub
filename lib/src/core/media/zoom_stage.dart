// 可缩放舞台：双指缩放 + 双击放大/复位 + 放大后单指平移。
//
// 为什么不直接用裸 `InteractiveViewer`（真机与单测都踩过）：
//   1. `InteractiveViewer` 内部**始终**注册 `ScaleGestureRecognizer`，单指横向拖动会被它
//      吃掉（flutter#57913）—— 放在 `PageView` 里时表现为"放大后想平移，结果切到了下一张"。
//      这里用 [onZoomChanged] 把"当前是否已放大"告诉外面，由外面把 `PageView` 的
//      `physics` 换成 `NeverScrollableScrollPhysics`，于是放大后单指手势归平移。
//   2. 双击放大要"放大到手指点到的地方"，需要自己按落点算矩阵 + 走动画；官方那种
//      双击只复位（或只居中放大）用起来会跳。
//
// 分工：**缩放归本组件，切页/关闭归外层**（外层拿 [onZoomChanged] 决定要不要放行单指手势）。
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

class ZoomStage extends StatefulWidget {
  const ZoomStage({
    super.key,
    required this.child,
    this.minScale = 1,
    this.maxScale = 6,
    this.doubleTapScale = 2.5,
    this.onZoomChanged,
    this.resetSignal = 0,
    this.viewportSize,
  });

  final Widget child;

  final double minScale;
  final double maxScale;

  /// 双击放大的目标倍数（再双击回到 [minScale]）
  final double doubleTapScale;

  /// 放大状态变化时回调（只在跨过 1.0 这条线时触发，不是每帧）
  final ValueChanged<bool>? onZoomChanged;

  /// 外部要求复位：这个值一变就把缩放清回 [minScale]（翻页时用）
  final int resetSignal;

  /// 视口尺寸（双击锚点用）；不传就取 `MediaQuery.sizeOf(context)`
  final Size? viewportSize;

  @override
  State<ZoomStage> createState() => _ZoomStageState();
}

class _ZoomStageState extends State<ZoomStage>
    with SingleTickerProviderStateMixin {
  final _ctrl = TransformationController();
  late final AnimationController _anim;
  Animation<Matrix4>? _tween;
  Offset? _tapPoint;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onChanged);
    _anim = AnimationController(vsync: this, duration: Motion.base)
      ..addListener(() {
        final v = _tween?.value;
        if (v != null) _ctrl.value = v;
      });
  }

  @override
  void didUpdateWidget(ZoomStage old) {
    super.didUpdateWidget(old);
    if (widget.resetSignal != old.resetSignal && _zoomed) {
      _anim.value = 0;
      _ctrl.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _onChanged() {
    final zoomed = _ctrl.value.getMaxScaleOnAxis() > widget.minScale + 0.01;
    if (zoomed != _zoomed) {
      setState(() => _zoomed = zoomed);
      widget.onZoomChanged?.call(zoomed);
    }
  }

  /// 双击：放大到落点 / 回到原始大小
  void _toggleZoom() {
    final scale = _ctrl.value.getMaxScaleOnAxis();
    if (scale > widget.minScale + 0.01) {
      _animateTo(Matrix4.identity());
      return;
    }
    final target = widget.doubleTapScale;
    final p = _tapPoint ?? Offset.zero;
    final size = widget.viewportSize ?? MediaQuery.sizeOf(context);
    // T·S 作用到落点上等于把这个点钉住；再夹到边界内，免得露出黑边
    final tx = (-p.dx * (target - 1)).clamp(-size.width * (target - 1), 0.0);
    final ty = (-p.dy * (target - 1)).clamp(-size.height * (target - 1), 0.0);
    _animateTo(
      Matrix4.identity()
        ..translateByDouble(tx, ty, 0, 1)
        ..scaleByDouble(target, target, 1, 1),
    );
  }

  void _animateTo(Matrix4 target) {
    _tween = Matrix4Tween(begin: _ctrl.value, end: target).animate(
      CurvedAnimation(parent: _anim, curve: Motion.resolveCurve(Motion.out)),
    );
    _anim.duration = Motion.resolve(Motion.base);
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 双击手势挂在 InteractiveViewer 的 child 上：这样它在手势竞技场里比外层更靠内，
      // 双击不会被缩放识别器吞掉，单指拖动仍归 InteractiveViewer（放大后即平移）
      onDoubleTapDown: (d) => _tapPoint = d.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _ctrl,
        minScale: widget.minScale,
        maxScale: widget.maxScale,
        // 未放大时把单指手势让给外层（`PageView` 翻页 / 下滑关闭）—— 真机踩过：
        // 不让的话左右滑会一直停在同一张。放大后才允许内部平移看细节。
        panEnabled: _zoomed,
        child: widget.child,
      ),
    );
  }
}
