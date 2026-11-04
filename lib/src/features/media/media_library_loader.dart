// 播放列表 + 外挂字幕的**目录加载器**（纯逻辑层：不 import flutter / l10n）。
//
// 一次 `FileStation.List.list` 同时喂两件事：
//   1. 「上一个 / 下一个」的播放列表（同目录 + 同类型 + 自然序，见
//      `media_playlist.dart`）；
//   2. 外挂字幕候选（同名字幕排序，见 `media_subtitles.dart`）。
//
// 为什么只列一次：两者需要的都是"当前文件所在目录的条目"，列两次等于把 NAS 的
// 延迟翻倍；而且列表和字幕必须来自**同一份快照**，否则用户会看到"上一个/下一个
// 和字幕对不上"。
//
// 字幕正文按需取头部（`getBytes(maxBytes:)` → `Range: bytes=0-N`，真机实测
// FileStation `Download` 支持 206），再用 `book_encoding` 的编码探测解码
// （中文字幕大量是 GBK/GB18030，直接按 UTF-8 解会全是乱码）。
library;

import 'dart:convert';

import '../../data/dto/file_entry_dto.dart';
import '../../data/filestation_api.dart';
import '../../dsm/webapi.dart';
import '../files/book_encoding.dart';
import 'media_playlist.dart';
import 'media_source.dart';
import 'media_subtitles.dart';

/// 字幕只取头部这么多字节（一条 `.srt`/`.ass` 极少超过 256KB；
/// 超出部分宁可缺几句也不要为了字幕把整份文件拉下来）。
const int kSubtitleHeadBytes = 256 * 1024;

/// 一个目录能给播放器提供的东西
class MediaDirectoryContext {
  const MediaDirectoryContext({
    required this.playlist,
    required this.index,
    this.paths = const [],
    this.entries = const [],
    this.subtitleMatches = const [],
    this.subtitleEntries = const {},
  });

  /// 同目录同类型的可播列表（自然序；至少含当前文件）
  final List<MediaSource> playlist;

  /// 当前文件在 [playlist] 里的下标
  final int index;

  /// 与 [playlist] **一一对应**的目录条目（r651 / `DA251`）。
  ///
  /// 音频舞台要拿它算"这一条的封面 / 歌词身份（path）"——只给 `MediaSource`
  /// 的话，换歌之后封面与歌词会挂在上一首上。空表示"身份不可得"。
  final List<FileEntryDto> entries;

  /// 与 [playlist] **一一对应**的 FileStation 路径（可为空 = 身份不可得）。
  ///
  /// 播放队列的持久化（`media_playback_store.dart`）只存路径不存 URL：
  /// 空表示"这条来源没有稳定身份"（相册/Drive），那就**不持久化**，
  /// 而不是把带 `_sid` 的直链写进磁盘。
  final List<String> paths;

  /// 同名字幕候选（匹配度从高到低）
  final List<SubtitleMatch> subtitleMatches;

  /// 字幕文件名 → 目录条目（取正文时要用它的 path 拼直链）
  final Map<String, FileEntryDto> subtitleEntries;

  bool get hasPlaylist => playlist.length > 1;

  bool get hasSubtitles => subtitleMatches.isNotEmpty;

  /// **自动**挂载的最低匹配分（[kSubtitleAutoMatchMinScore]）。
  ///
  /// 不设这条线的话，目录里任何一条 `.srt` 都会被自动挂到不相关的视频上
  /// （`rankSubtitleFiles` 把无关候选也列出来是为了**手动**可选）。
  SubtitleMatch? get autoMatch {
    if (subtitleMatches.isEmpty) return null;
    final top = subtitleMatches.first;
    return top.score >= kSubtitleAutoMatchMinScore ? top : null;
  }
}

/// 自动挂载的最低分：够得上"同名/同名前缀"档（无关文件大约 3 分，见
/// `rankSubtitleFiles` 的打分表）。
const int kSubtitleAutoMatchMinScore = 30;

