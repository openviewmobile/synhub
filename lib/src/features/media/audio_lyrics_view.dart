// 歌词**滚动视图**（有时间轴 → 逐行高亮 + 自动居中滚动 + 点行跳转；
// 没时间轴 → 照实平铺、可滚动、**不高亮**）。
//
// ════════════════════════════════════════════════════════════════════════
// 为什么会有这个文件（用户报障，第 274 轮）
// ════════════════════════════════════════════════════════════════════════
// 用户原话：「歌词也没有滚动的效果」。
//
// 真机取证（Honor LGE-AN10，2026-09-26）：Audio Station 单曲页的歌词区
// 只有一个 `SelectableText(整段歌词)` —— 它**能滚，但不会跟着播放走**，
// 也没有"当前这一句"的高亮。所以用户感受就是"歌词没有滚动效果"。
//
// 同时，仓库里**已经有**一套解析好的歌词模型（`audio_lyrics.dart` 的
// `LrcDocument` / `LyricLine` / `parseLrc`），文件预览页
// （`media_audio_stage.dart`）在用。本文件把"滚动/高亮/居中"这部分做成
// **可复用的视图**，让 Audio Station 与文件预览页走同一套渲染
// （AGENTS §2.0.8 ④：同一份文档，不同入口必须走同一个阅读器）。
//
// ## 诚实的三种状态（不许假装）
//
// | 输入 | 渲染 | 会不会滚动 |
// |---|---|---|
// | `LrcDocument.timed == true` | 逐行列表，当前行高亮，自动居中 | **会**（跟播放位置） |
// | `timed == false`（只有纯文本） | 平铺的行，顶部标注「无时间轴」 | 用户手动滚动，**不假装同步** |
// | `isEmpty` | 由调用方给"没有歌词"的空态 | — |
//
// ★ **绝不**给无时间轴的歌词编一套时间轴去"看起来能滚" —— 那是假同步。
//
// ## 自动滚动与手动滚动**不打架**
//
// 用户正在拖 / 刚拖完 `kLyricAutoScrollResumeDelay` 之内，自动跟随**让位**
// （否则手指还按着，歌词被播放位置拽回去，根本没法看后面的词）。
// 判定是纯函数 `lyricAutoScrollAllowed()`，可离线单测。
//
// ## 省电 / 无障碍
//
// * 只在**当前行下标变化**时才滚（不是每帧都滚）；
// * 系统开"减少动态效果"（`MediaQuery.disableAnimations`）→ 用 `jumpTo`
//   而不是动画；
// * 行高固定（`itemExtent`）+ `ListView.builder` 惰性构建 ⇒ 长歌词不卡。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'audio_lyrics.dart';

/// 一行歌词的高度（固定 → `itemExtent` 才能成立，滚动才精确）。
///
/// 与文件预览页 `media_audio_stage.dart` 的 `kAudioLyricLineHeight` 同值：
/// 两个入口的歌词视觉必须一致（同一份文档同一个渲染）。
const double kLyricViewLineHeight = 28;

/// 用户手动滚动之后，自动跟随**让位**多久。
const Duration kLyricAutoScrollResumeDelay = Duration(seconds: 4);

/// 自动滚动一次用多久（行与行之间的平滑过渡）。
const Duration kLyricAutoScrollDuration = Duration(milliseconds: 320);

/// 当前该高亮的歌词行下标（纯函数）。
///
/// 返回"时间点 ≤ [position] 的**最后**一行"；[position] 在第一行之前
/// （前奏）或没有时间轴时返回 `-1`（**不硬指一行**，前奏时就该没有高亮）。
int activeLyricLineIndex(List<LyricLine> lines, Duration position) {
  if (lines.isEmpty) return -1;
  final ms = position.inMilliseconds;
  if (ms < lines.first.time.inMilliseconds) return -1;
  // 时间轴已按升序排好（`parseLrc` 保证）⇒ 二分找最后一个 <= ms 的行。
  var lo = 0;
  var hi = lines.length - 1;
  var best = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].time.inMilliseconds <= ms) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best;
}

