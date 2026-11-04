// **真实文件**闭环验证：把 `lib/src/data/office_native/**` 的解析层直接喂
// 设备批次取回的 8 份真实 `.odoc/.osheet/.oslides`（宿主 `/tmp/office-samples/`）。
//
// 诚实边界（必读）：
//   * 样本本体**不 vendored 进仓库**；本文件只按路径读取，缺失时整组 **skip**
//     并写明原因。身份（大小/sha256）登记在
//     `test/golden/office_native_real_samples.txt`。
//   * 这里的"独立数字"来自设备批次报告 `REPORT.md` / `_content.json`（宿主 Python
//     解码器 `decode.py`），**不是**本仓库的输出。对照时如果我们不一致 ⇒ 红。
//   * 结构真伪不靠 lib 自证：本文件自带一个**独立的** BSON doc 链扫描器
//     （不 import `ofile.dart` 的解析代码），并用设备报告的口径统计。
//
// 口径（与设备报告一致）：
//   - 头文档第 5 字节必须是 `0x12`（int64 `schema`），头文档**只放**元数据；
//   - `@C_metatext` 与明文 `metatext`（string 字面量 `"null"`）在**同一个 doc**；
//   - `metabinary_files` 值 = document，键 = `{"name":"<file_id>"}`，值 = 未压缩字节；
//   - 链尾 = `{"end": true}`；
//   - odoc/oslides 的 "text 节点数" = `content` JSON 里 `type=="text"` 且 `text`
//     **非空白** 的节点数（设备报告口径）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:synhub/src/data/office_native/office_native_reader.dart';
import 'package:synhub/src/data/office_native/ofile.dart';

import 'support/ofile_fixture.dart';

final Directory _root = Directory(
  Platform.environment['OFFICE_NATIVE_REAL_SAMPLES'] ?? '/tmp/office-samples',
);

final String? _skipReason = _root.existsSync()
    ? null
    : '真实文件样本缺失：${_root.path}（设备批次取回，样本不进仓库；'
          'REPORT.md 见 /tmp/office-samples/REPORT.md）';

String _sha256Hex(List<int> bytes) {
  final d = SHA256Digest()..update(Uint8List.fromList(bytes), 0, bytes.length);
  final out = Uint8List(32);
  d.doFinal(out, 0);
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// --- 独立 BSON doc 链扫描器（**不**依赖 lib/ofile.dart） ---------------------

class _RawElem {
  const _RawElem(this.type, this.value);
  final int type;
  final Object? value;
}

class _RawDoc {
  const _RawDoc(this.offset, this.length, this.elems);
  final int offset;
  final int length;
  final Map<String, _RawElem> elems;
}

int _i32(Uint8List b, int p) =>
    b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24);

/// 逐 doc 走完 `[int32 LE len][BSON doc]` 链，返回每个 doc 的顶层键/类型/值。
List<_RawDoc> _rawChain(Uint8List b, {required String file}) {
  final docs = <_RawDoc>[];
  var off = 0;
  while (off < b.length) {
    final len = _i32(b, off);
    expect(
      len >= 5 && off + len <= b.length,
      isTrue,
      reason: '$file: doc @$off 长度 $len 越界（size=${b.length}）',
    );
    expect(b[off + len - 1], 0, reason: '$file: doc @$off 缺 BSON 终结符 0x00');
    final elems = <String, _RawElem>{};
    var p = off + 4;
    final end = off + len - 1;
    while (p < end) {
      final t = b[p];
      p++;
      if (t == 0) break;
      final z = b.indexOf(0, p);
      expect(z, lessThan(end), reason: '$file: 未终结 cstring @$p');
      final key = utf8.decode(b.sublist(p, z));
      p = z + 1;
      final r = _skipValue(b, p, t);
      elems[key] = _RawElem(t, r.$1);
      p = r.$2;
    }
    docs.add(_RawDoc(off, len, elems));
    off += len;
  }
  expect(off, b.length, reason: '$file: consumed($off) != size(${b.length})');
  return docs;
}

