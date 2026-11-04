// 共用的假播放器：`AudioStationPlayer` 的最小可观测实现。
//
// 从 `test/audio_mini_player_test.dart` 提出来（r653 · `DA257`），
// 让"迷你条"与"点通知回播放页"两组用例吃**同一个**假引擎 ——
// 免得两个文件各写一份，改一处忘一处。
//
// 判据是**计数器**（`plays` / `pauses` / `stops`）＋ `changes` 流：
// 用户按下的动作到底有没有打到引擎，看这里，不看 UI 长得像不像。
import 'dart:async';

import 'package:synhub/src/features/audio/audio_player.dart';

class FakeAudioStationPlayer implements AudioStationPlayer {
  int pauses = 0;
  int plays = 0;
  int stops = 0;
  bool _playing = false;
  String? _current;
  int _index = -1;
  List<AudioQueueEntry> _queue = const [];
  final _changes = StreamController<void>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();

  @override
  String? get currentUrl => _current;
  @override
  bool get playing => _playing;
  @override
  int get currentIndex => _index;
  @override
  int get queueLength => _queue.length;
  @override
  List<AudioQueueEntry> get queue => _queue;
  @override
  bool get shuffleEnabled => false;
  @override
  AudioRepeatMode get repeatMode => AudioRepeatMode.off;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => null;
  @override
  Stream<void> get changes => _changes.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;

  @override
  Future<void> play(String url) =>
      playQueue([AudioQueueEntry(id: url, url: url)]);

  @override
  Future<void> playQueue(
    List<AudioQueueEntry> entries, {
    int startIndex = 0,
  }) async {
    if (entries.isEmpty) return;
    _queue = entries;
    _index = startIndex.clamp(0, entries.length - 1);
    _current = entries[_index].url;
    _playing = true;
    plays++;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    pauses++;
    _playing = false;
    _changes.add(null);
  }

  @override
  Future<void> resume() async {
    plays++;
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> stop() async {
    stops++;
    _playing = false;
    _current = null;
    _queue = const [];
    _index = -1;
    _changes.add(null);
  }

  @override
  Future<void> next() async {}
  @override
  Future<void> previous() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setShuffle(bool enabled) async {}
  @override
  Future<void> setRepeat(AudioRepeatMode mode) async {}
}
