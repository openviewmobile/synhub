// 阶段 2a 的 OFile **离线闭环** + 加密拒绝 + 错误路径测试。
//
// ⚠️ 诚实声明（2026-09 真实文件修正后）：本文件用的 `.odoc/.osheet/.oslides` 外壳由
// `test/support/ofile_fixture.dart` 按 **8 份真实文件实测结构**装配（不是研究推测）：
// `[int32 len][BSON doc]` 链、头文档只放 `schema/enc/id/ver`、section 各占一 doc、
// `@C_metatext` 与明文 `metatext` 同 doc、`metabinary_files`、链尾 `{"end":true}`。
// 样本文字仍取自包内官方 `template/**/text.json`（不 vendored，缺失 skip）。
// 真实文件的端到端对照见 `test/office_native_real_samples_test.dart`。
//
// 样本：`template/sheet/*`（13）/ `template/doc/*`（16）/ `template/slides/*`（24），
// 包内官方样本、不 vendored；缺失时整组 skip 并写明原因。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/odoc_model.dart';
import 'package:synhub/src/data/office_native/office_native_reader.dart';
import 'package:synhub/src/data/office_native/ofile.dart';
import 'package:synhub/src/data/office_native/osheet_model.dart';
import 'package:synhub/src/data/office_native/oslides_model.dart';

import 'support/ofile_fixture.dart';
import 'support/office_samples.dart';

final Directory _root = Directory(
  officeTemplateRoot().path,
);

final String? _skipReason = _root.existsSync()
    ? null
    : '官方样本缺失：${_root.path}（包内样本，不 vendored；'
          '见 docs/office-native-format-research.md §5）';

List<String> _sampleNames(String kind) {
  final dir = Directory('${_root.path}/$kind');
  if (!dir.existsSync()) return const [];
  final names =
      dir
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split('/').last)
          .toList()
        ..sort();
  return names;
}

Map<String, Object?> _readJson(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>();

// --- 独立顶层链扫描（只用 int32 长度前缀 + 首元素 type/key，不依赖 lib）------

int _firstDocLength(Uint8List b) =>
    b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);

List<String> _chainFirstElements(Uint8List b, {required String what}) {
  final out = <String>[];
  var off = 0;
  while (off < b.length) {
    final len =
        b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);
    expect(
      len >= 5 && off + len <= b.length,
      isTrue,
      reason: '$what: doc @$off len=$len 越界',
    );
    expect(b[off + len - 1], 0, reason: '$what: doc @$off 缺 BSON 终结符');
    final t = b[off + 4].toRadixString(16).padLeft(2, '0');
    var z = off + 5;
    while (b[z] != 0) {
      z++;
    }
    out.add('$t:${utf8.decode(b.sublist(off + 5, z))}');
    off += len;
  }
  expect(off, b.length, reason: '$what: consumed != size');
  return out;
}

// --- 模型"逐字段"签名（把模型里所有可观测字段序列化成可比字符串）-----------

String _sortedCounts(Map<String, int> counts) {
  final keys = counts.keys.toList()..sort();
  return keys.map((k) => '$k=${counts[k]}').join(',');
}

String _sheetSig(OSheetWorkbook w) {
  final b = StringBuffer()
    ..writeln(
      'idx order=${w.index.order.join(",")} schemaVersion=${w.index.schemaVersion} '
      'ver=${w.index.ver} gcVer=${w.index.gcVer} maxIndex=${w.index.maxIndex}',
    )
    ..writeln(
      'styles=${w.styles?.styleCount} sections=${w.sectionNames.join(",")}',
    );
  for (final s in w.sheets) {
    b.writeln(
      'sheet ${s.id} title=${s.title} rows=${s.rowCount} cols=${s.colCount} '
      'cells=${s.cellCount} values=${s.valueCellCount} text=${jsonEncode(s.plainText)}',
    );
    final rows = s.cells.keys.toList()..sort();
    for (final r in rows) {
      final cols = s.cells[r]!.keys.toList()..sort();
      for (final c in cols) {
        final cell = s.cells[r]![c]!;
        b.writeln(
          '  $r,$c s=${cell.styleIndex} v=${jsonEncode(cell.value)} '
          'f=${cell.formula} t=${jsonEncode(cell.text)}',
        );
      }
    }
  }
  return b.toString();
}

