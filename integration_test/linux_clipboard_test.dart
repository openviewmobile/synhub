// r701 · 深度项：Linux **系统剪贴板**的真往返（判据在 App 之外）。
//
// 为什么这条要单独立案：`Clipboard.setData/getData` 在 `flutter_test` 里是**假通道**
// （用例里写进去再读回来永远成功），证明不了"系统剪贴板里真有这段字"。
// 这里用 `xclip`（X11 的官方命令行客户端，**另一个进程**）当判据：
//   ① App 写 → `xclip -o` 读得到；
//   ② `xclip -i` 写 → App 读得到（含中文：验的是 UTF-8 目标格式，不是 ASCII 运气）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<String> _xclipOut() async {
  final r = await Process.run('xclip', ['-o', '-selection', 'clipboard']);
  return '${r.stdout}';
}

Future<void> _xclipIn(String text) async {
  final p = await Process.start('xclip', ['-i', '-selection', 'clipboard']);
  p.stdin.write(text);
  await p.stdin.close();
  final code = await p.exitCode;
  expect(code, 0, reason: 'xclip -i 失败');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('① App 写 → 另一个进程（xclip）读得到', (tester) async {
    const marker = 'r701-clipboard-from-app';
    await Clipboard.setData(const ClipboardData(text: marker));
    // GTK 写选区是异步的：轮询到 xclip 读出来（最多 5 s）
    var got = '';
    for (var i = 0; i < 25 && got != marker; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      got = (await _xclipOut()).trim();
    }
    expect(got, marker, reason: 'xclip 读到的应该是 App 刚写的这段字');
  });

  testWidgets('② xclip 写 → App 读得到（中文 UTF-8）', (tester) async {
    const marker = 'r701 中文剪贴板 ✅';
    await _xclipIn(marker);
    String? got;
    for (var i = 0; i < 25; i++) {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      got = data?.text;
      if (got == marker) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(got, marker, reason: 'App 应该读到系统剪贴板里的中文');
  });
}
