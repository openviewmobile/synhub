// 226（M74）WebDAV 连接模式 —— **纯 Dart 协议层**（自研；`dio` + `xml` 都是
// `pubspec.yaml` **已有**依赖 ⇒ **没有新增任何依赖**）。
//
// ## 官方 DS file 是怎么做的（一手证据：反编译 smali）
//
// 路径：`/tmp/dsfile_out/smali_classes2/com/synology/DSfile/webdav/`
//
//   * `WebDav$Companion$Method` 的字符串常量逐字：
//     `OPTIONS` / `PROPFIND` / `PROPPATCH` / `MKCOL` / `COPY` / `MOVE` /
//     `PUT` / `GET` / `DELETE`；
//   * `WebDav.smali` 的 `public static final` 字段逐字：
//     ```
//     QUERY_PATH            = "/~DSFile/queryWebdav.cgi"
//     USER_AGENT            = "DSfile"
//     HEADER_AUTHORIZATION  = "Authorization"   （值 "Basic " + base64）
//     HEADER_DEPTH          = "Depth"
//     HEADER_CONTENT_TYPE   = "Content-Type"
//     HEADER_DESTINATION    = "Destination"
//     HEADER_OVERWRITE      = "Overwrite"
//     HEADER_ETAG           = "If-None-Match"
//     HEADER_USER           = "user"
//     HEADER_ACTION         = "action"
//     ACTION_VERSION        = "version"   ACTION_QUERY = "query"
//     ACTION_CLEAR          = "clear"     ACTION_CANCEL = "cancel"
//     ETAG                  = "4fda6a2043824"
//     ```
//   * `doListPath(path)` → `PROPFIND`，headers
//     `{Depth: "1", Content-Type: "text/xml"}`，**body 为 null**
//     （`buildRequestBody(null)` 直接 `return null` ⇒ RFC 4918 的 allprop）；
//   * `getVersion()` → 同一个 `QUERY_PATH`，header `{action: "version"}`，
//     回 JSON（`vos/webdav/VersionVo` 的 `majorVersion` / `success`）；
//   * `getRequestUrl(path)` = `Uri.encode(path, "/")`（**保留 `/`**）后拼到
//     `QUERY_PATH` 之后 ⇒ `https://host:port/~DSFile/queryWebdav.cgi/<path>`；
//   * `WebdavUtil.isGoodResponse(code)` = `200 <= code <= 299`；
//   * `WebdavUtil.encodeURL` = `URLEncoder(utf-8)` 之后把 `+` 换成 `%20`；
//   * `WebdavUtil.decodeURL` = 先把 `+` 换成 `%2B` 再 `URLDecoder(utf-8)`；
//   * `WebdavUtil.formats` 的 7 种日期格式（`parseDate` 逐个尝试）；
//   * `webdav/model/Prop.smali` 认这 8 个属性：`creationdate` /
//     `getcontentlength` / `getcontenttype` / `getetag` / `getlastmodified` /
//     `lockdiscovery` / `resourcetype` / `supportedlock`；
//   * `WebDavConnectionManager.smali`：`DEPRECATED_DSM_VERSION = 0x7`
//     （第 7 行）+ `majorVersion >= 7 → mIsDeprecated = true`（第 45-58 行）。
//
// ## 本实现的范围（如实登记，不假装做全）
//
//   * **只实现读路径**：`OPTIONS`（能力探测）+ `version`（废弃判定）+
//     `PROPFIND`（列目录）。这三个都是**只读**动词，符合本批纪律。
//   * **写动词 `PUT` / `MKCOL` / `COPY` / `MOVE` / `DELETE` / `PROPPATCH`
//     一律未实现** —— 本批不做变更型探测、写路径也没有真机验证；
//     对应方法**根本不存在**（不是"藏起来的私有方法"），调用方无从误用。
//   * **真机状态**：本机 NAS 的 WebDAV 入口**不可达**（只读探针：
//     `OPTIONS/GET/PROPFIND https://nas.example.com:5001/~DSFile/queryWebdav.cgi`
//     → **403 nginx**；标准 WebDAV 端口 5005/5006 → **connection refused**），
//     即这台机器**没有装/没启用 WebDAV Server**。故本层**未在真机跑通**。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import '../../core/net/traffic_meter.dart';
import 'package:xml/xml.dart';

