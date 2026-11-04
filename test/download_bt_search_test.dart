// Download Station **BT 搜索**（wave4）的离线验证。
//
// ⚠️ **wave4 重大更正**（`docs/download-api-live.md` §12）：BT 搜索在本机
// **完全可用** —— 老一代 `SYNO.DownloadStation.BTSearch` v1，
// **path = `DownloadStation/btsearch.cgi`**，方法表（包内 `DownloadStation.api`
// 逐字）`["start","list","getCategory","clean","getModule"]`；
// 真机（普通用户，2026-09-22）：
//   * `getModule`（无参）→ 真实 enabled 模块；
//   * `start {keyword}` → `{"data":{"taskid":"…"}}`（无参 → 400）；
//   * `list {taskid,offset,limit}` → `{"finished":…,"items":[…],"total":130}`；
//   * `getCategory`（403）/ `clean`（401）**未取证 → 不做**。
//
// 覆盖：
//   * 数据层：老代 start/list 的请求形状 + **path 来自能力表**（不是写死
//     entry.cgi）；`size` 是**字符串字节数**；DS2 既有方法仍保留（降级）；
//   * 状态机：**老代优先**、`finished` 轮询（5s / 有上限 / 离开即停）、
//     模块多选（客户端按 `module_id` 过滤）、中性降级；
//   * 页面：结果字段展示（含 `size` 格式化）、**下载入口（DA35，r388 起有）**、
//     **绝不显示任何内部 id**（`taskid`/`id`/`module_id`）。
//
// ⚠️ 这是**离线**用例：别把离线绿当成真机已验证。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/dto/download_task_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/downloads/download_bt_search_page.dart';
import 'package:synhub/src/features/downloads/download_bt_search_providers.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 两个 BTSearch 的 path **不同**（老代 `btsearch.cgi` / 新代 `entry.cgi`）。
const _legacyTable = {
  'SYNO.DownloadStation.BTSearch': {
    'path': 'DownloadStation/btsearch.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

const _ds2Table = {
  'SYNO.DownloadStation2.BTSearch': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// 建任务用（DA35）：`Task.create` 走同一个 entry.cgi。
const _taskTable = {
  'SYNO.DownloadStation2.Task': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// `Task.create` 成功回包（URL 建任务时服务端回的 `list_id` 是**空数组**，
/// 见 r387/DA37；这里逐字照抄真机形状）。
Map<String, dynamic> get _createOk => {'list_id': <dynamic>[]};

const _magnet = 'magnet:?xt=urn:btih:C168FBD6';

const _taskIdSecret = '179004081364F3458F';
const _resultIdSecret = 'RESULTID-SECRET-42';
const _moduleIdSecret = 'the_pirate_bay';

/// 记录 **path**（FakeTransport 的 `calls` 只有参数），并支持给老代 `list`
/// 注入**一串**分页响应（验 `finished` 轮询的推进）。
class _BtTransport extends FakeTransport {
  _BtTransport(super.responses, super.apiTable);

  final List<String> paths = [];

  /// 老代 `list` 的按序响应（按 `list` 调用顺序消费）。
  List<Map<String, dynamic>> legacyPages = [];

  int legacyListCalls = 0;

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    paths.add(path);
    final key = '${params['api']}.${params['method']}';
    if (params['api'] == 'SYNO.DownloadStation.BTSearch' &&
        params['method'] == 'list' &&
        legacyPages.isNotEmpty) {
      calls.add(params);
      legacyListCalls++;
      final failCode = failures[key];
      if (failCode != null) {
        return jsonEncode({
          'success': false,
          'error': {'code': failCode},
        });
      }
      final idx = legacyListCalls - 1;
      final data = idx < legacyPages.length
          ? legacyPages[idx]
          : legacyPages.last;
      return jsonEncode({'success': true, 'data': data});
    }
    return super.postForm(path, params);
  }

  int countMethod(String method) =>
      calls.where((c) => c['method'] == method).length;

  int countPath(String path) => paths.where((p) => p == path).length;

  Map<String, dynamic> lastCall(String method) =>
      calls.lastWhere((c) => c['method'] == method);
}

/// 老代 `list` 的一行（**逐字 11 字段**，`size` 是字符串字节数）。
Map<String, dynamic> _legacyItem({
  String id = _resultIdSecret,
  String title = 'ubuntu-24.04.iso',
  String size = '204385784',
  String date = '2012-04-20',
  int seeds = 12,
  int leechs = 3,
  int peers = 4,
  String moduleId = _moduleIdSecret,
  String moduleTitle = 'The Pirate Bay',
  String downloadUri = _magnet,
}) => {
  'date': date,
  'download_uri': downloadUri,
  'external_link': 'https://example.invalid/description.php?id=1',
  'id': id,
  'leechs': leechs,
  'module_id': moduleId,
  'module_title': moduleTitle,
  'peers': peers,
  'seeds': seeds,
  'size': size,
  'title': title,
};

Map<String, dynamic> _legacyPage({
  List<Map<String, dynamic>> items = const [],
  int total = 0,
  bool finished = false,
}) => {'finished': finished, 'items': items, 'offset': 0, 'total': total};

/// 老代 `start` 的真机回包（`{"data":{"taskid":…}}`）。
Map<String, dynamic> get _startOk => {'taskid': _taskIdSecret};

Future<({DsmWebApi api, DownloadStationApi ds, _BtTransport t})> _boot({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  bool legacy = true,
  bool ds2 = true,
  bool task = false,
}) async {
  final t = _BtTransport(responses, {
    ...FakeTransport.table,
    if (legacy) ..._legacyTable,
    if (ds2) ..._ds2Table,
    if (task) ..._taskTable,
  });
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'demo_user', password: 'x');
  return (api: api, ds: DownloadStationApi(api), t: t);
}

({ProviderContainer c, _BtTransport t}) _container(
  DsmWebApi api, {
  int maxPolls = 120,
  Duration interval = Duration.zero,
  void Function(_BtTransport t)? setup,
}) {
  final t = api.transport as _BtTransport;
  setup?.call(t);
  final c = ProviderContainer(
    overrides: [
      downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
      btSearchPollIntervalProvider.overrideWithValue(interval),
      btSearchMaxPollsProvider.overrideWithValue(maxPolls),
    ],
  );
  return (c: c, t: t);
}

void main() {
  group('数据层：老代 API（path 来自能力表 / 参数逐字）', () {
    test('getModule 走 btsearch.cgi（不是 entry.cgi）且方法名是 getModule', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {
                'enabled': true,
                'id': _moduleIdSecret,
                'title': 'The Pirate Bay',
              },
              {'enabled': true, 'id': '1337x', 'title': '1337x'},
              {'enabled': false, 'id': 'off', 'title': 'Off'},
            ],
          },
        },
      );

      final mods = await ds.btSearchModules();

      final call = t.lastCall('getModule');
      expect(call['api'], 'SYNO.DownloadStation.BTSearch');
      expect(call['version'], '1');
      expect(t.paths.last, 'DownloadStation/btsearch.cgi');
      expect(mods.map((m) => m.id), [_moduleIdSecret, '1337x', 'off']);
      expect(mods.first.title, 'The Pirate Bay');
      expect(mods.last.enabled, isFalse);
    });

    test('start 形状 {keyword} v1，path=btsearch.cgi，回包取 taskid', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {'SYNO.DownloadStation.BTSearch.start': _startOk},
      );

      final id = await ds.btSearchLegacyStart(keyword: '  ubuntu ');

      final call = t.lastCall('start');
      expect(call['api'], 'SYNO.DownloadStation.BTSearch');
      expect(call['version'], '1');
      expect(call['keyword'], 'ubuntu'); // trim
      // 真机契约只钉了 keyword：不许猜 module 等未取证参数。
      expect(call.containsKey('module'), isFalse);
      expect(t.paths.last, 'DownloadStation/btsearch.cgi');
      expect(t.paths.last, isNot('entry.cgi'));
      expect(id, _taskIdSecret);
    });

    test('start 空 keyword 不发请求（本地抛 120）', () async {
      final (api: _, :ds, :t) = await _boot();
      await expectLater(
        ds.btSearchLegacyStart(keyword: '   '),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noRequiredParam,
          ),
        ),
      );
      expect(t.countMethod('start'), 0);
    });

    test('list 参数 {taskid,offset,limit}，path=btsearch.cgi，解析 11 字段', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation.BTSearch.list': _legacyPage(
            items: [_legacyItem()],
            total: 130,
            finished: false,
          ),
        },
      );

      final page = await ds.btSearchLegacyList(
        taskid: _taskIdSecret,
        offset: 25,
        limit: 25,
      );

      final call = t.lastCall('list');
      expect(call['api'], 'SYNO.DownloadStation.BTSearch');
      expect(call['version'], '1');
      expect(call['taskid'], _taskIdSecret);
      expect(call['offset'], 25);
      expect(call['limit'], 25);
      expect(t.paths.last, 'DownloadStation/btsearch.cgi');

      expect(page.total, 130);
      expect(page.finished, isFalse);
      final r = page.items.single;
      // `size` 是**字符串字节数** → 必须解析成字节。
      expect(r.size, 204385784);
      expect(r.date, '2012-04-20');
      expect(r.seeds, 12);
      expect(r.peers, 4);
      expect(r.leechs, 3);
      expect(r.moduleTitle, 'The Pirate Bay');
      expect(r.moduleId, _moduleIdSecret);
      expect(r.downloadUri, 'magnet:?xt=urn:btih:C168FBD6');
    });
  });

  group('数据层：DS2 既有方法保留（降级/兼容）', () {
    test('DS2 start/list 仍可用（entry.cgi）', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.BTSearch.start': {'id': _taskIdSecret},
          'SYNO.DownloadStation2.BTSearch.list': {
            'is_running': false,
            'results': [
              {
                'result_id': 'r1',
                'title': 'ds2-item',
                'size': 1024,
                'seeds': 1,
                'peers': 2,
                'provider': 'DS2 Provider',
              },
            ],
            'total': 1,
          },
        },
      );

      expect(await ds.btSearchStart(keyword: 'ubuntu'), _taskIdSecret);
      expect(t.paths.last, 'entry.cgi');
      final page = await ds.btSearchList(searchTaskId: _taskIdSecret);
      expect(page.results.single.title, 'ds2-item');
      expect(t.paths.last, 'entry.cgi');
    });
  });

  group('DTO：老代结果字段（宽容解析）', () {
    test('size 字符串 → int；缺字段不崩', () {
      final r = DsBtSearchLegacyResult.fromJson({'size': '204385784'});
      expect(r.size, 204385784);
      expect(r.seeds, -1);
      expect(r.hasSeedInfo, isFalse);
      expect(r.title, '');
      expect(r.date, '');
    });

    test('11 字段逐字解析（含 module_id / module_title / download_uri）', () {
      final r = DsBtSearchLegacyResult.fromJson(_legacyItem(id: 'x'));
      expect(r.id, 'x');
      expect(r.moduleId, _moduleIdSecret);
      expect(r.moduleTitle, 'The Pirate Bay');
      expect(r.externalLink, contains('example.invalid'));
      expect(r.raw['leechs'], 3);
      // ★ r388/DA35：`download_uri` **逐字**进展示模型（大小写与 `&` 都不许动）。
      expect(r.downloadUri, _magnet);
      final entry = BtSearchEntry.fromLegacy(r);
      expect(entry.downloadUri, _magnet);
      expect(entry.hasDownloadLink, isTrue);
      // 服务端没给 ⇒ 展示模型必须承认"没有"，而不是"空串也算有"。
      final none = BtSearchEntry.fromLegacy(
        DsBtSearchLegacyResult.fromJson(_legacyItem(id: 'y', downloadUri: '')),
      );
      expect(none.hasDownloadLink, isFalse);
      expect(
        BtSearchEntry.fromLegacy(
          DsBtSearchLegacyResult.fromJson(_legacyItem(id: 'z', downloadUri: '   ')),
        ).hasDownloadLink,
        isFalse,
        reason: '全是空白也不许当链接',
      );
    });

    test('DS2 `dlurl` 也进 `downloadUri`（两条来源同一出口）', () {
      final r = DsBtSearchResult.fromJson({
        'result_id': 'R1',
        'title': 'ubuntu',
        'size': 100,
        'dlurl': _magnet,
      });
      expect(r.dlurl, _magnet);
      final entry = BtSearchEntry.fromDs2(r);
      expect(entry.downloadUri, _magnet);
      expect(entry.hasDownloadLink, isTrue);
    });
  });

  group('状态机：老代优先 / finished 轮询 / 降级', () {
    test('两个能力位都在 → 走老代（start/list 都在 btsearch.cgi）', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation.BTSearch.start': _startOk,
          'SYNO.DownloadStation2.BTSearch.start': {'id': 'DS2-SHOULD-NOT-USE'},
        },
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);
      t.legacyPages = [
        _legacyPage(items: [_legacyItem()], total: 1, finished: true),
      ];

      await c.read(btSearchProvider.notifier).search(keyword: 'ubuntu');

      final s = c.read(btSearchProvider);
      expect(s.legacy, isTrue);
      expect(s.phase, BtSearchPhase.done);
      expect(s.finished, isTrue);
      expect(s.entries.single.title, 'ubuntu-24.04.iso');
      expect(s.entries.single.sizeBytes, 204385784);
      expect(t.countMethod('start'), 1);
      expect(t.lastCall('start')['api'], 'SYNO.DownloadStation.BTSearch');
      expect(t.countMethod('list'), 1);
      expect(t.countPath('DownloadStation/btsearch.cgi'), 2);
      expect(t.countPath('entry.cgi'), 0);
      // 老代没有 stop 概念；DS2 的 stop 不该被调。
      expect(t.countMethod('stop'), 0);
    });

    test('finished=false → finished=true：轮询推进并合并去重', () async {
      final booted = await _boot(
        responses: {'SYNO.DownloadStation.BTSearch.start': _startOk},
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);
      final first = _legacyItem(id: 'a', title: 'first', moduleId: 'm1');
      final second = _legacyItem(id: 'b', title: 'second', moduleId: 'm1');
      t.legacyPages = [
        _legacyPage(items: [first], total: 2, finished: false),
        // 第二次把 first 再回一遍（去重）并补上 second。
        _legacyPage(items: [first, second], total: 2, finished: true),
      ];

      await c.read(btSearchProvider.notifier).search(keyword: 'ubuntu');

      final s = c.read(btSearchProvider);
      expect(s.polls, 2);
      expect(s.finished, isTrue);
      expect(s.entries.map((e) => e.title), ['first', 'second']);
      expect(t.legacyListCalls, 2);
    });

    test('finished 一直 false → 到 maxPolls 必停，绝不无限轮询', () async {
      final booted = await _boot(
        responses: {'SYNO.DownloadStation.BTSearch.start': _startOk},
      );
      final (:c, :t) = _container(booted.api, maxPolls: 3);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);
      t.legacyPages = [_legacyPage(items: [], total: 0, finished: false)];

      await c.read(btSearchProvider.notifier).search(keyword: 'ubuntu');

      final s = c.read(btSearchProvider);
      expect(t.legacyListCalls, 3, reason: '到顶即停');
      expect(s.polls, 3);
      expect(s.phase, BtSearchPhase.done);
    });

    test('start 回 105 → noPrivilege 降级，不轮询', () async {
      final booted = await _boot(
        failures: {'SYNO.DownloadStation.BTSearch.start': 105},
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(btSearchProvider.notifier).search(keyword: 'ubuntu');

      final s = c.read(btSearchProvider);
      expect(s.phase, BtSearchPhase.unavailable);
      expect(s.block, BtSearchBlock.noPrivilege);
      expect(s.errorText, isNull);
      expect(t.legacyListCalls, 0);
    });

    test('start 成功但没回 taskid → idNotFound 中性降级', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation.BTSearch.start': {'taskid': ''},
        },
      );
      final (:c, t: _) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(btSearchProvider.notifier).search(keyword: 'ubuntu');

      final s = c.read(btSearchProvider);
      expect(s.phase, BtSearchPhase.unavailable);
      expect(s.block, BtSearchBlock.idNotFound);
    });

    test('能力位都没有 → notInstalled（门控的兜底）', () async {
      final booted = await _boot(legacy: false, ds2: false);
      final (:c, t: _) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(btSearchProvider.notifier).search(keyword: 'ubuntu');

      expect(c.read(btSearchProvider).block, BtSearchBlock.notInstalled);
    });

    test('只有 DS2 能力位（老代缺失）→ 降级走 DS2', () async {
      final booted = await _boot(
        legacy: false,
        responses: {
          'SYNO.DownloadStation2.BTSearch.start': {'id': _taskIdSecret},
          'SYNO.DownloadStation2.BTSearch.list': {
            'is_running': false,
            'results': [
              {
                'result_id': 'r1',
                'title': 'ds2-item',
                'size': 1024,
                'seeds': 1,
                'peers': 2,
                'provider': 'DS2 Provider',
              },
            ],
            'total': 1,
          },
          'SYNO.DownloadStation2.BTSearch.list_category': {'categories': []},
          'SYNO.DownloadStation2.BTSearch.list_plugin_status': {
            'plugins': [
              {'id': 'a', 'can_connect': true},
            ],
          },
          'SYNO.DownloadStation2.BTSearch.stop': {'ok': true},
        },
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(btSearchProvider.notifier).search(keyword: 'ubuntu');

      final s = c.read(btSearchProvider);
      expect(s.legacy, isFalse);
      expect(s.phase, BtSearchPhase.done);
      expect(s.entries.single.title, 'ds2-item');
      expect(t.lastCall('start')['api'], 'SYNO.DownloadStation2.BTSearch');
      expect(t.countPath('DownloadStation/btsearch.cgi'), 0);
    });

    test('老代 list 回 1408 → idNotFound 中性降级（不是加载失败）', () async {
      final booted = await _boot(
        responses: {'SYNO.DownloadStation.BTSearch.start': _startOk},
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);
      t.legacyPages = [_legacyPage()];
      t.failures['SYNO.DownloadStation.BTSearch.list'] = 1408;

      await c.read(btSearchProvider.notifier).search(keyword: 'ubuntu');

      final s = c.read(btSearchProvider);
      expect(s.phase, BtSearchPhase.unavailable);
      expect(s.block, BtSearchBlock.idNotFound);
      expect(s.errorText, isNull);
    });

    test('loadSources 只保留 enabled 的数据源', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {'enabled': true, 'id': 'a', 'title': 'A'},
              {'enabled': false, 'id': 'b', 'title': 'B'},
            ],
          },
        },
      );
      final (:c, t: _) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(btSearchProvider.notifier).loadSources();

      final s = c.read(btSearchProvider);
      expect(s.sourcesLoaded, isTrue);
      expect(s.sources.map((m) => m.id), ['a']);
    });

    test('模块多选：客户端按 module_id 过滤 + 清空还原', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation.BTSearch.start': _startOk,
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {'enabled': true, 'id': 'a', 'title': 'A'},
              {'enabled': true, 'id': 'b', 'title': 'B'},
            ],
          },
        },
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);
      t.legacyPages = [
        _legacyPage(
          items: [
            _legacyItem(id: '1', title: 'from-a', moduleId: 'a'),
            _legacyItem(id: '2', title: 'from-b', moduleId: 'b'),
          ],
          total: 2,
          finished: true,
        ),
      ];

      final n = c.read(btSearchProvider.notifier);
      await n.loadSources();
      await n.search(keyword: 'ubuntu');
      expect(c.read(btSearchProvider).visibleEntries, hasLength(2));

      n.toggleModule('a');
      expect(c.read(btSearchProvider).visibleEntries.single.title, 'from-a');

      n.clearModules();
      expect(c.read(btSearchProvider).visibleEntries, hasLength(2));
    });

    // ★ r406 / DA58：服务端 `getModule` 真的会返回重复项（真机 13 条里
    // `EZTV` 同 id 两条、`the_pirate_bay`/`ThePirateBay` 同名两条）。
    // 同 id 必须在装载时去重，否则两个同名 chip 的勾选会互相抵消。
    test('DA58：同 id 的重复数据源只保留一条；同名不同 id 的两条都保留', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {'enabled': true, 'id': '1337xxx', 'title': '1337xxx'},
              {'enabled': true, 'id': 'the_pirate_bay', 'title': 'The Pirate Bay'},
              {'enabled': true, 'id': 'EZTV', 'title': 'EZTV'},
              {'enabled': true, 'id': 'ThePirateBay', 'title': 'The Pirate Bay'},
              {'enabled': true, 'id': 'EZTV', 'title': 'EZTV'},
              {'enabled': false, 'id': 'EZTV', 'title': 'EZTV'},
            ],
          },
        },
      );
      final (:c, t: _) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(btSearchProvider.notifier).loadSources();
      final s = c.read(btSearchProvider);

      // 同 id 只留一条（`EZTV` 出现 2 次 enabled + 1 次 disabled ⇒ 1 条）
      expect(s.sources.where((m) => m.id == 'EZTV'), hasLength(1));
      // 同名但 id 不同 ⇒ **不许**合并（服务端确实是两个源）
      expect(s.sources.where((m) => m.title == 'The Pirate Bay'), hasLength(2));
      expect(
        s.sources.map((m) => m.id),
        ['1337xxx', 'the_pirate_bay', 'EZTV', 'ThePirateBay'],
      );

      // 反向：只点一次 `EZTV` 就必须真的筛上（修前：第二次点会抵消）
      final n = c.read(btSearchProvider.notifier);
      n.toggleModule('EZTV');
      expect(c.read(btSearchProvider).selectedModules, {'EZTV'});
      n.toggleModule('EZTV');
      expect(c.read(btSearchProvider).selectedModules, isEmpty);
    });

    test('离开（autoDispose）打断老代轮询（不再 list，不泄漏）', () async {
      final booted = await _boot(
        responses: {'SYNO.DownloadStation.BTSearch.start': _startOk},
      );
      // 间隔很长：轮询会卡在 delay 上，模拟"页面还开着在等下一次"。
      final (:c, :t) = _container(
        booted.api,
        interval: const Duration(seconds: 30),
      );
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      t.legacyPages = [_legacyPage(items: [], total: 0, finished: false)];

      final future = c
          .read(btSearchProvider.notifier)
          .search(keyword: 'ubuntu');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(t.legacyListCalls, 1);

      sub.close(); // 页面离开 → autoDispose
      await future;
      await Future<void>.delayed(Duration.zero);

      final atExit = t.legacyListCalls;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(t.legacyListCalls, atExit, reason: '离开后不得再轮询');
    });
  });

  group('页面：结果展示 / 下载入口（DA35，r388 起）/ 不显示内部 id', () {
    Future<({_BtTransport t, ProviderContainer c})> pump(
      WidgetTester tester, {
      Map<String, Map<String, dynamic>> responses = const {},
      Map<String, int> failures = const {},
      List<Map<String, dynamic>> legacyPages = const [],
      bool taskApi = false,
      String defaultDest = '/home/Download',
    }) async {
      final booted = await _boot(
        responses: responses,
        failures: failures,
        legacy: true,
        ds2: true,
        task: taskApi,
      );
      final t = booted.t;
      t.legacyPages = List.of(legacyPages);
      final c = ProviderContainer(
        overrides: [
          downloadApiProvider.overrideWithValue(DownloadStationApi(booted.api)),
          btSearchPollIntervalProvider.overrideWithValue(Duration.zero),
          btSearchMaxPollsProvider.overrideWithValue(5),
          // ★ r388/DA35：建任务的目录来源与「新建任务」页**同一个 provider**；
          //   测试里固定住，不依赖 Mock 里有没有 `Settings.Location.get`。
          downloadDefaultDestProvider.overrideWith((ref) => defaultDest),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DownloadBtSearchPage()),
        ),
      );
      await tester.pump(); // postFrame → loadSources
      await tester.pump();
      return (t: t, c: c);
    }

    Future<void> runSearch(WidgetTester tester) async {
      await tester.enterText(find.byKey(const Key('ds-bt-keyword')), 'ubuntu');
      await tester.tap(find.byKey(const Key('ds-bt-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('DA58：同 id 的重复数据源在 chip 条上只出现一个', (tester) async {
      await pump(
        tester,
        responses: {
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {'enabled': true, 'id': '1337xxx', 'title': '1337xxx'},
              {'enabled': true, 'id': 'the_pirate_bay', 'title': 'The Pirate Bay'},
              {'enabled': true, 'id': 'EZTV', 'title': 'EZTV'},
              {'enabled': true, 'id': 'ThePirateBay', 'title': 'The Pirate Bay'},
              {'enabled': true, 'id': 'EZTV', 'title': 'EZTV'},
            ],
          },
        },
      );
      // 同 id 只渲染一个 chip（修前：两个 `ds-bt-source-EZTV`）
      expect(find.byKey(const Key('ds-bt-source-EZTV')), findsOneWidget);
      // 同名不同 id ⇒ 两个 chip 都在（不许合并）
      expect(find.byKey(const Key('ds-bt-source-the_pirate_bay')),
          findsOneWidget);
      expect(find.byKey(const Key('ds-bt-source-ThePirateBay')),
          findsOneWidget);
      // 内部 id 绝不上屏：同名两项上屏的都是标题
      expect(find.text('The Pirate Bay'), findsNWidgets(2));
      expect(find.text('EZTV'), findsOneWidget);
    });

    testWidgets('老代结果：标题/大小格式化/日期/seeds/peers/module_title', (tester) async {
      final r = await pump(
        tester,
        responses: {
          'SYNO.DownloadStation.BTSearch.start': _startOk,
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {
                'enabled': true,
                'id': _moduleIdSecret,
                'title': 'The Pirate Bay',
              },
            ],
          },
        },
        legacyPages: [
          _legacyPage(items: [_legacyItem()], total: 1, finished: true),
        ],
      );

      await runSearch(tester);

      expect(find.text('ubuntu-24.04.iso'), findsOneWidget);
      // 204385784 字节 → "195 MB"（**不是**裸数字）。
      expect(find.textContaining('195 MB'), findsOneWidget);
      expect(find.textContaining('204385784'), findsNothing);
      expect(find.text('2012-04-20'), findsOneWidget);
      expect(find.textContaining('种子：12'), findsOneWidget);
      expect(find.textContaining('连接：4'), findsOneWidget);
      expect(find.text('The Pirate Bay'), findsWidgets);

      // ★★ r388/DA35（**推翻本文件 r352 起的"无下载入口"断言**）：
      // 现在每条**有 `download_uri`** 的结果行都有「下载」按钮，且**可点**。
      // 键里的 `L` 前缀 = `BtSearchEntry.dedupeKey` 的老代形态（`L<id>`）。
      final downloadBtn = find.byKey(
        const Key('ds-bt-download-L$_resultIdSecret'),
      );
      expect(downloadBtn, findsOneWidget);
      expect(find.byIcon(Icons.download), findsWidgets);
      expect(find.text('下载'), findsWidgets);
      expect(
        tester.widget<TextButton>(downloadBtn).onPressed,
        isNotNull,
        reason: '有 download_uri 的结果行必须能真的建任务',
      );

      // **绝不显示内部 id**（taskid / id / module_id）。
      expect(find.textContaining(_taskIdSecret), findsNothing);
      expect(find.textContaining(_resultIdSecret), findsNothing);
      expect(find.textContaining(_moduleIdSecret), findsNothing);

      // path：老代搜索结果一律走 btsearch.cgi。
      expect(r.t.countPath('DownloadStation/btsearch.cgi'), greaterThan(0));
      expect(r.t.countPath('entry.cgi'), 0);
    });

    testWidgets('★ r388/DA35：点「下载」→ `Task.create` 带**逐字** magnet 建任务', (tester) async {
      final r = await pump(
        tester,
        taskApi: true,
        responses: {
          'SYNO.DownloadStation.BTSearch.start': _startOk,
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {
                'enabled': true,
                'id': _moduleIdSecret,
                'title': 'The Pirate Bay',
              },
            ],
          },
          'SYNO.DownloadStation2.Task.create': _createOk,
        },
        legacyPages: [
          _legacyPage(items: [_legacyItem()], total: 1, finished: true),
        ],
      );

      await runSearch(tester);
      await tester.tap(
        find.byKey(const Key('ds-bt-download-L$_resultIdSecret')),
      );
      await tester.pump(); // _adding = true
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      final call = r.t.lastCall('create');
      expect(call['api'], 'SYNO.DownloadStation2.Task');
      expect(call['method'], 'create');
      // `type=url`（官方 `addQuickURL` 的同一条路径）。
      expect(call['type'], 'url');
      // ★ url 是**逐字**的 `download_uri`（数组以 JSON 文本上线）。
      expect(jsonDecode(call['url'] as String), [_magnet]);
      // `create_list` 不勾（与官方 `download_now` 一致）。
      expect(call['create_list'], false);
      // ★★ 建完必须**重新拉列表**：`downloadListProvider` 的 `build()` 只给空
      //    初始值、不发请求 ⇒ 用 `invalidate` 会把列表清成"0 tasks"（真机
      //    r8_23 的原始读数），必须走 `refresh()`。
      //    ⚠️ 这条断言**必须钉到 `SYNO.DownloadStation2.Task`**：BT 搜索自己的
      //    `BTSearch.list` 也叫 `list`，只数 `method` 会让这条守卫"构造性变绿"。
      expect(
        r.t.calls
            .where(
              (c) =>
                  c['api'] == 'SYNO.DownloadStation2.Task' &&
                  c['method'] == 'list',
            )
            .length,
        greaterThan(0),
        reason: '建任务后必须重拉任务列表（Task.list），不许只作废（作废=列表变空）',
      );
      // ★★ 真机 120 的根因就在这一行：官方 `downloadSelected` 逐字带
      //    `destination`，且没目录连请求都不发 ⇒ 我们也**必须**带。
      expect(jsonDecode(call['destination'] as String), '/home/Download');
      // 上屏：提示条（不是"点了没反应"）。
      expect(find.text('已添加到下载任务'), findsOneWidget);
      // 内部 id 仍不许上屏。
      expect(find.textContaining(_resultIdSecret), findsNothing);
    });

    testWidgets('★ r388/DA35 反向：服务端**没给** `download_uri` 的那条置灰且不建任务', (tester) async {
      final r = await pump(
        tester,
        taskApi: true,
        responses: {
          'SYNO.DownloadStation.BTSearch.start': _startOk,
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {
                'enabled': true,
                'id': _moduleIdSecret,
                'title': 'The Pirate Bay',
              },
            ],
          },
          'SYNO.DownloadStation2.Task.create': _createOk,
        },
        legacyPages: [
          _legacyPage(
            items: [_legacyItem(downloadUri: '')],
            total: 1,
            finished: true,
          ),
        ],
      );

      await runSearch(tester);
      final btn = find.byKey(const Key('ds-bt-download-L$_resultIdSecret'));
      expect(btn, findsOneWidget, reason: '按钮要在（看得见"这里本该有"）');
      expect(
        tester.widget<TextButton>(btn).onPressed,
        isNull,
        reason: '**不许**拿 title 拼磁力链糊弄；没链接就是点不动',
      );
      await tester.tap(btn, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
      expect(r.t.calls.where((c) => c['method'] == 'create'), isEmpty);
      expect(find.text('已添加到下载任务'), findsNothing);
    });

    testWidgets('★ r388/DA35 兜底：取不到默认目录 ⇒ 不发请求，带链接交给「新建任务」', (tester) async {
      // 官方在这里弹"选目录"（`checkLocationDestinationNonEmpty`）且
      // `if(!Ext.isDefined(a)){return}` —— **没目录连请求都不发**。
      // 我们的等价形态：带 `download_uri` 跳到「新建任务」页让用户确认目录。
      final r = await pump(
        tester,
        taskApi: true,
        defaultDest: '',
        responses: {
          'SYNO.DownloadStation.BTSearch.start': _startOk,
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {
                'enabled': true,
                'id': _moduleIdSecret,
                'title': 'The Pirate Bay',
              },
            ],
          },
          'SYNO.DownloadStation2.Task.create': _createOk,
        },
        legacyPages: [
          _legacyPage(items: [_legacyItem()], total: 1, finished: true),
        ],
      );

      await runSearch(tester);
      await tester.tap(
        find.byKey(const Key('ds-bt-download-L$_resultIdSecret')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      // ① 不许发建任务请求（真机 120 就是"没目录硬发"来的）。
      expect(
        r.t.calls.where((c) => c['method'] == 'create'),
        isEmpty,
        reason: '没目录不许发请求（官方同款：if(!Ext.isDefined(a)){return}）',
      );
      // ② 跳到「新建任务」页，链接已预填（用户在那里确认目录）。
      expect(find.byKey(const Key('ds-create-urls')), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('ds-create-urls')),
      );
      expect(field.controller?.text, _magnet);
    });

    testWidgets('★ r388/DA38：英文界面里字段分隔符**不能**是全角「：」', (tester) async {
      // 真机读数（r8_09）：英文档下渲染成 `Size：195 MB` / `Seeds：0` ——
      // 分隔符 `：` 是**写死在 Dart 里**的，跟着中文一起漏进了英文界面。
      setCurrentText(AppTextEn());
      addTearDown(() => setCurrentText(AppTextZh()));
      await pump(
        tester,
        responses: {
          'SYNO.DownloadStation.BTSearch.start': _startOk,
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {
                'enabled': true,
                'id': _moduleIdSecret,
                'title': 'The Pirate Bay',
              },
            ],
          },
        },
        legacyPages: [
          _legacyPage(items: [_legacyItem()], total: 1, finished: true),
        ],
      );

      await runSearch(tester);

      // 英文档：标签是英文，分隔符跟着英文（`: `）。
      expect(find.textContaining('Size: 195 MB'), findsOneWidget);
      expect(find.textContaining('Seeds: 12'), findsOneWidget);
      expect(find.textContaining('Peers: 4'), findsOneWidget);
      // ★ 全角冒号**一个都不许**留在英文界面上。
      expect(
        find.textContaining('：'),
        findsNothing,
        reason: '英文档不许出现中文标点（DA38）',
      );
      expect(find.textContaining('Size：'), findsNothing);
    });

    testWidgets('模块多选只显示 enabled，选中即按 module_id 过滤', (tester) async {
      await pump(
        tester,
        responses: {
          'SYNO.DownloadStation.BTSearch.start': _startOk,
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {'enabled': true, 'id': 'a', 'title': 'Source A'},
              {'enabled': true, 'id': 'b', 'title': 'Source B'},
              {'enabled': false, 'id': 'c', 'title': 'Source C'},
            ],
          },
        },
        legacyPages: [
          _legacyPage(
            items: [
              _legacyItem(id: '1', title: 'from-a', moduleId: 'a'),
              _legacyItem(id: '2', title: 'from-b', moduleId: 'b'),
            ],
            total: 2,
            finished: true,
          ),
        ],
      );

      // 只显示 enabled 的（Source C 被过滤掉）。
      expect(find.byKey(const Key('ds-bt-source-a')), findsOneWidget);
      expect(find.byKey(const Key('ds-bt-source-b')), findsOneWidget);
      expect(find.byKey(const Key('ds-bt-source-c')), findsNothing);

      await runSearch(tester);
      expect(find.text('from-a'), findsOneWidget);
      expect(find.text('from-b'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ds-bt-source-a')));
      await tester.pump();
      expect(find.text('from-a'), findsOneWidget);
      expect(find.text('from-b'), findsNothing);
    });

    testWidgets('模块无 title 时也不把 module_id 当显示名', (tester) async {
      const secretId = 'SECRET-MODULE-ID';
      await pump(
        tester,
        responses: {
          'SYNO.DownloadStation.BTSearch.getModule': {
            'modules': [
              {'enabled': true, 'id': secretId, 'title': ''},
            ],
          },
        },
      );

      expect(find.text('未命名数据源'), findsOneWidget);
      expect(find.textContaining(secretId), findsNothing);
    });

    testWidgets('没有结果 → 明确空态（不是加载失败）', (tester) async {
      await pump(
        tester,
        responses: {'SYNO.DownloadStation.BTSearch.start': _startOk},
        legacyPages: [_legacyPage(items: [], total: 0, finished: true)],
      );

      await runSearch(tester);

      expect(find.byKey(const Key('ds-bt-no-result')), findsOneWidget);
      expect(find.text('没有找到结果'), findsOneWidget);
      expect(find.text('加载失败'), findsNothing);
      expect(find.textContaining(_taskIdSecret), findsNothing);
    });

    testWidgets('start 无权限（105）→ 中性空态说明，不是加载失败', (tester) async {
      await pump(
        tester,
        failures: {'SYNO.DownloadStation.BTSearch.start': 105},
      );

      await runSearch(tester);

      expect(find.byKey(const Key('ds-bt-unavailable')), findsOneWidget);
      expect(find.text('这个账号没有使用 BT 搜索的权限。'), findsOneWidget);
      expect(find.text('加载失败'), findsNothing);
    });
  });

  group('D-4：D1 排序 / D2 分类', () {
    Map<String, dynamic> ds2Page(List<Map<String, dynamic>> items) => {
      'is_running': false,
      'results': items,
      'total': items.length,
    };

    test('D2：list_category 回的分类进状态；选分类后带 categories 重取列表', () async {
      final booted = await _boot(
        legacy: false,
        responses: {
          'SYNO.DownloadStation2.BTSearch.start': {'id': _taskIdSecret},
          'SYNO.DownloadStation2.BTSearch.list': ds2Page([
            {
              'result_id': 'r1',
              'title': 'movie-a',
              'size': 100,
              'seeds': 5,
              'peers': 1,
              'provider': 'P',
            },
          ]),
          'SYNO.DownloadStation2.BTSearch.list_category': {
            'categories': ['Movies', 'TV'],
          },
          'SYNO.DownloadStation2.BTSearch.list_plugin_status': {
            'plugins': [
              {'id': 'a', 'can_connect': true},
            ],
          },
          'SYNO.DownloadStation2.BTSearch.stop': {'ok': true},
        },
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(btSearchProvider.notifier).search(keyword: 'ubuntu');
      var s = c.read(btSearchProvider);
      expect(s.categories, ['Movies', 'TV'], reason: '分类要上屏而不是丢掉');

      await c.read(btSearchProvider.notifier).selectCategory('Movies');
      s = c.read(btSearchProvider);
      expect(s.selectedCategory, 'Movies');
      // DS2 抓完即 stop ⇒ 会话已结束，选分类会**重跑一次搜索**，
      // 分类跟着复合请求的 `list` 走（官方 beforeSearchPolling 同款参数）。
      expect(
        t.calls.where((e) => e['method'] == 'start').length,
        2,
        reason: '会话已停，切分类必须重开会话',
      );
      final compound = t.calls
          .lastWhere((e) => e['api'] == 'SYNO.Entry.Request')['compound']
          .toString();
      expect(compound.contains('"categories":["Movies"]'), isTrue,
          reason: '分类要进 list 参数');

      // 回到全部分类：不再带 categories
      await c.read(btSearchProvider.notifier).selectCategory(null);
      expect(c.read(btSearchProvider).selectedCategory, isNull);
      final compound2 = t.calls
          .lastWhere((e) => e['api'] == 'SYNO.Entry.Request')['compound']
          .toString();
      expect(compound2.contains('categories'), isFalse);
    });

    test('D1：排序键按名称/大小/做种数生效，方向可切', () async {
      final booted = await _boot(
        legacy: false,
        responses: {
          'SYNO.DownloadStation2.BTSearch.start': {'id': _taskIdSecret},
          'SYNO.DownloadStation2.BTSearch.list': ds2Page([
            {
              'result_id': 'r1',
              'title': 'beta',
              'size': 300,
              'seeds': 9,
              'peers': 1,
              'provider': 'P',
            },
            {
              'result_id': 'r2',
              'title': 'alpha',
              'size': 100,
              'seeds': 2,
              'peers': 1,
              'provider': 'P',
            },
            {
              'result_id': 'r3',
              'title': 'gamma',
              'size': 200,
              'seeds': 5,
              'peers': 1,
              'provider': 'P',
            },
          ]),
          'SYNO.DownloadStation2.BTSearch.list_category': {'categories': []},
          'SYNO.DownloadStation2.BTSearch.list_plugin_status': {
            'plugins': [
              {'id': 'a', 'can_connect': true},
            ],
          },
          'SYNO.DownloadStation2.BTSearch.stop': {'ok': true},
        },
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(btSearchProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(btSearchProvider.notifier).search(keyword: 'ubuntu');
      final n = c.read(btSearchProvider.notifier);

      // 默认序 = 服务端返回顺序
      expect(
        c.read(btSearchProvider).sortedEntries.map((e) => e.title),
        ['beta', 'alpha', 'gamma'],
      );
      // 按名称升序
      n.setSort('title', descending: false);
      expect(
        c.read(btSearchProvider).sortedEntries.map((e) => e.title),
        ['alpha', 'beta', 'gamma'],
      );
      // 按大小降序
      n.setSort('size', descending: true);
      expect(
        c.read(btSearchProvider).sortedEntries.map((e) => e.sizeBytes),
        [300, 200, 100],
      );
      // 切方向 → 升序
      n.toggleSortDirection();
      expect(
        c.read(btSearchProvider).sortedEntries.map((e) => e.sizeBytes),
        [100, 200, 300],
      );
      // 按做种数
      n.setSort('seeds', descending: true);
      expect(
        c.read(btSearchProvider).sortedEntries.map((e) => e.seeds),
        [9, 5, 2],
      );
      // 排序不改服务端请求（纯客户端排序：不重开会话）
      expect(t.calls.where((e) => e['method'] == 'start').length, 1);
    });
  });

}
