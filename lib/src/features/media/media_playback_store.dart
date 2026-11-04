// 播放偏好与播放队列的**持久化**（W1-2）。
//
// 这一层解决三件事，全部是"进程重启后还在"：
//   1. **播放速度**（全局一份 —— 用户挑倍速是习惯，不是每条视频各不相同）；
//   2. **字幕选择**（按媒体身份一份；外挂字幕记文件名、内封字幕记轨道 id，
//      重启后找不到就**如实降级**回自动/关闭，不假装选中）；
//   3. **播放队列**（按目录一份 —— 顺序 + 当前条目；重启后重新打开同一队列里的
//      文件时，队列顺序与"上次播到的那一条"都回来）。
//
// ⚠️ **只存身份，不存凭据**：队列条目存的是 `path/name`，**绝不**存带
// `_sid`/`SynoToken` 的直链（与 `media_source.dart` 的既有约定一致 —— 凭据只在
// 内存里的 URL 查询串上，URL 一变就被新会话覆盖）。
//
// 纯逻辑（[reconcileMediaQueue] / [normalizeMediaPlaybackSpeed]）不 import
// flutter，能被离线单测直接跑；IO 部分（[AppMediaPlaybackStore]）走
// `path_provider` 的应用文档目录，解析不出来时**退回内存**（测试/无平台通道），
// 绝不因为"存偏好失败"影响播放。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// 倍速档位（界面与持久化共用一份；`media_player_view.dart` 的
/// `kMediaSpeeds` 就是它，避免两处各写一遍导致持久化值不在菜单里）。
const List<double> kMediaPlaybackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// 字幕垂直偏移档位（逻辑像素，正值向上）—— r655 `DA263` 起界面在用，
/// r656 `DA270` 起**持久化的吸附目标也是它**（两处共用一份，避免各写一遍）。
const List<double> kMediaSubtitleOffsetSteps = <double>[0, 40, 80, 120];

/// 别名：界面侧历史上就叫这个名字（r655 起）。
const List<double> kMediaSubtitleOffsets = kMediaSubtitleOffsetSteps;

/// 把任意读到的倍速**吸附到最近的合法档位**；非法/越界 → 1.0（原速）。
///
/// 为什么要吸附：偏好文件可能被旧版本/手改过（0.9、3.0、NaN…）。直接拿去
/// `setSpeed` 会让界面显示一个菜单里没有的值（用户点不回去），也可能被平台拒绝。
double normalizeMediaPlaybackSpeed(double value) {
  if (!value.isFinite || value <= 0) return 1.0;
  var best = kMediaPlaybackSpeeds.first;
  var bestDelta = (value - best).abs();
  for (final s in kMediaPlaybackSpeeds) {
    final d = (value - s).abs();
    if (d < bestDelta) {
      best = s;
      bestDelta = d;
    }
  }
  return best;
}

/// 队列里的一条**身份**（不含 URL/凭据）。
class MediaQueueRef {
  const MediaQueueRef({required this.path, required this.name});

  final String path;
  final String name;

  Map<String, dynamic> toJson() => {'path': path, 'name': name};

  static MediaQueueRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final name = raw['name'];
    if (path is! String || path.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    return MediaQueueRef(path: path, name: name);
  }

  @override
  bool operator ==(Object other) =>
      other is MediaQueueRef && other.path == path && other.name == name;

  @override
  int get hashCode => Object.hash(path, name);

  @override
  String toString() => 'MediaQueueRef($path)';
}

/// 一条队列的快照：顺序 + 当前条目 + 队列身份（父目录）。
class MediaQueueSnapshot {
  const MediaQueueSnapshot({
    required this.queueKey,
    required this.items,
    required this.currentPath,
  });

  /// 队列身份（目录路径）；同一目录的队列互相覆盖（一个目录只留一条）
  final String queueKey;

  final List<MediaQueueRef> items;

  /// 上次播到的那一条（重启后用来把下标放回去）
  final String currentPath;

  Map<String, dynamic> toJson() => {
    'items': [for (final i in items) i.toJson()],
    'currentPath': currentPath,
  };

