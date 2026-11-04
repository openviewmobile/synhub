// C2（Photos 补齐）入口页（hub）：把共享相册 / 照片请求 / 地点 / 搜索 /
// 条件相册 / 相似照片六个入口集中在一处。
//
// 为什么单开一页：这六个是**横切能力**（不隶属于某一个相册/文件夹），塞进
// 六段视图的 chip 会把"浏览视图"和"操作 / 检索入口"混在一起；分开后能力位
// 降级更干净 —— 每个入口只在自己那个可选 API 缺失或返回 `105` 时消失
// （`partial`），**绝不隐藏 Photos 模块本身**。
//
// 入口可见性由 `photoC2AvailabilityProvider` 决定（能力位 + 一次轻探针）：
//   * 能力位缺失 / `105`/`160` → 该入口不渲染（`105` 另给"没有权限"提示）；
//   * `119`/`106` → 会话提示条，入口**保留**；
//   * 未检测 / 其它错误 → fail-open（保留）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../admin/admin_gate.dart';
import 'photo_admin_page.dart';
import 'photo_background_tasks_page.dart';
import 'photo_c2_providers.dart';
import 'photo_c2_sections.dart';
import 'photo_c2_text.dart';
import 'photo_free_up_page.dart';
import 'photo_free_up_text.dart';
import 'photo_g6_text.dart';
import 'photo_migration_page.dart';
import 'photo_recent_page.dart';
import 'photo_recent_text.dart';
import 'photo_wave2_page.dart';
import 'photo_wave2_text.dart';

Widget _buildPhotoAdminPage(BuildContext context) => const PhotoAdminPage();

