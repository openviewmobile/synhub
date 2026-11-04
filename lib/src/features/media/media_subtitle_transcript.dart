// 字幕全文（同步滚动）—— r637。
//
// 用户第一轮就点名要的："字幕的同步滚动效果这个还没有"。
//
// 两条边界先说清楚（不给自己留"假装"的空间）：
//   * **只对外挂字幕开放**。`.srt/.vtt/.ass` 解析成 [SubtitleCue] 后整条轨道都在
//     手上，才能"列出全文 + 跟着播";内封字幕经 Media3 只给**当前这一帧的文本**
//     （`Player.Listener.onCues`），拿不到"后面还会说什么" ⇒ 那一路不摆这个入口。
//   * **复用全屏歌词那套滚动算法**（[SyncedLyricsView]：首帧就位、只在行号变化时
//     滚动、用户手动滚开后让位、减少动态效果时 `jumpTo`）。同一份时间轴，不写
//     第二套滚动逻辑 —— 那套已经在真机上过了。
//
// 交互按"人怎么看字幕"设计：
//   * 打开就停在**正在播的那一句**；
//   * 播放推进 ⇒ 列表跟着滚、当前句高亮；
//   * 手指滚开 ⇒ 自动跟随让位一会儿（不跟手指抢）；
//   * 点任意一句 ⇒ 跳到那句。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';

import '../../core/theme/app_tokens.dart';
import '../../design/design_palette.dart';
import 'audio_lyrics.dart' show LrcDocument, LyricLine;
import 'audio_lyrics_view.dart';
import 'media_subtitles.dart' show SubtitleCue;

/// `SubtitleCue` 列表 → [LrcDocument]（给 [SyncedLyricsView] 用的同一份时间轴）。
///
/// 两个细节：
///   * 字幕里的换行在"一行一条"的列表里没有意义 ⇒ 折成空格（否则一行被撑成三行，
///     高亮盒高度和 `lineHeight` 对不上，居中的那一句会偏）；
///   * 保留**原始顺序**（解析器已按 start 升序，别在这里再排一次 —— 稳定排序
///     对同 start 的多条字幕（双行字幕）顺序有影响，重排会让它们来回跳）。
LrcDocument subtitleTranscriptDocument(List<SubtitleCue> cues) {
  return LrcDocument(
    lines: <LyricLine>[
      for (final cue in cues)
        LyricLine(
          time: cue.start,
          text: cue.text.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim(),
        ),
    ],
    plainText: cues.map((c) => c.text).join('\n'),
  );
}

/// 字幕全文面板（标题 + 条数 + 同步滚动的正文）。
///
/// 位置从 [position] 来（播放器把它挂在 `changes` 监听上）——面板是
/// `showModalBottomSheet` 里的一棵独立子树，父视图 `setState` 不会重建它，
/// 所以只能用可取值的源，不能用"父视图重建"这条链路。
class MediaSubtitleTranscript extends StatelessWidget {
  const MediaSubtitleTranscript({
    super.key,
    required this.cues,
    required this.position,
    this.onSeek,
    this.height = 360,
  });

  final List<SubtitleCue> cues;

  /// 当前播放位置（唯一同步来源；暂停时它不前进，高亮自然不动）。
  final ValueListenable<Duration> position;

  /// 点某一句 ⇒ 跳到该句起点。
  final ValueChanged<Duration>? onSeek;

  /// 面板总高（正文高度 = 这个值减去标题行）。
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doc = subtitleTranscriptDocument(cues);
    return SafeArea(
      key: const Key('media-subtitle-transcript-sheet'),
      top: false,
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.t.mediaSubtitleTranscript,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    '${cues.length}',
                    key: const Key('media-subtitle-transcript-count'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: DesignPalette.of(context).dim,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<Duration>(
                valueListenable: position,
                builder: (ctx, pos, _) => SyncedLyricsView(
                  key: const Key('media-subtitle-transcript'),
                  document: doc,
                  position: pos,
                  height: height - 72,
                  lineKeyPrefix: 'subtitle-line',
                  onSeek: onSeek,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
