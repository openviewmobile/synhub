// Download Station 缺口 wave1 的离线验证：A6 文件清单 / F8 缩略图 /
// F7 种子导出 / F9 自动解压设置。
//
// 事实来源（**以本机 `SYNO.API.Info` + 实调为准**，见
// `docs/download-api-live.md` 与包内官方前端 `ui/download.js`）：
//   * A6 `SYNO.DownloadStation2.Task.BT.File:list` v1–2，`{task_id,offset,limit}`，
//     root `items`、total `total`，字段 `index/name/size/size_downloaded/priority/wanted`；
//   * F8 `SYNO.DownloadStation2.Thumbnail:get` v2，参数 **`id`**；回包 `data`
//     是裸数组 `[{file_name, thumbnail_list:[{thumbnail_id}]}]`；图片走
//     `Thumbnail:download` + `thumbnail_id`；
//   * F7 `SYNO.DownloadStation2.Task.Source:download` v2（`allowDownload`）；
//   * F9 `SYNO.DownloadStation2.Settings.AutoExtraction:get|set` v1。
//
// ⚠️ 真机现状：NAS 上 **0 个真实下载任务** → A6/F7/F8 的**成功回包形态**无法
// 真机取证（`docs/download-api-live.md:56`）；这里只钉"请求拼对了、回包解对了、
// 取不到时回落不空白"。**不要把"离线绿"当成"真机已验证"**。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/dto/download_task_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/downloads/download_detail_page.dart';
import 'package:synhub/src/features/downloads/download_export.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';
import 'package:synhub/src/features/downloads/download_settings_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 透明 PNG（与 `test/drive_gaps_wave1_test.dart` 同一份）。
final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// 真机 DS2 的能力表形状（`path=entry.cgi`，版本区间来自来自 `.lib`/实调）。
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
  'SYNO.DownloadStation2.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Task.Source': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Settings.AutoExtraction': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// `Thumbnail.get` 的成功回包是**裸 JSON 数组**（`SYNO.API.Request` 的 `data`），
/// 而假传输的默认 `postBytes` 只会吐 `downloadBytes` —— 这里按 `method` 分流：
/// `get` 回 JSON 信封，`download` 交给基类（= `downloadBytes` 里那张真 PNG）。
class _ThumbTransport extends FakeTransport {
  _ThumbTransport(super.responses, super.apiTable);

  /// `get` 回的裸数组（默认一张缩略图）。
  List<Map<String, dynamic>> thumbData = [
    {
      'file_name': 'videos/cover.jpg',
      'thumbnail_list': [
        {'thumbnail_id': 'TH-1'},
      ],
    },
  ];

  /// 非空时 `get` 回 **错误信封**（模拟真机的 `1911 = 暂无缩略图`）。
  int? thumbErrorCode;

  @override
  Future<List<int>> postBytes(
    String path,
    Map<String, dynamic> params, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    String? module,
  }) async {
    if (params['api'] == 'SYNO.DownloadStation2.Thumbnail' &&
        params['method'] == 'get') {
      postDownloads.add(
        '$path?api=${params['api']}&method=get'
        '&version=${params['version']}&id=${params['id']}',
      );
      if (thumbErrorCode != null) {
        return utf8.encode(
          jsonEncode({
            'success': false,
            'error': {'code': thumbErrorCode},
          }),
        );
      }
      return utf8.encode(jsonEncode({'success': true, 'data': thumbData}));
    }
    return super.postBytes(
      path,
      params,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }
}

Future<(DownloadStationApi, FakeTransport)> boot({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, Map<String, dynamic>>? apiTable,
  FakeTransport Function(
    Map<String, Map<String, dynamic>> responses,
    Map<String, Map<String, dynamic>> table,
  )?
  transport,
}) async {
  final table = {...FakeTransport.table, ..._dsTable, ...?apiTable};
  final t = transport != null
      ? transport(responses, table)
      : FakeTransport(responses, table);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (DownloadStationApi(api), t);
}

