// `.oslides`（PPTX）**阅读器**：16:9 幻灯片画布 + 缩略图侧栏 + 左右滑动翻页 +
// 页码指示 + 全屏放映 + 双指缩放 + 备注。
//
// 设计口径（对齐 WPS / Microsoft Office 安卓版的用户预期）：
//   * 一眼看到的就是**幻灯片本身**（白纸/彩底 + 图 + 文字），不是"文字流"；
//   * 形状按 PPTX 里的**真实 EMU 坐标**绝对定位（`ppt/slides/slideN.xml` 的形状是
//     占位符，几何来自 `slideLayouts/*.xml` / `slideMasters/*.xml` —— 继承已在
//     `oslides_ooxml.dart` 里算完，这里只负责摆位与绘制）；
//   * 文字的字号/颜色/加粗/对齐/项目符号/行距都按文件声明渲染；
//   * 翻页方式：**左右滑动**（`PageView`）+ 缩略图侧栏点击跳页 + 页码指示 `2 / 15`；
//   * 点画布 = **全屏放映**（黑底、可双指缩放、可左右翻页、可看备注）。
//
// 兜底（硬要求：不许静默空白）：
//   * 一页里出现本批不渲染的对象（表格/图表/SmartArt）→ 画一张**可读的占位卡**
//     说明"这张幻灯片包含暂不支持的对象"；
//   * 整页没有任何可绘制内容 → 明确说"这张幻灯片没有可显示的内容"；
//   * SVG 矢量图（`ppt/media/*.svg`）由**自研渲染器**（`office_svg_painter.dart`）
//     画出来；**解析不出图形**的矢量格式（svgz / emf / wmf）不画、不猜。
//
// 这里**没有**任何"本批/从简/只读预览"之类的工程措辞：降级文案只在真的需要时出现。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/office_native/oslides_ooxml.dart';
import 'office_svg_painter.dart';

String _t(String key, String zh) => dataText(key, zh);

