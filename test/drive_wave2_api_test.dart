// Drive **wave2**（普通用户级功能）**接口层**离线测试。
//
// 只碰 `drive_api.dart` + DTO + 编排器，不 import 任何 widget/Office，避免与
// 并行批次耦合。
//
// 覆盖（全部按用户**真机取证**的契约逐字断言）：
//   * 配额 / 用量：`Info:quota` **v2**（v1 = 103）、无参、`quota:0` = 不限额；
//   * 访问事件上报：`Files:access` **v1**，参数是 `event_type` + `path`
//     （**不是 `file_id`**，官方值 `preview`）；
//   * 转 Office：`Files:convert_office` **v1**，`files` = `'["id:<file_id>"]'`
//     （**必须带 `id:` 前缀 + JSON 数组字符串**）+ `format`；
//   * 结果判定：只有轮询确认 `finished` 才算完成，否则一律"已提交"（不谎报）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_quota_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/drive/drive_wave2_providers.dart';
import 'package:synhub/src/features/drive/drive_wave2_text.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Tasks': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// 用户真机取证的 `Info:quota` v2 回包（逐字）。
Map<String, dynamic> _quotaReply() => {
  'share_list': [
    {
      'is_home': true,
      'name': 'homes',
      'quota': 0,
      'share_quota': 0,
      'share_used': 4871229.5,
      'support_per_share_quota': true,
      'used': 17307.96484375,
    },
  ],
};

Future<({FakeTransport t, DsmWebApi api})> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (t: t, api: api);
}

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
}) {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key]};
  };
  return t;
}

