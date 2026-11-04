// 内置播放器的**页面层**离线测试：假播放器适配器 + 假传输。
//
// 关注四件事（任务的硬性要求）：
//   1. 播放 / 暂停 / 进度 / 时间的**交互真的接上了**（不是只画了个控件）；
//   2. 拖进度条**真的调了 seek**（音频走 `VoicePlayer.seek`，视频走适配器 `seekTo`）；
//   3. 拖不动的来源**把滑块置灰并说明**（Drive 写死 `Accept-Ranges: none`）；
//   4. 播放器出错 → **可读文案 + "交给系统应用"回退入口**（编码不支持 / 证书失败 /
//      空 URL / 隧道空串 / 未连接）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/voice_message.dart'
    show VoicePlayer, voicePlayerProvider;
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/media/media_audio_stage.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_reason_text.dart';
import 'package:synhub/src/features/media/media_source.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 假播放器适配器：记录调用，状态可由测试直接摆布
class FakeMediaAdapter implements MediaPlayerAdapter {
  final _changes = StreamController<void>.broadcast();

  final loaded = <String>[];
  int plays = 0;
  int pauses = 0;
  int disposes = 0;
  final seeks = <Duration>[];
  final speeds = <double>[];

  Duration _position = Duration.zero;
  Duration? _duration = const Duration(seconds: 100);
  bool _playing = false;
  bool _ready = true;
  double _speed = 1;
  String? _error;

  /// 载入时抛这个异常（测"初始化失败 → 回退"）
  Object? throwOnLoad;

  set ready(bool v) => _ready = v;
  set error(String? v) => _error = v;
  set duration(Duration? v) => _duration = v;

  void emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void setPosition(Duration d) {
    _position = d;
    emit();
  }

  @override
  Future<void> load(MediaSource source) async {
    if (throwOnLoad != null) throw throwOnLoad!;
    loaded.add(source.uri);
  }

  @override
  Future<void> play() async {
    plays++;
    _playing = true;
    emit();
  }

  @override
  Future<void> pause() async {
    pauses++;
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
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    speeds.add(speed);
    emit();
  }

  @override
  Future<void> dispose() async {
    disposes++;
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
  String? get error => _error;

  @override
  double get aspectRatio => 16 / 9;

  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(key: Key('fake-video-surface'), color: Colors.black);

  @override
  Stream<void> get changes => _changes.stream;
}

/// 假音频播放器（`VoicePlayer`）
class FakeVoicePlayer implements VoicePlayer {
  final _changes = StreamController<void>.broadcast();
  final played = <String>[];
  final seeks = <Duration>[];
  final speeds = <double>[];
  int pauses = 0;
  int stops = 0;
  int resumes = 0;
  Duration _position = Duration.zero;
  Object? throwOnPlay;

  @override
  String? currentUrl;

  /// 有没有载入过来源（生产实现 `JustAudioVoicePlayer.hasSource` 的等价物）
  @override
  bool get hasSource => _hasSource;
  bool _hasSource = false;

  @override
  bool playing = false;

  @override
  double speed = 1;

  @override
  Duration? duration = const Duration(seconds: 100);

  @override
  Duration get position => _position;

  @override
  Stream<void> get changes => _changes.stream;

  void setPosition(Duration d) {
    _position = d;
    _changes.add(null);
  }

  @override
  Future<void> play(String url) async {
    if (throwOnPlay != null) throw throwOnPlay!;
    played.add(url);
    currentUrl = url;
    _hasSource = true;
    // ***刻意复刻真机缺陷***：`play(url)` 等价 just_audio `setUrl` = 重新载入来源
    // → **位置回到 0**（R4 A2：点播放会新建 ExoPlayer 从 00:02 重来）。
    // 拖动/暂停之后要续播必须走 `resume()`，用例靠这条承重。
    _position = Duration.zero;
    playing = true;
    _changes.add(null);
  }

  /// 从当前位置继续（不重载来源、**不动 position**）
  @override
  Future<void> resume() async {
    if (!_hasSource) return;
    resumes++;
    playing = true;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    pauses++;
    playing = false;
    _changes.add(null);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    seeks.add(position);
    _changes.add(null);
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
    speeds.add(value);
  }

