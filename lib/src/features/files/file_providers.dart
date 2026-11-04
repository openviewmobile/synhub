// 文件模块的依赖注入、状态与动作控制器。
//
// 分层（与聊天模块一致）：
//   DsmWebApi → FileStationApi（协议）→ FileStore（Drift 缓存）
//   → providers（本文件）→ 页面
//
// **local-first**：目录内容先出本地缓存（`folderCacheProvider`），网络刷新
// （`folderSyncProvider`）回来后再更新缓存，UI 通过同一个 watch 流自动刷新。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/media/thumb_cache.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import 'book_cover.dart';
import 'pdf_cover.dart';
import '../../core/settings/app_settings.dart' show cacheServiceProvider;
import '../../data/dto/file_entry_dto.dart';
import '../../data/dto/file_worm_dto.dart';
import '../../data/filestation_api.dart';
import '../../data/local/file_store.dart';
import '../../dsm/webapi.dart';
import '../chat/chat_session_controller.dart' show chatDatabaseProvider;
import '../servers/session_controller.dart';
import 'file_download_resume.dart';
import 'file_task_retry.dart';
import 'file_thumb.dart' show ThumbScale;

/// 文件模块的 API 层。未连接时为 null（页面显示"未连接"而不是崩）。
final fileApiProvider = Provider<FileStationApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : FileStationApi(conn.api);
});

/// 下载断点续传用的 Range 取数口（P0-b）。
///
/// 生产用 [DioRangeByteFetcher]（`getBytes` 只支持 `bytes=0-N` 且丢响应头，
/// 做不了续传）；测试用假实现覆盖，**不联网**。
///
/// ★★★ 第 302 轮真机修复：兜底那条**必须带会话 Dio**。老代码是裸的
/// `DioRangeByteFetcher()`，它会新建一个**默认 TLS** 的 `HttpClient` ⇒
/// 本 NAS 是 `https://<IP>:5001` + 自签证书（`CN=nas.example.com`），
/// 主机名与 IP 不匹配，真机逐字：
/// `CERTIFICATE_VERIFY_FAILED: IP address mismatch(handshake.cc:320)`。
/// 后果不止离线缓存 —— **「下载到本机」同样打不开**（同一条取数口）。
/// 会话 Dio（`DsmConnection.dio`，`DioFactory.create` 造）已经把
/// `badCertificateCallback` / `trustPolicy` 配好了，继承它即可。
final rangeByteFetcherProvider = Provider<RangeByteFetcher>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  final Object? transport = conn?.api.transport;
  if (transport is RangeByteFetcher) return transport;
  return DioRangeByteFetcher(dio: conn?.dio);
});

/// ★ 302：**离线文件缓存器** —— 把「加入离线文件」的登记真下到本机。
///
/// 与「下载到本机」**同一套引擎**（[FileDownloadResumer] + `Range` 续传 +
/// `.sydownload` 临时文件），只是落点是私有目录 `<Documents>/offline_cache/`、
/// 文件名带路径指纹（同名不同目录不打架）。URL 仍来自 FileStation 的
/// `downloadUrl([path])`。
///
/// 为什么需要它：在此之前 `OfflinePinEntry.localPath` **全仓没有生产者**
/// ⇒ 清单恒"未缓存"、`buildSafIndex()` 恒空（系统「文件」里看不到离线文件）、
/// 断网也打不开。见 `file_download_resume.dart` 末尾那一节。
final offlineCacherProvider = Provider<OfflineCacher>((ref) {
  return OfflineCacher(
    fetcher:
        ({required path, required name, required directory, onProgress}) async {
          final api = ref.read(fileApiProvider);
          if (api == null) {
            throw StateError('FileStation 未连接');
          }
          return FileDownloadResumer(
            fetcher: ref.read(rangeByteFetcherProvider),
            store: FileResumeStore(directory),
          ).download(
            sourcePath: path,
            url: api.downloadUrl([path]),
            fileName: OfflineCacher.fileNameFor(path: path, name: name),
            directory: directory,
            onProgress: onProgress,
          );
        },
  );
});

// ---------------------------------------------------------------- 缩略图（P0.1）

/// 缩略图缓存：限流 + 内存 LRU + 磁盘 + 负缓存（细节见 `ThumbCache`）。
///
/// 记号里带 `mtime/size`（[thumbKey]）→ 文件被覆盖后自动换图，不需要手动失效。
final thumbCacheProvider = Provider<ThumbCache>((ref) {
  final cache = ThumbCache(
    loader: (path, size) async {
      final fs = ref.read(fileApiProvider);
      if (fs == null) throw StateError('未连接');
      final bytes = await fs.api.getBytes(fs.thumbnailUrl(path, size: size));
      return Uint8List.fromList(bytes);
    },
    directory: () async => ref.read(cacheServiceProvider).fileThumbsDirectory(),
  );
  ref.onDispose(cache.clearMemory);
  return cache;
});

/// 一次缩略图请求的"身份"：路径 + 档位 + 服务端给的 mtime/size
class FileThumbRequest {
  const FileThumbRequest(this.path, this.scale, {this.mtime, this.bytes});

  factory FileThumbRequest.of(FileEntryDto e, ThumbScale scale) =>
      FileThumbRequest(e.path, scale, mtime: e.mtime, bytes: e.size);

  final String path;
  final ThumbScale scale;
  final int? mtime;
  final int? bytes;

  String get cacheKey =>
      thumbKey(path, size: scale.apiValue, mtime: mtime, bytes: bytes);

  @override
  bool operator ==(Object other) =>
      other is FileThumbRequest &&
      other.path == path &&
      other.scale == scale &&
      other.mtime == mtime &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(path, scale, mtime, bytes);
}

/// 取一个文件的缩略图；失败/不存在 → null（UI 退回分类图标）。
///
/// `autoDispose`：离开页面后不再占内存；图片本身在 [thumbCacheProvider] 里还留着。
final fileThumbProvider = FutureProvider.autoDispose
    .family<Uint8List?, FileThumbRequest>((ref, req) async {
      ref.keepAlive(); // 缓存层已经做了上限，这里别让"滚动出去"把请求也取消掉
      final cache = ref.watch(thumbCacheProvider);
      return cache.get(req.cacheKey, req.path, size: req.scale.apiValue);
    });

// ------------------------------------------------------------ 电子书封面
//
// **为什么要单独一层**：`SYNO.FileStation.Thumb` 只认图片/视频，对 `.epub`
// 回 404 + 一页 HTML（真机验证过），PDF 同样 404。想"NAS 文件列表里显示电子书
// 封面"就只能客户端自己出图：
//   * epub/cbz/fb2 → [bookCoverBytes] 从包里把封面抠出来（纯解析）；
//   * pdf          → `pdfx` 渲第一页（[PdfCoverRenderer]）。
// 两者都要**先把整本书下载下来**，所以有体积闸门（见 [kBookCoverMaxBytes]）。
//
// 缓存复用缩略图那套 [ThumbCache]：限流 + 内存 LRU + 磁盘 + 负缓存 + 合流，
// 于是"滚动时同一本书被要三次"只会下载一次，失败也不会反复重撞；
// 磁盘里存的是**抠出来的小封面**（几十 KB），不是整本书。

/// 超过这个体积就不去取封面：整本书要下到内存里才能解析（zip 中央目录在末尾，
/// 没法只下一个片段），一本 200MB 的画集为了列表里一张小图不值得。
/// 24MB 覆盖了绝大多数 epub/pdf，漫画/画集这类大文件继续用分类图标。
const int kBookCoverMaxBytes = 24 << 20;

/// 这个条目能不能出客户端封面（电子书 + PDF，且在体积闸门内）
bool showsBookCover(FileEntryDto e) {
  if (e.isDir) return false;
  // `size == 0` 表示列表没带 size（没请求 additional）—— 这时不设闸门，先试一次
  if (e.size > kBookCoverMaxBytes) return false;
  final ext = e.extension.toLowerCase();
  // 只有"真的能抠出封面"的格式才去下载整本书；本批新增的 TXT/RTF/DOCX/ODT…
  // 虽然也能在阅读器里读，但抠不出封面，所以不进这条路。
  return ext == 'pdf' || bookCoverSupported(ext);
}

/// 一次"要电子书封面"的请求身份：路径 + 后缀 + mtime/size（后两个用于失效）
class BookCoverRequest {
  const BookCoverRequest(this.path, this.extension, {this.mtime, this.bytes});

  factory BookCoverRequest.of(FileEntryDto e) =>
      BookCoverRequest(e.path, e.extension, mtime: e.mtime, bytes: e.size);

  final String path;

