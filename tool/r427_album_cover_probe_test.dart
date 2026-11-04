// r427 · §4.2「音频专辑真封面」的**宿主只读探针**（跑法 = `flutter test tool/…`；
// 仪器91：放 `tool/` ⇒ 不进闸门②，缺凭据也不会让闸门红）。
//
// 要回答的问题（都用**与 App 同一条 URL 构造路径**，即 `AudioStationApi`）：
//   ① 专辑级 `Cover.getcover`（**不发** `output_default`）今天在本机到底回什么？
//      —— 真图 / 占位图 / 200+HTML / 404？
//   ② 那些"专辑级拿不到真图"的专辑，它的**歌曲级** `Cover.getsongcover` 有没有真图？
//      （r424 读过"24 首里 14 首真图、同专辑同图" ⇒ 本轮复核并算出**能受益的专辑数**）
//   ③ 逐首探的**代价**：一次专辑解析要几个请求、耗时多少（决定能不能放进列表页）。
//
// 只读：不发任何写动词，不落盘到 NAS。
// 凭据只从 `--dart-define` 来（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   flutter test tool/r427_album_cover_probe_test.dart \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD"
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const int albumLimit = int.fromEnvironment('ALBUM_LIMIT', defaultValue: 12);
const int songProbePerAlbum =
    int.fromEnvironment('SONG_PROBE', defaultValue: 30);

/// 一张图/一段正文的"是什么"分类（只看前 8 字节 + content-type）。
String classify(List<int> bytes, String contentType) {
  if (bytes.isEmpty) return '空';
  final head = bytes.take(8).toList();
  if (head.length >= 3 && head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF) {
    return 'JPEG';
  }
  if (head.length >= 8 &&
      head[0] == 0x89 &&
      head[1] == 0x50 &&
      head[2] == 0x4E &&
      head[3] == 0x47) {
    return 'PNG';
  }
  if (head[0] == 0x3C) return 'HTML($contentType)';
  return '未知($contentType)';
}

class Fetcher {
  Fetcher() {
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = (cert, host, port) => true;
  }
  late final HttpClient _client;

  /// 只读一次响应体（封面图最大也就几十 KB）。
  Future<({int status, List<int> bytes, String type})> get(String u) async {
    final req = await _client.getUrl(Uri.parse(u));
    req.headers.set('User-Agent', 'synhub/1.0 (r427 cover probe)');
    final res = await req.close();
    final bytes = await res.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
    return (
      status: res.statusCode,
      bytes: bytes,
      type: res.headers.contentType?.mimeType ?? '-',
    );
  }
}

Future<DsmWebApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');
  print('[r427] 已登录 $url as $account');
  return api;
}

void main() {
  test('r427 专辑真封面只读探针', () async {
    if (url.isEmpty || account.isEmpty || password.isEmpty) {
      fail('缺 NAS_URL/NAS_ACCOUNT/NAS_PASSWORD（只从 --dart-define 来）');
    }
    final api = await connect();
    final as = AudioStationApi(api);
    final http = Fetcher();

    final albums = await as.listAlbums(limit: albumLimit);
    print('[r427] Album.list ⇒ ${albums.items.length} 张（limit=$albumLimit）');
    print('');

    var albumLevelReal = 0;
    var albumLevelNo = 0;
    var benefit = 0; // 专辑级没有真图、但歌曲级有 ⇒ 本轮改动**能受益**
    var probeRequests = 0;

    for (final a in albums.items) {
      final t0 = DateTime.now();
      final au = as.albumCoverUrl(a.name, albumArtist: a.albumArtist);
      final ar = await http.get(au);
      probeRequests++;
      final ak = classify(ar.bytes, ar.type);
      final isReal = ak == 'JPEG' || ak == 'PNG';
      if (isReal) {
        albumLevelReal++;
      } else {
        albumLevelNo++;
      }
      print('[r427] 专辑「${a.name}」artist=「${a.albumArtist}」  '
          'albumCover ${ar.status} ${ar.bytes.length}B  $ak');

      if (!isReal) {
        // 专辑级没有真图 ⇒ 逐首探歌曲级（与 UI 将要走的路径完全一致）
        final songs = await as.listSongs(
          album: a.name,
          albumArtist: a.albumArtist,
          limit: songProbePerAlbum,
        );
        probeRequests++;
        var found = false;
        var tried = 0;
        for (final s in songs.items) {
          tried++;
          final su = as.songCoverUrl(s.id);
          final sr = await http.get(su);
          probeRequests++;
          final sk = classify(sr.bytes, sr.type);
          if (sk == 'JPEG' || sk == 'PNG') {
            print('[r427]     ↳ 歌曲级命中：${s.title} id=${s.id} '
                '${sr.status} ${sr.bytes.length}B $sk（试了 $tried 首）');
            found = true;
            break;
          }
        }
        if (!found) {
          print('[r427]     ↳ 歌曲级 ${songs.items.length} 首全无真图（试了 $tried 首）');
        } else {
          benefit++;
        }
        print('[r427]     ↳ 本张专辑解析耗时 '
            '${DateTime.now().difference(t0).inMilliseconds}ms、'
            '累计请求 $probeRequests');
      }
    }

    print('');
    print('[r427] ==== 汇总（逐字读数）====');
    print('[r427] 专辑级真图 = $albumLevelReal，专辑级非真图 = $albumLevelNo');
    print('[r427] 其中"专辑级没有、歌曲级有" ⇒ 逐首回退**能受益** = $benefit 张');
    print('[r427] 本探针发出的 GET 总数 = $probeRequests');
    await api.logout();
    print('[r427] 已登出（只读探针收尾，零写动词）');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
