// 网络电台：**播放列表解析**（`.pls` / `.m3u` → 真正的流地址）。
//
// ════════════════════════════════════════════════════════════════════════
// ★★★ 为什么需要这一步（第 392 轮，DA32 的修法组成）
// ════════════════════════════════════════════════════════════════════════
//
// `SYNO.AudioStation.Radio:list` 展开到分类叶子（`container=SHOUTcast_<genre>`）后，
// 电台项的 `url` 来自 SHOUTcast 目录 —— 权威样本是分包内自带的
// `etc/radio/shoutcast_<genre>.json`（26 个分类文件，字段
// `bitrate/desc/mimetype/name/url`），逐字：
//
// ```json
// {"bitrate":"128","desc":"MP3 (128 kbps)","mimetype":"audio/mpeg",
//  "name":".977 The Hitz Channel - 977MUSIC.COM - ...",
//  "url":"http://yp.shoutcast.com/sbin/tunein-station.pls?id=1280356"}
// ```
//
// ⇒ 这些 `url` 是 **`.pls` 播放列表**，不是音频流本身。原生播放器
// （Android 走 ExoPlayer）不解析 `.pls`，直接把这个地址交给它只会起播失败。
// 所以播放前要先 GET 它、取出里面真正的流地址。
//
// `.pls` 是 INI 风格（`[playlist]` / `File1=http://…` / `Title1=…`），
// `.m3u`/`.m3u8`（音频场景）是"每行一个地址 + `#` 注释"。两者都只有
// **第一条 `FileN=` / 第一行非注释地址**才是我们要的（多流电台的备选流
// 由播放器自己重试，不在这里做故障转移）。
//
// ★ HTTP 出口**可注入**：单测里换成假实现，离线跑、不碰网络。
//   ★★ 不共用 NAS 的 `DioFactory` 信任链：电台目录是**公网**主机（公共 CA 签发），
//   拿 NAS 那把"自签/主机名不匹配放行"的尺子去请求它，等于把放宽校验用错地方
//   （与 `audio_lyrics.dart` 同一条纪律）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一次 GET 的结果（只需要状态码 + 文本正文）。
class RadioStreamHttpResponse {
  const RadioStreamHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// HTTP 出口（可注入）。
abstract interface class RadioStreamHttp {
  Future<RadioStreamHttpResponse> get(Uri uri);
}

/// 真实实现：`dart:io` 的 `HttpClient`（平台默认 TLS 校验）。
class IoRadioStreamHttp implements RadioStreamHttp {
  IoRadioStreamHttp({HttpClient? client, Duration? timeout})
    : _client = client,
      _timeout = timeout ?? const Duration(seconds: 10);

  final HttpClient? _client;
  final Duration _timeout;

  /// 播放列表很小（`.pls` 通常 < 2 KB）；给个上限免得被异常响应拖死。
  static const int kMaxBytes = 64 * 1024;

  /// 目录站/电台站都会看 UA；不做鉴权用。
  static const String kUserAgent = 'synhub/1.0 (Android; internet radio)';

  @override
  Future<RadioStreamHttpResponse> get(Uri uri) async {
    final client = _client ?? (HttpClient()..connectionTimeout = _timeout);
    try {
      final req = await client.getUrl(uri).timeout(_timeout);
      req.headers.set(HttpHeaders.userAgentHeader, kUserAgent);
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final res = await req.close().timeout(_timeout);
      final buf = StringBuffer();
      var bytes = 0;
      await for (final chunk in res.timeout(_timeout)) {
        bytes += chunk.length;
        buf.write(utf8.decode(chunk, allowMalformed: true));
        if (bytes >= kMaxBytes) break;
      }
      return RadioStreamHttpResponse(
        statusCode: res.statusCode,
        body: buf.toString(),
      );
    } finally {
      // 自己建的 client 用完就关；外部传进来的由调用方管（测试复用）。
      if (_client == null) client.close(force: true);
    }
  }
}

/// 地址看起来是不是**播放列表**（需要先解析）。
///
/// 判定只看路径后缀（`.pls` / `.m3u` / `.m3u8`），**不看 `Content-Type`**：
/// 这一步发生在发请求之前。
bool isPlaylistUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return path.endsWith('.pls') ||
      path.endsWith('.m3u') ||
      path.endsWith('.m3u8');
}

