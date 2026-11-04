// 自研原生播放器适配器（`native_video_player.dart`）的离线测试。
//
// 两个被测面：
//   1. `NativeVideoPlayerAdapter`（接**假 PlayerBridge**）：参数**装配**
//      （load/playlist/seek/音量/画面比例/轨道选择发到原生的是什么）与状态
//      **回读**（原生事件 → 适配器状态）、±10s 边界、播放列表首尾禁用、
//      dispose 清理、错误上报。
//   2. `MethodChannelPlayerBridge`（接 flutter_test 的 mock method handler）：
//      通道名 / 方法名 / 参数名与 Kotlin 侧逐字对齐。
//
// 有了这层，Kotlin 的 `MediaPlayerBridge.kt` 只需要保证"按这些方法名和键名收发"。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/media_tls_policy.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_tracks.dart';
import 'package:synhub/src/features/media/fallback_player_adapter.dart';
import 'package:synhub/src/features/media/native_video_player.dart';

/// 假的原生通道：记录调用 + 可注入事件
class FakePlayerBridge implements PlayerBridge {
  FakePlayerBridge({this.textureId = 7});

  final int textureId;

  int created = 0;
  int disposals = 0;
  int plays = 0;
  int pauses = 0;
  int nexts = 0;
  int previouses = 0;
  final List<Map<String, Object?>> loads = [];
  final List<int> seeks = [];
  final List<double> speeds = [];
  final List<double> volumes = [];
  final List<bool> mutes = [];
  final List<String> aspects = [];
  final List<Map<String, Object?>> trackSelections = [];

  final _events = StreamController<Map<Object?, Object?>>.broadcast();

  @override
  Future<int> create() async {
    created++;
    return textureId;
  }

  @override
  Future<void> load({
    required List<String> urls,
    required int index,
    required bool autoplay,
    required double volume,
    required bool muted,
    required double speed,
    required String aspect,
  }) async {
    loads.add({
      'urls': urls,
      'index': index,
      'autoplay': autoplay,
      'volume': volume,
      'muted': muted,
      'speed': speed,
      'aspect': aspect,
    });
  }

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> seekTo(int positionMs) async => seeks.add(positionMs);

  @override
  Future<void> setSpeed(double speed) async => speeds.add(speed);

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> setMuted(bool muted) async => mutes.add(muted);

  @override
  Future<void> playNext() async => nexts++;

  @override
  Future<void> playPrevious() async => previouses++;

  @override
  Future<void> selectTrack({required String kind, String? id}) async =>
      trackSelections.add({'kind': kind, 'id': id});

  @override
  Future<void> setAspectMode(String code) async => aspects.add(code);

  @override
  Future<void> dispose() async => disposals++;

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  /// 派发一个原生事件（交付是异步的，调用后要 [flush]）
  void emit(Map<String, Object?> event) => _events.add(event);

  void addError(Object error) => _events.addError(error);

  void close() => _events.close();
}

/// 等广播流把事件投递到适配器
Future<void> flush() => Future<void>.delayed(Duration.zero);

MediaSource _source(
  String name, {
  String uri = 'https://nas/webapi/entry.cgi?path=x.mp4',
  MediaKind kind = MediaKind.video,
}) => MediaSource(
  uri: uri,
  channel: MediaChannel.fileStation,
  kind: kind,
  displayName: name,
  supportsRange: true,
);

Map<String, Object?> _audioTrack({
  String id = 'audio:0:0',
  String language = 'zho',
  String codec = 'mp4a.40.2',
  int channels = 2,
  bool selected = true,
  bool isDefault = true,
}) => {
  'id': id,
  'kind': 'audio',
  'language': language,
  'codec': codec,
  'channels': channels,
  'default': isDefault,
  'selected': selected,
  'group': 0,
  'index': 0,
};

