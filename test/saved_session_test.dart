// 「上次登录」落盘（`SavedSessionStore`）的离线测试。
//
// 关注四件事：
//   1. 往返：存进去的东西能原样读回来（包括服务端发的 `did`）；
//   2. **凭据不能明文落盘**（有 Keystore 时必须封）；
//   3. 没有 Keystore（测试/桌面/老设备）→ 退回明文也要能存能读，不能因此丢功能；
//   4. 密文解不开（换机/重装/Keystore 密钥被清）→ **记录还在**（地址账号可预填），
//      但 `password == null`，于是"自动登录"会优雅降级成"请重输密码"。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/e2ee/e2ee_service.dart' show E2eeStore;
import 'package:synhub/src/data/e2ee/secret_keeper.dart';
import 'package:synhub/src/features/servers/saved_session.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

/// 内存版键值表（`ChatStore` 的替身；只用到 E2eeStore 这三个方法）
class _MemStore implements E2eeStore {
  final Map<String, String> kv = {};

  @override
  Future<String?> setting(String key) async => kv[key];

  @override
  Future<void> setSetting(String key, String value) async => kv[key] = value;

  @override
  Future<void> deleteSetting(String key) async => kv.remove(key);
}

SavedSession _sample({String? did = 'DID-1'}) => SavedSession(
  profile: const ServerProfile(
    kind: ServerAddressKind.quickConnect,
    value: 'demo_admin-qq',
    displayName: '家里的 NAS',
  ),
  account: 'demo_user',
  password: 'pw-secret',
  rememberDevice: true,
  deviceId: did,
  lastBaseUrl: 'https://nas.example.com:5001',
);

void main() {
  _r707PlaintextMigrationTests();
  test('往返：服务器/账号/凭据/did/上次地址都读得回来（OTP 不落盘）', () async {
    final kv = _MemStore();
    final store = SavedSessionStore(kv, keeper: InMemorySecretKeeper());

    await store.save(_sample());
    final got = await store.load();

    expect(got, isNotNull);
    expect(got!.profile.kind, ServerAddressKind.quickConnect);
    expect(got.profile.value, 'demo_admin-qq');
    expect(got.profile.displayName, '家里的 NAS');
    expect(got.account, 'demo_user');
    expect(got.password, 'pw-secret');
    expect(got.rememberDevice, isTrue);
    expect(got.deviceId, 'DID-1');
    expect(got.lastBaseUrl, 'https://nas.example.com:5001');
    expect(got.canAutoLogin, isTrue);
    expect(got.otpBypassReady, isTrue);
    expect(
      kv.kv[SavedSessionStore.storageKey]!.contains('123456'),
      isFalse,
      reason: '一次性验证码不该被存下来（原库发完就清空）',
    );
  });

  test('有 Keystore 时凭据是密文落盘（明文不出现在存储里）', () async {
    final kv = _MemStore();
    final keeper = InMemorySecretKeeper();
    final store = SavedSessionStore(kv, keeper: keeper);

    await store.save(_sample());
    final raw = kv.kv[SavedSessionStore.storageKey]!;

    expect(keeper.seals, 1, reason: '凭据要经过封壳');
    expect(raw.contains('pw-secret'), isFalse, reason: '密码不能明文落盘');
    expect(raw.contains('"secret_sealed":true'), isTrue);
    // 非机密部分照旧可读（预填要用）
    expect(raw.contains('demo_admin-qq'), isTrue);
    expect(raw.contains('DID-1'), isTrue);
  });

  test('没有 Keystore → 退回明文，功能不能因此失效', () async {
    final kv = _MemStore();
    final store = SavedSessionStore(kv, keeper: const NoopSecretKeeper());

    await store.save(_sample());
    expect(
      kv.kv[SavedSessionStore.storageKey]!.contains('"secret_sealed":false'),
      isTrue,
    );

    final got = await store.load();
    expect(got!.password, 'pw-secret', reason: '明文分支也要能自动登录');
    expect(got.canAutoLogin, isTrue);
  });

  test('密文解不开（换机/重装）→ 记录还在，但没有密码', () async {
    final kv = _MemStore();
    final keeper = InMemorySecretKeeper();
    await SavedSessionStore(kv, keeper: keeper).save(_sample());

    // 新设备：Keystore 里没有这把密钥
    final broken = InMemorySecretKeeper(failOpen: true);
    final got = await SavedSessionStore(kv, keeper: broken).load();

    expect(got, isNotNull, reason: '地址/账号要留着给登录页预填');
    expect(got!.account, 'demo_user');
    expect(got.profile.value, 'demo_admin-qq');
    expect(got.deviceId, 'DID-1', reason: 'did 不是机密，跟着记录走');
    expect(got.password, isNull);
    expect(got.canAutoLogin, isFalse);
  });

  test('没存过 / 坏数据 → null（不能把启动流程卡死）', () async {
    final kv = _MemStore();
    final store = SavedSessionStore(kv, keeper: InMemorySecretKeeper());
    expect(await store.load(), isNull);

    kv.kv[SavedSessionStore.storageKey] = '{不是 json';
    expect(await store.load(), isNull);

    kv.kv[SavedSessionStore.storageKey] = '{"account":"a"}'; // 缺 profile
    expect(await store.load(), isNull);
  });

  test('clear() → 忘掉上次登录（登出用）', () async {
    final kv = _MemStore();
    final store = SavedSessionStore(kv, keeper: InMemorySecretKeeper());
    await store.save(_sample());
    await store.clear();
    expect(await store.load(), isNull);
  });

  test('免验证码是否真的就绪：要"勾了开关 + 有 did"', () async {
    final kv = _MemStore();
    final store = SavedSessionStore(kv, keeper: InMemorySecretKeeper());

    await store.save(_sample(did: null));
    final noDid = (await store.load())!;
    expect(noDid.otpBypassReady, isFalse, reason: '没拿到 did 就免不了验证码');

    await store.save(_sample());
    expect((await store.load())!.otpBypassReady, isTrue);
  });
}

