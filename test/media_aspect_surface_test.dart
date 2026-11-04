// 画面比例布局（`media_aspect_surface.dart`）的 widget 用例。
//
// 为什么要有这一份：`test/media_tracks_test.dart` 只钉了「`kMediaZoomScale > 1.0`」
// 这个**常量**，钉不住「倍数有没有被用上」。真机于是把 `Zoom (crop more)`
// 做成了和 `Fill (crop)` **逐字节相同**的两个档位 —— 即 `DA88`：
// `_AspectSurface` 把放大写进了 `FittedBox` 的 child 尺寸，而 `BoxFit.cover`
// 是**尺度无关**的，倍数被精确抵消。
//
// 判据（**行为级**，不是常量级）：
//   ① `zoom` 必须比 `fill` 多一层 `Transform.scale(kMediaZoomScale)`，且被 `ClipRect` 包住；
//   ② 那个 Transform 的**实际缩放**等于 `kMediaZoomScale`（读矩阵，不读常量）；
//   ③ `fill`/`stretch` **不许**有这层放大（反向：否则 `fill` 会被误放大）；
//   ④ `stretch` 用 `BoxFit.fill`（会变形），`fill`/`zoom` 用 `BoxFit.cover`。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/media_aspect_surface.dart';
import 'package:synhub/src/features/media/media_tracks.dart';

/// 把被测布局放进一个固定尺寸的窗口里。
Future<void> pumpSurface(
  WidgetTester tester,
  MediaAspectMode mode, {
  double ratio = 16 / 9,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 400,
          height: 400,
          child: MediaAspectSurface(
            mode: mode,
            aspectRatio: ratio,
            child: const ColoredBox(color: Color(0xFF112233)),
          ),
        ),
      ),
    ),
  );
}

/// 从 widget 树里读出「放大层」的实际倍数（没有放大层 = 1.0）。
///
/// ★ 这里**不读** `kMediaZoomScale`：读的是渲染用的 `Matrix4`，
/// 所以"倍数写错位置 / 写错值"都能被抓住。
double paintedZoomScale(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(find.byType(Transform));
  var scale = 1.0;
  for (final t in transforms) {
    final s = t.transform.getMaxScaleOnAxis();
    if (s > scale) scale = s;
  }
  return scale;
}

void main() {
  group('DA88 · 画面比例四档的渲染判据', () {
    testWidgets('zoom 比 fill 多一层按 kMediaZoomScale 的放大，且被 ClipRect 裁住', (
      tester,
    ) async {
      await pumpSurface(tester, MediaAspectMode.fill);
      final fillScale = paintedZoomScale(tester);
      expect(find.byType(ClipRect), findsOneWidget);
      expect(
        find.byType(Transform),
        findsNothing,
        reason: 'fill 不该有放大层（放大只属于 zoom）',
      );

      await pumpSurface(tester, MediaAspectMode.zoom);
      final zoomScale = paintedZoomScale(tester);
      expect(find.byType(ClipRect), findsOneWidget);
      expect(
        find.byType(Transform),
        findsOneWidget,
        reason: 'DA88：zoom 的放大必须做在 FittedBox 外面，否则会被 cover 抵消',
      );
      expect(
        zoomScale,
        closeTo(kMediaZoomScale, 1e-6),
        reason: 'DA88：放大倍数要真的落到矩阵上（常量值是 $kMediaZoomScale）',
      );
      expect(
        zoomScale,
        greaterThan(fillScale),
        reason: 'DA88：真机上 Zoom 与 Fill 出画逐字节相同 ⇒ 这一条必须能红',
      );
    });

    testWidgets('fill / zoom 用 cover，stretch 用 fill（会变形）', (tester) async {
      for (final mode in [MediaAspectMode.fill, MediaAspectMode.zoom]) {
        await pumpSurface(tester, mode);
        final fitted = tester.widget<FittedBox>(find.byType(FittedBox));
        expect(fitted.fit, BoxFit.cover, reason: '$mode 应当是等比铺满');
      }
      await pumpSurface(tester, MediaAspectMode.stretch);
      final fitted = tester.widget<FittedBox>(find.byType(FittedBox));
      expect(fitted.fit, BoxFit.fill, reason: 'stretch 是拉伸铺满（允许变形）');
      expect(
        find.byType(Transform),
        findsNothing,
        reason: 'stretch 不该被当成 zoom（倍数只属于 zoom）',
      );
    });

    testWidgets('fit 走 AspectRatio+Center（contain，不留放大层）', (tester) async {
      await pumpSurface(tester, MediaAspectMode.fit);
      expect(find.byType(AspectRatio), findsOneWidget);
      expect(find.byType(FittedBox), findsNothing);
      expect(find.byType(Transform), findsNothing);
      final ar = tester.widget<AspectRatio>(find.byType(AspectRatio));
      expect(ar.aspectRatio, closeTo(16 / 9, 1e-9));
    });

    testWidgets('非法比例回落 16/9（fit 与 zoom 两路都不崩）', (tester) async {
      await pumpSurface(tester, MediaAspectMode.fit, ratio: double.nan);
      expect(
        tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
        closeTo(16 / 9, 1e-9),
      );
      await pumpSurface(tester, MediaAspectMode.zoom, ratio: 0);
      expect(paintedZoomScale(tester), closeTo(kMediaZoomScale, 1e-6));
    });
  });
}