  /// 后缀（小写）—— 决定用"解析包"还是"渲第一页"
  final String extension;
  final int? mtime;
  final int? bytes;

  String get cacheKey =>
      'book|${thumbKey(path, size: extension.toLowerCase(), mtime: mtime, bytes: bytes)}';

  @override
  bool operator ==(Object other) =>
      other is BookCoverRequest &&
      other.path == path &&
      other.extension == extension &&
      other.mtime == mtime &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(path, extension, mtime, bytes);
}

/// 电子书封面缓存（与缩略图同一套管线，只是 loader 换成"下载 + 抠封面"）
final bookCoverCacheProvider = Provider<ThumbCache>((ref) {
  final cache = ThumbCache(
    loader: (path, size) async {
      final fs = ref.read(fileApiProvider);
      final url = fs?.downloadUrl([path]);
      if (fs == null || url == null) throw StateError('未连接');
      // 整本书的字节（`getBytes` 非 2xx 会抛 → 进负缓存）
      final bytes = Uint8List.fromList(await fs.api.getBytes(url));
      // `ThumbCache.loader` 只有 (path, size) 两个槽位，这里借 `size` 传后缀
      final ext = size.toLowerCase();
      if (ext == 'pdf') {
        final cover = await ref.read(pdfCoverRendererProvider)(bytes);
        if (cover == null) throw StateError('PDF 封面渲染失败');
        return cover;
      }
      final cover = bookCoverBytes(ext, bytes);
      if (cover == null) throw StateError('这本书里没有封面');
      return cover;
    },
    // 与缩略图共用 `file_thumbs/`：key 前缀是 `book|…`，不会撞
    directory: () async => ref.read(cacheServiceProvider).fileThumbsDirectory(),
  );
  ref.onDispose(cache.clearMemory);
  return cache;
});

/// 取一本书的封面；拿不到 → null（UI 退回分类图标）
final bookCoverProvider = FutureProvider.autoDispose
    .family<Uint8List?, BookCoverRequest>((ref, req) async {
      ref.keepAlive(); // 与缩略图同理：缓存层已经有上限，别让滚出屏幕取消请求
      return ref
          .watch(bookCoverCacheProvider)
          .get(req.cacheKey, req.path, size: req.extension.toLowerCase());
    }, retry: _noRetry);

/// 一次"取文件字节"请求：预览页用
class FileBytesRequest {
  const FileBytesRequest(this.path, {this.maxBytes, this.url});

  final String path;

  /// 只取开头这么多字节（文本预览；真机 `Range` 支持，回 206）
  final int? maxBytes;

  /// 现成的鉴权直链。为空时按 [path] 走 FileStation 的 `Download` ——
  /// Drive 源的文件不是 FileStation 路径，由它给出 `Files/download` 直链
  /// （两条链路都带 `_sid`，取字节的方式也就统一了）。
  final String? url;

  @override
  bool operator ==(Object other) =>
      other is FileBytesRequest &&
      other.path == path &&
      other.maxBytes == maxBytes &&
      other.url == url;

  @override
  int get hashCode => Object.hash(path, maxBytes, url);
}

/// 下载一个文件的字节（预览页的图片/文本都走它）。
///
/// 失败会抛（`getBytes` 现在对非 2xx **以及 200+JSON 错误信封**都会抛），
/// 所以 UI 能给出"打不开+原因"。
final fileBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, FileBytesRequest>((ref, req) async {
      final fs = ref.watch(fileApiProvider);
      final url = req.url ?? fs?.downloadUrl([req.path]);
      // 只有 FileStation 的 URL 时才需要 fs；Drive 的直链（`req.url`）只要有
      // 连接就能取字节 —— 测试里往往只覆盖 fileApiProvider，所以两种都认
      final api =
          fs?.api ?? ref.read(sessionControllerProvider).connection?.api;
      if (url == null || api == null) throw StateError('未连接');
      try {
        final bytes = await api.getBytes(url, maxBytes: req.maxBytes);
        return Uint8List.fromList(bytes);
      } on DsmApiException catch (e) {
        // FileStation 直链（`req.url == null`）才回填 file 服务；Drive 的现成
        // 直链（`req.url != null`）是 Drive 服务的账，别记到文件头上。
        if (req.url == null) {
          reportFileByteFailure(ref, 'SYNO.FileStation.Download', e);
        }
        rethrow;
      }
    }, retry: _noRetry); // 失败就报错，别指数退避重试（见 _noRetry 的说明）

/// 「取文件字节」通道（`getBytes` / `postBytesForm`）失败 → 回填统一服务状态。
///
/// 为什么要单独有它：二进制旁路**不在** `ServiceReportingApi` 的覆盖范围
/// （那里只包 `call`，见其文件头"边界"说明），所以 `200 + {"success":false,
/// "error":{"code":119}}` 以前既不提示、也没被 `classifyErrorCode` 归类（R6-4a）。
/// 这里按**既有**统一分类回填：
///   * 119/106 → `sessionExpired`（`hidesModule` 为 false ⇒ **绝不隐藏**）；
///   * 105/160 → `unauthorized`；102 → `absent`（Download/Thumb 是**可选**
///     API，`reportApiError` 会降级成 `partial`，不隐藏整个模块）；
///   * 其它码 → `unknown`（不动状态）；非 `DsmApiException`（网络）→ `unreachable`。
void reportFileByteFailure(Ref ref, String apiName, Object error) {
  ref
      .read(serviceAvailabilityProvider.notifier)
      .reportApiError(StationService.file, apiName, error);
}

/// 列表 / 网格（缩略图）两种浏览方式。与排序一样只活在本次会话里。
enum FileViewMode { list, grid }

final fileViewModeProvider =
    NotifierProvider<FileViewModeNotifier, FileViewMode>(
      FileViewModeNotifier.new,
    );

class FileViewModeNotifier extends Notifier<FileViewMode> {
  @override
  FileViewMode build() => FileViewMode.list;

  void set(FileViewMode mode) => state = mode;

  void toggle() => state = state == FileViewMode.list
      ? FileViewMode.grid
      : FileViewMode.list;
}

/// 目录缓存（与聊天共用一个 sqlite，不新开库）
final fileStoreProvider = Provider<FileStore>(
  (ref) => FileStore(ref.watch(chatDatabaseProvider)),
);

/// 根目录：普通用户从"共享文件夹"进（`List.list_share`）。
///
/// 官方 DS file 也是这么做的 —— 直接 `List.list(folder_path='/')` 对普通用户
/// 会 401（真机实测），所以根这一层必须走 `list_share`。
const String kFileRoot = '/';

/// 失败**不自动重试**：Riverpod 3 默认会对失败的 provider 做指数退避重试，
/// 在移动网络下这是"偷偷烧流量"，而且 UI 会一直停在带错误的 AsyncLoading
/// （错误页永远不出现）。文件模块一律关掉自动重试，改由用户点「重试」。
Duration? _noRetry(int retryCount, Object error) => null;

/// 目录内容（来自本地缓存，UI 直接 watch 它）
final folderCacheProvider = StreamProvider.family<List<FileEntryDto>, String>((
  ref,
  path,
) {
  return ref.watch(fileStoreProvider).watchFolder(path);
});

/// M51：个人文件夹（`/home`）固定入口。
///
/// 官方 DS file 的 home 就是 `List/list_share` 结果里的一条（
/// `docs/filestation-parity-audit.md` M51）；**已解析的根目录缓存**里就有它，
/// 直接复用 `folderCacheProvider(kFileRoot)`，**不再多发一次请求**。
/// 缓存里还没根目录（例如冷启动直接进收藏页）时返回 `null`，UI 回落成固定的
/// `/home` 条目 —— 真机证据表明普通用户 `List:list /home` 可读（同审计行
/// 的 `[L]`）。
final fileHomeEntryProvider = Provider<FileEntryDto?>((ref) {
  final cached = ref.watch(folderCacheProvider(kFileRoot)).value;
  if (cached == null) return null;
  for (final e in cached) {
    if (e.path == '/home' || e.name == 'home') return e;
  }
  return null;
});

/// 一页取多少条（M04 分页）。
///
/// 缺省沿用旧行为 `1000`（服务端 `List/list` 的常见上限）。做成 provider
/// 只是为了让离线测试能把页大小压到 2~5 条，不必在测试里造 1000+ 行 widget。
final filePageSizeProvider = Provider<int>((ref) => 1000);

