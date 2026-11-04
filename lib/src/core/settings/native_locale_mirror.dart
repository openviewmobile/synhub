import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 把「App 内语言」镜像成一个**原生可读的小文件**，供**由 Kotlin 生成**的
/// 文案（通知栏 / 前台服务 / 小组件）选择语言 —— 第 41 轮。
///
/// 为什么不用 SharedPreferences：本仓设置存在 **Drift 键值表**里（见
/// `app_settings.dart` 文件头），原生读不到；也不为一个字符串新增插件依赖。
/// 原生侧 `AppLang` 读 `files/app_locale.txt`：空 / `system` ⇒ 跟随系统语言。
const String kNativeLocaleFileName = 'app_locale.txt';

/// 镜像失败**不该影响任何功能**（原生侧会回退到系统语言）。
///
/// ⚠️ 不许用 `.timeout(...)` 兜挂起：`timeout` 会**留下 pending Timer**，
/// 而 `flutter test` 的 `AutomatedTestWidgetsFlutterBinding` 会断言
/// "widget 树销毁后不许还有 Timer"（实测：3 条切语言用例由"挂 10 分钟"
/// 变成"1 秒失败：A Timer is still pending"）。正确做法是**测试里直接不发**。
bool get _inFlutterTest {
  try {
    return Platform.environment['FLUTTER_TEST'] == 'true';
  } catch (_) {
    return true; // 拿不到环境（诡异平台）就当测试，别乱碰平台通道
  }
}
/// ★★ 第 42 轮（真红灯修复）：**必须带超时**。`flutter test` 里
/// `path_provider` 的平台通道没有实现，`getApplicationSupportDirectory()` 的
/// Future 在 fake async 下**永不完成** ⇒ 谁 `await` 它谁就挂住。
/// 后果实测：`app_identity_i18n_test.dart` 的 3 条切语言用例**各挂 10 分钟**
/// 后超时（全量基线从 `+10168` 掉到 `+10165 -3`）。
Future<void> mirrorAppLocaleToNative(String rawValue) async {
  // ① `flutter test` 里**一次都别调**：路径通道缺席，`getApplicationSupportDirectory()`
  //    的 Future 在 fake async 下永不完成 ⇒ 谁 await 谁挂（实测 10 分钟超时）。
  //    （与 `KeystoreSecretKeeper._inFlutterTest` 同一口径。）
  if (_inFlutterTest) return;
  try {
    final dir = await getApplicationSupportDirectory();
    await File('${dir.path}/$kNativeLocaleFileName').writeAsString(rawValue);
  } catch (_) {
    // 有意吞掉：见上（镜像只是给原生侧选语言用，失败就回落系统语言）
  }
}
