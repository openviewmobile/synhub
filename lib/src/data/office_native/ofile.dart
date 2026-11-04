// Office 原生文件（`.odoc` / `.osheet` / `.oslides`）的 **BSON 外壳** 解析。
//
// 本文件是**阶段 2a** 的外壳实现：把「BSON 外壳 + section inflate」这条链路走通，
// 并对**带打开密码**的文档给出明确拒绝（不输出乱码、不落进泛化"解析失败"）。
//
// ⚠️ **真实文件修正（2026-09 设备批次，8 份真实 `.odoc/.osheet/.oslides` 实测）**：
//   1. 容器 = `[int32 LE len][BSON doc]` 的**链**，不是"整个文件一个 BSON"，也
//      **不是** 5 字节前缀：`len` 就是 BSON 文档长度，第 5 字节是 BSON 首个元素的
//      type（头文档 = `0x12` int64 `"schema"`）。[OFile.parse] 现在逐 doc 遍历到底。
//   2. **头文档只放元数据**（`schema`/`enc`/`id`/`ver`），**不**放 section；
//      section 各占链上一个 doc（`metabinary_files` 还会重复多个 doc）。
//      odoc/osheet/oslides 头文档长度实测 121/120/123（由 id 串长决定）。
//   3. `ver` 真实类型是 **string**（40 位 hex，**疑似 sha1 但未被取证**），不是 int。
//   4. `metatext` 顶层字段真实类型是 **string，值为字面量 `"null"`**（**不是** BSON
//      null）；权威 metatext 在 `@C_metatext`（真实解出 `{"ntype":21|37|69,"oflie":true}`，
//      **没有 `encrypt` 字段**——`enc=false` 的文档就是没有该键）。
//   5. `metabinary_files` 是 **BSON document**，键是整段 JSON 文本
//      `{"name":"<file_id>"}`，值是 **未压缩** 原始图片字节（PNG/JPEG 魔数直出）。
//   6. 终止 doc = `{"end":true}`（链上最后一个 doc，不是头文档字段）。
//
// 依据（历史研究，**只读**引用，本批不改该文档）：`docs/office-crypto-research.md`
// §2.1/§2.2/§2.3/§4.4/§4.5；`libsynoffice.so.6` 的 `BsonHelper::CompressAdd` /
// `BsonHelper::AddBinary("@C_" + key, deflate字节, size)`。
//
// 职责边界（必须如实报告）：
//   1. BSON 单文件外壳 → 顶层元数据 + 逻辑 section 字典；
//   2. `@C_` section 的 **BSON binary** 载荷 → zlib inflate → utf8 → JSON；
//   3. `@C_metatext` 的 `encrypt` 判定：非 true 走 2a；true → 抛
//      [OfficeDocumentPasswordProtectedException]。
//
// 真实文件状态（2026-09 设备批次）：**8 份真实文件已逐字节跑通**
// （`test/office_native_real_samples_test.dart` + `test/golden/office_native_real_samples.txt`）。
// 8/8 `enc=false`、8/8 头文档 `schema=3`、8/8 `@C_metatext` 无 `encrypt` 键 ⇒ 2a 成立。
// 但**带打开密码的真实文件仍未取得**（`enc=true` / `metatext.encrypt==true` 至今
// 只有自造夹具覆盖），密文载荷形态（`inflate` 后是原始 `prefix‖salt‖ct` 还是
// `base64(prefix‖salt‖ct)`）**仍是推断**。真实样本本体不 vendored 进仓库。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibDecoder;

import 'bson/bson_reader.dart';

/// `OFILE_SCHEMA_VERSION`（研究文档 §2.3：已取证 = 3）。
const int kOFileSchemaVersion = 3;

/// `Bson::CompressAdd` 给每个压缩 section 加的字段名前缀（研究文档 §2.1）。
const String kOFileCompressedPrefix = '@C_';

/// `OFile::UpdateText` 使用的成员前缀：`"text/" + 成员名`（研究文档 §2.2）。
const String kOFileTextSectionPrefix = 'text/';

/// 顶层元数据键（来自 `synoffice_ofile.cpp` 的 `bson.Add` 断言原文 + §2.3，
/// **按真实文件修正**）。
///
/// - `metatext`（无 `@C_` 前缀）真实类型是 **string，值为字面量 `"null"`**，
///   不是 section，也不是 BSON null ⇒ 归元数据，不参与模型。
const Set<String> kOFileMetaKeys = {
  'schema',
  'enc',
  'id',
  'ver',
  'end',
  'sys_password',
  'metatext',
};

