// C4：**远程播放器**页（`SYNO.AudioStation.RemotePlayer`）。
//
// 事实来源（双证）：
//   * `weblib/AudioStation/AudioStation.api`（权威接口表）：
//     `RemotePlayer` path `AudioStation/remote_player.cgi` v1..3，
//     方法 `list/getinfo/getstatus/getplaylist/updateplaylist/control/…`；
//     `RemotePlayerStatus` path `remote_player_status.cgi` v1..2（仅 `getstatus`）。
//   * 官方 APK `ApiRemoteController.java:37-56 / 186-216`：
//     `control` 的参数是 `{id, action, value?, subplayer_id?}`，
//     `action` 取值 `play`/`pause`/`stop`/`prev`/`next`/`set_volume`/…。
//
// ★ 老实说：`RemotePlayer.list` 的**根键形状未取证**（真机未验）⇒
//   数据层按 `players`/`items`/`renderers` 防御式取，取不到就空列表；
//   本页对每一项只渲染它**确实带**的字段（`name`/`title`/`id`），
//   字段缺失就如实显示占位，不臆造。
//
// ★ 与 C1/C2/C3 的边界：这里走的是 **NAS 侧发现/控制**（服务端为每个播放器
//   提供状态与指令），**不是**手机端 Cast SDK/AirPlay 集成；后三者仍未做。
//
// ★ r445：**空列表有两种成因，不许混为一谈**（`DA99`）。真 NAS 取证
//   （AudioStation 7.2.1-6006 / DSM 7.2）：`RemotePlayer.list` 在**账号没有**
//   `privilege.remote_player` 的画像下就是 `{"players": []}`（本轮同时把一台
//   自造 DLNA MediaRenderer 挂进同一 /24：SSDP 应答、设备描述/SCPD 抓取、
//   SUBSCRIBE ＋ 初始事件、`GetProtocolInfo` 全都发生过 —— 发现链路是通的，
//   列表照样空）。官方 Web 前端在这张画像下**根本不显示** DLNA 入口
//   （`setMediaServerVisible(!settings.disable_upnp && privilege.upnp_browse)`，
//   `app/audio-common.js`）；我们照抄这条语义，但**保留页面**并把原因写清楚，
//   而不是把授权/开关原因说成"NAS 上没设备"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/ui/hud_widgets.dart';
import '../../core/user_facing_error.dart';
import '../../data/dto/audio_station_dto.dart';
import 'audio_player.dart';
import 'audio_providers.dart';

/// 远程播放器**列不出来**的服务端原因（`null` = 不是这个原因 / 不知道）。
///
/// 判据全部来自服务端下发的那张画像（`SYNO.AudioStation.Info/getinfo` v2+，
/// 与官方 Web 前端逐字同源）；**画像缺失（`info == null` 或键不存在）一律返回
/// `null`** —— "不知道"不等于"没权限"（AGENTS §2.0.7 ③）。
enum RemotePlayerDenial {
  /// `settings.disable_upnp == true`：服务端那颗总开关关着，NAS 不会去发现设备。
  upnpDisabled,

  /// `privilege.remote_player == false`：本账号没有 Audio Station 的远程播放权限。
  noPrivilege,
}

RemotePlayerDenial? remotePlayerDenial(AudioInfoDto? info) {
  if (info == null) return null;
  if (info.disableUpnp == true) return RemotePlayerDenial.upnpDisabled;
  if (info.remotePlayerPrivilege == false) return RemotePlayerDenial.noPrivilege;
  return null;
}

