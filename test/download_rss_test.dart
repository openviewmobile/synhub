// Download Station **RSS 订阅**（wave3）的离线验证。
//
// 契约事实来源：
//   * 包内 `webapi/SYNO.DownloadStation2.RSS.lib` 逐字：三个 API
//     `RSS.Feed` / `RSS.Filter` / `RSS.Item`，**都只有 v1**，
//     `allowUser=["admin.local","normal.local"]`（普通用户可用）；
//   * 包内官方前端 `ui/download.js` 的 `DLM.RSS*` 调用点（线参形态逐字）；
//   * 真机实测（`docs/download-api-live.md` §11）：`Feed:list`（含
//     `is_updating`）/ `Feed:updateall` 可用；其余"缺参 120"钉死参数名；
//     `2404`/`2405` **语义未定**。
//
// ⚠️ 真机**订阅成功路径未取证**（`Feed:add` 全部失败）：本套件只验
// "请求拼对了、回包解对了、轮询结束条件对了、降级对了、门槛对了、
// 内部 id 不上屏"。**别把离线绿当成真机已验证**。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/dto/download_task_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';
import 'package:synhub/src/features/downloads/download_rss_page.dart';
import 'package:synhub/src/features/downloads/download_rss_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 真机路径：三个 RSS API 都在 `entry.cgi`，v1 only。
const _rssTable = {
  'SYNO.DownloadStation2.RSS.Feed': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.DownloadStation2.RSS.Filter': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.DownloadStation2.RSS.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
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
};

/// **内部标识**：任何用例只要在屏幕上找到它就是失败。
const _secretFeedId = 'FEEDID-SECRET-7';
const _secretItemId = 'ITEMID-SECRET-9';

Map<String, dynamic> _feed({
  String id = _secretFeedId,
  String title = 'NASA Breaking News',
  String url = 'https://www.nasa.gov/rss/dyn/breaking_news.rss',
  int lastUpdate = 1700000000,
  bool isUpdating = false,
}) => {
  'id': id,
  'title': title,
  'url': url,
  'last_update': lastUpdate,
  'is_updating': isUpdating,
  'username': 'demo_user',
};

Map<String, dynamic> _item({
  String id = _secretItemId,
  String feedId = _secretFeedId,
  String title = 'Artemis II 更新',
  String url = 'https://www.nasa.gov/a.rss',
  String link = 'https://www.nasa.gov/detail',
  int date = 1700000000,
  int size = 2048,
  bool isNew = true,
}) => {
  'id': id,
  'feed_id': feedId,
  'title': title,
  'url': url,
  'link': link,
  'date': date,
  'size': size,
  'is_new': isNew,
};

Map<String, dynamic> _filter({
  String id = 'FILTERID-SECRET-3',
  String feedId = _secretFeedId,
  String name = '只下 1080p',
  String match = '1080p',
  String notMatch = 'CAM',
  String destination = 'downloads/rss',
  bool enable = true,
  bool isRegex = false,
}) => {
  'id': id,
  'feed_id': feedId,
  'name': name,
  'match': match,
  'not_match': notMatch,
  'destination': destination,
  'enable': enable,
  'is_regex': isRegex,
};

/// 记录 path + 能按次序给 `Feed:list` 不同回包（验轮询会**自己停**）。
class _RssTransport extends FakeTransport {
  _RssTransport(super.responses, super.apiTable);

  final List<String> paths = [];

  /// `Feed:list` 的**逐次**回包队列；空则回落 [responses]。
  final List<Map<String, dynamic>> feedQueue = [];

  int feedListCount = 0;

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    paths.add(path);
    if (params['api'] == 'SYNO.DownloadStation2.RSS.Feed' &&
        params['method'] == 'list' &&
        feedQueue.isNotEmpty) {
      feedListCount++;
      calls.add(params);
      final data = feedQueue.length > 1
          ? feedQueue.removeAt(0)
          : feedQueue.first;
      return jsonEncode({'success': true, 'data': data});
    }
    return super.postForm(path, params);
  }

  int countMethod(String method) =>
      calls.where((c) => c['method'] == method).length;

  Map<String, dynamic> lastCall(String method) =>
      calls.lastWhere((c) => c['method'] == method);
}

