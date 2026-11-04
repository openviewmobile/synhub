// Audio 后台播放 / 通知栏 / 锁屏 / 耳机按键（P0-3）的**离线**验证。
//
// ⚠️ 边界（方案 §4）：`AudioService.init` 背后的**平台运行时行为**（媒体会话是否
// 建立、熄屏是否停播、通知栏/锁屏控件、耳机按键、前台服务）在**没有真机**的
// 离线测试里**测不到** —— 那些一律记为"待真机验证 V1–V7"，本文件**不**声称
// 已验证。这里能钉死的是：handler 的**桥接语义**（状态发布 / 元数据 / 队列下标 /
// 打断 / 会话续期）与"页面只认 handler"这条接线。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/media/media_source.dart'
    show MediaUnavailableReason, kMediaSessionRenewMaxAttempts;

/// 假引擎：覆盖 [AudioStationPlayer] + [AudioEngineExtras]。
///
/// 与 `test/audio_page_test.dart` 的 `_FakePlayer` 同源，额外补上
/// `errors` / `bufferedPosition`（后台 handler 需要它们）。
class _FakeEngine implements AudioStationPlayer, AudioEngineExtras {
  final played = <String>[];
  final playedQueues = <List<AudioQueueEntry>>[];
  final seeks = <Duration>[];
  final _changes = StreamController<void>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  bool _playing = false;
  String? _current;
  int _index = -1;
  List<AudioQueueEntry> _queue = const [];
  bool _shuffle = false;
  AudioRepeatMode _repeat = AudioRepeatMode.off;
  Duration _pos = Duration.zero;
  Duration _buffered = Duration.zero;
  Duration? _dur;

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
  bool get shuffleEnabled => _shuffle;

  @override
  AudioRepeatMode get repeatMode => _repeat;

  @override
  Duration get position => _pos;

  @override
  Duration? get duration => _dur;

  @override
  Duration get bufferedPosition => _buffered;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration?> get durationStream => _duration.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  void emitPosition(Duration d) {
    _pos = d;
    _position.add(d);
  }

  void emitDuration(Duration? d) {
    _dur = d;
    _duration.add(d);
  }

  void emitBuffered(Duration d) {
    _buffered = d;
    _changes.add(null);
  }

  void emitError(Object error) => _errors.add(error);

  @override
  Future<void> play(String url) =>
      playQueue([AudioQueueEntry(id: url, url: url)]);

  @override
  Future<void> playQueue(
    List<AudioQueueEntry> entries, {
    int startIndex = 0,
  }) async {
    if (entries.isEmpty) return;
    playedQueues.add(entries);
    _queue = entries;
    _index = startIndex.clamp(0, entries.length - 1);
    _current = entries[_index].url;
    played.add(_current!);
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _changes.add(null);
  }

  @override
  Future<void> resume() async {
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _current = null;
    _index = -1;
    _changes.add(null);
  }

  @override
  Future<void> next() async {
    if (_queue.isEmpty) return;
    _index = (_index + 1).clamp(0, _queue.length - 1);
    _current = _queue[_index].url;
    played.add(_current!);
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> previous() async {
    if (_queue.isEmpty) return;
    _index = (_index - 1).clamp(0, _queue.length - 1);
    _current = _queue[_index].url;
    played.add(_current!);
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    emitPosition(position);
  }

  @override
  Future<void> setShuffle(bool enabled) async {
    _shuffle = enabled;
    _changes.add(null);
  }

  @override
  Future<void> setRepeat(AudioRepeatMode mode) async {
    _repeat = mode;
    _changes.add(null);
  }

  @override
  Future<void> dispose() async {
    await _changes.close();
    await _position.close();
    await _duration.close();
    await _errors.close();
  }
}

/// 假封面缓存：记录收到的字节；[next] 为 null 时模拟"拿不到本地目录"。
class _FakeArtwork implements AudioArtworkCache {
  final stored = <Uint8List>[];
  Uri? next;

  @override
  Future<Uri?> store(Uint8List bytes) async {
    stored.add(bytes);
    return next;
  }

  @override
  Future<void> dispose() async {}
}

/// 假音频焦点：测试里手动喂"打断 / 拔耳机"事件。
class _FakeFocus implements AudioFocusController {
  final _interruptions = StreamController<bool>.broadcast();
  final _noisy = StreamController<void>.broadcast();
  bool activated = false;

  @override
  Future<void> activate() async {
    activated = true;
  }

  @override
  Stream<bool> get interruptions => _interruptions.stream;

