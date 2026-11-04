// r714 · Windows 外链路：App 交给**系统默认处理器**，我们证明它真的到了。
//
// 判据为什么必须跨进程：`url_launcher_windows` 走 `ShellExecuteEx`
// （见 pub-cache 里 `url_launcher_windows/windows/url_launcher_plugin.cpp`），
// 函数返回 `true` 只代表"调用没报错"。真到没到，只有**另一个进程**能证明。
//
// 本仓 Windows 侧的外链**不走** `systemOpen`/`SystemOpenRunner`（那个入口只收
// 本地文件路径，见 `lib/src/core/system_open.dart`），走的是 `url_launcher`
// （`chat/url_actions.dart` / `notes/note_mail.dart` / `files/drive_share_page.dart` …）。
// 所以这里直接用同一个插件、同一个 `LaunchMode.externalApplication`。
//
// 装置前提：guest 上装了 Edge（Windows 11 自带）。判据取三样：
//   ① `launchUrl` 返回 true；
//   ② **新出现**一个浏览器进程（`msedge` / `chrome` / `firefox`，pid 不在基线里）；
//   ③ 该进程的窗口标题里出现我们请求的主机名 `example.com`
//      —— 挡住"浏览器早就在跑，这次其实没投递"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:url_launcher/url_launcher.dart';

const String _host = 'example.com';
const String _url = 'https://example.com/r714-external?probe=1';
const List<String> _browsers = ['msedge', 'chrome', 'firefox'];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('外链：launchUrl(externalApplication) 必须真到系统默认处理器', (
    tester,
  ) async {
    // 基线：现在已经在跑的浏览器进程（Edge 的"启动加速"常驻，不能算我们的）
    final before = <String, int>{};
    for (final name in _browsers) {
      for (final pid in _pids(name)) {
        before['$name:$pid'] = pid;
      }
    }
    // ignore: avoid_print
    print('[probe] baseline browsers=$before');

    final ok = await launchUrl(
      Uri.parse(_url),
      mode: LaunchMode.externalApplication,
    );
    expect(ok, isTrue, reason: 'launchUrl 必须返回 true（ShellExecute 成功）');

    // 等新进程 / 等窗口标题出现（最多 ~30 s：冷启动 Edge 会慢）
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    String? hitName;
    String? hitTitle;
    while (DateTime.now().isBefore(deadline)) {
      for (final name in _browsers) {
        for (final pid in _pids(name)) {
          if (before.containsKey('$name:$pid')) continue;
          final title = _title(pid);
          // ignore: avoid_print
          print('[probe] new browser $name/$pid title="$title"');
          if (title.toLowerCase().contains(_host)) {
            hitName = name;
            hitTitle = title;
          }
        }
      }
      if (hitName != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    expect(
      hitName,
      isNotNull,
      reason: '必须出现**新的**浏览器进程且窗口标题含 $_host'
          '（只回 true 不算：那只是 ShellExecute 没报错）',
    );
    // ignore: avoid_print
    print('[probe] DELIVERED $hitName title="$hitTitle" url=$_url');
  });
}

/// 某个映像名当前的 pid 列表（`tasklist` 比 WMI 快且不需要 COM）。
List<int> _pids(String imageName) {
  final r = Process.runSync('tasklist', ['/FI', 'IMAGENAME eq $imageName.exe', '/NH', '/FO', 'CSV']);
  final out = (r.stdout as String).trim();
  if (out.isEmpty || out.startsWith('INFO:')) return const [];
  final pids = <int>[];
  for (final line in out.split('\n')) {
    final cells = line.trim().split('","');
    if (cells.length < 2) continue;
    final pid = int.tryParse(cells[1].replaceAll('"', '').trim());
    if (pid != null) pids.add(pid);
  }
  return pids;
}

/// 取该 pid 的窗口标题（没有窗口就是空串）。
String _title(int pid) {
  final r = Process.runSync('powershell', [
    '-NoProfile',
    '-Command',
    r'(Get-Process -Id ' + pid.toString() + r' -ErrorAction SilentlyContinue).MainWindowTitle',
  ]);
  return (r.stdout as String).trim();
}
