// **r442** · 播放列表「加歌」的**契约探针**（写动词**有界**：只动自己建的临时列表，收尾删净）。
//
// 背景（`docs/android-remaining-todo-r418.md` §二-4「Playlist 族的容器/行号核查」＋
// `docs/admin-parity-requirement.md` §68.4 诚实剩余：「把歌曲加入播放列表」UI 未接，
// 官方 = `Playlist/updatesongs` 带 `offset=已有曲数`）。
//
// 本探针要回答**契约问题**（不许猜）：
//   ① `Playlist.list` 个人/共享两库分别回什么？`song_count` 可信吗？
//   ② `Playlist.getinfo` 的 `additional.songs` 形状？（`songs_total` vs 实到条数）
//   ③ **加歌**到底怎么加：`updatesongs {id, offset, limit, songs}` 的 `offset` 是
//      "已有曲数"（追加）还是"要替换的段起点"？`limit` 给 `0` / `-1` 有何不同？
//   ④ 同一首歌再加一次会不会变成两条（`skip_duplicate` 缺省语义）？
//
// **写动词清单（本探针内，全部收尾还原）**：
//   * `Playlist/create` ×2（名字前缀 `r442probe`，**只建我自己建的**）
//   * `Playlist/updatesongs` ×3（只写这两个临时列表）
//   * `Playlist/delete` ×2（删净；收尾再列一次核对名字命中 = 0）
// 凭据只从 `--dart-define` 来（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   flutter test tool/r442_playlist_songs_probe_test.dart \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD"
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const String tag = String.fromEnvironment('TAG', defaultValue: 'r442probe');

Future<AudioStationApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');
  print('[r442] 已登录 $url as $account');
  return AudioStationApi(api);
}

String _ids(List<AudioSongDto> songs) =>
    songs.map((s) => '${s.id}:${s.title}').join(' | ');

Future<AudioPlaylistDto?> readback(AudioStationApi as, String id, String label) async {
  final p = await as.getPlaylist(id, songsLimit: 500);
  print('[r442] $label getinfo ⇒ songs=${p?.songs.length} songs_total=${p?.songsTotal} '
      'name=${p?.name} 曲目=[${_ids(p?.songs ?? const [])}]');
  return p;
}

Future<int> countByName(AudioStationApi as, String name) async {
  var hit = 0;
  for (final lib in AudioLibrary.values) {
    final page = await as.listPlaylists(library: lib, offset: 0, limit: 100);
    for (final p in page.items) {
      if (p.name.contains(name)) {
        hit++;
        print('[r442] 残留检查：命中 ${p.library}/${p.id} name=${p.name}');
      }
    }
  }
  return hit;
}

