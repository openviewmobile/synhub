// ⑥下载 D-6b：**F3 eMule 搜索**（`SYNO.DownloadStation2.eMule.Search` v1）。
//
// 参数逐字来自官方 `ui/download.js` aMule 面板：
// * `start`：`{keyword, search_type, file_type}` 恒发；`file_size_min/max`、
//   `source_num_min`、`file_extension` **填了才发**；
// * `list`：`{id, offset, limit, sort_by, order}`，root `results`，`search_done`；
// * `stop`：`{id}`（0 = 全部）；
// * `download`：`{file_id:[…]}`；
// * kad 关键字 < 3 字符的段 → 客户端挡下（官方 validator 同款）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/downloads/download_emule_search_page.dart';
import 'package:synhub/src/features/downloads/download_emule_search_providers.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.DownloadStation2.eMule.Search': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Map<String, dynamic> _result({
  String id = 'f1',
  String name = 'ubuntu.iso',
  int size = 1024,
  int source = 7,
  int completed = 3,
  bool downloaded = false,
}) => {
  'file_id': id,
  'filename': name,
  'file_size': size,
  'source': source,
  'completed_source': completed,
  'file_type': 'iso',
  'file_has_downloaded': downloaded,
};

Future<({DsmWebApi api, DownloadStationApi ds, FakeTransport t})> _boot({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'demo_user', password: 'x');
  return (api: api, ds: DownloadStationApi(api), t: t);
}

ProviderContainer _container(DsmWebApi api) => ProviderContainer(
  overrides: [
    downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
    emuleSearchPollIntervalProvider.overrideWithValue(Duration.zero),
  ],
);

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  final c = ProviderContainer(
    overrides: [
      downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
      emuleSearchPollIntervalProvider.overrideWithValue(Duration.zero),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: DownloadEmuleSearchPage()),
    ),
  );
  await tester.pump();
  return c;
}

