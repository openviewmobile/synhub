// P0：**媒体播到一半 `_sid` 过期 → 原地重建取流 URL 并续播**的承重用例。
//
// 场景（离线，假传输 + 假播放器）：
//   * 首次取流成功（FileStation `Download`，真机实测支持 206 → 能 seek）；
//   * 播放中途播放器回 `119`（会话失效）；
//   * `renew` 走 `SYNO.FileStation.Info/get`（相册走 `SYNO.Foto.Browse.Item/get`），
//     命中既有的"119 → `onSessionExpired` 重登 → 重放"链路 → 用新 `_sid` 重拼直链；
//   * 重建播放项 → seek 回失效前位置 → 继续播，**不弹**会话失效面板。
//
// 硬断言：
//   ① 续播位置 == 失效前位置（容差 = `kMediaSessionResumeTolerance`）；
//   ② 自动恢复路径**不出现**会话失效面板，只给**非阻塞**"已重新连接"提示；
//   ③ 续期**失败**时才出现既有会话失效面板（+ 手动重试入口）；
//   ④ `supportsRange == false` 时**不发生** seek（保持既有面板，不假装能续播）；
//   ⑤ 重试**有界 + 指数退避**（`kMediaSessionRenewMaxAttempts` /
//      `mediaSessionRenewDelay`）：不会无限重试，也不会立刻重试；
//   ⑥ 相册 / 音频 / 视频三条链路各有用例；会话失效**不许**被说成"媒体损坏"。
//
// ⚠️ 夹具里**不写**真实 `_sid` / `SynoToken` 字面量：直链由假传输按登录态生成，
// 断言只比较"新旧 sid 不同"，不落任何凭据明文。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/voice_message.dart'
    show VoicePlaybackErrors, VoicePlayer, voicePlayerProvider;
import 'package:synhub/src/features/media/media_audio_stage.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

// --------------------------------------------------------------- 假播放器

/// 视频假适配器：`load` 会清错（等价 `NativeVideoPlayerAdapter._sendLoad`）
class _RenewAdapter implements MediaPlayerAdapter {
  final _changes = StreamController<void>.broadcast();

  final loaded = <String>[];
  final seeks = <Duration>[];
  int plays = 0;

  Duration _position = Duration.zero;
  final Duration _duration = const Duration(seconds: 100);
  bool _playing = false;
  bool _ready = true;
  double _speed = 1;
  String? _error;

  void setPosition(Duration d) {
    _position = d;
    _emit();
  }

