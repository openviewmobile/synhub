// 文件模块「剩余能力批次」**接口层**离线测试（146 / 219 / 223 / 226）。
//
// 每个功能都覆盖：
//   * 146 分卷识别 —— 纯函数（`archive_volumes.dart`）；
//   * 219 离线 Pin —— 本地清单 + 容量汇总（`file_offline_pin.dart`）；
//   * 223 USB     —— `FileStationApi.listUsbDevices` / `ejectUsbDevice` 的
//                    协议形状 + 404 语义 + DTO 解析；
//   * 226 WebDAV  —— 自研协议层（`webdav_client.dart`）：URL/编码/Basic 认证/
//                    PROPFIND 解析/OPTIONS/version/错误码，**全程不联网**。
//
// 协议取证的**一手证据**写在对应实现的注释里（DS file 反编译 smali +
// FileStation `conf/resource` 的 `allow_other_apis` + 只读真机探针）。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/archive_volumes.dart';
import 'package:synhub/src/features/files/file_offline_pin.dart';
import 'package:synhub/src/features/files/webdav_client.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _usbTable = {
  'SYNO.Core.ExternalDevice.Storage.USB': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

FakeTransport _transport() =>
    FakeTransport({}, {...FakeTransport.table, ..._usbTable});

Future<FileStationApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FileStationApi(api);
}

/// 记录请求 + 回放预设响应的假 WebDAV 传输（**不联网**）。
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

