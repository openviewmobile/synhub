// Phase 9 真机验收：服务端设置（`SYNO.Chat.Admin.Setting`）→ 编辑权限一致性。
//
//   flutter test integration_test/phase9_server_settings_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 验证的是"我们算出来的可编辑性"和"服务端真的接受这次编辑"一致：
//   ① 拉真设置，逐字段核对 + 版本能力（v4 = 可编辑任意消息）；
//   ② 真发一条消息 → 我们的判定说"能编辑" → 真调 `Post/set` 改掉 →
//      服务端回读确认文本变了（证明判定不是自娱自乐）；
//   ③ 界面层：聊天页长按自己刚发的消息，操作面板里确实有「编辑」；
//   ④ 收尾删掉测试消息。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/settings/server_settings.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/post_editable.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ★ 真机 `integration_test` 的"常驻动效"陷阱（第 45 轮定位）：
  //   `FieldBackdrop` 在 `AppEffects.ambientAllowed` 为真时会
  //   `AnimationController.repeat()`（`lib/src/core/ui/field_backdrop.dart:104`），
  //   而 `ambientAllowed = Motion.enabled && !AppEffects.isFlutterTest`
  //   （`lib/src/core/theme/app_tokens.dart:109`）；`isFlutterTest` 只认
  //   `Platform.environment.containsKey('FLUTTER_TEST')`（`:99`）—— 这个环境变量
  //   **只有宿主 `flutter test` 才有，真机 App 进程里永远没有** ⇒ 生产路径的常驻
  //   动效照常在跑 ⇒ 含 `FieldBackdrop` 的页面（ChatPage / CertificatesPage …）上的
  //   `pumpAndSettle()` 永远等不到停帧：默认 10 分钟超时，整目标先被套件看门狗杀掉，
  //   日志里连一条 `Expected/Actual` 都看不到。
  //   这里按仓库既有约定（AGENTS §2.0.9「有常驻动画时 pumpAndSettle 不可用」）
  //   显式打开**用户可见的**「减少动效」开关把常驻动效停掉：
  //   不改产品行为、不放宽任何产品断言。
  AppEffects.reducedMotion.value = true;

  testWidgets('Phase 9 真机：服务端设置 + 编辑权限', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    // ---------- ① 真设置 ----------
    final s = await chat.fetchServerSettings();
    debugPrint('[p9s] ① 服务端设置：$s');
    debugPrint('[p9s] ① file_size_limit=${s.fileSizeLimitMb}MB '
        'edit=${s.allowEditMessage}(${s.editMessageTimeWithinMin}min) '
        'enc=${s.allowEncryption} read=${s.allowReadStatus} '
        'notify=${s.defaultNotificationType} guest=${s.allowGuest}');
    expect(chat.supports('SYNO.Chat.Admin.Setting', 4), isTrue,
        reason: '本机 NAS 的 API 表是 v1-5，应支持"可编辑任意消息"');
    // 这些值取真机实测，不做硬编码断言（管理员随时可能改），只打日志；
    // 但要保证：允许编辑时窗口是"不限"或正数
    expect(s.fileSizeLimitBytes >= 0, isTrue);
    if (s.editMessageTimeWithinMin > 0) {
      expect(s.editWindowMs, s.editMessageTimeWithinMin * 60000);
    }

    // 控制器登录后也应把设置拉进来
    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    await container.read(chatSessionControllerProvider.notifier).start(conn);
    for (var i = 0;
        i < 60 &&
            container.read(serverSettingsProvider).defaultNotificationType
                .isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)));
    }
    final applied = container.read(serverSettingsProvider);
    final sync = container.read(chatSessionControllerProvider);
    debugPrint('[p9s] ① 控制器已应用：$applied / 支持编辑任意消息='
        '${sync.supportsEditAllPost}');
    expect(applied.defaultNotificationType, s.defaultNotificationType,
        reason: '控制器与直接调用应拿到同一份设置');
    expect(sync.supportsEditAllPost, isTrue);

    final store = container.read(chatStoreProvider);
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    var channels = await store.allChannels();
    if (channels.isEmpty) {
      await ctrl.refresh();
      channels = await store.allChannels();
    }
    final target = channels.firstWhere(
      (c) => !c.encrypted && c.channelId > 0,
      orElse: () => channels.first,
    );
    debugPrint('[p9s] 目标频道 #${target.channelId} (${target.type})');

    // ---------- ② 真发一条 → 判定 → 真编辑 ----------
    final marker = 'flt-p9s-${DateTime.now().millisecondsSinceEpoch % 1000000}';
    final created = await chat.createPost(
      channelId: target.channelId,
      message: marker,
      connId: sync.connId!,
    );
    final postId = (created['post_id'] as num).toInt();
    debugPrint('[p9s] ② 发了 post=#$postId');
    // 刚发的消息还没进本地库（posts 是按频道页打开时拉的）——按服务端返回的
    // PostVo 落一条，跟实时通道收到事件后拉取的效果一致
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)));
    final remotePost =
        await chat.listPosts(channelId: target.channelId, prevCount: 20);
    final raw = remotePost
        .where((p) => (p['post_id'] as num?)?.toInt() == postId)
        .firstOrNull;
    expect(raw, isNotNull, reason: '服务端应当已经存下这条消息');
    await store.upsertPosts([PostDto.fromJson(Map<String, dynamic>.from(raw!))]);

    final posts =
        await store.postsForChannel(target.channelId, limit: 50);
    final mine = posts.where((p) => p.postId == postId).firstOrNull;
    expect(mine, isNotNull, reason: '刚发的消息应当已经在本地库');
    expect(mine!.creatorId, sync.myUserId);

    final channel = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    final editable = isPostEditable(
      mine,
      channel,
      myUserId: sync.myUserId,
      settings: applied,
      supportsEditAllPost: sync.supportsEditAllPost,
    );
    debugPrint('[p9s] ② 我们的判定：可编辑=$editable');
    expect(editable, isTrue, reason: '本机允许编辑且窗口不限');

    final edited = '$marker-edited';
    final ok = await ctrl.editMessage(target.channelId, postId, edited);
    debugPrint('[p9s] ② Post/set 成功=$ok');
    expect(ok, isTrue, reason: '判定说能改，服务端就该接受');

    // 回读确认（服务端侧真的改了）
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)));
    final fetched = await chat.listPosts(
        channelId: target.channelId, prevCount: 5);
    final remote = fetched
        .where((p) => (p['post_id'] as num?)?.toInt() == postId)
        .firstOrNull;
    expect(remote, isNotNull);
    debugPrint('[p9s] ② 服务端回读 message=${remote!['message']}');
    expect('${remote['message']}', edited, reason: '服务端上的正文要真的变了');

    // ---------- ③ 界面：长按有「编辑」 ----------
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ChatPage(channelId: target.channelId)),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 800)));
    await tester.pump(const Duration(milliseconds: 300));

    final bubble = find.text(edited);
    expect(bubble, findsWidgets, reason: '消息要显示出来');
    await tester.longPress(bubble.first);
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.text('编辑'), findsOneWidget,
        reason: '自己刚发的消息应当有编辑入口');
    expect(find.text('删除'), findsOneWidget);
    debugPrint('[p9s] ③ 长按面板有「编辑」 ✓');
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    // ---------- ④ 收尾 ----------
    try {
      await chat.deletePost(postId);
      debugPrint('[p9s] ④ 删掉测试消息 #$postId');
    } catch (e) {
      debugPrint('[p9s] ④ 删消息失败（忽略）：$e');
    }
    debugPrint('[p9s] 完成 ✓');
  });
}
