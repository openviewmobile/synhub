// 批量打标签的底部弹层（相册多选 → 标签）。
//
// 接口口径（官方 Web 前端 saga，SPK `ui/react_bundle.js`）：
//   * 共同标签：`Browse.Item/get_tag {id:[…]}` → `{intersection:[tagId…]}`
//   * 全部标签：`Browse.GeneralTag/list`
//   * 联想：`Browse.GeneralTag/suggest {keyword, limit}`
//   * 新建：`Browse.GeneralTag/create {name}` → 官方前端写 `{tag:[{id,name}]}`，
//     但现场 NAS 实测回的是**单个对象** `{"tag":{"id":1,"name":"…"}}`，两种都认
//   * 现场另一处差异：`GeneralTag/list` 在这台 NAS 上对新标签一直回空 `{list:[]}`，
//     真正能搜到标签的是 `suggest`，所以输入框**边打边联想**（防抖 250ms）
//   * 加/去：`Browse.Item/add_tag|remove_tag {id:[…], tag:[…]}`（50 一批，含 `error_list`）
//
// `GeneralTag` **没有**改名/删除，所以这里不给这两个入口。
import '../../design/kit/design_kit.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/viewport_bound.dart';
import '../../data/dto/foto_dto.dart';
import 'photo_providers.dart';
import 'photo_seen_tags.dart';
import '../../core/user_facing_error.dart';

/// 打开标签弹层；返回是否真的提交了修改。
Future<bool> showPhotoTagSheet(
  BuildContext context,
  WidgetRef ref, {
  required List<String> itemIds,
}) async {
  if (itemIds.isEmpty) return false;
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => PhotoTagSheet(itemIds: itemIds),
  );
  return done == true;
}

/// 标签弹层本体（独立出来方便离线 widget 测试直接挂）。
class PhotoTagSheet extends ConsumerStatefulWidget {
  const PhotoTagSheet({super.key, required this.itemIds});

  final List<String> itemIds;

  @override
  ConsumerState<PhotoTagSheet> createState() => _PhotoTagSheetState();
}

class _PhotoTagSheetState extends ConsumerState<PhotoTagSheet> {
  final TextEditingController _search = TextEditingController();

