// LIT / RB / SNB 的离线测试（RB 与 SNB 的正文已实现，LIT 只到精确边界）。
//
//   * RB（Rocket eBook）：正文**已实现**（未压缩 + zlib 压缩页都读）；
//   * SNB：**盛大 Bambook `SNBP000B`** 正文**已实现**（zlib VFAT + bzip2 文本流）；
//     zip/裸 HTML 变体也读；其它 SNB 方言走明确的 unsupportedCompression；
//   * LIT：容器识别 + **精确到 DRM 等级与所需变换**的结论，正文不做；
//   * 做不到的一定走 `BookParseErrorKind.unsupportedCompression`，**明确报错**；
//   * 文件坏了走 `parseFailed`，**绝不吐乱码/半截内容**。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/files/book_cover.dart';
import 'package:synhub/src/features/files/book_lit.dart';
import 'package:synhub/src/features/files/book_rb.dart';
import 'package:synhub/src/features/files/book_snb.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 造一个结构合法的 LIT：主头 + piece 表 + 长度片 + （可选）DRM/变换标记。
///
/// 布局见 `lib/src/features/files/book_lit.dart` 顶部注释：偏移 12 是 **hdr_len**
/// 而不是 ITSF 签名。
Uint8List _lit({
  int version = 1,
  int numPieces = 5,
  int fileLength = 12345,
  String markers = '',
  bool des = false,
  bool lzx = false,
}) {
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void u64(BytesBuilder b, int v) {
    for (var i = 0; i < 8; i++) {
      b.addByte((v >> (8 * i)) & 0xff);
    }
  }

  const hdrLen = 40;
  const secHdrLen = 232;
  final pieceTableEnd = hdrLen + numPieces * 16;
  final sizePieceAt = pieceTableEnd + secHdrLen;

  final body = BytesBuilder();
  // piece 0 = 长度片：u32 tag + u32 version + u64 fileLength
  u32(body, 0x1FE);
  u32(body, 2);
  u64(body, fileLength);
  if (markers.isNotEmpty) body.add(ascii.encode(markers));
  if (des) body.add(_kDesGuidBytes);
  if (lzx) body.add(ascii.encode('LZXC'));
  final bodyBytes = body.takeBytes();

  final out = BytesBuilder();
  out.add(ascii.encode('ITOLITLS'));
  u32(out, version);
  u32(out, hdrLen);
  u32(out, numPieces);
  u32(out, secHdrLen);
  out.add(List.filled(16, 0)); // 文件 GUID
  for (var i = 0; i < numPieces; i++) {
    // piece 0 指向长度片；其余置 0（本层不依赖目录内容）
    u64(out, i == 0 ? sizePieceAt : 0);
    u64(out, i == 0 ? bodyBytes.length : 0);
  }
  out.add(List.filled(secHdrLen, 0));
  out.add(bodyBytes);
  return Uint8List.fromList(out.takeBytes());
}

/// DES 变换 GUID 的小端字节（与解析层保持同一份常量）
const List<int> _kDesGuidBytes = [
  0xA2, 0xE4, 0xF6, 0x67, 0xBF, 0x60, 0xD3, 0x11, //
  0x85, 0x40, 0x00, 0xC0, 0x4F, 0x58, 0xC3, 0xCF,
];

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/books/$name',
  isDir: false,
  size: 2048,
  mtime: 1700000000000,
);

// -------------------------------------------------------------- RB fixture
/// 一个待写进 RB 的 ToC 页
class _RbPage {
  _RbPage(this.name, this.flags, this.text, {this.deflate = false});
  final String name;
  final int flags;
  final String text;
  final bool deflate;
}

