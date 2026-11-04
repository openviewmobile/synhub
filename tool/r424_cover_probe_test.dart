// r424 · 音频「专辑真封面」素材探针（宿主侧，跑法 = `flutter test tool/…`，仪器91）。
//
// 目的：`docs/launch-readiness.md` §4.2 保留项「音频专辑真封面（代码逐字写未实现）」
// —— 先用**只读取证**回答"是本机素材没有，还是我们没实现"：
//   ① 专辑级 `Cover:getcover` 在本机是不是恒为同一张占位图（docs/thumbnail-apis.md §1.7 说 7101 B）；
//   ② 歌曲级 `Cover:getsongcover` 能不能取到**真**图（PNG/JPEG 魔数 + 字节数 + 不同歌曲是否不同）。
// 只发 `list` / `getcover` / `getsongcover`，**零写动词**。
//
// 凭据只从 `--dart-define` 来（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   export PATH="<flutter-sdk>/bin:$PATH"
//   flutter test tool/r424_cover_probe_test.dart \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD"
// ignore_for_file: avoid_print
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');

String magic(Uint8List b) {
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'PNG';
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'JPEG';
  if (b.length >= 12 &&
      String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
    return 'WEBP';
  }
  return '未知(${b.length >= 4 ? b.sublist(0, 4).map((e) => e.toRadixString(16).padLeft(2, '0')).join() : '-'})';
}

void main() {
  test('r424 专辑封面素材探针（只读）', () async {
    if (url.isEmpty || account.isEmpty || password.isEmpty) {
      fail('缺 NAS_URL/NAS_ACCOUNT/NAS_PASSWORD（只从 --dart-define 来）');
    }
    final api = DsmWebApi(
      DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
    );
    await api.discover();
    await api.login(account: account, password: password, session: 'AudioStation');
    final as = AudioStationApi(api);
    final dio = DioFactory.create(allowSelfSigned: true);

    Future<Uint8List?> fetch(String u) async {
      try {
        final r = await dio.get<List<int>>(
          u,
          options: Options(responseType: ResponseType.bytes),
        );
        final d = r.data;
        final bytes = d == null ? Uint8List(0) : Uint8List.fromList(d);
        return bytes.isEmpty ? null : bytes;
      } catch (e) {
        print('[r424]   HTTP 失败: $e');
        return null;
      }
    }

    // ① 专辑列表（取前 6 张）
    final albums = await as.listAlbums(limit: 6);
    print('[r424] 专辑总数=${albums.total}，本轮探 ${albums.items.length} 张');
    for (final a in albums.items) {
      final cover = await fetch(
        as.albumCoverUrl(a.name, albumArtist: a.albumArtist),
      );
      print('[r424] 专辑 ${a.name} / ${a.albumArtist.isEmpty ? '-' : a.albumArtist}: '
          'getcover ⇒ ${cover == null ? '无' : '${cover.length}B ${magic(cover)}'}');
    }

    // ② 歌曲级 getsongcover：逐首探（每张专辑最多 4 首）
    var withReal = 0;
    final signatures = <String>{};
    for (final a in albums.items) {
      final songs = await as.listSongs(limit: 4, album: a.name);
      for (final s in songs.items) {
        final u = as.songCoverUrl(s.id);
        final b = await fetch(u);
        if (b == null) {
          print('[r424]   song ${s.title}: getsongcover ⇒ 无（404/空）');
          continue;
        }
        final m = magic(b);
        signatures.add('${b.length}:$m');
        if (m == 'PNG' || m == 'JPEG' || m == 'WEBP') withReal++;
        print('[r424]   song ${s.title}: ${b.length}B $m');
      }
    }
    print('[r424] 小结：歌曲级真图张数=$withReal，'
        '去重签名=${signatures.length} 个（真封面应彼此不同；恒同=占位图）');

    await api.logout();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
