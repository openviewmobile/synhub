// ★★★ **访客登录**（②聊天 审计行 261 的收尾）——第 95 轮
//
// ## 为什么有这个文件
//
// `docs/parity-recount-chat-files.md` §1.10 列出的**最后一条真 ❌** 就是
// 行 261「Guest 登录」：
//
// > 需先取证（需 NAS 上有访客账号；**先确认 `SAS.Guest/stat` 是否真被官方 App 调用**）
//
// 本轮把"先确认"这一步做完了 —— 依据是官方
// `SynologyChat 2.11.1-607` 的 smali（**一级来源**）：
//
// | 文件 | 事实 |
// |---|---|
// | `data/remote/api/SasGuest.smali` | `API="SYNO.SAS.Guest"`、`STAT="stat"`、`VERSION_1=0x1` |
// | `data/vo/GuestAccountVo.smali` | `data: GuestAccountData` |
// | `data/vo/GuestAccountVo$GuestAccountData.smali` | `username: String` |
// | `data/remote/WebApiService.smali` `queryGuestAccount(...)` | `POST webapi/{path}` + `@FormUrlEncoded`，字段 `api`/`method`/`version`/**`email`** |
// | `data/AccountManager.smali` `queryGuestAccount()` | `ApiManager.get("SYNO.SAS.Guest")` |
// | `ui/activity/LoginActivity.smali` | `mGuestBox`（登录页勾选框）→ `LoginPresenter.queryGuestAccount()` |
//
// ⇒ **官方确实调它**，契约是 **提交 `email` → 服务端回访客 `username`**。
//
// ## 诚实边界
//
// ⚠️ `weblib/` 里**不存在** `SYNO.SAS*.lib`，全库 grep `SYNO.SAS` **0 命中**
//   ⇒ **没有 `.lib` 佐证**，唯一依据是 APK smali。（我一度在代码注释里
//   写了"`.lib` 里也只有 v1" —— 那是没核实就写的，已删除。）
// ⚠️ 响应字段**只有** `username` 是实证的；其余字段不臆造。
// ⚠️ 真机未取证：本机 NAS 无访客账号（规程允许"无法验证的用 Mock 验证"）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late MockDsmBackend backend;
  late DsmWebApi web;
  late ChatApi chat;

  Future<void> boot({bool fixture = true}) async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'u', admin: false);
    if (fixture) {
      backend.fixture('SYNO.SAS.Guest', 'stat', (p) {
        return {
          'success': true,
          'data': {
            'data': {'username': 'guest_${p['email']}'},
          },
        };
      });
    }
    web = DsmWebApi(MockDsmTransport(backend));
    await web.discover();
    await web.login(account: 'u', password: 'x');
    chat = ChatApi(web);
  }

  Map<String, dynamic> lastParams() => backend.requests
      .lastWhere((r) => '${r.params['api']}' == 'SYNO.SAS.Guest')
      .params;

  group('G1. ★★★ 契约：api/method/version/email 逐项对齐官方 smali', () {
    test('★★★ 只发 `email` 一个业务字段，走 v1 的 `stat`', () async {
      await boot();
      final r = await chat.queryGuestAccount('a@b.com');
      expect(r, isNotNull);
      expect(r!.username, 'guest_a@b.com');

      final p = lastParams();
      expect('${p['api']}', 'SYNO.SAS.Guest');
      expect('${p['method']}', 'stat');
      expect('${p['version']}', '1', reason: '★ 官方 `SasGuest.VERSION_1 = 0x1`');
      expect('${p['email']}', 'a@b.com');
    });

    test('★ 不夹带任何猜测参数', () async {
      await boot();
      await chat.queryGuestAccount('a@b.com');
      final extra = lastParams().keys.toSet()
        ..removeAll({'api', 'method', 'version', 'email', '_sid'});
      expect(
        extra,
        isEmpty,
        reason:
            '★ 官方注解里只有 api/method/version/email '
            '⇒ 多发的每一个都是臆造（`_sid` 除外：框架统一加的会话号）',
      );
    });

    test('★ 空响应 / 缺 username ⇒ null，不抛、不编', () async {
      await boot(fixture: false);
      backend.fixture(
        'SYNO.SAS.Guest',
        'stat',
        (p) => {'success': true, 'data': const {}},
      );
      expect(await chat.queryGuestAccount('a@b.com'), isNull);

      backend.fixture('SYNO.SAS.Guest', 'stat', (p) {
        return {
          'success': true,
          'data': {
            'data': {'username': ''},
          },
        };
      });
      expect(
        await chat.queryGuestAccount('a@b.com'),
        isNull,
        reason: '★ 空字符串等同于"没查到"，不能当成有效访客名',
      );

      backend.fixture('SYNO.SAS.Guest', 'stat', (p) {
        return {
          'success': true,
          'data': {
            'data': {'username': 42},
          },
        };
      });
      expect(
        await chat.queryGuestAccount('a@b.com'),
        isNull,
        reason: '类型不对也不能硬转',
      );
    });
  });

  group('G2. ★★★ Mock 真的校验这个三元组（否则上面的"通过"证明不了什么）', () {
    test('★★★ 目录里 `SYNO.SAS.Guest` 现在是 methodsVerified', () {
      final spec = DsmCatalog.load().apis['SYNO.SAS.Guest']!;
      expect(
        spec.methodsVerified,
        isTrue,
        reason: '第 95 轮把它从 `live`/无方法表升级为实证方法表',
      );
      expect(spec.methods[1], contains('stat'));
      expect(spec.hasMethod(1, 'stat'), isTrue);
    });

    test('★★★ 不存在的方法必须回 103', () async {
      await boot();
      // 用 API 层直接打一个不在表里的方法名
      final bad = backend.handle('/webapi/entry.cgi', {
        'api': 'SYNO.SAS.Guest',
        'method': 'login',
        'version': '1',
      });
      expect(
        '$bad'.contains('103'),
        isTrue,
        reason: '★ 若 Mock 不校验，G1 的通过就毫无意义',
      );
    });

    test('★★★ 版本 2 也必须回 103（官方只有 VERSION_1）', () async {
      await boot();
      final bad = backend.handle('/webapi/entry.cgi', {
        'api': 'SYNO.SAS.Guest',
        'method': 'stat',
        'version': '2',
      });
      expect('$bad'.contains('103'), isTrue);
    });
  });

  group('G3. ★★ 只读性：这次查询不含任何变更动词', () {
    test('★★★ 全流程无写动词', () async {
      await boot();
      await chat.queryGuestAccount('a@b.com');
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
        'login',
        'logout',
        'pair',
      };
      // ⚠️ 断言**只针对 `SYNO.SAS.Guest`**：boot 阶段的
      // `SYNO.API.Auth:login` 是为了建立 Mock 会话，与本查询无关。
      // （第一次写这条时忘了排除，直接被 `login` 命中 ——
      //  是**断言写错**，不是实现写错。）
      final guestVerbs = backend.requests
          .where((r) => '${r.params['api']}' == 'SYNO.SAS.Guest')
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(guestVerbs, {'stat'});
      expect(guestVerbs.intersection(blacklist), isEmpty);
      // 明确记一笔：`SYNO.API.Auth:login` 是 Mock 里为了建立会话发的，
      // 不属于本查询；断言只针对 SAS.Guest 这一个 API。
      expect(
        backend.requests
            .where((r) => '${r.params['api']}' == 'SYNO.SAS.Guest')
            .map((r) => '${r.params['method']}')
            .toSet(),
        {'stat'},
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // G4. ★★★ **登录前**能不能查（官方就是在登录页调的）
  //
  // 这条是"接线可行性"的实测，不是想当然：登录页在 `login()` 之前
  // 就已经有 connection（`session_controller.login` 要求
  // `state.connection != null`），但**尚未认证**。
  // 官方在 `LoginActivity` 里正是这个时刻调的 `queryGuestAccount`。
  // ══════════════════════════════════════════════════════════════════════
  group('G4. 未认证会话下调用', () {
    test('★★★ 实测：未登录时 Mock **放行**（因为目录里 authLevel 为空）', () async {
      // 刻意**不**调 backend.login
      backend = MockDsmBackend(catalog: DsmCatalog.load());
      backend.fixture('SYNO.SAS.Guest', 'stat', (p) {
        return {
          'success': true,
          'data': {
            'data': {'username': 'guest_x'},
          },
        };
      });
      web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      final c = ChatApi(web);

      // ★★★ 实测结论：**未认证时 Mock 回 119**。
      //
      // 原因是 `tool/mock_dsm/mock_dsm_core.dart:57`：
      //   `authLevel: (json['authLevel'] as num?)?.toInt() ?? 1`
      // —— 目录里 `SYNO.SAS.Guest.authLevel` 是 **null**，被**默认成 1**
      // ⇒ 触发 `authLevel > 0 && !loggedIn ⇒ 119`。
      //
      // ⇒ **这是一处"目录 JSON 与 Dart 模型不一致"**（写下来，不掩盖）：
      //   JSON 说"没写 authLevel"，Dart 当成 1。
      //
      // ⚠️ **真机行为仍未验证**：官方在登录页就调它，**间接**说明可能免认证，
      //   但那是推断不是实测（需 NAS 上有访客账号）。
      Object? err;
      try {
        await c.queryGuestAccount('a@b.com');
      } catch (e) {
        err = e;
      }
      expect(
        '$err'.contains('119'),
        isTrue,
        reason:
            '★ 钉死实测行为：未认证 ⇒ 119。'
            '所以"登录页调访客查询"在我方当前 Mock 语义下**走不通**，'
            '这正是要在文档里登记的边界，而不是假装它能用。',
      );

      final spec = DsmCatalog.load().apis['SYNO.SAS.Guest']!;
      expect(
        spec.authLevel,
        1,
        reason: '★ Dart 模型把缺失的 authLevel 默认成 1（JSON 里是 null）',
      );
    });
  });
}
