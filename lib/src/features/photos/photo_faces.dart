// P18：人物相册里的**人脸条目**与逐脸操作（官方 `Person/list_face` +
// `delete_face` / `separate`）。
//
// ## 字段取证（本轮补上，来源：官方 Web 前端 `react_bundle.js`）
//
// 官方人物页的"人脸对话框"是这样渲染的（逐字）：
//
// ```js
// renderFace = function(list, library, thumbnailType) {
//   list.map(function(face, index) {
//     var id = face.id;
//     var thumb = face.additional.thumbnail;
//     var hidden = face.hidden || false;
//     ... nu(id, thumb, thumbnailType, ...)   // 缩略图 URL 构造
//   })
// }
// ```
//
// ⇒ `list_face` 回的条目就是**普通照片条目**的形状：
//   * `id` —— 人脸所在条目的 id（也正因如此，`delete_face` / `separate` 传的
//     `face_id` 是"这批条目的 id 数组"）；
//   * `additional.thumbnail` —— 缩略图对象（与照片条目同形，可直接复用
//     [photoThumbRequest]）；
//   * `hidden` —— 该人脸是否已被隐藏（Web 用它画选中态遮罩）。
//
// 这就是 183–193 轮"人脸渲染字段未取证"缺的那一条 —— 现在有了。
//
// ## 保守判定
//
// * `item_id` 为空 ⇒ **不发请求**（`personFaces` 自己就会返回空，沿用官方
//   "只查当前可见条目"的语义）；
// * 破坏性操作（移出人物 / 拆分为新人物）一律**先确认**，取消 ⇒ 零请求；
// * 失败 ⇒ 明确提示 + 失效列表（不做乐观更新）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../data/dto/foto_dto.dart';
import 'photo_providers.dart';
import 'photo_widgets.dart';

/// 一条人脸 = 一个照片条目 + 它在该人物下的 `hidden` 标记。
class PhotoFaceDto {
  const PhotoFaceDto({required this.item, required this.hidden});

  final FotoItemDto item;
  final bool hidden;

  String get id => item.id;

  /// 容错解析：没有 id 的条目直接丢弃（不造空壳）。
  static PhotoFaceDto? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final item = FotoItemDto.fromJson(map);
    if (item.id.isEmpty) return null;
    return PhotoFaceDto(item: item, hidden: map['hidden'] == true);
  }
}

/// 某人物在给定条目上的人脸（`Person/list_face`）。
///
/// 参数 `itemIds` 必传：官方只查"当前可见条目里"的人脸，列表空则不发请求。
final photoPersonFacesProvider =
    FutureProvider.autoDispose.family<List<PhotoFaceDto>, PhotoFacesQuery>((
      ref,
      query,
    ) async {
      final api = ref.watch(fotoSpaceApiProvider);
      if (api == null || query.itemIds.isEmpty) return const [];
      final raw = await api.personFaces(query.personId, itemIds: query.itemIds);
      return [
        for (final r in raw)
          ?PhotoFaceDto.tryParse(r),
      ];
    });

/// 人脸查询条件（人物 + 当前可见条目）。
class PhotoFacesQuery {
  const PhotoFacesQuery({required this.personId, required this.itemIds});

  final String personId;
  final List<String> itemIds;

  @override
  bool operator ==(Object other) =>
      other is PhotoFacesQuery &&
      other.personId == personId &&
      _sameIds(other.itemIds, itemIds);

  @override
  int get hashCode => Object.hash(personId, Object.hashAll(itemIds));

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 人物相册顶部的人脸条：点一张脸 → 底部弹层（移出该人物 / 拆分为新人物）。
///
/// 复用人物列表已有的写接口（`delete_face` / `separate`，`face_id` 传
/// **JSON 数字数组**，见 193 轮纠错）。
class PhotoFaceStrip extends ConsumerWidget {
  const PhotoFaceStrip({super.key, required this.personId, required this.itemIds});

  final String personId;
  final List<String> itemIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (itemIds.isEmpty) return const SizedBox.shrink();
    final faces = ref.watch(
      photoPersonFacesProvider(
        PhotoFacesQuery(personId: personId, itemIds: itemIds),
      ),
    );
    final space = ref.watch(fotoSpaceProvider);
    return faces.when(
      loading: () => const SizedBox(
        height: 2,
        child: LinearProgressIndicator(key: Key('photo-face-strip-loading')),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          key: const Key('photo-face-strip'),
          height: 72,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) => GestureDetector(
              key: Key('photo-face-${list[i].id}'),
              onTap: () => _openActions(context, ref, list[i]),
              child: Opacity(
                opacity: list[i].hidden ? 0.4 : 1,
                child: ClipOval(
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: PhotoThumb(
                      request: photoThumbRequest(list[i].item, space),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openActions(
    BuildContext context,
    WidgetRef ref,
    PhotoFaceDto face,
  ) async {
    final t = context.t;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          key: const Key('photo-face-actions'),
          mainAxisSize: MainAxisSize.min,
          children: [
            DesignRowTile(
              key: const Key('photo-face-remove'),
              leading: const Icon(Icons.person_remove_outlined),
              title: Text(context.t.photoFaceRemove),
              onTap: () => Navigator.of(context).pop('remove'),
            ),
            DesignRowTile(
              key: const Key('photo-face-separate'),
              leading: const Icon(Icons.call_split),
              title: Text(context.t.photoFaceSeparate),
              onTap: () => Navigator.of(context).pop('separate'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('photo-face-confirm'),
        title: Text(
          action == 'remove'
              ? context.t.photoFaceRemoveTitle
              : context.t.photoFaceSeparateTitle,
        ),
        content: Text(
          action == 'remove'
              ? context.t.photoFaceRemoveBody
              : context.t.photoFaceSeparateBody,
        ),
        actions: [
          TextButton(
            key: const Key('photo-face-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-face-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.actionOk),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = t;
    try {
      if (action == 'remove') {
        await api.personDeleteFace(personId: personId, faceIds: [face.id]);
      } else {
        await api.personSeparateFace(faceIds: [face.id]);
      }
      ref.invalidate(photoPersonFacesProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            action == 'remove' ? l10n.photoFaceRemoved : l10n.photoFaceSeparated,
          ),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(describePhotoError(err, l10n))),
      );
    }
  }
}
