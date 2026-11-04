// W1-2：播放器的**记忆**接线离线测试（倍速 / 字幕 / 队列）。
//
// 全部离线：假适配器 + 假 FileStation（FakeTransport 的响应表）+ 内存偏好存储。
// 覆盖：
//   1. 倍速重启后用回来，并能在界面上改（改完落盘）；
//   2. 内封字幕选择重启后用回来；轨道 id 不在了 → **如实降级**（不假装选中）；
//   3. 队列顺序/下标从快照恢复；切集后把新下标落盘。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/media/media_playback_store.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_tracks.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

class _MemoryAdapter implements MediaPlayerAdapter, MediaPlayerFullControls {
  final _changes = StreamController<void>.broadcast();

  final playlists = <({int index, List<String> urls})>[];
  final speeds = <double>[];
  final subtitleSelections = <String?>[];

  Duration _position = Duration.zero;
  final Duration _duration = const Duration(seconds: 100);
  bool _playing = false;
  final bool _ready = true;
  double _speed = 1;
  int _index = 0;
  int _count = 1;

  @override
  List<MediaTrackInfo> audioTracks = const [];
  @override
  List<MediaTrackInfo> subtitleTracks = const [];

  void setIndex(int v) {
    _index = v;
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> load(MediaSource source) async {}

  @override
  Future<void> setPlaylist(List<MediaSource> items, int index) async {
    playlists.add((index: index, urls: [for (final e in items) e.uri]));
    _count = items.length;
    _index = index;
  }

  @override
  Future<void> play() async {
    _playing = true;
  }

  @override
  Future<void> pause() async {
    _playing = false;
  }

  @override
  Future<void> seekTo(Duration position) async {
    _position = position;
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    speeds.add(speed);
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Duration get position => _position;
  @override
  Duration? get duration => _duration;
  @override
  bool get playing => _playing;
  @override
  bool get ready => _ready;
  @override
  double get speed => _speed;
  @override
  String? get error => null;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(color: Colors.black);
  @override
  Stream<void> get changes => _changes.stream;

  // MediaPlayerFullControls
  @override
  Future<void> skipBy(Duration offset) async {}
  @override
  Future<void> setVolume(double value) async {}
  @override
  double get volume => 1;
  @override
  Future<void> setMuted(bool value) async {}
  @override
  bool get muted => false;
  @override
  int get playlistIndex => _index;
  @override
  int get playlistLength => _count;
  @override
  bool get hasPrevious => _index > 0;
  @override
  bool get hasNext => _index < _count - 1;
  @override
  Future<void> playNext() async => setIndex(_index + 1);
  @override
  Future<void> playPrevious() async => setIndex(_index - 1);
  @override
  String? get selectedAudioTrackId => null;
  @override
  String? get selectedSubtitleTrackId => _selectedSubtitle;
  String? _selectedSubtitle;
  @override
  Future<void> selectAudioTrack(String? id) async {}
  @override
  Future<void> selectSubtitleTrack(String? id) async {
    _selectedSubtitle = id;
    subtitleSelections.add(id);
  }

  @override
  MediaAspectMode get aspectMode => MediaAspectMode.fit;
  @override
  Future<void> setAspectMode(MediaAspectMode mode) async {}
  @override
  String? get embeddedSubtitleText => null;
}

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/v/$name',
  isDir: false,
  size: 4096,
  mtime: 1758100000,
);

MediaSource _source(String name) => MediaSource(
  uri:
      'https://fake.test/webapi/entry.cgi?api=SYNO.FileStation.Download&path=/v/$name',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: name,
  supportsRange: true,
);

/// 目录列表响应（同目录三个视频）
void _seedDir(FakeTransport t) {
  t.responses['SYNO.FileStation.List.list'] = {
    'total': 3,
    'offset': 0,
    'files': [
      for (final name in ['ep1.mp4', 'ep2.mp4', 'ep3.mp4'])
        {
          'name': name,
          'path': '/v/$name',
          'isdir': false,
          'additional': {
            'size': 4096,
            'time': {'mtime': 1758100000},
          },
        },
    ],
  };
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required _MemoryAdapter adapter,
  required MediaPlaybackStore store,
  FileEntryDto? entry,
  FileStationApi? fs,
}) async {
  final container = ProviderContainer(
    overrides: [
      mediaPlayerAdapterFactoryProvider.overrideWithValue(() => adapter),
      mediaPlaybackStoreProvider.overrideWithValue(store),
      if (fs != null) fileApiProvider.overrideWithValue(fs),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: MediaPlayerView(source: _source('ep1.mp4'), entry: entry),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

Future<FileStationApi> _fakeFs() async {
  final table = <String, Map<String, dynamic>>{
    ...FakeTransport.table,
    'SYNO.FileStation.List': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
  };
  final t = FakeTransport({}, table);
  _seedDir(t);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FileStationApi(api);
}

void main() {
  group('倍速记忆', () {
    testWidgets('重启后（已存的 1.5x）打开播放器 → 用回 1.5x', (tester) async {
      final adapter = _MemoryAdapter();
      final store = InMemoryMediaPlaybackStore(speed: 1.5);
      await _pump(tester, adapter: adapter, store: store);
      await tester.pumpAndSettle();
      expect(adapter.speeds, contains(1.5));
      expect(adapter.speed, 1.5);
    });

    testWidgets('没存过 → 不设倍速（保持 1.0，零多余调用）', (tester) async {
      final adapter = _MemoryAdapter();
      await _pump(
        tester,
        adapter: adapter,
        store: InMemoryMediaPlaybackStore(),
      );
      await tester.pumpAndSettle();
      expect(adapter.speeds, isEmpty);
      expect(adapter.speed, 1.0);
    });

    testWidgets('界面上改倍速 → 立即生效且落盘', (tester) async {
      final adapter = _MemoryAdapter();
      final store = InMemoryMediaPlaybackStore();
      await _pump(tester, adapter: adapter, store: store);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('media-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('media-speed')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x').last);
      await tester.pumpAndSettle();
      expect(adapter.speed, 1.5);
      expect(await store.loadSpeed(), 1.5);
    });
  });

  group('字幕记忆', () {
    testWidgets('重启后（已存的内封轨）→ 自动选中同 id 的轨', (tester) async {
      final adapter = _MemoryAdapter()
        ..subtitleTracks = const [
          MediaTrackInfo(
            id: 'sub-2',
            kind: MediaTrackKind.subtitle,
            label: '中文',
          ),
        ];
      final store = InMemoryMediaPlaybackStore(
        subtitles: {'/v/ep1.mp4|4096': 'embedded:sub-2'},
      );
      await _pump(
        tester,
        adapter: adapter,
        store: store,
        entry: _entry('ep1.mp4'),
      );
      await tester.pumpAndSettle();
      expect(adapter.subtitleSelections, contains('sub-2'));
    });

    testWidgets('存的轨 id 不存在 → 如实降级（不选任何轨，不崩）', (tester) async {
      final adapter = _MemoryAdapter()
        ..subtitleTracks = const [
          MediaTrackInfo(
            id: 'sub-9',
            kind: MediaTrackKind.subtitle,
            label: '英文',
          ),
        ];
      final store = InMemoryMediaPlaybackStore(
        subtitles: {'/v/ep1.mp4|4096': 'embedded:sub-2'},
      );
      await _pump(
        tester,
        adapter: adapter,
        store: store,
        entry: _entry('ep1.mp4'),
      );
      await tester.pumpAndSettle();
      expect(adapter.subtitleSelections, isEmpty);
      expect(adapter.selectedSubtitleTrackId, isNull);
    });
  });

  group('队列记忆（目录来源）', () {
    testWidgets('快照顺序 + 上次下标一起恢复', (tester) async {
      final adapter = _MemoryAdapter();
      final store = InMemoryMediaPlaybackStore(
        queues: {
          '/v': MediaQueueSnapshot(
            queueKey: '/v',
            items: [
              const MediaQueueRef(path: '/v/ep3.mp4', name: 'ep3.mp4'),
              const MediaQueueRef(path: '/v/ep1.mp4', name: 'ep1.mp4'),
              const MediaQueueRef(path: '/v/ep2.mp4', name: 'ep2.mp4'),
            ],
            currentPath: '/v/ep1.mp4',
          ),
        },
      );
      await _pump(
        tester,
        adapter: adapter,
        store: store,
        entry: _entry('ep1.mp4'),
        fs: await _fakeFs(),
      );
      await tester.pumpAndSettle();
      final last = adapter.playlists.last;
      expect(last.urls[0], contains('ep3.mp4'));
      expect(last.urls[1], contains('ep1.mp4'));
      expect(last.urls[2], contains('ep2.mp4'));
      expect(last.index, 1, reason: '上次播的 ep1 在新顺序里的下标');
    });

    testWidgets('切到下一集 → 新下标落盘（重启后还在）', (tester) async {
      final adapter = _MemoryAdapter();
      final store = InMemoryMediaPlaybackStore();
      await _pump(
        tester,
        adapter: adapter,
        store: store,
        entry: _entry('ep1.mp4'),
        fs: await _fakeFs(),
      );
      await tester.pumpAndSettle();
      // 播放器回报"现在播第 2 条"（等价于原生侧切集）
      adapter.setIndex(1);
      await tester.pumpAndSettle();
      final snap = await store.loadQueue('/v');
      expect(snap, isNotNull);
      expect(snap!.currentPath, '/v/ep2.mp4');
      expect(snap.items.map((e) => e.name).toList(), [
        'ep1.mp4',
        'ep2.mp4',
        'ep3.mp4',
      ]);
    });
  });
}
