// 电子书「格式补漏批」的**宿主探针**：不连 NAS、不碰设备，直接对 /tmp 下的样本跑解析层。
//
// 用法：
//   dart run tool/book_new_formats_probe.dart
//
// 样本（公开许可，**不进仓库**；缺了就跳过并打印说明）：
//   /tmp/ebook-samples/sample-unicode-huffdic.mobi  libmobi 测试夹具（LGPL-3.0-or-later）
//   /tmp/ebook-samples/lorem-ipsum-0.9.0.rb         openpreserve/format-corpus（CC0）
//   /tmp/ebook-samples/lorem-ipsum-0.9.0.snb        同上（CC0）
//
// 这个探针同时是"解析层是**纯 Dart**"的证据：它 import 的解析层里没有任何
// `package:flutter` / `l10n.dart`，所以 `dart run` 能直接跑起来。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/features/files/book_lit.dart';
import 'package:synhub/src/features/files/book_mobi.dart';
import 'package:synhub/src/features/files/book_rb.dart';
import 'package:synhub/src/features/files/book_snb.dart';
import 'package:synhub/src/features/files/file_book.dart';

int _pass = 0;
int _fail = 0;
int _skip = 0;

void _check(String label, bool ok, [Object? detail]) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail == null ? '' : '  ($detail)'}');
  } else {
    _fail++;
    print('  ❌ $label${detail == null ? '' : '  ($detail)'}');
  }
}

void _skipCase(String label, String why) {
  _skip++;
  print('  ⏭  $label  — $why');
}

void main() {
  const dir = '/tmp/ebook-samples';
  print('== 电子书格式补漏批 · 宿主探针 ==\n');

  print('[HUFF/CDIC] sample-unicode-huffdic.mobi');
  final huff = File('$dir/sample-unicode-huffdic.mobi');
  if (!huff.existsSync()) {
    _skipCase('HUFF/CDIC', '样本不存在');
  } else {
    final bytes = huff.readAsBytesSync();
    final head = mobiHeaderProbe(bytes);
    print('  header: $head');
    print('  huff  : ${mobiHuffProbe(bytes)}');
    _check('compression == 17480', head['compression'] == 17480);
    _check('字典短语数 == 347', mobiHuffProbe(bytes)['phrases'] == 347);
    final r = parseBook(BookFormat.mobi, bytes);
    _check('parseBook ok', r.ok, r.error);
    final text = r.content.chapters.map((c) => c.html).join('\n');
    _check('正文含 "libmobi"', text.contains('libmobi'));
    _check(
      '正文长度 > 100000 标称吗（html 已转义，只看非空）',
      text.isNotEmpty,
      '${text.length} 字符',
    );
  }

  print('\n[RB] lorem-ipsum-0.9.0.rb');
  final rb = File('$dir/lorem-ipsum-0.9.0.rb');
  if (!rb.existsSync()) {
    _skipCase('RB', '样本不存在');
  } else {
    final bytes = rb.readAsBytesSync();
    print('  probe : ${rbProbe(bytes)}');
    final book = parseRbBook(bytes, format: BookFormat.rb);
    print(
      '  title="${book.title}" author="${book.author}" chapters=${book.chapters.length}',
    );
    final html = book.chapters.map((c) => c.html).join('\n');
    _check('作者 == Unknown', book.author == 'Unknown');
    _check('正文含 "Lorem ipsum"', html.contains('Lorem ipsum'));
  }

  print('\n[SNB/Bambook] lorem-ipsum-0.9.0.snb');
  final snb = File('$dir/lorem-ipsum-0.9.0.snb');
  if (!snb.existsSync()) {
    _skipCase('SNB', '样本不存在');
  } else {
    final bytes = snb.readAsBytesSync();
    print('  probe : ${snbProbe(bytes)}');
    print('  file  : ${snbFileProbe(bytes)}');
    final book = parseSnbBook(bytes, format: BookFormat.snb);
    final html = book.chapters.map((c) => c.html).join('\n');
    _check('章节标题 == Start Page', book.chapters.first.title == 'Start Page');
    _check('正文含 "Lorem ipsum"', html.contains('Lorem ipsum'));
  }

  print('\n[LIT] 无真实样本；只验头部分流（自造最小头）');
  final litHead = <int>[
    ...'ITOLITLS'.codeUnits,
    1, 0, 0, 0, // version
    40, 0, 0, 0, // hdr_len
    5, 0, 0, 0, // num_pieces
    232, 0, 0, 0, // sec_hdr_len
    ...List.filled(16, 0),
    ...List.filled(40 + 5 * 16 + 232, 0),
  ];
  final r = parseBook(BookFormat.lit, litHead);
  print('  probe : ${litProbe(litHead)}');
  _check(
    '不是 LIT 的字节 → parseFailed',
    parseBook(BookFormat.lit, 'nope'.codeUnits).errorKind ==
        BookParseErrorKind.parseFailed,
  );
  _check(
    'LIT 头 → unsupportedCompression',
    r.errorKind == BookParseErrorKind.unsupportedCompression,
    r.error,
  );

  print('\n== 结果：$_pass 通过 / $_fail 失败 / $_skip 跳过 ==');
  if (_fail > 0) exitCode = 1;
}
