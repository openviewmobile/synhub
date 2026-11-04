// 生成 `test/golden/*` 的**固化清单**（离线，不碰设备、不联网）。
//
// 这些清单是"某次实跑的快照"：用**仓库自己的解析器**对 `/tmp` 里的真实样本
// 跑一遍，把每条 sha256 / 尺寸 / 墨迹占比 / oracle 像素对比数字写下来，之后由
// `test/golden_samples_test.dart` 在样本存在时**逐条**复核。它钉住的是**回归**
// （实现漂移会红），不是独立 oracle；独立 oracle 证据见 `docs/ebook-reader-plan.md`
// 与 `tool/chm_real_probe.dart` / `tool/djvu_real_compare.dart`。
//
//   dart run tool/golden_snapshot.dart
//
// 样本目录（都不进仓库）：
//   /tmp/ebook-samples/python2718.chm
//   /tmp/ebook-samples/{pg11-kf8.azw3, pg11-images-kf8.mobi, sample-unicode-huffdic.mobi}
//   /tmp/djvu-samples/*.djvu
//   /tmp/rar-samples/*.rar  +  /tmp/ebook-samples/real.rar
//
// 缺样本的清单**不生成空文件**，只打印"本轮无法生成"的原因（假通过是不允许的）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import 'package:synhub/src/features/files/book_mobi.dart';
import 'package:synhub/src/features/files/chm_archive.dart';
import 'package:synhub/src/features/files/djvu_archive.dart';
import 'package:synhub/src/features/files/djvu_render.dart';
import 'package:synhub/src/features/files/rar_archive.dart';

const String _chm = '/tmp/ebook-samples/python2718.chm';
const String _kf8Azw3 = '/tmp/ebook-samples/pg11-kf8.azw3';
const String _kf8Mobi = '/tmp/ebook-samples/pg11-images-kf8.mobi';
const String _huff = '/tmp/ebook-samples/sample-unicode-huffdic.mobi';
const String _djvuDir = '/tmp/djvu-samples';
const String _rarDir = '/tmp/rar-samples';
const String _realRar = '/tmp/ebook-samples/real.rar';
const String _ddjvu = '/tmp/djvuoracle/djvulibre-3.5.28/tools/ddjvu';

const String _outDir = 'test/golden';

String sha256Hex(List<int> b) => SHA256Digest()
    .process(b is Uint8List ? b : Uint8List.fromList(b))
    .map((x) => x.toRadixString(16).padLeft(2, '0'))
    .join();

void _write(String name, String body) {
  final f = File('$_outDir/$name');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(body);
  print(
    '写出 ${f.path}（${body.split('\n').where((l) => l.trim().isNotEmpty).length} 行）',
  );
}

// ------------------------------------------------------------------ CHM

void chm() {
  final f = File(_chm);
  if (!f.existsSync()) {
    print('!! CHM 清单本轮无法生成：$_chm 不存在');
    return;
  }
  final bytes = f.readAsBytesSync();
  final a = ChmArchive.open(bytes);
  // 547 = 545 条 space1（LZX 压缩内容）+ `#SYSTEM`（space0 未压缩）
  //        + `#ITBITS`（7z 会导出空文件，但在目录树里不是普通条目）。
  // 这三个来源合起来才等于 7z oracle 导出的 547 个文件
  // （独立证据见 /tmp/chm-probe-report.txt）。
  final rows = <({String path, int size, Uint8List data})>[];
  for (final e in a.entries) {
    if (e.isDir || e.space != 1 || e.length <= 0) continue;
    rows.add((path: e.normalized, size: e.length, data: a.read(e)));
  }
  for (final extra in const ['#SYSTEM', '#ITBITS']) {
    final e = a.find(extra);
    if (e == null) continue;
    final data = a.read(e);
    rows.add((path: extra, size: data.length, data: data));
  }
  rows.sort((x, y) => x.path.compareTo(y.path));
  final b = StringBuffer()
    ..writeln('# golden snapshot: CHM（$_chm）')
    ..writeln('# 生成：dart run tool/golden_snapshot.dart（用仓库解析器实跑）')
    ..writeln('# 口径：space1 压缩内容 + `#SYSTEM`/`#ITBITS`，共 547 条')
    ..writeln(
      '# 非独立 oracle；7z 对照见 tool/chm_real_probe.dart（/tmp/chm-probe-report.txt）',
    )
    ..writeln('# format: sha256<TAB>size<TAB>path')
    ..writeln('# sample-bytes\t${bytes.length}')
    ..writeln('# itsf-version\t${a.version}')
    ..writeln('# entry-count\t${rows.length}');
  for (final r in rows) {
    b.writeln('${sha256Hex(r.data)}\t${r.size}\t${r.path}');
  }
  _write('chm_sha256.txt', b.toString());
}

// ------------------------------------------------------------------ MOBI

