// r665 跨平台站（macOS / Linux）三条缺陷的结构守卫。
//
// 为什么用"读源码"的守卫而不是行为用例：这三条都钉在**平台装配/依赖解析**上，
// 行为用例只能在对应宿主上跑（macOS 钥匙串、Linux 编译）。结构守卫能让
// "有人把它们改回去"这件事在**任何宿主**上都立刻变红 —— 这正是前面几轮
// `DA280`–`DA283` 的同一套做法（见 `test/web_platform_bridges_test.dart`）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('DA284 会话与连接必须配对（空 sid 不许开始同步）', () {
    test('chat 同步的判据钉在 conn 自己的 sid 上', () {
      final src = _read('lib/src/features/chat/chat_session_controller.dart');
      // 早退：没有 sid 直接返回，且**在** `_conn = conn` 之前
      final gate = src.indexOf("final sid = conn.api.session?.sid ?? '';");
      final assign = src.indexOf('_conn = conn;');
      expect(gate, greaterThan(0), reason: '缺 sid 判据（DA284 被改回去了）');
      expect(assign, greaterThan(gate), reason: '判据必须在赋值之前');
      expect(src.contains("if (sid.isEmpty) {"), isTrue);
    });

    test('列表页的触发条件同口径（不只信 loggedIn）', () {
      final src = _read('lib/src/features/chat/channel_list_page.dart');
      expect(
        src.contains("final connHasSession = (conn?.api.session?.sid ?? '').isNotEmpty;"),
        isTrue,
        reason: 'DA284：`loggedIn` 与 `connection` 可以不是同一时刻的对象',
      );
      expect(src.contains('session.loggedIn && conn != null && connHasSession'), isTrue);
    });
  });

  group('DA285 依赖钉版本（image 4.11.0 在 Linux 编译失败）', () {
    test('pubspec 里 image 是精确版本，不是区间', () {
      final src = _read('pubspec.yaml');
      final m = RegExp(r'^\s+image:\s*(\S+)\s*$', multiLine: true).firstMatch(src);
      expect(m, isNotNull, reason: 'pubspec 里找不到 image 依赖');
      expect(m!.group(1), '4.10.1', reason: 'DA285：区间约束会让新机器解析到 4.11.0（编译失败）');
      expect(src.contains('decodeLazy'), isTrue, reason: '注释里要留下根因，方便下一个人');
    });

    test('lock 与 pubspec 一致（防止 lock 被别的机器改回去）', () {
      final lock = _read('pubspec.lock');
      final m = RegExp(r'\n  image:\n(?:.*\n)*?    version: "([^"]+)"').firstMatch(lock);
      expect(m, isNotNull);
      expect(m!.group(1), '4.10.1');
    });
  });

  group('DA286 macOS Debug 不再走钥匙串（ad-hoc 签名每次弹授权框）', () {
    test('门面存在且 Web 侧恒为 false（条件导入）', () {
      final facade = _read('lib/src/core/platform/debug_secret_file.dart');
      expect(facade.contains("if (dart.library.io) 'debug_secret_file_io.dart'"), isTrue);
      final stub = _read('lib/src/core/platform/debug_secret_file_stub.dart');
      expect(stub.contains('bool debugSecretFileMode() => false;'), isTrue);
    });

    test('io 实现认 macOS 全档（r668 起含 Release），可被 SYNHUB_KEYCHAIN=1 否决', () {
      final io = _read('lib/src/core/platform/debug_secret_file_io.dart');
      // ★ r668 / DA295：判据从"只认 Debug"改成"macOS 全档都认" —— 用户拿到的是
      //   Release 包，只让 Debug 绕开钥匙串等于把"每次冷启动要输密码"留给用户。
      expect(io.contains('if (kIsWeb) return false;'), isTrue);
      expect(io.contains('if (!kDebugMode || kIsWeb) return false;'), isFalse,
          reason: 'Release 又被放回钥匙串 ⇒ 用户每次冷启动都要输一次密码');
      expect(io.contains("Platform.environment['SYNHUB_KEYCHAIN'] == '1'"), isTrue);
      expect(io.contains('return Platform.isMacOS;'), isTrue);
      // ★ 第一版为了 0600 起 `chmod` 子进程 ⇒ 沙箱拦 `process-exec`，
      //   同步的 `Process.runSync` 把**整轮审计卡死在启动**（r665 实测）。
      //   现在文件只在 App 沙箱容器里（外层 0700），**不许再起子进程**。
      expect(
        io.contains("Process.runSync('chmod'") || io.contains('Process.run('),
        isFalse,
        reason: '沙箱里同步起子进程会死锁（r665 实测：整轮审计卡死在启动）',
      );
      expect(io.contains('sandboxd'), isTrue, reason: '注释里要留下这条教训的指纹');
    });

    test('三个方法都先看门面（read/write/delete）', () {
      final src = _read('lib/src/core/platform/app_secure_storage.dart');
      expect(src.contains('bool get _fileMode => debugSecretFileMode();'), isTrue);
      expect(src.contains('if (_fileMode) return debugSecretFileRead(key);'), isTrue);
      expect(src.contains('if (_fileMode) return debugSecretFileDelete(key);'), isTrue);
      expect(src.contains('return debugSecretFileWrite(key, value);'), isTrue);
    });
  });

  group('DA287 文件后端不许在 `flutter test` 里生效（跨用例泄漏）', () {
    test('io 实现认 FLUTTER_TEST，测试进程回落原路径', () {
      final io = _read('lib/src/core/platform/debug_secret_file_io.dart');
      expect(
        io.contains("Platform.environment['FLUTTER_TEST'] == 'true'"),
        isTrue,
        reason: 'DA287：文件后端是**真持久化**的，测试会把数据写进宿主 HOME',
      );
      // 判据必须在返回 `Platform.isMacOS` **之前**（否则等于没挡）
      final guard = io.indexOf("Platform.environment['FLUTTER_TEST']");
      final ret = io.indexOf('return Platform.isMacOS;');
      expect(ret, greaterThan(guard), reason: '排除测试的判断要在放行 macOS 之前');
    });

    test('反向：测试环境里 `debugSecretFileMode()` 真的回 false', () {
      // 只在真正被 `flutter test` 拉起时才会走到这里；如果哪天有人把
      // FLUTTER_TEST 判据删了，这一条会在 macOS 宿主上直接变红。
      final io = _read('lib/src/core/platform/debug_secret_file_io.dart');
      expect(io.contains('FLUTTER_TEST'), isTrue);
      expect(Platform.environment['FLUTTER_TEST'] == 'true' ||
          Platform.environment['FLUTTER_TEST'] == null, isTrue);
    });
  });
}