/// 链上"内嵌附件"的 BSON 字段名（真实文件实测；值 = document，键是
/// `{"name":"<file_id>"}`，值是未压缩原始字节）。
const String kOFileEmbeddedFilesKey = 'metabinary_files';

/// 链上终止 doc 的字段名（真实文件实测：`{"end": true}`，长度恒 11 字节）。
const String kOFileEndKey = 'end';

/// `@C_metatext` 解密后的**逻辑** section 名。
const String kOFileMetaTextSection = 'metatext';

/// 逻辑 section 名白名单（研究文档 §4.2/§9.1）；`sh_*` 按前缀匹配。
const Set<String> kOFileKnownSectionNames = {
  'content',
  'index',
  'comment',
  'command',
  'page_setup',
  'file',
  'raw_text',
  'metatext',
  'locale',
  'style',
  'define',
  'protection',
  'externals',
  'pivotCaches',
  'pivotTables',
  'attachment',
};

/// 把 BSON 顶层字段名翻成**逻辑** section 名；不是压缩 section（即没有 `@C_` 前缀）
/// 时返回 `null`。
///
/// 证据（研究文档 §2.1/§2.2）：
///   - `@C_text/index`   → `index`（去掉 `@C_` 与 `text/`）
///   - `@C_text/sh_1`    → `sh_1`
///   - `@C_metatext`     → `metatext`
///   - `@C_<其它>`       → `<其它>`（去掉 `@C_`，不臆造 `text/`）
String? oFileLogicalSectionName(String bsonKey) {
  if (!bsonKey.startsWith(kOFileCompressedPrefix)) return null;
  final rest = bsonKey.substring(kOFileCompressedPrefix.length);
  if (rest.startsWith(kOFileTextSectionPrefix)) {
    return rest.substring(kOFileTextSectionPrefix.length);
  }
  return rest;
}

/// [oFileLogicalSectionName] 的逆向拼装（参考实现；测试夹具**独立**拼装，
/// 以免把同一处 bug 两边都复制）。
///
/// `metatext` → `@C_metatext`；其它 → `@C_text/<name>`。
String oFileBsonKeyForSection(String logicalName) =>
    logicalName == kOFileMetaTextSection
    ? '${kOFileCompressedPrefix}metatext'
    : '$kOFileCompressedPrefix$kOFileTextSectionPrefix$logicalName';

/// 一个 section 的解析状态。
enum OFileSectionState {
  /// 值本来就是 BSON document/array（未压缩的直给结构）。
  structured,

  /// base64 + JSON 文本（明文，例如 `locale` / `file`）。
  json,

  /// `CompressAdd` 的明文形态：BSON binary → zlib inflate → JSON。
  inflatedJson,

  /// `CompressAdd` 的明文形态，但 inflate 后不是 JSON。
  text,

  /// BSON binary（图片/附件字节），且不来自 `@C_` 压缩 section。
  binary,

  /// 看起来是加密内容：`CompressAdd` 之后还套了
  /// `base64(Saltv2c_‖salt‖AES-256-CBC(...))`（有打开密码的文档）。
  ///
  /// 阶段 2a **不解密**；取内容时抛
  /// [OfficeDocumentPasswordProtectedException]（不返回空串冒充正文）。
  encrypted,

  /// 既不是 zlib 也不是可识别文本，且无法判定：不臆断，标为不可解释。
  opaque,

  /// 非字符串/二进制标量（int/bool 等）。
  scalar,
}

/// 外壳解析的错误码（每种失败路径一个稳定码，**不统一成"解析失败"**）。
enum OFileErrorCode {
  /// BSON 被截断 / 长度不符 / 终结符缺失。
  truncatedBson('E_OFILE_BSON_TRUNCATED'),

  /// BSON 里出现本解析器未覆盖的 type byte。
  unsupportedBsonType('E_OFILE_BSON_UNSUPPORTED_TYPE'),

  /// 顶层缺 `schema` 字段。
  missingSchema('E_OFILE_SCHEMA_MISSING'),

  /// `schema != OFILE_SCHEMA_VERSION(3)`。
  unsupportedSchemaVersion('E_OFILE_SCHEMA_VERSION'),

  /// `.osheet` 外壳缺 `@C_text/index`。
  missingIndexSection('E_OFILE_INDEX_MISSING'),

  /// `.odoc` / `.oslides` 外壳缺 `@C_text/content`。
  missingContentSection('E_OFILE_CONTENT_MISSING'),

  /// `@C_` section 的 binary 载荷不是合法 zlib 流。
  invalidZlibPayload('E_OFILE_ZLIB_INVALID'),