Map<String, dynamic> _callOf(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

Map<String, dynamic> _file({
  int index = 0,
  String name = 'a.mkv',
  int size = 100,
  int downloaded = 50,
  String priority = 'normal',
  bool wanted = true,
}) => {
  'index': index,
  'name': name,
  'size': size,
  'size_downloaded': downloaded,
  'progress': 0,
  'priority': priority,
  'wanted': wanted,
};

Map<String, dynamic> _task({
  Object id = 1,
  String title = 'ubuntu.iso',
  String type = 'bt',
  int status = 2,
  int size = 4096,
  int downloaded = 1024,
}) => {
  'id': id,
  'title': title,
  'type': type,
  'status': status,
  'size': size,
  'username': 'demo_user',
  'additional': {
    'detail': {'destination': '/volume1/downloads'},
    'transfer': {'size_downloaded': downloaded, 'speed_download': 2048},
  },
};

/// 挂一个下载页面（可注入 `_ThumbTransport` 与落盘目录覆盖）。
Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  Map<String, Map<String, dynamic>>? apiTable,

  /// 从能力表里**移除**这些 API（模拟"这台 NAS 没注册"）。
  List<String> dropApis = const [],
  FakeTransport Function(
    Map<String, Map<String, dynamic>> responses,
    Map<String, Map<String, dynamic>> table,
  )?
  transport,
  void Function(FakeTransport t)? setup,
  Future<Directory> Function()? downloadDir,
  DsSourceSaver? saver,
  Future<void> Function(ProviderContainer c)? afterBuild,

  /// 详情页很高：默认给一个高视口，避免懒构建导致下方区块根本没建出来。
  Size viewSize = const Size(900, 2600),
}) async {
  tester.view.physicalSize = viewSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final table = {...FakeTransport.table, ..._dsTable, ...?apiTable}
    ..removeWhere((k, _) => dropApis.contains(k));
  final t = transport != null
      ? transport(responses, table)
      : FakeTransport(responses, table);
  setup?.call(t);
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  final c = ProviderContainer(
    overrides: [
      downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
      if (downloadDir != null)
        dsDownloadDirProvider.overrideWithValue(downloadDir),
      if (saver != null) dsSourceSaverProvider.overrideWithValue(saver),
    ],
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
  if (afterBuild != null) await afterBuild(c);
  return (t: t, c: c);
}

void main() {
  group('A6 任务文件清单（Task.BT.File/list）', () {
    test('list v2：task_id/offset/limit + root items + 字段解析', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.BT.File.list': {
            'items': [
              _file(index: 0, name: 'a.mkv', size: 100, downloaded: 50),
              _file(
                index: 1,
                name: 'b.txt',
                size: 10,
                downloaded: 10,
                priority: 'low',
                wanted: false,
              ),
            ],
            'total': 2,
          },
        },
      );
      final page = await ds.listFiles('9', offset: 25, limit: 25);
      final call = _callOf(t, 'list');
      expect(call['api'], 'SYNO.DownloadStation2.Task.BT.File');
      expect(call['version'], '2');
      expect(call['task_id'], '9');
      expect(call['offset'], 25);
      expect(call['limit'], 25);
      expect(page.total, 2);
      expect(page.items.first.name, 'a.mkv');
      expect(page.items.first.progressRatio, closeTo(0.5, 1e-9));
      expect(page.items[1].isSkipped, isTrue);
      expect(page.items[1].priority, 'low');
    });

    test('服务端只到 v1 时按 v1 发（版本协商）', () async {
      final (ds, t) = await boot(
        apiTable: const {
          'SYNO.DownloadStation2.Task.BT.File': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      await ds.listFiles('9');
      expect(_callOf(t, 'list')['version'], '1');
    });

    test('size=0 时 progressRatio 给 1（官方 calculateProgressRenderer）', () {
      expect(
        const DownloadFileDto(index: 0, name: 'x', size: 0).progressRatio,
        1,
      );
    });
  });

  group('F8 缩略图（Thumbnail/get + download）', () {
    test('get v2 参数是 id（不是 task_id），裸数组摊平成 thumbnail_id', () async {
      final (ds, t) = await boot(
        transport: (r, table) => _ThumbTransport(r, table),
      );
      final list = await ds.thumbnails('9');
      expect(
        t.postDownloads.single,
        contains(
          'api=SYNO.DownloadStation2.Thumbnail&method=get&version=2&id=9',
        ),
      );
      expect(list.single.fileName, 'videos/cover.jpg');
      expect(list.single.thumbnailId, 'TH-1');
    });

    test('download 直链带 thumbnail_id / method=download / v2', () async {
      final (ds, _) = await boot();
      final url = ds.thumbnailUrl('TH-1');
      expect(url, contains('api=SYNO.DownloadStation2.Thumbnail'));
      expect(url, contains('method=download'));
      expect(url, contains('version=2'));
      expect(url, contains('thumbnail_id=TH-1'));
    });

    test('回包为空数组 → 没有缩略图（调用方回落图标）', () async {
      final t0 = _ThumbTransport(const {}, {
        ...FakeTransport.table,
        ..._dsTable,
      })..thumbData = const [];
      final api = DsmWebApi(t0);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      expect(await DownloadStationApi(api).thumbnails('9'), isEmpty);
    });

    test('1911（暂无缩略图）连错误码一起还原，界面按中性回落', () async {
      final t0 = _ThumbTransport(const {}, {
        ...FakeTransport.table,
        ..._dsTable,
      })..thumbErrorCode = DownloadStationApi.errNoThumbnail;
      final api = DsmWebApi(t0);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      await expectLater(
        DownloadStationApi(api).thumbnails('9'),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 1911)),
      );
      // 兜底文案是**中性**的，不是"网络失败"。
      expect(
        describeDownloadError(DsmApiException(1911, method: 'Thumbnail.get')),
        '这个任务暂无缩略图',
      );
    });
  });

  group('F7 种子导出（Task.Source/download v2）', () {
    test('直链带 api/method=download/version=2/id，返回原始字节', () async {
      final (ds, t) = await boot();
      t.downloadBytes = utf8.encode('d8:announce4:udp:');
      final bytes = await ds.downloadSource('9');
      expect(t.downloads.single, contains('SYNO.DownloadStation2.Task.Source'));
      expect(t.downloads.single, contains('method=download'));
      expect(t.downloads.single, contains('version=2'));
      expect(t.downloads.single, contains('id=9'));
      expect(utf8.decode(bytes), 'd8:announce4:udp:');
    });

    test('文件名：标题 + .torrent；路径分隔符被净化', () {
      expect(dsTorrentFileName('ubuntu'), 'ubuntu.torrent');
      expect(dsTorrentFileName('a/b'), 'a_b.torrent');
      expect(dsTorrentFileName('x.torrent'), 'x.torrent');
      expect(dsTorrentFileName('  '), 'task.torrent');
    });

    test('非 BT 任务的 404+HTML → 不当成网络失败（中性文案）', () {
      expect(
        describeDownloadError(
          DsmTransportException('HTTP 404', statusCode: 404, uri: 'entry.cgi'),
        ),
        '这个任务没有可导出的源文件',
      );
    });
  });

  group('Task.BT.get 形状容忍（真机 paused/active 两种形状）', () {
    test('暂停态只剩 destination/extract_password/is_active_torrent 也能解析', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.BT.get': {
            'destination': '/volume1/dl',
            'extract_password': '',
            'is_active_torrent': false,
          },
        },
      );
      final s = await ds.getBtSettings('dbid_334');
      expect(_callOf(t, 'get')['task_id'], 'dbid_334');
      expect(s.isActiveTorrent, isFalse);
      // 缺失字段给默认值，不抛（真机实测 docs/download-api-live.md:109-112）
      expect(s.maxDownloadRate, 0);
      expect(s.maxPeers, 0);
      expect(s.priority, isEmpty);
    });
  });

  group('F9 自动解压设置（Settings.AutoExtraction get|set v1）', () {
    test('get v1 → enable_unzip 等字段（普通用户可读）', () async {
      final (ds, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': true,
            'unzip_location': 'current_folder',
            'create_subfolder': true,
            'delete_archive': false,
            'unzip_overwrite': false,
          },
        },
      );
      final s = await ds.autoExtraction();
      final call = _callOf(t, 'get');
      expect(call['api'], 'SYNO.DownloadStation2.Settings.AutoExtraction');
      expect(call['version'], '1');
      expect(s.enableUnzip, isTrue);
      expect(s.unzipLocation, 'current_folder');
      expect(s.createSubfolder, isTrue);
      expect(s.deleteArchive, isFalse);
    });

    test('set 只发脏字段 enable_unzip（写操作，版本 v1）', () async {
      final (ds, t) = await boot();
      await ds.setAutoExtraction(enableUnzip: true);
      final call = _callOf(t, 'set');
      expect(call['api'], 'SYNO.DownloadStation2.Settings.AutoExtraction');
      expect(call['method'], 'set');
      expect(call['version'], '1');
      expect(call['enable_unzip'], isTrue);
      // 没传的字段一个都不许下发（官方 getDirtyFieldValues）
      expect(call.containsKey('unzip_location'), isFalse);
      expect(call.containsKey('unzip_to_path'), isFalse);
      // admin-only 字段永不下发
      expect(call.containsKey('enable_unzip_service'), isFalse);
    });

    // ------------------------------------------------- ★ r410 · G-r408-01
    // 6 个可写字段**逐个单独发**：只许出现自己那一个（官方 getDirtyFieldValues）。
    // 这条是页面补全 6 控件的地基 —— 界面能发了，最底下这一层必须先钉住。
    test('set 逐字段：6 个可写字段各自单独调用只发自己', () async {
      final (ds, t) = await boot();

      Future<Map<String, dynamic>> one(Future<void> Function() f) async {
        final before = t.calls.length;
        await f();
        expect(t.calls.length, greaterThan(before), reason: '必须真的发了一次');
        return _callOf(t, 'set');
      }

      // ① bool ×4
      var call = await one(() => ds.setAutoExtraction(enableUnzip: true));
      expect(call['enable_unzip'], isTrue);
      call = await one(() => ds.setAutoExtraction(createSubfolder: true));
      expect(call['create_subfolder'], isTrue);
      call = await one(() => ds.setAutoExtraction(unzipOverwrite: true));
      expect(call['unzip_overwrite'], isTrue);
      call = await one(() => ds.setAutoExtraction(deleteArchive: true));
      expect(call['delete_archive'], isTrue);
      // ② 两个字符串
      // ★ DA65：位置是**布尔**（true = 用下载文件夹；false = 用指定文件夹）。
      call = await one(
        () => ds.setAutoExtraction(unzipLocationToCurrentFolder: false),
      );
      expect(call['unzip_location'], isFalse);
      call = await one(
        () => ds.setAutoExtraction(unzipLocationToCurrentFolder: true),
      );
      expect(call['unzip_location'], isTrue);
      // ★ 空串必须发 **JSON 空串**（裸空串 = 服务端当参数缺失，静默不回写）。
      call = await one(() => ds.setAutoExtraction(unzipToPath: ''));
      expect(call['unzip_to_path'], '""');
      call = await one(
        () => ds.setAutoExtraction(unzipToPath: '/volume1/downloads'),
      );
      expect(call['unzip_to_path'], '/volume1/downloads');

      // 上面每一次都只许带**自己**那一个业务字段。
      final fields = call.keys
          .where(
            (k) => k.startsWith('unzip_') || k.startsWith('create_') ||
                k.startsWith('delete_'),
          )
          .toList();
      expect(fields, ['unzip_to_path'], reason: '最后一次只发 unzip_to_path');
      // admin-only 字段任何一次都不许出现。
      for (final c in t.calls.where((c) => c['method'] == 'set')) {
        expect(c.containsKey('enable_unzip_service'), isFalse);
        expect(c.containsKey('passwords'), isFalse);
      }
    });

    // ------------------------------------------------- ★ r410 · DA65
    // 真机读数（逐字）：页面把 `unzip_location` 当**字符串**发
    //   ⇒ 服务端 `120 {"name":"unzip_location","reason":"type"}`；
    //   受控探针再逐个试 `"select_folder"` / `"specified_folder"` / `"current_folder"`
    //   —— **三个都回 `reason:"type"`** ⇒ 类型错；换成布尔就成功
    //   （`true`→回读 `current_folder`、`false`→回读 `select_folder`）。
    test('DA65 · unzip_location 只许发布尔，字符串枚举一律不许出网', () async {
      final (ds, t) = await boot();
      await ds.setAutoExtraction(unzipLocationToCurrentFolder: true);
      await ds.setAutoExtraction(unzipLocationToCurrentFolder: false);
      final sets = t.calls.where((c) => c['method'] == 'set').toList();
      expect(sets.length, 2);
      expect(sets[0]['unzip_location'], isTrue);
      expect(sets[1]['unzip_location'], isFalse);
      for (final c in sets) {
        expect(
          c['unzip_location'],
          isNot(isA<String>()),
          reason: '字符串会被服务端按类型拒（真机 120 type）',
        );
      }
    });
  });

  group('A6 页面：文件区（只读、有收尾态）', () {
    testWidgets('显示文件名/大小/优先级；全部加载完给"共 N 个文件"', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '9'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 9)],
          },
          'SYNO.DownloadStation2.Task.BT.get': {'is_active_torrent': true},
          'SYNO.DownloadStation2.Task.BT.File.list': {
            'items': [
              _file(index: 0, name: 'movie.mkv', size: 2048, priority: 'high'),
              _file(index: 1, name: 'notes.txt', size: 12, wanted: false),
            ],
            'total': 2,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('文件列表'), findsOneWidget);
      expect(find.text('movie.mkv'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('高'), findsOneWidget);
      expect(find.text('跳过'), findsOneWidget);
      expect(find.text('共 2 个文件'), findsOneWidget);
      expect(find.byKey(const Key('ds-files-more')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('分页：点「加载更多」续取 offset=25，到底后收尾', (tester) async {
      final boot = await _pump(
        tester,
        const DownloadDetailPage(taskId: '9'),
        setup: (t) => t.onCall = (p) {
          if (p['api'] == 'SYNO.DownloadStation2.Task.BT.File' &&
              p['method'] == 'list') {
            final offset = (p['offset'] as num?)?.toInt() ?? 0;
            if (offset == 0) {
              return {
                'items': [for (var i = 0; i < 25; i++) _file(index: i)],
                'total': 30,
              };
            }
            return {
              'items': [for (var i = 25; i < 30; i++) _file(index: i)],
              'total': 30,
            };
          }
          if (p['api'] == 'SYNO.DownloadStation2.Task' &&
              p['method'] == 'get') {
            return {
              'task': [_task(id: 9)],
            };
          }
          if (p['api'] == 'SYNO.DownloadStation2.Task.BT' &&
              p['method'] == 'get') {
            return {'is_active_torrent': true};
          }
          return null;
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('ds-files-more')), findsOneWidget);

      await tester.tap(find.byKey(const Key('ds-files-more')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(_callOf(boot.t, 'list')['offset'], 25);
      expect(find.text('共 30 个文件'), findsOneWidget);
      expect(find.byKey(const Key('ds-files-more')), findsNothing);
    });

    testWidgets('服务端回空页 → 不再有"加载更多"（不会无限转圈）', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '9'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 9)],
          },
          'SYNO.DownloadStation2.Task.BT.get': {'is_active_torrent': true},
          'SYNO.DownloadStation2.Task.BT.File.list': {'items': [], 'total': 0},
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('没有文件信息'), findsOneWidget);
      expect(find.byKey(const Key('ds-files-more')), findsNothing);
    });

    testWidgets('非 BT 任务不显示文件区', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '3'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 3, type: 'http', status: 5)],
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('文件列表'), findsNothing);
    });

    testWidgets('1913（暂停的 BT 任务，is_active=false）→ 中性提示，不是加载失败', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '9'),
        failures: {'SYNO.DownloadStation2.Task.BT.File.list': 1913},
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 9, status: 3)],
          },
          'SYNO.DownloadStation2.Task.BT.get': {
            'is_active_torrent': false,
            'destination': '/volume1/dl',
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('任务未激活或已完成，暂无文件列表'), findsOneWidget);
      expect(find.text('没有文件信息'), findsNothing);
      expect(find.textContaining('加载失败'), findsNothing);
    });

    testWidgets('1913（已完成的 BT 任务，is_active=false）→ 同样中性', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '9'),
        failures: {'SYNO.DownloadStation2.Task.BT.File.list': 1913},
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 9, status: 5)],
          },
          'SYNO.DownloadStation2.Task.BT.get': {
            'is_active_torrent': false,
            'destination': '/volume1/dl',
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('任务未激活或已完成，暂无文件列表'), findsOneWidget);
      expect(find.textContaining('加载失败'), findsNothing);
    });
  });

  group('F8 页面：缩略图有则显示、无则回落图标（不空白）', () {
    testWidgets('取到缩略图字节 → 渲染图片', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '9'),
        transport: (r, table) => _ThumbTransport(r, table),
        setup: (t) => t.downloadBytes = _png1x1,
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 9)],
          },
          'SYNO.DownloadStation2.Task.BT.get': {'is_active_torrent': true},
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('ds-thumb-9')), findsOneWidget);
    });

    testWidgets('没有缩略图（空数组）→ 回落到状态图标，不空白', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '9'),
        transport: (r, table) {
          final t = _ThumbTransport(r, table)..thumbData = const [];
          return t;
        },
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 9)],
          },
          'SYNO.DownloadStation2.Task.BT.get': {'is_active_torrent': true},
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('ds-thumb-9')), findsNothing);
      // 既有状态图标还在（下载中）
      expect(find.byIcon(Icons.downloading), findsWidgets);
    });

    testWidgets('任务列表行也给缩略图回落到图标', (tester) async {
      await _pump(
        tester,
        const DownloadPage(),
        transport: (r, table) => _ThumbTransport(r, table),
        setup: (t) => t.downloadBytes = _png1x1,
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task(id: 9)],
            'total': 1,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('ds-thumb-9')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('1911（暂无缩略图）→ 中性回落图标，不报错不空白', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '9'),
        transport: (r, table) {
          final t = _ThumbTransport(r, table)
            ..thumbErrorCode = 1911
            ..downloadBytes = _png1x1;
          return t;
        },
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 9)],
          },
          'SYNO.DownloadStation2.Task.BT.get': {'is_active_torrent': true},
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('ds-thumb-9')), findsNothing);
      expect(find.byIcon(Icons.downloading), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('F7 页面：导出 .torrent 走既有落盘通道', () {
    test(
      'saveTaskSource 真落盘：fileDownloadDirectory 通道 + 写入 .torrent 字节',
      () async {
        final dir = await Directory.systemTemp.createTemp('ds_torrent_');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });
        final (ds, t) = await boot();
        t.downloadBytes = utf8.encode('d4:infod4:name5:hello');
        final path = await saveTaskSource(
          api: ds,
          dir: () async => dir,
          taskId: '9',
          title: 'ubuntu',
        );
        expect(path, '${dir.path}/ubuntu.torrent');
        expect(await File(path).readAsString(), 'd4:infod4:name5:hello');
        expect(
          t.downloads.single,
          contains('SYNO.DownloadStation2.Task.Source'),
        );
      },
    );

    testWidgets('BT 任务点导出 → 调页面级 saver 并提示（不碰真实 IO）', (tester) async {
      final saves = <String>[];
      final boot = await _pump(
        tester,
        const DownloadDetailPage(taskId: '9'),
        saver: (taskId, title) async {
          saves.add('$taskId:$title');
          return '/tmp/${dsTorrentFileName(title)}';
        },
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 9, title: 'ubuntu')],
          },
          'SYNO.DownloadStation2.Task.BT.get': {'is_active_torrent': true},
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('ds-export-torrent')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(saves, ['9:ubuntu']);
      expect(find.text('已导出 ubuntu.torrent'), findsOneWidget);
      // 非 BT 任务不给导出入口
      expect(boot.t.downloads, isEmpty);
    });

    testWidgets('非 BT 任务没有导出按钮', (tester) async {
      await _pump(
        tester,
        const DownloadDetailPage(taskId: '3'),
        responses: {
          'SYNO.DownloadStation2.Task.get': {
            'task': [_task(id: 3, type: 'http', status: 5)],
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('ds-export-torrent')), findsNothing);
    });
  });

  group('F9 页面：设置页自动解压开关', () {
    testWidgets('开关按 get 预填；toggle 发 set enable_unzip=true（v1）', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        const DownloadSettingsPage(),
        responses: {
          'SYNO.DownloadStation2.Settings.AutoExtraction.get': {
            'enable_unzip': false,
            'unzip_location': 'current_folder',
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('自动解压'), findsWidgets);
      // ★ r407 就地订正：原先断言的是**裸服务端枚举** `解压位置：current_folder`
      //   —— 等于把 DA59 那个缺陷写成了期望值。
      //   ★ r410：位置改成官方 radio ×2（G-r408-01），断言取 radio 上的人话。
      expect(find.text('下载文件夹'), findsOneWidget);
      expect(find.textContaining('current_folder'), findsNothing);

      await tester.tap(find.byKey(const Key('ds-auto-extract')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final call = _callOf(boot.t, 'set');
      expect(call['api'], 'SYNO.DownloadStation2.Settings.AutoExtraction');
      expect(call['version'], '1');
      expect(call['enable_unzip'], isTrue);
      expect(find.text('自动解压设置已保存'), findsOneWidget);
    });

    testWidgets('能力表没有 AutoExtraction → 明确"不支持"，不给开关', (tester) async {
      await _pump(
        tester,
        const DownloadSettingsPage(),
        dropApis: const ['SYNO.DownloadStation2.Settings.AutoExtraction'],
      );
      expect(find.text('这台 NAS 的 Download Station 不支持自动解压设置'), findsOneWidget);
      expect(find.byKey(const Key('ds-auto-extract')), findsNothing);
    });

    testWidgets('下载页有设置入口', (tester) async {
      await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      expect(find.byKey(const Key('ds-settings')), findsOneWidget);
    });
  });
}
