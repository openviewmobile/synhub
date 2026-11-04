// 新建频道（对齐原版 `ChannelCreateFragment` + `AccountManager.createNamed`）。
//
// 两种频道：
//   * **普通命名频道**：`Channel.Named create` → `invite` 成员；
//   * **加密命名频道**：多两步，且**次序不能乱**（`tool/probe_make_e2ee_channel.dart` 实测）：
//       1. 本地生成 32 字节频道密钥（`E2eeService.newChannelKey`）；
//       2. `create(encrypted=true)` → 只回 channel_id；
//       3. `join` **必须带自己的 `channel_key_enc`** —— 不带就是
//          `CHAT_ERR_CHANNEL_KEY_NOT_EXIST (421)`；
//       4. `invite` 带 `user_ids` + `channel_key_encs`（每个成员各封一份）。
//
// 密钥全程只在本地：服务端只见到「用各自公钥 seal 过的副本」。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/user_dto.dart';
import 'chat_session_controller.dart';

/// 新建频道的结果
class CreatedChannel {
  const CreatedChannel({required this.channelId, required this.encrypted});

  final int channelId;
  final bool encrypted;
}

/// 新建频道的业务动作（不碰 UI，离线可测）
final channelCreateControllerProvider = Provider<ChannelCreateController>(
  (ref) => ChannelCreateController(ref),
);

class ChannelCreateController {
  ChannelCreateController(this.ref);

  final Ref ref;

  /// 可邀请的人（human，且不是我自己、不是已删除用户）
  Future<List<UserDto>> invitableUsers() async {
    final me = ref.read(chatSessionControllerProvider).myUserId;
    final users = await ref.read(chatStoreProvider).allUsers();
    return users
        .where((u) => u.userId != me && !u.isDeleted && u.type == 'human')
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
  }

  /// 选中的成员里，哪些**还没配端到端加密口令**（没有 `key_pair` 公钥）。
  ///
  /// 原版 `CreateChannelPresenter.showNoPublicKeyUsers`：加密频道在邀请/创建前
  /// 先筛一遍，然后弹 `dialog_no_passphrase` 让用户决定「移出并继续」以及
  /// 「是否通知他们」（`NamedCreateFragment.showNoPublicKeyUsers`）。
  Future<List<UserDto>> usersWithoutPublicKey(List<int> userIds) async {
    if (userIds.isEmpty) return const [];
    final users = await ref.read(chatStoreProvider).allUsers();
    final byId = {for (final u in users) u.userId: u};
    return [
      for (final id in userIds)
        if ((byId[id]?.publicKey ?? '').isEmpty && byId[id] != null) byId[id]!,
    ];
  }

  /// 建频道（含加密频道的密钥分发）。
  ///
  /// [memberIds] 是要邀请的 userId；[encrypted] 为真时按上面 4 步走。
  Future<CreatedChannel> create({
    required String name,
    String purpose = '',
    String type = 'private',
    bool encrypted = false,
    List<int> memberIds = const [],
  }) async {
    final t = currentText();
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError(t.chatCreateNameRequired);
    }
    final api = ref.read(chatApiProvider);
    if (api == null) {
      throw StateError(t.profileEditNotConnected);
    }

    if (!encrypted) {
      final id = await api.createNamedChannel(
        name: trimmed,
        purpose: purpose,
        type: type,
        encrypted: false,
      );
      // ⚠️ 普通频道也要先 **join** 才能 invite —— 真机实测：create 出来的频道
      // 创建者并不自动是成员，直接 invite 会 `CHAT_ERR_NOT_IN_CHANNEL (401)`。
      if (id > 0) {
        await api.joinNamedChannel(id);
        if (memberIds.isNotEmpty) {
          await api.inviteNamedChannel(id, userIds: memberIds);
        }
      }
      await _refresh();
      return CreatedChannel(channelId: id, encrypted: false);
    }

