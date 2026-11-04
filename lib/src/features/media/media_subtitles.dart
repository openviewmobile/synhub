// 外挂字幕的**自研解析 + 同名匹配**（纯逻辑层）。
//
// 为什么自研而不是让 Media3 解析：
//   * 外挂字幕文件只在 NAS 上，Media3 要 side-load 就得把 URL 喂给它 —— 那
//     我们既拿不到"解析结果"（无法做选择/回读），也没法只取头部；
//   * 需求明确要 ASS "尽力"（先抽 `Dialogue` 文本、样式忽略），而 Media3 的
//     SSA 支持随版本漂移；
//   * 解析是纯字符串处理，放在这里能被 `dart run tool/*.dart` 直接跑、被离线
//     单测逐条钉死（SRT / VTT / ASS / 坏格式）。
//
// 这一层**不许** import flutter / package:flutter / l10n。
//
// 覆盖范围与**明确不支持**的部分见文件末尾注释。
library;

// 文件名工具（扩展名 / 去扩展名）与播放列表共用同一份实现，避免两套规则漂移。
import 'media_playlist.dart' show fileNameExtension, fileNameStem;

/// 字幕格式（由扩展名判定）
enum SubtitleFormat {
  srt('srt'),
  vtt('vtt'),
  ssa('ssa'),
  ass('ass');

  const SubtitleFormat(this.code);
  final String code;

  /// 界面上显示的格式标签（纯 ASCII，不是 l10n 文案）
  String get tag => code.toUpperCase();
}

/// 扩展名 → 字幕格式（不是字幕 → null）
SubtitleFormat? subtitleFormatOf(String fileName) {
  switch (fileNameExtension(fileName)) {
    case 'srt':
      return SubtitleFormat.srt;
    case 'vtt':
    case 'webvtt':
      return SubtitleFormat.vtt;
    case 'ssa':
      return SubtitleFormat.ssa;
    case 'ass':
      return SubtitleFormat.ass;
    default:
      return null;
  }
}

/// 是字幕文件？（`media_playlist` 的"同目录候选"用这个筛）
bool isSubtitleFileName(String name) => subtitleFormatOf(name) != null;

/// 一条字幕：时间段 + 文本（可能多行）
class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;

  @override
  String toString() =>
      'SubtitleCue($start→$end, ${text.replaceAll('\n', '⏎')})';
}

/// 解析好的一条字幕轨（外挂字幕）
class SubtitleTrack {
  const SubtitleTrack({
    required this.fileName,
    required this.format,
    required this.cues,
  });

  final String fileName;
  final SubtitleFormat format;
  final List<SubtitleCue> cues;

  bool get isEmpty => cues.isEmpty;

  /// 某个时刻该显示的字幕文本（没有 → null）
  String? textAt(Duration position) => cueAt(cues, position)?.text;

  @override
  String toString() =>
      'SubtitleTrack($fileName, ${format.code}, ${cues.length})';
}

/// 自研字幕解析器。
abstract final class SubtitleParser {
  /// 按格式分派；**任何**异常/坏格式都退回"能解多少算多少"，绝不抛
  static List<SubtitleCue> parse(String content, SubtitleFormat format) {
    try {
      return switch (format) {
        SubtitleFormat.srt => parseSrt(content),
        SubtitleFormat.vtt => parseVtt(content),
        SubtitleFormat.ssa || SubtitleFormat.ass => parseAss(content),
      };
    } catch (_) {
      return const [];
    }
  }

