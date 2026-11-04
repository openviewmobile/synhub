// 纯 Dart 的 BSON **只读**解析器（无 pub 依赖，只用 `dart:convert`/`dart:typed_data`）。
//
// 依据：BSON 规范的公开线格式（little-endian；document = int32 总长 + 元素序列 + 0x00）。
// 本文件只做"读"，不做"写"——阶段 1 只需要读；写（`bson_append_*` 对应物）留待阶段 4。
//
// 为什么自研而不引 pub：
//   1. `bson`/`mongo_dart` 之类会带进一整套驱动依赖，本仓库只需要线格式解码；
//   2. 需要**可复核**——每种类型在固定 `文件:行` 处一对一映射到规范；
//   3. 出错必须精确到字节偏移，便于定位真实 `.odoc/.osheet/.oslides` 的容器异常。
//
// 证据（`docs/office-native-format-research.md` §4.0）：
//   `libsynoffice.so.6` 动态链接 `libbson-1.0.so.0`，导入 `bson_reader_new_from_file` /
//   `bson_reader_read` / `bson_iter_next` / `bson_iter_key` / `bson_iter_utf8` /
//   `bson_append_binary` …… 即容器就是 BSON 文档。
//
// ⚠️ **真实文件修正（2026-09 设备批次，8 份实测）**：容器不是"整个文件一个 BSON"，
//   而是 `[int32 LE len][BSON doc]` 的**链**——第 5 字节起是 BSON 首个元素的 type
//   （头文档首元素是 `0x12 73 63 68 65 6d 61 00` = int64 `"schema"`），
//   `len` 就是 BSON 自己的文档长度，**没有额外的 5 字节前缀**。
//   链式遍历用 [BsonReader.parseAt]（本批新增）。
//
// 支持的类型（规范 type byte）：
//   0x01 double       -> double
//   0x02 string       -> String
//   0x03 document     -> BsonDocument
//   0x04 array        -> List<Object?>（BSON 数组是键为 "0","1",… 的文档）
//   0x05 binary       -> BsonBinary（含 subtype）
//   0x06 undefined    -> BsonUndefined.instance
//   0x07 objectId     -> BsonObjectId
//   0x08 bool         -> bool
//   0x09 date         -> BsonDateTime（int64 毫秒）
//   0x0A null         -> null
//   0x0B regex        -> BsonRegex
//   0x0C dbPointer    -> BsonDbPointer
//   0x0D javascript   -> BsonJavaScript
//   0x0E symbol       -> String（容器里未用到；按规范是 cstring）
//   0x0F js+scope     -> BsonJavaScript（带 scope）
//   0x10 int32        -> int
//   0x11 timestamp    -> BsonTimestamp
//   0x12 int64        -> BsonInt64（与 int32 区分开，便于自检）
//   0x13 decimal128   -> BsonDecimal128（16 字节原样保留）
//   0x7F maxKey       -> BsonMaxKey.instance
//   0xFF minKey       -> BsonMinKey.instance
// 其它 type byte -> 抛 [BsonUnsupportedTypeException]（不猜、不跳过）。
//
// 注意：`int64`/`double` 用 `ByteData.getUint32` 拼装而不是 `getInt64`/`getFloat64` 之外的
// 扩展运算，避免在 Web 目标上撞 `getInt64` 的 "Unsupported operation"。

import 'dart:convert';
import 'dart:typed_data';

/// BSON 结构非法（截断、长度不符、终结符缺失等）。
class BsonFormatException implements Exception {
  BsonFormatException(this.message, [this.offset]);

  final String message;

  /// 出错位置（相对当前 document 起点的字节偏移；能取到时才有值）。
  final int? offset;

  @override
  String toString() =>
      'BsonFormatException: $message${offset == null ? '' : ' (offset $offset)'}';
}

/// 遇到了本解析器未覆盖的 BSON type byte。
class BsonUnsupportedTypeException implements Exception {
  BsonUnsupportedTypeException(this.typeByte, this.key, this.offset);

  final int typeByte;
  final String key;
  final int offset;

  @override
  String toString() =>
      'BsonUnsupportedTypeException: type byte 0x${typeByte.toRadixString(16)} '
      'for key "$key" at offset $offset';
}

