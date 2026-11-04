// macOS 麦克风采集探针（r717 · `C3`）：**只测桥与授权**，不上传、不发消息。
//
// 为什么要有：`C3` 一直是"录音授权与采集未验"。聊天页的语音消息走
// `RecordVoiceRecorder`（`record` 插件 → `record_macos`），要证明它在这台 Mac 上
// **真能起录、真拿到采样**，最小判据就是：`hasPermission()` → `start()` →
// 取若干次 `amplitude()` → `stop()` → 文件字节 > 0。
//
// 跑法：
//   flutter test integration_test/macos_mic_probe_test.dart -d macos
//
// ★ 会触发一次 macOS 的「麦克风」授权弹框（首次）。不授权 = 本探针失败，
//   台账里记"授权不可得"，**不要**记成"产品不支持录音"。
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/features/chat/voice_message.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS 麦克风：授权 → 起录 → 有采样 → 停录出文件', (tester) async {
    final rec = RecordVoiceRecorder();
    final dir = Directory.systemTemp.createTempSync('micprobe');
    final path = '${dir.path}/probe.aac';

    final ok = await rec.hasPermission();
    debugPrint('[mic] hasPermission = $ok');
    if (!ok) {
      fail('麦克风未授权（TCC 弹框没被允许）⇒ 记"授权不可得"，不是产品缺陷');
    }

    await rec.start(path);
    // 采 6 次（约 2.4 s），看有没有任何一次读到非零音量
    var maxAmp = 0.0;
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final a = await rec.amplitude();
      if (a > maxAmp) maxAmp = a;
      debugPrint('[mic] amplitude[$i] = ${a.toStringAsFixed(3)}');
    }
    final out = await rec.stop();
    debugPrint('[mic] stop → $out');
    expect(out, isNotNull, reason: '录音器没给出文件路径');

    final f = File(out!);
    final n = f.existsSync() ? f.lengthSync() : -1;
    debugPrint('[mic] 文件字节 = $n');
    // 判据：文件存在且 > 1 KB（AAC-LC 2.4 s 远大于此）；音量只做参考，
    // 因为 macOS 可能把输入设备静音（那是环境事实，不是桥坏了）。
    expect(n, greaterThan(1024), reason: '录音文件不存在或太小 ⇒ 桥没真采到数据');
    dir.deleteSync(recursive: true);
  });
}
