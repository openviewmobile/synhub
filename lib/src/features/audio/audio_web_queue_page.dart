// Audio Station **服务端播放队列**面板（wave2）。
//
// 事实来源：`docs/audio-api-live.md` §6（2026-09-22 真机取证）+
// `webapi/AudioStation.api`（`WebPlayer` v1 → `getplaylist`/`updateplaylist`）：
//   * `SYNO.AudioStation.WebPlayer / getplaylist` **v1，无参**；
//   * path `AudioStation/web_player.cgi`（来自 `SYNO.API.Info`）；
//   * 真机逐字：
//     `{"current":0,"mode":"normal","shuffle":0,"songs":[],"timestamp":1789993283,"total":0}`。
//
// ★ 这是**服务端**队列（官方 Web Player 的队列），与本机 `media_playback_store`
//   的"本地播放队列"（`audio_song_page.dart` 的 `as-queue-entry`）是两码事，
//   入口/文案都分开，互不冒充。
//
// 门控（与其余音频入口同一套语义）：
//   * 未连接 → "未连接"；套件未安装 → 未安装空态；
//   * 能力表缺 `SYNO.AudioStation.WebPlayer` → "不支持"空态，且**不发**注定 102 的请求；
//   * 网络/权限/其它 → 失败态 + 重试（**不把失败渲染成空**）。
//
// ★ r405 新取证（来源：AudioStation-7.2.1-6006 的**官方前端 JS**
//   `app/audio-common.js:onPlayingQueueCommit` + `app/audio-utils.js:getSongIdList`，
//   并由 NAS 侧 `getplaylist` 回读逐字确认）：
//   * `songs` 记录形状 = `{id, path, title, type}`（`type` 真机见 `file`）；
//   * `updateplaylist` 的 `songs` 是**逗号连接的 id 串**（**不是**记录数组 ——
//     传记录数组会"成功 + 静默不生效"，仪器73）；
//   * `offset`/`limit` 是**队列段替换**（`songs` 为空 = 删掉这一段）。
//   仍未取证（不猜）：`mode` 除 `normal` 外的取值 → 认不出回原值，不编。
//   写侧边界：本页**不提供**排序/清空/移除入口 —— 这条队列属于**官方 Web Player**；
//   本 App 自己的"推队列"走 `RemotePlayer.updateplaylist`（data 层 `updatePlaylistSongs`）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/audio_station.dart';
import '../../data/dto/audio_station_dto.dart';
import 'audio_labels.dart';
import 'audio_page.dart';
import 'audio_providers.dart';
import 'audio_song_page.dart';

class AudioWebQueuePage extends ConsumerWidget {
  const AudioWebQueuePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final api = ref.watch(audioApiProvider);
    final async = ref.watch(audioWebPlayerQueueProvider);
    final Widget body;
    if (api == null) {
      body = AppEmptyState(icon: Icons.cloud_off, title: t.setNotConnected);
    } else if (!api.installed) {
      body = AppEmptyState(
        key: const Key('as-not-installed'),
        icon: Icons.extension_off_outlined,
        title: t.asErrNotInstalled,
        message: t.asNotInstalledHint,
      );
    } else if (!api.hasApi(AudioStationApi.apiWebPlayer)) {
      body = AppEmptyState(
        key: const Key('as-webqueue-unsupported'),
        icon: Icons.extension_off_outlined,
        title: asWebQueueUnsupported,
      );
    } else {
      body = async.when(
        loading: () => const AppListSkeleton(rows: 4),
        error: (e, _) => AppErrorView(
          icon: audioFailureKind(e) == AsFailureKind.network
              ? Icons.wifi_off
              : Icons.error_outline,
          title: asWebQueueLoadFailed,
          detail: describeAudioError(e),
          onRetry: () => ref.invalidate(audioWebPlayerQueueProvider),
        ),
        data: (q) => q == null
            ? AppEmptyState(
                key: const Key('as-webqueue-unsupported'),
                icon: Icons.extension_off_outlined,
                title: asWebQueueUnsupported,
              )
            : _QueueBody(
                queue: q,
                onRefresh: () async {
                  ref.invalidate(audioWebPlayerQueueProvider);
                  try {
                    await ref.read(audioWebPlayerQueueProvider.future);
                  } catch (_) {
                    // 失败态由 provider 的 error 分支渲染，这里只负责收起指示器。
                  }
                },
              ),
      );
    }
    return DesignScaffold(
      appBar: AppBar(title: Text(asWebQueueTitle)),
      body: body,
    );
  }
}

