// Audio Station 单曲页（阶段二 A：Audio Station 普通用户功能）。
//
// 接口事实来源：`docs/stage2-audio-download-api.md`：
//   * 单曲元数据 = `Song.getinfo` v3（+ `additional="song_tag,song_audio,song_rating"`）；
//   * 歌词 = `Lyrics.getlyrics` v2（**POST** `lyrics.cgi`，回包取 `data.lyrics`，
//     逐字来自官方 `audio-core.js` 的 `requestLyricsId`）；
//   * 联网搜歌词 = `LyricsSearch.searchlyrics` v2（`{title, artist, limit:1,
//     additional:"full_lyrics"}`，官方 `searchLyrics` 逐字）；
//   * 评分/收藏 = `Song.setrating` **v2**（`id` 是**逗号串**，`rating` 0–5）；
//   * 流式 URL 见 `AudioStationApi.streamUrl`（doc §2.3 A-1b，`stream.cgi/0.<ext>`）。
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/net/device_traffic.dart';
import '../../core/net/traffic_meter.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/audio_station.dart';
import '../../data/dto/audio_station_dto.dart';
import '../../data/media/media_format_support.dart';
import '../../core/user_facing_error.dart';
import '../files/file_providers.dart' show fileApiProvider;
import '../files/file_thumb.dart' show looksLikeImage;
import '../media/audio_handler.dart';
import '../media/authed_image.dart';
import '../media/audio_lyrics.dart';
import '../media/audio_lyrics_view.dart';
import '../media/media_cover_provider.dart';
import '../media/media_cover_view.dart';
import '../media/media_playback_store.dart';
import '../media/media_player.dart' show classifyPlayerError;
import '../media/media_reason_text.dart';
import '../media/media_source.dart' show MediaKind, MediaUnavailableReason;
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../shell/capability_hint.dart';
import 'audio_cast_page.dart';
import 'audio_album_cover.dart';
import 'audio_cover.dart';
import 'audio_equalizer.dart';
import 'audio_labels.dart';
import 'audio_offline_store.dart';
import 'audio_player.dart';
import '../files/file_browse_page.dart';
import 'audio_providers.dart';
import 'audio_queue_memory.dart';

class AudioSongDetailPage extends ConsumerStatefulWidget {
  const AudioSongDetailPage({
    super.key,
    required this.songId,
    required this.title,
    this.queue = const [],
    this.queueIndex = 0,
    this.autoPlay = false,
  });

  final String songId;
  final String title;

  /// ★★★ r642（`DA236`）：**从列表里点一首歌，就该立刻响**。
  ///
  /// 修前：列表点歌只 push 详情页，停在 `0:00` 等用户再按一次播放，而且
  /// **不带队列** ⇒ 上一首/下一首是灰的（真机 dump `Previous enabled=false`）。
  /// 用户的心智模型是"点歌 = 播这首歌，然后可以往下听"，所以由**列表入口**
  /// 显式传 `true`；迷你条/搜索结果之外的老入口一律保持原来的暂停语义。
  ///
  /// 只触发一次（见 `_StreamSectionState._autoPlayTried`），用户按暂停不会被它抢回。
  final bool autoPlay;

  /// 打开这一页时所在的播放队列（没有就退化成单曲）。
  ///
  /// P0-2：上一首/下一首 · 随机 · 单曲循环 · 循环全部 · 播完自动下一首
  /// 都作用在这个队列上；队列上限由 `Info.getinfo.playing_queue_max` 决定。
  final List<AudioSongDto> queue;
  final int queueIndex;

  @override
  ConsumerState<AudioSongDetailPage> createState() =>
      _AudioSongDetailPageState();
}

class _AudioSongDetailPageState extends ConsumerState<AudioSongDetailPage> {
  /// ★ r631：**页面级**的流地址缓存（原来在 `_StreamSection` 里）。
  ///
  /// 为什么必须提到页面级：技术信息面板也要显示**同一条** URL。
  /// URL 里的 `_dc` 是生成时刻的时间戳 —— 两处各拼一次就会得到两个不同的串，
  /// 面板上写的和播放器里放的就不是同一条（真机用例当场抓到 `_dc` 差 21 ms）。
  /// 联网搜回来的歌词（null = 还没搜过/没搜到）。
  String? _onlineLyrics;
  bool _searchingLyrics = false;

  /// ★ r644（**DA241**）：`_onlineLyrics` / `_searchingLyrics` 是**某一首歌**的
  /// 搜索结果 —— 换歌必须作废，否则新歌的面板会吃到上一首"联网搜到的歌词"
  ///（`_displayed()` 里服务端那份会兜底显示 ⇒ 屏上出现别人的歌词）。
  /// 记下它们是**为哪一首歌**搜的，`_setQueueIndex()` 与 build 都按这份记号清。
  String? _onlineLyricsFor;

  /// 切歌的唯一入口：**先作废旧歌的搜索结果**，再改下标。
  ///
  /// 为什么不能只靠 `didUpdateWidget`：上一首/下一首是**内部字段**变化
  /// （`widget` 根本没换）⇒ `didUpdateWidget` 不会触发。
  void _setQueueIndex(int i) {
    setState(() {
      _queueIndex = i;
      _onlineLyrics = null;
      _searchingLyrics = false;
      _onlineLyricsFor = _songId;
    });
  }

  /// 播放队列里的当前位置（队列为空时固定 0）。
  late int _queueIndex = widget.queue.isEmpty
      ? 0
      : widget.queueIndex.clamp(0, widget.queue.length - 1);

  /// 从持久化快照**按 id 回填**出来的队列（null = 这次用调用方带的 `widget.queue`）。
  List<AudioSongDto>? _restoredQueue;

  /// 本次真正生效的队列（持久化恢复优先于"这次打开时带的列表"，
  /// 但恢复只在没带列表、且快照与本次打开的歌相关时发生，见 [_restoreQueueMemory]）。
  List<AudioSongDto> get _effectiveQueue => _restoredQueue ?? widget.queue;

  /// 当前展示/播放的歌曲 id —— 队列推进（自动下一首 / 点上一首下一首）时跟着变。
  String get _songId =>
      _effectiveQueue.isEmpty ? widget.songId : _effectiveQueue[_queueIndex].id;

  /// 当前展示的标题（队列推进时跟着变）。
  String get _songTitle {
    if (_effectiveQueue.isEmpty) return widget.title;
    final song = _effectiveQueue[_queueIndex];
    return song.title.isNotEmpty ? song.title : song.path;
  }

  final Map<String, String> _urlCache = {};

  /// 同一条 URL 的**唯一**生成点（播放、队列、信息面板都走它）。
  String _urlOf(
    AudioStationApi api,
    AudioSongDto song,
    AudioInfoDto? info,
    int bitrate,
  ) {
    final mode = AudioStationApi.defaultStreamMode(song, info: info);
    final key = '${api.sid}|${song.id}|${song.path}|${mode.name}|$bitrate';
    return _urlCache.putIfAbsent(
      key,
      () => api.streamUrl(song, mode: mode, bitrate: bitrate),
    );
  }

  @override
  void initState() {
    super.initState();
    // 页面曝光（Audio Station 单曲页）——稳定页面 id，不记歌名
    trackView(UsageModule.audio, screen: 'player');
    // 重启后恢复上次的 AS 播放队列（失败/无关/没存过都静默，不挡这一页）
    unawaited(_restoreQueueMemory());
  }

  /// 用持久化的快照按 id 回填 AS 播放队列。
  ///
  /// 取三条"不抢用户选择"的纪律：
  ///   * 这次**带了显式队列**（专辑/文件夹点进来）→ 不恢复；
  ///   * 快照里**没有**这次打开的这一首 → 不恢复（用户在听别的歌）；
  ///   * 回填失败（歌被删 / 无权限 / 离线）→ 跳过那一首并**告知**，
  ///     队列其余部分照常恢复；全军覆没也不清空已存快照。
  Future<void> _restoreQueueMemory() async {
    if (widget.queue.isNotEmpty) return;
    final snap = await ref.read(mediaPlaybackStoreProvider).loadAudioQueue();
    if (!mounted || snap == null || snap.items.isEmpty) return;
    if (!snap.items.any((e) => e.id == widget.songId)) return;
    final api = ref.read(audioApiProvider);
    if (api == null || !api.installed) return;
    final restored = await restoreAudioQueue(
      snapshot: snap,
      fetch: api.getSong,
      preferId: widget.songId,
    );
    if (!mounted) return;
    if (restored.songs.isNotEmpty) {
      setState(() {
        _restoredQueue = restored.songs;
        _queueIndex = restored.index;
        _onlineLyricsFor = _songId;
      });
    }
    if (restored.skipped.isNotEmpty) _notifyQueueSkipped(restored.skipped);
  }

