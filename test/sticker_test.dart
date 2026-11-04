// Phase 5 贴纸 / emoji（`SYNO.Chat.Sticker`）离线用例。
//
// 反编译对照（Android-SynologyChat 2.11.1）：
//   * `AccountManager.fetchStickers()` → `list` **v1**，
//     返回 `{categories:[{category_id,is_emoji,name,stickers:[{sticker_id,name,keywords,support_skin}]}]}`
//   * 图片 `GET {base}sc/stickers/{id}/{size}`，size ∈ 1x|2x|4x；**不带 `_sid`**
//   * 贴纸消息 = `Post/create` 的 `type=sticker` + `message=":<name>:"`
//   * emoji 分类点一下是**插进输入框**，不是发消息
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/sticker_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/rich_text.dart';
import 'package:synhub/src/features/chat/sticker_catalog.dart';
import 'package:synhub/src/features/chat/sticker_view.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 真机形状：3 个非 emoji 分类
Map<String, dynamic> stickerListResponse() => {
  'categories': [
    {
      'category_id': 9,
      'name': 'business_man',
      'is_emoji': false,
      'stickers': [
        {
          'sticker_id': 81,
          'name': 'business_man_01',
          'keywords': [],
          'support_skin': false,
        },
        {
          'sticker_id': 82,
          'name': 'business_man_02',
          'keywords': [],
          'support_skin': false,
        },
      ],
    },
    {
      'category_id': 20,
      'name': 'emoji',
      'is_emoji': true,
      'stickers': [
        {
          'sticker_id': 501,
          'name': 'thumbsup',
          'keywords': [],
          'support_skin': true,
        },
        {
          'sticker_id': 502,
          'name': 'dog',
          'keywords': [],
          'support_skin': false,
        },
      ],
    },
    {
      'category_id': 11,
      'name': 'dog',
      'is_emoji': false,
      'stickers': [
        {
          'sticker_id': 123,
          'name': 'dog_01',
          'keywords': ['puppy'],
        },
      ],
    },
  ],
};

/// 一张 1×1 PNG（服务端回什么不重要，只要能被 `Image.memory` 解出来）
final kPngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

