// ★★★ **管理工具页 UI 的成对验证**（第 77 轮）
//
// 覆盖：非管理员**进不去**（R2）· 管理员**能进**（R3）·
// 蜂鸣三种状态如实显示 · 点"停止"真的发出 `stop_beep`。
//
// ## 为什么"停止"那条必须数请求
// 点了按钮、SnackBar 弹了，**不代表请求发出去了** ——
// 断言 UI 反应会漏掉"按钮只改了本地状态"这种假实现。
// 所以这条直接用 Mock 的请求记录证明 `stop_beep` 真的发了。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/auth_extra_api.dart';
import 'package:synhub/src/data/system_admin_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/admin/admin_gate.dart';
import 'package:synhub/src/features/admin/admin_tools_page.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
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

  /// 给系统信息 / FindMe 注册默认响应（值可被单个用例覆盖）。
  void stubSysInfo({String? model, String? version}) {
    backend.fixture('SYNO.Core.System', 'info', (p) {
      return {
        'success': true,
        'data': {
          'model': ?model,
          'version': ?version,
        },
      };
    });
  }

  void stubFindMe(bool? supported) {
    backend.fixture(kFindMeApi, 'supported', (p) {
      return {
        'success': true,
        'data': {'supported': ?supported},
      };
    });
  }

  /// 渲染**真实的管理工具页**，只覆盖身份与 API 两条接线。
  Future<void> pumpTools(WidgetTester tester, {required bool admin}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isAdminProvider.overrideWith((ref) => Future.value(admin)),
          authExtraApiProvider.overrideWithValue(AuthExtraApi(web)),
          systemAdminApiProvider.overrideWithValue(SystemAdminApi(web)),
        ],
        child: MaterialApp(theme: AppTheme.dark(), home: AdminToolsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// ★★★ 懒加载 ListView 不会构建屏外行 ⇒ 断言前必须先滚到它。
  ///
  /// 第 83 轮又踩了一次：新增 5 个磁贴后，蜂鸣/系统信息被挤到屏幕外，
  /// 原来的 `find.byKey` 全部落空。**"找不到"不等于"没有"**。
  Future<Finder> tile(WidgetTester tester, String key) async {
    final f = find.byKey(Key(key));
    if (f.evaluate().isEmpty) {
      // 手写 `drag` 循环不可靠（第 83 轮踩过：`Bad state: No element`）——
      // 改用 Flutter 自带的 `scrollUntilVisible`，它会边滚边等。
      try {
        await tester.scrollUntilVisible(
          f,
          240,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 40,
        );
      } catch (_) {
        // 找不到就让调用方的断言去报错，别在这里吞掉信息
      }
      await tester.pump();
    }
    return f;
  }

  int beepCalls(String method) => backend.requests
      .where(
        (r) =>
            '${r.params['api']}' == kBeepControlApi &&
            '${r.params['method']}' == method,
      )
      .length;

  group('AT1. ★★★ 成对门控：非管理员进不去 / 管理员能进', () {
    testWidgets('★★★ 非管理员 ⇒ 看不到管理内容（R2）', (tester) async {
      await boot(admin: false);
      await pumpTools(tester, admin: false);
      expect(
        find.byKey(const Key('admin-tools-page')),
        findsNothing,
        reason: '★★★ R2：非管理员不该看到管理工具页的内容',
      );
      expect(
        find.byKey(const Key('admin-page-gate')),
        findsOneWidget,
        reason: '深链/竞态下给说明，不是白屏',
      );
    });

    testWidgets('★★★ 管理员 ⇒ 看得到管理工具页（R3）', (tester) async {
      await boot(admin: true);
      backend.fixture(kBeepControlApi, 'get', (p) {
        return {
          'success': true,
          'data': {'beep_status': false},
        };
      });
      await pumpTools(tester, admin: true);
      expect(
        find.byKey(const Key('admin-tools-page')),
        findsOneWidget,
        reason: '★★★ R3：管理员必须能正常使用管理功能',
      );
      expect(await tile(tester, 'admin-beep-tile'), findsOneWidget);
    });
  });

  group('AT2. ★★★ 蜂鸣状态如实显示（不知道 ≠ 不是）', () {
    testWidgets('★★ 正在蜂鸣 ⇒ 显示"正在蜂鸣"且**出现停止按钮**', (tester) async {
      await boot(admin: true);
      backend.fixture(kBeepControlApi, 'get', (p) {
        return {
          'success': true,
          'data': {'beep_status': true},
        };
      });
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-beep-tile');
      final st = tester.widget<Text>(find.byKey(const Key('admin-beep-state')));
      expect(st.data, contains('正在蜂鸣'));
      expect(
        find.byKey(const Key('admin-beep-stop')),
        findsOneWidget,
        reason: '★ 只在**确实在响**时才给"停止"按钮',
      );
    });

    testWidgets('★★ 未蜂鸣 ⇒ 显示"未在蜂鸣"且**没有**停止按钮', (tester) async {
      await boot(admin: true);
      backend.fixture(kBeepControlApi, 'get', (p) {
        return {
          'success': true,
          'data': {'beep_status': false},
        };
      });
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-beep-tile');
      final st = tester.widget<Text>(find.byKey(const Key('admin-beep-state')));
      expect(st.data, contains('未在蜂鸣'));
      expect(find.byKey(const Key('admin-beep-stop')), findsNothing);
    });

    testWidgets('★★★ 状态字段缺失 ⇒ 显示"状态未知"（**不是**"未在蜂鸣"）', (tester) async {
      await boot(admin: true);
      backend.fixture(kBeepControlApi, 'get', (p) {
        return {
          'success': true,
          'data': {'something_else': 1},
        };
      });
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-beep-tile');
      final st = tester.widget<Text>(find.byKey(const Key('admin-beep-state')));
      expect(
        st.data,
        contains('状态未知'),
        reason:
            '★★★ 拿不到状态时如实说"未知" —— '
            '若显示"未在蜂鸣"，用户会以为 NAS 正常（实际是没读到）',
      );
      expect(st.data, isNot(contains('未在蜂鸣')));
      expect(
        find.byKey(const Key('admin-beep-stop')),
        findsNothing,
        reason: '★ 不知道有没有在响，就不该给"停止"按钮',
      );
    });
  });

  group('AT3. ★★★ 点"停止"必须**真的发出** `stop_beep`', () {
    testWidgets('★★★ 请求记录里出现 `stop_beep`（不是只改了本地状态）', (tester) async {
      await boot(admin: true);
      backend.fixture(kBeepControlApi, 'get', (p) {
        return {
          'success': true,
          'data': {'beep_status': true},
        };
      });
      await pumpTools(tester, admin: true);
      expect(beepCalls('stop_beep'), 0, reason: '点之前不该发');

      await tile(tester, 'admin-beep-tile');
      await tester.tap(find.byKey(const Key('admin-beep-stop')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        beepCalls('stop_beep'),
        1,
        reason:
            '★★★ 用**真实请求记录**证明按钮接上了服务端；'
            '只断言 SnackBar/本地状态会漏掉"假实现"',
      );
      expect(find.byKey(const Key('admin-beep-stopped')), findsOneWidget);
    });

    testWidgets('★★★ `stop_beep` 发的是官方方法名（不是 `stop`/`set`）', (tester) async {
      await boot(admin: true);
      backend.fixture(kBeepControlApi, 'get', (p) {
        return {
          'success': true,
          'data': {'beep_status': true},
        };
      });
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-beep-tile');
      await tester.tap(find.byKey(const Key('admin-beep-stop')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == kBeepControlApi)
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs, {'get', 'stop_beep'});
      expect(
        verbs.contains('set'),
        isFalse,
        reason: '★★★ §5.1：`set` 是变更动词；官方 `ApiBeepControl` 也没用它',
      );
    });
  });

  group('AT4. ★★ 非管理员即使拿到 API 也吃 `105`（服务端第二道闸）', () {
    testWidgets('★★★ 用非管理员后端渲染 ⇒ 如实说"需要管理员权限"', (tester) async {
      // 刻意**绕过** `AdminOnly`（身份谎报为管理员），验证页面对 105 的处理：
      // 单靠客户端门控是不够的，服务端才是最终裁决。
      await boot(admin: false);
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-beep-tile');
      // 页面上**两处**都会报 105（Active Insight 与蜂鸣）—— 这是正确的，
      // 两处都如实反馈。这里**精确**断言蜂鸣那一条，而不是笼统地
      // `findsOneWidget`（第一版就是这么写才失败的）。
      await tile(tester, 'admin-beep-tile');
      final st = tester.widget<Text>(find.byKey(const Key('admin-beep-state')));
      expect(
        st.data,
        contains('需要管理员权限'),
        reason:
            '★★★ 客户端门控 + 服务端 105 是两道闸；'
            '第二道也要如实反馈，不能白屏或假装"未在蜂鸣"',
      );
      expect(find.textContaining('未在蜂鸣'), findsNothing);
    });
  });

  group('AT5. ★★★ 系统信息磁贴（`SYNO.Core.System:info`）', () {
    testWidgets('★★★ 管理员 ⇒ 显示机型与版本', (tester) async {
      await boot(admin: true);
      stubSysInfo(model: 'DS920+', version: 'DSM 7.2.2');
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-sysinfo-tile');
      final st = tester.widget<Text>(
        find.byKey(const Key('admin-sysinfo-state')),
      );
      expect(st.data, contains('DS920+'));
      expect(st.data, contains('DSM 7.2.2'));
    });

    testWidgets('★★★ 字段全缺 ⇒ 显示"系统信息未知"（不拼假字符串）', (tester) async {
      await boot(admin: true);
      stubSysInfo();
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-sysinfo-tile');
      final st = tester.widget<Text>(
        find.byKey(const Key('admin-sysinfo-state')),
      );
      expect(st.data, contains('系统信息未知'));
    });

    testWidgets('★★★ 非管理员后端 ⇒ 如实报"需要管理员权限"', (tester) async {
      await boot(admin: false);
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-sysinfo-tile');
      final st = tester.widget<Text>(
        find.byKey(const Key('admin-sysinfo-state')),
      );
      expect(st.data, contains('需要管理员权限'));
      expect(st.data, isNot(contains('系统信息未知')));
    });

    testWidgets('★★★ 调用集合 == {info}（不含 shutdown/reboot/reset）', (tester) async {
      await boot(admin: true);
      stubSysInfo(model: 'X');
      await pumpTools(tester, admin: true);
      // ★ 必须先把磁贴滚进视野：懒加载 ListView 不构建屏外行，
      // 没构建 ⇒ 请求根本没发出 ⇒ 断言 `== {info}` 会拿到**空集**
      // （第 85 轮踩的坑：单独看像"调用集合不对"，实际是"没渲染"）
      await tile(tester, 'admin-sysinfo-tile');
      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == 'SYNO.Core.System')
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs, {'info'});
      for (final bad in ['shutdown', 'reboot', 'reset']) {
        expect(verbs.contains(bad), isFalse, reason: '★★★ §5.1 黑名单');
      }
    });
  });

  group('AT6. ★★★ FindMe 磁贴（只有状态，没有启停）', () {
    testWidgets('★★★ 支持 ⇒ 显示"本机支持"', (tester) async {
      await boot(admin: true);
      stubFindMe(true);
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-findme-tile');
      final st = tester.widget<Text>(
        find.byKey(const Key('admin-findme-state')),
      );
      expect(st.data, contains('本机支持'));
    });

    testWidgets('★★ 不支持 ⇒ 显示"本机不支持"（与"未知"区分）', (tester) async {
      await boot(admin: true);
      stubFindMe(false);
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-findme-tile');
      final st = tester.widget<Text>(
        find.byKey(const Key('admin-findme-state')),
      );
      expect(st.data, contains('本机不支持'));
    });

    testWidgets('★★★ 字段缺失 ⇒ 显示"状态未知"（**不是**"本机不支持"）', (tester) async {
      await boot(admin: true);
      stubFindMe(null);
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-findme-tile');
      final st = tester.widget<Text>(
        find.byKey(const Key('admin-findme-state')),
      );
      expect(st.data, contains('状态未知'));
      expect(st.data, isNot(contains('本机不支持')));
    });

    testWidgets('★★★ **没有**启停按钮（官方 start/stop 是 §5.1 变更动词）', (tester) async {
      await boot(admin: true);
      stubFindMe(true);
      await pumpTools(tester, admin: true);
      // 磁贴里不该有任何可点元素
      final tile = find.byKey(const Key('admin-findme-tile'));
      expect(
        find.descendant(of: tile, matching: find.byType(TextButton)),
        findsNothing,
        reason:
            '★★★ 官方 FindMe 有 start/stop，但那是变更动词 ⇒ '
            '本仓不实现，界面上就不能出现启停入口',
      );
      expect(
        find.descendant(of: tile, matching: find.byType(ElevatedButton)),
        findsNothing,
      );
    });

    testWidgets('★★★ 调用集合 == {supported}（不含 start/stop）', (tester) async {
      await boot(admin: true);
      stubFindMe(true);
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-findme-tile'); // 必须滚进视野，否则没发请求
      final verbs = backend.requests
          .where((r) => '${r.params['api']}' == kFindMeApi)
          .map((r) => '${r.params['method']}')
          .toSet();
      expect(verbs, {'supported'});
      for (final bad in ['start', 'stop']) {
        expect(verbs.contains(bad), isFalse, reason: '★★★ §5.1 黑名单');
      }
    });
  });

  group('AT7. ★★★ 第三/四/五批磁贴（通用只读磁贴）', () {
    void stub(String apiName, String method, Map<String, dynamic> data) {
      backend.fixture(apiName, method, (p) {
        return {'success': true, 'data': data};
      });
    }

    /// 注册全部 5 个磁贴的响应（值可被单个用例先覆盖）。
    void stubAll() {
      stub('SYNO.Storage.CGI.Storage', 'load_info', const {});
      stub('SYNO.Storage.CGI.Smart', 'get_health_info', const {});
      stub('SYNO.Core.Storage.Volume', 'list', const {});
      stub('SYNO.Core.Package', 'list', const {});
      stub('SYNO.Core.Network', 'get', const {});
      stub('SYNO.Core.Upgrade', 'basic_status', const {});
      stub('SYNO.Core.Service', 'get', const {});
    }

    Future<String> stateOf(WidgetTester tester, String key) async {
      await tile(tester, key);
      return tester.widget<Text>(find.byKey(Key('$key-state'))).data!;
    }

    testWidgets('★★★ 管理员 ⇒ 5 个磁贴都在', (tester) async {
      await boot(admin: true);
      stubAll();
      await pumpTools(tester, admin: true);
      for (final k in const [
        'admin-storage-tile',
        'admin-diskhealth-tile',
        'admin-package-tile',
        'admin-network-tile',
        'admin-upgrade-tile',
        'admin-service-tile',
      ]) {
        expect(await tile(tester, k), findsOneWidget, reason: '$k 应存在');
      }
    });

    testWidgets('★★★ 存储：解析出卷列表', (tester) async {
      await boot(admin: true);
      stubAll();
      stub('SYNO.Core.Storage.Volume', 'list', {
        'volumes': [
          {'id': 'volume_1', 'status': 'normal'},
        ],
      });
      await pumpTools(tester, admin: true);
      expect(await stateOf(tester, 'admin-storage-tile'), contains('volume_1'));
    });

    testWidgets('★★★ 存储为空 ⇒ 「（空）」（不是空白，也不是"未知"）', (tester) async {
      await boot(admin: true);
      stubAll();
      await pumpTools(tester, admin: true);
      final st = await stateOf(tester, 'admin-storage-tile');
      expect(st, contains('（空）'));
      expect(st, isNot(contains('未知')));
    });

    testWidgets('★★★ 套件：显示数量与示例 id', (tester) async {
      await boot(admin: true);
      stubAll();
      stub('SYNO.Core.Package', 'list', {
        'packages': [
          {'id': 'SynologyDrive'},
          {'id': 'AudioStation'},
        ],
      });
      await pumpTools(tester, admin: true);
      final st = await stateOf(tester, 'admin-package-tile');
      expect(st, contains('2'));
      expect(st, contains('SynologyDrive'));
    });

    testWidgets('★★★ 升级：字段缺失 ⇒ 「系统信息未知」（不是"已是最新"）', (tester) async {
      await boot(admin: true);
      stubAll();
      await pumpTools(tester, admin: true);
      final st = await stateOf(tester, 'admin-upgrade-tile');
      expect(st, contains('系统信息未知'));
      expect(
        st,
        isNot(contains('已是最新')),
        reason: '★★★ 读不到就说读不到；说"已是最新"会让用户以为系统安全',
      );
    });

    testWidgets('★★★ 升级：`available:false` ⇒ 「已是最新」', (tester) async {
      await boot(admin: true);
      stubAll();
      stub('SYNO.Core.Upgrade', 'basic_status', {'available': false});
      await pumpTools(tester, admin: true);
      expect(await stateOf(tester, 'admin-upgrade-tile'), contains('已是最新'));
    });

    testWidgets('★★★ 非管理员后端 ⇒ 5 个磁贴全部如实报「需要管理员权限」', (tester) async {
      await boot(admin: false);
      await pumpTools(tester, admin: true);
      // ★★★ **存储不在此列**，这是一个**真实的 Mock 语义缺口**：
      // `SYNO.Core.Storage.Volume` 在目录里是 `adminOnly: false`
      // （它靠 `normal: false` / appPriv 限制普通用户），
      // 而 Mock 只在 `adminOnly == true` 时返 105
      // ⇒ 非管理员调 Volume:list **不会被 Mock 拒绝**，磁贴显示「（空）」。
      //
      // 如实记录：**Mock 目前不建模 `normal:false` 的语义**，
      // 所以这条对存储的期望不能照抄其它三个，否则就是用断言掩盖缺口。
      for (final k in const [
        'admin-package-tile',
        'admin-network-tile',
        'admin-upgrade-tile',
        'admin-service-tile',
      ]) {
        expect(
          await stateOf(tester, k),
          contains('需要管理员权限'),
          reason: '$k 应如实报 105',
        );
      }
    });

    testWidgets('★★★ 只读：这批磁贴发出的方法全在黑名单外', (tester) async {
      await boot(admin: true);
      stubAll();
      await pumpTools(tester, admin: true);
      // ★ 必须**滚到列表底部**，否则靠后的磁贴（套件/网络/升级）不会被构建
      // ⇒ 请求没发出 ⇒ 期望集合会少几个方法。
      // （请求记录是累积的，所以滚下去不会丢已发出的那些。）
      await tile(tester, 'admin-service-tile');
      const batchApis = {
        'SYNO.Storage.CGI.Storage',
        'SYNO.Storage.CGI.Smart',
        'SYNO.Core.Storage.Volume',
        'SYNO.Core.Package',
        'SYNO.Core.Network',
        'SYNO.Core.Upgrade',
        'SYNO.Core.Service',
      };
      final verbs = backend.requests
          .where((r) => batchApis.contains('${r.params['api']}'))
          .map((r) => '${r.params['method']}')
          .toSet();
      // ★ 第 84 轮：缺口二已关闭 ⇒ 存储磁贴现在**也**调 `load_info`，
      // 新增的磁盘健康磁贴调 `get_health_info`。
      // 期望集合**随实现更新**（而不是让断言继续停在旧行为上）。
      expect(verbs, {
        'load_info',
        'get_health_info',
        'list',
        'get',
        'basic_status',
      });
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
        'do_smart_test',
        'uninstall',
        'upgrade',
      };
      expect(verbs.intersection(blacklist), isEmpty, reason: '★★★ §5.1');
    });
  });

  group('AT8. ★★★ 缺口二关闭：存储池与磁盘健康**有了界面入口**', () {
    void stub(String apiName, String method, Map<String, dynamic> data) {
      backend.fixture(apiName, method, (p) {
        return {'success': true, 'data': data};
      });
    }

    testWidgets('★★★ 存储磁贴显示**存储池数**（`load_info` 真的被用上了）', (tester) async {
      await boot(admin: true);
      stub('SYNO.Storage.CGI.Storage', 'load_info', {
        'storagePools': [
          {'id': 'pool_1'},
          {'id': 'pool_2'},
        ],
      });
      stub('SYNO.Core.Storage.Volume', 'list', {
        'volumes': [
          {'id': 'volume_1', 'status': 'normal'},
        ],
      });
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-storage-tile');
      final st = tester
          .widget<Text>(find.byKey(const Key('admin-storage-tile-state')))
          .data!;
      expect(st, contains('volume_1'));
      expect(
        st,
        contains('2 个存储池'),
        reason:
            '★★★ 这与上轮不同：上轮 `load_info` 只在 API 层，UI 没用；'
            '现在必须有界面证据证明它被调用了',
      );
    });

    testWidgets('★★★ `storagePools` 缺失 ⇒ **不显示池数**（不写"0 个池"冒充）', (
      tester,
    ) async {
      await boot(admin: true);
      stub('SYNO.Storage.CGI.Storage', 'load_info', const {});
      stub('SYNO.Core.Storage.Volume', 'list', {
        'volumes': [
          {'id': 'volume_1', 'status': 'normal'},
        ],
      });
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-storage-tile');
      final st = tester
          .widget<Text>(find.byKey(const Key('admin-storage-tile-state')))
          .data!;
      expect(st, contains('volume_1'));
      expect(st, isNot(contains('存储池')), reason: '★ 拿不到就别说 —— 显示"0 个存储池"是编数据');
    });

    testWidgets('★★★ 磁盘健康磁贴：显示磁盘数（`get_health_info` 有界面入口）', (tester) async {
      await boot(admin: true);
      stub('SYNO.Storage.CGI.Smart', 'get_health_info', {
        'disks': [
          {'id': 'sda'},
          {'id': 'sdb'},
          {'id': 'sdc'},
        ],
      });
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-diskhealth-tile');
      expect(
        tester
            .widget<Text>(find.byKey(const Key('admin-diskhealth-tile-state')))
            .data!,
        contains('3 块磁盘'),
      );
    });

    testWidgets('★★ `disks` 缺失 ⇒ 磁盘健康磁贴显示「（空）」', (tester) async {
      await boot(admin: true);
      stub('SYNO.Storage.CGI.Smart', 'get_health_info', const {});
      await pumpTools(tester, admin: true);
      await tile(tester, 'admin-diskhealth-tile');
      expect(
        tester
            .widget<Text>(find.byKey(const Key('admin-diskhealth-tile-state')))
            .data!,
        contains('（空）'),
      );
    });
  });
}
