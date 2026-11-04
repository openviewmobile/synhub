// DSM Mock Server 的 **HTTP 前端**（`dart:io` HttpServer）。
//
// 核心逻辑在 `mock_dsm_core.dart`（离线用例走**进程内** transport，不碰 socket）。
// 这一层是为了两种"必须是真 HTTP"的场景：
//   1. 想拿 `curl` / 官方前端 / **真机 App** 去打这台 mock（新规要的"在电脑上
//      搭建 mock server 模拟测试"）；
//   2. 端到端验证传输层（CSRF 头、form 编码、multipart、错误信封解析）。
//
// ## 用法
//     dart run tool/mock_dsm/bin/serve.dart --port 18080 --account admin
//
// 真机指向电脑：把 App 的服务器地址设成 `http://<电脑局域网 IP>:18080`。
//
// ★ 第 247 轮：**二进制接口**（`Files/download`、`get_thumbnail`）也能真回字节 ——
// 注册了 `rawFixture` 的 `api|method` 走 `backend.handleRaw`，其余照旧走 JSON 信封。
// 真机验证 SAF provider "打开那一刻真去下载"就靠它（`--drive-demo` 会注册一条）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'mock_dsm_core.dart';
import 'mock_ds_demo.dart';
import 'mock_fs_demo.dart';
import 'mock_multipart.dart';
import 'mock_chat_demo.dart';
import 'mock_note_demo.dart';
import 'mock_photo_demo.dart';

/// 夹具目录：`tool/mock_dsm/fixtures/<api>.<method>.json`
///
/// 里面的内容是**服务端返回的 `data`**（不含 `success` 信封），
/// 来源写进 `_source` 字段（反编译 SPK / APK 解析代码 / 真机抓包）。
class MockDsmFixtureStore {
  MockDsmFixtureStore(this.dir);

  final Directory dir;

  /// 把 `<api>.<method>.json` 全部注册进 [backend]。
  int installInto(MockDsmBackend backend) {
    if (!dir.existsSync()) return 0;
    var n = 0;
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.json')) continue;
      final stem = name.substring(0, name.length - '.json'.length);
      final dot = stem.lastIndexOf('.');
      if (dot <= 0) continue;
      final api = stem.substring(0, dot);
      final method = stem.substring(dot + 1);
      try {
        final body = jsonDecode(f.readAsStringSync());
        if (body is! Map) continue;
        // ⚠️ **文件夹具里存的是响应的 `data`**（见 fixtures/README.md），
        // 而 `backend.fixture()` 的回调要返回**整个信封**
        // —— 少包一层的话客户端会拿到"没有 success/data 的响应"，
        // 报成 `code=100 未知错误`。这个坑是 M73 用例踩出来的。
        // 同时剥掉 `_source` / `_note` 这类**给人和工具看的元数据**，
        // 它们不该混进"服务端返回数据"里。
        final data = Map<String, dynamic>.from(body)
          ..removeWhere((k, _) => k.startsWith('_'));
        backend.fixture(api, method, (_) => {'success': true, 'data': data});
        n++;
      } catch (e) {
        stderr.writeln('[mock] 夹具 $name 解析失败：$e');
      }
    }
    return n;
  }
}

/// ★ r433：**真机形状**的 `AppPrivilege` 键表（20 项，原文）。
///
/// 逐字抄自 `docs/capability-fixture-refresh.md` §1 与
/// `test/support/nas_capability_fixtures.dart` 的 `kLiveNasAppPrivilegeKeys`
/// （工具目录不能 import `test/`，故另抄一份；两处若不一致以文档为准）。
/// 用途：在真机上造出"某模块权限键 `false`"这个**本机 NAS 上不存在**的场景
/// （本机账号 22 个 app 全 `true`）。
const List<String> kMockRealAppPrivilegeKeys = <String>[
  'SYNO.AFP',
  'SYNO.Cal.Application',
  'SYNO.Contacts.AppInstance',
  'SYNO.Desktop',
  'SYNO.FTP',
  'SYNO.Foto.AppInstance',
  'SYNO.Rsync',
  'SYNO.SDS.App.FileStation3.Instance',
  'SYNO.SDS.BackupService.Instance',
  'SYNO.SDS.Chat.Application',
  'SYNO.SDS.DocumentViewer.Application',
  'SYNO.SDS.Drive.Application',
  'SYNO.SDS.MailClient.Application',
  'SYNO.SDS.MailPlusServer.Instance',
  'SYNO.SDS.MailServer.Instance',
  'SYNO.SDS.NoteStation.Application',
  'SYNO.SDS.SMBService.AppPrivilege.Instance',
  'SYNO.SDS.SynologyFileManager.Privilege.Extension',
  'SYNO.SDS.WebDAVServer.Instance',
  'SYNO.SFTP',
];

