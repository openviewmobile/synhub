// 多 NAS / 多账号的**页面层**离线用例。
//
// 覆盖任务要求里的界面面：
//   * 切换器出现（多个时）/ 只剩一个时的表现；
//   * 切换后列表重新拉取（用真实依赖 `sessionControllerProvider` 的 provider 计数）；
//   * 移除必须二次确认：取消 → 不删；确认 → 只删这一条；
//   * 移除当前项 → 回落到剩余项。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/core/services/service_reporting_api.dart';
import 'package:synhub/src/data/e2ee/secret_keeper.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatStoreProvider;
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/nas_manager_page.dart';
import 'package:synhub/src/features/servers/nas_registry.dart';
import 'package:synhub/src/features/servers/saved_session.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/server_setup_page.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

const _homeProfile = ServerProfile(
  kind: ServerAddressKind.direct,
  value: 'https://home.nas:5001',
  displayName: '家里的 NAS',
);
const _officeProfile = ServerProfile(
  kind: ServerAddressKind.direct,
  value: 'https://office.nas:5001',
  displayName: '办公室 NAS',
);

/// 每次被重新求值就记一笔 —— 用来证明"切换后列表会重新拉取"。
final _fetchLog = <String?>[];

final _fakeListProvider = FutureProvider<List<int>>((ref) async {
  final conn = ref.watch(sessionControllerProvider).connection;
  _fetchLog.add(conn?.profile.value);
  return const <int>[];
});

