// 在线字幕源（**可插拔**）：按标题/文件名搜索、首尾 64KB 哈希匹配、下载到缓存。
//
// 这一层是**纯逻辑**：不 import flutter / riverpod / path_provider，只碰
// `dart:io` + `dio` 之外的标准库与两个纯 Dart 依赖（`archive` / `pointycastle`）。
// 缓存落盘由调用方注入：`SubtitleCacheStore(directory: …)`（生产：`path_provider`
// 的缓存目录）或 `SubtitleCacheStore(backend: …)`（单测：内存实现 —— widget 测试
// 的假时钟推不动真磁盘 IO，`runAsync` 里发起还会重入挂死，见测试文件头）。
//
// ---------------------------------------------------------------------------
// ★ 实测证据（2026-09-26，本机 bash + PAC 代理 127.0.0.1:7897；`curl -sS -L`）
// ---------------------------------------------------------------------------
//
// 【1】gestdown（**免密钥，实测可用**；只覆盖剧集，en/fr 有词条）
//
//   $ curl -sS --max-time 30 "https://api.gestdown.info/shows/search/Breaking%20Bad"
//   http=200 size=332
//   {"shows":[{"id":"31ffb6ce-c000-4079-8912-b3f72057baed","name":"Breaking Bad",
//     "nbSeasons":5,"seasons":[1,2,3,4,5],"tvDbId":81189,"tmdbId":1396,
//     "slug":"breaking-bad"}, ...]}
//
//   $ curl -sS "https://api.gestdown.info/subtitles/get/31ffb6ce-...-3f72057baed/1/1/en"
//   http=200 size=2276
//   {"matchingSubtitles":[{"subtitleId":"69cf7d79-052c-4f12-a57d-995d77de43ad",
//     "version":"0tv","language":"English","downloadUri":"/subtitles/download/69cf...",
//     "discovered":"2022-05-17T02:28:20.084012Z", ...}]}
//
//   $ curl -sS "https://api.gestdown.info/subtitles/download/69cf7d79-...-995d77de43ad"
//   http=200 size=45970 ct=text/srt
//   1
//   00:02:05,273 --> 00:02:17,187
//   My name is
//   Walter Hartwell White.
//   （→ **端到端可用**：搜索 → 选条 → 下载，全部 200，无需任何 key）
//   ★ 语言覆盖实测（同一集 BB S1E1）：en=6 条、fr=5 条；
//     es/de/pt/zh 都是 200 但 `matchingSubtitles` 为空；非法码（zh-CN/zt）回 423。
//     ⇒ 中文剧集字幕**这个源给不了**（如实记录，不假装）。
//
// 【2】OpenSubtitles REST（搜索偶发可用、下载**免密钥实测可用**；要稳定得填 key）
//
//   $ curl -sS -L "https://api.opensubtitles.com/api/v1/subtitles?query=inception&languages=en"
//   http=200 size=60789
//   {"total_pages":2,"total_count":57,"per_page":50,"page":1,"data":[{"id":"4859512",
//     "attributes":{"subtitle_id":"4859512","language":"en","download_count":7733,
//     "legacy_subtitle_id":7803094,"files":[{"file_id":4982777,"cd_number":1,...}],
//     "release":"Inception", ...}}]}
//   ★ 匿名档**会限流，且限流窗口不短**：紧接着的 `?query=matrix&languages=en`
//     连打 10 次全部 `http=403 size=100 {"message":"You cannot consume this service"}`
//     （间隔 3s），隔 120s 再打 3 次仍全 403，再往后（约 10 分钟后）同样的
//     `?query=inception&languages=en` 又回到 `http=200 size=60789`。
//     ⇒ 匿名档是**间歇可用**：实现里把「403 + 没填 key」映射成"需要 API Key"
//     的可读提示（不静默失败），填 Key 后走 `Api-Key` 头。
//   ★ `languages=` 换成 zh/chi/fr/de/es 时也是 403；只有 `en` 与 `all` 成功过。
//     因此匿名时本实现只在"只要 en"时发 `languages=en`，否则发 `languages=all`
//     再在客户端按目标语言过滤（尽力而为，如实标注）。
//
//   $ curl -sS -L "https://dl.opensubtitles.org/en/download/sub/7803094"
//   http=200 size=47017 ct=application/zip
//   00000000: 504b 0304 1400 0000 0800 8c56 395d 0a34  PK.........V9].4
//   0000b7a0: 0000 0013 b700 0000 00                   .........
//   $ unzip -l /tmp/dl2.bin
//     Inception.srt   133285 bytes    （→ **下载链路免密钥可用**，回来的是 zip）
//   ★ 收尾复测（同一天稍后）：`http=200 size=47016 ct=application/zip`，
//     `zipfile` 读出 `Inception.srt`（133281 B）首行 `1 / 00:00:06,000 --> …`
//     ⇒ 下载口**不随搜索口的限流一起失效**，可独立依赖。
//
//   $ curl -sS -X POST -H 'Content-Type: application/json' --data '{"file_id":4982777}' \
//       "https://api.opensubtitles.com/api/v1/download"
//   http=503 {"message":"Service unavailable"}   （重试 3 次 + 带 bogus key 都是 503）
//   ⇒ **官方 JSON 下载口在本机实测不可用**，所以本模块的下载一律走
//     `dl.opensubtitles.org/en/download/sub/<legacy_subtitle_id>`（上面那条 200 的）。
//
// 【3】被否掉的源（如实记录，不留"看起来支持"的假象）
//   * SubDB（首尾 64KB MD5 的那个）：`http://api.thesubdb.com/?action=search&hash=…`
//     → `http=502 size=0`；`https://api.thesubdb.com` → `curl: (35) SSL_ERROR_SYSCALL`。
//     ⇒ **API 已不可用**，只保留它的哈希算法（[subDbHashHex]）不再做源。
//   * Podnapisi XML（`https://www.podnapisi.net/subtitles/search/old?sXML=1&…`）
//     → `curl: (35) SSL_ERROR_SYSCALL`（000）。
//     ★ **r425 复探（只读）⇒ 域名已死**：`www.podnapisi.net` 直连 **DNS 解析失败**
//       （`curl: (6) Could not resolve host`）＋ 走 PAC 代理 **TLS 握手失败**
//       （`curl: (35) SSL_ERROR_SYSCALL`）⇒ **不再作为候选**（不是"未验证"，是实测不可达）。
//       证据：`docs/evidence-r425/README.md` 的 `r425_subtitle_sources_probe.txt`；
//       待办销号：`docs/android-remaining-todo-r418.md` §二点九-3。
//   * opensubtitles.org 老 HTML 搜索 → `http=401`「Making sure you're not a bot!」
//     （Anubis 反爬）⇒ 不能当源；但同域的 `dl.opensubtitles.org/en/download/sub/…`
//     **不受影响**（上面 200）。
//   * OpenSubtitles XML-RPC（`api.opensubtitles.org/xml-rpc`）`SearchSubtitles`
//     与空口令 `LogIn` 都回 `401 Unauthorized` ⇒ **该口**不是免密钥源
//     （★ r456 复探：`TemporaryUserAgent` 与裸 curl UA **都还是 401** ⇒ 匿名档确实被关掉了；
//      这正是 VLC 的 VLSub 现在普遍失效的原因 —— 它的 `vlsub.lua` 就是空账号空口令 `LogIn`）。
//
//   * wyzie（`api.wyzie.io/*`）全部 404，没有可用的公开路由。
//
// ★★★ 【4】r456 **新发现的免密钥口**：`rest.opensubtitles.org/search/...`
//   （OpenSubtitles 的**老 REST 口**，XBMC/Kodi 时代那条路；本模块此前**从没试过**。
//    ⇒ 教训：老 XML-RPC 一关，不等于这家站全关 —— 换入口要真的换）
//   ⚠️ ⚠️ **路径必须全小写**（本轮最关键的实测）：`query-Matrix` = 302（**5/5 稳定**）、
//      `query-matrix` = 200（5/5）；302 的 `location` 是**小写化后的路径**
//      ⇒ 触发条件就是"路径里出现大写字母"。
//   ⚠️ 查询词一律用 `+` 连接：`%20` 与 `.`/`%2E` 会撞上同一个**坏重定向**
//      （`location: https://_/search/...`，目标主机字面是 `_` ⇒ `Could not resolve host: _`）。
//   $ curl -sS "https://rest.opensubtitles.org/search/imdbid-1375666/sublanguageid-chi"
//     http=200 size=14551 ⇒ 9 条（同一部片 `chi` 简 9 / `zht` 繁 6 / `zhe` 双语 5）
//   $ curl -sS "https://rest.opensubtitles.org/search/query-breaking+bad/sublanguageid-chi"
//     http=200 size=127947 ⇒ 73 条
//   $ curl -sS -o /tmp/x.gz "<SubDownloadLink>"
//     http=200 size=47176 ct=application/force-download
//     gunzip 后首行：`1 / 00:00:01,000 --> 00:00:03,000 / 盗梦空间2010`
//   ★ 限流：连打 8 次（间隔 0.5 s）**全 200**（1.1–4.3 s）—— 与新口匿名档的 403 形成对照；
//   ★ UA 不是门槛：`TemporaryUserAgent` / 默认 `curl` / 浏览器 UA 都是 200；
//   ★ **哈希搜索在这个口不可用**（`moviehash-…/moviebytesize-…` ⇒ 同一个坏 302）⇒ 只按 `query-`/`imdbid-` 搜。
//   完整读数（含被否掉的 subdl/subsource/addic7ed 等）：`docs/evidence-r456/host/r456_subtitle_sources_probe.txt`
//
// ---------------------------------------------------------------------------
// 哈希（"首尾 64KB"）
// ---------------------------------------------------------------------------
// OpenSubtitles hash（官方算法）：`hash = fileSize + Σ uint64_le(首 64KB) + Σ
// uint64_le(尾 64KB)`，取模 2^64。媒体 URL 只要支持 Range，就能只取两段。
// SubDB 用 md5(首 64KB + 尾 64KB)（[subDbHashHex]，算法保留）。
// ★ 拿不到 hash 就**不做 hash 搜索**（不硬编）：调用方传 `query.hash == null`，
//   只按标题搜。
//
// ---------------------------------------------------------------------------
// 明确不做
// ---------------------------------------------------------------------------
// * 不做 .sub（VobSub 图形字幕）—— 需要 OCR，本模块只认 srt/ass/ssa/vtt；
// * 不做多 CD（`nb_cd > 1`）的自动拼接 —— 只取第一条文件，界面如实标注；
// * 不做源内登录 / 不做验证码绕过。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pointycastle/digests/md5.dart';

