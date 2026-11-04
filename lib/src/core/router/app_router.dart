import 'package:flutter/material.dart';
import '../../core/dev/dev_tools.dart';
import '../../core/i18n/l10n.dart';
import 'package:go_router/go_router.dart';

import '../../features/chat/channel_create_page.dart';
import '../../features/design/design_preview_page.dart';
import '../../design/design_gallery.dart';
import '../../features/chat/channel_content_page.dart';
import '../../features/chat/channel_hashtags_page.dart';
import '../../features/settings/bots_page.dart';
import '../../features/chat/archive_page.dart';
import '../../features/settings/notification_settings_page.dart';
import '../../features/settings/snooze_settings_page.dart';
import '../../features/servers/certificates_page.dart';
import '../../features/settings/e2ee_page.dart';
import '../../features/chat/channel_media_page.dart';
import '../../features/chat/channel_members_page.dart';
import '../../features/chat/channel_scheduled_page.dart';
import '../../features/chat/chat_page.dart';
import '../../features/search/search_page.dart';
import '../../features/chat/thread_page.dart';
import '../../features/diagnostics/diag_page.dart';
import '../../features/home/home_page.dart';
import '../../features/login/login_page.dart';
import '../../features/servers/server_setup_page.dart';
import '../../features/settings/profile_edit_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/settings/service_check_page.dart';
import 'app_routes.dart';

/// 全局路由。用 [go] 做无栈跳转（登录流是线性的），
/// 诊断页用 [push] 以便返回。
/// 全局导航 key：证书信任框要在任意页面（甚至非 widget 上下文）弹出来
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'root',
);

final GoRouter appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: AppRoutes.setup,
  routes: [
    GoRoute(
      path: AppRoutes.setup,
      name: AppRoutes.setupName,
      builder: (_, __) => const ServerSetupPage(),
    ),
    GoRoute(
      path: AppRoutes.login,
      name: AppRoutes.loginName,
      builder: (_, __) => const LoginPage(),
    ),
    GoRoute(
      path: AppRoutes.home,
      name: AppRoutes.homeName,
      builder: (_, __) => const HomePage(),
    ),
    GoRoute(
      path: '${AppRoutes.chat}/:channelId',
      name: AppRoutes.chatName,
      builder: (_, state) => ChatPage(
        channelId: int.tryParse(state.pathParameters['channelId'] ?? '') ?? 0,
        focusPostId: int.tryParse(state.uri.queryParameters['post'] ?? '') ?? 0,
      ),
      routes: [
        GoRoute(
          path: 'thread/:postId',
          name: 'thread',
          builder: (_, state) => ThreadPage(
            channelId:
                int.tryParse(state.pathParameters['channelId'] ?? '') ?? 0,
            parentPostId:
                int.tryParse(state.pathParameters['postId'] ?? '') ?? 0,
          ),
        ),
        GoRoute(
          path: 'content/:kind',
          name: AppRoutes.contentName,
          builder: (_, state) {
            final kind = state.pathParameters['kind'] ?? '';
            return ChannelContentPage(
              channelId:
                  int.tryParse(state.pathParameters['channelId'] ?? '') ?? 0,
              kind: ChannelContentKind.values.firstWhere(
                (k) => k.name == kind,
                orElse: () => ChannelContentKind.links,
              ),
            );
          },
        ),
        GoRoute(
          path: 'hashtags',
          name: 'hashtags',
          builder: (_, state) => ChannelHashtagsPage(
            channelId:
                int.tryParse(state.pathParameters['channelId'] ?? '') ?? 0,
          ),
        ),
        GoRoute(
          path: 'scheduled',
          name: 'scheduled',
          builder: (_, state) => ScheduledMessagesPage(
            channelId:
                int.tryParse(state.pathParameters['channelId'] ?? '') ?? 0,
          ),
        ),
        GoRoute(
          path: 'reminders',
          name: 'reminders',
          builder: (_, state) => RemindersPage(
            channelId:
                int.tryParse(state.pathParameters['channelId'] ?? '') ?? 0,
          ),
        ),
        GoRoute(
          path: 'members',
          name: 'members',
          builder: (_, state) => ChannelMembersPage(
            channelId:
                int.tryParse(state.pathParameters['channelId'] ?? '') ?? 0,
          ),
        ),
        GoRoute(
          path: 'media',
          name: 'media',
          builder: (_, state) => ChannelMediaPage(
            channelId:
                int.tryParse(state.pathParameters['channelId'] ?? '') ?? 0,
          ),
        ),
      ],
    ),
    GoRoute(
      path: AppRoutes.channelCreate,
      name: AppRoutes.channelCreateName,
      builder: (context, state) => const ChannelCreatePage(),
    ),
    GoRoute(
      path: AppRoutes.search,
      name: AppRoutes.searchName,
      builder: (_, __) => const SearchPage(),
    ),
    GoRoute(
      path: AppRoutes.bots,
      name: AppRoutes.botsName,
      builder: (_, __) => const BotsPage(),
    ),
    GoRoute(
      path: AppRoutes.settings,
      name: AppRoutes.settingsName,
      builder: (_, __) => const SettingsPage(),
    ),
    GoRoute(
      path: AppRoutes.profileEdit,
      name: AppRoutes.profileEditName,
      builder: (_, __) => const ProfileEditPage(),
    ),
    GoRoute(
      path: AppRoutes.notifications,
      name: AppRoutes.notificationsName,
      builder: (_, __) => const NotificationSettingsPage(),
    ),
    GoRoute(
      path: AppRoutes.snooze,
      name: AppRoutes.snoozeName,
      builder: (_, __) => const SnoozeSettingsPage(),
    ),
    GoRoute(
      path: AppRoutes.archives,
      name: AppRoutes.archivesName,
      builder: (_, __) => const ArchivePage(),
    ),
    GoRoute(
      path: AppRoutes.certificates,
      name: AppRoutes.certificatesName,
      builder: (_, __) => const CertificatesPage(),
    ),
    GoRoute(
      path: AppRoutes.serviceCheck,
      name: AppRoutes.serviceCheckName,
      builder: (_, __) => const ServiceCheckPage(),
    ),
    GoRoute(
      path: AppRoutes.e2ee,
      name: AppRoutes.e2eeName,
      builder: (_, __) => const E2eePage(),
    ),
    // 临时/调试页面：**只在 dev 档注册**（release 包里连路由都不存在）。
    if (kDevTools) ...[
      GoRoute(
        path: AppRoutes.designPreview,
        name: AppRoutes.designPreviewName,
        builder: (_, __) => const DesignPreviewPage(),
      ),
      GoRoute(
        path: AppRoutes.designGallery,
        name: AppRoutes.designGalleryName,
        builder: (_, __) => const DesignGalleryPage(),
      ),
      GoRoute(
        path: AppRoutes.diagnostics,
        name: AppRoutes.diagnosticsName,
        builder: (_, __) => const DiagPage(autoRun: false),
      ),
    ],
  ],
  errorBuilder: (context, state) => Scaffold(
    appBar: AppBar(title: Text(context.t.appPageNotFound)),
    body: Center(child: Text('${state.uri}')),
  ),
);