  /// 播放中途报错（会话失效 / 网络 / 编码都走这里）
  void fail(String message) {
    _error = message;
    _emit();
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> load(MediaSource source) async {
    loaded.add(source.uri);
    _error = null; // 生产适配器重载即清错
    _ready = true;
    _emit();
  }

  @override
  Future<void> play() async {
    plays++;
    _playing = true;
    _emit();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _emit();
  }

  @override
  Future<void> seekTo(Duration position) async {
    _position = position;
    seeks.add(position);
    _emit();
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    _emit();
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
  String? get error => _error;

  @override
  double get aspectRatio => 16 / 9;

  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(key: Key('renew-video-surface'), color: Colors.black);

  @override
  Stream<void> get changes => _changes.stream;
}

/// 音频假播放器：复刻 `just_audio` 的 `setUrl` 语义（重载 → 位置回 0）
class _RenewVoicePlayer implements VoicePlayer, VoicePlaybackErrors {
  final _changes = StreamController<void>.broadcast();

  final played = <String>[];
  final seeks = <Duration>[];

  String? _url;
  String? _error;
  bool _hasSource = false;
  Duration _position = Duration.zero;
  final Duration _duration = const Duration(seconds: 100);
  bool _playing = false;
  double _speed = 1;

  void setPosition(Duration d) {
    _position = d;
    _changes.add(null);
  }

  /// 播放中途报错
  void fail(String message) {
    _error = message;
    _changes.add(null);
  }

  @override
  String? get currentUrl => _url;

  @override
  bool get hasSource => _hasSource;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  bool get playing => _playing;

  @override
  double get speed => _speed;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  String? get error => _error;

  @override
  void clearError() => _error = null;

  @override
  Future<void> play(String url) async {
    played.add(url);
    _url = url;
    _hasSource = true;
    _error = null;
    _position = Duration.zero; // setUrl = 重载回到 0
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> resume() async {
    if (!_hasSource) return;
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    _playing = false;
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
    _speed = value;
    _changes.add(null);
  }

  @override
  Future<void> stop() async {
    _hasSource = false;
    _url = null;
    _playing = false;
    _changes.add(null);
  }
}

// --------------------------------------------------------------- 脚手架

/// FileStation / 相册两步都需要的 API 能力表
Map<String, Map<String, dynamic>> _apiTable() => {
  ...FakeTransport.table,
  'SYNO.FileStation.Download': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Streaming': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Download': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  // 续期用的轻量鉴权 ping（官方 `Browse.Item/get`，见 `videoPlaybackInfo`）：
  // 能力表里**必须有**，否则 `DsmWebApi._prepare` 直接抛 `103 apiNotFound`
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
};

/// 建一个已登录的 API。[relogin] = 是否装上"会话过期自动重登"（生产由
/// `SessionController._installRelogin` 安装；测试里手动装，语义一致）。
Future<DsmWebApi> _bootApi(
  FakeTransport transport, {
  bool relogin = true,
}) async {
  final api = DsmWebApi(transport);
  await api.discover();
  await api.login(account: 'u', password: 'p');
  if (relogin) {
    api.onSessionExpired = () async {
      await api.login(account: 'u', password: 'p');
    };
  }
  return api;
}

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/home/$name',
  isDir: false,
  size: 4096,
  mtime: 1758100000,
);

/// 挂 `MediaPlayerView`
Future<void> _pumpView(
  WidgetTester tester,
  MediaSource source, {
  required MediaPlayerAdapterFactory factory,
}) async {
  final container = ProviderContainer(
    overrides: [mediaPlayerAdapterFactoryProvider.overrideWithValue(factory)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(body: MediaPlayerView(source: source)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

/// 挂 `MediaAudioStage`
Future<void> _pumpAudio(
  WidgetTester tester,
  MediaSource source,
  VoicePlayer player,
) async {
  final container = ProviderContainer(
    overrides: [voicePlayerProvider.overrideWithValue(player)],
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
}

bool _withinResumeTolerance(Duration actual, Duration expected) =>
    (actual - expected).abs() <= kMediaSessionResumeTolerance;

/// `SYNO.FileStation.Info/get` 被真正发出去的次数（= 续期尝试次数）
int _infoCalls(FakeTransport t) => t.calls
    .where((c) => c['api'] == 'SYNO.FileStation.Info' && c['method'] == 'get')
    .length;

/// 把**有界重试的退避**走完。
///
/// `pumpAndSettle` 只推进"有帧调度"的时间；退避是纯 Timer（没有 setState），
/// 所以必须显式 `pump(退避时长)` 才能让第 2 次尝试真的发生。
Future<void> _drainRenewBackoff(WidgetTester tester) async {
  for (var attempt = 2; attempt <= kMediaSessionRenewMaxAttempts; attempt++) {
    await tester.pump(mediaSessionRenewDelay(attempt));
  }
  await tester.pumpAndSettle();
}

void main() {
  group('会话失效判定的纯逻辑', () {
    test('shouldRenewSession：会话失效 + 能 seek + 有 renewer 才自动续播', () {
      final renewable = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        supportsRange: true,
        renew: () async => throw UnimplementedError(),
      );
      expect(
        shouldRenewSession(renewable, MediaUnavailableReason.sessionExpired),
        isTrue,
      );
      // 网络中断不续期（复用既有判定）
      expect(
        shouldRenewSession(renewable, MediaUnavailableReason.networkFailed),
        isFalse,
      );
      // 不能 seek → 不能续播（硬约束）
      final noSeek = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi',
        channel: MediaChannel.photos,
        kind: MediaKind.video,
        displayName: 'p.mp4',
        renew: () async => throw UnimplementedError(),
      );
      expect(
        shouldRenewSession(noSeek, MediaUnavailableReason.sessionExpired),
        isFalse,
      );
      // 没有 renewer
      final noRenew = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        supportsRange: true,
      );
      expect(
        shouldRenewSession(noRenew, MediaUnavailableReason.sessionExpired),
        isFalse,
      );
    });

    test('DSM 106（会话超时）在错误码上下文里 → sessionExpired', () {
      expect(
        classifyPlayerError(Exception('{"error":{"code":106}}')),
        MediaUnavailableReason.sessionExpired,
      );
      // 裸 `106`（位置/字节数）**不许**被当成会话失效
      expect(
        classifyPlayerError(Exception('position=106000 out of range')),
        MediaUnavailableReason.decodeFailed,
      );
    });

    test('重试策略是**有界 + 指数退避**（不会无限循环、也不会立刻重试）', () {
      expect(kMediaSessionRenewMaxAttempts, 2, reason: '有界：最多 2 次');
      // 第一次立刻试（用户已经在等画面回来）
      expect(mediaSessionRenewDelay(1), Duration.zero);
      // 之后按 2 的幂增长（指数退避）
      expect(mediaSessionRenewDelay(2), kMediaSessionRenewBackoffBase);
      expect(
        mediaSessionRenewDelay(3),
        kMediaSessionRenewBackoffBase * 2,
        reason: '退避必须真的递增（否则不叫指数退避）',
      );
      expect(
        mediaSessionRenewDelay(4) > mediaSessionRenewDelay(3),
        isTrue,
        reason: '单调递增',
      );
    });
  });

  group('视频链路：FileStation（supportsRange = true）', () {
    testWidgets('播放中途 119 → 自动续期新地址 + seek 回原位置续播（不弹会话面板）', (tester) async {
      final transport = FakeTransport({}, _apiTable());
      // 续期时第一次 Info 命中 119 → 既有链路自动重登 → 重放成功
      transport.failTimes['SYNO.FileStation.Info.get'] = 119;
      final fs = FileStationApi(await _bootApi(transport));
      final source = resolveFileStationSource(
        displayName: 'clip.mp4',
        kind: MediaKind.video,
        fs: fs,
        path: '/home/clip.mp4',
      );
      expect(source.supportsRange, isTrue);
      expect(source.renew, isNotNull);
      final oldUri = source.uri;

      final adapter = _RenewAdapter();
      await _pumpView(tester, source, factory: () => adapter);
      expect(adapter.loaded.single, oldUri, reason: '首次取流成功');

      // 播到 42s，然后会话失效
      adapter.setPosition(const Duration(seconds: 42));
      await tester.pump();
      adapter.fail('{"error":{"code":119},"success":false}');
      await tester.pumpAndSettle();

      // ① 续播位置 == 失效前位置（容差内）
      expect(adapter.seeks, isNotEmpty, reason: '必须 seek 回原位置');
      expect(
        _withinResumeTolerance(adapter.seeks.last, const Duration(seconds: 42)),
        isTrue,
        reason:
            '续播位置 ${adapter.seeks.last} 与 42s 的偏差必须 ≤ '
            '$kMediaSessionResumeTolerance',
      );
      // 新地址：同一个文件，sid 已换新
      expect(adapter.loaded, hasLength(2), reason: '重建一次播放项');
      expect(adapter.loaded.last, isNot(oldUri));
      final oldSid = Uri.parse(oldUri).queryParameters['_sid'];
      final newSid = Uri.parse(adapter.loaded.last).queryParameters['_sid'];
      expect(newSid, isNotNull, reason: '新地址必须带 `_sid`');
      expect(newSid, isNot(oldSid), reason: '续期必须换成新的会话');
      // ② 自动恢复路径：**不出现**会话失效面板
      expect(find.byType(MediaFallbackPanel), findsNothing);
      expect(find.textContaining('会话不存在'), findsNothing);
      expect(adapter.playing, isTrue, reason: '续播后继续在放');
      // 让"已重新连接"提示条自然消失（不留待触发的 Timer）
      await tester.pump(kMediaReconnectedNoticeDuration);
      await tester.pumpAndSettle();
    });

    testWidgets('续期失败（拿不到凭据）→ 有界重试用尽才出面板 + 手动重试入口', (tester) async {
      final transport = FakeTransport({}, _apiTable());
      // **持续** 119：没有装上自动重登（= 没有可用的账号口令）时，会话是真的死了
      // —— 每次 Info 都失败（`failTimes` 只失败一次，第二次就"活了"，
      // 那模拟的是"抖一下"而不是"拿不到凭据"）。
      transport.failures['SYNO.FileStation.Info.get'] = 119;
      final fs = FileStationApi(await _bootApi(transport, relogin: false));
      final source = resolveFileStationSource(
        displayName: 'clip.mp4',
        kind: MediaKind.video,
        fs: fs,
        path: '/home/clip.mp4',
      );

      final adapter = _RenewAdapter();
      await _pumpView(tester, source, factory: () => adapter);
      adapter.setPosition(const Duration(seconds: 42));
      await tester.pump();
      adapter.fail('{"error":{"code":119},"success":false}');
      await tester.pump();
      await _drainRenewBackoff(tester);

      // ③ 续期失败 → 既有"会话不存在，请重新登录"面板 + 回退入口
      expect(find.byType(MediaFallbackPanel), findsOneWidget);
      expect(find.textContaining('会话不存在'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsOneWidget);
      expect(adapter.seeks, isEmpty, reason: '没拿到新地址就不许 seek');
      // **有界**：恰好 kMediaSessionRenewMaxAttempts 次自动尝试（不会无限重试）
      expect(_infoCalls(transport), kMediaSessionRenewMaxAttempts);
      // **不静默停住**：面板上给明确的手动重试入口 + 说明
      expect(find.byKey(const Key('media-session-retry')), findsOneWidget);
      expect(
        find.byKey(const Key('media-session-resume-hint')),
        findsOneWidget,
      );
    });

    testWidgets('会话过期绝不被说成"媒体损坏 / 编码不支持"', (tester) async {
      // 没有 renewer 的来源 → 直接落到会话失效面板（不经过自动重试），
      // 专门盯"分类/文案有没有被说成媒体损坏"
      final source = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi?_sid=OLD',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        supportsRange: true,
      );
      final adapter = _RenewAdapter();
      await _pumpView(tester, source, factory: () => adapter);
      adapter.fail('{"error":{"code":119},"success":false}');
      await tester.pumpAndSettle();

      // 面板解释句 = 会话语义；**不许**出现"解码器 / 编码不支持"这类"媒体坏了"的话
      expect(find.textContaining('会话不存在'), findsOneWidget);
      expect(find.textContaining('解码器'), findsNothing);
      expect(find.textContaining('编码'), findsNothing);
    });

    testWidgets('没有 renewer（可 seek 但无重解析能力）→ 不假装能续播，保持面板', (tester) async {
      final source = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi?_sid=OLD',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        supportsRange: true,
        // renew 缺省 = null
      );
      final adapter = _RenewAdapter();
      await _pumpView(tester, source, factory: () => adapter);
      adapter.setPosition(const Duration(seconds: 42));
      await tester.pump();
      adapter.fail('{"error":{"code":119},"success":false}');
      await tester.pumpAndSettle();

      expect(find.byType(MediaFallbackPanel), findsOneWidget);
      expect(find.textContaining('会话不存在'), findsOneWidget);
      expect(adapter.seeks, isEmpty);
      // 没有可重试的恢复路径 → 不给假按钮
      expect(find.byKey(const Key('media-session-retry')), findsNothing);
    });

    testWidgets('网络中断仍走网络提示，不触发续期（判定复用同一层）', (tester) async {
      var renewCalls = 0;
      final source = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        supportsRange: true,
        renew: () async {
          renewCalls++;
          throw StateError('网络中断不该走到续期');
        },
      );
      final adapter = _RenewAdapter();
      await _pumpView(tester, source, factory: () => adapter);
      adapter.fail('ERROR_CODE_IO_NETWORK_CONNECTION_FAILED: timeout');
      await tester.pumpAndSettle();

      expect(renewCalls, 0, reason: '网络中断不是会话失效，不许续期');
      expect(find.textContaining('连不上文件地址'), findsOneWidget);
      expect(adapter.seeks, isEmpty);
    });

    testWidgets('有界重试 + 指数退避：第一次瞬时失败 → 退避后第二次成功续播', (tester) async {
      var renewCalls = 0;
      late final MediaSource freshSource;
      freshSource = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi?_sid=NEW',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        supportsRange: true,
        renew: () async => freshSource,
      );
      final source = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi?_sid=OLD',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        supportsRange: true,
        renew: () async {
          renewCalls++;
          // 第一次 = "重登刚发出、服务端会话还没生效"这类**瞬时**失败
          if (renewCalls == 1) throw StateError('会话尚未生效（瞬时）');
          return freshSource;
        },
      );
      final adapter = _RenewAdapter();
      await _pumpView(tester, source, factory: () => adapter);
      adapter.setPosition(const Duration(seconds: 42));
      await tester.pump();
      adapter.fail('{"error":{"code":119},"success":false}');
      await tester.pump();
      await tester.pump();

      // 第一次**立刻**试过（已失败），此刻正在退避：还没有第二次、也还没 seek
      expect(renewCalls, 1, reason: '第一次不许有退避延迟');
      expect(adapter.loaded, hasLength(1));
      expect(adapter.seeks, isEmpty);

      // 退避时长到点 → 第二次尝试成功
      await tester.pump(kMediaSessionRenewBackoffBase);
      await tester.pumpAndSettle();
      expect(renewCalls, 2, reason: '退避后必须真的重试一次');
      expect(adapter.loaded, hasLength(2));
      expect(adapter.loaded.last, contains('_sid=NEW'));
      expect(
        _withinResumeTolerance(adapter.seeks.last, const Duration(seconds: 42)),
        isTrue,
        reason: '重试成功后仍要 seek 回失效前位置（不是从头开始）',
      );
      expect(find.byType(MediaFallbackPanel), findsNothing);
    });

    testWidgets('续期成功给**非阻塞**提示（不弹窗、播放器仍在、自动消失）', (tester) async {
      var calls = 0;
      late final MediaSource freshSource;
      freshSource = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi?_sid=NEW',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        supportsRange: true,
        renew: () async => freshSource,
      );
      final source = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi?_sid=OLD',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        supportsRange: true,
        renew: () async {
          calls++;
          return freshSource;
        },
      );
      final adapter = _RenewAdapter();
      await _pumpView(tester, source, factory: () => adapter);
      adapter.setPosition(const Duration(seconds: 42));
      await tester.pump();
      adapter.fail('{"error":{"code":119},"success":false}');
      await tester.pumpAndSettle();
      expect(calls, 1);

      // 提示条出现，且**不打断**：播放器画面与控制仍在（不是回退面板）
      expect(
        find.byKey(const Key('media-session-reconnected')),
        findsOneWidget,
      );
      expect(find.textContaining('已重新连接'), findsOneWidget);
      expect(find.byKey(const Key('renew-video-surface')), findsOneWidget);
      expect(find.byType(MediaFallbackPanel), findsNothing);
      expect(adapter.playing, isTrue);

      // 自动消失（不需要用户点任何东西）
      await tester.pump(kMediaReconnectedNoticeDuration);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-session-reconnected')), findsNothing);
    });

