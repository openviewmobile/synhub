// macOS **Debug** 档的凭据后端：App 沙箱里的一个 `0600` JSON。
// 语义见 `debug_secret_file.dart` 的文件头（ad-hoc 签名 ⇒ 钥匙串每次弹框）。
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// 是否走"文件后端"（Debug + macOS + 没被 `SYNHUB_KEYCHAIN=1` 显式否决 + 不在测试里）。
bool debugSecretFileMode() {
  if (kIsWeb) return false;
  // ★ r668 / DA295：**Release 也走文件**（原来是 `!kDebugMode ⇒ false`）。
  //   用户拿到的是 Release 包，一冷启动就弹「SynHub 想使用您钥匙串中的机密信息」
  //   （用户当面追问两次"怎么老要我输密码？"）。根因不会因为在 Release 就消失：
  //   **ad-hoc 签名每次构建都变 ⇒ 登录钥匙串 ACL 永远不认识新构建**。
  //   所以"只有 Debug 绕开钥匙串"等于把问题留给用户。现在 macOS 全档走
  //   App 沙箱里的 0600 文件；要验证钥匙串那条路仍可 `SYNHUB_KEYCHAIN=1`。
  try {
    if (Platform.environment['SYNHUB_KEYCHAIN'] == '1') return false;
    // ★ r665 教训二：文件后端是**真持久化**的，而 `flutter test` 也在
    //   macOS Debug 下跑 ⇒ 用例会把数据写进宿主的
    //   `~/Library/Application Support/synhub/debug_secrets.json`，
    //   再被后面的用例读到 —— 实测 `photo_seen_tags_v1` 就是这样跨用例泄漏，
    //   让「没有标签 → 空态提示」的两条用例稳定变红（空态被本机记忆顶掉）。
    //   测试进程带 `FLUTTER_TEST=true`，直接回落原路径（用例各自的内存桩）。
    if (Platform.environment['FLUTTER_TEST'] == 'true') return false;
    return Platform.isMacOS;
  } catch (_) {
    return false; // 拿不到环境（诡异宿主）⇒ 走原路径
  }
}

File _storeFile() {
  final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
  final dir = Directory('$home/Library/Application Support/synhub');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final f = File('${dir.path}/debug_secrets.json');
  if (!f.existsSync()) {
    f.writeAsStringSync('{}');
  }
  return f;
}

// ★ r665 实测教训：**沙箱里不许 `Process.runSync`**。
//   第一版为了把文件设成 `0600` 起了 `chmod` 子进程 —— 沙箱（App 有
//   `com.apple.security.app-sandbox`）直接拦 `process-exec`，而这个调用是
//   **同步**的：整轮逐屏审计从此**卡死在启动**（0 张图、进程 0% CPU、
//   `sample` 里主线程在 `mach_msg` 等 sandboxd）。
//   现在的做法：文件就在 **App 沙箱容器**里
//   （`~/Library/Containers/<bundle>/Data/...`），外层容器本身就是 `0700`、
//   只有本用户可读 —— **不再起子进程**，也不再假装自己做 chmod。
Map<String, String> _load() {
  try {
    final raw = _storeFile().readAsStringSync();
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return <String, String>{
        for (final e in decoded.entries) '${e.key}': '${e.value}',
      };
    }
  } catch (_) {}
  return <String, String>{};
}

/// ★ r670：把凭据文件收紧成 **0600**。
///
/// 之前这里写着"外层容器 0700 兜底，所以不 chmod" —— 但实测新建文件是
/// **0644**（`ls -l` 证据：`-rw-r--r-- debug_secrets.json`），而 DA295 的
/// 收口口径是 0600。沙箱里**不许起子进程**（r665 踩过：同步起进程会把
/// 整轮审计卡死），所以直接 `dart:ffi` 调 libc 的 `chmod`：不 exec、
/// 不进 shell，沙箱放行。
void _restrictTo0600(File f) {
  if (!Platform.isMacOS && !Platform.isLinux) return;
  try {
    final lib = ffi.DynamicLibrary.process();
    final chmod = lib.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Int32),
        int Function(ffi.Pointer<ffi.Char>, int)>('chmod');
    final path = f.path.toNativeUtf8();
    try {
      chmod(path.cast(), 0x180); // 0o600
    } finally {
      malloc.free(path);
    }
  } catch (_) {
    // 平台没有 chmod（或符号缺失）⇒ 保持默认（容器 0700 仍是最后一道门）
  }
}

void _save(Map<String, String> data) {
  final f = _storeFile();
  f.writeAsStringSync(jsonEncode(data));
  _restrictTo0600(f);
}

Future<String?> debugSecretFileRead(String key) async => _load()[key];

Future<void> debugSecretFileWrite(String key, String value) async {
  final data = _load()..[key] = value;
  _save(data);
}

Future<void> debugSecretFileDelete(String key) async {
  final data = _load()..remove(key);
  _save(data);
}
