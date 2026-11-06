// Audio Station 收藏页（"我的锁定"，阶段二 A：Audio Station 普通用户功能）。
//
// 接口事实来源：`docs/stage2-audio-download-api.md` §2.2 / §2.3 A-1d
// （来源 `lib`：`webapi5/SYNO.AudioStation.lib` + 官方前端
// `PinReorderGrid`/`sendPinRequest`/`sendUnpinRequest`）：
//   * `Pin.list` v1 —— `{offset:0, limit:-1}`，root `items`，total `total`；
//   * `Pin.unpin` v1 —— 官方前端 `sendUnpinRequest` 发的是 **`items`（id 数组）**，
//     不是 doc §2.3 第 42 行写的 `id`（见 `AudioStationApi.removePins` 的偏差说明）。
//
// 收藏记录是**异构**的（`type` + `criteria` + `name`，官方
// `getPinArgumentsFromRecord` 动态拼）：这里按 `type`/`criteria` 还原入口，
// 认不出的类型只提示、不猜。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../data/audio_station.dart';
import '../../data/dto/audio_station_dto.dart';
import 'audio_detail_page.dart';
import 'audio_labels.dart';
import 'audio_providers.dart';
import 'audio_search_page.dart';

class AudioPinsPage extends ConsumerWidget {
  const AudioPinsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final api = ref.watch(audioApiProvider);
    final async = ref.watch(audioPinsProvider);
    return DesignScaffold(
      // ★ r481：spec 写的是「搜索 + 更多」两个动作。这里**故意**只给两个
      //   **图标**（搜索 / 刷新），不做成 ⋮ 菜单 —— 用户的原话是
      //   "常用动作被藏进菜单"，而这一页一共就两个动作，藏起来更糟。
      //   偏差登记在 `design/README.md` §4.15。
      appBar: AppBar(
        title: Text(t.asPinsTitle),
        actions: [
          IconButton(
            key: const Key('as-pins-search'),
            tooltip: t.asSearchTitle, // 复用已有键（"Search music"）
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(builder: (_) => const AudioSearchPage()),
            ),
          ),
          IconButton(
            key: const Key('as-pins-refresh'),
            tooltip: t.photoRefresh, // 复用已有键（"Refresh"）
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(audioPinsProvider),
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
              loading: () => const AppListSkeleton(rows: 4),
              error: (e, _) => AppErrorView(
                icon: audioFailureKind(e) == AsFailureKind.network
                    ? Icons.wifi_off
                    : Icons.error_outline,
                title: t.asPinsLoadFailed,
                detail: describeAudioError(e),
                onRetry: () => ref.invalidate(audioPinsProvider),
              ),
              data: (pins) => pins.isEmpty
                  ? AppEmptyState(
                      icon: Icons.favorite_border,
                      title: t.asPinEmpty,
                      message: t.asPinEmptyHint,
                    )
                  // P1-7 接线：`Pin.reorder` v1 —— 拖动排序此前只有数据层/测试，
                  // 现在用 `ReorderableListView` 真正下发（长按拖动）。
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.only(bottom: Gap.xxl),
                      itemCount: pins.length,
                      // 用**显式拖动手柄**（`_PinTile` 里的 drag_handle）：
                      // 移动端长按拖动发现性差，且与列表行点击/取消收藏按钮
                      // 抢手势；显式手柄互不干扰。
                      buildDefaultDragHandles: false,
                      onReorderItem: (oldIndex, newIndex) =>
                          _reorder(context, ref, pins, oldIndex, newIndex),
                      itemBuilder: (context, i) => _PinTile(
                        key: Key('as-pin-${pins[i].id}'),
                        pin: pins[i],
                        index: i,
                      ),
                    ),
            ),
    );
  }

  /// 拖动结束后：本地先算出新次序，乐观下发 `Pin.reorder`，再让列表重取。
  ///
  /// 用 `onReorderItem`（Flutter 3.41+）：它给的 [newIndex] 已经是"移除
  /// 旧项之后"的落点，**不再自己减一**（旧 `onReorder` 才需要）。
  Future<void> _reorder(
    BuildContext context,
    WidgetRef ref,
    List<AudioPinDto> pins,
    int oldIndex,
    int newIndex,
  ) async {
    final next = [...pins];
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    try {
      await ref.read(audioActionsProvider).reorderPins(next);
      ref.invalidate(audioPinsProvider);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.asPinReorderFailedDetail(describeAudioError(e)),
          ),
        ),
      );
      ref.invalidate(audioPinsProvider);
    }
  }
}

