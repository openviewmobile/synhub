// 生成**自造的最小 MOBI / AZW3**，供真机验证用（不下载任何真实电子书）。
//
//   dart run tool/make_mobi_fixture.dart [输出目录]
//
// 产出：
//   * `mobi-verify.mobi` —— MOBI6：原书目录（`<a filepos>`）+ 两章 + 内置 PNG 插图
//     + 封面（EXTH 201）；
//   * `mobi-verify.azw3` —— 同一个正文，但写成 **joint MOBI/KF8**
//     （mobi version 8 + EXTH 121 边界），验证 AZW3 走 MOBI6 那一半这条路。
//
// 生成完会**立刻用解析层自检**（`mobiSupportProbe`），所以这个脚本同时也是
// "解析器能读自己造的文件"的冒烟测试。纯 Dart，不依赖 flutter。
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:synhub/src/features/files/book_mobi.dart';

// ---------------------------------------------------------------- PNG

List<int> _u32b(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

List<int> asciiBytes(String s) => [for (final c in s.codeUnits) c];

/// 一张**肉眼可见**的棋盘 PNG（1×1 的透明图在截图里看不出来，验证不了"图真的渲染了"）
Uint8List makePng(int w, int h, int rgb) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0); // 每行的 filter type
    for (var x = 0; x < w; x++) {
      final on = ((x ~/ 10) + (y ~/ 10)) % 2 == 0;
      raw.add(
        on
            ? [(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF]
            : [0x18, 0x18, 0x22],
      );
    }
  }
  final out = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  void chunk(String type, List<int> data) {
    out.add(_u32b(data.length));
    out.add(asciiBytes(type));
    out.add(data);
    out.add(_u32b(getCrc32([...asciiBytes(type), ...data])));
  }

  chunk('IHDR', [..._u32b(w), ..._u32b(h), 8, 2, 0, 0, 0]); // 8bit truecolor
  chunk('IDAT', ZLibEncoder().encode(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

// ---------------------------------------------------------------- MOBI 组装

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

Uint8List _exth(Map<int, List<List<int>>> records) {
  final body = <int>[];
  var count = 0;
  records.forEach((type, values) {
    for (final value in values) {
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

Uint8List _palmDb(List<Uint8List> records, String name) {
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

Uint8List buildMobi({
  required List<int> html,
  required String title,
  required String author,
  List<Uint8List> images = const [],
  int mobiVersion = 6,
  int? kf8Boundary,
}) {
  final textRecord = Uint8List.fromList(html);
  final exth = _exth({
    503: [utf8.encode(title)],
    100: [utf8.encode(author)],
    101: [utf8.encode('自造 fixture')],
    if (images.isNotEmpty) 201: [_u32b(0)], // 封面 = firstImageIndex + 0
    if (kf8Boundary != null) 121: [_u32b(kf8Boundary)],
  });
  final titleBytes = utf8.encode(title);

  const headerLength = 232;
  final header = Uint8List(16 + headerLength);
  final b = _Buf(header);
  b.u16(0, 1); // compression = 无压缩
  b.u32(4, textRecord.length); // textLength
  b.u16(8, 1); // 正文记录数
  b.u16(10, 4096);
  b.u16(12, 0); // 无 DRM
  b.ascii(16, 'MOBI');
  b.u32(20, headerLength);
  b.u32(24, 2);
  b.u32(28, 65001); // UTF-8
  b.u32(32, 0xC0FFEE);
  b.u32(36, mobiVersion);
  b.u32(80, 2); // firstNonBookIndex
  b.u32(108, images.isEmpty ? 0 : 2); // 图片从记录 2 开始
  b.u32(128, 0x40); // EXTH flags
  b.u32(84, 16 + headerLength + exth.length); // fullNameOffset
  b.u32(88, titleBytes.length);

  final rec0 = Uint8List.fromList([...header, ...exth, ...titleBytes]);
  return _palmDb([rec0, textRecord, ...images], title);
}

// ---------------------------------------------------------------- 正文

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

/// 把正文里的等宽占位符换成目标的 **UTF-8 字节偏移**，返回最终字节。
///
/// ⚠️ 关键：`filepos` 是**字节偏移**，不是 Dart `String` 的下标（UTF-16 码元）。
/// 中文一个字 3 字节 / 1 个码元，用 `raw.indexOf(...)` 算出来的偏移会小一大截，
/// 解析器照着切就会切在半个汉字上（真机上就是这么发现解析层没错、fixture 错了）。
Uint8List fillFilepos(String raw, List<String> markers) {
  final bytes = utf8.encode(raw);
  final offsets = [
    for (final m in markers) _byteIndexOf(bytes, utf8.encode(m)),
  ];
  for (final o in offsets) {
    if (o < 0) throw StateError('fixture 里找不到标记，占位符不会对齐');
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

/// 带原书目录的 MOBI6 正文
Uint8List fixtureHtml() {
  const raw =
      '<html><head><guide><reference type="toc" filepos="$_placeholder">'
      '</guide></head><body>'
      '<h1>目录</h1>'
      '<p><a filepos="$_placeholder">第一章 MOBI 验证</a></p>'
      '<p><a filepos="$_placeholder">第二章 图片与目录</a></p>'
      '<mbp:pagebreak/>'
      '<h1>第一章 MOBI 验证</h1>'
      '<p>这是一本<strong>自造的最小 MOBI</strong>，用来在真机上验证'
      '电子书格式批次里的 MOBI 解析：PalmDB 容器、EXTH 元数据、章节切分、'
      '以及图片记录里的插图。</p>'
      '<img recindex="1">'
      '<p>上面那张棋盘图来自 MOBI 的图片记录（<code>recindex="1"</code>）。</p>'
      '<mbp:pagebreak/>'
      '<h1>第二章 图片与目录</h1>'
      '<p>如果你能在目录面板里看到两条「原书目录」，并且点得动，'
      '说明 <code>&lt;a filepos&gt;</code> 链接已经换成书内锚点了。</p>'
      '</body></html>';

  return fillFilepos(raw, ['<h1>目录', '<h1>第一章', '<h1>第二章']);
}

// ---------------------------------------------------------------- main

Future<void> main(List<String> args) async {
  final dir = Directory(args.isEmpty ? '/tmp/mobi-verify' : args.first);
  await dir.create(recursive: true);

  final png = makePng(240, 120, 0x4F8CFF);
  final html = fixtureHtml();

  final files = <String, Uint8List>{
    'mobi-verify.mobi': buildMobi(
      html: html,
      title: 'MOBI 验证之书',
      author: 'AutoProbe',
      images: [png],
    ),
    // joint MOBI/KF8：version 8 + EXTH 121 边界 → 解析器读 MOBI6 那一半
    'mobi-verify.azw3': buildMobi(
      html: html,
      title: 'AZW3 验证之书（joint MOBI/KF8）',
      author: 'AutoProbe',
      images: [png],
      mobiVersion: 8,
      kf8Boundary: 3,
    ),
  };

  for (final e in files.entries) {
    final path = '${dir.path}/${e.key}';
    await File(path).writeAsBytes(e.value);
    final probe = mobiSupportProbe(e.value);
    print('$path  ${e.value.length} B');
    print('  自检：$probe');
    if (probe['ok'] != true) {
      stderr.writeln('!! 解析层读不了自己造的文件，fixture 有问题');
      exit(1);
    }
  }
  print(
    '\n封面（EXTH 201）自检：'
    '${mobiCoverBytes(files['mobi-verify.mobi']!)?.length} B',
  );
  exit(0);
}
