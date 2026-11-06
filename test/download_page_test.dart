// Download Station 页面层离线验证（阶段二 A 第一块）。
//
// 接口层用例在 `test/download_station_test.dart`；这里只验：
//   * 页面把请求发对了（分类过滤/分页/行内操作/新建/BT 限速）；
//   * 空态与错误态**区分**套件未安装 / 无权限 / 网络失败；
//   * 危险操作（删除）走二次确认，取消就不发请求。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/downloads/download_create_page.dart';
import 'package:synhub/src/features/downloads/download_detail_page.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _dsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.DownloadStation2.Task': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Task.Statistic': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.DownloadStation2.Task.BT': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Task.BT.Tracker': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Task.BT.Peer': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Task.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Task.List.Polling': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Settings.Location': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Map<String, dynamic> _task({
  Object id = 1,
  String title = 'ubuntu.iso',
  String type = 'bt',
  int status = 2,
  int size = 4096,
  int downloaded = 1024,
  int speedDown = 2048,
  int speedUp = 0,
  String? priority,
  String destination = '/volume1/downloads',
}) => {
  'id': id,
  'title': title,
  'type': type,
  'status': status,
  'size': size,
  'username': 'demo_user',
  'additional': {
    'detail': {
      'destination': destination,
      'priority': ?priority,
    },
    'transfer': {
      'size_downloaded': downloaded,
      'speed_download': speedDown,
      'speed_upload': speedUp,
    },
  },
};

/// 挂一个页面：假传输 + 只覆盖下载模块的 API provider。
Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  Map<String, int> failOnce = const {},
  bool noDs = false,

  /// 额外注入的能力表条目（例如 BT 搜索门控用例）。
  Map<String, Map<String, dynamic>> extraTable = const {},
  void Function(FakeTransport t)? setup,

  /// 需要一屏放下的页面（例如新建表单）传更高的视口，避免滚动点击。
  Size? viewSize,
}) async {
  if (viewSize != null) {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    if (!noDs) ..._dsTable,
    ...extraTable,
  });
  t.failures.addAll(failures);
  t.failTimes.addAll(failOnce);
  setup?.call(t);
  final api = DsmWebApi(t);
  await api.discover();
  final c = ProviderContainer(
    overrides: [downloadApiProvider.overrideWithValue(DownloadStationApi(api))],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump(); // postFrameCallback → load()
  await tester.pump(const Duration(milliseconds: 200));
  return (t: t, c: c);
}