class MockDsmHttpServer {
  MockDsmHttpServer._(this._server, this.backend, this.fixturesLoaded);

  final HttpServer _server;
  final MockDsmBackend backend;
  final int fixturesLoaded;

  /// `--fs-demo` 装上的可写内存树（没装则是 `null`）。
  MockFileSystem? fsTree;

  /// `--download-demo` 装上的可写内存下载队列（没装则是 `null`）。
  MockDownloadStation? dsQueue;

  /// `--note-demo` 装上的可写内存笔记库（没装则是 `null`）。
  MockNoteStation? noteDb;

  /// `--photo-demo` 装上的可写内存相册库（没装则是 `null`）。
  MockPhotoLibrary? photoDb;

  /// `--chat-demo` 装上的可写内存聊天库（没装则是 `null`）。
  MockChatStation? chatDb;

  /// `--drive-demo` 时给真机用的 sid（客户端 prefs 里直接写它 ⇒ 免登录）。
  static String _sid = '';

  // ---- r701 · B12 弱网仪器（容器没有 CAP_NET_ADMIN，tc/netem 用不了）----
  //
  // 判据必须落在"客户端在慢/坏网络下的界面反应"，不是"Mock 能延迟"。
  // 用法（见 `bin/serve.dart`）：
  //   --latency-ms 1200      每个请求先等 1.2 s（验加载态/骨架，不是白屏）
  //   --fail-after 12        前 12 个请求正常（够登录+首屏），之后
  //   --fail-rate 1.0        按比例回 503（验错误态、重试入口）
  // 为什么要 `--fail-after`：一上来就全挂 ⇒ 连登录都进不去，验不到"页面错误态"。
  int latencyMs = 0;
  int failAfter = 0;
  double failRate = 0.0;
  int servedRequests = 0;
  int failedRequests = 0;
  final Random _weakNetRng = Random(701);

  int get port => _server.port;

  /// `--drive-demo` 下发的 sid（写进设备 prefs 用；非 demo 为空）。
  String get demoSid => _sid;

  /// 本机回环地址（离线端到端用）。
  String get baseUrl => 'http://127.0.0.1:$port/';

  /// 局域网地址（真机指向电脑用）。
  Future<String> lanUrl() async =>
      'http://${await _lanIp() ?? '127.0.0.1'}:$port/';

