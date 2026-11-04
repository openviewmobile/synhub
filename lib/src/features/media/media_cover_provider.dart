// 内嵌封面的**取片段 + 解析 + 缓存**接线层（UI 层，允许 flutter/riverpod）。
//
// 为什么单独一层：`media_cover.dart` 是纯解析（不知道网络、不知道 Riverpod），
// 这一层负责"按 `Range` 只取头/尾片段 → 交给解析器 → 写进 FIFO 缓存"。
//
// 四条硬规则：
//   1. **只发片段请求**：头部走 `getBytes(maxBytes:)`（`Range: bytes=0-N`），
//      尾部走 `getBytes(tailBytes:)`（`Range: bytes=-N`）——永远不会为了封面
//      下载整个文件（片段大小见 `mediaCoverRequestFor`）；
//   2. **两段式**：第一段预读若发现图片帧比预读更长（真机样本的 2MB APIC），
//      再发**一次**精确区间请求（`MediaCoverScan.range`，上限
//      `kMediaCoverRangeMaxBytes` = 4MB）；小封面仍然只发一次；
//   3. **拿不到就 null**：网络失败 / 容器不支持 / 解析不出 / 不像图片 /
//      第二段长度对不上，一律 null，让 UI 退回现有图标或黑底，绝不显示破图；
//   4. **缓存优先**：FIFO 字节缓存（`media_cover.dart`），同一个文件在列表里
//      滚进滚出只解析一次。
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/file_entry_dto.dart';
import '../../core/net/traffic_meter.dart';
import '../../dsm/webapi.dart';
import '../servers/session_controller.dart';
import 'media_cover.dart';
import 'media_source.dart';

/// 一次"要内嵌封面"的请求身份。
///
/// [cacheKey] 建议 `<path|url>|<mtime>|<size>`：文件被覆盖后键变、自然回源，
/// 也便于 [evictMediaCovers] 按路径前缀失效。
class MediaCoverKey {
  const MediaCoverKey({
    required this.cacheKey,
    required this.uri,
    required this.kind,
    required this.extension,
    this.fileSize = 0,
    this.rangeSupported = true,
  });

  final String cacheKey;

  /// 取字节的鉴权直链（FileStation `Download` / Drive `Files/download`）
  final String uri;

  final MediaKind kind;
  final String extension;
  final int fileSize;

  /// 服务端是否支持 HTTP Range（Drive 写死 `Accept-Ranges: none` → false，
  /// 这种情况**不为了封面整份下载**，直接放弃）
  final bool rangeSupported;

  @override
  bool operator ==(Object other) =>
      other is MediaCoverKey &&
      other.cacheKey == cacheKey &&
      other.uri == uri &&
      other.kind == kind &&
      other.extension == extension &&
      other.fileSize == fileSize &&
      other.rangeSupported == rangeSupported;

  @override
  int get hashCode =>
      Object.hash(cacheKey, uri, kind, extension, fileSize, rangeSupported);

  @override
  String toString() => 'MediaCoverKey($cacheKey)';
}

/// 从"文件条目 + 已解析的播放来源"拼一个封面请求。
///
/// 前提：来源可播且支持 Range（FileStation 主通道）。Drive / Photos 的
/// `supportsRange=false` → 返回 null（不为了封面整份下载）。
MediaCoverKey? mediaCoverKeyFor(FileEntryDto entry, MediaSource source) {
  if (source.uri.isEmpty || !source.supportsRange) return null;
  final plan = mediaCoverRequestFor(
    kind: source.kind,
    extension: entry.extension,
    fileSize: entry.size,
  );
  if (!plan.supported) return null;
  return MediaCoverKey(
    cacheKey: '${entry.path}|${entry.mtime}|${entry.size}',
    uri: source.uri,
    kind: source.kind,
    extension: entry.extension,
    fileSize: entry.size,
    rangeSupported: true,
  );
}

/// 从播放来源本身拼一个封面请求（播放页没有 `FileEntryDto` 时用）。
MediaCoverKey? mediaCoverKeyOfSource(MediaSource source) {
  if (source.uri.isEmpty || !source.supportsRange) return null;
  final ext = normalizeMediaExtension(source.displayName);
  if (ext.isEmpty) return null;
  final plan = mediaCoverRequestFor(
    kind: source.kind,
    extension: ext,
    fileSize: source.size,
  );
  if (!plan.supported) return null;
  return MediaCoverKey(
    cacheKey: '${source.uri}|${source.size}',
    uri: source.uri,
    kind: source.kind,
    extension: ext,
    fileSize: source.size,
    rangeSupported: true,
  );
}

/// 失败**不自动重试**（同文件模块：移动网络下指数退避是"偷偷烧流量"）。
Duration? _noRetry(int retryCount, Object error) => null;

