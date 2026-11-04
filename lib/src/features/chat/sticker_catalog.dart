// 贴纸目录 provider + 图片字节缓存。
//
// * 目录：登录后拉一次 `SYNO.Chat.Sticker / list` v1，会话内缓存；
//   服务端没这个 API（老 NAS）→ 返回 null，界面上贴纸入口自动隐藏。
// * 图片：`GET {base}sc/stickers/{id}/{size}`，**靠 cookie 不带 `_sid`**；
//   同一张图在内存里缓存（原版用 Glide 的磁盘缓存，我们用内存 + 列表页内
//   复用足够）。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../data/chat_api.dart';
import '../../data/dto/sticker_dto.dart';
import 'chat_session_controller.dart';

/// 贴纸目录（拿不到 / 服务端不支持 → null）
final stickerCatalogProvider = FutureProvider<StickerCatalog?>((ref) async {
  final api = ref.watch(chatApiProvider);
  if (api == null || !api.supportsStickers) return null;
  try {
    final catalog = await api.fetchStickers();
    return catalog.isEmpty ? null : catalog;
  } catch (_) {
    // 老服务端没有这个 API：静默降级，不要弹错
    return null;
  }
}, retry: noRetry);

/// 图片字节的内存缓存（key = `id|size`）
final Map<String, List<int>> stickerBytesCache = {};

@visibleForTesting
void clearStickerCache() => stickerBytesCache.clear();

/// 取贴纸图片字节（带内存缓存）
Future<List<int>> loadStickerBytes(
  ChatApi api,
  int stickerId, {
  String size = '2x',
}) async {
  final key = '$stickerId|$size';
  final hit = stickerBytesCache[key];
  if (hit != null) return hit;
  final bytes = await api.downloadSticker(stickerId, size: size);
  stickerBytesCache[key] = bytes;
  return bytes;
}
