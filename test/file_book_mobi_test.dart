// MOBI / AZW3（PalmDB）解析 + 接入点的离线测试。
//
// **fixture 全部是代码生成的最小 MOBI 二进制**（PalmDB 头 + 记录索引 + PalmDOC 头
// + MOBI 头 + EXTH + 正文记录 + 图片记录）。不下载任何真实电子书 —— 真实书的
// 覆盖率交给真机那一步，这里负责把**接口与算法**钉死：
// PalmDOC 解压（手写 opcode）、无压缩、EXTH 元数据、章节/目录切分、图片
// recindex 映射、extra data 剥离、CP1252、封面偏移、以及**能力边界**
// （HUFF/CDIC / DRM / KF8 索引缺失的坏文件）必须给"清晰错误"而不是乱码。
// **纯 KF8 的正常重组**在 `test/file_book_mobi_kf8_test.dart`（真实样本 + 自造
// fixture，已与 KindleUnpack 逐字节对照）。
//
// 另有**真实样本**用例（Gutenberg #11，公有领域）：样本只在
// `/tmp/ebook-samples/pg11.mobi` 存在时跑、不存在则 skip，样本不进仓库。
// 它专门盯住自造 fixture 覆盖不到的坑 —— 尾部 extra data 的真实偏移是 record 0
// 的 **0xF2**（自造 fixture 曾跟着实现写在 0xE4，于是单测全绿、真实文件露馅）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/book_cover.dart';
import 'package:synhub/src/features/files/book_mobi.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/file_book_view.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 透明 PNG（够 magic number 判定 + Flutter 解码）
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// 1×1 JPEG 的 magic number 就够解析层认（不解码像素）
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A]);

// ============================================================ MOBI fixture 生成

class _Buf {
  _Buf(this.b);
  final Uint8List b;
  void u16(int o, int v) {
    b[o] = (v >> 8) & 0xFF;
    b[o + 1] = v & 0xFF;
  }

  void u32(int o, int v) {
    b[o] = (v >> 24) & 0xFF;
    b[o + 1] = (v >> 16) & 0xFF;
    b[o + 2] = (v >> 8) & 0xFF;
    b[o + 3] = v & 0xFF;
  }

  void ascii(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      b[o + i] = s.codeUnitAt(i);
    }
  }
}

