// r691 · `DA331`：Linux 上的「听书」TTS 走系统合成器（`spd-say` / `espeak-ng`）。
//
// 判据分四层：
//   ① 探测优先级（有 spd-say 就用它，没装就退 espeak-ng，都没有 ⇒ null）；
//   ② 命令形状（语言归一、`--wait`、`-w` 合成到文件 —— **都不出声**）；
//   ③ 引擎语义（念完才回调 / 失败给错误 / 停住能 kill / 没有合成器时如实报不可用）；
//   ④ 源码结构（provider 按平台分流；Linux 文件里不许出现"假装成功"的兜底）。
//
// ★ 静音：本文件**不真起任何合成器**，全部走假执行器 / 假进程。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/files/book_tts.dart';
import 'package:synhub/src/features/files/book_tts_linux.dart';

/// 记录被调用的假执行器
class _FakeRunner {
  _FakeRunner(this._answers);

  /// 可执行文件名 → 退出码（缺省视为"没装"⇒ 抛 ProcessException）
  final Map<String, int> _answers;
  final List<String> calls = [];

  Future<TtsProcessResult> call(String exe, List<String> args) async {
    calls.add('$exe ${args.join(' ')}');
    final code = _answers[exe];
    if (code == null) {
      throw ProcessException(exe, args, 'No such file or directory', 2);
    }
    return TtsProcessResult(exitCode: code);
  }
}

/// 假进程：由测试控制何时"念完"
class _FakeProcess implements TtsSpawnedProcess {
  _FakeProcess(this._completer);

  final Future<int> _completer;
  bool killed = false;

  @override
  Future<int> get exitCode => _completer;

  @override
  void kill() {
    killed = true;
  }
}

