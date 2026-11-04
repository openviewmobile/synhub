// R7 P0：**相册视频通道选择（Download 优先 + Streaming 回退）** 与
// **取流失败携带会话语义（119/106）→ sessionExpired + 自动续期** 的离线承重。
//
// 事实来源：
//   * docs/media-streaming-diagnosis.md §1.2 —— 官方 `u9`
//     （`ui/react_bundle.js` 偏移 2544763）对 `Item` 种类发 `item_id=[…]`，
//     对 `Unit` 种类发 `unit_id=[…]`；`"raw"` 档（原生 mp4/h264）走的正是 Download。
//   * docs/device-verification.md R7-13-B —— `--download-error=119` 首包是
//     `HTTP 200` + JSON 信封，Media3 只报 `PARSING_CONTAINER_UNSUPPORTED`（串里
//     没有 119）→ 必须用**同一鉴权字节链路**复核应答体才能还原会话语义。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_tracks.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

// ─────────────────────────────────────────────────────────────── 假适配器

/// 完整控制的假适配器（对应自研原生播放器）：记录播放列表 / 可摆布错误。
class _FakeFullAdapter implements MediaPlayerAdapter, MediaPlayerFullControls {
  final _changes = StreamController<void>.broadcast();

  final loaded = <String>[];
  final playlists = <List<String>>[];
  final seeks = <Duration>[];
  int plays = 0;

  Duration _position = Duration.zero;
  final Duration _duration = const Duration(seconds: 100);
  bool _playing = false;
  final bool _ready = true;
  int _index = 0;
  int _count = 1;
  String? _error;

  void emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 模拟"用户点了下一个 / 播放列表索引变化"
  void selectIndex(int index) {
    _index = index;
    emit();
  }

  /// 模拟"播放器运行中报错"
  void failWith(String message) {
    _error = message;
    emit();
  }

  @override
  Future<void> load(MediaSource source) async {
    loaded.add(source.uri);
    // 生产适配器重载即清错
    _error = null;
    emit();
  }

  @override
  Future<void> setPlaylist(List<MediaSource> items, int index) async {
    playlists.add([for (final s in items) s.uri]);
    _count = items.length;
    _index = index;
    _error = null;
    emit();
  }

  @override
  Future<void> play() async {
    plays++;
    _playing = true;
    emit();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    emit();
  }

  @override
  Future<void> seekTo(Duration position) async {
    _position = position;
    seeks.add(position);
    emit();
  }

  @override
  Future<void> skipBy(Duration offset) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> setMuted(bool value) async {}
  @override
  Future<void> playNext() async {}
  @override
  Future<void> playPrevious() async {}
  @override
  Future<void> selectAudioTrack(String? id) async {}
  @override
  Future<void> selectSubtitleTrack(String? id) async {}
  @override
  Future<void> setAspectMode(MediaAspectMode mode) async {}

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
  double get speed => 1;
  @override
  String? get error => _error;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(key: Key('photos-fake-surface'), color: Colors.black);
  @override
  Stream<void> get changes => _changes.stream;
  @override
  double get volume => 1;
  @override
  bool get muted => false;
  @override
  int get playlistIndex => _index;
  @override
  int get playlistLength => _count;
  @override
  bool get hasPrevious => _count > 1 && _index > 0;
  @override
  bool get hasNext => _count > 1 && _index < _count - 1;
  // ★ r659（`DA274`）：轨道要能在播放中变 —— 面板"行值不跟"就是从这儿复现的
  final audioTrackList = <MediaTrackInfo>[];
  final subtitleTrackList = <MediaTrackInfo>[];
  String? audioId;
  String? subtitleId;

  /// 模拟"用户在菜单里选了内封字幕"（原生回一条事件）
  void chooseSubtitle(String? id) {
    subtitleId = id;
    emit();
  }

