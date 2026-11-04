// 跨平台桥的**契约守卫**（r664：`DA279` / `DA280` / `DA281` / `DA282`）。
//
// 这四条都是"**原生才有的能力被无条件调用**"造成的：Web 站编译不过 / 连不上 /
// 实时通道死，iOS 与 macOS 一启动就白屏。修法统一是**条件导入 + 平台门控**，
// 而这类修法最容易"改完看着对、其实平台判据写错"，所以这里用**能跑在 VM 上的
// 判据**把契约钉住（Web 侧那份实现另有浏览器取证：`docs/evidence-r664/`）。
//
// 判据分两类：
//   ① **反向判据**：在 VM（非 Web）上，Web 专用入口必须**给 null / 不生效** ⇒
//      原生路径与改动前逐字一致（`web_dio_adapter.dart` 的桩）；
//   ② **正向判据**：桥接层只认"真正能用的宿主对象"，别的一律拒绝
//      （`MpvPropertyBridge.forPlatform` / `SocketLike` 的窄接口）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/web_dio_adapter.dart';
import 'package:synhub/src/data/remote/socket/socket_connector.dart';
import 'package:synhub/src/features/media/mpv_property_bridge.dart';

void main() {
  group('DA280 Web 才用的 HTTP 适配器：原生侧必须是 null（走 IOHttpClientAdapter）',
      () {
    test('DA280 createWebHttpClientAdapter() 在 VM 上返回 null', () {
      expect(
        createWebHttpClientAdapter(),
        isNull,
        reason: 'DA280：VM/原生上必须回落 IOHttpClientAdapter（返回 null 即"别用我"）',
      );
    });
  });

  group('DA279 libmpv 属性桥：只认真正的原生播放器', () {
    test('DA279 非 NativePlayer 的平台对象 ⇒ 桥为 null（不碰 getProperty/setProperty）', () {
      // Web 侧 `NativePlayer` 是 media_kit 的 stub，**没有** getProperty/setProperty；
      // 修复前 `mpv_player_adapter` 直接调它们 ⇒ `flutter build web` 编译失败。
      expect(MpvPropertyBridge.forPlatform(null), isNull);
      expect(MpvPropertyBridge.forPlatform('not-a-player'), isNull);
      expect(MpvPropertyBridge.forPlatform(Object()), isNull);
    });
  });

  group('DA281 WebSocket 连接：跨平台窄接口', () {
    test('DA281 openSocket 在原生侧真的能连上，且只暴露 SocketLike 三件事', () async {
      // 起一个最小的 websocket 服务端（真握手，不是 mock 类）
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((data) {
          if (data == 'ping') ws.add('pong');
        });
      });

      final socket = await openSocket(
        Uri.parse('ws://127.0.0.1:${server.port}/sc/socket.io'),
      );
      addTearDown(socket.close);

      final got = <dynamic>[];
      final sub = socket.frames.listen(got.add);
      addTearDown(sub.cancel);

      socket.send('ping');
      for (var i = 0; i < 100 && got.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(got, contains('pong'), reason: 'DA281：原生连接器必须真的收发帧');
    });

    test('DA281 SocketLike 只有 frames/send/close（不许把 dart:io 类型漏出去）',
        () {
      // 编译期判据：接口里出现 `WebSocket`/`HttpClient` 就说明又绑回 dart:io 了。
      final src = File('lib/src/data/remote/socket/socket_connector_base.dart')
          .readAsStringSync();
      // ★ 只认**真的 import 行**：注释里提到 `dart:io` 不算（本仓闸门吃过
      //   "把注释里的键名也数进去"的亏，见 AGENTS §2.0.52）。
      expect(src.contains("import 'dart:io';"), isFalse,
          reason: 'DA281：共用声明不许 import dart:io');
      expect(src.contains('class SocketLike'), isTrue);
      expect(src.contains('Stream<dynamic> get frames'), isTrue);
    });
  });

  group('DA282 media_kit 初始化必须按平台门控且不许拦住启动', () {
    test('DA282 main.dart 只在 Android 上调 MediaKit.ensureInitialized()，且包在 try/catch',
        () {
      final src = File('lib/main.dart').readAsStringSync();
      final call = src.indexOf('MediaKit.ensureInitialized()');
      expect(call, greaterThan(0), reason: 'DA282：初始化调用本身要留着');
      final head = src.substring(0, call);
      expect(
        head.contains('defaultTargetPlatform == TargetPlatform.android'),
        isTrue,
        reason: 'DA282：非 Android 平台没有 Mpv.framework ⇒ 必须门控，否则启动即崩',
      );
      // try/catch：即使 Android 上 libmpv 出了问题，也不许把 App 拦在启动前
      final guard = src.substring((call - 400).clamp(0, call), call);
      expect(guard.contains('try {'), isTrue, reason: 'DA282：初始化失败不许拦住启动');
      expect(
        src.contains('catch (e, st)'),
        isTrue,
        reason: 'DA282：失败要 log 并降级（视频退回主引擎），不是抛出去',
      );
    });
  });

  group('DA283 底部遥测带吃满父级宽度', () {
    test('DA283 DataStrip 的 SizedBox 给了 width: double.infinity', () {
      final src = File('lib/src/core/ui/tech_frame.dart').readAsStringSync();
      final i = src.indexOf('class _DataStripState');
      expect(i, greaterThan(0));
      final body = src.substring(i);
      expect(
        body.contains('width: double.infinity'),
        isTrue,
        reason: 'DA283：只给 height 会让内部 Stack 量出 0 宽 ⇒ 塌成 32×30.8 灰方块',
      );
      // 几何判据在 test/data_strip_width_test.dart（真跑一次布局）
      expect(
        File('test/data_strip_width_test.dart').existsSync(),
        isTrue,
        reason: 'DA283：几何回归用例必须在（宽度/文字可见性）',
      );
    });
  });

  group('编码/解码常量（防止本文件被当成"只读文档"误改）', () {
    test('jsonEncode 往返（占位判据：确保 dart:convert 真的可用）', () {
      expect(jsonDecode(jsonEncode({'ok': true})), {'ok': true});
    });
  });
}