  @override
  Future<void> stop() async {
    stops++;
    playing = false;
    _hasSource = false;
    _changes.add(null);
  }
}

MediaSource _playable({
  MediaKind kind = MediaKind.video,
  MediaChannel channel = MediaChannel.fileStation,
  bool supportsRange = true,
  String uri =
      'https://fake.test/webapi/entry.cgi?api=SYNO.FileStation.Download',
  String name = 'clip.mp4',
}) => MediaSource(
  uri: uri,
  channel: channel,
  kind: kind,
  displayName: name,
  supportsRange: supportsRange,
);

MediaSource _blocked(
  MediaUnavailableReason reason, {
  MediaKind kind = MediaKind.video,
}) => MediaSource(
  uri: '',
  channel: MediaChannel.fileStation,
  kind: kind,
  displayName: 'clip.mp4',
  fallbackReason: reason,
);

FileEntryDto _entry(String name, {String? path, int size = 4096}) =>
    FileEntryDto(
      name: name,
      path: path ?? '/home/$name',
      isDir: false,
      size: size,
      mtime: 1758100000,
    );

/// 挂 `MediaPlayerView`
Future<ProviderContainer> _pumpView(
  WidgetTester tester,
  MediaSource source, {
  required MediaPlayerAdapterFactory factory,
  VoidCallback? onOpenExternal,
  VoidCallback? onDownload,
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
            onOpenExternal: onOpenExternal,
            onDownload: onDownload,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return container;
}

/// 直接取 `Slider` 的回调（比 `tester.drag` 精确：能钉死"seek 到这个毫秒"）
Future<void> _dragSliderTo(WidgetTester tester, Key key, double value) async {
  final slider = tester.widget<Slider>(find.byKey(key));
  slider.onChangeStart!(value);
  slider.onChanged!(value);
  // `onChangeEnd` 的类型是 `void Function(double)`，里面是 async —— 用
  // pumpAndSettle 把 seek/续播这两步跑完
  slider.onChangeEnd!(value);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    // 假适配器里的 StreamController 由 `dispose` 关；没 dispose 的用例自己 emit
  });

