// ★★★ D7 残留修复（P1）：身份的**自动重试触发点**（防请求风暴）。
//
// ## 残留缺陷
// `admin_identity.dart` 上一轮已把"解析失败"做成可重试的
// `AdminIdentitySource.failed` + `_loadedFor = null`（见
// `test/admin_identity_source_retry_test.dart`），但**没有人触发**：
// 登录那次 `refresh()` 失败后若无人再调，管理入口会一直隐藏
// —— 原缺陷只解除一半。
//
// ## 本轮补的两条触发（共用一份"每会话至多一次"预算）
// * ①首个管理员门控界面被查询时：`isAdminProvider` 结算见 `failed` ⇒ 自动补一次；
// * ②应用回到前台时：`app.dart` 的 lifecycle `resumed` 调
//   `AdminIdentityController.triggerAutoRetry()`。
//
// ## 断言口径（§2.0.30②）：钉**机制量**
// * "解析尝试数"= `adminIdentityProvider` 的 `AsyncLoading` 转换次数
//   （`refresh()` 一旦真走解析路径必先置 loading；被守卫吃掉则不会）；
// * `triggerAutoRetry()` 的返回值（true = 真的发起了这次重试）；
// * **不**钉"界面上管理入口出现了没"这类结果量。
//
// ## 反向验证（原文见交付报告）
// 去掉 `triggerAutoRetry()` 里的 `if (_autoRetried) return false;` 守卫 ⇒
// `D7-auto-2`（同一会话内不重复触发）**当场红**；随后恢复。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/entitlement/session_entitlement.dart';
import 'package:synhub/src/core/services/service_registry.dart'
    show AppPrivilegeSignal;
import 'package:synhub/src/data/auth_extra_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/admin/admin_identity.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

/// 永远失败的权限画像：复现"首打失败 ⇒ source=failed"。
class _FailingEntitlement extends SessionEntitlementController {
  @override
  Future<SessionEntitlement> build() async {
    throw StateError('synthetic: entitlement probe failed');
  }
}

/// 第一次失败、之后成功：验证"自动重试真的能恢复管理员结论"。
class _FlakyEntitlement extends SessionEntitlementController {
  static int calls = 0;

  @override
  Future<SessionEntitlement> build() async {
    calls++;
    if (calls == 1) throw StateError('synthetic: first probe fails');
    return const SessionEntitlement(
      appPrivilege: AppPrivilegeSignal.unavailable,
      isAdmin: true,
    );
  }
}