/// DS file 的 WebDAV 入口路径（`WebDav.QUERY_PATH` 逐字）。
const String kWebDavQueryPath = '/~DSFile/queryWebdav.cgi';

/// DS file 的 User-Agent（`WebDav.USER_AGENT` 逐字）。
const String kWebDavUserAgent = 'DSfile';

/// 官方自标废弃的 DSM 主版本（`WebDavConnectionManager.DEPRECATED_DSM_VERSION`）。
const int kWebDavDeprecatedDsmVersion = 7;

/// 连接一个 WebDAV 服务端所需的全部坐标 + 凭据。
class WebDavTarget {
  const WebDavTarget({
    required this.host,
    this.port = 5006,
    this.secure = true,
    this.username = '',
    this.password = '',
    this.queryPath = kWebDavQueryPath,
  });

  final String host;
  final int port;
  final bool secure;
  final String username;
  final String password;

  /// 入口路径。官方 DS file 走 `/~DSFile/queryWebdav.cgi`；标准 WebDAV
  /// 服务端应为 `/`（DSM 的 WebDAV Server 默认根）。
  final String queryPath;

  String get scheme => secure ? 'https' : 'http';

  /// `scheme://host:port` + 入口路径（**不带**尾斜杠）。
  String get baseUrl {
    final p = queryPath.isEmpty ? '/' : queryPath;
    final normalized = p.startsWith('/') ? p : '/$p';
    return '$scheme://$host:$port$normalized';
  }

  /// `Authorization: Basic ...` 的取值（官方 `HEADER_AUTHORIZATION` + `"Basic "`）。
  String get authorizationHeader =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  /// 某个 WebDAV 路径的完整 URL（官方 `getRequestUrl` 的等价物）。
  ///
  /// ⚠️ `queryPath == '/'`（标准 WebDAV 根）时**不能**直接拼，否则会得到
  /// `//home`；这里统一用一个斜杠。
  String urlFor(String path) => '$_rootlessBase${encodeWebDavPath(path)}';

  String get _rootlessBase =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  WebDavTarget copyWith({
    String? host,
    int? port,
    bool? secure,
    String? username,
    String? password,
    String? queryPath,
  }) => WebDavTarget(
    host: host ?? this.host,
    port: port ?? this.port,
    secure: secure ?? this.secure,
    username: username ?? this.username,
    password: password ?? this.password,
    queryPath: queryPath ?? this.queryPath,
  );

  @override
  String toString() =>
      'WebDavTarget($scheme://$host:$port$queryPath, user=$username)';
}

/// 官方 `WebdavUtil.encodeURL` 的等价物：**保留 `/`**，其余按段编码。
///
/// 一手证据：`getRequestUrl` 用 `android.net.Uri.encode(path, "/")`，
/// 第二个参数就是"允许原样保留的字符集"。
String encodeWebDavPath(String path) {
  if (path.isEmpty) return '/';
  final q = path.startsWith('/') ? path : '/$path';
  return q
      .split('/')
      .map(
        (seg) => seg.isEmpty
            // 保留前导/尾随/连续空段（`//` 是有意义路径的一部分）
            ? ''
            // `Uri.encodeComponent` 与 `Uri.encode(s, "/")` 对本场景等价：
            // 字母数字与 `-_.!~*'()` 原样，其余（空格、`+`、中文…）百分号编码。
            : Uri.encodeComponent(seg),
      )
      .join('/');
}

/// 官方 `WebdavUtil.decodeURL` 的等价物（`+` → `%2B` 再 decode）。
String decodeWebDavPath(String raw) {
  try {
    return Uri.decodeComponent(raw.replaceAll('+', '%2B'));
  } catch (_) {
    return raw;
  }
}

