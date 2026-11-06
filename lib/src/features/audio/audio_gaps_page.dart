// Audio Station「首页预置列表」与「本地收听记录」页（G2 批次）。
//
// 本文件实现三行：
//   * **A7 最近添加** —— `Album.list{sort_by:time, sort_direction:DESC, limit:50}`
//     （官方 `ApiEnumerator.java:253-257`；真机 total 1210 / 回 50）；
//   * **A8 Random100** —— `Song.list{sort_by:random, limit:100}`
//     （官方 `ApiEnumerator.java:499-521`；真机回 100）；
//   * **A10 最近播放 / 最常播放** —— **纯本地**收听记录（官方也是本地
//     SQLite `hit_count DESC`，无服务端 API）。
//
// 三页都沿用本模块既有状态语言：区分"未连接 / 套件未安装 / 无权限 / 网络 /
// 一条都没有"（`AudioPagedBody` 与 `AudioEmptyState` 同款）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../data/audio_station.dart';
import '../../data/dto/audio_station_dto.dart';
import '../media/media_playback_store.dart';
import 'audio_cover.dart';
import 'audio_detail_page.dart';
import 'audio_labels.dart';
import 'audio_page.dart';
import 'audio_providers.dart';
import 'audio_song_page.dart';

/// A7：最近添加的专辑（`Album.list` 按 `time` 倒序，官方 `limit=50`）。
class AudioRecentlyAddedPage extends ConsumerWidget {
  const AudioRecentlyAddedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(audioRecentlyAddedProvider);
    return DesignScaffold(
      appBar: AppBar(title: Text(dataText('asRecentlyAdded', '最近添加'))),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppErrorView(
          key: const Key('as-recently-added-error'),
          title: dataText('asRecentlyAddedFailed', '最近添加加载失败'),
          detail: describeAudioError(e),
          onRetry: () => ref.invalidate(audioRecentlyAddedProvider),
        ),
        data: (page) {
          if (page.items.isEmpty) {
            return AppEmptyState(
              key: const Key('as-recently-added-empty'),
              icon: Icons.album_outlined,
              title: dataText('asRecentlyAddedEmpty', '还没有最近添加的专辑'),
            );
          }
          return ListView.separated(
            key: const Key('as-recently-added-list'),
            padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xxl),
            itemCount: page.items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 2),
            itemBuilder: (context, i) {
              final album = page.items[i];
              return DesignRowTile(
                key: Key('as-recent-album-${album.name}'),
                leading: AudioCoverImage(
                  key: Key('as-recent-album-cover-${album.name}'),
                  identity: album.name,
                  url: ref
                      .read(audioApiProvider)
                      ?.albumCoverUrl(
                        album.name,
                        albumArtist: album.albumArtist,
                      ),
                  fallbackIcon: Icons.album_outlined,
                ),
                title: Text(
                  album.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: asAlbumMetaLine(album).isEmpty
                    ? null
                    : Text(
                        asAlbumMetaLine(album),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: DesignType.labelSmallSize,
                          color: DesignPalette.of(context).dim,
                        ),
                      ),
                onTap: () => Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AudioDetailPage.album(
                      name: album.name,
                      albumArtist: album.albumArtist,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// A8：随机 100 首（`Song.list{sort_by:random, limit:100}`）。
///
/// ⚠️ 每进一次页面就是一次**重新随机**（官方按钮 `btn_randomize_100` 同语义）；
/// 右上角刷新按钮重取一批。
class AudioRandom100Page extends ConsumerWidget {
  const AudioRandom100Page({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(audioRandom100Provider);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(dataText('asRandom100', '随机 100 首')),
        actions: [
          IconButton(
            key: const Key('as-random-100-refresh'),
            tooltip: dataText('asRandom100Refresh', '换一批'),
            icon: const Icon(Icons.casino_outlined),
            onPressed: () => ref.invalidate(audioRandom100Provider),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppErrorView(
          key: const Key('as-random-100-error'),
          title: dataText('asRandom100Failed', '随机列表加载失败'),
          detail: describeAudioError(e),
          onRetry: () => ref.invalidate(audioRandom100Provider),
        ),
        data: (page) {
          final songs = page.items;
          if (songs.isEmpty) {
            return AppEmptyState(
              key: const Key('as-random-100-empty'),
              icon: Icons.shuffle_outlined,
              title: dataText('asEmptySongs', '音乐库里还没有歌曲'),
            );
          }
          return ListView.separated(
            key: const Key('as-random-100-list'),
            padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xxl),
            itemCount: songs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 2),
            itemBuilder: (context, i) => AudioSongTile(
              key: Key('as-random-song-${songs[i].id}'),
              song: songs[i],
              onTap: () => _openSong(context, songs[i], queue: songs, index: i),
            ),
          );
        },
      ),
    );
  }
}

/// A10：最近播放 / 最常播放（**本地**记录，与官方 `hit_count` 同语义）。
enum AudioPlayedMode {
  /// 最近播放（按上次播放时间倒序）。
  recently,

  /// 最常播放（按命中次数倒序）。
  most,
}

class AudioPlayedPage extends ConsumerWidget {
  const AudioPlayedPage({super.key, required this.mode});

  final AudioPlayedMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = mode == AudioPlayedMode.recently
        ? dataText('asRecentlyPlayed', '最近播放')
        : dataText('asMostPlayed', '最常播放');
    final all = ref.watch(audioListenHistoryProvider);
    final records = mode == AudioPlayedMode.recently
        ? ref.watch(audioRecentlyPlayedProvider)
        : ref.watch(audioMostPlayedProvider);
    return DesignScaffold(
      appBar: AppBar(title: Text(title)),
      body: all.isLoading && !all.hasValue
          ? const Center(child: CircularProgressIndicator())
          : records.isEmpty
          ? AppEmptyState(
              key: Key('as-played-empty-${mode.name}'),
              icon: Icons.history_outlined,
              title: mode == AudioPlayedMode.recently
                  ? dataText('asRecentlyPlayedEmpty', '还没有播放记录')
                  : dataText('asMostPlayedEmpty', '还没有播放记录'),
            )
          : ListView.separated(
              key: Key('as-played-list-${mode.name}'),
              padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xxl),
              itemCount: records.length,
              separatorBuilder: (_, _) => const SizedBox(height: 2),
              itemBuilder: (context, i) => _PlayedTile(record: records[i]),
            ),
    );
  }
}

class _PlayedTile extends ConsumerWidget {
  const _PlayedTile({required this.record});

  final AudioPlayRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = <String>[
      // ★ r481（DA118）：英文的 "Played 1 times" 是错的 ⇒ 单数走**专用键**
      //   （复数语言只有"1"这一个特例，用不着 ICU plural 那一整套）。
      if (record.count > 0)
        record.count == 1
            ? dataText('asPlayCountOne', '播放 1 次')
            : dataText('asPlayCount', '播放 {count} 次').replaceAll(
                '{count}',
                '${record.count}',
              ),
      if (record.lastPlayedMs > 0) _relativeTime(record.lastPlayedMs),
      if (record.positionMs > 0) asDurationText(record.positionMs ~/ 1000),
    ].join(' · ');
    return DesignRowTile(
      key: Key('as-played-${record.id}'),
      leading: const Icon(Icons.music_note_outlined),
      title: Text(
        record.title.isNotEmpty ? record.title : record.id,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: meta.isEmpty
          ? null
          : Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: DesignType.labelSmallSize,
                color: DesignPalette.of(context).dim,
              ),
            ),
      onTap: () => Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => AudioSongDetailPage(
            songId: record.id,
            title: record.title.isNotEmpty ? record.title : record.id,
          ),
        ),
      ),
    );
  }

  /// 相对时间（`刚刚` / `N 分钟前` / `N 小时前` / `N 天前`）。
  ///
  /// 纯本地展示，**不**做国际化时间格式（避免引入 `intl` 依赖）。
  static String _relativeTime(int ms) {
    final delta = DateTime.now().millisecondsSinceEpoch - ms;
    if (delta < 60 * 1000) return dataText('asJustNow', '刚刚');
    if (delta < 60 * 60 * 1000) {
      final n = delta ~/ 60000;
      if (n == 1) return dataText('asMinutesAgoOne', '1 分钟前');
      return dataText('asMinutesAgo', '{n} 分钟前').replaceAll('{n}', '$n');
    }
    if (delta < 24 * 60 * 60 * 1000) {
      final n = delta ~/ 3600000;
      if (n == 1) return dataText('asHoursAgoOne', '1 小时前');
      return dataText('asHoursAgo', '{n} 小时前').replaceAll('{n}', '$n');
    }
    final n = delta ~/ 86400000;
    if (n == 1) return dataText('asDaysAgoOne', '1 天前');
    return dataText('asDaysAgo', '{n} 天前').replaceAll('{n}', '$n');
  }
}

void _openSong(
  BuildContext context,
  AudioSongDto song, {
  List<AudioSongDto> queue = const [],
  int index = 0,
}) {
  final title = song.title.isNotEmpty ? song.title : song.path;
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => AudioSongDetailPage(
        songId: song.id,
        title: title,
        queue: queue,
        queueIndex: index,
      ),
    ),
  );
}
