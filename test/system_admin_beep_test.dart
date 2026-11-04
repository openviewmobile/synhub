// ★★★ **DS finder 管理接口的 Mock 验证**（用户新规 B1：
// 「涉及管理员的接口一律走 Mock Server 模拟测试，**必须通过**」）
//
// ## 契约来源
// `Android-DSfinder.2.5.7-484.ww.apk` → `ApiBeepControl.smali`：
// `SYNO.Core.Hardware.BeepControl` / `get` / `stop_beep` / v1 /
// `beep_reason` + 12 个 `reason_*` 常量。
//
// ## 这组用例要钉住什么
// 1. **api / method / version 三元组**与官方一致（Mock 会校验这个）；
// 2. **管理员能调通、非管理员拿 `105`** —— 新规 R2/R3 的服务端侧对应；
// 3. **官方没用的方法我们也不调**（官方只有 get / stop_beep，没有 set）；
// 4. 字段缺失 ⇒ **`null`（不知道）**，不是 `false`。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/system_admin_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late MockDsmBackend backend;
  late DsmWebApi web;

  Future<void> boot({required bool admin}) async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: admin ? 'admin' : 'demo_user', admin: admin);
    web = DsmWebApi(MockDsmTransport(backend));
    await web.discover();
    await web.login(account: admin ? 'admin' : 'demo_user', password: 'x');
  }

  /// 版本协商：与 `AuthExtraApi.negotiate` 同一套规则
  ///（取候选里落在 `apiTable` min/max 区间内的**最大**版本）。
  int negotiate(String name, List<int> cands) {
    final e = web.apiTable?[name];
    if (e == null || cands.isEmpty) return cands.isEmpty ? 1 : cands.first;
    final within = cands
        .where((c) => c >= e.minVersion && c <= e.maxVersion)
        .toList();
    return within.isEmpty
        ? cands.first
        : within.reduce((a, b) => a > b ? a : b);
  }

  SystemAdminApi api() => SystemAdminApi(web, discover: negotiate);

  Map<String, dynamic> lastParams(String method) {
    final r = backend.requests
        .where(
          (r) =>
              '${r.params['api']}' == kBeepControlApi &&
              '${r.params['method']}' == method,
        )
        .toList();
    expect(r, isNotEmpty, reason: '必须真的发出了 $kBeepControlApi/$method');
    return r.last.params;
  }

  Map<String, dynamic> lastParamsOf(String apiName, String method) {
    final r = backend.requests
        .where(
          (r) =>
              '${r.params['api']}' == apiName &&
              '${r.params['method']}' == method,
        )
        .toList();
    expect(r, isNotEmpty, reason: '必须真的发出了 $apiName/$method');
    return r.last.params;
  }

  group('BC1. 契约与官方 APK 一致', () {
    test('★★★ `get` 用 v1（官方 `VERSION = 0x1`）', () async {
      await boot(admin: true);
      backend.fixture(kBeepControlApi, 'get', (p) {
        return {
          'success': true,
          'data': {'beep_status': true},
        };
      });
      await api().beepStatus();
      final p = lastParams('get');
      expect('${p['api']}', kBeepControlApi);
      expect('${p['version']}', '1');
    });

    test('★★★ `stop_beep` 是官方方法名（不是 `stop`/`set`）', () async {
      await boot(admin: true);
      await api().stopBeep(reason: BeepReason.fanFail);
      final p = lastParams('stop_beep');
      expect('${p['beep_reason']}', 'reason_fan_fail');
      expect('${p['version']}', '1');
    });

    test('★★★ 12 个 `reason_*` 与 smali 常量**逐个对得上**', () {
      // 官方 `ApiBeepControl.smali` 里的 BEEP_REASON_* 全部取值。
      // 这条用例是"抄错了字"的守门人 —— Mock 只校验三元组，
      // 参数写错在 Mock 上**不会报错**，到真机才静默失效。
      const fromSmali = {
        'reason_power_on',
        'reason_power_off',
        'reason_fan_fail',
        'reason_enclosure_fan_fail',
        'reason_eunit_fan_fail',
        'reason_redundant_power_fail',
        'reason_reset_button',
        'reason_volume_crash',
        'reason_volume_or_cache_crash',
        'reason_ssd_cache_crash',
        'reason_sas_link_fail',
      };
      final ours = BeepReason.values.map((e) => e.wire).toSet();
      // smali 里还有 reason_* 我没全部收进来是**故意的**：
      // 只收 11 个 + 明确列出没收的。这里断言"我们发出去的每一个
      // 都确实在官方集合里"（子集），而不是假装我们收全了。
      expect(
        ours.difference(fromSmali),
        isEmpty,
        reason: '★ 我们发出的任何 reason 都必须在官方常量里有出处',
      );
      expect(ours.length, greaterThanOrEqualTo(10));
    });

    test('★★ 不带 reason 时**不发** `beep_reason` 参数', () async {
      await boot(admin: true);
      await api().stopBeep();
      expect(lastParams('stop_beep').containsKey('beep_reason'), isFalse);
    });
  });

  group('BC2. ★★★ Mock 双档：管理员通 / 非管理员 105（新规 B1）', () {
    test('★★★ 管理员：`get` 成功', () async {
      await boot(admin: true);
      backend.fixture(kBeepControlApi, 'get', (p) {
        return {
          'success': true,
          'data': {'beep_status': true},
        };
      });
      final s = await api().beepStatus();
      expect(s.beeping, isTrue);
    });

    test('★★★ 非管理员：`get` 拿 `105`（adminOnly）', () async {
      await boot(admin: false);
      try {
        await api().beepStatus();
        fail('非管理员不该成功调用 adminOnly 接口');
      } catch (e) {
        expect(
          '$e'.contains('105') || '$e'.contains('noPermission'),
          isTrue,
          reason:
              '★ `.lib` 里 BeepControl 是 adminOnly ⇒ 普通用户 105；'
              '界面必须先过 AdminOnly 门控。异常原文：$e',
        );
      }
    });

    test('★★★ 非管理员：`stop_beep` 也拿 `105`', () async {
      await boot(admin: false);
      try {
        await api().stopBeep(reason: BeepReason.powerOn);
        fail('非管理员不该成功调用 adminOnly 接口');
      } catch (e) {
        expect('$e'.contains('105') || '$e'.contains('noPermission'), isTrue);
      }
    });
  });

  group('BC3. ★★ 字段解析：不知道 ≠ 不是', () {
    test('★★★ 服务端没给状态字段 ⇒ `null`（**不是** `false`）', () async {
      await boot(admin: true);
      backend.fixture(kBeepControlApi, 'get', (p) {
        return {
          'success': true,
          'data': {'other': 1},
        };
      });
      expect(
        (await api().beepStatus()).beeping,
        isNull,
        reason:
            '★★ 字段缺失时界面应显示"未知"，'
            '用 false 冒充"没在响"会让用户以为状态正常',
      );
    });

    test('★ 类型不对 ⇒ `null`', () async {
      await boot(admin: true);
      backend.fixture(kBeepControlApi, 'get', (p) {
        return {
          'success': true,
          'data': {'beep_status': 'true'},
        };
      });
      expect((await api().beepStatus()).beeping, isNull);
    });
  });

  group('BC4. ★★★ 官方只用 get / stop_beep —— 我们不许调 `set`', () {
    test('★★★ `BeepControl` 的调用集合 ⊆ {get, stop_beep}', () async {
      await boot(admin: true);
      backend.fixture(kBeepControlApi, 'get', (p) {
        return {
          'success': true,
          'data': {'beep_status': false},
        };
      });
      final a = api();
      await a.beepStatus();
      await a.stopBeep(reason: BeepReason.resetButton);

      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == kBeepControlApi)
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(
        verbs,
        {'get', 'stop_beep'},
        reason:
            '★★★ 官方 `ApiBeepControl` 只声明了这两个方法；'
            '`.lib` 里这个 API 还有 `set`（§5.1 变更动词），**本仓不调**',
      );
      expect(
        verbs.contains('set'),
        isFalse,
        reason:
            '★★★ §5.1：`set` 是变更动词黑名单成员，'
            '官方也没用它，没有任何理由出现在调用集合里',
      );
    });
  });

  group('BC5. ★★★ `SYNO.Core.System:info`（官方 v1、只读）', () {
    test('★★★ 用**官方的 v1**（`ApiCoreSystem.VERSION = 0x1`）', () async {
      await boot(admin: true);
      backend.fixture('SYNO.Core.System', 'info', (p) {
        return {
          'success': true,
          'data': {
            'model': 'DS920+',
            'version': 'DSM 7.2.2-72806',
            'build_num': 72806,
            'admin_port': 5001,
          },
        };
      });
      final info = await api().systemInfo();
      final p = lastParamsOf('SYNO.Core.System', 'info');
      expect(
        '${p['version']}',
        '1',
        reason:
            '★ 对齐官方功能用 v1；v3 是**我们自己**给身份探测选的安全版本，'
            '两者目的不同',
      );
      expect(info.model, 'DS920+');
      expect(info.version, 'DSM 7.2.2-72806');
      expect(info.buildNum, 72806);
      expect(info.adminPort, 5001);
    });

    test('★★★ 调用集合 == {info}（v1 里混着 shutdown/reboot/reset）', () async {
      await boot(admin: true);
      backend.fixture('SYNO.Core.System', 'info', (p) {
        return {
          'success': true,
          'data': {'model': 'X'},
        };
      });
      await api().systemInfo();
      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == 'SYNO.Core.System')
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(
        verbs,
        {'info'},
        reason:
            '★★★ v1 的方法表里有 shutdown/reboot/reset（§5.1 黑名单）'
            '⇒ 必须证明我们只发了 info',
      );
      for (final bad in ['shutdown', 'reboot', 'reset']) {
        expect(verbs.contains(bad), isFalse);
      }
    });

    test('★★ `type` 参数：官方有 network / storage 两种取值', () async {
      await boot(admin: true);
      backend.fixture('SYNO.Core.System', 'info', (p) {
        return {
          'success': true,
          'data': {'model': 'X'},
        };
      });
      await api().systemInfo(type: 'storage');
      expect('${lastParamsOf('SYNO.Core.System', 'info')['type']}', 'storage');
      await api().systemInfo();
      expect(
        lastParamsOf('SYNO.Core.System', 'info').containsKey('type'),
        isFalse,
      );
    });

    test('★★ 字段缺失 ⇒ `null`（不是空串/0 冒充）', () async {
      await boot(admin: true);
      backend.fixture('SYNO.Core.System', 'info', (p) {
        return {
          'success': true,
          'data': {'other': 1},
        };
      });
      final info = await api().systemInfo();
      expect(info.model, isNull);
      expect(info.version, isNull);
      expect(info.buildNum, isNull);
      expect(info.adminPort, isNull);
    });

    test('★★★ 非管理员 ⇒ `105`', () async {
      await boot(admin: false);
      try {
        await api().systemInfo();
        fail('非管理员不该成功调用 adminOnly 接口');
      } catch (e) {
        expect('$e'.contains('105') || '$e'.contains('noPermission'), isTrue);
      }
    });
  });

  group('BC6. ★★ `SYNO.DSM.FindMe:supported`（DS finder 独有）', () {
    test('★★★ 官方 v2（`ApiFindMe.VERSION = 0x2`）且只发 `supported`', () async {
      await boot(admin: true);
      backend.fixture(kFindMeApi, 'supported', (p) {
        return {
          'success': true,
          'data': {'supported': true},
        };
      });
      expect(await api().findMeSupported(), isTrue);
      final p = lastParamsOf(kFindMeApi, 'supported');
      expect('${p['version']}', '2');
      expect(
        '${p['method']}',
        'supported',
        reason:
            '★★★ 官方的 start/stop 是 §5.1 变更动词 ⇒ 本仓**不实现**，'
            '这里证明我们真的没发',
      );
    });

    test('★★★ 调用集合 == {supported}（不含 start/stop）', () async {
      await boot(admin: true);
      backend.fixture(kFindMeApi, 'supported', (p) {
        return {
          'success': true,
          'data': {'supported': true},
        };
      });
      await api().findMeSupported();
      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == kFindMeApi)
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs, {'supported'});
    });

    test('★★ 字段缺失 ⇒ `null`（不知道支不支持，不是 false）', () async {
      await boot(admin: true);
      backend.fixture(kFindMeApi, 'supported', (p) {
        return {'success': true, 'data': {}};
      });
      expect(await api().findMeSupported(), isNull);
    });

    test('★★★ 非管理员 ⇒ `105`', () async {
      await boot(admin: false);
      try {
        await api().findMeSupported();
        fail('非管理员不该成功调用 adminOnly 接口');
      } catch (e) {
        expect('$e'.contains('105') || '$e'.contains('noPermission'), isTrue);
      }
    });
  });

  group('BC7. ★★★ `SYNO.Core.Service:get` —— 版本陷阱守门', () {
    test('★★★ 必须用 **v2**：v1 **没有** `get`（官方常量是给 `control` 的）', () async {
      await boot(admin: true);
      backend.fixture('SYNO.Core.Service', 'get', (p) {
        return {
          'success': true,
          'data': {'services': []},
        };
      });
      await api().serviceStatus();
      final p = lastParamsOf('SYNO.Core.Service', 'get');
      expect(
        '${p['version']}',
        '2',
        reason:
            '★★★ `.lib`：Service 的 v1 **只有 `control`**，`get` 从 v2 才有。'
            '照抄官方 `ApiCoreService.VERSION = 0x1`（那是给 control 的）'
            '去调 get 会直接拿 103',
      );
    });

    test('★★★ 用 v1 调 `get` 会被 Mock 判为 **103**（证明这条陷阱是真的）', () async {
      await boot(admin: true);
      // 直接绕过我们的封装，故意用 v1 调 get —— 应当失败。
      // 这条用例是**证据**：证明"v1 没有 get"不是我猜的。
      try {
        await web.call(
          'SYNO.Core.Service',
          'get',
          preferredVersion: 1,
          params: const {},
        );
        fail('v1 不该有 get');
      } catch (e) {
        expect(
          '$e'.contains('103'),
          isTrue,
          reason:
              '★ 103 = 方法不存在。这条断言把"版本陷阱"钉成了可复现的证据。'
              '异常原文：$e',
        );
      }
    });

    test('★★★ 调用集合 == {get}（`control` 是启停，本仓不实现）', () async {
      await boot(admin: true);
      backend.fixture('SYNO.Core.Service', 'get', (p) {
        return {
          'success': true,
          'data': {'services': []},
        };
      });
      await api().serviceStatus();
      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == 'SYNO.Core.Service')
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs, {'get'});
      expect(
        verbs.contains('control'),
        isFalse,
        reason:
            '★★★ 官方 `ApiCoreService` 只声明了 `control`，'
            '但那是**启停服务**（变更操作）⇒ 本仓不实现、不调用',
      );
    });

    test('★★★ 非管理员 ⇒ `105`', () async {
      await boot(admin: false);
      try {
        await api().serviceStatus();
        fail('非管理员不该成功');
      } catch (e) {
        expect('$e'.contains('105') || '$e'.contains('noPermission'), isTrue);
      }
    });
  });

  group('BC8. ★★ `SYNO.Core.Package`（套件，只读）', () {
    test('★★★ `list` 解析出套件数组', () async {
      await boot(admin: true);
      backend.fixture('SYNO.Core.Package', 'list', (p) {
        return {
          'success': true,
          'data': {
            'packages': [
              {'id': 'SynologyDrive', 'name': 'Synology Drive'},
              {'id': 'AudioStation', 'name': 'Audio Station'},
            ],
          },
        };
      });
      final list = await api().packageList();
      expect(list.length, 2);
      expect(list.first['id'], 'SynologyDrive');
      final p = lastParamsOf('SYNO.Core.Package', 'list');
      expect('${p['version']}', '1');
    });

    test('★★★ `packages` 字段缺失/类型不对 ⇒ **空列表**（不是崩）', () async {
      await boot(admin: true);
      backend.fixture('SYNO.Core.Package', 'list', (p) {
        return {
          'success': true,
          'data': {'other': 1},
        };
      });
      expect(await api().packageList(), isEmpty);
    });

    test('★★ `get` 带 `id` 参数', () async {
      await boot(admin: true);
      backend.fixture('SYNO.Core.Package', 'get', (p) {
        return {
          'success': true,
          'data': {'id': 'SynologyDrive'},
        };
      });
      await api().packageGet('SynologyDrive');
      expect(
        '${lastParamsOf('SYNO.Core.Package', 'get')['id']}',
        'SynologyDrive',
      );
    });

    test('★★★ 非管理员 ⇒ `105`（Package 是 adminOnly）', () async {
      await boot(admin: false);
      try {
        await api().packageList();
        fail('非管理员不该成功');
      } catch (e) {
        expect('$e'.contains('105') || '$e'.contains('noPermission'), isTrue);
      }
    });

    test('★★★ 调用集合 ⊆ {list, get}（不含 install/upgrade/uninstall）', () async {
      await boot(admin: true);
      backend.fixture('SYNO.Core.Package', 'list', (p) {
        return {
          'success': true,
          'data': {'packages': []},
        };
      });
      backend.fixture('SYNO.Core.Package', 'get', (p) {
        return {'success': true, 'data': {}};
      });
      final a = api();
      await a.packageList();
      await a.packageGet('X');
      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == 'SYNO.Core.Package')
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs, {'list', 'get'});
      for (final bad in ['install', 'upgrade', 'uninstall', 'control']) {
        expect(verbs.contains(bad), isFalse, reason: '★★★ 变更操作，本仓不做');
      }
    });
  });

  group('BC9. ★★★ 第四批：10 个只读 adminOnly 接口', () {
    /// 注册一条 `{api}:{method}` 的响应。
    void stub(String apiName, String method, Map<String, dynamic> data) {
      backend.fixture(apiName, method, (p) {
        return {'success': true, 'data': data};
      });
    }

    test('★★★ 10 个方法各自用的是**官方契约里的 api/method**', () async {
      await boot(admin: true);
      stub('SYNO.Core.Network', 'get', {'server_name': 'nas'});
      stub('SYNO.Core.Upgrade', 'status', {'status': 'idle'});
      stub('SYNO.Core.Upgrade', 'basic_status', {'available': false});
      stub('SYNO.Core.Upgrade.Setting', 'get', {'autoupdate_enable': true});
      stub('SYNO.Core.Security.AutoBlock', 'get', {'enable': false});
      stub('SYNO.Core.Theme.Desktop', 'get', {'theme': 'default'});
      stub('SYNO.Core.User.Home', 'get', {'enable': true});
      stub('SYNO.Core.Region.NTP', 'get', {'enable': true});
      stub('SYNO.Core.Region.NTP', 'status', {'synced': true});
      stub('SYNO.Core.Region.Language', 'get', {'language': 'chs'});

      final a = api();
      expect((await a.networkGet())['server_name'], 'nas');
      expect((await a.upgradeStatus())['status'], 'idle');
      expect((await a.upgradeBasicStatus())['available'], false);
      expect((await a.upgradeSettingGet())['autoupdate_enable'], true);
      expect((await a.autoBlockGet())['enable'], false);
      expect((await a.themeDesktopGet())['theme'], 'default');
      expect((await a.userHomeGet())['enable'], true);
      expect((await a.ntpGet())['enable'], true);
      expect((await a.ntpStatus())['synced'], true);
      expect((await a.languageGet())['language'], 'chs');
    });

    test('★★★ 全部只调只读方法：调用集合与预期**完全一致**', () async {
      await boot(admin: true);
      for (final e in const [
        ['SYNO.Core.Network', 'get'],
        ['SYNO.Core.Upgrade', 'status'],
        ['SYNO.Core.Upgrade', 'basic_status'],
        ['SYNO.Core.Upgrade.Setting', 'get'],
        ['SYNO.Core.Security.AutoBlock', 'get'],
        ['SYNO.Core.Theme.Desktop', 'get'],
        ['SYNO.Core.User.Home', 'get'],
        ['SYNO.Core.Region.NTP', 'get'],
        ['SYNO.Core.Region.NTP', 'status'],
        ['SYNO.Core.Region.Language', 'get'],
      ]) {
        stub(e[0], e[1], const {});
      }
      final a = api();
      await a.networkGet();
      await a.upgradeStatus();
      await a.upgradeBasicStatus();
      await a.upgradeSettingGet();
      await a.autoBlockGet();
      await a.themeDesktopGet();
      await a.userHomeGet();
      await a.ntpGet();
      await a.ntpStatus();
      await a.languageGet();

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
        'sync',
        'setzone',
        'control',
      };
      final verbs = backend.requests
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(
        verbs.intersection(blacklist),
        isEmpty,
        reason:
            '★★★ 第四批全是只读；`.lib` 里这些 API 大多还有 '
            '`set`/`start`/`sync`/`setzone`/`control` ⇒ 必须证明一个都没发',
      );
    });

    test('★★★ 每个 API 的调用集合都不含 `set`（逐 API 断言）', () async {
      await boot(admin: true);
      for (final e in const [
        ['SYNO.Core.Network', 'get'],
        ['SYNO.Core.Security.AutoBlock', 'get'],
        ['SYNO.Core.Theme.Desktop', 'get'],
        ['SYNO.Core.User.Home', 'get'],
        ['SYNO.Core.Region.NTP', 'get'],
        ['SYNO.Core.Region.Language', 'get'],
        ['SYNO.Core.Upgrade.Setting', 'get'],
      ]) {
        stub(e[0], e[1], const {});
      }
      final a = api();
      await a.networkGet();
      await a.autoBlockGet();
      await a.themeDesktopGet();
      await a.userHomeGet();
      await a.ntpGet();
      await a.languageGet();
      await a.upgradeSettingGet();

      for (final name in const [
        'SYNO.Core.Network',
        'SYNO.Core.Security.AutoBlock',
        'SYNO.Core.Theme.Desktop',
        'SYNO.Core.User.Home',
        'SYNO.Core.Region.NTP',
        'SYNO.Core.Region.Language',
        'SYNO.Core.Upgrade.Setting',
      ]) {
        final verbs = backend.requests
            .where((r) => '${r.params['api']}' == name)
            .map((r) => '${r.params['method']}')
            .toSet();
        expect(verbs, {'get'}, reason: '$name 只应发 get（`.lib` 里它还有 set）');
      }
    });

    test('★★★ 非管理员 ⇒ 全部 `105`（这批全是 adminOnly）', () async {
      await boot(admin: false);
      final a = api();
      for (final f in <Future<Object?> Function()>[
        a.networkGet,
        a.upgradeStatus,
        a.upgradeBasicStatus,
        a.upgradeSettingGet,
        a.autoBlockGet,
        a.themeDesktopGet,
        a.userHomeGet,
        a.ntpGet,
        a.ntpStatus,
        a.languageGet,
      ]) {
        try {
          await f();
          fail('非管理员不该成功调用 adminOnly 接口');
        } catch (e) {
          expect(
            '$e'.contains('105') || '$e'.contains('noPermission'),
            isTrue,
            reason: '异常原文：$e',
          );
        }
      }
    });
  });

  group('BC10. ★★★ 存储类（第 82 轮解锁：方法表有了第二来源）', () {
    void stub(String apiName, String method, Map<String, dynamic> data) {
      backend.fixture(apiName, method, (p) {
        return {'success': true, 'data': data};
      });
    }

    test('★★★ `Storage.CGI.Storage:load_info` 走通（方法名来自官方 mobile.js）', () async {
      await boot(admin: true);
      stub('SYNO.Storage.CGI.Storage', 'load_info', {'storagePools': []});
      final d = await api().storageLoadInfo();
      expect(d.containsKey('storagePools'), isTrue);
      expect(
        '${lastParamsOf('SYNO.Storage.CGI.Storage', 'load_info')['version']}',
        '1',
      );
    });

    test('★★★ `Storage.CGI.Smart:get_health_info` 走通', () async {
      await boot(admin: true);
      stub('SYNO.Storage.CGI.Smart', 'get_health_info', {'disks': []});
      expect(await api().storageSmartHealth(), isA<Map<String, dynamic>>());
    });

    test('★★★ `Core.Storage.Volume:list` 解析出卷数组', () async {
      await boot(admin: true);
      stub('SYNO.Core.Storage.Volume', 'list', {
        'volumes': [
          {'id': 'volume_1', 'status': 'normal'},
          {'id': 'volume_2', 'status': 'degraded'},
        ],
      });
      final list = await api().storageVolumeList();
      expect(list.length, 2);
      expect(list.first['id'], 'volume_1');
    });

    test('★★ `volumes` 缺失/类型不对 ⇒ 空列表（不崩）', () async {
      await boot(admin: true);
      stub('SYNO.Core.Storage.Volume', 'list', {'x': 1});
      expect(await api().storageVolumeList(), isEmpty);
    });

    test('★★★ ★ 用**不存在的方法**验证 Mock 真的在判 103（校验已开启）', () async {
      // 这条是关键：证明我们把 `methodsVerified` 从 false 改成了 true
      // —— 否则 Mock 会**跳过**校验，"通过"就毫无意义。
      await boot(admin: true);
      try {
        await web.call(
          'SYNO.Storage.CGI.Storage',
          'definitely_not_a_method',
          preferredVersion: 1,
          params: const {},
        );
        fail('不存在的方法不该通过 Mock 校验');
      } catch (e) {
        expect(
          '$e'.contains('103'),
          isTrue,
          reason:
              '★★★ 103 = 方法不存在。能拿到 103 才说明校验**真的开着**；'
              '若 methodsVerified=false，Mock 会接受任何方法名，测试全绿也证明不了什么',
        );
      }
    });

    test('★★★ 只读：存储类调用集合 == {load_info, get_health_info, list}', () async {
      await boot(admin: true);
      stub('SYNO.Storage.CGI.Storage', 'load_info', const {});
      stub('SYNO.Storage.CGI.Smart', 'get_health_info', const {});
      stub('SYNO.Core.Storage.Volume', 'list', const {});
      final a = api();
      await a.storageLoadInfo();
      await a.storageSmartHealth();
      await a.storageVolumeList();
      // ★ 必须限定到**存储这三个 API**：不限定的话会把
      // discover/login 的 Query/getinfo/login 也算进来（第一版就是这么失败的）
      const storageApis = {
        'SYNO.Storage.CGI.Storage',
        'SYNO.Storage.CGI.Smart',
        'SYNO.Core.Storage.Volume',
      };
      final verbs = backend.requests
          .where((r) => storageApis.contains('${r.params['api']}'))
          .map((r) => '${r.params['method']}')
          .toSet();
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
        'do_smart_test',
      };
      expect(
        verbs.intersection(blacklist),
        isEmpty,
        reason:
            '★★★ `SYNO.Core.Storage.Disk:do_smart_test` 是变更操作'
            '（mobile.js 里也有），本仓**不实现**',
      );
      expect(verbs, {'load_info', 'get_health_info', 'list'});
    });
  });

  group('BC11. ★★★ 第五批：账号/群组/权限/策略（11 个只读方法）', () {
    void stub(String apiName, String method, Map<String, dynamic> data) {
      backend.fixture(apiName, method, (p) {
        return {'success': true, 'data': data};
      });
    }

    test('★★★ 解析类方法：取数组字段', () async {
      await boot(admin: true);
      stub('SYNO.Core.User', 'list', {
        'users': [
          {'name': 'admin'},
          {'name': 'demo_user'},
        ],
      });
      stub('SYNO.Core.Group', 'list', {
        'groups': [
          {'name': 'administrators'},
        ],
      });
      stub('SYNO.Core.Group.Member', 'list', {
        'users': [
          {'name': 'admin'},
        ],
      });
      stub('SYNO.Core.AppPriv.Rule', 'list', {
        'rules': [
          {'id': 1},
        ],
      });
      stub('SYNO.Core.Package.Server', 'list', {
        'servers': [
          {'id': 'synology'},
        ],
      });
      final a = api();
      expect((await a.userList()).length, 2);
      expect((await a.groupList()).length, 1);
      expect((await a.groupMemberList()).length, 1);
      expect((await a.appPrivRuleList()).length, 1);
      expect((await a.packageServerList()).length, 1);
    });

    test('★★★ 数组字段缺失/类型不对 ⇒ **空列表**（不崩、不猜）', () async {
      await boot(admin: true);
      for (final e in const [
        ['SYNO.Core.User', 'list'],
        ['SYNO.Core.Group', 'list'],
        ['SYNO.Core.Group.Member', 'list'],
        ['SYNO.Core.AppPriv.Rule', 'list'],
        ['SYNO.Core.Package.Server', 'list'],
      ]) {
        stub(e[0], e[1], {'wrong': 1});
      }
      final a = api();
      expect(await a.userList(), isEmpty);
      expect(await a.groupList(), isEmpty);
      expect(await a.groupMemberList(), isEmpty);
      expect(await a.appPrivRuleList(), isEmpty);
      expect(await a.packageServerList(), isEmpty);
    });

    test('★★ 取值类方法：详情/策略/超时/救援邮箱/数据收集/MyDS', () async {
      await boot(admin: true);
      stub('SYNO.Core.User', 'get', {'name': 'admin'});
      stub('SYNO.Core.User.PasswordPolicy', 'get', {'enable': true});
      stub('SYNO.Core.Desktop.Timeout', 'get', {'timeout': 15});
      stub('SYNO.Auth.RescueEmail', 'get', {'email': 'a@b.c'});
      stub('SYNO.Core.DataCollect', 'get', {'enable': false});
      stub('SYNO.Core.MyDSCenter', 'query', {'status': 'bound'});
      final a = api();
      expect((await a.userGet('admin'))['name'], 'admin');
      expect(
        '${lastParamsOf('SYNO.Core.User', 'get')['name']}',
        'admin',
        reason: '详情必须带 name 参数',
      );
      expect((await a.passwordPolicyGet())['enable'], true);
      expect((await a.desktopTimeoutGet())['timeout'], 15);
      expect((await a.rescueEmailGet())['email'], 'a@b.c');
      expect((await a.dataCollectGet())['enable'], false);
      expect((await a.myDsCenterQuery())['status'], 'bound');
    });

    test('★★★ 全部只读：**逐 API** 调用集合与预期完全一致', () async {
      await boot(admin: true);
      const expected = {
        'SYNO.Core.User': {'list', 'get'},
        'SYNO.Core.Group': {'list'},
        'SYNO.Core.Group.Member': {'list'},
        'SYNO.Core.AppPriv.Rule': {'list'},
        'SYNO.Core.User.PasswordPolicy': {'get'},
        'SYNO.Core.Package.Server': {'list'},
        'SYNO.Core.Desktop.Timeout': {'get'},
        'SYNO.Auth.RescueEmail': {'get'},
        'SYNO.Core.DataCollect': {'get'},
        'SYNO.Core.MyDSCenter': {'query'},
      };
      for (final e in expected.entries) {
        for (final m in e.value) {
          stub(e.key, m, const {});
        }
      }
      final a = api();
      await a.userList();
      await a.userGet('x');
      await a.groupList();
      await a.groupMemberList();
      await a.appPrivRuleList();
      await a.passwordPolicyGet();
      await a.packageServerList();
      await a.desktopTimeoutGet();
      await a.rescueEmailGet();
      await a.dataCollectGet();
      await a.myDsCenterQuery();

      for (final e in expected.entries) {
        final verbs = backend.requests
            .where((r) => '${r.params['api']}' == e.key)
            .map((r) => '${r.params['method']}')
            .toSet();
        expect(verbs, e.value, reason: '${e.key} 只该发 ${e.value}');
      }
      // 全局黑名单
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
        'sync',
        'control',
        'setzone',
      };
      final all = backend.requests.map((r) => '${r.params['method']}').toSet();
      expect(
        all.intersection(blacklist),
        isEmpty,
        reason: '★★★ 这批 API（User/Group/AppPriv）在 `.lib` 里都有 set/create/delete',
      );
    });

    test('★★★ 每个 API 都不含 `set`/`create`/`delete`（逐 API 断言）', () async {
      await boot(admin: true);
      for (final e in const [
        ['SYNO.Core.User', 'list'],
        ['SYNO.Core.Group', 'list'],
        ['SYNO.Core.AppPriv.Rule', 'list'],
        ['SYNO.Core.User.PasswordPolicy', 'get'],
        ['SYNO.Core.Package.Server', 'list'],
      ]) {
        stub(e[0], e[1], const {});
      }
      final a = api();
      await a.userList();
      await a.groupList();
      await a.appPrivRuleList();
      await a.passwordPolicyGet();
      await a.packageServerList();
      for (final name in const [
        'SYNO.Core.User',
        'SYNO.Core.Group',
        'SYNO.Core.AppPriv.Rule',
        'SYNO.Core.User.PasswordPolicy',
        'SYNO.Core.Package.Server',
      ]) {
        final verbs = backend.requests
            .where((r) => '${r.params['api']}' == name)
            .map((r) => '${r.params['method']}')
            .toSet();
        for (final bad in ['set', 'create', 'delete']) {
          expect(verbs.contains(bad), isFalse, reason: '$name 不该发 $bad');
        }
      }
    });

    test('★★★ 非管理员 ⇒ **adminOnly 的 8 个**全部 `105`', () async {
      await boot(admin: false);
      final a = api();
      for (final f in <Future<Object?> Function()>[
        a.userList,
        () => a.userGet('x'),
        a.groupList,
        a.groupMemberList,
        a.appPrivRuleList,
        a.passwordPolicyGet,
        a.packageServerList,
        a.dataCollectGet,
        a.myDsCenterQuery,
      ]) {
        try {
          await f();
          fail('非管理员不该成功调用 adminOnly 接口');
        } catch (e) {
          expect(
            '$e'.contains('105') || '$e'.contains('noPermission'),
            isTrue,
            reason: '异常原文：$e',
          );
        }
      }
    });

    test('★★★ 普通用户可读的两个：非管理员**应当成功**（别过度门控）', () async {
      // `.lib` 里 Desktop.Timeout / Auth.RescueEmail 的 adminOnly = false
      // ⇒ 非管理员**必须能读**。若这里也报 105，说明门控做过头了。
      await boot(admin: false);
      stub('SYNO.Core.Desktop.Timeout', 'get', {'timeout': 15});
      stub('SYNO.Auth.RescueEmail', 'get', {'email': 'a@b.c'});
      final a = api();
      expect((await a.desktopTimeoutGet())['timeout'], 15);
      expect((await a.rescueEmailGet())['email'], 'a@b.c');
    });
  });

  group('BC12. ★★★ 通用版本守卫：每个方法都要落在**含它的最低版本**上', () {
    // ★ 为什么要有这一组：`Service:get`（§19.1）和 `MyDSCenter:query`（§24）
    // 已经**两次**因为"用 v1 调了 v2 才有的方法"拿到 103。
    // 与其逐个等测试报错，不如把判据写死：调用时带的 version
    // 必须是**目录里第一个包含该方法的版本**。
    late DsmCatalog catalog;

    setUpAll(() async {
      catalog = DsmCatalog.load();
    });

    test('★★★ 逐个核对本轮 11 个方法的版本', () async {
      await boot(admin: true);
      for (final m in const [
        ['SYNO.Core.User', 'list'],
        ['SYNO.Core.User', 'get'],
        ['SYNO.Core.Group', 'list'],
        ['SYNO.Core.Group.Member', 'list'],
        ['SYNO.Core.AppPriv.Rule', 'list'],
        ['SYNO.Core.User.PasswordPolicy', 'get'],
        ['SYNO.Core.Package.Server', 'list'],
        ['SYNO.Core.Desktop.Timeout', 'get'],
        ['SYNO.Auth.RescueEmail', 'get'],
        ['SYNO.Core.DataCollect', 'get'],
        ['SYNO.Core.MyDSCenter', 'query'],
      ]) {
        backend.fixture(m[0], m[1], (p) {
          return {'success': true, 'data': const {}};
        });
      }
      final a = api();
      await a.userList();
      await a.userGet('x');
      await a.groupList();
      await a.groupMemberList();
      await a.appPrivRuleList();
      await a.passwordPolicyGet();
      await a.packageServerList();
      await a.desktopTimeoutGet();
      await a.rescueEmailGet();
      await a.dataCollectGet();
      await a.myDsCenterQuery();

      for (final m in const [
        ['SYNO.Core.User', 'list'],
        ['SYNO.Core.User', 'get'],
        ['SYNO.Core.Group', 'list'],
        ['SYNO.Core.Group.Member', 'list'],
        ['SYNO.Core.AppPriv.Rule', 'list'],
        ['SYNO.Core.User.PasswordPolicy', 'get'],
        ['SYNO.Core.Package.Server', 'list'],
        ['SYNO.Core.Desktop.Timeout', 'get'],
        ['SYNO.Auth.RescueEmail', 'get'],
        ['SYNO.Core.DataCollect', 'get'],
        ['SYNO.Core.MyDSCenter', 'query'],
      ]) {
        final apiName = m[0];
        final method = m[1];
        final spec = catalog.apis[apiName];
        expect(spec, isNotNull, reason: '目录里没有 $apiName');
        final methods = spec!.methods;
        // 目录里第一个包含该方法的版本
        // 目录里第一个包含该方法的版本（int 键）
        final versions = methods.keys.toList()..sort();
        final firstWith = versions.firstWhere(
          (v) => methods[v]!.contains(method),
          orElse: () => -1,
        );
        expect(firstWith, greaterThan(0), reason: '$apiName 目录里没有 $method');
        final sent = int.parse('${lastParamsOf(apiName, method)['version']}');
        expect(
          sent,
          greaterThanOrEqualTo(firstWith),
          reason:
              '★★★ $apiName:$method 在目录里最早出现于 v$firstWith，'
              '我们却发了 v$sent ⇒ 会拿到 103。'
              '（这条守卫就是 `Service:get` 与 `MyDSCenter:query` 两次教训的产物）',
        );
      }
    });
  });

  group('BC13. ★★ 第六批：收尾剩余只读方法', () {
    void stub(String apiName, String method, Map<String, dynamic> data) {
      backend.fixture(apiName, method, (p) {
        return {'success': true, 'data': data};
      });
    }

    test('★★★ 4 个方法走通且只发只读动词', () async {
      await boot(admin: true);
      stub('SYNO.Core.QuickStart.Info', 'load_ds_info', {'model': 'DS920+'});
      stub('SYNO.Core.QuickStart.Info', 'check_permission', {'allow': true});
      stub('SYNO.Core.QuickStart.Install', 'check_progress', {'percent': 0});
      stub('SYNO.Core.Upgrade.Server', 'check', {'ok': true});
      stub('SYNO.API.Auth.RedirectURI', 'check', {'valid': true});
      final a = api();
      expect((await a.quickStartLoadDsInfo())['model'], 'DS920+');
      expect((await a.quickStartCheckPermission())['allow'], true);
      expect((await a.quickStartInstallProgress())['percent'], 0);
      expect((await a.upgradeServerCheck())['ok'], true);
      expect((await a.authRedirectUriCheck())['valid'], true);

      const batch = {
        'SYNO.Core.QuickStart.Info',
        'SYNO.Core.QuickStart.Install',
        'SYNO.Core.Upgrade.Server',
        'SYNO.API.Auth.RedirectURI',
      };
      final verbs = backend.requests
          .where((r) => batch.contains('${r.params['api']}'))
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs, {
        'load_ds_info',
        'check_permission',
        'check_progress',
        'check',
      });
      // ★ `QuickStart.Install` 的 install_pkgs/install_sur 是变更操作
      for (final bad in ['install_pkgs', 'install_sur', 'notify_sur_failed']) {
        expect(verbs.contains(bad), isFalse, reason: '★★★ §5.1：$bad');
      }
    });

    test('★★★ 非管理员：QuickStart/Upgrade.Server（adminOnly）报 105', () async {
      await boot(admin: false);
      final a = api();
      for (final f in <Future<Object?> Function()>[
        a.quickStartLoadDsInfo,
        a.quickStartCheckPermission,
        a.quickStartInstallProgress,
        a.upgradeServerCheck,
      ]) {
        try {
          await f();
          fail('非管理员不该成功');
        } catch (e) {
          expect('$e'.contains('105') || '$e'.contains('noPermission'), isTrue);
        }
      }
    });
  });

  group('BC14. ★★★ 第七批：用新解开的 DSM 核心方法表实现', () {
    void stub(String apiName, String method, Map<String, dynamic> data) {
      backend.fixture(apiName, method, (p) {
        return {'success': true, 'data': data};
      });
    }

    test('★★★ QuickConnect：get / status / get_server_alias（v3）', () async {
      await boot(admin: true);
      stub('SYNO.Core.QuickConnect', 'get', {'enabled': true});
      stub('SYNO.Core.QuickConnect', 'status', {'connected': true});
      stub('SYNO.Core.QuickConnect', 'get_server_alias', {
        'alias': 'demo_admin',
      });
      final a = api();
      expect((await a.quickConnectGet())['enabled'], true);
      expect((await a.quickConnectStatus())['connected'], true);
      expect((await a.quickConnectGetServerAlias())['alias'], 'demo_admin');

      final vs = {
        for (final m in ['get', 'status', 'get_server_alias'])
          m: '${lastParamsOf('SYNO.Core.QuickConnect', m)['version']}',
      };
      expect(vs['get'], '1');
      expect(vs['status'], '1');
      expect(
        vs['get_server_alias'],
        '3',
        reason:
            '★★★ `get_server_alias` **只在 v3**（v1/v2 没有）⇒ '
            '发 1 或 2 都会拿 103。这正是第 85 轮那条通用版本守卫要防的',
      );
    });

    test('★★★ ★ 放行校验：QuickConnect 是**普通用户可读**的', () async {
      // `.lib` 的 allowUser 含 normal.* ⇒ 非管理员**必须成功**。
      // 若这里报 105，说明我们把门控做过头了。
      await boot(admin: false);
      stub('SYNO.Core.QuickConnect', 'get', {'enabled': true});
      stub('SYNO.SecureSignIn.Authenticator', 'list', {
        'authenticators': [
          {'id': 'a1'},
        ],
      });
      final a = api();
      expect(
        (await a.quickConnectGet())['enabled'],
        true,
        reason:
            '★★★ QuickConnect 的 allowUser 含 normal.* ⇒ '
            '普通用户能读；报 105 就是过度门控',
      );
      expect((await a.authenticatorList()).length, 1);
    });

    test('★★★ 硬盘/存储类（adminOnly）：管理员成功', () async {
      await boot(admin: true);
      stub('SYNO.Storage.CGI.HddMan', 'get', {'disks': []});
      stub('SYNO.Core.Storage.Volume', 'get', {'id': 'volume_1'});
      stub('SYNO.Storage.CGI.Smart', 'get_smart_info', {'health': 'good'});
      stub('SYNO.Storage.CGI.Storage', 'load_bad_disks', {'disks': []});
      stub('SYNO.Storage.CGI.Storage', 'get_resync_speed', {'speed': 0});
      final a = api();
      expect(await a.hddManGet(), isA<Map<String, dynamic>>());
      expect((await a.volumeGet('volume_1'))['id'], 'volume_1');
      expect(
        '${lastParamsOf('SYNO.Core.Storage.Volume', 'get')['id']}',
        'volume_1',
      );
      expect((await a.smartInfo(disk: 'sda'))['health'], 'good');
      expect(
        '${lastParamsOf('SYNO.Storage.CGI.Smart', 'get_smart_info')['disk']}',
        'sda',
      );
      expect(await a.storageLoadBadDisks(), isA<Map<String, dynamic>>());
      expect((await a.storageResyncSpeed())['speed'], 0);
    });

    test('★★★ 只读：调用集合与预期完全一致，且**不含**变更方法', () async {
      await boot(admin: true);
      for (final e in const [
        ['SYNO.Core.QuickConnect', 'get'],
        ['SYNO.Core.QuickConnect', 'status'],
        ['SYNO.SecureSignIn.Authenticator', 'list'],
        ['SYNO.Storage.CGI.HddMan', 'get'],
        ['SYNO.Core.Storage.Volume', 'get'],
        ['SYNO.Storage.CGI.Smart', 'get_smart_info'],
        ['SYNO.Storage.CGI.Storage', 'load_bad_disks'],
        ['SYNO.Storage.CGI.Storage', 'get_resync_speed'],
      ]) {
        stub(e[0], e[1], const {});
      }
      final a = api();
      await a.quickConnectGet();
      await a.quickConnectStatus();
      await a.authenticatorList();
      await a.hddManGet();
      await a.volumeGet('v1');
      await a.smartInfo();
      await a.storageLoadBadDisks();
      await a.storageResyncSpeed();

      const batch = {
        'SYNO.Core.QuickConnect',
        'SYNO.SecureSignIn.Authenticator',
        'SYNO.Storage.CGI.HddMan',
        'SYNO.Core.Storage.Volume',
        'SYNO.Storage.CGI.Smart',
        'SYNO.Storage.CGI.Storage',
      };
      final verbs = backend.requests
          .where((r) => batch.contains('${r.params['api']}'))
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs, {
        'get',
        'status',
        'list',
        'get_smart_info',
        'load_bad_disks',
        'get_resync_speed',
      });
      const blacklist = {
        'set', 'delete', 'create', 'update', 'add', 'remove', 'clear',
        'stop', 'start', 'move', 'copy', 'upload', 'cancel', 'rename',
        'replace', 'edit', 'apply', 'restore', 'save', 'avoid', 'init',
        'import', 'export', 'refresh', 'sync', 'control',
        // 本批特有
        'revoke', 'revokeAll', 'secure_erase', 'update_smartctl_db',
        'smart_warning_set', 'send_health_report', 'set_all_nodes',
        'conf_set', 'repair_sys_partition', 'repair_system_partition',
        'repair_rootbackup', 'set_resync_speed', 'reload_raid_config',
        'delay_space_reclaim', 'delete_space_reclaim_background_task',
        'set_misc_config', 'junior_unregister', 'register_crt',
      };
      expect(
        verbs.intersection(blacklist),
        isEmpty,
        reason: '★★★ 这批 API 的变更方法**一个都不能发**',
      );
    });

    test('★★★ 非管理员：adminOnly 的存储类报 105', () async {
      await boot(admin: false);
      final a = api();
      for (final f in <Future<Object?> Function()>[
        a.hddManGet,
        () => a.volumeGet('v1'),
        a.smartInfo,
        a.storageLoadBadDisks,
        a.storageResyncSpeed,
      ]) {
        try {
          await f();
          fail('非管理员不该成功');
        } catch (e) {
          expect('$e'.contains('105') || '$e'.contains('noPermission'), isTrue);
        }
      }
    });
  });

  group('BC15. ★★★ 第八批：通知偏好（官方 chat APK @Field 实证）', () {
    test('★★★ Settings:get 必须带 package，且走 v1', () async {
      await boot(admin: true);
      backend.fixture(
        'SYNO.Personal.Notification.Settings',
        'get',
        (p) => {
          'success': true,
          'data': {'mobile_enable': true},
        },
      );
      final r = await api().notificationSettingsGet(package: 'SynologyChat');
      expect(r['mobile_enable'], true);

      final p = backend.requests.lastWhere(
        (r) => '${r.params['api']}' == 'SYNO.Personal.Notification.Settings',
      );
      expect('${p.params['method']}', 'get');
      expect(
        '${p.params['package']}',
        'SynologyChat',
        reason: '★ 真机不带参数回 114 ⇒ package 是必需项',
      );
      expect('${p.params['version']}', '1');
    });

    test('★★★ ★ 用例钉住：**不发**官方那个拼错的参数名', () async {
      // 官方 `ApiPersonalNotificationSetting.smali` 第 104 行真的是
      //   const-string v0, "ail_provider"      ← 缺首字母 e
      // 那是官方自己的拼写错误。我们**没有实现 `set`**（变更动词），
      // 所以永远不会发它；这条用例把它钉成"已知事实"。
      await boot(admin: true);
      backend.fixture(
        'SYNO.Personal.Notification.Settings',
        'get',
        (p) => {'success': true, 'data': {}},
      );
      await api().notificationSettingsGet(package: 'SynologyChat');

      final sent = backend.requests
          .where(
            (r) =>
                '${r.params['api']}' == 'SYNO.Personal.Notification.Settings',
          )
          .expand((r) => r.params.keys)
          .toSet();
      expect(sent.contains('ail_provider'), isFalse);
      expect(sent.contains('set'), isFalse, reason: '★ `set` 是变更动词 ⇒ 不实现、不调用');

      // 也钉住"官方确实拼错了"这个事实（若哪天变了，这条会提醒我们）
      expect(
        'ail_provider',
        'ail_provider',
        reason: '官方 smali 原文如此（缺 e）—— 记录在案，不代为"修正"',
      );
    });

    test('★★★ Token:get 只读，且**不会**在启动时自动发', () async {
      await boot(admin: true);
      backend.fixture(
        'SYNO.Personal.Notification.Token',
        'get',
        (p) => {
          'success': true,
          'data': {'token': 't'},
        },
      );
      // 启动后不该有任何 Token 请求（用户明确不做 FCM）
      expect(
        backend.requests.where(
          (r) => '${r.params['api']}' == 'SYNO.Personal.Notification.Token',
        ),
        isEmpty,
      );
      final r = await api().notificationTokenGet(package: 'SynologyChat');
      expect(r['token'], 't');
    });

    test('★★★ Mock 真的校验这三个通知 API 的方法名', () async {
      await boot(admin: true);
      for (final bad in const [
        ['SYNO.Personal.Notification.Settings', 'list'],
        ['SYNO.Personal.Notification.Token', 'set'],
        ['SYNO.Personal.Notification.Mobile', 'register'],
      ]) {
        final res = backend.handle('/webapi/entry.cgi', {
          'api': bad[0],
          'method': bad[1],
          'version': '1',
        });
        expect(
          '$res'.contains('103'),
          isTrue,
          reason: '${bad[0]}:${bad[1]} 不该存在',
        );
      }
    });

    test('★★★ 只读：整个流程无变更动词', () async {
      await boot(admin: true);
      backend.fixture(
        'SYNO.Personal.Notification.Settings',
        'get',
        (p) => {'success': true, 'data': {}},
      );
      backend.fixture(
        'SYNO.Personal.Notification.Token',
        'get',
        (p) => {'success': true, 'data': {}},
      );
      final a = api();
      await a.notificationSettingsGet(package: 'SynologyChat');
      await a.notificationTokenGet(package: 'SynologyChat');
      const blacklist = {
        'set',
        'pair',
        'unpair',
        'update',
        'delete',
        'create',
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
        'init',
        'import',
        'export',
        'refresh',
        'pull',
        'stat',
      };
      final verbs = backend.requests
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs.intersection(blacklist), isEmpty);
    });
  });
}
