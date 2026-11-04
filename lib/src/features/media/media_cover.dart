// 音频 / 视频文件里的**内嵌封面图**解析（**纯逻辑层**）。
//
// 这一层**不许** import flutter / package:flutter / l10n：
// `dart run tool/*.dart` 要用纯 Dart VM 直接加载它（同 `media_source.dart`
// 的规矩）。所以这里只有 `dart:convert` / `dart:typed_data`，失败一律返回
// null，绝不抛异常、绝不吐垃圾字节。
//
// 为什么只读**片段**：FileStation 的 `Download` 直链真机实测支持 HTTP Range
// （206 + `content-range`），所以封面只需要头部/尾部各读几十~几百 KB，
// **永远不要**为了列表里一张缩略图把整个视频/音频下载下来。
// [mediaCoverRequestFor] 给出"要读多少"的建议，调用方照它发 `Range` 请求。
//
// **两段式（为什么需要它）**：真机样本 `/home/Music/CD1 - 01 - Track01.mp3`
// 的内嵌封面（APIC，MIME 写作 `image/jpg`）有 **2,103,578 字节**，
// 而第一段预读只有 512KB ⇒ 帧头找到了、图片却被截断，旧逻辑直接 null
// （列表里只能退回音符图标）。所以现在分两步：
//   ① [scanMediaCover] 扫第一段预读：要么拿到封面，要么给出图片在文件里的
//      **绝对区间 [start, end)**（[MediaCoverRange]）；
//   ② 调用方按这个区间再取**恰好那段**字节 → [finishMediaCoverRange]。
// 小封面（≤512KB）仍然**只发一次**请求；只有"声明长度真的超出预读"才发第二次。
//
// 覆盖范围（能拿就拿，拿不到就 null）：
//   * MP3 / ID3v2：`APIC`（2.3 / 2.4）/ `PIC`（2.2）——含 unsynchronisation、
//     extended header、多 APIC 取第一个；
//   * FLAC：`METADATA_BLOCK_PICTURE`（type 6），以及 Vorbis comment 里的
//     `METADATA_BLOCK_PICTURE=`（base64）；
//   * OGG / Vorbis / Opus：comment header 里的 `METADATA_BLOCK_PICTURE=`（base64）
//     （兼容老的 `COVERART=`）；
//   * MP4 / M4A / M4V / MOV：`moov > udta > meta > ilst > covr > data`
//     （type 13 = JPEG / 14 = PNG）——`moov` 可能在**文件尾**，所以支持
//     "头 + 尾"两段；大小字段支持 64 位 largesize（`co64` 那一类箱子的写法）；
//   * MKV / WebM：`Attachments > AttachedFile`（`FileMimeType` / `FileData`，
//     常见 `cover.jpg`）——EBML 变长整数按规范解析，未知长度元素不硬跳；
//   * ASF / WMA：`WM/Picture`（尽力而为）；
//   * RIFF / WAV：`ID3 ` 块里再走一遍 ID3v2（尽力而为）。
//
// **明确不支持**（返回 null，且 [mediaCoverRequestFor] 会标 `supported=false`
// 让调用方连请求都别发）：AVI（没有标准内嵌封面）、APE、AIFF，以及所有
// 非音视频后缀。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'media_source.dart' show MediaKind;

/// 内嵌封面的体积上限。
///
/// 列表缩略图会被批量解码并缓存，一张几十 MB 的"封面"（其实是整页扫描图）
/// 能把列表内存打爆。真实音视频内嵌封面普遍在 30KB~2MB，8MB 只用来兜住极端值。
const int kMediaCoverMaxBytes = 8 * 1024 * 1024;

/// 第二段（精确）取字节的**上限：4 MiB**。超过就**不发第二次请求**，直接 null。
///
/// 数字理由：
///   * 真实内嵌封面普遍 30KB~2MB —— 真机样本（`CD1 - 01 - Track01.mp3` 的
///     APIC）是 **2,103,578 字节**，4MB 兜住极端值；
///   * **传输层只支持 `bytes=0-N` / `bytes=-N`**（见 `DsmWebApi.getBytes`），
///     发不了真正的 `bytes=<start>-<end-1>` ⇒ 第二次实际上是从 0 读到 end。
///     所以用 `end <= 4MB` **同时**卡住"封面太大"和"白读的流量"：
///     一次列表浏览不会因为封面多出几十 MB。
const int kMediaCoverRangeMaxBytes = 4 * 1024 * 1024;

/// 头部读取建议：ID3v2 标签里的 APIC 大图一般 < 512KB。
const int kMediaCoverId3HeadBytes = 512 * 1024;

/// 头部读取建议：FLAC / Vorbis 的元数据块都在文件开头，256KB 足够。
const int kMediaCoverVorbisHeadBytes = 256 * 1024;

/// 头部读取建议：MP4 的 `moov` 若在开头，`covr` 通常在头 1MB 内。
const int kMediaCoverMp4HeadBytes = 1024 * 1024;

/// 尾部读取建议：`moov` 在文件尾时，尾部 1MB 通常能覆盖 `moov`。
const int kMediaCoverMp4TailBytes = 1024 * 1024;

/// 头部读取建议：MKV / WebM 的 EBML 头 + 部分元素。
const int kMediaCoverMatroskaHeadBytes = 256 * 1024;

/// 尾部读取建议：MKV / WebM 的 `Attachments` 常常追加在文件末尾。
const int kMediaCoverMatroskaTailBytes = 2 * 1024 * 1024;

/// 头部读取建议：ASF / WMA 的 `WM/Picture` 在头部对象里。
const int kMediaCoverAsfHeadBytes = 512 * 1024;

/// 头部读取建议：RIFF / WAV 的 `ID3 ` 块一般也在前面。
const int kMediaCoverRiffHeadBytes = 256 * 1024;

/// 一张内嵌封面：图片字节 + MIME + 来自哪个容器（诊断用）。
class MediaCover {
  const MediaCover({
    required this.bytes,
    required this.mime,
    required this.source,
  });

  final Uint8List bytes;

  /// 归一化后的 MIME（`image/jpeg` / `image/png` / …）
  final String mime;

  /// 解析来源，例如 `id3v2.3/APIC` / `flac/picture` / `mp4/covr`（诊断/测试断言）
  final String source;

  int get length => bytes.length;

  @override
  String toString() => 'MediaCover($mime, ${bytes.length}B, $source)';
}

/// 已经取到的字节片段：**头段**（从文件开头）+ 可选**尾段**（从文件末尾）。
///
/// [fileSize] 是文件总大小（列表里的 `size`）。有它才能把尾段的相对偏移换算成
/// 绝对偏移 —— MP4/MKV 的箱子遍历需要绝对位置。`fileSize == 0`（未知）时只按
/// 头段解析。
class MediaCoverBytes {
  const MediaCoverBytes({this.prefix, this.tail, this.fileSize = 0});

  /// 从文件开头读到的字节（`Range: bytes=0-<n-1>`）
  final Uint8List? prefix;

  /// 从文件末尾读到的字节（`Range: bytes=-<n>`）
  final Uint8List? tail;

  /// 文件总大小；[tail] 非空时应当给出（否则尾部无法定位）
  final int fileSize;

  bool get isEmpty =>
      (prefix == null || prefix!.isEmpty) && (tail == null || tail!.isEmpty);

  @override
  String toString() =>
      'MediaCoverBytes(prefix=${prefix?.length ?? 0}, '
      'tail=${tail?.length ?? 0}, fileSize=$fileSize)';
}

/// "为了内嵌封面，读多少字节"的建议。
///
/// 调用方**只应**照这个发 `Range` 请求；[supported] 为 false 时连请求都别发
/// （这个容器没有我们认识的内嵌封面，发了也是白跑）。
class MediaCoverRequest {
  const MediaCoverRequest({
    required this.prefixBytes,
    this.tailBytes = 0,
    this.supported = true,
    this.container = 'unknown',
  });

