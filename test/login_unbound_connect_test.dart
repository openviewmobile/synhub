// DA56（r404）：**登录页在"未绑定服务器"的入口下必须先把连接补上**。
//
// 现场（真机、r403 包，`docs/evidence-r404/device/r404_07_login_signin_not_connected.xml`）：
// 多 NAS 下从连接页点切换器里的另一条 —— `SessionController.switchTo` 在
// "本机没有可用凭据"时**只卸连接**、返回 `needLogin`，界面把用户带到登录页；
// 那一页标着 `AUTH · UNBOUND`，账号密码都填好后点「登录」，
// **必然**报 `srvNotConnected`（"Not connected to a server yet"，连点两次同读）。
// 逐字根因：`SessionController.login` 第一行 `if (conn == null) → srvNotConnected`。
//
// 这条用例钉的是**行为**：同样的入口下，点「登录」必须先发生一次
// `ConnectionService.connect`（探针 + 绑定），然后才谈得上登录。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/e2ee/secret_keeper.dart';
import 'package:synhub/src/dsm/webapi.dart' show DsmTransportException;
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatStoreProvider;
import 'package:synhub/src/features/login/login_page.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/saved_session.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

import 'support/chat_harness.dart';

class _FakeConnectionService extends ConnectionService {
  _FakeConnectionService(this._connection, {this.failConnect = false});

  final DsmConnection Function() _connection;
  bool failConnect;
  int connects = 0;
  ServerProfile? lastProfile;

  @override
  Future<DsmConnection> connect(
    ServerProfile profile, {
    void Function(ConnectStep)? onStep,
  }) async {
    connects++;
    lastProfile = profile;
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
      GoRoute(path: '/', builder: (_, _) => const LoginPage()),
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('HOME-PAGE')),
      ),
      GoRoute(
        path: '/setup',
        builder: (_, _) => const Scaffold(body: Text('SETUP-PAGE')),
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

  Future<({ChatHarness h, _FakeConnectionService service})> boot({
    bool failConnect = false,
  }) async {
    keeper = InMemorySecretKeeper();
    late ChatHarness h;
    late _FakeConnectionService service;
    h = await bootChat(
      moreOverrides: [
        savedSessionStoreProvider.overrideWith(
          (ref) =>
              SavedSessionStore(ref.watch(chatStoreProvider), keeper: keeper),
        ),
        connectionServiceProvider.overrideWithValue(
          service = _FakeConnectionService(
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
    return (h: h, service: service);
  }

  /// 复现"点切换器里那一条"：新增一条没有凭据的记录并切过去。
  Future<void> switchToCredentialLessNas(ChatHarness h) async {
    final r = await h.container
        .read(sessionControllerProvider.notifier)
        .addNas(_profile);
    // 没有凭据 ⇒ 需要登录（这正是把用户带到登录页的那条路）
    expect(r, NasSwitchResult.needLogin);
    final state = h.container.read(sessionControllerProvider);
    expect(state.connection, isNull, reason: '先决条件：这时还没有连上服务器');
    expect(state.saved, isNotNull, reason: '但"这一条"已经钉住了（地址/账号可预填）');
  }

  testWidgets('DA56：未绑定 + 有记录 ⇒ 点「登录」先连服务器，再登录成功', (tester) async {
    final (:h, :service) = await boot();
    await switchToCredentialLessNas(h);

    await tester.pumpWidget(_app(h.container));
    await tester.pump();
    // 账号（无凭据的新记录 → 账号框是空的）+ 口令
    await tester.enterText(find.byType(TextField).at(0), 'demo_user');
    await tester.enterText(find.byType(TextField).at(1), 'pw');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(
      service.connects,
      1,
      reason: '必须先探针/绑定一次 —— 修前这里是 0，页面只会报"尚未连接服务器"',
    );
    expect(service.lastProfile?.value, 'demo_admin-qq');
    final state = h.container.read(sessionControllerProvider);
    expect(state.loggedIn, isTrue);
    expect(state.error, isNull);
    expect(find.text('HOME-PAGE'), findsOneWidget);
  });

  testWidgets('DA56 反向：一条记录都没有 ⇒ 仍报"尚未连接服务器"，不硬造连接', (
    tester,
  ) async {
    final (:h, :service) = await boot();
    // 刻意不 switchTo：state.saved == null
    await tester.pumpWidget(_app(h.container));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), 'demo_user');
    await tester.enterText(find.byType(TextField).at(1), 'pw');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(service.connects, 0, reason: '没有地址可连 ⇒ 不许瞎连');
    expect(
      h.container.read(sessionControllerProvider).error,
      isNotNull,
      reason: '这条老提示必须还在（不许改成静默什么都不发生）',
    );
  });
}
