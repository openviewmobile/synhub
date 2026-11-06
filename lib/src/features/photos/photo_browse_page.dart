// 相册浏览页（P2 · SynologyPhotos）—— 时间轴 / 相册 / 文件夹 / 收藏 / 人物 / 场景
// 六段，外加「个人空间 ↔ 共享空间」切换。
//
// 设计口径：
//   * 空间切换就是**换 api 前缀**（`SYNO.Foto.` ↔ `SYNO.FotoTeam.`，见
//     `FotoApi.inSpace`），页面只需要换一个 provider，不写两套；
//   * 共享空间默认**不显示**：普通用户的 `team_space_permission` 是 `none`
//     （真机实测），硬显示只会让人点进去吃 801；
//   * 时间轴按 `timeline_group_unit`（day/month）分组，和官方一致；
//   * 缩略图 URL 自带 `_sid`，直接 `Image.network`（缓存交给 Flutter ImageCache）。
import '../../design/kit/design_kit.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/responsive_grid.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/section_pager.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/foto_api.dart';
import '../../dsm/webapi.dart';
import 'photo_backup_page.dart';
import 'photo_c2_page.dart';
import 'photo_c2_sections.dart';
import 'photo_c2_text.dart';
import 'photo_faces.dart';
import 'photo_format_support.dart';
import 'photo_grid_density.dart';
import 'photo_p0_text.dart';
import 'photo_p1_text.dart';
import 'photo_providers.dart';
import 'photo_tag_sheet.dart';
import 'photo_viewer_page.dart';
import 'photo_wave1_text.dart';
import 'photo_wave3_page.dart';
import 'photo_wave3_providers.dart';
import 'photo_wave3_text.dart';
import 'photo_widgets.dart';

/// 时间轴分组标题的**兜底高度**（第 263 轮）。
///
/// 只用于"第一段标题**是否已经整个滚出顶栏**"这一条判定：阈值取标题实测高度，
/// 量不到时才用 40（`Gap.md + Gap.xs + titleSmall` 的典型值）。它**不是**
/// 布局预算 —— 不参与任何高度计算，量得到就永远用实测值。
const double kPhotoTimelineHeaderFallbackHeight = 40;

/// 顶栏两枚时间刻度按钮的**最小点击区**（AGENTS §2.0.10：48dp 是最小点击区，
/// 不是"可以再挤一挤"）。视觉胶囊尺寸不变，只有 `PopupMenuButton` 的**可点盒**
/// 被撑到这个下限（`ConstrainedBox(minWidth/minHeight)` + `Center`）。
///
/// 这一条是**本轮顺带修的既有偏差**：改动前实测两枚胶囊只有 54.4×26 / 46.4×26，
/// 高度 26dp 远低于 48dp；它和"日期居中"无关，但同属顶栏工具条的可点性，
/// 一并收口。
const double kPhotoTimelineChipMinTap = 48;

/// 悬浮日期指示的内容：**分组标题 + 该分组的条目数**。
///
/// 计数与列表里每个分组标题**右端那个数字同源** —— 两处都取
/// [groupPhotos] 返回的 `(标题, 该组照片)` 里的 `$2.length`，不存在第二份计数。
typedef PhotoStickySection = ({String label, int count});

/// 悬浮日期指示的显示文案：`<分组标题> (<条目数>)`，例如 `9/21/2026 (4)`。
///
/// 括号与数字**不是需要翻译的用户可见文案**（中英同形：ASCII 圆括号 + 十进制
/// 数字），分组标题本身走既有本地化 ⇒ 本轮**不新增 ARB 条目**、无需
/// `flutter gen-l10n`。
@visibleForTesting
String photoStickySectionText(PhotoStickySection section) =>
    '${section.label} (${section.count})';

/// 单行文本在 [maxWidth] 里装不装得下（用同一套 `style` 与 `textScaler` 量）。
///
/// ★ r332 新增：悬浮日期"不许被省略"的唯一正解是**改文案/宽度**（AGENTS §2.0.18），
/// 所以这里先量、再决定显示 `<日期> (N)` 还是退成 `<日期>`。
bool _stickyFits(
  BuildContext context,
  String text,
  TextStyle? style,
  double maxWidth,
) {
  if (!maxWidth.isFinite || maxWidth <= 0) return false;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final ok = painter.width <= maxWidth;
  painter.dispose();
  return ok;
}

/// 一个待上传到时间轴的文件（`Upload.Item/upload` v8）。
class PhotoUploadPick {
  const PhotoUploadPick({
    required this.path,
    required this.name,
    required this.mtimeMs,
  });

  final String path;
  final String name;

  /// 毫秒；官方 form 里发的是**秒**（`_uploadItem` 会除 1000）
  final int mtimeMs;
}

/// 选文件（真机走 `file_picker`）。
///
/// 抽成 provider 是为了**离线可测**：widget 测试注入一个假实现，
/// 不弹系统选择器、也不碰真实文件系统。
final photoUploadPickerProvider = Provider<Future<List<PhotoUploadPick>>>((
  ref,
) async {
  // file_picker 13 是静态 API（`FilePicker.platform` 已移除），多选走 `pickFiles`。
  final files = await FilePicker.pickFiles();
  if (files.isEmpty) return const <PhotoUploadPick>[];
  final mtime = DateTime.now().millisecondsSinceEpoch;
  return <PhotoUploadPick>[
    for (final f in files)
      if ((f.path ?? '').isNotEmpty)
        PhotoUploadPick(path: f.path!, name: f.name, mtimeMs: mtime),
  ];
});

/// 选文件 → 逐个 `Upload.Item/upload`（`uploadDestination:"timeline"`）→ 汇总提示。
///
/// **不并发**：官方前端也是一张张传（并发上传在 NAS 上更容易触发 429/超时），
/// 而且顺序提示对用户更有意义。
Future<void> uploadPickedToTimeline(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.t;
  final api = ref.read(fotoSpaceApiProvider);
  if (api == null) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.setNotConnected)));
    return;
  }
  List<PhotoUploadPick> picks;
  try {
    picks = await ref.read(photoUploadPickerProvider);
  } catch (_) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(photoP1(PhotoP1TextKeys.uploadPickFailed, '选择文件失败')),
      ),
    );
    return;
  }
  if (picks.isEmpty) return;
  var ok = 0;
  var failed = 0;
  for (final pick in picks) {
    try {
      await api.uploadToTimeline(
        filePath: pick.path,
        fileName: pick.name,
        mtimeMs: pick.mtimeMs,
      );
      ok++;
    } catch (_) {
      failed++;
    }
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        failed == 0
            ? photoP1Fill(PhotoP1TextKeys.uploadDone, '已上传 {count} 项', {
                'count': '$ok',
              })
            : photoP1Fill(
                PhotoP1TextKeys.uploadFailed,
                '成功 {ok} 项，失败 {failed} 项',
                {'ok': '$ok', 'failed': '$failed'},
              ),
      ),
    ),
  );
  ref.invalidate(photoTimelineProvider);
}

/// 相册的六段视图
///
/// 「人物」「场景」是 P2 阶段二 C 最后一块：**只读**浏览（列表 → 该人物/场景的
/// 照片网格 → 大图）。人脸合并/命名、场景自定义都**不做**（管理员/高风险写操作）。
enum PhotoSection {
  timeline,
  albums,
  folders,
  favorites,
  persons,
  concepts;

  /// 当前语言文案（枚举值**不带**文案字面量；界面统一读这里，
  /// 由 `AppText` 按当前语言解析）。
  String labelIn(AppText t) => switch (this) {
    PhotoSection.timeline => t.photoSectionTimeline,
    PhotoSection.albums => t.navPhotos,
    PhotoSection.folders => t.photoSectionFolders,
    PhotoSection.favorites => t.photoSectionFavorites,
    PhotoSection.persons => t.photoSectionPersons,
    PhotoSection.concepts => t.photoSectionConcepts,
  };
}

/// 当前选中的段（进页面时保持住，切走再回来不跳）
final photoSectionProvider =
    NotifierProvider<PhotoSectionNotifier, PhotoSection>(
      PhotoSectionNotifier.new,
    );

class PhotoSectionNotifier extends Notifier<PhotoSection> {
  @override
  PhotoSection build() => PhotoSection.timeline;

  void select(PhotoSection s) => state = s;
}

/// 分页容器按 index 取视图（顺序 = [PhotoSection] 的顺序）
const List<Widget> _views = [
  _TimelineView(),
  _AlbumsView(),
  _FoldersView(),
  _FavoritesView(),
  _PersonsView(),
  _ConceptsView(),
];

class PhotoBrowsePage extends ConsumerStatefulWidget {
  const PhotoBrowsePage({super.key});

  @override
  ConsumerState<PhotoBrowsePage> createState() => _PhotoBrowsePageState();
}

class _PhotoBrowsePageState extends ConsumerState<PhotoBrowsePage> {
  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final section = ref.watch(photoSectionProvider);
    final space = ref.watch(fotoSpaceProvider);
    final setting = ref.watch(fotoSettingProvider);
    // 共享空间权限：除了 `team_space_permission`，官方还看 `team_space_share_only`；
    // 普通用户真机就是 `none` → 一个都不要显示。
    final canTeam = (setting.value?.teamSpacePermission ?? 'none') != 'none';
    final api = ref.watch(fotoSpaceApiProvider);

    ref.listen(fotoSpaceProvider, (prev, next) {
      if (prev != next) _invalidateAll(ref);
    });

