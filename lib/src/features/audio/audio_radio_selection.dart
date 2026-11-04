// **r443** · 网络电台「多选批量删除」的**纯逻辑**（不碰 UI、不碰网络）。
//
// 为什么单独一个文件：这一段的正确性**只靠读代码看不出来**，必须能被宿主用例
// 直接钉住 —— 尤其"**多段删除要从高往低做**"这一条（服务端是**段替换**语义，
// 删掉低位段会让后面所有行号前移；真机读数见
// `tool/r443_radio_batch_delete_probe_test.dart` 的 B 段）。
//
// 事实来源（真 NAS 有界写探针，r443）：
//   * `{offset, limit:n, radios_json:'[]'}` **一次删一段连续的 n 行**；
//   * 段删完，**后面的行号前移**（留下的正是没被选的那条）；
//   * `limit` 越界 ⇒ **钳到末尾**，不报错；
//   * `limit:0` ⇒ 服务端**拒绝**（`101`），那条**不会**被删（不是静默清空）。
//
// 行号口径（复用 r401 加固过的结论）：`offset` 是**相对该 container** 的服务端
// 行号，列表页从 `offset 0` 起向后追加 ⇒ 已加载列表的下标 **就是**服务端下标。
// ⚠️ 这条前提在"只加载了前 k 页"时依然成立（下标 ≤ 已加载数），但如果将来
// 加入"跳页/排序"，下标与服务端行号就会脱钩 —— 那时本文件必须一起改。
library;

/// 把**服务端行号**（可乱序、可含重复）整理成**升序去重**的段：
/// 连续的归一段，不连续的另起一段。
///
/// 例：`[3, 1, 2, 7]` ⇒ `[[1, 2, 3], [7]]`。
List<List<int>> radioDeleteRuns(Iterable<int> indices) {
  final sorted = indices.where((i) => i >= 0).toSet().toList()..sort();
  final runs = <List<int>>[];
  for (final i in sorted) {
    if (runs.isEmpty || i != runs.last.last + 1) {
      runs.add(<int>[i]);
    } else {
      runs.last.add(i);
    }
  }
  return runs;
}

/// 真正**发请求的顺序**：段**从高往低**。
///
/// ★★ 每条段的 `[first, last]` 直接对应一次
/// `updateradios{offset: first, limit: last - first + 1, radios_json:'[]'}`。
/// 反过来的话，删完低位段之后，高位段的 `offset` 已经指向**别的行**了。
List<List<int>> radioDeleteOrder(Iterable<int> indices) =>
    radioDeleteRuns(indices).reversed.toList();

/// 一次批量删除要发的调用序列（`[offset, limit]` 对，按**发出顺序**）。
///
/// 用它当用例与真机两侧的**唯一形状来源**（不许各写一份）。
List<(int offset, int limit)> radioDeleteCalls(Iterable<int> indices) => [
  for (final run in radioDeleteOrder(indices))
    (run.first, run.last - run.first + 1),
];

/// 选中的行里有没有**容器行**（`type:"container"`）—— 容器行**不许**被删。
///
/// 判据只认行号是否落在 [containerIndices] 里（调用方按 `items` 现取）。
bool radioSelectionHitsContainer(
  Iterable<int> indices,
  Set<int> containerIndices,
) => indices.any(containerIndices.contains);
