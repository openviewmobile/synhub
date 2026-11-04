// 附件下载缓存 —— 对齐原版的「Cache management」。
//
// 原版（`util/DownloadCache.java` + `PreferenceCacheFragment`）：
//   * 独立的缓存目录，6 档上限（10/50/100/500 MB、1 GB、不限制），默认 500 MB；
//   * 设置页显示"已用多少"，可一键清空（二次确认）；
//   * ⚠️ 原版有缺陷：`DownloadCache` 构造里把上限**硬编码成 500MB**、
//     压根不读 `set_cache_limit`，所以设置改完重启就失效。
//     我们这里真的按设置里的值做淘汰（"做对"的版本）。
//
// 实现取舍：不额外维护 LRU 索引文件 —— 缓存文件都落在自己的子目录里，
// 用量 = 目录内文件大小之和，最久未用 = 文件 mtime（命中缓存时 `touch` 一下）。
// 这样即使进程被杀、索引丢了，缓存也不会失控。
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../i18n/data_text.dart';

/// 缓存用量快照
class CacheUsage {
  const CacheUsage({required this.bytes, required this.files, this.limit = 0});

  final int bytes;
  final int files;

  /// 上限（字节）；0 = 不限制
  final int limit;

  /// 人类可读的用量，例如 `12.3 MB`
  String get humanSize => humanBytes(bytes);

  String get humanLimit =>
      limit <= 0 ? dataText('cacheUnlimited', '不限制') : humanBytes(limit);

  /// 是否已经超限（超限时下一次写入会触发淘汰）
  bool get overLimit => limit > 0 && bytes > limit;

  @override
  String toString() => 'CacheUsage($humanSize / $humanLimit, $files 个文件)';
}

String humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  // 留一点容差：原版的「1 GB」取值是 1073741814（2^30-10），
  // 严格比较会显示成 "1024 MB"，设置页里跟「1 GB」这一档就对不上了。
  while (v >= 1023.95 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${units[i]}';
}

/// 一个「可再生纯缓存」子目录的登记项。
class CacheDirEntry {
  const CacheDirEntry(this.name, {required this.why});

  /// 相对应用缓存根的目录名（允许一层 `/`，例如 `chat_cache/file_thumbs`）
  final String name;

  /// 为什么可以放心"计入并清掉"
  final String why;
}

/// ★ 第 425 轮（`DA83`）：**应用缓存作用域的唯一登记表**。
///
/// 「缓存用量 / 清理已下载的文件 / 上限淘汰」三件事**都只走这张表**。
/// 改前这里硬编码 `chat_cache` + `file_thumbs` 两层，于是
/// `video_frames`（视频首帧）、`office_doc_images`、`office_thumbs`、
/// `office_template_thumbs`、`pdf_renderer_cache` 全都**既不计数也清不掉**：
/// 真机读数（r425）：设置页显示「已用 5.3 MB」，而 `/data/data/<包名>/cache/`
/// 实际 ≈ 17 MB；对话框文案却写「会删掉**所有**已下载的附件与缩略图」。
///
/// ★ 新增缓存目录时**必须**在这里登记（或在 [kCacheNotRegenerable] 里写清理由）——
/// `test/cache_scope_guard_test.dart` 扫源码强制这一点。
const List<CacheDirEntry> kRegenerableCacheDirs = [
  CacheDirEntry('chat_cache', why: '聊天附件与文件缩略图（对齐原版 Cache management）'),
  CacheDirEntry('chat_cache/file_thumbs', why: '文件行缩略图（原版就放在 chat_cache 里）'),
  CacheDirEntry('video_frames', why: '视频首帧缩略图：纯抽帧产物，点开就重抽'),
  CacheDirEntry('office_doc_images', why: 'Office 正文内嵌图片：服务端字节，重开就取回'),
  CacheDirEntry('office_template_thumbs', why: 'Office 模板缩略图：服务端字节，重开就取回'),
  CacheDirEntry('office_thumbs', why: 'Office 文件行缩略图（走临时目录；Android 上就是缓存目录）'),
  CacheDirEntry('libCachedImageData', why: '图片磁盘缓存：重下即可'),
  CacheDirEntry('pdf_renderer_cache', why: 'PDF 渲染位图缓存：重渲染即可'),
];

