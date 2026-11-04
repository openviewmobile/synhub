// Phase 5 语音消息（60s 录音 / 播放）离线验证。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/attachment_view.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/voice_message.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 假录音器：记录调用，stop 时返回预先准备好的文件
class FakeRecorder implements VoiceRecorder, VoiceAmplitudeSource {
  FakeRecorder({this.permission = true, this.result});

  bool permission;
  String? result;
  String? startedPath;
  int stops = 0;
  int cancels = 0;

  /// 当前音量（0..1）—— 波形动效测试直接改它
  double amp = 0.2;

  @override
  Future<double> amplitude() async => amp;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> start(String path) async => startedPath = path;

  @override
  Future<String?> stop() async {
    stops++;
    return result;
  }

  @override
  Future<void> cancel() async => cancels++;
}

/// 假播放器
class FakePlayer implements VoicePlayer {
  final _changes = StreamController<void>.broadcast();
  final played = <String>[];
  int pauses = 0;
  int stops = 0;
  int resumes = 0;
  Duration _position = Duration.zero;

  @override
  String? currentUrl;

  @override
  bool get hasSource => _hasSource;
  bool _hasSource = false;

  void setPosition(Duration d) {
    _position = d;
    _changes.add(null);
  }

  @override
  Duration get position => _position;

  @override
  Duration? duration = const Duration(seconds: 10);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> play(String url) async {
    played.add(url);
    currentUrl = url;
    _hasSource = true;
    playing = true;
    _changes.add(null);
  }

  /// 从当前位置继续（不重载来源）
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
    currentUrl = null;
    _changes.add(null);
  }

  @override
  Future<void> stop() async {
    stops++;
    playing = false;
    currentUrl = null;
    _hasSource = false;
    _changes.add(null);
  }

  /// 拖进度：记下来（文件预览页的滑块要断言"真的 seek 了"）
  final seeks = <Duration>[];

  @override
  bool playing = false;

  @override
  double speed = 1;

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    seeks.add(position);
    _changes.add(null);
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
  }
}