  /// inflate 后不是 UTF-8。
  invalidUtf8Payload('E_OFILE_UTF8_INVALID'),

  /// inflate 后是文本但不是合法 JSON。
  invalidJsonPayload('E_OFILE_JSON_INVALID'),

  /// 无法判别格式 / 无法构造模型等其它外壳级问题。
  unsupported('E_OFILE_UNSUPPORTED');

  const OFileErrorCode(this.wire);

  /// 稳定的线格式错误码（给 UI/日志做互不相同的分支）。
  final String wire;
}

/// 带**打开密码**的文档：阶段 2a 明确拒绝，不输出乱码、不假装读出。
///
/// 触发条件（研究文档 §4.5）：`@C_metatext` 解密后 `encrypt == true`。
/// 文案刻意与"文件损坏"「格式不支持」「OPC 加密」互不相同。
class OfficeDocumentPasswordProtectedException implements Exception {
  OfficeDocumentPasswordProtectedException({this.metatext, this.detail});

  /// 稳定错误码。
  static const String codeWire = 'E_OFFICE_PASSWORD_PROTECTED';

  /// `@C_metatext` 解出的原始 JSON（可能含 `password` 包裹串），只读记录。
  final Map<String, Object?>? metatext;

  final String? detail;

  String get message =>
      '该文档带打开密码，本阅读器暂不支持解密'
      '（Synology Office 原生格式：metatext.encrypt == true，'
      'section 经 zlib deflate + AES-256-CBC 加密）。'
      '解密需要用户提供文档密码，排期在阶段 2b，当前尚未实现。'
      '这不是文件损坏、不是格式不支持，也不是 OPC/Office 加密格式问题。'
      '${detail ?? ''}';

  @override
  String toString() =>
      'OfficeDocumentPasswordProtectedException[$codeWire]: $message';
}

/// 一个**无打开密码**的加密 section（阶段 1 遗留路径 / 无法判定算法的密文）。
///
/// 阶段 2a 对真实"带打开密码"文档走 [OfficeDocumentPasswordProtectedException]；
/// 本异常保留给历史夹具与"外壳标了 enc 但拿不到 `@C_metatext`"的不可判定情况。
class OfficeSectionEncryptedException implements Exception {
  OfficeSectionEncryptedException(this.sectionName, {this.detail});

  final String sectionName;
  final String? detail;

  String get message =>
      'Office 原生文件 section "$sectionName" 已加密'
      '（zlib deflate + AES-256-CBC + base64）：阶段 1 不依赖密钥、不解密，'
      '需阶段 2 提供 sys_password/用户密码。${detail ?? ''}';

  @override
  String toString() => 'OfficeSectionEncryptedException: $message';
}

/// BSON 外壳本身不可解析 / 不符合 OFile 结构（每种情况带 [code]）。
class OFileFormatException implements Exception {
  OFileFormatException(
    this.message, {
    this.code = OFileErrorCode.unsupported,
    this.sectionName,
  });

  final String message;
  final OFileErrorCode code;

  /// 出错的 section（外壳级错误时为 `null`）。
  final String? sectionName;

  /// 稳定错误码（[OFileErrorCode.wire]）。
  String get codeWire => code.wire;

  @override
  String toString() =>
      'OFileFormatException[${code.wire}]'
      '${sectionName == null ? '' : ' section "$sectionName"'}: $message';
}

/// 单个 section。
class OFileSection {
  OFileSection({
    required this.name,
    required this.state,
    required this.rawValue,
    this.bsonKey,
    this.json,
    this.bytes,
    this.text,
    this.detail,
    this.passwordProtected = false,
  });

  /// 逻辑 section 名（已去掉 `@C_` 与 `text/`）。
  final String name;

  /// BSON 里的原始字段名（例如 `@C_text/index`）；历史夹具可能为 `null`。
  final String? bsonKey;

  final OFileSectionState state;

  /// BSON 里的原始值（String / BsonBinary / BsonDocument / …）。
  final Object? rawValue;

  /// [OFileSectionState.structured] / [OFileSectionState.json] /
  /// [OFileSectionState.inflatedJson] 时可用。
  final Object? json;

  /// [OFileSectionState.binary] 时的原始字节。
  final Uint8List? bytes;

  /// 明文文本（json / inflatedJson 的 JSON 原文，或 text）。
  final String? text;

  /// encrypted/opaque 时的人类可读原因。
  final String? detail;

  /// 是否确认来自"带打开密码"的文档（`@C_` 载荷带 `Saltv2c_`/`Salted__` 特征）。
  final bool passwordProtected;

