// ★ **登录外围只读 API 的 Mock 覆盖**（②聊天 API 级对照 · 第 33 轮）。
//
// 覆盖三个**有官方 Web JS 调用点证据**的端点：
//   `SYNO.API.Auth.Type / get`、`SYNO.Auth.RescueEmail / get`、
//   `SYNO.ActiveInsight.Package / get_status`。
//
// 证据出处（原文见 `lib/src/data/auth_extra_api.dart` 文件头）：
//   `dsm.common.bundle.js` / `WelcomeApp/PromotionApp.js`。
//
// 全部打**内存 Mock Server**，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/auth_extra_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late DsmCatalog catalog;
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late AuthExtraApi ax;

  /// [activeInsightMax] 非空时，构造一份把 ActiveInsight 的 `maxVersion`
  /// 改小的目录 —— 用来模拟"老服务器"（`maxVersion` 是 final，不能就地改）。
  Future<void> boot({int? activeInsightMax, bool admin = false}) async {
    catalog = DsmCatalog.load();
    if (activeInsightMax != null) {
      final base = catalog.apis[kActiveInsightApi]!;
      catalog = DsmCatalog(
        apiCount: catalog.apiCount,
        source: catalog.source,
        apis: {
          ...catalog.apis,
          kActiveInsightApi: DsmApiSpec(
            name: base.name,
            minVersion: base.minVersion,
            maxVersion: activeInsightMax,
            authLevel: base.authLevel,
            allowUser: base.allowUser,
            normal: base.normal,
            adminOnly: base.adminOnly,
            methods: base.methods,
            methodsVerified: base.methodsVerified,
            source: base.source,
          ),
        },
      );
    }
    backend = MockDsmBackend(catalog: catalog);
    backend.login(username: admin ? 'admin' : 'u', admin: admin);
    transport = MockDsmTransport(backend);
    web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: admin ? 'admin' : 'u', password: 'x');
    ax = AuthExtraApi(web);
  }

  setUp(boot);

  group('AX-1. 目录事实：三个 API 都有 `.lib` 方法表（不是"不校验"）', () {
    test('★ 三个 API 都在目录里，且 methodsVerified=true', () {
      for (final a in [kAuthTypeApi, kRescueEmailApi, kActiveInsightApi]) {
        final spec = catalog[a];
        expect(spec, isNotNull, reason: '$a 必须在目录里');
        expect(
          spec!.methodsVerified,
          isTrue,
          reason: '$a 的方法表来自 .lib ⇒ Mock 应当能校验方法名',
        );
        expect(spec.source, 'spk', reason: '$a 的来源应是反编译 SPK');
      }
    });

    test('方法名与 `.lib` 一致（get / get,verify,set / get_status…）', () {
      expect(catalog[kAuthTypeApi]!.methodsAt(1), contains('get'));
      expect(catalog[kRescueEmailApi]!.methodsAt(1), contains('get'));
      expect(catalog[kRescueEmailApi]!.methodsAt(1), contains('verify'));
      expect(catalog[kRescueEmailApi]!.methodsAt(1), contains('set'));
      expect(catalog[kActiveInsightApi]!.methodsAt(1), contains('get_status'));
      expect(catalog[kActiveInsightApi]!.methodsAt(2), contains('get_status'));
      // ActiveInsight v1/v2 都是这四个
      expect(catalog[kActiveInsightApi]!.methodsAt(2), contains('start_mib'));
    });
  });

  group('AX-2. 反证：方法名写错必须被抓住（证明 `.lib` 表真在校验）', () {
    test('Auth.Type 没有 `list` ⇒ 103', () {
      final r = backend.handle('entry.cgi', {
        'api': kAuthTypeApi,
        'method': 'list',
        'version': 1,
        '_sid': backend.sessions.first,
      });
      expect(r.errorCode, 103);
    });

    test('RescueEmail 没有 `list` ⇒ 103（它只有 get/verify/set）', () {
      final r = backend.handle('entry.cgi', {
        'api': kRescueEmailApi,
        'method': 'list',
        'version': 1,
        '_sid': backend.sessions.first,
      });
      expect(r.errorCode, 103);
    });

    test('ActiveInsight 没有 `get`（它叫 `get_status`）⇒ 103', () {
      final r = backend.handle('entry.cgi', {
        'api': kActiveInsightApi,
        'method': 'get',
        'version': 2,
        '_sid': backend.sessions.first,
      });
      expect(r.errorCode, 103);
    });
  });

  group('AX-3. 逐个驱动：三元组合法、版本落在区间内、**无参数**', () {
    test('★ Auth.Type/get', () async {
      await ax.authType();
      final r = backend.requests.last;
      expect(transport.last!.errorCode, isNull);
      expect(r.params['api'], kAuthTypeApi);
      expect(r.params['method'], 'get');
      expect('${r.params['version']}', '1');
      // 官方 JS 里没有 params ⇒ 我们也不发业务参数
      expect(r.params.containsKey('params'), isFalse);
    });

    test('★ RescueEmail/get ⇒ 解析 `verified`（字段名出自官方 JS）', () async {
      backend.fixture(kRescueEmailApi, 'get', (_) {
        return {
          'success': true,
          'data': {'verified': true},
        };
      });
      expect(await ax.rescueEmailVerified(), isTrue);
      final r = backend.requests.last;
      expect(r.params['method'], 'get');
      expect('${r.params['version']}', '1');
    });

    test('★ RescueEmail/get 缺字段 ⇒ false（不崩、不瞎猜）', () async {
      backend.fixture(kRescueEmailApi, 'get', (_) {
        return {'success': true, 'data': <String, dynamic>{}};
      });
      expect(await ax.rescueEmailVerified(), isFalse);
    });

    test('★ ActiveInsight/get_status 协商到 **v2**（官方 JS 用的就是 2）', () async {
      await boot(admin: true); // ★ 仅管理员 API（规则 B1）
      backend.fixture(kActiveInsightApi, 'get_status', (_) {
        return {
          'success': true,
          'data': {'enabled': true},
        };
      });
      expect(await ax.activeInsightEnabled(), isTrue);
      expect('${backend.requests.last.params['version']}', '2');
    });

    test('★ 服务端 maxVersion=1 时 ActiveInsight 退回 v1（不吃 103）', () async {
      // 老服务器 + 管理员（ActiveInsight 是仅管理员 API，规则 B1）
      await boot(activeInsightMax: 1, admin: true);
      backend.fixture(kActiveInsightApi, 'get_status', (_) {
        return {
          'success': true,
          'data': {'enabled': false},
        };
      });
      expect(await ax.activeInsightEnabled(), isFalse);
      expect('${backend.requests.last.params['version']}', '1');
    });
  });

  group('AX-4. §5.1 只读承诺 + 未实现清单是**选择**而非遗漏', () {
    test('★ 本文件发出的方法全在只读白名单里', () async {
      await boot(admin: true);
      await ax.authType();
      await ax.rescueEmailVerified();
      await ax.activeInsightEnabled();
      const readOnly = {'get', 'get_status'};
      final mine = backend.requests.where(
        (r) => kAuthExtraNotImplemented.keys.any(
          (k) => '${r.params['api']}' == k.split(' /').first,
        ),
      );
      for (final r in mine) {
        expect(readOnly, contains('${r.params['method']}'));
      }
      // 三个方法各发一次（boot 的 Query/Login 不算）
      expect(
        backend.requests.where(
          (r) =>
              '${r.params['api']}'.startsWith('SYNO.Auth') ||
              '${r.params['api']}' == kActiveInsightApi ||
              '${r.params['api']}' == kAuthTypeApi,
        ),
        hasLength(3),
      );
    });

    test('★ 未实现清单非空，且每条都写了理由（不许留空）', () {
      expect(kAuthExtraNotImplemented, isNotEmpty);
      for (final e in kAuthExtraNotImplemented.entries) {
        expect(e.key, contains(' / '), reason: '键要写成 `API / method`');
        expect(
          e.value.length,
          greaterThan(20),
          reason: '${e.key} 的理由太短 ⇒ 等于没写',
        );
      }
    });

    test('★ 清单里的写动词**一个都没被调用过**（结构性保证）', () {
      const writes = [
        'set',
        'verify',
        'run',
        'check',
        'start_mib',
        'stop_mib',
        'change_mode',
        'exchange',
        'getjs',
        'getjs_mobile',
      ];
      for (final r in backend.requests) {
        expect(
          writes,
          isNot(contains('${r.params['method']}')),
          reason: '本文件不该发任何写/敏感方法，却发了 ${r.params['method']}',
        );
      }
    });
  });

  group('AX-5. ★ 规则 B1：仅管理员 API 必须**双档**验证', () {
    test('★ 非管理员调 ActiveInsight ⇒ 105（这就是真机上的结果）', () async {
      await boot(admin: false);
      await expectLater(
        ax.activeInsightEnabled(),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noPermission,
          ),
        ),
      );
    });

    test('★ 管理员 ⇒ 通过（真机**测不到**的那一档）', () async {
      await boot(admin: true);
      backend.fixture(kActiveInsightApi, 'get_status', (_) {
        return {
          'success': true,
          'data': {'enabled': true},
        };
      });
      expect(await ax.activeInsightEnabled(), isTrue);
    });

    test('★ 目录里 ActiveInsight 的 allowUser 只有 admin.*（与 B1 判定一致）', () {
      final spec = catalog[kActiveInsightApi]!;
      expect(spec.adminOnly, isTrue);
      expect(spec.normal, isFalse);
      expect(spec.allowUser.every((a) => a.startsWith('admin.')), isTrue);
    });

    test('对照：Auth.Type / RescueEmail **不是**仅管理员（不该被 105 拦）', () {
      expect(catalog[kRescueEmailApi]!.adminOnly, isFalse);
      expect(catalog[kAuthTypeApi]!.adminOnly, isFalse);
    });
  });
}