/// 官方 `WebdavUtil.parseDate` 的等价物：ISO8601 + RFC 1123 两大类。
///
/// 官方那 7 条格式（`WebdavUtil.formats`）覆盖到秒；Dart 的 `DateTime.parse`
/// 能吃掉其中的 ISO8601 变体，RFC1123 由下面这个正则兜底。
DateTime? parseWebDavDate(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;

  final iso = DateTime.tryParse(s);
  if (iso != null) return iso.toUtc();

  // "Wed, 21 Oct 2015 07:28:00 GMT" / "Wed, 21-Oct-15 07:28:00 GMT"
  final m = RegExp(
    r'^[A-Za-z]{3,9},?\s+(\d{1,2})[-\s]([A-Za-z]{3})[A-Za-z]?[-\s](\d{2,4})\s+'
    r'(\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(s);
  if (m == null) return null;
  const months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };
  final mon = months[m.group(2)!.toLowerCase()];
  if (mon == null) return null;
  var year = int.parse(m.group(3)!);
  if (year < 100) year += year >= 70 ? 1900 : 2000;
  try {
    return DateTime.utc(
      year,
      mon,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
  } catch (_) {
    return null;
  }
}

/// 一次 WebDAV 请求（传输无关 → 可注入假实现做离线测试）。
class WebDavRequest {
  const WebDavRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
  });

  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;
}

class WebDavResponse {
  const WebDavResponse({
    required this.statusCode,
    this.headers = const {},
    this.body = '',
  });

  final int statusCode;

  /// **小写 key** 的响应头（`dav` / `allow` / `server`…）
  final Map<String, String> headers;
  final String body;
}

abstract class WebDavTransport {
  Future<WebDavResponse> send(WebDavRequest request);
}

/// 生产实现：走 `dio`（本仓库已有依赖）。
class DioWebDavTransport implements WebDavTransport {
  DioWebDavTransport([Dio? dio])
    : _dio = tagDioWithModule(dio ?? Dio(), TrafficModules.files);

  final Dio _dio;

  @override
  Future<WebDavResponse> send(WebDavRequest request) async {
    final res = await _dio.request<String>(
      request.url,
      data: request.body,
      options: Options(
        method: request.method,
        headers: request.headers,
        responseType: ResponseType.plain,
        // 交给我们自己判码：403/404/405 都是**有意义的业务结果**，不是异常
        validateStatus: (_) => true,
        followRedirects: false,
      ),
    );
    return WebDavResponse(
      statusCode: res.statusCode ?? 0,
      headers: {
        for (final e in res.headers.map.entries)
          e.key.toLowerCase(): e.value.join(', '),
      },
      body: res.data ?? '',
    );
  }
}

/// WebDAV 错误（非 2xx，或响应形状不对）。
class WebDavException implements Exception {
  const WebDavException({
    required this.method,
    required this.path,
    required this.statusCode,
    this.message = '',
  });

  final String method;
  final String path;
  final int statusCode;
  final String message;

  @override
  String toString() =>
      'WebDavException($method $path → $statusCode${message.isEmpty ? '' : ' $message'})';
}

/// `OPTIONS` 的能力回包。
class WebDavCapabilities {
  const WebDavCapabilities({
    required this.statusCode,
    required this.dav,
    required this.allow,
    required this.server,
  });

  final int statusCode;

  /// `DAV:` 响应头（官方 WebDAV 至少回 `1`；DSM 回 `1, 2` 之类）
  final String dav;

  /// `Allow:` 响应头拆出来的动词
  final List<String> allow;
  final String server;

  bool get supportsPropfind => allow.contains('PROPFIND');
}

/// `getVersion()`（header `action: version`）的回包。
class WebDavVersion {
  const WebDavVersion({required this.success, required this.majorVersion});

  final bool success;
  final int majorVersion;

  /// 官方在 DSM ≥ 7 上把整个 WebDAV 模式标为废弃
  /// （`majorVersion >= DEPRECATED_DSM_VERSION`）。
  bool get isDeprecatedBySynology =>
      majorVersion >= kWebDavDeprecatedDsmVersion;
}

