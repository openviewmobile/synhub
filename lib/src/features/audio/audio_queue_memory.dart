// Audio Station 播放队列的**持久化 + 按 id 回填**（W1-2/W1-3 收尾）。
//
// 背景（`docs/media-player-download-ux-w1-2-3.md` §5 登记项）：AS 队列是网络
// DTO（`AudioSongDto`），条目里的流式 URL 带 `_sid`、会随会话失效（凭据只活在
// 内存 —— 与 `media_source.dart` 的既有约定一致）。所以持久化**只存 id + 标题**，
// 重启后按 id 回填：
//
//   * 回填 API = 官方 `SYNO.AudioStation.Song:getinfo` v3（参数 `id`）。
//     证据：`docs/stage2-audio-download-api.md:137`（`Song` v1–v3 都有
//     `getinfo`）、`:209`（第 11 行 `getinfo` v3，参数 `id`，用途"歌曲详情 /
//     播放前取元数据"）；实现 `lib/src/data/audio_station.dart:329`（`getSong`）；
//     既有页面 provider `audio_providers.dart:482`（`audioSongProvider`）。
//     —— **已取证**，所以这里真的按 id 回填，不是"登记不做"。
//
//   * 存储**复用** `media_playback_store.dart` 的同一套约定：同一个
//     `media_playback.json`、同一份读写容错（坏文件不抛 / 无平台通道退内存），
//     不另造存储。
//
//   * 恢复失败（歌被删 / 无权限 / 离线）→ **跳过那一首并告知**（
//     [AudioQueueRestoreResult.skipped]），绝不清空整个队列，也不清掉已存的快照。
//
//   * 回填预算 [kAudioQueueRestoreLimit]：逐条 `getinfo` 是一首一个请求，
//     服务端队列上限 8192（`Info.getinfo.playing_queue_max`），重启后照着打
//     8000 次请求会把 NAS 和网络拖死。
library;

import '../../data/dto/audio_station_dto.dart';
import '../media/media_playback_store.dart';

/// 单次恢复**最多回填**多少首（不是服务端队列上限，是恢复预算）。
///
/// 超过预算时保留靠前的条目；如果"这次打开的那一首"被截在预算外，就用它
/// 替掉最后一条 —— 保证用户点开的那首一定能播（详见 [restoreAudioQueue]）。
const int kAudioQueueRestoreLimit = 200;

/// 把一条 AS 队列 + 下标做成持久化快照（空队列 / 全空 id → null，不落盘）。
///
/// 重复 id 只留第一条（同一首歌在列表里出现两次不该占两个恢复请求）。
AudioQueueSnapshot? audioQueueSnapshotOf(List<AudioSongDto> queue, int index) {
  if (queue.isEmpty) return null;
  final items = <AudioQueueRef>[];
  final seen = <String>{};
  for (final s in queue) {
    if (s.id.isEmpty || !seen.add(s.id)) continue;
    items.add(
      AudioQueueRef(id: s.id, title: s.title.isNotEmpty ? s.title : s.path),
    );
  }
  if (items.isEmpty) return null;
  final i = index.clamp(0, queue.length - 1);
  final current = queue[i];
  return AudioQueueSnapshot(
    items: items,
    currentId: items.any((e) => e.id == current.id) ? current.id : items.first.id,
  );
}

/// 按 id 回填的结果。
class AudioQueueRestoreResult {
  const AudioQueueRestoreResult({
    required this.songs,
    required this.index,
    required this.skipped,
  });

  /// 回填成功、**保持原顺序**的曲目（被删 / 无权限的不在其中）
  final List<AudioSongDto> songs;

  /// 起播 / 当前条目的下标（已收敛到 [songs] 范围内）
  final int index;

  /// 回填失败的条目标题（用来**告知**用户"跳过了哪几首"，不是静默丢弃）
  final List<String> skipped;

  bool get isEmpty => songs.isEmpty;
}

/// 按 [snapshot] 的顺序逐条回填（纯异步逻辑，`fetch` 可注入 → 离线可测）。
///
/// 规则（与 `reconcileMediaQueue` 同一精神，每条都有理由）：
///   * 顺序 = 快照顺序；回填失败**只丢那一首**，其余保持原顺序（不重排）；
///   * `fetch` 返回 null 或抛（被删 / 无权限 / 网络）→ 记进 [skipped]，**继续**；
///   * 下标优先 [preferId]（= 用户这次点开的那一首，不抢用户的选择），
///     其次 `snapshot.currentId`，都没有才退回 0；
///   * 全部失效 → 返回空 [songs]；调用方**不得**据此清空已存快照
///     （用户可能只是这一会儿没权限/离线）。
Future<AudioQueueRestoreResult> restoreAudioQueue({
  required AudioQueueSnapshot snapshot,
  required Future<AudioSongDto?> Function(String id) fetch,
  String? preferId,
  int maxItems = kAudioQueueRestoreLimit,
}) async {
  var wanted = snapshot.items;
  final budget = maxItems <= 0 ? wanted.length : maxItems;
  if (wanted.length > budget && budget > 0) {
    final keep = wanted.take(budget).toList();
    if (preferId != null && !keep.any((e) => e.id == preferId)) {
      for (final e in wanted) {
        if (e.id != preferId) continue;
        // 用"这次打开的这首"替掉预算里的最后一条：其余相对顺序不变，
        // 且用户点开的那首不会被预算截掉（它必须能播）。
        keep[budget - 1] = e;
        break;
      }
    }
    wanted = keep;
  }

  final songs = <AudioSongDto>[];
  final skipped = <String>[];
  final indexById = <String, int>{};
  for (final item in wanted) {
    AudioSongDto? song;
    try {
      song = await fetch(item.id);
    } catch (_) {
      song = null;
    }
    if (song == null) {
      skipped.add(item.title.isNotEmpty ? item.title : item.id);
      continue;
    }
    indexById[item.id] = songs.length;
    songs.add(song);
  }

  if (songs.isEmpty) {
    return AudioQueueRestoreResult(
      songs: const [],
      index: 0,
      skipped: skipped,
    );
  }
  final preferred = preferId == null ? null : indexById[preferId];
  final fallback = indexById[snapshot.currentId] ?? 0;
  return AudioQueueRestoreResult(
    songs: songs,
    index: (preferred ?? fallback).clamp(0, songs.length - 1),
    skipped: skipped,
  );
}
