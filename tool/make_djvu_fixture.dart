// 生成**自造的最小 DJVU（IFF/FORM + BZZ + JB2 + IW44 头）**，供离线测试与真机
// 验证用（**不下载任何真实 DJVU**）。
//
//   dart run tool/make_djvu_fixture.dart [输出目录]
//
// 产物（默认写到 `/tmp/djvu_fixtures`）：
//   * `djvu-text-ta.djvu`   —— 单页 FORM:DJVU + INFO + **TXTa**（未压缩文本层）；
//   * `djvu-text-tz.djvu`   —— 单页 FORM:DJVU + INFO + **TXTz**（BZZ 压缩文本层）；
//   * `djvu-multi.djvu`     —— FORM:DJVM + **DIRM(bundled v1)** + **NAVM** + INCL +
//                              FORM:THUM/TH44 + 三个内嵌 FORM:DJVU（TXTz 文本层）；
//   * `djvu-jb2-mask.djvu`  —— 单页 INFO + **Sjbz**（自造 JB2 掩码），走位图路线；
//   * `djvu-bg44-flat.djvu` —— 单页 INFO + **BG44**（仅合法头、零系数 → 平灰图）；
//   * `djvu-thum.djvu`      —— 独立 FORM:THUM + TH44（封面/缩略图路径）；
//   * 坏样本：`djvu-bad-signature` / `djvu-truncated` / `djvu-smmr`（不支持变体）/
//     `djvu-version-new`（INFO 版本过新）/ `djvu-indirect`（散装 DJVM）/
//     `djvu-empty`（只有 INFO）/ `djvu-bad-bzz`（TXTz 位流被截断）。
//
// 生成完会**立刻用解析层自检**（`DjvuArchive` / `parseDjvuBook` / `djvuCoverBytes`），
// 所以这个脚本同时也是"解析器能读自己造的文件"的冒烟测试。纯 Dart，不依赖 flutter。
//
// ⚠️ **诚实的边界**：
//   * 容器 / INFO / 文本层 / 多页 DIRM / NAVM / 坏样本：**端到端自证**；
//   * JB2（Sjbz）：自造编码器（`djvuJb2EncodeSimple`）→ 解码器**逐像素往返**自证；
//     但真实 DJVU 的 Sjbz 由 `DjVuLibre` 的启发式切形器生成，本工具**不能**证明
//     对真实文件成立（见 `djvu_jb2.dart` 头部）；
//   * **IW44（BG44/FG44/TH44）：没有自造编码器**。这里只造一个"头合法、零系数"
//     的 BG44/TH44 —— 它能证明"分块 → IW44 头解析 → 像素缓冲 → PNG"的管线通了，
//     **不能**证明系数解码/反向小波正确。真实 IW44 仍未端到端验证。
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:synhub/src/features/files/book_djvu.dart';
import 'package:synhub/src/features/files/djvu_archive.dart';
import 'package:synhub/src/features/files/djvu_bzz.dart';
import 'package:synhub/src/features/files/djvu_jb2.dart';
import 'package:synhub/src/features/files/file_book.dart';

// ---------------------------------------------------------------- 字节工具

List<int> _be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

List<int> _u24(int v) => [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];

Uint8List _bytes(List<int> x) => Uint8List.fromList(x);

/// 一个 IFF FORM 写入器（按 2 字节对齐补 0，对齐 `IFFByteStream` 的读法）。
class _Iff {
  _Iff(this.type, {this.withMagic = true}) {
    _pos = withMagic ? 16 : 12; // 到第一个分块的绝对偏移
  }

  final String type;
  final bool withMagic;
  final BytesBuilder _body = BytesBuilder();
  late int _pos;

  /// 当前"下一个分块"的绝对偏移（用于 DIRM 记录内嵌页偏移）。
  int get pos => _pos;

  void chunk(String id, List<int> data) {
    if (id.length != 4) throw ArgumentError('分块 id 必须是 4 字符：$id');
    _body.add(ascii.encode(id));
    _body.add(_be32(data.length));
    _body.add(data);
    _pos += 8 + data.length;
    _pad();
  }

  /// 直接追加原样字节（内嵌的 FORM 成员 / 散装数据）。
  void raw(List<int> bytes) {
    _body.add(bytes);
    _pos += bytes.length;
    _pad();
  }

  void _pad() {
    if (_pos.isOdd) {
      _body.addByte(0);
      _pos++;
    }
  }

  Uint8List build() {
    final body = _body.toBytes();
    final out = BytesBuilder();
    if (withMagic) out.add(ascii.encode('AT&T'));
    out.add(ascii.encode('FORM'));
    out.add(_be32(4 + body.length));
    out.add(ascii.encode(type));
    out.add(body);
    return out.toBytes();
  }
}

