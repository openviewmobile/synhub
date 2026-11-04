// 视频投屏（DLNA / UPnP AVTransport）—— r655 · DA264。
//
// ## 为什么不用 NAS 侧的那条路
//
// 音频投屏走的是 `SYNO.AudioStation.RemotePlayer`（渲染器列表与推送都由 NAS 代劳，
// NAS 侧去发现设备）。**视频没有对应的 API**：样例库里 21 个套件目录中，只有
// `AudioStation` 与 `SynologyDrive` 提到 DLNA/MediaServer，`SYNO.VideoStation`
// 没有任何 remote-player 方法（`scripts/samples.sh weblib` 复核过）。
// 换句话说：想在视频页投屏，**必须由手机自己去发现与推送**。
//
// ## 这条路怎么走（标准 UPnP，不依赖任何服务端能力）
//
//   ① SSDP `M-SEARCH`（组播 `239.255.255.250:1900`，`ST=MediaRenderer:1`）→
//      收各设备的**单播** `200 OK`（含 `LOCATION:`）；
//   ② 取 `LOCATION` 的设备描述 XML → 找 `AVTransport` 服务的 `controlURL`；
//   ③ `SetAVTransportURI(CurrentURI=<DSM 直链>, CurrentURIMetaData=<DIDL-Lite>)`
//      → `Play`；后续 `Pause/Play/Stop/Seek/GetTransportInfo` 都打同一个控制 URL。
//
// ## 鉴权怎么过
//
// 本仓的直链鉴权**全在查询串**（`_sid` + `SynoToken`，见 `media_source.dart`）⇒
// 渲染器自己去 GET 同一个 URL 就能拿到字节，**不需要**把会话交给它（也不需要它
// 支持我们的 Cookie 头）。代价：渲染器必须能直连 NAS（同一 LAN / 同 QuickConnect
// 出口），且它自己的 HTTP 客户端信任 NAS 证书 —— 这两条失败时**必须说清楚是哪条**
// （[UpnpCastFailure]），不能笼统地"投屏失败"。
//
// ## 可测性
//
// 一切"会碰网络"的动作都收在 [UpnpDiscovery] / [UpnpAvTransport] 的**注入点**上
// （socket 工厂 / HTTP 取文本 / HTTP POST），所以解析、去重、DIDL、SOAP 故障分类
// 都能在宿主上逐条断言（`test/upnp_cast_test.dart`），不需要真设备。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'media_source.dart';

/// SSDP 组播地址/端口（UPnP 规范固定值）
const String kSsdpMulticastAddress = '239.255.255.250';
const int kSsdpPort = 1900;

/// 只找 `MediaRenderer:1`（电视机/投影/音箱/软件渲染器都是这个设备类型）
const String kMediaRendererDeviceType =
    'urn:schemas-upnp-org:device:MediaRenderer:1';

/// AVTransport 服务类型（v1 覆盖绝大多数设备；v2 设备通常同时声明 v1）
const String kAvTransportServiceType =
    'urn:schemas-upnp-org:service:AVTransport:1';

/// 投屏失败的原因（每一条都给**用户能做的事**，不给技术黑话）
enum UpnpCastFailure {
  /// 同一网络里没发现任何渲染器
  noRenderer('no-renderer'),

  /// 找到了设备但它的描述/控制地址不可用（防火墙、设备老化）
  unreachable('unreachable'),

  /// 设备不接受这个媒体（格式/DRM/URI 被拒）
  rejected('rejected'),

  /// 设备认了 URI 但起播失败（它拉不到 NAS 直链：跨网段/证书不信任）
  playbackFailed('playback-failed');

  const UpnpCastFailure(this.code);
  final String code;

  static UpnpCastFailure? fromCode(String? code) {
    for (final v in values) {
      if (v.code == code) return v;
    }
    return null;
  }
}

/// 一个可投屏的渲染器
class UpnpRenderer {
  const UpnpRenderer({
    required this.friendlyName,
    required this.location,
    required this.controlUrl,
    this.modelName = '',
    this.usn = '',
  });

  /// 用户看到的名字（设备描述里的 `friendlyName`；拿不到时退回 `modelName`/主机名）
  final String friendlyName;

  /// SSDP 回的设备描述地址（也用来去重）
  final String location;

  /// AVTransport 的控制 URL（**绝对**地址，SOAP POST 打这里）
  final String controlUrl;

  final String modelName;

  /// SSDP 的 `USN`（同一台设备可能有多个 ST 应答，用 USN 去重）
  final String usn;

  @override
  String toString() => 'UpnpRenderer($friendlyName, $controlUrl)';
}

