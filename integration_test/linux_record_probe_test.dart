// r693 · Linux 录音探针（§C9 销号用）
//
// 目的：把"Linux 上能不能录音"从**推断**变成**读数**。
//
// 事实链（三条，缺一条这个用例就不该绿）：
//   ① `record 7.1.x` 在 Linux 上走 **`record_linux`**（`parecord` 抓 + `ffmpeg` 编码），
//      容器里这两个二进制都在 ⇒ 插件本身有实现，不是"没实现"；
//   ② 容器**没有麦克风**，所以装置侧给一个 **null sink + virtual source**
//      （`pactl load-module module-null-sink` / `module-virtual-source`）当输入；
//   ③ ★ **静音铁律**（用户 2026-10-30 明确要求「不要搞这种发出尖锐声音的测试」）：
//      音调只打进 **null sink**（它把样本直接丢弃，不上声卡），
//      **绝不** `paplay` 到真实输出设备，**绝不**走 `NativeAudioStationPlayer().play()`。
//
// 判据：文件真的写出来了（> 1000 B）、`ffprobe` 量到的时长在 1.0–3.0 s 之间、
// 抓到的 PCM 幅度峰值 > 0.05（证明抓到的不是一块纯静音）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/features/chat/voice_message.dart';

const _out = '/tmp/synhub_rec_probe.aac';
const _tone = '/tmp/synhub_rec_tone.wav';

Future<String> _run(String cmd) async {
  final r = await Process.run('bash', ['-lc', cmd]);
  return '${r.stdout}${r.stderr}'.trim();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Linux 录音闭环：parecord 抓到载荷 + ffprobe 认这段时长', (tester) async {
    final src = await _run('pactl list short sources');
    // 前置：虚拟输入必须存在（没有就如实失败，不要静默跳过）
    expect(
      src.contains('virtmic'),
      isTrue,
      reason: '装置缺虚拟输入源（virtmic）——先跑 tool/linux_record_fixture.sh',
    );

    final out = File(_out);
    if (out.existsSync()) out.deleteSync();

    // 440 Hz 音调 → null sink（**丢弃样本，不发声**）
    await _run(
      'ffmpeg -hide_banner -loglevel error -f lavfi '
      '-i sine=frequency=440:duration=4 -f wav $_tone -y',
    );
    final tone = await Process.start(
      'bash',
      ['-lc', 'paplay --device=nullsink $_tone'],
    );

    final rec = RecordVoiceRecorder();
    expect(await rec.hasPermission(), isTrue, reason: 'record_linux 的 hasPermission');
    await rec.start(_out);

    var peak = 0.0;
    for (var i = 0; i < 14; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final a = await rec.amplitude();
      if (a > peak) peak = a;
    }

    final path = await rec.stop();
    await tone.exitCode;

    expect(path, isNotNull, reason: 'stop() 必须给出文件路径');
    final f = File(path!);
    expect(f.existsSync(), isTrue, reason: '录音文件必须真的落盘');
    expect(f.lengthSync(), greaterThan(1000), reason: '载荷不许是 0 字节');
    expect(peak, greaterThan(0.05), reason: '抓到的 PCM 不能是一块纯静音');

    final probe = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration,format_name',
      '-of',
      'json',
      path,
    ]);
    final info = jsonDecode(probe.stdout as String)['format'] as Map;
    final dur = double.parse('${info['duration']}');
    expect(dur, greaterThan(1.0), reason: '时长下界');
    expect(dur, lessThan(3.0), reason: '时长上界');

    // 读数落日志（走查日志里要能一眼看到这次的实测值）
    // ignore: avoid_print
    print(
      '[record] path=$path bytes=${f.lengthSync()} peak=${peak.toStringAsFixed(3)} '
      'format=${info['format_name']} duration=${dur.toStringAsFixed(2)}s',
    );
  });
}
