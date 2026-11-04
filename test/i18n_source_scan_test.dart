// 守卫：`lib/src` 里**不许**再出现"界面位置上的硬编码中文"。
//
// 背景（AGENTS.md §2.0.13）：用户 2026-09-26 报「界面上还是有很多中英文串到一起的」。
// 根因有两类，本用例只盯第二类：
//   * ① 数据层的 `dataText('key', '中文')` 没登记进 `dataTextMap` —— 由
//     `test/i18n_coverage_test.dart` 守卫；
//   * ② **界面代码里直接写死中文**（`Text('我的 NAS')` / `tooltip: '添加 NAS'` /
//     `labelText: '名称'`…）—— 完全绕开 i18n，英文模式下必然漏中文。
//
// 口径（与第 260 轮普查脚本一致）：
//   * UI 位置 = `Text(...)` 的实参区，或 `tooltip|label|labelText|hintText|
//     helperText|title|message|subtitle|content|semanticLabel|errorText|
//     counterText|prefixText|suffixText|decoration|description` 之后紧跟的
//     字符串字面量；
//   * 注释、`lib/src/core/i18n/`（翻译层自身）、以及**翻译助手的第 2 实参**
//     （`dataText('k','中文')` / `photoC2(Key.x,'中文')` / `fsG4(...)` …）
//     都**不算**——那正是 i18n 入口；
//   * 相邻字符串拼接（Dart 的 `'a' 'b'`）会逐段检查。
//
// 两条例外：
//   * `_allowlist`：解析层生成的**哨兵标题**，视图层会按语言重写
//     （`file_book_view.dart` 的 `bookChapterTitle()`），中文永远不会上屏；
//   * `_foreignOwned`：由**另一个批次**负责的 6 个音视频文件（本轮不许动），
//     只在旁边盯住"别变多"。
//
// 规矩：新增界面文案一律 `context.t.xxx`（ARB 双语）或
// `dataText('key','中文')` + 登记 `dataTextMap`；真要例外，必须在
// `_allowlist` 里写清理由——**没有理由的例外不许进**。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 中日韩字符 + 全角标点（与 `i18n_coverage_test.dart` 同一口径）。
final RegExp _cjk = RegExp(r'[\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF]');

/// 允许例外：`<相对路径>|<字面量>` → 理由。**必须写明理由**。
///
/// 这些是**解析层生成的哨兵标题**，不是给用户看的文案：`BookChapter.generatedUnit`
/// 标记了它是"第 N 章/节/正文"，视图层 `bookChapterTitle()`（
/// `lib/src/features/files/file_book_view.dart`）会按当前语言改写成
/// `t.bookChapterN/bookSectionN/bookBodyText`。所以中文只是内部约定值，
/// 英文模式下不会上屏。
const Map<String, String> _allowlist = <String, String>{
  // 本轮（i18n 清理）后只剩这一条：book_mobi 的 MOBI/PalmDOC 分页哨兵标题。
  // 它带 `generatedUnit: BookGeneratedUnit.chapter`，视图层
  // `file_book_view.dart` 按 generatedUnit 重写成 `t.bookChapterN(index+1)`
  // ⇒ 中文只是解析层内部约定值，英文模式不会上屏。
  // （book_chm/book_text 的同型哨兵本轮已改为 `fsT/fsTFill`，条目随之删除。）
  'lib/src/features/files/book_mobi.dart|第 \${chapters.length + 1} 章':
      'BookGeneratedUnit.chapter 哨兵；视图层 → t.bookChapterN',
};

/// 由**另一个批次**负责的 6 个音视频文件（本轮明确不许改）。
///
/// 只断言"数量不增加"，这样那一批改完自然还是绿的，也不需要改本用例。
const Map<String, String> _foreignOwned = <String, String>{
  'lib/src/features/audio/audio_song_page.dart': '★ 别批次负责',
  'lib/src/features/audio/audio_page.dart': '★ 别批次负责',
  'lib/src/features/media/media_audio_stage.dart': '★ 别批次负责',
  'lib/src/features/media/media_player_view.dart': '★ 别批次负责',
  'lib/src/features/media/audio_lyrics.dart': '★ 别批次负责',
  'lib/src/features/media/audio_visualizer.dart': '★ 别批次负责',
};

