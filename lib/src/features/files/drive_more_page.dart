// Drive「更多」页（P3）：回收站 / 星标 / 共享给我 / 团队文件夹 / **标签**（五段）。
//
// 2026-09-22 收口：本页另加一个 **Office 文档** 直达入口（key `drive-more-office`）——
// 用户拍板「Office 的入口在 Drive 里，官方也没有独立出来」，所以工作台不再有 Office
// 磁贴，入口放回 Drive 家族里（详见 `docs/workspace-expansion-evaluation.md` §10）。
//
// 定位：浏览为主 + 明确的写操作（清空回收站、标签的增删改与打标签），
// 破坏性动作都要二次确认（官方也是）。
//
// 协议事实（真机 2026-09-18 / 09-19，见 `docs/api-server-authoritative.md` §5.1/§5.2）：
//   * `Trash/list` 必须给 `path`（`/mydrive`）且**只能用 v1**；`Trash/get_size` v2；
//   * `Files/list_starred` / `Files/shared_with_me` v3；`TeamFolders/list` v1；
//   * 版本历史 / 共享（个人与链接）/ 标签分别是 `Revisions/list` v1、
//     `Sharing/list|update|create_link` v1、`Labels/*` v1 + `Files/list_labelled` v2
//     —— 参数与编码见 §5.2.1，页面在 `drive_revisions_page.dart` /
//     `drive_share_page.dart` / `drive_labels_page.dart`。
// 注意 `Share/list`（团队文件夹管理）对普通用户回 **105 无权限**，不要调。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/section_pager.dart';
import '../../data/drive_api.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../drive/drive_c1_text.dart';
import '../drive/drive_category_page.dart';
import '../drive/drive_extras_page.dart';
import '../drive/drive_folder_page.dart';
import '../drive/drive_open_entry.dart';
import '../drive/drive_p0_text.dart';
import 'drive_labels_page.dart';
import '../../data/local/file_store.dart' show describeFileError;
import 'drive_browse_view.dart' show driveEntryAsFile;
import 'drive_providers.dart';
import 'file_row.dart' show formatFileTime;
import 'file_thumb.dart' show FileIconTile;
import 'office_page.dart';

/// Office 的必需能力位（`service_registry.dart` 的
/// `StationService.office.requiredApis`）。这里只**读**这个事实，不改服务层：
/// 缺位 → 隐藏「更多」页里的 Office 文档入口（Drive 模块本身照常）。
const String _kOfficeNodeApi = 'SYNO.Office.Node';

/// 分页容器按 index 取视图（顺序 = [DriveMoreSection] 的顺序）
const List<Widget> _sections = [
  _TrashSection(),
  _SimpleListSection(kind: _ListKind.starred),
  _SimpleListSection(kind: _ListKind.shared),
  _SimpleListSection(kind: _ListKind.team),
  _LabelsSection(),
  // P0-5 / P0-6：追加在末尾（前五段 index 不变）
  _SimpleListSection(kind: _ListKind.recent),
  _SimpleListSection(kind: _ListKind.sharedByMe),
];

class DriveMorePage extends ConsumerWidget {
  const DriveMorePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final section = ref.watch(driveMoreSectionProvider);

