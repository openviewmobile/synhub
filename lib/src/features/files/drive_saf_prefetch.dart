// ★★★ ③Drive **D66「SAF 云端条目按需下载」** —— 第 227 轮。
//
// ## 现状（221 轮之后）
// 云端目录树已经镜像进 SAF 索引（`:real:<fileId>`），系统选择器里能**浏览/搜索**，
// 但条目**没有本地副本**，provider 打开时只能报错"请先设为离线可用"。
//
// ## 本轮做到哪儿
// 加一层**有界预取**：刷新索引时，把 `:real:` 条目里**体积小**的文件下载到
// App 私有缓存（`saf_cache/<fileId>_<名字>`），把 `documentId → 本地路径` 交给
// `mergeSafIndexes` ⇒ 这些云端条目在系统选择器里**直接能打开**。
//
// 边界（都是刻意设的，防止一个大目录把手机塞满）：
//   * `maxFileBytes`（单文件上限，默认 8 MB）
//   * `maxTotalBytes`（本轮总量上限，默认 24 MB）
//   * `maxFiles`（本轮文件个数上限，默认 20）
//   * 任何一条失败**只记录不中断**（`failed`）
//
// ⚠️ 仍**没有**"打开那一刻真去下载"的能力 —— provider 自己不做 DSM 登录，
// 所以超过上限的文件仍然打不开（**如实报错**，不假装成功）。
import 'dart:io';
import 'dart:typed_data';

import 'drive_saf_index.dart';

class SafPrefetchPolicy {
  const SafPrefetchPolicy({
    this.enabled = true,
    this.maxFileBytes = 8 << 20,
    this.maxTotalBytes = 24 << 20,
    this.maxFiles = 20,
  });

  final bool enabled;
  final int maxFileBytes;
  final int maxTotalBytes;
  final int maxFiles;

  static const SafPrefetchPolicy off = SafPrefetchPolicy(enabled: false);

  @override
  bool operator ==(Object other) =>
      other is SafPrefetchPolicy &&
      other.enabled == enabled &&
      other.maxFileBytes == maxFileBytes &&
      other.maxTotalBytes == maxTotalBytes &&
      other.maxFiles == maxFiles;

  @override
  int get hashCode =>
      Object.hash(enabled, maxFileBytes, maxTotalBytes, maxFiles);
}

class SafPrefetchResult {
  const SafPrefetchResult({
    required this.downloaded,
    required this.skippedTooBig,
    required this.skippedByLimit,
    required this.failed,
    required this.bytes,
  });

  const SafPrefetchResult.empty()
    : downloaded = const [],
      skippedTooBig = const [],
      skippedByLimit = const [],
      failed = const [],
      bytes = 0;

  /// 成功的 `document_id`
  final List<String> downloaded;
  final List<String> skippedTooBig;
  final List<String> skippedByLimit;
  final List<String> failed;
  final int bytes;

  int get considered =>
      downloaded.length +
      skippedTooBig.length +
      skippedByLimit.length +
      failed.length;

  Map<String, Object?> toJson() => {
    'downloaded': downloaded.length,
    'skipped_too_big': skippedTooBig.length,
    'skipped_by_limit': skippedByLimit.length,
    'failed': failed.length,
    'bytes': bytes,
  };
}

/// 取一个远端文件的字节（生产实现：`downloadUrl` + `getBytes`）
typedef SafPrefetchFetcher =
    Future<List<int>> Function(String fileId, String name);

/// 把字节落到本地并返回**本地路径**（可注入 ⇒ 用例不碰真实磁盘）
typedef SafPrefetchWriter =
    Future<String> Function(String documentId, String name, List<int> bytes);

/// 有界预取。只处理 `:real:` 条目（别的前缀直接忽略）。
Future<({Map<String, String> localPaths, SafPrefetchResult result})>
prefetchSafCloudEntries({
  required List<SafIndexEntry> entries,
  required SafPrefetchFetcher fetch,
  required SafPrefetchWriter writeLocal,
  SafPrefetchPolicy policy = const SafPrefetchPolicy(),
}) async {
  final localPaths = <String, String>{};
  final downloaded = <String>[];
  final tooBig = <String>[];
  final byLimit = <String>[];
  final failed = <String>[];
  var bytes = 0;

  if (!policy.enabled) {
    return (
      localPaths: localPaths,
      result: SafPrefetchResult.empty(),
    );
  }

  for (final e in entries) {
    if (!e.documentId.startsWith(SafDocumentId.realPrefix)) continue;
    final fileId = SafDocumentId.payloadOf(e.documentId) ?? '';
    if (fileId.isEmpty) continue;
    if (e.mimeType == 'vnd.android.document/directory') continue;
    if (downloaded.length + byLimit.length >= policy.maxFiles) {
      byLimit.add(e.documentId);
      continue;
    }
    if (e.size > policy.maxFileBytes) {
      tooBig.add(e.documentId);
      continue;
    }
    if (bytes >= policy.maxTotalBytes) {
      byLimit.add(e.documentId);
      continue;
    }
    try {
      final data = await fetch(fileId, e.name);
      if (bytes + data.length > policy.maxTotalBytes) {
        // 边界：这一条会把总量顶破 ⇒ 不写
        byLimit.add(e.documentId);
        continue;
      }
      final path = await writeLocal(e.documentId, e.name, data);
      localPaths[e.documentId] = path;
      downloaded.add(e.documentId);
      bytes += data.length;
    } catch (_) {
      failed.add(e.documentId);
    }
  }

  return (
    localPaths: localPaths,
    result: SafPrefetchResult(
      downloaded: downloaded,
      skippedTooBig: tooBig,
      skippedByLimit: byLimit,
      failed: failed,
      bytes: bytes,
    ),
  );
}

/// 给生产用的默认写入器（`<dir>/<fileId>_<name>`，同名覆盖）。
class SafPrefetchFileWriter {
  const SafPrefetchFileWriter(this.cacheDirPath);

  final String cacheDirPath;

  Future<String> write(
    String documentId,
    String name,
    List<int> bytes,
  ) async {
    final fileId = SafDocumentId.payloadOf(documentId) ?? 'x';
    final safeName = name.replaceAll(RegExp(r'[/\\]'), '_');
    final path = '$cacheDirPath/${fileId}_$safeName';
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(Uint8List.fromList(bytes), flush: true);
    return path;
  }
}
