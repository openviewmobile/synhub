// 文件模块「剩余能力批次」**界面层**离线测试（146 / 219 / 223 / 226）。
//
// 每一行都真的把页面/面板渲染一次，并断言"点了会发生什么"：
//   * 146 `showExtractSheet` 的分卷提示（第 1 卷 / 第 N 卷）；
//   * 219 `FileOfflinePage` 的容量提示（本批新增）；
//   * 223 `UsbDevicesPage` 的设备卡片 + 弹出**二次确认**；
//   * 226 `WebDavPage` 的连接 / 废弃提示 / 列目录 / 进入子目录 / 失败态。
//
// 全部走假传输（FakeTransport / _FakeWebDav），**不联网**；
// 223 的 eject 只在假 transport 上"发"出去，**绝无真机写操作**。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_download_resume.dart';
import 'package:synhub/src/features/files/file_offline_page.dart';
import 'package:synhub/src/features/files/file_offline_pin.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_sheets.dart';
import 'package:synhub/src/features/files/usb_devices_page.dart';
import 'package:synhub/src/features/files/webdav_client.dart';
import 'package:synhub/src/features/files/webdav_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _usbTable = {
  // ★ `requestFormat: "JSON"` 是**活服务器**（`SYNO.API.Info`）会给的字段，
  //   官方《DS file》按它决定参数值编码（见 DA24）。
  'SYNO.Core.ExternalDevice.Storage.USB': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
    'requestFormat': 'JSON',
  },
};

Future<FileStationApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FileStationApi(api);
}

class _FakeWebDav implements WebDavTransport {
  _FakeWebDav(this._handler);

  final WebDavResponse Function(WebDavRequest req) _handler;
  final List<WebDavRequest> requests = [];