/// `0x06 undefined`。
class BsonUndefined {
  const BsonUndefined._();

  static const instance = BsonUndefined._();

  @override
  String toString() => 'BsonUndefined';
}

/// `0x07 objectId`：12 字节。
class BsonObjectId {
  BsonObjectId(Uint8List bytes)
    : bytes = Uint8List.fromList(bytes),
      assert(bytes.length == 12);

  final Uint8List bytes;

  String get hex =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() => 'BsonObjectId($hex)';
}

/// `0x05 binary`：`subtype` 原样保留（容器内图片是 `BSON_SUBTYPE_BINARY`=0x00）。
class BsonBinary {
  BsonBinary(this.subtype, Uint8List bytes) : bytes = Uint8List.fromList(bytes);

  final int subtype;
  final Uint8List bytes;

  int get length => bytes.length;

  @override
  String toString() => 'BsonBinary(subtype=$subtype, ${bytes.length}B)';
}

/// `0x09 date`：UTC 毫秒。
class BsonDateTime {
  const BsonDateTime(this.millisecondsSinceEpoch);

  final int millisecondsSinceEpoch;

  DateTime get toDateTime =>
      DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch, isUtc: true);

  @override
  String toString() => 'BsonDateTime($millisecondsSinceEpoch)';
}

/// `0x12 int64`。
class BsonInt64 {
  const BsonInt64(this.value);

  final int value;

  @override
  String toString() => 'BsonInt64($value)';
}

/// `0x0B regex`：pattern + options（两个 cstring）。
class BsonRegex {
  const BsonRegex(this.pattern, this.options);

  final String pattern;
  final String options;

  @override
  String toString() => 'BsonRegex(/$pattern/$options)';
}

/// `0x0C dbPointer`。
class BsonDbPointer {
  const BsonDbPointer(this.namespace, this.id);

  final String namespace;
  final BsonObjectId id;

  @override
  String toString() => 'BsonDbPointer($namespace, $id)';
}

/// `0x0D javascript` / `0x0F javascriptWithScope`。
class BsonJavaScript {
  const BsonJavaScript(this.code, [this.scope]);

  final String code;
  final BsonDocument? scope;

  @override
  String toString() => 'BsonJavaScript(${code.length} chars)';
}

/// `0x11 timestamp`：低 32 位 increment + 高 32 位 seconds。
class BsonTimestamp {
  const BsonTimestamp(this.seconds, this.increment);

  final int seconds;
  final int increment;

  @override
  String toString() => 'BsonTimestamp($seconds, inc=$increment)';
}

/// `0x13 decimal128`：16 字节原样保留（容器里未用到，不做十进制换算）。
class BsonDecimal128 {
  BsonDecimal128(Uint8List bytes) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;

  @override
  String toString() => 'BsonDecimal128(${bytes.length}B)';
}

/// `0x7F maxKey`。
class BsonMaxKey {
  const BsonMaxKey._();

  static const instance = BsonMaxKey._();

  @override
  String toString() => 'BsonMaxKey';
}

/// `0xFF minKey`。
class BsonMinKey {
  const BsonMinKey._();

  static const instance = BsonMinKey._();

  @override
  String toString() => 'BsonMinKey';
}

/// 一个 BSON document：**保序**的键值表（Dart `Map` 默认是 `LinkedHashMap`）。
class BsonDocument {
  BsonDocument(this.values);

  final Map<String, Object?> values;

  Iterable<String> get keys => values.keys;

  int get length => values.length;

  bool containsKey(String key) => values.containsKey(key);

  Object? operator [](String key) => values[key];

  String? getString(String key) {
    final v = values[key];
    return v is String ? v : null;
  }

  bool? getBool(String key) {
    final v = values[key];
    return v is bool ? v : null;
  }

  int? getInt(String key) {
    final v = values[key];
    if (v is int) return v;
    if (v is BsonInt64) return v.value;
    if (v is BsonDateTime) return v.millisecondsSinceEpoch;
    return null;
  }

  BsonDocument? getDocument(String key) {
    final v = values[key];
    return v is BsonDocument ? v : null;
  }

  List<Object?>? getArray(String key) {
    final v = values[key];
    return v is List ? v : null;
  }

  @override
  String toString() => 'BsonDocument(${values.keys.join(', ')})';
}

