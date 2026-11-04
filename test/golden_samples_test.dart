// golden 清单的**逐条复核**（`test/golden/*.txt`，由 `tool/golden_snapshot.dart`
// 生成）。
//
// 为什么要这套东西：文档里出现过"547/547 sha256""111,701 字节""IoU 0.982–1.000"
// 这类**某次实跑**的数字，但仓库里没有自动断言 —— 干净检出时真样本测试还会整组
// skip。这里把实跑数字固化成清单，样本在就**逐条**校验；样本不在就 skip 并说明
// 原因（**不许假装通过**）。
//
// 清单是**回归快照**，不是独立 oracle；独立 oracle 证据在
// `tool/chm_real_probe.dart`（7z）/`tool/djvu_real_compare.dart`（ddjvu）与 docs。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'package:synhub/src/features/files/book_mobi.dart';
import 'package:synhub/src/features/files/chm_archive.dart';
import 'package:synhub/src/features/files/djvu_archive.dart';
import 'package:synhub/src/features/files/djvu_render.dart';
import 'package:synhub/src/features/files/rar_archive.dart';

const _ebookDir = '/tmp/ebook-samples';
const _djvuDir = '/tmp/djvu-samples';
const _rarDir = '/tmp/rar-samples';
const _ddjvu = '/tmp/djvuoracle/djvulibre-3.5.28/tools/ddjvu';

String _sha256(List<int> b) => SHA256Digest()
    .process(b is Uint8List ? b : Uint8List.fromList(b))
    .map((x) => x.toRadixString(16).padLeft(2, '0'))
    .join();

/// 读清单里的数据行（跳过空行与 `#` 注释），按 TAB 切列。
List<List<String>> _rows(String file) => [
  for (final l in File(file).readAsLinesSync())
    if (l.trim().isNotEmpty && !l.startsWith('#')) l.split('\t'),
];

String? _missing(String path, {String what = '真实样本'}) =>
    File(path).existsSync() ? null : '$what $path 不存在（不进仓库）';

