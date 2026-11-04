// 埋点**覆盖注册表**（单一事实来源，供 `test/analytics_coverage_test.dart` 守卫）。
//
// 为什么要有这一份（而不是让埋点散在各页面里）：
//   * 新功能加了一个页面，很容易"忘了埋点"，而且**不会有人发现**；
//   * 注册表把"哪个页面应该记哪类事件"变成可断言的契约：
//     每条 surface 声明 `file` + `module`（+ 期望的 screen/action），
//     守卫用**静态扫描**逐个核对，漏了就红；
//   * 同时维护一份"明确不埋点"的 feature 目录（含理由），
//     这样新增一个 feature 目录时会**被迫做决定**（登记或写理由），
//     不会静默腐烂。
//
// 注：注册表只描述"应该存在埋点"的**接口**，不关心具体行号；
// 具体触发点见 `docs/usage-analytics-audit.md` 的矩阵。
import 'usage_event.dart';

/// 一处**应当有埋点**的功能面（页面/弹层/播放器等）
class AnalyticsSurface {
  const AnalyticsSurface({
    required this.id,
    required this.module,
    required this.file,
    this.screens = const [],
    this.actions = const [],
    this.note = '',
  });

  /// 稳定 id（`<feature>.<surface>`），不要改名 —— 守卫与文档都引用它。
  final String id;

  /// 归属模块（落库时用）
  final UsageModule module;

  /// 仓库相对路径（`lib/...`）。守卫会读这个文件做静态扫描。
  final String file;

  /// 期望出现的稳定 screen/view id（曝光/视图偏好类）
  final List<String> screens;

  /// 期望出现的动作 id（`UsageAction.id`）
  final List<String> actions;

  /// 备注（覆盖口径 / 刻意取舍）
  final String note;
}