  static MediaQueueSnapshot? fromJson(String queueKey, Object? raw) {
    if (raw is! Map) return null;
    final list = raw['items'];
    if (list is! List) return null;
    final items = <MediaQueueRef>[];
    for (final e in list) {
      final ref = MediaQueueRef.fromJson(e);
      if (ref != null) items.add(ref);
    }
    if (items.isEmpty) return null;
    final current = raw['currentPath'];
    return MediaQueueSnapshot(
      queueKey: queueKey,
      items: items,
      currentPath: current is String ? current : items.first.path,
    );
  }
}

/// [reconcileMediaQueue] 的结果：按快照顺序排好的可用条目 + 恢复的下标。
class MediaQueueRestore {
  const MediaQueueRestore({required this.paths, required this.index});

  /// 仍然存在的条目路径（**按快照顺序**；快照里已消失的被丢掉）
  final List<String> paths;

  /// 上次播放条目在 [paths] 里的下标（找不到 → 0）
  final int index;
}

/// 用**当前真实存在的条目**核对一份队列快照（纯函数）。
///
/// 规则（每一条都有理由）：
///   * 快照里已删除/改名的条目**丢掉**（不能给播放器一个不存在的项）；
///   * 快照里没有、但现在存在的条目**追加到末尾**（新加的一集不能消失）；
///   * 返回顺序 = 快照顺序 + 新增尾部（这就是"队列持久化"的意义：
///     自定义过的顺序重启后还在）；
///   * 下标 = [MediaQueueSnapshot.currentPath] 在新顺序里的位置；
///     它不存在时退回 0（不假装恢复成功）；
///   * 结果为空 → 返回 null（调用方不恢复，走默认目录序）。
MediaQueueRestore? reconcileMediaQueue(
  MediaQueueSnapshot snapshot,
  List<MediaQueueRef> available,
) {
  if (available.isEmpty) return null;
  final byPath = {for (final a in available) a.path: a};
  final ordered = <String>[];
  final seen = <String>{};
  for (final item in snapshot.items) {
    if (!byPath.containsKey(item.path)) continue;
    if (!seen.add(item.path)) continue;
    ordered.add(item.path);
  }
  for (final a in available) {
    if (!seen.add(a.path)) continue;
    ordered.add(a.path);
  }
  if (ordered.isEmpty) return null;
  final index = ordered.indexOf(snapshot.currentPath);
  return MediaQueueRestore(
    paths: ordered,
    index: index < 0 ? 0 : index,
  );
}

/// 媒体身份（字幕记忆的 key）：拿不到稳定身份（相册等没有 `FileEntryDto`）
/// 时返回 null —— 那就**不记忆**，而不是拿 URL（含 `_sid`）当 key。
String? mediaSubtitleMemoryKey({required String path, required int size}) {
  if (path.isEmpty) return null;
  return '$path|$size';
}

/// Audio Station 播放队列里的**一条身份**（不含流式 URL / `_sid`）。
///
/// 为什么不复用 [MediaQueueRef]：AS 条目没有"目录/路径"身份，重启后只能按
/// `id` 回填（`SYNO.AudioStation.Song:getinfo`）。把 id 塞进 `path` 字段会
/// 诱导调用方拿它当文件路径用，所以这里单列一个身份类型 —— 但**存储约定
/// 完全相同**（同一个 `media_playback.json`、同一份读写容错）。
class AudioQueueRef {
  const AudioQueueRef({required this.id, required this.title});

  final String id;

  /// 展示名：回填失败时用来"告知跳过了哪一首"，**不参与**恢复判定
  final String title;

  Map<String, dynamic> toJson() => {'id': id, 'title': title};

  static AudioQueueRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final title = raw['title'];
    return AudioQueueRef(id: id, title: title is String ? title : '');
  }

  @override
  bool operator ==(Object other) =>
      other is AudioQueueRef && other.id == id && other.title == title;

  @override
  int get hashCode => Object.hash(id, title);

  @override
  String toString() => 'AudioQueueRef($id)';
}

