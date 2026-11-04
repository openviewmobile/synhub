// OFile（BSON 外壳 + zlib section）与统一入口的单元测试。
//
// 关键验收点：
//   1. 顶层 `schema`/`enc`/`id`/`ver`/`end` 与 section 分类（json/inflatedJson/binary/scalar）；
//   2. **加密 section 必须明确报告"需阶段 2"**，不得返回空内容；
//   3. `.osheet` 的加密 section 会让 `parse()` 抛 `OfficeSectionEncryptedException`，
//      而 `inspect()` 只如实记录、不抛。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibEncoder;
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/office_native_reader.dart';
import 'package:synhub/src/data/office_native/ofile.dart';

// --- 最小 BSON 构造器（测试用） ---------------------------------------------

Uint8List _i32(int v) {
  final d = ByteData(4)..setInt32(0, v, Endian.little);
  return d.buffer.asUint8List();
}

class _B {
  final BytesBuilder _b = BytesBuilder();

  void _elem(int type, String key, List<int> payload) {
    _b.addByte(type);
    _b.add(utf8.encode(key));
    _b.addByte(0);
    _b.add(payload);
  }

  void int32(String k, int v) => _elem(0x10, k, _i32(v));

  void string(String k, String v) {
    final bytes = utf8.encode(v);
    final p = BytesBuilder();
    p.add(_i32(bytes.length + 1));
    p.add(bytes);
    p.addByte(0);
    _elem(0x02, k, p.toBytes());
  }

  void bool_(String k, bool v) => _elem(0x08, k, [v ? 1 : 0]);

  void binary(String k, int subtype, List<int> bytes) {
    final p = BytesBuilder();
    p.add(_i32(bytes.length));
    p.addByte(subtype);
    p.add(bytes);
    _elem(0x05, k, p.toBytes());
  }

  Uint8List finish() {
    final body = _b.toBytes();
    final out = BytesBuilder();
    out.add(_i32(body.length + 5));
    out.add(body);
    out.addByte(0);
    return out.toBytes();
  }
}

String _b64ZlibJson(Object json) =>
    base64.encode(ZLibEncoder().encodeBytes(utf8.encode(jsonEncode(json))));

/// 一份"明文的" .osheet 外壳（section 全部是 base64+zlib 的 JSON）。
Uint8List _plainSheetOFile() {
  final b = _B();
  // OFILE_SCHEMA_VERSION 已取证 = 3（研究文档 §2.3）；13 是 content attrs.schema，
  // 不是外壳 schema。这里用真值 3。
  b.int32('schema', 3);
  b.bool_('enc', false);
  b.string('id', 'obj-1');
  // 真实头文档 `ver` 是 string（40 hex），不是 int（2026-09 真实文件修正）。
  b.string('ver', '0123456789abcdef0123456789abcdef01234567');
  b.bool_('end', true);
  b.string(
    'index',
    _b64ZlibJson({
      'gcVer': 1,
      'maxIndex': 2,
      'order': ['sh_1'],
      'schemaVersion': 5,
      'ver': 1,
      'sheets': {
        'sh_1': {'deleted': false, 'title': 'Sheet One'},
      },
    }),
  );
  b.string(
    'style',
    _b64ZlibJson({
      'styles': [
        [1, 2, 3, 4, 5, 6],
      ],
      'fonts': [],
    }),
  );
  b.string('define', _b64ZlibJson({}));
  b.string('comment', '{"data":[]}');
  b.string(
    'sh_1',
    _b64ZlibJson({
      'cells': {
        '0': {
          '0': {'s': 0, 'v': 'Hello'},
          '2': {'v': 1500},
        },
        '1': {
          '1': {'s': 0, 'v': 'World'},
        },
      },
      'colCount': 4,
      'rowCount': 2,
    }),
  );
  b.binary('image.1', 0x00, [0x89, 0x50, 0x4E, 0x47]);
  return b.finish();
}

