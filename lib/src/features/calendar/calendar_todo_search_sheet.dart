// 待办搜索（`SYNO.Cal.Todo/search` **v1**）弹层。
//
// 事实来源（**真机 2026-09-22，普通用户**）：
//   * 参数：`cal_id` **或** `keyword`（两者都实测可调）——这里用 `keyword`；
//   * 版本：**v1**（包内 `webapi/SYNO.Cal.lib` 的 `SYNO.Cal.Todo` 方法表里
//     `search` 只在 `methods["1"]`）；
//   * 回包 root 是 **`evt_list_result`**（不是 `todolist`）+ `total`：
//     `{"data":{"evt_list_result":[],"total":0}}`。
//
// 降级/空态纪律：
//   * **空关键字**：不发请求，直接给"输入关键字"的提示（不是空结果）；
//   * **服务端回来 0 条**：给**明确空态**（"没有找到匹配的待办"）；
//   * **接口失败**：如实显示错误（`describeCalendarError`），**绝不显示成
//     "0 条"** —— "搜不到"和"搜索挂了"必须能分辨。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/calendar_api.dart';
import '../../data/dto/calendar_dto.dart';
import 'calendar_providers.dart';

/// 打开"搜索待办"弹层。返回用户点中的那条待办（取消 → null）。
///
/// 调用方拿到非空结果后走**既有的** `_openTodoEditor`（编辑/完成/删除都在那）。
Future<CalTodoDto?> showTodoSearchSheet(BuildContext context) =>
    showModalBottomSheet<CalTodoDto>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (_) => const _TodoSearchSheet(),
    );

class _TodoSearchSheet extends ConsumerStatefulWidget {
  const _TodoSearchSheet();

  @override
  ConsumerState<_TodoSearchSheet> createState() => _TodoSearchSheetState();
}

class _TodoSearchSheetState extends ConsumerState<_TodoSearchSheet> {
  final TextEditingController _input = TextEditingController();

  /// 已提交的关键字（空 = 还没搜过）
  String _query = '';

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final kw = _input.text.trim();
    if (kw == _query) {
      // 同一关键字再点一次：手动重新拉一次（失败后重试的入口）
      if (kw.isNotEmpty) ref.invalidate(calTodoSearchProvider(kw));
      setState(() {});
      return;
    }
    setState(() => _query = kw);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inset = MediaQuery.of(context).viewInsets.bottom;
    final async = _query.isEmpty
        ? null
        : ref.watch(calTodoSearchProvider(_query));

    return SafeArea(
      // 用 `ListView(shrinkWrap: true)` 而不是 Column：本仓库所有底部弹层都是
      // 这个形状（`ListView` 的交叉轴宽度是**紧约束**，`Column` + `stretch`
      // 在弹层里会拿到无界宽度 → `BoxConstraints forces an infinite width`）。
      child: ListView(
        key: const Key('cal-todo-search-sheet'),
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.lg + inset),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  dataText('calTodoSearchTitle', '搜索待办'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: context.t.photoClose,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('cal-todo-search-field'),
                  controller: _input,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: dataText('calTodoSearchHint', '输入关键字'),
                    prefixIcon: const Icon(Icons.search),
                  ),
                ),
              ),
              const SizedBox(width: Gap.sm),
              // ⚠️ 这里**不能**用 `FilledButton`：本 App 的主题给它
              // `minimumSize: Size.fromHeight(48)`（整行宽），放进 `Row`（主轴
              // 无界）会直接 `BoxConstraints forces an infinite width`。
              // `TextButton` 的 minimumSize 是 `Size(0, 40)`，在 Row 里安全。
              TextButton(
                key: const Key('cal-todo-search-go'),
                onPressed: _submit,
                child: Text(dataText('calTodoSearchAction', '搜索')),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          _results(async),
        ],
      ),
    );
  }

  Widget _results(AsyncValue<CalTodoSearchResultDto>? async) {
    if (async == null) {
      // 还没搜过 —— 说明怎么用，**不是**"没有结果"
      return _hint(
        key: const Key('cal-todo-search-idle'),
        icon: Icons.search,
        text: dataText('calTodoSearchPrompt', '输入关键字后点「搜索」。'),
      );
    }
    if (async.hasError) {
      return _hint(
        key: const Key('cal-todo-search-error'),
        icon: Icons.error_outline,
        text: describeCalendarError(async.error!),
      );
    }
    final data = async.value;
    if (data == null) {
      return _hint(
        key: const Key('cal-todo-search-loading'),
        icon: Icons.hourglass_empty,
        text: dataText('calLoading', '加载中…'),
      );
    }
    if (data.isEmpty) {
      // **明确空态**：服务端确实回了 0 条（不是"还没搜"、也不是"加载中"）
      return _hint(
        key: const Key('cal-todo-search-empty'),
        icon: Icons.search_off,
        text: dataText('calTodoSearchEmpty', '没有找到匹配的待办。'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < data.items.length; i++)
          DesignRowTile(
            key: Key('cal-todo-search-$i'),
            dense: true,
            leading: Icon(
              data.items[i].done
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              size: 18,
              color: data.items[i].done ? DesignPalette.of(context).dim : null,
            ),
            title: Text(
              data.items[i].summary,
              style: data.items[i].done
                  ? TextStyle(
                      decoration: TextDecoration.lineThrough,
                      color: DesignPalette.of(context).dim,
                    )
                  : null,
            ),
            subtitle: data.items[i].dueAt == null
                ? null
                : Text(
                    context.t.calDueDate(_fmtDate(data.items[i].dueAt!)),
                  ),
            onTap: () => Navigator.of(context).pop(data.items[i]),
          ),
      ],
    );
  }

  Widget _hint({
    required Key key,
    required IconData icon,
    required String text,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Gap.lg),
    child: Row(
      key: key,
      children: [
        Icon(icon, size: 18, color: DesignPalette.of(context).dim),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: DesignPalette.of(context).dim,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 与 `calendar_page.dart` 同口径的日期文案（`yyyy-MM-dd`）。
String _fmtDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}
