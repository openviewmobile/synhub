// r444 · §二点九-5「设置页「缓存用量」的每次扫描成本」—— **扫描成本量表**（只读/自造临时目录）。
//
// 为什么要有这张表：`CacheService.usage()` 每次进设置页都算一遍，而
// `enforceLimit()` **被 await 在「保存附件/下载文件」的收尾路径里**
// （`attachment_view.dart` / `chat_session_controller.dart`）——
// 两者都是"走完登记表里每个目录 ＋ 每个文件一次 `length()`"。
// 于是"贵不贵"是个**可量的问题**，不该靠感觉说"暂不需要优化"。
//
// 做法：在临时 root 下按 `kRegenerableCacheDirs` 造 N 个文件，逐档量墙钟；
// 判据 = **线性**（每文件微秒数稳定），并给出可复算的读数。
//
// ★ 边界（如实）：这是**宿主 FS** 的成本模型（APFS），不是 Android 的；
//   设备侧读数在 `docs/evidence-r444/`（真机注入 N 个文件后进设置页）。
//   两者一起才说明"这台机器上到底贵不贵"。
//
// 运行：flutter test -r expanded tool/r444_cache_scan_cost_probe_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/media/cache_service.dart';

void main() {
  late Directory root;
  late CacheService cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('r444_cost_');
    cache = CacheService(root: root);
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  /// 按登记表把 [count] 个文件摊到各目录（每目录直接子文件，不建子目录）
  Future<int> seed(int count, {int bytes = 4096}) async {
    final dirs = <Directory>[];
    for (final e in kRegenerableCacheDirs) {
      final d = await cache.cacheDirFor(e);
      if (!await d.exists()) await d.create(recursive: true);
      dirs.add(d);
    }
    var made = 0;
    for (var i = 0; i < count; i++) {
      final d = dirs[i % dirs.length];
      final f = File('${d.path}/r444_$i.bin');
      await f.writeAsBytes(List<int>.filled(bytes, 7), flush: false);
      made++;
    }
    return made;
  }

  String us(int micros) => '${(micros / 1000).toStringAsFixed(1)} ms';

  test('成本量表：usage / enforceLimit / clear 随文件数（宿主 FS）', () async {
    final rows = <String>[];
    for (final n in <int>[0, 100, 1000, 3000]) {
      // 每个档位用干净目录，避免上一档的残留混进来
      await root.delete(recursive: true);
      root = await Directory.systemTemp.createTemp('r444_cost_');
      cache = CacheService(root: root);
      final made = await seed(n);

      final sw1 = Stopwatch()..start();
      final u = await cache.usage();
      sw1.stop();

      // 上限设成「刚好装下 60%」⇒ 真的会走排序 ＋ 删除路径
      final limit = (u.bytes * 6) ~/ 10;
      final sw2 = Stopwatch()..start();
      await cache.enforceLimit(limit);
      sw2.stop();

      final sw3 = Stopwatch()..start();
      await cache.clear();
      sw3.stop();

      final perFile = made == 0 ? 0.0 : sw1.elapsedMicroseconds / made;
      rows.add(
        'N=$made files=${u.files} bytes=${u.bytes} | '
        'usage=${us(sw1.elapsedMicroseconds)} (${perFile.toStringAsFixed(1)} µs/file) | '
        'enforceLimit=${us(sw2.elapsedMicroseconds)} | '
        'clear=${us(sw3.elapsedMicroseconds)}',
      );
      // 非性能门槛，只是拒绝"量出垃圾"：3000 个文件不该慢到分钟级
      expect(sw1.elapsedMicroseconds, lessThan(30000000));
    }
    // ignore: avoid_print
    print('=== r444 缓存扫描成本量表（宿主 FS，每文件 4 KB）===');
    for (final r in rows) {
      // ignore: avoid_print
      print(r);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