    // ---- Office 文档入口（2026-09-22 收口：Office 的入口在 Drive 里）
    //
    // 用户拍板原话：「Office 的入口在 Drive 里，为啥要独立出来？官方也没有独立
    // 出来啊？」官方证据：Office 包自述 "Synology Office is a collaboration-focused
    // application … **in Synology Drive**"、带 `drive/hook/libsynoffice_drivehook.so`、
    // 前端有 `SYNO.SDS.Office.Utils.isDrivePage` —— 所以工作台不再给独立磁贴，
    // 「更多」页给一个**直达 Office 文档**的便利入口即可。
    //
    // 能力位纪律（与 C2 的相册入口一致；**绝不动 Drive 模块本身**）：
    //   * 缺 `SYNO.Office.Node`（`absent`）→ 本入口隐藏，Drive 照常（`partial` 语义）；
    //   * `105`/`160`（`unauthorized`）→ 隐藏 + 一句"无权限"提示；
    //   * `119`/`106`（`sessionExpired`）→ 入口**保留但置灰** + 会话提示；
    //   * `unreachable` / `unknown` / 未检测 → 保留（fail-open，不因不确定而隐藏）。
    final availability = ref.watch(serviceAvailabilityProvider);
    final officeState = availability.stateOf(StationService.office);
    final officeVisible =
        !hidesModule(officeState) &&
        !(officeState == AvailabilityState.partial &&
            !availability.hasApi(StationService.office, _kOfficeNodeApi));
    final officeDenied = officeState == AvailabilityState.unauthorized;
    final officeDisabledReason = switch (officeState) {
      AvailabilityState.sessionExpired => t.serviceEntrySessionExpired,
      AvailabilityState.unreachable => t.serviceEntryUnreachable,
      _ => null,
    };

    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: t.calBack,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 标题/副标题各限一行：360x640 + 文字缩放 2.0 下多折一行
                          // 会把固定高度的顶部 Column 顶到 4px 纵向溢出
                          // （`ui_overflow_audit_test` 的 DriveMorePage 用例抓到）。
                          Text(
                            t.driveMoreTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            t.driveSectionHud(section.labelIn(t)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: hud.dim),
                          ),
                        ],
                      ),
                    ),
                    // D23 分类浏览（官方 Home 的四个媒体分类图标）。
                    // 放**头部图标**而不是列表项：列表项在 360x640 + 文字
                    // 缩放 2.0 下会把固定高度的顶部 Column 顶到纵向溢出
                    // （`ui_overflow_audit_test` 抓到过，已修）。
                    IconButton(
                      key: const Key('drive-more-categories'),
                      tooltip: driveC1('driveCategoryEntry', '分类浏览'),
                      icon: const Icon(Icons.category_outlined),
                      onPressed: () => openDriveCategoryPage(context),
                    ),
                    IconButton(
                      key: const Key('drive-more-extras'),
                      tooltip: t.driveMoreTitle,
                      icon: const Icon(Icons.widgets_outlined),
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const DriveExtrasPage(),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: t.photoRefresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: () {
                        ref.invalidate(driveTrashProvider(kDriveRoot));
                        ref.invalidate(driveTrashSizeProvider(kDriveRoot));
                        ref.invalidate(driveStarredProvider(''));
                        ref.invalidate(driveSharedProvider(''));
                        ref.invalidate(driveTeamProvider(''));
                        ref.invalidate(driveRecentProvider(''));
                        ref.invalidate(driveSharedByMeProvider(''));
                      },
                    ),
                  ],
                ),
              ),
              // ---- Office 文档直达入口（在 Drive 家族里，不做独立模块 tab）
              if (officeVisible)
                _OfficeDocsEntry(disabledReason: officeDisabledReason)
              else if (officeDenied)
                const _OfficeDeniedHint(),
              SegmentedChips(
                labels: [
                  for (final s in DriveMoreSection.values) s.labelIn(context.t),
                ],
                index: section.index,
                onChanged: (i) {
                  // 点 chip 和左右滑都要记（以前只有滑才记，点就漏了）
                  track(
                    ref,
                    UsageModule.drive,
                    UsageAction.switchSection,
                    objectType: DriveMoreSection.values[i].name,
                  );
                  ref
                      .read(driveMoreSectionProvider.notifier)
                      .select(DriveMoreSection.values[i]);
                },
              ),
              // 四段之间**左右滑动**切换
              Expanded(
                child: SectionPager(
                  pagerKey: const Key('drive-more-pager'),
                  index: section.index,
                  itemCount: DriveMoreSection.values.length,
                  onIndex: (i) {
                    track(
                      ref,
                      UsageModule.drive,
                      UsageAction.switchSection,
                      objectType: DriveMoreSection.values[i].name,
                    );
                    ref
                        .read(driveMoreSectionProvider.notifier)
                        .select(DriveMoreSection.values[i]);
                  },
                  itemBuilder: (context, i) => _sections[i],
                ),
              ),
            ],
          ),
        ),
    );
  }
}