void main() {
  group('OFile 外壳', () {
    test('顶层字段与 section 分类', () {
      final ofile = OFile.parse(_plainSheetOFile());

      expect(ofile.schema, 3);
      expect(ofile.enc, isFalse);
      expect(ofile.id, 'obj-1');
      expect(ofile.ver, '0123456789abcdef0123456789abcdef01234567');
      expect(ofile.end, isTrue);
      expect(
        ofile.sectionNames,
        containsAll(['index', 'style', 'define', 'comment', 'sh_1', 'image.1']),
      );
      expect(ofile.sheetSectionNames, ['sh_1']);
      expect(ofile.section('index')!.state, OFileSectionState.inflatedJson);
      expect(ofile.section('comment')!.state, OFileSectionState.json);
      expect(ofile.section('image.1')!.state, OFileSectionState.binary);
      expect(ofile.section('image.1')!.bytes, [0x89, 0x50, 0x4E, 0x47]);
      expect(ofile.hasEncryptedSections, isFalse);

      final index = ofile.requireSection('index').jsonMap!;
      expect(index['sheets'], isA<Map>());
      expect(ofile.requireSection('index').text, contains('sh_1'));
    });

    test('非 BSON 字节 → OFileFormatException（不猜内容）', () {
      expect(
        () =>
            OFile.parse(Uint8List.fromList(utf8.encode('PK\x03\x04 not bson'))),
        throwsA(isA<OFileFormatException>()),
      );
    });

    test('标量 section 原样保留为 scalar', () {
      final b = _B();
      b.int32('schema', 3);
      b.int32('weird', 42);
      final ofile = OFile.parse(b.finish());
      expect(ofile.section('weird')!.state, OFileSectionState.scalar);
      expect(ofile.section('weird')!.rawValue, 42);
    });
  });

  group('加密 section（阶段 1 边界）', () {
    Uint8List encryptedOFile() {
      final b = _B();
      b.int32('schema', 3);
      b.bool_('enc', true);
      b.string('id', 'obj-enc');
      // 密文特征：base64 能解，但 zlib inflate 必然失败（随机字节）。
      b.string(
        'content',
        base64.encode(List<int>.generate(256, (i) => (i * 37) % 251)),
      );
      b.string(
        'index',
        base64.encode(List<int>.generate(64, (i) => (i * 91) % 253)),
      );
      return b.finish();
    }

    test('state=encrypted + detail 指出 zlib/AES 特征（不假装读出内容）', () {
      final ofile = OFile.parse(encryptedOFile());
      final content = ofile.section('content')!;
      expect(content.state, OFileSectionState.encrypted);
      expect(content.isEncrypted, isTrue);
      expect(content.json, isNull);
      expect(content.text, isNull);
      expect(content.detail, contains('inflate'));
      expect(ofile.hasEncryptedSections, isTrue);
      expect(
        ofile.encryptedSections.map((s) => s.name),
        containsAll(['content']),
      );
    });

    test('requireSection 抛 OfficeSectionEncryptedException，原文含"阶段 2"', () {
      final ofile = OFile.parse(encryptedOFile());
      expect(
        () => ofile.requireSection('content'),
        throwsA(
          isA<OfficeSectionEncryptedException>()
              .having((e) => e.sectionName, 'sectionName', 'content')
              .having((e) => e.message, 'message', contains('阶段 2'))
              .having((e) => e.message, 'message', contains('AES-256-CBC')),
        ),
      );
      expect(
        () => ofile.requireSection('index'),
        throwsA(isA<OfficeSectionEncryptedException>()),
      );
    });

    test('inspect 不抛：报告 encryptionNotice，模型留空', () {
      final doc = OfficeNativeReader.inspect(
        encryptedOFile(),
        fileName: 'x.osheet',
      );
      expect(doc.hasModel, isFalse);
      expect(doc.hasEncryptedSections, isTrue);
      expect(doc.encryptedSectionNames, contains('index'));
      expect(doc.encryptionNotice, contains('阶段 2'));
      expect(doc.encryptionNotice, contains('AES-256-CBC'));
      expect(doc.envelope.enc, isTrue);
      expect(doc.envelope.id, 'obj-enc');
    });

    test('parse 对加密的必需 section 直接抛异常（不返回空模型）', () {
      expect(
        () => OfficeNativeReader.parse(encryptedOFile(), fileName: 'x.osheet'),
        throwsA(isA<OfficeSectionEncryptedException>()),
      );
      expect(
        () => OfficeNativeReader.parse(encryptedOFile(), fileName: 'x.odoc'),
        throwsA(isA<OfficeSectionEncryptedException>()),
      );
    });
  });

  group('统一入口（解析层）', () {
    test('parse 明文 .osheet → OSheetWorkbook', () {
      final doc = OfficeNativeReader.parse(
        _plainSheetOFile(),
        fileName: 'budget.osheet',
      );
      expect(doc.format, OfficeNativeFormat.osheet);
      final workbook = doc.workbook!;
      expect(workbook.sheets, hasLength(1));
      expect(workbook.sheets.single.title, 'Sheet One');
      expect(workbook.sheets.single.cellAt(0, 0)!.text, 'Hello');
      expect(workbook.sheets.single.cellAt(0, 2)!.value, 1500);
      // `s` 按 1 基解释（13 份官方样本一致支持的推断）。
      expect(workbook.styles!.slotsAt(1), [1, 2, 3, 4, 5, 6]);
      expect(workbook.styles!.slotsAt(0), isNull);
      expect(workbook.styles!.slotsAt(2), isNull);
      expect(workbook.styles!.rawStyleAt(0), [1, 2, 3, 4, 5, 6]);
      expect(doc.hasEncryptedSections, isFalse);
      expect(doc.encryptionNotice, isNull);
    });

    test('扩展名判定（大小写不敏感）', () {
      expect(OfficeNativeReader.canParseFileName('A.ODOC'), isTrue);
      expect(OfficeNativeReader.canParseFileName('B.OSHEET'), isTrue);
      expect(OfficeNativeReader.canParseFileName('C.oslides'), isTrue);
      expect(OfficeNativeReader.canParseFileName('C.docx'), isFalse);
      expect(
        OfficeNativeReader.formatForFileName('x.Oslides'),
        OfficeNativeFormat.oslides,
      );
      expect(OfficeNativeReader.formatForFileName('noext'), isNull);
    });

    test('明文 .osheet 但 index/sh_* 被加密 → parse 抛，inspect 报告', () {
      final b = _B();
      b.int32('schema', 3);
      b.bool_('enc', true);
      b.string('index', base64.encode(List<int>.filled(96, 0x5A)));
      b.string('sh_1', base64.encode(List<int>.filled(96, 0xA5)));
      final encryptedOnly = b.finish();

      final inspected = OfficeNativeReader.inspect(
        encryptedOnly,
        fileName: 'x.osheet',
      );
      expect(inspected.hasModel, isFalse);
      expect(inspected.encryptedSectionNames, containsAll(['index', 'sh_1']));

      expect(
        () => OfficeNativeReader.parse(encryptedOnly, fileName: 'x.osheet'),
        throwsA(isA<OfficeSectionEncryptedException>()),
      );
    });
  });
}
