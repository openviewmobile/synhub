// libmpv 兜底引擎的**选择策略**用例（r655 · DA262）。
//
// 判据（每一条都对应一个"换/不换"的确定结论，不猜文件后缀）：
//   ① 音轨非空且**全都不支持** ⇒ 换；
//   ② 音轨里有能用的（那怕只有一条）⇒ **不换**（能用主引擎就别付 libmpv 的代价）；
//   ③ 音轨列表为空（容器里没有音轨信息）⇒ 不换；
//   ④ 错误被判成"解不了"（codecUnsupported / decodeFailed）⇒ 换；
//   ⑤ 错误是会话失效 / 服务端拒绝 / 网络不通 ⇒ **不换**（换引擎救不了，换了只会
//      把"服务端拒绝"伪装成"播放失败"）；
//   ⑥ 换引擎时**位置与播放意图必须保留**（否则用户看到的是"从头开始"）；
//   ⑦ 换过之后 `audioTracks` 一律 `isSupported == true`（libmpv 自带解码器）——
//      界面上那条"本机不支持"的横幅因此自己消失，不需要第二套 UI 分支。
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/media/fallback_player_adapter.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_tracks.dart';

MediaSource _playable() => const MediaSource(
      uri: 'https://fake.test/webapi/entry.cgi?api=SYNO.FileStation.Download',
      channel: MediaChannel.fileStation,
      kind: MediaKind.video,
      displayName: 'AC3-sample.mkv',
      supportsRange: true,
    );

class _FakeAdapter implements MediaPlayerAdapter, MediaPlayerFullControls {
  _FakeAdapter({this.tags = const []});

  final List<String> tags;
  final _changes = StreamController<void>.broadcast();

  final loads = <String>[];
  final seeks = <Duration>[];
  bool disposed = false;
  int playCalls = 0;

  Duration positionValue = Duration.zero;
  bool playingValue = false;
  String? errorValue;
  double volumeValue = 0.5;
  double speedValue = 1;
  MediaAspectMode aspectValue = MediaAspectMode.fit;

  /// 载入后要暴露的音轨（"支持/不支持"由用例自己定）
  List<MediaTrackInfo> audioValue = const [];

  /// `load()` 里抛的异常（模拟"起播就崩"）
  Object? loadThrows;

  void emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> load(MediaSource source) async {
    loads.add(source.uri);
    if (loadThrows != null) throw loadThrows!;
  }

  @override
  Future<void> play() async {
    playCalls++;
    playingValue = true;
    emit();
  }

  @override
  Future<void> pause() async {
    playingValue = false;
    emit();
  }

  @override
  Future<void> seekTo(Duration position) async {
    positionValue = position;
    seeks.add(position);
    emit();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Widget buildSurface(BuildContext context) => const SizedBox(key: Key('surface'));

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Duration get position => positionValue;
  @override
  Duration? get duration => const Duration(minutes: 10);
  @override
  bool get playing => playingValue;
  @override
  bool get ready => true;
  @override
  double get speed => speedValue;
  @override
  String? get error => errorValue;
  @override
  double get aspectRatio => 16 / 9;

  @override
  Future<void> setSpeed(double speed) async => speedValue = speed;

  @override
  Future<void> skipBy(Duration offset) async {}

  @override
  Future<void> setVolume(double value) async => volumeValue = value;
  @override
  double get volume => volumeValue;
  @override
  Future<void> setMuted(bool value) async {}
  @override
  bool get muted => false;

  final playlistCalls = <List<String>>[];
  int playlistIndexValue = 0;

  @override
  Future<void> setPlaylist(List<MediaSource> items, int index) async {
    playlistCalls.add(items.map((s) => s.uri).toList(growable: false));
    playlistIndexValue = index;
    loads.add(items[index].uri);
  }
  @override
  int get playlistIndex => playlistIndexValue;
  @override
  int get playlistLength => playlistCalls.isEmpty ? 1 : playlistCalls.last.length;
  @override
  bool get hasPrevious => false;
  @override
  bool get hasNext => false;
  @override
  Future<void> playNext() async {}
  @override
  Future<void> playPrevious() async {}

  @override
  List<MediaTrackInfo> get audioTracks => audioValue;
  @override
  List<MediaTrackInfo> get subtitleTracks => const [];
  @override
  String? get selectedAudioTrackId => null;
  @override
  String? get selectedSubtitleTrackId => null;
  @override
  Future<void> selectAudioTrack(String? id) async {}
  @override
  Future<void> selectSubtitleTrack(String? id) async {}

  @override
  MediaAspectMode get aspectMode => aspectValue;
  @override
  Future<void> setAspectMode(MediaAspectMode mode) async => aspectValue = mode;

  @override
  String? get embeddedSubtitleText => null;
}

MediaTrackInfo _track({required bool supported}) => MediaTrackInfo(
      id: 'audio:0:1',
      kind: MediaTrackKind.audio,
      label: 'English',
      codec: 'audio/vnd.dts',
      channels: 6,
      isSupported: supported,
    );

/// libmpv 侧：它列出来的音轨一律 supported（这正是"兜底"的意义）
_FakeAdapter _mpvLike() => _FakeAdapter(tags: const ['mpv'])
  ..audioValue = [_track(supported: true)];

void main() {
  test('① 音轨全都"本机不支持" ⇒ 换 libmpv，且位置与播放意图保留', () async {
    final primary = _FakeAdapter(tags: const ['primary'])
      ..audioValue = [
        _track(supported: false),
        MediaTrackInfo(
          id: 'audio:1:2',
          kind: MediaTrackKind.audio,
          codec: 'audio/ac3',
          isSupported: false,
        ),
      ]
      ..positionValue = const Duration(minutes: 3, seconds: 20)
      ..playingValue = true;
    final fallback = _mpvLike();
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () => fallback,
    );

    await adapter.load(_playable());

    expect(adapter.usingFallbackEngine, isTrue);
    expect(adapter.fallbackEngineReason,
        MediaFallbackEngineReason.audioTracksUnsupported);
    expect(primary.disposed, isTrue, reason: '主引擎必须释放（纹理/解码器都要还回去）');
    expect(fallback.loads, hasLength(1));
    expect(fallback.seeks, contains(const Duration(minutes: 3, seconds: 20)),
        reason: '换引擎不许把用户打回开头');
    expect(fallback.playCalls, greaterThan(0), reason: '原来在播 ⇒ 换完继续播');
    // ⑦ 换过之后"不支持"的标记必须消失（界面横幅因此自己消失）
    expect(adapter.audioTracks.every((t) => t.isSupported), isTrue);
  });

