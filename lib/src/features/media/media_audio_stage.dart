// 内置音频播放舞台（文件预览页用）。
//
// ════════════════════════════════════════════════════════════════════════
// 第 260 轮：按"主流安卓播放器"的形态重做（用户要求）
// ════════════════════════════════════════════════════════════════════════
// 用户原话：「音频播放器需要做下播放的视觉效果以及歌词搜索关联和歌词的滚动效果」、
// 「目前的音频播放器设计效果都很差劲，需要重新设计，可以参考流行安卓播放器的界面
// 效果和功能重新设计实现」。
//
// 现在的构成（从上到下）：
//   ① **封面 + 呼吸光环 + 主色律动柱**（`audio_visualizer.dart`）；
//   ② 标题 / 歌手（从文件名推）/ 体积 · 时间；
//   ③ **逐行滚动歌词**（当前行高亮、居中、随进度自动滚动、**点击某行跳转到该时间点**；
//      歌词来自免密钥公开源 lrclib.net —— `audio_lyrics.dart`，带本地缓存）；
//   ④ 进度条（可拖，来源不支持 Range 时**置灰并说明**）；
//   ⑤ 控制行：单曲循环 / 搜歌词 / 播放暂停 / 睡眠定时 / 倍速。
//
// ## 历史修复（一律保留，别改回去）
//
// 现状修复（调研 §2.1 / §6.1 第 2 条）：
//   * 原来进度条的 `onChanged` 只调 `player.pause()`，**根本不能定位**；
//   * `VoicePlayer` 抽象里也**没有 seek** → 这里给抽象补上 seek 并真的接上滑块；
//   * 拖不动（服务端不支持 HTTP Range，例如 Drive）时**把滑块置灰并说明**，
//     不给假希望。
//
// 播放器是聊天模块共用的 `voicePlayerProvider`（just_audio）—— 与现状一致，
// 换独立实例是更大的改动（调研 §6.4 把它列为后续项）。
//
// ## 诚实的边界（**不要**为了"功能看起来全"而假装）
//
//   * 律动可视化是**推导动效，不是真实频谱**（原因与证据见
//     `audio_visualizer.dart` 文件头：Android `Visualizer` 必须要 RECORD_AUDIO）；
//   * ★ r651（`DA251`）改：**有**"上一首 / 下一首 / 接下来播放"了。判据不是
//     "播放器有没有队列 API"，而是**人**：从 `home/Music/` 点开一首歌，
//     下一首当然就是同目录的下一首。队列＝同目录同类型的可播条目
//     （`loadMediaDirectoryContext`，与视频侧同一份），切歌＝换 `_activeUri`。
//     单条来源（Drive / 相册 / 无目录身份）时**一个按钮都不画** —— 宁可没有，
//     也不放点了没反应的键；
//   * **没有**音量控制：`VoicePlayer` / `AudioStationPlayer` 都没有 volume API；
//     加它要改 `voice_message.dart`（超出本次允许改动的文件范围）⇒ 留待后续，
//     界面不放假的音量条；
//   * **循环**仍只做**单曲循环**；"循环全部"要有明确的开关，不在队列里偷偷绕回
//     队首（自然播完只走到下一首，到队尾就停在那里）。
//
// ## AGENTS §2.0.10（工具条按钮叠在一起）
//
// 本舞台的控制行是**固定 5 个**动作（不随状态增删）⇒ 不属于"数量会变"的工具条，
// 不需要 `adaptiveActions` 折叠；窄屏下它们仍然各占 48dp 的点击区，
// 但**不会**出现"排不下继续往左长、盖住返回键"的情形（控制行居中且总宽 < 320dp）。
// 本文件**不引入** `Key('bar-overflow')`，避免与页面顶栏的折叠入口撞 key。
import '../../design/kit/design_kit.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/file_entry_dto.dart';
import '../chat/voice_message.dart'
    show VoicePlaybackEnded, VoicePlaybackErrors, voicePlayerProvider;
import '../files/file_row.dart' show formatFileTime;
import '../files/file_thumb.dart';
import '../files/file_providers.dart';
import 'audio_lyrics.dart';
import 'audio_lyrics_view.dart';
import 'audio_visualizer.dart';
import 'media_library_loader.dart';
import 'media_cover_provider.dart';
import 'media_cover_view.dart';
import 'media_playback_store.dart';
import 'media_player.dart' show classifyPlayerError;
import 'media_player_view.dart'
    show
        MediaFallbackPanel,
        formatMediaDuration,
        kMediaReconnectedNoticeDuration,
        kMediaSpeeds;
import 'media_reason_text.dart';
import 'media_source.dart';

/// 歌词面板里每行的高度（固定 ⇒ 自动居中的偏移量可以直接算出来）。
const double kAudioLyricLineHeight = 28;

class MediaAudioStage extends ConsumerStatefulWidget {
  const MediaAudioStage({
    super.key,
    required this.entry,
    required this.source,
    this.playlist,
    this.playlistIndex = 0,
    this.onCurrentSourceChanged,
    this.onOpenExternal,
    this.onDownload,
  });

  final FileEntryDto entry;
  final MediaSource source;

  /// 调用方直接给好的队列（与视频侧 `MediaPlayerView.playlist` 同一写法）。
  ///
  /// 为空时 **自己列目录**（`loadMediaDirectoryContext`）—— 也就是默认行为：
  /// 从 `home/Music/` 点开一首歌，接下来播放的就是同目录的其它音频。
  final List<MediaSource>? playlist;
  final int playlistIndex;

  /// 当前播放项回填（顶栏标题跟着换歌走）。
  ///
  /// ★ r651（`DA251`）：不接这条线，真机上就出现**同一个页面两种读数** ——
  /// 舞台上写着 `CD1 - 02 - Falling A.mp3`，顶栏还挂着点开时那一首
  /// （r639 的教训：机制存在 ≠ 每条路径都走它）。
  final ValueChanged<MediaSource>? onCurrentSourceChanged;
  final VoidCallback? onOpenExternal;
  final VoidCallback? onDownload;

