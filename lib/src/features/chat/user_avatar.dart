// 用户头像取图与展示 —— `SYNO.Chat.User.Avatar / get`（v1）。
//
// 官方事实来源（两处交叉验证，别凭记忆）：
//
//  1) Chat 服务端包 `Chat-x86_64-2.4.7-22203`（`synology-spk` 解包）：
//     `SYNO.Chat.User.Avatar maxVersion=1`，方法表 **v1 只有 `get`**。
//  2) APK 反编译（`/tmp/syno_apk/jadx_out/sources/com/synology/dschat`）：
//     * `data/remote/StreamService.java:24`
//       `getAvatar(path, api, method, version, user_id, type, v)` ——
//       `@FormUrlEncoded @POST("webapi/{path}")`，业务字段 `user_id` / `type` / `v`；
//     * `data/AccountManager.java:1515` `fetchAvatar(userId, type, version)`
//       → `type` 取 `ChatUserAvatar.S/M/L`，`v` = `UserVo.avatar_version`；
//     * `loader/AvatarLoader.java`（Kotlin 编译产物）缓存键是
//       `ObjectKey("${userId}:${appId}:${avatarVersion}:${type}")` ——
//       **换头像 → avatar_version 变 → 缓存键变 → 强制回源**；并且
//       `avatar_version <= 0` 时直接 `onDataReady(null)` 回退；
//     * `ui/adapter/CommonViewBinder.java:329` 无图时用
//       `user.avatar_color()` 画圆 + 首字母（本人固定 `#3D82D1`）。
//
// 本文件用【内存字节 + 缓存键】而不是 `Image.network`：官方是 POST 表单
// （参数在 body），`Image.network` 只能 GET；走 API 层还能带上 `_sid`/CSRF，
// 自签证书与打洞（QuickConnect）两条传输都稳。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/hud_widgets.dart';
import '../../data/dto/user_dto.dart';
import 'chat_session_controller.dart';

/// 一次头像请求的身份 + 失效版本。
///
/// [version] 是 `UserVo.avatar_version`：换头像/移除头像后服务端会改它，
/// 所以它同时是 **请求参数 `v`** 和 **本地缓存键**（对齐原版 Glide ObjectKey）。
@immutable
class UserAvatarKey {
  const UserAvatarKey({
    required this.userId,
    required this.version,
    this.appId = 0,
    this.type = 'S',
  });

  final int userId;
  final int appId;
  final int version;

  /// `S` / `M` / `L`（`ChatUserAvatar.S/M/L`）
  final String type;

  /// 原版 `AvatarLoader.buildLoadData` 的 `ObjectKey` 字符串
  String get cacheKey => '$userId:$appId:$version:$type';

  @override
  bool operator ==(Object other) =>
      other is UserAvatarKey &&
      other.userId == userId &&
      other.appId == appId &&
      other.version == version &&
      other.type == type;

  @override
  int get hashCode => Object.hash(userId, appId, version, type);

  @override
  String toString() => 'UserAvatarKey($cacheKey)';
}

/// 按尺寸选官方尺寸串（`ChatUserAvatar.S/M/L`）：
/// 消息里 32px 用 `S`、列表/「我的」44-56 用 `M`、资料页大图 72+ 用 `L`。
String userAvatarTypeForSize(double size) {
  if (size >= 72) return 'L';
  if (size >= 44) return 'M';
  return 'S';
}

