// Office 批 D 接线层（**只做入口/导航/能力门控**，不改 `office_library.dart` 的
// widget 内部逻辑）。
//
// 背景：批 D 交付了 `OfficeTemplateLibraryView` / `OfficeThemePickerView` /
// `OfficeVersionListView`，但被限定在禁区外、**没有接入口**。本文件把它们接到
// 既有的 Office / Drive 入口上：
//   * 「模板库」→ `OfficePage` 的 AppBar（`office-page-templates`）；
//   * 「主题」  → Drive 行菜单的 Office 原生文档（`office_theme`，只对 `.oslides`）；
//   * 「版本记录（只读）」→ Drive 行菜单的 Office 原生文档（`office_versions_readonly`）。
//
// 纪律（与批 D 一致）：
//   * **不新造打开逻辑**：从模板新建成功后把回包解析成 [DriveEntryDto]，
//     直接走既有的 [driveOpenEntry]（加密探测 / `.odoc`·`.osheet`·`.oslides`
//     分流 / 统一预览全在里面）；
//   * **不新造门控**：能力判定复用 `service_registry` /
//     `ServiceAvailabilitySnapshot`（见下面两个 `*Available` 函数），
//     版本门控直接复用既有的 `kOfficeVersionApi`；
//   * **不显示会报错的按钮**：能力缺失时入口整个隐藏；模板为空 / 主题为空 /
//     版本为空都由批 D 的 widget 给出明确空态。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart' show kOfficeVersionApi;
import '../../core/theme/app_tokens.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/office_api.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../drive/drive_open_entry.dart';
import '../files/office_providers.dart';
import 'office_library.dart';
import '../../core/user_facing_error.dart';

/// `Office.Template` 能力位（`Template:list/get/make` 同属一张表）。
///
/// 为什么**不**登记进 `service_registry.dart`：该文件在本任务是禁改区，
/// 而登记表本身是"每个 [StationService] 的必需/可选 API 向量"。这两个 API
/// 不在既有向量里 → 走既有的**横切能力位**通道
/// [ServiceAvailabilitySnapshot.apiPresent]（`service_registry.dart` 顶部注释
/// 就是为 `SYNO.Finder.*` 这类"不在向量里"的能力准备的，语义相同：
/// 只有"拿到过能力表且表里明确没有"才隐藏，未检测/检测失败一律 fail-open）。
///
/// 为什么不用 `hasApi(StationService.office, …)`：那个 API 对 `absent`/
/// `unknown` 一律 fail-open（返回 true），在**没装 Office 的 NAS** 上会漏出入口；
/// 这里要的是"表里明确没有就隐藏"，所以用 [ServiceAvailabilitySnapshot.apiPresent]。
const String kOfficeTemplateApi = 'SYNO.Office.Template';

/// `Office.Theme` 能力位（`Theme:list/apply`）。判定语义同 [kOfficeTemplateApi]。
const String kOfficeThemeApi = 'SYNO.Office.Theme';

/// `Template:make` 的目标目录：真机唯一取证过的形态是 `"/mydrive"` 路径串
/// （`docs/office-doc-render-batch-d.md` §6-13；`id:<folder_id>` 形态未取证）。
/// 传别的形态属于"猜参数"，所以这里钉死取证值。
const String kOfficeTemplateMakeParentId = '/mydrive';

/// 「模板库」入口是否显示（能力缺失 → **隐藏**，不是点了报错）。
bool officeTemplateLibraryAvailable(ServiceAvailabilitySnapshot availability) =>
    availability.apiPresent(kOfficeTemplateApi);

/// 「主题」入口是否显示。判定语义同上。
bool officeThemePickerAvailable(ServiceAvailabilitySnapshot availability) =>
    availability.apiPresent(kOfficeThemeApi);

/// **只读**版本列表通道是否可用（`SYNO.Office.Node.Version` 在能力表里）。
///
/// 与完整版本页的能力判据**不是一回事**：完整页（可还原/命名/导出）除这个 API
/// 外还需要 Office 原生文档带 `permanent_link`（见 `drive_browse_view.dart` 的
/// `officeFullVersions`）。两个入口**降级互补、绝不同时出现**：
/// 完整可用 → 只显示完整；完整不可用而这里可用 → 只显示只读；都不可用 → 都不显示。
///
/// 判定走既有的**横切能力位** [ServiceAvailabilitySnapshot.apiPresent]
/// （`kOfficeVersionApi` 虽在 `service_registry.dart` 的 Office 向量里，但这里要的
/// 是"只读通道"这一横切语义：未检测/空表 fail-open，表里明确没有才隐藏）。
bool officeReadOnlyVersionsAvailable(
  ServiceAvailabilitySnapshot availability,
) => availability.apiPresent(kOfficeVersionApi);

