// 146（M26）分卷压缩包的**纯客户端识别**。
//
// 为什么需要它：官方 APK 对分卷包**没有独立 UI**——`SYNO.FileStation.Extract`
// 的 `start` 由服务端自己处理分卷（`FileStation.apis.txt`：
// `SYNO.FileStation.Extract v1-2: list start status stop`，普通用户可用）。
// 所以我们缺的不是 API，而是"用户拿了第 2 卷去解压、然后一脸问号"时
// **一句能救命的提示**。本文件只做识别 + 文案，**不碰任何服务端调用**。
//
// ## 真机取证（本会话，只读，2026-09-22，普通用户 `demo_user`）
//
// ```text
// Extract/list v2 {file_path:/home/…/Agent入门课程配套代码.rar} → {"items":[…]} success
// Extract/list v1 {同}                                        → {"items":[…]} success
// Extract/list v2 {file_path:/home/nope.001}                  → 408（档案/路径不存在）
// Extract/list v2 （不带 file_path）                          → 400
// Extract/status v2 （不带 taskid）                           → 101
// Extract/status v2 {taskid:"x"}                              → 599
// ```
// ⇒ API 通、单卷可列；**本机没有多卷包**（`/home`、`/docker` 两棵子树全量遍历
// 只找到 3 个单卷 `.rar`），而"造一个多卷包"需要写操作（本批纪律禁止），
// 所以"服务端对多卷的确切行为"**未取证**——本文件只做**保守识别 + 提示**，
// 不声称已对齐服务端行为（见交付报告的 146 行）。
library;

/// 分卷包的四种命名法（都是业界通行、可静态识别的）：
///
///   * [rarPart] —— `name.part1.rar` / `name.part01.rar`（WinRAR 新式）；
///   * [rarOld] —— `name.r00` / `name.r01`（WinRAR 老式）；
///   * [numeric] —— `name.001` / `name.002`（7-Zip / HJSplit / `x.tar.gz.001`）；
///   * [zip] —— `name.z01` / `name.z02`（PKZIP 分卷）。
enum ArchiveVolumeKind { rarPart, rarOld, numeric, zip }

/// 识别结果。
class ArchiveVolume {
  const ArchiveVolume({
    required this.kind,
    required this.index,
    required this.firstVolumeName,
  });

  final ArchiveVolumeKind kind;

  /// 卷号（**1 起**：`.part1.rar` / `.001` / `.r00` 都算第 1 卷）
  final int index;

  /// **应该拿去解压的那一卷的文件名**（即第 1 卷）
  final String firstVolumeName;

  /// 这是不是第 1 卷（是 → 直接解压就行；不是 → 要提示用户改选）
  bool get isFirst => index == 1;
}

final RegExp _rarPart = RegExp(r'^(.*)\.part(\d+)\.rar$', caseSensitive: false);
final RegExp _rarOld = RegExp(r'^(.*)\.r(\d{2,3})$', caseSensitive: false);
final RegExp _numeric = RegExp(r'^(.*)\.(\d{3,4})$');
final RegExp _zip = RegExp(r'^(.*)\.z(\d{2,3})$', caseSensitive: false);

/// 识别一个文件名是不是分卷包；不是就回 `null`（普通文件走原逻辑）。
ArchiveVolume? detectArchiveVolume(String fileName) {
  if (fileName.isEmpty || fileName.contains('/')) return null;

  final part = _rarPart.firstMatch(fileName);
  if (part != null) {
    final digits = part.group(2)!;
    final idx = int.tryParse(digits) ?? 0;
    if (idx < 0) return null;
    // 第 1 卷保留原来的补零宽度（part01 → part01，而不是 part1）
    final first = '${part.group(1)}.part'
        '${1.toString().padLeft(digits.length, '0')}.rar';
    return ArchiveVolume(
      kind: ArchiveVolumeKind.rarPart,
      index: idx == 0 ? 1 : idx,
      firstVolumeName: first,
    );
  }

  final old = _rarOld.firstMatch(fileName);
  if (old != null) {
    final digits = old.group(2)!;
    final idx = int.tryParse(digits) ?? 0;
    // 老式 RAR：`.rar` 是第 1 卷，`.r00` 是第 2 卷
    if (idx == 0) {
      return ArchiveVolume(
        kind: ArchiveVolumeKind.rarOld,
        index: 2,
        firstVolumeName: '${old.group(1)}.rar',
      );
    }
    return ArchiveVolume(
      kind: ArchiveVolumeKind.rarOld,
      index: idx + 1,
      firstVolumeName: '${old.group(1)}.rar',
    );
  }

  final num = _numeric.firstMatch(fileName);
  if (num != null) {
    final digits = num.group(2)!;
    final idx = int.tryParse(digits) ?? 0;
    if (idx <= 0) return null;
    return ArchiveVolume(
      kind: ArchiveVolumeKind.numeric,
      index: idx,
      firstVolumeName:
          '${num.group(1)}.${1.toString().padLeft(digits.length, '0')}',
    );
  }

  final z = _zip.firstMatch(fileName);
  if (z != null) {
    final digits = z.group(2)!;
    final idx = int.tryParse(digits) ?? 0;
    if (idx <= 0) return null;
    return ArchiveVolume(
      kind: ArchiveVolumeKind.zip,
      index: idx,
      firstVolumeName:
          '${z.group(1)}.z${1.toString().padLeft(digits.length, '0')}',
    );
  }

  return null;
}

/// 该文件名看起来是分卷包的**后续卷**（第 2 卷起）。UI 用它决定"要不要弹提示"。
bool needsVolumeHint(String fileName) {
  final v = detectArchiveVolume(fileName);
  return v != null && !v.isFirst;
}

/// 该文件名看起来是分卷包的**第 1 卷**（服务端会自己去读其余卷）。
bool isFirstVolume(String fileName) {
  final v = detectArchiveVolume(fileName);
  return v != null && v.isFirst;
}
