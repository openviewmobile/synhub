// HUD 图片查看器：多图左右切 / 双击缩放 / 下滑关闭。
//
// 这些行为是本次 UI 现代化新增的（原版是 ViewPager + 未做下滑关闭），
// 所以断言的是"新行为"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/file_prop_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/chat/attachment_view.dart';

FilePropDto _png(String name) =>
    FilePropDto.fromJson({'name': name, 'type': 'png'});

PostDto _post() => PostDto.fromJson(const {
  'post_id': 4242,
  'channel_id': 5,
  'creator_id': 14,
  'type': 'file',
  'message': '',
});

Widget _host(ProviderContainer c, Widget child) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: child),
);

void main() {
  testWidgets('多图：左右滑切换页，AppBar 页码跟着走', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final a = _png('a.png');
    final b = _png('b.png');
    await tester.pumpWidget(
      _host(
        c,
        ImageViewerPage(
          url: 'https://example.invalid/a.png',
          title: 'a.png',
          post: _post(),
          prop: a,
          images: [a, b],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('a.png'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.byType(PageView), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('b.png'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('单图不包 PageView（避免手势竞争）', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final a = _png('only.png');
    await tester.pumpWidget(
      _host(
        c,
        ImageViewerPage(
          url: 'https://example.invalid/a.png',
          title: 'only.png',
          post: _post(),
          prop: a,
          images: [a],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(PageView), findsNothing);
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('双击放大到 2.5 倍，再双击还原', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final a = _png('a.png');
    await tester.pumpWidget(
      _host(
        c,
        ImageViewerPage(
          url: 'https://example.invalid/a.png',
          title: 'a.png',
          post: _post(),
          prop: a,
        ),
      ),
    );
    await tester.pump();

    InteractiveViewer viewer() =>
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    double scale() =>
        viewer().transformationController!.value.getMaxScaleOnAxis();

    expect(scale(), closeTo(1, 0.001));
    expect(viewer().minScale, 1);
    expect(viewer().maxScale, 6);

    final center = tester.getCenter(find.byType(InteractiveViewer));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(scale(), closeTo(2.5, 0.01));

    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(scale(), closeTo(1, 0.01));
  });

  testWidgets('未放大时下滑超过阈值 → 关闭查看器', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final a = _png('a.png');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ImageViewerPage(
                    url: 'https://example.invalid/a.png',
                    title: 'a.png',
                    post: _post(),
                    prop: a,
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);

    // 直接拖 InteractiveViewer：内层的下滑手势会接管
    await tester.drag(find.byType(InteractiveViewer), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.text('打开'), findsOneWidget);
  });
}