/// 一次网络刷新（页面 mount / 下拉刷新时调用）—— **永远是第一页**。
///
/// 返回服务端版本号（`total`），UI 用它判断"是否还有更多"。
final folderSyncProvider = FutureProvider.family<FolderSyncResult, String>((
  ref,
  path,
) async {
  final api = ref.watch(fileApiProvider);
  if (api == null) {
    return const FolderSyncResult(offline: true);
  }

  // 排序是服务端参数 → **watch** 排序状态：用户改排序时这个 provider 自动失效，
  // 不需要页面手动 invalidate（少一处容易忘记的刷新）。
  final sort = ref.watch(fileSortProvider);
  final pageSize = ref.watch(filePageSizeProvider);

  final result = path == kFileRoot
      ? await api.listShares(
          offset: 0,
          limit: pageSize,
          sortBy: sort.sortBy,
          sortDirection: sort.sortDirection,
        )
      : await api.listFolder(
          folderPath: path,
          offset: 0,
          limit: pageSize,
          sortBy: sort.sortBy,
          sortDirection: sort.sortDirection,
        );

  // 空目录也要写（清掉过期缓存）
  await ref.read(fileStoreProvider).replaceFolder(path, result.entries);
  // M04：第一页落库后把分页游标归零重算（刷新 = 回到第 0 页）
  ref.read(folderPagingProvider(path).notifier).resetFrom(result);
  return FolderSyncResult(total: result.total, offset: result.offset);
}, retry: _noRetry);

/// 一个目录的**分页状态机**（M04）。
///
/// 三态：
///   * `loadingMore` —— 正在取下一页（底部转圈，滚动不再重复触发）；
///   * `hasMore` —— 服务端还有没取的条目（`loaded < total`）；
///   * `reachedEnd` —— 到底了（底部给"没有更多了"收尾，**不再发请求**）。
///
/// 游标用**服务端回包推进**（`loaded += entries.length`），不是本地缓存行数：
/// 缓存里可能有上一页/别的页留下的行，拿它当 offset 会跳页或死循环。
class FolderPagingState {
  const FolderPagingState({
    this.loadingMore = false,
    this.reachedEnd = false,
    this.total = 0,
    this.loaded = 0,
    this.error,
  });

  /// 正在取下一页
  final bool loadingMore;

  /// 已经到底（含"服务端 total 未知且第一页就取完"）
  final bool reachedEnd;

  /// 服务端报的条目总数（0 = 服务端没给，视为未知）
  final int total;

  /// 已经从服务端取回的条目数（= 下一页的 offset）
  final int loaded;

  /// 取下一页失败的原因；非空时**不自动重试**，由底部「重试」发起
  final Object? error;

  /// 还有下一页
  bool get hasMore => !reachedEnd && loaded < total;

  /// 现在可以发起下一页（滚动触底时用它做闸门）
  bool get canLoadMore => hasMore && !loadingMore && error == null;

  FolderPagingState copyWith({
    bool? loadingMore,
    bool? reachedEnd,
    int? total,
    int? loaded,
    Object? error,
    bool clearError = false,
  }) => FolderPagingState(
    loadingMore: loadingMore ?? this.loadingMore,
    reachedEnd: reachedEnd ?? this.reachedEnd,
    total: total ?? this.total,
    loaded: loaded ?? this.loaded,
    error: clearError ? null : (error ?? this.error),
  );
}

final folderPagingProvider =
    NotifierProvider.family<FolderPagingNotifier, FolderPagingState, String>(
      FolderPagingNotifier.new,
    );

class FolderPagingNotifier extends Notifier<FolderPagingState> {
  FolderPagingNotifier(this.path);

  /// 这个状态机管的是哪个目录
  final String path;

  @override
  FolderPagingState build() => const FolderPagingState();

  /// 第一页（首屏 / 下拉刷新 / 排序变化）回来后重置游标。
  ///
  /// `total <= 0` 时把 total 当成"已取回的数量"——老服务器不给 total 的话
  /// 就退化成旧行为（只此一页），不要凭空以为还有下一页。
  void resetFrom(FileListResult result) {
    final loaded = result.entries.length;
    final total = result.total > 0 ? result.total : loaded;
    state = FolderPagingState(
      total: total,
      loaded: loaded,
      reachedEnd: loaded >= total,
    );
  }

  /// 取下一页并**追加**进缓存（`upsertEntry` 按 path 冲突覆盖 = 去重合并）。
  ///
  /// 到底的判据（任一命中即收尾）：
  ///   * 服务端这一页是空的；
  ///   * 服务端 `total` 已知且 `loaded >= total`；
  ///   * 这一页没有 `hasMore`（`offset + entries.length >= total`）。
  Future<void> loadMore() async {
    final api = ref.read(fileApiProvider);
    if (api == null || !state.canLoadMore) return;
    final offset = state.loaded;
    state = state.copyWith(loadingMore: true, clearError: true);
    try {
      final sort = ref.read(fileSortProvider);
      final pageSize = ref.read(filePageSizeProvider);
      final result = path == kFileRoot
          ? await api.listShares(
              offset: offset,
              limit: pageSize,
              sortBy: sort.sortBy,
              sortDirection: sort.sortDirection,
            )
          : await api.listFolder(
              folderPath: path,
              offset: offset,
              limit: pageSize,
              sortBy: sort.sortBy,
              sortDirection: sort.sortDirection,
            );

      final store = ref.read(fileStoreProvider);
      final seen = <String>{};
      for (final entry in result.entries) {
        // 同页/跨页重复的 path 只落一次（服务端排序不稳定时可能出现）
        if (entry.path.isEmpty || !seen.add(entry.path)) continue;
        await store.upsertEntry(path, entry);
      }

      final loaded = offset + result.entries.length;
      final total = result.total > 0 ? result.total : state.total;
      final end = result.entries.isEmpty || loaded >= total || !result.hasMore;
      state = FolderPagingState(total: total, loaded: loaded, reachedEnd: end);
    } catch (e) {
      // 保留 hasMore，交给底部「重试」；不要在滚动里自动重撞
      state = state.copyWith(loadingMore: false, error: e);
    }
  }
}

/// 刷新结果
class FolderSyncResult {
  const FolderSyncResult({
    this.total = 0,
    this.offset = 0,
    this.offline = false,
  });
  final int total;
  final int offset;
  final bool offline;
}

/// 能力探测：这台 NAS 的文件服务支持哪些入口（按 API 表判断）。
///
/// 与聊天模块的 ACL 一样是 **fail-open**：API 表还没拉到时一律当"支持"，
/// 真正调用失败再降级（不把用户挡在门外）。
class FileCapabilities {
  const FileCapabilities({
    this.canBrowse = true,
    this.canSearch = true,
    this.canShare = true,
    this.canCompress = true,
    this.canExtract = true,
    this.canFavorite = true,
    this.canBackgroundTask = true,
    this.canVirtualFolder = true,
    this.canUploadRename = true,
    this.canDownload = true,
    this.canShareWithMe = true,
  });

  final bool canBrowse;
  final bool canSearch;
  final bool canShare;
  final bool canCompress;
  final bool canExtract;
  final bool canFavorite;
  final bool canBackgroundTask;
  final bool canVirtualFolder;

  /// 服务端是否提供 `SYNO.FileStation.Download`（下载直链）。
  ///
  /// 缺位时文件页**不显示**「下载任务」常驻入口（并就地给出原因），
  /// 与 `Mount` 的既有约定一致：不留会失败的入口。语义与其余能力位相同，
  /// API 表没拉到（未登录）时 **fail-open**（当作有）。
  final bool canDownload;

  /// 服务端 `Upload` 是否支持 `rename` 冲突策略（官方
  /// `isSupportUploadRename()` = `Upload.maxVersion >= 3`）。
  /// 不支持时冲突面板不提供"重命名"（那个入口必失败）。
  final bool canUploadRename;

  /// 服务端 `SYNO.FileStation.Sharing` 是否支持 **`list_share_me` v2**
  /// —— 「共享给我的」入口的能力位（wave3）。
  ///
  /// 为什么不能只看 API 在不在（[canShare]）：`list_share_me` 是 **v2 起**
  /// 才有的方法，真机逐版本扫描 v1 = **103**；`Sharing` 只到 v1 的服务器
  /// 上，「共享给我的」这个入口必失败，要**隐藏**（与 [canDownload] 同一
  /// 约定：不留会失败的入口）。
  ///
  /// 与其余能力位共用同一套机制（[probe] + 服务注册表），没有另起一套：
  /// API 表没拉到（未登录）时仍 **fail-open**（当作有），真正调用失败再降级。
  final bool canShareWithMe;

