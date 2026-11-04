// 守卫（第 425 轮 / `DA83`）：**应用缓存作用域不许有"漏网的目录"**。
//
// 背景（真机读数）：设置页「清理已下载的文件」只统计 `chat_cache/` 与
// `chat_cache/file_thumbs/` 两层 ⇒ 界面显示「已用 5.3 MB」，而设备上
// `/data/data/com.openviewai.synhub/cache/` 实际 ≈ 17 MB（`office_doc_images`
// 9.1 MB、`file_picker` 1.5 MB、`office_thumbs` 1.0 MB、`office_template_thumbs`
// 452 KB、`video_frames` 132 KB…），并且对话框写的是"**所有**已下载的附件与缩略图"。
//
// 修法 = `lib/src/core/media/cache_service.dart` 里的一张**显式登记表**：
//   * `kRegenerableCacheDirs`：可再生纯缓存 ⇒ 计入用量、可清理、可淘汰；
//   * `kCacheNotRegenerable`：**不许动**（用户内容 / 正在写的临时件 / 持久目录），每条带理由。
//
// 本守卫把这件事变成**机器可检**的：扫 `lib/src/**` 与 `android/app/src/main/**`，
// 凡出现"应用缓存目录下的子目录"字面量，必须在上面两张表里分类。
// ★ 反向验证（记账在台账 §S3）：临时加一个未登记的目录名 ⇒ 本用例必须红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/media/cache_service.dart';

/// 收集到的"缓存目录名 → 出处（文件:行）"
Map<String, String> _collectCacheDirNames() {
  final found = <String, String>{};

  void add(String name, String where) {
    found.putIfAbsent(name, () => where);
  }

  /// Dart：`Directory('${xxx.path}/名字')`
  final dartRe = RegExp(
    r"""Directory\('\$\{[a-zA-Z_.]+\.path\}/([A-Za-z0-9_]+)""",
  );
  final dartFiles = Directory('lib/src').listSync(recursive: true);
  for (final e in dartFiles) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    for (final line in e.readAsLinesSync()) {
      final t = line.trimLeft();
      // 注释里的字面量不算（文档注释会举反例）
      if (t.startsWith('//') || t.startsWith('*')) continue;
      for (final m in dartRe.allMatches(line)) {
        add(m.group(1)!, '${e.path}: ${line.trim()}');
      }
    }
  }

  /// Kotlin：`File(ctx.cacheDir, "名字")` 或 `File(ctx.cacheDir, CONST)`
  /// （同一文件里的 `const val CONST = "名字"` 会被解析出来）
  final ktRe = RegExp(r'\.cacheDir,\s*(?:"([A-Za-z0-9_]+)"|([A-Za-z_][A-Za-z0-9_]*))');
  final constRe = RegExp(
    r'const val ([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)"',
  );
  final ktDir = Directory('android/app/src/main');
  if (ktDir.existsSync()) {
    for (final e in ktDir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.kt')) continue;
      final text = e.readAsStringSync();
      final consts = <String, String>{
        for (final m in constRe.allMatches(text))
          m.group(1)!: m.group(2)!,
      };
      for (final line in text.split('\n')) {
        final t = line.trimLeft();
        if (t.startsWith('//')) continue;
        for (final m in ktRe.allMatches(line)) {
          final direct = m.group(1);
          final viaConst = m.group(2);
          final name = direct ?? consts[viaConst];
          if (name == null) continue;
          // 只认"目录名"形态：别把 SID / 别名这类值混进来
          if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) continue;
          add(name, '${e.path}: ${line.trim()}');
        }
      }
    }
  }

  return found;
}

void main() {
  test('扫源码：每个"应用缓存目录下的子目录"都必须登记（可再生 或 写明不许动）', () {
    final found = _collectCacheDirNames();

    // ① 采集本身要有内容 —— "扫到 0 个"不是通过，是没扫到（仪器：false green）
    expect(
      found,
      isNotEmpty,
      reason: '扫描没采到任何缓存目录字面量 ⇒ 正则或路径失效了，不是"没问题"',
    );

    // ② 登记表允许的名字：登记项自身的**每一段**都算（`chat_cache/file_thumbs` ⇒
    //    源码里可能只写 `file_thumbs`）
    final registered = <String>{
      for (final e in kRegenerableCacheDirs) ...e.name.split('/'),
    };
    final ignored = kCacheNotRegenerable.keys.toSet();

    final unregistered = <String>[
      for (final n in found.keys)
        if (!registered.contains(n) && !ignored.contains(n)) '$n ← ${found[n]}',
    ];
    expect(
      unregistered,
      isEmpty,
      reason:
          '这些缓存目录既没登记进 kRegenerableCacheDirs、也没在 kCacheNotRegenerable 里'
          '说明理由（漏登记 = 用户"清了缓存"却清不掉）：\n${unregistered.join('\n')}',
    );

    // ③ 登记表自身不许有重复 / 空名（防手滑改表）
    final names = [for (final e in kRegenerableCacheDirs) e.name];
    expect(names.toSet().length, names.length, reason: '登记表里有重复项');
    for (final e in kRegenerableCacheDirs) {
      expect(e.name.trim(), isNotEmpty);
      expect(e.why.trim(), isNotEmpty, reason: '${e.name} 缺"为什么可再生"的理由');
    }
    for (final e in kCacheNotRegenerable.entries) {
      expect(e.value.trim(), isNotEmpty, reason: '${e.key} 缺"为什么不许动"的理由');
    }

    // ④ 本轮的四个"漏网目录"必须真的在登记表里（钉住 DA83 的修法本身）
    for (final name in ['video_frames', 'office_doc_images', 'office_thumbs']) {
      expect(
        registered.contains(name),
        isTrue,
        reason: '$name 是真机实测的漏网缓存目录，必须登记',
      );
      expect(
        found.containsKey(name),
        isTrue,
        reason: '$name 应该在源码里还能扫到（不然是改掉了实现，不是登记）',
      );
    }
  });

  test('登记表与实际统计一致：登记表里的目录丢掉文件后算得出来', () async {
    final root = await Directory.systemTemp.createTemp('cache_guard_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    final cache = CacheService(root: root);

    for (final entry in kRegenerableCacheDirs) {
      final dir = Directory('${root.path}/${entry.name}')
        ..createSync(recursive: true);
      File('${dir.path}/probe.bin').writeAsBytesSync(List.filled(100, 1));
    }
    final u = await cache.usage();
    expect(u.files, kRegenerableCacheDirs.length);
    expect(u.bytes, kRegenerableCacheDirs.length * 100);

    final freed = await cache.clear();
    expect(freed, kRegenerableCacheDirs.length * 100);
    expect((await cache.usage()).files, 0);
  });
}