  @override
  ConsumerState<MediaAudioStage> createState() => _MediaAudioStageState();
}

class _MediaAudioStageState extends ConsumerState<MediaAudioStage> {
  /// 在 initState 里抓住播放器：dispose 时不能再碰 `ref`（容器可能已销毁）
  late final _player = ref.read(voicePlayerProvider);

  /// 这个播放器能不能报错（`just_audio` 有 `errorStream`；假实现未必有）
  VoicePlaybackErrors? get _errors =>
      _player is VoicePlaybackErrors ? _player as VoicePlaybackErrors : null;

  StreamSubscription<void>? _sub;

  /// 运行时失败（载入/解码失败）→ 出回退面板
  MediaUnavailableReason? _failure;

  /// ★ r651（**DA251**）：**Up Next** —— 同目录的音频条目（自然序）。
  ///
  /// 之前这里写死"没有上一首/下一首"（文件头的老注释也是这么说的），理由是
  /// 舞台背后只有一条 URL。但从**人**的角度看这是说不通的：用户从
  /// `home/Music/` 点开一首歌，播放器不给"下一首"，也没有"接下来播放"——
  /// 而视频播放器早就有同目录的上一个/下一个（同一份 `loadMediaDirectoryContext`）。
  /// 所以这里不是"新造一份队列"，而是**复用目录条目**：队列 = 同目录同类型的
  /// 可播条目，切歌 = 换 `_activeUri` 再 `play`。
  List<MediaSource> _queue = const [];
  List<FileEntryDto> _queueEntries = const [];
  int _queueIndex = 0;

  /// 当前这条（队列没就绪时退回 widget 给的那条）
  FileEntryDto get _entry =>
      _queueEntries.length == _queue.length && _queueIndex < _queueEntries.length
      ? _queueEntries[_queueIndex]
      : widget.entry;
  MediaSource get _source =>
      _queueIndex < _queue.length ? _queue[_queueIndex] : widget.source;

  /// 正在换歌（换歌期间不判定"播完"，见 listener 里的边沿判据）
  bool _switching = false;

  /// 上一帧是否处于"片尾"（边沿检测用；`DA251` 真机缺陷的修法）
  bool _wasAtEnd = false;

  /// 队列里到底有没有"下一首/上一首"（没有就不画按钮 —— 不放点不动的键）
  bool get _hasQueue => _queue.length > 1;

  /// 标题该写谁：有目录条目就用条目名（含音轨号，和文件页一致），
  /// 只有显式队列时用当前来源的名字 —— 换歌之后标题**必须跟着换**。
  String get _titleName =>
      _queueEntries.length == _queue.length ? _entry.name : _source.displayName;

  /// 当前**有效**来源的 URL：会话续期成功后换成带新 `_sid` 的那条，
  /// 否则"暂停 → 再播放"会用旧 URL 重载（`_startOrResume` 的同源判断）。
  late String _activeUri;

  /// 失效前的最后已知位置（119 到达时播放器可能已把位置清 0）
  Duration _lastKnownPosition = Duration.zero;

  /// 正在会话续期 / 已自动续期次数（见 `kMediaSessionRenewMaxAttempts`）
  bool _renewing = false;
  int _renewAttempts = 0;

  /// 续期成功后显示"已重新连接"**非阻塞**提示（几秒后自动消失）
  bool _reconnected = false;
  Timer? _reconnectedTimer;

  /// 拖动中的目标位置（毫秒）；非 null = 用户正按着滑块
  double? _dragValue;

  /// 拖动前是否在播（松手后要接着播）
  bool _resumeAfterDrag = false;

  /// 当前来源是否已经播到（或拖到）**结尾**。
  ///
  /// 为什么不能只靠 `_player.position >= duration`：just_audio 在 `completed`
  /// 时会**异步** `stop() + seek(0)`（见 `JustAudioVoicePlayer`），位置可能已经
  /// 回到 0 —— 而"点播放 → 从头重播"的语义仍然成立。R5-7 的两次点击就出在这个
  /// 竞争上：第一次点击走了 `resume()`（对 completed 的播放器不出声），之后监听
  /// 才把位置归零。所以末尾这个事实要在位置/拖动处**显式记一笔**，重播成功后清掉。
  bool _atEnd = false;

  /// 播放器的"已在片尾"能力（真实实现 `JustAudioVoicePlayer` 有；假实现可以没有）。
  ///
  /// 位置是**流上的瞬时量**、会被 `completed` 后的异步 `seek(0)` 冲掉；状态才是
  /// 事实。两者任一成立就记 [_atEnd]（见 [VoicePlaybackEnded]）。
  VoicePlaybackEnded? get _endedCap =>
      _player is VoicePlaybackEnded ? _player as VoicePlaybackEnded : null;

  /// 「拖到结尾」的判定容差（毫秒级的滑块落点抖动）。
  static const Duration _audioEndTolerance = Duration(milliseconds: 300);

  // ─────────────────────────────────────────────────────────── 本轮新增状态

  /// **单曲循环**（默认关）。开 → 播完自动从头再来（单条来源唯一有意义的循环）。
  bool _repeatOne = false;

  /// 睡眠定时（一次性 Timer；**不用**每秒轮询 —— 那会一直在调度帧）。
  Timer? _sleepTimer;

  /// 已设定睡眠定时的分钟数（null = 没设定）
  int? _sleepMinutes;

  /// 歌词结果 / 是否正在取 / 是否已经自动取过一次
  LyricsLoadResult? _lyrics;
  bool _lyricsLoading = false;
  bool _lyricsAuto = false;

  /// 歌词列表的滚动控制器（**自动居中**当前行）


  /// 上一次高亮的行号（只在变化时才发起滚动，避免每帧都动）


  /// 睡眠定时档位（分钟）
  static const List<int> kSleepTimerMinutes = [15, 30, 60, 90];

  /// 歌词查询（曲名/歌手从文件名推；时长用来给候选排序）。
  LyricsQuery get _lyricsQuery {
    // ★ r651（`DA251`）：换歌后歌词必须跟着换 —— 有目录条目用条目的
    // name/path（能复用缓存），只有显式队列时用当前来源的名字。
    final named = _queueEntries.length == _queue.length;
    return lyricsQueryForFileName(
      named ? _entry.name : _source.displayName,
      duration: _player.duration,
      identity: named ? _entry.path : '',
    );
  }

