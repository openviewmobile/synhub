// 多 NAS / 多账号的**会话层**离线用例。
//
// 重点盯两条安全不变量（切换不串号）与切换/添加/移除的行为：
//   * 切换到 B 之后，A 的连接被摘掉自动重登钩子 —— A 的 119 不可能登进 B；
//   * 切换只带目标 NAS 自己的凭据/设备令牌（不把 A 的 did 带给 B，也不带给同
//     NAS 的另一个账号）；
//   * 无凭据的条目 → 去登录页补；移除当前 → 回落到剩余项；移除别的 → 当前不动。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/core/services/service_reporting_api.dart';
import 'package:synhub/src/data/e2ee/secret_keeper.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatStoreProvider;
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/nas_registry.dart';
import 'package:synhub/src/features/servers/saved_session.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

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

/// 预置一个已登录的假连接（独立传输，能查它到底发了什么）。
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

/// 按地址返回预置连接；记录连了几次、连的是谁。
class _FakeConnectionService extends ConnectionService {
  _FakeConnectionService(this._connections, {this.failFor = const {}});

  final Map<String, DsmConnection> _connections;

  /// 这些地址连接时抛错（测 connectFailed）
  final Set<String> failFor;
  int connects = 0;
  final List<String> connected = [];

  @override
  Future<DsmConnection> connect(
    ServerProfile profile, {
    void Function(ConnectStep)? onStep,
  }) async {
    connects++;
    connected.add(profile.value);
    if (failFor.contains(profile.value)) {
      throw DsmTransportException('连不上 NAS');
    }
    final conn = _connections[profile.value];
    if (conn == null) throw DsmTransportException('没有预置这个地址');
    onStep?.call(ConnectStep('命中 ${profile.value}'));
    return conn;
  }
}

int _loginCount(FakeTransport t) => t.calls
    .where((c) => c['api'] == 'SYNO.API.Auth' && c['method'] == 'login')
    .length;

Map<String, dynamic>? _lastLogin(FakeTransport t) {
  for (final c in t.calls.reversed) {
    if (c['api'] == 'SYNO.API.Auth' && c['method'] == 'login') return c;
  }
  return null;
}