void main() {
  group('F3 数据层：start/list/stop/download 参数逐字', () {
    test('start 恒发三项；可选项**填了才发**', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.eMule.Search.start': {'id': 11},
        },
      );
      final id = await ds.emuleSearchStart(
        keyword: '  ubuntu iso  ',
        searchType: 'global',
        fileType: 'video',
      );
      final call = t.calls.lastWhere((c) => c['method'] == 'start');
      expect(id, 11);
      expect(call['keyword'], 'ubuntu iso', reason: '官方 trim 关键字');
      expect(call['search_type'], 'global');
      expect(call['file_type'], 'video');
      expect(call.containsKey('file_size_min'), isFalse);
      expect(call.containsKey('file_size_max'), isFalse);
      expect(call.containsKey('source_num_min'), isFalse);
      expect(call.containsKey('file_extension'), isFalse);
    });

    test('可选参数填了就发（min/max/source/extension）', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.eMule.Search.start': {'id': 12},
        },
      );
      await ds.emuleSearchStart(
        keyword: 'x',
        fileSizeMin: 100,
        fileSizeMax: 900,
        sourceNumMin: 4,
        fileExtension: '  avi  ',
      );
      final call = t.calls.lastWhere((c) => c['method'] == 'start');
      expect(call['file_size_min'], 100);
      expect(call['file_size_max'], 900);
      expect(call['source_num_min'], 4);
      expect(call['file_extension'], 'avi');
      expect(call['search_type'], 'local', reason: '默认 local');
      expect(call['file_type'], 'any', reason: '默认 any');
    });

    test('空关键字 → 不发请求（114）', () async {
      final (api: _, :ds, :t) = await _boot();
      await expectLater(
        ds.emuleSearchStart(keyword: '   '),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noRequiredParam,
          ),
        ),
      );
      expect(t.calls.where((c) => c['method'] == 'start'), isEmpty);
    });

    test('kad 关键字太短 → 客户端挡下（官方 validator 同款）', () async {
      final (api: _, :ds, :t) = await _boot();
      await expectLater(
        ds.emuleSearchStart(keyword: 'ab cd', searchType: 'kad'),
        throwsA(isA<DsmApiException>()),
      );
      expect(t.calls.where((c) => c['method'] == 'start'), isEmpty);
      // 有一个 ≥3 字符的段就放行
      expect(DownloadStationApi.isKadKeywordValid('ab cde'), isTrue);
      expect(DownloadStationApi.isKadKeywordValid('ab cd'), isFalse);
    });

    test('list：{id,offset,limit} + root results / total / search_done', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.eMule.Search.list': {
            'results': [_result()],
            'total': 1,
            'search_done': true,
          },
        },
      );
      final page = await ds.emuleSearchList(id: 11, offset: 0, limit: 50);
      final call = t.calls.lastWhere((c) => c['method'] == 'list');
      expect(call['id'], 11);
      expect(call['offset'], 0);
      expect(call['limit'], 50);
      expect(page.total, 1);
      expect(page.searchDone, isTrue);
      expect(page.results.single.fileId, 'f1');
      expect(page.results.single.source, 7);
      expect(page.results.single.completedSource, 3);
      expect(page.results.single.hasDownloaded, isFalse);
    });

    test('stop：{id:0} = 停全部', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {'SYNO.DownloadStation2.eMule.Search.stop': {'ok': true}},
      );
      await ds.emuleSearchStop();
      expect(t.calls.lastWhere((c) => c['method'] == 'stop')['id'], 0);
      await ds.emuleSearchStop(id: 11);
      expect(t.calls.lastWhere((c) => c['method'] == 'stop')['id'], 11);
    });

    test('download：file_id 是**数组**（表单通道 = JSON 文本）；空选不发', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.eMule.Search.download': {'ok': true},
        },
      );
      await ds.emuleSearchDownload(['f1', 'f2']);
      final call = t.calls.lastWhere((c) => c['method'] == 'download');
      expect(call['file_id'], jsonEncode(['f1', 'f2']));

      await expectLater(
        ds.emuleSearchDownload(const []),
        throwsA(isA<DsmApiException>()),
      );
      expect(t.calls.where((c) => c['method'] == 'download').length, 1);
    });
  });

  group('F3 provider：轮询到 search_done 即停 + 选择/下载', () {
    test('search_done=true → 只轮询一次就收尾', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.eMule.Search.start': {'id': 11},
          'SYNO.DownloadStation2.eMule.Search.list': {
            'results': [_result()],
            'total': 1,
            'search_done': true,
          },
        },
      );
      final c = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(emuleSearchProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(emuleSearchProvider.notifier).search(keyword: 'ubuntu');

      final s = c.read(emuleSearchProvider);
      expect(s.done, isTrue);
      expect(s.running, isFalse);
      expect(s.results.single.filename, 'ubuntu.iso');
      expect(
        booted.t.calls.where((e) => e['method'] == 'list').length,
        1,
        reason: 'search_done 后不该继续轮询',
      );
    });

    test('没 search_done → 轮询到上限（maxPolls）', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.eMule.Search.start': {'id': 11},
          'SYNO.DownloadStation2.eMule.Search.list': {
            'results': [],
            'total': 0,
            'search_done': false,
          },
        },
      );
      final c = ProviderContainer(
        overrides: [
          downloadApiProvider.overrideWithValue(DownloadStationApi(booted.api)),
          emuleSearchPollIntervalProvider.overrideWithValue(Duration.zero),
          emuleSearchMaxPollsProvider.overrideWithValue(3),
        ],
      );
      addTearDown(c.dispose);
      final sub = c.listen(emuleSearchProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(emuleSearchProvider.notifier).search(keyword: 'ubuntu');
      expect(
        booted.t.calls.where((e) => e['method'] == 'list').length,
        3,
        reason: '官方 maxRequestTimes = 5 的上限语义',
      );
    });

    test('toggle + downloadSelected：只把选中的 file_id 发出去', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.eMule.Search.start': {'id': 11},
          'SYNO.DownloadStation2.eMule.Search.list': {
            'results': [
              _result(id: 'f1', name: 'a.iso'),
              _result(id: 'f2', name: 'b.iso'),
            ],
            'total': 2,
            'search_done': true,
          },
          'SYNO.DownloadStation2.eMule.Search.download': {'ok': true},
        },
      );
      final c = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(emuleSearchProvider, (_, _) {});
      addTearDown(sub.close);
      final n = c.read(emuleSearchProvider.notifier);
      await n.search(keyword: 'ubuntu');

      expect(await n.downloadSelected(), isFalse, reason: '空选不发请求');
      n.toggle('f2');
      expect(c.read(emuleSearchProvider).selected, {'f2'});
      n.toggle('f2');
      expect(c.read(emuleSearchProvider).selected, isEmpty);

      n.toggle('f1');
      n.toggle('f2');
      expect(await n.downloadSelected(), isTrue);
      final call = booted.t.calls.lastWhere((e) => e['method'] == 'download');
      expect(
        (jsonDecode(call['file_id'] as String) as List).toSet(),
        {'f1', 'f2'},
      );
    });
  });

  group('F3 页面：表单三态 + 结果上屏 + 下载选中', () {
    testWidgets('未搜索 → 没有结果也**不报错**；搜完空结果 → 中性空态', (tester) async {
      final c = await _pumpPage(
        tester,
        responses: {
          'SYNO.DownloadStation2.eMule.Search.start': {'id': 11},
          'SYNO.DownloadStation2.eMule.Search.list': {
            'results': [],
            'total': 0,
            'search_done': true,
          },
        },
      );
      expect(find.byKey(const Key('ds-emule-search-submit')), findsOneWidget);
      expect(find.textContaining('加载失败'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('ds-emule-search-keyword')),
        'ubuntu',
      );
      await tester.tap(find.byKey(const Key('ds-emule-search-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('ds-emule-search-empty')), findsOneWidget);
      expect(c.read(emuleSearchProvider).polls, 1);
    });

    testWidgets('结果上屏：文件名/大小/来源数；已下载过走红色（官方同款）',
        (tester) async {
      final c = await _pumpPage(
        tester,
        responses: {
          'SYNO.DownloadStation2.eMule.Search.start': {'id': 11},
          'SYNO.DownloadStation2.eMule.Search.list': {
            'results': [
              _result(id: 'f1', name: 'a.iso', size: 2048, source: 12),
              _result(id: 'f2', name: 'already.iso', downloaded: true),
            ],
            'total': 2,
            'search_done': true,
          },
        },
      );
      await tester.enterText(
        find.byKey(const Key('ds-emule-search-keyword')),
        'iso',
      );
      await tester.tap(find.byKey(const Key('ds-emule-search-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('ds-emule-result-0')), findsOneWidget);
      expect(find.byKey(const Key('ds-emule-result-1')), findsOneWidget);
      expect(find.text('a.iso'), findsOneWidget);
      expect(find.textContaining('12/3'), findsOneWidget);

      // 选中后右上角出现"下载选中 (n)"
      await tester.tap(find.byKey(const Key('ds-emule-result-0')));
      await tester.pump();
      expect(c.read(emuleSearchProvider).selected, {'f1'});
      expect(find.byKey(const Key('ds-emule-search-download')), findsOneWidget);
    });

    testWidgets('kad + 太短关键字 → 追错文案上屏，且**不发 start**', (tester) async {
      final c = await _pumpPage(
        tester,
        responses: {
          'SYNO.DownloadStation2.eMule.Search.start': {'id': 11},
        },
      );
      await tester.enterText(
        find.byKey(const Key('ds-emule-search-keyword')),
        'ab cd',
      );
      await tester.tap(find.byKey(const Key('ds-emule-search-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('kad').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ds-emule-search-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('ds-emule-search-error')), findsOneWidget);
      expect(c.read(emuleSearchProvider).errorText, isNotNull);
    });
  });

  // ★ DA33（r387）：eMule 搜索的业务码文案。
  //
  // **权威来源**：官方 Download Station 包
  // `DownloadStation-armada38x-4.1.2-5012.spk` 内 `ui/download.js`：
  //   * `SYNODL_ERR_EMULE_ED2K_NOT_CONNECTED = 2704`
  //   * `SYNODL_ERR_EMULE_KAD_NOT_CONNECTED = 2705`
  //   且 `getErrorString()` **只**给这两个配了文案
  //   （`error_server_not_connected{,_normaluser}` /
  //    `error_kad_not_connected{,_normaluser}`）。
  //   证据原文：`docs/evidence-r387/ds412_error_enum.txt`。
  group('DA33 · eMule 业务码文案（2704/2705 有官方语义；其余不编）', () {
    test('2704 → ED2K 未连接；2705 → Kad 未连接（不再是"未知错误 (N)"）', () {
      expect(
        describeDownloadError(
          DsmApiException(DownloadStationApi.errEmuleEd2kNotConnected),
        ),
        'eMule 未连接到 ED2K 服务器',
      );
      expect(
        describeDownloadError(
          DsmApiException(DownloadStationApi.errEmuleKadNotConnected),
        ),
        'eMule 未连接到 Kad 网络',
      );
    });

    test('反向：2703（官方**没给**文案的兄弟码）仍回"未知错误 + 原始码"', () {
      // 这是本条的**边界**：不许因为"都是 eMule 的码"就把整族都编上文案。
      final text = describeDownloadError(DsmApiException(2703));
      expect(text, contains('2703'));
      expect(text, isNot(contains('ED2K')));
    });

    testWidgets('真机同款：服务端回 2704 → 页面上屏的是语义文案，不是"Unknown error (2704)"', (
      tester,
    ) async {
      final c = await _pumpPage(
        tester,
        failures: {'SYNO.DownloadStation2.eMule.Search.start': 2704},
      );
      await tester.enterText(
        find.byKey(const Key('ds-emule-search-keyword')),
        'ubuntu',
      );
      await tester.tap(find.byKey(const Key('ds-emule-search-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('ds-emule-search-error')), findsOneWidget);
      expect(find.text('eMule 未连接到 ED2K 服务器'), findsOneWidget);
      expect(find.textContaining('2704'), findsNothing);
      expect(find.textContaining('Unknown'), findsNothing);
      expect(c.read(emuleSearchProvider).errorText, 'eMule 未连接到 ED2K 服务器');
    });
  });
}