    testWidgets('自动重试用尽 → 手动重试成功即续播（绝不静默停住）', (tester) async {
      var renewCalls = 0;
      var sessionDead = true;
      late final MediaSource freshSource;
      freshSource = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi?_sid=NEW',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        supportsRange: true,
        renew: () async => freshSource,
      );
      final source = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi?_sid=OLD',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        supportsRange: true,
        renew: () async {
          renewCalls++;
          if (sessionDead) throw StateError('会话仍然失效');
          return freshSource;
        },
      );
      final adapter = _RenewAdapter();
      await _pumpView(tester, source, factory: () => adapter);
      adapter.setPosition(const Duration(seconds: 42));
      await tester.pump();
      adapter.fail('{"error":{"code":119},"success":false}');
      await tester.pump();
      await _drainRenewBackoff(tester);

      // 有界：两次都失败 → 面板（不是黑屏卡住）
      expect(renewCalls, kMediaSessionRenewMaxAttempts);
      expect(find.byType(MediaFallbackPanel), findsOneWidget);
      expect(find.byKey(const Key('media-session-retry')), findsOneWidget);

      // 用户手动重试（此时会话已经能被重登拿回）→ 续播回原位
      sessionDead = false;
      await tester.tap(find.byKey(const Key('media-session-retry')));
      await tester.pumpAndSettle();
      expect(renewCalls, kMediaSessionRenewMaxAttempts + 1);
      expect(find.byType(MediaFallbackPanel), findsNothing);
      expect(adapter.loaded, hasLength(2));
      expect(
        _withinResumeTolerance(adapter.seeks.last, const Duration(seconds: 42)),
        isTrue,
        reason: 'seeks=${adapter.seeks}',
      );
      expect(adapter.playing, isTrue);
    });
  });

  group('音频链路：FileStation（supportsRange = true）', () {
    testWidgets('播放中途 119 → 换新地址 + seek 回原位置续播（不弹会话面板）', (tester) async {
      final transport = FakeTransport({}, _apiTable());
      transport.failTimes['SYNO.FileStation.Info.get'] = 119;
      final fs = FileStationApi(await _bootApi(transport));
      final source = resolveFileStationSource(
        displayName: 'song.mp3',
        kind: MediaKind.audio,
        fs: fs,
        path: '/home/song.mp3',
      );
      final oldUri = source.uri;

      final player = _RenewVoicePlayer();
      await _pumpAudio(tester, source, player);
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(player.played.single, oldUri);

      // 播到 42s，然后会话失效
      player.setPosition(const Duration(seconds: 42));
      await tester.pump();
      player.fail('{"error":{"code":119},"success":false}');
      await tester.pumpAndSettle();

      expect(player.played, hasLength(2), reason: 'just_audio 换 URL 必须重载');
      expect(player.played.last, isNot(oldUri));
      expect(
        _withinResumeTolerance(player.seeks.last, const Duration(seconds: 42)),
        isTrue,
        reason: 'seeks=${player.seeks}',
      );
      expect(player.position, const Duration(seconds: 42));
      expect(find.byType(MediaFallbackPanel), findsNothing);
      expect(find.textContaining('会话不存在'), findsNothing);
      // 续期成功 → 音频侧也给**非阻塞**提示（不弹窗、不打断，自动消失）
      expect(
        find.byKey(const Key('audio-session-reconnected')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('audio-play-pause')), findsOneWidget);
      await tester.pump(kMediaReconnectedNoticeDuration);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-session-reconnected')), findsNothing);
    });

    testWidgets('续期失败 → 音频侧同样有界重试后面板（不无限、不静默）', (tester) async {
      final transport = FakeTransport({}, _apiTable());
      transport.failures['SYNO.FileStation.Info.get'] = 119;
      final fs = FileStationApi(await _bootApi(transport, relogin: false));
      final source = resolveFileStationSource(
        displayName: 'song.mp3',
        kind: MediaKind.audio,
        fs: fs,
        path: '/home/song.mp3',
      );
      final player = _RenewVoicePlayer();
      await _pumpAudio(tester, source, player);
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      player.setPosition(const Duration(seconds: 42));
      await tester.pump();
      player.fail('{"error":{"code":119},"success":false}');
      await tester.pump();
      await _drainRenewBackoff(tester);

      expect(find.byType(MediaFallbackPanel), findsOneWidget);
      expect(find.textContaining('会话不存在'), findsOneWidget);
      expect(player.seeks, isEmpty);
      expect(_infoCalls(transport), kMediaSessionRenewMaxAttempts);
      expect(find.byKey(const Key('media-session-retry')), findsOneWidget);
    });
  });

  group('相册链路：Download 腿（可 seek + 已接 renewer）', () {
    testWidgets('播放中途 119 → 重登 ping + 重拼直链 + seek 回原位置续播（不弹面板）', (
      tester,
    ) async {
      final transport = FakeTransport({}, _apiTable());
      // 续期用的**轻量鉴权 ping** = 官方播放素材请求 `SYNO.Foto.Browse.Item/get`
      // （`videoPlaybackInfo`，相册选画质时已在用）。第一次命中 119 →
      // 既有链路自动重登 → 重放成功 → 用新 `_sid` 重拼 Download 直链。
      transport.failTimes['SYNO.Foto.Browse.Item.get'] = 119;
      final api = await _bootApi(transport);
      final source = resolvePhotosSource(
        displayName: 'p.mp4',
        kind: MediaKind.video,
        itemId: '9317',
        foto: FotoApi(api),
      );
      // Download 腿 Range 真机已证（206）→ 可 seek → 必须能原地续期
      expect(source.supportsRange, isTrue);
      expect(source.renew, isNotNull, reason: '可 seek 的相册腿也要能续期');
      final oldUri = source.uri;
      expect(Uri.parse(oldUri).queryParameters['_sid'], isNotNull);

      final adapter = _RenewAdapter();
      await _pumpView(tester, source, factory: () => adapter);
      adapter.setPosition(const Duration(seconds: 42));
      await tester.pump();
      adapter.fail('{"error":{"code":119},"success":false}');
      await tester.pumpAndSettle();

      expect(adapter.loaded, hasLength(2), reason: '重登后重建一次播放项');
      expect(adapter.loaded.last, isNot(oldUri));
      final newSid = Uri.parse(adapter.loaded.last).queryParameters['_sid'];
      expect(newSid, isNotNull, reason: '新地址必须带 `_sid`');
      expect(
        newSid,
        isNot(Uri.parse(oldUri).queryParameters['_sid']),
        reason: '未重登就拿不到新会话 —— 不许用旧 _sid 重拼',
      );
      expect(
        _withinResumeTolerance(adapter.seeks.last, const Duration(seconds: 42)),
        isTrue,
        reason: 'seeks=${adapter.seeks}（相册也要回原位置，不是从头开始）',
      );
      expect(find.byType(MediaFallbackPanel), findsNothing);
      expect(adapter.playing, isTrue);
      await tester.pump(kMediaReconnectedNoticeDuration);
      await tester.pumpAndSettle();
    });

    testWidgets('续期 ping 拿不到新会话 → 有界重试后回面板（相册侧也不静默）', (tester) async {
      final transport = FakeTransport({}, _apiTable());
      // 持续 119 且**没有**自动重登 → 会话真的死了
      transport.failures['SYNO.Foto.Browse.Item.get'] = 119;
      final api = await _bootApi(transport, relogin: false);
      final source = resolvePhotosSource(
        displayName: 'p.mp4',
        kind: MediaKind.video,
        itemId: '9317',
        foto: FotoApi(api),
      );
      final adapter = _RenewAdapter();
      await _pumpView(tester, source, factory: () => adapter);
      adapter.setPosition(const Duration(seconds: 42));
      await tester.pump();
      adapter.fail('{"error":{"code":119},"success":false}');
      await tester.pump();
      await _drainRenewBackoff(tester);

      expect(find.byType(MediaFallbackPanel), findsOneWidget);
      expect(find.textContaining('会话不存在'), findsOneWidget);
      expect(adapter.seeks, isEmpty);
      expect(
        transport.calls
            .where(
              (c) =>
                  c['api'] == 'SYNO.Foto.Browse.Item' && c['method'] == 'get',
            )
            .length,
        kMediaSessionRenewMaxAttempts,
        reason: '有界：恰好两次自动尝试',
      );
    });

    testWidgets('supportsRange=false 即使有 renewer 也绝不 seek（硬约束承重）', (
      tester,
    ) async {
      var renewCalls = 0;
      late MediaSource source;
      source = MediaSource(
        uri: 'https://fake.test/webapi/entry.cgi?api=SYNO.Foto.Streaming',
        channel: MediaChannel.photos,
        kind: MediaKind.video,
        displayName: 'p.mp4',
        // 故意把 renewer 装上：证明"不续播"来自 supportsRange 这条**硬约束**，
        // 而不是仅仅因为相册没实现 renew。
        renew: () async {
          renewCalls++;
          return source;
        },
      );
      final adapter = _RenewAdapter();
      await _pumpView(tester, source, factory: () => adapter);
      adapter.setPosition(const Duration(seconds: 42));
      await tester.pump();
      adapter.fail('{"error":{"code":119},"success":false}');
      await tester.pumpAndSettle();

      expect(adapter.seeks, isEmpty, reason: '不可 seek 的来源不许发生 seek');
      expect(renewCalls, 0, reason: '不支持 Range → 不许续期');
      expect(find.byType(MediaFallbackPanel), findsOneWidget);
      expect(find.textContaining('会话不存在'), findsOneWidget);
      // 不能 seek → 没有"原位置"可回 → 连手动重试入口都不给
      expect(find.byKey(const Key('media-session-retry')), findsNothing);
    });
  });
}
