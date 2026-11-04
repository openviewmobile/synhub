// ★★★ **会话权限画像**（`SessionEntitlement`）与"**不再用 `105` 探测权限**"
// 的回归保护（第 254 轮，用户 2026-09-25 指令）。
//
// ## 这组用例在钉什么
// 用户原话：「用你推荐的方式改掉之前用 `105` 探测的办法吧」。
// 于是把"故意调一个 adminOnly 接口，把 `105` 读成'我没权限'"换成
// **采信服务端下发的权限画像**（`SYNO.Core.Desktop.Initdata:get` 的
// `Session.is_admin` + `AppPrivilege` + `ActionPrivilege`）。
//
// 因此本文件有两半：
//   ① **解析契约**：官方前端的三元语义（键不存在 = 不放行；`false` 只有通配键能抵消），
//      以及"空 `ActionPrivilege` 是**不知道**、不是**全拒**"这条真机事实；
//   ② **接线契约**：身份链**只**走 Initdata → NormalUser 两棒，
//      **一次** `SYNO.Core.System` 都不许打（旧第三棒已删除）。
//
// ## 真实载荷（不是编的）
// `AppPrivilege` 的 22 个键与 `Session.is_admin=false` 取自 DSM 7.4.1-90080
// 真机响应（`SYNO.Core.Desktop.Initdata:get`，普通用户 `demo_user`，
// 整包 3.1 MB 的解析结果）；证据与边界见 `docs/session-entitlement.md`。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/entitlement/session_entitlement.dart';
import 'package:synhub/src/data/auth_extra_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

/// 真机 `AppPrivilege` 的 22 个键（DSM 7.4.1-90080 实测，全部 `true`）。
const List<String> kRealAppPrivilegeKeys = [
  'SYNO.AFP',
  'SYNO.Cal.Application',
  'SYNO.Contacts.AppInstance',
  'SYNO.Desktop',
  'SYNO.FTP',
  'SYNO.Foto.AppInstance',
  'SYNO.Rsync',
  'SYNO.SDS.App.FileStation3.Instance',
  'SYNO.SDS.AudioStation.Application',
  'SYNO.SDS.BackupService.Instance',
  'SYNO.SDS.Chat.Application',
  'SYNO.SDS.DocumentViewer.Application',
  'SYNO.SDS.DownloadStation.Application',
  'SYNO.SDS.Drive.Application',
  'SYNO.SDS.MailClient.Application',
  'SYNO.SDS.MailPlusServer.Instance',
  'SYNO.SDS.MailServer.Instance',
  'SYNO.SDS.NoteStation.Application',
  'SYNO.SDS.SMBService.AppPrivilege.Instance',
  'SYNO.SDS.SynologyFileManager.Privilege.Extension',
  'SYNO.SDS.WebDAVServer.Instance',
  'SYNO.SFTP',
];