  /// 告知"有几首在恢复时被跳过"（歌被删 / 无权限）——不静默、也不清空队列。
  void _notifyQueueSkipped(List<String> skipped) {
    if (!mounted || skipped.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          dataText(
            'asQueueRestoreSkipped',
            '播放队列里有 {count} 首已不可用（被删除或无权限），已跳过',
          ).replaceAll('{count}', '${skipped.length}'),
        ),
      ),
    );
  }

  /// 顶栏「播放队列」入口：有队列时带数量徽标（纯覆盖层 `Badge`，不占宽度）。
  ///
  /// 与文件页「下载任务」入口同性质（`file_browse_page.dart` 的
  /// `_DownloadTasksButton`）：徽标只显示**数量**，点开才是队列本身。
  /// 这里队列是页面自身状态，`setState` 会重建入口，不需要 `ListenableBuilder`。
  Widget _queueEntryAction() {
    final icon = IconButton(
      key: const Key('as-queue-entry'),
      tooltip: _effectiveQueue.isEmpty
          ? dataText('asQueueEntry', '播放队列')
          : dataText(
              'asQueueEntryActive',
              '播放队列 · {count} 首',
            ).replaceAll('{count}', '${_effectiveQueue.length}'),
      icon: const Icon(Icons.playlist_play),
      onPressed: _openQueueSheet,
    );
    if (_effectiveQueue.isEmpty) return icon;
    // ★ r524（DA167，真机亮色像素）：`Badge` 默认贴 child 的右上角，而
    // `AppBar` 的 action 自带 8dp 内边距 ⇒ 徽标被推到**屏幕右边缘之外**
    // 还要更高一截，真机上像一颗悬在状态栏附近的红点（不在图标角上）。
    // 往里收 6、往下压 6，落回图标右上角。
    return Badge(
      key: const Key('as-queue-badge'),
      offset: const Offset(-6, 6),
      label: Text('${_effectiveQueue.length}'),
      child: icon,
    );
  }

  /// 打开当前队列。空队列给**空态**（不是空白弹层）；
  /// 非空则列出每条曲目并高亮当前条，点一条把页面切到那首
  /// （起播仍走既有的播放/下一首链路，不新增播放器 API）。
  Future<void> _openQueueSheet() async {
    final queue = _effectiveQueue;
    final current = _queueIndex.clamp(
      0,
      queue.isEmpty ? 0 : queue.length - 1,
    );
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: queue.isEmpty
            ? AppEmptyState(
                key: const Key('as-queue-empty'),
                icon: Icons.playlist_play,
                title: dataText(
                  'asQueueEmpty',
                  '播放队列还是空的（当前是单曲播放）',
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DesignRowTile(
                    dense: true,
                    title: Text(
                      dataText('asQueueEntryActive', '播放队列 · {count} 首')
                          .replaceAll('{count}', '${queue.length}'),
                      style: Theme.of(sheetContext).textTheme.titleSmall,
                    ),
                  ),
                  Flexible(
                    child: ListView.builder(
                      key: const Key('as-queue-list'),
                      shrinkWrap: true,
                      itemCount: queue.length,
                      itemBuilder: (_, i) {
                        final s = queue[i];
                        final meta = asSongMetaLine(s);
                        return DesignRowTile(
                          key: Key('as-queue-item-${s.id}'),
                          selected: i == current,
                          leading: Icon(
                            i == current
                                ? Icons.play_arrow
                                : Icons.music_note_outlined,
                          ),
                          title: Text(
                            s.title.isNotEmpty ? s.title : s.path,
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
                                    color: DesignPalette.of(sheetContext).dim,
                                  ),
                                ),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            if (i != _queueIndex) {
                              _setQueueIndex(i);
                            }
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final api = ref.watch(audioApiProvider);
    final async = ref.watch(audioSongProvider(_songId));
    // 播放队列的**常驻入口**（W1-3 收尾缺口）：让用户随时看到/回到当前队列，
    // 而不是只能靠"再点一次播放"。
    //
    // 能力/会话门控：未连接 / 套件未安装 / 缺 `AudioStation.Stream` 能力位
    // → 入口**不渲染**；原因分别由正文的 `setNotConnected` 空态、
    // `as-not-installed` 空态、`as-stream-unavailable` 降级提示给出（不另造一套）。
    final canStream = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.audio, kAudioStreamApi);
    final canOpenQueue = api != null && api.installed && canStream;
    return DesignScaffold(
      appBar: AppBar(
        title: Text(_songTitle),
        actions: [
          if (canOpenQueue) _queueEntryAction(),
          if (api != null && api.installed)
            PopupMenuButton<String>(
              key: const Key('as-song-menu'),
              tooltip: dataText('asSongMenu', '更多'),
              onSelected: (value) {
                final song = ref.read(audioSongProvider(_songId)).value;
                if (song == null) return;
                switch (value) {
                  case 'download':
                    unawaited(_download(song));
                  case 'share':
                    unawaited(_share(song));
                  case 'show_in_files':
                    _showInFiles(song.path);
                  case 'add_to_playlist':
                    unawaited(_addToPlaylist(song));
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  key: const Key('as-song-download'),
                  value: 'download',
                  child: Text(dataText('asDownload', '下载')),
                ),
                PopupMenuItem(
                  key: const Key('as-song-share'),
                  value: 'share',
                  child: Text(dataText('asShare', '分享')),
                ),
                // r442：把这首歌加入某个播放列表（`Playlist/updatesongs` 追加用法）
                PopupMenuItem(
                  key: const Key('as-song-add-to-playlist'),
                  value: 'add_to_playlist',
                  child: Text(dataText('asAddToPlaylist', '加入播放列表')),
                ),
                // D6：跳到 File Station 的同目录（官方两 App 独立，但我们**多给**一个入口）
                PopupMenuItem(
                  key: const Key('as-song-show-in-files'),
                  value: 'show_in_files',
                  child: Text(dataText('asShowInFiles', '在 File Station 中显示')),
                ),
              ],
            ),
        ],
      ),
      body: api == null
          ? AppEmptyState(icon: Icons.cloud_off, title: t.setNotConnected)
          : !api.installed
          ? AppEmptyState(
              key: const Key('as-not-installed'),
              icon: Icons.extension_off_outlined,
              title: t.asErrNotInstalled,
              message: t.asNotInstalledHint,
            )
          : async.when(
              loading: () => const AppListSkeleton(rows: 5),
              error: (e, __) => AppErrorView(
                title: t.asSongLoadFailed,
                detail: describeAudioError(e),
                onRetry: () => ref.invalidate(audioSongProvider(_songId)),
              ),
              data: (song) => song == null
                  ? AppEmptyState(
                      icon: Icons.search_off,
                      title: t.asSongLoadFailed,
                      // ★ r320：这里原来挂 `t.asOpenFailed` —— 那是一句**报错文案**
                      //   （"Failed to open"/"打开失败"），被当成**按钮标签**用，
                      //   于是屏幕上出现一个写着"打开失败"的按钮（动作其实是重试）。
                      //   诊断串不许当用户文案（§2.0.47 ④）⇒ 按钮就是 `photoRetry`。
                      actionLabel: t.photoRetry,
                      actionIcon: Icons.refresh,
                      onAction: () =>
                          ref.invalidate(audioSongProvider(_songId)),
                    )
                  : _body(context, song),
            ),
    );
  }

  Widget _body(BuildContext context, AudioSongDto song) {
    // ★★★ r631：单曲页**从"文档"改成"播放器"**（用户 2026-10-23：
    //    「从人类用户使用角度…很多音频技术参数没有必要罗列在界面上，
    //      可以收在某一个菜单项里」）。
    //
    // 旧版面（自上而下）：小封面 + 标题 + `3:51 · 320 kbps · 44.1 kHz · 9.0 MB`
    //   → 评分五星 → 播放卡片（进度/小封面/播放键/音质档位/睡眠定时/
    //   **Streaming URL 一大段**）→ 歌词 → 15 行技术字段 → 在线标签。
    //   真机首屏有一半是排障信息，播放键要滑一下才看得全（证据见
    //   `docs/evidence-r631/device_before_*`）。
    //
    // 新版面只留**人要看的三块**：① 大封面 + 歌名/歌手/时长；② 进度 + 播放键
    //   + 常用动作；③ 同步滚动的歌词。技术参数、评分、音质、在线标签、流地址
    //   全部收进「歌曲信息」面板（`_openSongInfo`，从播放区的「歌曲信息」进入）。
    return ListView(
      padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xxl * 2),
      children: [
        _PlayerHero(song: song),
        const SizedBox(height: Gap.md),
        _StreamSection(
          song: song,
          queue: _effectiveQueue,
          index: _queueIndex,
          autoPlay: widget.autoPlay,
          onIndexChanged: _setQueueIndex,
          onQueue: _openQueueSheet,
          onInfo: () => unawaited(_openSongInfo(song)),
          urlFor: _urlOf,
        ),
        // D2：这首歌已在本地离线缓存里 —— 如实标出来（不夸口"可离线播放"，
        // 因为缓存的是服务端打包字节，能否播放取决于服务端给了什么）。
        if (ref.watch(audioOfflineIdsProvider).contains(song.id)) ...[
          const SizedBox(height: Gap.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
            child: TelemetryLabel(
              dataText('asDownloadedLocal', '已下载到本机'),
              key: const Key('as-downloaded-badge'),
              color: DesignPalette.of(context).dim,
            ),
          ),
        ],
        const SizedBox(height: Gap.md),
        // ★★★ r644（**DA241**）：歌词面板**必须跟着歌换**。
        //
        // 真机（2026-10-23）：屏上曲名已是 `Demo Song`，署名却仍是**上一首**的
        // `Favorite Girl · Justin Bieber`（像素 `docs/evidence-r644/09_stale_lyrics_after_switch.png`）。
        // 根因：`_LyricsSection` 的 State 存着 `_lookup` / `_cacheTried` /
        // `_autoTried`，而它**没有 key** —— 换歌只换 `widget.song`，同一棵元素
        // 原地复用 ⇒ 上一首的歌词、"已查过缓存/已自动匹配"标记全留着。
        // 给 key 就是给**这首歌**一个身份：新歌 = 新 State = 重新读缓存/重新匹配。
        _LyricsSection(
          key: ValueKey('lyrics-${song.id}'),
          song: song,
          // 记号对不上就不给它（结构性兜底：哪怕哪天漏了清，也不会串台）。
          online: _onlineLyricsFor == song.id ? _onlineLyrics : null,
          searching: _searchingLyrics,
          onSearch: () => _searchLyrics(song),
        ),
      ],
    );
  }

  /// 「歌曲信息」面板（r631）：原来铺在页面上的**全部技术/管理内容**搬到这里。
  ///
  /// 用户原话是"收在某一个菜单项里" —— 所以这是一个**面板**而不是第二页：
  /// 关掉就回到播放器，不丢位置、不丢播放状态。里面按"先技术、后管理"排序：
  /// ① 评分 ② 音质档位 ③ 详细信息（15 个字段）④ 流地址 ⑤ 在线标签。
  ///
  /// ★ 键名一个都没改（`as-stream-url` / `as-copy-url` / `as-quality-*` /
  ///   `as-quality-row` / `as-transcode-hint`）：旧用例只要先点开面板就仍然成立。
  Future<void> _openSongInfo(AudioSongDto song) async {
    final api = ref.read(audioApiProvider);
    final info = ref.read(audioInfoProvider).value;
    final bitrate = ref.read(audioTranscodeBitrateProvider);
    final mode = AudioStationApi.defaultStreamMode(song, info: info);
    final transcode = AudioStationApi.usesServerTranscode(mode);
    // 只用于**显示/复制**：与播放器共用**同一个** `_urlOf` 缓存
    // （`_dc` 时间戳只生成一次，面板上写的与播放器里放的是同一条 URL）。
    // ⚠️ 但**档位**是活的：用户在面板里改档位后 URL 必须跟着变，所以存的是
    //   「能按档位现算」的闭包，而不是一个定死的字符串（旧写法当场被用例抓到）。
    String urlFor(int bps) => api == null ? '' : _urlOf(api, song, info, bps);
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: DesignPalette.of(context).surface,
      builder: (ctx) => Theme(
        data: theme,
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.88,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (ctx, controller) => SafeArea(
            key: const Key('as-song-info-sheet'),
            // ★ r631：同 `showRadioPlayerSheet` —— 弹层不在页面的 `Theme` 作用域里，
            //   必须把页面的 `Theme` 显式带过去，否则主色/字号会退回全局档。
            child: _SongInfoSheet(
              song: song,
              urlFor: urlFor,
              initialBitrate: bitrate,
              transcode: transcode,
              controller: controller,
            ),
          ),
        ),
      ),
    );
  }

  /// 服务端（NAS）搜歌词这一路的结论 —— **不在这一层报**（DA55）：
  /// 点一次按钮其实有**两条联网来源**（NAS 的 `LyricsSearch` 与公开源），
  /// 谁先说谁就露脸，会出现"屏上正显示着歌词，提示条却说联网没找到"。
  /// 所以这里只回结论，由 [_LyricsSection] 等两条都出结果后统一说人话。
  Future<LyricsServerOutcome> _searchLyrics(AudioSongDto song) async {
    setState(() => _searchingLyrics = true);
    try {
      final text = await ref
          .read(audioActionsProvider)
          .searchLyrics(
            song.title,
            artist: song.artist.isEmpty ? null : song.artist,
          );
      if (!mounted) return LyricsServerOutcome.failed;
      setState(() {
        _searchingLyrics = false;
        _onlineLyrics = text;
        // 记下**这是给哪首歌搜的**（见 `_onlineLyricsFor`）。
        _onlineLyricsFor = song.id;
      });
      return text.isEmpty ? LyricsServerOutcome.none : LyricsServerOutcome.found;
    } catch (_) {
      if (!mounted) return LyricsServerOutcome.failed;
      setState(() => _searchingLyrics = false);
      return LyricsServerOutcome.failed;
    }
  }

  /// D2：下载（`Download.download` v1 —— 官方把选中曲目打成 zip 给你存到本机）。
  ///
  /// 三道门（缺一不可，且都**如实**说话）：
  ///   1. 服务端 `enable_download` 为假 → **不发**注定无载荷的请求；
  ///   2. 服务端回 200 但内容不是打包字节（真机本机就是 `{"success": true}`，
  ///      17 字节）→ 说"服务端没有返回下载内容"，不写假文件；
  ///   3. 落盘失败（无文档目录 / 无权限）→ 说失败。
  /// D6：在 File Station 中打开本曲所在目录。
  ///
  /// 官方 Android 的 DS audio 与 DS file 是两个独立 App（无互相跳转），
  /// 我们**多做一步**：直接切到 File Station 的同目录。
  /// 路径无 `/` 时（异常数据）退回根目录，**不臆造**。
  void _showInFiles(String path) {
    final i = path.lastIndexOf('/');
    final dir = i > 0 ? path.substring(0, i) : '/';
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileBrowsePage(initialPath: dir),
      ),
    );
  }

  /// **r442**：把这首歌加入某个播放列表（官方 = `Playlist/updatesongs` 的**追加**用法）。
  ///
  /// 服务端契约见 [AudioStationApi.addSongsToPlaylist]（真机探针实测）：
  /// `offset = 该列表已有曲数`、`limit = 0` ⇒ 追加；**重复** ⇒ 服务端回 411
  /// （`AUDIO_ERR_DUPLICATE_SONGS`，文案「有重复的歌曲」—— 见 `DA96`）。
  ///
  /// 只列**普通列表**（智能列表的曲目由规则决定，服务端不接受手工加歌）。
  Future<void> _addToPlaylist(AudioSongDto song) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(audioApiProvider);
    if (api == null) return;
    // 两个库都列（个人 + 共享）；智能列表排除（曲目由规则决定，服务端不收手工加歌）。
    final choices = <AudioPlaylistDto>[];
    try {
      for (final lib in AudioLibrary.values) {
        final page = await api.listPlaylists(
          library: lib,
          offset: 0,
          limit: 100,
        );
        choices.addAll(page.items.where((p) => !p.isSmart));
      }
      // 去重按 `id`（两个库分别查，服务端理论上不会给同一条；重复入口只会让用户困惑）
      final seen = <String>{};
      choices.retainWhere((p) => seen.add(p.id));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(userFacingError(e))));
      return;
    }
    if (!mounted) return;
    final picked = await showDialog<AudioPlaylistDto>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('as-choose-playlist'),
        title: Text(dataText('asChoosePlaylist', '选择播放列表')),
        content: SizedBox(
          width: double.maxFinite,
          child: choices.isEmpty
              ? Text(dataText('asChoosePlaylistEmpty', '还没有播放列表，请先在音频首页新建一个'))
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in choices)
                      DesignRowTile(
                        key: Key('as-playlist-pick-${c.id}'),
                        leading: const Icon(Icons.queue_music_outlined),
                        title: Text(
                          c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        // 个人/共享标签复用播放列表徽标（`asSharedPlaylist`/`asPersonalPlaylist`）
                        subtitle: Text(asPlaylistBadge(context.t, c)),
                        onTap: () => Navigator.of(ctx).pop(c),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.t.actionCancel),
          ),
        ],
      ),
    );
    if (picked == null) return;
    try {
      await api.addSongsToPlaylist(id: picked.id, songIds: [song.id]);
      messenger.showSnackBar(
        SnackBar(
          key: const Key('as-playlist-added'),
          content: Text(
            dataText('asPlaylistAdded', '已加入「{name}」').replaceAll(
              '{name}',
              picked.name,
            ),
          ),
        ),
      );
    } catch (e) {
      // ★ 文案统一走"异常 → 用户文案"的唯一出口（`DA96` 修的就是它）。
      messenger.showSnackBar(
        SnackBar(
          key: const Key('as-playlist-add-failed'),
          content: Text(userFacingError(e)),
        ),
      );
    }
  }

  Future<void> _download(AudioSongDto song) async {
    final messenger = ScaffoldMessenger.of(context);
    final info = ref.read(audioInfoProvider).value;
    if (info != null && !info.audioEnableDownload) {
      messenger.showSnackBar(
        SnackBar(
          key: const Key('as-download-disabled'),
          content: Text(
            // ★ r343 D52：原文案带 API 参数名与取值（D39/D40 同族，§2.0.47）。
            dataText(
              'asDownloadDisabled',
              '服务端未开启下载，请在 NAS 上的下载套件里开启后重试',
            ),
          ),
        ),
      );
      return;
    }
    try {
      final bytes = await ref.read(audioActionsProvider).downloadBytes([
        song.id,
      ]);
      if (!mounted) return;
      if (looksLikeServerStub(bytes)) {
        messenger.showSnackBar(
          SnackBar(
            key: const Key('as-download-nocontent'),
            content: Text(
              dataText('asDownloadNoContent', '服务端没有返回下载内容'),
            ),
          ),
        );
        return;
      }
      final saved = await ref
          .read(audioOfflineStoreProvider)
          .save(song.id, bytes);
      if (!mounted) return;
      if (!saved) {
        messenger.showSnackBar(
          SnackBar(
            key: const Key('as-download-failed'),
            content: Text(dataText('asDownloadFailed', '下载失败：无法写入本地')),
          ),
        );
        return;
      }
      unawaited(ref.read(audioOfflineIdsProvider.notifier).reload());
      messenger.showSnackBar(
        SnackBar(
          key: const Key('as-download-ok'),
          content: Text(
            dataText('asDownloadOk', '已下载 {n} 字节到本机').replaceAll(
              '{n}',
              '${bytes.length}',
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          key: const Key('as-download-error'),
          content: Text(describeAudioError(e)),
        ),
      );
    }
  }

  /// D4：分享（`Song.getsharing` v2 读 / `setsharing` v2 写，受 `privilege.sharing`）。
  Future<void> _share(AudioSongDto song) async {
    final messenger = ScaffoldMessenger.of(context);
    final info = ref.read(audioInfoProvider).value;
    if (info != null && !info.sharing) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('as-share-no-privilege'),
          title: Text(dataText('asShare', '分享')),
          content: Text(
            // ★ r343 D52：原文案带服务端权限字段名（`privilege.sharing=false`）。
            dataText(
              'asShareNoPrivilege',
              '服务端未开启共享，请在 NAS 上开启后重试',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(context.t.actionOk),
            ),
          ],
        ),
      );
      return;
    }
    AudioSharingInfo? current;
    try {
      current = await ref.read(audioActionsProvider).getSharing(song.id);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(describeAudioError(e))),
      );
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('as-share-dialog'),
        title: Text(dataText('asShare', '分享')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (current?.url.isNotEmpty ?? false)
              SelectableText(
                current!.url,
                key: const Key('as-share-url'),
                style: Theme.of(ctx).textTheme.bodySmall,
              )
            else
              Text(
                dataText('asShareNone', '这首歌还没有共享链接'),
                key: const Key('as-share-none'),
              ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('as-share-toggle'),
            onPressed: () async {
              final enable = !(current?.enableSharing ?? false);
              Navigator.of(ctx).pop();
              try {
                await ref
                    .read(audioActionsProvider)
                    .setSharing(song.id, enable: enable);
                if (!mounted) return;
                unawaited(_share(song));
              } catch (e) {
                if (!mounted) return;
                messenger.showSnackBar(
                  SnackBar(content: Text(describeAudioError(e))),
                );
              }
            },
            child: Text(
              (current?.enableSharing ?? false)
                  ? dataText('asShareDisable', '关闭共享')
                  : dataText('asShareEnable', '开启共享'),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.t.actionOk),
          ),
        ],
      ),
    );
  }
}

class _PlayerHero extends ConsumerWidget {
  const _PlayerHero({required this.song});