Map<String, dynamic> _callOf(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

void main() {
  group('① 配额 / 用量（Info:quota v2）', () {
    test('发 v2（v1 会 103）且无参', () async {
      final t = _transport(
        responses: {'SYNO.SynologyDrive.Info.quota': _quotaReply()},
      );
      final s = await _loggedIn(t);
      final api = DriveApi(s.api);
      final quota = await api.quota();

      final call = _callOf(t, 'quota');
      expect(call['api'], 'SYNO.SynologyDrive.Info');
      // 硬要求：**必须 v2**（v1 真机回 103）
      expect(call['version'], '2');
      // 无参：除 api/version/method/_sid 外没有业务参数
      final business = call.keys
          .where((k) => k != 'api' && k != 'version' && k != 'method')
          .where((k) => !k.startsWith('_'))
          .toList();
      expect(business, isEmpty);

      // 真机回包逐字解析
      expect(quota.shares, hasLength(1));
      final home = quota.home;
      expect(home, isNotNull);
      expect(home!.isHome, isTrue);
      expect(home.name, 'homes');
      expect(home.usedMib, closeTo(17307.96484375, 1e-9));
      expect(home.shareUsedMib, closeTo(4871229.5, 1e-9));
      expect(home.supportPerShareQuota, isTrue);
    });

    test('quota:0 → hasQuota=false（不限额），不是 0 字节容量', () async {
      final t = _transport(
        responses: {'SYNO.SynologyDrive.Info.quota': _quotaReply()},
      );
      final s = await _loggedIn(t);
      final quota = await DriveApi(s.api).quota();
      final home = quota.home!;
      expect(home.quotaMib, 0);
      expect(home.hasQuota, isFalse, reason: 'quota=0 表示不限额');
      expect(quota.hasAnyQuota, isFalse);
      // used 仍是真实用量
      expect(home.usedBytes, (17307.96484375 * 1024 * 1024).round());
    });

    test('设了配额 → hasQuota=true + 比例', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Info.quota': {
            'share_list': [
              {
                'is_home': true,
                'name': 'homes',
                'quota': 20480,
                'share_quota': 0,
                'share_used': 0,
                'support_per_share_quota': true,
                'used': 10240,
              },
            ],
          },
        },
      );
      final s = await _loggedIn(t);
      final home = (await DriveApi(s.api).quota()).home!;
      expect(home.hasQuota, isTrue);
      expect(home.quotaBytes, 20480 * 1024 * 1024);
      expect(home.ratio, closeTo(0.5, 1e-9));
    });
  });

  group('② 访问事件上报（Files:access v1）', () {
    test('参数是 event_type + path（不是 file_id），版本 v1', () async {
      final t = _transport(
        responses: {'SYNO.SynologyDrive.Files.access': const {}},
      );
      final s = await _loggedIn(t);
      await DriveApi(s.api).reportAccess(
        eventType: DriveApi.kAccessEventPreview,
        path: 'id:974457808523148038',
      );

      final call = _callOf(t, 'access');
      expect(call['api'], 'SYNO.SynologyDrive.Files');
      expect(call['version'], '1');
      // 官方核到的唯一值
      expect(call['event_type'], 'preview');
      // path = id:<file_id>
      expect(call['path'], 'id:974457808523148038');
      // **绝不能**只传 file_id（真机会 120 缺 event_type）
      expect(call.containsKey('file_id'), isFalse);
    });
  });

  group('③ 转成 Office 格式（Files:convert_office v1）', () {
    test('files 必须带 id: 前缀且是 JSON 数组字符串，version v1', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.convert_office': {
            'async_task_id': 'task-140',
          },
        },
      );
      final s = await _loggedIn(t);
      final taskId = await DriveApi(
        s.api,
      ).convertOffice(fileId: '974457808523148038');
      expect(taskId, 'task-140');

      final call = _callOf(t, 'convert_office');
      expect(call['api'], 'SYNO.SynologyDrive.Files');
      expect(call['version'], '1');
      expect(call['format'], 'docx');
      // 逐字形态
      expect(call['files'], '["id:974457808523148038"]');
      // 解出来也必须是带前缀的字符串数组
      final decoded = (call['files'] as String);
      expect(decoded.startsWith('["id:'), isTrue);
      expect(decoded.endsWith('"]'), isTrue);
    });
  });

  group('④ 转换结果判定（Tasks:get 轮询，绝不谎报成功）', () {
    Future<DriveConvertResult> runWith({
      required Map<String, Map<String, dynamic>> responses,
      Map<String, int> failures = const {},
      int maxPolls = 3,
    }) async {
      final t = _transport(responses: responses);
      t.failures.addAll(failures);
      final s = await _loggedIn(t);
      final runner = DriveConvertOfficeRunner(
        api: DriveApi(s.api),
        pollInterval: Duration.zero,
        maxPolls: maxPolls,
      );
      return runner.run(fileId: '974457808523148038');
    }

    test('convert ok + Tasks:get finished → finished', () async {
      final r = await runWith(
        responses: {
          'SYNO.SynologyDrive.Files.convert_office': {
            'async_task_id': 'task-140',
          },
          'SYNO.SynologyDrive.Tasks.get': {
            'task_id': 'task-140',
            'status': 'finished',
            'result': {'action': 'convert_office', 'task_id': 'task-140'},
          },
        },
      );
      expect(r.outcome, DriveConvertOutcome.finished);
    });

    test('convert ok + Tasks:get 一直 in_progress → pending（不是成功）', () async {
      final r = await runWith(
        responses: {
          'SYNO.SynologyDrive.Files.convert_office': {
            'async_task_id': 'task-140',
          },
          'SYNO.SynologyDrive.Tasks.get': {
            'task_id': 'task-140',
            'status': 'in_progress',
            'progress': 40,
          },
        },
      );
      expect(r.outcome, DriveConvertOutcome.pending);
    });

    test('convert ok + 轮询接口 103（未取证通道不可用）→ pending', () async {
      final r = await runWith(
        responses: {
          'SYNO.SynologyDrive.Files.convert_office': {
            'async_task_id': 'task-140',
          },
        },
        failures: {'SYNO.SynologyDrive.Tasks.get': 103},
      );
      expect(r.outcome, DriveConvertOutcome.pending);
    });

    test('convert ok + 任务报错 → failed', () async {
      final r = await runWith(
        responses: {
          'SYNO.SynologyDrive.Files.convert_office': {
            'async_task_id': 'task-140',
          },
          'SYNO.SynologyDrive.Tasks.get': {
            'task_id': 'task-140',
            'status': 'error',
            'errors': ['boom'],
          },
        },
      );
      expect(r.outcome, DriveConvertOutcome.failed);
    });

    test('convert 本身 105 → failed 且带原始错误（供门控）', () async {
      final r = await runWith(
        responses: const {},
        failures: {'SYNO.SynologyDrive.Files.convert_office': 105},
      );
      expect(r.outcome, DriveConvertOutcome.failed);
      expect(r.error, isA<DsmApiException>());
      expect((r.error! as DsmApiException).code, 105);
    });
  });

  group('⑤ 不限额文案（quota:0 不得显示成 0 B / 0 B）', () {
    test('不限额 → 只显示已使用，不含 0 B', () {
      const share = DriveQuotaShareDto(
        name: 'homes',
        isHome: true,
        quotaMib: 0,
        usedMib: 17307.96484375,
        shareQuotaMib: 0,
        shareUsedMib: 0,
        supportPerShareQuota: true,
      );
      final line = driveQuotaUsageLine(share, (b) => '$b B');
      expect(line.contains('0 B'), isFalse);
      expect(line.contains('已使用'), isTrue);
      // 断言"不限额"语义由 UI 层单独表达（页面 Key drive-quota-primary-unlimited）
      expect(share.hasQuota, isFalse, reason: 'quota:0 = 不限额，绝不能当作 0 容量');
    });

    test('设了配额 → 显示 used / total', () {
      const share = DriveQuotaShareDto(
        name: 'homes',
        isHome: true,
        quotaMib: 1024,
        usedMib: 512,
        shareQuotaMib: 0,
        shareUsedMib: 0,
        supportPerShareQuota: true,
      );
      final line = driveQuotaUsageLine(share, (b) => '$b B');
      expect(line.contains('中已使用'), isTrue);
      expect(line.contains('${512 * 1024 * 1024} B'), isTrue);
      expect(line.contains('${1024 * 1024 * 1024} B'), isTrue);
    });
  });
}
