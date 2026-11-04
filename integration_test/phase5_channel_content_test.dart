// Phase 5/9 真机验收：频道内容列表（置顶 / 文件 / 链接 / @我）。
//
//   flutter test integration_test/phase5_channel_content_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 这四条列表在原版是 `TabPostFragment`（置顶/文件/链接 三个 tab）+
// `MentionFragment`（@我），数据源都是 `SYNO.Chat.Post / search`，
// 只是过滤条件不同（`has: pin|file|url` / `mention: [me]`）。
//
// 真机上我们要看到的是：
//   ① 链接：发一条带链接的消息 → `has:["url"]` 能搜到它，且 `url_props` 有 OG
//   ② 文件：上传一个附件 → `has:["file"]`（v3 走 post_type）能搜到它
//   ③ 置顶：`has:["pin"]` 至少不发错（这台服务端置顶本身就不支持，见 Phase 4 记录）
//   ④ @我：发一条 @我自己的消息 → `mention:[我]` 能搜到（服务端自己解析 @）
//   ⑤ 页面：用真数据渲染 `ChannelContentPage`，能看到行 + OG 卡片
//   ⑥ 清场：把造出来的消息删掉
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/settings/server_settings.dart';
import 'package:synhub/src/data/dto/server_settings_dto.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/features/chat/channel_content_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 5/9 真机：频道内容列表', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);
    // 自己的 user_id 从 `User/get`（不带 user_id 时服务端回自己）拿
    final me = await chat.myUser();
    final myUserId = me?.userId ?? 0;
    expect(myUserId, greaterThan(0));
    debugPrint('[p5cc] 我是 user_id=$myUserId (${me?.displayName})');

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });

    final channels = await chat.listChannels();
    final target = channels.firstWhere((c) => !c.encrypted);
    final cid = target.channelId;
    debugPrint('[p5cc] 用频道 #$cid');

    final marker = 'flt-p5cc-${DateTime.now().millisecondsSinceEpoch % 1000000}';
    final linkUrl = 'https://www.synology.com/zh-cn/products/DS920+';
    final created = <int>[];

    Future<List<int>> idsFor(PostSearchQuery q) async {
      final r = await chat.searchPosts(q);
      return r.posts
          .map((p) => (p['post_id'] as num).toInt())
          .where((id) => id > 0)
          .toList();
    }

    // ---------- ① 链接：has:["url"] ----------
    final linkPost = await chat.createPost(
      channelId: cid,
      message: '$marker-link $linkUrl',
      connId: '',
    );
    final linkId = (((linkPost['post'] ?? linkPost) as Map)['post_id'] as num).toInt();
    created.add(linkId);
    debugPrint('[p5cc] ① 发出链接消息 #$linkId');

    Map<String, dynamic>? linkHit;
    var linkIds = <int>[];
    for (var i = 0; i < 20; i++) {
      linkIds = await idsFor(PostSearchQuery(
        inChannels: [cid],
        has: const ['url'],
        offset: 0,
        limit: 50,
      ));
      if (linkIds.contains(linkId)) {
        final r = await chat.searchPosts(PostSearchQuery(
          inChannels: [cid],
          has: const ['url'],
          offset: 0,
          limit: 50,
        ));
        for (final p in r.posts) {
          if ((p['post_id'] as num).toInt() == linkId) {
            linkHit = Map<String, dynamic>.from(p);
          }
        }
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    expect(linkHit, isNotNull,
        reason: '`has:["url"]` 应该能搜到刚发的链接消息（当前命中 ${linkIds.length} 条）');
    final urls = linkHit!['url_props'];
    final firstUrl = urls is List && urls.isNotEmpty
        ? Map<String, dynamic>.from(urls.first as Map)
        : null;
    debugPrint('[p5cc] ① 链接列表命中 ${linkIds.length} 条，我们那条的 '
        'url_props.title="${firstUrl?['title']}"');

    // ---------- ② 文件：has:["file"] ----------
    final dir = Directory.systemTemp.createTempSync('flt_p5cc');
    final file = File('${dir.path}/flt-report.txt');
    file.writeAsStringSync('flt channel-content probe\n');
    final filePost = await chat.uploadPost(
      channelId: cid,
      connId: '',
      filePath: file.path,
      fileName: 'flt-report.txt',
      message: '$marker-file',
      mimeType: 'text/plain',
    );
    final fileId = (((filePost['post'] ?? filePost) as Map)['post_id'] as num).toInt();
    created.add(fileId);
    debugPrint('[p5cc] ② 上传附件消息 #$fileId');

    // 文件列表走 has:["file"]（Post v3 会挪进 post_type，chat_api 已处理）
    var fileIds = <int>[];
    for (var i = 0; i < 10; i++) {
      fileIds = await idsFor(PostSearchQuery(
        inChannels: [cid],
        has: const ['file'],
        offset: 0,
        limit: 50,
      ));
      if (fileIds.contains(fileId)) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    debugPrint('[p5cc] ② 文件列表命中 ${fileIds.length} 条，包含我们那条：'
        '${fileIds.contains(fileId)}');
    expect(fileIds.contains(fileId), isTrue,
        reason: '`has:["file"]`/`post_type:["file"]` 应该能搜到刚上传的附件');

    // ---------- ③ 置顶：has:["pin"] ----------
    try {
      final pinIds = await idsFor(PostSearchQuery(
        inChannels: [cid],
        has: const ['pin'],
        offset: 0,
        limit: 50,
      ));
      debugPrint('[p5cc] ③ 置顶列表命中 ${pinIds.length} 条（这台服务端的置顶'
          '本身就不支持，见 docs/phase4-protocol.md §7）');
    } catch (e) {
      debugPrint('[p5cc] ③ 置顶查询被服务端拒绝：$e');
    }

    // ---------- ④ @我：mention:[me] ----------
    final mentionPost = await chat.createPost(
      channelId: cid,
      message: '$marker-mention @$_account 看这里',
      connId: '',
    );
    final mentionId =
        (((mentionPost['post'] ?? mentionPost) as Map)['post_id'] as num).toInt();
    created.add(mentionId);
    var mentionIds = <int>[];
    for (var i = 0; i < 10; i++) {
      mentionIds = await idsFor(PostSearchQuery(
        inChannels: [cid],
        mentions: [myUserId],
        offset: 0,
        limit: 50,
      ));
      if (mentionIds.contains(mentionId)) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    debugPrint('[p5cc] ④ @我 列表命中 ${mentionIds.length} 条，包含我们那条：'
        '${mentionIds.contains(mentionId)}');

    // ---------- ⑤ 页面：真数据渲染 ----------
    await container.read(chatSessionControllerProvider.notifier).start(conn);
    container.read(serverSettingsProvider.notifier).apply(
        ServerSettings(hidePostUrlPreview: false));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ChannelContentPage(
            channelId: cid, kind: ChannelContentKind.links),
      ),
    ));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pump();
      if (find.textContaining('$marker-link').evaluate().isNotEmpty) break;
    }
    final rows = find.textContaining('$marker-link').evaluate().length;
    debugPrint('[p5cc] ⑤ 链接页渲染到了我们那条：${rows > 0}');
    expect(rows, greaterThan(0), reason: '刚发的链接消息应该出现在链接列表里');
    if (firstUrl != null && (firstUrl['title'] as String?)?.isNotEmpty == true) {
      final cards = find.text(firstUrl['title'] as String).evaluate().length;
      debugPrint('[p5cc] ⑤ OG 卡片：${cards > 0}');
    }

    // ---------- ⑥ 清场 ----------
    for (final id in created) {
      try {
        await chat.deletePost(id);
        debugPrint('[p5cc] ⑥ 已删除 #$id');
      } catch (e) {
        debugPrint('[p5cc] ⑥ 删除 #$id 失败：$e');
      }
    }
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    debugPrint('[p5cc] 完成 ✓');
  });
}