class AudioRemotePage extends ConsumerWidget {
  const AudioRemotePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(audioRemotePlayersProvider);
    final info = ref.watch(audioInfoProvider).value;
    final denial = remotePlayerDenial(info);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(dataText('asRemoteTitle', '远程播放器')),
        actions: [
          IconButton(
            key: const Key('as-remote-refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(audioRemotePlayersProvider),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppErrorView(
          title: dataText('asRemoteLoadFailed', '远程播放器加载失败'),
          detail: userFacingError(e),
          onRetry: () => ref.invalidate(audioRemotePlayersProvider),
        ),
        data: (players) => players.isEmpty
            ? switch (denial) {
                // ★ 服务端不给的原因必须自己给（仪器138）：这两种空态**不是**
                //   "NAS 上没设备"，用户照着旧文案去开电视永远修不好。
                RemotePlayerDenial.upnpDisabled => AppEmptyState(
                  key: const Key('as-remote-upnp-disabled'),
                  icon: Icons.cast_connected_outlined,
                  title: dataText('asRemoteUpnpDisabled', '服务端已关闭 DLNA / UPnP'),
                  message: dataText(
                    'asRemoteUpnpDisabledHint',
                    'NAS 上的 Audio Station 关掉了 UPnP／DLNA（设置 → 高级 → DLNA），'
                        '所以它不会去发现播放设备 —— 与手机端无关。',
                  ),
                ),
                RemotePlayerDenial.noPrivilege => AppEmptyState(
                  key: const Key('as-remote-no-privilege'),
                  icon: Icons.lock_outline,
                  title: dataText('asRemoteNoPrivilege', '此账号没有远程播放权限'),
                  message: dataText(
                    'asRemoteNoPrivilegeHint',
                    '本账号在 Audio Station 里没有「远程播放」权限（由 DSM 管理员分配），'
                        '因此服务端不返回任何播放设备。',
                  ),
                ),
                null => AppEmptyState(
                  key: const Key('as-remote-empty'),
                  icon: Icons.cast_connected_outlined,
                  title: dataText('asRemoteEmpty', '没有发现远程播放器'),
                  message: dataText(
                    'asRemoteEmptyHint',
                    'NAS 没有发现可控制的播放设备（DLNA/UPnP 渲染器等）。',
                  ),
                ),
              }
            : ListView.separated(
                key: const Key('as-remote-list'),
                padding: const EdgeInsets.all(Gap.md),
                itemCount: players.length,
                separatorBuilder: (_, _) => const SizedBox(height: Gap.sm),
                itemBuilder: (context, i) =>
                    _RemoteTile(player: players[i], index: i),
              ),
      ),
    );
  }
}

class _RemoteTile extends ConsumerStatefulWidget {
  const _RemoteTile({required this.player, required this.index});

  final Map<String, dynamic> player;
  final int index;

  @override
  ConsumerState<_RemoteTile> createState() => _RemoteTileState();
}

class _RemoteTileState extends ConsumerState<_RemoteTile> {
  bool _busy = false;

  String get _id => '${widget.player['id'] ?? ''}';

