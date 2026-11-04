import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import 'audio_labels.dart';
import 'audio_radio_failure.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../design/design_palette.dart';
import '../media/audio_handler.dart';
import 'audio_radio_desc.dart';
import 'audio_radio_icy.dart';

export 'audio_radio_desc.dart' show asRadioHumanDesc;

/// 电台「人话」副标题（r631）。
///
/// 用户 2026-10-23：「很多音频技术参数没有必要罗列在界面上」。而 SHOUTcast /
/// Icecast 的 `desc` 恰恰经常就是 `MP3 (192 kbps)` 这种**纯技术串** ——
/// 旧版把它原样当副标题画在播放条上。
///
/// 处理口径（宁可少说，也不说技术）：
///   * 把 `(...)` 里含 `kbps/kHz/bit/AAC/MP3/OGG/FLAC/WMA/HE-` 的片段切掉；
///   * 剩下的**还有人话**（≥2 个字符、含字母/汉字）才用；
///   * 否则回落到播放状态文案（`正在播放` / `已暂停`）—— 这是用户此刻
///     真正关心的一件事。
String asRadioPlayingStateText({required bool playing, required String desc}) {
  final cleaned = asRadioHumanDesc(desc);
  final state = playing
      ? dataText('asRadioNowPlaying', '正在播放')
      : dataText('asRadioPaused', '已暂停');
  // ★ r653（`DA258`）：通知栏发布时已把电台副标题清洗成「正在播放」这类人话，
  //   面板再拼一次就成了「正在播放 · 正在播放」（真机当场看到）。
  if (cleaned.isEmpty || cleaned == state) return state;
  return '$state · $cleaned';
}

/// 打开电台播放器面板（r631）。
///
/// 人类视角的三块：
///   ① **电台**：图标 + 台名 + 正在播放/已暂停（+ 人话描述）；
///   ② **主控**：大播放/暂停键、停止；
///   ③ **电台信息**（可折叠，默认收起）：流地址（打码 + 复制）、描述、编码说明。
///
/// 技术参数默认收在第三块里 —— 这正是用户要的"收在某一个菜单项里"。
/// [onRetry]：起播失败后的"重试"要**由页面**去做（它手里才有那条电台的 DTO/
/// 解析后的地址）。不给就回落到 `handler.play()`（真的再试一次当前这条）。
Future<void> showRadioPlayerSheet(
  BuildContext context, {
  required MediaItem item,
  VoidCallback? onRetry,
}) {
  // ★ r631：弹层走的是 `Navigator` 的 overlay，**拿不到页面里 `DesignScaffold`
  //   那层 `Theme`**（真机第一版弹层主色是全局蓝、而页面是设计稿的深青 ⇒ 同一页
  //   两种主色）。把调用点的 `Theme` 显式带过去。
  final theme = Theme.of(context);
  final surface = DesignPalette.of(context).surface;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: surface,
    builder: (_) => Theme(
      data: theme,
      child: SafeArea(
        key: const Key('as-radio-sheet'),
        child: _RadioPlayerSheet(item: item, onRetry: onRetry),
      ),
    ),
  );
}

class _RadioPlayerSheet extends ConsumerStatefulWidget {
  const _RadioPlayerSheet({required this.item, this.onRetry});

  final MediaItem item;
  final VoidCallback? onRetry;

  @override
  ConsumerState<_RadioPlayerSheet> createState() => _RadioPlayerSheetState();
}

class _RadioPlayerSheetState extends ConsumerState<_RadioPlayerSheet> {
  /// 「电台信息」是否展开（默认收起：技术参数不该抢镜）。
  bool _showTech = false;

  /// 提前拿住 notifier：`dispose()` 里**不许**再碰 `ref`（Riverpod 会抛
  /// "Using ref when a widget is about to or has been unmounted"）。
  RadioNowPlayingController? _np;

  /// ★ r641（**DA234**）：面板自己也要听"起播失败"。
  ///
  /// 为什么：失败提示条画在**页面**的 Scaffold 上，而面板是 `Navigator` 的
  /// 弹层 —— 真机上用户只看见面板，提示条在它**下面**（或被播放条盖住）。
  /// 面板里必须自己说一次，并给一个**当场能按**的重试。
  StreamSubscription<AudioEngineFailure>? _failureSub;

