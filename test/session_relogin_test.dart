// 会话过期自动重登（原版 `RetryInterceptor`）：请求拿到 119 → 重新登录 →
// **把原请求重放一次**，用户无感。
//
// 覆盖：
//   * 119 触发重登 + 重放，重放带的是**新** sid；
//   * **105 不再触发重登**（R6-6 真机实测：105 重登会滚成 712 次 `List` 的
//     重试风暴；105 是确定性失败，必须熔断成"只发一次请求"，见
//     `DsmErrorCode.retryLoginCodes` 注释）；
//   * 没装钩子 → 原样抛错（不会自己转圈）；
//   * 并发请求同时过期 → 只登一次（共享同一个重登 Future）；
//   * 重登拿到 400/401/408/409/410 → 透出该码并**永久**关掉自动重登；
//   * 未认证请求（`requiresAuth:false`）与 Auth/Encryption 自身不触发；
//   * `SessionController` 装上钩子后：用内存里的凭据重登、更新 state.session，
//     并让实时通道用新 sid 重建。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

import 'support/chat_harness.dart';

/// 用假传输建一个已登录的 api（login 走真 CGI 加密协议，假传输给真公钥）
Future<FakeTransport> _login(DsmWebApi api) async {
  await api.discover();
  await api.login(account: 'demo_user', password: 'pw', session: 'Chat');
  return api.transport as FakeTransport;
}

