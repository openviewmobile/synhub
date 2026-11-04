// 纯文本文件的应用内编辑页（D59）。
//
// 官方是捆绑的 Markor SDK（`ShowTextEditorFragment`），本仓**不引入该依赖**，
// 只做最小可用的纯文本编辑：多行 `TextField` + 保存。加载/保存都通过回调注入，
// 页面本身不认识 Drive 协议 —— 好处有两个：
//   * `features/drive/**` 不反向依赖 `features/files/**`，不产生环；
//   * 单测可以直接喂假加载/假保存，不需要真 NAS。
//
// 保存通道由调用方决定。★ r371（DA12/DA14）订正：两个调用方（编辑已有文件
// `_editText` / 新建草稿 `case 'text'`）现在**都**走 Drive 自己的
// `Files/create`（`path` + `type=file` + `file_content`(base64) +
// `conflict_action`）——见 `DriveApi.createTextFile` 的逐字取证。
// 曾经"借 FileStation 临时文件 + 上传"那条通道在真机 2/2 失败
// （`Save failed: DSM 401: Account disabled`，文件字节数不变），已弃用。
import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import 'drive_gaps_text.dart';
import '../../core/user_facing_error.dart';

class DriveTextEditorPage extends StatefulWidget {
  const DriveTextEditorPage({
    super.key,
    required this.title,
    required this.loadText,
    required this.saveText,
    this.onSaved,
    this.readOnly = false,
  });

  /// 标题（一般是文件名）
  final String title;

  /// 只读打开（无写权限）：隐藏保存动作、正文不可改，并在正文上方如实说明。
  ///
  /// ★ r379（DA16）：官方的 `.txt`/`.md` 点行分流（`OpenFileHelper.smali`
  /// `openFile$lambda$5`）只看**体积**（≤1 MiB 进编辑器、>1 MiB 进阅读器），
  /// **不看写权限** —— 只读共享给别人的文件，官方也照样拿 Markor 打开。
  /// 所以我们依然进编辑器，只把"保存"收起来，而不是把用户挡回阅读器。
  final bool readOnly;

  /// 取当前文本（已解码）
  final Future<String> Function() loadText;

  /// 保存文本；抛异常 = 失败，页面按错误提示
  final Future<void> Function(String text) saveText;

  /// 保存成功后的回调（例如刷新列表 / pop）
  final VoidCallback? onSaved;

  @override
  State<DriveTextEditorPage> createState() => _DriveTextEditorPageState();
}

class _DriveTextEditorPageState extends State<DriveTextEditorPage> {
  final TextEditingController _controller = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final text = await widget.loadText();
      if (!mounted) return;
      _controller.text = text;
      setState(() {
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = userFacingError(e);
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.saveText(_controller.text);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(driveGap(DriveGapTextKeys.textEditorSaved, '已保存')),
        ),
      );
      widget.onSaved?.call();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveGapFill(
              DriveGapTextKeys.textEditorSaveFailed,
              '保存失败：{error}',
              {'error': userFacingError(e)},
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hud = DesignPalette.of(context);
    return Scaffold(
      key: const Key('drive-text-editor-page'),
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(
          widget.title.isEmpty
              ? driveGap(DriveGapTextKeys.textEditorTitle, '编辑文本')
              : widget.title,
        ),
        leading: IconButton(
          tooltip: t.calBack,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          // 只读打开时不出现"保存" —— 留一个按不动的按钮比没有按钮更让人困惑。
          if (!widget.readOnly)
            IconButton(
              key: const Key('drive-text-save'),
              tooltip: driveGap(DriveGapTextKeys.textEditorSave, '保存'),
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              onPressed: _loading || _saving ? null : _save,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(Gap.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 40, color: hud.dim),
                    const SizedBox(height: Gap.md),
                    Text(
                      driveGapFill(
                        DriveGapTextKeys.textEditorLoadFailed,
                        '打不开这个文本文件：{error}',
                        {'error': _loadError!},
                      ),
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: hud.dim),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                if (widget.readOnly)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Gap.md,
                      Gap.sm,
                      Gap.md,
                      0,
                    ),
                    child: Row(
                      key: const Key('drive-text-readonly-note'),
                      children: [
                        Icon(Icons.lock_outline, size: 16, color: hud.dim),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Text(
                            driveGap(
                              DriveGapTextKeys.textEditorReadOnly,
                              '只读：你没有修改这个文件的权限',
                            ),
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: hud.dim),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: TextField(
                      key: const Key('drive-text-field'),
                      controller: _controller,
                      readOnly: widget.readOnly,
                      // 纯文本：不做 Markdown 预览（官方 Markor 的预览不在本批范围）
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      keyboardType: TextInputType.multiline,
                      style: const TextStyle(fontFamily: 'monospace'),
                      // ★ DA209（r627）：这一页的**编辑面**就是界面本身 ——
                      // 之前用 `InputBorder.none` + 空 hint，真机量到：边界 1.40:1、
                      // 填色与页面同色 1.00:1、没有提示、也没有光标 ⇒ 新建文本文件
                      // 打开后看上去就是一页空白。现在：静态边界用 `hud.dim`
                      // （对页面底 4.70:1 ≥ WCAG 1.4.11 的 3:1），聚焦用 `hud.primary`，
                      // 输入面填白，并给一句“开始输入…”。
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: hud.surface,
                        hintText: driveGap(
                          DriveGapTextKeys.textEditorHint,
                          '开始输入…',
                        ),
                        hintStyle: TextStyle(color: hud.dim),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Radii.pane),
                          borderSide: BorderSide(color: hud.dim, width: 1),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Radii.pane),
                          borderSide: BorderSide(color: hud.dim, width: 1),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Radii.pane),
                          borderSide: BorderSide(color: hud.primary, width: 1.4),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
