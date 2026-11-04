// 听书（TTS）的**可注入抽象 + 朗读状态机**。
//
// 为什么把状态机独立出来：真机 TTS 是原生插件，单测里跑不了；而"播放/暂停/
// 继续/停止、按段落推进、最后一段读完回到 idle"这些**行为**才是业务价值所在。
// 所以：
//   * [TtsEngine] 是唯一与原生打交道的地方（真机实现见 `book_tts_system.dart`，
//     测试用 `FakeTtsEngine`）；
//   * [TtsController] 是纯 Dart 状态机，一行原生代码都不碰，离线可测。
//
// ⚠️ 关于"暂停/继续"的诚实说明：Android 的 TTS 引擎**没有可靠的断点续读**，
// flutter_tts 也只在部分平台实现了 `pause()`。所以这里的"继续"语义是
// **从本段开头重读**（段落粒度），不是从半个字续上。真机证据见
// `docs/device-verification.md`。
import 'dart:async';

/// 朗读状态
enum TtsPlaybackState {
  /// 没在读（初始 / 读完 / 停止 / 出错）
  idle,

  /// 正在读某一段
  playing,

  /// 暂停（保留了当前段落，点"继续"从本段开头重读）
  paused,
}

/// 一段读完（或出错）时的回调；[error] 非空表示失败。
/// 引擎不可用（系统没装 TTS / 没绑定成功）——界面据此给"设备不支持朗读"，
/// 而不是显示成"正在朗读"却没有任何声音。
///
/// 真机踩坑：HONOR LGE-AN10 只有 iFlytek 语音套件，`TextToSpeech.speak` 直接报
/// `speak failed: not bound to TTS engine`，**既不出声也不回调** —— 之前界面就一直
/// 停在"暂停"按钮上。所以说话前先问一次 `isLanguageAvailable`，不可用就直接失败。
const String kTtsEngineUnavailable = 'tts-engine-unavailable';

typedef TtsDone = void Function(Object? error);

/// 系统 TTS 的最小接口（测试注入假实现）
abstract interface class TtsEngine {
  /// 读一段文本。读完、被停掉、出错都要回调一次 [onDone]（出错时 [error] 非空）。
  ///
  /// 约定：实现方**不要**在 [stop]/[pause] 时回调 [onDone]（状态机自己作废
  /// 在途回调），只在"这一段真的结束了"时回调。
  Future<void> speak(String text, {required TtsDone onDone});

  /// 立刻停止出声
  Future<void> stop();

  /// 暂停（不支持断点续读的平台可以退化为"停止出声"）
  Future<void> pause();

  /// 释放原生资源
  Future<void> dispose();

  /// 这台设备/这套系统**能不能念** [text] 这种语言。
  ///
  /// ★ DA200（真机 2026-10-22）：HONOR LGE-AN10 只有 iFlytek 套件、没绑 TTS
  /// 引擎 ⇒ 朗读条的「Read aloud」是个**死动作**（点了只弹一行红字）。
  /// 有了这个探测，界面可以**进弹层就先说清楚**并把按钮置灰，
  /// 而不是让用户点一次才知道。（AGENTS §2.0.19：「验真才给按钮」。）
  Future<bool> availableFor(String text);
}

/// 朗读控制器：段落队列 + 播放/暂停/继续/停止/上下段。
///
/// [paragraphs] 是"要读的段落"（阅读器把整章纯文本按段落切好喂进来）。
/// 状态变化（包括"自动推进到下一段"）都会调 [onChanged]，界面据此刷新。
class TtsController {
  TtsController({
    required this.engine,
    List<String> paragraphs = const [],
    this.onChanged,
    this.onError,
  }) : _paragraphs = List<String>.from(paragraphs);

  final TtsEngine engine;

  /// 状态/段落变化回调（界面刷新用）
  void Function()? onChanged;

  /// 朗读失败回调（界面显示可读提示）
  void Function(Object error)? onError;