  /// SRT：`序号? / 时间行 / 文本行… / 空行` 分块
  ///
  /// 容错点（真机上的 `.srt` 什么都有）：
  ///   * CRLF / BOM / 中文编码残渣；
  ///   * 序号缺失、序号后面跟了额外文本；
  ///   * 毫秒分隔符是 `,` 或 `.`；
  ///   * 时间行后面还有 `X1:… Y1:…` 之类的坐标参数。
  static List<SubtitleCue> parseSrt(String content) {
    final lines = _lines(content);
    final out = <SubtitleCue>[];
    var i = 0;
    while (i < lines.length) {
      final timing = parseTimingLine(lines[i]);
      if (timing == null) {
        i++;
        continue;
      }
      final text = <String>[];
      i++;
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        text.add(lines[i]);
        i++;
      }
      final body = cleanCueText(text.join('\n'));
      if (body.isNotEmpty) {
        out.add(SubtitleCue(start: timing.start, end: timing.end, text: body));
      }
    }
    return out;
  }

  /// WebVTT：`WEBVTT` 头可省；跳过 `NOTE` / `STYLE` / `REGION` 块；
  /// 时间戳支持 `HH:MM:SS.mmm` 与 `MM:SS.mmm`；时间行后面可跟 `align:` 等设置。
  static List<SubtitleCue> parseVtt(String content) {
    final lines = _lines(content);
    final out = <SubtitleCue>[];
    var i = 0;
    while (i < lines.length) {
      final head = lines[i].trim();
      if (head.startsWith('NOTE') ||
          head.startsWith('STYLE') ||
          head.startsWith('REGION')) {
        // 跳掉整块（到空行为止）
        i++;
        while (i < lines.length && lines[i].trim().isNotEmpty) {
          i++;
        }
        continue;
      }
      final timing = parseTimingLine(lines[i]);
      if (timing == null) {
        i++;
        continue;
      }
      final text = <String>[];
      i++;
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        text.add(lines[i]);
        i++;
      }
      final body = cleanCueText(text.join('\n'));
      if (body.isNotEmpty) {
        out.add(SubtitleCue(start: timing.start, end: timing.end, text: body));
      }
    }
    return out;
  }

  /// ASS / SSA：只看 `[Events]` 段
  ///
  ///   * `Format:` 行决定字段顺序（不同压制组的顺序不一样，不能写死）；
  ///   * `Dialogue:` 行按 `,` 分段，但**最后一段（Text）里允许有逗号** ——
  ///     所以只切前 `n-1` 个逗号；
  ///   * `\N` → 换行、`\n` → 换行、`\h` → 空格；`{...}` 覆盖标签丢掉。
  ///
  /// **样式（字体/位置/特效/karaoke）全部忽略** —— 这是"尽力"的边界。
  static List<SubtitleCue> parseAss(String content) {
    final lines = _lines(content);
    var inEvents = false;
    var fields = <String>[];
    final out = <SubtitleCue>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('[')) {
        inEvents = line.toLowerCase() == '[events]';
        fields = <String>[];
        continue;
      }
      if (!inEvents) continue;
      final lower = line.toLowerCase();
      if (lower.startsWith('format:')) {
        fields = line
            .substring('format:'.length)
            .split(',')
            .map((f) => f.trim().toLowerCase())
            .toList();
        continue;
      }
      if (!lower.startsWith('dialogue:')) continue;
      final body = line.substring('dialogue:'.length);
      final startField = fields.indexOf('start');
      final endField = fields.indexOf('end');
      final textField = fields.indexOf('text');
      // 没写 `Format:` 的头（少数手写 ass）→ 按 SSA 默认顺序兜底
      final effStart = startField >= 0 ? startField : 1;
      final effEnd = endField >= 0 ? endField : 2;
      final effText = textField >= 0 ? textField : 9;
      final parts = _splitLimited(body, effText + 1);
      if (parts.length <= effText) continue;
      final start = parseTimestamp(parts[effStart]);
      final end = parseTimestamp(parts[effEnd]);
      if (start == null || end == null) continue;
      final text = cleanCueText(parts.sublist(effText).join(','));
      if (text.isEmpty) continue;
      out.add(SubtitleCue(start: start, end: end, text: text));
    }
    return out;
  }
}

/// 时间行解析结果
class SubtitleTiming {
  const SubtitleTiming(this.start, this.end);
  final Duration start;
  final Duration end;
}