  test(
    '⑩ DA266：音轨是 `load()` **之后**才到的（Media3 的真实时序）⇒ 到了也不许漏判',
    () async {
      // 真机现象（r655）：`load()` 返回时 `tracks` 还是空的 ⇒ 旧实现在这里判成
      // "全都支持"、永不换引擎，用户看到"有画面没声音、也没提示"。
      final primary = _FakeAdapter();
      final fallback = _FakeAdapter(tags: const ['fallback']);
      final adapter = FallbackPlayerAdapter(
        primary: primary,
        createFallback: () => fallback,
        enabled: true,
      );
      addTearDown(adapter.dispose);

      await adapter.load(_playable());
      expect(fallback.loads, isEmpty, reason: '进 load 时还没有音轨，不许瞎换');

      // Media3 的 `onTracksChanged` 到了：只有一条 AC3，且被判"本机解不了"
      primary.audioValue = const [
        MediaTrackInfo(
          id: 'audio:0:0',
          kind: MediaTrackKind.audio,
          label: 'English',
          codec: 'audio/ac3',
          channels: 6,
          isSupported: false,
        ),
      ];
      primary.emit();
      await Future<void>.delayed(Duration.zero);

      expect(fallback.loads, hasLength(1), reason: 'DA266：晚到的轨道也必须触发换引擎');
      expect(adapter.usingFallbackEngine, isTrue);
      expect(
        adapter.fallbackEngineReason,
        MediaFallbackEngineReason.audioTracksUnsupported,
      );
    },
  );

