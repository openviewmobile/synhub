// W1-2：Audio Station 单曲的**内嵌封面**接线（纯逻辑，离线）。
//
// 钉死"两级封面"的第一级决策：
//   * 有 FileStation + 有文件路径 → 生成内嵌封面请求（走 FileStation Download）；
//   * 未连 FileStation / 路径为空 / 路径无文件名 → null（调用方退服务器封面）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_cover.dart';

import 'support/chat_harness.dart' show FakeTransport;

Future<FileStationApi> _fs() async {
  final t = FakeTransport({}, FakeTransport.table);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FileStationApi(api);
}

AudioSongDto _song({
  String path = '/volume1/music/示例歌曲.mp3',
  int size = 9090909,
}) => AudioSongDto(id: 'music_1', title: '示例歌曲', path: path, filesize: size);

void main() {
  test('未连 FileStation → null（退服务器封面）', () {
    expect(embeddedSongCoverKey(song: _song(), fs: null), isNull);
  });

  test('路径为空 → null', () {
    expect(embeddedSongCoverKey(song: _song(path: ''), fs: null), isNull);
  });

  test('有 FileStation + 路径 → 内嵌封面请求走 FileStation Download', () async {
    final fs = await _fs();
    final key = embeddedSongCoverKey(song: _song(), fs: fs);
    expect(key, isNotNull);
    expect(key!.uri, contains('SYNO.FileStation.Download'));
    expect(key.cacheKey, contains('/volume1/music/示例歌曲.mp3'));
    expect(key.fileSize, 9090909);
    expect(key.extension, 'mp3');
  });

  test('路径无文件名（没有 /）→ null（不给 FileStation 一个假文件）', () async {
    final fs = await _fs();
    expect(
      embeddedSongCoverKey(
        song: _song(path: '示例歌曲.mp3'),
        fs: fs,
      ),
      isNull,
    );
  });
}
