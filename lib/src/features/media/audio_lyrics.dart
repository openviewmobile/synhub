// 歌词：**免密钥公开源（lrclib.net）** + LRC 解析 + 本地缓存（文件预览页音频用）。
//
// ════════════════════════════════════════════════════════════════════════
// ★ 歌词源实测证据（本机 curl，逐字复制；代理按 AGENTS §1.2 从 PAC 读出）
// ════════════════════════════════════════════════════════════════════════
//
// ```bash
// $ curl -sS --max-time 20 http://127.0.0.1:64095/commands/pac \
//     | grep -oE "PROXY [0-9.]+:[0-9]+"
// PROXY 127.0.0.1:7897
// $ export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897
// ```
//
// ① 按标题搜索（**无需 API key、无需任何鉴权头**）：
//
// ```bash
// $ curl -sS --max-time 60 -L -w "\nHTTP:%{http_code} SIZE:%{size_download}\n" \
//     "https://lrclib.net/api/search?q=Hey%20Jude" -o /tmp/lrc_search.json
// HTTP:200 SIZE:262902
// ```
// 响应片段（首条，逐字）：
// ```json
// [{"id":36839770,"name":"Hey Jude","trackName":"Hey Jude",
//   "artistName":"The Beatles - Topic","albumName":"Hey Jude","duration":426.0,
//   "instrumental":false,
//   "plainLyrics":"Hey Jude, don't make it bad\nTake a sad song and make it better\n...",
//   ...}]
// ```
// ⇒ `/api/search` 的每条结果**自带 `plainLyrics` / `syncedLyrics`**，
//   所以"搜到即拿到歌词"，不必再打第二次（本实现据此少发一次请求）。
//
// ② 按签名精确取（`track_name` + `artist_name` + `duration`）：
//
// ```bash
// $ curl -sS --max-time 60 -L -w "\nHTTP:%{http_code} SIZE:%{size_download}\n" \
//     "https://lrclib.net/api/get?track_name=Hey%20Jude&artist_name=The%20Beatles&duration=431" \
//     -o /tmp/lrc_get.json
// HTTP:200 SIZE:13769
// ```
// 字段全集（实测）：`['albumName','artistName','duration','id','instrumental',
// 'lyricsfile','name','plainLyrics','syncedLyrics','trackName']`；
// `syncedLyrics` 前 400 字符（逐字）：
// ```
// [00:00.35] Hey Jude, don't make it bad
// [00:06.74] Take a sad song and make it better
// [00:13.58] Remember to let her into your heart
// [00:18.44] Then you can start to make it better
// [00:25.52] Hey Jude, don't be afraid
// ```
// 实测该响应 `syncedLyrics` 共 **70** 行（`grep -c` 换行）。
//
// ③ 失败态（必须能给出**可读原因**，不能静悄悄什么都不显示）：
//
// ```bash
// $ curl -sS --max-time 60 -L -w "\nHTTP:%{http_code}\n" \
//     "https://lrclib.net/api/get?track_name=zzzznotexistqqq&artist_name=nobody&duration=7"
// {"message":"Failed to find specified track","name":"TrackNotFound","statusCode":404}
// HTTP:404
// $ curl -sS -L "https://lrclib.net/api/search?q=zzzznotexistqqqxyz"
// []
// HTTP:200
// ```
// ⇒ **404 = 明确"没这首歌"**（与"网络断了"分开报）；搜索无结果 = `200 []`。
//
// ③' 源站**会过载**（第 260 轮复验时第一次就撞上，隔 6 秒重试即恢复）——
//    这就是 `LyricsFailureKind.server` 那条分支的**真实样本**，
//    界面按"歌词服务返回错误，稍后可重试 + 重试按钮"处理，**不谎报"没这首歌"**：
//
// ```bash
// $ curl -sS -L "https://lrclib.net/api/search?q=Hey+Jude"
// {"message":"The server is busy, please retry in a moment","name":"ServerOverloaded","statusCode":503}
// HTTP:503 SIZE:101
// $ sleep 6; curl -sS -L "https://lrclib.net/api/search?q=Hey+Jude" -o /tmp/lrc.json \
//     -w "HTTP:%{http_code} SIZE:%{size_download}\n"
// HTTP:200 SIZE:263302      # ← 20 条候选
// $ curl -sS -L "https://lrclib.net/api/get/13781" -w "HTTP:%{http_code} SIZE:%{size_download}\n"
// HTTP:200 SIZE:13789       # ← syncedLyrics 71 行，首行 [00:00.35] Hey Jude, don't make it bad
// ```
//
// ④ 中文歌也覆盖（URL 编码走 `--data-urlencode`，Dart 侧用 `Uri.https` 的
//    `queryParameters` 自动做同一件事）：
//
// ```bash
// $ curl -sS -L -G --data-urlencode "q=月亮代表我的心" \
//     -w "\nHTTP:%{http_code} SIZE:%{size_download}\n" \
//     "https://lrclib.net/api/search" -o /tmp/lrc_cn.json
// HTTP:200 SIZE:82213
// ```
// 前 3 条实测（id | 曲名 | 歌手 | 专辑 | 时长 | 有无 syncedLyrics）：
// ```
// 18453229 | 月亮代表我的心 | 邓丽君 | 月亮代表我的心 | 206.16 | synced: True
// 24001935 | 月亮代表我的心 | 王小帅 | 月亮代表我的心 | 231.0  | synced: False
// 27214605 | 月亮代表我的心 | 邓丽君 | 月亮代表我的心 | 211.109025 | synced: True
// ```
// 首条 `syncedLyrics` 片段：`[00:12.88] 你問我愛你有多深`（繁体，源站如此）。
// ⇒ 时长**不是整数**（`211.109025`）⇒ 解析必须宽松（见 `LyricCandidate.fromJson`）。
//
// ════════════════════════════════════════════════════════════════════════
// 设计约定
// ════════════════════════════════════════════════════════════════════════
//   * **只走公开源**：lrclib.net 无需注册/密钥；TLS 是公共 CA 签发，
//     直接用平台默认校验（**不套用** NAS 自签证书那套 TrustStore —— 那不是给
//     公网域名用的）；
//   * **只查用户要的那首**：不做任何后台/自动批量联网（打开页面默认先读本地缓存）；
//   * **能失败得清楚**：离线 / 超时 / 没这首歌 / 服务端错 / 响应看不懂，
//     五类分开报（`LyricsFailureKind`），都由界面给出"重试"入口；
//   * **缓存只存歌词本身**：key 是曲目身份（标题|歌手|时长|文件名），
//     存的是源站返回的候选 JSON，**不含任何 `_sid`/URL**（与
//     `media_playback_store.dart` 的"只存身份不存凭据"同一约定）；
//   * 解析失败不抛：LRC 看不懂就退化成"纯文本歌词"（只显示、不逐行高亮）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/i18n/data_text.dart';