/// 所有**已登记**的功能面。每个 `UsageModule` 至少被一条覆盖。
const List<AnalyticsSurface> kAnalyticsSurfaces = [
  // ── 外壳 / 工作台 ──────────────────────────────────────────────
  AnalyticsSurface(
    id: 'workspace.shell',
    module: UsageModule.workspace,
    file: 'lib/src/features/shell/app_shell_page.dart',
    actions: ['open'],
    note: '工作台入口点击（workspace/open，object=入口 id）',
  ),
  // ── 文件 / Drive ───────────────────────────────────────────────
  AnalyticsSurface(
    id: 'files.browse',
    module: UsageModule.files,
    file: 'lib/src/features/files/file_browse_page.dart',
    actions: ['open', 'preview', 'switch_section', 'upload', 'sort'],
  ),
  AnalyticsSurface(
    id: 'drive.browse',
    module: UsageModule.drive,
    file: 'lib/src/features/files/drive_browse_view.dart',
    actions: ['open', 'preview', 'upload', 'download', 'create', 'share', 'delete'],
  ),
  AnalyticsSurface(
    id: 'drive.more',
    module: UsageModule.drive,
    file: 'lib/src/features/files/drive_more_page.dart',
    actions: ['switch_section'],
  ),
  AnalyticsSurface(
    id: 'drive.category',
    module: UsageModule.drive,
    file: 'lib/src/features/drive/drive_category_page.dart',
    screens: ['category'],
    actions: ['view', 'filter'],
    note: '分类浏览页曝光 + 分类筛选偏好',
  ),
  AnalyticsSurface(
    id: 'reader.book',
    module: UsageModule.reader,
    file: 'lib/src/features/files/file_book_view.dart',
    actions: ['open', 'switch_section', 'play', 'export'],
  ),
  AnalyticsSurface(
    id: 'reader.pdf',
    module: UsageModule.reader,
    file: 'lib/src/features/files/file_pdf_view.dart',
    actions: ['open'],
  ),
  // ── 笔记 / 相册 / 日历 / 联系人 / 聊天 / 搜索 ───────────────────
  AnalyticsSurface(
    id: 'notes.list',
    module: UsageModule.notes,
    file: 'lib/src/features/notes/notes_page.dart',
    actions: ['open'],
  ),
  AnalyticsSurface(
    id: 'notes.editor',
    module: UsageModule.notes,
    file: 'lib/src/features/notes/note_editor_page.dart',
    actions: ['create', 'edit'],
  ),
  AnalyticsSurface(
    id: 'photos.browse',
    module: UsageModule.photos,
    file: 'lib/src/features/photos/photo_browse_page.dart',
    actions: ['preview', 'switch_section', 'switch_view'],
  ),
  AnalyticsSurface(
    id: 'calendar.page',
    module: UsageModule.calendar,
    file: 'lib/src/features/calendar/calendar_page.dart',
    actions: ['switch_section', 'create', 'switch_view'],
  ),
  AnalyticsSurface(
    id: 'contacts.list',
    module: UsageModule.contacts,
    file: 'lib/src/features/contacts/contacts_page.dart',
    actions: ['open'],
  ),
  AnalyticsSurface(
    id: 'chat.page',
    module: UsageModule.chat,
    file: 'lib/src/features/chat/chat_page.dart',
    actions: ['create'],
    note: '发送消息（只记一条，正文不记）',
  ),
  AnalyticsSurface(
    id: 'search.global',
    module: UsageModule.search,
    file: 'lib/src/features/search/global_search_page.dart',
    actions: ['search'],
  ),
  // ── 第 275 轮新补的功能面 ───────────────────────────────────────
  AnalyticsSurface(
    id: 'office.library',
    module: UsageModule.office,
    file: 'lib/src/features/office/office_library_page.dart',
    screens: ['template_gallery'],
    actions: ['select'],
  ),
  AnalyticsSurface(
    id: 'office.template_preview',
    module: UsageModule.office,
    file: 'lib/src/features/office/office_template_preview.dart',
    actions: ['preview', 'create'],
  ),
  AnalyticsSurface(
    id: 'office.doc_reader',
    module: UsageModule.office,
    file: 'lib/src/features/office/office_doc_page.dart',
    screens: ['doc_reader'],
    actions: ['view'],
  ),
  AnalyticsSurface(
    id: 'office.sheet_reader',
    module: UsageModule.office,
    file: 'lib/src/features/office/office_sheet_page.dart',
    screens: ['sheet_reader'],
    actions: ['view'],
  ),
  AnalyticsSurface(
    id: 'office.slides_reader',
    module: UsageModule.office,
    file: 'lib/src/features/office/office_slides_page.dart',
    screens: ['slides_reader'],
    actions: ['view'],
  ),
  AnalyticsSurface(
    id: 'media.player',
    module: UsageModule.media,
    file: 'lib/src/features/media/media_player_view.dart',
    screens: ['player'],
    actions: ['view', 'play', 'start', 'complete'],
  ),
  AnalyticsSurface(
    id: 'media.lyrics',
    module: UsageModule.media,
    file: 'lib/src/features/media/audio_lyrics_view.dart',
    screens: ['lyrics'],
    actions: ['switch_view'],
  ),
  AnalyticsSurface(
    id: 'media.visualizer',
    module: UsageModule.media,
    file: 'lib/src/features/media/audio_visualizer.dart',
    screens: ['visualizer'],
    actions: ['switch_view'],
  ),
  AnalyticsSurface(
    id: 'media.video_frame',
    module: UsageModule.media,
    file: 'lib/src/features/media/video_frame_thumb.dart',
    actions: ['preview'],
  ),
  AnalyticsSurface(
    id: 'audio.song',
    module: UsageModule.audio,
    file: 'lib/src/features/audio/audio_song_page.dart',
    screens: ['player'],
    actions: ['view', 'play', 'start'],
  ),
  AnalyticsSurface(
    id: 'ai.model_page',
    module: UsageModule.ai,
    file: 'lib/src/features/ai/ai_model_page.dart',
    screens: ['model_page'],
    actions: ['view', 'select'],
  ),
  AnalyticsSurface(
    id: 'ai.assistant',
    module: UsageModule.ai,
    file: 'lib/src/features/ai/ai_assistant_sheet.dart',
    screens: ['assistant'],
    actions: ['view', 'complete'],
  ),
  AnalyticsSurface(
    id: 'downloads.list',
    module: UsageModule.downloads,
    file: 'lib/src/features/downloads/download_page.dart',
    screens: ['list'],
    actions: ['view', 'pause', 'resume', 'delete'],
  ),
  AnalyticsSurface(
    id: 'downloads.create',
    module: UsageModule.downloads,
    file: 'lib/src/features/downloads/download_create_page.dart',
    actions: ['create'],
  ),
  AnalyticsSurface(
    id: 'admin.tools',
    module: UsageModule.admin,
    file: 'lib/src/features/admin/admin_tools_page.dart',
    screens: ['tools'],
    actions: ['view', 'edit'],
  ),
  AnalyticsSurface(
    id: 'surveillance.live',
    module: UsageModule.surveillance,
    file: 'lib/src/features/surveillance/surv_page.dart',
    screens: ['live'],
    actions: ['view'],
  ),
  AnalyticsSurface(
    id: 'surveillance.camera',
    module: UsageModule.surveillance,
    file: 'lib/src/features/surveillance/surv_camera_page.dart',
    actions: ['view'],
  ),
  AnalyticsSurface(
    id: 'mailplus.list',
    module: UsageModule.mailplus,
    file: 'lib/src/features/mailplus/mail_page.dart',
    screens: ['inbox'],
    actions: ['view'],
  ),
  AnalyticsSurface(
    id: 'mailplus.detail',
    module: UsageModule.mailplus,
    file: 'lib/src/features/mailplus/mail_detail_page.dart',
    actions: ['open'],
  ),
  AnalyticsSurface(
    id: 'settings.page',
    module: UsageModule.settings,
    file: 'lib/src/features/settings/settings_page.dart',
    screens: ['settings'],
    actions: ['view', 'select', 'switch_language'],
  ),
];

