// ★★ ③Drive 第 213 轮 **D66「SAF / ContentProvider 暴露」** 的 Dart 半边。
//
// ## 官方事实（`SynologyDrive 3.9.0-1113` smali，逐字）
//
// `provider/DriveDocumentsProvider.smali`（`android.provider.DocumentsProvider`）：
//
// | 官方 | 我方对齐 |
// |---|---|
// | 字符串常量 `com.synology.dsdrive.documents` | **authority**（我们是自己的包名：`com.openviewai.synhub.drive.documents`） |
// | 文档 id 前缀 `:real:` / `:label:` / `:local:` / `:create_folder:` + 虚拟根 `virtualTop` | [SafDocumentId] 全部实现（前缀**逐字相同**） |
// | 列 `_display_name` / `_size` / `last_modified` / `mime_type` / `icon` / `flags` / `summary` / `title` / `root_id` / `document_id`（+ `search`） | [SafIndexEntry] 提供这些列（`icon`/`flags`/`summary` 在 Kotlin 侧按契约填） |
// | 目录 MIME `vnd.android.document/directory` | Kotlin 侧常量 |
// | `queryRoots/queryDocument/queryChildDocuments/querySearchDocuments/openDocument/openDocumentThumbnail/openTypedDocument/createDocument` | Kotlin 侧逐个实现（见 `DriveDocumentsProvider.kt`） |
// | `checkLoginStatus` / `getNeedGDPRAgreedMatrixCursor` / `getLoadingMatrixCursor` | 官方是"未登录/未同意 GDPR/加载中"三种**占位游标**；我方离线只读根不做这三种（记在台账的待办里） |
//
// ## 本文件的范围（如实登记，不是"全做完了"）
//
// * **只登记官方 `:local:` 语义**：真正**已在本地有副本**的离线文件
//   （`OfflinePinEntry.hasLocalCopy`）才进索引 —— 没下载的登记项**不进**，
//   免得系统文件选择器里点开一个 404。
// * **索引是给 Kotlin provider 读的 JSON 文件**（不用共享密钥库：SAF 的
//   provider 可能在 Flutter 引擎没起来时被系统叫起来）。契约见 [safIndexFileName]。
// * **远端按需浏览 / 打开（官方的 `:real:` 主体）暂不做** —— 那需要 provider
//   自己登录 DSM（QuickConnect + TLS + 存储凭据），是 L 级工程；本批把
//   id 方案与列契约先钉死，留待接上。
import 'dart:convert';
import 'dart:io';

import 'file_offline_pin.dart' show OfflinePinEntry;
import 'files_i18n.dart';

/// SAF provider 的 authority（`AndroidManifest.xml` 与 Kotlin 侧必须一致）。
const String safAuthority = 'com.openviewai.synhub.drive.documents';

/// 索引 JSON 的文件名；放在 `getApplicationDocumentsDirectory()/saf/` 下。
///
/// Kotlin 侧的读法（契约，两侧都写死这一条）：
/// `File(context.filesDir.parentFile, "app_flutter/saf/$safIndexFileName")`
/// —— Android 上 `getApplicationDocumentsDirectory()` = `<dataDir>/app_flutter`。
const String safIndexFileName = 'drive_index.json';

/// `saf/` 子目录名。
const String safIndexDirName = 'saf';

/// 官方 `DriveDocumentsProvider` 的文档 id 方案。
///
/// 前缀逐字来自 smali 常量表（`:real:` / `:label:` / `:local:` /
/// `:create_folder:`），虚拟根 id 是 `virtualTop`。
class SafDocumentId {
  const SafDocumentId._();

  /// 官方虚拟根：`queryRoots` 回的那个 root 的 document id。
  static const String virtualTop = 'virtualTop';

  /// 远端文件的 id 前缀（官方 `:real:`）——**本批不产生**，但编解码已对齐。
  static const String realPrefix = ':real:';

  /// 标签（label）视图的 id 前缀（官方 `:label:`）。
  static const String labelPrefix = ':label:';

  /// 本地副本的 id 前缀（官方 `:local:`）—— **本批唯一会产生的**。
  static const String localPrefix = ':local:';

  /// 新建文件夹的临时 id 标记（官方 `:create_folder:`）。
  static const String createFolderPrefix = ':create_folder:';

  static String real(String fileId) => '$realPrefix$fileId';
  static String label(String labelId) => '$labelPrefix$labelId';
  static String local(String path) => '$localPrefix$path';

  /// id 的种类（认不出来回 [SafDocumentKind.unknown]）。
  static SafDocumentKind kindOf(String documentId) {
    if (documentId == virtualTop) return SafDocumentKind.virtualTop;
    if (documentId.startsWith(realPrefix)) return SafDocumentKind.real;
    if (documentId.startsWith(labelPrefix)) return SafDocumentKind.label;
    if (documentId.startsWith(localPrefix)) return SafDocumentKind.local;
    if (documentId.startsWith(createFolderPrefix)) {
      return SafDocumentKind.createFolder;
    }
    return SafDocumentKind.unknown;
  }

  /// 前缀后面的负载（虚拟根回 `''`；认不出来回 `null`）。
  static String? payloadOf(String documentId) {
    if (documentId == virtualTop) return '';
    for (final p in const [
      realPrefix,
      labelPrefix,
      localPrefix,
      createFolderPrefix,
    ]) {
      if (documentId.startsWith(p)) {
        return documentId.substring(p.length);
      }
    }
    return null;
  }
}

enum SafDocumentKind { virtualTop, real, label, local, createFolder, unknown }

/// 索引里的一条（= Kotlin `MatrixCursor` 的一行）。
class SafIndexEntry {
  const SafIndexEntry({
    required this.documentId,
    required this.name,
    required this.mimeType,
    this.size = 0,
    this.lastModified = 0,
    this.localPath = '',
  });

