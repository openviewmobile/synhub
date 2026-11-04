// ★★★ r131（macOS 逐屏走查）静态守卫：**放进 `Row` 的实心/描边按钮必须收宽度**。
//
// 缺陷现场（真机像素 + 框架原文，见 `docs/platform-macos-ui-audit.md` §3 D14）：
//   全局主题 `app_theme.dart` 给 `FilledButton`/`OutlinedButton` 设了
//   `minimumSize: Size.fromHeight(48)`（= `Size(double.infinity, 48)`）。
//   `Row` 给**非 flex 子项**传的约束是 `maxWidth: infinity` ⇒ 按钮自身的
//   `minWidth: infinity` 立刻让框架断言
//   `BoxConstraints forces an infinite width`（`RenderPhysicalShape`），
//   随后连锁 `RenderBox was not laid out: …`。
//   ★ r332 追加：本守卫**在 r330 漏掉了两处真缺陷**（`photo_ai_edit_sheet.dart`
//   的 `photo-ai-edit-save-timeline`、`photo_free_up_page.dart` 的
//   `photo-free-up-start`）—— 根因是"**子项前面有注释**"让锚定正则不匹配（见
//   `_stripGuards` 注释）。两处都靠"给用例加真实主题"在布局期真抛断言才暴露，
//   现已修好并各有反向验证（把那一行 `style` 拿掉 ⇒ 用例真红）。
//   第 r131 轮 macOS 走查就是在 `download_bt_search_page.dart` 的
//   `FilledButton-[<'ds-bt-submit'>]` 上真拍到的；全仓静态扫描共 **18 处**同型。
//
// 本文件做两件事：
//   ① 静态扫描 `lib/**/*.dart`（含 `AppBar.actions`），漏一个就红；
//   ② 反向验证：**去掉** `style:` 的旧写法必须在测试里真抛异常，
//      证明这条守卫抓的是真缺陷，而不是"看着不对"。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';

/// 需要收宽度的按钮构造器（`TextButton` 的主题最小宽度是 `Size(0, 40)`，天然安全）。
///
/// ★★ r330：必须**连命名构造器一起**匹配 —— 原来只列了 `FilledButton(`，
///   于是 `FilledButton.icon(...)` / `FilledButton.tonal(...)` /
///   `OutlinedButton.icon(...)` **全部静默漏过**。下载任务对话框里那个
///   "撑满整行"的 `Open` 就是 `FilledButton.icon(`（r330 的 iOS/macOS 像素），
///   而老守卫两次机会都没抓到它（既没覆盖 `Wrap`，也不认命名构造器）。
final _riskyButtonRe = RegExp(
  r'^(?:const\s+)?(FilledButton|OutlinedButton|ElevatedButton)(\.[A-Za-z]+)?\s*\(',
);

/// 已经带上有限宽度的写法（出现任一即视为安全）。
const _safeMarkers = <String>['minimumSize', 'fixedSize', 'InlineButtonStyle'];

/// 与 `(` 配对的 `)` 之后一位的下标；找不到返回 -1。
int _matchParen(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i + 1;
    }
  }
  return -1;
}

/// 剥掉子项前面的 `// 注释` / `/* 注释 */` / `if (…)` / `...` 前缀，
/// 拿到**真正的控件表达式**。
///
/// ★★★ r332：**注释也是盲区**。原来只剥 `if (`/`...`，于是
///   ```dart
///   children: [
///     // 默认主操作 = 保存为新照片（106/119 会话过期也不隐藏；
///     if (canUploadTimeline && !_timelineDenied)
///       FilledButton.icon(          // ← 没写 style
///   ```
///   这种"**注释在最前**的条件子项"里，`t` 以 `//` 开头 ⇒ 锚定的
///   `_riskyButtonRe` 不匹配 ⇒ **整条静默漏过**。
///   实测：同一段代码**去掉注释就报 1 条、带注释报 0 条**
///   （`photo_ai_edit_sheet.dart` 修复前那种"保存为新照片"按钮就是这么漏的，
///   直到 r332 把产品主题加进用例、布局期真抛
///   `BoxConstraints forces an infinite width` 才暴露）。
String _stripGuards(String text) {
  var t = text.trim();
  while (true) {
    if (t.startsWith('//')) {
      final nl = t.indexOf('\n');
      if (nl < 0) return '';
      t = t.substring(nl + 1).trim();
      continue;
    }
    if (t.startsWith('/*')) {
      final end = t.indexOf('*/');
      if (end < 0) return '';
      t = t.substring(end + 2).trim();
      continue;
    }
    if (t.startsWith('if (')) {
      final close = _matchParen(t, t.indexOf('('));
      if (close < 0) return t;
      t = t.substring(close).trim();
      continue;
    }
    if (t.startsWith('...')) {
      t = t.substring(3).trim();
      continue;
    }
    return t;
  }
}

