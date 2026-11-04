// W1-3：多任务下载列表（`file_download_tasks.dart`）的离线测试。
//
// 关键承重：
//   1. **多任务不互相覆盖**：两条任务共存在列表里，并发 1，第二条排队等第一条；
//   2. **暂停 → 继续从已下载处续**（复用 `.sydownload` + `Range: bytes=<已下>-`）；
//   3. **失败可重试，且接着已下载的部分下**（不重复写文件、不生成第二个文件）；
//   4. **取消一条不影响另一条**；
//   5. **完成提示可点击打开**（列表里的「打开」真的调用打开器）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/file_download_resume.dart';
import 'package:synhub/src/features/files/file_download_tasks.dart';

import 'support/pump_until.dart';

/// 假 Range 取数口：按 [bytes] 回放；可"写一半就暂停"或"写一半就报错"。
class _Fetcher implements RangeByteFetcher {
  _Fetcher(this.bytes);

  final List<int> bytes;
  final List<int> starts = [];

  /// 第一次（start == 0）写一半后抛 [DownloadCancelledException]（用户暂停）
  bool pauseOnce = false;

  /// ★ r447：抛"取消"之前先等**测试真的按了暂停**。
  /// 原来"写一半 → `flush()` → 立刻抛"是**真 IO**，比测试里的两轮 microtask 快慢不定：
  /// 抛在 `pause()` 之前 ⇒ 续传引擎看到 `isPaused == false` ⇒ 归成"用户取消(abort)"，
  /// 状态停在 `cancelled`、`resume()` 变空操作 ⇒ 假红（历史台账里就写作"状态停在 cancelled"）。
  /// 现在由对手方等信号：`pause()` 之后再放行抛出，`isPaused == true` ⇒ 正确地走"暂停"分支。
  final Completer<void> pauseGate = Completer<void>();

  /// 第一次（start == 0）写一半后抛普通异常（失败，可重试）
  bool failOnce = false;

  @override
  Future<RangeFetchOutcome> fetchRange(
    String url, {
    required int start,
    required IOSink sink,
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
  }) async {
    starts.add(start);
    final remaining = start == 0 ? bytes : bytes.sublist(start);
    if (pauseOnce && start == 0) {
      pauseOnce = false;
      sink.add(remaining.sublist(0, remaining.length ~/ 2));
      await sink.flush();
      await pauseGate.future; // 等"暂停"真的按下去（见上面的注释）
      throw const DownloadCancelledException();
    }
    if (failOnce && start == 0) {
      failOnce = false;
      sink.add(remaining.sublist(0, remaining.length ~/ 2));
      await sink.flush();
      throw DsmTransportException('boom');
    }
    sink.add(remaining);
    await sink.flush();
    if (start == 0) {
      return RangeFetchOutcome(statusCode: 200, contentLength: bytes.length);
    }
    return RangeFetchOutcome(
      statusCode: 206,
      contentRange: 'bytes $start-${bytes.length - 1}/${bytes.length}',
      contentLength: remaining.length,
    );
  }
}

FileDownloadRunner _runner(Directory dir, FileResumeStore store, _Fetcher f) =>
    (path, {required session}) {
      final name = path.split('/').last;
      return FileDownloadResumer(fetcher: f, store: store).download(
        sourcePath: path,
        url: 'https://fake.test/$name',
        fileName: name,
        directory: dir,
        onProgress: session.report,
        cancelToken: session.cancelToken,
        // ★ DA100：归类问「这次取消是不是暂停引起的」（与生产接线同一判据）
        isPaused: () => session.pauseRequestedForInFlightRequest,
      );
    };