/// 把 `Template:make` 的回包解析成可交给 [driveOpenEntry] 的条目。
///
/// 回包缺 `file_id` 时返回 `null`：宁可如实提示"没有返回可打开的节点"，
/// 也**不**拿半截数据去打开（否则会落到错的文档/空文档）。
///
/// ★★ 第 317 轮真机缺陷（D13，已修）：`Template:make` v1 的回包**只有**
/// `file_id` / `link_id` / `display_path` / `perm`（第 258 轮写探针只取过 `file_id`；
/// 本轮真机 UI 复现：新建**成功**却弹「已新建，但服务端没有返回可打开的节点」、
/// 新文档没被打开）。而 [driveOpenEntry] 会用 `display_path` 映射 File Station
/// 真实路径（`/mydrive/x` → `/home/Drive/x`）——**这条路不依赖 Drive 索引**
/// （真机实测：新建的文件能立刻按 File Station 路径打开，而 `Files:list` 26 分钟后
/// 仍未收录它）⇒ 名字可由 `display_path` 的末段补出。
DriveEntryDto? officeEntryFromMadeNode(Map<String, dynamic> node) {
  final entry = DriveEntryDto.fromJson(node);
  if (entry.fileId.isEmpty) return null;
  if (entry.name.isNotEmpty) return entry;
  if (entry.displayPath.isEmpty) return null;
  final derived = officePathBasename(entry.displayPath);
  if (derived.isEmpty) return null;
  final withName = DriveEntryDto.fromJson({...node, 'name': derived});
  if (withName.fileId.isEmpty || withName.name.isEmpty) return null;
  return withName;
}

/// 路径末段（`/mydrive/我的发票.odoc` → `我的发票.odoc`）；空串/纯 `/` → 空串。
String officePathBasename(String path) {
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final i = trimmed.lastIndexOf('/');
  return i < 0 ? trimmed : trimmed.substring(i + 1);
}

// ---------------------------------------------------------------------------
// 模板库
// ---------------------------------------------------------------------------

/// 服务端模板库页（`Office.Template:list` + 「从模板新建」）。
///
/// 从模板新建成功后**落到新建出来的文档**：解析回包 → [driveOpenEntry]
/// （复用既有打开路径，不新写一套）。
class OfficeTemplateLibraryPage extends ConsumerStatefulWidget {
  const OfficeTemplateLibraryPage({
    super.key,
    this.parentId = kOfficeTemplateMakeParentId,
    this.typeFilter,
    this.encrypt = false,
    this.password = '',
  });

  /// `Template:make` 的 `parent_id`。
  ///
  /// 默认 [kOfficeTemplateMakeParentId]（`/mydrive`，真机唯一取证过的形态）；
  /// 从 Drive 目录里进来时给**当前目录的 Drive 路径**（同一种形态）。
  final String parentId;

  /// 只列该类型的模板（`null` = 三种都列）。
  ///
  /// 判定与官方 `SYNO.SDS.Office.Utils.getNTypeByObjectId` 一致
  /// （`.doc` / `.sh` / `.slide`），服务端 `ntype` 一致时也算命中。
  final OfficeNodeType? typeFilter;

  /// **加密新建**：官方 `makeTemplate` 白名单里 `encrypt` + `password` 与
  /// `object_id`/`parent_id` 同级（`ui.doc.js`）—— 与普通模板是同一个方法。
  final bool encrypt;
  final String password;

  @override
  ConsumerState<OfficeTemplateLibraryPage> createState() =>
      _OfficeTemplateLibraryPageState();
}