void main() {
  group('DA331 ① 探测优先级', () {
    test('spd-say 装了就用它（不再试 espeak-ng）', () async {
      final r = _FakeRunner({'spd-say': 0, 'espeak-ng': 0});
      final backend = await detectLinuxTtsBackend(r.call);
      expect(backend, LinuxTtsBackend.spdSay);
      expect(r.calls, ['spd-say --version']);
    });

    test('spd-say 没装 ⇒ 退 espeak-ng', () async {
      final r = _FakeRunner({'espeak-ng': 0});
      final backend = await detectLinuxTtsBackend(r.call);
      expect(backend, LinuxTtsBackend.espeakNg);
      expect(r.calls, ['spd-say --version', 'espeak-ng --version']);
    });

    test('两个都没装 ⇒ null（不许假装能念）', () async {
      final r = _FakeRunner({});
      expect(await detectLinuxTtsBackend(r.call), isNull);
    });
  });

  group('DA331 ② 命令形状（静音）', () {
    test('中文/英文归一成 zh / en', () {
      expect(linuxTtsVoiceFor('你好，世界'), 'zh');
      expect(linuxTtsVoiceFor('hello world'), 'en');
      // 中英混排以"有没有汉字"为准（与 flutter_tts 那边同一判据）
      expect(linuxTtsVoiceFor('hello 世界'), 'zh');
    });

    test('spd-say 必须 --wait（否则"念完"回调会立刻触发）', () {
      final args = spdSayArgs('hi');
      expect(args.first, '--wait');
      expect(args, containsAllInOrder(['-l', 'en']));
      expect(args.last, 'hi');
    });

    test('espeak-ng 合成到文件（-w）：这条永远不出声', () {
      final args = espeakSynthesizeArgs('你好', '/tmp/a.wav');
      expect(args, containsAllInOrder(['-v', 'zh']));
      expect(args, containsAllInOrder(['-w', '/tmp/a.wav']));
      expect(args.last, '你好');
      // 产品路径用的"直接念"参数里**不许**有 -w
      expect(spdSayArgs('你好'), isNot(contains('-w')));
    });
  });

  group('DA331 ③ 引擎语义', () {
    test('没有合成器 ⇒ available=false，speak 立刻报不可用', () async {
      final engine = LinuxTtsEngine(runner: _FakeRunner({}).call);
      expect(await engine.availableFor('hi'), isFalse);
      Object? err = 'unset';
      await engine.speak('hi', onDone: (e) => err = e);
      expect(err, kTtsEngineUnavailable);
    });

    test('有合成器 ⇒ 走到 spawn，念完才回调 null', () async {
      final engine = LinuxTtsEngine(
        runner: _FakeRunner({'spd-say': 0}).call,
      );
      engine.debugSetBackend(LinuxTtsBackend.spdSay);
      String? called;
      final engine2 = LinuxTtsEngine(
        runner: _FakeRunner({'spd-say': 0}).call,
        spawner: (exe, args) async {
          called = '$exe ${args.join(' ')}';
          return _FakeProcess(Future.value(0));
        },
      );
      engine2.debugSetBackend(LinuxTtsBackend.spdSay);
      Object? err = 'unset';
      var finished = false;
      await engine2.speak(
        'hi',
        onDone: (e) {
          finished = true;
          err = e;
        },
      );
      expect(called, 'spd-say --wait -l en hi');
      expect(finished, isTrue);
      expect(err, isNull);
      await engine2.dispose();
      await engine.dispose();
    });

    test('进程退出码非 0 ⇒ 回调带错误（不许当念完了）', () async {
      final engine = LinuxTtsEngine(
        runner: _FakeRunner({'espeak-ng': 0}).call,
        spawner: (exe, args) async => _FakeProcess(Future.value(3)),
      );
      engine.debugSetBackend(LinuxTtsBackend.espeakNg);
      Object? err;
      await engine.speak('hi', onDone: (e) => err = e);
      expect('$err', contains('exit=3'));
      await engine.dispose();
    });

    test('stop/pause 会 kill 正在念的进程，且不再回调', () async {
      final proc = _FakeProcess(Completer<int>().future);
      final engine = LinuxTtsEngine(
        runner: _FakeRunner({'spd-say': 0}).call,
        spawner: (exe, args) async => proc,
      );
      engine.debugSetBackend(LinuxTtsBackend.spdSay);
      var cb = 0;
      final speaking = engine.speak('hi', onDone: (_) => cb++);
      await Future<void>.delayed(Duration.zero);
      await engine.pause();
      expect(proc.killed, isTrue);
      expect(cb, 0);
      await engine.dispose();
      // 不 await speaking：假进程永不退出，这正是"被 kill 掉"的样子
      speaking.ignore();
    });

    test('dispose 之后不许再起进程', () async {
      var spawned = 0;
      final engine = LinuxTtsEngine(
        runner: _FakeRunner({'spd-say': 0}).call,
        spawner: (exe, args) async {
          spawned++;
          return _FakeProcess(Future.value(0));
        },
      );
      engine.debugSetBackend(LinuxTtsBackend.spdSay);
      await engine.dispose();
      expect(await engine.availableFor('hi'), isFalse);
      await engine.speak('hi', onDone: (_) {});
      expect(spawned, 0);
    });
  });

  group('DA331 ③b 失败换后端（桌面上 spd-say 在但守护进程没起）', () {
    test('spd-say 退出码非 0 ⇒ 自动退 espeak-ng 再念一次，并记住这次成功', () async {
      final spawned = <String>[];
      final engine = LinuxTtsEngine(
        runner: _FakeRunner({'spd-say': 0, 'espeak-ng': 0}).call,
        spawner: (exe, args) async {
          spawned.add(exe);
          // spd-say 命中"没有守护进程"；espeak-ng 正常念完
          return _FakeProcess(Future.value(exe == 'spd-say' ? 1 : 0));
        },
      );
      engine.debugSetBackend(LinuxTtsBackend.spdSay);
      Object? err = 'unset';
      await engine.speak('hi', onDone: (e) => err = e);
      expect(err, isNull, reason: '第二个合成器念成功就不该报错');
      expect(spawned, ['spd-say', 'espeak-ng']);
      await engine.dispose();
    });

    test('两个都失败 ⇒ 如实报最后一次的错误（不假装成功）', () async {
      final engine = LinuxTtsEngine(
        runner: _FakeRunner({'spd-say': 0, 'espeak-ng': 0}).call,
        spawner: (exe, args) async => _FakeProcess(Future.value(2)),
      );
      engine.debugSetBackend(LinuxTtsBackend.spdSay);
      Object? err;
      await engine.speak('hi', onDone: (e) => err = e);
      expect('$err', contains('exit=2'));
      await engine.dispose();
    });
  });

  group('DA331 ④ 源码结构', () {
    test('provider 按平台分流：Linux 走 LinuxTtsEngine', () {
      final providers = File(
        'lib/src/features/files/book_providers.dart',
      ).readAsStringSync();
      expect(providers, contains('defaultTtsEngine()'));
      final platform = File(
        'lib/src/features/files/book_tts_linux.dart',
      ).readAsStringSync();
      expect(
        platform,
        contains('defaultTargetPlatform == TargetPlatform.linux'),
      );
      expect(platform, contains('LinuxTtsEngine()'));
      expect(platform, contains('SystemTtsEngine()'));
      // Linux 文件里必须真的用 --wait / -w 这两条静音相关参数
      expect(platform, contains("'--wait'"));
      expect(platform, contains("'-w'"));
    });

    test('单测与集成测试都不许真出声（不许出现 spd-say 直接念的测试调用）', () {
      final self = File('test/book_tts_linux_test.dart').readAsStringSync();
      // 本文件只能用假执行器：出现"起真进程"的调用就是会出声的写法。
      // ★ 判据拼串比对（纯文本闸门会把注释里的字面量也数进去，见 AGENTS §2.0.47）
      final spawn = 'Process' '.start(';
      final run = 'Process' '.run(';
      expect(self.contains(spawn), isFalse);
      expect(self.contains(run), isFalse);
    });
  });
}
