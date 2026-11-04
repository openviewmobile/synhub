// P0-b：下载断点续传引擎（`FileDownloadResumer`）的离线单测。
//
// 这里用**专用假 Range 取数口**（`FakeRangeFetcher`）而不联网，也不碰设备；
// API 参数形状由 `filestation_api_test.dart` / UI 用例用 FakeTransport 覆盖。
//
// 官方对照（`sylibx/sydownloadmanager/services/DownloadTask.java`）：
//   * `:165-167` `Range: bytes=<mTempFile.length()>-`；
//   * `:179-206` `mTotalSize = contentLength + mPreviousFileSize`，收完必须相等；
//   * `DownloadManager.pauseTask()` 保留临时文件，`deleteTask()` 才删。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_download_resume.dart';

/// 假 Range 取数口：按 [bytes] 回放，可选择"服务端忽略 Range"。
class FakeRangeFetcher implements RangeByteFetcher {
  FakeRangeFetcher(
    this.bytes, {
    this.supportsRange = true,
    this.rangeOverride,
    this.throwPauseAfter,
    this.throwIncomplete,
  });

  final List<int> bytes;

  /// false = 服务端不支持 Range：start > 0 时回 200 且**不写正文**
  final bool supportsRange;

  /// 自定义 Content-Range（验 206 校验点）
  final String? rangeOverride;

  /// 写到第 N 字节后模拟"用户暂停"（抛取消 + isPaused=true）
  final int? throwPauseAfter;

  /// true = 206 的 Content-Range 总长比正文短（验收完校验）
  final bool? throwIncomplete;

  final List<int> requestedStarts = [];

  @override
  Future<RangeFetchOutcome> fetchRange(
    String url, {
    required int start,
    required IOSink sink,
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
  }) async {
    requestedStarts.add(start);
    if (start > 0 && !supportsRange) {
      return RangeFetchOutcome(statusCode: 200, contentLength: bytes.length);
    }
    final remaining = start == 0 ? bytes : bytes.sublist(start);
    if (throwPauseAfter != null) {
      sink.add(remaining.sublist(0, throwPauseAfter!));
      await sink.flush();
      throw const DownloadCancelledException();
    }
    sink.add(remaining);
    await sink.flush();
    if (start == 0) {
      return RangeFetchOutcome(statusCode: 200, contentLength: bytes.length);
    }
    final total = throwIncomplete == true ? 1 : bytes.length;
    return RangeFetchOutcome(
      statusCode: 206,
      contentRange: rangeOverride ?? 'bytes $start-${bytes.length - 1}/$total',
      contentLength: remaining.length,
    );
  }
}