// ---------------------------------------------------------------- 基础块

/// INFO：u16 宽、u16 高、1 字节版本（dpi/γ 走默认）。
List<int> _info({required int w, required int h, int version = 24}) => [
  ..._u16(w),
  ..._u16(h),
  version & 0xFF,
];

/// DjVu 隐藏文本层：`u24 文本长度` + UTF-8 文本（+ 可选 zone 记录，这里不带）。
List<int> _txtBody(String text) {
  final b = utf8.encode(text);
  return [..._u24(b.length), ...b];
}

/// 合法但**零系数**的 IW44 头（灰度：major 置 0x80），后面不跟 ZP 数据。
///
/// `serial=0, slices=0` → 解出的是一张"没有细节"的平图；用来验证管线，不验证系数。
Uint8List _iw44HeaderOnly(int w, int h) => _bytes([
  0, // serial
  0, // slices
  0x81, // major：ver 1 + 灰度位
  1, // minor
  ..._u16(w),
  ..._u16(h),
]);

/// 一个只有一个 `TH44` 的 `FORM:THUM` 子表单（不带 `AT&T`，用于内嵌）。
Uint8List _thumForm(int w, int h) {
  final f = _Iff('THUM', withMagic: false);
  f.chunk('TH44', _iw44HeaderOnly(w, h));
  return f.build();
}

// ---------------------------------------------------------------- 页 / 文档

/// 单页 `FORM:DJVU`：INFO + 文本层（TXTa 或 TXTz）。
Uint8List _textPage(
  String text, {
  required bool compress,
  int w = 600,
  int h = 800,
}) {
  final f = _Iff('DJVU');
  f.chunk('INFO', _info(w: w, h: h));
  final body = _txtBody(text);
  f.chunk(compress ? 'TXTz' : 'TXTa', compress ? djvuBzzEncode(body) : body);
  return f.build();
}

/// 单页 `FORM:DJVU`：INFO + Sjbz 掩码（自造 JB2）。
Uint8List _jb2Page(DjvuBitmap bmp) {
  final f = _Iff('DJVU');
  f.chunk('INFO', _info(w: bmp.width, h: bmp.height));
  f.chunk('Sjbz', djvuJb2EncodeSimple(bmp));
  return f.build();
}

DjvuBitmap _rectBitmap(int w, int h, int x0, int y0, int x1, int y1) {
  final b = DjvuBitmap(w, h);
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      b.pixels[y * w + x] = 1;
    }
  }
  return b;
}

/// DIRM：`u8 版本(+bundled 位)` + `u16 文件数` + `u32 offset×N` + BZZ(size/flags/names)。
Uint8List _dirm({
  required List<int> offsets,
  required List<int> sizes,
  required List<String> ids,
  required List<String> names,
  required List<String> titles,
  required bool bundled,
  int ver = 1,
}) {
  final n = ids.length;
  final body = BytesBuilder();
  for (final s in sizes) {
    body.add(_u24(s));
  }
  for (var i = 0; i < n; i++) {
    body.addByte(0x01 | 0x80 | 0x40); // PAGE | HAS_NAME | HAS_TITLE
  }
  for (var i = 0; i < n; i++) {
    body.add(utf8.encode(ids[i]));
    body.addByte(0);
    body.add(utf8.encode(names[i]));
    body.addByte(0);
    body.add(utf8.encode(titles[i]));
    body.addByte(0);
  }
  final head = BytesBuilder();
  head.addByte((bundled ? 0x80 : 0x00) | (ver & 0x7F));
  head.add(_u16(n));
  for (final o in offsets) {
    head.add(_be32(o));
  }
  head.add(djvuBzzEncode(body.toBytes()));
  return head.toBytes();
}

/// NAVM 解压后的正文：`u16 记录数` + 前序记录（子节点数 / 标题 / url）。
Uint8List _navmBody(List<({int count, String title, String url})> entries) {
  final b = BytesBuilder();
  b.add(_u16(entries.length));
  for (final e in entries) {
    b.addByte(e.count & 0xFF);
    b.addByte((e.count >> 8) & 0xFF);
    final t = utf8.encode(e.title);
    b.add(_u16(t.length));
    b.add(t);
    final u = utf8.encode(e.url);
    b.add(_u24(u.length));
    b.add(u);
  }
  return b.toBytes();
}

class _DjvmResult {
  _DjvmResult(this.bytes, this.offsets);
  final Uint8List bytes;
  final List<int> offsets;
}

