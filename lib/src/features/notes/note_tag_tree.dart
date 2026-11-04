// F4：**子标签（嵌套）**的纯逻辑实现。
//
// ★ 取证结论（本批核心发现）：NoteStation 的子标签**不是** `parent_tag_id` 关系，
//   而是**标题里的 `/` 分层约定**，服务端完全不知情（客户端自己建树）。
//
// 依据（官方前端明文 JS，NoteStation-x86_64-2.6.10-3938 `ui/notestation.js`）：
//   * `Tag/set` v1 **只收** `tag_id` + `title`
//     （`backend.setTag`：`params:Ext.copyTo({},t,"tag_id,title")`；
//      APK `callables/operations/SetTagOperation.java:29-33` 同）
//     ⇒ **没有** `parent_tag_id` 这种字段，`Tag/set` 造不出父子关系。
//   * `SYNO.SDS.NoteStation.Utils` 里的一整套约定（逐字）：
//     ```js
//     isSeparatorTag:function(t){for(var e=0;e<t.length;e++)if("/"!==t[e])return!1;return!0}
//     checkTagIsParent:function(t,e){return t!==e&&0===e.indexOf(t)&&("/"===e[t.length]||"/"===e[t.length-1])}
//     combineToFullTag:function(t,e,o){if(Ext.isEmpty(t))return e;void 0===o&&(o=isSeparatorTag(e));
//                       var i="/"===t[t.length-1];return o||i?t+e:t+"/"+e}
//     getTagChild:function(t,e){if(Ext.isEmpty(e))return t;var o=t.substr(e.length),
//                       i=isSeparatorTag(o),n="/"===e[e.length-1];return i||n?o:o.substr(1)}
//     ```
//     `parseTagStructure` 就是拿这套函数把扁平的 `Tag/list` 建成树。
//   * 子标签的**创建**只能"跟着笔记走"：官方 `openCreateTagDialog` 的 callback
//     把新标题 `addItem` 进笔记的 tag 集合，保存时经 `Note/set` 的 `tag:[标题]`
//     隐式建档（本仓库 `note_tag_page.dart` 顶部注释早已记录这一点）。
//
// 本文件只做**纯函数**移植，便于离线单测；UI 在 `note_tag_page.dart` 里用。
// 内部 id（`tag_id`）**绝不上屏**：树上的 key 一律用标题。
library;

/// 标签标题的层级分隔符（官方写死 `"/"`）。
const String kNoteTagSeparator = '/';

/// 全是分隔符的标题（官方 `isSeparatorTag`）
bool isNoteTagSeparator(String value) {
  if (value.isEmpty) return false;
  for (var i = 0; i < value.length; i++) {
    if (value[i] != kNoteTagSeparator) return false;
  }
  return true;
}

/// [child] 是不是 [parent] 的子标签（官方 `checkTagIsParent` 逐字移植）。
///
/// 例：`checkNoteTagIsParent('work', 'work/urgent')` → true；
/// `checkNoteTagIsParent('work', 'workshop')` → false（下一个字符不是 `/`）。
bool checkNoteTagIsParent(String parent, String child) {
  if (parent == child) return false;
  if (!child.startsWith(parent)) return false;
  final at = parent.length;
  return (at < child.length && child[at] == kNoteTagSeparator) ||
      (at - 1 >= 0 && parent[at - 1] == kNoteTagSeparator);
}

/// 拼出完整标签标题（官方 `combineToFullTag` 逐字移植）。
///
/// [childIsSeparator] 不传时按官方默认：由 [child] 自己是不是纯分隔符决定。
String combineNoteTag(String parent, String child, {bool? childIsSeparator}) {
  if (parent.isEmpty) return child;
  final isSep = childIsSeparator ?? isNoteTagSeparator(child);
  final parentEndsWithSep =
      parent.isNotEmpty && parent[parent.length - 1] == kNoteTagSeparator;
  return (isSep || parentEndsWithSep) ? '$parent$child' : '$parent/$child';
}

