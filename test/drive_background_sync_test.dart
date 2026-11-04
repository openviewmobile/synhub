// ★★ ③Drive 第 248 轮 **D65「后台真的搬文件」** 的离线用例。
//
// 全部走**本地 Mock Server**（规则 B）：`Files/list` 走目录校验 + 夹具，
// `Files/download` 走**二进制** `handleRaw`（247 轮给 mock 补的）。
// 注入的依赖图让用例不碰真库/真 Keystore/真 QuickConnect，但**执行器与判定**
// 用的是生产同一套（`planDriveSync`/`DriveSyncExecutor`/`DriveApiSyncIo`）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/drive/drive_background_sync.dart';
import 'package:synhub/src/features/drive/drive_sync_task.dart';
import 'package:synhub/src/features/drive/drive_watch_bridge.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// JSON 走 mock 的 `handle`，二进制走 `handleRaw`（与 `drive_open_on_demand_test` 同构）。
class _MockTransport extends FakeTransport {
  _MockTransport(this.backend);

  final MockDsmBackend backend;
  String sid = '';
  final List<String> bytesUrls = [];

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) {
    final p = Map<String, String>.from(params);
    p['_sid'] = sid ?? this.sid;
    return Uri.parse(
      'https://mock.local/$path',
    ).replace(queryParameters: p).toString();
  }

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    final r = backend.handle(path, {...params, '_sid': sid});
    return jsonEncode(r.json);
  }

  @override
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) async {
    bytesUrls.add(url);
    final u = Uri.parse(url);
    final r = backend.handleRaw(u.path.replaceFirst('/', ''), u.queryParameters);
    if (!r.ok) throw StateError('HTTP ${r.errorCode}');
    return r.bytes;
  }
}

/// 假本地扫描器（不碰真磁盘）
class _Scanner {
  _Scanner(this.entries);
  List<DriveSyncLocalEntry> entries;
  final List<String> roots = [];
  Future<List<DriveSyncLocalEntry>> call(String root) async {
    roots.add(root);
    return entries;
  }
}

class _MemoryTaskStore implements DriveSyncTaskStore {
  _MemoryTaskStore(this.tasks);
  List<DriveSyncTask> tasks;
  int saves = 0;
  @override
  Future<List<DriveSyncTask>> load() async => List.of(tasks);
  @override
  Future<void> save(List<DriveSyncTask> tasks) async {
    this.tasks = List.of(tasks);
    saves++;
  }
}