  /// 头部读取字节数（`Range: bytes=0-<prefixBytes-1>`）
  final int prefixBytes;

  /// 尾部读取字节数（`Range: bytes=-<tailBytes>`）；0 = 不需要尾部
  final int tailBytes;

  /// 这个容器值不值得发请求（false = 明确拿不到，别浪费一次 Range）
  final bool supported;

  /// 容器标识（诊断/测试断言）
  final String container;

  bool get needsTail => tailBytes > 0;

  /// 总读取量（诊断/测试：断言"没有为了封面下载整个文件"）
  int get totalBytes => prefixBytes + tailBytes;

  @override
  String toString() =>
      'MediaCoverRequest($container, head=$prefixBytes, tail=$tailBytes, '
      'supported=$supported)';
}

/// "封面图片在文件里的**绝对区间** [start, end)"（含 start、不含 end）。
///
/// 只在"第一段预读里找到了图片帧，但它的声明长度超过预读"时产生
/// （见 [scanMediaCover]）。调用方应按这个区间**恰好**取 [length] 个字节，
/// 再交给 [finishMediaCoverRange] —— 不要把整段头读拉大来绕过它。
class MediaCoverRange {
  const MediaCoverRange({
    required this.start,
    required this.end,
    required this.mimeHint,
    required this.source,
  });

  /// 图片第一个字节的绝对偏移
  final int start;

  /// 图片最后一个字节之后的位置（不含）
  final int end;

  /// 容器里声明的 MIME（可能为空/脏，最终以图片 magic 为准）
  final String mimeHint;

  /// 解析来源（诊断/测试断言），例如 `id3v2.3/APIC`
  final String source;

  int get length => end - start;

  @override
  String toString() =>
      'MediaCoverRange([$start, $end), ${length}B, $mimeHint, $source)';
}

/// [scanMediaCover] 的结果：拿到了封面 / 还需要文件的某一段 / 都没有。
class MediaCoverScan {
  const MediaCoverScan({this.cover, this.range});

  /// 第一段预读里就解出来了
  final MediaCover? cover;

  /// 第一段预读里发现图片帧比预读更长 → 需要第二段
  final MediaCoverRange? range;

  bool get found => cover != null;

  bool get needsRange => cover == null && range != null;

  @override
  String toString() =>
      'MediaCoverScan(cover=${cover ?? 'null'}, range=${range ?? 'null'})';
}

/// 按容器给出"只读片段"的建议。[fileSize] > 0 时会把建议值夹到文件大小以内，
/// 并在此前提下省掉多余的尾读。
MediaCoverRequest mediaCoverRequestFor({
  required MediaKind kind,
  required String extension,
  int fileSize = 0,
}) {
  final ext = normalizeMediaExtension(extension);
  late MediaCoverRequest plan;
  switch (ext) {
    case 'mp3':
    case 'mp2':
    case 'mp1':
    case 'aac':
      plan = const MediaCoverRequest(
        prefixBytes: kMediaCoverId3HeadBytes,
        container: 'id3v2',
      );
    case 'flac':
      plan = const MediaCoverRequest(
        prefixBytes: kMediaCoverId3HeadBytes,
        container: 'flac',
      );
    case 'ogg':
    case 'oga':
    case 'opus':
    case 'spx':
      plan = const MediaCoverRequest(
        prefixBytes: kMediaCoverVorbisHeadBytes,
        container: 'ogg',
      );
    case 'mp4':
    case 'm4a':
    case 'm4b':
    case 'm4p':
    case 'm4v':
    case 'mov':
    case '3gp':
    case '3g2':
      plan = const MediaCoverRequest(
        prefixBytes: kMediaCoverMp4HeadBytes,
        tailBytes: kMediaCoverMp4TailBytes,
        container: 'mp4',
      );
    case 'mkv':
    case 'webm':
    case 'mka':
    case 'mks':
      plan = const MediaCoverRequest(
        prefixBytes: kMediaCoverMatroskaHeadBytes,
        tailBytes: kMediaCoverMatroskaTailBytes,
        container: 'matroska',
      );
    case 'wma':
    case 'asf':
    case 'wmv':
      plan = const MediaCoverRequest(
        prefixBytes: kMediaCoverAsfHeadBytes,
        container: 'asf',
      );
    case 'wav':
    case 'wave':
      plan = const MediaCoverRequest(
        prefixBytes: kMediaCoverRiffHeadBytes,
        container: 'riff',
      );
    case 'avi':
      // AVI 没有标准内嵌封面：明确不支持，别为它发请求
      plan = const MediaCoverRequest(
        prefixBytes: 0,
        supported: false,
        container: 'riff',
      );
    default:
      plan = const MediaCoverRequest(prefixBytes: 0, supported: false);
  }
  if (fileSize <= 0) return plan;
  var head = plan.prefixBytes;
  var tail = plan.tailBytes;
  if (head >= fileSize) {
    // 文件本身比建议头读还小 → 一次头读就是整份（小文件无妨）
    return MediaCoverRequest(
      prefixBytes: fileSize,
      supported: plan.supported,
      container: plan.container,
    );
  }
  if (tail > 0 && tail >= fileSize - head) {
    // 尾段已经开始覆盖到头部建议区间 → 头段读满整份即可，省掉尾读
    return MediaCoverRequest(
      prefixBytes: fileSize,
      supported: plan.supported,
      container: plan.container,
    );
  }
  return MediaCoverRequest(
    prefixBytes: head,
    tailBytes: tail,
    supported: plan.supported,
    container: plan.container,
  );
}

/// 文件名后缀归一化：大小写不敏感，去掉前导 `.`。
String normalizeMediaExtension(String extension) {
  var ext = extension.trim().toLowerCase();
  while (ext.startsWith('.')) {
    ext = ext.substring(1);
  }
  final slash = ext.lastIndexOf('/');
  if (slash >= 0) ext = ext.substring(slash + 1);
  final dot = ext.lastIndexOf('.');
  if (dot >= 0) ext = ext.substring(dot + 1);
  return ext;
}

/// 从字节片段里抠内嵌封面。拿不到 → null（**不抛异常、不吐垃圾**）。
///
/// 只解析**已经拿到的**字节：如果图片帧声明长度超过预读，这里返回 null
/// （这正是"2MB 封面出不来"的表象）。要支持那种文件，用 [scanMediaCover]。
MediaCover? extractMediaCover(
  MediaCoverBytes data,
  MediaKind kind,
  String extension,
) => _extractMediaCover(data, kind, extension, null);

/// 第一段预读的**两段式**入口：拿到封面，或者拿到"第二段要取哪一段"。
///
/// 契约：
///   * [MediaCoverScan.cover] 非空 ⇒ 已经解出，别再发请求；
///   * [MediaCoverScan.range] 非空 ⇒ 按这个**绝对区间**取字节，交给
///     [finishMediaCoverRange]（区间上限 [kMediaCoverRangeMaxBytes]，超了不给）；
///   * 两者都空 ⇒ 这个文件没有我们认识的内嵌封面（或数据太脏），退图标。
MediaCoverScan scanMediaCover(
  MediaCoverBytes data,
  MediaKind kind,
  String extension,
) {
  final wants = <MediaCoverRange>[];
  final cover = _extractMediaCover(data, kind, extension, wants);
  if (cover != null) return MediaCoverScan(cover: cover);
  final fileSize = data.fileSize;
  for (final r in wants) {
    if (_rangeLooksUsable(r, fileSize)) return MediaCoverScan(range: r);
  }
  return const MediaCoverScan();
}