String _fill(String key, String zh, Map<String, String> values) {
  var out = _t(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// pt → px（96 dpi）：PPTX 的字号是磅，画布坐标系是 px。
double pptxPtToPx(double pt) => pt * 96 / 72;

/// 竖屏底部胶片栏高度（dp）。
///
/// 预算（dp）：缩略图 54 + 间距 2 + 序号行约 16 + 列表内边距 12 + 当前页
/// 高亮底的内边距 4 + 顶边线 1 ≈ 89 ⇒ 取 96 留出字体差异的余量
/// （88 时真机字体行高更大，会 RenderFlex overflow）。
const double stripHeight = 96;

/// 一份 PPTX 演示文稿的**阅读器**。
class OfficeSlidesDeckView extends StatefulWidget {
  const OfficeSlidesDeckView({
    super.key,
    required this.deck,
    this.initialIndex = 0,
    this.showThumbnails = true,
  });

  final OSlidesDeck deck;
  final int initialIndex;

  /// 窄屏（手机竖屏）下缩略图侧栏可以关掉，默认开。
  final bool showThumbnails;

  @override
  State<OfficeSlidesDeckView> createState() => _OfficeSlidesDeckViewState();
}

class _OfficeSlidesDeckViewState extends State<OfficeSlidesDeckView> {
  late final PageController _controller;
  late int _index;
  bool _showNotes = false;

  /// 底部缩略图浮层是否可见。默认跟随 `showThumbnails`，
  /// 用户可点工具栏页码开关；**在画布上缩放/平移会自动收起**。
  late bool _showStrip = widget.showThumbnails;

  final ScrollController _stripController = ScrollController();

  /// 横屏竖栏专用（同一个 controller 不能同时挂到两个 scrollable 上）。
  final ScrollController _railController = ScrollController();

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, _maxIndex);
    _controller = PageController(initialPage: _index);
  }

  int get _maxIndex =>
      widget.deck.slides.isEmpty ? 0 : widget.deck.slides.length - 1;

  @override
  void dispose() {
    _controller.dispose();
    _stripController.dispose();
    _railController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deck = widget.deck;
    if (deck.slides.isEmpty) {
      return _EmptyCard(
        key: const Key('office-slides-deck-empty'),
        text: _t('officeSlidesDeckEmpty', '这份演示文稿里没有可显示的幻灯片'),
      );
    }
    final index = _index.clamp(0, _maxIndex);
    return Column(
      key: const Key('office-slides-deck'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(context, index),
        // ⚠️ **主画布必须吃满全宽**（2026-09-22 改版）。
        //
        // 旧版把缩略图放成左侧 116dp 的**常驻竖栏**，在 375dp 宽的手机上
        // 一口气吃掉 **31% 的宽度**：主画布只剩 243dp。
        // 幻灯片是 16:9 的横向内容，**横向空间比纵向金贵得多**，
        // 这个代价换来的是"每屏都能看见 10 个缩略图"——而用户其实只需要
        // 知道"我在第几页 / 想跳到第几页"。
        //
        // 新版（2026-09-22 第三轮）把竖屏的缩略图从**贴底浮层**改成
        // **参与布局的胶片栏**。理由都是**从真机实测像素出发的**：
        //
        //   * 浮层贴在 `bottom: 0`，**不吃底部系统区**。本机实测
        //     `ITYPE_NAVIGATION_BAR` 高 0、`ITYPE_BOTTOM_MANDATORY_GESTURES`
        //     高 123px ⇒ 序号落在**系统手势条**上（视觉被压住、点按会被系统抢走）。
        //   * 浮层底色 `surface@0.88` 与舞台底色实测只差 Δ≈4/255
        //     ⇒ 画面与缩略图之间**看不出分隔**。
        //   * 浮层盖住画面本身。
        //
        // 改成参与布局后：缩略图**不会被任何东西遮挡**、顶部有一条实边线、
        // 而且主画布**一像素都不会变小** —— 竖屏是**宽受限**的
        // （实测画布 1098×617px，AR=1.7796，宽度已吃满 1148px 屏宽），
        // 把竖向空间分给胶片栏不动画布尺寸。
        //
        // 横屏保持左侧竖栏：横屏是**高受限**，侧栏不损失画布（见下方算术）。
        Expanded(
          // ⚠️ **按方向自适应**（2026-09-22 第二轮改版）。
          //
          // 这不是"好看不好看"的口味问题，而是**能用数字证明的最优解**：
          // 幻灯片是 16:9 的横向内容，画布实际缩放比是
          //   `scale = min(可用宽/960, 可用高/540)`
          // 取两者**较小值** —— 所以只有"受限的那一边"才真正影响画布大小。
          //
          // * **竖屏**（如 375x592 的舞台）：宽受限。
          //   `min(375/960, 592/540) = 0.391` ⇒ 画布 375x211。
          //   若放左侧 116dp 常驻栏：`min(251/960, ...) = 0.261` ⇒ 画布 251x141。
          //   **侧栏吃掉 33% 的宽度，画布面积只剩 56%。**
          //   ⇒ 竖屏必须用**底部横条**（占的是富裕的高度，画布不缩）。
          //
          // * **横屏**（如 813x300 的舞台）：高受限。
          //   `min(805/960, 300/540) = 0.556` ⇒ 画布 534x300。
          //   放左侧 116dp 栏：`min(689/960, 300/540) = 0.556` ⇒ **画布仍是 534x300**。
          //   **横屏加侧栏，画布一像素都不损失**（因为限制在高度上，宽度本来就用不完）。
          //   ⇒ 横屏用**左侧竖栏**：同屏能看到的缩略图更多（高度富裕），
          //     而且不遮挡画面。
          //
          // 用 `OrientationBuilder` 而不是 `MediaQuery.orientationOf`：
          // 前者跟随**这个舞台盒子自己**的宽高比，在分屏/异形屏下更准。
          child: OrientationBuilder(
            builder: (context, orientation) {
              if (orientation == Orientation.landscape) {
                return Column(
                  key: const Key('office-slides-stage'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 横屏是**高受限**的：备注面板放上面（竖屏放下面，见下）。
                    if (_showNotes) _notesPanel(context, deck.slides[index]),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (widget.showThumbnails && _showStrip)
                            _thumbnailRail(context, index),
                          Expanded(child: _pager(context, index)),
                        ],
                      ),
                    ),
                  ],
                );
              }
              return Column(
                key: const Key('office-slides-stage'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _pager(context, index)),
                  // ⚠️ 竖屏把备注放在**画布下方**（而不是上方）。
                  //
                  // 竖屏"上下巨大留白"是几何必然（16:9 内容吃满宽度后只剩
                  // 617px 高，而舞台有 1691px）—— 留白本身消灭不了，
                  // 但可以**让它有用**：备注面板占的正是这块本来白扔的高度，
                  // 因为画布是宽受限的，**备注面板多高都不会缩小画布**
                  //（只要 pager 剩余高度 ≥ 617px，实测余量 >1000px）。
                  if (_showNotes) _notesPanel(context, deck.slides[index]),
                  if (widget.showThumbnails && _showStrip)
                    _thumbnailStrip(context, index),
                ],
              );
            },
          ),
        ),
        // 底部系统区（导航栏 / 底部手势区）—— 见 [_bottomInset]。
        SizedBox(
          key: const Key('office-slides-bottom-inset'),
          height: _bottomInset(context),
        ),
      ],
    );
  }

  /// 底部系统区安全边距。
  ///
  /// ⚠️ **为什么不是只看 `viewPadding.bottom`**（2026-09-22 真机实测）：
  /// HONOR LGE-AN10（Android 12 / 1148×2492 @490dpi / 手势导航）实测
  /// ```
  /// InsetsSource type=ITYPE_NAVIGATION_BAR               frame=[0,2492][1148,2492]  ← 高 0
  /// InsetsSource type=ITYPE_BOTTOM_MANDATORY_GESTURES    frame=[0,2369][1148,2492]  ← 高 123px
  /// ```
  /// 只读 `viewPadding.bottom` 得到 **0**，于是胶片栏的序号落在
  /// **系统手势条**上：视觉上被手势条压住（用户原话"被屏幕下沿切断"），
  /// 交互上落在系统手势区里 —— 缩略图是**点按目标**，
  /// 靠底边的一次点按可能被系统"上滑回主屏"抢走。
  ///
  /// 所以取两者**较大值**：既让开导航栏，也让开底部手势区。
  double _bottomInset(BuildContext context) {
    final mq = MediaQuery.of(context);
    final gesture = mq.systemGestureInsets.bottom;
    final padding = mq.viewPadding.bottom;
    return gesture > padding ? gesture : padding;
  }

  // ------------------------------------------------------------------ 工具条

  Widget _toolbar(BuildContext context, int index) {
    final theme = Theme.of(context);
    final total = widget.deck.slides.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
      color: DesignPalette.of(context).surface,
      child: Row(
        children: [
          // 页码指示（1 基）。**可点**：开关底部缩略图浮层。
          // 浮层默认是开着的，但用户一旦用画布缩放把它挤掉，
          // 需要一个"显而易见又能找回来"的入口 —— 页码是最自然的位置。
          if (widget.showThumbnails)
            Tooltip(
              message: _showStrip
                  ? _t('officeSlidesDeckHideThumbs', '隐藏幻灯片列表')
                  : _t('officeSlidesDeckShowThumbs', '显示幻灯片列表'),
              child: InkWell(
                key: const Key('office-slides-thumbnails-toggle'),
                onTap: () => setState(() => _showStrip = !_showStrip),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${index + 1} / $total',
                      key: const Key('office-slides-page-indicator'),
                      style: theme.textTheme.labelLarge,
                    ),
                    Icon(
                      _showStrip ? Icons.expand_more : Icons.expand_less,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            )
          else
            Text(
              '${index + 1} / $total',
              key: const Key('office-slides-page-indicator'),
              style: theme.textTheme.labelLarge,
            ),
          const Spacer(),
          IconButton(
            key: const Key('office-slides-notes-toggle'),
            tooltip: _t('officeSlidesDeckNotes', '备注'),
            isSelected: _showNotes,
            icon: const Icon(Icons.sticky_note_2_outlined, size: 20),
            selectedIcon: const Icon(Icons.sticky_note_2, size: 20),
            onPressed: () => setState(() => _showNotes = !_showNotes),
          ),
          if (_hasInfo) ...[
            IconButton(
              key: const Key('office-slides-info'),
              tooltip: _t('officeSlidesDeckInfoTitle', '演示文稿信息'),
              icon: const Icon(Icons.info_outline, size: 20),
              onPressed: () => _showInfoSheet(context),
            ),
          ],
          IconButton(
            key: const Key('office-slides-fullscreen'),
            tooltip: _t('officeSlidesDeckFullscreen', '全屏放映'),
            icon: const Icon(Icons.fullscreen, size: 20),
            onPressed: () => _openFullscreen(context, index),
          ),
        ],
      ),
    );
  }

  /// 只有真的有"说不出口的东西"时才显示信息入口（不常驻横幅）。
  bool get _hasInfo =>
      widget.deck.unrenderableVectorCount > 0 ||
      widget.deck.unsupportedObjectCount > 0 ||
      widget.deck.degradations.isNotEmpty;

  Future<void> _showInfoSheet(BuildContext context) async {
    final deck = widget.deck;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        key: const Key('office-slides-info-sheet'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _t('officeSlidesDeckInfoTitle', '演示文稿信息'),
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: Gap.sm),
              Text(
                _fill('officeSlidesDeckInfoSize', '画布 {w}×{h}（{ratio}）', {
                  'w': '${deck.widthEmu}',
                  'h': '${deck.heightEmu}',
                  'ratio': deck.isWidescreen
                      ? '16:9'
                      : (deck.isStandard
                            ? '4:3'
                            : '${(deck.widthPx / deck.heightPx).toStringAsFixed(2)}:1'),
                }),
              ),
              Text(
                _fill('officeSlidesDeckInfoPages', '幻灯片 {n} 页', {
                  'n': '${deck.slides.length}',
                }),
              ),
              Text(
                _fill('officeSlidesDeckInfoLayouts', '版式 {n} 套', {
                  'n': '${deck.layoutCount}',
                }),
              ),
              if (deck.unrenderableVectorCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(
                    _t('officeSlidesDeckVectorNote', '部分矢量图形（如 SVG 图标）暂不显示。'),
                    key: const Key('office-slides-vector-note'),
                  ),
                ),
              if (deck.unsupportedObjectCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(
                    _fill(
                      'officeSlidesDeckUnsupportedSummary',
                      '有 {n} 个对象（表格/图表/图示）暂不支持显示。',
                      <String, String>{'n': '${deck.unsupportedObjectCount}'},
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _notesPanel(BuildContext context, OSlidesDeckSlide slide) {
    final theme = Theme.of(context);
    final notes = slide.notes.trim();
    return Container(
      key: const Key('office-slides-notes-panel'),
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 132),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: SingleChildScrollView(
        child: Text(
          notes.isEmpty ? _t('officeSlidesDeckNoNotes', '这一页没有备注') : notes,
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 缩略图侧栏

  /// 底部**胶片栏**（参与布局，不是浮层）。
  ///
  /// 设计取舍见 `build` 里那段注释：竖屏必须用横条（横向空间金贵），
  /// 但**不能**做成贴底浮层 —— 浮层不吃系统手势区、且与舞台底色的对比
  /// 只有 Δ≈4/255（实测）。改成参与布局的常驻面板后：
  ///
  /// * 高度固定 [stripHeight]（缩略图 54dp + 序号 + 内边距），占**竖向**空间；
  /// * 底色**不透明** + 一条 `outlineVariant` 实边线 ⇒ 与画面明确分层；
  /// * 横向 `ListView`，切页时**自动滚动**到当前页（[`_revealCurrentThumb`]）；
  /// * 当前页有三种同时生效的高亮：`primary` 2dp 边框 + `primary@16%` 底 +
  ///   序号加粗变 `primary`（只靠一像素边框在缩略图里是看不清的）；
  /// * `IgnorePointer` 包住缩略图本体，点击由外层 `InkWell` 处理，
  ///   免得 `SlideCanvas` 里任何手势把点击吃掉。
  Widget _thumbnailStrip(BuildContext context, int index) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = widget.deck.slides.length;
    return Material(
      key: const Key('office-slides-thumbnails'),
      // **不透明**：半透明会让舞台底色透上来，画面与胶片栏之间就没有分隔
      // （真机实测：浮层底 (17,19,24) vs 舞台底 (13,17,27) ⇒ Δ≈4/255）。
      color: scheme.surfaceContainerHigh,
      child: Container(
        height: stripHeight,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: scheme.outlineVariant, width: 1),
          ),
        ),
        child: ListView.builder(
          controller: _stripController,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 6),
          itemCount: total,
          itemBuilder: (context, i) {
            final selected = i == index;
            // ★ 真机 r609（DA201，亮色 + 动态取色）：页码用 `scheme.primary`，
            // 而选中底是 `primary @16%` 叠在胶片栏底上 ⇒ 实测 **4.41:1**
            // （(51,99,131) on (203,215,226)），差 0.09 掉出 AA。
            // 判据钉在**真正画出去的底**上：先算合成色，再按它校正。
            // 4.6 而不是 4.5：合成底是浮点叠加、8 位量化后可能差一个通道，
            // 卡 4.5 会反复出现"这边 4.50、像素 4.46"的假绿。
            final thumbFill = Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.16),
              scheme.surfaceContainerHigh,
            );
            final thumbNumberColor = selected
                ? DesignPalette.ensureContrast(
                    scheme.primary,
                    thumbFill,
                    min: 4.6,
                    brightness: theme.brightness,
                  )
                : scheme.onSurfaceVariant;
            return Padding(
              padding: const EdgeInsets.only(right: Gap.xs),
              child: InkWell(
                key: Key('office-slides-thumb-$i'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => _controller.animateToPage(
                  i,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                ),
                child: Container(
                  // 当前页高亮的**可观测点**：只在当前页存在。
                  key: selected ? Key('office-slides-thumb-selected-$i') : null,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary.withValues(alpha: 0.16)
                        : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 54,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: selected
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                              width: selected ? 2 : 1,
                            ),
                          ),
                          child: IgnorePointer(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: SlideCanvas(
                                deck: widget.deck,
                                slide: i,
                                compact: true,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${i + 1}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          // ★ r537（DA171，真机亮色像素 1.15:1）：页码是**文字**，
                          // 原来未选中用 `outline`（那是画边框的颜色）⇒ 几乎看不见。
                          // ★ r609（DA201）：选中态也不许直接吃 `primary`。
                          color: thumbNumberColor,
                          fontWeight: selected ? FontWeight.w700 : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// **横屏**用的左侧竖栏（与竖屏的底部浮层是同一份数据、同一种交互）。
  ///
  /// 为什么不干脆竖屏横屏都用浮层？因为在横屏里**侧栏不损失画布**（见 `build`
  /// 里的算术），却能同屏显示更多缩略图、且完全不遮挡画面 —— 比浮层更好。
  ///
  /// 宽度 116dp 与原实现一致；`_railController` 负责切页时滚到当前项。
  Widget _thumbnailRail(BuildContext context, int index) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const Key('office-slides-thumbnails'),
      width: 116,
      color: scheme.surfaceContainerLow,
      child: ListView.builder(
        controller: _railController,
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        itemCount: widget.deck.slides.length,
        itemBuilder: (context, i) {
          final selected = i == index;
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.xs,
              vertical: 3,
            ),
            child: InkWell(
              key: Key('office-slides-thumb-$i'),
              onTap: () => _controller.animateToPage(
                i,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    child: Text(
                      '${i + 1}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        // ★ r537（DA171）：同上一处 —— 页码是文字，不用 `outline`。
                        // ★ r609（DA201）：与底部条同一把尺子（横屏这里没有叠加底，
                        // 仍走一遍校正，免得以后改底色时又掉出去）。
                        color: selected
                            ? DesignPalette.ensureContrast(
                                scheme.primary,
                                scheme.surfaceContainerLow,
                                min: 4.6,
                                brightness: theme.brightness,
                              )
                            : scheme.onSurfaceVariant,
                        fontWeight: selected ? FontWeight.w700 : null,
                      ),
                    ),
                  ),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: selected
                              ? scheme.primary
                              : scheme.outlineVariant,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: IgnorePointer(
                        child: SlideCanvas(
                          deck: widget.deck,
                          slide: i,
                          compact: true,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 把当前页滚进横屏竖栏的可视区。
  void _revealCurrentRail(int index) {
    if (!_railController.hasClients) return;
    // 竖栏单项高约 94dp（116 宽 ⇒ 缩略图高 65 + 序号/间距）。
    const itemExtent = 94.0;
    final target = (index * itemExtent - itemExtent * 1.5).clamp(
      0.0,
      _railController.position.maxScrollExtent,
    );
    _railController.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// 把当前页的缩略图滚进可视区（切页时调用；`hasClients` 保护首帧）。
  void _revealCurrentThumb(int index) {
    if (!_stripController.hasClients) return;
    const itemExtent = 100.0;
    final target = (index * itemExtent - itemExtent * 1.5).clamp(
      0.0,
      _stripController.position.maxScrollExtent,
    );
    _stripController.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  // -------------------------------------------------------------------- 翻页

  Widget _pager(BuildContext context, int index) {
    return PageView.builder(
      key: const Key('office-slides-pages'),
      controller: _controller,
      itemCount: widget.deck.slides.length,
      onPageChanged: (i) {
        setState(() => _index = i);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _revealCurrentThumb(i);
          _revealCurrentRail(i);
        });
      },
      itemBuilder: (context, i) {
        final slide = widget.deck.slides[i];
        return GestureDetector(
          key: Key('office-slides-page-${slide.order}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _openFullscreen(context, i),
          child: Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: Center(
              child: InteractiveViewer(
                key: Key('office-slides-zoom-${slide.order}'),
                minScale: 1,
                maxScale: 6,
                clipBehavior: Clip.none,
                // 用户一旦在画布上缩放/平移，就**自动收起**底部胶片栏：
                // 那一刻他要的是尽可能大的画面，而缩略图的使命（挑页）已完成。
                // 只监听 `onInteractionStart`（拖动/捏合），**不监听单击** ——
                // 单击仍然是进全屏放映。
                onInteractionStart: (_) {
                  if (_showStrip) setState(() => _showStrip = false);
                },
                // 幻灯片在舞台底色上要有"纸边"（PowerPoint/WPS 的放映视图同样
                // 给幻灯片一圈投影）：深色底 + 深色页时，没有投影就看不出
                // 画面到哪里为止。投影画在画布**外面**，不改画布尺寸。
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: SlideCanvas(deck: widget.deck, slide: i),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openFullscreen(BuildContext context, int index) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            OfficeSlidesFullscreenView(deck: widget.deck, initialIndex: index),
      ),
    );
  }
}

// ---------------------------------------------------------------------- 画布

/// 一页幻灯片：**16:9 画布** + 按真实坐标绝对定位的形状。
///
/// 坐标系是 PPTX 的 px（EMU/9525，96 dpi）；整页按可用宽高等比缩放。
class SlideCanvas extends StatelessWidget {
  const SlideCanvas({
    super.key,
    required this.deck,
    required this.slide,
    this.compact = false,
  });

  final OSlidesDeck deck;

  /// 页序（0 基）。
  final int slide;

  /// 缩略图模式：不渲染文字/图片，只画色块与形状轮廓，省内存。
  final bool compact;

  OSlidesDeckSlide get _slide => deck.slides[slide];

  @override
  Widget build(BuildContext context) {
    final s = _slide;
    final w = deck.widthPx <= 0 ? 960.0 : deck.widthPx;
    final h = deck.heightPx <= 0 ? 540.0 : deck.heightPx;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availW = constraints.maxWidth.isFinite ? constraints.maxWidth : w;
        final availH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : h;
        var scale = availW / w;
        if (availH.isFinite && availH > 0) {
          final byHeight = availH / h;
          if (byHeight < scale) scale = byHeight;
        }
        return SizedBox(
          key: Key(
            compact
                ? 'office-slides-thumb-canvas-$slide'
                : 'office-slides-canvas-$slide',
          ),
          width: w * scale,
          height: h * scale,
          child: ClipRect(
            // ⚠️⚠️ **必须用 `OverflowBox` 把紧约束解开**（真机缺陷根因，2026-09-22）。
            //
            // 缺陷现象：真机上 `.oslides` 主画布只画出**一小块**内容
            // （实测内容包围盒 62x35 dp，而画布本身是 243x137 dp），其余是脚手架底色。
            //
            // 根因：外层 `SizedBox(width: w*scale, height: h*scale)` 给出的是**紧约束**，
            // `Transform.scale` 作为 RenderProxyBox **原样把紧约束下传**，
            // 于是内层 `SizedBox(width: w, height: h)` 被 `BoxConstraints.enforce`
            // **压成 `w*scale x h*scale`**（960x540 → 243x137），
            // 然后 `Transform.scale(scale)` **又把它缩一次** ⇒ 内容只占 `w*scale^2`
            // （960*0.253^2 = 61.5 dp，与实测 62 dp 吻合）。
            //
            // 即：**内容被缩放两次**。`Transform.scale` 只影响绘制、不影响布局，
            // 所以外层布局尺寸（243x137）一直是对的 —— 这也正是它躲过离线用例的原因：
            // 既有的 `office_slides_fit_regression_test` 只量了外层 `SizedBox` 的尺寸。
            //
            // 修法：用 `OverflowBox` 给内层**无界**约束，让幻灯片在自己的
            // 960x540 坐标系里正常布局，再由 `Transform.scale` 缩放、外层 `ClipRect` 裁剪。
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  // 测试可观测点：**幻灯片自己的坐标系**，必须始终等于 `deck` 的
                  // 原始尺寸（通常 960x540），**不是**缩放后的外层尺寸。
                  // 真机那个「内容被缩放两次」的缺陷，就是靠这条断言才能抓住。
                  key: Key(
                    compact
                        ? 'office-slides-thumb-frame-$slide'
                        : 'office-slides-frame-$slide',
                  ),
                  width: w,
                  height: h,
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Positioned.fill(
                        child: ColoredBox(color: Color(s.backgroundArgb)),
                      ),
                      for (var i = 0; i < s.shapes.length; i++)
                        _positioned(context, s.shapes[i], i, scale),
                      if (!compact && _blankAfterRender(s))
                        Positioned.fill(
                          child: Center(
                            child: _DegradeCard(
                              key: Key('office-slides-blank-$slide'),
                              text: _t(
                                'officeSlidesDeckBlank',
                                '这张幻灯片没有可显示的内容',
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 只有"确实什么都没画出来"时才给整页空态。
  ///
  /// ⚠️ **必须与 [_picture] 的判定保持一致**：SVG 现在由自研渲染器绘制，
  /// 只有"解析出图形"才算画得出来；若不在这里同步，一个**只含 SVG** 的页面
  /// 会被错误地判成"没有可显示的内容"，从而**在 SVG 已经画出来的同时叠一张空态卡**。
  bool _blankAfterRender(OSlidesDeckSlide s) {
    for (final shape in s.shapes) {
      if (shape.width <= 0 || shape.height <= 0) continue;
      switch (shape.kind) {
        case OSlidesShapeKind.picture:
          if (_pictureIsRenderable(shape)) return false;
        case OSlidesShapeKind.unsupported:
          return false;
        default:
          if (shape.hasText ||
              shape.fillArgb != null ||
              shape.lineArgb != null) {
            return false;
          }
      }
    }
    return true;
  }

  /// 图片形状是否真的画得出来 —— 与 [_picture] 走**同一条判定**。
  bool _pictureIsRenderable(OSlidesDeckShape shape) {
    final bytes = deck.media[shape.imagePart];
    if (bytes == null) return false;
    if (isSvgMediaPart(shape.imagePart)) {
      return !officeSvgDocumentFor(bytes).isEmpty;
    }
    // 其余矢量格式（svgz / emf / wmf）本批仍不渲染。
    return !shape.isVectorImage;
  }

  Widget _positioned(
    BuildContext context,
    OSlidesDeckShape shape,
    int z,
    double canvasScale,
  ) {
    final left = shape.left;
    final top = shape.top;
    final width = shape.width <= 0 ? 1.0 : shape.width;
    final height = shape.height <= 0 ? 1.0 : shape.height;
    // ⚠️ **缩略图必须走与主画布完全相同的渲染路径**（真机缺陷修复，2026-09-22）。
    //
    // 缺陷现象：缩略图是**一整块纯色**，看不出幻灯片内容，用户直接反馈
    // 「缩略图不太对啊，好像没有正确生成」。
    //
    // 根因：旧实现对 `compact` 走 `_compactShape`，而它只画"有填充色的形状"：
    // ```dart
    // final fill = shape.fillArgb;
    // if (fill == null) return const SizedBox.shrink();   // ← 图片/文字直接被丢掉
    // ```
    // ⇒ 图片、文本框没有 `fillArgb`，于是**全部消失**，缩略图只剩背景色。
    //
    // 当初这么写是为了省内存（样本里有 5612x3742 / 84MB 的图）。
    // **但那个理由现在已经不成立了**：
    //   1. `_picture` 会按 `canvasScale` 夹取 `cacheWidth/cacheHeight`，
    //      缩略图 scale ≈ 0.1 ⇒ 只解码约 30px 宽，开销可以忽略；
    //   2. `normAutofit`（`FittedBox scaleDown`）保证文字在 54dp 高的缩略图里
    //      等比缩小而不是溢出。
    //
    // ⇒ **同一条渲染路径**：缩略图 = 主画布缩小版，这才是用户对"缩略图"的预期。
    // `compact` 现在只用来**跳过整页空态卡片**（在 96px 宽的缩略图里那只是噪声）。
    var child = _shapeContent(context, shape, canvasScale, z);
    if (shape.rotationDegrees.abs() > 0.01) {
      child = Transform.rotate(
        angle: shape.rotationDegrees * 3.1415926535897932 / 180,
        child: child,
      );
    }
    return Positioned(
      key: Key(
        compact
            ? 'office-slides-thumb-shape-$slide-$z'
            : 'office-slides-shape-$slide-$z',
      ),
      left: left,
      top: top,
      width: width,
      height: height,
      child: ClipRect(child: child),
    );
  }

  Widget _shapeContent(
    BuildContext context,
    OSlidesDeckShape shape,
    double canvasScale,
    int z,
  ) {
    switch (shape.kind) {
      case OSlidesShapeKind.picture:
        return _picture(context, shape, canvasScale, z);
      case OSlidesShapeKind.unsupported:
        return _DegradeCard(
          key: Key(
            'office-slides-unsupported-$slide-${shape.unsupportedLabel}',
          ),
          text: _t('officeSlidesDeckUnsupported', '这张幻灯片包含暂不支持的对象'),
          detail: shape.unsupportedLabel,
        );
      case OSlidesShapeKind.line:
        return CustomPaint(
          painter: _LinePainter(
            color: Color(shape.lineArgb ?? shape.fillArgb ?? 0xFF808080),
            width: shape.lineWidthPx <= 0 ? 1 : shape.lineWidthPx,
          ),
          child: const SizedBox.expand(),
        );
      case OSlidesShapeKind.text:
        return shape.hasText ? _text(context, shape) : const SizedBox.shrink();
      case OSlidesShapeKind.rectangle:
      case OSlidesShapeKind.roundRect:
      case OSlidesShapeKind.ellipse:
      case OSlidesShapeKind.triangle:
        return _autoshape(context, shape);
    }
  }

  Widget _picture(
    BuildContext context,
    OSlidesDeckShape shape,
    double canvasScale,
    int z,
  ) {
    final bytes = deck.media[shape.imagePart];
    // ⭐ **自研 SVG 渲染**（本批新增）：`ppt/media/*.svg` 不再"有意不画"。
    //
    // WPS / Microsoft Office 安卓版会把 `.oslides` 里继承自版式的 SVG 图标画出来
    // （真样本 `Technology.oslides` slide1 的 `img_dot_dark.svg`），
    // 我们之前直接 `SizedBox.shrink()` ⇒ 真机上肉眼可见的差距。
    //
    // 这里用 [OfficeSvgDocument] 解析、[OfficeSvgView] 绘制：
    //   * 解析出至少一个可绘制图形 → 用自研画笔绘制；
    //   * 解析失败 / 空 SVG / 只有不支持的标签 → **退回不画**（下面的分支），
    //     绝不抛异常、绝不假装画了。
    if (bytes != null && isSvgMediaPart(shape.imagePart)) {
      final document = officeSvgDocumentFor(bytes);
      if (!document.isEmpty) {
        // 测试可观测点：这个 key 只有在**自研 SVG 真的画出来**时才存在。
        return OfficeSvgView(
          key: Key(
            compact
                ? 'office-slides-thumb-svg-$slide-$z'
                : 'office-slides-svg-$slide-$z',
          ),
          document: document,
        );
      }
      return const SizedBox.shrink();
    }
    if (shape.isVectorImage || bytes == null) {
      // 不支持的矢量格式（svgz / emf / wmf）/ 缺字节：不画、不猜；
      // 整页因此变空时由 [_blankAfterRender] 出空态。
      return const SizedBox.shrink();
    }
    // ⚠️ **必须按实际显示尺寸解码**（真机缺陷根因，2026-09-22）。
    //
    // 实测（`Dynamic.oslides`，9,003,452 B，真 pptx）：
    //   image1.png   8 KB  1917x14      → 0.1 MB
    //   image5.jpg  24 KB   397x397     → 0.6 MB
    //   image2.jpg  75 KB  1440x810     → 4.7 MB
    //   image6.jpg 8.9 MB  5612x3742    → **84 MB**（ARGB8888）
    //
    // 不设 `cacheWidth`/`cacheHeight` 时 `Image.memory` 按**原始分辨率**解码：
    //   * 5612 超过常见 Android GPU 的**最大纹理边长 4096**；
    //   * 单张 84 MB 就能塞满 Flutter 默认 **100 MB** 的图片缓存；
    //   * 15 页连续翻页时缓存被反复冲垮。
    // 而幻灯片逻辑画布只有 960x540，真机上整页实际只占约 **744 物理 px**
    // ⇒ 按原始分辨率解码是纯浪费，且会失败。
    //
    // 这里按 `形状逻辑尺寸 x canvasScale x devicePixelRatio` 取实际需要的像素，
    // 并**硬性夹在 1..2048**：2048 是安全上限（远低于 4096），
    // 又足够覆盖任何手机的幻灯片显示尺寸。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final needW = (shape.width * canvasScale * dpr).ceil();
    final needH = (shape.height * canvasScale * dpr).ceil();
    final cacheW = needW.clamp(1, 2048);
    final cacheH = needH.clamp(1, 2048);
    return Image.memory(
      bytes,
      fit: BoxFit.fill,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      cacheWidth: cacheW,
      cacheHeight: cacheH,
      errorBuilder: (context, error, stack) =>
          _DegradeCard(text: _t('officeSlidesDeckImageFailed', '这张图片没能显示')),
    );
  }

  Widget _autoshape(BuildContext context, OSlidesDeckShape shape) {
    final fill = shape.fillArgb;
    final line = shape.lineArgb;
    final isEllipse = shape.kind == OSlidesShapeKind.ellipse;
    final radius = isEllipse
        ? 999.0
        : (shape.kind == OSlidesShapeKind.roundRect ? 12.0 : 0.0);
    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: fill == null ? null : Color(fill),
        borderRadius: BorderRadius.circular(radius),
        border: line == null
            ? null
            : Border.all(
                color: Color(line),
                width: shape.lineWidthPx <= 0 ? 1 : shape.lineWidthPx,
              ),
      ),
      child: const SizedBox.expand(),
    );
    if (shape.kind == OSlidesShapeKind.triangle) {
      box = CustomPaint(
        painter: _TrianglePainter(
          fill: fill == null ? null : Color(fill),
          stroke: line == null ? null : Color(line),
          strokeWidth: shape.lineWidthPx,
        ),
        child: const SizedBox.expand(),
      );
    }
    if (!shape.hasText) return box;
    return Stack(fit: StackFit.expand, children: [box, _text(context, shape)]);
  }

  /// 文本框：内边距 + 垂直对齐（`bodyPr@anchor`）+ 逐段渲染（run 级样式、
  /// 项目符号、行距）。
  ///
  /// 文本高度**有意不受形状高度限制**（`OverflowBox` 解除高度约束 + `ClipRect`
  /// 裁掉溢出）：PPTX 的文字本来就可能溢出形状（PowerPoint 用 normAutofit 缩排，
  /// 我们没有字体度量时不该假装能算准），但**绝不能**因此抛出 Flex overflow
  /// 把整页画布变成红黑条纹。
  Widget _text(BuildContext context, OSlidesDeckShape shape) {
    final paragraphs = <Widget>[
      for (var i = 0; i < shape.paragraphs.length; i++)
        _paragraph(context, shape, shape.paragraphs[i], i),
    ];
    // 内容宽度 = 形状宽度减去左右内边距。**必须给确定宽度**：
    // `FittedBox` 需要子项有内在尺寸才能测量，`double.infinity` 会让它量不出来。
    final contentWidth = (shape.width - shape.insetLeftPx - shape.insetRightPx)
        .clamp(1.0, double.infinity);
    final inner = SizedBox(
      width: contentWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: paragraphs,
      ),
    );
    // ⚠️ **`normAutofit` 近似：文字过高时等比缩小，而不是裁掉**（真机缺陷修复，2026-09-22）。
    //
    // 缺陷现象：`Technology.oslides` 首页的标题占位符有**两个 64pt 段落**
    //（`Social Media` + `Strategy`），而形状框只有 `T=220 H=120`、`anchor=b`。
    // 64pt ≈ 85px 行高 ⇒ 两行 170px > 框高 120px。
    //
    // 旧实现用 `ClipRect + OverflowBox` + 底对齐 ⇒ 内容**从顶部溢出后被裁掉**，
    // 真机上只看得见 `Strategy`，`Social Media` **整行消失**。
    // 旧注释的理由是「PowerPoint 用 normAutofit 缩排，我们没有字体度量时不该假装算准」
    // —— 但**裁掉一整行文字**显然比「缩得不够精确」更糟。
    //
    // `FittedBox(fit: scaleDown)` 是忠实的近似：
    //   * **只缩不放**（`scaleDown`）⇒ 放得下时行为与原来完全一致，不会突然放大；
    //   * 子项宽度已固定为形状内容宽 ⇒ 正常情况下不需要横向缩放；
    //   * 高度超出时整体等比缩小 ⇒ **文字全部可见**，这正是 PowerPoint/WPS 的表现。
    //
    // 本页实例：scale = 120/170 = 0.706 ⇒ 64pt 实际显示约 45pt，两行都看得见。
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: _alignFor(shape.anchor),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          shape.insetLeftPx,
          shape.insetTopPx,
          shape.insetRightPx,
          shape.insetBottomPx,
        ),
        child: inner,
      ),
    );
  }

  Alignment _alignFor(String? anchor) {
    switch (anchor) {
      case 'ctr':
        return Alignment.centerLeft;
      case 'b':
        return Alignment.bottomLeft;
      default:
        return Alignment.topLeft;
    }
  }

  Widget _paragraph(
    BuildContext context,
    OSlidesDeckShape shape,
    OSlidesDeckParagraph p,
    int index,
  ) {
    final spans = <TextSpan>[];
    if (p.bullet != null) {
      spans.add(
        TextSpan(
          text: '${p.bullet}  ',
          style: _runStyle(context, shape, p, null),
        ),
      );
    }
    for (final run in p.runs) {
      spans.add(
        TextSpan(text: run.text, style: _runStyle(context, shape, p, run)),
      );
    }
    if (spans.isEmpty) {
      spans.add(TextSpan(text: '', style: _runStyle(context, shape, p, null)));
    }
    final body = Text.rich(
      TextSpan(children: spans),
      key: Key('office-slides-text-$slide-${shape.id}-$index'),
      textAlign: _textAlign(p.align),
      softWrap: shape.wrap,
    );
    final inset = p.leftInsetPx;
    final spacingBefore = p.spaceBeforePt == null
        ? 0.0
        : pptxPtToPx(p.spaceBeforePt!);
    final spacingAfter = p.spaceAfterPt == null
        ? 0.0
        : pptxPtToPx(p.spaceAfterPt!);
    if (inset <= 0 && spacingBefore == 0 && spacingAfter == 0) return body;
    return Padding(
      padding: EdgeInsets.only(
        left: inset > 0 ? inset : 0,
        top: spacingBefore,
        bottom: spacingAfter,
      ),
      child: body,
    );
  }

  TextStyle _runStyle(
    BuildContext context,
    OSlidesDeckShape shape,
    OSlidesDeckParagraph p,
    OSlidesDeckRun? run,
  ) {
    final fallback = Theme.of(context).textTheme.bodyMedium;
    final size = run?.sizePt == null ? 18.0 : run!.sizePt!;
    return (fallback ?? const TextStyle()).copyWith(
      fontSize: pptxPtToPx(size),
      fontWeight: (run?.bold ?? false) ? FontWeight.w700 : FontWeight.w400,
      fontStyle: (run?.italic ?? false) ? FontStyle.italic : FontStyle.normal,
      color: run?.colorArgb == null
          ? _defaultTextColor(shape)
          : Color(run!.colorArgb!),
      fontFamily: run?.fontFamily,
      height: p.lineSpacingPct == null ? null : p.lineSpacingPct! / 100,
      decoration: (run?.underline ?? false)
          ? TextDecoration.underline
          : ((run?.strike ?? false) ? TextDecoration.lineThrough : null),
    );
  }

  Color _defaultTextColor(OSlidesDeckShape shape) {
    // 没声明颜色时：深色底用白字，浅色底用黑字（与母版 lt1/dk1 的默认一致）。
    final bg = Color(_slide.backgroundArgb);
    final lum = bg.computeLuminance();
    return lum < 0.5 ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  }

  TextAlign _textAlign(String? algn) {
    switch (algn) {
      case 'ctr':
        return TextAlign.center;
      case 'r':
        return TextAlign.right;
      case 'just':
        return TextAlign.justify;
      default:
        return TextAlign.left;
    }
  }
}

// ---------------------------------------------------------------- 全屏放映

/// 全屏放映：黑底、双指缩放、左右滑动翻页、**点按翻页 + 自动隐藏工具条**、页码与备注。
///
/// 放映模式对齐官方放映器的三条形态（这是用户对"放映观感"的预期）：
///   1. **工具栏不常驻** —— 3 秒无操作自动隐藏，把整屏留给幻灯片；
///   2. **点按翻页** —— 点画面右侧/中间翻到下一页，最左侧 20% 翻上一页；
///      **最后一页再点一次即退出**（这就是官方放映器的收尾方式）；
///   3. **顶部 12% 区域点按 = 呼出/收起工具栏** —— 让"隐藏工具栏"不会把用户困住
///      （工具栏里有退出、备注、上下页与页码）。
class OfficeSlidesFullscreenView extends StatefulWidget {
  const OfficeSlidesFullscreenView({
    super.key,
    required this.deck,
    this.initialIndex = 0,
  });

  final OSlidesDeck deck;
  final int initialIndex;

  /// 工具条**自动隐藏延时**。
  ///
  /// 放在公开 widget 上（而不是私有 State 里）是为了让用例
  /// （`test/office_slides_fullscreen_chrome_test.dart`）**跟随常量**，
  /// 不在用例里硬写 `3` 秒。
  static const Duration chromeAutoHide = Duration(seconds: 3);

  @override
  State<OfficeSlidesFullscreenView> createState() =>
      _OfficeSlidesFullscreenViewState();
}

class _OfficeSlidesFullscreenViewState
    extends State<OfficeSlidesFullscreenView> {
  late final PageController _controller;
  late int _index;
  bool _showNotes = false;

  /// 工具条是否可见。默认可见，[OfficeSlidesFullscreenView.chromeAutoHide]
  /// 之后自动隐藏。
  bool _showChrome = true;
  Timer? _hideTimer;

  static const Duration chromeAutoHide =
      OfficeSlidesFullscreenView.chromeAutoHide;

  /// 点按判定：位移超过这个距离就不算"点按"（是拖动/捏合）。
  static const double _tapSlop = 12;

  Offset? _downPosition;
  Duration? _downAt;

  int get _lastIndex =>
      widget.deck.slides.isEmpty ? 0 : widget.deck.slides.length - 1;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, _lastIndex);
    _controller = PageController(initialPage: _index);
    _scheduleChromeHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleChromeHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(chromeAutoHide, () {
      if (!mounted || !_showChrome) return;
      setState(() => _showChrome = false);
    });
  }

  void _toggleChrome() {
    setState(() => _showChrome = !_showChrome);
    if (_showChrome) _scheduleChromeHide();
  }

  /// 翻到下一页；已经是最后一页 ⇒ **退出放映**。
  void _advance() {
    if (_index >= _lastIndex) {
      Navigator.of(context).maybePop();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _retreat() {
    if (_index <= 0) return;
    _controller.previousPage(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  // ⚠️ 用 `Listener`（原始指针事件）而不是 `GestureDetector`：
  // 页面里已经有 `InteractiveViewer` 的 scale 识别器与 `PageView` 的横向拖动
  // 识别器，再加一个 tap 识别器要跟它们抢手势竞技场；`Listener` **不参与**
  // 竞技场，永远收得到事件，判定完全由我们的"位移 + 时长"阈值决定。
  void _onPointerDown(PointerDownEvent event) {
    _downPosition = event.position;
    _downAt = event.timeStamp;
  }

  /// 点按分区（**这是放映态的交互契约，改了要同步改用例**）：
  ///
  /// | 状态 | 点按位置 | 行为 |
  /// |---|---|---|
  /// | **工具条隐藏** | **任意位置** | **唤回工具条（不翻页）** ← ★ 用户报的 bug 的修法 |
  /// | 工具条可见 | 顶部 12% | 隐藏工具条 |
  /// | 工具条可见 | 左侧 20% | 上一页 |
  /// | 工具条可见 | 其余 | 下一页 |
  ///
  /// ## ★ 为什么"隐藏时任意点按都唤回"（用户原话）
  /// > "oslides 全屏之后工具条 3 秒隐藏之后再没有机会显示了，这个分析排查修复下"
  ///
  /// 真机实测（`LGE-AN10`，全屏视口 1148×2492）：
  /// * 12% 热区 = **299px**，其中顶部约 110px 是状态栏 ⇒ **实际可点区仅约 190px**，
  ///   而且完全落在幻灯片（y≈1000–1650）**之外**的黑区；
  /// * 点 y=200 ⇒ 工具条**确实**回来了（**功能本身没坏**）；
  /// * 点 y=1400（中部，用户的本能位置）⇒ **翻到第 2 页，工具条仍然隐藏**。
  ///
  /// ⇒ 旧实现的缺陷**不是命中测试**（我一开始怀疑
  /// `HitTestBehavior.deferToChild` 吞掉事件，**被自己的实验推翻了**），
  /// 而是**可达性**：唤回工具条的唯一手势是顶部一条窄带，
  /// 而用户在其它任何位置点按只会**翻页**，于是感知为"再也没机会显示"。
  ///
  /// 修法沿用媒体播放器/放映器的通用契约：**工具条藏着的时候，
  /// 第一次点按永远先把它叫回来**（此时不翻页，避免"点一下既翻页又看不到工具条"）。
  /// 翻页仍然随时可用：左右滑动、或工具条上的 ◀ ▶ 。
  void _onPointerUp(PointerUpEvent event) {
    final down = _downPosition;
    final at = _downAt;
    _downPosition = null;
    _downAt = null;
    if (down == null || at == null) return;
    if ((event.position - down).distance > _tapSlop) return; // 拖动 / 捏合
    if (event.timeStamp - at > const Duration(milliseconds: 400)) return;

    final size = MediaQuery.sizeOf(context);
    if (size.height <= 0 || size.width <= 0) return;

    // ★ 工具条隐藏 ⇒ **任意位置**点按都先唤回，且**不翻页**。
    if (!_showChrome) {
      _toggleChrome();
      return;
    }

    if (event.position.dy < size.height * 0.12) {
      _toggleChrome();
      return;
    }
    if (event.position.dx < size.width * 0.2) {
      _retreat();
    } else {
      _advance();
    }
  }

  @override
  Widget build(BuildContext context) {
    final slides = widget.deck.slides;
    if (slides.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            _t('officeSlidesDeckEmpty', '这份演示文稿里没有可显示的幻灯片'),
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    final index = _index.clamp(0, slides.length - 1);
    return Scaffold(
      key: const Key('office-slides-fullscreen-view'),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerUp: _onPointerUp,
                child: PageView.builder(
                  key: const Key('office-slides-fullscreen-pages'),
                  controller: _controller,
                  itemCount: slides.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => InteractiveViewer(
                    key: Key('office-slides-fullscreen-zoom-$i'),
                    minScale: 1,
                    maxScale: 8,
                    child: Center(
                      child: SlideCanvas(deck: widget.deck, slide: i),
                    ),
                  ),
                ),
              ),
            ),
            if (_showChrome) ...[
              if (_showNotes)
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 160),
                  color: Colors.white10,
                  padding: const EdgeInsets.all(Gap.md),
                  child: SingleChildScrollView(
                    child: Text(
                      slides[index].notes.trim().isEmpty
                          ? _t('officeSlidesDeckNoNotes', '这一页没有备注')
                          : slides[index].notes.trim(),
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              Row(
                key: const Key('office-slides-fullscreen-chrome'),
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    key: const Key('office-slides-fullscreen-prev'),
                    color: Colors.white,
                    onPressed: index > 0 ? _retreat : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    '${index + 1} / ${slides.length}',
                    key: const Key('office-slides-fullscreen-indicator'),
                    style: const TextStyle(color: Colors.white),
                  ),
                  IconButton(
                    key: const Key('office-slides-fullscreen-next'),
                    color: Colors.white,
                    onPressed: index < slides.length - 1 ? _advance : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                  const SizedBox(width: Gap.md),
                  IconButton(
                    key: const Key('office-slides-fullscreen-notes'),
                    color: Colors.white,
                    isSelected: _showNotes,
                    onPressed: () {
                      setState(() => _showNotes = !_showNotes);
                      _scheduleChromeHide();
                    },
                    icon: const Icon(Icons.sticky_note_2_outlined),
                    selectedIcon: const Icon(Icons.sticky_note_2),
                  ),
                  IconButton(
                    key: const Key('office-slides-fullscreen-close'),
                    color: Colors.white,
                    tooltip: _t('officeSlidesDeckExitFullscreen', '退出放映'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_fullscreen),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------- 小部件

class _DegradeCard extends StatelessWidget {
  const _DegradeCard({super.key, required this.text, this.detail});

  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xCCFFFFFF),
        border: Border.all(color: const Color(0x33000000)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline, size: 14),
              const SizedBox(width: 4),
              Flexible(child: Text(text)),
            ],
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(detail!, style: const TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  const _LinePainter({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset.zero, Offset(size.width, 0), paint);
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.color != color || old.width != width;
}

class _TrianglePainter extends CustomPainter {
  const _TrianglePainter({this.fill, this.stroke, this.strokeWidth = 0});

  final Color? fill;
  final Color? stroke;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    if (fill != null) {
      canvas.drawPath(path, Paint()..color = fill!);
    }
    if (stroke != null) {
      canvas.drawPath(
        path,
        Paint()
          ..color = stroke!
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth <= 0 ? 1 : strokeWidth,
      );
    }
  }

  @override
  bool shouldRepaint(_TrianglePainter old) =>
      old.fill != fill || old.stroke != stroke;
}

/// 缩略图/测试便利：把图片字节直接交给 `Image.memory`。
Uint8List? deckMediaBytes(OSlidesDeck deck, String? part) =>
    part == null ? null : deck.media[part];