Future<Directory> _tmpDir() async {
  final dir = await Directory.systemTemp.createTemp('fs_resume_test');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

void main() {
  final payload = List<int>.generate(8, (i) => i); // 0..7

  test('续传：临时文件有 4 字节 → 从 4 发 Range，206 校验后只追加剩余', () async {
    final dir = await _tmpDir();
    final temp = File('${dir.path}/a.bin${FileDownloadResumer.tempSuffix}');
    await temp.writeAsBytes(payload.sublist(0, 4));
    final fetcher = FakeRangeFetcher(payload);

    final outcome =
        await FileDownloadResumer(
          fetcher: fetcher,
          store: FileResumeStore(dir),
        ).download(
          sourcePath: '/home/a.bin',
          url: 'https://nas/entry.cgi?api=Download',
          fileName: 'a.bin',
          directory: dir,
        );

    expect(fetcher.requestedStarts, [4], reason: '必须从已下载的 4 字节续');
    expect(outcome.resumedFrom, 4);
    expect(outcome.fullRestart, isFalse);
    expect(outcome.totalBytes, 8);
    expect(await File('${dir.path}/a.bin').readAsBytes(), payload);
    expect(await temp.exists(), isFalse, reason: '收完临时文件要被改名掉');
  });

  test('无元数据也能续（进程重启）：临时文件在、.resume.json 不在', () async {
    final dir = await _tmpDir();
    final temp = File('${dir.path}/a.bin${FileDownloadResumer.tempSuffix}');
    await temp.writeAsBytes(payload.sublist(0, 3));
    final fetcher = FakeRangeFetcher(payload);

    await FileDownloadResumer(
      fetcher: fetcher,
      store: FileResumeStore(dir),
    ).download(
      sourcePath: '/home/a.bin',
      url: 'https://nas/entry.cgi?api=Download',
      fileName: 'a.bin',
      directory: dir,
    );

    expect(fetcher.requestedStarts, [3]);
  });

  test('服务端不支持 Range（忽略 Range 回 200）→ 诚实降级整份重下', () async {
    final dir = await _tmpDir();
    final temp = File('${dir.path}/a.bin${FileDownloadResumer.tempSuffix}');
    await temp.writeAsBytes(payload.sublist(0, 4));
    final fetcher = FakeRangeFetcher(payload, supportsRange: false);

    final outcome =
        await FileDownloadResumer(
          fetcher: fetcher,
          store: FileResumeStore(dir),
        ).download(
          sourcePath: '/home/a.bin',
          url: 'https://nas/entry.cgi?api=Download',
          fileName: 'a.bin',
          directory: dir,
        );

    expect(fetcher.requestedStarts, [4, 0], reason: '先试探 Range，被 200 拒后从 0 重来');
    expect(outcome.fullRestart, isTrue);
    expect(await File('${dir.path}/a.bin').readAsBytes(), payload);
  });

  test('206 起点与本地已有字节不符 → 抛 incomplete，不拼接损坏文件', () async {
    final dir = await _tmpDir();
    final temp = File('${dir.path}/a.bin${FileDownloadResumer.tempSuffix}');
    await temp.writeAsBytes(payload.sublist(0, 4));
    // 服务端错回 bytes 0-7/8（起点 0，而我们有 4）
    final fetcher = FakeRangeFetcher(payload, rangeOverride: 'bytes 0-7/8');

    expect(
      () => FileDownloadResumer(fetcher: fetcher, store: FileResumeStore(dir))
          .download(
            sourcePath: '/home/a.bin',
            url: 'https://nas/entry.cgi?api=Download',
            fileName: 'a.bin',
            directory: dir,
          ),
      throwsA(isA<FileDownloadIncompleteException>()),
    );
  });

  test('206 缺 Content-Range → 抛 incomplete（206 校验点①）', () async {
    final dir = await _tmpDir();
    await File(
      '${dir.path}/a.bin${FileDownloadResumer.tempSuffix}',
    ).writeAsBytes(payload.sublist(0, 4));
    // rangeOverride 为空串 → 解析失败
    final fetcher = FakeRangeFetcher(payload, rangeOverride: 'not-a-range');

    expect(
      () => FileDownloadResumer(fetcher: fetcher, store: FileResumeStore(dir))
          .download(
            sourcePath: '/home/a.bin',
            url: 'https://nas/entry.cgi?api=Download',
            fileName: 'a.bin',
            directory: dir,
          ),
      throwsA(isA<FileDownloadIncompleteException>()),
    );
  });

  test('206 总长不大于终点 → 抛 incomplete（206 校验点③）', () async {
    final dir = await _tmpDir();
    await File(
      '${dir.path}/a.bin${FileDownloadResumer.tempSuffix}',
    ).writeAsBytes(payload.sublist(0, 4));
    final fetcher = FakeRangeFetcher(
      payload,
      rangeOverride: 'bytes 4-7/4', // 总长 4 <= 终点 7
    );

    expect(
      () => FileDownloadResumer(fetcher: fetcher, store: FileResumeStore(dir))
          .download(
            sourcePath: '/home/a.bin',
            url: 'https://nas/entry.cgi?api=Download',
            fileName: 'a.bin',
            directory: dir,
          ),
      throwsA(isA<FileDownloadIncompleteException>()),
    );
  });

  test('暂停：保留临时文件（已下载字节不丢），不落最终文件', () async {
    final dir = await _tmpDir();
    final fetcher = FakeRangeFetcher(payload, throwPauseAfter: 3);
    var paused = false;

    await expectLater(
      () => FileDownloadResumer(fetcher: fetcher, store: FileResumeStore(dir))
          .download(
            sourcePath: '/home/a.bin',
            url: 'https://nas/entry.cgi?api=Download',
            fileName: 'a.bin',
            directory: dir,
            cancelToken: DownloadCancelToken(),
            isPaused: () => true,
          ),
      throwsA(isA<FileDownloadPausedException>()),
    );
    paused = true;
    expect(paused, isTrue);

    final temp = File('${dir.path}/a.bin${FileDownloadResumer.tempSuffix}');
    expect(await temp.exists(), isTrue, reason: '暂停必须保留临时文件');
    expect(await temp.length(), 3);
    expect(await File('${dir.path}/a.bin').exists(), isFalse);
  });

  test('取消（非暂停）同样保留临时文件 —— 删不删由调用方决定', () async {
    final dir = await _tmpDir();
    final fetcher = FakeRangeFetcher(payload, throwPauseAfter: 2);

    await expectLater(
      () => FileDownloadResumer(fetcher: fetcher, store: FileResumeStore(dir))
          .download(
            sourcePath: '/home/a.bin',
            url: 'https://nas/entry.cgi?api=Download',
            fileName: 'a.bin',
            directory: dir,
            cancelToken: DownloadCancelToken(),
            isPaused: () => false,
          ),
      throwsA(isA<DownloadCancelledException>()),
    );
    final temp = File('${dir.path}/a.bin${FileDownloadResumer.tempSuffix}');
    expect(await temp.exists(), isTrue);
    expect(await temp.length(), 2);
  });

  test('断点元数据落盘：save / totalFor / remove 往返（重启后可读）', () async {
    final dir = await _tmpDir();
    final store = FileResumeStore(dir);
    expect(await store.totalFor('/home/a.bin'), isNull);
    await store.save('/home/a.bin', 4096);
    expect(await store.totalFor('/home/a.bin'), 4096);
    // 重新构造一个 store（模拟进程重启）仍读得到
    expect(await FileResumeStore(dir).totalFor('/home/a.bin'), 4096);
    await store.remove('/home/a.bin');
    expect(await store.totalFor('/home/a.bin'), isNull);
  });

  test('已存在且长度对得上的目标文件直接复用，不再发请求', () async {
    final dir = await _tmpDir();
    await File('${dir.path}/a.bin').writeAsBytes(payload);
    await FileResumeStore(dir).save('/home/a.bin', payload.length);
    final fetcher = FakeRangeFetcher(payload);

    final outcome =
        await FileDownloadResumer(
          fetcher: fetcher,
          store: FileResumeStore(dir),
        ).download(
          sourcePath: '/home/a.bin',
          url: 'https://nas/entry.cgi?api=Download',
          fileName: 'a.bin',
          directory: dir,
        );

    expect(fetcher.requestedStarts, isEmpty);
    expect(outcome.totalBytes, payload.length);
  });

  test('未记录的旧临时文件 + 206 给总长 → 收完落盘并清掉元数据', () async {
    final dir = await _tmpDir();
    // 没有 .resume.json，直接留半截临时文件
    await File(
      '${dir.path}/a.bin${FileDownloadResumer.tempSuffix}',
    ).writeAsBytes(payload.sublist(0, 4));
    final store = FileResumeStore(dir);
    final fetcher = FakeRangeFetcher(payload);

    await FileDownloadResumer(fetcher: fetcher, store: store).download(
      sourcePath: '/home/a.bin',
      url: 'https://nas/entry.cgi?api=Download',
      fileName: 'a.bin',
      directory: dir,
    );

    expect(await File('${dir.path}/a.bin').readAsBytes(), payload);
    expect(await store.totalFor('/home/a.bin'), isNull);
  });

  group('FileDownloadSession', () {
    test('暂停 → 取消令牌生效；继续 → 换新令牌且放行等待', () async {
      final session = FileDownloadSession('a.bin');
      addTearDown(session.dispose);
      final gate = session.waitForResume();
      expect(session.cancelToken.isCancelled, isFalse);

      session.pause();
      expect(session.isPaused, isTrue);
      expect(session.cancelToken.isCancelled, isTrue);

      final old = session.cancelToken;
      session.resume();
      expect(session.isPaused, isFalse);
      expect(identical(session.cancelToken, old), isFalse);
      expect(session.cancelToken.isCancelled, isFalse);
      await gate; // 被放行，不会挂住
    });

    test('取消会放行挂起的 waitForResume（否则下载循环永久等待）', () async {
      final session = FileDownloadSession('a.bin');
      addTearDown(session.dispose);
      session.pause();
      final gate = session.waitForResume();
      session.cancel();
      session.releaseGate();
      await gate;
      expect(session.isCancelled, isTrue);
    });
  });
}
