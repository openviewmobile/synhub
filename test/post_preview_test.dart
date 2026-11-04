// Phase 9：「收到消息通知时预加载消息」（原版 `PostPreviewWorker`）+ 「回车发送」。
//
// 原版行为（`pref_setting.xml` / `PostPreviewWorker.kt` / `ChannelFragment`）：
//   * `preview_new_message` 三档：`CLOSE` / `ONLY_WIFI`(默认) / `WIFI_AND_OTHER`，
//     存在偏好 key `post_preview_mode` 里；
//   * 弹完通知（`PushNotificationUtils.notifyReceivedMessage` 最后一行）挂一个
//     worker，把该频道 `Post/list` 的 **前后各 40 条**拉下来并 `resetPosts`
//     （**替换**主列表，只删 `state == 0` 的行，本地待发/失败的消息保留）；
//   * 网络类型取不到就不做；失败置 `skip_post_preview_mode` 节流。
//   * `sendByEnter`：开着时输入框单行 + 回车即发（默认关）。
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/network_type.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/notifications/notification_service.dart';
import 'package:synhub/src/features/settings/settings_page.dart';

import 'support/chat_harness.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/fake_background.dart';

ChatStore _store() => ChatStore(ChatDatabase(NativeDatabase.memory()));

/// 固定网络类型的假探针
class _FakeNet implements NetworkTypeProbe {
  _FakeNet(this.value);

  NetworkType value;
  int calls = 0;

  @override
  Future<NetworkType> current() async {
    calls++;
    return value;
  }
}

PostDto _post({
  int id = 1001,
  int channelId = 5,
  int creatorId = 4,
  String message = '在吗',
  int state = 0,
}) => PostDto.fromJson({
  'post_id': id,
  'channel_id': channelId,
  'creator_id': creatorId,
  'create_at': 9000,
  'type': 'normal',
  'message': message,
  'state': state,
});

ChannelDto _channel({int id = 5, String name = '测试频道'}) => ChannelDto.fromJson({
  'channel_id': id,
  'name': name,
  'type': 'public',
  'is_joined': true,
});

