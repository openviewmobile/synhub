// 数据层"包装器文案"静态扫描（**纯 Dart**，dataText 的登记缺口守卫用）。
//
// 背景：模块里的新文案常写成
//
//   String photoAiEdit(String key, String zh) => dataText(key, zh);
//   abstract final class PhotoAiEditTextKeys {
//     static const settingsEntry = 'imageEditSettingsEntry';
//   }
//   // 调用点：
//   photoAiEdit(PhotoAiEditTextKeys.settingsEntry, 'AI 美化（图生图）')
//
// key 是**具名常量**，不是字符串字面量。既有的 `i18n_coverage_test.dart`
// 守卫②只认 `xxxText('literal', '…')`，`i18n_hardcoded_cjk_test.dart` 又把
// `key + 中文回落` 当成合法形态排除 ⇒ 这两类调用点长期是盲区：
// key 没进 ARB / 没进 `dataTextMap` 时，英文模式会显示中文。
//
// 本文件把那套扫描抽成**可单测的纯函数**（不 import Flutter，纯 Dart），
// 供 `tool/i18n_wrapper_key_audit.dart`（CLI）与
// `test/i18n_wrapper_keys_test.dart`（守卫 + 反向验证）共用。
//
// 约定：
//   * [auditWrapperKeys] 接收 `路径 → 源码` 的映射，返回完整审计结果；
//   * 扫描前先剥掉注释（否则文档里的示例调用会被当成真调用），行号保持不变；
//   * ARB / dataTextMap 的已登记 key 由调用方传入，本文件只做比对。

/// 一处包装器调用点。
class WrapperCallSite {
  const WrapperCallSite({
    required this.file,
    required this.line,
    required this.wrapper,
    required this.key,
    required this.zh,
  });

  /// 源码文件路径（调用方给的 key）。
  final String file;

  /// 1 起的行号。
  final int line;

  /// 包装器名（`photoAiEdit` / `photoAiEditFill` / 局部 `worm` …）。
  final String wrapper;

  /// 解析出的 ARB key。
  final String key;

  /// 调用点写的中文回落原文。
  final String zh;
}

/// 一次全仓扫描的结果。
class WrapperKeyAudit {
  const WrapperKeyAudit({
    required this.wrapperNames,
    required this.callSites,
    required this.keyToZh,
    required this.keyToAllZh,
    required this.conflicts,
    required this.unresolvedRefs,
    required this.missingZh,
    required this.missingEn,
    required this.missingMap,
  });

  /// 发现的包装器函数名（含局部函数；不含 `dataText`）。
  final Set<String> wrapperNames;

  /// 全部匹配到的调用点。
  final List<WrapperCallSite> callSites;

  /// key → 首个中文回落（调用点顺序）。
  final Map<String, String> keyToZh;

  /// key → 全部出现过的中文回落（去重，用于冲突检测）。
  final Map<String, Set<String>> keyToAllZh;

  /// 同一 key 的多个调用点写了**不同**中文原文（`key = a | b`）。
  final List<String> conflicts;

  /// `XTextKeys.name` 引用了但常量没解析到（`Class.const` 形态）。
  final List<String> unresolvedRefs;

  /// 缺在 `app_zh.arb` 的 key。
  final Set<String> missingZh;

  /// 缺在 `app_en.arb` 的 key。
  final Set<String> missingEn;

  /// 缺在 `dataTextMap` 的 key。
  final Set<String> missingMap;

  int get uniqueKeys => keyToZh.length;

  /// 任一维度缺登记。
  bool get hasFindings =>
      missingZh.isNotEmpty ||
      missingEn.isNotEmpty ||
      missingMap.isNotEmpty ||
      unresolvedRefs.isNotEmpty;
}