  /// 载入同目录音频队列（r651 / `DA251`）。
  ///
  /// 与视频侧共用 [loadMediaDirectoryContext]：它负责"列目录 + 自然排序 + 放进
  /// 当前条目"，鉴权/证书/隧道那些规则由 `resolveFileStationSource` 决定。
  /// 没有目录身份（Drive / 相册 / 无会话）→ 队列为空 ⇒ 界面**不出现**上一首/
  /// 下一首/接下来播放（宁可没有，也不放点了没反应的键）。
  Future<void> _loadQueue() async {
    final explicit = widget.playlist;
    if (explicit != null && explicit.length > 1) {
      if (!mounted) return;
      setState(() {
        _queue = explicit;
        _queueEntries = const [];
        _queueIndex = widget.playlistIndex.clamp(0, explicit.length - 1);
      });
      _reportCurrent();
      return;
    }
    try {
      final ctx = await loadMediaDirectoryContext(
        fs: ref.read(fileApiProvider),
        entry: widget.entry,
        kind: MediaKind.audio,
        sourceOf: _sourceOf,
      );
      if (!mounted || ctx == null || ctx.playlist.length < 2) return;
      setState(() {
        _queue = ctx.playlist;
        _queueEntries = ctx.entries;
        _queueIndex = ctx.index.clamp(0, ctx.playlist.length - 1);
      });
      _reportCurrent();
    } catch (_) {
      // 列目录失败不影响单条播放：保持"单条"形态
    }
  }

  /// 把"当前播放项"报给父层（顶栏标题）；没变化就不触发。
  void _reportCurrent() {
    final callback = widget.onCurrentSourceChanged;
    if (callback == null) return;
    final current = _source;
    if (identical(current, _reportedSource)) return;
    _reportedSource = current;
    callback(current);
  }

  MediaSource? _reportedSource;

  MediaSource _sourceOf(FileEntryDto e) => resolveFileStationSource(
    displayName: e.name,
    kind: MediaKind.audio,
    fs: ref.read(fileApiProvider),
    path: e.path,
    size: e.size,
  );

  /// 切到队列里的第 [index] 条：**换来源**（不是续播）。
  ///
  /// 换歌要一并复位"这首歌"的状态（结尾标记 / 歌词 / 位置），否则上一首的
  /// 歌词和 `_atEnd` 会挂在新歌上（r644 的教训：该重建的地方必须有 key/状态复活）。
  Future<void> _switchTo(int index) async {
    if (index < 0 || index >= _queue.length || index == _queueIndex) return;
    final next = _queue[index];
    if (!next.playable) return;
    _switching = true;
    setState(() {
      _queueIndex = index;
      _failure = null;
      _atEnd = false;
      // 注意：**不**清 `_wasAtEnd` —— 换歌之后通常还会来一两帧"上一首的片尾"
      // 读数，清掉就等于把边沿重新上膛，真机上就会 02→04 连跳。
      // 它会在新歌真的播起来（读数不再是片尾）那一帧自然复位。
      _lyrics = null;
      _lyricsLoading = false;
      _lyricsAuto = false;
      _lastKnownPosition = Duration.zero;
      _activeUri = next.uri;
    });
    try {
      _endedCap?.clearEnded();
      await _player.play(next.uri);
    } catch (_) {
      // 换歌失败：停在原状态，界面不假装在播
      _switching = false;
      return;
    }
    _switching = false;
    _reportCurrent();
    unawaited(_maybeAutoLoadLyrics());
    if (_repeatOne) _repeatOne = false;
  }

  /// 「接下来播放」面板：列出队列，点哪条播哪条（当前那条打勾、且点它不动作）
  Future<void> _showUpNext() async {
    final t = context.t;
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: Column(
            key: const Key('audio-up-next-sheet'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
                child: Row(
                  children: [
                    Text(
                      t.audioUpNext,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(width: Gap.xs),
                    Text(
                      '${_queueIndex + 1} / ${_queue.length}',
                      key: const Key('audio-up-next-count'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: DesignPalette.of(sheetContext).dim,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _queue.length,
                  itemBuilder: (_, i) {
                    final item = _queue[i];
                    final current = i == _queueIndex;
                    // 设计语言闸门（`DA133`）禁用裸列表行：行卡一律走
                    // `DesignRowTile`（纯文本守卫会把注释里的写法也数进去）。
                    return DesignRowTile(
                      key: Key('audio-up-next-$i'),
                      dense: true,
                      // 当前那条用「选中底色」表达"就是这首"，而不是置灰
                      // （置灰会读成"这首不能点"）；点它不动作由 onTap:null 保证。
                      selected: current,
                      leading: Icon(
                        current
                            ? Icons.equalizer_rounded
                            : Icons.music_note_outlined,
                        color: current ? theme.colorScheme.primary : null,
                      ),
                      title: Text(
                        item.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: current
                            ? TextStyle(color: theme.colorScheme.primary)
                            : null,
                      ),
                      onTap: current
                          ? null
                          : () => Navigator.of(sheetContext).pop(i),
                    );
                  },
                ),
              ),
              const SizedBox(height: Gap.sm),
            ],
          ),
        );
      },
    );
    if (picked != null) await _switchTo(picked);
  }

  /// 开始/继续播放**当前这个来源**。
  ///
  /// Bug 3（真机 A2 `audiotone.wav`）：拖动 seek 到 `00:38` → 暂停 → 点播放，
  /// 旧代码无条件 `_player.play(uri)`，而 `JustAudioVoicePlayer.play` 内部是
  /// `setUrl` —— 真机上 just_audio **新建 ExoPlayer 并从 00:02 重来**
  /// （logcat `ExoPlayerImpl: Init`），「从新位置续播」不成立。
  ///
  /// 判据用"播放器里已经载入的这个 URL == 本条来源"：满足就只 `resume()`
  /// （不重载）；换来源才 `play(uri)`。
  Future<void> _startOrResume() async {
    if (_player.hasSource && _player.currentUrl == _activeUri) {
      await _player.resume();
      return;
    }
    await _player.play(_activeUri);
  }

