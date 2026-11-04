// 外挂字幕的**自研解析 + 同名匹配**（`media_subtitles.dart`）的离线测试。
//
// 三个格式各一份自造 fixture（SRT / VTT / ASS）+ 坏格式；再加同名匹配的
// 优先级与"某一时刻该显示哪条"。
//
// 这一层是**纯逻辑**（不 import flutter/l10n），所以 `dart run tool/*.dart`
// 也能直接跑同一份实现（见 `tool/media_player_probe.dart`）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/media_subtitles.dart';

/// 带 CRLF、缺序号、逗号/点混用毫秒、坐标参数、HTML 标签、ASS 换行的 SRT
const _srtFixture =
    '1\r\n'
    '00:00:01,000 --> 00:00:04,000\r\n'
    'Hello <i>world</i>\r\n'
    '\r\n'
    '2\r\n'
    '00:00:05.500 --> 00:00:06,000 X1:100 Y1:200\r\n'
    '{\\an8}Second line\\Nwith break\r\n'
    '\r\n'
    '3\r\n'
    '00:00:07,000 --> 00:00:08,000\r\n'
    '\r\n';

const _vttFixture =
    'WEBVTT\n'
    '\n'
    'NOTE this is a comment\n'
    'still the comment\n'
    '\n'
    'STYLE\n'
    '::cue { color: red }\n'
    '\n'
    '1\n'
    '00:00:01.000 --> 00:00:04.000 align:middle\n'
    'Hello <c.yellow>VTT</c>\n'
    '\n'
    'intro\n'
    '00:05.000 --> 00:07.000\n'
    'Second\n';

const _assFixture =
    '[Script Info]\n'
    'Title: fixture\n'
    '\n'
    '[Events]\n'
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
    'Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,{\\i1}Hello{\\i0}, world\\Nsecond\n'
    'Comment: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,ignored\n'
    '\n'
    '[Fonts]\n'
    'Dialogue: 0,0:00:09.00,0:00:10.00,Default,,0,0,0,,not in events\n';