/// 扫描给定的 `路径 → 源码`，与三张已登记 key 集合比对。
///
/// * [sources]：一般传 `lib/**/*.dart` 的路径与源码；
/// * [zhKeys] / [enKeys]：两套 ARB 的顶层消息 key；
/// * [mapKeys]：`lib/src/core/i18n/l10n.dart` 里 `dataTextMap` 的 key 集合。
WrapperKeyAudit auditWrapperKeys({
  required Map<String, String> sources,
  required Set<String> zhKeys,
  required Set<String> enKeys,
  required Set<String> mapKeys,
  bool identifierKeysOnly = false,
}) {
  // 注释先剥掉（保留换行 ⇒ 行号不变），避免文档示例被误当成调用点。
  // 按路径排序 ⇒ "首个中文回落"与冲突报告的挑选结果**可复现**。
  final stripped = <String, String>{};
  final paths = sources.keys.toList()..sort();
  for (final path in paths) {
    stripped[path] = stripComments(sources[path]!);
  }

  // ① 发现包装器：函数签名 `(String key, String zh)` + 委托调用 `name(key, zh)`。
  final wrappers = discoverWrappers(stripped);

  // ② 解析所有 `static const name = 'arbKey';`（按类归属）。
  final constants = discoverKeyConstants(stripped);

  // ②b 解析**顶层** `const String kFoo = 'arbKey';`（第 132 轮补的盲区：
  //     笔记模块把 key 写成顶层常量，首参是裸标识符而不是 `XTextKeys.name`，
  //     旧扫描器直接看不见 ⇒ 英文界面回落中文而两道守卫全绿）。
  final topConstants = discoverTopLevelKeyConstants(stripped);

  // ③ 收集调用点。
  final sites = <WrapperCallSite>[];
  final unresolved = <String>[];
  final keyToAllZh = <String, Set<String>>{};
  stripped.forEach((path, src) {
    for (final raw in scanWrapperCallSites(
      src,
      file: path,
      wrappers: wrappers,
      constants: constants,
      topConstants: topConstants,
      identifierKeysOnly: identifierKeysOnly,
    )) {
      if (raw.key == null) {
        if (raw.unresolvedRef != null) unresolved.add('${raw.file}:${raw.line} ${raw.unresolvedRef}');
        continue;
      }
      final site = WrapperCallSite(
        file: raw.file,
        line: raw.line,
        wrapper: raw.wrapper,
        key: raw.key!,
        zh: raw.zh,
      );
      sites.add(site);
      keyToAllZh.putIfAbsent(site.key, () => <String>{}).add(site.zh);
    }
  });

  final keyToZh = <String, String>{};
  for (final s in sites) {
    keyToZh.putIfAbsent(s.key, () => s.zh);
  }

  final conflicts = <String>[];
  keyToAllZh.forEach((key, values) {
    if (values.length > 1) {
      final sorted = values.toList()..sort();
      conflicts.add('$key = ${sorted.join(' | ')}');
    }
  });

  final missingZh = <String>{};
  final missingEn = <String>{};
  final missingMap = <String>{};
  for (final key in keyToZh.keys) {
    if (!zhKeys.contains(key)) missingZh.add(key);
    if (!enKeys.contains(key)) missingEn.add(key);
    if (!mapKeys.contains(key)) missingMap.add(key);
  }

  final wrapperNames = wrappers
      .where((w) => w != 'dataText' && w != 'Function')
      .toSet();

  return WrapperKeyAudit(
    wrapperNames: wrapperNames,
    callSites: sites,
    keyToZh: keyToZh,
    keyToAllZh: keyToAllZh,
    conflicts: conflicts,
    unresolvedRefs: unresolved,
    missingZh: missingZh,
    missingEn: missingEn,
    missingMap: missingMap,
  );
}

/// 发现的包装器函数名（不含 `dataText`）。
///
/// 判定标准：**声明**了 `String name(String key, String zh…)`，且函数体里
/// （直接或经其它包装器转调）以 `(key, zh)` 调到了 `dataText`。
/// 只靠"出现过 `name(key, zh)`"会把 `call` / `name` / `fill` 这类普通标识符
/// 误当包装器，进而把无关调用点算进来，所以必须要求声明 + 可达 `dataText`。
Set<String> discoverWrappers(Map<String, String> sources) {
  final edges = <String, Set<String>>{};
  final declRe = RegExp(
    r'\bString\s+([A-Za-z_]\w*)\s*\(\s*String\s+key\s*,\s*String\s+zh\s*[,)]',
  );
  final callRe = RegExp(r'\b([A-Za-z_]\w*)\s*\(\s*key\s*,\s*zh\s*\)');
  for (final src in sources.values) {
    for (final m in declRe.allMatches(src)) {
      final name = m.group(1)!;
      if (name == 'dataText' || name == 'Function') continue;
      final body = _functionBody(src, m.end);
      final calls = callRe.allMatches(body).map((c) => c.group(1)!).toSet();
      edges.putIfAbsent(name, () => <String>{}).addAll(calls);
    }
  }
  // 反向可达：哪些名字（经若干跳）能调到 dataText。
  final reaches = <String>{'dataText'};
  var changed = true;
  while (changed) {
    changed = false;
    edges.forEach((name, calls) {
      if (!reaches.contains(name) && calls.any(reaches.contains)) {
        reaches.add(name);
        changed = true;
      }
    });
  }
  reaches.remove('dataText');
  return reaches;
}

