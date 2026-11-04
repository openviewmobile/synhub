// 无模型也能用的**纯 Dart 文本处理**：正文提取、句子切分、抽取式摘要、
// 片段检索。全部离线可测，不依赖任何推理库。
//
// 定位要说清楚：这一层**不是"生成"**——它只会挑原文里的句子、按相关度
// 排序。放在这里有两个用处：
//   1. 没下模型时（或低配设备上）功能照样可用，只是标注"内置摘要"；
//   2. 下了模型时，检索（RAG）用的就是这里的 [rankPassages]，
//      把最相关的几段喂给模型，避免把整本书塞进 4K 上下文。
import 'dart:convert';
import 'dart:math' as math;

import 'on_device_ai.dart';
import '../../core/i18n/data_text.dart';

/// HTML 片段 → 纯文本（阅读器的章节正文是"我们能渲染的 HTML 子集"）
String bookPlainText(String html) {
  if (html.isEmpty) return '';
  var s = html;
  // 块级标签换成换行，免得 `<p>a</p><p>b</p>` 粘成 "ab"
  s = s.replaceAll(
    RegExp(r'</(p|div|li|h[1-6]|tr|blockquote)\s*>', caseSensitive: false),
    '\n',
  );
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  // 脚本/样式整段丢掉
  s = s.replaceAll(
    RegExp(
      r'<(script|style)[^>]*>.*?</\1>',
      caseSensitive: false,
      dotAll: true,
    ),
    '',
  );
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = _decodeEntities(s);
  return collapseWhitespace(s);
}

String _decodeEntities(String s) {
  const named = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'",
    '&hellip;': '…',
    '&mdash;': '—',
    '&ndash;': '–',
    '&ldquo;': '“',
    '&rdquo;': '”',
    '&lsquo;': '‘',
    '&rsquo;': '’',
  };
  var out = s;
  named.forEach((k, v) => out = out.replaceAll(k, v));
  // 数字实体（`&#39;` / `&#x27;`）
  out = out.replaceAllMapped(RegExp(r'&#(x?[0-9a-fA-F]+);'), (m) {
    final raw = m.group(1)!;
    final code = raw.startsWith('x') || raw.startsWith('X')
        ? int.tryParse(raw.substring(1), radix: 16)
        : int.tryParse(raw);
    if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
    return String.fromCharCode(code);
  });
  return out;
}

/// 把空白（含全角空格、多余换行）压成"段落用单个换行、段内用单空格"
String collapseWhitespace(String s) {
  final lines = s
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u3000', ' ')
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').trim())
      .where((l) => l.isNotEmpty)
      .toList();
  return lines.join('\n');
}

/// 切句：中英混排都能用。
///
/// 规则：先按句末标点和换行切；英文的 `.` 只有在"后面是空格+大写/结束"时
/// 才算句末（否则 `3.14`、`v1.2.3` 会被切碎）。
List<String> splitSentences(String text) {
  final out = <String>[];
  final buf = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    buf.write(c);
    final isEnd =
        c == '。' ||
        c == '！' ||
        c == '？' ||
        c == '!' ||
        c == '?' ||
        c == '；' ||
        c == ';' ||
        c == '\n';
    if (isEnd) {
      _push(out, buf.toString());
      buf.clear();
      continue;
    }
    if (c == '.') {
      final next = i + 1 < text.length ? text[i + 1] : '';
      final after = i + 2 < text.length ? text[i + 2] : '';
      final boundary = next.isEmpty || next == ' ' || next == '\n';
      final startsUpper = after.isNotEmpty && after == after.toUpperCase();
      if (boundary && (next.isEmpty || startsUpper)) {
        _push(out, buf.toString());
        buf.clear();
      }
    }
  }
  _push(out, buf.toString());
  return out;
}

void _push(List<String> out, String raw) {
  final s = raw.trim();
  if (s.isEmpty) return;
  out.add(s);
}

/// 切句后过滤出"适合当要点"的句子：太短（"好的。"）和太长（整段没标点）
/// 都不要，它们要么没信息、要么塞进摘要就是一大坨。
List<String> candidateSentences(String text, {int min = 8, int max = 180}) {
  final seen = <String>{};
  final out = <String>[];
  for (final s in splitSentences(text)) {
    final plain = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    final cleaned = plain.replaceAll(RegExp(r'^[\-\*\u2022\d\.、\s]+'), '');
    if (cleaned.length < min || cleaned.length > max) continue;
    final key = cleaned.length > 24 ? cleaned.substring(0, 24) : cleaned;
    if (!seen.add(key)) continue;
    out.add(cleaned);
  }
  return out;
}