/// `00:00:01,000 --> 00:00:04,000`（也吃 `.` 毫秒、`X1:` 之类的附加参数）
SubtitleTiming? parseTimingLine(String line) {
  final arrow = line.indexOf('-->');
  if (arrow < 0) return null;
  final left = line.substring(0, arrow).trim();
  // 右边可能跟 `align:middle line:90%` 等设置 → 只取第一段
  final rightRaw = line.substring(arrow + 3).trim();
  final right = rightRaw.split(RegExp(r'\s+')).first;
  final start = parseTimestamp(left);
  final end = parseTimestamp(right);
  if (start == null || end == null) return null;
  return SubtitleTiming(start, end);
}

/// `HH:MM:SS,mmm` / `HH:MM:SS.mmm` / `MM:SS.mmm` / `SS.mmm` → Duration
Duration? parseTimestamp(String raw) {
  final text = raw.trim().replaceAll(',', '.');
  if (text.isEmpty) return null;
  final parts = text.split(':');
  if (parts.length > 3) return null;
  var total = Duration.zero;
  final unit = <Duration>[
    const Duration(hours: 1),
    const Duration(minutes: 1),
    const Duration(seconds: 1),
  ];
  // parts 从"最粗"到"最细"，对齐到 unit 的尾部
  final offset = unit.length - parts.length;
  for (var i = 0; i < parts.length; i++) {
    final value = double.tryParse(parts[i]);
    if (value == null || value.isNaN) return null;
    final scale = unit[offset + i];
    total += scale * value;
  }
  return total;
}

/// 到 `position` 为止"该显示"的那条（用结束时间宽松匹配：字幕延迟普遍存在）
///
/// 二分查找：`cues` 按 start 升序（解析器保证）。
SubtitleCue? cueAt(List<SubtitleCue> cues, Duration position) {
  if (cues.isEmpty) return null;
  var lo = 0;
  var hi = cues.length - 1;
  var found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (cues[mid].start <= position) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (found < 0) return null;
  // 允许"上一条还没结束"（end >= start 就是有效区间）；文本重叠时取最后一条
  if (position <= cues[found].end) return cues[found];
  return null;
}

/// 同一个目录里的字幕候选，按匹配度**从高到低**排（`rankSubtitleFiles` 的结果）
class SubtitleMatch {
  const SubtitleMatch({
    required this.name,
    required this.format,
    required this.score,
    this.language = '',
  });

  final String name;
  final SubtitleFormat format;

  /// 越大越优先（规则见 [rankSubtitleFiles]）
  final int score;

  /// 从文件名后缀里认出来的语言码（`movie.zh.srt` → `zh`；没有 → 空串）
  final String language;

  @override
  String toString() => 'SubtitleMatch($name, ${format.code}, $score)';
}

/// 认得出"这是个语言后缀"的标签（决定 `movie.zh.srt` 归到哪一档）
const Set<String> kSubtitleLanguageTags = {
  'zh',
  'zho',
  'chi',
  'chs',
  'cht',
  'hans',
  'hant',
  'cn',
  'sc',
  'tc',
  'en',
  'eng',
  'ja',
  'jpn',
  'jp',
  'ko',
  'kor',
  'kr',
  'fr',
  'fra',
  'fre',
  'de',
  'deu',
  'ger',
  'es',
  'spa',
  'ru',
  'rus',
  'pt',
  'por',
  'it',
  'ita',
  'ar',
  'ara',
  'th',
  'tha',
  'vi',
  'vie',
  'zh-cn',
  'zh-tw',
  'zh-hans',
  'zh-hant',
  'pt-br',
};