/// 缓存文件名用的稳定散列（FNV-1a 32 位）。
///
/// 与 `audio_handler.dart` 的封面指纹、`audio_visualizer.dart` 的身份色同款：
/// 只需要"同一个 key → 同一个文件名"，不做安全用途，所以**不引入 `crypto`**。
String lyricsCacheFileStem(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

// ─────────────────────────────────────────────────────────────── LRC 解析

/// 一行**带时间戳**的歌词。
@immutable
class LyricLine {
  const LyricLine({required this.time, required this.text});

  /// 该行开始的时间点（已应用 LRC 的 `[offset:]`）
  final Duration time;

  final String text;

  @override
  bool operator ==(Object other) =>
      other is LyricLine && other.time == time && other.text == text;

  @override
  int get hashCode => Object.hash(time, text);

  @override
  String toString() => 'LyricLine(${time.inMilliseconds}ms, $text)';
}

/// 解析结果。
@immutable
class LrcDocument {
  const LrcDocument({required this.lines, required this.plainText});

  const LrcDocument.empty() : lines = const [], plainText = '';

  /// 按时间升序的逐行歌词（空 = 没有时间轴信息）
  final List<LyricLine> lines;

  /// 纯文本歌词（无时间戳时用它；有时间戳时保留原文以便"照实显示"）
  final String plainText;

  /// 能不能逐行滚动/高亮（false 时只静态显示纯文本）
  bool get timed => lines.isNotEmpty;

  bool get isEmpty => lines.isEmpty && plainText.trim().isEmpty;

  /// 时间轴上最后一行的时间（用来判断"滚动到末尾"）
  Duration get lastTime => lines.isEmpty ? Duration.zero : lines.last.time;
}

/// `[mm:ss.xx]` / `[mm:ss]` / `[mm:ss.xxx]`（毫秒位 1–3 位都接受）。
final RegExp _kTimeTag = RegExp(r'\[(\d{1,4}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

/// `[ti:…] [ar:…] [al:…] [by:…] [offset:…] [length:…]` 之类的元数据标签。
final RegExp _kMetaTag = RegExp(
  r'\[(ti|ar|al|by|offset|re|ve|length):([^\]]*)\]',
  caseSensitive: false,
);

/// 解析 LRC（或退化成纯文本）。
///
/// 支持（都有真实数据来源：①②的实测响应里同时存在这几种形态）：
///   * **一行多个时间标签**：`[00:12.00][01:20.00]同一句` → 两行；
///   * 毫秒位 1/2/3 位（`[00:01.5]` / `[00:01.50]` / `[00:01.500]`）；
///   * `[offset:-500]`：整体平移（正数 = 提前，与 LRC 惯例一致，
///     **只在标签出现在文件里时应用**）；
///   * 元数据标签（`ti/ar/al/by/...`）**不算歌词行**；
///   * 完全没有时间戳的文本 → 进 [LrcDocument.plainText]（**照实显示**，
///     不做"假装能高亮"的事）；
///   * **带时间戳的空行保留**（LRC 里它是"间奏"标记；界面把它画成 `♪`，
///     不是删掉造成"歌词突然跳一段"）；
///   * 文件里时间顺序乱了（少见但存在）→ 统一按时间升序排好再返回。
LrcDocument parseLrc(String raw) {
  if (raw.trim().isEmpty) return const LrcDocument.empty();

  var offsetMs = 0;
  // 先扫一遍 offset（LRC 要求它在头部，但宽容一点、整篇扫也无害）
  for (final m in _kMetaTag.allMatches(raw)) {
    if (m.group(1)!.toLowerCase() == 'offset') {
      offsetMs = int.tryParse(m.group(2)!.trim()) ?? 0;
    }
  }

  final lines = <LyricLine>[];
  final plain = <String>[];
  for (final rawLine in raw.split(RegExp(r'\r?\n'))) {
    // 元数据标签先摘掉，剩下的才是歌词正文
    final line = rawLine.replaceAll(_kMetaTag, '');
    final tags = _kTimeTag.allMatches(line).toList();
    if (tags.isEmpty) {
      final text = line.trim();
      if (text.isNotEmpty) plain.add(text);
      continue;
    }
    // 正文 = 最后一个时间标签之后的内容（LRC 就是这么定义的）
    final text = line.substring(tags.last.end).trim();
    for (final tag in tags) {
      final minutes = int.parse(tag.group(1)!);
      final seconds = int.parse(tag.group(2)!);
      final fraction = tag.group(3);
      var ms = 0;
      if (fraction != null) {
        // `[00:01.5]` = 500ms；`[00:01.50]` = 500ms；`[00:01.500]` = 500ms
        ms = switch (fraction.length) {
          1 => int.parse(fraction) * 100,
          2 => int.parse(fraction) * 10,
          _ => int.parse(fraction),
        };
      }
      var at = Duration(minutes: minutes, seconds: seconds, milliseconds: ms);
      if (offsetMs != 0) {
        // LRC 惯例：offset 为正 = 歌词提前 → 时间点减小
        at = at - Duration(milliseconds: offsetMs);
        if (at < Duration.zero) at = Duration.zero;
      }
      lines.add(LyricLine(time: at, text: text));
    }
  }

  if (lines.isNotEmpty) {
    // 文件里时间乱序（少见但确实存在）⇒ 统一排一次（稳定排序，同时间保持原序）
    lines.sort((a, b) => a.time.compareTo(b.time));
    return LrcDocument(lines: List.unmodifiable(lines), plainText: raw.trim());
  }
  // 没有时间戳：纯文本（空行保留为段间分隔，读起来更像歌词）
  return LrcDocument(
    lines: const [],
    plainText: raw
        .split(RegExp(r'\r?\n'))
        .map((l) => l.replaceAll(_kMetaTag, '').trim())
        .join('\n')
        .trim(),
  );
}

/// 当前播放位置对应的**高亮行**下标；没有高亮（还没到第一行 / 没有时间轴）→ -1。
///
/// 用二分查找（歌词最多几百行，但这个方法每帧都被调用 ⇒ 不能是线性扫描）。
int activeLyricIndex(List<LyricLine> lines, Duration position) {
  if (lines.isEmpty) return -1;
  if (position < lines.first.time) return -1;
  var lo = 0;
  var hi = lines.length - 1;
  var best = 0;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].time <= position) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best;
}