    return Scaffold(
      backgroundColor: hud.bg,
      // 「新建相册」只在相册段出现、「新建文件夹」只在文件夹段出现；
      // 个人空间一定有建相册/建目录的权限，共享空间按服务端报错提示。
      floatingActionButton: api == null
          ? null
          : switch (section) {
              // 时间轴上传统：选文件 → `Upload.Item/upload`（destination=timeline）
              PhotoSection.timeline => FloatingActionButton.extended(
                key: const Key('photo-upload-timeline'),
                // ★ r497：相册 FAB 统一成设计语言的主色 + onPrimary
                //   （原来是"surface 底 + 默认前景"，在深色下是一块灰白药丸，
                //   与 Files 的主色 `+` 不是同一套）。
                backgroundColor: hud.primary,
                foregroundColor: hud.onPrimary,
                icon: const Icon(Icons.upload_outlined),
                label: Text(
                  photoP1(PhotoP1TextKeys.uploadToTimeline, '上传到时间轴'),
                ),
                onPressed: () => uploadPickedToTimeline(context, ref),
              ),
              PhotoSection.albums => FloatingActionButton.extended(
                key: const Key('photo-album-create'),
                // ★ r497：相册 FAB 统一成设计语言的主色 + onPrimary
                //   （原来是"surface 底 + 默认前景"，在深色下是一块灰白药丸，
                //   与 Files 的主色 `+` 不是同一套）。
                backgroundColor: hud.primary,
                foregroundColor: hud.onPrimary,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(context.t.photoNewAlbum),
                onPressed: () => showCreateAlbumDialog(context, ref),
              ),
              PhotoSection.folders => FloatingActionButton.extended(
                key: const Key('photo-folder-create'),
                // ★ r497：相册 FAB 统一成设计语言的主色 + onPrimary
                //   （原来是"surface 底 + 默认前景"，在深色下是一块灰白药丸，
                //   与 Files 的主色 `+` 不是同一套）。
                backgroundColor: hud.primary,
                foregroundColor: hud.onPrimary,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(context.t.photoCreateFolder),
                onPressed: () =>
                    showCreateFolderDialog(context, ref, parentId: '0'),
              ),
              _ => null,
            },
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              section: section,
              onSection: (s) {
                // 点 chip 和左右滑都要记（以前只有滑才记）
                track(
                  ref,
                  UsageModule.photos,
                  UsageAction.switchSection,
                  objectType: s.name,
                );
                // 进时间轴板块 = 切到"时间轴"视图（每次切换记一次，不在滚动帧里记）
                if (s == PhotoSection.timeline) {
                  trackViewMode(UsageModule.photos, 'timeline');
                }
                ref.read(photoSectionProvider.notifier).select(s);
              },
              space: space,
              canTeam: canTeam,
              onSpace: (s) {
                ref.read(fotoSpaceProvider.notifier).set(s);
                _invalidateAll(ref);
              },
              onRefresh: () => _invalidateAll(ref),
              onBackup: () =>
                  Navigator.of(context, rootNavigator: true).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const PhotoBackupPage(),
                    ),
                  ),
              // C2：共享 / 地点 / 搜索 / 条件相册 / 相似照片的入口（hub）
              onMore: () =>
                  Navigator.of(context, rootNavigator: true).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const PhotoC2Page(),
                    ),
                  ),
            ),
            // 四段之间**左右滑动**切换（分段控件与手势共用同一个 provider）
            Expanded(
              child: SectionPager(
                pagerKey: const Key('photo-section-pager'),
                index: section.index,
                itemCount: PhotoSection.values.length,
                onIndex: (i) {
                  final next = PhotoSection.values[i];
                  track(
                    ref,
                    UsageModule.photos,
                    UsageAction.switchSection,
                    objectType: next.name,
                  );
                  // 进时间轴板块 = 切到"时间轴"视图（每次切换记一次，不在滚动帧里记）
                  if (next == PhotoSection.timeline) {
                    trackViewMode(UsageModule.photos, 'timeline');
                  }
                  ref.read(photoSectionProvider.notifier).select(next);
                },
                itemBuilder: (context, i) => _views[i],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 顶部

class _Header extends StatelessWidget {
  const _Header({
    required this.section,
    required this.onSection,
    required this.space,
    required this.canTeam,
    required this.onSpace,
    required this.onRefresh,
    required this.onBackup,
    required this.onMore,
  });

  final PhotoSection section;
  final ValueChanged<PhotoSection> onSection;
  final FotoSpace space;
  final bool canTeam;
  final ValueChanged<FotoSpace> onSpace;
  final VoidCallback onRefresh;
  final VoidCallback onBackup;

  /// C2：共享 / 地点 / 搜索 / 条件相册 / 相似照片（hub 入口）
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t.navPhotos,
                      style: theme.textTheme.titleLarge,
                    ),
                    // ★ r496：页头副标题去 HUD 化。
                    //   原来是全大写 + 1.4 字距的"遥测字"（`SYNOLOGY PHOTOS · …`），
                    //   与设计语言的行卡/组头是两种语言。信息只保留**空间名**。
                    Text(
                      // 副标题只写产品名：空间名已经在右边的切换芯片上，
                      // 写两遍会让 `find.text('个人空间')` 变成歧义判据（r496 实测踩到）。
                      'Synology Photos',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: DesignType.bodySmallSize,
                        color: hud.muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (canTeam) _SpaceChip(space: space, onChanged: onSpace),
              IconButton(
                key: const Key('photo-c2-entry'),
                tooltip: photoC2(PhotoC2TextKeys.hubTitle, '更多相册功能'),
                icon: const Icon(Icons.more_horiz),
                onPressed: onMore,
              ),
              IconButton(
                key: const Key('photo-backup-entry'),
                tooltip: context.t.pbTitle,
                icon: const Icon(Icons.phone_android_outlined),
                onPressed: onBackup,
              ),
              IconButton(
                tooltip: context.t.photoRefresh,
                icon: const Icon(Icons.refresh),
                onPressed: onRefresh,
              ),
            ],
          ),
        ),
        PhotoSegment(
          labels: [for (final s in PhotoSection.values) s.labelIn(context.t)],
          index: section.index,
          onChanged: (i) => onSection(PhotoSection.values[i]),
        ),
      ],
    );
  }
}

/// 个人 / 共享空间切换（权限不足时整块不出现）
class _SpaceChip extends StatelessWidget {
  const _SpaceChip({required this.space, required this.onChanged});