/// 让第 [index] 行**垂直居中**所需的目标滚动偏移（纯函数，已 clamp）。
///
/// [maxScrollExtent] 未知（还没布局完）时按 `double.infinity` 处理 ——
/// 返回未截断的目标值，调用方拿到真实 extent 后自然会收敛。
double lyricCenteredScrollOffset({
  required int index,
  required int lineCount,
  required double viewportHeight,
  required double lineHeight,
  required double maxScrollExtent,
  /// ★ r477：列表**顶部留白**（`ListView.padding.top`）。
  ///
  /// 原公式只按 `index*行高` 算，等价于"留白 = 0"；而视图为了让高亮行居中，
  /// 顶部留了半屏 ⇒ 公式与真实坐标**差了半个视口**：改留白（或留白随状态变化）时，
  /// 高亮行会被挤到视口底部（r476 真机当场量到，见 `docs/evidence-r476/`）。
  /// 把留白作为参数传进来，等号两边才是同一套坐标。
  double topPadding = 0,
}) {
  if (index < 0 || lineCount <= 0 || lineHeight <= 0) return 0;
  if (!viewportHeight.isFinite || viewportHeight <= 0) return 0;
  final raw =
      topPadding + index * lineHeight + lineHeight / 2 - viewportHeight / 2;
  if (!raw.isFinite) return 0;
  final upper = maxScrollExtent.isFinite ? math.max(0.0, maxScrollExtent) : raw;
  final lower = 0.0;
  if (upper <= lower) return lower;
  return raw.clamp(lower, upper);
}

/// 现在允许自动跟随吗（纯函数）。
///
/// * 用户**正在**拖 → 不让位不行；
/// * 刚拖完 [resumeDelay] 之内 → 也不跟随（给用户看完那几行的时间）；
/// * 其余情况 → 跟随。
bool lyricAutoScrollAllowed({
  required bool userScrolling,
  required Duration sinceUserScroll,
  Duration resumeDelay = kLyricAutoScrollResumeDelay,
}) {
  if (userScrolling) return false;
  return sinceUserScroll >= resumeDelay;
}

/// 第 [index] 行是否**完整地**落在视口里（纯函数）。
///
/// ★ r644（**DA239**）：用户手动滑走之后，"回到正在唱的那句"这个落点
/// **只在当前行真的看不见了**才出现 —— 一直挂着就成了永久占位的假控件。
///
/// 坐标与 [lyricCenteredScrollOffset] 同一套：行顶 = `topPadding + index*行高`。
bool lyricActiveLineVisible({
  required int index,
  required double lineHeight,
  required double topPadding,
  required double offset,
  required double viewportHeight,
}) {
  if (index < 0 || lineHeight <= 0) return false;
  if (!viewportHeight.isFinite || viewportHeight <= 0) return false;
  final top = topPadding + index * lineHeight;
  final bottom = top + lineHeight;
  return top >= offset - 0.5 && bottom <= offset + viewportHeight + 0.5;
}

/// 歌词**署名行**（★ DA66，r411）：屏上这一份是谁的、从哪个源来的。
///
/// 两个入口（Audio Station 单曲页 / 文件预览页）**必须用同一个**渲染，
/// 理由同本文件头（§2.0.8 ④：同一份数据走同一个阅读器）。
///
/// 只在**确实有歌词**时才画（[document] 为 null/空 ⇒ `SizedBox.shrink()`）：
/// 空态已经有一句「没有找到这首歌的歌词」，这里再写一遍就是两句。
class LyricsAttributionLine extends StatelessWidget {
  const LyricsAttributionLine({
    super.key,
    required this.document,
    this.chosen,
    this.fromCache = false,
    this.textKey,
  });

  /// 当前**屏上正在显示**的那份歌词（判据取它，不取"最近一次搜到的"）。
  final LrcDocument? document;

  /// 当前选中的公开源候选（null = 这份来自 NAS 歌词库）。
  final LyricCandidate? chosen;

  /// 是不是直接命中本地缓存。
  final bool fromCache;

  /// 文本节点自己的 key（两处面板各给一个，便于按页断言）。
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final doc = document;
    if (doc == null || doc.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xxs),
      child: Text(
        audioLyricsAttributionText(
          chosen: chosen,
          fromCache: fromCache,
          timed: doc.timed,
        ),
        key: textKey,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
      ),
    );
  }
}