void main() {
  // ------------------------------------------------------------------ CHM
  group('golden：CHM（test/golden/chm_sha256.txt）', () {
    const sample = '$_ebookDir/python2718.chm';
    test('547 条 sha256 + 长度逐条一致（= 7z oracle 导出的文件数）', () {
      final a = ChmArchive.open(File(sample).readAsBytesSync());
      final rows = _rows('test/golden/chm_sha256.txt');
      expect(rows, hasLength(547), reason: '清单应覆盖 7z oracle 的 547 个文件');
      for (final r in rows) {
        final path = r[2];
        final e = a.find(path);
        expect(e, isNotNull, reason: '清单条目在 CHM 里找不到：$path');
        final data = a.read(e!);
        expect(data.length, int.parse(r[1]), reason: '$path 长度');
        expect(_sha256(data), r[0], reason: '$path sha256');
      }
    }, skip: _missing(sample));
  });

  // ------------------------------------------------------------------ KF8
  group('golden：MOBI/AZW3 纯 KF8 段（test/golden/mobi_kf8_parts_sha256.txt）', () {
    final rows = _rows('test/golden/mobi_kf8_parts_sha256.txt');
    for (final sample in const ['pg11-kf8.azw3', 'pg11-images-kf8.mobi']) {
      test('$sample：每段长度/sha256 + 拼接 sha256 + 汇总尺寸', () {
        final bytes = File('$_ebookDir/$sample').readAsBytesSync();
        final parts = mobiKf8Parts(bytes);
        final meta = <String, String>{
          for (final r in rows)
            if (r[0] == 'meta' && r[1] == sample) r[2]: r[3],
        };
        expect(parts, hasLength(int.parse(meta['parts']!)), reason: '段数');
        final partRows = [
          for (final r in rows)
            if (r[0] == 'part' && r[1] == sample) r,
        ];
        expect(partRows, hasLength(parts.length));
        for (var i = 0; i < parts.length; i++) {
          expect(
            parts[i].length,
            int.parse(partRows[i][3]),
            reason: '第 $i 段长度',
          );
          expect(_sha256(parts[i]), partRows[i][4], reason: '第 $i 段 sha256');
        }
        expect(
          _sha256([for (final p in parts) ...p]),
          meta['concatSha256'],
          reason: '拼接 sha256',
        );
        final probe = mobiKf8Probe(bytes);
        expect('${probe['assembledBytes']}', meta['assembledBytes']);
        expect('${probe['assembledChars']}', meta['assembledChars']);
        expect('${probe['skeletons']}', meta['skeletons']);
        expect('${probe['fragments']}', meta['fragments']);
      }, skip: _missing('$_ebookDir/$sample'));
    }
  });

  // ------------------------------------------------------------------ HUFF
  group('golden：MOBI HUFF/CDIC（test/golden/mobi_huff_sample.txt）', () {
    const sample = '$_ebookDir/sample-unicode-huffdic.mobi';
    test('解压正文 111,701 字节 == text_length（不再只断言 phrases）', () {
      final bytes = File(sample).readAsBytesSync();
      final meta = <String, String>{
        for (final r in _rows('test/golden/mobi_huff_sample.txt')) r[0]: r[1],
      };
      final header = mobiHeaderProbe(bytes);
      final huff = mobiHuffProbe(bytes);
      final text = mobiTextProbe(bytes);
      expect('${huff['compression']}', meta['compression']);
      expect('${huff['phrases']}', meta['phrases']);
      expect(text['ok'], isTrue, reason: '${text['error']}');
      expect('${text['declaredTextLength']}', meta['declaredTextLength']);
      expect('${text['decodedBytes']}', meta['decodedBytes']);
      expect('${header['textLength']}', meta['declaredTextLength']);
      expect(text['matchesDeclared'], isTrue, reason: '解出的字节数必须等于 text_length');
      // 文档口径 111,701 字节 —— 固化成一个明确的数字断言。
      expect(text['decodedBytes'], 111701);
    }, skip: _missing(sample));
  });

  // ------------------------------------------------------------------ DJVU
  group('golden：DJVU 结构（test/golden/djvu_samples.txt）', () {
    final rows = _rows('test/golden/djvu_samples.txt');
    for (final r in rows) {
      final name = r[0];
      final path = '$_djvuDir/$name';
      test('$name：页数/首页尺寸/NAVM/THUM/墨迹占比', () {
        final bytes = File(path).readAsBytesSync();
        if (r[1] == 'ERROR') {
          // 散装 index.djvu：必须**明确报错**，不许吐半截内容。
          expect(
            () => DjvuArchive.open(bytes),
            throwsA(
              predicate(
                (e) => e.toString().contains(r[2].substring(0, 12)),
                '错误信息应说明原因',
              ),
            ),
            reason: name,
          );
          return;
        }
        final arc = DjvuArchive.open(bytes);
        expect(arc.pages.length, int.parse(r[1]), reason: '$name 页数');
        final rgba = djvuRenderPage(arc.pages.first);
        expect(rgba.width, int.parse(r[2]), reason: '$name 首页宽');
        expect(rgba.height, int.parse(r[3]), reason: '$name 首页高');
        expect(arc.bookmarks.length, int.parse(r[4]), reason: '$name NAVM');
        expect(arc.thumbnail.length, int.parse(r[5]), reason: '$name THUM');
        var dark = 0;
        for (var i = 0; i < rgba.width * rgba.height; i++) {
          final l =
              (rgba.pixels[i * 4] +
                  rgba.pixels[i * 4 + 1] +
                  rgba.pixels[i * 4 + 2]) ~/
              3;
          if (l < 192) dark++;
        }
        final pct = dark * 100 / (rgba.width * rgba.height);
        expect(pct, closeTo(double.parse(r[6]), 0.001), reason: '$name 墨迹占比');
      }, skip: _missing(path));
    }
    test('清单覆盖 7 个 .djvu：6 份 bundled + 1 份散装报错', () {
      final names = [for (final r in rows) r[0]];
      expect(names, hasLength(7), reason: '目录里有 7 个 .djvu');
      expect(rows.where((r) => r[1] == 'ERROR').map((r) => r[0]), [
        'index.djvu',
      ], reason: '只有散装 index.djvu 预期报错（不参与像素对照）');
      expect(
        rows.where((r) => r[1] != 'ERROR'),
        hasLength(6),
        reason: '像素级对照只有 6 份',
      );
    });
  });

  group('golden：DJVU 首页像素对比（需要 ddjvu oracle）', () {
    final rows = _rows('test/golden/djvu_samples.txt');
    for (final r in rows) {
      if (r[1] == 'ERROR') continue;
      final path = '$_djvuDir/${r[0]}';
      test('${r[0]}：首页 meanAbs / IoU', () {
        final meanAbs = double.parse(r[7]);
        final iou = double.parse(r[8]);
        expect(meanAbs, greaterThanOrEqualTo(0), reason: '清单应有像素数字');
        expect(iou, greaterThan(0));
        final arc = DjvuArchive.open(File(path).readAsBytesSync());
        final mine = djvuRenderPage(arc.pages.first);
        final tmp = File('${Directory.systemTemp.path}/golden_${r[0]}.ppm');
        final p = Process.runSync(_ddjvu, [
          '-format=ppm',
          '-page=1',
          path,
          tmp.path,
        ]);
        expect(p.exitCode, 0, reason: '${r[0]} oracle 渲染失败: ${p.stderr}');
        final ref = _parsePpm(tmp.path);
        tmp.deleteSync();
        expect(ref.width, mine.width, reason: '${r[0]} 宽');
        expect(ref.height, mine.height, reason: '${r[0]} 高');
        final c = _compare(mine, ref);
        expect(c.meanAbs, closeTo(meanAbs, 0.001), reason: '${r[0]} meanAbs');
        expect(c.iou, closeTo(iou, 0.0001), reason: '${r[0]} IoU');
      }, skip: _missing(path) ?? _missing(_ddjvu, what: 'ddjvu oracle'));
    }
  });

  // ------------------------------------------------------------------ RAR
  group('golden：RAR 真实样本（test/golden/rar_samples.txt）', () {
    final rows = _rows('test/golden/rar_samples.txt');
    final samples = <String>{
      for (final r in rows)
        if (r[0] != 'real.rar') r[0],
    }.toList()..sort();
    for (final sample in samples) {
      test('$sample：条目 size/crc32/sha256 或明确错误', () {
        final bytes = File('$_rarDir/$sample').readAsBytesSync();
        final mine = rows.where((r) => r[0] == sample).toList();
        final err = mine.where((r) => r[1] == 'ERROR').toList();
        if (err.isNotEmpty) {
          Object? got;
          try {
            RarArchive.open(bytes).extract();
          } catch (e) {
            got = e;
          }
          expect(got, isNotNull, reason: '加密/坏样本必须明确报错');
          expect(got.runtimeType.toString(), err.first[2]);
          expect('$got', contains(err.first[3].substring(0, 8)));
          return;
        }
        final out = RarArchive.open(bytes).extract();
        final names = [for (final r in mine) r[1]];
        expect(out.keys.toList()..sort(), names..sort(), reason: '条目集合');
        for (final r in mine) {
          final data = out[r[1]]!;
          expect(data.length, int.parse(r[2]), reason: '${r[1]} 长度');
          expect(
            rarCrc32(data).toRadixString(16).padLeft(8, '0'),
            r[3],
            reason: '${r[1]} crc32',
          );
          expect(_sha256(data), r[4], reason: '${r[1]} sha256');
        }
      }, skip: _missing('$_rarDir/$sample'));
    }

    test('real.rar（RAR 2.0 存储包）：三个条目逐条一致', () {
      final bytes = File('$_ebookDir/real.rar').readAsBytesSync();
      final out = RarArchive.open(bytes).extract();
      final mine = rows.where((r) => r[0] == 'real.rar').toList();
      expect(out.keys.toList()..sort(), [for (final r in mine) r[1]]..sort());
      for (final r in mine) {
        final data = out[r[1]]!;
        expect(data.length, int.parse(r[2]), reason: '${r[1]} 长度');
        expect(
          rarCrc32(data).toRadixString(16).padLeft(8, '0'),
          r[3],
          reason: '${r[1]} crc32',
        );
        expect(_sha256(data), r[4], reason: '${r[1]} sha256');
      }
    }, skip: _missing('$_ebookDir/real.rar'));
  });
}

// ---------------------------------------------------------------- PPM 对照
// 与 `tool/djvu_real_compare.dart` 同口径（尺寸必须一致；meanAbs = 三通道绝对差
// 均值；IoU = 亮度<192 的"墨迹"掩码交并比）。

class _Ppm {
  _Ppm(this.width, this.height, this.rgb);
  final int width;
  final int height;
  final Uint8List rgb;
}

_Ppm _parsePpm(String path) {
  final b = File(path).readAsBytesSync();
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
  expect(magic, 'P6', reason: 'ddjvu 应输出 P6 PPM');
  final w = int.parse(token());
  final h = int.parse(token());
  expect(int.parse(token()), 255);
  pos++;
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
  return (
    meanAbs: sum / (n * 3),
    iou: uni == 0 ? 1.0 : math.max(inter / uni, 0),
  );
}