  final FotoSpace space;
  final ValueChanged<FotoSpace> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<FotoSpace>(
      tooltip: context.t.photoSwitchSpace,
      initialValue: space,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final s in FotoSpace.values)
          PopupMenuItem(value: s, child: Text(s.labelText())),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(Radii.capsule),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.layers_outlined, size: 14),
            const SizedBox(width: 4),
            Text(
              space.labelText(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 时间轴

class _TimelineView extends ConsumerStatefulWidget {
  const _TimelineView();

  @override
  ConsumerState<_TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends ConsumerState<_TimelineView> {
  final PhotoSelectionController _selection = PhotoSelectionController();

  /// 用户在本页选的时间刻度（`day`/`month`/`year`）；null = 用服务端默认。
  String? _unitOverride;

  /// ★ 悬浮日期指示（第 263 轮）：时间轴上"视口顶边所在分组"的标题。
  ///
  /// `null` = 还没开始滚动（顶栏左侧仍显示「时间刻度」）；非 null = 用日期
  /// **替换**「时间刻度」四个字，起到"悬浮指示当前是哪一天"的效果。
  /// 由 [_TimelineSlivers] 按滚动位置实时上报（见
  /// [photoTopmostSectionIndex]）——顶栏是**固定**的，所以指示器永远可见，
  /// 而右侧两枚时间刻度按钮（密度 / 日-月-年）一个字都不动、照样可点。
  final ValueNotifier<PhotoStickySection?> _stickyLabel =
      ValueNotifier<PhotoStickySection?>(null);

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelection);
  }

  @override
  void dispose() {
    _stickyLabel.dispose();
    _selection.dispose();
    super.dispose();
  }

  void _onSelection() {
    if (mounted) setState(() {});
  }

  Future<void> _addToAlbum(List<FotoItemDto> items) async {
    final ids = [
      for (final item in items)
        if (_selection.contains(item.id)) item.id,
    ];
    await showAddToAlbumSheet(context, ref, itemIds: ids);
    if (mounted) _selection.clear();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(photoTimelineProvider);
    final serverUnit =
        ref.watch(fotoSettingProvider).value?.timelineGroupUnit ?? 'day';
    // 用户在本页选的视图单位（day/month/year）优先于服务端默认；官方
    // `bottom_sheet_timeline_viewmode` 也是"本地切换 + 服务端默认"。
    final unit = _unitOverride ?? serverUnit;
    return Column(
      children: [
        _TimelineViewModeBar(
          unit: unit,
          onUnit: (u) => setState(() => _unitOverride = u),
          stickyLabel: _stickyLabel,
        ),
        Expanded(
          child: PhotoAsync<PhotoTimelineState>(
            value: RiverpodAsync(async),
            emptyTitle: context.t.photoEmptyTimelineTitle,
            emptyMessage: context.t.photoEmptyTimelineMessage,
            isEmpty: (state) => state.items.isEmpty,
            onRetry: () => ref.invalidate(photoTimelineProvider),
            builder: (state) => Column(
              children: [
                if (_selection.active)
                  PhotoSelectionHeader(
                    count: _selection.count,
                    total: state.items.length,
                    onSelectAll: () =>
                        _selection.selectAll(state.items.map((e) => e.id)),
                    onClear: _selection.clear,
                  ),
                Expanded(
                  child: _TimelineSlivers(
                    state: state,
                    unit: unit,
                    selection: _selection,
                    onSection: (section) => _stickyLabel.value = section,
                  ),
                ),
                if (_selection.active)
                  PhotoSelectionBar(
                    items: [
                      for (final it in state.items)
                        if (_selection.contains(it.id)) it,
                    ],
                    space: ref.watch(fotoSpaceProvider),
                    onClear: _selection.clear,
                    onAddToAlbum: () => _addToAlbum(state.items),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 时间轴视图单位切换（官方 `str_day_view_mode` / `str_month_view_mode` /
/// `str_year_view_mode` + `layout/bottom_sheet_timeline_viewmode`）。
///
/// 只改**客户端分组**（日/月/年），不请求服务端 —— 与官方一致的轻交互。
/// 「年视图」让大库能按年速览，配合触底分页一次拉全部。
class _TimelineViewModeBar extends ConsumerWidget {
  const _TimelineViewModeBar({
    required this.unit,
    required this.onUnit,
    required this.stickyLabel,
  });

  /// `day` / `month` / `year`
  final String unit;
  final ValueChanged<String> onUnit;

  /// 悬浮日期指示：非 null 时**替换**左侧的「时间刻度」文案（含该组条目数）。
  final ValueListenable<PhotoStickySection?> stickyLabel;

  /// 密度档的界面名（P4，官方 `segment_view_mode` 的缩略图尺寸档）。
  String _densityLabel(int columns) => switch (columns) {
    2 => photoG1(PhotoG1TextKeys.gridDensityLarge, '大'),
    3 => photoG1(PhotoG1TextKeys.gridDensityMedium, '中'),
    4 => photoG1(PhotoG1TextKeys.gridDensitySmall, '小'),
    _ => photoG1(PhotoG1TextKeys.gridDensityTiny, '密'),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final columns = ref.watch(photoGridColumnsProvider);
    String label(String u) => switch (u) {
      'year' => photoWave1(PhotoWave1TextKeys.timelineViewYear, '年'),
      'month' => photoWave1(PhotoWave1TextKeys.timelineViewMonth, '月'),
      _ => photoWave1(PhotoWave1TextKeys.timelineViewDay, '日'),
    };
    return Padding(
      key: const Key('photo-timeline-view-bar'),
      // ★★★ r332：左槽的日期文案要**在真机 375dp 上不被截断**，所以把这一行的水平内边距
      // 从 16 收到 8（省 16dp）。量出来的证据（400dp 宽、真主题、titleSmall 14.5sp）：
      // 文案 `2026 年 9 月 20 日 (6)` 需要 **277.4dp**，而左槽只有 **273.1dp**
      // ⇒ 差 4.3dp 就开始打省略号（真机 375dp 差得更多）。
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, 0),
      child: Row(
        children: [
          // ★ 左槽 = 「时间刻度」↔「当前分组日期」的悬浮指示（第 263 轮）。
          //
          // 官方安卓端的做法是列表内的 sticky section header
          // （`com.synology.projectkailash.widget.fastscroll.StickyHeaderRecyclerView`
          // + `StickyHeaderAdapter.notifyStickyHeaderChange`，SPK/APK 字符串取证）。
          // 本仓这个「Time scale」行是**我们自己加的**、官方没有，删掉会丢掉
          // 密度/日-月-年两枚按钮，所以按用户要求把日期**顶进这一行的左槽**：
          // 行本身固定不动 ⇒ 指示器永远可见，右槽两枚按钮原位保留。
          //
          // 不截断靠的是"给足宽度 + 单行省略号"，**不用 FittedBox**
          // （AGENTS §2.0.18：FittedBox 会改自身高度、破坏下方预算不变量）。
          Expanded(
            // 稳定的定位锚点：测试用它量左槽的**文字左边缘**（居中 bug 的钉子）。
            key: const Key('photo-timeline-sticky-slot'),
            child: ValueListenableBuilder<PhotoStickySection?>(
              valueListenable: stickyLabel,
              builder: (context, sticky, _) {
                // 日期态 = `<分组标题> (<条目数>)`，计数与列表内分组标题右端
                // 那个数字同源（同一批 `groups`）。
                final text = sticky == null
                    ? photoWave1(PhotoWave1TextKeys.timelineViewMode, '时间刻度')
                    : photoStickySectionText(sticky);
                final label = sticky?.label ?? text;
                // 日期态用与分组标题同级的小标题字重（"是我在指示"），
                // 「时间刻度」保持低调的说明性小字。
                final style = sticky == null
                    ? Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: hud.dim)
                    : Theme.of(context).textTheme.titleSmall;
                // ★★★ r332：**按测量挑"最富、但装得下"的形态**，而不是写死一种再让它省略。
                // 背景：真主题下（titleSmall 14.5sp）`<日期> (N)` 需要 277.4dp，而真机 375dp
                // 的左槽只有约 268dp ⇒ 中文日期必然被省略成 `2026 年 9 月 20 …`。
                // 规矩（AGENTS §2.0.18）：截断只能靠**改文案/宽度**，不许缩字号 ⇒
                // 装不下 `(N)` 时退成"只有日期"（条目数在列表内的分组标题里本来就有）。
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final chosen =
                        _stickyFits(context, text, style, constraints.maxWidth)
                        ? text
                        : label;
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      // ★ 日期"看着居中"的根因就在这一行：`AnimatedSwitcher` 的
                      // **默认** `layoutBuilder` 是
                      // `Stack(alignment: Alignment.center, …)`。`Expanded` 给的是
                      // **紧宽度**，Stack 被撑满整个左槽，`center` 于是把短文本
                      // 摆到槽正中（实测「时间刻度」文字矩形 124.8→174.4，槽是
                      // 12→287.2，两者中心都是 149.6 —— 就是"居中"）。左槽要求
                      // 跟随 `Time scale` 的**左对齐**，所以只把水平对齐换成
                      // `centerLeft`：Stack 形状、淡入/上滑动画、高度都不变。
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [...previous, ?current],
                      ),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.55),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: Text(
                        chosen,
                        key: ValueKey<String>('photo-timeline-sticky:$chosen'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.left,
                        style: style,
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // P4 网格缩放/密度：官方是**本地分段控件**（`layout/segment_view_mode`
          // / `id/zoom` / `id/grid`），APK 里没有 pinch-to-zoom 字符串 →
          // 这里做同一件事：选一档列数，落盘、全相册网格共用。
          PopupMenuButton<int>(
            key: const Key('photo-grid-density'),
            tooltip: photoG1(PhotoG1TextKeys.gridDensity, '缩略图密度'),
            initialValue: columns,
            onSelected: (c) {
              ref.read(photoGridColumnsProvider.notifier).setColumns(c);
              // 时间轴是**网格**布局（没有 list 档），密度档 = 栅格布局偏好
              trackViewMode(UsageModule.photos, 'grid');
            },
            itemBuilder: (_) => [
              for (final c in kPhotoGridColumnChoices)
                PopupMenuItem(value: c, child: Text(_densityLabel(c))),
            ],
            child: _ChipTapTarget(
              child: Container(
                // ★ r332：同上（给左槽再让 4dp）。
                margin: const EdgeInsets.only(right: Gap.xs),
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.sm,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(Radii.capsule),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.grid_view_outlined, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      _densityLabel(columns),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            key: const Key('photo-timeline-view-mode'),
            tooltip: photoWave1(PhotoWave1TextKeys.timelineViewMode, '时间刻度'),
            initialValue: unit,
            onSelected: onUnit,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'day', child: Text(label('day'))),
              PopupMenuItem(value: 'month', child: Text(label('month'))),
              PopupMenuItem(value: 'year', child: Text(label('year'))),
            ],
            child: _ChipTapTarget(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.sm,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(Radii.capsule),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.timeline_outlined, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      label(unit),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 把一枚时间刻度胶囊包进 **≥48dp 的可点盒**（AGENTS §2.0.10）。
///
/// 只放宽 `PopupMenuButton`（内部 `InkWell`）的**布局盒**到 48dp；
/// 里面的胶囊视觉尺寸、圆角、间距一个像素都不动（`Center` 让它在盒中居中）。
class _ChipTapTarget extends StatelessWidget {
  const _ChipTapTarget({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(
      minWidth: kPhotoTimelineChipMinTap,
      minHeight: kPhotoTimelineChipMinTap,
    ),
    child: Center(child: child),
  );
}

/// 悬浮日期指示：算出**视口顶边正落在哪个分组**（第 263 轮）。
///
/// [starts] 是各分组标题的**滚动起点偏移**（`分组起点 - 0`，按分组顺序单调不减；
/// 还没测到的位置是 `null`）。返回**最后一个** `start <= offset + 0.5` 的下标；
/// `null` = 还没有任何分组起点可用（等价于"还没滚动/没有内容"）。
///
/// 为什么允许 `null` 洞：分组的标题 widget 只在视口缓存范围内才会被构建。
/// 深在一个很大分组内部时，它的标题早已滚出缓存、这一帧测不到，但它的起点
/// **在刚滚过时就已经记下**，所以结论仍然正确；调用方只在整体无数据时得到 null。
@visibleForTesting
int? photoTopmostSectionIndex(List<double?> starts, double offset) {
  int? best;
  for (var i = 0; i < starts.length; i++) {
    final s = starts[i];
    if (s == null) continue;
    if (s <= offset + 0.5) {
      best = i;
    } else {
      break;
    }
  }
  return best;
}

class _TimelineSlivers extends ConsumerStatefulWidget {
  const _TimelineSlivers({
    required this.state,
    required this.unit,
    required this.selection,
    required this.onSection,
  });

  final PhotoTimelineState state;
  final String unit;
  final PhotoSelectionController selection;

  /// 实时上报"顶边所在分组（标题 + 条目数）"；`null` = 还没滚动
  /// （顶栏显示「时间刻度」）。
  final ValueChanged<PhotoStickySection?> onSection;

  @override
  ConsumerState<_TimelineSlivers> createState() => _TimelineSliversState();
}

class _TimelineSliversState extends ConsumerState<_TimelineSlivers> {
  /// 悬浮日期指示的滚动位置来源（**只读**，不动滚动行为）。
  final ScrollController _controller = ScrollController();

  /// 每个分组标题的 `GlobalKey`（用于把标题的全局 Y 换算成滚动起点）。
  final List<GlobalKey> _headerKeys = [];

  /// 每个分组的**滚动起点**（`null` = 这一帧还没测到）。
  final List<double?> _starts = [];

  /// 首帧布局后再量一次（`ScrollNotification` 只在真的滚动时才来）。
  bool _measuredOnce = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 触底自动续取：距底部 < 600px 就触发（去重/防抖在 notifier 里）。
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n.metrics.extentAfter < 600) _loadMore();
    _updateSection();
    return false;
  }

  void _loadMore() {
    final s = ref.read(photoTimelineProvider).value;
    if (s == null || !s.hasMore || s.loadingMore) return;
    ref.read(photoTimelineProvider.notifier).loadMore();
  }

  /// 分组标题在**滚动坐标系**里的起点（= 顶边贴住视口上沿时的 `offset`）。
  ///
  /// ⚠️ 不要用 `offset + (标题全局 Y − 列表顶边全局 Y)` 去算：`ScrollNotification`
  /// 是在 **布局之前**派发的，那一刻"新的 offset"配的是"上一帧的标题位置"
  /// ⇒ 每次滚动都会把起点记成 `真值 ± 本帧位移`，并在后续帧之间**来回跳**
  /// （第 263 轮实测：同一组在 `0` 与 `20` 之间振荡，真值是 `12`）。
  /// `getOffsetToReveal` 由视口自己用**同一份布局**算，没有这个错位。
  double? _sectionStart(RenderBox box) {
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    return viewport.getOffsetToReveal(box, 0).offset;
  }

  /// 量出已构建标题的起点，并把"顶边所在分组"上报给顶栏。
  ///
  /// 只在**拿到真实 RenderBox** 时写入，绝不拿估算值冒充测量值。
  void _updateSection() {
    final groups = groupPhotos(
      widget.state.items,
      unit: widget.unit,
      l10n: context.t,
    );
    if (groups.isEmpty) {
      widget.onSection(null);
      return;
    }
    final offset = _controller.hasClients ? _controller.offset : 0.0;
    for (var i = 0; i < groups.length && i < _headerKeys.length; i++) {
      final box =
          _headerKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final start = _sectionStart(box);
      if (start != null) _starts[i] = start;
    }
    // 第一段标题**完全滚出顶边之前**仍显示「时间刻度」——那段时间里标题
    // 正在"滑上去顶替"这四个字，视觉上就是用户要的悬浮指示。
    final firstHeight =
        (_headerKeys.isNotEmpty
            ? (_headerKeys.first.currentContext?.findRenderObject()
                      as RenderBox?)
                  ?.size
                  .height
            : null) ??
        kPhotoTimelineHeaderFallbackHeight;
    if (offset <= firstHeight) {
      widget.onSection(null);
      return;
    }
    final idx = photoTopmostSectionIndex(_starts, offset);
    if (idx == null || idx < 0 || idx >= groups.length) {
      widget.onSection(null);
      return;
    }
    // ★ 条目数与列表内分组标题右端的数字**同源**：同一个 `groups[idx]`。
    widget.onSection((label: groups[idx].$1, count: groups[idx].$2.length));
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final items = widget.state.items;
    final groups = groupPhotos(items, unit: widget.unit, l10n: context.t);
    // 分组数变化（首屏/换单位/续取）时重建测量表，长度与分组一一对应。
    if (_headerKeys.length != groups.length) {
      _headerKeys
        ..clear()
        ..addAll(List<GlobalKey>.generate(groups.length, (_) => GlobalKey()));
      _starts
        ..clear()
        ..addAll(List<double?>.filled(groups.length, null));
      _measuredOnce = false;
    }
    if (!_measuredOnce) {
      _measuredOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateSection();
      });
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: CustomScrollView(
        controller: _controller,
        slivers: [
          for (var g = 0; g < groups.length; g++) ...[
            SliverToBoxAdapter(
              // ⚠️ `GlobalKey` 必须挂在**盒子**上，不能挂在 `SliverToBoxAdapter`
              // 本身 —— 后者的 render object 是 `RenderSliverToBoxAdapter`，
              // 不是 `RenderBox`（量位置会当场类型转换失败）。
              child: Padding(
                key: _headerKeys[g],
                padding: const EdgeInsets.fromLTRB(
                  Gap.md,
                  Gap.md,
                  Gap.md,
                  Gap.xs,
                ),
                // 时间轴分组标题：`Row` 里两个不可压缩的 `Text`，英文/大字号下
                // 横向溢出（2.0 缩放实测 130px）。标题给 `Expanded` + 省略号，
                // 计数保持自然宽度。
                child: Row(
                  key: Key('photo-timeline-section-$g'),
                  children: [
                    Expanded(
                      child: Text(
                        groups[g].$1,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: Gap.xs),
                    Text(
                      '${groups[g].$2.length}',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: hud.dim),
                    ),
                  ],
                ),
              ),
            ),
            PhotoGrid(
              items: groups[g].$2,
              space: ref.watch(fotoSpaceProvider),
              sliver: true,
              // P4：密度档由用户选（`photo-grid-density`），全相册共用
              columns: ref.watch(photoGridColumnsProvider),
              selecting: widget.selection.active,
              selectedIds: widget.selection.ids,
              onTap: (i) => widget.selection.active
                  ? widget.selection.toggle(groups[g].$2[i].id)
                  : _openViewer(context, items, items.indexOf(groups[g].$2[i])),
              onLongPress: (i) => widget.selection.enter(groups[g].$2[i].id),
            ),
          ],
          SliverToBoxAdapter(
            child: _TimelineFooter(state: widget.state, onLoadMore: _loadMore),
          ),
          // ★ r521（DA163，真机亮色像素）：时间轴最后一行缩略图被右下角那颗
          // 悬浮的「上传到时间轴」药丸压掉一半（`Gap.xl`=24 的尾巴根本不够）。
          // extended FAB 高 56 + 外边距 16 + 与内容留 32 ⇒ 尾巴给 104。
          const SliverToBoxAdapter(
            child: SizedBox(
              key: Key('photo-timeline-tail'),
              height: Gap.xl + 80,
            ),
          ),
        ],
      ),
    );
  }
}

/// 时间轴底部：加载更多 / 加载中 / 失败重试 / 已全部加载。
///
/// **不静默**：手动按钮与触底自动触发共用 [onLoadMore]；失败时保留已加载的
/// 全部照片，只在这里给"重试"。
class _TimelineFooter extends StatelessWidget {
  const _TimelineFooter({required this.state, required this.onLoadMore});

  final PhotoTimelineState state;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(Gap.md),
        child: Center(
          child: CircularProgressIndicator(
            key: Key('photo-timeline-loading-more'),
          ),
        ),
      );
    }
    final err = state.loadMoreError;
    if (err != null) {
      return Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          children: [
            Text(
              photoWave1Fill(
                PhotoWave1TextKeys.loadMoreFailed,
                '加载下一页失败：{error}',
                {'error': describePhotoError(err, context.t)},
              ),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton(
              key: const Key('photo-timeline-load-more-retry'),
              onPressed: onLoadMore,
              child: Text(context.t.photoRetry),
            ),
          ],
        ),
      );
    }
    if (state.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Center(
          child: TextButton(
            key: const Key('photo-timeline-load-more'),
            onPressed: onLoadMore,
            child: Text(photoWave1(PhotoWave1TextKeys.loadMore, '加载更多')),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Center(
        child: Text(
          photoWave1Fill(PhotoWave1TextKeys.allLoaded, '已全部加载（{count} 张）', {
            'count': '${state.items.length}',
          }),
          key: const Key('photo-timeline-all-loaded'),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
        ),
      ),
    );
  }
}

/// 页面里刷新（`refreshPhotos` 是给 `Ref` 用的，WidgetRef 需要自己 invalidate）
void _invalidateAll(WidgetRef ref) {
  ref.invalidate(photoTimelineProvider);
  ref.invalidate(photoAlbumsProvider);
  ref.invalidate(photoFoldersProvider);
  ref.invalidate(photoFavoritesProvider);
  ref.invalidate(photoPersonsProvider);
  ref.invalidate(photoConceptsProvider);
}

void _openViewer(BuildContext context, List<FotoItemDto> items, int index) {
  // 使用日志：只看"打开了相册大图"，不记内容/文件名（这个函数没有 ref，用全局单例）
  trackOnce(UsageModule.photos, UsageAction.preview);
  Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => PhotoViewerPage(items: items, index: index),
    ),
  );
}

// ---------------------------------------------------------------- 相册

class _AlbumsView extends ConsumerWidget {
  const _AlbumsView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(photoAlbumsProvider);
    // wave3：相册设置入口（缓存状态 / 列表显示偏好，只读）。能力位都缺 → 入口隐藏。
    final showSettings = ref.watch(photoWave3AlbumSettingsVisibleProvider);
    return Column(
      children: [
        Row(
          children: [
            const Expanded(child: _AlbumSortBar()),
            if (showSettings)
              IconButton(
                key: const Key('photo-album-settings'),
                tooltip: photoWave3(PhotoWave3TextKeys.albumSettings, '相册设置'),
                icon: const Icon(Icons.settings_outlined),
                onPressed: () =>
                    Navigator.of(context, rootNavigator: true).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const PhotoAlbumSettingsPage(),
                      ),
                    ),
              ),
          ],
        ),
        Expanded(
          child: PhotoAsync<List<FotoAlbumDto>>(
            value: RiverpodAsync(async),
            emptyTitle: context.t.photoEmptyAlbumsTitle,
            emptyMessage: context.t.photoEmptyAlbumsMessage,
            isEmpty: (items) => items.isEmpty,
            onRetry: () => ref.invalidate(photoAlbumsProvider),
            builder: (albums) => GridView.builder(
              padding: const EdgeInsets.all(Gap.md),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:
                    albumColumnsFor(MediaQuery.sizeOf(context).width),
                mainAxisSpacing: Gap.md,
                crossAxisSpacing: Gap.md,
                childAspectRatio: 0.86,
              ),
              itemCount: albums.length,
              itemBuilder: (context, i) {
                final a = albums[i];
                final space = ref.watch(fotoSpaceProvider);
                return PhotoAlbumTile(
                  title: a.name,
                  subtitle: [
                    if (a.itemCount > 0) context.t.photoItemCount(a.itemCount),
                    if (a.type != 'normal') context.t.photoConditionalAlbum,
                    if (a.shared) context.t.photoShared,
                  ].join(' · '),
                  iconFallback: a.type == 'normal'
                      ? Icons.photo_album_outlined
                      : Icons.auto_awesome_mosaic_outlined,
                  // 相册封面：服务端给的是 `cover.unit_id`（不是照片 item id）
                  coverRequest: photoCoverRequest(a.cover, space),
                  onTap: () =>
                      Navigator.of(context, rootNavigator: true).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => PhotoAlbumItemsPage(album: a),
                        ),
                      ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// 相册段的排序菜单（`Browse.Album/get|set_album_list_order` + `list` 的
/// `sort_by`/`sort_direction`）。
///
/// 证据：
///   * 服务端方法 `get_album_list_order`/`set_album_list_order`（v2+，
///     `api-server-authoritative:225`）；
///   * 请求/响应键 `album_list_sort_by`/`album_list_sort_direction`
///     （官方 Web `react_bundle.js` + camel→snake 转换）；
///   * `list` 接受 `sort_by`/`sort_direction` 且 `SUPPORT_ALBUM_SORTING_VERSION=2`
///     （官方 APK `ApiBrowseAlbum`）。
///   * 排序字段枚举：`SortingManager.AlbumSortBy`
///     （album_name / album_type / create_time / starting_time /
///     sharing_status / share_mod_time）；方向 `SortingManager.SortDirection`
///     （asc / desc）。
///
/// 点选后：**先本地生效**（立即重排 + 重取列表），再写回服务端默认；写回失败
/// 只提示，不回滚本地选择（服务端默认没存上不影响本次浏览）。
class _AlbumSortBar extends ConsumerWidget {
  const _AlbumSortBar();

  /// 排序字段（服务端键）。**只存键**：可显示文案统一由 [_fieldLabel]
  /// 按当前语言解析，避免第二份中文字面量。
  static const _fields = <String>[
    'create_time',
    'album_name',
    'starting_time',
    'album_type',
    'sharing_status',
    'share_mod_time',
  ];

  String _fieldLabel(String key) => switch (key) {
    'album_name' => photoWave1(PhotoWave1TextKeys.albumSortName, '名称'),
    'starting_time' => photoWave1(
      PhotoWave1TextKeys.albumSortStartTime,
      '开始时间',
    ),
    'album_type' => photoWave1(PhotoWave1TextKeys.albumSortType, '类型'),
    'sharing_status' => photoWave1(
      PhotoWave1TextKeys.albumSortSharingStatus,
      '共享状态',
    ),
    'share_mod_time' => photoWave1(
      PhotoWave1TextKeys.albumSortShareModTime,
      '共享修改时间',
    ),
    _ => photoWave1(PhotoWave1TextKeys.albumSortCreateTime, '创建时间'),
  };

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    PhotoAlbumSort sort,
  ) async {
    ref.read(photoAlbumSortProvider.notifier).set(sort);
    // 使用日志：相册排序偏好（只记稳定字段键，不记文案）
    trackSort(UsageModule.photos, sort.sortBy);
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    try {
      await api.setAlbumListOrder(
        sortBy: sort.sortBy,
        sortDirection: sort.sortDirection,
      );
      ref.invalidate(photoAlbumListOrderProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(photoWave1(PhotoWave1TextKeys.albumSortSaved, '排序已保存')),
        ),
      );
    } catch (err) {
      // 使用日志：排序保存失败（用户可见的错误；只记稳定原因码与错误类型）
      trackOnceFailure(
        UsageModule.photos,
        UsageAction.edit,
        objectType: 'album_sort',
        reason: 'sort_save_failed',
        error: err,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            photoWave1Fill(
              PhotoWave1TextKeys.albumSortFailed,
              '排序保存失败：{error}',
              {'error': describePhotoError(err, t)},
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 服务端默认排序到达后，填充本地态（用户已手动选过则不动）。放在 listen
    // 里而不是 build 里改 provider，避免"build 期间修改 provider"。
    ref.listen(photoAlbumListOrderProvider, (_, next) {
      final remote = next.value;
      if (remote == null) return;
      final cur = ref.read(photoAlbumSortProvider);
      if (cur.userSelected) return;
      if (remote.sortBy.isEmpty && remote.sortDirection.isEmpty) return;
      ref
          .read(photoAlbumSortProvider.notifier)
          .seed(
            PhotoAlbumSort(
              sortBy: remote.sortBy.isEmpty ? cur.sortBy : remote.sortBy,
              sortDirection: remote.sortDirection.isEmpty
                  ? cur.sortDirection
                  : remote.sortDirection,
            ),
          );
    });
    final sort = ref.watch(photoAlbumSortProvider);
    final ascending = sort.sortDirection == 'asc';
    // ★ r523（DA166，真机亮色像素英文）：这一行原来最左边有个
    // 「Album sort」标签 + `Expanded`。两颗 chip（`Creation time` /
    // `Descending`）在英文下把宽度吃光 ⇒ 标签被挤成**两行**
    // （"Album" / "sort"），整行高度翻倍、看着像坏了。
    // 标签本身是冗余的（两颗 chip 已经说明"排序字段 + 方向"，且都有 tooltip），
    // 去掉视觉标签、只留读屏用的 `Semantics` —— 行内空间全部让给控件。
    return Semantics(
      label: photoWave1(PhotoWave1TextKeys.albumSort, '相册排序'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
        child: Row(
          children: [
            PopupMenuButton<String>(
              key: const Key('photo-album-sort-field'),
              tooltip: photoWave1(PhotoWave1TextKeys.albumSortBy, '排序方式'),
              initialValue: sort.sortBy,
              onSelected: (key) => _apply(
                context,
                ref,
                PhotoAlbumSort(sortBy: key, sortDirection: sort.sortDirection),
              ),
              itemBuilder: (_) => [
                for (final key in _fields)
                  PopupMenuItem(value: key, child: Text(_fieldLabel(key))),
              ],
              child: _SortChip(
                icon: Icons.sort,
                label: _fieldLabel(sort.sortBy),
              ),
            ),
            const SizedBox(width: Gap.xs),
            TextButton.icon(
              key: const Key('photo-album-sort-direction'),
              onPressed: () => _apply(
                context,
                ref,
                PhotoAlbumSort(
                  sortBy: sort.sortBy,
                  sortDirection: ascending ? 'desc' : 'asc',
                ),
              ),
              icon: Icon(
                ascending ? Icons.arrow_upward : Icons.arrow_downward,
                size: 16,
              ),
              label: Text(
                ascending
                    ? photoWave1(PhotoWave1TextKeys.albumSortAsc, '升序')
                    : photoWave1(PhotoWave1TextKeys.albumSortDesc, '降序'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  const _SortChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 5),
    decoration: BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(Radii.capsule),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

// ---------------------------------------------------------------- 文件夹

class _FoldersView extends ConsumerWidget {
  const _FoldersView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(photoFoldersProvider);
    return PhotoAsync<List<FotoFolderDto>>(
      value: RiverpodAsync(async),
      emptyTitle: context.t.photoEmptyFoldersTitle,
      emptyMessage: context.t.photoEmptyFoldersMessage,
      isEmpty: (items) => items.isEmpty,
      onRetry: () => ref.invalidate(photoFoldersProvider),
      builder: (folders) => ListView.separated(
        padding: const EdgeInsets.all(Gap.md),
        itemCount: folders.length,
        separatorBuilder: (_, _) => const SizedBox(height: Gap.sm),
        itemBuilder: (context, i) {
          final f = folders[i];
          return _FolderRow(
            folder: f,
            onTap: () => Navigator.of(context, rootNavigator: true).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => PhotoFolderPage(folder: f),
              ),
            ),
            onRename: f.shared || f.id.isEmpty
                ? null
                : () => showRenameFolderDialog(context, ref, f),
            onDelete: f.shared || f.id.isEmpty
                ? null
                : () => confirmDeleteFolder(context, ref, f),
          );
        },
      ),
    );
  }
}

/// 文件夹行左侧的**封面**。
///
/// 候选来自 `Browse.Folder:list|get additional=["thumbnail"]`（[FotoFolderDto.covers]，
/// `folders()` 一直在请求这个 additional，只是以前界面没画）。两步：
///   1. [FotoApi.pickFolderCover] 挑**第一个就绪**的候选 —— 真机实测候选第一项
///      恰好是一条坏视频（`sm:"ame_defect"`），盲取会 404；
///   2. 复用智能相册那套请求构造器（缩略对象带 `unit_id` ⇒ `type=unit`）。
/// 一个就绪的都没有 → 画文件夹图标，**一个请求都不发**。
/// ★ 这条替换掉了原先无人调用的 `FotoApi.folderCoverUrl`（§2.0.45 死功能）——
///   同一个语义只留一份实现（`thumbnailUrl(type:'unit')`）。
class _FolderCover extends ConsumerWidget {
  const _FolderCover({required this.folder});

  final FotoFolderDto folder;

  static const double _size = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final icon = Icon(Icons.folder_outlined, color: hud.dim);
    final picked = FotoApi.pickFolderCover(folder.covers);
    final req = picked == null
        ? null
        : photoSmartAlbumCoverRequest(
            picked,
            ref.watch(fotoSpaceProvider),
            // 只会走 `unit_id` 那条分支（pickFolderCover 已要求 unitId 非空）；
            // `type=folder` 形态真机不可用（120/502），这里不依赖它。
            type: 'folder',
            id: folder.id,
          );
    if (req == null) {
      return SizedBox(
        width: _size,
        height: _size,
        child: Center(child: icon),
      );
    }
    final bytes = ref.watch(photoThumbProvider(req)).value;
    return ClipRRect(
      key: Key('photo-folder-cover-${folder.id}'),
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: _size,
        height: _size,
        child: bytes == null
            ? ColoredBox(
                color: hud.surface,
                child: Center(
                  child: Icon(Icons.folder_outlined, color: hud.dim, size: 20),
                ),
              )
            : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
      ),
    );
  }
}

class _FolderRow extends ConsumerWidget {
  const _FolderRow({
    required this.folder,
    required this.onTap,
    this.onRename,
    this.onDelete,
  });

  final FotoFolderDto folder;
  final VoidCallback onTap;

  /// 为 null 时不出菜单（共享给我的 / id 不合法的目录不给改）
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final menu = (onRename == null && onDelete == null)
        ? null
        : PopupMenuButton<String>(
            key: Key('photo-folder-menu-${folder.id}'),
            tooltip: context.t.photoMore,
            icon: Icon(Icons.more_vert, size: 18, color: hud.dim),
            onSelected: (v) {
              if (v == 'rename') onRename?.call();
              if (v == 'delete') onDelete?.call();
            },
            itemBuilder: (context) => [
              if (onRename != null)
                PopupMenuItem(
                  value: 'rename',
                  child: Text(context.t.photoRename),
                ),
              if (onDelete != null)
                PopupMenuItem(
                  value: 'delete',
                  child: Text(context.t.photoDeleteFolder),
                ),
            ],
          );
    // FieldBackdrop 是 ColoredBox（没有 Material 祖先）→ ListTile 的水波纹会炸，
    // 必须自己套一层透明 Material
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        onTap: onTap,
        leading: _FolderCover(folder: folder),
        title: Text(folder.name),
        subtitle: folder.shared ? Text(context.t.photoSharedWithMe) : null,
        trailing: menu == null
            ? const Icon(Icons.chevron_right, size: 18)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [menu, const Icon(Icons.chevron_right, size: 18)],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 收藏

class _FavoritesView extends ConsumerWidget {
  const _FavoritesView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(photoFavoritesProvider);
    return PhotoAsync<List<FotoItemDto>>(
      value: RiverpodAsync(async),
      emptyTitle: context.t.photoEmptyFavoritesTitle,
      emptyMessage: context.t.photoEmptyFavoritesMessage,
      isEmpty: (items) => items.isEmpty,
      onRetry: () => ref.invalidate(photoFavoritesProvider),
      builder: (items) => GridView.builder(
        padding: const EdgeInsets.all(Gap.xs),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: Gap.xs,
          crossAxisSpacing: Gap.xs,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) => _FavoriteCell(
          items: items,
          index: i,
          space: ref.watch(fotoSpaceProvider),
        ),
      ),
    );
  }
}

class _FavoriteCell extends StatelessWidget {
  const _FavoriteCell({
    required this.items,
    required this.index,
    required this.space,
  });

  final List<FotoItemDto> items;
  final int index;
  final FotoSpace space;

  @override
  Widget build(BuildContext context) => PhotoCell(
    item: items[index],
    space: space,
    onTap: () => _openViewer(context, items, index),
  );
}

// ---------------------------------------------------------------- 人物 / 场景
//
// 只读浏览（P2 阶段二 C 最后一块）。三态必须分开：
//   * **未开启**（`Setting.User.enable_person` / `enable_concept` 为 false）
//     → 引导态，而且**根本不发列表请求**（官方前端也是先过这道门）；
//   * **没有识别结果** → 空态（该 NAS 没识别到人/场景）；
//   * **无权限 / 未安装 / 功能不可用**（801 / 102 / 103）→ 错误态；
//     另外 `901`（人脸迁移未完成）、`902`（聚类未完成）单独翻成"正在整理"。
//
// **不做**：人脸合并/命名/设封面、人物关系图、场景自定义/隐藏（都是写操作或
// 管理员能力）。`Browse.Person/add_face|merge|separate|set|...` 一个都不调。

/// 人物 / 场景板块顶部的计数条（接 `Browse.Person|Concept/count`）。
///
/// 三态都给：加载中 → 细进度条；出错 → "数量拿不到" + 重试（**不影响下面的网格**）；
/// 拿到了 → "共 N 人 / 个场景"，列表还没取满时给"加载更多"。
class _SmartAlbumCountBar extends StatelessWidget {
  const _SmartAlbumCountBar({
    super.key,
    required this.prefix,
    required this.count,
    required this.shown,
    required this.countLabel,
    required this.onMore,
    required this.onRetry,
  });

  /// 用于生成稳定的 WidgetKey（`photo-persons-count` / `photo-concepts-count` …）
  final String prefix;

  final AsyncValue<int> count;

  /// 当前已经渲染出来的条目数（用来判断"还有没有更多"）
  final int shown;

  final String Function(int total) countLabel;
  final VoidCallback onMore;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final total = count.value;
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 0),
      child: Row(
        children: [
          if (total != null) ...[
            Text(
              countLabel(total),
              key: Key('$prefix-count-label'),
              style: style,
            ),
          ] else if (count.hasError)
            Expanded(
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 16, color: style?.color),
                  const SizedBox(width: Gap.xs),
                  Text(
                    photoP1(PhotoP1TextKeys.countUnavailable, '数量拿不到'),
                    key: Key('$prefix-count-error'),
                    style: style,
                  ),
                ],
              ),
            )
          else
            SizedBox(
              height: 2,
              width: 96,
              child: LinearProgressIndicator(key: Key('$prefix-count-loading')),
            ),
          const Spacer(),
          if (count.hasError)
            IconButton(
              key: Key('$prefix-count-retry'),
              tooltip: context.t.photoRetry,
              iconSize: 18,
              icon: const Icon(Icons.refresh),
              onPressed: onRetry,
            ),
          if (total != null && shown < total)
            TextButton(
              key: Key('$prefix-load-more'),
              onPressed: onMore,
              child: Text(
                photoP1Fill(
                  PhotoP1TextKeys.loadMoreRemaining,
                  '加载更多（还有 {count} 个）',
                  {'count': '${total - shown}'},
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 「人物」段：网格列人（官方 `Browse.Person/list` v1）。
class _PersonsView extends ConsumerStatefulWidget {
  const _PersonsView();

  @override
  ConsumerState<_PersonsView> createState() => _PersonsViewState();
}

class _PersonsViewState extends ConsumerState<_PersonsView> {
  /// 0 = 首屏（沿用 [photoPersonsProvider] 的 `show_more` 回退语义）；
  /// > 0 = 用户点过「加载更多」之后的页大小（走 [photoPersonsPageProvider]）。
  int _limit = 0;

  @override
  Widget build(BuildContext context) {
    final setting = ref.watch(fotoSettingProvider).value;
    // NAS 端没开人脸识别 → 直接给引导态（不要发一个必然空的请求）
    if (setting != null && !setting.enablePerson) {
      return AppEmptyState(
        icon: Icons.face_retouching_natural_outlined,
        title: context.t.photoEmptyPersonsDisabledTitle,
        message: context.t.photoEmptyPersonsDisabledMessage,
      );
    }
    final async = _limit == 0
        ? ref.watch(photoPersonsProvider)
        : ref.watch(photoPersonsPageProvider(_limit));
    // 901 = PERSON_MIGRATION_IS_NOT_FINISHED：这不是错误，是"还没跑完"，
    // 单独给"正在整理"的空态（官方前端也为它专门分支）。
    final error = async is AsyncError<List<FotoPersonDto>> ? async.error : null;
    if (error is DsmApiException && error.code == 901) {
      // 迁移进度能给就一起给（`Browse.Person/get_migration_status`）：
      // 有进度 → "…（已整理 42%）"；拿不到就退回纯文案——**不谎报、不吓人**。
      final migration = ref.watch(photoPersonMigrationProvider).value;
      final message = (migration != null && migration.hasProgress)
          ? photoP0Fill(
              PhotoP0TextKeys.personMigratingProgress,
              '{message}（已整理 {percent}%）',
              {
                'message': context.t.photoPersonsMigratingMessage,
                'percent': '${(migration.ratio * 100).round()}',
              },
            )
          : context.t.photoPersonsMigratingMessage;
      return AppEmptyState(
        icon: Icons.hourglass_top_outlined,
        title: context.t.photoPersonsMigratingTitle,
        message: message,
      );
    }
    return PhotoAsync<List<FotoPersonDto>>(
      value: RiverpodAsync(async),
      emptyTitle: context.t.photoEmptyPersonsTitle,
      emptyMessage: context.t.photoEmptyPersonsMessage,
      emptyIcon: Icons.face_retouching_natural_outlined,
      isEmpty: (people) => people.isEmpty,
      onRetry: () => ref.invalidate(
        _limit == 0 ? photoPersonsProvider : photoPersonsPageProvider(_limit),
      ),
      builder: (people) => Column(
        children: [
          _SmartAlbumCountBar(
            key: const Key('photo-persons-count'),
            prefix: 'photo-persons',
            count: ref.watch(photoPersonCountProvider),
            shown: people.length,
            countLabel: (n) => photoP1Fill(
              PhotoP1TextKeys.personCount,
              '共 {count} 人',
              {'count': '$n'},
            ),
            onMore: () => setState(
              () => _limit = people.length + kFotoSmartAlbumPageSize,
            ),
            onRetry: () => ref.invalidate(photoPersonCountProvider),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(Gap.md),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:
                    albumColumnsFor(MediaQuery.sizeOf(context).width),
                mainAxisSpacing: Gap.md,
                crossAxisSpacing: Gap.md,
                childAspectRatio: 0.86,
              ),
              itemCount: people.length,
              itemBuilder: (context, i) {
                final p = people[i];
                final t = context.t;
                final name = p.name.isEmpty ? t.photoPersonUntitled : p.name;
                return Stack(
                  children: [
                    PhotoAlbumTile(
                      title: name,
                      subtitle: p.itemCount > 0
                          ? t.photoPhotoCount(p.itemCount)
                          : null,
                      iconFallback: Icons.face_retouching_natural_outlined,
                      coverRequest: photoSmartAlbumCoverRequest(
                        p.cover,
                        ref.watch(fotoSpaceProvider),
                        type: 'person',
                        id: p.id,
                      ),
                      onTap: () =>
                          Navigator.of(context, rootNavigator: true).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => PhotoSmartAlbumPage(
                                kind: PhotoSmartAlbumKind.person,
                                id: p.id,
                                title: name,
                              ),
                            ),
                          ),
                    ),
                    // P18：显示 / 隐藏人物（官方 `Person/show`，v1）。
                    // 已隐藏的人用"眼睛"图标提示，点一下切换（**不隐藏入口**：
                    // 隐藏本身就是这个按钮的作用，藏起来就没法恢复）。
                    Positioned(
                      top: 2,
                      right: 2,
                      child: IconButton(
                        key: Key('photo-person-visibility-${p.id}'),
                        tooltip: p.show
                            ? photoP0(PhotoP0TextKeys.personHide, '隐藏')
                            : photoP0(PhotoP0TextKeys.personShow, '显示'),
                        iconSize: 18,
                        icon: Icon(
                          p.show
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => _togglePersonShow(ref, p),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// P18：切换人物显示 / 隐藏。
  ///
  /// 失败 ⇒ 明确提示；成功后失效人物列表让服务端状态回来（**不做乐观更新**：
  /// 服务端才是事实来源）。
  Future<void> _togglePersonShow(WidgetRef ref, FotoPersonDto p) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    try {
      await api.personShow(personIds: [p.id], show: !p.show);
      ref.invalidate(photoPersonsProvider);
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(describePhotoError(err, t))),
      );
    }
  }
}

/// 「场景」段：网格列场景 / 主题（官方 `Browse.Concept/list` v2）。
class _ConceptsView extends ConsumerStatefulWidget {
  const _ConceptsView();

  @override
  ConsumerState<_ConceptsView> createState() => _ConceptsViewState();
}

class _ConceptsViewState extends ConsumerState<_ConceptsView> {
  /// 同 [_PersonsViewState._limit]：0 = 首屏。
  int _limit = 0;

  @override
  Widget build(BuildContext context) {
    final setting = ref.watch(fotoSettingProvider).value;
    if (setting != null && !setting.enableConcept) {
      return AppEmptyState(
        icon: Icons.auto_awesome_outlined,
        title: context.t.photoEmptyConceptsDisabledTitle,
        message: context.t.photoEmptyConceptsDisabledMessage,
      );
    }
    final async = _limit == 0
        ? ref.watch(photoConceptsProvider)
        : ref.watch(photoConceptsPageProvider(_limit));
    return PhotoAsync<List<FotoConceptDto>>(
      value: RiverpodAsync(async),
      emptyTitle: context.t.photoEmptyConceptsTitle,
      emptyMessage: context.t.photoEmptyConceptsMessage,
      emptyIcon: Icons.auto_awesome_outlined,
      isEmpty: (items) => items.isEmpty,
      onRetry: () => ref.invalidate(
        _limit == 0 ? photoConceptsProvider : photoConceptsPageProvider(_limit),
      ),
      builder: (concepts) => Column(
        children: [
          _SmartAlbumCountBar(
            key: const Key('photo-concepts-count'),
            prefix: 'photo-concepts',
            count: ref.watch(photoConceptCountProvider),
            shown: concepts.length,
            countLabel: (n) => photoP1Fill(
              PhotoP1TextKeys.conceptCount,
              '共 {count} 个场景',
              {'count': '$n'},
            ),
            onMore: () => setState(
              () => _limit = concepts.length + kFotoSmartAlbumPageSize,
            ),
            onRetry: () => ref.invalidate(photoConceptCountProvider),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(Gap.md),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:
                    albumColumnsFor(MediaQuery.sizeOf(context).width),
                mainAxisSpacing: Gap.md,
                crossAxisSpacing: Gap.md,
                childAspectRatio: 0.86,
              ),
              itemCount: concepts.length,
              itemBuilder: (context, i) {
                final c = concepts[i];
                final name = c.name.isEmpty ? c.id : c.name;
                return PhotoAlbumTile(
                  title: name,
                  subtitle: c.itemCount > 0
                      ? context.t.photoPhotoCount(c.itemCount)
                      : null,
                  iconFallback: Icons.auto_awesome_outlined,
                  coverRequest: photoSmartAlbumCoverRequest(
                    c.cover,
                    ref.watch(fotoSpaceProvider),
                    type: 'concept',
                    id: c.id,
                  ),
                  onTap: () =>
                      Navigator.of(context, rootNavigator: true).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => PhotoSmartAlbumPage(
                            kind: PhotoSmartAlbumKind.concept,
                            id: c.id,
                            title: name,
                          ),
                        ),
                      ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 人物 / 场景两种"名下照片"页（区别只在取数用的 family provider）。
enum PhotoSmartAlbumKind { person, concept }

/// 某人 / 某场景详情页的头：封面 + 名字 + 总数（`Browse.Person|Concept/get`）。
///
/// 四态都给：加载中 → 细进度条；有数据 → 封面 + 名字 + "N 张照片"；
/// 失败 → "加载失败" + 重试（**不影响下面网格的取数**）；
/// 未命名 → 复用既有"未命名"文案。
class _SmartAlbumDetailHeader extends ConsumerWidget {
  const _SmartAlbumDetailHeader({
    super.key,
    required this.kind,
    required this.id,
    required this.title,
    required this.fallbackCount,
    required this.info,
    required this.loading,
    required this.hasError,
    required this.onRetry,
  });

  final PhotoSmartAlbumKind kind;
  final String id;
  final String title;
  final int fallbackCount;
  final ({String name, int itemCount, FotoThumbDto? cover})? info;
  final bool loading;
  final bool hasError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    if (hasError) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                t.photoLoadFailed,
                key: const Key('photo-smart-album-detail-error'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              key: const Key('photo-smart-album-detail-retry'),
              onPressed: onRetry,
              child: Text(t.photoRetry),
            ),
          ],
        ),
      );
    }
    if (info == null) {
      return SizedBox(
        height: 2,
        child: loading
            ? LinearProgressIndicator(
                key: const Key('photo-smart-album-detail-loading'),
              )
            : null,
      );
    }
    final name = switch (kind) {
      PhotoSmartAlbumKind.person =>
        info!.name.isEmpty ? t.photoPersonUntitled : info!.name,
      PhotoSmartAlbumKind.concept => info!.name.isEmpty ? title : info!.name,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 48,
              height: 48,
              child: info!.cover == null
                  ? ColoredBox(
                      color: hud.bg,
                      child: Icon(
                        kind == PhotoSmartAlbumKind.person
                            ? Icons.face_retouching_natural_outlined
                            : Icons.auto_awesome_outlined,
                        color: hud.dim,
                        size: 20,
                      ),
                    )
                  : PhotoThumb(
                      request: photoSmartAlbumCoverRequest(
                        info!.cover,
                        ref.watch(fotoSpaceProvider),
                        type: kind == PhotoSmartAlbumKind.person
                            ? 'person'
                            : 'concept',
                        id: id,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  key: const Key('photo-smart-album-detail-name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  photoP1Fill(PhotoP1TextKeys.detailSummary, '共 {count} 张照片', {
                    'count':
                        '${info!.itemCount > 0 ? info!.itemCount : fallbackCount}',
                  }),
                  key: const Key('photo-smart-album-detail-count'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          // P18：合并到别的人物（官方 `Person/merge` v2）。
          if (kind == PhotoSmartAlbumKind.person)
            IconButton(
              key: const Key('photo-person-merge'),
              tooltip: context.t.photoPersonMergeTooltip,
              icon: const Icon(Icons.merge_type, size: 18),
              onPressed: () => _mergePerson(context, ref),
            ),
          // P18：人物改名（官方 `Person/set` 的 `id`+`name`）。
          // 只对人物显示：场景/主题没有"名字可改"这个用户操作。
          if (kind == PhotoSmartAlbumKind.person)
            IconButton(
              key: const Key('photo-person-rename'),
              tooltip: photoP0(PhotoP0TextKeys.personRename, '重命名人物'),
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => _renamePerson(context, ref, name),
            ),
        ],
      ),
    );
  }

  /// P18：把**当前人物**合并到另一个人物（官方 `Person/merge` **v2**）。
  ///
  /// 半自动：先让人选目标（其余人物列表），再二次确认；
  /// 任一步取消 ⇒ **零请求**。成功后当前人物已被并走 ⇒ 退回列表并刷新。
  Future<void> _mergePerson(BuildContext context, WidgetRef ref) async {
    final others = ref
        .read(photoPersonsProvider)
        .value
        ?.where((p) => p.id != id)
        .toList();
    if (others == null || others.isEmpty) return;
    final l10n = context.t;
    final target = await showDialog<FotoPersonDto>(
      context: context,
      builder: (context) => SimpleDialog(
        key: const Key('photo-person-merge-picker'),
        title: Text(context.t.photoPersonMergePickerTitle),
        children: [
          for (final p in others)
            SimpleDialogOption(
              key: Key('photo-person-merge-target-${p.id}'),
              onPressed: () => Navigator.of(context).pop(p),
              child: Text(p.name.isEmpty ? l10n.photoPersonUntitled : p.name),
            ),
        ],
      ),
    );
    if (target == null || !context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('photo-person-merge-confirm'),
        title: Text(context.t.photoPersonMergeConfirmTitle(target.name)),
        content: Text(context.t.photoPersonMergeConfirmBody),
        actions: [
          TextButton(
            key: const Key('photo-person-merge-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-person-merge-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.photoPersonMergeAction),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await api.personMerge(targetId: target.id, mergedIds: [id]);
      ref.invalidate(photoPersonsProvider);
      ref.invalidate(photoPersonDetailProvider(id));
      // 本人已被并走：退回人物列表（留着只会看到一个已经不存在的条目）
      navigator.maybePop();
      messenger.showSnackBar(SnackBar(content: Text(l10n.photoPersonMerged)));
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(describePhotoError(err, l10n))),
      );
    }
  }

  /// P18：人物改名。空名 / 未改 ⇒ **不发请求**。
  Future<void> _renamePerson(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _PersonRenameDialog(initial: current),
    );
    // 取消 / 空名 / 没改 → 零请求
    if (picked == null || picked.isEmpty || picked == current) return;
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    try {
      await api.personSetName(personId: id, name: picked);
      ref.invalidate(photoPersonDetailProvider(id));
      ref.invalidate(photoPersonsProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(photoP0(PhotoP0TextKeys.personRenamed, '人物已重命名')),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(describePhotoError(err, l10n))),
      );
    }
  }
}

/// 人物改名对话框。
///
/// 必须是有状态组件：`TextEditingController` 要在**对话框真正销毁**时释放。
/// （早前版本在 `showDialog` 返回后立刻 dispose，退场动画还在构建 TextField，
/// 触发 "A TextEditingController was used after being disposed"。）
class _PersonRenameDialog extends StatefulWidget {
  const _PersonRenameDialog({required this.initial});

  final String initial;

  @override
  State<_PersonRenameDialog> createState() => _PersonRenameDialogState();
}

class _PersonRenameDialogState extends State<_PersonRenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('photo-person-rename-dialog'),
    title: Text(photoP0(PhotoP0TextKeys.personRename, '重命名人物')),
    content: TextField(
      key: const Key('photo-person-rename-field'),
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(labelText: context.t.contactFieldFullName),
    ),
    actions: [
      TextButton(
        key: const Key('photo-person-rename-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.t.actionCancel),
      ),
      FilledButton(
        key: const Key('photo-person-rename-ok'),
        onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
        child: Text(context.t.actionSave),
      ),
    ],
  );
}

/// 某人 / 某场景名下的照片：网格 + 大图查看器 + 长按多选打标签。
///
/// 完全复用现有的 [PhotoGrid] / [PhotoSelectionController] / [PhotoViewerPage] /
/// [showPhotoTagSheet]（与相册详情页同一套交互，不另造轮子）。
class PhotoSmartAlbumPage extends ConsumerStatefulWidget {
  const PhotoSmartAlbumPage({
    super.key,
    required this.kind,
    required this.id,
    required this.title,
  });

  final PhotoSmartAlbumKind kind;

  /// 人物 / 场景 id
  final String id;

  /// AppBar 标题（已按"未命名"回落处理过）
  final String title;

  @override
  ConsumerState<PhotoSmartAlbumPage> createState() =>
      _PhotoSmartAlbumPageState();
}

class _PhotoSmartAlbumPageState extends ConsumerState<PhotoSmartAlbumPage> {
  final PhotoSelectionController _selection = PhotoSelectionController();

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelection);
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  void _onSelection() {
    if (mounted) setState(() {});
  }

  Future<void> _addToAlbum(List<FotoItemDto> items) async {
    final ids = [
      for (final item in items)
        if (_selection.contains(item.id)) item.id,
    ];
    await showAddToAlbumSheet(context, ref, itemIds: ids);
    if (mounted) _selection.clear();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final space = ref.watch(fotoSpaceProvider);
    final async = switch (widget.kind) {
      PhotoSmartAlbumKind.person => ref.watch(
        photoPersonItemsProvider((space: space, personId: widget.id)),
      ),
      PhotoSmartAlbumKind.concept => ref.watch(
        photoConceptItemsProvider((space: space, conceptId: widget.id)),
      ),
    };
    final emptyTitle = switch (widget.kind) {
      PhotoSmartAlbumKind.person => t.photoEmptyPersonTitle,
      PhotoSmartAlbumKind.concept => t.photoEmptyConceptTitle,
    };
    final emptyMessage = switch (widget.kind) {
      PhotoSmartAlbumKind.person => t.photoEmptyPersonMessage,
      PhotoSmartAlbumKind.concept => t.photoEmptyConceptMessage,
    };
    // 详情头：`Browse.Person|Concept/get`（人物 / 场景的封面 + 数量）。
    // 拿不到就回落成"标题 + 当前已加载张数"，**不白屏、不挡列表**。
    final detail = switch (widget.kind) {
      PhotoSmartAlbumKind.person => ref.watch(
        photoPersonDetailProvider(widget.id),
      ),
      PhotoSmartAlbumKind.concept => ref.watch(
        photoConceptDetailProvider(widget.id),
      ),
    };
    final detailDto = detail.value;
    // 两个 DTO 没有共同接口，但字段同名 → 在这里收敛成一条记录给头部用。
    final ({String name, int itemCount, FotoThumbDto? cover})? detailInfo =
        switch (widget.kind) {
          PhotoSmartAlbumKind.person =>
            detailDto is FotoPersonDto
                ? (
                    name: detailDto.name,
                    itemCount: detailDto.itemCount,
                    cover: detailDto.cover,
                  )
                : null,
          PhotoSmartAlbumKind.concept =>
            detailDto is FotoConceptDto
                ? (
                    name: detailDto.name,
                    itemCount: detailDto.itemCount,
                    cover: detailDto.cover,
                  )
                : null,
        };
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: PhotoAsync<List<FotoItemDto>>(
        value: RiverpodAsync(async),
        emptyTitle: emptyTitle,
        emptyMessage: emptyMessage,
        isEmpty: (items) => items.isEmpty,
        onRetry: () {
          final s = ref.read(fotoSpaceProvider);
          switch (widget.kind) {
            case PhotoSmartAlbumKind.person:
              ref.invalidate(
                photoPersonItemsProvider((space: s, personId: widget.id)),
              );
            case PhotoSmartAlbumKind.concept:
              ref.invalidate(
                photoConceptItemsProvider((space: s, conceptId: widget.id)),
              );
          }
        },
        builder: (items) => Column(
          children: [
            _SmartAlbumDetailHeader(
              key: const Key('photo-smart-album-detail-header'),
              kind: widget.kind,
              id: widget.id,
              title: widget.title,
              fallbackCount: items.length,
              info: detailInfo,
              loading: detail.isLoading,
              hasError: detail.hasError,
              onRetry: () => ref.invalidate(
                widget.kind == PhotoSmartAlbumKind.person
                    ? photoPersonDetailProvider(widget.id)
                    : photoConceptDetailProvider(widget.id),
              ),
            ),
            // P18：人物页顶部人脸条（点一张脸 → 移出该人物 / 拆分为新人物）
            if (widget.kind == PhotoSmartAlbumKind.person)
              PhotoFaceStrip(
                personId: widget.id,
                itemIds: items.map((e) => e.id).toList(),
              ),
            if (_selection.active)
              PhotoSelectionHeader(
                count: _selection.count,
                total: items.length,
                onSelectAll: () => _selection.selectAll(items.map((e) => e.id)),
                onClear: _selection.clear,
              ),
            Expanded(
              child: PhotoGrid(
                items: items,
                space: space,
                size: 'm',
                columns: ref.watch(photoGridColumnsProvider),
                selecting: _selection.active,
                selectedIds: _selection.ids,
                onTap: (i) {
                  if (_selection.active) {
                    _selection.toggle(items[i].id);
                    return;
                  }
                  _openViewer(context, items, i);
                },
                onLongPress: (i) => _selection.enter(items[i].id),
              ),
            ),
            if (_selection.active)
              PhotoSelectionBar(
                items: [
                  for (final it in items)
                    if (_selection.contains(it.id)) it,
                ],
                space: ref.watch(fotoSpaceProvider),
                onClear: _selection.clear,
                onAddToAlbum: () => _addToAlbum(items),
                // P18/P19：设封面；概念另有"从该场景移除"
                onSetCover: () => _setSmartCover(items),
                onRemoveSmart: widget.kind == PhotoSmartAlbumKind.concept
                    ? () => _removeFromConcept(items)
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  /// P18/P19：把选中的照片设为人物/场景封面（官方 `set_cover`）。
  ///
  /// **多选超过 1 张 ⇒ 不发请求**（服务端只接受一个 `photo_id`，
  /// 随便挑一张当封面属于"替用户做决定"）。
  Future<void> _setSmartCover(List<FotoItemDto> items) async {
    final selected = [
      for (final it in items)
        if (_selection.contains(it.id)) it,
    ];
    if (selected.length != 1) return;
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    try {
      if (widget.kind == PhotoSmartAlbumKind.person) {
        await api.personSetCover(
          personId: widget.id,
          photoId: selected.single.id,
        );
        ref.invalidate(photoPersonDetailProvider(widget.id));
      } else {
        await api.conceptSetCover(
          conceptId: widget.id,
          photoId: selected.single.id,
        );
        ref.invalidate(photoConceptDetailProvider(widget.id));
      }
      _selection.clear();
      messenger.showSnackBar(
        SnackBar(content: Text(photoP0(PhotoP0TextKeys.coverSet, '封面已更新'))),
      );
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(describePhotoError(err, t))),
      );
    }
  }

  /// P19：把选中照片**从该场景移除**（官方 `Concept/hide_item`，逐张调用）。
  ///
  /// 破坏性 ⇒ **先二次确认**；取消则一个请求都不发。
  Future<void> _removeFromConcept(List<FotoItemDto> items) async {
    final selected = [
      for (final it in items)
        if (_selection.contains(it.id)) it,
    ];
    if (selected.isEmpty) return;
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('photo-smart-remove-confirm'),
        title: Text(
          photoP0(PhotoP0TextKeys.removeSmartConfirm, '从该场景移除选中的照片？'),
        ),
        content: Text(
          photoP0(
            PhotoP0TextKeys.removeSmartBody,
            '只影响这个场景的归类，照片本身不会被删除，之后仍可在时间轴里看到。',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('photo-smart-remove-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-smart-remove-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    var doneCount = 0;
    var failCount = 0;
    for (final it in selected) {
      try {
        await api.conceptHideItem(conceptId: widget.id, itemId: it.id);
        doneCount++;
      } catch (_) {
        failCount++;
      }
    }
    _selection.clear();
    ref.invalidate(
      photoConceptItemsProvider((
        space: ref.read(fotoSpaceProvider),
        conceptId: widget.id,
      )),
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failCount == 0
              ? photoP0(PhotoP0TextKeys.removeSmartDone, '已从该场景移除')
              : '${photoP0(PhotoP0TextKeys.removeSmartDone, '已从该场景移除')} '
                    '($doneCount/$failCount)',
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 相册 / 文件夹详情

/// 相册里的照片（2 段：照片网格；点开大图）——长按进多选，可批量打标签
class PhotoAlbumItemsPage extends ConsumerStatefulWidget {
  const PhotoAlbumItemsPage({super.key, required this.album});

  final FotoAlbumDto album;

  @override
  ConsumerState<PhotoAlbumItemsPage> createState() =>
      _PhotoAlbumItemsPageState();
}

class _PhotoAlbumItemsPageState extends ConsumerState<PhotoAlbumItemsPage> {
  final PhotoSelectionController _selection = PhotoSelectionController();

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelection);
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  void _onSelection() {
    if (mounted) setState(() {});
  }

  Future<void> _addToAlbum(List<FotoItemDto> items) async {
    final ids = [
      for (final item in items)
        if (_selection.contains(item.id)) item.id,
    ];
    await showAddToAlbumSheet(context, ref, itemIds: ids);
    if (mounted) _selection.clear();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final space = ref.watch(fotoSpaceProvider);
    final album = widget.album;
    final async = ref.watch(
      photoAlbumItemsProvider((space: space, albumId: album.id)),
    );
    // ⚠️ 用 provider 里的**最新**那份：改名之后共用的 provider 会刷新，
    // 但传进来的 DTO 是打开这一页时的快照 —— 真机上表现为"改完名标题还是旧的，
    // 连删除确认框里也念旧名字"。
    final live = ref
        .watch(photoNormalAlbumsProvider)
        .whenData((list) => list)
        .value
        ?.where((a) => a.id == album.id)
        .firstOrNull;
    final shown = live ?? album;
    // 条件相册不能改名/删（服务端也不允许往里加照片）
    final editable = shown.type == 'normal' || shown.type.isEmpty;
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(shown.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (editable)
            PopupMenuButton<String>(
              tooltip: context.t.photoAlbumActions,
              onSelected: (v) {
                switch (v) {
                  case 'rename':
                    showRenameAlbumDialog(context, ref, shown);
                  case 'delete':
                    confirmDeleteAlbum(context, ref, shown);
                  case 'share':
                    // ★ r417（DA75）：相册共享此前**只有**"已共享列表里点一行"
                    // 这一个入口 ⇒ 首个共享相册在 App 内建不出来。相册详情页
                    // 直连共享页（外链 / 成员 / 口令）。
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => AlbumSharingDetailPage(album: shown),
                      ),
                    );
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'share',
                  child: Text(context.t.photoShare),
                ),
                PopupMenuItem(
                  value: 'rename',
                  child: Text(context.t.photoRename),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(context.t.photoDeleteAlbum),
                ),
              ],
            ),
        ],
      ),
      body: PhotoAsync<List<FotoItemDto>>(
        value: RiverpodAsync(async),
        emptyTitle: context.t.photoEmptyAlbumTitle,
        emptyMessage: editable ? context.t.photoEmptyAlbumMessage : null,
        isEmpty: (items) => items.isEmpty,
        onRetry: () => ref.invalidate(
          photoAlbumItemsProvider((space: space, albumId: album.id)),
        ),
        builder: (items) => Column(
          children: [
            if (_selection.active)
              PhotoSelectionHeader(
                count: _selection.count,
                total: items.length,
                onSelectAll: () => _selection.selectAll(items.map((e) => e.id)),
                onClear: _selection.clear,
              ),
            Expanded(
              child: PhotoGrid(
                items: items,
                space: space,
                size: 'm',
                columns: ref.watch(photoGridColumnsProvider),
                selecting: _selection.active,
                selectedIds: _selection.ids,
                onTap: (i) {
                  if (_selection.active) {
                    _selection.toggle(items[i].id);
                    return;
                  }
                  Navigator.of(context, rootNavigator: true).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => PhotoViewerPage(
                        items: items,
                        index: i,
                        albumId: editable ? album.id : null,
                        albumName: editable ? album.name : null,
                      ),
                    ),
                  );
                },
                onLongPress: (i) => _selection.enter(items[i].id),
              ),
            ),
            if (_selection.active)
              PhotoSelectionBar(
                items: [
                  for (final it in items)
                    if (_selection.contains(it.id)) it,
                ],
                space: ref.watch(fotoSpaceProvider),
                albumId: widget.album.id,
                onClear: _selection.clear,
                onAddToAlbum: () => _addToAlbum(items),
              ),
          ],
        ),
      ),
    );
  }
}

/// 文件夹页：子文件夹 + 照片（照片支持长按多选 → 批量打标签）
class PhotoFolderPage extends ConsumerStatefulWidget {
  const PhotoFolderPage({super.key, required this.folder});

  final FotoFolderDto folder;

  @override
  ConsumerState<PhotoFolderPage> createState() => _PhotoFolderPageState();
}

class _PhotoFolderPageState extends ConsumerState<PhotoFolderPage> {
  final PhotoSelectionController _selection = PhotoSelectionController();

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelection);
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  void _onSelection() {
    if (mounted) setState(() {});
  }

  Future<void> _addToAlbum(List<FotoItemDto> items) async {
    final ids = [
      for (final item in items)
        if (_selection.contains(item.id)) item.id,
    ];
    await showAddToAlbumSheet(context, ref, itemIds: ids);
    if (mounted) _selection.clear();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final space = ref.watch(fotoSpaceProvider);
    final folder = widget.folder;
    final subs = ref.watch(
      photoSubFoldersProvider((space: space, parentId: folder.id)),
    );
    final items = ref.watch(
      photoFolderItemsProvider((space: space, folderId: folder.id)),
    );
    final photos = items.value ?? const <FotoItemDto>[];

    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (!folder.shared && folder.id.isNotEmpty)
            PopupMenuButton<String>(
              key: const Key('photo-folder-page-menu'),
              tooltip: context.t.photoMore,
              onSelected: (v) {
                if (v == 'rename') showRenameFolderDialog(context, ref, folder);
                if (v == 'delete') confirmDeleteFolder(context, ref, folder);
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'rename',
                  child: Text(context.t.photoRename),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(context.t.photoDeleteFolder),
                ),
              ],
            ),
        ],
      ),
      floatingActionButton: folder.shared || folder.id.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const Key('photo-subfolder-create'),
              // ★ r522（DA165 同族）：同上，亮色白底白字。
              backgroundColor: hud.surface,
              foregroundColor: hud.primary,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(context.t.photoCreateFolder),
              onPressed: () =>
                  showCreateFolderDialog(context, ref, parentId: folder.id),
            ),
      body: Column(
        children: [
          if (_selection.active)
            PhotoSelectionHeader(
              count: _selection.count,
              total: photos.length,
              onSelectAll: () => _selection.selectAll(photos.map((e) => e.id)),
              onClear: _selection.clear,
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(
                  photoSubFoldersProvider((space: space, parentId: folder.id)),
                );
                ref.invalidate(
                  photoFolderItemsProvider((space: space, folderId: folder.id)),
                );
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  ...subs.when(
                    loading: () => const [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(Gap.md),
                          child: LinearProgressIndicator(),
                        ),
                      ),
                    ],
                    error: (e, _) => [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(Gap.md),
                          child: Text(
                            describePhotoError(e, context.t),
                            style: TextStyle(color: hud.dim),
                          ),
                        ),
                      ),
                    ],
                    data: (folders) => [
                      if (folders.isNotEmpty)
                        SliverList.builder(
                          itemCount: folders.length,
                          itemBuilder: (context, i) => _FolderRow(
                            folder: folders[i],
                            onTap: () =>
                                Navigator.of(
                                  context,
                                  rootNavigator: true,
                                ).push<void>(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        PhotoFolderPage(folder: folders[i]),
                                  ),
                                ),
                            onRename: folders[i].shared || folders[i].id.isEmpty
                                ? null
                                : () => showRenameFolderDialog(
                                    context,
                                    ref,
                                    folders[i],
                                  ),
                            onDelete: folders[i].shared || folders[i].id.isEmpty
                                ? null
                                : () => confirmDeleteFolder(
                                    context,
                                    ref,
                                    folders[i],
                                  ),
                          ),
                        ),
                    ],
                  ),
                  items.when(
                    loading: () => const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(Gap.xl),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                    error: (e, _) => SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(Gap.md),
                        child: Text(
                          describePhotoError(e, context.t),
                          style: TextStyle(color: hud.dim),
                        ),
                      ),
                    ),
                    data: (photos) => photos.isEmpty
                        ? const SliverToBoxAdapter(child: SizedBox.shrink())
                        : PhotoGrid(
                            items: photos,
                            space: space,
                            size: 'm',
                            sliver: true,
                            columns: ref.watch(photoGridColumnsProvider),
                            selecting: _selection.active,
                            selectedIds: _selection.ids,
                            onTap: (i) {
                              if (_selection.active) {
                                _selection.toggle(photos[i].id);
                                return;
                              }
                              _openViewer(context, photos, i);
                            },
                            onLongPress: (i) => _selection.enter(photos[i].id),
                          ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: Gap.xl)),
                ],
              ),
            ),
          ),
          if (_selection.active)
            PhotoSelectionBar(
              items: [
                for (final it in photos)
                  if (_selection.contains(it.id)) it,
              ],
              space: ref.watch(fotoSpaceProvider),
              onClear: _selection.clear,
              onAddToAlbum: () => _addToAlbum(photos),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 相册写操作

/// 「新建相册」对话框（可选：把给定的照片一起放进去）
Future<FotoAlbumDto?> showCreateAlbumDialog(
  BuildContext context,
  WidgetRef ref, {
  List<String> itemIds = const [],
}) async {
  final controller = TextEditingController();
  final messenger = ScaffoldMessenger.of(context);
  final t = context.t;
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.photoNewAlbum),
      content: TextField(
        key: const Key('photo-album-name'),
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: t.photoAlbumNameHint,
          helperText: itemIds.isEmpty
              ? null
              : t.photoAlbumCreateHelper(itemIds.length),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          key: const Key('photo-album-create-ok'),
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: Text(t.photoCreate),
        ),
      ],
    ),
  );
  // ⚠️ 对话框退场动画期间 TextField 还会重建，这里不 dispose（见阅读器同款注释）
  if (name == null) return null;
  if (name.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(t.photoAlbumNameRequired)));
    return null;
  }
  try {
    final album = await ref
        .read(photoAlbumActionsProvider)
        .create(name, itemIds: itemIds);
    messenger.showSnackBar(SnackBar(content: Text(t.photoAlbumCreated(name))));
    return album;
  } catch (err) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(t.photoAlbumCreateFailed(describePhotoError(err, t))),
      ),
    );
    return null;
  }
}

/// 「加入相册」弹层：列普通相册 + 新建一个（当前照片一起加进去）
Future<void> showAddToAlbumSheet(
  BuildContext context,
  WidgetRef ref, {
  required List<String> itemIds,
}) async {
  if (itemIds.isEmpty) return;
  final albums = await ref.read(photoNormalAlbumsProvider.future);
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final t = context.t;
  final picked = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DesignRowTile(
            title: Text(
              t.photoAddToAlbumTitle(itemIds.length),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            trailing: IconButton(
              tooltip: t.photoClose,
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          const Divider(height: 1),
          DesignRowTile(
            key: const Key('photo-add-new-album'),
            leading: const Icon(Icons.add),
            title: Text(t.photoNewAlbumAndAdd),
            onTap: () => Navigator.of(context).pop('__new__'),
          ),
          if (albums.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Text(
                t.photoNoNormalAlbums,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: DesignPalette.of(context).dim,
                ),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: albums.length,
                itemBuilder: (context, i) => DesignRowTile(
                  leading: const Icon(Icons.photo_album_outlined),
                  title: Text(albums[i].name),
                  subtitle: albums[i].itemCount > 0
                      ? Text(t.photoItemCount(albums[i].itemCount))
                      : null,
                  onTap: () => Navigator.of(context).pop(albums[i].id),
                ),
              ),
            ),
          const SizedBox(height: Gap.xs),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;

  final actions = ref.read(photoAlbumActionsProvider);
  if (picked == '__new__') {
    await showCreateAlbumDialog(context, ref, itemIds: itemIds);
    return;
  }
  try {
    final failed = await actions.addItems(picked, itemIds);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed.isEmpty
              ? t.photoAddedToAlbum
              : t.photoAddedPartial(failed.length),
        ),
      ),
    );
  } catch (err) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(t.photoAddToAlbumFailed(describePhotoError(err, t))),
      ),
    );
  }
}

/// 改相册名（详情页用）
Future<void> showRenameAlbumDialog(
  BuildContext context,
  WidgetRef ref,
  FotoAlbumDto album,
) async {
  final controller = TextEditingController(text: album.name);
  final messenger = ScaffoldMessenger.of(context);
  final t = context.t;
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.photoRenameAlbum),
      content: TextField(
        key: const Key('photo-album-rename'),
        controller: controller,
        autofocus: true,
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: Text(t.actionSave),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty || name == album.name) return;
  try {
    await ref.read(photoAlbumActionsProvider).rename(album.id, name);
    messenger.showSnackBar(SnackBar(content: Text(t.photoRenamed(name))));
  } catch (err) {
    messenger.showSnackBar(
      SnackBar(content: Text(t.photoRenameFailed(describePhotoError(err, t)))),
    );
  }
}

/// 删相册（会二次确认；照片本身不会被删）
Future<void> confirmDeleteAlbum(
  BuildContext context,
  WidgetRef ref,
  FotoAlbumDto album,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final t = context.t;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.photoDeleteAlbumConfirm),
      content: Text(t.photoDeleteAlbumMessage(album.name)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          key: const Key('photo-album-delete-ok'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.dtoActionDelete),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await ref.read(photoAlbumActionsProvider).remove([album.id]);
    messenger.showSnackBar(
      SnackBar(content: Text(t.photoAlbumDeleted(album.name))),
    );
    if (context.mounted) Navigator.of(context).maybePop();
  } catch (err) {
    messenger.showSnackBar(
      SnackBar(content: Text(t.photoDeleteFailed(describePhotoError(err, t)))),
    );
  }
}

