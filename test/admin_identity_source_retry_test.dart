// ★★★ D7（P1）：会话身份的**三态语义 + 可重试**（AGENTS §2.0.7③ / §2.0.6②）。
//
// ## 缺陷（pass9 钉在 `s131` 的决定性一行）
// `AdminIdentityController.refresh()` 的 `catch` 把"解析失败"写成
// `AdminIdentity.unknown`（`source == unresolved`），**并且把 `_loadedFor`
// 一起写成本会话 key** ⇒
//   ① `unresolved` 同时表示"还在探测"和"探测失败"，外部无法区分；
//   ② 首次一失败就被缓存成"本会话已解析"，下一次 `refresh()` 直接
//      early-return ⇒ **失败后再也不重试**；真机上管理员也可能永远看不到管理入口
//      （fail-closed 不误放行，但会**误隐藏**）。
//
// ## 这组用例钉的是**机制量**（§2.0.30②），不是结果量
//   * `source` 的取值（`failed` ≠ `unresolved`）；
//   * 失败后**是否再次发起解析**（用"refresh 是否进入 AsyncLoading"量 ——
//     `refresh()` 一旦走解析路径就一定先置 `AsyncLoading`，early-return 则不会）；
//   * `_loadedFor` 是否被写死 —— 用上面那条"是否重试"间接量它。
//   **不**断言"界面上的管理入口出现了没"（那种结果量在缓存 bug 下也可能碰巧为真）。
//
// ## 反向验证
// 把 `catch` 里的 `_loadedFor = null;` 改回 `_loadedFor = key;` ⇒
// 本文件 `D7-2` **当场红**（原文见交付报告）。
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

/// 造一个**解析必失败**的权限画像（第一棒的 `.future` 直接抛）。
///
/// 为什么必须从第一棒注入：`_resolve()` 里第二棒
/// `normalUserIsAdminOrNull()` 的异常被它自己 catch 成 `null`，
/// 所以只有第一棒的 `.future` 抛出才能走到 `refresh()` 的 `catch`
/// —— 也就是 D7 要治的那条路。假画像**不是**在生产里制造故障，
/// 只是复现"首打失败"这一时序。
class _FailingEntitlement extends SessionEntitlementController {
  @override
  Future<SessionEntitlement> build() async {
    throw StateError('synthetic: entitlement probe failed');
  }
}

void main() {
  late DsmWebApi web;

  setUp(() {
    web = DsmWebApi(
      MockDsmTransport(MockDsmBackend(catalog: DsmCatalog.load())),
    );
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        authExtraApiProvider.overrideWithValue(AuthExtraApi(web)),
        sessionEntitlementProvider.overrideWith(_FailingEntitlement.new),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('★★★ D7-1（三态语义）：解析失败 ⇒ source=failed，不再与 unresolved 混用；'
      'isAdmin 仍 false（fail-closed 不变）', () async {
    final c = container();

    // 解析之前 = "还没解析"
    final before = await c.read(adminIdentityProvider.future);
    expect(
      before.source,
      AdminIdentitySource.unresolved,
      reason: 'build() 只给"还没解析"，深层解析发生在 refresh()',
    );

    await c.read(adminIdentityProvider.notifier).refresh(force: true);
    final id = await c.read(adminIdentityProvider.future);

    expect(
      id.source,
      AdminIdentitySource.failed,
      reason: '★★ D7：失败必须有**独立取值**，不能和"还在探测"共用 unresolved',
    );
    expect(id.source, isNot(AdminIdentitySource.unresolved));
    expect(id.isAdmin, isFalse, reason: '失败仍 fail-closed：不许"失败就放行"');
    // 门控仍只看 isAdminProvider（身份位在 Session；门控在 admin_gate.dart）
    expect(await c.read(isAdminProvider.future), isFalse);
  });

  test('★★★ D7-2（机制量）：解析失败后，**非 force** 的 refresh() 仍会再次发起解析'
      '（= 失败没把 `_loadedFor` 写死）', () async {
    final c = container();
    // 先等初次 build 结算（否则 build 的 AsyncLoading→AsyncData 会与
    // refresh 的 Data→AsyncLoading 抢占通知，量不准）。
    expect((await c.read(adminIdentityProvider.future)).source,
        AdminIdentitySource.unresolved);

    // 用"refresh 是否进入 AsyncLoading"数解析尝试次数：
    // `refresh()` 一旦走解析路径就必然先 `state = AsyncLoading`；
    // 若被 `_loadedFor` early-return，则不会产生新的 loading 转换。
    var loadingTransitions = 0;
    final sub = c.listen(adminIdentityProvider, (prev, next) {
      if (next is AsyncLoading) loadingTransitions++;
    });

    await c.read(adminIdentityProvider.notifier).refresh(force: true);
    final afterFirst = loadingTransitions;
    expect(afterFirst, greaterThanOrEqualTo(1), reason: '第一次确实发起了解析');
    expect((await c.read(adminIdentityProvider.future)).source,
        AdminIdentitySource.failed);

    // ★ 关键：**不带 force**。若失败把 `_loadedFor` 写死，
    //   这里会被 early-return 吃掉 ⇒ loadingTransitions 不涨。
    await c.read(adminIdentityProvider.notifier).refresh();

    expect(
      loadingTransitions,
      greaterThan(afterFirst),
      reason: '★★ D7 机制量：失败不许写死 `_loadedFor`，'
          '下一次 refresh() 必须再次尝试解析（否则首次一失败就永久停在未解析）',
    );
    expect(
      (await c.read(adminIdentityProvider.future)).source,
      AdminIdentitySource.failed,
      reason: '重试仍失败 ⇒ 继续如实报 failed（不是编成 unresolved，也不是放行）',
    );
    sub.close();
  });

  test('★★ D7-3（幂等仍在）：**成功解析后**同一会话重复 refresh() 不再重复解析', () async {
    // 成功路径的缓存语义不许被 D7 的改动破坏：_loadedFor 只在成功时写，
    // 成功之后非 force 的 refresh() 必须继续 early-return。
    final c = ProviderContainer(
      overrides: [
        authExtraApiProvider.overrideWithValue(AuthExtraApi(web)),
        sessionEntitlementProvider.overrideWith(_OkEntitlement.new),
      ],
    );
    addTearDown(c.dispose);

    var loadingTransitions = 0;
    final sub = c.listen(adminIdentityProvider, (prev, next) {
      if (next is AsyncLoading) loadingTransitions++;
    });

    await c.read(adminIdentityProvider.notifier).refresh(force: true);
    final afterFirst = loadingTransitions;
    expect((await c.read(adminIdentityProvider.future)).source,
        AdminIdentitySource.initData);

    await c.read(adminIdentityProvider.notifier).refresh();
    await c.read(adminIdentityProvider.notifier).refresh();

    expect(
      loadingTransitions,
      afterFirst,
      reason: '成功已缓存 ⇒ 非 force 的 refresh() 不许再解析（幂等语义不变）',
    );
    sub.close();
  });
}

/// 一次就给出结论的假画像（管理员）—— 用来验证"成功路径仍幂等"。
class _OkEntitlement extends SessionEntitlementController {
  @override
  Future<SessionEntitlement> build() async => const SessionEntitlement(
    appPrivilege: AppPrivilegeSignal.unavailable,
    isAdmin: true,
  );
}