String _docSig(ODocDocument d) {
  final p = d.pageSetup;
  final b = StringBuffer()
    ..writeln(
      'schema=${d.schema} version=${d.version} comments=${d.commentCount} '
      'idxSchema=${d.indexSchemaVersion} sections=${d.sectionNames.join(",")}',
    )
    ..writeln(
      'page=${p.left},${p.top},${p.right},${p.bottom},${p.orientation},${p.pageType}',
    )
    ..writeln(
      'blocks=${d.blocks.length} headings=${d.headings.length} '
      'lists=${d.listItems.length} tables=${d.tables.length} '
      'images=${d.images.length} textLen=${d.textLength} '
      'decorate=${d.pageDecorate != null}',
    )
    ..writeln('types=${_sortedCounts(d.nodeTypeCounts)}')
    ..writeln('text=${d.plainText}');
  return b.toString();
}

String _slidesSig(OSlidesPresentation p) {
  final b = StringBuffer()
    ..writeln(
      'schema=${p.schema} cx=${p.cx} cy=${p.cy} layouts=${p.layoutCount} '
      'textLen=${p.textLength} images=${p.imageCount} '
      'sections=${p.sectionNames.join(",")}',
    )
    ..writeln('types=${_sortedCounts(p.nodeTypeCounts)}')
    ..writeln('master=${jsonEncode(p.master.plainText)}');
  for (final s in p.slides) {
    b.writeln(
      'slide ${s.order} id=${s.id} master=${s.masterId} layout=${s.layoutId} '
      'visible=${s.isVisible} blocks=${s.blocks.length} '
      'text=${jsonEncode(s.plainText)} notes=${jsonEncode(s.notes)}',
    );
  }
  return b.toString();
}

/// 自造 OFile → parse；与直接喂 JSON 的模型逐字段比对。
void _assertRoundTrip(
  String name,
  Map<String, Object?> raw,
  OfficeNativeFormat fmt,
) {
  final bytes = buildTestOFile(sections: raw, id: name);
  final doc = OfficeNativeDocument.parse(bytes, format: fmt);
  final direct = OfficeNativeReader.parseSections(raw, format: fmt);

  expect(doc.format, fmt, reason: '$name: 格式');
  expect(doc.envelope.schema, kOFileSchemaVersion, reason: '$name: 外壳 schema');
  expect(doc.hasEncryptedSections, isFalse, reason: '$name: 不该有加密 section');
  expect(doc.envelope.isPasswordProtected, isFalse, reason: '$name: 不该有打开密码');

  // 1) 每个 section 的 JSON 必须与原始 text.json 逐字段一致。
  for (final key in raw.keys) {
    final section = doc.envelope.section(key);
    expect(section, isNotNull, reason: '$name: 缺 section "$key"');
    expect(
      section!.state,
      OFileSectionState.inflatedJson,
      reason: '$name/$key: 应走 binary→inflate→JSON',
    );
    expect(
      section.bsonKey,
      fixtureSectionKey(key),
      reason: '$name/$key: BSON 字段名',
    );
    expect(section.json, equals(raw[key]), reason: '$name/$key: 逐字段不一致');
  }

  // 2) 模型必须与"直接喂 JSON"逐字段一致。
  switch (fmt) {
    case OfficeNativeFormat.osheet:
      final a = _sheetSig(doc.workbook!);
      expect(a, _sheetSig(direct.workbook!), reason: '$name: sheet 模型不一致');
      // ignore: avoid_print
      print(
        'OFILE_ROUNDTRIP sheet $name cells=${doc.workbook!.totalCellCount} '
        'values=${doc.workbook!.totalValueCellCount} '
        'styles=${doc.workbook!.styles?.styleCount ?? 0} 一致=100%',
      );
    case OfficeNativeFormat.odoc:
      final a = _docSig(doc.document!);
      expect(a, _docSig(direct.document!), reason: '$name: doc 模型不一致');
      // ignore: avoid_print
      print(
        'OFILE_ROUNDTRIP doc $name blocks=${doc.document!.blocks.length} '
        'textLen=${doc.document!.textLength} 一致=100%',
      );
    case OfficeNativeFormat.oslides:
      final a = _slidesSig(doc.presentation!);
      expect(
        a,
        _slidesSig(direct.presentation!),
        reason: '$name: slides 模型不一致',
      );
      // ignore: avoid_print
      print(
        'OFILE_ROUNDTRIP slides $name pages=${doc.presentation!.slides.length} '
        'textLen=${doc.presentation!.textLength} 一致=100%',
      );
  }
}