import '../../core/i18n/data_text.dart';
import '../../core/json_coerce.dart';
import '../files/book_encoding.dart';
import 'media_playlist.dart' show fileNameStem;
import 'media_subtitles.dart';

// ------------------------------------------------------------------ 常量

/// OpenSubtitles 的 `Api-Key` 在安全存储里的槽位（见 `CloudKeyStore`）
const String kOpenSubtitlesKeySlot = 'opensubtitles';

/// 在线字幕请求的 User-Agent。
///
/// 实测：默认的 `curl/x.y` 与 `synhub/0.1` 都能拿到 200，但浏览器风格
/// 的 UA 在风控下更稳（同一时段 `languages=all` 用浏览器 UA 命中过 200）。
const String kSubtitleSearchUserAgent =
    'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// 缓存目录里的文件名前缀（`subtitle_` 便于用户/排查一眼看出是谁放的）
const String kSubtitleCachePrefix = 'subtitle_';

// ------------------------------------------------------------------ 解析：

/// 从文件名里认出来的"这片子是什么"（`Breaking.Bad.S01E02.1080p.mkv`）
class ParsedMediaName {
  const ParsedMediaName({
    required this.title,
    this.year,
    this.season,
    this.episode,
  });

  /// 干净的标题（去掉了季集/画质/编码/年份这些标签）
  final String title;

  final int? year;
  final int? season;
  final int? episode;

  bool get isEpisode => season != null && episode != null;

  @override
  String toString() => 'ParsedMediaName($title, $year, S$season E$episode)';
}

/// 会被当成"发布标签"的片段（命中即从这里截断标题）
const List<String> _releaseTags = [
  '2160p',
  '1080p',
  '1080i',
  '720p',
  '576p',
  '480p',
  '4k',
  'uhd',
  'hdrip',
  'bluray',
  'blu-ray',
  'brrip',
  'bdrip',
  'webrip',
  'web-dl',
  'webdl',
  'web',
  'hdtv',
  'dvdrip',
  'dvd',
  'remux',
  'x264',
  'x265',
  'h264',
  'h265',
  'hevc',
  'avc',
  'xvid',
  'divx',
  'aac',
  'ac3',
  'eac3',
  'dts',
  'dtshd',
  'truehd',
  'atmos',
  'flac',
  'mp3',
  '10bit',
  '8bit',
  'hdr',
  'sdr',
  'dolby',
  'proper',
  'repack',
  'remastered',
  'extended',
  'imax',
];

bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// 文件名 → 标题 / 年份 / 季集。
///
/// 规则（**只做能证伪的简单规则**，不猜）：
///   1. 去扩展名，`.` / `_` / `-` 视作分隔；
///   2. `S01E02` / `s1e2` / `1x02` → season/episode（**紧贴在标题尾部也算**，
///      见下面 DA41 的说明）；
///   3. 第一个 19xx/20xx 的独立数字 → year（**并且标题在这里截断**）；
///   4. 第一个发布标签（1080p/x265/web-dl…）→ 标题在这里截断。
///
/// ★ DA41（r391 真机抓到）：`60招基础街球S01E01.AVI` 这类"季集号**紧贴**在标题
/// 后面、中间没有任何分隔符"的命名（中文媒体最常见的写法之一）原来**认不出来** ——
/// 旧实现要求整个 token 恰好等于 `S01E01`。后果不是"少认一个名字"那么轻：
/// 唯一免密钥的在线字幕源 gestdown 的门禁就是"文件名能不能推出季集"
/// （[GestdownSource.supportsFileName]），于是这类文件**永远拿不到在线字幕**，
/// 而界面还写着"文件名里需要有 S01E02 这样的季集号" —— 对一个明明含 `S01E01`
/// 的文件撒谎。修法：token 尾部出现 `SxxExx` / `NxNN` 时也认，
/// 并把这个 token 的前半截**留在标题里**（`60招基础街球S01E01` → 标题
/// `60招基础街球`、S1E1）。★ 必须锚在**尾部**：中间出现（`ShowS01E02Extras`）
/// 不认，否则会把"标题里恰好有这串字符"的普通文件误判成剧集。
ParsedMediaName parseMediaFileName(String fileName) {
  final stem = fileNameStem(fileName);
  final raw = stem.replaceAll(RegExp(r'[._]+'), ' ').replaceAll('-', ' ');
  final parts = raw
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  int? season;
  int? episode;
  int? year;
  var cut = parts.length;
  // token 尾部的季集号（DA41）：`...S01E01` / `...1x02`，前面必须有别的内容
  final gluedSxxExx = RegExp(r'[sS](\d{1,2})[eE](\d{1,3})$');
  final gluedXform = RegExp(r'(\d{1,2})x(\d{1,3})$');
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    // 紧贴尾部的写法：把标签从 token 上切掉，前半截继续参与标题
    final gluedS = gluedSxxExx.firstMatch(p);
    final gluedX = gluedS == null ? gluedXform.firstMatch(p) : null;
    final glued = gluedS ?? gluedX;
    // ★ 前置字符不能是数字：否则 `1920x1080` 会被尾部子串 `20x1080`
    //   误判成 S20E1080（分辨率 token 在文件名里极常见）—— 见反向用例。
    if (glued != null &&
        glued.start > 0 &&
        !_isAsciiDigit(p.codeUnitAt(glued.start - 1))) {
      if (gluedS != null) {
        season ??= int.tryParse(gluedS.group(1)!);
        episode ??= int.tryParse(gluedS.group(2)!);
      } else {
        final x = gluedX!;
        season ??= int.tryParse(x.group(1)!);
        episode ??= int.tryParse(x.group(2)!);
      }
      parts[i] = p.substring(0, glued.start);
      // `cut = i + 1`：这个 token 的**前半截**（标题部分）保留在标题里
      if (i + 1 < cut) cut = i + 1;
      continue;
    }
    final sxxexx = RegExp(
      r'^[sS](\d{1,2})[eE](\d{1,3})$',
    ).firstMatch(p);
    if (sxxexx != null) {
      season ??= int.tryParse(sxxexx.group(1)!);
      episode ??= int.tryParse(sxxexx.group(2)!);
      if (i < cut) cut = i;
      continue;
    }
    final xform = RegExp(r'^(\d{1,2})x(\d{1,3})$').firstMatch(p);
    if (xform != null) {
      season ??= int.tryParse(xform.group(1)!);
      episode ??= int.tryParse(xform.group(2)!);
      if (i < cut) cut = i;
      continue;
    }
    if (year == null && RegExp(r'^(19|20)\d{2}$').hasMatch(p)) {
      final v = int.tryParse(p);
      // 2010 这样的数字才有意义（`2021` 也可能是集数，但剧集走 SxxExx 分支）
      if (v != null && v >= 1900 && v <= 2099) {
        year = v;
        if (i < cut) cut = i;
      }
      continue;
    }
    if (_releaseTags.contains(p.toLowerCase())) {
      if (i < cut) cut = i;
    }
  }
  final title = parts.take(cut).join(' ').trim();
  return ParsedMediaName(
    title: title.isEmpty ? raw.trim() : title,
    year: year,
    season: season,
    episode: episode,
  );
}

// ------------------------------------------------------------------ 哈希

final BigInt _u64Mask = (BigInt.one << 64) - BigInt.one;