/// 字节是否是常见图片容器。
///
/// 头像接口失败时服务端可能回 HTML/JSON（HTTP 200），直接 `MemoryImage`
/// 会得到一个解码报错而不是回退首字母；先用magic bytes 挡掉。
bool looksLikeImage(List<int> bytes) {
  bool at(int i, List<int> sig) {
    if (bytes.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (bytes[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4E, 0x47])) return true; // PNG
  if (at(0, const [0xFF, 0xD8, 0xFF])) return true; // JPEG
  if (at(0, const [0x47, 0x49, 0x46, 0x38])) return true; // GIF
  if (at(0, const [0x42, 0x4D])) return true; // BMP
  if (at(0, const [0x00, 0x00, 0x01, 0x00])) return true; // ICO
  // WebP: RIFF....WEBP
  if (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
      at(8, const [0x57, 0x45, 0x42, 0x50])) {
    return true;
  }
  return false;
}

/// 已取到的头像字节，键是 [UserAvatarKey.cacheKey]。
///
/// 用模块级缓存而不是只靠 Riverpod：同一张头像会在消息列表里出现几十次，
/// 缓存键里带 `avatar_version`，换头像后键变、自然回源，旧键可被
/// [evictUserAvatars] 主动清掉（对齐原版 Glide 的 `signature` 语义）。
final Map<String, Uint8List> _avatarBytes = <String, Uint8List>{};

/// 缓存上限（LRU 太复杂；按插入顺序 FIFO 淘汰，够用）
const int _avatarCacheLimit = 128;

void _rememberAvatar(String key, Uint8List bytes) {
  _avatarBytes[key] = bytes;
  while (_avatarBytes.length > _avatarCacheLimit) {
    _avatarBytes.remove(_avatarBytes.keys.first);
  }
}

/// 主动失效：清掉某个用户**所有**版本的头像缓存（换头像/移除头像成功后调用）。
/// 返回清掉的键，便于测试与日志。
List<String> evictUserAvatars(int userId) {
  final prefix = '$userId:';
  final hit = _avatarBytes.keys.where((k) => k.startsWith(prefix)).toList();
  for (final k in hit) {
    _avatarBytes.remove(k);
  }
  return hit;
}

/// 清空所有头像缓存（登出/切换服务器时用）。
void clearUserAvatarCache() => _avatarBytes.clear();

/// 当前缓存里的键（只读，测试/诊断用）。
List<String> debugUserAvatarCacheKeys() => _avatarBytes.keys.toList();

/// 头像图片。[version] <= 0 或 API 不可用时返回 null（调用方回退）。
final userAvatarImageProvider =
    FutureProvider.family<ImageProvider?, UserAvatarKey>((ref, key) async {
      if (key.userId <= 0 || key.version <= 0) return null;
      final cached = _avatarBytes[key.cacheKey];
      if (cached != null) return MemoryImage(cached);
      final api = ref.watch(chatApiProvider);
      if (api == null) return null;
      try {
        final bytes = await api.fetchUserAvatar(
          userId: key.userId,
          version: key.version,
          type: key.type,
        );
        if (!looksLikeImage(bytes)) return null;
        final data = Uint8List.fromList(bytes);
        _rememberAvatar(key.cacheKey, data);
        return MemoryImage(data);
      } catch (_) {
        // 取不到就退回首字母，不要在消息列表里抛红
        return null;
      }
    });

/// 统一的用户头像控件：有 `avatar_version` 就取真图，否则 `avatar_color`+首字母。
///
/// 与 [RingAvatar] 的关系：只负责"取哪张图 / 什么时候回退"，
/// 圆环、徽标、语义标签都照旧交给 [RingAvatar]。
class UserAvatar extends ConsumerWidget {
  const UserAvatar({
    super.key,
    required this.user,
    this.size = 44,
    this.background,
    this.ring,
    this.badge,
    this.semanticLabel,
    this.onTap,
    this.showBotIcon = false,
    this.fallbackLabel,
  });

  /// 为 null（用户表还没加载）时退回首字母占位
  final UserDto? user;
  final double size;
  final Color? background;
  final Color? ring;
  final Widget? badge;
  final String? semanticLabel;
  final VoidCallback? onTap;

  /// [user] 为 null 时显示的首字母/短文本（例如「我的」页登录账号名）
  final String? fallbackLabel;

  /// 机器人是否用机器人图标兜底（聊天页的机器人群像是这样）
  final bool showBotIcon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = user;
    final ThemeData theme = Theme.of(context);
    final bg = background ?? userAvatarColor(u, theme);
    final name = u?.displayName ?? '';
    final initial = name.isEmpty
        ? (fallbackLabel == null || fallbackLabel!.isEmpty
              ? '?'
              : fallbackLabel!.characters.first.toUpperCase())
        : name.characters.first.toUpperCase();
    final icon = (showBotIcon && (u?.isBot ?? false))
        ? Icons.smart_toy_outlined
        : null;

    ImageProvider? image;
    if (u != null && u.avatarVersion > 0) {
      final key = UserAvatarKey(
        userId: u.userId,
        appId: u.appId,
        version: u.avatarVersion,
        type: userAvatarTypeForSize(size),
      );
      image = ref.watch(userAvatarImageProvider(key)).value;
    }

    return RingAvatar(
      size: size,
      image: image,
      icon: image == null ? icon : null,
      label: image == null && icon == null ? initial : null,
      background: bg,
      ring: ring,
      badge: badge,
      semanticLabel: semanticLabel,
      onTap: onTap,
    );
  }
}

/// `user_props.avatar_color`（`#RRGGBB`）→ Color；缺省/非法时用主题主色。
Color userAvatarColor(UserDto? user, ThemeData theme) {
  final hex = user?.avatarColor ?? '';
  if (hex.startsWith('#') && hex.length == 7) {
    final v = int.tryParse(hex.substring(1), radix: 16);
    if (v != null) return Color(0xFF000000 | v);
  }
  return theme.colorScheme.primary;
}
