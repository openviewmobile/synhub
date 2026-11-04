// 占位符文案「防复发」测试。
//
// 背景（真机可见缺陷）：ARB 里带占位符的 key（例如 `pbTargetPathLabel` =
// `落点路径：{path}`）经由 `dataText` 的 **key + 中文原文** 字符串通道取词时，
// 拿到的是**模板**；调用点若不 `replaceAll`（或不用 `*Fill` 包装），界面就会把
// `{path}` / `{name}` 这类原始模板直接画出来。`photo_backup_page.dart` 的
// Drive 落点卡片就是这么漏的（真机 `落点路径：{path}`）。
//
// 这个测试做**静态源码扫描**，对 ARB 里声明的**每一个**带占位符的 key，检查它
// 在 `lib/` 里的每一处字符串通道使用点：
//   * 要么走 `*Fill` / `fill` / `at` 这类会替换占位符的包装；
//   * 要么在**同一个调用表达式**（含 `.replaceAll(...)` 链与紧跟的几行）里，
//     对**每一个**占位符都出现 `replaceAll('{name}', …)`；
//   * `l10n.dart` 的 `dataTextMap`（模板产地）与 `static const` 别名声明不算使用点；
//   * 生成 getter 直调（`t.xxx(v)`）由编译器保证参数齐全，不在扫描范围。
//
// 另有渲染层断言（`test/photo_backup_background_test.dart` 的
// 「装了翻译表后不得漏占位符」），二者共同挡住回归。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/features/notes/note_reminder.dart';

/// 取词包装：函数体是 `dataText(key, zh)` 的薄封装。它们的第一个参数是 ARB key，
/// 返回的是**模板**（带占位符时），所以调用点必须自己填。
const Set<String> _textWrappers = {
  'dataText',
  'pbText',
  'noteB',
  'noteC3',
  'noteDrawingText',
  'fsC5',
  'fsP0a',
  'fsP0b',
  'photoAiEdit',
  'photoC2',
  'photoMap',
  'photoP0',
  'photoP1',
  'driveP0',
  'driveC1',
  'serviceText',
  'officeDocText',
  'officeSheetText',
  'officeSlidesText',
  '_t',
};

/// 自己就会替换占位符的包装（名字不一定以 `Fill` 结尾）。
const Set<String> _fillHelpers = {
  'fill',
  'at',
  '_fill',
  'officeDocFillText',
  'officeSheetFillText',
  'officeSlidesFillText',
};

/// 这些 fill 包装按**固定的**占位符名替换（不看调用点传的 map），
/// 所以不检查调用点参数：`fill` 只管 `{tail}/{code}/{url}`，`at` 只管 `{host}`。
const Set<String> _fixedPlaceholderFillers = {'fill', 'at'};

/// 已知的「延迟填充」调用点：字符串在这里仍含占位符，但会被下游 widget 填掉。
///
/// 键是 `<lib 相对路径>|<ARB key>`；每条都写明下游填充者，避免变成万能豁免。
const Set<String> _deferredFillSites = {
  // `_DegradedCard` 内部用 `officeDocFillText(label, {'name': detail})` 填。
  'lib/src/features/office/office_doc_view.dart|officeDocUnsupportedUnknown',
  'lib/src/features/office/office_doc_view.dart|officeDocUnsupportedType',
};

final RegExp _placeholderRe = RegExp(r'\{([a-zA-Z_]\w*)\}');
final RegExp _keyConstRe = RegExp(r"const\s+(\w+)\s*=\s*'([^']+)'\s*;");
final RegExp _stringLitRe = RegExp(r"'([A-Za-z_]\w*)'");
final RegExp _qualifiedAliasRe = RegExp(r'\b([A-Z]\w*)\.(\w+)\b');
final RegExp _constDeclRe = RegExp(r'^\s*(static\s+)?const\s+\w+\s*=');
final RegExp _classRe = RegExp(
  r'^\s*(?:abstract\s+final\s+|abstract\s+)?class\s+(\w+)',
);

/// ARB key → 占位符名集合（只取 zh 模板；`app_en.arb` 占位符与之同名）。
Map<String, Set<String>> _placeholderKeys(String arbPath) {
  final raw = jsonDecode(File(arbPath).readAsStringSync());
  final out = <String, Set<String>>{};
  raw.forEach((k, v) {
    if (k.startsWith('@') || v is! String) return;
    final names = _placeholderRe.allMatches(v).map((m) => m.group(1)!).toSet();
    if (names.isNotEmpty) out[k] = names;
  });
  return out;
}

