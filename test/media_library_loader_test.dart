// 播放列表 + 外挂字幕的**目录加载器**（`media_library_loader.dart`）离线测试。
//
// 一次 `FileStation.List.list` 同时喂播放列表与字幕候选（只列一次目录）；
// 字幕正文按需取头部（`getBytes(maxBytes:)` → `Range: bytes=0-N`）再探编码解析。
//
// 用脚手架的 `FakeTransport`（假传输）+ 本地假字节源，全程不碰网络。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/media/media_library_loader.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_subtitles.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _loaderTable = <String, Map<String, dynamic>>{
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Download': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 假传输：`authenticatedUrl` 拼 `_sid`（和真实直链同形）+ `getBytes` 返回假字节
class _LoaderTransport extends FakeTransport {
  _LoaderTransport([super.responses, super.apiTable]);

  /// 关键字 → 字节（按 URL 里是否包含关键字匹配）
  final Map<String, List<int>> blobs = {};

  /// 收到过 Range 取字节的 URL（断言"只取头部"）
  final List<String> byteUrls = [];
  final List<int?> maxBytesSeen = [];

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) {
    final qp = <String, String>{
      ...params,
      if (sid != null && sid.isNotEmpty) '_sid': sid,
      if (synoToken != null && synoToken!.isNotEmpty) 'SynoToken': synoToken!,
    };
    final q = qp.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return 'https://fake.test/webapi/$path?$q';
  }

  @override
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) async {
    byteUrls.add(url);
    maxBytesSeen.add(maxBytes);
    for (final entry in blobs.entries) {
      if (url.contains(entry.key)) return entry.value;
    }
    return const [];
  }
}

Map<String, dynamic> _file(
  String name,
  String path, {
  bool isDir = false,
  int size = 1024,
}) => {
  'name': name,
  'path': path,
  'isdir': isDir,
  'additional': {'size': size},
};

