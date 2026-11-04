// r695 · `DA337` 守卫：**同一个能力有几个入口，就得有几处分流**。
//
// 现场（`/src/walk_r695b.log` 第 739 行起）：Linux 走查推进 Drive「PDF 批注/签名」页时抛
//   PlatformNotSupportedException: Actual platform not supported by it method, try use another
//   #0 assertHasPdfSupport (package:pdfx/src/renderer/interfaces/document.dart:76:31)
// 因为查看器（`DA330`）与列表封面早已按平台改成 poppler，**批注页漏了同一条路**。
//
// 这条用例三个方向都钉：
//   ① Linux 上 `pdfPageRasterizerProvider` 必须**不是** pdfx 那条（就是本缺陷的反向判据：
//      修前这里恒等于 `defaultPdfPageRasterizer`）；
//   ② poppler 版逐页出图：页数取自 `pdfinfo`，`page` 0 基、宽高取自 PNG 的 IHDR；
//   ③ 读不到页数时**只渲第 1 页**，不编一个"共 N 页"。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/drive/drive_pdf_markup_page.dart';
import 'package:synhub/src/features/files/pdf_poppler_view.dart';

/// 24 字节起的一个"够用" PNG：签名 + IHDR 长/类型 + 宽高（大端）。
/// 判据只读 IHDR，所以不需要真的压缩数据（这不是在验 PNG 解码）。
Uint8List _png(int w, int h) {
  final b = BytesBuilder();
  b.add(<int>[137, 80, 78, 71, 13, 10, 26, 10]);
  b.add(<int>[0, 0, 0, 13]); // IHDR 长度
  b.add('IHDR'.codeUnits);
  b.add(<int>[
    (w >> 24) & 0xff,
    (w >> 16) & 0xff,
    (w >> 8) & 0xff,
    w & 0xff,
    (h >> 24) & 0xff,
    (h >> 16) & 0xff,
    (h >> 8) & 0xff,
    h & 0xff,
  ]);
  b.add(<int>[8, 6, 0, 0, 0]); // bitDepth/colorType/... + 占位 CRC
  return b.toBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('DA337 ① Linux 上批注页不许再走 pdfx 那条（反向判据：修前恒等）', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final linux = c.read(pdfPageRasterizerProvider);
    expect(identical(linux, defaultPdfPageRasterizer), isFalse,
        reason: 'Linux 上 pdfx 没有实现 ⇒ 这一页必须走 poppler');

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    expect(identical(c2.read(pdfPageRasterizerProvider), defaultPdfPageRasterizer),
        isTrue,
        reason: 'Android 上仍走 pdfx（系统 PdfRenderer），不要顺手把移动端换掉');
  });

  test('DA337 ② poppler 版逐页出图：页数来自 pdfinfo，page 0 基，宽高来自 IHDR',
      () async {
    final calls = <List<String>>[];
    Future<PdfRasterResult> run(String exe, List<String> args) async {
      calls.add(<String>[exe, ...args]);
      if (exe == 'pdfinfo') {
        return const PdfRasterResult(
          exitCode: 0,
          stdout: 'Title: probe\nPages:          2\n',
          stderr: '',
        );
      }
      // pdftoppm ... <input> <out> ⇒ 造出 <out>.png
      final out = args.last;
      await File('$out.png').writeAsBytes(_png(1240, 1754), flush: true);
      return const PdfRasterResult(exitCode: 0, stdout: '', stderr: '');
    }

    final pages = await rasterizePdfPagesWithPoppler(
      Uint8List.fromList(<int>[1, 2, 3, 4]),
      run,
    );
    expect(pages.length, 2);
    expect(pages.map((p) => p.page), <int>[0, 1]);
    expect(pages.first.width, 1240);
    expect(pages.first.height, 1754);
    expect(pages.first.pngBytes, isNotEmpty);
    // 2 页 ⇒ 1 次 pdfinfo + 2 次 pdftoppm，且页码参数逐页递增
    expect(calls.where((c) => c.first == 'pdfinfo').length, 1);
    final ppms = calls.where((c) => c.first == 'pdftoppm').toList();
    expect(ppms.length, 2);
    expect(ppms[0].sublist(ppms[0].indexOf('-f'), ppms[0].indexOf('-f') + 2),
        <String>['-f', '1']);
    expect(ppms[1].sublist(ppms[1].indexOf('-f'), ppms[1].indexOf('-f') + 2),
        <String>['-f', '2']);
  });

  test('DA337 ③ 读不到页数 ⇒ 只渲第 1 页（不编页数）', () async {
    Future<PdfRasterResult> run(String exe, List<String> args) async {
      if (exe == 'pdfinfo') {
        return const PdfRasterResult(exitCode: 1, stdout: '', stderr: 'boom');
      }
      await File('${args.last}.png').writeAsBytes(_png(100, 200), flush: true);
      return const PdfRasterResult(exitCode: 0, stdout: '', stderr: '');
    }

    final pages = await rasterizePdfPagesWithPoppler(
      Uint8List.fromList(<int>[9, 9]),
      run,
    );
    expect(pages.length, 1);
    expect(pages.single.page, 0);
    expect(pages.single.width, 100);
  });
}
