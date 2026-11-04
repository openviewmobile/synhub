// 批次 G3 · 下载模块 7 行缺口的**页面层**离线验证（mock，不依赖真机）。
//
//   * B8  详情页「修改下载目的地」→ `Task/edit`；
//   * B10 详情页文件行「复制到…」→ `Task.BT.File/copy`；
//   * C12 新建页「立即开始」关掉 → 创建后 `Task/pause`；
//   * F5/F6 NZB 任务的日志/文件清单区块；
//   * F14 设置页套件版本 / 模块 / 能力位；
//   * F12 DownloadPage 检测到"刚刚完成"→ 应用内提示。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/downloads/download_completion.dart';
import 'package:synhub/src/features/downloads/download_create_page.dart';
import 'package:synhub/src/features/downloads/download_detail_page.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';
import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/features/downloads/download_settings_page.dart';
import 'package:synhub/src/features/downloads/download_labels.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';

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
  'SYNO.DownloadStation2.Task.BT.File': {
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
  'SYNO.DownloadStation2.Task.NZB.Log': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.DownloadStation2.Task.NZB.File': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.DownloadStation2.Settings.Location': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.DownloadStation2.Settings.AutoExtraction': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.DownloadStation2.Package.Info': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Package.Module': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Package.Service': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
};