/// Audio Station 播放队列快照：顺序 + 上次播放的那条（**只存 id/标题**）。
///
/// AS 同时只有一条播放队列（`audioStationPlayerProvider` 是单例），
/// 所以不像 [MediaQueueSnapshot] 那样按 `queueKey` 分桶。
class AudioQueueSnapshot {
  const AudioQueueSnapshot({required this.items, required this.currentId});

  final List<AudioQueueRef> items;

  /// 上次播放的那条（只有 [items] 里存在的 id 才有意义）
  final String currentId;

  Map<String, dynamic> toJson() => {
    'items': [for (final i in items) i.toJson()],
    'currentId': currentId,
  };

  static AudioQueueSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final list = raw['items'];
    if (list is! List) return null;
    final items = <AudioQueueRef>[];
    final seen = <String>{};
    for (final e in list) {
      final ref = AudioQueueRef.fromJson(e);
      if (ref == null || !seen.add(ref.id)) continue;
      items.add(ref);
    }
    if (items.isEmpty) return null;
    final current = raw['currentId'];
    return AudioQueueSnapshot(
      items: items,
      currentId: current is String ? current : items.first.id,
    );
  }
}

/// 一条**本地**收听记录（A10 最近/最常播放 + B6 断点续播共用一份）。
///
/// 官方安卓客户端把这两件事都放在**本地 SQLite**（`item/PlaylistItem.java`
/// 的 `PredefinedType{most_played, recently_played}`；`DatabaseAccesser` 按
/// `hit_count DESC` 排序，审计 §A10）—— **没有服务端 API**。所以这里也只
/// 存本地：命中次数 + 上次播放时间 + 上次播放位置。
///
/// ⚠️ 只存**身份与计数**，绝不存 URL/凭据（与 [AudioQueueRef] 同一约定）。
class AudioPlayRecord {
  const AudioPlayRecord({
    required this.id,
    this.title = '',
    this.count = 0,
    this.lastPlayedMs = 0,
    this.positionMs = 0,
    this.durationMs = 0,
  });

  final String id;

  /// 展示名（最近/最常列表用；不参与身份判定）。
  final String title;

  /// 命中次数（每"起播一次" +1；官方 `hit_count` 同语义）。
  final int count;

  /// 上次播放的墙上时间（毫秒；0 = 未知）。
  final int lastPlayedMs;

  /// 上次播放位置（毫秒；B6 断点续播用）。
  final int positionMs;

  /// 上次已知总时长（毫秒；判断"是否播到结尾"用）。
  final int durationMs;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'count': count,
    'lastPlayedMs': lastPlayedMs,
    'positionMs': positionMs,
    'durationMs': durationMs,
  };

  static AudioPlayRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    int asInt(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);
    return AudioPlayRecord(
      id: id,
      title: raw['title'] is String ? raw['title'] as String : '',
      count: asInt(raw['count']),
      lastPlayedMs: asInt(raw['lastPlayedMs']),
      positionMs: asInt(raw['positionMs']),
      durationMs: asInt(raw['durationMs']),
    );
  }

  AudioPlayRecord copyWith({
    String? title,
    int? count,
    int? lastPlayedMs,
    int? positionMs,
    int? durationMs,
  }) => AudioPlayRecord(
    id: id,
    title: title ?? this.title,
    count: count ?? this.count,
    lastPlayedMs: lastPlayedMs ?? this.lastPlayedMs,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
  );
}

/// 一条"起播"发生后更新记录（纯函数）：命中 +1、刷新时间、清掉旧断点
/// （重新从头发起播放时旧位置作废）。
AudioPlayRecord audioMarkPlayed(
  AudioPlayRecord? prev, {
  required String id,
  String title = '',
  required int nowMs,
}) {
  final base = prev ?? AudioPlayRecord(id: id);
  return base.copyWith(
    title: title.isNotEmpty ? title : base.title,
    count: base.count + 1,
    lastPlayedMs: nowMs,
    positionMs: 0,
    durationMs: 0,
  );
}

