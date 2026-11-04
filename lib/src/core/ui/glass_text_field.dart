// 科幻层组件 ⑤：玻璃输入框（GlassTextField）。
//
// 为什么单独抽出来：登录页与连接页最早各自复制了一份私有实现（"聚焦描边 + 辉光球
// 形面板"），一旦要调手感就得改两处。这里统一成一个组件：
//   * 静息：`hud.glass` 填充 + 细边；
//   * 聚焦：主色描边加粗 + `hud.glowShadow` 外辉光 + 主色淡填充（`AnimatedContainer`
//     做过渡，`减少动效`时立即完成）；
//   * 语义：`labelText`/`hintText` 原样透传给 `TextField`，无障碍树里仍是一个标准
//     可编辑节点（不要把 label 画成纯装饰 Text，否则屏幕阅读器读不到）。
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'glass_pane.dart';

class GlassTextField extends StatefulWidget {
  const GlassTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.enabled = true,
    this.labelText,
    this.hintText,
    this.helperText,
    this.prefixIcon,
    this.suffixIcon,
    this.obscureText = false,
    this.autocorrect = true,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.autofocus = false,
    this.maxLines = 1,
  });

  final TextEditingController controller;

  /// 外部想自己管焦点时传（例如页面里要 `FocusScope` 跳转）
  final FocusNode? focusNode;
  final bool enabled;
  final String? labelText;
  final String? hintText;
  final String? helperText;
  final Widget? prefixIcon;

  /// 行尾附加件（例如"显示密码"的眼睛）
  final Widget? suffixIcon;
  final bool obscureText;
  final bool autocorrect;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final int maxLines;

  @override
  State<GlassTextField> createState() => _GlassTextFieldState();
}

class _GlassTextFieldState extends State<GlassTextField> {
  FocusNode? _own;
  bool _focused = false;

  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocus);
  }

  void _onFocus() {
    if (_focused != _node.hasFocus && mounted) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hud = HudTokens.of(context);
    return AnimatedContainer(
      duration: Motion.resolve(Motion.fast),
      curve: Motion.out,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pane),
        border: Border.all(
          color: _focused
              ? scheme.primary.withValues(alpha: 0.85)
              : hud.edge.withValues(alpha: 0.55),
          width: _focused ? 1.4 : 0.8,
        ),
        boxShadow: _focused ? hud.glowShadow : null,
      ),
      child: GlassPane(
        radius: Radii.pane - 1,
        showEdge: false,
        fill: _focused ? scheme.primary.withValues(alpha: 0.10) : hud.glass,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: TextField(
          controller: widget.controller,
          focusNode: _node,
          enabled: widget.enabled,
          autocorrect: widget.autocorrect,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          obscureText: widget.obscureText,
          onSubmitted: widget.onSubmitted,
          onChanged: widget.onChanged,
          autofocus: widget.autofocus,
          maxLines: widget.obscureText ? 1 : widget.maxLines,
          style: Theme.of(context).textTheme.bodyLarge,
          decoration: InputDecoration(
            labelText: widget.labelText,
            hintText: widget.hintText,
            helperText: widget.helperText,
            prefixIcon: widget.prefixIcon,
            suffixIcon: widget.suffixIcon,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
          ),
        ),
      ),
    );
  }
}
