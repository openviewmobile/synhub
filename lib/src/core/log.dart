import 'package:flutter/foundation.dart';

/// logcat 统一标签。`adb logcat -s flutter | grep SYNOPUNCH` 即可过滤。
const String kLogTag = 'SYNOPUNCH';

/// 带标签的调试输出。
///
/// 注意：Android 上 `debugPrint` 走的是 `flutter` 这个 logcat tag，
/// 而不是 [kLogTag] —— 标签只是消息前缀。
void log(String msg) {
  debugPrint('[$kLogTag] $msg');
}
