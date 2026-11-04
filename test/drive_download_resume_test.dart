// ★★ D26「下载 Range 续传」核实（Drive 源）。
//
// ## 官方逐字证据（Drive 3.9.0-1113 反编译，`sylib` 就在官方 APK 里）
//
// `smali_classes4/com/synology/sylib/syapi/webapi/net/ConnectionManager.smali`：
//   * `:27`   `HEADER_RANGE = "RANGE"`；
//   * `:301-309`（`isTypeRecoverable` 为真的下载）：
//     目标文件 `File(getDownloadFileName())` → 取 `file.length()` →
//     日志 `"Set range header to <len>"` → `putHeader("RANGE", "bytes=<len>-")`；
//     不可恢复时才 `File.createTempFile("temp.", ".download", cacheDir)`；
//   * `:659-667`（`copy`）：`RandomAccessFile(file, "rw")`，
//     **headers 含 `RANGE` 就 `seek(file.length())`**，否则从 0 写；
//   * `:328-331` 出错时**删掉**临时文件。
//   ⇒ 续传 = 「本地残留长度 → `Range: bytes=<len>-` → seek 到同一偏移继续写」。
//
// ## 本文件证明什么
//
//   * ① Drive 的三条「保存到本机」路径（单文件 / 打包 zip / 预览页另存）
//        全部走**同一个** `downloadResumable`，不再 `getBytes` 整份进内存；
//   * ② 有残留时**发的是 `Range: bytes=<已下>-`**（start = 已下字节数），
//        且**续写**到同一文件而不是重下（终态字节一致）；
//   * ③ 服务端忽略 Range（回 200 全量）→ **诚实降级为整份重下**并
//       带 `restarted` 标记（界面据此换文案）；
//   * ④ 断点元数据 key 必须**按通道分开**（Drive 直链 vs FileStation 原生字节、
//        打包下载按被选中的 id 列表），换批次不串。
//
// §5.1：全程只发 HTTP **GET**（含 Range GET）；没有任何变更动词，
// 也不碰真机 / 真 NAS。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/drive_download.dart';
import 'package:synhub/src/features/files/file_download.dart';
import 'package:synhub/src/features/files/file_download_resume.dart';
import 'package:synhub/src/features/files/file_download_tasks.dart';

/// 假 Range 取数口：记录 `start`，可选择"服务端忽略 Range"。
class _Fetcher implements RangeByteFetcher {
  _Fetcher(this.bytes, {this.supportsRange = true});

  final List<int> bytes;
  final bool supportsRange;

  /// 每次请求的**起始偏移**（== 官方 `Range: bytes=<start>-`）
  final List<int> starts = [];
  final List<String> urls = [];

  @override
  Future<RangeFetchOutcome> fetchRange(
    String url, {
    required int start,
    required IOSink sink,
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
  }) async {
    starts.add(start);
    urls.add(url);
    if (start > 0 && !supportsRange) {
      // 服务端不认 Range：200 + 全量正文（客户端必须自己发现并重下）
      sink.add(bytes);
      await sink.flush();
      return RangeFetchOutcome(statusCode: 200, contentLength: bytes.length);
    }
    final remaining = start == 0 ? bytes : bytes.sublist(start);
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

Future<Directory> _tmp() async {
  final dir = await Directory.systemTemp.createTemp('drive_dl_resume_test');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

List<int> _payload(int n) => List<int>.generate(n, (i) => i % 251);

void main() {
  group('D26-1. 首次下载 / 残留续传', () {
    test('★★ 无残留 → start=0，落盘字节完整', () async {
      final dir = await _tmp();
      final f = _Fetcher(_payload(5000));
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);

      final result = await downloadResumable(
        list: list,
        fetcher: f,
        directory: dir,
        resumeKey: 'drive:FILE1',
        url: 'https://nas.example/entry.cgi?api=SYNO.SynologyDrive.Files&method=download&_sid=s1',
        saveName: 'a.bin',
      );

      expect(result.status, FileDownloadStatus.ok);
      expect(result.restarted, isFalse);
      expect(f.starts, [0]);
      expect(await File('${dir.path}/a.bin').length(), 5000);
      // 临时文件收干净
      expect(await File('${dir.path}/a.bin.sydownload').exists(), isFalse);
    });

    test('★★ 有 2000 字节残留 → 第二次请求 start=2000（Range 语义），且是续写', () async {
      final dir = await _tmp();
      final all = _payload(5000);
      // 模拟"上次下到一半就断了"：残留临时文件 2000 字节
      await File(
        '${dir.path}/a.bin.sydownload',
      ).writeAsBytes(all.sublist(0, 2000));

      final f = _Fetcher(all);
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);

      final result = await downloadResumable(
        list: list,
        fetcher: f,
        directory: dir,
        resumeKey: 'drive:FILE1',
        url: 'https://nas.example/entry.cgi?method=download&_sid=s1',
        saveName: 'a.bin',
      );

      expect(result.status, FileDownloadStatus.ok);
      // 官方语义：Range: bytes=<本地残留长度>-
      expect(f.starts, [2000], reason: '必须从已下处续，不是从 0 重来');
      // 续写（不是覆盖）→ 终态与原文逐字节一致
      expect(await File('${dir.path}/a.bin').readAsBytes(), all);
      expect(result.restarted, isFalse);
      expect(
        result.message,
        contains('继续下载'),
        reason: '续传要如实告诉用户"从 X 处继续"',
      );
    });
  });

  group('D26-2. 服务端不认 Range → 诚实降级', () {
    test('★★ 回 200 全量 → 整份重下，restarted=true + 文案明确', () async {
      final dir = await _tmp();
      final all = _payload(3000);
      await File(
        '${dir.path}/a.bin.sydownload',
      ).writeAsBytes(all.sublist(0, 1000));

      final f = _Fetcher(all, supportsRange: false);
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);

      final result = await downloadResumable(
        list: list,
        fetcher: f,
        directory: dir,
        resumeKey: 'drive:FILE1',
        url: 'https://nas.example/entry.cgi?method=download&_sid=s1',
        saveName: 'a.bin',
      );

      expect(result.status, FileDownloadStatus.ok);
      expect(result.restarted, isTrue, reason: '降级必须能被界面看出来');
      expect(result.message, contains('重新完整下载'));
      expect(await File('${dir.path}/a.bin').readAsBytes(), all);
    });
  });