void main() {
  group('格式判定', () {
    test('扩展名 → 格式；不是字幕 → null', () {
      expect(subtitleFormatOf('a.srt'), SubtitleFormat.srt);
      expect(subtitleFormatOf('a.SRT'), SubtitleFormat.srt);
      expect(subtitleFormatOf('a.vtt'), SubtitleFormat.vtt);
      expect(subtitleFormatOf('a.webvtt'), SubtitleFormat.vtt);
      expect(subtitleFormatOf('a.ass'), SubtitleFormat.ass);
      expect(subtitleFormatOf('a.ssa'), SubtitleFormat.ssa);
      expect(subtitleFormatOf('a.mp4'), isNull);
      expect(subtitleFormatOf('srt'), isNull);
      expect(isSubtitleFileName('movie.zh.ass'), isTrue);
      expect(isSubtitleFileName('movie.zh.txt'), isFalse);
    });

    test('格式标签用大写（界面显示用）', () {
      expect(SubtitleFormat.srt.tag, 'SRT');
      expect(SubtitleFormat.ass.tag, 'ASS');
    });
  });

  group('SRT 解析', () {
    test('CRLF / 缺序号 / 点毫秒 / 坐标参数 / 标签 / ASS 换行', () {
      final cues = SubtitleParser.parseSrt(_srtFixture);
      expect(cues, hasLength(2), reason: '第 3 块只有时间没有文本 → 丢掉');
      expect(cues[0].start, const Duration(seconds: 1));
      expect(cues[0].end, const Duration(seconds: 4));
      expect(cues[0].text, 'Hello world');
      expect(cues[1].start, const Duration(milliseconds: 5500));
      expect(cues[1].end, const Duration(seconds: 6));
      expect(cues[1].text, 'Second line\nwith break');
    });

    test('没有序号的块也能解', () {
      final cues = SubtitleParser.parseSrt(
        '00:00:00,500 --> 00:00:02,000\nNo index\n',
      );
      expect(cues, hasLength(1));
      expect(cues.single.text, 'No index');
    });

    test('坏格式 → 空列表（不抛）', () {
      expect(
        SubtitleParser.parseSrt('this is not a subtitle\nat all'),
        isEmpty,
      );
      expect(SubtitleParser.parseSrt(''), isEmpty);
      expect(
        SubtitleParser.parse('garbage', SubtitleFormat.srt),
        isEmpty,
        reason: '分派入口也只返回空表',
      );
    });
  });

  group('WebVTT 解析', () {
    test('WEBVTT 头 / NOTE / STYLE / 设置串 / MM:SS 时间戳 / 行内标签', () {
      final cues = SubtitleParser.parseVtt(_vttFixture);
      expect(cues, hasLength(2));
      expect(cues[0].start, const Duration(seconds: 1));
      expect(cues[0].end, const Duration(seconds: 4));
      expect(cues[0].text, 'Hello VTT');
      expect(cues[1].start, const Duration(seconds: 5));
      expect(cues[1].end, const Duration(seconds: 7));
      expect(cues[1].text, 'Second');
    });

    test('坏格式 → 空列表', () {
      expect(SubtitleParser.parseVtt('WEBVTT\n\nnonsense'), isEmpty);
    });
  });

  group('ASS / SSA 解析（样式忽略，只抽 Dialogue 文本）', () {
    test('按 Format 行取字段；Text 里的逗号保留；\\N 换行；覆盖标签丢掉', () {
      final cues = SubtitleParser.parseAss(_assFixture);
      expect(cues, hasLength(1), reason: 'Comment 行与 [Fonts] 段不算');
      expect(cues.single.start, const Duration(seconds: 1));
      expect(cues.single.end, const Duration(milliseconds: 3500));
      expect(cues.single.text, 'Hello, world\nsecond');
    });

    test('没有 Format 行时按 SSA 默认字段顺序兜底', () {
      final cues = SubtitleParser.parseAss(
        '[Events]\n'
        'Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,Default order\n',
      );
      expect(cues, hasLength(1));
      expect(cues.single.start, const Duration(seconds: 2));
      expect(cues.single.text, 'Default order');
    });

    test('坏格式 → 空列表', () {
      expect(SubtitleParser.parseAss('[Script Info]\nTitle: x'), isEmpty);
      expect(
        SubtitleParser.parseAss(
          '[Events]\n'
          'Dialogue: broken\n',
        ),
        isEmpty,
      );
    });

    test('.ssa 走同一条 ASS 解析路径', () {
      expect(
        SubtitleParser.parse(_assFixture, SubtitleFormat.ssa),
        hasLength(1),
      );
    });
  });

  group('时间戳', () {
    test('支持 HH:MM:SS,mmm / HH:MM:SS.mmm / MM:SS.mmm / SS.mmm', () {
      expect(
        parseTimestamp('00:00:01,500'),
        const Duration(milliseconds: 1500),
      );
      expect(
        parseTimestamp('00:00:01.500'),
        const Duration(milliseconds: 1500),
      );
      expect(
        parseTimestamp('01:02:03,000'),
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
      expect(parseTimestamp('05.250'), const Duration(milliseconds: 5250));
      expect(parseTimestamp('0:00:01.00'), const Duration(seconds: 1));
    });

    test('非法 → null', () {
      expect(parseTimestamp(''), isNull);
      expect(parseTimestamp('abc'), isNull);
      expect(parseTimestamp('1:2:3:4'), isNull);
      expect(parseTimestamp('1:xx'), isNull);
    });

    test('时间行：没有 --> 或时间戳非法 → null', () {
      expect(parseTimingLine('not a timing line'), isNull);
      expect(parseTimingLine('abc --> 00:00:01,000'), isNull);
      expect(
        parseTimingLine('00:00:01,000 --> 00:00:02,000 align:middle'),
        isNotNull,
      );
    });
  });

  group('当前该显示哪条', () {
    final cues = SubtitleParser.parseSrt(
      '1\n00:00:01,000 --> 00:00:04,000\nA\n\n'
      '2\n00:00:05,000 --> 00:00:06,000\nB\n',
    );

    test('区间内命中，区间外 / 之间 → null', () {
      expect(cueAt(cues, Duration.zero), isNull);
      expect(cueAt(cues, const Duration(seconds: 2))?.text, 'A');
      expect(cueAt(cues, const Duration(seconds: 4))?.text, 'A');
      expect(cueAt(cues, const Duration(milliseconds: 4500)), isNull);
      expect(cueAt(cues, const Duration(milliseconds: 5500))?.text, 'B');
      expect(cueAt(cues, const Duration(seconds: 30)), isNull);
      expect(cueAt(const [], Duration.zero), isNull);
    });

    test('SubtitleTrack.textAt 是同一套判定', () {
      final track = SubtitleTrack(
        fileName: 'movie.srt',
        format: SubtitleFormat.srt,
        cues: cues,
      );
      expect(track.isEmpty, isFalse);
      expect(track.textAt(const Duration(seconds: 2)), 'A');
      expect(track.textAt(Duration.zero), isNull);
    });
  });

  group('同名匹配优先级', () {
    test('完全同名 > 同语言后缀（中文优先）> 其它后缀 > 无关文件', () {
      final ranked = rankSubtitleFiles(
        videoFileName: 'movie.mp4',
        fileNames: [
          'other.srt',
          'movie.2024.srt',
          'movie.en.srt',
          'movie.zh.srt',
          'movie.ass',
          'movie.srt',
          'movie.mp4', // 不是字幕 → 不进候选
        ],
      );
      expect(ranked.map((m) => m.name).toList(), [
        'movie.srt',
        'movie.ass',
        'movie.zh.srt',
        'movie.en.srt',
        'movie.2024.srt',
        'other.srt',
      ]);
      expect(ranked.first.language, isEmpty);
      expect(ranked.first.format, SubtitleFormat.srt);
    });

    test('语言标签识别：zh-CN / chs / zho 都算中文，en/eng 算英文', () {
      final ranked = rankSubtitleFiles(
        videoFileName: 'movie.mkv',
        fileNames: ['movie.zh-CN.srt', 'movie.chs.ass', 'movie.eng.vtt'],
      );
      final languages = {for (final m in ranked) m.name: m.language};
      expect(languages['movie.zh-CN.srt'], 'zh-cn');
      expect(languages['movie.chs.ass'], 'chs');
      expect(languages['movie.eng.vtt'], 'eng');
      // 中文后缀拿语言加分 → 排在英文前面
      expect(ranked.first.name, 'movie.zh-CN.srt');
    });

    test('视频名带附加信息、字幕只用前半段（movie.zh.srt ← Movie.2020.1080p.mp4）', () {
      final ranked = rankSubtitleFiles(
        videoFileName: 'Movie.2020.1080p.mp4',
        fileNames: ['Movie.zh.srt', 'Movie.2020.1080p.srt'],
      );
      final byName = {for (final m in ranked) m.name: m.score};
      expect(
        byName['Movie.2020.1080p.srt']!,
        greaterThan(byName['Movie.zh.srt']!),
      );
      expect(ranked.first.name, 'Movie.2020.1080p.srt');
    });

    test('同分时按文件名自然序，顺序稳定', () {
      final ranked = rankSubtitleFiles(
        videoFileName: 'movie.mp4',
        fileNames: ['b.srt', 'a.srt'],
      );
      expect(ranked.map((m) => m.name).toList(), ['a.srt', 'b.srt']);
    });

    test('没有候选 → 空表（界面据此不显示"自动匹配"）', () {
      expect(
        rankSubtitleFiles(videoFileName: 'movie.mp4', fileNames: const []),
        isEmpty,
      );
    });
  });

  group('文本清洗', () {
    test('去标签 / 转义换行 / 去行尾空白 / 去首尾空行', () {
      expect(cleanCueText('<b>a</b>'), 'a');
      expect(cleanCueText('a\\Nb'), 'a\nb');
      expect(cleanCueText('a\\hb'), 'a b');
      expect(cleanCueText('{\\pos(1,2)}hello'), 'hello');
      // 只去行尾空白与首尾空行；行首缩进保留（`\h` 可能是有意的缩进）
      expect(cleanCueText('\n\n  x  \n\n'), '  x');
      expect(cleanCueText('a   \nb'), 'a\nb');
      expect(cleanCueText(''), '');
    });
  });
}
