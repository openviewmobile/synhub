// 用真实 DjVuLibre（`ddjvu`/`djvused`）当 oracle，把本解码器的渲染结果和参考
// 渲染逐像素对照。
//
//   dart run tool/djvu_real_compare.dart <文件或目录> [--pages 1,2,5] [--tol 32]
//   dart run tool/djvu_real_compare.dart --oracle /path/to/tools <文件>
//
// 默认 oracle 路径是 /tmp/djvuoracle/djvulibre-3.5.28/tools（本地源码构建），
// 找不到就 skip 并说明"无像素级 oracle"。
//
// 对照口径：
//   * 尺寸必须一致（页宽高来自 INFO）；
//   * meanAbs：三通道绝对差均值（0..255）；
//   * major%：任一通道差 > 96 的像素占比；
//   * IoU：两边"墨迹"（亮度 < 192）掩码的交并比 —— 主图内容是否在同一位置。
//
// 真实样本只在 /tmp，不进仓库。
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:synhub/src/features/files/djvu_archive.dart';
import 'package:synhub/src/features/files/djvu_render.dart';

const String _defaultOracle = '/tmp/djvuoracle/djvulibre-3.5.28/tools';

class _Ppm {
  _Ppm(this.width, this.height, this.rgb);
  final int width;
  final int height;
  final Uint8List rgb;
}

_Ppm _parsePpm(Uint8List b) {
  var pos = 0;
  String token() {
    while (pos < b.length &&
        (b[pos] == 0x20 ||
            b[pos] == 0x0a ||
            b[pos] == 0x0d ||
            b[pos] == 0x09)) {
      pos++;
    }
    if (b[pos] == 0x23) {
      while (pos < b.length && b[pos] != 0x0a) {
        pos++;
      }
      return token();
    }
    final start = pos;
    while (pos < b.length &&
        b[pos] != 0x20 &&
        b[pos] != 0x0a &&
        b[pos] != 0x0d &&
        b[pos] != 0x09) {
      pos++;
    }
    return String.fromCharCodes(b.sublist(start, pos));
  }

  final magic = token();
  if (magic != 'P6') throw StateError('不是 P6 PPM：$magic');
  final w = int.parse(token());
  final h = int.parse(token());
  final maxv = int.parse(token());
  pos++; // 单个空白
  if (maxv != 255) throw StateError('maxval=$maxv 不支持');
  final n = w * h * 3;
  return _Ppm(w, h, Uint8List.sublistView(b, pos, pos + n));
}

({double meanAbs, double majorPct, double iou, double darkMine, double darkRef})
_compare(DjvuRgba mine, _Ppm ref) {
  if (mine.width != ref.width || mine.height != ref.height) {
    throw StateError(
      '尺寸不一致：mine=${mine.width}x${mine.height} ref=${ref.width}x${ref.height}',
    );
  }
  final n = mine.width * mine.height;
  var sum = 0;
  var major = 0;
  var inter = 0, uni = 0, dm = 0, dr = 0;
  for (var i = 0; i < n; i++) {
    final r = ref.rgb[i * 3], g = ref.rgb[i * 3 + 1], b = ref.rgb[i * 3 + 2];
    final mr = mine.pixels[i * 4],
        mg = mine.pixels[i * 4 + 1],
        mb = mine.pixels[i * 4 + 2];
    final d0 = (mr - r).abs(), d1 = (mg - g).abs(), d2 = (mb - b).abs();
    sum += d0 + d1 + d2;
    final dmax = math.max(d0, math.max(d1, d2));
    if (dmax > 96) major++;
    // 亮度阈值 192：扫描纸面背景（~230）不算墨，字/图算
    final lm = (mr + mg + mb) ~/ 3 < 192;
    final lr = (r + g + b) ~/ 3 < 192;
    if (lm) dm++;
    if (lr) dr++;
    if (lm && lr) inter++;
    if (lm || lr) uni++;
  }
  return (
    meanAbs: sum / (n * 3),
    majorPct: major * 100 / n,
    iou: uni == 0 ? 1 : inter / uni,
    darkMine: dm * 100 / n,
    darkRef: dr * 100 / n,
  );
}