void main() {
  group('文件名 / 时长格式', () {
    test('voiceFileName 必须能被服务端认出是语音', () {
      final name = voiceFileName(DateTime.fromMillisecondsSinceEpoch(1234));
      expect(name, 'voiceMessage-1234.aac');
      expect(isVoiceFileName(name), isTrue);
      // 服务端只在「以 voiceMessage 开头且 MIME 含 aac」时才读 voice_msg_length
      expect(isVoiceFileName('voiceMessage-1.aac'), isTrue);
      expect(isVoiceFileName('recording.aac'), isFalse);
      expect(isVoiceFileName('voiceMessage-1.m4a'), isFalse);
    });

    test('formatVoiceDuration', () {
      expect(formatVoiceDuration(0), '0:00');
      expect(formatVoiceDuration(7), '0:07');
      expect(formatVoiceDuration(59), '0:59');
      expect(formatVoiceDuration(60), '1:00');
    });

    test('上限 60 秒（AudioRecordPresenter 的 60000L）', () {
      expect(kVoiceMaxSeconds, 60);
    });
  });

  group('sendVoiceMessage（控制器）', () {
    test('带 voice_msg_length、文件名是 voiceMessage*.aac、message 为空', () async {
      final h = await bootChat();
      final tmp = File(
        '${Directory.systemTemp.path}/voice-${DateTime.now().microsecondsSinceEpoch}.aac',
      )..writeAsBytesSync([1, 2, 3, 4]);
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });

      h.transport.responses['SYNO.Chat.Post.create'] = {
        'post_id': 7001,
        'channel_id': 5,
        'creator_id': 14,
        'create_at': 1,
        'type': 'file',
        'file_props': {
          'name': 'voiceMessage-1.aac',
          'type': 'aac',
          'size': 4,
          'is_voice_msg': true,
          'voice_msg_length': 5,
        },
      };
      final ok = await h.ctrl.sendVoiceMessage(
        channelId: 5,
        filePath: tmp.path,
        seconds: 5,
      );
      expect(ok, isTrue);

      final call = h.transport.calls.lastWhere((c) => c['file_name'] != null);
      expect(call['file_name'], matches(r'^voiceMessage-\d+\.aac$'));
      expect(call['voice_msg_length'], '5');
      expect(call['message'], '', reason: '语音不该带正文');
      expect(call['type'], 'file');
      // 上传用的 MIME 必须是 audio/aac 的一种写法
      expect('${call['file_mime'] ?? 'audio/aac'}', contains('aac'));

      // 本地库里的这条消息应被识别成语音
      final post = await h.container.read(chatStoreProvider).postById(5, 7001);
      expect(post, isNotNull);
      expect(post!.attachments.single.isVoiceMessage, isTrue);
      expect(post.attachments.single.voiceMsgLength, 5);
    });

    test('上传完把录音临时文件删掉', () async {
      final h = await bootChat();
      final tmp = File(
        '${Directory.systemTemp.path}/voice-tmp-${DateTime.now().microsecondsSinceEpoch}.aac',
      )..writeAsBytesSync([1, 2, 3]);
      h.transport.responses['SYNO.Chat.Post.create'] = {
        'post_id': 7002,
        'channel_id': 5,
        'creator_id': 14,
        'create_at': 1,
        'type': 'file',
      };
      await h.ctrl.sendVoiceMessage(
        channelId: 5,
        filePath: tmp.path,
        seconds: 3,
      );
      expect(tmp.existsSync(), isFalse);
    });

    test('失败时也清掉临时文件（不留在磁盘上）', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.create'] = 411;
      final tmp = File(
        '${Directory.systemTemp.path}/voice-fail-${DateTime.now().microsecondsSinceEpoch}.aac',
      )..writeAsBytesSync([9]);
      final ok = await h.ctrl.sendVoiceMessage(
        channelId: 5,
        filePath: tmp.path,
        seconds: 2,
      );
      expect(ok, isFalse);
      expect(tmp.existsSync(), isFalse);
      final sync = h.container.read(chatSessionControllerProvider);
      expect(sync.pendingFiles, isEmpty);
    });
  });

  group('录音浮层', () {
    Future<void> pumpSheet(
      WidgetTester tester,
      FakeRecorder rec, {
      FakePlayer? player,
    }) async {
      _lastResult = null;
      final container = ProviderContainer(
        overrides: [
          voiceRecorderProvider.overrideWithValue(rec),
          // 单测里没有 path_provider 平台通道，临时文件直接给个假路径
          voiceTempFileProvider.overrideWithValue(
            () async => File('/tmp/voiceMessage-test.aac'),
          ),
          if (player != null) voicePlayerProvider.overrideWithValue(player),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async =>
                    _lastResult = await showVoiceRecorderSheet(context),
                child: const Text('录'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('没权限时给出提示且不能发送', (tester) async {
      final rec = FakeRecorder(permission: false);
      await pumpSheet(tester, rec);
      expect(find.text('没有麦克风权限'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull, reason: '没权限时"发送"要禁用');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });

    testWidgets('录音 → 停止进试听 → 点发送才返回文件（不再边录边发）', (tester) async {
      final rec = FakeRecorder(result: '/tmp/a.aac');
      await pumpSheet(tester, rec);
      expect(find.text('0:00'), findsOneWidget);
      expect(rec.startedPath, isNotNull);
      expect(rec.startedPath, contains('voiceMessage'));

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('0:01'), findsOneWidget);
      // ★ 录音中不给"发送"：必须先进试听页
      expect(find.text('发送'), findsNothing);

      await tester.tap(find.text('停止录音'));
      await tester.pumpAndSettle();
      expect(rec.stops, 1);
      expect(_lastResult, isNull, reason: '停止录音 ≠ 发送');
      expect(find.text('试听'), findsOneWidget);

      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(_lastResult?.path, '/tmp/a.aac');
      expect(_lastResult?.seconds, 1);
    });

    testWidgets('录音中点取消：cancel 录音且不返回结果', (tester) async {
      final rec = FakeRecorder(result: '/tmp/a.aac');
      await pumpSheet(tester, rec);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(rec.cancels, 1);
      expect(rec.stops, 0);
      expect(_lastResult, isNull);
    });

    testWidgets('不到 1 秒就停 = 当作取消（别让用户试听空音频）', (tester) async {
      final rec = FakeRecorder(result: '/tmp/a.aac');
      await pumpSheet(tester, rec);
      await tester.tap(find.text('停止录音'));
      await tester.pumpAndSettle();
      expect(_lastResult, isNull);
    });

    testWidgets('★ 录满 60 秒只停录、不自动发送（进试听页由用户决定）', (tester) async {
      final rec = FakeRecorder(result: '/tmp/b.aac');
      await pumpSheet(tester, rec);
      for (var i = 0; i < kVoiceMaxSeconds; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(rec.stops, 1);
      expect(_lastResult, isNull, reason: '到上限不许自动发送');
      expect(find.text('试听'), findsOneWidget);

      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(_lastResult?.seconds, kVoiceMaxSeconds);
    });

    testWidgets('试听：播放按钮把本地录音交给播放器（file:// URI）', (tester) async {
      final rec = FakeRecorder(result: '/tmp/a.aac');
      final player = FakePlayer();
      await pumpSheet(tester, rec, player: player);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('停止录音'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('试听'));
      await tester.pump();
      expect(player.played, hasLength(1));
      expect(player.played.single, startsWith('file://'));

      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();
      expect(_lastResult, isNull);
      expect(player.stops, greaterThan(0), reason: '关掉浮层要停掉试听');
    });

    testWidgets('录音波形跟着音量变（真动效，不是固定动画）', (tester) async {
      final rec = FakeRecorder(result: '/tmp/a.aac')..amp = 0.02;
      await pumpSheet(tester, rec);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      double topBar() => tester
          .widgetList<Container>(
            find.descendant(
              of: find.byKey(const Key('voice-waveform')),
              matching: find.byType(Container),
            ),
          )
          .map((c) => c.constraints?.maxHeight ?? 0)
          .fold<double>(0, (a, b) => a > b ? a : b);

      final low = topBar();
      rec.amp = 1.0;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      final high = topBar();
      expect(find.byKey(const Key('voice-waveform')), findsOneWidget);
      expect(high, greaterThan(low), reason: '音量变大时波形必须更高');
    });
  });

  group('语音气泡', () {
    PostDto voicePost() => PostDto.fromJson(const {
      'post_id': 8001,
      'channel_id': 5,
      'creator_id': 14,
      'create_at': 1,
      'type': 'file',
      'file_props': {
        'name': 'voiceMessage-1.aac',
        'type': 'aac',
        'size': 4000,
        'is_voice_msg': true,
        'voice_msg_length': 65,
      },
    });

    testWidgets('点一下开始播放（用带 _sid 的下载地址）', (tester) async {
      final player = FakePlayer();
      final h = await bootChat(
        moreOverrides: [voicePlayerProvider.overrideWithValue(player)],
      );
      final post = voicePost();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: VoiceBubble(
                post: post,
                prop: post.attachments.single,
                api: ChatApi(h.api),
              ),
            ),
          ),
        ),
      );
      // 时长显示 1:05
      expect(find.text('1:05'), findsOneWidget);
      // HUD：未播放时不再画 0% 进度条（改成按时长成比例的固定长度条）
      expect(find.byType(LinearProgressIndicator), findsNothing);

      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(player.played, hasLength(1));
      expect(player.played.single, contains('_sid='));
      expect(player.played.single, contains('post_id=8001'));

      // 播放中：进度条按位置更新
      player.setPosition(const Duration(seconds: 5));
      await tester.pump();
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.5, 0.01));

      // 再点一下暂停
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(player.pauses, 1);
    });

    testWidgets('播放失败显示提示而不是崩', (tester) async {
      final player = _ThrowingPlayer();
      final h = await bootChat(
        moreOverrides: [voicePlayerProvider.overrideWithValue(player)],
      );
      final post = voicePost();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: VoiceBubble(
                post: post,
                prop: post.attachments.single,
                api: ChatApi(h.api),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      await tester.pump();
      expect(find.text('播放失败'), findsOneWidget);
    });

    // ★ DA193：语音条在**窄气泡**里溢出 —— 时长被画到气泡圆角外。
    //   根因：那条 Row 全是定宽（图标 + 最多 200dp 的条 + 时长），而 Flutter **不裁** Row 的溢出，
    //   最后一个孩子就画到父容器外面（真机实测 `1:00` 的尾字符压在深青底上 = 1.08:1）。
    PostDto narrowPost(int seconds) => PostDto.fromJson({
          'post_id': 8002,
          'channel_id': 5,
          'creator_id': 14,
          'create_at': 1,
          'type': 'file',
          'file_props': {
            'name': 'voiceMessage-2.aac',
            'type': 'aac',
            'size': 4000,
            'is_voice_msg': true,
            'voice_msg_length': seconds,
          },
        });

    Widget narrowHost(double width, PostDto post, ChatHarness h) => MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: VoiceBubble(
                  post: post,
                  prop: post.attachments.single,
                  api: ChatApi(h.api),
                ),
              ),
            ),
          ),
        );

    testWidgets('DA193 ① 260dp 窄气泡里 60 秒语音不溢出', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = await bootChat(moreOverrides: [
        voicePlayerProvider.overrideWithValue(FakePlayer()),
      ]);
      final post = narrowPost(60);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: narrowHost(260, post, h),
        ),
      );
      expect(tester.takeException(), isNull,
          reason: '语音条在窄气泡里溢出了（时长会被画到气泡外）');
      expect(find.text('1:00'), findsOneWidget);
    });

    testWidgets('DA193 ② 时长文本完整落在气泡横向范围内', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = await bootChat(moreOverrides: [
        voicePlayerProvider.overrideWithValue(FakePlayer()),
      ]);
      final post = narrowPost(60);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: narrowHost(260, post, h),
        ),
      );
      final bubble = tester.getRect(find.byType(InkWell).first);
      final label = tester.getRect(find.text('1:00'));
      expect(label.left, greaterThanOrEqualTo(bubble.left - 0.5),
          reason: '时长跑到气泡左边外面了');
      expect(label.right, lessThanOrEqualTo(bubble.right + 0.5),
          reason: '时长跑到气泡右边外面了（DA193 的原始症状）');
    });

    // ★ DA194：短语音的条太窄（7 秒 ≈ 94dp），`Voice message` 折成两行
    //   ⇒ 同一会话里语音气泡高矮不一。判据是"标签只有一行"，不是"看起来还行"。
    // ★ DA194：短语音的条太窄（旧下限 80 ⇒ 7 秒只有 ~94dp），**真机上**
    //   `Voice message` 会折成两行 ⇒ 同一会话里语音气泡高矮不一。
    //   ★ 这条缺陷**不能用测试字体量**：测试字体下「语音消息」4 个字 56dp 就放得下，
    //     永远绿（AGENTS §2.0.55–64 ③「测试字体不是真机字体」）。
    //     所以判据改成两条结构化断言：宽度下限 + 标签单行。
    testWidgets('DA194 ① 语音条宽度下限：短语音也要放得下一行标签', (tester) async {
      expect(VoiceBubble.barWidthFor(7), greaterThanOrEqualTo(kVoiceBarMin));
      expect(VoiceBubble.barWidthFor(0), kVoiceBarMin);
      // 「时长越长条越长」不能被下限吃掉
      expect(VoiceBubble.barWidthFor(60), 200);
      expect(VoiceBubble.barWidthFor(30), greaterThan(VoiceBubble.barWidthFor(7)));
    });

    testWidgets('DA194 ② 标签必须是单行（maxLines 1 + 不换行）', (tester) async {
      final h = await bootChat(moreOverrides: [
        voicePlayerProvider.overrideWithValue(FakePlayer()),
      ]);
      final post = narrowPost(7);
      await tester.binding.setSurfaceSize(const Size(420, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: narrowHost(260, post, h),
        ),
      );
      final label = tester.widget<Text>(find
          .descendant(
            of: find.byType(VoiceBubble),
            matching: find.byType(Text),
          )
          .first);
      expect(label.maxLines, 1, reason: '标签没有钉死单行，窄条里会折行（DA194）');
      expect(label.softWrap, isFalse, reason: '标签允许换行（DA194）');
    });


    // ★ DA195：真机上播完 7 秒语音后，按钮**永久停在"暂停 + 空进度条"**
    //   —— 因为 `currentUrl` 播完仍在（just_audio 走 stop+seek(0)，不清源），
    //   只看 `active` 就一直当成"在播"。判据必须问播放器的「已到片尾」状态。
    testWidgets('DA195 ① 片尾状态必须显示"播放"而不是"暂停"', (tester) async {
      final player = _EndedPlayer();
      final h = await bootChat(moreOverrides: [
        voicePlayerProvider.overrideWithValue(player),
      ]);
      final post = narrowPost(7);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: narrowHost(320, post, h),
        ),
      );
      // 载入过、且已经在片尾（currentUrl 仍在 = 真机上的状态）。
      // ★ 这里必须用**同一个 URL**：否则 `active` 一开始就是 false，
      //   不管有没有 ended 判定都会画播放图标 —— 那就是构造性假绿。
      player.currentUrl = ChatApi(h.api).fileUrl(post.postId);
      player.didEnd = true;
      player.notify();
      await tester.pump();

      expect(find.byIcon(Icons.pause_circle_filled_rounded), findsNothing,
          reason: '片尾还画暂停图标 ⇒ 用户以为还在播（DA195）');
      expect(find.byIcon(Icons.play_circle_fill_rounded), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing,
          reason: '片尾不该画进度条（位置已被复位成 0，看起来像卡住）');
    });

    testWidgets('DA195 ② 片尾再点一次要真的重播', (tester) async {
      final player = _EndedPlayer();
      final h = await bootChat(moreOverrides: [
        voicePlayerProvider.overrideWithValue(player),
      ]);
      final post = narrowPost(7);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: narrowHost(320, post, h),
        ),
      );
      player.currentUrl = ChatApi(h.api).fileUrl(post.postId);
      player.didEnd = true;
      player.notify();
      await tester.pump();

      await tester.tap(find.byType(InkWell).first);
      await tester.pump();
      await tester.pump();
      expect(player.played, isNotEmpty, reason: '片尾点击没有触发播放');
      expect(player.cleared, greaterThan(0), reason: '没有清掉"已在片尾"标记');
    });
  });
}

RecordedVoice? _lastResult;

class _ThrowingPlayer implements VoicePlayer {
  @override
  String? get currentUrl => null;

  @override
  bool get hasSource => false;

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => null;

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<void> play(String url) async => throw StateError('boom');

  @override
  Future<void> resume() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  bool get playing => false;

  @override
  double get speed => 1;

  @override
  Future<void> setSpeed(double speed) async {}
}

/// 假播放器：能模拟「已载入过、且已播到片尾」的真机状态（DA195）。
class _EndedPlayer implements VoicePlayer, VoicePlaybackEnded {
  final _c = StreamController<void>.broadcast();
  @override
  String? currentUrl;
  bool didEnd = false;
  int cleared = 0;
  final List<String> played = [];

  void notify() => _c.add(null);

  @override
  bool get ended => didEnd;
  @override
  void clearEnded() {
    didEnd = false;
    cleared++;
  }

  @override
  bool get hasSource => currentUrl != null;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => const Duration(seconds: 7);
  @override
  Stream<void> get changes => _c.stream;
  @override
  bool get playing => false;
  @override
  double get speed => 1;
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> play(String url) async {
    played.add(url);
    currentUrl = url;
    didEnd = false;
    notify();
  }
  @override
  Future<void> resume() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
}