Future<DsmWebApi> _boot(_LoaderTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

FileEntryDto _entry(String name, {String? path}) => FileEntryDto(
  name: name,
  path: path ?? '/home/videos/$name',
  isDir: false,
  size: 2048,
  mtime: 1758100000,
);

void main() {
  group('一次列目录 → 播放列表 + 字幕候选', () {
    late _LoaderTransport transport;
    late FileStationApi fs;

    setUp(() async {
      transport = _LoaderTransport(
        {
          // ⚠️ 脚手架里 `responses[key]` 就是 `data` 负载（外面自动包 success/data）
          'SYNO.FileStation.List.list': {
            'total': 6,
            'offset': 0,
            'files': [
              _file('movie.mp4', '/home/videos/movie.mp4'),
              _file('ep10.mp4', '/home/videos/ep10.mp4'),
              _file('ep2.mp4', '/home/videos/ep2.mp4'),
              _file('cover.jpg', '/home/videos/cover.jpg'),
              _file('movie.srt', '/home/videos/movie.srt'),
              _file('movie.zh.srt', '/home/videos/movie.zh.srt'),
              _file('subs', '/home/videos/subs', isDir: true),
            ],
          },
        },
        {...FakeTransport.table, ..._loaderTable},
      );
      fs = FileStationApi(await _boot(transport));
    });

    MediaSource sourceOf(FileEntryDto e) => resolveFileStationSource(
      displayName: e.name,
      kind: MediaKind.video,
      fs: fs,
      path: e.path,
      size: e.size,
    );

    test('播放列表：同类型 + 自然序 + 当前文件下标', () async {
      final ctx = await loadMediaDirectoryContext(
        fs: fs,
        entry: _entry('movie.mp4'),
        kind: MediaKind.video,
        sourceOf: sourceOf,
      );
      expect(ctx, isNotNull);
      expect(ctx!.hasPlaylist, isTrue);
      expect(ctx.playlist.map((s) => s.displayName).toList(), [
        'ep2.mp4',
        'ep10.mp4',
        'movie.mp4',
      ]);
      expect(ctx.index, 2);
      // URL 真的是 FileStation 直链（带 _sid，原生播放器只吃 URL）
      expect(ctx.playlist.first.uri, contains('_sid=FAKE-SID'));
      expect(ctx.playlist.first.uri, contains('SYNO.FileStation.Download'));
    });

    test('字幕候选：同名字幕按匹配度排，自动匹配取第一条', () async {
      final ctx = await loadMediaDirectoryContext(
        fs: fs,
        entry: _entry('movie.mp4'),
        kind: MediaKind.video,
        sourceOf: sourceOf,
      );
      expect(ctx!.hasSubtitles, isTrue);
      expect(ctx.subtitleMatches.map((m) => m.name).toList(), [
        'movie.srt',
        'movie.zh.srt',
      ]);
      expect(ctx.autoMatch!.name, 'movie.srt');
      expect(
        ctx.subtitleEntries['movie.zh.srt']!.path,
        '/home/videos/movie.zh.srt',
      );
    });

    test('列目录只在**父目录**上做一次（不在每个候选上重复问）', () async {
      await loadMediaDirectoryContext(
        fs: fs,
        entry: _entry('movie.mp4'),
        kind: MediaKind.video,
        sourceOf: sourceOf,
      );
      final listCalls = transport.calls
          .where((c) => c['api'] == 'SYNO.FileStation.List')
          .toList();
      expect(listCalls, hasLength(1));
      expect(listCalls.single['folder_path'], '/home/videos');
    });

    test('视频没有同名字幕时：候选仍列出（可手选），但**不自动挂**不相关的字幕', () async {
      final ctx = await loadMediaDirectoryContext(
        fs: fs,
        entry: _entry('nosubs.mp4'),
        kind: MediaKind.video,
        sourceOf: sourceOf,
      );
      // 目录里的 movie*.srt 与 nosubs.mp4 无关：可以手选，但自动匹配必须为 null
      expect(ctx!.subtitleMatches, isNotEmpty);
      expect(ctx.autoMatch, isNull);
      // 当前文件不在目录列表里 → 补进播放列表，仍可播
      expect(ctx.playlist.map((s) => s.displayName), contains('nosubs.mp4'));
    });
  });

  group('失败一律返回 null（增强不能把能播的变成失败）', () {
    test('没有 FileStation（未连接）→ null', () async {
      expect(
        await loadMediaDirectoryContext(
          fs: null,
          entry: _entry('movie.mp4'),
          kind: MediaKind.video,
          sourceOf: (e) => throw StateError('不该被调用'),
        ),
        isNull,
      );
    });

    test('Drive 条目（drive:<file_id>）→ null', () async {
      expect(
        await loadMediaDirectoryContext(
          fs: FileStationApi(DsmWebApi(FakeTransport())),
          entry: _entry('clip.mp4', path: 'drive:7788'),
          kind: MediaKind.video,
          sourceOf: (e) => throw StateError('不该被调用'),
        ),
        isNull,
      );
    });

    test('列目录报错（离线）→ null，不抛', () async {
      final t = _LoaderTransport(
        {
          'SYNO.FileStation.List.list': {'success': true, 'data': {}},
        },
        {...FakeTransport.table, ..._loaderTable},
      )..offlineKeys.add('SYNO.FileStation.List.list');
      final fs = FileStationApi(await _boot(t));
      final ctx = await loadMediaDirectoryContext(
        fs: fs,
        entry: _entry('movie.mp4'),
        kind: MediaKind.video,
        sourceOf: (e) => resolveFileStationSource(
          displayName: e.name,
          kind: MediaKind.video,
          fs: fs,
          path: e.path,
        ),
      );
      expect(ctx, isNull);
    });
  });

  group('字幕正文：Range 只取头部 → 探测编码 → 解析', () {
    const srt = '1\n00:00:01,000 --> 00:00:03,000\n你好，世界\n';

    late _LoaderTransport transport;
    late FileStationApi fs;

    setUp(() async {
      transport = _LoaderTransport(const {}, {
        ...FakeTransport.table,
        ..._loaderTable,
      });
      transport.blobs['movie.srt'] = srt.codeUnits; // ASCII 安全的 fixture
      fs = FileStationApi(await _boot(transport));
    });

    test('取头部（maxBytes）+ 解析出 cue', () async {
      final source = resolveFileStationSource(
        displayName: 'movie.srt',
        kind: MediaKind.video,
        fs: fs,
        path: '/home/videos/movie.srt',
      );
      final track = await fetchSubtitleTrack(
        api: fs.api,
        source: source,
        match: const SubtitleMatch(
          name: 'movie.srt',
          format: SubtitleFormat.srt,
          score: 103,
        ),
      );
      expect(track, isNotNull);
      expect(track!.cues, hasLength(1));
      expect(track.cues.single.start, const Duration(seconds: 1));
      expect(transport.byteUrls.single, contains('movie.srt'));
      expect(
        transport.maxBytesSeen.single,
        kSubtitleHeadBytes,
        reason: '只取头部，不整份拉',
      );
    });

    test('空字节 / 非字幕内容 / 没 api → null（选不中那条，播放器照常）', () async {
      final source = resolveFileStationSource(
        displayName: 'movie.srt',
        kind: MediaKind.video,
        fs: fs,
        path: '/home/videos/movie.srt',
      );
      const match = SubtitleMatch(
        name: 'movie.srt',
        format: SubtitleFormat.srt,
        score: 1,
      );
      expect(
        await fetchSubtitleTrack(api: null, source: source, match: match),
        isNull,
      );
      expect(
        await fetchSubtitleTrack(
          api: fs.api,
          source: resolveFileStationSource(
            displayName: 'missing.srt',
            kind: MediaKind.video,
            fs: fs,
            path: '/home/videos/missing.srt',
          ),
          match: match,
        ),
        isNull,
        reason: '假传输对未知 URL 返回空字节',
      );
    });

    test('looksLikeSubtitleText 的粗检', () {
      expect(looksLikeSubtitleText(srt), isTrue);
      expect(looksLikeSubtitleText('[Events]\nDialogue: 0,...'), isTrue);
      expect(looksLikeSubtitleText('just text'), isFalse);
      expect(looksLikeSubtitleText('   '), isFalse);
    });
  });
}