  final AudioSongDto song;

  /// 大封面边长：393pt 屏上左右各留 16 ⇒ 361 可用；**240** 让首屏
  /// 一眼能同时看到"封面 + 歌名 + 播放键"，不用滑（旧版首屏只有半张卡）。
  static const double coverSize = 236;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final api = ref.watch(audioApiProvider);
    final p = DesignPalette.of(context);
    // 封面两级（用户明确要求"音视频同样支持内嵌封面 + 服务器缩略图回退"）：
    // ① 文件**内嵌**封面（走 FileStation Range 片段，`AudioSongDto.path`）；
    // ② 没有内嵌 → 既有的 Audio Station 服务器封面 `Cover.getsongcover`；
    // ③ 都没有 → AudioCoverImage 的图标占位（不是空白）。
    final embedded = embeddedSongCoverKey(
      song: song,
      fs: ref.watch(fileApiProvider),
    );
    final title = song.title.isNotEmpty
        ? song.title
        : (song.path.isNotEmpty ? song.path : t.asSongInfo);
    final humanMeta = asSongHumanMetaLine(song);
    return Padding(
      key: const Key('as-player-hero'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      child: Column(
        children: [
          // ★ r631：封面是**这一页的主角**（Plexamp / Apple Music 的通行做法）。
          //   旧版是 64×64 的小头像，用户读到的是"一张歌单里的一个条目"，
          //   而不是"正在播放"。
          Center(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  width: coverSize,
                  height: coverSize,
                  child: MediaCoverImage(
                    request: embedded,
                    fit: BoxFit.cover,
                    fallback: AudioCoverImage(
                      key: const Key('as-song-cover'),
                      identity: song.id,
                      url: api?.songCoverUrl(song.id),
                      size: coverSize,
                      fallbackIcon: Icons.music_note_outlined,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: Gap.md),
          Text(
            title,
            key: const Key('as-hero-title'),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w600,
              height: 1.25,
              color: p.text,
            ),
          ),
          if (song.subtitle.isNotEmpty) ...[
            const SizedBox(height: Gap.xxs),
            Text(
              song.subtitle,
              key: const Key('as-hero-artist'),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, color: p.muted),
            ),
          ],
          if (humanMeta.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            // ★ r631：这里**只**写时长与年份。比特率/采样率/体积挪进
            //   「歌曲信息」面板（用户要求：技术参数不铺在界面上）。
            Text(
              humanMeta,
              key: const Key('as-hero-meta'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: DesignType.labelSmallSize,
                color: p.dim,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 评分 / 收藏（`Song.setrating` v2）。
class _RatingSection extends ConsumerWidget {
  const _RatingSection({required this.song});

  final AudioSongDto song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    final current = song.rating.round();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      child: Row(
        children: [
          _MetaLine(t.asRating),
          const SizedBox(width: Gap.sm),
          for (var star = 1; star <= 5; star++)
            IconButton(
              key: Key('as-star-$star'),
              visualDensity: VisualDensity.compact,
              tooltip: '$star',
              icon: Icon(
                star <= current ? Icons.star : Icons.star_border,
                size: 20,
                color: star <= current ? scheme.primary : DesignPalette.of(context).dim,
              ),
              // ★ DA206（真机 r615）：原来只会 `setRating(star)` —— 评过之后就再也
              //   回不到"未评分"（接口本身支持 `rating=0` 清除，界面上却没有入口）。
              //   真机实测：点第 5 颗星 = 5 星，再点同一颗**什么都不变**。
              //   语义对齐同一个文件里的睡眠定时（「再点一次可取消」）：
              //   点当前星级 = 清除。
              onPressed: () => _setRating(
                context,
                ref,
                star == current ? 0 : star,
              ),
            ),
          if (current == 0) _MetaLine(t.asRatingUnset),
        ],
      ),
    );
  }

  Future<void> _setRating(
    BuildContext context,
    WidgetRef ref,
    int rating,
  ) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      // `Song.setrating` 的 `id` 是**逗号串**（官方 `id:a.join(",")`）。
      await ref.read(audioActionsProvider).setRating([song.id], rating);
      ref.invalidate(audioSongProvider(song.id));
      // 清除（rating=0）时提示"已清除"，别让用户以为还存着星级（DA206）。
      messenger.showSnackBar(
        SnackBar(content: Text(rating == 0 ? t.asRatingCleared : t.asRatingSet)),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.asRatingFailed(describeAudioError(e)))),
      );
    }
  }
}

/// B11：睡眠定时行（15 / 30 / 60 / 90 分钟；再点一次可取消）。
///
/// 官方安卓端把睡眠定时放在播放页（`widget/SleepTimer`），纯客户端计时，
/// **没有服务端 API**。到点行为由 `_StreamSectionState` 的 `ref.listen`
/// 一次性处理（暂停 + 提示 + 复位）。
class _SleepTimerRow extends ConsumerWidget {
  const _SleepTimerRow();

  /// 官方可选档位（分钟）。
  static const List<int> kMinutes = [15, 30, 60, 90];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = ref.watch(audioSleepTimerProvider);
    final label = remaining == null
        ? dataText('asSleepTimer', '睡眠定时')
        : dataText('asSleepTimerRemaining', '睡眠定时 · {left}').replaceAll(
            '{left}',
            asDurationText(remaining.inSeconds),
          );
    return Row(
      children: [
        _PanelLabel(label, key: const Key('as-sleep-label')),
        const Spacer(),
        if (remaining != null)
          TextButton(
            key: const Key('as-sleep-cancel'),
            onPressed: () =>
                ref.read(audioSleepTimerProvider.notifier).cancel(),
            child: Text(dataText('asSleepTimerCancel', '取消')),
          ),
        PopupMenuButton<int>(
          key: const Key('as-sleep-menu'),
          tooltip: dataText('asSleepTimerSet', '设置睡眠定时'),
          icon: const Icon(Icons.bedtime_outlined, size: 18),
          onSelected: (minutes) {
            final timer = ref.read(audioSleepTimerProvider.notifier);
            // ★ r633（DA221）：菜单里的「关闭」用哨兵值 0（`PopupMenuItem` 的
            //   `value` 不许为 null，否则"点了没反应"无法与"取消菜单"区分）。
            if (minutes <= 0) {
              timer.cancel();
              return;
            }
            timer.start(Duration(minutes: minutes));
          },
          itemBuilder: (_) => [
            // ★ r633（DA221）：**当前选中的那档要打勾**，并把「关闭定时」
            //   放进菜单里。旧版：再打开菜单看不出现在是哪一档（四个选项
            //   长得一样），想关还得去菜单**外面**另找那个「取消」按钮
            //   —— 一个动作拆成两处，是菜单语义的倒退。
            for (final m in kMinutes)
              PopupMenuItem(
                key: Key('as-sleep-$m'),
                value: m,
                child: _SleepMenuItem(
                  key: Key('as-sleep-check-$m'),
                  label: dataText('asSleepTimerMinutes', '{m} 分钟').replaceAll(
                    '{m}',
                    '$m',
                  ),
                  checked:
                      ref.read(audioSleepTimerProvider.notifier).chosenMinutes ==
                          m,
                ),
              ),
            if (remaining != null) ...[
              const PopupMenuDivider(),
              PopupMenuItem(
                key: const Key('as-sleep-off'),
                value: 0,
                child: _SleepMenuItem(
                  label: dataText('asSleepTimerOff', '关闭定时'),
                  checked: false,
                  icon: Icons.bedtime_off_outlined,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// 睡眠定时菜单里的一行：勾选标记 + 文案（r633 / DA221）。
class _SleepMenuItem extends StatelessWidget {
  const _SleepMenuItem({
    super.key,
    required this.label,
    required this.checked,
    this.icon,
  });

  final String label;
  final bool checked;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = DesignPalette.of(context);
    return Row(
      children: [
        Icon(
          checked ? Icons.check : icon,
          size: 18,
          color: checked ? p.primary : (icon == null ? Colors.transparent : null),
        ),
        const SizedBox(width: Gap.sm),
        Text(label),
      ],
    );
  }
}

/// 播放器段：流式 URL（`stream.cgi/0.<ext>`，`_sid=` 鉴权）+
/// 播放/暂停 · 上一首/下一首 · 进度与 seek · 随机/循环 · 转码音质档位。
///
/// * **队列**来自打开单曲页时带进来的 `queue`（没有就退化成单曲）；
///   上限消费 `Info.getinfo.playing_queue_max`（真机 **8192**，审计 §1.4）；
/// * **进度与 seek**：位置/时长来自播放器；AS 直传与转码流都吃 HTTP Range
///   （真机已证，审计 §1.7），所以客户端 `seek` 不需要重拼 `position=`；
/// * **音质档位**只作用于"服务端转码且目标为 mp3"的那条 URL
///   （官方三档 128000/192000/320000，真机逐档验证，审计 §1.7）。
class _StreamSection extends ConsumerStatefulWidget {
  const _StreamSection({
    required this.song,
    required this.queue,
    required this.index,
    required this.onIndexChanged,
    required this.onQueue,
    required this.onInfo,
    required this.urlFor,
    this.autoPlay = false,
  });

  final AudioSongDto song;
  final List<AudioSongDto> queue;
  final int index;
  final ValueChanged<int> onIndexChanged;

  /// 打开播放队列（队列状态在页面态里，面板只负责显示入口）。
  final VoidCallback onQueue;

  /// 打开「歌曲信息」面板（r631）：技术参数 / 评分 / 音质 / 流地址都在那里。
  final VoidCallback onInfo;

  /// 页面级的流地址生成器（r631：面板与播放器必须显示/播放**同一条** URL）。
  final String Function(
    AudioStationApi api,
    AudioSongDto song,
    AudioInfoDto? info,
    int bitrate,
  )
  urlFor;

  /// 页面要求"打开就播"（列表点歌，见 `AudioSongDetailPage.autoPlay`）。
  final bool autoPlay;

  @override
  ConsumerState<_StreamSection> createState() => _StreamSectionState();
}

class _StreamSectionState extends ConsumerState<_StreamSection> {
  /// 这次播放失败的**分类原因**（null = 没失败）。
  ///
  /// 为什么不满足于一句 `asPlayFailed('$e')`：那句把"服务端转码被拒 / 会话过期 /
  /// 网络中断 / 解码器解不了"混成同一句，用户和排查都会被带偏
  /// （与文件预览页 `classifyPlayerError` 同一套分类，见 `media_player.dart`）。
  MediaUnavailableReason? _failure;

  /// 刚才那次播放用的是转码流（失败重试时要说明"重试的是哪条路"）
  bool _retryUsesTranscode = false;

  /// **起播中**（三态里的 loading）：按下播放到**引擎真的出状态**之间。
  ///
  /// 为什么要单独一个态：真机上"按下去没反应"最常见的原因是**取流被拒**
  /// 而播放器要过一会儿才报错（socket/嗅探都要时间）。没有 loading 态时，
  /// 用户看到的只有"按了没反应"，等几秒才跳失败 —— 中间那段就是黑洞
  /// （AGENTS §2.0.17 ②：中间态必须可视化）。
  ///
  /// ⚠️ **引擎状态才是事实**：它一到（在播/暂停/出错都算），起播这一段就结束了
  /// —— 见 [_onHandlerState]。否则"await 还没回来"会让按钮一直转圈，
  /// 而播放其实已经开始了（真机上就是"明明在响却显示在加载"）。
  bool _starting = false;

  /// `autoPlay` 只触发一次（用户按暂停后不许被它抢回来）。
  bool _autoPlayTried = false;

  /// 最近一次失败的**可查询原因**（进 logcat；UI 不显示它）。
  ///
  /// 前缀固定 `[audio-station] play-failure`，真机排查一条命令捞全：
  /// `adb logcat -d | grep 'audio-station'`。
  String? _failureReason;

  /// 拖动中的进度（毫秒；null = 没在拖，显示播放器实时位置）。
  double? _dragMs;

  /// handler 的订阅（`playbackState` / `queue` / 续期通知）。
  final List<StreamSubscription<dynamic>> _subs = [];

  /// 本页绑定的 handler（`dispose` 里**不能**再 `ref.read`，先把实例存下来）。
  SynologyAudioHandler? _handler;

  /// B6：每 5 秒把播放位置落盘（断点续播）。
  Timer? _positionTimer;

  @override
  void initState() {
    super.initState();
    // R7：页面**只**监听 handler 的 `playbackState` / `queue`（不再直接读引擎），
    // 队列推进（自动下一首 / 上一首下一首 / 循环）→ 页面跟着换歌。
    final handler = ref.read(audioHandlerProvider);
    _handler = handler;
    _subs.add(handler.playbackState.listen(_onHandlerState));
    _subs.add(
      handler.queue.listen((_) {
        if (mounted) setState(() {});
      }),
    );
    _subs.add(handler.renewNotices.listen(_onRenewNotice));
    // R8：会话续期所需的新直链**只能**由页面（有会话）解析 —— 把回调交给
    // handler；它自己绝不登录（R6）。断链时 handler 会退回"暂停 + 如实提示"。
    handler.freshUrlFetcher = _freshUrlFor;
    // B12：把当前 gapless 配置推给引擎，并在开关变化时同步。
    _applyGapless(ref.read(audioGaplessProvider));
    ref.listenManual<bool>(audioGaplessProvider, (_, next) {
      _applyGapless(next);
    });
    // B6：位置落盘（5 秒一次；测试可用 pump 推进假时钟）。
    _positionTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_savePosition()),
    );
  }

  /// B12：若引擎支持 gapless（[AudioGaplessControls]），把开关推给它。
  ///
  /// 用 `is` 判断而**不是**给 `AudioStationPlayer` 加抽象方法：既有假实现
  /// （测试里的 `_FakePlayer`）不必被迫补一个与它们无关的方法。
  void _applyGapless(bool enabled) {
    // 用 `case` 模式而不是 `is` + 提升：两个能力接口与 `AudioStationPlayer`
    // 无继承关系，直接用模式绑定最省事。
    if (ref.read(audioStationPlayerProvider)
        case final AudioGaplessControls gapless) {
      _guard(() => gapless.setGapless(enabled));
    }
  }

  @override
  void dispose() {
    // 离开页面 = 这一段估算窗口结束（后台继续播的部分**不**归属，宁可少算）
    unawaited(EstimatedTraffic.end());
    _positionTimer?.cancel();
    _positionTimer = null;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    // 只撤销**本页**注入的回调（同一实例方法的 tear-off 相等）
    if (_handler?.freshUrlFetcher == _freshUrlFor) {
      _handler?.freshUrlFetcher = null;
    }
    super.dispose();
  }

  /// 用**当前会话**重新解析某条曲目的直链（续期用）。
  ///
  /// 复用既有续期路径的两半：
  ///   * `Song.getinfo` 是**既有**的鉴权调用 → 当前 `_sid` 失效时 `DsmWebApi.call`
  ///     走既有的"119 → `onSessionExpired` 重登 → 重放一次"（与
  ///     `media_source.dart` 的 `_renewPhotosSource` 借
  ///     `videoPlaybackInfo` 触发重登同一套路）；
  ///   * 重登后 `api.streamUrl` 用**新** `_sid` 重拼直链。
  ///
  /// 失败（重登失败 / 歌被删）**抛出** → handler 的有界重试耗尽后暂停 + 如实提示。
  Future<String> _freshUrlFor(String mediaId) async {
    final api = ref.read(audioApiProvider);
    if (api == null) throw StateError('未连接');
    final song = await api.getSong(mediaId);
    if (song == null) throw StateError('song not found: $mediaId');
    final info = ref.read(audioInfoProvider).value;
    final bitrate = ref.read(audioTranscodeBitrateProvider);
    final mode = AudioStationApi.defaultStreamMode(song, info: info);
    final url = api.streamUrl(song, mode: mode, bitrate: bitrate);
    if (url.isEmpty) throw StateError('empty stream url');
    return url;
  }

  /// handler 的 `playbackState` 变化 → 队列下标跟着换歌 + 落盘 + 补封面。
  void _onHandlerState(PlaybackState state) {
    if (!mounted) return;
    // 引擎已经出状态了 ⇒ 起播这一段结束（成功、暂停、出错都算），
    // 界面立刻回到"按 playing 显示播放/暂停"，不再被卡在转圈上。
    if (_starting) _starting = false;
    final i = _currentIndex();
    if (i >= 0 && i < widget.queue.length && i != widget.index) {
      widget.onIndexChanged(i);
      // 推进也要把"上次播到哪一条"落盘（与 W1-2 目录队列同一语义）
      _persistQueue(i);
      // 队列推进到下一首 → 补上那一首的内嵌封面（通知栏/锁屏用）
      unawaited(_attachCoverFor(i));
    }
    setState(() {});
  }

  /// 当前在播的是队列里的第几条（身份 = `mediaItem.id`，**不**依赖引擎下标）。
  int _currentIndex() {
    final id = _handler?.currentMediaId;
    if (id == null) return -1;
    if (widget.queue.isEmpty) return id == widget.song.id ? 0 : -1;
    return widget.queue.indexWhere((s) => s.id == id);
  }

  /// 续期结果提示：成功 = 非阻塞"已续上"；失败 = **明确说已暂停**（R8 不夸口）。
  void _onRenewNotice(AudioRenewNotice notice) {
    if (!mounted) return;
    final text = switch (notice.kind) {
      AudioRenewNoticeKind.renewed => dataText(
        'mediaSessionReconnected',
        '已重新连接，从原位置继续播放',
      ),
      AudioRenewNoticeKind.failedPaused => dataText(
        'mediaSessionRenewFailedPaused',
        '会话已过期且自动续期失败，已暂停播放；请回到 App 重新登录后重试',
      ),
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// 把当前队列 + 下标落盘：**只存 id/标题**（不存带 `_sid` 的流式 URL）。
  ///
  /// 失败绝不影响播放（`store` 内部已按"坏文件不抛 / 无平台通道退内存"处理，
  /// 这里再兜一层，防测试注入的实现抛异常）。
  void _persistQueue([int? index]) {
    final songs = widget.queue.isEmpty ? [widget.song] : widget.queue;
    final snap = audioQueueSnapshotOf(songs, index ?? widget.index);
    if (snap == null) return;
    unawaited(
      ref
          .read(mediaPlaybackStoreProvider)
          .saveAudioQueue(snap)
          .catchError((Object _) {}),
    );
  }

  /// 本次播放的队列（含当前曲目；超过服务端上限按上限截断），带展示元数据。
  ///
  /// R6：URL 与元数据在这里（主引擎、有会话）解析好，才交给 handler；
  /// 封面走**既有内嵌封面提取链**（FileStation `Range` 片段），拿不到就不给
  /// `artUri` —— 绝不为封面联网取图（方案 §3.5）。
  Future<List<AudioTrackInfo>> _tracks(
    AudioStationApi api,
    AudioInfoDto? info,
    int bitrate,
  ) async {
    final songs = widget.queue.isEmpty ? [widget.song] : widget.queue;
    final entries = [
      for (final s in songs)
        AudioQueueEntry(
          id: s.id,
          url: widget.urlFor(api, s, info, bitrate),
          title: s.title,
        ),
    ];
    final cap = info?.queueMax ?? AudioInfoDto.kPlayingQueueMaxFallback;
    final capped = capPlaybackQueue(entries, widget.index, cap);
    final byId = {for (final s in songs) s.id: s};
    final tracks = <AudioTrackInfo>[
      for (final e in capped)
        AudioTrackInfo(
          id: e.id,
          url: e.url,
          title: e.title,
          artist: byId[e.id]?.artist ?? '',
          album: byId[e.id]?.album ?? '',
          duration: (byId[e.id]?.duration ?? 0) > 0
              ? Duration(seconds: byId[e.id]!.duration)
              : null,
        ),
    ];
    // 当前条的内嵌封面（只取这一首；队列推进时由 [_attachCoverFor] 再补）
    final coverIndex = tracks.indexWhere((t) => t.id == widget.song.id);
    if (coverIndex >= 0) {
      final bytes = await _coverBytesFor(widget.song);
      if (bytes != null) {
        tracks[coverIndex] = tracks[coverIndex].withCover(bytes);
      }
    }
    return tracks;
  }

  /// ★ r653（`DA254`）：**通知栏/锁屏封面** —— 内嵌优先，退**服务器单曲封面**。
  ///
  /// 真机缺口：`Audio Station` 的歌`path` 常常为空（服务端不下发），
  /// `embeddedSongCoverKey` 直接给 null ⇒ 通知栏**从来没有封面**（`largeIcon=null`），
  /// 而页面上明明有封面（走的是 `Cover.getsongcover`）。
  /// 同一张图在两处显示，却只有一处能拿到 —— 典型"只连了一条接线"。
  ///
  /// 隐私口径不变：取到的字节只落**本地**文件给媒体会话用，
  /// 带 `_sid` 的 URL **不会**交给系统（`artUri` 永远是 `file://`）。
  Future<Uint8List?> _coverBytesFor(
    AudioSongDto song, {
    AudioStationApi? api,
    AlbumCoverResolver? resolver,
  }) async {
    final station = api ?? ref.read(audioApiProvider);
    final coverResolver = resolver ?? ref.read(albumCoverResolverProvider);
    return resolveNotificationCoverBytes(
      embedded: () => _embeddedCoverBytes(song),
      fetchServerCover: () async {
        final api = station;
        if (api == null) throw StateError('未连接 Audio Station');
        // ① 歌曲级封面（`Cover.getsongcover`）—— 页面上那张，优先复用缓存
        final songUrl = api.songCoverUrl(song.id);
        final hit = AuthedImageCache.get('${song.id}|$songUrl');
        if (hit != null && hit.isNotEmpty) return hit;
        final direct = await _tryFetchImage(api, songUrl);
        if (direct != null) return direct;
        // ② 专辑级封面（`Cover.getcover`）—— 同一张专辑的歌共享一张图。
        //    r653 真机：从通知栏切到下一首时，歌曲级常常 404（r439 实测
        //    12 张专辑只有 4 张逐首能探到真图），专辑级反而有 ⇒ 不给这一步，
        //    通知栏换歌就"掉图"。
        final albumUrl = api.albumCoverUrl(
          song.album,
          albumArtist: song.albumArtist,
        );
        if (albumUrl.isNotEmpty) {
          final cached = AuthedImageCache.get('album:${song.album}|$albumUrl');
          if (cached != null && cached.isNotEmpty) return cached;
          final album = await _tryFetchImage(api, albumUrl);
          if (album != null) return album;
        }
        // ③ 两级解析器（有界逐首探 ＋ 会话级负缓存，r439）
        if (coverResolver == null) throw StateError('没有封面解析器');
        final resolved = await coverResolver.resolve(
          album: song.album,
          albumArtist: song.albumArtist,
          identity: 'album:${song.album}',
        );
        if (resolved == null) throw StateError('这张专辑没有可用封面');
        final key = 'album:${song.album}|$resolved';
        final cached = AuthedImageCache.get(key);
        if (cached != null && cached.isNotEmpty) return cached;
        final deep = await _tryFetchImage(api, resolved);
        if (deep == null) throw StateError('封面 URL 不是图');
        return deep;
      },
    );
  }

  /// 取一个封面 URL 的字节：**只要是图**就返回，否则 null（404/HTML/网络错都不抛）。
  Future<Uint8List?> _tryFetchImage(AudioStationApi api, String url) async {
    if (url.isEmpty) return null;
    try {
      final raw = await api.api.getBytes(url);
      final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
      return looksLikeImage(bytes) ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  /// 复用既有内嵌封面的**提取链**（`embeddedSongCoverKey` + `mediaCoverProvider`，
  /// 只发 FileStation `Range` 片段）；拿不到 → null（**不联网取图**）。
  Future<Uint8List?> _embeddedCoverBytes(AudioSongDto song) async {
    final key = embeddedSongCoverKey(song: song, fs: ref.read(fileApiProvider));
    if (key == null) return null;
    try {
      final cover = await ref.read(mediaCoverProvider(key).future);
      return cover?.bytes;
    } catch (_) {
      return null;
    }
  }

  /// 队列推进到 [index] 时，把那一首的封面补交给 handler（通知栏/锁屏用）。
  ///
  /// ★ r653（`DA254`）：**await 之后这个 State 可能已经不存在了**。
  /// 真机日志：`attach idx=1 … bytes=55253 mounted=false` —— 取图成功（55 KB），
  /// 但"当前播放区"在切歌时被整块重建 ⇒ 老的 State `mounted == false`
  /// ⇒ 原来的 `if (!mounted) return` 把**已经拿到手的封面**丢掉了，
  /// 于是通知栏换歌就掉图（第一首有图、下一首没图）。
  ///
  /// 三条修法一起用：
  ///   ① `handler` / `api` / `resolver` 在**第一个 await 之前**抓成局部变量
  ///      （`ref` 在 dispose 之后用会抛 `UnmountedRefException`，AGENTS §2.0.48）；
  ///   ② 不再用 `mounted` 否决"把封面交给 handler"——那件事与这个 State 的
  ///      生死无关（artUri 是按**曲目 id** 存的，播的不是它就不会被显示）；
  ///   ③ 只保留"不许 setState / 不许碰 widget"这层纪律（这里本来就没有）。
  Future<void> _attachCoverFor(int index) async {
    final handler = _handler;
    if (handler == null) return;
    final songs = widget.queue.isEmpty ? [widget.song] : widget.queue;
    if (index < 0 || index >= songs.length) return;
    final song = songs[index];
    final api = ref.read(audioApiProvider);
    final resolver = ref.read(albumCoverResolverProvider);
    await deliverCoverBytesToHandler(
      mediaId: song.id,
      load: () => _coverBytesFor(song, api: api, resolver: resolver),
      attach: handler.attachArtwork,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    final api = ref.watch(audioApiProvider);
    final info = ref.watch(audioInfoProvider).value;
    // R7：页面只与 handler 说话（handler 是播放状态的唯一来源）。
    final handler = ref.watch(audioHandlerProvider);
    final bitrate = ref.watch(audioTranscodeBitrateProvider);
    if (api == null) return const SizedBox.shrink();
    // S2 能力位降级：服务端缺 `SYNO.AudioStation.Stream` → **不提供内嵌播放**
    // （不生成流地址、不给播放按钮），只给一句话原因。模块其余部分照常。
    final canStream = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.audio, kAudioStreamApi);
    if (!canStream) {
      return Padding(
        key: const Key('as-stream-unavailable'),
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        // S2 收口：专指"缺 `AudioStation.Stream` → 内嵌播放不可用"，
        // 用更贴切的 key，而不是通用能力缺失文案。
        child: CapabilityDegradeHint(detail: t.asStreamUnavailable),
      );
    }
    // ★ 格式 → 流形态：WMA/ASF、APE、WavPack、DSD 等**已知不被系统解码器支持**
    //   的格式在这里被判成"服务端转码"（`method=transcode`），而 MP3/FLAC/AAC
    //   等照旧 `method=stream` 直传（**零误报**：判定清单见
    //   `lib/src/data/media/media_format_support.dart`）。
    final song = widget.song;
    final url = widget.urlFor(api, song, info, bitrate);
    // playing / 随机 / 循环 / 队列长度全部来自 handler 的 `playbackState` / `queue`
    final state = handler.playbackState.value;
    final playing = state.playing && handler.currentMediaId == song.id;
    final shuffleEnabled = state.shuffleMode != AudioServiceShuffleMode.none;
    final repeatMode = _audioRepeatOf(state.repeatMode);
    final queueLength = handler.queue.value.length;
    final failure = _failure;
    // ★ r642（DA236）：列表点歌 ⇒ 打开即起播（只一次；当前已经在放这首就不动）。
    if (widget.autoPlay &&
        !_autoPlayTried &&
        handler.currentMediaId != song.id) {
      _autoPlayTried = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _guard(() => _toggle(handler, url, false));
      });
    }
    // B11：睡眠定时到点 → 暂停播放 + 如实提示 + 复位（一次性）。
    //
    // ★ DA73（r413 **真机**撞到 / 当轮修）：`Duration.zero` 是**一次性状态**，
    // 而"复位"原来只写在这条 `ref.listen` 里 —— 到点时页面**没挂载**
    // （用户已经离开单曲页）就没人消费它：`state` 永远停在 `Duration.zero`，
    // 回到单曲页会看到一个**早已到点、实际没有任何定时器在跑**的假状态
    // （真机像素逐字 `Sleep timer · --` ＋ 仍在的 `Cancel`；
    // 证据 `docs/evidence-r413/device/r413_20_sleep_row_after_expiry_unmounted.png`）。
    // DA31 把"暂停"搬进了常驻控制器，这次把"复位"也补到**挂载时**消费一次；
    // 只有"当场看到它归零"的那一次弹提示（挂载时补消费**不弹**，避免旧事件重播）。
    void consumeSleepExpiry({required bool announce}) {
      _guard(handler.pause);
      ref.read(audioSleepTimerProvider.notifier).cancel();
      if (!announce || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          key: const Key('as-sleep-done'),
          content: Text(dataText('asSleepTimerDone', '睡眠定时到点，已暂停播放')),
        ),
      );
    }

    ref.listen<Duration?>(audioSleepTimerProvider, (_, next) {
      if (next == Duration.zero) consumeSleepExpiry(announce: true);
    });
    // 挂载时若已经是"到点"状态（⇒ 到点那一刻本页不在场）⇒ 静默复位。
    if (ref.watch(audioSleepTimerProvider) == Duration.zero) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(audioSleepTimerProvider) != Duration.zero) return;
        consumeSleepExpiry(announce: false);
      });
    }
    // 注意：`FieldBackdrop` 是**整页**背景（内部是 Stack，需要有限高），
    // 不能塞进 ListView 的子项里 —— 这里用设计卡片。
    final p = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      child: DecoratedBox(
        // 设计语言：这里是**一张卡片**（surface + line + 13 圆角），
        // 不再是 HUD 的玻璃切角面板 —— 与设置/电台两处已统一的几何一致。
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: p.line),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ★★★ r631：这块原来从"进度条"一直排到"Streaming URL 一大段"，
              //   真机首屏一半是排障信息（用户 2026-10-23 的原话：
              //   "很多音频技术参数没有必要罗列在界面上"）。
              //   现在只留三样：**进度**、**主控键**、**常用动作**；
              //   音质档位 / 转码说明 / 流地址 / 评分 / 15 个技术字段
              //   全部由 `widget.onInfo` 打开的面板承载。
              _progress(context, handler, song),
              const SizedBox(height: Gap.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    key: const Key('as-shuffle'),
                    tooltip: dataText('asShuffle', '随机播放'),
                    color: shuffleEnabled
                        ? scheme.primary
                        : DesignPalette.of(context).dim,
                    icon: const Icon(Icons.shuffle, size: 20),
                    onPressed: () => _guard(
                      () => handler.setShuffleMode(
                        shuffleEnabled
                            ? AudioServiceShuffleMode.none
                            : AudioServiceShuffleMode.all,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('as-prev'),
                    tooltip: dataText('asPrevious', '上一首'),
                    iconSize: 30,
                    icon: const Icon(Icons.skip_previous),
                    onPressed: queueLength > 1
                        ? () => _guard(handler.skipToPrevious)
                        : null,
                  ),
                  const SizedBox(width: Gap.sm),
                  // ★ r631：主播放键放大到 64×64（人机工程：单手拇指的主目标）。
                  //   旧版三个键都是默认 48，播放键和上一首一样大 ⇒ 看不出主次。
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: IconButton.filled(
                      key: const Key('as-play'),
                      tooltip: playing ? t.asPause : t.asPlay,
                      iconSize: 34,
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.onPrimary,
                      ),
                      // 三态（idle / loading / playing）：
                      //   * 起播中且**引擎还没说在播** → 转圈（`as-play-loading`），
                      //     而不是"按了没反应"；
                      //   * 引擎一旦报告在播 → 立刻切到暂停图标（**事实优先**，
                      //     不再因为 await 没回来而一直转圈）；
                      //   * 其余情况按 `playing` 显示播放/暂停（原有行为）。
                      icon: (_starting && !playing)
                          ? const SizedBox(
                              key: Key('as-play-loading'),
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(playing ? Icons.pause : Icons.play_arrow),
                      // 起播期间**禁止重复触发**（防连点开出两条播放请求）；
                      // 这个守卫与"显示什么图标"是两件事，别混。
                      onPressed: _starting
                          ? null
                          : () => _toggle(handler, url, playing),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  IconButton(
                    key: const Key('as-next'),
                    tooltip: dataText('asNext', '下一首'),
                    iconSize: 30,
                    icon: const Icon(Icons.skip_next),
                    onPressed: queueLength > 1
                        ? () => _guard(handler.skipToNext)
                        : null,
                  ),
                  IconButton(
                    key: const Key('as-repeat'),
                    tooltip: _repeatLabel(repeatMode),
                    color: repeatMode == AudioRepeatMode.off
                        ? DesignPalette.of(context).dim
                        : scheme.primary,
                    icon: Icon(
                      repeatMode == AudioRepeatMode.one
                          ? Icons.repeat_one
                          : Icons.repeat,
                      size: 20,
                    ),
                    onPressed: () => _guard(
                      () => handler.setRepeatMode(
                        _nextServiceRepeat(state.repeatMode),
                      ),
                    ),
                  ),
                ],
              ),
              // 队列位置（"第 2 / 12 首"）—— **给人看的**最小信息：
              // 知道自己在队列哪儿，不用打开队列页。键名保持 `as-queue-position`。
              if (widget.queue.length > 1) ...[
                const SizedBox(height: Gap.xxs),
                Center(
                  child: Text(
                    dataText('asQueuePosition', '{index}/{total}')
                        .replaceAll('{index}', '${widget.index + 1}')
                        .replaceAll('{total}', '${widget.queue.length}'),
                    key: const Key('as-queue-position'),
                    style: TextStyle(
                      fontSize: DesignType.labelSmallSize,
                      color: DesignPalette.of(context).dim,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: Gap.sm),
              // ★ r478（DA113）：三条最常做的动作原来**都不在这一页**——
              //   `播放队列` 在顶栏一个图标里，`投送`/`音效` 要退回首屏再从
              //   「更多列表」菜单里找（用户 r468 抱怨"常用动作藏在菜单里"）。
              //   r631 又补了第四条「歌曲信息」（技术参数的唯一入口）。
              _QuickActions(
                onQueue: widget.onQueue,
                onCast: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const AudioCastPage()),
                ),
                onEffects: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AudioEqualizerPage(),
                  ),
                ),
                onInfo: widget.onInfo,
              ),
              const SizedBox(height: Gap.xs),
              // B11：睡眠定时（纯客户端；官方 `widget/SleepTimer` 同定位）。
              const _SleepTimerRow(),
              // **失败分类提示**（含转码失败）：明确说是哪一类，并给"重试"。
              // ★ r631 起转码说明本身搬进了「歌曲信息」，但**失败**必须留在
              //   播放区：那是"按了没反应"的答案，藏进菜单等于没有。
              if (failure != null) ...[
                const SizedBox(height: Gap.sm),
                _StreamFailureNotice(
                  reason: failure,
                  // 可查询原因（真机 logcat 与 widget 测试都用它定位分支）
                  reasonTag: _failureReason,
                  transcode: _retryUsesTranscode,
                  onRetry: () => _toggle(handler, url, playing),
                ),
              ],
              const SizedBox(height: Gap.sm),
            ],
          ),
        ),
      ),
    );
  }

  /// 进度条（P0-5）：位置 / 总长都是**播放器**报的，可用时优先；
  /// 播放器还没报总长时退回到曲目元数据里的 `duration`（秒）。
  Widget _progress(
    BuildContext context,
    SynologyAudioHandler handler,
    AudioSongDto song,
  ) {
    return StreamBuilder<Duration?>(
      stream: handler.durationStream,
      initialData: handler.duration,
      builder: (context, durSnap) {
        final total =
            durSnap.data ??
            (song.duration > 0 ? Duration(seconds: song.duration) : null);
        final totalMs = total?.inMilliseconds ?? 0;
        return StreamBuilder<Duration>(
          stream: handler.positionStream,
          initialData: handler.position,
          builder: (context, posSnap) {
            final liveMs = (posSnap.data ?? Duration.zero).inMilliseconds
                .toDouble();
            final maxMs = totalMs > 0 ? totalMs.toDouble() : 0.0;
            final value = (_dragMs ?? liveMs).clamp(
              0.0,
              maxMs > 0 ? maxMs : liveMs,
            );
            // ★ r631：进度条重排成**两行**（Plexamp / Apple Music 的做法）：
            //   上面是一根细轨 + 大圆点，下面左右两端放「已播 / 剩余」。
            //   旧版三个元素挤一行，两端的读数各占 ~44pt ⇒ 拖动区在 393pt 屏上
            //   只剩 ~150pt，手指很难精确落到想跳的位置。
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 18,
                    ),
                  ),
                  child: Slider(
                    key: const Key('as-progress'),
                    min: 0,
                    max: maxMs > 0 ? maxMs : 1,
                    value: maxMs > 0 ? value.toDouble() : 0,
                    // ★ r633（**DA222**）：读屏不能只念百分比 —— 要念
                    //   「已播 1:23 / 共 4:00」。旧版没有格式化回调，TalkBack
                    //   读出来是 `63%`，用户听不出还剩多久。
                    // ★ r639（**DA232**）：同一处「0 秒不是未知」的坑，读屏这
                    //   一路**没跟上** DA231 —— 真机 dump 里进度条语义仍是
                    //   `— / 3:51`（看得见的写 `0:00`、听得见的念破折号）。
                    semanticFormatterCallback: (v) =>
                        '${_playedText(v)} / ${maxMs > 0 ? _fmtMs(maxMs) : '—'}',
                    onChanged: maxMs > 0
                        ? (v) => setState(() => _dragMs = v)
                        : null,
                    onChangeEnd: (v) {
                      setState(() => _dragMs = null);
                      _guard(
                        () => handler.seek(Duration(milliseconds: v.round())),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xxs),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        // ★ r638（**DA231**）：0 秒写 `0:00`，不再写破折号
                        //   （「在开头」≠「不知道播到哪儿」）。
                        asPositionText(
                          Duration(milliseconds: value.round()),
                        ),
                        key: const Key('as-progress-current'),
                        style: TextStyle(
                          fontSize: DesignType.labelSmallSize,
                          color: DesignPalette.of(context).dim,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(
                        // ★ r633（**DA222**）：右端改成**总长**（`1:23 / 4:00`）。
                        //
                        // 旧版写的是"负的剩余"`-2:37`：用户想知道"这歌一共多长"
                        // 得自己心算，而总长恰恰是点歌之前最想确认的数字
                        // （Plexamp / Apple Music 右端都是总长）。未知总长时
                        // 仍写 `—`，不编一个数。
                        maxMs > 0 ? _fmtMs(maxMs) : '—',
                        key: const Key('as-progress-remaining'),
                        style: TextStyle(
                          fontSize: DesignType.labelSmallSize,
                          color: DesignPalette.of(context).dim,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _repeatLabel(AudioRepeatMode mode) => switch (mode) {
    AudioRepeatMode.off => dataText('asRepeatOff', '顺序播放'),
    AudioRepeatMode.all => dataText('asRepeatAll', '循环全部'),
    AudioRepeatMode.one => dataText('asRepeatOne', '单曲循环'),
  };

  static AudioRepeatMode _audioRepeatOf(AudioServiceRepeatMode mode) =>
      switch (mode) {
        AudioServiceRepeatMode.one => AudioRepeatMode.one,
        AudioServiceRepeatMode.all => AudioRepeatMode.all,
        AudioServiceRepeatMode.none ||
        AudioServiceRepeatMode.group => AudioRepeatMode.off,
      };

  /// 循环按钮：`none → all → one → none`（与改动前的 off→all→one 顺序一致）。
  static AudioServiceRepeatMode _nextServiceRepeat(
    AudioServiceRepeatMode mode,
  ) => switch (mode) {
    AudioServiceRepeatMode.none ||
    AudioServiceRepeatMode.group => AudioServiceRepeatMode.all,
    AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
    AudioServiceRepeatMode.one => AudioServiceRepeatMode.none,
  };

  static String _fmtMs(double ms) => asDurationText((ms / 1000).round());

  /// ★ r639（**DA232**）：**位置**读数（0 秒写 `0:00`）。
  /// 总长/剩余仍走 [_fmtMs]（未知才写 `—`）—— 两把尺子不能混用。
  static String _playedText(double ms) =>
      asPositionText(Duration(milliseconds: ms.round()));

  /// 播放器调用不该把异常抛到 zone 外（起播失败已有分类提示兜底）。
  void _guard(Future<void> Function() action) {
    action().catchError((Object _) {});
  }

  /// A10 + B6：起播成功后记一次播放，并续播到上次位置。
  ///
  /// **顺序有讲究**：先读断点（[AudioListenHistoryController.markPlayed] 会把
  /// 断点清零），再记播放，最后 seek —— 反了就把断点自己抹掉了。
  Future<void> _recordPlay(SynologyAudioHandler handler) async {
    final history = ref.read(audioListenHistoryProvider.notifier);
    final resumeMs = await history.ensureResumePositionMs(widget.song.id);
    if (!mounted) return;
    await history.markPlayed(widget.song.id, title: widget.song.title);
    if (resumeMs <= 0 || !mounted) return;
    _guard(() => handler.seek(Duration(milliseconds: resumeMs)));
  }

  /// 每 5 秒把播放位置写进本地记录（B6 断点续播的数据来源）。
  ///
  /// 只在**真的在播**且位置 > 0 时写；不播就不写（免得把断点刷成 0）。
  Future<void> _savePosition() async {
    final handler = _handler;
    if (!mounted || handler == null || !handler.playbackState.value.playing) {
      return;
    }
    final posMs = handler.position.inMilliseconds;
    if (posMs <= 0) return;
    try {
      await ref
          .read(audioListenHistoryProvider.notifier)
          .markPosition(
            widget.song.id,
            title: widget.song.title,
            positionMs: posMs,
            durationMs: handler.duration?.inMilliseconds ?? 0,
          );
    } catch (_) {
      // 本地记录写失败绝不影响播放。
    }
  }

  /// 播放/暂停。失败时**分类**成 [MediaUnavailableReason] 并出明确提示
  /// （而不是把原始异常串塞进一句泛化的"播放失败"）。
  Future<void> _toggle(
    SynologyAudioHandler handler,
    String url,
    bool playing,
  ) async {
    final api = ref.read(audioApiProvider);
    if (api == null) return;
    final info = ref.read(audioInfoProvider).value;
    final bitrate = ref.read(audioTranscodeBitrateProvider);
    final mode = AudioStationApi.defaultStreamMode(widget.song, info: info);

    // ★ 取流鉴权**前置自检**（第 274 轮真机缺陷的回归保护）。
    //
    // 缺 `SynoToken` 时服务端回的是 HTTP 200 + `{"error":{"code":105}}`，
    // 原生播放器只报"没有 extractor 能读这个流"——**看不出是鉴权问题**。
    // 在进播放器之前先判一次，就能给出可归因的失败原因（而不是等 6 秒后
    // 一句含糊的"播放失败"）。
    final authProblem = audioMediaAuthProblem(
      url,
      sessionHasSid: api.sid.isNotEmpty,
      sessionHasSynoToken: api.hasSynoToken,
    );
    debugPrint(
      '[audio-station] play-start song=${widget.song.id} mode=${mode.name} '
      'transcode=${AudioStationApi.usesServerTranscode(mode)} '
      '${audioMediaAuthProblemReason(authProblem, sessionHasSynoToken: api.hasSynoToken)}',
    );
    if (authProblem != AudioMediaAuthProblem.none) {
      // 失败要能归因：原因码用功能自己的枚举（MediaUnavailableReason.id）
      trackOnceFailure(
        UsageModule.audio,
        UsageAction.play,
        objectType: 'song',
        reason: MediaUnavailableReason.sessionExpired,
      );
      if (mounted) {
        setState(() {
          _failure = MediaUnavailableReason.sessionExpired;
          _failureReason = audioMediaAuthProblemReason(
            authProblem,
            sessionHasSynoToken: api.hasSynoToken,
          );
          _retryUsesTranscode = AudioStationApi.usesServerTranscode(mode);
          debugPrint('[audio-song] failure reason=$_failureReason');
        });
      }
      return;
    }

    if (mounted) setState(() => _starting = true);
    try {
      if (playing) {
        await handler.pause();
      } else if (handler.currentMediaId == widget.song.id &&
          handler.tracks.isNotEmpty) {
        await handler.play();
      } else {
        final cap = info?.queueMax ?? AudioInfoDto.kPlayingQueueMaxFallback;
        final start = cap > 0 && widget.index >= cap
            ? cap - 1
            : widget.index;
        // R6：URL/元数据/封面都在这里解析好，handler 只负责播
        await handler.startQueue(
          await _tracks(api, info, bitrate),
          startIndex: start,
        );
        // 起播成功 → 队列 + 起点落盘（重启后可恢复）
        _persistQueue(start);
        // A10 记录一次播放 + B6 续播到上次位置
        await _recordPlay(handler);
        // 行为偏好：Audio Station 起播一次
        trackStart(UsageModule.audio, UsageAction.play, objectType: 'song');
        // 估算档：Audio Station 也是原生 ExoPlayer（绕过 Dart）
        unawaited(EstimatedTraffic.begin(TrafficModules.audio));
      }
      if (mounted) {
        setState(() {
          _failure = null;
          _failureReason = null;
          _retryUsesTranscode = AudioStationApi.usesServerTranscode(mode);
        });
      }
    } catch (e) {
      final reason = _reasonOf(e);
      debugPrint(
        '[audio-station] play-failure song=${widget.song.id} reason=${reason.name} error=$e',
      );
      trackOnceFailure(
        UsageModule.audio,
        UsageAction.play,
        objectType: 'song',
        reason: reason,
        error: e,
      );
      if (mounted) {
        setState(() {
          _failure = reason;
          _failureReason = reason.name;
          debugPrint('[audio-song] failure reason=${reason.name}');
          _retryUsesTranscode = AudioStationApi.usesServerTranscode(mode);
        });
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// 播放器给的失败 → 单曲页要显示的原因。
  ///
  /// 在 [classifyPlayerError] 之上补一条：这条曲目命中了[已知格式缺口]
  /// （WMA/ASF、APE…）而错误只是**笼统兜底**时，升级成
  /// [MediaUnavailableReason.formatUnsupported] —— 服务端转码也可能失败
  /// （转码服务没装 / 服务端没有该解码器），那时要说"格式/转码路径"而不是
  /// 泛化的"播放失败"。**只升级兜底**：会话/网络/服务端拒绝三类更具体，
  /// 原样保留。
  MediaUnavailableReason _reasonOf(Object error) {
    final reason = classifyPlayerError(error);
    if (reason != MediaUnavailableReason.decodeFailed) return reason;
    return mediaFormatGapOf(widget.song.path) != null
        ? MediaUnavailableReason.formatUnsupported
        : reason;
  }
}

/// 单曲页的播放失败提示：**分类**标题 + 解释 + 重试。
///
/// 文案与文件预览页同源（[mediaReasonText]）：会话过期说"重新登录"、网络中断说
/// "连不上"、服务端拒绝说"改取流形态"、格式/解码器解不了说"换条路" —— 四类
/// **绝不混成一句**（R5 真机教训，docs/media-streaming-diagnosis.md）。
class _StreamFailureNotice extends StatelessWidget {
  const _StreamFailureNotice({
    required this.reason,
    required this.transcode,
    required this.onRetry,
    this.reasonTag,
  });

  final MediaUnavailableReason reason;

  /// 机器可读的失败原因（渲染在 `as-play-failure-reason` 上，供测试/排查断言）。
  final String? reasonTag;

  /// 这次失败的 URL 是服务端转码流（重试按钮据此说明在重试哪条路）
  final bool transcode;

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final text = mediaReasonText(t, reason, MediaKind.audio);
    return Column(
      key: const Key('as-play-failure'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(
                text.title,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
            TextButton(
              key: const Key('as-play-retry'),
              onPressed: onRetry,
              child: Text(t.serviceRetry),
            ),
          ],
        ),
        const SizedBox(height: Gap.xxs),
        Text(
          text.detail,
          key: const Key('as-play-failure-detail'),
          style: theme.textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
        ),
        // ★★ r633（**DA219**）：诊断串**不许上屏**。
        //
        // 旧版把 `_failureReason`（`session_expired` / `network_failed` /
        // `stream_rejected`…）当一行小字画在提示下面，还塞进了 `Semantics`
        // —— 普通用户读到英文机器码，读屏用户听到的也是机器码，截图外发时
        // 还把排障信息一起带出去（AGENTS §2.0.47「诊断串不许当用户文案」）。
        // 它唯一的正当用途是**测试与 logcat** ⇒ 只留零尺寸可断言标记
        // `as-play-failure-reason:<tag>`，排障走 `debugPrint`。
        if (reasonTag != null && reasonTag!.isNotEmpty)
          KeyedSubtree(
            key: Key('as-play-failure-reason:$reasonTag'),
            child: const SizedBox.shrink(),
          ),
        if (transcode) ...[
          const SizedBox(height: Gap.xxs),
          // 转码失败不是"崩溃"，也不是原文件的锅 —— 如实标注重试的是转码流
          Text(
            dataText(
              'asTranscodeFailedHint',
              '重试的仍是服务端转码流；若持续失败，可在其它应用中打开原始文件',
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
          ),
        ],
      ],
    );
  }
}

/// 歌词（先取服务端歌词；**有时间轴就逐行高亮 + 自动滚动**，没有就如实平铺）。
///
/// 第 274 轮真机缺陷修复点：这里原来是 `SelectableText(整段歌词)` ——
/// 能滚但**不跟播放走**、也没有"当前这一句"。现在交给
/// [SyncedLyricsView]（与文件预览页同一套渲染），并：
///   * 有时间轴 → 逐行高亮 + 自动居中 + 点行跳转；
///   * 没时间轴 → 明确标注「无时间轴」（**不假装同步**）；
///   * 「同步歌词」按钮先查**本地缓存**（默认不联网），再走公开源
///     `lrclib.net`（`audio_lyrics.dart` 既有编排，含缓存与失败分类），
///     实在没有才退回服务端 `LyricsSearch`。
/// 服务端（NAS）搜歌词这一路的结论（DA55：两条联网来源统一说人话）。
enum LyricsServerOutcome {
  /// 服务端给了歌词正文
  found,

  /// 服务端答"没有"（`200 {}`，不是失败）
  none,

  /// 服务端这条路失败/超时（与"没有"分开）
  failed,
}

class _LyricsSection extends ConsumerStatefulWidget {
  const _LyricsSection({
    super.key,
    required this.song,
    required this.online,
    required this.searching,
    required this.onSearch,
  });

  final AudioSongDto song;
  final String? online;
  final bool searching;
  /// 服务端那一路（返回结论，由本组件统一报话）
  final Future<LyricsServerOutcome> Function() onSearch;

  @override
  ConsumerState<_LyricsSection> createState() => _LyricsSectionState();
}

class _LyricsSectionState extends ConsumerState<_LyricsSection> {
  /// 从公开源（lrclib）取回的歌词（null = 还没查/查不到）。
  LyricsLoadResult? _lookup;

  /// 正在查公开源。
  bool _busy = false;

  /// 只自动读一次**本地缓存**（不联网）。
  bool _cacheTried = false;

  /// ★ r472：自动匹配**带时间轴**歌词只尝试一次（用户 r468 的「歌词不随进度」）。
  ///
  /// 缘起：服务端很大方地给了**纯文本**歌词，而"能滚"要的是带时间轴的那一份；
  /// 以前必须由用户自己点一次「Search lyrics online」——他看到的自然是"歌词不滚"。
  /// 现在的口径：**先缓存、再静默补一次公开源**，只在拿到**带时间轴**的版本时替换屏上内容
  /// （纯文本不替换：用户眼前那份已经能读，换来换去只会让人以为内容在乱跳）。
  bool _autoTried = false;

  /// 歌词正文还没回来时的重试次数（最多 5 次 ≈ 1.5 s，之后放弃、不打扰）。
  int _autoRetries = 0;

  /// 查询条件：只用与歌有关的字段（**不含路径/凭据**）。
  LyricsQuery get _query => LyricsQuery(
    title: widget.song.title,
    artist: widget.song.artist,
    duration: widget.song.duration > 0
        ? Duration(seconds: widget.song.duration)
        : null,
    identity: widget.song.id,
  );

  @override
  void initState() {
    super.initState();
    // 打开页面**不联网**：只读本地缓存（`audio_lyrics.dart` 的约定）。
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_tryCache()));
  }

  Future<void> _tryCache() async {
    if (_cacheTried || !mounted) return;
    _cacheTried = true;
    final q = _query;
    if (q.isEmpty) return;
    try {
      final cached = await ref.read(mediaLyricsLookupProvider).fromCache(q);
      if (!mounted) return;
      if (cached.hasLyrics) setState(() => _lookup = cached);
    } catch (_) {
      // 缓存读失败绝不影响页面（当作没有）。
    }
    if (!mounted) return;
    unawaited(_autoSynced());
  }

  /// 静默补一次公开源，**只**为了拿带时间轴的那份（失败不打扰、不弹任何提示）。
  ///
  /// 三条硬约束（都来自已有的血教训）：
  ///   ① **不许**把用户明确选过的版本改回自动排名（DA69）；
  ///   ② 只在屏上**确实没有**时间轴时才发这次请求（已经有就不要多打一次网络）；
  ///   ③ 失败/没找到一律静默 —— 页面仍然显示原来那份，不出现"搜索失败"这种噪声。
  Future<void> _autoSynced() async {
    if (_autoTried || !mounted) return;
    if (_busy) return;
    final q = _query;
    if (q.isEmpty) return;
    // 歌词正文是**异步**取回来的（`audioLyricsProvider`）：第一帧还是 null。
    // 这时候判断"有没有时间轴"必然判错 ⇒ 等它回来再看，最多重试几次。
    final text = ref.read(audioLyricsProvider(widget.song.id)).value;
    if (text == null) {
      if (_autoRetries >= 5) return;
      _autoRetries++;
      Future<void>.delayed(
        const Duration(milliseconds: 300),
        () => mounted ? unawaited(_autoSynced()) : null,
      );
      return;
    }
    _autoTried = true;
    if (parseLrc(text).timed) return;
    if (_lookup?.document?.timed ?? false) return;
    if (_lookup?.chosen != null) return; // 用户选过的，别动
    try {
      final result = await ref.read(mediaLyricsLookupProvider).search(q);
      if (!mounted) return;
      // 只认"带时间轴"的那份；纯文本保持原样（换源不换内容才是要点）。
      if (!(result.document?.timed ?? false)) return;
      setState(() => _lookup = result);
    } catch (_) {
      // 静默：这是增益，不是功能。
    }
  }

  /// 用户点「同步歌词」：**先走本来的服务端搜索**，再尝试公开的带时间轴歌词源。
  ///
  /// 顺序很讲究（第 274 轮改过一次）：
  ///   ① 用户点的这个按钮**本来就是**"搜歌词"，服务端 `LyricsSearch` 是既有行为，
  ///      必须**同步**发起（不能先等一个可能很慢/可能失败的公开源，
  ///      否则用户看到的是"点了半天没反应"）；
  ///   ② 公开源（lrclib）**只做增益**：它给的歌词可能带时间轴，那才谈得上
  ///      滚动 + 高亮；拿到了就替换显示，拿不到就保持服务端那份纯文本。
  /// 两路互不连累：公开源异常一律吞掉（服务端那一路已经在走）。
  Future<void> _searchSynced() async {
    if (_busy) return;
    final q = _query;
    setState(() => _busy = true);
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    // ① 服务端搜索（既有行为，纯文本、没有时间轴）—— **先不报话**（DA55）
    final server = await widget.onSearch();
    if (!mounted) return;
    // ② 公开源（带时间轴的增益）
    var publicFound = false;
    try {
      final lookup = ref.read(mediaLyricsLookupProvider);
      // ★ DA68（r411 真机撞到）：用户**明确点了**「Search lyrics online」
      // ⇒ 必须真的联网重搜，**不许先探缓存再短路**。
      // 改前这里是「`fromCache()` 命中就直接用缓存」⇒ 在这首歌**已经有歌词**
      // 这个最常见的情形下：① 按钮点下去屏上毫无变化（既不重搜、也不报话）；
      // ② `candidates` 永远是空的 ⇒ 上一轮刚补的「换一个歌词版本」入口
      // **在真机上根本出不来**（同轮真机 dump 逐字为证）。
      // 打开页面时的"不联网"契约由 `_tryCache()` 负责，与此处无关。
      final result = await lookup.search(q);
      // ★ DA69（r411 真机撞到）：重搜**不许把用户明确选过的版本静默改回**
      // 自动排名那份。真机读数：16:18 用户在候选里选了
      // `De Nederlandse Top 40 Van 2000`（缓存文件逐字可证），16:23 只点了一次
      // 这个按钮 ⇒ 屏上与**缓存**都被改回自动排名第一的 `Hitbreaker 2001/2 - CD2`
      // （`docs/evidence-r411/device/r411_after_search_lyrics-78a9676d.json`）。
      // 判据：屏上那份**还在**新候选里 ⇒ 继续用它（走 `choose` 把它写回缓存）。
      final kept = _lookup?.chosen;
      var effective = result;
      if (kept != null &&
          result.hasLyrics &&
          result.candidates.any((c) => c.id == kept.id)) {
        final again = await lookup.choose(
          q,
          kept,
          candidates: result.candidates,
        );
        if (again.hasLyrics) effective = again;
      }
      publicFound = effective.hasLyrics;
      if (!mounted) return;
      setState(() {
        if (effective.hasLyrics || _lookup == null) {
          _lookup = effective;
        } else {
          // 新搜到的一条正文都没有：**屏上原有的歌词不许弄丢**，
          // 但候选要留下来（否则"换版本"入口又没了）。
          _lookup = _lookup!.withCandidates(effective.candidates);
        }
      });
    } catch (_) {
      // 公开源失败无所谓：服务端那一路照旧（①已经发起）
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    // ③ 统一报话（DA55）：**先看屏上到底有没有歌词**，有就一句都不报 ——
    // 报"没找到"之前必须确认屏上真的空着（否则就是撒谎）。
    final async = ref.read(audioLyricsProvider(widget.song.id));
    final serverText = (async.value ?? '').isNotEmpty
        ? async.value!
        : (widget.online ?? '');
    if (!_displayed(parseLrc(serverText)).doc.isEmpty) return;
    if (server == LyricsServerOutcome.found || publicFound) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          server == LyricsServerOutcome.failed
              ? t.asLyricsSearchFailed
              : t.asLyricsSearchEmpty,
        ),
      ),
    );
  }

  /// 打开全屏歌词（r631）。
  void _openFullLyrics(
    LrcDocument doc,
    ({LrcDocument doc, LyricCandidate? chosen, bool fromCache}) shown,
    SynologyAudioHandler handler,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LyricsFullPage(
          song: widget.song,
          document: doc,
          chosen: shown.chosen,
          fromCache: shown.fromCache,
          position: handler.positionStream,
          onSeek: (at) => unawaited(handler.seek(at)),
          handler: handler,
        ),
      ),
    );
  }

  /// 两份来源里挑**更好的那一份**：有时间轴的优先（那才能真的滚动+高亮）。
  ///
  /// ★ DA66（r411）：返回的不只是文档，还有**它的出处** —— 署名行必须跟着
  /// "屏上正在显示的那一份"写。反例（这条就是不加它会犯的错）：
  /// 公开源取回的是**无时间轴**的一份，而服务端那份**有时间轴** ⇒
  /// 屏上显示的是**服务端**的歌词，署名却写"来自 lrclib" ⇒ 又变成撒谎。
  ({LrcDocument doc, LyricCandidate? chosen, bool fromCache}) _displayed(
    LrcDocument server,
  ) {
    final fetched = _lookup?.document;
    final chosen = _lookup?.chosen;
    final cached = _lookup?.fromCache ?? false;
    if (fetched != null && fetched.timed) {
      return (doc: fetched, chosen: chosen, fromCache: cached);
    }
    if (server.timed) {
      // 屏上是**服务端**那份 ⇒ 署名只能是 NAS 歌词库
      return (doc: server, chosen: null, fromCache: false);
    }
    if (fetched != null && !fetched.isEmpty) {
      return (doc: fetched, chosen: chosen, fromCache: cached);
    }
    return (doc: server, chosen: null, fromCache: false);
  }

  /// ★ DA67（r411）：用户在候选里**明确选一个版本**。
  ///
  /// 文件预览页（`media_audio_stage.dart`）早就有这条路；单曲页以前把
  /// `LyricsLoadResult.candidates` 拿到了却**没有任何入口** —— 同一个「歌词」
  /// 功能两个入口能力不同（AGENTS §2.0.8 ④的同族）。
  Future<void> _pickCandidate(LyricCandidate candidate) async {
    final candidates = _lookup?.candidates ?? const <LyricCandidate>[];
    final lookup = ref.read(mediaLyricsLookupProvider);
    if (mounted) setState(() => _busy = true);
    final result = await lookup.choose(
      _query,
      candidate,
      candidates: candidates,
    );
    if (!mounted) return;
    setState(() {
      _lookup = result;
      _busy = false;
    });
  }

  /// 选歌词版本的底部弹层（歌名 / 歌手 / 专辑 / 时长，如实来自源站）。
  Future<void> _showCandidateSheet() async {
    final candidates = _lookup?.candidates ?? const <LyricCandidate>[];
    if (candidates.isEmpty) return;
    final chosenId = _lookup?.chosen?.id;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: ListView.builder(
            key: const Key('as-lyrics-candidates'),
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (context, i) {
              final c = candidates[i];
              final selected = c.id == chosenId;
              return DesignRowTile(
                key: Key('as-lyrics-candidate-${c.id}'),
                selected: selected,
                leading: Icon(
                  c.hasSynced ? Icons.lyrics_outlined : Icons.subject_rounded,
                  color: selected ? theme.colorScheme.primary : DesignPalette.of(context).dim,
                ),
                title: Text(
                  c.trackName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    if (c.artistName.isNotEmpty) c.artistName,
                    if (c.albumName.isNotEmpty) c.albumName,
                    c.durationLabel(),
                    if (!c.hasSynced) dataText('audioLyricsNoTimeline', '不会自动滚动'),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_pickCandidate(c));
                },
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final async = ref.watch(audioLyricsProvider(widget.song.id));
    final handler = ref.watch(audioHandlerProvider);
    final serverText = (async.value ?? '').isNotEmpty
        ? async.value!
        : (widget.online ?? '');
    final serverDoc = parseLrc(serverText);
    // ★ DA66：`shown` 同时带出**出处**（doc / chosen / fromCache 三者必须同源）
    final shown = _displayed(serverDoc);
    final doc = shown.doc;

    final searchButton = TextButton.icon(
      key: const Key('as-lyrics-search'),
      onPressed: (widget.searching || _busy) ? null : () => unawaited(_searchSynced()),
      icon: (widget.searching || _busy)
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.travel_explore, size: 16),
      label: Text(t.asLyricsSearch),
    );

    // ★ DA67：单曲页也必须有「换一个歌词版本」—— 与文件预览页同一个入口语义
    // （判据同样是 `hasCandidates`，不是"看有没有 chosen"）。
    final pickButton = (_lookup?.hasCandidates ?? false)
        ? TextButton.icon(
            key: const Key('as-lyrics-pick'),
            onPressed: _busy ? null : () => unawaited(_showCandidateSheet()),
            icon: const Icon(Icons.library_music_outlined, size: 16),
            label: Text(audioLyricsPickText()),
          )
        : null;

    final Widget body;
    if (async.isLoading && doc.isEmpty) {
      body = const Padding(
        padding: EdgeInsets.all(Gap.md),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (doc.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        child: Row(
          children: [
            Expanded(
              child: Text(
                t.asLyricsEmpty,
                key: const Key('as-lyrics-empty'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            searchButton,
          ],
        ),
      );
    } else {
      body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ★ DA66（r411）：**先写清楚这是谁的歌词**，再显示正文。
            // 判据取 `shown`（正在显示的那一份的出处），不是"最近搜到的"。
            LyricsAttributionLine(
              document: doc,
              chosen: shown.chosen,
              fromCache: shown.fromCache,
              textKey: const Key('as-lyrics-attribution'),
            ),
            // 有时间轴 = 真的跟着播放滚；没时间轴 = 只说"无时间轴"，绝不假装。
            //
            // 位置必须走 `positionStream`：`ref.watch(audioHandlerProvider)`
            // 只在 handler 实例变化时重建，位置**不会**触发本页重建
            // （这也是"歌词不滚"的一个隐藏成因——读一次快照就永远停在第 0 秒）。
            StreamBuilder<Duration>(
              stream: handler.positionStream,
              initialData: handler.position,
              builder: (context, snapshot) => SyncedLyricsView(
                key: const Key('as-lyrics'),
                document: doc,
                position: snapshot.data ?? Duration.zero,
                onSeek: doc.timed ? (at) => unawaited(handler.seek(at)) : null,
                lineKeyPrefix: 'as-lyrics-line',
                // ★ r631：歌词是这一页的**主角之一**，给到 320（≈11 行），
                //   而不是挤成 260（≈9 行）。真机 393pt 屏上 320 仍然
                //   让"播放器 + 歌词"两块都在一屏里可滚到。
                height: 320,
              ),
            ),
            const SizedBox(height: Gap.xs),
            // ★ r403（DA51）：**不再**在这里重复那句提示 ——
            // 上面的 `SyncedLyricsView`（`audio_lyrics_view.dart:290`）在"没时间轴"
            // 时已经原样印过一次（同一个 `audioLyricsPlainTextHintText()`），
            // 这里再印一次真机像素上就是**同一句话出现两遍**
            // （证据 `docs/evidence-r403/device/r403_02_lyrics_success.png` +
            //  同帧 XML：两个相邻的 hint 文本节点）。
            // ★ r471 真机：两个按钮并列时 `Row(Spacer + …)` 会**横向溢出** ——
            //   真机逐字：`Search lyrics o…` 被屏幕右缘切掉，点不到也读不全。
            //   换成 `Wrap`：放得下就一行靠右，放不下自动换行（窄屏也给完整文案）。
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: Gap.md,
                runSpacing: Gap.xs,
                children: [
                  if (pickButton != null) pickButton,
                  searchButton,
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ★ r631：**全屏歌词**（Plexamp 的通行做法）。用户抱怨的
        //   "字幕/歌词同步滚动"在 260px 的小窗里很容易被当成"没在动"——
        //   给一个整屏、字号更大、当前行居中的视图，滚动就一眼可见。
        //
        // ★★ r633（DA220）：入口从「右上角 18dp 图标」改成**整行可点**。
        //   真机现场：那个图标是整张卡里最小的目标（实际点击区 ~24dp），
        //   按 3 次都没点中；而"打开全屏歌词"其实是这个卡片最想要的动作。
        //   现在标题整行都是热区（≥48dp 高），右侧写明"全屏歌词"而不是
        //   只留一个图标 —— 图标不再承担"唯一的发现性"。
        if (doc.isEmpty)
          Row(
            children: [Expanded(child: DesignSectionHeader(t.asLyrics))],
          )
        else
          InkWell(
            key: const Key('as-lyrics-expand'),
            onTap: () => _openFullLyrics(doc, shown, handler),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xs),
              child: Row(
                children: [
                  Expanded(child: DesignSectionHeader(t.asLyrics)),
                  Text(
                    dataText('asLyricsFullscreen', '全屏歌词'),
                    style: TextStyle(
                      fontSize: 12,
                      color: DesignPalette.of(context).muted,
                    ),
                  ),
                  const SizedBox(width: Gap.xxs),
                  Icon(
                    Icons.open_in_full,
                    size: 16,
                    color: DesignPalette.of(context).muted,
                  ),
                ],
              ),
            ),
          ),
        body,
      ],
    );
  }
}

/// 全屏歌词页（r631）—— 大字、当前行居中、点哪唱哪。
///
/// 为什么单独一页而不是"把卡片拉高"：手机竖屏上歌词需要**整屏高度**才谈得上
/// "跟着唱"；卡片高度受限，用户很容易读成"歌词没动"。这一页与卡片共用同一个
/// `SyncedLyricsView`（§2.0.8 ④：同一份文档只走一个阅读器），只是给满高度、
/// 放大行高。
class _LyricsFullPage extends StatefulWidget {
  const _LyricsFullPage({
    required this.song,
    required this.document,
    required this.chosen,
    required this.fromCache,
    required this.position,
    required this.onSeek,
    this.handler,
  });

  final AudioSongDto song;
  final LrcDocument document;
  final LyricCandidate? chosen;
  final bool fromCache;
  final Stream<Duration> position;
  final ValueChanged<Duration> onSeek;

  /// 只用来放**播放/暂停**（全屏歌词里最需要的那一个键）；
  /// 其余控制留在单曲页，免得这里变成"第二套播放器"。
  final SynologyAudioHandler? handler;

  @override
  State<_LyricsFullPage> createState() => _LyricsFullPageState();
}

class _LyricsFullPageState extends State<_LyricsFullPage> {
  /// ★ r633（DA220）：字号倍率。默认 1.0，范围 0.85–1.6（再大一行放不下）。
  double _scale = 1.0;

  AudioSongDto get song => widget.song;
  LrcDocument get document => widget.document;
  LyricCandidate? get chosen => widget.chosen;
  bool get fromCache => widget.fromCache;
  Stream<Duration> get position => widget.position;
  ValueChanged<Duration> get onSeek => widget.onSeek;
  SynologyAudioHandler? get handler => widget.handler;

  void _zoom(double delta) {
    final next = (_scale + delta).clamp(0.85, 1.6);
    if (next == _scale) return;
    setState(() => _scale = next);
  }

  @override
  Widget build(BuildContext context) {
    final p = DesignPalette.of(context);
    return DesignScaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(song.title.isNotEmpty ? song.title : song.path, maxLines: 1),
            if (song.artist.isNotEmpty)
              Text(
                song.artist,
                style: TextStyle(fontSize: 12, color: p.muted),
              ),
          ],
        ),
        actions: [
          // ★ r633（DA220）：字号可调 —— 老花/近视/远看（放支架上）都能读。
          IconButton(
            key: const Key('as-lyrics-font-smaller'),
            tooltip: dataText('asLyricsFontSmaller', '缩小字号'),
            icon: const Icon(Icons.text_decrease, size: 20),
            onPressed: _scale <= 0.85 ? null : () => _zoom(-0.15),
          ),
          IconButton(
            key: const Key('as-lyrics-font-larger'),
            tooltip: dataText('asLyricsFontLarger', '放大字号'),
            icon: const Icon(Icons.text_increase, size: 20),
            onPressed: _scale >= 1.6 ? null : () => _zoom(0.15),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
            child: LyricsAttributionLine(
              document: document,
              chosen: chosen,
              fromCache: fromCache,
              textKey: const Key('as-lyrics-full-attribution'),
            ),
          ),
          Expanded(
            // ★ r631 真机撞到（DA213）：这里原来写死 `height: double.infinity`
            //   ⇒ `SyncedLyricsView` 的顶部留白 `height/2` 变成 **无穷大**，
            //   整屏歌词被推到看不见的地方（真机像素：只有署名两行，正文全空）。
            //   高度必须来自**布局给的真实值**，不能用无穷。
            child: Padding(
              // ★ r631 真机：不留横边距时正文贴到屏幕最左（第一列像素被裁）
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: LayoutBuilder(
              builder: (context, constraints) => StreamBuilder<Duration>(
                stream: position,
                // ★ r633（DA220）：暂停中进来时位置流**不会再推新值**
                //   ⇒ 没有 initialData 就只能从 0 开始（屏上停在第一句）。
                initialData: handler?.position,
                builder: (context, snapshot) => SyncedLyricsView(
                  key: const Key('as-lyrics-full'),
                  document: document,
                  position: snapshot.data ?? Duration.zero,
                  onSeek: document.timed ? onSeek : null,
                  lineKeyPrefix: 'as-lyrics-full-line',
                  height: constraints.maxHeight.isFinite
                      ? constraints.maxHeight
                      : 480,
                  // 行高跟着字号走，否则字大了会挤在一起
                  lineHeight: 38 * _scale,
                  fontScale: _scale,
                  // 长按复制 ⇒ 就地给一条非阻塞反馈
                  onCopied: (text) {
                    if (!mounted) return;
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      SnackBar(
                        content: Text(dataText('asLyricsCopied', '已复制这一句')),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ),
              ),
            ),
          ),
          if (handler != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.sm),
              child: StreamBuilder<PlaybackState>(
                stream: handler!.playbackState,
                initialData: handler!.playbackState.value,
                builder: (context, snap) {
                  final playing = snap.data?.playing ?? false;
                  return Row(
                    children: [
                      IconButton(
                        key: const Key('as-lyrics-full-toggle'),
                        tooltip: playing ? context.t.asPause : context.t.asPlay,
                        icon: Icon(
                          playing ? Icons.pause_circle : Icons.play_circle,
                          size: 44,
                          color: p.primary,
                        ),
                        onPressed: () =>
                            playing ? handler!.pause() : handler!.play(),
                      ),
                      const Spacer(),
                      StreamBuilder<Duration>(
                        stream: position,
                        builder: (context, pos) => Text(
                          // ★ r639（**DA232**）：全屏歌词头上的「播到哪儿」
                          //   同样把 0 秒画成破折号（真机 dump 读数 `—`）。
                          // ★ r643（**DA238**）：单曲页写着 `3:02 / 3:52`，全屏歌词
                          //   只写 `3:02` —— 同一件事两个页面两种读数，人在全屏里
                          //   根本不知道还剩多久。总时长**知道才写**（服务端没给就
                          //   不编一个 `0:00` 尾巴）。
                          song.duration > 0
                              ? '${asPositionText(pos.data ?? Duration.zero)}'
                                    ' / ${asDurationText(song.duration)}'
                              : asPositionText(pos.data ?? Duration.zero),
                          key: const Key('as-lyrics-full-position'),
                          style: TextStyle(
                            fontSize: 12,
                            color: p.muted,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// A19：在线标签段（`Tag.list` **v1**，`entry.cgi`）。
///
/// **必须**同时给 `album` 与 `album_artist`（真机逐参数验证：缺一个就 101；
/// 见 `docs/audio-gaps-implementation-report.md` §A19）。因此专辑/专辑艺术家
/// 任一为空时**不给入口**（发了也只会失败）。
///
/// 手动触发：默认只显示一个按钮，点开才查（不平白联网）。
/// 查不到 ≠ 查失败：两者文案分开（`AudioTagLookupState.failed`）。
class _OnlineTagSection extends ConsumerStatefulWidget {
  const _OnlineTagSection({required this.song});

  final AudioSongDto song;

  @override
  ConsumerState<_OnlineTagSection> createState() => _OnlineTagSectionState();
}

class _OnlineTagSectionState extends ConsumerState<_OnlineTagSection> {
  bool _requested = false;

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    // 缺 album / album_artist 就没有可查的键（`Tag.list` 两个都必填）。
    if (song.album.isEmpty || song.albumArtist.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _MetaLine(
                dataText('asOnlineTag', '在线标签'),
                key: const Key('as-tag-title'),
              ),
              const Spacer(),
              TextButton.icon(
                key: const Key('as-tag-search'),
                icon: const Icon(Icons.travel_explore, size: 18),
                label: Text(
                  _requested
                      ? dataText('asTagRefresh', '重新查询')
                      : dataText('asTagQuery', '查询'),
                ),
                onPressed: () {
                  if (_requested) {
                    ref.invalidate(
                      audioTagLookupProvider((
                        album: song.album,
                        albumArtist: song.albumArtist,
                      )),
                    );
                  }
                  setState(() => _requested = true);
                },
              ),
            ],
          ),
          if (!_requested)
            Text(
              dataText('asTagHint', '联网查询该专辑的标签信息（Discogs）'),
              key: const Key('as-tag-hint'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
            )
          else
            _results(context),
        ],
      ),
    );
  }

  Widget _results(BuildContext context) {
    final song = widget.song;
    final async = ref.watch(
      audioTagLookupProvider((album: song.album, albumArtist: song.albumArtist)),
    );
    return async.when(
      loading: () => const Padding(
        key: Key('as-tag-loading'),
        padding: EdgeInsets.symmetric(vertical: Gap.md),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _failedText(describeAudioError(e)),
      data: (state) {
        if (state.failed) {
          return _failedText(state.errorText ?? '');
        }
        final items = state.result?.items ?? const <AudioTagItemDto>[];
        if (items.isEmpty) {
          return Text(
            key: const Key('as-tag-empty'),
            dataText('asTagEmpty', '没有查到在线标签'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
          );
        }
        return Column(
          key: const Key('as-tag-list'),
          children: [
            for (final item in items) _TagTile(item: item),
          ],
        );
      },
    );
  }

  Widget _failedText(String detail) => Text(
    key: const Key('as-tag-failed'),
    dataText('asTagFailed', '在线标签查询失败：{e}').replaceAll('{e}', detail),
    style: Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).danger),
  );
}

class _TagTile extends StatelessWidget {
  const _TagTile({required this.item});

  final AudioTagItemDto item;

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      if (item.albumArtist.isNotEmpty) item.albumArtist,
      if (item.year.isNotEmpty) item.year,
      ...item.genres,
    ].join(' · ');
    return DesignRowTile(
      key: Key('as-tag-item-${item.album}'),
      contentPadding: EdgeInsets.zero,
      // DA86（r427）：标签行的封面同样走鉴权字节通道（原来 `Image.network`
      // 在本环境恒不显示 —— 主机名不匹配 ⇒ 握手失败）。一个实现，见
      // `AudioCoverImage`。
      leading: item.cover.isEmpty
          ? const Icon(Icons.public, size: 20)
          : AudioCoverImage(
              key: Key('as-tag-cover-${item.album}'),
              identity: 'tag:${item.album}',
              url: item.cover,
              size: 40,
              fallbackIcon: Icons.public,
            ),
      title: Text(
        item.album,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium,
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
      // `release_url` 只是展示（不打开外部浏览器 —— 本模块不外跳）。
      trailing: item.releaseUrl.isEmpty
          ? null
          : const Icon(Icons.link, size: 16),
    );
  }
}

/// 字段区：逐条列出有值的元数据（缺字段就不显示 —— doc §5 U8）。
/// 「歌曲信息」面板（r631）—— 用户要求"技术参数收在某一个菜单项里"的那个菜单。
///
/// 面板内**顺序**按"先想知道的、后排查用的"排：
///   ① 音质档位（会影响听感）② 评分 ③ 技术字段（15 行）
///   ④ 流地址（打码 + 复制）⑤ 在线标签（联网动作放最后，不平白触发）。
///
/// ★ 所有既有 `Key` 原样保留（`as-quality-row` / `as-quality-<bps>` /
///   `as-stream-url` / `as-copy-url` / `as-stream-url-masked-note` /
///   `as-transcode-hint`）—— 旧用例只要先打开面板就仍然成立。
class _SongInfoSheet extends StatelessWidget {
  const _SongInfoSheet({
    required this.song,
    required this.urlFor,
    required this.initialBitrate,
    required this.transcode,
    required this.controller,
  });

  final AudioSongDto song;

  /// 按档位现算流地址（与播放器共用同一份缓存）。
  final String Function(int bitrate) urlFor;
  final int initialBitrate;

  /// 走的是服务端转码（说清楚"你听到的不是原文件"）。
  final bool transcode;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final p = DesignPalette.of(context);
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.xl),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                // ★ r631：用**已登记**的 `t.asSongInfo`（`dataText` 里没有这条
                //   映射 ⇒ 英文界面会回落中文，正是 DA212 的同一类坑）。
                t.asSongInfo,
                key: const Key('as-song-info-title'),
                style: TextStyle(
                  fontSize: DesignType.titleSmallSize,
                  fontWeight: FontWeight.w600,
                  color: p.text,
                ),
              ),
            ),
            IconButton(
              key: const Key('as-song-info-close'),
              tooltip: t.asClosePlayer,
              icon: const Icon(Icons.close, size: 20),
              color: p.muted,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
        const SizedBox(height: Gap.xs),
        const _QualityRow(),
        const SizedBox(height: Gap.md),
        _RatingSection(song: song),
        const SizedBox(height: Gap.md),
        _FieldSection(song: song),
        const SizedBox(height: Gap.md),
        _StreamUrlBlock(urlFor: urlFor, transcode: transcode),
        const SizedBox(height: Gap.md),
        _OnlineTagSection(song: song),
      ],
    );
  }
}

/// 转码音质档位（128/192/320 kbps）。**始终可选**：直传时档位不影响原文件，
/// 一旦命中服务端转码（mp3）就按所选档位发 `bitrate`（官方三档，审计 §1.7）。
///
/// r631 起从播放区搬到这里（用户：技术参数收进菜单）。
class _QualityRow extends ConsumerWidget {
  const _QualityRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bitrate = ref.watch(audioTranscodeBitrateProvider);
    // ★ r474：标签原来与三档 chip 挤在**同一行**，393pt 真机上第三档（320 kbps）
    //   被右缘切掉一半（虽然可横向滑，但没有任何"还能滑"的提示 ⇒ 用户读到的是
    //   "只有两档"）。把标签提到**上面一行**，三档 chip 拿满宽度 ⇒ 一眼看全。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PanelLabel(dataText('asQuality', '音质')),
        const SizedBox(height: Gap.xxs),
        SingleChildScrollView(
          key: const Key('as-quality-row'),
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final bps in const [128000, 192000, 320000])
                Padding(
                  padding: const EdgeInsets.only(right: Gap.xs),
                  child: ChoiceChip(
                    key: Key('as-quality-$bps'),
                    label: Text(
                      dataText('asQualityKbps', '{kbps} kbps').replaceAll(
                        '{kbps}',
                        '${bps ~/ 1000}',
                      ),
                    ),
                    selected: bitrate == bps,
                    onSelected: (_) => ref
                        .read(audioTranscodeBitrateProvider.notifier)
                        .select(bps),
                  ),
                ),
            ],
          ),
        ),
        if (bitrate != 320000)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xxs),
            child: Text(
              dataText(
                'asQualityHint',
                '仅在服务端转码时生效；直传播放的是原文件',
              ),
              style: TextStyle(fontSize: 11.5, color: DesignPalette.of(context).dim),
            ),
          ),
      ],
    );
  }
}

