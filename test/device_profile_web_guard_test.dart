// ★ 第 336 轮（D34）守卫：**启动路径在 web 上不许抛**。
//
// 真缺陷：`DeviceProfile.detect()` 在 `main.dart:17` 被同步调用（runApp 之前），
// 而它原本有两处裸 `Platform.*`（`Platform.isAndroid` / `Platform.operatingSystemVersion`）
// **不在 try 里** ⇒ 在 web 上 `dart2js` 的 `dart:io` 桩抛
// `Unsupported operation: Platform._operatingSystem`
// ⇒ **runApp 之前就断了 ⇒ 首屏白屏**（浏览器实测：截图 2.5 KB 纯色、控制台只有 `Uncaught ` 空串）。
//
// 判据钉在**机制量**上（§2.0.30）：`detect()` 体内**第一个 `Platform.` 之前**必须出现 `kIsWeb`。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 只丢掉整行 `//` 注释 —— 本仓已踩过"守卫把注释数进去"的坑（§2.0.63⑤）。
String stripLineComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// 抠出 `static DeviceProfile detect() { ... }` 的方法体（到方法级 `\n  }` 为止）。
String detectBody(String src) {
  final start = src.indexOf('static DeviceProfile detect() {');
  // ★ 这里**不能用 `expect`**：本函数在 `main()` 体里就被调用（装载期），
  //   而 `expect` 在测试体外会抛 `OutsideTestException`
  //   （第 336 轮实测：整条用例文件直接 `Failed to load`）。
  if (start <= 0) throw StateError('找不到 detect() —— 守卫要跟着改');
  final rest = src.substring(start);
  final end = rest.indexOf('\n  }');
  if (end <= 0) throw StateError('detect() 体没找到结尾 —— 守卫要跟着改');
  return rest.substring(0, end);
}

/// 判据本体（抽成函数是为了**反向验证**：把守卫拿掉必须让判据变假）。
bool guardedFromWeb(String body) {
  final web = body.indexOf('kIsWeb');
  if (web < 0) return false;
  final firstPlatform = body.indexOf('Platform.');
  if (firstPlatform < 0) return true; // 压根不碰 Platform 也算安全
  return web < firstPlatform;
}

void main() {
  final path = 'lib/src/core/device/device_profile.dart';
  final src = stripLineComments(File(path).readAsStringSync());
  final body = detectBody(src);

  test('① `detect()` 在第一个 `Platform.` 之前判了 `kIsWeb`', () {
    expect(
      guardedFromWeb(body),
      isTrue,
      reason: '$path 的 detect() 在 web 上会抛（启动路径 ⇒ 白屏）',
    );
  });

  test('② `detect()` 真的碰了 Platform（否则①是空转）', () {
    expect(body.contains('Platform.'), isTrue);
  });

  test('③ ★ 反向：把 `kIsWeb` 早返回拿掉后，判据必须变假', () {
    // 用"删掉那一段早返回"来模拟"有人把守卫删了"，
    // 而不是只调换断言方向（后者证明不了判据真的在看这个量）。
    final stripped = body.replaceAll(
      RegExp(r'if \(kIsWeb\) \{[\s\S]*?\n    \}', multiLine: true),
      '',
    );
    expect(stripped, isNot(body), reason: '没匹配到 kIsWeb 早返回 —— 守卫要跟着改');
    expect(guardedFromWeb(stripped), isFalse);
    expect(stripped.contains('Platform.'), isTrue);
  });

  test('③b ★ 同一个坑的其他两个入口也必须先短路 `kIsWeb`', () {
    // `Platform.environment` 在 web 上是**抛**（不是回空表）。这两个符号都是
    // 启动路径可达的：`isTestEnvironment` 由 `readDeviceModel()` 第一个求值，
    // `realEnvironmentLookup` 由路径层解析求值。
    for (final probe in const [
      ('lib/src/core/system_open.dart', 'bool get isTestEnvironment'),
      ('lib/src/core/platform/app_paths.dart', 'EnvironmentLookup get realEnvironmentLookup'),
    ]) {
      final src = stripLineComments(File(probe.$1).readAsStringSync());
      final at = src.indexOf(probe.$2);
      expect(at, greaterThan(0), reason: '找不到 ${probe.$2} —— 守卫要跟着改');
      // 取该声明之后的一小段（够覆盖表达式体/单行箭头体）
      final seg = src.substring(at, at + 400);
      final web = seg.indexOf('kIsWeb');
      final env = seg.indexOf('Platform.environment');
      expect(env, greaterThan(0), reason: '${probe.$2} 不再碰 Platform.environment？');
      expect(web, greaterThan(0), reason: '${probe.$2} 没判 kIsWeb');
      expect(web, lessThan(env), reason: 'kIsWeb 必须在 Platform.environment 左边（|| 从左短路）');
    }
  });

  test('④ 已知的第二个裸调用点（Android SDK 串）包了 try/catch', () {
    final i = body.indexOf('Platform.operatingSystemVersion');
    expect(i, greaterThan(0));
    final before = body.substring(0, i);
    final tryIdx = before.lastIndexOf('try {');
    final catchIdx = before.lastIndexOf('catch (');
    expect(
      tryIdx > catchIdx,
      isTrue,
      reason: 'Platform.operatingSystemVersion 不在最近的 try 里',
    );
  });
}
