// 链接预览（OG）—— DTO 解析 / 选择规则 / 卡片渲染 / 点击行为。
//
// 真机实测载荷见 test/fixtures/url_props_real.json（NAS 上一条真消息的 url_props，
// 服务端**异步**补的）。原版渲染逻辑：`UrlAdapter` + `CommonViewBinder`。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/server_settings.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/server_settings_dto.dart';
import 'package:synhub/src/data/dto/url_prop_dto.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/link_preview_card.dart';
import 'package:synhub/src/features/chat/url_actions.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 真机原样载荷
Map<String, dynamic> realProp() =>
    jsonDecode(File('test/fixtures/url_props_real.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  setUp(clearOgCache);

  group('UrlPropDto 解析（真机载荷）', () {
    test('八个字段全解析出来', () {
      final p = UrlPropDto.tryParse(realProp())!;
      expect(p.url, 'https://www.synology.com/zh-cn/products/DS920+');
      expect(p.title, 'Download Center - download | Synology Inc.');
      expect(p.description, startsWith('Centralize data storage'));
      expect(p.favicon, contains('fileres.synology.com'));
      expect(p.image, contains('meta-tag-preview-image'));
      expect(p.mimeType, 'text/html');
      expect(p.hidden, isFalse);
      expect(p.imageWidth, 1200);
      expect(p.imageHeight, 628);
    });

    test('域名：按原版 getDomainFromUrl 去掉协议头取到第一个 /', () {
      expect(UrlPropDto.tryParse(realProp())!.domain, 'www.synology.com');
      expect(
        UrlPropDto.tryParse({'url': 'http://a.b.c:8080/x/y'})!.domain,
        'a.b.c:8080',
      );
      expect(
        UrlPropDto.tryParse({'url': 'https://no-slash.example'})!.domain,
        'no-slash.example',
      );
    });

    test('没有 title 就用 url 当标题（bindPartialUrlView）', () {
      final p = UrlPropDto.tryParse({'url': 'https://x.y/z'})!;
      expect(p.displayTitle, 'https://x.y/z');
      expect(p.displayTitle, p.url);
    });

    test('缺字段 / 不是 map / 没 url → 容错', () {
      expect(UrlPropDto.tryParse(null), isNull);
      expect(UrlPropDto.tryParse('nope'), isNull);
      expect(UrlPropDto.tryParse({'title': 'x'}), isNull, reason: '没 url 就丢掉');
      final p = UrlPropDto.tryParse({'url': 'https://a.b'})!;
      expect(p.title, '');
      expect(p.image, '');
      expect(p.hasImage, isFalse);
      expect(p.imageWidth, 0);
    });

    test('image_prop 也可能直接平铺成 width/height', () {
      final p = UrlPropDto.tryParse({
        'url': 'https://a.b',
        'width': 100,
        'height': 50,
      })!;
      expect(p.imageWidth, 100);
      expect(p.imageHeight, 50);
    });
  });

  group('该画哪一张（bindFirstUrlOg）', () {
    final a = UrlPropDto.tryParse({'url': 'https://a', 'hidden': true})!;
    final b = UrlPropDto.tryParse({'url': 'https://b'})!;
    final c = UrlPropDto.tryParse({'url': 'https://c'})!;

    test('跳过 hidden，取第一条可见的', () {
      expect(firstVisiblePreview([a, b, c])!.url, 'https://b');
    });

    test('全 hidden → null', () {
      expect(firstVisiblePreview([a]), isNull);
    });

    test('有附件就不画（原版 file() != null 直接隐藏）', () {
      expect(firstVisiblePreview([b], hasAttachment: true), isNull);
    });

    test('PostDto.linkPreview 端到端（含 attachments）', () {
      final post = PostDto.fromJson({
        'post_id': 7,
        'channel_id': 1,
        'creator_id': 14,
        'message': 'https://www.synology.com/',
        'url_props': [realProp()],
      });
      expect(post.linkPreview?.domain, 'www.synology.com');

      final withFile = PostDto.fromJson({
        'post_id': 8,
        'channel_id': 1,
        'creator_id': 14,
        'message': 'x',
        'url_props': [realProp()],
        'file_props': [
          {'file_id': 1, 'post_id': 8, 'name': 'a.txt', 'type': 'file'},
        ],
      });
      expect(withFile.linkPreview, isNull, reason: '有附件就不叠卡片');
    });
  });

  group('图框尺寸（UrlAdapter.setupImageSize）', () {
    test('横图：宽 = 可用宽，高 × 0.6', () {
      final p = UrlPropDto.tryParse({
        'url': 'https://a',
        'image_prop': {'width': 1200, 'height': 628},
      })!;
      final box = p.imageBox(300);
      expect(box.width, 300);
      expect(box.height, closeTo(180, 0.001));
    });

    test('竖图：宽 × 0.7，高 = 宽 × 1.25', () {
      final p = UrlPropDto.tryParse({
        'url': 'https://a',
        'image_prop': {'width': 400, 'height': 900},
      })!;
      final box = p.imageBox(300);
      expect(box.width, closeTo(210, 0.001));
      expect(box.height, closeTo(262.5, 0.001));
    });

    test('方图：宽 = 高 = 可用宽 × 0.7', () {
      final p = UrlPropDto.tryParse({
        'url': 'https://a',
        'image_prop': {'width': 500, 'height': 500},
      })!;
      final box = p.imageBox(300);
      expect(box.width, closeTo(210, 0.001));
      expect(box.height, closeTo(210, 0.001));
    });

    test('尺寸未知或 ≤64px 或强制 → 小图 88×88', () {
      // 原版 getItemViewType：0 ≤ 64 也算小图，所以"没尺寸信息"给缩略图
      final unknown = UrlPropDto.tryParse({'url': 'https://a'})!;
      expect(unknown.isSmallThumb, isTrue);
      expect(unknown.imageBox(320).width, 88);
      expect(unknown.imageBox(320).height, 88);

      final tiny = UrlPropDto.tryParse({
        'url': 'https://a',
        'image_prop': {'width': 64, 'height': 64},
      })!;
      expect(tiny.isSmallThumb, isTrue);
      expect(tiny.imageBox(320).width, 88);

      final big = UrlPropDto.tryParse({
        'url': 'https://a',
        'image_prop': {'width': 800, 'height': 400},
      })!;
      expect(big.isSmallThumb, isFalse);
      expect(big.imageBox(300, forceSmallThumb: true).width, 88);
    });
  });

  group('频道链接判定（UrlUtil）', () {
    const base = 'https://nas.local:5001/';
    test('同主机 + #channels/<id> → 频道 id', () {
      expect(
        channelIdFromLink('https://nas.local:5001/#channels/23', baseUrl: base),
        23,
      );
      expect(
        channelIdFromLink('https://nas.local:5001/#CHANNELS/7', baseUrl: base),
        7,
        reason: 'fragment 大小写不敏感（路径不同就不算了，原版 isSamePath）',
      );
    });

    test('别的域名 / 别的端口 / 路径不同 → 不是频道链接', () {
      expect(
        channelIdFromLink('https://evil.com/#channels/23', baseUrl: base),
        isNull,
      );
      expect(
        channelIdFromLink('https://nas.local:5002/#channels/23', baseUrl: base),
        isNull,
      );
      expect(
        channelIdFromLink(
          'https://nas.local:5001/other/#channels/23',
          baseUrl: base,
        ),
        isNull,
      );
    });

    test('fragment 不是 channels/<数字> → 不是频道链接', () {
      expect(
        channelIdFromLink(
          'https://nas.local:5001/#channels/abc',
          baseUrl: base,
        ),
        isNull,
      );
      expect(
        channelIdFromLink('https://nas.local:5001/#foo/1', baseUrl: base),
        isNull,
      );
      expect(
        channelIdFromLink('https://nas.local:5001/', baseUrl: base),
        isNull,
      );
    });

    test('QuickConnect 域名：同 id 的另一个 QC 域名也算', () {
      expect(
        channelIdFromLink(
          'https://demo.quickconnect.to/#channels/5',
          baseUrl: 'https://demo.quickconnect.to/',
        ),
        5,
      );
      expect(channelIdFromFragment('channels/42'), 42);
      expect(channelIdFromFragment(''), isNull);
    });
  });

  group('聊天页里的门控（hide_post_url_preview）', () {
    Future<void> bootWithLink(WidgetTester tester, ProviderContainer c) async {
      c
          .read(serverSettingsProvider.notifier)
          .apply(ServerSettings.fromJson(const {'notify_type': 'all'}));
      await c.read(chatStoreProvider).upsertPosts([
        PostDto.fromJson({
          'post_id': 30,
          'channel_id': 5,
          'creator_id': 14,
          'message': '看看 https://www.synology.com/',
          'create_at': 1700000000000,
          'url_props': [realProp()],
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

    testWidgets('服务端没要求隐藏 → 画卡片', (tester) async {
      final h = await bootChat();
      h.transport.bytesByUrl['method=og'] = _tinyPng;
      await bootWithLink(tester, h.container);
      expect(
        find.text('Download Center - download | Synology Inc.'),
        findsOneWidget,
      );
    });

    testWidgets('服务端 hide_post_url_preview=true → 不画卡片', (tester) async {
      final h = await bootChat();
      h.container
          .read(serverSettingsProvider.notifier)
          .apply(
            ServerSettings.fromJson(const {'hide_post_url_preview': true}),
          );
      h.transport.bytesByUrl['method=og'] = _tinyPng;
      // bootWithLink 会把设置覆盖掉，所以这里手动装页面
      await h.container.read(chatStoreProvider).upsertPosts([
        PostDto.fromJson({
          'post_id': 31,
          'channel_id': 5,
          'creator_id': 14,
          'message': '看看 https://www.synology.com/',
          'create_at': 1700000000000,
          'url_props': [realProp()],
        }),
      ]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: 5)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Download Center - download | Synology Inc.'),
        findsNothing,
      );
      expect(
        find.textContaining('synology.com'),
        findsWidgets,
        reason: '正文里的链接文字还在，只是不画预览卡',
      );
    });
  });

  group('发完带链接的消息会自动补刷（原版没有，但服务端不推广播）', () {
    testWidgets('发消息 → 4 秒后再拉一次列表 → 预览卡片自己冒出来', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.list': {
            // 第一次拉：服务端还没抓 OG
            'posts': [
              {
                'post_id': 40,
                'channel_id': 5,
                'creator_id': 14,
                'message': '看看 https://www.synology.com/',
                'create_at': 1700000000000,
                'url_props': <Object>[],
              },
            ],
          },
        },
      );
      h.transport.bytesByUrl['method=og'] = _tinyPng;
      h.transport.responses['SYNO.Chat.Post.create'] = {
        'post_id': 41,
        'channel_id': 5,
        'creator_id': 14,
        'type': 'normal',
        'message': '看 https://www.synology.com/',
        'create_at': 1700000100000,
      };
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: 5)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Download Center - download | Synology Inc.'),
        findsNothing,
        reason: '还没抓到 OG 时不该有卡片',
      );

      // 发一条带链接的消息 → 控制器安排 4s/12s 两次补刷
      expect(
        await h.ctrl.sendMessage(5, '看 https://www.synology.com/'),
        isTrue,
      );

      // 服务端抓好了 → 下一次 Post/list 会带上 url_props
      h.transport.responses['SYNO.Chat.Post.list'] = {
        'posts': [
          {
            'post_id': 40,
            'channel_id': 5,
            'creator_id': 14,
            'message': '看看 https://www.synology.com/',
            'create_at': 1700000000000,
            'url_props': [realProp()],
          },
        ],
      };
      final before = h.transport.calls
          .where((c) => c['method'] == 'list' && c['api'] == 'SYNO.Chat.Post')
          .length;
      // 过 4 秒 → 定时器触发补刷
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 300));
      final after = h.transport.calls
          .where((c) => c['method'] == 'list' && c['api'] == 'SYNO.Chat.Post')
          .length;
      expect(after, greaterThan(before), reason: '应该自动补拉了列表');
      expect(
        find.text('Download Center - download | Synology Inc.'),
        findsOneWidget,
      );
      // 还有第二个（12 秒）补刷定时器，跑完它免得测试报"Timer still pending"
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  group('卡片渲染', () {
    Widget wrap(ProviderContainer c, Widget child) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child)),
    );

    testWidgets('大图卡：标题 + 域名 + 描述 + 风险提示', (tester) async {
      final h = await bootChat(extra: {'SYNO.Chat.Post.File.og': const {}});
      // 用 1×1 PNG 假装服务端代理抓回来的 OG 图（走假传输的 getBytes）
      h.transport.bytesByUrl['method=og'] = _tinyPng;

      UrlPropDto? opened;
      await tester.pumpWidget(
        wrap(
          h.container,
          LinkPreviewCard(
            postId: 5,
            prop: UrlPropDto.tryParse(realProp())!,
            safeUrl: false,
            onOpen: (p) => opened = p,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Download Center - download | Synology Inc.'),
        findsOneWidget,
      );
      expect(find.text('www.synology.com'), findsOneWidget);
      expect(find.textContaining('Centralize data storage'), findsOneWidget);
      expect(find.text('链接可能有风险'), findsOneWidget);
      expect(find.byType(Image), findsWidgets, reason: 'OG 图 + favicon');
      expect(
        h.transport.downloads.where((u) => u.contains('method=og')).length,
        2,
        reason: '图 + favicon 都经服务端 OG 代理取',
      );

      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      expect(opened?.url, 'https://www.synology.com/zh-cn/products/DS920+');
    });

    testWidgets('没有 title → 显示 URL；没有描述 → 不显示描述行', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(
        wrap(
          h.container,
          LinkPreviewCard(
            postId: 5,
            prop: UrlPropDto.tryParse({'url': 'https://example.com/page'})!,
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/page'), findsOneWidget);
      expect(find.text('example.com'), findsOneWidget);
      expect(find.text('链接可能有风险'), findsNothing, reason: 'safe_url 默认 true');
    });
  });
}

/// 1×1 透明 PNG（免得依赖仓库里的图片资源）
final List<int> _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