// ─────────────────────────────────────────────────────────── 文件名 → 查询

/// 一次歌词查询的输入（**只用与歌有关的字段**，不含路径/凭据）。
@immutable
class LyricsQuery {
  const LyricsQuery({
    required this.title,
    this.artist = '',
    this.duration,
    this.identity = '',
  });

  /// 曲名（已从文件名里剥掉扩展名/音轨号）
  final String title;

  /// 歌手（文件名里 `歌手 - 曲名` 形态时才有；空 = 不知道）
  final String artist;

  /// 已知时长（用来把候选排到最前面；null = 未知）
  final Duration? duration;

  /// 本地身份（文件名/条目名）—— 只用于缓存 key，**不参与搜索**
  final String identity;

  /// 有没有可用于搜索的内容
  bool get isEmpty => title.trim().isEmpty;

  /// 缓存 key（稳定、可读、不含凭据）
  String get cacheKey => [
    title.trim().toLowerCase(),
    artist.trim().toLowerCase(),
    duration == null ? '' : '${duration!.inSeconds}',
    identity.trim().toLowerCase(),
  ].join('|');

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    'durationMs': duration?.inMilliseconds,
    'identity': identity,
  };

  @override
  String toString() => 'LyricsQuery($title / $artist / $duration)';
}

/// 从文件名推查询条件（纯函数）。
///
/// 处理三种真实命名（音乐库文件名的常见形态）：
///   * `01 - The Beatles - Hey Jude.mp3` → artist=The Beatles, title=Hey Jude
///   * `01. Hey Jude.mp3` / `07_Hey Jude.flac` / `[03] Hey Jude.m4a`
///     → title=Hey Jude（音轨号剥掉）
///   * `Hey Jude.mp3` → title=Hey Jude
///
/// ⚠️ 音轨号只在**有明确分隔符**时剥（`-` `.` `_` `)` 或 `[NN]`）。
/// 为什么不做"前导数字 + 空格"这种更宽的规则：那会把
/// `99 Red Balloons.mp3` 的曲名剥成 `Red Balloons` —— 宁可少剥，也不剥错。
///
/// 不做"把标题当歌手"之类的猜测：拿不准时 artist 留空（搜索更宽、候选更全）。
LyricsQuery lyricsQueryForFileName(
  String fileName, {
  Duration? duration,
  String identity = '',
}) {
  var stem = fileName.trim();
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  // 前导音轨号：`[03] ` / `01 - ` / `01. ` / `07_`
  stem = stem.replaceFirst(RegExp(r'^\s*(?:\[\d{1,3}\]|\d{1,3}\s*[-._)])\s*'), '');
  stem = stem.trim();
  // `歌手 - 曲名`：只在**恰好一段** ` - ` 且两侧都非空时拆（避免把
  // 带连字符的曲名拆坏，例如 "Love - Hate - Remix"）
  final parts = stem.split(' - ');
  if (parts.length == 2 &&
      parts[0].trim().isNotEmpty &&
      parts[1].trim().isNotEmpty &&
      parts[0].trim().length <= 60) {
    return LyricsQuery(
      title: parts[1].trim(),
      artist: parts[0].trim(),
      duration: duration,
      identity: identity.isEmpty ? fileName : identity,
    );
  }
  return LyricsQuery(
    title: stem,
    duration: duration,
    identity: identity.isEmpty ? fileName : identity,
  );
}

// ─────────────────────────────────────────────────────────────── 候选

/// 源站返回的一条歌词候选。
@immutable
class LyricCandidate {
  const LyricCandidate({
    required this.id,
    required this.trackName,
    this.artistName = '',
    this.albumName = '',
    this.duration,
    this.instrumental = false,
    this.syncedLyrics,
    this.plainLyrics,
  });

  final int id;
  final String trackName;
  final String artistName;
  final String albumName;
  final Duration? duration;
  final bool instrumental;
  final String? syncedLyrics;
  final String? plainLyrics;

  bool get hasLyrics =>
      (syncedLyrics?.trim().isNotEmpty ?? false) ||
      (plainLyrics?.trim().isNotEmpty ?? false);

  bool get hasSynced => syncedLyrics?.trim().isNotEmpty ?? false;

  /// 候选 → 可渲染文档（优先带时间轴的 `syncedLyrics`）。
  LrcDocument toDocument() {
    final synced = syncedLyrics;
    if (synced != null && synced.trim().isNotEmpty) {
      final doc = parseLrc(synced);
      if (!doc.isEmpty) return doc;
    }
    final plain = plainLyrics ?? '';
    if (plain.trim().isNotEmpty) return LrcDocument(lines: const [], plainText: plain.trim());
    return const LrcDocument.empty();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'trackName': trackName,
    'artistName': artistName,
    'albumName': albumName,
    'duration': duration?.inMilliseconds,
    'instrumental': instrumental,
    'syncedLyrics': syncedLyrics,
    'plainLyrics': plainLyrics,
  };

