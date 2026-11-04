// r711（W-B9）：Windows 站两条**产品行为**的宿主侧判据。
//
// ① 单实例：点系统通知时 Windows 会再起一个进程（MSIX 的 AUMID 激活没有
//    "转发给已运行实例"的语义）。r711 实测过：点通知后进程数 1 → 2
//    （pid 8524 登录态 + pid 6276 新实例，新窗口是「离线」）。
//    修法在 `windows/runner/main.cpp`（命名互斥量 + EnumWindows 找窗口）。
//    C++ 在这里测不到，所以本文件只锁"判据的文字/常量层面不被改回去"：
//    文件名与关键字必须仍在，且必须带 `Local\` 前缀（每个会话一个实例，
//    不是整机一个）。
//
// ② 测试通知的副标题：Windows 上不许承诺「回复/已读/贪睡」按钮
//    —— toast XML 里没有 `<actions>`/`<input>`（`GetHistory` 原文可证）。
//    判据抽成可注入函数，因为宿主机上 `Platform.isWindows` 恒为 false。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/settings/notification_settings_page.dart';

void main() {
  test('① windows/runner/main.cpp 仍有单实例闸门（命名互斥量 + 找已有窗口）', () {
    final f = File('windows/runner/main.cpp');
    expect(f.existsSync(), isTrue, reason: 'Windows runner 不见了');
    final src = f.readAsStringSync();
    expect(src.contains('SynHub.SingleInstance'), isTrue,
        reason: 'r711 的单实例互斥量名被改了/删了');
    expect(src.contains(r'L"Local\\SynHub.SingleInstance"'), isTrue,
        reason: '必须是 Local\\ 前缀：每个登录会话一个实例，不是整机一个');
    expect(src.contains('ERROR_ALREADY_EXISTS'), isTrue,
        reason: '没有"已存在就退出"的判据，等于没做单实例');
    expect(src.contains('FindRunningMainWindow'), isTrue,
        reason: '没有把已运行窗口提到前台，点通知仍会"什么都没发生"');
    // 闸门必须在 COM/引擎初始化**之前**：否则第二个实例已经把引擎起完了
    final gate = src.indexOf('SynHub.SingleInstance');
    final com = src.indexOf('CoInitializeEx');
    expect(gate, greaterThan(0));
    expect(com, greaterThan(0));
    expect(gate, lessThan(com), reason: '单实例闸门必须早于 CoInitializeEx');
  });

  test('①b main.cpp 必须是纯 ASCII（MSVC 在 936 代码页下 C4819 当错误）', () {
    // r711 实测：中文注释进 main.cpp 后，guest 上是
    //   error C4819（treated as error）+ 一串假 "undeclared identifier"
    //   —— GBK 尾字节 0x5C 把下一行吞了。所以这个文件只许 ASCII。
    final bytes = File('windows/runner/main.cpp').readAsBytesSync();
    final nonAscii = bytes.where((b) => b > 0x7f).length;
    expect(nonAscii, 0, reason: 'main.cpp 里出现了 $nonAscii 个非 ASCII 字节');
  });

  test('② Windows 的测试通知副标题不承诺动作按钮（可注入判据）', () {
    const generic = 'generic-hint';
    const windows = 'windows-hint';
    expect(
      notifSendTestHintText(generic: generic, windows: windows, isWindows: true),
      windows,
    );
    expect(
      notifSendTestHintText(
          generic: generic, windows: windows, isWindows: false),
      generic,
    );
  });
}