  /// 起一台 mock。`port: 0` ⇒ 让系统分配（用例里用它避免端口冲突）。
  static Future<MockDsmHttpServer> start({
    int port = 0,
    String account = 'mockuser',
    bool admin = false,
    String? catalogPath,
    Directory? fixtureDir,
    bool driveDemo = false,
    bool fsDemo = false,
    bool downloadDemo = false,
    bool noteDemo = false,
    bool photoDemo = false,
    bool smartAlbumDemo = false,
    bool chatDemo = false,
    List<String>? appPrivilegeProfileKeys,
    Set<String> appPrivilegeDenied = const <String>{},
    Set<String> appPrivilegeOmitted = const <String>{},
    bool appPrivilegeAllowAll = false,
    int latencyMs = 0,
    int failAfter = 0,
    double failRate = 0.0,
  }) async {
    final catalog = DsmCatalog.load(path: catalogPath);
    // ★ r295：真机取证那台要能把"管理员档"推出来（离线用例默认关，见
    // `MockDsmBackend.synthesizeSessionIdentity` 的注释）。
    final backend = MockDsmBackend(
      catalog: catalog,
      synthesizeSessionIdentity: true,
      // ★ r433：默认 `null` ⇒ 旧行为（通配键全放行）；
      // 传了键表才按真机形状回画像。
      appPrivilegeProfileKeys: appPrivilegeProfileKeys,
      appPrivilegeDenied: appPrivilegeDenied,
      appPrivilegeOmitted: appPrivilegeOmitted,
      appPrivilegeAllowAll: appPrivilegeAllowAll,
    );
    if (driveDemo) installDriveDemo(backend);
    // ★ r319：可写内存文件系统（写动词走查用；见 mock_fs_demo.dart）
    final fsTree = fsDemo ? backend.installFileSystemDemo() : null;
    // ★ r320：可写内存下载队列（"新建下载任务"走查用；见 mock_ds_demo.dart）
    final dsQueue = downloadDemo ? backend.installDownloadDemo() : null;
    // ★ r324：可写内存笔记库（"新建/编辑笔记"走查用；见 mock_note_demo.dart）
    final nsDb = noteDemo ? backend.installNoteDemo() : null;
    // ★ r325：可写内存相册库（"上传照片"走查用；见 mock_photo_demo.dart）
    // ★ r436：`--smart-album-demo` 复用相册内存库，但把画像切成"人脸识别 /
    //   场景识别已开"并给出人物名册与场景（见 mock_photo_demo.dart 的
    //   smartAlbumDemo 分支）。
    final phDb = photoDemo
        ? backend.installPhotoDemo(smartAlbumDemo: smartAlbumDemo)
        : null;
    // ★ r326：可写内存聊天库（"发一条消息"走查用；见 mock_chat_demo.dart）
    final chDb = chatDemo ? backend.installChatDemo() : null;
    // 非 demo 的默认会话（真机走正常登录流程）
    if (!driveDemo) backend.login(username: account, admin: admin);

    final dir =
        fixtureDir ?? Directory('${_repoRoot()}/tool/mock_dsm/fixtures');
    final loaded = MockDsmFixtureStore(dir).installInto(backend);

    // `--drive-demo`：给真机一个可写进 prefs 的 sid（免登录直接测下载）
    if (driveDemo) _sid = backend.login(username: account, admin: admin);

    final server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      port,
      shared: false,
    );
    final mock = MockDsmHttpServer._(server, backend, loaded)
      ..latencyMs = latencyMs
      ..failAfter = failAfter
      ..failRate = failRate
      ..fsTree = fsTree
      ..dsQueue = dsQueue
      ..noteDb = nsDb
      ..photoDb = phDb
      ..chatDb = chDb;
    unawaited(mock._serve());
    return mock;
  }

  Future<void> _serve() async {
    await for (final req in _server) {
      try {
        // r701 · 弱网：先延迟（模拟高 RTT），再按预算决定是否整条 503。
        if (latencyMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: latencyMs));
        }
        servedRequests++;
        if (servedRequests > failAfter &&
            failRate > 0 &&
            _weakNetRng.nextDouble() < failRate) {
          failedRequests++;
          stdout.writeln(
            '[mock] FAIL 503 ${req.method} ${req.uri.path} '
            '（第 $servedRequests 个请求，failAfter=$failAfter '
            'rate=$failRate，累计失败 $failedRequests）',
          );
          req.response.statusCode = 503;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'success': false,
              'error': {'code': 500},
            }),
          );
          await req.response.close();
          continue;
        }
        await _handle(req);
      } catch (e) {
        // mock 不该把异常透给客户端：一律回 DSM 风格的错误信封。
        try {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'success': false,
              'error': {'code': 100},
            }),
          );
          await req.response.close();
        } catch (_) {}
        stderr.writeln('[mock] 处理异常：$e');
      }
    }
  }

  // ---- ★ 第 282 轮：Engine.IO v3 / socket.io v2（Chat 实时通道）----
  //
  // 为什么必须补：第 280 轮 macOS 上 Chat 显示 `Sync failed / 0 channels`，
  // 当时怀疑"macOS 特有"。A/B 后发现真因是 **Mock 根本没有 socket 通道**
  // （`lib/src/data/remote/socket/eio3_client.dart` 只走
  //  `GET /sc/socket.io/?EIO=3&transport=websocket&client=mobile`），
  // 于是**任何平台**的实时通道都必然失败 ⇒ 这是 Mock 缺口，不是产品缺陷。
  //
  // 本实现只做"够用且诚实"的一层：open 包 → `40`(namespace "/") → 事件回显/记录。
  // 每个帧都打日志，便于日后取证"客户端到底发了什么、服务端回了什么"。
  Future<void> _serveSocket(WebSocket ws, Map<String, String> q) async {
    final sid = 'mock-socket-${DateTime.now().microsecondsSinceEpoch}';
    stdout.writeln(
      '[mock:ws] 升级成功 EIO=${q['EIO']} client=${q['client']} sid=$sid',
    );
    // engine.io open 包（type 0）。`upgrades: []` = 不提供 polling 升级。
    ws.add(
      '0{"sid":"$sid","upgrades":[],"pingInterval":25000,"pingTimeout":60000}',
    );
    ws.listen(
      (dynamic frame) {
        final msg = '$frame';
        if (msg.isEmpty) return;
        final type = msg[0];
        if (type == '2') {
          // engine.io ping（客户端发 2 / 服务端回 3）
          ws.add('3${msg.length > 1 ? msg.substring(1) : ''}');
          return;
        }
        if (msg == '40') {
          // socket.io 连接命名空间 "/"
          stdout.writeln('[mock:ws] ← 40（连命名空间） → 回 40');
          ws.add('40');
          // ★ r326：**`client.init` 是 `conn_id` 的唯一来源**
          //   （`chat_socket.dart:219 _handleInit` 读 `{id, version}`）。
          //   以前这里什么都不发 ⇒ 客户端 `connId` 恒 null ⇒ `sendMessage()`
          //   在第一步就 return false（"连不上实时通道"）—— 那是 **Mock 缺口**，
          //   不是产品缺陷。格式与客户端 `emit()` 一致：`42["name",payload]`。
          final connId = '$sid-conn';
          ws.add('42${jsonEncode([
                'client.init',
                {'id': connId, 'version': 'mock-2.11.1'},
              ])}');
          chatDb?.registerConnId(connId);
          stdout.writeln(
            '[mock:ws] → client.init id=$connId'
            '${chatDb == null ? '（未装 --chat-demo，Post/create 仍会拒）' : '（已登记进聊天库）'}',
          );
          return;
        }
        if (msg.startsWith('42')) {
          stdout.writeln('[mock:ws] ← $msg');
          return;
        }
        stdout.writeln('[mock:ws] ← $msg（未处理，按原样记录）');
      },
      onDone: () => stdout.writeln('[mock:ws] 客户端断开 sid=$sid'),
      onError: (Object e) => stdout.writeln('[mock:ws] 出错 sid=$sid：$e'),
      cancelOnError: true,
    );
  }

  Future<void> _handle(HttpRequest req) async {
    // ★ r664：**CORS**（Web 站验收需要）。
    //   Flutter Web 走浏览器的 `fetch`：跨源时先打 preflight，且只有回包里带
    //   `access-control-allow-origin`（且不能是 `*`，因为带凭据）才肯把响应交给
    //   Dart 侧 ⇒ 没有这几个头，Web 站连 Mock 都"连不上"，会被误判成产品缺陷。
    //   注意：**真 NAS 不发这些头**，所以跨源直连真 NAS 仍然不可行（那是
    //   `docs/platform-web.md` §8 的部署决策：同源部署到 NAS 上）。
    final origin = req.headers.value('origin');
    if (origin != null && origin.isNotEmpty) {
      req.response.headers.set('access-control-allow-origin', origin);
      req.response.headers.set('access-control-allow-credentials', 'true');
      req.response.headers.set('vary', 'origin');
    }
    if (req.method == 'OPTIONS') {
      req.response.headers.set(
        'access-control-allow-methods',
        'GET, POST, OPTIONS',
      );
      req.response.headers.set(
        'access-control-allow-headers',
        req.headers.value('access-control-request-headers') ?? '*',
      );
      req.response.headers.set('access-control-max-age', '600');
      req.response.statusCode = HttpStatus.noContent;
      await req.response.close();
      return;
    }
    var path = req.uri.path;
    if (path.startsWith('/')) path = path.substring(1);
    // `webapi/entry.cgi` → `entry.cgi`（与真实 DSM 的 cgi 名对齐）
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    final cgi = segs.isEmpty ? path : segs.last;

    // ★ 实时通道：websocket 升级 / polling 握手（见 _serveSocket 注释）
    if (cgi == 'socket.io') {
      final q = req.uri.queryParameters;
      if (q['transport'] == 'websocket') {
        if (!WebSocketTransformer.isUpgradeRequest(req)) {
          req.response.statusCode = HttpStatus.badRequest;
          req.response.write('socket.io: 需要 websocket 升级');
          await req.response.close();
          return;
        }
        final ws = await WebSocketTransformer.upgrade(req);
        unawaited(_serveSocket(ws, q));
        return;
      }
      // polling 握手：只回 open 包（本仓客户端不用它，但手动 curl 时能看懂）
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.text;
      req.response.write(
        '0{"sid":"mock-poll","upgrades":["websocket"],'
        '"pingInterval":25000,"pingTimeout":60000}',
      );
      await req.response.close();
      return;
    }

    // 参数：GET 查询串 + POST 表单体都要（真实 DSM 两条都吃）
    final params = <String, dynamic>{};
    req.uri.queryParameters.forEach((k, v) => params[k] = v);
    if (req.method == 'POST') {
      final type = req.headers.contentType?.mimeType ?? '';
      if (type.contains('multipart/form-data')) {
        // ★ r319：上传（`SYNO.FileStation.Upload/upload`）是**唯一**把文件字节
        //   发上来的写动词；原来这里 `drain()` 把体丢掉 ⇒ Mock 永远收不到文件。
        //   解析出的字段并进 `params`，文件挂在约定的 `__files` 键上
        //   （夹具从 `p['__files']` 取；见 `mock_fs_demo.dart`）。
        final body = <int>[];
        await for (final chunk in req) {
          body.addAll(chunk);
        }
        // ⚠️ `headers.contentType?.mimeType` **只有** `multipart/form-data`，
        //    boundary 在**参数**里 —— 传 `mimeType` 进去必然"解析失败"
        //    （r319 第一次跑就是这个：请求到了、Mock 说解析失败）。
        final boundary = req.headers.contentType?.parameters['boundary'];
        final form = MultipartForm.parse(
          body,
          'multipart/form-data; boundary=$boundary',
        );
        if (form != null) {
          params.addAll(form.fields);
          params['__files'] = [
            for (final f in form.files)
              {'name': f.filename, 'bytes': f.bytes},
          ];
          stdout.writeln(
            '[mock]   → multipart 字段 ${form.fields.keys.join(',')}'
            ' · 文件 ${form.files.length}',
          );
        } else {
          // 判不了就说判不了（不许当成"空上传成功"）
          stdout.writeln('[mock]   → multipart 解析失败（boundary 缺失或体损坏）');
          params['__multipartBroken'] = true;
        }
      } else if (type.contains('application/x-www-form-urlencoded') ||
          type.isEmpty) {
        final body = await utf8.decoder.bind(req).join();
        if (body.isNotEmpty) {
          for (final pair in body.split('&')) {
            if (pair.isEmpty) continue;
            final i = pair.indexOf('=');
            final k = i < 0 ? pair : pair.substring(0, i);
            final v = i < 0 ? '' : pair.substring(i + 1);
            params[Uri.decodeQueryComponent(k)] = Uri.decodeQueryComponent(v);
          }
        }
      } else {
        await req.drain<void>();
      }
    }

    // ★ 247 轮：**二进制接口**（download / get_thumbnail …）真回字节。
    // 判据 = 该 `api|method` 注册过 rawFixture（JSON 夹具不会误伤）。
    final api = '${params['api'] ?? ''}';
    final method = '${params['method'] ?? ''}';
    // ★ 247 轮：**每次请求都打一行** —— 真机取证时要能证明"客户端到底调了什么、
    // 回了多少字节"（原来只有 JSON 分支有 requests 记录，且只在进程内可见）。
    stdout.writeln(
      '[mock] ${req.method} /$cgi api=$api method=$method '
      'v${params['version']} sid=${params['_sid']}',
    );
    if (backend.rawFixtures.containsKey('$api|$method')) {
      final raw = backend.handleRaw(cgi, params);
      // ★ 第 329 轮：错误分支带上 **note**。没有它，`raw error 408` 完全不说是
      //   "哪个 path 没找到"，上一轮就为这句白跑了一次 1 小时 25 分钟的集成
      //   （§2.0.57④：超时/失败诊断必须带"到底发生了什么"）。
      stdout.writeln(
        '[mock]   → raw '
        '${raw.ok ? '${raw.bytes.length} bytes' : 'error ${raw.errorCode}（${raw.note}）'}',
      );
      req.response.statusCode = 200; // 与 DSM 一样：错误也用 200 承载
      if (raw.ok) {
        req.response.headers.contentType = ContentType.parse(raw.contentType);
        req.response.add(raw.bytes);
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'success': false,
            'error': {'code': raw.errorCode},
          }),
        );
      }
      await req.response.close();
      return;
    }

    final res = backend.handle(cgi, params);
    req.response.statusCode = 200; // DSM 用 200 承载业务错误
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(res.json));
    await req.response.close();
  }

  Future<void> stop() => _server.close(force: true);

  // ------------------------------------------------------------------
  static Future<String?> _lanIp() async {
    // 取第一个非回环 IPv4；失败就 null（由调用方回退 127.0.0.1）。
    try {
      for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      )) {
        for (final a in iface.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (_) {}
    return null;
  }
}

