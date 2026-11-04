// 只读截图工具（第 279 轮 macOS 取证）：
// 连上运行中的 Flutter App 的 VM service，调引擎的 `_flutter.screenshot`
// 拿**真实光栅化**的 PNG。为什么不用 `screencapture`：本机 TCC 未授权
// Screen Recording（`screencapture -x` 恒 `could not create image from display`），
// 而 VM service 这条路拿到的就是 App 自己画出来的那一帧。
//
// ⚠️ 需要 **Skia** 后端：Impeller 下 `_flutter.screenshot` 直接报
// `(-32000) Could not capture image screenshot`。所以 App 要用
// `flutter run -d macos --no-enable-impeller` 启动。
//
// 用法：dart run tool/r279_shot.dart <vm-service-ws-url> <out.png> [isolateId]
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: r279_shot.dart <ws-url> <out.png> [isolateId]');
    exit(64);
  }
  final url = args[0];
  final out = args[1];
  final vm = await vmServiceConnectUri(url);
  try {
    final vmInfo = await vm.getVM();
    final iso = args.length > 2
        ? args[2]
        : vmInfo.isolates!.firstWhere((i) => i.name == 'main').id!;
    final r = await vm.callServiceExtension('_flutter.screenshot', isolateId: iso);
    final json = r.json ?? const <String, Object?>{};
    final payload = json['result'] ?? json;
    final b64 = payload is Map ? payload['screenshot'] as String? : null;
    if (b64 == null || b64.isEmpty) {
      stderr.writeln('no screenshot in response: ${jsonEncode(json)}');
      exit(2);
    }
    File(out).writeAsBytesSync(base64Decode(b64));
    stdout.writeln('wrote $out ${File(out).lengthSync()} bytes');
  } catch (e) {
    stderr.writeln('ERR $e');
    exit(3);
  } finally {
    await vm.dispose();
  }
}
