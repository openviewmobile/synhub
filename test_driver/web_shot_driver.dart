// r666-web：`flutter drive` 的 extended driver。
// 把 `takeScreenshot(name)` 收到的 PNG 写到 `/tmp/r666_web_ui/<name>.png`。
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final dir = Directory('/tmp/r666_web_ui')..createSync(recursive: true);
  await integrationDriver(
    onScreenshot: (String name, List<int> image, [Map<String, Object?>? args]) async {
      File('${dir.path}/$name.png').writeAsBytesSync(image);
      stdout.writeln('[web-shot] $name ${image.length}B');
      return true;
    },
  );
}
