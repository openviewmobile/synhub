/// 路由路径常量。跳转一律用这些常量，避免散落的字符串。
abstract final class AppRoutes {
  /// 选择服务器 / 输入 QuickConnect ID
  static const String setup = '/';

  /// 登录
  static const String login = '/login';

  /// 主页（频道列表，Phase 2 起填充）
  static const String home = '/home';

  /// 频道消息页
  static const String chat = '/chat';
  static String chatOf(int channelId) => '$chat/$channelId';
  static const String chatName = 'chat';

  /// 新建频道（命名频道创建）
  static const String channelCreate = '/channels/new';
  static const String channelCreateName = 'channelCreate';

  /// 话题（thread）页
  static String threadOf(int channelId, int postId) =>
      '$chat/$channelId/thread/$postId';

  /// 频道的「媒体与文件」页
  static String mediaOf(int channelId) => '$chat/$channelId/media';

  /// 频道成员页
  static String membersOf(int channelId) => '$chat/$channelId/members';

  /// 从搜索结果跳到某条消息（`?post=<postId>`）
  static String chatAt(int channelId, int postId) =>
      '$chat/$channelId?post=$postId';

  /// 定时消息列表
  static String scheduledOf(int channelId) => '$chat/$channelId/scheduled';

  /// 提醒列表
  static String remindersOf(int channelId) => '$chat/$channelId/reminders';

  /// 标签列表
  static String hashtagsOf(int channelId) => '$chat/$channelId/hashtags';

  /// 频道内容列表（置顶 / 文件 / 链接 / @我）—— 对齐原版 `TabPostFragment` +
  /// `MentionFragment`（`Post/search` + `has`/`mention` 过滤）
  static String contentOf(int channelId, String kind) =>
      '$chat/$channelId/content/$kind';
  static const String contentName = 'channelContent';


  /// 设置主页（Phase 9）
  static const String settings = '/settings';
  static const String settingsName = 'settings';

  /// 服务检测（统一可用性安全阀：列出全部服务状态 + 重新检测 + 临时显示隐藏模块）
  static const String serviceCheck = '/settings/services';
  static const String serviceCheckName = 'serviceCheck';

  /// 个人资料编辑（Phase 9，对齐原版 ProfileEditFragment）
  static const String profileEdit = '/profile/edit';
  static const String profileEditName = 'profileEdit';

  /// 通知与后台（Phase 8）
  static const String snooze = '/snooze';
  static const String snoozeName = 'snooze';
  static const String notifications = '/notifications';
  static const String notificationsName = 'notifications';

  /// 归档频道（E2EE 归档）
  static const String archives = '/archives';
  static const String archivesName = 'archives';

  /// 机器人列表
  static const String bots = '/bots';
  static const String botsName = 'bots';

  /// 端到端加密设置
  static const String e2ee = '/e2ee';
  static const String e2eeName = 'e2ee';

  /// 证书信任管理（Phase 9）
  static const String certificates = '/certificates';
  static const String certificatesName = 'certificates';

  /// 高级搜索页
  static const String search = '/search';
  static const String searchName = 'search';

  /// 打洞诊断工具
  /// 设计预览画廊（临时页面，UI 现代化期间用来在真机上评审设计语言）
  static const String designPreview = '/design';
  static const String designPreviewName = 'designPreview';
  /// 设计稿画廊（154 屏 × 暗/亮 × 中/英），评审用；只在 dev 档注册。
  static const String designGallery = '/design/gallery';
  static const String designGalleryName = 'designGallery';

  static const String diagnostics = '/diagnostics';

  static const String setupName = 'setup';
  static const String loginName = 'login';
  static const String homeName = 'home';
  static const String diagnosticsName = 'diagnostics';
}
