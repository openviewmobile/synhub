// Drive 搜索页（P0-4）。**每个筛选字段都有官方原文才做**。
//
// 官方原文（APK `ApiSynoDriveFiles.java:724-796` `setAsListSearch` + 官方 Web
// `synodrive_common.js:18` 的 `fillSearch*` 系列，两处键名完全一致）：
//   * 关键词 `keyword`（空则不搜，服务端 120）；
//   * 位置 `location`（`any/mydrive/team_folders/shared_with_me/
//     shared_with_others/starred/custom`，`SearchCondition.java:659-667`）+
//     `custom_location`（`id:<folder_id>`，`:736-737`）；
//   * 类型 `file_type`（`any/folder/file/odoc/osheet/oslides/document/image/
//     audio/video/custom`，`:748-758`）+ `custom_file_type`（扩展名）；
//   * 拥有者 `owner`（`any/me/not_me/custom`，`:912-915`）+ `custom_owner`
//     （`{type:'user',name}`）；
//   * 大小 `min_size`/`max_size`（**字节**；UI 输入 MB × 1048576，`:756`）；
//     "约等于" = 官方 `EqualTo` 的 ±5% 带（`:762-766`，容差 `:133`）；
//   * 时间 `time`（`modified_time`/`created_time`，`:1062-1064`）+
//     `start_date`/`end_date`（epoch 秒；官方 to 端补到 23:59:59）；
//   * 标签 `labels`（label_id 数组，`:768-771`）；
//   * `content_snippet`：APK 恒定 `true`（`:791`），本实现照抄（无开关）。
//
// 检索范围取"当前浏览到的位置"用 `location=custom` + 当前目录 id：官方另有独立
// 的 `location=current`，但其上行依赖"当前节点上下文"，本批不实现（见
// `drive_search_dto.dart` 的说明与文档"未实现/未验证"清单）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/drive_label_dto.dart';
import '../../data/dto/drive_search_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../files/drive_browse_view.dart' show driveEntryAsFile;
import '../files/drive_providers.dart';
import '../files/file_row.dart' show formatFileTime;
import '../files/file_thumb.dart' show FileIconTile;
import 'drive_folder_page.dart';
import 'drive_gaps_stores.dart';
import 'drive_gaps_text.dart';
import 'drive_open_entry.dart';
import 'drive_p0_text.dart';

class DriveSearchPage extends ConsumerStatefulWidget {
  const DriveSearchPage({super.key});

  @override
  ConsumerState<DriveSearchPage> createState() => _DriveSearchPageState();
}

class _DriveSearchPageState extends ConsumerState<DriveSearchPage> {
  final TextEditingController _keyword = TextEditingController();
  final TextEditingController _size = TextEditingController();

  /// 已提交的条件（`null` = 还没搜过，显示引导）
  DriveSearchQuery? _query;

  /// "当前文件夹" 解析出来的目录 id（`location=custom` 用）
  String _currentFolderId = '';

