// P17：相似/重复**堆叠**的分组操作面板（官方 `Browse.Similar` 写接口）。
//
// ## 取证（全部来自官方 APK 2.4.0-644 smali，逐字）
//
// * `datasource/network/vo/SimilarVo.smali`：`count` / `id`（分组 id）/
//   `item_id`（这张图自己的 id）/ `top_pick`；
// * `ImageRepository.similarAddItemToStack(SimilarGroup, List, long, boolean)`、
//   `similarRemoveItemFromStack(SimilarGroup, List, boolean)`、
//   `similarSetTopPick(SimilarGroup, long, boolean)`、`similarUngroup(List, boolean)`
//   —— 分组操作都带 `SimilarGroup`，写接口的 `id` 就是它的 `groupId`。
//
// 因此面板只做四件有证据的事：**设为主推 / 移出堆叠 / 解散堆叠**（+ 只读查看），
// 不发明任何别的操作。破坏性操作一律二次确认，取消 = 零请求。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/foto_api.dart';
import '../../dsm/webapi.dart';
import '../../data/foto_c2_api.dart';
import 'photo_c2_providers.dart';
import 'photo_providers.dart';
import 'photo_widgets.dart';

/// 相似堆叠一页（**分组视图**）。
///
/// 与旧的"扁平成照片网格"不同：这里按官方 `SimilarVo.id` 聚合，一组一张卡。
/// 认不出分组 id（老服务器 / `SimilarItem/list` 回落路径）时**退化成普通网格**
/// —— 不是错误，是"没有可操作的分组"。
final photoSimilarGroupsProvider = FutureProvider.autoDispose
    .family<List<FotoSimilarGroupDto>, int>((ref, limit) async {
      final api = ref.watch(fotoC2ApiProvider);
      if (api == null) return const [];
      final hasTimeline = ref
          .watch(serviceAvailabilityProvider)
          .hasApi(StationService.photo, kFotoSimilarTimelineApi);
      if (hasTimeline) {
        try {
          final data = await api.similarTimeline({
            'offset': 0,
            'limit': limit,
          });
          final groups = parseSimilarGroups(data);
          if (groups.isNotEmpty) return groups;
        } on DsmApiException {
          // `103` 方法不存在 → 回落（官方安卓 2.4.0-644 本来就没这个 api 类）
        }
      }
      final items = await api.similarGroupItems(limit: limit);
      // 回落路径没有分组 id ⇒ 每组一张、`id` 为空 ⇒ [FotoSimilarGroupDto.isActionable]
      // 为 false，面板只读（**不编造 group id**）。
      return [
        for (final it in items)
          FotoSimilarGroupDto(
            id: '',
            count: 1,
            topPickId: it.id,
            items: [it],
          ),
      ];
    });

/// 打开某个堆叠的操作面板（底部弹层）。
Future<void> showPhotoSimilarGroupSheet(
  BuildContext context,
  FotoSimilarGroupDto group,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _SimilarGroupSheet(group: group),
);

class _SimilarGroupSheet extends ConsumerWidget {
  const _SimilarGroupSheet({required this.group});

  final FotoSimilarGroupDto group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final space = ref.watch(fotoSpaceProvider);
    final coverId = group.cover?.id;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          key: const Key('photo-similar-group-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              group.count > 1
                  ? context.t.photoSimilarGroupN(group.count)
                  : context.t.photoSimilarSingle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (!group.isActionable)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  // 老服务器走 `SimilarItem/list` 回落，响应里没有分组 id
                  context.t.photoSimilarNotActionable,
                ),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in group.items)
                      _MemberTile(
                        item: item,
                        space: space,
                        isTopPick: item.id == group.topPickId,
                        actionable: group.isActionable,
                        onTap: () => _setTopPick(context, ref, item),
                        onRemove: () => _removeItem(context, ref, item),
                      ),
                  ],
                ),
              ),
            ),
            if (group.isActionable) ...[
              const Divider(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('photo-similar-ungroup'),
                  onPressed: () => _ungroup(context, ref),
                  icon: const Icon(Icons.call_split),
                  label: Text(context.t.photoSimilarUngroup),
                ),
              ),
              if (coverId != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(context.t.photoSimilarHint),
                ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('photo-similar-sheet-close'),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(context.t.photoClose),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setTopPick(
    BuildContext context,
    WidgetRef ref,
    FotoItemDto item,
  ) async {
    if (!group.isActionable) return;
    final api = ref.read(fotoC2ApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final l10n = context.t;
    try {
      await api.similarSetTopPick(groupId: group.id, itemId: item.id);
      ref.invalidate(photoSimilarGroupsProvider);
      navigator.maybePop();
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.photoSimilarTopPickSet)),
      );
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(describePhotoError(err, l10n))),
      );
    }
  }

  Future<void> _removeItem(
    BuildContext context,
    WidgetRef ref,
    FotoItemDto item,
  ) async {
    if (!group.isActionable) return;
    final ok = await _confirm(
      context,
      context.t.photoSimilarRemoveTitle,
      context.t.photoSimilarRemoveBody,
    );
    if (ok != true || !context.mounted) return;
    final api = ref.read(fotoC2ApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final l10n = context.t;
    try {
      await api.similarRemoveItem(groupId: group.id, itemId: item.id);
      ref.invalidate(photoSimilarGroupsProvider);
      navigator.maybePop();
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.photoSimilarRemoved)),
      );
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(describePhotoError(err, l10n))),
      );
    }
  }

  Future<void> _ungroup(BuildContext context, WidgetRef ref) async {
    final ok = await _confirm(
      context,
      context.t.photoSimilarUngroupTitle,
      context.t.photoSimilarUngroupBody,
    );
    if (ok != true || !context.mounted) return;
    final api = ref.read(fotoC2ApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final l10n = context.t;
    try {
      await api.similarUngroup(groupId: group.id);
      ref.invalidate(photoSimilarGroupsProvider);
      navigator.maybePop();
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.photoSimilarUngrouped)),
      );
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(describePhotoError(err, l10n))),
      );
    }
  }

  Future<bool?> _confirm(
    BuildContext context,
    String title,
    String body,
  ) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('photo-similar-group-confirm'),
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          key: const Key('photo-similar-group-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.t.actionCancel),
        ),
        FilledButton(
          key: const Key('photo-similar-group-ok'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.t.actionOk),
        ),
      ],
    ),
  );
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.item,
    required this.space,
    required this.isTopPick,
    required this.actionable,
    required this.onTap,
    required this.onRemove,
  });

  final FotoItemDto item;
  final FotoSpace space;
  final bool isTopPick;
  final bool actionable;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      GestureDetector(
        key: Key('photo-similar-member-${item.id}'),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: isTopPick
                ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
                : null,
          ),
          child: SizedBox(
            width: 84,
            height: 84,
            child: PhotoThumb(request: photoThumbRequest(item, space)),
          ),
        ),
      ),
      if (actionable)
        Positioned(
          top: 0,
          right: 0,
          child: InkWell(
            key: Key('photo-similar-remove-${item.id}'),
            onTap: onRemove,
            child: const CircleAvatar(
              radius: 10,
              child: Icon(Icons.close, size: 12),
            ),
          ),
        ),
    ],
  );
}