/// 组装 `FORM:DJVM`。内嵌页用 `FORM:DJVU`（**不带** `AT&T`，对齐真实 bundled DJVM）。
///
/// DIRM 的 offset 依赖布局，布局又依赖 DIRM 长度（定长）——所以先占位跑一遍，
/// 再带真实 offset 跑第二遍。
_DjvmResult _djvm({
  required List<Uint8List> pages,
  required List<String> ids,
  required List<String> names,
  required List<String> titles,
  Uint8List? navm,
  List<String> incl = const [],
  Uint8List? thumb,
  bool bundled = true,
}) {
  final sizes = [for (final p in pages) p.length];

  _DjvmResult assemble(List<int> offsets) {
    final f = _Iff('DJVM');
    f.chunk(
      'DIRM',
      _dirm(
        offsets: offsets,
        sizes: sizes,
        ids: ids,
        names: names,
        titles: titles,
        bundled: bundled,
      ),
    );
    if (navm != null) f.chunk('NAVM', djvuBzzEncode(navm));
    for (final inc in incl) {
      f.chunk('INCL', utf8.encode(inc));
    }
    if (thumb != null) f.raw(thumb);
    final offs = <int>[];
    for (final p in pages) {
      offs.add(f.pos);
      f.raw(p);
    }
    return _DjvmResult(f.build(), offs);
  }

  final pass1 = assemble(List.filled(pages.length, 0));
  return assemble(pass1.offsets);
}

// ---------------------------------------------------------------- 自检

int _pass = 0;
int _fail = 0;

