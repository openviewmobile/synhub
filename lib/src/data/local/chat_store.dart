// 本地聊天数据仓库 —— 把 drift 的 [ChatDatabase] 包成面向 DTO 的读写接口。
//
// 上层（Riverpod / 页面）只认 [ChannelDto] / [UserDto]，不碰 drift 的 Row 类型。
//
// upsert 语义（**简单版**，够当前同步流程用）：
//   * 按 id 覆盖：同 id 的直接替换，绝不产生重复行；
//   * 传入 DTO 的字符串为空 / 数字为 0 时，保留本地已有的非空值，避免低版本
//     服务器或增量事件把已有资料抹掉；
//   * 例外（**始终以传入值为准**）：频道的 unread*、lastPostAt、lastViewAt、
//     isStar、isJoined、notification* —— 这些来自服务器列表响应，必须刷新；
//   * 布尔量不视为「空」（false 不是 0），始终以传入值为准，否则
//     isDeleted / isDisabled 会一直粘住 true。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../dto/channel_dto.dart';
import '../dto/post_dto.dart';
import '../dto/user_dto.dart';
import 'database.dart';
import '../e2ee/e2ee_service.dart';

class ChatStore implements E2eeStore {
  ChatStore(this.db);

  final ChatDatabase db;

  /// 本进程内**本地新建**、还没被服务端列表确认过的频道 id
  /// （由 [upsertLocallyCreatedChannel] 登记）。清理时必须放过它们 ——
  /// 服务端 `Channel/list` 可能**滞后**，刚建好的频道不能因为"这次列表里
  /// 没有"就被当成陈旧缓存删掉（真实回归：`initiateChatbot` 是"先写本地
  /// 再 `refresh()`"，会被自己的剪枝删掉）。
  final Set<int> _locallyCreatedChannelIds = <int>{};

  /// 服务端换了库（`SYNO.Chat.User/login` 的 `db_uuid` 变了）→ 本地缓存全清。
  ///
  /// 原版的行为是抛 `DbUuidException` 逼用户重新登录并清库；我们只清数据，
  /// 保留 E2EE 身份等本地设置（清掉私钥就再也解不开历史密文了）。
  ///
  /// ⚠️ **带 `channel_key_enc` 的加密频道行（连同它的消息行）也不清。**
  /// 理由与剪枝侧的 [\_pruneChannelsMissingFrom] 保护 ④ **同一条**：
  /// 那段频道密钥密文 `Channel/list` **不会**给回来（对"自己建的"频道它回空），
  /// 本地只此一份 ⇒ 删掉就是**永久丢这把密钥**、该频道历史密文再也解不开。
  /// 第 326 轮（D24）把 `db_uuid` 落盘时只想着"清缓存"，漏了它不在
  /// `keyValueRows` 而在 `channelRows`；**第 327 轮真机实测踩到**：
  /// 换库清理后频道 267 `flt-p7m-enc-278125` 的行与密钥一起消失，
  /// 而重新同步（`is_joined=true`）**没有把它带回来** ⇒ 只剩备份能救。
  /// 通式：**"清理缓存"这类动作绝不允许造成不可逆的数据损失** ——
  /// 凡"服务端不会再给"的列，清理前必须先把它排除掉。
  Future<void> clearAllData() async {
    await db.transaction(() async {
      final keep = <int>{
        for (final row in await db.select(db.channelRows).get())
          if (row.channelKeyEnc.isNotEmpty) row.channelId,
      };
      if (keep.isEmpty) {
        await db.delete(db.postRows).go();
      } else {
        await (db.delete(
          db.postRows,
        )..where((t) => t.channelId.isNotIn(keep))).go();
      }
      await (db.delete(
        db.channelRows,
      )..where((t) => t.channelId.isNotIn(keep))).go();
      await db.delete(db.userRows).go();
    });
  }

  // ------------------------------------------------------------ 键值（E2EE 身份等）

