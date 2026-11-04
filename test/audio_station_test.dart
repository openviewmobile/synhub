// Audio Station 接口层离线验证（阶段二 A 第二块）。
//
// 事实来源：`docs/stage2-audio-download-api.md` §2.1–§2.4（api/method/版本/参数
// 逐字对齐 NAS 上 AudioStation 7.2.1-6006 包内的官方 Web 前端
// `app/audio-common.js` / `app/audio-utils.js`）。
// 这里只验"客户端把请求拼对了、把回包解对了、把错误码翻对了"，不打真机。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 真实 `SYNO.API.Info` 里 AS 的条目形状（path 逐字来自 `webapi/AudioStation.api`，
/// 版本区间来自 `.api` 的每版本方法表，见 doc §2.1）。
const _asTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.AudioStation.Info': {
    'path': 'AudioStation/info.cgi',
    'minVersion': 1,
    'maxVersion': 6,
  },
  'SYNO.AudioStation.Song': {
    'path': 'AudioStation/song.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Album': {
    'path': 'AudioStation/album.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Artist': {
    'path': 'AudioStation/artist.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.AudioStation.Composer': {
    'path': 'AudioStation/composer.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.AudioStation.Genre': {
    'path': 'AudioStation/genre.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Folder': {
    'path': 'AudioStation/folder.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Playlist': {
    'path': 'AudioStation/playlist.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Lyrics': {
    'path': 'AudioStation/lyrics.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.AudioStation.LyricsSearch': {
    'path': 'AudioStation/lyrics_search.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.AudioStation.Cover': {
    'path': 'AudioStation/cover.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Search': {
    'path': 'AudioStation/search.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.AudioStation.Stream': {
    'path': 'AudioStation/stream.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  // 新 API（webapi5，synoapid）：path 由真机能力表定；官方前端走 entry.cgi。
  'SYNO.AudioStation.Pin': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Future<(AudioStationApi, FakeTransport)> boot({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, Map<String, dynamic>>? apiTable,

  /// true = 能力表里**没有任何** AS API（模拟"这台 NAS 没装套件"）。
  bool noAs = false,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    if (!noAs) ..._asTable,
    ...?apiTable,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (AudioStationApi(api), t);
}

Map<String, dynamic> callOf(FakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

/// 一首歌的完整记录（字段名逐字来自官方 `createFieldConvertFunc` 的两条路径）。
Map<String, dynamic> songJson({
  String id = 'music_1',
  String title = '示例歌曲',
  String artist = '示例歌手',
  String album = '十一月的萧邦',
  String albumArtist = '示例歌手',
  String path = '/volume1/music/示例歌曲.mp3',
  int duration = 227,
  int bitrate = 320000,
  int frequency = 44100,
  int channel = 2,
  int filesize = 9090909,
  Object rating = '4.5',
  String type = 'file',
}) => {
  'id': id,
  'path': path,
  'type': type,
  'title': title,
  'artist': artist,
  'album': album,
  'support': true,
  'additional': {
    'song_tag': {
      'title': title,
      'artist': artist,
      'album': album,
      'album_artist': albumArtist,
      'composer': '示例歌手',
      'genre': 'Pop',
      'year': 2005,
      'track': 3,
      'disc': 1,
      'comment': 'demo',
    },
    'song_audio': {
      'duration': duration,
      'bitrate': bitrate,
      'frequency': frequency,
      'channel': channel,
      'filesize': filesize,
    },
    'song_rating': {'rating': rating},
  },
};

const _as = 'SYNO.AudioStation';

void main() {
  group('能力探测（未安装 ≠ 无权限 ≠ 网络）', () {
    test('能力表里有 AS Info → installed=true；没有 → installed=false', () async {
      final (audio, _) = await boot();
      expect(audio.installed, isTrue);

      final (missing, _) = await boot(noAs: true);
      expect(missing.installed, isFalse);
    });

    test('路径优先取能力表，缺了才回落 .api 的固定 path', () async {
      final (audio, _) = await boot();
      expect(audio.cgiPath('$_as.Song'), 'AudioStation/song.cgi');
      // 能力表里没有 → 回落静态表（逐字来自 doc §2.1 的 path 列）
      final (noTable, _) = await boot(noAs: true);
      expect(noTable.cgiPath('$_as.Stream'), 'AudioStation/stream.cgi');
    });

    test('版本按方法收敛（Artist=4 / Genre=3 / Song=3 / Stream=2 / Pin=1）', () async {
      final (audio, _) = await boot();
      expect(audio.versionOf('$_as.Artist'), 4);
      expect(audio.versionOf('$_as.Genre'), 3);
      expect(audio.versionOf('$_as.Song'), 3);
      expect(audio.versionOf('$_as.Stream'), 2);
      expect(audio.versionOf('$_as.Pin'), 1);
      // 能力表压到 maxVersion=2 时不该发出 v4
      final (old, t) = await boot(
        apiTable: const {
          'SYNO.AudioStation.Artist': {
            'path': 'AudioStation/artist.cgi',
            'minVersion': 1,
            'maxVersion': 2,
          },
        },
        responses: {
          'SYNO.AudioStation.Artist.list': {'artists': [], 'total': 0},
        },
      );
      await old.listArtists();
      expect(callOf(t, '$_as.Artist', 'list')['version'], '2');
    });

    test('Info.getinfo 解析能力位（is_manager 不是"仅管理员"）', () async {
      final (audio, t) = await boot(
        responses: {
          'SYNO.AudioStation.Info.getinfo': {
            'version_string': '7.2.1-6006',
            'build': 6006,
            'is_manager': true,
            'privilege': {'playlist_edit': true, 'sharing': false},
            'enable_personal_library': true,
            'transcode_to_mp3': true,
            'support_dsd_decode': false,
          },
        },
      );
      final info = await audio.getInfo();
      final call = callOf(t, '$_as.Info', 'getinfo');
      expect(call['version'], '6');
      expect(info.versionString, '7.2.1-6006');
      expect(info.isManager, isTrue);
      expect(info.playlistEdit, isTrue);
      expect(info.sharing, isFalse);
      expect(info.enablePersonalLibrary, isTrue);
      expect(info.transcodeToMp3, isTrue);
    });
  });

  group('音乐库浏览（root 与参数逐字）', () {
    test(
      'Song.list：version=3、additional 逐字、root data.songs + data.total',
      () async {
        final (audio, t) = await boot(
          responses: {
            'SYNO.AudioStation.Song.list': {
              'songs': [songJson()],
              'total': 7,
            },
          },
        );
        final page = await audio.listSongs(offset: 25, limit: 25);
        final call = callOf(t, '$_as.Song', 'list');
        expect(call['version'], '3');
        expect(call['additional'], 'song_tag,song_audio,song_rating');
        expect(call['offset'], 25);
        expect(call['limit'], 25);
        expect(page.total, 7);
        final s = page.items.single;
        expect(s.id, 'music_1');
        expect(s.title, '示例歌曲');
        expect(s.artist, '示例歌手');
        expect(s.album, '十一月的萧邦');
        expect(s.albumArtist, '示例歌手');
        expect(s.composer, '示例歌手');
        expect(s.genre, 'Pop');
        expect(s.year, 2005);
        expect(s.track, 3);
        expect(s.disc, 1);
        expect(s.duration, 227);
        expect(s.bitrate, 320000);
        expect(s.frequency, 44100);
        expect(s.channel, 2);
        expect(s.filesize, 9090909);
        expect(s.rating, closeTo(4.5, 0.001));
        expect(s.durationText, '3:47');
        expect(s.bitrateText, '320 kbps');
      },
    );

    test('Song.list 的过滤参数：album/album_artist/artist/genre/rating 区间', () async {
      final (audio, t) = await boot();
      await audio.listSongs(
        album: '十一月的萧邦',
        albumArtist: '示例歌手',
        genre: 'Pop',
        ratingMeq: 4,
        ratingLeq: 5,
        sortBy: 'title',
        descending: true,
      );
      final call = callOf(t, '$_as.Song', 'list');
      expect(call['album'], '十一月的萧邦');
      expect(call['album_artist'], '示例歌手');
      expect(call['genre'], 'Pop');
      expect(call['song_rating_meq'], 4);
      expect(call['song_rating_leq'], 5);
      expect(call['sort_by'], 'title');
      expect(call['sort_direction'], 'DESC');
    });

    test('Song.search：keyword 逐字，version=3', () async {
      final (audio, t) = await boot(
        responses: {
          'SYNO.AudioStation.Song.search': {
            'songs': [songJson(id: 'music_9')],
            'total': 1,
          },
        },
      );
      final page = await audio.searchSongs(keyword: '示例歌曲');
      final call = callOf(t, '$_as.Song', 'search');
      expect(call['version'], '3');
      expect(call['keyword'], '示例歌曲');
      expect(call['additional'], 'song_tag,song_audio,song_rating');
      expect(page.items.single.id, 'music_9');
    });

    test('Song.getinfo：同时认 data.songs[0] 与 data 直接是记录', () async {
      final (audio, _) = await boot(
        responses: {
          'SYNO.AudioStation.Song.getinfo': {
            'songs': [songJson(title: '搁浅')],
          },
        },
      );
      expect((await audio.getSong('music_1'))!.title, '搁浅');

      final (audio2, _) = await boot(
        responses: {'SYNO.AudioStation.Song.getinfo': songJson(title: '晴天')},
      );
      expect((await audio2.getSong('music_1'))!.title, '晴天');
    });

    test('Album/Artist/Composer/Genre.list：各取对的 version 与 root', () async {
      final (audio, t) = await boot(
        responses: {
          'SYNO.AudioStation.Album.list': {
            'albums': [
              {
                'name': '十一月的萧邦',
                'album_artist': '示例歌手',
                'year': 2005,
                'additional': {'avg_rating': 4.5},
              },
            ],
            'total': 1,
          },
          'SYNO.AudioStation.Artist.list': {
            'artists': [
              {
                'name': '示例歌手',
                'additional': {'avg_rating': 5},
              },
            ],
            'total': 1,
          },
          'SYNO.AudioStation.Composer.list': {
            'composers': [
              {'name': '林迈可'},
            ],
            'total': 1,
          },
          'SYNO.AudioStation.Genre.list': {
            'genres': [
              {'name': 'Pop'},
            ],
            'total': 1,
          },
        },
      );
      final albums = await audio.listAlbums(artist: '示例歌手');
      expect(callOf(t, '$_as.Album', 'list')['version'], '3');
      expect(callOf(t, '$_as.Album', 'list')['additional'], 'avg_rating');
      expect(albums.items.single.name, '十一月的萧邦');
      expect(albums.items.single.albumArtist, '示例歌手');
      expect(albums.items.single.year, 2005);
      expect(albums.items.single.avgRating, closeTo(4.5, 0.001));

      final artists = await audio.listArtists(genre: 'Pop');
      final ac = callOf(t, '$_as.Artist', 'list');
      expect(ac['version'], '4');
      expect(ac['genre'], 'Pop');
      expect(artists.items.single.name, '示例歌手');

      await audio.listComposers();
      expect(callOf(t, '$_as.Composer', 'list')['version'], '2');

      await audio.listGenres();
      expect(callOf(t, '$_as.Genre', 'list')['version'], '3');
    });

    test('Genre.list_default_genre 必须是 v3', () async {
      final (audio, t) = await boot(
        responses: {
          'SYNO.AudioStation.Genre.list_default_genre': {
            'genres': [
              {'name': 'Pop'},
            ],
          },
        },
      );
      final genres = await audio.listDefaultGenres();
      expect(callOf(t, '$_as.Genre', 'list_default_genre')['version'], '3');
      expect(genres.single.name, 'Pop');
    });

    test(
      'Folder.list：root data.items + data.folder_total，id/path 可选',
      () async {
        final (audio, t) = await boot(
          responses: {
            'SYNO.AudioStation.Folder.list': {
              'items': [
                {
                  'id': 'dir_1',
                  'path': '/music/rock',
                  'title': 'rock',
                  'type': 'folder',
                },
                {
                  'id': 'music_1',
                  'path': '/music/a.mp3',
                  'title': 'a.mp3',
                  'type': 'file',
                  'additional': songJson()['additional'],
                },
              ],
              'folder_total': 3,
              'total': 12,
            },
          },
        );
        final page = await audio.listFolders(id: 'dir_1');
        final call = callOf(t, '$_as.Folder', 'list');
        expect(call['version'], '3');
        expect(call['id'], 'dir_1');
        expect(call['additional'], 'song_tag,song_audio,song_rating');
        expect(page.folderTotal, 3);
        expect(page.total, 12);
        expect(page.items.first.isFolder, isTrue);
        expect(page.items.last.isFolder, isFalse);
      },
    );

    test('Playlist.list：root data.playlists + type/library', () async {
      final (audio, t) = await boot(
        responses: {
          'SYNO.AudioStation.Playlist.list': {
            'playlists': [
              {
                'id': 'playlist_1',
                'name': '通勤',
                'library': 'personal',
                'type': 'normal',
              },
              {'id': 'playlist_2', 'name': '智能收藏', 'type': 'smart'},
            ],
            'total': 2,
          },
        },
      );
      final page = await audio.listPlaylists();
      expect(callOf(t, '$_as.Playlist', 'list')['version'], '3');
      expect(page.items.first.name, '通勤');
      expect(page.items.first.isSmart, isFalse);
      expect(page.items.last.isSmart, isTrue);
    });

    test(
      'Playlist.getinfo：root data.playlists[0]，曲目在 additional.songs',
      () async {
        final (audio, t) = await boot(
          responses: {
            'SYNO.AudioStation.Playlist.getinfo': {
              'playlists': [
                {
                  'id': 'playlist_1',
                  'name': '通勤',
                  'type': 'normal',
                  'additional': {
                    'songs': [
                      // 播放列表视图的字段路径：additional.songs[].additional.*
                      {
                        'id': 'music_1',
                        'path': '/volume1/music/a.mp3',
                        'title': 'a',
                        'additional': songJson(title: 'a')['additional'],
                      },
                    ],
                    'songs_total': 1,
                  },
                },
              ],
            },
          },
        );
        final p = await audio.getPlaylist('playlist_1');
        final call = callOf(t, '$_as.Playlist', 'getinfo');
        expect(call['version'], '3');
        expect(call['id'], 'playlist_1');
        expect(
          call['additional'],
          'songs_song_tag,songs_song_audio,songs_song_rating,sharing_info',
        );
        expect(p!.name, '通勤');
        expect(p.songsTotal, 1);
        expect(p.songs.single.title, 'a');
        expect(
          p.songs.single.artist,
          '示例歌手',
        ); // 嵌在 songs[].additional.song_tag 里
        expect(p.songs.single.duration, 227);
      },
    );

    test('Search.list：keyword + 五个分类键都等于关键字（官方 getSearchJsonObj）', () async {
      final (audio, t) = await boot(
        responses: {
          'SYNO.AudioStation.Search.list': {
            'songs': [songJson()],
            'albums': [
              {'name': '十一月的萧邦'},
            ],
            'artists': [
              {'name': '示例歌手'},
            ],
          },
        },
      );
      final r = await audio.globalSearch(keyword: '示例歌手');
      final call = callOf(t, '$_as.Search', 'list');
      expect(call['version'], '1');
      expect(call['keyword'], '示例歌手');
      expect(call['album'], '示例歌手');
      expect(call['artist'], '示例歌手');
      expect(call['composer'], '示例歌手');
      expect(call['genre'], '示例歌手');
      expect(call['title'], '示例歌手');
      expect(r.songs.single.title, '示例歌曲');
      expect(r.albums.single.name, '十一月的萧邦');
      expect(r.artists.single.name, '示例歌手');
      expect(r.composers, isEmpty);
    });
  });

  group('歌词 / 评分 / 收藏', () {
    test('Lyrics.getlyrics：v2、POST、回包取 data.lyrics', () async {
      final (audio, t) = await boot(
        responses: {
          'SYNO.AudioStation.Lyrics.getlyrics': {'lyrics': '[00:01]示例歌曲'},
        },
      );
      final text = await audio.getLyrics('music_1');
      final call = callOf(t, '$_as.Lyrics', 'getlyrics');
      expect(call['version'], '2');
      expect(call['id'], 'music_1');
      expect(text, '[00:01]示例歌曲');
    });

    test('Lyrics.searchlyrics：title/artist/limit/additional 逐字', () async {
      final (audio, t) = await boot(
        responses: {
          'SYNO.AudioStation.LyricsSearch.searchlyrics': {'lyrics': 'x'},
        },
      );
      await audio.searchLyrics(title: '示例歌曲', artist: '示例歌手');
      final call = callOf(t, '$_as.LyricsSearch', 'searchlyrics');
      expect(call['version'], '2');
      expect(call['title'], '示例歌曲');
      expect(call['artist'], '示例歌手');
      expect(call['limit'], 1);
      expect(call['additional'], 'full_lyrics');
    });

    test('Song.setrating：v2、id 是逗号串、rating 0–5 收敛', () async {
      final (audio, t) = await boot();
      await audio.setRating(['music_1', 'music_2'], 9);
      final call = callOf(t, '$_as.Song', 'setrating');
      expect(call['version'], '2');
      expect(call['id'], 'music_1,music_2');
      expect(call['rating'], 5);
    });

    test('Pin.list：v1、offset=0&limit=-1、root items', () async {
      final (audio, t) = await boot(
        responses: {
          'SYNO.AudioStation.Pin.list': {
            'items': [
              {
                'id': 'pin_1',
                'type': 'album',
                'name': '十一月的萧邦',
                'criteria': {'album': '十一月的萧邦', 'album_artist': '示例歌手'},
              },
            ],
            'total': 1,
          },
        },
      );
      final pins = await audio.listPins();
      final call = callOf(t, '$_as.Pin', 'list');
      expect(call['version'], '1');
      expect(call['offset'], 0);
      expect(call['limit'], -1);
      expect(pins.single.type, 'album');
      expect(pins.single.criteria['album'], '十一月的萧邦');
    });

    test('Pin.pin/unpin/rename/reorder 的参数形态', () async {
      final (audio, t) = await boot();
      await audio.addPins([
        const AudioPinRequest(
          type: 'artist',
          criteria: {'artist': '示例歌手'},
          name: '示例歌手',
        ),
      ]);
      final pin = callOf(t, '$_as.Pin', 'pin');
      expect(pin['version'], '1');
      expect(
        pin['items'],
        '[{"type":"artist","criteria":{"artist":"示例歌手"},"name":"示例歌手"}]',
      );

      // ★ 官方前端 sendUnpinRequest 发的是 items（id 数组），不是 doc §2.3 写的 id
      await audio.removePins(['pin_1', 'pin_2']);
      final unpin = callOf(t, '$_as.Pin', 'unpin');
      expect(unpin['items'], '["pin_1","pin_2"]');
      expect(unpin.containsKey('id'), isFalse);

      await audio.renamePin('pin_1', '新名字');
      final rename = callOf(t, '$_as.Pin', 'rename');
      expect(rename['id'], 'pin_1');
      expect(rename['name'], '新名字');

      // ★ **DA45**（r398 真机定案）：`Pin.reorder` 的 `items` 是 **id 数组**（官方安卓
      //   客户端 `ApiEnumerator.reorder` = `Gson(idList)` + offset/limit）。
      //   旧断言只查 offset/limit，等于**没锁住载荷** ⇒ 真机上必 117 都没测出来。
      await audio.reorderPins(['pin_2', 'pin_1']);
      final reorder = callOf(t, '$_as.Pin', 'reorder');
      expect(reorder['items'], '["pin_2","pin_1"]');
      expect(reorder['offset'], 0);
      expect(reorder['limit'], -1);
      // 反向：不许再把"记录数组"发上去（那是修前必 117 的形态）
      expect((reorder['items'] as String).contains('criteria'), isFalse);
    });
  });

  group('流式 URL / 封面 URL（官方 getPlayUrl + §1.2 的 getCgiImgMapping）', () {
    // ★ 断言纠正（不是"放宽断言"，是纠正一条被真机推翻的错误断言）：
    //   旧断言钦定 `sid=FAKE-SID` 且 `_sid=` 必须不存在 —— 那是抄了官方 **Web
    //   前端** `audio-core.js` 的 `st()`（浏览器里另带 DSM 会话 cookie）。
    //   2026-09-21 真机只读实测（docs/audio-parity-audit.md §1.6）证明客户端
    //   没有 cookie 时：
    //     * `stream.cgi?…&sid=<sid>`  → `{"error":{"code":105},"success":false}`
    //     * `stream.cgi?…&_sid=<sid>` → HTTP 206 `audio/x-ms-wma` / `audio/mpeg`
    //   官方**安卓客户端** `ApiEnumerator.getPlayUrl` 逐字就是 `&_sid=`。
    //   所以正确形态是 `_sid=`；旧断言把"真机上必 105"的形态钉死了，必须改。
    test(
      'stream：stream.cgi/0.<ext> + _sid + SynoToken + version=1（官方客户端形态）',
      () async {
        final (audio, _) = await boot();
        final song = AudioSongDto.fromJson(songJson());
        final url = audio.streamUrl(
          song,
          now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );
        // ★★★ 第 274 轮：URL 里**必须**同时有 `_sid` 与 `SynoToken`。
        //
        // 这条断言是**反向验证过**的：修复前（只有 `_sid`）这里会失败，
        // 真机上就是"服务端回 HTTP 200 + {"error":{"code":105}}，Media3 报
        // None of the available extractors…" —— 音频站永远播不了。
        expect(
          url,
          'https://nas.example.com:5001/webapi/AudioStation/stream.cgi/0.mp3'
          '?_sid=FAKE-SID&SynoToken=FAKE-TOKEN&api=SYNO.AudioStation.Stream'
          '&version=1&method=stream&id=music_1&_dc=1700000000000',
        );
        // 真机：`sid=` 一律回 105；这里守住"绝不发 `sid=`"。
        expect(url.contains('sid='), isTrue);
        expect(url.contains('_sid='), isTrue);
        expect(url.contains('&sid='), isFalse);
        // 原生播放器发不了 `X-SYNO-TOKEN` 头 ⇒ CSRF 令牌只能在查询串里。
        expect(url.contains('SynoToken=FAKE-TOKEN'), isTrue);
      },
    );

    test('transcode：format/position（仅 seek 偏移）+ path-info 扩展名', () async {
      final (audio, _) = await boot();
      final song = AudioSongDto.fromJson(songJson());
      final mp3 = audio.streamUrl(
        song,
        mode: AudioStreamMode.mp3,
        position: 30,
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(mp3.contains('/0.mp3?'), isTrue);
      expect(mp3.contains('method=transcode'), isTrue);
      expect(mp3.contains('format=mp3'), isTrue);
      expect(mp3.contains('position=30'), isTrue);

      final wav = audio.streamUrl(
        song,
        mode: AudioStreamMode.wav,
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(wav.contains('/0.wav?'), isTrue);
      expect(wav.contains('format=wav'), isTrue);

      // 官方普通播放不发 `position`（只在 Chromecast 时发 0，审计 §1.7 结论 4）
      final plain = audio.streamUrl(
        song,
        mode: AudioStreamMode.mp3,
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(plain.contains('position='), isFalse);
    });

    // P0-4：官方三档 128000/192000/320000（真机实测输出长度
    // 2,432,000 / 3,648,000 / 6,080,000 B，审计 §1.7）。
    test('transcode 的 bitrate 三档；直传 / wav / 非法档位都不发', () async {
      final (audio, _) = await boot();
      final song = AudioSongDto.fromJson(songJson());
      String at(AudioStreamMode mode, int? bitrate) => audio.streamUrl(
        song,
        mode: mode,
        bitrate: bitrate,
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

      for (final bps in AudioStationApi.kTranscodeBitrates) {
        final url = at(AudioStreamMode.mp3, bps);
        expect(url.contains('bitrate=$bps'), isTrue, reason: url);
        expect(AudioStationApi.isValidTranscodeBitrate(bps), isTrue);
      }
      // 非法档位一律不发（宁可用服务端默认）
      expect(at(AudioStreamMode.mp3, 256000).contains('bitrate='), isFalse);
      expect(at(AudioStreamMode.mp3, 0).contains('bitrate='), isFalse);
      expect(AudioStationApi.isValidTranscodeBitrate(null), isFalse);
      // 直传发原文件，没有码率参数
      expect(at(AudioStreamMode.direct, 320000).contains('bitrate='), isFalse);
      // wav 是无损容器，官方也只对 mp3 发 bitrate
      expect(at(AudioStreamMode.wav, 320000).contains('bitrate='), isFalse);
    });

    test('defaultStreamMode：常见格式直传，DSD 必转码', () async {
      AudioSongDto at(String path) =>
          AudioSongDto.fromJson({'id': 'x', 'path': path});
      expect(
        AudioStationApi.defaultStreamMode(at('/m/a.mp3')),
        AudioStreamMode.direct,
      );
      expect(
        AudioStationApi.defaultStreamMode(at('/m/a.flac')),
        AudioStreamMode.direct,
      );
      // 无 transcode 能力位 → wav
      expect(
        AudioStationApi.defaultStreamMode(at('/m/a.dsf')),
        AudioStreamMode.wav,
      );
      // 有 transcode_to_mp3 → mp3
      expect(
        AudioStationApi.defaultStreamMode(
          at('/m/a.dsf'),
          info: const AudioInfoDto(transcodeToMp3: true),
        ),
        AudioStreamMode.mp3,
      );
      // 重格式（ape）走转码
      expect(
        AudioStationApi.defaultStreamMode(at('/m/a.ape')),
        AudioStreamMode.wav,
      );
    });

    // 封面通道与流式通道同一条鉴权规矩（真机 §1.6：`sid=` → 105、
    // `_sid=` → 200 `image/jpeg` 55253 B）。
    test(
      'cover：cover.cgi 的 method/view/维度键 + output_default/is_hr + _sid',
      () async {
        final (audio, _) = await boot();
        final url = audio.albumCoverUrl('十一月的萧邦', albumArtist: '示例歌手');
        expect(
          url.startsWith(
            'https://nas.example.com:5001/webapi/AudioStation/cover.cgi?',
          ),
          isTrue,
        );
        expect(url.contains('api=SYNO.AudioStation.Cover'), isTrue);
        expect(url.contains('version=3'), isTrue);
        // ⚠️ 这一条**故意改掉了旧断言**（旧断言钉的是被真机推翻的结论）：
        // 旧实现恒发 `output_default=true`，于是"没封面"回 200 固定占位 PNG
        // （4815B），UI 永远分不清有没有真封面（`docs/thumbnail-apis.md` §1.7）。
        // 现在默认**不发** `output_default`：无封面 → 404 → 回退本地图标。
        expect(url.contains('output_default'), isFalse, reason: url);
        expect(
          audio
              .albumCoverUrl('十一月的萧邦', outputDefault: true)
              .contains('output_default=true'),
          isTrue,
          reason: '需要占位图时必须能显式打开',
        );
        expect(url.contains('method=getcover'), isTrue);
        expect(url.contains('view=default'), isTrue);
        expect(url.contains('album_name='), isTrue);
        expect(url.contains('album_artist_name='), isTrue);
        // 真机：`sid=` → 105；`_sid=` 才通
        expect(url.contains('_sid=FAKE-SID'), isTrue, reason: url);
        expect(url.contains('?sid='), isFalse, reason: url);
        expect(
          audio.songCoverUrl('music_1').contains('method=getsongcover'),
          isTrue,
        );
        expect(
          audio.folderCoverUrl('dir_1').contains('method=getfoldercover'),
          isTrue,
        );
        expect(audio.artistCoverUrl('示例歌手').contains('artist_name='), isTrue);
        expect(audio.genreCoverUrl('Pop').contains('genre_name='), isTrue);
      },
    );
  });

  group('错误文案 / 失败大类', () {
    test('102/103/104/121 → 未安装；105/160 → 无权限；106/119 → 会话过期', () {
      expect(
        describeAudioError(DsmApiException(102, method: 'x')),
        '这台 NAS 没有安装 Audio Station',
      );
      expect(
        describeAudioError(DsmApiException(160, method: 'x')),
        '这个账号没有使用 Audio Station 的权限',
      );
      expect(
        describeAudioError(DsmApiException(106, method: 'x')),
        '登录已过期，请重新登录',
      );
      expect(
        audioFailureKind(DsmApiException(102, method: 'x')),
        AsFailureKind.notInstalled,
      );
      expect(
        audioFailureKind(DsmApiException(160, method: 'x')),
        AsFailureKind.noPrivilege,
      );
      expect(
        audioFailureKind(DsmApiException(106, method: 'x')),
        AsFailureKind.sessionExpired,
      );
    });

    test('业务码走官方 getErrCodeMapping（1006/1007/411/407/409）', () {
      expect(
        describeAudioError(DsmApiException(1006, method: 'x')),
        '这个项目已经收藏过了',
      );
      expect(describeAudioError(DsmApiException(1007, method: 'x')), '这个收藏不存在');
      expect(describeAudioError(DsmApiException(411, method: 'x')), '有重复的歌曲');
      expect(
        describeAudioError(DsmApiException(407, method: 'x')),
        '播放列表不存在（DSM 可能正在重建索引）',
      );
      expect(describeAudioError(DsmApiException(409, method: 'x')), '歌曲数量已达上限');
    });

    test('网络失败单独一类；未知码回"未知错误（code）"', () {
      final transport = DsmTransportException('boom');
      expect(describeAudioError(transport), '网络连接失败，请检查网络后重试');
      expect(audioFailureKind(transport), AsFailureKind.network);
      expect(
        describeAudioError(DsmApiException(999, method: 'x')),
        '未知错误（999）',
      );
      expect(
        audioFailureKind(DsmApiException(999, method: 'x')),
        AsFailureKind.other,
      );
    });

    test('未安装时能力探测不撒谎：hasApi=false', () async {
      final (audio, _) = await boot(noAs: true);
      expect(audio.hasApi('$_as.Info'), isFalse);
      expect(audio.installed, isFalse);
    });
  });

  group('DTO 工具', () {
    test('asHumanBytes / asDurationText', () {
      expect(asHumanBytes(0), '0 B');
      expect(asHumanBytes(1024), '1.0 KB');
      expect(asHumanBytes(9090909), '8.7 MB');
      expect(asDurationText(0), '—');
      expect(asDurationText(227), '3:47');
      expect(asDurationText(3727), '1:02:07');
    });

    test('fileExtension 同官方 getFileExtensionName', () {
      expect(AudioStationApi.fileExtension('/volume1/music/a.mp3'), 'mp3');
      expect(AudioStationApi.fileExtension('/volume1/music/a'), '');
      expect(AudioStationApi.fileExtension('/volume1/music/a.M4A?x=1'), 'M4A');
    });
  });
}