/// OpenSubtitles 的"首尾 64KB"哈希（16 位小写 hex）。
///
/// [head] = 文件开头最多 64KB，[tail] = 文件末尾最多 64KB，
/// [fileSize] = **完整**文件大小（不是这两段的和）。
/// 文件 < 128KB 时应把整份当 head、tail 传空（调用方负责，见 [hashChunkPlan]）。
String openSubtitlesHashHex({
  required List<int> head,
  required List<int> tail,
  required int fileSize,
}) {
  var sum = BigInt.from(fileSize < 0 ? 0 : fileSize);
  void addChunk(List<int> chunk) {
    var value = BigInt.zero;
    // 小端 64bit：每 8 字节一组；官方实现里尾部不足 8 字节按 0 补齐
    for (var i = 0; i < chunk.length; i++) {
      value |= BigInt.from(chunk[i] & 0xFF) << (8 * (i % 8));
      if (i % 8 == 7) {
        sum = (sum + value) & _u64Mask;
        value = BigInt.zero;
      }
    }
    sum = (sum + value) & _u64Mask;
  }

  addChunk(head);
  addChunk(tail);
  // 官方把哈希当 64bit **整数**打成 16 位 hex（大端写法，等价于 `%016x`），
  // 不是小端字节序 —— 交叉校验时踩过：小端写法会得到整串倒过来的值。
  return sum.toRadixString(16).padLeft(16, '0');
}

/// SubDB 的"首尾 64KB MD5"（32 位小写 hex）。
///
/// ★ 算法保留、**没有对应的源**：API 实测已死（见文件头 §3）。
String subDbHashHex({required List<int> head, required List<int> tail}) {
  final digest = MD5Digest();
  final combined = Uint8List.fromList([...head, ...tail]);
  final out = digest.process(combined);
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 某文件大小要不要"整份当 head"（而不是首尾各 64KB）
bool hashNeedsWholeFile(int fileSize, {int chunk = 65536}) =>
    fileSize <= chunk * 2;

// ------------------------------------------------------------------ HTTP

/// 一次 HTTP 应答（在线字幕源只用到 GET/HEAD 语义）
class SubtitleHttpResponse {
  const SubtitleHttpResponse({
    required this.statusCode,
    required this.body,
    this.contentType = '',
  });

  final int statusCode;
  final Uint8List body;
  final String contentType;

  bool get ok => statusCode >= 200 && statusCode < 300;

  /// UTF-8 宽松解码（JSON 都是 UTF-8）
  String get text => utf8.decode(body, allowMalformed: true);
}

/// HTTP 抽象：单测注入假实现，生产走 [DartIoSubtitleHttp]
abstract class SubtitleHttp {
  Future<SubtitleHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 20),
  });
}

/// 生产实现：`dart:io` HttpClient（自动跟随跳转 + 解 gzip）
class DartIoSubtitleHttp implements SubtitleHttp {
  DartIoSubtitleHttp({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<SubtitleHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final req = await _client.getUrl(uri).timeout(timeout);
      req.followRedirects = true;
      req.headers.set(HttpHeaders.userAgentHeader, kSubtitleSearchUserAgent);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
      headers.forEach(req.headers.set);
      final res = await req.close().timeout(timeout);
      final builder = BytesBuilder(copy: false);
      final completer = Completer<void>();
      // gzip / deflate 由 HttpClient 自动解（它认 Content-Encoding）
      res.listen(
        builder.add,
        onDone: completer.complete,
        onError: completer.completeError,
        cancelOnError: true,
      );
      await completer.future.timeout(timeout);
      return SubtitleHttpResponse(
        statusCode: res.statusCode,
        body: builder.takeBytes(),
        contentType: res.headers.contentType?.mimeType ?? '',
      );
    } on TimeoutException {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.network,
        dataText('mediaSubtitleTimeout', '请求超时'),
      );
    } on SocketException catch (e) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.network,
        dataText(
          'mediaSubtitleServerUnreachable',
          '连不上字幕服务器（{err}）',
        ).replaceAll('{err}', e.osError?.message ?? e.message),
      );
    } on HandshakeException catch (e) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.network,
        dataText(
          'mediaSubtitleTlsFailed',
          'TLS 握手失败（{err}）',
        ).replaceAll('{err}', e.message),
      );
    }
  }
}

// ------------------------------------------------------------------ 结果模型

/// 搜索失败的种类（决定界面给什么可读原因 + 有没有"重试"）
enum SubtitleSearchFailureKind {
  /// 网络层：超时 / 连不上 / TLS
  network,

  /// 源要 API Key 而用户没填（或匿名档被拒）
  keyMissing,

  /// 填了 Key 但被拒（401/403）
  keyRejected,

  /// 被限流（429/503）
  rateLimited,

  /// 应答不是能认的 JSON / 结构
  badResponse,

  /// 这个源不支持这次查询（例如 gestdown 遇到电影、文件名叫不出季集）
  unsupported,
}

/// 在线字幕的一次失败（**不许静默**：界面拿它在字幕面板里显示原因 + 重试）
class SubtitleSearchFailure implements Exception {
  const SubtitleSearchFailure(this.kind, this.message, {this.statusCode});

  final SubtitleSearchFailureKind kind;

  /// 给用户看的一句话（中文原文；英文由 `context.t` 侧的既有 key 兜）
  final String message;

  final int? statusCode;

  @override
  String toString() =>
      'SubtitleSearchFailure($kind, $message${statusCode == null ? '' : ', '
          'http=$statusCode'})';
}

/// 一条在线搜索结果
class SubtitleSearchHit {
  const SubtitleSearchHit({
    required this.sourceId,
    required this.sourceLabel,
    required this.id,
    required this.title,
    required this.language,
    this.release = '',
    this.downloads = 0,
    this.rating = 0,
    this.note = '',
    this.payload = const {},
  });

  /// 源 id（`opensubtitles` / `gestdown`）
  final String sourceId;

  /// 界面上显示的源名
  final String sourceLabel;

  /// 源内 id（下载时原样回传）
  final String id;

  /// 片名/版本名（列表主文案）
  final String title;

  /// 语言码（`zh-cn` / `en` …）
  final String language;

  /// 发布名（`Inception.2010.1080p.BluRay.x264`）
  final String release;

  final int downloads;
  final double rating;

  /// 附加说明（`S01E02` / `第 1/2 段`…）
  final String note;

  /// 源内参数（下载要用；不要拿去显示）
  final Map<String, String> payload;

  @override
  String toString() =>
      'SubtitleSearchHit($sourceId #$id, $language, $release)';
}

/// 下载好的一条字幕
class SubtitleDownload {
  const SubtitleDownload({
    required this.fileName,
    required this.bytes,
    required this.format,
  });

  final String fileName;
  final Uint8List bytes;
  final SubtitleFormat format;

  /// 字节 → 解析好的轨（解析不出内容 → null，调用方**不许**假装挂上了）
  SubtitleTrack? toTrack() {
    final text = decodeBookText(bytes);
    final cues = SubtitleParser.parse(text, format);
    if (cues.isEmpty) return null;
    return SubtitleTrack(fileName: fileName, format: format, cues: cues);
  }
}

/// 搜索条件
class SubtitleSearchQuery {
  const SubtitleSearchQuery({
    required this.fileName,
    this.title,
    this.hash,
    this.languages = const ['zh-cn', 'zh', 'en'],
    this.year,
  });

  /// NAS 上的文件名（用来推标题与季集）
  final String fileName;

  /// 用户手输的标题（覆盖从文件名推的）
  final String? title;

  /// OpenSubtitles 哈希（16 位 hex；null = 不做 hash 匹配）
  final String? hash;

  /// 目标语言（源不支持就跳过 / 过滤）
  final List<String> languages;

  final int? year;

  /// 实际拿去搜的标题（手输优先，否则解析文件名）
  String get effectiveTitle {
    final manual = title?.trim() ?? '';
    if (manual.isNotEmpty) return manual;
    return parseMediaFileName(fileName).title;
  }
}

// ------------------------------------------------------------------ 源接口

/// 一个**可插拔**的在线字幕源。
///
/// 加新源只要实现这个接口并放进 `SubtitleSearchService.sources`，
/// 不需要动播放器界面。
abstract class SubtitleOnlineSource {
  /// 稳定 id（也是缓存文件名里的一段）
  String get id;

  /// 界面显示的源名
  String get label;

  /// 源需不需要 API Key（true = 没填时界面要明确提示"未配置密钥"）
  bool get requiresKey;

  /// 源支不支持首尾 64KB 哈希匹配
  bool get supportsHash;

  /// 能给用户看的一句话说明（界面在源名下面显示）
  String get note;

  Future<List<SubtitleSearchHit>> search(
    SubtitleSearchQuery query, {
    String? apiKey,
  });

  Future<SubtitleDownload> download(
    SubtitleSearchHit hit, {
    String? apiKey,
  });
}

// ------------------------------------------------------------------ OpenSubtitles