void main() {
  test('r442 播放列表加歌契约探针', () async {
    final as = await connect();
    final created = <String>[];

    try {
      // ---------- ① 只读：歌曲 & 播放列表 ----------
      final songs = await as.listSongs(
        library: AudioLibrary.personal,
        offset: 0,
        limit: 5,
      );
      print('[r442] ① Song.list personal ⇒ total=${songs.total} '
          '实到=${songs.items.length} [${_ids(songs.items)}]');
      final sharedSongs = await as.listSongs(
        library: AudioLibrary.shared,
        offset: 0,
        limit: 5,
      );
      print('[r442] ① Song.list shared ⇒ total=${sharedSongs.total} '
          '实到=${sharedSongs.items.length} [${_ids(sharedSongs.items)}]');

      for (final lib in AudioLibrary.values) {
        final page = await as.listPlaylists(library: lib, offset: 0, limit: 100);
        print('[r442] ① Playlist.list ${lib.wire} ⇒ total=${page.total} '
            '实到=${page.items.length} 前几条='
            '${page.items.take(5).map((p) => '${p.id}/${p.name}(${p.library},'
                '${p.type},count=${p.songCount})').join(' · ')}');
      }

      // 拿两个**真实存在**的曲目 id 来加歌（缺样本就如实跳过写侧）。
      final pool = <String>[
        ...songs.items.map((s) => s.id),
        ...sharedSongs.items.map((s) => s.id),
      ].where((id) => id.isNotEmpty).toList();
      print('[r442] ① 可用曲目 id 池 = ${pool.length} 个: $pool');
      if (pool.length < 2) {
        print('[r442] ⚠️ 曲目样本不足 2 个 ⇒ **跳过写侧**（不许编读数）');
        return;
      }

      // ---------- ② 只读：既有列表的 getinfo 形状 ----------
      final existing = await as.listPlaylists(
        library: AudioLibrary.personal,
        offset: 0,
        limit: 1,
      );
      if (existing.items.isNotEmpty) {
        await readback(as, existing.items.first.id, '② 既有列表'
            '(${existing.items.first.name}, list 报 song_count=${existing.items.first.songCount})');
      } else {
        print('[r442] ② 个人库没有既有列表 ⇒ 形状只看临时列表');
      }

      // ---------- ③ 写：建临时列表（带 1 首）→ 追加变体 ----------
      final a = await as.createPlaylist(
        name: '$tag-append',
        songIds: [pool[0]],
        library: AudioLibrary.personal,
      );
      if (a.isNotEmpty) created.add(a);
      print('[r442] ③ create(#1, songs=[${pool[0]}]) ⇒ id=$a');
      var pa = await readback(as, a, '③ create 回读');
      final n1 = pa?.songs.length ?? 0;

      // 变体 A：offset = 已有曲数（官方说的"加歌"姿势），limit = 0
      await as.updatePlaylistSongs(
        id: a,
        songIds: [pool[1]],
        offset: n1,
        limit: 0,
      );
      pa = await readback(as, a, '③ A: offset=$n1 limit=0 加 1 首 ⇒');
      final nA = pa?.songs.length ?? 0;
      print('[r442] ③ A 判定：$n1 → $nA '
          '${nA == n1 + 1 ? '✅ 追加成功' : nA == n1 ? '❌ 没加进去' : '⚠️ 数量异常'}');

      // 变体 B：**另一首新歌**再加一次（证明账号没被锁：与 A 同一动词、不同载荷）
      await as.updatePlaylistSongs(
        id: a,
        songIds: [pool[2]],
        offset: nA,
        limit: 0,
      );
      final pb = await readback(as, a, '③ B: 再加 1 首新歌 ⇒');
      final nB = pb?.songs.length ?? 0;
      print('[r442] ③ B 判定：$nA → $nB '
          '${nB == nA + 1 ? '✅ 追加成功（⇒ A 之后账号没有被锁）' : '⚠️ 与 A 不一致'}');

      // 变体 C：**同一首再加一次**（重复）—— 预期服务端拒绝，读它到底回什么码
      try {
        await as.updatePlaylistSongs(
          id: a,
          songIds: [pool[0]],
          offset: nB,
          limit: 0,
        );
        final pc = await readback(as, a, '③ C: 重复加同一首 ⇒');
        print('[r442] ③ C 判定：$nB → ${pc?.songs.length} ⇒ 服务端**没去重**（重复进了表）');
      } catch (e) {
        print('[r442] ③ C 判定：重复加同一首 ⇒ **被服务端拒绝**：$e');
      }

      // 变体 D：一次加**两首**新歌（批量）—— 官方"多选加歌"是否一次调用就够
      final beforeD = (await readback(as, a, '③ D 前回读'))?.songs.length ?? 0;
      if (pool.length >= 5) {
        await as.updatePlaylistSongs(
          id: a,
          songIds: [pool[3], pool[4]],
          offset: beforeD,
          limit: 0,
        );
        final pd = await readback(as, a, '③ D: 一次加 2 首 ⇒');
        final nD = pd?.songs.length ?? 0;
        print('[r442] ③ D 判定：$beforeD → $nD '
            '${nD == beforeD + 2 ? '✅ 一次调用加多首 OK' : '⚠️ 只进了 ${nD - beforeD} 首'}');
      } else {
        print('[r442] ③ D 跳过（可用曲目不足 5 首）');
      }

      // 变体 E：`songs_total` 在 `songsLimit=1` 时就给全量吗（决定"offset 怎么算"）
      final e1 = await as.getPlaylist(a, songsOffset: 0, songsLimit: 1);
      print('[r442] ③ E: getinfo(songs_limit=1) ⇒ additional.songs=${e1?.songs.length} '
          'songs_total=${e1?.songsTotal} ⇒ '
          '${(e1?.songsTotal ?? 0) > 0 ? '✅ 用 songs_total 就能算 offset（不必拉全量）' : '⚠️ songs_total 不可用'}');

      // 变体 F：空列表 + offset 0 + limit 0（"替换第一段"边角）
      final c = await as.createPlaylist(
        name: '$tag-empty',
        songIds: const [],
        library: AudioLibrary.personal,
      );
      if (c.isNotEmpty) created.add(c);
      final pc0 = await readback(as, c, '③ F: 空列表回读');
      print('[r442] ③ F 判定：空列表 songs=${pc0?.songs.length} '
          '${(pc0?.songs.length ?? -1) == 0 ? '✅ 真的空' : '⚠️ 不是空'}');
      await as.updatePlaylistSongs(
        id: c,
        songIds: [pool[1]],
        offset: 0,
        limit: 0,
      );
      final pc1 = await readback(as, c, '③ F: 空列表 offset=0 limit=0 加 1 首 ⇒');
      print('[r442] ③ F 判定：0 → ${pc1?.songs.length} '
          '${(pc1?.songs.length ?? -1) == 1 ? '✅ 空列表加歌 OK' : '⚠️ 异常'}');

      // 变体 G：offset 越界（已有 + 5）—— "追加"实现最容易踩的边角
      final beforeG = pc1?.songs.length ?? 0;
      try {
        await as.updatePlaylistSongs(
          id: c,
          songIds: [pool[0]],
          offset: beforeG + 5,
          limit: 0,
        );
        final pg = await readback(as, c, '③ G: offset=已有+5 ⇒');
        final nG = pg?.songs.length ?? 0;
        print('[r442] ③ G 判定：$beforeG → $nG '
            '${nG == beforeG + 1 ? '越界被钳到末尾（仍追加）' : nG == beforeG ? '越界 ⇒ 静默丢弃' : '⚠️ 数量异常'}');
      } catch (e) {
        print('[r442] ③ G 判定：offset 越界 ⇒ 服务端拒绝：$e');
      }

    } finally {
      // ---------- ④ 收尾：删净自己建的两个列表 ----------
      for (final id in created) {
        try {
          await as.deletePlaylist(id);
          print('[r442] ④ delete $id ⇒ ok');
        } catch (e) {
          print('[r442] ④ delete $id ⇒ ⚠️ $e');
        }
      }
      final left = await countByName(as, tag);
      print('[r442] ④ 收尾核对：名字含 `$tag` 的列表 = $left '
          '${left == 0 ? '✅ 已删净' : '❌ 还有残留'}');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
