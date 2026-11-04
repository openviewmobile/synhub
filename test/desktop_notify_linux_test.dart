// r693 · Linux 桌面通知（`org.freedesktop.Notifications`）的**判据**用例。
//
// 这一份故意**不跑真通知**（宿主是 macOS，没有 `notify-send`，也不该在单测里
// 弹系统通知）。它守的是三件事：
//   ① `resolveOnPath` 的行为（PATH 上有就返回绝对路径、没有就 null）；
//   ② 能力位判据钉在**客户端在不在 PATH 上**，而不是"我们有没有写代码"——
//      缺客户端必须 fail-closed（否则界面会说"已发送"而其实什么也没发生）；
//   ③ 非 Linux 宿主上这条能力**不允许**因为"代码写了"就变成 available。
//
// 真链路的读数在容器里：`integration_test/linux_notification_probe_test.dart`
// （日志 `docs/evidence-r693b-linux/notification-integration.log`）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/platform/desktop_notify_linux.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('notify_probe');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('① resolveOnPath：PATH 上有就给绝对路径，没有就 null', () {
    final bin = File('${tmp.path}${Platform.pathSeparator}notify-send')
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    final env = {'PATH': tmp.path};
    expect(resolveOnPath('notify-send', env: env), bin.path);
    expect(resolveOnPath('definitely-not-here-xyz', env: env), isNull);

    // 空目录 ⇒ null（不是"随便返回点什么"）
    final empty = Directory('${tmp.path}${Platform.pathSeparator}empty')
      ..createSync();
    expect(resolveOnPath('notify-send', env: {'PATH': empty.path}), isNull);
    // PATH 里的空段（`::`）必须跳过，不能当"当前目录"
    expect(resolveOnPath('notify-send', env: {'PATH': '::'}), isNull);
  });

  test('② 能力判据：客户端不在 PATH 上 ⇒ linuxNotifyClientOnPath=false', () {
    expect(linuxNotifyClientOnPath(env: {'PATH': tmp.path}), isFalse);
    File('${tmp.path}${Platform.pathSeparator}notify-send')
        .writeAsStringSync('#!/bin/sh\nexit 0\n');
    expect(linuxNotifyClientOnPath(env: {'PATH': tmp.path}), isTrue);
  });

  test('③ 非 Linux 宿主：这条能力不许变成 available（fail-closed）', () {
    // 宿主是 macOS/Windows 时，`Platform.isLinux` 为 false ⇒ 一律不可用，
    // 与"我们有没有写 Linux 实现"无关。
    if (!Platform.isLinux) {
      expect(linuxDesktopNotifyAvailable(), isFalse);
      final cap = AppPlatformCapabilities.current();
      final status = cap.statusOf(AppCapability.localNotifications);
      expect(status.isAvailable, isFalse,
          reason: '非 Linux 宿主上 localNotifications 必须如实不可用');
    }
  });
}
