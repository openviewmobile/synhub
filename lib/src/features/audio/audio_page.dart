// Audio Station 音乐库页（阶段二 A：Audio Station 普通用户功能）。
//
// 接口事实来源：`docs/stage2-audio-download-api.md` §2.1–§2.4：
//   * 歌曲 = `Song.list` v3（root `data.songs` + `data.total`）；
//   * 专辑 = `Album.list` v3 · 艺术家 = `Artist.list` v4 · 流派 = `Genre.list` v3；
//   * 文件夹 = `Folder.list` v3（root `data.items` + `data.folder_total`）；
//   * 播放列表 = `Playlist.list` v3（root `data.playlists`）。
//
// 页面结构对齐现有模块（见 `features/downloads/download_page.dart`）：
// 分类标签页 · 触底分页 · 下拉刷新 · 空态/错误态
// （**区分套件未安装 / 无权限 / 网络失败**）。
import 'package:flutter/material.dart';
import '../../core/ui/adaptive_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/user_facing_error.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../data/audio_station.dart';
import '../../data/dto/audio_station_dto.dart';
import 'audio_cover.dart';
import 'audio_detail_page.dart';
import 'audio_gaps_page.dart';
import 'audio_labels.dart';
import 'audio_mini_player.dart';
import 'audio_pins_page.dart';
import 'audio_providers.dart';
import 'audio_cast_page.dart';
import 'audio_equalizer.dart';
import 'audio_radio_page.dart';
import 'audio_remote_page.dart';
import 'audio_search_page.dart';
import 'audio_song_page.dart';
import 'audio_web_queue_page.dart';

/// 音乐库的标签页顺序。
///
/// wave2 追加 `composer`（`Composer:list` v1–v2 真机取证 → 与 Album/Artist/Genre
/// 同级的作曲家浏览页；正文/钻取本来就已经实现，此前只是没进标签栏）。
const List<AudioBrowseKind> kAudioTabKinds = [
  AudioBrowseKind.song,
  AudioBrowseKind.album,
  AudioBrowseKind.artist,
  AudioBrowseKind.composer,
  AudioBrowseKind.genre,
  AudioBrowseKind.folder,
  AudioBrowseKind.playlist,
];

class AudioPage extends ConsumerStatefulWidget {
  const AudioPage({super.key});

  @override
  ConsumerState<AudioPage> createState() => _AudioPageState();
}

class _AudioPageState extends ConsumerState<AudioPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: kAudioTabKinds.length,
    vsync: this,
  );

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // 网络电台（`AudioStation.Radio`）与**服务端播放队列**
    // （`AudioStation.WebPlayer`）的能力门控，同一套语义：
    //   * 能力表**没有**这个 API → 隐藏入口（缺失→隐藏，且不发探测）；
    //   * 还没连会话 / 能力表未知 → fail-open（照常显示，原因由正文状态给出）。
    final api = ref.watch(audioApiProvider);
    final showRadio = api == null || api.hasApi(AudioStationApi.apiRadio);
    final showWebQueue = api == null || api.hasApi(AudioStationApi.apiWebPlayer);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(t.asTitle),
        actions: adaptiveActions([
          IconButton(
            key: const Key('as-search'),
            tooltip: t.asSearchTitle,
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(builder: (_) => const AudioSearchPage()),
            ),
          ),
          // ★ r482：电台 / 播放队列 / 收藏 三个入口**收进 ⋮**。
          //
          // 用户原话是「菜单太多、顶栏太挤、常用动作被藏起来」——这两个抱怨
          // 看似相反，实际是同一件事：**顶栏只放"到处都要用"的**，其余进
          // 一个明确的「更多」。音乐库首页真正到处都用的是「搜索」与
          // 「切换音乐库」；电台/队列/收藏是偶尔去一次，收进 ⋮ 与
          // 「最近添加 / 随机100 / …」同一处 ⇒ 顶栏从 6 个图标降到 3 个。
          // 能力缺失（没有 `AudioStation.Radio` / `WebPlayer`）时**照旧不出现**。
          // A11：音乐库切换（个人 / 共享 / 默认）。官方前端
          // `Window.getBrowseLibraryType()`，选中后写入所有 `*.list` 的
          // `library=` 参数。
          // ★ 用 `String` 而不是 `AudioLibrary?` 做泛型：`PopupMenuItem` 的
          // `value == null` 会被 Flutter 当成"取消"，`onSelected` **不会**回调
          // （踩过一次）——"默认/全部"这一项必须有自己的非空值。
          PopupMenuButton<String>(
            key: const Key('as-library-switch'),
            tooltip: dataText('asLibrarySwitch', '音乐库'),
            icon: Icon(
              switch (ref.watch(audioLibraryProvider)) {
                AudioLibrary.shared => Icons.people_outline,
                AudioLibrary.personal => Icons.person_outline,
                null => Icons.library_music_outlined,
              },
            ),
            onSelected: (v) => ref
                .read(audioLibraryProvider.notifier)
                .select(switch (v) {
                  'shared' => AudioLibrary.shared,
                  'personal' => AudioLibrary.personal,
                  _ => null,
                }),
            itemBuilder: (_) => [
              PopupMenuItem(
                key: const Key('as-library-personal'),
                value: 'personal',
                child: Text(dataText('asLibraryPersonal', '个人音乐库')),
              ),
              PopupMenuItem(
                key: const Key('as-library-shared'),
                value: 'shared',
                child: Text(dataText('asLibraryShared', '共享音乐库')),
              ),
              PopupMenuItem(
                key: const Key('as-library-default'),
                value: 'default',
                child: Text(dataText('asLibraryAll', '全部（默认）')),
              ),
            ],
          ),
          // A7/A8/A10：官方首页常驻的预置列表（最近添加 / 随机 100 首 /
          // 最近播放 / 最常播放）。四项都从同一个「更多」入口进，避免顶栏
          // 再堆 4 个图标。
          // ★ r483：「更多」从 `PopupMenuButton`（11 项平铺）换成**分组底部弹层**。
          //
          // 用户抱怨的两件事其实是同一个判据：**入口该有层级**。
          // 11 项平铺的菜单等于把"菜单太多"原样搬到菜单里；弹层能用
          // 组标题把「媒体源 / 快捷列表 / 播放与投送」讲清楚，行还带图标，
          // 手指也好点（`PopupMenu` 行高 48，弹层行 56 且宽度整屏）。
          IconButton(
            key: const Key('as-home-menu'),
            tooltip: dataText('asMoreLists', '更多列表'),
            icon: const Icon(Icons.more_vert),
            onPressed: () => _openMoreSheet(
              context,
              ref,
              showRadio: showRadio,
              showWebQueue: showWebQueue,
            ),
          ),
        ]),
        bottom: _DesignTabBar(
          controller: _tabs,
          tabs: [
            for (final k in kAudioTabKinds)
              Tab(key: Key('as-tab-${k.name}'), text: asTabLabel(t, k)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [for (final k in kAudioTabKinds) _AudioTab(kind: k)],
      ),
      // ★★ r633（DA215 真机补修）：**音乐模块页也要有迷你条**。
      //
      // 上一版只挂在外壳（`app_shell_page`）底部，真机当场拍到反例：
      // 从「Workspace → Music」进来是一个**独立路由**（盖住外壳），
      // 播放中回到这个列表页时，屏幕底部**什么都没有**（截图
      // `docs/evidence-r633/device/24_music_list_no_mini.png`）——
      // 用户正是"一边听一边翻库"的场景，最难接受没有控制。
      bottomNavigationBar: const AudioMiniPlayer(),
    );
  }
}