void mobi() {
  final kf8 = <String, String>{
    _kf8Azw3: 'pg11-kf8.azw3',
    _kf8Mobi: 'pg11-images-kf8.mobi',
  };
  final missing = kf8.keys.where((p) => !File(p).existsSync()).toList();
  if (missing.length == kf8.length) {
    print('!! KF8 清单本轮无法生成：${missing.join(', ')} 都不存在');
  } else {
    final b = StringBuffer()
      ..writeln('# golden snapshot: MOBI/AZW3 纯 KF8 重组段')
      ..writeln('# 生成：dart run tool/golden_snapshot.dart')
      ..writeln('# 口径：mobiKf8Parts() 逐段 sha256 + 拼接 sha256 + 汇总尺寸')
      ..writeln(
        '# 非独立 oracle；KindleUnpack v0.83 逐字节对照见 docs/ebook-reader-plan.md §7.10',
      )
      ..writeln('# format: part<TAB>sample<TAB>index<TAB>size<TAB>sha256')
      ..writeln('# format: meta<TAB>sample<TAB>key<TAB>value');
    for (final e in kf8.entries) {
      if (!File(e.key).existsSync()) {
        b.writeln('# missing\t${e.value}\t${e.key}');
        continue;
      }
      final bytes = File(e.key).readAsBytesSync();
      final parts = mobiKf8Parts(bytes);
      final probe = mobiKf8Probe(bytes);
      for (var i = 0; i < parts.length; i++) {
        b.writeln(
          'part\t${e.value}\t$i\t${parts[i].length}\t${sha256Hex(parts[i])}',
        );
      }
      b.writeln('meta\t${e.value}\tparts\t${parts.length}');
      b.writeln(
        'meta\t${e.value}\tconcatSha256\t${sha256Hex([for (final p in parts) ...p])}',
      );
      b.writeln('meta\t${e.value}\tassembledBytes\t${probe['assembledBytes']}');
      b.writeln('meta\t${e.value}\tassembledChars\t${probe['assembledChars']}');
      b.writeln('meta\t${e.value}\tskeletons\t${probe['skeletons']}');
      b.writeln('meta\t${e.value}\tfragments\t${probe['fragments']}');
    }
    _write('mobi_kf8_parts_sha256.txt', b.toString());
  }

  if (!File(_huff).existsSync()) {
    print('!! HUFF 清单本轮无法生成：$_huff 不存在');
    return;
  }
  final bytes = File(_huff).readAsBytesSync();
  final text = mobiTextProbe(bytes);
  final huff = mobiHuffProbe(bytes);
  final header = mobiHeaderProbe(bytes);
  final b = StringBuffer()
    ..writeln('# golden snapshot: MOBI HUFF/CDIC（$_huff）')
    ..writeln('# 生成：dart run tool/golden_snapshot.dart')
    ..writeln('# 口径：mobiTextProbe()/mobiHuffProbe()/mobiHeaderProbe() 实跑值')
    ..writeln('# 非独立 oracle；libmobi 夹具来源见 docs/ebook-reader-plan.md §7.8')
    ..writeln('# format: key<TAB>value')
    ..writeln('compression\t${huff['compression'] ?? header['compression']}')
    ..writeln('phrases\t${huff['phrases']}')
    ..writeln('declaredTextLength\t${text['declaredTextLength']}')
    ..writeln('decodedBytes\t${text['decodedBytes']}')
    ..writeln('matchesDeclared\t${text['matchesDeclared']}')
    ..writeln('ok\t${text['ok']}');
  _write('mobi_huff_sample.txt', b.toString());
}

// ------------------------------------------------------------------ DJVU

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
  pos++;
  if (maxv != 255) throw StateError('maxval=$maxv 不支持');
  return _Ppm(w, h, Uint8List.sublistView(b, pos, pos + w * h * 3));
}

({double meanAbs, double iou}) _compare(DjvuRgba mine, _Ppm ref) {
  final n = mine.width * mine.height;
  var sum = 0, inter = 0, uni = 0;
  for (var i = 0; i < n; i++) {
    final r = ref.rgb[i * 3], g = ref.rgb[i * 3 + 1], b = ref.rgb[i * 3 + 2];
    final mr = mine.pixels[i * 4],
        mg = mine.pixels[i * 4 + 1],
        mb = mine.pixels[i * 4 + 2];
    sum += (mr - r).abs() + (mg - g).abs() + (mb - b).abs();
    final lm = (mr + mg + mb) ~/ 3 < 192;
    final lr = (r + g + b) ~/ 3 < 192;
    if (lm && lr) inter++;
    if (lm || lr) uni++;
  }
  return (meanAbs: sum / (n * 3), iou: uni == 0 ? 1.0 : inter / uni);
}

