// **纯 KF8（AZW3，无 MOBI6 部分）** 的解析测试。
//
// 分两层：
//   1. **自造 KF8 fixture**（本文件用 Dart 逐字节构造 INDX/TAGX/CTOC/FDST）——
//      不依赖 /tmp，永远跑。它按 KindleUnpack v0.83 的 `K8Processor.buildParts` /
//      `MobiIndex.getIndexData` 语义编码，并且**已经用真实 KindleUnpack 跑过同一份
//      字节布局**：oracle 解出的 2 段 XHTML 与我们逐字节相同（见
//      `docs/ebook-reader-plan.md` §7.10）。
//   2. **真实样本**（`/tmp/ebook-samples/pg11-kf8.azw3` 与同内容不同名的
//      `pg11-images-kf8.mobi`）—— 只在样本存在时跑、不存在则带原因 skip，样本不进仓库。
//      这一层是**独立 oracle**：本机 KindleUnpack 对 `pg11-kf8.azw3` 的
//      `K8Processor.buildParts` 输出是 **19 段 / 234555 字节 / 227412 字符**，
//      我们逐字节相同（SHA256 一致），所以这里把这两个数当作回归钉子。
//
// **falsification（承重断言）**：把 `book_mobi.dart` 里的 KF8 分支改回"直接报错"，
// 下面 `KF8 重组` 与 `真实样本` 两组会立刻红 —— 不是"只覆盖报错路径"的假绿。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/files/book_mobi.dart';
import 'package:synhub/src/features/files/file_book.dart';

// ============================================================ 自造 KF8 fixture

/// 1×1 透明 PNG（够 magic number 判定）
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

List<int> _asciiBytes(String s) => [for (final c in s.codeUnits) c];

List<int> _u16b(int v) => [(v >> 8) & 0xFF, v & 0xFF];

