// Audio Station 搜索页（阶段二 A：Audio Station 普通用户功能）。
//
// 两条通道（doc §2.3 A-1a 第 10/12 行）：
//   * 歌曲 = `Song.search` v3（`keyword` + `additional="song_tag,song_audio,song_rating"`）；
//   * 分类聚合 = `Search.list` v1（root `data`，各分类可选）。
//
// 分类聚合**失败就回空**（参数键名虽在 doc 里，取值形态是从官方
// `getSearchJsonObj` 补齐的，见 `AudioStationApi.globalSearch`），
// 不影响歌曲结果 —— 保守起见不把整页判成失败。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../design/kit/design_kit.dart';
import '../../data/dto/audio_station_dto.dart';
import 'audio_detail_page.dart';
import 'audio_page.dart';
import 'audio_providers.dart';
import 'audio_song_page.dart';

class AudioSearchPage extends ConsumerStatefulWidget {
  const AudioSearchPage({super.key});

  @override
  ConsumerState<AudioSearchPage> createState() => _AudioSearchPageState();
}

class _AudioSearchPageState extends ConsumerState<AudioSearchPage> {
  final _controller = TextEditingController();
  String _keyword = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final kw = raw.trim();
    if (kw == _keyword) return;
    setState(() => _keyword = kw);
    if (kw.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(audioSongListProvider(songSearchQuery(kw)).notifier).load();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return DesignScaffold(
      appBar: AppBar(
        title: TextField(
          key: const Key('as-search-field'),
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: t.asSearchHint,
            border: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(
            key: const Key('as-search-go'),
            tooltip: t.asSearchTitle,
            icon: const Icon(Icons.search),
            onPressed: () => _submit(_controller.text),
          ),
        ],
      ),
      body: _keyword.isEmpty
          ? AppEmptyState(icon: Icons.search, title: t.asSearchHint)
          : Column(
              children: [
                _AggregateStrip(keyword: _keyword),
                Expanded(child: _SongResults(keyword: _keyword)),
              ],
            ),
    );
  }
}

/// 歌曲结果（`Song.search`，分页）。
class _SongResults extends ConsumerStatefulWidget {
  const _SongResults({required this.keyword});

  final String keyword;

  @override
  ConsumerState<_SongResults> createState() => _SongResultsState();
}

class _SongResultsState extends ConsumerState<_SongResults> {
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final state = ref.watch(
      audioSongListProvider(songSearchQuery(widget.keyword)),
    );
    return AudioPagedBody<AudioSongDto>(
      kind: AudioBrowseKind.song,
      state: state,
      emptyTitle: t.asSearchEmpty,
      errorTitle: t.asSearchFailed,
      onLoad: () => ref
          .read(audioSongListProvider(songSearchQuery(widget.keyword)).notifier)
          .load(),
      onLoadMore: () => ref
          .read(audioSongListProvider(songSearchQuery(widget.keyword)).notifier)
          .loadMore(),
      onRefresh: () => ref
          .read(audioSongListProvider(songSearchQuery(widget.keyword)).notifier)
          .refresh(),
      itemBuilder: (context, song) => AudioSongTile(
        key: Key('as-song-${song.id}'),
        song: song,
        // ★ r642（DA236）：搜索结果点歌 = 带结果队列 + 立刻起播
        onTap: () => Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(
            builder: (_) => AudioSongDetailPage(
              songId: song.id,
              title: song.title.isNotEmpty ? song.title : song.path,
              queue: state.items,
              queueIndex: state.items.indexWhere((e) => e.id == song.id),
              autoPlay: state.items.isNotEmpty,
            ),
          ),
        ),
      ),
    );
  }
}

/// 分类聚合条（`Search.list` 的 albums/artists/genres/composers）。
///
/// 没有命中或有任何失败都不占高度（回 `SizedBox.shrink`），不干扰歌曲结果。
class _AggregateStrip extends ConsumerWidget {
  const _AggregateStrip({required this.keyword});

  final String keyword;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (keyword.isEmpty) return const SizedBox.shrink();
    final result = ref.watch(audioGlobalSearchProvider(keyword)).value;
    if (result == null || result.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 92,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.md,
          vertical: Gap.xs,
        ),
        children: [
          for (final a in result.albums)
            _AggregateChip(
              key: Key('as-search-album-${a.name}'),
              icon: Icons.album_outlined,
              label: a.name,
              onTap: () => _push(
                context,
                AudioDetailPage.album(name: a.name, albumArtist: a.albumArtist),
              ),
            ),
          for (final a in result.artists)
            _AggregateChip(
              key: Key('as-search-artist-${a.name}'),
              icon: Icons.person_outline,
              label: a.name,
              onTap: () => _push(context, AudioDetailPage.artist(name: a.name)),
            ),
          for (final a in result.genres)
            _AggregateChip(
              key: Key('as-search-genre-${a.name}'),
              icon: Icons.category_outlined,
              label: a.name,
              onTap: () => _push(context, AudioDetailPage.genre(name: a.name)),
            ),
          for (final a in result.composers)
            _AggregateChip(
              key: Key('as-search-composer-${a.name}'),
              icon: Icons.piano_outlined,
              label: a.name,
              onTap: () =>
                  _push(context, AudioDetailPage.composer(name: a.name)),
            ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}

class _AggregateChip extends StatelessWidget {
  const _AggregateChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xxs),
      child: ActionChip(
        avatar: Icon(icon, size: 16, color: hud.dim),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        onPressed: onTap,
      ),
    );
  }
}
