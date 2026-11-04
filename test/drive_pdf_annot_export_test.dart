// ★★ ③Drive 第 231 轮 **D61 批注写进 PDF 注释对象层** 用例。
//
// 不靠"看着像"：直接解出导出的 PDF 字节，检查
//   * `/Annots` 真的挂上了；
//   * 三种 `Subtype` 都在（`/Square`、`/Ink`、`/Text`）；
//   * 位图副本被**压缩**过 ⇒ 检查对象结构前要先解压（`zlib`）——
//     否则正则扫不到注释对象（这是"布局断言证明不了内容"的同类坑）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:synhub/src/features/drive/drive_pdf_annot_export.dart';
import 'package:synhub/src/features/drive/drive_pdf_markup.dart';

/// 用 `image` 包现场编码一张 4×4 PNG：**真的能解码**（手搓 base64 曾坑过一轮）
Uint8List _png4x4Bytes() {
  final im = img.Image(width: 4, height: 4);
  img.fill(im, color: img.ColorRgb8(200, 210, 220));
  return Uint8List.fromList(img.encodePng(im));
}

PdfPageBitmap _page(int index) => PdfPageBitmap(
  page: index,
  width: 200,
  height: 100,
  pngBytes: _png4x4Bytes(),
);

PdfMarkupDoc _doc() {
  final d = PdfMarkupDoc();
  d.add(
    const PdfMarkup(
      id: 'h1',
      page: 0,
      kind: PdfMarkupKind.highlight,
      left: 0.10,
      top: 0.20,
      right: 0.60,
      bottom: 0.30,
      color: 0xFFFFD54F,
    ),
  );
  d.add(
    const PdfMarkup(
      id: 'n1',
      page: 0,
      kind: PdfMarkupKind.note,
      left: 0.10,
      top: 0.40,
      right: 0.30,
      bottom: 0.50,
      note: '这是一条便签',
    ),
  );
  d.add(
    const PdfMarkup(
      id: 'i1',
      page: 0,
      kind: PdfMarkupKind.ink,
      points: [0.05, 0.90, 0.20, 0.85, 0.40, 0.95],
      color: 0xFFE53935,
    ),
  );
  return d;
}

/// 把 PDF 里所有 `stream … endstream` 解压出来拼成一个大字符串，
/// 便于正则扫对象（对象本身不压缩，但整份文件里混着压缩流）。
String _inflateAll(Uint8List bytes) {
  final out = StringBuffer();
  final raw = latin1.decode(bytes, allowInvalid: true);
  // 未压缩部分（对象字典）直接进
  out.write(raw);
  // 再把 FlateDecode 流解开（用包内自带的 zlib）
  final re = RegExp(r'stream\r?\n');
  var idx = 0;
  while (true) {
    final m = re.firstMatch(raw.substring(idx));
    if (m == null) break;
    final start = idx + m.end;
    final end = raw.indexOf('endstream', start);
    if (end < 0) break;
    final chunk = bytes.sublist(start, end);
    try {
      out.write(latin1.decode(zlib.decode(chunk), allowInvalid: true));
    } catch (_) {
      // 不是 zlib 流（例如图片 DCT）就跳过
    }
    idx = end + 1;
  }
  return out.toString();
}