/// 造一个最小合法 RB：头（magic/版本/ToC 偏移 0x128）+ ToC + 顺序数据区。
Uint8List _buildRb(List<_RbPage> pages) {
  const tocOffset = 0x128;
  final bodies = <Uint8List>[];
  for (final p in pages) {
    final raw = Uint8List.fromList(utf8.encode(p.text));
    if (!p.deflate) {
      bodies.add(raw);
      continue;
    }
    // 压缩页：pieces + 解压后长度 + 各块压缩长度 + 各块独立 zlib 流
    final z = ZLibEncoder().encode(raw);
    final b = BytesBuilder();
    void u32(int v) =>
        b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    u32(1);
    u32(raw.length);
    u32(z.length);
    b.add(z);
    bodies.add(b.takeBytes());
  }

  var pos = tocOffset + 4 + pages.length * 44;
  final offsets = <int>[];
  for (final b in bodies) {
    offsets.add(pos);
    pos += b.length;
  }

  final hdr = Uint8List(tocOffset);
  hdr.setRange(0, 4, [0xB0, 0x0C, 0xB0, 0x0C]);
  hdr[4] = 2; // version int16 LE = 2
  hdr[5] = 0;
  hdr.setRange(6, 10, ascii.encode('NUVO'));
  hdr[0x0E] = 0xE8; // year 2024
  hdr[0x0F] = 0x07;
  hdr[0x10] = 1;
  hdr[0x11] = 1;
  hdr[0x18] = 0x28; // tocOffset = 0x128
  hdr[0x19] = 0x01;

  final w = BytesBuilder();
  void u32(int v) =>
      w.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  u32(pages.length);
  for (var i = 0; i < pages.length; i++) {
    final name = Uint8List(32);
    final nb = ascii.encode(pages[i].name);
    name.setRange(0, nb.length > 32 ? 32 : nb.length, nb);
    w.add(name);
    u32(bodies[i].length);
    u32(offsets[i]);
    u32(pages[i].flags);
  }
  for (final b in bodies) {
    w.add(b);
  }
  return Uint8List.fromList([...hdr, ...w.takeBytes()]);
}