  /// 分享链接是**只读管理**（用户的决定：默认关闭新建入口），
  /// 所以这里只表示"能不能看已有链接"。
  ///
  /// ⚠️ 这是**唯一**接入统一服务注册表的地方（本批约定：files/** 只动这一处）：
  /// 各能力位的 API 名不再各写一遍，而是取自
  /// `kServiceRegistry[StationService.file]` 的同一份向量，避免两处漂移。
  /// 语义保持不变：API 表没拉到（未登录）时 **fail-open**（一律当"支持"）。
  static FileCapabilities probe(FileStationApi? api) {
    if (api == null) return const FileCapabilities();
    final table = api.api.apiTable;
    if (table == null) return const FileCapabilities();
    final spec = kServiceRegistry[StationService.file]!;
    final present = table.keys.toSet();
    bool has(String name) => spec.contains(name) && present.contains(name);
    final upload = table['SYNO.FileStation.Upload'];
    final sharing = table['SYNO.FileStation.Sharing'];
    return FileCapabilities(
      canBrowse: has('SYNO.FileStation.List'),
      canSearch: has('SYNO.FileStation.Search'),
      canShare: has('SYNO.FileStation.Sharing'),
      // `list_share_me` 只在 Sharing v2+（真机 v1 = 103）
      canShareWithMe:
          has('SYNO.FileStation.Sharing') &&
          (sharing == null || sharing.maxVersion >= 2),
      canCompress: has('SYNO.FileStation.Compress'),
      canExtract: has('SYNO.FileStation.Extract'),
      canFavorite: has('SYNO.FileStation.Favorite'),
      canBackgroundTask: has('SYNO.FileStation.BackgroundTask'),
      canVirtualFolder: has('SYNO.FileStation.VirtualFolder'),
      canDownload: has('SYNO.FileStation.Download'),
      canUploadRename: upload == null || upload.maxVersion >= 3,
    );
  }
}

/// 属性面板里"要额外问服务端"的几行：占盘大小 / 真实修改时间 / 所有者。
///
/// ⚠️ **Property.\* 必须用 `real_path`（`/volume1/...`），不能用 FileStation 的
/// 虚拟路径** —— 真机（DSM 7.4 / DS923+，FileStation 1.5.1-2410）实测：
/// `Property.CompressSize/Mtime` 传 `/home/l1.png` 直接 `401`，`ACLOwner` 回 `407`；
/// 换成 `real_path` 全部正常。官方 Web 端也是拿 `real_path` 去调的
/// （`FileProperty.js`：`params:{file:r[0].get("real_path")}`）。
///
/// 但**目录列表默认不带 `real_path`**（`FileAdditional.browse` 与官方
/// `getFiles` 调用点一致，不含这一项），所以这里在没有 real_path 时先用
/// `List/getinfo` 补一次 —— 代价是一次额外请求，换来"不改变浏览请求形状"。
///
/// 每一项都**单独 try**：普通用户看别人的目录时 `ACLOwner` 会 403/407，
/// 不能因为这一项失败就把整个属性面板变成错误页。
final fileExtraPropsProvider = FutureProvider.autoDispose
    .family<FileExtraProps, FilePropKey>((ref, key) async {
      final api = ref.watch(fileApiProvider);
      if (api == null) return const FileExtraProps();

      // 先定出真实路径：列表里有就用，没有就 getinfo 补一次
      var real = key.realPath ?? '';
      if (real.isEmpty) {
        try {
          real = (await api.getInfo(key.path)).realPath ?? '';
        } catch (_) {}
      }
      final target = real.isNotEmpty ? real : key.path;

      int? diskSize;
      int? mtime;
      FileAclOwnerDto? owner;
      String? ownerError;
      try {
        diskSize = await api.compressSize(target);
      } catch (_) {}
      try {
        mtime = await api.mtimeOf(target);
      } catch (_) {}
      try {
        owner = await api.aclOwner(target);
      } catch (err) {
        // 403/407 = 没权限看/改所有者（普通用户常态），单独记下来给 UI 说清楚
        ownerError = describeFileError(err);
      }
      return FileExtraProps(
        realPath: real,
        diskSize: diskSize,
        mtime: mtime,
        owner: owner,
        ownerError: ownerError,
      );
    }, retry: _noRetry);

/// 属性面板要问服务端的东西用 (虚拟路径, 列表里带的 real_path) 做 key：
/// 记录类型有值相等语义，同一个文件不会重复请求。
typedef FilePropKey = ({String path, String? realPath});

/// `Property.CompressSize / Mtime / ACLOwner` 三项的合并结果
class FileExtraProps {
  const FileExtraProps({
    this.realPath = '',
    this.diskSize,
    this.mtime,
    this.owner,
    this.ownerError,
  });

  /// 这次实际用的真实路径（列表没带时是 `getinfo` 补的；空串 = 没拿到）
  final String realPath;

  final int? diskSize;
  final int? mtime;
  final FileAclOwnerDto? owner;

  /// 拿不到所有者时的原因（多半是"没有权限"）
  final String? ownerError;
}

/// 属性面板的 WriteOnce / WORM 信息（`SYNO.FileStation.Worm` v1，**只读**）。
///
/// 两个来源：
///   * [share] —— `get_share_info`（共享级：模式 + 自动锁定是否启用）；
///   * [pathStatus] —— `Worm:get`（逐路径：锁定状态 / 锁定与到期时间）。
class FileWormInfo {
  const FileWormInfo({this.share, this.pathStatus});

  final FileWormShareInfo? share;
  final FileWormPathStatus? pathStatus;

  /// 自动锁定是否启用。**拿不到共享配置时按"未启用"**（真机常态：没有 WORM
  /// 的共享回的也是 1500/内层 0，而不是成功 data）。
  bool get autoLockEnabled => share?.autoLockEnabled ?? false;
}

/// 喂给属性面板的 WriteOnce 数据；`null` = **整块隐藏**。
///
/// 门控（规程 §4.5「缺失→隐藏，且不发探测」）：
/// `SYNO.FileStation.Worm` 不在 `SYNO.API.Info` 里 ⇒ 返回 null，面板不出现，
/// 也不发任何请求。API 表还没拉到（未登录）时 [FileStationApi.hasApi] 是
/// fail-open（返回 true），照常探测，调用失败再降级。
///
/// 两个接口**各自独立 try**：任一个失败都**不**把属性面板变成错误页
/// —— 这台真机上"没有 WORM"本来就是按 1500 + 内层 code=0 回的常态。
///
/// ⚠️ **绝不把服务端的失败渲染成"未启用"**：`Worm:get` 的内层 400/408
/// 会被 [FileStationApi.wormGet] 抛出，这里吞掉后只表示"拿不到逐路径状态"，
/// 而"未启用"这个结论**只**来自 [FileWormShareInfo.autoLockEnabled] 的官方判定
/// （`def_lock_mode ∈ {Immutable, Appendable}`），不靠"出错"推断。
final fileWormInfoProvider = FutureProvider.autoDispose
    .family<FileWormInfo?, String>((ref, path) async {
      final api = ref.watch(fileApiProvider);
      if (api == null) return null;
      if (!api.hasApi('SYNO.FileStation.Worm')) return null;
      FileWormShareInfo? share;
      FileWormPathStatus? pathStatus;
      try {
        share = await api.wormShareInfo(path);
      } catch (_) {
        share = null;
      }
      try {
        pathStatus = await api.wormGet(path);
      } catch (_) {
        pathStatus = null;
      }
      return FileWormInfo(share: share, pathStatus: pathStatus);
    }, retry: _noRetry);

final fileCapabilitiesProvider = Provider<FileCapabilities>(
  (ref) => FileCapabilities.probe(ref.watch(fileApiProvider)),
);

/// 图片的 EXIF / IPTC / XMP 元数据（`SYNO.FileStation.ThumbInfo / get`，**只读**）。
///
/// 真机只读实测（`docs/device-readonly-verification-evidence-r16.md` §12）：
/// `{path:"/home"}` → `{"exif":null,"iptc":null,"xmp":null}` —— 参数字面量已取证；
/// **非 null 的内部结构没有样本**，解析按 JSON 类型宽松降级（见 [FileThumbInfoDto]）。
///
/// ## 门控与"空态 ≠ 失败"（规程 §4.5）
///   * `SYNO.FileStation.ThumbInfo` **不在能力表** → 返回 `null`：
///     属性面板整块不出现，**且一个请求都不发**；
///   * 未连接 / 请求失败 → 返回 `null`：面板不出现（属性面板不该被元数据拖垮），
///     **不会**因此显示成"没有元数据"；
///   * 服务端**成功**回了三个 `null` → 返回 `isEmpty == true` 的 DTO：
///     界面**明说**"该文件不含 EXIF / IPTC / XMP 元数据"。
///
/// ⇒ `null`（不显示）与 `isEmpty`（如实说没有）是**两条不同的路**，
/// 绝不把失败伪装成空态。
final fileThumbInfoProvider = FutureProvider.autoDispose
    .family<FileThumbInfoDto?, String>((ref, path) async {
      final api = ref.watch(fileApiProvider);
      if (api == null) return null;
      if (!api.canThumbInfo) return null;
      try {
        return await api.thumbInfo(path);
      } catch (_) {
        return null;
      }
    }, retry: _noRetry);