/// 「更多」底部弹层：**分组**而不是平铺（r483）。
///
/// 三组：媒体源（电台/队列/收藏）、快捷列表（最近添加/随机100/最近/最常）、
/// 播放与投送（新建列表/均衡器/投送/远程播放器）。
///
/// ★ 键名与 r482 的菜单项**逐一相同**（`as-radio` / `as-home-*`）⇒ 用例只需
///   把"开菜单"改成"开弹层"，判据不用重写。
Future<void> _openMoreSheet(
  BuildContext context,
  WidgetRef ref, {
  required bool showRadio,
  required bool showWebQueue,
}) {
  final p = DesignPalette.of(context);
  void go(Widget page) {
    Navigator.of(context).pop();
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: p.bg,
    builder: (ctx) {
      final t = ctx.t;
      return SafeArea(
        child: ListView(
          key: const Key('as-more-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            DesignSectionHeader(dataText('asMoreSources', '媒体源')),
            if (showRadio)
              DesignRowTile(
                key: const Key('as-radio'),
                leading: const Icon(Icons.radio_outlined),
                title: Text(asRadioTitle),
                onTap: () => go(const AudioRadioPage()),
              ),
            if (showWebQueue)
              DesignRowTile(
                key: const Key('as-webqueue'),
                leading: const Icon(Icons.queue_music_outlined),
                title: Text(asWebQueueTitle),
                onTap: () => go(const AudioWebQueuePage()),
              ),
            DesignRowTile(
              key: const Key('as-pins'),
              leading: const Icon(Icons.favorite_border),
              title: Text(t.asPinsTitle),
              onTap: () => go(const AudioPinsPage()),
            ),
            DesignSectionHeader(dataText('asMoreLists', '更多列表')),
            DesignRowTile(
              key: const Key('as-home-recently-added'),
              leading: const Icon(Icons.new_releases_outlined),
              title: Text(dataText('asRecentlyAdded', '最近添加')),
              onTap: () => go(const AudioRecentlyAddedPage()),
            ),
            DesignRowTile(
              key: const Key('as-home-random-100'),
              leading: const Icon(Icons.casino_outlined),
              title: Text(dataText('asRandom100', '随机 100 首')),
              onTap: () => go(const AudioRandom100Page()),
            ),
            DesignRowTile(
              key: const Key('as-home-recently-played'),
              leading: const Icon(Icons.history),
              title: Text(dataText('asRecentlyPlayed', '最近播放')),
              onTap: () =>
                  go(const AudioPlayedPage(mode: AudioPlayedMode.recently)),
            ),
            DesignRowTile(
              key: const Key('as-home-most-played'),
              leading: const Icon(Icons.trending_up),
              title: Text(dataText('asMostPlayed', '最常播放')),
              onTap: () => go(const AudioPlayedPage(mode: AudioPlayedMode.most)),
            ),
            DesignSectionHeader(dataText('asMorePlayback', '播放与投送')),
            DesignRowTile(
              key: const Key('as-home-new-playlist'),
              leading: const Icon(Icons.playlist_add),
              title: Text(dataText('asNewPlaylist', '新建播放列表')),
              onTap: () {
                Navigator.of(context).pop();
                _createPlaylist(context, ref);
              },
            ),
            DesignRowTile(
              key: const Key('as-home-equalizer'),
              leading: const Icon(Icons.equalizer),
              title: Text(dataText('asEqualizer', '均衡器')),
              onTap: () => go(const AudioEqualizerPage()),
            ),
            DesignRowTile(
              key: const Key('as-home-cast'),
              leading: const Icon(Icons.cast),
              title: Text(dataText('asCastTitle', '投送到 Chromecast')),
              onTap: () => go(const AudioCastPage()),
            ),
            DesignRowTile(
              key: const Key('as-home-remote'),
              leading: const Icon(Icons.speaker_outlined),
              title: Text(dataText('asRemoteTitle', '远程播放器')),
              onTap: () => go(const AudioRemotePage()),
            ),
          ],
        ),
      );
    },
  );
}

