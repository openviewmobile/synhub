// ★★★ **管理员身份通道**（用户 2026-09-23 新规 · 第 71 轮）
//
// ## 为什么先做这个
// 新规要求：**管理员功能必须实现，且按身份门控** ——
// 非管理员登录时**隐藏**、管理员登录时**展示**。
// 门控的前提是"客户端知道当前用户是不是管理员"。
// 本轮实测：本仓**没有**全局 admin 身份（唯一一处是 `note_dto.dart` 里的
// 笔记专属 `isAdmin`）⇒ 先把这个地基铺上，否则写不出正确的门控界面。
//
// ## 权威依据
// | 来源 | 事实 |
// |---|---|
// | `tool/mock_dsm/catalog.json` | `SYNO.Core.NormalUser`：`min 1 / max 2`，**v1 只有 `get`**，v2 才有 `set`；`adminOnly: false` |
// | 本仓先例 `note_dto.dart:841` | `SYNO.NoteStation.Info/get` 的响应字段就叫 **`is_admin`** ⇒ 是 DSM 通用字段名 |
// | 官方桌面 JS `dsm.desktop.bundle.js` | `is_admin` 是全局身份位（用于门控管理入口） |
//
// ⚠️ **尚未直证的一点**：`NormalUser:get` 的响应里确实有 `is_admin`
// —— 本轮**没能在真 NAS 上验**（凭据登录返回 `402`）。所以下面的用例
// 钉的是**我们的解析契约**与**兜底方向**，不是"真机证实了字段名"。
//
// ## 兜底方向（最重要的一条）
// 字段缺失/类型不对 ⇒ **`false`**（当普通用户）。
// 宁可少显示管理功能，**也不能**把普通用户当管理员 —— 后者会把管理入口
// 摆到非管理员面前，点进去吃 `105`，正是新规 R2 要避免的。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/auth_extra_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

const _api = 'SYNO.Core.NormalUser';