/// BSON 只读入口。`BsonReader.parse(bytes)` = 读文件里第一个 document。
///
/// 全部为静态方法，不持有状态。
abstract final class BsonReader {
  /// 解析 [bytes] 开头的 BSON document。
  ///
  /// [bytes] 末尾允许多余字节（真实容器理论上没有，但驱动器可能做 padding），
  /// 已消费的字节数见 [BsonParseResult.consumedBytes]。
  static BsonParseResult parse(Uint8List bytes) {
    final cursor = _Cursor(bytes);
    final doc = _readDocument(cursor);
    return BsonParseResult(doc, cursor.pos, bytes.length);
  }

  /// 只读 document，忽略是否有多余字节。
  static BsonDocument parseDocument(Uint8List bytes) => parse(bytes).document;

  /// 解析 [bytes] 中从 [offset] 开始的 BSON document。
  ///
  /// 真实 Office 原生容器不是"单文件一个 BSON"，而是
  /// `[int32 LE len][BSON doc]` 的**链**（首个 doc 是头文档，其后每个 doc 载一个
  /// `@C_*` section / `metabinary_files` / `{"end":true}`）。链式遍历靠本方法。
  ///
  /// [BsonParseResult.consumedBytes] 是**绝对**字节偏移（doc 结束处），
  /// 可直接作为下一次调用的 [offset]。
  static BsonParseResult parseAt(Uint8List bytes, int offset) {
    if (offset < 0 || offset > bytes.length) {
      throw BsonFormatException(
        'offset $offset out of range (0..${bytes.length})',
        offset,
      );
    }
    final cursor = _Cursor(bytes)..pos = offset;
    final doc = _readDocument(cursor);
    return BsonParseResult(doc, cursor.pos, bytes.length);
  }

  // 下面这些静态方法是解析实现本体，按规范逐类型一对一。
  static BsonDocument _readDocument(_Cursor c) {
    final start = c.pos;
    final len = c.readInt32();
    if (len < 5) {
      throw BsonFormatException('document length $len < 5', start);
    }
    final end = start + len;
    if (end > c.length) {
      throw BsonFormatException(
        'document length $len overruns buffer (start=$start, buffer=${c.length})',
        start,
      );
    }
    final map = <String, Object?>{};
    while (c.pos < end - 1) {
      final typeByte = c.readByte();
      final key = c.readCString();
      map[key] = _readValue(c, typeByte, key);
    }
    if (end - 1 < 0 || c.pos != end - 1) {
      throw BsonFormatException('element table overran document', c.pos);
    }
    final terminator = c.readByte();
    if (terminator != 0) {
      throw BsonFormatException(
        'document terminator must be 0x00, got 0x${terminator.toRadixString(16)}',
        c.pos - 1,
      );
    }
    if (c.pos != end) {
      throw BsonFormatException(
        'document ended at ${c.pos}, expected $end',
        c.pos,
      );
    }
    return BsonDocument(map);
  }

  static Object? _readValue(_Cursor c, int typeByte, String key) {
    switch (typeByte) {
      case 0x01: // double
        return c.readFloat64();
      case 0x02: // string
        return c.readString();
      case 0x03: // document
        return _readDocument(c);
      case 0x04: // array
        return List<Object?>.from(_readDocument(c).values.values);
      case 0x05: // binary
        return _readBinary(c);
      case 0x06: // undefined
        return BsonUndefined.instance;
      case 0x07: // objectId
        return BsonObjectId(c.readBytes(12));
      case 0x08: // bool
        final b = c.readByte();
        if (b != 0 && b != 1) {
          throw BsonFormatException('bool must be 0 or 1, got $b', c.pos - 1);
        }
        return b == 1;
      case 0x09: // date
        return BsonDateTime(c.readInt64());
      case 0x0A: // null
        return null;
      case 0x0B: // regex
        return BsonRegex(c.readCString(), c.readCString());
      case 0x0C: // dbPointer
        final ns = c.readString();
        return BsonDbPointer(ns, BsonObjectId(c.readBytes(12)));
      case 0x0D: // javascript
        return BsonJavaScript(c.readString());
      case 0x0E: // symbol
        return c.readString();
      case 0x0F: // javascript with scope
        final total = c.readInt32();
        final start = c.pos - 4;
        final code = c.readString();
        final scope = _readDocument(c);
        if (c.pos - start != total) {
          throw BsonFormatException(
            'javascriptWithScope length $total != consumed ${c.pos - start}',
            start,
          );
        }
        return BsonJavaScript(code, scope);
      case 0x10: // int32
        return c.readInt32();
      case 0x11: // timestamp
        final increment = c.readUint32();
        final seconds = c.readUint32();
        return BsonTimestamp(seconds, increment);
      case 0x12: // int64
        return BsonInt64(c.readInt64());
      case 0x13: // decimal128
        return BsonDecimal128(c.readBytes(16));
      case 0x7F: // maxKey
        return BsonMaxKey.instance;
      case 0xFF: // minKey
        return BsonMinKey.instance;
      default:
        throw BsonUnsupportedTypeException(typeByte, key, c.pos - 1);
    }
  }

