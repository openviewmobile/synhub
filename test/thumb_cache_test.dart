// 缩略图缓存管线（`ThumbCache`）的离线测试。
//
// 这一层最容易出的不是"取不到图"，而是：重复请求、失败后狂重试、
// 内存不设上限、把失败页当图缓存下来。测试就盯着这几件事。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/media/thumb_cache.dart';

Uint8List bytesOf(int n, [int seed = 0]) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i + seed) % 256));

void main() {
  late int calls;
  late List<String> asked;
  late ThumbCache cache;

  ThumbCache build({
    Future<Uint8List> Function(String path, String size)? loader,
    Future<Directory?> Function()? directory,
    int memoryBytes = 1 << 20,
    int maxConcurrent = 4,
    Duration negativeTtl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) {
    calls = 0;
    asked = [];
    cache = ThumbCache(
      loader: (path, size) {
        calls++;
        asked.add('$path|$size');
        return loader?.call(path, size) ?? Future.value(bytesOf(100));
      },
      directory: directory,
      memoryBytes: memoryBytes,
      maxConcurrent: maxConcurrent,
      negativeTtl: negativeTtl,
      now: now,
    );
    return cache;
  }

  test('第一次取要请求，第二次同键走内存（不再请求）', () async {
    build();
    final first = await cache.get('k1', '/home/a.png');
    expect(first, isNotNull);
    expect(calls, 1);

    final second = await cache.get('k1', '/home/a.png');
    expect(second, first);
    expect(calls, 1, reason: '第二次必须命中内存');
    expect(cache.stats.hits, 1);
  });

  test('不同键（mtime 变了）→ 重新取，老图被新图顶掉', () async {
    build(
      loader: (path, size) async {
        // 用调用次数当"图片内容"，能看出有没有拿到新图
        return bytesOf(10, calls * 17);
      },
    );
    final oldKey = thumbKey('/home/a.png', mtime: 1000, bytes: 10);
    final newKey = thumbKey('/home/a.png', mtime: 2000, bytes: 10);
    expect(oldKey, isNot(newKey), reason: 'mtime 要进缓存键，否则改图不刷新');

    final a = await cache.get(oldKey, '/home/a.png');
    final b = await cache.get(newKey, '/home/a.png');
    expect(calls, 2);
    expect(a, isNot(b));
  });

  test('失败 → 负缓存：短时间内不再打服务端，返回 null', () async {
    var fail = true;
    build(
      loader: (path, size) async {
        if (fail) throw const SocketException('boom');
        return bytesOf(5);
      },
    );

    expect(await cache.get('k1', '/home/bad.png'), isNull);
    expect(calls, 1);

    // 负缓存期内：不再请求，还是 null
    expect(await cache.get('k1', '/home/bad.png'), isNull);
    expect(calls, 1, reason: '失败要记住，别在滚动时反复撞');

    // 失败不该留下任何"图"
    expect(cache.memoryCount, 0);

    // 过 TTL 后再试 → 这次成功
    fail = false;
    final later = build(
      loader: (path, size) async => bytesOf(5),
      negativeTtl: Duration.zero,
    );
    expect(await later.get('k1', '/home/bad.png'), isNotNull);
  });

  test('负缓存过期后会重新请求（时间可注入）', () async {
    var t = DateTime(2026, 1, 1);
    var fail = true;
    build(
      now: () => t,
      negativeTtl: const Duration(minutes: 5),
      loader: (path, size) async {
        if (fail) throw StateError('nope');
        return bytesOf(8);
      },
    );

    expect(await cache.get('k1', '/home/c.png'), isNull);
    expect(calls, 1);
    t = t.add(const Duration(minutes: 6)); // 超过 TTL
    fail = false;
    expect(await cache.get('k1', '/home/c.png'), isNotNull);
    expect(calls, 2);
  });

  test('并发同键合并成一个请求（列表重复 build 不会打爆服务端）', () async {
    final gate = Completer<void>();
    build(
      loader: (path, size) async {
        await gate.future;
        return bytesOf(42);
      },
    );

    final futures = [
      cache.get('k1', '/home/a.png'),
      cache.get('k1', '/home/a.png'),
      cache.get('k1', '/home/a.png'),
    ];
    gate.complete();
    final results = await Future.wait(futures);

    expect(calls, 1, reason: '同键并发只请求一次');
    expect(results.every((r) => r != null), isTrue);
    expect(results[0], results[1]);
    expect(cache.stats.deduped, 2);
  });

  test('并发上限：同时在飞的请求不超过 maxConcurrent', () async {
    var inFlight = 0;
    var peak = 0;
    build(
      maxConcurrent: 2,
      loader: (path, size) async {
        inFlight++;
        peak = peak > inFlight ? peak : inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return bytesOf(3);
      },
    );

    await Future.wait([
      for (var i = 0; i < 8; i++) cache.get('k$i', '/home/$i.png'),
    ]);
    expect(calls, 8);
    expect(peak, lessThanOrEqualTo(2), reason: '限流没生效会把服务端打爆');
  });

  test('内存 LRU：超上限淘汰最久未用的', () async {
    build(memoryBytes: 250); // 每张 100 字节 → 只放得下 2 张
    await cache.get('k1', '/a.png');
    await cache.get('k2', '/b.png');
    await cache.get('k3', '/c.png'); // 挤掉 k1
    expect(cache.memoryCount, 2);
    expect(cache.memoryUsed, lessThanOrEqualTo(250));

    calls = 0;
    await cache.get('k2', '/b.png'); // 还在
    expect(calls, 0);
    await cache.get('k1', '/a.png'); // 被淘汰了 → 重新取
    expect(calls, 1);
  });

  test('单张图超过内存上限 → 不缓存它（但不影响这次显示）', () async {
    build(memoryBytes: 50, loader: (path, size) async => bytesOf(100));
    final big = await cache.get('k1', '/big.png');
    expect(big, isNotNull);
    expect(cache.memoryCount, 0, reason: '放不下的图别硬塞');
  });

  test('磁盘缓存：第二次（新实例）不再请求网络', () async {
    final dir = await Directory.systemTemp.createTemp('thumb_cache_test');
    addTearDown(() => dir.delete(recursive: true));

    build(directory: () async => dir);
    expect(await cache.get('k1', '/home/a.png'), isNotNull);
    expect(calls, 1);
    // 等落盘（write 是 fire-and-forget）
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(dir.listSync().whereType<File>(), isNotEmpty);

    // 新实例：内存是空的，但磁盘还在
    build(directory: () async => dir);
    final again = await cache.get('k1', '/home/a.png');
    expect(again, isNotNull);
    expect(calls, 0, reason: '磁盘命中就不该再请求');
    expect(cache.stats.hits, 1);
  });

  test('clearDisk 删掉磁盘缓存并返回释放的字节数', () async {
    final dir = await Directory.systemTemp.createTemp('thumb_cache_clear');
    addTearDown(() => dir.delete(recursive: true));
    build(directory: () async => dir);
    await cache.get('k1', '/home/a.png');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final freed = await cache.clearDisk();
    expect(freed, greaterThan(0));
    expect(dir.listSync(), isEmpty);
  });

  test('thumbKey 把 size / mtime / 字节数都编进去', () {
    final a = thumbKey('/home/a.png', size: 'small', mtime: 1, bytes: 2);
    expect(a, contains('small'));
    expect(a, contains('/home/a.png'));
    expect(a, contains(':1'));
    expect(a, contains(':2'));
    expect(
      a,
      isNot(thumbKey('/home/a.png', size: 'large', mtime: 1, bytes: 2)),
    );
    expect(
      a,
      isNot(thumbKey('/home/a.png', size: 'small', mtime: 9, bytes: 2)),
    );
    expect(
      a,
      isNot(thumbKey('/home/a.png', size: 'small', mtime: 1, bytes: 3)),
    );
  });
}
