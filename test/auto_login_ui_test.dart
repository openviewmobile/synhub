// 启动页（连接页）在冷启动时的**导航**行为。
//
// 控制器级的判定已经在 `auto_login_test.dart` 覆盖，这里只盯一件事：
// initState 里那一次 `restore()` 真的会被触发，并且四种结果各自走到对的页面 ——
// 因为"自动登录"最怕的是**卡在连接页什么也不发生**。
//
// 用一个只含三条桩路由的 GoRouter：`/`（真连接页）、`/home`、`/login`。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/e2ee/secret_keeper.dart';
import 'package:synhub/src/dsm/webapi.dart' show DsmTransportException;
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatStoreProvider;
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/saved_session.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/server_setup_page.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

import 'support/chat_harness.dart';

class _FakeConnectionService extends ConnectionService {
  _FakeConnectionService(this._connection, {this.failConnect = false});

  final DsmConnection Function() _connection;
  bool failConnect;

  @override
  Future<DsmConnection> connect(
    ServerProfile profile, {
    void Function(ConnectStep)? onStep,
  }) async {
    if (failConnect) throw DsmTransportException('连不上 NAS');
    return _connection();
  }
}

const _profile = ServerProfile(
  kind: ServerAddressKind.quickConnect,
  value: 'demo_admin-qq',
);

Widget _app(ProviderContainer c) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const ServerSetupPage()),
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('HOME-PAGE')),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) => const Scaffold(body: Text('LOGIN-PAGE')),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: c,
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  late InMemorySecretKeeper keeper;

  Future<ChatHarness> boot({bool failConnect = false}) async {
    keeper = InMemorySecretKeeper();
    late ChatHarness h;
    h = await bootChat(
      moreOverrides: [
        savedSessionStoreProvider.overrideWith(
          (ref) =>
              SavedSessionStore(ref.watch(chatStoreProvider), keeper: keeper),
        ),
        connectionServiceProvider.overrideWithValue(
          _FakeConnectionService(
            () => DsmConnection(
              api: h.api,
              endpoint: const ResolvedEndpoint(
                baseUrl: 'https://nas:5001/',
                source: 'lan',
              ),
              profile: _profile,
              dio: DioFactory.create(allowSelfSigned: true),
            ),
            failConnect: failConnect,
          ),
        ),
      ],
    );
    return h;
  }

  SavedSessionStore storeOf(ChatHarness h) =>
      SavedSessionStore(h.container.read(chatStoreProvider), keeper: keeper);

  testWidgets('有保存的登录 → 不再打扰用户，直接进主页', (tester) async {
    final h = await boot();
    await storeOf(h).save(
      SavedSession(
        profile: _profile,
        account: 'demo_user',
        password: 'pw',
        rememberDevice: true,
        deviceId: 'DID-1',
      ),
    );

    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();

    expect(find.text('HOME-PAGE'), findsOneWidget);
    expect(h.container.read(sessionControllerProvider).loggedIn, isTrue);
  });

  testWidgets('没有保存过 → 留在连接页（第一次用的路径）', (tester) async {
    final h = await boot();
    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();

    expect(find.text('HOME-PAGE'), findsNothing);
    expect(find.text('星枢'), findsOneWidget);
    expect(h.container.read(sessionControllerProvider).loggedIn, isFalse);
  });

  testWidgets('r378：连接页（用户第一屏）不许出现临时/调试入口', (tester) async {
    final h = await boot();
    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();

    // 反面：两个临时页面（设计预览 / 诊断）的入口，中文、英文、图标三种找法都不许命中。
    expect(find.text('设计预览'), findsNothing);
    expect(find.text('Design preview'), findsNothing);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
    expect(find.byIcon(Icons.bug_report_outlined), findsNothing);
    // 正面（防空转）：这一屏确实渲染出来了正常内容，不是"整页没渲染"造成的假绿。
    expect(find.text('星枢'), findsOneWidget);
  });

  testWidgets('连不上 → 留在连接页，并把上次的地址预填好', (tester) async {
    final h = await boot(failConnect: true);
    await storeOf(h).save(
      SavedSession(profile: _profile, account: 'demo_user', password: 'pw'),
    );

    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();

    expect(find.text('HOME-PAGE'), findsNothing);
    // 地址已填进输入框：用户只需再点一次「连接」
    expect(find.textContaining('demo_admin-qq'), findsWidgets);
    // 真机缺陷回归（2026-09-22）：连接页是用户看到的**第一屏**，
    // 失败原因必须是用户语言，**不得**原样透出异常原文 / 内部类型名。
    expect(find.textContaining('连不上 NAS'), findsNothing);
    expect(find.textContaining('网络'), findsWidgets);
  });

  testWidgets('连不上但有上次登录 → 提供"离线浏览缓存"入口', (tester) async {
    final h = await boot(failConnect: true);
    await storeOf(h).save(
      SavedSession(profile: _profile, account: 'demo_user', password: 'pw'),
    );

    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();

    // 没网也要能进笔记看上次同步的内容（官方 DS note 的行为）
    final entry = find.textContaining('离线浏览缓存');
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('HOME-PAGE'), findsOneWidget);
  });

  testWidgets('没有上次登录时不提供离线入口（无从缓存起）', (tester) async {
    final h = await boot(failConnect: true);
    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();
    expect(find.textContaining('离线浏览缓存'), findsNothing);
  });

  testWidgets('服务器连上了但登录被拒 → 去登录页（账号已预填）', (tester) async {
    final h = await boot();
    h.transport.failures['SYNO.API.Auth.login'] = 400; // 400：密码错
    await storeOf(h).save(
      SavedSession(
        profile: _profile,
        account: 'demo_user',
        password: 'pw',
        rememberDevice: true,
      ),
    );

    await tester.pumpWidget(_app(h.container));
    await tester.pumpAndSettle();

    expect(find.text('LOGIN-PAGE'), findsOneWidget);
    expect(h.container.read(sessionControllerProvider).autoLoginFailed, isTrue);
  });
}