  /// 宽松解析：**绝不**裸 `as num?`/`as String`。
  ///
  /// 教训来源（AGENTS §2.2 第 257 轮）：Mock 里用整数喂的字段，真机是字符串
  /// ⇒ `type 'String' is not a subtype of type 'num'?` 整页失效。
  /// 而且实测 lrclib 的 `duration` 是 `211.109025` 这种非整数（见文件头 ④）。
  static LyricCandidate? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = _asInt(raw['id']);
    final track = _asString(raw['trackName']) ?? _asString(raw['name']);
    if (id == null || track == null || track.isEmpty) return null;
    final durationMs = _asDouble(raw['duration']);
    return LyricCandidate(
      id: id,
      trackName: track,
      artistName: _asString(raw['artistName']) ?? '',
      albumName: _asString(raw['albumName']) ?? '',
      duration: durationMs == null
          ? null
          : Duration(milliseconds: (durationMs * 1000).round()),
      instrumental: _asBool(raw['instrumental']),
      syncedLyrics: _asString(raw['syncedLyrics']),
      plainLyrics: _asString(raw['plainLyrics']),
    );
  }

  /// 一行候选在列表里显示的时长文本（未知 → `--:--`）。
  String durationLabel() {
    final d = duration;
    if (d == null) return '--:--';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

String? _asString(Object? v) => v is String ? v : (v == null ? null : '$v');

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

bool _asBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.toLowerCase() == 'true' || v == '1';
  return false;
}

/// 候选排序（纯函数）：**时长最接近 + 歌手对得上 + 有时间轴** 的排前面。
///
/// 为什么必须排序而不是"取第一条"：实测 ④ 里同一个歌名有 20 条候选，
/// 时长相差 25 秒、歌手各不相同（邓丽君 / 王小帅…）；直接取第一条
/// 很容易给用户一首**别的歌手**的歌词。
List<LyricCandidate> rankLyricCandidates(
  List<LyricCandidate> input, {
  Duration? duration,
  String? artist,
}) {
  double score(LyricCandidate c) {
    var s = 0.0;
    if (duration != null && c.duration != null) {
      final delta = (c.duration!.inMilliseconds - duration.inMilliseconds)
          .abs();
      if (delta <= 2000) {
        s += 100;
      } else if (delta <= 5000) {
        s += 60;
      } else if (delta <= 10000) {
        s += 25;
      } else if (delta <= 30000) {
        s += 5;
      } else {
        s -= 30;
      }
    }
    final a = artist?.trim().toLowerCase() ?? '';
    if (a.isNotEmpty) {
      final ca = c.artistName.toLowerCase();
      if (ca == a) {
        s += 40;
      } else if (ca.contains(a) || a.contains(ca)) {
        s += 20;
      }
    }
    if (c.hasSynced) s += 12;
    if (c.instrumental) s -= 60;
    return s;
  }

  final indexed = input.indexed.toList();
  indexed.sort((x, y) {
    final byScore = score(y.$2).compareTo(score(x.$2));
    return byScore != 0 ? byScore : x.$1.compareTo(y.$1); // 稳定
  });
  return [for (final e in indexed) e.$2];
}

/// 候选的**可用性判据**（DA53：歌词张冠李戴）：
///
/// 打分能"在几条候选里挑更好的"，但**挑不出"这几条全是别人的歌"** ——
/// 实测（2026-10-15）：`Demo Song`（Demo Artist，231 s）在 `q=Demo Song` 的 20 条里
/// **根本没有**，排序只能把 `On Demo Song`（Mia Love，223 s）顶上第一，
/// 界面就把它当本曲歌词显示（真机像素与源站回包逐字对上）。
/// ⇒ 显示之前必须过一道**名字门槛**（曲名 + 歌手）：
///
/// * 曲名对不上（两边都有名字且互不包含）⇒ **-1**；
/// * 歌手对不上（两边都有名字且互不包含）⇒ **-1**；
/// * 都对得上 ⇒ `2`；只有曲名对得上、源站没给歌手名 ⇒ `1`（判断不了，但不算"明确不是"）。
int lyricCandidateVerdict(
  LyricCandidate c, {
  required String title,
  required String artist,
}) {
  bool compatible(String q, String cand) {
    final a = q.trim().toLowerCase();
    final b = cand.trim().toLowerCase();
    if (a.isEmpty || b.isEmpty) return true; // 一边没有名字 ⇒ 判不了，不拦
    return a == b || a.contains(b) || b.contains(a);
  }

  if (!compatible(title, c.trackName)) return -1;
  if (!compatible(artist, c.artistName)) return -1;
  final t = title.trim().toLowerCase();
  final ct = c.trackName.trim().toLowerCase();
  final a = artist.trim().toLowerCase();
  final ca = c.artistName.trim().toLowerCase();
  if (a.isNotEmpty && ca.isNotEmpty && (ca == a || ca.contains(a) || a.contains(ca))) {
    return 2;
  }
  if (t.isNotEmpty && ct.isNotEmpty && (ct == t || ct.contains(t) || t.contains(ct))) {
    return 1;
  }
  return 1;
}

// ─────────────────────────────────────────────────────────────── HTTP

/// 一次 GET 的最小结果（只保留状态码与正文：这一层不做业务解释）。
@immutable
class LyricsHttpResponse {
  const LyricsHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// HTTP 出口（可注入：单测里换成假实现，**离线**且不碰网络）。
abstract interface class LyricsHttp {
  Future<LyricsHttpResponse> get(Uri uri);
}

/// 真实实现：`dart:io` 的 `HttpClient`。
///
/// 为什么不用 `dio`：项目里的 `DioFactory` 装的是**NAS 专用**信任链
/// （自签/主机名不匹配放行 + 首连指纹钉住）。lrclib.net 是公共 CA 签发的
/// 公网域名，**必须**走平台默认校验 —— 拿 NAS 的信任策略去请求它，
/// 等于把"放宽校验"用在了不该用的地方。
class IoLyricsHttp implements LyricsHttp {
  IoLyricsHttp({HttpClient? client, Duration? timeout})
    : _client = client,
      _timeout = timeout ?? const Duration(seconds: 12);

  final HttpClient? _client;
  final Duration _timeout;

  /// lrclib 建议带上能识别调用方的 UA（不做鉴权用）。
  static const String kUserAgent = 'synhub/1.0 (Android; lrclib client)';