class _QueueBody extends StatelessWidget {
  const _QueueBody({required this.queue, required this.onRefresh});

  final AudioWebPlayerQueueDto queue;

  /// 下拉刷新（★ r405）：本页数据源是**外部**会改的服务端队列，
  /// 停在页面上时也要有一条用户可控的重取路径（与其余音频列表页同形）。
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _QueueMeta(queue: queue),
        Expanded(
          child: RefreshIndicator(
            onRefresh: onRefresh,
            child: queue.isEmpty
                // 空态也要能下拉：ListView + AlwaysScrollable 保证可滚动。
                ? LayoutBuilder(
                    builder: (context, box) => ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: box.maxHeight,
                          child: AppEmptyState(
                            key: const Key('as-webqueue-empty'),
                            icon: Icons.queue_music_outlined,
                            title: asWebQueueEmpty,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: Gap.xxl),
                    itemCount: queue.songs.length,
                    itemBuilder: (context, i) {
                      final song = queue.songs[i];
                      final isCurrent = i == queue.current;
                      final trailing = isCurrent
                          ? Icon(
                              Icons.graphic_eq,
                              size: 18,
                              color: DesignPalette.of(context).dim,
                            )
                          : null;
                      // 记录形状已取证（`{id,path,title,type}`），但仍要防"没有 id"
                      // 的行：没有 id 就没有可打开的详情 → 用**不可点**的行，不给死入口。
                      if (song.id.isEmpty) {
                        return DesignRowTile(
                          key: Key('as-webqueue-song-$i'),
                          leading: const Icon(Icons.music_note_outlined),
                          title: Text(
                            asQueueDisplayTitle(song.title, song.path),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: trailing,
                        );
                      }
                      return AudioSongTile(
                        key: Key('as-webqueue-song-${song.id}'),
                        song: song,
                        trailing: trailing,
                        titleOverride: asQueueDisplayTitle(
                          song.title,
                          song.path,
                        ),
                        onTap: () =>
                            Navigator.of(context, rootNavigator: true).push(
                              MaterialPageRoute<void>(
                                builder: (_) => AudioSongDetailPage(
                                  songId: song.id,
                                  title: asQueueDisplayTitle(
                                    song.title,
                                    song.path,
                                  ),
                                ),
                              ),
                            ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// 队列元信息：播放模式 + 随机开关（**如实展示**，模式认不出回原值）。
class _QueueMeta extends StatelessWidget {
  const _QueueMeta({required this.queue});

  final AudioWebPlayerQueueDto queue;

  @override
  Widget build(BuildContext context) {
    final mode = asWebQueueModeText(queue.mode);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
      child: Wrap(
        spacing: Gap.md,
        runSpacing: Gap.xs,
        children: [
          if (mode.isNotEmpty)
            TelemetryLabel(
              mode,
              key: const Key('as-webqueue-mode'),
              size: 11,
              color: DesignPalette.of(context).dim,
              letterSpacing: 0.2,
            ),
          TelemetryLabel(
            queue.isShuffled ? asWebQueueShuffleOn : asWebQueueShuffleOff,
            key: const Key('as-webqueue-shuffle'),
            size: 11,
            color: DesignPalette.of(context).dim,
            letterSpacing: 0.2,
          ),
        ],
      ),
    );
  }
}