/// Drive「更多」页里的 **Office 文档直达入口**（不是独立模块 tab）。
///
/// 位置：`DriveMorePage` 头部下方、分段 chips 上方——一眼可见，且不侵入
/// 五个浏览段的语义。点击进入 [OfficePage]（内容 = `DriveBrowseView(officeOnly: true)`）。
///
/// [disabledReason] 非空（会话失效 119/106、网络异常）时**保留但置灰**，
/// 并把原因写在副标题里 —— 绝不因为会话问题隐藏模块（见 service_registry）。
class _OfficeDocsEntry extends StatelessWidget {
  const _OfficeDocsEntry({this.disabledReason});

  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final enabled = disabledReason == null;
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        key: const Key('drive-more-office'),
        enabled: enabled,
        leading: Icon(Icons.description_outlined, color: hud.dim),
        title: Text(driveC1('officeDocsEntry', 'Office 文档')),
        subtitle: Text(
          disabledReason ??
              driveC1(
                'officeDocsEntryHint',
                '只看 Drive 里的 .odoc / .osheet / .oslides',
              ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
        trailing: enabled ? Icon(Icons.chevron_right, color: hud.dim) : null,
        onTap: enabled
            ? () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const OfficePage(title: 'Office'),
                ),
              )
            : null,
      ),
    );
  }
}

/// `105`/`160`（无权限）：Office 文档入口**隐藏**，但给一句原因，避免用户
/// 以为"Drive 里本来就没有 Office"。Drive 模块本身不受影响。
class _OfficeDeniedHint extends StatelessWidget {
  const _OfficeDeniedHint();

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Padding(
      key: const Key('drive-more-office-denied'),
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, 0),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 16, color: hud.dim),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              driveC1(
                'officeDocsNoPermission',
                '无权限访问 Synology Office（Office 文档入口已隐藏）',
              ),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分段 chips（和相册页一个观感；这里自带一份，避免跨模块耦合）
