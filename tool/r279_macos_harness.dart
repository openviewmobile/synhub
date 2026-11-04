// 第 279 轮：macOS 端到端**取证用**入口（不是产品入口，产品入口仍是 `lib/main.dart`）。
//
// ## 为什么需要它
//
// 本机 **没有** Screen Recording / Accessibility 的 TCC 授权：
//   * `screencapture -x` 恒报 `could not create image from display`；
//   * `osascript`（System Events）会卡在自动化授权上超时。
// ⇒ 既不能拍桌面，也不能合成鼠标/键盘事件。
//
// 所以本轮的"真跑 + 真拍 + 真驱动"走 **Flutter 自己的 VM service**：
//   * 像素：`tool/r279_shot.dart` 调引擎的 `_flutter.screenshot`
//     （⚠️ 需 Skia 后端：Impeller 下该扩展直接报 `(-32000)`，所以用
//      `flutter run -d macos --no-enable-impeller` 启动）；
//   * 驱动：本文件注册一个顶层函数 `r279(<json 命令>)`，用 VM service 的
//     `evaluate` 调用它。**跑的就是真实的 `SynologyChatApp`**（同一套 provider、
//     同一套页面、同一个会话控制器），只是把"点按钮"换成了"调函数"。
//
// ## 用法
//
//     flutter run -d macos --debug --no-enable-impeller -t tool/r279_macos_harness.dart
//     # 然后对着 VM service ws url：
//     dart run tool/r279_drive.dart <ws-url> connect http://127.0.0.1:18080
//     dart run tool/r279_drive.dart <ws-url> login mockuser mockpass
//     dart run tool/r279_drive.dart <ws-url> tab files
//
// ## 纪律
//
// * 这里**只有**连接 / 登录 / 切 tab / push 页面 / 读状态这几类动作；
// * 对真 NAS 只允许 login + 列目录这类**只读**动词（AGENTS §5.1）；
// * 不写任何产品状态，不进 `lib/`，`flutter analyze lib test tool/mock_dsm`
//   的覆盖面不受影响（本文件在 `tool/` 根，属于工具目录）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/router/app_router.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/notes/note_background_sync_scheduler.dart';
import 'package:synhub/src/features/notes/notes_page.dart' show NotesPage;
import 'package:synhub/src/features/diagnostics/diag_page.dart' show PlatformCapabilityPanel;
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/session_controller.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';

/// 最近一次命令的结果（JSON 字符串）。驱动器轮询它。
String r279Last = '{"state":"idle"}';

/// AHK 风格的分发：接一个 JSON 命令，异步执行，结果写进 [r279Last]。
String r279(String commandJson) {
  final decoded = jsonDecode(commandJson);
  if (decoded is! Map) return '{"state":"error","error":"not-a-map"}';
  final cmd = '${decoded['cmd']}';
  final nonce = '${decoded['nonce'] ?? ''}';
  // ★ 先把结果置成"在跑"，否则驱动器会读上一条命令的**陈旧结果**
  //   （第 279 轮踩过：`connect` 拿回了上一次 `ping` 的 `pong`）。
  r279Last = jsonEncode({'state': 'running', 'cmd': cmd, 'nonce': nonce});
  unawaited(_run(cmd, nonce, Map<String, dynamic>.from(decoded)));
  return '{"state":"started","cmd":"$cmd"}';
}

Future<void> _run(String cmd, String nonce, Map<String, dynamic> a) async {
  try {
    final result = await _dispatch(cmd, a);
    r279Last = jsonEncode({
      'state': 'ok',
      'cmd': cmd,
      'nonce': nonce,
      'result': result,
    });
  } catch (e, st) {
    r279Last = jsonEncode({
      'state': 'error',
      'cmd': cmd,
      'nonce': nonce,
      'error': _clip('$e', 300),
      'stack': _clip('$st'.split('\n').take(3).join(' | '), 300),
    });
  }
}

