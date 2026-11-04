// r698 / DA338：**凭据落盘永远不许挡住"已经登录成功"**（Linux 钥匙串弹窗把它变成了死等）。
//
// 现场（Linux 容器实测，2026-10-31）：
//   * 手动登录（没有已存会话）时 App 停在 `AUTHENTICATING`，`flutter test` 卡死 9 分钟；
//   * 抓根窗口像素 → 屏幕上盖着一个 GNOME 的
//     「Choose password for new keyring / An application wants to create a new
//      keyring called "Default keyring"」模态框；
//   * 原因：`flutter_secure_storage` 在 Linux 走 libsecret，默认 keyring 不存在时
//     这个调用**阻塞**（不是抛异常）⇒ `await _registry.upsertActive(...)` 永不返回，
//     登录按钮就一直"正在验证"。
//
// 判据：把 store 换成**永不完成**的 upsert，登录仍必须在 `persistWaitCap`
// 之后返回 `true`，且 `busy == false`、`error == null`、`saved == null`（没假装存好）。
// 反向验证：去掉 `_persist` 里的 `.timeout(...)`，本用例会超时变红。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/nas_store.dart';
import 'package:synhub/src/features/servers/saved_session.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

import 'support/chat_harness.dart';

/// 永不完成的 `upsertActive` —— 模拟"钥匙串弹窗把写盘挡在模态里"。
class _HangingNasStore extends NasStore {
  _HangingNasStore(super.store);

  int upserts = 0;

  @override
  Future<NasSnapshot> load() async => const NasSnapshot();

  @override
  Future<SavedSession> upsertActive(SavedSession s) {
    upserts++;
    return Completer<SavedSession>().future; // 永远不完成
  }
}

/// `load()` 正常（空列表）、`upsertActive()` 挂住。
class _HangingSessionStore extends SavedSessionStore {
  _HangingSessionStore(super.store);

  final _HangingNasStore hanging = _HangingNasStore(_NullStore());

  @override
  NasStore get nas => hanging;
}

/// 只满足 `E2eeStore` 三个方法的最小桩（本用例根本不读它）。
class _NullStore implements E2eeStore {
  @override
  Future<String?> setting(String key) async => null;

  @override
  Future<void> setSetting(String key, String value) async {}

  @override
  Future<void> deleteSetting(String key) async {}
}

/// 固定返回一条"已连上"的连接，不碰网络。
class _FakeConnectionService extends ConnectionService {
  _FakeConnectionService(this.makeConnection);

  final DsmConnection Function() makeConnection;

  @override
  Future<DsmConnection> connect(
    ServerProfile profile, {
    void Function(ConnectStep)? onStep,
  }) async => makeConnection();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('★ r698：钥匙串写盘挂住 ⇒ 登录照样在 3s 上限后成功（busy 落回 false）', () async {
    late _HangingSessionStore store;
    late ChatHarness h;
    // 闭包只会在 `sc.connect()` 时被调用 —— 那时 `h` 已就绪。
    final service = _FakeConnectionService(
      () => DsmConnection(
        api: h.api,
        endpoint: const ResolvedEndpoint(
          baseUrl: 'https://nas:5001/',
          source: 'lan',
        ),
        profile: const ServerProfile(
          kind: ServerAddressKind.direct,
          value: 'https://nas:5001/',
        ),
        dio: Dio(),
      ),
    );
    h = await bootChat(
      moreOverrides: [
        savedSessionStoreProvider.overrideWith(
          (ref) => store = _HangingSessionStore(_NullStore()),
        ),
        connectionServiceProvider.overrideWithValue(service),
      ],
    );

    final sc = h.container.read(sessionControllerProvider.notifier);
    await sc.connect(
      const ServerProfile(
        kind: ServerAddressKind.direct,
        value: 'https://nas:5001/',
      ),
    );
    final sw = Stopwatch()..start();
    final ok = await sc.login(account: 'a', password: 'b');
    sw.stop();

    final st = h.container.read(sessionControllerProvider);
    expect(ok, isTrue, reason: '落盘挂住不许把"已经登录成功"变成失败');
    expect(st.busy, isFalse, reason: 'AUTHENTICATING 必须落回，否则界面就是卡死');
    expect(st.error, isNull);
    expect(st.session, isNotNull);
    expect(
      sw.elapsed,
      lessThan(SessionController.persistWaitCap + const Duration(seconds: 3)),
      reason: '超过上限还没返回 ⇒ 界面会一直停在 AUTHENTICATING',
    );
    expect(store.hanging.upserts, 1, reason: '该写的还是写了（只是没等它完成）');
    expect(st.saved, isNull, reason: '落盘没完成 ⇒ 不许假装"已保存"');
  });
}
