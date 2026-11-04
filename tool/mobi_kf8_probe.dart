// 用**真实纯 KF8 样本**验证自研 KF8 重组（FDST + skeleton/fragment INDX）。
//
// 只调 `lib/src/features/files/book_mobi.dart` 的公开 API，不 import flutter / l10n，
// `dart run` 即可。
//
// 用法：
//   dart run tool/mobi_kf8_probe.dart <book.azw3|book.mobi> [--dump <outdir>]
//
// 输出：KF8 头部字段（FDST/FCIS/FLIS/skeleton/fragment/guide/NCX 记录号）、
// 重组出的 part 数 / 每段字节数 / 合计算出的字节数与字符数、书名作者语言，
// 以及每个 part 的 `<title>`。`--dump` 会把每段 XHTML 写成
// `<outdir>/ourpart%04d.xhtml`，便于与 KindleUnpack 的
// `K8Processor.buildParts` 结果（`refpart%04d.xhtml`）做逐字节对照。
//
// 样本只放 /tmp，不提交进仓库。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/features/files/book_mobi.dart';
import 'package:synhub/src/features/files/file_book.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      '用法: dart run tool/mobi_kf8_probe.dart <book.azw3> [--dump <outdir>]',
    );
    exit(2);
  }
  final path = args[0];
  String? dumpDir;
  final dash = args.indexOf('--dump');
  if (dash >= 0 && dash + 1 < args.length) dumpDir = args[dash + 1];

  final bytes = File(path).readAsBytesSync();
  print('===== KF8 真实样本探针 =====');
  print('样本: $path (${bytes.length} 字节)');

  final h = mobiHeaderProbe(bytes);
  print('头部: $h');
  print('--- 解析结果 ---');
  final s = mobiSupportProbe(bytes);
  print('ok=${s['ok']} error=${s['error']} kind=${s['kind']}');
  print('title=${s['title']} chapters=${s['chapters']} images=${s['images']}');

  final k = mobiKf8Probe(bytes);
  print('--- KF8 重组 ---');
  if (k['ok'] != true) {
    print('重组失败: ${k['error']}');
    return;
  }
  print(
    'rawText=${k['rawText']} flows=${k['flows']} '
    'skeletons=${k['skeletons']} fragments=${k['fragments']}',
  );
  print('parts=${k['parts']}');
  print('partLengths=${k['partLengths']}');
  print(
    'assembledBytes=${k['assembledBytes']} '
    'assembledChars=${k['assembledChars']}',
  );
  print('title=${k['title']} author=${k['author']} language=${k['language']}');
  print('fdst=${k['fdst']}');

  final r = parseMobiBook(bytes, format: bookFormatOf('azw3'));
  var total = 0;
  for (var i = 0; i < r.content.chapters.length; i++) {
    total += r.content.chapters[i].html.length;
    final c = r.content.chapters[i];
    final text = c.html
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    print(
      '  章 ${i + 1}/${r.content.chapters.length} title="${c.title}" '
      '开头80字: ${text.length > 80 ? text.substring(0, 80) : text}',
    );
  }
  print('解析层章节 HTML 合计字符数: $total');

  if (dumpDir != null) {
    final out = Directory(dumpDir)..createSync(recursive: true);
    final parts = mobiKf8Parts(bytes);
    for (var i = 0; i < parts.length; i++) {
      File(
        '${out.path}/ourpart${i.toString().padLeft(4, '0')}.xhtml',
      ).writeAsBytesSync(parts[i]);
    }
    print('已写出 ${parts.length} 段到 $dumpDir');
  }
}
