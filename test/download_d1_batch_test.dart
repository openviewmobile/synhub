// 批次 D-1（⑥下载 A 组：列表/筛选/详情/文件清单）**离线接口层验证**。
//
// 覆盖台账 §4 A 组剩余行（本轮之前只有"已实现·未验证"）：
//   * A1  任务列表分页/总数 —— `Task/list` v2 `{offset,limit,additional,type,type_inverse}`，
//         root `task`、total `total`；
//   * A3  进度·速率·剩余时间 —— DTO 字段（`progress`/`speed_download`/`size`/
//         `size_downloaded`）与格式化函数；
//   * A5  任务详情 —— `Task/get` v2 `{id:[…], additional:["detail"]}`；
//   * A7  Tracker 列表 —— `Task.BT.Tracker/list` v2 `{task_id,offset,limit}`，root `items`；
//   * A8  Peer 列表 —— `Task.BT.Peer/list` v2 同上；
//   * A9  搜索 —— `keyword` 只在非空时下发；
//   * A10 排序 —— `sort_by` + `order`（asc/desc）；
//   * A11 批量取详情 —— `id` 数组文本一次多个。
//
// ⚠️ 全部是**只读**调用；写操作不在此文件（A6 的 `set` 已在
// `download_page_test.dart` 内以 FakeTransport 断言）。真实 NAS 调用次数 = 0。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/dto/download_task_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _dsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.DownloadStation2.Task': {
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
};

Future<(DownloadStationApi, FakeTransport)> boot({
  Map<String, Map<String, dynamic>> responses = const {},
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._dsTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (DownloadStationApi(api), t);
}

Map<String, dynamic> callOf(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

/// 与真机回包同形：root `task`（不是 items）、`additional.detail/transfer`。
Map<String, dynamic> taskJson({
  String id = '1',
  String title = 'ubuntu.iso',
  int status = 2,
  int size = 2048,
  int downloaded = 1024,
  int speed = 2048,
}) => {
  'id': id,
  'title': title,
  'type': 'bt',
  'status': status,
  'size': size,
  'additional': {
    'detail': {
      'destination': '/volume1/downloads',
      'created_time': 100,
      'priority': 'normal',
    },
    'transfer': {'size_downloaded': downloaded, 'speed_download': speed},
  },
};

void main() {
  group('D-1 A1 列表分页与总数', () {
    test('A1：offset/limit 原样、additional 是 JSON 文本、root=task', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [taskJson(id: '1'), taskJson(id: '2')],
            'total': 30,
          },
        },
      );
      final page = await ds.listTasks(offset: 25, limit: 25);
      final call = callOf(t, 'list');
      expect(call['api'], 'SYNO.DownloadStation2.Task');
      expect(call['version'], '2');
      expect(call['offset'], 25);
      expect(call['limit'], 25);
      expect(call['additional'], jsonEncode(const ['detail', 'transfer']));
      // eMule 恒排除（官方默认）
      expect(call['type'], jsonEncode(const ['emule']));
      expect(call['type_inverse'], true);
      expect(page.total, 30);
      expect(page.items.map((e) => e.id).toList(), ['1', '2']);
    });
  });

  group('D-1 A3 进度/速率/剩余时间', () {
    test('A3：DTO 取到 progress/speed/size，格式化函数给出人读值', () async {
      final (ds, _) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [taskJson(size: 4096, downloaded: 2048, speed: 2048)],
            'total': 1,
          },
        },
      );
      final page = await ds.listTasks();
      final task = page.items.single;
      expect(task.size, 4096);
      expect(task.transfer.sizeDownloaded, 2048);
      expect(task.transfer.speedDownload, 2048);
      expect(task.progress, closeTo(0.5, 0.0001));
      // 人读值（界面层同一套函数）
      expect(dsHumanRate(2048), '2 KB/s');
      expect(dsHumanBytes(4096), '4.0 KB');
      expect(dsEtaParts(90).map((e) => '${e.value}${e.unit}').join(), '1m30s');
    });
  });

  group('D-1 A5/A11 详情与批量取详情', () {
    test('A5/A11：Task/get 的 id 是数组文本，additional 只带 detail', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [taskJson(id: '31'), taskJson(id: '32')],
            'total': 2,
          },
        },
      );
      final tasks = await ds.getTasks(const ['31', '32']);
      final call = callOf(t, 'get');
      expect(call['api'], 'SYNO.DownloadStation2.Task');
      expect(call['method'], 'get');
      expect(call['id'], jsonEncode(const ['31', '32']));
      expect(call['additional'], jsonEncode(const ['detail']));
      expect(tasks.map((e) => e.id).toList(), ['31', '32']);
      expect(tasks.first.detail.destination, '/volume1/downloads');
    });
  });

  group('D-1 A7/A8 Tracker 与 Peer', () {
    test('A7：Tracker 参数与 root=items', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.BT.Tracker.list': {
            'items': [
              {'url': 'udp://tracker.example:1337', 'status': 'working'},
            ],
            'total': 1,
          },
        },
      );
      final page = await ds.listTrackers('dbid_1', offset: 0, limit: 50);
      final call = callOf(t, 'list');
      expect(call['api'], 'SYNO.DownloadStation2.Task.BT.Tracker');
      expect(call['task_id'], 'dbid_1');
      expect(call['offset'], 0);
      expect(call['limit'], 50);
      expect(page.total, 1);
      expect(page.items.single.url, 'udp://tracker.example:1337');
    });

    test('A8：Peer 参数与 root=items', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.BT.Peer.list': {
            'items': [
              {'ip': '10.0.0.9', 'port': 6881, 'download_rate': 100},
            ],
            'total': 1,
          },
        },
      );
      final page = await ds.listPeers('dbid_1');
      final call = callOf(t, 'list');
      expect(call['api'], 'SYNO.DownloadStation2.Task.BT.Peer');
      expect(call['task_id'], 'dbid_1');
      expect(page.items.single.ip, '10.0.0.9');
    });
  });

  group('D-1 A9/A10 搜索与排序', () {
    test('A9：keyword 非空才下发；空白不下发', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      await ds.listTasks(keyword: 'ubuntu');
      expect(callOf(t, 'list')['keyword'], 'ubuntu');
      await ds.listTasks(keyword: '   ');
      expect(callOf(t, 'list').containsKey('keyword'), isFalse);
    });

    test('A10：sort_by/order 成对下发（desc 逐字）', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      await ds.listTasks(sortBy: 'title', descending: true);
      final call = callOf(t, 'list');
      expect(call['sort_by'], 'title');
      expect(call['order'], 'desc');
      // 不传排序 → 两个字段都不出现（服务端默认序）
      await ds.listTasks();
      final plain = callOf(t, 'list');
      expect(plain.containsKey('sort_by'), isFalse);
      expect(plain.containsKey('order'), isFalse);
    });
  });
}
