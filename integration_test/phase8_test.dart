// Phase 8 真机验收：前台常驻服务 + 本地通知 + 通知动作 + 通知体解密 + 自启开关。
//
//   flutter test integration_test/phase8_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 验收内容（都跑在真 NAS + 真 Android 上）：
//   ① 实时通道起来后前台服务真的在跑（原生 `isServiceRunning`）
//   ② 退到后台收到消息 → 原生通知条数 > 0，且**正文是解密后的明文**
//      （用一个**本地真能解密**的加密频道：优先取服务端已加入列表里
//      `keyState == ready` 的那个；`pm clear` 后一个都没有时，用例**自己现造**
//      一个加密频道并建立密钥，见文件末尾 `_provisionEncryptedChannel`。
//      消息事件用真实 `client.post.create` 载荷喂给同一条处理链——
//      这台 NAS 上只有我自己的账号，没法让别的账号真发一条）
//   ③ 通知动作「已读」→ 落库；「回复」→ 真的把消息发到服务端且是密文
//   ④ 开机自启开关能写进原生 SharedPreferences
//   ⑤ 收尾：清通知、删测试消息、恢复自启开关
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/data/remote/socket/socket_events.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/notifications/notification_service.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/settings/e2ee_controller.dart';
import 'package:synhub/src/native/background_service.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _passcode = 'flt-e2ee-pass';