class _OfficeTemplateLibraryPageState
    extends ConsumerState<OfficeTemplateLibraryPage> {
  late Future<List<OfficeTemplateDto>> _future;

  @override
  void initState() {
    super.initState();
    trackView(UsageModule.office, screen: 'template_gallery');
    _future = _load();
  }

  Future<List<OfficeTemplateDto>> _load() async {
    final api = ref.read(officeApiProvider);
    if (api == null) return const <OfficeTemplateDto>[];
    final all = await api.templateList();
    final filter = widget.typeFilter;
    if (filter == null) return all;
    // 服务端 `ntype` 与 `object_id` 后缀两路都认（后者是官方前端的判据）。
    return [
      for (final t in all)
        if (t.ntype == filter.value ||
            officeNodeTypeFromObjectId(t.objectId) == filter)
          t,
    ];
  }

  void _refresh() => setState(() => _future = _load());

  Future<Map<String, dynamic>> _make(
    OfficeTemplateDto template,
    String? title,
  ) {
    final api = ref.read(officeApiProvider);
    if (api == null) {
      throw StateError(officeLibraryText('officeLibraryNotConnected', '未连接'));
    }
    return api.templateMake(
      parentId: widget.parentId,
      objectId: template.objectId,
      title: title,
      encrypt: widget.encrypt,
      password: widget.password,
    );
  }

  Future<void> _onCreated(
    OfficeTemplateDto template,
    Map<String, dynamic> node,
  ) async {
    final entry = officeEntryFromMadeNode(node);
    if (!mounted) return;
    if (entry == null) {
      // 回包不可用：如实提示，**不**去打开别的东西
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            officeLibraryText(
              'officeTemplateMakeUnopened',
              '已新建，但服务端没有返回可打开的节点',
            ),
          ),
        ),
      );
      return;
    }
    await driveOpenEntry(context, ref, entry);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('office-template-library-page'),
      backgroundColor: DesignPalette.of(context).bg,
      appBar: AppBar(
        title: Text(
          widget.encrypt
              ? officeLibraryText(
                  'officeTemplateLibraryEncryptedTitle',
                  '从模板新建（加密）',
                )
              : officeLibraryText('officeTemplateLibraryTitle', '模板库'),
        ),
        actions: [
          IconButton(
            key: const Key('office-template-library-refresh'),
            tooltip: officeLibraryText('officeLibraryRefresh', '刷新'),
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<OfficeTemplateDto>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              // 骨架屏（官方 `#e2e6ea` 底色 + 与真网格同形）——比转圈更不跳动。
              return const OfficeTemplateGridSkeleton();
            }
            if (snap.hasError) {
              return Center(
                key: const Key('office-template-library-error'),
                child: Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        officeLibraryText(
                          'officeTemplateLibraryLoadFailed',
                          '模板库加载失败：${snap.error}',
                        ).replaceAll('{error}', '${snap.error}'),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: Gap.md),
                      FilledButton(
                        key: const Key('office-template-library-retry'),
                        onPressed: _refresh,
                        child: Text(
                          officeLibraryText('officeLibraryRetry', '重试'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
            // 空列表由批 D 的 widget 给明确空态（`office-template-library-empty`）；
            // 缩略图走官方 `Template.Thumb:get`（真机 PNG）；未连接时 fetcher 为
            // null ⇒ 卡片只显示占位，**不发请求**（不假装有图）。
            final api = ref.read(officeApiProvider);
            return OfficeTemplateLibraryView(
              templates: snap.data ?? const <OfficeTemplateDto>[],
              makeTemplate: _make,
              encrypt: widget.encrypt,
              // 类型筛选偏好（稳定 id：`all` / `doc` / `sheet` / `presentation`）。
              onFilterChanged: (ntype) => trackSelect(
                UsageModule.office,
                ntype ?? 'all',
                kind: 'template',
              ),
              thumbFetcher: api == null
                  ? null
                  : ({required objectId, ver, required retina}) =>
                        api.templateThumbBytes(
                          objectId: objectId,
                          ver: ver,
                          retina: retina,
                        ),
              // ★ 第 265 轮：**正文预览**（官方 `Export/download {object_id,
              // format:"ms"}`，只读）。api 为 null（未连接）时不给 ⇒ 预览
              // 保持纯缩略图模式，不假装有正文。
              bodyFetcher: api == null
                  ? null
                  : (template) => api.templateExportBytes(
                      objectId: template.objectId,
                    ),
              onTemplateCreated: (template, node) =>
                  unawaited(_onCreated(template, node)),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 主题
// ---------------------------------------------------------------------------

/// 某个演示文稿的**服务端主题**选择页（`Office.Theme:list` + `Theme:apply`）。
///
/// `Theme:apply` 只认 Office 域内的 `object_id`（形如 `1028_…`，不是 Drive 的
/// `file_id`）——复用既有的 [OfficeApi.resolveObjectId]（`Node:get {path}`）解析；
/// 解析不到就**不发请求**，如实报错（宁可报错也不发一个形态已知不对的 id）。
class OfficeThemesPage extends ConsumerStatefulWidget {
  const OfficeThemesPage({
    super.key,
    required this.entry,
    this.ntype = 'presentation',
  });

  final DriveEntryDto entry;

  /// 主题类型；真机只取证过 `presentation`（`themeList` 17 套）。
  final String ntype;

  @override
  ConsumerState<OfficeThemesPage> createState() => _OfficeThemesPageState();
}

class _OfficeThemesPageState extends ConsumerState<OfficeThemesPage> {
  late Future<List<OfficeThemeDto>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<OfficeThemeDto>> _load() async {
    final api = ref.read(officeApiProvider);
    if (api == null) return const <OfficeThemeDto>[];
    return api.themeList(ntype: widget.ntype);
  }

  void _refresh() => setState(() => _future = _load());

  Future<void> _apply(OfficeThemeDto theme) async {
    final api = ref.read(officeApiProvider);
    if (api == null) {
      throw StateError(officeLibraryText('officeLibraryNotConnected', '未连接'));
    }
    final objectId = await api.resolveObjectId(fileId: widget.entry.fileId);
    if (objectId == null || objectId.isEmpty) {
      throw StateError(
        officeLibraryText('officeThemeNoObjectId', '解析不到文档内部 id，未发送应用请求'),
      );
    }
    await api.themeApply(
      objectId: objectId,
      ntype: widget.ntype,
      themeId: theme.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('office-themes-page'),
      backgroundColor: DesignPalette.of(context).bg,
      appBar: AppBar(
        title: Text(officeLibraryText('officeThemeTitle', '主题')),
        actions: [
          IconButton(
            key: const Key('office-themes-refresh'),
            tooltip: officeLibraryText('officeLibraryRefresh', '刷新'),
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<OfficeThemeDto>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                key: Key('office-themes-loading'),
                child: CircularProgressIndicator(),
              );
            }
            if (snap.hasError) {
              return Center(
                key: const Key('office-themes-error'),
                child: Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        officeLibraryText(
                          'officeThemeLoadFailed',
                          '主题加载失败：${snap.error}',
                        ).replaceAll('{error}', '${snap.error}'),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: Gap.md),
                      FilledButton(
                        key: const Key('office-themes-retry'),
                        onPressed: _refresh,
                        child: Text(
                          officeLibraryText('officeLibraryRetry', '重试'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
            // 空列表由批 D 的 widget 给明确空态（`office-theme-empty`）。
            return OfficeThemePickerView(
              themes: snap.data ?? const <OfficeThemeDto>[],
              ntype: widget.ntype,
              onApply: _apply,
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 版本历史（只读，批 D 的 `OfficeVersionListView`）
// ---------------------------------------------------------------------------

/// Office 原生文档的**只读**版本列表页。
///
/// 数据沿用既有的 [officeNodeVersionsProvider]（`Office.Node.Version:list`）——
/// 与完整版历史页（`drive_revisions_page.dart` 的 `_OfficeVersionsPage`）同一条
/// 通道、同一份缓存；本页只展示批 D 的只读 widget，**不做**还原 / 命名 / 导出。
class OfficeVersionsReadOnlyPage extends ConsumerWidget {
  const OfficeVersionsReadOnlyPage({super.key, required this.entry});

  final DriveEntryDto entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(officeNodeVersionsProvider(entry.fileId));
    return Scaffold(
      key: const Key('office-versions-readonly-page'),
      backgroundColor: DesignPalette.of(context).bg,
      appBar: AppBar(
        title: Text(
          officeLibraryText('officeVersionReadOnlyTitle', '版本记录（只读）'),
        ),
        actions: [
          IconButton(
            key: const Key('office-versions-readonly-refresh'),
            tooltip: officeLibraryText('officeLibraryRefresh', '刷新'),
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.invalidate(officeNodeVersionsProvider(entry.fileId)),
          ),
        ],
      ),
      body: SafeArea(
        child: async.when(
          loading: () => const Center(
            key: Key('office-versions-readonly-loading'),
            child: CircularProgressIndicator(),
          ),
          error: (e, _) => Center(
            key: const Key('office-versions-readonly-error'),
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    officeLibraryText(
                      'officeVersionLoadFailed',
                      '版本记录加载失败：$e',
                    ).replaceAll('{error}', userFacingError(e)),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: Gap.md),
                  FilledButton(
                    key: const Key('office-versions-readonly-retry'),
                    onPressed: () => ref.invalidate(
                      officeNodeVersionsProvider(entry.fileId),
                    ),
                    child: Text(officeLibraryText('officeLibraryRetry', '重试')),
                  ),
                ],
              ),
            ),
          ),
          // 空列表由批 D 的 widget 给明确空态（`office-version-empty`）。
          data: (versions) => OfficeVersionListView(versions: versions),
        ),
      ),
    );
  }
}