/// OpenSubtitles（`api.opensubtitles.com` 搜索 + `dl.opensubtitles.org` 下载）
///
/// * **免密钥**：搜索与下载都实测拿到过 200（见文件头 §2）；匿名档配额有限，
///   被拒（403）时给 [SubtitleSearchFailureKind.keyMissing] 让界面提示填 Key；
/// * 填了 Key 之后带 `Api-Key` 头，配额与语言覆盖都更好；
/// * 下载走 `dl.opensubtitles.org/en/download/sub/<legacy_subtitle_id>`
///   （实测 200 + 45KB 合法 zip）——**官方 JSON 下载口实测 503，不用它**。
class OpenSubtitlesSource implements SubtitleOnlineSource {
  OpenSubtitlesSource({SubtitleHttp? http})
    : _http = http ?? DartIoSubtitleHttp();

  final SubtitleHttp _http;

  static const String searchBase = 'https://api.opensubtitles.com/api/v1';
  static const String downloadBase = 'https://dl.opensubtitles.org/en/download';

  @override
  String get id => 'opensubtitles';

  @override
  String get label => 'OpenSubtitles';

  @override
  bool get requiresKey => false;

  @override
  bool get supportsHash => true;

  @override
  String get note => dataText(
    'mediaSubtitleSourceOpenSubtitlesNote',
    '免密钥可用（匿名有配额）；填 API Key 后更稳、语言更全',
  );

  @override
  Future<List<SubtitleSearchHit>> search(
    SubtitleSearchQuery query, {
    String? apiKey,
  }) async {
    final title = query.effectiveTitle.trim();
    if (title.isEmpty) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.unsupported,
        dataText(
          'mediaSubtitleNoTitleFromFileName',
          '文件名里推不出片名，请在搜索框里手动输入片名',
        ),
      );
    }
    final params = <String, String>{'query': title};
    // 匿名档实测只有 `en` / `all` 能过（其余语言码回 403），所以：
    //   * 只要 en → languages=en（最省配额）
    //   * 否则 → languages=all，再在客户端按目标语言过滤
    final wanted = query.languages
        .map(_normalizeLanguage)
        .where((e) => e.isNotEmpty)
        .toSet();
    final onlyEnglish = wanted.isNotEmpty && wanted.every((e) => e == 'en');
    params['languages'] = onlyEnglish ? 'en' : 'all';
    final hash = query.hash?.trim() ?? '';
    if (hash.isNotEmpty) params['moviehash'] = hash;
    if (query.year != null) params['year'] = '${query.year}';

    final uri = Uri.parse(
      '$searchBase/subtitles',
    ).replace(queryParameters: params);
    final headers = <String, String>{
      'Accept': 'application/json',
      if (apiKey != null && apiKey.trim().isNotEmpty)
        'Api-Key': apiKey.trim(),
    };
    final res = await _http.get(uri, headers: headers);
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw SubtitleSearchFailure(
        apiKey == null || apiKey.trim().isEmpty
            ? SubtitleSearchFailureKind.keyMissing
            : SubtitleSearchFailureKind.keyRejected,
        apiKey == null || apiKey.trim().isEmpty
            ? dataText(
                'mediaSubtitleOpenSubtitlesAnonymousRejected',
                'OpenSubtitles 拒绝了匿名请求（HTTP {code}）：请在下方填写 API Key 后重试',
              ).replaceAll('{code}', '${res.statusCode}')
            : dataText(
                'mediaSubtitleOpenSubtitlesRejected',
                'OpenSubtitles 拒绝了这次请求（HTTP {code}）：API Key 可能无效或已超额',
              ).replaceAll('{code}', '${res.statusCode}'),
        statusCode: res.statusCode,
      );
    }
    if (res.statusCode == 429 || res.statusCode == 503) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.rateLimited,
        dataText(
          'mediaSubtitleOpenSubtitlesUnavailable',
          'OpenSubtitles 暂时不可用（HTTP {code}），稍后重试',
        ).replaceAll('{code}', '${res.statusCode}'),
        statusCode: res.statusCode,
      );
    }
    if (!res.ok) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.badResponse,
        dataText(
          'mediaSubtitleOpenSubtitlesUnexpectedStatus',
          'OpenSubtitles 返回了意外的状态码 HTTP {code}',
        ).replaceAll('{code}', '${res.statusCode}'),
        statusCode: res.statusCode,
      );
    }
    final decoded = _decodeJson(res);
    final rows = jsonMapList(decoded['data']);
    final hits = <SubtitleSearchHit>[];
    for (final row in rows) {
      final attrs = jsonMap(row['attributes']);
      final language = _normalizeLanguage(jsonStr(attrs['language']));
      if (wanted.isNotEmpty && !_languageMatches(wanted, language)) continue;
      final legacy = jsonInt(attrs['legacy_subtitle_id']);
      final files = jsonMapList(attrs['files']);
      final fileId = files.isEmpty ? null : jsonInt(files.first['file_id']);
      if (legacy == null && fileId == null) continue;
      final feature = jsonMap(attrs['feature_details']);
      final release = jsonStr(attrs['release']).trim();
      final featureTitle = jsonStr(feature['title']).trim();
      final title0 = release.isNotEmpty
          ? release
          : (featureTitle.isNotEmpty ? featureTitle : query.effectiveTitle);
      hits.add(
        SubtitleSearchHit(
          sourceId: id,
          sourceLabel: label,
          id: '${legacy ?? fileId}',
          title: title0,
          language: language,
          release: release,
          downloads: jsonIntOr(attrs['download_count'], 0),
          rating: jsonDouble(attrs['ratings']) ?? 0,
          note: [
            if (jsonBool(attrs['hearing_impaired']) == true)
              dataText('mediaSubtitleHearingImpaired', '听障'),
            if (jsonBool(attrs['hd']) == true) 'HD',
            if (jsonIntOr(attrs['nb_cd'], 1) > 1)
              dataText(
                'mediaSubtitlePartsCount',
                '{n} 段（只取第 1 段）',
              ).replaceAll('{n}', '${jsonIntOr(attrs['nb_cd'], 1)}'),
          ].join(' · '),
          payload: {
            if (legacy != null) 'legacy_subtitle_id': '$legacy',
            if (fileId != null) 'file_id': '$fileId',
          },
        ),
      );
    }
    // 下载多的排前面（同分保持稳定：按标题）
    hits.sort((a, b) {
      final byDownloads = b.downloads.compareTo(a.downloads);
      if (byDownloads != 0) return byDownloads;
      return a.title.compareTo(b.title);
    });
    return hits;
  }

  @override
  Future<SubtitleDownload> download(
    SubtitleSearchHit hit, {
    String? apiKey,
  }) async {
    final legacy = hit.payload['legacy_subtitle_id'] ?? hit.id;
    if (legacy.isEmpty || legacy == 'null') {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.badResponse,
        dataText('mediaSubtitleNoDownloadFileId', '这条结果没有可下载的文件 id'),
      );
    }
    final uri = Uri.parse('$downloadBase/sub/$legacy');
    final res = await _http.get(uri);
    if (!res.ok) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.badResponse,
        dataText(
          'mediaSubtitleFileDownloadFailed',
          '字幕文件下载失败（HTTP {code}）',
        ).replaceAll('{code}', '${res.statusCode}'),
        statusCode: res.statusCode,
      );
    }
    final parsed = decodeSubtitlePayload(res.body, contentType: res.contentType);
    if (parsed == null) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.badResponse,
        dataText(
          'mediaSubtitleUnrecognizedSubtitle',
          '下载回来的不是可识别的字幕（可能是压缩包结构变了）',
        ),
      );
    }
    return parsed;
  }
}

// ------------------------------------------------ OpenSubtitles（老 REST 口）

/// OpenSubtitles 的**老 REST 口**（`rest.opensubtitles.org/search/...`）。
///
/// ★ r456 免密钥复探（起因：用户问「难道全世界就只有 OpenSubtitles 一个？Plex/VLC
///   也没让用户填 key」）：这个口**免密钥、免 UA、未见限流**，而且是**满目录**的 ——
///   中文**三档都有条目**（`chi` 简 / `zht` 繁 / `zhe` 双语），下载口直接给文本字幕。
///   逐字读数 → `docs/evidence-r456/host/r456_subtitle_sources_probe.txt`。
///
/// ⚠️ 四条硬约束（**全是实测出来的，不是猜的**；改这个类前先读这一段）：
///   1. **路径必须全小写**：路径里出现任何大写字母，服务端就 302 到
///      `https://_/search/<小写路径>` —— 目标主机**字面就是 `_`**，是个坏重定向，
///      客户端跟过去只会 `Could not resolve host: _`（变成"网络失败"，
///      **不是**"没找到"）。实测 `query-matrix` = 200 / `query-Matrix` = 302（5/5 稳定）。
///      ⇒ 本类把查询词一律 `toLowerCase()`。
///   2. **查询词用 `+` 连接**，且只取干净片名的字母数字 token：`%20` 与 `.` 同样会撞
///      那条坏重定向，而且 token 越少结果集越小越快
///      （`query-inception` = 16 KB/10 条/1.2 s，`query-inception+2010+1080p` = 168 KB/100 条）。
///   3. **`episode-` 不能进路径**（`…/season-1/episode-1/…` = 302）⇒ 每季结果拿回来后
///      在客户端按 `SeriesEpisode` 过滤。
///   4. **不支持哈希匹配**：`moviehash-…/moviebytesize-…` 也撞同一条坏 302
///      （[supportsHash] 因此是 false，如实标注，不要假装支持）。
///
/// ★ 语言码是 legacy 的（`chi`/`zht`/`zhe`/`eng`…），与 App 的 `zh-cn`/`zh-tw`/`en`
///   不是一套 ⇒ 用 [_legacyOpenSubtitlesLanguage] / [_appLanguageOfLegacy] 双向翻译。
class OpenSubtitlesRestSource implements SubtitleOnlineSource {
  OpenSubtitlesRestSource({SubtitleHttp? http})
    : _http = http ?? DartIoSubtitleHttp();

