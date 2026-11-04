// 聊天深链（审计行 262）离线套件：接口层 + 通道契约 + 页面层。
//
// 官方证据（SynologyChat 2.11.1 = 真机安装版 2.11.1-607）：
//   * 真机住院表：`SplashActivity` 收 `VIEW` + `DEFAULT` + `BROWSABLE`，
//     scheme = `synochat` / `synochats` / `synochatGuest` / `synochatsGuest`，
//     **无 authority/path 约束**（`adb shell dumpsys package com.synology.dschat`）；
//     另有 `synology-chat` = AppAuth 的 `RedirectUriReceiverActivity`（OAuth 回跳）。
//   * 参数解析：`LoginActivity.fillInData(Intent)` 读 **extras** `address` / `account`，
//     `https = synochats*`，`guest` **无条件 true**（jadx + baksmali 双向核对）。
//   * 落点：`SplashActivity.enter()` —— 没有已保存账号才去 LoginActivity（预填），
//     有已保存账号直接进主界面（**深链被丢弃**）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:go_router/go_router.dart';

import 'package:synhub/src/core/router/app_routes.dart';
import 'package:synhub/src/dsm/webapi.dart' show DsmSession;
import 'package:synhub/src/features/chat/chat_deep_link.dart';
import 'package:synhub/src/features/chat/chat_deep_link_host.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

const String kManifestPath = 'android/app/src/main/AndroidManifest.xml';

/// 离线假源：给什么 pending 就返回什么，`push` 模拟前台时的来件。
class _FakeDeepLinkSource implements ChatDeepLinkSource {
  _FakeDeepLinkSource(this.pending);

  ChatDeepLink? pending;
  final _events = StreamController<ChatDeepLink>.broadcast();

  @override
  Stream<ChatDeepLink> get incoming => _events.stream;

  @override
  Future<ChatDeepLink?> takePending() async {
    final p = pending;
    pending = null;
    return p;
  }

  void push(ChatDeepLink link) => _events.add(link);

  @override
  void dispose() {
    if (!_events.isClosed) _events.close();
  }
}

/// 一个"已登录"的会话控制器（官方落点判定的输入）。
class _LoggedInSession extends SessionController {
  @override
  SessionState build() => const SessionState(session: DsmSession(sid: 'SID'));
}