  @override
  List<MediaTrackInfo> get audioTracks => audioTrackList;
  @override
  List<MediaTrackInfo> get subtitleTracks => subtitleTrackList;
  @override
  String? get selectedAudioTrackId => audioId;
  @override
  String? get selectedSubtitleTrackId => subtitleId;
  @override
  MediaAspectMode get aspectMode => MediaAspectMode.fit;
  @override
  String? get embeddedSubtitleText => null;
}

// ─────────────────────────────────────────────────────────────── 夹具

const String _sid = '_sid=FAKE-SID';
const String _token = 'SynoToken=FAKE-TOKEN';

/// 相册主通道：官方"原文件"端点 + `item_id`（Item 种类，官方 `u9`）。
MediaSource _photosDownload({MediaSource? fallback}) => MediaSource(
  uri:
      'https://nas/webapi/entry.cgi?api=SYNO.Foto.Download&version=2'
      '&method=download&item_id=%5B9317%5D&$_sid&$_token',
  channel: MediaChannel.photos,
  kind: MediaKind.video,
  displayName: 'clip-h264.mp4',
  size: 18 * 1024,
  supportsRange: false,
  fallback: fallback,
);

/// 相册回退通道：转码档端点 + `type=item`。
MediaSource _photosStreaming() => MediaSource(
  uri:
      'https://nas/webapi/entry.cgi?api=SYNO.Foto.Streaming&version=2'
      '&method=streaming&id=9317&type=item&$_sid&$_token',
  channel: MediaChannel.photos,
  kind: MediaKind.video,
  displayName: 'clip-h264.mp4',
  size: 18 * 1024,
  supportsRange: false,
);

MediaSource _fileStation({
  Future<MediaSource> Function()? renew,
  Future<int?> Function()? probe,
  String displayName = 'v.mp4',
}) => MediaSource(
  uri:
      'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download'
      '&mode=download&path=%2Fhome%2Fv.mp4&$_sid&$_token',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: displayName,
  supportsRange: true,
  renew: renew,
  probeSessionCode: probe,
);

FileEntryDto _entry(String name, {String? path}) => FileEntryDto(
  name: name,
  path: path ?? '/home/$name',
  isDir: false,
  size: 18 * 1024,
  mtime: 1758100000,
);