  /// 当前这条是否处于"起播失败"态（重试 / 播放成功 / 换条目即清）。
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // ★ r640：**面板打开时**才开始问"这一首在播什么"（关掉就停 —— 看不见的信息
    //   不为它耗流量，也不会在后台留一个定时器）。
    final np = ref.read(radioNowPlayingProvider.notifier);
    _np = np;
    // ★ 放到帧后：`resumePolling()` 会立刻探一次，而"不是当前这条"时会**同步**
    //   改一次 provider 状态 —— 在 `initState` 里改 provider 会被 Riverpod 拦下
    //   （"Tried to modify a provider while the widget tree was building"）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) np.resumePolling();
    });
    _failureSub = ref.read(audioHandlerProvider).engineFailures.listen((f) {
      if (!mounted) return;
      // 只认**这一条**的失败（引擎的错误流是全 App 共享的）
      if (f.mediaId != null && f.mediaId != widget.item.id) return;
      if (_failed) return;
      setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    unawaited(_failureSub?.cancel());
    _failureSub = null;
    _np?.pausePolling();
    super.dispose();
  }

  /// 面板里的「重试」：优先走页面给的回调（重播那条电台，含 `.pls` 解析与中继），
  /// 没有回调就退回 `handler.play()`（对当前这条再试一次 —— 也是真动作）。
  void _retry(SynologyAudioHandler handler) {
    ref.read(radioPlaybackFailureProvider.notifier).clear();
    setState(() => _failed = false);
    final cb = widget.onRetry;
    if (cb != null) {
      cb();
      return;
    }
    handler.play().catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final p = DesignPalette.of(context);
    final handler = ref.watch(audioHandlerProvider);
    final nowPlaying = ref.watch(radioNowPlayingProvider);
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      initialData: handler.playbackState.value,
      builder: (context, snap) {
        final state = snap.data;
        final playing = state?.playing ?? false;
        // ★ r641（**DA234**）：**打开面板时**就要知道"这条刚刚没播出来"
        //   （失败发生在打开之前也一样 —— 页面把事实写进了共享 provider）。
        final sharedFailed = ref.watch(radioPlaybackFailureProvider) ==
            widget.item.id;
        final failed = _failed || sharedFailed;
        // ★ 面板**不自动**清失败态（r641 用例⑤的教训）：
        //   失败后 handler 的 `playing`/`processingState` 都可能还是上一次成功
        //   留下的 `true`/`ready` ⇒ 任何"看起来在播"的判据都会在面板打开的第一帧
        //   把失败态误清掉。清失败只有三个**权威**入口：重试、页面新的成功起播、
        //   关闭播放条。宁可多挂一会儿，也不许在用户眼前把错误抹掉。
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: p.primarySoft,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(Icons.radio, size: 44, color: p.primary),
                ),
              ),
              const SizedBox(height: Gap.md),
              Text(
                widget.item.title,
                key: const Key('as-radio-sheet-title'),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  color: p.text,
                ),
              ),
              const SizedBox(height: Gap.xxs),
              Text(
                asRadioPlayingStateText(
                  playing: playing,
                  desc: widget.item.artist ?? '',
                ),
                key: const Key('as-radio-sheet-state'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: p.muted),
              ),
              // ★ r640（**DA233**）：电台自己报的"正在播的曲目"（ICY StreamTitle）。
              //   只有**这条**在播时才显示（按 mediaId 比），拿不到就整行不出现 ——
              //   绝不摆一个"未知"占着位置。
              if (nowPlaying.matches(widget.item.id)) ...[
                const SizedBox(height: Gap.xs),
                Text(
                  nowPlaying.title!,
                  key: const Key('as-radio-sheet-track'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
              ],
              // ★ r641（**DA234**）：失败就在**面板里**说，并给当场可按的重试
              if (failed) ...[
                const SizedBox(height: Gap.sm),
                Container(
                  key: const Key('as-radio-sheet-failed'),
                  padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.xs, Gap.xs),
                  decoration: BoxDecoration(
                    color: p.primarySoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.error_outline, size: 18, color: p.primary),
                      const SizedBox(width: Gap.xs),
                      Expanded(
                        child: Text(
                          asRadioPlayFailed,
                          style: TextStyle(fontSize: 12.5, color: p.text),
                        ),
                      ),
                      TextButton(
                        key: const Key('as-radio-sheet-retry'),
                        onPressed: () => _retry(handler),
                        child: Text(asRadioPlayRetry),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: Gap.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: IconButton.filled(
                      key: const Key('as-radio-sheet-toggle'),
                      tooltip: playing ? t.asPause : t.asPlay,
                      iconSize: 34,
                      style: IconButton.styleFrom(
                        backgroundColor: p.primary,
                        foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      ),
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: () =>
                          playing ? handler.pause() : handler.play(),
                    ),
                  ),
                  const SizedBox(width: Gap.lg),
                  TextButton.icon(
                    key: const Key('as-radio-sheet-stop'),
                    onPressed: () {
                      // r640：停止 = 这条"正在播的曲目"作废（探针停、状态清）
                      ref.read(radioNowPlayingProvider.notifier).stop();
                      unawaitedStop(handler);
                      Navigator.of(context).maybePop();
                    },
                    icon: const Icon(Icons.stop_circle_outlined, size: 20),
                    label: Text(dataText('asRadioStop', '停止'),
                        key: const Key('as-radio-sheet-stop-label')),
                  ),
                ],
              ),
              const SizedBox(height: Gap.md),
              const Divider(height: 1),
              const SizedBox(height: Gap.xs),
              // ── ③ 电台信息（技术参数的唯一入口） ──────────────────────────
              TextButton.icon(
                key: const Key('as-radio-sheet-tech-toggle'),
                onPressed: () => setState(() => _showTech = !_showTech),
                icon: Icon(
                  _showTech ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
                label: Text(dataText('asRadioInfo', '电台信息')),
              ),
              if (_showTech) _RadioTechSection(item: widget.item),
            ],
          ),
        );
      },
    );
  }
}

