// ★ **③Drive 第 56 轮：D25 多选选择模型**（纯逻辑，可单测）
//
// ## 为什么先写纯模型
// 多选的 bug 几乎全在**状态转移**里，而不在 UI：全选后取消一个、
// 跨目录残留、文件名里的字符让 zip 名非法…… 这些在 Widget 里
// 很难稳定复现，写成纯函数就能一次钉死。
//
// 官方依据：多选本身是 UI 概念，没有对应 WebAPI。真正对接口负责的是
// 打包下载参数（见 `DriveApi.downloadArchiveUrl` 与附录 AR 的官方规格）。
// 本文件只负责"用户选了哪些 id"和"压缩包该叫什么名字"。
import 'dart:collection';

/// 当前目录的多选状态。
///
/// 不可变：每次操作返回新实例，便于 Riverpod/`setState` 判定变化，
/// 也避免"共享可变集合被外部改掉"这类难查的 bug。
class DriveSelection {
  const DriveSelection(this.ids);

  const DriveSelection.empty() : ids = const {};

  /// 已选中的 `file_id`（不是路径、不是 `id:` 前缀形态 —— 见下）。
  ///
  /// ⚠️ 存 **裸 `file_id`**，不存 `id:<id>`：因为
  /// `downloadArchiveUrl` 内部会做 `_pathById` 转换，
  /// 存前缀形态会变成 `id:id:xxx` 的风险面（虽然那个函数幂等，
  /// 但"约定存裸 id"能少一层心智负担）。
  final Set<String> ids;

  bool get isEmpty => ids.isEmpty;
  bool get isNotEmpty => ids.isNotEmpty;
  int get count => ids.length;

  bool contains(String fileId) => ids.contains(fileId);

  /// 全选/取消全选（对**当前可见**的 id 集合操作）。
  ///
  /// [visibleIds] 是当前目录列出的 id。语义：
  /// * 若可见项**全部已选** ⇒ 取消它们（不影响可见集合之外的已选，虽然
  ///   正常情况下不该有 —— 换目录时会 [clear]，见下）；
  /// * 否则 ⇒ 把它们**全部选中**（即"补全"，而不是切换）。
  ///
  /// ★ 用"补全"而不是"逐个取反"：后者在"选了 3 个中的 1 个再点全选"时
  /// 会把那 1 个**取消掉**并选中另外 2 个 —— 用户预期是"全选"。
  DriveSelection toggleAll(Iterable<String> visibleIds) {
    final vis = visibleIds.toSet();
    if (vis.isEmpty) return this;
    final allSelected = vis.every(ids.contains);
    if (allSelected) {
      return DriveSelection({...ids}..removeAll(vis));
    }
    return DriveSelection({...ids, ...vis});
  }

  DriveSelection toggle(String fileId) {
    final next = {...ids};
    if (!next.remove(fileId)) next.add(fileId);
    return DriveSelection(next);
  }

  DriveSelection add(String fileId) => DriveSelection({...ids, fileId});

  DriveSelection remove(String fileId) =>
      DriveSelection({...ids}..remove(fileId));

  /// 换目录 / 退出选择模式时调用。
  DriveSelection clear() => const DriveSelection.empty();

  /// 把已选顺序稳定化后的列表（用于断言与请求）。按字典序，保证可复现。
  List<String> get sortedIds => SplayTreeSet<String>.of(ids).toList();

  @override
  bool operator ==(Object other) =>
      other is DriveSelection &&
      other.ids.length == ids.length &&
      other.ids.containsAll(ids);

  @override
  int get hashCode => Object.hashAllUnordered(ids);

  @override
  String toString() => 'DriveSelection(${sortedIds.join(',')})';
}

/// 由已选条目推出压缩包名（`archive_name`）。
///
/// 官方把命名交给调用方（`setAsDownload(..., archiveName, ...)`，
/// 非空才发 `archive_name`）。这里给出一个**确定性**规则：
///
/// * 选中 **1 个** ⇒ 用它的文件名（官方对单文件下载也是这个观感）；
/// * 选中 **多个** ⇒ 用**父目录名**（调用方传入 `folderName`）
///   + `.zip`；父目录名取不到就退化成 `SynologyDrive.zip`；
/// * **一定要清洗**：`/`、`\`、`:`、`*`、`?`、`"`、`<`、`>`、`|`
///   在多数文件系统/浏览器下载里非法或会被改写，
///   而 `archive_name` 会出现在 `Content-Disposition` 里
///   ⇒ 不清洗会得到一个**存不下来的文件名**。
///
/// ⚠️ 这是我方**策略**，不是官方明文规则；故写成独立纯函数便于调整。
String driveArchiveName({
  required List<String> selectedNames,
  String? folderName,
  String extension = 'zip',
}) {
  if (selectedNames.isEmpty) return '';
  if (selectedNames.length == 1) {
    return _sanitizeArchiveName(selectedNames.first);
  }
  final base = _sanitizeArchiveName(
    (folderName == null || folderName.trim().isEmpty)
        ? 'SynologyDrive'
        : folderName,
  );
  return '$base.$extension';
}

/// 去掉在文件名里非法的字符，把空白折叠成单个下划线。
///
/// ★ 顺序很重要（我第一版写反了，被 `drive_selection_test.dart` 抓到）：
/// 必须**先 `trim()` 再替换空白**。反过来写的话前导/尾随空白已经变成 `_`，
/// `trim()` 再也去不掉 ⇒ `"  我的 文档  "` 会得到 `"_我的_文档_"`。
///
/// 另外**连续的下划线要折叠**、**首尾下划线要剥掉**：
/// `"///"` 逐字符替换会得到 `"___"`，那是个没意义的名字；
/// 剥成空后由调用方退化到 `SynologyDrive`，对用户更有用。
String _sanitizeArchiveName(String raw) {
  final cleaned = raw
      .trim()
      .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  // 全是非法字符 / 全是空白 ⇒ 不能给空名字
  if (cleaned.isEmpty) return 'SynologyDrive';
  return cleaned;
}
