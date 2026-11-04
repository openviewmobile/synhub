// 离线探针：证明播放列表 / 字幕解析 / 轨道模型这一层是**纯 Dart**（不 import
// flutter、不 import l10n），能被 `dart run tool/media_player_probe.dart` 直接跑。
//
//   dart run tool/media_player_probe.dart
//
// 不连 NAS、不起 Flutter 引擎：全部用自造 fixture。跑通即说明"协议/解析"这部分
// 逻辑可以在命令行里定位问题（与本项目 `tool/*.dart` 的老习惯一致）。
import '../lib/src/features/media/media_library_loader.dart';
import '../lib/src/features/media/media_playlist.dart';
import '../lib/src/features/media/media_source.dart';
import '../lib/src/features/media/media_subtitles.dart';
import '../lib/src/features/media/media_tracks.dart';
import '../lib/src/data/dto/file_entry_dto.dart';

int _checks = 0;

void check(bool ok, String what) {
  _checks++;
  if (!ok) {
    throw StateError('探针失败：$what');
  }
  print('  ✓ $what');
}

FileEntryDto entry(String name, {bool isDir = false}) => FileEntryDto(
  name: name,
  path: '/volume1/video/$name',
  isDir: isDir,
  size: 2048,
  mtime: 1758100000,
);

void main() {
  print('== 播放列表（同目录 + 同类型 + 自然序）==');
  final playlist = buildMediaPlaylist(
    kind: MediaKind.video,
    entries: [
      entry('ep10.mkv'),
      entry('ep2.mkv'),
      entry('ep1.mkv'),
      entry('cover.jpg'),
      entry('subs', isDir: true),
      entry('song.flac'),
    ],
  );
  check(
    playlist.map((e) => e.name).join(',') == 'ep1.mkv,ep2.mkv,ep10.mkv',
    '自然序 + 只留视频 + 丢掉目录项',
  );
  check(playlistIndexFor(playlist, '/volume1/video/ep2.mkv') == 1, '当前文件下标');
  check(hasPreviousIn(playlist, 0) == false, '第一个禁用"上一个"');
  check(hasNextIn(playlist, 2) == false, '最后一个禁用"下一个"');
  check(clampPlaylistIndex(2, 1, 3) == 2, '下标夹取');

  print('== SRT 解析 ==');
  final srt = SubtitleParser.parseSrt(
    '1\r\n'
    '00:00:01,000 --> 00:00:04,000\r\n'
    '<i>你好</i>，世界\r\n'
    '\r\n'
    '2\r\n'
    '00:00:05.500 --> 00:00:06,000 X1:1 Y1:2\r\n'
    '第二句\\N换行\r\n',
  );
  check(srt.length == 2, 'SRT 两条 cue（CRLF + 点毫秒 + 坐标参数）');
  check(srt.first.text == '你好，世界', 'SRT 去标签');
  check(srt.last.text == '第二句\n换行', 'SRT 的 \\N 转真换行');
  check(cueAt(srt, const Duration(seconds: 2))?.text == '你好，世界', '按时间找 cue');

  print('== WebVTT 解析 ==');
  final vtt = SubtitleParser.parseVtt(
    'WEBVTT\n\nNOTE 注释\n说明\n\n'
    '00:01.000 --> 00:03.000 align:middle\n'
    '<c.yellow>VTT</c> 文本\n',
  );
  check(vtt.length == 1, 'VTT 跳过 NOTE、认 MM:SS.mmm');
  check(vtt.single.text == 'VTT 文本', 'VTT 去行内标签');

  print('== ASS 解析（样式忽略，只抽 Dialogue 文本）==');
  final ass = SubtitleParser.parseAss(
    '[Script Info]\nTitle: probe\n\n[Events]\n'
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
    'Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,{\\i1}你好{\\i0}, 世界\\N第二行\n',
  );
  check(ass.length == 1, 'ASS 一条 cue');
  check(ass.single.text == '你好, 世界\n第二行', 'ASS 保留 Text 内逗号 + \\N + 去覆盖标签');

  print('== 坏格式不抛 ==');
  check(
    SubtitleParser.parse('garbage', SubtitleFormat.srt).isEmpty,
    'SRT 坏格式 → 空',
  );
  check(SubtitleParser.parseVtt('WEBVTT\n\nnope').isEmpty, 'VTT 坏格式 → 空');
  check(
    SubtitleParser.parseAss('[Events]\nDialogue: broken').isEmpty,
    'ASS 坏格式 → 空',
  );

  print('== 同名匹配优先级 ==');
  final ranked = rankSubtitleFiles(
    videoFileName: 'movie.mp4',
    fileNames: ['movie.zh.srt', 'movie.srt', 'movie.ass', 'other.srt'],
  );
  check(ranked.first.name == 'movie.srt', '完全同名排第一');
  check(ranked[1].name == 'movie.ass', '次优：同名 ASS（样式忽略但同名）');
  check(ranked[2].name == 'movie.zh.srt', '再次：中文语言后缀');
  check(ranked.first.score >= kSubtitleAutoMatchMinScore, '够自动挂载线');
  check(
    rankSubtitleFiles(
          videoFileName: 'a.mp4',
          fileNames: ['other.srt'],
        ).first.score <
        kSubtitleAutoMatchMinScore,
    '无关字幕不够自动挂载线（只能手选）',
  );

  print('== 轨道 / 画面比例模型 ==');
  final track = MediaTrackInfo.fromMap(const {
    'id': 'audio:0:0',
    'kind': 'audio',
    'language': 'zho',
    'channels': 6,
    'default': true,
    'selected': true,
  });
  check(track.displayLabel == '中文', '语言码 → 可读名');
  check(track.detail == '6 ch', '声道进 detail');
  check(
    MediaAspectMode.fromCode('zoom') == MediaAspectMode.zoom,
    '画面比例 code 解析',
  );
  check(
    MediaAspectMode.fromCode('nope') == MediaAspectMode.fit,
    '未知画面比例 → fit',
  );

  print('\n全部 $_checks 项通过（纯 Dart，不需要 Flutter 引擎）。');
}
