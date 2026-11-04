// 标准 integration_test 驱动（配合 `flutter drive --keep-app-running` 使用，
// 见 AGENTS §2.0.1⑤：`flutter test integration_test/...` 会卸载并清空 App 数据）。
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