/// 流地址（打码）+ 复制 + 转码说明（r631 从播放区搬进「歌曲信息」）。
class _StreamUrlBlock extends ConsumerWidget {
  const _StreamUrlBlock({required this.urlFor, required this.transcode});

  /// 按**当前档位**现算（档位是 provider，改了要立刻反映到这条 URL 上）。
  final String Function(int bitrate) urlFor;
  final bool transcode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final p = DesignPalette.of(context);
    final url = urlFor(ref.watch(audioTranscodeBitrateProvider));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _PanelLabel(t.asStreamUrl),
            const Spacer(),
            IconButton(
              key: const Key('as-copy-url'),
              tooltip: t.asCopy,
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(t.asStreamUrlCopiedWithToken)),
                );
              },
            ),
          ],
        ),
        SelectableText(
          redactStreamUrl(url),
          key: const Key('as-stream-url'),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: p.dim),
        ),
        const SizedBox(height: Gap.xxs),
        Text(
          t.asStreamUrlMaskedNote,
          key: const Key('as-stream-url-masked-note'),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.dim),
        ),
        // 走了转码就**如实说**：用户看到的是 mp3/wav 流，别让人以为放的是原文件。
        if (transcode) ...[
          const SizedBox(height: Gap.xs),
          Text(
            dataText(
              'asTranscodeFallbackHint',
              '该格式系统解码器通常不支持，已自动改用服务端转码（mp3/wav）播放',
            ),
            key: const Key('as-transcode-hint'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.dim),
          ),
        ],
      ],
    );
  }
}