/// 取声明参数表之后的函数体（`=> expr` 取到顶层 `;`；`{ … }` 取整个块；
/// 抽象/typedef（直接 `;`）返回空串）。
String _functionBody(String src, int afterParams) {
  var i = afterParams;
  while (i < src.length &&
      (src[i] == ' ' || src[i] == '\n' || src[i] == '\r' || src[i] == '\t')) {
    i++;
  }
  if (i >= src.length) return '';
  if (src[i] == ';') return ''; // 抽象声明 / typedef
  if (src.startsWith('=>', i)) {
    final end = src.indexOf(';', i);
    return end < 0 ? src.substring(i) : src.substring(i, end);
  }
  if (src[i] == '{') {
    final end = _findBlockEnd(src, i);
    return end < 0 ? src.substring(i) : src.substring(i, end + 1);
  }
  // async / sync* 之类极少见；退化为取到下一个分号。
  final end = src.indexOf(';', i);
  return end < 0 ? '' : src.substring(i, end);
}

/// 解析 `<类名> → {常量名 → ARB key}`（`static const name = 'arbKey';`）。
Map<String, Map<String, String>> discoverKeyConstants(
  Map<String, String> sources,
) {
  final out = <String, Map<String, String>>{};
  final classRe = RegExp(r'\bclass\s+([A-Za-z_]\w*)');
  final constRe = RegExp(
    r"""static\s+const\s+([A-Za-z_]\w*)\s*=\s*'((?:[^'\\]|\\.)*)'""",
  );
  for (final src in sources.values) {
    for (final m in classRe.allMatches(src)) {
      final open = src.indexOf('{', m.end);
      if (open < 0) continue;
      final end = _findBlockEnd(src, open);
      if (end < 0) continue;
      final body = src.substring(open + 1, end);
      final entries = <String, String>{};
      for (final c in constRe.allMatches(body)) {
        entries[c.group(1)!] = _unescape(c.group(2)!);
      }
      if (entries.isNotEmpty) {
        out.putIfAbsent(m.group(1)!, () => <String, String>{}).addAll(entries);
      }
    }
  }
  return out;
}

/// 解析**顶层** `const String kFoo = 'arbKey';` → `{kFoo: arbKey}`。
///
/// 只认行首（允许缩进前的零个空格）的 `const String`，所以类里的
/// `static const` 不会被误收；`final` / 非字面量初始化一律跳过。
Map<String, String> discoverTopLevelKeyConstants(
  Map<String, String> sources,
) {
  final out = <String, String>{};
  final re = RegExp(
    r"""^const\s+String\s+([A-Za-z_]\w*)\s*=\s*'((?:[^'\\]|\\.)*)'\s*;""",
    multiLine: true,
  );
  for (final src in sources.values) {
    for (final m in re.allMatches(src)) {
      out[m.group(1)!] = _unescape(m.group(2)!);
    }
  }
  return out;
}

/// [scanWrapperCallSites] 的中间形态（key 可能没解析出来）。
class RawWrapperCallSite {
  const RawWrapperCallSite({
    required this.file,
    required this.line,
    required this.wrapper,
    required this.zh,
    this.key,
    this.unresolvedRef,
  });

  final String file;
  final int line;
  final String wrapper;
  final String zh;
  final String? key;
  final String? unresolvedRef;
}

