// r684（s284）· iOS 上的打洞**全栈回环**：真库的两侧在同一个进程里对接
//
// 与宿主档 `test/punch_tunnel_loopback_test.dart` 同一个装置
// （`test/support/punch_loopback.dart`）：假 echo 服务器 + 假 NAS + 两个真库
// 实例（被动方 listener / 发起方 client）。iOS 上库是静态链进进程的，所以
// `libraryPath` 传 null（走 `DynamicLibrary.process()`）。
//
// 判据（四条，缺一条就不算"隧道通了"）：
//   ① 被动方 `prepare()` 给出 UDT 监听端口；
//   ② 假 echo 真收到打洞命令（打洞交换跑了）；
//   ③ 对端引擎把 `ping` 拨到了本地服务端口（假的 NAS 收到了）；
//   ④ 同一个 `ping` 的 `pong` 回到发起方本地 TCP 客户端（数据双向）。
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/punch_loopback.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('s284 全栈回环：打洞 → UDT → 双引擎 → ping/pong 穿隧道', (tester) async {
    final r = await runPunchLoopback();
    // ignore: avoid_print
    print('[r684] udtPort=${r.udtPort} initTcp=${r.initiatorTcpPort} '
        'passiveTcp=${r.passiveTcpPort} echoReq=${r.echoRequests} '
        'nasSeen=${r.nasSeen} reply=${r.reply}');

    expect(r.udtPort, greaterThan(0), reason: '被动方 prepare 必须给出 UDT 端口');
    expect(r.echoRequests, greaterThan(0), reason: '打洞命令真的发出去了');
    expect(r.nasSeen, contains('ping'), reason: '对端引擎真的拨到了本地服务端口');
    expect(r.reply, contains('pong'), reason: '数据穿过隧道回来了');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
