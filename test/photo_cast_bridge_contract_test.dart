// P65：**照片投送契约一致性**（纯源码断言，不构建、不联网）。
//
// 为什么需要它：Dart 侧 `photo_cast.dart` 与原生 `CastBridge.kt` 之间是
// **字符串契约**（MethodChannel 方法名）—— 写错一个字母在编译期完全看不出来，
// 表现是"真机上永远报不支持"。197 轮就差点把照片投送写成原生根本没实现的方法。
//
// 这里把两边的**通道名**与**四个方法名**钉在一起，任何一边改名都会立刻红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _channel = 'synhub/cast';
const _methods = [
  'photoCastAvailability',
  'photoCastConnect',
  'photoCastSend',
  'photoCastDisconnect',
];

void main() {
  final dart = File(
    'lib/src/features/photos/photo_cast.dart',
  ).readAsStringSync();
  final kotlin = File(
    'android/app/src/main/kotlin/com/openviewai/synhub/CastBridge.kt',
  ).readAsStringSync();

  test('两端通道名一致', () {
    expect(dart, contains("'$_channel'"), reason: 'Dart 侧通道名');
    expect(kotlin, contains('"$_channel"'), reason: '原生侧通道名');
  });

  test('四个照片投送方法在两端都存在（改名即红）', () {
    for (final m in _methods) {
      expect(dart, contains("'$m'"), reason: 'Dart 侧缺 $m');
      expect(kotlin, contains('"$m"'), reason: '原生侧缺 $m');
    }
  });

  test('原生侧确实走会话自定义命名空间消息（不是音频的 play）', () {
    expect(kotlin, contains('urn:x-cast'), reason: '照片投送用自定义命名空间');
    expect(kotlin, contains('sendMessage'), reason: '用 CastSession.sendMessage');
    // 音频桥的方法名与照片桥**不能混用**
    expect(kotlin, contains('"play"'));
    expect(dart.contains("'play'"), isFalse, reason: 'Dart 照片桥不得调用音频方法名');
  });
}
