// RAR / CBR 探针（开发与真机取证用）：解析一个 RAR 文件，列出条目并校验解压。
//
// 用法：`dart run tool/rar_probe.dart <a.rar> [b.rar ...]`
import 'dart:io';
import 'dart:typed_data';

import 'package:synhub/src/features/files/rar_archive.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/rar_probe.dart <a.rar> ...');
    exit(2);
  }
  for (final path in args) {
    print('=== $path');
    final bytes = File(path).readAsBytesSync();
    print('签名: ${RarArchive.isRar(bytes)}  大小: ${bytes.length}');
    try {
      final archive = RarArchive.open(bytes);
      print('版本: RAR ${archive.version}.x  固实: ${archive.isSolid}');
      for (final e in archive.entries) {
        print(
          '  ${e.isDir ? 'D' : 'F'} ${e.name}  '
          'packed=${e.packedSize} unpacked=${e.unpackedSize} '
          'method=${e.method} ver=${e.unpackVersion} solid=${e.solid} '
          'enc=${e.encrypted} crc=${e.crc32?.toRadixString(16)}',
        );
      }
      final only = <String>{
        for (final e in archive.entries)
          if (!e.isDir &&
              RegExp(
                r'\.(png|jpe?g|gif|webp|bmp)$',
                caseSensitive: false,
              ).hasMatch(e.name))
            e.name,
      };
      print('图片条目: ${only.length}');
      final data = archive.extract(only: only);
      for (final k in data.keys) {
        final b = data[k]!;
        print('  解出 $k: ${b.length} B  magic=${_magic(b)}');
      }
      print('全部条目解压校验…');
      final all = archive.extract();
      print(
        'OK：${all.length} 个文件，共 ${all.values.fold<int>(0, (a, b) => a + b.length)} B',
      );
    } on RarUnsupportedException catch (e) {
      print('能力边界：${e.message}');
    } on RarFormatException catch (e) {
      print('文件损坏：${e.message}');
    }
  }
}

String _magic(Uint8List b) {
  if (b.length < 4) return '(短)';
  return b
      .sublist(0, 4)
      .map((v) => v.toRadixString(16).padLeft(2, '0'))
      .join(' ');
}
