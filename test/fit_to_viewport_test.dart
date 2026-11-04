// ★★★ r131（macOS 逐屏走查 D20）：**照片查看器必须把图 fit 到视口**，不许按 1:1 原生像素画。
//
// 缺陷现场（真机像素，`docs/platform-macos-ui-audit.md` §1.1 第 53 行 / §3 D20）：
//   `p16_photo_viewer.png` 里那张图在 1600×1200 画布上只占 **127×127 px（0.84%）**，
//   而**同一张图**在 `p10` 的时间线磁贴里占 **527 px**。
//
// 根因（本文件的反向用例把它钉死）：查看器原来是
//   `ZoomStage(child: Center(child: Image.memory(bytes, fit: BoxFit.contain)))`
// `Center` 给的是**松约束**，`RenderImage` 在松约束下缩到**图自己的固有尺寸**
// ⇒ `BoxFit.contain` 没有可缩放的空间：小图就 1:1 画在画布正中（scale == 1）。
//   反过来，磁贴给的是**紧约束**，所以同一张图在磁贴里被放大到 527 px —— 两处不一致。
//
// 修法：`FitToViewport`（`lib/src/core/media/fit_to_viewport.dart`）先把 child 撑到视口大小，
// `BoxFit` 这才真的把图放大/缩小到可视区。
//
// ★ 断言钉的是**机制量**（§2.0.30②）：
//   * `box` = `RenderImage` 的**布局尺寸**；
//   * `scale = min(box.w / img.w, box.h / img.h)` ⇒ 小图必须 `> 1`、大图必须 `<= 1`。
//   **不**钉"某元素此刻可不可见" —— 1:1 的小图在画布正中**确实看得见**，只是小到 0.84%，
//   只钉可见性会把这条缺陷放行。
//
// ★ 测试装置注意：`ui.Picture.toImage()` / 图片解码要走**真异步**，在 `testWidgets` 的
//   假时钟里直接 await 会**永久挂住**（本用例初版就踩了这条，10 分钟超时）。所以
//   ① 造图一律放进 `tester.runAsync()`；② 树里用 `RawImage`（同步）而不是 `Image.memory`
//   （后者要异步解码，同样会挂）。

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/media/fit_to_viewport.dart';

/// 造一张宽高可控的图（走真异步，见文件头说明）。不用 PNG 编解码 —— 测的是**布局**。
Future<ui.Image> _image(WidgetTester tester, int w, int h) async {
  final img = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFFFF0000),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    picture.dispose();
    return image;
  });
  return img!;
}

/// 把 widget 放进 400×600 的"视口"里，量出图片这一层的机制量。
Future<({Size box, Size image, double scale, Size viewport})> _measureIn(
  WidgetTester tester,
  Widget stage,
) async {
  const viewport = Size(400, 600);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: viewport),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: viewport.width,
            height: viewport.height,
            child: stage,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  final finder = find.byType(RawImage);
  expect(finder, findsWidgets, reason: '必须真的有一张图在渲染');
  final raw = tester.widget<RawImage>(finder.first);
  final img = raw.image!;
  final box = tester.getSize(finder.first);
  return (
    box: box,
    image: Size(img.width.toDouble(), img.height.toDouble()),
    scale: math.min(box.width / img.width, box.height / img.height),
    viewport: viewport,
  );
}

void main() {
  group('★★★★ 小图必须被放大到视口（缺陷本体）', () {
    testWidgets('小图：box 必须铺满视口、scale > 1、长边贴满', (tester) async {
      final small = await _image(tester, 32, 16);
      final m = await _measureIn(
        tester,
        FitToViewport(child: RawImage(image: small, fit: BoxFit.contain)),
      );
      expect(m.image, const Size(32, 16), reason: '前提：喂进去的是小图');
      expect(
        m.box,
        const Size(400, 600),
        reason: 'RenderImage 的布局尺寸必须是**视口**（实际 ${m.box}）',
      );
      expect(
        m.scale,
        greaterThan(1.0),
        reason: '小图必须放大；scale=${m.scale}（==1 就是"按原生像素画"的缺陷）',
      );
      final painted = Size(m.image.width * m.scale, m.image.height * m.scale);
      expect(
        math.max(painted.width, painted.height),
        closeTo(m.viewport.width, 0.5),
        reason: 'contain 必须把长边贴满视口（画出 $painted / 视口 ${m.viewport}）',
      );
      expect(painted.width <= m.viewport.width + 0.5, isTrue);
      expect(painted.height <= m.viewport.height + 0.5, isTrue);
    });
  });

  group('★★★★ 大图必须被缩小到视口内（不许裁切）', () {
    testWidgets('大图：scale <= 1，且画出来的矩形完全落在视口内', (tester) async {
      final big = await _image(tester, 1600, 800);
      final m = await _measureIn(
        tester,
        FitToViewport(child: RawImage(image: big, fit: BoxFit.contain)),
      );
      expect(m.image, const Size(1600, 800), reason: '前提：喂进去的是大图');
      expect(m.box, const Size(400, 600));
      expect(m.scale, lessThanOrEqualTo(1.0), reason: '大图必须缩小；scale=${m.scale}');
      final painted = Size(m.image.width * m.scale, m.image.height * m.scale);
      expect(painted.width <= m.viewport.width + 0.5, isTrue, reason: '$painted');
      expect(painted.height <= m.viewport.height + 0.5, isTrue, reason: '$painted');
      expect(
        math.max(painted.width, painted.height),
        closeTo(m.viewport.width, 0.5),
        reason: '长边贴满（画出 $painted）',
      );
    });
  });

  group('★★★★ 反向验证：修复前的结构确实会 1:1 画小图', () {
    testWidgets('旧写法 Center + BoxFit.contain：box = 固有尺寸、scale == 1', (tester) async {
      final small = await _image(tester, 32, 16);
      final m = await _measureIn(
        tester,
        Center(child: RawImage(image: small, fit: BoxFit.contain)),
      );
      // 记下真实数字：这就是 D20 的根因（盒子是 32×16，而不是 400×600）。
      expect(
        m.box,
        const Size(32, 16),
        reason: '松约束下 RenderImage 缩到固有尺寸（实际 ${m.box}）',
      );
      expect(
        m.scale,
        closeTo(1.0, 0.001),
        reason: '旧写法 scale=${m.scale} ⇒ 真机上就是 127px / 0.84% 那个现象',
      );
    });
  });

  group('★★★★ 接线：查看器真的用了 FitToViewport', () {
    test('photo_viewer_page 的 _OriginalPhoto 必须走 FitToViewport', () {
      final src = File(
        'lib/src/features/photos/photo_viewer_page.dart',
      ).readAsStringSync();
      expect(
        src.contains('FitToViewport('),
        isTrue,
        reason: '查看器必须用 FitToViewport 撑到视口，否则 BoxFit 无处可缩放',
      );
      // 反向：旧的 `Center(child: Image.memory(` 形态不许回来（它正是 D20）。
      //   ★ 先剥掉注释再判 —— 修复说明里**引用**了旧写法，那不是代码。
      final code = src.replaceAll(RegExp(r'//[^\n]*'), '');
      expect(
        RegExp(r'Center\(\s*child:\s*Image\.memory\(').hasMatch(code),
        isFalse,
        reason: '不许再用 Center + Image 固有尺寸的写法',
      );
      expect(code.contains('FitToViewport('), isTrue);
    });
  });
}