  bool get isEncrypted => state == OFileSectionState.encrypted;

  bool get isOpaque => state == OFileSectionState.opaque;

  /// 结构化结果（顶层一般是 Map）。
  Map<String, Object?>? get jsonMap {
    final v = json;
    return v is Map ? Map<String, Object?>.from(v) : null;
  }

  List<Object?>? get jsonList {
    final v = json;
    return v is List ? List<Object?>.from(v) : null;
  }

  @override
  String toString() => 'OFileSection($name, ${state.name})';
}

/// 链上 `metabinary_files` 带出的一段**内嵌附件**原始字节。
///
/// 真实形态（8 份实测）：BSON document，**键**是整段 JSON 文本
/// `{"name":"<file_id>"}`，**值**是 BSON binary(subtype 0) 的**未压缩**原始字节
/// （PNG `89 50 4e 47` / JPEG `ff d8 ff` 魔数直出）。`@C_text/attachment` 里
/// `<attachment_id>.name` 就是这里的 `<file_id>`。
class OFileEmbeddedFile {
  OFileEmbeddedFile({
    required this.name,
    required this.bytes,
    required this.rawKey,
  });

  /// `{"name":"…"}` 里的 `<file_id>`；键不是该形态时退化为 [rawKey]。
  final String name;

  /// 原始字节（**未压缩**，与 `@C_*` section 的 zlib 载荷不同）。
  final Uint8List bytes;

  /// 链上原始 BSON 键（真实文件 = `{"name":"<file_id>"}` 整段文本）。
  final String rawKey;

  int get length => bytes.length;

  @override
  String toString() => 'OFileEmbeddedFile($name, $length B)';
}

/// 解析后的 OFile。
class OFile {
  OFile({
    required this.schema,
    required this.enc,
    required this.id,
    required this.ver,
    required this.end,
    required this.sections,
    required this.metadata,
    this.metatext = const {},
    this.embeddedFiles = const [],
    this.documentCount = 1,
    this.consumedBytes = 0,
    this.totalBytes = 0,
  });

  /// `schema`（`OFILE_SCHEMA_VERSION` = 3；真实头文档里是 **int64**）。
  final int? schema;

  /// 头文档 `enc`：真实 8 份全 `false`。既有的"打开密码"判定仍以
  /// `@C_metatext.encrypt == true` 为准（真实 8 份的 `@C_metatext` **没有**
  /// `encrypt` 键，`ntype`/`oflie` 才是实测字段）。
  final bool enc;

  /// 头文档 `id`：真实形如 `"1028_<docid>.doc|.sh|.slide"`。
  ///
  /// **不是**纯 Drive object id：`1028_` 前缀 + 文档 id + **格式后缀**。
  /// 后缀可直接判别格式（见 [idSuffix]）。
  final String? id;

  /// 头文档 `ver`：真实类型是 **string**，40 位 hex。
  ///
  /// **疑似 sha1 但未被取证**：8 份实测对"整个文件 / 头文档 / `content` 压缩
  /// 载荷 / `content` 明文 JSON"都没有命中 sha1，语义未知，解析层只原样保留。
  final String? ver;

  /// 终结标记。真实文件里它**不在头文档**，而是链上最后一个 doc
  /// `{"end": true}`（长度恒 11 字节）；[ended] 也是靠链尾判定。
  final bool? end;

  /// 逻辑 section 名 -> section。
  final Map<String, OFileSection> sections;

  /// 剩余的顶层标量（`sys_password`、真实 `metatext` 字面量 `"null"` 等），
  /// 原样保留不解释。
  final Map<String, Object?> metadata;

  /// `@C_metatext` 解出的 JSON（权威 metatext，研究文档 §9.2 第 2 条）。
  ///
  /// 真实 8 份实测：`{"ntype":<21|37|69>,"oflie":true}`（`office-convert-probe`
  /// 少了 `oflie`）；**没有 `encrypt` 字段**。
  final Map<String, Object?> metatext;

  /// `metabinary_files` 带出的内嵌附件（真实文件可有多段，按链上顺序）。
  final List<OFileEmbeddedFile> embeddedFiles;

  /// 解析过的顶层 BSON doc 数（真实：头文档 + 每 section 一个 + `metatext` doc
  /// + 每个 `metabinary_files` 一个 + `{"end":true}`）。
  final int documentCount;

  /// 链恰好消费的字节数；[containerExact] 判"8/8 consumed == size"。
  final int consumedBytes;
  final int totalBytes;

