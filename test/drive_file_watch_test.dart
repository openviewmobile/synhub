// ★★ ③Drive 第 224 轮 **D65 后台常驻文件监听**（Dart 半边）用例。
//
// ①去抖/噪音过滤（纯逻辑）；②协调器（监听→算差异→执行）用假监听源 + 假 IO
// 全离线验证；③`IoDriveWatchSource` 用**真实临时目录**验证 dart:io 监听真的通。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/drive/drive_file_watch.dart';
import 'package:synhub/src/features/drive/drive_sync_runner.dart';
import 'package:synhub/src/features/drive/drive_sync_task.dart';

class _FakeSource implements DriveWatchSource {
  final ctl = StreamController<DriveWatchEvent>.broadcast();
  final roots = <String>[];

  @override
  Stream<DriveWatchEvent> watch(String root) {
    roots.add(root);
    return ctl.stream;
  }
}

class _FakeRemote implements DriveSyncRemoteIo {
  final calls = <String>[];
  int downloads = 0;

  @override
  Future<String> ensureFolder(String relDir) async {
    calls.add('ensure:$relDir');
    return '1';
  }

  @override
  Future<void> upload({
    required String localPath,
    required String relPath,
  }) async => calls.add('upload:$relPath');

  @override
  Future<void> download({
    required String relPath,
    required String localPath,
  }) async {
    downloads += 1;
    calls.add('download:$relPath');
  }

  @override
  Future<void> removeRemote(String relPath) async => calls.add('rm:$relPath');
}

class _FakeLocal implements DriveSyncLocalIo {
  @override
  String absolutePath(String relPath) => '/l/$relPath';

  @override
  Future<void> removeLocal(String relPath) async {}

  @override
  Future<String> renameLocalConflict(String relPath, String stamp) async =>
      '/l/${driveSyncConflictName(relPath, stamp)}';
}

DriveSyncTask _task({
  bool autoSyncEnabled = true,
  int interval = 1,
  bool deleted = false,
}) => DriveSyncTask(
  id: 't1',
  localRoot: '/l',
  remoteRoot: '/mydrive/t',
  autoSyncEnabled: autoSyncEnabled,
  autoSyncInterval: interval,
  deleted: deleted,
);

DriveWatchEvent _e(String path, [DriveWatchChange c = DriveWatchChange.modified]) =>
    DriveWatchEvent(relPath: path, change: c, atMs: 1000);

