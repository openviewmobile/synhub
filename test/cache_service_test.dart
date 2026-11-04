// Phase 9：附件缓存的容量管理（对齐原版 Cache management，且修掉原版的缺陷）。
//
// 原版 `DownloadCache` 把上限硬编码成 500MB、不读 `set_cache_limit`，
// 设置改了重启就失效；我们按设置里的值真的淘汰。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/media/cache_service.dart';

void main() {
  late Directory root;
  late CacheService cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cache_test_');
    cache = CacheService(root: root);
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> write(String name, int bytes, {DateTime? at}) async {
    final path = await cache.pathFor(bytes, name);
    final f = File(path);
    await f.writeAsBytes(List.filled(bytes, 7));
    if (at != null) await f.setLastModified(at);
    return path;
  }

  test('落盘路径在缓存子目录里，文件名做了安全化', () async {
    final p = await cache.pathFor(42, '季度 报告/2026.pdf');
    expect(p, contains('chat_cache'));
    expect(p, contains('f42_'));
    expect(p, isNot(contains('/2026')));
    expect(p, endsWith('.pdf'));
  });

  test('用量统计 = 文件大小之和与个数', () async {
    await write('a.bin', 1000);
    await write('b.bin', 2000);
    final u = await cache.usage(limitBytes: 524288000);
    expect(u.bytes, 3000);
    expect(u.files, 2);
    expect(u.limit, 524288000);
    expect(u.overLimit, isFalse);
    expect(u.humanSize, '2.9 KB');
  });

  test('超限时按 mtime 从最久未用开始删，正好降到上限以内', () async {
    final old1 = DateTime.now().subtract(const Duration(days: 3));
    final old2 = DateTime.now().subtract(const Duration(days: 2));
    await write('old1.bin', 1000, at: old1);
    await write('old2.bin', 1000, at: old2);
    final fresh = await write('new.bin', 1000); // 最新

    // 3000 → 删最旧(1000)=2000 仍超 → 再删次旧(1000)=1000 ≤ 1500 停止
    final freed = await cache.enforceLimit(1500);
    expect(freed, 2000);
    final u = await cache.usage();
    expect(u.bytes, 1000);
    expect(File(fresh).existsSync(), isTrue, reason: '最新的那份必须留着');
    final left = Directory(
      '${root.path}/chat_cache',
    ).listSync().whereType<File>();
    expect(left.length, 1);
    expect(left.single.path, fresh);
  });

  test('protect 里的文件不会被删（正在用的那份）', () async {
    final keep = await write(
      'keep.bin',
      3000,
      at: DateTime.now().subtract(const Duration(days: 9)),
    );
    await write('other.bin', 3000, at: DateTime.now());

    await cache.enforceLimit(1000, protect: {keep});
    expect(File(keep).existsSync(), isTrue, reason: '正在读的文件不能删');
  });

  test('上限为 0（不限制）时什么都不删', () async {
    await write('a.bin', 5000);
    expect(await cache.enforceLimit(0), 0);
    expect((await cache.usage()).bytes, 5000);
  });

  test('clear 清空并返回释放的字节数', () async {
    await write('a.bin', 1000);
    await write('b.bin', 2000);
    final freed = await cache.clear();
    expect(freed, 3000);
    final u = await cache.usage();
    expect(u.bytes, 0);
    expect(u.files, 0);
  });

  test('touch 刷新 mtime（命中缓存算"刚用过"）', () async {
    final p = await write(
      'a.bin',
      100,
      at: DateTime.now().subtract(const Duration(days: 5)),
    );
    final before = File(p).lastModifiedSync();
    await cache.touch(p);
    expect(File(p).lastModifiedSync().isAfter(before), isTrue);
  });

  // ---------------------------------------------------------------- DA83

  test('DA83：登记表里的其它可再生缓存也计入用量、也一起清掉', () async {
    await write('a.bin', 1000); // chat_cache
    void put(String sub, String file, int bytes) {
      final d = Directory('${root.path}/$sub')..createSync(recursive: true);
      File('${d.path}/$file').writeAsBytesSync(List.filled(bytes, 1));
    }

    put('video_frames', 'x.vframe', 4096);
    put('office_doc_images', 'y.png', 2048);
    put('office_thumbs', 'z.png', 1024);
    put('pdf_renderer_cache', 'p.bin', 512);

    const total = 1000 + 4096 + 2048 + 1024 + 512;
    var u = await cache.usage();
    expect(u.bytes, total, reason: '改前这里只有 1000（视频帧/Office 图都不算）');
    expect(u.files, 5);

    expect(await cache.clear(), total);
    u = await cache.usage();
    expect(u.bytes, 0);
    for (final sub in [
      'video_frames',
      'office_doc_images',
      'office_thumbs',
      'pdf_renderer_cache',
    ]) {
      expect(Directory('${root.path}/$sub').listSync(), isEmpty, reason: sub);
    }
  });

  test('DA83：登记表外的目录一个都不许动（离线保存/分享副本/系统目录）', () async {
    const outOfScope = [
      'saf_ondemand', // Drive 按需下载（用户显式要的）
      'share_in', // 入站分享副本（用户内容）
      'photo_backup', // 相册备份暂存
      'WebView', // Chromium 自己管理
      'voice', // 语音临时件
      'video_frame_tmp', // 抽帧中间件
      'file_picker', // 第三方插件
    ];
    for (final name in outOfScope) {
      final d = Directory('${root.path}/$name')..createSync(recursive: true);
      File('${d.path}/keep.bin').writeAsBytesSync(List.filled(512, 3));
    }
    await write('a.bin', 1000);

    final u = await cache.usage();
    expect(u.bytes, 1000, reason: '表外的目录不计入用量');
    expect(await cache.clear(), 1000);
    for (final name in outOfScope) {
      final files = Directory('${root.path}/$name').listSync().whereType<File>();
      expect(files.length, 1, reason: '$name 里的文件必须还在（不许"顺手清全目录"）');
    }
  });

  test('DA83：上限淘汰跨目录按 mtime 统一排序（视频帧也会被淘汰）', () async {
    await write('new.bin', 1000); // chat_cache，最新
    final vf = Directory('${root.path}/video_frames')
      ..createSync(recursive: true);
    final old = File('${vf.path}/old.vframe')
      ..writeAsBytesSync(List.filled(1000, 9));
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 7)));

    expect(await cache.enforceLimit(1000), 1000);
    expect(old.existsSync(), isFalse, reason: '最久未用的视频帧先被淘汰');
    expect((await cache.usage()).bytes, 1000);
  });

  test('humanBytes 常见档位', () {
    expect(humanBytes(0), '0 B');
    expect(humanBytes(10485760), '10 MB');
    expect(humanBytes(524288000), '500 MB');
    expect(humanBytes(1073741814), '1.0 GB');
  });
}
