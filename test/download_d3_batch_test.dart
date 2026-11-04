// 批次 D-3（⑥下载 C 组：新建任务）**离线接口层验证**。
//
// 覆盖台账 §4 C 组 15 行：
//   * C1  URL 下载 —— `Task/create` `{type:"url", url:[…]}`（DS2 单栈，见台账说明）；
//   * C2  FTP 账号/密码 —— `username`/`password` **URI 编码**后下发；
//   * C3  磁力链接 —— `canonizeUrl` 对 `magnet:` 的规范化（小写前缀修正）；
//   * C4/C5/C6 上传 `.torrent`/`.nzb`/`.txt` —— `Task/create` `{type:"file", file:[…]}`；
//   * C7  ed2k —— 与 URL 同一条 `create`（官方 QuickURL 走同一入口）；
//   * C8  批量 URL ≤50 —— 超过 `maxAddLimit` 以 **501 REACH_LIMIT** 拒绝、且**不发请求**；
//   * C9  多文件批量上限 —— 数据层一次一个 `file` 字段（`uploadFileField`）；
//   * C10 目标文件夹 —— `destination` 是 JSON 文本；
//   * C11 解压密码 —— `extract_password`；
//   * C12 限速/立即开始 —— `applyCreateOptions`（不立即开始 → `pause`；限速 → `Task.BT/get`+`set`）；
//   * C13 "选择要下载的文件" —— `create_list` 开关 + `list_id` 解析；
//   * C14 Captcha —— `Captcha/set` `{task_id, code}`；空参以 114 拒绝、不发请求；
//   * C15 从 BT 搜索结果建任务 —— **按用户指令不提供**（见台账 ➖ 登记）。
//
// ⚠️ 写操作只发到 FakeTransport，真实 NAS 调用 = 0。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
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
  'SYNO.DownloadStation2.Captcha': {
    'path': 'entry.cgi',
    'minVersion': 1,
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

void main() {
  group('D-3 C1/C2/C7 新建 URL / FTP / ed2k', () {
    test('C1：type=url、url 是 JSON 文本、create_list=false', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.create': {'list_id': ''},
        },
      );
      await ds.createUrlTask(urls: const ['https://example.com/a.iso']);
      final call = callOf(t, 'create');
      expect(call['api'], 'SYNO.DownloadStation2.Task');
      expect(call['type'], 'url');
      expect(call['url'], jsonEncode(const ['https://example.com/a.iso']));
      expect(call['create_list'], false);
    });

    test('C2：FTP 账号密码被 URI 编码（含 @ / 空格）', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.create': {'list_id': ''},
        },
      );
      await ds.createUrlTask(
        urls: const ['ftp://ftp.example.com/x.bin'],
        username: 'user@corp',
        password: 'p a ss',
      );
      final call = callOf(t, 'create');
      expect(call['username'], 'user%40corp');
      expect(call['password'], 'p%20a%20ss');
    });

    test('C7：ed2k 链接与 URL 同一条 create（QuickURL 官方入口）', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.create': {'list_id': ''},
        },
      );
      const ed2k =
          'ed2k://|file|a.iso|1024|0123456789ABCDEF0123456789ABCDEF|/';
      await ds.createUrlTask(urls: const [ed2k]);
      final call = callOf(t, 'create');
      expect(call['type'], 'url');
      expect(call['url'], jsonEncode(const [ed2k]));
    });
  });

  group('D-3 C3 磁力链接规范化', () {
    test('C3：magnet 前缀大小写被规范成小写，去空白', () {
      expect(DownloadStationApi.canonizeUrl('  MAGNET:?xt=urn:btih:ABC  '), 'magnet:?xt=urn:btih:ABC');
      expect(DownloadStationApi.canonizeUrl('magnet:?xt=urn:btih:ABC'), 'magnet:?xt=urn:btih:ABC');
      expect(DownloadStationApi.canonizeUrl('https://a/b'), 'https://a/b');
      expect(DownloadStationApi.canonizeUrl('   '), '');
    });
  });

  group('D-3 C4/C5/C6/C9 上传文件', () {
    test('C4/C5/C6：type=file、file 字段是 JSON 数组、extract_password 逐字', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.create': {'list_id': ''},
        },
      );
      await ds.createFileTask(
        filePath: '/tmp/a.torrent',
        fileName: 'a.torrent',
        destination: '/volume1/downloads',
        extractPassword: 'pw123',
      );
      final call = callOf(t, 'create');
      // 官方 multipart 线上形态是带引号的 `"file"`（`Ext.encode("file")`）
      expect(call['type'], jsonEncode('file'));
      expect(call['file'], jsonEncode(const [DownloadStationApi.uploadFileField]));
      expect(call['destination'], jsonEncode('/volume1/downloads'));
      expect(call['extract_password'], 'pw123');
    });

    test('C9：一次只声明一个 file 字段（多选由 UI 逐次提交）', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.create': {'list_id': ''},
        },
      );
      await ds.createFileTask(filePath: '/tmp/a.nzb', fileName: 'a.nzb');
      final sent = jsonDecode(callOf(t, 'create')['file'] as String) as List;
      expect(sent.length, 1);
    });
  });

  group('D-3 C8/C10/C11/C13 参数与 create_list', () {
    test('C8：超过上限（50）以 501 拒绝且零调用', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.create': {'list_id': ''},
        },
      );
      final before = t.calls.length;
      await expectLater(
        ds.createUrlTask(
          urls: [for (var i = 0; i < 51; i++) 'https://e.com/$i.iso'],
        ),
        throwsA(
          isA<DsmApiException>().having((e) => e.code, 'code', 501),
        ),
      );
      expect(t.calls.length, before, reason: '超限不许发请求');
      // 恰好 50 条可以发
      await ds.createUrlTask(
        urls: [for (var i = 0; i < 50; i++) 'https://e.com/$i.iso'],
      );
      expect(jsonDecode(callOf(t, 'create')['url'] as String).length, 50);
    });

    test('C8b：空/无效链接以 114 拒绝且零调用', () async {
      final (ds, t) = await boot();
      final before = t.calls.length;
      await expectLater(
        ds.createUrlTask(urls: const ['   ']),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noRequiredParam,
          ),
        ),
      );
      expect(t.calls.length, before);
    });

    test('C13：create_list=true 时回包 list_id 被解析出来', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.create': {'list_id': 'list_9'},
        },
      );
      final r = await ds.createUrlTask(
        urls: const ['https://e.com/a.torrent'],
        createList: true,
      );
      expect(callOf(t, 'create')['create_list'], true);
      expect(r.listId, 'list_9');
    });
  });

  group('D-3 C12 新建后置选项（立即开始 / 限速）', () {
    test('C12：不立即开始 → pause；限速 → Task.BT/get 再 set', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.BT': {
            'max_download_rate': 0,
            'max_upload_rate': 0,
          },
        },
      );
      final applied = await ds.applyCreateOptions(
        taskId: '31',
        startImmediately: false,
        maxDownloadRate: 1024,
      );
      expect(applied, isTrue);
      // 先暂停
      expect(callOf(t, 'pause')['id'], jsonEncode(const ['31']));
      // 读现有设置再写回（保留 upload 原值）
      expect(callOf(t, 'get')['task_id'], '31');
      final set = callOf(t, 'set');
      expect(set['api'], 'SYNO.DownloadStation2.Task.BT');
      expect(set['max_download_rate'], 1024);
      expect(set['max_upload_rate'], 0);
    });

    test('C12b：立即开始且不限速 → 零调用（没什么可改）', () async {
      final (ds, t) = await boot();
      final before = t.calls.length;
      final applied = await ds.applyCreateOptions(taskId: '31');
      expect(applied, isFalse);
      expect(t.calls.length, before);
    });
  });

  group('D-3 C14 Captcha', () {
    test('C14：set 带 {task_id, code}；空 code 以 114 拒绝且零调用', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Captcha.set': {'success': true},
        },
      );
      await ds.setCaptcha(taskId: '31', code: 'abcd');
      final call = callOf(t, 'set');
      expect(call['api'], 'SYNO.DownloadStation2.Captcha');
      expect(call['task_id'], '31');
      expect(call['code'], 'abcd');
      // 空白 code 被 trim 后视为缺失
      final before = t.calls.length;
      await expectLater(
        ds.setCaptcha(taskId: '31', code: '   '),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noRequiredParam,
          ),
        ),
      );
      expect(t.calls.length, before);
    });
  });
}