void main() {
  late InMemorySecretKeeper keeper;
  late FakeTransport tHome;
  late FakeTransport tOffice;
  late DsmConnection cHome;
  late DsmConnection cOffice;

  Future<
    ({ChatHarness h, _FakeConnectionService service, SavedSessionStore store})
  >
  boot({Set<String> failFor = const {}}) async {
    keeper = InMemorySecretKeeper();
    (cHome, tHome) = await _makeConn(_homeProfile);
    (cOffice, tOffice) = await _makeConn(_officeProfile);
    late ChatHarness h;
    late _FakeConnectionService service;
    h = await bootChat(
      moreOverrides: [
        savedSessionStoreProvider.overrideWith(
          (ref) =>
              SavedSessionStore(ref.watch(chatStoreProvider), keeper: keeper),
        ),
        connectionServiceProvider.overrideWithValue(
          service = _FakeConnectionService({
            _homeProfile.value: cHome,
            _officeProfile.value: cOffice,
          }, failFor: failFor),
        ),
      ],
    );
    final store = SavedSessionStore(
      h.container.read(chatStoreProvider),
      keeper: keeper,
    );
    return (h: h, service: service, store: store);
  }

  SavedSession sessionOf(
    String id,
    ServerProfile p,
    String account,
    String did,
  ) => SavedSession(
    id: id,
    profile: p,
    account: account,
    password: 'pw-$account',
    rememberDevice: true,
    deviceId: did,
  );

  Future<void> seedBoth(SavedSessionStore store) async {
    await store.save(
      sessionOf('nas-home', _homeProfile, 'demo_user', 'DID-HOME'),
    );
    // 最后写入 office → 它成为"当前"
    await store.save(
      sessionOf('nas-office', _officeProfile, 'office-user', 'DID-OFFICE'),
    );
  }

  test('切换：切到 A 时连接/凭据/设备令牌都换成 A 的', () async {
    final (:h, :service, :store) = await boot();
    await seedBoth(store);
    final notifier = h.container.read(sessionControllerProvider.notifier);

    // 冷启动恢复 → 当前是 office
    expect(await notifier.restore(), AutoLoginResult.success);
    var state = h.container.read(sessionControllerProvider);
    expect(state.activeNasId, 'nas-office');
    expect(state.connection!.api, same(cOffice.api));

    final r = await notifier.switchTo('nas-home');
    expect(r, NasSwitchResult.success);
    state = h.container.read(sessionControllerProvider);
    expect(state.loggedIn, isTrue);
    expect(state.activeNasId, 'nas-home');
    expect(state.connection!.api, same(cHome.api), reason: '模块拿到的必须是 A 的连接');
    expect(state.session!.sid, cHome.api.session!.sid);
    // 切到 A 的登录请求用的是 A 自己的凭据与设备令牌
    final login = _lastLogin(tHome)!;
    expect(login['device_id'], 'DID-HOME');
    expect(_loginCount(tOffice), greaterThan(0), reason: 'office 是冷启动恢复时登的');
  });

  test('安全不变量①：切走之后 A 的会话过期不会登进 B（sid 不串号）', () async {
    final (:h, :service, :store) = await boot();
    await seedBoth(store);
    final notifier = h.container.read(sessionControllerProvider.notifier);

    expect(await notifier.restore(), AutoLoginResult.success); // office
    expect(
      await notifier.switchTo('nas-home'),
      NasSwitchResult.success,
    ); // home
    expect(
      await notifier.switchTo('nas-office'),
      NasSwitchResult.success,
    ); // 回 office

    // A 已经被卸掉：钩子必须被摘
    expect(cHome.api.onSessionExpired, isNull, reason: '旧连接的自动重登钩子必须摘掉');
    expect(cHome.api.onSessionLost, isNull);

    final sidOnB = h.container.read(sessionControllerProvider).session!.sid;
    final loginsOnA = _loginCount(tHome);

    // A 上再来一次 119：应当原样抛错，不触发任何重登
    tHome.failTimes['SYNO.Chat.Channel.list'] = DsmErrorCode.sidNotFound;
    await expectLater(
      cHome.api.call('SYNO.Chat.Channel', 'list'),
      throwsA(
        isA<DsmApiException>().having(
          (e) => e.code,
          'code',
          DsmErrorCode.sidNotFound,
        ),
      ),
    );

    expect(_loginCount(tHome), loginsOnA, reason: '摘了钩子就不该再发生登录');
    final state = h.container.read(sessionControllerProvider);
    expect(state.session!.sid, sidOnB, reason: '当前会话必须还是 B 的 sid');
    expect(state.connection!.api, same(cOffice.api));
  });

  test('安全不变量①（反面）：模块请求带的是当前 NAS 的 sid', () async {
    final (:h, :service, :store) = await boot();
    await seedBoth(store);
    final notifier = h.container.read(sessionControllerProvider.notifier);
    await notifier.restore(); // office
    await notifier.switchTo('nas-home');

    final state = h.container.read(sessionControllerProvider);
    // 模块统一从 state.connection.api 取会话
    await state.connection!.api.call('SYNO.Chat.Channel', 'list');
    final call = tHome.calls.lastWhere((c) => c['api'] == 'SYNO.Chat.Channel');
    expect(call['_sid'], cHome.api.session!.sid);
  });

  test('安全不变量②：同 NAS 换账号登录，不带上一个账号的设备令牌', () async {
    final (:h, :service, :store) = await boot();
    await store.save(
      sessionOf('nas-home', _homeProfile, 'demo_user', 'DID-HOME'),
    );
    final notifier = h.container.read(sessionControllerProvider.notifier);

    expect(await notifier.restore(), AutoLoginResult.success);
    final before = _loginCount(tHome);

    // 同一个 NAS、不同账号
    await notifier.connect(_homeProfile);
    final ok = await notifier.login(
      account: 'other-user',
      password: 'pw',
      rememberDevice: true,
    );
    expect(ok, isTrue);

    final login = _lastLogin(tHome)!;
    expect(_loginCount(tHome), greaterThan(before));
    expect(login['device_id'], isNull, reason: '换账号就不能把上一个账号的设备令牌带过去');
  });

  test('切到没有凭据的条目 → needLogin，不发起连接', () async {
    final (:h, :service, :store) = await boot();
    await seedBoth(store);
    final notifier = h.container.read(sessionControllerProvider.notifier);
    await notifier.restore();

    // 加一条只有地址的新 NAS
    final added = await h.container
        .read(nasRegistryProvider.notifier)
        .add(
          const ServerProfile(
            kind: ServerAddressKind.direct,
            value: 'https://new.nas:5001',
            displayName: '新 NAS',
          ),
        );
    final connectsBefore = service.connects;

    final r = await notifier.switchTo(added.id!);
    expect(r, NasSwitchResult.needLogin);
    expect(service.connects, connectsBefore, reason: '没凭据就别去连');
    final state = h.container.read(sessionControllerProvider);
    expect(state.loggedIn, isFalse);
    expect(state.activeNasId, added.id);
    expect(
      state.saved!.profile.value,
      'https://new.nas:5001',
      reason: '预填给登录页',
    );
  });

  test('添加并连接无凭据 → addNas 返回 needLogin，条目已入列且成为当前', () async {
    final (:h, :service, :store) = await boot();
    await seedBoth(store);
    final notifier = h.container.read(sessionControllerProvider.notifier);
    await notifier.restore();

    final r = await notifier.addNas(
      const ServerProfile(
        kind: ServerAddressKind.direct,
        value: 'https://new.nas:5001',
        displayName: '新 NAS',
      ),
    );
    expect(r, NasSwitchResult.needLogin);
    final nas = h.container.read(nasRegistryProvider);
    expect(nas.configs, hasLength(3));
    expect(nas.activeId, nas.configs.last.id);
  });

  test('移除当前 NAS → 回落到剩余项并登进去，别的不删', () async {
    final (:h, :service, :store) = await boot();
    await seedBoth(store);
    final notifier = h.container.read(sessionControllerProvider.notifier);
    expect(await notifier.restore(), AutoLoginResult.success); // office 当前

    final r = await notifier.removeNas('nas-office');
    expect(r, NasSwitchResult.success);

    final nas = h.container.read(nasRegistryProvider);
    expect(nas.configs, hasLength(1), reason: '只删掉被移除的那一条');
    expect(nas.configs.single.id, 'nas-home');
    expect(nas.activeId, 'nas-home', reason: '回落到剩余项');

    final state = h.container.read(sessionControllerProvider);
    expect(state.activeNasId, 'nas-home');
    expect(state.connection!.api, same(cHome.api), reason: '真的切过去并登录了');
  });

  test('移除"非当前" NAS → 当前会话完全不动，只少一条', () async {
    final (:h, :service, :store) = await boot();
    await seedBoth(store);
    final notifier = h.container.read(sessionControllerProvider.notifier);
    await notifier.restore(); // office 当前
    final sidBefore = h.container.read(sessionControllerProvider).session!.sid;

    final r = await notifier.removeNas('nas-home');
    expect(r, NasSwitchResult.success);

    final nas = h.container.read(nasRegistryProvider);
    expect(nas.configs, hasLength(1));
    expect(nas.configs.single.id, 'nas-office');
    final state = h.container.read(sessionControllerProvider);
    expect(state.activeNasId, 'nas-office');
    expect(state.session!.sid, sidBefore, reason: '当前会话不该被重建');
    expect(state.connection!.api, same(cOffice.api));
  });

  test('移除最后一条 → 回到未登录、没有当前项', () async {
    final (:h, :service, :store) = await boot();
    await store.save(
      sessionOf('nas-home', _homeProfile, 'demo_user', 'DID-HOME'),
    );
    final notifier = h.container.read(sessionControllerProvider.notifier);
    await notifier.restore();

    final r = await notifier.removeNas('nas-home');
    expect(r, NasSwitchResult.success);
    expect(h.container.read(nasRegistryProvider).configs, isEmpty);
    final state = h.container.read(sessionControllerProvider);
    expect(state.loggedIn, isFalse);
    expect(state.activeNasId, isNull);
  });

  test('切换时服务器连不上 → connectFailed，且不残留旧 NAS 的会话', () async {
    final (:h, :service, :store) = await boot(
      failFor: {'https://home.nas:5001'},
    );
    await seedBoth(store);
    final notifier = h.container.read(sessionControllerProvider.notifier);
    await notifier.restore(); // office

    final r = await notifier.switchTo('nas-home');
    expect(r, NasSwitchResult.connectFailed);
    final state = h.container.read(sessionControllerProvider);
    expect(state.activeNasId, 'nas-home');
    expect(state.loggedIn, isFalse, reason: '连不上就不能留着 B 的会话当成 A');
    expect(state.connection, isNull);
  });

  test('登出：只清当前条目，其他 NAS 配置保留', () async {
    final (:h, :service, :store) = await boot();
    await seedBoth(store);
    final notifier = h.container.read(sessionControllerProvider.notifier);
    await notifier.restore(); // office

    await notifier.logout();

    final nas = h.container.read(nasRegistryProvider);
    expect(nas.configs, hasLength(2), reason: '登出不删别的 NAS 配置');
    expect(nas.activeId, isNull, reason: '登出后没有"当前"，不会自动登回去');
    expect(await store.load(), isNull);
    final state = h.container.read(sessionControllerProvider);
    expect(state.loggedIn, isFalse);
    expect(cOffice.api.onSessionExpired, isNull, reason: '登出后旧钩子也要摘掉');
  });

  test('重命名：只改名字，不影响会话', () async {
    final (:h, :service, :store) = await boot();
    await seedBoth(store);
    final notifier = h.container.read(sessionControllerProvider.notifier);
    await notifier.restore();

    await notifier.renameNas('nas-office', '新名字');
    final nas = h.container.read(nasRegistryProvider);
    expect(nas.byId('nas-office')!.profile.displayName, '新名字');
    expect(nas.activeId, 'nas-office');
  });
}
