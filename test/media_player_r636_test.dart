// 播放器「上次看到哪儿」记忆（r636）—— **DA227**。
//
// 现场（真机 ＋ 人视角）：10 分钟的课程视频看到 04:31，退出再进 —— **永远回到 00:00**。
// 用户的动作是"接着看"，播放器给的却是"重看"；Plex / YouTube / 播客类 App 全都有续播。
//
// 判据（都能红）：
//   ① 有记忆 ⇒ 装好就 seek 到旧位置，并给一条**可撤销**的提示（点「从头播放」回 00:00 且清记忆）；
//   ② 反向：没有记忆 ⇒ 一次都不许 seek（不许"假动作"）；
//   ③ 反向：不可 seek 的源（Drive `Accept-Ranges: none`）⇒ 连读都不读（读了也没用）；
//   ④ 暂停是"我可能要走了" ⇒ 必须**立刻**落盘（等 10 s 节流就丢了）；
//   ⑤ 存储本身：太短 / 快看完的不记（并把旧值清掉）、超上限按最近使用淘汰。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/cloud_key_store.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_resume_store.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_tracks.dart';

/// 内存版：行为与真实存储一致，只是不落盘（用例断言用）。
class _MemStore extends MediaResumeStore {
  _MemStore({this.saved = const {}});

  final Map<String, Duration> saved;
  final loads = <String>[];
  final writes = <String, Duration>{};
  final cleared = <String>[];

  @override
  Future<Duration?> load(String uri, {required Duration duration}) async {
    loads.add(uri);
    return saved[uri];
  }

  @override
  Future<void> save(
    String uri,
    Duration position, {
    required Duration duration,
  }) async {
    writes[uri] = position;
  }

  @override
  Future<void> clear(String uri) async {
    cleared.add(uri);
  }
}

/// 读盘永远不返回：模拟"本地存储很慢/卡住"的极端情况。
///
/// 判据：**起播不许等它**。进度记忆是加分项，慢一拍也还能用就绪回调补上；
/// 但"用户点了播放却因为读一个 JSON 迟迟不出画面"是不可接受的。
class _HangStore extends MediaResumeStore {
  final loads = <String>[];

  @override
  Future<Duration?> load(String uri, {required Duration duration}) {
    loads.add(uri);
    return Completer<Duration?>().future; // 永不完成
  }
}

class _Adapter implements MediaPlayerAdapter, MediaPlayerFullControls {
  final _changes = StreamController<void>.broadcast();

  final seeks = <Duration>[];
  final loaded = <String>[];
  int plays = 0;
  Duration positionValue = Duration.zero;
  bool playingValue = false;
  double speedValue = 1;
  Object? errorValue;
  double volumeValue = 0.5;
  MediaAspectMode aspectValue = MediaAspectMode.fit;

  void emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> load(MediaSource source) async => loaded.add(source.uri);