/// 当前用户是不是 File Station 管理员（`Info.get` 的 `is_manager`）。
///
/// 只用于门控「清空回收站」：`SYNO.Core.RecycleBin` 在注册表里 `allowUser`
/// 仅 `admin.*`（见 `filestation_api.dart` 的 [FileStationApi.purgeRecycleBin]）。
/// 取不到（离线/失败）时按 **false** 处理 —— 宁可不给入口，也不给一个必失败的入口。
final fileIsManagerProvider = FutureProvider.autoDispose<bool>((ref) async {
  final api = ref.watch(fileApiProvider);
  if (api == null) return false;
  try {
    return await api.isManager();
  } catch (_) {
    return false;
  }
}, retry: _noRetry);

/// 官方 `Utils.findUsableFilePathInSet` 的纯函数版：
/// 在 [existing] 里找一个不冲突的文件名。
///
/// ⚠️ 官方用 `'-' + index`（`Utils.getIndexedFileName` 拼 `name + '-' + i + ext`），
/// **不是** `name (1).ext`。`a.txt` 冲突 → `a-1.txt`；`a` → `a-1`。
String indexedFileName(String name, Set<String> existing) {
  final dot = name.lastIndexOf('.');
  // 与官方一致：`.` 在开头（隐藏文件）或不存在时，整名当主名
  final hasExt = dot > 0 && dot < name.length - 1;
  final base = hasExt ? name.substring(0, dot) : name;
  final ext = hasExt ? name.substring(dot) : '';
  var candidate = name;
  var i = 1;
  while (existing.contains(candidate)) {
    candidate = '$base-$i$ext';
    i++;
  }
  return candidate;
}

// ---------------------------------------------------------------- 排序

/// 目录排序（界面偏好，默认目录在前 + 名称升序；这里的键影响服务端请求）
final fileSortProvider = NotifierProvider<FileSortNotifier, FileSortState>(
  FileSortNotifier.new,
);

class FileSortState {
  const FileSortState({
    this.sortBy = FileSortBy.name,
    this.sortDirection = FileSortDirection.asc,
  });

  final FileSortBy sortBy;
  final FileSortDirection sortDirection;

  FileSortState copyWith({
    FileSortBy? sortBy,
    FileSortDirection? sortDirection,
  }) => FileSortState(
    sortBy: sortBy ?? this.sortBy,
    sortDirection: sortDirection ?? this.sortDirection,
  );
}

class FileSortNotifier extends Notifier<FileSortState> {
  @override
  FileSortState build() => const FileSortState();

  void setSortBy(FileSortBy by) {
    // 再点一次同一个键 → 切换升降序（与 DSM 网页一致）
    if (state.sortBy == by) {
      state = state.copyWith(
        sortDirection: state.sortDirection == FileSortDirection.asc
            ? FileSortDirection.desc
            : FileSortDirection.asc,
      );
      return;
    }
    state = FileSortState(sortBy: by, sortDirection: FileSortDirection.asc);
  }
}

// ---------------------------------------------------------------- 浏览栈

/// 文件 Tab 内部的浏览栈（第一个元素永远是根 `/`）。
///
/// 为什么不用 go_router 的路径参数：目录路径本身含 `/`，塞进路由既难读又容易
/// 被转义搞坏；而且文件 Tab 是外壳里的一个 tab，返回键应该只退目录、不该退 tab。
final fileBrowseStackProvider =
    NotifierProvider<FileBrowseStackNotifier, List<String>>(
      FileBrowseStackNotifier.new,
    );

class FileBrowseStackNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [kFileRoot];

  String get current => state.isEmpty ? kFileRoot : state.last;

  /// 进入子目录
  void open(String path) {
    if (path == current) return;
    state = [...state, path];
  }

  /// 返回上一级（到根就不再退）
  void up() {
    if (state.length <= 1) return;
    state = state.sublist(0, state.length - 1);
  }

  /// 点面包屑的第 [index] 段
  void jumpTo(int index) {
    if (index < 0 || index >= state.length) return;
    state = state.sublist(0, index + 1);
  }

  /// 直接跳到某个路径（从收藏 / 搜索结果进来时用）。
  ///
  /// 栈要按路径逐级补全（`/home/a/b` → `[根, /home, /home/a, /home/a/b]`），
  /// 否则面包屑会缺层、点不回去。
  void openPath(String path) {
    if (path.isEmpty || path == kFileRoot) {
      reset();
      return;
    }
    final built = <String>[kFileRoot];
    var acc = '';
    for (final seg in path.split('/').where((s) => s.isNotEmpty)) {
      acc = '$acc/$seg';
      built.add(acc);
    }
    state = built;
  }

  void reset() => state = const [kFileRoot];
}

// ---------------------------------------------------------------- 任务

/// 后台任务（统一任务中心的文件部分）
final fileTasksProvider = FutureProvider.autoDispose<List<FileTaskDto>>((
  ref,
) async {
  final api = ref.watch(fileApiProvider);
  if (api == null) return const [];
  final result = await api.listBackgroundTasks();
  // **长任务保活**：还有没跑完的任务时，顺手 `Timeout/avoid` 续一次会话。
  // NAS 空闲超时 15 分钟，而压缩/解压/MD5 能跑十几分钟 —— 不续的话用户
  // 回来看到的不是进度，是"会话已失效"。
  //
  // 刻意 **fire-and-forget**：保活失败绝不能影响任务列表本身（保活是
  // 尽力而为，读任务才是这个 provider 的职责）。
  if (result.tasks.any((t) => !t.finished)) {
    unawaited(
      api.avoidTimeout().catchError((Object _) {
        // 保活失败静默：会话真过期了，随后的正式请求自然会暴露 119。
      }),
    );
  }
  return result.tasks;
}, retry: _noRetry);

/// 收藏夹里的路径集合（用于在行菜单里区分"加入/取消收藏"）
final fileFavoritesProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  final api = ref.watch(fileApiProvider);
  if (api == null) return const [];
  final result = await api.listFavorites(limit: 1000);
  return result.entries.map((e) => e.path).toList();
}, retry: _noRetry);

/// 本地排序 —— 缓存里的顺序要跟用户选的排序一致。
///
/// 为什么不能只靠服务端排序：目录内容是从 Drift 缓存读出来的（local-first），
/// 缓存里的行序是插入序；服务端排好序的结果一进缓存就"丢序"了。
/// 目录永远排在最前面（与 DSM 一致），其余按所选字段比。
List<FileEntryDto> sortFileEntries(
  List<FileEntryDto> rows,
  FileSortState sort,
) {
  int compare(FileEntryDto a, FileEntryDto b) {
    switch (sort.sortBy) {
      case FileSortBy.name:
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case FileSortBy.size:
        return a.size.compareTo(b.size);
      case FileSortBy.mtime:
        return a.mtime.compareTo(b.mtime);
      case FileSortBy.crtime:
        return a.crtime.compareTo(b.crtime);
      case FileSortBy.type:
        return a.extension.compareTo(b.extension);
      case FileSortBy.user:
        return (a.owner ?? '').compareTo(b.owner ?? '');
      case FileSortBy.group:
        return (a.group ?? '').compareTo(b.group ?? '');
    }
  }

  final sorted = [...rows];
  sorted.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1; // 目录永远在前
    final c = compare(a, b);
    final result = c != 0 ? c : a.name.compareTo(b.name);
    return sort.sortDirection == FileSortDirection.asc ? result : -result;
  });
  return sorted;
}

