// Phase 5/9 真机验收：链接预览（OG）。
//
//   flutter test integration_test/phase5_link_preview_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 真机上验四件事：
//   ① 发一条带链接的消息 → 服务端**异步**抓 OG：`url_props` 一开始是 `[]`，
//      几秒后才有值（原版靠 `post.update` 广播拿到）
//   ② 8 个字段（title/description/image/favicon/image_prop/hidden/mime_type/url）
//      是不是真解析出来
//   ③ `SYNO.Chat.Post.File / og` 代理能不能真拿到图字节（PNG）
//   ④ 卡片真的能画出来（用真数据 + 真 api），并把服务端设置
//      `hide_post_url_preview` 的两种取值都走一遍
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/settings/server_settings.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/server_settings_dto.dart';
import 'package:synhub/src/data/dto/url_prop_dto.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/link_preview_card.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 5/9 真机：链接预览 OG', (tester) async {
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

    final settings = await chat.fetchServerSettings();
    debugPrint('[p5og] ① 服务端 hide_post_url_preview='
        '${settings.hidePostUrlPreview}');

    // 用一个自己的频道，别污染公共频道
    final channels = await chat.listChannels();
    final target = channels.firstWhere((c) => !c.encrypted);
    debugPrint('[p5og] 用频道 #${target.channelId} "${target.name}"');

    // 同时开一条真 socket：看服务端抓完 OG 之后到底**推不推** `post.update`
    // （还是只能靠自己刷新列表）—— 这决定卡片是"自动冒出来"还是"要刷新才出来"
    final session = conn.api.session;
    final socket = ChatSocket(
      baseUrl: conn.endpoint.baseUrl,
      sid: session?.sid ?? '',
      synotoken: session?.synotoken,
    );
    final seen = <String>[];
    Map<String, dynamic>? ogUpdate;
    final sub = socket.events.listen((e) {
      seen.add(e.event);
      if (e.event == 'post.update' || e.event == 'client.broadcast') {
        final map = e.asMap;
        final data = map?['data'];
        final payload = data is Map ? Map<String, dynamic>.from(data) : map;
        final type = payload?['type'];
        if (type == 'post.update' || e.event == 'post.update') {
          if (payload != null && payload['url_props'] is List &&
              (payload['url_props'] as List).isNotEmpty) {
            ogUpdate = payload;
          }
        }
      }
    });
    await socket.connect();
    debugPrint('[p5og] socket 状态=${socket.status}');

    // ---------- 发消息（服务端异步抓 OG，要等） ----------
    final marker = 'flt-p5og-${DateTime.now().millisecondsSinceEpoch % 1000000}';
    final linkUrl = 'https://www.synology.com/zh-cn/products/DS920+';
    final sent = await chat.createPost(
      channelId: target.channelId,
      message: '$marker $linkUrl',
      connId: '',
    );
    final sentPost = (sent['post'] ?? sent) as Map;
    final postId = (sentPost['post_id'] as num).toInt();
    debugPrint('[p5og] ② 发出 #$postId，url_props='
        '${jsonEncode(sentPost['url_props'])}（刚发出来时通常是空数组）');

    Map<String, dynamic>? raw;
    for (var i = 0; i < 20; i++) {
      final posts = await chat.listPosts(
          channelId: target.channelId, prevCount: 20);
      for (final p in posts) {
        if ((p['post_id'] as num).toInt() != postId) continue;
        final props = p['url_props'];
        if (props is List && props.isNotEmpty) raw = Map<String, dynamic>.from(props.first as Map);
      }
      if (raw != null) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    expect(raw, isNotNull, reason: '等了 60 秒服务端还没抓出 url_props');
    debugPrint('[p5og] ③ 服务端抓好了：${jsonEncode(raw)}');
    debugPrint('[p5og] ③ 期间收到的 socket 事件：${seen.toSet().toList()}');
    if (ogUpdate != null) {
      debugPrint('[p5og] ③a 服务端**推送**了带 url_props 的 post.update：'
          'channel_id=${ogUpdate!['channel_id']} post_id=${ogUpdate!['post_id']}');
    } else {
      debugPrint('[p5og] ③b 没收到带 url_props 的推送 → 预览只能靠列表刷新拿到');
    }
    await sub.cancel();
    socket.dispose();

    final prop = UrlPropDto.tryParse(raw);
    expect(prop, isNotNull);
    debugPrint('[p5og] ③ 解析：title="${prop!.title}" domain="${prop.domain}" '
        'image=${prop.imageWidth}×${prop.imageHeight} '
        'favicon=${prop.hasFavicon} desc=${prop.description.length} 字');
    expect(prop.url, linkUrl, reason: '服务端回带的 url 必须是我们发的那条');

    // ⚠️ 标题/配图取决于**这台 NAS 能不能访问外网**：2026-… 实测 KX 这台机器
    // 抓 synology.com 只回了骨架（title/image 都是空），`Post/list` 里
    // 有 url_props、url 正确，但内容是空的。这属于环境限制（同 `Post/list`
    // 的 has_url 抓取），不是客户端解析问题 —— 客户端解析在离线测试里断言。
    // 所以这里只做"抓到内容才校验内容"的软断言。
    if (prop.title.isEmpty) {
      debugPrint('[p5og] ③c NAS 没抓到标题/配图（外网受限），'
          '跳过内容断言，只验证 url 与解析不崩');
      return;
    }
    expect(prop.title, isNotEmpty);

    // ⚠️ 抓到的页面**不一定带 OG 配图**：2026-… 同一台 NAS 上 synology.com
    // 第一次抓回了 title/description/favicon 但 `image` 是空串（页面本身没有
    // og:image 或抓取时被裁了）。这是内容/环境差异，不是客户端解析问题 ——
    // 所以"有配图才校验配图"，没有就只验 favicon。
    if (prop.image.isEmpty) {
      debugPrint('[p5og] ③d 服务端抓到的页面没有 OG 配图（image 为空）→ 跳过配图断言');
    } else {
      expect(prop.imageWidth, greaterThan(0));

      // ---------- OG 代理取图 ----------
      final imgBytes = await chat.downloadOgImage(postId, prop.image);
      debugPrint('[p5og] ④ og(image) ✓ ${imgBytes.length} 字节 '
          '（PNG 头=${imgBytes.take(4).toList()}）');
      expect(imgBytes.length, greaterThan(1000), reason: 'OG 图应该是一张真图');
      final head = imgBytes.take(4).toList();
      final isPng =
          head[0] == 137 && head[1] == 80 && head[2] == 78 && head[3] == 71;
      final isJpeg = head[0] == 255 && head[1] == 216;
      debugPrint('[p5og] ④ 图片格式：${isPng ? 'PNG' : (isJpeg ? 'JPEG' : head)}');
      expect(isPng || isJpeg, isTrue,
          reason: '服务端代理回的应该是 PNG/JPEG 图片，实际头=$head');
    }
    if (prop.hasFavicon) {
      final favBytes = await chat.downloadOgImage(postId, prop.favicon);
      debugPrint('[p5og] ④ og(favicon) ✓ ${favBytes.length} 字节');
      expect(favBytes, isNotEmpty);
    }

    // ---------- 卡片渲染（真数据 + 真 api） ----------
    await container.read(chatStoreProvider).upsertPosts([
      PostDto.fromJson({
        'post_id': postId,
        'channel_id': target.channelId,
        'creator_id': 14,
        'message': '$marker $linkUrl',
        'create_at': DateTime.now().millisecondsSinceEpoch,
        'url_props': [raw],
      }),
    ]);
    await container.read(chatSessionControllerProvider.notifier).start(conn);
    container.read(serverSettingsProvider.notifier).apply(ServerSettings(
          hidePostUrlPreview: false,
        ));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: LinkPreviewCard(postId: postId, prop: prop, availableWidth: 320),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text(prop.title), findsOneWidget);
    expect(find.text(prop.domain), findsOneWidget);
    debugPrint('[p5og] ⑤ 卡片渲染 ✓（标题 + 域名 + OG 图）');

    // ---------- 服务端设置门控 ----------
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ChatPage(channelId: target.channelId)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final shownWhenAllowed =
        find.text(prop.title, skipOffstage: false).evaluate().isNotEmpty;
    debugPrint('[p5og] ⑥ 允许预览时聊天页有卡片：$shownWhenAllowed');

    container.read(serverSettingsProvider.notifier).apply(ServerSettings(
          hidePostUrlPreview: true,
        ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final shownWhenHidden =
        find.text(prop.title, skipOffstage: false).evaluate().isNotEmpty;
    debugPrint('[p5og] ⑥ hide_post_url_preview=true 时还有卡片：$shownWhenHidden '
        '（服务端本机设置=${settings.hidePostUrlPreview}）');
    expect(shownWhenHidden, isFalse, reason: '服务端要求隐藏时必须不画');
    if (!settings.hidePostUrlPreview) {
      expect(shownWhenAllowed, isTrue);
    }

    // ---------- ⑧ 端到端：走控制器（真 conn_id）发链接，靠 App 自己补刷 ----------
    container.read(serverSettingsProvider.notifier).apply(
        ServerSettings(hidePostUrlPreview: false));
    final marker2 =
        'flt-p5og-b-${DateTime.now().millisecondsSinceEpoch % 1000000}';
    final sentOk = await container
        .read(chatSessionControllerProvider.notifier)
        .sendMessage(target.channelId, '$marker2 $linkUrl');
    expect(sentOk, isTrue, reason: '控制器发消息应该成功');
    // 找到这条的 post_id
    var myPostId = 0;
    final after = await chat.listPosts(
        channelId: target.channelId, prevCount: 10);
    for (final p in after) {
      if ('${p['message']}'.startsWith(marker2)) {
        myPostId = (p['post_id'] as num).toInt();
      }
    }
    expect(myPostId, greaterThan(0));
    debugPrint('[p5og] ⑧ 控制器发出 #$myPostId，等 App 自己补刷（4s/12s 两次）…');

    // 控制器用的是**真实定时器**，widget 测试的假时钟推不动 → 用 runAsync 等
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 7)));
    final store = container.read(chatStoreProvider);
    var previewLanded = false;
    for (var i = 0; i < 10; i++) {
      final posts = await store.postsForChannel(target.channelId, limit: 20);
      for (final p in posts) {
        if (p.postId == myPostId && p.linkPreviews.isNotEmpty) {
          previewLanded = true;
          debugPrint('[p5og] ⑧ 自动补刷到了预览：title='
              '"${p.linkPreview?.title}"');
        }
      }
      if (previewLanded) break;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)));
    }
    debugPrint('[p5og] ⑧ 服务端不推广播，靠自动补刷拿到预览：$previewLanded');
    expect(previewLanded, isTrue,
        reason: '控制器应该在 4s/12s 后补拉列表，把 url_props 带回来');
    await chat.deletePost(myPostId);
    debugPrint('[p5og] ⑧ 已删除 #$myPostId');

    // ---------- 清理：删掉探针消息 ----------
    await chat.deletePost(postId);
    debugPrint('[p5og] ⑦ 已删除探针消息 #$postId');
    debugPrint('[p5og] 完成 ✓');
  });
}