  @override
  Future<LyricsHttpResponse> get(Uri uri) async {
    final client =
        _client ?? (HttpClient()..connectionTimeout = _timeout);
    try {
      final req = await client.getUrl(uri).timeout(_timeout);
      req.headers.set(HttpHeaders.userAgentHeader, kUserAgent);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(_timeout);
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      return LyricsHttpResponse(statusCode: res.statusCode, body: body);
    } finally {
      // 自己建的 client 用完就关；外部传进来的由调用方管（测试复用）
      if (_client == null) client.close(force: true);
    }
  }
}

// ─────────────────────────────────────────────────────────────── 失败态

/// 失败原因（**分开报**：离线 / 超时 / 没这首歌 / 服务端错 / 响应看不懂）。
enum LyricsFailureKind { offline, timeout, notFound, server, badResponse }

/// 可读的失败原因（界面直接显示这一句 + "重试"）。
String lyricsFailureText(LyricsFailureKind kind) => switch (kind) {
  LyricsFailureKind.offline => dataText(
    'audioLyricsOffline',
    '网络不可用，无法联网搜歌词',
  ),
  LyricsFailureKind.timeout => dataText('audioLyricsTimeout', '歌词服务响应超时'),
  LyricsFailureKind.notFound => dataText(
    'audioLyricsNotFound',
    '没有找到这首歌的歌词',
  ),
  LyricsFailureKind.server => dataText(
    'audioLyricsServer',
    '歌词服务返回错误，稍后可重试',
  ),
  LyricsFailureKind.badResponse => dataText(
    'audioLyricsBadResponse',
    '歌词返回的数据看不懂（歌词源可能改版了）',
  ),
};

/// 搜歌词的总失败（网络/协议层）——业务上的"没这首歌"由空列表表达。
class LyricsFetchException implements Exception {
  const LyricsFetchException(this.kind, [this.detail]);

  final LyricsFailureKind kind;
  final String? detail;

  @override
  String toString() => 'LyricsFetchException($kind, $detail)';
}

// ─────────────────────────────────────────────────────────────── 歌词源

/// 歌词源抽象（单测注入假源；生产 = [LrclibLyricsSource]）。
abstract interface class LyricsSource {
  /// 按标题（可带歌手）搜候选；无结果返回空列表（**不是**失败）。
  Future<List<LyricCandidate>> search(LyricsQuery query);

  /// 按源站 id 取一条（用户从候选里选定时用）。
  Future<LyricCandidate?> fetchById(int id);
}

/// lrclib.net 实现（免密钥）。
///
/// 端点与参数**逐字**来自文件头的实测 curl：
///   * `GET https://lrclib.net/api/search?q=<...>` → `[candidate, ...]`
///   * `GET https://lrclib.net/api/get/<id>` → `candidate`
class LrclibLyricsSource implements LyricsSource {
  LrclibLyricsSource({required LyricsHttp http}) : _http = http;

  final LyricsHttp _http;

  static const String host = 'lrclib.net';

  /// 搜索 URL（导出来给单测断言参数编码正确）。
  static Uri searchUri(String q) =>
      Uri.https(host, '/api/search', {'q': q});

  /// ★ DA53：**带歌手**的结构化搜索 URL（`track_name` + `artist_name`）。
  ///
  /// 文件头 ①/④ 的实测 curl 里本来就有这两个参数，只是一直没用。
  /// 实测对比（2026-10-15，同一时间同一台机）：
  ///   * `q=Demo Song`               → 20 条，**没有一条是 Demo Artist**；
  ///   * `track_name=Demo Song&artist_name=Demo Artist` → 20 条，**全是 Demo Artist**
  ///     （230/231/232 s，`syncedLyrics` 是整首歌词）。
  static Uri searchTrackUri(String title, String artist) => Uri.https(host, '/api/search', {
    'track_name': title,
    'artist_name': artist,
  });

  /// 按 id 取歌词的 URL。
  static Uri getUri(int id) => Uri.https(host, '/api/get/$id');

  @override
  Future<List<LyricCandidate>> search(LyricsQuery query) async {
    final title = query.title.trim();
    if (title.isEmpty) return const [];
    final artist = query.artist.trim();
    // ★ DA53：有歌手就**先按结构化字段搜**（`track_name` + `artist_name`）。
    // 以前一律按标题搜 ⇒ 《Demo Song》拿到的 20 条里没有 Demo Artist，
    // 排序只能把别人的《On Demo Song》当本曲歌词显示。
    var out = await _searchRawUri(
      artist.isEmpty ? searchUri(title) : searchTrackUri(title, artist),
    );
    // 结构化搜不到 → 退回"歌手 标题"纯文本搜（只多一次请求，且只在**确实没结果**时发生）
    if (out.isEmpty) {
      out = await _searchRaw(
        artist.isEmpty ? title : '$artist $title',
      );
    }
    return out;
  }

  Future<List<LyricCandidate>> _searchRaw(String q) =>
      _searchRawUri(searchUri(q));

  Future<List<LyricCandidate>> _searchRawUri(Uri uri) async {
    final res = await _guard(() => _http.get(uri));
    if (res.statusCode == 404) return const [];
    if (!res.ok) throw LyricsFetchException(LyricsFailureKind.server);
    final decoded = _decodeJson(res.body);
    if (decoded is! List) {
      throw const LyricsFetchException(LyricsFailureKind.badResponse);
    }
    final out = <LyricCandidate>[];
    for (final item in decoded) {
      final c = LyricCandidate.fromJson(item);
      if (c != null) out.add(c);
    }
    return out;
  }

  @override
  Future<LyricCandidate?> fetchById(int id) async {
    final res = await _guard(() => _http.get(getUri(id)));
    // 实测：找不到时 404 + `{"message":"Failed to find specified track",
    // "name":"TrackNotFound","statusCode":404}` ⇒ 明确的"没这首歌"
    if (res.statusCode == 404) return null;
    if (!res.ok) throw LyricsFetchException(LyricsFailureKind.server);
    final decoded = _decodeJson(res.body);
    final c = LyricCandidate.fromJson(decoded);
    if (c == null) {
      throw const LyricsFetchException(LyricsFailureKind.badResponse);
    }
    return c;
  }

  Object? _decodeJson(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      throw const LyricsFetchException(LyricsFailureKind.badResponse);
    }
  }