/// 列当前文件所在目录 → 播放列表 + 字幕候选。
///
/// 任何一种失败（没连上 / 权限不够 / 目录太大 / 网络抖动）都返回 **null**：
/// 播放列表和外挂字幕是**增强**，不能因为它们把"本来能播的视频"变成失败页。
/// 调用方（`MediaPlayerView`）拿到 null 就退回单文件播放。
///
/// [sourceOf] 由界面层给：它知道 certPinned / 隧道这些规则（`resolveFileStationSource`），
/// 这里只负责"列出条目、排好序"，不重复实现鉴权判断。
Future<MediaDirectoryContext?> loadMediaDirectoryContext({
  required FileStationApi? fs,
  required FileEntryDto entry,
  required MediaKind kind,
  required MediaSource Function(FileEntryDto) sourceOf,
  int limit = 2000,
}) async {
  if (fs == null) return null;
  if (entry.path.isEmpty || entry.path.startsWith(kDrivePathPrefix)) {
    return null;
  }
  try {
    final parent = parentPathOf(entry.path);
    final result = await fs.listFolder(folderPath: parent, limit: limit);
    final entries = result.entries;
    final ordered = ensureInPlaylist(
      buildMediaPlaylist(entries: entries, kind: kind),
      entry,
    );
    final playlist = <MediaSource>[];
    final paths = <String>[];
    final picked = <FileEntryDto>[];
    for (final e in ordered) {
      if (paths.contains(e.path)) continue;
      paths.add(e.path);
      playlist.add(sourceOf(e));
      picked.add(e);
    }
    final index = paths.indexOf(entry.path);
    final byName = <String, FileEntryDto>{};
    for (final e in entries) {
      if (e.isDir) continue;
      if (!isSubtitleFileName(e.name)) continue;
      byName.putIfAbsent(e.name, () => e);
    }
    final matches = rankSubtitleFiles(
      videoFileName: entry.name,
      fileNames: byName.keys,
    );
    return MediaDirectoryContext(
      playlist: playlist,
      index: index < 0 ? 0 : index,
      paths: paths,
      entries: picked,
      subtitleMatches: matches,
      subtitleEntries: byName,
    );
  } catch (_) {
    return null;
  }
}

/// 字幕候选条目 → 可播来源（外挂字幕也走 FileStation `Download` 直链）
MediaSource? subtitleSource({
  required FileEntryDto entry,
  required MediaSource Function(FileEntryDto) sourceOf,
}) => entry.isDir ? null : sourceOf(entry);

/// 取一条外挂字幕的**头部字节 → 探测编码 → 解析**。
///
/// 失败返回 null（例如权限被拒 / 文件其实不是字幕 / 坏编码）：
/// 界面上的表现就是"这条字幕选不了"，而不是整个播放器报错。
Future<SubtitleTrack?> fetchSubtitleTrack({
  required DsmWebApi? api,
  required MediaSource source,
  required SubtitleMatch match,
  int maxBytes = kSubtitleHeadBytes,
}) async {
  if (api == null || source.uri.isEmpty) return null;
  try {
    final bytes = await api.getBytes(source.uri, maxBytes: maxBytes);
    if (bytes.isEmpty) return null;
    final text = decodeBookText(bytes);
    final cues = SubtitleParser.parse(text, match.format);
    if (cues.isEmpty) return null;
    return SubtitleTrack(
      fileName: match.name,
      format: match.format,
      cues: cues,
    );
  } catch (_) {
    return null;
  }
}

/// 只用来做"这条 `.srt` 看起来像不像字幕"的粗检（探针 / 测试用）
bool looksLikeSubtitleText(String text) {
  if (text.trim().isEmpty) return false;
  return text.contains('-->') || text.contains('[Events]');
}

/// UTF-8 兜底解码（`decodeBookText` 认不出的极少数情况下用）
String decodeUtf8Lenient(List<int> bytes) =>
    const Utf8Decoder(allowMalformed: true).convert(bytes);