/// 与 `[` 配对的 `]` 的下标。
int _matchBracket(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (c == '[') {
      depth++;
    } else if (c == ']') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// 按**顶层逗号**切分列表体，返回 (相对偏移, 原文)。
List<(int, String)> _splitTopLevel(String body) {
  final out = <(int, String)>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
    } else if (c == ',' && depth == 0) {
      out.add((start, body.substring(start, i)));
      start = i + 1;
    }
  }
  if (start < body.length) out.add((start, body.substring(start)));
  return out;
}

/// 扫描一份 Dart 源码，返回 `file:line 说明` 形式的违规列表。
List<String> findInlineButtonViolations(String src, {String file = 'src'}) {
  final out = <String>[];
  // ★★ r330：`Wrap` 也必须进来 —— 它给子项的是**宽松但有界**的约束，
  //   于是 `minimumSize: Size(infinity, 48)` 不会触发无限宽断言，而是
  //   **静默撑满整行**（症状不同、根因同一个）。r330 的 iOS/macOS 像素
  //   就是这么抓到的（下载任务对话框里的 `Open` 渲染成整行实心蓝条）。
  final rowRe = RegExp(r'\b(Row|Wrap|AppBar|SliverAppBar)\s*\(');
  for (final m in rowRe.allMatches(src)) {
    final kind = m.group(1)!;
    final open = m.end - 1;
    final close = _matchParen(src, open);
    if (close < 0) continue;
    final body = src.substring(open + 1, close - 1);
    final key = (kind == 'Row' || kind == 'Wrap') ? 'children' : 'actions';
    final listStart = RegExp('\\b$key\\s*:\\s*\\[').firstMatch(body);
    if (listStart == null) continue;
    final lb = body.indexOf('[', listStart.start);
    final rb = _matchBracket(body, lb);
    if (rb < 0) continue;
    final list = body.substring(lb + 1, rb);
    final base = open + 1 + lb + 1;
    for (final (offset, raw) in _splitTopLevel(list)) {
      final text = raw.trim();
      if (text.isEmpty) continue;
      // ★★ r330：条件子项（`if (cond) FilledButton(...)`）与展开子项
      //   （`...list`）也要能识别 —— 原来 `startsWith` 一撞上 `if (` 就跳过，
      //   而"按状态显隐的按钮"恰恰是最常见的写法（下载任务对话框就是）。
      final body2 = _stripGuards(text);
      final m2 = _riskyButtonRe.firstMatch(body2);
      if (m2 == null) continue;
      final btn = '${m2.group(1)}${m2.group(2) ?? ''}';
      // ★ r332：判据只看**这个按钮自己那对括号里**有没有收宽度 —— 原来
      //   `body2.contains(...)` 判的是**整个子项**，于是同一子项里
      //   "前一个按钮没收宽度、后一个按钮写了 style"会被误判成安全
      //   （`if (a) FilledButton(...) else OutlinedButton(style: …)` 这种写法）。
      final spanEnd = _matchParen(body2, m2.end - 1);
      final span = spanEnd < 0 ? body2.substring(m2.start) : body2.substring(m2.start, spanEnd);
      if (_safeMarkers.any(span.contains)) continue;
      var idx = raw.indexOf(body2);
      // ★ r332：注释被剥掉后 `body2` 可能不在 `raw` 里 ⇒ 退一步按控件名定位，
      //   保证行号指向**按钮那一行**（判据本身不依赖行号）。
      if (idx < 0) idx = raw.indexOf(btn);
      final abs = base + offset + (idx < 0 ? 0 : idx);
      final line = '\n'.allMatches(src.substring(0, abs)).length + 1;
      out.add('$file:$line  $btn 直接作为 $kind 的$key 子项且未收宽度'
          '（加 `style: InlineButtonStyle.filled`/`.outlined`，'
          '或改用 `Expanded`/`Flexible`/`SizedBox(width: …)`）');
    }
  }
  return out;
}

