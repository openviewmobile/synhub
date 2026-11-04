// 「文件」搜索的**搜索根规整** —— 从 `file_pages.dart` 抽出，供
// 「文件」搜索页与「全局搜索」页（`features/search/global_search_page.dart`）共用。
//
// ★ r395 抽出的原因：全局搜索页此前**写死** `folder_path: '/'`（r391 真机截图：
//   `Search failed` + 裸 `Error code 600`），而「文件」搜索页在 r121/r135 就为
//   **同一个 `'/'`** 做过回落。两处不该各写各的判据。
/// 搜索根规整的默认回落值（`/home`）。
///
/// 依据（r395 逐字读数，见 `docs/evidence-r395/r395_da42_limit_matrix.txt`）：
/// 根 `/` 上的搜索任务 `has_not_index_share:true`，且 `Search/list` 对该任务会回
/// **600**（官方 FileStation 1.5.1-2410 文案 `search/no_search_cache`
/// 「暂时无法访问搜索结果。请再试一次。」）；`/home` 上同一关键字回的是**成功 + 命中**。
const kFileSearchDefaultRoot = '/home';

/// 把「文件」浏览上下文里的路径**规整**成 `SYNO.FileStation.Search:start`
/// 认得的搜索根。
///
/// ★ r135 修（D3 根因之一）：`FileBrowseStackNotifier` 的根是
/// `kFileRoot = '/'`，而搜索入口把**当前目录**原样传进来 ⇒ 在根目录点搜索
/// 会发 `folder_path='/'`，而真机对 `'/'` **回 `Error code 600`**
/// （r121 取证：不是"0 命中"，是**直接报错**）。空串同理不是合法搜索根。
/// ⇒ 这两种一律回落 [kFileSearchDefaultRoot]（`/home`）。
/// 具体的子目录（`/home/Video` …）**原样透传**，不做任何猜测。
String fileSearchRootFor(String folderPath) {
  final p = folderPath.trim();
  if (p.isEmpty || p == '/') return kFileSearchDefaultRoot;
  return p;
}