  final SubtitleHttp _http;

  static const String searchBase = 'https://rest.opensubtitles.org/search';

  @override
  String get id => 'opensubtitles-rest';

  @override
  String get label => 'OpenSubtitles REST';

  @override
  bool get requiresKey => false;

  /// 实测：该口的哈希搜索是坏的（坏 302），**不许**标 true
  @override
  bool get supportsHash => false;

  @override
  String get note => dataText(
    'mediaSubtitleSourceOpenSubtitlesRestNote',
    '免密钥；中文简体/繁体/双语都能搜到（按片名匹配，不支持哈希匹配）',
  );

  /// 电影与剧集都能走（剧集要求文件名里推得出季集 —— 只有季也能搜，见 [search]）
  static bool supportsFileName(String fileName) => true;

  @override
  Future<List<SubtitleSearchHit>> search(
    SubtitleSearchQuery query, {
    String? apiKey,
  }) async {
    final parsed = parseMediaFileName(query.fileName);
    final manual = query.title?.trim() ?? '';
    final title = manual.isNotEmpty ? manual : parsed.title;
    final key = _legacyQuerySegment(title);
    if (key.isEmpty) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.unsupported,
        dataText(
          'mediaSubtitleNoTitleFromFileName',
          '文件名里推不出片名，请在搜索框里手动输入片名',
        ),
      );
    }
    final season = parsed.season;
    final episode = parsed.episode;
    final codes = _legacyLanguageCodes(query.languages);
    if (codes.isEmpty) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.unsupported,
        dataText(
          'mediaSubtitleRestLanguageUnsupported',
          '这个语言组合在 OpenSubtitles 老接口上没有对应的语言码',
        ),
      );
    }
    final wanted = query.languages
        .map(_normalizeLanguage)
        .where((e) => e.isNotEmpty)
        .toSet();
    final hits = <SubtitleSearchHit>[];
    for (final code in codes) {
      // 契约：`query-<小写 token，+ 连接>[/season-<n>]/sublanguageid-<legacy 码>`
      final path = StringBuffer('query-')
        ..write(key)
        ..write(season == null ? '' : '/season-$season')
        ..write('/sublanguageid-$code');
      final res = await _http.get(Uri.parse('$searchBase/$path'));
      // ⚠️ 302 = 那条坏重定向（大写/点号/非法参数）；404 = 这个语言没词条。
      // 两者都**不是错误**：如实当"这个语言没结果"，别把界面吓成"网络失败"。
      if (res.statusCode == 302 || res.statusCode == 404) continue;
      if (!res.ok) {
        throw SubtitleSearchFailure(
          res.statusCode == 429 || res.statusCode == 503
              ? SubtitleSearchFailureKind.rateLimited
              : SubtitleSearchFailureKind.badResponse,
          dataText(
            'mediaSubtitleRestHttp',
            'OpenSubtitles 老接口返回 HTTP {code}',
          ).replaceAll('{code}', '${res.statusCode}'),
          statusCode: res.statusCode,
        );
      }
      // `jsonMapList` 负责"不是对象就跳过"（同族宽松助手，见 lib/src/core/json_coerce.dart）
      for (final row in jsonMapList(_decodeJsonArray(res))) {
        final language = _appLanguageOfLegacy(jsonStr(row['SubLanguageID']));
        if (wanted.isNotEmpty && !_languageMatches(wanted, language)) {
          continue;
        }
        final rowSeason = jsonInt(row['SeriesSeason']);
        final rowEpisode = jsonInt(row['SeriesEpisode']);
        // 契约只允许用 `season-` 过滤（`episode-` 会 302）⇒ 集号在这里过滤。
        // 字段存在且非 0 时严格要求相等；缺失时保留（并在备注里如实写"集号未知"）。
        if (season != null && rowSeason != null && rowSeason > 0 && rowSeason != season) {
          continue;
        }
        if (episode != null && rowEpisode != null && rowEpisode > 0 && rowEpisode != episode) {
          continue;
        }
        final link = jsonStr(row['SubDownloadLink']).isNotEmpty
            ? jsonStr(row['SubDownloadLink'])
            : jsonStr(row['ZipDownloadLink']);
        if (link.isEmpty) continue;
        final fileName = jsonStr(row['SubFileName']);
        // ⚠️ 局部变量**不能叫 `id`**：那会遮蔽 `SubtitleOnlineSource.id`，
        //    于是 `sourceId:` 写到的是"这条字幕的行号"⇒ 真机上点下载时
        //    `service.sourceById(hit.sourceId)` 找不到源，界面报
        //    「这个源已经不可用了（OpenSubtitles REST）」（r456 真机抓到）。
        final rowId = jsonStr(row['IDSubtitle']).isNotEmpty
            ? jsonStr(row['IDSubtitle'])
            : jsonStr(row['IDSubtitleFile']);
        hits.add(
          SubtitleSearchHit(
            sourceId: id,
            sourceLabel: label,
            id: rowId.isEmpty ? link : rowId,
            title: fileName.isEmpty ? jsonStr(row['MovieReleaseName']) : fileName,
            language: language,
            release: jsonStr(row['MovieReleaseName']),
            downloads: jsonInt(row['SubDownloadsCnt']) ?? 0,
            note: [
              if (rowSeason != null && rowSeason > 0 && rowEpisode != null && rowEpisode > 0)
                'S${rowSeason.toString().padLeft(2, '0')}'
                    'E${rowEpisode.toString().padLeft(2, '0')}'
              else if (season != null)
                dataText('mediaSubtitleEpisodeUnknown', '集号未知'),
              if (jsonStr(row['SubFormat']).isNotEmpty) jsonStr(row['SubFormat']),
              if (jsonStr(row['SubEncoding']).isNotEmpty) jsonStr(row['SubEncoding']),
            ].join(' · '),
            payload: {'download_link': link, 'file_name': fileName},
          ),
        );
      }
    }
    // ★ 排序：**中文系命中先排**（界面「中文优先」档的语义），各自内部再按下载量降序。
    //   为什么必须这样排 —— 这个口太"慷慨"：实测 `query-citizen+kane/sublanguageid-eng`
    //   回 **56 条 / 97 KB**，纯按下载量排会把 3 条中文命中挤到第 2–4 位之后；
    //   再叠加下面的上限，中文就一定留在第一屏。
    hits.sort((a, b) {
      final ac = _isChineseLanguage(a.language) ? 0 : 1;
      final bc = _isChineseLanguage(b.language) ? 0 : 1;
      if (ac != bc) return ac - bc;
      return b.downloads.compareTo(a.downloads);
    });
    // ★ 每源上限 40 条：面板一次列几百行没有意义（而且这个口回 100 条是常态）。
    //   上限**在排序之后**才切，所以"中文 + 下载最多的英文"这一组不会被切掉。
    return hits.length <= _maxHits ? hits : hits.sublist(0, _maxHits);
  }

  /// 一次搜索最多回给界面多少条（见 [search] 里的理由）
  static const int _maxHits = 40;

  @override
  Future<SubtitleDownload> download(
    SubtitleSearchHit hit, {
    String? apiKey,
  }) async {
    final link = hit.payload['download_link'] ?? '';
    if (link.isEmpty) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.badResponse,
        dataText('mediaSubtitleNoDownloadUri', '这条结果没有下载地址'),
      );
    }
    final res = await _http.get(Uri.parse(link));
    if (!res.ok) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.badResponse,
        dataText(
          'mediaSubtitleFileDownloadFailed',
          '字幕文件下载失败（HTTP {code}）',
        ).replaceAll('{code}', '${res.statusCode}'),
        statusCode: res.statusCode,
      );
    }
    final parsed = decodeSubtitlePayload(
      res.body,
      contentType: res.contentType,
      preferredName: hit.payload['file_name'] ?? '',
    );
    if (parsed == null) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.badResponse,
        dataText(
          'mediaSubtitleUnrecognizedSubtitle',
          '下载回来的不是可识别的字幕（可能是压缩包结构变了）',
        ),
      );
    }
    return parsed;
  }
}