/// 第 260 轮普查时这 6 个文件里的硬编码中文基线（只许 ≤）。
const int _foreignOwnedBaseline = 0;

const String _keysPattern =
    r'tooltip|label|labelText|hintText|helperText|title|message|subtitle|'
    r'content|semanticLabel|errorText|counterText|prefixText|suffixText|'
    r'decoration|description';

class _Hit {
  _Hit(this.path, this.line, this.kind, this.value);
  final String path;
  final int line;
  final String kind;
  final String value;
}

/// 去掉 `//` 与 `/* */` 注释（保持换行数，行号不乱）。
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  final n = src.length;
  while (i < n) {
    final c = src[i];
    if (c == '/' && i + 1 < n && src[i + 1] == '/') {
      final j = src.indexOf('\n', i);
      if (j < 0) break;
      i = j;
      continue;
    }
    if (c == '/' && i + 1 < n && src[i + 1] == '*') {
      final j = src.indexOf('*/', i + 2);
      if (j < 0) break;
      final seg = src.substring(i, j);
      out.write('\n' * '\n'.allMatches(seg).length);
      i = j + 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

int _skipString(String s, int i) {
  final q = s[i];
  i++;
  while (i < s.length) {
    if (s[i] == '\\') {
      i += 2;
      continue;
    }
    if (s[i] == q) return i + 1;
    i++;
  }
  return i;
}

int _matchParen(String s, int i) {
  var depth = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      continue;
    }
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i + 1;
    }
    i++;
  }
  return s.length;
}

int _lineNo(String s, int off) {
  var n = 1;
  for (var i = 0; i < off; i++) {
    if (s.codeUnitAt(i) == 10) n++;
  }
  return n;
}

int _prevLiteralStart(String s, int end) {
  var j = end - 1;
  while (j >= 0) {
    if (s[j] == "'") {
      var bs = 0;
      var k = j - 1;
      while (k >= 0 && s[k] == '\\') {
        bs++;
        k--;
      }
      if (bs % 2 == 0) return j;
    }
    j--;
  }
  return -1;
}

/// 这个字面量是不是翻译助手的实参（`helper(<key>, '中文')`，含相邻拼接）？
bool _isTranslatorArg(String s, int litStart) {
  var i = litStart - 1;
  while (true) {
    while (i >= 0 && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n')) {
      i--;
    }
    if (i >= 0 && s[i] == "'") {
      // 前一个字面量属于同一个实参（Dart 相邻字符串拼接），跨过去
      final st = _prevLiteralStart(s, i);
      if (st < 0) break;
      i = st - 1;
      continue;
    }
    break;
  }
  if (i < 0 || s[i] != ',') return false;
  var depth = 0;
  var j = i - 1;
  while (j >= 0) {
    final c = s[j];
    if (c == ')') {
      depth++;
    } else if (c == '(') {
      if (depth == 0) return s.substring(j + 1, i).trim().isNotEmpty;
      depth--;
    } else if (c == "'" || c == '"') {
      final q = c;
      j--;
      while (j >= 0 && s[j] != q) {
        if (s[j] == '\\') j--;
        j--;
      }
    }
    j--;
  }
  return false;
}

/// 单个引号字符串字面量（跨行的不算，避免把整块当一句）。
Iterable<(int, String)> _singleQuoted(String s, int from, int to) sync* {
  var i = from;
  while (i < to) {
    if (s[i] == "'") {
      final end = _skipString(s, i);
      final raw = s.substring(i + 1, end - 1);
      if (!raw.contains('\n')) yield (i, raw);
      i = end;
    } else {
      i++;
    }
  }
}

