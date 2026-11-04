// 批次 D-2（⑥下载 B 组：任务操作）**离线接口层验证**。
//
// 覆盖台账 §4 B 组的 10 行（本轮之前多为"已实现·未验证"）：
//   * B1  单任务暂停/恢复 —— `Task/pause|resume` v1–2 `{id:[…]}`；
//   * B2  单任务删除 —— `Task/delete` `{id:[…], force_complete:false}`；
//   * B3  "连带删除文件"语义 —— 官方 `.so` 无该开关（unlink 是服务端行为），
//         客户端**只发 id + force_complete**，不伪造复选框参数；
//   * B4  全部暂停/全部恢复 —— `Task/pause_condition|resume_condition` v2
//         `{type:["emule"], type_inverse:true}`；
//   * B5  清除已完成 / 删除错误任务 —— `Task/delete_condition` v2
//         （已完成 `status:[5]`；错误态全表用 `DsTaskStatus.errorGroup`）；
//   * B6  结束任务 —— 同 `Task/delete` 但 `force_complete:true`
//         （官方 `str_force_complete`，"结束后不可续传"）；
//   * B7  任务优先级 —— `Task.BT/set` `priority: high|normal|low`；
//   * B8  目的地修改 —— `Task/edit` v2 `{id:[…], destination}`；
//   * B9  BT 限速/做种 —— `Task.BT/set` 的 `max_*_rate`/`seeding_*`/`max_peers`；
//   * B10 复制文件 —— `Task.BT.File/copy` v2 `{task_id, index:[…], destination}`。
//
// ⚠️ 写操作**全部只发到 FakeTransport**（真实 NAS 调用次数 = 0）。
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
};

Future<(DownloadStationApi, FakeTransport)> boot() async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._dsTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (DownloadStationApi(api), t);
}