List<int> _u32b(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

/// EXTH：12 字节头 + 一串 (type, len, value)，每条按 4 字节对齐（对齐算进 len）
Uint8List _exthBytes(Map<int, List<List<int>>> records) {
  final body = <int>[];
  var count = 0;
  records.forEach((type, values) {
    for (final value in values) {
      // len 字段记的是**对齐后**的总长（含自描述的 8 字节）—— 读取方就是按这个值
      // 往后推进，写少了会让后面的记录整体错位（真踩过：作者丢了）。
      var len = 8 + value.length;
      while (len % 4 != 0) {
        len++;
      }
      final rec = <int>[..._u32b(type), ..._u32b(len), ...value];
      while (rec.length < len) {
        rec.add(0);
      }
      body.addAll(rec);
      count++;
    }
  });
  return Uint8List.fromList([
    ...asciiBytes('EXTH'),
    ..._u32b(12 + body.length),
    ..._u32b(count),
    ...body,
  ]);
}

List<int> asciiBytes(String s) => [for (final c in s.codeUnits) c];

/// PalmDB 外壳：78 字节头 + N×8 记录索引 + 记录体
Uint8List _palmDb(List<Uint8List> records, {String name = 'test'}) {
  final header = Uint8List(78);
  final hb = _Buf(header);
  final nm = utf8.encode(name);
  for (var i = 0; i < nm.length && i < 31; i++) {
    header[i] = nm[i];
  }
  hb.ascii(60, 'BOOK');
  hb.ascii(64, 'MOBI');
  hb.u16(76, records.length);

  final table = Uint8List(records.length * 8);
  final tb = _Buf(table);
  var offset = 78 + records.length * 8;
  for (var i = 0; i < records.length; i++) {
    tb.u32(i * 8, offset);
    offset += records[i].length;
  }
  final out = BytesBuilder(copy: false)
    ..add(header)
    ..add(table);
  for (final r in records) {
    out.add(r);
  }
  return out.takeBytes();
}

/// 组装一个结构完整的 MOBI/AZW3。
///
/// 记录顺序 = [record 0][正文记录…][extraRecords…][图片记录…]，与真实文件一致；
/// `firstImageIndex` 据此算出来。
Uint8List buildMobi({
  required List<Uint8List> textRecords,
  int compression = 1,
  int textEncoding = 65001,
  int? textLength,
  int mobiVersion = 6,
  int encryption = 0,
  int extraDataFlags = 0,
  Map<int, List<List<int>>> exth = const {},
  String title = '测试之书',
  List<Uint8List> images = const [],
  int? coverOffset,
  int? kf8Boundary,
  List<Uint8List> extraRecords = const [],
  bool exthFlag = true,
}) {
  final allExth = <int, List<List<int>>>{
    for (final e in exth.entries) e.key: [...e.value],
  };
  if (coverOffset != null) allExth[201] = [_u32b(coverOffset)];
  if (kf8Boundary != null) allExth[121] = [_u32b(kf8Boundary)];
  final exthBlob = _exthBytes(allExth);
  final titleBytes = utf8.encode(title);

  const mobiHeaderLength = 232; // 0xE8，真实文件常见值 → EXTH 落在 16+232
  final header = Uint8List(16 + mobiHeaderLength);
  final b = _Buf(header);
  b.u16(0, compression);
  b.u16(2, 0);
  b.u32(4, textLength ?? textRecords.fold<int>(0, (s, r) => s + r.length));
  b.u16(8, textRecords.length);
  b.u16(10, 4096);
  b.u16(12, encryption);
  b.u16(14, 0);
  b.ascii(16, 'MOBI');
  b.u32(20, mobiHeaderLength);
  b.u32(24, 2); // mobi type = book
  b.u32(28, textEncoding);
  b.u32(32, 0x12345678);
  b.u32(36, mobiVersion);
  b.u32(80, 1 + textRecords.length + extraRecords.length); // firstNonBookIndex
  b.u32(108, images.isEmpty ? 0 : 1 + textRecords.length + extraRecords.length);
  b.u32(128, exthFlag ? 0x40 : 0); // EXTH flags
  // 尾部 extra data 标志：真实位置是 record 0 的 **0xF2**（MOBI 头相对 0xE0）。
  // 曾经写在这里的 0xE4 是 INDX record offset —— 真实文件那里恒为 0，
  // 于是解析器读不到 flags、尾部数据没剥；自造 fixture 跟着写 0xE4 才"全绿"。
  b.u16(0xF2, extraDataFlags);
  final fullNameOffset = 16 + mobiHeaderLength + exthBlob.length;
  b.u32(84, fullNameOffset);
  b.u32(88, titleBytes.length);

  final rec0 = Uint8List.fromList([...header, ...exthBlob, ...titleBytes]);
  return _palmDb([
    rec0,
    ...textRecords,
    ...extraRecords,
    ...images,
  ], name: title);
}

/// 无压缩的单记录 MOBI（最常用）。[html] 已经是**最终字节**（filepos 回填过）。
Uint8List plainMobiBytes(
  List<int> html, {
  String title = '测试之书',
  Map<int, List<List<int>>> exth = const {},
  List<Uint8List> images = const [],
  int? coverOffset,
  int textEncoding = 65001,
}) => buildMobi(
  textRecords: [Uint8List.fromList(html)],
  title: title,
  exth: exth,
  images: images,
  coverOffset: coverOffset,
  textEncoding: textEncoding,
);

/// 同上，但直接收字符串
Uint8List plainMobi(
  String html, {
  String title = '测试之书',
  Map<int, List<List<int>>> exth = const {},
  List<Uint8List> images = const [],
  int? coverOffset,
  int textEncoding = 65001,
}) => plainMobiBytes(
  utf8.encode(html),
  title: title,
  exth: exth,
  images: images,
  coverOffset: coverOffset,
  textEncoding: textEncoding,
);

/// 测试用**最简 PalmDOC 编码器**：只用"字面量串（0x01..0x08）+ 单字节字面量
/// （0x09..0x7F）"两种操作码，不产生距离对。
///
/// 它是 `_palmDocDecompress` 操作码表的严格逆操作（0x09..0x7F 直出，其余字节
/// 每 ≤8 个一组走"原样拷贝"），所以能安全地当作"已知正确的压缩结果"喂给解析器
/// 做端到端往返；距离对那部分由手写 opcode 的用例单独覆盖。
List<int> palmDocEncode(List<int> data) {
  final out = <int>[];
  var i = 0;
  while (i < data.length) {
    final b = data[i];
    if (b >= 0x09 && b <= 0x7f) {
      out.add(b);
      i++;
      continue;
    }
    var n = 0;
    while (i + n < data.length && n < 8) {
      final c = data[i + n];
      if (c >= 0x09 && c <= 0x7f) break;
      n++;
    }
    out.add(n);
    for (var k = 0; k < n; k++) {
      out.add(data[i + k]);
    }
    i += n;
  }
  return out;
}

const _placeholder = '0000000000';

bool _matchesAt(List<int> data, int at, List<int> needle) {
  for (var i = 0; i < needle.length; i++) {
    if (data[at + i] != needle[i]) return false;
  }
  return true;
}

int _byteIndexOf(List<int> data, List<int> needle) {
  for (var i = 0; i + needle.length <= data.length; i++) {
    if (_matchesAt(data, i, needle)) return i;
  }
  return -1;
}

/// 把等宽占位符换成目标的 **UTF-8 字节偏移**，返回最终正文字节。
///
/// ⚠️ `filepos` 是**字节偏移**，不是 Dart `String` 的下标（UTF-16 码元）。中文一个
/// 字 3 字节 / 1 个码元，`raw.indexOf(...)` 算出来的偏移会小一大截 —— 照着切就会
/// 切在半个汉字上，正文从中间断掉、边界冒 `�`。纯 ASCII 的 fixture 会让这个错
/// 完全躲过去，所以这里的目录页和正文**都用中文**。
Uint8List fillFilepos(String raw, List<String> markers) {
  final bytes = utf8.encode(raw);
  final offsets = [
    for (final m in markers) _byteIndexOf(bytes, utf8.encode(m)),
  ];
  for (final o in offsets) {
    expect(o, greaterThan(0), reason: 'fixture 里找不到标记 $markers');
  }
  final placeholder = asciiBytes(_placeholder);
  final out = <int>[];
  var i = 0;
  var k = 0;
  while (i < bytes.length) {
    if (k < offsets.length && _matchesAt(bytes, i, placeholder)) {
      out.addAll(asciiBytes(offsets[k++].toString().padLeft(10, '0')));
      i += placeholder.length;
    } else {
      out.add(bytes[i++]);
    }
  }
  return Uint8List.fromList(out);
}

/// 带**原书目录**的 MOBI：`<guide><reference type="toc" filepos>` + 目录页里的
/// `<a filepos="N">`。filepos 是**字节偏移**（见 [fillFilepos]）。
Uint8List tocMobi() {
  const raw =
      '<html><head><guide><reference type="toc" filepos="$_placeholder">'
      '</guide></head><body>'
      '<h1>目录页</h1>'
      '<a filepos="$_placeholder">第一章 起风了</a><br/>'
      '<a filepos="$_placeholder">第二章 落雨了</a><br/>'
      '<mbp:pagebreak/>'
      '<h1>第一章 起风了</h1><p>第一段正文。</p>'
      '<mbp:pagebreak/>'
      '<h1>第二章 落雨了</h1><p>第二段正文。</p>'
      '</body></html>';
  return plainMobiBytes(
    fillFilepos(raw, ['<h1>目录页', '<h1>第一章', '<h1>第二章']),
    title: '目录之书',
  );
}

/// 没有目录、用 `<mbp:pagebreak>` 分页的 MOBI
Uint8List pagebreakMobi() => plainMobi(
  '<html><head></head><body>'
  '<h1>One</h1><p>a</p>'
  '<mbp:pagebreak/>'
  '<h1>Two</h1><p>b</p>'
  '<mbp:pagebreak/>'
  '<h1>Three</h1><p>c</p>'
  '</body></html>',
);

/// 既没目录也没分页符的大书（触发"按大小切"）
Uint8List bigMobi() {
  final body = StringBuffer('<html><body>');
  // 每个块 ~200 字节，凑到 > 256KB（比阈值大，才能触发按大小切）
  for (var i = 0; i < 1800; i++) {
    body.write('<p>paragraph $i ${'x' * 160}</p>');
  }
  body.write('</body></html>');
  return plainMobi(body.toString());
}

// ============================================================ 阅读页 pump

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/books/$name',
  isDir: false,
  size: 4096,
  mtime: 1700000000000,
);

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  FileEntryDto entry,
  List<int> bytes,
) async {
  final t = FakeTransport(const {}, {...FakeTransport.table});
  t.downloadBytes = bytes;
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(FileStationApi(api)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: FileBookStage(entry: entry, bytesUrl: 'https://nas/x'),
        ),
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (t: t, c: c);
}

