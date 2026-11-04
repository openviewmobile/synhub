// 多 NAS / 多账号的**存储层**离线用例（接口层）。
//
// 覆盖任务要求里的接口面：
//   * 多配置的读写（两个 NAS / 两个账号各自独立）；
//   * 切换活动项；
//   * 迁移兼容（老的单条 `saved_session` 平滑升级，**不清空**）；
//   * sid/凭据隔离（改 B 不动 A 的密码与 did）；
//   * 移除当前项后回落到剩余项，且不连带删除别的配置；
//   * 配置损坏 / 部分缺失时**不得整体清空**。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/e2ee/e2ee_service.dart' show E2eeStore;
import 'package:synhub/src/data/e2ee/secret_keeper.dart';
import 'package:synhub/src/features/servers/nas_store.dart';
import 'package:synhub/src/features/servers/saved_session.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

/// 内存版键值表（`ChatStore` 的替身）。
class _MemStore implements E2eeStore {
  final Map<String, String> kv = {};

  @override
  Future<String?> setting(String key) async => kv[key];

  @override
  Future<void> setSetting(String key, String value) async => kv[key] = value;

  @override
  Future<void> deleteSetting(String key) async => kv.remove(key);
}

const _home = ServerProfile(
  kind: ServerAddressKind.quickConnect,
  value: 'demo_admin-qq',
  displayName: '家里的 NAS',
);
const _office = ServerProfile(
  kind: ServerAddressKind.direct,
  value: 'https://nas.office.example:5001',
  displayName: '办公室 NAS',
);

SavedSession _a({String account = 'demo_user', String? did = 'DID-A'}) =>
    SavedSession(
      profile: _home,
      account: account,
      password: 'pw-a',
      rememberDevice: true,
      deviceId: did,
      lastBaseUrl: 'https://nas.example.com:5001',
    );

SavedSession _b({String account = 'office-user', String? did = 'DID-B'}) =>
    SavedSession(
      profile: _office,
      account: account,
      password: 'pw-b',
      deviceId: did,
      lastBaseUrl: 'https://nas.office.example:5001',
    );

/// 老格式（单条）JSON，模拟"已经有单 NAS 用户"。
String _legacyJson({bool sealed = false, String secret = '{"password":"pw"}'}) {
  return jsonEncode({
    'v': 1,
    'kind': 'quickConnect',
    'value': 'demo_admin-qq',
    'display_name': '家里的 NAS',
    'account': 'demo_user',
    'secret': secret,
    'secret_sealed': sealed,
    'remember_device': true,
    'did': 'DID-OLD',
    'last_base_url': 'https://nas.example.com:5001',
  });
}

