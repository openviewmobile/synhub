// Office 批 D —— **服务端模板库 / 主题 / 版本历史**的只读（+ 从模板新建）UI。
//
// 证据（`docs/office-sample-corpus.md` §7/§9，2026-09-22 真机）：
//   * `Office.Template:list` v1 → 53 套（presentation 24 / doc 16 / sheet 13）；
//   * `Office.Template:make v1 {parent_id, object_id[, title]}` → **实测成功**，
//     回完整 Drive 节点（"从模板新建"的**唯一**已验证形态；`Node:create` 不支持）；
//   * `Office.Theme:list v1 {ntype:"presentation"}` → 17 套；
//   * `Office.Theme:apply v1 {…}` 参数名已钉，但**成功回包未取证** → 不假装写成功；
//   * `Office.Node.Version:list v1 {path|object_id}` → 版本可读（本文件只读展示）。
//
// 纪律：
//   * 模板 `title` 是 **i18n key**（`theme_presentation:opinion`）——**绝不上屏**，
//     显示 `officeTemplateTitleFromKey()`（查官方双语表，见
//     `office_template_text.dart` + `docs/office-template-gallery.md` §3）；
//   * **绝不显示 `object_id` / `file_id` / `link_id` 等内部 id**（既有铁律）；
//   * 缩略图走官方 `SYNO.Office.Template.Thumb:get`（真机 PNG，
//     `office_template_thumbs.dart`）；取不到才占位，绝不假装有图。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/office_version_dto.dart';
import '../../data/office_api.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'office_template_document.dart';
import 'office_template_preview.dart';
import 'office_template_text.dart';
import 'office_template_thumbs.dart';

String officeLibraryText(String key, String zh) => dataText(key, zh);

/// ntype → 可读标签（`presentation`/`doc`/`sheet` → 演示文稿/文档/表格）。
String officeLibraryNtypeLabel(String ntype) => officeTemplateTypeLabel(ntype);

IconData officeLibraryNtypeIcon(String ntype) => switch (ntype) {
  'presentation' => Icons.slideshow_outlined,
  'doc' => Icons.description_outlined,
  'sheet' => Icons.table_chart_outlined,
  _ => Icons.insert_drive_file_outlined,
};

// ---------------------------------------------------------------------------
// 模板库
// ---------------------------------------------------------------------------

/// 服务端官方模板库：**两列自适应网格 + 官方缩略图 + 全屏预览**。
///
/// 迁移决策全文见 `docs/office-template-gallery.md` §5（这是"适配安卓"，
/// 不是照抄桌面 Web）：
///   * 官方桌面卡片 280×200、一屏 4–5 列；手机竖屏 ~414dp ⇒ **2 列自适应网格**
///     （`maxCrossAxisExtent=220`，平板/横屏自动变 3–4 列）；
///   * 官方按类型给缩略图比例（presentation 16:9、doc/sheet 3:4）——本仓库沿用；
///   * 官方 hover 出悬浮菜单 ⇒ 手机改成**长按 / 卡片 ⋮ 出底部菜单**；
///   * 官方"点卡片 = 直接新建"（有副作用）⇒ 手机改成**点卡片 = 全屏预览**，
///     预览里显式点「使用此模板」才新建。
class OfficeTemplateLibraryView extends StatefulWidget {
  const OfficeTemplateLibraryView({
    super.key,
    required this.templates,
    this.makeTemplate,
    this.onTemplateCreated,
    this.onOpenTemplate,
    this.onFilterChanged,
    this.initialNtype,
    this.thumbFetcher,
    this.thumbCache,
    this.bodyFetcher,
    this.bodyCache,
    this.encrypt = false,
  });

  final List<OfficeTemplateDto> templates;

  /// `Future<Map<String,dynamic>> Function(template, title)`；接 `OfficeApi.templateMake`。
  final Future<Map<String, dynamic>> Function(
    OfficeTemplateDto template,
    String? title,
  )?
  makeTemplate;

  /// 新建成功后回调（参数是新建出的 Drive 节点原始回包）。
  final void Function(OfficeTemplateDto template, Map<String, dynamic> node)?
  onTemplateCreated;

