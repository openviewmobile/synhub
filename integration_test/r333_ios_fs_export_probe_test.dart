// r333：iOS 上 `synhub/iosfsexport` 桥的**注册探针**（模拟器，不需要人手点）。
//
// 为什么单独一条：A 轨的"选目录"面板本体**必须有人手点**（模拟器上没法自动
// 点「文件」App 的目录）⇒ 面板行为进未验清单；但"**桥到底在不在**"是纯机制量，
// 可以被钉住 —— 而它恰恰是这次改动最容易漏的一环（Swift 文件要同时进
// `project.pbxproj` 的 Sources 阶段 + `AppDelegate` 的 registrar，漏一个就
// `MissingPluginException`，而 Dart 侧会**静默**退 B 轨、看起来"一切正常"）。
//
// 跑法（AGENTS §2.0.20⑤：参数在用例内给默认值）：
//   export PATH="<flutter-sdk>/bin:$PATH"
//   flutter test integration_test/r333_ios_fs_export_probe_test.dart \
//     -d A9D73490-69EC-4346-88D1-6ACAEFD58147 --timeout 600s
//
// ★ 反向验证也在这一条里：拿一个**不存在的通道名**去问，必须得到 false ——
//   否则"true"可能只是"我永远回 true"（§2.0.30 的同型）。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/platform/ios_fs_export.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('r333：iOS 的 synhub/iosfsexport 已注册（且反向：假通道必须是 false）',
      (tester) async {
    final bridge = MethodChannelIosFsExportBridge();
    expect(
      await bridge.isSupported(),
      isTrue,
      reason: '★ 桥必须真的编进 App 并在 AppDelegate 里注册：'
          'Swift 文件漏进 project.pbxproj 的 Sources 阶段、或漏了 registrar，'
          '这里就会是 false（Dart 侧会静默退 B 轨，看不出问题）',
    );

    // 反向：同样的 Dart 代码、换一个没人注册的通道名 ⇒ 必须 false。
    // 这一条同时证明上面的 true 不是"无条件 true"。
    final bogus = MethodChannelIosFsExportBridge(
      const MethodChannel('synhub/iosfsexport_not_registered'),
    );
    expect(
      await bogus.isSupported(),
      isFalse,
      reason: '反向验证：通道不存在时必须如实说 false（MissingPluginException 被吃成 false）',
    );
  });
}