/// 解析一条 SSDP `200 OK` 应答里的 `LOCATION`。
///
/// 只回取得到的绝对 http(s) 地址；头名大小写不敏感（实测设备里两种都有）。
String? parseSsdpLocation(String response) {
  for (final line in const LineSplitter().convert(response)) {
    final i = line.indexOf(':');
    if (i <= 0) continue;
    final name = line.substring(0, i).trim().toLowerCase();
    if (name != 'location') continue;
    final value = line.substring(i + 1).trim();
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    return value;
  }
  return null;
}

/// 解析 USN（去重用）。
String? parseSsdpUsn(String response) {
  for (final line in const LineSplitter().convert(response)) {
    final i = line.indexOf(':');
    if (i <= 0) continue;
    if (line.substring(0, i).trim().toLowerCase() != 'usn') continue;
    final v = line.substring(i + 1).trim();
    return v.isEmpty ? null : v;
  }
  return null;
}

/// 从设备描述 XML 里取 `friendlyName` / `modelName` / AVTransport 的 `controlURL`。
///
/// 手写正则而不是引 XML 解析器：这些字段在 XML 里永远是**叶子文本**，
/// 而设备描述里还有大量命名空间前缀（`dlna:X_DLNADOC` 等），用 DOMParser
/// 反而要处理命名空间；正则在这里更稳、也更好断言（已知边界写进用例）。
UpnpRenderer? parseDeviceDescription(String xml, {required String location}) {
  final friendly = _firstTagText(xml, 'friendlyName');
  final model = _firstTagText(xml, 'modelName');

  // AVTransport 服务的 controlURL：只认 serviceType 里带 AVTransport 的那一段。
  final services = RegExp(
    r'<service>(.*?)</service>',
    dotAll: true,
    caseSensitive: false,
  ).allMatches(xml);
  for (final m in services) {
    final block = m.group(1) ?? '';
    final type = _firstTagText(block, 'serviceType') ?? '';
    if (!type.toLowerCase().contains('avtransport')) continue;
    final raw = _firstTagText(block, 'controlURL');
    if (raw == null || raw.isEmpty) continue;
    final resolved = _resolve(location, raw);
    if (resolved == null) continue;
    return UpnpRenderer(
      friendlyName: (friendly ?? model ?? _hostOf(location)).trim(),
      location: location,
      controlUrl: resolved,
      modelName: model ?? '',
    );
  }
  return null;
}

