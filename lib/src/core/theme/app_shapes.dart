import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 切角位置。
enum CutCorner { topLeft, topRight, bottomRight, bottomLeft }

/// 切角八边形边框 —— HUD 设计语言里"铬部件"的签名形状。
///
/// 用在对角切一刀的标签、徽标、坞、球、状态 chip 上；内容区（气泡、卡片）
/// 仍然用普通圆角，形成"铬 vs 内容"的对比。
class ChamferBorder extends OutlinedBorder {
  const ChamferBorder({
    this.cut = 9,
    this.corners = const {CutCorner.topRight, CutCorner.bottomLeft},
    super.side,
  });

  /// 切角边长
  final double cut;
  final Set<CutCorner> corners;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final c = math.min(cut, rect.shortestSide / 2);
    final l = rect.left, t = rect.top, r = rect.right, b = rect.bottom;
    final path = Path();
    // 从左上角出发，顺时针走一圈；命中切角的角用两点斜边代替直角点。
    if (corners.contains(CutCorner.topLeft)) {
      path.moveTo(l + c, t);
    } else {
      path.moveTo(l, t);
    }
    if (corners.contains(CutCorner.topRight)) {
      path.lineTo(r - c, t);
      path.lineTo(r, t + c);
    } else {
      path.lineTo(r, t);
    }
    if (corners.contains(CutCorner.bottomRight)) {
      path.lineTo(r, b - c);
      path.lineTo(r - c, b);
    } else {
      path.lineTo(r, b);
    }
    if (corners.contains(CutCorner.bottomLeft)) {
      path.lineTo(l + c, b);
      path.lineTo(l, b - c);
    } else {
      path.lineTo(l, b);
    }
    path.close();
    return path;
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect.deflate(side.width), textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    canvas.drawPath(
      getOuterPath(rect, textDirection: textDirection),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side.width
        ..color = side.color,
    );
  }

  @override
  ChamferBorder scale(double t) =>
      ChamferBorder(cut: cut * t, corners: corners, side: side.scale(t));

  @override
  ChamferBorder copyWith({BorderSide? side}) =>
      ChamferBorder(cut: cut, corners: corners, side: side ?? this.side);
}

/// 顶栏"仪表边框"：一条主色渐隐底线 + 均匀刻度。
///
/// 挂在 `AppBarTheme.shape` 上之后，**全 App 的 AppBar 都会自动带上**
/// 这道仪器刻度（不用逐个页面改），是"科幻加权"里性价比最高的一刀。
class HudBarBorder extends ShapeBorder {
  const HudBarBorder({
    this.side = BorderSide.none,
    this.tickColor,
    this.accent,
    this.ticks = 26,
    this.tickHeight = 5,
    this.majorEvery = 5,
  });

  final BorderSide side;
  final Color? tickColor;

  /// 底线中间的强调色（渐隐）
  final Color? accent;
  final int ticks;
  final double tickHeight;
  final int majorEvery;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.only(bottom: side.width);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect.deflate(side.width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) =>
      paintInterior(
        canvas,
        rect,
        Paint()..color = side.color,
        textDirection: textDirection,
      );

  @override
  void paintInterior(
    Canvas canvas,
    Rect rect,
    Paint paint, {
    TextDirection? textDirection,
  }) {
    final y = rect.bottom - side.width / 2;
    // 底线
    canvas.drawLine(
      Offset(rect.left, y),
      Offset(rect.right, y),
      Paint()
        ..color = side.color
        ..strokeWidth = side.width,
    );
    // 中间强调渐变（像仪器的"工作指示"）
    if (accent != null) {
      canvas.drawLine(
        Offset(rect.left, y),
        Offset(rect.right, y),
        Paint()
          ..strokeWidth = side.width * 1.6
          ..shader = LinearGradient(
            colors: [
              accent!.withValues(alpha: 0),
              accent!.withValues(alpha: 0.85),
              accent!.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromLTWH(rect.left, y - 2, rect.width, 4)),
      );
    }
    // 刻度
    final tick = tickColor;
    if (tick != null && ticks > 1) {
      final p = Paint()..color = tick;
      final step = rect.width / (ticks - 1);
      for (var i = 0; i < ticks; i++) {
        final major = majorEvery > 0 && i % majorEvery == 0;
        final h = major ? tickHeight : tickHeight * 0.55;
        canvas.drawRect(
          Rect.fromLTWH(
            rect.left + i * step,
            rect.bottom - side.width - h,
            1,
            h,
          ),
          p,
        );
      }
    }
  }

  @override
  ShapeBorder scale(double t) => HudBarBorder(
    side: side.scale(t),
    tickColor: tickColor,
    accent: accent,
    ticks: ticks,
    tickHeight: tickHeight,
    majorEvery: majorEvery,
  );

  @override
  bool operator ==(Object other) =>
      other is HudBarBorder &&
      other.side == side &&
      other.tickColor == tickColor &&
      other.accent == accent &&
      other.ticks == ticks &&
      other.tickHeight == tickHeight &&
      other.majorEvery == majorEvery;

  @override
  int get hashCode =>
      Object.hash(side, tickColor, accent, ticks, tickHeight, majorEvery);
}