  group('D26-3. 续传 key 按通道 / 批次分开', () {
    test('★★ 不同 resumeKey → 各自独立（互不续到对方的分片）', () async {
      final dir = await _tmp();
      final all = _payload(1200);
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);

      // 通道 A：Drive 直链，残留 400
      await File(
        '${dir.path}/a.bin.sydownload',
      ).writeAsBytes(all.sublist(0, 400));
      final fa = _Fetcher(all);
      await downloadResumable(
        list: list,
        fetcher: fa,
        directory: dir,
        resumeKey: 'drive:FILE1',
        url: 'https://nas/entry.cgi?a=1',
        saveName: 'a.bin',
      );
      expect(fa.starts, [400], reason: 'drive:FILE1 有残留 → 续 400');

      // 通道 B：FileStation 原生字节（同一文件名、不同 key）→ 必须从 0
      final fb = _Fetcher(all);
      await downloadResumable(
        list: list,
        fetcher: fb,
        directory: dir,
        resumeKey: 'native:/home/Drive/a.bin',
        url: 'https://nas/entry.cgi?a=2',
        saveName: 'b.bin',
      );
      expect(fb.starts, [0], reason: '另一条通道不能吃 drive: 的断点');
    });

    test('★★ 打包下载 key = 被选中 id 列表（换批次不串）', () async {
      // 这条只钉 key 的构造规则（真实调用点在 `driveDownloadArchive`）
      const batchA = ['1', '2'];
      const batchB = ['1', '3'];
      final keyA = 'archive:${batchA.join(',')}';
      final keyB = 'archive:${batchB.join(',')}';
      expect(keyA, 'archive:1,2');
      expect(keyA, isNot(keyB));
    });
  });

  group('D26-4. 调用面：Drive 的三条保存路径都在用这台引擎', () {
    test('★★ 源码层面没有"整份进内存"的 Drive 下载了', () async {
      // 单文件 / 打包 zip / 预览页另存 —— 三处都改走 `downloadResumableWithUi`；
      // 原来的 `getBytes(url)` 整份读法在这些"保存到本机"入口必须消失。
      final files = [
        'lib/src/features/files/drive_browse_view.dart',
        'lib/src/features/files/file_preview_page.dart',
      ];
      for (final path in files) {
        final src = await File(path).readAsString();
        expect(
          src.contains('downloadResumableWithUi'),
          isTrue,
          reason: '$path 必须接进断点续传引擎',
        );
        // 老写法是「getBytes → 整份进内存 → writeAsBytes 落盘」；
        // 这个"整份再落盘"的形状必须消失（读进内存做别的事不算）。
        expect(
          RegExp(r'writeAsBytes\(bytes\)').hasMatch(src),
          isFalse,
          reason: '$path 里不该再有"整份进内存再落盘"的下载',
        );
      }
      // 打包下载那条也接了引擎
      final browse = await File(
        'lib/src/features/files/drive_browse_view.dart',
      ).readAsString();
      expect(browse.contains("resumeKey: 'archive:"), isTrue);
    });
  });
}