class PhotoC2Page extends ConsumerWidget {
  const PhotoC2Page({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final value = ref.watch(photoC2AvailabilityProvider);
    final availability = value.value;
    final visible = availability?.visible ?? const <PhotoC2Feature>{};
    final denied = availability?.denied ?? const <PhotoC2Feature>{};
    final sessionExpired = availability?.sessionExpired ?? false;

    bool shows(PhotoC2Feature f) => visible.contains(f);

    // 相似照片还要看用户设置 `enable_similar`（官方 `getUserEnableSimilar`）
    final similarEnabled = ref.watch(similarFeatureEnabledProvider);

    final entries = <Widget>[
      // P51「释放手机空间」：**纯本机**功能（不依赖任何 NAS API），所以
      // **不参与**能力位门控 —— 相册模块可见就应该能进去，断网时更需要它。
      _Entry(
        key: const Key('photo-c2-entry-free-up'),
        icon: Icons.auto_delete_outlined,
        title: freeUpText(PhotoFreeUpTextKeys.entry, '释放手机空间'),
        subtitle: freeUpText(
          PhotoFreeUpTextKeys.entryHint,
          '删掉已备份到 NAS 的本地照片，腾出手机存储；没备份的一张都不会动',
        ),
        builder: (_) => const PhotoFreeUpSpacePage(),
      ),
      if (shows(PhotoC2Feature.sharing))
        _Entry(
          key: const Key('photo-c2-entry-sharing'),
          icon: Icons.folder_shared_outlined,
          title: photoC2(PhotoC2TextKeys.sharing, '共享相册'),
          subtitle: photoC2(
            PhotoC2TextKeys.sharingEntry,
            '与我共享 / 我共享的；看成员、改角色、开关外链',
          ),
          builder: (_) => const PhotoSharedPage(),
        ),
      if (shows(PhotoC2Feature.photoRequest))
        _Entry(
          key: const Key('photo-c2-entry-photo-request'),
          icon: Icons.inbox_outlined,
          title: photoC2(PhotoC2TextKeys.photoRequest, '照片请求'),
          subtitle: photoC2(
            PhotoC2TextKeys.photoRequestEntry,
            '管理你发出的收图链接（删除会让链接立刻失效）',
          ),
          builder: (_) => const PhotoRequestsPage(),
        ),
      if (shows(PhotoC2Feature.geocoding))
        _Entry(
          key: const Key('photo-c2-entry-geocoding'),
          icon: Icons.place_outlined,
          title: photoC2(PhotoC2TextKeys.geocoding, '地点'),
          subtitle: photoC2(
            PhotoC2TextKeys.geocodingEntry,
            '按地理坐标 / 地点浏览照片（地点名依赖 NAS 端地理编码服务）',
          ),
          builder: (_) => const PhotoGeocodingPage(),
        ),
      if (shows(PhotoC2Feature.search))
        _Entry(
          key: const Key('photo-c2-entry-search'),
          icon: Icons.search,
          title: photoC2(PhotoC2TextKeys.search, '搜索照片'),
          subtitle: photoC2(PhotoC2TextKeys.searchEntry, '按关键词检索照片，点开复用大图查看器'),
          builder: (_) => const PhotoSearchPage(),
        ),
      // wave2：标签浏览 / 人物（只读）——与搜索并列的能力入口。
      // 门控与其余入口同一套：能力位缺失 / `105` → 隐藏；`119`/`106` → 会话提示。
      if (shows(PhotoC2Feature.tags))
        _Entry(
          key: const Key('photo-c2-entry-tags'),
          icon: Icons.label_outline,
          title: photoWave2(PhotoWave2TextKeys.tags, '标签'),
          subtitle: photoWave2(
            PhotoWave2TextKeys.tagsEntry,
            '按标签浏览照片（标签由 NAS 端索引）',
          ),
          builder: (_) => const PhotoTagsPage(),
        ),
      if (shows(PhotoC2Feature.persons))
        _Entry(
          key: const Key('photo-c2-entry-persons'),
          icon: Icons.face_retouching_natural_outlined,
          title: photoWave2(PhotoWave2TextKeys.persons, '人物'),
          subtitle: photoWave2(
            PhotoWave2TextKeys.personsEntry,
            '按人物浏览照片（需 NAS 端已开启人脸识别）',
          ),
          builder: (_) => const PhotoPersonsPage(),
        ),
      // 本批：最近添加（`Browse.RecentlyAdded/list`，只读浏览）。
      // 门控与其余入口同一套：能力位缺失 → 隐藏；`119`/`106` → 会话提示、不隐藏。
      if (shows(PhotoC2Feature.recentlyAdded))
        _Entry(
          key: const Key('photo-c2-entry-recent'),
          icon: Icons.new_releases_outlined,
          title: photoRecent(PhotoRecentTextKeys.title, '最近添加'),
          subtitle: photoRecent(PhotoRecentTextKeys.entry, '按加入时间浏览最近入库的照片与视频'),
          builder: (_) => const PhotoRecentlyAddedPage(),
        ),
      // G6：用户后台任务（`BackgroundTask.Info:list_user_task`，**全局 v1**）。
      // 门控与其余入口同一套：能力位缺失 → 隐藏（且不发探测）；
      // `119`/`106` → 会话提示、入口保留。真机回空列表 ⇒ 页面画人话空态。
      if (shows(PhotoC2Feature.backgroundTask))
        _Entry(
          key: const Key('photo-c2-entry-background-task'),
          icon: Icons.pending_actions_outlined,
          title: photoG6(PhotoG6TextKeys.tasksEntry, '后台任务'),
          subtitle: photoG6(
            PhotoG6TextKeys.tasksEntryHint,
            '查看相册里正在进行的复制 / 移动等任务',
          ),
          builder: (_) => const PhotoBackgroundTasksPage(),
        ),
      // G6：迁移状态（`Migration:get_status`，**全局 v1**）。
      // 真机回 `status:"done", total:0` ⇒ 页面画「没有正在进行的迁移」空态。
      if (shows(PhotoC2Feature.migration))
        _Entry(
          key: const Key('photo-c2-entry-migration'),
          icon: Icons.moving_outlined,
          title: photoG6(PhotoG6TextKeys.migrationEntry, '迁移状态'),
          subtitle: photoG6(
            PhotoG6TextKeys.migrationEntryHint,
            'Photo Station / Moments 到 Synology Photos 的迁移进度',
          ),
          builder: (_) => const PhotoMigrationPage(),
        ),
      if (shows(PhotoC2Feature.conditionAlbum))
        _Entry(
          key: const Key('photo-c2-entry-condition'),
          icon: Icons.filter_alt_outlined,
          title: photoC2(PhotoC2TextKeys.conditionAlbum, '条件相册'),
          subtitle: photoC2(
            PhotoC2TextKeys.conditionAlbumEntry,
            '按时间 / 地点 / 人物 / 标签等条件自动成册',
          ),
          builder: (_) => const PhotoConditionAlbumPage(),
        ),
      if (shows(PhotoC2Feature.similar) && similarEnabled)
        _Entry(
          key: const Key('photo-c2-entry-similar'),
          icon: Icons.collections_outlined,
          title: photoC2(PhotoC2TextKeys.similar, '相似照片'),
          subtitle: photoC2(
            PhotoC2TextKeys.similarEntry,
            '官方相似分组（依赖 NAS 端的相似索引）',
          ),
          builder: (_) => const PhotoSimilarPage(),
        ),
      // ⑦相册 **管理员**（新规 B1）：非管理员**完全看不到**（AdminOnly = fail-closed）
      AdminOnly(
        child: _Entry(
          key: const Key('photo-c2-entry-admin'),
          icon: Icons.admin_panel_settings_outlined,
          title: context.t.photoAdminTitle,
          subtitle: context.t.photoAdminEntrySubtitle,
          builder: _buildPhotoAdminPage,
        ),
      ),
    ];

    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('photo-c2-page'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: context.t.calBack,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            photoC2(PhotoC2TextKeys.hubTitle, '更多相册功能'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            photoC2(
                              PhotoC2TextKeys.hubSubtitle,
                              '共享 · 地点 · 搜索 · 条件相册 · 相似照片',
                            ),
                            // ★ r496：去 1.2 字距（HUD 遥测字），改用设计语言的次级文字色
                            style: TextStyle(
                              fontSize: DesignType.bodySmallSize,
                              color: hud.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // `119`/`106`：会话提示条 —— **只提示，不动入口**（也绝不隐藏模块）
              if (sessionExpired)
                Container(
                  key: const Key('photo-c2-session-hint'),
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
                  padding: const EdgeInsets.all(Gap.sm),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.errorContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(Radii.pane),
                  ),
                  child: Text(
                    photoC2(PhotoC2TextKeys.sessionHint, '登录状态已失效，请重新登录后重试。'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              // `105`：无权限提示（对应入口已从列表里消失）
              if (denied.isNotEmpty)
                Container(
                  key: const Key('photo-c2-permission-hint'),
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
                  padding: const EdgeInsets.all(Gap.sm),
                  child: Text(
                    photoC2(
                      PhotoC2TextKeys.noPermissionHint,
                      '部分功能当前账号没有权限，已从列表里隐藏。',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              // FieldBackdrop 是 ColoredBox（没有 Material 祖先）→ 里面的
              // ListTile 水波纹会断言失败，必须套一层透明 Material
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: value.isLoading && availability == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          children: entries,
                        ),
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return DesignRowTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle, style: TextStyle(color: hud.dim)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(
        context,
      ).push<void>(MaterialPageRoute<void>(builder: builder)),
    );
  }
}
