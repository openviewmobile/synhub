// ★★★ **登录后加载身份** 的验证（用户 2026-09-23 第 76 轮要求）
//
// 用户原话：
// 「`Desktop.Initdata` 可以作为整个 App 的全局用来判断是否管理员的接口吧，
//   在用户登陆成功之后调用」
//
// ## 这组用例要钉住的三件事
// 1. **登录成功后真的调了** `Desktop.Initdata`（不是"界面上碰巧显示了"）；
// 2. **只调一次**（缓存生效，不是每个门控各打一次）；
// 3. **登出后清空**（否则 A 的管理员身份留给 B —— 权限泄漏）。
//
// ## 为什么这组必须独立存在
// `admin_gate_test.dart` 用 `isAdminProvider.overrideWith(...)` 直接喂了答案，
// 它验证的是**显示语义**；本文件验证的是**身份从哪来、什么时候取、什么时候清**。
// 两者缺一，都可能是"界面对了但身份是假的"。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/admin/admin_identity.dart';

import 'package:synhub/src/data/auth_extra_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late MockDsmBackend backend;
  late DsmWebApi web;

  /// ★ 用 **Mock Server**（新规 B）：`MockDsmBackend` 按
  /// `tool/mock_dsm/catalog.json` 校验 api/method/version 三元组。
  setUp(() {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    web = DsmWebApi(MockDsmTransport(backend));
  });

  /// ⚠️ 必须先把能力表拿到手：`negotiate()` 依赖 `SYNO.API.Info`，
  /// 没 `discover()` 时它拿不到版本约束 ⇒ 通道直接判为不可用
  ///（本轮第一版就漏了这一步，表现为"请求发了但身份是 fallback"）。
  Future<void> ready({required bool admin}) async {
    await web.discover();
    await web.login(account: admin ? 'admin' : 'demo_user', password: 'x');
  }

  /// 统计 Initdata **真实发出**了几次 —— 直接数请求，
  /// 不数我们自己的状态变量（后者自证不了"到底调没调"）。
  int initDataCalls() => backend.requests
      .where((r) => '${r.params['api']}' == 'SYNO.Core.Desktop.Initdata')
      .length;

  void stubInitData(Map<String, dynamic> data) {
    backend.fixture('SYNO.Core.Desktop.Initdata', 'get', (p) {
      return {'success': true, 'data': data};
    });
  }

  /// 造一个**只覆盖身份通道**的容器（不必伪造整个会话连接）。
  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [authExtraApiProvider.overrideWithValue(AuthExtraApi(web))],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('AI1. ★★★ 登录成功后调用 Initdata（全局身份）', () {
    test('★★★ 管理员：`is_admin: true` ⇒ 全局是管理员，且**真的调了** Initdata', () async {
      await ready(admin: true);
      stubInitData({
        'is_admin': true,
        'support_wol': true,
        'support_findme': false,
        'hostname': 'my-nas',
        'serial_number': 'SN-1',
      });
      final c = container();
      await c.read(adminIdentityProvider.notifier).refresh(force: true);
      final id = await c.read(adminIdentityProvider.future);

      expect(
        initDataCalls(),
        greaterThanOrEqualTo(1),
        reason: '★★★ 用户的明确要求：登录成功后要调 `Desktop.Initdata` 判定是不是管理员',
      );
      expect(id.isAdmin, isTrue);
      expect(id.source, AdminIdentitySource.initData);
      // 与 is_admin **同一次响应**里的能力位
      expect(id.supportWol, isTrue);
      expect(id.supportFindme, isFalse);
      expect(id.hostname, 'my-nas');
      expect(id.serialNumber, 'SN-1');
    });

    test('★★★ 非管理员：`is_admin: false` ⇒ 全局不是管理员', () async {
      await ready(admin: false);
      stubInitData({'is_admin': false});
      final c = container();
      await c.read(adminIdentityProvider.notifier).refresh(force: true);
      final id = await c.read(adminIdentityProvider.future);
      expect(id.isAdmin, isFalse);
      expect(id.source, AdminIdentitySource.initData);
    });

    test('★★★ 身份通道是**纯读**的：本 API 调用集合 == {get}', () async {
      await ready(admin: true);
      stubInitData({'is_admin': true});
      final c = container();
      await c.read(adminIdentityProvider.notifier).refresh(force: true);
      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == 'SYNO.Core.Desktop.Initdata')
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs, {'get'});
    });
  });

  group('AI2. ★★★ 缓存语义：一次登录只打一次', () {
    test('★★★ 重复 `refresh()` **不会**重复打 Initdata', () async {
      await ready(admin: true);
      stubInitData({'is_admin': true});
      final c = container();
      await c.read(adminIdentityProvider.notifier).refresh(force: true);
      final first = initDataCalls();
      for (var i = 0; i < 3; i++) {
        await c.read(adminIdentityProvider.notifier).refresh();
      }
      expect(
        initDataCalls(),
        first,
        reason:
            '★★★ 身份是**全局缓存**：多个门控读同一份，'
            '不该每个入口都打一次接口（那是我们的实现缺陷）',
      );
    });

    test('★★ `force: true` 才重新打（切账号/手动重试用）', () async {
      await ready(admin: true);
      stubInitData({'is_admin': true});
      final c = container();
      await c.read(adminIdentityProvider.notifier).refresh(force: true);
      final first = initDataCalls();
      await c.read(adminIdentityProvider.notifier).refresh(force: true);
      expect(initDataCalls(), greaterThan(first));
    });
  });

  group('AI3. ★★★ 登出 ⇒ 立刻降级；Initdata 不可用 ⇒ 降级到 NormalUser', () {
    test('★★★ `clear()` 后不是管理员（权限不残留）', () async {
      await ready(admin: true);
      stubInitData({'is_admin': true});
      final c = container();
      await c.read(adminIdentityProvider.notifier).refresh(force: true);
      expect((await c.read(adminIdentityProvider.future)).isAdmin, isTrue);
      c.read(adminIdentityProvider.notifier).clear();
      expect(
        (await c.read(adminIdentityProvider.future)).isAdmin,
        isFalse,
        reason:
            '★★★ 登出必须清身份：否则 A 的管理员身份留给 B，'
            '非管理员就能看到管理入口 —— 权限泄露',
      );
    });

    test('★★★ Initdata 不可用（字段缺失）⇒ 落到 `NormalUser`', () async {
      await ready(admin: true);
      // 不注册 Initdata fixture ⇒ 通道可用但 `is_admin` 缺失 ⇒ 第一棒没结论
      backend.fixture('SYNO.Core.NormalUser', 'get', (p) {
        return {
          'success': true,
          'data': {'is_admin': true},
        };
      });
      final c = container();
      await c.read(adminIdentityProvider.notifier).refresh(force: true);
      final id = await c.read(adminIdentityProvider.future);
      expect(id.isAdmin, isTrue, reason: '★★★ 老服务器没有 Initdata 时仍要能判出管理员');
      expect(id.source, AdminIdentitySource.normalUser);
    });
  });
}