/// 压缩包解出后**客户端自己**要建/要当目标的那一级目录名
/// （`/a/b/r300wt.zip` → `r300wt`）。逐字对齐官方
/// `SYNO.webfm.utils.getZipName`（FileStation 1.5.1-2410 的
/// `ui/file_browser/FileBrowserUtil.js`）：
///
/// ```js
/// getZipName = function (e) {            // e = 文件名
///   var t = e.lastIndexOf(".");
///   e = e.substr(0, t);                  // ① 去掉最后一个 `.扩展名`
///   t = e.lastIndexOf(".");
///   if (e.substr(t + 1).toLowerCase() == "tar") e = e.substr(0, t);  // ② `.tar.gz` 再去一层
///   return e;
/// }
/// ```
///
/// ⇒ `a.zip`→`a`；`a.tar.gz`→`a`；`a.tar.bz2`→`a`；`a.txt.bz2`→`a.txt`；
/// 无扩展名 / 隐藏文件（`.zip`）⇒ null（官方对这俩会得到空串/怪异名，宁可不猜）。
///
/// ★ 第 303 轮修正：此前这里只去掉**一层**扩展名、且**只用于刷缓存**；
/// 真正的 `dest_folder_path` 一直发父目录 ⇒ 解压产物落回当前目录、与既有
/// 文件同名时被静默跳过（真机见 `docs/device-verification.md` 第 303 轮）。
String? fileArchiveSubfolderName(String filePath) {
  final slash = filePath.lastIndexOf('/');
  final base = slash < 0 ? filePath : filePath.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  if (dot <= 0) return null; // `.zip`（隐藏文件）/ 无扩展名
  var name = base.substring(0, dot);
  final dot2 = name.lastIndexOf('.');
  if (dot2 > 0 && name.substring(dot2 + 1).toLowerCase() == 'tar') {
    name = name.substring(0, dot2);
  }
  return name;
}

// ---------------------------------------------------------------- 动作

/// 文件动作控制器（无状态、只做动作；错误交给 UI 用 [describeFileError] 展示）
final fileActionsProvider = Provider<FileActionsController>(
  (ref) => FileActionsController(ref),
);

class FileActionsController {
  FileActionsController(this.ref);

  final Ref ref;

  FileStationApi get _api {
    final api = ref.read(fileApiProvider);
    if (api == null) {
      throw DsmApiException(
        DsmErrorCode.apiNotFound,
        method: 'FileStation（未连接）',
      );
    }
    return api;
  }

  FileStore get _store => ref.read(fileStoreProvider);

  /// 当前目录（刷新后重建缓存）
  Future<void> _refresh(String folderPath) async {
    // ⚠️ **必须先 `invalidate`**：`folderSyncProvider` 是非 autoDispose 的
    // `FutureProvider.family`，一旦解析过一次，`ref.read(...future)` 只会拿
    // **缓存结果**、根本不会再发请求。以前漏了这一步 —— R6 真机观察到
    // "上传成功后 snackbar 报「已上传 …」但列表看不到新文件、冷启动才出现、
    // 期间 sqlite mtime 也不动"（docs/device-verification.md R6 §9.1）。
    // 同一个坑对 createFolder / delete / copyMove / extract 一样成立。
    ref.invalidate(folderSyncProvider(folderPath));
    await ref.read(folderSyncProvider(folderPath).future);
  }

  /// 取路径的父目录（**词法** dirname，不解析 symlink）。
  ///
  /// `/home/a/b.zip` → `/home/a`；`/a` → `/`；`/`（或相对路径）→ `null`。
  /// 与 `lib/src/core/file_provider_paths.dart` 的 `canonicalizePath` 同一族语义，
  /// 这里只要 dirname 这一件事。
  static String? _parentDirOf(String path) {
    final slash = path.lastIndexOf('/');
    if (slash < 0) return null; // 相对路径没有"父目录"，宁可不动
    if (slash == 0) return path.length > 1 ? '/' : null;
    return path.substring(0, slash);
  }

  /// 词法拼路径（不解析 symlink），保证只有一个斜杠。
  static String _joinPath(String dir, String name) {
    if (dir.isEmpty) return name;
    if (dir == '/') return '/$name';
    return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  }

  /// 新建文件夹
  Future<void> createFolder({
    required String folderPath,
    required String name,
  }) async {
    await _api.createFolder(folderPath: folderPath, name: name);
    await _refresh(folderPath);
  }

  /// 重命名（本地缓存同步改名，避免刷新前显示旧名）
  Future<void> rename({required String path, required String name}) async {
    await _api.rename(path: path, name: name);
    await _store.renameEntry(path, name);
  }

  /// 删除到回收站（支持多选）。
  ///
  /// P0-a 起走 `Delete.start`（官方 DS file 唯一用法，异步任务 + 进回收站），
  /// 不再是原来的同步 `Delete.delete`。任务号已进任务中心，本方法只关心
  /// 本地缓存与刷新。
  Future<void> delete(List<String> paths) async {
    if (paths.isEmpty) return;
    await _api.deleteItems(paths);
    await _store.removeEntries(paths);
    // 删完把所在的父目录刷一次（目录大小等会变）
    final parents = paths
        .map((p) => p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : '/')
        .toSet();
    for (final parent in parents) {
      final path = parent.isEmpty ? kFileRoot : parent;
      try {
        await _refresh(path);
      } catch (_) {
        // 父目录可能已经不在（删的就是它自己），忽略
      }
    }
    ref.invalidate(fileTasksProvider);
  }

  /// 永久删除（**只用于 `#recycle` 里的条目**）—— 同步、不可恢复。
  Future<void> deleteForever(List<String> paths) async {
    if (paths.isEmpty) return;
    await _api.deletePermanently(paths);
    await _store.removeEntries(paths);
    for (final parent in _parentsOf(paths)) {
      try {
        await _refresh(parent);
      } catch (_) {
        // 同上
      }
    }
  }

  /// 从回收站还原到原位置（`CopyMove.start` + `restore_from_recycle_bin`）。
  ///
  /// 目标目录按官方 `RecycleBin.js` 的规则算：去掉 `#recycle` 这一段。
  /// 还原后源（回收站目录）与目标目录都刷新一次。
  ///
  /// [overwrite] 必须由调用方根据 [recycleRestoreConflicts] 的探测结果 + 用户
  /// 选择给出（**不再硬编码** false —— 官方 `RecycleBin.js` 的
  /// `PasteConfirmDialog` 回调就是把用户选的布尔值传给 `doRestore(…, r, …)`）。
  Future<List<String>> restoreFromRecycle(
    List<String> paths, {
    required bool overwrite,
  }) async {
    if (paths.isEmpty) return const [];
    final dest = RecyclePath.restoreDest(paths.first);
    final start = await _api.restoreFromRecycleBin(
      paths: paths,
      destFolderPath: dest,
      overwrite: overwrite,
    );
    await _store.removeEntries(paths);
    final roots = <String>{..._parentsOf(paths), if (dest.isNotEmpty) dest};
    for (final root in roots) {
      try {
        await _refresh(root);
      } catch (_) {
        // 目标目录可能还没建出来 / 源已空，忽略
      }
    }
    ref.invalidate(fileTasksProvider);
    return start.taskIds;
  }

  /// 还原前探测"目标位置同名冲突"（P0-b）。
  ///
  /// 官方证据：服务端官方前端 `ui/file_browser/RecycleBin.js` 的
  /// `launchFn` —— 未开启 `enableautooverwrite` 时先弹 `PasteConfirmDialog`
  /// （`filenames: getFilenames(选中项)`），把用户选择作为 `overwrite` 传给
  /// `doRestore`。**FileStation 没有 `dry_run` 参数**（那是 `SYNO.SynologyDrive.Node`
  /// 的能力，且 `CopyMove.so` 的参数字符串里没有它），所以探测在客户端做：
  /// 对每个条目的还原目标路径调 `CheckExist/check`。
  ///
  /// 返回冲突的**文件名**列表；探测失败（离线/无权限）时把该项当"不冲突"
  /// （调用方仍以 `overwrite=false` 保守提交，服务端自会跳过同名项）。
  Future<List<String>> recycleRestoreConflicts(List<String> paths) async {
    if (paths.isEmpty) return const [];
    final dest = RecyclePath.restoreDest(paths.first);
    if (dest.isEmpty) return const [];
    final base = dest.endsWith('/') ? dest.substring(0, dest.length - 1) : dest;
    final conflicts = <String>[];
    for (final path in paths) {
      final name = path.split('/').last;
      if (name.isEmpty) continue;
      try {
        if (await _api.exists('$base/$name')) conflicts.add(name);
      } catch (_) {
        // 探测失败 → 不当作冲突
      }
    }
    return conflicts;
  }

  /// 清空某个共享文件夹的回收站（**不可恢复**，需要管理员）。
  Future<void> purgeRecycleBin(String shareName) async {
    await _api.purgeRecycleBin(shareName);
    try {
      await _refresh('/$shareName/${RecyclePath.segment}');
    } catch (_) {
      // 清空后目录可能已不存在，忽略
    }
  }

  /// 上传前冲突检测：目标目录里有没有同名条目（官方 `hasCommonFilename`）。
  ///
  /// 只看目录列表里的**文件名**，不比对大小/时间（与官方一致）；检测失败
  /// （离线/无权限）时返回 `null` 表示"未知"，调用方据此采取安全策略。
  Future<bool?> uploadConflictExists({
    required String folderPath,
    required String fileName,
  }) async {
    try {
      final result = await _api.listFolder(
        folderPath: folderPath,
        limit: 1000,
        additional: FileAdditional.light,
      );
      return result.entries.any((e) => e.name == fileName);
    } catch (_) {
      return null;
    }
  }