Map<String, dynamic> _task({
  Object id = 1,
  String title = 'ubuntu.iso',
  String type = 'bt',
  int status = 2,
  int createdTime = 100,
  String destination = '/volume1/downloads',
}) => {
  'id': id,
  'title': title,
  'type': type,
  'status': status,
  'size': 4096,
  'additional': {
    'detail': {'destination': destination, 'created_time': createdTime},
    'transfer': {'size_downloaded': 1024, 'speed_download': 2048},
  },
};

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  void Function(FakeTransport t)? setup,
  List<Object> overrides = const [],
  List<String> dropApis = const [],
  Size viewSize = const Size(900, 2600),
}) async {
  tester.view.physicalSize = viewSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final table = {...FakeTransport.table, ..._dsTable}
    ..removeWhere((k, _) => dropApis.contains(k));
  final t = FakeTransport(responses, table);
  setup?.call(t);
  final api = DsmWebApi(t);
  await api.discover();
  final c = ProviderContainer(
    overrides: [
      downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
      // 不让 widget 测试去打开真实 drift 数据库。
      downloadNotifyStoreProvider.overrideWithValue(
        MemoryDownloadNotifyStore(),
      ),
      ...overrides,
    ].cast(),
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return (t: t, c: c);
}

Map<String, dynamic> _callOf(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

Iterable<Map<String, dynamic>> _allOf(FakeTransport t, String method) =>
    t.calls.where((c) => c['method'] == method);

void main() {
  group('B8 页面：详情页修改下载目的地', () {
    testWidgets('点按钮 → 弹框预填 → 保存发 Task/edit', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadDetailPage(taskId: '1'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 1, type: 'http', status: 2)],
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('ds-edit-destination')), findsOneWidget);

      await tester.tap(find.byKey(const Key('ds-edit-destination')));
      await tester.pumpAndSettle();
      // 预填当前目的地（字段里 + 详情区各一处）
      expect(find.text('/volume1/downloads'), findsWidgets);

      await tester.enterText(
        find.byKey(const Key('ds-edit-dest-field')),
        '/volume1/movies',
      );
      await tester.tap(find.byKey(const Key('ds-dest-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final call = _callOf(boot.t, 'edit');
      expect(call['api'], 'SYNO.DownloadStation2.Task');
      expect(call['id'], jsonEncode(['1']));
      expect(call['destination'], '/volume1/movies');
      expect(find.text('下载目的地已修改'), findsOneWidget);
    });

    testWidgets('已完成任务不显示目的地编辑入口', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '1'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 1, type: 'http', status: 5)],
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('ds-edit-destination')), findsNothing);
    });
  });

  group('B10 页面：文件清单「复制到…」', () {
    testWidgets('点复制 → 填目录 → 发 Task.BT.File/copy', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadDetailPage(taskId: '1'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 1, type: 'bt', status: 2)],
          },
          'SYNO.DownloadStation2.Task.BT.File.list': {
            'items': [
              {'index': 0, 'name': 'movie.mkv', 'size': 100, 'wanted': true},
            ],
            'total': 1,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('ds-file-copy-0')), findsOneWidget);

      await tester.tap(find.byKey(const Key('ds-file-copy-0')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('ds-copy-dest-field')),
        '/volume1/copy',
      );
      await tester.tap(find.byKey(const Key('ds-dest-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final call = _callOf(boot.t, 'copy');
      expect(call['api'], 'SYNO.DownloadStation2.Task.BT.File');
      expect(call['version'], '2');
      expect(call['task_id'], '1');
      expect(call['index'], jsonEncode([0]));
      expect(call['destination'], '/volume1/copy');
      expect(find.text('已开始复制文件'), findsOneWidget);
    });
  });

  group('C12 页面：新建任务的「立即开始」开关', () {
    testWidgets('关掉「立即开始」→ 创建后对新任务发 Task/pause', (tester) async {
      var listCalls = 0;
      final boot = await _pump(
        tester,
        const DownloadCreatePage(),
        responses: {
          'SYNO.DownloadStation2.Settings.Location.get': {
            'default_destination': '/volume1/downloads',
          },
        },
        setup: (t) {
          t.onCall = (p) {
            if (p['api'] == 'SYNO.DownloadStation2.Task' &&
                p['method'] == 'list') {
              listCalls++;
              // 第一次 = 创建前快照（空）；之后 = 新任务已出现
              return listCalls == 1
                  ? {'task': <dynamic>[], 'total': 0}
                  : {
                      'task': [_task(id: 77, createdTime: 999)],
                      'total': 1,
                    };
            }
            return null;
          };
        },
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(
        find.byKey(const Key('ds-create-urls')),
        'https://example.com/a.iso',
      );
      // 关掉「立即开始下载」
      await tester.tap(find.byKey(const Key('ds-create-immediate')));
      await tester.pump();

      final submit = find.byKey(const Key('ds-create-submit'));
      await tester.scrollUntilVisible(
        submit,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.tap(submit, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(_allOf(boot.t, 'create'), isNotEmpty);
      final pause = _callOf(boot.t, 'pause');
      expect(pause['api'], 'SYNO.DownloadStation2.Task');
      expect(pause['id'], jsonEncode(['77']));
    });
  });

  group('F5/F6 页面：NZB 日志与文件清单', () {
    testWidgets('NZB 任务显示日志正文与文件行', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '1'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 1, type: 'nzb', status: 2)],
          },
          'SYNO.DownloadStation2.Task.NZB.Log.get': {
            'nzblog': 'par2 ok\nunrar ok',
          },
          'SYNO.DownloadStation2.Task.NZB.File.list': {
            'items': [
              {'name': 'release.rar', 'size': 1024},
            ],
            'total': 1,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('ds-nzb-log-text')), findsOneWidget);
      expect(find.text('release.rar'), findsOneWidget);
    });

    testWidgets('非 NZB 任务不显示 NZB 区块', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '1'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 1, type: 'http', status: 2)],
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('ds-nzb-log-text')), findsNothing);
      expect(find.text('NZB 文件列表'), findsNothing);
    });
  });

  group('F14 页面：设置页套件信息 / 模块 / 能力位', () {
    testWidgets('显示版本、模块与能力位', (tester) async {
      await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': false,
          },
          'SYNO.DownloadStation2.Package.Info.get': {
            'major': 4,
            'minor': 1,
            'build_number': 5012,
            'is_manager': false,
          },
          'SYNO.DownloadStation2.Package.Module.list': {
            'listItems': [
              {'fn': 'a', 'folder': 'dlm'},
              {'fn': 'b', 'folder': 'aMule'},
            ],
          },
          'SYNO.DownloadStation2.Package.Service.get': {
            'enable_bt_preview': true,
            'enable_emule': true,
            'enable_unzip': false,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('版本 4.1-5012'), findsOneWidget);
      expect(find.textContaining('BT · eMule'), findsOneWidget);
      expect(find.byKey(const Key('ds-package-capabilities')), findsOneWidget);
      expect(find.text('BT 预览 ✓'), findsOneWidget);
      expect(find.text('自动解压 ✗'), findsOneWidget);
    });

    // ★ DA34（r387 **真机撞到**）：保存自动解压开关后，**同一页**上的
    //   `Auto extract ✓/✗` 能力位（来自 `Package.Service.get` 的 `enable_unzip`）
    //   必须跟着刷新 —— 否则页面同时显示"开关=关"和"自动解压 ✓"（自相矛盾）。
    //   真机读数：`docs/evidence-r387/w3_14.xml`（switch=false 而 chip=✓）。
    testWidgets('DA34：保存后能力位跟着刷新（不再与开关自相矛盾）', (tester) async {
      var serviceCalls = 0;
      final boot = await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': false,
          },
          'SYNO.DownloadStation2.Package.Info.get': {
            'major': 4,
            'minor': 1,
            'build_number': 5012,
          },
          'SYNO.DownloadStation2.Package.Module.list': {
            'listItems': [
              {'fn': 'a', 'folder': 'dlm'},
            ],
          },
        },
        setup: (t) {
          // 服务端的 `enable_unzip` 真的会变：第一次读 = false，之后 = true。
          t.onCall = (params) {
            if (params['api'] == 'SYNO.DownloadStation2.Package.Service' &&
                params['method'] == 'get') {
              serviceCalls++;
              return {
                'enable_bt_preview': true,
                'enable_emule': true,
                'enable_unzip': serviceCalls > 1,
              };
            }
            return null;
          };
        },
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('自动解压 ✗'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ds-auto-extract')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(serviceCalls, greaterThan(1), reason: '保存后必须**重新读**能力位');
      expect(find.text('自动解压 ✓'), findsOneWidget);
      expect(find.text('自动解压 ✗'), findsNothing);
      expect(boot.c.read(downloadAutoExtractionProvider).value?.enableUnzip, isNotNull);
    });

    testWidgets('能力表没有 Package.* → 不显示套件信息块', (tester) async {
      await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': false,
          },
        },
        dropApis: const [
          'SYNO.DownloadStation2.Package.Info',
          'SYNO.DownloadStation2.Package.Module',
          'SYNO.DownloadStation2.Package.Service',
        ],
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('ds-package-version')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('F12 页面：任务完成应用内提示', () {
    testWidgets('轮询检测到"下载中 → 完成"→ 弹完成提示', (tester) async {
      var listCalls = 0;
      await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task(id: 1, status: 5)],
            'total': 1,
          },
        },
        overrides: [
          downloadCompletionPollIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 30),
          ),
        ],
        setup: (t) {
          t.onCall = (p) {
            if (p['api'] == 'SYNO.DownloadStation2.Task' &&
                p['method'] == 'list') {
              listCalls++;
              // 第 1 次（页面 load）与第 2 次（首次轮询播种）回"下载中"；
              // 之后回"已完成" → 第 3 次轮询检出转移。
              return {
                'task': [_task(id: 1, status: listCalls <= 2 ? 2 : 5)],
                'total': 1,
              };
            }
            return null;
          };
        },
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(find.textContaining('下载完成'), findsWidgets);
    });
  });

  // ---------------------------------------------------------------- DA59（r407）
  //
  // 真机撞到：设置页把服务端枚举**原样**上屏（`Extract to: current_folder`）。
  // 判据只能取真机 dump/像素；这里把它钉成回归（含"未知枚举不许编名字"）。
  group('DA59 · 解压位置的服务端枚举不许当用户文案', () {
    test('枚举 → 文案：已知值翻译，未知值**原样透传**（不许编）', () {
      expect(dsUnzipLocationLabel(AppTextZh(), 'current_folder'), '下载文件夹');
      // ★ DA64（r410）：官方 4.1.2 `ui/download.js` 的第二档真值是
      //   `select_folder`（不是我们 r407 写的 `specified_folder`）。
      expect(dsUnzipLocationLabel(AppTextZh(), 'select_folder'), '指定文件夹');
      // 非官方值**不再**被翻译（它服务端从来没发过）⇒ 原样透传。
      expect(dsUnzipLocationLabel(AppTextZh(), 'specified_folder'), 'specified_folder');
      expect(
        dsUnzipLocationLabel(AppTextEn(), 'current_folder'),
        'the download folder',
      );
      // ★ 反向：没见过的枚举**原样**返回 —— 编一个"听起来对"的名字才是撒谎
      expect(dsUnzipLocationLabel(AppTextZh(), 'future_mode'), 'future_mode');
      expect(dsUnzipLocationLabel(AppTextZh(), ''), '');
    });

    testWidgets('设置页渲染的是人话，整页找不到裸枚举 current_folder', (tester) async {
      await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': false,
            'unzip_location': 'current_folder',
          },
        },
      );
      // ★ r410：位置从"只读一行"改成**官方 radio ×2**（G-r408-01），
      //   判据仍是"用户看到的是人话、不是枚举"。
      expect(find.text('下载文件夹'), findsOneWidget);
      expect(
        find.textContaining('current_folder'),
        findsNothing,
        reason: '服务端枚举不许出现在用户可见文案里（真机 r407 逐字读到过）',
      );
    });

    testWidgets('select_folder 也走映射（官方第二档枚举）', (tester) async {
      await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': false,
            'unzip_location': 'select_folder',
            'unzip_to_path': '/volume1/dl',
          },
        },
      );
      expect(find.text('指定文件夹'), findsOneWidget);
      expect(find.textContaining('select_folder'), findsNothing);
    });

  // ------------------------------------------------- ★ r410 · G-r408-01
  //
  // 缺陷（r408 登记，**功能缺**）：设置页只暴露了 6 个可写自动解压字段里的 1 个
  // （`enable_unzip`），其余 5 个（`unzip_location` / `unzip_to_path` /
  // `create_subfolder` / `unzip_overwrite` / `delete_archive`）**在界面上根本没有**，
  // 而数据层早就能发（`setAutoExtraction` 6 参数）。本轮补齐并钉住三条纪律：
  //   ① 每个控件**只发自己那个脏字段**（官方 `getDirtyFieldValues`）；
  //   ② 官方依赖关系：`enable_unzip` 关 ⇒ 其余全 disabled（`enableUnzipFields`）；
  //   ③ 官方 `unzip_to_path` 是 `allowBlank:false` ⇒ 路径空着切过去**不许**发一次必被拒的写。
  group('★ r410 · 自动解压 6 个可写字段（G-r408-01）', () {
    testWidgets('总开关开着：4 勾选 + 2 radio 都在；关着：其余全 disabled', (tester) async {
      await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': true,
            'unzip_location': 'current_folder',
          },
        },
      );
      for (final k in const [
        'ds-unzip-subfolder',
        'ds-unzip-overwrite',
        'ds-unzip-delete-archive',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: '$k 必须出现');
      }
      expect(find.byKey(const Key('ds-unzip-loc-current')), findsOneWidget);
      expect(find.byKey(const Key('ds-unzip-loc-select')), findsOneWidget);
      // 总开关开着 ⇒ 三个勾选可点。
      expect(
        tester
            .widget<DesignSwitchRow>(find.byKey(const Key('ds-unzip-subfolder')))
            .onChanged,
        isNotNull,
      );

      // 关掉总开关后（服务端回读 false）⇒ 其余控件必须 disabled。
      await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': false,
            'unzip_location': 'current_folder',
          },
        },
      );
      for (final k in const [
        'ds-unzip-subfolder',
        'ds-unzip-overwrite',
        'ds-unzip-delete-archive',
      ]) {
        expect(
          tester.widget<DesignSwitchRow>(find.byKey(Key(k))).onChanged,
          isNull,
          reason: '官方 enableUnzipFields：总开关关 ⇒ $k 必须 disabled',
        );
      }
      // ignore: deprecated_member_use
      expect(
        tester
            .widget<RadioListTile<String>>(
              find.byKey(const Key('ds-unzip-loc-select')),
            )
            // ignore: deprecated_member_use
            .onChanged,
        isNull,
      );
    });

    testWidgets('切「指定文件夹」但路径空 ⇒ 一次 set 都不发，只提示（反向）', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': true,
            'unzip_location': 'current_folder',
          },
        },
      );
      await tester.tap(find.byKey(const Key('ds-unzip-loc-select')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _allOf(boot.t, 'set'),
        isEmpty,
        reason: '官方 allowBlank:false ⇒ 路径空着发过去必被拒，不许发',
      );
      expect(find.text('请先填写目标文件夹路径'), findsOneWidget);
    });

    testWidgets('填路径点保存 ⇒ **只**发 unzip_to_path（dirty-only）', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': true,
            'unzip_location': 'select_folder',
            'unzip_to_path': '/volume1/old',
          },
        },
      );
      await tester.enterText(
        find.byKey(const Key('ds-unzip-path')),
        '/volume1/downloads',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('ds-unzip-path-save')));
      await tester.pump(const Duration(milliseconds: 200));
      final call = _callOf(boot.t, 'set');
      expect(call['unzip_to_path'], '/volume1/downloads');
      for (final other in const [
        'enable_unzip',
        'unzip_location',
        'create_subfolder',
        'unzip_overwrite',
        'delete_archive',
      ]) {
        expect(call.containsKey(other), isFalse, reason: '$other 不是脏字段');
      }
    });

    testWidgets('三个勾选 + 位置切换：各自只发自己那一个字段', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': true,
            'unzip_location': 'current_folder',
            'create_subfolder': false,
            'unzip_overwrite': false,
            'delete_archive': false,
          },
        },
      );
      for (final (key, field) in const [
        ('ds-unzip-subfolder', 'create_subfolder'),
        ('ds-unzip-overwrite', 'unzip_overwrite'),
        ('ds-unzip-delete-archive', 'delete_archive'),
      ]) {
        await tester.tap(find.byKey(Key(key)));
        await tester.pump(const Duration(milliseconds: 200));
        final call = _callOf(boot.t, 'set');
        expect(call[field], isTrue, reason: '$key 发 $field=true');
        expect(
          call.keys.where((k) => k.startsWith('unzip_') || k.startsWith('create_') || k.startsWith('delete_')),
          [field],
          reason: '$key **只许**发 $field',
        );
      }
      // 位置切换：空路径那档已单独验过（不发）。这里先点"指定文件夹"
      // （本地切过去、**不**发写）→ 填路径 → 保存 ⇒ 官方一次表单提交那样
      // **两个字段一起发**，且不带别的脏字段。
      await tester.tap(find.byKey(const Key('ds-unzip-loc-select')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(
        find.byKey(const Key('ds-unzip-path')),
        '/volume1/dl',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('ds-unzip-path-save')));
      await tester.pump(const Duration(milliseconds: 200));
      final call = _callOf(boot.t, 'set');
      // ★ DA65：发的是**布尔** false（= 用指定文件夹），不是字符串枚举。
      expect(call['unzip_location'], isFalse);
      expect(call['unzip_to_path'], '/volume1/dl');
      expect(call.containsKey('create_subfolder'), isFalse);
      expect(call.containsKey('delete_archive'), isFalse);
      expect(call.containsKey('enable_unzip'), isFalse);
    });
  });

    testWidgets('服务端给未知位置值 ⇒ 原样多出一档，绝不静默改写', (tester) async {
      await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': true,
            'unzip_location': 'future_mode',
          },
        },
      );
      expect(find.byKey(const Key('ds-unzip-loc-unknown')), findsOneWidget);
      expect(find.text('future_mode'), findsOneWidget);
    });
  });
}
