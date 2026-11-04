// 「上一个 / 下一个」播放列表（`media_playlist.dart`）的离线测试。
//
// 这一层**纯逻辑**（不 import flutter/l10n），要钉死：
//   1. 文件名 → 媒体类型（视频/音频/其它）；
//   2. 自然序（`ep2 < ep10`，不能是字典序）；
//   3. 同目录 + 同类型过滤、去重、把当前文件补进列表；
//   4. **首尾边界**：第一个没有"上一个"、最后一个没有"下一个"（按钮禁用态同源）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/media/media_playlist.dart';
import 'package:synhub/src/features/media/media_source.dart';

FileEntryDto _e(String name, {String? path, bool isDir = false}) =>
    FileEntryDto(
      name: name,
      path: path ?? '/home/videos/$name',
      isDir: isDir,
      size: 1024,
      mtime: 1758100000,
    );

void main() {
  group('文件名工具', () {
    test('扩展名：小写化、隐藏文件/无扩展名 → 空串', () {
      expect(fileNameExtension('Clip.MP4'), 'mp4');
      expect(fileNameExtension('a.b.mkv'), 'mkv');
      expect(fileNameExtension('.gitignore'), '');
      expect(fileNameExtension('README'), '');
      expect(fileNameExtension('trailing.'), '');
    });

    test('去扩展名：只去掉最后一个扩展名', () {
      expect(fileNameStem('a.b.mp4'), 'a.b');
      expect(fileNameStem('movie.zh.srt'), 'movie.zh');
      expect(fileNameStem('noext'), 'noext');
      expect(fileNameStem('.hidden'), '.hidden');
    });

    test('媒体类型：视频 / 音频 / 不是媒体', () {
      expect(mediaKindOfName('a.mp4'), MediaKind.video);
      expect(mediaKindOfName('a.MKV'), MediaKind.video);
      expect(mediaKindOfName('a.ts'), MediaKind.video);
      expect(mediaKindOfName('a.rmvb'), MediaKind.video);
      expect(mediaKindOfName('a.flac'), MediaKind.audio);
      expect(mediaKindOfName('a.opus'), MediaKind.audio);
      expect(mediaKindOfName('a.srt'), isNull);
      expect(mediaKindOfName('a.jpg'), isNull);
      expect(mediaKindOfName('a'), isNull);
    });

    test('父目录：根下的文件回 /', () {
      expect(parentPathOf('/home/videos/a.mp4'), '/home/videos');
      expect(parentPathOf('/a.mp4'), '/');
      expect(parentPathOf(''), '/');
    });
  });

  group('自然序', () {
    test('数字段按数值比（字典序会反过来）', () {
      expect(compareNatural('ep2.mkv', 'ep10.mkv'), lessThan(0));
      expect(compareNatural('ep10.mkv', 'ep2.mkv'), greaterThan(0));
      expect(compareNatural('第2集.mp4', '第10集.mp4'), lessThan(0));
    });

    test('忽略大小写，但大小写不同时仍然稳定（不会互相判等）', () {
      expect(compareNatural('a.mp4', 'A.mp4'), isNot(0));
      expect(compareNatural('A.mp4', 'a.mp4'), lessThan(0));
      expect(compareNatural('a.mp4', 'a.mp4'), 0);
    });

    test('前导零按数值比（数值相同则用原串稳定定序）', () {
      expect(compareNatural('ep007.mkv', 'ep8.mkv'), lessThan(0));
      // `007` 与 `7` 数值相同：不能判等（两个真实文件必须有确定顺序）
      expect(compareNatural('ep008.mkv', 'ep8.mkv'), isNot(0));
      expect(
        compareNatural('ep008.mkv', 'ep8.mkv'),
        -compareNatural('ep8.mkv', 'ep008.mkv'),
      );
    });
  });

  group('播放列表构造', () {
    test('只留同目录同类型、目录项被丢掉、按自然序排', () {
      final items = buildMediaPlaylist(
        kind: MediaKind.video,
        entries: [
          _e('ep10.mp4'),
          _e('cover.jpg'),
          _e('ep2.mp4'),
          _e('subs', isDir: true),
          _e('ep1.mp4'),
          _e('song.mp3'),
        ],
      );
      expect(items.map((e) => e.name).toList(), [
        'ep1.mp4',
        'ep2.mp4',
        'ep10.mp4',
      ]);
    });

    test('同 path 去重（服务端偶发重复项不会变成两集）', () {
      final items = buildMediaPlaylist(
        kind: MediaKind.audio,
        entries: [_e('a.mp3'), _e('a.mp3'), _e('b.mp3')],
      );
      expect(items, hasLength(2));
    });

    test('下标查找：不在列表 → -1', () {
      final items = buildMediaPlaylist(
        kind: MediaKind.video,
        entries: [_e('a.mp4'), _e('b.mp4')],
      );
      expect(playlistIndexFor(items, '/home/videos/b.mp4'), 1);
      expect(playlistIndexFor(items, '/home/videos/zzz.mp4'), -1);
    });

    test('把当前文件补进列表（目录列表漏项时上一个/下一个仍然可用）', () {
      final items = buildMediaPlaylist(
        kind: MediaKind.video,
        entries: [_e('a.mp4'), _e('c.mp4')],
      );
      final withCurrent = ensureInPlaylist(items, _e('b.mp4'));
      expect(withCurrent.map((e) => e.name).toList(), [
        'a.mp4',
        'b.mp4',
        'c.mp4',
      ]);
      // 已经在列表里 → 原样返回
      expect(ensureInPlaylist(withCurrent, _e('b.mp4')), hasLength(3));
    });
  });

  group('首尾边界', () {
    final items = [_e('a.mp4'), _e('b.mp4'), _e('c.mp4')];

    test('空列表：两边都没有', () {
      expect(hasPreviousIn(const [], 0), isFalse);
      expect(hasNextIn(const [], 0), isFalse);
    });

    test('只有一个：两边都没有', () {
      expect(hasPreviousIn([_e('a.mp4')], 0), isFalse);
      expect(hasNextIn([_e('a.mp4')], 0), isFalse);
    });

    test('第一个没有上一个、最后一个没有下一个', () {
      expect(hasPreviousIn(items, 0), isFalse);
      expect(hasNextIn(items, 0), isTrue);
      expect(hasPreviousIn(items, 1), isTrue);
      expect(hasNextIn(items, 1), isTrue);
      expect(hasPreviousIn(items, 2), isTrue);
      expect(hasNextIn(items, 2), isFalse);
    });

    test('下标非法（-1 / 越界）→ 两边都没有', () {
      expect(hasPreviousIn(items, -1), isFalse);
      expect(hasNextIn(items, -1), isFalse);
      expect(hasNextIn(items, 3), isFalse);
    });

    test('夹取：空列表 -1、下界 0、上界 length-1、单步移动', () {
      expect(clampPlaylistIndex(0, 1, 0), -1);
      expect(clampPlaylistIndex(0, -1, 3), 0);
      expect(clampPlaylistIndex(2, 1, 3), 2);
      expect(clampPlaylistIndex(1, 1, 3), 2);
      expect(clampPlaylistIndex(1, -1, 3), 0);
      expect(clampPlaylistIndex(9, 5, 3), 2);
    });
  });
}
