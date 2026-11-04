// 自适应网格列数（r668 / DA292 的同一族修法）。
//
// 为什么要有这个文件：本仓好几处网格把 `crossAxisCount` **写死 2 列** ——
// 手机上正好，到了 macOS/Linux 的 1000+dp 窗口里，每格就有 450–780dp 宽、
// 一大半是空白（用户对「工作台卡片」的原话，同样适用于相册的相册/人物/概念
// 三个网格）。**列数必须跟窗口宽度走**，而且不能各页各写一套公式。

/// 相册类（封面 + 两行标题）网格的列数。
///
/// 单格目标宽度 200dp（`PhotoAlbumTile` 的封面在 180–220 之间最好看），
/// 上下限 2–6 列：低于 2 列手机上手感就不对，高于 6 列封面会小于 150dp。
int albumColumnsFor(double maxWidth) {
  final usable = maxWidth.isFinite ? maxWidth : 400.0;
  return (usable / 200).floor().clamp(2, 6);
}
