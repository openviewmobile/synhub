// 第 242 轮 · `DA186` 的系统守卫：**半透明 `primary` 底不许再当文字底**。
//
// 为什么需要它：同一个缺陷在五个地方重复出现（`DA176` 相册分段 → `DA183` 文件来源
// → `DA185` Drive 四段 → `DA186` 通讯录/笔记/流量/Drive 搜索/下载/表情胶囊）。
// 每次都是「`primary` 字 + `primary@α` 底」，透出页面底后合成掉到 4.2–4.5:1。
// 人手 gреп 管不住第 6 次，所以把**清单**变成机器守卫。
//
// 判据：
//   ① 扫 `lib/src/**/*.dart` 里所有 `primary.withValues(alpha: ≤0.22)`；
//   ② 每一处 (文件, α) 都必须在 `design/translucent_primary_allowlist.md` 里登记；
//   ③ 反过来，清单里登记过但代码里已经没有的条目也算陈旧 ⇒ 红（防止清单腐烂）；
//   ④ 反证：清单文件里必须写明"文字底一律用不透明 primarySoft"，且**确实**存在
//      至少一处 `primarySoft` 用法（否则说明有人把修法又改回去了）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _allowlist = 'design/translucent_primary_allowlist.md';

final _alphaRe = RegExp(r'primary\.withValues\(alpha:\s*0?\.(\d+)\)');
final _entryRe = RegExp(r'^- `([^`]+)` @(\d+\.\d+) — (.+)$');

/// 扫描：每个文件里出现的**低不透明度** primary α 集合。
Map<String, Set<double>> _scan() {
  final out = <String, Set<double>>{};
  for (final f in Directory('lib/src').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final src = f.readAsStringSync();
    for (final m in _alphaRe.allMatches(src)) {
      final a = double.parse('0.${m.group(1)}');
      if (a <= 0.22) (out[f.path] ??= {}).add(a);
    }
  }
  return out;
}

/// 清单：file → 登记的 α 集合 + 理由。
Map<String, Map<double, String>> _entries() {
  final text = File(_allowlist).readAsStringSync();
  final out = <String, Map<double, String>>{};
  for (final line in text.split('\n')) {
    final m = _entryRe.firstMatch(line.trim());
    if (m == null) continue;
    (out[m.group(1)!] ??= {})[double.parse(m.group(2)!)] = m.group(3)!;
  }
  return out;
}

void main() {
  test('清单存在且有内容', () {
    final entries = _entries();
    expect(entries, isNotEmpty);
    for (final e in entries.entries) {
      for (final r in e.value.values) {
        expect(r.trim().length, greaterThan(8), reason: '${e.key} 的理由太短：$r');
      }
    }
  });

  test('每一处半透明 primary 底都登记过（新增必须给出理由）', () {
    final scanned = _scan();
    final registered = _entries();
    final unregistered = <String>[];
    for (final e in scanned.entries) {
      final known = registered[e.key] ?? const <double, String>{};
      for (final a in e.value) {
        if (!known.containsKey(a)) {
          unregistered.add('${e.key} @${a.toStringAsFixed(2)}');
        }
      }
    }
    expect(unregistered, isEmpty,
        reason: '这些地方用了半透明 primary 底却没登记：$unregistered\n'
            '（如果它是**文字底**，请改成不透明 `p.primarySoft`；'
            '如果它上面叠的不是 primary 文字，请在 $_allowlist 登记理由）');
  });

  test('清单不许腐烂：登记了但代码里已经没有的条目要删掉', () {
    final scanned = _scan();
    final registered = _entries();
    final stale = <String>[];
    for (final e in registered.entries) {
      final present = scanned[e.key] ?? const <double>{};
      for (final a in e.value.keys) {
        if (!present.contains(a)) {
          stale.add('${e.key} @${a.toStringAsFixed(2)}');
        }
      }
    }
    expect(stale, isEmpty, reason: '清单里的这些条目在代码里已经不存在：$stale');
  });

  test('修法还在：`primarySoft` 确实被当作文字底使用（DA176/183/185/186）', () {
    final text = File(_allowlist).readAsStringSync();
    expect(text.contains('primarySoft'), isTrue,
        reason: '清单里必须写明修法是不透明 primarySoft');
    // 至少 6 处调用点仍在（少一处说明有人回退了）
    var hits = 0;
    for (final f in Directory('lib/src').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.readAsStringSync().contains('primarySoft')) hits++;
    }
    expect(hits, greaterThanOrEqualTo(6),
        reason: 'primarySoft 的使用点只剩 $hits 个文件，疑似回退');
  });
}
