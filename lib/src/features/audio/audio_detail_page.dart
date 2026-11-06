// Audio Station 详情页（阶段二 A：Audio Station 普通用户功能）。
//
// 钻取链路**逐字**对齐包内官方前端 `audio-common.js` 的
// `prepareGotoNextParam`：
//   * 专辑 → `Song.list {album, album_artist}`；
//   * 艺术家 → `Album.list {artist}`；
//   * 作曲家 → `Album.list {composer}`；
//   * 流派 → `Artist.list {genre}`；
//   * 文件夹 → `Folder.list {id}`（目录可继续钻）；
//   * 播放列表 → `Playlist.getinfo {id}`（曲目在 `additional.songs`）。
//
// 收藏（`Pin.pin` v1）只在有明确 `criteria` 的分类上给入口
// （官方 `getPinArgumentsFromRecord` 的值域）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../data/audio_station.dart';
import '../../data/dto/audio_station_dto.dart';
import 'audio_cover.dart';
import 'audio_labels.dart';
import 'audio_page.dart';
import 'audio_providers.dart';
import 'audio_song_page.dart';
import 'audio_search_page.dart';

class AudioDetailPage extends ConsumerStatefulWidget {
  const AudioDetailPage._({
    super.key,
    required this.kind,
    this.name = '',
    this.album,
    this.albumArtist,
    this.artist,
    this.composer,
    this.genre,
    this.folderId,
    this.folderPath,
    this.playlistId,
  });

  /// 专辑详情：列出该专辑的歌曲。
  const AudioDetailPage.album({
    Key? key,
    required String name,
    String albumArtist = '',
  }) : this._(
         key: key,
         kind: AudioBrowseKind.album,
         name: name,
         album: name,
         albumArtist: albumArtist,
       );

  /// 艺术家详情：列出该艺术家的专辑。
  const AudioDetailPage.artist({Key? key, required String name})
    : this._(key: key, kind: AudioBrowseKind.artist, name: name, artist: name);

  /// 作曲家详情：列出该作曲家的专辑。
  const AudioDetailPage.composer({Key? key, required String name})
    : this._(
        key: key,
        kind: AudioBrowseKind.composer,
        name: name,
        composer: name,
      );

  /// 流派详情：列出该流派的艺术家（官方 `prepareGotoNextParam` 同款）。
  const AudioDetailPage.genre({Key? key, required String name})
    : this._(key: key, kind: AudioBrowseKind.genre, name: name, genre: name);

  /// 文件夹详情：列出目录/文件（目录可继续钻）。
  const AudioDetailPage.folder({
    Key? key,
    String? id,
    String? path,
    String name = '',
  }) : this._(
         key: key,
         kind: AudioBrowseKind.folder,
         name: name,
         folderId: id,
         folderPath: path,
       );

  /// 播放列表详情：`Playlist.getinfo` 取曲目。
  const AudioDetailPage.playlist({
    Key? key,
    required String id,
    required String name,
  }) : this._(
         key: key,
         kind: AudioBrowseKind.playlist,
         name: name,
         playlistId: id,
       );

  final AudioBrowseKind kind;

  /// 展示名（文件夹没有名字时退化成 id/path）。
  final String name;
  final String? album;
  final String? albumArtist;
  final String? artist;
  final String? composer;
  final String? genre;
  final String? folderId;
  final String? folderPath;
  final String? playlistId;

  /// 标题（`AppBar` 用）。
  String get title => name.isNotEmpty ? name : (folderId ?? folderPath ?? '');

  @override
  ConsumerState<AudioDetailPage> createState() => _AudioDetailPageState();
}

