// Office 原生格式（`.odoc` / `.osheet` / `.oslides`）只读解析的**统一入口**。
//
// 阶段 2a（本批）做的：
//   1. `[int32 len][BSON doc]` **链**外壳解析（`bson/bson_reader.dart` + `ofile.dart`；
//      真实文件修正见 `ofile.dart` 头注释与 `docs/office-native-reader.md` §11）；
//   2. `@C_text/*` / `@C_metatext` 的 **BSON binary → zlib inflate → JSON**；
//   3. 三种格式的只读模型（`osheet_model.dart` / `odoc_model.dart` /
//      `oslides_model.dart`）。
//
// 真实文件：8 份真机样本（`.odoc×4 / .osheet×2 / .oslides×2`）已闭环，
// `test/office_native_real_samples_test.dart` + `test/golden/office_native_real_samples.txt`。
//
// 阶段 2a **不做**的（阶段 2b）：
//   - AES-256-CBC 解密与 `sys_password` / 用户密码派生
//     （`docs/office-crypto-research.md` §3/§4/§5）。
//     因此**带打开密码**（`@C_metatext.encrypt == true`）的真实文件在这里会抛
//     [OfficeDocumentPasswordProtectedException]（明确文案，**绝不**输出乱码、
//     不假装读出、不落进泛化"解析失败"）；无法判定算法的历史密文 section 抛
//     [OfficeSectionEncryptedException]。
//
// "接进既有链路"的边界（最小改动）：
//   本批只提供**解析层入口**（[OfficeNativeReader.parse] /
//   [OfficeNativeDocument.parse]）；**不接 UI**、不改 `lib/src/features/**`。
//   下一批要接页面时，在文件预览处按扩展名调用入口即可。

import 'dart:typed_data';

import '../../core/i18n/data_text.dart';
import 'odoc_model.dart';
import 'office_json.dart';
import 'ofile.dart';
import 'osheet_model.dart';
import 'oslides_model.dart';

/// 三种原生格式。
enum OfficeNativeFormat {
  odoc('.odoc'),
  osheet('.osheet'),
  oslides('.oslides');

  const OfficeNativeFormat(this.extension);

  final String extension;
}

/// 解析结果：外壳 + 对应模型（解不出时为 `null`，绝不编造）。
class OfficeNativeDocument {
  OfficeNativeDocument({
    required this.format,
    required this.envelope,
    this.workbook,
    this.document,
    this.presentation,
    this.encryptedSectionNames = const [],
    this.opaqueSectionNames = const [],
    this.passwordProtected = false,
  });

  final OfficeNativeFormat format;
  final OFile envelope;

  final OSheetWorkbook? workbook;
  final ODocDocument? document;
  final OSlidesPresentation? presentation;

  /// 已确认加密（阶段 2a 无密钥）的 section。
  final List<String> encryptedSectionNames;

  /// 不可解释（非 zlib 非文本，且 `enc=false`）的 section。
  final List<String> opaqueSectionNames;

  /// 该文档带**打开密码**（`@C_metatext.encrypt == true`）；
  /// [OfficeNativeReader.parse] 会对它抛
  /// [OfficeDocumentPasswordProtectedException]。
  final bool passwordProtected;

  bool get hasEncryptedSections => encryptedSectionNames.isNotEmpty;

  bool get hasOpaqueSections => opaqueSectionNames.isNotEmpty;

  /// 是否有可用的任何一种模型。
  bool get hasModel =>
      workbook != null || document != null || presentation != null;

  /// 给 UI/日志用的人类可读说明；没有加密问题时为 `null`。
  String? get encryptionNotice {
    if (passwordProtected) {
      return OfficeDocumentPasswordProtectedException(
        detail: '（object id: ${envelope.id ?? '-'}）',
      ).message;
    }
    if (encryptedSectionNames.isEmpty && opaqueSectionNames.isEmpty) {
      return null;
    }
    final parts = <String>[];
    if (encryptedSectionNames.isNotEmpty) {
      parts.add(
        dataText(
          'officeSectionEncryptedNotice',
          '已加密 section：{x}（zlib+AES-256-CBC+base64）→ 阶段 2a 不解密，需阶段 2b',
        ).replaceAll('{x}', encryptedSectionNames.join(', ')),
      );
    }
    if (opaqueSectionNames.isNotEmpty) {
      parts.add(
        dataText(
          'officeSectionOpaqueNotice',
          '不可解释 section：{x}',
        ).replaceAll('{x}', opaqueSectionNames.join(', ')),
      );
    }
    return parts.join(dataText('listSeparator', '；'));
  }

  /// 单一入口：**文件字节 → 模型**（`OfficeNativeReader.parse` 的同义写法）。
  ///
  /// 供 UI 批次直接调用；本批**不接 UI**。
  static OfficeNativeDocument parse(
    Uint8List bytes, {
    String? fileName,
    OfficeNativeFormat? format,
  }) => OfficeNativeReader.parse(bytes, fileName: fileName, format: format);
}