Future<void> _pumpView(
  WidgetTester tester,
  MediaSource source, {
  required MediaPlayerAdapterFactory factory,
  List<MediaSource>? playlist,
  int playlistIndex = 0,
}) async {
  final container = ProviderContainer(
    overrides: [mediaPlayerAdapterFactoryProvider.overrideWithValue(factory)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: MediaPlayerView(
            source: source,
            playlist: playlist,
            playlistIndex: playlistIndex,
            onOpenExternal: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  // ───────────────────────── ① Download 通道 + ②/③ 回退链 ──────────────
  group('相册视频取流通道（R7 P0：Download 优先 → Streaming 回退）', () {
    testWidgets('② Download 失败 → 原地回退 Streaming，不弹面板', (tester) async {
      final download = _photosDownload(fallback: _photosStreaming());
      final adapter = _FakeFullAdapter();
      await _pumpView(
        tester,
        download,
        playlist: [download],
        factory: () => adapter,
      );
      // 先装上 Download 通道
      expect(adapter.playlists.single.single, contains('SYNO.Foto.Download'));
      expect(adapter.playlists.single.single, contains('item_id='));

      // 服务端明确拒绝 / 返回的不是媒体（Media3 结构化 HTTP 证据）
      adapter.failWith(
        'ERROR_CODE_IO_BAD_HTTP_STATUS(2008) | http=404 | '
        'InvalidResponseCodeException | body=html',
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(MediaFallbackPanel),
        findsNothing,
        reason: 'Download 失败还有下一跳，不许直接给面板',
      );
      expect(
        adapter.playlists.last.single,
        contains('SYNO.Foto.Streaming'),
        reason: '回退链第二跳 = 官方转码档端点（type=item）',
      );
      expect(adapter.playlists.last.single, contains('type=item'));
      expect(adapter.playlists.last.single, isNot(contains('item_id=')));
      expect(adapter.plays, greaterThanOrEqualTo(1));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('③ 两条腿都失败 → 明确面板（streamRejected 文案与另两类互不相同）', (tester) async {
      final download = _photosDownload(fallback: _photosStreaming());
      final adapter = _FakeFullAdapter();
      await _pumpView(
        tester,
        download,
        playlist: [download],
        factory: () => adapter,
      );
      // 第一跳 Download 被拒 → 回退 Streaming
      adapter.failWith('ERROR_CODE_IO_BAD_HTTP_STATUS(2008) | http=500');
      await tester.pumpAndSettle();
      expect(adapter.playlists.last.single, contains('SYNO.Foto.Streaming'));
      expect(find.byType(MediaFallbackPanel), findsNothing);

      // 第二跳 Streaming 也失败 → 才给面板
      adapter.failWith(
        'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED(3003) | sniff failures: '
        '[NoDeclaredBrand, NoDeclaredBrand]',
      );
      await tester.pumpAndSettle();

      expect(find.byType(MediaFallbackPanel), findsOneWidget);
      expect(
        find.textContaining(MediaUnavailableReason.streamRejected.text),
        findsOneWidget,
      );
      // 三类文案互不相同（streamRejected ≠ 编码不支持 ≠ 会话失效）
      expect(
        MediaUnavailableReason.streamRejected.text,
        isNot(MediaUnavailableReason.codecUnsupported.zh),
      );
      expect(
        MediaUnavailableReason.streamRejected.text,
        isNot(MediaUnavailableReason.sessionExpired.zh),
      );
      expect(
        MediaUnavailableReason.codecUnsupported.zh,
        isNot(MediaUnavailableReason.sessionExpired.zh),
      );
      // ④ 第二跳 Streaming **未取证/很可能不可用**（必填 quality 枚举未解）：
      //    失败文案必须说"这条取流请求被服务端拒绝"，**不许**混成"格式不支持"，
      //    更不许让用户以为"文件坏了 / 服务端没这个功能"。
      expect(
        MediaUnavailableReason.streamRejected.text,
        isNot(MediaUnavailableReason.formatUnsupported.zh),
        reason: 'Streaming 失败不是格式问题',
      );
      for (final bad in ['格式', '损坏', '坏', '解码器']) {
        expect(
          MediaUnavailableReason.streamRejected.text,
          isNot(contains(bad)),
          reason: '取流被拒的文案里不许出现「$bad」',
        );
      }

      await tester.pumpWidget(const SizedBox());
    });

    test('⑤ unit_id → 117（真机：item_id 才是 Download 的正确参数）不许误报格式/损坏', () {
      // 真机对照（docs/live-nas-verification.md §4.2）：`unit_id` → `117`；
      // 正确参数是 `item_id`。117 = `DsmErrorCode.internalError`。
      expect(DsmErrorCode.internalError, 117);
      final reason = classifyPlayerError(
        Exception('{"error":{"code":117},"success":false}'),
      );
      expect(reason, isNot(MediaUnavailableReason.formatUnsupported));
      expect(reason, isNot(MediaUnavailableReason.codecUnsupported));
      expect(reason.text, isNot(contains('格式')));
      expect(reason.text, isNot(contains('损坏')));
      // 120（quality 必填 / 参数条件不满足）同理：取流层失败，不是格式问题
      expect(
        classifyPlayerError(
          Exception(
            'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED | '
            '{"error":{"code":120,"errors":{"name":"quality"}},"success":false}',
          ),
        ),
        MediaUnavailableReason.streamRejected,
      );
    });
  });

  // ───────────────────────── ⑥ 119/106 → sessionExpired + 续期 ───────────
  group('取流失败的会话语义（R7-13-B）：119/106 必须归 sessionExpired 并续期', () {
    // 真机形态：`HTTP 200` + JSON 信封 → Media3 只报"不是媒体"（串里没有 119）
    const ambiguous =
        'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED(3003) | '
        'UnrecognizedInputFormatException | sniff failures: [NoDeclaredBrand]';

    testWidgets('119（SID 不存在）→ 复核出会话码 → 触发自动续期，不弹面板', (tester) async {
      var renewCalls = 0;
      final source = _fileStation(
        probe: () async => DsmErrorCode.sidNotFound,
        renew: () async {
          renewCalls++;
          return _fileStation(probe: () async => DsmErrorCode.sidNotFound);
        },
      );
      final adapter = _FakeFullAdapter();
      await _pumpView(tester, source, factory: () => adapter);

      adapter.failWith(ambiguous);
      await tester.pumpAndSettle();

      expect(renewCalls, 1, reason: '会话语义必须触发既有自动续期链路');
      expect(
        adapter.loaded.length,
        greaterThanOrEqualTo(2),
        reason: '续期后用新直链重建播放项',
      );
      expect(
        find.byType(MediaFallbackPanel),
        findsNothing,
        reason: '续期成功不弹会话失效面板',
      );
      expect(
        find.textContaining(MediaUnavailableReason.sessionExpired.zh),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('106（会话超时）同样归 sessionExpired 并续期', (tester) async {
      var renewCalls = 0;
      final source = _fileStation(
        probe: () async => DsmErrorCode.sessionTimeout,
        renew: () async {
          renewCalls++;
          return _fileStation();
        },
      );
      final adapter = _FakeFullAdapter();
      await _pumpView(tester, source, factory: () => adapter);

      adapter.failWith(ambiguous);
      await tester.pumpAndSettle();

      expect(renewCalls, 1);
      expect(find.byType(MediaFallbackPanel), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('续期失败 → 才回落到既有会话失效面板', (tester) async {
      var renewCalls = 0;
      final source = _fileStation(
        probe: () async => DsmErrorCode.sidNotFound,
        renew: () async {
          renewCalls++;
          throw StateError('拿不到新凭据');
        },
      );
      final adapter = _FakeFullAdapter();
      await _pumpView(tester, source, factory: () => adapter);

      adapter.failWith(ambiguous);
      await tester.pump();
      // **有界重试**：第一次失败后要等指数退避才试第二次；`pumpAndSettle`
      // 不推进没有帧调度的 Timer，所以这里显式按退避时长 pump。
      await tester.pump(mediaSessionRenewDelay(2));
      await tester.pumpAndSettle();

      expect(
        renewCalls,
        kMediaSessionRenewMaxAttempts,
        reason: '有界重试：恰好 kMediaSessionRenewMaxAttempts 次（不会无限循环）',
      );
      expect(
        find.byType(MediaFallbackPanel),
        findsOneWidget,
        reason: '续期失败才给面板（成功时不弹）',
      );
      expect(
        find.textContaining(MediaUnavailableReason.sessionExpired.zh),
        findsOneWidget,
        reason: '会话失效的面板文案（不是"取流被拒"/"编码不支持"）',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('复核出的不是会话码（105 无权限）→ 保持 streamRejected，不续期', (tester) async {
      var renewCalls = 0;
      final source = _fileStation(
        probe: () async => DsmErrorCode.noPermission,
        renew: () async {
          renewCalls++;
          return _fileStation();
        },
      );
      final adapter = _FakeFullAdapter();
      await _pumpView(tester, source, factory: () => adapter);

      adapter.failWith(ambiguous);
      await tester.pumpAndSettle();

      expect(renewCalls, 0, reason: '只有真会话语义才归 sessionExpired');
      expect(find.byType(MediaFallbackPanel), findsOneWidget);
      expect(
        find.textContaining(MediaUnavailableReason.streamRejected.text),
        findsOneWidget,
      );
      expect(
        find.textContaining(MediaUnavailableReason.sessionExpired.zh),
        findsNothing,
        reason: '绝不许把非会话失败误报成"登录过期"',
      );

      await tester.pumpWidget(const SizedBox());
    });

    test('会话语义判定只认 119/106（其余码不许升级）', () {
      expect(isMediaSessionCode(DsmErrorCode.sidNotFound), isTrue);
      expect(isMediaSessionCode(DsmErrorCode.sessionTimeout), isTrue);
      expect(isMediaSessionCode(DsmErrorCode.noPermission), isFalse);
      expect(isMediaSessionCode(105), isFalse);
      expect(isMediaSessionCode(null), isFalse);
      // 「119 绝不隐藏模块」的语义前提：119 归 sessionExpired（只提示、不隐藏），
      // 而不是归"能力缺失/无权限"（那才会隐藏）。此断言钉死分类，不碰 service_registry。
      expect(
        classifyPlayerError(
          Exception('{"error":{"code":119},"success":false}'),
        ),
        MediaUnavailableReason.sessionExpired,
      );
      expect(
        classifyPlayerError(
          Exception('{"error":{"code":105},"success":false}'),
        ),
        isNot(MediaUnavailableReason.sessionExpired),
      );
    });
  });

  // ───────────────────────── ④ 顶栏与面板一致（R7-5-1） ──────────────────
  group('顶栏标题跟随当前播放项（R7-5-1）', () {
    testWidgets('文件预览页：顶栏交给播放器（DA273），标题＝在播那条', (tester) async {
      final t = FakeTransport(const {}, FakeTransport.table);
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final adapter = _FakeFullAdapter();
      final container = ProviderContainer(
        overrides: [
          fileApiProvider.overrideWithValue(FileStationApi(api)),
          mediaPlayerAdapterFactoryProvider.overrideWithValue(() => adapter),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: FilePreviewPage(entry: _entry('r7-long70.mp4')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // ⑦ 文件通道行为零回归：仍走 FileStation.Download + 查询串鉴权
      expect(adapter.loaded.single, contains('SYNO.FileStation.Download'));
      expect(adapter.loaded.single, contains('_sid=FAKE-SID'));
      // 打开时顶栏 = 打开的那条（★ r645/DA244：播放器一接上就按"在播"分支渲染，
      // 所以这里同样是不带容器扩展名的写法；这条断言在 r645 前是 `r7-long70.mp4`）。
      expect(find.text('r7-long70'), findsOneWidget);

      // ★ r658（DA273）改约定：**宿主页不再有 AppBar**（它是布局高度，竖屏/
      //   横屏/画中画都从画面里扣），顶栏改由播放器画（浮层、跟控制条同显隐）。
      //   判据因此换成三条：① 宿主没有 AppBar；② 播放器的顶栏真有"返回＋标题"；
      //   ③ 标题取的是**当前播放项**（不是打开时那一条）。
      expect(
        find.byType(AppBar),
        findsNothing,
        reason: 'DA273：视频预览页不许再有 AppBar（它把画面永久压掉一条）',
      );
      expect(find.byKey(const Key('media-top-bar')), findsOneWidget);
      expect(find.byKey(const Key('media-top-back')), findsOneWidget);
      expect(
        find.byKey(const Key('media-top-title')),
        findsOneWidget,
        reason: 'DA273：标题搬进播放器顶栏，不能就此消失',
      );

      // 播放器仍把**当前播放项**报给宿主（宿主用它做下载/外部打开的动作参数）
      final view = tester.widget<MediaPlayerView>(find.byType(MediaPlayerView));
      expect(
        view.onCurrentSourceChanged,
        isNotNull,
        reason: 'R7-5-1：内嵌播放器必须把当前播放项接出来',
      );
      expect(
        view.hostChrome,
        isTrue,
        reason: 'DA273：宿主页不留 AppBar ⇒ 必须把顶栏交给播放器',
      );
      expect(view.onBack, isNotNull, reason: 'DA273：返回键由播放器顶栏负责');

      // 「当前播放项 → 标题」在音轨/换集之后仍只认一个来源：见下面这条
      // 面板入口用例（AppBar 退场后动作不能丢）。
      expect(find.text('theora.mkv'), findsNothing);
      // 打开时的非播放分支保持原样（文件名带扩展名 ＋ `MP4 · 大小`）
      expect(find.textContaining('MP4'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('DA274：面板开着选字幕，行值当场就变（不吃打开那一刻的快照）',
        (tester) async {
      final t = FakeTransport(const {}, FakeTransport.table);
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final adapter = _FakeFullAdapter();
      adapter.subtitleTrackList.add(
        const MediaTrackInfo(
          id: 'sub:0:0',
          kind: MediaTrackKind.subtitle,
          label: '中文测试',
          language: 'zho',
          codec: 'subrip',
        ),
      );
      final container = ProviderContainer(
        overrides: [
          fileApiProvider.overrideWithValue(FileStationApi(api)),
          mediaPlayerAdapterFactoryProvider.overrideWithValue(() => adapter),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: FilePreviewPage(entry: _entry('r7-long70.mp4')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 打开播放设置面板：此刻还没选字幕 ⇒ 行值只能是 "Subtitles off"
      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-settings-sheet')), findsOneWidget);
      // 行内文字（标签 ＋ 值）拼起来判：不钉英文文案，只钉"是不是那条轨道"
      String rowText() => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const Key('media-settings-row-subtitle')),
              matching: find.byType(Text),
            ),
          )
          .map((w) => w.data ?? '')
          .join('|');
      expect(
        rowText(),
        isNot(contains('中文测试')),
        reason: '还没选字幕时行值不可能是轨道名',
      );

      // ★ 用户在面板里选了内封字幕（原生只回一条 `changes` 事件）
      adapter.chooseSubtitle('sub:0:0');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      // 行值必须**当场**换成轨道名 —— 不许"关掉重开才对"
      expect(
        rowText(),
        contains('中文测试'),
        reason: 'DA274：面板开着时行值必须跟着换，不能停在打开那一刻',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('DA273：AppBar 退场后「下载 / 用其他应用打开」仍可点（搬进 ⋮ 菜单）',
        (tester) async {
      final t = FakeTransport(const {}, FakeTransport.table);
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final adapter = _FakeFullAdapter();
      final container = ProviderContainer(
        overrides: [
          fileApiProvider.overrideWithValue(FileStationApi(api)),
          mediaPlayerAdapterFactoryProvider.overrideWithValue(() => adapter),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: FilePreviewPage(entry: _entry('r7-long70.mp4')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 宿主已经没有 AppBar ⇒ 这两个动作必须真的还能找到（不是"文档说搬了"）
      expect(find.byType(AppBar), findsNothing);
      await tester.tap(find.byKey(const Key('media-more')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('media-more-download')),
        findsOneWidget,
        reason: '下载入口不许随 AppBar 一起消失',
      );
      expect(
        find.byKey(const Key('media-more-external')),
        findsOneWidget,
        reason: '「用其他应用打开」不许随 AppBar 一起消失',
      );

      await tester.pumpWidget(const SizedBox());
    });

    // 「切集后顶栏与面板同时显示当前项（断言两处文本）」的**全屏页**路径由
    // test/media_r5_followup_test.dart 的 group ③ 用例 ① 覆盖（真实 bridge 驱动
    // index 变化 → 断言 AppBar 与 MediaFallbackPanel 两处文本都是 theora.mkv）。
    // 这里补的是 R7-5-1 的**宿主页**路径：内嵌 `MediaPlayerView` 必须把
    // `onCurrentSourceChanged` 接出来，顶栏才会跟着播放器走。
  });
}