class _AudioDetailPageState extends ConsumerState<AudioDetailPage> {
  @override
  void initState() {
    super.initState();
    if (widget.kind == AudioBrowseKind.playlist) return; // 走 FutureProvider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  // ---- 各分类的查询（record 有结构相等，family 复用同一实例）------------
  SongQuery get _songQuery => (
    album: widget.album,
    albumArtist: widget.albumArtist,
    artist: null,
    composer: null,
    genre: null,
    folder: null,
    playlist: null,
    keyword: null,
    library: null,
  );

  AlbumQuery get _artistAlbumQuery => (
    artist: widget.artist,
    composer: null,
    genre: null,
    search: null,
    filter: null,
    library: null,
  );

  AlbumQuery get _composerAlbumQuery => (
    artist: null,
    composer: widget.composer,
    genre: null,
    search: null,
    filter: null,
    library: null,
  );

  NamedQuery get _genreArtistQuery =>
      namedQuery(AudioBrowseKind.artist, genre: widget.genre);

  FolderQuery get _folderQuery =>
      (id: widget.folderId, path: widget.folderPath, library: null);

  Future<void> _load({bool silent = false}) async {
    switch (widget.kind) {
      case AudioBrowseKind.album:
        await ref
            .read(audioSongListProvider(_songQuery).notifier)
            .load(silent: silent);
      case AudioBrowseKind.artist:
        await ref
            .read(audioAlbumListProvider(_artistAlbumQuery).notifier)
            .load(silent: silent);
      case AudioBrowseKind.composer:
        await ref
            .read(audioAlbumListProvider(_composerAlbumQuery).notifier)
            .load(silent: silent);
      case AudioBrowseKind.genre:
        await ref
            .read(audioNamedListProvider(_genreArtistQuery).notifier)
            .load(silent: silent);
      case AudioBrowseKind.folder:
        await ref
            .read(audioFolderListProvider(_folderQuery).notifier)
            .load(silent: silent);
      default:
        return;
    }
  }

  Future<void> _loadMore() async {
    switch (widget.kind) {
      case AudioBrowseKind.album:
        await ref.read(audioSongListProvider(_songQuery).notifier).loadMore();
      case AudioBrowseKind.artist:
        await ref
            .read(audioAlbumListProvider(_artistAlbumQuery).notifier)
            .loadMore();
      case AudioBrowseKind.composer:
        await ref
            .read(audioAlbumListProvider(_composerAlbumQuery).notifier)
            .loadMore();
      case AudioBrowseKind.genre:
        await ref
            .read(audioNamedListProvider(_genreArtistQuery).notifier)
            .loadMore();
      case AudioBrowseKind.folder:
        await ref
            .read(audioFolderListProvider(_folderQuery).notifier)
            .loadMore();
      default:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return DesignScaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // 设计稿 `audio_detail.appbar.actions = [search, more]`：本页的"更多"
          // 就是「收藏/取消收藏」（唯一有副作用的动作），"搜索"直达搜索页。
          IconButton(
            key: const Key('as-detail-search'),
            tooltip: t.asSearchTitle,
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(builder: (_) => const AudioSearchPage()),
            ),
          ),
          if (_pinRequest() != null)
            IconButton(
              key: const Key('as-pin-add'),
              tooltip: t.asPinAdd,
              icon: const Icon(Icons.favorite_border),
              onPressed: _addPin,
            ),
        ],
      ),
      body: widget.kind == AudioBrowseKind.playlist
          ? _playlistBody(context)
          : _pagedBody(context),
    );
  }

  Widget _playlistBody(BuildContext context) {
    final t = context.t;
    final id = widget.playlistId ?? '';
    final async = ref.watch(audioPlaylistDetailProvider(id));
    return async.when(
      loading: () => const AppListSkeleton(),
      error: (e, _) => AppErrorView(
        title: t.asPlaylistLoadFailed,
        detail: describeAudioError(e),
        onRetry: () => ref.invalidate(audioPlaylistDetailProvider(id)),
      ),
      data: (p) {
        if (p == null) {
          return AppEmptyState(
            icon: Icons.queue_music_outlined,
            title: t.asErrPlaylistNotExists,
          );
        }
        if (p.songs.isEmpty) {
          return AppEmptyState(
            icon: Icons.music_note_outlined,
            title: t.asEmptyDetailSongs,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xxl * 2),
          itemCount: p.songs.length,
          separatorBuilder: (_, _) => Divider(
            height: 1,
            color: DesignPalette.of(context).dim.withValues(alpha: 0.12),
          ),
          itemBuilder: (context, i) {
            final song = p.songs[i];
            return AudioSongTile(
              key: Key('as-song-${song.id}'),
              song: song,
              // 队列 = 这个播放列表的全部曲目（P0-2：连续听 + 上一首/下一首）
              onTap: () => _openSong(context, song, queue: p.songs, index: i),
            );
          },
        );
      },
    );
  }

  Widget _pagedBody(BuildContext context) {
    switch (widget.kind) {
      case AudioBrowseKind.album:
        final s = ref.watch(audioSongListProvider(_songQuery));
        return AudioPagedBody<AudioSongDto>(
          kind: AudioBrowseKind.song,
          state: s,
          onLoad: _load,
          onLoadMore: _loadMore,
          onRefresh: () => _load(silent: true),
          emptyTitle: asDetailEmptyLabel(context.t, widget.kind),
          itemBuilder: (context, song) => AudioSongTile(
            key: Key('as-song-${song.id}'),
            song: song,
            // 队列 = 这个专辑的全部曲目（P0-2）
            onTap: () => _openSong(
              context,
              song,
              queue: s.items,
              index: s.items.indexOf(song),
            ),
          ),
        );
      case AudioBrowseKind.artist:
      case AudioBrowseKind.composer:
        final s = ref.watch(
          audioAlbumListProvider(
            widget.kind == AudioBrowseKind.composer
                ? _composerAlbumQuery
                : _artistAlbumQuery,
          ),
        );
        return AudioPagedBody<AudioAlbumDto>(
          kind: AudioBrowseKind.album,
          state: s,
          onLoad: _load,
          onLoadMore: _loadMore,
          onRefresh: () => _load(silent: true),
          emptyTitle: asDetailEmptyLabel(context.t, widget.kind),
          itemBuilder: (context, album) => DesignRowTile(
            key: Key('as-album-${album.name}'),
            // r439：与专辑列表同一套两级封面（专辑级 → 逐首探 `getsongcover`）
            leading: AudioCoverImage(
              key: Key('as-album-cover-${album.name}'),
              identity: album.name,
              url: ref
                  .read(audioApiProvider)
                  ?.albumCoverUrl(
                    album.name,
                    albumArtist: album.albumArtist,
                  ),
              resolveFallback: albumCoverFallbackOf(
                ref.watch(albumCoverResolverProvider),
                album,
              ),
              fallbackIcon: Icons.album_outlined,
            ),
            title: Text(
              album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              asAlbumMetaLine(album),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: DesignType.labelSmallSize,
                letterSpacing: 0.2,
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
          ),
        );
      case AudioBrowseKind.genre:
        final s = ref.watch(audioNamedListProvider(_genreArtistQuery));
        return AudioPagedBody<AudioNameDto>(
          kind: AudioBrowseKind.artist,
          state: s,
          onLoad: _load,
          onLoadMore: _loadMore,
          onRefresh: () => _load(silent: true),
          emptyTitle: asDetailEmptyLabel(context.t, widget.kind),
          itemBuilder: (context, name) => DesignRowTile(
            key: Key('as-artist-${name.name}'),
            leading: const Icon(Icons.person_outline),
            title: Text(
              name.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => AudioDetailPage.artist(name: name.name),
              ),
            ),
          ),
        );
      case AudioBrowseKind.folder:
        final s = ref.watch(audioFolderListProvider(_folderQuery));
        return AudioPagedBody<AudioFolderItemDto>(
          kind: AudioBrowseKind.folder,
          state: s,
          onLoad: _load,
          onLoadMore: _loadMore,
          onRefresh: () => _load(silent: true),
          emptyTitle: asDetailEmptyLabel(context.t, widget.kind),
          itemBuilder: (context, item) => DesignRowTile(
            key: Key('as-folder-${item.id}'),
            leading: Icon(
              item.isFolder ? Icons.folder_outlined : Icons.music_note_outlined,
            ),
            title: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: item.isFolder
                ? () => Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AudioDetailPage.folder(
                        id: item.id,
                        path: item.path,
                        name: item.title,
                      ),
                    ),
                  )
                : () => Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AudioSongDetailPage(
                        songId: item.id,
                        title: item.title,
                      ),
                    ),
                  ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// 打开单曲页。
  ///
  /// P0-2：把**所在列表**当作播放队列一起带进去（`queue` + 起始 `index`），
  /// 单曲页据此提供上一首/下一首 · 随机 · 循环；不传时退化成单曲
  /// （文件夹里的孤立文件、直接跳转等场景）。
  void _openSong(
    BuildContext context,
    AudioSongDto song, {
    List<AudioSongDto> queue = const [],
    int index = 0,
  }) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => AudioSongDetailPage(
          songId: song.id,
          title: song.title.isNotEmpty ? song.title : song.path,
          queue: queue,
          queueIndex: index,
          // ★ r642（DA236）：专辑/播放列表里点歌也**立刻起播**（与歌曲列表一致）
          autoPlay: queue.isNotEmpty,
        ),
      ),
    );
  }

  /// 收藏（`Pin.pin`）的请求体；没有明确 `criteria` 的分类返回 null（不给入口）。
  AudioPinRequest? _pinRequest() {
    switch (widget.kind) {
      case AudioBrowseKind.album:
        final name = widget.album ?? '';
        if (name.isEmpty) return null;
        return AudioPinRequest(
          type: 'album',
          criteria: {
            'album': name,
            if ((widget.albumArtist ?? '').isNotEmpty)
              'album_artist': widget.albumArtist,
          },
          name: name,
        );
      case AudioBrowseKind.artist:
        final name = widget.artist ?? '';
        return name.isEmpty
            ? null
            : AudioPinRequest(
                type: 'artist',
                criteria: {'artist': name},
                name: name,
              );
      case AudioBrowseKind.composer:
        final name = widget.composer ?? '';
        return name.isEmpty
            ? null
            : AudioPinRequest(
                type: 'composer',
                criteria: {'composer': name},
                name: name,
              );
      case AudioBrowseKind.genre:
        final name = widget.genre ?? '';
        return name.isEmpty
            ? null
            : AudioPinRequest(
                type: 'genre',
                criteria: {'genre': name},
                name: name,
              );
      case AudioBrowseKind.folder:
        final id = widget.folderId;
        return id == null || id.isEmpty
            ? null
            : AudioPinRequest(
                type: 'folder',
                criteria: {'folder': id},
                name: widget.title,
              );
      case AudioBrowseKind.playlist:
        final id = widget.playlistId ?? '';
        return id.isEmpty
            ? null
            : AudioPinRequest(
                type: 'playlist',
                criteria: {'playlist': id},
                name: widget.title,
              );
      default:
        return null;
    }
  }

  Future<void> _addPin() async {
    final t = context.t;
    final req = _pinRequest();
    if (req == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(audioActionsProvider).addPin(req);
      messenger.showSnackBar(SnackBar(content: Text(t.asPinAdded)));
      ref.invalidate(audioPinsProvider);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.asPinAddFailed(describeAudioError(e)))),
      );
    }
  }
}
