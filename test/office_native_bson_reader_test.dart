// BSON 只读解析器（`lib/src/data/office_native/bson/bson_reader.dart`）的单元测试。
//
// 用**手工构造的 BSON 字节**做 oracle：期望值来自 BSON 规范，而不是"跑一遍实现再看结果"。
// 覆盖：double/string/document/array/binary/bool/null/int32/int64/objectId/date/regex
// （任务要求的子集）+ timestamp/undefined/js/symbol/dbPointer/decimal128/minKey/maxKey
// （实现里顺带支持的部分）+ 各类畸形输入的错误路径。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/bson/bson_reader.dart';

Uint8List _le32(int v) {
  final d = ByteData(4)..setInt32(0, v, Endian.little);
  return d.buffer.asUint8List();
}

Uint8List _leU32(int v) {
  final d = ByteData(4)..setUint32(0, v, Endian.little);
  return d.buffer.asUint8List();
}

Uint8List _le64(int v) {
  final d = ByteData(8)..setInt64(0, v, Endian.little);
  return d.buffer.asUint8List();
}

/// 极简 BSON **构造器**（只测试用；生产代码本批只读）。
class BsonEmit {
  final BytesBuilder _b = BytesBuilder();

  void _elem(int type, String key, List<int> payload) {
    _b.addByte(type);
    _b.add(utf8.encode(key));
    _b.addByte(0);
    _b.add(payload);
  }

  Uint8List toDocument() {
    final body = _b.toBytes();
    final out = BytesBuilder();
    out.add(_le32(body.length + 5));
    out.add(body);
    out.addByte(0);
    return out.toBytes();
  }

  void double_(String k, double v) {
    final d = ByteData(8)..setFloat64(0, v, Endian.little);
    _elem(0x01, k, d.buffer.asUint8List());
  }

  void string(String k, String v) => _elem(0x02, k, _stringPayload(v));

  void document(String k, void Function(BsonEmit) f) =>
      _elem(0x03, k, _subDocument(f));

  void array(String k, void Function(BsonEmit) f) =>
      _elem(0x04, k, _subDocument(f));

  void binary(String k, int subtype, List<int> bytes) {
    final p = BytesBuilder();
    p.add(_le32(bytes.length));
    p.addByte(subtype);
    p.add(bytes);
    _elem(0x05, k, p.toBytes());
  }

  void legacyBinary(String k, int declaredInner, List<int> bytes) {
    final p = BytesBuilder();
    p.add(_le32(bytes.length + 4));
    p.addByte(0x02);
    p.add(_le32(declaredInner));
    p.add(bytes);
    _elem(0x05, k, p.toBytes());
  }

  void undefined(String k) => _elem(0x06, k, const []);

  void objectId(String k, List<int> twelve) {
    expect(twelve.length, 12);
    _elem(0x07, k, twelve);
  }

  void bool_(String k, bool v) => _elem(0x08, k, [v ? 1 : 0]);

  void boolRaw(String k, int raw) => _elem(0x08, k, [raw]);

  void date(String k, int millis) => _elem(0x09, k, _le64(millis));

  void null_(String k) => _elem(0x0A, k, const []);

  void regex(String k, String pattern, String options) {
    final p = BytesBuilder();
    p.add(utf8.encode(pattern));
    p.addByte(0);
    p.add(utf8.encode(options));
    p.addByte(0);
    _elem(0x0B, k, p.toBytes());
  }

  void dbPointer(String k, String ns, List<int> twelve) {
    final p = BytesBuilder();
    p.add(_stringPayload(ns));
    p.add(twelve);
    _elem(0x0C, k, p.toBytes());
  }

  void javascript(String k, String code) =>
      _elem(0x0D, k, _stringPayload(code));

  void symbol(String k, String v) => _elem(0x0E, k, _stringPayload(v));

  void javascriptWithScope(String k, String code, void Function(BsonEmit) f) {
    final inner = BytesBuilder();
    inner.add(_stringPayload(code));
    final scope = _subDocument(f);
    inner.add(scope);
    final body = inner.toBytes();
    final p = BytesBuilder();
    p.add(_le32(body.length + 4));
    p.add(body);
    _elem(0x0F, k, p.toBytes());
  }

  void int32(String k, int v) => _elem(0x10, k, _le32(v));

  void timestamp(String k, int seconds, int increment) {
    final p = BytesBuilder();
    p.add(_leU32(increment));
    p.add(_leU32(seconds));
    _elem(0x11, k, p.toBytes());
  }

  void int64(String k, int v) => _elem(0x12, k, _le64(v));

  void decimal128(String k, List<int> sixteen) {
    expect(sixteen.length, 16);
    _elem(0x13, k, sixteen);
  }

  void maxKey(String k) => _elem(0x7F, k, const []);

  void minKey(String k) => _elem(0xFF, k, const []);