  @override
  Future<void> play() async {
    plays++;
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
  Future<void> skipBy(Duration offset) async {}

  @override
  Future<void> setSpeed(double speed) async => speedValue = speed;

  @override
  Future<void> setVolume(double value) async => volumeValue = value;

  @override
  Future<void> setMuted(bool value) async {}

  @override
  Future<void> setPlaylist(List<MediaSource> items, int index) async {}

  @override
  Future<void> playNext() async {}

  @override
  Future<void> playPrevious() async {}

  @override
  Future<void> selectAudioTrack(String? id) async {}

  @override
  Future<void> selectSubtitleTrack(String? id) async {}

  @override
  Future<void> setAspectMode(MediaAspectMode mode) async => aspectValue = mode;

  @override
  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  List<MediaTrackInfo> audioTracks = const [];

  @override
  List<MediaTrackInfo> subtitleTracks = const [];

  @override
  String? embeddedSubtitleText;

  @override
  Duration get position => positionValue;

  Duration? durationValue = const Duration(seconds: 600);

  @override
  Duration? get duration => durationValue;

  @override
  bool get playing => playingValue;

  bool readyValue = true;

  @override
  bool get ready => readyValue;

  @override
  double get speed => speedValue;

  @override
  String? get error => errorValue?.toString();

  @override
  double get aspectRatio => 16 / 9;

  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(key: Key('fake-surface'), color: Colors.black);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  double get volume => volumeValue;

  @override
  bool get muted => false;

  @override
  int get playlistIndex => 0;

  @override
  int get playlistLength => 1;

  @override
  bool get hasPrevious => false;

  @override
  bool get hasNext => false;

  @override
  String? get selectedAudioTrackId => null;

  @override
  String? get selectedSubtitleTrackId => null;

  @override
  MediaAspectMode get aspectMode => aspectValue;
}

MediaSource _source({bool range = true}) => MediaSource(
  uri: 'https://fake.test/webapi/entry.cgi?api=SYNO.FileStation.Download',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: '1-课程导学.mp4',
  supportsRange: range,
);

Future<void> _pump(
  WidgetTester tester,
  _Adapter adapter, {
  bool range = true,
  MediaResumeStore? store,
}) async {
  final container = ProviderContainer(
    overrides: [
      cloudKeyStoreProvider.overrideWithValue(MemoryCloudKeyStore()),
      mediaPlayerAdapterFactoryProvider.overrideWithValue(() => adapter),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: MediaPlayerView(
            source: _source(range: range),
            resumeStore: store,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  group('DA227：上次看到哪儿 + 从头播放', () {
    testWidgets('① 有记忆 ⇒ 装好就 seek 到旧位置，并给可撤销提示', (tester) async {
      final adapter = _Adapter();
      final store = _MemStore(
        saved: {_source().uri: const Duration(minutes: 4, seconds: 31)},
      );
      await _pump(tester, adapter, store: store);

      // 装载时就 seek 到 4:31，用户不会看到"从 00:00 闪一下再跳"。
      expect(adapter.seeks.first, const Duration(minutes: 4, seconds: 31));
      expect(find.byKey(const Key('media-resume-banner')), findsOneWidget);
      // 提示里给的是**读数**，不是"续播成功"这种技术话术。
      expect(
        find.descendant(
          of: find.byKey(const Key('media-resume-banner')),
          matching: find.textContaining('4:31'),
        ),
        findsOneWidget,
      );

      // 「从头播放」= 回 00:00 ＋ 清掉记忆（下次进来不再被拉回）
      await tester.tap(find.byKey(const Key('media-resume-start-over')));
      await tester.pump();
      expect(adapter.seeks.last, Duration.zero);
      expect(store.cleared, contains(_source().uri));
      expect(find.byKey(const Key('media-resume-banner')), findsNothing);
    });

    testWidgets('⑨ 提示条**整条**都能点（不只那一小段文字）', (tester) async {
      final adapter = _Adapter();
      final store = _MemStore(
        saved: {_source().uri: const Duration(minutes: 4, seconds: 31)},
      );
      await _pump(tester, adapter, store: store);
      final banner = find.byKey(const Key('media-resume-banner'));
      expect(banner, findsOneWidget);
      final rect = tester.getRect(banner);
      // 点提示条**左侧**（图标/文字那一片）——真机上"只做一个小按钮"正是这里点不动
      await tester.tapAt(Offset(rect.left + 40, rect.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(adapter.seeks.last, Duration.zero);
      expect(banner, findsNothing);
    });

    testWidgets('⑩ 就绪那拍已经播过几秒 ⇒ 仍然要续播（判据是"谁动的"，不是第几秒）', (tester) async {
      final adapter = _Adapter()..readyValue = false;
      final store = _MemStore(
        saved: {_source().uri: const Duration(minutes: 4, seconds: 31)},
      );
      await _pump(tester, adapter, store: store);
      expect(adapter.seeks, isEmpty);

      // 真机常态：ready 与首个位置事件一起来，此时已经播了 6 s
      adapter.readyValue = true;
      adapter.playingValue = true;
      adapter.positionValue = const Duration(seconds: 6);
      adapter.emit();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(adapter.seeks.first, const Duration(minutes: 4, seconds: 31));
    });

    testWidgets('② 反向：没有记忆 ⇒ 一次都不 seek，也不出提示', (tester) async {
      final adapter = _Adapter();
      final store = _MemStore();
      await _pump(tester, adapter, store: store);
      expect(adapter.seeks, isEmpty);
      expect(find.byKey(const Key('media-resume-banner')), findsNothing);
    });

    testWidgets('③ 反向：不可 seek 的源 ⇒ 连读都不读', (tester) async {
      final adapter = _Adapter();
      final store = _MemStore(
        saved: {_source(range: false).uri: const Duration(minutes: 4)},
      );
      await _pump(tester, adapter, range: false, store: store);
      expect(store.loads, isEmpty);
      expect(adapter.seeks, isEmpty);
    });

    testWidgets('⑦ 装载时还不知道时长 ⇒ 就绪后再续播（不许就此放弃）', (tester) async {
      final adapter = _Adapter()..durationValue = null;
      final store = _MemStore(
        saved: {_source().uri: const Duration(minutes: 4, seconds: 31)},
      );
      await _pump(tester, adapter, store: store);
      // 时长未知 = "还不知道"，不是"没有记忆"：此刻不许 seek，也不许下结论
      expect(adapter.seeks, isEmpty);
      expect(find.byKey(const Key('media-resume-banner')), findsNothing);

      // 播放器就绪（时长报到）→ 补做续播
      adapter.durationValue = const Duration(seconds: 600);
      adapter.playingValue = true;
      adapter.emit();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(adapter.seeks.first, const Duration(minutes: 4, seconds: 31));
      expect(find.byKey(const Key('media-resume-banner')), findsOneWidget);
    });

    testWidgets('⑧ 首帧未就绪 ⇒ 不许 seek（真机上会直接把这条播崩）', (tester) async {
      final adapter = _Adapter()..readyValue = false;
      final store = _MemStore(
        saved: {_source().uri: const Duration(minutes: 4, seconds: 31)},
      );
      await _pump(tester, adapter, store: store);
      expect(adapter.seeks, isEmpty);

      // 首帧就绪 → 才允许续播
      adapter.readyValue = true;
      adapter.playingValue = true;
      adapter.emit();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(adapter.seeks.first, const Duration(minutes: 4, seconds: 31));
      expect(find.byKey(const Key('media-resume-banner')), findsOneWidget);
    });

    testWidgets('④ 暂停 ⇒ 立刻落盘（不等 10 s 节流）', (tester) async {
      final adapter = _Adapter();
      final store = _MemStore();
      await _pump(tester, adapter, store: store);
      adapter.playingValue = true;
      // 先让节流记一次 2:00（`_lastSavedPosition` 有值）
      adapter.positionValue = const Duration(minutes: 2);
      adapter.emit();
      await tester.pump();
      expect(store.writes[_source().uri], const Duration(minutes: 2));
      // 5 s 后再暂停：节流会跳过（差 < 10 s）⇒ 只有"暂停强制落盘"才写得出 2:05
      adapter.positionValue = const Duration(minutes: 2, seconds: 5);
      await adapter.pause();
      await tester.pump();
      expect(
        store.writes[_source().uri],
        const Duration(minutes: 2, seconds: 5),
      );
    });

    testWidgets('⑪ 读盘卡住 ⇒ 照样出画面起播（起播不许被"读进度文件"拖住）', (tester) async {
      final adapter = _Adapter();
      final store = _HangStore();
      await _pump(tester, adapter, store: store);
      expect(adapter.loaded.single, contains('SYNO.FileStation.Download'));
      // 真机上的代价是几毫秒，但这条路径**一次不必要的等待都不该有**
      expect(adapter.plays, 1, reason: '读盘卡住也必须已经起播');
      expect(store.loads, hasLength(1), reason: '读还是要读的，只是不挡路');
      expect(adapter.seeks, isEmpty, reason: '还没读到记忆 ⇒ 不 seek');
    });

    testWidgets('⑫ 起播那一拍 00:00 不许把旧记忆清掉（先判定，后落盘）', (tester) async {
      final adapter = _Adapter();
      adapter.readyValue = false; // 首帧还没就绪（真机上常见）
      final store = _MemStore(
        saved: {_source().uri: const Duration(minutes: 4, seconds: 31)},
      );
      await _pump(tester, adapter, store: store);

      // 起播边沿：位置 00:00、playing=true ⇒ 老实现会 `save(0)` ⇒ 太短 ⇒ 清掉 4:31
      adapter.playingValue = true;
      adapter.positionValue = Duration.zero;
      adapter.emit();
      await tester.pump();
      expect(store.writes, isEmpty, reason: '续播判定没落地前，一个字节都不许写');
      expect(store.cleared, isEmpty, reason: '更不许把旧记忆清掉');

      // 首帧就绪 ⇒ 补做续播
      adapter.readyValue = true;
      adapter.emit();
      await tester.pump();
      expect(adapter.seeks.single, const Duration(minutes: 4, seconds: 31));
    });

    // ★ r637 `DA229`：设置面板在真机会超出窗口（最后一行点不到）⇒ 必须能滚。
    testWidgets('⑬ 「播放设置」面板可滚动（多行时最后一行也点得到）', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('media-settings-sheet')),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
        reason: '真机 2492 高、App 窗口只到 2377：行多了就点不到，必须可滚',
      );
    });
  });

  group('DA227：存储规则（真实文件）', () {
    late Directory dir;
    late MediaResumeStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('synhub_resume_');
      store = MediaResumeStore(
        supportDirectory: () async => dir,
        maxEntries: 3,
      );
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('⑤ 往返：存进去、读出来；太短/快看完不记且清旧值', () async {
      const uri = 'https://nas.test/video.mp4';
      const total = Duration(minutes: 10);
      await store.save(uri, const Duration(minutes: 3), duration: total);
      expect(
        await store.load(uri, duration: total),
        const Duration(minutes: 3),
      );

      // 3 秒 = 太短，不记（并且把旧值清掉，避免下次被拉回）
      await store.save(uri, const Duration(seconds: 3), duration: total);
      expect(await store.load(uri, duration: total), isNull);

      // 只剩 5 秒 = 快看完了，也不记
      await store.save(
        uri,
        const Duration(minutes: 9, seconds: 55),
        duration: total,
      );
      expect(await store.load(uri, duration: total), isNull);
    });

    test('⑥ 键归一：只差会话参数的直链算同一条（真机第一版就栽在这里）', () async {
      const total = Duration(minutes: 10);
      const a =
          'https://nas.test/webapi/entry.cgi?api=SYNO.FileStation.Download'
          '&version=2&method=download&path=%2Fhome%2Fc.mp4&_sid=AAA&SynoToken=TT1';
      const b =
          'https://nas.test/webapi/entry.cgi?api=SYNO.FileStation.Download'
          '&version=2&method=download&path=%2Fhome%2Fc.mp4&_sid=BBB&SynoToken=TT2';
      expect(MediaResumeStore.keyOf(a), MediaResumeStore.keyOf(b));
      expect(MediaResumeStore.keyOf(a), isNot(contains('_sid')));
      // 同一目录的**另一条**片子必须是不用的键（否则互相顶掉进度）
      expect(
        MediaResumeStore.keyOf(a),
        isNot(MediaResumeStore.keyOf(a.replaceAll('c.mp4', 'd.mp4'))),
      );
      await store.save(a, const Duration(minutes: 3), duration: total);
      expect(await store.load(b, duration: total), const Duration(minutes: 3));
    });

    test('⑤ 上限：超 maxEntries 按最近使用淘汰', () async {
      const total = Duration(minutes: 10);
      for (var i = 0; i < 5; i++) {
        await store.save('u$i', const Duration(minutes: 1), duration: total);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await store.load('u0', duration: total), isNull);
      expect(
        await store.load('u4', duration: total),
        const Duration(minutes: 1),
      );
    });
  });
}