/// 第二段字节到位之后的收口：长度必须与区间**恰好一致**，再做 magic 校验。
///
/// 长度不一致（服务端没给够 / 被中间层改过）⇒ null —— **绝不把半张图**
/// 喂给 `Image.memory`（截断的 JPEG 头几个字节仍然是合法 magic）。
MediaCover? finishMediaCoverRange(MediaCoverRange range, Uint8List segment) {
  if (segment.length != range.length) return null;
  return _finishCover(segment, range.mimeHint, range.source);
}

/// 第二段区间的可用性闸门：区间合法、不越文件尾、且不超过 4MB 上限。
bool _rangeLooksUsable(MediaCoverRange r, int fileSize) {
  if (r.start < 0 || r.end <= r.start) return false;
  // 传输层只能 `bytes=0-N`（读到 end 再切）⇒ 用 end 同时卡封面大小与流量
  if (r.end > kMediaCoverRangeMaxBytes) return false;
  if (fileSize > 0 && r.end > fileSize) return false; // 声明越过文件尾 = 脏数据
  return true;
}

MediaCover? _extractMediaCover(
  MediaCoverBytes data,
  MediaKind kind,
  String extension,
  List<MediaCoverRange>? wants,
) {
  if (data.isEmpty) return null;
  final view = _FileView(data.prefix ?? Uint8List(0), data.tail, data.fileSize);
  final head = view.prefix;
  final ext = normalizeMediaExtension(extension);
  try {
    // 先认 magic number，再退到后缀（magic 更可信）
    if (_startsWith(head, const [0x49, 0x44, 0x33])) {
      return _id3v2(view, wants);
    }
    if (_startsWith(head, const [0x66, 0x4C, 0x61, 0x43])) {
      return _flac(view, wants);
    }
    if (_startsWith(head, const [0x4F, 0x67, 0x67, 0x53])) return _ogg(view);
    if (_startsWith(head, const [0x52, 0x49, 0x46, 0x46])) {
      return _riff(view, wants);
    }
    if (_startsWith(head, kMatroskaMagic)) return _matroska(view);
    if (_startsWith(head, kAsfHeaderGuid)) return _asf(view);
    if (_looksLikeMp4(head)) return _mp4(view, wants);

    // magic 看不到（头段很短 / 隔离片段）：按后缀再试一次
    switch (ext) {
      case 'mp3':
      case 'mp2':
      case 'mp1':
      case 'aac':
        return _id3v2(view, wants);
      case 'flac':
        return _flac(view, wants);
      case 'ogg':
      case 'oga':
      case 'opus':
      case 'spx':
        return _ogg(view);
      case 'mp4':
      case 'm4a':
      case 'm4b':
      case 'm4p':
      case 'm4v':
      case 'mov':
      case '3gp':
      case '3g2':
        return _mp4(view, wants);
      case 'mkv':
      case 'webm':
      case 'mka':
      case 'mks':
        return _matroska(view);
      case 'wma':
      case 'asf':
      case 'wmv':
        return _asf(view);
      case 'wav':
      case 'wave':
        return _riff(view, wants);
    }
    return null;
  } catch (_) {
    // 敢吞的理由见文件头：列表调用方已有"退分类图标"的降级路径，
    // 为一次解析失败把整条列表崩掉不划算。
    return null;
  }
}

/// 只有一整段字节（头段，或小文件全量）时的便捷入口。
MediaCover? extractMediaCoverFromHead(
  Uint8List head,
  MediaKind kind,
  String extension,
) => extractMediaCover(
  MediaCoverBytes(prefix: head, fileSize: head.length),
  kind,
  extension,
);

// ============================================================ 字节视图

/// 头段 + 尾段拼成的"文件视图"：按**绝对偏移**读，落在头段或尾段内才读得到，
/// 落在中间未知区（大 `mdat` 之类）返回 null，调用方据此停下。
class _FileView {
  _FileView(this.prefix, this.tail, this.fileSize);

  final Uint8List prefix;
  final Uint8List? tail;
  final int fileSize;

  int get length => fileSize > prefix.length ? fileSize : prefix.length;

  bool get hasTail => tail != null && tail!.isNotEmpty;

  int get tailStart => hasTail ? length - tail!.length : length;

  Uint8List? slice(int offset, int count) {
    if (count < 0 || offset < 0) return null;
    final end = offset + count;
    if (end > length) return null;
    if (end <= prefix.length) return Uint8List.sublistView(prefix, offset, end);
    if (hasTail && offset >= tailStart && end <= length) {
      final s = offset - tailStart;
      return Uint8List.sublistView(tail!, s, s + count);
    }
    return null;
  }

  int? u8(int offset) {
    if (offset < 0 || offset >= length) return null;
    if (offset < prefix.length) return prefix[offset];
    if (hasTail && offset >= tailStart) return tail![offset - tailStart];
    return null;
  }

  /// 读一段大端无符号整数（[count] ∈ 1..8）
  int? readBe(int offset, int count) {
    final b = slice(offset, count);
    if (b == null) return null;
    var v = 0;
    for (final x in b) {
      v = (v << 8) | x;
    }
    return v;
  }
}

// ============================================================ 通用工具

bool _startsWith(Uint8List b, List<int> sig) {
  if (b.length < sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[i] != sig[i]) return false;
  }
  return true;
}

bool _eqAscii(Uint8List b, int off, String s) {
  if (off < 0 || off + s.length > b.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (b[off + i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

/// 4 字节大端
int _be32(Uint8List b, int off) {
  if (off + 4 > b.length) return -1;
  return (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
}

/// 3 字节大端
int _be24(Uint8List b, int off) {
  if (off + 3 > b.length) return -1;
  return (b[off] << 16) | (b[off + 1] << 8) | b[off + 2];
}

/// 8 字节大端（可能 > 2^53，这里只用它做边界判断，够用）
int _be64(Uint8List b, int off) {
  if (off + 8 > b.length) return -1;
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v = (v << 8) | b[off + i];
  }
  return v;
}

int _le16(Uint8List b, int off) {
  if (off + 2 > b.length) return -1;
  return b[off] | (b[off + 1] << 8);
}

int _le32(Uint8List b, int off) {
  if (off + 4 > b.length) return -1;
  return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);
}

int _le64(Uint8List b, int off) {
  if (off + 8 > b.length) return -1;
  var v = 0;
  for (var i = 7; i >= 0; i--) {
    v = (v << 8) | b[off + i];
  }
  return v;
}

int _indexOfByte(Uint8List b, int value, int from) {
  for (var i = from; i < b.length; i++) {
    if (b[i] == value) return i;
  }
  return -1;
}

int _indexOfSequence(Uint8List b, List<int> sig, [int from = 0]) {
  if (sig.isEmpty) return -1;
  outer:
  for (var i = from; i + sig.length <= b.length; i++) {
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) continue outer;
    }
    return i;
  }
  return -1;
}

/// 归一化图片 MIME；认不出返回 null
String? _normalizeImageMime(String raw) {
  final m = raw.trim().toLowerCase().replaceAll('\u0000', '');
  if (m == 'image/jpg') return 'image/jpeg';
  if (m.startsWith('image/')) return m;
  return null;
}

/// 图片 magic number → MIME（认不出返回 null）
String? imageMimeOf(Uint8List b) {
  if (b.length < 4) return null;
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return 'image/png';
  }
  if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
    return 'image/gif';
  }
  if (b[0] == 0x42 && b[1] == 0x4D) return 'image/bmp';
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

/// 收口：长度闸门 + magic 校验 + MIME 归一化。任何一步不过 → null。
MediaCover? _finishCover(Uint8List raw, String mimeHint, String source) {
  if (raw.isEmpty || raw.length > kMediaCoverMaxBytes) return null;
  final magic = imageMimeOf(raw);
  if (magic == null) return null;
  final hint = _normalizeImageMime(mimeHint);
  if (hint != null && hint != magic) {
    // MIME 与 magic 冲突（例如 APIC 写了 image/jpeg 却是 PNG）→ 信 magic
    return MediaCover(
      bytes: Uint8List.fromList(raw),
      mime: magic,
      source: '$source(mime-hint:$hint)',
    );
  }
  return MediaCover(
    bytes: Uint8List.fromList(raw),
    mime: hint ?? magic,
    source: source,
  );
}