void djvu() {
  final dir = Directory(_djvuDir);
  if (!dir.existsSync()) {
    print('!! DJVU 清单本轮无法生成：$_djvuDir 不存在');
    return;
  }
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.djvu'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final hasOracle = File(_ddjvu).existsSync();
  final tmp = Directory.systemTemp.createTempSync('djvu_golden');
  final b = StringBuffer()
    ..writeln('# golden snapshot: DJVU 真实样本')
    ..writeln('# 生成：dart run tool/golden_snapshot.dart')
    ..writeln('# 口径：结构/尺寸/墨迹占比来自本仓库渲染；meanAbs/IoU 由 ddjvu 3.5.28 对首页')
    ..writeln('# 目录里有 7 个 .djvu；**像素级对照只有 6 份**（index.djvu 是散装 indirect，')
    ..writeln('#   缺分页文件 → 明确报错，不参与像素对照）—— 这就是文档"6 份 vs 7 份"的真相。')
    ..writeln('# 首页-only 的数字只是抽样；全量（每份前 6 页）由 tool/djvu_real_compare.dart')
    ..writeln('#   输出，实测范围 meanAbs 0.0–1.6 / IoU 0.982–1.000（与 docs 一致）。')
    ..writeln('# format: sample<TAB>error<TAB>detail            （解不开时）')
    ..writeln(
      '# format: sample<TAB>pages<TAB>w<TAB>h<TAB>navm<TAB>thum<TAB>darkPct<TAB>meanAbs<TAB>iou',
    );
  try {
    for (final f in files) {
      final name = f.path.substring(f.path.lastIndexOf('/') + 1);
      final bytes = f.readAsBytesSync();
      try {
        final arc = DjvuArchive.open(bytes);
        if (arc.pages.isEmpty) {
          b.writeln('$name\tERROR\tno-pages');
          continue;
        }
        final rgba = djvuRenderPage(arc.pages.first);
        var dark = 0;
        for (var i = 0; i < rgba.width * rgba.height; i++) {
          final l =
              (rgba.pixels[i * 4] +
                  rgba.pixels[i * 4 + 1] +
                  rgba.pixels[i * 4 + 2]) ~/
              3;
          if (l < 192) dark++;
        }
        final darkPct = dark * 100 / (rgba.width * rgba.height);
        var meanAbs = -1.0, iou = -1.0;
        if (hasOracle) {
          final ppm = '${tmp.path}/$name.ppm';
          final r = Process.runSync(_ddjvu, [
            '-format=ppm',
            '-page=1',
            f.path,
            ppm,
          ]);
          if (r.exitCode == 0) {
            final ref = _parsePpm(File(ppm).readAsBytesSync());
            if (ref.width == rgba.width && ref.height == rgba.height) {
              final c = _compare(rgba, ref);
              meanAbs = c.meanAbs;
              iou = c.iou;
            }
          }
        }
        b.writeln(
          '$name\t${arc.pages.length}\t${rgba.width}\t${rgba.height}\t'
          '${arc.bookmarks.length}\t${arc.thumbnail.length}\t'
          '${darkPct.toStringAsFixed(3)}\t${meanAbs.toStringAsFixed(3)}\t'
          '${iou.toStringAsFixed(4)}',
        );
      } catch (e) {
        b.writeln('$name\tERROR\t$e');
      }
    }
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
  _write('djvu_samples.txt', b.toString());
}

// ------------------------------------------------------------------ RAR

void rar() {
  final files = <File>[];
  final dir = Directory(_rarDir);
  if (dir.existsSync()) {
    files.addAll(
      dir.listSync().whereType<File>().where(
        (f) => f.path.toLowerCase().endsWith('.rar'),
      ),
    );
  }
  if (File(_realRar).existsSync()) files.add(File(_realRar));
  if (files.isEmpty) {
    print('!! RAR 清单本轮无法生成：$_rarDir 与 $_realRar 都不存在');
    return;
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  final b = StringBuffer()
    ..writeln('# golden snapshot: RAR 真实样本（libarchive 测试数据 + real.rar）')
    ..writeln('# 生成：dart run tool/golden_snapshot.dart')
    ..writeln('# 口径：RarArchive 解出的每个条目 size/crc32/sha256；解不开写 ERROR')
    ..writeln('# format: sample<TAB>entry<TAB>size<TAB>crc32<TAB>sha256')
    ..writeln('# format: sample<TAB>ERROR<TAB>exception<TAB>message');
  for (final f in files) {
    final name = f.path.substring(f.path.lastIndexOf('/') + 1);
    try {
      final out = RarArchive.open(f.readAsBytesSync()).extract();
      for (final e in out.entries) {
        b.writeln(
          '$name\t${e.key}\t${e.value.length}\t'
          '${rarCrc32(e.value).toRadixString(16).padLeft(8, '0')}\t'
          '${sha256Hex(e.value)}',
        );
      }
      if (out.isEmpty) b.writeln('$name\tEMPTY\t-\t-');
    } catch (e) {
      b.writeln(
        '$name\tERROR\t${e.runtimeType}\t${e.toString().split('\n').first}',
      );
    }
  }
  _write('rar_samples.txt', b.toString());
}

void main() {
  Directory(_outDir).createSync(recursive: true);
  chm();
  mobi();
  djvu();
  rar();
  print('提示：清单是回归快照，不是独立 oracle；样本缺失时对应行不写入。');
}