/// 音乐库的分页条（设计稿口径：实色底、primary 指示条、13/600 选中）。
///
/// ★ 为什么包一层而不是直接给 `TabBar` 传样式：`TabBar` 默认吃 Material
/// 主题（HUD 那套玻璃底 + 亮青指示条），散着传 6 个颜色参数容易漏一个就
/// 变回老样子；包成组件只在这里取一次 [DesignPalette]。
class _DesignTabBar extends StatelessWidget implements PreferredSizeWidget {
  const _DesignTabBar({required this.controller, required this.tabs});

  final TabController controller;
  final List<Widget> tabs;

  /// 与 `TabBar` 默认值一致（分页条高度 46 + 指示条 2）。
  @override
  Size get preferredSize => const Size.fromHeight(kTextTabBarHeight + 2);

  @override
  Widget build(BuildContext context) {
    final p = DesignPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.phone,
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: TabBar(
        controller: controller,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        indicatorColor: p.primary,
        indicatorSize: TabBarIndicatorSize.label,
        indicatorWeight: 2,
        labelColor: p.text,
        unselectedLabelColor: p.muted,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        dividerColor: Colors.transparent,
        tabs: tabs,
      ),
    );
  }
}

/// 一个标签页 = 一个分页列表（各自持有 provider，切页不互相干扰）。
/// C6：新建播放列表（`Playlist/create`，参数逐字对齐官方 APK）。
///
/// 官方 `ApiEnumerator.doCreatePlaylist`：`{name, library, songs}`。
/// 新列表先建成**空表**（`songs` 空串）—— 官方"新建"也是先建空表再加曲。
Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
  final name = await _askPlaylistName(
    context,
    title: dataText('asNewPlaylist', '新建播放列表'),
  );
  if (name == null || name.trim().isEmpty) return;
  final api = ref.read(audioApiProvider);
  if (api == null) return;
  try {
    await api.createPlaylist(
      name: name.trim(),
      songIds: const [],
      // 建到**当前浏览的库**里；未选库时用官方默认（个人库）。
      library: ref.read(audioLibraryProvider),
    );
    ref.invalidate(
      audioPlaylistListProvider(
        playlistsQueryOf(ref.read(audioLibraryProvider)),
      ),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dataText('asPlaylistCreated', '已新建播放列表'))),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e))),
      );
    }
  }
}

/// C6：改名 / 删除的二次确认与输入框（同一套 UI，key 固定便于用例）。
Future<String?> _askPlaylistName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const Key('as-playlist-name-field'),
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(
          hintText: dataText('asPlaylistNameHint', '名称'),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('as-playlist-name-cancel'),
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(dataText('cancel', '取消')),
        ),
        TextButton(
          key: const Key('as-playlist-name-ok'),
          onPressed: () => Navigator.of(ctx).pop(ctrl.text),
          child: Text(dataText('ok', '确定')),
        ),
      ],
    ),
  );
}

class _AudioTab extends ConsumerStatefulWidget {
  const _AudioTab({required this.kind});

  final AudioBrowseKind kind;

  @override
  ConsumerState<_AudioTab> createState() => _AudioTabState();
}

