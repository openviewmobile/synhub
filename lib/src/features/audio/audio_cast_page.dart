// C3：Chromecast 投送页（Dart 侧 UI；原生桥见
// `android/.../CastBridge.kt`，通道 `synhub/cast`）。
//
// ★ 原则（与 B10 一致）：**能力拿不到就如实说"本机不支持"，并零调用**；
//   未连接设备时"投送当前曲目"按钮禁用；投送的是**本机当前曲目的 Stream 直链**
//   （id 从 URL 的 `id` 参数取，与 C1 同一套"不臆造"的做法）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/ui/app_states.dart';
import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import 'audio_cast.dart';
import 'audio_player.dart';

class AudioCastPage extends ConsumerStatefulWidget {
  const AudioCastPage({super.key});

  @override
  ConsumerState<AudioCastPage> createState() => _AudioCastPageState();
}

class _AudioCastPageState extends ConsumerState<AudioCastPage> {
  var _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(audioCastProvider.notifier).preload();
    });
  }

  String? get _currentUrl => ref.read(audioStationPlayerProvider).currentUrl;

  Future<void> _connect(String id) async {
    setState(() => _busy = true);
    final ok = await ref.read(audioCastProvider.notifier).connect(id);
    if (mounted) {
      setState(() => _busy = false);
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(dataText('asCastConnectFailed', '连接失败'))),
        );
      }
    }
  }

  Future<void> _castCurrent() async {
    final url = _currentUrl;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(dataText('asRemoteNoCurrent', '本机当前没有正在播放的曲目')),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    final ok = await ref.read(audioCastProvider.notifier).play(url);
    if (mounted) {
      setState(() => _busy = false);
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(dataText('asCastPlayFailed', '投送失败'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cast = ref.watch(audioCastProvider);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(dataText('asCastTitle', '投送到 Chromecast')),
        actions: [
          IconButton(
            key: const Key('as-cast-refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(audioCastProvider.notifier).preload(),
          ),
        ],
      ),
      body: !cast.loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                // ★ r480（DA115）：这一页原来是 `AppEmptyState` + 裸 `ListTile`
                //   + `FilledButton`，跟设置页/单曲页不是一套语言。改成设计组件：
                //   说明卡（DesignNote）+ 行卡（DesignRowTile）+ 主按钮。
                //   键位一个没动（`as-cast-*` 全保留）。
                if (!cast.available) ...[
                  Padding(
                    key: const Key('as-cast-unsupported'),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: AppEmptyState(
                      icon: Icons.cast_connected_outlined,
                      title: dataText('asCastUnsupported', '本机不支持 Chromecast'),
                      message: dataText(
                        'asCastUnsupportedHint',
                        '需要设备具备 Google Play 服务与 Cast 能力。',
                      ),
                    ),
                  ),
                  // spec `audio_cast.json` 的第二句：给出**可用的替代路**
                  // （DLNA）。不给按钮：真 DLNA 投送在「远程播放器」页，
                  // 这里再放一个按钮就是同一动作两个入口。
                  DesignNote(
                    dataText(
                      'asCastDlnaHint',
                      '可以改用同网段的 DLNA 投送（见「远程播放器」）。',
                    ),
                    icon: Icons.info_outline,
                  ),
                ] else ...[
                  DesignSectionHeader(dataText('asCastGroupDevices', '可投送设备')),
                  for (var i = 0; i < cast.devices.length; i++)
                    DesignRowTile(
                      key: Key('as-cast-device-$i'),
                      leading: const Icon(Icons.cast, size: 20),
                      title: Text(cast.devices[i].name),
                      selected: cast.connectedId == cast.devices[i].id,
                      trailing: cast.connectedId == cast.devices[i].id
                          ? Icon(
                              Icons.check,
                              color: DesignPalette.of(context).primary,
                            )
                          : TextButton(
                              key: Key('as-cast-connect-$i'),
                              onPressed: _busy
                                  ? null
                                  : () => _connect(cast.devices[i].id),
                              child: Text(dataText('asCastConnect', '连接')),
                            ),
                    ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('as-cast-current'),
                        onPressed: (_busy || cast.connectedId == null)
                            ? null
                            : _castCurrent,
                        icon: const Icon(Icons.cast),
                        label: Text(dataText('asCastCurrent', '投送当前曲目')),
                      ),
                    ),
                  ),
                  if (cast.connectedId != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          key: const Key('as-cast-disconnect'),
                          onPressed: _busy
                              ? null
                              : () => ref
                                    .read(audioCastProvider.notifier)
                                    .disconnect(),
                          child: Text(dataText('asCastDisconnect', '断开连接')),
                        ),
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}