  List<String> _paragraphs;
  TtsPlaybackState _state = TtsPlaybackState.idle;
  int _index = 0;

  /// 每次"开始一段/停/暂停"都 +1；过期的完成回调看到代号变了就丢弃，
  /// 避免"停止后又冒出一个推进"这种鬼影。
  int _generation = 0;

  TtsPlaybackState get state => _state;
  int get index => _index;
  int get count => _paragraphs.length;
  bool get isActive => _state != TtsPlaybackState.idle;

  /// 当前要读/正在读的段落（越界或空返回空串）
  String get currentText =>
      _index >= 0 && _index < _paragraphs.length ? _paragraphs[_index] : '';

  /// 换一批段落（换章/重新选中时调）。会先停掉当前朗读。
  Future<void> setParagraphs(List<String> paragraphs) async {
    await stop();
    _paragraphs = List<String>.from(paragraphs);
    _index = 0;
    onChanged?.call();
  }

  /// 播放（[from] 指定起始段；暂停中点它 = 继续 = 从本段开头重读）
  Future<void> play({int? from}) async {
    if (_paragraphs.isEmpty) return;
    if (_state == TtsPlaybackState.paused) return resume();
    if (_state == TtsPlaybackState.playing) return;
    await _speak((from ?? _index).clamp(0, _paragraphs.length - 1));
  }

  Future<void> _speak(int i) async {
    _index = i;
    _state = TtsPlaybackState.playing;
    onChanged?.call();
    final gen = ++_generation;
    await engine.speak(
      _paragraphs[i],
      onDone: (error) {
        if (gen != _generation) return;
        if (error != null) {
          _state = TtsPlaybackState.idle;
          onChanged?.call();
          onError?.call(error);
          return;
        }
        if (_state != TtsPlaybackState.playing) return;
        if (i + 1 < _paragraphs.length) {
          unawaited(_speak(i + 1));
        } else {
          _state = TtsPlaybackState.idle;
          onChanged?.call();
        }
      },
    );
  }

  /// 暂停（在途的完成回调作废，不会偷偷推进到下一段）
  Future<void> pause() async {
    if (_state != TtsPlaybackState.playing) return;
    _generation++;
    _state = TtsPlaybackState.paused;
    onChanged?.call();
    await engine.pause();
  }

  /// 继续 = 从**本段开头**重读（见文件头的说明）
  Future<void> resume() async {
    if (_state != TtsPlaybackState.paused) return;
    await _speak(_index);
  }

  /// 停止（回到 idle，段落下标留在原处）
  Future<void> stop() async {
    if (_state == TtsPlaybackState.idle) return;
    _generation++;
    _state = TtsPlaybackState.idle;
    onChanged?.call();
    await engine.stop();
  }

  /// 直接跳到某一段（越界会被夹住）
  Future<void> seek(int i) async {
    if (_paragraphs.isEmpty) return;
    await _speak(i.clamp(0, _paragraphs.length - 1));
  }

  /// 下一段（到末尾就停）
  Future<void> next() async {
    if (_index + 1 >= _paragraphs.length) return;
    await seek(_index + 1);
  }

  /// 上一段（到开头就重读第一段）
  Future<void> previous() async {
    await seek(_index - 1 < 0 ? 0 : _index - 1);
  }

  Future<void> dispose() async {
    _generation++;
    _state = TtsPlaybackState.idle;
    await engine.dispose();
  }
}

/// 整章正文 → 朗读段落：按换行切、丢空行、过短的碎片并进上一段。
///
/// 纯函数，阅读器与测试共用（避免"读出来一顿一顿的"）。
List<String> ttsParagraphsOf(String text, {int minChars = 8}) {
  final out = <String>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    // 太短的碎片（标题残片、页码）并进上一段，读起来更连贯
    if (line.length < minChars && out.isNotEmpty) {
      out[out.length - 1] = '${out.last} $line';
      continue;
    }
    out.add(line);
  }
  return out;
}
