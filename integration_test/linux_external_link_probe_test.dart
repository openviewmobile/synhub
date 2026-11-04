// r700b · Linux 外链路：App 交给**系统默认处理器**，我们证明它真的到了。
//
// 为什么不是"再测一次按钮能点"：`url_launcher_linux` 内部走
// `gtk_show_uri_on_window` / `g_app_info_launch_default_for_uri`
// （见 pub-cache 里 `url_launcher_linux/linux/url_launcher_plugin.cc`）——
// 也就是说"发没发给系统"只有**系统那一侧的处理器**能证明。
// 容器里没有真浏览器 ⇒ 装置侧装一个**假的默认处理器**（写一行到文件），
// 这样判据仍然是"外链真的交出去了"，而不是"函数返回了 true"。
//
// 装置准备（一次性，见 docs/evidence-r700-linux/README.md）：
//   /usr/local/bin/synhub-test-url-handler  ← 把收到的 URL 追加进日志
//   /usr/share/applications/synhub-test-url.desktop（x-scheme-handler/https）
//   xdg-mime default synhub-test-url.desktop x-scheme-handler/https
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:url_launcher/url_launcher.dart';

const String _logPath = '/tmp/synhub_url_open.log';
const String _url = 'https://example.com/r700-external?probe=1';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('外链：launchUrl(externalApplication) 必须真的到系统默认处理器', (
    tester,
  ) async {
    final log = File(_logPath);
    // 清空标记：只看**这一次**的投递
    if (log.existsSync()) log.deleteSync();

    // 先看 handler 在不在（不在就别把"装置缺失"记成产品缺陷）
    final req = Process.runSync('xdg-mime', [
      'query',
      'default',
      'x-scheme-handler/https',
    ]);
    final handler = (req.stdout as String).trim();
    expect(
      handler,
      contains('synhub-test-url'),
      reason: '装置侧默认处理器没设好（xdg-mime query 返回 "$handler"）',
    );

    final ok = await launchUrl(
      Uri.parse(_url),
      mode: LaunchMode.externalApplication,
    );
    // 给 GTK 一点点时间把子进程拉起来
    for (var i = 0; i < 40 && !log.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(ok, isTrue, reason: 'launchUrl 必须成功（系统有默认处理器时）');
    expect(log.existsSync(), isTrue, reason: '系统处理器必须被真的调用到');
    final content = log.readAsStringSync();
    // eslint-disable-next-line no-console
    // ignore: avoid_print
    print('[probe] handler=$handler log=$content');
    expect(
      content,
      contains('r700-external'),
      reason: '投递到处理器的 URL 必须是我们请求的那一条',
    );
  });
}