  /// 把底层 IO 异常翻译成五类失败态之一（**不吞掉原因**）。
  Future<LyricsHttpResponse> _guard(
    Future<LyricsHttpResponse> Function() run,
  ) async {
    try {
      return await run();
    } on LyricsFetchException {
      rethrow;
    } on TimeoutException {
      throw const LyricsFetchException(LyricsFailureKind.timeout);
    } on SocketException catch (e) {
      throw LyricsFetchException(LyricsFailureKind.offline, e.message);
    } on HttpException catch (e) {
      throw LyricsFetchException(LyricsFailureKind.server, e.message);
    } catch (e) {
      // 未知异常也如实归类，不假装成功
      throw LyricsFetchException(LyricsFailureKind.badResponse, '$e');
    }
  }
}

// ─────────────────────────────────────────────────────────────── 缓存

/// 歌词缓存（key → 源站候选 JSON 串）。
abstract interface class LyricsCache {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> remove(String key);
}

/// 纯内存实现（单测 / 拿不到目录时兜底）。
class InMemoryLyricsCache implements LyricsCache {
  InMemoryLyricsCache([Map<String, String>? seed]) : _map = {...?seed};

  final Map<String, String> _map;

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async => _map[key] = value;

  @override
  Future<void> remove(String key) async => _map.remove(key);
}

/// 应用文档目录下的 JSON 实现：`audio_lyrics/<hash>.json`。
///
/// 读/写失败一律**不抛**（缓存是增强，绝不是"播不了"的原因）；
/// 目录拿不到（纯单测）→ 退回内存（进程内仍然记得）。
class FileLyricsCache implements LyricsCache {
  FileLyricsCache({Future<Directory?> Function()? dirResolver})
    : _dirResolver = dirResolver ?? _defaultDir;

  final Future<Directory?> Function() _dirResolver;
  final InMemoryLyricsCache _memory = InMemoryLyricsCache();
  Directory? _dir;
  bool _failed = false;

  static const String dirName = 'audio_lyrics';

  static Future<Directory?> _defaultDir() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      return Directory('${base.path}/$dirName');
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> _resolve() async {
    if (_dir != null) return _dir;
    if (_failed) return null;
    final d = await _dirResolver();
    if (d == null) {
      _failed = true;
      return null;
    }
    try {
      await d.create(recursive: true);
    } catch (_) {
      _failed = true;
      return null;
    }
    _dir = d;
    return d;
  }

  /// key → 文件名（FNV-1a，不含凭据、路径安全）。
  static String fileNameFor(String key) => 'lyrics-${lyricsCacheFileStem(key)}.json';

  @override
  Future<String?> read(String key) async {
    final dir = await _resolve();
    if (dir == null) return await _memory.read(key);
    try {
      final f = File('${dir.path}/${fileNameFor(key)}');
      if (!await f.exists()) return await _memory.read(key);
      return await f.readAsString();
    } catch (_) {
      return await _memory.read(key);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    await _memory.write(key, value);
    final dir = await _resolve();
    if (dir == null) return;
    try {
      await File(
        '${dir.path}/${fileNameFor(key)}',
      ).writeAsString(value, flush: true);
    } catch (_) {
      // 写不进去也不影响本次显示
    }
  }

  @override
  Future<void> remove(String key) async {
    await _memory.remove(key);
    final dir = await _resolve();
    if (dir == null) return;
    try {
      final f = File('${dir.path}/${fileNameFor(key)}');
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 忽略
    }
  }
}

// ─────────────────────────────────────────────────────────────── 编排

/// 一次"取歌词"的结果（界面只读它）。
@immutable
class LyricsLoadResult {
  const LyricsLoadResult({
    this.document,
    this.chosen,
    this.candidates = const [],
    this.failure,
    this.fromCache = false,
  });

  const LyricsLoadResult.empty() : this();

  /// 解析好的歌词（null = 还没有/失败了）
  final LrcDocument? document;

  /// 当前选中的候选（null = 自动挑选也没有结果）
  final LyricCandidate? chosen;

  /// 本次搜索的候选列表（用户在"换一个"里选）
  final List<LyricCandidate> candidates;

  /// 失败原因（null = 没失败；注意"没找到"是 [LyricsFailureKind.notFound]）
  final LyricsFailureKind? failure;

  /// 是不是直接命中了本地缓存（界面可以标注"离线缓存"）
  final bool fromCache;

  bool get hasLyrics => document != null && !document!.isEmpty;

  /// 能不能给"换一个候选"的入口
  bool get hasCandidates => candidates.length > 1;

  /// ★ DA68（r411）：**只换候选、保留屏上那一份**。
  ///
  /// 用在"用户明确点了重搜，但新搜到的候选一条都没有正文"时：
  /// 屏上原有歌词**不许弄丢**，可新候选要留下来（否则"换一个歌词版本"
  /// 这个刚补的入口又会消失）。
  LyricsLoadResult withCandidates(List<LyricCandidate> next) => LyricsLoadResult(
    document: document,
    chosen: chosen,
    candidates: next,
    failure: failure,
    fromCache: fromCache,
  );
}

/// **编排**：缓存 → 搜索 → 排序选最优 → 写缓存。
///
/// 独立成类的理由：它是这条链路上唯一有分支的逻辑，把它从界面里拿出来，
/// 就能用**假源 + 内存缓存**在离线单测里把每条分支都钉住（见
/// `test/audio_lyrics_test.dart`），不必起平台通道、不必联网。
class LyricsLookup {
  LyricsLookup({
    required LyricsSource source,
    LyricsCache? cache,
    this.retryDelay = const Duration(milliseconds: 700),
  }) : _source = source,
       _cache = cache ?? InMemoryLyricsCache();

  final LyricsSource _source;
  final LyricsCache _cache;

  /// 源站过载（5xx）时的自动重试等待（见 [_retryWhenServerOverloaded]）。
  /// 单测里传 `Duration.zero` 关掉它，免得白等。
  final Duration retryDelay;

  /// 缓存的落盘格式版本（换格式时旧缓存自然失效）。
  /// ★ DA53 起 = **2**：1 号缓存里可能存着"按标题搜到的别人的歌词"
  /// （例如 `Demo Song` 存成了 Mia Love 的《On Demo Song》），
  /// 光靠 `cacheKey` 分不出来 ⇒ 只能整代作废。
  static const int cacheSchemaVersion = 2;