  void rawElement(int type, String k, List<int> payload) =>
      _elem(type, k, payload);

  static List<int> _stringPayload(String v) {
    final bytes = utf8.encode(v);
    final p = BytesBuilder();
    p.add(_le32(bytes.length + 1));
    p.add(bytes);
    p.addByte(0);
    return p.toBytes();
  }

  static Uint8List _subDocument(void Function(BsonEmit) f) {
    final e = BsonEmit();
    f(e);
    return e.toDocument();
  }
}

void main() {
  group('BSON 类型子集', () {
    test(
      'double/string/document/array/binary/bool/null/int32/int64/objectId/date/regex',
      () {
        final e = BsonEmit();
        e.double_('dbl', 3.5);
        e.string('str', 'héllo');
        e.document('doc', (d) {
          d.int32('n', -7);
          d.string('s', 'inner');
        });
        e.array('arr', (a) {
          a.int32('0', 10);
          a.string('1', 'two');
          a.bool_('2', true);
          a.document('3', (d) => d.null_('x'));
        });
        e.binary('bin', 0x00, [1, 2, 3, 4]);
        e.bool_('yes', true);
        e.bool_('no', false);
        e.null_('nul');
        e.int32('i32', -2147483648);
        e.int64('i64', 9223372036854775807);
        e.objectId('oid', List<int>.generate(12, (i) => i));
        e.date('date', 1700000000000);
        e.regex('re', r'^a.*z$', 'im');

        final doc = BsonReader.parseDocument(e.toDocument());

        expect(doc['dbl'], 3.5);
        expect(doc['str'], 'héllo');
        final nested = doc.getDocument('doc')!;
        expect(nested.getInt('n'), -7);
        expect(nested.getString('s'), 'inner');
        final arr = doc.getArray('arr')!;
        expect(arr, hasLength(4));
        expect(arr[0], 10);
        expect(arr[1], 'two');
        expect(arr[2], true);
        expect((arr[3] as BsonDocument).containsKey('x'), isTrue);
        expect((arr[3] as BsonDocument)['x'], isNull);
        final bin = doc['bin'] as BsonBinary;
        expect(bin.subtype, 0x00);
        expect(bin.bytes, [1, 2, 3, 4]);
        expect(doc['yes'], true);
        expect(doc['no'], false);
        expect(doc.containsKey('nul'), isTrue);
        expect(doc['nul'], isNull);
        expect(doc['i32'], -2147483648);
        expect((doc['i64'] as BsonInt64).value, 9223372036854775807);
        expect((doc['oid'] as BsonObjectId).hex, '000102030405060708090a0b');
        expect(
          (doc['date'] as BsonDateTime).millisecondsSinceEpoch,
          1700000000000,
        );
        expect(
          (doc['date'] as BsonDateTime).toDateTime,
          DateTime.utc(2023, 11, 14, 22, 13, 20),
        );
        final re = doc['re'] as BsonRegex;
        expect(re.pattern, r'^a.*z$');
        expect(re.options, 'im');
      },
    );

    test('int64 边界值（含 int64 min，2^63 不能表示成正数）', () {
      final e = BsonEmit();
      e.int64('max', 9223372036854775807);
      e.int64('min', -9223372036854775808);
      e.int64('zero', 0);
      e.int64('neg', -42);

      final doc = BsonReader.parseDocument(e.toDocument());
      expect((doc['max'] as BsonInt64).value, 9223372036854775807);
      expect((doc['min'] as BsonInt64).value, -9223372036854775808);
      expect((doc['zero'] as BsonInt64).value, 0);
      expect((doc['neg'] as BsonInt64).value, -42);
    });

    test('数组是"键为 0,1,2… 的文档"，顺序 = 键插入顺序', () {
      final e = BsonEmit();
      e.array('a', (a) {
        a.string('0', 'first');
        a.string('1', 'second');
        a.string('2', 'third');
      });
      final doc = BsonReader.parseDocument(e.toDocument());
      expect(doc.getArray('a'), ['first', 'second', 'third']);
    });

    test('嵌套 document/array 的层数不限，键顺序保留（BSON 文档保序）', () {
      final e = BsonEmit();
      e.string('z', 'last-key-added-first?');
      e.int32('a', 1);
      e.array('m', (a) {
        a.array('0', (inner) {
          inner.int32('0', 9);
          inner.array('1', (deep) => deep.string('0', 'deep'));
        });
      });
      final doc = BsonReader.parseDocument(e.toDocument());
      expect(doc.keys.toList(), ['z', 'a', 'm']);
      // doc['m'] = [ [9, ['deep']] ]
      final inner = doc.getArray('m')![0] as List; // [9, ['deep']]
      expect(inner[0], 9);
      expect((inner[1] as List)[0], 'deep');
    });

    test('binary subtype 原样保留；legacy subtype=0x02 的额外长度字段认得', () {
      final e = BsonEmit();
      e.binary('b0', 0x00, [9, 8]);
      e.binary('b4', 0x04, [7]);
      e.legacyBinary('b2', 3, [1, 2, 3]);
      final doc = BsonReader.parseDocument(e.toDocument());
      expect((doc['b0'] as BsonBinary).subtype, 0x00);
      expect((doc['b4'] as BsonBinary).subtype, 0x04);
      final legacy = doc['b2'] as BsonBinary;
      expect(legacy.subtype, 0x02);
      expect(legacy.bytes, [1, 2, 3]);
    });

    test(
      '其余顺带支持的类型：timestamp/undefined/js/symbol/dbPointer/decimal128/minKey/maxKey',
      () {
        final e = BsonEmit();
        e.timestamp('ts', 1700000000, 5);
        e.undefined('undef');
        e.javascript('js', 'return 1;');
        e.javascriptWithScope('jss', 'x', (s) => s.int32('k', 1));
        e.symbol('sym', 'symval');
        e.dbPointer('dbp', 'db.coll', List<int>.filled(12, 6));
        e.decimal128('dec', List<int>.filled(16, 0));
        e.minKey('mk');
        e.maxKey('xk');

        final doc = BsonReader.parseDocument(e.toDocument());
        final ts = doc['ts'] as BsonTimestamp;
        expect(ts.seconds, 1700000000);
        expect(ts.increment, 5);
        expect(doc['undef'], isA<BsonUndefined>());
        expect((doc['js'] as BsonJavaScript).code, 'return 1;');
        final jss = doc['jss'] as BsonJavaScript;
        expect(jss.code, 'x');
        expect(jss.scope!.getInt('k'), 1);
        expect(doc['sym'], 'symval');
        expect((doc['dbp'] as BsonDbPointer).namespace, 'db.coll');
        expect((doc['dec'] as BsonDecimal128).bytes, hasLength(16));
        expect(doc['mk'], isA<BsonMinKey>());
        expect(doc['xk'], isA<BsonMaxKey>());
      },
    );

    test('末尾多余字节被如实报告（不静默吞掉）', () {
      final e = BsonEmit();
      e.int32('a', 1);
      final bytes = e.toDocument();
      final padded = Uint8List.fromList([...bytes, 0xDE, 0xAD, 0xBE, 0xEF]);
      final result = BsonReader.parse(padded);
      expect(result.document.getInt('a'), 1);
      expect(result.consumedBytes, bytes.length);
      expect(result.totalBytes, bytes.length + 4);
      expect(result.trailingBytes, 4);
    });
  });

  group('BSON 错误路径（不猜、不跳过）', () {
    test('空输入', () {
      expect(
        () => BsonReader.parse(Uint8List(0)),
        throwsA(isA<BsonFormatException>()),
      );
    });

    test('document 长度越界', () {
      final bytes = Uint8List.fromList([
        0x20,
        0x00,
        0x00,
        0x00,
        0x10,
        0x61,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      expect(
        () => BsonReader.parse(bytes),
        throwsA(isA<BsonFormatException>()),
      );
    });

    test('终结符不是 0x00', () {
      final bytes = Uint8List.fromList([
        0x08,
        0x00,
        0x00,
        0x00,
        0x10,
        0x61,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x7F,
      ]);
      expect(
        () => BsonReader.parse(bytes),
        throwsA(isA<BsonFormatException>()),
      );
    });

    test('未支持的 type byte 直接报错（含类型与键名）', () {
      final e = BsonEmit();
      e.rawElement(0x20, 'weird', const []);
      expect(
        () => BsonReader.parse(e.toDocument()),
        throwsA(
          isA<BsonUnsupportedTypeException>()
              .having((x) => x.typeByte, 'typeByte', 0x20)
              .having((x) => x.key, 'key', 'weird'),
        ),
      );
    });

    test('bool 只能是 0/1', () {
      final e = BsonEmit();
      e.boolRaw('b', 2);
      expect(
        () => BsonReader.parse(e.toDocument()),
        throwsA(isA<BsonFormatException>()),
      );
    });

    test('string 负长度 / 缺 NUL', () {
      final negLen = BsonEmit();
      negLen.rawElement(0x02, 's', _le32(-1));
      expect(
        () => BsonReader.parse(negLen.toDocument()),
        throwsA(isA<BsonFormatException>()),
      );

      final noNul = BsonEmit();
      noNul.rawElement(0x02, 's', [0x05, 0x00, 0x00, 0x00, 0x61, 0x62]);
      expect(
        () => BsonReader.parse(noNul.toDocument()),
        throwsA(isA<BsonFormatException>()),
      );
    });

    test('legacy binary 内层长度不一致', () {
      final e = BsonEmit();
      e.legacyBinary('b', 99, [1, 2, 3]);
      expect(
        () => BsonReader.parse(e.toDocument()),
        throwsA(isA<BsonFormatException>()),
      );
    });
  });
}
