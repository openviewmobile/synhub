// Phase 5 真机验收（语音）：真录音 → 上传 → 服务端 `is_voice_msg`/时长 → 真播放。
//
//   # ⚠️ 这台机器上每次重装 APK 都会重置运行时权限 → 系统权限框会把测试卡死，
//   #    所以要**一边跑测试一边**在后台反复 grant（见 tool/grant_mic.sh）：
//   ./tool/grant_mic.sh <device> 20 &
//   flutter test integration_test/phase5_voice_test.dart -d <device> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_LIVE_POST=true
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/voice_message.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _postRaw = String.fromEnvironment('SYNO_LIVE_POST');
final _doPost = _postRaw == '1' || _postRaw == 'true';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 5 真机：录 3 秒 → 上传 → 服务端认成语音 → 播放', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);
    expect(container.read(chatSessionControllerProvider).phase,
        ChatSyncPhase.ready);
    final store = container.read(chatStoreProvider);
    final channels = await store.allChannels();
    final target = channels.firstWhere((c) => !c.encrypted && c.isJoined,
        orElse: () => channels.first);
    debugPrint('[p5v] 频道=#${target.channelId}');

    // ---------- ① 真录音（走真实 RecordVoiceRecorder） ----------
    final recorder = container.read(voiceRecorderProvider);
    debugPrint('[p5v] 检查麦克风权限…');
    // 超时保护：权限框弹出来没人点的话，这里会一直等（实测卡 8 分钟）
    final permitted = await recorder
        .hasPermission()
        .timeout(const Duration(seconds: 25), onTimeout: () => false);
    debugPrint('[p5v] 权限=$permitted');
    if (!permitted) {
      fail('没有麦克风权限（或系统权限框没人点）：'
          '后台跑 ./tool/grant_mic.sh <device> 再重试');
    }
    final file = await newVoiceTempFile();
    debugPrint('[p5v] 临时文件 ${file.path}，开始录…');
    await recorder.start(file.path);
    debugPrint('[p5v] 录音中…');
    await Future<void>.delayed(const Duration(seconds: 3));
    debugPrint('[p5v] 停止录音…');
    final path = await recorder.stop();
    debugPrint('[p5v] stop 返回 $path');
    expect(path, isNotNull);
    final recFile = File(path!);
    expect(recFile.existsSync(), isTrue);
    final bytes = recFile.lengthSync();
    debugPrint('[p5v] 录音 ${recFile.path.split('/').last} $bytes 字节');
    expect(bytes, greaterThan(0), reason: '真录出来的文件不该是空的');

    if (!_doPost) {
      debugPrint('[p5v] 未开 SYNO_LIVE_POST，只验证录音');
      try {
        recFile.deleteSync();
      } catch (_) {}
      return;
    }

    // ---------- ② 上传 ----------
    final created = <int>[];
    addTearDown(() async {
      for (final id in created) {
        try {
          await chat.deletePost(id);
        } catch (_) {}
      }
    });

    final ok = await ctrl.sendVoiceMessage(
        channelId: target.channelId, filePath: path, seconds: 3);
    expect(ok, isTrue);
    expect(recFile.existsSync(), isFalse, reason: '发完要清掉临时文件');

    final post = (await store.postsForChannel(target.channelId)).firstWhere(
        (p) => p.attachments.any((a) => isVoiceFileName(a.name)),
        orElse: () => throw StateError('没在本地库里找到刚发的语音'));
    created.add(post.postId);
    final prop = post.attachments.single;
    debugPrint('[p5v] post=${post.postId} name=${prop.name} type=${prop.extension} '
        'is_voice=${prop.isVoiceMessage} len=${prop.voiceMsgLength} size=${prop.size}');
    expect(prop.extension, 'aac');
    expect(prop.isVoiceMessage, isTrue,
        reason: '服务端靠文件名 voiceMessage*.aac 认定为语音');
    expect(prop.voiceMsgLength, greaterThanOrEqualTo(3),
        reason: 'voice_msg_length 要落到服务端（气泡显示时长靠它）');

    // ---------- ③ 服务端列表里也是语音 ----------
    final listed = await chat.listPosts(
        channelId: target.channelId, prevCount: 10, nextCount: 0);
    final raw = listed.firstWhere(
        (p) => (p['post_id'] as num).toInt() == post.postId);
    final rawProps = raw['file_props'] as Map?;
    debugPrint('[p5v] 服务端 file_props.is_voice_msg='
        '${rawProps?['is_voice_msg']} voice_msg_length='
        '${rawProps?['voice_msg_length']}');
    expect(rawProps?['is_voice_msg'], isTrue);
    expect((rawProps?['voice_msg_length'] as num?)?.toInt(),
        greaterThanOrEqualTo(3));

    // ---------- ④ 真播放（just_audio + 带 _sid 的下载地址） ----------
    final player = container.read(voicePlayerProvider);
    final url = chat.fileUrl(post.postId);
    debugPrint('[p5v] 播放 ${url.split('?').first}?…');
    await player.play(url);
    var waited = Duration.zero;
    while (waited < const Duration(seconds: 8) &&
        (player.duration == null || player.duration!.inMilliseconds == 0)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited += const Duration(milliseconds: 250);
    }
    final duration = player.duration;
    debugPrint('[p5v] 播放器时长=$duration 位置=${player.position}');
    expect(duration, isNotNull, reason: '能从 NAS 上拉到音频并解码');
    expect(duration!.inMilliseconds, greaterThan(0));
    await player.stop();

    // ---------- ⑤ 清理 ----------
    for (final id in [...created]) {
      await chat.deletePost(id);
    }
    created.clear();
    debugPrint('[p5v] 清理完成 ✓');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
