// macOS 的「安全作用域书签」（`synhub/fsbookmark`）—— 第 328 轮补，backlog §3.4。
//
// ## 为什么需要它（用户可见的缺口）
// macOS 的 App 沙箱默认**只能写自己容器里**的东西。用户在保存面板里选了容器外的
// 目录时，`com.apple.security.files.user-selected.read-write` 给的是**一次性**
// 扩展 —— 进程重启后那个目录就又写不进去了。于是"记住上次选的目录"在 macOS 上
// **没法用路径字符串实现**，必须用官方的**安全作用域书签**：
//
//   ① 用户选完目录 ⇒ `create(path)` 拿一段 base64 书签串 ⇒ 存进 App 自己的存储；
//   ② 下次直接 `startAccess(bookmark)` ⇒ 解回路径 + `startAccessingSecurityScopedResource()`
//      （**这一步才是沙箱扩展生效的地方**）⇒ 普通 `File.copy` 就能写；
//   ③ 写完 `stopAccess(bookmark)`（**成对**，否则扩展泄漏）。
//
// 它需要 entitlement `com.apple.security.files.bookmarks.app-scope`：
// **本轮才加进两份 entitlements** —— 在此之前故意没申请（"申请了不用是空权限"，
// 见 `docs/platform-macos.md` §3.6.5）。守卫 `test/fs_bookmark_test.dart` 会
// 逐字读那两份文件（不靠"我记得配了"）。
//
// ## 通道契约（**与 Swift 侧逐字对应，改一处必须改两处**）
//   * 通道 `synhub/fsbookmark`
//   * `isSupported` → `Bool`
//   * `create`      ← `{path}`     → `{bookmark, path}`；失败 → `{error: …}`
//   * `startAccess` ← `{bookmark}` → `{path, started, stale}`；失败 → `{error: …}`
//   * `stopAccess`  ← `{bookmark}` → `Bool`
//
// ## 失败降级（**不许崩、不许静默换地方**）
// 桥不在（Android/iOS/Linux/Windows/单测）、entitlement 没批、书签过期、
// 目录被删 ⇒ 一律 catch 成"拿不到"，**回落是"再弹一次面板"**；
// 面板取消才走容器轨（B 轨），且**把真实落点告诉用户**。
//
// ## 能力位
// `AppCapability.fsBookmark` **只在 macOS 那一行** `available`；
// 其余宿主拿到的是 `statusOf` 的默认 `unavailable:bridge-missing`
// —— 那是**如实**的：这条 Swift 桥只编进 macOS 的 target。
//
// ## ★ r328 实测的硬事实：**这条路径上不能用 Keychain**
// 本机 macOS 构建是 **ad-hoc 签名**（没有 team ID）⇒ `flutter_secure_storage`
// 的 `write`/`delete` 每次都抛
// `PlatformException(-34018, "A required entitlement is not present.")`、
// `read` 返回 null（原文见 `docs/evidence-r328/README.md` §4.5 的探针读数）。
// 书签串**不是秘密**（它的价值只是"只在本机本用户有效"）⇒
// "上次选的目录"落**容器内一个文件**，不依赖任何 entitlement、也不静默降级。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';

import 'app_platform.dart';

/// 一次书签解析的结果。
class FsBookmarkAccess {
  const FsBookmarkAccess({
    required this.ok,
    this.path = '',
    this.started = false,
    this.stale = false,
    this.reason = '',
  });

  final bool ok;

  /// 解析出来的绝对路径（`ok` 时非空）。
  final String path;

  /// `startAccessingSecurityScopedResource()` 是否真的开起来了。
  ///
  /// ★ 它可能是 `false` 而路径依然可用（同一个路径已经在本进程里被别的
  /// 书签开过 —— 系统不允许重复开口）。调用方**不要**拿它当"能不能写"的判据，
  /// 真正的判据是**写盘成功**（见 `HostFileSaveSaver` 的回读）。
  final bool started;

  /// 书签过期（系统建议重新生成）—— 过期的书签**仍然能解出路径**。
  final bool stale;

  final String reason;
}

/// 书签桥的抽象（测试注入假桥；生产走 [MethodChannelFsBookmarkBridge]）。
abstract interface class FsBookmarkBridge {
  Future<bool> isSupported();

  /// 给 [path] 生成一段书签串（base64）。失败返回 `null`。
  Future<String?> create(String path);

  /// 解书签 + 开沙箱扩展。**成功拿到扩展后必须配一次 [stopAccess]**。
  Future<FsBookmarkAccess> startAccess(String bookmark);

  /// 关沙箱扩展（与 [startAccess] 成对）。
  Future<void> stopAccess(String bookmark);
}

