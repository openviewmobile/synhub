// S2 任务 2/3：**能力位降级 + 工作台入口按状态渲染**的离线 UI 用例。
//
// 覆盖设计 §3 矩阵：
//   * #7  相册缺 `SYNO.Foto.Streaming` → 视频项级降级（不崩、有提示）；
//       缺 `Thumbnail` → 缩略图回退占位；
//   * 音频缺 `Stream` → 不提供内嵌播放，给降级提示；
//   * 工作台磁贴：`absent`/`unauthorized` → 隐藏；`sessionExpired` → 保留但置灰+原因。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart'
    show AppTextZh;
import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_song_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';
import 'package:synhub/src/features/files/drive_more_page.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Map<String, Map<String, dynamic>> _fullTable({Set<String> drop = const {}}) {
  final table = <String, Map<String, dynamic>>{...FakeTransport.table};
  for (final spec in kServiceRegistry.values) {
    for (final api in spec.allApis) {
      table[api] = {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 9};
    }
  }
  for (final d in drop) {
    table.remove(d);
  }
  return table;
}

Set<String> _requiredApis(StationService s) =>
    kServiceRegistry[s]!.requiredApis.toSet();

/// 起一个已登录容器；模块 API provider 通过"盒子"在 boot 之后指向同一条假传输。
Future<ChatHarness> _boot({
  Set<String> drop = const {},
  Map<String, Map<String, dynamic>> extra = const {},
  List<Object> more = const [],
}) async {
  DsmWebApi? availBox;
  final h = await bootChat(
    extra: extra,
    apiTable: _fullTable(drop: drop),
    moreOverrides: <Object>[
      availabilityApiProvider.overrideWith((ref) => availBox),
      ...more,
    ],
  );
  availBox = h.api;
  await h.container.read(serviceAvailabilityProvider.notifier).refresh();
  return h;
}

/// 假播放器（`just_audio` 在 widget 测试里没有平台通道）。
///
/// ⚠️ 本类**只做接口补齐**：`AudioStationPlayer` 在本批音频 P0 里加了
/// 队列 / 索引 / 时长 / 位置流 / 随机 / 循环等成员（P0-2 / P0-5），这里按
/// 同一语义补上，使本文件的降级用例重新可编译。**不触碰本文件任何断言 /
/// `_fullTable()` / 降级判定** —— 那些是能力真值刷新批的成果。
///
/// 语义依据（与 `lib/src/features/audio/audio_player.dart` 的抽象一致）：
/// * `play(url)` = 只有一条的队列（`playQueue([url])`）；
/// * `currentIndex` 是队列下标，空队列/未播 = -1；
/// * `positionStream` / `durationStream` 广播当前值与后续值；
/// * `shuffleEnabled` / `repeatMode` 记住开关状态。
class _FakePlayer implements AudioStationPlayer {
  final played = <String>[];
  final playedQueues = <List<AudioQueueEntry>>[];
  final seeks = <Duration>[];
  String? _current;
  bool _playing = false;
  int _index = -1;
  List<AudioQueueEntry> _queue = const [];
  bool _shuffle = false;
  AudioRepeatMode _repeat = AudioRepeatMode.off;
  Duration _pos = Duration.zero;
  Duration? _dur;
  final _changes = StreamController<void>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();

  @override
  bool get playing => _playing;

  @override
  String? get currentUrl => _current;

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
    _changes.add(null);
  }

  @override
  Future<void> previous() async {
    if (_queue.isEmpty) return;
    _index = (_index - 1).clamp(0, _queue.length - 1);
    _current = _queue[_index].url;
    played.add(_current!);
    _changes.add(null);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _pos = position;
    _position.add(position);
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
}

FotoItemDto _videoItem() =>
    const FotoItemDto(id: '1001', filename: 'clip.mp4', type: 'video');