/// 干净片名 → 老 REST 口的查询段：**全小写**、只留字母数字（含中文）token、`+` 连接。
///
/// ★ 为什么要"只留字母数字"：`.` 与 `%20` 都会让服务端走那条坏 302（见类注释），
///   而片名里的年份/画质标签对 fulltext 匹配只是噪声（`query-inception` 比
///   `query-inception+2010+1080p` 又准又快）。
String _legacyQuerySegment(String title) {
  final tokens = title
      .toLowerCase()
      .replaceAll(RegExp(r"[^0-9a-z\u00c0-\uffff]+"), ' ')
      .split(' ')
      .where((e) => e.isNotEmpty)
      .toList();
  return tokens.join('+');
}

/// App 语言码 → 这个源要请求的 legacy 语言码（**有界**、去重、保序）
List<String> _legacyLanguageCodes(List<String> languages) {
  final wanted = languages
      .map(_normalizeLanguage)
      .where((e) => e.isNotEmpty)
      .toList();
  if (wanted.isEmpty) {
    // "任意语言"档：给一个有界默认（每个码 = 一次请求），不拿 all（实测 302）
    return const ['chi', 'eng'];
  }
  final out = <String>[];
  for (final l in wanted) {
    final code = _legacyOpenSubtitlesLanguage(l);
    if (code != null && !out.contains(code)) out.add(code);
  }
  return out;
}

/// App 语言码 → legacy 语言码（不认 → null，跳过该语言）
///
/// ★ `zh`（泛指中文）映射到 **`zhe`（简英双语）**：这样"中文优先"档
///   （`zh-cn` / `zh` / `zh-tw` / `en`）正好取到**简体 + 双语 + 繁体 + 英文**四类，
///   一个语言一次请求、不重复。
String? _legacyOpenSubtitlesLanguage(String normalized) {
  const map = <String, String>{
    'zh-cn': 'chi',
    'zh-hans': 'chi',
    'chs': 'chi',
    'chi': 'chi',
    'zh': 'zhe',
    'zh-bilingual': 'zhe',
    'zhe': 'zhe',
    'zh-tw': 'zht',
    'zh-hk': 'zht',
    'zh-hant': 'zht',
    'cht': 'zht',
    'zht': 'zht',
    'en': 'eng',
    'ja': 'jpn',
    'ko': 'kor',
    'fr': 'fre',
    'de': 'ger',
    'es': 'spa',
    'pt': 'por',
    'ru': 'rus',
    'it': 'ita',
  };
  return map[normalized.trim().toLowerCase()];
}

/// legacy 语言码 → App 语言码（界面/过滤都用 App 这一套）
String _appLanguageOfLegacy(String raw) {
  const map = <String, String>{
    'chi': 'zh-cn',
    'zhe': 'zh-cn',
    'zht': 'zh-tw',
    'eng': 'en',
    'jpn': 'ja',
    'kor': 'ko',
    'fre': 'fr',
    'ger': 'de',
    'spa': 'es',
    'por': 'pt',
    'rus': 'ru',
    'ita': 'it',
  };
  final code = raw.trim().toLowerCase();
  return map[code] ?? _normalizeLanguage(code);
}

/// HTTP 应答 → **JSON 数组**（老 REST 口回的是数组，不是对象）
///
/// 与 [_decodeJson] 同族：失败 → badResponse，不抛裸 FormatException。
List<Object?> _decodeJsonArray(SubtitleHttpResponse res) {
  try {
    final decoded = jsonDecode(res.text);
    if (decoded is List) return decoded;
  } catch (_) {
    // 落到下面统一抛
  }
  throw SubtitleSearchFailure(
    SubtitleSearchFailureKind.badResponse,
    dataText(
      'mediaSubtitleBadJson',
      '字幕源返回的不是合法 JSON（HTTP {code}）',
    ).replaceAll('{code}', '${res.statusCode}'),
    statusCode: res.statusCode,
  );
}

// ------------------------------------------------------------------ gestdown

/// gestdown（`api.gestdown.info`）：**免密钥、实测端到端可用**，但只覆盖剧集。
///
/// 搜索路径：文件名 → `S01E02` → `/shows/search/<title>` → `/subtitles/get/<show>/<s>/<e>/<lang>`
/// → 每条结果的 `downloadUri` → `GET https://api.gestdown.info<uri>`。
class GestdownSource implements SubtitleOnlineSource {
  GestdownSource({SubtitleHttp? http})
    : _http = http ?? DartIoSubtitleHttp();

  final SubtitleHttp _http;

  static const String base = 'https://api.gestdown.info';

  @override
  String get id => 'gestdown';

  @override
  String get label => 'Gestdown';

  @override
  bool get requiresKey => false;

  @override
  bool get supportsHash => false;

  @override
  String get note => dataText(
    'mediaSubtitleSourceGestdownNote',
    '免密钥；只覆盖剧集（文件名需含 S01E02 这类季集），实测语言以英/法为主',
  );

  /// 这个文件名能不能走 gestdown（推得出季集）
  static bool supportsFileName(String fileName) =>
      parseMediaFileName(fileName).isEpisode;

  @override
  Future<List<SubtitleSearchHit>> search(
    SubtitleSearchQuery query, {
    String? apiKey,
  }) async {
    final parsed = parseMediaFileName(query.fileName);
    final title = (query.title?.trim().isNotEmpty ?? false)
        ? query.title!.trim()
        : parsed.title;
    final season = parsed.season;
    final episode = parsed.episode;
    if (title.isEmpty || season == null || episode == null) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.unsupported,
        dataText(
          'mediaSubtitleGestdownEpisodesOnly',
          'Gestdown 只支持剧集：文件名里需要有 S01E02 这样的季集号',
        ),
      );
    }
    final show = await _resolveShow(title);
    if (show == null) {
      return const [];
    }
    final wanted = query.languages
        .map(_normalizeLanguage)
        .where((e) => e.isNotEmpty)
        .toList();
    // gestdown 只认两字母码（en/fr…）；非法码会回 423，所以先映射
    final langs = <String>[
      for (final l in (wanted.isEmpty ? ['en'] : wanted))
        if (_gestdownLanguage(l) != null) _gestdownLanguage(l)!,
    ];
    final hits = <SubtitleSearchHit>[];
    for (final lang in langs.toSet()) {
      final uri = Uri.parse(
        '$base/subtitles/get/$show/$season/$episode/$lang',
      );
      final res = await _http.get(uri);
      if (res.statusCode == 423 || res.statusCode == 404) {
        // 该语言没有词条（**不是错误**，如实当空结果）
        continue;
      }
      if (!res.ok) {
        throw SubtitleSearchFailure(
          res.statusCode == 429 || res.statusCode == 503
              ? SubtitleSearchFailureKind.rateLimited
              : SubtitleSearchFailureKind.badResponse,
          dataText(
            'mediaSubtitleGestdownHttp',
            'Gestdown 返回 HTTP {code}',
          ).replaceAll('{code}', '${res.statusCode}'),
          statusCode: res.statusCode,
        );
      }
      final decoded = _decodeJson(res);
      for (final row in jsonMapList(decoded['matchingSubtitles'])) {
        final downloadUri = jsonStr(row['downloadUri']);
        if (downloadUri.isEmpty) continue;
        hits.add(
          SubtitleSearchHit(
            sourceId: id,
            sourceLabel: label,
            id: jsonStr(row['subtitleId']).isEmpty
                ? downloadUri
                : jsonStr(row['subtitleId']),
            title: '${jsonStr(row['language']).isEmpty ? lang : jsonStr(
              row['language'],
            )} · S${season.toString().padLeft(2, '0')}'
                'E${episode.toString().padLeft(2, '0')}',
            language: lang,
            release: jsonStr(row['version']),
            note: [
              if (jsonBool(row['hearingImpaired']) == true)
                dataText('mediaSubtitleHearingImpaired', '听障'),
              if (jsonBool(row['hd']) == true) 'HD',
              if (jsonBool(row['corrected']) == true)
                dataText('mediaSubtitleProofread', '已校对'),
            ].join(' · '),
            payload: {'download_uri': downloadUri, 'show': show},
          ),
        );
      }
    }
    return hits;
  }

  @override
  Future<SubtitleDownload> download(
    SubtitleSearchHit hit, {
    String? apiKey,
  }) async {
    final path = hit.payload['download_uri'] ?? '';
    if (path.isEmpty) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.badResponse,
        dataText('mediaSubtitleNoDownloadUri', '这条结果没有下载地址'),
      );
    }
    final uri = path.startsWith('http') ? Uri.parse(path) : Uri.parse('$base$path');
    final res = await _http.get(uri);
    if (!res.ok) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.badResponse,
        dataText(
          'mediaSubtitleGestdownDownloadFailed',
          'Gestdown 字幕下载失败（HTTP {code}）',
        ).replaceAll('{code}', '${res.statusCode}'),
        statusCode: res.statusCode,
      );
    }
    final parsed = decodeSubtitlePayload(res.body, contentType: res.contentType);
    if (parsed == null) {
      throw SubtitleSearchFailure(
        SubtitleSearchFailureKind.badResponse,
        dataText(
          'mediaSubtitleUnrecognizedContent',
          '下载回来的内容不是可识别的字幕',
        ),
      );
    }
    return parsed;
  }

  /// 片名 → showId（按名字规范化后**精确**匹配，匹配不到再退回第一个结果）
  Future<String?> _resolveShow(String title) async {
    final uri = Uri.parse('$base/shows/search/${Uri.encodeComponent(title)}');
    final res = await _http.get(uri);
    if (!res.ok) {
      throw SubtitleSearchFailure(
        res.statusCode == 429 || res.statusCode == 503
            ? SubtitleSearchFailureKind.rateLimited
            : SubtitleSearchFailureKind.badResponse,
        dataText(
          'mediaSubtitleGestdownShowFailed',
          'Gestdown 剧集检索失败（HTTP {code}）',
        ).replaceAll('{code}', '${res.statusCode}'),
        statusCode: res.statusCode,
      );
    }
    final decoded = _decodeJson(res);
    final shows = jsonMapList(decoded['shows']);
    if (shows.isEmpty) return null;
    final target = _normalizeTitle(title);
    for (final show in shows) {
      if (_normalizeTitle(jsonStr(show['name'])) == target) {
        final id = jsonStr(show['id']);
        if (id.isNotEmpty) return id;
      }
    }
    final first = jsonStr(shows.first['id']);
    return first.isEmpty ? null : first;
  }
}