void main() {
  group('PostPreviewMode / NetworkType（取值照抄原版）', () {
    test('三档取值与文案对位 arrays.xml/strings.xml', () {
      expect(PostPreviewMode.close.rawValue, 'CLOSE');
      expect(PostPreviewMode.onlyWifi.rawValue, 'ONLY_WIFI');
      expect(PostPreviewMode.wifiAndOther.rawValue, 'WIFI_AND_OTHER');
      expect(PostPreviewMode.onlyWifi.label, '仅在使用 Wi-Fi 时');
      expect(PostPreviewMode.wifiAndOther.label, '使用 Wi-Fi 或移动数据时');
      expect(PostPreviewMode.close.label, '关闭');
    });

    test('fromName：认得出三档，空串/垃圾值落回默认 ONLY_WIFI', () {
      expect(PostPreviewMode.fromName('CLOSE'), PostPreviewMode.close);
      expect(
        PostPreviewMode.fromName('WIFI_AND_OTHER'),
        PostPreviewMode.wifiAndOther,
      );
      expect(PostPreviewMode.fromName(''), PostPreviewMode.onlyWifi);
      expect(PostPreviewMode.fromName('nope'), PostPreviewMode.onlyWifi);
    });

    test('NetworkType 解析 + isWifi', () {
      expect(NetworkType.fromRaw('wifi'), NetworkType.wifi);
      expect(NetworkType.fromRaw('mobile'), NetworkType.mobile);
      expect(NetworkType.fromRaw('other'), NetworkType.other);
      expect(NetworkType.fromRaw('none'), NetworkType.none);
      expect(NetworkType.fromRaw('???'), NetworkType.unknown);
      expect(NetworkType.fromRaw(null), NetworkType.unknown);
      expect(NetworkType.wifi.isWifi, isTrue);
      expect(NetworkType.mobile.isWifi, isFalse);
    });

    test('平台通道查不出来时给 unknown（桌面/测试）', () async {
      // 不注册平台实现 → MissingPluginException → unknown
      final probe = MethodChannelNetworkTypeProbe(
        channel: const MethodChannel('synhub/network_test_none'),
      );
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(await probe.current(), NetworkType.unknown);
    });

    // ★ 第 296 轮（P2-2）：macOS 上**明确回 unknown 且不碰通道** ——
    // `synhub/network` 是 Android `ConnectivityManager` 的桥，桌面没有实现；
    // 不让它以 MissingPluginException 的形态飘到界面。
    test('macOS：回 unknown，且连通道都不碰', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('synhub/network_test_macos');
      var touched = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        touched++;
        return 'wifi';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final probe = MethodChannelNetworkTypeProbe(channel: channel);
      expect(await probe.current(), NetworkType.unknown);
      expect(touched, 0, reason: 'macOS 上不该去碰 Android 的 synhub/network');
    });
  });

  group('SettingsService：回车发送 / 预加载档位', () {
    test('默认：回车发送关、预加载仅 Wi-Fi（原版默认值）', () async {
      final s = SettingsService(_store());
      expect(await s.sendByEnter(), isFalse);
      expect(await s.postPreviewMode(), PostPreviewMode.onlyWifi);
    });

    test('写回读 + key 名与原版一致（sendByEnter / post_preview_mode）', () async {
      final store = _store();
      final s = SettingsService(store);
      await s.setSendByEnter(true);
      await s.setPostPreviewMode(PostPreviewMode.wifiAndOther);
      expect(await s.sendByEnter(), isTrue);
      expect(await s.postPreviewMode(), PostPreviewMode.wifiAndOther);

      final all = await store.allSettings();
      expect(all[kSendByEnterKey], 'true');
      expect(all[kPostPreviewModeKey], 'WIFI_AND_OTHER');
    });

    test('坏值回落默认（不抛）', () async {
      final store = _store();
      await store.setSetting(kPostPreviewModeKey, 'garbage');
      await store.setSetting(kSendByEnterKey, 'yes');
      final s = SettingsService(store);
      expect(await s.postPreviewMode(), PostPreviewMode.onlyWifi);
      expect(await s.sendByEnter(), isFalse);
    });

    test('provider 落盘往返', () async {
      final store = _store();
      final c = ProviderContainer(
        overrides: [chatStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      await c.read(sendByEnterProvider.notifier).set(true);
      await c.read(postPreviewModeProvider.notifier).set(PostPreviewMode.close);

      final c2 = ProviderContainer(
        overrides: [chatStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c2.dispose);
      await c2.read(sendByEnterProvider.notifier).preload();
      await c2.read(postPreviewModeProvider.notifier).preload();
      expect(c2.read(sendByEnterProvider), isTrue);
      expect(c2.read(postPreviewModeProvider), PostPreviewMode.close);
    });
  });

  group('预加载：40+40、替换而非合并、门禁矩阵', () {
    test('拉的是 40+40 且带 has=[thread]（对位 fetchServerPostsAndReset）', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.list': {
            'posts': [testPostJson],
          },
        },
      );
      final n = await h.ctrl.prefetchChannelPosts(5);
      expect(n, 1);

      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'list',
      );
      expect(call['channel_id'], '5');
      expect(call['prev_count'], '40');
      expect(call['next_count'], '40');
      expect(call['has'], contains('thread'));
      expect(call.containsKey('post_id'), isFalse, reason: '游标不带（原版传 -1）');
    });

    test('替换主列表：老的正常消息被换掉，本地待发消息保留', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.list': {
            'posts': [testPostJson],
          },
        },
      );
      final store = h.container.read(chatStoreProvider);
      // 先塞一条"旧的"正常消息 + 一条发送失败的本地消息 + 一条话题回复
      await store.upsertPosts([
        _post(id: 900, message: '旧的'),
        _post(id: 901, message: '没发出去', state: 2),
      ]);
      await store.upsertPosts([
        PostDto.fromJson({
          'post_id': 902,
          'channel_id': 5,
          'creator_id': 14,
          'create_at': 500,
          'type': 'normal',
          'thread_id': 700,
          'message': '话题里的回复',
        }),
      ]);

      await h.ctrl.prefetchChannelPosts(5);
      final main = await store.postsForChannel(5);
      final ids = main.map((p) => p.postId).toSet();
      expect(ids, contains(4294967300), reason: '服务端新拉的进来了');
      expect(ids, isNot(contains(900)), reason: '旧的正常消息被 reset 掉');
      expect(ids, contains(901), reason: '待发/失败的本地消息要保留（原版只删 state=0）');
      final topic = await store.postsForChannel(5, threadId: 700);
      expect(topic.single.postId, 902, reason: '话题回复不受影响');
    });

    test('门禁矩阵：CLOSE 不发；ONLY_WIFI 只认 Wi-Fi；WIFI_AND_OTHER 认移动数据；'
        'unknown/none 都不发', () async {
      Future<bool> run(PostPreviewMode mode, NetworkType net) async {
        final fake = _FakeNet(net);
        final h = await bootChat(
          moreOverrides: [networkTypeProbeProvider.overrideWithValue(fake)],
          extra: {
            'SYNO.Chat.Post.list': {
              'posts': [testPostJson],
            },
          },
        );
        // 档位写进 store（provider 的 preload 读它）
        await SettingsService(
          h.container.read(chatStoreProvider),
        ).setPostPreviewMode(mode);
        await h.container.read(postPreviewModeProvider.notifier).preload();
        final svc = NotificationService(
          h.container.read(notificationServiceProvider).ref,
          background: FakeBackground(),
        );
        final before = h.transport.calls.length;
        final ok = await svc.maybePrefetchPosts(5);
        final posted = h.transport.calls
            .skip(before)
            .any((c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'list');
        expect(posted, ok, reason: '返回值要和"真发了请求"一致');
        return ok;
      }

      expect(await run(PostPreviewMode.close, NetworkType.wifi), isFalse);
      expect(await run(PostPreviewMode.onlyWifi, NetworkType.wifi), isTrue);
      expect(await run(PostPreviewMode.onlyWifi, NetworkType.mobile), isFalse);
      expect(await run(PostPreviewMode.onlyWifi, NetworkType.unknown), isFalse);
      expect(await run(PostPreviewMode.onlyWifi, NetworkType.none), isFalse);
      expect(
        await run(PostPreviewMode.wifiAndOther, NetworkType.mobile),
        isTrue,
      );
      expect(
        await run(PostPreviewMode.wifiAndOther, NetworkType.unknown),
        isFalse,
      );
    });

    test('失败后置节流位，不再重试；登录/同步成功可清', () async {
      final h = await bootChat(
        moreOverrides: [
          networkTypeProbeProvider.overrideWithValue(
            _FakeNet(NetworkType.wifi),
          ),
        ],
        extra: {
          'SYNO.Chat.Post.list': {
            'posts': [testPostJson],
          },
        },
      );
      final call = h.transport.calls;
      h.transport.failures['SYNO.Chat.Post.list'] = 102; // 服务端报错
      final svc = NotificationService(
        h.container.read(notificationServiceProvider).ref,
        background: FakeBackground(),
      );
      expect(await svc.maybePrefetchPosts(5), isFalse);
      expect(svc.skipPostPreview, isTrue);

      int listCalls() => call
          .where((c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'list')
          .length;
      final before = listCalls();
      expect(await svc.maybePrefetchPosts(5), isFalse);
      expect(listCalls(), before, reason: '节流期间一个请求都不发');

      svc.clearSkipPostPreview();
      h.transport.failures.remove('SYNO.Chat.Post.list');
      expect(await svc.maybePrefetchPosts(5), isTrue);
    });

    test('同步成功清掉节流位（原版 SyncWorker 成功时 setSkipPostPreview(false)）', () async {
      final h = await bootChat(
        moreOverrides: [
          networkTypeProbeProvider.overrideWithValue(
            _FakeNet(NetworkType.wifi),
          ),
        ],
        extra: {
          'SYNO.Chat.Post.list': {
            'posts': [testPostJson],
          },
        },
      );
      final svc = h.container.read(notificationServiceProvider);
      h.transport.failures['SYNO.Chat.Post.list'] = 102;
      await svc.maybePrefetchPosts(5);
      expect(svc.skipPostPreview, isTrue);

      h.transport.failures.remove('SYNO.Chat.Post.list');
      await h.ctrl.refresh(); // 一次成功的同步
      expect(svc.skipPostPreview, isFalse, reason: '同步成功要放开节流');
    });

    test('弹通知成功后自动预加载（原版挂在通知后面）', () async {
      final h = await bootChat(
        moreOverrides: [
          networkTypeProbeProvider.overrideWithValue(
            _FakeNet(NetworkType.wifi),
          ),
        ],
        extra: {
          'SYNO.Chat.Post.list': {
            'posts': [testPostJson],
          },
        },
      );
      final svc = NotificationService(
        h.container.read(notificationServiceProvider).ref,
        background: FakeBackground(),
      );
      svc.appInForeground = false;
      final before = h.transport.calls.length;
      expect(await svc.maybeNotify(_post(), channel: _channel()), isTrue);
      // 预加载是 unawaited 的，给它一轮事件循环
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final posted = h.transport.calls
          .skip(before)
          .any((c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'list');
      expect(posted, isTrue, reason: '弹了通知就该预加载');
    });

    test('没弹通知（前台）就不预加载', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.list': {
            'posts': [testPostJson],
          },
        },
      );
      final svc = NotificationService(
        h.container.read(notificationServiceProvider).ref,
        background: FakeBackground(),
      );
      svc.appInForeground = true;
      final before = h.transport.calls.length;
      expect(await svc.maybeNotify(_post(), channel: _channel()), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(
        h.transport.calls
            .skip(before)
            .any((c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'list'),
        isFalse,
      );
    });
  });

  group('回车发送（sendByEnter）', () {
    testWidgets('开着：输入框单行 + IME 动作是发送；关着：多行 + 换行', (tester) async {
      final h = await bootChat();
      var sent = 0;
      final controller = TextEditingController();

      Future<void> pump({required bool on}) async {
        await h.container.read(sendByEnterProvider.notifier).set(on);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: h.container,
            child: MaterialApp(theme: AppTheme.dark(), 
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    final enter = ref.watch(sendByEnterProvider);
                    return TextField(
                      controller: controller,
                      maxLines: enter ? 1 : 5,
                      textInputAction: enter
                          ? TextInputAction.send
                          : TextInputAction.newline,
                      onSubmitted: enter ? (_) => sent++ : null,
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await pump(on: false);
      var field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLines, 5);
      expect(field.textInputAction, TextInputAction.newline);
      expect(field.onSubmitted, isNull);
      // 回车（IME 换行动作）不该触发发送
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();
      expect(sent, 0);

      await pump(on: true);
      field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLines, 1, reason: '原版 setSingleLine(true)');
      expect(field.textInputAction, TextInputAction.send);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(sent, 1, reason: '回车即发');
    });

    testWidgets('设置页有这两个开关/入口', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();
      // 「外观」段新增了四个开关，这两个入口现在在屏幕外（ListView 懒构建），
      // 要先滚下去；不用 scrollUntilVisible（跨步会 No element），手动滚更稳
      Future<void> reveal(String label) async {
        final target = find.text(label);
        for (var i = 0; i < 24 && target.evaluate().isEmpty; i++) {
          await tester.drag(find.byType(ListView), const Offset(0, -240));
          await tester.pump(const Duration(milliseconds: 60));
        }
        expect(target, findsOneWidget, reason: label);
      }

      // 页面顺序：回车发送 → 收到消息通知时预加载消息（副标题「仅在使用 Wi-Fi 时」）
      await reveal('回车发送');
      await reveal('收到消息通知时预加载消息');
      expect(find.text('仅在使用 Wi-Fi 时'), findsOneWidget);
    });
  });
}