class SegmentedChips extends StatelessWidget {
  const SegmentedChips({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // ★ 第 241 轮（`DA185`，用户裁定 ③）：选中态原来是 `primary@16%` 透在页面底上 ⇒
    //   真机亮色合成 **4.42:1**（低于 AA），与 `DA176`/`DA183` 同一类。
    //   统一改成**不透明** `primarySoft` 底 + `primary` 字。
    final p = DesignPalette.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: Material(
                color: i == index
                    ? p.primarySoft
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(Radii.capsule),
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.capsule),
                  onTap: () => onChanged(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Gap.md,
                      vertical: 7,
                    ),
                    child: Text(
                      labels[i],
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: i == index ? p.primary : null,
                        fontWeight: i == index
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
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

// ---------------------------------------------------------------- 标签

/// 标签段（P3）：和「标签」页共用 `driveLabelsProvider`；
/// 点标签进"这个标签下的文件"，右上角 + 进标签管理页。
class _LabelsSection extends ConsumerWidget {
  const _LabelsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final async = ref.watch(driveLabelsProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  t.drivePersonalLabels(async.value?.length ?? 0),
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: Text(t.driveManageLabels),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(builder: (_) => const DriveLabelsPage()),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, __) => AppEmptyState(
              icon: Icons.error_outline,
              title: t.driveLabelsLoadFailed,
              message: describeFileError(e),
              actionLabel: t.photoRetry,
              onAction: () => ref.invalidate(driveLabelsProvider),
            ),
            data: (labels) => labels.isEmpty
                ? AppEmptyState(
                    icon: Icons.sell_outlined,
                    title: t.noteNoTagsYet,
                    message: t.driveNoLabelsMessage,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: Gap.xl),
                    itemCount: labels.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: hud.dim.withValues(alpha: 0.12),
                    ),
                    itemBuilder: (context, i) {
                      final l = labels[i];
                      return Material(
                        type: MaterialType.transparency,
                        child: DesignRowTile(
                          leading: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: Color(l.colorValue),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          title: Text(
                            l.name,
                            style: theme.textTheme.bodyMedium,
                          ),
                          subtitle: Text(
                            l.isShared
                                ? t.driveSharedLabel
                                : t.drivePersonalLabel,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: hud.dim,
                            ),
                          ),
                          trailing: Icon(Icons.chevron_right, color: hud.dim),
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => DriveLabelledPage(label: l),
                            ),
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

// ---------------------------------------------------------------- 回收站

class _TrashSection extends ConsumerWidget {
  const _TrashSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveTrashProvider(kDriveRoot));
    final size = ref.watch(driveTrashSizeProvider(kDriveRoot)).value ?? 0;
    // 头部这行以**列表**为准：`get_size` 对文件夹常常回 0/空，用它判断
    // "回收站是空的" 会跟下面的列表自相矛盾（真机上踩过）。
    final total = async.value?.total ?? 0;
    final header = total == 0
        ? t.driveTrashEmpty
        : '${t.driveTrashCount(total)}'
              '${size > 0 ? ' · ${t.driveTrashUsage(_bytes(size))}' : ''}';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  header,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ),
              // 按钮必须有界 + 标签可省略：`Row` 的非 flex 子项拿到的是
              // **无界**宽度，英文/大字号下这一行会横向溢出（实测最多 154px）。
              Flexible(
                child: TextButton.icon(
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: Text(
                    t.noteRecycleCleanTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () => _confirmEmpty(context, ref),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, __) => AppEmptyState(
              icon: Icons.error_outline,
              title: t.noteOpenRecycleFailed,
              message: describeFileError(e),
              actionLabel: t.photoRetry,
              onAction: () => ref.invalidate(driveTrashProvider(kDriveRoot)),
            ),
            data: (data) => data.items.isEmpty
                ? AppEmptyState(
                    icon: Icons.delete_outline,
                    title: t.driveTrashEmpty,
                    message: t.driveTrashEmptyMessage,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: Gap.xl),
                    itemCount: data.items.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: hud.dim.withValues(alpha: 0.12),
                    ),
                    itemBuilder: (context, i) =>
                        _DriveMoreRow(entry: data.items[i], inTrash: true),
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmEmpty(BuildContext context, WidgetRef ref) async {
    // 先在 await **之前**把 context 派生的东西取出来（跨 async gap 用 context
    // 是 lint 明令禁止的，真机上也可能拿到已经失效的 Element）
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.driveEmptyTrashConfirm),
        content: Text(t.driveEmptyTrashBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.driveEmptyTrashAction),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      await drive.emptyTrash(path: kDriveRoot);
      ref.invalidate(driveTrashProvider(kDriveRoot));
      ref.invalidate(driveTrashSizeProvider(kDriveRoot));
      messenger.showSnackBar(SnackBar(content: Text(t.driveTrashEmptied)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.driveEmptyTrashFailed(describeFileError(e)))),
      );
    }
  }

  static String _bytes(int b) {
    if (b < 1024) return '$b B';
    const u = ['KB', 'MB', 'GB', 'TB'];
    var v = b / 1024;
    var i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${u[i]}';
  }
}

// ---------------------------------------------------------------- 只读列表

enum _ListKind { starred, shared, team, recent, sharedByMe }

class _SimpleListSection extends ConsumerWidget {
  const _SimpleListSection({required this.kind});