const String _multiStatus = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/~DSFile/queryWebdav.cgi/home/</D:href>
    <D:propstat>
      <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/~DSFile/queryWebdav.cgi/home/photo.jpg</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype/>
        <D:getcontentlength>2048</D:getcontentlength>
        <D:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</D:getlastmodified>
        <D:getcontenttype>image/jpeg</D:getcontenttype>
        <D:getetag>"abc"</D:getetag>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
    <D:propstat>
      <D:prop><D:creationdate/></D:prop>
      <D:status>HTTP/1.1 404 Not Found</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/~DSFile/queryWebdav.cgi/home/%E4%B8%AD%E6%96%87.txt</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype/>
        <D:getcontentlength>7</D:getcontentlength>
        <D:getlastmodified>2026-09-22T11:05:40Z</D:getlastmodified>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>''';

void main() {
  // ------------------------------------------------------------ 146 多卷

  group('146 分卷压缩包识别（接口层，纯函数）', () {
    test('7-Zip 数字分卷 .001：第 2 卷要提示改选第 1 卷', () {
      final v = detectArchiveVolume('backup.7z.001')!;
      expect(v.kind, ArchiveVolumeKind.numeric);
      expect(v.index, 1);
      expect(v.isFirst, isTrue);
      expect(v.firstVolumeName, 'backup.7z.001');

      final later = detectArchiveVolume('backup.7z.002')!;
      expect(later.index, 2);
      expect(later.isFirst, isFalse);
      expect(later.firstVolumeName, 'backup.7z.001');
      expect(needsVolumeHint('backup.7z.002'), isTrue);
      expect(isFirstVolume('backup.7z.001'), isTrue);
    });

    test('老式 RAR：.rar 是第 1 卷、.r00 是第 2 卷', () {
      final rar = detectArchiveVolume('old.rar');
      expect(rar, isNull, reason: '.rar 本身不是"分卷名"，普通文件走原逻辑');

      final r00 = detectArchiveVolume('old.r00')!;
      expect(r00.kind, ArchiveVolumeKind.rarOld);
      expect(r00.index, 2);
      expect(r00.firstVolumeName, 'old.rar');
    });

    test('ZIP 分卷 .z01：kind=zip，第 1 卷是 .z01', () {
      final z = detectArchiveVolume('pics.z01')!;
      expect(z.kind, ArchiveVolumeKind.zip);
      expect(z.index, 1);
      expect(z.firstVolumeName, 'pics.z01');
      expect(needsVolumeHint('pics.z02'), isTrue);
    });

    test('带路径/空串不误判；不像分卷的普通文件回 null', () {
      expect(detectArchiveVolume(''), isNull);
      expect(detectArchiveVolume('/home/a.part1.rar'), isNull);
      expect(detectArchiveVolume('report.pdf'), isNull);
      expect(detectArchiveVolume('a.001'), isNotNull);
    });
  });

  // ------------------------------------------------------------ 219 离线

  group('219 离线文件（接口层，纯本地）', () {
    OfflinePinEntry entry(String path, int size) => OfflinePinEntry(
      path: path,
      name: path.split('/').last,
      size: size,
      pinnedAt: 1,
    );

    test('容量汇总：只累加已知大小，未知大小单独计数', () {
      final u = offlinePinUsage([
        entry('/home/a.bin', 100),
        entry('/home/b.bin', 250),
        entry('/home/c.bin', 0),
      ]);
      expect(u.totalBytes, 350);
      expect(u.knownCount, 2);
      expect(u.unknownCount, 1);
      expect(u.hasUnknown, isTrue);
    });

    test('空清单 / 全部未知 → total 0 且不崩', () {
      expect(offlinePinUsage(const []).totalBytes, 0);
      expect(offlinePinUsage(const []).hasUnknown, isFalse);
      final allUnknown = offlinePinUsage([entry('/home/a', 0)]);
      expect(allUnknown.totalBytes, 0);
      expect(allUnknown.knownCount, 0);
      expect(allUnknown.unknownCount, 1);
    });

    test('JSON 往返：字段名对齐官方 Pin（path/name/size/local_path）', () {
      final e = OfflinePinEntry(
        path: '/home/a.txt',
        name: 'a.txt',
        size: 9,
        pinnedAt: 42,
        localPath: '/tmp/a.txt',
      );
      final back = OfflinePinEntry.fromJson(
        jsonDecode(jsonEncode(e.toJson())),
      )!;
      expect(back.path, '/home/a.txt');
      expect(back.size, 9);
      expect(back.pinnedAt, 42);
      expect(back.hasLocalCopy, isTrue);
    });

    test('取消登记后清单与本地存储同时清空', () async {
      final store = MemoryOfflinePinStore([entry('/home/a', 1)]);
      final c = ProviderContainer(
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(offlinePinProvider.notifier);
      await n.preload();
      expect(c.read(offlinePinnedPathsProvider), {'/home/a'});
      await n.unpin('/home/a');
      expect(c.read(offlinePinnedPathsProvider), isEmpty);
      expect(store.items, isEmpty);
    });

    // ★ 302：缓存完成后回填 `localPath` —— 这一步修好之前**从没人调用**
    // （`localPath` 全仓没有生产者）⇒ 清单恒"未缓存"、SAF 索引恒空。
    test('★302 回填 localPath：清单落盘 + 同步 SAF 索引（两处都要带上本地副本）', () async {
      final store = MemoryOfflinePinStore([entry('/home/a', 11)]);
      final written = <List<OfflinePinEntry>>[];
      final merged = <int>[];
      final c = ProviderContainer(
        overrides: [
          offlinePinStoreProvider.overrideWithValue(store),
          safIndexSinkProvider.overrideWithValue(
            (pins) async => written.add(List.of(pins)),
          ),
          safMergedIndexSinkProvider.overrideWithValue(
            (index) async => merged.add(index.entries.length),
          ),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(offlinePinProvider.notifier);
      await n.preload();

      await n.setLocalPath('/home/a', '/tmp/offline_cache/deadbeef_a');

      expect(c.read(offlinePinProvider).single.hasLocalCopy, isTrue);
      expect(store.items.single.localPath, '/tmp/offline_cache/deadbeef_a');
      expect(
        written.last.single.hasLocalCopy,
        isTrue,
        reason: '落盘的 SAF 索引那一份也要带上本地副本，否则系统「文件」里还是没有',
      );
      expect(merged, isNotEmpty, reason: '合并索引也该被同步一次');
    });
  });

  // ------------------------------------------------------------ 223 USB

  group('223 USB 外接设备（接口层）', () {
    test(
      'list：api/method/version + additional=partitions，DTO 解析字符串数字',
      () async {
        final t = _transport();
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
        final fs = await _api(t);
        final r = await fs.listUsbDevices();
        final call = t.calls.last;
        expect(call['api'], 'SYNO.Core.ExternalDevice.Storage.USB');
        expect(call['method'], 'list');
        expect(call['version'], '1');
        expect(r.devices.single.partitions.single.totalSizeMb, 30436);
      },
    );

    test('404 ⇒ 空列表 + notFound=true；105 ⇒ 原样抛（不伪装成"没有设备"）', () async {
      final t404 = _transport();
      t404.failures['SYNO.Core.ExternalDevice.Storage.USB.list'] = 404;
      final fs404 = await _api(t404);
      final r = await fs404.listUsbDevices();
      expect(r.notFound, isTrue);
      expect(r.devices, isEmpty);

      final t105 = _transport();
      t105.failures['SYNO.Core.ExternalDevice.Storage.USB.list'] = 105;
      final fs105 = await _api(t105);
      await expectLater(
        fs105.listUsbDevices(),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 105)),
      );
    });

    test('eject 是唯一写入口：dev_id 原样回传（用例中只发假请求，绝不真调）', () async {
      final t = _transport();
      t.responses['SYNO.Core.ExternalDevice.Storage.USB.eject'] = const {};
      final fs = await _api(t);
      await fs.ejectUsbDevice('usb7');
      final call = t.calls.last;
      expect(call['method'], 'eject');
      expect(call['dev_id'], 'usb7');
    });
  });

  // ------------------------------------------------------------ 226 WebDAV

  group('226 WebDAV 协议层（接口层，不联网）', () {
    const target = WebDavTarget(
      host: 'nas.example.com',
      port: 5001,
      username: 'demo_user',
      password: 'secret',
    );

    test('入口 URL / Basic 认证 / 路径编码都对齐官方 DS file', () {
      expect(
        target.baseUrl,
        'https://nas.example.com:5001/~DSFile/queryWebdav.cgi',
      );
      expect(kWebDavQueryPath, '/~DSFile/queryWebdav.cgi');
      expect(kWebDavUserAgent, 'DSfile');
      // "Basic " + base64("demo_user:secret")
      expect(
        target.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('demo_user:secret'))}',
      );
      // 官方 getRequestUrl：保留 `/`、空格 %20、`+` %2B、中文百分号编码
      expect(
        target.urlFor('/home/a b+c/中文.txt'),
        'https://nas.example.com:5001/~DSFile/queryWebdav.cgi'
        '/home/a%20b%2Bc/%E4%B8%AD%E6%96%87.txt',
      );
      // 标准 WebDAV 根（queryPath='/'）不能拼出 `//`
      const root = WebDavTarget(host: 'h', port: 5006, queryPath: '/');
      expect(root.urlFor('/home/a'), 'https://h:5006/home/a');
      expect(root.baseUrl, 'https://h:5006/');
    });

    test('encode/decode 与官方 WebdavUtil 同口径', () {
      expect(encodeWebDavPath(''), '/');
      expect(encodeWebDavPath('rel'), '/rel');
      expect(encodeWebDavPath('//a'), '//a');
      expect(encodeWebDavPath('/x/y z'), '/x/y%20z');
      expect(decodeWebDavPath('%E4%B8%AD'), '中');
      // 官方 decodeURL：先把 `+` 变成 `%2B` 再 decode ⇒ 字面 `+` 保持 `+`
      expect(decodeWebDavPath('a+b'), 'a+b');
    });

    test('multistatus 解析：collection/size/date/etag + 跳过 404 propstat', () {
      final entries = parseWebDavMultiStatus(
        _multiStatus,
        stripPrefix: kWebDavQueryPath,
      );
      expect(entries, hasLength(3));

      expect(entries[0].path, '/home/');
      expect(entries[0].isCollection, isTrue);

      final photo = entries[1];
      expect(photo.path, '/home/photo.jpg');
      expect(photo.name, 'photo.jpg');
      expect(photo.isCollection, isFalse);
      expect(photo.size, 2048);
      expect(photo.contentType, 'image/jpeg');
      expect(photo.etag, '"abc"');
      // RFC 1123（官方 formats[1]）
      expect(photo.lastModified, DateTime.utc(2015, 10, 21, 7, 28));

      // 百分号编码的中文名要解码回可读文本；ISO8601 也要认
      expect(entries[2].name, '中文.txt');
      expect(entries[2].lastModified, DateTime.utc(2026, 9, 22, 11, 5, 40));
    });

    test('href 是完整 URL 时也能折成服务端路径', () {
      const body = '''<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:"><D:response>
