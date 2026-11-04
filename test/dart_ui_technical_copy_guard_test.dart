// 静态守卫：**Dart 侧渲染点**不许把 API 名印给用户（第 342 轮 D46）。
//
// ★ 为什么还要一条（r340 已有 `i18n_user_facing_copy_test.dart`）：
//   那条守卫扫的是 **ARB 值**。D46 的旁路不在 ARB 里 —— 它是**运行时拼出来的**
//   （`channel.detectedApis.join(' · ')`，数据来自 `service_registry.dart` 的 API 常量），
//   直接进了 `Text(...)`。真机逐字：
//   `SYNO.AI.Completion · SYNO.AI.Thread · SYNO.AI.Config · SYNO.AI.Metrics`。
//   ⇒ **"某一路径有守卫"证明不了"所有文案干净"**（§2.0.47）：ARB 是第一条旁路，
//     Dart 渲染点是**第二条**；本文件就是补第二条的（第三条是原生 `strings.xml`，归
//     `native_notification_channel_guard_test.dart` 管）。
//
// ★ 判据为什么要做**跨行取参**：`Text(` 与 `.join(` 常常不在同一行
//   （D46 就是这样：`Text(` 一行、实参一行）⇒ 逐行扫会得到 **0 命中**的假绿。
//   这里按括号配对取出 `Text(...)` 的**完整实参**再判。
//
// 认的"API 名样式"（只认这三种，收窄优先）：
//   ① 字符串字面量 `'SYNO.…'`；② 常量名里含 `Api`（如 `kAiCompletionApi`）；
//   ③ `<名字里含 api/Api 的表达式>.join(`。
// ★ 注释不算。★ 白名单 `tool/dart_ui_technical_copy_allow.txt`：**只登记诊断面**，
//   且带**陈旧检测**（登记了却不再命中 ⇒ 必须删条目，否则红）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _allowPath = 'tool/dart_ui_technical_copy_allow.txt';

/// 命中：文件 + 行号 + 实参片段。
class UiHit {
  const UiHit(this.path, this.line, this.snippet);
  final String path;
  final int line;
  final String snippet;

  @override
  String toString() => '$path:$line  $snippet';
}

/// ★★ r343 D52 的教训：④⑤ 这两个形状**只能在本字符串字面量内部**匹配 ——
/// 直接拿去匹配 `Text(` 的实参正文会把 Dart 代码本身当命中
/// （实测 `theme.textTheme.labelSmall` / `TextOverflow.ellipsis` / `state.uri`
/// 全被 ⑤ 的"点分路径"抓成假阳性）。⇒ 先抽字面量，再在字面量里找键值/参数路径；
/// ①②③（接口名/常量名/`.join(`）很专有，继续在整段实参里匹配。
final RegExp _stringLit = RegExp(r"'((?:\\.|[^'\\])*)'");

/// ④⑤ 两个"键值/参数路径"形状（**只用于字符串字面量内部**）：
///   ④ `user_id=14` / `finish_reason=length` / `source_url: …` / `（user_id={id}）`
///   ⑤ `settings.enable_download`（小写点分路径）
final RegExp _kvShape = RegExp(
  r"(?<![A-Za-z0-9_])[a-z][a-z0-9]*(?:_[a-z0-9]+)+\s*(?:=|:|：|＝)"
  r"|(?<![A-Za-z0-9_.])[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]+)+",
);

/// ★ 再退一步：字面量里的 **`${…}` / `$name` 插值也是 Dart 代码**，不是画上屏的字
/// （实测不剥就还会被 `'${state.uri}'` / `'${widget.progress}'` 抓成假阳性）。
/// ⇒ 先剥插值，再判 ④⑤。
/// ★★★ 剥插值必须**按花括号配对**做，不能用 `\$\{[^}]*\}`：
/// 插值里可以有嵌套花括号与**引号**（实测 `'${...padLeft(2, '0')}'` 里的 `'0'`
/// 会把朴素的"取字面量"解析带偏，于是又冒出一批假阳性）。
String _stripInterp(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    if (s[i] == r'$' && i + 1 < s.length && s[i + 1] == '{') {
      var depth = 0;
      var j = i + 1;
      while (j < s.length) {
        if (s[j] == '{') {
          depth++;
        } else if (s[j] == '}') {
          depth--;
          if (depth == 0) {
            j++;
            break;
          }
        }
        j++;
      }
      i = j;
      continue;
    }
    if (s[i] == r'$' && i + 1 < s.length && RegExp(r'[A-Za-z_]').hasMatch(s[i + 1])) {
      i += 2;
      while (i < s.length && RegExp(r'[A-Za-z0-9_]').hasMatch(s[i])) {
        i++;
      }
      continue;
    }
    out.write(s[i]);
    i++;
  }
  return out.toString();
}