  /// 重命名冲突建议：按官方 `Utils.findUsableFilePathInSet` 生成
  /// `name-1.ext` / `name-2.ext` …（**注意官方用的是 `-N`，不是 ` (N)`**）。
  Future<String> suggestUploadName({
    required String folderPath,
    required String fileName,
  }) async {
    Set<String> existing;
    try {
      final result = await _api.listFolder(
        folderPath: folderPath,
        limit: 1000,
        additional: FileAdditional.light,
      );
      existing = result.entries.map((e) => e.name).toSet();
    } catch (_) {
      existing = const {};
    }
    return indexedFileName(fileName, existing);
  }

  List<String> _parentsOf(List<String> paths) => paths
      .map((p) => p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : '/')
      .map((p) => p.isEmpty ? kFileRoot : p)
      .toSet()
      .toList();

  /// 复制 / 移动（返回任务号，交给任务中心看进度）
  Future<List<String>> copyMove({
    required List<String> paths,
    required String destFolderPath,
    required bool move,
  }) async {
    final start = await _api.startCopyMove(
      paths: paths,
      destFolderPath: destFolderPath,
      removeSrc: move,
    );
    await _refresh(destFolderPath);
    // ⚠️ **移动必须连"源目录"一起刷新**：只刷 `destFolderPath`，源目录会一直留着
    //    已经被搬走的行。第 298 轮真机实测：移动完成后 `_r298_dst` 仍列着
    //    `r298_renamed.png`（而任务中心已「移动 | 完成」、源目录里也确实有了它）——
    //    当时误记成"跨目录任务不自动刷新"，根因就是这里少刷一半。
    if (move) {
      for (final dir in paths.map(_parentDirOf).whereType<String>().toSet()) {
        if (dir != destFolderPath) await _refresh(dir);
      }
    }
    ref.invalidate(fileTasksProvider);
    return start.taskIds;
  }

  /// 压缩（`destFilePath` 是**完整目标文件**，如 `/home/a.zip`）
  ///
  /// [format] / [level] 是 P1-4 新增：`zip`/`7z` 与
  /// `store`/`fastest`/**`normal`**/`best` —— 线上值以官方 APK 的
  /// `archive_compress_level_key` 为准（服务端 `.so` 里中间档 `-mx6` 无名字）。
  /// 详见 `file_sheets.dart` 的 `CompressLevel` 裁决说明。
  /// [mode] 是 wave2 M21 新增：`add`/`update`/`freshen`/`synchronize`
  /// （取值照 `docs/api-server-authoritative.md:1194-1204` 的官方表）。
  Future<List<String>> compress({
    required List<String> paths,
    required String destFilePath,
    String format = 'zip',
    String level = 'normal',
    String mode = 'replace',
    String? password,
  }) async {
    final start = await _api.startCompress(
      paths: paths,
      destFilePath: destFilePath,
      format: format,
      level: level,
      mode: mode,
      password: password,
    );
    // ⚠️ **必须刷新 `destFilePath` 的父目录**（压缩包落在那里）。
    //
    // 第 299 轮真机实测（HUAWEI TET-AN00 + 真 NAS）：压缩任务在任务中心显示
    // 「压缩 | 完成」、`SYNO.Finder` 也能搜到 `r298_end.zip`（2.0 MB），
    // 但**文件列表里一直没有它** —— 离开目录再进来也没有（`folderSyncProvider`
    // 是非 autoDispose 的 `FutureProvider.family`，重进拿到的是缓存），
    // 下拉手势也不刷，**只有 FAB →「刷新」才出现**。
    // 同一条铁律：`compress` 当初被漏在 `_refresh` 的注释清单之外。
    final destDir = _parentDirOf(destFilePath);
    if (destDir != null) await _refresh(destDir);
    ref.invalidate(fileTasksProvider);
    return start.taskIds;
  }

  /// 解压（**解到当前目录下的同名文件夹** —— 目标路径由客户端算）
  ///
  /// [destFolderPath] 是**用户所在目录**（父目录），不是最终目标：真正的
  /// `dest_folder_path` 是 `<destFolderPath>/<getZipName(包名)>`。
  ///
  /// [codepage] 是 P1-5 新增：老压缩包文件名乱码时指定
  /// （官方 `ExtractFragment.java:82` 的语言下拉 → `Extract/start` 的
  /// `codepage`；取值 `utf8`/`chs`/`cht`/`enu`…）。
  ///
  /// ## ★★ 第 303 轮真机修复：目标路径必须**客户端自己算**（服务端不会替你建）
  ///
  /// 权威来源 = FileStation 1.5.1-2410 SPK 的官方 Web 前端
  /// `ui/file_browser/FileBrowser.js` 的 `ExtractNoDialog(e, t)` **逐字**：
  ///
  /// ```js
  /// i = r = file_id.substr(0, file_id.lastIndexOf("/"));        // r = 父目录
  /// t && (r += "/" + SYNO.webfm.utils.getZipName(filename), …); // r = 父目录/包名（t = 要同名子目录）
  /// const m = {overwrite:false, file_path:h[0], dest_folder_path: c.length?c[0]:r,
  ///            keep_dir:true, create_subfolder:t, codepage: await getCodePage()};
  /// requestAPI("SYNO.FileStation.Extract","start","2",m, …);
  /// ```
  ///
  /// 即：**「解压到同名文件夹」= 客户端把 `dest_folder_path` 直接算成那个子目录**，
  /// `create_subfolder: true` 只是让服务端**把这个还不存在的目标目录建出来**
  /// （所以官方从不发"父目录 + create_subfolder:true"这种组合）。
  ///
  /// 我们此前发的正是那个组合（`destFolderPath: dir`）⇒ 服务端发现目标目录
  /// **已存在**（就是当前目录），于是**什么都不建**，解压产物落回当前目录；
  /// 一旦与既有文件同名（`overwrite: false`）就**静默跳过**。真机实测
  /// （HUAWEI TET-AN00 + DSM 7.4.1-90080，`/home/r303wt`）：
  ///
  /// * 解压 `/home/r303wt/r303secret.zip` → 任务中心「解压 | 完成」、
  ///   详情「任务错误：没有错误」，但 `/home/r303wt` **始终只有那 3 个文件**；
  /// * 独立判据（**服务端冲突测试**）：手工新建 `/home/r303wt/r303secret`
  ///   **成功** ⇒ 服务端确实从未建过这个目录（若解压真产出过，重名会失败）；
  /// * 用 `codepage` / `password` 各种组合重试均同上 ⇒ 与加密、编码无关，
  ///   就是**目标路径错了**。
  ///
  /// ⚠️ 第 300 轮写的"`createSubfolder: true` 下服务端真正写入的是 destFolderPath
  /// 下的同名子目录"是**错的**（当时只看到"父目录 mtime 变了 + 同名目录内容旧"，
  /// 而那个同名目录其实是包里自带的顶层目录）。详见 `docs/device-verification.md`
  /// 第 303 轮。
  /// `SYNO.FileStation.Extract / list` —— **只看**压缩包里有什么，不解压。
  ///
  /// 只读、不改服务端状态，所以**不刷新任何目录**（与 `extract` 的区别）。
  /// 加密包需要 `password`；老包的乱码文件名要 `codepage` 才能读对。
  Future<FileListResult> listArchive({
    required String filePath,
    String? password,
    String? codepage,
  }) {
    return _api.listArchive(
      filePath: filePath,
      password: password,
      codepage: codepage,
    );
  }

  Future<List<String>> extract({
    required String filePath,
    required String destFolderPath,
    String? password,
    String? codepage,
  }) async {
    final sub = fileArchiveSubfolderName(filePath);
    // 无名可算（无扩展名/隐藏文件）⇒ 退回"就地解压"，不猜目录名。
    final target = (sub == null || sub.isEmpty)
        ? destFolderPath
        : _joinPath(destFolderPath, sub);
    final start = await _api.startExtract(
      filePath: filePath,
      destFolderPath: target,
      password: password,
      codepage: codepage,
      createSubfolder: true,
    );
    // 父目录要立刻刷新：那个**新建出来的同名子目录**得出现在用户眼前。
    // （第 299/300 轮反复踩的坑：`folderSyncProvider` 是非 autoDispose 的
    // `FutureProvider.family`，不 `_refresh` 就一直是旧缓存，下拉手势也不刷。）
    await _refresh(destFolderPath);
    if (target != destFolderPath) {
      // 目标目录本身也要作废：用户点进去时重新拉一次，才能看到包里的内容。
      // 只 `invalidate` 不 await（重名时服务端可能加成 `<名字> (1)`，刷不到正常）。
      ref.invalidate(folderSyncProvider(target));
    }
    ref.invalidate(fileTasksProvider);
    return start.taskIds;
  }

