// Linux 上的「听书」TTS —— 走**系统语音合成器**（`spd-say` / `espeak-ng`）。
//
// 为什么需要它：`flutter_tts` 没有 Linux 实现（插件只声明 Android/iOS/macOS/Windows
// 与 Web）⇒ 以前在 Linux 上打开听书面板只会得到"引擎不可用"。r691 把这档补上：
//   * **优先 `spd-say`**（speech-dispatcher，桌面发行版一般都有；`--wait` 会等念完，
//     正好对上 [TtsEngine.speak] 的"念完回调"语义）；
//   * 没有 `spd-say` 就退 **`espeak-ng`**（同一份文本直接念）。
//
// ★ 静音纪律（用户 2026-10-30 明确要求"不要搞发出尖锐声音的测试"）：
//   本文件的**单测与集成测试都不出声** —— 单测注入假执行器；
//   集成测试用 `espeak-ng -w <file>`（合成到 WAV，不播放）来证明"这台机器真能合成语音"。
//
// 进程执行器可注入（`ttsProcessRunnerProvider`），与 PDF 的 poppler 一路同一个套路：
// 单测不依赖宿主装没装 `spd-say`，也不真起子进程。
import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'book_tts.dart';
import 'book_tts_system.dart';

/// 一次外部命令的结果（只要退出码；stdout/stderr 用来诊断）
class TtsProcessResult {
  const TtsProcessResult({required this.exitCode, this.stderr = ''});

  final int exitCode;
  final String stderr;

  bool get ok => exitCode == 0;
}

/// 起一个进程并等它结束（`speak` 的"念完"就是等这个进程退出）
typedef TtsProcessRunner = Future<TtsProcessResult> Function(
  String executable,
  List<String> args,
);

/// 已经起来的合成进程：只暴露 [LinuxTtsEngine] 需要的两件事
/// （等它退出 / 中途把它 kill 掉）。做成接口是为了**单测能注入假进程**
/// —— 真 `Process` 没法在测试里构造。
abstract interface class TtsSpawnedProcess {
  Future<int> get exitCode;
  void kill();
}

class _RealProcess implements TtsSpawnedProcess {
  _RealProcess(this._p);

  final Process _p;

  @override
  Future<int> get exitCode => _p.exitCode;

  @override
  void kill() {
    try {
      _p.kill();
    } catch (_) {
      // 已经自己退了
    }
  }
}

/// 起一个**长驻**进程（需要中途 `kill` 才能停的那种）。
typedef TtsProcessSpawner = Future<TtsSpawnedProcess> Function(
  String executable,
  List<String> args,
);

Future<TtsProcessResult> _run(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  return TtsProcessResult(exitCode: r.exitCode, stderr: '${r.stderr}');
}

final ttsProcessRunnerProvider = Provider<TtsProcessRunner>(
  (ref) => _run,
);

final ttsProcessSpawnerProvider = Provider<TtsProcessSpawner>(
  (ref) => (exe, args) async => _RealProcess(await Process.start(exe, args)),
);

/// 本机可用的合成器（探测顺序即优先级）
enum LinuxTtsBackend {
  /// speech-dispatcher（桌面常见）
  spdSay('spd-say'),

  /// eSpeak NG（轻量、几乎处处可装）
  espeakNg('espeak-ng');

  const LinuxTtsBackend(this.executable);

  final String executable;
}

/// 探测本机有哪个合成器。**探测不了就返回 null**（面板如实说"不可用"，不假装能念）。
Future<LinuxTtsBackend?> detectLinuxTtsBackend(
  TtsProcessRunner run,
) async {
  for (final backend in LinuxTtsBackend.values) {
    try {
      final r = await run(backend.executable, const ['--version']);
      if (r.ok) return backend;
    } catch (_) {
      // ENOENT：这个合成器没装，试下一个
    }
  }
  return null;
}

/// 把 [ttsLanguageFor] 的 BCP-47 语言映射到两个后端的参数。
///
/// * `espeak-ng`：`-v zh` / `-v en`（它认语言名也认 `zh-CN` 这类串，但短名更稳）；
/// * `spd-say`：`-l zh` / `-l en`（同理）。
String linuxTtsVoiceFor(String text) {
  final lang = ttsLanguageFor(text);
  return lang.startsWith('zh') ? 'zh' : 'en';
}

/// `espeak-ng` 的合成命令：**写到文件**（`-w`），不经过声卡。
///
/// 集成测试用它拿"真合成出字节"的证据；产品路径不用它（产品要出声）。
List<String> espeakSynthesizeArgs(String text, String outPath) => [
  '-v',
  linuxTtsVoiceFor(text),
  '-w',
  outPath,
  text,
];

/// `spd-say` 的朗读命令：`--wait` 才能等到念完。
List<String> spdSayArgs(String text) => [
  '--wait',
  '-l',
  linuxTtsVoiceFor(text),
  text,
];

