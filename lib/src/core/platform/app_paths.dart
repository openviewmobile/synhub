// 应用级**路径层**（第 279 轮）—— "文件该放哪、能不能放"的**唯一**入口。
//
// ## 为什么要有这一层
//
// Android 上"应用数据"和"用户可见数据"是两套东西（`/data/data/<pkg>` vs
// `/storage/emulated/0`），而且分区存储之后还要分"应用专属外置目录"和
// "媒体目录"。这些概念在 macOS/Linux/Windows 上**要么不存在、要么换名字**：
//
// | Android | macOS（沙箱内） | Linux/Windows |
// |---|---|---|
// | `/data/data/<pkg>/files` | `~/Library/Containers/<bid>/Data/Library/Application Support/<bundle>` | `~/.local/share/<app>` / `%APPDATA%\<app>` |
// | `/data/data/<pkg>/app_flutter`（= `getApplicationDocumentsDirectory()`） | `<container>/Data/Documents` | `~/Documents`（XDG 未必） |
// | `/storage/emulated/0/Android/media/<pkg>` | **不存在** | **不存在** |
// | `/storage/emulated/0/Android/data/<pkg>/files`（= `getExternalStorageDirectory()`） | **不存在**（返回 null） | **不存在** |
//
// 好消息：**现有代码几乎全部走 `path_provider`**（第 279 轮普查：
// `getApplicationDocumentsDirectory` 17 处、`getApplicationSupportDirectory` 3 处、
// `getTemporaryDirectory` 12 处…），所以这些调用在 macOS 上**自动**落到沙箱容器里，
// 不需要改。真正需要"翻译"的只有下面三类：
//
//   1. `getExternalStorageDirectory()`（Android 专属，其它平台回 `null`）——
//      笔记"外置存储"与端侧模型"收件箱"；
//   2. `/storage/emulated/0` 字面量（`drive_local_files_page.dart`）——
//      "本地文件"页的根；
//   3. 端侧模型的**三层保管**语义（`Android/media` 收件箱）在桌面没有意义。
//
// ## 本轮的裁决（逐条，别凭印象改）
//
// * **保管库**（App 私有、抗"覆盖安装"）→ 所有平台都有，统一
//   `<support>/models_vault`。macOS 上就是
//   `~/Library/Containers/com.openviewai.synhub.macos/Data/Library/Application Support/…/models_vault`；
// * **收件箱**（`Android/media/<pkg>/models`，宿主机 push 用）→ **Android 独有**。
//   桌面上这台"宿主机"就是本机，不需要"先 push 再 import"这一跳
//   ⇒ 桌面上 [AppPaths.modelInboxDirectory] 返回 `null`，原因码
//   `not-supported-on-host`（**不是**报错，是"这个概念在这里不存在"）；
// * **"本地文件"根** → Android 给 `/storage/emulated/0`；桌面**只给沙箱容器内
//   可写的目录**（Documents / Downloads / 临时），**不假装**能读用户的
//   `~/Documents`（沙箱下读 `~/Documents` 要用户授权，那是 SAF 的 macOS 对应物，
//   本轮未实现 —— 见 `docs/platform-macos.md` backlog）。
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_platform.dart';

/// `path_provider` 的目录取用（可注入 ⇒ 用例不碰平台通道）。
typedef PathProviderDirs = ({
  Future<Directory> Function() support,
  Future<Directory> Function() documents,
  Future<Directory> Function() cache,
  Future<Directory> Function() temp,
  Future<Directory?> Function() external,
});

/// 生产实现（record 的字段都是**函数值**，测试可以整组替换）。
PathProviderDirs get realPathProviderDirs => (
  support: () => getApplicationSupportDirectory(),
  documents: () => getApplicationDocumentsDirectory(),
  cache: () => getApplicationCacheDirectory(),
  temp: () => getTemporaryDirectory(),
  // ⚠️ 桌面/web 上 `getExternalStorageDirectory()` 会抛 `MissingPlatformDirectoryException`
  // （不是回 null），所以这里包一层 —— "没有"是**预期路径**。
  external: () async {
    try {
      return await getExternalStorageDirectory();
    } catch (_) {
      return null;
    }
  },
);

/// 环境变量读取（可注入 ⇒ Linux 的 XDG 回落可以**离线单测**，不碰平台通道）。
typedef EnvironmentLookup = String? Function(String name);

/// 生产实现：真进程环境。
///
/// ★★ 第 336 轮：**web 上没有"进程环境"**，`Platform.environment` 在 web 上抛
///   `UnsupportedError`（不是"回空表"）⇒ 这里先短路成 `null`（等价于"这个变量没设"），
///   免得任何路径解析在浏览器里炸掉启动。
EnvironmentLookup get realEnvironmentLookup =>
    (name) => kIsWeb ? null : Platform.environment[name];