// ── r707：**遗留明文行**必须在读取时被封掉（guest 库里实测存在这种行）──────
//
// 证据：`C:\Users\dev\Documents\synhub.sqlite` 里同时有
// `secret_sealed":true`（新行）与 `secret_sealed":false` + 明文口令（旧行）。
// 只翻能力位不改历史行 = 明文永远留在盘上。两条用例：
//   ① 读一次就把明文行重封（存储里再也找不到明文口令）；
//   ② 重封之后**旧口令仍然读得回来**（迁移不许弄丢凭据）。
void _r707PlaintextMigrationTests() {
  test('r707 遗留明文行：读完立刻重封（存储里不再有明文口令）', () async {
    final kv = _MemStore();
    kv.kv[SavedSessionStore.storageKey] = jsonEncode({
      'v': 4,
      'kind': 'lan',
      'value': 'nas.example.com:5001',
      'display_name': '家里那台',
      'account': 'demo_user',
      'secret': jsonEncode({'password': 'pw-legacy-plain'}),
      'secret_sealed': false,
      'remember_device': true,
      'did': 'DID-7',
    });
    final keeper = InMemorySecretKeeper();
    final store = SavedSessionStore(kv, keeper: keeper);

    final got = await store.load();
    expect(got, isNotNull);
    expect(got!.password, 'pw-legacy-plain', reason: '迁移不许弄丢凭据');

    final raw = kv.kv[SavedSessionStore.storageKey]!;
    expect(raw.contains('pw-legacy-plain'), isFalse,
        reason: '重封后存储里不许再有明文口令');
    expect(raw.contains('"secret_sealed":true'), isTrue);
    expect(keeper.seals, greaterThanOrEqualTo(1));
  });
}
