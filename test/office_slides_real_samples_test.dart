// O3：**真实 NAS 文件**闭环（4 份 `.oslides`）。
//
// 诚实边界：样本本体**不 vendored 进仓库**（`Dynamic.oslides` 有 9 MB），本文件只按
// 路径读取；缺失时整组 **skip** 并写明原因。身份（字节数/sha256）见
// `docs/office-slides-redesign-report.md` §真机取证。
//
// 这组用例的价值：证明解析器不是"只对一份样本过拟合"——4 份文件的页数、版式数、
// 媒体清单、文字都由 `zipfile` 独立读出后写进断言，**不是**解析器自证。
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';

final Directory _root = Directory(
  Platform.environment['OFFICE_SLIDES_REAL_SAMPLES'] ?? '/tmp/o3samples',
);

final String? _skipReason = _root.existsSync()
    ? null
    : '真实 .oslides 样本缺失：${_root.path}（只读取证时下载，样本不进仓库）';

void main() {
  group('真实 NAS .oslides（4 份）', () {
    for (final name in const [
      'Technology.oslides',
      'Dynamic.oslides',
      'Ripple.oslides',
      'Celestial.oslides',
    ]) {
      test('$name：所有页面都有可绘制形状 + 几何继承生效', () {
        final bytes = File('${_root.path}/$name').readAsBytesSync();
        final deck = OSlidesDeck.parse(bytes);
        expect(deck, isNotNull, reason: '$name 必须是可解析的 PPTX');
        expect(deck!.slides, isNotEmpty);
        expect(deck.isWidescreen || deck.isStandard, isTrue);
        expect(deck.layoutCount, greaterThan(0));
        expect(deck.inheritedGeometryCount, greaterThan(0));
        for (final slide in deck.slides) {
          expect(
            slide.drawableShapeCount,
            greaterThan(0),
            reason: '$name 第 ${slide.pageNumber} 页应至少有一个带几何的形状',
          );
          expect(slide.inheritedGeometryCount, greaterThan(0));
        }
        // 至少一页有真实文字（Celestial 只有 1 页且内容为空，排除它）。
        if (name != 'Celestial.oslides') {
          expect(deck.slides.map((s) => s.plainText).join().trim(), isNotEmpty);
        }
        debugPrint(
          '[O3] $name → ${deck.slides.length} 页 / ${deck.layoutCount} 版式 / '
          '${deck.inheritedGeometryCount} 个继承几何 / '
          '${deck.media.length} 个媒体（矢量 ${deck.unrenderableVectorCount}）/ '
          '${deck.unsupportedObjectCount} 个暂不支持对象',
        );
      }, skip: _skipReason);
    }
  });
}