// ------------------------------------------------------------------ 服务

/// 一次多源搜索的结果（成功项 + 每个源各自的失败）
class SubtitleSearchOutcome {
  const SubtitleSearchOutcome({
    required this.hits,
    required this.failures,
    required this.sourcesTried,
  });

  final List<SubtitleSearchHit> hits;
  final List<SubtitleSourceFailure> failures;

  /// 这次实际问过的源个数（用来区分"没找到"与"全都失败了"）
  final int sourcesTried;

  bool get isEmpty => hits.isEmpty;

  /// 所有源都失败了（界面给"失败 + 重试"，而不是"没找到"）
  bool get allFailed =>
      hits.isEmpty && sourcesTried > 0 && failures.length == sourcesTried;
}

/// 某一个源的失败（界面按源分别显示原因）
class SubtitleSourceFailure {
  const SubtitleSourceFailure({
    required this.sourceId,
    required this.sourceLabel,
    required this.failure,
  });

  final String sourceId;
  final String sourceLabel;
  final SubtitleSearchFailure failure;
}

/// 多源聚合 + 缓存下载
class SubtitleSearchService {
  SubtitleSearchService({required List<SubtitleOnlineSource> sources})
    : sources = List.unmodifiable(sources);

  /// 默认源集合：
  ///   * `OpenSubtitles`（新口，支持哈希匹配；匿名档有配额、要填 Key 才稳）
  ///   * `OpenSubtitles REST`（**r456 新加的老口：免密钥、中文三档可用**，无哈希）
  ///   * `Gestdown`（免密钥，只覆盖剧集）
  factory SubtitleSearchService.defaults({SubtitleHttp? http}) =>
      SubtitleSearchService(
        sources: [
          OpenSubtitlesSource(http: http),
          OpenSubtitlesRestSource(http: http),
          GestdownSource(http: http),
        ],
      );

  final List<SubtitleOnlineSource> sources;