List<_Hit> _scan() {
  final hits = <_Hit>[];
  final dir = Directory('lib/src');
  if (!dir.existsSync()) {
    throw StateError('用例必须在包根目录跑（flutter test 默认如此）');
  }
  final files =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          // 设计稿原型（lib/src/design/）：中英文成对写在 `_zh ? … : …` 里，
          // 文案即设计源；只经 dev 档画廊可达，release 不被引用。
          .where((f) => !f.path.startsWith('lib/src/design/'))
          .map((f) => f.path)
          .toList()
        ..sort();

  final textRe = RegExp(r'Text\(');
  final keyRe = RegExp('($_keysPattern)\\s*:\\s*');

  for (final abs in files) {
    final rel = abs
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^.*?lib/src/'), 'lib/src/');
    if (rel.contains('/core/i18n/')) continue;
    final src = _stripComments(File(abs).readAsStringSync());

    // ① `Text(...)` 实参区里的中文字面量
    for (final m in textRe.allMatches(src)) {
      final prev = m.start == 0 ? '' : src[m.start - 1];
      if (RegExp(r'[A-Za-z0-9_$.]').hasMatch(prev)) continue; // FooText(
      final start = m.end - 1;
      final end = _matchParen(src, start);
      for (final (off, v) in _singleQuoted(src, start, end)) {
        if (!_cjk.hasMatch(v)) continue;
        if (_isTranslatorArg(src, off)) continue;
        hits.add(_Hit(rel, _lineNo(src, off), 'Text', v));
      }
    }

    // ② `tooltip: '中文'` 这类命名参数
    for (final m in keyRe.allMatches(src)) {
      final prev = m.start == 0 ? '' : src[m.start - 1];
      if (RegExp(r'[A-Za-z0-9_.]').hasMatch(prev)) continue; // xxxLabel:
      final pre = src.substring(m.start < 40 ? 0 : m.start - 40, m.start);
      if (RegExp(r'dataText\s*\(\s*$').hasMatch(pre)) continue;
      var j = m.end;
      while (j < src.length && (src[j] == ' ' || src[j] == '\n')) {
        j++;
      }
      if (j >= src.length || src[j] != "'") continue;
      for (final (off, v) in _singleQuoted(src, j, src.length)) {
        if (!_cjk.hasMatch(v)) break;
        if (!_isTranslatorArg(src, off)) {
          hits.add(_Hit(rel, _lineNo(src, off), m.group(1)!, v));
        }
        break;
      }
    }
  }

  // 去重（同一行同一字面量只算一次）
  final seen = <String>{};
  return hits
      .where((h) => seen.add('${h.path}|${h.line}|${h.value}'))
      .toList();
}

void main() {
  final hits = _scan();

  test('界面位置不许出现硬编码中文（allowlist 之外一处都不许有）', () {
    final allowed = <String>{};
    final violations = <String>[];
    for (final h in hits) {
      final key = '${h.path}|${h.value}';
      if (_allowlist.containsKey(key)) {
        allowed.add(key);
        continue;
      }
      if (_foreignOwned.containsKey(h.path)) continue;
      violations.add('${h.path}:${h.line}  ${h.kind}  ${h.value}');
    }
    expect(
      violations,
      isEmpty,
      reason: '这些界面文案没走 i18n；请改 context.t.xxx（ARB 双语）或 '
          'dataText(\'key\',\'中文\') + 登记 dataTextMap：\n${violations.join('\n')}',
    );

    // 反向验证：allowlist 里写了的必须真的命中，否则是失效条目（该删）
    final stale = _allowlist.keys.where((k) => !allowed.contains(k)).toList();
    expect(
      stale,
      isEmpty,
      reason: 'allowlist 条目已不再命中（代码变了），请删掉：$stale',
    );
  });

  test('别批次负责的 6 个音视频文件：硬编码中文不许变多', () {
    final others = hits.where((h) => _foreignOwned.containsKey(h.path)).length;
    expect(
      others,
      lessThanOrEqualTo(_foreignOwnedBaseline),
      reason:
          '第 260 轮基线 $_foreignOwnedBaseline 处（${_foreignOwned.length} 个文件，'
          '由另一批次清理）；现在 $others 处 ⇒ 有人在里面新增了硬编码中文。',
    );
  });

  test('普查确实扫到了文件（防空转）', () {
    // 扫描逻辑坏掉时会静默 0 命中，这条防止"假绿"。
    final dartFiles = Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .length;
    expect(dartFiles, greaterThan(300), reason: 'lib/src 下 .dart 文件数应远大于 300');
    // 清理完成后全仓界面位置上只剩 book_mobi 那一条哨兵标题（见 _allowlist），
    // 用它当"扫描器没坏"的哨兵：真扫出 0 条反而要怀疑扫描逻辑。
    expect(
      hits.length,
      greaterThanOrEqualTo(1),
      reason: '至少应扫到 book_mobi 的哨兵标题；扫出 ${hits.length} ⇒ 扫描逻辑可疑',
    );
  });
}