  @override
  Future<WebDavResponse> send(WebDavRequest request) async {
    requests.add(request);
    return _handler(request);
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget page, {
  List<Object?> overrides = const [],
}) async {
  final container = ProviderContainer(overrides: overrides.cast());
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

const String _listing = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/~DSFile/queryWebdav.cgi/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/~DSFile/queryWebdav.cgi/home/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/~DSFile/queryWebdav.cgi/readme.txt</D:href>
    <D:propstat><D:prop><D:resourcetype/>
      <D:getcontentlength>12</D:getcontentlength></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';

const String _homeListing = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/~DSFile/queryWebdav.cgi/home/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/~DSFile/queryWebdav.cgi/home/inside.txt</D:href>
    <D:propstat><D:prop><D:resourcetype/>
      <D:getcontentlength>3</D:getcontentlength></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';

void main() {
  // ------------------------------------------------------------ 146

  group('146 解压面板的分卷提示（页面层）', () {
    Future<void> open(WidgetTester tester, String name) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showExtractSheet(context, fileName: name),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('第 2 卷 → 明确让用户改选第 1 卷', (tester) async {
      await open(tester, 'movie.part2.rar');
      expect(find.byKey(const Key('fs-extract-volume-later')), findsOneWidget);
      expect(find.byKey(const Key('fs-extract-volume-first')), findsNothing);
      expect(find.textContaining('movie.part1.rar'), findsOneWidget);
    });

    testWidgets('第 1 卷 → 提示服务端会自己读其余分卷', (tester) async {
      await open(tester, 'movie.part1.rar');
      expect(find.byKey(const Key('fs-extract-volume-first')), findsOneWidget);
      expect(find.byKey(const Key('fs-extract-volume-later')), findsNothing);
    });

    testWidgets('非分卷包 → 没有任何分卷提示', (tester) async {
      await open(tester, 'report.pdf');
      expect(find.byKey(const Key('fs-extract-volume-first')), findsNothing);
      expect(find.byKey(const Key('fs-extract-volume-later')), findsNothing);
    });
  });

  // ------------------------------------------------------------ 219

  group('219 离线文件页（页面层）', () {
    OfflinePinEntry entry(String path, int size, {String local = ''}) =>
        OfflinePinEntry(
          path: path,
          name: path.split('/').last,
          size: size,
          pinnedAt: 1789739500,
          localPath: local,
        );

    testWidgets('空清单 → 空态', (tester) async {
      await _pump(
        tester,
        const FileOfflinePage(),
        overrides: [
          offlinePinStoreProvider.overrideWithValue(MemoryOfflinePinStore()),
        ],
      );
      expect(find.byKey(const Key('file-offline-empty')), findsOneWidget);
      expect(find.byKey(const Key('file-offline-capacity')), findsNothing);
    });

    testWidgets('有清单 → 列表 + 容量提示 + 逐条移出', (tester) async {
      final store = MemoryOfflinePinStore([
        entry('/home/a.bin', 1024),
        entry('/home/b.bin', 2048),
      ]);
      final c = await _pump(
        tester,
        const FileOfflinePage(),
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      // preload 是 microtask，多泵一次
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('file-offline-list')), findsOneWidget);
      expect(find.byKey(const Key('file-offline-capacity')), findsOneWidget);
      // 合计 3072 字节（登记值之和）
      expect(find.textContaining('3'), findsWidgets, reason: '容量行应给出合计数字');

      await tester.tap(find.byKey(const Key('file-offline-unpin-/home/a.bin')));
      await tester.pump();
      expect(c.read(offlinePinProvider).map((e) => e.path), ['/home/b.bin']);
      expect(store.items, hasLength(1));
    });

    testWidgets('全部移出 → 回空态', (tester) async {
      final store = MemoryOfflinePinStore([entry('/home/a.bin', 10)]);
      await _pump(
        tester,
        const FileOfflinePage(),
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('file-offline-clear')));
      await tester.pump();
      expect(find.byKey(const Key('file-offline-empty')), findsOneWidget);
      expect(store.items, isEmpty);
    });

    // ★ 302：登记 ≠ 已缓存。这两条钉的就是"页面上能不能看出区别、
    // 以及未缓存时有没有**重试入口**"（修好之前恒为未缓存且没有出路）。
    testWidgets('未缓存 → 标「未缓存」+ 有「缓存到本机」重试入口', (tester) async {
      final store = MemoryOfflinePinStore([entry('/home/a.bin', 1024)]);
      await _pump(
        tester,
        const FileOfflinePage(),
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('未缓存'), findsOneWidget);
      expect(
        find.byKey(const Key('file-offline-cache-/home/a.bin')),
        findsOneWidget,
        reason: '未缓存必须给一条出路，否则是死状态',
      );
    });

    testWidgets('已缓存 → 标「已缓存到本机」且**没有**重试入口', (tester) async {
      final store = MemoryOfflinePinStore([
        entry('/home/a.bin', 1024, local: '/tmp/offline_cache/deadbeef_a.bin'),
      ]);
      await _pump(
        tester,
        const FileOfflinePage(),
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('已缓存到本机'), findsOneWidget);
      expect(
        find.byKey(const Key('file-offline-cache-/home/a.bin')),
        findsNothing,
      );
    });

    testWidgets('点「缓存到本机」→ 真下到本机 + 回填 localPath + 落盘', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('r302_ui_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      // 假取数器：真写 11 字节（**不联网**）
      final cacher = OfflineCacher(
        documentsDir: () async => tmp,
        fetcher:
            ({required path, required name, required directory, onProgress}) async {
              final f = File(
                '${directory.path}/${OfflineCacher.fileNameFor(path: path, name: name)}',
              );
              await f.writeAsBytes(List<int>.filled(11, 0x41), flush: true);
              return FileDownloadOutcome(localPath: f.path, totalBytes: 11);
            },
      );
      final store = MemoryOfflinePinStore([entry('/home/a.bin', 11)]);
      final c = await _pump(
        tester,
        const FileOfflinePage(),
        overrides: [
          offlinePinStoreProvider.overrideWithValue(store),
          offlineCacherProvider.overrideWithValue(cacher),
        ],
      );
      await tester.pump(const Duration(milliseconds: 50));

      // 真文件 I/O 必须放进 `runAsync`：假异步时钟下 `writeAsBytes` 永远不会完成。
      //
      // ★ 轮询到"回填完成"而不是死等固定毫秒：固定 80ms 在全量并发负载下
      // 会偶发假红（本轮实测：单跑 3/3 绿、全量 1 红）。轮询**不放宽断言**
      // —— 仍然必须真的回填，只是不再对机器负载敏感。
      await tester.runAsync(() async {
        await tester.tap(
          find.byKey(const Key('file-offline-cache-/home/a.bin')),
        );
        for (var i = 0;
            i < 100 && !c.read(offlinePinProvider).single.hasLocalCopy;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();

      final after = c.read(offlinePinProvider).single;
      expect(after.hasLocalCopy, isTrue, reason: '缓存成功后必须回填 localPath');
      expect(File(after.localPath).lengthSync(), 11, reason: '字节要真的在本机');
      expect(
        store.items.single.localPath,
        after.localPath,
        reason: '回填要落盘，重启后不能丢',
      );
      expect(
        find.byKey(const Key('file-offline-cache-/home/a.bin')),
        findsNothing,
        reason: '缓存成功入口就该消失',
      );
    });
  });

  // ------------------------------------------------------------ 223

  group('223 外接设备页（页面层）', () {
    testWidgets('空列表 → 空态', (tester) async {
      final t = FakeTransport({}, {...FakeTransport.table, ..._usbTable});
      t.failures['SYNO.Core.ExternalDevice.Storage.USB.list'] = 404;
      final fs = await _api(t);
      await _pump(
        tester,
        const UsbDevicesPage(),
        overrides: [fileApiProvider.overrideWithValue(fs)],
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fs-usb-empty')), findsOneWidget);
    });

    testWidgets('★ DA25：服务端回 404 ⇒ 文案不许再叫用户"插 U 盘"', (tester) async {
      // r395 原始读数：同一分钟里 `usbshare1` → `real_path=/volumeUSB1/usbshare`
      // （盘真的挂载着、Files 能列内容），这个 `list` 仍回 404 ⇒
      // ① 空态说"把 U 盘插上"就是在撒谎；② 也不许反过来说"NAS 上没有 U 盘"。
      final t = FakeTransport({}, {...FakeTransport.table, ..._usbTable});
      t.failures['SYNO.Core.ExternalDevice.Storage.USB.list'] = 404;
      final fs = await _api(t);
      await _pump(
        tester,
        const UsbDevicesPage(),
        overrides: [fileApiProvider.overrideWithValue(fs)],
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('服务端没有返回外接设备'), findsOneWidget);
      expect(find.textContaining('这不代表 NAS 上没有 U 盘'), findsOneWidget);
      expect(find.textContaining('把 U 盘或移动硬盘插到 NAS'), findsNothing);
    });

    testWidgets('★ DA25 反向：服务端回「空列表」（不是 404）⇒ 保持原文案', (tester) async {
      final t = FakeTransport({}, {...FakeTransport.table, ..._usbTable});
      t.responses['SYNO.Core.ExternalDevice.Storage.USB.list'] = {
        'devices': [],
      };
      final fs = await _api(t);
      await _pump(
        tester,
        const UsbDevicesPage(),
        overrides: [fileApiProvider.overrideWithValue(fs)],
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('把 U 盘或移动硬盘插到 NAS'), findsOneWidget);
      expect(find.textContaining('服务端没有返回外接设备'), findsNothing);
    });

    testWidgets('有设备 → 卡片 + 分区；弹出要二次确认，取消不调用 eject', (tester) async {
      final t = FakeTransport({}, {...FakeTransport.table, ..._usbTable});
      t.responses['SYNO.Core.ExternalDevice.Storage.USB.list'] = {
        'devices': [
          {
            'dev_id': 'usb1',
            'dev_title': 'SanDisk',
            'partitions': [
              {
                'name_id': 'p1',
                'share_name': 'usbshare1',
                'filesystem': 'vfat',
                'status': 'normal',
                'total_size_mb': '30436',
                'used_size_mb': '124',
              },
            ],
          },
        ],
      };
      t.responses['SYNO.Core.ExternalDevice.Storage.USB.eject'] = const {};
      final fs = await _api(t);
      await _pump(
        tester,
        const UsbDevicesPage(),
        overrides: [fileApiProvider.overrideWithValue(fs)],
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fs-usb-device-usb1')), findsOneWidget);
      expect(find.text('SanDisk'), findsOneWidget);
      expect(find.textContaining('usbshare1'), findsWidgets);

      await tester.tap(find.byKey(const Key('fs-usb-eject-usb1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fs-usb-eject-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('fs-usb-eject-cancel')));
      await tester.pumpAndSettle();
      expect(t.calls.any((c) => c['method'] == 'eject'), isFalse);

      await tester.tap(find.byKey(const Key('fs-usb-eject-usb1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fs-usb-eject-confirm')));
      await tester.pumpAndSettle();
      // 弹出成功后页面会 invalidate 重新 `list`，所以 eject 未必是最后一次调用
      final ejects = t.calls.where((c) => c['method'] == 'eject').toList();
      expect(ejects, hasLength(1));
      expect(ejects.single['dev_id'], 'usb1');
    });
  });

  // ---------------------------------------------- DA24 参数值编码（官方规则）

  group('DA24 `requestFormat` 决定 `additional` 怎么编（官方《DS file》规则）', () {
    test('requestFormat=JSON ⇒ 必须 JSON 数组（与版本无关）', () async {
      final t = FakeTransport({}, {...FakeTransport.table, ..._usbTable});
      t.responses['SYNO.Core.ExternalDevice.Storage.USB.list'] = {
        'devices': [],
      };
      final fs = await _api(t);
      await fs.listUsbDevices();
      final call = t.calls.firstWhere(
        (c) =>
            c['api'] == 'SYNO.Core.ExternalDevice.Storage.USB' &&
            c['method'] == 'list',
      );
      expect(
        call['additional'],
        '["partitions"]',
        reason: '改前这里是 v1 逗号（`partitions`）—— 官方客户端对 JSON 格式的 API '
            '一律走 getJsonEncodeValue()',
      );
    });

    test('反向：服务端没声明 requestFormat ⇒ 仍旧 v1 逗号（不硬编码 JSON）', () async {
      const plainTable = {
        'SYNO.Core.ExternalDevice.Storage.USB': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      };
      final t = FakeTransport({}, {...FakeTransport.table, ...plainTable});
      t.responses['SYNO.Core.ExternalDevice.Storage.USB.list'] = {
        'devices': [],
      };
      final fs = await _api(t);
      await fs.listUsbDevices();
      final call = t.calls.firstWhere(
        (c) =>
            c['api'] == 'SYNO.Core.ExternalDevice.Storage.USB' &&
            c['method'] == 'list',
      );
      expect(call['additional'], 'partitions');
    });

    test('反向：判据挂在"服务端声明"上，不是挂在某个 API 名上', () async {
      // 同一个 `SYNO.FileStation.List`，只改表里的 requestFormat：
      // 表单格式 ⇒ 逗号；声明 JSON ⇒ JSON 数组。
      Future<Object?> additionalFor(Map<String, Map<String, dynamic>> entry) async {
        final t = FakeTransport({}, {...FakeTransport.table, ...entry});
        t.responses['SYNO.FileStation.List.list'] = {'files': []};
        final fs = await _api(t);
        await fs.listFolder(folderPath: '/x');
        return t.calls
            .firstWhere(
              (c) =>
                  c['api'] == 'SYNO.FileStation.List' && c['method'] == 'list',
            )['additional'];
      }

      const formEntry = {
        'SYNO.FileStation.List': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      };
      const jsonEntry = {
        'SYNO.FileStation.List': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
          'requestFormat': 'JSON',
        },
      };
      final form = '${await additionalFor(formEntry)}';
      final json = '${await additionalFor(jsonEntry)}';
      expect(form.contains('['), isFalse, reason: '表单格式 ⇒ 逗号分隔');
      expect(json.startsWith('['), isTrue, reason: '声明 JSON ⇒ JSON 数组');
    });
  });

  // ------------------------------------------------------------ 226

  group('226 WebDAV 页（页面层）', () {
    const defaults = WebDavTarget(
      host: 'nas.example.com',
      port: 5001,
      username: 'demo_user',
    );

    _FakeWebDav okTransport() => _FakeWebDav((req) {
      if (req.method == 'OPTIONS') {
        return const WebDavResponse(
          statusCode: 200,
          headers: {
            'dav': '1, 2',
            'allow': 'OPTIONS, PROPFIND, GET',
            'server': 'nginx',
          },
        );
      }
      if (req.headers['action'] == 'version') {
        return const WebDavResponse(
          statusCode: 200,
          body: '{"success":true,"majorVersion":"7"}',
        );
      }
      return WebDavResponse(
        statusCode: 207,
        body: req.url.contains('/home/') ? _homeListing : _listing,
      );
    });

    Future<void> connect(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('fs-webdav-connect')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('未连接：预填为空；缺主机时明确报错且不发请求', (tester) async {
      final fake = okTransport();
      await _pump(
        tester,
        const WebDavPage(),
        overrides: [webDavTransportProvider.overrideWithValue(fake)],
      );
      expect(find.byKey(const Key('fs-webdav-page')), findsOneWidget);
      expect(find.byKey(const Key('fs-webdav-readonly')), findsOneWidget);
      await connect(tester);
      expect(find.byKey(const Key('fs-webdav-error')), findsOneWidget);
      expect(fake.requests, isEmpty);
    });

    testWidgets('连上 DSM 7 → 显示废弃提示 + 能力 + 列出目录', (tester) async {
      final fake = okTransport();
      await _pump(
        tester,
        const WebDavPage(),
        overrides: [
          webDavTransportProvider.overrideWithValue(fake),
          webDavTargetDefaultsProvider.overrideWithValue(defaults),
        ],
      );
      expect(find.text('nas.example.com'), findsOneWidget);

      await connect(tester);
      expect(find.byKey(const Key('fs-webdav-deprecated')), findsOneWidget);
      expect(find.byKey(const Key('fs-webdav-capability')), findsOneWidget);
      expect(find.byKey(const Key('fs-webdav-list')), findsOneWidget);
      expect(find.byKey(const Key('fs-webdav-entry-/home/')), findsOneWidget);
      expect(
        find.byKey(const Key('fs-webdav-entry-/readme.txt')),
        findsOneWidget,
      );
      // 只读了三个动词，且没有发送任何写动词
      expect(fake.requests.map((r) => r.method), [
        'OPTIONS',
        'GET',
        'PROPFIND',
      ]);
    });

    testWidgets('点目录进入子目录（第二次 PROPFIND 打到新路径）', (tester) async {
      final fake = okTransport();
      await _pump(
        tester,
        const WebDavPage(),
        overrides: [
          webDavTransportProvider.overrideWithValue(fake),
          webDavTargetDefaultsProvider.overrideWithValue(defaults),
        ],
      );
      await connect(tester);
      await tester.tap(find.byKey(const Key('fs-webdav-entry-/home/')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const Key('fs-webdav-entry-/home/inside.txt')),
        findsOneWidget,
      );
      final propfinds = fake.requests
          .where((r) => r.method == 'PROPFIND')
          .toList();
      expect(propfinds, hasLength(2));
      expect(
        propfinds.last.url.endsWith('/~DSFile/queryWebdav.cgi/home/'),
        isTrue,
      );
    });

    testWidgets('服务端 403 → 出错提示，不假装列到了目录', (tester) async {
      final fake = _FakeWebDav((_) => const WebDavResponse(statusCode: 403));
      await _pump(
        tester,
        const WebDavPage(),
        overrides: [
          webDavTransportProvider.overrideWithValue(fake),
          webDavTargetDefaultsProvider.overrideWithValue(defaults),
        ],
      );
      await connect(tester);
      expect(find.byKey(const Key('fs-webdav-error')), findsOneWidget);
      expect(find.textContaining('403'), findsOneWidget);
      expect(find.byKey(const Key('fs-webdav-list')), findsNothing);
    });
  });
}