void main() {
  // ★ 第 55 轮：这些用例验证的是**桥被调用时发什么载荷**（Android 语义），
  //   而能力层在 macOS 宿主上会正确地拦住 Android-only 桥 ⇒ 先把门打开
  //   （反向验证：门打开时确实去碰通道；见 `platform_capability_test.dart`）。
  setUp(() => debugForceCapabilityGate = true);
  tearDown(() => debugForceCapabilityGate = false);
  // ============================================================ 解析（官方 fillInData）

  group('ChatDeepLink.fromIntentData（官方 LoginActivity.fillInData 等价物）', () {
    test('四条 scheme 都被认（真机住院表的四条）', () {
      for (final s in kChatDeepLinkSchemes) {
        final link = ChatDeepLink.fromIntentData({
          kChatDeepLinkKeyScheme: s,
          kChatDeepLinkKeyAddress: 'nas.example.com',
          kChatDeepLinkKeyAccount: 'bob',
        });
        expect(link, isNotNull, reason: s);
        expect(link!.scheme, s);
        expect(link.address, 'nas.example.com');
        expect(link.account, 'bob');
      }
    });

    test('https 只由 synochats / synochatsGuest 决定（官方 .line 141）', () {
      ChatDeepLink of(String s) =>
          ChatDeepLink.fromIntentData({kChatDeepLinkKeyScheme: s})!;
      expect(of('synochat').secure, isFalse);
      expect(of('synochats').secure, isTrue);
      expect(of('synochatGuest').secure, isFalse);
      expect(of('synochatsGuest').secure, isTrue);
    });

    test('guest 对四条 scheme 都是 true（官方 .line 145 无条件 setChecked(true)）', () {
      for (final s in kChatDeepLinkSchemes) {
        expect(
          ChatDeepLink.fromIntentData({kChatDeepLinkKeyScheme: s})!.guest,
          isTrue,
          reason:
              '这是官方的真实行为（jadx + baksmali 一致），不是我们的选择；'
              '访客登录本身属审计行 261，本批不据此发请求',
        );
      }
    });

    test('extras 缺失 → 地址/账号为空（官方拿到 null 就置空）', () {
      final link = ChatDeepLink.fromIntentData({
        kChatDeepLinkKeyScheme: 'synochat',
      })!;
      expect(link.address, '');
      expect(link.account, '');
      expect(link.hasLoginPrefill, isFalse);
    });

    test('非字符串 extras 不炸、按空处理', () {
      final link = ChatDeepLink.fromIntentData({
        kChatDeepLinkKeyScheme: 'synochat',
        kChatDeepLinkKeyAddress: 1234,
        kChatDeepLinkKeyAccount: const ['a'],
      })!;
      expect(link.address, '');
      expect(link.account, '');
    });

    test('不是这四条 scheme → null（含 OAuth 回跳 synology-chat）', () {
      for (final s in const [
        '',
        'http',
        'https',
        'synology-chat',
        'SYNOCHAT',
      ]) {
        expect(
          ChatDeepLink.fromIntentData({kChatDeepLinkKeyScheme: s}),
          isNull,
          reason: s,
        );
      }
      expect(ChatDeepLink.fromIntentData(const {}), isNull);
    });

    test('URI 兜底：只给 uri 时取它的 scheme，且不解析 host/path/query（官方也不解析）', () {
      final link = ChatDeepLink.fromUri(
        Uri.parse('synochats://whatever/path?address=x&account=y'),
      )!;
      expect(link.scheme, 'synochats');
      expect(link.secure, isTrue);
      expect(link.address, '', reason: '官方只读 intent extras；URI 里的查询串不会被当成地址');
      expect(link.account, '');
      expect(
        ChatDeepLink.fromUri(Uri.parse('synology-chat://account/login')),
        isNull,
        reason: 'synology-chat 是 AppAuth 的 OAuth 回跳，不是登录预填深链',
      );
    });

    test('显式 scheme 优先于 uri（原生两个都给时）', () {
      final link = ChatDeepLink.fromIntentData({
        kChatDeepLinkKeyScheme: 'synochat',
        kChatDeepLinkKeyUri: 'synochats://x',
        kChatDeepLinkKeyAddress: 'a',
      })!;
      expect(link.scheme, 'synochat');
      expect(link.secure, isFalse);
    });
  });

  group('官方常量（防止照抄错我们的旧审计文档）', () {
    test('scheme 常量与真机住院表逐字一致', () {
      expect(kChatDeepLinkSchemes, {
        'synochat',
        'synochats',
        'synochatGuest',
        'synochatsGuest',
      });
      expect(kChatOAuthRedirectScheme, 'synology-chat');
    });

    test('落点判定 = 官方 SplashActivity.enter（已登录即丢弃）', () {
      expect(chatDeepLinkShouldApply(loggedIn: false), isTrue);
      expect(chatDeepLinkShouldApply(loggedIn: true), isFalse);
    });
  });

  // ============================================================ 原生通道契约

  group('synhub/deep_link 通道契约', () {
    const channel = MethodChannel('synhub/deep_link');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('getPending 回 map → 解析成 ChatDeepLink（取完即 null）', () async {
      var payload = <Object?, Object?>{
        'scheme': 'synochats',
        'address': 'qc-id',
        'account': 'amy',
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getPending') return payload;
            return null;
          });
      final source = MethodChannelChatDeepLinkSource();
      addTearDown(source.dispose);

      final link = await source.takePending();
      expect(link, isNotNull);
      expect(link!.scheme, 'synochats');
      expect(link.secure, isTrue);
      expect(link.address, 'qc-id');
      expect(link.account, 'amy');

      payload = const {};
      expect(await source.takePending(), isNull);
    });

    test('onDeepLink 提醒 → 主动 getPending 并推进 incoming 流', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getPending') {
              return <Object?, Object?>{
                'scheme': 'synochat',
                'address': 'h',
                'account': 'z',
              };
            }
            return null;
          });
      final source = MethodChannelChatDeepLinkSource();
      addTearDown(source.dispose);

      final got = <ChatDeepLink>[];
      final sub = source.incoming.listen(got.add);
      addTearDown(sub.cancel);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('onDeepLink'),
            ),
            (_) {},
          );
      await Future<void>.delayed(Duration.zero);

      expect(got, hasLength(1));
      expect(got.single.address, 'h');
      expect(got.single.account, 'z');
    });

    test('通道不存在（桌面/纯 Dart）不是错误：返回 null', () async {
      final source = MethodChannelChatDeepLinkSource();
      addTearDown(source.dispose);
      expect(await source.takePending(), isNull);
    });
  });

  // ============================================================ 页面层（消费端）

  group('ChatDeepLinkHost', () {
    Future<ProviderContainer> boot(
      ChatDeepLinkSource source, {
      bool loggedIn = false,
    }) async {
      final container = ProviderContainer(
        overrides: [
          chatDeepLinkSourceProvider.overrideWithValue(source),
          if (loggedIn)
            sessionControllerProvider.overrideWith(_LoggedInSession.new),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    testWidgets('冷启动 pending：未登录 → 写预填并跳登录页', (tester) async {
      final link = ChatDeepLink.fromIntentData({
        kChatDeepLinkKeyScheme: 'synochats',
        kChatDeepLinkKeyAddress: 'nas.local',
        kChatDeepLinkKeyAccount: 'bob',
      })!;
      final source = _FakeDeepLinkSource(link);
      final c = await boot(source);

      final router = GoRouter(
        initialLocation: AppRoutes.home,
        routes: [
          GoRoute(
            path: AppRoutes.home,
            builder: (_, __) => const ChatDeepLinkHost(child: Text('HOME')),
          ),
          GoRoute(
            path: AppRoutes.login,
            builder: (_, __) => const Text('LOGIN'),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final prefill = c.read(chatDeepLinkPrefillProvider);
      expect(prefill, isNotNull);
      expect(prefill!.address, 'nas.local');
      expect(prefill.account, 'bob');
      expect(prefill.secure, isTrue);
      expect(router.state.uri.path, AppRoutes.login);
      expect(tester.takeException(), isNull);
    });

    testWidgets('前台新来一条：incoming 流同样生效', (tester) async {
      final source = _FakeDeepLinkSource(null);
      final c = await boot(source);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: ChatDeepLinkHost(child: SizedBox.shrink())),
          ),
        ),
      );
      await tester.pump();

      source.push(
        ChatDeepLink.fromIntentData({
          kChatDeepLinkKeyScheme: 'synochat',
          kChatDeepLinkKeyAccount: 'amy',
        })!,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      final prefill = c.read(chatDeepLinkPrefillProvider);
      expect(prefill, isNotNull);
      expect(prefill!.account, 'amy');
      expect(prefill.secure, isFalse);
      // 纯 MaterialApp 里没有 GoRouter → 不跳转、不炸（与 ShareIntentHost 同约定）
      expect(tester.takeException(), isNull);
    });

    testWidgets('已登录 → 按官方丢弃（不写预填、不跳登录页）', (tester) async {
      final link = ChatDeepLink.fromIntentData({
        kChatDeepLinkKeyScheme: 'synochat',
        kChatDeepLinkKeyAddress: 'evil.example',
        kChatDeepLinkKeyAccount: 'x',
      })!;
      final source = _FakeDeepLinkSource(link);
      final c = await boot(source, loggedIn: true);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: ChatDeepLinkHost(child: Text('IN'))),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        c.read(chatDeepLinkPrefillProvider),
        isNull,
        reason: '官方 SplashActivity 有已保存账号时直接进主界面，深链不生效',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('不是深链的 intent（null pending）→ 完全无动作', (tester) async {
      final source = _FakeDeepLinkSource(null);
      final c = await boot(source);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: ChatDeepLinkHost(child: Text('IN'))),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(c.read(chatDeepLinkPrefillProvider), isNull);
      expect(tester.takeException(), isNull);
    });
  });

  // ============================================================ 边界记录

  group('android/** 边界（本批不改清单，交回上一级）', () {
    test('清单一旦声明这些 scheme，必须四条齐全且 VIEW+DEFAULT+BROWSABLE', () {
      final body = File(
        kManifestPath,
      ).readAsStringSync().replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
      final declared = kChatDeepLinkSchemes
          .where((s) => body.contains('android:scheme="$s"'))
          .toSet();
      if (declared.isEmpty) {
        // 现状：本批不可改 android/**（见报告"边界外交接"），由上一级套用补丁。
        return;
      }
      expect(
        declared,
        kChatDeepLinkSchemes,
        reason: '官方四条 scheme 必须一起声明，漏一条就会漏掉 https/guest 变体',
      );
      final filter = RegExp(
        '<intent-filter>(?:(?!</intent-filter>).)*?'
        'android:scheme="synochat"'
        '(?:(?!</intent-filter>).)*?</intent-filter>',
        dotAll: true,
      ).firstMatch(body);
      expect(filter, isNotNull);
      final f = filter!.group(0)!;
      for (final need in const [
        'android.intent.action.VIEW',
        'android.intent.category.DEFAULT',
        'android.intent.category.BROWSABLE',
      ]) {
        expect(f, contains(need), reason: '官方过滤器里有 $need');
      }
    });
  });
}