Map<String, Object?> _subtitleTrack({
  String id = 'subtitle:1:0',
  String language = 'chs',
  bool selected = true,
}) => {
  'id': id,
  'kind': 'subtitle',
  'language': language,
  'codec': 'subrip',
  'selected': selected,
  'group': 1,
  'index': 0,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('load / 纹理', () {
    test('载入装配：单条 URL、index 0、不自动播、音量/画面比例初值', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);

      await adapter.load(_source('a.mp4'));
      expect(bridge.created, 1, reason: '纹理只建一次');
      expect(adapter.textureId, 7);
      expect(adapter.ready, isTrue);
      final call = bridge.loads.single;
      expect(call['urls'], ['https://nas/webapi/entry.cgi?path=x.mp4']);
      expect(call['index'], 0);
      expect(call['autoplay'], false);
      expect(call['volume'], 1.0);
      expect(call['muted'], false);
      expect(call['speed'], 1.0);
      expect(call['aspect'], 'fit');
    });

    test('重复 load 不重建纹理，但每次都重新装配', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      await adapter.load(_source('b.mp4', uri: 'https://nas/b.mp4'));
      expect(bridge.created, 1);
      expect(bridge.loads, hasLength(2));
      expect(bridge.loads.last['urls'], ['https://nas/b.mp4']);
    });

    test('空 URL → 抛错且不碰原生通道（绝不把空串塞给原生）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await expectLater(
        adapter.load(_source('a.mp4', uri: '')),
        throwsA(isA<StateError>()),
      );
      expect(bridge.created, 0);
      expect(bridge.loads, isEmpty);
    });

    test('play/pause 真的过通道，并乐观更新状态', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      await adapter.play();
      expect(bridge.plays, 1);
      expect(adapter.playing, isTrue);
      await adapter.pause();
      expect(bridge.pauses, 1);
      expect(adapter.playing, isFalse);
    });

    test('setSpeed 过通道 + 事件回读', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      await adapter.setSpeed(1.5);
      expect(bridge.speeds, [1.5]);
      expect(adapter.speed, 1.5);
      bridge.emit({'kind': 'state', 'speed': 2});
      await flush();
      expect(adapter.speed, 2.0);
    });
  });

  group('播放列表与上一个/下一个', () {
    List<MediaSource> items(int n) => [
      for (var i = 0; i < n; i++) _source('$i.mp4', uri: 'https://nas/$i.mp4'),
    ];

    test('setPlaylist 装配全部 URL，下标夹取', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.setPlaylist(items(3), 1);
      expect(bridge.loads.single['urls'], [
        'https://nas/0.mp4',
        'https://nas/1.mp4',
        'https://nas/2.mp4',
      ]);
      expect(bridge.loads.single['index'], 1);
      expect(adapter.playlistIndex, 1);
      expect(adapter.playlistLength, 3);

      await adapter.setPlaylist(items(3), 99);
      expect(bridge.loads.last['index'], 2, reason: '上界夹到最后一集');
      await adapter.setPlaylist(items(3), -5);
      expect(bridge.loads.last['index'], 0);
    });

    test('空播放列表 → 抛错；空 URL 项被丢掉', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await expectLater(
        adapter.setPlaylist(const [], 0),
        throwsA(isA<StateError>()),
      );
      await adapter.setPlaylist([
        _source('a.mp4', uri: 'https://nas/a.mp4'),
        _source('b.mp4', uri: ''),
      ], 0);
      expect(bridge.loads.single['urls'], ['https://nas/a.mp4']);
      expect(adapter.playlistLength, 1);
    });

    test('第一个没有"上一个"、最后一个没有"下一个"；越界调用是 no-op', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);

      await adapter.setPlaylist(items(2), 0);
      expect(adapter.hasPrevious, isFalse);
      expect(adapter.hasNext, isTrue);
      await adapter.playPrevious();
      expect(bridge.previouses, 0, reason: '第一个文件时"上一个"不发指令');

      await adapter.playNext();
      expect(bridge.nexts, 1);
      // 原生切集后回报 index=1
      bridge.emit({'kind': 'state', 'index': 1, 'count': 2});
      await flush();
      expect(adapter.playlistIndex, 1);
      expect(adapter.hasPrevious, isTrue);
      expect(adapter.hasNext, isFalse);
      await adapter.playNext();
      expect(bridge.nexts, 1, reason: '最后一个文件时"下一个"不发指令');
      await adapter.playPrevious();
      expect(bridge.previouses, 1);
    });

    test('单文件（count=1）两边都禁用', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      expect(adapter.hasPrevious, isFalse);
      expect(adapter.hasNext, isFalse);
      await adapter.playNext();
      await adapter.playPrevious();
      expect(bridge.nexts, 0);
      expect(bridge.previouses, 0);
    });
  });

  group('±10 秒边界', () {
    test('快进不越界总时长；快退不越界 0', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));

      bridge.emit({'kind': 'state', 'positionMs': 95000, 'durationMs': 100000});
      await flush();
      await adapter.skipBy(const Duration(seconds: 10));
      expect(bridge.seeks.last, 100000, reason: '95s + 10s 夹到总时长');
      expect(adapter.position, const Duration(seconds: 100));

      bridge.emit({'kind': 'state', 'positionMs': 3000, 'durationMs': 100000});
      await flush();
      await adapter.skipBy(const Duration(seconds: -10));
      expect(bridge.seeks.last, 0, reason: '3s - 10s 夹到 0');
      expect(adapter.position, Duration.zero);
    });

    test('时长未知时只夹下界', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      bridge.emit({'kind': 'state', 'positionMs': 3000});
      await flush();
      expect(adapter.duration, isNull);
      await adapter.skipBy(const Duration(seconds: 10));
      expect(bridge.seeks.last, 13000);
    });

    test('seekTo 也夹取（负数 / 超过总时长）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      bridge.emit({'kind': 'state', 'durationMs': 60000});
      await flush();
      await adapter.seekTo(const Duration(seconds: -5));
      expect(bridge.seeks.last, 0);
      await adapter.seekTo(const Duration(minutes: 5));
      expect(bridge.seeks.last, 60000);
    });

    // Bug 3（R4 A2）：拖动 seek 之后暂停，再点播放 —— 必须从**新位置**继续，
    // 绝不能重建播放器 / 重新 load。原生侧本来就只发 play()，这条用例把
    // "适配器不偷偷重载"钉死（媒资侧一旦有人加"play 前先 load"就会挂）。
    test('seek(50%) → pause → play：不重建播放器、不重新 load、位置还在 50%', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      bridge.emit({'kind': 'state', 'durationMs': 60000});
      await flush();
      await adapter.play();
      expect(bridge.created, 1);

      await adapter.seekTo(const Duration(seconds: 30));
      await adapter.pause();
      await adapter.play();

      expect(bridge.created, 1, reason: '播放器实例不许重建');
      expect(bridge.loads, hasLength(1), reason: '不许重新 load（重载会回到 0）');
      expect(bridge.seeks.last, 30000);
      expect(adapter.position, const Duration(seconds: 30));
      expect(adapter.playing, isTrue);
    });
  });

  group('音量', () {
    test('夹到 0–1 并过通道；事件回读 0–100 → 0–1', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));

      await adapter.setVolume(1.5);
      expect(bridge.volumes.last, 1.0);
      expect(adapter.volume, 1.0);
      await adapter.setVolume(-0.5);
      expect(bridge.volumes.last, 0.0);
      await adapter.setVolume(0.35);
      expect(bridge.volumes.last, closeTo(0.35, 1e-9));

      bridge.emit({'kind': 'state', 'volume': 40});
      await flush();
      expect(adapter.volume, closeTo(0.4, 1e-9));
    });

    test('静音切换 + 调音量自动取消静音（否则"拖了没声音"）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));

      await adapter.setMuted(true);
      expect(bridge.mutes.last, isTrue);
      expect(adapter.muted, isTrue);

      await adapter.setVolume(0.8);
      expect(adapter.muted, isFalse);
      expect(bridge.mutes.last, isFalse);
      expect(bridge.volumes.last, closeTo(0.8, 1e-9));
    });

    test('DA249 音量为 0 时解除静音会把声音叫回来（恢复上次可听音量）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));

      // 先调到 30%（记住这一档），再拖到 0 —— 此时界面显示"没声音"但 muted=false
      await adapter.setVolume(0.3);
      await adapter.setVolume(0);
      expect(adapter.volume, 0.0);
      expect(adapter.muted, isFalse);

      await adapter.setMuted(false);

      expect(adapter.volume, closeTo(0.3, 1e-9), reason: 'DA249：要恢复上次能听见的音量');
      expect(adapter.muted, isFalse);
      expect(bridge.volumes.last, closeTo(0.3, 1e-9), reason: '恢复要真的推给原生桥');
      expect(bridge.mutes.last, isFalse);
    });

    test('DA249 静音后再解除：音量保持不变（不因为恢复逻辑被改档）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));

      await adapter.setVolume(0.65);
      await adapter.setMuted(true);
      await adapter.setMuted(false);

      expect(adapter.volume, closeTo(0.65, 1e-9));
      expect(adapter.muted, isFalse);
      expect(bridge.volumes.where((v) => v == 0), isEmpty, reason: '全程不许把音量清零');
    });

    test('音量 0 不算静音标记，但界面按 0 显示', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      await adapter.setVolume(0);
      expect(adapter.muted, isFalse);
      expect(adapter.volume, 0.0);
    });
  });

  group('画面比例', () {
    test('setAspectMode 过通道 + 状态回读', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      expect(adapter.aspectMode, MediaAspectMode.fit);

      await adapter.setAspectMode(MediaAspectMode.zoom);
      expect(bridge.aspects.last, 'zoom');
      expect(adapter.aspectMode, MediaAspectMode.zoom);

      bridge.emit({'kind': 'state', 'aspect': 'stretch'});
      await flush();
      expect(adapter.aspectMode, MediaAspectMode.stretch);

      // 重新载入时把当前比例带给原生
      await adapter.load(_source('b.mp4', uri: 'https://nas/b.mp4'));
      expect(bridge.loads.last['aspect'], 'stretch');
    });

    test('画面尺寸 → 宽高比（未知时 16:9）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      expect(adapter.aspectRatio, closeTo(16 / 9, 1e-9));
      bridge.emit({'kind': 'state', 'videoWidth': 1920, 'videoHeight': 800});
      await flush();
      expect(adapter.videoWidth, 1920);
      expect(adapter.aspectRatio, closeTo(2.4, 1e-9));
    });
  });

  group('轨道', () {
    test('事件解析音轨/字幕轨 + 选中回读', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      expect(adapter.audioTracks, isEmpty);

      bridge.emit({
        'kind': 'tracks',
        'audio': [
          _audioTrack(),
          _audioTrack(id: 'audio:0:1', language: 'eng', selected: false),
        ],
        'subtitle': [_subtitleTrack()],
      });
      await flush();
      expect(adapter.audioTracks, hasLength(2));
      expect(adapter.audioTracks.first.displayLabel, '中文');
      expect(adapter.selectedAudioTrackId, 'audio:0:0');
      expect(adapter.subtitleTracks, hasLength(1));
      expect(adapter.selectedSubtitleTrackId, 'subtitle:1:0');
    });

    test('selectAudioTrack 装配 kind/id，并乐观更新选中态', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      bridge.emit({
        'kind': 'tracks',
        'audio': [
          _audioTrack(),
          _audioTrack(id: 'audio:0:1', language: 'eng', selected: false),
        ],
        'subtitle': const [],
      });
      await flush();

      await adapter.selectAudioTrack('audio:0:1');
      expect(bridge.trackSelections.last, {'kind': 'audio', 'id': 'audio:0:1'});
      expect(adapter.selectedAudioTrackId, 'audio:0:1');
      expect(adapter.audioTracks.first.isSelected, isFalse);
      expect(adapter.audioTracks.last.isSelected, isTrue);

      await adapter.selectAudioTrack(null);
      expect(bridge.trackSelections.last, {'kind': 'audio', 'id': null});
      expect(adapter.selectedAudioTrackId, isNull);
    });

    test('selectSubtitleTrack(null) 关字幕并清掉当前文本', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      bridge.emit({
        'kind': 'tracks',
        'audio': const [],
        'subtitle': [_subtitleTrack()],
      });
      bridge.emit({'kind': 'cues', 'text': '内封字幕'});
      await flush();
      expect(adapter.embeddedSubtitleText, '内封字幕');

      await adapter.selectSubtitleTrack(null);
      expect(bridge.trackSelections.last, {'kind': 'subtitle', 'id': null});
      expect(adapter.embeddedSubtitleText, isNull);
      expect(adapter.selectedSubtitleTrackId, isNull);
    });

    test('内封字幕文本：空白 → null；切集时原生会清零', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      bridge.emit({'kind': 'cues', 'text': '  hello  '});
      await flush();
      expect(adapter.embeddedSubtitleText, 'hello');
      bridge.emit({'kind': 'cues', 'text': '   '});
      await flush();
      expect(adapter.embeddedSubtitleText, isNull);
      bridge.emit({'kind': 'cues', 'text': null});
      await flush();
      expect(adapter.embeddedSubtitleText, isNull);
    });
  });

  group('错误上报（真机 Theora 黑屏那条的真凶）', () {
    test('state.error / 流错误 → adapter.error → 具体分类', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      expect(adapter.error, isNull);

      bridge.emit({
        'kind': 'state',
        'error': 'ERROR_CODE_DECODING_FORMAT_UNSUPPORTED: unsupported format',
      });
      await flush();
      expect(
        classifyPlayerError(adapter.error),
        MediaUnavailableReason.codecUnsupported,
      );

      bridge.addError(StateError('socket closed'));
      await flush();
      expect(
        classifyPlayerError(adapter.error),
        MediaUnavailableReason.networkFailed,
      );
    });

    test('error 事件通道（kind=error）也能上报', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      bridge.emit({
        'kind': 'error',
        'message': 'Trust anchor for cert not found',
      });
      await flush();
      expect(
        classifyPlayerError(adapter.error),
        MediaUnavailableReason.certificateUntrusted,
      );
    });

    test('changes 流会在每个事件后触发（界面 setState 靠它）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      addTearDown(adapter.dispose);
      await adapter.load(_source('a.mp4'));
      var ticks = 0;
      final sub = adapter.changes.listen((_) => ticks++);
      addTearDown(sub.cancel);
      bridge.emit({'kind': 'state', 'positionMs': 1000});
      bridge.emit({'kind': 'tracks', 'audio': const [], 'subtitle': const []});
      await flush();
      expect(ticks, greaterThanOrEqualTo(2));
    });
  });

  group('dispose', () {
    test('释放原生 + 关掉 changes 流', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      await adapter.load(_source('a.mp4'));
      var closed = false;
      final sub = adapter.changes.listen((_) {}, onDone: () => closed = true);
      await adapter.dispose();
      await flush();
      expect(bridge.disposals, 1);
      expect(adapter.textureId, isNull);
      expect(closed, isTrue);
      await sub.cancel();
    });

    test('原生 dispose 抛错也不把页面卡住', () async {
      final bridge = _ThrowingDisposeBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(bridge: bridge);
      await adapter.load(_source('a.mp4'));
      await adapter.dispose();
      expect(adapter.textureId, isNull);
    });
  });

  group('MethodChannelPlayerBridge（真实的通道名/参数名）', () {
    const channel = MethodChannel(kMediaPlayerChannel);
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'create' ? 42 : null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('create 回传纹理 id；法名与 Kotlin 的 when 分支逐字对齐', () async {
      final bridge = MethodChannelPlayerBridge();
      expect(await bridge.create(), 42);
      expect(calls.single.method, 'create');
    });

    test('load 的参数名（urls/index/autoplay/volume/muted/speed/aspect）', () async {
      final bridge = MethodChannelPlayerBridge();
      await bridge.load(
        urls: ['u1', 'u2'],
        index: 1,
        autoplay: true,
        volume: 0.5,
        muted: true,
        speed: 1.25,
        aspect: 'zoom',
      );
      expect(calls.single.method, 'load');
      expect(calls.single.arguments, {
        'urls': ['u1', 'u2'],
        'index': 1,
        'autoplay': true,
        'volume': 0.5,
        'muted': true,
        'speed': 1.25,
        'aspect': 'zoom',
      });
    });

    test('其余方法名与参数', () async {
      final bridge = MethodChannelPlayerBridge();
      await bridge.play();
      await bridge.pause();
      await bridge.seekTo(1234);
      await bridge.setSpeed(2);
      await bridge.setVolume(0.25);
      await bridge.setMuted(true);
      await bridge.playNext();
      await bridge.playPrevious();
      await bridge.selectTrack(kind: 'subtitle', id: 'subtitle:0:1');
      await bridge.setAspectMode('fill');
      await bridge.dispose();
      expect(calls.map((c) => c.method).toList(), [
        'play',
        'pause',
        'seekTo',
        'setSpeed',
        'setVolume',
        'setMuted',
        'next',
        'previous',
        'selectTrack',
        'setAspectMode',
        'dispose',
      ]);
      expect(calls[2].arguments, {'positionMs': 1234});
      expect(calls[6].method, 'next');
      expect(calls[8].arguments, {'kind': 'subtitle', 'id': 'subtitle:0:1'});
      expect(calls[9].arguments, {'aspect': 'fill'});
    });

    test('create 没给 id → StateError（不静默用一个假纹理）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      final bridge = MethodChannelPlayerBridge();
      await expectLater(bridge.create(), throwsA(isA<StateError>()));
    });

    test('通道名与 Kotlin 侧常量一致', () {
      expect(kMediaPlayerChannel, 'synhub/player');
      expect(kMediaPlayerEventChannel, 'synhub/player_events');
    });
  });

  // Bug B：真机 Theora `.mkv` = `ExoPlayerImpl Init` 之后**既没有 onPlayerError
  // 也没有首帧** → 黑屏且无提示。看门狗负责把这种"起播无进展"上报成
  // `codecUnsupported`。这里用**注入的短窗口**（20–120ms）做确定性断言。
  group('起播看门狗（Bug B：无解码器不报错 → 黑屏）', () {
    /// 建一个窗口很短的适配器（默认 5s 对单测太慢）
    NativeVideoPlayerAdapter shortWatchdog(
      FakePlayerBridge bridge, {
      Duration timeout = const Duration(milliseconds: 60),
    }) => NativeVideoPlayerAdapter(
      bridge: bridge,
      watchdogTimeout: timeout,
      // R7-5 冷缓存修正：非阻塞提示判死前多一轮**确认窗口**；测试同样缩短，
      // 于是"窗口 60ms + 确认 60ms" ≈ 120ms 后才会提示（真无解码器仍会提示）。
      continuationConfirmGrace: const Duration(milliseconds: 60),
    );

    test('prepare 后无首帧、无尺寸、无错误 → 上报"疑似无解码器"', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.load(_source('theora.mkv'));
      await adapter.play();
      expect(adapter.error, isNull, reason: '窗口内不该提前报错');

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, kNoDecoderWatchdogError);
      expect(
        classifyPlayerError(adapter.error),
        MediaUnavailableReason.codecUnsupported,
        reason: '必须落到既有 codecUnsupported（复用既有面板/文案）',
      );
    });

    test('真机同形：位置已到 duration、playing=false、非 buffering 也要上报', () async {
      // 真机 theora.mkv 的显示是 `00:05/00:05`（位置/时长都 5s）且按钮是"播放"
      // —— 所以看门狗**不能**以 `playing` 或"位置没推进"作为触发前提。
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.load(_source('theora.mkv'));
      await adapter.play();
      bridge.emit({
        'kind': 'state',
        'positionMs': 5000,
        'durationMs': 5000,
        'playing': false,
        'buffering': false,
      });
      await flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, kNoDecoderWatchdogError);
    });

    test('首帧到达 → 不上报（`firstFrame` 事件）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.load(_source('clip-h264.mp4'));
      await adapter.play();
      bridge.emit({'kind': 'state', 'firstFrame': true, 'videoWidth': 160});
      await flush();

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, isNull);
    });

    test('只有视频尺寸到达 → 也不上报（老 ROM 没有 firstFrame 字段时的兜底）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.load(_source('clip-h264.mp4'));
      await adapter.play();
      bridge.emit({'kind': 'state', 'videoWidth': 1920, 'videoHeight': 1080});
      await flush();

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, isNull);
    });

    test('音频-only → 不装看门狗（本来就没有首帧）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.load(_source('tone.wav', kind: MediaKind.audio));
      await adapter.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, isNull);
    });

    test('暂停状态 → 不误伤（pause 立刻解除）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.load(_source('theora.mkv'));
      await adapter.play();
      await adapter.pause();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, isNull);

      // 重新播放 → 新窗口照常工作
      await adapter.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, kNoDecoderWatchdogError);
    });

    test('一直 buffering（慢速网络起播）→ 不误报成解码器问题', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(
        bridge,
        timeout: const Duration(milliseconds: 30),
      );
      addTearDown(adapter.dispose);

      await adapter.load(_source('theora.mkv'));
      await adapter.play();
      bridge.emit({'kind': 'state', 'buffering': true, 'playing': false});
      await flush();

      // 两轮窗口（60ms+）都还在缓冲 → 不上报
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(adapter.error, isNull, reason: '慢速起播不能被说成"编码不支持"');

      // 缓冲结束（进过 READY）后又有新窗口 → 仍然没首帧才上报
      bridge.emit({'kind': 'state', 'buffering': false});
      await flush();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(adapter.error, kNoDecoderWatchdogError);
    });

    test('用户拖动进度 → 起播窗口重新开始，不在拖动中误报', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(
        bridge,
        timeout: const Duration(milliseconds: 100),
      );
      addTearDown(adapter.dispose);

      await adapter.load(_source('theora.mkv'));
      await adapter.play();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await adapter.seekTo(const Duration(seconds: 3)); // 拖动 → 重置窗口
      // 原窗口（t=100ms）已过，但重开后的窗口还没到 → 仍不该报
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(adapter.error, isNull);
      // 重新计时后到点 → 才上报
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, kNoDecoderWatchdogError);
    });

    test('真实 onPlayerError 优先：看门狗不覆盖已有错误', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.load(_source('theora.mkv'));
      await adapter.play();
      bridge.emit({
        'kind': 'state',
        'error': 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED: socket closed',
      });
      await flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, contains('NETWORK_CONNECTION_FAILED'));
      expect(
        classifyPlayerError(adapter.error),
        MediaUnavailableReason.networkFailed,
      );
    });

    test('pump 一个正常首帧后再播下一集：换集会重置画面状态并重装看门狗', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.setPlaylist([
        _source('a.mp4', uri: 'https://nas/a.mp4'),
        _source('b.mkv', uri: 'https://nas/b.mkv'),
      ], 0);
      await adapter.play();
      bridge.emit({'kind': 'state', 'firstFrame': true, 'videoWidth': 160});
      await flush();
      expect(adapter.error, isNull);

      // 切到第二集：即使新集完全没有首帧，也应该在窗口后上报
      await adapter.playNext();
      bridge.emit({'kind': 'state', 'index': 1, 'count': 2});
      await flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, kNoDecoderWatchdogError);
    });

    // ── R4 的 P0 回归：看门狗把**能播的 H.264**也盖成「编码不支持」 ────────────
    //
    // 真机取证（决定性，见 docs/native-media-playback-research.md §10.3）：
    //   * `clip-h264.mp4` 播到 `00:04/00:05` 时，画面被渲染成 **4:3**（160×120）
    //     —— 而 `_AspectSurface` 的宽高比来自 `adapter.aspectRatio`，只有 Dart 侧
    //     真的收到 `videoWidth/videoHeight` 才会是 4:3（否则回 16:9）；
    //   * 即：`onVideoSizeChanged → emitState → _applyState → _hasVideoOutput`
    //     这条链路**是通的**，首帧/尺寸事件确实到达并解除了看门狗；
    //   * 面板出现在 `play() + ~10s`（截图 mtime：s@09:31:06 有画面 → e@09:31:13
    //     面板），而 5s 的片子 `play() + 5s` 就播完了 —— 说明面板是**播完之后**
    //     才出现的：Books 目录的播放列表是 `[clip-h264.mp4, theora.mkv]`
    //     （真机上一个可用/一个禁用证明了顺序），Media3 在片尾**自动续播**
    //     `theora.mkv`，原生 `onMediaItemTransition` 把尺寸/首帧清零，
    //     Dart 的 index 分支又重装了看门狗 → 下一条没解码器 → 面板挂在
    //     **上一条的名字**（页面 source 仍是 clip-h264.mp4）下面。
    test('播放列表**自动**播下一条 → 不给致命 error，只给非阻塞提示（H.264 不会被下一条拖累）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.setPlaylist([
        _source('clip-h264.mp4', uri: 'https://nas/clip-h264.mp4'),
        _source('theora.mkv', uri: 'https://nas/theora.mkv'),
      ], 0);
      await adapter.play();
      // 真的出过画面（尺寸 + 首帧都到）
      bridge.emit({
        'kind': 'state',
        'positionMs': 100,
        'videoWidth': 160,
        'videoHeight': 120,
        'firstFrame': true,
      });
      await flush();
      expect(adapter.error, isNull);

      // 片尾自动续播：原生清尺寸/首帧 + index 变成 1；新的一条原地不动
      // （没有首帧、没有尺寸、位置也不推进 —— 若这里被重装了看门狗就会误报）
      bridge.emit({
        'kind': 'state',
        'positionMs': 0,
        'durationMs': 5000,
        'firstFrame': false,
        'videoWidth': 0,
        'videoHeight': 0,
        'index': 1,
        'count': 2,
      });
      await flush();

      // R7-5 冷缓存修正：窗口（60ms）到点后先进**确认窗口**（再 60ms），
      // 未确认前**不许**提示 —— 冷缓存的下一条首帧常比第一个窗口晚到，
      // 那一刻就报会变成"已出画却还提示"。
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        adapter.hasNoPictureContinuationNotice,
        isFalse,
        reason: '确认窗口内先不下结论（R7-5 冷缓存误报修正）',
      );

      await Future<void>.delayed(const Duration(milliseconds: 220));
      // R5 之后：自动续播**不再完全静默** —— 照样装表取证，但结果降级成
      // **非阻塞**提示（`hasNoPictureContinuationNotice`）；致命 `error` 仍然不给
      // （那会把上一条明明能播的 H.264 误伤成"编码不支持"）。
      expect(adapter.error, isNull, reason: '自动换集不许给下一条致命 error');
      expect(
        adapter.hasNoPictureContinuationNotice,
        isTrue,
        reason: 'R5/R7-11：自动续播 + 确认后仍零画面证据必须给非阻塞提示，不能静默黑屏',
      );
    });

    test('冷缓存：确认窗口内首帧到了 → 从头到尾不提示（R7-5 误报修正）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.setPlaylist([
        _source('clip-h264.mp4', uri: 'https://nas/clip-h264.mp4'),
        _source('cold-cache.mp4', uri: 'https://nas/cold-cache.mp4'),
      ], 0);
      await adapter.play();
      bridge.emit({
        'kind': 'state',
        'positionMs': 100,
        'videoWidth': 160,
        'videoHeight': 120,
        'firstFrame': true,
      });
      await flush();

      // 自动续播到冷缓存的下一条：第一个窗口（60ms）内没有任何画面证据
      bridge.emit({
        'kind': 'state',
        'positionMs': 0,
        'durationMs': 5000,
        'firstFrame': false,
        'videoWidth': 0,
        'videoHeight': 0,
        'index': 1,
        'count': 2,
      });
      await flush();

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(adapter.hasNoPictureContinuationNotice, isFalse);
      // 确认窗口内首帧终于到了（冷缓存跑次的真实形态）
      bridge.emit({'kind': 'state', 'firstFrame': true, 'videoWidth': 160});
      await flush();

      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(
        adapter.hasNoPictureContinuationNotice,
        isFalse,
        reason: '已出画绝不能误报"自动续播无画面"',
      );
      expect(adapter.error, isNull);
    });

    test('r438 DA92：本条**没有视频轨**（原生 tracks 明说 videoCount=0）⇒ 不许等它播到结尾才提示', () async {
      // r438 真机现场：本条 = **只有音轨**的 `.mp4`（30 s）自动续播进来 ⇒ 顶栏已经是新条目、
      // 屏上却一直挂着**上一条的残帧**，而**一条提示都没有** —— 因为 `_onWatchdogTimeout`
      // 的既有取舍是"时钟在推、还没到结尾 ⇒ 再看一轮"（那是为了不误伤慢起播的真视频）。
      // 但"本条根本没有视频轨"是**确定的事实**（原生 `onTracksChanged` 就能说），
      // 不是"还没等到"⇒ 必须当轮定性，不能等到 30 s 播完（用户会以为播错了东西）。
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.setPlaylist([
        _source('clip-h264.mp4', uri: 'https://nas/clip-h264.mp4'),
        _source('silent30.mp4', uri: 'https://nas/silent30.mp4'),
      ], 0);
      await adapter.play();
      bridge.emit({
        'kind': 'state',
        'positionMs': 100,
        'videoWidth': 160,
        'videoHeight': 120,
        'firstFrame': true,
      });
      await flush();

      // 片尾自动续播到"只有音轨"的下一条：原生清尺寸/首帧 + index 变化
      bridge.emit({
        'kind': 'state',
        'positionMs': 0,
        'durationMs': 30000,
        'firstFrame': false,
        'videoWidth': 0,
        'videoHeight': 0,
        'index': 1,
        'count': 2,
      });
      await flush();
      // ★ 原生 tracks：**本条没有视频轨**（`videoCount = 0`，带条目下标）
      bridge.emit({
        'kind': 'tracks',
        'videoCount': 0,
        'index': 1,
        'audio': [_audioTrack()],
        'subtitle': <Object?>[],
      });
      await flush();
      // 时钟在推（音频在响）、远没到结尾 —— 这正是旧逻辑"再看一轮"的情形
      bridge.emit({
        'kind': 'state',
        'positionMs': 2000,
        'durationMs': 30000,
        'playing': true,
        'buffering': false,
        'index': 1,
        'count': 2,
      });
      await flush();

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        adapter.hasNoPictureContinuationNotice,
        isTrue,
        reason: '本条没有视频轨是**确定事实** ⇒ 必须当轮给非阻塞提示（不许等 30 s 播完）',
      );
      expect(adapter.error, isNull, reason: '自动续播仍不许给下一条致命 error');

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        adapter.hasNoPictureContinuationNotice,
        isTrue,
        reason: '提示是"非阻塞"的，别过一会儿又自己退掉',
      );
    });

    test('r438 DA92 兼容/反误伤：有视频轨的推进长片，tracks 到过也不许提示', () async {
      // 反向：`videoCount = 1`（本条**有**视频轨，只是还没出帧/还没到结尾）
      // ⇒ 必须保持既有取舍（宁可漏报也不误伤能解码的文件）。
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.setPlaylist([
        _source('clip-h264.mp4', uri: 'https://nas/clip-h264.mp4'),
        _source('slow.mp4', uri: 'https://nas/slow.mp4'),
      ], 0);
      await adapter.play();
      bridge.emit({
        'kind': 'state',
        'positionMs': 0,
        'durationMs': 60000,
        'index': 1,
        'count': 2,
      });
      await flush();
      bridge.emit({
        'kind': 'tracks',
        'videoCount': 1,
        'index': 1,
        'audio': [_audioTrack()],
        'subtitle': <Object?>[],
      });
      await flush();
      bridge.emit({
        'kind': 'state',
        'positionMs': 2000,
        'durationMs': 60000,
        'playing': true,
        'buffering': false,
        'index': 1,
        'count': 2,
      });
      await flush();

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        adapter.hasNoPictureContinuationNotice,
        isFalse,
        reason: '有视频轨 ⇒ 属于"还没出帧"，既有取舍保持（不提示）',
      );
      expect(adapter.error, isNull);
    });

    test('用户主动点"下一个"到坏文件 → 仍然会上报（自动换集 ≠ 用户换集）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.setPlaylist([
        _source('clip-h264.mp4', uri: 'https://nas/clip-h264.mp4'),
        _source('theora.mkv', uri: 'https://nas/theora.mkv'),
      ], 0);
      await adapter.play();
      bridge.emit({'kind': 'state', 'firstFrame': true, 'videoWidth': 160});
      await flush();
      expect(adapter.error, isNull);

      await adapter.playNext();
      bridge.emit({
        'kind': 'state',
        'positionMs': 0,
        'durationMs': 5000,
        'index': 1,
        'count': 2,
      });
      await flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, kNoDecoderWatchdogError, reason: '用户主动切的集必须照旧受保护');
    });

    test('位置在窗口内推进且文件没放完 → 前 3 个窗口不误报（r675 `DA303` 起有界）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(
        bridge,
        timeout: const Duration(milliseconds: 40),
      );
      addTearDown(adapter.dispose);

      await adapter.load(_source('clip-h264.mp4'));
      await adapter.play();
      // 60s 的长片：窗口到点时位置才走到 2s，远没到结尾
      bridge.emit({
        'kind': 'state',
        'positionMs': 2000,
        'durationMs': 60000,
        'playing': true,
        'buffering': false,
      });
      await flush();
      // 第 1–2 个窗口（40ms × 2 ≈ 100ms）：慢起播 / 某 ROM 不回调首帧的宽限期内
      // **不许**判死（老行为在这里是对的）。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(adapter.error, isNull,
          reason: '前两个窗口不许误报（时钟在推进 + 文件没放完）');
      // ★ r675（`DA303`）：宽限**有界** —— iOS 上 mkv/avi 是"音频在放、画面永远
      //   没有"，位置会一路推到片尾；无限宽限 = 用户对着黑屏+声音等到放弃。
      //   3 个窗口（这里 40ms×3 = 120ms）之后必须判死。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, isNotNull,
          reason: '★ DA303：位置一直在推也必须判死（否则永远黑屏）');
    });

    test('时钟走完一整条却零画面证据 → 必须上报（真机 Theora 的 `00:04/00:05` 形态）', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.load(_source('theora.mkv'));
      await adapter.play();
      // 真机截图：theora.mkv 的时钟**照样**从 0 走到 4s/5s，按钮还是"暂停"，
      // 但没有任何尺寸/首帧 —— 这种"走完仍无画面"必须判死
      bridge.emit({
        'kind': 'state',
        'positionMs': 4000,
        'durationMs': 5000,
        'playing': true,
        'buffering': false,
        'videoWidth': 0,
        'videoHeight': 0,
        'firstFrame': false,
      });
      await flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(adapter.error, kNoDecoderWatchdogError);
    });

    // ── ★ r437 `DA91`：画面证据必须**归属到具体条目**，状态事件必须**保序** ──────
    //
    // 同一个根因的两个方向（证据是"全局布尔"：没有条目身份、也没有事件序号）：
    //   * 旧条目的证据**晚到** ⇒ 被当成新条目的证据 ⇒ 新条目真没解码器也**不提示**（漏报黑屏）；
    //   * 新条目的证据被**晚到的** transition 事件清掉且不会再来 ⇒ 画面在播却挂"播不了"（r431 现场）。
    test('r437 DA91：旧条目晚到的事件不许把下标改回去，也不许顶替新条目的画面证据', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.setPlaylist([
        _source('ok-h264.mp4', uri: 'https://nas/ok-h264.mp4'),
        _source('theora.mkv', uri: 'https://nas/theora.mkv'),
      ], 0);
      await adapter.play();
      // 第 0 条：真的出过画（序号 10，"证据属于下标 0"）
      bridge.emit({
        'kind': 'state',
        'seq': 10,
        'index': 0,
        'count': 2,
        'positionMs': 100,
        'videoWidth': 160,
        'videoHeight': 120,
        'firstFrame': true,
        'firstFrameIndex': 0,
        'sizeIndex': 0,
      });
      await flush();
      // 片尾自动续播到第 1 条（序号 11）：本条没有任何画面证据
      bridge.emit({
        'kind': 'state',
        'seq': 11,
        'index': 1,
        'count': 2,
        'positionMs': 0,
        'durationMs': 5000,
        'firstFrame': false,
        'videoWidth': 0,
        'videoHeight': 0,
      });
      await flush();
      // ★ 第 0 条的**最后一拍晚到**了（序号 9 < 11）：下标 0、内容是"有画面"
      bridge.emit({
        'kind': 'state',
        'seq': 9,
        'index': 0,
        'count': 2,
        'positionMs': 4900,
        'durationMs': 5000,
        'firstFrame': true,
        'videoWidth': 160,
        'videoHeight': 120,
        'firstFrameIndex': 0,
        'sizeIndex': 0,
      });
      await flush();

      await Future<void>.delayed(const Duration(milliseconds: 260));
      expect(adapter.error, isNull, reason: '自动续播不许给下一条致命 error');
      expect(
        adapter.hasNoPictureContinuationNotice,
        isTrue,
        reason: '第 1 条自己零画面证据 ⇒ 必须提示；乱序事件不许改回下标、也不许顶替证据',
      );
    });

    test('r437 DA91：证据带的下标 ≠ 当前条目 ⇒ 不算"出了画面"', () async {
      final bridge = FakePlayerBridge();
      addTearDown(bridge.close);
      final adapter = shortWatchdog(bridge);
      addTearDown(adapter.dispose);

      await adapter.setPlaylist([
        _source('ok-h264.mp4', uri: 'https://nas/ok-h264.mp4'),
        _source('theora.mkv', uri: 'https://nas/theora.mkv'),
      ], 0);
      await adapter.play();
      bridge.emit({
        'kind': 'state',
        'seq': 10,
        'index': 0,
        'count': 2,
        'positionMs': 100,
        'videoWidth': 160,
        'videoHeight': 120,
        'firstFrame': true,
        'firstFrameIndex': 0,
        'sizeIndex': 0,
      });
      await flush();
      // 换到第 1 条，但这一拍里的"首帧/尺寸"证据是**第 0 条**留下的
      bridge.emit({
        'kind': 'state',
        'seq': 11,
        'index': 1,
        'count': 2,
        'positionMs': 0,
        'durationMs': 5000,
        'firstFrame': true,
        'videoWidth': 160,
        'videoHeight': 120,
        'firstFrameIndex': 0,
        'sizeIndex': 0,
      });
      await flush();

      await Future<void>.delayed(const Duration(milliseconds: 260));
      expect(
        adapter.hasNoPictureContinuationNotice,
        isTrue,
        reason: '证据下标 0 ≠ 当前条目 1 ⇒ 第 1 条仍然零画面证据，必须提示',
      );
    });

    test('错误串刻意无数字：不会被误分类成会话/网络', () {
      for (final token in ['119', '401', '403', 'session', 'network', 'io_']) {
        expect(
          kNoDecoderWatchdogError.toLowerCase().contains(token),
          isFalse,
          reason: '不能让分类器把看门狗错误认成 $token',
        );
      }
      expect(
        classifyPlayerError(kNoDecoderWatchdogError),
        MediaUnavailableReason.codecUnsupported,
      );
    });

    test('默认窗口就是 4–6s（上线阈值）', () {
      expect(kMediaWatchdogTimeout, const Duration(seconds: 5));
      final adapter = NativeVideoPlayerAdapter();
      addTearDown(adapter.dispose);
      expect(adapter.watchdogTimeout, kMediaWatchdogTimeout);
    });
  });

  // ★ 第 296 轮（P2-3）：macOS 上**明确**走 `video_player` 分支，
  // 不去碰 `synhub/player`（自研 AVPlayer 桥已实现，但没在真 NAS 上验证播放前
  // 不默认启用）。开关打开时切回自研桥。
  group('平台默认适配器分支', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      MediaTlsPolicy.macosNativePlayerEnabled =
          MediaTlsPolicy.macosNativePlayerFromEnv;
      MediaTlsPolicy.iosNativePlayerEnabled =
          MediaTlsPolicy.iosNativePlayerFromEnv;
    });

    test('Android → 自研桥（r655 起外面包一层「拿不动就换 libmpv」的策略层）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final adapter = createDefaultMediaPlayerAdapter();
      // r655 `DA262`：Android 的主引擎仍是自研 Media3 桥，但外面套了
      // `FallbackPlayerAdapter`（音轨全不支持 / 起播被判"解不了"时换 libmpv）。
      // 断言落到**内层**而不是只断类型：包装层必须真的把原生桥包在里面。
      expect(adapter, isA<FallbackPlayerAdapter>());
      expect(
        (adapter as FallbackPlayerAdapter).activeAdapter,
        isA<NativeVideoPlayerAdapter>(),
      );
    });

    test('macOS 默认 → video_player（不尝试 synhub/player）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      MediaTlsPolicy.macosNativePlayerEnabled = false;
      expect(createDefaultMediaPlayerAdapter(), isA<VideoPlayerAdapter>());
    });

    test('macOS + 开关打开 → 自研桥（供真 NAS 验证后切换）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      MediaTlsPolicy.macosNativePlayerEnabled = true;
      expect(createDefaultMediaPlayerAdapter(), isA<NativeVideoPlayerAdapter>());
    });

    // ★ 第 92 轮 iOS 迁移：与 macOS 用同一份 Swift 桥 ⇒ 默认也走自研桥；
    // 并且**反向验证**"开关关掉必须回退插件"（证明这条分支不是恒真）。
    // ★ r678（`DA311`）：iOS 也包一层 libmpv 兜底 —— `.mkv` 在 AVFoundation 上
    // 是 `-11828`（容器解不开），只有兜底引擎能真播。断言落到**内层**：
    // 主引擎仍必须是原生桥（mp4/H.264 那条更省、能力更全），不是直接上 mpv。
    test('iOS 默认 → 自研桥 ＋ 「解不了就换 libmpv」策略层', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(MediaTlsPolicy.iosNativePlayerFromEnv, isTrue);
      final adapter = createDefaultMediaPlayerAdapter();
      expect(adapter, isA<FallbackPlayerAdapter>());
      expect(
        (adapter as FallbackPlayerAdapter).activeAdapter,
        isA<NativeVideoPlayerAdapter>(),
      );
    });

    test('iOS + 开关关闭 → 回退 video_player（反向验证，分支不是恒真）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      MediaTlsPolicy.iosNativePlayerEnabled = false;
      expect(createDefaultMediaPlayerAdapter(), isA<VideoPlayerAdapter>());
    });

    // ★ r703：Windows 并入 Linux 这一型 —— `video_player` 在 Windows 上**没有**
    //   实现（插件列里没有 `video_player_windows`），`media_kit_libs_windows_video`
    //   随包带 libmpv ⇒ 直接走同一条 libmpv 引擎。反向断言钉住"不是 video_player"。
    test('Windows → libmpv 分支（构造即要 MediaKit；video_player 分支不碰原生库）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      // 为什么不断言 `isA<MpvPlayerAdapter>()`：`MpvPlayerAdapter` 的构造函数
      // 立刻 `Player()`，而 media_kit 的 `Player` 要求**先**
      // `MediaKit.ensureInitialized()`（真机由 `lib/main.dart` 在 `runApp` 前做，
      // 单测进程里没有 libmpv）。所以判据落在"它在**造 libmpv 引擎**"这件事上：
      // 抛的一定是 media_kit 的未初始化错误；`VideoPlayerAdapter` 分支不碰原生库，
      // 永远不会抛这个 ⇒ 这条反向断言能区分两个分支。
      expect(
        () => createDefaultMediaPlayerAdapter(),
        throwsA(
          predicate(
            (e) => '$e'.contains('MediaKit.ensureInitialized'),
            '抛 media_kit 未初始化（说明确实走了 libmpv 分支）',
          ),
        ),
      );
      // 反向：换成 fuchsia（没有 libmpv 分支）⇒ 不抛，拿到 video_player。
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      expect(createDefaultMediaPlayerAdapter(), isA<VideoPlayerAdapter>());
    });


  });
}

/// dispose 抛错的桥（测清理路径不把页面卡住）
class _ThrowingDisposeBridge extends FakePlayerBridge {
  @override
  Future<void> dispose() async => throw StateError('channel gone');
}