// ============================================================ ID3v2 (MP3)

/// 4 字节 syncsafe 整数（每字节只用低 7 位）
int? _syncsafe(Uint8List b, int off) {
  if (off + 4 > b.length) return null;
  var v = 0;
  for (var i = 0; i < 4; i++) {
    final x = b[off + i];
    if (x & 0x80 != 0) return null;
    v = (v << 7) | (x & 0x7F);
  }
  return v;
}

/// 去掉 unsynchronisation 塞进去的 `FF 00`（ID3v2.3 是整标签级，v2.4 是帧级）
Uint8List _deunsynchronise(Uint8List b) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < b.length; i++) {
    out.addByte(b[i]);
    if (b[i] == 0xFF && i + 1 < b.length && b[i + 1] == 0x00) i++;
  }
  return out.toBytes();
}

MediaCover? _id3v2(_FileView view, [List<MediaCoverRange>? wants]) {
  final p = view.prefix;
  if (p.length < 10) return null;
  if (!(p[0] == 0x49 && p[1] == 0x44 && p[2] == 0x33)) return null;
  final major = p[3];
  if (major < 2 || major > 4) return null;
  final flags = p[5];
  final size = _syncsafe(p, 6);
  if (size == null || size < 0) return null;
  final tagEnd = 10 + size;
  final availableEnd = tagEnd < p.length ? tagEnd : p.length;
  if (availableEnd <= 10) return null;
  var body = p.sublist(10, availableEnd);
  // 整标签级 unsynchronisation（v2.3 常见）；v2.4 还有帧级，见下
  if (flags & 0x80 != 0) body = _deunsynchronise(body);

  var off = 0;
  if (flags & 0x40 != 0) off = _skipId3ExtendedHeader(body, major);
  if (off < 0 || off > body.length) return null;

  while (off < body.length) {
    final String id;
    final int frameSize;
    final int headerSize;
    if (major == 2) {
      if (off + 6 > body.length) break;
      headerSize = 6;
      frameSize = _be24(body, off + 3);
      id = _ascii3(body, off);
    } else {
      if (off + 10 > body.length) break;
      headerSize = 10;
      frameSize = major >= 4
          ? (_syncsafe(body, off + 4) ?? -1)
          : _be32(body, off + 4);
      id = _ascii4(body, off);
    }
    if (frameSize < 0) break;
    // 全 0 帧头 = padding，后面没了
    if (id.isEmpty || id.codeUnitAt(0) == 0) break;
    if (!_isValidFrameId(id)) break;
    final dataStart = off + headerSize;
    final dataEnd = dataStart + frameSize;
    // 帧数据不完整（头段被截断 / 长度越界）→ **不硬截半张图**。
    // 若是 APIC/PIC，且没有 unsynchronisation 打乱字节偏移，就把"图片在文件里
    // 的绝对区间"报给调用方，由它发第二段精确请求（文件头的"两段式"）。
    if (dataEnd > body.length) {
      if (wants != null && (id == 'APIC' || id == 'PIC') && flags & 0x80 == 0) {
        var mappable = true;
        if (major >= 4 && headerSize == 10) {
          // 压缩 / 加密 / 帧级 unsync / 长度指示器都会让偏移失真 → 不报区间
          if (body[off + 9] & 0x0F != 0) mappable = false;
        }
        if (mappable) {
          final want = _id3TruncatedPictureRange(
            body: body,
            frameDataStart: dataStart,
            frameSize: frameSize,
            major: major,
            fileSize: view.fileSize,
          );
          if (want != null) wants.add(want);
        }
      }
      break;
    }
    if (id == 'APIC' || id == 'PIC') {
      var frame = body.sublist(dataStart, dataEnd);
      if (major >= 4 && headerSize == 10) {
        final frameFlags = body[off + 9];
        // 帧级 unsynchronisation（v2.4）
        if (frameFlags & 0x02 != 0) frame = _deunsynchronise(frame);
        // 帧级 data length indicator：前 4 字节是 syncsafe 实际长度
        if (frameFlags & 0x01 != 0 && frame.length >= 4) {
          final real = _syncsafe(frame, 0);
          if (real != null && real <= frame.length - 4) {
            frame = frame.sublist(4, 4 + real);
          }
        }
      }
      final cover = _parseId3Picture(frame, major);
      if (cover != null) return cover;
    }
    off = dataEnd;
  }
  return null;
}

/// v2.3 的 extended header 长度字段**不含**那 4 字节本身；v2.4 **含**。
int _skipId3ExtendedHeader(Uint8List body, int major) {
  if (body.length < 4) return 0;
  if (major >= 4) {
    final s = _syncsafe(body, 0);
    return s ?? 0;
  }
  final s = _be32(body, 0);
  return s < 0 ? 0 : 4 + s;
}

bool _isValidFrameId(String id) {
  for (final c in id.codeUnits) {
    final ok = (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39); // A-Z 0-9
    if (!ok) return false;
  }
  return true;
}

String _ascii3(Uint8List b, int off) {
  if (off + 3 > b.length) return '';
  return String.fromCharCodes(b.sublist(off, off + 3));
}

String _ascii4(Uint8List b, int off) {
  if (off + 4 > b.length) return '';
  return String.fromCharCodes(b.sublist(off, off + 4));
}

/// APIC（2.3/2.4）/ PIC（2.2）帧体 → 封面
MediaCover? _parseId3Picture(Uint8List d, int major) {
  final h = _id3PicturePayloadHeader(d, major);
  if (h == null) return null;
  return _finishCover(
    Uint8List.sublistView(d, h.offset),
    h.mimeHint,
    'id3v2.$major/${major == 2 ? 'PIC' : 'APIC'}',
  );
}

/// 只解 "图片数据从帧体哪个偏移开始" 与 MIME 提示 —— 图片本身可以在后面。
///
/// [d] **允许被截断**（只要 MIME / picture type / description 这几段还在），
/// 因为第二段取字节必须先知道图片的绝对起点。返回 null = 连起点都算不出来。
({int offset, String mimeHint})? _id3PicturePayloadHeader(
  Uint8List d,
  int major,
) {
  if (d.length < 4) return null;
  final enc = d[0];
  var i = 1;
  String mimeHint = '';
  if (major == 2) {
    if (i + 3 > d.length) return null;
    final fmt = String.fromCharCodes(d.sublist(i, i + 3)).toUpperCase();
    i += 3;
    mimeHint = switch (fmt) {
      'PNG' => 'image/png',
      'JPG' || 'JPEG' => 'image/jpeg',
      'GIF' => 'image/gif',
      'BMP' => 'image/bmp',
      _ => '',
    };
  } else {
    final nul = _indexOfByte(d, 0, i);
    if (nul < 0) return null;
    mimeHint = latin1.decode(d.sublist(i, nul), allowInvalid: true);
    i = nul + 1;
  }
  // picture type
  if (i >= d.length) return null;
  i += 1;
  // description：UTF-16 用双字节 0 结束，其余用单字节
  if (enc == 1 || enc == 2) {
    var j = i;
    var found = -1;
    while (j + 1 < d.length) {
      if (d[j] == 0 && d[j + 1] == 0) {
        found = j;
        break;
      }
      j += 2;
    }
    if (found < 0) return null;
    i = found + 2;
  } else {
    final nul = _indexOfByte(d, 0, i);
    if (nul < 0) return null;
    i = nul + 1;
  }
  if (i >= d.length) return null;
  return (offset: i, mimeHint: mimeHint);
}