String _marker(String kind) =>
    'flt-p8-$kind-${DateTime.now().millisecondsSinceEpoch}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 8 真机：常驻服务 + 通知 + 动作 + 解密', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    await container.read(chatSessionControllerProvider.notifier).start(conn);
    final sync = container.read(chatSessionControllerProvider);
    debugPrint('[p8] 我=#${sync.myUserId} 实时=${sync.realtime} conn=${sync.connId}');
    expect(sync.phase, ChatSyncPhase.ready);

    final ctrl = container.read(chatSessionControllerProvider.notifier);
    final bg = container.read(backgroundServiceProvider);
    final service = container.read(notificationServiceProvider);
    final svc = container.read(e2eeServiceProvider);

    // ---------- ① 前台常驻服务 ----------
    // 拉起是异步的（socket ready 之后 unawaited 起的），这里轮询等它起来
    debugPrint('[p8] isSupported=${bg.isSupported} '
        '直接 start()=${await bg.start(title: '验收', text: 'Phase 8')}');
    var running = false;
    for (var i = 0; i < 24 && !running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // ★★★ r349 订正：这两行引用的 `ChatSessionController.refreshForegroundServiceFlag()`
      //   与 `ChatSyncState.foregroundService` **在 lib/ 里都已不存在**
      //   （`grep -rn 'refreshForegroundServiceFlag' lib/` → 0 命中；
      //     `ChatSyncState`（`chat_session_controller.dart:177`）已无该字段）
      //   ⇒ 本文件**编不过、根本跑不了**，从 Sep 26 起就是死件。
      //   现代读法（`notification_service.dart:58` 自述是**唯一来源**）：
      //   失效并重读 `foregroundServiceRunningProvider`。
      container.invalidate(foregroundServiceRunningProvider);
      running = await container.read(foregroundServiceRunningProvider.future);
    }
    debugPrint('[p8] 前台服务 running=$running（原生 isServiceRunning=${await bg.isRunning()}）');
    expect(running, isTrue, reason: '实时通道起来后前台服务要在跑');

    // ---------- ② 通知体解密 ----------
    await container.read(e2eeControllerProvider.notifier).load();
    final unlocked =
        await container.read(e2eeControllerProvider.notifier).unlock(_passcode);
    expect(unlocked, isTrue, reason: '要用 $_passcode 解锁 E2EE 私钥');

    final store = container.read(chatStoreProvider);

    // ★ 第 52 轮加固：不许再"闭眼取第一个加密频道"。
    //   `ChannelKeyState.missing` = "已解锁、但本地拿不到这个频道的密钥"
    //   （`e2ee_service.dart:265-270`：`ready` 只看 `_channelKeys` 里有没有；
    //    否则 `isUnlocked ? missing : locked`）。它是**产品明确建模的合法状态** ——
    //   `e2ee_page.dart:191` 的「密钥缺失」、`e2ee_controller.dart:444` 专门筛
    //   `encrypted && missing` 的列表、还有 `renew_key` 重封流程在管它。
    //   密钥唯一来源是按成员封的 `channel_key_enc`（`loadChannelKey`，
    //   `e2ee_service.dart:275-279` 空则不装载）⇒ 本账号对这个频道**没有副本**时，
    //   `missing` 就是**正确答案**，不是缺陷。
    //   而下面这段验的是"**通知体解密**"，必须用一个**本地真能解密**的频道：
    //   判据① `keyState == ready`；判据② 它**此刻仍在服务端的已加入列表**里
    //   （否则会挑中"上一轮退出了、但本地 E2EE 行按政策被保留下来"的频道 ——
    //    那种频道发消息会被服务端拒，是个真会踩到的坑）。
    final joinedNow = await chat.listChannels();
    final ready = joinedNow
        .where((c) => c.encrypted && svc.keyState(c) == ChannelKeyState.ready)
        .toList();
    var picked = ready.isEmpty ? null : ready.first;

    // 干净数据下的兜底（`pm clear` 之后本地一行都没有 ⇒ 全部 missing）：
    // 按既有配方**现造**一个加密频道并建立密钥（见文件末尾
    // `_provisionEncryptedChannel`，配方取自真机验证过的
    // `tool/probe_make_e2ee_channel.dart:66-97`），结束时退出该频道。
    var provisionedId = 0;
    if (picked == null) {
      provisionedId = await _provisionEncryptedChannel(
        chat: chat,
        svc: svc,
        myPublicKey: container.read(e2eeControllerProvider).publicKey,
      );
      expect(provisionedId, greaterThan(0),
          reason: '干净数据下必须能现造一个加密频道（否则这条验收无从谈起）');
      await ctrl.refresh();
      for (final c in await chat.listChannels()) {
        if (c.channelId == provisionedId) {
          picked = c;
          break;
        }
      }
    }
    expect(picked, isNotNull,
        reason: 'Phase 8 的通知体解密验收需要一个"本地能解密"的加密频道'
            '（本轮现造的 #$provisionedId 也必须出现在服务端已加入列表里）');
    final target = picked!;
    debugPrint('[p8] 用加密频道 #${target.channelId} '
        '密钥状态=${svc.keyState(target)}（本轮现造=$provisionedId）');
    // 断言**不放宽**：选中它的前提就是它必须真能解密
    expect(svc.keyState(target), ChannelKeyState.ready);

    // 通知：前台不弹，退到后台才弹
    service.appInForeground = true;
    final wouldNotify = await service.maybeNotify(
      PostDto.fromJson({
        'post_id': 8000001,
        'channel_id': target.channelId,
        'creator_id': 4,
        'create_at': DateTime.now().millisecondsSinceEpoch,
        'type': 'normal',
        'message': svc.encryptMessage(target.channelId, 'x'),
      }),
      channel: target,
    );
    expect(wouldNotify, isFalse, reason: '前台不该弹通知');

    // 真实事件链：先落一条"别人发的"密文消息，再喂真实 socket 载荷
    final text = _marker('通知');
    final postId = 4294967901;
    await store.upsertPosts([
      PostDto.fromJson({
        'post_id': postId,
        'channel_id': target.channelId,
        'creator_id': 4,
        'create_at': DateTime.now().millisecondsSinceEpoch,
        'type': 'normal',
        'message': svc.encryptMessage(target.channelId, text),
        'props': {'encrypted': true},
      }),
    ]);
    // 先直接走原生通道弹一条，区分「原生弹不出来」还是「服务层过滤掉了」
    final direct = await bg.show(MessageNotification(
      channelId: target.channelId,
      postId: 999999,
      title: '直连测试',
      text: 'native probe',
    ));
    debugPrint('[p8] 直接 bg.show()=$direct，条数=${await bg.activeCount()}');

    service.appInForeground = false; // 模拟退到后台（真机上就是 Home 键那一下）
    await ctrl.handleEvent(ChatSocketEvent(
        SocketEvent.clientPostCreate,
        phase8FakePostCreateEvent(target.channelId, postId)));

    final active = await bg.activeCount();
    debugPrint('[p8] 原生通知条数=$active（正文应为解密后的「$text」）');
    expect(active, greaterThan(0), reason: '后台收到消息要弹原生通知');
    final shown = service.notifiedCount;
    debugPrint('[p8] Dart 侧已记录提醒 $shown 条');

    // 通知内容（原生那边画的就是这些字段）
    final e2ee = container.read(e2eeControllerProvider.notifier);
    expect(e2ee.displayMessage(target, svc.encryptMessage(target.channelId, text)),
        text);

    // ---------- ③ 通知动作 ----------
    // 已读：真的打服务端 `Channel/view` 并落库
    await ctrl.handleNotificationAction(NotificationAction(
      action: NotificationAction.markRead,
      channelId: target.channelId,
      postId: postId,
    ));
    final afterRead = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    debugPrint('[p8] 已读后 last_view_at=${afterRead.lastViewAt}');
    expect(afterRead.lastViewAt, greaterThan(0));

    // 回复：真的发到服务端（加密频道 → 密文），读回来解出原文。
    // ⚠️ 这一步**一定会**在 NAS 上写一条（不再是可选的 `SYNO_LIVE_POST` 开关），
    //    ⑤ 收尾会把它删掉 —— 别让它跨轮次留在服务端。
    final reply = _marker('回复');
    await ctrl.handleNotificationAction(NotificationAction(
      action: NotificationAction.reply,
      channelId: target.channelId,
      postId: postId,
      text: reply,
    ));
    final posts = await chat.listPosts(
        channelId: target.channelId, prevCount: 10, has: const ['thread']);
    var replyOk = false;
    int? replyPostId;
    for (final p in posts) {
      final message = '${p['message'] ?? ''}';
      if (p['creator_id'] == 14 &&
          svc.tryDecryptMessage(target.channelId, message) == reply) {
        replyOk = true;
        replyPostId = (p['post_id'] as num?)?.toInt();
      }
    }
    expect(replyOk, isTrue, reason: '通知里回复的内容要真的发到服务端（密文）');
    debugPrint('[p8] 通知回复已送达 #$replyPostId（密文）');

    // ---------- ④ 开机自启开关 ----------
    final before = await bg.getAutostart();
    expect(await bg.setAutostart(boot: true, foreground: false), isTrue);
    final saved = await bg.getAutostart();
    expect(saved.boot, isTrue);
    await bg.setAutostart(boot: before.boot, foreground: before.foreground);
    debugPrint('[p8] 自启开关可写：${saved.boot}（已恢复成 ${before.boot}）');

    // ---------- ⑤ 收尾 ----------
    await bg.cancelAll();
    // ③ 的回复是**无条件**发到服务端的（不看 `_doPost`），所以这里也**无条件**删 ——
    // 原来那句 `if (_doPost && ...)` 会让套件每跑一轮就在 NAS 上留一条密文回复，
    // 正是本轮要治的"跨轮次状态漂移"。
    if (replyPostId != null) {
      try {
        await chat.deletePost(replyPostId);
        debugPrint('[p8] 已删回复 #$replyPostId');
      } catch (e) {
        debugPrint('[p8] 删回复失败：$e');
      }
    }
    // 自造的加密频道：服务端对 Named 频道**没有** delete/close（`chat_api.dart:568`），
    // 能做的清理就是退出（它不再出现在"已加入"列表里 ⇒ 下一轮不会被挑中）。
    if (provisionedId > 0) {
      try {
        await chat.disjoinNamedChannel(provisionedId);
        debugPrint('[p8] 已退出自造加密频道 #$provisionedId');
      } catch (e) {
        debugPrint('[p8] 退出自造频道失败：$e');
      }
    }
    debugPrint('[p8] 清理完成 ✓');
  });
}