/// 歌词滚动视图。
///
/// 用法（Audio Station 单曲页 / 文件预览页）：
/// ```dart
/// SyncedLyricsView(
///   document: parseLrc(rawLyrics),
///   position: handler.position,
///   onSeek: (at) => handler.seek(at),   // 有时间轴才给
/// )
/// ```
class SyncedLyricsView extends StatefulWidget {
  const SyncedLyricsView({
    super.key,
    required this.document,
    required this.position,
    this.onSeek,
    this.height = 260,
    this.lineHeight = kLyricViewLineHeight,
    this.autoScrollDelay = kLyricAutoScrollResumeDelay,
    this.now,
    this.lineKeyPrefix = 'lyrics-line',
    this.untimedHintKey = const Key('lyrics-untimed-hint'),
    this.fontScale = 1.0,
    this.onCopied,
    this.listKey = const Key('lyrics-timed-list'),
    this.activeLineKey,
    this.textAlign = TextAlign.left,
  });

  /// 解析好的歌词（时间轴/纯文本两种形态都在里面）。
  final LrcDocument document;

  /// 当前播放位置（**唯一**的同步来源；暂停时它不前进，高亮自然不动）。
  final Duration position;

  /// 点某一行跳转（null = 不给这个交互；无时间轴时一律不触发）。
  final ValueChanged<Duration>? onSeek;

  /// 视口高度。
  final double height;

  final double lineHeight;

  final Duration autoScrollDelay;

  /// 时间源（单测注入，生产用 `DateTime.now`）。
  final DateTime Function()? now;

  /// 行 key 前缀（测试按 `Key('$prefix-$i')` 定位）。
  final String lineKeyPrefix;

  /// 无时间轴提示的 key（测试断言"如实标注"用）。
  final Key untimedHintKey;

  /// ★ r633（**DA220**）：字号倍率（全屏歌词的 `A-` / `A+`）。
  ///
  /// 只作用在**歌词正文**上；行高由调用方一起给（`lineHeight`），
  /// 否则字号变大后行距不变 ⇒ 字挤在一起。
  final double fontScale;

  /// 长按一行复制成功后回调（宿主弹提示条；视图自己不认识 Scaffold）。
  final ValueChanged<String>? onCopied;

  /// ★ r652（**DA253**）：时间轴列表的 key。
  ///
  /// 文件预览页（音频舞台）与 Audio Station 单曲页**必须走同一个阅读器**
  /// （AGENTS §2.0.8 ④），但两边的既有 key 不同（`audio-lyrics` /
  /// `lyrics-timed-list`）。key 是**宿主的定位契约**，不是渲染语义 ⇒
  /// 用参数分开，渲染与行为仍然只有这一份实现。
  final Key listKey;

  /// 当前正在唱的那一行**额外**挂的 key（宿主用它做"有没有高亮"的判据）。
  final Key? activeLineKey;

  /// 行文本的对齐（大字屏/全屏左对齐好读；舞台的小面板居中更好看）。
  final TextAlign textAlign;

