// 我这个账号的权限表（`SYNO.Chat.Misc / acl` v1）。
//
// 原版 `AccountManager.fetchAcl` 把 `{acl_name: allow}` 存到**自己**的用户行上，
// 之后 `User.hasPrivilege(name)` 用它判断能不能邀请/踢人/建频道……
// ⚠️ 关键语义：**表里没有的 key 一律允许**（`hasPrivilege` 查不到就 return true），
// 所以这里也必须 fail-open，否则老服务器不带 ACL 就会把功能全锁死。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings.dart';

const String kMyAclKey = 'my_acl_json';

/// ACL 名字（对齐原版 `User.ACL_*`，值就是字符串本身）
const String kAclChannelInvite = 'channel_invite';
const String kAclChannelKick = 'channel_kick';
const String kAclChannelArchive = 'channel_archive';
const String kAclChannelClose = 'channel_close';
const String kAclChannelDisjoin = 'channel_disjoin';
const String kAclChannelSet = 'channel_set';
const String kAclGuestManage = 'guest_manage';

/// 建频道（原版 `User.ACL_CHANNEL_CREATE` → `NamedChannelFragment.java:155`
/// 无权限就把工具栏的 `menu_available_channel`（含 `create`）整个清空）。
const String kAclChannelCreate = 'channel_create';

/// 加入频道 / 看到公开频道（原版 `User.ACL_CHANNEL_JOIN` +
/// `User.ACL_CHANNEL_PUBLIC` → `NamedChannelFragment.java:165`
/// `showPublic(join && public)`，两个都满足才列可加入的公开频道）。
const String kAclChannelJoin = 'channel_join';
const String kAclChannelPublic = 'channel_public';

/// 建加密频道（原版 `User.ACL_CHANNEL_ENCRYPTION` → `NamedCreateFragment.java:300`
/// 无权限时 `mPrivateSwitch.setVisibility(8)`，开关**整块隐藏**）。
const String kAclChannelEncryption = 'channel_encryption';

/// 一对一（匿名）会话（原版 `User.ACL_CHANNEL_ANONYMOUS` → `DrawerPresenter.java:67`
/// 无权限不挂 `DrawerField(108)`；`ShareChannelPresenter.java:143`、
/// `ForwardConversationsFragment.java:121` 同理）。
const String kAclChannelAnonymous = 'channel_anonymous';

/// 一组 ACL 都允许才成立（`hasPrivilege` 查不到即允许，fail-open）。
bool hasEveryPrivilege(bool Function(String) hasPrivilege, List<String> names) =>
    names.every(hasPrivilege);

/// 常见的组合门控：公开频道列表要 `channel_join` **且** `channel_public`。
bool allowsPublicChannels(bool Function(String) hasPrivilege) =>
    hasEveryPrivilege(hasPrivilege, const [
      kAclChannelJoin,
      kAclChannelPublic,
    ]);

final myAclProvider = NotifierProvider<MyAclNotifier, Map<String, bool>>(
  MyAclNotifier.new,
);

class MyAclNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  /// 启动时读本地缓存（离线也能按上次的权限渲染界面）
  Future<void> preload() async {
    final raw = await ref.read(settingsServiceProvider).myAclJson();
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw);
      if (map is Map && ref.mounted) {
        state = {for (final e in map.entries) '${e.key}': e.value == true};
      }
    } catch (e) {
      debugPrint('[acl] 缓存解析失败：$e');
    }
  }

  /// 服务端拉回来的权限表（覆盖本地；空表不覆盖，避免清掉已知权限）
  Future<void> apply(Map<String, bool> acls) async {
    if (acls.isEmpty) return;
    state = Map<String, bool>.from(acls);
    await ref.read(settingsServiceProvider).setMyAclJson(jsonEncode(acls));
  }

  /// `User.hasPrivilege` —— 查不到就允许
  bool hasPrivilege(String name) => state[name] ?? true;
}

extension MyAclQuery on WidgetRef {
  bool hasPrivilege(String name) => read(myAclProvider)[name] ?? true;
}

extension MyAclQueryRef on Ref {
  bool hasPrivilege(String name) => read(myAclProvider)[name] ?? true;
}