void main() {
  group('格式接入（扩展名 → 解析器 → 预览分流）', () {
    test('.mobi / .azw / .azw3 都认，且落到"内嵌阅读"那一档', () {
      expect(bookFormatOf('mobi'), BookFormat.mobi);
      expect(bookFormatOf('MOBI'), BookFormat.mobi);
      expect(bookFormatOf('azw'), BookFormat.mobi);
      expect(bookFormatOf('azw3'), BookFormat.azw3);
      expect(isReadableBook('mobi'), isTrue);
      expect(isReadableBook('azw3'), isTrue);
      expect(filePreviewKind(_entry('a.mobi')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.azw')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.azw3')), FilePreviewKind.book);
      // CBR / CHM / DJVU 都由自研纯 Dart 解压接手（RAR / ITSF+LZX / DJVU）
      expect(isReadableBook('cbr'), isTrue);
      expect(filePreviewKind(_entry('a.cbr')), FilePreviewKind.book);
      expect(isReadableBook('djvu'), isTrue);
      expect(isReadableBook('chm'), isTrue);
      expect(filePreviewKind(_entry('a.djvu')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.chm')), FilePreviewKind.book);
      // 格式名走枚举 label（页脚/进度都用它，没有新增 ARB key）
      expect(BookFormat.mobi.label, 'MOBI');
      expect(BookFormat.azw3.label, 'AZW3');
    });

    test('parseBook 按格式分派：mobi 与 azw3 共用解析器但 format 回填不同', () {
      final m = parseBook(BookFormat.mobi, plainMobi('<body><p>x</p></body>'));
      final a = parseBook(BookFormat.azw3, plainMobi('<body><p>x</p></body>'));
      expect(m.ok, isTrue);
      expect(a.ok, isTrue);
      expect(m.content.format, BookFormat.mobi);
      expect(a.content.format, BookFormat.azw3);
    });
  });

  group('PalmDOC 解压（手写 opcode，逐种操作码覆盖）', () {
    test('五种操作码：字面量串 / 单字节 / 0x00 / 距离-长度对 / 空格优化', () {
      final compressed = <int>[
        0x08, ...asciiBytes('Chapter '), // 0x01..0x08：原样拷贝 8 字节
        0x08, ...asciiBytes('One body'), // 再 8 字节 → "Chapter One body"
        // 0x80..0xBF：distance=5, length=8 → pair=(5<<3)|(8-3)=0x2D
        0x80, 0x2D,
        0x00, // 原样一个 0 字节
        0xE1, // 0xC0..0xFF：空格 + (0xE1^0x80 = 'a')
        0x2E, // 0x09..0x7F：单字节字面量 '.'
      ];
      final out = mobiPalmDocDecode(compressed);
      // 距离对会**重叠展开**：后半段引用的是"刚写进去的字节"，不是原串里的
      expect(
        utf8.decode(out),
        'Chapter One body body bo\u0000 a.',
        reason: 'distance=5/length=8 的重叠复制必须逐字节展开',
      );
    });

    test('距离大于已输出长度 → 停止，不产生乱码', () {
      // 只有 1 个字节，却要往 100 字节之前复制
      final out = mobiPalmDocDecode([0x41, 0x80, 0xFE]);
      expect(utf8.decode(out), 'A');
    });

    test('压缩正文端到端：PalmDOC 记录 → 章节正文正确', () {
      const html =
          '<html><body><h1>压缩之章</h1><p>用 LZ77 压过的正文。</p></body></html>';
      final encoded = palmDocEncode(utf8.encode(html));
      final bytes = buildMobi(
        textRecords: [Uint8List.fromList(encoded)],
        compression: 2,
        textLength: utf8.encode(html).length,
        title: '压缩书',
      );
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue);
      expect(r.content.chapters, hasLength(1));
      expect(r.content.chapters.first.html, contains('压缩之章'));
      expect(r.content.chapters.first.html, contains('用 LZ77 压过的正文。'));
      expect(r.content.title, '压缩书');
    });

    test('压缩类型 1（无压缩）：记录字节就是正文', () {
      final r = parseBook(
        BookFormat.mobi,
        plainMobi('<html><body><h1>未压缩</h1></body></html>'),
      );
      expect(r.ok, isTrue);
      expect(r.content.chapters.first.html, contains('未压缩'));
    });
  });

  group('EXTH 元数据与文字编码', () {
    test('EXTH 503（更新书名）优先，100 取作者', () {
      final bytes = plainMobi(
        '<html><body><h1>章</h1></body></html>',
        title: 'MOBI 头里的名字',
        exth: {
          503: [utf8.encode('EXTH 里的名字')],
          100: [utf8.encode('张三')],
          101: [utf8.encode('某出版社')],
        },
      );
      final b = parseBook(BookFormat.mobi, bytes).content;
      expect(b.title, 'EXTH 里的名字');
      expect(b.author, '张三');
    });

    test('没有 EXTH 503 时退回 MOBI 头的 fullName', () {
      final bytes = plainMobi(
        '<html><body><h1>章</h1></body></html>',
        title: '头的书名',
        exth: {
          100: [utf8.encode('李四')],
        },
      );
      final b = parseBook(BookFormat.mobi, bytes).content;
      expect(b.title, '头的书名');
      expect(b.author, '李四');
    });

    test('EXTH flags 没开时不去读 EXTH（不误伤后面的 fullName）', () {
      final bytes = buildMobi(
        textRecords: [Uint8List.fromList(utf8.encode('<body><p>x</p></body>'))],
        title: '无 EXTH',
        exth: {
          503: [utf8.encode('不该出现')],
        },
        exthFlag: false,
      );
      final b = parseBook(BookFormat.mobi, bytes).content;
      expect(b.title, '无 EXTH');
    });

    test('textEncoding=1252：CP1252 的弯引号/破折号正确解出', () {
      final html = asciiBytes('<html><body><h1>cp1252</h1><p>');
      // 0x93/0x94 = 左右双引号，0x97 = 长破折号
      final body = <int>[...asciiBytes('<p>'), 0x93, 0x41, 0x94, 0x97, 0x42];
      final bytes = buildMobi(
        textRecords: [
          Uint8List.fromList([
            ...html,
            ...body,
            ...asciiBytes('</p></body></html>'),
          ]),
        ],
        textEncoding: 1252,
        title: 'cp1252 书',
      );
      final b = parseBook(BookFormat.mobi, bytes).content;
      expect(b.chapters.first.html, contains('\u201CA\u201D\u2014B'));
    });

    test('UTF-8 中文正文不乱码（byte-offset 与 char-offset 不能混淆）', () {
      final r = parseBook(
        BookFormat.mobi,
        plainMobi('<html><body><h1>中文标题</h1><p>正文字符串。</p></body></html>'),
      );
      expect(r.content.chapters.first.html, contains('中文标题'));
      expect(r.content.chapters.first.html, contains('正文字符串。'));
    });
  });

  group('章节与目录切分', () {
    test('原书目录（guide + <a filepos>）：目录条目 + 切章都对', () {
      final r = parseBook(BookFormat.mobi, tocMobi());
      expect(r.ok, isTrue);
      final b = r.content;
      // 目录页在第一个目标之前，也要作为一段留下来（封面/书名页不丢）
      expect(b.chapters, hasLength(3));
      // 中文标题：在 latin1 空间匹出来的标题必须编回字节重解码，不能是乱码
      expect([for (final e in b.toc) e.title], ['第一章 起风了', '第二章 落雨了']);
      expect([for (final e in b.toc) e.chapterIndex], [1, 2]);
      // 中文章节标题（页脚要显示这个）也不能是乱码
      expect(b.chapters[1].title, '第一章 起风了');
      expect(b.chapters[2].title, '第二章 落雨了');
      expect(b.chapters[1].html, contains('第一段正文。'));
      expect(b.chapters[1].html, isNot(contains('第二段正文。')));
      expect(b.chapters[2].html, contains('第二段正文。'));
      // 字节偏移切出来的片段必须落在字符边界上：没有替换符、没有半个汉字
      for (final c in b.chapters) {
        expect(c.html, isNot(contains('\uFFFD')));
      }
      expect(b.chapters[1].html, contains('<h1>第一章 起风了</h1>'));
      expect(b.chapters[1].html, isNot(contains('<h1>第二章')));
      // 目录链接（`<a filepos>`）变成了书内锚点：目录页里的链接指向第 1/2 段
      final firstTarget = _fileposOf(b.chapters[0].html);
      expect(firstTarget, greaterThan(0));
      expect(b.anchors['#f$firstTarget'], 1);
      expect(
        b.anchors.keys,
        contains('#f${_fileposOf(b.chapters[0].html, 2)}'),
      );
    });

    test('filepos 差几个字节（切在半个汉字上）也不会出乱码', () {
      // 用**字符下标**当 filepos 的自造文件：偏移偏小、正好落在多字节序列中间。
      // 解析器会把它对齐到字符起点，正文不出 `\uFFFD`。
      const raw =
          '<html><head><guide><reference type="toc" filepos="$_placeholder">'
          '</guide></head><body>'
          '<h1>目录页</h1>'
          '<a filepos="$_placeholder">第一章 起风了</a><br/>'
          '<a filepos="$_placeholder">第二章 落雨了</a><br/>'
          '<mbp:pagebreak/>'
          '<h1>第一章 起风了</h1><p>第一段正文。</p>'
          '<mbp:pagebreak/>'
          '<h1>第二章 落雨了</h1><p>第二段正文。</p>'
          '</body></html>';
      // 故意用 String 下标（UTF-16 码元）而不是字节偏移
      final marks = ['<h1>目录页', '<h1>第一章', '<h1>第二章'];
      var k = 0;
      final wrong = raw.replaceAllMapped(RegExp(_placeholder), (_) {
        final off = raw.indexOf(marks[k++]);
        return off.toString().padLeft(10, '0');
      });
      final b = parseBook(BookFormat.mobi, plainMobi(wrong)).content;
      for (final c in b.chapters) {
        expect(c.html, isNot(contains('\uFFFD')));
      }
      expect(b.chapters.last.html, contains('第二段正文。'));
    });

    test('没有目录时退到 <mbp:pagebreak> 分页，标题取第一个 h1', () {
      final b = parseBook(BookFormat.mobi, pagebreakMobi()).content;
      expect(b.chapters, hasLength(3));
      expect([for (final c in b.chapters) c.title], ['One', 'Two', 'Three']);
      // 分页符本身不能留在正文里
      expect(b.chapters.first.html, isNot(contains('mbp:pagebreak')));
      // 没有原书目录 → toc 为空，界面自动退回"按章节列"
      expect(b.toc, isEmpty);
    });

    test('既无目录也无分页、且很大时按大小切（块级边界，不劈开标签）', () {
      final b = parseBook(BookFormat.mobi, bigMobi()).content;
      expect(b.chapters.length, greaterThan(3));
      for (final c in b.chapters) {
        expect(c.html, isNot(contains('<mbp:')));
        // 每段都不该超过"目标 + 一个块"的量级
        expect(c.html.length, lessThan(80 * 1024));
      }
      // 切出来的伪章节用"节"而不是"章"
      expect(b.chapters.first.generatedUnit, BookGeneratedUnit.section);
    });

    test('小书没有目录也不切：单章 + 正文兜底标题', () {
      final b = parseBook(
        BookFormat.mobi,
        plainMobi('<html><body><p>没有标题的正文</p></body></html>'),
      ).content;
      expect(b.chapters, hasLength(1));
      expect(b.chapters.first.generatedUnit, BookGeneratedUnit.body);
      expect(b.chapters.first.html, contains('没有标题的正文'));
    });
  });

  group('图片与封面', () {
    test('图片记录 → resources，<img recindex> 换成可渲染的 src', () {
      final bytes = plainMobi(
        '<html><body><h1>图</h1><img recindex="1" align="middle"></body></html>',
        images: [_png],
      );
      final b = parseBook(BookFormat.mobi, bytes).content;
      expect(b.resources, hasLength(1));
      final key = b.resources.keys.single;
      expect(key, endsWith('.png'));
      expect(b.resources[key], _png);
      expect(b.chapters.first.html, contains('src="$key"'));
      expect(b.chapters.first.html, isNot(contains('recindex')));
    });

    test('多个图片：recindex 按记录顺序映射，扩展名按 magic number', () {
      final bytes = plainMobi(
        '<html><body><img recindex="1"><img recindex="2"></body></html>',
        images: [_png, _jpeg],
      );
      final b = parseBook(BookFormat.mobi, bytes).content;
      expect(b.resources, hasLength(2));
      expect(b.resources.keys.toList()..sort(), [
        'mobi-img-0.png',
        'mobi-img-1.jpg',
      ]);
    });

    test('recindex 指向不存在的记录 → 那个 img 删掉，不崩', () {
      final bytes = plainMobi(
        '<html><body><h1>图</h1><img recindex="9"></body></html>',
        images: [_png],
      );
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue);
      expect(r.content.chapters.first.html, isNot(contains('recindex')));
    });

    test('封面：EXTH 201 → mobiCoverBytes，bookCoverBytes 也认 mobi/azw3', () {
      final bytes = plainMobi(
        '<html><body><p>x</p></body></html>',
        images: [_png],
        coverOffset: 0,
      );
      expect(mobiCoverBytes(bytes), _png);
      expect(bookCoverBytes('mobi', bytes), _png);
      expect(bookCoverBytes('azw3', bytes), _png);
      // 没有 EXTH 201 就没有封面（列表退回分类图标）
      final noCover = plainMobi(
        '<html><body><p>x</p></body></html>',
        images: [_png],
      );
      expect(mobiCoverBytes(noCover), isNull);
      expect(bookCoverBytes('mobi', noCover), isNull);
      // 老后缀 .azw 也走同一条路
      expect(bookCoverBytes('azw', bytes), _png);
    });
  });

  group('extra data 剥离（否则中间记录会混进垃圾字节）', () {
    test('flags=2：尾部数据块被剥掉，两段文字正确拼接', () {
      // 记录 1 = "AAAA" + 尾部块（4 字节载荷 + 1 字节长度 varint）
      // 真实 MOBI 的尾部 varint **最高位为 1 表示结束**（KindleUnpack 同款）：
      // 末字节 0x85 = 值 5；若把终止位写反会读成 0x1DD=477 而误剥正文。
      final rec1 = Uint8List.fromList([
        ...asciiBytes('AAAA'),
        0xAA,
        0xBB,
        0xCC,
        0xDD,
        0x85,
      ]);
      final rec2 = Uint8List.fromList(asciiBytes('BBBB'));
      final bytes = buildMobi(
        textRecords: [rec1, rec2],
        // textLength 是**纯正文**长度：不剥尾部数据的话，前 8 个字节里会混进垃圾
        textLength: 8,
        extraDataFlags: 2,
      );
      final b = parseBook(BookFormat.mobi, bytes).content;
      expect(b.chapters.first.html, contains('AAAABBBB'));
      expect(b.chapters.first.html, isNot(contains('\u00AA\u00BB')));
    });

    test('flags 指向的尾部块读不出来时原样保留（宁多留也不切正文）', () {
      final rec1 = Uint8List.fromList(asciiBytes('AAAA'));
      final bytes = buildMobi(
        textRecords: [rec1],
        extraDataFlags: 0x8000, // bit15：要求读一个 varint，但数据只有 4 字节
        textLength: 4,
      );
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue);
      expect(r.content.chapters.first.html, contains('AAAA'));
    });

    test('flags=3 + 真实尾部编码（00 xx 80 yy 84）→ 正文一字不差', () {
      // 直接照抄真实样本 pg11.mobi 每条正文记录的尾部字节形态：
      // 末字节 0x84 是最低位=1 的结束 varint（值 4），它前面是 0x00（多字节重叠位）。
      // 正确剥离 5 字节后应只剩 "AAAA"；终止位写反会把 0x03 也算进去（读到 388）。
      final rec1 = Uint8List.fromList([
        ...asciiBytes('AAAA'),
        0x00,
        0x86,
        0x80,
        0x03,
        0x84,
      ]);
      final rec2 = Uint8List.fromList(asciiBytes('BBBB'));
      final bytes = buildMobi(
        textRecords: [rec1, rec2],
        textLength: 8,
        extraDataFlags: 3,
      );
      final b = parseBook(BookFormat.mobi, bytes).content;
      // 不剥尾部：前 8 个字节是 "AAAA"+乱码，"BBBB" 会被 textLength 截掉 → 失败
      expect(b.chapters.first.html, contains('AAAABBBB'));
      expect(b.chapters.first.html, isNot(contains('\uFFFD')));
    });
  });

  // 真实样本（Gutenberg #11，公有领域）只在 /tmp 存在时跑，绝不进仓库。
  // 这条路径专门盯住自造 fixture 覆盖不到的坑：**尾部数据标志的真实偏移 0xF2**。
  group('真实样本端到端（/tmp/ebook-samples/pg11.mobi）', () {
    final sample = File('/tmp/ebook-samples/pg11.mobi');
    final missing = sample.existsSync()
        ? null
        : '真实样本 /tmp/ebook-samples/pg11.mobi 不存在';

    test('书名/作者/正文无损：跨记录边界处不混进垃圾字节', () async {
      final bytes = await sample.readAsBytes();
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue);
      expect(r.content.title, contains('Alice'));
      expect(r.content.author, contains('Carroll'));

      final text = r.content.chapters
          .map((c) => c.html)
          .join('\n')
          .replaceAll(RegExp(r'<[^>]*>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ');
      // 没剥尾部数据时，正文每 ~4KB 会混进乱码 —— UTF-8 下就是 U+FFFD
      expect(text.contains('\uFFFD'), isFalse, reason: '正文里出现了替换字符（尾部数据没剥）');
      // 这三段都**跨过记录边界**（4096/8192/12288 字节）
      expect(text, contains('CHAPTER XI. Who Stole the'));
      expect(text, contains('Latitude was, or Longitude either'));
      expect(text, contains('t very few things indeed were really impossible'));
    }, skip: missing);
  });

  group('能力边界：做不到的必须给清晰错误，而不是乱码', () {
    test('HUFF/CDIC（17480）→ unsupportedCompression + 说明，正文为空', () {
      final bytes = buildMobi(
        textRecords: [
          Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        ],
        compression: 17480,
        textLength: 999,
      );
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('HUFF/CDIC'));
      // 关键：**没有**把 Huffman 码流当成正文塞进来
      expect(r.content.chapters, isEmpty);
      expect(r.content.isEmpty, isTrue);
    });

    test('DRM（encryptionType != 0）→ 明确报"带 DRM"', () {
      final bytes = buildMobi(
        textRecords: [Uint8List.fromList(utf8.encode('<body><p>x</p></body>'))],
        encryption: 2,
      );
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('DRM'));
    });

    test('纯 KF8 但 FDST / 索引缺失（坏文件）→ 明确报错，不吐半截正文', () {
      // 纯 KF8 现在**已支持**（见 `test/file_book_mobi_kf8_test.dart`）；这条盯的是
      // "声明是 KF8 但重组所需索引读不出来"的坏文件：必须给清晰错误、正文为空。
      final bytes = buildMobi(
        textRecords: [Uint8List.fromList(utf8.encode('<body><p>x</p></body>'))],
        mobiVersion: 8,
      );
      final r = parseBook(BookFormat.azw3, bytes);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('KF8'));
      expect(r.error, contains('FDST'));
      expect(r.content.chapters, isEmpty);
    });

    // 行为在"joint 优先 KF8"那一批变了：record 0 是 **MOBI6 头（version 6）** +
    // EXTH 121 指向 KF8 半边的才是真 joint；真 joint 且 KF8 半边可用时**优先
    // KF8**（真实样本对照见 `test/file_book_mobi_joint_test.dart`）。这条用
    // "EXTH 121 指向不存在的 KF8 半边"来钉**回落 MOBI6**的安全网。
    test('joint MOBI/KF8（EXTH 121 指向坏的 KF8 半边）→ 回落 MOBI6 半边，能用', () {
      final html =
          '<html><body><h1>MOBI6 兼容部分</h1><p>joint 文件的正文。</p></body></html>';
      final bytes = buildMobi(
        textRecords: [Uint8List.fromList(utf8.encode(html))],
        mobiVersion: 6,
        kf8Boundary: 5, // 这个 record 号不存在 → KF8 半边拿不到
        title: 'joint 书',
      );
      final r = parseBook(BookFormat.azw3, bytes);
      expect(r.ok, isTrue);
      expect(r.content.format, BookFormat.azw3);
      expect(r.content.chapters.first.html, contains('MOBI6 兼容部分'));
    });

    test('未知压缩类型 → 报出类型号，而不是静默空书', () {
      final bytes = buildMobi(
        textRecords: [
          Uint8List.fromList([1, 2, 3]),
        ],
        compression: 99,
      );
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('99'));
    });

    test('坏文件（不是 PalmDB / 不是 MOBI）→ parseFailed，不红屏', () {
      expect(
        parseBook(BookFormat.mobi, utf8.encode('这不是 MOBI')).errorKind,
        BookParseErrorKind.parseFailed,
      );
      final notMobi = _palmDb([Uint8List.fromList(utf8.encode('XXXX' * 40))]);
      expect(
        parseBook(BookFormat.mobi, notMobi).errorKind,
        BookParseErrorKind.parseFailed,
      );
    });

    test('界面文案：能力边界走 i18n 前缀 + 具体原因（没有新增 ARB key）', () {
      final bytes = buildMobi(
        textRecords: [
          Uint8List.fromList([1, 2, 3]),
        ],
        compression: 17480,
      );
      final parsed = parseBook(BookFormat.mobi, bytes);
      final label = bookParseErrorLabel(parsed, AppTextZh());
      expect(label, contains('这个格式还不支持内嵌阅读'));
      // ★ r316c：类型化后按类别说本地化的话；`HUFF/CDIC` 只在 `parsed.error`（进日志）
      expect(label, contains('这种压缩/编码变体本阅读器还没实现'));
      expect(label, isNot(contains('HUFF/CDIC')));
      expect(parsed.error, contains('HUFF/CDIC'));
    });
  });

  group('探针（tool/*.dart 用）', () {
    test('mobiHeaderProbe / mobiSupportProbe 能直接跑', () {
      final bytes = plainMobi(
        '<html><body><h1>章</h1></body></html>',
        exth: {
          503: [utf8.encode('探针书')],
        },
        images: [_png],
        coverOffset: 0,
      );
      final h = mobiHeaderProbe(bytes);
      expect(h['compression'], 1);
      expect(h['encryption'], 0);
      expect(h['encoding'], 65001);
      expect(h['imageCount'], 1);
      expect(h['title'], '探针书');

      final s = mobiSupportProbe(bytes);
      expect(s['ok'], isTrue);
      expect(s['chapters'], 1);
      expect(s['images'], 1);

      // 不支持的输入也不能抛
      expect(mobiHeaderProbe(utf8.encode('nope')), contains('error'));
    });
  });

  group('阅读页（MOBI 走和 EPUB 同一套 BookContent）', () {
    testWidgets('MOBI：显示书名 / 章节 / 正文，翻章可用', (tester) async {
      final b = await _pump(tester, _entry('book.mobi'), tocMobi());
      expect(find.text('目录之书'), findsOneWidget);
      // 3 段（含目录页那一段）
      expect(find.textContaining('第 1/3 章'), findsOneWidget);
      expect(find.textContaining('目录页'), findsWidgets);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('下一章'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('第 2/3 章'), findsOneWidget);
      expect(find.textContaining('第一段正文。', findRichText: true), findsWidgets);
      expect(b.t.downloads, isNotEmpty);
    });

    testWidgets('MOBI：目录面板读的是原书目录，点条目跳章', (tester) async {
      await _pump(tester, _entry('toc.mobi'), tocMobi());
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-toc-list')), findsOneWidget);
      expect(find.text('2 条 · 原书目录'), findsOneWidget);
      expect(find.text('第二章 落雨了'), findsWidgets);

      await tester.tap(find.text('第二章 落雨了').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('第 3/3 章'), findsOneWidget);
      expect(find.textContaining('第二段正文。', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AZW3：KF8 索引缺失（坏文件）给"能力边界"提示，不红屏', (tester) async {
      // 纯 KF8 的**正常**路径已实现；这里刻意用"没有 FDST/skeleton 索引"的
      // fixture 制造坏 KF8，确认界面给清晰提示而不是把半截正文塞进阅读页。
      final kf8Only = buildMobi(
        textRecords: [Uint8List.fromList(utf8.encode('<body><p>x</p></body>'))],
        mobiVersion: 8,
      );
      await _pump(tester, _entry('kf8.azw3'), kf8Only);
      expect(find.textContaining('暂时不能内嵌阅读'), findsOneWidget);
      expect(find.textContaining('这种压缩/编码变体本阅读器还没实现'), findsOneWidget);
      expect(find.textContaining('KF8'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('MOBI：插图渲染成图片而不是"缺失图片"提示', (tester) async {
      final bytes = plainMobi(
        '<html><body><h1>有图</h1><img recindex="1"></body></html>',
        images: [_png],
      );
      await _pump(tester, _entry('img.mobi'), bytes);
      expect(find.byType(Image), findsWidgets);
      expect(find.textContaining('缺失图片'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 取章节里第 [n] 个 filepos 锚点的偏移（用例里做交叉校验）
int _fileposOf(String html, [int n = 1]) {
  final matches = RegExp(r'href="#f(\d+)"').allMatches(html).toList();
  if (matches.length < n) return -1;
  return int.parse(matches[n - 1].group(1)!);
}
