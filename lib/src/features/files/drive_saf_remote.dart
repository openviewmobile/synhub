// ★★★ ③Drive **D66「SAF / ContentProvider」的远端半边** —— 第 221 轮。
//
// ## 背景（第 213 轮做到哪儿）
// `DriveDocumentsProvider.kt` + `drive_saf_index.dart` 已经把 SAF 的**离线文件**
// （`:local:`）半边打通：系统文件选择器里能看到已下载的文件，`openDocument`
// 直接开本地 `ParcelFileDescriptor`。**远端半边**（官方 `:real:` 的按需浏览）
// 一直是待办：provider 自己不会登录 DSM。
//
// ## 本轮做到哪儿（诚实边界）
// 在 **Dart 侧**把 Drive 目录树**镜像**进同一份索引文件（`:real:<fileId>`）⇒
// 系统选择器里能**浏览/搜索**云端文件；**打开**仍要求本地已有副本
// （远端按需下载 + provider 侧自登录 DSM 仍未做，Kotlin 侧给明确错误文案）。
//
// 为什么不直接让 Kotlin 登录：QuickConnect + TLS + 双因子 + 凭据存储都在 Dart 侧
// （`dsm/` 那一套），在 provider 里复刻一份会**分叉出第二套登录通道**——
// 那是更大的不一致，宁可先只做镜像并如实挂账。
import '../../data/dto/drive_entry_dto.dart';
import 'drive_saf_index.dart';
import 'files_i18n.dart';

/// 云端镜像的根标题（与离线那份分开，用户一眼能分辨）
///
/// 原为 `const`：`dataText` 不是常量表达式 ⇒ 改成运行时 getter。
String get safRemoteRootTitle =>
    fsT('driveSafRemoteRootTitle', 'Synology Drive · 云端文件');

/// 镜像时最多收多少条（防止在大盘上把索引写成几 MB）
const int kSafRemoteMaxEntries = 300;

/// 镜像递归深度上限（0 = 只列根）
const int kSafRemoteMaxDepth = 2;

/// 列一个远端目录（`Files/list`）
typedef SafRemoteLister = Future<List<DriveEntryDto>> Function(String path);

class SafRemoteMirrorResult {
  const SafRemoteMirrorResult({
    required this.entries,
    required this.listedFolders,
    required this.errors,
  });

  final List<SafIndexEntry> entries;
  final int listedFolders;

  /// 哪些目录列失败（不中断整体：大盘上个别目录 105/103 很正常）
  final List<String> errors;
}

/// 把一个 Drive 目录**递归镜像**成 SAF 索引条目。
///
/// 规则：
///   * 目录也进索引（`mime_type = vnd.android.document/directory`），否则没法"浏览"；
///   * 文档 id 用官方 `:real:<fileId>`（[SafDocumentId.real]）；
///   * `localPath` 留空（provider 侧据此给"尚未下载"的明确错误）；
///   * 深度/条目数都有上限；单个目录失败**只记录不抛出**。
Future<SafRemoteMirrorResult> buildSafRemoteIndex({
  required List<String> folders,
  required SafRemoteLister listFolder,
  int maxDepth = kSafRemoteMaxDepth,
  int maxEntries = kSafRemoteMaxEntries,
}) async {
  final out = <SafIndexEntry>[];
  final seen = <String>{};
  final errors = <String>[];
  var listed = 0;

  void add(DriveEntryDto e) {
    if (out.length >= maxEntries) return;
    final id = SafDocumentId.real(e.fileId);
    if (!seen.add(id)) return;
    out.add(
      SafIndexEntry(
        documentId: id,
        name: e.name,
        mimeType: e.isDir
            ? 'vnd.android.document/directory'
            : (e.contentType.isEmpty ? '*/*' : e.contentType),
        size: e.isDir ? 0 : e.size,
        lastModified: e.modifiedTime,
      ),
    );
  }

  Future<void> walk(String path, int depth) async {
    if (out.length >= maxEntries) return;
    List<DriveEntryDto> items;
    try {
      items = await listFolder(path);
      listed += 1;
    } catch (e) {
      errors.add('$path: $e');
      return;
    }
    for (final e in items) {
      add(e);
    }
    if (depth >= maxDepth) return;
    for (final e in items.where((e) => e.isDir)) {
      if (out.length >= maxEntries) return;
      final child = path.endsWith('/') ? '$path${e.name}' : '$path/${e.name}';
      await walk(child, depth + 1);
    }
  }

  for (final f in folders) {
    await walk(f, 0);
    if (out.length >= maxEntries) break;
  }
  return SafRemoteMirrorResult(
    entries: out,
    listedFolders: listed,
    errors: errors,
  );
}

/// 把"云端镜像"与"离线文件"合并成一份索引：
/// 离线那份**优先**（同名同 id 不去重，因为 id 前缀不同；但同一个 `:real:` id
/// 若在离线侧已存在，就带上它的本地路径 —— 这样在系统选择器里打开能直接用）。
SafIndex mergeSafIndexes({
  required SafIndex local,
  required SafIndex remote,
  /// `:real:` 条目 → 已下载副本的本地路径（227 轮按需预取的结果）。
  /// 有它就优先于"按文件名猜"，避免同名文件挂错副本。
  Map<String, String> localByDocumentId = const {},
}) {
  final byId = <String, SafIndexEntry>{};
  final localByFileId = <String, SafIndexEntry>{};
  for (final e in local.entries) {
    byId[e.documentId] = e;
    final payload = SafDocumentId.payloadOf(e.documentId);
    if (payload != null && e.documentId.startsWith(SafDocumentId.localPrefix)) {
      localByFileId[payload] = e;
    }
  }
  // 用**文件名**把本地副本挂到云端条目上（离线登记的键是本地路径）
  final localByName = <String, SafIndexEntry>{};
  for (final e in local.entries) {
    localByName.putIfAbsent(e.name, () => e);
  }
  for (final r in remote.entries) {
    final pinned = localByDocumentId[r.documentId];
    final localCopy = pinned == null
        ? localByName[r.name]
        : SafIndexEntry(
            documentId: r.documentId,
            name: r.name,
            mimeType: r.mimeType,
            size: r.size,
            lastModified: r.lastModified,
            localPath: pinned,
          );
    byId.putIfAbsent(
      r.documentId,
      () => localCopy == null
          ? r
          : SafIndexEntry(
              documentId: r.documentId,
              name: r.name,
              mimeType: r.mimeType,
              size: r.size,
              lastModified: r.lastModified,
              localPath: localCopy.localPath,
            ),
    );
  }
  return SafIndex(
    rootTitle: local.entries.isEmpty ? safRemoteRootTitle : local.rootTitle,
    entries: byId.values.toList(),
  );
}
