// 投票编辑器（发起 + 编辑共用）。
//
// 对位原版 `CreateVoteFragment` / `EditVoteFragment`（两者是同一个表单的两种模式）：
//   * 「问题」输入框（原版 `mTitleText` + `error_empty_message`）
//   * 选项列表：输入 + 添加 / 删除；**至少两个**；文本不能重复、不能为空
//   * 三个开关：允许多选 / 匿名投票 / 允许添加选项
//   * 截止时间（原版 `mWillExpireSwitch` + `mDueAfterSpinner` + 时间选择），
//     必须在未来（原版 `time_must_in_future`）
//
// **可编辑性**（原版 `EditVoteFragment.showPost` 的关键规则）：
//   `editable = 总票数 == 0`。一旦有人投过票，问题正文、选项、多选/匿名开关全部置灰，
//   只有「允许添加选项」和「截止时间」还能改 —— 服务端那条 `Vote/set` 也只接受
//   `options`（原版两个重载，见 `AccountManager.editVote`）。
import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../data/dto/vote_dto.dart';

/// 编辑器返回的草稿（选项带 id：既有的选项必须原样回传 id）
class VoteDraft {
  const VoteDraft({
    required this.message,
    required this.choices,
    required this.multiple,
    required this.anonymous,
    required this.addOption,
    required this.expireAt,
  });

  final String message;
  final List<VoteChoiceDraft> choices;
  final bool multiple;
  final bool anonymous;
  final bool addOption;
  final int expireAt;

  factory VoteDraft.fromVote(String message, VoteDto vote) => VoteDraft(
    message: message,
    choices: [
      for (final c in vote.choices) VoteChoiceDraft(id: c.id, text: c.text),
    ],
    multiple: vote.multiple,
    anonymous: vote.anonymous,
    addOption: vote.addOption,
    expireAt: vote.expireAt,
  );
}

/// 一个选项（`id` 为空 = 新建，保存时服务端自己生成）
class VoteChoiceDraft {
  VoteChoiceDraft({this.id = '', required this.text});

  final String id;
  String text;
}

/// 弹投票编辑器。返回 null = 取消。
///
/// [editable] 为 false 时（已有人投票）只允许改「允许添加选项 / 截止时间」。
Future<VoteDraft?> showVoteEditor(
  BuildContext context, {
  VoteDraft? initial,
  bool editable = true,
  String? title,
  String? submitLabel,
}) {
  final t = context.t;
  return showDialog<VoteDraft>(
    context: context,
    builder: (_) => _VoteEditorDialog(
      initial: initial,
      editable: editable,
      title: title ?? t.chatVoteCreateTitle,
      submitLabel: submitLabel ?? t.chatVoteCreateSubmit,
    ),
  );
}

class _VoteEditorDialog extends StatefulWidget {
  const _VoteEditorDialog({
    this.initial,
    required this.editable,
    required this.title,
    required this.submitLabel,
  });

  final VoteDraft? initial;
  final bool editable;
  final String title;
  final String submitLabel;

  @override
  State<_VoteEditorDialog> createState() => _VoteEditorDialogState();
}

class _VoteEditorDialogState extends State<_VoteEditorDialog> {
  final _message = TextEditingController();
  final _option = TextEditingController();
  final _choices = <VoteChoiceDraft>[];
  bool _multiple = false;
  bool _anonymous = false;
  bool _addOption = false;
  int _expireAt = 0;

