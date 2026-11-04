// `platformNetworkCountryIso()` —— QuickConnect 区域判定（概念②）的 **MCC 输入通路**。
//
// ## 为什么需要它（这一路是**新增**的）
// D4 把端点顺序对齐官方客户端后，剩下一个没对齐的口子：**只看 locale** 会把
// "系统语言设成英文、**人在中国**"的用户判成非中国区 ⇒ 官方客户端先试
// `global.quickconnect.cn`，我们却先试 `global.quickconnect.to` ⇒ **首次登录更慢**。
// 官方靠 `QuickConnectUtil.isDeviceInChina(Context)` 的**第一顺位**
// `TelephonyManager.getNetworkCountryIso()` 兜住这一类；本文件验的就是这条通路。
//
// ## 证据（`[取证]`）
// * 官方 APK `Android-DSfinder.2.5.7-484.ww.apk`（样例库）的
//   `com/synology/sylibx/syhttp3/util/QuickConnectUtil.smali`：
//   MCC **非空 ⇒ `"cn".equals(iso, ignoreCase)` 并到此为止**（不看 locale）；
//   为空才回落 `getResources().getConfiguration().locales[0].getISO3Country()=="CHN"`。
//   它调的是 `getNetworkCountryIso()`（**网络**注册地），
//   **不是** `getSimCountryIso()`（SIM 归属）—— 两个不同的语义。
// * 本仓实现挂在**已有**的 `synhub/network` 桥（`NetworkBridge.kt`，与
//   `ConnectivityManager` 那路同一个 object、同一个通道）上，走**已有**的
//   `AppCapability.networkInfo` 能力门 —— **不新开通道、不新造平台信息抽象**。
//
// ## 这个文件能证明什么 / 不能证明什么
// ✅ 能：① 拿不到（门关 / 桥抛异常 / 空值 / 空白）**一律 `null`，绝不 `false`**
//        ——「不知道」必须与「不在中国」分开（AGENTS §2.0.26④："回 false 就是编结论"）；
//        ② 门开着时**真的**去问桥，且方法名就是那个常量；
//        ③ Dart 侧的方法名常量与 `NetworkBridge.kt` 的 `when` 分支**静态逐字对上**。
// ❌ 不能：真机上 `getNetworkCountryIso()` 实际回什么（漫游 / 高铁 / Wi-Fi-only 平板 /
//        纯 WiFi 无蜂窝的设备）—— 那要真机，见 `docs/android-ui-screenshot-audit.md` §4 U17。
//
// ★★ **为什么单独一个文件、不和 `serv_api_test.dart` 放一起**：
// 本文件要 Mock 平台通道 ⇒ 必须初始化 `TestWidgetsFlutterBinding`；
// 而这个 binding 会把 `HttpOverrides` 换成 mock ⇒ 同文件里那些
// **真 loopback `HttpServer`**（`FakeServ`）会被打红。
// 两个需求互斥，故分文件（不是重复覆盖）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/network_type.dart';
import 'package:synhub/src/core/platform/app_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('synhub/network');

  group('D4d platformNetworkCountryIso：拿不到一律 null（不是 false）', () {
    late List<MethodCall> calls;

    /// 装上假桥：记录调用 + 按 [handler] 作答。
    void mockBridge(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            calls.add(call);
            return handler(call);
          });
    }

    setUp(() {
      calls = <MethodCall>[];
      // ★ 明确钉住宿主为 macOS：这样"门是关的"这条结论**与跑测机器无关**
      // （不依赖本机恰好是 macOS）。
      debugForceAppHost = AppHost.macos;
      debugForceCapabilityGate = false;
      mockBridge((_) async => 'cn');
    });

    tearDown(() {
      debugForceAppHost = null;
      debugForceCapabilityGate = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('① 能力门关闭（非 Android）⇒ null，且**连通道都不碰**', () async {
      expect(
        capabilityGateAllows(AppCapability.networkInfo),
        isFalse,
        reason: 'macOS 宿主上 networkInfo 是 unavailable ⇒ 门必须关着',
      );

      expect(await platformNetworkCountryIso(), isNull);
      expect(
        calls,
        isEmpty,
        reason: '门没开就不许碰通道（宿主要走"没有这项能力"，不是 MissingPluginException）',
      );
    });

    test('② 门开 + 桥回值 ⇒ 原样返回（反向验证：这道门不是恒假）', () async {
      debugForceCapabilityGate = true;

      expect(await platformNetworkCountryIso(), 'cn');
      expect(
        calls.map((c) => c.method),
        [kNetworkCountryIsoMethod],
        reason: '真的问了桥，且方法名就是那个常量（不是别的拼法）',
      );
    });

    test('③ 桥抛异常（没有电话服务 / 平台未实现）⇒ null，不抛给调用方', () async {
      debugForceCapabilityGate = true;
      mockBridge((_) async => throw PlatformException(code: 'no-telephony'));

      expect(await platformNetworkCountryIso(), isNull);
      expect(calls, hasLength(1), reason: '确实试过桥（不是被门拦下的）');
    });

    test('④ 桥回空串 / 空白 / null ⇒ null（**不是 false**）', () async {
      debugForceCapabilityGate = true;

      for (final Object? raw in <Object?>['', '   ', null]) {
        mockBridge((_) async => raw);
        expect(
          await platformNetworkCountryIso(),
          isNull,
          reason: 'raw=${raw == null ? 'null' : '"$raw"'} ⇒ "没有结论"，'
              '交给 locale 回落；回 false 就把它伪造成"不在中国"了',
        );
      }
    });

    test('⑤ 值两端空白裁掉（桥回 " cn " ⇒ "cn"）', () async {
      debugForceCapabilityGate = true;
      mockBridge((_) async => ' cn ');

      expect(await platformNetworkCountryIso(), 'cn');
    });

    test('⑥ 大小写**原样透传**（归一化在 deviceInChinaFrom 里做，不在这一层）', () async {
      debugForceCapabilityGate = true;
      mockBridge((_) async => 'CN');

      expect(
        await platformNetworkCountryIso(),
        'CN',
        reason: '这一层只负责"取到没取到"，判定归 ServApi.deviceInChinaFrom',
      );
    });
  });

  // ★★ 跨语言契约守卫。
  // 为什么必须有：Mock 通道**证不了** Kotlin 侧的方法名 —— 它会照着 Dart 传的名字
  // 答应。真把 `NetworkBridge.kt` 的分支改名，Dart 侧单测**全绿**，而真机上
  // `invokeMethod` 落到 `else -> notImplemented()` ⇒ 抛 `MissingPluginException`
  // ⇒ 我们静默回 null ⇒ 又变回"只看 locale"。这正是 §2.0.12「Mock 全绿、真机崩」
  // 的同族形态，只能靠静态比对源文件挡住。
  group('D4d 跨语言契约：Dart 方法名常量 == NetworkBridge.kt 的分支', () {
    final ktFile = File(
      'android/app/src/main/kotlin/com/openviewai/synhub/NetworkBridge.kt',
    );

    test('① Kotlin 的 when 分支与 kNetworkCountryIsoMethod 逐字一致', () {
      expect(ktFile.existsSync(), isTrue, reason: '要在仓库根目录跑');
      final src = ktFile.readAsStringSync();

      expect(
        src.contains('"$kNetworkCountryIsoMethod" ->'),
        isTrue,
        reason:
            'NetworkBridge.kt 里找不到 "$kNetworkCountryIsoMethod" -> 分支；'
            'Dart 侧常量与 Kotlin 侧方法名必须逐字相同',
      );
    });

    test('② 用的是 getNetworkCountryIso()（网络注册地），不是 getSimCountryIso()', () {
      final src = ktFile.readAsStringSync();

      expect(
        src.contains('getNetworkCountryIso'),
        isTrue,
        reason: '官方 smali 调的就是 getNetworkCountryIso()',
      );
      expect(
        src.contains('getSimCountryIso'),
        isFalse,
        reason: 'SIM 归属是另一个语义，官方没有用它判区域',
      );
    });

    test('③ Dart 侧通道名与 Kotlin 的 CHANNEL 一致', () {
      final kt = ktFile.readAsStringSync();
      expect(kt.contains('const val CHANNEL = "synhub/network"'), isTrue);

      final dart = File('lib/src/core/net/network_type.dart').readAsStringSync();
      expect(dart.contains("MethodChannel('synhub/network')"), isTrue);
      expect(
        dart.contains('invokeMethod<String>(kNetworkCountryIsoMethod)'),
        isTrue,
        reason: '调用点必须走那个常量，否则契约就断了',
      );
    });
  });
}