  /// 只渲染它**确实带**的字段；都没有就退回占位文案（不臆造设备名）。
  String get _title {
    for (final k in const ['name', 'title', 'model', 'host']) {
      final v = widget.player[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return dataText('asRemoteUnnamed', '未命名播放器');
  }

  /// 官方类型 → 上屏标签（未知类型**原样显示**，不猜）。
  String? get _typeLabel {
    final t = widget.player['type'];
    if (t is! String || t.isEmpty) return null;
    return switch (t) {
      'usb' => 'USB',
      'bluetooth' => dataText('asRemoteTypeBt', '蓝牙'),
      'upnp' => 'DLNA / UPnP',
      'airplay' => 'AirPlay',
      _ => t,
    };
  }

  /// 当前曲目的 id：从本机播放器的 `currentUrl` 里取其 `id` 参数
  /// （`streamUrl` **必然**带 `id=<song.id>`，见 `audio_station.dart:1474`）。
  String? get _currentSongId {
    final url = ref.read(audioStationPlayerProvider).currentUrl;
    if (url == null || url.isEmpty) return null;
    final v = Uri.tryParse(url)?.queryParameters['id'];
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> _pushCurrent() async {
    final api = ref.read(audioApiProvider);
    if (api == null || _id.isEmpty || _busy) return;
    final player = ref.read(audioStationPlayerProvider);
    // 官方 `control_enqueue(PLAY_NOW)`：offset=0 / limit=队列长度 /
    // songs=整个 id 列表 / updated_index=-1 / keep_shuffle_order=false。
    final queueIds = [
      for (final e in player.queue)
        if (e.id.isNotEmpty && Uri.tryParse(e.url)?.queryParameters['id'] == e.id)
          e.id,
    ];
    if (queueIds.isNotEmpty) {
      setState(() => _busy = true);
      try {
        await api.updateRemotePlaylist(
          id: _id,
          songIds: queueIds,
          offset: 0,
          limit: queueIds.length,
          updatedIndex: -1,
          keepShuffleOrder: false,
        );
        // ★ DA104（r458 真机）：`updateplaylist` **只改远端队列**，不会自己开播。
        //   实测（真机 + 自造 DLNA 渲染器）：推完 NAS 只对该设备发了 `Stop`；
        //   再按该设备的 ▶ 才有 `SetAVTransportURI` + `Play`。
        //   ⇒ 推送成功后再补一条官方 `control(action=play)`，让"推过去"＝"那边开始放"。
        await api.controlRemote(id: _id, action: 'play');
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(userFacingError(e))));
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    final songId = _currentSongId;
    if (songId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(dataText('asRemoteNoCurrent', '本机当前没有正在播放的曲目')),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await api.updateRemotePlaylist(
        id: _id,
        songIds: [songId],
        offset: 0,
        limit: 1,
        updatedIndex: 0,
        keepShuffleOrder: false,
      );
      // ★ DA104：回退路径同样要补 `play`（理由见上面整队列分支）。
      await api.controlRemote(id: _id, action: 'play');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _control(String action, {String? value}) async {
    final api = ref.read(audioApiProvider);
    if (api == null || _id.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await api.controlRemote(id: _id, action: action, value: value);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // ★ 不用 `FieldBackdrop`：它内部是 Stack，放进 ListView（高度无界）会触发
    // "Stack requires bounded constraints" —— 这里用普通卡片。
    return Container(
      decoration: BoxDecoration(
        color: DesignPalette.of(context).surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DesignPalette.of(context).line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.speaker_outlined, size: 18, color: DesignPalette.of(context).dim),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    _title,
                    key: Key('as-remote-name-${widget.index}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (_typeLabel != null) ...[
              const SizedBox(height: Gap.xs),
              // C2：官方 `ApiRemotePlayerType` 枚举逐字 `usb/bluetooth/upnp/airplay`
              // （`ApiRemotePlayerResponseVo.java:21-26`）——**只是显示**；
              // 官方 Android 端同样没有 AirPlay 发送端实现。
              TelemetryLabel(
                _typeLabel!,
                key: Key('as-remote-type-${widget.index}'),
                size: 11,
                color: DesignPalette.of(context).dim,
                letterSpacing: 0.2,
              ),
            ],
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.xs,
              children: [
                // C1：把**当前曲目**推到该设备（官方 `control_enqueue(PLAY_NOW)` 形态：
                // offset=0 / limit=queueSize / songs=idList / updated_index=-1 /
                // keep_shuffle_order=false，见 `ApiRemoteController.java:288-300`）。
                // ★ 148 轮：本机队列的 song id 列表**已经拿得到**了
                // （`AudioStationPlayer.queue`）⇒ 有队列就推**整队列**，
                // 没有就退回"当前这一首"（id 只从 currentUrl 的 id 参数取，
                // 绝不臆造）。
                IconButton(
                  key: Key('as-remote-push-${widget.index}'),
                  tooltip: dataText('asRemotePushCurrent', '把当前曲目推到该设备'),
                  onPressed: _busy ? null : _pushCurrent,
                  icon: const Icon(Icons.cast),
                ),
                for (final a in const ['prev', 'play', 'pause', 'stop', 'next'])
                  IconButton(
                    key: Key('as-remote-$a-${widget.index}'),
                    tooltip: a,
                    onPressed: _busy ? null : () => _control(a),
                    icon: Icon(
                      switch (a) {
                        'prev' => Icons.skip_previous,
                        'play' => Icons.play_arrow,
                        'pause' => Icons.pause,
                        'stop' => Icons.stop,
                        _ => Icons.skip_next,
                      },
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