Map<String, dynamic> callOf(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

void main() {
  group('D-2 B1/B2/B3 单任务暂停·恢复·删除', () {
    test('B1：pause/resume 的 id 是数组文本', () async {
      final (ds, t) = await boot();
      await ds.pauseTasks(const ['31', '32']);
      expect(callOf(t, 'pause')['id'], jsonEncode(const ['31', '32']));
      await ds.resumeTasks(const ['31']);
      expect(callOf(t, 'resume')['id'], jsonEncode(const ['31']));
      // 空列表零调用
      final before = t.calls.length;
      await ds.pauseTasks(const []);
      expect(t.calls.length, before);
    });

    test('B2：delete 带 force_complete=false', () async {
      final (ds, t) = await boot();
      await ds.deleteTasks(const ['31']);
      final call = callOf(t, 'delete');
      expect(call['api'], 'SYNO.DownloadStation2.Task');
      expect(call['id'], jsonEncode(const ['31']));
      expect(call['force_complete'], false);
    });

    test('B3：没有"保留文件"开关 —— 参数里不许出现 unlink/delete_file', () async {
      final (ds, t) = await boot();
      await ds.deleteTasks(const ['31']);
      final call = callOf(t, 'delete');
      // 官方 .so 里只有 force_complete；unlink 是服务端行为
      expect(call.containsKey('unlink'), isFalse);
      expect(call.containsKey('delete_file'), isFalse);
      expect(
        call.keys.where((k) => k != '_sid').toSet(),
        {'api', 'method', 'version', 'id', 'force_complete'},
      );
    });
  });

  group('D-2 B4/B5/B6 批量条件操作', () {
    test('B4：pause_condition/resume_condition 只带 type 过滤', () async {
      final (ds, t) = await boot();
      await ds.pauseAll();
      final p = callOf(t, 'pause_condition');
      expect(p['api'], 'SYNO.DownloadStation2.Task');
      expect(p['version'], '2');
      expect(p['type'], jsonEncode(const ['emule']));
      expect(p['type_inverse'], true);
      await ds.resumeAll();
      final r = callOf(t, 'resume_condition');
      expect(r['type_inverse'], true);
    });

    test('B5：clear 已完成 = status:[5]；错误任务 = 错误态全表', () async {
      final (ds, t) = await boot();
      await ds.deleteCondition(statuses: const [DsTaskStatus.finished]);
      final p = callOf(t, 'delete_condition');
      expect(p['method'], 'delete_condition');
      expect(p['status'], jsonEncode(const [5]));
      await ds.deleteCondition(statuses: DsTaskStatus.errorGroup);
      final e = callOf(t, 'delete_condition');
      final sent = jsonDecode(e['status'] as String) as List;
      expect(sent.first, 101);
      expect(sent.length, DsTaskStatus.errorGroup.length);
      // 空 statuses = 删除全部（官方 delete_all），此时不发 status 字段
      await ds.deleteCondition();
      expect(callOf(t, 'delete_condition').containsKey('status'), isFalse);
    });

    test('B6：结束任务 = delete + force_complete=true', () async {
      final (ds, t) = await boot();
      await ds.deleteTasks(const ['31'], forceComplete: true);
      expect(callOf(t, 'delete')['force_complete'], true);
    });
  });

  group('D-2 B7/B9 BT 设置', () {
    test('B7：优先级 high/normal/low 逐字（空值不下发）', () async {
      final (ds, t) = await boot();
      await ds.setBtSettings(
        '31',
        const DownloadBtSettings(priority: 'high'),
      );
      final call = callOf(t, 'set');
      expect(call['api'], 'SYNO.DownloadStation2.Task.BT');
      expect(call['task_id'], jsonEncode(const ['31']));
      expect(call['priority'], 'high');
      // 空 priority → 不出现该字段（服务端保持原值）
      await ds.setBtSettings('31', const DownloadBtSettings(priority: ''));
      expect(callOf(t, 'set').containsKey('priority'), isFalse);
    });

    test('B9：限速/做种参数逐字成对下发', () async {
      final (ds, t) = await boot();
      await ds.setBtSettings(
        '31',
        const DownloadBtSettings(
          maxDownloadRate: 1024,
          maxUploadRate: 256,
          seedingRatio: 200,
          seedingInterval: 60,
          maxPeers: 50,
        ),
      );
      final call = callOf(t, 'set');
      expect(call['max_download_rate'], 1024);
      expect(call['max_upload_rate'], 256);
      expect(call['seeding_ratio'], 200);
      expect(call['seeding_interval'], 60);
      expect(call['max_peers'], 50);
    });
  });

  group('D-2 B8/B10 目的地与文件复制', () {
    test('B8：Task/edit 的 id 数组 + destination 原样', () async {
      final (ds, t) = await boot();
      await ds.editTask(const ['31'], destination: '/volume1/movies');
      final call = callOf(t, 'edit');
      expect(call['api'], 'SYNO.DownloadStation2.Task');
      expect(call['version'], '2');
      expect(call['id'], jsonEncode(const ['31']));
      expect(call['destination'], '/volume1/movies');
    });

    test('B10：Task.BT.File/copy 的 index 数组 + destination', () async {
      final (ds, t) = await boot();
      await ds.copyTaskFile(
        taskId: 'dbid_1',
        indexes: const [0, 2],
        destination: '/volume1/movies',
      );
      final call = callOf(t, 'copy');
      expect(call['api'], 'SYNO.DownloadStation2.Task.BT.File');
      expect(call['task_id'], 'dbid_1');
      expect(call['index'], jsonEncode(const [0, 2]));
      expect(call['destination'], '/volume1/movies');
      // 空 index → **零调用**，并以 114 明确拒绝（数据层守卫，不是静默成功）
      final before = t.calls.length;
      await expectLater(
        ds.copyTaskFile(
          taskId: 'dbid_1',
          indexes: const [],
          destination: '/volume1/movies',
        ),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noRequiredParam,
          ),
        ),
      );
      expect(t.calls.length, before, reason: '守卫失败时不许发请求');
    });
  });
}