/// 一条 PROPFIND 结果（`webdav/model/Response` + `Prop`）。
class WebDavEntry {
  const WebDavEntry({
    required this.href,
    required this.path,
    required this.name,
    required this.isCollection,
    this.size = 0,
    this.lastModified,
    this.contentType = '',
    this.etag = '',
  });

  /// 服务端原样回的 `href`
  final String href;

  /// 去掉入口前缀后的**服务端绝对路径**（如 `/home/photo.jpg`）
  final String path;

  /// 末段名（已百分号解码）
  final String name;

  /// `<D:resourcetype><D:collection/></D:resourcetype>` ⇒ 目录
  final bool isCollection;

  /// `getcontentlength`（目录通常没有）
  final int size;
  final DateTime? lastModified;
  final String contentType;
  final String etag;
}

/// 解析一个 `multistatus` 文档。
///
/// 只收 **2xx 的 `propstat`**；`404` 的 `propstat`（属性不存在）整块跳过 ——
/// 这与官方 `Prop.smali` 只认那 8 个已知属性的行为一致：不认识就当没有，
/// 不让整个列表失败。
List<WebDavEntry> parseWebDavMultiStatus(
  String body, {
  String stripPrefix = '',
}) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(body);
  } on XmlException {
    return const [];
  }
  final root = doc.rootElement;
  if (root.name.local.toLowerCase() != 'multistatus') return const [];

  final out = <WebDavEntry>[];
  for (final resp in root.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'response')) {
    final href = _childText(resp, 'href');
    if (href == null || href.isEmpty) continue;

    final entry = _entryFromResponse(resp, href, stripPrefix);
    if (entry != null) out.add(entry);
  }
  return out;
}

WebDavEntry? _entryFromResponse(
  XmlElement resp,
  String href,
  String stripPrefix,
) {
  XmlElement? prop;
  for (final ps in resp.childElements.where((e) => e.name.local == 'propstat')) {
    final status = _childText(ps, 'status') ?? '';
    // 只看 2xx 的 propstat
    if (!RegExp(r'\s2\d\d\s').hasMatch(status)) continue;
    prop = ps.childElements
        .where((e) => e.name.local == 'prop')
        .cast<XmlElement?>()
        .firstWhere((_) => true, orElse: () => null);
    if (prop != null) break;
  }
  if (prop == null) return null;

  final isCollection = prop.childElements
      .where((e) => e.name.local == 'resourcetype')
      .any(
        (rt) => rt.childElements.any((c) => c.name.local == 'collection'),
      );

  final decoded = _stripEntryPrefix(href, stripPrefix);
  final segments = decoded.split('/').where((s) => s.isNotEmpty).toList();
  final name = segments.isEmpty
      ? '/'
      : decodeWebDavPath(segments.last);

  return WebDavEntry(
    href: href,
    path: decoded.isEmpty ? '/' : decoded,
    name: name,
    isCollection: isCollection,
    size: int.tryParse(_childText(prop, 'getcontentlength') ?? '') ?? 0,
    lastModified: parseWebDavDate(_childText(prop, 'getlastmodified')),
    contentType: _childText(prop, 'getcontenttype') ?? '',
    etag: _childText(prop, 'getetag') ?? '',
  );
}

String? _childText(XmlElement e, String local) {
  for (final c in e.childElements) {
    if (c.name.local == local) return c.innerText.trim();
  }
  return null;
}

/// 把 `href` 折成"服务端绝对路径"。
///
/// 服务端可能回完整 URL（`https://h:p/~DSFile/queryWebdav.cgi/home`）或
/// 绝对路径（`/~DSFile/queryWebdav.cgi/home`）。两种都要能落到 `/home`。
String _stripEntryPrefix(String href, String stripPrefix) {
  var path = href;
  final uri = Uri.tryParse(href);
  if (uri != null && uri.hasScheme) {
    path = uri.path;
  }
  path = decodeWebDavPath(path);

  final prefixes = <String>[
    if (stripPrefix.isNotEmpty) stripPrefix,
    kWebDavQueryPath,
  ];
  for (final p in prefixes) {
    final normalized = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
    if (normalized.isEmpty || normalized == '/') continue;
    if (path == normalized) return '/';
    if (path.startsWith('$normalized/')) {
      return path.substring(normalized.length);
    }
  }
  return path.isEmpty ? '/' : path;
}