  /// 初始共同标签（check 状态 = 在不在这个集合里）
  Set<String> _initial = {};
  Set<String> _checked = {};
  List<FotoTagDto> _suggestions = const [];
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  /// 联想防抖：`GeneralTag/list` 在现场可能回空，`suggest` 才是可靠的来源
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final intersection = await ref
          .read(photoTagActionsProvider)
          .intersection(widget.itemIds);
      if (!mounted) return;
      setState(() {
        _initial = intersection.toSet();
        _checked = {...intersection};
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = userFacingError(err);
      });
    }
  }

  Future<void> _suggest(String keyword) async {
    if (keyword.trim().isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    try {
      final list = await ref
          .read(photoTagActionsProvider)
          .suggest(keyword.trim());
      // 本机**见过**就记住（r412 DA70）：这台 NAS 的 `GeneralTag/list` 恒空，
      // 标签浏览页只能靠这份本地记忆补台 —— 不记住就等于"在弹层里搜得到、
      // 回标签页又没了"。
      if (list.isNotEmpty) {
        // **不 await**：记忆是副作用，不许拦着联想结果上屏
        //（`remember` 里 `state = …` 是同步的，落盘在后面的 await 里）。
        unawaited(
          ref
              .read(photoSeenTagsProvider.notifier)
              .remember(ref.read(fotoSpaceProvider).name, list),
        );
      }
      if (!mounted) return;
      setState(() => _suggestions = list);
    } catch (_) {
      // 联想失败不致命：用户还能从全部标签里勾，或直接新建
    }
  }

  Future<void> _create() async {
    final name = _search.text.trim();
    if (name.isEmpty) return;
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final tag = await ref.read(photoTagActionsProvider).create(name);
      if (!mounted) return;
      if (tag == null) {
        // 服务端没回可解析的标签：说出来，别让按钮看起来"点了没反应"
        messenger.showSnackBar(
          SnackBar(content: Text(t.ptTagCreateFailed(name))),
        );
        return;
      }
      // 新建的标签同样记进本地：服务端 `list` 不回它（现场实测），
      // 不记的话"刚建的标签"在标签页里看不到。同样**不 await**。
      unawaited(
        ref
            .read(photoSeenTagsProvider.notifier)
            .remember(ref.read(fotoSpaceProvider).name, [tag]),
      );
      if (!mounted) return;
      setState(() {
        _checked = {..._checked, tag.id};
        _suggestions = const [];
        _search.clear();
      });
    } catch (err) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(userFacingError(err))));
    }
  }

  Future<void> _apply() async {
    final add = _checked.where((id) => !_initial.contains(id)).toList();
    final remove = _initial.where((id) => !_checked.contains(id)).toList();
    if (add.isEmpty && remove.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() => _submitting = true);
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final failed = await ref
          .read(photoTagActionsProvider)
          .apply(itemIds: widget.itemIds, addTagIds: add, removeTagIds: remove);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            failed.isEmpty
                ? (add.isNotEmpty && remove.isEmpty
                      ? t.ptTagApplied(widget.itemIds.length)
                      : t.ptTagUpdated(widget.itemIds.length))
                : t.ptTagFailed(failed.length),
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (err) {
      if (!mounted) return;
      setState(() => _submitting = false);
      messenger.showSnackBar(
        SnackBar(content: Text(t.ptTagApplyFailed(userFacingError(err)))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    // 「全部标签」也用同一份补台口径（r412 DA70）：服务端 `list` 恒空时，
    // 本机见过的标签要能出现在这里 —— 否则**刚新建的标签**在弹层里也没行，
    // 只有计数动了（用户看到的是"已选 1 个标签"却找不到那一条）。
    final all = photoTagView(
      server: ref.watch(photoTagsProvider).value ?? const <FotoTagDto>[],
      seen: ref.watch(photoSeenTagsProvider),
      space: ref.watch(fotoSpaceProvider).name,
    ).tags;
    // 联想优先展示；没有联想时列全部标签
    final shown = _suggestions.isNotEmpty ? _suggestions : all;
    final keyword = _search.text.trim();
    final canCreate =
        keyword.isNotEmpty && !shown.any((e) => e.name == keyword);

    // 布局口径跟 `showAppSheet` 一致：外层 useSafeArea 已处理安全区，
    // 这里只钉高度上限 + 键盘 inset。
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          // P2-8：0.86 是经验系数，加安全上下界（见 viewport_bound.dart）
          maxHeight: boundedViewportHeight(
            MediaQuery.sizeOf(context).height,
            0.86,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesignRowTile(
              title: Text(
                t.ptTagSheetTitle(widget.itemIds.length),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              trailing: IconButton(
                key: const Key('photo-tag-close'),
                tooltip: t.photoClose,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: TextField(
                key: const Key('photo-tag-search'),
                controller: _search,
                autofocus: false,
                decoration: InputDecoration(
                  hintText: t.ptTagSearchHint,
                  prefixIcon: const Icon(Icons.search, size: 18),
                ),
                onChanged: (v) {
                  setState(() {});
                  _debounce?.cancel();
                  _debounce = Timer(
                    const Duration(milliseconds: 250),
                    () => _suggest(v),
                  );
                },
                onSubmitted: _suggest,
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(Gap.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Text(
                    t.ptTagLoadFailed,
                    style: TextStyle(color: hud.dim),
                  ),
                ),
              if (canCreate)
                DesignRowTile(
                  key: const Key('photo-tag-create'),
                  leading: const Icon(Icons.add),
                  title: Text(t.ptTagCreate(keyword)),
                  onTap: _create,
                ),
              if (shown.isEmpty && !canCreate)
                Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Text(t.ptTagNone, style: TextStyle(color: hud.dim)),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final tag in shown)
                          DesignCheckRow(
                            key: Key('photo-tag-${tag.id}'),
                            dense: true,
                            value: _checked.contains(tag.id),
                            title: Text(tag.name),
                            subtitle: tag.count > 0
                                ? Text(t.photoItemCount(tag.count))
                                : null,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _checked.add(tag.id);
                              } else {
                                _checked.remove(tag.id);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.ptSelectedTags(_checked.length),
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: hud.dim),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(t.actionCancel),
                    ),
                    const SizedBox(width: Gap.sm),
                    // ⚠️ 主题里 FilledButton 的 minimumSize 是 `Size.fromHeight(48)`
                    // （全宽按钮）。Row 会给非 flex 子项**无界宽度**，于是渲染层直接报
                    // "BoxConstraints forces an infinite width"（Release 下表现为文字
                    // 被挤成竖排、保存按钮飞出屏幕），放进 Row 必须显式给有限宽度。
                    FilledButton(
                      key: const Key('photo-tag-apply'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 40),
                      ),
                      onPressed: _submitting ? null : _apply,
                      child: Text(t.actionSave),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Gap.xs),
            ],
          ],
        ),
      ),
    );
  }
}