    // ---- 加密频道 ----
    final e2ee = ref.read(e2eeServiceProvider);
    final mine = e2ee.identity?.publicKey ?? '';
    if (mine.isEmpty) {
      throw StateError(t.chatCreateNoE2eeIdentity);
    }
    final users = await ref.read(chatStoreProvider).allUsers();
    final byId = {for (final u in users) u.userId: u};
    final recipients = <int, UserDto>{};
    for (final id in memberIds) {
      final u = byId[id];
      if (u == null) continue;
      if (u.publicKey.isEmpty) {
        // 对方还没配加密密钥：拉进来也没人能解，直接拦住比事后 broken 好
        throw StateError(t.chatCreateMemberNoKey(u.displayName));
      }
      recipients[id] = u;
    }

    // 1. 本地生成频道密钥（同时把我自己的那份先封好，join 要用）
    final fresh = e2ee.newChannelKey([mine]);
    // 2. create
    final id = await api.createNamedChannel(
      name: trimmed,
      purpose: purpose,
      type: type,
      encrypted: true,
    );
    if (id <= 0) throw StateError(t.chatCreateNoChannelId);
    // 3. join：把明文密钥留在本地，带上封给自己的副本
    e2ee.putChannelKey(id, fresh.key);
    await api.joinNamedChannel(id, channelKeyEnc: fresh.sealedKeys.first);
    // 4. invite：每个成员各封一份（顺序必须与 user_ids 一一对应）
    if (recipients.isNotEmpty) {
      await api.inviteNamedChannel(
        id,
        userIds: recipients.keys.toList(),
        channelKeyEncs: [
          for (final pk in recipients.values.map((u) => u.publicKey))
            e2ee.sealChannelKey(id, pk),
        ],
      );
    }
    debugPrint('[create] 加密频道 #$id 建好，成员 ${recipients.keys.toList()}');
    // ⚠️ **先把本地行和"封给自己那份 channel_key_enc"落库，再刷新列表。**
    //
    // 顺序很关键：`_refresh()` 会走一次全量同步并按服务端列表剪掉"名单外"的
    // 频道（`ChatStore.upsertChannels(removeMissing: true)`，对位官方
    // `DatabaseHelper.setChannels(channels, true)`）。刚建好的频道有可能还没
    // 进服务端的 `Channel/list`（列表短暂滞后），而 `channel_key_enc`
    // **服务端永远不会给**（见下），行一旦被剪，重启后这把频道密钥就
    // **永久找不回**、该频道历史密文再也解不开。
    // 带密文的行在 store 层受"**本地新建不剪**"+"E2EE 关键行不剪"双重保护，
    // 所以先写它是安全的（`upsertLocallyCreatedChannel`）。
    final store = ref.read(chatStoreProvider);
    await store.upsertLocallyCreatedChannel(
      ChannelDto(
        channelId: id,
        name: trimmed,
        purpose: purpose,
        type: type,
        encrypted: true,
        isJoined: true,
        channelKeyEnc: fresh.sealedKeys.first,
      ),
    );
    await _refresh();
    // 把"封给我自己那份 channel_key_enc"落到本地频道行。
    //
    // ⚠️ 不能指望 `Channel/list` 带回来：服务端对**自己建的**频道不返回
    // `channel_key_enc`（真机实测：本地行一直是空的，重启后 `keyState` 变
    // missing / 界面显示 ⚠，明明密钥就在手里）。原版也是在 create/join 之后
    // 自己把这份密文写进数据库（`DatabaseHelper` 的频道行）。
    // 刷新后行可能已被服务端数据合并，这里再确认一次（幂等）。
    await store.updateChannelEncryptKeys([id], [fresh.sealedKeys.first]);
    return CreatedChannel(channelId: id, encrypted: true);
  }

  /// 建完立刻刷新频道列表/成员，让新频道出现在首页。
  ///
  /// **必须 await**：`refresh()` 里还有一次网络同步，放任它跑会在
  /// ProviderContainer 销毁后碰到已释放的 Ref（测试里直接炸）。
  Future<void> _refresh() async {
    ref.invalidate(channelsProvider);
    ref.invalidate(usersProvider);
    try {
      await ref.read(chatSessionControllerProvider.notifier).refresh();
    } catch (e) {
      debugPrint('[create] 刷新频道列表失败（不影响已建好的频道）：$e');
    }
  }
}