class _AudioTabState extends ConsumerState<_AudioTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// A12：专辑 / 艺术家标签页的首字母过滤（null = 全部）。
  ///
  /// 官方用 `filter=<字母>`（`ApiEnumerator.java:325,334`）；真机
  /// `Artist.list{filter:A}` → 627、`Album.list{filter:A}` → 940（本批复验）。
  String? _letter;

  /// A14：歌曲标签页的多选集合（空集 = 非多选态）。
  final Set<String> _selected = {};

  /// A11：当前音乐库（`personal` / `shared` / null=默认）。
  AudioLibrary? get _library => ref.watch(audioLibraryProvider);

  SongQuery get _songsQuery => songsQueryOf(_library);

  FolderQuery get _foldersQuery => foldersQueryOf(_library);

  PlaylistQuery get _playlistsQuery => playlistsQueryOf(_library);

  /// A12：专辑查询（带首字母）。
  AlbumQuery _albumQueryOf(AudioLibrary? lib) => (
    artist: null,
    composer: null,
    genre: null,
    search: null,
    filter: _letter,
    library: lib,
  );

  AlbumQuery get _albumQuery => _albumQueryOf(_library);

  /// C6：改名（`Playlist/rename` + `{id, new_name}`）。
  Future<void> _renamePlaylist(
    BuildContext context,
    WidgetRef ref,
    AudioPlaylistDto p,
  ) async {
    final name = await _askPlaylistName(
      context,
      title: dataText('rename', '重命名'),
      initial: p.name,
    );
    if (name == null || name.trim().isEmpty) return;
    final api = ref.read(audioApiProvider);
    if (api == null) return;
    try {
      if (p.isSmart) {
        // ★ 官方 Android 端只能**改名**智能列表：必须先把原规则取回来，
        // 再原样回传 `updatesmart`（`conj_rule` + `rules_json`），否则规则丢。
        // 出处：反编译 `PlaylistEditor.doRenameSmartPlaylist` / `getSmartPlaylistRules`。
        final rules = await api.getPlaylistRules(id: p.id, library: _library);
        if (rules == null) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  dataText('asSmartRulesMissing', '智能列表规则获取失败，未改名'),
                ),
              ),
            );
          }
          return;
        }
        await api.updateSmartPlaylist(
          id: p.id,
          newName: name.trim(),
          conjunction: rules.conjunction,
          rules: rules.rules,
          library: _library,
        );
      } else {
        await api.renamePlaylist(p.id, name.trim());
      }
      ref.invalidate(audioPlaylistListProvider(_playlistsQuery));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(userFacingError(e))),
        );
      }
    }
  }

  /// C6：删除（`Playlist/delete` + `{id}`）。
  Future<void> _deletePlaylist(
    BuildContext context,
    WidgetRef ref,
    AudioPlaylistDto p,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(dataText('asPlaylistDeleteTitle', '删除播放列表')),
        content: Text(
          dataText(
            'asPlaylistDeleteBody',
            '确定删除「{name}」？',
          ).replaceAll('{name}', p.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(dataText('cancel', '取消')),
          ),
          TextButton(
            key: const Key('as-playlist-delete-ok'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(dataText('delete', '删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final api = ref.read(audioApiProvider);
    if (api == null) return;
    try {
      await api.deletePlaylist(p.id);
      ref.invalidate(audioPlaylistListProvider(_playlistsQuery));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(userFacingError(e))),
        );
      }
    }
  }

  /// A12：名字型查询（带首字母）。
  NamedQuery _namedQ(AudioBrowseKind kind) =>
      namedQuery(kind, filter: _letter, library: _library);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  /// 本标签页对应的分页控制器（各分类的 provider 类型不同，这里按分类分派）。
  Future<void> _load({bool silent = false}) async {
    switch (widget.kind) {
      case AudioBrowseKind.song:
        await ref
            .read(audioSongListProvider(_songsQuery).notifier)
            .load(silent: silent);
      case AudioBrowseKind.album:
        await ref
            .read(audioAlbumListProvider(_albumQuery).notifier)
            .load(silent: silent);
      case AudioBrowseKind.artist || AudioBrowseKind.composer:
        await ref
            .read(audioNamedListProvider(_namedQ(widget.kind)).notifier)
            .load(silent: silent);
      case AudioBrowseKind.genre:
        await ref
            .read(audioNamedListProvider(_namedQ(widget.kind)).notifier)
            .load(silent: silent);
      case AudioBrowseKind.folder:
        await ref
            .read(audioFolderListProvider(_foldersQuery).notifier)
            .load(silent: silent);
      case AudioBrowseKind.playlist:
        await ref
            .read(audioPlaylistListProvider(_playlistsQuery).notifier)
            .load(silent: silent);
    }
  }

  Future<void> _loadMore() async {
    switch (widget.kind) {
      case AudioBrowseKind.song:
        await ref
            .read(audioSongListProvider(_songsQuery).notifier)
            .loadMore();
      case AudioBrowseKind.album:
        await ref
            .read(audioAlbumListProvider(_albumQuery).notifier)
            .loadMore();
      case AudioBrowseKind.artist ||
          AudioBrowseKind.composer ||
          AudioBrowseKind.genre:
        await ref
            .read(audioNamedListProvider(_namedQ(widget.kind)).notifier)
            .loadMore();
      case AudioBrowseKind.folder:
        await ref
            .read(audioFolderListProvider(_foldersQuery).notifier)
            .loadMore();
      case AudioBrowseKind.playlist:
        await ref
            .read(audioPlaylistListProvider(_playlistsQuery).notifier)
            .loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = context.t;
    final kind = widget.kind;
    // A11：换库（个人/共享/默认）后**重新拉第一页** —— 查询换了 family key
    // 会拿到新的控制器，但 `onLoad` 只在 `AudioPagedBody` 初始化时触发一次，
    // 所以必须显式再 load；同时清掉首字母过滤与多选（换库后无意义）。
    ref.listen(audioLibraryProvider, (prev, next) {
      if (prev == next) return;
      _letter = null;
      _selected.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    });
    switch (kind) {
      case AudioBrowseKind.song:
        final s = ref.watch(audioSongListProvider(_songsQuery));
        final body = AudioPagedBody<AudioSongDto>(
          kind: kind,
          state: s,
          onLoad: _load,
          onLoadMore: _loadMore,
          onRefresh: () => _load(silent: true),
          itemBuilder: (context, song) => AudioSongTile(
            key: Key('as-song-${song.id}'),
            song: song,
            selected: _selected.contains(song.id),
            onTap: _selected.isEmpty
                ? () => _openSong(
                      context,
                      song,
                      // 队列 = 当前这一页（多选态下不触发）
                      queue: s.items,
                      index: s.items.indexWhere((e) => e.id == song.id),
                      autoPlay: true,
                    )
                : () => _toggleSelected(song.id),
            // A14：长按进入多选态（官方 APK adapter 层的多选同语义）。
            onLongPress: () => _toggleSelected(song.id),
          ),
        );
        // A14：多选态下的批量操作条（批量评分 —— `Song.setrating` v2 的
        // `id` 官方就是**逗号串**，一次最多 50 首）。
        if (_selected.isEmpty) return body;
        return Column(
          children: [
            Expanded(child: body),
            _SongSelectionBar(
              count: _selected.length,
              onCancel: () => setState(_selected.clear),
              onRate: _rateSelected,
            ),
          ],
        );
      case AudioBrowseKind.album:
        final s = ref.watch(audioAlbumListProvider(_albumQuery));
        final body = AudioPagedBody<AudioAlbumDto>(
          kind: kind,
          state: s,
          onLoad: _load,
          onLoadMore: _loadMore,
          onRefresh: () => _load(silent: true),
          itemBuilder: (context, album) => DesignRowTile(
            key: Key('as-album-${album.name}'),
            // 专辑封面（`Cover.getcover` v3）—— 接线：此前零 UI 入口（审计 §4.2）
            leading: AudioCoverImage(
              key: Key('as-album-cover-${album.name}'),
              identity: album.name,
              url: ref
                  .read(audioApiProvider)
                  ?.albumCoverUrl(
                    album.name,
                    albumArtist: album.albumArtist,
                  ),
              // r439：专辑级没有真封面时，逐首探 `getsongcover`（最多 1 首）
              resolveFallback: albumCoverFallbackOf(
                ref.watch(albumCoverResolverProvider),
                album,
              ),
              fallbackIcon: Icons.album_outlined,
            ),
            title: Text(
              asDisplayName(album.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: _meta(context, asAlbumMetaLine(album)),
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
        // A12：专辑页顶部首字母索引条（`filter=<字母>`）。
        return Column(
          children: [
            _AlphabetBar(
              tab: 'album',
              selected: _letter,
              onSelect: _selectLetter,
            ),
            Expanded(child: body),
          ],
        );
      case AudioBrowseKind.artist:
      case AudioBrowseKind.composer:
      case AudioBrowseKind.genre:
        final s = ref.watch(audioNamedListProvider(_namedQ(kind)));
        final body = AudioPagedBody<AudioNameDto>(
          kind: kind,
          state: s,
          onLoad: _load,
          onLoadMore: _loadMore,
          onRefresh: () => _load(silent: true),
          itemBuilder: (context, name) => DesignRowTile(
            key: Key('as-${kind.name}-${name.name}'),
            // 艺术家 / 流派 / 作曲家封面（`Cover.getcover` v3）—— 接线：此前零 UI 入口。
            leading: AudioCoverImage(
              key: Key('as-${kind.name}-cover-${name.name}'),
              identity: '${kind.name}:${name.name}',
              url: switch (kind) {
                AudioBrowseKind.genre => ref
                    .read(audioApiProvider)
                    ?.genreCoverUrl(name.name),
                AudioBrowseKind.artist => ref
                    .read(audioApiProvider)
                    ?.artistCoverUrl(name.name),
                // 官方 `getCgiImgMapping` 的 `case"composer"` → `composer_name`
                // （wave2 接线：此前误以为"作曲家没有 Cover 维度键"而回落图标）。
                AudioBrowseKind.composer => ref
                    .read(audioApiProvider)
                    ?.composerCoverUrl(name.name),
                _ => null,
              },
              fallbackIcon: switch (kind) {
                AudioBrowseKind.genre => Icons.category_outlined,
                AudioBrowseKind.composer => Icons.piano_outlined,
                _ => Icons.person_outline,
              },
            ),
            // ★ r486（DA126）：**服务端会下发空名字**（真机上艺术家分页第一条就是
            // 空行：只有图标和箭头，看不见可点的东西）。空名必须有占位文案。
            title: Text(
              asDisplayName(name.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: _meta(context, asNameMetaLine(name)),
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => switch (kind) {
                  AudioBrowseKind.genre => AudioDetailPage.genre(
                    name: name.name,
                  ),
                  AudioBrowseKind.composer => AudioDetailPage.composer(
                    name: name.name,
                  ),
                  _ => AudioDetailPage.artist(name: name.name),
                },
              ),
            ),
          ),
        );
        // 流派页顶部加"建议的流派"（`Genre.list_default_genre` v3）——
        // **接线**：此前该方法只有测试引用（审计 §4.2 死代码第 7 条）。
        // A12：艺术家页顶部再加首字母索引条（官方 `filter` 只对 Album/Artist）。
        if (kind == AudioBrowseKind.artist) {
          return Column(
            children: [
              _AlphabetBar(
                tab: 'artist',
                selected: _letter,
                onSelect: _selectLetter,
              ),
              Expanded(child: body),
            ],
          );
        }
        if (kind != AudioBrowseKind.genre) return body;
        return Column(
          children: [
            const _DefaultGenresStrip(),
            Expanded(child: body),
          ],
        );
      case AudioBrowseKind.folder:
        final s = ref.watch(audioFolderListProvider(_foldersQuery));
        return AudioPagedBody<AudioFolderItemDto>(
          kind: kind,
          state: s,
          onLoad: _load,
          onLoadMore: _loadMore,
          onRefresh: () => _load(silent: true),
          itemBuilder: (context, item) => _FolderTile(
            key: Key('as-folder-${item.id}'),
            item: item,
            // 文件夹封面（`Cover.getfoldercover` v3）—— 接线：此前零 UI 入口
            coverUrl: ref.read(audioApiProvider)?.folderCoverUrl(item.id),
          ),
        );
      case AudioBrowseKind.playlist:
        final s = ref.watch(audioPlaylistListProvider(_playlistsQuery));
        return AudioPagedBody<AudioPlaylistDto>(
          kind: kind,
          state: s,
          onLoad: _load,
          onLoadMore: _loadMore,
          onRefresh: () => _load(silent: true),
          itemBuilder: (context, p) => DesignRowTile(
            key: Key('as-playlist-${p.id}'),
            leading: const Icon(Icons.queue_music_outlined),
            title: Text(
              asDisplayName(p.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: _meta(context, asPlaylistBadge(t, p)),
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    AudioDetailPage.playlist(id: p.id, name: p.name),
              ),
            ),
            // C6：改名 / 删除（`Playlist/rename`、`Playlist/delete`）
            trailing: PopupMenuButton<String>(
              key: Key('as-playlist-menu-${p.id}'),
              onSelected: (v) => v == 'rename'
                  ? _renamePlaylist(context, ref, p)
                  : _deletePlaylist(context, ref, p),
              itemBuilder: (_) => [
                PopupMenuItem(
                  key: Key('as-playlist-rename-${p.id}'),
                  value: 'rename',
                  child: Text(dataText('rename', '重命名')),
                ),
                PopupMenuItem(
                  key: Key('as-playlist-delete-${p.id}'),
                  value: 'delete',
                  child: Text(dataText('delete', '删除')),
                ),
              ],
            ),
          ),
        );
    }
  }

  /// ★ r642（`DA236`）：列表点歌 = **带队列 + 立刻起播**。
  ///
  /// 修前只带 `songId`：进了详情页停在 `0:00`（还要再按一次播放），
  /// 上一首/下一首也是灰的（真机 dump `Previous enabled=false`）。
  void _openSong(
    BuildContext context,
    AudioSongDto song, {
    List<AudioSongDto> queue = const [],
    int index = 0,
    bool autoPlay = false,
  }) {
    final title = song.title.isNotEmpty ? song.title : song.path;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => AudioSongDetailPage(
          songId: song.id,
          title: title,
          queue: queue,
          queueIndex: index,
          autoPlay: autoPlay,
        ),
      ),
    );
  }

  /// A12：切换首字母过滤并重新拉第一页。
  Future<void> _selectLetter(String? letter) async {
    if (_letter == letter) return;
    setState(() => _letter = letter);
    await _load();
  }

  /// A14：进入 / 退出某一首的多选。
  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  /// A14：给选中的曲目批量评分（`Song.setrating` v2，`id` 是逗号串）。
  Future<void> _rateSelected(int rating) async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(audioActionsProvider).setRating(ids, rating);
      if (!mounted) return;
      setState(_selected.clear);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText('asBatchRatingSet', '已为 {count} 首设置评分').replaceAll(
              '{count}',
              '${ids.length}',
            ),
          ),
        ),
      );
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText('asRatingFailed', '设置评分失败：{e}').replaceAll(
              '{e}',
              describeAudioError(e),
            ),
          ),
        ),
      );
    }
  }

  /// 次要行：空串就不占位（`ListTile.subtitle` 给 null 时不显示）。
  Widget? _meta(BuildContext context, String text) {
    if (text.isEmpty) return null;
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: DesignType.labelSmallSize,
        color: DesignPalette.of(context).dim,
        letterSpacing: 0.2,
      ),
    );
  }
}

