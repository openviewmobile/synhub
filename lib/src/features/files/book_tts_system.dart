// 系统 TTS 的 [TtsEngine] 真机实现（flutter_tts）。
//
// 只在阅读器真机路径上用；单测永远注入假引擎（见 `book_tts.dart` 的说明）。
// 语音/语速都不强制设置：**跟随系统 TTS 的默认语音**最不容易出错（用户自己
// 在系统设置里选的声音才是他习惯的）。
import 'package:flutter_tts/flutter_tts.dart';

import 'book_tts.dart';

/// 按文本内容挑一个语言（中英混排时以"有没有汉字"为准）。
///
/// 纯函数、可单测：系统 TTS 如果拿中文语音读英文段落会很难听。
String ttsLanguageFor(String text) {
  final hasCjk = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff]').hasMatch(text);
  if (hasCjk) return 'zh-CN';
  final hasLatin = RegExp(r'[A-Za-z]').hasMatch(text);
  return hasLatin ? 'en-US' : 'zh-CN';
}

/// flutter_tts 实现。
///
/// ⚠️ Android 的 `pause()` 支持很弱、也**没有 resume**：所以状态机把"继续"
/// 定义成"从本段开头重读"，这里 [pause] 只是尽力停止出声（iOS 上是真暂停）。
class SystemTtsEngine implements TtsEngine {
  FlutterTts? _tts;

  /// 当前这一段的完成回调（一次只读一段，所以单个字段就够）
  void Function(Object? error)? _onDone;

  String? _language;

  /// 懒创建：不在构造时碰原生（测试宿主/桌面没有插件也能 new 出来）
  Future<FlutterTts> _ensure() async {
    final cached = _tts;
    if (cached != null) return cached;
    final tts = FlutterTts();
    tts.setCompletionHandler(() => _finish(null));
    // 有些平台把"取消/停止"也走 cancel handler，这里只清回调不出声
    tts.setCancelHandler(() => _finish(null));
    tts.setErrorHandler((msg) => _finish(msg ?? 'tts error'));
    _tts = tts;
    return tts;
  }

  /// 引擎是否可用（拿不到答案时按"不可用"处理，宁可报错也别假装在念）
  Future<bool> _languageReady(FlutterTts tts, String lang) async {
    try {
      final ok = await tts.isLanguageAvailable(lang);
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  void _finish(Object? error) {
    final cb = _onDone;
    _onDone = null;
    cb?.call(error);
  }

  @override
  Future<bool> availableFor(String text) async {
    final tts = await _ensure();
    return _languageReady(tts, ttsLanguageFor(text));
  }

  @override
  Future<void> speak(String text, {required TtsDone onDone}) async {
    if (text.trim().isEmpty) {
      onDone(null);
      return;
    }
    _onDone = onDone;
    final tts = await _ensure();
    final lang = ttsLanguageFor(text);
    // ⚠️ 先确认引擎真的能用。系统 TTS 没绑定时 `speak()` 只会打一行
    // `speak failed: not bound to TTS engine` 的日志：不出声也**不回调**，
    // 界面就会永远停在"朗读中"。宁可这里直接失败。
    if (!await _languageReady(tts, lang)) {
      _finish(kTtsEngineUnavailable);
      return;
    }
    if (lang != _language) {
      _language = lang;
      await tts.setLanguage(lang);
    }
    await tts.speak(text);
  }

  @override
  Future<void> stop() async {
    _onDone = null;
    final tts = _tts;
    if (tts == null) return;
    await tts.stop();
  }

  @override
  Future<void> pause() async {
    _onDone = null;
    final tts = _tts;
    if (tts == null) return;
    // Android 上 pause 不可靠，stop 是确定能停住的；状态机已经把"继续"
    // 定义成从本段开头重读，所以这里退化成 stop 不会丢内容。
    try {
      await tts.pause();
    } catch (_) {
      await tts.stop();
    }
  }

  @override
  Future<void> dispose() async {
    _onDone = null;
    final tts = _tts;
    _tts = null;
    if (tts == null) return;
    try {
      await tts.stop();
    } catch (_) {
      // 退出流程不该被原生异常卡住
    }
  }
}