String? _firstTagText(String xml, String tag) {
  final m = RegExp(
    '<$tag[^>]*>(.*?)</$tag>',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(xml);
  if (m == null) return null;
  return _unescapeXml(m.group(1) ?? '').trim();
}

/// 把 `controlURL` 拼成绝对地址（设备常给相对路径，如 `/upnp/control/AVTransport1`）
String? _resolve(String location, String raw) {
  final base = Uri.tryParse(location);
  if (base == null) return null;
  try {
    return base.resolve(raw).toString();
  } catch (_) {
    return null;
  }
}

String _hostOf(String url) {
  final u = Uri.tryParse(url);
  return u?.host ?? url;
}

String _unescapeXml(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// 转义成 XML 文本/属性安全的形式。
String escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 拼 DIDL-Lite 元数据。
///
/// 为什么非要它：规范里 `SetAVTransportURI` 的 `CurrentURIMetaData` 可以是空串，
/// 但**实测多数电视/投影在空元数据时拒播**（它们靠 `upnp:class` 判定"这是不是
/// 一个能播的视频"）。所以这里给最小但完整的视频条目。
String buildVideoDidlLite({
  required String uri,
  required String title,
  required int sizeBytes,
}) {
  final safeUri = escapeXml(uri);
  return '<DIDL-Lite '
      'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="synhub-video" parentID="0" restricted="1">'
      '<dc:title>${escapeXml(title)}</dc:title>'
      '<upnp:class>object.item.videoItem</upnp:class>'
      '<res protocolInfo="http-get:*:video/*:*" size="$sizeBytes">$safeUri</res>'
      '</item></DIDL-Lite>';
}

/// 拼一个 SOAP 信封（`SOAPACTION` 头单独给）。
String buildSoapEnvelope({
  required String serviceType,
  required String action,
  required Map<String, String> arguments,
}) {
  final args = StringBuffer();
  arguments.forEach((k, v) {
    args.write('<$k>${escapeXml(v)}</$k>');
  });
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:$action xmlns:u="$serviceType">$args</u:$action>'
      '</s:Body></s:Envelope>';
}

/// `GetTransportInfo` 回包里的 `CurrentTransportState`（`PLAYING`/`PAUSED_PLAYBACK`/
/// `STOPPED`/`TRANSITIONING`…）；拿不到 → null。
String? parseTransportState(String xml) =>
    _firstTagText(xml, 'CurrentTransportState');

/// SOAP 故障 → 投屏失败原因。
///
/// 判据用的是**设备回的 UPnPError code**（`<errorCode>714</errorCode>` 之类）：
///   * 714/715/716/701/702/704/705 = "不接受这个媒体/URI 不合规" → [rejected]；
///   * 7xx 其它 / 5xx / 网络层异常 = 拉不到或放不出来 → [playbackFailed]；
///   * 连不上设备本身（socket 异常）= [unreachable]。
UpnpCastFailure classifySoapFailure(String xml, {bool transportError = false}) {
  if (transportError) return UpnpCastFailure.unreachable;
  final m = RegExp(
    r'<errorCode>\s*(-?\d+)\s*</errorCode>',
    caseSensitive: false,
  ).firstMatch(xml);
  final code = m == null ? null : int.tryParse(m.group(1)!);
  if (code == null) return UpnpCastFailure.rejected;
  const rejected = {701, 702, 704, 705, 714, 715, 716};
  if (rejected.contains(code)) return UpnpCastFailure.rejected;
  if (code >= 700 && code < 800) return UpnpCastFailure.playbackFailed;
  return UpnpCastFailure.rejected;
}

// ── 真实网络实现 ────────────────────────────────────────────────────────────

/// 渲染器发现的**可注入**外壳。
///
/// 默认实现对真网络：`RawDatagramSocket` 发 M-SEARCH + 收单播应答，
/// `HttpClient` 取设备描述。测试注入假 socket / 假取文本。
class UpnpDiscovery {
  UpnpDiscovery({
    this.searchTimeout = const Duration(seconds: 3),
    Future<RawDatagramSocket> Function()? socketFactory,
    Future<String?> Function(Uri location)? fetchDescription,
    String searchAddress = kSsdpMulticastAddress,
    int searchPort = kSsdpPort,
  })  : _socketFactory = socketFactory ?? _defaultSocket,
        _fetchDescription = fetchDescription ?? _defaultFetch,
        _searchAddress = searchAddress,
        _searchPort = searchPort;

  /// 收应答的窗口（真机 3s 够；电视偶尔慢，重试一次比拉长窗口好）
  final Duration searchTimeout;
  final Future<RawDatagramSocket> Function() _socketFactory;
  final Future<String?> Function(Uri location) _fetchDescription;

  /// M-SEARCH 的目的地址（**测试注入点**：宿主上没有组播设备，
  /// 打真组播会 `Send failed`；这一层可换就等于"协议逻辑可测"）
  final String _searchAddress;
  final int _searchPort;

  static Future<RawDatagramSocket> _defaultSocket() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    // 发组播要打开广播位；新版 SDK 里它是 setter 而不是 bind 的参数。
    socket.broadcastEnabled = true;
    return socket;
  }

  static Future<String?> _defaultFetch(Uri location) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(location);
      final res = await req.close();
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      return body.isEmpty ? null : body;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 搜一轮，返回**去重后**的渲染器列表（同一台设备多播多次只留一个）。
  ///
  /// 去重键优先 `USN`（设备唯一），退化到 `location`。
  Future<List<UpnpRenderer>> discover() async {
    RawDatagramSocket socket;
    try {
      socket = await _socketFactory();
    } catch (_) {
      return const [];
    }
    final locations = <String, String?>{}; // location -> usn
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final message = utf8.decode(datagram!.data, allowMalformed: true);
        if (!message.toUpperCase().contains('200 OK')) continue;
        final location = parseSsdpLocation(message);
        if (location == null) continue;
        locations.putIfAbsent(location, () => parseSsdpUsn(message));
      }
    }, onError: (Object _) {
      // 个别 ROM 会拒组播；收不到应答就等于"没找到"，不把异常抛给界面。
    });

    final search = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $kSsdpMulticastAddress:$kSsdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $kMediaRendererDeviceType\r\n'
        '\r\n';
    final target = InternetAddress(_searchAddress);
    for (var i = 0; i < 2; i++) {
      try {
        socket.send(utf8.encode(search), target, _searchPort);
      } catch (_) {
        // 组播被系统拦掉（少数 ROM）：不致命，下面照样收得到"被动通告"。
      }
    }

    await Future<void>.delayed(searchTimeout);
    await sub.cancel();
    socket.close();

    if (locations.isEmpty) return const [];

    final out = <UpnpRenderer>[];
    final seenUsn = <String>{};
    for (final entry in locations.entries) {
      final location = entry.key;
      final xml = await _fetchDescription(Uri.parse(location));
      if (xml == null) continue;
      final renderer = parseDeviceDescription(xml, location: location);
      if (renderer == null) continue;
      final usn = entry.value ?? '';
      final key = usn.isNotEmpty ? usn : location;
      if (!seenUsn.add(key)) continue;
      out.add(
        UpnpRenderer(
          friendlyName: renderer.friendlyName,
          location: renderer.location,
          controlUrl: renderer.controlUrl,
          modelName: renderer.modelName,
          usn: usn,
        ),
      );
    }
    out.sort((a, b) => a.friendlyName.compareTo(b.friendlyName));
    return out;
  }
}