/// 真实 `client.post.create` 载荷形状（Phase 3 实测）
Map<String, Object?> phase8FakePostCreateEvent(int channelId, int postId) => {
      'channel_id': channelId,
      'user_id': 4,
      'data': {
        'post_id': postId,
        'channel_id': channelId,
        'creator_id': 4,
        'create_at': DateTime.now().millisecondsSinceEpoch,
        'type': 'normal',
        'message': '',
      },
    };

/// 干净数据（`pm clear`）下的兜底：**现造**一个"本地有密钥"的加密频道。
///
/// 配方逐字照 `tool/probe_make_e2ee_channel.dart:66-97`（真机验证过的那条）：
///   1. 生成 32 字节频道密钥；
///   2. `SYNO.Chat.Channel.Named / create`（`encrypted=true`）→ channel_id；
///   3. `svc.putChannelKey(id, key)` —— 本地内存持有（`e2ee_service.dart:310`）；
///   4. `SYNO.Chat.Channel.Named / join` 带上
///      `svc.sealChannelKey(id, 我自己的公钥)` —— 服务端从此存着封给我的副本，
///      下次同步 `loadChannelKey` 能把它解回来（`e2ee_service.dart:278`）。
///
/// 返回新频道 id（<=0 = 失败）。清理见用例 ⑤。
Future<int> _provisionEncryptedChannel({
  required ChatApi chat,
  required E2eeService svc,
  required String myPublicKey,
}) async {
  final id = await chat.createNamedChannel(
    name: _marker('e2ee-ch'),
    purpose: 'Phase 8 通知体解密验收（用例自造，跑完退出）',
    encrypted: true,
  );
  if (id <= 0) return 0;
  final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
  svc.putChannelKey(id, key);
  await chat.joinNamedChannel(
    id,
    channelKeyEnc: svc.sealChannelKey(id, myPublicKey),
  );
  return id;
}