/// 被截断的 APIC/PIC 帧 → "图片在文件里的绝对区间 [start, end)"。
///
/// 只在 [scanMediaCover] 语境下用；前提是**没有 unsynchronisation**
/// （有的话 body 偏移与文件偏移不是 1:1，区间会算错 ⇒ 调用方已经先挡掉）。
MediaCoverRange? _id3TruncatedPictureRange({
  required Uint8List body,
  required int frameDataStart,
  required int frameSize,
  required int major,
  required int fileSize,
}) {
  if (frameSize <= 0) return null;
  if (frameDataStart < 0 || frameDataStart >= body.length) return null;
  final h = _id3PicturePayloadHeader(
    Uint8List.sublistView(body, frameDataStart),
    major,
  );
  if (h == null) return null;
  final start = 10 + frameDataStart + h.offset;
  final end = 10 + frameDataStart + frameSize;
  if (fileSize > 0 && end > fileSize) return null; // 声明越过文件尾 = 脏数据
  return MediaCoverRange(
    start: start,
    end: end,
    mimeHint: h.mimeHint,
    source: 'id3v2.$major/${major == 2 ? 'PIC' : 'APIC'}',
  );
}

// ============================================================ FLAC

/// FLAC 的 `METADATA_BLOCK_PICTURE`（去掉 4 字节块头之后的结构体）
MediaCover? _parseFlacPicture(Uint8List d, String source) {
  final h = _flacPictureHeader(d);
  if (h == null) return null;
  if (h.offset + h.dataLen > d.length) return null;
  return _finishCover(
    Uint8List.sublistView(d, h.offset, h.offset + h.dataLen),
    h.mime,
    source,
  );
}

/// 只解 FLAC picture 结构体的头部：图片数据的**块内偏移**、MIME、声明长度。
///
/// [d] 允许被截断（只要 mime / description / 尺寸 / dataLen 那几段还在）——
/// "大封面比预读更长"时就靠它算出第二段要取哪一段。
({int offset, String mime, int dataLen})? _flacPictureHeader(Uint8List d) {
  var off = 0;
  // picture type
  if (off + 4 > d.length) return null;
  off += 4;
  // mime
  final mimeLen = _be32(d, off);
  if (mimeLen < 0) return null;
  off += 4;
  if (off + mimeLen > d.length) return null;
  final mime = latin1.decode(d.sublist(off, off + mimeLen), allowInvalid: true);
  off += mimeLen;
  // description
  final descLen = _be32(d, off);
  if (descLen < 0) return null;
  off += 4;
  if (off + descLen > d.length) return null;
  off += descLen;
  // width/height/depth/colors
  if (off + 16 > d.length) return null;
  off += 16;
  // data
  final dataLen = _be32(d, off);
  if (dataLen < 0) return null;
  off += 4;
  return (offset: off, mime: mime, dataLen: dataLen);
}

MediaCover? _flac(_FileView view, [List<MediaCoverRange>? wants]) {
  final p = view.prefix;
  if (p.length < 8) return null;
  if (!_eqAscii(p, 0, 'fLaC')) return null;
  var off = 4; // 跳过 'fLaC'
  while (off + 4 <= p.length) {
    final b0 = p[off];
    final isLast = b0 & 0x80 != 0;
    final type = b0 & 0x7F;
    final len = _be24(p, off + 1);
    if (len < 0) return null;
    final dataStart = off + 4;
    final dataEnd = dataStart + len;
    if (dataEnd > p.length) {
      // 块被截断（大封面比预读更长）：picture 块报出图片的绝对区间
      if (wants != null && type == 6) {
        final h = _flacPictureHeader(Uint8List.sublistView(p, dataStart));
        if (h != null) {
          wants.add(
            MediaCoverRange(
              start: dataStart + h.offset,
              end: dataStart + h.offset + h.dataLen,
              mimeHint: h.mime,
              source: 'flac/picture',
            ),
          );
        }
      }
      return null;
    }
    if (type == 6) {
      final cover = _parseFlacPicture(
        Uint8List.sublistView(p, dataStart, dataEnd),
        'flac/picture',
      );
      if (cover != null) return cover;
    } else if (type == 4) {
      final cover = _parseVorbisComment(
        p.sublist(dataStart, dataEnd),
        'flac/vorbis',
      );
      if (cover != null) return cover;
    }
    off = dataEnd;
    if (isLast) break;
  }
  return null;
}

// ============================================================ Vorbis comment

/// Vorbis comment 块（`vendor_length + vendor + count + (len + 'KEY=value')*`）
MediaCover? _parseVorbisComment(Uint8List d, String source) {
  var off = 0;
  final vendorLen = _le32(d, off);
  if (vendorLen < 0 || off + 4 + vendorLen > d.length) return null;
  off += 4 + vendorLen;
  final count = _le32(d, off);
  if (count < 0) return null;
  off += 4;
  String? coverArtMime;
  MediaCover? base64Picture;
  MediaCover? legacyCover;
  for (var i = 0; i < count; i++) {
    final len = _le32(d, off);
    if (len < 0) break;
    off += 4;
    if (off + len > d.length) break;
    final entry = latin1.decode(d.sublist(off, off + len), allowInvalid: true);
    off += len;
    final eq = entry.indexOf('=');
    if (eq <= 0) continue;
    final key = entry.substring(0, eq).toUpperCase();
    final value = entry.substring(eq + 1);
    if (key == 'METADATA_BLOCK_PICTURE') {
      final block = _decodeBase64(value);
      if (block != null) {
        base64Picture ??= _parseFlacPicture(
          block,
          '$source/METADATA_BLOCK_PICTURE',
        );
      }
    } else if (key == 'COVERARTMIME') {
      coverArtMime = value;
    } else if (key == 'COVERART') {
      final raw = _decodeBase64(value);
      if (raw != null) {
        legacyCover ??= _finishCover(
          raw,
          coverArtMime ?? '',
          '$source/COVERART',
        );
      }
    }
  }
  return base64Picture ?? legacyCover;
}

Uint8List? _decodeBase64(String s) {
  final cleaned = s.replaceAll(RegExp(r'\s'), '');
  if (cleaned.isEmpty) return null;
  try {
    return base64.decode(cleaned);
  } catch (_) {
    return null;
  }
}

// ============================================================ OGG

MediaCover? _ogg(_FileView view) {
  final p = view.prefix;
  if (p.length < 27) return null;
  if (!_eqAscii(p, 0, 'OggS')) return null;
  // 把页的 segment 负载按顺序拼起来（comment 包头可能跨页）
  final out = BytesBuilder(copy: false);
  var off = 0;
  while (off + 27 <= p.length) {
    if (!_eqAscii(p, off, 'OggS')) break;
    final segCount = p[off + 26];
    if (off + 27 + segCount > p.length) break;
    var dataLen = 0;
    for (var i = 0; i < segCount; i++) {
      dataLen += p[off + 27 + i];
    }
    final dataStart = off + 27 + segCount;
    final dataEnd = dataStart + dataLen;
    if (dataEnd > p.length) {
      out.add(p.sublist(dataStart, p.length));
      break;
    }
    out.add(p.sublist(dataStart, dataEnd));
    off = dataEnd;
  }
  final buf = out.toBytes();
  // comment 包头：0x03 + 'vorbis'
  final idx = _indexOfSequence(buf, const [
    0x03,
    0x76,
    0x6F,
    0x72,
    0x62,
    0x69,
    0x73,
  ]);
  if (idx < 0) return null;
  return _parseVorbisComment(Uint8List.sublistView(buf, idx + 7), 'ogg/vorbis');
}

// ============================================================ MP4 / M4A / M4V