/// 生产实现：`synhub/fsbookmark`（Swift `FsBookmarkBridge.swift`）。
class MethodChannelFsBookmarkBridge implements FsBookmarkBridge {
  MethodChannelFsBookmarkBridge([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('synhub/fsbookmark');

  final MethodChannel _channel;

  /// 能力门（`test/method_channel_gate_guard_test.dart` 要求的那个"命名门"）。
  static bool get _allowed => capabilityGateAllows(AppCapability.fsBookmark);

  static void _logBlocked(String method) {
    // 诊断串（**不是**用户文案）：只在 debug 里打，方便排障时区分
    // "桥不在"与"门没放行"。
    assert(() {
      // ignore: avoid_print
      print('[fsbookmark] blocked method=$method（能力位不可用）');
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
  Future<String?> create(String path) async {
    if (!_allowed) {
      _logBlocked('create');
      return null;
    }
    try {
      final r = await _channel.invokeMethod<Object?>('create', {'path': path});
      final m = r is Map ? r : null;
      final bm = m?['bookmark'];
      return bm is String && bm.isNotEmpty ? bm : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<FsBookmarkAccess> startAccess(String bookmark) async {
    if (!_allowed) {
      _logBlocked('startAccess');
      return const FsBookmarkAccess(ok: false, reason: 'bridge-unavailable');
    }
    try {
      final r = await _channel.invokeMethod<Object?>('startAccess', {
        'bookmark': bookmark,
      });
      final m = r is Map ? r : null;
      if (m == null) {
        return const FsBookmarkAccess(ok: false, reason: 'bad-response');
      }
      final err = m['error'];
      if (err is String && err.isNotEmpty) {
        return FsBookmarkAccess(ok: false, reason: 'resolve-failed: $err');
      }
      final p = m['path'];
      if (p is! String || p.isEmpty) {
        return const FsBookmarkAccess(ok: false, reason: 'no-path');
      }
      return FsBookmarkAccess(
        ok: true,
        path: p,
        started: m['started'] == true,
        stale: m['stale'] == true,
      );
    } catch (e) {
      return FsBookmarkAccess(ok: false, reason: 'exception: $e');
    }
  }

  @override
  Future<void> stopAccess(String bookmark) async {
    if (!_allowed) return;
    try {
      await _channel.invokeMethod<bool>('stopAccess', {'bookmark': bookmark});
    } catch (_) {
      // 关不掉不影响正确性（进程退出也会释放），静默。
    }
  }
}

/// 注入点：测试覆盖成假桥。
final fsBookmarkBridgeProvider = Provider<FsBookmarkBridge>(
  (ref) => MethodChannelFsBookmarkBridge(),
);

/// "上次用户选的保存目录"（路径 + 书签串）—— **纯本地**，服务端无此概念。
class RecentSaveDirectory {
  const RecentSaveDirectory({required this.path, required this.bookmark});

  final String path;
  final String bookmark;

  @override
  String toString() => 'RecentSaveDirectory($path)';
}

/// 读写口（只有两个方法；JSON 编解码在上层，错误一律静默成"没存过"）。
abstract interface class RecentSaveDirectoryStore {
  Future<RecentSaveDirectory?> read();
  Future<void> write(RecentSaveDirectory value);
  Future<void> clear();
}

/// 生产实现：**容器内的一个文件**（`<documents>/synhub/recent_save_directory.txt`）。
///
/// 编码：`<base64 书签>\n<绝对路径>`（只按**第一个**换行切，路径里的换行不会
/// 把书签读错）。坏数据一律当"没存过"。
///
/// ★ 为什么不用 Keychain：见文件头的 r328 实测（ad-hoc 签名 ⇒ `-34018`）。
/// 为什么不做成"Keychain 失败就回落文件"：那会让**同一条语义有两种落点**，
/// 排障时说不清"用户上次选的目录到底存哪了"（AGENTS §2.0.26 同族）。
class FileRecentSaveDirectoryStore implements RecentSaveDirectoryStore {
  FileRecentSaveDirectoryStore({PathProviderDirs? dirs, AppHost? hostOverride})
    : _dirs = dirs,
      _hostOverride = hostOverride;

  final PathProviderDirs? _dirs;
  final AppHost? _hostOverride;

  /// 目录名与文件名：**改字符串 = 用户旧选择读不回来**（不许改）。
  static const String dirName = 'synhub';
  static const String fileName = 'recent_save_directory.txt';

  Future<File> _file({bool create = true}) async {
    final base = await AppPaths.documentsDirectory(
      dirs: _dirs,
      hostOverride: _hostOverride,
      create: create,
    );
    final dir = Directory(p.join(base.path, dirName));
    if (create && !await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, fileName));
  }

  @override
  Future<RecentSaveDirectory?> read() async {
    try {
      final f = await _file(create: false);
      if (!await f.exists()) return null;
      return decodeRecentSaveDirectory(await f.readAsString());
    } catch (_) {
      // 读不出来就当没存过（下次再弹面板），绝不让保存失败
      return null;
    }
  }

  @override
  Future<void> write(RecentSaveDirectory value) async {
    try {
      final f = await _file();
      await f.writeAsString(encodeRecentSaveDirectory(value), flush: true);
    } catch (_) {
      // 写不进去就当没记住（下次再弹面板），绝不让保存失败
    }
  }

  @override
  Future<void> clear() async {
    try {
      final f = await _file(create: false);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// 编码（纯函数，可离线测）。
String encodeRecentSaveDirectory(RecentSaveDirectory v) =>
    '${v.bookmark}\n${v.path}';

/// 解码（纯函数，可离线测）：坏数据一律 `null`（= 没存过）。
RecentSaveDirectory? decodeRecentSaveDirectory(String raw) {
  if (raw.isEmpty) return null;
  final i = raw.indexOf('\n');
  if (i <= 0 || i >= raw.length - 1) return null;
  final bookmark = raw.substring(0, i);
  final path = raw.substring(i + 1);
  if (bookmark.isEmpty || path.isEmpty) return null;
  return RecentSaveDirectory(path: path, bookmark: bookmark);
}

/// 注入点。
final recentSaveDirectoryStoreProvider = Provider<RecentSaveDirectoryStore>(
  (ref) => FileRecentSaveDirectoryStore(),
);