  /// 收藏 / 取消收藏
  Future<void> setFavorite(String path, {required bool favorite}) async {
    if (favorite) {
      await _api.addFavorite(path);
    } else {
      await _api.deleteFavorite(path);
    }
  }

  /// P1-7：改收藏显示名（`Favorite/edit`），然后刷新收藏列表。
  Future<void> renameFavorite(String path, String name) async {
    await _api.editFavorite(path, name: name);
    ref.invalidate(fileFavoritesProvider);
  }

  /// P1-7：清掉失效收藏（`Favorite/clear_broken`，无参数）。
  Future<void> clearBrokenFavorites() async {
    await _api.clearBrokenFavorites();
    ref.invalidate(fileFavoritesProvider);
  }

  /// M50：整表重排收藏（`Favorite/replace_all` v2，参数形态**已真机取证**）。
  ///
  /// [ordered] 是重排后的**完整**收藏列表（顺序即期望显示顺序）——`path` 与
  /// `name` 两个平行数组都从它取。服务端 `success:false`（含 400）会让
  /// [FileStationApi.replaceAllFavorites] 抛 `DsmApiException`，这里**不吞异常**：
  /// 调用方负责保留原顺序并提示（本方法只在真正成功后刷新收藏列表）。
  Future<void> replaceAllFavorites(List<FileEntryDto> ordered) async {
    if (ordered.isEmpty) return;
    await _api.replaceAllFavorites(
      paths: ordered.map((e) => e.path).toList(),
      names: ordered.map((e) => e.name).toList(),
    );
    ref.invalidate(fileFavoritesProvider);
  }

  /// M58：重试一个失败的后台任务（重发原 api / method / 参数快照）。
  ///
  /// 返回 `false` = 该任务**不可重试**（缺参数快照，且目标无法从任务字段重建，
  /// 见 [fileTaskRetryPlan]）。返回 `true` = 已重新发起。
  Future<bool> retryTask(FileTaskDto task) async {
    final plan = fileTaskRetryPlan(task);
    if (plan == null) return false;
    await _api.retryTask(
      apiName: plan.api,
      method: plan.method,
      params: plan.params,
    );
    ref.invalidate(fileTasksProvider);
    return true;
  }

  /// 下载到应用目录（断点续传）。进度/暂停/取消由 [FileDownloadSession] 承载。
  ///
  /// P0-b 起：临时文件 `<name>.sydownload` + `Range: bytes=<已下>-` + 206 校验；
  /// 暂停保留临时文件（进程重启后仍可续），服务端不支持 Range 时降级为整份
  /// 重下（[FileDownloadOutcome.fullRestart] = true，界面如实提示）。
  Future<FileDownloadOutcome> download(
    String path, {
    required FileDownloadSession session,
  }) async {
    if (_refApiNull) {
      throw DsmApiException(
        DsmErrorCode.apiNotFound,
        method: 'FileStation（未连接）',
      );
    }
    final name = path.split('/').last;
    final url = _api.downloadUrl([path]);
    final dir = await fileDownloadDirectory();
    try {
      return await FileDownloadResumer(
        fetcher: ref.read(rangeByteFetcherProvider),
        store: FileResumeStore(dir),
      ).download(
        sourcePath: path,
        url: url,
        fileName: name.isEmpty ? 'download' : name,
        directory: dir,
        onProgress: session.report,
        cancelToken: session.cancelToken,
        // ★ DA100：问「这次取消是不是暂停引起的」，而不是「现在还在暂停吗」
        isPaused: () => session.pauseRequestedForInFlightRequest,
      );
    } on DsmApiException catch (e) {
      // 200+JSON 错误信封（如 119）在取数层被还原成错误码 → 统一分类回填
      reportFileByteFailure(ref, 'SYNO.FileStation.Download', e);
      rethrow;
    }
  }

  bool get _refApiNull => ref.read(fileApiProvider) == null;

  /// 上传（从本机路径 → 目标目录）
  ///
  /// [conflict] 是冲突策略（P0-a）：`null` = 没有冲突 / 不发送 `overwrite`
  /// 字段（与官方 `OverWriteMode.NONE` 一致，**不再硬编码 overwrite**）。
  Future<void> upload({
    required String folderPath,
    required String localPath,
    required String fileName,
    UploadConflictPolicy? conflict,
    void Function(int sent, int total)? onProgress,
  }) async {
    await _api.upload(
      folderPath: folderPath,
      filePath: localPath,
      fileName: fileName,
      conflict: conflict,
      onProgress: onProgress,
    );
    await _refresh(folderPath);
  }

  /// M73（审计行 225）：上传本机照片 —— 走 `SYNO.FileStation.PhotoUpload`。
  ///
  /// 与 [upload] 的**唯一区别**：官方 `usePhotoUpload(name)` =
  /// `supportUploadThumbnail() && isPicture(name)` ⇒ 图片走 `PhotoUpload`
  /// （可附缩略图部分，服务端据此直接生成缩略图，不用等它自己转），
  /// 非图片走 `Upload`。这里只服务"本机照片"这条入口，所以固定走前者。
  ///
  /// 缩略图部分**本批不生成**（要平台侧编码，属另一个工作量），
  /// 于是线参退化成与 `upload` 同形 —— 这**不是**假装做了缩略图，
  /// `photoUpload` 的实现在没传 `thumbnailFiles` 时就是这个形状。
  Future<void> uploadPhoto({
    required String folderPath,
    required String localPath,
    required String fileName,
    UploadConflictPolicy? conflict,
    void Function(int sent, int total)? onProgress,
  }) async {
    await _api.photoUpload(
      folderPath: folderPath,
      filePath: localPath,
      fileName: fileName,
      conflict: conflict,
      onProgress: onProgress,
    );
    await _refresh(folderPath);
  }

  /// 清理已完成任务
  Future<void> clearFinishedTasks() async {
    await _api.clearFinishedTasks();
    ref.invalidate(fileTasksProvider);
  }

  /// 分享链接（只读管理）：列表
  Future<List<ShareLinkDto>> shareLinks() => _api.listShareLinks();

  /// 分享链接（只读管理）：删除
  Future<void> deleteShareLinks(List<String> ids) async {
    await _api.deleteShareLinks(ids);
  }

  /// 创建分享链接（P0-1）：`Sharing.create` v3。
  ///
  /// [paths] 可以是文件或文件夹；[password] / [dateExpired] 为空即不发送
  /// （官方 `createShareLinkV3` 的行为，空字段不发 = 无密码 / 永久有效）。
  Future<List<ShareLinkDto>> createShareLink({
    required List<String> paths,
    String? password,
    String? dateAvailable,
    String? dateExpired,
  }) => _api.createShareLink(
    paths: paths,
    password: password,
    dateAvailable: dateAvailable,
    dateExpired: dateExpired,
  );

  /// 编辑分享链接（M36）：`Sharing.edit` v3 —— 改密码 / 有效期。
  ///
  /// [clearPassword] = 移除密码：第 251 轮已按官方 APK 取证，报文是
  /// **`protect_type:"none"` + `password:""` 两个字段一起发**
  /// （见 [FileStationApi.editShareLink] 的 smali 证据）。
  ///
  /// ⚠️ **没有 `clearExpiry`**：官方 edit 路径根本不发"取消有效期"的字段
  /// （APK 在日期为空时直接省略，DSM 网页端发的 `expire_at` 服务端不认），
  /// 所以本方法**不提供**这个动作 —— 界面里选「永久」只会**不改动**原到期时间，
  /// 并已如实提示。
  Future<void> editShareLink({
    required String id,
    String? password,
    bool clearPassword = false,
    String? dateAvailable,
    String? dateExpired,
  }) async {
    await _api.editShareLink(
      id: id,
      password: password,
      clearPassword: clearPassword,
      dateAvailable: dateAvailable,
      dateExpired: dateExpired,
    );
  }

  /// 目录大小（异步任务，结果在任务里）
  Future<String> dirSize(List<String> paths) async {
    final start = await _api.startDirSize(paths);
    ref.invalidate(fileTasksProvider);
    return start.taskId;
  }
}

/// 下载落盘目录：`<应用文档>/downloads`（与聊天附件的缓存目录分开，
/// 因为这里的东西是用户主动下载的，不该被缓存清理策略删掉）
Future<Directory> fileDownloadDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/downloads');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}
