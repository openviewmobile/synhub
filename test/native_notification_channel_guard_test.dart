// 静态守卫：**通知渠道名/描述必须走 `AppLang.s`**（第 341 轮，D42）。
//
// ★ 为什么会有这条（r341 真机）：`dumpsys notification` 里中文 App 的系统通知渠道名是
//   英文 `Backup process`；一查发现**同一个语义有 3 种口径**（§2.0.26）：
//     ① 硬编码中文字面量（`"后台连接"` / `"新消息"` / `"下载完成"`）⇒ **英文界面显示中文**；
//     ② `context.getString(...)` ⇒ 跟随**系统**语言，App 内语言切了也不变
//        （第 41 轮早就立过"原生可见文案用 `AppLang.s`"的口径，渠道名漏了）；
//     ③ `AppLang.s(...)` ⇒ 正确。
//   而且四处都写成 `if (getNotificationChannel(id) == null) { create(...) }`
//   ⇒ 渠道一旦建过，**换语言永远不更新**。
//
// 判据：扫 `android/app/src/main/kotlin/**/*.kt` 里每个 `NotificationChannel(` 的
// **第 2 个实参**（渠道名），必须是
//   * `AppLang.s(` 调用，或
//   * 一个在**同文件**里由 `AppLang.s(` 赋值的局部变量；
// 否则红（含中文字面量、`context.getString`、其它任何东西）。
//
// ★ 反向断言：构造样本必须被抓到（含两种坏口径与一种好口径）。
// ★ 已知边界：只扫 Kotlin 侧构造 `NotificationChannel(` 的地方；XML/其它语言不受管。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _kotlinRoot = 'android/app/src/main/kotlin';

/// 取 `NotificationChannel(` 之后**第 2 个实参**的原文（支持跨行、含嵌套括号）。
String? secondArgOf(String source, int callStart) {
  var i = source.indexOf('(', callStart);
  if (i < 0) return null;
  final args = <String>[];
  final buf = StringBuffer();
  var depth = 0;
  for (; i < source.length; i++) {
    final c = source[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) {
        args.add(buf.toString());
        break;
      }
    }
    if (c == ',' && depth == 1) {
      args.add(buf.toString());
      buf.clear();
      continue;
    }
    if (depth >= 1) buf.write(c);
  }
  if (args.length < 2) return null;
  return args[1].trim();
}

/// 文件里由 `val <ident> = AppLang.s(` 赋值的名字集合。
Set<String> appLangVals(String source) {
  final out = <String>{};
  final re = RegExp(r'val\s+(\w+)\s*[=:][^=\n]*=\s*AppLang\.s\(');
  for (final m in re.allMatches(source)) {
    out.add(m.group(1)!);
  }
  // 形如 `val name = AppLang.s(`（无类型标注）
  final re2 = RegExp(r'val\s+(\w+)\s*=\s*AppLang\.s\(');
  for (final m in re2.allMatches(source)) {
    out.add(m.group(1)!);
  }
  return out;
}

List<String> badChannelNames(String path, String source) {
  final bad = <String>[];
  final vals = appLangVals(source);
  // ★ 必须加前置词界：否则会匹配到 `nm.createNotificationChannel(` 的**尾部**，
  //   把外层调用的实参当成渠道构造的实参（r341 实测：报的 arg 全是空串）。
  final re = RegExp(r'(?<![A-Za-z0-9_])NotificationChannel\s*\(');
  for (final m in re.allMatches(source)) {
    final line = source.substring(0, m.start).split('\n').length;
    final trimmed = source.split('\n')[line - 1].trim();
    if (trimmed.startsWith('//')) continue;
    final arg = secondArgOf(source, m.start);
    if (arg == null) {
      bad.add('$path:$line: 取不到第 2 个实参（渠道名）');
      continue;
    }
    final ok = arg.startsWith('AppLang.s(') || vals.contains(arg);
    if (!ok) {
      bad.add('$path:$line: 渠道名实参 = `$arg`（必须走 AppLang.s）');
    }
  }
  return bad;
}

void main() {
  test('Kotlin 侧通知渠道名一律走 AppLang.s（不许硬编码中文 / 系统语言）', () {
    final hits = <String>[];
    for (final e in Directory(_kotlinRoot).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.kt')) continue;
      hits.addAll(badChannelNames(e.path, e.readAsStringSync()));
    }
    expect(
      hits,
      isEmpty,
      reason: '通知渠道名/描述在系统「应用 → 通知」里对用户可见，'
          '必须用 `AppLang.s(context, R.string.…)`（App 内语言），'
          '不许硬编码中文（英文界面会显示中文）也不许 `context.getString`（跟随系统语言）：\n'
          '${hits.join('\n')}',
    );
  });

  test('判据本身有效（反向：两种坏口径 + 一种好口径）', () {
    // 坏口径①：硬编码中文
    expect(
      badChannelNames('x.kt', 'NotificationChannel("id", "后台连接", 3)'),
      hasLength(1),
    );
    // 坏口径②：系统语言
    expect(
      badChannelNames('x.kt', 'NotificationChannel(id, context.getString(R.string.a), 3)'),
      hasLength(1),
    );
    // 好口径①：直接 AppLang.s
    expect(
      badChannelNames('x.kt', 'NotificationChannel(id, AppLang.s(c, R.string.a), 3)'),
      isEmpty,
    );
    // 好口径②：同文件里先赋值
    expect(
      badChannelNames(
        'x.kt',
        'val name = AppLang.s(c, R.string.a)\nNotificationChannel(id, name, 3)',
      ),
      isEmpty,
    );
    // ★ 反向的反向：外层 `createNotificationChannel(` 的尾部不许被当成渠道构造
    expect(
      badChannelNames(
        'x.kt',
        'nm.createNotificationChannel(\n  NotificationChannel(id, "新消息", 3),\n)',
      ),
      hasLength(1),
    );
    // 跨行实参也要能取到第 2 个
    expect(
      badChannelNames(
        'x.kt',
        'NotificationChannel(\n  id,\n  "新消息",\n  3,\n)',
      ),
      hasLength(1),
    );
  });

  test('真仓里确实扫到了渠道（防空转：命中数 > 0）', () {
    var total = 0;
    for (final e in Directory(_kotlinRoot).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.kt')) continue;
      total += RegExp(r'(?<![A-Za-z0-9_])NotificationChannel\s*\(')
          .allMatches(e.readAsStringSync())
          .length;
    }
    // "扫到 0 个"不是成功，是**没校验**（§1.3.0.1）。
    expect(total, greaterThanOrEqualTo(6));
  });
}