/// 解析层入口。
abstract final class OfficeNativeReader {
  /// 支持的原生扩展名。
  static const Set<String> extensions = {'.odoc', '.osheet', '.oslides'};

  /// 按文件名（不区分大小写）判断格式；不是原生格式返回 `null`。
  static OfficeNativeFormat? formatForFileName(String fileName) {
    final lower = fileName.toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = lower.substring(dot);
    for (final f in OfficeNativeFormat.values) {
      if (f.extension == ext) return f;
    }
    return null;
  }

  static bool canParseFileName(String fileName) =>
      formatForFileName(fileName) != null;

  /// 从**已解开的** section 字典构造模型（测试、阶段 2 解密后都走这里）。
  ///
  /// [format] 为 `null` 时按内容自动判别。
  static OfficeNativeDocument parseSections(
    Map<String, Object?> sections, {
    OfficeNativeFormat? format,
    OFile? envelope,
  }) {
    final resolved = format ?? detectFormatFromSections(sections);
    if (resolved == null) {
      throw OFileFormatException(
        '无法从 section 判别格式（键：${sections.keys.join(', ')}）',
      );
    }
    final shell =
        envelope ??
        OFile(
          schema: null,
          enc: false,
          id: null,
          ver: null,
          end: null,
          sections: const {},
          metadata: const {},
        );
    switch (resolved) {
      case OfficeNativeFormat.osheet:
        return OfficeNativeDocument(
          format: resolved,
          envelope: shell,
          workbook: OSheetWorkbook.fromSections(sections),
        );
      case OfficeNativeFormat.odoc:
        return OfficeNativeDocument(
          format: resolved,
          envelope: shell,
          document: ODocDocument.fromSections(sections),
        );
      case OfficeNativeFormat.oslides:
        return OfficeNativeDocument(
          format: resolved,
          envelope: shell,
          presentation: OSlidesPresentation.fromSections(sections),
        );
    }
  }

  /// 从内容猜格式：`.osheet` 有 `sh_*`/`style`/`define`；doc/slides 靠
  /// `content.data.attrs.type`（`document` / `presentation`），再退化到节点名。
  static OfficeNativeFormat? detectFormatFromSections(
    Map<String, Object?> sections,
  ) {
    final hasSheetSection = sections.keys.any((k) => k.startsWith('sh_'));
    if (hasSheetSection ||
        (sections.containsKey('style') && sections.containsKey('define'))) {
      return OfficeNativeFormat.osheet;
    }
    final content = asJsonMap(sections['content']);
    if (content != null) {
      final data = asJsonMap(content['data']);
      final attrs = asJsonMap(data?['attrs']);
      final type = asJsonString(attrs?['type']);
      if (type == 'document') return OfficeNativeFormat.odoc;
      if (type == 'presentation') return OfficeNativeFormat.oslides;
      final root = data?['content'];
      if (findFirstNodeByType(root, 'slide_container') != null ||
          findFirstNodeByType(root, 'master_container') != null) {
        return OfficeNativeFormat.oslides;
      }
      if (findFirstNodeByType(root, 'edit_area') != null) {
        return OfficeNativeFormat.odoc;
      }
    }
    return null;
  }

  /// 解析真实文件字节：BSON 外壳 → 无密钥 section 解码 → 模型。
  ///
  /// **带打开密码**的文档（`@C_metatext.encrypt == true`）抛
  /// [OfficeDocumentPasswordProtectedException]（专属文案，不落进"解析失败"）。
  /// 必需 section 处于不可判定加密状态时抛 [OfficeSectionEncryptedException]。
  /// 想"先看外壳、不抛异常"用 [inspect]。
  static OfficeNativeDocument parse(
    Uint8List bytes, {
    String? fileName,
    OfficeNativeFormat? format,
  }) {
    final envelope = OFile.parse(bytes);
    // 先判"打开密码"，否则 doc/slides 在没有文件名/格式时连格式都判别不了，
    // 会退化成一个泛化的"无法判别格式"错误（不允许）。
    if (envelope.isPasswordProtected) {
      throw OfficeDocumentPasswordProtectedException(
        metatext: envelope.metatext,
        detail: '（object id: ${envelope.id ?? '-'}）',
      );
    }
    final doc = inspectOFile(envelope, fileName: fileName, format: format);
    if (doc.hasModel) return doc;
    if (doc.encryptedSectionNames.isNotEmpty) {
      throw OfficeSectionEncryptedException(
        doc.encryptedSectionNames.first,
        detail: '文件含 ${doc.encryptedSectionNames.length} 个加密 section',
      );
    }
    throw OFileFormatException(
      '无法从 OFile 构造 ${doc.format.extension} 模型'
      '（已解开 section：${doc.envelope.sectionNames.join(', ')}）',
      code: OFileErrorCode.unsupported,
    );
  }