/// `--drive-demo` 装的**Drive 最小夹具**：一条 `Files/list` + 一条**二进制**
/// `Files/download`（内容是可预测的 `Drive mock demo` 前缀 + 序号）。
///
/// 为什么需要：真机验证 SAF provider "按需下载"要求
/// ①云端目录里有条目（`:real:` 镜像）②直链真能回字节。夹具的 `fileId`
/// 固定为 [kDriveDemoFileId]，Dart/Kotlin/索引三处必须一致。
void installDriveDemo(MockDsmBackend backend) {
  backend.fixture('SYNO.SynologyDrive.Files', 'list', (p) {
    final path = '${p['path'] ?? '/mydrive'}';
    return {
      'success': true,
      'data': {
        'total': 1,
        'items': [
          {
            'file_id': kDriveDemoFileId,
            'name': kDriveDemoFileName,
            'path': '$path/$kDriveDemoFileName',
            'isdir': false,
            'size': kDriveDemoBytes.length,
            'mtime': 1700000000,
            'type': 'file',
          },
        ],
      },
    };
  });
  backend.fixture('SYNO.SynologyDrive.Files', 'get', (p) {
    return {
      'success': true,
      'data': {
        'file_id': kDriveDemoFileId,
        'name': kDriveDemoFileName,
        'isdir': false,
        'size': kDriveDemoBytes.length,
        'mtime': 1700000000,
        'type': 'file',
      },
    };
  });
  // ★ r719（`D10`）：回收站页原来在 Mock 上恒走错误态 —— 因为 Mock 没有
  //   `SynologyDrive.Trash` 的夹具，页面报「打不开这个位置」。
  //   真 NAS 只读实测（本批）：`Trash:list {path:"/mydrive"}` → `{"total":0}` success。
  //   这里补**空回收站**两条夹具（`list` / `get_size`），让"空态"这条路能被走到。
  backend.fixture('SYNO.SynologyDrive.Trash', 'list', (p) {
    return {
      'success': true,
      'data': {'total': 0, 'items': <Map<String, dynamic>>[]},
    };
  });
  backend.fixture('SYNO.SynologyDrive.Trash', 'get_size', (p) {
    // 真机空回收站回的就是 `{"items": null}`（见 `trashSize()` 的注释）
    return {
      'success': true,
      'data': {'items': null},
    };
  });
  backend.rawFixture('SYNO.SynologyDrive.Files', 'download', (p) {
    final files = '${p['files'] ?? ''}';
    if (!files.contains(kDriveDemoFileId)) {
      return const MockRawResponse.error(408, note: 'demo 夹具只有 $kDriveDemoFileId');
    }
    return MockRawResponse(
      kDriveDemoBytes,
      contentType: 'application/octet-stream',
      note: 'Drive demo 文件字节',
    );
  });
}

/// `--drive-demo` 的文件 id / 名字 / 内容（三处共用，别只改一处）。
const String kDriveDemoFileId = 'drive-demo-1';
const String kDriveDemoFileName = 'drive-demo.txt';

/// 内容固定可核验：每行 `Drive mock demo <n>`。
final List<int> kDriveDemoBytes = utf8.encode(
  '${List<String>.generate(8, (i) => 'Drive mock demo $i').join('\n')}\n',
);

/// 内容文本（真机把下载到的文件读回来核对用）。
String get kDriveDemoText => utf8.decode(kDriveDemoBytes);

/// 与 core 里的 `_repoRoot` 同口径（这里需要，core 那份是私有）。
String _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}
