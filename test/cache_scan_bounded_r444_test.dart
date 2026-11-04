// r444 · §二点九-5「设置页缓存用量的每次扫描成本」的**结构守卫**：
// 「成本的形状」= `CacheService._allFiles()` **只走 `kRegenerableCacheDirs` 的
// **直接子文件**（每目录一次 list + 每文件一次 length），所以
// 用量/清空/上限淘汰的成本上界 = **登记目录的直接子文件数**，不随目录树深度增长。
//
// 为什么要把它钉住（不是"随便写条用例"）：
//   * `usage()` 每次进设置页都算；`enforceLimit()` **被 await 在「保存附件 /
//     下载文件」的收尾路径里**（`attachment_view.dart` / `chat_session_controller.dart`）；
//   * 真机/宿主读数（`docs/evidence-r444/`）：线性、约 28 µs/文件（宿主 Dart 层）、
//     3,013 个文件时原生等价走查 0.14–0.16 s（含进程启动）⇒ 成本**有界**；
//   * 若将来有人把 `dir.list()` 改成递归（或让用量开始吃整棵树），
//     成本与"作用域"会同时悄悄扩大 —— 这条用例就是那种改动的红灯。
//
// ★ 登记新目录（含嵌套目录，如已登记的 `chat_cache/file_thumbs`）的**唯一**地方是
// `lib/src/core/media/cache_service.dart` 的 `kRegenerableCacheDirs`；
// 不许动的那类写 `kCacheNotRegenerable`（静态守卫见 `cache_scope_guard_test.dart`）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/media/cache_service.dart';

void main() {
  late Directory root;
  late CacheService cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('r444_bounded_');
    cache = CacheService(root: root);
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> put(String rel, String name, int bytes) async {
    final f = File('${root.path}/$rel/$name');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(List<int>.filled(bytes, 3));
    return f;
  }

  test('① 只有登记目录的**直接子文件**计入用量（深层文件不计）', () async {
    await put('video_frames', 'a.bin', 100);
    await put('video_frames', 'b.bin', 100);
    // 深层：既不是"登记目录的直接子文件"，也不是登记表里的那条嵌套目录
    await put('video_frames/sub', 'deep.bin', 9999);

    final u = await cache.usage();
    expect(u.files, 2, reason: '深层文件不许进用量（成本上界 = 直接子文件）');
    expect(u.bytes, 200);
  });

  test('② 登记表里**显式登记**的嵌套目录照算（chat_cache/file_thumbs）', () async {
    await put('chat_cache', 'c.bin', 10);
    await put('chat_cache/file_thumbs', 't.bin', 20);
    await put('chat_cache/file_thumbs/2024', 'x.bin', 9999); // 更深一层 ⇒ 不算

    final u = await cache.usage();
    expect(u.files, 2);
    expect(u.bytes, 30);
  });

  test('③ 深层文件也不会被上限淘汰删掉（用量与淘汰同一条判据）', () async {
    await put('office_thumbs', 'a.bin', 1000);
    final deep = await put('office_thumbs/nested', 'keep.bin', 1000);

    // 上限 0 = 不限制 ⇒ 什么都不删；再把上限压到 0 以下也不该碰深层文件
    expect(await cache.enforceLimit(0), 0);
    await cache.clear();
    expect(await deep.exists(), isTrue,
        reason: '登记目录的深层文件不在作用域里 ⇒ 清空缓存也不许删');
  });
}