void main() {
  late MockDsmBackend backend;
  late _MockTransport transport;
  late Directory tmp;
  late DriveApi api;

  final payload = utf8.encode('remote file body\n');

  const fileItem = {
    'file_id': 'f-1',
    'name': 'note.txt',
    'path': '/mydrive/note.txt',
    'isdir': false,
    'size': 17,
    'mtime': 1700000000,
    'type': 'file',
  };

  setUp(() {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    transport = _MockTransport(backend);
    transport.sid = backend.login(username: 'u', admin: false);
    // 登录本身会记一条请求；用例关心的是**同步**发出的请求 ⇒ 先清干净
    backend.requests.clear();
    api = DriveApi(DsmWebApi(transport));
    tmp = Directory.systemTemp.createTempSync('drive_bg_test');
    backend.fixture('SYNO.SynologyDrive.Files', 'list', (p) {
      return {
        'success': true,
        'data': {
          'total': 1,
          'items': [fileItem],
        },
      };
    });
    // `DriveApiSyncIo.download` 先 `Files/get` 拿 file_id，再走二进制 download
    backend.fixture('SYNO.SynologyDrive.Files', 'get', (p) {
      return {
        'success': true,
        'data': {
          'total': 1,
          'items': [fileItem],
          // 有的版本把条目平铺在 data 里
          ...fileItem,
        },
      };
    });
    backend.rawFixture('SYNO.SynologyDrive.Files', 'download', (p) {
      if (!'${p['files']}'.contains('f-1')) {
        return const MockRawResponse.error(408, note: '不存在');
      }
      return MockRawResponse(payload, note: '远端文件字节');
    });
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 默认 `ignoreLocalRemove: true` ⇒ 本地缺失时**以远端为准（下载）**，
  /// 与官方默认策略一致（另一支是"把本地删除传播到远端"）。
  DriveSyncTask taskAt(String root, {int lastSyncAtMs = 0}) => DriveSyncTask(
    id: 't1',
    localRoot: root,
    remoteRoot: '/mydrive',
    lastSyncAtMs: lastSyncAtMs,
    ignoreLocalRemove: true,
  );

  test('★ 被唤醒的根 ⇒ 真的把远端文件下到本地（Mock 二进制）', () async {
    final localRoot = '${tmp.path}/local';
    Directory(localRoot).createSync(recursive: true);
    final scanner = _Scanner(const []);
    final store = _MemoryTaskStore([taskAt(localRoot)]);
    final ctx = DriveSyncBackgroundContext(
      store: store,
      api: api,
      scanLocal: scanner.call,
      now: () => DateTime(2026, 9, 25, 3),
    );
    final r = await runDriveSyncWith(ctx, roots: [localRoot]);
    expect(r.ok, isTrue);
    expect(r.tasks, 1);
    expect(r.downloaded, 1);
    // 文件真的落盘，内容 = mock 的字节
    final f = File('$localRoot/note.txt');
    expect(f.existsSync(), isTrue);
    expect(f.readAsBytesSync(), payload);
    // 任务被写回：状态 done + 上次同步时间
    expect(store.saves, 1);
    expect(store.tasks.single.status, DriveSyncStatus.done);
    expect(store.tasks.single.lastSyncAtMs, greaterThan(0));
    // wire 上确实是 Mock 的目录/接口
    expect(transport.bytesUrls, hasLength(1));
    expect(transport.bytesUrls.single, contains('method=download'));
    expect(
      backend.requests.map((q) => '${q.params['method']}'),
      contains('list'),
    );
  });

  test('★ 没被唤醒且粒度没到 ⇒ 一条请求都不发（不空转）', () async {
    final localRoot = '${tmp.path}/l2';
    final scanner = _Scanner(const []);
    final store = _MemoryTaskStore([
      // 1 分钟前刚跑过 + 默认间隔 ⇒ **没到点**
      taskAt(
        localRoot,
        lastSyncAtMs: DateTime(
          2026,
          9,
          25,
          2,
          59,
        ).millisecondsSinceEpoch,
      ),
    ]);
    final ctx = DriveSyncBackgroundContext(
      store: store,
      api: api,
      scanLocal: scanner.call,
      now: () => DateTime(2026, 9, 25, 3),
    );
    final r = await runDriveSyncWith(ctx, roots: const []);
    expect(r.tasks, 0);
    expect(scanner.roots, isEmpty);
    expect(backend.requests, isEmpty);
    expect(store.saves, 0);
  });

  test('★ 到点了（无唤醒来源的周期检查）⇒ 会跑', () async {
    final localRoot = '${tmp.path}/l3';
    Directory(localRoot).createSync(recursive: true);
    final store = _MemoryTaskStore([
      // 1 分钟间隔 + 2 小时前跑的 ⇒ 必然到点
      taskAt(
        localRoot,
        lastSyncAtMs: DateTime(2026, 9, 25, 1).millisecondsSinceEpoch,
      ).copyWith(autoSyncInterval: 1),
    ]);
    final ctx = DriveSyncBackgroundContext(
      store: store,
      api: api,
      scanLocal: _Scanner(const []).call,
      now: () => DateTime(2026, 9, 25, 3),
    );
    final r = await runDriveSyncWith(ctx, roots: const []);
    expect(r.tasks, 1);
    expect(r.downloaded, 1);
  });

  test('★ 唤醒的是没登记的根 ⇒ 不跑，但把该根从账本摘掉', () async {
    final store = _MemoryTaskStore([
      taskAt('${tmp.path}/other'),
    ]);
    final wakes = RecordingWakeStore(['${tmp.path}/unknown'] + [
      normalizeDriveLocalRoot('${tmp.path}/other'),
    ]);
    final ctx = DriveSyncBackgroundContext(
      store: store,
      api: api,
      scanLocal: _Scanner(const []).call,
      now: () => DateTime(2026, 9, 25, 3),
      clearWakes: (roots) => wakes.removeAll(roots),
    );
    final r = await runDriveSyncWith(ctx, roots: ['${tmp.path}/unknown']);
    expect(r.tasks, 0);
    expect(backend.requests, isEmpty);
    // 只摘掉处理过的那个根，别人的还挂着
    expect(wakes.ids, [normalizeDriveLocalRoot('${tmp.path}/other')]);
  });

  test('★ 单条失败只记录不中断（远端 408 ⇒ 任务 error，回执 failed=1）', () async {
    backend.rawFixture('SYNO.SynologyDrive.Files', 'download', (p) {
      return const MockRawResponse.error(408, note: '文件没了');
    });
    final localRoot = '${tmp.path}/l4';
    Directory(localRoot).createSync(recursive: true);
    final store = _MemoryTaskStore([taskAt(localRoot)]);
    final ctx = DriveSyncBackgroundContext(
      store: store,
      api: api,
      scanLocal: _Scanner(const []).call,
      now: () => DateTime(2026, 9, 25, 3),
    );
    final r = await runDriveSyncWith(ctx, roots: [localRoot]);
    expect(r.executed, 0);
    expect(r.failed, 1);
    expect(r.ok, isFalse);
    expect(store.tasks.single.status, DriveSyncStatus.error);
    expect(File('$localRoot/note.txt').existsSync(), isFalse);
  });

  test('★★ 249 轮：一条任务都没有 ⇒ **一次都不登录**（preflight 先看活）', () async {
    final store = _MemoryTaskStore(const []);
    final wakes = RecordingWakeStore([normalizeDriveLocalRoot('${tmp.path}/w')]);
    final logFile = File('${tmp.path}/bg0.json');
    final r = await runDriveSyncInBackground(
      ['${tmp.path}/w'],
      // ★ 只要走到"装配依赖图 + 静默重登"这一步就会炸
      open: () async => fail('没有活的时候绝不该登录/建库'),
      taskStoreFor: () async => store,
      logFileFor: () async => logFile,
      wakeStore: wakes,
      now: () => DateTime(2026, 9, 25, 3),
    );
    expect(r.ok, isTrue);
    expect(r.tasks, 0);
    // 待办账被摘掉（没活可干，账不该继续挂着）
    expect(wakes.ids, isEmpty);
    // 后台日志照样留痕（不然真机上无法证明"worker 真的跑到底了"）
    final list = jsonDecode(logFile.readAsStringSync()) as List;
    expect(list, hasLength(1));
    expect(list.first['tasks'], 0);
  });

  test('★ 249 轮：有活才登录（存在被唤醒的任务 ⇒ open 被调用一次）', () async {
    final localRoot = '${tmp.path}/l6';
    Directory(localRoot).createSync(recursive: true);
    final store = _MemoryTaskStore([taskAt(localRoot)]);
    var opened = 0;
    final r = await runDriveSyncInBackground(
      [localRoot],
      open: () async {
        opened++;
        return DriveSyncBackgroundContext(
          store: store,
          api: api,
          scanLocal: _Scanner(const []).call,
          now: () => DateTime(2026, 9, 25, 3),
        );
      },
      taskStoreFor: () async => store,
      wakeStore: RecordingWakeStore(const []),
      now: () => DateTime(2026, 9, 25, 3),
    );
    expect(opened, 1);
    expect(r.downloaded, 1);
  });

  test('★ 没有可用会话 ⇒ 如实回 no-saved-session（不写任何东西）', () async {
    final store = _MemoryTaskStore([taskAt('${tmp.path}/x')]);
    final r = await runDriveSyncInBackground(
      ['${tmp.path}/x'],
      open: () async => null,
      taskStoreFor: () async => store,
      wakeStore: RecordingWakeStore(const []),
    );
    expect(r.ok, isFalse);
    expect(r.error, 'no-saved-session');
    expect(r.toMap()['error'], 'no-saved-session');
  });

  test('★ 后台日志：落盘 + 只留最近 20 条 + 原子写（无 .part 残留）', () async {
    final localRoot = '${tmp.path}/l5';
    Directory(localRoot).createSync(recursive: true);
    final logFile = File('${tmp.path}/drive_sync_bg_log.json');
    // 预置 25 条旧日志
    logFile.writeAsStringSync(
      jsonEncode([
        for (var i = 0; i < 25; i++) {'at': i, 'ok': true},
      ]),
    );
    final store = _MemoryTaskStore([taskAt(localRoot)]);
    final ctx = DriveSyncBackgroundContext(
      store: store,
      api: api,
      scanLocal: _Scanner(const []).call,
      now: () => DateTime(2026, 9, 25, 3),
      logFile: logFile,
    );
    final r = await runDriveSyncInBackground(
      [localRoot],
      open: () async => ctx,
      taskStoreFor: () async => store,
      logFileFor: () async => logFile,
      wakeStore: RecordingWakeStore(const []),
      now: () => DateTime(2026, 9, 25, 3),
    );
    expect(r.downloaded, 1);
    final list = jsonDecode(logFile.readAsStringSync()) as List;
    expect(list, hasLength(20));
    expect(list.first['downloaded'], 1);
    expect(File('${logFile.path}.part').existsSync(), isFalse);
  });

  test('★ 与 Kotlin 的通道/方法名一致（读源码钉住）', () {
    final kt = File(
      'android/app/src/main/kotlin/com/openviewai/synhub/DriveWatchWorker.kt',
    ).readAsStringSync();
    expect(kDriveSyncBackgroundChannel, 'synhub/drive_watch_bg');
    expect(kt, contains('BG_CHANNEL = "synhub/drive_watch_bg"'));
    expect(kt, contains('invokeBg(engine, args, "wake")'));
    expect(kt, contains('invokeBg(engine, args, "runSync")'));
    // ★ 真问题：headless 引擎必须自己挂 Keystore 桥，否则后台永远解不开凭据
    expect(kt, contains('KeystoreBridge.attach(engine)'));
  });

  test('★ 任务表路径必须与前台 `defaultDriveSyncStoreFile()` 一致', () {
    final page = File(
      'lib/src/features/drive/drive_sync_tasks_page.dart',
    ).readAsStringSync();
    expect(page, contains("drive_sync_tasks.json"));
    // 后台那份用的是同一个文件名（目录同为应用文档目录）
    final bg = File(
      'lib/src/features/drive/drive_background_sync.dart',
    ).readAsStringSync();
    expect(bg, contains(r"${dir.path}/drive_sync_tasks.json"));
    expect(kDriveSyncBackgroundLogFile, 'drive_sync_bg_log.json');
  });
}

/// 记录型账本（用例里看"摘掉了哪些"）
class RecordingWakeStore implements DrivePendingWakeStore {
  RecordingWakeStore(this.ids);
  List<String> ids;
  @override
  Future<List<String>> read() async => List.of(ids);
  @override
  Future<List<String>> add(Iterable<String> taskIds) async {
    for (final id in taskIds) {
      if (!ids.contains(id)) ids.add(id);
    }
    return List.of(ids);
  }

  @override
  Future<void> clear() async => ids = [];
}
