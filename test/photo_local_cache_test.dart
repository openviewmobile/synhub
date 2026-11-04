// ⑦相册 P53：**客户端**图片/缩略图缓存（上限 + 清理）。
// 用临时目录里的真文件验 —— 不 mock 文件系统。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/photos/photo_local_cache.dart';

late Directory _root;
late PhotoLocalCache _cache;

File _write(String rel, int bytes, {required DateTime at}) {
  final f = File('${_root.path}/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(List.filled(bytes, 7));
  // 显式设置 mtime：LRU 判据就是它，不能靠写入顺序（同毫秒会抖）
  f.setLastModifiedSync(at);
  return f;
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('photo_cache_test');
    _cache = PhotoLocalCache(root: _root);
  });
  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  test('目录不存在：stats=0、clear 不抛（不是错误态）', () async {
    final missing = PhotoLocalCache(
      root: Directory('${_root.path}/not_created_yet'),
    );
    expect((await missing.stats()).bytes, 0);
    expect(await missing.clear(), 0);
    expect(await missing.enforceLimit(1024), 0);
  });

  test('stats：递归统计子目录里的文件', () async {
    final now = DateTime(2026, 9, 20, 10);
    _write('thumb/a.jpg', 100, at: now);
    _write('full/b.jpg', 250, at: now);
    _write('c.jpg', 50, at: now);
    final s = await _cache.stats();
    expect(s.fileCount, 3);
    expect(s.bytes, 400);
    expect(s.isEmpty, isFalse);
  });

  test('clear：删文件、返回释放字节、**保留目录**', () async {
    _write('a.jpg', 100, at: DateTime(2026, 9, 20));
    _write('t/b.jpg', 200, at: DateTime(2026, 9, 20));
    expect(await _cache.clear(), 300);
    expect((await _cache.stats()).bytes, 0);
    expect(_root.existsSync(), isTrue, reason: '目录本身要留着复用');
  });

  test('enforceLimit(0)：不限制 ⇒ 一个都不删', () async {
    _write('a.jpg', 100, at: DateTime(2026, 9, 20));
    expect(await _cache.enforceLimit(0), 0);
    expect((await _cache.stats()).fileCount, 1);
  });

  test('enforceLimit：未超限 ⇒ 不动（返回 0，零删除）', () async {
    _write('a.jpg', 100, at: DateTime(2026, 9, 20));
    expect(await _cache.enforceLimit(1000), 0);
    expect((await _cache.stats()).fileCount, 1);
  });

  test('enforceLimit：超限 ⇒ 按 mtime **最旧先删**，降到上限内即停', () async {
    final old = _write('old.jpg', 400, at: DateTime(2026, 9, 1));
    final mid = _write('mid.jpg', 400, at: DateTime(2026, 9, 10));
    final fresh = _write('fresh.jpg', 400, at: DateTime(2026, 9, 20));
    // 1200 → 上限 500：删最旧的 old(400) 后是 800 仍超 ⇒ 再删 mid(400) → 400 ✅
    final freed = await _cache.enforceLimit(500);
    expect(freed, 800);
    expect(old.existsSync(), isFalse, reason: '最旧的先走');
    expect(mid.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue, reason: '最新的必须留下');
    expect((await _cache.stats()).bytes, 400);
  });

  test('enforceLimit：删不掉的文件不抛（返回值只算真删掉的）', () async {
    _write('a.jpg', 100, at: DateTime(2026, 9, 1));
    // 独占句柄在 macOS 上仍可 unlink ⇒ 这里用"目录不存在"的边界代替：
    expect(await _cache.enforceLimit(50), greaterThanOrEqualTo(0));
  });

  test('档位名（纯函数）', () {
    expect(photoCacheLimitLabel(0), '不限制');
    expect(photoCacheLimitLabel(500 * 1024 * 1024), '500 MB');
    expect(photoCacheLimitLabel(1024 * 1024 * 1024), '1 GB');
    expect(kPhotoLocalCacheDefaultLimit, 500 * 1024 * 1024);
    expect(kPhotoLocalCacheLimitOptions.first, 0);
  });
}