/// 从完整标题里剥掉父标题，得到"显示用"的子名（官方 `getTagChild` 逐字移植）。
String noteTagChildLabel(String full, String parent) {
  if (parent.isEmpty) return full;
  final rest = full.substring(parent.length.clamp(0, full.length));
  final isSep = isNoteTagSeparator(rest);
  final parentEndsWithSep =
      parent.isNotEmpty && parent[parent.length - 1] == kNoteTagSeparator;
  if (isSep || parentEndsWithSep) return rest;
  return rest.isEmpty ? rest : rest.substring(1);
}

/// 子标签是否被算作某个父标签的后代（官方 `show_subtag` 的判定：
/// 直接父、或任意层级的祖先——官方是拿标题逐个 `checkTagIsParent` 比）。
bool noteTagIsDescendant(String ancestor, String candidate) {
  if (checkNoteTagIsParent(ancestor, candidate)) return true;
  // 逐段回退：`a/b/c` 对 `a` 也成立
  var current = candidate;
  while (current.contains(kNoteTagSeparator)) {
    final idx = current.lastIndexOf(kNoteTagSeparator);
    current = current.substring(0, idx);
    if (current.isEmpty) break;
    if (checkNoteTagIsParent(ancestor, current)) return true;
    if (checkNoteTagIsParent(current, ancestor)) return false;
  }
  return false;
}

/// 标签树的一个节点。
class NoteTagNode {
  NoteTagNode({required this.title, required this.fullTitle, this.count = 0});

  /// 显示用（子标签已剥掉父前缀）
  final String title;

  /// 完整标题（就是服务端 `Tag/list` 里的 title，也是 `Note/set` 的 tag 值）
  final String fullTitle;

  /// 该标签直接挂了多少条笔记（来自 `Tag/list` 的 `count`）
  final int count;

  final List<NoteTagNode> children = [];

  /// 子树里的标签条数总和（父标签自己常常是 0，展示时更有用）
  int get totalCount =>
      count + children.fold<int>(0, (sum, c) => sum + c.totalCount);
}

/// 把扁平的标签标题建成树（官方 `parseTagStructure` 的语义等价实现）。
///
/// 扁平表里可能缺父标签（只有 `a/b` 没有 `a`）——官方会把 `a/b` 当 **根** 处理，
/// 这里保持一致（不凭标题臆造一个不存在的父标签对象）。
List<NoteTagNode> buildNoteTagTree(
  Iterable<({String title, int count})> tags,
) {
  final flat = tags.toList()
    ..sort((a, b) => a.title.length.compareTo(b.title.length));
  final roots = <NoteTagNode>[];
  // fullTitle → 已建好的节点
  final built = <String, NoteTagNode>{};
  for (final t in flat) {
    if (t.title.isEmpty) continue;
    // 找一个**已建好的**、最长前缀的父
    NoteTagNode? parent;
    var bestLen = -1;
    for (final candidate in built.values) {
      if (checkNoteTagIsParent(candidate.fullTitle, t.title) &&
          candidate.fullTitle.length > bestLen) {
        parent = candidate;
        bestLen = candidate.fullTitle.length;
      }
    }
    final node = NoteTagNode(
      title: parent == null
          ? t.title
          : noteTagChildLabel(t.title, parent.fullTitle),
      fullTitle: t.title,
      count: t.count,
    );
    built[t.title] = node;
    if (parent == null) {
      roots.add(node);
    } else {
      parent.children.add(node);
    }
  }
  void sortRec(List<NoteTagNode> list) {
    list.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    for (final n in list) {
      sortRec(n.children);
    }
  }

  sortRec(roots);
  return roots;
}

/// 拍平成一维（缩进展示用）：`depth` 是层数，`visible=false` 表示被
/// "隐藏子标签"开关折叠掉了（此时它的后代也一并折叠）。
List<({NoteTagNode node, int depth, bool visible})> flattenNoteTagTree(
  List<NoteTagNode> roots, {
  bool showSubTags = true,
}) {
  final out = <({NoteTagNode node, int depth, bool visible})>[];
  void walk(List<NoteTagNode> nodes, int depth, bool ancestorsVisible) {
    for (final n in nodes) {
      final visible = ancestorsVisible && (showSubTags || depth == 0);
      out.add((node: n, depth: depth, visible: visible));
      walk(n.children, depth + 1, visible);
    }
  }

  walk(roots, 0, true);
  return out;
}