/// 把实参正文里的**字符串字面量**逐个拿出来做 ④⑤ 判据（先剥插值）。
bool _literalKvHit(String body) {
  for (final m in _stringLit.allMatches(_stripInterp(body))) {
    if (_kvShape.hasMatch(m.group(1)!)) return true;
  }
  return false;
}

/// 认的**技术字样形状**（★ 这张清单就是本守卫的边界，§2.0.63⑤；r343 D52 扩了两条）：
///   ① `'SYNO.` —— 接口全名；
///   ② `kXxxApiXxx` —— 代码里的 API 常量名；
///   ③ `xxxApi.join(` —— 拼接口清单；
///   ④ ★ **键值形状**：`user_id=14` / `finish_reason=length` / `source_url: …`
///      —— snake_case 标识符后紧跟 `=`、`:`（含全角）或空格等号。**r343 D52 新增**：
///      真机/源码里四处同族就是这样漏的（`（user_id={id}）`、`settings.enable_download=false`、
///      `clipper_url`/`clipper_mode`、`finish_reason={reason}`），前三种形状**一个都不认**。
///   ⑤ ★ **带点的参数路径**：`settings.enable_download` —— 小写点分路径（不是接口全名）。
///      与 r340 的 ARB 守卫 R2「带点接口路径」同源，但那条只管 ARB，管不到 Dart 里的回退字面量。
final RegExp _apiShape = RegExp(
  r"'SYNO\.[A-Za-z]"
  r"|\bk[A-Za-z]*Api[A-Za-z]*\b"
  r"|\b[A-Za-z_][A-Za-z0-9_]*[Aa]pi[A-Za-z0-9_]*\s*\.\s*join\s*\(",
);

/// 认的**渲染入口**（这就是本守卫清点过的字面形状，§2.0.63⑤）：
///   `Text(` / `SelectableText(` —— 普通文案；`_add(` —— 诊断页的诊断行
///   （`_add(step, ok, detail)` 的第三参就是会被画上屏的技术细节）。
/// ★ 已知边界：`TextSpan`/`RichText`/自定义 `dataText` 不在此列（本仓未用它们渲染 API 名）。
final RegExp _renderEntry =
    RegExp(r'(?<![A-Za-z0-9_])(?:Text|SelectableText|_add)\s*\(');

/// 取渲染入口调用的完整实参（括号配对 + 跳过字符串字面量里的括号）。
List<({int start, String body})> textSpans(String src) {
  final out = <({int start, String body})>[];
  for (final m in _renderEntry.allMatches(src)) {
    final open = src.indexOf('(', m.start);
    var depth = 0;
    var j = open;
    String? quote;
    while (j < src.length) {
      final c = src[j];
      if (quote != null) {
        if (c == r'\') {
          j += 2;
          continue;
        }
        if (c == quote) quote = null;
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) break;
      }
      j++;
    }
    out.add((start: m.start, body: src.substring(open + 1, j)));
  }
  return out;
}

bool _inComment(String src, int start) {
  final lineStart = src.lastIndexOf('\n', start) + 1;
  return src.substring(lineStart, start).trimLeft().startsWith('//');
}

/// 扫一个文件里的所有命中。
List<UiHit> scanSource(String path, String src) {
  final out = <UiHit>[];
  for (final span in textSpans(src)) {
    if (_inComment(src, span.start)) continue;
    final m = _apiShape.firstMatch(span.body);
    if (m == null && !_literalKvHit(span.body)) continue;
    final flat = span.body.replaceAll(RegExp(r'\s+'), ' ').trim();
    out.add(UiHit(
      path,
      src.substring(0, span.start).split('\n').length,
      flat.length <= 40 ? flat : flat.substring(0, 40),
    ));
  }
  return out;
}