/// A12：首字母索引条（`filter=<字母>`）。
///
/// 官方用 `filter`（不是 `search`）—— 真机 `Artist.list{filter:A}` → 627、
/// `Album.list{filter:A}` → 940。这里 26 个字母横排，选中项高亮；再点一次
/// 选中项 = 取消过滤（回到全部）。
class _AlphabetBar extends StatelessWidget {
  const _AlphabetBar({
    required this.tab,
    required this.selected,
    required this.onSelect,
  });

  /// `album` / `artist`（只用于给每个字母 key 加前缀，避免两个标签页重复 key）。
  final String tab;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return SizedBox(
      height: 40,
      child: ListView(
        key: Key('as-alpha-$tab'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: Gap.xs),
            child: ChoiceChip(
              key: Key('as-alpha-$tab-all'),
              label: Text(dataText('asAlphaAll', '全部')),
              selected: selected == null,
              onSelected: (_) => onSelect(null),
            ),
          ),
          for (final letter in _kAlphabet)
            Padding(
              padding: const EdgeInsets.only(right: Gap.xs),
              child: ChoiceChip(
                key: Key('as-alpha-$tab-$letter'),
                label: TelemetryLabel(
                  letter,
                  size: 12,
                  color: selected == letter ? hud.accent : hud.dim,
                ),
                selected: selected == letter,
                onSelected: (_) =>
                    onSelect(selected == letter ? null : letter),
              ),
            ),
        ],
      ),
    );
  }
}

