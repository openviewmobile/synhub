// D29 的守卫（第 328 轮）：本仓**只有一个** `FlutterSecureStorage` 构造点。
//
// 为什么必须做成结构性守卫：`flutter_secure_storage` 11.2.0 的
// `MacOsOptions.usesDataProtectionKeychain` 默认 **true** ⇒ macOS 上走
// **数据保护钥匙串** ⇒ 需要 `keychain-access-groups` 一族 entitlement。
// 本仓的 macOS 构建是 **ad-hoc 签名**（无 team ID）⇒ 写/删抛
// `PlatformException(-34018 "A required entitlement is not present.")`、
// 读返回 null ⇒ 所有 `catch (_)` 的 store 都**静默存不上**。
//
// 判据不是"我记得改了 8 处"，而是：
//   ① 全仓**只有** `app_secure_storage.dart` 里出现 `FlutterSecureStorage(`；
//   ② 工厂返回的实例上 `mOptions.usesDataProtectionKeychain == false`
//      （**行为**断言，不是文本断言）；
//   ③ 反向：把一个调用点改回 `const FlutterSecureStorage()` ⇒ ①红。
import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_secure_storage.dart';

void main() {
  group('第 328 轮 D29：`FlutterSecureStorage` 只有一个构造点', () {
    test('① 全仓只有 `app_secure_storage.dart` 构造 FlutterSecureStorage', () {
      final hits = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        // ★ 先剥掉行注释：**纯文本扫描会把注释里的字面量数进去**（§2.0.48 的坑，
        //   本用例第一版就被自己写的"不许用 const FlutterSecureStorage()"那句注释绊红）。
        final text = [
          for (final line in e.readAsStringSync().split('\n'))
            line.split('//').first,
        ].join('\n');
        // 只看**构造**（`FlutterSecureStorage(`），不看类型注解/`final` 字段声明。
        if (text.contains('FlutterSecureStorage(') &&
            !e.path.endsWith('core/platform/app_secure_storage.dart')) {
          hits.add(e.path);
        }
      }
      expect(
        hits,
        isEmpty,
        reason: '★ 这些文件自己造了 secure storage（macOS 上会静默存不上）：'
            '${hits.join(' / ')} —— 改成 `appSecureStorage(...)`',
      );
    });

    test('② 工厂真的关掉了 macOS"数据保护钥匙串"（行为断言）', () {
      // ★ `mOptions` 的**静态类型是 `AppleOptions`**（插件 11.2.0 的字段声明），
      //   实际对象是 `MacOsOptions` ⇒ 必须**转回子类**才看得到这个开关
      //   （这本身就是个坑：类型转换失败会静默用错默认值）。
      final mac = appSecureStorage().mOptions;
      expect(mac, isA<MacOsOptions>(), reason: 'mOptions 的实际类型必须是 MacOsOptions');
      expect(
        (mac as MacOsOptions).usesDataProtectionKeychain,
        isFalse,
        reason: '★ 插件默认是 true ⇒ ad-hoc 签名下 -34018（探针原文见证据 §4.5）',
      );
      // 反向：显式传 true 时工厂要**尊重**调用方（不是硬编码无视参数）
      expect(
        (appSecureStorage(
                  macos: const MacOsOptions(usesDataProtectionKeychain: true),
                ).mOptions
                as MacOsOptions)
            .usesDataProtectionKeychain,
        isTrue,
      );
      // 别的平台保持插件默认（本轮没有改非 macOS 语义）
      expect(appSecureStorage().aOptions.runtimeType, AndroidOptions);
    });

    test('④ 工厂返回的是**带闸门**的实例（不是裸插件实例）', () {
      // ★ 为什么要这条：`appSecureStorage()` 的返回类型是 `FlutterSecureStorage`，
      //   如果哪天有人把实现改回 `FlutterSecureStorage(...)`，**编译照样过**、
      //   ①② 也照样绿（`mOptions` 还是对的），但 D30 的闸门就没了
      //   ⇒ 必须有一条钉在**运行时类型**上的判据。
      final s = appSecureStorage();
      expect(s, isA<FlutterSecureStorage>(), reason: '仍必须是插件实例（调用点都按它声明）');
      expect(
        s.runtimeType,
        isNot(FlutterSecureStorage),
        reason: '★ 必须是闸门子类（否则钥匙串弹框会再次把 App 挂死，见 D30）',
      );
    });

    test('⑤ 闸门正常放行（有结果就原样返回）', () async {
      final gate = SecureStorageGate(timeout: const Duration(seconds: 1));
      expect(await gate.run(() async => 'v'), 'v');
      expect(gate.blocked, isFalse);
    });

    test('⑥ 等不到授权 ⇒ 超时抛 SecureStorageUnavailable（并进入熔断）', () async {
      final gate = SecureStorageGate(
        timeout: const Duration(milliseconds: 40),
        cooldown: const Duration(minutes: 5),
      );
      final never = Completer<String?>();
      await expectLater(
        gate.run(() => never.future),
        throwsA(isA<SecureStorageUnavailable>()),
      );
      expect(gate.blocked, isTrue, reason: '超时之后必须进入熔断窗口');
    });

    test('⑦ 熔断窗口内**立即**失败，且不再调底层（不白等第二次）', () async {
      final gate = SecureStorageGate(
        timeout: const Duration(milliseconds: 40),
        cooldown: const Duration(minutes: 5),
      );
      var calls = 0;
      await expectLater(
        gate.run(() {
          calls++;
          return Completer<String?>().future;
        }),
        throwsA(isA<SecureStorageUnavailable>()),
      );
      expect(calls, 1);
      final sw = Stopwatch()..start();
      await expectLater(
        gate.run(() {
          calls++;
          return Completer<String?>().future;
        }),
        throwsA(isA<SecureStorageUnavailable>()),
      );
      sw.stop();
      expect(calls, 1, reason: '★ 熔断期间底层操作**一次都不许**再发起');
      expect(
        sw.elapsed,
        lessThan(const Duration(milliseconds: 20)),
        reason: '★ 第二次必须是"立即"失败（实测 ${sw.elapsedMilliseconds}ms）',
      );
    });

    test('③ 至少有一个调用点真的用了工厂（防"工厂没人用"）', () {
      final users = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (e.path.endsWith('core/platform/app_secure_storage.dart')) continue;
        if (e.readAsStringSync().contains('appSecureStorage(')) {
          users.add(e.path);
        }
      }
      // 第 328 轮实测 7 个文件 / 8 处。给一个下限（不是精确值，避免每次加 store 都要改）
      expect(
        users.length,
        greaterThanOrEqualTo(7),
        reason: '★ 用了工厂的文件数必须是"实测那么多"（§2.0.45：封装了没人用 = 死功能）',
      );
    });
  });
}