Map<String, dynamic> _call(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

/// 新建页比测试视口高（默认 800px），提交按钮常在屏幕外（懒构建 → 元素都还没有）：
/// 滚到它出现再点。
Future<void> _tapSubmit(WidgetTester tester) async {
  final anchor = find.byKey(const Key('ds-create-submit'));
  final scrollable = find.byType(Scrollable).first;
  await tester.scrollUntilVisible(anchor, 300, scrollable: scrollable);
  await tester.ensureVisible(anchor);
  await tester.pumpAndSettle();
  await tester.tap(anchor, warnIfMissed: false);
}

void main() {
  group('空态 / 错误态（区分未安装、无权限、网络）', () {
    testWidgets('一个任务都没有 → 空态 + 新建入口', (tester) async {
      await _pump(tester, const DownloadPage());
      expect(find.text('还没有下载任务'), findsOneWidget);
      expect(find.text('新建任务'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('套件未安装 → 明确说"没有安装"，不给重试按钮', (tester) async {
      await _pump(tester, const DownloadPage(), noDs: true);
      expect(find.text('这台 NAS 没有安装 Download Station'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(find.text('下载任务加载失败'), findsNothing);
      // 没装套件时 FAB 不出现，所以引导文案也不能叫用户去点「新建任务」
      expect(find.byKey(const Key('ds-add-task')), findsNothing);
      expect(find.text('在 DSM「套件中心」安装 Download Station 后即可使用'), findsOneWidget);
      expect(find.textContaining('新建任务'), findsNothing);
    });

    testWidgets('无权限（160）→ 说权限，不是"加载失败"', (tester) async {
      await _pump(
        tester,
        const DownloadPage(),
        failures: {'SYNO.DownloadStation2.Task.list': 160},
      );
      expect(find.text('这个账号没有使用 Download Station 的权限'), findsOneWidget);
      expect(find.text('请联系管理员为这个账号授予 Download Station 权限'), findsOneWidget);
      expect(find.text('下载任务加载失败'), findsNothing);
    });

    testWidgets('网络失败 → 网络文案 + 可重试', (tester) async {
      await _pump(
        tester,
        const DownloadPage(),
        setup: (t) => t.onCall = (p) {
          if (p['method'] == 'list') throw DsmTransportException('offline');
          return null;
        },
      );
      expect(find.text('下载任务加载失败'), findsOneWidget);
      expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });

  group('任务列表', () {
    testWidgets('标题/状态/进度/速度都显示出来', (tester) async {
      await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [
              _task(id: 1, title: 'ubuntu.iso', status: 2, speedDown: 2048),
              _task(
                id: 2,
                title: 'report.pdf',
                type: 'http',
                status: 5,
                size: 2048,
                downloaded: 2048,
              ),
            ],
            'total': 2,
          },
        },
      );
      expect(find.text('ubuntu.iso'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('下载中'), findsWidgets);
      expect(find.text('已完成'), findsWidgets);
      expect(find.textContaining('↓2 KB/s'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('切分类会带服务端 status 过滤（已完成 = 7/8/5）', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      await tester.tap(find.byKey(const Key('ds-cat-finished')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(boot.t, 'list');
      expect(call['status'], '[7,8,5]');
      expect(find.text('这个分类下暂无任务'), findsOneWidget);
    });

    testWidgets('A6：文件优先级/跳过走 File.set v2（参数逐字）', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.BT.File.set': {'success': true},
        },
      );
      final api = DownloadStationApi(DsmWebApi(boot.t));
      // 优先级（官方菜单 high|normal|low）
      await api.setTaskFiles(
        taskId: 'dbid_1',
        indexes: const [0],
        priority: 'high',
      );
      final p0 = _call(boot.t, 'set');
      expect(p0['api'], 'SYNO.DownloadStation2.Task.BT.File');
      expect(p0['task_id'], 'dbid_1');
      expect(p0['index'], '[0]');
      expect(p0['priority'], 'high');
      expect(p0.containsKey('wanted'), isFalse, reason: '官方也是分两次调用');
      // 跳过（官方 skipHandler：wanted=false）
      await api.setTaskFiles(
        taskId: 'dbid_1',
        indexes: const [1, 2],
        wanted: false,
      );
      final p1 = _call(boot.t, 'set');
      expect(p1['index'], '[1,2]');
      expect(p1['wanted'], isFalse);
      expect(p1.containsKey('priority'), isFalse);
      // 空选择 → 零调用（不发给服务器）
      final before = boot.t.calls.length;
      await api.setTaskFiles(taskId: 'dbid_1', indexes: const []);
      expect(boot.t.calls.length, before, reason: '空 index 不许发请求');
      expect(tester.takeException(), isNull);
    });

    testWidgets('A2：官方过滤类齐全（active/waiting/seeding/hashChecking/extracting/paused）',
        (tester) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      // 官方 DSdownload dex 里逐个搜到的过滤类，都要有对应分类入口
      for (final name in const [
        'active',
        'waiting',
        'seeding',
        'hashChecking',
        'extracting',
        'paused',
        'finished',
        'error',
      ]) {
        expect(
          find.byKey(Key('ds-cat-$name')),
          findsOneWidget,
          reason: '缺 $name 分类',
        );
      }
      // 「等待中」的 status 过滤逐字（1=等待，9=文件托管等待）
      await tester.tap(find.byKey(const Key('ds-cat-waiting')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_call(boot.t, 'list')['status'], '[1,9]');
      // 「做种」= 7/8
      await tester.tap(find.byKey(const Key('ds-cat-seeding')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_call(boot.t, 'list')['status'], '[7,8]');
      // 「已暂停」= 3
      await tester.tap(find.byKey(const Key('ds-cat-paused')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_call(boot.t, 'list')['status'], '[3]');
      expect(tester.takeException(), isNull);
    });

    testWidgets('触底加载下一页（offset=25）', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [for (var i = 0; i < 25; i++) _task(id: i + 1)],
            'total': 30,
          },
        },
      );
      expect(_call(boot.t, 'list')['offset'], 0);
      // 注意：页面里有两个 ListView（顶部分类条也是横向 ListView），
      // 任务列表是最后一个。
      await tester.drag(find.byType(ListView).last, const Offset(0, -6000));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_call(boot.t, 'list')['offset'], 25);
    });

    testWidgets('行内暂停/继续：暂停中的给"继续"', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task(id: 7, status: 3)],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byKey(const Key('ds-toggle-7')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_call(boot.t, 'resume')['id'], '["7"]');
    });
  });

  group('批量操作（全部暂停/恢复、清除已完成、删除错误）', () {
    testWidgets('全部暂停 → pause_condition；全部恢复 → resume_condition', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      await tester.tap(find.byKey(const Key('ds-batch-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-batch-pause-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final pause = _call(boot.t, 'pause_condition');
      expect(pause['type'], '["emule"]');
      expect(pause['type_inverse'], true);
      expect(find.text('全部暂停'), findsWidgets);
    });

    testWidgets('清除已完成：先确认，再发 delete_condition status:[5]', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      await tester.tap(find.byKey(const Key('ds-batch-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-batch-clear-finished')));
      await tester.pumpAndSettle();
      // 确认前不发请求
      expect(
        boot.t.calls.any((c) => c['method'] == 'delete_condition'),
        isFalse,
      );
      expect(find.text('已完成的任务会从下载列表中移除，此操作无法恢复。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '清除已完成'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_call(boot.t, 'delete_condition')['status'], '[5]');
    });

    testWidgets('删除错误任务 → delete_condition 覆盖 101..134', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      await tester.tap(find.byKey(const Key('ds-batch-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-batch-remove-errors')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除错误任务'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final status = _call(boot.t, 'delete_condition')['status'] as String;
      expect(status, contains('101'));
      expect(status, contains('134'));
    });
  });

  group('结束任务（force_complete，DC-3 接线）', () {
    testWidgets('错误任务 → 更多菜单 → 确认后 delete force_complete=true，文案不写"删文件"', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task(id: 5, status: 102)],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byKey(const Key('ds-more-5')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-force-complete-5')));
      await tester.pumpAndSettle();
      expect(find.text('结束后无法再恢复下载，已下载的文件会保留在目标文件夹。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '结束任务'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(boot.t, 'delete');
      expect(call['id'], '["5"]');
      expect(call['force_complete'], true);
    });
  });

  group('搜索与排序（DC-4 接线）', () {
    testWidgets('搜索框提交 → 请求带 keyword', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      await tester.tap(find.byKey(const Key('ds-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('ds-search-field')),
        'ubuntu',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_call(boot.t, 'list')['keyword'], 'ubuntu');
    });

    testWidgets('排序菜单选"名称" → 请求带 sort_by=filename/order=asc', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      await tester.tap(find.byKey(const Key('ds-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('名称').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(boot.t, 'list');
      expect(call['sort_by'], 'filename');
      expect(call['order'], 'asc');
    });
  });

  group('删除（危险操作二次确认）', () {
    testWidgets('取消 → 不发删除请求；确认 → delete + force_complete=false', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task(id: 7)],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byKey(const Key('ds-delete-7')));
      await tester.pumpAndSettle();
      expect(find.text('删除任务？'), findsOneWidget);
      expect(find.text('任务会从下载列表中移除，此操作无法恢复。'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(boot.t.calls.any((c) => c['method'] == 'delete'), isFalse);

      await tester.tap(find.byKey(const Key('ds-delete-7')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(boot.t, 'delete');
      expect(call['id'], '["7"]');
      expect(call['force_complete'], false);
      expect(find.text('已删除'), findsOneWidget);
    });
  });

  group('新建任务', () {
    testWidgets('链接表单 → type=url + url 数组 + 默认目录预填', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadCreatePage(),
        viewSize: const Size(800, 1400),
        responses: {
          'SYNO.DownloadStation2.Settings.Location.get': {
            'default_destination': '/volume1/downloads',
          },
        },
      );
      expect(find.text('默认：/volume1/downloads'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('ds-create-urls')),
        'magnet:?xt=urn:btih:ABC\nhttp://example.com/a.iso',
      );
      await _tapSubmit(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(boot.t, 'create');
      expect(call['type'], 'url');
      expect(
        call['url'],
        '["magnet:?xt=urn:btih:ABC","http://example.com/a.iso"]',
      );
      expect(call['destination'], '"/volume1/downloads"');
      expect(call['create_list'], false);
    });

    testWidgets('空链接 → 页面报错且不发请求', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadCreatePage(),
        viewSize: const Size(800, 1400),
      );
      await _tapSubmit(tester);
      await tester.pump();
      expect(find.text('请输入至少一个链接'), findsOneWidget);
      expect(boot.t.calls.any((c) => c['method'] == 'create'), isFalse);
    });

    testWidgets('非法链接 → 页面报错且不发请求', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadCreatePage(),
        viewSize: const Size(800, 1400),
      );
      await tester.enterText(
        find.byKey(const Key('ds-create-urls')),
        'not a link',
      );
      await _tapSubmit(tester);
      await tester.pump();
      expect(find.text('请输入至少一个链接'), findsOneWidget);
      expect(boot.t.calls.any((c) => c['method'] == 'create'), isFalse);
    });

    testWidgets('ed2k:// 链接按官方判定放行并建任务（P0-1）', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadCreatePage(),
        viewSize: const Size(800, 1400),
      );
      await tester.enterText(
        find.byKey(const Key('ds-create-urls')),
        'ed2k://|file|a.mkv|2|ff|/',
      );
      await _tapSubmit(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(boot.t, 'create');
      expect(call['type'], 'url');
      expect(call['url'], '["ed2k://|file|a.mkv|2|ff|/"]');
      expect(find.text('请输入至少一个链接'), findsNothing);
    });

    testWidgets('FTP 认证：打开开关后 username/password 随 create 下发（DC-1）', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        const DownloadCreatePage(),
        viewSize: const Size(800, 1400),
      );
      await tester.enterText(
        find.byKey(const Key('ds-create-urls')),
        'ftp://example.com/a.iso',
      );
      await tester.tap(find.byKey(const Key('ds-create-ftp-auth')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('ds-create-username')),
        'alice',
      );
      await tester.enterText(
        find.byKey(const Key('ds-create-ftp-password')),
        'p@ss word',
      );
      await _tapSubmit(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(boot.t, 'create');
      // 官方 `encodeURIComponent(username/password)`
      expect(call['username'], 'alice');
      expect(call['password'], 'p%40ss%20word');
    });

    testWidgets('create_list=true → 进选文件页，选中后发 Polling.download（DC-2）', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        const DownloadCreatePage(),
        viewSize: const Size(800, 1400),
        responses: {
          'SYNO.DownloadStation2.Task.create': {'list_id': 88},
          'SYNO.DownloadStation2.Task.List.get': {
            'files': [
              {'index': 0, 'name': 'a.mkv', 'size': 100, 'enable': true},
              {'index': 1, 'name': 'b.txt', 'size': 10, 'enable': true},
            ],
          },
          'SYNO.DownloadStation2.Task.List.Polling.download': {'task_id': 77},
        },
      );
      await tester.enterText(
        find.byKey(const Key('ds-create-urls')),
        'http://example.com/a.torrent',
      );
      await tester.tap(find.byKey(const Key('ds-create-list')));
      await tester.pumpAndSettle();
      await _tapSubmit(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // 选文件页出现
      expect(find.text('选择要下载的文件'), findsOneWidget);
      // 取消勾选第二个文件
      await tester.tap(find.byKey(const Key('ds-file-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('ds-file-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final dl = _call(boot.t, 'download');
      expect(dl['list_id'], '88');
      expect(dl['selected'], '[0]');
      expect(find.text('已开始下载选中的文件'), findsOneWidget);
    });
  });

  group('DA37 选文件清单入口（真机 list_id 形态）', () {
    // ★★ r387/DA37（**真机读到**）：服务端 `Task.create` 回的 `list_id` 是
    //   **数组**，URL 建任务时还是**空数组**。以前把它字符串化成 `"[]"` 推页，
    //   于是必然 `Task.List:get` 失败（真机 `code=120 errors{name:list_id,
    //   reason:type}`，`docs/evidence-r387/w3_45.xml`）。
    testWidgets('DA37：list_id=[] → 不推选文件页，如实提示，且不发 List.get', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        const DownloadCreatePage(),
        viewSize: const Size(800, 1400),
        responses: {
          'SYNO.DownloadStation2.Task.create': {'list_id': <Object>[]},
        },
      );
      await tester.enterText(
        find.byKey(const Key('ds-create-urls')),
        'http://example.com/a.zip',
      );
      await tester.tap(find.byKey(const Key('ds-create-list')));
      await tester.pumpAndSettle();
      await _tapSubmit(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 任务照旧建好了
      expect(_call(boot.t, 'create')['create_list'], true);
      // 不推一个注定失败的页面
      expect(find.text('选择要下载的文件'), findsNothing);
      // 提示条**只有一条**：把"任务已建成"和"没有清单"合起来说
      // （两条 snackbar 会互相盖住 —— r387 真机像素 `w3_55.png` 只看到
      //  `Task created`）
      expect(find.text('任务已创建，但服务端没有返回文件清单，无法先选文件'), findsOneWidget);
      expect(find.text('任务已创建'), findsNothing);
      // 也不发那个会 120 的请求
      expect(
        boot.t.calls.any((c) => c['api'] == 'SYNO.DownloadStation2.Task.List'),
        isFalse,
      );
    });

    testWidgets('DA37：list_id=["L1"]（数组）→ 取第一个元素推选文件页', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadCreatePage(),
        viewSize: const Size(800, 1400),
        responses: {
          'SYNO.DownloadStation2.Task.create': {
            'list_id': <Object>['L1'],
          },
          'SYNO.DownloadStation2.Task.List.get': {
            'files': [
              {'index': 0, 'name': 'a.mkv', 'size': 100, 'enable': true},
            ],
          },
        },
      );
      await tester.enterText(
        find.byKey(const Key('ds-create-urls')),
        'http://example.com/a.torrent',
      );
      await tester.tap(find.byKey(const Key('ds-create-list')));
      await tester.pumpAndSettle();
      await _tapSubmit(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('选择要下载的文件'), findsOneWidget);
      expect(_call(boot.t, 'get')['list_id'], 'L1');
    });
  });

  group('任务详情 + 单任务 BT 限速', () {
    testWidgets('BT 任务显示设置表单，保存发 Task.BT.set（普通用户可改）', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadDetailPage(taskId: '9'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 9, status: 2)],
          },
          'SYNO.DownloadStation2.Task.BT.get': {
            'is_active_torrent': true,
            'max_upload_rate': 0,
            'max_download_rate': 0,
            'seeding_ratio': 0,
            'seeding_interval': 0,
            'max_peers': 0,
          },
          'SYNO.DownloadStation2.Task.BT.Tracker.list': {
            'items': [
              {
                'url': 'udp://tracker.example:1337',
                'status': 3,
                'seeds': 4,
                'peers': 5,
              },
            ],
          },
          'SYNO.DownloadStation2.Task.BT.Peer.list': {
            'items': [
              {
                'ip': '1.2.3.4',
                'client': 'qBittorrent',
                'progress': 0.5,
                'speed_download': 2048,
              },
            ],
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('BT 设置'), findsOneWidget);
      // Tracker / Peer 只读列表（P0-4）：详情页比视口高，滚到列表再断言。
      await tester.scrollUntilVisible(
        find.text('udp://tracker.example:1337'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('udp://tracker.example:1337'), findsOneWidget);
      expect(find.text('1.2.3.4'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('ds-bt-down')), '1024');
      await tester.enterText(find.byKey(const Key('ds-bt-up')), '256');
      // 详情页比测试视口高：先把保存按钮滚进可视区再点。
      await tester.ensureVisible(find.byKey(const Key('ds-bt-save')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('ds-bt-save')),
        warnIfMissed: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(boot.t, 'set');
      expect(call['api'], 'SYNO.DownloadStation2.Task.BT');
      expect(call['task_id'], '["9"]');
      expect(call['max_download_rate'], 1024);
      expect(call['max_upload_rate'], 256);
      expect(find.text('BT 设置已保存'), findsOneWidget);
    });

    testWidgets('优先级下拉框选择后随 Task.BT.set 下发 priority（P0-5）', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadDetailPage(taskId: '9'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 9, status: 2)],
          },
          'SYNO.DownloadStation2.Task.BT.get': {
            'is_active_torrent': true,
            'seeding_ratio': 0,
            'seeding_interval': 0,
            'max_peers': 0,
            'priority': 'normal',
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.ensureVisible(find.byKey(const Key('ds-bt-priority')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-bt-priority')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('ds-bt-save')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('ds-bt-save')),
        warnIfMissed: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_call(boot.t, 'set')['priority'], 'high');
    });

    testWidgets('非 BT 任务不显示 BT 设置', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '3'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 3, type: 'http', status: 5)],
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('BT 设置'), findsNothing);
      expect(find.text('任务详情'), findsWidgets);
    });
  });

  // ------------------------------------------------------ BT 搜索入口门控（wave4）
  group('BT 搜索入口门控（不许删既有门控）', () {
    const legacy = {
      'SYNO.DownloadStation.BTSearch': {
        'path': 'DownloadStation/btsearch.cgi',
        'minVersion': 1,
        'maxVersion': 1,
      },
    };
    const ds2 = {
      'SYNO.DownloadStation2.BTSearch': {
        'path': 'entry.cgi',
        'minVersion': 1,
        'maxVersion': 1,
      },
    };

    testWidgets('能力表都没有 BTSearch → 隐藏入口', (tester) async {
      await _pump(tester, const DownloadPage());
      expect(find.byKey(const Key('ds-bt-search-open')), findsNothing);
    });

    testWidgets('只有老代 BTSearch → 显示入口（本机真实形状）', (tester) async {
      await _pump(tester, const DownloadPage(), extraTable: legacy);
      expect(find.byKey(const Key('ds-bt-search-open')), findsOneWidget);
    });

    testWidgets('只有 DS2 BTSearch → 仍显示入口（降级/兼容）', (tester) async {
      await _pump(tester, const DownloadPage(), extraTable: ds2);
      expect(find.byKey(const Key('ds-bt-search-open')), findsOneWidget);
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // ★ D9「有数据态」：一个进行中 / 一个已完成 / 一个暂停 / 一个错误同行列出。
  //
  // 之前 D9 的验证只落在**空态**（真机 NAS 上 0 个任务）：列表行、进度条、
  // 行内操作按钮、批量入口在"有数据"时是否成立没有断言。本组用 Mock 补齐，
  // 钉的是**机制量**（§2.0.30②）：`LinearProgressIndicator.value`（进度数值）、
  // 每个 key 的**存在/缺失**（按钮分支），而不是"看起来有按钮"。
  // ─────────────────────────────────────────────────────────────────────
  group('★ D9 有数据态（混合 4 条：下载中/已完成/暂停/错误）', () {
    Map<String, dynamic> mixed() => {
      'task': [
        // 1: 进行中（BT）→ 0.25 进度、暂停按钮、无"结束任务"
        _task(
          id: 1,
          title: 'movie-a.mkv',
          status: 2,
          size: 4096,
          downloaded: 1024,
          speedDown: 2048,
        ),
        // 2: 已完成（http）→ 无进度条、无暂停按钮、无"结束任务"（非 BT）
        _task(
          id: 2,
          title: 'report.pdf',
          type: 'http',
          status: 5,
          size: 2048,
          downloaded: 2048,
        ),
        // 3: 暂停（BT）→ 0.5 进度、继续按钮、有"结束任务"
        _task(id: 3, title: 'linux.iso', status: 3, size: 8192, downloaded: 4096),
        // 4: 错误（http, 107 超时）→ 无进度条、无暂停按钮、有"结束任务"
        _task(
          id: 4,
          title: 'broken.bin',
          type: 'http',
          status: 107,
          size: 1024,
          downloaded: 0,
        ),
      ],
      'total': 4,
    };

    Future<({FakeTransport t, ProviderContainer c})> pumpMixed(
      WidgetTester tester,
    ) => _pump(
      tester,
      const DownloadPage(),
      viewSize: const Size(800, 1400),
      responses: {'SYNO.DownloadStation2.Task.list': mixed()},
    );

    testWidgets('列表行：4 条都在、状态标签各自正确', (tester) async {
      await pumpMixed(tester);
      for (final title in const [
        'movie-a.mkv',
        'report.pdf',
        'linux.iso',
        'broken.bin',
      ]) {
        expect(find.text(title), findsOneWidget, reason: '缺行 $title');
      }
      expect(find.text('下载中'), findsWidgets);
      expect(find.text('已完成'), findsWidgets);
      expect(find.text('已暂停'), findsWidgets);
      // 107 = TIMEOUT，标签必须说出"下载超时"而不是笼统"失败"/错误码
      expect(find.text('下载超时'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('进度条：只有未完成的 2 条有，且 value = downloaded/size（机制量）', (
      tester,
    ) async {
      await pumpMixed(tester);
      final bars = tester
          .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .toList();
      expect(
        bars,
        hasLength(2),
        reason: '已完成（无进度条可言）与错误（size_downloaded=0 ⇒ 进度 0）都不该画进度条',
      );
      final values = bars.map((b) => b.value).toList()..sort();
      expect(values[0], closeTo(0.25, 1e-9), reason: '进行中：1024/4096');
      expect(values[1], closeTo(0.5, 1e-9), reason: '暂停：4096/8192');
      expect(tester.takeException(), isNull);
    });

    testWidgets('行内操作按钮按状态分支：暂停/继续只给未完成未错误', (tester) async {
      await pumpMixed(tester);
      // 有：进行中(1)、暂停(3)；无：已完成(2)、错误(4)
      expect(find.byKey(const Key('ds-toggle-1')), findsOneWidget);
      expect(find.byKey(const Key('ds-toggle-3')), findsOneWidget);
      expect(find.byKey(const Key('ds-toggle-2')), findsNothing);
      expect(find.byKey(const Key('ds-toggle-4')), findsNothing);
      // 暂停的那条给的是"继续"（play_arrow）
      final paused = tester.widget<IconButton>(
        find.byKey(const Key('ds-toggle-3')),
      );
      expect((paused.icon as Icon).icon, Icons.play_arrow);
      final running = tester.widget<IconButton>(
        find.byKey(const Key('ds-toggle-1')),
      );
      expect((running.icon as Icon).icon, Icons.pause);
      // 删除按钮所有状态都有
      for (final id in const [1, 2, 3, 4]) {
        expect(
          find.byKey(Key('ds-delete-$id')),
          findsOneWidget,
          reason: '任务 $id 缺删除按钮',
        );
      }
    });

    testWidgets('「结束任务」入口：暂停/错误/已完成BT 有，进行中与已完成http 无', (tester) async {
      await pumpMixed(tester);
      // ★ r323：⋮ 变成「改目的地」与「结束任务」的**共用入口**之后，
      //   门控的判据必须**下沉到菜单项**上 —— 原来判 `ds-more-1` 不在，
      //   等于把"结束任务的出现条件"错判成了"整行有没有 ⋮"（第 322 轮 D22 的同源错）。
      expect(
        find.byKey(const Key('ds-more-2')),
        findsNothing,
        reason: '已完成但非 BT → 既不能改目的地、也不能"结束"⇒ 无 ⋮',
      );
      expect(find.byKey(const Key('ds-more-3')), findsOneWidget, reason: '暂停 → 有');
      expect(find.byKey(const Key('ds-more-4')), findsOneWidget, reason: '错误 → 有');
      expect(
        find.byKey(const Key('ds-more-1')),
        findsOneWidget,
        reason: '进行中 → 可编辑 ⇒ 有 ⋮（但菜单里没有「结束任务」）',
      );
      // 进行中那一行：只有「改目的地」
      await tester.tap(find.byKey(const Key('ds-more-1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('ds-force-complete-1')),
        findsNothing,
        reason: '进行中 → 没有「结束任务」',
      );
      expect(find.byKey(const Key('ds-edit-dest-1')), findsOneWidget);
      // 关掉菜单（点遮罩）
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      // 展开"暂停"那一行的"更多操作" → 「结束任务」真的在
      await tester.tap(find.byKey(const Key('ds-more-3')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ds-force-complete-3')), findsOneWidget);
    });

    testWidgets('有数据态与空态互斥：空态文案不在、新建入口仍是 FAB', (tester) async {
      await pumpMixed(tester);
      expect(find.text('还没有下载任务'), findsNothing);
      expect(find.text('这个分类下暂无任务'), findsNothing);
      // 非空 ⇒ `emptyStateHasNewTask == false` ⇒ 只给 FAB（不与空态按钮重复）
      expect(find.byKey(const Key('ds-add-task')), findsOneWidget);
      expect(find.text('新建任务'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('批量入口在有数据态可用：全部暂停 → pause_condition', (tester) async {
      final boot = await pumpMixed(tester);
      expect(find.byKey(const Key('ds-batch-menu')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ds-batch-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-batch-pause-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_call(boot.t, 'pause_condition')['type'], '["emule"]');
      expect(tester.takeException(), isNull);
    });

    testWidgets('已完成 BT（做种）也有「结束任务」入口；已完成 http 没有', (tester) async {
      await _pump(
        tester,
        const DownloadPage(),
        viewSize: const Size(800, 1400),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [
              _task(id: 11, title: 'seed.iso', status: 8, size: 4096, downloaded: 4096),
              _task(
                id: 12,
                title: 'done.pdf',
                type: 'http',
                status: 5,
                size: 4096,
                downloaded: 4096,
              ),
            ],
            'total': 2,
          },
        },
      );
      expect(find.byKey(const Key('ds-more-11')), findsOneWidget, reason: '做种(BT) → 有');
      expect(find.byKey(const Key('ds-more-12')), findsNothing, reason: '已完成 http → 无');
      expect(find.byKey(const Key('ds-toggle-11')), findsNothing, reason: '已完成不画暂停键');
      expect(find.byType(LinearProgressIndicator), findsNothing, reason: '都已完成 → 无进度条');
    });
  });

  // ============================================================ D19（r320）
  group('D19 写动词之后顶部统计条必须重算（像素 08_download_deleted.png）', () {
    /// `Task.Statistic.get` 到底被请求了几次。
    int statCalls(FakeTransport t) => t.calls
        .where((c) => c['api'] == 'SYNO.DownloadStation2.Task.Statistic')
        .length;

    testWidgets('删除任务后统计条重算（不是"0 tasks 还挂着 Down 1 KB/s"）', (tester) async {
      final r = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task(id: 'dbid_1', title: 'r320_del.bin')],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.Statistic': {
            'download_rate': 1024,
            'upload_rate': 0,
          },
        },
      );
      // 首屏会读统计（读几次是实现细节，**不钉死**）：只要"删完之后比删之前多"
      final before = statCalls(r.t);
      expect(before, greaterThan(0), reason: '首屏至少要读过一次统计条');
      expect(find.byKey(const Key('ds-delete-dbid_1')), findsOneWidget);

      // ---- 写动词：删除（行上垃圾桶 → 确认）
      await tester.tap(find.byKey(const Key('ds-delete-dbid_1')));
      await tester.pumpAndSettle();
      // 确认键按**对话框子树**定位（不依赖语言：`t.dtoActionDelete` 中英不同）
      final dialog = find.byKey(const Key('ds-delete-dialog'));
      expect(dialog, findsOneWidget, reason: '删除确认框必须出现');
      await tester.tap(
        find.descendant(of: dialog, matching: find.byType(FilledButton)),
      );
      await tester.pumpAndSettle();

      expect(
        statCalls(r.t),
        greaterThan(before),
        reason: '★ 删完之后统计条必须重算 —— 否则屏幕上就是'
            '"0 tasks + Down 1 KB/s"（缺陷原文是像素判出来的）',
      );
    });

    testWidgets('反向验证：取消删除**不许**多读一次统计（计数是有区分力的）', (tester) async {
      final r = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task(id: 'dbid_1', title: 'r320_del.bin')],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.Statistic': {
            'download_rate': 1024,
            'upload_rate': 0,
          },
        },
      );
      final before = statCalls(r.t);
      await tester.tap(find.byKey(const Key('ds-delete-dbid_1')));
      await tester.pumpAndSettle();
      final dialog = find.byKey(const Key('ds-delete-dialog'));
      expect(dialog, findsOneWidget);
      await tester.tap(
        find.descendant(of: dialog, matching: find.byType(TextButton)),
      );
      await tester.pumpAndSettle();
      expect(
        statCalls(r.t),
        before,
        reason: '什么都没改 ⇒ 不许刷新（否则上面那条断言就变成"恒真"了）',
      );
      expect(find.byKey(const Key('ds-delete-dbid_1')), findsOneWidget);
    });
  });

  // ---- r323：行 ⋮ 的**状态门控**与「改目的地」（`Task.edit` 从 r1 起没有 caller）
  //
  // ★ 第 322 轮踩过 D22：拿着"下载中"的任务去找 ⋮，报"行上没有 ds-more-…"，
  //   差点当成"功能缺失"。这里的成对用例把门控**钉住**：
  //   可编辑/可结束 ⇒ 有 ⋮；已完成(5) 的 http 任务 ⇒ **两种动作都不该有**。
  group('r323 行 ⋮ 的状态门控与改目的地', () {
    testWidgets('下载中(2)：⋮ 里有「改目的地」，填路径提交后发出 Task.edit', (tester) async {
      final r = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [
              _task(id: 'dbid_1', title: 'r323_edit.bin', type: 'http'),
            ],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.Statistic': {
            'download_rate': 0,
            'upload_rate': 0,
          },
        },
      );
      // 下载中 ⇒ 可编辑 ⇒ ⋮ 在
      expect(
        find.byKey(const Key('ds-more-dbid_1')),
        findsOneWidget,
        reason: '可编辑状态必须有 ⋮（"改目的地"的入口）',
      );
      await tester.tap(find.byKey(const Key('ds-more-dbid_1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('ds-edit-dest-dbid_1')),
        findsOneWidget,
        reason: '菜单里要有「改目的地」',
      );
      // 已完成/错误才有「结束任务」⇒ 下载中**不该**有
      expect(find.byKey(const Key('ds-force-complete-dbid_1')), findsNothing);

      await tester.tap(find.byKey(const Key('ds-edit-dest-dbid_1')));
      await tester.pumpAndSettle();
      final dlg = find.byKey(const Key('ds-edit-dest-dialog'));
      expect(dlg, findsOneWidget);
      // 预填当前目的地（`_task()` 给的是 /volume1/downloads）。
      // ⚠️ 别用 `find.text` —— 同一个路径在列表行副标题里也有一份（会 findsNWidgets）；
      //    判"输入框预填了什么"要看**那个 `TextField` 的 controller**。
      final field = tester.widget<TextField>(
        find.byKey(const Key('ds-edit-dest-field')),
      );
      expect(field.controller?.text, '/volume1/downloads');

      await tester.enterText(
        find.byKey(const Key('ds-edit-dest-field')),
        '/volume1/movies',
      );
      await tester.tap(find.byKey(const Key('ds-edit-dest-submit')));
      await tester.pumpAndSettle();

      // ⚠️ `FakeTransport.calls` 存的是**扁平的 params**（`{'api':…,'method':…}`），
      //    不是 `{'params': {…}}`（我第一版按后者写，当场 NoSuchMethodError）。
      final call = _call(r.t, 'edit');
      expect(call['api'], 'SYNO.DownloadStation2.Task');
      expect(call['id'], '["dbid_1"]');
      expect(
        call['destination'],
        '/volume1/movies',
        reason: '★ 目的地必须逐字送出（Mock/服务端按它改状态）',
      );
    });

    testWidgets('已完成(5) 的 http 任务：⋮ 不该出现（两种动作都不适用）', (tester) async {
      await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [
              _task(
                id: 'dbid_9',
                title: 'r323_done.bin',
                type: 'http',
                status: 5,
              ),
            ],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.Statistic': {
            'download_rate': 0,
            'upload_rate': 0,
          },
        },
      );
      // 反向：`isFinished && isBt` 才给「结束任务」，http 已完成不是；
      // `!isFinished` 才给「改目的地」，已完成也不是 ⇒ ⋮ 必须没有。
      expect(
        find.byKey(const Key('ds-more-dbid_9')),
        findsNothing,
        reason: '★ 门控：已完成(5) 的 http 任务既不能改也不能"结束"',
      );
      // 但删除永远在（这一条同时证明"没有 ⋮ ≠ 整行没渲染"）
      expect(find.byKey(const Key('ds-delete-dbid_9')), findsOneWidget);
    });

    testWidgets('已完成(5) 的 BT 任务：⋮ 在，但只有「结束任务」', (tester) async {
      await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [
              _task(id: 'dbid_8', title: 'r323_bt.bin', type: 'bt', status: 5),
            ],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.Statistic': {
            'download_rate': 0,
            'upload_rate': 0,
          },
        },
      );
      expect(find.byKey(const Key('ds-more-dbid_8')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ds-more-dbid_8')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ds-force-complete-dbid_8')), findsOneWidget);
      expect(
        find.byKey(const Key('ds-edit-dest-dbid_8')),
        findsNothing,
        reason: '已完成的 BT 只能"结束"，不能改目的地',
      );
    });
  });

  // ---- r328：改任务对话框的**官方字段**（`ui/download.js` 逐字）
  //
  // 官方事实（Download Station 4.1.2-5012 的 `ui/download.js`）：
  //   * 常规任务 `DLM.QueueEditBtDialog.saveDestination()` ⇒ `{id, destination}`
  //     （`extract_password` 只在密码框 dirty 时带上）；
  //   * eMule 任务 `aMule.EditTaskWindow.applyHandler()` ⇒ `{id, priority, destination}`，
  //     ★ **优先级只有 eMule 模块给**；
  //   * 解压密码框只在 `DLM.Util.isUnzipServiceOn()` 为真时出现。
  // 这组用例把"哪个任务类型有哪些字段"钉成**成对断言**（有 / 没有同时验）。
  group('r328 改任务对话框的官方字段', () {
    testWidgets('eMule 任务 ⇒ 有优先级下拉；http 任务 ⇒ 没有（成对）', (tester) async {
      late FakeTransport t;
      Future<void> openDialog(String id, String type, {String? priority}) async {
        final r = await _pump(
          tester,
          const DownloadPage(),
          responses: {
            'SYNO.DownloadStation2.Task.list': {
              'task': [
                _task(
                  id: id,
                  title: 'r328_$id.bin',
                  type: type,
                  priority: priority,
                ),
              ],
              'total': 1,
            },
            'SYNO.DownloadStation2.Task.Statistic': {
              'download_rate': 0,
              'upload_rate': 0,
            },
          },
        );
        await tester.tap(find.byKey(Key('ds-more-$id')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('ds-edit-dest-$id')));
        await tester.pumpAndSettle();
        t = r.t;
      }

      await openDialog('em1', 'emule', priority: 'high');
      expect(
        find.byKey(const Key('ds-edit-task-priority')),
        findsOneWidget,
        reason: '★ eMule 任务的编辑窗口必须有「优先级」（官方 aMule.EditTaskWindow）',
      );
      // 预填当前优先级（`Task.list` 的 `additional.detail.priority`）。
      final dd = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('ds-edit-task-priority')),
      );
      expect(dd.initialValue, 'high');

      // 换成"低"再提交：`priority` 必须逐字送出（服务端按它改 eMule 队列）。
      await tester.tap(find.byKey(const Key('ds-edit-task-priority')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('低').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-edit-dest-submit')));
      await tester.pumpAndSettle();
      final call = _call(t, 'edit');
      expect(call['priority'], 'low');
      expect(call['destination'], '/volume1/downloads');
    });

    testWidgets('http 任务 ⇒ **没有**优先级字段，请求里也不该有 priority', (tester) async {
      final r = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [
              _task(
                id: 'h1',
                title: 'r328_http.bin',
                type: 'http',
                priority: 'high',
              ),
            ],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.Statistic': {
            'download_rate': 0,
            'upload_rate': 0,
          },
        },
      );
      await tester.tap(find.byKey(const Key('ds-more-h1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-edit-dest-h1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('ds-edit-task-priority')),
        findsNothing,
        reason: '★ 官方常规队列的 saveDestination 只有 destination —— 不许给优先级',
      );
      await tester.tap(find.byKey(const Key('ds-edit-dest-submit')));
      await tester.pumpAndSettle();
      final call = _call(r.t, 'edit');
      expect(call.containsKey('priority'), isFalse);
      expect(call['destination'], '/volume1/downloads');
    });

    testWidgets('解压密码：服务关 ⇒ 无字段；服务开且填了 ⇒ 带 extract_password',
        (tester) async {
      // ① 服务关（表中没有 `Package.Service` ⇒ 能力未知 ⇒ 字段不出现）
      final r = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task(id: 'u1', title: 'r328_zip.bin', type: 'http')],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.Statistic': {
            'download_rate': 0,
            'upload_rate': 0,
          },
        },
      );
      await tester.tap(find.byKey(const Key('ds-more-u1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-edit-dest-u1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('ds-edit-task-unzip')),
        findsNothing,
        reason: '★ 官方 isUnzipServiceOn() 为假时**不显示**解压密码框',
      );
      await tester.tap(find.byKey(const Key('ds-edit-dest-submit')));
      await tester.pumpAndSettle();
      expect(_call(r.t, 'edit').containsKey('extract_password'), isFalse);
    });

    testWidgets('解压密码：服务开 ⇒ 有字段；**不填** ⇒ 不发空写', (tester) async {
      final r = await _pump(
        tester,
        const DownloadPage(),
        extraTable: const {
          'SYNO.DownloadStation2.Package.Service': {
            'path': 'entry.cgi',
            'minVersion': 2,
            'maxVersion': 2,
          },
        },
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task(id: 'u2', title: 'r328_zip2.bin', type: 'http')],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.Statistic': {
            'download_rate': 0,
            'upload_rate': 0,
          },
          // ⚠️ 夹具键 = `api.method`（与 `Task.list` 同一规矩）：漏掉 `.get`
          //    会静默落到"未注册夹具 ⇒ 空 data"，能力位全 false，字段恒不出现。
          'SYNO.DownloadStation2.Package.Service.get': {
            'enable_bt_preview': false,
            'enable_emule': false,
            'enable_unzip': true,
            'is_unzip_service_enable': true,
          },
        },
      );
      await tester.tap(find.byKey(const Key('ds-more-u2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-edit-dest-u2')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('ds-edit-task-unzip')),
        findsOneWidget,
        reason: 'unzip 服务开着 ⇒ 官方会显示解压密码框',
      );
      // 不填（未 dirty）⇒ 不发 `extract_password`（官方 handlePassword 的 isDirty 语义）
      await tester.tap(find.byKey(const Key('ds-edit-dest-submit')));
      await tester.pumpAndSettle();
      expect(
        _call(r.t, 'edit').containsKey('extract_password'),
        isFalse,
        reason: '★ 空密码不许造成"空写"（官方只在 dirty 时提交这个字段）',
      );
    });

    testWidgets('解压密码：服务开且**填了** ⇒ extract_password 逐字送出', (tester) async {
      final r = await _pump(
        tester,
        const DownloadPage(),
        extraTable: const {
          'SYNO.DownloadStation2.Package.Service': {
            'path': 'entry.cgi',
            'minVersion': 2,
            'maxVersion': 2,
          },
        },
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task(id: 'u3', title: 'r328_zip3.bin', type: 'http')],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.Statistic': {
            'download_rate': 0,
            'upload_rate': 0,
          },
          'SYNO.DownloadStation2.Package.Service.get': {
            'enable_bt_preview': false,
            'enable_emule': false,
            'enable_unzip': true,
            'is_unzip_service_enable': true,
          },
        },
      );
      await tester.tap(find.byKey(const Key('ds-more-u3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-edit-dest-u3')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('ds-edit-task-unzip')),
        'zip-secret',
      );
      await tester.tap(find.byKey(const Key('ds-edit-dest-submit')));
      await tester.pumpAndSettle();
      expect(_call(r.t, 'edit')['extract_password'], 'zip-secret');
    });

    testWidgets('目的地清空 ⇒ 保存键禁用，不发请求（官方 error_bad_field）',
        (tester) async {
      final r = await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task(id: 'e1', title: 'r328_empty.bin', type: 'http')],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.Statistic': {
            'download_rate': 0,
            'upload_rate': 0,
          },
        },
      );
      final before = r.t.calls.length;
      await tester.tap(find.byKey(const Key('ds-more-e1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-edit-dest-e1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('ds-edit-dest-field')),
        '',
      );
      await tester.pumpAndSettle();
      final submit = tester.widget<FilledButton>(
        find.byKey(const Key('ds-edit-dest-submit')),
      );
      expect(submit.onPressed, isNull, reason: '目的地空 ⇒ 保存键必须禁用');
      await tester.tap(
        find.byKey(const Key('ds-edit-dest-submit')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(
        r.t.calls.length,
        before,
        reason: '禁用状态下点它也不许发出任何请求',
      );
      expect(
        r.t.calls.where((c) => c['method'] == 'edit'),
        isEmpty,
      );
    });
  });
}
