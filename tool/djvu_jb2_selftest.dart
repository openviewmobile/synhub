// JB2 解码器自测（scratch，不在 `lib/` 分析树里，可随意改）。
//
//   export PATH="<flutter-sdk>/bin:$PATH"
//   dart run tool/djvu_jb2_selftest.dart
//   dart run tool/djvu_jb2_selftest.dart --emit   # 导出我的编码结果供 C++ 反解
//
// 覆盖：
//   1) 空/垃圾/截断字节 → 明确的 DJVU 异常（不吐乱码）；
//   2) 自造编码器 `djvuJb2EncodeSimple` ↔ 本解码器逐像素往返；
//   3) 如果 /tmp/jb2build 下存在本地编译的 DjVuLibre 参考样本
//      （`ref_dict.jbz` / `ref_img_*.jb2` + `.raw`），做端到端交叉验证：
//      参考编码 → 我的解码，逐像素比对。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:synhub/src/features/files/djvu_errors.dart';
import 'package:synhub/src/features/files/djvu_jb2.dart';

int _failures = 0;

void ok(bool cond, String what) {
  if (cond) {
    stdout.writeln('  ok   $what');
  } else {
    _failures++;
    stdout.writeln('  FAIL $what');
  }
}

void section(String s) {
  stdout.writeln('\n== $s ==');
}

// ------------------------------------------------------------ 图案

int _seed = 0x12345678;
int _rand() {
  _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
  return _seed;
}

DjvuBitmap _pattern(int w, int h, bool Function(int x, int y) f) {
  final b = DjvuBitmap(w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (f(x, y)) b.pixels[y * w + x] = 1;
    }
  }
  return b;
}

List<(String, DjvuBitmap)> _patterns() => <(String, DjvuBitmap)>[
  (
    'checkerboard 63x47',
    _pattern(63, 47, (x, y) => ((x ~/ 4) + (y ~/ 4)) % 2 == 0),
  ),
  (
    'filled rectangle 40x30',
    _pattern(40, 30, (x, y) => x >= 5 && x < 35 && y >= 4 && y < 26),
  ),
  ('diagonal line 50x50', _pattern(50, 50, (x, y) => x == y || x == y + 1)),
  ('random noise 37x29', _pattern(37, 29, (x, y) => _rand() % 3 == 0)),
  ('tiny 3x2', _pattern(3, 2, (x, y) => !(x == 1 && y == 0))),
];

bool _samePixels(DjvuBitmap a, Uint8List pixels, int w, int h) {
  if (a.width != w || a.height != h) return false;
  for (var i = 0; i < w * h; i++) {
    if ((a.pixels[i] != 0) != (pixels[i] != 0)) return false;
  }
  return true;
}

String _expectThrows(void Function() f) {
  try {
    f();
    return 'NO-THROW';
  } on DjvuUnsupportedException catch (e) {
    return 'unsupported: ${e.message}';
  } on DjvuFormatException catch (e) {
    return 'format: ${e.message}';
  } catch (e) {
    return 'other: $e';
  }
}

bool _isClean(String tag) =>
    tag.startsWith('format:') || tag.startsWith('unsupported:');

/// .raw 布局：文本头 "SIZE W H\n" + W*H 个 0/1 字节（自上而下）。
(int, int, Uint8List)? _loadRaw(String path) {
  final f = File(path);
  if (!f.existsSync()) return null;
  final bytes = f.readAsBytesSync();
  final nl = bytes.indexOf(0x0a);
  if (nl < 0) return null;
  final header = ascii.decode(bytes.sublist(0, nl));
  final parts = header.trim().split(RegExp(r'\s+'));
  if (parts.length != 3 || parts[0] != 'SIZE') return null;
  final w = int.parse(parts[1]);
  final h = int.parse(parts[2]);
  if (bytes.length - (nl + 1) < w * h) return null;
  return (w, h, Uint8List.sublistView(bytes, bytes.length - w * h));
}

void _emit() {
  final dir = Directory('/tmp/jb2build')..createSync(recursive: true);
  var i = 0;
  for (final (_, bmp) in _patterns()) {
    File('${dir.path}/mine_$i.jb2').writeAsBytesSync(djvuJb2EncodeSimple(bmp));
    final b = BytesBuilder()
      ..add(ascii.encode('SIZE ${bmp.width} ${bmp.height}\n'))
      ..add(bmp.pixels);
    File('${dir.path}/mine_$i.raw').writeAsBytesSync(b.toBytes());
    i++;
  }
  stdout.writeln('emitted $i 个 mine_*.jb2 / mine_*.raw 到 ${dir.path}');
}

