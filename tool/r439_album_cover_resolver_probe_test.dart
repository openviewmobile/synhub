// **`DA93`（r439）** 的代价仪：专辑级 `getcover` 拿不到真图时的**有界**逐首探。
//
// r439 · §4.2「音频专辑真封面」的**第二条只读探针**（跑法 = `flutter test tool/…`；
// 仪器91：放 `tool/` ⇒ 不进闸门②，缺凭据也不会让闸门红）。
//
// r427 的探针（`tool/r427_album_cover_probe_test.dart`）量的是"**手工**逐首深探
// 30 首"的原始事实。本探针量的是**生产实现**（`AlbumCoverResolver`）：
//   ① 同一批专辑，**新策略**（`maxSongs = 1`，`albumAlreadyTried = true`：专辑级由
//      界面先取过一次并失败）能命中几张 —— 与 r427 的"能受益 4 张"对得上吗？
//   ② **旧策略**（`maxSongs = 30`）在**同一天、同一台 NAS** 上的代价，与新策略**同表**对比
//      （A/B：命中数一样、请求数差一个量级才是"有界"的证明）。
//   ③ 新策略**一次解析的真实耗时**（列表页逐行探测的体感）。
//
// 只读：零写动词。
// 凭据只从 `--dart-define` 来（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   flutter test tool/r439_album_cover_resolver_probe_test.dart \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD"
// ignore_for_file: avoid_print
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_album_cover.dart';
import 'package:synhub/src/features/files/file_thumb.dart' show looksLikeImage;

const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const int albumLimit = int.fromEnvironment('ALBUM_LIMIT', defaultValue: 12);

Future<DsmWebApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');
  print('[r439] 已登录 $url as $account');
  return api;
}

/// 计数的取字节函数（只读；判据与生产同一条 `looksLikeImage`）。
class Counter {
  int gets = 0;
  int lists = 0;
  int http404 = 0;
  final List<String> hitUrls = <String>[];
}

AlbumCoverResolver resolverOf(AudioStationApi as, Counter c, int maxSongs) =>
    AlbumCoverResolver(
      maxSongs: maxSongs,
      probeCover: (u, cacheKey) async {
        c.gets++;
        try {
          final bytes = await as.api.getBytes(u);
          return looksLikeImage(Uint8List.fromList(bytes));
        } catch (_) {
          // 与生产同构：404 / 网络错 ⇒ 这一张没有真图（不许让异常逃出探针）
          c.http404++;
          return false;
        }
      },
      listSongs: (album, albumArtist) async {
        c.lists++;
        final page = await as.listSongs(
          album: album,
          albumArtist: albumArtist,
          limit: maxSongs,
        );
        return page.items;
      },
      albumCoverUrl: (album, albumArtist) =>
          as.albumCoverUrl(album, albumArtist: albumArtist),
      songCoverUrl: (s) => as.songCoverUrl(s.id),
    );

void main() {
  test('r439 生产解析器：有界逐首探的命中率与代价（A/B）', () async {
    if (url.isEmpty || account.isEmpty || password.isEmpty) {
      fail('缺 NAS_URL/NAS_ACCOUNT/NAS_PASSWORD（只从 --dart-define 来）');
    }
    final api = await connect();
    final as = AudioStationApi(api);

    final albums = await as.listAlbums(limit: albumLimit);
    print('[r439] Album.list ⇒ ${albums.items.length} 张（limit=$albumLimit）');

    for (final policy in const [1, 30]) {
      final c = Counter();
      final r = resolverOf(as, c, policy);
      final t0 = DateTime.now();
      var withCover = 0;
      print('');
      print('[r439] ==== 策略 maxSongs=$policy'
          '${policy == 1 ? "（r439 生产默认：列表页/详情页）" : "（旧：r427 手工深探）"} ====');
      for (final a in albums.items) {
        // ★ 忠实模拟界面路径：① `AuthedImage` 先取**专辑级** URL 一次；
        //   ② 只有它**真的**不是真图，才调回退解析器（`albumAlreadyTried: true`）。
        //   不许一上来就 assume "专辑级已经失败" —— 那样会把
        //   「示例专辑」（专辑级 200 真 JPEG）也拖去探歌曲级（假读数）。
        final au = as.albumCoverUrl(a.name, albumArtist: a.albumArtist);
        final albumOk = au.isEmpty ? false : await r.probeCover(au, '${a.name}|$au');
        String? got;
        var kind = '专辑级';
        if (albumOk) {
          got = au;
        } else {
          got = await r.resolve(
            album: a.name,
            albumArtist: a.albumArtist,
            identity: a.name,
            albumAlreadyTried: true,
          );
          kind = '歌曲级';
        }
        if (got != null) {
          withCover++;
          c.hitUrls.add(got);
        }
        print('[r439]   「${a.name}」artist=「${a.albumArtist}」 ⇒ '
            '${got == null ? "无真封面（回占位图标）" : "命中 $kind"}'
            '（本张探了 ${r.lastProbeCount} 次）');
      }
      final ms = DateTime.now().difference(t0).inMilliseconds;
      print('[r439] ---- 汇总：有真封面的专辑 = $withCover/${albums.items.length}'
          '，探测 GET = ${c.gets}（其中 404 = ${c.http404}），Song:list = ${c.lists}，'
          '总耗时 = ${ms}ms');
    }

    await api.logout();
    print('');
    print('[r439] 已登出（只读探针收尾，零写动词）');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
