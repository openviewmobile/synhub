// ★ 第 259 轮真机缺陷回归：**原生媒体栈的 TLS 政策**必须跟着会话走。
//
// 背景（logcat 实证，见 `lib/src/core/net/media_tls_policy.dart` 文件头）：
// NAS 证书 `CN=nas.example.com`，App 用 IP `nas.example.com` 访问 ⇒
// Dart 侧（`DioFactory`）放行，原生侧（ExoPlayer / just_audio 的
// `HttpURLConnection`）严格主机名校验 ⇒ 视频与音频**都**播不了。
//
// 这个文件钉住三件事：
//   ① 宿主/测试环境（非 Android）**不碰**平台通道（既有用例不受影响）；
//   ② 下发的参数形态（主机名 + 大写指纹）、去重、空主机不下发；
//   ③ 登出会还原成平台默认（不把放宽留给下一个会话）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/media_tls_policy.dart';
import 'package:synhub/src/features/media/mpv_player_adapter.dart'
    show mpvTlsVerifyValue;
import 'package:synhub/src/core/platform/app_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    MediaTlsPolicy.resetForTest();
    MediaTlsPolicy.debugForceAndroid = false;
    debugForceAppHost = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MediaTlsPolicy.channel, (call) async {
          calls.add(call);
          return true;
        });
  });

  tearDown(() {
    MediaTlsPolicy.debugForceAndroid = false;
    MediaTlsPolicy.macosNativePlayerEnabled =
        MediaTlsPolicy.macosNativePlayerFromEnv;
    MediaTlsPolicy.iosNativePlayerEnabled = MediaTlsPolicy.iosNativePlayerFromEnv;
    // ★ 第 92 轮：`nativePlayerEnabled` 现在读能力层的 `currentAppHost`
    //   （可被 `debugForceAppHost` 覆盖）⇒ 必须在这里还原，否则会污染同进程的
    //   后续用例（"宿主判定"和"能力表"共用同一个全局）。
    debugForceAppHost = null;
    MediaTlsPolicy.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MediaTlsPolicy.channel, null);
  });

  group('① 没有自研播放器的宿主不碰平台通道', () {
    test('install / clear 都是 no-op', () async {
      // 前提（r87 更新）：macOS **默认开**自研播放器 ⇒ "宿主就一定是 no-op"
      // 不再成立。这里把开关显式关掉，断言的仍是**同一个**语义：
      // "这台宿主不会用自研播放器时，政策一个字节都不下发"。
      // 反向（默认开且是 macOS ⇒ 会下发）由 ④ 组钉住，覆盖没有减少。
      MediaTlsPolicy.macosNativePlayerEnabled = false;
      await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
      await MediaTlsPolicy.clear();
      expect(calls, isEmpty);
      expect(MediaTlsPolicy.installedKeyForTest, isNull);
    });
  });

  group('② 参数装配（纯函数）', () {
    test('IP 直连：主机名取 IP，无指纹 ⇒ fingerprint 为 null', () {
      expect(
        MediaTlsPolicy.payloadFor(baseUrl: 'https://nas.example.com:5001'),
        {'host': 'nas.example.com', 'fingerprint': null},
      );
    });

    test('QuickConnect/域名：主机名原样（那种证书本来就匹配，放宽是空操作）', () {
      expect(
        MediaTlsPolicy.payloadFor(baseUrl: 'https://nas.example.com:5001'),
        {'host': 'nas.example.com', 'fingerprint': null},
      );
    });

    test('★ 指纹统一成大写（与 TrustStore.sha256Hex 同构）', () {
      // 小写进来也必须变成大写：原生侧虽然 ignoreCase，但我们要
      // 「同一枚指纹只有一种表示」才好做去重 key。
      final p = MediaTlsPolicy.payloadFor(
        baseUrl: 'https://nas.example.com:5001',
        fingerprintSha256: 'ab12cd34ef56',
      );
      expect(p!['fingerprint'], 'AB12CD34EF56');
    });

    test('空指纹 = 没指纹（不钉证书，只放宽主机名）', () {
      expect(
        MediaTlsPolicy.payloadFor(
          baseUrl: 'https://nas.example.com:5001',
          fingerprintSha256: '',
        )!['fingerprint'],
        isNull,
      );
    });

    test('baseUrl 取不到主机名 ⇒ 不下发（宁可不放宽，也不放宽到空主机）', () {
      expect(MediaTlsPolicy.payloadFor(baseUrl: ''), isNull);
      expect(MediaTlsPolicy.payloadFor(baseUrl: 'not a url'), isNull);
    });
  });

  group('③ 强制 Android：下发 / 去重 / 还原', () {
    test('install 下发 host + 大写指纹，并记住；重复 install 不再发', () async {
      MediaTlsPolicy.debugForceAndroid = true;
      await MediaTlsPolicy.install(
        baseUrl: 'https://nas.example.com:5001',
        fingerprintSha256: 'ab12cd34',
      );
      expect(calls, hasLength(1));
      expect(calls.first.method, 'setTlsPolicy');
      expect(calls.first.arguments, {
        'host': 'nas.example.com',
        'fingerprint': 'AB12CD34',
      });
      // 同一组合不重复过通道（避免每次播放都打一次原生）
      await MediaTlsPolicy.install(
        baseUrl: 'https://nas.example.com:5001',
        fingerprintSha256: 'ab12cd34',
      );
      expect(calls, hasLength(1));
    });

    test('换了主机（切服务器）会重新下发', () async {
      MediaTlsPolicy.debugForceAndroid = true;
      await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
      await MediaTlsPolicy.install(baseUrl: 'https://192.168.0.99:5001');
      expect(calls, hasLength(2));
      expect(calls.last.arguments['host'], '192.168.0.99');
    });

    test('★ clear 还原平台默认（登出后不把放宽留给下一个会话）', () async {
      MediaTlsPolicy.debugForceAndroid = true;
      await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
      await MediaTlsPolicy.clear();
      expect(calls, hasLength(2));
      expect(calls.last.arguments, {'host': null, 'fingerprint': null});
      expect(MediaTlsPolicy.installedKeyForTest, isNull);
      // 还原后重复 clear 不再发
      await MediaTlsPolicy.clear();
      expect(calls, hasLength(2));
    });

    test('通道抛异常也不向外冒（加固失败不该打断连接/登出）', () async {
      MediaTlsPolicy.debugForceAndroid = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MediaTlsPolicy.channel, (call) async {
            throw PlatformException(code: 'boom');
          });
      await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
      await MediaTlsPolicy.clear();
      // 没抛异常就是通过
    });
  });

  // ★ 第 296 轮：macOS 上也接自研 AVPlayer 桥（`macos/Runner/MediaPlayerBridge.swift`），
  // 但**默认关**（没在真 NAS 上验证播放前不默认启用）。
  // 政策的下发必须与"这台宿主机真的会用自研播放器"对齐：否则会出现
  // "媒体闸门说能播、播放器根本握不上手"（`file_preview_page._certPinned`）。
  group('④ macOS 自研播放器开关决定政策是否下发', () {
    tearDown(() {
      MediaTlsPolicy.macosNativePlayerEnabled =
          MediaTlsPolicy.macosNativePlayerFromEnv;
    });

    test(
      '开关关（默认）⇒ macOS 宿主上不下发（闸门也不该被误开）',
      () async {
        MediaTlsPolicy.macosNativePlayerEnabled = false;
        expect(MediaTlsPolicy.nativePlayerEnabled, isFalse);
        await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
        expect(calls, isEmpty);
        expect(
          MediaTlsPolicy.isInstalledFor('https://nas.example.com:5001'),
          isFalse,
        );
      },
      skip: Platform.isMacOS ? null : '仅在 macOS 宿主上有意义（判定读 Platform.isMacOS）',
    );

    test(
      '开关开 ⇒ macOS 上按 host|fingerprint 下发，clear 还原',
      () async {
        MediaTlsPolicy.macosNativePlayerEnabled = true;
        expect(MediaTlsPolicy.nativePlayerEnabled, isTrue);
        await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
        expect(calls, hasLength(1));
        expect(calls.single.method, 'setTlsPolicy');
        expect(calls.single.arguments, {
          'host': 'nas.example.com',
          'fingerprint': null,
        });
        expect(
          MediaTlsPolicy.isInstalledFor('https://nas.example.com:5001'),
          isTrue,
        );
        await MediaTlsPolicy.clear();
        expect(calls.last.arguments, {'host': null, 'fingerprint': null});
        expect(MediaTlsPolicy.isInstalledFor('https://nas.example.com:5001'), isFalse);
      },
      skip: Platform.isMacOS ? null : '仅在 macOS 宿主上有意义（判定读 Platform.isMacOS）',
    );

    test('★ r87：默认值就是开（不再需要 --dart-define）', () {
      // r87 已在真 NAS 上验证播放（`docs/platform-macos.md` §3.7.7）⇒ 按
      // "验证通过即可用"把默认翻成 true。要退回旧行为才需要显式 dart-define。
      expect(MediaTlsPolicy.macosNativePlayerFromEnv, isTrue);
      expect(MediaTlsPolicy.macosNativePlayerEnabled, isTrue);
    });
  });

  // ⑤ scoped 语义的**离线**钉桩：放宽只对**当前会话那一台主机**生效。
  // 反向验证的判据是"另一个主机的请求没有被放宽"——这里用 Dart 侧可观测的
  // `payloadFor` / `isInstalledFor` 指认；原生 `MediaTrustDelegate` 真按同一
  // 判据放行的证据由 `tool/r87_scoped_tls_check.sh`（本机回环 + 自签证书，
  // **零外网**）给出，档位在 §3.7.7 如实标注。
  group('⑤ scoped：只放宽精确主机、指纹只在有指纹时钉住', () {
    test('install 一台主机后，另一台主机的请求未被放宽（反向验证）', () async {
      MediaTlsPolicy.debugForceAndroid = true;
      await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
      expect(
        MediaTlsPolicy.isInstalledFor('https://nas.example.com:5001'),
        isTrue,
        reason: '当前会话主机应被放宽',
      );
      expect(
        MediaTlsPolicy.isInstalledFor('https://192.168.0.99:5001'),
        isFalse,
        reason: '★ 反向：别的 NAS 的请求**没有**被放宽',
      );
      // 前缀不能误命中：`192.168.0.18` 与 `nas.example.com` 是两台不同的主机
      expect(
        MediaTlsPolicy.isInstalledFor('https://192.168.0.18:5001'),
        isFalse,
        reason: '★ 反向：主机名按 | 分隔精确比对，不做前缀匹配',
      );
      // 别的请求即使被拼成 payload，也不会去动已下发的那条政策
      expect(
        MediaTlsPolicy.payloadFor(baseUrl: 'https://192.168.0.99:5001')!['host'],
        '192.168.0.99',
      );
      expect(calls, hasLength(1));
      expect(calls.single.arguments['host'], 'nas.example.com');
    });

    test('没有指纹 ⇒ 不下发钉扎（fingerprint=null），链仍由系统 CA 校验', () async {
      MediaTlsPolicy.debugForceAndroid = true;
      await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
      expect(calls.single.arguments, {
        'host': 'nas.example.com',
        'fingerprint': null,
      });
    });

    test('有指纹 ⇒ 按那一枚钉住；换一枚指纹会重新下发', () async {
      MediaTlsPolicy.debugForceAndroid = true;
      await MediaTlsPolicy.install(
        baseUrl: 'https://nas.example.com:5001',
        fingerprintSha256: 'aa11',
      );
      expect(calls.single.arguments['fingerprint'], 'AA11');
      // 同一枚指纹去重
      await MediaTlsPolicy.install(
        baseUrl: 'https://nas.example.com:5001',
        fingerprintSha256: 'AA11',
      );
      expect(calls, hasLength(1));
      // 证书换了（新指纹）⇒ 必须把新钉扎送下去，不能吃旧 key
      await MediaTlsPolicy.install(
        baseUrl: 'https://nas.example.com:5001',
        fingerprintSha256: 'bb22',
      );
      expect(calls, hasLength(2));
      expect(calls.last.arguments['fingerprint'], 'BB22');
    });

    test('登出还原后，同一台主机也不再被放宽（反向验证）', () async {
      MediaTlsPolicy.debugForceAndroid = true;
      await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
      await MediaTlsPolicy.clear();
      expect(
        MediaTlsPolicy.isInstalledFor('https://nas.example.com:5001'),
        isFalse,
        reason: '★ 反向：登出后原主机也回到平台默认',
      );
      expect(calls.last.arguments, {'host': null, 'fingerprint': null});
    });
  });

  // ★★ 第 92 轮 iOS 迁移：政策下发是"这台宿主会不会用自研桥"的函数，
  // 而 iOS 与 macOS **共用同一份 Swift 桥** ⇒ iOS 也必须按 host|fingerprint 下发，
  // 否则 iOS 上会退化成 macOS r87 之前那种"闸门说能播、播放器握不上手"。
  //
  // 这里用 `debugForceAppHost` 把宿主钉成 iOS —— 这正是把宿主判据从裸
  // `dart:io Platform` 换成 `currentAppHost` 的目的：**在本机（macOS 宿主）上
  // 也能测 iOS 这一列**。反向验证：开关关掉 ⇒ 一个字节都不下发。
  group('⑥ iOS：与 macOS 同一份桥 ⇒ 默认下发政策；关掉开关即不下发', () {
    test('iOS + 默认开 ⇒ 下发 host/fingerprint，clear 还原', () async {
      debugForceAppHost = AppHost.ios;
      expect(MediaTlsPolicy.iosNativePlayerFromEnv, isTrue);
      expect(MediaTlsPolicy.nativePlayerEnabled, isTrue);

      await MediaTlsPolicy.install(
        baseUrl: 'https://nas.example.com:5001',
        fingerprintSha256: 'aa11',
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setTlsPolicy');
      expect(calls.single.arguments, {
        'host': 'nas.example.com',
        'fingerprint': 'AA11',
      });
      expect(
        MediaTlsPolicy.isInstalledFor('https://nas.example.com:5001'),
        isTrue,
      );

      await MediaTlsPolicy.clear();
      expect(calls.last.arguments, {'host': null, 'fingerprint': null});
      expect(
        MediaTlsPolicy.isInstalledFor('https://nas.example.com:5001'),
        isFalse,
      );
    });

    test('★ 反向：iOS 开关关掉 ⇒ 判定为 false 且不下发任何字节', () async {
      debugForceAppHost = AppHost.ios;
      MediaTlsPolicy.iosNativePlayerEnabled = false;
      expect(MediaTlsPolicy.nativePlayerEnabled, isFalse);

      await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
      expect(calls, isEmpty, reason: '★ 反向：开关关掉时政策不许下发');
    });

    test('★ 反向：iOS 的开关**不影响** macOS 那一列（两个开关各自独立）', () async {
      MediaTlsPolicy.iosNativePlayerEnabled = false;
      debugForceAppHost = AppHost.macos;
      MediaTlsPolicy.macosNativePlayerEnabled = true;
      expect(MediaTlsPolicy.nativePlayerEnabled, isTrue);
      await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
      expect(calls, hasLength(1), reason: 'iOS 开关关掉不该连坐 macOS');
    });

    test('★ 反向：Linux/Windows 上没有自研桥 ⇒ 判定 false、不下发', () async {
      for (final host in const [AppHost.linux, AppHost.windows]) {
        calls.clear();
        MediaTlsPolicy.resetForTest();
        debugForceAppHost = host;
        expect(MediaTlsPolicy.nativePlayerEnabled, isFalse, reason: host.name);
        await MediaTlsPolicy.install(baseUrl: 'https://nas.example.com:5001');
        expect(calls, isEmpty, reason: host.name);
      }
    });
  
  // ★ r678（`DA311`）：兜底引擎（libmpv）也要拿到**同一份** TLS 事实。
  // 主引擎走 `synhub/player` 通道（AVFoundation 桥），libmpv 收不到那条政策 ⇒
  // 不翻译的话，真 NAS（自签 + 主机名不匹配）在兜底引擎上会重新"能播本地、
  // 播不了 NAS"。判据：**只放当前会话那台主机**，别的源照旧严格校验。
  group('⑤ libmpv 的 tls-verify 跟着同一份政策走（DA311）', () {
    test('政策下发过 ⇒ no；没下发过 ⇒ yes（反向，不是恒 no）', () async {
      debugForceCapabilityGate = true;
      addTearDown(() => debugForceCapabilityGate = false);
      debugForceAppHost = AppHost.ios;
      const nas = 'https://nas.example.com:5001/webapi/entry.cgi?api=X';
      const other = 'https://example.com/v.mp4';

      expect(mpvTlsVerifyValue(nas), 'yes', reason: '还没下发之前不许放宽');
      await MediaTlsPolicy.install(
        baseUrl: 'https://nas.example.com:5001',
        fingerprintSha256: 'ab' * 32,
      );
      expect(mpvTlsVerifyValue(nas), 'no', reason: '这台主机已按会话放宽');
      expect(
        mpvTlsVerifyValue(other),
        'yes',
        reason: '别的源必须照旧严格校验（放宽只放精确主机）',
      );
    });
  });
});
}