/// AVTransport 客户端（真网络，可注入 POST）。
class UpnpAvTransport {
  UpnpAvTransport({
    required this.controlUrl,
    Future<(int, String)> Function(Uri url, String body, String soapAction)?
        post,
  }) : _post = post ?? _defaultPost;

  final String controlUrl;
  final Future<(int, String)> Function(Uri, String, String) _post;

  static Future<(int, String)> _defaultPost(
    Uri url,
    String body,
    String soapAction,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(url);
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set('SOAPACTION', soapAction);
      // ★★★ 必须**显式**给 Content-Length（`DA265`，真机 2026-10-24 撞到）：
      //   不给长度时 Dart 的 `HttpClient` 会发 `Transfer-Encoding: chunked`，
      //   而 UPnP 渲染器的解析几乎清一色只读 `Content-Length`（有的直接
      //   `int(headers['Content-Length'] or 0)`）⇒ 它把请求体读成 0 字节，
      //   于是 `SetAVTransportURI` 收到空 `CurrentURI`：**回 200 成功、却没内容**。
      //   真机现象是"看起来投屏成功、电视没反应"，比报错更难查。
      final bytes = utf8.encode(body);
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return (res.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }

  Future<(int, String)> _invoke(
    String action,
    Map<String, String> args, {
    String serviceType = kAvTransportServiceType,
  }) async {
    final body = buildSoapEnvelope(
      serviceType: serviceType,
      action: action,
      arguments: args,
    );
    return _post(
      Uri.parse(controlUrl),
      body,
      '"$serviceType#$action"',
    );
  }

  /// 推一条视频上去（**不自动播**：先 SetAVTransportURI 再单独 Play，
  /// 这样"推成功但起播失败"能和"压根推不进去"分开报）。
  Future<UpnpCastFailure?> setVideo({
    required MediaSource source,
    required String title,
  }) async {
    try {
      final (status, text) = await _invoke('SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': source.uri,
        'CurrentURIMetaData': buildVideoDidlLite(
          uri: source.uri,
          title: title,
          sizeBytes: source.size,
        ),
      });
      if (status >= 400 || text.contains('Fault')) {
        return classifySoapFailure(text);
      }
      return null;
    } on SocketException {
      return UpnpCastFailure.unreachable;
    } catch (_) {
      return UpnpCastFailure.unreachable;
    }
  }

  Future<UpnpCastFailure?> play() => _simple('Play');
  Future<UpnpCastFailure?> pause() => _simple('Pause');
  Future<UpnpCastFailure?> stop() => _simple('Stop');

  Future<UpnpCastFailure?> _simple(String action) async {
    try {
      final (status, text) = await _invoke(action, {'InstanceID': '0'});
      if (status >= 400 || text.contains('Fault')) {
        return classifySoapFailure(text);
      }
      return null;
    } on SocketException {
      return UpnpCastFailure.unreachable;
    } catch (_) {
      return UpnpCastFailure.unreachable;
    }
  }

  /// 从 [position] 起播（续投：用户看到一半换到电视上）
  Future<UpnpCastFailure?> seek(Duration position) async {
    final h = position.inHours.toString().padLeft(2, '0');
    final m = (position.inMinutes % 60).toString().padLeft(2, '0');
    final s = (position.inSeconds % 60).toString().padLeft(2, '0');
    try {
      final (status, text) = await _invoke('Seek', {
        'InstanceID': '0',
        'Unit': 'REL_TIME',
        'Target': '$h:$m:$s',
      });
      if (status >= 400 || text.contains('Fault')) {
        return classifySoapFailure(text);
      }
      return null;
    } on SocketException {
      return UpnpCastFailure.unreachable;
    } catch (_) {
      return UpnpCastFailure.unreachable;
    }
  }

  /// 问设备当前状态（`PLAYING`/`PAUSED_PLAYBACK`/`STOPPED`/null=问不到）
  Future<String?> transportState() async {
    try {
      final (status, text) =
          await _invoke('GetTransportInfo', {'InstanceID': '0'});
      if (status >= 400 || text.contains('Fault')) return null;
      return parseTransportState(text);
    } catch (_) {
      return null;
    }
  }
}
