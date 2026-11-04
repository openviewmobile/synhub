// 静态守卫：**「关于」页显示的版本号必须等于真实产物的版本号**。
//
// ★ 为什么会有这条（r349，D74，真机发现）：
//   `lib/src/features/settings/settings_page.dart` 里写着
//
//     /// App 版本（与 `pubspec.yaml` 的 `version:` 保持一致）
//     const String kAppVersion = '0.1.0+1';
//
//   那句注释是**愿望**，不是**机制** —— 而 `pubspec.yaml` 早就是 `1.0.0+1`，
//   装到 HONOR LGE-AN10 上的 APK `dumpsys package` 也报 `versionName=1.0.0`。
//   于是「关于」页逐字显示 `版本 0.1.0+1`。**三份表示，两个不同的值。**
//
// ★ 为什么原来的用例抓不到（AGENTS §2.0.29「修复必须带一条能红的用例」）：
//   `test/settings_test.dart` 里只有
//
//     expect(find.text(kAppVersion), findsOneWidget);
//
//   —— 它断言的是"**这个常量**画出来了"，**没有第二个来源可比**
//   ⇒ 常量改成什么它都绿，属于**构造性假绿**。
//
// ★ 本用例的判据：把 `pubspec.yaml`（真实产物的版本来源）当**独立第二来源**读进来，
//   逐字断言两者相等。**装回 `'0.1.0+1'` 就会红**（见文件末"反向验证"用例）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/settings/settings_page.dart' show kAppVersion;

/// 从 `pubspec.yaml` 顶部读出 `version:` 的值（`1.0.0+1` 这种，**去掉引号**）。
///
/// 只认顶层的 `^version:`（行首无缩进）—— `dependencies:` 里不会有这个名字的键，
/// 但用锚点更稳，免得将来某插件带了 `version:` 子键把判据带偏。
String? readPubspecVersion(String yaml) {
  for (final raw in yaml.split('\n')) {
    if (raw.startsWith('version:')) {
      return raw.substring('version:'.length).trim().replaceAll('"', '').replaceAll("'", '');
    }
  }
  return null;
}

void main() {
  group('D74 App 版本号必须与 pubspec.yaml 一致', () {
    test('★ DA3：kAppVersion == pubspec.yaml 的 version:', () {
      final yaml = File('pubspec.yaml').readAsStringSync();
      final want = readPubspecVersion(yaml);
      expect(want, isNotNull, reason: 'pubspec.yaml 里没读到顶层 version: —— 判据本身失效了');
      expect(
        kAppVersion,
        want,
        reason:
            '「关于」页写的版本必须与 pubspec.yaml 逐字相同（pubspec=$want，常量=$kAppVersion）。'
            '两者不一致时，用户看到的版本号与装到手机上的产物版本号会对不上。',
      );
    });

    test('版本号形状必须是 <x.y.z>+<build>（两段都在，别只写一半）', () {
      expect(
        RegExp(r'^\d+\.\d+\.\d+\+\d+$').hasMatch(kAppVersion),
        isTrue,
        reason: '期望形如 1.0.0+1，实际是 $kAppVersion',
      );
    });

    // ★★★ 反向验证（AGENTS §1.3.0.1「校验 0 条不是成功，是没校验」）：
    //   证明上面那个解析器**真的会读出东西**，而不是恒返回 null 让我"看起来通过"。
    test('装置自证：解析器能在构造的 yaml 上读出预期值', () {
      expect(readPubspecVersion('name: x\nversion: 9.9.9+42\ndeps: {}\n'), '9.9.9+42');
      expect(readPubspecVersion('name: x\n'), isNull);
    });
  });
}