void main(List<String> args) {
  if (args.contains('--emit')) {
    _emit();
    return;
  }

  stdout.writeln('JB2 自测开始（纯 Dart，无 flutter 依赖）');

  // ---------------------------------------------------------- (a) 坏数据
  section('坏数据必须抛明确异常');
  final empty = _expectThrows(() => djvuJb2Decode(Uint8List(0)));
  ok(_isClean(empty), '空字节 → $empty');

  final ff = _expectThrows(
    () => djvuJb2Decode(Uint8List.fromList(<int>[0xff, 0xff, 0xff, 0xff])),
  );
  ok(_isClean(ff), '0xff 垃圾 → $ff');

  final garbage = _expectThrows(
    () => djvuJb2Decode(
      Uint8List.fromList(<int>[
        for (var i = 0; i < 64; i++) (i * 97 + 13) & 0xff,
      ]),
    ),
  );
  ok(_isClean(garbage), '伪随机垃圾 → $garbage');

  for (final (name, bmp) in _patterns().take(3)) {
    final full = djvuJb2EncodeSimple(bmp);
    final cut = Uint8List.sublistView(
      full,
      0,
      (full.length ~/ 3).clamp(1, full.length),
    );
    final t = _expectThrows(() => djvuJb2Decode(cut));
    ok(_isClean(t), '$name 截断 → $t');
  }

  // ---------------------------------------------------------- (b) 往返
  section('自造编码器 ↔ 解码器逐像素往返');
  for (final (name, bmp) in _patterns()) {
    final enc = djvuJb2EncodeSimple(bmp);
    final dec = djvuJb2Decode(enc);
    ok(
      _samePixels(dec, bmp.pixels, bmp.width, bmp.height),
      '$name 字节=${enc.length} 往返一致',
    );
    final dec2 = djvuJb2Decode(enc, width: bmp.width, height: bmp.height);
    ok(
      _samePixels(dec2, bmp.pixels, bmp.width, bmp.height),
      '$name 显式 INFO 尺寸一致',
    );
    final blank = DjvuBitmap(bmp.width, bmp.height);
    final decBlank = djvuJb2Decode(djvuJb2EncodeSimple(blank));
    ok(decBlank.pixels.every((p) => p == 0), '$name 全空往返为全空');
  }

  section('DjvuBitmap.at 边界');
  final tiny = DjvuBitmap(2, 2)..pixels[0] = 1;
  ok(
    tiny.at(0, 0) && !tiny.at(1, 0) && !tiny.at(-1, 0) && !tiny.at(0, 2),
    'at() 越界安全',
  );

  // ---------------------------------------------------------- (c) 参考交叉
  section('参考实现（DjVuLibre）交叉验证');
  final refDir = Directory('/tmp/jb2build');
  if (!refDir.existsSync()) {
    stdout.writeln('  skip 未发现 /tmp/jb2build（无参考样本）');
  } else {
    DjvuJb2Dictionary? refDict;
    final dictFile = File('/tmp/jb2build/ref_dict.jbz');
    if (dictFile.existsSync()) {
      try {
        refDict = djvuJb2DictionaryDecode(dictFile.readAsBytesSync());
        stdout.writeln('  ok   ref_dict.jbz 解析为共享字典');
      } catch (e) {
        _failures++;
        stdout.writeln('  FAIL ref_dict.jbz 解析：$e');
      }
    } else {
      stdout.writeln('  skip 无 ref_dict.jbz');
    }
    final refs = refDir.listSync().whereType<File>().where((f) {
      final n = f.uri.pathSegments.last;
      return n.startsWith('ref_img_') && n.endsWith('.jb2');
    }).toList()..sort((a, b) => a.path.compareTo(b.path));
    if (refs.isEmpty) {
      stdout.writeln(
        '  skip 未发现 /tmp/jb2build/ref_img_*.jb2（无参考样本：'
        '真实 .djvu 文件仍未端到端验证）',
      );
    }
    for (final jb2 in refs) {
      final name = jb2.uri.pathSegments.last;
      final raw = _loadRaw('${jb2.path.substring(0, jb2.path.length - 4)}.raw');
      if (raw == null) {
        stdout.writeln('  skip $name（缺同名 .raw）');
        continue;
      }
      final (w, h, pixels) = raw;
      try {
        final decoded = djvuJb2Decode(
          jb2.readAsBytesSync(),
          dictionary: refDict,
        );
        ok(_samePixels(decoded, pixels, w, h), '参考流 $name 解码 == 原始位图');
      } catch (e) {
        _failures++;
        stdout.writeln('  FAIL 参考流 $name 抛异常：$e');
      }
    }
  }

  stdout.writeln(_failures == 0 ? '\n全部通过' : '\n有 $_failures 项失败');
  if (_failures != 0) exitCode = 1;
}
