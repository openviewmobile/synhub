// 冷启动静默重登 + 「记住此设备」的控制器级测试。
//
// 覆盖的是**行为链**，不是单点：
//   * 没有保存过 → 不联网、不进主页（第一次用的路径）；
//   * 保存过 → 自动连 + 自动登，且**上次的 did 会作为 device_id 回传**（免验证码）；
//   * 连接失败 → 留在连接页，但服务器地址仍可预填；
//   * 登录被拒（密码改了）→ 去登录页，并把落盘的密码清掉（别每次冷启动都撞一次）；
//   * 凭据解不开（换机）→ 预填账号，请用户补密码；
//   * 手动登录会落盘；登出会把落盘清掉（否则冷启动又自己登回去）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/e2ee/secret_keeper.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatStoreProvider;
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/saved_session.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

import 'support/chat_harness.dart';

/// 固定返回（或固定拒绝）一个预置连接，不碰网络
class _FakeConnectionService extends ConnectionService {
  _FakeConnectionService(this._connection, {this.failConnect = false});

  final DsmConnection Function() _connection;
  bool failConnect;
  int connects = 0;

  @override
  Future<DsmConnection> connect(
    ServerProfile profile, {
    void Function(ConnectStep)? onStep,
  }) async {
    connects++;
    if (failConnect) throw DsmTransportException('连不上 NAS');
    onStep?.call(const ConnectStep('直连命中 https://nas:5001'));
    return _connection();
  }
}

const _profile = ServerProfile(
  kind: ServerAddressKind.quickConnect,
  value: 'demo_admin-qq',
);

