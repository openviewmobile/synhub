// **joint MOBI/KF8** 的离线探针 + KindleUnpack oracle 逐段 sha256 对照。
//
// 用法：
//   dart run tool/mobi_joint_probe.dart <book.mobi> [--ref <dir>]
//
// `--ref <dir>` 指向 KindleUnpack `K8Processor.buildParts` 的产物目录（每个 part
// 一个 `refpart%04d.xhtml`）。工具把仓库解析器 `mobiKf8Parts()` 的结果逐段算
// sha256，与参考目录里的同名文件比对，并打印拼接 sha256 / 字节数。
//
// 等价的 oracle 驱动（本机已跑过；结果见 docs/`ebook-formats-research.md`）：
//   * `python3 /tmp/kf8_joint_ref.py <joint.mobi> <outdir>`（joint 版：扫 8 字节
//     `BOUNDARY` → 从 boundary+1 起 `MobiHeader` + `K8Processor.buildParts`）；
//   * 纯 KF8 仍可用 `/tmp/kf8_ref.py`。
// 样本只放宿主 /tmp，不进仓库；本工具不联网、不碰设备。
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import 'package:synhub/src/features/files/book_mobi.dart';
import 'package:synhub/src/features/files/file_book.dart';

String _sha256(List<int> b) => SHA256Digest()
    .process(b is Uint8List ? b : Uint8List.fromList(b))
    .map((x) => x.toRadixString(16).padLeft(2, '0'))
    .join();

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      '用法: dart run tool/mobi_joint_probe.dart <book.mobi> [--ref <dir>]',
    );
    exit(2);
  }
  final path = args[0];
  final refIdx = args.indexOf('--ref');
  final refDir = refIdx >= 0 && refIdx + 1 < args.length
      ? args[refIdx + 1]
      : null;

  final bytes = File(path).readAsBytesSync();
  print('===== joint MOBI/KF8 探针 =====');
  print('样本: $path (${bytes.length} 字节)');
  print('头部(record 0): ${mobiHeaderProbe(bytes)}');

  final k = mobiKf8Probe(bytes);
  print('--- KF8 半边 ---');
  print(
    'ok=${k['ok']} joint=${k['joint']} kf8Start=${k['kf8Start']} '
    'rawText=${k['rawText']}',
  );
  if (k['ok'] != true) {
    print('KF8 重组失败: ${k['error']}');
  } else {
    print(
      'flows=${k['flows']} skeletons=${k['skeletons']} '
      'fragments=${k['fragments']} parts=${k['parts']}',
    );
    print(
      'assembledBytes=${k['assembledBytes']} '
      'assembledChars=${k['assembledChars']} title=${k['title']}',
    );
    print('fdst=${k['fdst']} toc=${k['toc']}');
  }

  final t = mobiTocProbe(bytes);
  print('--- 目录 ---');
  print('source=${t['source']} count=${t['count']}');
  final entries = t['entries'];
  if (entries is List) {
    for (final e in entries) {
      print('  $e');
    }
  }

  // 解析层端到端（章节标题）
  final r = parseMobiBook(bytes, format: bookFormatOf('mobi'));
  print('--- 解析层 ---');
  print(
    'ok=${r.ok} title=${r.content.title} chapters=${r.content.chapters.length} '
    'toc=${r.content.toc.length}',
  );
  for (var i = 0; i < r.content.chapters.length; i++) {
    print(
      '  章 ${i + 1}/${r.content.chapters.length} "${r.content.chapters[i].title}"',
    );
  }

  if (refDir == null || k['ok'] != true) return;
  print('--- oracle 逐段对照 ($refDir) ---');
  final parts = mobiKf8Parts(bytes);
  final refFiles =
      Directory(refDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.split('/').last.startsWith('refpart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (refFiles.length != parts.length) {
    print('!! 段数不一致：ours=${parts.length} ref=${refFiles.length}');
  }
  var ok = true;
  for (var i = 0; i < parts.length && i < refFiles.length; i++) {
    final a = _sha256(parts[i]);
    final b = _sha256(refFiles[i].readAsBytesSync());
    final same = a == b;
    ok &= same;
    print('part $i ${same ? 'MATCH' : 'DIFF '} $a');
  }
  final ours = _sha256([for (final p in parts) ...p]);
  final ref = _sha256([for (final f in refFiles) ...f.readAsBytesSync()]);
  print('concat ${ours == ref ? 'MATCH' : 'DIFF '} $ours');
  print(ok && ours == ref ? '全部一致 ✅' : '有差异 ❌');
}
