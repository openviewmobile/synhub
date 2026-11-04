// 「会抖的状态」上屏闸门（r668 / `DA294`）。
//
// ## 为什么要有它
//
// 用户报（macOS 手测，并明确说「安卓也有这个问题」）：
//
//   「chat 的页面 channel 下面的连接状态变化太频繁，会导致页面跳动」
//
// 根因不是动画难看，而是**把实时状态直接绑进布局**：实时通道在弱网/服务端重连时
// 会在一秒内 `ready ↔ degraded` 抖好几次，而那一行在列表头部 —— 文案长度一变
// （中英文都不同）就可能从 1 行折成 2 行，**整页跟着上下跳**。
//
// ## 三条规矩（本组件就是这三条的封装）
//
//   ① **状态要稳定 [settle] 才上屏**：期间继续变就重新计时；最后一帧一定会上屏
//      （不会"卡在旧状态"——`didUpdateWidget` 每次都重排定时器，`dispose` 取消）；
//   ② **同一状态内的文案/颜色变化即时跟随**（人数刷新这种不算抖动）；
//   ③ **定高单行**：无论文案多长、系统字号多大，渲染高度只由字号决定 ⇒
//      **布局不变量**，这才是用户说的"页面不跳"。
//
// ★ 为什么不直接用 `AnimatedSwitcher`：它只让"变化"好看，高度仍随文案长度/折行
//   改变 —— 而用户要的是布局不跳。所以这里的判据是**高度恒定**，不是动画。
//
// ★ 判据在 `test/chat_header_jump_r668_test.dart`：连续翻转 20 次（间隔 < 稳定窗口）
//   断言渲染高度**一像素都没变**、可见文案仍是旧值；停手 700ms 后文案才更新。
import 'dart:async';

import 'package:flutter/material.dart';

/// 见文件头。`status` 只用于**判等**（相位枚举、连接状态等），`label`/`color` 是上屏值。
class DebouncedStatusLine extends StatefulWidget {
  const DebouncedStatusLine({
    super.key,
    required this.status,
    required this.label,
    required this.color,
    this.fontSize = 11.5,
    this.dot = true,
    this.dotSize = 3.5,
    this.settle = const Duration(milliseconds: 700),
    this.textKey,
  });

  /// 判等用：变了就重新计时（通常是相位枚举）。
  final Object status;

  /// 上屏文案（人话）。
  final String label;

  /// 上屏颜色（状态色）。
  final Color color;

  /// 字号（决定定高；跟随 `textScaler`）。
  final double fontSize;

  /// 前面是否画状态点。
  final bool dot;

  final double dotSize;

  /// 稳定窗口。700ms 的取法：比人眼可察觉的跳动间隔长，又短于一次正常重连
  /// （实测 1–3s）—— 所以真断了也会在 1 秒内显示出来。
  final Duration settle;

  /// 给文案 `Text` 的 key（用例定位/取值）。
  final Key? textKey;

  @override
  State<DebouncedStatusLine> createState() => _DebouncedStatusLineState();
}

class _DebouncedStatusLineState extends State<DebouncedStatusLine> {
  // ★ 必须在 `initState` 里赋值，**不能用 `late` 惰性初始化**：
  //   `late Object _shownStatus = widget.status;` 的初始化表达式在**第一次读取**
  //   时才求值，而第一次读取发生在 `didUpdateWidget` —— 那时 `widget` 已经是
  //   **新**的那个，于是"新状态 == 旧状态"恒成立 ⇒ 抖动抑制**静默失效**
  //   （用例当场抓到：第一次变换就立刻上屏）。
  late Object _shownStatus;
  late String _label;
  late Color _color;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _shownStatus = widget.status;
    _label = widget.label;
    _color = widget.color;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DebouncedStatusLine old) {
    super.didUpdateWidget(old);
    // ★ 先无条件取消：**"同状态"这一支也必须取消**。第一版在这里提前 return
    //   忘了取消，于是上一次"异状态"排下的定时器会晚到一步、把中间某帧的
    //   文案/颜色写上去（实测：连续抖动 20 次后停在 `DOWN`，而界面状态是 `ready`）
    //   —— 那正是用户说的"闪"。取消是幂等的，无脑取消最安全。
    _timer?.cancel();
    _timer = null;
    if (widget.status == _shownStatus) {
      // 同状态内的微调：即时跟随，不进定时器
      _label = widget.label;
      _color = widget.color;
      return;
    }
    _timer = Timer(widget.settle, () {
      if (!mounted) return;
      setState(() {
        _shownStatus = widget.status;
        _label = widget.label;
        _color = widget.color;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    // 定高：只由字号 × 缩放决定 ⇒ 文案再长、折行规则怎么变都不影响高度
    final height = (widget.fontSize * scale * 1.45).ceilToDouble();
    return SizedBox(
      height: height,
      child: Row(
        children: [
          if (widget.dot) ...[
            _Dot(color: _color, size: widget.dotSize, label: _label),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              _label,
              key: widget.textKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: widget.fontSize, color: _color),
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态点（本文件私有的极简版：只画圆，语义标签跟随文案）。
class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.size, required this.label});

  final Color color;
  final double size;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
  );
}