int _oraclePageCount(String djvused, String path) {
  final r = Process.runSync(djvused, ['-e', 'n', path]);
  if (r.exitCode != 0) return -1;
  return int.tryParse(r.stdout.toString().trim()) ?? -1;
}

void main(List<String> args) {
  var oracle = _defaultOracle;
  var tol = 96.0;
  final pagesArg = <int>[];
  var allPages = false;
  final paths = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--all') {
      allPages = true;
    } else if (a == '--oracle') {
      oracle = args[++i];
    } else if (a == '--tol') {
      tol = double.parse(args[++i]);
    } else if (a == '--pages') {
      for (final s in args[++i].split(',')) {
        final v = int.tryParse(s.trim());
        if (v != null) pagesArg.add(v);
      }
    } else {
      final d = Directory(a);
      if (d.existsSync()) {
        final found =
            d
                .listSync()
                .whereType<File>()
                .where((f) => f.path.toLowerCase().endsWith('.djvu'))
                .map((f) => f.path)
                .toList()
              ..sort();
        paths.addAll(found);
      } else {
        paths.add(a);
      }
    }
  }
  final ddjvu = '$oracle/ddjvu';
  final djvused = '$oracle/djvused';
  if (!File(ddjvu).existsSync()) {
    print('skip 找不到 oracle（$ddjvu）→ 无像素级对照');
    print('     可用 `tool/djvu_real_probe.dart` 做结构性体检');
    exit(0);
  }
  if (paths.isEmpty) {
    print('用法: dart run tool/djvu_real_compare.dart <文件或目录> [--pages 1,2]');
    exit(2);
  }
  final tmp = Directory.systemTemp.createTempSync('djvu_cmp');
  try {
    for (final path in paths) {
      print('================ $path');
      final Uint8List bytes;
      try {
        bytes = File(path).readAsBytesSync();
      } catch (e) {
        print('  ✗ 读不到: $e');
        continue;
      }
      final DjvuArchive arc;
      try {
        arc = DjvuArchive.open(bytes);
      } catch (e) {
        print('  ✗ open 失败: $e');
        continue;
      }
      final refCount = _oraclePageCount(djvused, path);
      print(
        '  页数：mine=${arc.pages.length} oracle=$refCount '
        '${refCount == arc.pages.length ? "✓" : "✗ 不一致"}',
      );
      final idxs = pagesArg.isNotEmpty
          ? pagesArg
                .map((p) => p - 1)
                .where((i) => i >= 0 && i < arc.pages.length)
                .toList()
          : List<int>.generate(
              allPages ? arc.pages.length : math.min(arc.pages.length, 6),
              (i) => i,
            );
      for (final i in idxs) {
        final page = arc.pages[i];
        final ppm = '${tmp.path}/p${i + 1}.ppm';
        final r = Process.runSync(ddjvu, [
          '-format=ppm',
          '-page=${i + 1}',
          path,
          ppm,
        ]);
        if (r.exitCode != 0) {
          print('  [页 ${i + 1}] oracle 渲染失败: ${r.stderr}');
          continue;
        }
        final ref = _parsePpm(File(ppm).readAsBytesSync());
        final DjvuRgba mine;
        try {
          mine = djvuRenderPage(page);
        } catch (e) {
          print('  [页 ${i + 1}] ✗ 本解码器渲染失败: $e');
          continue;
        }
        if (mine.width != ref.width || mine.height != ref.height) {
          print(
            '  [页 ${i + 1}] ✗ 尺寸 mine=${mine.width}x${mine.height} oracle=${ref.width}x${ref.height}',
          );
          continue;
        }
        final c = _compare(mine, ref);
        final ok = c.majorPct <= tol && c.iou >= 0.80;
        print(
          '  [页 ${i + 1}] ${ok ? "✓" : "⚠"} ${mine.width}x${mine.height} '
          'meanAbs=${c.meanAbs.toStringAsFixed(1)} '
          'major(>96)=${c.majorPct.toStringAsFixed(2)}% '
          'IoU(墨迹)=${c.iou.toStringAsFixed(3)} '
          '墨迹占比 mine=${c.darkMine.toStringAsFixed(1)}% oracle=${c.darkRef.toStringAsFixed(1)}%',
        );
        File(ppm).deleteSync();
      }
    }
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}