  /// 外部接管"点卡片"行为（既有调用方仍可传；不传则用内置全屏预览）。
  final void Function(OfficeTemplateDto template)? onOpenTemplate;

  /// 类型筛选变化回调（`null` = 全部）。埋点由调用方决定，视图本身不记。
  final ValueChanged<String?>? onFilterChanged;

  /// 初始筛选（`null` = 全部）。
  final String? initialNtype;

  /// 缩略图字节提供者；null（未连接 / 单测没注入）时**不发请求**，只显示占位。
  final OfficeTemplateThumbFetcher? thumbFetcher;

  /// 缩略图缓存；null = 进程级默认实例。
  final OfficeTemplateThumbCache? thumbCache;

  /// **正文**字节提供者（生产 = `OfficeApi.templateExportBytes`）。
  ///
  /// null（未连接 / 单测没注入）⇒ 预览回落纯缩略图模式（既有行为不变）。
  final OfficeTemplateBodyFetcher? bodyFetcher;

  /// 正文缓存；null = 进程级默认实例。
  final OfficeTemplateBodyCache? bodyCache;

  /// 从**加密入口**进来时为 true（预览主按钮文案变「加密新建」）。
  final bool encrypt;

  @override
  State<OfficeTemplateLibraryView> createState() =>
      _OfficeTemplateLibraryViewState();
}

/// 组内排序 + 按官方 `TYPE_ORDER` 分组（纯函数，单测直接钉）。
///
/// 排序规则（照官方，别自己发明）：
///   1. 类型顺序 `doc → sheet → presentation`（未知类型最后）；
///   2. 组内 `isDeprecatedTemplate` 的 7 个演示主题**沉底**；
///   3. 再按 `sort_order`（真机 `Template:get` 才回，缺的排后面）；
///   4. 全部相同 → 保持服务端原顺序（稳定）。
List<OfficeTemplateDto> sortedOfficeTemplates(
  Iterable<OfficeTemplateDto> templates,
) {
  final input = templates.toList(growable: false);
  final original = <String, int>{
    for (var i = 0; i < input.length; i++) input[i].objectId: i,
  };
  int rank(OfficeTemplateDto t) => original[t.objectId] ?? 1 << 30;
  bool deprecated(OfficeTemplateDto t) =>
      isDeprecatedOfficeTemplateKey(t.titleKey);
  final out = [...input];
  out.sort((a, b) {
    final byType = officeTemplateTypeOrder(
      a.ntype,
    ).compareTo(officeTemplateTypeOrder(b.ntype));
    if (byType != 0) return byType;
    final byDeprecated = (deprecated(a) ? 1 : 0).compareTo(
      deprecated(b) ? 1 : 0,
    );
    if (byDeprecated != 0) return byDeprecated;
    final ao = a.sortOrder;
    final bo = b.sortOrder;
    if (ao != null || bo != null) {
      final byOrder = (ao ?? 1 << 30).compareTo(bo ?? 1 << 30);
      if (byOrder != 0) return byOrder;
    }
    return rank(a).compareTo(rank(b));
  });
  return out;
}

/// 按类型分组（返回顺序 = 官方 `TYPE_ORDER`），组内已 [sortedOfficeTemplates]。
Map<String, List<OfficeTemplateDto>> groupOfficeTemplates(
  Iterable<OfficeTemplateDto> templates,
) {
  final sorted = sortedOfficeTemplates(templates);
  final out = <String, List<OfficeTemplateDto>>{};
  for (final t in sorted) {
    out.putIfAbsent(t.ntype, () => <OfficeTemplateDto>[]).add(t);
  }
  return out;
}

class _OfficeTemplateLibraryViewState extends State<OfficeTemplateLibraryView> {
  static const double _maxCrossAxisExtent = 220;
  static const double _spacing = 12;
  static const double _metaHeight = 96;

  String? _ntype;
  String? _busyObjectId;
  String? _error;
  String? _createdTitle;

  @override
  void initState() {
    super.initState();
    _ntype = widget.initialNtype;
  }