void main() {
  group('SE1. 解析：真实载荷形状', () {
    test('★★★ 22 个真机 `AppPrivilege` 键全部解析出来，身份/用户/能力位都在', () {
      final ent = SessionEntitlement.fromInitdata({
        'AppPrivilege': {for (final k in kRealAppPrivilegeKeys) k: true},
        'Session': {'is_admin': false, 'user': 'demo_user'},
        'ActionPrivilege': <dynamic>[],
        'ServiceStatus': <String, dynamic>{},
        'support_wol': true,
        'support_findme': false,
        'hostname': 'ds923plus',
        'serial_number': 'SN123',
      });
      expect(ent.known, isTrue);
      expect(ent.appPrivilege.entries.length, kRealAppPrivilegeKeys.length);
      expect(ent.isAdmin, isFalse, reason: '★ 真机这台 NAS 上该账号是普通用户');
      expect(ent.user, 'demo_user');
      expect(ent.supportWol, isTrue);
      expect(ent.supportFindme, isFalse);
      expect(ent.hostname, 'ds923plus');
      expect(ent.serialNumber, 'SN123');
      // 官方改键名也认得出（`SYNO.SDS.<App>.Application/Instance` 两种后缀都有）
      for (final k in kRealAppPrivilegeKeys) {
        expect(ent.allowsApp([k]), isTrue, reason: '$k 应为放行');
      }
      expect(ent.describe(), contains('apps=22'));
    });

    test('★★★ `Session.is_admin` 是**下发的结论**：管理员载荷直接为 true', () {
      final ent = SessionEntitlement.fromInitdata({
        'AppPrivilege': {'SYNO.SDS.Chat.Application': true},
        'Session': {'is_admin': true, 'user': 'admin'},
      });
      expect(ent.isAdmin, isTrue);
      expect(ent.user, 'admin');
    });

    test('★★ 空载荷 / 形状不对 ⇒ `unavailable`（**不是**"什么权限都没有"）', () {
      for (final data in <Map<String, dynamic>>[
        {},
        {'Session': 'not-a-map', 'AppPrivilege': 42},
      ]) {
        final ent = SessionEntitlement.fromInitdata(data);
        expect(ent.known, isFalse, reason: '拿不到画像');
        expect(ent.isAdmin, isNull, reason: '★ null = 不知道，别当 false 用');
        expect(
          ent.allowsApp(const ['SYNO.SDS.Chat.Application']),
          isFalse,
          reason: '★ 画像缺席时查询恒不放行（fail-closed），但 known=false '
              '让调用方能区分"拒绝"与"不知道"',
        );
      }
    });

    test('★★★ 只有身份、没有 `AppPrivilege` ⇒ 仍算 known（可用于管理门控）', () {
      final ent = SessionEntitlement.fromInitdata({
        'Session': {'is_admin': true},
      });
      expect(ent.known, isTrue);
      expect(ent.isAdmin, isTrue);
      expect(ent.appPrivilege.known, isFalse, reason: '权限那半确实没拿到');
    });
  });

  group('SE2. 语义：照抄官方前端的三元判断（不发明规则）', () {
    test('★★★ 键存在且 true ⇒ 放行；键存在且 false ⇒ 明确拒绝', () {
      final ent = SessionEntitlement.fromInitdata({
        'AppPrivilege': {
          'SYNO.SDS.Chat.Application': true,
          'SYNO.SDS.NoteStation.Application': false,
        },
      });
      expect(ent.allowsApp(const ['SYNO.SDS.Chat.Application']), isTrue);
      expect(ent.allowsApp(const ['SYNO.SDS.NoteStation.Application']), isFalse);
      expect(ent.deniedApp(const ['SYNO.SDS.NoteStation.Application']), isTrue);
      expect(
        ent.deniedApp(const ['SYNO.SDS.Chat.Application']),
        isFalse,
        reason: '★ "放行"不是"拒绝"',
      );
    });

    test('★★★ 键**不存在** ⇒ 官方前端判"不允许"（但不是"明确拒绝"）', () {
      final ent = SessionEntitlement.fromInitdata({
        'AppPrivilege': {'SYNO.SDS.Chat.Application': true},
      });
      expect(ent.allowsApp(const ['SYNO.SDS.Drive.Application']), isFalse);
      expect(
        ent.deniedApp(const ['SYNO.SDS.Drive.Application']),
        isFalse,
        reason: '★ 官方是 `void 0 !== P[e] && !1 !== P[e]`：缺键=不放行，'
            '但没有"明说拒绝"这层含义 —— 两者要能区分',
      );
    });

    test('★★★ 通配键 `SYNO.ALLOW.ALL.APPLICATIONS` 只抵消 `false`', () {
      final ent = SessionEntitlement.fromInitdata({
        'AppPrivilege': {
          'SYNO.ALLOW.ALL.APPLICATIONS': true,
          'SYNO.SDS.NoteStation.Application': false,
        },
      });
      expect(ent.allowAllApps, isTrue);
      expect(
        ent.allowsApp(const ['SYNO.SDS.NoteStation.Application']),
        isTrue,
        reason: '★ 官方原文：`!0===AppPrivilege["SYNO.ALLOW.ALL.APPLICATIONS"] '
            '|| (void 0!==P[e] && !1!==P[e])`',
      );
    });

    test('★★ 多键模块：**任一命中**即放行（`ServiceSpec.appPrivilegeKeys` 语义）', () {
      final ent = SessionEntitlement.fromInitdata({
        'AppPrivilege': {
          'SYNO.SDS.MailClient.Application': false,
          'SYNO.SDS.MailPlusServer.Instance': true,
        },
      });
      expect(
        ent.allowsApp(const [
          'SYNO.SDS.MailClient.Application',
          'SYNO.SDS.MailPlusServer.Instance',
        ]),
        isTrue,
      );
    });
  });

  group('SE3. 动作权限：空列表是**不知道**，不是"全拒"（真机就是空）', () {
    test('★★★ 空 `ActionPrivilege` ⇒ `null`（不许读成"全部拒绝"）', () {
      final ent = SessionEntitlement.fromInitdata({
        'AppPrivilege': {'SYNO.SDS.Chat.Application': true},
        'ActionPrivilege': <dynamic>[],
      });
      expect(
        ent.allowsAction('SYNO.SDS.Admin.Console'),
        isNull,
        reason: '★★★ 真机普通用户的 `ActionPrivilege` 就是 `[]`；'
            '若当成"全拒"，所有动作级功能会对普通用户凭空消失',
      );
    });

    test('★★ 非空列表 ⇒ 三态查询真的生效', () {
      final ent = SessionEntitlement.fromInitdata({
        'AppPrivilege': {'SYNO.SDS.Chat.Application': true},
        'ActionPrivilege': <dynamic>['SYNO.SDS.Action.A', 42, ''],
      });
      expect(ent.actionAllowList, ['SYNO.SDS.Action.A'], reason: '★ 非字符串项不采信');
      expect(ent.allowsAction('SYNO.SDS.Action.A'), isTrue);
      expect(ent.allowsAction('SYNO.SDS.Action.B'), isFalse);
    });

    test('★★ `ServiceStatus` 只收布尔；缺 / 非 map ⇒ 空（没有信息）', () {
      expect(
        SessionEntitlement.fromInitdata({
          'AppPrivilege': {'SYNO.SDS.Chat.Application': true},
          'ServiceStatus': {'SYNO.SDS.Chat.Application': true, 'x': 'yes'},
        }).serviceStatus,
        {'SYNO.SDS.Chat.Application': true},
      );
      expect(
        SessionEntitlement.fromInitdata({
          'AppPrivilege': {'SYNO.SDS.Chat.Application': true},
        }).serviceStatus,
        isEmpty,
      );
    });
  });

  group('SE4. 接线：`AuthExtraApi.sessionEntitlement()` 纯读、只打一次 get', () {
    late MockDsmBackend backend;
    late DsmWebApi web;

    Future<void> boot({
      Map<String, dynamic>? data,
      bool admin = false,
    }) async {
      backend = MockDsmBackend(catalog: DsmCatalog.load());
      backend.login(username: admin ? 'admin' : 'demo_user', admin: admin);
      backend.fixture(
        kInitDataApi,
        'get',
        (p) => {'success': true, 'data': data ?? {}},
      );
      web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      await web.login(account: admin ? 'admin' : 'demo_user', password: 'x');
    }

    test('★★★ 拿得到画像，且**只**调 `get`（零写动词）', () async {
      await boot(
        data: {
          'AppPrivilege': {'SYNO.SDS.Chat.Application': true},
          'Session': {'is_admin': true, 'user': 'admin'},
        },
        admin: true,
      );
      final ent = await AuthExtraApi(web).sessionEntitlement();
      expect(ent.isAdmin, isTrue);
      expect(ent.allowsApp(const ['SYNO.SDS.Chat.Application']), isTrue);
      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == kInitDataApi)
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs, {'get'});
    });

    test('★★★ 通道不可用（空响应）⇒ `unavailable`，不抛异常', () async {
      await boot(data: {});
      final ent = await AuthExtraApi(web).sessionEntitlement();
      expect(ent, same(SessionEntitlement.unavailable));
    });
  });

  group('SE5. ★★★ 身份链**不再有** `105` 探测（本轮的核心回归保护）', () {
    late MockDsmBackend backend;
    late DsmWebApi web;

    Future<void> boot({
      required bool admin,
      Map<String, dynamic>? normal,
      Map<String, dynamic>? init,
    }) async {
      backend = MockDsmBackend(catalog: DsmCatalog.load());
      backend.login(username: admin ? 'admin' : 'demo_user', admin: admin);
      backend.fixture(
        'SYNO.Core.NormalUser',
        'get',
        (p) => {'success': true, 'data': normal ?? {}},
      );
      if (init != null) {
        backend.fixture(
          kInitDataApi,
          'get',
          (p) => {'success': true, 'data': init},
        );
      }
      web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      await web.login(account: admin ? 'admin' : 'demo_user', password: 'x');
    }

    /// 身份链打过的 API 集合（去掉登录 / 能力发现那几步）。
    Set<String> identityApis() => backend.requests
        .map((r) => '${r.params['api']}')
        .where((a) => a == kInitDataApi || a == 'SYNO.Core.NormalUser' ||
            a == 'SYNO.Core.System')
        .toSet();

    test('★★★ 论证：`resolveIsAdmin()` 一份**都不打** `SYNO.Core.System`', () async {
      await boot(
        admin: true,
        normal: {'is_admin': true},
        init: {
          'AppPrivilege': {'SYNO.SDS.Chat.Application': true},
          'Session': {'is_admin': true},
        },
      );
      expect(await AuthExtraApi(web).resolveIsAdmin(), isTrue);
      expect(
        backend.requests.any((r) => '${r.params['api']}' == 'SYNO.Core.System'),
        isFalse,
        reason:
            '★★★ 旧第三棒会故意打 adminOnly 的 `Core.System/info`，'
            '把 `105` 读成"不是管理员"。用户 2026-09-25 要求改掉这个办法 ⇒ '
            '权限结论只能来自服务端**下发**的画像（Initdata / NormalUser）',
      );
      expect(identityApis(), isNot(contains('SYNO.Core.System')));
    });

    test('★★★ 两条通道都没结论 ⇒ `false`（fail-closed，**不探测**）', () async {
      await boot(admin: false, normal: {'username': 'demo_user'}, init: {});
      expect(await AuthExtraApi(web).resolveIsAdmin(), isFalse);
      expect(
        backend.requests.any((r) => '${r.params['api']}' == 'SYNO.Core.System'),
        isFalse,
        reason: '★ 没有画像时宁可当普通用户，也不去猜',
      );
    });

    test('★★★ `Initdata` 给身份 ⇒ 走官方通道，且**不问** `NormalUser`', () async {
      await boot(
        admin: false,
        normal: {'is_admin': true},
        init: {
          'AppPrivilege': {'SYNO.SDS.Chat.Application': false},
          'Session': {'is_admin': false},
        },
      );
      expect(await AuthExtraApi(web).resolveIsAdmin(), isFalse);
      expect(identityApis(), isNot(contains('SYNO.Core.NormalUser')));
    });
  });
}