  bool get _editable => widget.editable;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init != null) {
      _message.text = init.message;
      _choices.addAll([
        for (final c in init.choices) VoteChoiceDraft(id: c.id, text: c.text),
      ]);
      _multiple = init.multiple;
      _anonymous = init.anonymous;
      _addOption = init.addOption;
      _expireAt = init.expireAt;
    }
  }

  @override
  void dispose() {
    _message.dispose();
    _option.dispose();
    super.dispose();
  }

  void _addChoice() {
    final t = _option.text.trim();
    if (t.isEmpty || _choices.any((c) => c.text == t)) return;
    setState(() {
      _choices.add(VoteChoiceDraft(text: t));
      _option.clear();
    });
  }

  Future<void> _pickExpire() async {
    final current = _expireAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(_expireAt)
        : DateTime.now().add(const Duration(days: 1));
    final d = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (t == null) return;
    setState(
      () => _expireAt = DateTime(
        d.year,
        d.month,
        d.day,
        t.hour,
        t.minute,
      ).millisecondsSinceEpoch,
    );
  }

  /// 校验（原版 `EditVoteFragment.editVote` 的三条：问题非空、选项非空/不重复、
  /// 截止时间在未来）
  String? _validate() {
    final t = context.t;
    if (_editable) {
      if (_message.text.trim().isEmpty) return t.chatVoteErrQuestionEmpty;
      final seen = <String>{};
      for (final c in _choices) {
        final v = c.text.trim();
        if (v.isEmpty) return t.chatVoteErrChoiceEmpty;
        if (!seen.add(v)) return t.chatVoteErrChoiceDuplicate;
      }
      if (_choices.length < 2) return t.chatVoteErrTooFewChoices;
    }
    if (_expireAt != 0 && _expireAt <= DateTime.now().millisecondsSinceEpoch) {
      return t.chatVoteErrExpireFuture;
    }
    return null;
  }

  void _submit() {
    final problem = _validate();
    if (problem != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    Navigator.of(context).pop(
      VoteDraft(
        message: _message.text.trim(),
        choices: _choices,
        multiple: _multiple,
        anonymous: _anonymous,
        addOption: _addOption,
        expireAt: _expireAt,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _message,
              autofocus: _editable,
              enabled: _editable,
              decoration: InputDecoration(
                labelText: t.chatVoteQuestionLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            if (_editable) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _option,
                      onSubmitted: (_) => _addChoice(),
                      decoration: InputDecoration(
                        labelText: t.chatVoteChoiceLabel,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _addChoice,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            for (final c in _choices)
              _ChoiceEditRow(
                draft: c,
                editable: _editable,
                onChanged: (v) => c.text = v,
                onRemove: () => setState(() => _choices.remove(c)),
              ),
            DesignSwitchRow(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(t.chatVoteAllowMultiple),
              value: _multiple,
              onChanged: _editable
                  ? (v) => setState(() => _multiple = v)
                  : null,
            ),
            DesignSwitchRow(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(t.chatVoteAnonymousVote),
              value: _anonymous,
              onChanged: _editable
                  ? (v) => setState(() => _anonymous = v)
                  : null,
            ),
            DesignSwitchRow(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(t.chatVoteAllowAddOption),
              // 这条即使投过票也能改（服务端 options-only 那条路）
              value: _addOption,
              onChanged: (v) => setState(() => _addOption = v),
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _pickExpire,
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text(
                    _expireAt == 0
                        ? t.chatVoteSetExpire
                        : DateTime.fromMillisecondsSinceEpoch(
                            _expireAt,
                          ).toString().substring(0, 16),
                  ),
                ),
                if (_expireAt != 0)
                  IconButton(
                    tooltip: t.chatVoteClearExpire,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _expireAt = 0),
                  ),
              ],
            ),
            if (_expireAt != 0 &&
                _expireAt <= DateTime.now().millisecondsSinceEpoch)
              Text(
                t.chatVoteErrExpireFuture,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            if (!_editable)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  t.chatVoteLockedHint,
                  // ★ r511：令牌化（原来 `Colors.grey`，暗色下偏亮、亮色下偏淡）。
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: DesignPalette.of(context).dim,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.submitLabel)),
      ],
    );
  }
}

class _ChoiceEditRow extends StatefulWidget {
  const _ChoiceEditRow({
    required this.draft,
    required this.editable,
    required this.onChanged,
    required this.onRemove,
  });

  final VoteChoiceDraft draft;
  final bool editable;
  final ValueChanged<String> onChanged;
  final VoidCallback onRemove;

  @override
  State<_ChoiceEditRow> createState() => _ChoiceEditRowState();
}

class _ChoiceEditRowState extends State<_ChoiceEditRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.draft.text,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: TextField(
          controller: _controller,
          enabled: widget.editable,
          onChanged: widget.onChanged,
          decoration: InputDecoration(
            isDense: true,
            hintText: context.t.chatVoteChoiceHint,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      if (widget.editable)
        IconButton(
          icon: const Icon(Icons.close, size: 18),
          onPressed: widget.onRemove,
        ),
    ],
  );
}