/// **纯函数**：从一段源码里抽出所有包装器调用点。
///
/// 只认两种首参：`ClassName.constName`（需在 [constants] 里解析得到）或
/// 字符串字面量。第二参必须是中文字符串字面量。`wrapper` 必须在 [wrappers]
/// 里（`xxxFill` 在 `xxx` 是包装器时也算）。
List<RawWrapperCallSite> scanWrapperCallSites(
  String source, {
  String file = '',
  required Set<String> wrappers,
  required Map<String, Map<String, String>> constants,
  Map<String, String> topConstants = const <String, String>{},
  bool identifierKeysOnly = false,
}) {
  final out = <RawWrapperCallSite>[];
  // group1 = 包装器名；group2 = 类名；group3 = 常量名；group4 = 字面量 key；
  // group5 = **顶层常量裸标识符**（`kFoo`）。
  // 中文回落由 [_parseAdjacentStringLiterals] 手工解析（要处理
  // `'前半句' '后半句'` 这种 Dart 相邻字面量拼接）。
  final re = RegExp(
    r"""([A-Za-z_]\w*)\s*\(\s*(?:([A-Za-z_]\w*)\.([A-Za-z_]\w*)|'((?:[^'\\]|\\.)*)'|([A-Za-z_]\w*))\s*,\s*""",
    multiLine: true,
  );
  for (final m in re.allMatches(source)) {
    final wrapper = m.group(1)!;
    if (!_isWrapper(wrapper, wrappers)) continue;
    final className = m.group(2);
    final constName = m.group(3);
    final literalKey = m.group(4);
    final bareName = m.group(5);
    // 跳过空格后必须是字符串字面量；把相邻的多个字面量拼成一个回落原文。
    final parsed = _parseAdjacentStringLiterals(source, m.end);
    if (parsed == null) continue;
    final zh = _unescape(parsed.value);
    // 口径：第二参必须是**静态中文字面量**。Dart 插值（`$…`）是运行时拼的，
    // 不是可登记的回落原文；纯 ASCII 的（如 API 目录的 `'create'`）也不是。
    if (!_hasCjk(zh) || zh.contains(r'$')) continue;
    final line = _lineOf(source, m.start);
    if (literalKey != null) {
      if (identifierKeysOnly) continue;
      out.add(RawWrapperCallSite(
        file: file,
        line: line,
        wrapper: wrapper,
        key: _unescape(literalKey),
        zh: zh,
      ));
      continue;
    }
    // 顶层常量裸标识符（`noteB(kNoteSharedTitle, '我分享的')`）。
    // 只在常量表里解析得到时算调用点；解析不到（局部变量等）跳过。
    if (className == null && constName == null && literalKey == null) {
      final resolvedBare = bareName == null ? null : topConstants[bareName];
      if (resolvedBare != null) {
        out.add(RawWrapperCallSite(
          file: file,
          line: line,
          wrapper: wrapper,
          key: resolvedBare,
          zh: zh,
        ));
      }
      continue;
    }
    // `XTextKeys.name` 形态：优先当 key 解析；解析不到且类名像 keys 类 ⇒ 报未解析。
    // 只认 `*TextKeys` 类（本仓 1560 个 key 常量都在这些类里）；其它
    // `Enum.value` 首参不是文案 key，跳过。
    if (className == null || !className.endsWith('TextKeys')) continue;
    final resolved = constants[className]?[constName];
    if (resolved != null) {
      out.add(RawWrapperCallSite(
        file: file,
        line: line,
        wrapper: wrapper,
        key: resolved,
        zh: zh,
      ));
    } else {
      out.add(RawWrapperCallSite(
        file: file,
        line: line,
        wrapper: wrapper,
        zh: zh,
        unresolvedRef: '$className.$constName',
      ));
    }
  }
  return out;
}

class _ParsedString {
  const _ParsedString(this.value, this.end);
  final String value;
  final int end;
}

/// 从 [pos] 起解析**相邻字符串字面量拼接**：`'a' 'b'` → `ab`。
///
/// Dart 里相邻字面量等价于拼接（本仓数据层文案常这么折行）。只吃
/// "跳过空白后仍是引号"的字面量；遇到 `,` / `)` 等即停。
/// 返回第一个字面量的原始（未反转义）内容与结束位置；不是字面量则返回 null。
_ParsedString? _parseAdjacentStringLiterals(String source, int pos) {
  var i = _skipSpace(source, pos);
  if (i >= source.length) return null;
  final quote = source[i];
  if (quote != "'" && quote != '"') return null;
  final first = _parseOneString(source, i);
  if (first == null) return null;
  final buf = StringBuffer(first.value);
  var end = first.end;
  while (true) {
    final j = _skipSpace(source, end);
    if (j >= source.length) break;
    final q = source[j];
    if (q != "'" && q != '"') break;
    final more = _parseOneString(source, j);
    if (more == null) break;
    buf.write(more.value);
    end = more.end;
  }
  return _ParsedString(buf.toString(), end);
}

