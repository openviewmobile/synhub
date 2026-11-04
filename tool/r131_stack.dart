// r131 诊断：把**卡住的 macOS App** 的 Dart 调用栈抓出来。
//
// 为什么需要它：逐屏走查里发现某一屏会让 UI isolate 在**一帧内无限递归**
// （宿主 `sample` 显示 `Animator::BeginFrame → Dart` 栈反复同一组帧、App CPU 100%
// 然后 0%，界面从此不再出帧）。Dart 侧的符号只有 VM service 能解。
//
// 用法：dart run tool/r131_stack.dart <vm-service-http-url>
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final uri = args.isNotEmpty ? args.first : '';
  if (uri.isEmpty) {
    stderr.writeln('usage: r131_stack.dart <vm-service-http-url>');
    exit(64);
  }
  final ws = uri
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/$'), '/ws');
  final svc = await vmServiceConnectUri(ws);
  final vm = await svc.getVM();
  for (final ref in vm.isolates ?? const []) {
    stdout.writeln('=== isolate ${ref.id} ${ref.name}');
    try {
      final stack = await svc.getStack(ref.id!, limit: 60);
      for (final f in stack.frames ?? const []) {
        final name = f.function?.name ?? '?';
        final file = f.location?.script?.uri ?? '';
        final line = f.location?.line ?? 0;
        stdout.writeln('  $name  ($file:$line)');
      }
    } catch (e) {
      stdout.writeln('  getStack failed: $e');
    }
  }
  stdout.writeln(jsonEncode({'ok': true}));
  await svc.dispose();
}
