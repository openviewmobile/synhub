// 第 293 轮：**"哪家宿主走 `flutter_secure_storage` 插件"这条机制的宿主侧守卫**。
//
// ## 为什么需要这个文件（而不是只改 `app_platform.dart`）
//
// 第 293 轮真 Windows 上的根因原文是**两个门同时为 false**：
//
// ```text
// [p1] _r293Probe seal BLOCKED plainLen=25 isSupported=false capAllowed=false
//      hostSupports=false inFlutterTest=false targetPlatform=windows
//      usesPluginSecureStorage=false isApple=false isLinux=false
//      channel=synhub/keystore
// [p1] _r293Probe plugin-direct write/read OK key=_r293probe readBackMatched=true
// ```
//
// * `capAllowed=false` ⇒ 能力层（`app_platform.dart`）说 Windows 没有安全存储；
// * `hostSupports=false` ⇒ `KeystoreSecretKeeper._usesPluginSecureStorage` 把
//   Windows 排除在插件之外；
// * 而**同一个进程里直连插件是成功的** ⇒ 插件没问题、选项没问题、异常也没被吞。
//
// ⇒ **只改一处等于没修**：能力层放行而 keeper 仍挡住 ⇒ 照旧明文落盘。
//   所以这个文件把 keeper 那一半用**纯函数**钉死，让"只改了一半"在离线测试里就红。
//
// ## 为什么能离线钉（本机是 macOS）
//
// `usesPluginSecureStorageFor()` / `secretKeeperHostSupportedFor()` 是**纯函数**
// （只看入参的 `TargetPlatform` / `isWeb` / `inFlutterTest`），不碰任何插件、
// 不依赖真机 ⇒ 宿主单元测试可以逐个平台断言，这正是第 109–290 轮做不到的部分。
//
// ⚠️ 但它**证明不了**"Windows 上 DPAPI 真能写" —— 那是真机档，见
// `docs/platform-windows.md` §15。这里只钉**选择逻辑**。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/security/keystore_secret_keeper.dart';

/// `AppHost` → `TargetPlatform` 的对照（web/unknown 没有对应物，单独处理）。
const Map<AppHost, TargetPlatform> kHostToTarget = {
  AppHost.android: TargetPlatform.android,
  AppHost.ios: TargetPlatform.iOS,
  AppHost.macos: TargetPlatform.macOS,
  AppHost.linux: TargetPlatform.linux,
  AppHost.windows: TargetPlatform.windows,
};