void main() {
  group('自造 OFile 往返（13 份 sheet 样本）', () {
    for (final name in _sampleNames('sheet')) {
      test(name, () {
        final raw = _readJson('${_root.path}/sheet/$name/text.json');
        _assertRoundTrip(name, raw, OfficeNativeFormat.osheet);
      }, skip: _skipReason ?? false);
    }
  });

  group('自造 OFile 往返（16 份 doc 样本）', () {
    for (final name in _sampleNames('doc')) {
      test(name, () {
        final raw = _readJson('${_root.path}/doc/$name/text.json');
        _assertRoundTrip(name, raw, OfficeNativeFormat.odoc);
      }, skip: _skipReason ?? false);
    }
  });

  group('自造 OFile 往返（24 份 slides 样本）', () {
    for (final name in _sampleNames('slides')) {
      test(name, () {
        final raw = _readJson('${_root.path}/slides/$name/text.json');
        _assertRoundTrip(name, raw, OfficeNativeFormat.oslides);
      }, skip: _skipReason ?? false);
    }
  });

  group('section 名拼装（@C_ / text/）', () {
    test('oFileLogicalSectionName 只认 @C_ 前缀，text/ 再剥一层', () {
      expect(oFileLogicalSectionName('@C_text/index'), 'index');
      expect(oFileLogicalSectionName('@C_text/sh_1'), 'sh_1');
      expect(oFileLogicalSectionName('@C_text/content'), 'content');
      expect(oFileLogicalSectionName('@C_text/attachment'), 'attachment');
      expect(oFileLogicalSectionName('@C_metatext'), 'metatext');
      expect(oFileLogicalSectionName('@C_weird/thing'), 'weird/thing');
      // 没有 @C_ 前缀的旧字段名不是压缩 section。
      expect(oFileLogicalSectionName('index'), isNull);
      expect(oFileLogicalSectionName('metatext'), isNull);
    });

    test('oFileBsonKeyForSection 逆向拼装', () {
      expect(oFileBsonKeyForSection('index'), '@C_text/index');
      expect(oFileBsonKeyForSection('metatext'), '@C_metatext');
    });

    test('@C_text/* 解出的逻辑名 + state=inflatedJson', () {
      final bytes = buildTestOFile(
        sections: {
          'index': {
            'order': ['sh_1'],
            'sheets': {
              'sh_1': {'title': 'T'},
            },
          },
          'sh_1': {
            'cells': {
              '0': {
                '0': {'v': 'x'},
              },
            },
            'rowCount': 1,
            'colCount': 1,
          },
          'style': {'styles': []},
          'define': {},
        },
      );
      final of = OFile.parse(bytes);
      expect(of.schema, kOFileSchemaVersion);
      expect(of.sheetSectionNames, ['sh_1']);
      expect(of.section('index')!.bsonKey, '@C_text/index');
      expect(of.section('index')!.state, OFileSectionState.inflatedJson);
      expect(of.section('sh_1')!.bsonKey, '@C_text/sh_1');
      expect(of.section('style')!.name, 'style');
      expect(of.section('metatext')!.bsonKey, '@C_metatext');
      // 真实 @C_metatext 没有 encrypt 键（8 份实测）；夹具默认给真实形状。
      expect(of.metatext['encrypt'], isNull);
      expect(of.metatext['oflie'], isTrue);
      expect(of.isPasswordProtected, isFalse);
    });
  });

  group('夹具结构 == 真实结构（不依赖真实样本）', () {
    test('链形：头文档首个元素 schema(0x12)，section 各占一 doc，尾部 {"end":true}', () {
      final bytes = buildTestOFile(
        sections: {
          'index': {
            'order': ['sh_1'],
            'sheets': {
              'sh_1': {'title': 'T'},
            },
          },
          'sh_1': {
            'cells': {
              '0': {
                '0': {'v': 'x'},
              },
            },
          },
          'style': {'styles': []},
          'define': <String, Object?>{},
        },
        embeddedFiles: {
          'aabbccdd': [0x89, 0x50, 0x4E, 0x47],
        },
      );
      expect(_chainFirstElements(bytes, what: 'fixture'), [
        '12:schema',
        '05:@C_text/index',
        '05:@C_text/sh_1',
        '05:@C_text/style',
        '05:@C_text/define',
        '05:@C_metatext',
        '03:metabinary_files',
        '08:end',
      ]);
    });

    test('头文档布局 == 真实：长度 86+len(id)，首 16 字节与真实 odoc 一致', () {
      final bytes = buildTestOFile(
        sections: const {},
        includeMetatext: false,
        end: false,
        id: '1028_AAAAAAAAAAAAAAAAAAAAAAAAAA.doc',
        ver: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      expect(_firstDocLength(bytes), 121, reason: '86 + len(id)=35');
      expect(bytes.sublist(0, 16), <int>[
        0x79, 0x00, 0x00, 0x00, // int32 LE 头文档长度 = 121
        0x12, 0x73, 0x63, 0x68, 0x65, 0x6D, 0x61, 0x00, // 0x12 int64 "schema"
        0x03, 0x00, 0x00, 0x00, // int64 = 3
      ]);
    });
  });

  group('带打开密码（encrypt == true）→ 明确拒绝', () {
    final bytes = buildTestOFile(
      encrypt: true,
      sections: {
        'index': {
          'order': ['sh_1'],
          'sheets': {
            'sh_1': {'title': 'T'},
          },
        },
        'sh_1': {
          'cells': {
            '0': {
              '0': {'v': 'secret'},
            },
          },
        },
      },
    );

    test('OFile.parse 能识别 encrypt==true（section 不会假装读出）', () {
      final of = OFile.parse(bytes);
      expect(of.isPasswordProtected, isTrue);
      expect(of.metatext['encrypt'], isTrue);
      expect(of.enc, isTrue);
      final index = of.section('index')!;
      expect(index.state, OFileSectionState.encrypted);
      expect(index.passwordProtected, isTrue);
      expect(index.json, isNull);
      // inflate 后是 base64(prefix‖salt‖ct)：解码后前 8 字节 = 官方前缀。
      expect(
        base64.decode(index.text!.trim()).sublist(0, 8),
        utf8.encode('Saltv2c_'),
      );
    });

    test('requireSection 抛 OfficeDocumentPasswordProtectedException', () {
      final of = OFile.parse(bytes);
      expect(
        () => of.requireSection('index'),
        throwsA(
          isA<OfficeDocumentPasswordProtectedException>().having(
            (e) => e.message,
            'message',
            contains('该文档带打开密码'),
          ),
        ),
      );
    });

    test('parse 抛专属文案：不是"解析失败"/"文件损坏"', () {
      Object? caught;
      try {
        OfficeNativeDocument.parse(bytes, fileName: 'secret.osheet');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<OfficeDocumentPasswordProtectedException>());
      final msg = (caught! as OfficeDocumentPasswordProtectedException).message;
      expect(msg, contains('该文档带打开密码'));
      expect(msg, contains('本阅读器暂不支持解密'));
      expect(msg, contains('阶段 2b'));
      expect(msg, contains('这不是文件损坏'));
      expect(msg, contains('不是格式不支持'));
      expect(msg, isNot(contains('解析失败')));
      expect(
        OfficeDocumentPasswordProtectedException.codeWire,
        'E_OFFICE_PASSWORD_PROTECTED',
      );
    });

    test('没有文件名/格式时也优先报"打开密码"（不落进格式判别失败）', () {
      // content-only：外壳无法区分 doc/slides，但密码判定必须先于格式判别。
      final contentOnly = buildTestOFile(
        encrypt: true,
        sections: {
          'content': {
            'data': {
              'attrs': {'type': 'document'},
              'content': [],
            },
          },
        },
      );
      expect(
        () => OfficeNativeDocument.parse(contentOnly),
        throwsA(isA<OfficeDocumentPasswordProtectedException>()),
      );
    });

    test('inspect 不抛：passwordProtected=true、模型留空、notice 是专属文案', () {
      final doc = OfficeNativeReader.inspect(bytes, fileName: 'secret.osheet');
      expect(doc.hasModel, isFalse);
      expect(doc.passwordProtected, isTrue);
      expect(doc.encryptionNotice, contains('该文档带打开密码'));
      expect(doc.encryptionNotice, contains('本阅读器暂不支持解密'));
    });
  });

  group('错误与边界（各有专属错误码）', () {
    test('截断 BSON → E_OFILE_BSON_TRUNCATED', () {
      final full = buildTestOFile(
        sections: {
          'index': {
            'order': ['sh_1'],
            'sheets': {
              'sh_1': {'title': 'T'},
            },
          },
          'sh_1': {
            'cells': {
              '0': {
                '0': {'v': 'x'},
              },
            },
          },
        },
      );
      final truncated = Uint8List.fromList(full.sublist(0, full.length - 12));
      expect(
        () => OFile.parse(truncated),
        throwsA(
          isA<OFileFormatException>().having(
            (e) => e.code,
            'code',
            OFileErrorCode.truncatedBson,
          ),
        ),
      );
    });

    test('未知 BSON type byte → E_OFILE_BSON_UNSUPPORTED_TYPE', () {
      final w = TestBsonWriter();
      w.int32('schema', 3);
      w.rawElement(0x42, 'weird', [0, 0, 0, 0]);
      expect(
        () => OFile.parse(w.finish()),
        throwsA(
          isA<OFileFormatException>().having(
            (e) => e.code,
            'code',
            OFileErrorCode.unsupportedBsonType,
          ),
        ),
      );
    });

    test('缺 schema → E_OFILE_SCHEMA_MISSING', () {
      final bytes = buildTestOFile(sections: const {}, includeSchema: false);
      expect(
        () => OFile.parse(bytes),
        throwsA(
          isA<OFileFormatException>()
              .having((e) => e.code, 'code', OFileErrorCode.missingSchema)
              .having((e) => e.message, 'message', contains('schema')),
        ),
      );
    });

    test('schema != 3 → E_OFILE_SCHEMA_VERSION（含向后拒绝语义）', () {
      final bytes = buildTestOFile(sections: const {}, schema: 4);
      expect(
        () => OFile.parse(bytes),
        throwsA(
          isA<OFileFormatException>()
              .having(
                (e) => e.code,
                'code',
                OFileErrorCode.unsupportedSchemaVersion,
              )
              .having((e) => e.message, 'message', contains('向后拒绝')),
        ),
      );
      final older = buildTestOFile(sections: const {}, schema: 2);
      expect(
        () => OFile.parse(older),
        throwsA(
          isA<OFileFormatException>().having(
            (e) => e.code,
            'code',
            OFileErrorCode.unsupportedSchemaVersion,
          ),
        ),
      );
    });

    test('缺 @C_text/index（.osheet）→ E_OFILE_INDEX_MISSING', () {
      final bytes = buildTestOFile(
        sections: {
          'sh_1': {
            'cells': {
              '0': {
                '0': {'v': 'x'},
              },
            },
          },
        },
      );
      expect(
        () => OfficeNativeReader.inspect(
          bytes,
          format: OfficeNativeFormat.osheet,
        ),
        throwsA(
          isA<OFileFormatException>()
              .having((e) => e.code, 'code', OFileErrorCode.missingIndexSection)
              .having((e) => e.sectionName, 'sectionName', 'index'),
        ),
      );
    });

    test('缺 @C_text/content（.odoc）→ E_OFILE_CONTENT_MISSING', () {
      final bytes = buildTestOFile(
        sections: {
          'index': {'schemaVersion': 13},
        },
      );
      expect(
        () =>
            OfficeNativeReader.inspect(bytes, format: OfficeNativeFormat.odoc),
        throwsA(
          isA<OFileFormatException>().having(
            (e) => e.code,
            'code',
            OFileErrorCode.missingContentSection,
          ),
        ),
      );
    });

    test('@C_ binary 不是合法 zlib 流 → E_OFILE_ZLIB_INVALID', () {
      final w = TestBsonWriter();
      w.int32('schema', 3);
      w.boolean('enc', false);
      w.binary('@C_text/index', [0x00, 0x01, 0x02, 0x03, 0x04, 0x05]);
      expect(
        () => OFile.parse(w.finish()),
        throwsA(
          isA<OFileFormatException>()
              .having((e) => e.code, 'code', OFileErrorCode.invalidZlibPayload)
              .having((e) => e.sectionName, 'sectionName', 'index'),
        ),
      );
    });

    test('@C_ binary 为空 → E_OFILE_ZLIB_INVALID', () {
      final w = TestBsonWriter();
      w.int32('schema', 3);
      w.binary('@C_text/index', const []);
      expect(
        () => OFile.parse(w.finish()),
        throwsA(
          isA<OFileFormatException>().having(
            (e) => e.code,
            'code',
            OFileErrorCode.invalidZlibPayload,
          ),
        ),
      );
    });

    test('metatext 缺 encrypt 字段 → 按无密码（2a）处理', () {
      final bytes = buildTestOFile(
        metatext: {'foo': 'bar'},
        sections: {
          'index': {
            'order': ['sh_1'],
            'sheets': {
              'sh_1': {'title': 'T'},
            },
          },
          'sh_1': {
            'cells': {
              '0': {
                '0': {'v': 'x'},
              },
            },
          },
        },
      );
      final doc = OfficeNativeDocument.parse(
        bytes,
        format: OfficeNativeFormat.osheet,
      );
      expect(doc.envelope.isPasswordProtected, isFalse);
      expect(doc.envelope.metatext['encrypt'], isNull);
      expect(doc.hasModel, isTrue);
      expect(doc.workbook!.sheets.single.cellAt(0, 0)!.value, 'x');
    });

    test('缺 @C_metatext 外壳仍可解（enc 缺失按 false）', () {
      final bytes = buildTestOFile(
        includeMetatext: false,
        sections: {
          'index': {
            'order': ['sh_1'],
            'sheets': {
              'sh_1': {'title': 'T'},
            },
          },
          'sh_1': {
            'cells': {
              '0': {
                '0': {'v': 'x'},
              },
            },
          },
        },
      );
      final doc = OfficeNativeDocument.parse(
        bytes,
        format: OfficeNativeFormat.osheet,
      );
      expect(doc.envelope.metatext, isEmpty);
      expect(doc.envelope.isPasswordProtected, isFalse);
      expect(doc.hasModel, isTrue);
    });
  });

  test('样本计数（缺样本时整组 skip 有据可查）', () {
    if (_skipReason != null) {
      markTestSkipped(_skipReason!);
      return;
    }
    expect(_sampleNames('sheet'), hasLength(13));
    expect(_sampleNames('doc'), hasLength(16));
    expect(_sampleNames('slides'), hasLength(24));
  }, skip: _skipReason ?? false);
}