void main() {
  group('D65 文件监听 · 噪音过滤', () {
    test('临时/中间文件被忽略，正经文件不被忽略', () {
      for (final p in [
        'a.tmp',
        'dir/b.crdownload',
        'c.part',
        '.hidden.swp',
        r'~$report.docx',
        '.DS_Store',
      ]) {
        expect(driveWatchNoisePath(p), isTrue, reason: p);
      }
      for (final p in ['a.txt', 'dir/报告.pdf', 'x.docx']) {
        expect(driveWatchNoisePath(p), isFalse, reason: p);
      }
    });
  });

  group('D65 文件监听 · 去抖', () {
    test('窗口内多个事件合并成一批（按路径去重、保留最后一次）', () async {
      final src = StreamController<DriveWatchEvent>();
      final batches = <List<DriveWatchEvent>>[];
      final sub = debounceDriveWatch(
        src.stream,
        window: const Duration(milliseconds: 80),
      ).listen(batches.add);
      src
        ..add(_e('a.txt'))
        ..add(_e('a.txt', DriveWatchChange.created))
        ..add(_e('b.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(batches, hasLength(1));
      expect(batches.single.map((e) => e.relPath), ['a.txt', 'b.txt']);
      expect(
        batches.single.first.change,
        DriveWatchChange.created,
        reason: '同一路径保留最后一次',
      );
      // 第二个窗口独立成批
      src.add(_e('c.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(batches, hasLength(2));
      await sub.cancel();
      await src.close();
    });

    test('噪音不进批；全是噪音则一批都不发', () async {
      final src = StreamController<DriveWatchEvent>();
      final batches = <List<DriveWatchEvent>>[];
      final sub = debounceDriveWatch(
        src.stream,
        window: const Duration(milliseconds: 50),
      ).listen(batches.add);
      src
        ..add(_e('x.tmp'))
        ..add(_e('y.crdownload'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(batches, isEmpty);
      await sub.cancel();
      await src.close();
    });
  });

  group('D65 文件监听 · 自动同步协调器', () {
    test('启用且到间隔 ⇒ 算差异并真的调执行器', () async {
      final source = _FakeSource();
      final remote = _FakeRemote();
      final co = DriveAutoSyncCoordinator(
        source: source,
        task: _task(),
        diffBuilder: () async => DriveSyncDiff([
          const DriveSyncAction(DriveSyncActionKind.upload, 'a.txt', '新增'),
          const DriveSyncAction(DriveSyncActionKind.skip, 'b.txt', '一样'),
        ]),
        executor: DriveSyncExecutor(remote: remote, local: _FakeLocal()),
        window: const Duration(milliseconds: 40),
      );
      addTearDown(co.dispose);
      final runs = <DriveAutoSyncRun>[];
      co.runs.listen(runs.add);
      await co.start();
      expect(co.isListening, isTrue);
      expect(source.roots, ['/l']);
      source.ctl.add(_e('a.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(runs, hasLength(1));
      expect(runs.single.ran, isTrue);
      expect(runs.single.changedPaths, ['a.txt']);
      expect(runs.single.executed, 1);
      expect(remote.calls, contains('upload:a.txt'));
    });

    test('未启用自动同步 ⇒ 记录"跳过"，不发任何请求', () async {
      final source = _FakeSource();
      final remote = _FakeRemote();
      final co = DriveAutoSyncCoordinator(
        source: source,
        task: _task(autoSyncEnabled: false),
        diffBuilder: () async => DriveSyncDiff(const []),
        executor: DriveSyncExecutor(remote: remote, local: _FakeLocal()),
        window: const Duration(milliseconds: 40),
      );
      addTearDown(co.dispose);
      final runs = <DriveAutoSyncRun>[];
      co.runs.listen(runs.add);
      await co.start();
      source.ctl.add(_e('a.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(runs.single.ran, isFalse);
      expect(runs.single.skippedReason, contains('未启用'));
      expect(remote.calls, isEmpty);
    });

    test('距上次不足间隔 ⇒ 跳过（防抖动打爆服务端）', () async {
      final source = _FakeSource();
      var now = 1000000;
      var diffs = 0;
      final co = DriveAutoSyncCoordinator(
        source: source,
        task: _task(interval: 60),
        diffBuilder: () async {
          diffs += 1;
          return DriveSyncDiff(const []);
        },
        executor: DriveSyncExecutor(remote: _FakeRemote(), local: _FakeLocal()),
        window: const Duration(milliseconds: 30),
        now: () => now,
      );
      addTearDown(co.dispose);
      final runs = <DriveAutoSyncRun>[];
      co.runs.listen(runs.add);
      await co.start();
      source.ctl.add(_e('a.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(runs, hasLength(1));
      expect(runs.single.ran, isTrue);
      expect(diffs, 1);
      // 第二次：时间只过了 1 分钟内的 30 秒
      now += 30 * 1000;
      source.ctl.add(_e('a.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(runs, hasLength(2));
      expect(runs.last.ran, isFalse);
      expect(runs.last.skippedReason, contains('不足'));
      expect(diffs, 1, reason: '跳过时不该再算差异');
      // 过了间隔 ⇒ 再跑
      now += 61 * 60 * 1000; // 61 分钟 > 60 分钟间隔
      source.ctl.add(_e('a.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(diffs, 2);
    });

    test('stop 后不再触发；已删除任务不发车', () async {
      final source = _FakeSource();
      final co = DriveAutoSyncCoordinator(
        source: source,
        task: _task(),
        diffBuilder: () async => DriveSyncDiff(const []),
        executor: DriveSyncExecutor(remote: _FakeRemote(), local: _FakeLocal()),
        window: const Duration(milliseconds: 30),
      );
      addTearDown(co.dispose);
      var count = 0;
      co.runs.listen((_) => count += 1);
      await co.start();
      await co.stop();
      expect(co.isListening, isFalse);
      source.ctl.add(_e('a.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(count, 0);
    });

    test('差异计算抛错 ⇒ 记成失败但不崩', () async {
      final source = _FakeSource();
      final co = DriveAutoSyncCoordinator(
        source: source,
        task: _task(),
        diffBuilder: () async => throw StateError('未连接'),
        executor: DriveSyncExecutor(remote: _FakeRemote(), local: _FakeLocal()),
        window: const Duration(milliseconds: 30),
      );
      addTearDown(co.dispose);
      final runs = <DriveAutoSyncRun>[];
      co.runs.listen(runs.add);
      await co.start();
      source.ctl.add(_e('a.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(runs.single.ran, isTrue);
      expect(runs.single.failed, 0);
      expect(runs.single.skippedReason, contains('未连接'));
    });
  });

  group('D65 文件监听 · 真实 dart:io 监听（临时目录）', () {
    test('新建文件真的能收到事件（Android 上同一条链路 = inotify）', () async {
      final dir = Directory.systemTemp.createTempSync('d65_watch');
      final batches = <List<DriveWatchEvent>>[];
      final sub = debounceDriveWatch(
        const IoDriveWatchSource().watch(dir.path),
        window: const Duration(milliseconds: 100),
      ).listen(batches.add);
      // 给监听一点注册时间（inotify 注册完成前写入会漏事件）
      await Future<void>.delayed(const Duration(milliseconds: 300));
      File('${dir.path}/hello.txt').writeAsStringSync('hi');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await sub.cancel();
      final paths = [
        for (final b in batches)
          for (final e in b) e.relPath,
      ];
      expect(
        paths.any((p) => p.endsWith('hello.txt')),
        isTrue,
        reason: '真实文件系统的 watch 必须能收到新建事件（收到=$paths）',
      );
      expect(
        paths.every((p) => p.isNotEmpty),
        isTrue,
        reason: '根目录自身的事件必须被过滤（否则相对路径是空串）',
      );
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