class _PinTile extends ConsumerWidget {
  const _PinTile({super.key, required this.pin, required this.index});

  final AudioPinDto pin;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final title = pin.name.isNotEmpty ? pin.name : pin.id;
    return DesignRowTile(
      leading: Icon(_iconFor(pin.type)),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(asPinTypeLabel(t, pin.type)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 显式拖动手柄（`buildDefaultDragHandles: false`）。
          ReorderableDragStartListener(
            key: Key('as-pin-drag-${pin.id}'),
            index: index,
            child: Icon(
              Icons.drag_handle,
              size: 18,
              color: DesignPalette.of(context).dim,
            ),
          ),
          // P1-7 接线：`Pin.rename` v1 —— 改名此前只有数据层/测试。
          IconButton(
            key: Key('as-pin-rename-${pin.id}'),
            tooltip: dataText('asPinRename', '重命名'),
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () => _rename(context, ref, title),
          ),
          IconButton(
            key: Key('as-unpin-${pin.id}'),
            tooltip: t.asPinRemove,
            icon: const Icon(Icons.favorite, size: 18),
            onPressed: () => _remove(context, ref),
          ),
        ],
      ),
      onTap: () => _open(context, title),
    );
  }

  static IconData _iconFor(String type) => switch (type) {
    'folder' => Icons.folder_outlined,
    'album' => Icons.album_outlined,
    'artist' => Icons.person_outline,
    'composer' => Icons.piano_outlined,
    'genre' => Icons.category_outlined,
    'playlist' => Icons.queue_music_outlined,
    'random_100' => Icons.shuffle,
    'recently_added' => Icons.new_releases_outlined,
    _ => Icons.favorite_border,
  };

  String _crit(String key) {
    final v = pin.criteria[key];
    return v == null ? '' : '$v';
  }

  void _open(BuildContext context, String title) {
    final t = context.t;
    Widget? page;
    switch (pin.type) {
      case 'album':
        final name = _crit('album');
        if (name.isNotEmpty) {
          page = AudioDetailPage.album(
            name: name,
            albumArtist: _crit('album_artist'),
          );
        }
      case 'artist':
        final name = _crit('artist');
        if (name.isNotEmpty) page = AudioDetailPage.artist(name: name);
      case 'composer':
        final name = _crit('composer');
        if (name.isNotEmpty) page = AudioDetailPage.composer(name: name);
      case 'genre':
        final name = _crit('genre');
        if (name.isNotEmpty) page = AudioDetailPage.genre(name: name);
      case 'folder':
        final id = _crit('folder');
        if (id.isNotEmpty) {
          page = AudioDetailPage.folder(id: id, name: title);
        }
      case 'playlist':
        final id = _crit('playlist');
        if (id.isNotEmpty) {
          page = AudioDetailPage.playlist(id: id, name: title);
        }
      default:
        page = null;
    }
    if (page == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.asPinUnsupported)));
      return;
    }
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute<void>(builder: (_) => page!));
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(audioActionsProvider).removePin(pin.id);
      ref.invalidate(audioPinsProvider);
      messenger.showSnackBar(SnackBar(content: Text(t.asPinRemoved)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.asPinRemoveFailed(describeAudioError(e)))),
      );
    }
  }

  /// `Pin.rename` v1 —— 弹一个输入框改名，确认后下发；空名不发。
  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final t = context.t;
    final controller = TextEditingController(text: current);
    // 先抓 messenger（`showDialog` 之后再取会撞 use_build_context_synchronously）。
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(dataText('asPinRenameTitle', '重命名收藏')),
        content: TextField(
          key: const Key('as-pin-rename-field'),
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: dataText('asPinName', '名称')),
        ),
        actions: [
          TextButton(
            key: const Key('as-pin-rename-cancel'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.actionCancel),
          ),
          TextButton(
            key: const Key('as-pin-rename-confirm'),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(dataText('asPinRenameConfirm', '保存')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == current) return;
    try {
      await ref.read(audioActionsProvider).renamePin(pin.id, name);
      ref.invalidate(audioPinsProvider);
      messenger.showSnackBar(
        SnackBar(content: Text(dataText('asPinRenamed', '已重命名收藏'))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.asPinRenameFailedDetail(describeAudioError(e)),
          ),
        ),
      );
    }
  }
}
