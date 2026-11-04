// Download Station 接口层离线验证（阶段二 A 第一块）。
//
// 事实来源：`docs/stage2-audio-download-api.md` §3.3–§3.5（api/method/版本/参数
// 逐字对齐 NAS 上 DownloadStation 4.1.2-5012 包内的官方 Web 前端）。
// 这里只验"客户端把请求拼对了、把回包解对了、把错误码翻对了"，不打真机。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/dto/download_task_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 真实 `SYNO.API.Info` 里 DS2 的条目形状（`path=entry.cgi`，各 API 版本区间
/// 来自 SPK 内的 `.lib`，见 docs §3.1）。
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

Future<(DownloadStationApi, FakeTransport)> boot({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, Map<String, dynamic>>? apiTable,

  /// true = 能力表里**没有**任何 DS2 API（模拟"这台 NAS 没装套件"）。
  bool noDs = false,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    if (!noDs) ..._dsTable,
    ...?apiTable,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (DownloadStationApi(api), t);
}

Map<String, dynamic> callOf(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

void main() {
  group('能力探测', () {
    test('能力表里有 DS2 Task → installed=true；没有 → installed=false', () async {
      final (ds, _) = await boot();
      expect(ds.installed, isTrue);

      final (missing, _) = await boot(noDs: true);
      expect(missing.installed, isFalse);
    });

    test('版本协商按方法收敛（Task v2，Statistic/Location v1）', () async {
      final (ds, _) = await boot(
        apiTable: const {
          'SYNO.DownloadStation2.Task': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      final list = await ds.listTasks();
      expect(list.items, isEmpty);
    });
  });

  group('任务列表', () {
    test('list：root 是 task/total，参数逐字对齐官方 getLoadParams', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [
              {
                'id': 31,
                'title': 'ubuntu.iso',
                'type': 'bt',
                'status': 2,
                'size': 4096,
                'status_extra': '',
                'username': 'demo_user',
                'additional': {
                  'detail': {
                    'destination': '/volume1/downloads',
                    'hash': 'ABC123',
                    'connected_peers': 3,
                    'total_peers': 9,
                    'started_time': 1700000000,
                  },
                  'transfer': {
                    'size_downloaded': 1024,
                    'speed_download': 2048,
                    'speed_upload': 512,
                  },
                },
              },
            ],
            'total': 7,
          },
        },
      );
      final page = await ds.listTasks(offset: 0, limit: 25);
      final call = callOf(t, 'list');
      expect(call['api'], 'SYNO.DownloadStation2.Task');
      expect(call['version'], '2');
      expect(call['offset'], 0);
      expect(call['limit'], 25);
      // 复杂参数是 JSON 文本（不是重复字段）
      expect(call['additional'], '["detail","transfer"]');
      // 官方默认排除 eMule
      expect(call['type'], '["emule"]');
      expect(call['type_inverse'], true);
      expect(call.containsKey('status'), isFalse);

      expect(page.total, 7);
      expect(page.items.single.title, 'ubuntu.iso');
      expect(page.items.single.type, 'bt');
      expect(page.items.single.isBt, isTrue);
      expect(page.items.single.progress, closeTo(0.25, 0.0001));
      expect(page.items.single.etaSeconds, 2); // (4096-1024)/2048
      expect(page.items.single.detail.destination, '/volume1/downloads');
      expect(page.items.single.detail.totalPeers, 9);
      expect(page.items.single.transfer.speedDownload, 2048);
      expect(page.hasMore, isTrue);
    });

    test('分类过滤：错误 = 101..134，已完成 = 7/8/5，下载中 = 官方五态+等待', () async {
      final (ds, t) = await boot();
      await ds.listTasks(category: DownloadTaskCategory.error);
      final err = callOf(t, 'list')['status'] as String;
      expect(err, contains('101'));
      expect(err, contains('134'));
      expect(err, isNot(contains('"5"')));

      await ds.listTasks(category: DownloadTaskCategory.finished);
      expect(callOf(t, 'list')['status'], '[7,8,5]');

      await ds.listTasks(category: DownloadTaskCategory.downloading);
      final down = callOf(t, 'list')['status'] as String;
      for (final v in [1, 2, 4, 6, 11, 12, 13, 14]) {
        expect(down, contains('$v'), reason: '下载中应含状态 $v');
      }
    });

    test('排序与关键字：sort_by/order/keyword 进请求', () async {
      final (ds, t) = await boot();
      await ds.listTasks(
        sortBy: 'filename',
        descending: true,
        keyword: ' ubuntu ',
      );
      final call = callOf(t, 'list');
      expect(call['sort_by'], 'filename');
      expect(call['order'], 'desc');
      expect(call['keyword'], 'ubuntu');
      // eMule 恒排除（官方默认）
      expect(call['type'], '["emule"]');
      expect(call['type_inverse'], true);
    });

    test('分页：第二页带 offset', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 60},
        },
      );
      await ds.listTasks(offset: 25, limit: 25);
      expect(callOf(t, 'list')['offset'], 25);
    });
  });

  group('任务详情 / 统计 / 默认目录', () {
    test('get：id 是 JSON 数组，additional=detail', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [
              {'id': 5, 'title': 'a', 'type': 'http', 'status': 5, 'size': 10},
            ],
          },
        },
      );
      final row = await ds.getTask('5');
      final call = callOf(t, 'get');
      expect(call['id'], '["5"]');
      expect(call['additional'], '["detail"]');
      expect(row!.status, DsTaskStatus.finished);
    });

    test('statistic：download_rate/upload_rate', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.Statistic.get': {
            'download_rate': 1024,
            'upload_rate': 512,
          },
        },
      );
      final s = await ds.statistic();
      expect(callOf(t, 'get')['version'], '1');
      expect(s.downloadRate, 1024);
      expect(s.uploadRate, 512);
    });

    test('Settings.Location.get → default_destination（normal）', () async {
      final (ds, _) = await boot(
        responses: {
          'SYNO.DownloadStation2.Settings.Location.get': {
            'default_destination': '/volume1/downloads',
          },
        },
      );
      expect(await ds.defaultDestination(), '/volume1/downloads');
    });
  });

  group('建任务', () {
    test('URL/磁力：type=url、url 为 JSON 数组、destination 编码、create_list', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.create': {'list_id': 88},
        },
      );
      final r = await ds.createUrlTask(
        urls: const [
          'HTTP://example.com/a.iso',
          'magnet:?xt=urn:btih:ABC',
          'thunder://QUFodHRwOi8v',
        ],
        destination: '/volume1/dl',
        extractPassword: 'pw',
        createList: true,
      );
      final call = callOf(t, 'create');
      expect(call['version'], '2');
      expect(call['type'], 'url'); // 官方 addQuickURL 的形态（不带引号）
      expect(
        call['url'],
        '["http://example.com/a.iso","magnet:?xt=urn:btih:ABC",'
        '"thunder://QUFodHRwOi8v"]',
      );
      expect(call['destination'], '"/volume1/dl"');
      expect(call['extract_password'], 'pw');
      expect(call['create_list'], true);
      expect(r.listId, '88');
    });

    test('U2 兼容写法：可切成带引号的 "url"（官方表单路径的 Ext.encode 形态）', () async {
      final (ds, t) = await boot();
      await ds.createUrlTask(
        urls: const ['http://a'],
        shape: DsCreateValueShape.jsonQuoted,
      );
      expect(callOf(t, 'create')['type'], '"url"');
    });

    test('无效链接直接拒（不再发请求）', () async {
      final (ds, t) = await boot();
      await expectLater(
        ds.createUrlTask(urls: const ['not a link']),
        throwsA(isA<DsmApiException>()),
      );
      expect(t.calls.any((c) => c['method'] == 'create'), isFalse);
    });

    test('超过 50 个链接直接拒', () async {
      final (ds, _) = await boot();
      await expectLater(
        ds.createUrlTask(urls: List.generate(51, (i) => 'http://a/$i')),
        throwsA(isA<DsmApiException>()),
      );
    });

    // ---------------------------------------------------------------- DA60
    group('DA60 · destination 是必填项（真机 120 的根因）', () {
      test('不给 destination ⇒ 自动补服务端默认目录（不再整条失败）', () async {
        final (ds, t) = await boot(
          responses: {
            'SYNO.DownloadStation2.Settings.Location.get': {
              'default_destination': 'home/Download',
            },
            'SYNO.DownloadStation2.Task.create': {
              'task_id': ['dbid_353'],
            },
          },
        );
        await ds.createUrlTask(
          urls: const ['ed2k://|file|a.bin|1048576|0123456789abcdef|/'],
        );
        final call = callOf(t, 'create');
        // 服务端点名要的字段，**必须发**，且形态 = 官方 Ext.encode 的 JSON 串
        expect(call['destination'], '"home/Download"');
        expect(call['type'], 'url');
      });

      test('调用方显式给了 destination ⇒ 不再多问一次默认目录', () async {
        final (ds, t) = await boot(
          responses: {
            'SYNO.DownloadStation2.Task.create': {'task_id': ['x']},
          },
        );
        await ds.createUrlTask(
          urls: const ['magnet:?xt=urn:btih:ABC'],
          destination: '/volume1/dl',
        );
        expect(callOf(t, 'create')['destination'], '"/volume1/dl"');
        expect(
          t.calls.any(
            (c) =>
                c['api'] == 'SYNO.DownloadStation2.Settings.Location' ||
                c['method'] == 'Settings.Location.get',
          ),
          isFalse,
        );
      });

      test('默认目录取不到 ⇒ 照旧不传，不许把创建本身弄崩', () async {
        final (ds, t) = await boot(
          responses: {
            'SYNO.DownloadStation2.Task.create': {'task_id': ['x']},
          },
        );
        // FakeTransport 对 `Settings.Location.get` 没登记夹具 ⇒ 空 data ⇒ 空串
        await ds.createUrlTask(urls: const ['http://a']);
        expect(callOf(t, 'create').containsKey('destination'), isFalse);
      });

      test('无效链接仍然不发任何请求（校验先于补默认目录）', () async {
        final (ds, t) = await boot();
        await expectLater(
          ds.createUrlTask(urls: const ['not a link']),
          throwsA(isA<DsmApiException>()),
        );
        expect(t.calls.any((c) => c['method'] == 'create'), isFalse);
        expect(
          t.calls.any((c) => c['method'] == 'get' && c['api'].toString().contains('Location')),
          isFalse,
        );
      });
    });

    // ---------------------------------------------------------------- DA61
    group('DA61 · 服务端点名的参数要透传给用户', () {
      test('raw 是整包 {success,error:{code,errors}} ⇒ 取出 name', () {
        expect(
          errorFieldName({
            'success': false,
            'error': {
              'code': 120,
              'errors': {'name': 'destination', 'reason': 'required'},
            },
          }),
          'destination',
        );
      });

      test('raw 是摊平的 {code,errors} ⇒ 取出 name', () {
        expect(
          errorFieldName({
            'code': 120,
            'errors': {'name': 'destination', 'reason': 'required'},
          }),
          'destination',
        );
      });

      test('errors 是数组也能取', () {
        expect(
          errorFieldName({
            'errors': [
              {'name': 'url', 'reason': 'invalid'},
            ],
          }),
          'url',
        );
      });

      test('没有 errors ⇒ null（不猜）', () {
        expect(errorFieldName(null), isNull);
        expect(errorFieldName({'code': 120}), isNull);
        expect(errorFieldName({'errors': 'oops'}), isNull);
      });

      test('120 的文案带上参数名（机器标识原样透传）', () {
        final e = DsmApiException(
          DsmErrorCode.requestParameterInvalid,
          method: 'SYNO.DownloadStation2.Task.create',
          raw: {
            'error': {
              'code': 120,
              'errors': {'name': 'destination', 'reason': 'required'},
            },
          },
        );
        final text = describeDownloadError(e);
        expect(text.contains('(destination)'), isTrue);
      });

      test('120 但没有参数名 ⇒ 文案与从前一字不差（不回归）', () {
        final e = DsmApiException(
          DsmErrorCode.requestParameterInvalid,
          method: 'SYNO.DownloadStation2.Task.create',
        );
        final text = describeDownloadError(e);
        expect(text.contains('(destination)'), isFalse);
        expect(
          text,
          DsmErrorCode.describe(
            DsmErrorCode.requestParameterInvalid,
            method: 'SYNO.DownloadStation2.Task.create',
          ),
        );
      });
    });

    test(
      '种子上传：端点 entry.cgi/SYNO.DownloadStation2.Task + file/torrent 形态',
      () async {
        final (ds, t) = await boot(
          responses: {
            'SYNO.DownloadStation2.Task.create': {'list_id': 12},
          },
        );
        final r = await ds.createFileTask(
          filePath: '/tmp/a.torrent',
          fileName: 'a.torrent',
          destination: '/volume1/dl',
        );
        final call = callOf(t, 'create');
        expect(call['api'], 'SYNO.DownloadStation2.Task');
        expect(call['version'], '2');
        // 官方表单：type = Ext.encode("file") → 带引号；file = ["torrent"]
        expect(call['type'], '"file"');
        expect(call['file'], '["torrent"]');
        expect(call['destination'], '"/volume1/dl"');
        expect(call['create_list'], 'false');
        // multipart 文件块的字段名是官方 FILEFILEDNAME = torrent
        expect(call['file_field'], 'torrent');
        expect(call['file_name'], 'a.torrent');
        expect(r.listId, '12');
      },
    );

    test('上传端点路径：uploadPath = entry.cgi/SYNO.DownloadStation2.Task', () async {
      final (ds, _) = await boot();
      expect(
        ds.uploadPath(DownloadStationApi.apiTask),
        'entry.cgi/SYNO.DownloadStation2.Task',
      );
    });
  });

  group('暂停 / 继续 / 删除', () {
    test('pause/resume：id JSON 数组', () async {
      final (ds, t) = await boot();
      await ds.pauseTasks(const ['1', '2']);
      await ds.resumeTasks(const ['3']);
      expect(callOf(t, 'pause')['id'], '["1","2"]');
      expect(callOf(t, 'resume')['id'], '["3"]');
    });

    test('delete：官方传 force_complete=false', () async {
      final (ds, t) = await boot();
      await ds.deleteTasks(const ['7']);
      final call = callOf(t, 'delete');
      expect(call['id'], '["7"]');
      expect(call['force_complete'], false);
    });
  });

  group('单任务 BT 限速（普通用户可改）', () {
    test('get：task_id + 解析限速字段', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.BT.get': {
            'is_active_torrent': true,
            'max_upload_rate': 100,
            'max_download_rate': 200,
            'seeding_ratio': 150,
            'seeding_interval': 30,
            'max_peers': 50,
          },
        },
      );
      final s = await ds.getBtSettings('9');
      expect(callOf(t, 'get')['task_id'], '9');
      expect(s.maxUploadRate, 100);
      expect(s.maxDownloadRate, 200);
      expect(s.seedingRatio, 150);
      expect(s.maxPeers, 50);
    });

    test('set：字段逐字对齐官方 _getBTSetFieldValues；含 priority；0 = 不限', () async {
      final (ds, t) = await boot();
      await ds.setBtSettings(
        '9',
        const DownloadBtSettings(
          maxUploadRate: 0,
          maxDownloadRate: 1024,
          seedingRatio: 200,
          seedingInterval: 60,
          maxPeers: 80,
          priority: 'high',
        ),
      );
      final call = callOf(t, 'set');
      expect(call['api'], 'SYNO.DownloadStation2.Task.BT');
      expect(call['version'], '2');
      expect(call['task_id'], '["9"]');
      expect(call['max_upload_rate'], 0);
      expect(call['max_download_rate'], 1024);
      expect(call['seeding_ratio'], 200);
      expect(call['seeding_interval'], 60);
      expect(call['max_peers'], 80);
      // 官方 BT 属性表单的 priority combobox → Task.BT.set
      expect(call['priority'], 'high');
    });

    test('priority 为空时不下发（官方 allowBlank，不脏不带）', () async {
      final (ds, t) = await boot();
      await ds.setBtSettings('9', const DownloadBtSettings(maxPeers: 5));
      expect(callOf(t, 'set').containsKey('priority'), isFalse);
    });
  });

  group('错误码 → 可读文案 / 大类', () {
    test('102 → 套件未安装，且归类为 notInstalled', () {
      final e = DsmApiException(102, method: 'SYNO.DownloadStation2.Task.list');
      expect(describeDownloadError(e), '这台 NAS 没有安装 Download Station');
      expect(downloadFailureKind(e), DsFailureKind.notInstalled);
    });

    test('160/105 → 无权限', () {
      for (final code in [160, 105, 524]) {
        final e = DsmApiException(
          code,
          method: 'SYNO.DownloadStation2.Task.list',
        );
        expect(describeDownloadError(e), '这个账号没有使用 Download Station 的权限');
        expect(downloadFailureKind(e), DsFailureKind.noPrivilege);
      }
    });

    test('网络失败 → 网络文案（与"未安装"区分开）', () {
      final e = DsmTransportException('socket closed');
      expect(describeDownloadError(e), '网络连接失败，请检查网络后重试');
      expect(downloadFailureKind(e), DsFailureKind.network);
    });

    test('业务码：406 无默认目录 / 502 JSON 解析 / 404 任务不存在 / 537 删文件失败', () {
      String msg(int code) =>
          describeDownloadError(DsmApiException(code, method: 'x'));
      expect(msg(406), contains('默认下载目录'));
      expect(msg(502), contains('无法解析请求数据'));
      expect(msg(404), '任务不存在（可能已被删除）');
      expect(msg(537), contains('删除文件失败'));
      expect(msg(405), '操作失败');
      expect(msg(9999), contains('9999'));
    });

    test('★★ r371（DA18）：120 是业务码 ⇒ 走通用参数通道，不是"压缩包已损坏"', () {
      final s = describeDownloadError(DsmApiException(120, method: 'x'));
      expect(
        s,
        DsmErrorCode.messagesText()[DsmErrorCode.requestParameterInvalid],
        reason: '★ 120 = 请求参数无效（与 RSS 那条通道同判据）',
      );
      expect(
        s.contains('压缩'),
        isFalse,
        reason: '★★ 缺陷原文：把报文参数错误说成"压缩包已损坏"',
      );
      // 反向：状态表里的**真**状态码照旧（证明不是把整张表废了）
      expect(
        describeDownloadError(DsmApiException(118, method: 'x')),
        contains('解压失败'),
      );
      expect(
        describeDownloadError(DsmApiException(123, method: 'x')),
        contains('种子文件无效'),
      );
    });

    test('会话过期单列一类', () {
      for (final code in [106, 119]) {
        final e = DsmApiException(code, method: 'x');
        expect(describeDownloadError(e), '登录已过期，请重新登录');
        expect(downloadFailureKind(e), DsFailureKind.sessionExpired);
      }
    });
  });

  group('URL 规范化（官方 Utils.isValidUrls / isValidDownloadUrls）', () {
    test('认得的 scheme 保留原大小写，前缀大小写规范化', () {
      expect(
        DownloadStationApi.canonizeUrl('HTTP://Example.com/A'),
        'http://Example.com/A',
      );
      expect(DownloadStationApi.canonizeUrl('MAGNET:?xt=1'), 'magnet:?xt=1');
      expect(DownloadStationApi.canonizeUrl('Thunder://abc'), 'thunder://abc');
      expect(DownloadStationApi.canonizeUrl('  ftp://a/b  '), 'ftp://a/b');
    });

    test('ed2k:// 与 file:/// 按官方判定放行（P0-1）', () {
      // 官方 Utils.java:224（TASKS_TYPE_EMULE）与 :340（isValidDownloadUrls）
      // 都认 `ed2k://`；通用列表还认 `file:///`。
      expect(
        DownloadStationApi.canonizeUrl('ED2K://|file|x|1|abc|/'),
        'ed2k://|file|x|1|abc|/',
      );
      expect(
        DownloadStationApi.canonizeUrl('ed2k://|file|a.mkv|2|ff|/'),
        'ed2k://|file|a.mkv|2|ff|/',
      );
      expect(
        DownloadStationApi.canonizeUrl('file:///volume1/a.iso'),
        'file:///volume1/a.iso',
      );
    });

    test('仍拒绝真正无效的输入；磁力判定只看 magnet:?', () {
      expect(DownloadStationApi.canonizeUrl('not a link'), isEmpty);
      expect(DownloadStationApi.canonizeUrl(''), isEmpty);
      expect(DownloadStationApi.canonizeUrl('ed2kxt=1'), isEmpty);
      expect(DownloadStationApi.isMagnet('magnet:?xt=1'), isTrue);
      expect(DownloadStationApi.isMagnet('MAGNET:?xt=1'), isTrue);
      expect(DownloadStationApi.isMagnet('http://a'), isFalse);
    });
  });

  group('全局暂停/恢复 + 条件删除（v2）', () {
    test('pauseAll/resumeAll 发 *_condition + type/type_inverse', () async {
      final (ds, t) = await boot();
      await ds.pauseAll();
      await ds.resumeAll();
      final pause = callOf(t, 'pause_condition');
      expect(pause['api'], 'SYNO.DownloadStation2.Task');
      expect(pause['version'], '2');
      expect(pause['type'], '["emule"]');
      expect(pause['type_inverse'], true);
      final resume = callOf(t, 'resume_condition');
      expect(resume['type'], '["emule"]');
      expect(resume['type_inverse'], true);
    });

    test('清除已完成 = delete_condition status:[5]；删除错误 = 101..134', () async {
      final (ds, t) = await boot();
      await ds.deleteCondition(statuses: const [DsTaskStatus.finished]);
      final clear = callOf(t, 'delete_condition');
      expect(clear['status'], '[5]');
      expect(clear['type_inverse'], true);

      await ds.deleteCondition(statuses: DsTaskStatus.errorGroup);
      final err = callOf(t, 'delete_condition')['status'] as String;
      expect(err, contains('101'));
      expect(err, contains('134'));
      expect(err, isNot(contains('"5"')));
    });

    test('forceComplete 走 Task.delete + force_complete=true', () async {
      final (ds, t) = await boot();
      await ds.deleteTasks(const ['7'], forceComplete: true);
      final call = callOf(t, 'delete');
      expect(call['id'], '["7"]');
      expect(call['force_complete'], true);
    });
  });

  group('Tracker / Peer 只读列表（v2）', () {
    test('listTrackers：task_id/offset/limit，root items', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.BT.Tracker.list': {
            'items': [
              {
                'url': 'udp://tracker.example:1337',
                'status': 3,
                'update': '2024-01-01',
                'seeds': 12,
                'peers': 34,
              },
            ],
            'total': 1,
          },
        },
      );
      final page = await ds.listTrackers('9');
      final call = callOf(t, 'list');
      expect(call['api'], 'SYNO.DownloadStation2.Task.BT.Tracker');
      expect(call['version'], '2');
      expect(call['task_id'], '9');
      expect(page.total, 1);
      expect(page.items.single.url, 'udp://tracker.example:1337');
      expect(page.items.single.seeds, 12);
      expect(page.items.single.peers, 34);
    });

    test('listPeers：解析 ip/client/progress/速率', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.BT.Peer.list': {
            'items': [
              {
                'ip': '1.2.3.4',
                'client': 'qBittorrent',
                'progress': 0.5,
                'speed_upload': 100,
                'speed_download': 2048,
              },
            ],
            'total': 1,
          },
        },
      );
      final page = await ds.listPeers('9');
      expect(callOf(t, 'list')['api'], 'SYNO.DownloadStation2.Task.BT.Peer');
      expect(page.items.single.ip, '1.2.3.4');
      expect(page.items.single.client, 'qBittorrent');
      expect(page.items.single.progress, 0.5);
      expect(page.items.single.speedDownload, 2048);
    });
  });

  group('选文件流程（create_list → list_id 被消费）', () {
    test('getCreateList 读 root files；download 发 selected 并回 task_id', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.List.get': {
            'files': [
              {'index': 0, 'name': 'a.mkv', 'size': 100, 'enable': true},
              {'index': 1, 'name': 'b.txt', 'size': 10, 'enable': true},
            ],
            'total': 2,
          },
          'SYNO.DownloadStation2.Task.List.Polling.download': {'task_id': '77'},
        },
      );
      final list = await ds.getCreateList('88');
      final get = callOf(t, 'get');
      expect(get['api'], 'SYNO.DownloadStation2.Task.List');
      expect(get['list_id'], '88');
      expect(list.files.length, 2);
      expect(list.files.first.enable, isTrue);

      final taskId = await ds.downloadCreateList(
        listId: '88',
        destination: '/volume1/dl',
        selected: const [0],
      );
      final dl = callOf(t, 'download');
      expect(dl['list_id'], '88');
      expect(dl['selected'], '[0]');
      expect(dl['destination'], '"/volume1/dl"');
      expect(taskId, '77');
    });

    test('放弃选择时 Task.List.delete 清掉临时清单', () async {
      final (ds, t) = await boot();
      await ds.deleteCreateList('88');
      final call = callOf(t, 'delete');
      expect(call['api'], 'SYNO.DownloadStation2.Task.List');
      expect(call['list_id'], '88');
    });
  });

  group('DTO 派生量', () {
    test('错误态 = status >= 101；完成/做种归入已完成', () {
      DownloadTaskDto task(int status) =>
          DownloadTaskDto(id: '1', title: 't', type: 'bt', status: status);
      expect(task(101).isError, isTrue);
      expect(task(134).isError, isTrue);
      expect(task(100).isError, isFalse);
      expect(task(5).isFinished, isTrue);
      expect(task(8).isFinished, isTrue);
      expect(task(3).isPaused, isTrue);
      expect(task(2).isPaused, isFalse);
    });

    test('进度/ETA：size 为 0 不给 NaN，速度为 0 不给 ETA', () {
      const zero = DownloadTaskDto(id: '1', title: 't', type: 'bt', status: 2);
      expect(zero.progress, 0);
      expect(zero.etaSeconds, isNull);
    });

    test('字节/速率格式化', () {
      expect(dsHumanBytes(0), '0 B');
      expect(dsHumanBytes(512), '512 B');
      expect(dsHumanBytes(2048), '2.0 KB');
      expect(dsHumanRate(0), '0 KB/s');
      expect(dsHumanRate(2048), '2 KB/s');
      expect(dsHumanRate(3 * 1024 * 1024), '3.0 MB/s');
    });
  });
}