/// 跳过/读取一个 BSON 值；返回 (值, 新偏移)。只对 string/bool/int64 取真值。
(Object?, int) _skipValue(Uint8List b, int p, int t) {
  switch (t) {
    case 0x01:
      return (null, p + 8);
    case 0x02:
      final n = _i32(b, p);
      return (utf8.decode(b.sublist(p + 4, p + 4 + n - 1)), p + 4 + n);
    case 0x03:
    case 0x04:
      return (null, p + _i32(b, p));
    case 0x05:
      final n = _i32(b, p);
      return (b.sublist(p + 5, p + 5 + n), p + 5 + n);
    case 0x07:
      return (null, p + 12);
    case 0x08:
      return (b[p] == 1, p + 1);
    case 0x09:
    case 0x11:
    case 0x12:
      return (null, p + 8);
    case 0x0A:
      return (null, p);
    case 0x10:
      return (null, p + 4);
    case 0x13:
      return (null, p + 16);
    default:
      throw StateError('未知 BSON type 0x${t.toRadixString(16)} @$p');
  }
}

/// 统计 `content` JSON 里非空白 `type=="text"` 节点数（设备报告口径）。
int _nonBlankTextNodes(Object? node) {
  var n = 0;
  void walk(Object? x) {
    if (x is List) {
      for (final y in x) {
        walk(y);
      }
      return;
    }
    if (x is! Map) return;
    if (x['type'] == 'text') {
      final t = x['text'];
      if (t is String && t.trim().isNotEmpty) n++;
    }
    for (final v in x.values) {
      walk(v);
    }
  }

  walk(node);
  return n;
}

/// 每份真实文件的**独立期望**（来自设备报告 `_content.json` / 链 dump）。
class _Expected {
  const _Expected({
    required this.file,
    required this.bytes,
    required this.format,
    required this.idSuffix,
    required this.ntype,
    required this.docCount,
    required this.enc,
    required this.sections,
    this.nonBlankText,
    this.totalText,
    this.valueCells,
    this.formulaValues,
    this.sheetCount,
    this.slides,
    this.layouts,
    this.masterImages,
    this.tables,
    this.pictures,
    this.embeddedCount = 0,
    this.embeddedBytes = 0,
  });

  final String file;
  final int bytes;
  final OfficeNativeFormat format;
  final String idSuffix;
  final int ntype;
  final int docCount;
  final bool enc;
  final Set<String> sections;
  final int? nonBlankText;
  final int? totalText;
  final int? valueCells;
  final int? formulaValues;
  final int? sheetCount;
  final int? slides;
  final int? layouts;
  final int? masterImages;
  final int? tables;
  final int? pictures;
  final int embeddedCount;
  final int embeddedBytes;
}