Future<Directory> _tmp() async {
  final dir = await Directory.systemTemp.createTemp('dl_tasks_test');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

/// 手动可控的 runner（测并发/排队，不碰文件）
class _Controlled {
  final calls = <String>[];
  final completers = <Completer<FileDownloadOutcome>>[];
  final sessions = <FileDownloadSession>[]; // ★ DA101：用例要直接推进度

  FileDownloadRunner get runner => (path, {required session}) {
    calls.add(path);
    sessions.add(session);
    final c = Completer<FileDownloadOutcome>();
    completers.add(c);
    return c.future;
  };
}

FileDownloadOutcome _done(String path) =>
    FileDownloadOutcome(localPath: path, totalBytes: 8);

void main() {
  group('多任务 / 排队', () {
    test('第二条排队，第一条完成后才跑；两条都在列表里', () async {
      final c = _Controlled();
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);
      final a = list.start(
        sourcePath: '/v/a.bin',
        name: 'a.bin',
        runner: c.runner,
      );
      final b = list.start(
        sourcePath: '/v/b.bin',
        name: 'b.bin',
        runner: c.runner,
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.calls, ['/v/a.bin'], reason: '并发 1：第二条必须排队');
      expect(b.status, FileDownloadTaskStatus.queued);
      expect(list.tasks.length, 2, reason: '两条都在列表里，互不覆盖');

      c.completers.first.complete(_done('/d/a.bin'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.calls, ['/v/a.bin', '/v/b.bin']);
      expect(a.status, FileDownloadTaskStatus.done);
      expect(b.status, FileDownloadTaskStatus.running);

      c.completers.last.complete(_done('/d/b.bin'));
      await b.settled;
      expect(b.status, FileDownloadTaskStatus.done);
    });

    test('取消一条不影响另一条', () async {
      final c = _Controlled();
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);
      final a = list.start(
        sourcePath: '/v/a.bin',
        name: 'a.bin',
        runner: c.runner,
      );
      final b = list.start(
        sourcePath: '/v/b.bin',
        name: 'b.bin',
        runner: c.runner,
      );
      await Future<void>.delayed(Duration.zero);
      list.cancel(a.id);
      await a.settled;
      expect(a.status, FileDownloadTaskStatus.cancelled);
      expect(b.status, FileDownloadTaskStatus.queued, reason: '取消不牵连排队者');
      c.completers.first.complete(_done('/d/a.bin'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.calls, ['/v/a.bin', '/v/b.bin']);
      c.completers.last.complete(_done('/d/b.bin'));
      await b.settled;
      expect(b.status, FileDownloadTaskStatus.done);
    });

    // ★ DA101 守卫（r447 新登记并当轮修掉）：**进度 tick 必须让任务行重建**。
    //   修前 `FileDownloadSession.report()` 只写 `progress`（`ValueNotifier`），
    //   而任务行 `ListenableBuilder` 监听的是 `FileDownloadTask`（`ChangeNotifier`）
    //   ⇒ 进度条/百分比只在**状态变化**时刷新。真机读数：文字停在
    //   `267 MB / 4.4 GB · 5%`，同一时刻 `.sydownload` 已从 487 MB 涨到 673 MB。
    test('★ DA101：进度 tick 按整数百分比通知（否则进度条只在状态变化时刷新）', () async {
      final c = _Controlled();
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);
      final t = list.start(
        sourcePath: '/v/a.bin',
        name: 'a.bin',
        runner: c.runner,
      );
      await Future<void>.delayed(Duration.zero);
      final session = c.sessions.single;
      var notified = 0;
      t.addListener(() => notified++);

      session.report(500, 1000); // 0% → 50%
      expect(
        notified,
        greaterThan(0),
        reason: 'DA101：进度变化必须通知，否则进度条/百分比只在状态变化时刷新',
      );
      final afterFirst = notified;

      session.report(500, 1000); // 同一值 ⇒ 不重复通知
      expect(notified, afterFirst, reason: 'DA101：同值重复上报不该白重建');
      session.report(505, 1000); // 仍 50% ⇒ 不重复通知
      expect(notified, afterFirst, reason: 'DA101：百分比没变就不该重建');

      session.report(600, 1000); // 50% → 60%
      expect(notified, greaterThan(afterFirst), reason: 'DA101：百分比变了必须重建');
      expect(t.percent, 60);
      expect(t.received, 600);
    });
  });

  group('复用 .sydownload 续传（真引擎 + 假 Range）', () {
    test('暂停 → 继续：从已下载的字节处发 Range，最终文件完整', () async {
      final dir = await _tmp();
      final payload = List<int>.generate(16, (i) => i);
      final f = _Fetcher(payload)..pauseOnce = true;
      final store = FileResumeStore(dir);
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);
      final task = list.start(
        sourcePath: '/v/a.bin',
        name: 'a.bin',
        runner: _runner(dir, store, f),
      );
      final temp = File('${dir.path}/a.bin${FileDownloadResumer.tempSuffix}');
      // ★ r447：先等**那一半真的落盘**（条件等待，不是"睡两轮 microtask"）
      final wrote = await pollUntilAsync(
        () async => await temp.exists() && await temp.length() > 0,
        timeout: const Duration(seconds: 5),
      );
      expect(wrote, isTrue, reason: '第一次请求要先写下一半（真落盘）');
      list.pause(task.id);
      expect(task.status, FileDownloadTaskStatus.paused);
      f.pauseGate.complete(); // 放行对手方抛出"取消" ⇒ 续传引擎按"暂停"归类
      expect(await temp.exists(), isTrue, reason: '暂停保留 .sydownload 临时文件');

      list.resume(task.id);
      await task.settled;
      expect(task.status, FileDownloadTaskStatus.done);
      expect(f.starts.first, 0);
      expect(f.starts.last, greaterThan(0), reason: '继续必须从已下载处发 Range');
      expect(await File('${dir.path}/a.bin').readAsBytes(), payload);
      expect(await temp.exists(), isFalse, reason: '完成后临时文件已改名');
    });

    // ★ DA100 守卫（r447 新登记并当轮修掉）：**快速「暂停 → 继续」**
    //   取消异常是**稍后**才回到引擎的（dio 侧 200ms 轮询兜底）；如果用户在这个窗口里
    //   就点了「继续」，旧代码拿"现在还在暂停吗"归类 ⇒ 这次取消被判成 abort
    //   ⇒ 任务显示「已取消」并停住（用户以为继续了，实际没动）。
    //   这里**故意把这个顺序钉死**：先继续、再放行迟到的取消 ⇒ 必须仍然下到完成。
    test('快速「暂停 → 继续」：迟到的取消不许把任务判成已取消（DA100）', () async {
      final dir = await _tmp();
      final payload = List<int>.generate(16, (i) => i);
      final f = _Fetcher(payload)..pauseOnce = true;
      final store = FileResumeStore(dir);
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);
      final task = list.start(
        sourcePath: '/v/a.bin',
        name: 'a.bin',
        runner: _runner(dir, store, f),
      );
      final temp = File('${dir.path}/a.bin${FileDownloadResumer.tempSuffix}');
      final wrote = await pollUntilAsync(
        () async => await temp.exists() && await temp.length() > 0,
        timeout: const Duration(seconds: 5),
      );
      expect(wrote, isTrue, reason: '第一次请求要先写下一半（真落盘）');
      list.pause(task.id);
      expect(task.status, FileDownloadTaskStatus.paused);
      list.resume(task.id); // ← 抢在"取消"回到引擎之前先按继续
      expect(task.status, FileDownloadTaskStatus.running);
      f.pauseGate.complete(); // ← 迟到的取消这时才回到引擎
      await task.settled;
      expect(
        task.status,
        FileDownloadTaskStatus.done,
        reason: 'DA100：这次取消是「暂停」引起的，不许归成「用户取消」',
      );
      expect(f.starts.length, 2, reason: 'DA100：继续后要真的再发一次请求');
      expect(
        f.starts.last,
        greaterThan(0),
        reason: 'DA100：接着已下载处继续，不是从 0 重来',
      );
      expect(await File('${dir.path}/a.bin').readAsBytes(), payload);
      expect(await temp.exists(), isFalse, reason: '完成后临时文件已改名');
    });

    test('失败 → 重试：接着已下载的部分下，只有一份目标文件', () async {
      final dir = await _tmp();
      final payload = List<int>.generate(16, (i) => i);
      final f = _Fetcher(payload)..failOnce = true;
      final store = FileResumeStore(dir);
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);
      final task = list.start(
        sourcePath: '/v/a.bin',
        name: 'a.bin',
        runner: _runner(dir, store, f),
      );
      await task.settled;
      expect(task.status, FileDownloadTaskStatus.failed);
      expect(task.error, isNotEmpty);

      list.retry(task.id);
      final retried = list.tasks.single;
      await retried.settled;
      expect(retried.status, FileDownloadTaskStatus.done);
      expect(f.starts.length, 2);
      expect(f.starts.last, greaterThan(0), reason: '重试不许从 0 重下一遍');
      expect(await File('${dir.path}/a.bin').readAsBytes(), payload);
      final files = await dir
          .list()
          .where((e) => e is File && e.path.contains('a.bin'))
          .toList();
      expect(files.length, 1, reason: '只有一份目标文件（不重复写/不复制）');
    });
  });

  group('完成提示可点击打开', () {
    testWidgets('列表显示多条任务；完成后「打开」按钮可用并触发打开器', (tester) async {
      final c = _Controlled();
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);
      list.start(sourcePath: '/v/a.bin', name: 'a.bin', runner: c.runner);
      list.start(sourcePath: '/v/b.bin', name: 'b.bin', runner: c.runner);
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileDownloadTasksDialog(
              controller: list,
              openHandler: (p) async => opened.add(p),
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('a.bin'), findsOneWidget);
      expect(find.text('b.bin'), findsOneWidget);
      expect(find.byKey(const Key('download-tasks-dialog')), findsOneWidget);

      c.completers.first.complete(_done('/d/a.bin'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('download-task-open-dl-0')));
      await tester.pump();
      expect(opened, ['/d/a.bin']);
    });
  });
  // ★★ 第 330 轮：**这条用例是补"仪器"** —— r329 只留下了"像素上 Open 渲染成整行
  //   实心蓝条"的现象，当时用部件树量不出来，因为我量的是**裸 `MaterialApp`**
  //   （没有 app 主题）。真正的根因在主题里：
  //   `filledButtonTheme.minimumSize = Size.fromHeight(48)` = `Size(double.infinity, 48)`
  //   ⇒ `Wrap` 给的是"宽松但有界"的约束 ⇒ 按钮**静默撑满整行**。
  //   判据钉在三处：① 真实主题下宽度有界；② 比对话框窄得多；
  //   ③ 反面：不带 `style` 的同型按钮在同一 `Wrap` 里**确实撑满**（证明判据有牙）。
  testWidgets('★★ r330：真实主题下，任务对话框的 Open/Save 必须是"内容宽"而不是整行', (
    tester,
  ) async {
    final c = _Controlled();
    final list = FileDownloadTaskList();
    addTearDown(list.dispose);
    list.start(sourcePath: '/v/a.bin', name: 'a.bin', runner: c.runner);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: FileDownloadTasksDialog(
            controller: list,
            openHandler: (p) async {},
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    c.completers.first.complete(_done('/d/a.bin'));
    await tester.pump();
    await tester.pump();
    final open = find.byKey(const ValueKey('download-task-open-dl-0'));
    final save = find.byKey(const ValueKey('download-task-save-dl-0'));
    final dialogW = tester.getSize(find.byKey(const Key('download-tasks-dialog'))).width;
    final openW = tester.getSize(open).width;
    final saveW = tester.getSize(save).width;
    expect(openW.isFinite, isTrue);
    // ★★ 判据用**绝对值**，不用"对话框的百分比"：第一次我写的是
    //   `openW < dialogW * 0.6`（=480），而**把 `style` 拿掉**做反向验证时
    //   `openW` 只涨到 **232**（对话框内部把 `Wrap` 限到 232，并不是整屏 800）
    //   ⇒ **反向验证居然是绿的**（判据没有牙）。实测两档读数：
    //   **带 `style` = 91.0 / 不带 = 232.0** ⇒ 阈值取 **160** 才分得开。
    //   （教训与 §2.0.30 同族：判据要钉在"机制量"上，"相对某个大容器的比例"会被容器内边距掩盖。）
    const kWideLimit = 160.0;
    expect(
      openW,
      lessThan(kWideLimit),
      reason: '★ Open 必须是"内容宽"（实测带 style=91.0 / 不带=232.0）：open=$openW',
    );
    expect(
      saveW,
      lessThan(kWideLimit),
      reason: 'Save 同样是内容宽（实测 ~106）：save=$saveW',
    );
    expect(dialogW, greaterThan(kWideLimit * 2), reason: '对话框要足够宽，否则这条判据没意义：$dialogW');
    expect(tester.getSize(open).height, greaterThanOrEqualTo(48));

    // 反面：**不带** `style` 的实心按钮放进 `Wrap` ⇒ 撑满整行（同根的"病"）
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: SizedBox(
            width: 400,
            child: Wrap(
              children: [
                FilledButton(onPressed: null, child: Text('bare')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.getSize(find.text('bare')).width,
      greaterThan(0),
    );
    final bareW = tester
        .getSize(find.widgetWithText(FilledButton, 'bare'))
        .width;
    expect(
      bareW,
      greaterThan(300),
      reason: '★ 主题的 `Size.fromHeight(48)` 在 `Wrap` 里会撑满 ⇒ 反向判据必须成立'
          '（否则上一条断言没有牙）：bare=$bareW',
    );
  });

}