  /// 是否"带打开密码"（`metatext.encrypt == true`，研究文档 §4.5）。
  ///
  /// 真实 8 份皆为 `false`（连 `encrypt` 键都没有）⇒ 走 2a。
  bool get isPasswordProtected => metatext['encrypt'] == true;

  /// `id` 的格式后缀（`doc` / `sh` / `slide`），小写；无后缀时为 `null`。
  String? get idSuffix {
    final v = id;
    if (v == null) return null;
    final dot = v.lastIndexOf('.');
    if (dot < 0 || dot == v.length - 1) return null;
    return v.substring(dot + 1).toLowerCase();
  }

  /// `@C_metatext.ntype`：真实实测 21=文档 / 37=电子表格 / 69=演示文稿。
  int? get metaType {
    final v = metatext['ntype'];
    return v is int ? v : null;
  }

  /// 链是否恰好走完整个文件（真实 8/8 为 `true`）。
  bool get containerExact => totalBytes > 0 && consumedBytes == totalBytes;

  /// 链尾是否出现 `{"end": true}`。
  bool get ended => end == true;

  bool get hasEncryptedSections => sections.values.any((s) => s.isEncrypted);

  bool get hasOpaqueSections => sections.values.any((s) => s.isOpaque);

  Iterable<OFileSection> get encryptedSections =>
      sections.values.where((s) => s.isEncrypted);

  /// 逻辑 section 名列表（保序，BSON 文档顺序）。
  List<String> get sectionNames => sections.keys.toList(growable: false);

  /// `sh_*` 逻辑 section 名（工作表数据），按 BSON 顺序。
  List<String> get sheetSectionNames =>
      sectionNames.where((n) => n.startsWith('sh_')).toList(growable: false);

  OFileSection? section(String name) => sections[name];

  /// 按 `<file_id>` 取内嵌附件；不存在时返回 `null`。
  OFileEmbeddedFile? embeddedFile(String name) {
    for (final f in embeddedFiles) {
      if (f.name == name) return f;
    }
    return null;
  }

  /// 取一个**已解开**的 section；加密/不可解释时抛异常，而不是返回空。
  OFileSection requireSection(String name) {
    final s = sections[name];
    if (s == null) {
      throw OFileFormatException(
        'missing section "$name"',
        code: OFileErrorCode.unsupported,
        sectionName: name,
      );
    }
    if (s.state == OFileSectionState.encrypted) {
      if (s.passwordProtected) {
        throw OfficeDocumentPasswordProtectedException(detail: s.detail);
      }
      throw OfficeSectionEncryptedException(name, detail: s.detail);
    }
    if (s.state == OFileSectionState.opaque) {
      throw OFileFormatException(
        'section "$name" 不可解释（非 zlib、非文本）：${s.detail ?? ''}',
        sectionName: name,
      );
    }
    return s;
  }

