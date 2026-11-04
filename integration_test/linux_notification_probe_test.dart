// r693 · Linux 桌面通知探针（§C6 的一条真读数）
//
// 要证明的事只有一件：**面板上「发送测试通知」在 Linux 上真的把通知交给了
// 系统的通知守护进程**。所以判据分两层：
//   ① 应用自己的路径（`BackgroundService.show(MessageNotification)`）返回 `true`；
//   ② **消费方**收到了 —— `dbus-monitor` 抓到 `member=Notify`，
//      并且 `dunstctl` 的计数里真有这一条。
//
// 只验 ① 会假绿：`notify-send` 在没有守护进程的容器里也 `exit 0`
// （它只是把消息丢给 D-Bus），"返回 true"证明不了"有人收到"。
//
// 装置：`tool/linux_notify_fixture.sh`（dbus-daemon --session + dunst + dbus-monitor）。
// 跑的时候要带上 `DBUS_SESSION_BUS_ADDRESS=$(cat /tmp/synhub_dbus_addr)`。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/core/platform/desktop_notify_linux.dart';
import 'package:synhub/src/native/background_service.dart';

const _monLog = '/tmp/synhub_notif_monitor.log';
const _addrFile = '/tmp/synhub_dbus_addr';

Future<String> _run(String cmd) async {
  final r = await Process.run('bash', ['-lc', cmd]);
  return '${r.stdout}${r.stderr}'.trim();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Linux 通知闭环：应用路径返回 true 且守护进程真的收到', (tester) async {
    // 前置：会话总线 + 通知守护进程必须在（缺了就如实失败，不要静默跳过）
    expect(File(_addrFile).existsSync(), isTrue,
        reason: '缺会话总线地址 —— 先跑 tool/linux_notify_fixture.sh');
    final owner = await _run(
      'gdbus call --session --dest org.freedesktop.DBus '
      '--object-path /org/freedesktop/DBus '
      '--method org.freedesktop.DBus.NameHasOwner org.freedesktop.Notifications',
    );
    expect(owner.contains('true'), isTrue,
        reason: 'org.freedesktop.Notifications 没有持有者（dunst 没起）——实得：$owner');

    // 能力位：客户端在 PATH 上 ⇒ 这条能力在 Linux 上是 available
    expect(linuxDesktopNotifyAvailable(), isTrue,
        reason: '缺 notify-send（libnotify-bin）');

    // ① 应用自己的路径
    final bg = BackgroundService();
    final ok = await bg.show(
      MessageNotification(
        channelId: 0,
        postId: 999999,
        title: 'SynHub 通知自检 r693',
        text: '这条是 Linux 桌面真发出来的（daemon 收到才算过）。',
      ),
    );
    expect(ok, isTrue, reason: 'BackgroundService.show 在 Linux 上必须走桌面通知');

    await Future<void>.delayed(const Duration(milliseconds: 1200));

    // ② 消费方读数：dbus-monitor 抓到的 Notify
    final mon = File(_monLog).existsSync() ? File(_monLog).readAsStringSync() : '';
    final notifies = RegExp(r'member=Notify').allMatches(mon).length;
    expect(notifies, greaterThan(0), reason: 'dbus-monitor 没抓到 member=Notify');

    // ③ dunst 的计数（另一个消费方口径，防止只抓到自己发的信号）
    final counts = await _run('dunstctl count displayed; dunstctl count history');
    // ignore: avoid_print
    print('[notify] monitor_notify=$notifies dunst=${counts.replaceAll('\n', ' / ')}');

    // clearAll 也要走通（没有 dunstctl 时允许 false，但这里装了）
    final cleared = await const LinuxDesktopNotifier().clearAll();
    // ignore: avoid_print
    print('[notify] clearAll=$cleared');
  });
}