  @override
  Stream<void> get becomingNoisy => _noisy.stream;

  void interrupt(bool begin) => _interruptions.add(begin);

  void unplug() => _noisy.add(null);

  @override
  Future<void> dispose() async {
    await _interruptions.close();
    await _noisy.close();
  }
}

AudioTrackInfo _track(
  String id, {
  String title = 't',
  String artist = '',
  String url = '',
  Duration? duration,
  Uint8List? cover,
  AudioTrackKind kind = AudioTrackKind.song,
}) => AudioTrackInfo(
  id: id,
  url: url.isEmpty
      ? 'http://nas/webapi/AudioStation/stream.cgi/0.mp3?_sid=S-$id'
      : url,
  title: title,
  artist: artist,
  duration: duration,
  coverBytes: cover,
  kind: kind,
);

({SynologyAudioHandler handler, _FakeEngine engine, _FakeFocus focus})
_harness({_FakeArtwork? artwork}) {
  final engine = _FakeEngine();
  final focus = _FakeFocus();
  final handler = SynologyAudioHandler(
    player: engine,
    focus: focus,
    artwork: artwork ?? _FakeArtwork(),
    // 测试里退避为 0，避免真等 500ms
    renewer: AudioSessionRenewer(delayOf: (_) => Duration.zero),
  );
  addTearDown(handler.dispose);
  return (handler: handler, engine: engine, focus: focus);
}

void main() {
  group('handler 桥接：playbackState（playing/位置/缓冲/速度/队列下标）', () {
    test(
      '起播 + 位置推进 → playbackState 上报 position/buffered/speed/queueIndex',
      () async {
        final h = _harness();
        await h.handler.startQueue([
          _track('m1', title: 'a'),
          _track('m2', title: 'b'),
        ], startIndex: 1);
        await pumpEventQueue();

        expect(h.handler.playbackState.value.playing, isTrue);
        expect(h.handler.playbackState.value.queueIndex, 1);
        expect(h.handler.playbackState.value.speed, 1.0);

        // 位置跨过 1 秒的整数格才广播（不是每 200ms 推一次平台通道）
        h.engine.emitPosition(const Duration(seconds: 30));
        await pumpEventQueue();
        expect(
          h.handler.playbackState.value.updatePosition,
          const Duration(seconds: 30),
        );

        h.engine.emitBuffered(const Duration(seconds: 45));
        await pumpEventQueue();
        expect(
          h.handler.playbackState.value.bufferedPosition,
          const Duration(seconds: 45),
        );
      },
    );

    test('系统回调 play/pause/seek/stop 落到引擎并同步 playbackState', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1')]);
      await pumpEventQueue();
      expect(h.engine.playing, isTrue);

      await h.handler.pause();
      await pumpEventQueue();
      expect(h.engine.playing, isFalse);
      expect(h.handler.playbackState.value.playing, isFalse);

      await h.handler.play();
      await pumpEventQueue();
      expect(h.engine.playing, isTrue);

      await h.handler.seek(const Duration(seconds: 12));
      expect(h.engine.seeks.last, const Duration(seconds: 12));
      expect(
        h.handler.playbackState.value.updatePosition,
        const Duration(seconds: 12),
      );

      await h.handler.stop();
      await pumpEventQueue();
      expect(h.engine.playing, isFalse);
      expect(
        h.handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // ★ r653（**DA255**）：通知栏上的**按钮**（人视角）
  //
  // 真机缺口：buttons 的 label 恒为英文（`Previous`/`Pause`/`Next`），
  // 读屏/车机会念英文；而且第四个键是 `stop`（音乐 App 上罕见动作占了位置）。
  // 这里钉住：三个键、顺序固定、标签走 l10n、暂停后变「播放」。
  // ════════════════════════════════════════════════════════════════════
  // ★ r653（**DA258**）：通知栏的**副标题**也要说人话
  //
  // 真机现场（`docs/evidence-r653/10_radio_notification.png`）：电台在播，
  // 通知栏副标题写着 `MP3 (192 kbps)` —— 而迷你条与播放面板早就清洗成「正在播放」。
  // 同一个东西两处两种读数。
  // ════════════════════════════════════════════════════════════════════
  group('DA258 通知栏副标题：电台不许印编码串', () {
    test('纯技术串 → 副标题是「正在播放」', () async {
      final h = _harness();
      await h.handler.startQueue([
        _track(
          'radio_blues',
          title: 'Blues Radio',
          artist: 'MP3 (192 kbps)',
          kind: AudioTrackKind.radio,
        ),
      ]);
      await pumpEventQueue();
      expect(h.handler.mediaItem.value?.artist, '正在播放');
      expect(
        h.handler.mediaItem.value?.artist ?? '',
        isNot(contains('kbps')),
        reason: '通知栏/锁屏会把副标题直接印出来，技术串不进这里',
      );
    });

    test('有人话就留人话（只摘技术）', () async {
      final h = _harness();
      await h.handler.startQueue([
        _track(
          'radio_jazz',
          title: 'Jazz 24/7',
          artist: 'Jazz 24/7 · MP3 (192 kbps)',
          kind: AudioTrackKind.radio,
        ),
      ]);
      await pumpEventQueue();
      final artist = h.handler.mediaItem.value?.artist ?? '';
      expect(artist, contains('Jazz 24/7'));
      expect(artist, isNot(contains('kbps')));
    });

    test('歌曲不受影响（artist 本来就是人话）', () async {
      final h = _harness();
      await h.handler.startQueue([
        _track('m1', title: 'Demo Song', artist: 'Demo Artist'),
      ]);
      await pumpEventQueue();
      expect(h.handler.mediaItem.value?.artist, 'Demo Artist');
    });
  });

  group('DA255 通知栏按钮：三个键 + 本地化标签', () {
    test('播放中：上一首 / 暂停 / 下一首，没有 stop', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1'), _track('m2')]);
      await pumpEventQueue();
      final controls = h.handler.playbackState.value.controls;
      expect(
        controls.map((c) => c.action).toList(),
        [MediaAction.skipToPrevious, MediaAction.pause, MediaAction.skipToNext],
      );
      expect(
        controls.map((c) => c.label).toList(),
        ['上一首', '暂停', '下一首'],
        reason: '读屏/车机会念这个标签，中文环境不许念英文',
      );
      expect(
        controls.any((c) => c.action == MediaAction.stop),
        isFalse,
        reason: '「停止」不该占通知栏一个位置（暂停后划走即可）',
      );
    });

    test('暂停后中间键变「播放」', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1')]);
      await pumpEventQueue();
      await h.handler.pause();
      await pumpEventQueue();
      final controls = h.handler.playbackState.value.controls;
      expect(controls[1].action, MediaAction.play);
      expect(controls[1].label, '播放');
    });

    test('紧凑视图仍然只取前三个（索引都有效）', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1')]);
      await pumpEventQueue();
      final state = h.handler.playbackState.value;
      expect(state.androidCompactActionIndices, [0, 1, 2]);
      expect(state.controls.length, greaterThanOrEqualTo(3));
    });
  });

  group('handler 桥接：mediaItem（标题/歌手/时长/封面 URI）与 queue', () {
    test('mediaItem 带标题/歌手/时长/内嵌封面 URI；绝不把 _sid 交给媒体会话', () async {
      final artwork = _FakeArtwork()..next = Uri.parse('file:///tmp/cover.img');
      final h = _harness(artwork: artwork);
      await h.handler.startQueue([
        _track(
          'm1',
          title: '示例歌曲',
          artist: '示例歌手',
          duration: const Duration(seconds: 227),
          cover: Uint8List.fromList([1, 2, 3, 4]),
          url: 'http://nas/webapi/AudioStation/stream.cgi/0.mp3?_sid=SECRET',
        ),
      ]);
      await pumpEventQueue();

      final item = h.handler.mediaItem.value!;
      expect(item.title, '示例歌曲');
      expect(item.artist, '示例歌手');
      expect(item.duration, const Duration(seconds: 227));
      expect(item.artUri, Uri.parse('file:///tmp/cover.img'));
      expect(artwork.stored.single, [1, 2, 3, 4]);
      // 凭据只活在引擎 URL 里，不进 MediaItem（否则会随媒体会话广播出去）
      // ★ r633：`extras` 不再是 null —— Producer 起会带 `{'kind': 'song'|'radio'}`，
      //   让"迷你条/播放条点开进哪个播放器"不用按 id 前缀猜（DA215）。
      //   判据因此改成"**只许有 kind**、而且绝不含凭据"。
      expect(item.extras, {'kind': 'song'});
      expect(item.toString().contains('_sid'), isFalse);
      expect(item.toString().contains('SECRET'), isFalse);

      expect(h.handler.queue.value.map((e) => e.id).toList(), ['m1']);
    });

    test('没有内嵌封面 → 不给 artUri（不联网取图，如实降级）', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1', title: 'a')]);
      await pumpEventQueue();
      expect(h.handler.mediaItem.value!.artUri, isNull);
    });

    test('本地目录拿不到（封面写不出去）→ artUri null，但播放照常', () async {
      final artwork = _FakeArtwork()..next = null; // store 返回 null
      final h = _harness(artwork: artwork);
      await h.handler.startQueue([
        _track('m1', cover: Uint8List.fromList([9, 9])),
      ]);
      await pumpEventQueue();
      expect(h.engine.playing, isTrue);
      expect(h.handler.mediaItem.value!.artUri, isNull);
    });
  });

  group('handler 桥接：队列下标（通知栏/耳机"下一首/上一首"）', () {
    test(
      'skipToNext / skipToPrevious 让 queueIndex 与 mediaItem 跟着队列走',
      () async {
        final h = _harness();
        await h.handler.startQueue([
          _track('m1', title: 'a'),
          _track('m2', title: 'b'),
          _track('m3', title: 'c'),
        ], startIndex: 0);
        await pumpEventQueue();
        expect(h.handler.playbackState.value.queueIndex, 0);

        await h.handler.skipToNext();
        await pumpEventQueue();
        expect(h.engine.currentIndex, 1);
        expect(h.handler.playbackState.value.queueIndex, 1);
        expect(h.handler.mediaItem.value!.id, 'm2');
        expect(h.handler.mediaItem.value!.title, 'b');

        await h.handler.skipToNext();
        await pumpEventQueue();
        expect(h.handler.playbackState.value.queueIndex, 2);

        await h.handler.skipToPrevious();
        await pumpEventQueue();
        expect(h.handler.playbackState.value.queueIndex, 1);
      },
    );
  });

  group('音频焦点 / 打断', () {
    test('来电/其它 App 抢占 → 暂停；打断结束 → 恢复', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1')]);
      await pumpEventQueue();
      expect(h.engine.playing, isTrue);

      h.focus.interrupt(true);
      await pumpEventQueue();
      expect(h.engine.playing, isFalse);
      expect(h.handler.playbackState.value.playing, isFalse);

      h.focus.interrupt(false);
      await pumpEventQueue();
      expect(h.engine.playing, isTrue);
    });

    test('拔耳机（becomingNoisy）→ 暂停且**不**自动恢复', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1')]);
      await pumpEventQueue();

      h.focus.unplug();
      await pumpEventQueue();
      expect(h.engine.playing, isFalse);

      // 即使随后收到"打断结束"，也不许自动外放
      h.focus.interrupt(false);
      await pumpEventQueue();
      expect(h.engine.playing, isFalse);
    });
  });

  group('会话续期（R8：复用 shouldRenewSession + 有界退避）', () {
    test('会话过期（119）→ 有界续期成功 → 换新 _sid、seek 回原位置继续播', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1')]);
      await pumpEventQueue();
      h.engine.emitPosition(const Duration(seconds: 42));
      h.handler.freshUrlFetcher = (id) async =>
          'http://nas/webapi/AudioStation/stream.cgi/0.mp3?_sid=NEW';

      h.engine.emitError(Exception('{"error":{"code":119}}'));
      await pumpEventQueue(times: 40);

      expect(h.engine.playedQueues.length, greaterThanOrEqualTo(2));
      expect(h.engine.playedQueues.last.single.url, contains('_sid=NEW'));
      expect(h.engine.seeks.last, const Duration(seconds: 42));
      expect(h.engine.playing, isTrue);
    });

    test('会话过期且续期全部失败 → **暂停 + 明确提示**（不夸口后台一定能续）', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1')]);
      await pumpEventQueue();
      h.handler.freshUrlFetcher = (id) async => throw Exception('login failed');

      final notices = <AudioRenewNotice>[];
      h.handler.renewNotices.listen(notices.add);

      h.engine.emitError(Exception('{"error":{"code":119}}'));
      await pumpEventQueue(times: 60);

      expect(h.engine.playing, isFalse);
      expect(h.handler.playbackState.value.playing, isFalse);
      expect(
        notices.map((n) => n.kind),
        contains(AudioRenewNoticeKind.failedPaused),
      );
    });

    test('续期成功 → 发"已续上"提示', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1')]);
      await pumpEventQueue();
      h.handler.freshUrlFetcher = (id) async => 'http://nas/a.mp3?_sid=NEW';
      final notices = <AudioRenewNotice>[];
      h.handler.renewNotices.listen(notices.add);

      h.engine.emitError(Exception('session timeout 106'));
      await pumpEventQueue(times: 40);
      expect(
        notices.map((n) => n.kind),
        contains(AudioRenewNoticeKind.renewed),
      );
    });

    test('**不是**会话问题（网络中断）→ 不触发续期、不动播放', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1')]);
      await pumpEventQueue();
      h.handler.freshUrlFetcher = (id) async => 'http://nas/a.mp3?_sid=NEW';
      var fetchCalls = 0;
      h.handler.freshUrlFetcher = (id) async {
        fetchCalls++;
        return 'http://nas/a.mp3?_sid=NEW';
      };

      h.engine.emitError(Exception('SocketException: connection failed'));
      await pumpEventQueue(times: 40);

      expect(fetchCalls, 0, reason: '网络中断不该走会话续期');
      expect(h.engine.playedQueues.length, 1);
      expect(h.engine.playing, isTrue);
    });

    test('页面还没注入续期回调 → 暂停 + 失败提示（不假装能续）', () async {
      final h = _harness();
      await h.handler.startQueue([_track('m1')]);
      await pumpEventQueue();
      final notices = <AudioRenewNotice>[];
      h.handler.renewNotices.listen(notices.add);

      h.engine.emitError(Exception('{"error":{"code":119}}'));
      await pumpEventQueue(times: 40);

      expect(h.engine.playing, isFalse);
      expect(
        notices.map((n) => n.kind),
        contains(AudioRenewNoticeKind.failedPaused),
      );
    });
  });

  group('续期驱动（纯逻辑，复用 media_source.dart 的判定/预算）', () {
    test('shouldRenewSession=false（网络中断）→ notRenewable，一次都不试', () async {
      final outcome = await const AudioSessionRenewer(delayOf: _zeroDelay)
          .renew(
            source: renewableAudioSource(url: 'u', displayName: 't', size: 0),
            reason: MediaUnavailableReason.networkFailed,
            fetchFreshUrl: () async => 'x',
          );
      expect(outcome.kind, 'notRenewable');
      expect(outcome.renewed, isFalse);
    });

    test('有界：预算是 kMediaSessionRenewMaxAttempts 次，不会无限重试', () async {
      var attempts = 0;
      final outcome = await const AudioSessionRenewer(delayOf: _zeroDelay)
          .renew(
            source: renewableAudioSource(url: 'u', displayName: 't', size: 0),
            reason: MediaUnavailableReason.sessionExpired,
            fetchFreshUrl: () async {
              attempts++;
              throw Exception('still failing');
            },
          );
      expect(outcome.kind, 'exhausted');
      expect(attempts, kMediaSessionRenewMaxAttempts);
    });
  });

