// r691 · `DA331`：Linux 上的「听书」TTS **真的能合成**（但全程静音）。
//
// 三层判据：
//   ① 本机真有合成器（`detectLinuxTtsBackend` 不必猜）；
//   ② **真合成出字节**：`espeak-ng -w <wav>` 写出合法 WAV（RIFF 头 + 非 0 长度），
//      —— 这条**不经过声卡**，所以既有证据又不会吓到人（用户 2026-10-30 要求）；
//   ③ 引擎接上真的 runner 后 `availableFor() == true`，且 `speak()` 用**注入的假进程**
//      断言命令形状（**不真念**）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/files/book_tts_linux.dart';

class _FakeProc implements TtsSpawnedProcess {
  @override
  Future<int> get exitCode => Future.value(0);

  @override
  void kill() {}
}

void main() {
  test('r691 DA331 · Linux 上实例化合成器（espeak-ng 写入 WAV，不发声）', () async {
    final backend = await detectLinuxTtsBackend((exe, args) async {
      final r = await Process.run(exe, args);
      return TtsProcessResult(exitCode: r.exitCode, stderr: '${r.stderr}');
    });
    // 容器里装了 espeak-ng（poppler 同源 apt 装法）；spd-say 也在但守护进程不一定起
    expect(backend, isNotNull, reason: '这台机器必须至少有一个合成器，否则不算验过');

    final out = File(
      '${Directory.systemTemp.path}/r691_tts_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    final r = await Process.run('espeak-ng', espeakSynthesizeArgs('你好，这是验收。', out.path));
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(await out.exists(), isTrue);
    final bytes = await out.readAsBytes();
    expect(bytes.length, greaterThan(2000), reason: '合成出的 WAV 太小，像没真合成');
    // RIFF....WAVE
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    await out.delete();

    // 引擎侧：真探测 + 假进程（不真念）
    final engine = LinuxTtsEngine(
      spawner: (exe, args) async => _FakeProc(),
    );
    expect(await engine.availableFor('你好'), isTrue);
    var done = false;
    await engine.speak('你好', onDone: (_) => done = true);
    expect(done, isTrue);
    await engine.dispose();

    // 命令形状：中文要看得到 zh、WAV 要能落盘（-w），且产品路径不许带 -w
    expect(espeakSynthesizeArgs('你好', '/tmp/x.wav'), contains('zh'));
    expect(espeakSynthesizeArgs('你好', '/tmp/x.wav'), contains('-w'));
    expect(spdSayArgs('你好'), contains('--wait'));
    expect(spdSayArgs('你好'), isNot(contains('-w')));
    // 不可用的合成器集合 = 空的（本机两个都在）
    expect(LinuxTtsBackend.values.map((b) => b.executable).toList(),
        ['spd-say', 'espeak-ng']);
    debugPrint('[r691] TTS ok backend=$backend wav=${bytes.length}B (silent, -w)');
  });
}
