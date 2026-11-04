// 真机缺陷回归（2026-09-22）：幻灯片图片**必须按实际显示尺寸解码**。
//
// ## 缺陷现象（真机 HONOR LGE-AN10）
// `Dynamic.oslides` 打开后：`1 / 15` 指示、15 页缩略图栏、工具条都正常，
// 但**主画布只画出背景色**，图文不显示；缩略图里也**只有极小的图**画出来了
// （每条缩略图左上角那条 1917x14 的 PNG 细条），大图全是空白。
//
// ## 根因（离线实测确定）
// `_picture()` 里的 `Image.memory` **没有 `cacheWidth`/`cacheHeight`**
// ⇒ 按**原始分辨率**解码。该文件的媒体实测：
//
// | 媒体 | 字节 | 像素 | 解码后 ARGB |
// |---|---|---|---|
// | `image1.png` | 8 KB | 1917x14 | 0.1 MB |
// | `image5.jpg` | 24 KB | 397x397 | **0.6 MB** |
// | `image2.jpg` | 75 KB | 1440x810 | 4.7 MB |
// | **`image6.jpg`** | **8.9 MB** | **5612x3742** | **84 MB** |
//
// ⇒ 两个后果：
//   1. **5612 超过常见 Android GPU 的最大纹理边长 4096**；
//   2. **单张 84 MB 就塞满 Flutter 默认 100 MB 的图片缓存**；
//      15 页连续翻页时缓存被反复冲垮。
//
// **⚠️ 注意**：所有 6 个媒体用 `ui.instantiateImageCodec` 都能**成功解码**
// ⇒ 不是"格式不支持"，**是"尺寸没夹取"**。这个区分很重要：
// 我一开始猜"JPEG 解码失败"，被自己的实测**否证**了。
//
// 而幻灯片逻辑画布固定 960x540，真机上整页实际只占约 744 物理 px
// ⇒ 按原始分辨率解码既是浪费、也会失败。
//
// ## 本用例锁住的不变量
// 1. 幻灯片里**每一个** `Image` 都必须带**有界**的 `cacheWidth`/`cacheHeight`；
// 2. 夹取上限 **≤ 2048**（安全地低于 4096 的纹理边长上限）；
// 3. **★ 反向确认**：源图**确实**远大于夹取上限（证明用例不是空断言——
//    如果夹具换成小图，这条会失败，提醒我们换回真实大图样本）。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_slides_deck_view.dart';

const _fixture = 'test/fixtures/office_slides_o3/dynamic.oslides';

/// 夹取上限：**必须**低于常见 GPU 最大纹理边长 4096，留足余量。
const _maxDecodeEdge = 2048;

/// 取出一个 `Image` widget 实际请求的解码尺寸（缓存尺寸）。
///
/// `Image.memory(cacheWidth:, cacheHeight:)` 会把 provider 包成 `ResizeImage`；
/// 这两个字段**不在 `Image` widget 上**，而在 `ImageProvider` 上。
(int?, int?) _decodeSizeOf(Image img) {
  final p = img.image;
  if (p is ResizeImage) return (p.width, p.height);
  if (p is MemoryImage) return (p.scale == 1.0 ? null : null, null);
  return (null, null);
}

void main() {
  final file = File(_fixture);

  group('幻灯片大图必须按显示尺寸解码（真机空白画布回归）', () {
    test('★ 反向确认：夹具里确实有远大于夹取上限的源图', () async {
      expect(
        file.existsSync(),
        isTrue,
        reason:
            '缺少真机样本 $_fixture（应从 NAS 只读下载 Dynamic.oslides 放入）；'
            '没有它这条测试就没有意义',
      );
      final deck = OSlidesDeck.parse(file.readAsBytesSync())!;
      final widths = <String, int>{};
      for (final e in deck.media.entries) {
        final codec = await ui.instantiateImageCodec(e.value);
        final frame = await codec.getNextFrame();
        widths[e.key] = frame.image.width;
        frame.image.dispose();
        codec.dispose();
      }
      final widest = widths.values.reduce((a, b) => a > b ? a : b);
      // 这条是**证明用例不空**的关键：源图宽度必须真的超过上限。
      expect(
        widest,
        greaterThan(_maxDecodeEdge),
        reason:
            '夹具中最宽的图是 $widest px，没有超过 $_maxDecodeEdge；'
            '那这条回归就测不到东西了（这正是缺陷被漏掉的模式）',
      );
      // 且确实有超过 GPU 纹理边长上限 4096 的图。
      expect(
        widths.values.any((w) => w > 4096),
        isTrue,
        reason: '夹具里应有超过 4096 的图，否则复现不了真机那个现象；实测=$widths',
      );
    });

    testWidgets('★ 幻灯片里每个 Image 都必须有界地夹取解码尺寸', (tester) async {
      // 真机精确参数：override 1148x2492，density 490 → DPR 3.0625
      tester.view.physicalSize = const Size(1148, 2492);
      tester.view.devicePixelRatio = 490 / 160;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final deck = OSlidesDeck.parse(file.readAsBytesSync())!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeSlidesDeckView(deck: deck)),
        ),
      );
      await tester.pump();

      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images, isNotEmpty, reason: '这一页应当有图片，否则测不到夹取');

      for (final img in images) {
        final (w, h) = _decodeSizeOf(img);
        expect(w, isNotNull, reason: 'Image.memory 必须设 cacheWidth，否则按原始分辨率解码');
        expect(h, isNotNull, reason: 'Image.memory 必须设 cacheHeight，否则按原始分辨率解码');
        expect(w!, greaterThan(0));
        expect(h!, greaterThan(0));
        expect(
          w,
          lessThanOrEqualTo(_maxDecodeEdge),
          reason: 'cacheWidth=$w 超过安全上限 $_maxDecodeEdge',
        );
        expect(
          h,
          lessThanOrEqualTo(_maxDecodeEdge),
          reason: 'cacheHeight=$h 超过安全上限 $_maxDecodeEdge',
        );
      }
    });

    testWidgets('夹取尺寸随画布缩放变化，但始终不超过上限', (tester) async {
      final deck = OSlidesDeck.parse(file.readAsBytesSync())!;
      // ⚠️ 只用**真实手机宽度**（>=266dp）：实测在 400 物理 px / DPR3 = 133dp 时
      // deck view 会 `RenderFlex overflowed by 111 pixels`（缩略图栏 116dp + 画布放不下）。
      // 133dp 不是任何真实手机；那条属于**另一个**健壮性缺口，见
      // docs/office-slides-device-blank-rootcause.md「附带发现」。
      for (final size in const [
        Size(800, 1600),
        Size(1080, 1920),
        Size(1440, 2880),
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 3.0;
        await tester.pumpWidget(
          MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: OfficeSlidesDeckView(deck: deck)),
          ),
        );
        await tester.pump();
        for (final img in tester.widgetList<Image>(find.byType(Image))) {
          final (w, h) = _decodeSizeOf(img);
          expect(w, isNotNull);
          expect(w!, greaterThan(0));
          expect(w, lessThanOrEqualTo(_maxDecodeEdge));
          expect(h, lessThanOrEqualTo(_maxDecodeEdge));
        }
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    });
  });
}