void main() {
  group('D61 注释对象层 · 对象与坐标', () {
    late Uint8List bytes;
    late String text;

    setUpAll(() async {
      bytes = await flattenPdfMarkupsAnnotated(
        pages: [_page(0)],
        doc: _doc(),
        date: DateTime.utc(2026, 1, 2),
      );
      text = _inflateAll(bytes);
    });

    test('页面上真的挂了 /Annots（不是只画上去）', () {
      expect(text, contains('/Annots'));
      // ★ PDF 里键值**不保证有空格**（实测输出是 `/Type/Annot`）⇒ 一律用宽松正则
      expect(text, matches(RegExp(r'/Type\s*/Annot')));
    });

    test('三种注释子类型都在：/Square（高亮近似）、/Ink、/Text', () {
      for (final s in kPdfAnnotSubtypes) {
        expect(
          text,
          matches(RegExp('/Subtype\\s*${RegExp.escape(s)}')),
          reason: '缺少 $s',
        );
      }
    });

    test('★ pdf 包没有 /Highlight —— 这个事实被钉在常量里，不许悄悄改', () {
      expect(kPdfHasHighlightSubtype, isFalse);
      expect(text, isNot(matches(RegExp(r'/Subtype\s*/Highlight'))));
      // `pdf` 包写的键是 `/Subj`（不是 `/Subject`）——按实际输出来断言
      expect(text, matches(RegExp(r'/Subj\s*\(Highlight\)')));
    });

    test('便签文字真的进了 /Contents（按 PDF 字面串解 UTF-16BE）', () {
      // `PdfString.fromString` 对非拉丁文字写 **UTF-16BE 字面串**（可能带 BOM）。
      // 所以要从 `/Contents(...)` 里取出原始字节再解码 —— 不能直接找中文字符。
      final m = RegExp(r'/Contents\((.*?)\)/F', dotAll: true).firstMatch(text);
      expect(m, isNotNull, reason: '便签注释必须带 /Contents');
      final rawBytes = latin1.encode(m!.group(1)!);
      expect(rawBytes.length.isEven, isTrue, reason: 'UTF-16BE 字节数必须是偶数');
      final units = <int>[
        for (var i = 0; i + 1 < rawBytes.length; i += 2)
          (rawBytes[i] << 8) | rawBytes[i + 1],
      ];
      final decoded = String.fromCharCodes(
        units.skipWhile((u) => u == 0xFEFF),
      );
      expect(decoded, '这是一条便签');
    });

    test('三个批注 ⇒ /Annots 里三条**互不相同**的引用（231 轮抓到过重复）', () {
      final m = RegExp(r'/Annots\[([^\]]*)\]').firstMatch(text);
      expect(m, isNotNull);
      final refs = RegExp(r'(\d+ 0 R)')
          .allMatches(m!.group(1)!)
          .map((e) => e.group(1)!)
          .toList();
      expect(refs, hasLength(3));
      expect(refs.toSet(), hasLength(3), reason: '/Annots 出现重复引用');
    });

    test('高亮对象：矩形按页面高度翻了 y（归一化 0.20~0.30 ⇒ PDF 70~80）', () {
      // 页高 100 ⇒ bottom_pdf = 100 - 0.30*100 = 70；top_pdf = 100 - 0.20*100 = 80
      final m = RegExp(r'/Rect\s*\[\s*([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s*\]')
          .allMatches(text)
          .map((m) => [for (var i = 1; i <= 4; i++) double.parse(m.group(i)!)])
          .toList();
      expect(m, isNotEmpty, reason: '至少要有一个 /Rect');
      final hit = m.any(
        (r) =>
            (r[0] - 20).abs() < 1 &&
            (r[1] - 70).abs() < 1 &&
            (r[2] - 120).abs() < 1 &&
            (r[3] - 80).abs() < 1,
      );
      expect(hit, isTrue, reason: '高亮矩形没按左下原点翻转：$m');
    });

    test('手写对象带 /InkList，且点数与模型一致（3 个点 ⇒ 6 个数）', () {
      final m = RegExp(r'/InkList\s*\[([^\]]*)\]').firstMatch(text);
      expect(m, isNotNull, reason: '缺少 /InkList');
      final nums = RegExp(r'-?[0-9.]+')
          .allMatches(m!.group(1)!)
          .map((e) => double.parse(e.group(0)!))
          .toList();
      expect(nums.length % 2, 0);
      expect(
        nums.length ~/ 2,
        3,
        reason: '模型里手写有 3 个点，PDF 里也必须 3 个',
      );
    });

    test('作者与日期进了对象（其他阅读器的批注面板会显示）', () {
      // 作者键是 `/T`、日期键是 `/M`（`PdfAnnotBase.build`）
      expect(
        text,
        matches(RegExp('/T\\s*\\(${RegExp.escape(kPdfAnnotAuthor)}\\)')),
      );
      expect(text, matches(RegExp(r'/M\s*\(D:20260102')));
    });

    test('页数仍是 1（注释不额外造页）', () {
      final count = RegExp(r'/Type\s*/Page[^s]').allMatches(text).length;
      expect(count, 1);
    });
  });

  group('D61 注释对象层 · 视觉层仍保留', () {
    test('多页 + 无批注页：仍然每页都出，注释只挂在该有的页上', () async {
      final doc = _doc();
      doc.add(
        const PdfMarkup(
          id: 'h2',
          page: 1,
          kind: PdfMarkupKind.highlight,
          left: 0.1,
          top: 0.1,
          right: 0.2,
          bottom: 0.2,
        ),
      );
      final bytes = await flattenPdfMarkupsAnnotated(
        pages: [_page(0), _page(1)],
        doc: doc,
      );
      final text = _inflateAll(bytes);
      final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(text).length;
      expect(pages, 2);
      // 两个高亮 ⇒ 两个 /Subtype /Square
      final squares = RegExp(r'/Subtype\s*/Square').allMatches(text).length;
      expect(squares, 2);
    });

    test('真实文件产物可落盘、能被读回（不造假证据）', () async {
      final dir = Directory.systemTemp.createTempSync('d61_annot');
      final f = File('${dir.path}/out.pdf');
      await f.writeAsBytes(
        await flattenPdfMarkupsAnnotated(pages: [_page(0)], doc: _doc()),
      );
      final back = await f.readAsBytes();
      expect(back.length, greaterThan(1000));
      expect(latin1.decode(back, allowInvalid: true), startsWith('%PDF-'));
      dir.deleteSync(recursive: true);
    });
  });
}