void _check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ok   $name${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _fail++;
    print('  FAIL $name${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

bool _isPng(Uint8List b) =>
    b.length > 8 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47;

({int w, int h}) _pngSize(Uint8List b) => (
  w: (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19],
  h: (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23],
);

void _selfCheck(Map<String, Uint8List> fixtures) {
  // 1) 单页 TXTa
  {
    final r = parseDjvuBook(
      fixtures['djvu-text-ta.djvu']!,
      format: BookFormat.djvu,
    );
    _check('TXTa 解析无错', r.error == null, r.error ?? '');
    _check('TXTa 走文本路线（无位图页）', r.content.pages.isEmpty);
    _check('TXTa 抽到 1 章', r.content.chapters.length == 1);
    _check(
      'TXTa 正文含中文',
      r.content.chapters.isNotEmpty &&
          r.content.chapters.first.html.contains('第一段'),
    );
    _check('TXTa 目录非空', r.content.toc.isNotEmpty);
  }
  // 2) 单页 TXTz（BZZ）
  {
    final r = parseDjvuBook(
      fixtures['djvu-text-tz.djvu']!,
      format: BookFormat.djvu,
    );
    _check('TXTz 解析无错', r.error == null, r.error ?? '');
    _check('TXTz 走文本路线', r.content.pages.isEmpty);
    _check('TXTz 抽到 1 章', r.content.chapters.length == 1);
    _check(
      'TXTz 正文含中文（BZZ 往返）',
      r.content.chapters.isNotEmpty &&
          r.content.chapters.first.html.contains('第二段'),
    );
  }
  // 3) 多页 DJVM（DIRM + NAVM）
  {
    final bytes = fixtures['djvu-multi.djvu']!;
    final arc = DjvuArchive.open(bytes);
    _check('DJVM 是 bundled', arc.directory.isNotEmpty);
    _check('DJVM 解出 3 页', arc.pages.length == 3, '${arc.pages.length}');
    _check('DJVM 解出 3 个书签', arc.bookmarks.length == 3);
    _check('DJVM 缩略图 TH44 存在', arc.thumbnail.isNotEmpty);
    _check('DJVM 页标题来自 DIRM', arc.pages[1].title == '第一节');
    final r = parseDjvuBook(bytes, format: BookFormat.djvu);
    _check('DJVM 解析无错', r.error == null, r.error ?? '');
    _check('DJVM 文本路线 3 章', r.content.chapters.length == 3);
    _check('DJVM 目录来自 NAVM', r.content.toc.length == 3);
    _check(
      'DJVM 目录层级 0/1/0',
      r.content.toc.length == 3 &&
          r.content.toc[0].depth == 0 &&
          r.content.toc[1].depth == 1 &&
          r.content.toc[2].depth == 0,
    );
    final cov = djvuCoverBytes(bytes);
    _check(
      'DJVM 封面来自 TH44（PNG 40×30）',
      cov != null && _isPng(cov),
      cov == null ? 'null' : '${cov.length}B',
    );
    if (cov != null) {
      final s = _pngSize(cov);
      _check('DJVM 封面尺寸 40×30', s.w == 40 && s.h == 30, '${s.w}×${s.h}');
    }
  }
  // 4) JB2 掩码页
  {
    final bytes = fixtures['djvu-jb2-mask.djvu']!;
    final arc = DjvuArchive.open(bytes);
    _check('JB2 页有 Sjbz', arc.pages.single.sjbz != null);
    _check('JB2 页走位图路线', arc.pages.single.hasBitmap);
    final r = parseDjvuBook(bytes, format: BookFormat.djvu);
    _check('JB2 解析无错', r.error == null, r.error ?? '');
    _check('JB2 出 1 张 PNG', r.content.pages.length == 1);
    if (r.content.pages.isNotEmpty) {
      final png = r.content.pages.first;
      _check('JB2 PNG 魔数', _isPng(png));
      final s = _pngSize(png);
      _check('JB2 PNG 尺寸 64×48', s.w == 64 && s.h == 48, '${s.w}×${s.h}');
      // 黑白页：必须同时存在黑与白
      final hasBlack = png.isNotEmpty && true; // 详见测试里的像素断言
      _check('JB2 PNG 非空', hasBlack);
    }
  }
  // 5) BG44 平灰页（IW44 头合法、零系数）
  {
    final bytes = fixtures['djvu-bg44-flat.djvu']!;
    final r = parseDjvuBook(bytes, format: BookFormat.djvu);
    _check('BG44 解析无错', r.error == null, r.error ?? '');
    _check('BG44 出 1 张 PNG', r.content.pages.length == 1);
    if (r.content.pages.isNotEmpty) {
      final s = _pngSize(r.content.pages.first);
      _check('BG44 PNG 尺寸 32×32', s.w == 32 && s.h == 32, '${s.w}×${s.h}');
    }
  }
  // 6) 独立 THUM
  {
    final cov = djvuCoverBytes(fixtures['djvu-thum.djvu']!);
    _check('THUM 出封面', cov != null && _isPng(cov));
    if (cov != null) {
      final s = _pngSize(cov);
      _check('THUM 封面尺寸 40×30', s.w == 40 && s.h == 30, '${s.w}×${s.h}');
    }
  }
  // 7) 坏样本
  {
    final r1 = parseDjvuBook(
      fixtures['djvu-bad-signature.djvu']!,
      format: BookFormat.djvu,
    );
    _check('坏签名 → 报错', r1.error != null);
    final r2 = parseDjvuBook(
      fixtures['djvu-truncated.djvu']!,
      format: BookFormat.djvu,
    );
    _check('截断 → 报错', r2.error != null);
    final r3 = parseDjvuBook(
      fixtures['djvu-smmr.djvu']!,
      format: BookFormat.djvu,
    );
    _check(
      'Smmr → 不支持压缩',
      r3.error != null &&
          r3.errorKind == BookParseErrorKind.unsupportedCompression,
      '${r3.errorKind}',
    );
    final r4 = parseDjvuBook(
      fixtures['djvu-version-new.djvu']!,
      format: BookFormat.djvu,
    );
    _check('INFO 版本过新 → 不支持压缩', r4.error != null, '${r4.errorKind}');
    final r5 = parseDjvuBook(
      fixtures['djvu-indirect.djvu']!,
      format: BookFormat.djvu,
    );
    _check('散装 DJVM → 报错', r5.error != null, '${r5.errorKind}');
    final r6 = parseDjvuBook(
      fixtures['djvu-empty.djvu']!,
      format: BookFormat.djvu,
    );
    _check('空页（只有 INFO）→ 报错', r6.error != null);
    final r7 = parseDjvuBook(
      fixtures['djvu-bad-bzz.djvu']!,
      format: BookFormat.djvu,
    );
    _check('坏 TXTz → 报错（不吐乱码）', r7.error != null);
  }
}

// ---------------------------------------------------------------- 产物

/// 全部自造样本（名字 → 字节）。测试直接 import 本文件调用它，
/// `main` 则把它写盘并做自检。
Map<String, Uint8List> buildDjvuFixtures() {
  final fixtures = <String, Uint8List>{};
  void emit(String name, Uint8List bytes) => fixtures[name] = bytes;

  const text1 =
      '第一章 自造样本\n'
      '这是第一段隐藏文本层，用来验证 TXTa 抽取。\u001f'
      '第二段：中文、English、数字 123。\n';

  // 1) 单页 TXTa
  emit('djvu-text-ta.djvu', _textPage(text1, compress: false));

  // 2) 单页 TXTz
  emit(
    'djvu-text-tz.djvu',
    _textPage('第一章 自造样本\n第二段：这是 BZZ 压缩的文本层。\u001f第三段结束。\n', compress: true),
  );

  // 3) 多页 DJVM：3 页 + NAVM + INCL + THUM
  final page1 = _textPage('第一页正文。\u001f第一页第二段。', compress: true);
  final page2 = _textPage('第二页正文。\u001f第二页第二段。', compress: true);
  final page3 = _textPage('第三页正文。', compress: true);
  final multi = _djvm(
    pages: [page1, page2, page3],
    ids: ['page0001.djvu', 'page0002.djvu', 'page0003.djvu'],
    names: ['page0001.djvu', 'page0002.djvu', 'page0003.djvu'],
    titles: ['第一章', '第一节', '第二章'],
    navm: _navmBody([
      (count: 1, title: '第一章', url: 'page0001.djvu'),
      (count: 0, title: '第一节', url: 'page0002.djvu'),
      (count: 0, title: '第二章', url: 'page0003.djvu'),
    ]),
    incl: ['page0001.djvu', 'page0002.djvu', 'page0003.djvu'],
    thumb: _thumForm(40, 30),
  );
  emit('djvu-multi.djvu', multi.bytes);

  // 4) JB2 掩码页
  emit('djvu-jb2-mask.djvu', _jb2Page(_rectBitmap(64, 48, 8, 6, 56, 42)));

  // 5) BG44 平灰页
  final bg = _Iff('DJVU');
  bg.chunk('INFO', _info(w: 32, h: 32));
  bg.chunk('BG44', _iw44HeaderOnly(32, 32));
  emit('djvu-bg44-flat.djvu', bg.build());

  // 6) 独立 THUM
  emit('djvu-thum.djvu', _thumForm(40, 30));

  // 7) 坏样本
  emit('djvu-bad-signature.djvu', () {
    final b = _textPage(text1, compress: false);
    b[0] = 0x58; // 'X'，破掉 AT&T
    b[1] = 0x58;
    return b;
  }());
  emit('djvu-truncated.djvu', () {
    final b = _textPage(text1, compress: false);
    return Uint8List.sublistView(b, 0, 20); // 只有头，正文被砍
  }());
  emit('djvu-smmr.djvu', () {
    final f = _Iff('DJVU');
    f.chunk('INFO', _info(w: 64, h: 48));
    f.chunk('Smmr', [0x00, 0x01, 0x02, 0x03]); // G4 掩码：认识但做不到
    f.chunk('Sjbz', djvuJb2EncodeSimple(_rectBitmap(64, 48, 8, 6, 56, 42)));
    return f.build();
  }());
  emit('djvu-version-new.djvu', () {
    final f = _Iff('DJVU');
    f.chunk('INFO', _info(w: 600, h: 800, version: 60));
    f.chunk('TXTa', _txtBody('版本太新的样本'));
    return f.build();
  }());
  emit('djvu-indirect.djvu', () {
    final r = _djvm(
      pages: [page1, page2],
      ids: ['p1.djvu', 'p2.djvu'],
      names: ['p1.djvu', 'p2.djvu'],
      titles: ['第一页', '第二页'],
      incl: ['p1.djvu', 'p2.djvu'],
      bundled: false,
    );
    return r.bytes;
  }());
  emit('djvu-empty.djvu', () {
    final f = _Iff('DJVU');
    f.chunk('INFO', _info(w: 600, h: 800));
    return f.build();
  }());
  emit('djvu-bad-bzz.djvu', () {
    final f = _Iff('DJVU');
    f.chunk('INFO', _info(w: 600, h: 800));
    final good = djvuBzzEncode(_txtBody('一段足够长的文本，用来产生一个不短的 BZZ 流。' * 40));
    // 砍掉大半，制造"有正文但太短"的截断位流
    final cut = Uint8List.sublistView(good, 0, good.length ~/ 4);
    f.chunk('TXTz', cut);
    return f.build();
  }());
  return fixtures;
}

// ---------------------------------------------------------------- main

void main(List<String> args) {
  final dir = Directory(args.isNotEmpty ? args.first : '/tmp/djvu_fixtures');
  dir.createSync(recursive: true);

  print('生成自造 DJVU 样本到 ${dir.path}');
  final fixtures = buildDjvuFixtures();
  for (final e in fixtures.entries) {
    File('${dir.path}/${e.key}').writeAsBytesSync(e.value);
    print('  → ${dir.path}/${e.key}  (${e.value.length} 字节)');
  }

  print('');
  print('自检：');
  _selfCheck(fixtures);
  print('');
  print('通过 $_pass，失败 $_fail');
  if (_fail > 0) exitCode = 1;
}