// ★ 第 368 轮真机缺陷的**接线守卫**：生产上只能有一个播放器实例。
//
// 事实：`main.dart` 只覆盖了 `audioHandlerProvider`，而 `AudioService.init`
// 的 builder 是 `SynologyAudioHandler.new` —— 它自己建了**真正在播**的 P1；
// 容器里的 `audioStationPlayerProvider` 又懒建了一个**闲置的 P2**。
// 页面读 P2 ⇒ `androidAudioSessionId` 恒为 null（真频谱回落推导动效）、
// 原生均衡器永远"还没接上"。修法 = `main.dart` 把
// `audioStationPlayerProvider` 覆盖成 `audioHandler.player`。
//
// 这条接线在真机上的**症状**（会话 id 恒 null）离线复现不了，所以这里直接钉
// 结构与"同一实例"两件事；真机读数见 `docs/android-ui-audit-r368.md`。
group('★ 368 单一播放器实例（DA21 接线守卫）', () {
  test('handler 暴露的播放器就是它内部在用的那一个', () {
    final h = _harness();
    expect(
      identical(h.handler.player, h.engine),
      isTrue,
      reason: '不是同一实例 ⇒ 页面与会话/原生效果/真频谱全部失联',
    );
  });

  test('main.dart 把页面读的 provider 覆盖成 handler 的播放器', () {
    final src = File('lib/main.dart').readAsStringSync();
    expect(
      src.contains(
        'audioStationPlayerProvider.overrideWithValue(audioHandler.player)',
      ),
      isTrue,
      reason: '生产上不许存在第二个闲置播放器',
    );
    expect(
      src.contains('audioHandlerProvider.overrideWithValue(audioHandler)'),
      isTrue,
    );
  });
});
}

Duration _zeroDelay(int attempt) => Duration.zero;