_ParsedString? _parseOneString(String source, int start) {
  if (start >= source.length) return null;
  final quote = source[start];
  if (quote != "'" && quote != '"') return null;
  final buf = StringBuffer();
  var i = start + 1;
  while (i < source.length) {
    final c = source[i];
    if (c == r'\') {
      if (i + 1 >= source.length) return null;
      buf.write(c);
      buf.write(source[i + 1]);
      i += 2;
      continue;
    }
    if (c == quote) return _ParsedString(buf.toString(), i + 1);
    if (c == '\n') return null; // 未闭合
    buf.write(c);
    i++;
  }
  return null;
}

int _skipSpace(String source, int i) {
  while (i < source.length &&
      (source[i] == ' ' ||
          source[i] == '\n' ||
          source[i] == '\r' ||
          source[i] == '\t')) {
    i++;
  }
  return i;
}

/// 中日韩字符 + 全角标点。
final _cjkRe = RegExp(r'[\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF]');

bool _hasCjk(String s) => _cjkRe.hasMatch(s);

bool _isWrapper(String name, Set<String> wrappers) {
  if (wrappers.contains(name)) return true;
  if (name.endsWith('Fill')) {
    return wrappers.contains(name.substring(0, name.length - 4));
  }
  return false;
}

/// 剥离 `//` 与 `/* */` 注释（保留换行，行号不变）。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  final n = src.length;
  while (i < n) {
    final c = src[i];
    final d = i + 1 < n ? src[i + 1] : '';
    // 字符串字面量原样保留（值里可能有 `{...}` 或 `//`）。
    if (c == "'" || c == '"') {
      final q = c;
      // 三引号
      if (i + 2 < n && src[i + 1] == q && src[i + 2] == q) {
        out.write(src.substring(i, i + 3));
        i += 3;
        while (i < n) {
          if (src[i] == q && i + 2 < n && src[i + 1] == q && src[i + 2] == q) {
            out.write(src.substring(i, i + 3));
            i += 3;
            break;
          }
          out.write(src[i]);
          i++;
        }
        continue;
      }
      out.write(c);
      i++;
      while (i < n) {
        final ch = src[i];
        if (ch == '\\' && i + 1 < n) {
          out.write(ch);
          out.write(src[i + 1]);
          i += 2;
          continue;
        }
        out.write(ch);
        i++;
        if (ch == q) break;
      }
      continue;
    }
    if (c == '/' && d == '/') {
      while (i < n && src[i] != '\n') {
        out.write(' ');
        i++;
      }
      continue;
    }
    if (c == '/' && d == '*') {
      var depth = 1;
      out.write('  ');
      i += 2;
      while (i < n && depth > 0) {
        if (src[i] == '/' && i + 1 < n && src[i + 1] == '*') {
          depth++;
          out.write('  ');
          i += 2;
          continue;
        }
        if (src[i] == '*' && i + 1 < n && src[i + 1] == '/') {
          depth--;
          out.write('  ');
          i += 2;
          continue;
        }
        out.write(src[i] == '\n' ? '\n' : ' ');
        i++;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

int _findBlockEnd(String s, int openBrace) {
  var depth = 0;
  var i = openBrace;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      final q = c;
      i++;
      while (i < s.length) {
        if (s[i] == '\\') {
          i += 2;
          continue;
        }
        if (s[i] == q) {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}

int _lineOf(String s, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < s.length; i++) {
    if (s[i] == '\n') line++;
  }
  return line;
}

String _unescape(String s) {
  final b = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == '\\' && i + 1 < s.length) {
      final d = s[i + 1];
      switch (d) {
        case "'":
          b.write("'");
          break;
        case '\\':
          b.write('\\');
          break;
        case 'n':
          b.write('\n');
          break;
        case 't':
          b.write('\t');
          break;
        case r'$':
          b.write(r'$');
          break;
        default:
          b.write(d);
      }
      i += 2;
      continue;
    }
    b.write(c);
    i++;
  }
  return b.toString();
}