/// 明确**不计入**「缓存用量 / 清理」的目录 —— 每一个都带理由。
///
/// 不是"漏了"，是"不许动"：用户内容、可能正在写的临时件、
/// 或根本不在缓存目录（持久目录）。守卫同样强制分类。
const Map<String, String> kCacheNotRegenerable = {
  'share_in': '入站分享写进来的副本（用户内容）',
  'saf_ondemand': 'Drive 按需下载的离线文件（用户显式要的，另有自己的清理入口）',
  'photo_backup': '相册备份暂存（用户内容）',
  'photo_cache': '相册浏览临时副本（会话级清理 + 系统回收）',
  'video_frame_tmp': '抽帧中间件（可能正在写）',
  'voice': '语音消息临时文件（可能正在发）',
  'file_picker': '第三方插件 file_picker 的取件副本',
  'WebView': '系统 WebView 目录（Chromium 自己管理）',
  'data': '插件建的 data/user/0 目录（不是本 App 的缓存）',
  'downloads': '在**文档**目录（持久下载），不是缓存',
  'drive_transfer': '在**文档**目录（持久传输），不是缓存',
  'audio_artwork': '在支持目录（持久封面缓存），不是缓存',
};

/// 缓存**根层**（`cacheDir` 直接子文件）里"可再生"的那一类（r434）。
///
/// 为什么单独有这一档：登记表 [kRegenerableCacheDirs] 是按**目录**建模的，
/// 而第三方插件会把文件直接写在 `cacheDir` 里。最典型的是 `pdfx-2.11.0` 的
/// `openDataDocument()`：`File(cacheDir, "$randomFilename.pdf")`
/// （`Messages.kt:360`；`randomFilename` = UUID 去横线 = **32 位十六进制**）。
///
/// 后果（真机 r434 实测）：这类文件既不在任何登记目录下 ⇒ ①「缓存用量」看不到、
/// ②「清空缓存」删不掉、③ 上限淘汰不碰它，而对话框明说会删"attachments/thumbnails/previews"；
/// 且插件每次都用**新随机名** ⇒ 打开一次 PDF 就多一份（真机已积 18 个）。
///
/// 两层修法见 `lib/src/core/media/pdf_local_copy.dart`：源头改走 `openFile`
/// （我们落到已登记的 `pdf_renderer_cache/`）；这里登记根层名字**兜住历史遗留**。
class CacheRootPattern {
  const CacheRootPattern({
    required this.source,
    required this.why,
  });

  /// 正则源码（`RegExp` 不是 const 构造 ⇒ 这里存源码、用时编译）
  final String source;

  /// 为什么它是"可再生"、可以算进用量并删掉（守卫强制非空）
  final String why;

  RegExp get regex => RegExp(source);
}

const List<CacheRootPattern> kCacheRootRegenerablePatterns = [
  CacheRootPattern(
    source: r'^[0-9a-f]{32}\.pdf$',
    why: '第三方 pdfx 的 `openData` 把整份 PDF 写在缓存根层'
        '（插件写死 cacheDir；32 位十六进制 = UUID 去横线）。'
        '我们已改用 `openFile`，这里回收历史遗留 —— 用户"清空缓存"后空间必须真的变小',
  ),
];

/// 根层**明示保留**（不清理、也不计入「缓存用量」）的那一类。
///
/// 为什么要有这一档（r435 / `DA90`）：真机**任意深度**枚举发现根层还躺着在线字幕
/// `subtitle_<集>.gestdown.<uuid>.srt`（45,970 B）。对话框逐字承诺「在线字幕会保留」，
/// 所以**不删是对的**；但在 r434 之前它连「被决定留下过」都算不上 ——
/// 于是 ① 用量行少报 46 KB、② 根层下一次出现新形状时，没人能一眼区分
/// 「故意留的」和「漏登记的」（r434 撞到的 `<32hex>.pdf` 就是后者）。
/// ⇒ 修法：**明示保留也要登记**，并且**不算进用量**（用户能清的东西才叫「缓存用量」）。
const List<CacheRootPattern> kCacheRootKeptPatterns = [
  CacheRootPattern(
    source: r'^subtitle_.*\.srt$',
    why: '在线字幕（`media_subtitle_search` 落盘：集号 + 源 + uuid）。'
        '对话框逐字承诺「在线字幕会保留」⇒ **不清理、不计入用量**，'
        '但必须登记 —— 否则无法区分「故意留的」与「漏登记的」',
  ),
];