void main() {
  late MockDsmBackend backend;
  late DsmWebApi web;

  Future<void> boot({required bool admin, Map<String, dynamic>? data}) async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: admin ? 'admin' : 'demo_user', admin: admin);
    backend.fixture(_api, 'get', (p) => {'success': true, 'data': data ?? {}});
    web = DsmWebApi(MockDsmTransport(backend));
    await web.discover();
    await web.login(account: admin ? 'admin' : 'demo_user', password: 'x');
  }

  Map<String, dynamic> lastParams() {
    final r = backend.requests
        .where((r) => '${r.params['api']}' == _api)
        .toList();
    expect(r, isNotEmpty, reason: '必须真的发出了 $_api/get');
    return r.last.params;
  }

  group('AD1. 契约：走 v1 的 `get`，不带任何写动词', () {
    test('★★ 只调 `get` v1，且**不发** `set`（v2 的写动词本仓不做）', () async {
      await boot(admin: true, data: {'is_admin': true});
      final ok = await AuthExtraApi(web).normalUserIsAdmin();
      expect(ok, isTrue);
      final p = lastParams();
      expect(p['method'], 'get');
      expect(
        '${p['version']}',
        '1',
        reason:
            '★ `.lib` 里 `get` 在 v1 就有；v2 只多一个 `set`（写动词）'
            '⇒ 没有任何理由上 v2',
      );
    });

    test('★ `_sid` 必须带上（身份查询是登录态接口）', () async {
      await boot(admin: true, data: {'is_admin': true});
      await AuthExtraApi(web).normalUserIsAdmin();
      expect(lastParams().containsKey('_sid'), isTrue);
    });

    test('★★★ 全程**零写动词**（新规 §5.1 对本族的声明）', () async {
      await boot(admin: true, data: {'is_admin': true});
      await AuthExtraApi(web).normalUserIsAdmin();
      const blacklist = {
        'set',
        'delete',
        'create',
        'update',
        'add',
        'remove',
        'clear',
        'stop',
        'start',
        'move',
        'copy',
        'upload',
        'cancel',
        'rename',
        'replace',
        'edit',
        'apply',
        'restore',
        'save',
        'avoid',
        'init',
        'import',
        'export',
        'refresh',
      };
      // 只统计**本 API** 的调用（登录/能力发现属另外的 API，不算本族）
      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == _api)
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(
        verbs.intersection(blacklist),
        isEmpty,
        reason:
            '★★★ 身份通道**必须**是纯读的：它会在每次登录后被调用，'
            '一旦掺进写动词，登录就变成了"改服务器"',
      );
      expect(verbs, {'get'}, reason: '实测调用集合应只有 get');
    });
  });

  group('AD2. ★★★ 兜底方向：缺失/异常一律当**普通用户**', () {
    test('★★★ 字段缺失 ⇒ `false`（不是 true、不是抛异常）', () async {
      await boot(admin: false, data: {'username': 'demo_user'});
      expect(
        await AuthExtraApi(web).normalUserIsAdmin(),
        isFalse,
        reason:
            '★★★ 方向性错误必须选**安全**那一边：'
            '当普通用户 ⇒ 少显示管理入口；'
            '当管理员 ⇒ 把管理入口摆给无权用户，点进去吃 105。'
            '后者正是新规 R2 要杜绝的',
      );
    });

    test('★★ `is_admin: false` 明确为假 ⇒ `false`', () async {
      await boot(admin: false, data: {'is_admin': false});
      expect(await AuthExtraApi(web).normalUserIsAdmin(), isFalse);
    });

    test('★★ 类型不对（字符串 `"true"` / 数字 `1`）⇒ **不**当成真', () async {
      // 服务端按约定回布尔；回字符串是**异常形态**。
      // 若这里"聪明"地做宽松转换，一旦字段语义变了就会静默放行管理员入口。
      await boot(admin: false, data: {'is_admin': 'true'});
      expect(await AuthExtraApi(web).normalUserIsAdmin(), isFalse);
      await boot(admin: false, data: {'is_admin': 1});
      expect(await AuthExtraApi(web).normalUserIsAdmin(), isFalse);
    });

    test('★ 空 data ⇒ `false`，不崩', () async {
      await boot(admin: false, data: {});
      expect(await AuthExtraApi(web).normalUserIsAdmin(), isFalse);
    });
  });

  group('AD3. ★★★ Mock 双档（新规 B1：管理员接口必须走 Mock 验证）', () {
    test('★★★ 管理员登录 ⇒ `true`', () async {
      await boot(admin: true, data: {'is_admin': true});
      expect(
        await AuthExtraApi(web).normalUserIsAdmin(),
        isTrue,
        reason: '新规 R3：管理员登录后管理功能必须能正常展示 ⇒ 身份必须先为 true',
      );
    });

    test('★★★ 非管理员登录 ⇒ `false`', () async {
      await boot(admin: false, data: {'is_admin': false});
      expect(
        await AuthExtraApi(web).normalUserIsAdmin(),
        isFalse,
        reason:
            '新规 R2：非管理员必须看到**隐藏**的管理功能，'
            '所以身份必须是 false',
      );
    });

    test('★★ 非管理员调 **adminOnly** 接口 ⇒ `105`（真机会发生的事）', () async {
      // 这不是身份通道本身，而是**门控要防的那个后果**：
      // 如果身份判错（false 判成 true），界面就会把入口摆出来，
      // 用户点进去后拿到的就是这个 105。
      await boot(admin: false, data: {'is_admin': false});
      // `SYNO.ActiveInsight.Package/get_status` 在 .lib 里是 admin-only
      try {
        await AuthExtraApi(web).activeInsightEnabled();
        fail('非管理员不该成功调用 adminOnly 接口');
      } catch (e) {
        final code = '$e'.contains('105') || '$e'.contains('noPermission');
        expect(code, isTrue, reason: '★ 应当拿到 105（无权限）。异常原文：$e');
      }
    });
  });

  group('AD4. ★★★ 第 254 轮：`105` 探测**已删除**（用户 2026-09-25 指令）', () {
    test('★★★ 身份链一份都不打 `SYNO.Core.System`（旧第三棒的接口）', () async {
      await boot(admin: false, data: {});
      expect(await AuthExtraApi(web).resolveIsAdmin(), isFalse);
      expect(
        backend.requests.any((r) => '${r.params['api']}' == 'SYNO.Core.System'),
        isFalse,
        reason:
            '★★★ 旧实现会**故意**打 adminOnly 的 `Core.System/info`，把 `105` '
            '读成"不是管理员"。用户 2026-09-25 要求：「用你推荐的方式改掉之前用 '
            '105 探测的办法」⇒ 身份与权限只认服务端**下发**的画像'
            '（`Session.is_admin` / `AppPrivilege`），不再拿"被拒绝"反推权限',
      );
    });

    test('★★★ `Initdata` 给了身份 ⇒ 不碰 `Core.System`，也不问 `NormalUser`', () async {
      backend = MockDsmBackend(catalog: DsmCatalog.load());
      backend.login(username: 'admin', admin: true);
      backend.fixture(
        'SYNO.Core.Desktop.Initdata',
        'get',
        (p) => {
          'success': true,
          'data': {
            'Session': {'is_admin': true, 'user': 'admin'},
            'AppPrivilege': {'SYNO.SDS.Chat.Application': true},
          },
        },
      );
      web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      await web.login(account: 'admin', password: 'x');

      expect(await AuthExtraApi(web).resolveIsAdmin(), isTrue);
      final apis = backend.requests
          .map((r) => '${r.params['api']}')
          .where(
            (a) =>
                a == 'SYNO.Core.System' ||
                a == _api ||
                a == 'SYNO.Core.Desktop.Initdata',
          )
          .toSet();
      expect(
        apis,
        {'SYNO.Core.Desktop.Initdata'},
        reason: '★★★ 第一棒给出明确答案后，既不该探测、也不该问第二棒',
      );
    });
  });

  group('AD5. ★★★ 合并判定 `resolveIsAdmin()`：便宜的在前，兜底在后', () {
    test('★★★ 字段说"是" ⇒ 直接采信（不去探测，省一次调用）', () async {
      await boot(admin: true, data: {'is_admin': true});
      expect(await AuthExtraApi(web).resolveIsAdmin(), isTrue);
      expect(
        backend.requests.any((r) => '${r.params['api']}' == 'SYNO.Core.System'),
        isFalse,
        reason: '★ 字段已给出明确答案时不该再多打一次服务端',
      );
    });

    test('★★★ 字段说"不是" ⇒ 采信，也不探测', () async {
      await boot(admin: false, data: {'is_admin': false});
      expect(await AuthExtraApi(web).resolveIsAdmin(), isFalse);
      expect(
        backend.requests.any((r) => '${r.params['api']}' == 'SYNO.Core.System'),
        isFalse,
      );
    });

    test('★★★ 字段**缺失** ⇒ `false`（**不再**降级到 `105` 探测）', () async {
      await boot(admin: true, data: {'username': 'admin'});
      expect(
        await AuthExtraApi(web).resolveIsAdmin(),
        isFalse,
        reason:
            '★★ 旧实现此时会去打 adminOnly 接口、把"调用成功"读成管理员 —— '
            '在 Mock/代理/任何"成功但无权限信息"的环境下都会误判。'
            '第 254 轮起改为：字段与另一条通道都没有结论 ⇒ 当普通用户'
            '（fail-closed，宁可少显示管理入口）',
      );
      expect(
        backend.requests.any((r) => '${r.params['api']}' == 'SYNO.Core.System'),
        isFalse,
        reason: '★ 无结论 ≠ 去探测',
      );
    });

    test('★★★ 两者都无结论 ⇒ `false`（安全方向）', () async {
      // 字段类型不对 + 探测拿到非 105 的错误（这里用"方法不存在"模拟）
      await boot(admin: false, data: {'is_admin': 'true'});
      final api = AuthExtraApi(web);
      // 把探测目标换成不存在的版本组合不好造，这里直接验证
      // "非 105 的错误 ⇒ null" 这条分支的行为契约：
      expect(
        await api.normalUserIsAdminOrNull(),
        isNull,
        reason: '类型不对 ⇒ 必须报"不知道"，而不是硬判 true/false',
      );
      expect(
        await api.resolveIsAdmin(),
        isFalse,
        reason:
            '★ 最终无结论时取 `false`：宁可少显示管理功能，'
            '也不能把管理入口摆给无权用户',
      );
    });
  });

  group('AD6. ★★★ 官方 DS finder 通道：`Desktop.Initdata`（第 75 轮 smali 实证）', () {
    /// 注册 Initdata 的响应（`is_admin` 等能力位）。
    void initFixture(Map<String, dynamic> data) {
      backend.fixture('SYNO.Core.Desktop.Initdata', 'get', (p) {
        return {'success': true, 'data': data};
      });
    }

    Future<void> bootInit({
      required bool admin,
      Map<String, dynamic>? init,
      Map<String, dynamic>? normal,
    }) async {
      await boot(admin: admin, data: normal ?? {});
      if (init != null) initFixture(init);
    }

    test('★★★ `Initdata.is_admin` 为真 ⇒ `true`，且**优先于** `NormalUser`', () async {
      await bootInit(
        admin: true,
        init: {'is_admin': true},
        normal: {'is_admin': false},
      );
      expect(
        await AuthExtraApi(web).resolveIsAdmin(),
        isTrue,
        reason:
            '★★★ 官方 DS finder 走的就是 Initdata；'
            '两条通道**冲突**时必须采信官方那条，否则"对齐官方"无从谈起',
      );
      expect(
        backend.requests.any((r) => '${r.params['api']}' == _api),
        isFalse,
        reason: '★ 第一棒给出明确答案后，不该再去问第二棒',
      );
    });

    test('★★★ `Initdata` 里 `is_admin: false` ⇒ `false`（且不越级到探测）', () async {
      await bootInit(
        admin: false,
        init: {'is_admin': false},
        normal: {'is_admin': true},
      );
      expect(await AuthExtraApi(web).resolveIsAdmin(), isFalse);
      expect(
        backend.requests.any((r) => '${r.params['api']}' == 'SYNO.Core.System'),
        isFalse,
        reason: '★ 已拿到明确答案就不该继续往下降级',
      );
    });

    test('★★★ Initdata **不可用**（方法不存在 ⇒ 103）⇒ 自动降级到 `NormalUser`', () async {
      await bootInit(admin: true, normal: {'is_admin': true});
      // 不注册 initFixture ⇒ Mock 对该方法返回 `{'success':true,'data':{}}`
      // ⇒ `is_admin` 缺失 ⇒ 第一棒返回 null ⇒ 必须**继续降级**
      expect(
        await AuthExtraApi(web).resolveIsAdmin(),
        isTrue,
        reason:
            '★★★ 接力链的意义：老服务器没有 Initdata 时，'
            '仍要能判出管理员（本仓 NormalUser 通道已实现）',
      );
      expect(
        backend.requests.any((r) => '${r.params['api']}' == _api),
        isTrue,
        reason: '★ 第一棒没结论时**必须**真的去问第二棒',
      );
    });

    test('★★ Initdata 的 `is_admin` 类型不对 ⇒ 不采信，继续降级', () async {
      await bootInit(
        admin: true,
        init: {'is_admin': 'true'},
        normal: {'is_admin': true},
      );
      expect(
        await AuthExtraApi(web).resolveIsAdmin(),
        isTrue,
        reason: '★ 第一棒给了垃圾值 ⇒ 视为"不知道"，由第二棒定夺',
      );
    });

    test('★★★ Initdata 通道是**纯读**的：本 API 调用集合 == {get}', () async {
      await bootInit(admin: true, init: {'is_admin': true});
      await AuthExtraApi(web).resolveIsAdmin();
      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == 'SYNO.Core.Desktop.Initdata')
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(
        verbs,
        {'get'},
        reason:
            '★★★ `.lib` 里这个 API 的 v1 还有 `get_user_service` / '
            '`get_ui_config` / `get_user_lang` —— 全是读；'
            '身份查询会在每次登录后跑，绝不许掺变更动词',
      );
    });

    test(
      '★★★ 能力位：`support_wol` / `support_findme` 可读（DS finder 同款门控）',
      () async {
        await bootInit(
          admin: true,
          init: {
            'is_admin': true,
            'support_wol': true,
            'support_findme': false,
            'hostname': 'nas',
            'serial_number': 'SN123',
          },
        );
        final api = AuthExtraApi(web);
        expect(await api.initDataCapability('support_wol'), isTrue);
        expect(await api.initDataCapability('support_findme'), isFalse);
        expect(
          await api.initDataCapability('nonexistent'),
          isNull,
          reason:
              '★ 能力位拿不到时返回 `null`，**不要**用 false 冒充"不支持" '
              '—— 那会让弱网下功能凭空消失',
        );
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════
  // AM1. ★★★ 自适应 MFA「游客连接建议」——官方**登录流程**里的一步
  //
  // 依据（两来源互证）：
  //  ① 官方 `SynologyChat 2.11.1-607` smali
  //     `com/synology/sylibx/login/api/SuggestConnWebApi.smali`：
  //     `path=SYNO.SecureSignIn.AMFA.SuggestConn, method="get", version=0x1`；
  //  ② `SecureSignIn-x86_64-1.1.5-0362.spk` 的
  //     `webapi/amfa/SYNO.SecureSignIn.AMFA.lib`：`v1: ['get']`，
  //     `allowUser` 含 `normal.*`。
  // ══════════════════════════════════════════════════════════════════════
  group('AM1. AMFA SuggestConn（登录兼容性）', () {
    Future<void> bootAmfa({
      required bool admin,
      Map<String, dynamic>? data,
    }) async {
      backend = MockDsmBackend(catalog: DsmCatalog.load());
      backend.login(username: admin ? 'admin' : 'demo_user', admin: admin);
      backend.fixture(
        kAmfaSuggestConnApi,
        'get',
        (p) => {'success': true, 'data': data ?? {}},
      );
      web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      await web.login(account: admin ? 'admin' : 'demo_user', password: 'x');
    }

    test(
      '★★★ 走 v1 的 `get`，且**普通用户也能调**（.lib 的 allowUser 含 normal.*）',
      () async {
        await bootAmfa(admin: false, data: {'suggest': 'guest'});
        final r = await AuthExtraApi(web).suggestConn();
        expect(r, isNotNull);
        expect(r!.suggest, 'guest');

        final p = backend.requests.lastWhere(
          (r) => '${r.params['api']}' == kAmfaSuggestConnApi,
        );
        expect('${p.params['method']}', 'get');
        expect(
          '${p.params['version']}',
          '1',
          reason: '★ smali 注解与 .lib 都写 v1；发错版本会吃 103',
        );
        expect(
          p.params.containsKey('username'),
          isFalse,
          reason: '该方法不该带写动词或多余身份参数',
        );
      },
    );

    test('★★★ 字段名未被证实 ⇒ 响应缺键时**不臆造**，返回原始 map', () async {
      await bootAmfa(admin: true, data: {'unexpected_key': 1});
      final r = await AuthExtraApi(web).suggestConn();
      expect(r!.suggest, isNull, reason: '★ 官方 smali 没给字段名、真机也没观察到 ⇒ 不猜字段名');
      expect(r.raw, {'unexpected_key': 1});
    });

    test('★★★ 非管理员：与管理员**同一条路径**（不做门控）', () async {
      await bootAmfa(admin: false, data: {'x': 1});
      final a = AuthExtraApi(web);
      expect(await a.suggestConn(), isNotNull);
      await bootAmfa(admin: true, data: {'x': 1});
      expect(await AuthExtraApi(web).suggestConn(), isNotNull);
    });

    test('★★★ 只读：整个流程里一个变更动词都没发', () async {
      await bootAmfa(admin: true, data: {});
      await AuthExtraApi(web).suggestConn();
      const blacklist = {
        'set',
        'delete',
        'create',
        'update',
        'add',
        'remove',
        'clear',
        'stop',
        'start',
        'move',
        'copy',
        'upload',
        'cancel',
        'rename',
        'replace',
        'edit',
        'apply',
        'restore',
        'save',
        'avoid',
        'init',
        'import',
        'export',
        'refresh',
      };
      final verbs = backend.requests
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs.intersection(blacklist), isEmpty);
      expect(verbs, contains('get'));
    });

    test('★★★ Mock 会**真的校验**方法名（不是"接受任何方法"）', () async {
      await bootAmfa(admin: true);
      // 直接打一个该 API 不存在的方法，确认 Mock 回 103 ⇒
      // 上面的通过才有意义。
      final bad = backend.handle('/webapi/entry.cgi', {
        'api': kAmfaSuggestConnApi,
        'method': 'get_guest_account',
        'version': '1',
      });
      expect(
        '$bad'.contains('103'),
        isTrue,
        reason: '★★★ 若 Mock 不校验方法名，前面的"通过"就证明不了什么',
      );
    });
  });
}