  /// 只读本地缓存（打开页面时先走这条：**默认不联网**）。
  Future<LyricsLoadResult> fromCache(LyricsQuery query) async {
    final raw = await _cache.read(query.cacheKey);
    if (raw == null || raw.isEmpty) return const LyricsLoadResult.empty();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const LyricsLoadResult.empty();
      // ★ DA53：以前这里**只看 `chosen` 不看版本号** —— 注释说"换格式时旧缓存
      // 自然失效"，其实没有任何代码执行这件事（旧缓存会一直被用）。
      // 现在真检查：版本对不上就当作没有缓存（走联网重搜）。
      if (decoded['version'] != cacheSchemaVersion) {
        return const LyricsLoadResult.empty();
      }
      final candidate = LyricCandidate.fromJson(decoded['chosen']);
      if (candidate == null) return const LyricsLoadResult.empty();
      final doc = candidate.toDocument();
      if (doc.isEmpty) return const LyricsLoadResult.empty();
      return LyricsLoadResult(document: doc, chosen: candidate, fromCache: true);
    } catch (_) {
      // 坏缓存当没有
      return const LyricsLoadResult.empty();
    }
  }

  /// 联网搜索 + 自动挑最优 + 写缓存。
  ///
  /// 搜到候选但一个都没有歌词正文 → 如实回 [LyricsFailureKind.notFound]。
  Future<LyricsLoadResult> search(LyricsQuery query) async {
    if (query.isEmpty) return const LyricsLoadResult.empty();
    final List<LyricCandidate> raw;
    try {
      raw = await _retryWhenServerOverloaded(() => _source.search(query));
    } on LyricsFetchException catch (e) {
      return LyricsLoadResult(failure: e.kind);
    }
    if (raw.isEmpty) {
      return const LyricsLoadResult(failure: LyricsFailureKind.notFound);
    }
    final ranked = rankLyricCandidates(
      raw,
      duration: query.duration,
      artist: query.artist,
    );
    // ★ DA53：排序只能"在候选里挑更好的"，**挑不出"这些全是别人的歌"**。
    // 所以显示之前先过歌手门槛：明确不是同一个人的一律不用
    // （候选仍原样带出去，留给"换一个"入口）。
    final usable = [
      for (final c in ranked)
        if (lyricCandidateVerdict(
              c,
              title: query.title,
              artist: query.artist,
            ) >=
            0)
          c,
    ];
    LyricCandidate? best;
    for (final c in usable) {
      if (c.hasLyrics) {
        best = c;
        break;
      }
    }
    best ??= usable.isEmpty ? null : usable.first;
    if (best == null || !best.hasLyrics) {
      // 两种情况都归"没有这首歌的歌词"（而**不是**网络失败）：
      // ① 搜到了条目，但源站没给任何歌词正文；
      // ② 搜到的条目**明确不是同一个人**（宁可不显示，也不显示别人的歌词）。
      return LyricsLoadResult(
        candidates: ranked,
        failure: LyricsFailureKind.notFound,
      );
    }
    // 候选自带正文时**不再**打第二次请求（实测 ①：search 就带 lyrics）
    final doc = best.toDocument();
    await _writeCache(query, best);
    return LyricsLoadResult(
      document: doc,
      chosen: best,
      candidates: ranked,
    );
  }

  /// 用户从候选里**明确选一个**（或重试某一条）：必要时按 id 拉正文。
  Future<LyricsLoadResult> choose(
    LyricsQuery query,
    LyricCandidate candidate, {
    List<LyricCandidate> candidates = const [],
  }) async {
    var pick = candidate;
    if (!pick.hasLyrics) {
      try {
        final fetched = await _retryWhenServerOverloaded(
          () => _source.fetchById(candidate.id),
        );
        if (fetched != null) pick = fetched;
      } on LyricsFetchException catch (e) {
        return LyricsLoadResult(candidates: candidates, failure: e.kind);
      }
    }
    final doc = pick.toDocument();
    if (doc.isEmpty) {
      return LyricsLoadResult(
        candidates: candidates,
        chosen: pick,
        failure: LyricsFailureKind.notFound,
      );
    }
    await _writeCache(query, pick);
    return LyricsLoadResult(
      document: doc,
      chosen: pick,
      candidates: candidates,
    );
  }

  /// 源站**过载**（5xx）自动重试一次。
  ///
  /// 实测依据（第 260 轮复验，逐字见文件头 ③'）：
  /// `.../api/search?q=Hey+Jude` 第一次回
  /// `503 {"name":"ServerOverloaded","message":"The server is busy, please retry in a moment"}`，
  /// **6 秒后重试即 200**（20 条候选）⇒ 这类 5xx 是**暂时**的，自动再试一次
  /// 对用户是有意义的。
  ///
  /// ⚠️ 只重试 `server`（5xx/非 JSON 之外的服务端错）：**断网 / 超时 / 404 不重试**
  /// —— 那些重试也一样，只会让用户多等。重试仍失败就**原样抛出**，
  /// 交给界面显示"歌词服务返回错误，稍后可重试"。
  Future<T> _retryWhenServerOverloaded<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on LyricsFetchException catch (e) {
      if (e.kind != LyricsFailureKind.server || retryDelay <= Duration.zero) {
        rethrow;
      }
      await Future<void>.delayed(retryDelay);
      return await run();
    }
  }

  Future<void> _writeCache(LyricsQuery query, LyricCandidate chosen) async {
    try {
      // ★ DA54：`LyricCandidate.toJson` 写的是**毫秒**，而 `fromJson` 按
      // **秒**读（×1000 ⇒ 毫秒）—— 那是 lrclib 响应的口径（`"duration": 211.109`）。
      // 直接原样写进缓存，读回来时长就被放大 1000 倍（231 s → 64 小时）。
      // 这里统一按"源站口径"（秒）落盘，round-trip 才是恒等的。
      final chosenJson = chosen.toJson();
      chosenJson['duration'] = chosen.duration == null
          ? null
          : chosen.duration!.inMilliseconds / 1000.0;
      await _cache.write(
        query.cacheKey,
        jsonEncode({
          'version': cacheSchemaVersion,
          'query': query.toJson(),
          'chosen': chosenJson,
        }),
      );
    } catch (_) {
      // 缓存写失败不影响本次显示
    }
  }

  /// 清掉某首歌的缓存（用户在"换一个"里选了别的之后需要覆盖 → 走 write）。
  Future<void> clear(LyricsQuery query) => _cache.remove(query.cacheKey);
}

