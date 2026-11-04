// macOS 沙盒下的**文件保存"双轨"**（第 55 轮）。
//
// ## 为什么要有这一层
//
// Android 上"存到系统下载目录"走 `MediaStore`（`synhub/mediastore`）；macOS
// 沙盒里**没有**这个通道（能力层报 `unavailable:not-implemented-on-host`）。
// 桌面上的对应物有两条路，必须二选一并且**如实告诉用户文件在哪**：
//
// | 轨道 | 落点 | 沙盒依据 | 记住跨启动 |
// |---|---|---|---|
// | A `userSelected` | 用户在保存/选择面板里挑的目录 | `com.apple.security.files.user-selected.read-write`（**已配**，见 `macos/Runner/*.entitlements`） | 需要 `files.bookmarks.app-scope` + security-scoped bookmark（**本轮未实现**，见 `docs/platform-macos.md` §5 残留） |
// | B `container` | `<container>/Documents/downloads`（`AppPaths.downloadsDirectory`） | 容器内，**免授权** | 不需要 |
//
// 两条路都返回**明确的落点**：A 成功就报 A 的路径；用户取消选择、或面板
// 不可用时退到 B，并把 B 的**绝对路径**带给界面（不静默、不说"存好了"却
// 不告诉在哪）。
//
// ## 纯净性
//
// 目录解析与写盘都是纯 Dart（只依赖 `dart:io` / `path`），**不碰平台通道**，
// 所以宿主上可以直接跑真文件系统证据（见 `test/save_destination_test.dart`）。
// 面板本身由调用方注入（生产用 `file_picker` 的 `getDirectoryPath`），
// 这样用例不需要弹窗。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'app_platform.dart';

/// 这次保存走的是哪条轨。
enum SaveTrack {
  /// A：用户在系统面板里选的位置（沙盒 user-selected 授权）。
  userSelected,

  /// B：应用容器内的下载目录（免授权，路径要如实告诉用户）。
  container,
}

/// 一次"该存到哪"的结论（**不抛异常**）。
class SaveDestination {
  const SaveDestination({
    required this.track,
    required this.directory,
    required this.reason,
  });

  final SaveTrack track;

  /// 绝对目录路径；`''` = 两条路都拿不到（此时 [reason] 说明原因）。
  final String directory;

  /// 机器可读原因码（`user-selected` / `container` / `not-supported-on-host` …）。
  final String reason;

  bool get ok => directory.isNotEmpty;

  @override
  String toString() =>
      'SaveDestination(${track.name}, ${directory.isEmpty ? '—' : directory}, $reason)';
}

/// 裁决保存落点。
///
/// * [userSelectedDirectory] 非空 ⇒ 走 A（面板已经授权了那个路径）；
/// * 否则 ⇒ 走 B（容器内下载目录）；连 B 都拿不到才回 [ok] == false。
///
/// [dirs] 可注入 ⇒ 用例不碰 `path_provider` 的平台通道。
Future<SaveDestination> resolveSaveDestination({
  String? userSelectedDirectory,
  PathProviderDirs? dirs,
}) async {
  final picked = (userSelectedDirectory ?? '').trim();
  if (picked.isNotEmpty) {
    return SaveDestination(
      track: SaveTrack.userSelected,
      directory: picked,
      reason: 'user-selected',
    );
  }
  try {
    final downloads = await AppPaths.downloadsDirectory(dirs: dirs);
    return SaveDestination(
      track: SaveTrack.container,
      directory: downloads.path,
      reason: 'container',
    );
  } catch (_) {
    return const SaveDestination(
      track: SaveTrack.container,
      directory: '',
      reason: CapabilityReason.bridgeMissing,
    );
  }
}

/// 在 [directory] 里安全落盘：同名已存在则自动加 ` (1)` / ` (2)` …（**绝不覆盖**）。
///
/// 返回写好的**绝对路径**（调用方据此如实告知用户）。源文件不存在 / 目录不可写
/// ⇒ 抛 [FileSystemException]（调用方按"失败"处理，别假装成功）。
Future<String> saveFileToDirectory({
  required String sourcePath,
  required String fileName,
  required String directory,
}) async {
  final src = File(sourcePath);
  if (!await src.exists()) {
    throw FileSystemException('源文件不存在', sourcePath);
  }
  final dir = Directory(directory);
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final target = File(_uniquePath(dir.path, fileName));
  await src.copy(target.path);
  return target.path;
}

/// `<dir>/<name>`（同名已存在则 ` (n)`，保留扩展名）。
String _uniquePath(String dir, String name) {
  final safe = name.trim().isEmpty ? 'download' : name.trim();
  var candidate = p.join(dir, safe);
  if (!File(candidate).existsSync()) return candidate;
  final ext = p.extension(safe);
  final stem = ext.isEmpty ? safe : safe.substring(0, safe.length - ext.length);
  for (var i = 1; i < 10000; i++) {
    candidate = p.join(dir, '$stem ($i)$ext');
    if (!File(candidate).existsSync()) return candidate;
  }
  // 极端情况：加时间戳兜底（不覆盖用户已有文件是硬要求）
  return p.join(dir, '$stem-${DateTime.now().microsecondsSinceEpoch}$ext');
}

/// 双轨的**一条结论 + 一个落点**：先问面板（A），取消/不可用就退 B。
///
/// [pickDirectory] 由调用方注入（生产 = `file_picker` 的 `getDirectoryPath`；
/// 用例注入返回固定值/ null 的假实现）⇒ 本函数本身可离线测试。
Future<({SaveDestination destination, String? savedPath, bool cancelled})>
saveWithDualTrack({
  required String sourcePath,
  required String fileName,
  Future<String?> Function()? pickDirectory,
  PathProviderDirs? dirs,
}) async {
  String? picked;
  var cancelled = false;
  if (pickDirectory != null) {
    try {
      picked = await pickDirectory();
    } catch (_) {
      picked = null;
    }
    cancelled = (picked == null || picked.trim().isEmpty);
  }
  final dest = await resolveSaveDestination(
    userSelectedDirectory: picked,
    dirs: dirs,
  );
  if (!dest.ok) {
    return (destination: dest, savedPath: null, cancelled: cancelled);
  }
  final saved = await saveFileToDirectory(
    sourcePath: sourcePath,
    fileName: fileName,
    directory: dest.directory,
  );
  return (destination: dest, savedPath: saved, cancelled: cancelled);
}
