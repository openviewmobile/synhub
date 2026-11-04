// 302 轮：离线文件**真缓存到本机**的机制用例。
//
// 背景（真机发现，见 docs/evidence-r301/README.md 与 AGENTS §2.0.41）：
//   「加入离线文件」之前只写清单 —— `OfflinePinEntry.localPath` 全仓没有生产者，
//   于是 `hasLocalCopy` 恒 false ⇒
//     ① 清单行永远显示"未缓存"；
//     ② `buildSafIndex()` 只收 `hasLocalCopy` 的项 ⇒ **系统「文件」里的
//        Synology 位置恒为空**（"按需下载"那条路是死路）；
//     ③ 断网后打不开 —— 而"离线"的全部意义就在这里。
//
// 本文件钉的就是"字节真的落到本机"这件事，断言的是**机制量**：
// 磁盘上文件在不在、长度对不对、指纹会不会撞、取消登记后字节有没有删掉。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/files/drive_saf_index.dart';
import 'package:synhub/src/features/files/file_download_resume.dart';
import 'package:synhub/src/features/files/file_offline_pin.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r302_offline_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  OfflinePinEntry entry(String path, {String? name, int size = 0}) =>
      OfflinePinEntry(
        path: path,
        name: name ?? path.split('/').last,
        size: size,
        pinnedAt: 1700000000,
      );

  /// 假取数器：把 [bytes] 个字节真写到目标文件（**不联网**）。
  OfflineCacheFetcher writer(int bytes, {String? failWith}) {
    return ({required path, required name, required directory, onProgress}) async {
      if (failWith != null) throw StateError(failWith);
      final target = File(
        '${directory.path}/${OfflineCacher.fileNameFor(path: path, name: name)}',
      );
      await target.writeAsBytes(List<int>.filled(bytes, 0x41), flush: true);
      onProgress?.call(bytes, bytes);
      return FileDownloadOutcome(localPath: target.path, totalBytes: bytes);
    };
  }

  test('① 缓存成功：字节真的落盘，长度与 size 一致', () async {
    final cacher = OfflineCacher(
      fetcher: writer(11),
      documentsDir: () async => tmp,
    );
    final r = await cacher.cache(
      path: '/home/a/r302probe.txt',
      name: 'r302probe.txt',
    );

    expect(r.ok, isTrue, reason: '缓存必须成功');
    expect(File(r.localPath).existsSync(), isTrue, reason: '磁盘上要有这个文件');
    expect(File(r.localPath).lengthSync(), 11, reason: '字节数要对得上');
    expect(r.bytes, 11);
    // 落在私有缓存目录里，不是用户的下载/相册
    expect(r.localPath, contains(OfflineCacher.directoryName));
    expect(r.localPath, startsWith(tmp.path));
  });

  test('② 缓存失败：如实回原因，**不回滚登记**（登记是另一件事）', () async {
    final cacher = OfflineCacher(
      fetcher: writer(0, failWith: 'NAS 断线'),
      documentsDir: () async => tmp,
    );
    final r = await cacher.cache(path: '/home/a/x.bin', name: 'x.bin');

    expect(r.ok, isFalse);
    expect(r.localPath, isEmpty);
    expect(r.error, contains('NAS 断线'));
    // 失败路径**不该**把半截字节记成"已缓存"：清单里仍然是 localPath 为空。
    // （真正的续传临时文件 `.sydownload` 由 `FileDownloadResumer` 管理，
    //  那是"下次接着下"的凭据，属于另一层，这里不越权断言。）
    expect(r.localPath, isEmpty);
  });

  test('③ 文件名带路径指纹：不同目录同名文件**不互相覆盖**', () {
    String fn(String p) =>
        OfflineCacher.fileNameFor(path: p, name: 'report.pdf');
    final a = fn('/home/a/report.pdf');
    final b = fn('/home/b/report.pdf');
    final again = fn('/home/a/report.pdf');

    expect(a, isNot(b), reason: '同名不同目录必须落不同文件');
    expect(again, a, reason: '同一个路径必须稳定命中同一文件（重复缓存可复用）');
    expect(a, endsWith('_report.pdf'), reason: '人还得看得懂');
    expect(a, contains(RegExp(r'^[0-9a-f]{8}_')), reason: '前缀是 8 位十六进制指纹');
  });

  test('④ 文件名安全：带斜杠/点点/超长的名字不会跑出目录', () {
    final n1 = OfflineCacher.fileNameFor(
      path: '/home/a/x',
      name: '../../etc/passwd',
    );
    expect(n1.contains('/'), isFalse, reason: '不能带路径分隔符');
    expect(n1.contains('..'), isFalse, reason: '不能带上跳');
    // 只保留最后一段，且不含目录分隔
    expect(n1, endsWith('_etc_passwd'));

    final long = OfflineCacher.fileNameFor(
      path: '/home/a/x',
      name: '${'z' * 300}.txt',
    );
    // 8 位指纹 + 下划线 + 安全名上限
    expect(long.length, lessThanOrEqualTo(8 + 1 + 80));
    expect(long.contains('/'), isFalse);
  });

  test('⑤ 回填 localPath ⇒ hasLocalCopy 为真，且 SAF 索引**收录**它', () async {
    final cacher = OfflineCacher(
      fetcher: writer(11),
      documentsDir: () async => tmp,
    );
    final e = entry('/home/a/r302probe.txt', size: 11);
    final r = await cacher.cache(path: e.path, name: e.name);
    expect(r.ok, isTrue);

    final cached = OfflinePinEntry(
      path: e.path,
      name: e.name,
      size: e.size,
      pinnedAt: e.pinnedAt,
      localPath: r.localPath,
    );
    expect(cached.hasLocalCopy, isTrue);

    final index = buildSafIndex([cached]);
    expect(index.length, 1, reason: '已缓存的登记必须进系统选择器索引');
    expect(index.single.localPath, r.localPath);
    expect(index.single.name, 'r302probe.txt');
  });

  test('⑥ 反向验证：**没缓存**的登记不进索引（这正是修好之前的状态）', () {
    final index = buildSafIndex([entry('/home/a/r302probe.txt', size: 11)]);
    expect(
      index,
      isEmpty,
      reason: '没下载的登记进索引只会给用户一个点不开的条目 ⇒ 修好之前系统里恒为空',
    );
  });

  test('⑦ 取消登记：本地副本一并删除（不留孤儿字节）', () async {
    final dir = Directory('${tmp.path}/${OfflineCacher.directoryName}')
      ..createSync(recursive: true);
    final copy = File('${dir.path}/deadbeef_a.txt')
      ..writeAsBytesSync(List<int>.filled(4, 1));
    expect(copy.existsSync(), isTrue);

    await deleteOfflineCopy(copy.path);
    expect(copy.existsSync(), isFalse, reason: '"移出离线"必须释放本机空间');

    // 找不到文件不算错（用户清过 App 数据是正常情况）
    await deleteOfflineCopy(copy.path);
    await deleteOfflineCopy('');
  });
}
