// r691 · `DA330`：Linux 上 PDF **真的出图**（poppler 路径）—— 跑在真 Linux 容器里。
//
// 判据三层（缺一层都不算闭环）：
//   ① `popplerAvailable()` 为真 —— 这台机器确实有 `pdftoppm`；
//   ② 我们自己合成的一份 PDF（纯 Dart 拼的合法文件）能被 `pdfinfo` 读出页数；
//   ③ 渲出来的 PNG **有像素**（`convert` 量标准差 > 0.05），并把 PNG 落进证据目录。
//
// 合成 PDF 而不是下载样本：网络样本会过期、也会给"证据来源"添一层不确定；
// 这份 PDF 里有**三块不同颜色的实心矩形**，所以"非空"不是判据 —— 判据是像素离散度。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/pdf_poppler_view.dart';

/// 拼一份最小合法 PDF（2 页、彩色实心块）。
///
/// **为什么手拼**：仓库里没有 PDF 测试样本，而这一轮要验的正是"渲染这条链"，
/// 依赖外部样本等于把判据交给别人。手拼的 PDF 只要被 `pdfinfo` 认可（页数对），
/// 就说明它真是合法 PDF —— 这本身就是一条判据。
Uint8List buildSamplePdf() {
  final objs = <String>[
    // 1: Catalog
    '<< /Type /Catalog /Pages 2 0 R >>',
    // 2: Pages
    '<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>',
    // 3: Page 1
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] '
        '/Resources << >> /Contents 4 0 R >>',
    // 4: Page 1 content
    '<< /Length 108 >>\nstream\n'
        '0.10 0.35 0.85 rg 20 20 260 120 re f\n'
        '0.90 0.20 0.10 rg 20 160 120 120 re f\n'
        '0.95 0.80 0.10 rg 160 160 120 120 re f\n'
        'endstream',
    // 5: Page 2
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] '
        '/Resources << >> /Contents 6 0 R >>',
    // 6: Page 2 content
    '<< /Length 62 >>\nstream\n'
        '0.20 0.20 0.20 rg 40 40 220 220 re f\n'
        'endstream',
  ];

  final buf = StringBuffer('%PDF-1.7\n%\u00E2\u00E3\u00CF\u00D3\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offsets.add(buf.length);
    buf.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xrefPos = buf.length;
  buf.write('xref\n0 ${objs.length + 1}\n');
  buf.write('0000000000 65535 f \n');
  for (final off in offsets) {
    buf.write('${off.toString().padLeft(10, '0')} 00000 n \n');
  }
  buf.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\n');
  buf.write('startxref\n$xrefPos\n%%EOF\n');

  // PDF 的字节是 latin-1 语义：逐字符取低 8 位，别用 UTF-8（会把中文注释区搞坏）
  final bytes = Uint8List(buf.length);
  final s = buf.toString();
  for (var i = 0; i < s.length; i++) {
    bytes[i] = s.codeUnitAt(i) & 0xFF;
  }
  return bytes;
}

/// 用 ImageMagick 量一张 PNG 的灰度标准差（容器里是 ImageMagick **6** ⇒ `convert`）。
Future<double?> stdDevOf(String pngPath) async {
  for (final exe in ['convert', 'magick']) {
    try {
      final r = await Process.run(exe, [
        pngPath,
        '-colorspace',
        'Gray',
        '-format',
        '%[fx:standard_deviation]',
        'info:',
      ]);
      if (r.exitCode != 0) continue;
      final v = double.tryParse('${r.stdout}'.trim());
      if (v != null) return v;
    } catch (_) {
      // 换下一个工具名（容器里没有 magick）
    }
  }
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('r691 DA330 · Linux PDF：poppler 真渲出彩色像素', (tester) async {
    // ① 装置前提
    final available = await popplerAvailable(
      (exe, args) async {
        final r = await Process.run(exe, args);
        return PdfRasterResult(
          exitCode: r.exitCode,
          stdout: '${r.stdout}',
          stderr: '${r.stderr}',
        );
      },
    );
    expect(
      available,
      isTrue,
      reason: '这台机器没有 pdftoppm（poppler-utils）—— 装置不满足，不能报绿',
    );

    final pdf = buildSamplePdf();

    // ② 我们自己拼的 PDF 必须被 poppler 认可（页数 = 2）
    final pages = await popplerPageCount(
      pdf,
      (exe, args) async {
        final r = await Process.run(exe, args);
        return PdfRasterResult(
          exitCode: r.exitCode,
          stdout: '${r.stdout}',
          stderr: '${r.stderr}',
        );
      },
    );
    expect(pages, 2, reason: '合成 PDF 没被 pdfinfo 认可 ⇒ 样本本身有问题');

    // ③ 第 1 页渲成 PNG，量像素
    final png = await popplerRenderPage(pdf, page: 1, dpi: 96);
    expect(png.length, greaterThan(1000));
    const outDir = 'docs/evidence-r691-linux/shots';
    Directory(outDir).createSync(recursive: true);
    final out = '$outDir/50_linux_pdf_page1.png';
    File(out).writeAsBytesSync(png);
    final sd = await stdDevOf(out);
    // ignore: avoid_print
    print(
      '[r691] PDF ok pages=$pages png=${png.length}B stddev=$sd out=$out',
    );
    expect(sd, isNotNull, reason: '量不到像素（ImageMagick 不可用）');
    expect(
      sd!,
      greaterThan(0.05),
      reason: 'PNG 是纯色/空白（stddev=$sd）⇒ 没有真出图',
    );

    // ④ 页面级：把 PopplerPdfView 真挂起来，确认它给出了图片与翻页条
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            localizationsDelegates: AppText.localizationsDelegates,
            supportedLocales: AppText.supportedLocales,
            home: Scaffold(body: PopplerPdfView(bytes: pdf, dpi: 72)),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump();
    expect(find.byKey(const Key('pdf-poppler-page-indicator')), findsOneWidget);
    expect(find.byKey(const Key('pdf-poppler-next')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    final indicator = tester.widget<Text>(
      find.byKey(const Key('pdf-poppler-page-indicator')),
    );
    // ignore: avoid_print
    print('[r691] PDF 页面读数 = ${indicator.data}');
    expect(indicator.data, isNotEmpty);
  });
}
