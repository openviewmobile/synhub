// Phase 5 真机验收：贴纸（`SYNO.Chat.Sticker`）。
//
//   flutter test integration_test/phase5_sticker_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 验收点：
//   ① `list` v1 拿得到分类目录（真机这台：3 个非 emoji 分类）
//   ② 图片直链 `{base}sc/stickers/{id}/{size}`：**靠 cookie** 能拿到真图片；
//      挂 `_sid` 会回 HTML（回归点，别把 `_sid` 加回去）
//   ③ 发一条 `type=sticker` + `message=":name:"` 的消息，服务端原样存下
//   ④ 消息在频道正文里画成 150dp 的图（不显示短代码）
//   ⑤ 清场：删掉探针消息
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/sticker_catalog.dart';
import 'package:synhub/src/features/chat/sticker_view.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 5 真机：贴纸目录 / 图片 / 发贴纸消息', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');
    clearStickerCache();

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    // ---------- ① 目录 ----------
    expect(chat.supportsStickers, isTrue, reason: '真机有 SYNO.Chat.Sticker');
    final catalog = await chat.fetchStickers();
    debugPrint('[p5st] ① 分类 ${catalog.categories.length} 个：'
        '${catalog.categories.map((c) => '${c.name}(emoji=${c.isEmoji},'
            '${c.stickers.length})').join(' / ')}');
    expect(catalog.isEmpty, isFalse);
    final sticker = catalog.stickerCategories.first.stickers.first;
    debugPrint('[p5st] ① 取第一张贴纸 ${sticker.name} (id=${sticker.stickerId})');

    // ---------- ② 图片直链 ----------
    final withCookie = await conn.api.getBytes(chat.stickerImageUrl(
      sticker.stickerId,
      size: '2x',
    ));
    final magic = withCookie.take(4).map((b) => b.toRadixString(16)).join(' ');
    debugPrint('[p5st] ② cookie 直链 → ${withCookie.length} 字节 magic=$magic');
    expect(magic, anyOf('89 50 4e 47', 'ff d8 ff e0', 'ff d8 ff e1'),
        reason: '应该拿到真图片（PNG/JPEG），不是 HTML');

    // ★ 第 43 轮：真机现在对"带 `_sid` 的贴纸直链"直接回 **404**（以前回 HTML）。
    //   两者都只是"拿不到真图片"，而这正是本条要守的不变量 —— 所以**不能把历史
    //   结果写死**（原来写死"一定有字节"，真机一改成 404 就抛 DsmTransportException
    //   把整条用例打红，看着像功能坏了）。
    Object? sidErr;
    List<int>? sidBytes;
    try {
      sidBytes = await conn.api.getBytes(conn.api.authenticatedUrl(
        '/sc/stickers/${sticker.stickerId}/2x',
        const {},
      ));
    } catch (e) {
      sidErr = e;
    }
    if (sidErr != null) {
      debugPrint('[p5st] ②（回归）挂 _sid → 抛错 ${sidErr.runtimeType}'
          '（拿不到真图片 ✓，别再给贴纸 URL 加 _sid）');
    } else {
      final sidMagic =
          sidBytes!.take(4).map((b) => b.toRadixString(16)).join(' ');
      debugPrint('[p5st] ②（回归）挂 _sid → ${sidBytes.length} 字节 '
          'magic=$sidMagic（不是图片就是预期行为）');
      expect(
        sidMagic,
        isNot(anyOf('89 50 4e 47', 'ff d8 ff e0', 'ff d8 ff e1')),
        reason: '挂 _sid 绝不该拿到真图片 —— 那是错的用法',
      );
    }

    // 走我们自己的下载方法（内存缓存那条路）
    final bytes = await loadStickerBytes(chat, sticker.stickerId);
    expect(bytes.length, withCookie.length);

    // ---------- ③ 发贴纸消息 ----------
    final channels = await chat.listChannels();
    final target = channels.firstWhere((c) => !c.encrypted);
    final cid = target.channelId;
    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });

    await container.read(chatSessionControllerProvider.notifier).start(conn);
    // 让贴纸目录 provider 就绪（真机上也是聊天页打开时加载）
    final providerCatalog =
        await container.read(stickerCatalogProvider.future);
    debugPrint('[p5st] ③ provider 目录：'
        '${providerCatalog?.categories.length ?? 0} 个分类');

    final ok = await container
        .read(chatSessionControllerProvider.notifier)
        .sendSticker(cid, sticker.name);
    expect(ok, isTrue, reason: '贴纸消息应该发出去');
    await Future<void>.delayed(const Duration(seconds: 2));

    // 从服务端回读（确认 type/message 原样）。
    // 注意：`has` 过滤器只有 thread|reaction|pin|url|file|star|vote 七种，
    // **没有 sticker**（原版 `QueryAdapter` 的 switch 就这些），所以这里直接拉列表找。
    Map<String, dynamic>? hit;
    for (var i = 0; i < 6 && hit == null; i++) {
      final posts = await chat.listPosts(channelId: cid, prevCount: 30);
      for (final p in posts) {
        if (p['type'] == 'sticker' && p['message'] == ':${sticker.name}:') {
          hit = Map<String, dynamic>.from(p);
        }
      }
      if (hit == null) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    debugPrint('[p5st] ③ 服务端回读：${hit == null ? "没找到" : "post_id=${hit['post_id']} "
        "type=${hit['type']} message=${hit['message']}"}');
    expect(hit, isNotNull, reason: '服务端应该存下 type=sticker + :name:');
    final postId = (hit!['post_id'] as num).toInt();

    // ---------- ④ 界面：贴纸消息画成图 ----------
    final store = container.read(chatStoreProvider);
    final posts = await store.postsForChannel(cid, limit: 50);
    final mine = posts.where((p) => p.postId == postId).toList();
    debugPrint('[p5st] ④ 本地库里那条：type=${mine.isEmpty ? "?" : mine.first.type}');

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: StickerView(name: ':${sticker.name}:'),
          ),
        ),
      ),
    ));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      if (find.byType(Image).evaluate().isNotEmpty) break;
    }
    expect(find.byType(Image), findsWidgets, reason: '贴纸名能在真目录里查到并画出图');
    final img = tester.widget<Image>(find.byType(Image).first);
    debugPrint('[p5st] ④ 渲染 ${img.width}×${img.height}（原版 150dp）');
    expect(img.width, kStickerEdge);

    // 顺带验一次真正的聊天页（消息列表里那条）
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ChatPage(channelId: cid)),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      if (find.text(':${sticker.name}:').evaluate().isEmpty &&
          find.byType(Image).evaluate().isNotEmpty) {
        break;
      }
    }
    debugPrint('[p5st] ④ 聊天页里短代码文本已隐藏：'
        '${find.text(':${sticker.name}:').evaluate().isEmpty}');

    // ---------- ⑤ 清场 ----------
    try {
      await chat.deletePost(postId);
      debugPrint('[p5st] ⑤ 已删除 #$postId');
    } catch (e) {
      debugPrint('[p5st] ⑤ 删除 #$postId 失败：$e');
    }
    debugPrint('[p5st] 完成 ✓');
    if (Platform.isAndroid) {
      // 避免集成测试退出码受 pending timer 影响
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  });
}