/// 同一目录下的字幕候选 → 匹配度排序。
///
/// 打分规则（**三档主序 + 两档微调**）：
///   1. 基名完全相同（`movie.srt` 对 `movie.mp4`）→ 100；
///   2. 基名 = `视频基名 + "." + 语言标签`（`movie.zh.srt` / `movie.chs.srt`）
///      → 80；
///   3. 基名以 `视频基名 + "."` 开头但后缀不是语言标签（`movie.2024.srt`）
///      → 40；
///   4. 其它（`other.srt`）→ 0（仍然列出来，用户可以手选）。
///
/// 微调：
///   * 格式：`srt` / `vtt` 各 +3（我们能完整解析），`ass` / `ssa` 各 +1
///     （样式忽略，只出文本）；
///   * 语言：中文系标签 +3，英文 +1。
///
/// 同分按文件名自然序，保证顺序稳定。
List<SubtitleMatch> rankSubtitleFiles({
  required String videoFileName,
  required Iterable<String> fileNames,
}) {
  final stem = fileNameStem(videoFileName);
  final out = <SubtitleMatch>[];
  for (final name in fileNames) {
    final format = subtitleFormatOf(name);
    if (format == null) continue;
    final subStem = fileNameStem(name);
    var score = 0;
    var language = '';
    if (subStem == stem) {
      score = 100;
    } else if (subStem.startsWith('$stem.')) {
      final suffix = subStem.substring(stem.length + 1).toLowerCase();
      if (kSubtitleLanguageTags.contains(suffix)) {
        score = 80;
        language = suffix;
      } else {
        score = 40;
      }
    } else {
      // 视频名带附加信息而字幕只用了前半段（`movie.zh.srt` 对
      // `movie.2020.1080p.mp4`）：字幕基名是视频基名的前缀 → 也算同名前缀
      if (subStem.isNotEmpty && stem.startsWith('$subStem.')) {
        score = 30;
      }
    }
    score += switch (format) {
      SubtitleFormat.srt || SubtitleFormat.vtt => 3,
      SubtitleFormat.ass || SubtitleFormat.ssa => 1,
    };
    if (language.isNotEmpty && _isChineseTag(language)) {
      score += 3;
    } else if (language == 'en' || language == 'eng') {
      score += 1;
    }
    out.add(
      SubtitleMatch(
        name: name,
        format: format,
        score: score,
        language: language,
      ),
    );
  }
  out.sort((a, b) {
    if (a.score != b.score) return b.score - a.score;
    return _naturalName(a.name, b.name);
  });
  return out;
}

bool _isChineseTag(String tag) => const {
  'zh',
  'zho',
  'chi',
  'chs',
  'cht',
  'hans',
  'hant',
  'cn',
  'sc',
  'tc',
  'zh-cn',
  'zh-tw',
  'zh-hans',
  'zh-hant',
}.contains(tag);

int _naturalName(String a, String b) {
  // 只有"同分"时才用到；这里刻意保持简单：数字段按数值，其余按小写字典序
  final la = a.toLowerCase();
  final lb = b.toLowerCase();
  return la.compareTo(lb);
}

// ---------------------------------------------------------------- 内部工具

List<String> _lines(String content) => content
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceFirst('\uFEFF', '')
    .split('\n');

/// 只按前 `limit - 1` 个逗号切分（最后一段原样保留，ASS 的 Text 里允许逗号）
List<String> _splitLimited(String input, int limit) {
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < input.length && out.length < limit - 1; i++) {
    if (input.codeUnitAt(i) == 0x2C) {
      out.add(input.substring(start, i));
      start = i + 1;
    }
  }
  out.add(input.substring(start));
  return out;
}

/// 清掉标签/转义，得到"能直接画在屏幕上"的纯文本
String cleanCueText(String raw) {
  var text = raw;
  // ASS 覆盖标签 `{\i1}` / `{\pos(..)}`
  text = text.replaceAll(RegExp(r'\{[^}]*\}'), '');
  // HTML/VTT 行内标签 `<i>` `<c.color>` `<00:01:00.000>`
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  // ASS 换行
  text = text
      .replaceAll('\\N', '\n')
      .replaceAll('\\n', '\n')
      .replaceAll('\\h', ' ');
  final lines = text
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+$'), ''))
      .toList();
  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}