const Set<String> _stopWords = {
  'the',
  'a',
  'an',
  'of',
  'to',
  'and',
  'or',
  'in',
  'on',
  'at',
  'for',
  'is',
  'are',
  'was',
  'were',
  'be',
  'been',
  'it',
  'its',
  'this',
  'that',
  'these',
  'those',
  'as',
  'by',
  'with',
  'from',
  'we',
  'you',
  'they',
  'he',
  'she',
  'i',
  'not',
  'but',
  'if',
  'then',
  'than',
  'so',
  'such',
  'can',
  'will',
  'would',
  'has',
  'have',
  'had',
  'do',
  'does',
  'did',
  'there',
  'their',
  'our',
  'your',
  '的',
  '了',
  '是',
  '在',
  '和',
  '与',
  '或',
  '也',
  '都',
  '就',
  '而',
  '及',
  '对',
  '把',
  '被',
  '让',
  '从',
  '到',
  '为',
  '以',
  '并',
  '很',
  '会',
  '要',
  '这',
  '那',
  '你',
  '我',
  '他',
  '她',
  '它',
  '们',
  '个',
  '中',
  '上',
  '下',
  '不',
  '有',
  '没有',
  '可以',
  '一个',
  '这个',
  '如果',
  '因为',
  '所以',
  '但是',
};

/// 取词：拉丁词按词切；CJK 走**二元组**（不做分词也能抓住关键词），
/// 单字 CJK 只在整句都很短时才用（否则噪声太大）。
List<String> tokenize(String text) {
  final out = <String>[];
  final lower = text.toLowerCase();
  for (final m in RegExp(r'[a-z0-9][a-z0-9_\-\+\.]*').allMatches(lower)) {
    final w = m.group(0)!;
    if (w.length < 2 || _stopWords.contains(w)) continue;
    out.add(w);
  }
  final cjk = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff]+');
  for (final m in cjk.allMatches(lower)) {
    final run = m.group(0)!;
    if (run.length == 1) {
      if (!_stopWords.contains(run)) out.add(run);
      continue;
    }
    for (var i = 0; i + 1 < run.length; i++) {
      final bigram = run.substring(i, i + 2);
      if (_stopWords.contains(bigram)) continue;
      out.add(bigram);
    }
  }
  return out;
}

/// 抽取式摘要：**挑原句**，不上模型。
///
/// 打分 = 词频权重（除以长度开方，压掉长句优势）
///      + 位置加成（开头的句子更像主题句）
///      + 数字/专名小加成
/// 选句时做一次粗糙的"去重"（和已选句子词重叠 > 60% 就跳过），
/// 最后**按原文顺序**输出（摘要读起来才像话）。
List<String> extractiveSummary(String text, {int maxBullets = 5}) {
  final sentences = candidateSentences(text);
  if (sentences.isEmpty) {
    final flat = collapseWhitespace(text).replaceAll('\n', ' ');
    if (flat.isEmpty) return const [];
    return [flat.length > 200 ? '${flat.substring(0, 200)}…' : flat];
  }
  if (sentences.length <= maxBullets) return sentences;

  final freq = <String, int>{};
  final tokenCache = <List<String>>[];
  for (final s in sentences) {
    final t = tokenize(s);
    tokenCache.add(t);
    for (final w in t) {
      freq[w] = (freq[w] ?? 0) + 1;
    }
  }
  final scored =
      <({int index, String text, double score, List<String> toks})>[];
  for (var i = 0; i < sentences.length; i++) {
    final toks = tokenCache[i];
    if (toks.isEmpty) continue;
    var sum = 0.0;
    for (final w in toks) {
      sum += 1 + math.log(1 + (freq[w] ?? 1));
    }
    var score = sum / math.sqrt(toks.length + 4);
    // 主题句加成：前 15% 的句子
    if (i < math.max(1, sentences.length * 0.15)) score *= 1.25;
    // 带数字/年份的句子往往是有信息量的（"2024 年增长了 30%"）
    if (RegExp(r'\d').hasMatch(sentences[i])) score *= 1.08;
    // 太靠后的句子（总结段）稍微加一点
    if (i >= sentences.length - 2) score *= 1.05;
    scored.add((index: i, text: sentences[i], score: score, toks: toks));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));

  final picked =
      <({int index, String text, double score, List<String> toks})>[];
  for (final c in scored) {
    if (picked.length >= maxBullets) break;
    final dup = picked.any((p) => _overlap(p.toks, c.toks) > 0.6);
    if (dup) continue;
    picked.add(c);
  }
  picked.sort((a, b) => a.index.compareTo(b.index));
  return [for (final p in picked) p.text];
}