  /// 从文件字节解析 OFile：**逐 doc 走完 `[int32 len][BSON doc]` 链**。
  static OFile parse(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw OFileFormatException(
        '空文件：连头文档都没有',
        code: OFileErrorCode.truncatedBson,
      );
    }
    final docs = <BsonDocument>[];
    var offset = 0;
    try {
      while (offset < bytes.length) {
        final r = BsonReader.parseAt(bytes, offset);
        if (r.consumedBytes <= offset) {
          throw BsonFormatException(
            'document at $offset consumed 0 bytes',
            offset,
          );
        }
        docs.add(r.document);
        offset = r.consumedBytes;
      }
    } on BsonFormatException catch (e) {
      throw OFileFormatException(
        'BSON doc 链不可解析（截断/长度不符/终结符缺失）：$e',
        code: OFileErrorCode.truncatedBson,
      );
    } on BsonUnsupportedTypeException catch (e) {
      throw OFileFormatException(
        'BSON 里出现未支持类型：$e',
        code: OFileErrorCode.unsupportedBsonType,
      );
    }
    return fromDocuments(docs, consumedBytes: offset, totalBytes: bytes.length);
  }

  /// 从已解析的**单个** BSON document 构造 OFile（历史/宽松路径；真实文件是链，
  /// 请用 [parse] 或 [fromDocuments]）。
  static OFile fromBson(BsonDocument doc) =>
      fromDocuments([doc], consumedBytes: 0, totalBytes: 0);

  /// 从**整条链**的 BSON doc 构造 OFile。
  ///
  /// 真实链：`docs[0]` = 头文档（`schema`/`enc`/`id`/`ver`），其后每个 doc 载
  /// `@C_text/<part>`（每 doc 一个）、`@C_metatext`（与明文 `metatext` 同 doc）、
  /// `metabinary_files`（可重复）或 `{"end":true}`。
  static OFile fromDocuments(
    List<BsonDocument> docs, {
    required int consumedBytes,
    required int totalBytes,
  }) {
    if (docs.isEmpty) {
      throw OFileFormatException(
        'BSON doc 链为空',
        code: OFileErrorCode.truncatedBson,
      );
    }
    final header = docs.first;
    final sections = <String, OFileSection>{};
    final metadata = <String, Object?>{};
    final metatext = <String, Object?>{};
    final embeddedFiles = <OFileEmbeddedFile>[];
    var ended = false;

    for (final doc in docs) {
      for (final entry in doc.values.entries) {
        final bsonKey = entry.key;
        final value = entry.value;
        if (bsonKey == kOFileEndKey && value == true) {
          // 真实终止 doc：{"end": true}（bool，不是 section）。
          ended = true;
          metadata[bsonKey] = value;
          continue;
        }
        if (bsonKey == kOFileEmbeddedFilesKey) {
          // 真实内嵌附件：值 = document{ {"name":"<file_id>"}: <binary> }。
          embeddedFiles.addAll(_decodeEmbeddedFiles(value));
          continue;
        }
        final logical = oFileLogicalSectionName(bsonKey);
        if (logical == null) {
          if (kOFileMetaKeys.contains(bsonKey)) {
            metadata[bsonKey] = value;
            continue;
          }
          // 历史/未取证字段名：按原始名归档，走阶段 1 的宽松解码，不臆断前缀。
          sections[bsonKey] = _decodeSection(bsonKey, bsonKey, value);
          continue;
        }
        final section = _decodeCompressedSection(bsonKey, logical, value);
        sections[logical] = section;
        if (logical == kOFileMetaTextSection) {
          final m = section.jsonMap;
          if (m != null) metatext.addAll(m);
        }
      }
    }

    final schema = header.getInt('schema');
    if (schema == null) {
      throw OFileFormatException(
        '头文档缺 "schema"（OFile 必须写 OFILE_SCHEMA_VERSION=$kOFileSchemaVersion）',
        code: OFileErrorCode.missingSchema,
        sectionName: 'schema',
      );
    }
    if (schema != kOFileSchemaVersion) {
      throw OFileFormatException(
        'schema=$schema 与 OFILE_SCHEMA_VERSION=$kOFileSchemaVersion 不符：'
        '官方读侧对 schema > $kOFileSchemaVersion 向后拒绝（研究文档 §2.3）',
        code: OFileErrorCode.unsupportedSchemaVersion,
        sectionName: 'schema',
      );
    }

    return OFile(
      schema: schema,
      enc: header.getBool('enc') ?? false,
      id: header.getString('id'),
      ver: header.getString('ver'),
      end: ended ? true : header.getBool('end'),
      sections: sections,
      metadata: metadata,
      metatext: metatext,
      embeddedFiles: embeddedFiles,
      documentCount: docs.length,
      consumedBytes: consumedBytes,
      totalBytes: totalBytes,
    );
  }

  /// 展开 `metabinary_files` 的值（真实 = document；兼容裸 binary）。
  static List<OFileEmbeddedFile> _decodeEmbeddedFiles(Object? value) {
    final out = <OFileEmbeddedFile>[];
    void add(String rawKey, Object? v) {
      if (v is BsonBinary) {
        out.add(
          OFileEmbeddedFile(
            name: _embeddedFileNameFromKey(rawKey) ?? rawKey,
            bytes: v.bytes,
            rawKey: rawKey,
          ),
        );
      }
    }

    if (value is BsonDocument) {
      for (final e in value.values.entries) {
        add(e.key, e.value);
      }
    } else {
      add(kOFileEmbeddedFilesKey, value);
    }
    return out;
  }

  /// 真实键是整段 JSON 文本 `{"name":"<file_id>"}`（**不是**普通字段名）。
  static String? _embeddedFileNameFromKey(String key) {
    final trimmed = key.trim();
    if (!trimmed.startsWith('{')) return null;
    final json = _tryJson(trimmed);
    if (json is Map) {
      final name = json['name'];
      if (name is String && name.isNotEmpty) return name;
    }
    return null;
  }

  /// `@C_` 压缩 section：BSON binary → zlib inflate → utf8 → JSON。
  static OFileSection _decodeCompressedSection(
    String bsonKey,
    String logical,
    Object? value,
  ) {
    if (value is! BsonBinary) {
      // 证据不足时退回宽松解码（不猜），但仍记逻辑名。
      return _decodeSection(logical, bsonKey, value);
    }
    final inflated = _inflateOrThrow(value.bytes, logical);
    final text = _utf8OrThrow(inflated, logical);
    final trimmed = text.trim();
    // 真实 `@C_text/locale` = zlib(`"en_US"`)：**JSON 标量**也是合法 section 载荷
    // （不只是 `{`/`[`）。所以先试 JSON，再谈密文/裸文本。
    final json = _tryJson(trimmed);
    if (json != null) {
      return OFileSection(
        name: logical,
        bsonKey: bsonKey,
        state: OFileSectionState.inflatedJson,
        rawValue: value,
        json: json,
        text: text,
      );
    }
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      throw OFileFormatException(
        'section "$logical" inflate 后以 JSON 开头但不是合法 JSON',
        code: OFileErrorCode.invalidJsonPayload,
        sectionName: logical,
      );
    }

    // 明文 section 的载荷在压缩前应当是 JSON 字符串；不是 JSON 又带官方密文前缀，
    // 就是"带打开密码"的文档（§3.1：`Saltv2c_` / `Saltv2__` / `Salted__`）。
    final cryptoPrefix = _cryptoBlobPrefix(trimmed);
    if (cryptoPrefix != null) {
      return OFileSection(
        name: logical,
        bsonKey: bsonKey,
        state: OFileSectionState.encrypted,
        rawValue: value,
        text: text,
        passwordProtected: true,
        detail:
            'inflate 后是 base64 密文（前缀 "$cryptoPrefix"，'
            '${trimmed.length} 字符）：zlib deflate + AES-256-CBC，'
            '需文档密码（阶段 2b）',
      );
    }

    // 非 JSON、非密文：如实记为文本，不臆断为加密。
    return OFileSection(
      name: logical,
      bsonKey: bsonKey,
      state: OFileSectionState.text,
      rawValue: value,
      text: text,
      detail: 'inflate 后既不是 JSON，也不带已知密文前缀',
    );
  }

  /// 历史/宽松路径（阶段 1）：支持明文 JSON、base64+zlib、裸 binary、标量。
  static OFileSection _decodeSection(
    String name,
    String? bsonKey,
    Object? value,
  ) {
    if (value is BsonDocument || value is Map) {
      final map = value is BsonDocument
          ? value.values
          : Map<String, Object?>.from(value as Map);
      return OFileSection(
        name: name,
        bsonKey: bsonKey,
        state: OFileSectionState.structured,
        rawValue: value,
        json: map,
      );
    }
    if (value is List) {
      return OFileSection(
        name: name,
        bsonKey: bsonKey,
        state: OFileSectionState.structured,
        rawValue: value,
        json: value,
      );
    }
    if (value is BsonBinary) {
      return OFileSection(
        name: name,
        bsonKey: bsonKey,
        state: OFileSectionState.binary,
        rawValue: value,
        bytes: value.bytes,
      );
    }
    if (value is String) {
      return _decodeStringSection(name, bsonKey, value);
    }
    return OFileSection(
      name: name,
      bsonKey: bsonKey,
      state: OFileSectionState.scalar,
      rawValue: value,
    );
  }

  static OFileSection _decodeStringSection(
    String name,
    String? bsonKey,
    String value,
  ) {
    final trimmed = value.trim();
    // 明文 JSON 直给（`locale` / `file` 或未压缩的 section）。
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return OFileSection(
          name: name,
          bsonKey: bsonKey,
          state: OFileSectionState.json,
          rawValue: value,
          json: jsonDecode(trimmed),
          text: trimmed,
        );
      } on FormatException {
        // 落到下面按 base64 处理。
      }
    }

    final decoded = _tryBase64(value);
    if (decoded == null) {
      // 不是 base64：当作裸文本（例如纯 mode 字符串）。
      return OFileSection(
        name: name,
        bsonKey: bsonKey,
        state: OFileSectionState.text,
        rawValue: value,
        text: value,
        detail: '非 base64、非 JSON 的明文文本',
      );
    }

    final inflated = _tryInflate(decoded);
    if (inflated != null) {
      final text = _tryUtf8(inflated);
      if (text != null) {
        final t = text.trim();
        final json = _tryJson(t);
        return OFileSection(
          name: name,
          bsonKey: bsonKey,
          state: json != null
              ? OFileSectionState.inflatedJson
              : OFileSectionState.text,
          rawValue: value,
          json: json,
          text: text,
        );
      }
      return OFileSection(
        name: name,
        bsonKey: bsonKey,
        state: OFileSectionState.text,
        rawValue: value,
        bytes: inflated,
        detail: 'zlib 解开后不是 UTF-8 文本',
      );
    }

    // base64 解开了但 inflate 失败 —— 最可能就是 `CompressAdd` 的 AES 密文。
    final asText = _tryUtf8(decoded);
    if (asText != null &&
        (asText.trim().startsWith('{') || asText.trim().startsWith('['))) {
      return OFileSection(
        name: name,
        bsonKey: bsonKey,
        state: OFileSectionState.json,
        rawValue: value,
        json: _tryJson(asText.trim()),
        text: asText,
        detail: 'base64 解开即 JSON（未走 zlib）',
      );
    }
    return OFileSection(
      name: name,
      bsonKey: bsonKey,
      state: OFileSectionState.encrypted,
      rawValue: value,
      bytes: decoded,
      detail:
          'base64 可解（${decoded.length}B），但 zlib inflate 失败：'
          '符合「deflate→AES-256-CBC→base64」的密文特征，阶段 1 无密钥',
    );
  }

  /// `@C_` section 的 binary 载荷必须是合法 zlib 流；否则抛带错误码的异常。
  static Uint8List _inflateOrThrow(Uint8List data, String logical) {
    if (data.isEmpty) {
      throw OFileFormatException(
        'section "$logical" 的 binary 载荷为空，不是合法 zlib 流',
        code: OFileErrorCode.invalidZlibPayload,
        sectionName: logical,
      );
    }
    try {
      final out = ZLibDecoder().decodeBytes(data);
      if (out.isEmpty) {
        throw OFileFormatException(
          'section "$logical" 的 binary 载荷 inflate 后为空',
          code: OFileErrorCode.invalidZlibPayload,
          sectionName: logical,
        );
      }
      return Uint8List.fromList(out);
    } on OFileFormatException {
      rethrow;
    } catch (e) {
      throw OFileFormatException(
        'section "$logical" 的 binary 载荷不是合法 zlib 流'
        '（Bson::CompressAdd 用 zlib compress2，需 0x78 头）：$e',
        code: OFileErrorCode.invalidZlibPayload,
        sectionName: logical,
      );
    }
  }

  static String _utf8OrThrow(Uint8List data, String logical) {
    try {
      return utf8.decode(data);
    } on FormatException catch (e) {
      throw OFileFormatException(
        'section "$logical" inflate 后不是合法 UTF-8：$e',
        code: OFileErrorCode.invalidUtf8Payload,
        sectionName: logical,
      );
    }
  }

  /// 官方密文前缀（研究文档 §3.1/§3.2）；命中即"带打开密码"。
  ///
  /// 载荷形态有两种可能的写法，这里都兼容（真实文件待逐字节确认）：
  ///   1. `inflate` 后直接是 `prefix‖salt‖ct` 原始字节文本；
  ///   2. `inflate` 后是 `base64(prefix‖salt‖ct)`（§1 分层图与 §3.5 的写法），
  ///      此时先 base64 解码，再看解出来的前 8 字节。
  static String? _cryptoBlobPrefix(String text) {
    for (final p in const ['Saltv2c_', 'Saltv2__', 'Salted__']) {
      if (text.startsWith(p)) return p;
    }
    final decoded = _tryBase64(text);
    if (decoded != null && decoded.length >= 8) {
      final head = ascii.decode(decoded.sublist(0, 8), allowInvalid: true);
      for (final p in const ['Saltv2c_', 'Saltv2__', 'Salted__']) {
        if (head == p) return p;
      }
    }
    return null;
  }

  static Uint8List? _tryBase64(String value) {
    // 先做字符集预筛：`base64.normalize` 对非法字符会**抛** FormatException
    // （真实 `@C_text/locale` = `"en_US"` 就踩过这条路），不能让它冒出去。
    var s = value.trim();
    if (s.isEmpty) return null;
    if (!RegExp(r'^[A-Za-z0-9+/\s]*={0,2}$').hasMatch(s)) return null;
    s = s.replaceAll(RegExp(r'\s'), '');
    if (s.isEmpty || s.length % 4 != 0) return null;
    try {
      return base64.decode(s);
    } on FormatException {
      return null;
    }
  }

  static Uint8List? _tryInflate(Uint8List data) {
    if (data.isEmpty) return null;
    try {
      final out = ZLibDecoder().decodeBytes(data);
      if (out.isEmpty) return null;
      return Uint8List.fromList(out);
    } catch (_) {
      return null;
    }
  }

  static String? _tryUtf8(Uint8List data) {
    try {
      return utf8.decode(data);
    } on FormatException {
      return null;
    }
  }

  static Object? _tryJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
}