  @override
  void initState() {
    super.initState();
    // D51：读回本地搜索历史（存储不可用时静默为空表）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(driveSearchHistoryProvider.notifier).preload();
    });
  }

  @override
  void dispose() {
    _keyword.dispose();
    _size.dispose();
    super.dispose();
  }

  DriveSearchQuery get _draft => (_query ?? const DriveSearchQuery()).copyWith(
    keyword: _keyword.text,
  );

  bool _isBlank(DriveSearchQuery q) =>
      q.keyword.trim().isEmpty &&
      q.location == DriveSearchLocation.any &&
      q.fileType == DriveSearchFileType.any &&
      q.owner == DriveSearchOwner.any &&
      q.size == DriveSearchSize.any &&
      q.date == DriveSearchDate.any &&
      q.labelIds.isEmpty;

  void _submit() {
    final q = _draft.copyWith(sizeMegabytes: int.tryParse(_size.text) ?? 0);
    if (_isBlank(q)) {
      // 官方对空条件回 120；我们先拦，不发无效请求
      setState(() => _query = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            driveP0(
              DriveP0TextKeys.searchNeedCondition,
              '请输入关键词，或至少选择一个筛选条件',
            ),
          ),
        ),
      );
      return;
    }
    setState(() {
      _query = q;
      // 已在"当前文件夹"上选过：把目录 id 带上
      if (q.location == DriveSearchLocation.custom &&
          _currentFolderId.isNotEmpty) {
        _query = q.copyWith(customLocationId: _currentFolderId);
      }
    });
    // D51：记住这次关键词（本地持久化；空关键词会被 record 忽略）
    ref.read(driveSearchHistoryProvider.notifier).record(q.keyword);
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final q = _query;
    return Scaffold(
      key: const Key('drive-search-page'),
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(driveP0(DriveP0TextKeys.searchTitle, '搜索')),
        leading: IconButton(
          tooltip: t.calBack,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          IconButton(
            key: const Key('drive-search-submit'),
            tooltip: driveP0(DriveP0TextKeys.searchTitle, '搜索'),
            icon: const Icon(Icons.search),
            onPressed: _submit,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: TextField(
              key: const Key('drive-search-field'),
              controller: _keyword,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: driveP0(
                  DriveP0TextKeys.searchHint,
                  '搜索文件与文件夹',
                ),
                prefixIcon: const Icon(Icons.search),
              ),
            ),
          ),
          _filters(theme, hud),
          Expanded(
            child: q == null
                ? _historyOrEmpty(t)
                : ref
                      .watch(driveSearchQueryProvider(q))
                      .when(
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (e, _) => AppEmptyState(
                          icon: Icons.error_outline,
                          title: driveP0(
                            DriveP0TextKeys.searchFailed,
                            '搜索失败',
                          ),
                          message: describeFileError(e),
                          actionLabel: t.photoRetry,
                          onAction: () =>
                              ref.invalidate(driveSearchQueryProvider(q)),
                        ),
                        data: (data) => data.items.isEmpty
                            ? AppEmptyState(
                                icon: Icons.search_off,
                                title: driveP0(
                                  DriveP0TextKeys.searchEmptyTitle,
                                  '没有找到匹配项',
                                ),
                                message: driveP0(
                                  DriveP0TextKeys.searchEmptyMessage,
                                  '换个关键词或放宽筛选条件再试',
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.only(
                                  bottom: Gap.xl,
                                ),
                                itemCount: data.items.length,
                                separatorBuilder: (_, _) => Divider(
                                  height: 1,
                                  color: hud.dim.withValues(alpha: 0.12),
                                ),
                                itemBuilder: (context, i) =>
                                    _row(data.items[i]),
                              ),
                      ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 筛选条

  /// D51：还没搜过时，优先展示"最近搜索"；没有历史才给引导空态。
  Widget _historyOrEmpty(AppText t) {
    final hud = DesignPalette.of(context);
    final history = ref.watch(driveSearchHistoryProvider);
    if (history.isEmpty) {
      return AppEmptyState(
        icon: Icons.search,
        title: driveP0(DriveP0TextKeys.searchTitle, '搜索'),
        message: driveP0(DriveP0TextKeys.searchHint, '搜索文件与文件夹'),
      );
    }
    return ListView(
      key: const Key('drive-search-history'),
      padding: const EdgeInsets.only(bottom: Gap.xl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  driveGap(DriveGapTextKeys.searchHistoryTitle, '最近搜索'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton(
                key: const Key('drive-search-history-clear'),
                onPressed: () =>
                    ref.read(driveSearchHistoryProvider.notifier).clear(),
                child: Text(
                  driveGap(DriveGapTextKeys.searchHistoryClear, '清除'),
                ),
              ),
            ],
          ),
        ),
        for (final k in history)
          DesignRowTile(
            key: Key('drive-search-history-$k'),
            dense: true,
            leading: Icon(Icons.history, size: 18, color: hud.dim),
            title: Text(k, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              _keyword.text = k;
              _submit();
            },
            trailing: IconButton(
              tooltip: driveGap(DriveGapTextKeys.searchHistoryClear, '清除'),
              icon: Icon(Icons.close, size: 16, color: hud.dim),
              onPressed: () =>
                  ref.read(driveSearchHistoryProvider.notifier).remove(k),
            ),
          ),
      ],
    );
  }

  Widget _filters(ThemeData theme, DesignPalette hud) {
    final q = _draft;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
      child: Row(
        children: [
          _menu<DriveSearchLocation>(
            key: 'location',
            label: driveP0(DriveP0TextKeys.searchLocation, '位置'),
            value: q.location,
            items: DriveSearchLocation.values,
            text: (v) => switch (v) {
              DriveSearchLocation.any => driveP0(
                DriveP0TextKeys.searchLocationAny,
                '任意位置',
              ),
              DriveSearchLocation.myDrive => driveP0(
                DriveP0TextKeys.searchLocationMyDrive,
                '我的文件',
              ),
              DriveSearchLocation.teamFolders => driveP0(
                DriveP0TextKeys.searchLocationTeamFolders,
                '团队文件夹',
              ),
              DriveSearchLocation.sharedWithMe => driveP0(
                DriveP0TextKeys.searchLocationSharedWithMe,
                '共享给我',
              ),
              DriveSearchLocation.sharedWithOthers => driveP0(
                DriveP0TextKeys.searchLocationSharedByMe,
                '我共享的',
              ),
              DriveSearchLocation.starred => driveP0(
                DriveP0TextKeys.searchLocationStarred,
                '星标',
              ),
              DriveSearchLocation.custom => driveP0(
                DriveP0TextKeys.searchLocationCurrent,
                '当前文件夹',
              ),
            },
            onPick: (v) async {
              var id = '';
              if (v == DriveSearchLocation.custom) {
                id = await _resolveCurrentFolderId();
                if (id.isEmpty) return; // 解析不到就不改条件（绝不发坏参数）
              }
              _currentFolderId = id;
              setState(() => _query = _draft.copyWith(location: v));
            },
          ),
          _menu<DriveSearchFileType>(
            key: 'type',
            label: driveP0(DriveP0TextKeys.searchType, '类型'),
            value: q.fileType,
            items: DriveSearchFileType.values,
            text: (v) => switch (v) {
              DriveSearchFileType.any => driveP0(
                DriveP0TextKeys.searchTypeAny,
                '任意类型',
              ),
              DriveSearchFileType.folder => driveP0(
                DriveP0TextKeys.searchTypeFolder,
                '文件夹',
              ),
              DriveSearchFileType.file => driveP0(
                DriveP0TextKeys.searchTypeFile,
                '文件',
              ),
              DriveSearchFileType.odoc => driveP0(
                DriveP0TextKeys.searchTypeOdoc,
                'Synology 文档',
              ),
              DriveSearchFileType.osheet => driveP0(
                DriveP0TextKeys.searchTypeOsheet,
                'Synology 表格',
              ),
              DriveSearchFileType.oslide => driveP0(
                DriveP0TextKeys.searchTypeOslide,
                'Synology 幻灯片',
              ),
              DriveSearchFileType.document => driveP0(
                DriveP0TextKeys.searchTypeDocument,
                '文档',
              ),
              DriveSearchFileType.image => driveP0(
                DriveP0TextKeys.searchTypeImage,
                '图片',
              ),
              DriveSearchFileType.audio => driveP0(
                DriveP0TextKeys.searchTypeAudio,
                '音频',
              ),
              DriveSearchFileType.video => driveP0(
                DriveP0TextKeys.searchTypeVideo,
                '视频',
              ),
              DriveSearchFileType.custom => driveP0(
                DriveP0TextKeys.searchTypeFile,
                '文件',
              ),
            },
            onPick: (v) async => setState(
              () => _query = _draft.copyWith(fileType: v),
            ),
          ),
          _menu<DriveSearchOwner>(
            key: 'owner',
            label: driveP0(DriveP0TextKeys.searchOwner, '拥有者'),
            value: q.owner,
            items: const [
              DriveSearchOwner.any,
              DriveSearchOwner.me,
              DriveSearchOwner.notMe,
            ],
            text: (v) => switch (v) {
              DriveSearchOwner.any => driveP0(
                DriveP0TextKeys.searchOwnerAny,
                '任何人',
              ),
              DriveSearchOwner.me => driveP0(
                DriveP0TextKeys.searchOwnerMe,
                '我',
              ),
              DriveSearchOwner.notMe => driveP0(
                DriveP0TextKeys.searchOwnerNotMe,
                '不是我',
              ),
              DriveSearchOwner.custom => driveP0(
                DriveP0TextKeys.searchOwnerAny,
                '任何人',
              ),
            },
            onPick: (v) async => setState(() => _query = _draft.copyWith(owner: v)),
          ),
          _menu<DriveSearchSize>(
            key: 'size',
            label: driveP0(DriveP0TextKeys.searchSize, '大小'),
            value: q.size,
            items: DriveSearchSize.values,
            text: (v) => switch (v) {
              DriveSearchSize.any => driveP0(
                DriveP0TextKeys.searchSizeAny,
                '不限',
              ),
              DriveSearchSize.greaterThan => driveP0(
                DriveP0TextKeys.searchSizeGreater,
                '大于',
              ),
              DriveSearchSize.lessThan => driveP0(
                DriveP0TextKeys.searchSizeLess,
                '小于',
              ),
              DriveSearchSize.roughly => driveP0(
                DriveP0TextKeys.searchSizeEqual,
                '约等于',
              ),
            },
            onPick: (v) async => setState(
              () => _query = _draft.copyWith(
                size: v,
                sizeMegabytes: int.tryParse(_size.text) ?? 0,
              ),
            ),
          ),
          if (q.size != DriveSearchSize.any) ...[
            SizedBox(
              width: 88,
              child: TextField(
                key: const Key('drive-search-size-mb'),
                controller: _size,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  isDense: true,
                  suffixText: driveP0(DriveP0TextKeys.searchSizeUnit, 'MB'),
                ),
              ),
            ),
            const SizedBox(width: Gap.sm),
          ],
          _menu<DriveSearchDate>(
            key: 'date',
            label: driveP0(DriveP0TextKeys.searchDate, '时间'),
            value: q.date,
            items: DriveSearchDate.values,
            text: (v) => switch (v) {
              DriveSearchDate.any => driveP0(
                DriveP0TextKeys.searchDateAny,
                '不限时间',
              ),
              DriveSearchDate.modified => driveP0(
                DriveP0TextKeys.searchDateModified,
                '修改时间',
              ),
              DriveSearchDate.created => driveP0(
                DriveP0TextKeys.searchDateCreated,
                '创建时间',
              ),
            },
            onPick: _pickDate,
          ),
          _menu<int>(
            key: 'labels',
            label: driveP0(DriveP0TextKeys.searchLabel, '标签'),
            value: q.labelIds.length,
            items: const [], // 标签走弹层多选，不用这个菜单的项
            text: (_) => q.labelIds.isEmpty
                ? driveP0(DriveP0TextKeys.searchLabel, '标签')
                : '${driveP0(DriveP0TextKeys.searchLabel, '标签')}'
                      ' (${q.labelIds.length})',
            onPick: (_) async => _pickLabels(),
          ),
        ],
      ),
    );
  }

  /// 一个筛选轴 = 一个下拉菜单（chip 观感）
  Widget _menu<T>({
    required String key,
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) text,
    required Future<void> Function(T) onPick,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final active = items.isEmpty ? false : value != items.first;
    return Padding(
      padding: const EdgeInsets.only(right: Gap.sm),
      child: PopupMenuButton<T>(
        key: Key('drive-search-filter-$key'),
        onSelected: (v) => onPick(v),
        itemBuilder: (_) => [
          for (final v in items)
            PopupMenuItem<T>(
              key: Key('drive-search-filter-$key-${v.toString().split('.').last}'),
              value: v,
              child: Text(text(v)),
            ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.md,
            vertical: 7,
          ),
          decoration: BoxDecoration(
            // ★ `DA186`：不透明 `primarySoft`（半透明叠底只有 4.4:1）
            color: active
                ? DesignPalette.of(context).primarySoft
                : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(Radii.capsule),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                active ? context.t.driveSearchFilterActive(label, text(value)) : label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: active ? DesignPalette.of(context).primary : null,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const Icon(Icons.arrow_drop_down, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  /// "当前文件夹" → 用当前 Drive 栈路径换 `file_id`（`Files/get`，官方同款）
  Future<String> _resolveCurrentFolderId() async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return '';
    final path = ref.read(driveStackProvider).last;
    try {
      return (await drive.get(path: path)).fileId;
    } catch (_) {
      return '';
    }
  }

  /// 时间轴：官方 `start_date`/`end_date`（epoch 秒，to 端到当天 23:59:59）
  Future<void> _pickDate(DriveSearchDate v) async {
    if (v == DriveSearchDate.any) {
      setState(
        () => _query = _draft.copyWith(
          date: v,
          startTime: 0,
          endTime: 0,
        ),
      );
      return;
    }
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10),
      lastDate: now,
    );
    if (range == null) return;
    setState(() {
      _query = _draft.copyWith(
        date: v,
        startTime: range.start.millisecondsSinceEpoch ~/ 1000,
        // 官方把结束日补到 23:59:59
        endTime:
            DateTime(
              range.end.year,
              range.end.month,
              range.end.day,
              23,
              59,
              59,
            ).millisecondsSinceEpoch ~/
            1000,
      );
    });
  }

  /// 标签多选（官方 `labels` = label_id 数组）
  Future<void> _pickLabels() async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    List<DriveLabelDto> labels;
    try {
      labels = await drive.listLabels();
    } catch (_) {
      return;
    }
    if (!mounted || labels.isEmpty) return;
    final picked = {..._draft.labelIds};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(driveP0(DriveP0TextKeys.searchLabel, '标签')),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final l in labels)
                DesignCheckRow(
                  key: Key('drive-search-label-${l.labelId}'),
                  value: picked.contains(l.labelId),
                  title: Text(l.name),
                  onChanged: (on) => on == true
                      ? picked.add(l.labelId)
                      : picked.remove(l.labelId),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.t.actionSave),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(
      () => _query = _draft.copyWith(labelIds: picked.toList(growable: false)),
    );
  }

  Widget _row(DriveEntryDto e) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    return DesignRowTile(
      key: Key('drive-search-result-${e.fileId}'),
      leading: SizedBox(
        width: 40,
        height: 40,
        child: FileIconTile(
          entry: driveEntryAsFile(e),
          size: 40,
          iconSize: 20,
        ),
      ),
      title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      // ★ D49：内容搜索的命中片段。
      //
      // 官方把服务端高亮后的片段放在回包字段 `content_snippet` 里
      // （`api/response/FileInfoVo.java:19`），官方 UI 也把它显示在结果行上。
      // **只有内容搜索**（服务端真读了文件）才有值；文件名搜索/列表/最近
      // 一律为空 ⇒ 用 `if` 条件构造，无片段时这一行**完全不存在**
      // （不留空行、不占位）。
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            [
              if (e.isDir) t.photoFolder else e.humanSize,
              if (e.displayPath.isNotEmpty) e.displayPath,
              if (e.modifiedTime > 0) formatFileTime(e.modifiedTime, t: t),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: hud.dim),
          ),
          if (e.snippet.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                e.snippet,
                key: Key('drive-search-snippet-${e.fileId}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: hud.dim),
              ),
            ),
        ],
      ),
      onTap: e.isDir
          ? () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) =>
                    DriveFolderPage(rootFileId: e.fileId, title: e.name),
              ),
            )
          : () => driveOpenEntry(context, ref, e),
    );
  }
}