/// 位置上报 → 更新记录里的断点（**不**改命中次数）。
AudioPlayRecord audioMarkPosition(
  AudioPlayRecord? prev, {
  required String id,
  String title = '',
  required int positionMs,
  int durationMs = 0,
}) {
  final base = prev ?? AudioPlayRecord(id: id);
  return base.copyWith(
    title: title.isNotEmpty ? title : base.title,
    positionMs: positionMs < 0 ? 0 : positionMs,
    durationMs: durationMs > 0 ? durationMs : base.durationMs,
  );
}

/// 断点续播的**落点**（毫秒）；不该续播时返回 0（纯函数）。
///
/// 三条纪律（否则就是"续播到很奇怪的地方"）：
///   * 太靠前（< [minMs]，默认 10s）→ 不值得续，回 0；
///   * 已经接近结尾（距总长 < [endGuardMs]，默认 15s，且总长已知）→ 不续，
///     否则一打开就是"放完了"；
///   * 记录里的总长未知（0）时**不**做结尾判断，只按最小值判断。
int audioResumePositionMs(
  AudioPlayRecord? record, {
  int minMs = 10000,
  int endGuardMs = 15000,
}) {
  if (record == null) return 0;
  final pos = record.positionMs;
  if (pos < minMs) return 0;
  if (record.durationMs > 0 && record.durationMs - pos < endGuardMs) return 0;
  return pos;
}

