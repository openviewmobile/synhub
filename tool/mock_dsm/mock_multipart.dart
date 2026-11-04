// `multipart/form-data` 的最小解析器 —— 只为 Mock 服务端收**上传**用。
//
// ## 为什么需要它
//
// `SYNO.FileStation.Upload/upload` 是**唯一**把文件字节发上来的写动词
// （真机/桌面都走 `Dio` 的 `MultipartFile`）。Mock 服务端原来对
// `multipart/*` 一律 `req.drain()`（把体丢掉），于是"上传"这条链在 Mock 上
// **永远验不到落盘**：客户端以为传了、服务端什么也没收到（r319 之前的状态）。
//
// 这里刻意**不引入依赖**（`package:http_parser` 的 `MimeMultipartTransformer`
// 也能做，但 Mock 要能在没有额外依赖时单独 `dart run`）：手写一个只认
// `Content-Disposition` 的极小解析器，够用即可，并把"不够用的地方"写清楚。
//
// ## 支持的形态（与 `Dio` 实际发出的报文一致）
//
// ```text
// --<boundary>\r\n
// Content-Disposition: form-data; name="path"\r\n\r\n
// /home\r\n
// --<boundary>\r\n
// Content-Disposition: form-data; name="file"; filename="a.txt"\r\n
// Content-Type: application/octet-stream\r\n\r\n
// <字节>\r\n
// --<boundary>--\r\n
// ```
//
// * 字段名取 `Content-Disposition` 的 `name=`；文件名取 `filename=`；
// * **值不做字符集猜测**：有 `filename` 的当字节（`bytes`），没有的按 UTF-8 文本；
// * 二进制安全：分隔符一律按 **字节序列** 找（不能先 `utf8.decode`，会毁二进制）。

/// 一个 multipart 段。
class MultipartPart {
  MultipartPart({required this.name, this.filename, required this.bytes});

  final String name;
  final String? filename;
  final List<int> bytes;

  bool get isFile => filename != null;

  String get text => String.fromCharCodes(bytes).trim();
}

/// 解析结果：字段表 + 文件表（顺序保留）。
class MultipartForm {
  MultipartForm(this.parts);

  final List<MultipartPart> parts;

  Iterable<MultipartPart> get files => parts.where((p) => p.isFile);

  MultipartPart? part(String name) {
    for (final p in parts) {
      if (p.name == name) return p;
    }
    return null;
  }

  /// 非文件字段（`path` / `create_parents` / `overwrite` 等）的文本值。
  Map<String, String> get fields => {
    for (final p in parts)
      if (!p.isFile) p.name: p.text,
  };

  /// 从 `Content-Type` 头里取 `boundary=`；没有就返回 `null`（⇒ 判不了）。
  static String? boundaryOf(String contentType) {
    final i = contentType.toLowerCase().indexOf('boundary=');
    if (i < 0) return null;
    var b = contentType.substring(i + 'boundary='.length).trim();
    if (b.startsWith('"') && b.endsWith('"') && b.length >= 2) {
      b = b.substring(1, b.length - 1);
    }
    final semi = b.indexOf(';');
    if (semi >= 0) b = b.substring(0, semi);
    return b.isEmpty ? null : b;
  }

  /// 解析。**失败一律返回 `null`，不抛** —— Mock 的契约是"判不了就说判不了"。
  static MultipartForm? parse(List<int> body, String contentType) {
    final boundary = boundaryOf(contentType);
    if (boundary == null) return null;
    final delim = _bytes('--$boundary');
    final crlf = _bytes('\r\n');

    // 按分隔符切段（二进制层面）
    final segments = <List<int>>[];
    var start = _indexOf(body, delim, 0);
    if (start < 0) return null;
    start += delim.length;
    while (true) {
      // 结束标记 `--<boundary>--`
      if (_startsWith(body, _bytes('--'), start)) break;
      // 跳过分隔符后的 CRLF
      if (_startsWith(body, crlf, start)) start += crlf.length;
      final next = _indexOf(body, delim, start);
      if (next < 0) break;
      var end = next;
      // 段尾的 CRLF 属于分隔符，不属于内容
      if (end >= crlf.length &&
          _startsWith(body, crlf, end - crlf.length)) {
        end -= crlf.length;
      }
      segments.add(body.sublist(start, end));
      start = next + delim.length;
    }

    final parts = <MultipartPart>[];
    for (final seg in segments) {
      final headerEnd = _indexOf(seg, _bytes('\r\n\r\n'), 0);
      if (headerEnd < 0) continue;
      final headers = String.fromCharCodes(seg.sublist(0, headerEnd));
      final content = seg.sublist(headerEnd + 4);
      final name = _attr(headers, 'name');
      if (name == null) continue;
      parts.add(
        MultipartPart(
          name: name,
          filename: _attr(headers, 'filename'),
          bytes: content,
        ),
      );
    }
    return MultipartForm(parts);
  }

  /// 从 `Content-Disposition: form-data; name="x"; filename="y"` 里取属性。
  static String? _attr(String headers, String key) {
    final lower = headers.toLowerCase();
    final i = lower.indexOf('$key="');
    if (i < 0) return null;
    final from = i + key.length + 2;
    final to = headers.indexOf('"', from);
    if (to < 0) return null;
    return headers.substring(from, to);
  }

  static List<int> _bytes(String s) => s.codeUnits;

  static int _indexOf(List<int> hay, List<int> needle, int from) {
    if (needle.isEmpty) return -1;
    final last = hay.length - needle.length;
    for (var i = from < 0 ? 0 : from; i <= last; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  static bool _startsWith(List<int> hay, List<int> needle, int at) {
    if (at + needle.length > hay.length) return false;
    for (var j = 0; j < needle.length; j++) {
      if (hay[at + j] != needle[j]) return false;
    }
    return true;
  }
}
