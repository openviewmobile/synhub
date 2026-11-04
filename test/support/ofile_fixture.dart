// **测试专用**的合法 OFile 夹具生成器（阶段 2a，**2026-09 按真实文件重写**）。
//
// ⚠️ 诚实声明：本夹具的字节布局现在**按 8 份真实 `.odoc/.osheet/.oslides`
// 实测结构**重写（`/tmp/office-samples/`，见
// `test/golden/office_native_real_samples.txt`），而不是按研究文档推测：
//
//   1. 文件 = `[int32 LE len][BSON doc]` 的**链**（`len` 就是 BSON 文档长度，
//      **没有**额外 5 字节前缀）；第 5 字节是 BSON 首个元素 type；
//   2. 头文档 `docs[0]` **只放** `schema`(int64=3) / `enc`(bool) / `id`(string
//      `1028_<docid>.doc|.sh|.slide`) / `ver`(string, 40 hex)；
//   3. 每个 section 单独一个 doc，字段名 `@C_text/<成员名>`，值 = BSON binary
//      (subtype 0) 的 **zlib** 载荷；
//   4. `@C_metatext` 与明文 `metatext` 在**同一个 doc** 里；明文 `metatext` 是
//      **string，值为字面量 `"null"`**（**不是** BSON null）；
//   5. `metabinary_files` 是 **BSON document**，键是整段 JSON 文本
//      `{"name":"<file_id>"}`，值是**未压缩**原始字节；
//   6. 链尾 = 单独一个 doc `{"end": true}`（**不在**头文档里）。
//
// 头文档长度因此**只由 `id` 串长决定**：`4 + schema(16) + enc(6) + id(9+len)
// + ver(50) + terminator(1) == 86 + len(id)`；真实实测 odoc=121 / osheet=120 /
// oslides=123 与 id 长度 35/34/37 逐一吻合（见夹具测试）。
//
// 注意：本文件**不 import** `lib/` 里的 `ofile.dart`——字段名拼装与链装配都是
// **独立**实现的，这样"链遍历/终止条件/前缀"被改坏时测试才会真的变红
// （而不是两边一起错）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibEncoder;

/// 小端 int32。
Uint8List int32Le(int v) {
  final d = ByteData(4)..setInt32(0, v, Endian.little);
  return d.buffer.asUint8List();
}

/// 小端 int64（真实头文档 `schema` 是 int64 = `0x12`）。
Uint8List int64Le(int v) {
  final d = ByteData(8)..setInt64(0, v, Endian.little);
  return d.buffer.asUint8List();
}

/// 最小 BSON document 写出器（只写本夹具需要的类型 + 一个 raw 逃生口）。
class TestBsonWriter {
  final BytesBuilder _body = BytesBuilder();

  void _element(int typeByte, String key, List<int> payload) {
    _body.addByte(typeByte);
    _body.add(utf8.encode(key));
    _body.addByte(0);
    _body.add(payload);
  }

  void int32(String key, int value) => _element(0x10, key, int32Le(value));

  void int64(String key, int value) => _element(0x12, key, int64Le(value));

  void boolean(String key, bool value) =>
      _element(0x08, key, <int>[value ? 1 : 0]);

  void string(String key, String value) {
    final bytes = utf8.encode(value);
    final p = BytesBuilder();
    p.add(int32Le(bytes.length + 1));
    p.add(bytes);
    p.addByte(0);
    _element(0x02, key, p.toBytes());
  }

  void binary(String key, List<int> bytes, {int subtype = 0x00}) {
    final p = BytesBuilder();
    p.add(int32Le(bytes.length));
    p.addByte(subtype);
    p.add(bytes);
    _element(0x05, key, p.toBytes());
  }

  /// 内嵌一个完整 BSON document 作为值（真实 `metabinary_files` 用）。
  void document(String key, List<int> documentBytes) =>
      _element(0x03, key, documentBytes);

  /// 任意 type byte（用于"未知 BSON 类型"用例：例如 0x42）。
  void rawElement(int typeByte, String key, List<int> payload) =>
      _element(typeByte, key, payload);

  int get _bodyLength => _body.length;

  /// 当前 body 长度（不含 4 字节长度前缀与结尾 0x00）；用于自检。
  int get bodyLength => _bodyLength;

  /// 完成一个**完整** BSON document（`int32 总长 + body + 0x00`）。
  Uint8List finish() {
    final body = _body.toBytes();
    final out = BytesBuilder();
    out.add(int32Le(body.length + 5));
    out.add(body);
    out.addByte(0);
    return out.toBytes();
  }
}