/// 最近播放（按 [AudioPlayRecord.lastPlayedMs] 倒序；**只保留有播放记录的**）。
List<AudioPlayRecord> audioRecentlyPlayed(
  Iterable<AudioPlayRecord> records, {
  int limit = 100,
}) {
  final list = records.where((r) => r.lastPlayedMs > 0).toList()
    ..sort((a, b) {
      final byTime = b.lastPlayedMs.compareTo(a.lastPlayedMs);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  return limit > 0 && list.length > limit ? list.sublist(0, limit) : list;
}

/// 最常播放（按 [AudioPlayRecord.count] 倒序，次数相同按最近播放时间倒序）。
List<AudioPlayRecord> audioMostPlayed(
  Iterable<AudioPlayRecord> records, {
  int limit = 100,
}) {
  final list = records.where((r) => r.count > 0).toList()
    ..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      final byTime = b.lastPlayedMs.compareTo(a.lastPlayedMs);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  return limit > 0 && list.length > limit ? list.sublist(0, limit) : list;
}

/// 字幕样式偏好（垂直偏移 + 背景条）—— r656 · `DA270`。
///
/// 为什么单独做一个值对象：这两项是**看的人的生理/环境偏好**（屏幕多大、
/// 画面亮不亮、字幕会不会压住人脸），不是"这条视频的记忆"。所以它是**全局一份**，
/// 跟倍速同层 —— 一次调好，之后每条视频都照这个来。
///
/// 为什么以前记不住：r655 把它俩放在页面 State 里（`_subtitleOffset` /
/// `_subtitleBackground`），退出播放页就没了 ⇒ 用户每次重看都要重新调两下。
/// 真机现场一眼就能看出来：调好 +80、退出去回个消息再进来，字幕又贴回控制条。
class MediaSubtitleStyle {
  const MediaSubtitleStyle({this.offset = 0, this.background = false});

  /// 垂直偏移（逻辑像素，正值向上）；只允许落在 [kMediaSubtitleOffsets] 档位上
  final double offset;

  /// 半透明背景条
  final bool background;

  static const MediaSubtitleStyle defaults = MediaSubtitleStyle();

  MediaSubtitleStyle copyWith({double? offset, bool? background}) =>
      MediaSubtitleStyle(
        offset: offset ?? this.offset,
        background: background ?? this.background,
      );

  Map<String, dynamic> toJson() => {'offset': offset, 'background': background};

  @override
  bool operator ==(Object other) =>
      other is MediaSubtitleStyle &&
      other.offset == offset &&
      other.background == background;

  @override
  int get hashCode => Object.hash(offset, background);

  @override
  String toString() => 'MediaSubtitleStyle(offset: $offset, background: $background)';
}

/// 把读到/传进来的偏移**吸附到最近的合法档位**（0 / 40 / 80 / 120）。
///
/// 为什么必须吸附：偏好文件可能被旧版本或手改过（37、-5、999…）。直接拿去
/// 渲染会得到"界面显示 +80 而实际是 999"这种自相矛盾，而且 mpv 那边也拿不到
/// 一个确定的读数。非法值一律回到 0（默认位置），**不猜用户想干嘛**。
double normalizeMediaSubtitleOffset(double value) {
  if (!value.isFinite) return 0;
  var best = kMediaSubtitleOffsets.first;
  var bestDelta = (value - best).abs();
  for (final o in kMediaSubtitleOffsets) {
    final d = (value - o).abs();
    if (d < bestDelta) {
      best = o;
      bestDelta = d;
    }
  }
  return best;
}

/// 从 JSON 还原（坏数据/缺键一律回到默认：不许让"记不住偏好"变成"播放报错"）。
MediaSubtitleStyle mediaSubtitleStyleFromJson(Object? raw) {
  if (raw is! Map) return MediaSubtitleStyle.defaults;
  final offset = raw['offset'];
  final background = raw['background'];
  return MediaSubtitleStyle(
    offset: offset is num ? normalizeMediaSubtitleOffset(offset.toDouble()) : 0,
    background: background is bool ? background : false,
  );
}

/// 持久化接口（真实实现落 JSON 文件；测试注入内存实现）。
abstract interface class MediaPlaybackStore {
  /// 全局播放速度（没存过 → null，调用方按 1.0 处理）
  Future<double?> loadSpeed();

  Future<void> saveSpeed(double speed);

  /// 某条媒体的字幕选择（`off` / `embedded:<trackId>` / `external:<fileName>`）
  Future<String?> loadSubtitle(String mediaKey);

  Future<void> saveSubtitle(String mediaKey, String? value);

  /// 某个目录的播放队列快照
  /// 字幕样式偏好（r656 · `DA270`）：全局一份，没存过 = 默认位置、无背景条
  Future<MediaSubtitleStyle> loadSubtitleStyle();

  Future<void> saveSubtitleStyle(MediaSubtitleStyle style);

  Future<MediaQueueSnapshot?> loadQueue(String queueKey);

  Future<void> saveQueue(MediaQueueSnapshot snapshot);

  /// Audio Station 播放队列快照（**单例**：AS 同时只有一条播放队列）。
  ///
  /// 与 [loadQueue] 同一个文件、同一套容错，只是身份不同 —— AS 条目没有
  /// 文件路径身份，恢复只能按 `id`（见 [AudioQueueSnapshot] 的说明）。
  Future<AudioQueueSnapshot?> loadAudioQueue();

  Future<void> saveAudioQueue(AudioQueueSnapshot snapshot);

  /// 本地收听记录（A10 最近/最常播放 + B6 断点续播；按曲目 id 一份）。
  Future<Map<String, AudioPlayRecord>> loadAudioHistory();

  Future<void> saveAudioHistory(Map<String, AudioPlayRecord> records);
}

/// 纯内存实现（单测 / 偏好文件不可用时兜底）。
class InMemoryMediaPlaybackStore implements MediaPlaybackStore {
  InMemoryMediaPlaybackStore({
    double? speed,
    Map<String, String>? subtitles,
    Map<String, MediaQueueSnapshot>? queues,
    AudioQueueSnapshot? audioQueue,
    Map<String, AudioPlayRecord>? audioHistory,
  }) : _speed = speed,
       _subtitles = {...?subtitles},
       _queues = {...?queues},
       _audioQueue = audioQueue,
       _audioHistory = {...?audioHistory};

  double? _speed;
  final Map<String, String> _subtitles;
  final Map<String, MediaQueueSnapshot> _queues;
  AudioQueueSnapshot? _audioQueue;
  final Map<String, AudioPlayRecord> _audioHistory;

  @override
  Future<double?> loadSpeed() async => _speed;

  @override
  Future<void> saveSpeed(double speed) async {
    _speed = normalizeMediaPlaybackSpeed(speed);
  }

  @override
  Future<String?> loadSubtitle(String mediaKey) async => _subtitles[mediaKey];

  @override
  Future<void> saveSubtitle(String mediaKey, String? value) async {
    if (value == null || value.isEmpty) {
      _subtitles.remove(mediaKey);
    } else {
      _subtitles[mediaKey] = value;
    }
  }

  MediaSubtitleStyle _subtitleStyle = MediaSubtitleStyle.defaults;

  @override
  Future<MediaSubtitleStyle> loadSubtitleStyle() async => _subtitleStyle;

  @override
  Future<void> saveSubtitleStyle(MediaSubtitleStyle style) async {
    _subtitleStyle = MediaSubtitleStyle(
      offset: normalizeMediaSubtitleOffset(style.offset),
      background: style.background,
    );
  }

  @override
  Future<MediaQueueSnapshot?> loadQueue(String queueKey) async =>
      _queues[queueKey];

  @override
  Future<void> saveQueue(MediaQueueSnapshot snapshot) async {
    if (snapshot.items.isEmpty) {
      _queues.remove(snapshot.queueKey);
      return;
    }
    _queues[snapshot.queueKey] = snapshot;
  }

  @override
  Future<AudioQueueSnapshot?> loadAudioQueue() async => _audioQueue;

  @override
  Future<void> saveAudioQueue(AudioQueueSnapshot snapshot) async {
    if (snapshot.items.isEmpty) {
      _audioQueue = null;
      return;
    }
    _audioQueue = snapshot;
  }

  @override
  Future<Map<String, AudioPlayRecord>> loadAudioHistory() async =>
      {..._audioHistory};

  @override
  Future<void> saveAudioHistory(Map<String, AudioPlayRecord> records) async {
    _audioHistory
      ..clear()
      ..addAll(records);
  }
}

/// 应用文档目录下的 JSON 实现（`media_playback.json`）。
///
/// 读/写任何一个环节失败都**不抛**：
///   * 解析不出来 → 当作"没存过"（坏文件不能阻断播放）；
///   * 目录拿不到（测试环境 / 无平台通道）→ 退回内存，进程内仍然记忆。
class AppMediaPlaybackStore implements MediaPlaybackStore {
  AppMediaPlaybackStore({Future<File?> Function()? fileResolver})
    : _fileResolver = fileResolver ?? _defaultFile;

  static const String fileName = 'media_playback.json';
  static const int schemaVersion = 1;

  final Future<File?> Function() _fileResolver;
  final InMemoryMediaPlaybackStore _memory = InMemoryMediaPlaybackStore();
  File? _resolved;
  bool _resolveFailed = false;

  static Future<File?> _defaultFile() async {
    try {
      // 延迟 import 的等价物：path_provider 只在这里用，解析失败就内存兜底
      final dir = await _documentsDirectory();
      if (dir == null) return null;
      return File('${dir.path}/$fileName');
    } catch (_) {
      return null;
    }
  }

  Future<File?> _file() async {
    if (_resolved != null) return _resolved;
    if (_resolveFailed) return null;
    final f = await _fileResolver();
    if (f == null) {
      _resolveFailed = true;
      return null;
    }
    _resolved = f;
    return f;
  }

  Future<Map<String, dynamic>> _read() async {
    final f = await _file();
    if (f == null) return const {};
    try {
      if (!await f.exists()) return const {};
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 坏文件当没存过
    }
    return const {};
  }

  Future<void> _write(Map<String, dynamic> data) async {
    final f = await _file();
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode({'version': schemaVersion, ...data}),
        flush: true,
      );
    } catch (_) {
      // 写不进去也不影响本次播放
    }
  }

  @override
  Future<double?> loadSpeed() async {
    final raw = await _read();
    final v = raw['speed'];
    if (v is num) return normalizeMediaPlaybackSpeed(v.toDouble());
    return _memory.loadSpeed();
  }

  @override
  Future<void> saveSpeed(double speed) async {
    final normalized = normalizeMediaPlaybackSpeed(speed);
    await _memory.saveSpeed(normalized);
    final raw = await _read();
    await _write({...raw, 'speed': normalized});
  }

  @override
  Future<String?> loadSubtitle(String mediaKey) async {
    final raw = await _read();
    final map = raw['subtitles'];
    if (map is Map) {
      final v = map[mediaKey];
      if (v is String && v.isNotEmpty) return v;
    }
    return _memory.loadSubtitle(mediaKey);
  }

  @override
  Future<void> saveSubtitle(String mediaKey, String? value) async {
    await _memory.saveSubtitle(mediaKey, value);
    final raw = await _read();
    final map = Map<String, dynamic>.from(
      raw['subtitles'] is Map ? raw['subtitles'] as Map : const {},
    );
    if (value == null || value.isEmpty) {
      map.remove(mediaKey);
    } else {
      map[mediaKey] = value;
    }
    await _write({...raw, 'subtitles': map});
  }

  @override
  Future<MediaSubtitleStyle> loadSubtitleStyle() async {
    final raw = await _read();
    if (raw.containsKey('subtitleStyle')) {
      return mediaSubtitleStyleFromJson(raw['subtitleStyle']);
    }
    return _memory.loadSubtitleStyle();
  }

  @override
  Future<void> saveSubtitleStyle(MediaSubtitleStyle style) async {
    await _memory.saveSubtitleStyle(style);
    final raw = await _read();
    await _write({...raw, 'subtitleStyle': style.toJson()});
  }

  @override
  Future<MediaQueueSnapshot?> loadQueue(String queueKey) async {
    final raw = await _read();
    final queues = raw['queues'];
    if (queues is Map) {
      final snap = MediaQueueSnapshot.fromJson(queueKey, queues[queueKey]);
      if (snap != null) return snap;
    }
    return _memory.loadQueue(queueKey);
  }

  @override
  Future<void> saveQueue(MediaQueueSnapshot snapshot) async {
    await _memory.saveQueue(snapshot);
    final raw = await _read();
    final queues = Map<String, dynamic>.from(
      raw['queues'] is Map ? raw['queues'] as Map : const {},
    );
    queues[snapshot.queueKey] = snapshot.toJson();
    await _write({...raw, 'queues': queues});
  }

  @override
  Future<AudioQueueSnapshot?> loadAudioQueue() async {
    final raw = await _read();
    final snap = AudioQueueSnapshot.fromJson(raw['audioQueue']);
    if (snap != null) return snap;
    return _memory.loadAudioQueue();
  }

  @override
  Future<void> saveAudioQueue(AudioQueueSnapshot snapshot) async {
    await _memory.saveAudioQueue(snapshot);
    final raw = await _read();
    if (snapshot.items.isEmpty) {
      final next = Map<String, dynamic>.from(raw)..remove('audioQueue');
      await _write(next);
      return;
    }
    await _write({...raw, 'audioQueue': snapshot.toJson()});
  }

  @override
  Future<Map<String, AudioPlayRecord>> loadAudioHistory() async {
    final raw = await _read();
    final map = raw['audioHistory'];
    if (map is Map) {
      final out = <String, AudioPlayRecord>{};
      for (final entry in map.entries) {
        final rec = AudioPlayRecord.fromJson(entry.value);
        if (rec != null) out[rec.id] = rec;
      }
      if (out.isNotEmpty) return out;
    }
    return _memory.loadAudioHistory();
  }

  @override
  Future<void> saveAudioHistory(Map<String, AudioPlayRecord> records) async {
    await _memory.saveAudioHistory(records);
    final raw = await _read();
    if (records.isEmpty) {
      final next = Map<String, dynamic>.from(raw)..remove('audioHistory');
      await _write(next);
      return;
    }
    await _write({
      ...raw,
      'audioHistory': {
        for (final e in records.entries) e.key: e.value.toJson(),
      },
    });
  }
}

/// 应用文档目录（唯一用到 `path_provider` 的地方）。
///
/// 拿不到（无平台通道的纯单测 / 权限异常）时返回 null → 退回内存：
/// 偏好是增强，**绝不**因为存不了偏好把播放变成失败。
Future<Directory?> _documentsDirectory() async {
  try {
    return await getApplicationDocumentsDirectory();
  } catch (_) {
    return null;
  }
}

/// 播放偏好存储（测试覆盖成内存实现；生产用文档目录 JSON）。
final mediaPlaybackStoreProvider = Provider<MediaPlaybackStore>(
  (ref) => AppMediaPlaybackStore(),
);