/// `static const alias = '<placeholder key>';` → `Class.alias` → key
///
/// 用**全限定名**做键：不同 *_text.dart 里常有好几个同名成员
/// （`NoteC3TextKeys.exportFailed` vs `NoteDrawingTextKeys.exportFailed`），
/// 只按成员名会串味。
Map<String, String> _keyAliases(List<File> files, Set<String> placeholderKeys) {
  final alias = <String, String>{};
  for (final f in files) {
    String? currentClass;
    for (final line in f.readAsLinesSync()) {
      // 顶层 class 收尾（`}` 顶格）→ 复位；比数花括号稳（字符串里也有 `{}`）。
      if (RegExp(r'^\}').hasMatch(line)) currentClass = null;
      currentClass ??= _classRe.firstMatch(line)?.group(1);
      final m = _keyConstRe.firstMatch(line);
      if (m != null &&
          currentClass != null &&
          placeholderKeys.contains(m.group(2))) {
        alias['$currentClass.${m.group(1)}'] = m.group(2)!;
      }
    }
  }
  return alias;
}

/// 从 [open] 处的 `(` 起，返回配对 `)` 的下标。
int _matchParen(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    if (s[i] == '(') {
      depth++;
    } else if (s[i] == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return s.length - 1;
}

/// 包住 [open] 处调用的表达式：调用本身 + 后续 `.method(...)` 链。
String _callExpression(String src, int open) {
  var end = _matchParen(src, open);
  while (true) {
    var i = end + 1;
    while (i < src.length && (src[i] == ' ' || src[i] == '\n')) {
      i++;
    }
    if (i >= src.length || src[i] != '.') break;
    i++;
    while (i < src.length && (src[i] == ' ' || src[i] == '\n')) {
      i++;
    }
    while (i < src.length && RegExp(r'\w').hasMatch(src[i])) {
      i++;
    }
    while (i < src.length && (src[i] == ' ' || src[i] == '\n')) {
      i++;
    }
    if (i >= src.length || src[i] != '(') break;
    end = _matchParen(src, i);
  }
  return src.substring(open, end + 1);
}

String _baseName(String call) => call.split('.').last;

void main() {
  group('占位符使用点静态扫描（lib 源码）', () {
    test('每个带占位符的 ARB key 的字符串通道使用点都替换了全部占位符', () {
      final placeholders = _placeholderKeys('lib/l10n/app_zh.arb');
      expect(placeholders, isNotEmpty, reason: 'app_zh.arb 里应当有带占位符的 key');

      final libFiles =
          Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .where((f) => !f.path.contains('l10n/gen/'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

      final aliases = _keyAliases(libFiles, placeholders.keys.toSet());
      final failures = <String>[];

      for (final file in libFiles) {
        final rel = file.path.replaceAll('\\', '/');
        // `dataTextMap` 是模板产地，不是使用点。
        if (rel.endsWith('core/i18n/l10n.dart')) continue;
        final src = file.readAsStringSync();
        final lines = src.split('\n');
        final lineOffsets = <int>[];
        var running = 0;
        for (final l in lines) {
          lineOffsets.add(running);
          running += l.length + 1;
        }
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          // `static const alias = 'key';` 是声明，不是使用点。
          if (_constDeclRe.hasMatch(line)) continue;

          final sites = <String>{};
          for (final m in _stringLitRe.allMatches(line)) {
            final k = m.group(1)!;
            if (placeholders.containsKey(k)) sites.add(k);
          }
          for (final m in _qualifiedAliasRe.allMatches(line)) {
            final key = aliases['${m.group(1)}.${m.group(2)}'];
            if (key != null) sites.add(key);
          }
          if (sites.isEmpty) continue;

          for (final key in sites) {
            final pos = _keyOffset(line, key, aliases);
            if (pos < 0) continue;
            final off = lineOffsets[i] + pos;
            final call = _enclosingCall(src, off);
            if (call == null) continue;
            final base = _baseName(call.$1);
            final isFill = base.endsWith('Fill') || _fillHelpers.contains(base);
            if (!_textWrappers.contains(base) && !isFill) continue;
            if (_deferredFillSites.contains('$rel|$key')) continue;

            final expr = _callExpression(src, call.$2);
            // 同一调用点可见的替换：表达式本身或紧跟的几行里。
            final lookaheadEnd = (i + 9) < lines.length ? i + 9 : lines.length;
            final lookahead = lines.sublist(i + 1, lookaheadEnd);
            final window = '$expr\n${lookahead.join('\n')}';
            if (isFill && _fixedPlaceholderFillers.contains(base)) {
              // 这些包装自己按固定占位符名替换（如 `fill` 只管 tail/code/url）。
              continue;
            }
            final missing = isFill
                // `*Fill(key, zh, {'name': v})`：每个占位符都要出现在 values 里。
                ? placeholders[key]!
                      .where(
                        (p) =>
                            !window.contains("'$p':") &&
                            !window.contains('"$p":'),
                      )
                      .toList()
                // 普通包装拿到的是模板，必须显式 `replaceAll('{p}', …)`。
                : placeholders[key]!
                      .where(
                        (p) => !RegExp(
                          "replaceAll\\(\\s*['\"]\\{$p\\}",
                        ).hasMatch(window),
                      )
                      .toList();
            if (missing.isNotEmpty) {
              failures.add(
                '$rel:${i + 1}  key=$key  call=$base  '
                '缺替换={${missing.join(',')}}\n    ${line.trim()}',
              );
            }
          }
        }
      }

      expect(
        failures,
        isEmpty,
        reason:
            '带占位符的 key 在字符串通道上必须替换全部占位符（用 *Fill，'
            '或同调用点 replaceAll）。漏掉的调用点：\n${failures.join('\n')}',
      );
    });
  });

  // 静态扫描看不到「key 存在字段里、再经包装取值」的链路（例如
  // `TodoReminderPreset.label` → `noteB(labelKey, …)`）。这类点用取值断言补：
  // 装了翻译表之后，ARB 模板里的占位符必须已经被替换掉。
  group('占位符取值断言（装了翻译表之后）', () {
    test('提醒预设：noteBReminderBefore 的 {value}/{unit} 必须已替换', () {
      addTearDown(() => setCurrentText(AppTextZh()));
      setCurrentText(AppTextZh());
      expect(
        todoReminderPresets.length,
        greaterThanOrEqualTo(6),
        reason: '官方 6 个提醒预设',
      );
      for (final preset in todoReminderPresets) {
        expect(
          preset.label.contains('{'),
          isFalse,
          reason: '预设 ${preset.offsetSeconds} 的文案漏占位符：${preset.label}',
        );
      }
      final half = todoReminderPresets.firstWhere(
        (p) => p.offsetSeconds == TodoReminderPlanner.offsetBefore30Min,
      );
      expect(half.label, '提前 30 分钟');

      setCurrentText(AppTextEn());
      for (final preset in todoReminderPresets) {
        expect(
          preset.label.contains('{'),
          isFalse,
          reason: '英文下预设 ${preset.offsetSeconds} 漏占位符：${preset.label}',
        );
      }
      expect(
        todoReminderPresets
            .firstWhere(
              (p) => p.offsetSeconds == TodoReminderPlanner.offsetBefore30Min,
            )
            .label,
        '30 minute(s) before',
      );
    });
  });

  // ★ r339（D38）：官方 Synology Chat 的字符串池里有一类**运行时变量名**——
  // `{post}` / `{this message}` / `{ 此信息 }` / `[_SUBST_1_]` / `%1$s`。
  // 早期轮次从池子里抄文案时，把变量名当成了正文（官方 zh-CN 自己也没替换），
  // 于是真机聊天页的系统事件被直接画成 `已锁定 this message` / `已创建一篇 post。`。
  // 判据：去掉 ICU 占位符与括号里的技术说明之后，**正文里不许再出现这些变量名**。
  group('官方变量名泄漏（文案防复发）', () {
    test('app_zh.arb 里不许把官方运行时变量名当正文', () {
      final leaks = _leakedOfficialVars('lib/l10n/app_zh.arb');
      expect(
        leaks,
        isEmpty,
        reason:
            '这些 key 把官方字符串池里的变量名当正文画给用户了（应写成中文）：\n'
            '${leaks.join('\n')}',
      );
    });

    test('反向：同一判据必须能抓到伪造的泄漏串，且不误伤合法占位符', () {
      // 真实缺陷样本（r339 真机像素里出现的就是这两条）
      expect(_leakHits('已锁定 this message'), isNotEmpty);
      expect(_leakHits('已创建一篇 post。'), isNotEmpty);
      expect(_leakHits('[_SUBST_1_] 已邀请 [_SUBST_2_] 进入此频道。'), isNotEmpty);
      // `$s` 会被 Dart 当插值 ⇒ 这条必须用**原始字符串**。
      expect(_leakHits(r'已邀请 %1$s。'), isNotEmpty);
      expect(_leakHits('已创建一篇 {post}。'), isNotEmpty);
      // 合法文案：不许误报
      expect(_leakHits('已锁定此消息'), isEmpty);
      expect(_leakHits('{actor} 已在帖子中留言。'), isEmpty);
      expect(_leakHits('模型返回了错误：{message}'), isEmpty);
      expect(_leakHits('Service Busy（SYNO.API 错误码 105）'), isEmpty);
    });
  });
}

/// key 在 [line] 上的下标：字符串字面量或 `Class.alias` 形式。
int _keyOffset(String line, String key, Map<String, String> aliases) {
  final lit = line.indexOf("'$key'");
  if (lit >= 0) return lit;
  for (final m in _qualifiedAliasRe.allMatches(line)) {
    if (aliases['${m.group(1)}.${m.group(2)}'] == key) return m.start;
  }
  return -1;
}

/// 官方 Synology Chat（2.11.1-607）字符串池里的**运行时变量名**，不是正文。
/// 花括号形态单独一组：它们必须先于「摘掉 ICU 占位符」被检查。
final List<RegExp> _officialVarBracedRe = <RegExp>[
  RegExp(r'\{\s*post\s*\}'),
  RegExp(r'\{\s*this message\s*\}'),
  RegExp(r'\{\s*此信息\s*\}'),
];

/// 裸露（无花括号）形态：官方变量名被当成正文抄进 ARB 的样子。
final List<RegExp> _officialVarBareRe = <RegExp>[
  RegExp(r'\bpost\b'),
  RegExp(r'\bthis message\b'),
  // 官方串池里的形状是 `[_SUBST_1_]`（**数字后面还有一条下划线**）。
  RegExp(r'\[_SUBST_\d+_?\]'),
  RegExp(r'%\d+\$[sd]'),
];

/// 扫描前先摘掉 ICU 占位符/复数与括号里的技术说明（它们合法）。
String _stripForLeakScan(String v) {
  var s = v.replaceAll(RegExp(r'\{[^}]*\}'), '');
  s = s.replaceAll(RegExp(r'（[^）]*）'), '');
  return s.replaceAll(RegExp(r'\([^)]*\)'), '');
}

/// 一条文案命中的官方变量名（空 = 干净）。
List<String> _leakHits(String value) {
  final s = _stripForLeakScan(value);
  return <String>[
    for (final re in _officialVarBracedRe)
      if (re.hasMatch(value)) re.pattern,
    for (final re in _officialVarBareRe)
      if (re.hasMatch(s)) re.pattern,
  ];
}

/// 整个 ARB 里所有"把官方变量名当正文"的 key（空 = 干净）。
List<String> _leakedOfficialVars(String arbPath) {
  final raw =
      jsonDecode(File(arbPath).readAsStringSync()) as Map<String, dynamic>;
  final out = <String>[];
  raw.forEach((k, v) {
    if (k.startsWith('@') || v is! String) return;
    final hits = _leakHits(v);
    if (hits.isNotEmpty) out.add('$k = $v  <<${hits.join(',')}');
  });
  return out;
}

/// 包住 [off] 的最近一层调用：返回 (调用名, `(` 下标)。
(String, int)? _enclosingCall(String src, int off) {
  var depth = 0;
  for (var i = off - 1; i > 0; i--) {
    final ch = src[i];
    if (ch == ')') {
      depth++;
    } else if (ch == '(') {
      if (depth == 0) {
        final m = RegExp(
          r'([\w.]+)\s*$',
        ).firstMatch(src.substring((i - 60).clamp(0, i), i));
        return m == null ? null : (m.group(1)!, i);
      }
      depth--;
    }
  }
  return null;
}