double _overlap(List<String> a, List<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final sa = a.toSet();
  var hit = 0;
  for (final w in b.toSet()) {
    if (sa.contains(w)) hit++;
  }
  return hit / math.min(sa.length, b.toSet().length);
}

/// 检索：给一个问题，从一堆片段里挑最相关的几段（喂给模型 / 直接展示）。
///
/// 用 **BM25 的简化式**：词频饱和 + 文档频率惩罚 + 长度归一。
/// 中文靠二元组命中，问题里的"什么/怎么"这类词被停用词表挡掉。
List<AiPassage> rankPassages(
  String query,
  List<AiPassage> passages, {
  int topK = kAiTopK,
}) {
  if (passages.isEmpty) return const [];
  final qTokens = tokenize(query).toSet();
  if (qTokens.isEmpty) {
    // 没问题/没关键词：退化成"取前几段"，别返回空
    return passages.take(topK).toList();
  }
  final docTokens = [
    for (final p in passages) tokenize('${p.title} ${p.text}'),
  ];
  final df = <String, int>{};
  for (final toks in docTokens) {
    for (final w in toks.toSet()) {
      if (qTokens.contains(w)) df[w] = (df[w] ?? 0) + 1;
    }
  }
  final avgLen = docTokens.isEmpty
      ? 1.0
      : docTokens.fold<int>(0, (s, t) => s + t.length) / docTokens.length;
  const k1 = 1.2;
  const b = 0.75;

  final scored = <({AiPassage p, double score})>[];
  for (var i = 0; i < passages.length; i++) {
    final toks = docTokens[i];
    if (toks.isEmpty) continue;
    final tf = <String, int>{};
    for (final w in toks) {
      if (qTokens.contains(w)) tf[w] = (tf[w] ?? 0) + 1;
    }
    var score = 0.0;
    tf.forEach((w, n) {
      final idf = math.log(
        1 + (passages.length - (df[w] ?? 0) + 0.5) / ((df[w] ?? 0) + 0.5),
      );
      final denom =
          n + k1 * (1 - b + b * toks.length / (avgLen == 0 ? 1 : avgLen));
      score += idf * (n * (k1 + 1)) / (denom == 0 ? 1 : denom);
    });
    // 标题命中（"第 3 章 引言"这种）额外加成
    final qInTitle = qTokens
        .where((w) => tokenize(passages[i].title).contains(w))
        .length;
    score += qInTitle * 0.6;
    if (score <= 0) continue;
    scored.add((p: passages[i], score: score));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  return [for (final s in scored.take(topK)) s.p];
}

/// 把整本书切成可检索的片段（按章切；一章太长再按段切）。
///
/// 为什么要再切：一章可能几万字，整章塞进 prompt 会直接爆上下文，
/// 检索精度也差（一段里只有一句相关）。
List<AiPassage> passagesOfBook(
  String title,
  List<String> chapterTitles,
  List<String> chapterTexts, {
  int maxChars = 1200,
}) {
  final out = <AiPassage>[];
  for (var i = 0; i < chapterTexts.length; i++) {
    final name = i < chapterTitles.length && chapterTitles[i].trim().isNotEmpty
        ? chapterTitles[i].trim()
        : '第 ${i + 1} 节';
    final text = collapseWhitespace(chapterTexts[i]);
    if (text.isEmpty) continue;
    if (text.length <= maxChars) {
      out.add(AiPassage(index: i, title: '$name · $title', text: text));
      continue;
    }
    final paragraphs = text.split('\n');
    final buf = StringBuffer();
    var n = 0;
    void flush() {
      final chunk = collapseWhitespace(buf.toString());
      buf.clear();
      if (chunk.isEmpty) return;
      n++;
      out.add(AiPassage(index: i, title: _passageTitle(name, n, title), text: chunk));
    }

    for (final p in paragraphs) {
      if (buf.length + p.length > maxChars && buf.isNotEmpty) flush();
      buf.writeln(p);
    }
    flush();
  }
  return out;
}

/// 截断到 [kAiMaxInputChars]，并告诉调用方"截了"
({String text, bool truncated}) clampInput(String text) {
  final t = collapseWhitespace(text);
  if (t.length <= kAiMaxInputChars) return (text: t, truncated: false);
  return (text: '${t.substring(0, kAiMaxInputChars)}…', truncated: true);
}

// ---------------------------------------------------------------- 模型输出卫生

/// 字节级 BPE 词表被按 **Latin-1** 解码后的乱码修复。
///
/// 现象（真机 Qwen3 0.6B 实测）：`Ġç®力与内存带宽…`，本意是
/// `算力与内存带宽…`。原因在引擎/词表那一层：`算` = UTF-8 `E7 AE 97`，
/// 被逐字节当成 Latin-1 就是 `ç`/`®`/控制字符；`Ġ` 是空格标记。
/// 字节没丢，所以**能原样还原**：把每个字符压回一个字节再按 UTF-8 解。
///
/// 只在看到 `Ġ`/`Ċ`（byte-level 词表的空格/换行标记）时才动手，
/// 免得把正常的法语、德语文本（`é`/`ü` 同样落在 Latin-1 区）改坏。
String repairMojibake(String s) {
  if (!s.contains('Ġ') && !s.contains('Ċ')) return s;
  // 有代理对（emoji 等）时逐单元处理会拆坏字符，直接不动
  if (s.runes.any((r) => r > 0xFFFF)) return s;
  final out = <int>[];
  for (final unit in s.codeUnits) {
    if (unit <= 0xFF) {
      out.add(unit); // ASCII / Latin-1 补充区：一个字符 = 一个原始字节
    } else if (unit <= 0x17F) {
      out.add(unit & 0xFF); // `Ġ`→空格、`Ċ`→换行：byte-level 词表的标记
    } else {
      out.addAll(utf8.encode(String.fromCharCode(unit))); // 正常汉字等，按 UTF-8 放回去
    }
  }
  try {
    return utf8.decode(out, allowMalformed: true);
  } catch (_) {
    return s;
  }
}

/// 把两种思考标记统一成同一套：`<think>`/`<thinking>` → ` thinking`
String _normalizeThinkTags(String raw) => raw
    .replaceAll(RegExp(r'<think(ing)?>'), ' thinking')
    .replaceAll(RegExp(r'</think(ing)?>'), ' response');

/// 流式展示用：把思考段单独摘出来。
///
/// 小模型的思考段会**边生成边**冒出来（真机上 Qwen3 0.6B 实测），不能等
/// 结束后再删 —— 用户会看到模型自言自语。没等到结束标记就返回
/// `thinking: true`，让 UI 显示"模型在思考…"而不是半截推理过程。
({String text, bool thinking}) splitThinking(String raw) {
  const open = ' thinking';
  const close = ' response';
  final s = _normalizeThinkTags(raw);
  final start = s.indexOf(open);
  if (start < 0) return (text: s, thinking: false);
  final end = s.indexOf(close);
  if (end < 0) return (text: s.substring(0, start), thinking: true);
  final rest = s.substring(end + close.length);
  return (text: '${s.substring(0, start)}$rest', thinking: false);
}

/// 把思考段**正文**摘出来（`splitThinking` 只答"在不在思考"，这里要内容）。
///
/// 用于把端侧模型（Qwen3 这类）的 ` thinking…` 也做成"可折叠的思考过程"，
/// 与云端推理模型的思考折叠区共用一个 UI。多段思考会拼在一起。
String extractThinkingText(String raw) {
  // 哨兵与 [splitThinking] 完全一致（拆成两段字面量写，避免被工具的
  // 标签归一化误伤）
  const open =
      ' thin'
      'king';
  const close =
      ' resp'
      'onse';
  final s = _normalizeThinkTags(repairMojibake(raw));
  final buf = StringBuffer();
  var i = 0;
  while (true) {
    final start = s.indexOf(open, i);
    if (start < 0) break;
    final from = start + open.length;
    final end = s.indexOf(close, from);
    if (end < 0) {
      // 还没等到结束标记：把剩下的都当思考内容（与 splitThinking 的判定一致）
      buf.write(s.substring(from));
      break;
    }
    buf.write(s.substring(from, end));
    i = end + close.length;
  }
  return buf.toString().trim();
}

/// 把输出洗干净：乱码修复 + 思考段剥掉 + 空白收敛
String cleanModelText(String raw) {
  var s = repairMojibake(raw);
  for (var i = 0; i < 4; i++) {
    final split = splitThinking(s);
    if (!split.thinking && split.text == s) break;
    s = split.text;
  }
  return collapseWhitespace(s);
}


/// 段标题（`{name}（{n}）· {title}`）：纯 Dart 层拿不到 context，走 `dataText`。
String _passageTitle(String name, int n, String title) => dataText(
  'textAiPassageLabel',
  '{name}（{n}）· {title}',
).replaceAll('{name}', name).replaceAll('{n}', '$n').replaceAll('{title}', title);