// ─────────────────────────────────────────────────────────────── providers

/// HTTP 出口（测试覆盖成假实现 → 完全不碰网络）。
final mediaLyricsHttpProvider = Provider<LyricsHttp>((ref) => IoLyricsHttp());

/// 缓存（测试覆盖成内存实现）。
final mediaLyricsCacheProvider = Provider<LyricsCache>(
  (ref) => FileLyricsCache(),
);

/// 歌词源（默认 lrclib）。
final mediaLyricsSourceProvider = Provider<LyricsSource>(
  (ref) => LrclibLyricsSource(http: ref.watch(mediaLyricsHttpProvider)),
);

/// 编排器（界面唯一入口）。
final mediaLyricsLookupProvider = Provider<LyricsLookup>(
  (ref) => LyricsLookup(
    source: ref.watch(mediaLyricsSourceProvider),
    cache: ref.watch(mediaLyricsCacheProvider),
  ),
);

/// 界面文案（用 dataText：不新增 ARB key，未翻译语言回落中文）。
String audioLyricsSearchHintText() =>
    dataText('audioLyricsSearchHint', '搜歌词');

String audioLyricsPickText() => dataText('audioLyricsPick', '换一个歌词版本');

String audioLyricsRetryText() => dataText('audioLyricsRetry', '重试');

// ★ r411（DA66）：「已用本地缓存」这句话现在由**署名行**
// （`audioLyricsAttributionText`）统一带出去，原来那个独立小标
// `audioLyricsCachedText()` 已无调用点 ⇒ 删掉，不留死代码。

String audioLyricsPlainTextHintText() =>
    dataText('audioLyricsPlain', '这份歌词不会自动滚动（只显示，可手动滑）');

/// ★ r644（**DA239**）：「回到正在唱的那句」那颗按钮上的字。
///
/// 为什么要它：手动把歌词滑走之后，自动跟随要等 `kLyricAutoScrollResumeDelay`
/// 才回来（让位是对的，但"我现在就想回去"没有落点）。Plexamp 这类播放器
/// 在滑走后都会留一个"回到当前句"的落点。
String audioLyricsJumpToActiveText() =>
    dataText('audioLyricsJumpToActive', '回到正在唱的那句');

/// ★ DA66（r411）：**歌词署名** —— 屏上这一份到底是谁的、从哪个源来的。
///
/// 为什么需要它（r403 记下的诚实缺口原文）：
/// > 「屏上**没有任何地方**写"这是哪一条候选 / 来自哪个源"。
/// >  用户会以为这就是 Demo Artist《Demo Song》的歌词。」
///
/// 事实只有两个来源，**都必须照实写**：
///   * 有 [chosen] ⇒ 这份来自**公开源**（`lrclib.net`），并配上它自己的
///     曲名 / 歌手 / 专辑（源站给什么写什么，**不美化**）；
///   * 没有 [chosen] ⇒ 这份来自 **NAS 歌词库**（Audio Station `Lyrics.getlyrics`）。
///
/// 另外两个布尔都是**已经知道的事实**，不许省：
///   * [timed] = false ⇒ 明说「无时间轴」（用户才知道为什么不高亮）；
///   * [fromCache] = true ⇒ 明说「已用本地缓存」（用户才知道为什么没联网）。
///
/// **不写正文里没有的东西**：源站不给年份/长度就不写，不编。
/// 这一段里**有没有真正的字**（字母/数字）。只由标点、空白组成的段不算信息。
///
/// `\p{L}`/`\p{N}` 要 `unicode: true` 才生效（Dart 的 RegExp 支持 Unicode 属性转义）。
bool _hasWordChar(String s) =>
    s.trim().isNotEmpty && RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(s);

String audioLyricsAttributionText({
  LyricCandidate? chosen,
  required bool fromCache,
  required bool timed,
}) {
  final parts = <String>[];
  final c = chosen;
  if (c == null) {
    parts.add(dataText('audioLyricsSourceNas', 'NAS 歌词库'));
  } else {
    parts.add(dataText('audioLyricsSourcePublic', 'lrclib.net 公开歌词库'));
    // ★ r631 备注：曾想把 曲名/艺人/专辑 从这行去掉（用户嫌技术参数占界面），
    //   但 **DA66 的验收判据就是"署名里必须能看出是谁唱的"**（用例
    //   `media_audio_lyrics_ui_test.dart` 逐字断言）。为不破坏已闭合的缺陷判据，
    //   保留这三段；拥挤问题改由 `LyricsAttributionLine` 的**字号与行数**解决。
    if (c.trackName.trim().isNotEmpty) parts.add(c.trackName.trim());
    if (c.artistName.trim().isNotEmpty) parts.add(c.artistName.trim());
    // ★ r644（**DA242**，真机 2026-10-23）：源站把专辑名给成一个孤零零的符号
    //   （lrclib 对 `Favorite Girl` 给的是 `albumName: "•"`）⇒ 屏上念成
    //   `… · Justin Bieber · • · 已用本地缓存`，中间那颗点既不是名字也不是分隔符，
    //   人只会读到"这里坏了"。**只有标点/空白的段一律不进署名**（已有分隔符负责断句）。
    if (_hasWordChar(c.albumName)) parts.add(c.albumName.trim());
  }
  // 「无时间轴」与来源无关：**哪个源都可能给纯文本**（NAS 歌词库里
  // 59/60 首里也有纯文本的），所以它必须写在来源分支**外面**。
  if (!timed) parts.add(dataText('audioLyricsNoTimeline', '不会自动滚动'));
  if (fromCache) parts.add(dataText('audioLyricsCached', '已用本地缓存'));
  // ★ 分隔符与"歌词来源"这四个字**都在 ARB 里**（模板 `{x}`）——
  // 上一版把全角冒号硬编码在这行 ⇒ 英文界面会印出 `Lyrics source：…`
  // （DA38 的同族：全角「：」当字段分隔符）。硬编码中文标点还会被
  // `test/i18n_hardcoded_cjk_test.dart` 第六条当轮抓红（已实测）。
  return dataText(
    'audioLyricsSourceLine',
    '歌词来源：{x}',
  ).replaceAll('{x}', parts.join(' · '));
}