List<String> dartFilesUnder(String dir) {
  final out = <String>[];
  for (final e in Directory(dir).listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) out.add(e.path);
  }
  out.sort();
  return out;
}

/// 白名单条目：`path<TAB>reason`（`#` 开头是注释）。
Map<String, String> parseAllow(String raw) {
  final out = <String, String>{};
  for (final line in raw.split('\n')) {
    final s = line.trim();
    if (s.isEmpty || s.startsWith('#')) continue;
    final parts = s.split('\t');
    // 注意：这里**不能**用 `expect`（main 体里不是测试作用域 ⇒ OutsideTestException）
    if (parts.length < 2) {
      throw FormatException('白名单行格式：path<TAB>理由 —— $s');
    }
    out[parts[0].trim()] = parts[1].trim();
  }
  return out;
}

void main() {
  final hits = <UiHit>[];
  for (final f in dartFilesUnder('lib/src')) {
    hits.addAll(scanSource(f, File(f).readAsStringSync()));
  }
  final allow = parseAllow(File(_allowPath).readAsStringSync());

  test('Dart 渲染点里不许出现 API 名（白名单只放诊断面）', () {
    final bad = hits.where((h) => !allow.containsKey(h.path)).toList();
    expect(
      bad,
      isEmpty,
      reason: '这些 `Text(...)` 把 API 名印给用户了：\n${bad.join('\n')}\n'
          '改成用户文案；技术事实挪到诊断页并登记进 $_allowPath（D46 / §2.0.47）。',
    );
  });

  test('白名单不许有陈旧条目（登记了却不再命中 ⇒ 删掉）', () {
    final stale = allow.keys
        .where((p) => !hits.any((h) => h.path == p))
        .toList();
    expect(stale, isEmpty, reason: '这些白名单条目已经不再命中：$stale');
  });

  test('防空转：真仓里确实还剩诊断面那一处（否则"没有命中"可能只是没扫到）', () {
    // ★ 「扫到 0 条」不是成功，是**没校验**（§1.3.0.1）。诊断页那一条是**有意保留**的
    //   技术事实渲染 ⇒ 它必须一直在，且必须在白名单里。
    expect(hits, isNotEmpty, reason: '扫到 0 条命中 ⇒ 判据/扫描器坏了，不是"干净"');
    expect(allow, isNotEmpty);
    expect(hits.where((h) => allow.containsKey(h.path)).length, allow.length);
    // 反向：扫到的必须真是诊断页（别把 AI 卡那条误当白名单放行）
    expect(
      hits.every((h) => h.path.contains('diagnostics/')),
      isTrue,
      reason: '白名单外的命中不该存在；诊断面之外的命中一律红',
    );
  });

  test('判据本身有效（反向：跨行实参必红、正常 join 不误报）', () {
    const bad = '''
      Text(
        ctx.detectedApis.join(' · '),
        style: a,
      ),
''';
    expect(scanSource('x.dart', bad), hasLength(1));
    expect(scanSource('x.dart', "Text('SYNO.AI.Thread')"), hasLength(1));
    // 诊断页那种 `_add(...)` 也要认（否则白名单锚点会"从不命中"）
    expect(
      scanSource('x.dart', "_add(t.title, ok, ai.detectedApis.join(' · '));"),
      hasLength(1),
    );
    expect(scanSource('x.dart', 'Text(kAiCompletionApi)'), hasLength(1));
    // 正常用法不许误报
    expect(scanSource('x.dart', "Text(names.join('、'))"), isEmpty);
    expect(scanSource('x.dart', "Text('导出 PDF')"), isEmpty);
    expect(scanSource('x.dart', "Text('AI 美化已关闭')"), isEmpty);
    // 注释里的不算
    expect(scanSource('x.dart', "// Text('SYNO.AI.Thread')"), isEmpty);
    // ★ 跨行提取真的生效（逐行扫会漏掉这一条）
    expect(textSpans(bad).single.body.contains('detectedApis.join'), isTrue);
  });
}