Future<({DsmWebApi api, DownloadStationApi ds, _RssTransport t})> _boot({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
}) async {
  final t = _RssTransport(responses, {...FakeTransport.table, ..._rssTable});
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'demo_user', password: 'x');
  return (api: api, ds: DownloadStationApi(api), t: t);
}

({ProviderContainer c, _RssTransport t}) _container(
  DsmWebApi api, {
  int maxPolls = 120,
  Duration interval = Duration.zero,
}) {
  final t = api.transport as _RssTransport;
  final c = ProviderContainer(
    overrides: [
      downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
      rssPollIntervalProvider.overrideWithValue(interval),
      rssMaxPollsProvider.overrideWithValue(maxPolls),
    ],
  );
  return (c: c, t: t);
}

void main() {
  group('数据层：请求形状逐字对齐官方 JS', () {
    test('Feed:list 走 entry.cgi，v1，分页参数是 offset/limit', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [_feed()],
            'total': 1,
          },
        },
      );

      final page = await ds.rssFeedList();

      final call = t.lastCall('list');
      expect(call['api'], 'SYNO.DownloadStation2.RSS.Feed');
      expect(call['version'], '1');
      expect(call['offset'], 0);
      expect(call['limit'], DownloadStationApi.rssPageSize); // 官方 50
      expect(t.paths.last, 'entry.cgi');
      expect(page.total, 1);
      expect(page.items.single.title, 'NASA Breaking News');
      expect(page.items.single.isUpdating, isFalse);
      expect(page.isUpdating, isFalse);
    });

    test('Feed:list 顶层 is_updating 被解析（真机回包字段）', () async {
      final (api: _, :ds, t: _) = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': true,
            'items': [],
            'total': 0,
          },
        },
      );
      final page = await ds.rssFeedList();
      expect(page.isUpdating, isTrue);
      expect(page.anyUpdating, isTrue);
    });

    test('Feed:add 线参是 url（不是 link/name/path）', () async {
      final (api: _, :ds, :t) = await _boot();

      await ds.rssFeedAdd(url: '  https://example.com/feed.xml  ');

      final call = t.lastCall('add');
      expect(call['api'], 'SYNO.DownloadStation2.RSS.Feed');
      expect(call['version'], '1');
      expect(call['url'], 'https://example.com/feed.xml'); // trim
      expect(call.containsKey('link'), isFalse);
      expect(call.containsKey('name'), isFalse);
      expect(call.containsKey('path'), isFalse);
      expect(call.containsKey('enable_auto_download'), isFalse);
    });

    test('Feed:add 勾了自动下载 → enable_auto_download + destination 字符串', () async {
      final (api: _, :ds, :t) = await _boot();

      await ds.rssFeedAdd(
        url: 'https://example.com/feed.xml',
        enableAutoDownload: true,
        destination: 'downloads/rss',
      );

      final call = t.lastCall('add');
      expect(call['enable_auto_download'], isTrue);
      expect(call['destination'], 'downloads/rss');
    });

    test('Feed:add 空 url 本地就拦（缺参通道，不发请求）', () async {
      final (api: _, :ds, :t) = await _boot();
      await expectLater(
        () => ds.rssFeedAdd(url: '   '),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noRequiredParam,
          ),
        ),
      );
      expect(t.countMethod('add'), 0);
    });

    test('Feed:set 线参 = id + title + url（官方 RSSEditDialog 表单字段）', () async {
      final (api: _, :ds, :t) = await _boot();

      await ds.rssFeedSet(
        id: _secretFeedId,
        title: '新名字',
        url: 'https://example.com/new.xml',
      );

      final call = t.lastCall('set');
      expect(call['id'], _secretFeedId);
      expect(call['title'], '新名字');
      expect(call['url'], 'https://example.com/new.xml');
    });

    test('Feed:delete / update 的 id 是数组（JSON 文本，官方多选）', () async {
      final (api: _, :ds, :t) = await _boot();

      await ds.rssFeedDelete([_secretFeedId, 'b']);
      expect(jsonDecode(t.lastCall('delete')['id'] as String), [
        _secretFeedId,
        'b',
      ]);

      await ds.rssFeedUpdate([_secretFeedId]);
      expect(jsonDecode(t.lastCall('update')['id'] as String), [_secretFeedId]);
    });

    test('Feed:updateall 无参（官方 sendRequest("updateall")）', () async {
      final (api: _, :ds, :t) = await _boot();

      await ds.rssFeedUpdateAll();

      final call = t.lastCall('updateall');
      expect(call['api'], 'SYNO.DownloadStation2.RSS.Feed');
      expect(call['version'], '1');
      expect(call.keys.toSet(), {'api', 'version', 'method', '_sid'});
    });

    test('Item:list 必带 feed_id（+offset/limit），字段名 = 官方 store', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Item.list': {
            'items': [_item()],
            'total': 3,
          },
        },
      );

      final page = await ds.rssItemList(feedId: _secretFeedId, offset: 50);

      final call = t.lastCall('list');
      expect(call['api'], 'SYNO.DownloadStation2.RSS.Item');
      expect(call['feed_id'], _secretFeedId);
      expect(call['offset'], 50);
      expect(call['limit'], DownloadStationApi.rssPageSize);
      final it = page.items.single;
      expect(it.id, _secretItemId);
      expect(it.feedId, _secretFeedId);
      expect(it.url, 'https://www.nasa.gov/a.rss');
      expect(it.link, 'https://www.nasa.gov/detail');
      expect(it.isNew, isTrue);
      expect(page.total, 3);
    });

    test('Item:clear 线参 = feed_id', () async {
      final (api: _, :ds, :t) = await _boot();
      await ds.rssItemClear(_secretFeedId);
      final call = t.lastCall('clear');
      expect(call['api'], 'SYNO.DownloadStation2.RSS.Item');
      expect(call['feed_id'], _secretFeedId);
    });

    test('Filter:list 必带 feed_id，且 sort_by=name（官方 baseParams）', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Filter.list': {
            'items': [_filter()],
            'total': 1,
          },
        },
      );

      final page = await ds.rssFilterList(feedId: _secretFeedId);

      final call = t.lastCall('list');
      expect(call['api'], 'SYNO.DownloadStation2.RSS.Filter');
      expect(call['feed_id'], _secretFeedId);
      expect(call['sort_by'], 'name');
      expect(page.items.single.destination, 'downloads/rss');
      expect(page.items.single.isRegex, isFalse);
    });

    test(
      'Filter:add 线参 = feed_id+name+match+not_match+destination+is_regex',
      () async {
        final (api: _, :ds, :t) = await _boot();

        await ds.rssFilterAdd(
          feedId: _secretFeedId,
          name: '只下 1080p',
          destination: 'downloads/rss',
          match: '1080p',
          notMatch: 'CAM',
        );

        final call = t.lastCall('add');
        expect(call['api'], 'SYNO.DownloadStation2.RSS.Filter');
        expect(call['feed_id'], _secretFeedId);
        expect(call['name'], '只下 1080p');
        expect(call['match'], '1080p');
        expect(call['not_match'], 'CAM');
        // ★ 官方 JS 取证：destination 是**字符串**（文件夹路径），不是数组/JSON 串。
        expect(call['destination'], isA<String>());
        expect(call['destination'], 'downloads/rss');
        expect(call['is_regex'], isFalse);
      },
    );

    test(
      'Filter:test 线参 = test_string+match+not_match+is_regex，回包取 matched',
      () async {
        final (api: _, :ds, :t) = await _boot(
          responses: {
            'SYNO.DownloadStation2.RSS.Filter.test': {'matched': true},
          },
        );

        final matched = await ds.rssFilterTest(
          testString: 'Show.S01.1080p.WEB',
          match: '1080p',
        );

        final call = t.lastCall('test');
        expect(call['api'], 'SYNO.DownloadStation2.RSS.Filter');
        expect(call['test_string'], 'Show.S01.1080p.WEB');
        expect(call['match'], '1080p');
        expect(call['not_match'], '');
        expect(call['is_regex'], isFalse);
        expect(matched, isTrue);
      },
    );

    test('Filter:delete 的 id 是数组', () async {
      final (api: _, :ds, :t) = await _boot();
      await ds.rssFilterDelete(['a', 'b']);
      expect(jsonDecode(t.lastCall('delete')['id'] as String), ['a', 'b']);
    });
  });

  group('错误码：未定语义绝不被写死文案', () {
    test('2404 / 2405 → 通用"未知错误 + 原始码"（不是自造语义）', () {
      final a = describeDownloadRssError(DsmApiException(2404));
      final b = describeDownloadRssError(DsmApiException(2405));
      // 通用通道把原始码带出来。
      expect(a, contains('2404'));
      expect(b, contains('2405'));
      // 绝不能出现任何"URL/地址/格式/无效/可达"之类的猜测性文案。
      for (final s in [a, b]) {
        expect(s.contains('URL'), isFalse);
        expect(s.contains('链接'), isFalse);
        expect(s.contains('无效'), isFalse);
        expect(s.contains('格式'), isFalse);
      }
      // 两个码的文案必须**只差数字**（同一通用通道）。
      expect(a.replaceAll('2404', '#'), b.replaceAll('2405', '#'));
    });

    test('120 走既有通用参数通道（不是"压缩包已损坏"的状态表文案）', () {
      final s = describeDownloadRssError(DsmApiException(120));
      expect(
        s,
        DsmErrorCode.messagesText()[DsmErrorCode.requestParameterInvalid],
      );
      expect(s.contains('压缩'), isFalse);
    });

    test('其余码继续用下载模块的既有解释（1408 中性文案）', () {
      expect(
        describeDownloadRssError(DsmApiException(1408)),
        describeDownloadError(DsmApiException(1408)),
      );
    });
  });

  group('状态机：轮询 / 结束条件 / 三态 / 降级', () {
    test('加载订阅列表成功；is_updating=false 不起轮询', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [_feed()],
            'total': 1,
          },
        },
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(rssProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(rssProvider.notifier).loadFeeds();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final s = c.read(rssProvider);
      expect(s.loaded, isTrue);
      expect(s.feeds, hasLength(1));
      expect(s.polling, isFalse);
      expect(t.countMethod('list'), 1, reason: '不起轮询 → 只发一次');
    });

    test('is_updating=true → 轮询；变 false 后自己停', () async {
      final booted = await _boot();
      final t = booted.t;
      // 第 1 次 true、第 2 次 true、第 3 次 false（之后固定 false）。
      t.feedQueue.addAll([
        {
          'is_updating': true,
          'items': [_feed(isUpdating: true)],
          'total': 1,
        },
        {
          'is_updating': true,
          'items': [_feed(isUpdating: true)],
          'total': 1,
        },
        {
          'is_updating': false,
          'items': [_feed()],
          'total': 1,
        },
      ]);
      final (:c, t: _) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(rssProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(rssProvider.notifier).loadFeeds();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final s = c.read(rssProvider);
      expect(s.polling, isFalse);
      expect(s.feeds.single.isUpdating, isFalse);
      // 首拉 + 轮询 2 次（第 3 次回包 false 就停）。
      expect(t.feedListCount, 3);
    });

    test('服务端永远 is_updating → 到 maxPolls 上限必须停（不死转）', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': true,
            'items': [_feed(isUpdating: true)],
            'total': 1,
          },
        },
      );
      final t = booted.t;
      final (:c, t: _) = _container(booted.api, maxPolls: 3);
      addTearDown(c.dispose);
      final sub = c.listen(rssProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(rssProvider.notifier).loadFeeds();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final s = c.read(rssProvider);
      expect(s.polling, isFalse, reason: '到顶必须停');
      expect(s.polls, lessThanOrEqualTo(3));
      final atStop = t.countMethod('list');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(t.countMethod('list'), atStop, reason: '停后不得再轮询');
    });

    test('能力表缺 RSS.Feed → 中性 notInstalled（不是"加载失败"）', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table});
      final api = DsmWebApi(t);
      await api.discover();
      final c = ProviderContainer(
        overrides: [
          downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
        ],
      );
      addTearDown(c.dispose);
      final sub = c.listen(rssProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(rssProvider.notifier).loadFeeds();

      final s = c.read(rssProvider);
      expect(s.block, RssBlock.notInstalled);
      expect(s.errorText, isNull);
    });

    test('addFeed 失败抛错（2404）→ 文案带原始码，不伪造语义', () async {
      final booted = await _boot(
        failures: {'SYNO.DownloadStation2.RSS.Feed.add': 2404},
      );
      final (:c, t: _) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(rssProvider, (_, _) {});
      addTearDown(sub.close);

      Object? caught;
      try {
        await c
            .read(rssProvider.notifier)
            .addFeed('https://example.com/feed.xml');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<DsmApiException>());
      expect(describeDownloadRssError(caught!), contains('2404'));
    });

    test('updateAll / deleteFeeds / updateFeeds 打到正确的 method', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [_feed()],
            'total': 1,
          },
        },
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(rssProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(rssProvider.notifier).loadFeeds();

      await c.read(rssProvider.notifier).updateAll();
      expect(t.countMethod('updateall'), 1);

      await c.read(rssProvider.notifier).updateFeeds([_secretFeedId]);
      expect(jsonDecode(t.lastCall('update')['id'] as String), [_secretFeedId]);

      await c.read(rssProvider.notifier).deleteFeeds([_secretFeedId]);
      expect(jsonDecode(t.lastCall('delete')['id'] as String), [_secretFeedId]);
    });

    test(
      'selectFeed → Item:list + Filter:list 都带 feed_id；条目分页 offset',
      () async {
        final booted = await _boot(
          responses: {
            'SYNO.DownloadStation2.RSS.Feed.list': {
              'is_updating': false,
              'items': [_feed()],
              'total': 1,
            },
            'SYNO.DownloadStation2.RSS.Item.list': {
              'items': [_item()],
              'total': 2,
            },
            'SYNO.DownloadStation2.RSS.Filter.list': {
              'items': [_filter()],
              'total': 1,
            },
          },
        );
        final (:c, :t) = _container(booted.api);
        addTearDown(c.dispose);
        final sub = c.listen(rssProvider, (_, _) {});
        addTearDown(sub.close);

        await c.read(rssProvider.notifier).loadFeeds();
        await c.read(rssProvider.notifier).selectFeed(_secretFeedId);

        var s = c.read(rssProvider);
        expect(s.items, hasLength(1));
        expect(s.itemsTotal, 2);
        expect(s.itemsLoaded, isTrue);
        expect(s.filters, hasLength(1));
        expect(s.filtersLoaded, isTrue);
        expect(t.lastCall('list')['feed_id'], _secretFeedId);

        // 下一页：offset = 已加载条数。
        await c.read(rssProvider.notifier).loadMoreItems();
        s = c.read(rssProvider);
        final itemCalls = t.calls
            .where((x) => x['api'] == 'SYNO.DownloadStation2.RSS.Item')
            .toList();
        expect(itemCalls.first['offset'], 0);
        expect(itemCalls.last['offset'], 1);
      },
    );

    test('Item:list 失败 → itemsError（失败态），不是崩', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [_feed()],
            'total': 1,
          },
        },
        failures: {'SYNO.DownloadStation2.RSS.Item.list': 519},
      );
      final (:c, t: _) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(rssProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(rssProvider.notifier).loadFeeds();
      await c.read(rssProvider.notifier).selectFeed(_secretFeedId);

      final s = c.read(rssProvider);
      expect(s.itemsLoaded, isTrue);
      expect(s.items, isEmpty);
      expect(s.itemsError, isNotNull);
    });

    test('条目空 → itemsLoaded 且空（空态，不是失败）', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [_feed()],
            'total': 1,
          },
          'SYNO.DownloadStation2.RSS.Item.list': {'items': [], 'total': 0},
          'SYNO.DownloadStation2.RSS.Filter.list': {'items': [], 'total': 0},
        },
      );
      final (:c, t: _) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(rssProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(rssProvider.notifier).loadFeeds();
      await c.read(rssProvider.notifier).selectFeed(_secretFeedId);

      final s = c.read(rssProvider);
      expect(s.itemsLoaded, isTrue);
      expect(s.items, isEmpty);
      expect(s.itemsError, isNull);
    });

    test('clearItems / addFilter / testFilter 走对方法', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [_feed()],
            'total': 1,
          },
          'SYNO.DownloadStation2.RSS.Item.list': {'items': [], 'total': 0},
          'SYNO.DownloadStation2.RSS.Filter.list': {'items': [], 'total': 0},
          'SYNO.DownloadStation2.RSS.Filter.test': {'matched': false},
        },
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(rssProvider, (_, _) {});
      addTearDown(sub.close);

      await c.read(rssProvider.notifier).loadFeeds();
      await c.read(rssProvider.notifier).selectFeed(_secretFeedId);

      await c.read(rssProvider.notifier).clearItems();
      expect(t.lastCall('clear')['feed_id'], _secretFeedId);

      await c
          .read(rssProvider.notifier)
          .addFilter(name: 'r', destination: 'd', match: 'm');
      expect(t.lastCall('add')['feed_id'], _secretFeedId);
      expect(t.lastCall('add')['destination'], 'd');

      final matched = await c
          .read(rssProvider.notifier)
          .testFilter(testString: 'abc');
      expect(matched, isFalse);
    });

    test('离开页面（autoDispose）后停止轮询（不泄漏）', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': true,
            'items': [_feed(isUpdating: true)],
            'total': 1,
          },
        },
      );
      final (:c, :t) = _container(
        booted.api,
        interval: const Duration(seconds: 30),
      );
      addTearDown(c.dispose);
      final sub = c.listen(rssProvider, (_, _) {});

      await c.read(rssProvider.notifier).loadFeeds();
      await Future<void>.delayed(Duration.zero);
      final before = t.countMethod('list');

      sub.close(); // 页面离开
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(t.countMethod('list'), before, reason: '离开后不得再轮询');
    });
  });

  group('页面：三态 / 门控 / 内部 id 不上屏', () {
    Future<({_RssTransport t, ProviderContainer c})> pumpRss(
      WidgetTester tester, {
      Map<String, Map<String, dynamic>> responses = const {},
      Map<String, int> failures = const {},
    }) async {
      final booted = await _boot(responses: responses, failures: failures);
      final c = ProviderContainer(
        overrides: [
          downloadApiProvider.overrideWithValue(DownloadStationApi(booted.api)),
          rssPollIntervalProvider.overrideWithValue(Duration.zero),
          rssMaxPollsProvider.overrideWithValue(3),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DownloadRssPage()),
        ),
      );
      await tester.pump(); // postFrame → loadFeeds
      await tester.pump();
      return (t: booted.t, c: c);
    }

    testWidgets('订阅列表显示 title/url；内部 id 绝不上屏', (tester) async {
      await pumpRss(
        tester,
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [_feed()],
            'total': 1,
          },
        },
      );

      expect(find.text('NASA Breaking News'), findsOneWidget);
      expect(find.textContaining('breaking_news.rss'), findsOneWidget);
      // 硬要求：内部 id 不上屏。
      expect(find.text(_secretFeedId), findsNothing);
      expect(find.textContaining(_secretFeedId), findsNothing);
    });

    testWidgets('空列表 → 空态（不是"加载失败"）', (tester) async {
      await pumpRss(
        tester,
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [],
            'total': 0,
          },
        },
      );

      expect(find.byKey(const Key('ds-rss-empty')), findsOneWidget);
      expect(find.byKey(const Key('ds-rss-error')), findsNothing);
    });

    testWidgets('RSS.Feed 缺失 → 中性不可用态（不是"加载失败"）', (tester) async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        'SYNO.DownloadStation2.RSS.Filter': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      });
      final api = DsmWebApi(t);
      await api.discover();
      final c = ProviderContainer(
        overrides: [
          downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DownloadRssPage()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('ds-rss-unavailable')), findsOneWidget);
      expect(find.byKey(const Key('ds-rss-error')), findsNothing);
    });

    testWidgets('只有 RSS.Feed（缺 Filter/Item）→ 列表照常，条目/过滤器优雅降级不崩', (
      tester,
    ) async {
      final t = FakeTransport(
        {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [_feed()],
            'total': 1,
          },
        },
        {
          ...FakeTransport.table,
          'SYNO.DownloadStation2.RSS.Feed': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      final api = DsmWebApi(t);
      await api.discover();
      final c = ProviderContainer(
        overrides: [
          downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DownloadRssPage()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('NASA Breaking News'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ds-rss-feed-0')));
      await tester.pumpAndSettle();
      // 条目 API 缺失 → 明确空态，不崩、不报"加载失败"。
      expect(find.byKey(const Key('ds-rss-items-empty')), findsOneWidget);
      expect(find.byKey(const Key('ds-rss-items-error')), findsNothing);
    });

    testWidgets('添加订阅：填 url 提交 → Feed:add 带 url', (tester) async {
      final r = await pumpRss(
        tester,
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [],
            'total': 0,
          },
        },
      );

      await tester.tap(find.byKey(const Key('ds-rss-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('ds-rss-url')),
        'https://example.com/feed.xml',
      );
      await tester.tap(find.byKey(const Key('ds-rss-add-submit')));
      await tester.pumpAndSettle();

      final add = r.t.lastCall('add');
      expect(add['url'], 'https://example.com/feed.xml');
    });

    testWidgets('选中订阅 → 条目页显示条目；内部 id 不上屏', (tester) async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [_feed()],
            'total': 1,
          },
          'SYNO.DownloadStation2.RSS.Item.list': {
            'items': [_item()],
            'total': 1,
          },
          'SYNO.DownloadStation2.RSS.Filter.list': {
            'items': [_filter()],
            'total': 1,
          },
        },
      );
      final c = ProviderContainer(
        overrides: [
          downloadApiProvider.overrideWithValue(DownloadStationApi(booted.api)),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DownloadRssPage()),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('ds-rss-feed-0')));
      await tester.pumpAndSettle();

      expect(find.text('Artemis II 更新'), findsOneWidget);
      expect(find.text(_secretItemId), findsNothing);
      expect(find.textContaining(_secretItemId), findsNothing);
      expect(find.textContaining(_secretFeedId), findsNothing);
    });

    testWidgets('条目失败 → 失败态（可重试）', (tester) async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'is_updating': false,
            'items': [_feed()],
            'total': 1,
          },
          'SYNO.DownloadStation2.RSS.Filter.list': {'items': [], 'total': 0},
        },
        failures: {'SYNO.DownloadStation2.RSS.Item.list': 519},
      );
      final c = ProviderContainer(
        overrides: [
          downloadApiProvider.overrideWithValue(DownloadStationApi(booted.api)),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DownloadRssPage()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('ds-rss-feed-0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ds-rss-items-error')), findsOneWidget);
      expect(find.byKey(const Key('ds-rss-items-empty')), findsNothing);
    });
  });

  group('能力门控：RSS API 缺失 → 隐藏入口（回归保护）', () {
    Future<void> pumpDownloadPage(
      WidgetTester tester, {
      required bool withRss,
    }) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._rssTable});
      if (!withRss) {
        // "任一不可用 → 隐藏入口"：只抽掉 `RSS.Item`（其余两个仍在），
        // 入口必须同样消失。
        t.apiTable.remove('SYNO.DownloadStation2.RSS.Item');
      }
      final api = DsmWebApi(t);
      await api.discover();
      final c = ProviderContainer(
        overrides: [
          downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DownloadPage()),
        ),
      );
      await tester.pump(); // postFrame
      // 下载页里有零延迟 Timer（既有页面行为）：等到它跑完，避免 pending timer。
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('三个 RSS API 都在 → 显示入口', (tester) async {
      await pumpDownloadPage(tester, withRss: true);
      expect(find.byKey(const Key('ds-rss-open')), findsOneWidget);
    });

    testWidgets('任一 RSS API 缺失 → 隐藏入口', (tester) async {
      await pumpDownloadPage(tester, withRss: false);
      expect(find.byKey(const Key('ds-rss-open')), findsNothing);
    });
  });

  group('解析宽容性（字段缺失/类型不对不崩）', () {
    test('未知字段/缺失字段回落中性值，保留 raw', () {
      final f = DsRssFeed.fromJson({'id': 7, 'is_updating': 'yes'});
      expect(f.id, '7');
      expect(f.title, '');
      expect(f.isUpdating, isFalse); // 只有真 bool true 才算更新
      expect(f.raw['id'], 7);

      final i = DsRssItem.fromJson({'size': '1024', 'date': null});
      expect(i.size, 1024);
      expect(i.date, 0);

      final p = DsRssFilterPage.fromJson({'items': 'oops'});
      expect(p.items, isEmpty);
    });
  });

  group('E4/E5：修改订阅与修改规则（本轮补的写分支）', () {
    test('E4：Feed:set 带 {id,title,url}（改名/改址），版本 v1', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.set': {'success': true},
        },
      );
      await ds.rssFeedSet(id: 'f1', title: '新名字', url: 'https://e.com/f.xml');
      final call = t.lastCall('set');
      expect(call['api'], 'SYNO.DownloadStation2.RSS.Feed');
      expect(call['id'], 'f1');
      expect(call['title'], '新名字');
      expect(call['url'], 'https://e.com/f.xml');
    });

    test('E4：只改名时不发 url（另一半保持服务端原值）', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.set': {'success': true},
        },
      );
      await ds.rssFeedSet(id: 'f1', title: '只改名');
      final call = t.lastCall('set');
      expect(call['title'], '只改名');
      expect(call.containsKey('url'), isFalse);
    });

    test('E5：Filter:set 全参逐字（含 is_regex）', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Filter.set': {'success': true},
        },
      );
      await ds.rssFilterSet(
        id: 'r1',
        feedId: 'f1',
        name: '规则A',
        destination: '/volume1/tv',
        match: 'S01',
        notMatch: 'sample',
        isRegex: true,
      );
      final call = t.lastCall('set');
      expect(call['api'], 'SYNO.DownloadStation2.RSS.Filter');
      expect(call['id'], 'r1');
      expect(call['feed_id'], 'f1');
      expect(call['name'], '规则A');
      expect(call['match'], 'S01');
      expect(call['not_match'], 'sample');
      expect(call['destination'], '/volume1/tv');
      expect(call['is_regex'], true);
    });

    test('E5：provider 的 editFilter 走 Filter:set，不是 Filter:add', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'items': [
              {'id': 'f1', 'title': 'F1', 'url': 'https://e.com/f.xml'},
            ],
            'total': 1,
          },
          'SYNO.DownloadStation2.RSS.Filter.list': {'items': [], 'total': 0},
          'SYNO.DownloadStation2.RSS.Filter.set': {'success': true},
          'SYNO.DownloadStation2.RSS.Filter.add': {'success': true},
        },
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      await c.read(rssProvider.notifier).loadFeeds();
      c.read(rssProvider.notifier).selectFeed('f1');
      await c.read(rssProvider.notifier).loadFilters();
      t.calls.clear();

      await c.read(rssProvider.notifier).editFilter(
        id: 'r1',
        name: '规则A',
        destination: '/volume1/tv',
        match: 'S01',
      );

      final methods = t.calls
          .where((e) => e['api'] == 'SYNO.DownloadStation2.RSS.Filter')
          .map((e) => e['method'])
          .toList();
      expect(methods, contains('set'));
      expect(methods, isNot(contains('add')),
          reason: '编辑走 add 会多出一条规则（原 bug）');
      expect(t.lastCall('set')['id'], 'r1');
    });

    test('E4：provider 的 editFeed 走 Feed:set 并刷新列表', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.RSS.Feed.list': {
            'items': [
              {'id': 'f1', 'title': 'F1', 'url': 'https://e.com/f.xml'},
            ],
            'total': 1,
          },
          'SYNO.DownloadStation2.RSS.Feed.set': {'success': true},
        },
      );
      final (:c, :t) = _container(booted.api);
      addTearDown(c.dispose);
      await c.read(rssProvider.notifier).loadFeeds();
      t.calls.clear();

      await c.read(rssProvider.notifier).editFeed(
        id: 'f1',
        title: 'F2',
        url: 'https://e.com/g.xml',
      );

      expect(t.lastCall('set')['id'], 'f1');
      expect(
        t.calls.where((e) => e['method'] == 'list').isNotEmpty,
        isTrue,
        reason: '改完要刷新订阅列表',
      );
    });
  });

}