void main() {
  // ------------------------------------------------------------------ LIT
  group('LIT（容器精确识别 + 明确边界）', () {
    test('合法 ITOLITLS 头 → unsupportedCompression，且说明卡在哪', () {
      final r = parseBook(BookFormat.lit, _lit());
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('ITOLITLS'));
      expect(r.error, contains('evaporated-HTML'));
      expect(r.content.isEmpty, isTrue);
    });

    test('DRM1（sealed）/DRM3（inscribed）/DRM5（EUL）分别报出等级', () {
      final sealed = parseBook(
        BookFormat.lit,
        _lit(markers: '/DRMStorage/DRMSealed'),
      );
      expect(sealed.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(sealed.error, contains('DRM1'));

      final inscribed = parseBook(
        BookFormat.lit,
        _lit(markers: '/DRMStorage/DRMBookplate'),
      );
      expect(inscribed.error, contains('DRM3'));

      final eul = parseBook(
        BookFormat.lit,
        _lit(markers: '/DRMStorage/Licenses/EUL'),
      );
      expect(eul.error, contains('DRM5'));
      expect(eul.error, contains('RSA'));
    });

    test('无 DRM 但带 DES/LZX 变换 → 报出缺的解码器', () {
      final r = parseBook(BookFormat.lit, _lit(des: true, lzx: true));
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('LIT-DES'));
      expect(r.error, contains('MS-LZX'));
    });

    test('不是 LIT 的字节 → parseFailed（不是"假装是 LIT"）', () {
      final r = parseBook(BookFormat.lit, utf8.encode('PK\x03\x04 not lit'));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('头部被截断 / piece 表越界 → parseFailed', () {
      expect(
        parseBook(BookFormat.lit, ascii.encode('ITOL')).errorKind,
        BookParseErrorKind.parseFailed,
      );
      // 声明 5 个 piece 但文件里放不下 piece 表
      final bad = Uint8List.fromList(_lit(numPieces: 5).sublist(0, 60));
      expect(
        parseBook(BookFormat.lit, bad).errorKind,
        BookParseErrorKind.parseFailed,
      );
    });

    test('probe 报告主头 + 长度片 + DRM/变换判定', () {
      final p = litProbe(_lit(fileLength: 12345));
      expect(p['ok'], isTrue);
      expect(p['lit'], isTrue);
      expect(p['version'], 1);
      expect(p['hdrLen'], 40);
      expect(p['numPieces'], 5);
      expect(p['secHdrLen'], 232);
      expect(p['fileLength'], 12345);
      expect(p['drmLevel'], 0);
      expect(p['needsDes'], isFalse);
      expect(litProbe(_lit(des: true))['needsDes'], isTrue);
      expect(litDrmLevel(_lit(markers: '/DRMStorage/DRMBookplate')), 3);
      expect(litProbe(utf8.encode('nope'))['lit'], isFalse);
    });

    test('接入点：扩展名/标签/预览分类', () {
      expect(bookFormatOf('lit'), BookFormat.lit);
      expect(bookFormatOf('LIT'), BookFormat.lit);
      expect(BookFormat.lit.label, 'LIT');
      expect(filePreviewKind(_entry('a.lit')), FilePreviewKind.book);
    });
  });

  // ------------------------------------------------------------------ RB
  group('RB（Rocket eBook：已实现正文）', () {
    test('自造未压缩 RB：info 页给书名/作者，html 页成章', () {
      final bytes = _buildRb([
        _RbPage(
          'info.info',
          0x02,
          'TITLE=RB 之书\nAUTHOR=作者乙\nBODY=index.html\n',
        ),
        _RbPage(
          'index.html',
          0,
          '<html><head><title>第一章 起点</title></head>'
              '<body><h1>第一章 起点</h1><p>RB 正文能读。</p></body></html>',
        ),
      ]);
      final book = parseRbBook(bytes, format: BookFormat.rb);
      expect(book.title, 'RB 之书');
      expect(book.author, '作者乙');
      expect(book.chapters, isNotEmpty);
      final all = book.chapters.map((c) => c.html).join();
      expect(all, contains('RB 正文能读。'));
    });

    test('自造 zlib 压缩页（多块独立流）能解出原文', () {
      const html = '<html><body><h1>Z</h1><p>压缩正文。</p></body></html>';
      final bytes = _buildRb([
        _RbPage('info.info', 0x02, 'TITLE=压缩书\nBODY=a.html\n'),
        _RbPage('a.html', 0x08, html, deflate: true),
      ]);
      final book = parseRbBook(bytes, format: BookFormat.rb);
      expect(book.title, '压缩书');
      expect(book.chapters.map((c) => c.html).join(), contains('压缩正文。'));
    });

    test('加密的正文页 → unsupportedCompression（不解密、不吐乱码）', () {
      final bytes = _buildRb([
        _RbPage('index.html', 0x01, '<html><body>ciphertext</body></html>'),
      ]);
      final r = parseBook(BookFormat.rb, bytes);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('加密'));
      expect(r.content.isEmpty, isTrue);
    });

    test('magic 不对 → parseFailed（不是"假装是 RB"）', () {
      final r = parseBook(BookFormat.rb, utf8.encode('random bytes here'));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('头部过短 → parseFailed', () {
      final r = parseBook(BookFormat.rb, [1, 2, 3]);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('ToC 越界的坏文件 → parseFailed（不崩、不吐半截）', () {
      final good = _buildRb([
        _RbPage('index.html', 0, '<html><body>x</body></html>'),
      ]);
      final bad = Uint8List.fromList(good);
      // 把 ToC 偏移改成一个远超文件长度的值
      bad[0x18] = 0xFF;
      bad[0x19] = 0xFF;
      bad[0x1A] = 0xFF;
      bad[0x1B] = 0x7F;
      final r = parseBook(BookFormat.rb, bad);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('probe 报告 magic/版本/ToC', () {
      final p = rbProbe(
        _buildRb([_RbPage('index.html', 0, '<html><body>x</body></html>')]),
      );
      expect(p['ok'], isTrue);
      expect(p['rb'], isTrue);
      expect(p['magic'], 'b00cb00c');
      expect(p['version'], 2);
      expect(p['entries'], 1);
    });

    test('真实样本（CC0，存在才跑）：lorem-ipsum .rb', () {
      final f = File('/tmp/ebook-samples/lorem-ipsum-0.9.0.rb');
      if (!f.existsSync()) {
        markTestSkipped('样本不存在：${f.path}');
        return;
      }
      final book = parseRbBook(f.readAsBytesSync(), format: BookFormat.rb);
      // 这个样本的 info 页就是 `TITLE= `（空），作者是 Unknown —— 如实断言，
      // 顺便钉住"空值不塞进元数据"。
      expect(book.title, isEmpty);
      expect(book.author, 'Unknown');
      expect(book.chapters, isNotEmpty);
      expect(book.chapters.map((c) => c.html).join(), contains('Lorem ipsum'));
    });

    test('接入点：扩展名/标签/预览分类/封面支持', () {
      expect(bookFormatOf('rb'), BookFormat.rb);
      expect(BookFormat.rb.label, 'RB');
      expect(filePreviewKind(_entry('a.rb')), FilePreviewKind.book);
      expect(bookCoverSupported('rb'), isTrue);
    });
  });

  // ------------------------------------------------------------------ SNB
  group('SNB（能读的容器就读，否则明确结论）', () {
    test('zip 里装 HTML → 真的读得出来', () {
      final bytes = _zip({
        'index.html': utf8.encode(
          '<html><body><h1>SNB 第一章</h1><p>这是能读的正文。</p></body></html>',
        ),
      });
      final book = parseSnbBook(bytes, format: BookFormat.snb);
      expect(book.chapters, isNotEmpty);
      expect(book.chapters.first.html, contains('这是能读的正文。'));
      expect(book.format, BookFormat.snb);
    });

    test('zip 里没有可识别正文 → unsupportedCompression（不吐乱码）', () {
      final bytes = _zip({'data.bin': utf8.encode('binary-ish')});
      final r = parseBook(BookFormat.snb, bytes);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
    });

    test('OLE2 复合文档 → unsupportedCompression，原因明确', () {
      final cfb = Uint8List.fromList([
        0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, //
        ...List.filled(40, 0),
      ]);
      final r = parseBook(BookFormat.snb, cfb);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('OLE2'));
    });

    test('裸 HTML → 当 HTML 读', () {
      final book = parseSnbBook(
        utf8.encode('<html><body><p>裸 HTML 的 SNB。</p></body></html>'),
        format: BookFormat.snb,
      );
      expect(book.chapters, isNotEmpty);
      expect(book.chapters.first.html, contains('裸 HTML 的 SNB。'));
    });

    test('未知二进制 → unsupportedCompression（私有容器，明确不支持）', () {
      final r = parseBook(
        BookFormat.snb,
        Uint8List.fromList(List.generate(64, (i) => i * 3)),
      );
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('SNB'));
    });

    test('头部过短 → parseFailed', () {
      final r = parseBook(BookFormat.snb, [1, 2, 3]);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('probe 报告容器分流', () {
      final zipP = snbProbe(_zip({'index.html': utf8.encode('<p>x</p>')}));
      expect(zipP['zip'], isTrue);
      final cfb = Uint8List.fromList([
        0xD0,
        0xCF,
        0x11,
        0xE0,
        0xA1,
        0xB1,
        0x1A,
        0xE1,
      ]);
      expect(snbProbe(cfb)['cfb'], isTrue);
      final html = utf8.encode('<html><body>y</body></html>');
      expect(snbProbe(html)['html'], isTrue);
    });

    test('接入点：扩展名/标签/预览分类', () {
      expect(bookFormatOf('snb'), BookFormat.snb);
      expect(BookFormat.snb.label, 'SNB');
      expect(filePreviewKind(_entry('a.snb')), FilePreviewKind.book);
    });
  });

  // --------------------------------------------------- SNB：盛大 Bambook 方言
  //
  // 口径修正：真正有公开实现的是 **Bambook `SNBP000B`**（calibre 的
  // `ebooks/snb/snbfile.py`，GPLv3）。容器 = 44 字节大端头 + zlib VFAT +
  // bzip2 的 32KiB 文本块流 + zlib 尾表；正文是 `snbc/*.snbc`。
  group('SNB（Bambook SNBP000B：已实现正文）', () {
    test('自造 Bambook SNB：VFAT + bzip2 文本流 + snbc 正文', () {
      final bytes = _buildSnb([
        _SnbItem.plain(
          'snbc/ch1.snbc',
          '<snbc><head><title>一章</title></head><body>'
              '<text><![CDATA[你好，SNB。]]></text></body></snbc>',
        ),
        _SnbItem.plain(
          'snbf/book.snbf',
          '<book-snbf version="1.0"><head><name>SNB 之书</name>'
              '<author>作者丙</author><cover/></head></book-snbf>',
        ),
        _SnbItem.plain(
          'snbf/toc.snbf',
          '<toc-snbf><head><chapters>1</chapters></head><body>'
              '<chapter src="ch1.snbc">一章</chapter></body></toc-snbf>',
        ),
      ]);
      final book = parseSnbBook(bytes, format: BookFormat.snb);
      expect(book.title, 'SNB 之书');
      expect(book.author, '作者丙');
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.title, '一章');
      expect(book.chapters.first.html, contains('你好，SNB。'));
      expect(book.format, BookFormat.snb);
    });

    test('二进制图片流进 resources，snbc 的 <img> 指向它', () {
      final png = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        ...List.filled(16, 0),
      ]);
      final bytes = _buildSnb([
        _SnbItem.binary('images/cover.png', png),
        _SnbItem.plain(
          'snbc/ch1.snbc',
          '<snbc><head><title>T</title></head><body>'
              '<img>images/cover.png</img>'
              '<text><![CDATA[带图正文]]></text></body></snbc>',
        ),
      ]);
      final book = parseSnbBook(bytes, format: BookFormat.snb);
      expect(book.chapters.first.html, contains('images/cover.png'));
      expect(book.resources['images/cover.png'], png);
      expect(book.resources['cover.png'], png);
    });

    test('SNBP0000（另一种 revision）→ unsupportedCompression，不硬切', () {
      final bytes = Uint8List.fromList([
        ...ascii.encode('SNBP0000'),
        ...List.filled(52, 0),
      ]);
      final r = parseBook(BookFormat.snb, bytes);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('SNBP0000'));
    });

    test('尾部 magic 不匹配 → parseFailed（截断/改动过）', () {
      final good = _buildSnb([
        _SnbItem.plain(
          'snbc/a.snbc',
          '<snbc><body><text><![CDATA[x]]></text></body></snbc>',
        ),
      ]);
      final bad = Uint8List.fromList(good);
      bad[bad.length - 1] = 0x00;
      final r = parseBook(BookFormat.snb, bad);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('VFAT 被破坏（不是 zlib）→ parseFailed', () {
      final good = _buildSnb([
        _SnbItem.plain(
          'snbc/a.snbc',
          '<snbc><body><text><![CDATA[x]]></text></body></snbc>',
        ),
      ]);
      final bad = Uint8List.fromList(good);
      bad[44] = 0xFF;
      bad[45] = 0xFF;
      final r = parseBook(BookFormat.snb, bad);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('probe：bambook=true 且能报出书名/章节数', () {
      final bytes = _buildSnb([
        _SnbItem.plain(
          'snbf/book.snbf',
          '<book-snbf version="1.0"><head><name>P</name><author>A</author>'
              '<cover/></head></book-snbf>',
        ),
        _SnbItem.plain(
          'snbc/a.snbc',
          '<snbc><head><title>t</title></head><body>'
              '<text><![CDATA[x]]></text></body></snbc>',
        ),
      ]);
      expect(snbProbe(bytes)['bambook'], isTrue);
      final p = snbFileProbe(bytes);
      expect(p['ok'], isTrue);
      expect(p['title'], 'P');
      expect(p['author'], 'A');
      expect(p['chapters'], 1);
    });

    test('真实样本（CC0，存在才跑）：lorem-ipsum .snb', () {
      final f = File('/tmp/ebook-samples/lorem-ipsum-0.9.0.snb');
      if (!f.existsSync()) {
        markTestSkipped('样本不存在：${f.path}');
        return;
      }
      final book = parseSnbBook(f.readAsBytesSync(), format: BookFormat.snb);
      expect(book.title, isEmpty); // 样本的 <name> 就是一个空格
      expect(book.chapters, isNotEmpty);
      expect(book.chapters.first.title, 'Start Page');
      expect(book.chapters.map((c) => c.html).join(), contains('Lorem ipsum'));
    });

    test('接入点：封面支持 / fileProbe 摘要', () {
      expect(bookCoverSupported('snb'), isFalse);
      expect(snbFileProbe(utf8.encode('not snb'))['ok'], isFalse);
    });
  });
}

// ------------------------------------------------------------- SNB fixture

/// 一个 Bambook SNB 里的文件
class _SnbItem {
  _SnbItem.plain(this.name, String text)
    : attr = 0x41000000,
      body = Uint8List.fromList(utf8.encode(text));
  _SnbItem.binary(this.name, this.body) : attr = 0x01000000;
  final String name;
  final int attr;
  final Uint8List body;
}

/// 造一个最小合法 `SNBP000B`：大端头 + zlib VFAT + 二进制流 + bzip2 文本块 + zlib 尾表。
Uint8List _buildSnb(List<_SnbItem> items) {
  void putI32(BytesBuilder b, int v) =>
      b.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);

  // VFAT：条目表 + NUL 分隔的名字
  final entries = BytesBuilder();
  final names = BytesBuilder();
  for (final it in items) {
    putI32(entries, it.attr);
    putI32(entries, names.length); // nameOffset（读取方按顺序取，不用它）
    putI32(entries, it.body.length);
    names.add(utf8.encode(it.name));
    names.addByte(0);
  }
  final vfat = Uint8List.fromList([
    ...entries.takeBytes(),
    ...names.takeBytes(),
  ]);
  final vfatCompressed = ZLibEncoder().encode(vfat);

  final binBlob = BytesBuilder();
  final plainBlob = BytesBuilder();
  var binPos = 0;
  var plainPos = 0;
  final tailRecs = BytesBuilder();
  for (final it in items) {
    if (it.attr == 0x41000000) {
      putI32(tailRecs, 0);
      putI32(tailRecs, plainPos);
      plainPos += it.body.length;
      plainBlob.add(it.body);
    } else {
      putI32(tailRecs, 0);
      putI32(tailRecs, binPos);
      binPos += it.body.length;
      binBlob.add(it.body);
    }
  }
  final bin = binBlob.takeBytes();
  final plain = plainBlob.takeBytes();

  // bzip2 文本流（每 32KiB 一块）
  final comp = BytesBuilder();
  final blockOffsets = <int>[];
  final binBlock = (bin.length + 0x7FFF) ~/ 0x8000;
  final plainBlock = (plain.length + 0x7FFF) ~/ 0x8000;
  var plainStart = 44 + vfatCompressed.length + bin.length;
  for (var i = 0; i < plainBlock; i++) {
    final lo = i * 0x8000;
    final hi = (lo + 0x8000) > plain.length ? plain.length : lo + 0x8000;
    blockOffsets.add(plainStart + comp.length);
    comp.add(BZip2Encoder().encode(Uint8List.sublistView(plain, lo, hi)));
  }
  final compressed = comp.takeBytes();

  // 尾表：块偏移 + 每文件的 (blockIndex, contentOffset)
  final tail = BytesBuilder();
  for (var i = 0; i < binBlock; i++) {
    putI32(tail, plainStart);
  }
  for (final off in blockOffsets) {
    putI32(tail, off);
  }
  tail.add(tailRecs.takeBytes());
  final tailZ = ZLibEncoder().encode(tail.takeBytes());
  final tailOffset = plainStart + compressed.length;

  final out = BytesBuilder();
  final header = BytesBuilder();
  header.add(ascii.encode('SNBP000B'));
  putI32(header, 0x00008000);
  putI32(header, 0x00A3A3A3);
  putI32(header, 0);
  putI32(header, items.length);
  putI32(header, vfat.length);
  putI32(header, vfatCompressed.length);
  putI32(header, bin.length);
  putI32(header, plain.length);
  putI32(header, 0);
  out.add(header.takeBytes());
  out.add(vfatCompressed);
  out.add(bin);
  out.add(compressed);
  out.add(tailZ);
  final tailRec = BytesBuilder();
  putI32(tailRec, tailZ.length);
  putI32(tailRec, tailOffset);
  tailRec.add(ascii.encode('SNBP000B'));
  out.add(tailRec.takeBytes());
  return out.takeBytes();
}
