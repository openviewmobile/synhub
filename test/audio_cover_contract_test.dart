// Audio Station 封面通道契约 —— 针对"恒带 `output_default=true`"这条
// **真机取证**缺陷的回归保护（证据：`docs/thumbnail-apis.md` §1.7）。
//
// 真机实测（`SYNO.AudioStation.Cover`）：
//   * 无内嵌封面 + `output_default=true` → 200 **固定占位 PNG 4815B**
//     （4 首不同专辑 + 不存在 id 的字节完全相同）⇒ "没封面"与"有封面"不可分；
//   * 无内嵌封面 + **不带** `output_default` → **404** ⇒ UI 才能画"无封面"；
//   * `getsongcover` 是**唯一可靠的真封面来源**（`id=<song_id>` → 200 jpeg）；
//   * 专辑级 `getcover` 8 张专辑逐字节相同（7101B 占位）⇒ 不是真封面。
//
// 因此：**默认不发 `output_default`**；需要占位图时才显式 `outputDefault: true`。
// 旧断言 `url.contains('output_default=true')` 钉的正是被推翻的结论，
// 已在 `audio_station_test.dart` 同步改掉。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.AudioStation.Cover': {
    'path': 'AudioStation/cover.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

Future<AudioStationApi> _api() async {
  final t = FakeTransport(<String, Map<String, dynamic>>{}, {
    ...FakeTransport.table,
    ..._table,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return AudioStationApi(api);
}

void main() {
  group('Cover：默认必须能区分"有没有真封面"', () {
    test('songCoverUrl 继续走 getsongcover，且默认不带 output_default', () async {
      final api = await _api();
      final url = api.songCoverUrl('music_28045');
      expect(url, contains('method=getsongcover'), reason: url);
      expect(url, contains('id=music_28045'), reason: url);
      expect(
        url.contains('output_default'),
        isFalse,
        reason: '不带 output_default：无封面 → 404 → UI 画"无封面"',
      );
    });

    test('专辑 getcover 默认不带 output_default（拒绝通用占位图冒充封面）', () async {
      final api = await _api();
      final url = api.albumCoverUrl('十一月的萧邦', albumArtist: '示例歌手');
      expect(url, contains('method=getcover'), reason: url);
      expect(url, contains('album_name='), reason: url);
      expect(url, contains('album_artist_name='), reason: url);
      expect(url.contains('output_default'), isFalse, reason: url);
    });

    test('艺术家 / 流派 / 作曲家 / 文件夹封面同样默认不带 output_default', () async {
      final api = await _api();
      for (final url in [
        api.artistCoverUrl('示例歌手'),
        api.genreCoverUrl('Pop'),
        api.composerCoverUrl('示例歌手'),
        api.folderCoverUrl('music_28045'),
      ]) {
        expect(url.contains('output_default'), isFalse, reason: url);
        expect(url.contains('output_default=false'), isFalse, reason: url);
      }
    });

    test('需要占位图时必须能显式打开 output_default=true', () async {
      final api = await _api();
      expect(
        api.songCoverUrl('music_1', outputDefault: true),
        contains('output_default=true'),
      );
      expect(
        api.artistCoverUrl('示例歌手', outputDefault: true),
        contains('output_default=true'),
      );
      expect(
        api.genreCoverUrl('Pop', outputDefault: true),
        contains('output_default=true'),
      );
      expect(
        api.composerCoverUrl('a', outputDefault: true),
        contains('output_default=true'),
      );
      expect(
        api.folderCoverUrl('d', outputDefault: true),
        contains('output_default=true'),
      );
    });
  });
}