/// WebDAV 客户端（**只读**：OPTIONS / version / PROPFIND）。
class WebDavClient {
  WebDavClient({required this.target, WebDavTransport? transport})
    : _transport = transport ?? DioWebDavTransport();

  final WebDavTarget target;
  final WebDavTransport _transport;

  Map<String, String> _headers({Map<String, String> extra = const {}}) => {
    'Authorization': target.authorizationHeader,
    'User-Agent': kWebDavUserAgent,
    ...extra,
  };

  /// `OPTIONS <entry>` —— 探测服务端支持哪些动词。
  Future<WebDavCapabilities> options() async {
    final url = target.baseUrl;
    final res = await _transport.send(
      WebDavRequest(method: 'OPTIONS', url: url, headers: _headers()),
    );
    if (!_isGood(res.statusCode)) {
      throw WebDavException(
        method: 'OPTIONS',
        path: target.queryPath,
        statusCode: res.statusCode,
        message: res.headers['server'] ?? '',
      );
    }
    return WebDavCapabilities(
      statusCode: res.statusCode,
      dav: res.headers['dav'] ?? '',
      allow: (res.headers['allow'] ?? '')
          .split(',')
          .map((s) => s.trim().toUpperCase())
          .where((s) => s.isNotEmpty)
          .toList(),
      server: res.headers['server'] ?? '',
    );
  }

  /// DS file 的 `getVersion()`：`GET <entry>` + header `action: version`。
  Future<WebDavVersion> version() async {
    final url = target.baseUrl;
    final res = await _transport.send(
      WebDavRequest(
        method: 'GET',
        url: url,
        headers: _headers(extra: {'action': 'version'}),
      ),
    );
    if (!_isGood(res.statusCode)) {
      throw WebDavException(
        method: 'GET',
        path: target.queryPath,
        statusCode: res.statusCode,
      );
    }
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) throw const FormatException('not an object');
      json = decoded.cast<String, dynamic>();
    } catch (_) {
      throw WebDavException(
        method: 'GET',
        path: target.queryPath,
        statusCode: res.statusCode,
        message: 'bad version body',
      );
    }
    return WebDavVersion(
      success: json['success'] == true,
      majorVersion: int.tryParse('${json['majorVersion'] ?? ''}') ?? 0,
    );
  }

  /// `PROPFIND <path>`（`Depth: 1`，**无 body** = allprop，与官方一致）。
  Future<List<WebDavEntry>> list(String path, {int depth = 1}) async {
    final url = target.urlFor(path);
    final res = await _transport.send(
      WebDavRequest(
        method: 'PROPFIND',
        url: url,
        headers: _headers(
          extra: {'Depth': '$depth', 'Content-Type': 'text/xml'},
        ),
      ),
    );
    if (!_isGood(res.statusCode)) {
      throw WebDavException(
        method: 'PROPFIND',
        path: path,
        statusCode: res.statusCode,
      );
    }
    return parseWebDavMultiStatus(
      res.body,
      stripPrefix: target.queryPath,
    );
  }

  /// 列出目录并**去掉第一个 `self` 条目**（它描述目录本身）。
  Future<List<WebDavEntry>> listChildren(String path) async {
    final all = await list(path);
    if (all.isEmpty) return all;
    final self = _normalize(path);
    return [
      for (final e in all)
        if (_normalize(e.path) != self) e,
    ];
  }

  static String _normalize(String p) {
    var s = p.startsWith('/') ? p : '/$p';
    if (s.length > 1 && s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  static bool _isGood(int code) => code >= 200 && code <= 299;

  /// 空目录（只有 self 条目）→ `[]`；用于 UI 空态判定。
  static bool isGoodResponse(int code) => _isGood(code);
}
