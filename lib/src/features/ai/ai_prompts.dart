// Prompt 组装 + **严格输出解析**。
//
// 端侧小模型（0.6B 这一档）最大的坑不是"不会答"，而是"不听话"：
// 你说"输出 3 条要点"，它给你写一段散文；你让它别编，它照样编。
// 所以这里做两件事：
//   1. prompt 写得**极短、极具体**（小模型上下文小、指令多了反而乱）；
//   2. 输出**回来就解析**——要点的前缀（`-`/`1.`）剥掉、空行丢掉、
//      条数截到上限；解析失败就把它当一整段文本用（不丢内容）。
import 'on_device_ai.dart';
import 'text_ai.dart';

/// 系统提示：统一"只依据原文、不确定就说不确定"
String aiSystemPrompt(AiTaskKind kind) {
  const base =
      '你是一个装在手机本地的阅读助手。'
      '回答必须使用简体中文，只依据我给你的原文，不要编造原文里没有的信息；'
      '如果原文不足以回答，就直接说"原文里没有提到"。';
  return switch (kind) {
    AiTaskKind.summary => '$base 你要把原文概括成几条要点，每条不超过 40 字。',
    AiTaskKind.explain =>
      '$base 你要用大白话解释选中的这段话，先说它讲了什么，'
          '再补充必要背景，控制在 120 字内。',
    AiTaskKind.translate =>
      '$base 你要把选中的这段话翻译成目标语言，'
          '只输出译文，不要解释。',
    AiTaskKind.askBook =>
      '$base 你要根据我给的原文片段回答问题，'
          '答案要短，句末用 [1] [2] 这样的角标标出依据的片段序号。',
  };
}

/// 用户提示（把原文嵌进去；`askBook` 带检索片段）
String aiUserPrompt(AiRequest req, {String language = '中文'}) {
  final input = clampInput(req.text);
  final where = req.title.isEmpty ? '' : '《${req.title}》';
  switch (req.kind) {
    case AiTaskKind.summary:
      return '${where.isEmpty ? '' : '$where 的'}下面这段内容，'
          '请用 3-5 条要点概括（每行一条，用「- 」开头）：\n\n${input.text}';
    case AiTaskKind.explain:
      return '请解释下面这段话：\n\n${input.text}';
    case AiTaskKind.translate:
      return '请把下面这段话翻译成$language：\n\n${input.text}';
    case AiTaskKind.askBook:
      final ctx = req.contexts.isEmpty
          ? input.text
          : [
              for (var i = 0; i < req.contexts.length; i++)
                '[${i + 1}] ${req.contexts[i].title}\n${req.contexts[i].text}',
            ].join('\n\n');
      return '根据下面的原文片段回答问题。\n\n$ctx\n\n问题：${req.question}';
  }
}

/// 把模型输出解析成"要点列表"
///
/// 处理：`- `/`* `/`1. `/`1、`/`• ` 前缀、全角空格、空行；
/// 去掉模型爱加的"以下是要点："这种开场白；顺带剥掉 markdown 粗体。
List<String> parseBullets(String raw, {int max = 6}) {
  final out = <String>[];
  for (final line in raw.split('\n')) {
    var s = line.trim();
    if (s.isEmpty) continue;
    s = s.replaceAll(RegExp(r'^[#>\s]*'), '');
    s = s.replaceAll(RegExp(r'^([\-\*•·]|\d+[\.、\)])\s*'), '');
    s = s.replaceAll('**', '').replaceAll(RegExp(r'["\u201c\u201d]'), '');
    // 行首可能残留乱码：`\uFFFD`（字节被模型吃掉）以及 Latin-1 补充区/私有区
    // 的碎片（`cleanModelText` 修不回来的那一部分）。丢掉行首这些字符，
    // 从第一个"像字"的字符（汉字/字母/数字）开始，读起来就不刺眼了。
    s = s.replaceFirst(
      RegExp(r'^[^\p{L}\p{N}\u4e00-\u9fff]+', unicode: true),
      '',
    );
    // `\uFFFD9力…`：被吃掉的字节有时残留一位数字，正好贴在汉字前面
    // （`2024 年` 这种正常开头带空格，不会被误删）
    s = s.replaceFirst(RegExp(r'^[0-9]{1,2}(?=[\u4e00-\u9fff])'), '');
    s = s.trim();
    if (s.isEmpty) continue;
    // 开场白/收尾话术：不像要点的整句丢掉
    if (RegExp(r'^(以下|下面是|要点如下|总结如下|希望|如果需要|总之|综上)').hasMatch(s)) {
      continue;
    }
    // 1-2 个字的"废话要点"（"- 好"）才丢；3 个字的短要点是合法的
    if (s.length < 3) continue;
    out.add(s.length > 120 ? '${s.substring(0, 120)}…' : s);
    if (out.length >= max) break;
  }
  if (out.isEmpty) {
    // 模型没按格式来：整段当一条，别把内容丢了
    final flat = collapseWhitespace(raw).replaceAll('\n', ' ');
    if (flat.isNotEmpty) {
      out.add(flat.length > 200 ? '${flat.substring(0, 200)}…' : flat);
    }
  }
  return out;
}

/// 去掉 `askBook` 答案里的思考段（Qwen3 会吐 ` thinking...</think>`）
/// 和角标噪声，给 UI 一个干净的正文。
String stripModelNoise(String raw) {
  // `cleanModelText` = 乱码修复（Qwen 的 byte-level 词表在真机上的 Latin-1
  // 解码问题）+ 思考段剥离 + 空白收敛，全部在纯 Dart 层，可单测。
  return cleanModelText(raw);
}

/// 从答案里抽出用到的引用角标（`[1]`/`【2】`）→ 对应片段序号（0 基）
List<int> citedPassages(String answer, int available) {
  final hits = <int>{};
  for (final m in RegExp(r'[\[【](\d{1,2})[\]】]').allMatches(answer)) {
    final n = int.tryParse(m.group(1)!);
    if (n == null) continue;
    if (n >= 1 && n <= available) hits.add(n - 1);
  }
  final sorted = hits.toList()..sort();
  return sorted;
}