const List<String> _kAlphabet = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', //
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
];

/// A14：多选态下的批量操作条。
class _SongSelectionBar extends StatelessWidget {
  const _SongSelectionBar({
    required this.count,
    required this.onCancel,
    required this.onRate,
  });

  final int count;
  final VoidCallback onCancel;
  final ValueChanged<int> onRate;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Material(
      key: const Key('as-selection-bar'),
      color: Theme.of(context).colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
          child: Row(
            children: [
              IconButton(
                key: const Key('as-selection-cancel'),
                tooltip: dataText('asSelectionCancel', '退出多选'),
                icon: const Icon(Icons.close),
                onPressed: onCancel,
              ),
              TelemetryLabel(
                dataText('asSelectionCount', '已选 {count} 首').replaceAll(
                  '{count}',
                  '$count',
                ),
                size: 12,
                color: hud.dim,
              ),
              const Spacer(),
              // 批量评分：`Song.setrating` v2 的 id 官方就是逗号串，一次一首
              // 也不亏；这里给 1–5 星 + 清除。
              for (var star = 1; star <= 5; star++)
                IconButton(
                  key: Key('as-selection-star-$star'),
                  tooltip: '$star',
                  icon: const Icon(Icons.star_border, size: 20),
                  onPressed: () => onRate(star),
                ),
              IconButton(
                key: const Key('as-selection-clear-rating'),
                tooltip: dataText('asRatingClear', '清除评分'),
                icon: const Icon(Icons.star_outline, size: 20),
                onPressed: () => onRate(0),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "建议的流派"横向带（`Genre.list_default_genre` **v3**）。
///
/// **接线**：`AudioStationApi.listDefaultGenres` 此前只有测试引用
/// （审计 §4.2 死代码第 7 条）。官方把它当首页"默认类型"入口；这里放在
/// 流派标签页顶部。拿不到就整条隐藏（不影响流派列表本身）。
class _DefaultGenresStrip extends ConsumerWidget {
  const _DefaultGenresStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final genres = ref.watch(audioDefaultGenresProvider).value ?? const [];
    if (genres.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView(
        key: const Key('as-default-genres'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        children: [
          for (final g in genres)
            Padding(
              padding: const EdgeInsets.only(right: Gap.xs),
              child: ActionChip(
                key: Key('as-default-genre-${g.name}'),
                label: Text(g.name),
                onPressed: () =>
                    Navigator.of(context, rootNavigator: true).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AudioDetailPage.genre(name: g.name),
                      ),
                    ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 文件夹条目（目录 → 再钻一层；文件 → 单曲页）。
class _FolderTile extends StatelessWidget {
  const _FolderTile({super.key, required this.item, this.coverUrl});

  final AudioFolderItemDto item;

  /// 目录封面 URL（`Cover.getfoldercover` v3）；没有就回落图标。
  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    return DesignRowTile(
      leading: AudioCoverImage(
        key: Key('as-folder-cover-${item.id}'),
        identity: item.id,
        url: coverUrl,
        fallbackIcon: item.isFolder
            ? Icons.folder_outlined
            : Icons.music_note_outlined,
      ),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: item.path.isEmpty
          ? null
          : TelemetryLabel(
              item.path,
              size: 11,
              color: DesignPalette.of(context).dim,
              letterSpacing: 0.2,
            ),
      onTap: item.id.isEmpty && item.path.isEmpty
          ? null
          : () => item.isFolder
                ? Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AudioDetailPage.folder(
                        id: item.id.isEmpty ? null : item.id,
                        path: item.path.isEmpty ? null : item.path,
                        name: item.title,
                      ),
                    ),
                  )
                : Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AudioSongDetailPage(
                        songId: item.id,
                        title: item.title,
                      ),
                    ),
                  ),
    );
  }
}

/// 分页列表的**通用壳**：空态/错误态区分套件未安装 / 无权限 / 网络失败。
class AudioPagedBody<T> extends StatelessWidget {
  const AudioPagedBody({
    super.key,
    required this.kind,
    required this.state,
    required this.itemBuilder,
    required this.onLoad,
    required this.onLoadMore,
    required this.onRefresh,
    this.emptyTitle,
    this.errorTitle,
  });

  final AudioBrowseKind? kind;
  final AudioPagedState<T> state;
  final Widget Function(BuildContext, T) itemBuilder;
  final Future<void> Function() onLoad;
  final Future<void> Function() onLoadMore;
  final Future<void> Function() onRefresh;
  final String? emptyTitle;

  /// 失败态标题（默认「音乐库加载失败」；搜索页传「搜索失败」）。
  final String? errorTitle;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // 1) 还没连接会话
    if (state.apiMissing) {
      return AppEmptyState(
        icon: Icons.cloud_off,
        title: t.setNotConnected,
        message: t.asNotInstalledHint,
      );
    }
    // 2) 套件未安装：给结论，不给"重试"（重试也装不上）
    if (state.failure == AsFailureKind.notInstalled) {
      return AppEmptyState(
        key: const Key('as-not-installed'),
        icon: Icons.extension_off_outlined,
        title: t.asErrNotInstalled,
        message: t.asNotInstalledHint,
      );
    }
    // 3) 无权限
    if (state.failure == AsFailureKind.noPrivilege && state.items.isEmpty) {
      return AppEmptyState(
        key: const Key('as-no-privilege'),
        icon: Icons.lock_outline,
        title: t.asErrNoPrivilege,
        message: t.asNoPrivilegeHint,
      );
    }
    // 4) 首次加载
    if (state.loading && !state.loaded) return const AppListSkeleton();
    // 5) 失败（网络/其它）
    if (state.failure != null && state.items.isEmpty) {
      final network =
          state.failure == AsFailureKind.network ||
          state.failure == AsFailureKind.sessionExpired;
      return AppErrorView(
        icon: network ? Icons.wifi_off : Icons.error_outline,
        title: errorTitle ?? t.asLoadFailed,
        detail: state.errorText,
        onRetry: () => onLoad(),
      );
    }
    // 6) 空态
    if (state.items.isEmpty) {
      final fallback = kind == null ? '' : asEmptyLabel(t, kind!);
      return AppEmptyState(
        icon: Icons.library_music_outlined,
        title: emptyTitle ?? fallback,
      );
    }
    // 7) 列表
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
            onLoadMore();
          }
          return false;
        },
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xxl * 2),
          itemCount: state.items.length + (state.loadingMore ? 1 : 0),
          separatorBuilder: (_, _) => Divider(
            height: 1,
            color: DesignPalette.of(context).dim.withValues(alpha: 0.12),
          ),
          itemBuilder: (context, i) {
            if (i >= state.items.length) {
              return const Padding(
                padding: EdgeInsets.all(Gap.lg),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return itemBuilder(context, state.items[i]);
          },
        ),
      ),
    );
  }
}

/// 单曲行（音乐库 / 详情页共用）。
///
/// ★ r638（**DA230**）：`ConsumerWidget` + [SongRowCover] —— 列表行终于有封面。
/// 以前每行都是同一个音符图标，同一张专辑的十首歌长得完全一样
/// （真机像素对比：`docs/evidence-r638/01..02`）。封面本身**不新造逻辑**，
/// 走专辑行那条已过真机的两级路（r439 / `DA93`）。
class AudioSongTile extends ConsumerWidget {
  const AudioSongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.trailing,
    this.onLongPress,
    this.selected = false,
    this.titleOverride,
  });

  final AudioSongDto song;
  final VoidCallback onTap;
  final Widget? trailing;

  /// A14：长按进入多选（null = 不支持多选）。
  final VoidCallback? onLongPress;

  /// A14：是否处于选中态。
  final bool selected;

  /// 显示用标题（`DA127`：标题是乱码时由调用方换成文件名）。
  final String? titleOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // r631：列表行只留**给人看**的时长（技术参数收进「歌曲信息」面板）。
    // 旧行为是 `3:51 · 320 kbps · 44.1 kHz`（DA120 起已不画体积），
    // 但比特率/采样率对"挑歌"没有用处，且真机上常被省略号切一半。
    final meta = asSongHumanMetaLine(song);
    return DesignRowTile(
      selected: selected,
      leading: selected
          ? const Icon(Icons.check_circle)
          : SongRowCover(song: song),
      title: Text(
        titleOverride ??
            (song.title.isNotEmpty ? song.title : song.path),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (song.subtitle.isNotEmpty)
            Text(
              song.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (meta.isNotEmpty)
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: DesignType.labelSmallSize,
                letterSpacing: 0.2,
                color: DesignPalette.of(context).dim,
              ),
            ),
        ],
      ),
      trailing: trailing,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