Map<String, dynamic> _songJson() => const {
  'id': 'music_1',
  'path': '/volume1/music/示例歌曲.mp3',
  'type': 'file',
  'title': '示例歌曲',
  'artist': '示例歌手',
  'album': '十一月的萧邦',
  'additional': {
    'song_tag': {
      'title': '示例歌曲',
      'artist': '示例歌手',
      'album': '十一月的萧邦',
      'album_artist': '示例歌手',
      'composer': '示例歌手',
      'genre': 'Pop',
      'year': 2005,
      'track': 3,
    },
    'song_audio': {
      'duration': 227,
      'bitrate': 320000,
      'frequency': 44100,
      'channel': 2,
      'filesize': 9090909,
    },
    'song_rating': {'rating': 0},
  },
};

Future<void> _pump(WidgetTester tester, ChatHarness h, Widget page) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  test('能力位常量都确实在注册表的对应服务里（防漂移）', () {
    expect(
      kServiceRegistry[StationService.note]!.optionalApis,
      contains(kNoteTodoApi),
    );
    expect(
      kServiceRegistry[StationService.calendar]!.optionalApis,
      contains(kCalTodoApi),
    );
    expect(
      kServiceRegistry[StationService.contacts]!.optionalApis,
      contains(kContactsAddressbookApi),
    );
    expect(
      kServiceRegistry[StationService.drive]!.optionalApis,
      contains(kDriveSharingApi),
    );
    expect(
      kServiceRegistry[StationService.office]!.optionalApis,
      contains(kOfficeVersionApi),
    );
    expect(
      kServiceRegistry[StationService.download]!.optionalApis,
      contains(kDownloadTaskListApi),
    );
    expect(
      kServiceRegistry[StationService.surveillance]!.optionalApis,
      contains(kSurveillanceRecordingApi),
    );
    expect(
      kServiceRegistry[StationService.mailplus]!.optionalApis,
      contains(kMailAttachmentApi),
    );
    expect(
      kServiceRegistry[StationService.photo]!.optionalApis,
      contains(kFotoStreamingApi),
    );
    expect(
      kServiceRegistry[StationService.photo]!.optionalApis,
      contains(kFotoThumbnailApi),
    );
    expect(
      kServiceRegistry[StationService.audio]!.optionalApis,
      contains(kAudioStreamApi),
    );
    expect(
      kServiceRegistry[StationService.audio]!.optionalApis,
      contains(kAudioCoverApi),
    );
  });

  group('S2 能力位降级', () {
    testWidgets('#7 相册缺 Foto.Streaming → 视频项降级（不崩、有提示）', (tester) async {
      FotoApi? fotoBox;
      final h = await _boot(
        drop: {kFotoStreamingApi},
        more: [fotoApiProvider.overrideWith((ref) => fotoBox)],
      );
      fotoBox = FotoApi(h.api);

      await _pump(tester, h, PhotoViewerPage(items: [_videoItem()], index: 0));

      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.photo),
        AvailabilityState.partial,
        reason: '相册本身仍可用（partial，不隐藏）',
      );
      expect(find.byKey(const Key('photo-video-unavailable')), findsOneWidget);
      // S2 收口：视频降级面板用更贴切的 `photoVideoUnavailable`，
      // 不再复用通用的 `serviceStatePartialReason`。
      expect(find.text(AppTextZh().photoVideoUnavailable), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('相册缺 Foto.Thumbnail → 缩略图回退占位（不空白）', (tester) async {
      final h = await _boot(drop: {kFotoThumbnailApi});
      await _pump(
        tester,
        h,
        const Scaffold(
          body: PhotoThumb(
            request: PhotoThumbRequest(
              itemId: '1',
              cacheKey: '1',
              space: FotoSpace.personal,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('photo-thumb-fallback')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('音频缺 AudioStation.Stream → 不提供内嵌播放，给降级提示', (tester) async {
      AudioStationApi? asBox;
      final player = _FakePlayer();
      final h = await _boot(
        drop: {kAudioStreamApi},
        extra: {
          'SYNO.AudioStation.Song.getinfo': {
            'songs': [_songJson()],
          },
          'SYNO.AudioStation.Lyrics.getlyrics': {'lyrics': 'l'},
        },
        more: [
          audioApiProvider.overrideWith((ref) => asBox),
          audioStationPlayerProvider.overrideWithValue(player),
        ],
      );
      asBox = AudioStationApi(h.api);

      await _pump(
        tester,
        h,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
      );

      expect(find.byKey(const Key('as-stream-unavailable')), findsOneWidget);
      expect(find.byKey(const Key('as-play')), findsNothing);
      // S2 收口：音频缺 `Stream` 的降级提示用 `asStreamUnavailable`。
      expect(find.text(AppTextZh().asStreamUnavailable), findsWidgets);
      // 遗留 1：队列入口同样按 `Stream` 能力位**隐藏**（原因即上面的降级提示）
      expect(find.byKey(const Key('as-queue-entry')), findsNothing);
      expect(player.played, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('S2 工作台磁贴按状态渲染', () {
    Future<void> pumpWorkspace(WidgetTester tester, ChatHarness h) async {
      // 放大测试画布：工作台是分屏 PageView，画布太小只会渲染第一屏的 2 个磁贴。
      await tester.binding.setSurfaceSize(const Size(1200, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      h.container.read(appTabProvider.notifier).select(AppTab.workspace);
      await _pump(tester, h, const AppShellPage());
    }

    testWidgets('note 未安装（absent）→ 工作台磁贴隐藏，其它保留', (tester) async {
      final h = await _boot(drop: _requiredApis(StationService.note));
      await pumpWorkspace(tester, h);

      expect(find.byKey(const Key('ws-tile-notes')), findsNothing);
      expect(find.byKey(const Key('ws-tile-calendar')), findsOneWidget);
    });

    testWidgets('note 无权限（105）→ 工作台磁贴隐藏', (tester) async {
      final h = await _boot();
      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.note, kNoPermissionCode);
      await pumpWorkspace(tester, h);

      expect(find.byKey(const Key('ws-tile-notes')), findsNothing);
    });

    testWidgets('note 会话失效（119）→ 磁贴保留但置灰 + 一句话原因', (tester) async {
      final h = await _boot();
      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.note, kSidNotFoundCode);
      await pumpWorkspace(tester, h);

      expect(find.byKey(const Key('ws-tile-notes')), findsOneWidget);
      expect(
        find.text(AppTextZh().serviceEntrySessionExpired),
        findsWidgets,
        reason: '会话失效 → 置灰 + 原因，不隐藏',
      );
    });
  });

  // ------------------------------------------------------------------
  // 任务 3（2026-09-22 收口）：Office 入口从工作台移进 Drive「更多」页。
  //
  // 用户拍板原话：「Office 的入口在 Drive 里，为啥要独立出来？官方也没有独立
  // 出来啊？」官方证据（Office 包自述 "…in Synology Drive"、带
  // `drive/hook/libsynoffice_drivehook.so`、前端有 `SYNO.SDS.Office.Utils.isDrivePage`）
  // 见 `docs/workspace-expansion-evaluation.md` 追加节。
  //
  // 结论：工作台回到 **11 个入口**；Office 入口在 Drive 的「更多」页里
  // （key `drive-more-office`），能力位缺失 → 只隐藏该入口，**绝不隐藏 Drive**。
  // ------------------------------------------------------------------
  group('任务 3 收口：Office 入口在 Drive 里', () {
    /// 工作台是分屏 PageView，画布太小只会渲染第一屏；给一块放得下 11 个磁贴的画布。
    Future<void> pumpBigWorkspace(WidgetTester tester, ChatHarness h) async {
      await tester.binding.setSurfaceSize(const Size(1600, 4200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      h.container.read(appTabProvider.notifier).select(AppTab.workspace);
      await _pump(tester, h, const AppShellPage());
    }

    Future<void> pumpDriveMore(WidgetTester tester, ChatHarness h) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(tester, h, const DriveMorePage());
    }

    testWidgets('① 工作台回到 11 个入口：office / drive 磁贴都不存在', (tester) async {
      final h = await _boot();
      await pumpBigWorkspace(tester, h);

      expect(
        find.byKey(const Key('ws-tile-office')),
        findsNothing,
        reason: 'Office 不再是工作台磁贴（入口进 Drive「更多」页）',
      );
      expect(
        find.byKey(const Key('ws-tile-drive')),
        findsNothing,
        reason: 'Drive 不再是工作台磁贴（底栏 tab / 文件来源已有）',
      );
      for (final id in [
        'files',
        'notes',
        'photos',
        'contacts',
        'calendar',
        'tasks',
        'search',
        'downloads',
        'audio',
        'surveillance',
        'mailplus',
      ]) {
        expect(
          find.byKey(Key('ws-tile-$id')),
          findsOneWidget,
          reason: '11 入口之一零回归：$id',
        );
      }
    });

    testWidgets('② Office 入口在 Drive「更多」页里，点了进 Office 文档页', (tester) async {
      final h = await _boot();
      await pumpDriveMore(tester, h);

      expect(
        find.byKey(const Key('drive-more-office')),
        findsOneWidget,
        reason: 'Office 的用户入口在 Drive 里（官方也是这样）',
      );
      await tester.tap(find.byKey(const Key('drive-more-office')));
      // 不用 pumpAndSettle：DriveBrowseView 首帧会发起请求（FakeTransport），
      // 只要确认路由已经推起来即可。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('office-page')), findsOneWidget);
    });

    testWidgets('③ 缺 SYNO.Office.Node：入口隐藏，Drive 模块照常（partial，不隐藏 Drive）', (
      tester,
    ) async {
      final h = await _boot(drop: _requiredApis(StationService.office));
      final states = h.container.read(serviceAvailabilityProvider);
      expect(states.stateOf(StationService.office), AvailabilityState.absent);
      expect(
        states.stateOf(StationService.drive),
        isNot(AvailabilityState.absent),
        reason: 'Office 缺失不该把 Drive 拖成不可用',
      );
      await pumpDriveMore(tester, h);

      expect(find.byKey(const Key('drive-more-office')), findsNothing);
      expect(
        find.byKey(const Key('drive-more-office-denied')),
        findsNothing,
        reason: '未安装 ≠ 无权限，不该弹"无权限"提示',
      );
      expect(
        find.byKey(const Key('drive-more-pager')),
        findsOneWidget,
        reason: 'Drive「更多」页整体照常（五段都在）',
      );
    });

    testWidgets('④ Office 无权限（105）→ 入口隐藏 + 无权限提示', (tester) async {
      final h = await _boot();
      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.office, kNoPermissionCode);
      await pumpDriveMore(tester, h);

      expect(
        find.byKey(const Key('drive-more-office')),
        findsNothing,
        reason: '105 无权限 → 入口隐藏（避免"看得见用不了"）',
      );
      expect(
        find.byKey(const Key('drive-more-office-denied')),
        findsOneWidget,
        reason: '105 要有一句"无权限"提示，别让用户以为 Drive 里本来没有 Office',
      );
      expect(find.textContaining('无权限'), findsWidgets);
      expect(find.byKey(const Key('drive-more-pager')), findsOneWidget);
    });

    testWidgets('⑤ Office 会话失效（119）→ 入口保留但置灰 + 会话提示，绝不隐藏模块', (tester) async {
      final h = await _boot();
      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.office, kSidNotFoundCode);
      await pumpDriveMore(tester, h);

      expect(
        find.byKey(const Key('drive-more-office')),
        findsOneWidget,
        reason: '119 是会话失效，绝不隐藏（隐藏了用户无从恢复）',
      );
      expect(find.byKey(const Key('drive-more-office-denied')), findsNothing);
      expect(
        find.text(AppTextZh().serviceEntrySessionExpired),
        findsWidgets,
        reason: '会话失效 → 置灰 + 一句话原因',
      );
      // 置灰 = 点不动（不会推起 Office 页）
      await tester.tap(find.byKey(const Key('drive-more-office')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('office-page')), findsNothing);
      expect(find.byKey(const Key('drive-more-pager')), findsOneWidget);
    });

    testWidgets('⑥ Office 会话超时（106）→ 同样保留但置灰（与 119 同族）', (tester) async {
      final h = await _boot();
      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.office, kSessionTimeoutCode);
      await pumpDriveMore(tester, h);

      expect(find.byKey(const Key('drive-more-office')), findsOneWidget);
      expect(find.text(AppTextZh().serviceEntrySessionExpired), findsWidgets);
      expect(find.byKey(const Key('drive-more-pager')), findsOneWidget);
    });
  });
}