/// 取片段用的 API。单独一个 provider 是为了测试里能直接塞一个假传输，
/// 从而钉死"只发 Range 片段请求、不下载整文件"。
final mediaCoverApiProvider = Provider<DsmWebApi?>(
  // 流量归属：封面走 media 模块（原生/图片加载器那部分不在这里）
  (ref) => ref
      .watch(sessionControllerProvider)
      .connection
      ?.api
      .withModule(TrafficModules.media),
);

/// **第二段**（精确）取字节的口：给定图片在文件里的绝对区间 `[start, end)`，
/// 返回**恰好这段**字节；拿不到 → null（不抛）。
///
/// 契约（测试按它断言 Range）：
///   * [start] / [end] 是**文件绝对偏移**，`end - start` 已经过
///     `kMediaCoverRangeMaxBytes`（4MB）闸门；
///   * 返回的字节长度必须等于 `end - start`，否则调用方按 null 处理
///     （绝不把半张图喂给 `Image.memory`）。
typedef MediaCoverSegmentLoader =
    Future<Uint8List?> Function(String uri, int start, int end);

/// 生产实现：`DsmWebApi.getBytes` 只支持 `bytes=0-N` / `bytes=-N`
/// （`lib/src/dsm/**` 是禁区，本轮不动），所以这里退一步：
/// **读到 end（`Range: bytes=0-(end-1)`）再把 `[0,start)` 切掉**。
/// 允许这么做的根据是上限：只有 `end <= kMediaCoverRangeMaxBytes`（4MB）
/// 的区间才会走到这里（见 `_rangeLooksUsable`），所以白读的字节数也是封顶的。
final mediaCoverSegmentLoaderProvider = Provider<MediaCoverSegmentLoader>((
  ref,
) {
  final api = ref.watch(mediaCoverApiProvider);
  return (uri, start, end) async {
    if (api == null) return null;
    if (uri.isEmpty || start < 0 || end <= start) return null;
    if (end > kMediaCoverRangeMaxBytes) return null;
    final head = Uint8List.fromList(
      await api.getBytes(uri, maxBytes: end),
    );
    if (head.length < end) return null; // 服务端没给够 → 退图标，别喂半张图
    return Uint8List.sublistView(head, start, end);
  };
});

/// 取一个文件的内嵌封面；拿不到 → null（UI 退回图标/黑底）。
final mediaCoverProvider = FutureProvider.autoDispose
    .family<MediaCover?, MediaCoverKey>((ref, key) async {
      final cached = mediaCoverCacheGet(key.cacheKey);
      if (cached != null) return cached;
      if (key.uri.isEmpty || !key.rangeSupported) return null;
      final plan = mediaCoverRequestFor(
        kind: key.kind,
        extension: key.extension,
        fileSize: key.fileSize,
      );
      if (!plan.supported || plan.prefixBytes <= 0) return null;
      final api = ref.watch(mediaCoverApiProvider);
      if (api == null) return null;
      // ★ 失败记忆（`kMediaCoverNegativeTtl`，语义照 `video_frame_thumb.dart`）：
      //   **这个文件抓不出来** ⇒ TTL 内不再重发（列表重建不重撞）。
      //   放在能力/通道路径判定之后：`api == null`、`!rangeSupported`、
      //   `!plan.supported` 这些"这台机器/这条路做不了"走上面返回，
      //   **不进**失败表 ⇒ 行为逐字节不变（r132 的分野）。
      if (mediaCoverFailureRemembered(key.cacheKey)) return null;
      try {
        // 头段：`Range: bytes=0-<prefixBytes-1>`
        final prefix = Uint8List.fromList(
          await api.getBytes(key.uri, maxBytes: plan.prefixBytes),
        );
        // 尾段（只有 MP4/MKV 需要）：`Range: bytes=-<tailBytes>`
        // 没有文件大小时无法把尾段映射成绝对偏移 → 不取
        Uint8List? tail;
        if (plan.needsTail && key.fileSize > 0) {
          tail = Uint8List.fromList(
            await api.getBytes(key.uri, tailBytes: plan.tailBytes),
          );
        }
        final scan = scanMediaCover(
          MediaCoverBytes(prefix: prefix, tail: tail, fileSize: key.fileSize),
          key.kind,
          key.extension,
        );
        var cover = scan.cover;
        if (cover == null && scan.needsRange) {
          // 两段式：图片帧声明的长度超过预读 → 取**恰好这段**图片字节。
          // 只有这条路能拿到真机样本那种 2MB 的 APIC；小封面不会走到这里。
          final range = scan.range!;
          final segment = await ref.read(mediaCoverSegmentLoaderProvider)(
            key.uri,
            range.start,
            range.end,
          );
          if (segment != null) cover = finishMediaCoverRange(range, segment);
        }
        if (cover == null) {
          mediaCoverRememberFailure(key.cacheKey);
          return null;
        }
        mediaCoverCachePut(key.cacheKey, cover);
        mediaCoverForgetFailure(key.cacheKey);
        return cover;
      } catch (_) {
        // 拿不到就退图标/黑底，别在列表里抛红
        mediaCoverRememberFailure(key.cacheKey);
        return null;
      }
    }, retry: _noRetry);