  test('⑪ DA266 反向：晚到的音轨**能解** ⇒ 一次都不换（别把正常文件赶去 libmpv）', () async {
    final primary = _FakeAdapter();
    final fallback = _FakeAdapter(tags: const ['fallback']);
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () => fallback,
      enabled: true,
    );
    addTearDown(adapter.dispose);

    await adapter.load(_playable());
    primary.audioValue = const [
      MediaTrackInfo(
        id: 'audio:0:0',
        kind: MediaTrackKind.audio,
        label: 'English',
        codec: 'audio/mp4a',
        isSupported: true,
      ),
    ];
    primary.emit();
    await Future<void>.delayed(Duration.zero);

    expect(fallback.loads, isEmpty);
    expect(adapter.usingFallbackEngine, isFalse);
  });

  test('⑫ DA268：有播放列表的入口走 `setPlaylist()`（不是 `load()`）也要能判、也要能换', () async {
    // 真机：文件页把同目录兄弟条目当播放列表交给页面 ⇒ 页面调 `setPlaylist`。
    // 旧实现在这条路上给的兜底**一次都不会触发**（探针证明 `load()` 没被调）。
    final primary = _FakeAdapter();
    final fallback = _FakeAdapter(tags: const ['fallback']);
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () => fallback,
      enabled: true,
    );
    addTearDown(adapter.dispose);

    final items = [
      _playable(),
      const MediaSource(
        uri: 'https://nas.example/next.mkv',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'next.mkv',
      ),
    ];
    await adapter.setPlaylist(items, 1);
    primary.audioValue = const [
      MediaTrackInfo(
        id: 'audio:0:0',
        kind: MediaTrackKind.audio,
        codec: 'audio/ac3',
        isSupported: false,
      ),
    ];
    primary.emit();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(adapter.usingFallbackEngine, isTrue, reason: 'DA268：这条路也必须换');
    // 兜底引擎只装**当前这一条**（真机上 media_kit 的 Playlist 模式拿不到轨道表），
    // 但"队里还有几条"由本类记账 ⇒ 数字必须还是 2，且停在 1。
    expect(fallback.loads, <String>[items[1].uri]);
    expect(adapter.playlistLength, 2, reason: '换引擎后队不许缩成 1');
    expect(adapter.playlistIndex, 1, reason: '换引擎后要停在同一集');
    expect(adapter.hasPrevious, isTrue);
    expect(adapter.hasNext, isFalse);

    // 换集：走记账 + 让当前引擎装下一条（不是让内层引擎自己翻页）
    await adapter.playPrevious();
    expect(adapter.playlistIndex, 0);
    expect(fallback.loads.last, items[0].uri);
  });

  test('② 有一条音轨能用 ⇒ 不换（能用主引擎就不付 libmpv 的代价）', () async {
    final primary = _FakeAdapter()
      ..audioValue = [
        _track(supported: false),
        _track(supported: true),
      ];
    var created = 0;
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () {
        created++;
        return _mpvLike();
      },
    );

    await adapter.load(_playable());

    expect(created, 0);
    expect(adapter.usingFallbackEngine, isFalse);
    expect(primary.disposed, isFalse);
  });

  test('③ 音轨列表为空 ⇒ 不换', () async {
    final primary = _FakeAdapter(); // audioValue 默认空
    var created = 0;
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () {
        created++;
        return _mpvLike();
      },
    );

    await adapter.load(_playable());

    expect(created, 0);
    expect(adapter.usingFallbackEngine, isFalse);
  });

  test('④ 错误被判成"解不了" ⇒ 换', () async {
    final primary = _FakeAdapter()
      ..errorValue = 'ERROR_CODE_DECODING_FORMAT_UNSUPPORTED';
    final fallback = _mpvLike();
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () => fallback,
    );

    await adapter.load(_playable());

    expect(adapter.usingFallbackEngine, isTrue);
    expect(adapter.fallbackEngineReason, MediaFallbackEngineReason.decodeFailure);
    expect(fallback.loads, hasLength(1));
  });

  test('⑤ 会话失效 / 服务端拒绝 / 网络不通 ⇒ 不换（换引擎救不了）', () async {
    for (final err in const [
      'ERROR_CODE_IO_BAD_HTTP_STATUS (http=403)',
      'session expired (code 106)',
      'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
    ]) {
      final primary = _FakeAdapter()..errorValue = err;
      var created = 0;
      final adapter = FallbackPlayerAdapter(
        primary: primary,
        createFallback: () {
          created++;
          return _mpvLike();
        },
      );
      await adapter.load(_playable());
      expect(created, 0, reason: '不该为「$err」换引擎');
      expect(adapter.usingFallbackEngine, isFalse);
    }
  });

  test('⑥ 换过之后不再换第二次（同一文件不许来回折腾）', () async {
    final primary = _FakeAdapter()
      ..audioValue = [_track(supported: false)];
    var created = 0;
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () {
        created++;
        return _mpvLike();
      },
    );

    await adapter.load(_playable());
    await adapter.load(_playable());

    expect(created, 1);
    expect((adapter.activeAdapter as _FakeAdapter).loads, hasLength(2),
        reason: '第二次载入应落到**当前**引擎上，而不是再新建一个');
  });

  test('⑦ enabled=false（非 Android 主引擎）⇒ 永不换', () async {
    final primary = _FakeAdapter()..audioValue = [_track(supported: false)];
    var created = 0;
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () {
        created++;
        return _mpvLike();
      },
      enabled: false,
    );

    await adapter.load(_playable());

    expect(created, 0);
    expect(adapter.usingFallbackEngine, isFalse);
  });

  test('⑧ 转发：控制类调用落到**当前**引擎；changes 事件不会因为换引擎而断', () async {
    final primary = _FakeAdapter()..audioValue = [_track(supported: false)];
    final fallback = _mpvLike();
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () => fallback,
    );
    var events = 0;
    final sub = adapter.changes.listen((_) => events++);

    await adapter.load(_playable());
    await adapter.seekTo(const Duration(seconds: 90));
    await Future<void>.delayed(Duration.zero);

    expect(fallback.seeks.last, const Duration(seconds: 90));
    expect(primary.seeks, isEmpty, reason: '主引擎已释放，不该再收到调用');
    expect(events, greaterThan(0), reason: '换引擎后事件流必须还在（页面靠它 setState）');
    await sub.cancel();
  });

  test('⑨ dispose 释放**当前**引擎并关闭事件流', () async {
    final primary = _FakeAdapter()..audioValue = [_track(supported: false)];
    final fallback = _mpvLike();
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () => fallback,
    );

    await adapter.load(_playable());
    await adapter.dispose();

    expect(fallback.disposed, isTrue);
  });
}