/// zlib 包装的 deflate（对应 `zlib compress2`；**不是** raw deflate）。
Uint8List zlibDeflate(List<int> data) => ZLibEncoder().encodeBytes(data);

/// 一个 section 值的 BSON binary 载荷（= `deflate(JSON 文本)`）。
Uint8List fixtureSectionPayload(Object? json) =>
    zlibDeflate(utf8.encode(jsonEncode(json)));

/// 逻辑 section 名 → BSON 字段名（独立于 `lib/ofile.dart` 的实现）。
String fixtureSectionKey(String logicalName) =>
    logicalName == 'metatext' ? '@C_metatext' : '@C_text/$logicalName';

/// 把多条完整 BSON document 顺序拼成真实容器链。
Uint8List fixtureChain(List<List<int>> docs) {
  final out = BytesBuilder();
  for (final d in docs) {
    out.add(d);
  }
  return out.toBytes();
}

/// 造一个"带打开密码"的 section 明文：`deflate` 之后是官方密文串
/// `base64("Saltv2c_" ‖ salt(16) ‖ ciphertext)`（研究文档 §3.1；这里**不**做真加密）。
///
/// ⚠️ 真实"带打开密码"文件**未取得**，本形态仍是**推断**（见 reader 文档）。
String fakeCryptoBlob(String plainText) {
  final seed = plainText.codeUnits.fold<int>(
    7,
    (a, b) => (a * 31 + b) & 0xffff,
  );
  final salt = List<int>.generate(16, (i) => (seed + i * 7) & 0xff);
  final cipher = List<int>.generate(48, (i) => (seed * 3 + i * 13) & 0xff);
  return base64.encode(utf8.encode('Saltv2c_') + salt + cipher);
}

/// 构造一份**合法且与真实结构同构**的 OFile。
///
/// [sections] 的键是**逻辑** section 名（`index` / `sh_1` / `content` / …）。
/// [encrypt] 为 `true` 时：`@C_metatext` 写 `encrypt: true` + `password`，
/// 且每个 section 的明文先包成 [fakeCryptoBlob]（模拟有打开密码的文档）。
Uint8List buildTestOFile({
  required Map<String, Object?> sections,
  bool encrypt = false,
  Map<String, Object?>? metatext,
  bool includeMetatext = true,
  bool includeSchema = true,
  int schema = 3,
  String id = '1028_FIXTURE0000000000000000.doc',
  String ver = '0000000000000000000000000000000000000000',
  bool end = true,
  bool withPlainMetatext = true,
  Map<String, List<int>> embeddedFiles = const {},
}) {
  final docs = <List<int>>[];

  // docs[0]：头文档，只放元数据（真实结构）。
  final header = TestBsonWriter();
  if (includeSchema) header.int64('schema', schema);
  header.boolean('enc', encrypt);
  header.string('id', id);
  header.string('ver', ver);
  docs.add(header.finish());

  // 每个 section 单独一个 doc（真实结构）。
  for (final entry in sections.entries) {
    final w = TestBsonWriter();
    final plain = jsonEncode(entry.value);
    final payload = encrypt
        ? zlibDeflate(utf8.encode(fakeCryptoBlob(plain)))
        : zlibDeflate(utf8.encode(plain));
    w.binary(fixtureSectionKey(entry.key), payload);
    docs.add(w.finish());
  }

  // `@C_metatext` + 明文 `metatext` 在同一个 doc 里（真实结构）。
  if (includeMetatext) {
    final w = TestBsonWriter();
    final meta =
        metatext ??
        <String, Object?>{
          'ntype': 21,
          'oflie': true,
          if (encrypt) 'encrypt': true,
          if (encrypt) 'password': 'fake-wrapped-sys-password',
        };
    w.binary('@C_metatext', fixtureSectionPayload(meta));
    if (withPlainMetatext) {
      // 真实：string，值为字面量 "null"（不是 BSON null）。
      w.string('metatext', 'null');
    }
    docs.add(w.finish());
  }

  // 内嵌附件：键 = 整段 JSON 文本 {"name":"<file_id>"}，值 = 未压缩 binary。
  for (final entry in embeddedFiles.entries) {
    final sub = TestBsonWriter()
      ..binary('{"name":"${entry.key}"}', entry.value);
    final w = TestBsonWriter()..document('metabinary_files', sub.finish());
    docs.add(w.finish());
  }

  // 链尾：独立的 {"end": true} doc。
  if (end) {
    final w = TestBsonWriter()..boolean('end', true);
    docs.add(w.finish());
  }

  return fixtureChain(docs);
}