const List<_Expected> _expected = [
  _Expected(
    file: '5-day trip planner.odoc',
    bytes: 266653,
    format: OfficeNativeFormat.odoc,
    idSuffix: 'doc',
    ntype: 21,
    docCount: 14,
    enc: false,
    sections: {'content', 'file', 'index', 'metatext', 'attachment'},
    nonBlankText: 38,
    totalText: 38,
    tables: 5,
    pictures: 10,
    embeddedCount: 7,
    embeddedBytes: 263216,
  ),
  _Expected(
    file: 'Annual income and expenditure.osheet',
    bytes: 4883,
    format: OfficeNativeFormat.osheet,
    idSuffix: 'sh',
    ntype: 37,
    docCount: 8,
    enc: false,
    sections: {'define', 'index', 'locale', 'sh_1', 'style', 'metatext'},
    valueCells: 407,
    formulaValues: 257,
    sheetCount: 1,
  ),
  _Expected(
    file: 'Celestial.oslides',
    bytes: 3400,
    format: OfficeNativeFormat.oslides,
    idSuffix: 'slide',
    ntype: 69,
    docCount: 5,
    enc: false,
    sections: {'content', 'index', 'metatext'},
    nonBlankText: 0,
    totalText: 0,
    slides: 1,
    layouts: 9,
    masterImages: 0,
    tables: 0,
    pictures: 0,
  ),
  _Expected(
    file: 'Dynamic.oslides',
    bytes: 9205426,
    format: OfficeNativeFormat.oslides,
    idSuffix: 'slide',
    ntype: 69,
    docCount: 13,
    enc: false,
    sections: {'content', 'file', 'index', 'metatext', 'attachment'},
    nonBlankText: 70,
    totalText: 70,
    slides: 15,
    layouts: 16,
    masterImages: 6,
    tables: 0,
    pictures: 0,
    embeddedCount: 6,
    embeddedBytes: 9197314,
  ),
  _Expected(
    file: 'Product spec.odoc',
    bytes: 3390,
    format: OfficeNativeFormat.odoc,
    idSuffix: 'doc',
    ntype: 21,
    docCount: 8,
    enc: false,
    sections: {'content', 'file', 'index', 'metatext', 'attachment'},
    nonBlankText: 36,
    totalText: 36,
    tables: 1,
    pictures: 1,
    embeddedCount: 1,
    embeddedBytes: 948,
  ),
  _Expected(
    file: 'Restaurant menu.odoc',
    bytes: 19590,
    format: OfficeNativeFormat.odoc,
    idSuffix: 'doc',
    ntype: 21,
    docCount: 10,
    enc: false,
    sections: {'content', 'file', 'index', 'metatext', 'attachment'},
    nonBlankText: 51,
    totalText: 59,
    tables: 0,
    pictures: 12,
    embeddedCount: 3,
    embeddedBytes: 16161,
  ),
  _Expected(
    file: 'Travel expenses.osheet',
    bytes: 4207,
    format: OfficeNativeFormat.osheet,
    idSuffix: 'sh',
    ntype: 37,
    docCount: 8,
    enc: false,
    sections: {'define', 'index', 'locale', 'sh_1', 'style', 'metatext'},
    valueCells: 95,
    formulaValues: 30,
    sheetCount: 1,
  ),
  _Expected(
    file: 'office-convert-probe.odoc',
    bytes: 671,
    format: OfficeNativeFormat.odoc,
    idSuffix: 'doc',
    ntype: 21,
    docCount: 6,
    enc: false,
    sections: {'comment', 'content', 'index', 'metatext'},
    nonBlankText: 1,
    totalText: 1,
    tables: 0,
    pictures: 0,
  ),
];