const List<int> _mp4Brands = [
  0x66, 0x74, 0x79, 0x70, // ftyp
  0x6D, 0x6F, 0x6F, 0x76, // moov
  0x6D, 0x64, 0x61, 0x74, // mdat
  0x66, 0x72, 0x65, 0x65, // free
  0x73, 0x6B, 0x69, 0x70, // skip
  0x77, 0x69, 0x64, 0x65, // wide
  0x70, 0x6E, 0x6F, 0x74, // pnot
];

bool _looksLikeMp4(Uint8List head) {
  if (head.length < 8) return false;
  final type = head.sublist(4, 8);
  for (var i = 0; i < _mp4Brands.length; i += 4) {
    var match = true;
    for (var k = 0; k < 4; k++) {
      if (type[k] != _mp4Brands[i + k]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

class _Box {
  const _Box(this.type, this.bodyStart, this.bodySize);
  final String type;

  /// 内容（不含 8/16 字节箱子头）的绝对起点
  final int bodyStart;
  final int bodySize;
}

/// 读一个箱子头（支持 32 位 size、64 位 largesize、size==0 到文件尾）。
_Box? _boxAt(_FileView v, int offset) {
  final hdr = v.slice(offset, 8);
  if (hdr == null) return null;
  final size32 = _be32(hdr, 0);
  final type = String.fromCharCodes(hdr.sublist(4, 8));
  var headerSize = 8;
  int size;
  if (size32 == 1) {
    // 64 位 largesize（`co64`/大文件里常见的大箱子写法）
    final big = v.slice(offset + 8, 8);
    if (big == null) return null;
    size = _be64(big, 0);
    headerSize = 16;
  } else if (size32 == 0) {
    size = v.length - offset; // 一直到文件尾
  } else {
    size = size32;
  }
  if (size < headerSize) return null;
  if (offset + size > v.length) return null; // 箱子越过已知范围
  return _Box(type, offset + headerSize, size - headerSize);
}

/// 在 [parentBodyStart, parentBodyStart+parentBodySize) 里找第一个 [type] 箱子
_Box? _findChild(_FileView v, int bodyStart, int bodySize, String type) {
  var off = bodyStart;
  final end = bodyStart + bodySize;
  while (off + 8 <= end) {
    final box = _boxAt(v, off);
    if (box == null) return null;
    if (box.type == type) return box;
    final span = (box.bodyStart - off) + box.bodySize;
    if (span <= 0) return null;
    off += span;
  }
  return null;
}

MediaCover? _mp4(_FileView view, [List<MediaCoverRange>? wants]) {
  // 顶层遍历：moov 可能在头（fast-start）也可能在尾
  final moov = _findChild(view, 0, view.length, 'moov');
  if (moov == null) return null;
  final udta = _findChild(view, moov.bodyStart, moov.bodySize, 'udta');
  if (udta == null) return null;
  final meta = _findChild(view, udta.bodyStart, udta.bodySize, 'meta');
  if (meta == null) return null;
  // `meta` 是 FullBox：正文前 4 字节是 version+flags（少数老 QuickTime 没有）
  final ilst =
      _findChild(view, meta.bodyStart + 4, meta.bodySize - 4, 'ilst') ??
      _findChild(view, meta.bodyStart, meta.bodySize, 'ilst');
  if (ilst == null) return null;
  final covr = _findChild(view, ilst.bodyStart, ilst.bodySize, 'covr');
  if (covr == null) return null;
  // covr 里放若干个 `data` 箱子，取第一个能认得出来的
  var off = covr.bodyStart;
  final end = covr.bodyStart + covr.bodySize;
  while (off + 8 <= end) {
    final box = _boxAt(view, off);
    if (box == null) return null;
    if (box.type == 'data') {
      final body = view.slice(box.bodyStart, box.bodySize);
      if (body != null && body.length > 8) {
        final typeIndicator = _be32(body, 0) & 0xFFFFFF;
        final payload = Uint8List.sublistView(body, 8);
        final hint = switch (typeIndicator) {
          13 => 'image/jpeg',
          14 => 'image/png',
          27 => 'image/bmp',
          _ => '',
        };
        final cover = _finishCover(payload, hint, 'mp4/covr');
        if (cover != null) return cover;
      } else if (wants != null && box.bodySize > 8) {
        // `data` 箱子的正文落在"头段与尾段之间的未知区"（例如 moov 在文件头、
        // 但 covr 图片比预读更长）→ 报出精确区间，由调用方取第二段。
        // 这里读不到 type indicator（正文不在手边），MIME 交给图片 magic 判。
        wants.add(
          MediaCoverRange(
            start: box.bodyStart + 8,
            end: box.bodyStart + box.bodySize,
            mimeHint: '',
            source: 'mp4/covr',
          ),
        );
      }
    }
    final span = (box.bodyStart - off) + box.bodySize;
    if (span <= 0) return null;
    off += span;
  }
  return null;
}

// ============================================================ Matroska / WebM

const List<int> kMatroskaMagic = [0x1A, 0x45, 0xDF, 0xA3];
const int _mSegment = 0x18538067;
const int _mAttachments = 0x1941A469;
const int _mAttachedFile = 0x61A7;
const int _mFileName = 0x466E;
const int _mFileMime = 0x4660;
const int _mFileData = 0x465C;

/// EBML 变长整数。[keepMarker] = true 时保留 marker 位（元素 ID 的算法），
/// false 时去掉（长度字段的算法）。`known=false` 表示"未知长度"（全 1）。
({int value, int length, bool known})? _ebmlVint(
  _FileView v,
  int off, {
  bool keepMarker = false,
}) {
  final first = v.u8(off);
  if (first == null) return null;
  var mask = 0x80;
  var len = 1;
  while (len <= 8 && (first & mask) == 0) {
    mask >>= 1;
    len++;
  }
  if (len > 8) return null;
  var value = keepMarker ? first : (first & (mask - 1));
  for (var i = 1; i < len; i++) {
    final b = v.u8(off + i);
    if (b == null) return null;
    value = (value << 8) | b;
  }
  final unknown = !keepMarker && value == (1 << (7 * len)) - 1;
  return (value: value, length: len, known: !unknown);
}

class _Ebml {
  const _Ebml(this.id, this.dataStart, this.size);
  final int id;
  final int dataStart;

  /// null = 未知长度（规范允许，常见于 Segment / Cluster）
  final int? size;
}

_Ebml? _ebmlAt(_FileView v, int off) {
  final id = _ebmlVint(v, off, keepMarker: true);
  if (id == null) return null;
  final size = _ebmlVint(v, off + id.length);
  if (size == null) return null;
  final dataStart = off + id.length + size.length;
  if (size.known && dataStart + size.value > v.length) return null;
  return _Ebml(id.value, dataStart, size.known ? size.value : null);
}

MediaCover? _matroska(_FileView view) {
  if (!_startsWith(view.prefix, kMatroskaMagic)) return null;
  // 1) 从文件头按 EBML 结构走一遍（Attachments 在头部时命中）
  final walked = _matroskaWalk(view);
  if (walked != null) return walked;
  // 2) `Attachments` 常被追加在文件末尾 → 在尾段里直接找元素 ID
  final buffers = <Uint8List>[if (view.hasTail) view.tail!, view.prefix];
  for (final buf in buffers) {
    final base = identical(buf, view.tail) ? view.tailStart : 0;
    var from = 0;
    while (true) {
      final rel = _indexOfSequence(buf, const [0x19, 0x41, 0xA4, 0x69], from);
      if (rel < 0) break;
      from = rel + 1;
      final el = _ebmlAt(view, base + rel);
      if (el == null || el.id != _mAttachments) continue;
      final cover = _matroskaAttachments(view, el);
      if (cover != null) return cover;
    }
  }
  return null;
}

MediaCover? _matroskaWalk(_FileView v) {
  var off = 0;
  while (off < v.length) {
    final el = _ebmlAt(v, off);
    if (el == null) return null;
    if (el.id == _mSegment) {
      final size = el.size ?? (v.length - el.dataStart);
      return _matroskaChildren(v, el.dataStart, el.dataStart + size);
    }
    if (el.size == null) return null;
    off = el.dataStart + el.size!;
  }
  return null;
}

MediaCover? _matroskaChildren(_FileView v, int start, int end) {
  var off = start;
  while (off < end) {
    final el = _ebmlAt(v, off);
    if (el == null) return null;
    if (el.id == _mAttachments) {
      final cover = _matroskaAttachments(v, el);
      if (cover != null) return cover;
    }
    if (el.size == null) return null; // 未知长度（Cluster）→ 跳不过，停
    off = el.dataStart + el.size!;
  }
  return null;
}

MediaCover? _matroskaAttachments(_FileView v, _Ebml attachments) {
  final end = attachments.size == null
      ? v.length
      : attachments.dataStart + attachments.size!;
  var off = attachments.dataStart;
  MediaCover? first;
  while (off < end) {
    final el = _ebmlAt(v, off);
    if (el == null) return first;
    if (el.id == _mAttachedFile) {
      final cover = _matroskaAttachedFile(v, el);
      if (cover != null) {
        // 优先 `cover.*` / image/*，否则先用第一个
        if (_looksLikeCoverName(cover.source)) return cover;
        first ??= cover;
      }
    }
    if (el.size == null) break;
    off = el.dataStart + el.size!;
  }
  return first;
}

bool _looksLikeCoverName(String source) {
  final s = source.toLowerCase();
  return s.contains('cover') || s.contains('folder') || s.contains('poster');
}

MediaCover? _matroskaAttachedFile(_FileView v, _Ebml file) {
  final end = file.size == null ? v.length : file.dataStart + file.size!;
  var off = file.dataStart;
  String name = '';
  String mime = '';
  Uint8List? data;
  while (off < end) {
    final el = _ebmlAt(v, off);
    if (el == null) break;
    final span = el.size;
    if (el.id == _mFileName && span != null) {
      final b = v.slice(el.dataStart, span);
      if (b != null) name = utf8.decode(b, allowMalformed: true);
    } else if (el.id == _mFileMime && span != null) {
      final b = v.slice(el.dataStart, span);
      if (b != null) mime = latin1.decode(b, allowInvalid: true);
    } else if (el.id == _mFileData && span != null) {
      final b = v.slice(el.dataStart, span);
      if (b != null) data = Uint8List.fromList(b);
    }
    if (span == null) break;
    off = el.dataStart + span;
  }
  if (data == null) return null;
  final cover = _finishCover(
    data,
    mime,
    'matroska/${name.isEmpty ? 'attachment' : name}',
  );
  return cover;
}

// ============================================================ ASF / WMA

const List<int> kAsfHeaderGuid = [
  0x30,
  0x26,
  0xB2,
  0x75,
  0x8E,
  0x66,
  0xCF,
  0x11,
  0xA6,
  0xD9,
  0x00,
  0xAA,
  0x00,
  0x62,
  0xCE,
  0x6C,
];
const List<int> _asfExtendedContent = [
  0x40,
  0xA4,
  0xD0,
  0xD2,
  0x07,
  0xE3,
  0xD2,
  0x11,
  0x97,
  0xF0,
  0x00,
  0xA0,
  0xC9,
  0x5E,
  0xA8,
  0x50,
];
const List<int> _asfMetadata = [
  0xEA,
  0xCB,
  0xF8,
  0xC5,
  0xAF,
  0x5B,
  0x77,
  0x48,
  0x84,
  0x67,
  0xAA,
  0x8C,
  0x44,
  0xFA,
  0x4C,
  0xCA,
];
const List<int> _asfMetadataLibrary = [
  0x94,
  0x1C,
  0x23,
  0x44,
  0x98,
  0x94,
  0xD1,
  0x49,
  0xA1,
  0x41,
  0x1D,
  0x13,
  0x4E,
  0x45,
  0x70,
  0x54,
];

MediaCover? _asf(_FileView view) {
  final p = view.prefix;
  if (p.length < 30) return null;
  if (!_startsWith(p, kAsfHeaderGuid)) return null;
  final headerSize = _le64(p, 16);
  if (headerSize < 30) return null;
  final end = headerSize < p.length ? headerSize : p.length;
  var off = 30;
  while (off + 24 <= end) {
    final guid = Uint8List.sublistView(p, off, off + 16);
    final objSize = _le64(p, off + 16);
    if (objSize < 24) break;
    final objEnd = off + objSize;
    if (objEnd > end) break;
    final bodyStart = off + 24;
    final bodyEnd = objEnd;
    MediaCover? cover;
    if (_guidEquals(guid, _asfExtendedContent)) {
      cover = _asfExtendedContentDescription(p, bodyStart, bodyEnd);
    } else if (_guidEquals(guid, _asfMetadata) ||
        _guidEquals(guid, _asfMetadataLibrary)) {
      cover = _asfMetadataObject(p, bodyStart, bodyEnd);
    }
    if (cover != null) return cover;
    off = objEnd;
  }
  return null;
}

bool _guidEquals(Uint8List a, List<int> b) {
  if (a.length < b.length) return false;
  for (var i = 0; i < b.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

MediaCover? _asfExtendedContentDescription(Uint8List p, int start, int end) {
  final count = _le16(p, start);
  if (count < 0) return null;
  var off = start + 2;
  for (var i = 0; i < count; i++) {
    final nameLen = _le16(p, off);
    if (nameLen < 0) return null;
    off += 2;
    if (off + nameLen + 4 > end) return null;
    final name = _asfAttributeName(_utf16le(p, off, nameLen));
    off += nameLen;
    final valueType = _le16(p, off);
    final valueLen = _le16(p, off + 2);
    off += 4;
    if (valueLen < 0 || off + valueLen > end) return null;
    if (valueType == 1 && name == 'WM/PICTURE') {
      return _parseWmPicture(Uint8List.sublistView(p, off, off + valueLen));
    }
    off += valueLen;
  }
  return null;
}

MediaCover? _asfMetadataObject(Uint8List p, int start, int end) {
  final count = _le16(p, start);
  if (count < 0) return null;
  var off = start + 2;
  for (var i = 0; i < count; i++) {
    if (off + 12 > end) return null;
    final nameLen = _le16(p, off + 4);
    final dataLen = _le32(p, off + 8);
    off += 12;
    if (nameLen < 0 || dataLen < 0) return null;
    if (off + nameLen > end) return null;
    final name = _asfAttributeName(_utf16le(p, off, nameLen));
    off += nameLen;
    if (off + dataLen > end) return null;
    if (name == 'WM/PICTURE' && dataLen > 0) {
      return _parseWmPicture(Uint8List.sublistView(p, off, off + dataLen));
    }
    off += dataLen;
  }
  return null;
}

/// ASF 属性的名字是**以 NUL 结尾**的 UTF-16LE 串，且 `nameLen` **含**那个结尾的
/// `0x0000`（ASF 规范 Extended Content Description / Metadata Object 两处都一样）。
///
/// 所以比较前**必须**先截到第一个 NUL —— 否则真实的 `WM/Picture` 名字会解码成
/// `'WM/Picture\u0000'`，永远匹配不上 `'WM/PICTURE'`。
///
/// 历史 bug（本批真机样本实测发现）：解析器当时直接 `name.toUpperCase() ==
/// 'WM/PICTURE'`，而单测夹具里写的是**不带 NUL** 的名字 —— 于是"测试全绿、
/// 真实 ASF 文件一律拿不到封面"。实测证据见 docs/audio-codec-fallback.md §4.3：
/// 在真实 Windows 产 ASF（`real_example.wma`，WMFSDK 12.0.15063.332）里注入
/// 规范形态的 `WM/Picture` 后，修复前 `extractMediaCoverFromHead` 返回 `null`，
/// 修复后返回 `asf/WM-Picture` + 图片字节。
String _asfAttributeName(String raw) {
  final nul = raw.indexOf('\x00');
  final trimmed = nul >= 0 ? raw.substring(0, nul) : raw;
  return trimmed.toUpperCase();
}

/// 读一个**以 NUL 结尾**的 UTF-16LE 串，返回文本与"下一个字节"的偏移。
///
/// 返回 null = 到片段末尾都没有遇到 NUL（截断 / 不是合法串）。
({String text, int end})? _utf16z(Uint8List b, int off) {
  final units = <int>[];
  var i = off;
  while (i + 1 < b.length) {
    final u = b[i] | (b[i + 1] << 8);
    i += 2;
    if (u == 0) return (text: String.fromCharCodes(units), end: i);
    units.add(u);
  }
  return null;
}

/// ASF `WM/Picture` 的值结构（**真实规范**，逐字对齐 ASF 规范
/// `ASF_Metadata_Object` 的 `WM/Picture` 属性与 ffmpeg `libavformat/asfdec_f.c`
/// 的 `asf_read_picture`）：
///
/// ```
/// BYTE  pictureType
/// DWORD dataLen
/// WCHAR mime[]         —— **NUL 结尾**，没有长度前缀
/// WCHAR description[]  —— **NUL 结尾**，没有长度前缀
/// BYTE  data[dataLen]
/// ```
///
/// 历史 bug：这里曾按 **ID3 APIC** 的形状多读 `mimeLen`/`descLen` 两个 4 字节
/// 长度前缀 —— 那套字节只在"夹具自己写的"上自洽，真实 ASF 一律解析失败
/// （实测见 docs/audio-codec-fallback.md §4.3）。
MediaCover? _parseWmPicture(Uint8List d) {
  if (d.length < 5) return null;
  var off = 1; // picture type
  final dataLen = _le32(d, off);
  if (dataLen < 0) return null;
  off += 4;
  final mime = _utf16z(d, off);
  if (mime == null) return null;
  final desc = _utf16z(d, mime.end);
  if (desc == null) return null;
  off = desc.end;
  if (off + dataLen > d.length) return null;
  return _finishCover(
    Uint8List.sublistView(d, off, off + dataLen),
    mime.text,
    'asf/WM-Picture',
  );
}

String _utf16le(Uint8List b, int off, int len) {
  if (len <= 0 || off + len > b.length) return '';
  final units = <int>[];
  for (var i = 0; i + 1 < len; i += 2) {
    units.add(b[off + i] | (b[off + i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

// ============================================================ RIFF / WAV

MediaCover? _riff(_FileView view, [List<MediaCoverRange>? wants]) {
  final p = view.prefix;
  if (p.length < 12) return null;
  if (!_eqAscii(p, 0, 'RIFF')) return null;
  var off = 12; // 'RIFF' + size + form type
  while (off + 8 <= p.length) {
    final size = _le32(p, off + 4);
    if (size < 0) return null;
    final dataStart = off + 8;
    final dataEnd = dataStart + size;
    if (dataEnd > p.length) return null;
    if (_eqAscii(p, off, 'ID3 ')) {
      // 注意：WAV 里这一段是**嵌在 RIFF 块里**的，偏移不是文件绝对偏移
      // （fileSize=0 的子视图），所以**不**在这里报第二段区间；块本身在预读内
      // 就已经整段可见，不需要两段式。
      final cover = _id3v2(
        _FileView(Uint8List.sublistView(p, dataStart, dataEnd), null, 0),
      );
      if (cover != null) return cover;
    }
    off = dataEnd + (size & 1); // chunk 按偶数对齐
  }
  return null;
}

// ============================================================ 内存缓存
//
// FIFO 字节缓存，容量与头像缓存（128）同量级。缓存键由调用方拼
// （建议 `<path|url>|<mtime>|<size>`），换文件后键变、自然回源。

const int kMediaCoverCacheLimit = 128;

final Map<String, MediaCover> _mediaCoverCache = <String, MediaCover>{};

/// 缓存命中 → 封面；没有 → null。
MediaCover? mediaCoverCacheGet(String key) => _mediaCoverCache[key];

/// 写入缓存（超过上限按插入顺序 FIFO 淘汰）。
void mediaCoverCachePut(String key, MediaCover cover) {
  _mediaCoverCache[key] = cover;
  while (_mediaCoverCache.length > kMediaCoverCacheLimit) {
    _mediaCoverCache.remove(_mediaCoverCache.keys.first);
  }
}

/// 失败负缓存 TTL：**这个文件抓不出来** ⇒ 这段时间内不再重发抓取请求。
///
/// 语义照本仓既有先例 `kVideoFrameNegativeTtl`（`video_frame_thumb.dart`）：
/// 封面这条路是"两段式 Range"（超预读再发精确 Range，失败样本可达 MB 级），
/// 列表滚动时同一文件被反复重建 ⇒ 失败必须被记忆，否则每次重建都重发。
///
/// ★ 只用于**单文件失败**（发过请求、解析不出/网络失败）。
/// **"这台机器/这条路做不了"**（无会话 api、kind 不支持、Drive 无 Range）
/// 在发起请求之前就返回，**不进**这张表，行为逐字节不变（r132 的分野）。
const Duration kMediaCoverNegativeTtl = Duration(minutes: 10);

final Map<String, DateTime> _mediaCoverFailedAt = <String, DateTime>{};

/// 测试可注入的时钟（生产 = [DateTime.now]）；与失败记忆同寿命。
DateTime Function() mediaCoverNow = DateTime.now;

/// 该键是否在 TTL 内被记为失败（过期即就地清除）。
bool mediaCoverFailureRemembered(String key) {
  final at = _mediaCoverFailedAt[key];
  if (at == null) return false;
  if (mediaCoverNow().difference(at) < kMediaCoverNegativeTtl) return true;
  _mediaCoverFailedAt.remove(key);
  return false;
}

/// 记一次失败（同成功缓存一样按 FIFO 封顶）。
void mediaCoverRememberFailure(String key) {
  _mediaCoverFailedAt[key] = mediaCoverNow();
  while (_mediaCoverFailedAt.length > kMediaCoverCacheLimit) {
    _mediaCoverFailedAt.remove(_mediaCoverFailedAt.keys.first);
  }
}

/// 忘掉失败记忆（成功抓到 / 主动失效后调）。
void mediaCoverForgetFailure(String key) => _mediaCoverFailedAt.remove(key);

/// 当前失败记忆里的键（只读，测试/诊断用）。
List<String> debugMediaCoverFailureKeys() => _mediaCoverFailedAt.keys.toList();

/// 主动失效：清掉某个路径前缀下的所有封面（删文件/覆盖文件后调用）。
/// 返回清掉的键，便于测试与日志。
List<String> evictMediaCovers(String keyPrefix) {
  final hit = _mediaCoverCache.keys
      .where((k) => k.startsWith(keyPrefix))
      .toList();
  for (final k in hit) {
    _mediaCoverCache.remove(k);
  }
  final failed = _mediaCoverFailedAt.keys
      .where((k) => k.startsWith(keyPrefix))
      .toList();
  for (final k in failed) {
    _mediaCoverFailedAt.remove(k);
  }
  return hit;
}

/// 清空所有封面缓存（清缓存 / 登出 / 切换服务器时用）。
void clearMediaCoverCache() {
  _mediaCoverCache.clear();
  _mediaCoverFailedAt.clear();
}

/// 当前缓存里的键（只读，测试/诊断用）。
List<String> debugMediaCoverCacheKeys() => _mediaCoverCache.keys.toList();

/// 当前缓存条数（只读，测试/诊断用）。
int debugMediaCoverCacheCount() => _mediaCoverCache.length;