  @override
  void initState() {
    super.initState();
    _activeUri = _source.uri;
    // r651：目录条目 → Up Next（失败/无目录身份时退化成"单条"，按钮不出现）
    unawaited(_loadQueue());
    // 上次的倍速用回来（W1-2；这与视频侧共用同一份全局偏好）。
    // dispose 会把速率复位成 1，避免把预览页选的倍速带进聊天语音；
    // 所以每次进入预览都要重新应用一次"记住的值"。
    unawaited(_applySavedSpeed());
    // 歌词：**先读本地缓存**（默认不联网）。首帧之后跑，因为 initState 里
    // 还读不到播放器报上来的时长。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_maybeAutoLoadLyrics());
    });
    // 流式播放：URL 本身就带 _sid/SynoToken，播放器直接读
    _sub = _player.changes.listen((_) {
      if (!mounted) return;
      final err = _errors?.error;
      if (err != null && _failure == null && !_renewing) {
        // 已知格式缺口（WMA/ASF、APE、DSD…）→ 把 Media3 的笼统兜底升级成
        // `formatUnsupported`，面板说"是格式问题、用其他应用打开"而不是
        // 泛化的"播放失败"（fail-open 的另一半，见 media_source.dart）
        final reason = refinePlayerErrorForSource(
          _source,
          classifyPlayerError(err),
        );
        // 会话失效（**不是**网络中断）+ 能 seek + 能重解析 → 原地续播；
        // 不弹会话失效面板，续期失败才回落到既有面板。
        if (shouldRenewSession(_source, reason) &&
            _renewAttempts < kMediaSessionRenewMaxAttempts) {
          unawaited(_renewAndResume(reason));
          return;
        }
        setState(() => _failure = reason);
        return;
      }
      if (_failure == null && !_renewing) {
        _lastKnownPosition = _player.position;
        final total = _player.duration;
        // 这一帧是不是"在片尾"：**状态优先**（`completed` 会被异步 `seek(0)`
        // 冲掉，位置靠不住），位置作为补充（拖到末尾那一支）。
        // 位置只能当**本首歌**的判据：`setUrl` 之后第一帧的位置/时长可能还是
        // 上一首的读数（真机：换歌后立刻又被判成"在片尾"⇒ 连跳两首）。
        final posIsOurs = _player.currentUrl == _activeUri;
        final atEndNow =
            (_endedCap?.ended == true) ||
            (posIsOurs &&
                total != null &&
                total > Duration.zero &&
                _player.position >= total);
        if (!_switching) {
          _atEnd = atEndNow;
          // ★ r651（`DA251`）：**"播完"认边沿，不认电平** —— 第一版按 `_atEnd`
          //   电平判断，换到下一首的瞬间播放器还留着上一首的 `ended` ⇒ 又切一首
          //   （真机：02 播完直接跳到 04），两次 `play()` 叠在一起还会抛异常、
          //   界面给出"网络中断/会话失效"的假面板。
          final shouldAct = atEndNow && !_wasAtEnd;
          _wasAtEnd = atEndNow;
          if (shouldAct) {
            if (_repeatOne) {
              unawaited(_restart());
            } else if (_hasQueue && _queueIndex + 1 < _queue.length) {
              // 自然播完 → 下一首；到队尾就停在这里（不偷偷"循环全部"）
              unawaited(_switchTo(_queueIndex + 1));
            }
          }
        }
      }
      // 时长一旦报上来，就当"这首歌"去要一次歌词（只查这一首）
      unawaited(_maybeAutoLoadLyrics());
      // ★ r651（`DA251`）真机缺陷：**"播完"必须认边沿，不能认电平**
      //   第一版按 `_atEnd` 电平判断 ⇒ 切到下一首的瞬间，播放器还没换掉上一首的
      //   `ended` 状态，listener 又看到一个"在片尾"⇒ 再切一首（真机：02 播完
      //   直接跳到 04），两次 `play()` 叠在一起还会抛 `PlayerException`，
      //   界面给出"网络中断/会话失效"的假面板。
      //   修法：只在 false→true **那一次**动作；换歌期间 `_switching` 一律不动。
      // 边沿只认**这一帧的实测读数**（sticky 的 `_atEnd` 是给"点一下重播"用的，
      // 拿它做边沿会在换歌后永不再触发）。
      final atEndNow =
          _endedCap?.ended == true ||
          (_player.duration != null &&
              _player.duration! > Duration.zero &&
              _player.position >= _player.duration!);
      final shouldAdvance = atEndNow && !_wasAtEnd && !_renewing && !_switching;
      if (!_switching) _wasAtEnd = atEndNow;
      if (shouldAdvance) {
        _atEnd = false;
        if (_repeatOne) {
          unawaited(_restart());
        } else if (_hasQueue && _queueIndex + 1 < _queue.length) {
          // 自然播完 → 队列里的下一首（到队尾就停在那里，不做偷偷的"循环全部"）
          unawaited(_switchTo(_queueIndex + 1));
        }
      }
      setState(() {});
    });
  }

  /// 单曲循环的重播（显式 `seek(0)` + 重新载入：`JustAudioVoicePlayer` 在
  /// completed 时会 `stop()` 把来源清掉 —— 那时 `resume()` 是 no-op）。
  Future<void> _restart() async {
    try {
      _endedCap?.clearEnded();
      await _player.seek(Duration.zero);
      await _player.play(_activeUri);
    } catch (err) {
      if (mounted) {
        setState(
          () => _failure = refinePlayerErrorForSource(
            _source,
            classifyPlayerError(err),
          ),
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────── 歌词流程

  /// 自动取一次（先缓存后联网）。用 [_lyricsAuto] 保证**只自动跑一次**。
  Future<void> _maybeAutoLoadLyrics() async {
    if (_lyricsAuto) return;
    _lyricsAuto = true;
    await _loadLyrics();
  }

  /// 取歌词：① 本地缓存 → ② 联网搜当前这一首。
  ///
  /// [force] = 用户点了「重搜」：跳过缓存，再联网一次。
  Future<void> _loadLyrics({bool force = false}) async {
    final query = _lyricsQuery;
    if (query.isEmpty) return;
    final lookup = ref.read(mediaLyricsLookupProvider);
    if (mounted) {
      setState(() {
        _lyricsLoading = true;
        if (force) _lyrics = null;
      });
    }
    if (!force) {
      final cached = await lookup.fromCache(query);
      if (!mounted) return;
      if (cached.hasLyrics) {
        setState(() {
          _lyrics = cached;
          _lyricsLoading = false;
        });
        return;
      }
    }
    final result = await lookup.search(query);
    if (!mounted) return;
    setState(() {
      _lyrics = result;
      _lyricsLoading = false;
    });
  }

  /// 用户在候选里**明确选一个版本**。
  Future<void> _pickCandidate(LyricCandidate candidate) async {
    final query = _lyricsQuery;
    final candidates = _lyrics?.candidates ?? const <LyricCandidate>[];
    final lookup = ref.read(mediaLyricsLookupProvider);
    if (mounted) setState(() => _lyricsLoading = true);
    final result = await lookup.choose(
      query,
      candidate,
      candidates: candidates,
    );
    if (!mounted) return;
    setState(() {
      _lyrics = result;
      _lyricsLoading = false;
    });
  }

  /// 选歌词版本的底部弹层（歌名 / 歌手 / 专辑 / 时长，如实来自源站）。
  Future<void> _showCandidateSheet() async {
    final candidates = _lyrics?.candidates ?? const <LyricCandidate>[];
    if (candidates.isEmpty) return;
    final chosenId = _lyrics?.chosen?.id;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: ListView.builder(
            key: const Key('audio-lyrics-candidates'),
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (context, i) {
              final c = candidates[i];
              final selected = c.id == chosenId;
              return DesignRowTile(
                key: Key('audio-lyrics-candidate-${c.id}'),
                selected: selected,
                leading: Icon(
                  c.hasSynced
                      ? Icons.lyrics_outlined
                      : Icons.subject_rounded,
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
                    if (!c.hasSynced)
                      dataText('audioLyricsNoTimeline', '不会自动滚动'),
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

  /// 点击某一行歌词 → **跳到该时间点**（用户在歌词里"点哪唱哪"）。
  ///
  /// ★ r652（DA253）：滚动/居中已由共享阅读器负责（`SyncedLyricsView`），
  /// 这一侧只保留"真的跳过去"这一个动作。
  Future<void> _seekToLyricTime(Duration time) async {
    final total = _player.duration;
    _atEnd =
        total != null &&
        total > Duration.zero &&
        time + _audioEndTolerance >= total;
    _endedCap?.clearEnded();
    await _player.seek(time);
    if (mounted) setState(() {});
  }

  // ─────────────────────────────────────────────────────────────── 睡眠定时

  void _startSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      if (!mounted) return;
      setState(() {
        _sleepMinutes = null;
      });
      unawaited(_player.pause());
    });
    setState(() => _sleepMinutes = minutes);
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    setState(() => _sleepMinutes = null);
  }

  /// **会话续期 → 原地续播**（音频侧）。
  ///
  /// `just_audio` 换 URL 必须 `setUrl`（新来源 = 新会话），所以先 `play(新URL)`
  /// 再 `seek` 回 [_lastKnownPosition]；网络中断不会到这里
  /// （`classifyPlayerError` 已把它分到 `networkFailed`）。
  ///
  /// **有界 + 指数退避**（与视频侧同一条策略）：最多
  /// [kMediaSessionRenewMaxAttempts] 次，第二次之前等 `mediaSessionRenewDelay`；
  /// 全部失败 → 既有会话失效面板 + 手动重试入口（不静默停住、不无限循环）。
  Future<void> _renewAndResume(MediaUnavailableReason reason) async {
    if (_renewing) return;
    _renewing = true;
    final resumeAt = _lastKnownPosition;
    var recovered = false;
    try {
      while (_renewAttempts < kMediaSessionRenewMaxAttempts) {
        if (_renewAttempts > 0) {
          final wait = mediaSessionRenewDelay(_renewAttempts + 1);
          if (wait > Duration.zero) await Future<void>.delayed(wait);
          if (!mounted) return;
        }
        _renewAttempts++;
        try {
          final renew = _source.renew;
          if (renew == null) throw StateError('source has no renewer');
          final fresh = await renew();
          if (!fresh.playable) {
            throw StateError('renew produced an unplayable source');
          }
          _activeUri = fresh.uri;
          await _player.play(_activeUri);
          await _player.seek(resumeAt);
          _errors?.clearError();
          recovered = true;
          break;
        } catch (_) {
          // 这一跳失败：还有额度就退避后再试，否则回面板
        }
      }
      if (recovered) {
        _showReconnectedNotice();
      } else if (mounted) {
        setState(() => _failure = reason);
      }
    } finally {
      _renewing = false;
      if (mounted) setState(() {});
    }
  }

  /// 续期成功 → **非阻塞**提示（不弹窗、不打断，几秒后自动消失）。
  void _showReconnectedNotice() {
    _reconnectedTimer?.cancel();
    _reconnectedTimer = Timer(kMediaReconnectedNoticeDuration, () {
      if (mounted) setState(() => _reconnected = false);
    });
    if (mounted) setState(() => _reconnected = true);
  }

  /// 这条失败能不能给"手动重试"入口（复用 [shouldRenewSession] 的三条件）
  bool _canManualRetry(MediaUnavailableReason reason) =>
      shouldRenewSession(_source, reason);

  /// 上次的倍速用回来（W1-2）。失败/没存过 → 保持原速。
  Future<void> _applySavedSpeed() async {
    final saved = await ref.read(mediaPlaybackStoreProvider).loadSpeed();
    if (!mounted || saved == null || saved == _player.speed) return;
    try {
      await _player.setSpeed(saved);
    } catch (_) {
      // 平台拒绝倍速不影响播放
    }
    if (mounted) setState(() {});
  }

  /// 用户选了倍速 → 立即生效并**记住**（重启后还在）。
  Future<void> _setSpeed(double speed) async {
    await _player.setSpeed(speed);
    await ref.read(mediaPlaybackStoreProvider).saveSpeed(speed);
    if (mounted) setState(() {});
  }

  /// 用户点「重试」：重置自动预算后再走一次续期→续播（每次点击仍有界）
  Future<void> _manualRetry() async {    if (_renewing) return;
    _renewAttempts = 0;
    if (mounted) setState(() => _failure = null);
    await _renewAndResume(MediaUnavailableReason.sessionExpired);
  }

  @override
  void dispose() {
    _reconnectedTimer?.cancel();
    _sleepTimer?.cancel();
    _sub?.cancel();
    // 共用播放器：走的时候把速率复位（别把预览页选的倍速带进聊天语音）
    unawaited(_player.setSpeed(1));
    unawaited(_player.stop());
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_player.playing) {
      await _player.pause();
      return;
    }
    try {
      if (_atEnd) {
        // 末尾重播：**一次点击**就要从 00:00 起播。不能只靠 just_audio 的
        // `completed → stop() + seek(0)`（异步），否则第一次点击会与它竞争、
        // 走了对 completed 播放器无效的 `resume()`：表现为"只归零不出声，要再点
        // 一次"（R5-7）。这里显式先归零再续播（`seek(0)` 同时清掉 completed 态）。
        _atEnd = false;
        _endedCap?.clearEnded();
        await _player.seek(Duration.zero);
      }
      await _startOrResume();
    } catch (err) {
      if (mounted) {
        setState(
          () => _failure = refinePlayerErrorForSource(
            _source,
            classifyPlayerError(err),
          ),
        );
      }
      return;
    }
    if (mounted) setState(() {});
  }

  void _onDragStart(double v) {
    _resumeAfterDrag = _player.playing;
    unawaited(_player.pause());
    setState(() => _dragValue = v);
  }

  void _onDragUpdate(double v) => setState(() => _dragValue = v);

  /// 松手：seek 到新位置，拖之前在播就**从新位置续播**（不重载来源）。
  ///
  /// 边界语义（"拖到文件末尾后再播放"）：位置落到 `duration` 后，just_audio 进
  /// `ProcessingState.completed` → `JustAudioVoicePlayer` 的监听会
  /// `stop()` + `seek(0)` → 再点播放就是**从头开始**（与视频侧
  /// `MediaPlayerView._toggle` 的 `seekTo(zero)` 一致）。
  Future<void> _onDragEnd(double v) async {
    final target = Duration(milliseconds: v.round());
    final total = _player.duration;
    // 拖到末尾 → 记为"下一次点播放是从头重播"（不能只看 player.position：
    // just_audio 可能已经异步把它复位成 0，见 [_atEnd]）
    _atEnd =
        total != null &&
        total > Duration.zero &&
        target + _audioEndTolerance >= total;
    _endedCap?.clearEnded();
    await _player.seek(target);
    setState(() => _dragValue = null);
    if (_resumeAfterDrag) await _startOrResume();
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    if (failure != null) {
      return MediaFallbackPanel(
        source: _source,
        reason: failure,
        onOpenExternal: widget.onOpenExternal,
        onDownload: widget.onDownload,
        // 有界重试用尽后的**手动**出口（不能 seek / 没有 renewer 时不出现）
        onRetry: _canManualRetry(failure) ? _manualRetry : null,
      );
    }

    final player = _player;
    final total = player.duration;
    final maxMs = total == null ? 0.0 : total.inMilliseconds.toDouble();
    final posMs = (_dragValue ?? player.position.inMilliseconds.toDouble())
        .clamp(0.0, maxMs <= 0 ? 0.0 : maxMs);
    // 能拖的前提：这个来源真的支持 Range（Drive 写死 Accept-Ranges: none）
    final canSeek = _source.seekable && maxMs > 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 矮屏 / 窄屏 → 紧凑：封面与歌词面板都缩小（真机横屏、分屏、小屏都走这条；
        // 本仓 widget 测试默认的 800x600 窗口也走这条，保证控件都在可视区内）
        final compact =
            constraints.hasBoundedHeight &&
            (constraints.maxHeight < 640 || constraints.maxWidth < 400);
        final top = _buildTop(context, compact: compact);
        final bottom = _buildBottom(
          context,
          posMs: posMs,
          total: total,
          maxMs: maxMs,
          canSeek: canSeek,
        );
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: top,
        );
        final content = constraints.hasBoundedHeight
            ? Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const Key('audio-stage-scroll'),
                      child: body,
                    ),
                  ),
                  ...bottom,
                ],
              )
            // 无界高度（例如被塞进 ListView）：不能 Expanded，整体一起滚
            : SingleChildScrollView(child: Column(children: [body, ...bottom]));
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.lg,
            vertical: Gap.sm,
          ),
          child: content,
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────── 上半部分

  List<Widget> _buildTop(BuildContext context, {required bool compact}) {
    final e = _entry;
    final theme = Theme.of(context);
    final t = context.t;
    final player = _player;

    final coverRequest = mediaCoverKeyFor(e, _source);
    // 封面字节同时喂给可视化（**真实**取主色）与封面本身
    final cover = coverRequest == null
        ? null
        : ref.watch(mediaCoverProvider(coverRequest)).value;
    final coverBytes = cover?.bytes;

    final coverSize = compact ? 104.0 : 176.0;
    final halo = coverSize * 1.5;
    final inset = (halo - coverSize) / 2;

    final query = _lyricsQuery;

    return [
      // 会话续期成功的**非阻塞**提示：不弹窗、不打断，几秒后自己消失
      if (_reconnected)
        Padding(
          key: const Key('audio-session-reconnected'),
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Text(
            mediaSessionReconnectedNotice(),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
          ),
        ),
      // ① 封面（内嵌封面优先，没有就退文件图标）+ 呼吸光环 + 主色律动柱
      Center(
        child: SizedBox(
          width: halo,
          height: halo + 34 + (compact ? 0 : 20),
          child: Stack(
            children: [
              AudioVisualizer(
                playing: player.playing,
                position: player.position,
                duration: player.duration,
                seedKey: e.path,
                coverBytes: coverBytes,
                compact: compact,
                size: Size(halo, halo),
              ),
              Positioned(
                left: inset,
                top: inset,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    width: coverSize,
                    height: coverSize,
                    child: MediaCoverLayers(
                      embedded: coverRequest,
                      fit: BoxFit.cover,
                      placeholder: FileThumb(
                        entry: e,
                        size: coverSize,
                        iconSize: coverSize * 0.36,
                        radius: 16,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: Gap.md),
      // ② 标题 / 歌手 / 体积 · 时间
      Text(
        _titleName,
        key: const Key('audio-stage-title'),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium,
      ),
      if (query.artist.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xxs),
          child: Text(
            query.artist,
            key: const Key('audio-stage-artist'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: DesignPalette.of(context).dim),
          ),
        ),
      const SizedBox(height: Gap.xxs),
      Text(
        '${e.humanSize}${e.mtime > 0 ? ' · ${formatFileTime(e.mtime, t: t)}' : ''}',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
      ),
      const SizedBox(height: Gap.md),
      // ③ 逐行滚动歌词
      _buildLyricsPanel(context, compact: compact),
    ];
  }

  // ─────────────────────────────────────────────────────────── 歌词面板

  Widget _buildLyricsPanel(BuildContext context, {required bool compact}) {
    final theme = Theme.of(context);
    final result = _lyrics;
    final doc = result?.document;
    final title = Text(
      context.t.asLyrics,
      style: theme.textTheme.labelMedium?.copyWith(color: DesignPalette.of(context).dim),
    );

    // ★ DA66（r411）：署名行**并进** header，不再单独挂一个「已用本地缓存」
    // 小标 —— 否则同一件事在屏上出现两遍（DA51 的同族判据）。
    Widget header({Widget? trailing}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            title,
            const Spacer(),
            if (trailing != null) trailing,
          ],
        ),
        // 判据取**屏上正在显示的那一份**（`result`），不是"最近搜到的"：
        // 用户看到什么，署名就得写什么。
        LyricsAttributionLine(
          document: doc,
          chosen: result?.chosen,
          fromCache: result?.fromCache ?? false,
          textKey: const Key('audio-lyrics-attribution'),
        ),
      ],
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (result != null && result.hasCandidates)
          TextButton(
            key: const Key('audio-lyrics-pick'),
            onPressed: _lyricsLoading ? null : _showCandidateSheet,
            child: Text(audioLyricsPickText()),
          ),
        TextButton(
          key: const Key('audio-lyrics-research'),
          onPressed: _lyricsLoading ? null : () => unawaited(_loadLyrics(force: true)),
          child: Text(
            result != null && result.chosen != null
                ? audioLyricsRetryText()
                : audioLyricsSearchHintText(),
          ),
        ),
      ],
    );

    if (_lyricsLoading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header(trailing: actions),
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.search_rounded, size: 14, color: DesignPalette.of(context).dim),
                const SizedBox(width: Gap.xs),
                Text(
                  // ⚠️ **不用** `CircularProgressIndicator`：它是**无限**动画，
                  // 会让任何 `pumpAndSettle()`（本仓既有音频用例大量使用）
                  // 直接超时。这里用静态文案 —— 用户照样知道"正在搜"。
                  dataText('audioLyricsLoading', '正在搜索歌词…'),
                  key: const Key('audio-lyrics-loading'),
                  style: theme.textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (doc == null || doc.isEmpty) {
      final failureText = result?.failure == null
          // 还没查过（例如文件名推不出曲名）→ 明确说"可以搜"
          ? dataText('audioLyricsNotLoaded', '还没有这首歌的歌词')
          : lyricsFailureText(result!.failure!);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header(trailing: actions),
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Text(
              failureText,
              key: const Key('audio-lyrics-empty'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
            ),
          ),
        ],
      );
    }

    if (!doc.timed) {
      // 纯文本歌词（没有时间轴）——**照实显示**，并说清"高亮不了"
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header(trailing: actions),
          Text(
            audioLyricsPlainTextHintText(),
            key: const Key('audio-lyrics-plain-hint'),
            style: theme.textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
          ),
          SizedBox(
            height: compact ? 96 : 168,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: SelectableText(
                doc.plainText,
                key: const Key('audio-lyrics-plain'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      );
    }

    final position = _dragValue == null
        ? _player.position
        : Duration(milliseconds: _dragValue!.round());
    final canSeek = _source.seekable && _player.duration != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header(trailing: actions),
        // ★ r652（**DA253**）：**同一个阅读器**。
        //
        // 这里原来自己搭了一套（`ListView` + 自己的滚动同步）：高亮、居中这两件
        // 事看着一样，但 Audio Station 单曲页 / 全屏歌词在这之上还有 r644 的
        // 三件事 ——「滑走了能回到正在唱的那句」、「边缘只在该有内容的一侧渐隐」、
        // 长按复制这句 —— **同一份歌词，两个入口行为不一样**。
        // 现在两边都走 `SyncedLyricsView`，key 用参数对齐（宿主的定位契约不变）。
        SizedBox(
          height: compact ? 96 : 168,
          child: SyncedLyricsView(
            document: doc,
            position: position,
            // 来源不支持 Range 时点了也没用 ⇒ 不给假的"点哪唱哪"
            onSeek: canSeek
                ? (time) => unawaited(_seekToLyricTime(time))
                : null,
            height: compact ? 96 : 168,
            lineHeight: kAudioLyricLineHeight,
            listKey: const Key('audio-lyrics'),
            lineKeyPrefix: 'audio-lyrics-line',
            activeLineKey: const Key('audio-lyrics-current'),
            // 舞台的小面板居中读起来更整齐（全屏页用左对齐）。
            textAlign: TextAlign.center,
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
      ],
    );
  }

  // ─────────────────────────────────────────────────────────── 下半部分

  List<Widget> _buildBottom(
    BuildContext context, {
    required double posMs,
    required Duration? total,
    required double maxMs,
    required bool canSeek,
  }) {
    final player = _player;
    final theme = Theme.of(context);
    final t = context.t;

    return [
      if (!_source.seekable)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.xs),
          child: Text(
            t.bookDownloadHint,
            key: const Key('audio-no-seek-hint'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
          ),
        ),
      // ④ 进度条：当前时间 / 可拖滑块 / 总时长
      Row(
        children: [
          Text(
            formatMediaDuration(Duration(milliseconds: posMs.round())),
            style: theme.textTheme.bodySmall,
          ),
          Expanded(
            child: Slider(
              key: const Key('audio-progress'),
              value: maxMs <= 0 ? 0 : posMs,
              max: maxMs <= 0 ? 1 : maxMs,
              onChangeStart: canSeek ? _onDragStart : null,
              onChanged: canSeek ? _onDragUpdate : null,
              onChangeEnd: canSeek ? _onDragEnd : null,
            ),
          ),
          Text(
            total == null ? '--:--' : formatMediaDuration(total),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      // ⑤ 控制行：**固定 5 个**动作（不随状态增删 ⇒ 不触发 §2.0.10 的折叠要求）。
      // 外面套 `FittedBox(scaleDown)`：极窄屏（< 320dp）宁可整体缩小，
      // 也**绝不**让它溢出（本仓 258 轮的教训：排不下就往左长、盖住返回键）。
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
          IconButton(
            key: const Key('audio-repeat-one'),
            tooltip: dataText('audioRepeatOne', '单曲循环'),
            isSelected: _repeatOne,
            icon: const Icon(Icons.repeat_one_rounded),
            color: _repeatOne ? theme.colorScheme.primary : DesignPalette.of(context).dim,
            onPressed: () => setState(() => _repeatOne = !_repeatOne),
          ),
          // ★ r651（`DA251`）：只有真的有多条才画（否则是"点了没反应"的假按钮）
          if (_hasQueue)
            IconButton(
              key: const Key('audio-previous'),
              tooltip: t.audioPrevious,
              icon: const Icon(Icons.skip_previous_rounded),
              onPressed: () => unawaited(_switchTo(_queueIndex - 1)),
            ),
          if (_hasQueue)
            IconButton(
              key: const Key('audio-up-next'),
              tooltip: t.audioUpNext,
              icon: const Icon(Icons.queue_music_rounded),
              onPressed: () => unawaited(_showUpNext()),
            ),
          IconButton(
            key: const Key('audio-lyrics-search'),
            tooltip: audioLyricsSearchHintText(),
            icon: const Icon(Icons.lyrics_outlined),
            onPressed: _lyricsLoading
                ? null
                : () => unawaited(_loadLyrics(force: true)),
          ),
          // 播放/暂停：主按钮（真机上必须有**有限**宽度，见下面的 minimumSize 注释）
          FilledButton.tonalIcon(
            key: const Key('audio-play-pause'),
            // ⚠️ 主题里的 `filledButtonTheme.minimumSize` 是
            // `Size.fromHeight(48)`（宽度 = **infinity**）。放进这个
            // **无界宽**的 Row 后，按钮会想占满整行，把两侧时间与倍速挤成
            // 0 宽、自己也画不出来 —— 真机 HONOR LGE-AN10 / API 31 实测就
            // 是"只有滑块、按钮点不到"。这里显式覆盖成有限宽度。
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            ),
            onPressed: _toggle,
            icon: Icon(
              player.playing
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
            ),
            label: Text(
              player.playing ? t.fileMediaPause : t.fileMediaPlay,
            ),
          ),
          if (_hasQueue)
            IconButton(
              key: const Key('audio-next'),
              tooltip: t.audioNext,
              icon: const Icon(Icons.skip_next_rounded),
              onPressed: () => unawaited(_switchTo(_queueIndex + 1)),
            ),
          PopupMenuButton<int>(
            key: const Key('audio-sleep'),
            tooltip: _sleepMinutes == null
                ? dataText('asSleepTimerSet', '设置睡眠定时')
                : dataText('asSleepTimerCancelLong', '取消睡眠定时'),
            icon: Icon(
              Icons.bedtime_outlined,
              color: _sleepMinutes == null
                  ? DesignPalette.of(context).dim
                  : theme.colorScheme.primary,
            ),
            onSelected: (minutes) {
              if (minutes <= 0) {
                _cancelSleepTimer();
                return;
              }
              _startSleepTimer(minutes);
            },
            itemBuilder: (_) => [
              if (_sleepMinutes != null)
                PopupMenuItem(
                  key: const Key('audio-sleep-off'),
                  value: 0,
                  child: Text(dataText('asSleepTimerCancel', '取消')),
                ),
              for (final m in kSleepTimerMinutes)
                PopupMenuItem(
                  key: Key('audio-sleep-$m'),
                  value: m,
                  child: Text(
                    dataText('asSleepTimerMinutes', '{m} 分钟').replaceAll(
                      '{m}',
                      '$m',
                    ),
                  ),
                ),
            ],
          ),
          PopupMenuButton<double>(
            key: const Key('audio-speed'),
            tooltip: '${player.speed}x',
            onSelected: (v) => unawaited(_setSpeed(v)),
            icon: Text(
              '${player.speed}x',
              style: theme.textTheme.labelLarge,
            ),
            itemBuilder: (_) => [
              for (final s in kMediaSpeeds)
                PopupMenuItem(value: s, child: Text('${s}x')),
            ],
          ),
          ],
        ),
      ),
      if (_sleepMinutes != null)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xxs),
          child: Text(
            dataText('asSleepTimerRemaining', '睡眠定时 · {left}').replaceAll(
              '{left}',
              dataText(
                'asSleepTimerMinutes',
                '{m} 分钟',
              ).replaceAll('{m}', '$_sleepMinutes'),
            ),
            key: const Key('audio-sleep-active'),
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
          ),
        ),
    ];
  }
}