void main() {
  group('真实文件闭环（/tmp/office-samples，8 份）', () {
    test('golden 身份：大小 + sha256 逐条一致', () {
      final golden = File('test/golden/office_native_real_samples.txt');
      expect(golden.existsSync(), isTrue, reason: 'golden 清单缺失');
      final rows = <String, List<String>>{};
      for (final line in golden.readAsLinesSync()) {
        if (line.trim().isEmpty || line.startsWith('#')) continue;
        final p = line.split('\t');
        rows[p[2]] = p;
      }
      expect(rows, hasLength(_expected.length));
      for (final e in _expected) {
        final r = rows[e.file];
        expect(r, isNotNull, reason: 'golden 缺 ${e.file}');
        expect(
          int.parse(r![1]),
          e.bytes,
          reason: '${e.file} golden 大小 == 设备报告大小',
        );
        final f = File('${_root.path}/${e.file}');
        if (!f.existsSync()) continue; // 缺失由逐份用例 skip 说明
        final b = f.readAsBytesSync();
        expect(b.length, e.bytes, reason: '${e.file} 磁盘大小');
        expect(_sha256Hex(b), r[0], reason: '${e.file} sha256');
      }
    });

    for (final e in _expected) {
      test('${e.file}：真实结构 + 解析数字对照', () {
        final path = '${_root.path}/${e.file}';
        final file = File(path);
        if (!file.existsSync()) {
          markTestSkipped('缺失真实样本：$path');
          return;
        }
        final bytes = file.readAsBytesSync();
        expect(bytes.length, e.bytes, reason: '${e.file} 大小');

        // 1) 独立链扫描：doc 数、头文档字段/类型/顺序、终止 doc。
        final chain = _rawChain(bytes, file: e.file);
        expect(chain.length, e.docCount, reason: '${e.file} 顶层 doc 数');
        expect(chain.first.elems.keys.toList(), [
          'schema',
          'enc',
          'id',
          'ver',
        ], reason: '${e.file} 头文档只放元数据且顺序如此');
        expect(
          chain.first.elems['schema']!.type,
          0x12,
          reason: 'schema 是 int64',
        );
        expect(chain.first.elems['enc']!.type, 0x08);
        final rawEnc = chain.first.elems['enc']!.value as bool;
        expect(rawEnc, e.enc, reason: '${e.file} enc 必须 false');
        final rawId = chain.first.elems['id']!.value as String;
        final rawVer = chain.first.elems['ver']!.value as String;
        expect(rawId, endsWith('.${e.idSuffix}'));
        expect(rawVer, hasLength(40), reason: 'ver 是 40 hex（语义未取证）');
        expect(
          RegExp(r'^[0-9a-f]{40}$').hasMatch(rawVer),
          isTrue,
          reason: 'ver hex',
        );
        expect(chain.last.elems.keys.toList(), ['end']);
        expect(chain.last.elems['end']!.type, 0x08);
        expect(chain.last.elems['end']!.value, isTrue);
        // 头文档长度由 id 串长决定：86 + len(id)。
        expect(chain.first.length, 86 + rawId.length);
        // metatext 明文副本：string 字面量 "null" 与 @C_metatext 同 doc。
        final metaDoc = chain.firstWhere(
          (d) => d.elems.containsKey('@C_metatext'),
        );
        expect(metaDoc.elems.containsKey('metatext'), isTrue);
        expect(metaDoc.elems['metatext']!.type, 0x02);
        expect(metaDoc.elems['metatext']!.value, 'null');
        // metabinary_files 出现次数 == 内嵌附件数。
        expect(
          chain.where((d) => d.elems.containsKey('metabinary_files')).length,
          e.embeddedCount,
          reason: '${e.file} metabinary_files doc 数',
        );

        // 2) 夹具头文档与真实头文档**逐字节**相同（独立拼装 vs 真实）。
        final headerOnly = buildTestOFile(
          sections: const {},
          id: rawId,
          ver: rawVer,
          includeMetatext: false,
          end: false,
        );
        expect(
          headerOnly.length,
          chain.first.length,
          reason: '${e.file} 夹具头文档长度',
        );
        expect(
          headerOnly,
          bytes.sublist(0, chain.first.length),
          reason: '${e.file} 夹具头文档应与真实头文档逐字节一致',
        );

        // 3) 真实文件跑我们的解析层（耗时/内存粗量）。
        final rssBefore = ProcessInfo.currentRss;
        final sw = Stopwatch()..start();
        final doc = OfficeNativeDocument.parse(bytes, fileName: e.file);
        sw.stop();
        final rssAfter = ProcessInfo.currentRss;
        // ignore: avoid_print
        print(
          'REAL_FILE ${e.file} bytes=${bytes.length} ms=${sw.elapsedMilliseconds} '
          'rssDeltaKB=${(rssAfter - rssBefore) ~/ 1024}',
        );

        expect(doc.format, e.format, reason: '${e.file} 格式');
        final of = doc.envelope;
        expect(of.schema, kOFileSchemaVersion);
        expect(of.enc, e.enc);
        expect(of.isPasswordProtected, isFalse);
        expect(of.id, rawId);
        expect(of.ver, rawVer, reason: 'ver 原样保留为 string');
        expect(of.idSuffix, e.idSuffix);
        expect(of.metaType, e.ntype, reason: 'metatext.ntype');
        expect(of.end, isTrue);
        expect(of.ended, isTrue);
        expect(of.documentCount, e.docCount);
        expect(of.consumedBytes, bytes.length);
        expect(of.totalBytes, bytes.length);
        expect(of.containerExact, isTrue, reason: 'consumed == size（8/8）');
        expect(of.hasEncryptedSections, isFalse);
        expect(of.hasOpaqueSections, isFalse);
        expect(
          of.metatext['encrypt'],
          isNull,
          reason: '真实 metatext 没有 encrypt 键',
        );
        expect(
          of.sectionNames.toSet(),
          e.sections,
          reason: '${e.file} section 名集合',
        );
        expect(of.sectionNames, isNot(contains('metabinary_files')));
        expect(of.embeddedFiles, hasLength(e.embeddedCount));
        expect(
          of.embeddedFiles.fold<int>(0, (s, f) => s + f.length),
          e.embeddedBytes,
          reason: '${e.file} 内嵌附件字节合计',
        );
        for (final f in of.embeddedFiles) {
          expect(f.rawKey, startsWith('{"name":"'));
          expect(f.name, isNotEmpty);
        }

        // 正文/单元格/页数：与设备报告独立数字对照。
        switch (e.format) {
          case OfficeNativeFormat.odoc:
            final d = doc.document!;
            expect(
              d.nodeTypeCounts['text'] ?? 0,
              e.totalText,
              reason: '${e.file} type=="text" 节点总数',
            );
            final cj = of.section('content')!.jsonMap;
            expect(
              _nonBlankTextNodes(cj),
              e.nonBlankText,
              reason: '${e.file} 非空白 text 节点数（设备报告口径）',
            );
            expect(d.tables.length, e.tables);
            expect(d.images.length, e.pictures);
          case OfficeNativeFormat.osheet:
            final w = doc.workbook!;
            expect(w.sheets, hasLength(e.sheetCount));
            expect(w.totalValueCellCount, e.valueCells);
            expect(w.sheets.single.id, 'sh_1');
            // 真实公式：`v` 以 `=` 开头，**没有 `f` 字段**（研究推测被否证）。
            final cells = w.sheets.single.allCells.toList();
            expect(cells.where((c) => c.formula != null), isEmpty);
            expect(
              cells.where((c) => c.isFormula).length,
              e.formulaValues,
              reason: '${e.file} v 以 = 开头的公式数',
            );
            for (final c in cells.where((c) => c.isFormula)) {
              expect(c.formulaText, startsWith('='));
              expect(c.text, c.value);
            }
            final stylePool = w.styles!;
            final sIds = cells
                .map((c) => c.styleIndex)
                .whereType<int>()
                .toList();
            expect(sIds, isNotEmpty);
            expect(
              sIds.reduce((a, b) => a < b ? a : b),
              greaterThanOrEqualTo(0),
            );
            expect(
              sIds.reduce((a, b) => a > b ? a : b),
              stylePool.styleCount,
              reason: '真实 osheet max(s) == styles.length（1 基推断仍成立）',
            );
          case OfficeNativeFormat.oslides:
            final p = doc.presentation!;
            expect(p.slides, hasLength(e.slides));
            expect(p.layoutCount, e.layouts);
            expect(
              p.nodeTypeCounts['text'] ?? 0,
              e.totalText,
              reason: '${e.file} type=="text" 节点总数',
            );
            final cj = of.section('content')!.jsonMap;
            expect(_nonBlankTextNodes(cj), e.nonBlankText);
            // 图片真实位置：Dynamic 的 6 张全在**母版**，不在任何 slide 正文。
            expect(p.master.images.length, e.masterImages);
            expect(p.imageCount, 0, reason: 'slide 正文里没有 image 节点');
        }
      }, skip: _skipReason ?? false);
    }

    test('汇总：8/8 enc=false、8/8 consumed==size（2a 由真实文件证明）', () {
      final files = [
        for (final e in _expected) File('${_root.path}/${e.file}'),
      ];
      if (files.any((f) => !f.existsSync())) {
        markTestSkipped(_skipReason ?? '部分样本缺失');
        return;
      }
      var ok = 0;
      for (final f in files) {
        final doc = OfficeNativeDocument.parse(
          f.readAsBytesSync(),
          fileName: f.path.split('/').last,
        );
        expect(doc.envelope.enc, isFalse);
        expect(doc.envelope.isPasswordProtected, isFalse);
        expect(doc.envelope.metatext['encrypt'], isNull);
        expect(doc.envelope.containerExact, isTrue);
        ok++;
      }
      expect(ok, 8);
    }, skip: _skipReason ?? false);

    test('Dynamic.oslides（9.2 MB）不卡死：解析 < 5s 且模型完整', () {
      final f = File('${_root.path}/Dynamic.oslides');
      if (!f.existsSync()) {
        markTestSkipped(_skipReason ?? 'Dynamic.oslides 缺失');
        return;
      }
      final bytes = f.readAsBytesSync();
      final sw = Stopwatch()..start();
      final doc = OfficeNativeDocument.parse(
        bytes,
        fileName: 'Dynamic.oslides',
      );
      sw.stop();
      // ignore: avoid_print
      print('REAL_FILE_PERF Dynamic.oslides ms=${sw.elapsedMilliseconds}');
      expect(sw.elapsedMilliseconds, lessThan(5000));
      expect(doc.presentation!.slides, hasLength(15));
      expect(doc.envelope.embeddedFiles, hasLength(6));
    }, skip: _skipReason ?? false);
  });
}