  final _ListKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = switch (kind) {
      _ListKind.starred => driveStarredProvider,
      _ListKind.shared => driveSharedProvider,
      _ListKind.team => driveTeamProvider,
      _ListKind.recent => driveRecentProvider,
      _ListKind.sharedByMe => driveSharedByMeProvider,
    };
    final t = context.t;
    // 团队文件夹是**可选能力**（`TeamFolders`）：能力表明确说没有时，连请求都
    // 不发（避免每次都撞 102），只在本段里说明原因；Drive 其余功能照常。
    //
    // ⚠️ 这一判必须放在 `ref.watch(provider(''))` **之前**：一旦先 watch，
    // 请求就已经发出去了 —— "能力缺失却仍然发请求"正是本批的伪证点之一。
    if (kind == _ListKind.team &&
        !ref
            .watch(serviceAvailabilityProvider)
            .hasApi(StationService.drive, kDriveTeamFoldersApi)) {
      return AppEmptyState(
        icon: Icons.block_outlined,
        title: t.driveNoTeamTitle,
        message: driveGateMessage(DriveEntryGate.unavailable),
      );
    }
    final async = ref.watch(provider(''));
    final (title, message, icon) = switch (kind) {
      _ListKind.starred => (
        t.driveNoStarredTitle,
        t.driveNoStarredMessage,
        Icons.star_border,
      ),
      _ListKind.shared => (
        t.driveNoSharedTitle,
        t.driveNoSharedMessage,
        Icons.people_outline,
      ),
      _ListKind.team => (
        t.driveNoTeamTitle,
        t.driveNoTeamMessage,
        Icons.groups_outlined,
      ),
      // P0-5 / P0-6 的文案走 driveP0（本批不碰 .arb）
      _ListKind.recent => (
        driveP0(DriveP0TextKeys.recentEmptyTitle, '还没有最近记录'),
        driveP0(
          DriveP0TextKeys.recentEmptyMessage,
          '在 Drive 里打开或修改过的文件会出现在这里',
        ),
        Icons.history,
      ),
      _ListKind.sharedByMe => (
        driveP0(DriveP0TextKeys.sharedByMeEmptyTitle, '还没有分享出去的内容'),
        driveP0(
          DriveP0TextKeys.sharedByMeEmptyMessage,
          '你在 Drive 里共享给他人的文件会出现在这里',
        ),
        Icons.ios_share,
      ),
    };
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      // 降级：105/160（无权限）与 102/103（服务端没有该方法）都**不让整页塌**，
      // 只在这段里说明原因；其余错误照常走 describeFileError。
      error: (e, __) {
        final gate = driveEntryGate(e);
        final gated = gate != DriveEntryGate.available;
        return AppEmptyState(
          icon: gated ? Icons.block_outlined : Icons.error_outline,
          title: gated ? title : t.driveListOpenFailed,
          message: gated ? driveGateMessage(gate) : describeFileError(e),
          actionLabel: t.photoRetry,
          onAction: () => ref.invalidate(provider('')),
        );
      },
      data: (data) => data.items.isEmpty
          ? AppEmptyState(icon: icon, title: title, message: message)
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: Gap.xl),
              itemCount: data.items.length,
              separatorBuilder: (_, __) => const SizedBox(height: Gap.xs),
              itemBuilder: (context, i) => _DriveMoreRow(entry: data.items[i]),
            ),
    );
  }
}

/// 「更多」里的一行：图标 + 名字 + 时间/大小；点开复用统一预览页。
class _DriveMoreRow extends ConsumerWidget {
  const _DriveMoreRow({required this.entry, this.inTrash = false});

  final DriveEntryDto entry;
  final bool inTrash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final api = ref.read(driveApiProvider);
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        leading: SizedBox(
          width: 40,
          height: 40,
          child: FileIconTile(
            entry: driveEntryAsFile(entry),
            size: 40,
            iconSize: 20,
          ),
        ),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (entry.isDir) t.photoFolder else _bytes(entry.size),
            if (entry.modifiedTime > 0)
              formatFileTime(entry.modifiedTime, t: t),
            if (inTrash) t.driveDeleted,
          ].join(' · '),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
        trailing: inTrash && entry.isDir
            ? null
            : const Icon(Icons.chevron_right, size: 18),
        // P0-3 / P0-6：目录行**可点进去**（团队文件夹以前是 `onTap: null`）。
        // 进入后走 `Files/list` + `path=id:<file_id>`（官方 Web/APK 同款），
        // 见 `drive_folder_page.dart` 顶部的原文说明。
        //
        // ★ DA10（r355 真机取证）：**回收站里的目录行不许再点进去** ——
        // 那一条 `file_id` 是 `Trash/list` 回的**回收站条目 id**，拿它去发
        // `Files/list path=id:<…>` **必然**回 1003（真机像素：`Cannot open
        // this folder`）。给一个必然报错的入口就是 D27 那一类缺陷。
        // 关掉它**不减少任何可用能力**：这个页面本来就没有"还原/打开回收站
        // 目录"的动作（还原通道 `DriveApi.restoreTrash` 至今零调用点 =
        // DA10c，另案登记）；文件行仍可点开预览，不受影响。
        onTap: api == null || (inTrash && entry.isDir)
            ? null
            : entry.isDir
            ? () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => DriveFolderPage(
                    rootFileId: entry.fileId,
                    title: entry.name,
                  ),
                ),
              )
            // 文件：统一入口（含 P0-11 的加密 Office 探测）
            : () => driveOpenEntry(context, ref, entry),
      ),
    );
  }

  static String _bytes(int b) {
    if (b < 1024) return '$b B';
    const u = ['KB', 'MB', 'GB', 'TB'];
    var v = b / 1024;
    var i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${u[i]}';
  }
}