/// 从播放列表正文里取出**第一条流地址**（相对地址按 [baseUrl] 解析）。
///
/// 支持两种形态：
/// * `.pls`（INI）：`File1=…`（也认 `file1=…` 大小写）；`#`/`;` 开头是注释；
/// * `.m3u`/`.m3u8`：**第一行非空、非 `#` 开头**的内容。
///
/// 返回 `null` = **没解析出可用地址**（调用方按"回落到原地址试一次"处理，
/// 不许把 `null` 当成"能播"）。
String? parsePlaylistStreamUrl(String body, {required String baseUrl}) {
  String? raw;
  for (final line in const LineSplitter().convert(body)) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('#') || t.startsWith(';')) continue;
    // `.pls`：`File1=<url>`（键名大小写不敏感；值里可能带引号）
    final eq = t.indexOf('=');
    if (eq > 0) {
      final key = t.substring(0, eq).trim().toLowerCase();
      if (key.startsWith('file')) {
        raw = t.substring(eq + 1).trim();
        break;
      }
      // 其它 INI 键（Title1/NumberOfEntries…）跳过
      continue;
    }
    // `.m3u`：裸地址行
    if (t.startsWith('http://') ||
        t.startsWith('https://') ||
        t.startsWith('/') ||
        t.startsWith('//')) {
      raw = t;
      break;
    }
  }
  if (raw == null || raw.isEmpty) return null;
  raw = raw.replaceAll('"', '');
  final base = Uri.tryParse(baseUrl);
  final direct = Uri.tryParse(raw);
  if (direct != null && direct.hasScheme) {
    return direct.toString();
  }
  // 相对地址：按播放列表自身的地址解析
  if (base != null) {
    final resolved = base.resolve(raw);
    return resolved.hasScheme ? resolved.toString() : null;
  }
  return null;
}

/// 解析结果（**能播的地址 + 是哪来的**，界面/日志要能区分"直连"与"解析过"）。
class RadioStreamResolution {
  const RadioStreamResolution({
    required this.url,
    required this.resolvedFromPlaylist,
    this.note = '',
  });

  /// 交给播放器的地址。
  final String url;

  /// 是否经过播放列表解析（`.pls`/`.m3u`）。
  final bool resolvedFromPlaylist;

  /// 失败/回落时给**人看的**原因（成功且直连时为空）。
  final String note;
}

/// 把电台项的 `url` 变成**可交给播放器**的地址。
///
/// 行为（三条，都有用例）：
/// 1. 非播放列表地址 → 原样返回（`resolvedFromPlaylist=false`）；
/// 2. 是播放列表且解析成功 → 返回第一条流地址（`resolvedFromPlaylist=true`）；
/// 3. 是播放列表但**取不到/解析不出** → **回落到原地址**并在 [note] 里写清原因
///    （宁可让它自己再试一次，也不静默什么都不播）。
Future<RadioStreamResolution> resolveRadioStreamUrl(
  String url, {
  RadioStreamHttp? http,
}) async {
  if (url.isEmpty || !isPlaylistUrl(url)) {
    return RadioStreamResolution(url: url, resolvedFromPlaylist: false);
  }
  final client = http ?? IoRadioStreamHttp();
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return RadioStreamResolution(
      url: url,
      resolvedFromPlaylist: false,
      note: 'bad-url',
    );
  }
  try {
    final res = await client.get(uri);
    if (res.statusCode != 200) {
      return RadioStreamResolution(
        url: url,
        resolvedFromPlaylist: false,
        note: 'http-${res.statusCode}',
      );
    }
    final parsed = parsePlaylistStreamUrl(res.body, baseUrl: url);
    if (parsed == null) {
      return RadioStreamResolution(
        url: url,
        resolvedFromPlaylist: false,
        note: 'no-stream-in-playlist',
      );
    }
    return RadioStreamResolution(url: parsed, resolvedFromPlaylist: true);
  } on TimeoutException {
    return RadioStreamResolution(
      url: url,
      resolvedFromPlaylist: false,
      note: 'timeout',
    );
  } catch (e) {
    return RadioStreamResolution(
      url: url,
      resolvedFromPlaylist: false,
      note: 'error',
    );
  }
}
