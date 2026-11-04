// **r442** · 播放列表**只读**回读探针（用于"设备上做完写动词后"的服务端回读 ＋ 收尾残留核对）。
//
// 只读：只调 `Playlist.list` / `Playlist.getinfo`（零写动词）。
//   set -a; . ~/.synhub-nas.env; set +a
//   flutter test tool/r442_playlist_readback_probe_test.dart \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD"
// 可选 `--dart-define=NAME=<子串>`：只详读名字含该子串的列表（默认 `r442`）。
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const String name = String.fromEnvironment('NAME', defaultValue: 'r442');

Future<AudioStationApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');
  print('[r442-read] 已登录 $url as $account');
  return AudioStationApi(api);
}

void main() {
  test('r442 播放列表只读回读', () async {
    final as = await connect();
    var hits = 0;
    for (final lib in AudioLibrary.values) {
      final page = await as.listPlaylists(library: lib, offset: 0, limit: 100);
      print('[r442-read] Playlist.list ${lib.wire} ⇒ total=${page.total} '
          '实到=${page.items.length}');
      for (final p in page.items) {
        final check = p.name.contains(name);
        print('[r442-read]   ${p.library}/${p.id} name=${p.name} '
            'type=${p.type} list_song_count=${p.songCount}'
            '${check ? ' ← 详读' : ''}');
        if (!check) continue;
        hits++;
        final full = await as.getPlaylist(p.id, songsLimit: 500);
        print('[r442-read]   ★ ${p.id} ⇒ getinfo songs=${full?.songs.length} '
            'songs_total=${full?.songsTotal} '
            '曲目=${full?.songs.map((s) => '${s.id}:${s.title}').join(' | ')}');
      }
    }
    print('[r442-read] 名字含 `$name` 的列表 = $hits');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