  static BsonBinary _readBinary(_Cursor c) {
    final len = c.readInt32();
    if (len < 0) {
      throw BsonFormatException('binary length $len < 0', c.pos - 4);
    }
    final subtype = c.readByte();
    if (subtype == 0x02) {
      // 旧版 binary：payload 前还有一个 int32 长度（规范 deprecated）。
      final inner = c.readInt32();
      if (inner != len - 4) {
        throw BsonFormatException(
          'legacy binary inner length $inner != $len-4',
          c.pos - 4,
        );
      }
      return BsonBinary(subtype, c.readBytes(inner));
    }
    return BsonBinary(subtype, c.readBytes(len));
  }
}

/// [BsonReader.parse] 的返回值：document + 已消费字节数。
class BsonParseResult {
  const BsonParseResult(this.document, this.consumedBytes, this.totalBytes);

  final BsonDocument document;
  final int consumedBytes;
  final int totalBytes;

  int get trailingBytes => totalBytes - consumedBytes;
}

class _Cursor {
  _Cursor(this.bytes);

  final Uint8List bytes;
  int pos = 0;

  late final ByteData _data = ByteData.sublistView(bytes);

  int get length => bytes.length;

  void _need(int n) {
    if (pos + n > bytes.length) {
      throw BsonFormatException(
        'need $n byte(s) at $pos but buffer is ${bytes.length}',
        pos,
      );
    }
  }

  int readByte() {
    _need(1);
    return bytes[pos++];
  }

  int readInt32() {
    _need(4);
    final v = _data.getInt32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int readUint32() {
    _need(4);
    final v = _data.getUint32(pos, Endian.little);
    pos += 4;
    return v;
  }

  /// 用两次 `getUint32` 拼 64 位（借 `BigInt` 处理符号），
  /// 避开 `getInt64` 在 Web 上的 "Unsupported operation"。
  int readInt64() {
    _need(8);
    final lo = _data.getUint32(pos, Endian.little);
    final hi = _data.getUint32(pos + 4, Endian.little);
    pos += 8;
    final unsigned = BigInt.from(lo) + (BigInt.from(hi) << 32);
    final signed = unsigned >= (BigInt.one << 63)
        ? unsigned - (BigInt.one << 64)
        : unsigned;
    return signed.toInt();
  }

  double readFloat64() {
    _need(8);
    final v = _data.getFloat64(pos, Endian.little);
    pos += 8;
    return v;
  }

  Uint8List readBytes(int n) {
    if (n < 0) throw BsonFormatException('negative length $n', pos);
    _need(n);
    final out = Uint8List.fromList(bytes.sublist(pos, pos + n));
    pos += n;
    return out;
  }

  String readCString() {
    final start = pos;
    var i = pos;
    while (i < bytes.length && bytes[i] != 0) {
      i++;
    }
    if (i >= bytes.length) {
      throw BsonFormatException('unterminated cstring', start);
    }
    final s = utf8.decode(bytes.sublist(start, i));
    pos = i + 1;
    return s;
  }

  String readString() {
    final len = readInt32();
    if (len < 1) {
      throw BsonFormatException('string length $len < 1', pos - 4);
    }
    final raw = readBytes(len);
    if (raw[len - 1] != 0) {
      throw BsonFormatException('string missing NUL terminator', pos - 1);
    }
    return utf8.decode(raw.sublist(0, len - 1));
  }
}