List<int> _u32b(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

/// Kindle 的变长整数：大端 base-128，**最后一个字节最高位置 1**。
List<int> _vw(int x) {
  if (x == 0) return [0x80];
  final out = <int>[];
  var v = x;
  while (v > 0) {
    out.add(v & 0x7F);
    v >>= 7;
  }
  final rev = out.reversed.toList();
  rev[rev.length - 1] |= 0x80;
  return rev;
}

/// INDX 主段：56 字节头 + `TAGX` 标签表；补齐到 0xC0（`parseINDXHeader` 会读到 0xA4）。
Uint8List _indxMain({
  required int entrySections,
  required int nctoc,
  required List<List<int>> tags,
  required int controlByteCount,
}) {
  final hdr = <int>[
    ..._asciiBytes('INDX'),
    ..._u32b(56), // len → TAGX 偏移
    ..._u32b(0), // nul1
    ..._u32b(2), // type
    ..._u32b(0), // gen
    ..._u32b(0), // start
    ..._u32b(entrySections), // count（entry 段数）
    ..._u32b(0), // code
    ..._u32b(65001), // lng
    ..._u32b(0), // total
    ..._u32b(0), // ordt
    ..._u32b(0), // ligt
    ..._u32b(0), // nligt
    ..._u32b(nctoc),
  ];
  assert(hdr.length == 56);
  final tagBody = <int>[for (final t in tags) ...t];
  final main = <int>[
    ...hdr,
    ..._asciiBytes('TAGX'),
    ..._u32b(12 + tagBody.length), // firstEntryOffset
    ..._u32b(controlByteCount),
    ...tagBody,
  ];
  while (main.length < 0xC0) {
    main.add(0);
  }
  return Uint8List.fromList(main);
}

/// INDX entry 段：头（ODRT 区必须是 0）+ 条目 + `IDXT` 偏移表。
Uint8List _indxEntry(List<List<int>> entries) {
  final data = <int>[...List<int>.filled(0xC0, 0)];
  final positions = <int>[];
  for (final e in entries) {
    positions.add(data.length);
    data.addAll(e);
  }
  final idxtPos = data.length;
  data.addAll(_asciiBytes('IDXT'));
  for (final p in positions) {
    data.addAll(_u16b(p));
  }
  void put32(int o, int v) {
    data[o] = (v >> 24) & 0xFF;
    data[o + 1] = (v >> 16) & 0xFF;
    data[o + 2] = (v >> 8) & 0xFF;
    data[o + 3] = v & 0xFF;
  }

  for (var i = 0; i < 4; i++) {
    data[i] = 'INDX'.codeUnitAt(i);
  }
  put32(4, 56);
  put32(12, 2);
  put32(20, idxtPos);
  put32(24, entries.length);
  return Uint8List.fromList(data);
}

/// skeleton 条目：文本名 + 控制字节 `[0x01, 0x01]` + 值 `fragCount/start/length`。
List<int> _skelEntry(String name, int fragCount, int start, int length) {
  final text = _asciiBytes(name);
  return [
    text.length,
    ...text,
    0x01,
    0x01,
    ..._vw(fragCount),
    ..._vw(start),
    ..._vw(length),
  ];
}

/// fragment 条目：文本=插入点 + 控制字节 `[0xFF,0x03,0x01]`
/// + 值 `ctoc偏移(变长字节形式)/fileNum/seqNum/start/length`。
List<int> _fragEntry(
  int insertPos,
  int ctocOffset,
  int start,
  int length,
  int fileNum,
  int seqNum,
) {
  final text = _asciiBytes('$insertPos');
  final v = _vw(ctocOffset);
  return [
    text.length,
    ...text,
    0xFF,
    0x03,
    0x01,
    ..._vw(v.length),
    ...v,
    ..._vw(fileNum),
    ..._vw(seqNum),
    ..._vw(start),
    ..._vw(length),
  ];
}

/// CTOC 段：一串 `变长长度 + 名字字节`，末尾 0；返回 (段字节, 每个名字的偏移)。
({Uint8List data, List<int> offsets}) _ctoc(List<String> names) {
  final data = <int>[];
  final offsets = <int>[];
  for (final n in names) {
    offsets.add(data.length);
    final b = _asciiBytes(n);
    data.addAll(_vw(b.length));
    data.addAll(b);
  }
  data.add(0);
  return (data: Uint8List.fromList(data), offsets: offsets);
}

/// PalmDB 外壳：78 字节头 + N×8 记录索引 + 记录体
Uint8List _palmDb(List<Uint8List> records, {String name = 'SyntheticKF8'}) {
  final header = Uint8List(78);
  final nm = utf8.encode(name);
  for (var i = 0; i < nm.length && i < 31; i++) {
    header[i] = nm[i];
  }
  for (var i = 0; i < 4; i++) {
    header[60 + i] = 'BOOK'.codeUnitAt(i);
    header[64 + i] = 'MOBI'.codeUnitAt(i);
  }
  final rc = _u16b(records.length);
  header[76] = rc[0];
  header[77] = rc[1];
  final table = <int>[];
  var offset = 78 + records.length * 8;
  for (final r in records) {
    table.addAll(_u32b(offset));
    table.addAll(_u32b(0));
    offset += r.length;
  }
  final out = BytesBuilder(copy: false)
    ..add(header)
    ..add(table);
  for (final r in records) {
    out.add(r);
  }
  return out.takeBytes();
}

/// 合成一本**最小纯 KF8**：2 个 skeleton、3 个 fragment、1 个 CSS flow、1 张图。
///
/// 这份字节布局已用真实 KindleUnpack 验证过：oracle 解出
/// `part0 = <html>…<p>first fragment.</p><p>second fragment.</p>…`、
/// `part1 = <html>…<img src="kindle:embed:0001?mime=image/png"/>…`，与
/// [kf8ExpectedPart0] / [kf8ExpectedPart1] 完全一致。
const String kf8ExpectedPart0 =
    '<html><head><title>Test One</title></head><body><h1>One</h1>'
    '<p>first fragment.</p><p>second fragment.</p></body></html>';
const String kf8ExpectedPart1 =
    '<html><head><title>Test Two</title></head><body><h1>Two</h1>'
    '<p>third fragment.</p>'
    '<img src="kindle:embed:0001?mime=image/png"/></body></html>';

/// 造出来的记录表（测试可改某条再 [_palmDb] 重新包，模拟坏文件）。
List<Uint8List> syntheticKf8Records() {
  const skel0 =
      '<html><head><title>Test One</title></head><body><h1>One</h1></body></html>';
  const skel1 =
      '<html><head><title>Test Two</title></head><body><h1>Two</h1></body></html>';
  const frag0 = '<p>first fragment.</p>';
  const frag1 = '<p>second fragment.</p>';
  const frag2 =
      '<p>third fragment.</p><img src="kindle:embed:0001?mime=image/png"/>';
  const css = 'body { margin: 0 }\n';

  final sk0 = 0;
  final frag0b = _asciiBytes(frag0);
  final frag1b = _asciiBytes(frag1);
  final sk1 = _asciiBytes(skel0).length + frag0b.length + frag1b.length;
  final ins0 = sk0 + skel0.indexOf('</body>');
  final ins1 = ins0 + frag0b.length; // 插入后的坐标（与 KindleUnpack 语义一致）
  final ins2 = sk1 + skel1.indexOf('</body>');

  final flow0 = <int>[
    ..._asciiBytes(skel0),
    ...frag0b,
    ...frag1b,
    ..._asciiBytes(skel1),
    ..._asciiBytes(frag2),
  ];
  final flow1 = _asciiBytes(css);
  final raw = <int>[...flow0, ...flow1];

  final ctoc = _ctoc(["P-//*[@aid='0']", "P-//*[@aid='1']", "P-//*[@aid='2']"]);

  final skelTags = <List<int>>[
    [1, 1, 0x01, 0],
    [0, 0, 0x00, 1],
    [6, 2, 0x01, 0],
    [0, 0, 0x00, 1],
  ];
  final fragTags = <List<int>>[
    [2, 1, 0xFF, 0],
    [0, 0, 0x00, 1],
    [3, 1, 0x01, 0],
    [4, 1, 0x02, 0],
    [0, 0, 0x00, 1],
    [6, 2, 0x01, 0],
    [0, 0, 0x00, 1],
  ];

  final skelMain = _indxMain(
    entrySections: 1,
    nctoc: 0,
    tags: skelTags,
    controlByteCount: 2,
  );
  final skelEnt = _indxEntry([
    _skelEntry('SKEL0000000000', 2, sk0, _asciiBytes(skel0).length),
    _skelEntry('SKEL0000000001', 1, sk1, _asciiBytes(skel1).length),
  ]);
  final fragMain = _indxMain(
    entrySections: 1,
    nctoc: 1,
    tags: fragTags,
    controlByteCount: 3,
  );
  final fragEnt = _indxEntry([
    _fragEntry(ins0, ctoc.offsets[0], 0, frag0b.length, 0, 0),
    _fragEntry(ins1, ctoc.offsets[1], frag0b.length, frag1b.length, 0, 1),
    _fragEntry(ins2, ctoc.offsets[2], 0, _asciiBytes(frag2).length, 1, 2),
  ]);

  final fdst = <int>[
    ..._asciiBytes('FDST'),
    ..._u32b(12),
    ..._u32b(2),
    ..._u32b(0),
    ..._u32b(flow0.length),
    ..._u32b(flow0.length),
    ..._u32b(raw.length),
  ];

  // record 0：PalmDOC 前缀 + MOBI8 头（0x108）+ EXTH + 书名
  const headerLen = 0x108;
  List<int> exthRec(int type, List<int> value) {
    var len = 8 + value.length;
    while (len % 4 != 0) {
      len++;
    }
    return [
      ..._u32b(type),
      ..._u32b(len),
      ...value,
      ...List<int>.filled(len - 8 - value.length, 0),
    ];
  }

  final exthBody = <int>[
    ...exthRec(100, _asciiBytes('Synthetic Author')),
    ...exthRec(503, _asciiBytes('Synthetic KF8 Book')),
  ];
  final exth = <int>[
    ..._asciiBytes('EXTH'),
    ..._u32b(12 + exthBody.length),
    ..._u32b(2),
    ...exthBody,
  ];
  final title = _asciiBytes('Synthetic KF8 Book');

  final rec0 = Uint8List(16 + headerLen);
  void put16(int o, int v) {
    rec0[o] = (v >> 8) & 0xFF;
    rec0[o + 1] = v & 0xFF;
  }

  void put32(int o, int v) {
    rec0[o] = (v >> 24) & 0xFF;
    rec0[o + 1] = (v >> 16) & 0xFF;
    rec0[o + 2] = (v >> 8) & 0xFF;
    rec0[o + 3] = v & 0xFF;
  }

  for (var i = 0; i < 4; i++) {
    rec0[16 + i] = 'MOBI'.codeUnitAt(i);
  }
  put16(0, 1); // 压缩 = 不压缩
  put32(4, raw.length); // textLength
  put16(8, 1); // textRecordCount
  put16(12, 0); // encryption
  put32(20, headerLen);
  put32(24, 2); // type = book
  put32(28, 65001); // UTF-8
  put32(36, 8); // mobiVersion = 8（KF8）
  put32(80, 2); // firstNonBookIndex = FDST 记录
  put32(92, 9); // language = en
  put32(108, 8); // firstImageIndex = 记录 8
  put32(128, 0x40); // EXTH flags
  put32(0xC0, 2); // fdst offset
  put32(0xC4, 2); // fdst count
  put32(0xC8, 0xFFFFFFFF); // fcis
  put32(0xCC, 0);
  put32(0xD0, 0xFFFFFFFF); // flis
  put32(0xD4, 0);
  put16(0xF2, 0); // traildata flags
  put32(0xF4, 0xFFFFFFFF); // ncx
  put32(0xF8, 5); // fragment index
  put32(0xFC, 3); // skeleton index
  put32(0x104, 0xFFFFFFFF); // guide

  final titleOff = 16 + headerLen + exth.length;
  put32(84, titleOff);
  put32(88, title.length);

  final rec0Full = Uint8List.fromList([...rec0, ...exth, ...title]);

  return [
    rec0Full,
    Uint8List.fromList(raw),
    Uint8List.fromList(fdst),
    skelMain,
    skelEnt,
    fragMain,
    fragEnt,
    ctoc.data,
    _png,
  ];
}

Uint8List syntheticKf8() => _palmDb(syntheticKf8Records());

/// 真实样本路径（只在 /tmp 存在时跑）
const _kf8Sample = '/tmp/ebook-samples/pg11-kf8.azw3';
const _kf8ImagesSample = '/tmp/ebook-samples/pg11-images-kf8.mobi';

String? _missing(String path) =>
    File(path).existsSync() ? null : '真实样本 $path 不存在';

void main() {
  group('KF8 重组（自造 fixture，字节布局经 KindleUnpack 对照验证）', () {
    test('FDST + skeleton/fragment 索引 → 两段完整 XHTML，逐字节正确', () {
      final r = parseBook(BookFormat.azw3, syntheticKf8());
      expect(r.ok, isTrue, reason: '纯 KF8 现在必须能读（falsification 的关键断言）');
      expect(r.content.format, BookFormat.azw3);
      expect(r.content.title, 'Synthetic KF8 Book');
      expect(r.content.author, 'Synthetic Author');
      expect(r.content.chapters, hasLength(2));
      expect(r.content.chapters[0].title, 'Test One');
      expect(r.content.chapters[1].title, 'Test Two');
      expect(r.content.chapters[0].html, contains('<h1>One</h1>'));
      expect(r.content.chapters[0].html, contains('<p>first fragment.</p>'));
      expect(r.content.chapters[0].html, contains('<p>second fragment.</p>'));
      expect(r.content.chapters[1].html, contains('<p>third fragment.</p>'));

      // 重组层的原始 XHTML 必须与 KindleUnpack `buildParts` 的输出一字不差
      final parts = mobiKf8Parts(syntheticKf8());
      expect(parts.map(utf8.decode).toList(), [
        kf8ExpectedPart0,
        kf8ExpectedPart1,
      ]);
    });

    test('KF8 的 kindle:embed: 图片引用解成 resources 键', () {
      final r = parseBook(BookFormat.azw3, syntheticKf8());
      expect(r.content.resources, hasLength(1));
      final key = r.content.resources.keys.single;
      expect(key, endsWith('.png'));
      expect(r.content.resources[key], _png);
      // 渲染层只认 src；kindle:embed 不能留着
      expect(r.content.chapters[1].html, contains('src="$key"'));
      expect(r.content.chapters[1].html, isNot(contains('kindle:embed')));
    });

    test('mobiKf8Probe 给出重组真值（段数 / 字节数 / 流数）', () {
      final p = mobiKf8Probe(syntheticKf8());
      expect(p['ok'], isTrue);
      expect(p['flows'], 2);
      expect(p['skeletons'], 2);
      expect(p['fragments'], 3);
      expect(p['parts'], 2);
      expect(
        p['assembledBytes'],
        utf8.encode(kf8ExpectedPart0).length +
            utf8.encode(kf8ExpectedPart1).length,
      );
      expect(p['fdst'], [
        0,
        utf8.encode(kf8ExpectedPart0 + kf8ExpectedPart1).length,
      ]);
      expect(p['language'], 9);
    });

    test('头部探针暴露 KF8 专有字段（FDST/skeleton/fragment/索引记录号）', () {
      final h = mobiHeaderProbe(syntheticKf8());
      expect(h['version'], 8);
      expect(h['kf8Boundary'], 0);
      expect(h['fdstOffset'], 2);
      expect(h['fdstCount'], 2);
      expect(h['fragIndex'], 5);
      expect(h['skelIndex'], 3);
      expect(h['fcisOffset'], 0xFFFFFFFF);
      expect(h['flisOffset'], 0xFFFFFFFF);
      expect(h['ncxIndex'], 0xFFFFFFFF);
    });
  });

  group('KF8 能力边界：坏 / 缺索引必须明确报错，不吐半截正文', () {
    test('FDST 记录号缺失 → unsupportedCompression + 正文为空', () {
      final recs = syntheticKf8Records();
      // rec0[0xC0..0xC4] = 0xFFFFFFFF
      recs[0][0xC0] = 0xFF;
      recs[0][0xC1] = 0xFF;
      recs[0][0xC2] = 0xFF;
      recs[0][0xC3] = 0xFF;
      final r = parseBook(BookFormat.azw3, _palmDb(recs));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('FDST'));
      expect(r.content.chapters, isEmpty);
    });

    test('FDST magic 损坏 → 明确报错（不是乱码）', () {
      final recs = syntheticKf8Records();
      for (var i = 0; i < 4; i++) {
        recs[2][i] = 'XXXX'.codeUnitAt(i);
      }
      final r = parseBook(BookFormat.azw3, _palmDb(recs));
      expect(r.ok, isFalse);
      expect(r.error, contains('FDST'));
      expect(r.content.chapters, isEmpty);
    });

    test('skeleton 索引记录号缺失 → 明确报错', () {
      final recs = syntheticKf8Records();
      for (var i = 0; i < 4; i++) {
        recs[0][0xFC + i] = 0xFF;
      }
      final r = parseBook(BookFormat.azw3, _palmDb(recs));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.content.chapters, isEmpty);
    });

    test('fragment 索引被截断（magic 坏）→ 明确报错', () {
      final recs = syntheticKf8Records();
      recs[5][0] = 0x00; // INDX magic 坏掉
      final r = parseBook(BookFormat.azw3, _palmDb(recs));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('fragment'));
      expect(r.content.chapters, isEmpty);
    });

    test('FDST 段数声明超过记录长度 → 明确报错', () {
      final recs = syntheticKf8Records();
      // u32 at 8 = 段数，改成巨大的值
      recs[2][8] = 0x00;
      recs[2][9] = 0x00;
      recs[2][10] = 0xFF;
      recs[2][11] = 0xFF;
      final r = parseBook(BookFormat.azw3, _palmDb(recs));
      expect(r.ok, isFalse);
      expect(r.error, contains('FDST'));
      expect(r.content.chapters, isEmpty);
    });
  });

  // 真实样本（Gutenberg #11，公有领域）只在 /tmp 存在时跑，绝不进仓库。
  // 这一层是**独立 oracle**：KindleUnpack 对 pg11-kf8.azw3 的 buildParts 输出
  // 是 19 段 / 234555 字节 / 227412 字符，我们的输出逐字节相同。
  group('真实样本端到端（纯 KF8，无 MOBI6 部分）', () {
    final missing = _missing(_kf8Sample);
    final missing2 = _missing(_kf8ImagesSample);

    test('pg11-kf8.azw3：识别为纯 KF8、读出完整 XHTML 正文', () async {
      final bytes = File(_kf8Sample).readAsBytesSync();
      final h = mobiHeaderProbe(bytes);
      expect(h['version'], 8);
      expect(h['kf8Boundary'], 0, reason: '没有 EXTH 121 → 不是 joint MOBI/KF8');
      expect(h['fdstOffset'], 73);
      expect(h['fdstCount'], 5);
      expect(h['skelIndex'], 63);
      expect(h['fragIndex'], 60);

      final p = mobiKf8Probe(bytes);
      expect(p['ok'], isTrue);
      expect(p['flows'], 5);
      expect(p['skeletons'], 19);
      expect(p['fragments'], 42);
      expect(p['parts'], 19);
      // ↓ 这两个数是 KindleUnpack `K8Processor.buildParts` 的真值（独立 oracle）
      expect(p['assembledBytes'], 234555);
      expect(p['assembledChars'], 227412);

      final r = parseBook(BookFormat.azw3, bytes);
      expect(r.ok, isTrue);
      expect(r.content.title, "Alice's Adventures in Wonderland");
      expect(r.content.author, 'Lewis Carroll');
      expect(r.content.chapters, hasLength(19));

      final all = r.content.chapters.map((c) => c.html).join('\n');
      // XHTML 结构真的解出来了（标题 + 段落标签）
      expect(all, contains('<h1'));
      expect(all, contains('<h2'));
      expect(all, contains('<p'));
      // PG11 特征串要看**去标签后的纯文本**：书上把书名放在 <span> 里拆开了
      final plain = all
          .replaceAll(RegExp(r'<[^>]*>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(plain, contains('CHAPTER I. Down the Rabbit-Hole'));
      expect(
        plain,
        contains(
          'Alice was beginning to get very tired of sitting by her sister',
        ),
      );
      expect(
        plain,
        contains(
          "The Project Gutenberg eBook of Alice's Adventures in Wonderland",
        ),
      );
      // 解出的正文字符数（非空、量级正确）
      final total = r.content.chapters.fold<int>(
        0,
        (s, c) => s + c.html.length,
      );
      expect(total, greaterThan(200000));
      // 尾部 extra data / 索引边界没有混进正文
      expect(all.contains('\uFFFD'), isFalse, reason: '正文里出现了替换字符');
      final controls = all.runes
          .where((c) => c < 9 || (c > 13 && c < 32))
          .length;
      expect(controls, 0, reason: '正文里混进了控制字符');
    }, skip: missing);

    test('pg11-images-kf8.mobi：同名同内容，结果与 .azw3 一致（交叉断言）', () async {
      final a = File(_kf8Sample).readAsBytesSync();
      final b = File(_kf8ImagesSample).readAsBytesSync();
      final ra = parseBook(BookFormat.mobi, a);
      final rb = parseBook(BookFormat.mobi, b);
      expect(rb.ok, isTrue);
      expect(rb.content.title, ra.content.title);
      expect(rb.content.author, ra.content.author);
      expect(
        rb.content.chapters.map((c) => c.title).toList(),
        ra.content.chapters.map((c) => c.title).toList(),
      );
      expect(
        rb.content.chapters.map((c) => c.html).toList(),
        ra.content.chapters.map((c) => c.html).toList(),
      );
      final p = mobiKf8Probe(b);
      expect(p['assembledBytes'], 234555);
      expect(p['assembledChars'], 227412);
    }, skip: (missing ?? missing2));
  });

  // ------------------------------------------------ KF8 内部链接（kindle:pos:fid）
  //
  // oracle：本机 KindleUnpack v0.83 的 `XHTMLK8Processor.buildXHTML` +
  // `K8Processor.getIDTagByPosFid`。驱动脚本 `/tmp/kf8_link_oracle.py` 对每一条
  // pos:fid 打印 `（fid, off, 目标段 pn, 目标锚点 idtag）`；我们的
  // `mobiKf8LinkProbe` 输出与之**逐条一致**（见 docs/ebook-reader-plan.md 末尾节）。
  group('KF8 内部链接 kindle:pos:fid（真实样本对照 + 降级）', () {
    const jointLinkSample = '/tmp/ebook-samples/libmobi-joint-multimedia.mobi';
    const jointNcxSample = '/tmp/ebook-samples/libmobi-joint-ncx.mobi';
    final missingPg11 = _missing(_kf8Sample);
    final missingJointLink = _missing(jointLinkSample);
    final missingJointNcx = _missing(jointNcxSample);

    test('pg11-kf8.azw3：28 条 pos:fid 全部映射到正确段 + 锚点', () {
      final bytes = File(_kf8Sample).readAsBytesSync();
      final p = mobiKf8LinkProbe(bytes);
      expect(p['ok'], isTrue);
      // KindleUnpack 对同一样本也是 28 条（独立 oracle，不是自证）。
      expect(p['count'], 28);
      expect(p['supported'], 28);
      expect(p['unsupported'], 0);
      final links = (p['links'] as List).cast<Map>();
      // 目录里的章节链接：Contents(part0003) → 第 4 段，锚点 chap01。
      // KindleUnpack oracle：`part 3 ... fid=0004 off=000000001K -> pn=4 idtag=b'chap01'`。
      final c1 = links.firstWhere(
        (e) => e['fid'] == '0004' && e['off'] == '000000001K',
      );
      expect(c1['from'], 'part0003.xhtml');
      expect(c1['part'], 4);
      expect(c1['anchor'], 'chap01');
      // 页脚链接：`fid=0016 off=0000000000 -> pn=17 idtag=b'pg-footer-heading'`。
      final foot = links.firstWhere(
        (e) => e['fid'] == '0016' && e['off'] == '0000000000',
      );
      expect(foot['part'], 17);
      expect(foot['anchor'], 'pg-footer-heading');

      final r = parseBook(BookFormat.azw3, bytes);
      expect(r.ok, isTrue);
      final all = r.content.chapters.map((c) => c.html).join('\n');
      // 改写后正文里不再有 kindle: 内部链接，也没有降级标记。
      expect(all.contains('kindle:pos'), isFalse);
      expect(all.contains('#kf8-unsupported'), isFalse);
      expect(all, contains('part0004.xhtml#chap01'));
      // 外链原样保留。
      expect(all, contains('https://www.gutenberg.org'));
      // anchors 指到正确段；阅读器现成的 anchorFor 能跳过去。
      expect(r.content.anchors['part0004.xhtml#chap01'], 4);
      expect(r.content.anchors['part0017.xhtml#pg-footer-heading'], 17);
      expect(r.content.anchorFor('part0018.xhtml', 'part0004.xhtml#chap01'), 4);
      // 每一段的合成 href 与 anchors 的键前缀一致。
      expect(r.content.chapters[4].href, 'part0004.xhtml');
    }, skip: missingPg11);

    test('joint MOBI/KF8：pos:fid 只到段首时落到段开头（真实样本）', () {
      final bytes = File(jointLinkSample).readAsBytesSync();
      final p = mobiKf8LinkProbe(bytes);
      expect(p['ok'], isTrue);
      expect(p['count'], 1);
      expect(p['supported'], 1);
      final l = (p['links'] as List).cast<Map>().single;
      expect(l['part'], 1);
      expect(l['anchor'], '', reason: 'KindleUnpack 的 getIDTag 对这条也返回空');
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue);
      expect(r.content.anchors, {'part0001.xhtml#kf8-top': 1});
      expect(
        r.content.anchorFor('part0000.xhtml', 'part0001.xhtml#kf8-top'),
        1,
      );
    }, skip: missingJointLink);

    test('无内链的真实样本：零回归（锚点空、正文不含 kindle: 链接）', () {
      final bytes = File(jointNcxSample).readAsBytesSync();
      expect(mobiKf8LinkProbe(bytes)['count'], 0);
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue);
      expect(r.content.anchors, isEmpty);
      final all = r.content.chapters.map((c) => c.html).join('\n');
      expect(all.contains('kindle:'), isFalse);
      expect(all.contains('#kf8-unsupported'), isFalse);
    }, skip: missingJointNcx);

    test('降级：越界 fid / 非法形态不崩、不静默错跳', () {
      // 自造 fixture 覆盖"真实样本里不存在"的坏形态（fragtbl 只有 3 行）。
      final bytes = syntheticKf8();
      final bad = mobiKf8ResolveLink(bytes, '000F', '0000000000');
      expect(bad['ok'], isTrue);
      expect(bad['supported'], isFalse, reason: 'fid=15 越界（只有 3 个 fragment）');
      expect(bad['part'], -1);
      // 同一本书里的合法 fid 能定位（证明上面对照不是恒 null）。
      final good = mobiKf8ResolveLink(bytes, '0', '0');
      expect(good['supported'], isTrue);
      expect(good['part'], 0);
      // 定位不了的链接统一写成 `#kf8-unsupported`：书内锚点形态，
      // 不会走外链（不把 kindle: 交给系统浏览器），阅读器查不到 → 给提示。
      final link = classifyBookLink('part0000.xhtml', '#kf8-unsupported');
      expect(link.kind, BookLinkKind.anchor);
      final r = parseBook(BookFormat.azw3, bytes);
      expect(r.content.anchorFor('part0000.xhtml', '#kf8-unsupported'), isNull);
    });
  });
}
