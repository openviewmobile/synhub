// 电子书封面提取（book_cover.dart）的离线测试。
//
// **为什么全部现场造包**：封面提取的分支全在"包内路径 / OPF 清单 / 大小写 /
// 自然序 / base64"这些结构细节上，提交二进制 fixture 既不利于 review 也容易
// 随格式漂移；用 `package:archive` 的 ZipEncoder 现造最小包，测试意图一眼可见。
//
// 造出来的"图片"只保证符合 magic number（提取层就只校验这个，不解码像素），
// 尾字节带 tag 用来区分到底抠到了哪一张。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/files/book_cover.dart';

/// "看起来像 PNG"的假图：真 magic number + 可区分尾字节
Uint8List _png(int tag) {
  final b = Uint8List(16);
  b.setAll(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  b[8] = tag;
  b[9] = 0xC0;
  return b;
}

/// "看起来像 JPEG"的假图
Uint8List _jpg(int tag) {
  final b = Uint8List(16);
  b.setAll(0, const [0xFF, 0xD8, 0xFF, 0xE0]);
  b[4] = tag;
  b[5] = 0xC0;
  return b;
}

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

/// 现场用 ZipEncoder 打一个 zip（模拟 EPUB/CBZ 容器）
Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, data) {
    archive.addFile(ArchiveFile(name, data.length, data));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 最小 EPUB：mimetype + container.xml + OPF（+ 资源）
Uint8List _epub(
  String opf, {
  Map<String, List<int>> extra = const {},
  String containerPath = 'OEBPS/content.opf',
  bool container = true,
}) {
  return _zip({
    'mimetype': _utf8('application/epub+zip'),
    if (container)
      'META-INF/container.xml': _utf8(
        '<?xml version="1.0"?>'
        '<container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="$containerPath" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
      ),
    containerPath: _utf8(opf),
    ...extra,
  });
}

/// 一个带封面 item 的 OPF 模板（manifest 内容由调用方拼）
String _opf(String metadata, String manifest, {String spine = ''}) =>
    '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">$metadata</metadata>
  <manifest>$manifest</manifest>
  <spine>$spine</spine>
</package>''';

const _chapterItem =
    '<item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>';

void main() {
  group('looksLikeCoverImage', () {
    test('认 PNG/JPEG/GIF/WEBP/BMP 的 magic number', () {
      expect(looksLikeCoverImage(_png(1)), isTrue);
      expect(looksLikeCoverImage(_jpg(1)), isTrue);
      expect(
        looksLikeCoverImage(
          Uint8List.fromList([
            0x47,
            0x49,
            0x46,
            0x38,
            0x39,
            0x61,
            ...List.filled(8, 0),
          ]),
        ),
        isTrue,
      );
      expect(
        looksLikeCoverImage(
          Uint8List.fromList([0x42, 0x4D, ...List.filled(12, 0)]),
        ),
        isTrue,
      );
      expect(
        looksLikeCoverImage(
          Uint8List.fromList([
            0x52,
            0x49,
            0x46,
            0x46,
            0,
            0,
            0,
            0,
            0x57,
            0x45,
            0x42,
            0x50,
          ]),
        ),
        isTrue,
      );
    });

    test('HTML / 文本 / 太短的字节都不算图片', () {
      expect(
        looksLikeCoverImage(_utf8('<html><body>404</body></html>')),
        isFalse,
      );
      expect(
        looksLikeCoverImage(_utf8('just text, definitely not an image')),
        isFalse,
      );
      expect(looksLikeCoverImage(Uint8List(4)), isFalse);
    });
  });

  group('EPUB', () {
    test('EPUB3：properties="cover-image" 能拿到封面', () {
      final epub = _epub(
        _opf(
          '<dc:title>T</dc:title>',
          '$_chapterItem'
              '<item id="cv" href="images/cover.png" '
              'media-type="image/png" properties="cover-image"/>',
        ),
        extra: {'OEBPS/images/cover.png': _png(7)},
      );

      final cover = bookCoverBytes('epub', epub);
      expect(cover, isNotNull);
      expect(cover, equals(_png(7)));
      // 前缀是真 PNG 头
      expect(cover!.sublist(0, 4), equals([0x89, 0x50, 0x4E, 0x47]));
    });

    test('EPUB2：<meta name="cover" content="ID"> 能拿到封面', () {
      final epub = _epub(
        _opf(
          '<dc:title>T</dc:title><meta name="cover" content="cov"/>',
          '$_chapterItem'
              '<item id="cov" href="cover.jpg" media-type="image/jpeg"/>',
        ),
        extra: {'OEBPS/cover.jpg': _jpg(3)},
      );

      expect(bookCoverBytes('epub', epub), equals(_jpg(3)));
    });

    test('href 带 ../ + %20 + 大小写不一致也能拿到', () {
      final epub = _epub(
        _opf(
          '<dc:title>T</dc:title>',
          '<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
              '<item id="cv" href="../images/Cover%20Art.JPG" '
              'media-type="image/jpeg" properties="cover-image"/>',
        ),
        containerPath: 'OEBPS/text/content.opf',
        // zip 里实际是小写、带空格的名字
        extra: {'OEBPS/images/cover art.jpg': _jpg(11)},
      );

      expect(bookCoverBytes('epub', epub), equals(_jpg(11)));
    });

    test('container.xml 缺失时兜底搜第一个 .opf', () {
      final epub = _epub(
        _opf(
          '<dc:title>T</dc:title>',
          '$_chapterItem'
              '<item id="cv" href="img/c.png" media-type="image/png" '
              'properties="cover-image"/>',
        ),
        container: false,
        extra: {'OEBPS/img/c.png': _png(21)},
      );

      expect(bookCoverBytes('epub', epub), equals(_png(21)));
    });

    test('没有封面线索 → null（不会退而拿正文插图）', () {
      final epub = _epub(
        _opf(
          '<dc:title>T</dc:title>',
          '$_chapterItem'
              '<item id="pic" href="images/illustration.png" '
              'media-type="image/png"/>',
          spine: '<itemref idref="c1"/>',
        ),
        extra: {
          'OEBPS/images/illustration.png': _png(99),
          'OEBPS/text/ch1.xhtml': _utf8('<html><body><p>hi</p></body></html>'),
        },
      );

      expect(bookCoverBytes('epub', epub), isNull);
    });

    test('最后一层兜底：spine 第一个文档里的 <img>', () {
      final epub = _epub(
        _opf(
          '<dc:title>T</dc:title>',
          '<item id="c1" href="text/cover.xhtml" '
              'media-type="application/xhtml+xml"/>'
              '<item id="img" href="images/only.png" media-type="image/png"/>',
          spine: '<itemref idref="c1"/>',
        ),
        extra: {
          'OEBPS/text/cover.xhtml': _utf8(
            '<html><body><img src="../images/only.png" alt=""/></body></html>',
          ),
          'OEBPS/images/only.png': _png(9),
        },
      );

      expect(bookCoverBytes('epub', epub), equals(_png(9)));
    });

    test('封面 href 指向的是 HTML 错误页 → null（图片校验兜住）', () {
      final epub = _epub(
        _opf(
          '<dc:title>T</dc:title><meta name="cover" content="cov"/>',
          '$_chapterItem'
              '<item id="cov" href="cover.jpg" media-type="image/jpeg"/>',
        ),
        extra: {
          'OEBPS/cover.jpg': _utf8(
            '<html><head><title>404</title></head><body>Not Found</body></html>',
          ),
        },
      );

      expect(bookCoverBytes('epub', epub), isNull);
    });
  });

  group('CBZ', () {
    test('多图按自然序取第一张（p2 排在 p10 前）', () {
      // 故意把 p10 先放进 zip，证明不是靠字典序/插入序
      final cbz = _zip({'p10.png': _png(10), 'p2.png': _png(2)});

      final cover = bookCoverBytes('cbz', cbz);
      expect(cover, equals(_png(2)));
    });

    test('跳过 __MACOSX 资源叉和超限的页；没有可用页 → null', () {
      final cbz = _zip({'__MACOSX/._p1.png': _png(1), 'p2.png': _png(2)});
      expect(bookCoverBytes('cbz', cbz), equals(_png(2)));

      // 唯一一张图超过 8MB 上限 → 放弃
      final huge = Uint8List(9 * 1024 * 1024);
      huge.setAll(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      final oversized = _zip({'big.png': huge});
      expect(bookCoverBytes('cbz', oversized), isNull);
    });
  });

  group('FB2', () {
    test('coverpage + l:href → base64 binary', () {
      final fb2 = _utf8('''<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"
             xmlns:l="http://www.w3.org/1999/xlink">
  <description><title-info>
    <coverpage><image l:href="#cover.jpg"/></coverpage>
  </title-info></description>
  <body><section><p>正文</p></section></body>
  <binary id="cover.jpg" content-type="image/jpeg">${base64Encode(_jpg(5))}</binary>
</FictionBook>''');

      expect(bookCoverBytes('fb2', fb2), equals(_jpg(5)));
    });

    test('xlink:href 前缀也认；没有 coverpage → null', () {
      final fb2 = _utf8('''<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns:xlink="http://www.w3.org/1999/xlink">
  <description><title-info>
    <coverpage><image xlink:href="#c"/></coverpage>
  </title-info></description>
  <body><section><p>x</p></section></body>
  <binary id="c" content-type="image/png">${base64Encode(_png(6))}</binary>
</FictionBook>''');
      expect(bookCoverBytes('fb2', fb2), equals(_png(6)));

      final noCover = _utf8(
        '<FictionBook><body><section><p>x</p></section></body></FictionBook>',
      );
      expect(bookCoverBytes('fb2', noCover), isNull);
    });
  });

  group('边界', () {
    test('垃圾字节 / 损坏 zip → null（不抛异常）', () {
      final junk = _utf8('this is definitely not a zip archive at all');
      expect(bookCoverBytes('epub', junk), isNull);
      expect(bookCoverBytes('cbz', junk), isNull);
      expect(bookCoverBytes('fb2', junk), isNull);
    });

    test('不支持的扩展名 → null', () {
      final junk = _utf8('anything');
      for (final ext in const ['pdf', 'mobi', 'azw3', 'cbr', 'txt', '']) {
        expect(bookCoverBytes(ext, junk), isNull, reason: ext);
      }
    });

    test('扩展名大小写不敏感', () {
      final cbz = _zip({'p1.png': _png(4)});
      expect(bookCoverBytes('CBZ', cbz), equals(_png(4)));
    });
  });
}