  /// `document_id` 列（官方是 `:local:<本地路径>`）
  final String documentId;

  /// `_display_name` / `title` 列
  final String name;

  /// `mime_type` 列
  final String mimeType;

  /// `_size` 列
  final int size;

  /// 文件修改时间（**epoch 秒**，服务端原值）。
  ///
  /// ★ r368 订正（DA20）：SAF 的 `Document.COLUMN_LAST_MODIFIED` 契约要求
  /// **毫秒**，而索引里存的是服务端秒值 —— 转换的责任在 **provider 边界**
  /// （`DriveDocumentsProvider.rowFor` 里 `* 1000`），本字段保持秒不变，
  /// 这样索引文件与其它消费者（Dart 侧）看到的仍是同一把尺子。
  final int lastModified;

  /// 本地真实路径（`openDocument` 用它开 `ParcelFileDescriptor`）
  final String localPath;

  Map<String, Object?> toJson() => {
    'document_id': documentId,
    'name': name,
    'mime_type': mimeType,
    'size': size,
    'last_modified': lastModified,
    'local_path': localPath,
  };

  static SafIndexEntry fromJson(Map<String, Object?> j) => SafIndexEntry(
    documentId: '${j['document_id'] ?? ''}',
    name: '${j['name'] ?? ''}',
    mimeType: '${j['mime_type'] ?? '*/*'}',
    size: (j['size'] as num?)?.toInt() ?? 0,
    lastModified: (j['last_modified'] as num?)?.toInt() ?? 0,
    localPath: '${j['local_path'] ?? ''}',
  );
}

/// 索引文件的顶层结构。
class SafIndex {
  const SafIndex({required this.rootTitle, required this.entries});

  /// 根的显示名（系统文件选择器里看到的那一行）
  final String rootTitle;

  final List<SafIndexEntry> entries;

  Map<String, Object?> toJson() => {
    'version': 1,
    'authority': safAuthority,
    'root_id': SafDocumentId.virtualTop,
    'root_title': rootTitle,
    'entries': [for (final e in entries) e.toJson()],
  };

  static SafIndex fromJson(Map<String, Object?> j) => SafIndex(
    rootTitle: '${j['root_title'] ?? ''}',
    entries: [
      for (final e in (j['entries'] as List?) ?? const [])
        if (e is Map) SafIndexEntry.fromJson(e.cast<String, Object?>()),
    ],
  );
}

/// 官方根标题里我们只暴露"离线文件"这一档。
///
/// 原为 `const`：`dataText` 不是常量表达式 ⇒ 改成运行时 getter
/// （调用点都不是 const 上下文）。
String get safOfflineRootTitle =>
    fsT('driveSafOfflineRootTitle', 'Synology Drive · 离线文件');

/// 从离线登记清单构造 SAF 索引。
///
/// **只收真在本地有副本的**（[OfflinePinEntry.hasLocalCopy]）——
/// 官方 `:local:` 也只在本地文件存在时才有意义；没下载的登记项进索引
/// 只会在系统选择器里给用户一个点不开的条目。
///
/// [isFile] 默认用 `File(localPath).isFileSync()`；测试里注入假实现，
/// 免得为了断言"没下载的不进索引"去造真实文件。
List<SafIndexEntry> buildSafIndex(
  Iterable<OfflinePinEntry> pins, {
  String Function(String name)? mimeOf,
  bool Function(String localPath)? isFile,
}) {
  final exists = isFile ?? (p) => FileSystemEntity.isFileSync(p);
  final mime = mimeOf ?? _defaultMime;
  final out = <SafIndexEntry>[];
  for (final p in pins) {
    if (!p.hasLocalCopy) continue;
    if (!exists(p.localPath)) continue;
    out.add(
      SafIndexEntry(
        documentId: SafDocumentId.local(p.localPath),
        name: p.name.isEmpty ? _baseName(p.localPath) : p.name,
        mimeType: mime(p.name),
        size: p.size,
        lastModified: p.pinnedAt,
        localPath: p.localPath,
      ),
    );
  }
  return out;
}

/// 把索引写到 `<dir>/saf/drive_index.json`（目录不存在就建）。
///
/// 返回写出的文件（写失败时**抛出**，由调用方决定是吞还是报 ——
/// 索引写不进去只影响"系统选择器里有没有离线文件"，不该拖垮主流程）。
Future<File> writeSafIndex(Directory dir, SafIndex index) async {
  final folder = Directory('${dir.path}/$safIndexDirName');
  if (!folder.existsSync()) await folder.create(recursive: true);
  final file = File('${folder.path}/$safIndexFileName');
  await file.writeAsString(jsonEncode(index.toJson()), flush: true);
  return file;
}

/// 读回索引；文件不在 / 坏了都回 `null`（调用方按"没索引"处理，不猜）。
SafIndex? readSafIndexSync(File file) {
  try {
    if (!file.existsSync()) return null;
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map) return null;
    return SafIndex.fromJson(raw.cast<String, Object?>());
  } catch (_) {
    return null;
  }
}

String _baseName(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

String _defaultMime(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '*/*';
  final ext = name.substring(dot + 1).toLowerCase();
  const table = {
    'txt': 'text/plain',
    'md': 'text/markdown',
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'odoc': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'osheet': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'oslides': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'flac': 'audio/flac',
    'wav': 'audio/wav',
    'mp4': 'video/mp4',
    'mkv': 'video/x-matroska',
    'zip': 'application/zip',
    'epub': 'application/epub+zip',
    'mobi': 'application/x-mobipocket-ebook',
    'azw3': 'application/vnd.amazon.ebook',
    'cbz': 'application/vnd.comicbook+zip',
  };
  return table[ext] ?? '*/*';
}
