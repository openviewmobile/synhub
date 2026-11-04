// 相册 P40：**评分**（星级）的界面层。
//
// 事实来源（逐条对照，不许猜）：
//   * 官方 APK 2.4.0-644（jadx 1.5.3）
//     `datasource/network/api/ApiBrowseItem.java`：
//     `SUPPORT_RATING_VERSION = 2`（:97）、`METHOD_SET = "set"`（:42）、
//     `KEY_RATING = "rating"`（:71）、`ADDITIONAL_RATING = "rating"`（:53）、
//     `SetParamBuilder.build()` `map.put("rating", String.valueOf(num))`（:1208）；
//   * `ConnectionManager.java:1814` `isSupportRating = Browse.Item.maxVersion >= 2`；
//   * 官方 UI 证据：`layout/dialog_set_ratings`、`id/rating_bar`、
//     `string/str_edit_rating`、`string/str_items_rated_toast`。
//
// 数据层在 `lib/src/data/foto_api.dart`（`supportsRating` / `setItemRating`）。
// 本文件只做三件事：
//   1. 星级控件（[PhotoRatingBar]）—— 只读展示 + 可交互两种形态；
//   2. 评分选择弹层（[showPhotoRatingSheet]）—— 点第 N 颗星 / 「未评分」清除；
//   3. 写入口（[setPhotoRating]）—— 统一的门控 + 反馈（成功/失败都说话）。
//
// ⚠️ 门控口径：`supportsRating == false`（老 Photos，`Browse.Item` maxVersion < 2）
// 时**入口整个不渲染**（不是置灰），绝不留一个点了报错的按钮。
//
// ⚠️ §5.1：本批次**不真调**任何变更动词方法；[setPhotoRating] 只被离线用例驱动。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/user_facing_error.dart';
import '../../data/foto_api.dart';
import '../../dsm/webapi.dart';
import 'photo_providers.dart';

/// 五颗星的评分控件。
///
/// * [onChanged] 为 null → **只读**（信息面板里的展示形态）；
/// * 有 [onChanged] → 可交互，点第 N 颗星回调 `N`；
/// * [showClear] 为 true 时（且可交互）多一颗「未评分」按钮，回调 `0`。
class PhotoRatingBar extends StatelessWidget {
  const PhotoRatingBar({
    super.key,
    required this.rating,
    this.onChanged,
    this.showClear = false,
    this.enabled = true,
  });

  /// 当前星级（`0` = 未评分）
  final int rating;
  final ValueChanged<int>? onChanged;
  final bool showClear;
  final bool enabled;

  bool get _interactive => onChanged != null && enabled;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final value = rating.clamp(0, kFotoRatingMax);
    return Row(
      key: const Key('photo-rating-bar'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var star = 1; star <= kFotoRatingMax; star++)
          IconButton(
            key: Key('photo-rating-star-$star'),
            // 只读形态下别抢焦点/别报"按钮"
            onPressed: _interactive ? () => onChanged!(star) : null,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: t.asRating,
            icon: Icon(
              star <= value ? Icons.star : Icons.star_border,
              color: star <= value ? Colors.amber : null,
            ),
          ),
        if (showClear && _interactive)
          TextButton(
            key: const Key('photo-rating-clear'),
            onPressed: () => onChanged!(0),
            child: Text(t.asRatingUnset),
          ),
        if (value == 0 && !(showClear && _interactive))
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              t.asRatingUnset,
              key: const Key('photo-rating-unrated'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// 打开评分选择弹层；返回选中的星级（`0` = 清除），取消回 null。
Future<int?> showPhotoRatingSheet(
  BuildContext context, {
  required int initial,
}) {
  return showModalBottomSheet<int>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          key: const Key('photo-rating-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ctx.t.asRating, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            PhotoRatingBar(
              rating: initial,
              showClear: true,
              onChanged: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 把星级写到服务端并刷新所有可能受影响的列表。
///
/// 返回 true = 成功。失败时**已把原因翻成人话**弹出来（不静默失败）。
///
/// 门控：[FotoApi.supportsRating] 为 false → 直接返回 false 且**不发请求**
/// （界面本就不该给入口，这里是兜底）。
Future<bool> setPhotoRating(
  BuildContext context,
  WidgetRef ref, {
  required List<String> itemIds,
  required int rating,
}) async {
  final api = ref.read(fotoSpaceApiProvider);
  final messenger = ScaffoldMessenger.of(context);
  final t = context.t;
  if (api == null || itemIds.isEmpty) return false;
  if (!api.supportsRating) {
    messenger.showSnackBar(
      SnackBar(content: Text(t.asRatingFailed(t.photoErrApiVersion))),
    );
    return false;
  }
  try {
    await api.setItemRating(itemIds, rating);
    // 服务端是唯一事实来源：改完重新拉列表
    ref.invalidate(photoTimelineProvider);
    ref.invalidate(photoFavoritesProvider);
    ref.invalidate(photoAlbumsProvider);
    ref.invalidate(photoAlbumItemsProvider);
    ref.invalidate(photoFolderItemsProvider);
    messenger.showSnackBar(
      SnackBar(content: Text(rating > 0 ? t.asRatingSet : t.asRatingUnset)),
    );
    return true;
  } catch (err) {
    messenger.showSnackBar(
      SnackBar(content: Text(t.asRatingFailed(_humanRatingError(err, t)))),
    );
    return false;
  }
}

/// 评分失败 → 人话（与 `describePhotoError` 同一口径，这里不反向依赖界面文件）。
String _humanRatingError(Object err, AppText t) {
  if (err is FotoRatingUnsupportedException) return t.photoErrApiVersion;
  if (err is DsmApiException) {
    switch (err.code) {
      case DsmErrorCode.apiNotFound:
        return t.photoErrNotInstalled;
      case DsmErrorCode.methodNotFound:
        return t.photoErrApiVersion;
      case DsmErrorCode.sessionTimeout:
      case DsmErrorCode.sidNotFound:
        return t.errLoginExpired;
      default:
        return DsmErrorCode.describe(err.code, method: err.method);
    }
  }
  return userFacingError(err);
}