  group('时长格式化', () {
    test('mm:ss / h:mm:ss', () {
      expect(formatMediaDuration(Duration.zero), '00:00');
      expect(formatMediaDuration(const Duration(seconds: 9)), '00:09');
      expect(
        formatMediaDuration(const Duration(minutes: 3, seconds: 7)),
        '03:07',
      );
      expect(
        formatMediaDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
    });
  });

  group('播放器错误分类（只影响文案，不影响要不要回退）', () {
    test('TLS/证书类错误 → certificateUntrusted', () {
      expect(
        classifyPlayerError(Exception('SSL handshake failed')),
        MediaUnavailableReason.certificateUntrusted,
      );
      expect(
        classifyPlayerError(
          Exception('java.security.cert.CertPathValidatorException'),
        ),
        MediaUnavailableReason.certificateUntrusted,
      );
    });

    test('编码/容器不支持 → codecUnsupported（文案要区别于"网络失败"）', () {
      expect(
        classifyPlayerError(Exception('Decoder init failed: OMX.google')),
        MediaUnavailableReason.codecUnsupported,
      );
      expect(
        classifyPlayerError(
          Exception('ERROR_CODE_DECODING_FORMAT_UNSUPPORTED: V_THEORA'),
        ),
        MediaUnavailableReason.codecUnsupported,
      );
      expect(
        classifyPlayerError(Exception('V_THEORA is not supported')),
        MediaUnavailableReason.codecUnsupported,
      );
    });

    test('会话/鉴权失效（DSM 119 / 401 / CSRF）→ sessionExpired', () {
      expect(
        classifyPlayerError(
          Exception('{"error":{"code":119},"success":false}'),
        ),
        MediaUnavailableReason.sessionExpired,
      );
      expect(
        classifyPlayerError(Exception('HTTP 401 Unauthorized')),
        MediaUnavailableReason.sessionExpired,
      );
      expect(
        classifyPlayerError(Exception('missing SynoToken: CSRF rejected')),
        MediaUnavailableReason.sessionExpired,
      );
    });

    test('Media3 的"响应不像媒体"兜底不再冒充 codecUnsupported', () {
      // ⚠️ 这两串与"真正的编码不支持"在文本上无法区分：服务端对缺鉴权的下载
      // URL 回 HTTP 200 + JSON 119，Media3 嗅探失败抛的就是它们。以前归到
      // codecUnsupported = 真机头号误报（正常 H.264 被说成"编码不支持"）。
      // 现在取流鉴权问题由 media_source 的查询串自检**在进播放器前**拦成
      // sessionExpired，所以这里退回中性的 decodeFailed。
      expect(
        classifyPlayerError(
          Exception('UnrecognizedInputFormatException: no suitable extractor'),
        ),
        MediaUnavailableReason.decodeFailed,
      );
      expect(
        classifyPlayerError(
          Exception(
            'None of the available extractors (A, B) could read the stream',
          ),
        ),
        MediaUnavailableReason.decodeFailed,
      );
    });

    test('网络类错误 → networkFailed', () {
      expect(
        classifyPlayerError(
          Exception('ERROR_CODE_IO_NETWORK_CONNECTION_FAILED: timeout'),
        ),
        MediaUnavailableReason.networkFailed,
      );
      expect(
        classifyPlayerError(Exception('SocketException: Connection refused')),
        MediaUnavailableReason.networkFailed,
      );
      // "连不上"里**不许**混进"服务端明确拒绝"：`io_` 这个子串太宽，
      // 所以 HTTP 分支必须排在网络分支**前面**（R5 相册取流失败就是被它吃掉的）。
      expect(
        classifyPlayerError(
          Exception(
            'ERROR_CODE_IO_BAD_HTTP_STATUS(2006) | InvalidResponseCodeException | http=404',
          ),
        ),
        isNot(MediaUnavailableReason.networkFailed),
      );
    });

    test('取流被服务端拒绝（HTTP 4xx/5xx / 响应不是媒体）→ streamRejected', () {
      // 这三条与"编码不支持"和"网络中断"**都必须不同**：
      // 处置是改取流形态 / 换通道 / 查服务端权限（docs/media-streaming-diagnosis.md）。
      expect(
        classifyPlayerError(
          Exception(
            'ERROR_CODE_IO_BAD_HTTP_STATUS(2006) | Source error | http=404',
          ),
        ),
        MediaUnavailableReason.streamRejected,
      );
      expect(
        classifyPlayerError(
          Exception(
            'ERROR_CODE_IO_UNSPECIFIED(2000) | InvalidResponseCodeException | http=500 | Status: 500',
          ),
        ),
        MediaUnavailableReason.streamRejected,
      );
      // SynologyPhotos 的取流处理器自己会写 `Status: 404 Not Found`
      expect(
        classifyPlayerError(
          Exception('ERROR_CODE_IO_FILE_NOT_FOUND(2005) | file_not_found'),
        ),
        MediaUnavailableReason.streamRejected,
      );
      // 200 + HTML 登录页 / 不是媒体：容器解析在服务端就失败
      expect(
        classifyPlayerError(
          Exception('ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED(3003) | html'),
        ),
        MediaUnavailableReason.streamRejected,
      );
      // 与另外两类互斥（文案不同才叫"可区分"）
      for (final text in const [
        'ERROR_CODE_IO_BAD_HTTP_STATUS(2006) | http=404',
        'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED(3003)',
      ]) {
        final r = classifyPlayerError(Exception(text));
        expect(r, isNot(MediaUnavailableReason.codecUnsupported), reason: text);
        expect(r, isNot(MediaUnavailableReason.networkFailed), reason: text);
        expect(r.text, isNot(contains('编码')), reason: text);
        expect(r.text, isNot(contains('连不上')), reason: text);
      }
    });

    test('裸数字不许被当成 HTTP 状态码（看门狗"错误串不放数字"的同一个教训）', () {
      // `position=404000` 这类**读数**不许被判成"服务端拒绝"。
      //
      // ⚠️ 如实记录一个**既有**的粗糙处（本批不改，避免扩大改动面）：网络分支里
      // 的 `text.contains('404')` 会把 `position=404000`（含 "4040"）算成
      // networkFailed。本批新增的 `streamRejected` 判定用的是**带上下文**的
      // `_httpStatusCode`（`http=404` / `status: 500`），不认裸数字，所以
      // "读数"至少不会被误判成"服务端拒绝取流"。
      final reading = classifyPlayerError(
        Exception('position=404000 duration=1040000'),
      );
      expect(reading, isNot(MediaUnavailableReason.streamRejected));
      expect(reading, isNot(MediaUnavailableReason.codecUnsupported));
      // `io_` 兜底仍然算网络类（与修复前一致）
      expect(
        classifyPlayerError(
          Exception('ERROR_CODE_IO_UNSPECIFIED(2000) size=404'),
        ),
        MediaUnavailableReason.networkFailed,
      );
    });

    test('认不出来 / null → decodeFailed（默认兜底）', () {
      expect(
        classifyPlayerError(Exception('something odd happened')),
        MediaUnavailableReason.decodeFailed,
      );
      expect(classifyPlayerError(null), MediaUnavailableReason.decodeFailed);
    });

    test('三类失败的用户文案**互相不同**（取流被拒 / 编码不支持 / 网络中断）', () {
      // 这三类在 R5 真机上被混成同一句"播放失败"，用户和排查都被带偏。
      // 文案层必须能把它们分开（`streamRejected` 的 ARB key 待父 agent 落库，
      // 现在走 `dataText` 的中文回落，所以断言用中文回落文本）。
      const kind = MediaKind.video;
      final rejected = mediaReasonText(
        AppTextZh(),
        MediaUnavailableReason.streamRejected,
        kind,
      );
      final codec = mediaReasonText(
        AppTextZh(),
        MediaUnavailableReason.codecUnsupported,
        kind,
      );
      final network = mediaReasonText(
        AppTextZh(),
        MediaUnavailableReason.networkFailed,
        kind,
      );
      expect(
        rejected.detail,
        contains(MediaUnavailableReason.streamRejected.zh),
      );
      expect(rejected.detail, isNot(contains('编码')));
      expect(rejected.detail, isNot(contains('连不上')));
      expect(rejected.detail, isNot(codec.detail));
      expect(rejected.detail, isNot(network.detail));
      expect(rejected.title, codec.title, reason: '标题都还是"播放失败"');
      // "交给系统应用"这句按 kind 复用既有 key（视频侧更具体）
      expect(rejected.detail, contains('系统播放器'));
    });
  });

  group('视频播放视图（假适配器）', () {
    testWidgets('载入后自动播放，显示画面、时长与当前时间', (tester) async {
      final adapter = FakeMediaAdapter();
      adapter.setPosition(const Duration(seconds: 5));
      await _pumpView(tester, _playable(), factory: () => adapter);

      expect(adapter.loaded.single, contains('SYNO.FileStation.Download'));
      expect(adapter.plays, 1, reason: '点开就播');
      expect(find.byKey(const Key('fake-video-surface')), findsOneWidget);
      expect(find.text('00:05'), findsOneWidget);
      expect(find.text('01:40'), findsOneWidget, reason: '总时长 100 秒');
    });

    testWidgets('播放/暂停按钮真的调用 play/pause', (tester) async {
      final adapter = FakeMediaAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      await tester.tap(find.byKey(const Key('media-play-pause')));
      await tester.pump();
      expect(adapter.pauses, 1);

      await tester.tap(find.byKey(const Key('media-play-pause')));
      await tester.pump();
      expect(adapter.plays, 2, reason: '第一次是自动播放');
    });

    testWidgets('拖动进度条真的 seek 到对应位置（并续播）', (tester) async {
      final adapter = FakeMediaAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      expect(adapter.playing, isTrue);

      await _dragSliderTo(tester, const Key('media-progress'), 60 * 1000);
      expect(adapter.seeks.single, const Duration(seconds: 60));
      expect(adapter.plays, 2, reason: '拖之前在播 → 松手后要接着播');
      expect(adapter.pauses, 1, reason: '拖的时候先暂停，别和 seek 抢位置');
      expect(find.text('01:00'), findsOneWidget);
    });

    // Bug 3 的视频侧：seek → pause → play 必须**不重载**（同一个 FakeMediaAdapter
    // 实例，loaded 只有一条）并从拖动后的位置继续。
    testWidgets('视频 seek(50%) → pause → play：不重载来源，从 50% 继续（Bug 3）', (
      tester,
    ) async {
      final adapter = FakeMediaAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      expect(adapter.loaded, hasLength(1));

      await _dragSliderTo(tester, const Key('media-progress'), 50 * 1000);
      expect(adapter.position, const Duration(seconds: 50));

      await tester.tap(find.byKey(const Key('media-play-pause')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('media-play-pause')));
      await tester.pump();

      expect(adapter.loaded, hasLength(1), reason: '播放器实例不许被重建');
      expect(adapter.position, const Duration(seconds: 50));
      expect(find.text('00:50'), findsOneWidget);
    });

    // Bug 3 的边界语义（明确并测试）：拖到/播到文件末尾后再点播放 = **从头开始**。
    testWidgets('拖到文件末尾后再点播放 → 回到 0 重新播（末尾语义）', (tester) async {
      final adapter = FakeMediaAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      // 先暂停，再把位置摆到末尾（position == duration）
      await tester.tap(find.byKey(const Key('media-play-pause')));
      await tester.pump();
      adapter.setPosition(const Duration(seconds: 100));
      await tester.pump();

      await tester.tap(find.byKey(const Key('media-play-pause')));
      await tester.pump();
      await tester.pump();
      expect(adapter.seeks.last, Duration.zero, reason: '末尾再播 = 从 0 开始');
      expect(adapter.position, Duration.zero);
      expect(find.text('00:00'), findsOneWidget);
    });

    testWidgets('倍速菜单能改播放速率', (tester) async {
      final adapter = FakeMediaAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('media-speed')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2.0x').last);
      await tester.pumpAndSettle();
      expect(adapter.speeds, contains(2.0));
    });

    testWidgets('全屏按钮推一个播放页（同一个来源）', (tester) async {
      final adapters = <FakeMediaAdapter>[];
      await _pumpView(
        tester,
        _playable(name: '旅途.mp4'),
        factory: () {
          final a = FakeMediaAdapter();
          adapters.add(a);
          return a;
        },
      );
      await tester.tap(find.byKey(const Key('media-fullscreen')));
      await tester.pumpAndSettle();
      expect(find.byType(MediaPlayerPage), findsOneWidget);
      // ★ r645（DA245）：全屏页顶栏不写容器扩展名（与预览页一致）
      expect(find.text('旅途'), findsOneWidget);
      expect(find.text('旅途.mp4'), findsNothing);
      // ★ r647（DA247）：全屏页**借**预览页的适配器（原生只有一个 player/texture）
      expect(adapters, hasLength(1), reason: '全屏页借同一个适配器，不再新建');
    });

    testWidgets('播放器初始化失败（编码不支持）→ 可读文案 + 交给系统应用', (tester) async {
      final adapter = FakeMediaAdapter()
        ..throwOnLoad = Exception('Decoder init failed');
      var opened = 0;
      await _pumpView(
        tester,
        _playable(),
        factory: () => adapter,
        onOpenExternal: () => opened++,
      );
      expect(find.text('播放失败'), findsOneWidget);
      expect(find.textContaining('视频用系统播放器看最稳'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsOneWidget);
      await tester.tap(find.text('用其他应用打开'));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('证书握手失败 → 明确说"服务器证书不受信任"', (tester) async {
      final adapter = FakeMediaAdapter()
        ..throwOnLoad = Exception('SSL handshake aborted');
      await _pumpView(tester, _playable(), factory: () => adapter);
      expect(find.text('服务器证书不受信任'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsOneWidget);
    });

    testWidgets('运行中报错（errorDescription）也会切到回退面板', (tester) async {
      final adapter = FakeMediaAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      adapter.error = 'UnrecognizedInputFormatException';
      adapter.emit();
      // 广播流的投递在微任务里 → 要 pumpAndSettle 才能看到重建
      await tester.pumpAndSettle();
      expect(find.text('播放失败'), findsOneWidget);
    });
  });

  group('来源不能播时（枚举原因 → 文案 + 回退，不碰播放器）', () {
    testWidgets('隧道未启动（空串根因）→ "隧道未启动（tcpPort == 0）"', (tester) async {
      final adapter = FakeMediaAdapter();
      await _pumpView(
        tester,
        _blocked(MediaUnavailableReason.tunnelUnavailable),
        factory: () => adapter,
      );
      expect(find.text('隧道未启动（tcpPort == 0）'), findsOneWidget);
      expect(adapter.loaded, isEmpty, reason: '空 URL 绝不能塞给播放器');
    });

    testWidgets('空 URL → 打不开 + 未知原因', (tester) async {
      final adapter = FakeMediaAdapter();
      await _pumpView(
        tester,
        _blocked(MediaUnavailableReason.emptyUrl),
        factory: () => adapter,
      );
      expect(find.text('打不开这个文件'), findsOneWidget);
      expect(adapter.loaded, isEmpty);
    });

    testWidgets('未连接 → "尚未连接服务器"', (tester) async {
      await _pumpView(
        tester,
        _blocked(MediaUnavailableReason.notConnected),
        factory: FakeMediaAdapter.new,
      );
      expect(find.text('尚未连接服务器'), findsOneWidget);
    });

    testWidgets('Drive 视频（无 Range）→ 不内嵌，交系统应用', (tester) async {
      final adapter = FakeMediaAdapter();
      await _pumpView(
        tester,
        _blocked(
          MediaUnavailableReason.rangeUnsupported,
          kind: MediaKind.video,
        ),
        factory: () => adapter,
      );
      expect(find.textContaining('视频用系统播放器看最稳'), findsOneWidget);
      expect(find.textContaining('下载后用其他应用打开'), findsOneWidget);
      expect(adapter.loaded, isEmpty);
    });
  });

  group('音频播放舞台（假 VoicePlayer）', () {
    Future<FakeVoicePlayer> pumpAudio(
      WidgetTester tester,
      MediaSource source, {
      FakeVoicePlayer? player,
    }) async {
      final p = player ?? FakeVoicePlayer();
      final container = ProviderContainer(
        overrides: [voicePlayerProvider.overrideWithValue(p)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: MediaAudioStage(entry: _entry('song.mp3'), source: source),
            ),
          ),
        ),
      );
      await tester.pump();
      return p;
    }

    testWidgets('播放/暂停，用的是带 _sid 的直链', (tester) async {
      final player = await pumpAudio(
        tester,
        _playable(
          kind: MediaKind.audio,
          name: 'song.mp3',
          uri:
              'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download&_sid=S1',
        ),
      );
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(player.played.single, contains('_sid=S1'));

      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(player.pauses, 1);
    });

    testWidgets('拖动进度条真的 seek（这是本批修的 bug）', (tester) async {
      final player = await pumpAudio(
        tester,
        _playable(kind: MediaKind.audio, name: 'song.mp3'),
      );
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      await _dragSliderTo(tester, const Key('audio-progress'), 42 * 1000);
      expect(player.seeks.single, const Duration(seconds: 42));
      // 拖之前在播 → 松手续播，且**不许重载来源**（重载会把位置打回 0）
      expect(player.played, hasLength(1), reason: '不许第二次 play(url)=重载');
      expect(player.resumes, 1, reason: '续播走 resume()');
      expect(player.position, const Duration(seconds: 42));
    });

    // ── Bug 3（真机 R4 A2）：拖动/暂停之后"从新位置续播" ────────────────────
    testWidgets('seek(50%) → pause → play：从 50% 继续，而不是回到 0（Bug 3）', (
      tester,
    ) async {
      final player = await pumpAudio(
        tester,
        _playable(kind: MediaKind.audio, name: 'audiotone.wav'),
      );
      // 先正常起播
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(player.played, hasLength(1));
      // 拖到 50%（100s 的文件 → 50s）
      await _dragSliderTo(tester, const Key('audio-progress'), 50 * 1000);
      expect(player.seeks.single, const Duration(seconds: 50));
      expect(player.playing, isTrue, reason: '拖之前在播 → 松手继续');

      // 暂停，再点播放（拖动时已经 pause 过一次，所以这里是第 2 次）
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(player.pauses, 2);
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();

      expect(
        player.played,
        hasLength(1),
        reason: '点播放时 URL 已被 just_audio 载入 → 绝不能再次 setUrl（会新建 ExoPlayer）',
      );
      expect(player.resumes, greaterThanOrEqualTo(1));
      expect(
        player.position,
        const Duration(seconds: 50),
        reason: '续播必须落在拖动后的位置，而不是 0',
      );
      expect(find.text('00:50'), findsOneWidget);
    });

    testWidgets('拖到文件末尾后再播放 → 语义是"从头开始"（与视频侧一致）', (tester) async {
      final player = await pumpAudio(
        tester,
        _playable(kind: MediaKind.audio, name: 'short.wav'),
      );
      player.duration = const Duration(seconds: 5);
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      // 拖到末尾：生产里 just_audio 会进 completed → stop() + seek(0)
      await _dragSliderTo(tester, const Key('audio-progress'), 5 * 1000);
      expect(player.seeks.last, const Duration(seconds: 5));
      // 模拟生产监听里的 completed 处理
      player.setPosition(Duration.zero);
      player.playing = false;
      await tester.pump();
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(player.resumes, greaterThanOrEqualTo(1));
      expect(
        player.position,
        Duration.zero,
        reason: '播完/拖到末尾之后重播 = 从 0 开始（明确语义）',
      );
    });

    testWidgets('拖不动的来源：滑块禁用 + 说明文案', (tester) async {
      await pumpAudio(
        tester,
        _playable(
          kind: MediaKind.audio,
          channel: MediaChannel.drive,
          supportsRange: false,
          name: 'song.mp3',
        ),
      );
      final slider = tester.widget<Slider>(
        find.byKey(const Key('audio-progress')),
      );
      expect(slider.onChanged, isNull, reason: '不给假希望');
      expect(find.byKey(const Key('audio-no-seek-hint')), findsOneWidget);
      expect(find.textContaining('下载后用其他应用打开'), findsOneWidget);
    });

    testWidgets('播放失败 → 回退面板（含"交给系统应用"）', (tester) async {
      final player = FakeVoicePlayer()..throwOnPlay = Exception('boom');
      await pumpAudio(
        tester,
        _playable(kind: MediaKind.audio, name: 'song.mp3'),
        player: player,
      );
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(find.text('播放失败'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsOneWidget);
    });

    testWidgets('倍速菜单能改速率', (tester) async {
      final player = await pumpAudio(
        tester,
        _playable(kind: MediaKind.audio, name: 'song.mp3'),
      );
      await tester.tap(find.byKey(const Key('audio-speed')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x').last);
      await tester.pumpAndSettle();
      expect(player.speeds, contains(1.5));
    });
  });

  group('文件预览页的分发（视频进内置播放器 / 不支持就回退）', () {
    Future<({FakeMediaAdapter adapter, ProviderContainer c})> pumpPreview(
      WidgetTester tester,
      FileEntryDto entry, {
      String? bytesUrl,
      bool connected = true,
      FakeMediaAdapter? adapter,
    }) async {
      final t = FakeTransport(const {}, FakeTransport.table);
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final a = adapter ?? FakeMediaAdapter();
      final container = ProviderContainer(
        overrides: [
          fileApiProvider.overrideWithValue(
            connected ? FileStationApi(api) : null,
          ),
          mediaPlayerAdapterFactoryProvider.overrideWithValue(() => a),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: FilePreviewPage(entry: entry, bytesUrl: bytesUrl),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      return (adapter: a, c: container);
    }

    testWidgets('NAS 上的 mp4 → 内置播放器（流式，不整段下载）', (tester) async {
      final boot = await pumpPreview(tester, _entry('clip.mp4'));
      expect(boot.adapter.loaded.single, contains('SYNO.FileStation.Download'));
      expect(boot.adapter.loaded.single, contains('_sid=FAKE-SID'));
      expect(find.byKey(const Key('preview-video-stage')), findsOneWidget);
    });

    testWidgets('Drive 里的 mp4 → 不进播放器，明确回退', (tester) async {
      final boot = await pumpPreview(
        tester,
        _entry('clip.mp4', path: 'drive:7788'),
        bytesUrl: 'https://nas/webapi/entry.cgi?api=SYNO.SynologyDrive.Files',
      );
      expect(boot.adapter.loaded, isEmpty);
      expect(find.textContaining('视频用系统播放器看最稳'), findsOneWidget);
      expect(find.byKey(const Key('preview-video-stage')), findsOneWidget);
      expect(find.text('用其他应用打开'), findsOneWidget);
    });

    testWidgets('未连接 → 说清"尚未连接服务器"，不白屏', (tester) async {
      final boot = await pumpPreview(
        tester,
        _entry('clip.mp4'),
        connected: false,
      );
      expect(boot.adapter.loaded, isEmpty);
      // 这句和"打不开这个文件"在**同一个 Text**（回退舞台的 why 是一整段）
      expect(find.textContaining('尚未连接服务器'), findsOneWidget);
    });

    testWidgets('NAS 上的 mp3 → 音频舞台（可拖）', (tester) async {
      await pumpPreview(tester, _entry('song.mp3'));
      expect(find.byType(MediaAudioStage), findsOneWidget);
    });

    // ---- 「系统解码器不支持的格式」的统一处置（本批新增）------------------
    // 用户报告「wma 这种音频格式不支持」：**FileStation 直链**里的 WMA 不在
    // AudioStation 音乐库，没有服务端转码通道 → 必须给**明确提示** +
    // 「用其他应用打开」，**不得**落进泛化的"播放失败"，也不得进内置音频舞台
    // （进舞台只会在起播时抛 `None of the available extractors…`）。
    testWidgets('NAS 上的 wma → formatUnsupported 明确提示 + 用其他应用打开', (
      tester,
    ) async {
      final boot = await pumpPreview(tester, _entry('song.wma'));
      expect(boot.adapter.loaded, isEmpty);
      expect(find.byType(MediaAudioStage), findsNothing);
      // 这句来自 `mediaReasonText(..., formatUnsupported, ...)` 的中文回落
      // （ARB key `mediaErrFormatUnsupported` 待父 agent 落库，见
      //  docs/audio-codec-fallback.md §6）
      expect(find.textContaining('这种格式通常不被系统解码器支持'), findsOneWidget);
      // 与另外几类**不同**：不是"编码不支持"、不是"连不上"、不是"会话过期"
      expect(find.textContaining('系统解码器不支持这个文件的编码'), findsNothing);
      expect(find.textContaining('连不上文件地址'), findsNothing);
      expect(find.textContaining('会话不存在'), findsNothing);
      expect(find.text('用其他应用打开'), findsOneWidget);
    });

    // 每个格式一条用例：`pumpPreview` 每次都要一棵干净的 widget 树
    // （同一测试里 pump 两次会留下 pending timer，Flutter 会判失败）。
    for (final name in const ['x.ape', 'x.wv', 'x.dsf', 'x.dff']) {
      testWidgets('NAS 上的 $name → 同样走明确提示（不止 WMA）', (tester) async {
        await pumpPreview(tester, _entry(name));
        expect(
          find.textContaining('这种格式通常不被系统解码器支持'),
          findsOneWidget,
          reason: name,
        );
        expect(find.byType(MediaAudioStage), findsNothing, reason: name);
        expect(find.text('用其他应用打开'), findsOneWidget, reason: name);
      });
    }

    for (final name in const ['a.mp3', 'a.flac', 'a.aac', 'a.m4a']) {
      testWidgets('NAS 上的 $name 直链**照旧**进音频舞台（零误报）', (tester) async {
        await pumpPreview(tester, _entry(name));
        expect(find.byType(MediaAudioStage), findsOneWidget, reason: name);
        expect(
          find.textContaining('这种格式通常不被系统解码器支持'),
          findsNothing,
          reason: name,
        );
      });
    }
  });
}
