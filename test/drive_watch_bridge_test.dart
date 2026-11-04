// ★★ ③Drive 第 228 轮 **D65 原生常驻监听（Dart 侧契约 + 后台记账）** 用例。
//
// ①前台登记/撤销监听的通道契约；②待办账本（内存 + 落盘）；③后台唤醒记账；
// ④与 Kotlin 的**跨语言契约比对**（通道名、FileObserver 掩码、去抖常量、
//    worker 类名、`wake` 方法名）—— 防止两侧悄悄漂移。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';

import 'package:synhub/src/features/drive/drive_watch_bridge.dart';

void main() {
  // ★ 第 55 轮：这些用例验证的是**桥被调用时发什么载荷**（Android 语义），
  //   而能力层在 macOS 宿主上会正确地拦住 Android-only 桥 ⇒ 先把门打开
  //   （反向验证：门打开时确实去碰通道；见 `platform_capability_test.dart`）。
  setUp(() => debugForceCapabilityGate = true);
  tearDown(() => debugForceCapabilityGate = false);
  TestWidgetsFlutterBinding.ensureInitialized();

  group('D65 原生监听 · 前台通道契约', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(kDriveWatchChannel),
            (call) async {
              calls.add(call);
              return true;
            },
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(kDriveWatchChannel),
            null,
          );
    });

    test('start 先登记回调 handle，再带上根列表 + 去抖秒数 + 深度上限', () async {
      const b = MethodChannelDriveWatchBridge();
      await b.start(['/storage/emulated/0/DCIM/Drive', '/x/y']);
      expect(calls.map((c) => c.method), ['registerCallback', 'start']);
      expect((calls.first.arguments as Map)['handle'], isA<int>());
      final args = calls.last.arguments as Map;
      expect(args['roots'], ['/storage/emulated/0/DCIM/Drive', '/x/y']);
      expect(args['debounce_seconds'], kDriveWatchDebounceSeconds);
      expect(args['max_depth'], kDriveWatchMaxDepth);
    });

    test('stop / isRunning 走同名方法', () async {
      const b = MethodChannelDriveWatchBridge();
      await b.stop();
      await b.isRunning();
      expect(calls.map((c) => c.method), ['stop', 'isRunning']);
    });

    test('记录型替身：start 会替换根列表、stop 后不再运行', () async {
      final r = RecordingDriveWatchBridge();
      await r.start(['/a']);
      expect(await r.isRunning(), isTrue);
      await r.start(['/b']);
      expect(r.startedRoots, [
        ['/a'],
        ['/b'],
      ]);
      await r.stop();
      expect(await r.isRunning(), isFalse);
    });
  });

  group('D65 原生监听 · 待办账本', () {
    test('内存账本：去重、保序、可清空', () async {
      final s = MemoryDrivePendingWakeStore();
      await s.add(['t2', 't1', 't2', '']);
      expect(await s.read(), ['t2', 't1']);
      await s.add(['t1', 't3']);
      expect(await s.read(), ['t2', 't1', 't3']);
      await s.clear();
      expect(await s.read(), isEmpty);
    });

    test('落盘账本：JSON 结构 + 坏文件当"没有待办"', () async {
      final dir = Directory.systemTemp.createTempSync('d65_pending');
      final f = File('${dir.path}/drive/pending_watch.json');
      final s = JsonDrivePendingWakeStore(f);
      expect(await s.read(), isEmpty, reason: '文件不存在 ⇒ 空');
      await s.add(['t1']);
      await s.add(['t2']);
      final raw = jsonDecode(f.readAsStringSync()) as Map;
      expect(raw['version'], 1);
      expect(raw['pending'], ['t1', 't2']);
      f.writeAsStringSync('{坏');
      expect(await s.read(), isEmpty, reason: '坏文件不许抛，也不许猜');
      await s.add(['t9']);
      expect(await s.read(), ['t9']);
      await s.clear();
      expect(f.existsSync(), isFalse);
      dir.deleteSync(recursive: true);
    });
  });

  group('D65 原生监听 · 后台唤醒记账', () {
    test('wake 把 task_ids 记进账本（去重），并回 pending 数', () async {
      final store = MemoryDrivePendingWakeStore();
      final r = await recordDriveWatchWake(
        {
          'task_ids': ['t1', 't2', 't1'],
        },
        store: store,
      );
      expect(r['ok'], isTrue);
      expect(r['pending'], 2);
      expect(r['ids'], ['t1', 't2']);
      expect(r['debounce_seconds'], kDriveWatchDebounceSeconds);
      // 再来一次 ⇒ 不重复记账
      final r2 = await recordDriveWatchWake(
        {
          'task_ids': ['t2'],
        },
        store: store,
      );
      expect(r2['pending'], 2);
    });

    test('空/畸形载荷 ⇒ 不改账本，仍然 ok', () async {
      final store = MemoryDrivePendingWakeStore(['t0']);
      final r = await recordDriveWatchWake(const {}, store: store);
      expect(r['ok'], isTrue);
      expect(r['pending'], 1);
      expect(await store.read(), ['t0']);
    });

    test('账本写失败 ⇒ ok=false，不假装记上了', () async {
      final r = await recordDriveWatchWake(
        {
          'task_ids': ['t1'],
        },
        store: _FailingWakeStore(),
      );
      expect(r['ok'], isFalse);
      expect('${r['error']}', contains('磁盘满'));
    });
  });

  group('D65 原生监听 · 与 Kotlin 的跨语言契约', () {
    late String svc;
    late String worker;
    late String bridge;

    setUpAll(() {
      const base =
          'android/app/src/main/kotlin/com/openviewai/synhub/';
      svc = File('${base}DriveFileWatchService.kt').readAsStringSync();
      worker = File('${base}DriveWatchWorker.kt').readAsStringSync();
      bridge = File('${base}DriveFileWatchBridge.kt').readAsStringSync();
    });

    test('三条通道名一致（前台登记 / 后台唤醒）', () {
      expect(kDriveWatchChannel, 'synhub/drive_watch');
      expect(bridge, contains('"$kDriveWatchChannel"'));
      expect(kDriveWatchBackgroundChannel, 'synhub/drive_watch_bg');
      expect(worker, contains('"$kDriveWatchBackgroundChannel"'));
    });

    test('callback handle 由 registerCallback 交上来（Kotlin 端必须实现）', () {
      expect(bridge, contains('"registerCallback"'));
      expect(bridge, contains('rememberCallbackHandle'));
    });

    group('249 轮 · 系统拒绝启动常驻服务时的诚实行为', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(kDriveWatchChannel),
            null,
          );
    });

    test('原生抛 PlatformException ⇒ start() 回 false（不炸界面、不假装成功）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(kDriveWatchChannel), (
            call,
          ) async {
            if (call.method == 'registerCallback') return true;
            throw PlatformException(
              code: 'error',
              message:
                  'Not allowed to start service Intent: app is in background',
            );
          });
      final ok = await const MethodChannelDriveWatchBridge().start([
        '/tmp/x',
      ]);
      expect(ok, isFalse);
    });

    test('原生通道不存在（桌面/测试）⇒ start() 回 false', () async {
      // 不装 handler ⇒ MissingPluginException
      final ok = await const MethodChannelDriveWatchBridge().start([
        '/tmp/x',
      ]);
      expect(ok, isFalse);
    });

    test('Kotlin 侧必须捕获 IllegalStateException 且回滚 prefs（真机实测的那条）', () {
      expect(svc, contains('catch (e: IllegalStateException)'));
      expect(svc, contains('remove(KEY_ROOTS)'));
      expect(svc, contains('BackgroundServiceStartNotAllowedException'));
      expect(bridge, contains('result.success(DriveFileWatchService.start('));
    });

    test('界面把 false 变成实话（不再一律说"已开始后台监听"）', () {
      final page = File(
        'lib/src/features/drive/drive_sync_tasks_page.dart',
      ).readAsStringSync();
      expect(page, contains('drive_sync_watch_no_native'));
      expect(page, contains('nativeWatch = await ref'));
    });
  });

  test('去抖常量一致，且 worker 调的方法名是 wake + runSync', () {
      expect(kDriveWatchDebounceSeconds, 3);
      expect(svc, contains('DEBOUNCE_SECONDS = 3L'));
      // ★ 248 轮：worker 走的是一条通用的 `invokeBg(engine, args, method)`，
      //   先 `wake`（228 轮记账语义保留）再 `runSync`（真的搬文件）
      expect(worker, contains('invokeBg(engine, args, "wake")'));
      expect(worker, contains('invokeBg(engine, args, "runSync")'));
      expect(worker, contains('invokeMethod(method, args'));
    });

    test('真的用 FileObserver（不是我方"假装常驻"）', () {
      expect(svc, contains('FileObserver('));
      expect(
        svc,
        contains('CREATE'),
        reason: '至少要看新建/修改/删除三类事件',
      );
      expect(svc, contains('MODIFY'));
      expect(svc, contains('DELETE'));
    });

    test('深度上限一致（FileObserver 不递归，得自己走子目录）', () {
      expect(kDriveWatchMaxDepth, 2);
      expect(svc, contains('MAX_DEPTH'));
    });
  });
}

class _FailingWakeStore implements DrivePendingWakeStore {
  @override
  Future<List<String>> read() async => const [];

  @override
  Future<List<String>> add(Iterable<String> taskIds) async =>
      throw StateError('磁盘满');

  @override
  Future<void> clear() async {}
}