// ---------------------------------------------------------------- 文件夹写操作
//
// 文案与官方 Photos 的 chs 语言包逐字对齐（SPK `ui/texts/chs/strings`）：
//   `create_folder` = 创建文件夹、`rename_folder` = 重命名文件夹、
//   `default_folder_name` = 新文件夹、`folder_name` = 文件夹名称、
//   `confirm_delete_item` = "…并将其移入 Drive 的回收站？"（删目录是移回收站，不是永久删）。

/// 「创建文件夹」对话框：`parentId` = 当前目录 id，根目录是 `'0'`
/// （官方 Web 前端就是 `FolderAPI.create({target_id, name})`）。
Future<FotoFolderDto?> showCreateFolderDialog(
  BuildContext context,
  WidgetRef ref, {
  required String parentId,
}) async {
  final t = context.t;
  final controller = TextEditingController(text: t.photoNewFolder);
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: controller.text.length,
  );
  final messenger = ScaffoldMessenger.of(context);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.photoCreateFolder),
      content: TextField(
        key: const Key('photo-folder-name'),
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: t.photoFolderNameHint),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          key: const Key('photo-folder-create-ok'),
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: Text(t.photoCreate),
        ),
      ],
    ),
  );
  // ⚠️ 对话框退场动画期间 TextField 还会重建，这里不 dispose（阅读器同款注释）
  if (name == null) return null;
  if (name.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(t.photoFolderNameRequired)));
    return null;
  }
  try {
    final folder = await ref
        .read(photoFolderActionsProvider)
        .create(parentId: parentId, name: name);
    messenger.showSnackBar(SnackBar(content: Text(t.photoFolderCreated(name))));
    return folder;
  } catch (err) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(t.photoFolderCreateFailed(describePhotoError(err, t))),
      ),
    );
    return null;
  }
}