  /// 读一个小状态；没有就返回 null。
  @override
  Future<String?> setting(String key) async {
    final row = await (db.select(
      db.keyValueRows,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// 写一个小状态。
  @override
  Future<void> setSetting(String key, String value) => db
      .into(db.keyValueRows)
      .insertOnConflictUpdate(
        KeyValueRowsCompanion.insert(key: key, value: Value(value)),
      );

  /// 删一个小状态（清空 E2EE 身份用）。
  @override
  Future<void> deleteSetting(String key) =>
      (db.delete(db.keyValueRows)..where((t) => t.key.equals(key))).go();

  /// 读全部键值（调试/导出用）。
  Future<Map<String, String>> allSettings() async {
    final rows = await db.select(db.keyValueRows).get();
    return {for (final r in rows) r.key: r.value};
  }

  // ------------------------------------------------------------ 频道

  /// 批量写入频道（先查旧行做字段合并，再按主键 upsert）。
  ///
  /// [removeMissing] = true 时**额外剪掉服务端本次列表里没有的频道行** ——
  /// 逐行对位原版 `DatabaseHelper.setChannels(channels, true)`
  /// （APK 反编译 `com/synology/dschat/data/local/DatabaseHelper.java:703-739`）：
  ///   1. 传入列表按 `channel_id` 建 map（`:706-708`）；
  ///   2. `SELECT * FROM ChatChannel` 遍历本地已有行（`:710-712`）；
  ///   3. 命中 map 的 → `UPDATE ... WHERE channel_id = ?` 并 `map.remove(id)`（`:716-722`）；
  ///   4. **未命中且 flag 为 true → `delete("ChatChannel", "channel_id = ? ", …)`（`:723-727`）**；
  ///   5. map 里剩下的（新频道）再 INSERT（`:733`）。
  ///
  /// **为什么这里剪枝是安全的（不是"增量语义下误删"）**：官方只在
  /// `AccountManager.fetchChannels(String isJoined)` 这一条**全量**请求上用它，
  /// 该请求的线参**只有 `is_joined`**（`AccountManager.java:569-577`，
  /// `WebApiService.listChannels(path, "SYNO.Chat.Channel", "list", version, params)`），
  /// **没有 offset / limit / since**；而复合请求 `SYNO.Entry.Request` 那条路
  /// 显式传 **false**（`AccountManager.java:621`，只回部分结果，不能剪）。
  /// 官方的 `SyncWorker.fetchData` / `LoginPresenter` 也都是 `"true"`
  /// （`SyncWorker$fetchData$3.java:262`）⇒ 官方同步一次就按 `is_joined=true`
  /// 的全量列表把本地库剪到与它一致。我们的 `ChatApi.listChannels()` 与官方
  /// **同形同参**（`{'is_joined': 'true'}`）且版本候选逐字一致
  /// （`chat_api.dart:298` = `[5,4,2,1]`，官方 `AccountManager.java:573`
  /// 也是 `{5,4,1,2}` 集合），所以可以同样剪。
  ///
  /// ⚠️ **五条本地保护（比官方更保守，见各自理由）**：
  ///   1. [channels] **为空时直接返回、绝不剪**。官方没有这层保护，但我们的
  ///      `ChatApi._channelsOf` 在回包形状意外时**静默回空表**
  ///      （`chat_api.dart:2185-2192`），服务端抖动/换版本就可能把整个频道库
  ///      误清空。**宁可留脏行，不可丢数据。**
  ///   2. **本地新建、服务端还没确认过**的频道不剪 —— 服务端列表会滞后，
  ///      而"先写本地再 refresh"是我们自己的既有写法（`initiateChatbot`
  ///      `chat_session_controller.dart:1795-1796`、加密频道 create）。
  ///      见 [upsertLocallyCreatedChannel]。
  ///   3. 有「发送失败 / 已过期」消息（`state IN (2,3)`）的频道**不剪** ——
  ///      这是本项目既有政策（见 [watchChannelsWithFailedPosts] 的注释：
  ///      这类频道"不能因为隐藏就看不见"，剪了用户就找不到重发入口）。
  ///   4. 带 `channel_key_enc` 的**加密**频道不剪 —— 那份密文服务端不给、
  ///      本地只此一份，剪了就是**永久丢密钥**（理由见
  ///      [_pruneChannelsMissingFrom] 里的长注释）。
  ///   5. 只删 `channelRows` + `postRows`，**绝不碰 `keyValueRows`** ——
  ///      E2EE 身份私钥等本地设置在那里，见 [clearAllData] 的注释。
  Future<void> upsertChannels(
    List<ChannelDto> channels, {
    bool removeMissing = false,
  }) async {
    if (channels.isEmpty) return;
    await db.transaction(() async {
      for (final channel in channels) {
        final old = await _findChannelRow(channel.channelId);
        final merged = old == null ? channel : _mergeChannel(old, channel);
        await db
            .into(db.channelRows)
            .insertOnConflictUpdate(_channelCompanion(merged));
      }
      if (removeMissing) {
        await _pruneChannelsMissingFrom(
          channels.map((c) => c.channelId).toSet(),
        );
      }
    });
  }

  /// **本地新建**的频道（`Channel.Named create` / `Channel.Chatbot initiate`）
  /// 落库。
  ///
  /// 与 [upsertChannels] 的唯一区别：这个频道会被登记成"本地新建、服务端还没
  /// 确认过"，**之后的清理一律放过它**，直到某次全量列表真的把它带回来为止。
  ///
  /// 为什么必须有这条：我们的既有写法就是"**先写本地、再 `refresh()`**"
  /// （`chat_session_controller.dart:1795-1796` 的 `initiateChatbot`、
  /// `channel_create_controller.dart` 的加密频道）。`refresh()` 里的全量同步
  /// 带 `removeMissing: true`，而**服务端列表可能滞后**（或本次响应只覆盖了
  /// 旧数据）⇒ 刚建好的频道会被自己的剪枝删掉、界面上"建完就消失"。
  /// 这一条与官方的差异是**有意的**：官方靠"服务端立刻收录"这个假设，
  /// 我们不吃这个假设（本地删除是不可逆的，宁可晚一轮再清）。
  Future<void> upsertLocallyCreatedChannel(ChannelDto channel) async {
    await upsertChannels([channel]);
    if (channel.channelId > 0) {
      _locallyCreatedChannelIds.add(channel.channelId);
    }
  }

  /// 剪掉不在 [keep] 里的频道行（连同它的消息行）。
  /// 调用方必须保证 [keep] 来自**服务端全量列表**（见 [upsertChannels]）。
  /// 三类行会被跳过：
  ///   * **本地新建、服务端还没确认过的**频道（见 [_locallyCreatedChannelIds]）；
  ///   * 有失败/过期消息的频道（`state IN (2,3)`，见文件内政策）；
  ///   * **带 `channel_key_enc` 的加密频道**（E2EE，见下）。
  /// ⚠️ 在这里**只动 channelRows / postRows**：`keyValueRows`（E2EE 身份、
  /// 各类本地设置）绝不参与清理。
  Future<void> _pruneChannelsMissingFrom(Set<int> keep) async {
    // 服务端列表这次带回来的频道 = 已被服务端确认 ⇒ 撤销"本地新建"标记。
    // （之后它再从列表里消失，就该按陈旧缓存清掉了 —— 保护是**临时**的，
    //   不会把剪枝功能废掉。）
    _locallyCreatedChannelIds.removeAll(keep);
    final protected = await failedPostChannelIds();
    final rows = await db.select(db.channelRows).get();
    for (final row in rows) {
      final id = row.channelId;
      if (keep.contains(id) || protected.contains(id)) continue;
      // 本地新建、服务端还没确认：列表滞后不是"这个频道没了"的证据。
      if (_locallyCreatedChannelIds.contains(id)) continue;
      // ⚠️ E2EE：`channel_key_enc` 是**服务端永远不会给**的东西 ——
      // 对"自己建的"频道，`Channel/list` 回的 `channel_key_enc` 一直是空
      // （真机实测，见 `channel_create_controller.dart:147-155` 的注释），
      // 而 `E2eeService._channelKeys` 只是**内存** map
      // （`e2ee_service.dart:108`），重启后唯一的恢复来源就是这一列
      // （`loadChannelKeys` ← `ChannelDto.channelKeyEnc`）。
      // ⇒ 剪掉这一行 = **永久丢掉**这把频道密钥、该频道的历史密文再也解不开。
      //   这是不可逆的数据损失，绝不能由"清理缓存"引起，所以这里整类放过。
      if (row.channelKeyEnc.isNotEmpty) continue;
      await (db.delete(
        db.channelRows,
      )..where((t) => t.channelId.equals(id))).go();
      await (db.delete(db.postRows)..where((t) => t.channelId.equals(id))).go();
    }
  }

  /// 会话列表用：按 sortKey（channel_order_time，缺失退回 last_post_at）降序。
  Stream<List<ChannelDto>> watchChannels() {
    return db.select(db.channelRows).watch().map(_sortedChannels);
  }

  /// 有「发送失败 / 已过期」消息的频道集合（`state IN (2,3)`）。
  ///
  /// 原版 `Channel.hideAtSideBar()` 会拿它做例外：**有失败消息就不藏**，
  /// 否则用户找不到重试入口。判定用的是 `observeAllOutDatedPosts()`
  /// （`DatabaseHelper.java:1514`：`WHERE state = 3 OR state = 2`），
  /// 所以两个状态都要算 —— 进过频道之后失败消息会从 2 变成 3，漏了 3
  /// 就会出现"频道被藏起来、消息也找不回"。
  Stream<Set<int>> watchChannelsWithFailedPosts() {
    final query = db.selectOnly(db.postRows, distinct: true)
      ..addColumns([db.postRows.channelId])
      ..where(_failedPostState());
    return query.watch().map((rows) {
      return rows
          .map((r) => r.read(db.postRows.channelId) ?? 0)
          .where((id) => id > 0)
          .toSet();
    });
  }

  /// [watchChannelsWithFailedPosts] 的**一次性版本**。
  ///
  /// 清理频道行时要在一个事务里同步判定"这个频道能不能删"——流版本在这里
  /// 没法用。两条路径共用 [_failedPostState] 谓词，保证判定**永远不会跑偏**
  /// （`state IN (2,3)` 漏一个状态就会出现"频道被清了、失败消息也跟着没了"）。
  Future<Set<int>> failedPostChannelIds() async {
    final query = db.selectOnly(db.postRows, distinct: true)
      ..addColumns([db.postRows.channelId])
      ..where(_failedPostState());
    final rows = await query.get();
    return rows
        .map((r) => r.read(db.postRows.channelId) ?? 0)
        .where((id) => id > 0)
        .toSet();
  }

  /// 「有失败/过期消息」的判定谓词（**两个状态都要**，理由见上）。
  Expression<bool> _failedPostState() => db.postRows.state.isIn(const [2, 3]);

  Future<List<ChannelDto>> allChannels() async {
    final rows = await db.select(db.channelRows).get();
    return _sortedChannels(rows);
  }

  Future<List<UserDto>> allUsers() async {
    final rows = await db.select(db.userRows).get();
    return rows.map(_userFromRow).toList();
  }

  /// 未读 +1；返回更新后的 DTO（频道不存在时返回 null）。
  Future<ChannelDto?> applyPostCreate({
    required int channelId,
    required int createAt,
  }) async {
    final old = await _findChannelRow(channelId);
    if (old == null) return null;

    final updated = _channelFromRow(
      old,
    ).copyWith(unread: old.unread + 1, lastPostAt: createAt);
    await _writeChannel(updated);
    return updated;
  }

  /// 把 `Channel.Hashtag/list` 的结果落到频道行（原版 `setChannelHashtags`）。
  ///
  /// 真机实测：`Channel/list` 不带标签，只有这个接口给；原版存在
  /// `ChatChannel.hashtags` 里，输入框 `#` 联想与标签页都读它。
  Future<void> updateChannelHashtags(
    int channelId,
    List<String> hashtags,
  ) async {
    final old = await _findChannelRow(channelId);
    if (old == null) return;
    final updated = _channelFromRow(old).copyWith(hashtags: hashtags);
    await _writeChannel(updated);
  }

  /// 频道的标签列表（本地缓存，空表示还没同步过）。
  Future<List<String>> channelHashtags(int channelId) async {
    final old = await _findChannelRow(channelId);
    return old == null ? const [] : _decodeStringList(old.hashtags);
  }

  /// `client.channel.join` / `disjoin` / `update` 等：只改 isJoined。
  Future<ChannelDto?> setJoined(int channelId, {required bool joined}) async {
    final old = await _findChannelRow(channelId);
    if (old == null) return null;

    final updated = _channelFromRow(old).copyWith(isJoined: joined);
    await _writeChannel(updated);
    return updated;
  }

  /// 标记已读：unread 系列清零、lastViewAt 设为 nowMillis。
  Future<void> markRead(int channelId, {required int nowMillis}) async {
    final old = await _findChannelRow(channelId);
    if (old == null) return;

    final updated = _channelFromRow(old).copyWith(
      unread: 0,
      unreadMention: 0,
      unreadComment: 0,
      unreadMentionComment: 0,
      unreadThread: const {},
      lastViewAt: nowMillis,
    );
    await _writeChannel(updated);
  }

  /// 自己发消息后刷新频道的排序时间，但**不加未读**（原 App 也是这样：
  /// 发送方从 HTTP 响应同步本地状态，不把自己算成未读）。
  Future<ChannelDto?> touchChannelOnOwnPost({
    required int channelId,
    required int at,
  }) async {
    final old = await _findChannelRow(channelId);
    if (old == null) return null;

    final updated = _channelFromRow(
      old,
    ).copyWith(lastPostAt: at, channelOrderTime: at);
    await _writeChannel(updated);
    return updated;
  }

  /// 话题已读：整频道清空，或只清某个话题（`channel.view_comment` 广播 / 上报回执）。
  Future<ChannelDto?> resetThreadUnread(
    int channelId, {
    int? threadId,
    int lastViewCommentAt = 0,
  }) async {
    final old = await _findChannelRow(channelId);
    if (old == null) return null;
    final dto = _channelFromRow(old);
    if (threadId != null && threadId > 0) {
      final map = Map<int, int>.from(dto.unreadThread)..remove(threadId);
      final dropped = dto.unreadThread[threadId] ?? 0;
      final updated = dto.copyWith(
        unreadThread: map,
        unreadComment: (dto.unreadComment - dropped).clamp(0, 1 << 31),
        lastViewCommentAt: lastViewCommentAt > 0
            ? lastViewCommentAt
            : dto.lastViewCommentAt,
      );
      await _writeChannel(updated);
      return updated;
    }
    final updated = dto.copyWith(
      unreadComment: 0,
      unreadMentionComment: 0,
      unreadThread: const {},
      lastViewCommentAt: lastViewCommentAt > 0
          ? lastViewCommentAt
          : dto.lastViewCommentAt,
    );
    await _writeChannel(updated);
    return updated;
  }

  /// `client.broadcast: channel.view` —— **别的设备**把这个频道读掉了。
  ///
  /// 原版 `lambda$viewChannel$104` 就是 `updateLastViewAt(channelId, last_view_at)`
  /// （载荷里的 `user_id` 读出来但没用）；我们未读是**持久列**不是查询算出来的，
  /// 所以这里顺带把未读清零，效果等价。
  Future<ChannelDto?> applyChannelView(
    int channelId, {
    required int lastViewAt,
  }) async {
    final old = await _findChannelRow(channelId);
    if (old == null) return null;
    final updated = _channelFromRow(old).copyWith(
      unread: 0,
      unreadMention: 0,
      unreadComment: 0,
      unreadMentionComment: 0,
      unreadThread: const {},
      lastViewAt: lastViewAt > 0 ? lastViewAt : old.lastViewAt,
    );
    await _writeChannel(updated);
    return updated;
  }

  /// `client.broadcast: channel.hide` / `channel.show` —— 设置/清掉 last_hide_at
  Future<ChannelDto?> setLastHideAt(
    int channelId, {
    required int lastHideAt,
  }) async {
    final old = await _findChannelRow(channelId);
    if (old == null) return null;
    final updated = _channelFromRow(old).copyWith(lastHideAt: lastHideAt);
    await _writeChannel(updated);
    return updated;
  }

  /// `client.channel.hide_global` / `unhide_global` —— 管理员把频道全局隐藏
  Future<ChannelDto?> setHideGlobalAt(int channelId, {required int at}) async {
    final old = await _findChannelRow(channelId);
    if (old == null) return null;
    final updated = _channelFromRow(old).copyWith(hideGlobalAt: at);
    await _writeChannel(updated);
    return updated;
  }

  /// `client.broadcast: post.subscribe` / `post.unsubscribe` —— 维护频道的
  /// `subscribes`（我订阅的话题 id 列表）与 `channel_order_time`。
  Future<ChannelDto?> setSubscribed(
    int channelId,
    int postId, {
    required bool subscribed,
    int? channelOrderTime,
  }) async {
    if (channelId <= 0 || postId <= 0) return null;
    final old = await _findChannelRow(channelId);
    if (old == null) return null;
    final dto = _channelFromRow(old);
    final ids = List<int>.from(dto.subscribes);
    if (subscribed) {
      if (!ids.contains(postId)) ids.add(postId);
    } else {
      ids.remove(postId);
    }
    final updated = dto.copyWith(
      subscribes: ids,
      channelOrderTime: channelOrderTime ?? dto.channelOrderTime,
    );
    await _writeChannel(updated);
    return updated;
  }

  /// `client.broadcast: user.delete` —— 原版 `DatabaseHelper.deleteUser` +
  /// `client.user.updatekey`：更新某个用户的公钥（换密钥对了）。
  ///
  /// 原版 `lambda$updateKey$111`：`public_key` 有就写，是自己才写 `private_key_enc`。
  Future<void> setUserPublicKey(
    int userId, {
    String? publicKey,
    String? privateKeyEnc,
  }) async {
    if (userId <= 0) return;
    final old = await _findUserRow(userId);
    if (old == null) return;
    final updated = UserDto(
      userId: old.userId,
      username: old.username,
      nickname: old.nickname,
      type: old.type,
      status: old.status,
      publicKey: publicKey ?? old.publicKey,
      privateKeyEnc: privateKeyEnc ?? old.privateKeyEnc,
      isDisabled: old.isDisabled,
      isDeleted: old.isDeleted,
      deleteAt: old.deleteAt,
      createAt: old.createAt,
      updateAt: old.updateAt,
    );
    await db.into(db.userRows).insertOnConflictUpdate(_userCompanion(updated));
  }

  /// `UserEvent.disable`：本地标成已删除（不物理删，历史消息还得显示作者名）。
  Future<UserDto?> markUserDeleted(int userId, {int deleteAt = 0}) async {
    if (userId <= 0) return null;
    final old = await _findUserRow(userId);
    if (old == null) return null;
    // UserDto 没有 copyWith（字段太多且服务端基本整条下发），这里直接按行改
    final updated = UserDto(
      userId: old.userId,
      username: old.username,
      nickname: old.nickname,
      type: old.type,
      status: '',
      publicKey: old.publicKey,
      privateKeyEnc: old.privateKeyEnc,
      isDisabled: true,
      isDeleted: true,
      deleteAt: deleteAt,
      createAt: old.createAt,
      updateAt: old.updateAt,
    );
    await db.into(db.userRows).insertOnConflictUpdate(_userCompanion(updated));
    return updated;
  }

  // ------------------------------------------------------------ 用户

  /// 批量写入用户（默认先做字段合并，再按主键 upsert）。
  ///
  /// [authoritative] = true 时**不做字段合并**：把传入的 user 整行覆盖。
  /// 这是 `User/set`（改资料/换头像/移除头像）响应的语义 —— 原版
  /// `DatabaseHelper.setUser`（APK 反编译 `data/local/DatabaseHelper.java:1261`）
  /// 就是 `toContentValues(user)` 直接 UPDATE，**没有任何 `0/空串保留旧值`**。
  ///
  /// 为什么必须区分：`_mergeUser` 的"0/空串保留旧值"是为**增量广播**
  /// （`user.update` 只带部分字段）设计的，但 `User/set` 返回的是**完整 user**。
  /// 移除头像时服务端回 `avatar_version: 0`，走合并会被旧值吃掉 → 本地永远
  /// 显示旧头像；同理清空简介也改不掉。
  Future<void> upsertUsers(
    List<UserDto> users, {
    bool authoritative = false,
  }) async {
    if (users.isEmpty) return;
    await db.transaction(() async {
      for (final user in users) {
        final old = await _findUserRow(user.userId);
        final merged = (old == null || authoritative)
            ? user
            : _mergeUser(old, user);
        await db
            .into(db.userRows)
            .insertOnConflictUpdate(_userCompanion(merged));
      }
    });
  }

  /// `user.update` / `user.create` 的增量写入。
  ///
  /// 载荷结构与 `User.list` 一致；[UserDto.tryFromBroadcast] 解析不出
  /// user_id 时直接忽略（有些广播只是状态提示，没有完整用户对象）。
  Future<void> upsertUserFromEvent(Map<String, dynamic> payload) async {
    final dto = UserDto.tryFromBroadcast(payload);
    if (dto == null) return;
    await upsertUsers([dto]);
  }

  // ------------------------------------------------------------ 内部

  Future<ChannelRow?> _findChannelRow(int channelId) {
    return (db.select(
      db.channelRows,
    )..where((t) => t.channelId.equals(channelId))).getSingleOrNull();
  }

  Future<UserRow?> _findUserRow(int userId) {
    return (db.select(
      db.userRows,
    )..where((t) => t.userId.equals(userId))).getSingleOrNull();
  }

  Future<void> _writeChannel(ChannelDto channel) {
    return db
        .into(db.channelRows)
        .insertOnConflictUpdate(_channelCompanion(channel));
  }

  static List<ChannelDto> _sortedChannels(List<ChannelRow> rows) {
    final list = rows.map(_channelFromRow).toList();
    list.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    return list;
  }

  /// 频道字段合并，规则见文件头注释。
  static ChannelDto _mergeChannel(ChannelRow old, ChannelDto incoming) {
    final prev = _channelFromRow(old);
    return ChannelDto(
      channelId: incoming.channelId,
      name: incoming.name.isEmpty ? prev.name : incoming.name,
      purpose: incoming.purpose.isEmpty ? prev.purpose : incoming.purpose,
      type: incoming.type.isEmpty ? prev.type : incoming.type,
      encrypted: incoming.encrypted,
      // 以下 6 类始终取新值：服务器列表响应说了算
      isJoined: incoming.isJoined,
      isStar: incoming.isStar,
      unread: incoming.unread,
      unreadMention: incoming.unreadMention,
      unreadComment: incoming.unreadComment,
      unreadMentionComment: incoming.unreadMentionComment,
      unreadThread: incoming.unreadThread,
      subscribes: incoming.subscribes.isEmpty
          ? prev.subscribes
          : incoming.subscribes,
      members: incoming.members.isEmpty ? prev.members : incoming.members,
      // broken 列表**只能靠实时事件攒**：真机实测 `Channel/list` 里这个字段
      // 一直是空数组（2.3.1），而原版 `ChannelHelper` 也是"非 null 才写库"——
      // 所以这里空值时保留本地已有的，否则每次刷新都把 broken 标记冲掉。
      brokenUsers: incoming.brokenUsers.isEmpty
          ? prev.brokenUsers
          : incoming.brokenUsers,

      channelKeyEnc: incoming.channelKeyEnc.isEmpty
          ? prev.channelKeyEnc
          : incoming.channelKeyEnc,
      totalMemberCount: incoming.totalMemberCount == 0
          ? prev.totalMemberCount
          : incoming.totalMemberCount,
      creatorId: incoming.creatorId == 0 ? prev.creatorId : incoming.creatorId,
      lastPostAt: incoming.lastPostAt,
      lastViewAt: incoming.lastViewAt,
      lastViewCommentAt: incoming.lastViewCommentAt == 0
          ? prev.lastViewCommentAt
          : incoming.lastViewCommentAt,
      channelOrderTime: incoming.channelOrderTime == 0
          ? prev.channelOrderTime
          : incoming.channelOrderTime,
      hideGlobalAt: incoming.hideGlobalAt == 0
          ? prev.hideGlobalAt
          : incoming.hideGlobalAt,
      lastHideAt: incoming.lastHideAt == 0
          ? prev.lastHideAt
          : incoming.lastHideAt,
      notificationDesktop: incoming.notificationDesktop,
      notificationMobile: incoming.notificationMobile,
      notificationMute: incoming.notificationMute,
      // 标签服务端不下发（本地靠 `Channel.Hashtag/list` 攒），空值别把已有列表冲掉
      hashtags: incoming.hashtags.isEmpty ? prev.hashtags : incoming.hashtags,
    );
  }

  /// 用户字段合并：空串 / 0 保留旧值；布尔量取新值。
  static UserDto _mergeUser(UserRow old, UserDto incoming) {
    final prev = _userFromRow(old);
    return UserDto(
      userId: incoming.userId,
      username: incoming.username.isEmpty ? prev.username : incoming.username,
      nickname: incoming.nickname.isEmpty ? prev.nickname : incoming.nickname,
      type: incoming.type.isEmpty ? prev.type : incoming.type,
      status: incoming.status.isEmpty ? prev.status : incoming.status,
      humanType: incoming.humanType.isEmpty
          ? prev.humanType
          : incoming.humanType,
      botType: incoming.botType.isEmpty ? prev.botType : incoming.botType,
      appId: incoming.appId == 0 ? prev.appId : incoming.appId,
      dsmUid: incoming.dsmUid == 0 ? prev.dsmUid : incoming.dsmUid,
      avatarVersion: incoming.avatarVersion == 0
          ? prev.avatarVersion
          : incoming.avatarVersion,
      avatarColor: incoming.avatarColor.isEmpty
          ? prev.avatarColor
          : incoming.avatarColor,
      email: incoming.email.isEmpty ? prev.email : incoming.email,
      description: incoming.description.isEmpty
          ? prev.description
          : incoming.description,
      publicKey: incoming.publicKey.isEmpty
          ? prev.publicKey
          : incoming.publicKey,
      privateKeyEnc: incoming.privateKeyEnc.isEmpty
          ? prev.privateKeyEnc
          : incoming.privateKeyEnc,
      isDisabled: incoming.isDisabled,
      isDeleted: incoming.isDeleted,
      hasUrl: incoming.hasUrl,
      isAlwaysOffline: incoming.isAlwaysOffline,
      // ⚠️ 机器人/斜杠命令的字段必须带上：`_mergeUser` 是"逐字段合并"，
      // 漏掉哪个字段就等于把它**清空**。踩过的坑：`User/list` 的
      // human/bot 两段会各写一次同一个人（第二次就走合并），漏掉
      // `chatbot_props` 后 `welcome_note`/`purpose`/`hide_from_user` 和
      // `slash_props`（`/jitsi` 之类）全被抹成空 —— 机器人列表和
      // 机器人会话的欢迎语都会跟着坏。取值规则同其它字段：新值非空/为真
      // 就用新值，否则保留旧值（广播可能只带部分字段）。
      slashCmd: incoming.slashCmd.isEmpty ? prev.slashCmd : incoming.slashCmd,
      slashDescription: incoming.slashDescription.isEmpty
          ? prev.slashDescription
          : incoming.slashDescription,
      slashUrl: incoming.slashUrl.isEmpty ? prev.slashUrl : incoming.slashUrl,
      slashUsage: incoming.slashUsage.isEmpty
          ? prev.slashUsage
          : incoming.slashUsage,
      chatbotHideFromUser:
          incoming.chatbotHideFromUser || prev.chatbotHideFromUser,
      chatbotPurpose: incoming.chatbotPurpose.isEmpty
          ? prev.chatbotPurpose
          : incoming.chatbotPurpose,
      chatbotWelcomeNote: incoming.chatbotWelcomeNote.isEmpty
          ? prev.chatbotWelcomeNote
          : incoming.chatbotWelcomeNote,
      botIsSystem: incoming.botIsSystem || prev.botIsSystem,
      botStickerName: incoming.botStickerName.isEmpty
          ? prev.botStickerName
          : incoming.botStickerName,
      // `user_props` 同理：`User/list` 的 human/bot 两段各写一次同一个人，
      // 漏掉这个字段就等于把 `timezoneUTC` / `avatar_color` 等全抹掉。
      userProps: incoming.userProps.isNotEmpty
          ? incoming.userProps
          : prev.userProps,
      createAt: incoming.createAt == 0 ? prev.createAt : incoming.createAt,
      updateAt: incoming.updateAt == 0 ? prev.updateAt : incoming.updateAt,
      deleteAt: incoming.deleteAt == 0 ? prev.deleteAt : incoming.deleteAt,
    );
  }

  // ------------------------------------------------------------ 消息

  /// 批量写入消息。
  ///
  /// 去重键：`post_id > 0` 用 `(channelId, postId)`（服务端消息），
  /// 否则用 `tmp_post_id`（本地乐观发送的消息）。
  /// 同一批里若已有同键行则覆盖，避免重复插入。
  Future<void> upsertPosts(List<PostDto> posts) async {
    if (posts.isEmpty) return;
    await db.transaction(() async {
      for (final post in posts) {
        final existing = await _findPostRow(post);
        if (existing == null) {
          await db.into(db.postRows).insert(_postCompanion(post));
        } else {
          await db
              .update(db.postRows)
              .replace(_postCompanion(post).copyWith(id: Value(existing.id)));
        }
      }
    });
  }

  /// 用服务端返回的一窗消息**替换**某频道的主列表。
  ///
  /// 逐行对齐原版 `DatabaseHelper.resetPosts`（预加载那条路走的就是它）：
  /// 只删 `state == 0`（正常情况下服务端来的）且 `thread_id == 0 || thread_id == post_id`
  /// 的行 —— **本地"发送中/发送失败"的消息（state != 0）与话题回复都不动**，
  /// 免得预加载把用户还没发出去的东西冲掉。
  Future<void> replaceChannelPosts(int channelId, List<PostDto> posts) async {
    if (posts.isEmpty) return;
    await db.transaction(() async {
      await (db.delete(db.postRows)..where(
            (t) =>
                t.channelId.equals(channelId) &
                t.state.equals(0) &
                (t.threadId.equals(0) | t.threadId.equalsExp(t.postId)),
          ))
          .go();
      for (final post in posts) {
        final existing = await _findPostRow(post);
        if (existing == null) {
          await db.into(db.postRows).insert(_postCompanion(post));
        } else {
          await db
              .update(db.postRows)
              .replace(_postCompanion(post).copyWith(id: Value(existing.id)));
        }
      }
    });
  }

  /// 某频道的消息，**新的在前**。
  ///
  /// [threadId] 默认 `0` = 只取**主列表**的消息（话题回复 `thread_id != 0` 不混进来，
  /// 原 App 的频道列表也是这样：回复只以"N 条回复"的形式挂在父消息上）；
  /// 传具体的话题 id 则返回该话题下的回复。
  ///
  /// [beforeSortKey] 用于向上翻页：只取比它更早的（严格小于）。
  Stream<List<PostDto>> watchPosts(
    int channelId, {
    int? limit,
    int threadId = 0,
  }) {
    final q = db.select(db.postRows)
      ..where(
        (t) => t.channelId.equals(channelId) & t.threadId.equals(threadId),
      );
    return q.watch().map((rows) => _sortedPosts(rows, limit: limit));
  }

  Future<List<PostDto>> postsForChannel(
    int channelId, {
    int? limit,
    int? beforeSortKey,
    int threadId = 0,
  }) async {
    final q = db.select(db.postRows)
      ..where(
        (t) => t.channelId.equals(channelId) & t.threadId.equals(threadId),
      );
    final rows = await q.get();
    var sorted = _sortedPosts(rows);
    if (beforeSortKey != null) {
      sorted = sorted.where((p) => p.sortKey < beforeSortKey).toList();
    }
    if (limit != null && sorted.length > limit) {
      sorted = sorted.sublist(0, limit);
    }
    return sorted;
  }

  /// 局部更新频道的通知偏好（只覆盖显式传入的字段）。
  ///
  /// ⚠️ 别走 `upsertChannels`：频道列表响应里带的偏好可能是空串，
  /// 而 `_mergeChannel` 对偏好是**无条件取新值**，会把刚设好的档位冲掉。
  Future<void> applyChannelPreference(
    int channelId, {
    String? notificationMobile,
    String? notificationDesktop,
    bool? notificationMute,
  }) async {
    if (channelId <= 0) return;
    await (db.update(
      db.channelRows,
    )..where((t) => t.channelId.equals(channelId))).write(
      ChannelRowsCompanion(
        notificationMobile: notificationMobile == null
            ? const Value.absent()
            : Value(notificationMobile),
        notificationDesktop: notificationDesktop == null
            ? const Value.absent()
            : Value(notificationDesktop),
        notificationMute: notificationMute == null
            ? const Value.absent()
            : Value(notificationMute),
      ),
    );
  }

  /// 广播里没带 channel_id 时，用 post_id 反查它属于哪个频道
  Future<int?> findPostChannel(int postId) async {
    if (postId <= 0) return null;
    final row =
        await (db.select(db.postRows)
              ..where((t) => t.postId.equals(postId))
              ..limit(1))
            .getSingleOrNull();
    return row?.channelId;
  }

  /// 局部分更新（`client.broadcast: post.update/star/pin/...` 之类）。
  /// [props] 会**合并**进已有的 `props`（传空 = 不动，删键走 `clearProps`）。
  ///
  /// **只覆盖显式传入的字段** —— 服务端这些广播可能只带变化的部分，
  /// 全量 replace 会把正文/作者冲掉（踩过的坑）。
  Future<PostDto?> applyPostPatch(
    int channelId,
    int postId, {
    String? message,
    bool? isStar,
    bool? isSticky,
    int? commentCount,
    int? lastCommentAt,
    int? lastPinAt,
    int? updateAt,
    List<Map<String, dynamic>>? reactions,
    List<String>? hashtags,
    List<int>? mentions,
    Map<String, dynamic>? props,
    List<String>? clearProps,
  }) async {
    if (postId <= 0) return null;
    final old = await postById(channelId, postId);
    if (old == null) return null;
    final nextProps = <String, dynamic>{...old.props, ...?props};
    for (final key in clearProps ?? const <String>[]) {
      nextProps.remove(key);
    }
    final updated = old.copyWith(
      props: nextProps,
      message: message,
      isStar: isStar,
      isSticky: isSticky,
      commentCount: commentCount,
      lastCommentAt: lastCommentAt,
      lastPinAt: lastPinAt,
      updateAt: updateAt,
      reactions: reactions,
      hashtags: hashtags,
      mentions: mentions,
    );
    await upsertPosts([updated]);
    return updated;
  }

  /// 频道的话题未读 +1（`unread_thread[threadId]` 与 `unread_comment` 同步涨）
  Future<ChannelDto?> applyCommentCreate({
    required int channelId,
    required int threadId,
  }) async {
    final old = await _findChannelRow(channelId);
    if (old == null) return null;
    final dto = _channelFromRow(old);
    final map = Map<int, int>.from(dto.unreadThread);
    map[threadId] = (map[threadId] ?? 0) + 1;
    final updated = dto.copyWith(
      unreadComment: dto.unreadComment + 1,
      unreadThread: map,
    );
    await _writeChannel(updated);
    return updated;
  }

  /// 话题回复数 +1（收到 `thread_id != 0` 的新消息时更新父消息）
  Future<PostDto?> bumpCommentCount(
    int channelId,
    int parentPostId, {
    required int at,
  }) async {
    final parent = await postById(channelId, parentPostId);
    if (parent == null) return null;
    final updated = parent.copyWith(
      commentCount: parent.commentCount + 1,
      lastCommentAt: at,
    );
    await upsertPosts([updated]);
    return updated;
  }

  /// 按服务端 id 取一条（收到 post.create 事件时判断是否已入库）
  Future<PostDto?> postById(int channelId, int postId) async {
    if (postId <= 0) return null;
    final row =
        await (db.select(db.postRows)..where(
              (t) => t.channelId.equals(channelId) & t.postId.equals(postId),
            ))
            .getSingleOrNull();
    return row == null ? null : _postFromRow(row);
  }

  /// 服务端确认删除 → 本地直接删行。
  Future<void> deletePost(int channelId, int postId) async {
    await (db.delete(db.postRows)..where(
          (t) => t.channelId.equals(channelId) & t.postId.equals(postId),
        ))
        .go();
  }

  /// `client.channel.brokenuser`：把某个成员标成"在这个频道解不开"
  /// （原版 `addChannelBrokenUsers`，去重追加）。
  Future<void> addChannelBrokenUsers(int channelId, List<int> userIds) async {
    if (channelId <= 0 || userIds.isEmpty) return;
    final row = await (db.select(
      db.channelRows,
    )..where((t) => t.channelId.equals(channelId))).getSingleOrNull();
    if (row == null) return;
    final current = _decodeIntList(row.brokenUsers).toSet();
    final before = current.length;
    current.addAll(userIds.where((u) => u > 0));
    if (current.length == before) return; // 没变化就别写库
    await (db.update(
      db.channelRows,
    )..where((t) => t.channelId.equals(channelId))).write(
      ChannelRowsCompanion(
        brokenUsers: Value(_encodeIntList(current.toList()..sort())),
      ),
    );
  }

  /// 换密钥对成功后，把本地频道行的 `channel_key_enc` 换成"封给新公钥"的那份
  /// （原版 `DatabaseHelper.updateChannelEncryptKeys(channelIds, keyEncs)`）。
  /// 两个列表一一对应。
  Future<void> updateChannelEncryptKeys(
    List<int> channelIds,
    List<String> channelKeyEncs,
  ) async {
    final n = channelIds.length < channelKeyEncs.length
        ? channelIds.length
        : channelKeyEncs.length;
    for (var i = 0; i < n; i++) {
      await (db.update(db.channelRows)
            ..where((t) => t.channelId.equals(channelIds[i])))
          .write(ChannelRowsCompanion(channelKeyEnc: Value(channelKeyEncs[i])));
    }
  }

  /// 一次性把若干频道里的某些人从 broken 列表摘掉
  /// （例如自己刚重传完频道密钥，见 `E2eeController.reuploadMyChannelKeys`）。
  Future<void> clearChannelBrokenUsers(
    List<int> channelIds,
    List<int> userIds,
  ) async {
    for (final cid in channelIds) {
      await removeChannelBrokenUsers(cid, userIds);
    }
  }

  /// 用服务端权威结果覆盖成员 + broken 列表
  /// （`SYNO.Chat.Channel.Member / get` 的 `user_ids` / `broken_user_ids`）。
  Future<void> applyChannelMembers(
    int channelId, {
    List<int>? userIds,
    List<int>? brokenUserIds,
  }) async {
    if (channelId <= 0) return;
    await (db.update(
      db.channelRows,
    )..where((t) => t.channelId.equals(channelId))).write(
      ChannelRowsCompanion(
        members: userIds == null
            ? const Value.absent()
            : Value(_encodeIntList(userIds)),
        brokenUsers: brokenUserIds == null
            ? const Value.absent()
            : Value(_encodeIntList(brokenUserIds)),
      ),
    );
  }

  /// `channel.rescue`：某个成员被"救回来"了（原版 `deleteChannelBrokenUsers`）。
  Future<void> removeChannelBrokenUsers(
    int channelId,
    List<int> userIds,
  ) async {
    if (channelId <= 0 || userIds.isEmpty) return;
    final row = await (db.select(
      db.channelRows,
    )..where((t) => t.channelId.equals(channelId))).getSingleOrNull();
    if (row == null) return;
    final current = _decodeIntList(row.brokenUsers).toSet();
    final before = current.length;
    current.removeAll(userIds);
    if (current.length == before) return;
    await (db.update(
      db.channelRows,
    )..where((t) => t.channelId.equals(channelId))).write(
      ChannelRowsCompanion(
        brokenUsers: Value(_encodeIntList(current.toList()..sort())),
      ),
    );
  }

  /// 关闭 / 退出 / 归档后**删掉频道行**。
  ///
  /// 原版 `DatabaseHelper.closeChannel(id)` 只 `DELETE FROM ChatChannel`，
  /// 消息留在本地变成孤儿；我们顺手把消息也清了（`channel.archive` 事件原版
  /// 就是 `deleteChannelPosts`，语义一致），省得留下永远打不开的残留。
  Future<void> deleteChannel(int channelId) async {
    await db.transaction(() async {
      await (db.delete(
        db.channelRows,
      )..where((t) => t.channelId.equals(channelId))).go();
      await (db.delete(
        db.postRows,
      )..where((t) => t.channelId.equals(channelId))).go();
    });
  }

  /// 这个频道本地有多少条消息。
  ///
  /// 原版用 `ChannelFragment` 列表的 itemCount 当 `postCount`，只用来判
  /// "归档要求频道里至少有消息"；我们直接数本地行（离线也对）。
  Future<int> countPosts(int channelId) async {
    final row =
        await (db.selectOnly(db.postRows)
              ..addColumns([db.postRows.postId.count()])
              ..where(db.postRows.channelId.equals(channelId)))
            .getSingle();
    return row.read(db.postRows.postId.count()) ?? 0;
  }

  /// 管理员批量清空频道（`post.delete_batch` / `post.delete_search_list`
  /// 带 `channel_id_list`）：把本地这些频道的消息整批清掉。
  Future<int> purgeChannelPosts(int channelId) async {
    return (db.delete(
      db.postRows,
    )..where((t) => t.channelId.equals(channelId))).go();
  }

  /// 乐观发送落库：先插一条 `post_id = 0`、`state = 1`（发送中）的本地消息。
  /// 返回它的 `tmp_post_id`（调用方用它做后续替换/失败标记）。
  Future<int> insertPendingPost({
    required int channelId,
    required int creatorId,
    required String message,
    required int nowMillis,
    int tmpPostId = 0,
    int threadId = 0,
    String type = 'normal',
  }) async {
    var id = tmpPostId != 0 ? tmpPostId : nowMillis;
    // ⚠️ `dedupe_key` 有 UNIQUE 索引，而默认 temp id 就是毫秒时间戳 ——
    // 同一毫秒里发两条（同频道或不同频道）会直接撞索引抛 SqliteException，
    // 把"发消息"整个搞崩。这里自增到没被占用为止（原版用的是单调递增的
    // temp id，我们没那个计数器，就地兜住）。键里带上频道，避免跨频道撞。
    while (await _findPendingRow(channelId, id) != null) {
      id++;
    }
    await db
        .into(db.postRows)
        .insert(
          PostRowsCompanion.insert(
            channelId: channelId,
            postId: const Value(0),
            tmpPostId: Value(id),
            dedupeKey: 't:$channelId:$id',
            creatorId: Value(creatorId),
            message: Value(message),
            createAt: Value(nowMillis),
            threadId: Value(threadId),
            type: Value(type),
            state: const Value(1),
          ),
        );
    return id;
  }

  /// 发送成功：把本地待发行换成服务端真实消息（同一条行，不产生重复）。
  Future<void> confirmPendingPost({
    required int channelId,
    required int tmpPostId,
    required PostDto server,
  }) async {
    final row = await _findPendingRow(channelId, tmpPostId);
    // ★★ r326（D23）：确认时**不能**把待发行的 `dedupe_key` 原地改成服务端键。
    //   若确认之前已经有一次列表刷新（`upsertPosts` / `replaceChannelPosts`）
    //   把**同一条**服务端消息写进库，`post_rows.dedupe_key` 的 UNIQUE 索引
    //   会抛 `SqliteException(2067) UNIQUE constraint failed` ⇒ 被
    //   `sendMessage()` 的 catch 当成"发送失败"（`failPendingPost`）⇒
    //   **服务端明明已收到，界面却显示 `Send failed · Retry`**。
    //   真机/走查实测（r326 run 4 诊断串）：
    //   `[chat] 发消息失败 channel=1 tmp=1791541967418：SqliteException(2067)…
    //    UNIQUE constraint failed: post_rows.dedupe_key`
    //   —— 两条消息几乎同时到：`Post/create` 回执 与 进频道那次 `Post/list`。
    //   正解：**先删掉待发行、再按服务端那条 upsert**（幂等：已存在就地更新，
    //   不存在就插入），两种时序都不会撞索引、也不会留下重复行。
    if (row != null) {
      await (db.delete(db.postRows)..where((t) => t.id.equals(row.id))).go();
    }
    await upsertPosts([server]);
  }

  /// 发送失败：标记 state = 2（保留在列表里，UI 显示重发入口）。
  Future<void> failPendingPost(int channelId, int tmpPostId) async {
    final row = await _findPendingRow(channelId, tmpPostId);
    if (row == null) return;
    await (db.update(db.postRows)..where((t) => t.id.equals(row.id))).write(
      const PostRowsCompanion(state: Value(2)),
    );
  }

  /// 进频道时把**没发成功**的本地消息标成「已过期」（`state = 3`）。
  ///
  /// 逐行对位原版 `DatabaseHelper.updateAllOutdatedPosts(channelId)`：
  /// `state != 0`（不是服务端已确认的消息）的行一律写成 `state = 3`
  /// 并把 `create_at` 改成"现在"——原版语义是"这条早就该发出去了，现在只剩
  /// 重发/编辑/删除"，长按会弹 temp 操作面板（`ChannelAdapter` 里
  /// `state() == 2 || state() == 3` 走 `showTempOption`）。
  ///
  /// 调用点是 `ChannelFragment.enterChannel()`（`ChannelFragment.java:535`），
  /// 顺序在 `enterChannel` 之后、`queryDBPosts` 之前。
  Future<void> markOutdatedPosts(
    int channelId, {
    required int nowMillis,
    Set<int> excludeTmpIds = const {},
  }) async {
    // [excludeTmpIds]：**本进程正在发**的消息（state=1 且在飞行中）不能动。
    // 原版这一步发生在"刚进频道、还没有任何在途发送"的时刻，所以它敢写
    // `state != 0`；我们进频道和发消息可能并发（慢网下更明显），一刀切会把
    // "发送中"的转圈图标变成红色"失败"。
    var where =
        db.postRows.channelId.equals(channelId) &
        db.postRows.state.equals(0).not();
    if (excludeTmpIds.isNotEmpty) {
      where = where & db.postRows.tmpPostId.isNotIn(excludeTmpIds);
    }
    await (db.update(db.postRows)..where((t) => where)).write(
      PostRowsCompanion(state: const Value(3), createAt: Value(nowMillis)),
    );
  }

  /// 改一条**本地待发/失败**消息的正文（编辑后重发用；不动 `state`）。
  Future<void> updatePendingMessage(
    int channelId,
    int tmpPostId,
    String message,
  ) async {
    final row = await _findPendingRow(channelId, tmpPostId);
    if (row == null) return;
    await (db.update(db.postRows)..where((t) => t.id.equals(row.id))).write(
      PostRowsCompanion(message: Value(message)),
    );
  }

  /// 删掉一条**本地**待发/失败/过期消息。
  ///
  /// 对位原版 `deleteTemp`：只删本地行，**不打服务端**（服务端根本没有这条）。
  Future<void> deletePendingPost(int channelId, int tmpPostId) async {
    await (db.delete(db.postRows)..where(
          (t) =>
              t.channelId.equals(channelId) &
              t.tmpPostId.equals(tmpPostId) &
              t.postId.equals(0),
        ))
        .go();
  }

  Future<PostRow?> _findPendingRow(int channelId, int tmpPostId) {
    return (db.select(db.postRows)..where(
          (t) => t.channelId.equals(channelId) & t.tmpPostId.equals(tmpPostId),
        ))
        .getSingleOrNull();
  }

  Future<PostRow?> _findPostRow(PostDto post) async {
    if (post.postId > 0) {
      return (db.select(db.postRows)..where(
            (t) =>
                t.channelId.equals(post.channelId) &
                t.postId.equals(post.postId),
          ))
          .getSingleOrNull();
    }
    if (post.tmpPostId == 0) return null;
    return _findPendingRow(post.channelId, post.tmpPostId);
  }

  static List<PostDto> _sortedPosts(List<PostRow> rows, {int? limit}) {
    final out = rows.map(_postFromRow).toList()
      ..sort((a, b) => b.sortKey.compareTo(a.sortKey));
    if (limit != null && out.length > limit) return out.sublist(0, limit);
    return out;
  }

  // ------------------------------------------------------------ DTO ↔ Row

  static ChannelDto _channelFromRow(ChannelRow r) => ChannelDto(
    channelId: r.channelId,
    name: r.name,
    purpose: r.purpose,
    type: r.type,
    encrypted: r.encrypted,
    isJoined: r.isJoined,
    isStar: r.isStar,
    unread: r.unread,
    unreadMention: r.unreadMention,
    unreadComment: r.unreadComment,
    unreadMentionComment: r.unreadMentionComment,
    unreadThread: _decodeIntMap(r.unreadThread),
    subscribes: _decodeIntList(r.subscribes),
    members: _decodeIntList(r.members),
    brokenUsers: _decodeIntList(r.brokenUsers),
    channelKeyEnc: r.channelKeyEnc,
    totalMemberCount: r.totalMemberCount,
    creatorId: r.creatorId,
    lastPostAt: r.lastPostAt,
    lastViewAt: r.lastViewAt,
    lastViewCommentAt: r.lastViewCommentAt,
    channelOrderTime: r.channelOrderTime,
    hideGlobalAt: r.hideGlobalAt,
    lastHideAt: r.lastHideAt,
    notificationDesktop: r.notificationDesktop,
    notificationMobile: r.notificationMobile,
    notificationMute: r.notificationMute,
    hashtags: _decodeStringList(r.hashtags),
  );

  static UserDto _userFromRow(UserRow r) {
    final rawProps = _decodeMap(r.botProps);
    final bot = _botFields(rawProps);
    // ★ `user_props`（`timezoneUTC` / `avatar_color` / `is_always_offline` …）
    // 原来**没有任何列**存它 ⇒ DB 一趟回来 `timezoneUtc` 永远是空串
    // （免打扰页的时区、资料弹窗的时区因此都读不到）。这里挂在 `botProps`
    // 这个 JSON 列的保留键下，避免动 drift schema/迁移。
    final up = rawProps['user_props'];
    final userProps = up is Map
        ? Map<String, dynamic>.from(up)
        : const <String, dynamic>{};
    return UserDto(
      userId: r.userId,
      username: r.username,
      nickname: r.nickname,
      type: r.type,
      status: r.status,
      humanType: r.humanType,
      botType: r.botType,
      appId: r.appId,
      dsmUid: r.dsmUid,
      avatarVersion: r.avatarVersion,
      avatarColor: r.avatarColor,
      email: r.email,
      description: r.description,
      publicKey: r.publicKey,
      privateKeyEnc: r.privateKeyEnc,
      isDisabled: r.isDisabled,
      isDeleted: r.isDeleted,
      hasUrl: r.hasUrl,
      isAlwaysOffline: r.isAlwaysOffline,
      slashCmd: bot['slashCmd']! as String,
      slashDescription: bot['slashDescription']! as String,
      slashUrl: bot['slashUrl']! as String,
      slashUsage: bot['slashUsage']! as String,
      chatbotHideFromUser: bot['chatbotHideFromUser']! as bool,
      chatbotPurpose: bot['chatbotPurpose']! as String,
      chatbotWelcomeNote: bot['chatbotWelcomeNote']! as String,
      botIsSystem: bot['botIsSystem']! as bool,
      botStickerName: bot['botStickerName']! as String,
      userProps: userProps,
      createAt: r.createAt,
      updateAt: r.updateAt,
      deleteAt: r.deleteAt,
    );
  }

  /// 从 `botProps` JSON 还原 UserDto 的几个机器人字段
  static Map<String, Object?> _botFields(Map<String, dynamic> raw) {
    final slash = raw['slash_props'] is Map
        ? Map<String, dynamic>.from(raw['slash_props'] as Map)
        : const <String, dynamic>{};
    final chatbot = raw['chatbot_props'] is Map
        ? Map<String, dynamic>.from(raw['chatbot_props'] as Map)
        : const <String, dynamic>{};
    final bot = raw['bot_props'] is Map
        ? Map<String, dynamic>.from(raw['bot_props'] as Map)
        : const <String, dynamic>{};
    return {
      'slashCmd': '${slash['cmd'] ?? ''}',
      'slashDescription': '${slash['description'] ?? ''}',
      'slashUrl': '${slash['url'] ?? ''}',
      'slashUsage': '${slash['usage'] ?? ''}',
      'chatbotHideFromUser': chatbot['hide_from_user'] == true,
      'chatbotPurpose': '${chatbot['purpose'] ?? ''}',
      'chatbotWelcomeNote': '${chatbot['welcome_note'] ?? ''}',
      'botIsSystem': bot['is_system'] == true,
      'botStickerName': '${bot['sticker_name'] ?? ''}',
    };
  }

  static ChannelRowsCompanion _channelCompanion(ChannelDto c) =>
      ChannelRowsCompanion(
        channelId: Value(c.channelId),
        name: Value(c.name),
        purpose: Value(c.purpose),
        type: Value(c.type),
        encrypted: Value(c.encrypted),
        isJoined: Value(c.isJoined),
        isStar: Value(c.isStar),
        unread: Value(c.unread),
        unreadMention: Value(c.unreadMention),
        unreadComment: Value(c.unreadComment),
        unreadMentionComment: Value(c.unreadMentionComment),
        unreadThread: Value(_encodeIntMap(c.unreadThread)),
        subscribes: Value(_encodeIntList(c.subscribes)),
        members: Value(_encodeIntList(c.members)),
        brokenUsers: Value(_encodeIntList(c.brokenUsers)),
        channelKeyEnc: Value(c.channelKeyEnc),
        totalMemberCount: Value(c.totalMemberCount),
        creatorId: Value(c.creatorId),
        lastPostAt: Value(c.lastPostAt),
        lastViewAt: Value(c.lastViewAt),
        lastViewCommentAt: Value(c.lastViewCommentAt),
        channelOrderTime: Value(c.channelOrderTime),
        hideGlobalAt: Value(c.hideGlobalAt),
        lastHideAt: Value(c.lastHideAt),
        notificationDesktop: Value(c.notificationDesktop),
        notificationMobile: Value(c.notificationMobile),
        notificationMute: Value(c.notificationMute),
        hashtags: Value(jsonEncode(c.hashtags)),
      );

  static UserRowsCompanion _userCompanion(UserDto u) => UserRowsCompanion(
    userId: Value(u.userId),
    username: Value(u.username),
    nickname: Value(u.nickname),
    type: Value(u.type),
    status: Value(u.status),
    humanType: Value(u.humanType),
    botType: Value(u.botType),
    botProps: Value(
      jsonEncode({
        if (u.slashCmd.isNotEmpty)
          'slash_props': {
            'cmd': u.slashCmd,
            'description': u.slashDescription,
            'url': u.slashUrl,
            'usage': u.slashUsage,
          },
        if (u.chatbotPurpose.isNotEmpty ||
            u.chatbotWelcomeNote.isNotEmpty ||
            u.chatbotHideFromUser)
          'chatbot_props': {
            'hide_from_user': u.chatbotHideFromUser,
            'purpose': u.chatbotPurpose,
            'welcome_note': u.chatbotWelcomeNote,
          },
        'bot_props': {
          'is_system': u.botIsSystem,
          'sticker_name': u.botStickerName,
        },
        // 保留键：`user_props` 原文（见 `_userFromRow` 的说明）。
        if (u.userProps.isNotEmpty) 'user_props': u.userProps,
      }),
    ),
    appId: Value(u.appId),
    dsmUid: Value(u.dsmUid),
    avatarVersion: Value(u.avatarVersion),
    avatarColor: Value(u.avatarColor),
    email: Value(u.email),
    description: Value(u.description),
    publicKey: Value(u.publicKey),
    privateKeyEnc: Value(u.privateKeyEnc),
    isDisabled: Value(u.isDisabled),
    isDeleted: Value(u.isDeleted),
    hasUrl: Value(u.hasUrl),
    isAlwaysOffline: Value(u.isAlwaysOffline),
    createAt: Value(u.createAt),
    updateAt: Value(u.updateAt),
    deleteAt: Value(u.deleteAt),
  );

  /// 服务端消息用 post_id 去重；待发消息用 tmp_post_id（post_id 还是 0）
  /// 去重键（`dedupe_key` 是 UNIQUE 列）：服务端消息用全局唯一的 post_id，
  /// 本地待发消息用「频道 + temp id」——**必须带频道**，否则两个频道在同一
  /// 毫秒各发一条就会撞唯一索引（早期就踩过：不同频道同毫秒直接插不进去）。
  static String _dedupeKey(PostDto p) =>
      p.postId > 0 ? 'p:${p.postId}' : 't:${p.channelId}:${p.tmpPostId}';

  static PostDto _postFromRow(PostRow r) => PostDto(
    postId: r.postId,
    channelId: r.channelId,
    creatorId: r.creatorId,
    threadId: r.threadId,
    type: r.type,
    message: r.message,
    createAt: r.createAt,
    updateAt: r.updateAt,
    deleteAt: r.deleteAt,
    lastCommentAt: r.lastCommentAt,
    lastPinAt: r.lastPinAt,
    commentCount: r.commentCount,
    isStar: r.isStar,
    isSticky: r.isSticky,
    encrypted: r.encrypted,
    safeUrl: r.safeUrl,
    staticUrl: r.staticUrl,
    forwardType: r.forwardType,
    hashtags: _decodeStringList(r.hashtags),
    hashtagsAdditional: HashtagDto.parseList(
      _decodeJsonOrNull(r.hashtagsAdditional),
    ),
    mentions: _decodeIntList(r.mentions),
    reactions: _decodeMapList(r.reactions),
    urlProps: _decodeMapList(r.urlProps),
    fileProps: _decodeJsonOrNull(r.fileProps),
    systemProps: _decodeMapOrNull(r.systemProps),
    props: _decodeMap(r.props),
    tmpPostId: r.tmpPostId,
    state: r.state,
  );

  static PostRowsCompanion _postCompanion(PostDto p) => PostRowsCompanion(
    postId: Value(p.postId),
    channelId: Value(p.channelId),
    creatorId: Value(p.creatorId),
    threadId: Value(p.threadId),
    type: Value(p.type),
    message: Value(p.message),
    createAt: Value(p.createAt),
    updateAt: Value(p.updateAt),
    deleteAt: Value(p.deleteAt),
    lastCommentAt: Value(p.lastCommentAt),
    lastPinAt: Value(p.lastPinAt),
    commentCount: Value(p.commentCount),
    isStar: Value(p.isStar),
    isSticky: Value(p.isSticky),
    encrypted: Value(p.encrypted),
    safeUrl: Value(p.safeUrl),
    staticUrl: Value(p.staticUrl),
    forwardType: Value(p.forwardType),
    hashtags: Value(jsonEncode(p.hashtags)),
    hashtagsAdditional: Value(
      jsonEncode(
        p.hashtagsAdditional
            .map((h) => {'hashtag': h.hashtag, 'user_id': h.userId})
            .toList(),
      ),
    ),
    mentions: Value(jsonEncode(p.mentions)),
    reactions: Value(jsonEncode(p.reactions)),
    urlProps: Value(jsonEncode(p.urlProps)),
    fileProps: Value(p.fileProps == null ? '' : jsonEncode(p.fileProps)),
    systemProps: Value(p.systemProps == null ? '' : jsonEncode(p.systemProps)),
    props: Value(jsonEncode(p.props)),
    tmpPostId: Value(p.tmpPostId),
    state: Value(p.state),
    dedupeKey: Value(_dedupeKey(p)),
  );

  // ------------------------------------------------------------ JSON 列

  static String _encodeIntMap(Map<int, int> map) =>
      jsonEncode(map.map((k, v) => MapEntry('$k', v)));

  static Map<int, int> _decodeIntMap(String raw) {
    if (raw.isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    final out = <int, int>{};
    decoded.forEach((key, value) {
      final k = int.tryParse('$key');
      if (k == null) return;
      if (value is int) {
        out[k] = value;
      } else if (value is num) {
        out[k] = value.toInt();
      }
    });
    return out;
  }

  static String _encodeIntList(List<int> list) => jsonEncode(list);

  static List<String> _decodeStringList(String raw) {
    if (raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded.map((e) => '$e').toList();
  }

  static List<Map<String, dynamic>> _decodeMapList(String raw) {
    if (raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static Map<String, dynamic> _decodeMap(String raw) =>
      _decodeMapOrNull(raw) ?? const {};

  /// 解出任意 JSON（附件可能是数组 / 对象 / 字符串）
  static Object? _decodeJsonOrNull(String raw) {
    if (raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _decodeMapOrNull(String raw) {
    if (raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  static List<int> _decodeIntList(String raw) {
    if (raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <int>[];
    for (final value in decoded) {
      if (value is int) {
        out.add(value);
      } else if (value is num) {
        out.add(value.toInt());
      }
    }
    return out;
  }
}