/// 把长串截断：`r279Last` 短了，驱动器就能一次读完（长串走 VM service
/// 会被截断；分片读时还可能踩到代理对边界）。
String _clip(String s, int n) =>
    s.length <= n ? s : '${s.substring(0, n)}...<clip>';

ProviderContainer get _container =>
    ProviderScope.containerOf(rootNavigatorKey.currentContext!);

void _pushCapsRoute() {
  rootNavigatorKey.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Platform capability')),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: const [PlatformCapabilityPanel(initiallyExpanded: true)],
        ),
      ),
    ),
  );
}

Future<Object?> _dispatch(String cmd, Map<String, dynamic> a) async {
  final c = _container;
  switch (cmd) {
    case 'ping':
      return 'pong';
    case 'state':
      final s = c.read(sessionControllerProvider);
      return {
        'connected': s.connected,
        'loggedIn': s.loggedIn,
        'busy': s.busy,
        'error': _clip(s.error ?? '', 200),
        'otpRequired': s.otpRequired,
        'baseUrl': s.connection?.endpoint.baseUrl,
        'account': s.session?.account,
        'sidPresent': (s.session?.sid ?? '').isNotEmpty,
        'activeNasId': s.activeNasId,
      };
    case 'connect':
      final url = '${a['url']}';
      final ok = await c
          .read(sessionControllerProvider.notifier)
          .connect(
            ServerProfile(kind: ServerAddressKind.direct, value: url),
          );
      return ok;
    case 'connectQC':
      final id = '${a['id']}';
      final ok = await c
          .read(sessionControllerProvider.notifier)
          .connect(
            ServerProfile(kind: ServerAddressKind.quickConnect, value: id),
          );
      return ok;
    case 'login':
      final ok = await c
          .read(sessionControllerProvider.notifier)
          .login(
            account: '${a['account']}',
            password: '${a['password']}',
            rememberDevice: a['remember'] == true,
          );
      return ok;
    case 'restore':
      final r = await c.read(sessionControllerProvider.notifier).restore();
      return r.name;
    case 'route':
      final path = '${a['path']}';
      appRouter.go(path);
      return path;
    case 'tab':
      final name = '${a['name']}';
      final tab = AppTab.values.firstWhere((t) => t.name == name);
      c.read(appTabProvider.notifier).select(tab);
      return tab.name;
    case 'pushCaps':
      // ⚠️ 必须**等这一帧画完**再 push：VM service 的 `evaluate` 会在
      //    构建/布局过程中被调用，直接 push 会撞
      //    `Build scheduled during frame`（第 279 轮实测）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pushCapsRoute();
      });
      return 'scheduled';
    case 'pushNotesDeferred':
      WidgetsBinding.instance.addPostFrameCallback((_) {
        rootNavigatorKey.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const NotesPage()),
        );
      });
      return 'scheduled';
    case 'pushCapsNow':
      _pushCapsRoute();
      return 'pushed';
    case 'pushCaps_unused':
      rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Platform capability')),
            body: ListView(
              padding: const EdgeInsets.all(12),
              children: const [PlatformCapabilityPanel(initiallyExpanded: true)],
            ),
          ),
        ),
      );
      return 'pushed';
    case 'pop':
      final can = rootNavigatorKey.currentState!.canPop();
      if (can) rootNavigatorKey.currentState!.pop();
      return can ? 'popped' : 'nothing-to-pop';
    case 'pushNotes':
      rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const NotesPage()),
      );
      return 'pushed';
    default:
      throw StateError('unknown cmd: $cmd');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final profile = DeviceProfile.detect();
  await NoteStationApi.initNoteDeviceName();
  await registerNoteBackgroundSync();
  final audioHandler = await createBackgroundAudioHandler();
  runApp(
    ProviderScope(
      overrides: [
        deviceProfileProvider.overrideWithValue(profile),
        biometricAuthenticatorProvider.overrideWithValue(
          LocalAuthBiometricAuthenticator(),
        ),
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const SynologyChatApp(),
    ),
  );
}