void main() {
  late InMemorySecretKeeper keeper;

  /// 起一套：内存库 + 假传输 + 假连接服务；并返回一个指向同一个库的
  /// [SavedSessionStore]，方便测试预置/检查落盘内容。
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

  SavedSessionStore storeOf(ChatHarness h) =>
      SavedSessionStore(h.container.read(chatStoreProvider), keeper: keeper);

  DsmSession seedOf(ChatHarness h) =>
      h.container.read(sessionControllerProvider).session!;

  test('没有保存过 → none，不联网，也不进主页', () async {
    final (:h, :service) = await boot();

    final result = await h.container
        .read(sessionControllerProvider.notifier)
        .restore();

    expect(result, AutoLoginResult.none);
    expect(service.connects, 0, reason: '没有记录就不该去连');
    expect(h.container.read(sessionControllerProvider).loggedIn, isFalse);
  });

  test('保存过 → 自动登录成功，did 作为 device_id 回传（免验证码）', () async {
    final (:h, :service) = await boot();
    await storeOf(h).save(
      SavedSession(
        profile: _profile,
        account: 'demo_user',
        password: 'pw',
        rememberDevice: true,
        deviceId: 'DID-1',
        lastBaseUrl: 'https://nas:5001/',
      ),
    );

    final result = await h.container
        .read(sessionControllerProvider.notifier)
        .restore();

    expect(result, AutoLoginResult.success);
    expect(service.connects, 1);
    final state = h.container.read(sessionControllerProvider);
    expect(state.loggedIn, isTrue);
    expect(state.autoLoginFailed, isFalse);
    expect(seedOf(h).sid, isNotEmpty);

    // 关键：登录请求里带回上次的 did + 免验证码开关
    final login = h.transport.calls.lastWhere(
      (c) => c['api'] == 'SYNO.API.Auth' && c['method'] == 'login',
    );
    expect(login['device_id'], 'DID-1');
    expect(login['session'], 'Chat');
    expect(login['device_name'], isNotNull);
  });

  test('连接失败 → connectFailed，未登录但地址还在（可预填）', () async {
    final (:h, :service) = await boot(failConnect: true);
    await storeOf(h).save(
      SavedSession(profile: _profile, account: 'demo_user', password: 'pw'),
    );

    final result = await h.container
        .read(sessionControllerProvider.notifier)
        .restore();

    expect(result, AutoLoginResult.connectFailed);
    final state = h.container.read(sessionControllerProvider);
    expect(state.loggedIn, isFalse);
    expect(state.saved?.profile.value, 'demo_admin-qq');
    // 真机缺陷回归（2026-09-22）：连接失败**只给用户语言**，
    // 绝不把异常原文 / 三方库类型名写进 `state.error`（那是连接页要显示的）。
    expect(state.error, contains('网络'));
    expect(state.error, isNot(contains('连不上 NAS')));
    expect(state.error, isNot(contains('DsmTransportException')));
    expect(service.connects, 1);
  });

  test('登录被拒（密码改了）→ loginFailed，并把落盘的密码清掉', () async {
    final (:h, :service) = await boot();
    await storeOf(h).save(
      SavedSession(
        profile: _profile,
        account: 'demo_user',
        password: 'pw',
        rememberDevice: true,
        deviceId: 'DID-1',
      ),
    );
    // 假传输：登录回 400（密码错）——注意 bootChat 里已经登录过一次，
    // 这里用 failures 让**之后**每一次登录都失败
    h.transport.failures['SYNO.API.Auth.login'] =
        DsmErrorCode.authInvalidPassword;

    final result = await h.container
        .read(sessionControllerProvider.notifier)
        .restore();

    expect(result, AutoLoginResult.loginFailed);
    final state = h.container.read(sessionControllerProvider);
    expect(state.autoLoginFailed, isTrue);
    expect(state.saved?.account, 'demo_user', reason: '账号留着预填');
    expect(state.saved?.password, isNull);
    // 落盘也要清掉密码，否则每次冷启动都拿它撞一次
    final onDisk = await storeOf(h).load();
    expect(onDisk!.password, isNull);
    expect(onDisk.account, 'demo_user');
    expect(onDisk.deviceId, 'DID-1', reason: 'did 不是密码错导致的，留着');
  });

  test('凭据解不开（换机/重装）→ needCredentials，账号仍可预填', () async {
    final (:h, :service) = await boot();
    // 用一把"能用"的 keeper 写盘
    await SavedSessionStore(
      h.container.read(chatStoreProvider),
      keeper: InMemorySecretKeeper(),
    ).save(
      SavedSession(
        profile: _profile,
        account: 'demo_user',
        password: 'pw',
        deviceId: 'DID-1',
      ),
    );
    // 再换成"密钥丢了"的 keeper 去读
    keeper = InMemorySecretKeeper(failOpen: true);

    final result = await h.container
        .read(sessionControllerProvider.notifier)
        .restore();

    expect(result, AutoLoginResult.needCredentials);
    final state = h.container.read(sessionControllerProvider);
    expect(state.loggedIn, isFalse);
    expect(state.saved?.account, 'demo_user');
    expect(state.saved?.password, isNull);
    expect(state.error, contains('重新输入密码'));
    expect(service.connects, 0, reason: '没凭据就别去连了');
  });

  test('手动登录会落盘；登出会把落盘清掉', () async {
    final (:h, :service) = await boot();
    final notifier = h.container.read(sessionControllerProvider.notifier);

    await notifier.connect(_profile);
    expect(
      await notifier.login(
        account: 'demo_user',
        password: 'pw',
        rememberDevice: true,
      ),
      isTrue,
    );

    final saved = await storeOf(h).load();
    expect(saved, isNotNull);
    expect(saved!.account, 'demo_user');
    expect(saved.password, 'pw');
    expect(saved.profile.value, 'demo_admin-qq');
    expect(saved.rememberDevice, isTrue);
    expect(saved.lastBaseUrl, 'https://nas:5001/', reason: '记住探通的地址');

    // 登录请求里也该出现"信任此设备"（服务端据此下发 did）——
    // 这里没有 OTP，所以按原库只发 device_name，did 由服务端在响应里给
    final login = h.transport.calls.lastWhere(
      (c) => c['api'] == 'SYNO.API.Auth' && c['method'] == 'login',
    );
    expect(login['device_name'], isNotNull);

    await notifier.logout();
    expect(await storeOf(h).load(), isNull, reason: '登出后不该再自动登回去');
    expect(h.container.read(sessionControllerProvider).loggedIn, isFalse);
  });

  test('登录响应里的 did 会存下来，下次登录回传（完整免验证码链路）', () async {
    final (:h, :service) = await boot();
    final notifier = h.container.read(sessionControllerProvider.notifier);

    // 第一次：带 OTP + 信任设备 → 服务端回 did（假传输照真服务端行为）
    await notifier.connect(_profile);
    expect(
      await notifier.login(
        account: 'demo_user',
        password: 'pw',
        otp: '123456',
        rememberDevice: true,
      ),
      isTrue,
    );

    final first = (await storeOf(h).load())!;
    expect(first.deviceId, 'FAKE-DID', reason: 'did 必须落盘');
    expect(first.otpBypassReady, isTrue);

    // 第二次（模拟冷启动重登）：带 did、不带 otp
    final result = await notifier.restore();
    expect(result, AutoLoginResult.success);
    final second = h.transport.calls
        .where((c) => c['api'] == 'SYNO.API.Auth' && c['method'] == 'login')
        .toList();
    expect(second.last['device_id'], 'FAKE-DID');
    expect(second.last['otp_code'], isNull, reason: '有 did 就不该再要验证码');
  });

  test('登录请求里 otp_code / enable_device_token 是明文参数（不进密文）', () async {
    final (:h, :service) = await boot();
    final notifier = h.container.read(sessionControllerProvider.notifier);
    await notifier.connect(_profile);
    await notifier.login(
      account: 'demo_user',
      password: 'pw',
      otp: '123456',
      rememberDevice: true,
    );

    final login = h.transport.calls.lastWhere(
      (c) => c['api'] == 'SYNO.API.Auth' && c['method'] == 'login',
    );
    expect(login['otp_code'], '123456');
    expect(login['enable_device_token'], 'yes');
    // 密文装在服务端下发的 cipherkey 字段里，且只有这一个字段
    const cipherField = '__cIpHeRtExT';
    expect(login.containsKey(cipherField), isTrue, reason: '凭据要走密文');
    expect(login[cipherField], isNot(contains('demo_user')));
    // 明文参数里不该混进 account / passwd
    expect(login.containsKey('account'), isFalse);
    expect(login.containsKey('passwd'), isFalse);
    // ⚠️ 这里**不再**断言 `isNot(contains('pw'))`：cipherkey 是**随机** base64，
    //   "pw" 只有 2 个字符，约 5% 的运行会偶然撞上（实测单测连跑 65 次命中 3 次），
    //   是条会随机变红的 flaky 断言。凭据真的进了密文这一点由上面 8 字符的
    //   `demo_user` 断言 + "只有这一个密文字段" + 明文参数里没有 account/passwd 共同保证。
  });
}
