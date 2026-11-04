// ★ **危险链接拦截**的专项验证 —— ②聊天 审计行 **174**。
//
// ## 本轮的真实发现：不是「无专项单测」，是**真的少一层**
//
// 原判 🟡 说「有拦截 UI，无真机/服务端证据；且无专项单测」。查实现后发现问题更实：
// `link_preview_card.dart` 只有一条**横幅**（`chatLinkRisky`），
// **没有**官方那层「打开前确认」。而官方 APK 里有**三个**字符串：
//
// | string | 官方原文 |
// |---|---|
// | `unsafe_website_title` | Unsafe website / 不安全的网站 |
// | `unsafe_website_desc` | 此信息包含 Google 安全浏览归类为恶意的 URL… |
// | `unsafe_website_confirm_open` | 以下网站可能由 Google 安全浏览归类为恶意网站。我们建议您不要访问它。**是否确定要打开它？** |
//
// ⇒ `unsafe_website_confirm_open` 是**打开前**的确认，我方完全没有。
// 本轮补齐（`url_actions.dart` 的 `_confirmUnsafe`，文案**逐字**取自 APK）。
//
// ## 证据
// * 官方三个字符串：`/tmp/chat_apktool/res/values/strings.xml` 与
//   `values-zh-rCN/strings.xml`（本轮 `grep` 出的**原文**）。
// * 触发条件：`post.props.safe_url == false`（我方 `PostDto.safeUrl`，
//   `link_preview_card.dart:75` 的 `safeUrl`）。
//
// ## 不做什么
// 不碰真机、不碰真 NAS（§5.1）。全程 widget/单元测试。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/chat/url_actions.dart';

/// 直接调用被测函数的驱动器（通过一个按钮触发）。
class _Driver extends StatefulWidget {
  const _Driver({
    required this.url,
    required this.baseUrl,
    required this.unsafe,
    this.known,
  });

  final String url;
  final String baseUrl;
  final bool unsafe;
  final Set<int>? known;

  @override
  State<_Driver> createState() => _DriverState();
}

class _DriverState extends State<_Driver> {
  final results = <String>[];

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: () async {
      results.add('start');
      await openUrlOrJumpChannel(
        context,
        widget.url,
        baseUrl: widget.baseUrl,
        knownChannelIds: widget.known,
        unsafe: widget.unsafe,
      );
      results.add('done');
    },
    child: const Text('go'),
  );
}