/// 一个"根目录 + 它为什么是/不是这样"的结论（三态复用 [CapabilityStatus] 的形状）。
class AppPathRoot {
  const AppPathRoot({
    required this.id,
    required this.path,
    required this.reason,
  });

  /// `downloads` / `models_vault` / `local_files` / …
  final String id;

  /// 绝对路径；空串 = 这个根在**本平台不存在**。
  final String path;

  /// 机器可读原因码（[CapabilityReason]）。
  final String reason;

  bool get exists => path.isNotEmpty;

  @override
  String toString() => 'AppPathRoot($id, ${path.isEmpty ? '—' : path}, $reason)';
}

/// 应用级路径解析。**所有**新代码取目录都走这里，不要再直接写字面量。
abstract final class AppPaths {
  /// Android 包名（原样保留；桌面不用它）。
  static const String androidPackageName = 'com.openviewai.synhub';

  /// Android 上"用户可见"的外置根。
  static const String androidExternalRoot = '/storage/emulated/0';

  /// 宿主（可注入，单测用 [debugForceAppHost] 覆盖）。
  static AppHost get host => currentAppHost;

  // ───────────────────────────────────────────────────────────────────────
  // ★★★ P0-2（Linux 站，第 109 轮）：文档目录**按 XDG 回落，降级而不是抛**
  //
  // 原始证据（`docs/platform-linux.md` §8.4 缺陷 2）：amd64 容器里真跑时
  // `getApplicationDocumentsDirectory()` 抛
  // `MissingPlatformDirectoryException(Unable to get application documents
  // directory)` **×5**（经 `drift_flutter` 的 `driftDatabase.databaseFile`）
  // ⇒ **drift 本地库在 Linux 上根本建不起来**（离线缓存/笔记/会话一整片底座）。
  //
  // 根因：`path_provider_linux` 的 `getApplicationDocumentsDirectory` 走
  // `xdg-user-dir DOCUMENTS`；容器/最小发行版没装 `xdg-user-dirs`、
  // 没有 `~/.config/user-dirs.dirs` ⇒ 拿不到目录 ⇒ 抛。
  //
  // 修法（本层唯一入口，别的平台语义**逐字节不变**）：
  //   * 先照旧问 `path_provider`（正常 Linux 桌面仍走 `~/Documents`，行为不变）；
  //   * **仅 Linux** 且失败时按 XDG 规范回落：
  //     `$XDG_DATA_HOME` → `<home>/.local/share` → `<home>`，再接 `/synhub`；
  //   * 非 Linux 平台**原样重抛**（macOS / Windows / iOS / Android 的行为
  //     一个字节都不许变 —— 见 `test/app_paths_xdg_test.dart` 的反向断言）。
  // ───────────────────────────────────────────────────────────────────────

  /// Linux 的 XDG "应用数据根"回落（**纯函数**：只读注入的环境，不碰平台通道）。
  ///
  /// 规范顺序：`$XDG_DATA_HOME`（必须是绝对路径才算数）→
  /// `<home>/.local/share` → `<home>`；三者都拿不到返回 `null`（调用方再决定抛不抛）。
  static String? linuxXdgDataBase(EnvironmentLookup env) {
    final xdg = env('XDG_DATA_HOME')?.trim();
    if (xdg != null && xdg.isNotEmpty && p.isAbsolute(xdg)) return xdg;
    final home = env('HOME')?.trim();
    if (home != null && home.isNotEmpty && p.isAbsolute(home)) {
      return p.join(home, '.local', 'share');
    }
    return null;
  }

  /// Windows 的"应用数据根"回落（**纯函数**：只读注入的环境，不碰平台通道）。
  ///
  /// 顺序：`%LOCALAPPDATA%`（本机、每用户）→ `%APPDATA%`（漫游）→
  /// `%USERPROFILE%\\AppData\\Local`；三者都拿不到返回 `null`（调用方再决定抛不抛）。
  /// 判据与 [linuxXdgDataBase] 一致：**必须是 Windows 绝对路径**才算数。
  ///
  /// ★ 为什么 Windows 也需要它（r348 真机证据，`docs/platform-windows.md` §17）：
  /// 在 Windows 上以 **SYSTEM / 无用户画像的会话**启动（服务、计划任务、
  /// 以及我们自己的 `PsExec64 -i 1 -s` 验收配方）时，
  /// `getApplicationDocumentsDirectory()` 抛
  /// `MissingPlatformDirectoryException(Unable to get application documents directory)`
  /// ⇒ **drift 本地库建不起来**（与 Linux P0-2 同一族）。此时 `%LOCALAPPDATA%`
  /// 仍然存在且可写（SYSTEM 落到
  /// `C:\\Windows\\system32\\config\\systemprofile\\AppData\\Local`），
  /// 所以**降级比抛**更符合"应用数据总得有地方放"的语义。
  static String? windowsDataBase(EnvironmentLookup env) {
    String? abs(String? v) {
      final s = v?.trim();
      if (s == null || s.isEmpty) return null;
      // ★ `p.windows.isAbsolute('\\foo')` / `('/posix/only')` 都是 **true**
      //   （根相对 = "当前盘"），但那种值落到磁盘上属于"盘符不确定" ⇒ 不算数。
      //   只要**完全限定**的路径：`C:\...` 或 `\\\\server\\share`。
      if (!p.windows.isAbsolute(s) || p.windows.isRootRelative(s)) return null;
      return s;
    }

    final local = abs(env('LOCALAPPDATA'));
    if (local != null) return local;
    final roaming = abs(env('APPDATA'));
    if (roaming != null) return roaming;
    final profile = abs(env('USERPROFILE'));
    if (profile != null) return p.windows.join(profile, 'AppData', 'Local');
    return null;
  }