  List<OfficeTemplateDto> get _visible => _ntype == null
      ? widget.templates
      : widget.templates.where((t) => t.ntype == _ntype).toList();

  /// 页签：官方三个类型里**有条目的**，外加数据里出现的未知类型。
  List<String> get _ntypes {
    final present = <String>{for (final t in widget.templates) t.ntype}
      ..remove('');
    final known = kOfficeTemplateKnownTypes
        .where(present.contains)
        .toList(growable: true);
    final extra = present.difference(kOfficeTemplateKnownTypes.toSet()).toList()
      ..sort();
    return [...known, ...extra];
  }

  /// 当前屏幕上（分组后）的模板顺序 —— 预览页左右滑动就按这个顺序。
  List<OfficeTemplateDto> get _sequence => [
    for (final group in groupOfficeTemplates(_visible).values) ...group,
  ];

  Future<void> _make(OfficeTemplateDto template) async {
    final make = widget.makeTemplate;
    if (make == null) return;
    final title = await showDialog<String>(
      context: context,
      builder: (context) => _MakeTemplateDialog(template: template),
    );
    if (title == null) return; // 取消
    setState(() {
      _busyObjectId = template.objectId;
      _error = null;
      _createdTitle = null;
    });
    try {
      final node = await make(template, title.isEmpty ? null : title);
      if (!mounted) return;
      setState(() {
        _busyObjectId = null;
        _createdTitle = officeTemplateTitleFromKey(template.titleKey);
      });
      widget.onTemplateCreated?.call(template, node);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busyObjectId = null;
        _error = officeLibraryText(
          'officeTemplateMakeFailed',
          '从模板新建失败：{error}',
        ).replaceAll('{error}', '$e');
      });
    }
  }

  Future<void> _openPreview(OfficeTemplateDto template) async {
    final external = widget.onOpenTemplate;
    if (external != null) {
      external(template);
      return;
    }
    final sequence = _sequence;
    final index = sequence.indexWhere((t) => t.objectId == template.objectId);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => OfficeTemplatePreviewPage(
          templates: sequence,
          initialIndex: index < 0 ? 0 : index,
          thumbFetcher: widget.thumbFetcher,
          thumbCache: widget.thumbCache,
          bodyFetcher: widget.bodyFetcher,
          bodyCache: widget.bodyCache,
          encrypt: widget.encrypt,
          onUseTemplate: widget.makeTemplate == null ? null : _make,
        ),
      ),
    );
  }

  /// 长按 / ⋮ → 底部菜单（手机没有 hover，官方那套悬浮菜单换成这个形态）。
  Future<void> _openCardMenu(OfficeTemplateDto template) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          key: const Key('office-template-menu-sheet'),
          mainAxisSize: MainAxisSize.min,
          children: [
            DesignRowTile(
              key: Key('office-template-menu-preview-${template.objectId}'),
              leading: const Icon(Icons.visibility_outlined),
              title: Text(
                officeLibraryText('officeTemplatePreviewAction', '预览'),
              ),
              onTap: () => Navigator.of(sheetContext).pop('preview'),
            ),
            if (widget.makeTemplate != null)
              DesignRowTile(
                key: Key('office-template-menu-make-${template.objectId}'),
                leading: const Icon(Icons.add_box_outlined),
                title: Text(officeLibraryText('officeTemplateMake', '从模板新建')),
                onTap: () => Navigator.of(sheetContext).pop('make'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'preview') {
      await _openPreview(template);
    } else if (action == 'make') {
      // 卡片菜单的「从模板新建」（预览里的主按钮走 `_use`，两条都只记一次）。
      trackOnce(UsageModule.office, UsageAction.create, objectType: 'template');
      await _make(template);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.templates.isEmpty) {
      return _emptyState(context);
    }
    return Column(
      key: const Key('office-template-library'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tabStrip(context),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.md,
              vertical: Gap.xs,
            ),
            child: Text(
              _error!,
              key: const Key('office-template-make-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_createdTitle != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.md,
              vertical: Gap.xs,
            ),
            child: Text(
              officeLibraryText(
                'officeTemplateMakeCreated',
                '已从模板「{name}」新建',
              ).replaceAll('{name}', _createdTitle ?? ''),
              key: const Key('office-template-make-result'),
            ),
          ),
        const Divider(height: 1),
        Expanded(child: _grid(context)),
      ],
    );
  }

  Widget _emptyState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: const Key('office-template-library-empty'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dashboard_customize_outlined,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: Gap.sm),
            Text(
              officeLibraryText('officeTemplateLibraryEmpty', '服务端没有返回可用模板'),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabStrip(BuildContext context) {
    final counts = <String, int>{};
    for (final t in widget.templates) {
      counts[t.ntype] = (counts[t.ntype] ?? 0) + 1;
    }
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
        children: [
          _filterChip(
            null,
            officeLibraryText('officeTemplateFilterAll', '全部'),
            widget.templates.length,
          ),
          for (final ntype in _ntypes)
            _filterChip(
              ntype,
              officeTemplateTypeLabel(ntype),
              counts[ntype] ?? 0,
            ),
        ],
      ),
    );
  }

  Widget _grid(BuildContext context) {
    final groups = groupOfficeTemplates(_visible);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - Gap.sm * 2;
        // ★ 必须与 `SliverGridDelegateWithMaxCrossAxisExtent` 内部同一公式
        //   （`(extent / (maxExtent + spacing)).ceil()`），否则算出的列数偏多、
        //   `tileWidth` 偏小 ⇒ `mainAxisExtent` 偏小 ⇒ 卡片底部溢出
        //   （第 260 轮 wiring 用例当场抓到 12px RenderFlex overflow）。
        final columns = math.max(
          1,
          (available / (_maxCrossAxisExtent + _spacing)).ceil(),
        );
        final tileWidth = (available - (columns - 1) * _spacing) / columns;
        return CustomScrollView(
          key: const Key('office-template-list'),
          slivers: [
            for (final entry in groups.entries) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  Gap.sm,
                  Gap.md,
                  Gap.sm,
                  Gap.xs,
                ),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    '${officeTemplateTypeLabel(entry.key)} '
                    '(${entry.value.length})',
                    key: Key('office-template-group-${entry.key}'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: _maxCrossAxisExtent,
                    mainAxisExtent:
                        tileWidth / officeTemplateThumbAspect(entry.key) +
                        _metaHeight,
                    crossAxisSpacing: _spacing,
                    mainAxisSpacing: _spacing,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _card(context, entry.value[i]),
                    childCount: entry.value.length,
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: Gap.lg)),
          ],
        );
      },
    );
  }

  Widget _filterChip(String? ntype, String label, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xxs),
      child: Center(
        child: ChoiceChip(
          key: Key('office-template-filter-${ntype ?? 'all'}'),
          label: Text('$label ($count)'),
          selected: _ntype == ntype,
          onSelected: (_) {
            setState(() => _ntype = ntype);
            widget.onFilterChanged?.call(ntype);
          },
        ),
      ),
    );
  }

  Widget _card(BuildContext context, OfficeTemplateDto template) {
    final scheme = Theme.of(context).colorScheme;
    final title = officeTemplateTitleFromKey(template.titleKey);
    final busy = _busyObjectId == template.objectId;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('office-template-item-${template.objectId}'),
        // 点卡片 = 预览（**不直接新建**：新建会在用户 Drive 里造文件，有副作用）。
        onTap: busy ? null : () => _openPreview(template),
        onLongPress: busy ? null : () => _openCardMenu(template),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 图占剩余高度、元信息固定高度 ⇒ 即使某天 `mainAxisExtent` 与
            // 真实格宽出现偏差，也只会让图片比例略有出入，**永远不会溢出**。
            Expanded(
              child: OfficeTemplateThumbnail(
                objectId: template.objectId,
                ver: template.thumbVer,
                fetcher: widget.thumbFetcher,
                cache: widget.thumbCache,
                semanticLabel: title,
              ),
            ),
            SizedBox(
              height: _metaHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xs, 6, 2, 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        key: Key(
                          'office-template-item-title-${template.objectId}',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    // ★ D21（r719）：原来是 `Flexible(类型) + 来源 + Spacer + 菜单`，
                    //   窄卡片下**类型标签**先被挤（真机像素截成 `Docume… System`，
                    //   两个词还粘在一起）。按 §2.0.18：不许缩字号，改**布局预算** ——
                    //   把「类型 + 来源」放进 `Wrap`，横向不够就换行，
                    //   腾出的宽度全部留给文字；菜单仍固定贴右。
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: Gap.xxs,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                officeTemplateTypeLabel(template.ntype),
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                              Text(
                                template.system
                                    ? officeLibraryText(
                                        'officeTemplateSourceSystem',
                                        '系统',
                                      )
                                    : officeLibraryText(
                                        'officeTemplateSourceMine',
                                        '我的',
                                      ),
                                key: Key(
                                  'office-template-source-${template.objectId}',
                                ),
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        if (busy)
                          const Padding(
                            padding: EdgeInsets.all(Gap.xs),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        else
                          IconButton(
                            key: Key(
                              'office-template-menu-${template.objectId}',
                            ),
                            tooltip: officeLibraryText(
                              'officeTemplateMoreActions',
                              '更多操作',
                            ),
                            iconSize: 18,
                            constraints: const BoxConstraints.tightFor(
                              width: 36,
                              height: 36,
                            ),
                            padding: EdgeInsets.zero,
                            onPressed: () => _openCardMenu(template),
                            icon: const Icon(Icons.more_vert),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 模板库**加载态骨架**：官方 `#e2e6ea` 骨架底色 + 与真网格同形的占位卡片
/// —— 图片到达时布局不跳动。
class OfficeTemplateGridSkeleton extends StatelessWidget {
  const OfficeTemplateGridSkeleton({super.key, this.cards = 6});

  final int cards;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      key: const Key('office-template-library-loading'),
      padding: const EdgeInsets.all(Gap.sm),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: cards,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisExtent: 220,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemBuilder: (context, i) => DecoratedBox(
        decoration: BoxDecoration(
          color: kOfficeTemplateThumbSkeleton.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}

class _MakeTemplateDialog extends StatefulWidget {
  const _MakeTemplateDialog({required this.template});

  final OfficeTemplateDto template;

  @override
  State<_MakeTemplateDialog> createState() => _MakeTemplateDialogState();
}

class _MakeTemplateDialogState extends State<_MakeTemplateDialog> {
  // 默认文件名 = 用户刚刚在预览/网格里看到的**本地化标题**（中文机就是中文名，
  // 英文机就是英文名）——不是 `section:key`，也不再用 ASCII 拆词回落。
  late final TextEditingController _controller = TextEditingController(
    text: officeTemplateTitleFromKey(widget.template.titleKey),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('office-template-make-dialog'),
      title: Text(officeLibraryText('officeTemplateMakeDialogTitle', '从模板新建')),
      content: TextField(
        key: const Key('office-template-make-title-field'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: officeLibraryText(
            'officeTemplateMakeTitleLabel',
            '文件名（可留空）',
          ),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          key: const Key('office-template-make-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(officeLibraryText('officeTemplateMakeCancel', '取消')),
        ),
        FilledButton(
          key: const Key('office-template-make-confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(officeLibraryText('officeTemplateMakeConfirm', '创建')),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 主题
// ---------------------------------------------------------------------------

/// 主题选择 / 应用入口（`Office.Theme:list` + `Theme:apply`）。
///
/// `onApply` 非空时才显示"应用"；调用方接 [OfficeApi.themeApply]。
/// ⚠️ `Theme:apply` 成功回包未取证 → **不显示"已应用成功"**，只如实回调/报错。
class OfficeThemePickerView extends StatefulWidget {
  const OfficeThemePickerView({
    super.key,
    required this.themes,
    this.onApply,
    this.ntype = 'presentation',
  });

  final List<OfficeThemeDto> themes;
  final Future<void> Function(OfficeThemeDto theme)? onApply;
  final String ntype;

  @override
  State<OfficeThemePickerView> createState() => _OfficeThemePickerViewState();
}

class _OfficeThemePickerViewState extends State<OfficeThemePickerView> {
  String? _selected;
  bool _busy = false;
  String? _error;
  String? _applied;

  Future<void> _apply() async {
    final apply = widget.onApply;
    final theme = widget.themes.firstWhere(
      (t) => t.id == _selected,
      orElse: () => const OfficeThemeDto(
        id: '',
        order: 0,
        titleKey: '',
        titleSection: '',
      ),
    );
    if (apply == null || theme.id.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await apply(theme);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _applied = theme.title;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = officeLibraryText('officeThemeApplyFailed', '应用主题失败：$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.themes.isEmpty) {
      return Center(
        key: const Key('office-theme-empty'),
        child: Text(officeLibraryText('officeThemeEmpty', '这个类型没有可用主题')),
      );
    }
    return Column(
      key: const Key('office-theme-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: Text(
              _error!,
              key: const Key('office-theme-apply-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_applied != null)
          Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: Text(
              // ⚠️ 措辞刻意保守：只说"已请求"（服务端回包不保证）。
              // r378：去掉"未取证"这类开发用语 —— 保守性靠**动词**（"已请求"）表达，
              // 不需要把工程状态印给用户。
              officeLibraryText('officeThemeApplied', '已请求服务端应用主题「$_applied」'),
              key: const Key('office-theme-applied'),
            ),
          ),
        Expanded(
          child: RadioGroup<String>(
            groupValue: _selected,
            onChanged: (v) => setState(() => _selected = v),
            child: ListView.builder(
              key: const Key('office-theme-list'),
              itemCount: widget.themes.length,
              itemBuilder: (context, i) {
                final theme = widget.themes[i];
                return RadioListTile<String>(
                  key: Key('office-theme-item-${theme.id}'),
                  value: theme.id,
                  title: Text(
                    theme.title,
                    key: Key('office-theme-item-title-${theme.id}'),
                  ),
                );
              },
            ),
          ),
        ),
        if (widget.onApply != null)
          Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: FilledButton(
              key: const Key('office-theme-apply'),
              onPressed: _busy || _selected == null ? null : _apply,
              child: Text(officeLibraryText('officeThemeApply', '应用主题')),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 版本历史（只读）
// ---------------------------------------------------------------------------

/// Office 原生文档的**只读**版本列表（版本号 / 时间 / 编辑者）。
///
/// 数据来自 `Office.Node.Version:list`（既有 [OfficeVersionDto]）。
/// **还原 / 下载某版本**在批 D **不做**（形态未取证，报告登记）。
class OfficeVersionListView extends StatelessWidget {
  const OfficeVersionListView({super.key, required this.versions});

  final List<OfficeVersionDto> versions;

  @override
  Widget build(BuildContext context) {
    if (versions.isEmpty) {
      return Center(
        key: const Key('office-version-empty'),
        child: Text(officeLibraryText('officeVersionEmpty', '还没有版本记录')),
      );
    }
    return ListView.builder(
      key: const Key('office-version-list'),
      itemCount: versions.length,
      itemBuilder: (context, i) {
        final v = versions[i];
        return DesignRowTile(
          key: Key('office-version-item-${v.version}'),
          leading: const Icon(Icons.history),
          title: Text(v.hasName ? v.verName : v.version),
          subtitle: Text(_subtitle(v)),
          trailing: v.firstVersion
              ? Text(officeLibraryText('officeVersionFirst', '初始版本'))
              : null,
        );
      },
    );
  }

  String _subtitle(OfficeVersionDto v) {
    final parts = <String>[];
    final t = v.modifiedTime;
    if (t != null) {
      String two(int n) => n.toString().padLeft(2, '0');
      parts.add(
        '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}',
      );
    }
    final editors = v.editors.isEmpty
        ? v.author
        : v.editors.join(officeLibraryText('listSeparator', '、'));
    if (editors.isNotEmpty) parts.add(editors);
    return parts.join(' · ');
  }
}