Future<(DsmConnection, FakeTransport)> _makeConn(ServerProfile p) async {
  final transport = FakeTransport({
    'SYNO.Chat.Channel.list': {'channels': <Map<String, dynamic>>[]},
  });
  final api = ServiceReportingApi(transport);
  await api.discover();
  await api.login(account: 'seed', password: 'seed', session: 'Chat');
  return (
    DsmConnection(
      api: api,
      endpoint: ResolvedEndpoint(baseUrl: '${p.value}/', source: 'lan'),
      profile: p,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
    transport,
  );
}

class _FakeService extends ConnectionService {
  _FakeService(this._byValue);
  final Map<String, DsmConnection> _byValue;

  @override
  Future<DsmConnection> connect(
    ServerProfile profile, {
    void Function(ConnectStep)? onStep,
  }) async {
    final c = _byValue[profile.value];
    if (c == null) throw DsmTransportException('没有预置这个地址');
    onStep?.call(ConnectStep('命中 ${profile.value}'));
    return c;
  }
}

SavedSession _cfg(String id, ServerProfile p, String account, {String? did}) =>
    SavedSession(
      id: id,
      profile: p,
      account: account,
      password: 'pw',
      deviceId: did,
    );

void main() {
  late InMemorySecretKeeper keeper;

  Future<ChatHarness> boot(Map<String, DsmConnection> conns) async {
    keeper = InMemorySecretKeeper();
    return bootChat(
      moreOverrides: [
        savedSessionStoreProvider.overrideWith(
          (ref) =>
              SavedSessionStore(ref.watch(chatStoreProvider), keeper: keeper),
        ),
        connectionServiceProvider.overrideWithValue(_FakeService(conns)),
      ],
    );
  }

  Future<void> seed(
    ChatHarness h,
    List<SavedSession> list,
    String? activeId,
  ) async {
    final store = SavedSessionStore(
      h.container.read(chatStoreProvider),
      keeper: keeper,
    );
    await store.nas.persist(list, activeId);
    await h.container.read(nasRegistryProvider.notifier).reload();
  }

  Widget wrapRouter(ChatHarness h) {
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
      container: h.container,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  Widget wrapPage(ChatHarness h, Widget child) => UncontrolledProviderScope(
    container: h.container,
    child: MaterialApp(theme: AppTheme.dark(), home: child),
  );

  testWidgets('多个 NAS：服务器页出现切换器，点另一个会切过去', (tester) async {
    final (cHome, _) = await _makeConn(_homeProfile);
    final (cOffice, _) = await _makeConn(_officeProfile);
    final h = await boot({
      _homeProfile.value: cHome,
      _officeProfile.value: cOffice,
    });
    // 两条配置，但"当前"为空（登录过的用户登出后的样子）→ 冷启动不会自动登
    await seed(h, [
      _cfg('nas-home', _homeProfile, 'demo_user', did: 'DID-HOME'),
      _cfg('nas-office', _officeProfile, 'office-user', did: 'DID-OFFICE'),
    ], null);

    await tester.pumpWidget(wrapRouter(h));
    await tester.pumpAndSettle();

    expect(find.text('选择 NAS（2 个）'), findsOneWidget, reason: '多个时切换器要出现');
    expect(find.byType(ChoiceChip), findsNWidgets(2));

    await tester.tap(find.widgetWithText(ChoiceChip, '家里的 NAS'));
    await tester.pumpAndSettle();

    // 切过去并登录成功 → 连接页按既有逻辑跳主页
    expect(find.text('HOME-PAGE'), findsOneWidget);
    final state = h.container.read(sessionControllerProvider);
    expect(state.activeNasId, 'nas-home');
    expect(state.connection!.api, same(cHome.api));
  });

  testWidgets('只剩一个 NAS：不出现切换列表，只显示已保存项', (tester) async {
    final (cHome, _) = await _makeConn(_homeProfile);
    final h = await boot({_homeProfile.value: cHome});
    await seed(h, [
      _cfg('nas-home', _homeProfile, 'demo_user', did: 'DID-HOME'),
    ], null);

    await tester.pumpWidget(wrapRouter(h));
    await tester.pumpAndSettle();

    expect(find.text('选择 NAS（1 个）'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing, reason: '一个的时候不该给切换列表');
    expect(find.text('已保存的 NAS'), findsOneWidget);
    expect(find.textContaining('家里的 NAS'), findsWidgets);
    expect(find.text('管理 NAS'), findsOneWidget);
  });

  testWidgets('切换后依赖会话的列表会重新拉取', (tester) async {
    final (cHome, _) = await _makeConn(_homeProfile);
    final (cOffice, _) = await _makeConn(_officeProfile);
    final h = await boot({
      _homeProfile.value: cHome,
      _officeProfile.value: cOffice,
    });
    await seed(h, [
      _cfg('nas-home', _homeProfile, 'demo_user', did: 'DID-HOME'),
      _cfg('nas-office', _officeProfile, 'office-user', did: 'DID-OFFICE'),
    ], 'nas-office');

    // 先生效一次："当前"是 office
    final notifier = h.container.read(sessionControllerProvider.notifier);
    await notifier.restore();
    final sub = h.container.listen(
      _fakeListProvider,
      (_, _) {},
      fireImmediately: true,
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(_fetchLog.last, _officeProfile.value, reason: '初次拉的是当前 NAS');

    final before = _fetchLog.length;
    await notifier.switchTo('nas-home');
    await tester.pumpAndSettle();

    expect(
      _fetchLog.length,
      greaterThan(before),
      reason: '切换后依赖会话的 provider 必须重新求值（列表重新拉取）',
    );
    expect(_fetchLog.last, _homeProfile.value);
    sub.close();
  });

  testWidgets('移除需要确认：点取消不会删任何配置', (tester) async {
    final (cHome, _) = await _makeConn(_homeProfile);
    final (cOffice, _) = await _makeConn(_officeProfile);
    final h = await boot({
      _homeProfile.value: cHome,
      _officeProfile.value: cOffice,
    });
    await seed(h, [
      _cfg('nas-home', _homeProfile, 'demo_user', did: 'DID-HOME'),
      _cfg('nas-office', _officeProfile, 'office-user', did: 'DID-OFFICE'),
    ], 'nas-office');
    await h.container.read(nasRegistryProvider.notifier).ensureLoaded();

    await tester.pumpWidget(wrapPage(h, const NasManagerPage()));
    await tester.pumpAndSettle();
    // r489：NAS 卡片换成设计行卡（`DA130`），判据跟着换类型而不是放宽
    expect(find.byType(DesignRowTile), findsNWidgets(2));

    // 打开第一项（家里的 NAS）的菜单 → 移除
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(find.text('移除这个 NAS？'), findsOneWidget, reason: '移除必须二次确认');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(
      h.container.read(nasRegistryProvider).configs,
      hasLength(2),
      reason: '取消不能删任何东西',
    );
  });

  testWidgets('确认移除：只删这一条，别的 NAS 配置保留', (tester) async {
    final (cHome, _) = await _makeConn(_homeProfile);
    final (cOffice, _) = await _makeConn(_officeProfile);
    final h = await boot({
      _homeProfile.value: cHome,
      _officeProfile.value: cOffice,
    });
    await seed(h, [
      _cfg('nas-home', _homeProfile, 'demo_user', did: 'DID-HOME'),
      _cfg('nas-office', _officeProfile, 'office-user', did: 'DID-OFFICE'),
    ], 'nas-office');
    await h.container.read(nasRegistryProvider.notifier).ensureLoaded();

    await tester.pumpWidget(wrapPage(h, const NasManagerPage()));
    await tester.pumpAndSettle();

    // 删第一项（家里的 NAS，非当前）
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    final nas = h.container.read(nasRegistryProvider);
    expect(nas.configs, hasLength(1), reason: '只该少一条');
    expect(nas.configs.single.id, 'nas-office', reason: '别的那条必须原样保留');
    expect(nas.activeId, 'nas-office');
  });

  testWidgets('移除当前 NAS：明确确认后回落到剩余项', (tester) async {
    final (cHome, _) = await _makeConn(_homeProfile);
    final (cOffice, _) = await _makeConn(_officeProfile);
    final h = await boot({
      _homeProfile.value: cHome,
      _officeProfile.value: cOffice,
    });
    await seed(h, [
      _cfg('nas-home', _homeProfile, 'demo_user', did: 'DID-HOME'),
      _cfg('nas-office', _officeProfile, 'office-user', did: 'DID-OFFICE'),
    ], 'nas-office');

    // 让 office 成为"当前会话"
    await h.container.read(sessionControllerProvider.notifier).restore();
    await tester.pumpWidget(wrapPage(h, const NasManagerPage()));
    await tester.pumpAndSettle();

    // 当前那条（办公室 NAS）在列表里排第二
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('当前 NAS'),
      findsOneWidget,
      reason: '移除当前项要说明会断开并切换',
    );
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    final nas = h.container.read(nasRegistryProvider);
    expect(nas.configs, hasLength(1));
    expect(nas.configs.single.id, 'nas-home');
    expect(nas.activeId, 'nas-home', reason: '回落到剩余项');

    final state = h.container.read(sessionControllerProvider);
    expect(state.activeNasId, 'nas-home');
    expect(state.connection!.api, same(cHome.api), reason: '回落后真的连上了剩余项');
  });
}