  /// "文档/应用数据该放哪" —— 需要 `getApplicationDocumentsDirectory()` 的
  /// **新代码一律走这里**（drift 库是第一个落地客户）。
  ///
  /// * Linux：`path_provider` 失败时按 [linuxXdgDataBase] 回落，并
  ///   `create: true` 时把 `<base>/synhub` 真建出来（drift 只建文件不建目录）；
  /// * ★ Windows（r348 起）：同理按 [windowsDataBase] 回落 —— 真机证据见该函数注释；
  /// * 其余平台（macOS/iOS/Android/web/unknown）：与直接调 `path_provider`
  ///   **完全等价**（异常原样重抛）。
  static Future<Directory> documentsDirectory({
    PathProviderDirs? dirs,
    AppHost? hostOverride,
    EnvironmentLookup? env,
    bool create = true,
  }) async {
    final h = hostOverride ?? host;
    final d = dirs ?? realPathProviderDirs;

    Object? failure;
    StackTrace? stack;
    try {
      final dir = await d.documents();
      if (dir.path.isNotEmpty) return dir;
      failure = StateError('documents directory path is empty');
    } catch (e, s) {
      failure = e;
      stack = s;
    }

    if (h == AppHost.linux) {
      final base = linuxXdgDataBase(env ?? realEnvironmentLookup);
      if (base != null) {
        final out = Directory(p.join(base, 'synhub'));
        if (create && !await out.exists()) {
          await out.create(recursive: true);
        }
        return out;
      }
    }
    // ★ r348：Windows 与 Linux 同一族（拿不到 documents ⇒ drift 建不起来），
    // 但**回落根不同**：Windows 用 `%LOCALAPPDATA%`（`p.windows` 拼接，
    // 不许用宿主分隔符 —— 本仓的用例跑在 POSIX 宿主上）。
    if (h == AppHost.windows) {
      final base = windowsDataBase(env ?? realEnvironmentLookup);
      if (base != null) {
        final out = Directory(p.windows.join(base, 'synhub'));
        if (create && !await out.exists()) {
          await out.create(recursive: true);
        }
        return out;
      }
    }
    Error.throwWithStackTrace(failure, stack ?? StackTrace.current);
  }

  /// 下载落点（会话里的"下载到本地"）。
  ///
  /// 所有平台都落**应用自己**的 documents 目录（Android:
  /// `<dataDir>/app_flutter/downloads`；macOS: `<container>/Data/Documents/downloads`）
  /// —— 沙箱下这是唯一**无需授权**就可写的用户可见位置；
  /// 用户想导出到别处走 [documentPicker] 的"用户选择"通道。
  static Future<Directory> downloadsDirectory({
    PathProviderDirs? dirs,
    bool create = true,
  }) async {
    final d = dirs ?? realPathProviderDirs;
    final base = await d.documents();
    final out = Directory(p.join(base.path, 'downloads'));
    if (create && !await out.exists()) await out.create(recursive: true);
    return out;
  }

  /// 端侧模型**保管库**（App 私有；覆盖安装不动它）。
  ///
  /// ★ macOS 语义裁决：桌面上没有"手机内部分区 vs 外置卡"的区分，
  /// 保管库就是 Application Support 下的一个普通目录；**收件箱概念取消**
  /// （这台机器就是宿主机，见 [modelInboxDirectory]）。
  static Future<Directory> modelVaultDirectory({
    PathProviderDirs? dirs,
    bool create = true,
  }) async {
    final d = dirs ?? realPathProviderDirs;
    final base = await d.support();
    final out = Directory(p.join(base.path, 'models_vault'));
    if (create && !await out.exists()) await out.create(recursive: true);
    return out;
  }

