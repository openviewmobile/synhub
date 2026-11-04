// iOS 的 A 轨：**用户现选目录**（`synhub/iosfsexport`）—— 第 333 轮补，
// 对应 `docs/platform-ios.md` 的 A 轨 row 11。
//
// ## 为什么必须有这条桥（这是对齐，不是新功能）
//
// `save_destination.dart` 的双轨里，A 轨（用户挑目录）在 **macOS** 走
// `file_picker` 的 `NSOpenPanel`（`getDirectoryPath`），在 **iOS** 上
// 那条 API 是 **desktop-only**（`file_picker` 的 Dart 侧直接在非桌面宿主上
// 抛 `UnimplementedError`）⇒ iOS 永远只能落到 B 轨（`<Documents>/downloads`）。
// 后果不是崩溃，而是**与官方 App 的能力差距**：
// 官方 Synology Photos/Drive 在 iOS 上能把文件存进用户在「文件」App 里
// 自选的目录（iCloud Drive / On My iPhone 的任意位置 / 第三方 provider）。
//
// iOS 上这件事只有一条合法路径 —— `UIDocumentPickerViewController`
// 用 **folder** 打开，然后对返回的 URL 调
// `startAccessingSecurityScopedResource()` 拿到**进程级**的临时授权
// （iOS 没有 macOS 那种 app-scope bookmark 免弹窗续期；每次都要用户点一次，
// 所以这里**不假装记住**，与 iOS 的系统语义一致）。
//
// ## 为什么"选目录"与"写文件"要分成两次调用
//
// 因为**写文件的命名/不覆盖策略只有一份实现**（`save_destination.dart` 的
// `saveFileToDirectory`：同名自动加 ` (1)`）。若让 Swift 端自己 copy，那份
// 策略就会变成两份 ⇒ 迟早发散（§2.0.26"同一语义不许有两份表示"）。
// 所以：`pickDirectory` 只负责"选 + 持有授权"并回一个 **token**，
// 真正的 copy 仍由 Dart 做（安全作用域是进程级的，Dart 的 `dart:io` 写得进去），
// 用完由调用方 `release(token)` **成对**关闭（不关会泄漏，长跑后系统拒绝再开）。
//
// ## 纯净性
//
// 本文件只做"通道 → 记录"的翻译，**不含任何弹窗逻辑**（用例注入假通道）；
// 生产构造点只有 `media_store_save.dart` 里的一处（且**只在 iOS 宿主**构造）。
library;

import 'package:flutter/services.dart';

import 'app_platform.dart';

/// 用户在「文件」App 里挑中的目录 + 这次授权的句柄。
///
/// [token] 是 Swift 侧生成的 UUID，用来在写完文件后关闭安全作用域。
/// [scoped] 是 `startAccessingSecurityScopedResource()` 的原始返回值 ——
/// ★ 它**不是**"能不能写"的判据（同一个 URL 本进程已经开过时系统会回
/// `false`，而那时照样能写；§2.0.58 在 macOS 书签上踩过同型），
/// 只用来在诊断面板里区分"系统说它没给新授权"与"根本没走到"。
class IosPickedDirectory {
  const IosPickedDirectory({
    required this.path,
    required this.token,
    required this.scoped,
  });

  final String path;
  final String token;
  final bool scoped;

  @override
  String toString() =>
      'IosPickedDirectory($path, token=${token.isEmpty ? '—' : token}, scoped=$scoped)';
}

/// `synhub/iosfsexport` 的 Dart 侧（Swift `IosFsExportBridge.swift`）。
abstract interface class IosFsExportBridge {
  /// 桥在不在（原生没编进去 / 老构建 ⇒ false，**不抛**）。
  Future<bool> isSupported();

  /// 弹系统文件夹选择器。
  ///
  /// 返回 `null` 的三种情况**都要走 B 轨**（不崩溃、也不说"存好了"）：
  /// 用户取消、桥不可用（能力门/通道缺失）、原生报错。
  Future<IosPickedDirectory?> pickDirectory();

  /// 关闭这次安全作用域（**成对**；token 不认识时静默）。
  Future<void> release(String token);
}

/// 生产实现。
class MethodChannelIosFsExportBridge implements IosFsExportBridge {
  MethodChannelIosFsExportBridge([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('synhub/iosfsexport');

  final MethodChannel _channel;

  /// 能力门（`test/method_channel_gate_guard_test.dart` 要求的那个"命名门"）。
  ///
  /// 复用 [AppCapability.documentPicker]：这条桥**就是** iOS 的系统文档/目录
  /// 选择器（`UIDocumentPickerViewController`），而该能力位在 iOS 上本来就是
  /// `available`（随包的 `file_picker_darwin`）⇒ 语义一致。
  /// ★ 桥本身只在 **iOS 宿主**构造（见 `media_store_save.dart`），
  /// 所以 macOS 上能力位为真也**不会**去调一条不存在的通道。
  static bool get _allowed => capabilityGateAllows(AppCapability.documentPicker);

  static void _logBlocked(String method) {
    assert(() {
      // ignore: avoid_print
      print('[iosfsexport] blocked method=$method（能力位不可用）');
      return true;
    }());
  }

  @override
  Future<bool> isSupported() async {
    if (!_allowed) {
      _logBlocked('isSupported');
      return false;
    }
    try {
      final r = await _channel.invokeMethod<bool>('isSupported');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<IosPickedDirectory?> pickDirectory() async {
    if (!_allowed) {
      _logBlocked('pickDirectory');
      return null;
    }
    try {
      final r = await _channel.invokeMethod<Object?>('pickDirectory');
      final m = r is Map ? r : null;
      if (m == null) return null;
      // 原生明确说"用户取消了" ⇒ 与 null 同义（调用方只关心"这次没得用"）。
      if (m['cancelled'] == true) return null;
      final path = m['path'];
      if (path is! String || path.isEmpty) return null;
      final token = m['token'];
      return IosPickedDirectory(
        path: path,
        token: token is String ? token : '',
        scoped: m['scoped'] == true,
      );
    } catch (_) {
      // 通道缺失 / 弹不出来（没有 key window）/ 原生报错 —— 一律交回 B 轨
      return null;
    }
  }

  @override
  Future<void> release(String token) async {
    if (!_allowed || token.isEmpty) return;
    try {
      await _channel.invokeMethod<Object?>('release', {'token': token});
    } catch (_) {
      // 关不掉不影响本次保存的结果（只是允许泄漏一次授权）；不抛。
    }
  }
}