/// 根层**零字节残留**规则（r435 / `DA90`）—— 一条「形状之外的兜底」。
///
/// 真机撞到的样本：`<uuid>.jpg`，**0 字节**（某次图片写入中断/失败留下的空壳），
/// 名字连形状都不固定 ⇒ 没法用正则登记。判据为什么可以放宽到「任意名字」：
///   * **0 字节 ⇒ 删掉不丢任何字节**，这是唯一一条不需要知道内容的删除规则；
///   * 加 [kCacheRootZeroByteMinAge] 门槛：避免删掉「正在写、还没写完」的空文件；
///   * 只作用于 `cacheDir` **根层**，白名单目录（`share_in`/`saf_ondemand`/…）碰都不碰。
const String kCacheRootZeroByteRule =
    'cacheDir 根层的 0 字节文件 = 中断/失败的写入残留；mtime 超过 1 小时 ⇒ '
    '计入用量、可被「清空缓存」删掉（删 0 字节不丢任何内容）。';

/// 零字节残留的「多旧才算残留」（见 [kCacheRootZeroByteRule]）
const Duration kCacheRootZeroByteMinAge = Duration(hours: 1);

class CacheService {
  CacheService({Directory? root}) : _explicitRoot = root;

  final Directory? _explicitRoot;
  Directory? _dir;