/// Linux 的 [TtsEngine]：进程式合成器。
///
/// 与 `SystemTtsEngine` 的语义对齐：一次只念一段；[stop]/[pause] 都是"停住"，
/// 状态机那边"继续 = 从本段开头重读"，所以不退化成真暂停也不会丢内容。
class LinuxTtsEngine implements TtsEngine {
  LinuxTtsEngine({
    TtsProcessRunner? runner,
    TtsProcessSpawner? spawner,
  }) : _run = runner ?? _runProcess,
       _spawn = spawner ?? _spawnProcess;

  static Future<TtsProcessResult> _runProcess(
    String exe,
    List<String> args,
  ) async {
    final r = await Process.run(exe, args);
    return TtsProcessResult(exitCode: r.exitCode, stderr: '${r.stderr}');
  }

  static Future<TtsSpawnedProcess> _spawnProcess(
    String exe,
    List<String> args,
  ) async => _RealProcess(await Process.start(exe, args));

  final TtsProcessRunner _run;
  final TtsProcessSpawner _spawn;

  /// "这个合成器起不来，换下一个试试"的哨兵（不是错误）
  static const Object _retryNext = Object();

  /// 探测结论缓存：`_probed` 为 true 时 `_backend` 才是结论（含 null）
  bool _probed = false;
  LinuxTtsBackend? _backend;
  TtsSpawnedProcess? _proc;
  void Function(Object? error)? _onDone;
  bool _disposed = false;

  /// 已探测到的后端（null = 还没探测 / 都没有）
  Future<LinuxTtsBackend?> _ensureBackend() async {
    if (_probed) return _backend;
    _backend = await detectLinuxTtsBackend(_run);
    _probed = true;
    return _backend;
  }

  @override
  Future<bool> availableFor(String text) async {
    if (_disposed) return false;
    final backend = await _ensureBackend();
    return backend != null;
  }

  @override
  Future<void> speak(String text, {required TtsDone onDone}) async {
    if (_disposed) return;
    if (text.trim().isEmpty) {
      onDone(null);
      return;
    }
    _onDone = onDone;
    final first = await _ensureBackend();
    if (first == null) {
      _finish(kTtsEngineUnavailable);
      return;
    }
    // ★ 桌面实况：`spd-say` 这个**可执行文件在**，但 speech-dispatcher 的守护进程
    //   没起来 ⇒ 命中了也没声。所以失败时**退另一个合成器再试一次**（各试一次，
    //   不无限重试），成功就把它记成新结论。
    Object? lastError;
    for (final backend in [
      first,
      ...LinuxTtsBackend.values.where((b) => b != first),
    ]) {
      final result = await _speakWith(backend, text);
      if (_disposed) return;
      if (result == null) {
        if (backend != first) {
          _backend = backend;
          _probed = true;
        }
        _finish(null);
        return;
      }
      if (result != _retryNext) lastError = result;
    }
    _finish(lastError ?? kTtsEngineUnavailable);
  }

  /// 用某个合成器念一次：成功返回 null，可重试（进程都没起来）返回 [_retryNext]，
  /// 失败返回错误对象。
  Future<Object?> _speakWith(LinuxTtsBackend backend, String text) async {
    final args = backend == LinuxTtsBackend.spdSay
        ? spdSayArgs(text)
        : ['-v', linuxTtsVoiceFor(text), text];
    try {
      final p = await _spawn(backend.executable, args);
      _proc = p;
      // 等它自己退出（spd-say --wait / espeak-ng 都会在念完后退出）
      final code = await p.exitCode;
      if (_disposed || !identical(_proc, p)) return null;
      _proc = null;
      return code == 0 ? null : 'tts exit=$code';
    } on ProcessException {
      // 可执行文件其实不在（探测用的 `--version` 骗了我们）
      return _retryNext;
    } catch (e) {
      return e;
    }
  }

  void _finish(Object? error) {
    final cb = _onDone;
    _onDone = null;
    cb?.call(error);
  }

  Future<void> _kill() async {
    _onDone = null;
    final p = _proc;
    _proc = null;
    if (p == null) return;
    try {
      p.kill();
    } catch (_) {
      // 进程可能已经自己退了
    }
  }

  @override
  Future<void> stop() => _kill();

  @override
  Future<void> pause() => _kill();

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _kill();
  }

  /// 测试用：把探测结果钉住（免得每个用例都走一遍探测）
  @visibleForTesting
  void debugSetBackend(LinuxTtsBackend? backend) {
    _backend = backend;
    _probed = true;
  }
}

/// 按平台选 TTS 引擎：Linux 走进程式合成器，其它平台仍是 `flutter_tts`。
TtsEngine defaultTtsEngine() => defaultTargetPlatform == TargetPlatform.linux
    ? LinuxTtsEngine()
    : SystemTtsEngine();