void main() {
  setUp(clearStickerCache);
  tearDown(clearStickerCache);

  group('目录解析', () {
    test('真机形状：分类 / 贴纸 / 关键词 / support_skin', () {
      final c = StickerCatalog.parse(stickerListResponse());
      expect(c.categories, hasLength(3));
      expect(c.stickerCategories.map((e) => e.name), ['business_man', 'dog']);
      expect(c.emojiCategories.map((e) => e.name), ['emoji']);
      expect(c.idOf('dog_01'), 123);
      expect(c.idOf('business_man_02'), 82);
      expect(c.idOf('nope'), isNull);
      expect(c.isEmpty, isFalse);
    });

    test('缺字段 / 空目录都安全', () {
      expect(StickerCatalog.parse(const {}).categories, isEmpty);
      expect(StickerCatalog.parse(const {}).isEmpty, isTrue);
      final c = StickerCatalog.parse(const {
        'categories': [
          {'name': 'broken'},
          {
            'category_id': 1,
            'name': 'ok',
            'is_emoji': false,
            'stickers': [
              {'sticker_id': 5}, // 没名字 → 丢
              {'name': 'no_id'}, // 没 id → 丢
              {'sticker_id': 7, 'name': 'good'},
            ],
          },
        ],
      });
      expect(c.categories, hasLength(2));
      expect(c.categories.last.stickers.single.name, 'good');
    });

    test('消息 ↔ 名字：`:name:` 的拼/拆', () {
      expect(StickerCatalog.messageFor('dog_01'), ':dog_01:');
      expect(StickerCatalog.nameFromMessage(':dog_01:'), 'dog_01');
      expect(
        StickerCatalog.nameFromMessage('  :business_man_01: 尾巴'),
        'business_man_01',
      );
      expect(StickerCatalog.nameFromMessage('普通消息'), isNull);
    });
  });

  group('接口 / URL', () {
    test('list 用 v1，解析出目录', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Sticker.list'] = stickerListResponse();
      final catalog = await h.apiForTest.fetchStickers();
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Sticker.list',
      );
      expect(call['version'], '1');
      expect(catalog.idOf('business_man_01'), 81);
    });

    test('图片直链：sc/stickers/{id}/{size}，且**不带 _sid**', () async {
      final h = await bootChat();
      final url = h.apiForTest.stickerImageUrl(81);
      expect(url.contains('/sc/stickers/81/2x'), isTrue);
      expect(url.contains('_sid'), isFalse, reason: '真机实测：挂 _sid 会回 HTML 登录页');
      expect(
        h.apiForTest.stickerImageUrl(81, size: '4x').endsWith('/4x'),
        isTrue,
      );
      expect(h.apiForTest.stickerImageUrl(81).startsWith('http'), isTrue);
    });

    test('downloadSticker 走字节下载 + 内存缓存', () async {
      final h = await bootChat();
      h.transport.bytesByUrl['/sc/stickers/81/2x'] = kPngBytes;
      final bytes = await loadStickerBytes(h.apiForTest, 81);
      expect(bytes, kPngBytes);
      // 第二次不再发请求
      final n = h.transport.downloads.length;
      await loadStickerBytes(h.apiForTest, 81);
      expect(h.transport.downloads.length, n);
      expect(stickerBytesCache.containsKey('81|2x'), isTrue);
    });

    test('老服务端没有 Sticker API → provider 回 null（入口隐藏）', () async {
      final h = await bootChat(
        apiTable: {
          ...FakeTransport.table,
          'SYNO.Chat.Sticker': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      // maxVersion=1 时 supportsStickers 仍然成立（v1 起就有），所以这里改用"没这个 API"
      expect(h.apiForTest.supportsStickers, isTrue);

      final h2 = await bootChat(
        apiTable: {...FakeTransport.table}..remove('SYNO.Chat.Sticker'),
      );
      expect(h2.apiForTest.supportsStickers, isFalse);
      final catalog = await h2.container.read(stickerCatalogProvider.future);
      expect(catalog, isNull);
    });
  });

  group('发送', () {
    test('sendSticker → type=sticker、正文 :name:、本地那条也是 sticker', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.create'] = {
        'post': {
          'post_id': 9001,
          'channel_id': 5,
          'creator_id': 14,
          'create_at': 1700000000000,
          'type': 'sticker',
          'message': ':dog_01:',
        },
      };
      final ok = await h.ctrl.sendSticker(5, 'dog_01');
      expect(ok, isTrue);
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.create',
      );
      expect(call['type'], 'sticker');
      expect(call['message'], '":dog_01:"');
      final posts = await h.container
          .read(chatStoreProvider)
          .postsForChannel(5);
      expect(posts.single.type, 'sticker');
      expect(posts.single.message, ':dog_01:');
    });

    test('空名字不发', () async {
      final h = await bootChat();
      expect(await h.ctrl.sendSticker(5, '   '), isFalse);
      expect(
        h.transport.calls.where(
          (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.create',
        ),
        isEmpty,
      );
    });
  });

  group('渲染', () {
    testWidgets('贴纸消息画 150dp 的图，不显示正文', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Sticker.list'] = stickerListResponse();
      h.transport.bytesByUrl['/sc/stickers/123/2x'] = kPngBytes;
      final c = h.container;
      // 预热目录
      await c.read(stickerCatalogProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: Center(child: StickerView(name: ':dog_01:')),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      await tester.pump();
      final img = tester.widget<Image>(find.byType(Image));
      expect(img.width, kStickerEdge);
      expect(img.height, kStickerEdge);
      expect(find.text(':dog_01:'), findsNothing);
    });

    testWidgets('目录里查不到名字 → 退化成短代码占位（不崩）', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Sticker.list'] = stickerListResponse();
      await h.container.read(stickerCatalogProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: Center(child: StickerView(name: ':nope:')),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(':nope:'), findsOneWidget);
    });

    testWidgets('没有贴纸目录的服务器不显示贴纸按钮', (tester) async {
      final h = await bootChat(
        apiTable: {...FakeTransport.table}..remove('SYNO.Chat.Sticker'),
      );
      h.transport.responses['SYNO.Chat.Channel.list'] = {
        'channels': [
          {
            'channel_id': 5,
            'name': 'general',
            'type': 'public',
            'encrypted': false,
            'member_count': 2,
          },
        ],
      };
      await h.container.read(stickerCatalogProvider.future);
      expect(h.apiForTest.supportsStickers, isFalse);
    });
  });

  group('聊天页里的贴纸', () {
    Future<void> bootSticker(
      WidgetTester tester,
      ProviderContainer c, {
      String message = ':dog_01:',
    }) async {
      await c.read(chatStoreProvider).upsertPosts([
        PostDto.fromJson({
          'post_id': 77,
          'channel_id': 5,
          'creator_id': 14,
          'type': 'sticker',
          'message': message,
          'create_at': 1700000000000,
        }),
      ]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: 5)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('type=sticker 的消息画 150dp 贴纸图，不显示 `:name:` 文本', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Sticker.list'] = stickerListResponse();
      h.transport.bytesByUrl['/sc/stickers/123/2x'] = kPngBytes;
      await bootSticker(tester, h.container);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text(':dog_01:'), findsNothing);
      final img = tester.widget<Image>(find.byType(Image));
      expect(img.width, kStickerEdge);
    });

    testWidgets('目录就绪时输入框旁出现贴纸按钮，点开能选分类', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Sticker.list'] = stickerListResponse();
      h.transport.bytesByUrl['/sc/stickers/'] = kPngBytes;
      await bootSticker(tester, h.container);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.emoji_emotions_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 面板 = 内置八组表情 + 服务端贴纸分类（`DA278`）
      // （分类名在 chip 与段落标题各出现一次，所以按 chip 定位）
      expect(find.widgetWithText(ChoiceChip, '表情'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'business_man'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'dog'), findsOneWidget);
      // 服务端那份 emoji 分类里全是内置表已有的名字 ⇒ 不再重复一段
      expect(find.widgetWithText(ChoiceChip, 'emoji'), findsNothing);
      // 内置表情是真的画出来了（上一版这条路一个表情都没有）
      expect(find.text('😀'), findsOneWidget);
    });

    testWidgets('没有贴纸目录 ⇒ 表情入口照样在（只是没有贴纸段）', (tester) async {
      final h = await bootChat(
        apiTable: {...FakeTransport.table}..remove('SYNO.Chat.Sticker'),
      );
      h.transport.responses['SYNO.Chat.Post.list'] = {'posts': []};
      await bootSticker(tester, h.container);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      // ★ 表情是内置的，不该被"服务端有没有贴纸目录"门控（`DA278`）
      expect(find.byIcon(Icons.emoji_emotions_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.widgetWithText(ChoiceChip, '表情'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'business_man'), findsNothing);
    });
  });

  group('正文里的 :短代码:', () {
    test('已有的短代码换成字符，未知的保持原样', () {
      final segs = parseMessage('hey :thumbsup: 和 :unknown_xyz:');
      final text = segs.whereType<PlainSegment>().map((s) => s.text).join();
      expect(text.contains('👍'), isTrue);
      expect(text.contains(':unknown_xyz:'), isTrue);
    });

    test('短代码不会吃掉后面的 @提及 / 链接', () {
      final segs = parseMessage(':thumbsup: @demo_user https://a.b');
      expect(segs.whereType<MentionSegment>(), hasLength(1));
      expect(segs.whereType<UrlSegment>(), hasLength(1));
    });
  });
}