/// **明确不埋点**的 feature 目录 + 理由。
///
/// 守卫要求 `lib/src/features/<dir>/*_page.dart` 的每个目录要么出现在
/// [kAnalyticsSurfaces] 的 `file` 前缀里，要么在这里有一条理由 ——
/// 新增 feature 目录时会被迫做决定，不会静默漏掉。
const Map<String, String> kAnalyticsExcludedFeatures = {
  'analytics': '使用分析页自身：记录"用户在看分析"会自我污染样本',
  'design': '设计预览页，仅开发期使用',
  'diagnostics': '诊断页，仅排障使用',
  'home': '启动/首页外壳，无独立用户行为',
  'login': '登录页：凭据、服务器地址，隐私红线，绝不埋点',
  'security': '安全设置：凭据/生物识别，隐私红线',
  'servers': '服务器地址与凭据管理，隐私红线',
  'shell': '外壳/导航容器：其行为由各模块入口记录，避免重复计数',
  'widgets': '共享组件：无独立行为，不在组件内埋点',
  'notifications': '系统通知设置：属系统级能力，非使用偏好',
};

/// 注册表里声明的模块集合（守卫据此断言模块级完整性）
Set<UsageModule> get kRegisteredModules =>
    {for (final s in kAnalyticsSurfaces) s.module};

/// **不需要功能面**的模块。
///
/// `unattributed` 不是功能模块，而是**网络流量计量的默认落点**
/// （没打模块标签的 Dart 请求都归它，见 `core/net/traffic_meter.dart`）——
/// 它永远不该有"埋点页面"，但必须存在于 [UsageModule] 里，
/// 否则未打标签的流量会静默消失。守卫对集合取差集时排除它。
const Set<UsageModule> kNonSurfaceModules = {UsageModule.unattributed};