void main() {
  late _MemStore kv;
  late InMemorySecretKeeper keeper;

  setUp(() {
    kv = _MemStore();
    keeper = InMemorySecretKeeper();
  });

  NasStore store() => NasStore(kv, keeper: keeper);

  test('多配置读写：两个 NAS 各自独立，活动项是最后登录的那个', () async {
    final s = store();
    final first = await s.upsertActive(_a());
    final second = await s.upsertActive(_b());

    final snap = await s.load();
    expect(snap.configs, hasLength(2));
    expect(snap.activeId, second.id, reason: '最后写入的成为当前');
    expect(first.id, isNot(second.id), reason: '两条必须有不同的稳定 id');

    final gotA = snap.byId(first.id)!;
    final gotB = snap.byId(second.id)!;
    expect(gotA.profile.value, 'demo_admin-qq');
    expect(gotA.account, 'demo_user');
    expect(gotA.password, 'pw-a');
    expect(gotA.deviceId, 'DID-A');
    expect(gotB.profile.value, 'https://nas.office.example:5001');
    expect(gotB.account, 'office-user');
    expect(gotB.password, 'pw-b');
    expect(gotB.deviceId, 'DID-B');
  });

  test('切换活动项：setActive 落盘，loadActive 返回目标', () async {
    final s = store();
    final a = await s.upsertActive(_a());
    await s.upsertActive(_b());

    await s.setActive(a.id!);
    final active = await s.loadActive();
    expect(active!.id, a.id);
    expect(active.profile.value, 'demo_admin-qq');

    // 重新构造 store（模拟冷启动）也要读到同一个"当前"
    final reopened = await NasStore(kv, keeper: keeper).load();
    expect(reopened.activeId, a.id);
  });

  test('迁移兼容：老的单条记录 → 自动升级成一条，字段一个不丢', () async {
    kv.kv[NasStore.legacyKey] = _legacyJson(); // 只有老键，没有列表

    final snap = await store().load();

    expect(snap.configs, hasLength(1), reason: '老记录要成为列表里的第一条');
    final only = snap.configs.single;
    expect(only.id, isNotNull, reason: '迁移时补稳定 id');
    expect(only.profile.kind, ServerAddressKind.quickConnect);
    expect(only.profile.value, 'demo_admin-qq');
    expect(only.profile.displayName, '家里的 NAS');
    expect(only.account, 'demo_user');
    expect(only.password, 'pw', reason: '明文格式的凭据要读回来');
    expect(only.rememberDevice, isTrue);
    expect(only.deviceId, 'DID-OLD');
    expect(only.lastBaseUrl, 'https://nas.example.com:5001');
    expect(snap.activeId, only.id, reason: '迁移后它就是当前 NAS');

    // 迁移是"写入新格式"，不是删掉重来：老键仍留着同一台 NAS 的信息
    expect(kv.kv[NasStore.configsKey], isNotNull);
    final legacyAfter = kv.kv[NasStore.legacyKey];
    expect(legacyAfter, isNotNull, reason: '老键保留，不清空');
    expect(legacyAfter, contains('demo_admin-qq'));
    expect(legacyAfter, contains('demo_user'));
  });

  test('迁移兼容：老键是密文也要能解出来（有 Keystore 的场景）', () async {
    final plain = '{"password":"pw"}';
    final encoded = (await keeper.seal(plain))!;
    kv.kv[NasStore.legacyKey] = _legacyJson(sealed: true, secret: encoded);

    final snap = await store().load();
    expect(snap.configs.single.password, 'pw');
  });

  test('sid/凭据隔离：改 B 不动 A 的密码与 did', () async {
    final s = store();
    final a = await s.upsertActive(_a());
    await s.upsertActive(_b());

    // 再用 A 的地址/账号更新一次（模拟 A 重登拿到新 did）
    await s.upsertActive(_a(did: 'DID-A2'));

    final snap = await s.load();
    final gotA = snap.byId(a.id)!;
    final gotB = snap.configs.firstWhere(
      (c) => c.profile.value.startsWith('https://nas.office'),
    );
    expect(gotA.deviceId, 'DID-A2');
    expect(gotA.password, 'pw-a');
    expect(gotB.deviceId, 'DID-B', reason: '更新 A 不能碰到 B 的设备令牌');
    expect(gotB.password, 'pw-b', reason: '更新 A 不能碰到 B 的密码');
    expect(gotA.id, a.id, reason: '同 NAS 同账号重登仍是同一条');
    expect(snap.configs, hasLength(2));
  });

  test('同一台 NAS 上的两个账号 = 两条独立记录（多账号）', () async {
    final s = store();
    final one = await s.upsertActive(_a(account: 'demo_user'));
    final two = await s.upsertActive(_a(account: 'second-user', did: 'DID-A2'));

    final snap = await s.load();
    expect(snap.configs, hasLength(2), reason: '同 NAS 换账号要各存一条');
    expect(one.id, isNot(two.id));
    expect(snap.byId(one.id)!.account, 'demo_user');
    expect(snap.byId(two.id)!.account, 'second-user');
  });

  test('移除当前项 → 回落到剩余项，且绝不连带删除别的配置', () async {
    final s = store();
    final a = await s.upsertActive(_a());
    final b = await s.upsertActive(_b());
    expect((await s.load()).activeId, b.id);

    final after = await s.remove(b.id!);

    expect(after.configs, hasLength(1), reason: '只该少一条');
    expect(after.configs.single.id, a.id, reason: 'A 必须原样保留');
    expect(after.configs.single.password, 'pw-a');
    expect(after.activeId, a.id, reason: '当前项回落到剩余第一条');
  });

  test('移除"非当前"项 → 当前不变，其它配置保留', () async {
    final s = store();
    final a = await s.upsertActive(_a());
    final b = await s.upsertActive(_b());

    final after = await s.remove(a.id!);
    expect(after.configs.single.id, b.id);
    expect(after.activeId, b.id, reason: '删的不是当前，当前不该变');
  });

  test('坏一条不拖垮全部：跳过坏条目，其余照常读（不清空）', () async {
    final s = store();
    final a = await s.upsertActive(_a());
    await s.upsertActive(_b());

    // 手工把列表改成 [A 的好条目, 一条坏 JSON]
    final raw = jsonDecode(kv.kv[NasStore.configsKey]!) as Map<String, dynamic>;
    final items = List<dynamic>.from(raw['items'] as List);
    items.add('{这一条坏了');
    kv.kv[NasStore.configsKey] = jsonEncode({'v': 1, 'items': items});

    final snap = await s.load();
    expect(snap.partial, isTrue, reason: '要能报告"有坏条目"');
    expect(snap.configs, hasLength(2), reason: '好的两条必须还在');
    expect(snap.byId(a.id)!.password, 'pw-a');
  });

  test('整块数据坏掉 → 不覆写、不删除（原样留在存储里）', () async {
    kv.kv[NasStore.configsKey] = '{不是 json';
    kv.kv[NasStore.activeKey] = 'nas_x';

    final snap = await store().load();
    expect(snap.configs, isEmpty);
    expect(kv.kv[NasStore.configsKey], '{不是 json', reason: '坏块不能被覆写');
    expect(kv.kv[NasStore.activeKey], 'nas_x', reason: '别的键也不能被清');
  });

  test('部分缺失（缺地址）→ 只跳过这一条，不整体清空', () async {
    final s = store();
    final a = await s.upsertActive(_a());
    kv.kv[NasStore.configsKey] = jsonEncode({
      'v': 1,
      'items': [
        jsonEncode({'account': 'no-address'}),
        jsonEncode({
          'id': a.id,
          'kind': 'quickConnect',
          'value': 'demo_admin-qq',
          'account': 'demo_user',
          'secret': '{"password":"pw-a"}',
          'secret_sealed': false,
        }),
      ],
    });

    final snap = await s.load();
    expect(snap.configs, hasLength(1), reason: '缺地址的那条跳过，好的那条保留');
    expect(snap.configs.single.profile.value, 'demo_admin-qq');
    expect(snap.partial, isTrue);
  });

  test('active 指向不存在的条目 → 回落第一条，而不是清空', () async {
    final s = store();
    final a = await s.upsertActive(_a());
    kv.kv[NasStore.activeKey] = 'nas_不存在';

    final snap = await s.load();
    expect(snap.configs, hasLength(1));
    expect(snap.activeId, a.id, reason: '悬空的 activeId 要回落到现有条目');
  });

  test('重命名只改展示名：id 与凭据不动', () async {
    final s = store();
    final a = await s.upsertActive(_a());

    await s.rename(a.id!, '书房那台');

    final got = (await s.load()).byId(a.id)!;
    expect(got.profile.displayName, '书房那台');
    expect(got.id, a.id);
    expect(got.password, 'pw-a');
    expect(got.deviceId, 'DID-A');
    expect(got.profile.value, 'demo_admin-qq');
  });

  test('添加（只有地址）→ 新条目入列，账号为空，不抢当前', () async {
    final s = store();
    final a = await s.upsertActive(_a());

    final added = await s.add(_office, displayName: '办公室 NAS');
    final snap = await s.load();

    expect(snap.configs, hasLength(2));
    expect(snap.activeId, a.id, reason: '添加本身不改变当前');
    final got = snap.byId(added.id)!;
    expect(got.account, isEmpty);
    expect(got.password, isNull);
    expect(got.profile.displayName, '办公室 NAS');
  });

  test('登出：清掉当前条目的凭据并把"当前"置空，条目保留', () async {
    final s = store();
    final a = await s.upsertActive(_a());
    await s.upsertActive(_b());

    await s.clearActive();

    final snap = await s.load();
    expect(snap.activeId, isNull, reason: '登出后没有"当前"，冷启动不会自动登');
    expect(snap.configs, hasLength(2), reason: '两条配置都还在');
    final gotB = snap.configs.firstWhere((c) => c.id != a.id);
    expect(gotB.password, isNull, reason: '当前条目的凭据被清掉');
    expect(gotB.deviceId, isNull);
    expect(gotB.account, isNotEmpty, reason: '账号留着给登录页预填');
    expect(snap.byId(a.id)!.password, 'pw-a', reason: '非当前条目不受影响');
  });

  test('先"添加"再登录不会多出一条重复记录', () async {
    final s = store();
    final a = await s.upsertActive(_a());
    final placeholder = await s.add(_office, displayName: '办公室 NAS');

    // 登录成功后按"同地址、账号为空"补进那一条
    final loggedIn = await s.upsertActive(_b());

    final snap = await s.load();
    expect(snap.configs, hasLength(2), reason: '占位条目要被升级，而不是新增一条');
    expect(loggedIn.id, placeholder.id);
    expect(snap.byId(placeholder.id)!.account, 'office-user');
    expect(snap.byId(placeholder.id)!.password, 'pw-b');
    expect(snap.activeId, placeholder.id);
    expect(snap.byId(a.id)!.password, 'pw-a');
  });

  test('老入口 SavedSessionStore 与多 NAS 列表共用一份账', () async {
    final saved = SavedSessionStore(kv, keeper: keeper);
    await saved.save(_a());
    await saved.save(_b());

    // 老入口只认"当前那条"
    final current = await saved.load();
    expect(current!.profile.value, _office.value);

    // 列表里两条都在
    final snap = await saved.nas.load();
    expect(snap.configs, hasLength(2));
    expect(snap.activeId, current.id);

    await saved.clear();
    expect(await saved.load(), isNull, reason: '登出后老入口读不到会话');
    expect((await saved.nas.load()).configs, hasLength(2), reason: '但配置没被删');
  });
}