void main() {
  late DsmWebApi web;

  setUp(() {
    web = DsmWebApi(
      MockDsmTransport(MockDsmBackend(catalog: DsmCatalog.load())),
    );
  });

  ProviderContainer container({required SessionEntitlementController Function() entitlement}) {
    final c = ProviderContainer(
      overrides: [
        authExtraApiProvider.overrideWithValue(AuthExtraApi(web)),
        sessionEntitlementProvider.overrideWith(entitlement),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// 把容器推进到 `failed`（首打必然失败）。
  Future<void> toFailed(ProviderContainer c) async {
    expect(
      (await c.read(adminIdentityProvider.future)).source,
      AdminIdentitySource.unresolved,
    );
    await c.read(adminIdentityProvider.notifier).refresh(force: true);
    expect(
      (await c.read(adminIdentityProvider.future)).source,
      AdminIdentitySource.failed,
    );
  }

  test('★★★ D7-auto-1（机制量）：`failed` 后触发自动重试 ⇒ 解析尝试数 +1', () async {
    final c = container(entitlement: _FailingEntitlement.new);
    await toFailed(c);

    var attempts = 0;
    final sub = c.listen(adminIdentityProvider, (prev, next) {
      if (next is AsyncLoading) attempts++;
    });

    final triggered = c.read(adminIdentityProvider.notifier).triggerAutoRetry();
    expect(triggered, isTrue, reason: 'failed + 本会话未重试过 ⇒ 必须发起一次');
    await c.read(adminIdentityProvider.future);

    expect(attempts, 1, reason: '触发点必须真的换来一次解析（机制量）');
    expect(
      (await c.read(adminIdentityProvider.future)).source,
      AdminIdentitySource.failed,
      reason: '重试仍失败 ⇒ 如实保持 failed，不许放宽门控',
    );
    sub.close();
  });

  test('★★★ D7-auto-2（防风暴·机制量）：同一会话内**不重复触发**', () async {
    final c = container(entitlement: _FailingEntitlement.new);
    await toFailed(c);

    var attempts = 0;
    final sub = c.listen(adminIdentityProvider, (prev, next) {
      if (next is AsyncLoading) attempts++;
    });

    expect(c.read(adminIdentityProvider.notifier).triggerAutoRetry(), isTrue);
    await c.read(adminIdentityProvider.future);
    expect(attempts, 1);

    // 反复触发（等价于"门控界面反复被查询 / 反复回前台"）
    for (var i = 0; i < 5; i++) {
      expect(
        c.read(adminIdentityProvider.notifier).triggerAutoRetry(),
        isFalse,
        reason: '每会话至多一次：第 ${i + 2} 次触发必须被守卫吃掉',
      );
    }
    await c.read(adminIdentityProvider.future);

    expect(
      attempts,
      1,
      reason: '★ 防请求风暴：同一会话内解析尝试数不许超过 1 次自动重试',
    );
    sub.close();
  });

  test('★★★ D7-auto-3（触发点①）：管理员门控界面查询 `isAdminProvider` 即自动重试一次', () async {
    final c = container(entitlement: _FailingEntitlement.new);
    await toFailed(c);

    var attempts = 0;
    final sub = c.listen(adminIdentityProvider, (prev, next) {
      if (next is AsyncLoading) attempts++;
    });

    // 这就是"某个 AdminOnly / adminOnlyVisible / AdminPageGate 被首帧查询"
    expect(await c.read(isAdminProvider.future), isFalse, reason: '门控仍 fail-closed');
    // 让 isAdminProvider 里排的 microtask 跑掉，再等这次重试结算
    await Future<void>.microtask(() {});
    await c.read(adminIdentityProvider.future);
    expect(attempts, 1, reason: '触发点①必须自动补一次解析');

    // 再次查询门控不许再来第二发
    await c.read(isAdminProvider.future);
    await Future<void>.microtask(() {});
    await c.read(adminIdentityProvider.future);
    expect(attempts, 1, reason: '门控反复查询也不重复触发');
    sub.close();
  });

  test('★★ D7-auto-4：自动重试**成功** ⇒ 从 failed 恢复到管理员结论（门控随之放行）', () async {
    _FlakyEntitlement.calls = 0;
    final c = container(entitlement: _FlakyEntitlement.new);
    await toFailed(c);

    // ★ 用"门控查询"本身当触发点①：第一次问门控是 fail-closed（隐藏），
    //   同时自动补一次解析（这次会成功）⇒ 再问就放行。
    expect(await c.read(isAdminProvider.future), isFalse, reason: '失败期间 fail-closed');
    await Future<void>.microtask(() {});
    final after = await c.read(adminIdentityProvider.future);
    expect(after.source, AdminIdentitySource.initData, reason: '重试这次真的取到了结论');
    expect(after.isAdmin, isTrue);
    expect(
      await c.read(isAdminProvider.future),
      isTrue,
      reason: '自动重试的价值：管理员身份恢复后，管理入口不再被误隐藏',
    );
  });

  test('★★ D7-auto-5（不误触发）：还没解析（unresolved）时触发是 no-op', () async {
    final c = container(entitlement: _FailingEntitlement.new);
    expect(
      (await c.read(adminIdentityProvider.future)).source,
      AdminIdentitySource.unresolved,
    );
    var attempts = 0;
    final sub = c.listen(adminIdentityProvider, (prev, next) {
      if (next is AsyncLoading) attempts++;
    });
    expect(
      c.read(adminIdentityProvider.notifier).triggerAutoRetry(),
      isFalse,
      reason: '只有 failed 才是"需要重试"的信号；unresolved 不是',
    );
    expect(attempts, 0);
    sub.close();
  });
}
