// 批次 G3 · 下载模块 7 行缺口的**接口层**离线验证。
//
// 覆盖：
//   * B8  `Task / edit` v1–2 `{id:[…], destination}`（官方 `ui/download.js`
//         `DLM.EditTaskWindow.saveDestination` 逐字）；
//   * B10 `Task.BT.File / copy` v2 `{task_id, index:[…], destination}`
//         （官方 `DLQFileList.applyCopyTo` 逐字）；
//   * C12 `Task / pause` + `Task.BT / get|set` 的"创建后置选项"
//         （官方 `Task.create` 本身没有立即开始/限速参数）；
//   * F5  `Task.NZB.Log / get` v1 `{task_id}`，回包 `nzblog`；
//   * F6  `Task.NZB.File / list` v1 `{task_id,offset,limit}`，root `items`；
//   * F14 `Package.Info|Module|Service` v2（真机只读实调见报告 §F14）；
//   * F12 `diffDownloadCompletions` 纯函数状态差分（无服务端 API）。
//
// ⚠️ B8/B10/C12 是**写操作**：本批按纪律**未在真机调用**，这里只钉"请求拼对了、
//    失败如实上抛"。F5/F6/F14 的**方法/版本/参数名**有真机只读实调佐证（报告 §证据）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/dto/download_task_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/downloads/download_completion.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 真机 `SYNO.API.Info` 里这几个 API 的形状（path=entry.cgi；版本区间来自
/// 包内 `.lib` + 真机注册表）。
const _dsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.DownloadStation2.Task': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
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

