// 通用的「分段视图 + 左右滑动切换」容器。
//
// 起因：好几个页面都是"顶部分段控件选一段、下面显示一段内容"（相册四段、
// Drive 更多四段、文件来源 NAS⇄Drive…）。用户要求**手势也能切**，
// 于是把"分段控件 ⇄ PageView 双向同步"这件事收敛到一个地方，避免每个页面
// 各写一份、各踩一遍同样的坑。
//
// 用法：
// ```dart
// SectionPager(
//   index: section.index,
//   onIndex: (i) => ref.read(...).select(Values[i]),
//   itemCount: Values.length,
//   itemBuilder: (context, i) => _views[i],
// )
// ```
//
// 与 `TabBarView` 的区别：我们不引 Tabs 那套（视觉要贴 HUD 设计语言），
// 而且需要"外部 index 变化 → 翻页"这条同步。
//
// ⚠️ 两个踩过的坑（都写在代码里）：
//   1. `late int _current = widget.index` 是**延迟求值**的 —— 第一次读取发生在
//      章节/分段已经变了之后，判断会永远不成立（`file_book_view.dart` 里抓过）；
//      所以一律在 `initState` 里显式赋值。
//   2. 在 build 阶段（`didUpdateWidget`）调 `animateToPage` 会被这一帧的布局吃掉，
//      pager 原地不动；这里统一用 `jumpToPage`（手势滑动本身仍有 PageView 的动画）。
import 'package:flutter/material.dart';

class SectionPager extends StatefulWidget {
  const SectionPager({
    super.key,
    required this.index,
    required this.onIndex,
    required this.itemCount,
    required this.itemBuilder,
    this.pagerKey,
  });

  /// 外部当前段（分段控件/其他代码改的）
  final int index;

  /// 手指滑到新的一段时回调（调用方负责更新自己的 provider/状态）
  final ValueChanged<int> onIndex;

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// 给测试用（默认按 [SectionPager] 类型取）
  final Key? pagerKey;

  @override
  State<SectionPager> createState() => _SectionPagerState();
}

class _SectionPagerState extends State<SectionPager> {
  late final PageController _pager;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.index;
    _pager = PageController(initialPage: widget.index);
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SectionPager old) {
    super.didUpdateWidget(old);
    if (widget.index != _current) {
      _current = widget.index;
      final target = widget.index;
      // 延迟到这一帧之后：build 阶段直接翻页会被布局吃掉
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pager.hasClients) return;
        if (_pager.page?.round() == target) return;
        _pager.jumpToPage(target);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      key: widget.pagerKey,
      controller: _pager,
      itemCount: widget.itemCount,
      onPageChanged: (i) {
        if (i == _current) return;
        _current = i;
        widget.onIndex(i);
      },
      itemBuilder: widget.itemBuilder,
    );
  }
}