  /// 缓存目录：`<cacheDir>/chat_cache`（测试里可注入）
  Future<Directory> directory() async {
    if (_dir != null) return _dir!;
    final base = _explicitRoot ?? await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/chat_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// 文件缩略图目录：`<cacheDir>/chat_cache/file_thumbs`
  ///
  /// 放在 `chat_cache` 里面（而不是另起一个目录）是为了让设置页的
  /// 「缓存用量/清空缓存/上限淘汰」把缩略图**一起算进去、一起清掉** ——
  /// 否则用户清了缓存发现空间没变，缩略图也永远不淘汰。
  Future<Directory> fileThumbsDirectory() async {
    final base = await directory();
    final dir = Directory('${base.path}/file_thumbs');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 应用缓存根（测试里可注入；生产 = `path_provider` 的 cache 目录）
  Future<Directory> cacheRoot() async =>
      _explicitRoot ?? await getApplicationCacheDirectory();

  /// 登记表里某个目录的绝对路径（**只算路径，不创建目录**）
  Future<Directory> cacheDirFor(CacheDirEntry entry) async =>
      Directory('${(await cacheRoot()).path}/${entry.name}');

  /// 缓存里的**所有**文件（= [kRegenerableCacheDirs] 里各目录的直接子文件）
  ///
  /// ★ 只走登记表：表外的目录（用户内容 / 正在写的临时件 / 系统目录）
  /// **一个都不碰** —— 这就是"清空缓存"不等于"把 `cacheDir` 整个删掉"的原因。
  Future<List<File>> _allFiles() async {
    final out = <File>[];
    for (final entry in kRegenerableCacheDirs) {
      try {
        final dir = await cacheDirFor(entry);
        await for (final e in dir.list(followLinks: false)) {
          if (e is File) out.add(e);
        }
      } catch (_) {}
    }
    out.addAll(await _rootRegenerableFiles());
    return out;
  }

  /// 缓存**根层**里"算作缓存"的文件（r434/r435）。
  ///
  /// 判据按**优先级**三条（顺序不能换）：
  ///   ① [kCacheRootKeptPatterns] 命中 ⇒ **明示保留**，直接跳过（一个都不许碰）；
  ///   ② [kCacheRootRegenerablePatterns] 命中 ⇒ 登记的"可再生"，计入用量/可清空；
  ///   ③ 都不是、但**是根层 0 字节且够旧** ⇒ 按 [kCacheRootZeroByteRule] 当残留回收。
  ///
  /// ★ 除这三条以外，根层别的东西（用户内容、别家插件正在写的文件、非零字节的陌生形状）
  /// **一个都不许碰** —— 判据是"名字/形状被登记过"，不是"根层所有文件"。
  /// ③ 存在的意义：真机上撞到过名字完全不固定的 0 字节残留；
  /// 把它**如实登记成一条规则**（而不是"眼不见为净"），才有"未归类 = 0"这种可核算判据。
  Future<List<File>> _rootRegenerableFiles() async {
    final out = <File>[];
    try {
      final root = await cacheRoot();
      final now = DateTime.now();
      await for (final e in root.list(followLinks: false)) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.isEmpty
            ? e.path
            : e.uri.pathSegments.last;
        // ① 明示保留：优先于一切（哪怕它同时命中下面的正则）
        if (kCacheRootKeptPatterns.any((p) => p.regex.hasMatch(name))) continue;
        // ② 登记过的可再生形状
        if (kCacheRootRegenerablePatterns.any((p) => p.regex.hasMatch(name))) {
          out.add(e);
          continue;
        }
        // ③ 0 字节残留（够旧的才算；正在写的空文件不许碰）
        try {
          final st = await e.stat();
          if (st.size == 0 &&
              now.difference(st.modified) >= kCacheRootZeroByteMinAge) {
            out.add(e);
          }
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  /// 缓存文件的落盘路径：`<cache>/<postId>_<安全文件名>`
  Future<String> pathFor(
    int postId,
    String fileName, {
    bool thumbnail = false,
  }) async {
    final dir = await directory();
    final safe = fileName.replaceAll(RegExp(r'[^\w.\-\u4e00-\u9fa5]'), '_');
    return '${dir.path}/${thumbnail ? 't' : 'f'}${postId}_$safe';
  }

  /// 命中缓存时把 mtime 刷新成"刚刚用过"（LRU 用 mtime）
  Future<void> touch(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.setLastModified(DateTime.now());
      }
    } catch (_) {}
  }

  /// 当前用量（[limitBytes] 传设置里的值，0 = 不限制）
  Future<CacheUsage> usage({int limitBytes = 0}) async {
    var bytes = 0;
    var files = 0;
    for (final f in await _allFiles()) {
      try {
        bytes += await f.length();
        files++;
      } catch (_) {}
    }
    return CacheUsage(bytes: bytes, files: files, limit: limitBytes);
  }

  /// 按上限淘汰：删最久未用的，直到用量降到上限以内。
  ///
  /// [limitBytes] <= 0 表示不限制，直接返回。
  /// [protect] 里的路径不会被删（正在用的那个文件）。
  /// 返回删掉的字节数。
  Future<int> enforceLimit(
    int limitBytes, {
    Set<String> protect = const {},
  }) async {
    if (limitBytes <= 0) return 0;
    final entries = <({File file, int size, DateTime at})>[];
    for (final f in await _allFiles()) {
      if (protect.contains(f.path)) continue;
      try {
        final st = await f.stat();
        entries.add((file: f, size: st.size, at: st.modified));
      } catch (_) {}
    }
    var total = entries.fold<int>(0, (a, e) => a + e.size);
    if (total <= limitBytes) return 0;

    entries.sort((a, b) => a.at.compareTo(b.at)); // 最久未用在前
    var freed = 0;
    for (final e in entries) {
      if (total <= limitBytes) break;
      try {
        await e.file.delete();
        total -= e.size;
        freed += e.size;
      } catch (_) {}
    }
    return freed;
  }

  /// 清空登记表里的所有可再生缓存（设置页的"清理已下载的文件"）
  ///
  /// ★ 不碰 [kCacheNotRegenerable] 里的目录（离线保存/分享副本/系统目录）。
  Future<int> clear() async {
    var freed = 0;
    for (final f in await _allFiles()) {
      try {
        freed += await f.length();
        await f.delete();
      } catch (_) {}
    }
    return freed;
  }
}