Future<(DownloadStationApi, FakeTransport)> boot({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, Map<String, dynamic>>? apiTable,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ..._dsTable,
    ...?apiTable,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (DownloadStationApi(api), t);
}

Map<String, dynamic> callOf(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

Iterable<Map<String, dynamic>> allOf(FakeTransport t, String method) =>
    t.calls.where((c) => c['method'] == method);

Map<String, dynamic> taskJson({
  String id = '1',
  String title = 'ubuntu.iso',
  String type = 'bt',
  int status = 2,
  int createdTime = 100,
}) => {
  'id': id,
  'title': title,
  'type': type,
  'status': status,
  'additional': {
    'detail': {
      'destination': '/volume1/downloads',
      'created_time': createdTime,
    },
  },
};

void main() {
  group('B8 Task/edit：任务目的地修改', () {
    test('id 是数组文本、destination 原样、version=2', () async {
      final (ds, t) = await boot();
      await ds.editTask(['31'], destination: '/volume1/movies');
      final call = callOf(t, 'edit');
      expect(call['api'], 'SYNO.DownloadStation2.Task');
      expect(call['method'], 'edit');
      expect(call['version'], '2');
      expect(call['id'], jsonEncode(['31']));
      expect(call['destination'], '/volume1/movies');
    });

    test('priority / extract_password 只在给了的时候下发', () async {
      final (ds, t) = await boot();
      await ds.editTask(
        ['1', '2'],
        destination: '/v',
        priority: 'high',
        extractPassword: 'pw',
      );
      final call = callOf(t, 'edit');
      expect(call['id'], jsonEncode(['1', '2']));
      expect(call['priority'], 'high');
      expect(call['extract_password'], 'pw');
    });

    test('两个可改字段都空 → 抛缺参，不发请求', () async {
      final (ds, t) = await boot();
      await expectLater(ds.editTask(['1']), throwsA(isA<DsmApiException>()));
      expect(allOf(t, 'edit'), isEmpty);
    });

    test('空 id 列表 → 不发请求', () async {
      final (ds, t) = await boot();
      await ds.editTask([], destination: '/v');
      expect(allOf(t, 'edit'), isEmpty);
    });
  });

  group('B10 Task.BT.File/copy：复制文件到…', () {
    test('task_id 单个、index 是数组文本、destination 原样、version=2', () async {
      final (ds, t) = await boot();
      await ds.copyTaskFile(
        taskId: '42',
        indexes: [0, 2],
        destination: '/volume1/copy',
      );
      final call = callOf(t, 'copy');
      expect(call['api'], 'SYNO.DownloadStation2.Task.BT.File');
      expect(call['method'], 'copy');
      expect(call['version'], '2');
      expect(call['task_id'], '42');
      expect(call['index'], jsonEncode([0, 2]));
      expect(call['destination'], '/volume1/copy');
    });

    test('缺参数 → 抛缺参，不发请求', () async {
      final (ds, t) = await boot();
      await expectLater(
        ds.copyTaskFile(taskId: '', indexes: const [1], destination: '/v'),
        throwsA(isA<DsmApiException>()),
      );
      await expectLater(
        ds.copyTaskFile(taskId: '1', indexes: const [], destination: '/v'),
        throwsA(isA<DsmApiException>()),
      );
      expect(allOf(t, 'copy'), isEmpty);
    });
  });

  group('C12 新建任务后置选项：立即开始 / 排队 / 限速', () {
    test('newestTaskId：返回不在快照里、created_time 最大的那个', () async {
      final (ds, _) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [
              taskJson(id: '1', createdTime: 100),
              taskJson(id: '2', createdTime: 300),
              taskJson(id: '3', createdTime: 200),
            ],
            'total': 3,
          },
        },
      );
      final id = await ds.newestTaskId({'1'});
      expect(id, '2');
    });

    test('startImmediately=false → 创建后 Task/pause 那个新任务', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [taskJson(id: '9', createdTime: 500)],
            'total': 1,
          },
        },
      );
      final applied = await ds.applyCreateOptions(
        taskId: '9',
        startImmediately: false,
      );
      expect(applied, isTrue);
      final call = callOf(t, 'pause');
      expect(call['api'], 'SYNO.DownloadStation2.Task');
      expect(call['id'], jsonEncode(['9']));
    });

    test('给限速 → 先 Task.BT.get 再 Task.BT.set（单任务，normal）', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.BT.get': {
            'max_upload_rate': 0,
            'max_download_rate': 0,
            'seeding_ratio': 0,
            'seeding_interval': 0,
            'max_peers': 0,
          },
        },
      );
      final applied = await ds.applyCreateOptions(
        taskId: '9',
        maxDownloadRate: 512,
      );
      expect(applied, isTrue);
      final call = callOf(t, 'set');
      expect(call['api'], 'SYNO.DownloadStation2.Task.BT');
      expect(call['task_id'], jsonEncode(['9']));
      expect(call['max_download_rate'], 512);
      // 没给上传限速 → 保留读回来的 0（=不限）
      expect(call['max_upload_rate'], 0);
    });

    test('立即开始且无限速 → 一个写请求都不发', () async {
      final (ds, t) = await boot();
      final applied = await ds.applyCreateOptions(taskId: '9');
      expect(applied, isFalse);
      expect(allOf(t, 'pause'), isEmpty);
      expect(allOf(t, 'set'), isEmpty);
    });
  });

  group('F5 Task.NZB.Log/get', () {
    test('api/method/version/task_id 正确，解析 data.nzblog', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.NZB.Log.get': {'nzblog': 'line1\nline2'},
        },
      );
      final log = await ds.nzbLog('7');
      expect(log.log, 'line1\nline2');
      final call = callOf(t, 'get');
      expect(call['api'], 'SYNO.DownloadStation2.Task.NZB.Log');
      expect(call['version'], '1');
      expect(call['task_id'], '7');
    });

    test('防御性别名 log 也能读', () async {
      final (ds, _) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.NZB.Log.get': {'log': 'x'},
        },
      );
      expect((await ds.nzbLog('7')).log, 'x');
    });
  });

  group('F6 Task.NZB.File/list', () {
    test('api/method/version/task_id/offset/limit 正确，root items', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.NZB.File.list': {
            'items': [
              {'name': 'a.rar', 'size': 10},
              {'name': 'b.rar', 'size': 20},
            ],
            'total': 2,
          },
        },
      );
      final page = await ds.nzbFiles('7', offset: 0, limit: 25);
      expect(page.total, 2);
      expect(page.items.map((e) => e.name), ['a.rar', 'b.rar']);
      expect(page.items.last.size, 20);
      final call = callOf(t, 'list');
      expect(call['api'], 'SYNO.DownloadStation2.Task.NZB.File');
      expect(call['version'], '1');
      expect(call['task_id'], '7');
      expect(call['offset'], 0);
      expect(call['limit'], 25);
    });
  });

  group('F14 Package 能力探测', () {
    test('Package.Info.get v2：解析 major/minor/build/is_manager + 版本串', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Package.Info.get': {
            'major': 4,
            'minor': 1,
            'build_number': 5012,
            'is_manager': false,
          },
        },
      );
      final info = await ds.packageInfo();
      expect(info.versionString, '4.1-5012');
      expect(info.isManager, isFalse);
      final call = callOf(t, 'get');
      expect(call['api'], 'SYNO.DownloadStation2.Package.Info');
      expect(call['version'], '2');
    });

    test('Package.Module.list v2：解析 listItems', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Package.Module.list': {
            'listItems': [
              {'fn': 'SYNO.SDS.DownloadStation.DLM.Main', 'folder': 'dlm'},
              {'fn': 'SYNO.SDS.DownloadStation.aMule.Main', 'folder': 'aMule'},
            ],
          },
        },
      );
      final mods = await ds.packageModules();
      expect(mods.map((m) => m.folder), ['dlm', 'aMule']);
      final call = callOf(t, 'list');
      expect(call['api'], 'SYNO.DownloadStation2.Package.Module');
      expect(call['version'], '2');
    });

    test('Package.Service.get v2：能力位解析', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Package.Service.get': {
            'enable_bt_preview': true,
            'enable_emule': true,
            'enable_unzip': false,
            'is_unzip_service_enable': false,
          },
        },
      );
      final s = await ds.packageService();
      expect(s.enableBtPreview, isTrue);
      expect(s.enableEmule, isTrue);
      expect(s.enableUnzip, isFalse);
      expect(s.isUnzipServiceEnable, isFalse);
      expect(callOf(t, 'get')['api'], 'SYNO.DownloadStation2.Package.Service');
    });
  });

  group('F12 完成检测：纯函数状态差分', () {
    DownloadTaskDto task(String id, int status) =>
        DownloadTaskDto.fromJson(taskJson(id: id, status: status));

    test('首次加载（空快照）不产出任何事件', () {
      expect(
        diffDownloadCompletions(
          previousStatus: const {},
          current: [task('1', 5)],
        ),
        isEmpty,
      );
    });

    test('下载中 → 完成 产出一条完成事件', () {
      final events = diffDownloadCompletions(
        previousStatus: const {'1': 2},
        current: [task('1', 5)],
      );
      expect(events.length, 1);
      expect(events.first.taskId, '1');
      expect(events.first.failed, isFalse);
    });

    test('下载中 → 错误 产出 failed=true', () {
      final events = diffDownloadCompletions(
        previousStatus: const {'1': 2},
        current: [task('1', 104)],
      );
      expect(events.single.failed, isTrue);
    });

    test('已经是终态 → 不重复产出；新出现的已完成任务也不算', () {
      final events = diffDownloadCompletions(
        previousStatus: const {'1': 5, '2': 104},
        current: [task('1', 5), task('2', 104), task('3', 5)],
      );
      expect(events, isEmpty);
    });
  });
}