class _FieldSection extends StatelessWidget {
  const _FieldSection({required this.song});

  final AudioSongDto song;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final rows = <(String, String)>[
      (t.asFieldArtist, song.artist),
      (t.asFieldAlbum, song.album),
      (t.asFieldAlbumArtist, song.albumArtist),
      (t.asFieldComposer, song.composer),
      (t.asFieldGenre, song.genre),
      (t.asFieldYear, song.year > 0 ? '${song.year}' : ''),
      (t.asFieldTrack, song.track > 0 ? '${song.track}' : ''),
      (t.asFieldDisc, song.disc > 0 ? '${song.disc}' : ''),
      (t.asFieldDuration, song.duration > 0 ? song.durationText : ''),
      (t.asFieldBitrate, song.bitrateText),
      (t.asFieldFrequency, asFrequencyText(song.frequency)),
      (t.asFieldChannels, asChannelText(song.channel)),
      (t.asFieldFilesize, song.filesize > 0 ? asHumanBytes(song.filesize) : ''),
      (t.asFieldCodec, song.codec),
      (t.asFieldPath, song.path),
    ];
    final visible = rows.where((r) => r.$2.isNotEmpty).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    // ★ r476：15 行小字原来是"贴边裸表格"，与页面上其它卡片不是一套语言。
    //   改成一张设计卡片（surface + line + 13），行内 label 用 muted、值用正文色。
    final p = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: p.line),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in visible)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 92,
                      child: Text(
                        label,
                        style: TextStyle(color: p.muted, fontSize: 12.5),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        value,
                        style: TextStyle(color: p.text, fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// ★ r475 顺带修的一处文档事故：这里原本挂着 `_SongVisualizer`
/// （播放视觉特效）的文档注释，而那个类本轮已删 ⇒ 注释成了"悬空 doc"，
/// 被 Dart 归到下面这个函数头上（读起来像"打码函数=视觉特效"）。
/// 悬空注释已就地清掉；视觉特效的能力描述留在 `media/audio_visualizer.dart`。
///
/// ★★★ r131（macOS 逐屏走查，像素证据见 `docs/platform-macos-ui-audit.md` §3 D15）：
/// 串流地址里带着 **_会话凭据**（`_sid=` 会话 id、`SynoToken=` CSRF 令牌）。
/// 这张诊断卡原先把整串地址渲染成可选文本 ⇒ 一张截图就等于把会话交出去。
/// 规矩：**界面上一律打码**；只有用户主动点"复制"才给出完整地址，且必须提示。
String redactStreamUrl(String url) {
  // 注意：Dart 的 `replaceAll` **不支持** `$1` 分组引用（那是 `replaceAllMapped`），
  // 用错会把 `${1}***` 原样写进地址 —— r131 反向用例当场抓到过。
  String mask(String s, String key) => s.replaceAllMapped(
    RegExp('($key=)[^&]*'),
    (m) => '${m.group(1)}***',
  );
  return mask(mask(url, '_sid'), 'SynoToken');
}

/// 播放键下方的**快捷动作**（spec `audio_song` 的 `quick`）——r478。
///
/// 只放**这一页真的会用到**的三条：播放队列 / 投送 / 音效。
/// 睡眠定时没放进来：它已经有一整行（`_SleepTimerRow`），同一个动作给两个
/// 入口正是用户抱怨的"菜单重复"。
class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.onQueue,
    required this.onCast,
    required this.onEffects,
    required this.onInfo,
  });

  final VoidCallback onQueue;
  final VoidCallback onCast;
  final VoidCallback onEffects;

  /// r631：技术参数 / 评分 / 音质 / 流地址的统一入口。
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: _QuickAction(
            key: const Key('as-qa-queue'),
            icon: Icons.playlist_play,
            label: dataText('asQueueEntry', '播放队列'),
            onTap: onQueue,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _QuickAction(
            key: const Key('as-qa-cast'),
            icon: Icons.cast,
            label: dataText('asQuickCast', '投送'),
            onTap: onCast,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _QuickAction(
            key: const Key('as-qa-effects'),
            icon: Icons.graphic_eq,
            label: dataText('asQuickEffects', '音效'),
            onTap: onEffects,
          ),
        ),
        const SizedBox(width: 8),
        // ★ r631：四个按钮并排（393pt 下每个 ≈ 78pt，够 48dp 点击区）。
        Expanded(
          child: _QuickAction(
            key: const Key('as-qa-info'),
            icon: Icons.info_outline,
            label: context.t.asSongInfo,
            onTap: onInfo,
          ),
        ),
      ],
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
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
    final p = DesignPalette.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(11),
      onTap: onTap,
      child: Container(
        // 48dp 是最小点击区（AGENTS §2.0.10）
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: p.surface2,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: p.line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 20, color: p.muted),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.text, fontSize: 11.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// 行内**元信息**（页头那行 "3:51 · 320 kbps · 44.1 kHz · 9.0 MB"、
/// `Rating`、`Unrated`、`在线标签` 组标题）。
///
/// ★ r476：这些原来都是 HUD 的等宽标签 —— 一页里混着等宽/非等宽两套字体，
/// 设置页与电台页已经统一过，这里补齐。
class _MetaLine extends StatelessWidget {
  const _MetaLine(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = DesignPalette.of(context);
    return Text(
      text,
      style: TextStyle(
        color: p.muted,
        fontSize: 12.5,
        height: 1.25,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// 面板内的**小标题**（`Quality` / `Sleep timer` / `Streaming URL`）。
///
/// ★ r475：原来是 HUD 的等宽标签（`TelemetryLabel`），一套界面里混着两种
/// 字体语言 —— 设计稿里这几个都是"卡片内的小节标题"。
class _PanelLabel extends StatelessWidget {
  const _PanelLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = DesignPalette.of(context);
    return Text(
      text,
      style: TextStyle(
        color: p.muted,
        fontSize: 12.5,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
    );
  }
}
/// ★ r475：原来的大圆环＋律动柱已由上面的 `_SongCoverBlock` 取代。
///
/// 为什么不两个都留：真机像素证明那个圆**没有任何内容**（空渐变），
/// 与封面块并排就是"同一个东西画两遍"；spec 里播放区要的是**封面**。
/// 律动柱/真频谱这套能力没删 —— 文件预览播放器
/// （`media_audio_stage.dart`）仍在用，只是不再杵在单曲页正中。
/// 若想把它做成"封面上的一层"，那是设计决定，得先在 spec 里画出来。