  /// 只做"能解多少解多少"的外壳检查，**不抛**加密/密码异常。
  static OfficeNativeDocument inspect(
    Uint8List bytes, {
    String? fileName,
    OfficeNativeFormat? format,
  }) => inspectOFile(OFile.parse(bytes), fileName: fileName, format: format);

  /// [inspect] 的核心：对**已解析**的外壳做检查（便于阶段 2b 复用）。
  static OfficeNativeDocument inspectOFile(
    OFile envelope, {
    String? fileName,
    OfficeNativeFormat? format,
  }) {
    final resolved =
        format ??
        (fileName == null ? null : formatForFileName(fileName)) ??
        _detectFormatFromOFile(envelope);
    if (resolved == null) {
      throw OFileFormatException(
        '无法判别格式（section：${envelope.sectionNames.join(', ')}）',
        code: OFileErrorCode.unsupported,
      );
    }

    // 必需 section 的外壳级缺失：给专属错误码，不落进泛化"解析失败"。
    if (resolved == OfficeNativeFormat.osheet &&
        !envelope.sections.containsKey('index')) {
      throw OFileFormatException(
        '缺 "@C_text/index"（.osheet 必需；BP 里有：'
        '${envelope.sectionNames.join(', ')}）',
        code: OFileErrorCode.missingIndexSection,
        sectionName: 'index',
      );
    }
    if (resolved != OfficeNativeFormat.osheet &&
        !envelope.sections.containsKey('content')) {
      throw OFileFormatException(
        '缺 "@C_text/content"（${resolved.extension} 必需；BP 里有：'
        '${envelope.sectionNames.join(', ')}）',
        code: OFileErrorCode.missingContentSection,
        sectionName: 'content',
      );
    }

    final sections = <String, Object?>{};
    final encrypted = <String>[];
    final opaque = <String>[];
    for (final section in envelope.sections.values) {
      if (section.name == kOFileMetaTextSection) {
        // metatext 是外壳元数据（encrypt/password 判定用），不是模型 section。
        continue;
      }
      if (section.isEncrypted) {
        encrypted.add(section.name);
        continue;
      }
      if (section.isOpaque) {
        opaque.add(section.name);
        continue;
      }
      if (section.json != null) {
        sections[section.name] = section.json;
      }
    }

    OfficeNativeDocument base({
      OSheetWorkbook? workbook,
      ODocDocument? document,
      OSlidesPresentation? presentation,
    }) => OfficeNativeDocument(
      format: resolved,
      envelope: envelope,
      workbook: workbook,
      document: document,
      presentation: presentation,
      encryptedSectionNames: encrypted,
      opaqueSectionNames: opaque,
      passwordProtected: envelope.isPasswordProtected,
    );

    // 必需 payload 缺失（尤其被加密）时，模型留 null，由调用方决定怎么报。
    final payloadReady = switch (resolved) {
      OfficeNativeFormat.osheet =>
        sections.containsKey('index') &&
            sections.keys.any((k) => k.startsWith('sh_')),
      OfficeNativeFormat.odoc ||
      OfficeNativeFormat.oslides => sections.containsKey('content'),
    };
    if (!payloadReady) return base();

    final model = parseSections(sections, format: resolved, envelope: envelope);
    return base(
      workbook: model.workbook,
      document: model.document,
      presentation: model.presentation,
    );
  }

  static OfficeNativeFormat? _detectFormatFromOFile(OFile envelope) {
    // 1) 头文档 `id` 后缀（**真实文件实测**：`1028_<docid>.doc|.sh|.slide`）。
    final byId = _formatFromIdSuffix(envelope.idSuffix);
    if (byId != null) return byId;
    // 2) section 名线索（历史/自造夹具路径；doc 与 slides 单看外壳无法区分）。
    final names = envelope.sectionNames;
    if (names.any((n) => n.startsWith('sh_'))) return OfficeNativeFormat.osheet;
    if (names.contains('style') && names.contains('define')) {
      return OfficeNativeFormat.osheet;
    }
    // 3) `@C_metatext.ntype`（**真实文件实测**：21=文档 / 37=表格 / 69=演示）。
    final byType = _formatFromMetaType(envelope.metaType);
    if (byType != null) return byType;
    return null;
  }

  /// 真实头文档 `id` 后缀 → 格式。
  static OfficeNativeFormat? _formatFromIdSuffix(String? suffix) {
    switch (suffix) {
      case 'doc':
        return OfficeNativeFormat.odoc;
      case 'sh':
        return OfficeNativeFormat.osheet;
      case 'slide':
        return OfficeNativeFormat.oslides;
      default:
        return null;
    }
  }

  /// 真实 `@C_metatext.ntype` → 格式（8 份实测 21/37/69）。
  static OfficeNativeFormat? _formatFromMetaType(int? ntype) {
    switch (ntype) {
      case 21:
        return OfficeNativeFormat.odoc;
      case 37:
        return OfficeNativeFormat.osheet;
      case 69:
        return OfficeNativeFormat.oslides;
      default:
        return null;
    }
  }
}