void main() {
  group('UA-1. 官方文案逐字落地（不是编的）', () {
    testWidgets('★ 确认弹窗用的是官方 `unsafe_website_confirm_open` 原文', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (ctx) {
              final t = ctx.t;
              // zh 环境的原文（来自 APK values-zh-rCN/strings.xml）
              expect(
                t.chatUnsafeWebsiteConfirmOpen,
                contains('Google 安全浏览'),
                reason: '官方 zh-rCN 原文里有这个品牌词',
              );
              expect(t.chatUnsafeWebsiteConfirmOpen, contains('是否确定要打开它？'));
              return const SizedBox();
            },
          ),
        ),
      );
    });
  });

  group('UA-2. ★ 不安全链接：**打开前必须确认**（本轮补的那层）', () {
    testWidgets('★ `unsafe: true` ⇒ 弹确认框，且**不点确认就不打开**', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: _Driver(
              url: 'https://evil.example.com/x',
              baseUrl: 'https://nas:5001/',
              unsafe: true,
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // 弹窗出现，正文是官方文案
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.textContaining('Google 安全浏览'),
        findsOneWidget,
        reason: '必须显示官方那句确认文案',
      );
      // 两个动作
      expect(find.text('仍然打开'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('★ 点「取消」⇒ 弹窗关闭、**没有**任何打开动作', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: _Driver(
              url: 'https://evil.example.com/x',
              baseUrl: 'https://nas:5001/',
              unsafe: true,
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      // 测试环境 `isTestEnvironment == true` ⇒ 本来就不会真启动浏览器，
      // 所以这里额外断言**没有**弹"没有可打开的应用"这类后续提示
      // —— 取消必须是**静默**的，不该再 toast 一条错误。
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('★ 点「仍然打开」⇒ 走完流程（测试环境不真起浏览器，故给提示）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: _Driver(
              url: 'https://evil.example.com/x',
              baseUrl: 'https://nas:5001/',
              unsafe: true,
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仍然打开'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing, reason: '确认后弹窗要关掉');
      // `isTestEnvironment` 让 `launchUrl` 短路成 false ⇒ 落到"没有可打开的应用"
      // 这条分支。这恰好证明**确认后真的往下走了**（而不是卡在弹窗）。
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('★ `unsafe: false`（默认）⇒ **不弹**任何确认框', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: _Driver(
              url: 'https://example.com/x',
              baseUrl: 'https://nas:5001/',
              unsafe: false,
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('UA-3. ★ 本机频道链接**不受**确认拦截（官方也只拦外部打开）', () {
    testWidgets('★ `unsafe: true` 但目标是本机频道链接 ⇒ 直接跳，不弹确认', (tester) async {
      // 频道链接会走 `context.push` ⇒ 需要 GoRouter。
      // 这本身也**证明**了它走的是"跳频道"分支而不是"外部打开"分支。
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: _Driver(
                url: 'https://nas:5001/#channels/5',
                baseUrl: 'https://nas:5001/',
                unsafe: true,
              ),
            ),
          ),
          GoRoute(
            path: '/chat/:id',
            builder: (_, _) => const Scaffold(body: Text('CHANNEL PAGE')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(
        find.byType(AlertDialog),
        findsNothing,
        reason: '官方顺序是先 jumpChannel 再 openWebPage；安全提示只针对后者',
      );
      // 而且**真的跳到了频道页**
      expect(find.text('CHANNEL PAGE'), findsOneWidget);
    });

    testWidgets('★ 未知频道（不在本地库）⇒ 提示"不在列表里"，也不弹安全确认', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: _Driver(
              url: 'https://nas:5001/#channels/999',
              baseUrl: 'https://nas:5001/',
              unsafe: true,
              known: {1, 2, 3},
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });

  group('UA-4. 链接解析纯函数（既有能力，防回归）', () {
    test('`channelIdFromFragment`：只有 `channels/<int>` 才算，大小写不敏感', () {
      expect(channelIdFromFragment('channels/5'), 5);
      expect(channelIdFromFragment('CHANNELS/5'), 5);
      expect(channelIdFromFragment('channels/abc'), isNull);
      expect(channelIdFromFragment('channels/'), isNull);
      expect(channelIdFromFragment(''), isNull);
      expect(channelIdFromFragment('other/5'), isNull);
    });

    test('`isServerLink`：同主机 + 同端口 + 同路径', () {
      const base = 'https://nas:5001/';
      expect(
        isServerLink('https://nas:5001/#channels/5', baseUrl: base),
        isTrue,
      );
      expect(isServerLink('https://other:5001/x', baseUrl: base), isFalse);
      expect(isServerLink('https://nas:6000/x', baseUrl: base), isFalse);
      expect(isServerLink('not a url', baseUrl: base), isFalse);
      expect(isServerLink('', baseUrl: base), isFalse);
    });

    test('QuickConnect：同一 id 下的 quickconnect 域名互认', () {
      const base = 'https://abc.quickconnect.cn/';
      expect(
        isServerLink('https://abc.quickconnect.cn/#channels/1', baseUrl: base),
        isTrue,
      );
      expect(
        isServerLink('https://zzz.quickconnect.cn/#channels/1', baseUrl: base),
        isFalse,
        reason: '不同 id 的 QuickConnect 域名不算同一台服务器',
      );
    });
  });
}
