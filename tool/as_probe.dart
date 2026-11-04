// Audio Station（阶段二 A 第二块）真机探针。
//
//   # 1) 匿名能力探测（不需要账号）：这台 NAS 装没装 Audio Station
//   SYNO_NAS_URL=https://<nas>:<port> dart run tool/as_probe.dart info
//
//   # 2) 真机只读往返（需要账号；**不改任何数据**）
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/as_probe.dart probe
//
// 事实来源：`docs/stage2-audio-download-api.md` §2.1–§2.4
// （AudioStation-x86_64-7.2.1-6006.spk 的离线取证）。
//
// 探针只打**普通用户只读**方法（`Info.getinfo` / `Song.list,search,getinfo` /
// `Album.list` / `Artist.list` / `Genre.list` / `Folder.list` / `Playlist.list,
// getinfo` / `Lyrics.getlyrics` / `Pin.list`），一个 admin-only 都不碰，
// 也**不**调用 `setrating`/`pin`/`unpin` 这类写方法（不给用户库留副作用）。
//
// ⚠️ 本探针是"核事实用"的：所有请求都打印实际发出的参数与回包形状，
// 以便把文档 §5 的不确定项（U1/U3/U5/U7/U8/U9/U13）在真机上定案。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<DsmWebApi> login() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'AudioStation',
  );
  return api;
}

/// 匿名探测：只读 `SYNO.API.Info`（不需要登录）。
Future<void> info() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  final table = await api.discover();
  print('API 总数：${table.length}');
  final as = table.keys.where((k) => k.contains('AudioStation')).toList()
    ..sort();
  print('AudioStation 相关 API：${as.length}');
  for (final k in as) {
    final e = table[k]!;
    print('  $k  v${e.minVersion}..${e.maxVersion}  path=${e.path}');
  }
  if (as.isEmpty) {
    print('结论：这台 NAS **没有安装** Audio Station（普通用户功能无法真机验证）');
    return;
  }
  // §5 U5：新 API（Pin 等）是否也在同一张表里注册、path 是不是 entry.cgi。
  for (final name in [
    AudioStationApi.apiInfo,
    AudioStationApi.apiSong,
    AudioStationApi.apiStream,
    AudioStationApi.apiPin,
  ]) {
    final e = table[name];
    print(
      '  $name → ${e == null ? '未注册' : 'v${e.minVersion}..${e.maxVersion} @ ${e.path}'}',
    );
  }
}

Future<void> probe() async {
  final api = await login();
  final as = AudioStationApi(api);
  print('installed=${as.installed}');
  if (!as.installed) {
    print('结论：这台 NAS **没有安装** Audio Station —— 后面的方法一个都不发。');
    return;
  }

  print('--- Info.getinfo（v6；§5 U1 权限位、U3 转码开关）');
  final info = await _tryPrint('Info.getinfo', () => as.getInfo());
  if (info != null) {
    print(
      '  version=${info.versionString} build=${info.build} '
      'is_manager=${info.isManager} playlist_edit=${info.playlistEdit} '
      'sharing=${info.sharing} transcode_to_mp3=${info.transcodeToMp3} '
      'personal_library=${info.enablePersonalLibrary}',
    );
  }

  print('--- Song.list（第一页；root data.songs + data.total）');
  final songs = await _tryPrint('Song.list', () => as.listSongs(limit: 5));
  if (songs != null) {
    print('  total=${songs.total} 本页=${songs.items.length}');
    for (final s in songs.items) {
      print(
        '  #${s.id} ${s.title} / ${s.artist} / ${s.album} '
        'dur=${s.duration}s br=${s.bitrate} freq=${s.frequency} '
        'ch=${s.channel} rating=${s.rating} path=${s.path}',
      );
    }
  }

  print('--- Album.list / Artist.list / Genre.list（各第一页）');
  await _tryPrint('Album.list', () async {
    final p = await as.listAlbums(limit: 3);
    print('  total=${p.total} 本页=${p.items.length}');
    for (final a in p.items) {
      print('  ${a.name} / ${a.albumArtist} / ${a.year} ★${a.avgRating}');
    }
  });
  await _tryPrint('Artist.list', () async {
    final p = await as.listArtists(limit: 3);
    print('  total=${p.total} 本页=${p.items.length}');
    for (final a in p.items) {
      print('  ${a.name} ★${a.avgRating}');
    }
  });
  await _tryPrint('Genre.list', () async {
    final p = await as.listGenres(limit: 3);
    print('  total=${p.total} 本页=${p.items.length}');
    for (final a in p.items) {
      print('  ${a.name} ★${a.avgRating}');
    }
  });
  await _tryPrint('Genre.list_default_genre（v3 专属）', () async {
    final p = await as.listDefaultGenres();
    print('  ${p.length} 条：${p.take(8).map((e) => e.name).join(" / ")}');
  });

  print('--- Folder.list（根目录；root data.items + data.folder_total）');
  await _tryPrint('Folder.list', () async {
    final p = await as.listFolders(limit: 5);
    print(
      '  total=${p.total} folder_total=${p.folderTotal} 本页=${p.items.length}',
    );
    for (final i in p.items) {
      print('  ${i.isFolder ? "[目录]" : "[文件]"} ${i.title} id=${i.id}');
    }
  });

  print('--- Playlist.list（v3，**只读**）');
  await _tryPrint('Playlist.list', () async {
    final p = await as.listPlaylists(limit: 5);
    print('  total=${p.total} 本页=${p.items.length}');
    for (final pl in p.items) {
      print('  ${pl.name} type=${pl.type} library=${pl.library}');
    }
  });

  print('--- Pin.list（**新 API**，v1；§5 U13 参数/结构）');
  await _tryPrint('Pin.list', () async {
    final pins = await as.listPins();
    print('  ${pins.length} 条');
    for (final p in pins) {
      print('  type=${p.type} name=${p.name} criteria=${p.criteria}');
    }
  });

  print('--- Lyrics.getlyrics（v2，POST；§5 U9 返回字段）');
  if (songs != null && songs.items.isNotEmpty) {
    final first = songs.items.first;
    await _tryPrint('Lyrics.getlyrics', () async {
      final text = await as.getLyrics(first.id);
      print('  歌词长度=${text.length} 首行=${text.split("\n").first}');
    });
    print('--- Stream.stream 的 URL 形态（只打印，不播；§5 U3 鉴权参数）');
    print('  direct=${as.streamUrl(first)}');
    print('  transcode(mp3)=${as.streamUrl(first, mode: AudioStreamMode.mp3)}');
    print(
      '  defaultMode=${AudioStationApi.defaultStreamMode(first, info: info)}',
    );
    print('--- Song.getinfo（v3；§5 U8 单曲记录根路径）');
    await _tryPrint('Song.getinfo', () async {
      final one = await as.getSong(first.id);
      print('  ${one == null ? '未解析到记录' : one.title}');
    });
  }
}

Future<T?> _tryPrint<T>(String what, Future<T> Function() run) async {
  try {
    final v = await run();
    print('  ✔ $what');
    return v;
  } catch (e) {
    print('  ✘ $what → ${describeAudioError(e)}');
    return null;
  }
}

Future<void> main(List<String> args) async {
  final cmd = args.isEmpty ? 'info' : args.first;
  switch (cmd) {
    case 'info':
      await info();
    case 'probe':
      await probe();
    default:
      stderr.writeln('用法: dart run tool/as_probe.dart [info|probe]');
      exitCode = 2;
  }
}
