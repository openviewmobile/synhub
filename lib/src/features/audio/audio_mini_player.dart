// 全局「正在播放」迷你条（r633）。
//
// 用户 2026-10-23：「音频，包括音乐与电台播放器也需要重新设计，从人类用户使用
// 角度……」。审计当场拍到的现场：电台在播，退到「音乐列表 / 工作台」之后，
// **整个界面没有任何地方能看见它、也没有地方能暂停** —— 唯一的出口是重新
// 走回电台页（`_RadioNowPlayingBar` 只挂在 `audio_radio_page.dart` 里）。
// 播放器类 App（Plexamp / Apple Music / Spotify）都有这一条：底栏之上常驻一条
// 迷你播放条，任何页面都能看见"在放什么"、一点就暂停、再点就回到播放器。
//
// 设计取舍（人视角）：
//   * **只放一个动作**（播放/暂停）。点标题区域才是"回到播放器" —— 避免把整条
//     做成两种语义混在一起的按钮。
//   * 副标题说人话：音乐给「歌手 · 专辑」，电台给清洗过的描述或「正在播放」
//     （码率一类的技术串一律不进这里，规则复用 `asRadioHumanDesc`）。
//   * 没在播（`processingState == idle` 或没有 `mediaItem`）时**整条不出现**，
//     不占位、不假装 —— 与 `_RadioNowPlayingBar` 同一状态口径（唯一状态源是
//     `audioHandlerProvider`）。
//   * 点开的目标靠 `MediaItem.extras['kind']` 判断（r633 起由 `AudioTrackInfo.kind`
//     落下来）：电台进面板，音乐进单曲页。**不用 id 前缀猜** —— 自定义电台的 id
//     就是服务端给的 `radio_<n>`，歌曲是 `music_<md5>`，两套都不保证。
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../design/design_palette.dart';
import '../media/audio_handler.dart';
import 'audio_now_playing_route.dart';
import 'audio_radio_player_sheet.dart' show asRadioHumanDesc;

class AudioMiniPlayer extends ConsumerWidget {
  const AudioMiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.watch(audioHandlerProvider);
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      initialData: handler.playbackState.value,
      builder: (context, stateSnap) {
        final state = stateSnap.data;
        // 与 `_RadioNowPlayingBar` 同一判据：`stop()` 之后 mediaItem 不一定清空，
        // 只有 processingState 回到 idle 才代表"真的没在播"。
        if (state == null || state.processingState == AudioProcessingState.idle) {
          return const SizedBox.shrink();
        }
        return StreamBuilder<MediaItem?>(
          stream: handler.mediaItem,
          initialData: handler.mediaItem.value,
          builder: (context, itemSnap) {
            final item = itemSnap.data;
            if (item == null) return const SizedBox.shrink();
            return _Bar(item: item, playing: state.playing, handler: handler);
          },
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.item,
    required this.playing,
    required this.handler,
  });

  final MediaItem item;
  final bool playing;
  final SynologyAudioHandler handler;

  bool get _isRadio => AudioTrackKind.fromTag(item.extras?['kind']) ==
      AudioTrackKind.radio;

  /// 副标题：**只说人话**。
  ///
  /// 电台的 `artist`（= SHOUTcast 的 `desc`）经常就是 `MP3 (192 kbps)`；
  /// 清洗后没人话就不显示描述，只留"正在播放/已暂停"。
  String _subtitle() {
    final stateText = playing
        ? dataText('asRadioNowPlaying', '正在播放')
        : dataText('asRadioPaused', '已暂停');
    if (_isRadio) {
      final human = asRadioHumanDesc(item.artist ?? '');
      // ★ r653（`DA258`）：通知栏发布时已把副标题清洗成「正在播放」这类人话，
      //   这里再拼一次就会变成「正在播放 · 正在播放」—— 同句不重复。
      return human.isEmpty || human == stateText
          ? stateText
          : '$stateText · $human';
    }
    final parts = <String>[
      if ((item.artist ?? '').isNotEmpty) item.artist!,
      if ((item.album ?? '').isNotEmpty) item.album!,
    ];
    return parts.isEmpty ? stateText : parts.join(' · ');
  }

  // ★ r653（`DA257`）：走**同一个**入口 —— 通知栏点卡片也调它，
  //   免得"点迷你条"和"点通知"两处各写一套 if/else 后走偏（r652 的教训）。
  void _open(BuildContext context) {
    openNowPlaying(context, item: item).catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final p = DesignPalette.of(context);
    return Material(
      key: const Key('audio-mini-player'),
      color: p.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.line)),
        ),
        child: SizedBox(
          // 56dp：比底座矮一档，仍保证 48dp 的最小点击区
          height: 56,
          child: Row(
            children: <Widget>[
              Expanded(
                child: InkWell(
                  key: const Key('audio-mini-open'),
                  onTap: () => _open(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: p.primarySoft,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            _isRadio
                                ? Icons.radio
                                : Icons.music_note_outlined,
                            size: 20,
                            color: p.primary,
                          ),
                        ),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: p.text,
                                ),
                              ),
                              Text(
                                _subtitle(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: p.dim,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const Key('audio-mini-toggle'),
                tooltip: playing ? context.t.asPause : context.t.asPlay,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                color: p.primary,
                onPressed: () {
                  // 引擎异常不往 zone 外抛（与页面里的 `_guard` 同口径）
                  (playing ? handler.pause() : handler.play())
                      .catchError((Object _) {});
                },
              ),
              const SizedBox(width: Gap.xs),
            ],
          ),
        ),
      ),
    );
  }
}