void main() {
  group('① 插件路线矩阵（逐平台写死 —— 第 293 轮新增的那条守卫）', () {
    test('★ 正向：走 `flutter_secure_storage` 的**恰好**这四家', () {
      final pluginHosts = <TargetPlatform>{
        for (final p in TargetPlatform.values)
          if (usesPluginSecureStorageFor(p)) p,
      };
      expect(pluginHosts, {
        TargetPlatform.macOS, // Keychain (darwin 插件)
        TargetPlatform.iOS, // Keychain (darwin 插件，同一份实现)
        TargetPlatform.linux, // libsecret
        // ★★ 第 293 轮新增。★ 反向验证：把这一行（以及
        //    `keystore_secret_keeper.dart` 里的 Windows）去掉，
        //    本用例当场红，红输出原文见 `docs/platform-windows.md` §15.5。
        TargetPlatform.windows, // DPAPI (flutter_secure_storage_windows 4.2.2)
      });
    });

    test('★ 反向：Android 与 Fuchsia **不在**插件路线里', () {
      // Android 走自研 `synhub/keystore` 通道（Kotlin Keystore）；
      // 把它顺手并进插件集合 = 真回归（真机上那时会去碰一个不存在的插件）。
      expect(usesPluginSecureStorageFor(TargetPlatform.android), isFalse);
      expect(usesPluginSecureStorageFor(TargetPlatform.fuchsia), isFalse);
    });

    test('★ Windows 必须**同时**过"宿主支持"这一关（能力门之外的另一半）', () {
      expect(
        secretKeeperHostSupportedFor(
          platform: TargetPlatform.windows,
          isWeb: false,
          inFlutterTest: false,
        ),
        isTrue,
        reason: 'Windows 上 `seal()` 要走到插件，这一条必须为 true —— '
            '第 293 轮真机根因就是它为 false',
      );
    });

    test('★ 反向：web / 测试环境一律挡掉（退化路径不许被放宽）', () {
      for (final p in TargetPlatform.values) {
        expect(
          secretKeeperHostSupportedFor(
            platform: p,
            isWeb: true,
            inFlutterTest: false,
          ),
          isFalse,
          reason: '${p.name}: web 上 dart:io 都没有',
        );
        expect(
          secretKeeperHostSupportedFor(
            platform: p,
            isWeb: false,
            inFlutterTest: true,
          ),
          isFalse,
          reason: '${p.name}: FLUTTER_TEST 下发消息给未注册 channel 会挂死',
        );
      }
    });

    test('★ 正向：真 App 进程里的四家 + Android 都"宿主支持"', () {
      for (final p in const [
        TargetPlatform.android,
        TargetPlatform.macOS,
        TargetPlatform.iOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      ]) {
        expect(
          secretKeeperHostSupportedFor(
            platform: p,
            isWeb: false,
            inFlutterTest: false,
          ),
          isTrue,
          reason: p.name,
        );
      }
      expect(
        secretKeeperHostSupportedFor(
          platform: TargetPlatform.fuchsia,
          isWeb: false,
          inFlutterTest: false,
        ),
        isFalse,
      );
    });
  });

  group('② 与能力层**同源**（两半必须一致，防"只改了一半"）', () {
    test('★ 能力层放行 `secureStorage` 的宿主，keeper 必须也走插件/通道', () {
      for (final entry in kHostToTarget.entries) {
        final host = entry.key;
        final platform = entry.value;
        final capabilitySaysYes =
            staticCapabilitiesFor(host).can(AppCapability.secureStorage);
        if (capabilitySaysYes) {
          expect(
            secretKeeperHostSupportedFor(
              platform: platform,
              isWeb: false,
              inFlutterTest: false,
            ),
            isTrue,
            reason: '${host.name}: 能力层说能存，keeper 却挡住了 ⇒ 实际会明文落盘',
          );
        }
      }
    });

    test('★ 反向：能力层**拦住**的宿主（web/unknown）不许出现在插件集合里', () {
      expect(
        staticCapabilitiesFor(AppHost.web).can(AppCapability.secureStorage),
        isFalse,
      );
      expect(
        staticCapabilitiesFor(AppHost.unknown).can(AppCapability.secureStorage),
        isFalse,
      );
      // 这两家在 `TargetPlatform` 上没有对应物 ⇒ 只能整体断言"能力层没放行"，
      // 且 web 一律被 `isWeb` 挡掉（上面 group ① 已逐平台覆盖）。
      expect(kHostToTarget.containsKey(AppHost.web), isFalse);
      expect(kHostToTarget.containsKey(AppHost.unknown), isFalse);
    });
  });

  group('③ "插件真的在"的 in-repo 依据（结论不许是编的）', () {
    test('★ 四家的联邦实现都能在生成产物里核到', () {
      final deps = jsonDecode(
        File('.flutter-plugins-dependencies').readAsStringSync(),
      ) as Map<String, Object?>;
      final plugins = deps['plugins'] as Map<String, Object?>;
      List<String> namesOf(String platform) =>
          (plugins[platform] as List<Object?>)
              .map((e) => (e as Map<String, Object?>)['name'] as String)
              .toList();

      expect(namesOf('windows'), contains('flutter_secure_storage_windows'));
      expect(namesOf('linux'), contains('flutter_secure_storage_linux'));
      expect(namesOf('macos'), contains('flutter_secure_storage_darwin'));
      expect(namesOf('ios'), contains('flutter_secure_storage_darwin'));

      // 生成注册表（每个宿主一份）也要有它 —— 只在依赖里而没进构建 = 空壳。
      expect(
        File('windows/flutter/generated_plugin_registrant.cc').readAsStringSync(),
        contains('FlutterSecureStorageWindowsPluginRegisterWithRegistrar('),
      );
      expect(
        File('linux/flutter/generated_plugin_registrant.cc').readAsStringSync(),
        contains('flutter_secure_storage_linux'),
      );
      // macOS/iOS 用的是 dartPluginClass 形态（注册表里不一定有 C++ 符号），
      // 所以这里只核依赖列 —— 如实标"这一条比 Windows/Linux 弱"。
      expect(
        File('pubspec.lock').readAsStringSync(),
        contains('flutter_secure_storage_darwin:'),
      );
    });
  });
}