  /// 端侧模型**收件箱**（`Android/media/<pkg>/models`）。
  ///
  /// **只有 Android 有这个概念**。桌面上宿主机就是本机 ⇒ 返回空路径 +
  /// `not-supported-on-host`（调用方据此隐藏"从收件箱导入"这类功能，
  /// 而不是报一个错）。
  static Future<AppPathRoot> modelInboxRoot({PathProviderDirs? dirs}) async {
    final d = dirs ?? realPathProviderDirs;
    if (host != AppHost.android) {
      return const AppPathRoot(
        id: 'model_inbox',
        path: '',
        reason: CapabilityReason.notSupportedOnHost,
      );
    }
    try {
      final ext = await d.external();
      if (ext == null) {
        return const AppPathRoot(
          id: 'model_inbox',
          path: '',
          reason: CapabilityReason.bridgeMissing,
        );
      }
      // ext = /storage/emulated/0/Android/data/<pkg>/files
      final marker = p.join('Android', 'data', androidPackageName);
      final idx = ext.path.indexOf(marker);
      if (idx < 0) {
        return const AppPathRoot(
          id: 'model_inbox',
          path: '',
          reason: CapabilityReason.notSupportedOnHost,
        );
      }
      final root = ext.path.substring(0, idx);
      return AppPathRoot(
        id: 'model_inbox',
        path: p.join(root, 'Android', 'media', androidPackageName, 'models'),
        reason: CapabilityReason.ok,
      );
    } catch (_) {
      return const AppPathRoot(
        id: 'model_inbox',
        path: '',
        reason: CapabilityReason.bridgeMissing,
      );
    }
  }

  /// "本地文件"页能列的根目录。
  ///
  /// * Android：`/storage/emulated/0`（外置共享存储根，与官方文件管理器同口径）；
  /// * 桌面：**只给沙箱容器内**的 Documents / Downloads / 临时目录
  ///   —— 沙箱下 `~/Documents` 需要用户授权，本轮**不做**（见文件头裁决）；
  ///   iOS：Documents（App 自己的）+ 临时目录（iTunes 文件共享可见的那层）。
  static Future<List<AppPathRoot>> localFileRoots({
    PathProviderDirs? dirs,
  }) async {
    final d = dirs ?? realPathProviderDirs;
    switch (host) {
      case AppHost.android:
        return const [
          AppPathRoot(
            id: 'local_external',
            path: androidExternalRoot,
            reason: CapabilityReason.ok,
          ),
        ];
      case AppHost.macos:
      case AppHost.linux:
      case AppHost.windows:
      case AppHost.ios:
        final out = <AppPathRoot>[];
        try {
          final docs = await d.documents();
          out.add(
            AppPathRoot(
              id: 'local_documents',
              path: docs.path,
              reason: CapabilityReason.ok,
            ),
          );
        } catch (_) {
          // 拿不到就不列（桌面沙箱理论上不会失败，但要能扛住）
        }
        try {
          final tmp = await d.temp();
          out.add(
            AppPathRoot(
              id: 'local_temp',
              path: tmp.path,
              reason: CapabilityReason.ok,
            ),
          );
        } catch (_) {}
        return out;
      case AppHost.web:
      case AppHost.unknown:
        return const [
          AppPathRoot(
            id: 'local_files',
            path: '',
            reason: CapabilityReason.notSupportedOnHost,
          ),
        ];
    }
  }

  /// 笔记附件/离线数据的根（`internal` / `external` 两档）。
  ///
  /// Android 的 `external` 用应用专属外置目录；桌面**没有外置这一档**
  /// ⇒ 返回 `internal` 的路径 + `fellBackReason = not-supported-on-host`
  /// （调用方据此把设置项置灰并写明原因，而不是静默当成外置成功）。
  static Future<({String path, String fallbackReason})> noteStorageRoot({
    required bool external,
    PathProviderDirs? dirs,
  }) async {
    final d = dirs ?? realPathProviderDirs;
    if (!external) {
      try {
        return (path: (await d.documents()).path, fallbackReason: '');
      } catch (_) {
        return (path: '', fallbackReason: CapabilityReason.bridgeMissing);
      }
    }
    if (host != AppHost.android) {
      final internal = await noteStorageRoot(external: false, dirs: dirs);
      return (
        path: internal.path,
        fallbackReason: CapabilityReason.notSupportedOnHost,
      );
    }
    try {
      final ext = await d.external();
      if (ext != null && ext.path.isNotEmpty) {
        return (path: ext.path, fallbackReason: '');
      }
    } catch (_) {}
    final internal = await noteStorageRoot(external: false, dirs: dirs);
    return (path: internal.path, fallbackReason: CapabilityReason.bridgeMissing);
  }
}