  SubtitleOnlineSource? sourceById(String id) {
    for (final s in sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 依次问每个源；单源失败**不拖垮**其它源，失败项照实带回界面。
  Future<SubtitleSearchOutcome> search(
    SubtitleSearchQuery query, {
    String? apiKey,
  }) async {
    final hits = <SubtitleSearchHit>[];
    final failures = <SubtitleSourceFailure>[];
    var tried = 0;
    for (final source in sources) {
      tried++;
      try {
        hits.addAll(await source.search(query, apiKey: apiKey));
      } on SubtitleSearchFailure catch (e) {
        failures.add(
          SubtitleSourceFailure(
            sourceId: source.id,
            sourceLabel: source.label,
            failure: e,
          ),
        );
      } catch (e) {
        failures.add(
          SubtitleSourceFailure(
            sourceId: source.id,
            sourceLabel: source.label,
            failure: SubtitleSearchFailure(
              SubtitleSearchFailureKind.badResponse,
              dataText(
                'mediaSubtitleParseResultFailed',
                '解析 {source} 的结果失败：{err}',
              )
                  .replaceAll('{source}', source.label)
                  .replaceAll('{err}', '$e'),
            ),
          ),
        );
      }
    }
    return SubtitleSearchOutcome(
      hits: hits,
      failures: failures,
      sourcesTried: tried,
    );
  }
}

// ------------------------------------------------------------------ 缓存

/// 缓存目录里的一条记录
class SubtitleCacheEntry {
  const SubtitleCacheEntry({required this.fileName, required this.size});

  final String fileName;
  final int size;
}

/// 在线字幕的磁盘缓存（App 缓存目录；调用方注入目录，单测给临时目录）
/// 缓存落盘 / 回读的**存储口**。
///
/// 为什么要抽出这一层（不是为抽象而抽象）：widget 测试里**真磁盘 IO 没法在
/// `testWidgets` 的假时钟里跑完** —— 发起时挂在假 zone 上，完成回调收不到；
/// 想在 `runAsync` 里发起又会挂死（本轮实测挂死过三次）。所以界面测试用
/// [MemorySubtitleCacheBackend]，真实磁盘路径由 `media_subtitle_search_test.dart`
/// （纯 Dart 测试，没有假时钟）覆盖 —— 两条路都有证据，谁也没被跳过。
abstract class SubtitleCacheBackend {
  Future<void> write(String fileName, List<int> bytes);

  Future<Uint8List?> read(String fileName);

  Future<List<SubtitleCacheEntry>> list();

  Future<int> clear();
}

/// `dart:io` 实现：落到 [SubtitleCacheStore.directory] 指向的目录
class DirectorySubtitleCacheBackend implements SubtitleCacheBackend {
  DirectorySubtitleCacheBackend(this.directory);

  final Future<Directory> Function() directory;

  Future<Directory> _ensureDir() async {
    final dir = await directory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  File _file(Directory dir, String fileName) =>
      File('${dir.path}${Platform.pathSeparator}$fileName');

  @override
  Future<void> write(String fileName, List<int> bytes) async {
    final file = _file(await _ensureDir(), fileName);
    // 先写 `.part` 再改名：半截文件绝不冒充成品（与端侧模型保管库同一条规矩）
    final part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(file.path);
  }

  @override
  Future<Uint8List?> read(String fileName) async {
    if (fileName.isEmpty) return null;
    final file = _file(await _ensureDir(), fileName);
    if (!await file.exists()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<SubtitleCacheEntry>> list() async {
    final dir = await _ensureDir();
    final out = <SubtitleCacheEntry>[];
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final base = e.uri.pathSegments.isEmpty ? e.path : e.uri.pathSegments.last;
      if (!base.startsWith(kSubtitleCachePrefix)) continue;
      try {
        out.add(SubtitleCacheEntry(fileName: base, size: await e.length()));
      } catch (_) {
        // 读不到长度就当它不存在（不因为一条坏文件让列表失败）
      }
    }
    return out;
  }

  @override
  Future<int> clear() async {
    final dir = await _ensureDir();
    var removed = 0;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final base = e.uri.pathSegments.isEmpty ? e.path : e.uri.pathSegments.last;
      if (!base.startsWith(kSubtitleCachePrefix)) continue;
      try {
        await e.delete();
        removed++;
      } catch (_) {}
    }
    return removed;
  }
}

/// 内存实现（widget 测试用；语义与磁盘实现一致）
class MemorySubtitleCacheBackend implements SubtitleCacheBackend {
  final Map<String, Uint8List> _files = {};

  /// 只留缓存前缀的文件（与磁盘实现同口径）
  Map<String, Uint8List> get files => {
    for (final e in _files.entries)
      if (e.key.startsWith(kSubtitleCachePrefix)) e.key: e.value,
  };

  @override
  Future<void> write(String fileName, List<int> bytes) async {
    _files[fileName] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> read(String fileName) async => _files[fileName];

  @override
  Future<List<SubtitleCacheEntry>> list() async {
    final out = <SubtitleCacheEntry>[];
    for (final e in files.entries) {
      out.add(SubtitleCacheEntry(fileName: e.key, size: e.value.length));
    }
    return out;
  }

  @override
  Future<int> clear() async {
    final removed = files.length;
    _files.clear();
    return removed;
  }
}

class SubtitleCacheStore {
  /// 二选一：给 [directory] 就是真实磁盘（生产），给 [backend] 就是替身（测试）
  factory SubtitleCacheStore({
    Future<Directory> Function()? directory,
    SubtitleCacheBackend? backend,
  }) {
    if (backend != null) {
      return SubtitleCacheStore._(directory: directory, backend: backend);
    }
    if (directory == null) {
      throw ArgumentError('SubtitleCacheStore 需要 directory 或 backend 之一');
    }
    return SubtitleCacheStore._(
      directory: directory,
      backend: DirectorySubtitleCacheBackend(directory),
    );
  }

  SubtitleCacheStore._({required this.directory, required this.backend});

  /// 缓存目录提供者（生产 = `getApplicationCacheDirectory()`；用 backend 时可为 null）
  final Future<Directory> Function()? directory;

  /// 真正落盘/回读的实现
  final SubtitleCacheBackend backend;

  /// 磁盘上存的文件名（`subtitle_<媒体名>.<源>.<hitId>.<ext>`，**确定性**）
  ///
  /// 确定性的意义：同一个媒体的同一条结果重复下载/重启后回读都用同一个名字，
  /// 记忆（`MediaPlaybackStore.saveSubtitle`）里存这个名字就够。
  static String fileNameFor({
    required String mediaFileName,
    required String sourceId,
    required String hitId,
    required SubtitleFormat format,
  }) {
    final stem = _sanitize(fileNameStem(mediaFileName));
    final id = _sanitize(hitId);
    return '$kSubtitleCachePrefix$stem.$sourceId.$id.${format.code}';
  }

  /// 写一条（覆盖同名）；返回落盘文件名
  Future<String> write({
    required String fileName,
    required List<int> bytes,
  }) async {
    await backend.write(fileName, bytes);
    return fileName;
  }

  Future<Uint8List?> read(String fileName) => backend.read(fileName);

  /// 读回一条**已缓存**的字幕（重启后用回来；文件不在 → null，如实降级）
  Future<SubtitleDownload?> load(String fileName) async {
    final bytes = await read(fileName);
    if (bytes == null || bytes.isEmpty) return null;
    final format = subtitleFormatOf(fileName);
    if (format == null) return null;
    return SubtitleDownload(fileName: fileName, bytes: bytes, format: format);
  }

  Future<List<SubtitleCacheEntry>> list() => backend.list();

  /// 清空（设置/排障入口用）
  Future<int> clear() => backend.clear();

  /// 下载 + 存盘（一次到位；返回落盘文件名）
  Future<({String fileName, SubtitleDownload download})> fetchAndStore({
    required SubtitleOnlineSource source,
    required SubtitleSearchHit hit,
    required String mediaFileName,
    String? apiKey,
  }) async {
    final download = await source.download(hit, apiKey: apiKey);
    final fileName = fileNameFor(
      mediaFileName: mediaFileName,
      sourceId: source.id,
      hitId: hit.id,
      format: download.format,
    );
    await write(fileName: fileName, bytes: download.bytes);
    return (
      fileName: fileName,
      download: SubtitleDownload(
        fileName: fileName,
        bytes: download.bytes,
        format: download.format,
      ),
    );
  }
}

// ------------------------------------------------------------------ 工具

/// HTTP 应答 → JSON（失败 → badResponse，不抛裸 FormatException）
Map<String, Object?> _decodeJson(SubtitleHttpResponse res) {
  try {
    final decoded = jsonDecode(res.text);
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) return decoded.cast<String, Object?>();
  } catch (_) {
    // 落到下面统一抛
  }
  throw SubtitleSearchFailure(
    res.statusCode == 403 || res.statusCode == 401
        ? SubtitleSearchFailureKind.keyRejected
        : SubtitleSearchFailureKind.badResponse,
    dataText(
      'mediaSubtitleBadJson',
      '字幕源返回的不是合法 JSON（HTTP {code}）',
    ).replaceAll('{code}', '${res.statusCode}'),
    statusCode: res.statusCode,
  );
}

/// 下载回来的字节 → 一条字幕。
///
/// 认三种形态（实测都出现过）：
///   1. **zip**（OpenSubtitles `dl…/download/sub/<id>` 就是 zip，含 `.nfo` + `.srt`）
///      → 取第一个 srt/ass/ssa/vtt；
///   2. 纯文本（gestdown 直接回 `text/srt`）→ 按 `-->` / `[Events]` 猜格式；
///   3. 其它 → null（调用方报"不是可识别的字幕"）。
SubtitleDownload? decodeSubtitlePayload(
  List<int> bytes, {
  String contentType = '',
  String preferredName = '',
}) {
  if (bytes.isEmpty) return null;
  // ★ r456：**裸 gzip 文件**（`rest.opensubtitles.org` 的 `SubDownloadLink` 回的就是
  //   `….gz`，`Content-Type: application/force-download` ⇒ HTTP 层的 gzip 自动解
  //   不生效，得自己解）。解完再按文本走一遍（保留下载名与后缀判格式）。
  if (bytes.length > 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
    try {
      return decodeSubtitlePayload(
        gzip.decode(bytes),
        contentType: contentType,
        preferredName: preferredName,
      );
    } catch (_) {
      return null;
    }
  }
  final isZip = bytes.length > 3 && bytes[0] == 0x50 && bytes[1] == 0x4B;
  if (isZip) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);
      for (final f in archive) {
        if (!f.isFile) continue;
        final format = subtitleFormatOf(f.name);
        if (format == null) continue;
        final content = Uint8List.fromList(f.content as List<int>);
        if (content.isEmpty) continue;
        return SubtitleDownload(
          fileName: f.name.split('/').last,
          bytes: content,
          format: format,
        );
      }
    } catch (_) {
      return null;
    }
    return null;
  }
  final text = decodeBookText(bytes);
  final fromName = subtitleFormatOf(preferredName);
  if (fromName != null) {
    return SubtitleDownload(
      fileName: preferredName,
      bytes: Uint8List.fromList(bytes),
      format: fromName,
    );
  }
  final trimmed = text.trimLeft();
  SubtitleFormat? format;
  if (trimmed.startsWith('WEBVTT')) {
    format = SubtitleFormat.vtt;
  } else if (trimmed.contains('[Events]') ||
      trimmed.toLowerCase().contains('dialogue:')) {
    format = SubtitleFormat.ass;
  } else if (trimmed.contains('-->')) {
    format = SubtitleFormat.srt;
  } else if (contentType.contains('ass')) {
    format = SubtitleFormat.ass;
  } else if (contentType.contains('vtt')) {
    format = SubtitleFormat.vtt;
  } else if (contentType.contains('srt') || contentType.contains('text')) {
    format = SubtitleFormat.srt;
  }
  if (format == null) return null;
  return SubtitleDownload(
    fileName: preferredName.isEmpty
        ? 'online.${format.code}'
        : preferredName,
    bytes: Uint8List.fromList(bytes),
    format: format,
  );
}

/// 语言码规范化（`zh_CN` → `zh-cn`；`English` → `en`）
String _normalizeLanguage(String raw) {
  var code = raw.trim().toLowerCase().replaceAll('_', '-');
  if (code.isEmpty) return '';
  const aliases = <String, String>{
    'english': 'en',
    'eng': 'en',
    'chinese': 'zh-cn',
    'chi': 'zh',
    'zho': 'zh',
    'chs': 'zh-cn',
    'cht': 'zh-tw',
    'hans': 'zh-cn',
    'hant': 'zh-tw',
    'japanese': 'ja',
    'jpn': 'ja',
    'korean': 'ko',
    'kor': 'ko',
    'french': 'fr',
    'fre': 'fr',
    'fra': 'fr',
    'german': 'de',
    'ger': 'de',
    'deu': 'de',
    'spanish': 'es',
    'spa': 'es',
    'portuguese': 'pt',
    'por': 'pt',
    'russian': 'ru',
    'rus': 'ru',
  };
  return aliases[code] ?? code;
}

/// 这条语言码算不算"中文系"（`zh` / `zh-cn` / `zh-tw` …）
bool _isChineseLanguage(String language) =>
    language.trim().toLowerCase().split('-').first == 'zh';

/// 目标语言集合里有没有命中这条结果的语言（中文系宽松命中）
bool _languageMatches(Set<String> wanted, String actual) {
  if (actual.isEmpty) return false;
  if (wanted.contains(actual)) return true;
  final a = actual.split('-').first;
  for (final w in wanted) {
    if (w.split('-').first == a) return true;
  }
  return false;
}

/// 目标语言 → gestdown 认的两字母码（不认 → null，直接跳过该语言）
String? _gestdownLanguage(String normalized) {
  const supported = {'en', 'fr', 'es', 'de', 'pt', 'it', 'nl', 'pl', 'ru'};
  final base = normalized.split('-').first;
  if (supported.contains(base)) return base;
  // 中文 gestdown 没有词条（实测 zh 回 200 但空列表）——不假装支持
  return null;
}

String _normalizeTitle(String raw) =>
    raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '').trim();

/// 缓存文件名里只允许 `[A-Za-z0-9._-]`（避免路径穿越 / 空格）
String _sanitize(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  final trimmed = cleaned.replaceAll(RegExp(r'^[._]+|[._]+$'), '');
  if (trimmed.isEmpty) return 'x';
  return trimmed.length <= 60 ? trimmed : trimmed.substring(0, 60);
}