void main() {
  group('DsmWebApi 自动重登', () {
    test('119 → 重登一次并重放，重放带新 sid', () async {
      final t = FakeTransport();
      final api = DsmWebApi(t);
      await _login(api);
      final oldSid = api.session!.sid;

      var relogins = 0;
      api.onSessionExpired = () async {
        relogins++;
        await api.login(account: 'demo_user', password: 'pw', session: 'Chat');
      };

      // 频道列表第一次 119，之后正常
      t.failTimes['SYNO.Chat.Channel.list'] = DsmErrorCode.sidNotFound;
      final before = t.calls.length;
      final data = await api.call('SYNO.Chat.Channel', 'list');

      expect(relogins, 1, reason: '应当只重登一次');
      expect(data, isEmpty, reason: '重放拿到了正常响应');
      final after = t.calls
          .skip(before)
          .where((c) => c['api'] == 'SYNO.Chat.Channel')
          .toList();
      expect(after, hasLength(2), reason: '原始请求 + 重放各一次');
      expect(after.first['_sid'], oldSid);
      final newSid = api.session!.sid;
      expect(newSid, isNot(oldSid), reason: '假传输也会每次登录换 sid');
      expect(after.last['_sid'], newSid, reason: '重放必须带新 sid');
    });

    test('105(noPermission) **不再**触发重登：确定性失败 → 请求数有界（上限 1）', () async {
      // R6-6 真机实测：105 触发"重登+重放"会形成正反馈（每次重登换新 sid →
      // 文件列表 provider 重建 → 再 List → 又 105），单跑记到 **712 次 `List`**
      // （docs/device-verification.md §9.5）。105 是确定性失败（账号无权限），
      // 重登不会改变 → 直接熔断，**一条 105 只发一次请求**。
      final t = FakeTransport();
      final api = DsmWebApi(t);
      await _login(api);
      var relogins = 0;
      api.onSessionExpired = () async {
        relogins++;
        await api.login(account: 'demo_user', password: 'pw', session: 'Chat');
      };

      t.failures['SYNO.Chat.Channel.list'] = DsmErrorCode.noPermission;
      final before = t.calls.length;
      await expectLater(
        api.call('SYNO.Chat.Channel', 'list'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noPermission,
          ),
        ),
      );
      expect(relogins, 0, reason: '105 不该触发重登（R6 重试风暴的根因）');
      final after = t.calls
          .skip(before)
          .where((c) => c['api'] == 'SYNO.Chat.Channel')
          .length;
      expect(after, 1, reason: '重试次数必须有界：一条 105 只发 1 次请求');
    });

    test('119(sidNotFound) 仍按既有策略重登一次 + 重放（瞬时态保留）', () async {
      final t = FakeTransport();
      final api = DsmWebApi(t);
      await _login(api);
      var relogins = 0;
      api.onSessionExpired = () async {
        relogins++;
        await api.login(account: 'demo_user', password: 'pw', session: 'Chat');
      };

      t.failures['SYNO.Chat.Channel.list'] = DsmErrorCode.sidNotFound;
      final before = t.calls.length;
      await expectLater(
        api.call('SYNO.Chat.Channel', 'list'),
        throwsA(isA<DsmApiException>()),
      );
      expect(relogins, 1, reason: '119 是瞬时态：既有策略保留');
      final after = t.calls
          .skip(before)
          .where((c) => c['api'] == 'SYNO.Chat.Channel')
          .length;
      expect(after, 2, reason: '原始请求 + 重放各一次，上限恒为 2');
    });

    test('没有装钩子 → 原样抛 119，不自己转圈', () async {
      final t = FakeTransport();
      final api = DsmWebApi(t);
      await _login(api);
      t.failures['SYNO.Chat.Channel.list'] = DsmErrorCode.sidNotFound;
      await expectLater(
        api.call('SYNO.Chat.Channel', 'list'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.sidNotFound,
          ),
        ),
      );
    });

    test('并发过期 → 只登一次（共享重登 Future）', () async {
      final t = FakeTransport();
      final api = DsmWebApi(t);
      await _login(api);
      var relogins = 0;
      api.onSessionExpired = () async {
        relogins++;
        await api.login(account: 'demo_user', password: 'pw', session: 'Chat');
      };
      // 两个不同请求都过期一次
      t.failTimes['SYNO.Chat.Channel.list'] = DsmErrorCode.sidNotFound;
      t.failTimes['SYNO.Chat.User.list'] = DsmErrorCode.sidNotFound;
      await Future.wait([
        api.call('SYNO.Chat.Channel', 'list'),
        api.call('SYNO.Chat.User', 'list'),
      ]);
      expect(relogins, 1, reason: '同一个瞬间只该登一次');
    });

    test('重登本身 400 → 透出 400 且永久关掉自动重登', () async {
      final t = FakeTransport();
      final api = DsmWebApi(t);
      await _login(api);
      var relogins = 0;
      var lost = 0;
      api.onSessionLost = (_) => lost++;
      api.onSessionExpired = () async {
        relogins++;
        t.failures['SYNO.API.Auth.login'] = DsmErrorCode.authInvalidPassword;
        await api.login(account: 'demo_user', password: 'pw', session: 'Chat');
      };

      t.failTimes['SYNO.Chat.Channel.list'] = DsmErrorCode.sidNotFound;
      await expectLater(
        api.call('SYNO.Chat.Channel', 'list'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.authInvalidPassword,
          ),
        ),
      );
      expect(relogins, 1);
      expect(lost, 1, reason: '要通知上层"会话救不回来了"');
      expect(api.retryLoginDisabled, isTrue);

      // 再过期一次：不再尝试重登
      t.failTimes['SYNO.Chat.User.list'] = DsmErrorCode.sidNotFound;
      await expectLater(
        api.call('SYNO.Chat.User', 'list'),
        throwsA(isA<DsmApiException>()),
      );
      expect(relogins, 1, reason: '已经关掉自动重登');
    });

    test('重登失败但码不在"再登也没用"集合 → 保留原始 119', () async {
      final t = FakeTransport();
      final api = DsmWebApi(t);
      await _login(api);
      api.onSessionExpired = () async {
        t.failures['SYNO.API.Auth.login'] = DsmErrorCode.internalError;
        await api.login(account: 'demo_user', password: 'pw', session: 'Chat');
      };
      t.failTimes['SYNO.Chat.Channel.list'] = DsmErrorCode.sidNotFound;
      await expectLater(
        api.call('SYNO.Chat.Channel', 'list'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.sidNotFound,
          ),
        ),
      );
      expect(api.retryLoginDisabled, isFalse, reason: '不是"再登也没用"的码，下次还得试');
    });

    test('logout 必须带 _sid（否则服务端不会真注销这条会话）', () async {
      final t = FakeTransport();
      final api = DsmWebApi(t);
      await _login(api);
      final sid = api.session!.sid;
      await api.logout();
      final call = t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.API.Auth' && c['method'] == 'logout',
      );
      expect(call['_sid'], sid, reason: '要靠 _sid 告诉服务端注销哪条会话');
      expect(call['session'], 'Chat');
      expect(api.session, isNull, reason: '本地会话也要清掉');
    });

    test('未认证请求 / Auth / Encryption 自身不触发重登', () async {
      final t = FakeTransport();
      final api = DsmWebApi(t);
      await _login(api);
      var relogins = 0;
      api.onSessionExpired = () async => relogins++;

      t.failures['SYNO.API.Info.query'] = DsmErrorCode.sidNotFound;
      t.failures['SYNO.API.Auth.logout'] = DsmErrorCode.sidNotFound;
      await expectLater(
        api.call('SYNO.API.Info', 'query', requiresAuth: false),
        throwsA(isA<DsmApiException>()),
      );
      await expectLater(
        api.call('SYNO.API.Auth', 'logout', requiresAuth: false),
        throwsA(isA<DsmApiException>()),
      );
      expect(relogins, 0);
    });
  });

  group('SessionController 装上钩子', () {
    test('过期 → 用内存凭据重登、state.session 更新、实时通道重建', () async {
      late DsmConnection connection;
      final fakeService = _FixedConnectionService(() => connection);
      final h = await bootChat(
        moreOverrides: [
          connectionServiceProvider.overrideWithValue(fakeService),
        ],
      );
      connection = DsmConnection(
        api: h.api,
        endpoint: const ResolvedEndpoint(
          baseUrl: 'https://nas.example:5001',
          source: 'direct',
        ),
        profile: const ServerProfile(
          kind: ServerAddressKind.quickConnect,
          value: 'demo_admin-qq',
        ),
        dio: DioFactory.create(allowSelfSigned: true),
      );

      final session = h.container.read(sessionControllerProvider.notifier);
      await session.connect(connection.profile);
      final ok = await session.login(account: 'demo_user', password: 'pw');
      expect(ok, isTrue);
      final oldSid = h.container.read(sessionControllerProvider).session!.sid;

      // 让下一次频道列表 119
      h.transport.failTimes['SYNO.Chat.Channel.list'] =
          DsmErrorCode.sidNotFound;
      final data = await h.apiForTest.listChannels();

      final state = h.container.read(sessionControllerProvider);
      expect(state.session!.sid, isNot(oldSid), reason: 'sid 应当已经换新');
      expect(state.error, isNull);
      // 重放拿到了正常响应（假传输的默认频道列表）
      expect(data.map((c) => c.channelId), contains(5));
      // 新 sid 也进了之后的请求
      final last = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.Channel',
      );
      expect(last['_sid'], state.session!.sid);
    });
  });
}

/// 固定返回一个预置连接的 ConnectionService（不碰网络）
class _FixedConnectionService extends ConnectionService {
  _FixedConnectionService(this._connection);

  final DsmConnection Function() _connection;

  @override
  Future<DsmConnection> connect(
    ServerProfile profile, {
    void Function(ConnectStep)? onStep,
  }) async => _connection();
}