void main() {
  test('★★★ r131：全仓没有"未收宽度就放进 Row 的 Filled/Outlined 按钮"', () {
    final violations = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.path)
        .toList()
      ..sort();
    for (final path in files) {
      violations.addAll(
        findInlineButtonViolations(File(path).readAsStringSync(), file: path),
      );
    }
    expect(
      violations,
      isEmpty,
      reason: '以下位置会在布局期抛 `BoxConstraints forces an infinite width`：\n'
          '${violations.join('\n')}',
    );
    // 扫描面活性断言：真扫到了文件、也真扫到了 Row（防"正则失效 ⇒ 0 违规 ⇒ 假绿"）。
    expect(files.length, greaterThan(200));
    final sample = File('lib/src/features/downloads/download_bt_search_page.dart')
        .readAsStringSync();
    expect(sample.contains('Row('), isTrue);
  });

  test('★★★ r131 反向验证：守卫能抓到修复前的写法（不抓到就说明守卫是摆设）', () {
    const beforeFix = '''
class P {
  Widget build() => Row(children: [
    Expanded(child: Text('k')),
    FilledButton(key: const Key('x'), onPressed: () {}, child: Text('go')),
  ]);
}
''';
    final hits = findInlineButtonViolations(beforeFix, file: 'fixture.dart');
    expect(hits, hasLength(1));
    expect(hits.single, contains('fixture.dart:4'));
    expect(hits.single, contains('FilledButton'));

    const appBarBeforeFix = '''
class P {
  Widget build() => AppBar(actions: [
    OutlinedButton(onPressed: () {}, child: Text('a')),
  ]);
}
''';
    expect(findInlineButtonViolations(appBarBeforeFix), hasLength(1));

    // 修复后的三种写法都不该被抓。
    const afterFix = '''
class P {
  Widget build() => Row(children: [
    FilledButton(style: InlineButtonStyle.filled, onPressed: () {}, child: Text('a')),
    Expanded(child: OutlinedButton(onPressed: () {}, child: Text('b'))),
    SizedBox(width: 120, child: FilledButton(onPressed: () {}, child: Text('c'))),
  ]);
}
''';
    expect(findInlineButtonViolations(afterFix), isEmpty);

    // ★★ r330：三个**新补的盲区**，每个都要有反向验证（不然"修了守卫"是空话）：
    //
    //  ① `Wrap`：约束是"宽松但有界" ⇒ 不炸，而是**静默撑满整行**（症状不同、根因同一个）；
    //  ② 命名构造器：`FilledButton.icon(` / `.tonal(` / `.tonalIcon(` /
    //     `OutlinedButton.icon(` —— 老守卫只认 `FilledButton(`，全漏；
    //  ③ 条件子项：`if (cond) FilledButton(...)` —— 老守卫用 `startsWith` 匹配，
    //     撞上 `if (` 直接跳过（而"按状态显隐的按钮"是最常见写法）。
    const wrapBeforeFix = '''
class P {
  Widget build() => Wrap(spacing: 8, children: [
    if (a) FilledButton.tonal(key: const Key('x'), onPressed: () {}, child: Text('r')),
    if (b) FilledButton.icon(onPressed: () {}, icon: Icon(Icons.open_in_new), label: Text('o')),
    OutlinedButton.icon(onPressed: () {}, icon: Icon(Icons.save), label: Text('s')),
  ]);
}
''';
    final wrapHits = findInlineButtonViolations(wrapBeforeFix, file: 'wrap.dart');
    expect(
      wrapHits,
      hasLength(3),
      reason: 'Wrap + 命名构造器 + `if (...)` 三个盲区必须都能抓到；实际：$wrapHits',
    );
    expect(wrapHits[0], contains('FilledButton.tonal'));
    expect(wrapHits[1], contains('FilledButton.icon'));
    expect(wrapHits[2], contains('OutlinedButton.icon'));

    // 反面：同一个 `Wrap`，三个都带上 style ⇒ 一条都不该抓
    const wrapAfterFix = '''
class P {
  Widget build() => Wrap(spacing: 8, children: [
    if (a) FilledButton.tonal(style: InlineButtonStyle.filled, onPressed: () {}, child: Text('r')),
    if (b) FilledButton.icon(style: InlineButtonStyle.filled, onPressed: () {}, icon: Icon(Icons.open_in_new), label: Text('o')),
    OutlinedButton.icon(style: InlineButtonStyle.outlined, onPressed: () {}, icon: Icon(Icons.save), label: Text('s')),
  ]);
}
''';
    expect(findInlineButtonViolations(wrapAfterFix), isEmpty);
  });

  test('★★★ r332 反向验证：**子项前面的注释**不能变成盲区（r330 漏了两处真缺陷）', () {
    // 现场（`photo_ai_edit_sheet.dart` 的"保存为新照片"、`photo_free_up_page.dart`
    // 的"释放空间"）：按钮是 `Row` 子项、**没写 style**，但它前面有 `//` 注释。
    // 老 `_stripGuards` 只剥 `if (`/`...` ⇒ `t` 以 `//` 开头 ⇒ 锚定的
    // `_riskyButtonRe` 不匹配 ⇒ **整条静默跳过**。实测同一段代码
    // "去掉注释报 1 条、带注释报 0 条"。
    const commentBeforeFix = '''
class P {
  Widget build() => Row(children: [
    // 默认主操作（106/119 会话过期也不隐藏；
    // 缺 SYNO.Foto.Upload.Item 才隐藏）
    if (a)
      FilledButton.icon(
        key: k,
        onPressed: f,
      ),
  ]);
}
''';
    final hits = findInlineButtonViolations(
      commentBeforeFix,
      file: 'comment.dart',
    );
    expect(
      hits,
      hasLength(1),
      reason: '注释在前的条件子项必须照样抓到；实际：$hits',
    );
    expect(hits.single, contains('FilledButton.icon'));

    // 块注释同理。
    const blockComment = '''
class P {
  Widget build() => Row(children: [
    /* 说明 */
    FilledButton(key: k, onPressed: f),
  ]);
}
''';
    expect(findInlineButtonViolations(blockComment), hasLength(1));

    // 反面：注释 + 带 style ⇒ 一条都不该抓（避免"剥注释"误伤安全写法）。
    const commentAfterFix = '''
class P {
  Widget build() => Row(children: [
    // 说明
    if (a) FilledButton.icon(style: InlineButtonStyle.filled, key: k, onPressed: f),
  ]);
}
''';
    expect(findInlineButtonViolations(commentAfterFix), isEmpty);
  });

  testWidgets('★★★ r131 行为反向验证：不带 style 的 FilledButton 放进 Row 会真的炸', (
    tester,
  ) async {
    // 用 `FlutterError.onError` 逐条收集：一次布局失败会连锁报多条，
    // `tester.takeException()` 只会给一句"Multiple exceptions (6)"的摘要。
    final errors = <String>[];
    final prev = FlutterError.onError;
    FlutterError.onError = (details) => errors.add(details.exceptionAsString());
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: TextField()),
                const SizedBox(width: 8),
                FilledButton(onPressed: () {}, child: const Text('搜索')),
              ],
            ),
          ),
        ),
      );
    } finally {
      FlutterError.onError = prev;
    }
    expect(errors, isNotEmpty, reason: '旧写法在 800x600 下本应抛断言');
    expect(
      errors.any((e) => e.contains('infinite width')),
      isTrue,
      reason: '期望出现「BoxConstraints forces an infinite width」，实际：$errors',
    );
    tester.takeException();

    // 换成本次落地的 `InlineButtonStyle.filled` ⇒ 零异常，且宽度是有限值。
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Row(
            children: [
              Expanded(child: TextField()),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('r131-ok'),
                style: InlineButtonStyle.filled,
                onPressed: () {},
                child: const Text('搜索'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byKey(const Key('r131-ok')));
    expect(size.width.isFinite, isTrue);
    expect(size.width, greaterThan(0));
    expect(size.height, greaterThanOrEqualTo(48));
  });
}