  @override
  State<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends State<SyncedLyricsView> {
  final ScrollController _scroll = ScrollController();

  int _active = -1;

  /// 列表**顶部留白**：有高亮行时留半屏（那一行才能停在正中）；没有高亮行时
  /// （还没起播 / 前奏）只留一点点 —— 否则歌词卡顶部白掉半屏（r476 现场）。
  ///
  /// 这个值同时用于 `padding` 与 `lyricCenteredScrollOffset(topPadding:)`，
  /// **不许只改一处**（r476 就是只改了 padding，真机高亮行贴到底部）。
  /// ★ r631（DA213）：`height` 是**有限值**才拿来算留白。
  ///
  /// 调用方传 `double.infinity`（曾经的真机 bug：整屏歌词凭空消失）时，
  /// 这里兜住 —— 无穷大的 padding 会让每一行都被推出视口，画面只剩署名。
  double get _pad {
    if (_active < 0) return 8.0;
    if (!widget.height.isFinite || widget.height <= 0) return 8.0;
    return widget.height / 2;
  }

  /// 用户正在拖 / 刚拖完的时刻（自动跟随让位的依据）。
  bool _userScrolling = false;
  DateTime? _lastUserScroll;

  /// ★ r644（**DA239**）：当前正在唱的那行**已经滑出视口**。
  bool _activeHidden = false;

  /// ★ r644（**DA240**）：视口上下**还有没有内容**（有内容的那一边才渐隐）。
  bool _canScrollUp = false;
  bool _canScrollDown = false;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScrolled);
    // 歌词视图曝光（视图模式偏好）。
    trackViewMode(UsageModule.media, 'lyrics');
    _active = activeLyricLineIndex(widget.document.lines, widget.position);
    // ★ r633（**DA220**）：**首帧就对到当前行**。
    //
    // 旧版只设了 `_active`，滚动只在 `didUpdateWidget` 且**行号变了**时发生。
    // 用户"暂停中"点开全屏歌词时，位置流不会再推新值 ⇒ 视图停在**第 0 行**，
    // 屏上是歌词开头 + 半屏空白，正在唱的那句根本不在视野里
    // （Plexamp 这类"点开就在当前句"是基本盘）。
    if (_active >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followActive());
    }
    _recomputeAfterLayout();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScrolled);
    _scroll.dispose();
    super.dispose();
  }

  /// 滚动位置/视口变了 ⇒ 重算「当前行还在不在视野里」和「两边还有没有内容」。
  ///
  /// 只在这些**布尔值真的翻转**时才 `setState` —— 否则每一帧滚动都重建整棵
  /// 歌词列表（长歌词下真机会掉帧）。
  void _onScrolled() {
    if (!mounted || !_scroll.hasClients) return;
    final hidden = !lyricActiveLineVisible(
      index: _active,
      lineHeight: widget.lineHeight,
      topPadding: _pad,
      offset: _scroll.offset,
      viewportHeight: _scroll.position.viewportDimension,
    );
    final up = _scroll.offset > 1;
    final down = _scroll.offset < _scroll.position.maxScrollExtent - 1;
    if (hidden == _activeHidden && up == _canScrollUp && down == _canScrollDown) {
      return;
    }
    setState(() {
      _activeHidden = hidden;
      _canScrollUp = up;
      _canScrollDown = down;
    });
  }

  /// 布局刚变（换歌 / 换字号 / 首帧对齐）之后补算一次 —— 那些时刻不产生滚动事件。
  void _recomputeAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScrolled();
    });
  }

  @override
  void didUpdateWidget(SyncedLyricsView old) {
    super.didUpdateWidget(old);
    // 换了一首歌/换了一版歌词 ⇒ 旧的滚动位置没有意义，重新对齐当前行。
    if (!identical(old.document, widget.document) ||
        old.fontScale != widget.fontScale) {
      _active = activeLyricLineIndex(widget.document.lines, widget.position);
      WidgetsBinding.instance.addPostFrameCallback((_) => _followActive());
      _recomputeAfterLayout();
      return;
    }
    final next = activeLyricLineIndex(widget.document.lines, widget.position);
    if (next == _active) return;
    final previous = _active;
    _active = next;
    // 只在**行变了**的时候滚（不是每次位置更新都滚）——省电，也不跟用户抢。
    if (next >= 0 && next != previous) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followActive());
    }
  }

  void _followActive() {
    if (!mounted || !_scroll.hasClients) return;
    final since = _lastUserScroll == null
        ? const Duration(days: 1)
        : _now.difference(_lastUserScroll!);
    if (!lyricAutoScrollAllowed(
      userScrolling: _userScrolling,
      sinceUserScroll: since,
      resumeDelay: widget.autoScrollDelay,
    )) {
      return;
    }
    final target = lyricCenteredScrollOffset(
      index: _active,
      lineCount: widget.document.lines.length,
      viewportHeight: _scroll.position.viewportDimension,
      lineHeight: widget.lineHeight,
      maxScrollExtent: _scroll.position.maxScrollExtent,
      topPadding: _pad,
    );
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: kLyricAutoScrollDuration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// ★ r644（**DA239**）：立刻回到正在唱的那句（**不等**让位计时）。
  void _jumpToActive() {
    _lastUserScroll = null;
    _userScrolling = false;
    _followActive();
    // 滚完之后 `_onScrolled` 会把 `_activeHidden` 翻回 false（按钮自己消失）。
  }

  bool _onScrollNotification(ScrollNotification n) {
    // `dragDetails != null` ⇒ 这次滚动是**手指**驱动的（含惯性滑动期间）。
    final userDriven = switch (n) {
      ScrollStartNotification(:final dragDetails) => dragDetails != null,
      ScrollUpdateNotification(:final dragDetails) => dragDetails != null,
      UserScrollNotification() => true,
      _ => false,
    };
    if (userDriven) {
      _userScrolling = n is! ScrollEndNotification;
      _lastUserScroll = _now;
    } else if (n is ScrollEndNotification) {
      _userScrolling = false;
    }
    // 不拦截事件：列表自己要能滚。
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.document;
    if (doc.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // 无时间轴：**照实**平铺 + 明确标注，不假装能同步。
    if (!doc.timed) {
      final lines = doc.plainText
          .split(RegExp(r'\r?\n'))
          .where((l) => l.trim().isNotEmpty)
          .toList(growable: false);
      // `ConstrainedBox(maxHeight:)` 给 Column **有限**的主轴上界 ⇒ 里面的
      // `Flexible` 才拿得到"标签之后剩下的高度"（调用方把本视图放进无界 Column
      // 时也不会炸：上界由这里的 maxHeight 提供；260 装不下标签 + 4dp 间隙 + 列表
      // 时按剩余空间收缩，**不溢出**）。
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.height),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          // 复用文件预览页那一条**同一句话**（`audio_lyrics.dart` 的
          // `audioLyricsPlainTextHintText`）：两个入口对"没时间轴"必须说同样的话，
          // 否则用户以为两个页面做的事不一样。
          Text(
            audioLyricsPlainTextHintText(),
            key: widget.untimedHintKey,
            style: theme.textTheme.labelSmall?.copyWith(
              color: DesignPalette.of(context).dim,
            ),
          ),
            const SizedBox(height: Gap.xxs),
            Flexible(
              child: Scrollbar(
                child: ListView.builder(
                  key: const Key('lyrics-untimed-list'),
                  itemCount: lines.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      lines[i],
                      key: Key('${widget.lineKeyPrefix}-$i'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final Widget list = ListView.builder(
          key: widget.listKey,
          controller: _scroll,
          itemExtent: widget.lineHeight,
          itemCount: doc.lines.length,
          // ★ r477：留白跟着"有没有高亮行"走，并把**同一个值**喂给居中公式
          //   （见 `_pad` 与 `lyricCenteredScrollOffset(topPadding:)`）。
          //   r476 只改留白不改公式 ⇒ 真机高亮行被挤到视口底部（已回退）；
          //   两者必须一起改，否则等号两边不是同一套坐标。
          padding: EdgeInsets.symmetric(vertical: _pad),
          itemBuilder: (context, i) {
            final line = doc.lines[i];
            final active = i == _active;
            final text = line.text.isEmpty ? '♪' : line.text;
            final baseStyle = (active
                    ? theme.textTheme.titleMedium
                    : theme.textTheme.bodyMedium) ??
                const TextStyle();
            final child = Align(
              alignment: switch (widget.textAlign) {
                TextAlign.center => Alignment.center,
                TextAlign.right => Alignment.centerRight,
                _ => Alignment.centerLeft,
              },
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                // ★ r633（DA220）：字号倍率只作用在**歌词正文**
                style: widget.fontScale == 1.0
                    ? baseStyle
                    : baseStyle.copyWith(
                        fontSize: (baseStyle.fontSize ?? 14) *
                            widget.fontScale,
                      ),
                child: Text(
                  text,
                  // 宿主给了 `activeLineKey` 时，**当前行**改用那个 key
                  // （宿主的用例按它取这一行的 `Text`）；其余行仍是行号 key。
                  // 行号 key 在下面由 `KeyedSubtree` 兜住 ⇒ 任何一行都能按行号点到。
                  key: widget.activeLineKey == null
                      ? Key('${widget.lineKeyPrefix}-$i')
                      : (active
                            ? widget.activeLineKey
                            // 行号 key 已在上面的 `KeyedSubtree` 上 ⇒
                            // 这里换一个后缀，**不许重复**（重复的 key 会让
                            // `find.byKey` 一次找到两个，`tap()` 直接报歧义）。
                            : Key('${widget.lineKeyPrefix}-text-$i')),
                  textAlign: widget.textAlign,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? scheme.primary : null,
                    fontWeight: active ? FontWeight.w600 : null,
                  ),
                ),
              ),
            );
            // ★ r633（DA220）：**长按复制这一句**。
            //
            // 用户常常想把一句歌词发给别人 / 记下来；旧版每一行只有"点 = 跳转"，
            // 连选字都做不到（`Text` 不是 `SelectableText`，也没有长按菜单）。
            // 长按不抢 `onTap`（点仍是 seek），两者同时存在。
            void copy() {
              final payload = line.text.isEmpty ? text : line.text;
              unawaited(Clipboard.setData(ClipboardData(text: payload)));
              widget.onCopied?.call(payload);
            }

            // ★ r652（DA253）：**宿主接管的 key 契约**
            //
            // 舞台（`activeLineKey != null`）沿用历史契约：行的容器就是
            // `Key('<prefix>-<i>')`，且**没有可点动作时仍是 `InkWell`（onTap: null）**
            // —— 用例正是按这个断言"点了没反应"，不能靠"换成另一类控件"来表达。
            // 默认模式（单曲页/全屏）保持 `-tap-` 那套（既有用例沿用）。
            final hostMode = widget.activeLineKey != null;
            final rowKey = hostMode
                ? Key('${widget.lineKeyPrefix}-$i')
                : Key('${widget.lineKeyPrefix}-tap-$i');
            if (widget.onSeek == null && !hostMode) {
              return GestureDetector(
                key: rowKey,
                behavior: HitTestBehavior.opaque,
                onLongPress: copy,
                child: child,
              );
            }
            return InkWell(
              key: rowKey,
              onTap: widget.onSeek == null
                  ? null
                  : () => widget.onSeek!(line.time),
              onLongPress: copy,
              child: child,
            );
          },
    );

    // ★ r644（**DA240**）：边缘渐隐。
    //
    // 真机像素上，视口边缘那一行是"齐刀切掉"的半行，紧贴署名行时像被压住。
    // 只给**还有内容**的那一边渐隐：到顶/到底时那里确实没东西，渐隐会骗人。
    //
    // ★ r644 第二轮（宿主用例 `DA220` 当场红）：这里**不许**按状态"包/不包" ——
    //   `ListView` 的父级类型一变（裸 `ListView` ↔ `ShaderMask`）会让元素重建、
    //   `ScrollPosition` 归零 ⇒ 首帧"对齐当前句"看起来没发生。`EdgeFade` 必须常驻。
    final shown = EdgeFade(
      key: const Key('lyrics-edge-fade'),
      fadeTop: _canScrollUp,
      fadeBottom: _canScrollDown,
      fadeDepth: 28,
      child: list,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.height),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: Stack(
          children: [
            Positioned.fill(child: shown),
            // ★ r644（**DA239**）：只有当前行**真的不在视野里**才摆这个落点。
            if (_activeHidden && _active >= 0)
              Positioned(
                right: 0,
                bottom: Gap.xs,
                child: _JumpToActiveButton(onTap: _jumpToActive),
              ),
          ],
        ),
      ),
    );
  }
}

/// 「回到正在唱的那句」——48dp 最小点击区，滑走后出现、点完自己消失。
class _JumpToActiveButton extends StatelessWidget {
  const _JumpToActiveButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = audioLyricsJumpToActiveText();
    return Material(
      color: scheme.surfaceContainerHighest,
      elevation: 3,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('lyrics-jump-to-active'),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.my_location, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 视口上下边缘的渐隐遮罩（★ r644 `DA240`）。
///
/// **必须常驻**在歌词列表外面：只在需要时包一层 `ShaderMask` 会让 `ListView`
/// 换父级类型 ⇒ 元素重建、滚动位置归零（宿主用例 `DA220` 当场抓到）。
/// 没有需要渐隐的一侧时，那一侧就是**完全不透明**（视觉上等于没有遮罩）。
class EdgeFade extends StatelessWidget {
  const EdgeFade({
    super.key,
    required this.child,
    this.fadeTop = false,
    this.fadeBottom = false,
    this.fadeDepth = 28,
  });

  final Widget child;

  /// 上/下边界是否还有内容（= 要不要渐隐）。
  final bool fadeTop;
  final bool fadeBottom;

  /// 渐隐带的高度（逻辑像素）。
  final double fadeDepth;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final h = rect.height <= 0 ? 1.0 : rect.height;
        final f = (fadeDepth / h).clamp(0.0, 0.25);
        const clear = Color(0x00000000);
        const solid = Color(0xFF000000);
        if (!fadeTop && !fadeBottom) {
          // 两侧都没内容：整块不透明
          return const LinearGradient(colors: [solid, solid]).createShader(rect);
        }
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            fadeTop ? clear : solid,
            solid,
            solid,
            fadeBottom ? clear : solid,
          ],
          stops: f <= 0 ? const [0.0, 0.0, 1.0, 1.0] : [0.0, f, 1.0 - f, 1.0],
        ).createShader(rect);
      },
      child: child,
    );
  }
}