/// 停止播放：`handler.stop()` 是异步的，这里不 await（面板马上要关）。
void unawaitedStop(SynologyAudioHandler handler) {
  handler.stop().catchError((Object _) {});
}

/// 技术参数（默认收起）：**只有电台自己给的描述**。
///
/// 为什么这里没有"流地址"：电台地址的完整串里带会话/中继凭据，而播放条只拿得到
/// `MediaItem`（audio_service 的模型**不含 URL**）。为了不在系统媒体元数据里
/// 夹带凭据，r631 明确**不**把 URL 塞进 `extras` —— 自定义电台的地址在
/// 「编辑电台」对话框里本来就可读写（那里才是它该在的地方）。
/// 这条取舍写进了 `docs/android-ui-audit-r631.md`（诚实缺口，不是遗忘）。
class _RadioTechSection extends StatelessWidget {
  const _RadioTechSection({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final p = DesignPalette.of(context);
    final desc = (item.artist ?? '').trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TechRow(
          label: dataText('asRadioDesc', '描述'),
          value: desc.isEmpty ? dataText('asRadioDescEmpty', '（电台未提供描述）') : desc,
          valueKey: const Key('as-radio-tech-desc'),
        ),
        const SizedBox(height: Gap.xxs),
        Text(
          dataText(
            'asRadioTechHint',
            '地址与编码由电台服务端决定；需要修改请到「编辑电台」。',
          ),
          key: const Key('as-radio-tech-hint'),
          style: TextStyle(fontSize: 11, color: p.dim),
        ),
      ],
    );
  }
}

class _TechRow extends StatelessWidget {
  const _TechRow({
    required this.label,
    required this.value,
    required this.valueKey,
  });

  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    final p = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: TextStyle(fontSize: 12, color: p.muted)),
          ),
          Expanded(
            child: Text(
              value,
              key: valueKey,
              style: TextStyle(fontSize: 12, color: p.text),
            ),
          ),
        ],
      ),
    );
  }
}