/// 重命名文件夹（官方 `rename_folder`）
Future<void> showRenameFolderDialog(
  BuildContext context,
  WidgetRef ref,
  FotoFolderDto folder,
) async {
  final controller = TextEditingController(text: folder.name);
  final messenger = ScaffoldMessenger.of(context);
  final t = context.t;
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.photoRenameFolder),
      content: TextField(
        key: const Key('photo-folder-rename'),
        controller: controller,
        autofocus: true,
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: Text(t.actionSave),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty || name == folder.name) return;
  try {
    await ref.read(photoFolderActionsProvider).rename(folder.id, name);
    messenger.showSnackBar(SnackBar(content: Text(t.photoRenamed(name))));
  } catch (err) {
    messenger.showSnackBar(
      SnackBar(content: Text(t.photoRenameFailed(describePhotoError(err, t)))),
    );
  }
}

/// 删除文件夹（二次确认；官方语义是**移入回收站**，不是永久删除）
Future<void> confirmDeleteFolder(
  BuildContext context,
  WidgetRef ref,
  FotoFolderDto folder,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final t = context.t;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.photoDeleteFolderConfirm),
      content: Text(t.photoDeleteFolderMessage(folder.name)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          key: const Key('photo-folder-delete-ok'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.dtoActionDelete),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await ref.read(photoFolderActionsProvider).remove([folder.id]);
    messenger.showSnackBar(
      SnackBar(content: Text(t.photoFolderDeleted(folder.name))),
    );
    // 从文件夹详情页删的 → 退回上一层（根列表里删的不动）
    if (context.mounted) Navigator.of(context).maybePop();
  } catch (err) {
    messenger.showSnackBar(
      SnackBar(content: Text(t.photoDeleteFailed(describePhotoError(err, t)))),
    );
  }
}