<D:href>https://h:5001/~DSFile/queryWebdav.cgi/home/x.txt</D:href>
<D:propstat><D:prop><D:resourcetype/></D:prop>
<D:status>HTTP/1.1 200 OK</D:status></D:propstat>
</D:response></D:multistatus>''';
      final e = parseWebDavMultiStatus(body, stripPrefix: kWebDavQueryPath);
      expect(e.single.path, '/home/x.txt');
    });

    test('坏 XML / 不是 multistatus → 空表（不抛）', () {
      expect(parseWebDavMultiStatus('<not-xml', stripPrefix: ''), isEmpty);
      expect(parseWebDavMultiStatus('<root/>', stripPrefix: ''), isEmpty);
    });

    test('PROPFIND：无 body（allprop）+ Depth + Content-Type + 认证头', () async {
      final fake = _FakeWebDav(
        (_) => const WebDavResponse(statusCode: 207, body: _multiStatus),
      );
      final client = WebDavClient(target: target, transport: fake);
      final children = await client.listChildren('/');

      final req = fake.requests.single;
      expect(req.method, 'PROPFIND');
      expect(
        req.body,
        isNull,
        reason: '官方 buildRequestBody(null) ⇒ RFC4918 allprop',
      );
      expect(req.headers['Depth'], '1');
      expect(req.headers['Content-Type'], 'text/xml');
      expect(req.headers['User-Agent'], 'DSfile');
      expect(req.headers['Authorization'], target.authorizationHeader);
      expect(req.url, 'https://nas.example.com:5001/~DSFile/queryWebdav.cgi/');

      // self 条目（`/`）被去掉，只剩 3 个子项
      expect(children, hasLength(3));
    });

    test('OPTIONS：解析 DAV / Allow', () async {
      final fake = _FakeWebDav(
        (_) => const WebDavResponse(
          statusCode: 200,
          headers: {
            'dav': '1, 2',
            'allow': 'OPTIONS, PROPFIND, GET',
            'server': 'nginx',
          },
        ),
      );
      final caps = await WebDavClient(
        target: target,
        transport: fake,
      ).options();
      expect(caps.dav, '1, 2');
      expect(caps.supportsPropfind, isTrue);
      expect(caps.allow, ['OPTIONS', 'PROPFIND', 'GET']);
      expect(fake.requests.single.method, 'OPTIONS');
    });

    test('version：majorVersion ≥ 7 ⇒ 官方已标废弃', () async {
      final fake = _FakeWebDav(
        (_) => const WebDavResponse(
          statusCode: 200,
          body: '{"success":true,"majorVersion":"7"}',
        ),
      );
      final v = await WebDavClient(target: target, transport: fake).version();
      expect(v.success, isTrue);
      expect(v.majorVersion, 7);
      expect(v.isDeprecatedBySynology, isTrue);
      expect(fake.requests.single.headers['action'], 'version');
      expect(
        const WebDavVersion(
          success: true,
          majorVersion: 6,
        ).isDeprecatedBySynology,
        isFalse,
      );
    });

    test('非 2xx → WebDavException（带码），坏 version body 也抛', () async {
      final forbidden = _FakeWebDav(
        (_) => const WebDavResponse(statusCode: 403),
      );
      await expectLater(
        WebDavClient(target: target, transport: forbidden).list('/'),
        throwsA(
          isA<WebDavException>()
              .having((e) => e.statusCode, 'status', 403)
              .having((e) => e.method, 'method', 'PROPFIND'),
        ),
      );

      final badVersion = _FakeWebDav(
        (_) => const WebDavResponse(statusCode: 200, body: 'not-json'),
      );
      await expectLater(
        WebDavClient(target: target, transport: badVersion).version(),
        throwsA(isA<WebDavException>()),
      );
    });

    test('isGoodResponse 与官方一致（200..299）', () {
      expect(WebDavClient.isGoodResponse(200), isTrue);
      expect(WebDavClient.isGoodResponse(207), isTrue);
      expect(WebDavClient.isGoodResponse(299), isTrue);
      expect(WebDavClient.isGoodResponse(300), isFalse);
      expect(WebDavClient.isGoodResponse(199), isFalse);
    });
  });
}
