// C2（Photos 补齐）的各功能区子页：共享相册 / 照片请求 / 地点 / 搜索 /
// 条件相册 / 相似照片。
//
// 纪律（用户决策，见 `photo_c2_providers.dart` 的 [PhotoC2Availability]）：
//   * 能力位缺失 → 入口由 hub 隐藏（这里不做二次判断）；
//   * `105` → 页面显示"没有权限"，**内容不渲染**；
//   * `119`/`106` → 会话提示；模块与入口都不隐藏；
//   * 危险操作（移除成员 / 关闭外链 / 删照片请求 / 删条件相册）**必须二次确认**，
//     取消后**一个请求都不发**。
import '../../design/kit/design_kit.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/foto_c2_dto.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/foto_api.dart';
import '../../data/foto_c2_api.dart';
import '../../dsm/webapi.dart';
import 'photo_c2_providers.dart';
import 'photo_c2_text.dart';
import 'photo_format_support.dart';
import 'photo_map_sheet.dart';
import 'photo_map_page.dart';
import 'photo_map_text.dart';
import 'photo_p1_text.dart';
import 'photo_providers.dart';
import 'photo_similar_group.dart';
import 'photo_search_history.dart';
import 'photo_viewer_page.dart';
import 'photo_wave1_text.dart';
import 'photo_wave2_providers.dart';
import 'photo_wave2_text.dart';
import 'photo_widgets.dart';
import '../../core/theme/app_theme.dart';

/// 打开大图查看器（与 `photo_browse_page.dart` 的 `_openViewer` 同一口径；
/// 那个是文件私有函数，这里不去改它，复制这几行）
void _openViewer(BuildContext context, List<FotoItemDto> items, int index) {
  Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => PhotoViewerPage(items: items, index: index),
    ),
  );
}

/// 子页共用的外壳（返回箭头 + 标题 + 背景）
class PhotoC2Scaffold extends StatelessWidget {
  const PhotoC2Scaffold({
    super.key,
    required this.title,
    required this.body,
    this.pageKey,
  });

  final String title;
  final Widget body;
  final Key? pageKey;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: pageKey,
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
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
              ),
              // FieldBackdrop 是 ColoredBox（没有 Material 祖先）→ 里面的
              // ListTile/水波纹会断言失败，必须套一层透明 Material
              Expanded(
                child: Material(type: MaterialType.transparency, child: body),
              ),
            ],
          ),
        ),
    );
  }
}

/// `105`/`160` → "没有权限"；其余走既有 [describePhotoError]（**不新造分类**）。
String _c2Error(Object error, AppText t) {
  if (_isDenied(error)) return photoC2(PhotoC2TextKeys.noPermission, '没有权限');
  return describePhotoError(error, t);
}

/// 该错误是不是"无权限"（→ 内容不渲染）
bool _isDenied(Object? error) {
  if (error is! DsmApiException) return false;
  return error.code == 105 || error.code == 160;
}

/// 条件相册的**条件类型键 → 可显示标题**（服务端键逐字：`person` / `camera` …）。
///
/// ★ r402：这条路以前有**两份**且都不全 ——
///   ① `_TypeRow` 的标题**每行都硬写** `PhotoC2TextKeys.conditionKindOther`
///      （意思是"其它条件"）⇒ 真机 6 行全显示 "Other"，用户看不出哪行是哪个条件；
///   ② 相册卡片的条件摘要另有一份 `_conditionKind`，缺 `camera`/`lens`/`concept`
///      ⇒ 带相机的相册摘要也显示"其它条件"。
/// 现在**只有这一份**，两处共用（要加类型就加在这里，别在页面上再写第二份）。
String photoC2ConditionKindLabel(String key) => switch (key) {
  'time' => photoC2(PhotoC2TextKeys.conditionKindTime, '时间'),
  'geocoding' => photoC2(PhotoC2TextKeys.conditionKindPlace, '地点'),
  'person' => photoC2(PhotoC2TextKeys.conditionKindPerson, '人物'),
  'general_tag' => photoC2(PhotoC2TextKeys.conditionKindTag, '标签'),
  'keyword' => photoC2(PhotoC2TextKeys.conditionKindKeyword, '关键词'),
  // r402 补全：编辑器实际开放、而上面那份漏掉的三个类型
  'camera' => photoC2(PhotoC2TextKeys.groupCamera, '相机'),
  'lens' => photoC2(PhotoC2TextKeys.groupLens, '镜头'),
  'concept' => photoC2(PhotoC2TextKeys.groupConcept, '场景'),
  'aperture' => photoC2(PhotoC2TextKeys.groupAperture, '光圈'),
  'iso' => 'ISO',
  'flash' => photoC2(PhotoC2TextKeys.groupFlash, '闪光灯'),
  'exposure_time_group' => photoC2(PhotoC2TextKeys.groupExposureTime, '曝光时间'),
  'focal_length_group' => photoC2(PhotoC2TextKeys.groupFocalLength, '焦距'),
  'rating' => photoC2(PhotoC2TextKeys.groupRating, '评分'),
  'favorite' => photoC2(PhotoC2TextKeys.groupFavorite, '收藏'),
  'item_type' => photoC2(PhotoC2TextKeys.groupItemType, '媒体类型'),
  _ => photoC2(PhotoC2TextKeys.conditionKindOther, '其它条件'),
};

/// 与 `PhotoAsync` 同形，只是错误文案走 [_c2Error]（105 说"没有权限"）。
class _C2Async<T> extends StatelessWidget {
  const _C2Async({
    required this.value,
    required this.builder,
    required this.emptyTitle,
    this.emptyIcon = Icons.photo_library_outlined,
    this.onRetry,
    this.isEmpty,
  });

  final AsyncValueLike<T> value;
  final Widget Function(T data) builder;
  final String emptyTitle;
  final IconData emptyIcon;
  final VoidCallback? onRetry;
  final bool Function(T data)? isEmpty;

  @override
  Widget build(BuildContext context) {
    if (value.hasError) {
      final error = value.error!;
      final denied = _isDenied(error);
      return AppEmptyState(
        icon: denied ? Icons.lock_outline : Icons.error_outline,
        title: denied
            ? photoC2(PhotoC2TextKeys.noPermission, '没有权限')
            : context.t.photoLoadFailed,
        message: denied
            ? photoC2('photoC2NoPermissionBody', '当前账号没有权限访问这个功能。')
            : _c2Error(error, context.t),
        actionLabel: onRetry == null ? null : context.t.photoRetry,
        onAction: onRetry,
      );
    }
    final data = value.dataOrNull;
    if (data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (isEmpty?.call(data) ?? false) {
      return AppEmptyState(icon: emptyIcon, title: emptyTitle);
    }
    return builder(data);
  }
}

// ================================================================ 共享相册

/// 共享相册页：与我共享 / 我共享的。
class PhotoSharedPage extends ConsumerStatefulWidget {
  const PhotoSharedPage({super.key});

  @override
  ConsumerState<PhotoSharedPage> createState() => _PhotoSharedPageState();
}

class _PhotoSharedPageState extends ConsumerState<PhotoSharedPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-shared-page'),
      title: photoC2(PhotoC2TextKeys.sharing, '共享相册'),
      body: Column(
        children: [
          TabBar(
            controller: _tabs,
            tabs: [
              Tab(
                key: const Key('photo-c2-shared-me-tab'),
                text: photoC2(PhotoC2TextKeys.sharedWithMe, '与我共享'),
              ),
              Tab(
                key: const Key('photo-c2-shared-others-tab'),
                text: photoC2(PhotoC2TextKeys.sharedByMe, '我共享的'),
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [
                _SharedAlbumList(mine: true),
                _SharedAlbumList(mine: false),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SharedAlbumList extends ConsumerWidget {
  const _SharedAlbumList({required this.mine});

  /// true = 与我共享；false = 我共享出去的
  final bool mine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(
      mine ? sharedWithMeAlbumsProvider : sharedByMeAlbumsProvider,
    );
    return _C2Async<List<FotoAlbumDto>>(
      value: RiverpodAsync(value),
      emptyTitle: photoC2(
        mine ? PhotoC2TextKeys.sharedEmpty : PhotoC2TextKeys.sharedByMeEmpty,
        mine ? '还没有人共享相册给你' : '你还没有共享过相册',
      ),
      emptyIcon: Icons.folder_shared_outlined,
      isEmpty: (l) => l.isEmpty,
      onRetry: () => ref.invalidate(
        mine ? sharedWithMeAlbumsProvider : sharedByMeAlbumsProvider,
      ),
      builder: (albums) => ListView.builder(
        padding: const EdgeInsets.only(bottom: Gap.xl),
        itemCount: albums.length,
        itemBuilder: (context, i) {
          final album = albums[i];
          return DesignRowTile(
            key: Key('photo-c2-shared-item-${album.id}'),
            leading: const Icon(Icons.photo_album_outlined),
            title: Text(album.name),
            subtitle: Text(
              mine
                  ? photoC2Fill(PhotoC2TextKeys.sharedFrom, '来自 {owner}', {
                      'owner': album.ownerUserId,
                    })
                  : photoC2Fill(
                      PhotoC2TextKeys.shareModifiedAt,
                      '{count} 项 · 已共享',
                      {'count': '${album.itemCount}'},
                    ),
            ),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => AlbumSharingDetailPage(album: album),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 单个相册的共享详情：外链 + 成员 + 角色。
///
/// ★ r417 起**公开**（原来叫 `_AlbumSharingDetailPage`）：因为它是相册共享的
/// 唯一界面，而 r417 之前**只有**"已共享相册列表里点一行"这一个入口
/// （`_SharedAlbumList` 的 `onTap`）—— 两个列表都是空的时候，整个共享功能
/// （外链 / 成员 / 角色 / 口令 ≒ 6 个写动词）在 App 内**根本进不去**。
/// 现在相册详情页的 `⋮` 里也有直达入口（`photo_browse_page.dart`）。
class AlbumSharingDetailPage extends ConsumerWidget {
  const AlbumSharingDetailPage({super.key, required this.album});

  final FotoAlbumDto album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(albumSharingProvider(album.id));
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-share-detail-page'),
      title: album.name,
      body: _C2Async<FotoAlbumSharingDto?>(
        value: RiverpodAsync(value),
        emptyTitle: context.t.photoLoadFailed,
        isEmpty: (d) => d == null,
        onRetry: () => ref.invalidate(albumSharingProvider(album.id)),
        builder: (info) => _SharingBody(album: album, info: info!),
      ),
    );
  }
}

class _SharingBody extends ConsumerWidget {
  const _SharingBody({required this.album, required this.info});

  final FotoAlbumDto album;
  final FotoAlbumSharingDto info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = info.userMembers;
    final hasPassphrase = info.passphrase.isNotEmpty;
    // ★ DA76（r417）：`set_shared(enabled:false)` 之后服务端的
    // `sharing_info.sharing_link` 仍是**空串**（真机读数）⇒ 判据不能只看它：
    //   ① 链接文本：服务端给了就用服务端的，否则用**生成时回包**里的那个；
    //   ② "打开外链分享"入口：只要**口令已存在**（= 链接已生成）就该给，
    //      否则用户永远走不到下一步（相册也永远进不了"我共享的"）。
    final generatedLink = ref.watch(
      photoC2GeneratedShareLinkProvider(album.id),
    );
    final linkText = info.sharingLink.isNotEmpty
        ? info.sharingLink
        : (generatedLink ?? '');
    final hasLink = linkText.isNotEmpty;
    final canEnable = !info.enabled && (hasPassphrase || hasLink);
    return ListView(
      padding: const EdgeInsets.only(bottom: Gap.xl),
      children: [
        // ---- 外链
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
          child: Text(
            photoC2(PhotoC2TextKeys.shareLink, '共享链接'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        DesignRowTile(
          key: const Key('photo-c2-share-link'),
          leading: const Icon(Icons.link),
          title: Text(
            hasLink
                ? linkText
                : photoC2(PhotoC2TextKeys.shareLinkNone, '还没有链接'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            info.enablePassword
                ? photoP1(PhotoP1TextKeys.passwordEnabled, '已开启口令保护')
                : photoP1(PhotoP1TextKeys.passwordOff, '未设口令'),
          ),
          trailing: IconButton(
            key: const Key('photo-c2-share-link-copy'),
            tooltip: photoC2(PhotoC2TextKeys.copyLink, '复制链接'),
            icon: const Icon(Icons.copy),
            onPressed: !hasLink
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: linkText));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          photoC2(PhotoC2TextKeys.linkCopied, '链接已复制'),
                        ),
                      ),
                    );
                  },
          ),
        ),
        // 还没有链接 → 生成（官方 `set_shared(enabled:false)` =
        // "只生成链接、不改可见性"）
        if (!hasPassphrase && !hasLink)
          DesignRowTile(
            key: const Key('photo-c2-share-link-create'),
            leading: const Icon(Icons.add_link),
            title: Text(photoP1(PhotoP1TextKeys.createShareLink, '生成共享链接')),
            subtitle: Text(
              photoP1(PhotoP1TextKeys.createShareLinkHint, '此时只生成链接，还不会对访客开放'),
            ),
            onTap: () => _generateLink(context, ref),
          ),
        // 链接已生成但还没打开 → 打开（官方 `set_shared(enabled:true)`）
        // ★ DA76：判据是"口令存在"，不是"服务端回了链接"。
        if (canEnable)
          DesignRowTile(
            key: const Key('photo-c2-share-link-enable'),
            leading: const Icon(Icons.public),
            title: Text(photoP1(PhotoP1TextKeys.enableShareLink, '打开外链分享')),
            onTap: () => _confirmEnableLink(context, ref),
          ),
        // 口令（`Sharing.Passphrase/update` 的 `password`；官方 Android 明文发）
        DesignRowTile(
          key: const Key('photo-c2-share-link-password'),
          leading: const Icon(Icons.lock_outline),
          title: Text(photoP1(PhotoP1TextKeys.passwordTitle, '口令保护')),
          subtitle: Text(
            hasPassphrase
                ? photoP1(PhotoP1TextKeys.passwordOff, '未设口令')
                : photoP1(PhotoP1TextKeys.linkNeedsPassphrase, '先生成共享链接再设口令'),
          ),
          enabled: hasPassphrase,
          onTap: hasPassphrase ? () => _editPassword(context, ref) : null,
        ),
        // 关闭外链 = 危险操作 → 二次确认
        if (info.enabled || info.publicMember != null)
          DesignRowTile(
            key: const Key('photo-c2-share-disable'),
            leading: const Icon(Icons.link_off),
            title: Text(photoC2(PhotoC2TextKeys.disableLink, '关闭外链分享')),
            onTap: () => _confirmDisableLink(context, ref),
          ),
        const Divider(height: Gap.lg),
        // ---- 成员
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  photoC2(PhotoC2TextKeys.members, '成员'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              TextButton.icon(
                key: const Key('photo-c2-add-member'),
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: Text(photoC2(PhotoC2TextKeys.addMember, '添加成员')),
                onPressed: hasPassphrase
                    ? () => _addMembers(context, ref)
                    : null,
              ),
            ],
          ),
        ),
        if (members.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: Text(
              photoC2(PhotoC2TextKeys.membersEmpty, '还没有成员；只有打开外链后访客才能看到'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        for (final m in members)
          DesignRowTile(
            key: Key('photo-c2-member-${m.type}-${m.id}'),
            leading: Icon(
              m.type == 'group' ? Icons.groups_outlined : Icons.person_outline,
            ),
            title: Text(m.name.isEmpty ? m.id : m.name),
            subtitle: Text(_roleLabel(m.role)),
            trailing: IconButton(
              key: Key('photo-c2-member-remove-${m.id}'),
              tooltip: photoC2(PhotoC2TextKeys.removeMember, '移除成员'),
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: () => _confirmRemoveMember(context, ref, m),
            ),
          ),
      ],
    );
  }

  /// 生成共享链接（`Sharing.Passphrase/set_shared`，`enabled:false`）。
  Future<void> _generateLink(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    try {
      await ref
          .read(photoC2SharingActionsProvider)
          .setLink(albumId: album.id, enabled: false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(photoP1(PhotoP1TextKeys.shareLinkCreated, '共享链接已生成')),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(_c2Error(err, l10n))));
    }
  }

  /// 打开外链 = 对拿到链接的人公开 → 二次确认（取消则一个请求都不发）。
  Future<void> _confirmEnableLink(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(photoP1(PhotoP1TextKeys.enableShareLinkConfirm, '打开外链分享？')),
        content: Text(
          photoP1(
            PhotoP1TextKeys.enableShareLinkBody,
            '打开后，任何拿到链接的人都能浏览这个相册（除非设置了口令）。',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('photo-c2-share-link-enable-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-c2-share-link-enable-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.actionOk),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final actions = ref.read(photoC2SharingActionsProvider);
      // ★ DA76：口令还没生成时先走一次 `enabled:false`（官方 `NS` 的
      // "链接为空 -> setShared(false) 先把链接要出来"），再打开。
      if (info.passphrase.isEmpty) {
        await actions.setLink(albumId: album.id, enabled: false);
      }
      await actions.setLink(albumId: album.id, enabled: true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(photoC2(PhotoC2TextKeys.linkEnabled, '外链分享已打开')),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(_c2Error(err, l10n))));
    }
  }

  /// 设 / 清口令 + 有效期（`Sharing.Passphrase/update`）。
  ///
  /// 口令按**官方 Android 的明文形态**发（见 `foto_c2_api.dart` 的长注释）；
  /// 留空 = 清除口令（官方 `setPassword("")`）。有效期留空 = 不过期（不传）。
  ///
  /// 这里**不用 `TextEditingController`**：对话框退场动画还在跑的时候
  /// controller 已经被 dispose，会直接抛 "used after being disposed"。
  /// 用 `onChanged` 存局部变量即可（不需要预填、不需要监听）。
  Future<void> _editPassword(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    var password = '';
    var daysText = '';
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(photoP1(PhotoP1TextKeys.passwordTitle, '口令保护')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('photo-c2-share-password-field'),
              obscureText: true,
              onChanged: (v) => password = v,
              decoration: InputDecoration(
                labelText: photoP1(PhotoP1TextKeys.passwordField, '访问口令'),
                helperText: photoP1(
                  PhotoP1TextKeys.passwordClearHint,
                  '留空表示清除口令',
                ),
              ),
            ),
            TextField(
              key: const Key('photo-c2-share-expiration-field'),
              keyboardType: TextInputType.number,
              onChanged: (v) => daysText = v,
              decoration: InputDecoration(
                labelText: photoP1(PhotoP1TextKeys.expirationField, '有效期（天）'),
                helperText: photoP1(PhotoP1TextKeys.expirationNever, '留空表示不过期'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('photo-c2-share-password-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-c2-share-password-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.actionSave),
          ),
        ],
      ),
    );
    if (result != true) return;
    final expireDays = int.tryParse(daysText);
    try {
      await ref
          .read(photoC2SharingActionsProvider)
          .updateSharing(
            passphrase: info.passphrase,
            password: password,
            expiration: expireDays == null || expireDays <= 0
                ? null
                : expireDays * 86400,
          );
      messenger.showSnackBar(
        SnackBar(
          content: Text(photoP1(PhotoP1TextKeys.passwordSaved, '口令已更新')),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(_c2Error(err, l10n))));
    }
  }

  /// 邀请成员：选人 + 选角色 → 官方成员 diff 的 `action:"update"`。
  Future<void> _addMembers(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    final picked = await showModalBottomSheet<List<FotoShareMemberDto>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MemberPickerSheet(existing: info.userMembers),
    );
    if (picked == null || picked.isEmpty) return;
    try {
      await ref
          .read(photoC2SharingActionsProvider)
          .updateSharing(passphrase: info.passphrase, members: picked);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            photoP1Fill(PhotoP1TextKeys.memberInvited, '已邀请 {count} 位成员', {
              'count': '${picked.length}',
            }),
          ),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(_c2Error(err, l10n))));
    }
  }

  static String _roleLabel(String role) => switch (role) {
    'download' => photoC2(PhotoC2TextKeys.roleDownload, '可下载'),
    'upload' => photoC2(PhotoC2TextKeys.roleUpload, '可上传'),
    'manage' => photoC2(PhotoC2TextKeys.roleManage, '可管理'),
    _ => photoC2(PhotoC2TextKeys.roleView, '仅查看'),
  };

  Future<void> _confirmDisableLink(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(photoC2(PhotoC2TextKeys.disableLinkConfirm, '关闭外链分享？')),
        content: Text(
          photoC2(PhotoC2TextKeys.disableLinkBody, '关闭后，拿到链接的人将无法再访问这个相册。'),
        ),
        actions: [
          TextButton(
            key: const Key('photo-c2-share-disable-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-c2-share-disable-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.dtoActionDelete),
          ),
        ],
      ),
    );
    // 取消 → 一个请求都不发
    if (ok != true) return;
    try {
      // ★ DA77（r417）：**关闭外链要发 `set_shared(enabled:false)`**。
      // 真机读数（`docs/evidence-r417/nas/r417_disable_shapes.log`）：原来发的
      // `Passphrase/update {privacy_type:'private'}`（以及 `permission:delete public`）
      // 服务端**回 success 但一个字段都不改**（`shared` 仍 true、`category=shared`
      // 仍有它）⇒ 界面弹「外链分享已关闭」是**谎报**；换 `set_shared(enabled:false)`
      // 一次就把 `shared` 翻回 false、`sharing_link` 清空、`category=shared` 归零。
      await ref
          .read(photoC2SharingActionsProvider)
          .setLink(albumId: album.id, enabled: false, deactivating: true);
      messenger.showSnackBar(
        SnackBar(content: Text(photoC2(PhotoC2TextKeys.linkClosed, '外链分享已关闭'))),
      );
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(_c2Error(err, l10n))));
    }
  }

  Future<void> _confirmRemoveMember(
    BuildContext context,
    WidgetRef ref,
    FotoShareMemberDto member,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    final name = member.name.isEmpty ? member.id : member.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(photoC2(PhotoC2TextKeys.removeMemberConfirm, '移除成员？')),
        content: Text(
          photoC2Fill(
            PhotoC2TextKeys.removeMemberBody,
            '移除后 {name} 将不再能看到这个相册。',
            {'name': name},
          ),
        ),
        actions: [
          TextButton(
            key: const Key('photo-c2-member-remove-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-c2-member-remove-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.dtoActionDelete),
          ),
        ],
      ),
    );
    // 取消 → 一个请求都不发
    if (ok != true) return;
    try {
      await ref
          .read(photoC2SharingActionsProvider)
          .updateSharing(passphrase: info.passphrase, removedMembers: [member]);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            photoC2Fill(PhotoC2TextKeys.memberRemoved, '已移除 {name}', {
              'name': name,
            }),
          ),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(_c2Error(err, l10n))));
    }
  }
}

/// 邀请成员的选人表：列出 `Sharing.Misc/list_user_group` 的可共享用户/群组，
/// 勾选 + 选角色（view / download / upload / manage，官方 `ShareRoleType`）。
class _MemberPickerSheet extends ConsumerStatefulWidget {
  const _MemberPickerSheet({required this.existing});

  /// 已经在相册里的成员（**不再列出**，避免重复邀请）
  final List<FotoShareMemberDto> existing;

  @override
  ConsumerState<_MemberPickerSheet> createState() => _MemberPickerSheetState();
}

class _MemberPickerSheetState extends ConsumerState<_MemberPickerSheet> {
  final Set<String> _selected = <String>{};
  String _role = 'view';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(sharableMembersProvider);
    return SafeArea(
      child: Column(
        key: const Key('photo-c2-member-picker'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    photoC2(PhotoC2TextKeys.addMember, '添加成员'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  photoP1(PhotoP1TextKeys.inviteRole, '角色'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: Gap.xs),
                DropdownButton<String>(
                  key: const Key('photo-c2-member-picker-role'),
                  value: _role,
                  onChanged: (v) => setState(() => _role = v ?? 'view'),
                  items: [
                    for (final r in const [
                      'view',
                      'download',
                      'upload',
                      'manage',
                    ])
                      DropdownMenuItem(value: r, child: Text(_roleLabel(r))),
                  ],
                ),
              ],
            ),
          ),
          // 三态：加载 / 出错（可重试）/ 空 / 列表
          if (async.isLoading && !async.hasValue)
            const Padding(
              padding: EdgeInsets.all(Gap.lg),
              child: Center(
                key: Key('photo-c2-member-picker-loading'),
                child: CircularProgressIndicator(),
              ),
            )
          else if (async.hasError && !async.hasValue)
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                key: const Key('photo-c2-member-picker-error'),
                children: [
                  Text(describePhotoError(async.error!, context.t)),
                  TextButton(
                    key: const Key('photo-c2-member-picker-retry'),
                    onPressed: () => ref.invalidate(sharableMembersProvider),
                    child: Text(context.t.photoRetry),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: Builder(
                builder: (context) {
                  final existingIds = {
                    for (final m in widget.existing) '${m.type}:${m.id}',
                  };
                  final candidates = [
                    for (final m in async.value ?? const [])
                      if (!existingIds.contains('${m.type}:${m.id}')) m,
                  ];
                  if (candidates.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Text(
                        photoC2(PhotoC2TextKeys.addMemberEmpty, '没有可邀请的成员'),
                        key: const Key('photo-c2-member-picker-empty'),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: candidates.length,
                    itemBuilder: (context, i) {
                      final m = candidates[i];
                      final key = '${m.type}:${m.id}';
                      return DesignCheckRow(
                        key: Key('photo-c2-member-picker-${m.type}-${m.id}'),
                        value: _selected.contains(key),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selected.add(key);
                          } else {
                            _selected.remove(key);
                          }
                        }),
                        secondary: Icon(
                          m.type == 'group'
                              ? Icons.groups_outlined
                              : Icons.person_outline,
                        ),
                        title: Text(m.name.isEmpty ? m.id : m.name),
                      );
                    },
                  );
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    photoP1Fill(
                      PhotoP1TextKeys.inviteSelected,
                      '已选 {count} 人',
                      {'count': '${_selected.length}'},
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  key: const Key('photo-c2-member-picker-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.t.actionCancel),
                ),
                FilledButton(
                  style: InlineButtonStyle.filled,
                  key: const Key('photo-c2-member-picker-ok'),
                  onPressed: _selected.isEmpty
                      ? null
                      : () {
                          final all = async.value ?? const [];
                          Navigator.of(context).pop([
                            for (final m in all)
                              if (_selected.contains('${m.type}:${m.id}'))
                                FotoShareMemberDto(
                                  type: m.type,
                                  id: m.id,
                                  name: m.name,
                                  role: _role,
                                ),
                          ]);
                        },
                  child: Text(photoP1(PhotoP1TextKeys.inviteConfirm, '邀请')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _roleLabel(String role) => switch (role) {
    'download' => photoC2(PhotoC2TextKeys.roleDownload, '可下载'),
    'upload' => photoC2(PhotoC2TextKeys.roleUpload, '可上传'),
    'manage' => photoC2(PhotoC2TextKeys.roleManage, '可管理'),
    _ => photoC2(PhotoC2TextKeys.roleView, '仅查看'),
  };
}

// ================================================================ 照片请求
class PhotoRequestsPage extends ConsumerWidget {
  const PhotoRequestsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(photoRequestsProvider);
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-requests-page'),
      title: photoC2(PhotoC2TextKeys.photoRequest, '照片请求'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    photoC2(
                      PhotoC2TextKeys.photoRequestCreateHint,
                      '建一个收图链接，外部访客无需账号即可上传',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                FilledButton.icon( style: InlineButtonStyle.filled,
                  key: const Key('photo-c2-request-new'),
                  onPressed: () => _openEditor(context, ref, null),
                  icon: const Icon(Icons.add),
                  label: Text(
                    photoC2(PhotoC2TextKeys.photoRequestCreate, '新建'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _C2Async<List<FotoPhotoRequestDto>>(
        value: RiverpodAsync(value),
        emptyTitle: photoC2(PhotoC2TextKeys.photoRequestEmpty, '还没有照片请求'),
        emptyIcon: Icons.inbox_outlined,
        isEmpty: (l) => l.isEmpty,
        onRetry: () => ref.invalidate(photoRequestsProvider),
        builder: (list) => ListView.builder(
          padding: const EdgeInsets.only(bottom: Gap.xl),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final r = list[i];
            return DesignRowTile(
              key: Key('photo-c2-request-${r.passphrase}'),
              leading: const Icon(Icons.upload_file_outlined),
              title: Text(r.name.isEmpty ? r.passphrase : r.name),
              subtitle: Text(
                r.expiration == 0
                    ? photoC2(PhotoC2TextKeys.photoRequestNeverExpires, '永不过期')
                    : photoC2Fill(
                        PhotoC2TextKeys.photoRequestExpires,
                        '{count} 秒后过期',
                        {'count': '${r.expiration}'},
                      ),
              ),
              onTap: () => _openEditor(context, ref, r),
              trailing: IconButton(
                key: Key('photo-c2-request-delete-${r.passphrase}'),
                tooltip: photoC2(PhotoC2TextKeys.photoRequestDelete, '删除请求'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDelete(context, ref, r),
              ),
            );
          },
        ),
      ),
          ),
        ],
      ),
    );
  }

  /// 打开"新建/编辑"表单（官方对应 `ActivityEditPhotoRequest`）。
  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref,
    FotoPhotoRequestDto? existing,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    final draft = await showDialog<_PhotoRequestDraft>(
      context: context,
      builder: (context) => _PhotoRequestEditor(existing: existing),
    );
    if (draft == null) return; // 取消 → 一个请求都不发
    try {
      final actions = ref.read(photoC2RequestActionsProvider);
      if (existing == null) {
        await actions.create(
          subject: draft.subject,
          description: draft.description,
          teamLibrary: draft.teamLibrary,
          fileSizeLimitBytes: draft.fileSizeLimitBytes,
        );
      } else {
        await actions.update(
          passphrase: existing.passphrase,
          subject: draft.subject,
          description: draft.description,
          teamLibrary: draft.teamLibrary,
          fileSizeLimitBytes: draft.fileSizeLimitBytes,
        );
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            photoC2(PhotoC2TextKeys.photoRequestSaved, '照片请求已保存'),
          ),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(_c2Error(err, l10n))));
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    FotoPhotoRequestDto request,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          photoC2(PhotoC2TextKeys.photoRequestDeleteConfirm, '删除照片请求？'),
        ),
        content: Text(
          photoC2(
            PhotoC2TextKeys.photoRequestDeleteBody,
            '删除后这个收图链接立刻失效，外部访客不能再通过它上传。',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('photo-c2-request-delete-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-c2-request-delete-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.dtoActionDelete),
          ),
        ],
      ),
    );
    // 取消 → **一个请求都不发**
    if (ok != true) return;
    try {
      await ref.read(photoC2RequestActionsProvider).remove(request.passphrase);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            photoC2(PhotoC2TextKeys.photoRequestDeleted, '照片请求已删除'),
          ),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(_c2Error(err, l10n))));
    }
  }
}

/// 表单草稿（提交前的纯数据，**不含任何网络调用**）。
class _PhotoRequestDraft {
  const _PhotoRequestDraft({
    required this.subject,
    required this.description,
    required this.teamLibrary,
    this.fileSizeLimitBytes,
  });

  final String subject;
  final String description;
  final bool teamLibrary;
  final int? fileSizeLimitBytes;
}

/// 「新建 / 编辑照片请求」表单。
///
/// 字段集合**逐字对齐官方 APK smali**（`ApiPhotoRequest$PhotoRequestRequests`）：
/// `subject` / `description` / `library` / `filesize_limit` / `expiration`。
/// * `library`：个人空间 / 团队空间（官方 `isTeamLibToString` ⇒
///   `personal_space` / `shared_space`）；
/// * `filesize_limit`：界面用 **MB**、提交转**字节**（官方 `mbToByte`）；
/// * `expiration`：**原样透传**（界面写"秒"，本仓**不做**时间语义换算 ——
///   没有证据说明它是绝对时间戳还是剩余秒数，就不许瞎算）。
class _PhotoRequestEditor extends StatefulWidget {
  const _PhotoRequestEditor({this.existing});

  final FotoPhotoRequestDto? existing;

  @override
  State<_PhotoRequestEditor> createState() => _PhotoRequestEditorState();
}

class _PhotoRequestEditorState extends State<_PhotoRequestEditor> {
  late final TextEditingController _subject = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _description = TextEditingController();
  late final TextEditingController _sizeMb = TextEditingController();
  bool _teamLibrary = false;

  @override
  void dispose() {
    _subject.dispose();
    _description.dispose();
    _sizeMb.dispose();
    super.dispose();
  }

  int? get _sizeBytes {
    final mb = int.tryParse(_sizeMb.text.trim());
    if (mb == null || mb <= 0) return null;
    return mb * 1024 * 1024; // 官方 mbToByte
  }

  void _save() {
    final subject = _subject.text.trim();
    if (subject.isEmpty) return; // 官方 subject 必填
    Navigator.of(context).pop(
      _PhotoRequestDraft(
        subject: subject,
        description: _description.text.trim(),
        teamLibrary: _teamLibrary,
        fileSizeLimitBytes: _sizeBytes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AlertDialog(
      key: const Key('photo-c2-request-editor'),
      title: Text(
        isEdit
            ? photoC2(PhotoC2TextKeys.photoRequestEdit, '编辑照片请求')
            : photoC2(PhotoC2TextKeys.photoRequestCreate, '新建照片请求'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('photo-c2-request-subject'),
              controller: _subject,
              decoration: InputDecoration(labelText: context.t.mailSubject),
            ),
            TextField(
              key: const Key('photo-c2-request-description'),
              controller: _description,
              decoration: InputDecoration(labelText: context.t.photoRequestDescription),
            ),
            DesignSwitchRow(
              key: const Key('photo-c2-request-team'),
              value: _teamLibrary,
              title: Text(context.t.photoRequestTeamLibrary),
              subtitle: Text(context.t.photoRequestTeamLibraryHint),
              onChanged: (v) => setState(() => _teamLibrary = v),
            ),
            TextField(
              key: const Key('photo-c2-request-size-mb'),
              controller: _sizeMb,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.t.photoRequestMaxFileSize,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('photo-c2-request-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t.actionCancel),
        ),
        FilledButton(
          key: const Key('photo-c2-request-save'),
          // subject 为空时直接禁用：**不发半个请求**
          onPressed: _subject.text.trim().isEmpty ? null : _save,
          child: Text(context.t.actionSave),
        ),
      ],
    );
  }
}

// ================================================================ 地点

class PhotoGeocodingPage extends ConsumerWidget {
  const PhotoGeocodingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(geocodingPlacesProvider);
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-geocoding-page'),
      title: photoC2(PhotoC2TextKeys.geocoding, '地点'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    photoC2(
                      PhotoC2TextKeys.geocodingServiceHint,
                      '地点名由 NAS 端的地理编码服务生成；没开这项服务时只会显示坐标分组。',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                // P21：照片地图页（官方 `MapViewFragment` 的等价物）
                TextButton.icon(
                  key: const Key('photo-c2-map-open'),
                  onPressed: () => openPhotoMapPage(context),
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: Text(context.t.photoMapEntry),
                ),
              ],
            ),
          ),
          Expanded(
            child: _C2Async<List<FotoGeocodingPlaceDto>>(
              value: RiverpodAsync(value),
              emptyTitle: photoC2(PhotoC2TextKeys.geocodingEmpty, '还没有带地点的照片'),
              emptyIcon: Icons.place_outlined,
              isEmpty: (l) => l.isEmpty,
              onRetry: () => ref.invalidate(geocodingPlacesProvider),
              builder: (list) => ListView.builder(
                padding: const EdgeInsets.only(bottom: Gap.xl),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final p = list[i];
                  return DesignRowTile(
                    key: Key('photo-c2-place-${p.id}'),
                    leading: const Icon(Icons.place_outlined),
                    title: Text(p.displayName),
                    subtitle: p.itemCount == 0
                        ? null
                        : Text(
                            photoC2Fill(
                              PhotoC2TextKeys.geocodingItemCount,
                              '{count} 张照片',
                              {'count': '${p.itemCount}'},
                            ),
                          ),
                    // 点进去看这个地点的照片（`Browse.Item/list` +
                    // `geocoding_id`，见 `foto_api.dart` 的 `geocodingItems`）
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 「在地图中打开」：只拼 URL 交给系统，零依赖零 key。
                        // 第一期**没有经纬度**（DTO 里就没有），所以是"按地名搜索"，
                        // 弹层里会如实说明（见 photo_map_sheet.dart）。
                        IconButton(
                          key: Key('photo-map-place-${p.id}'),
                          tooltip: photoMap(PhotoMapTextKeys.open, '在地图中打开'),
                          icon: const Icon(Icons.map_outlined),
                          onPressed: () =>
                              showPhotoMapSheet(context, name: p.displayName),
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _PlaceItemsPage(place: p),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 某个地点的照片（`Browse.Item/list` + `geocoding_id`）。
class _PlaceItemsPage extends ConsumerWidget {
  const _PlaceItemsPage({required this.place});

  final FotoGeocodingPlaceDto place;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final space = ref.watch(fotoSpaceProvider);
    final value = ref.watch(
      photoGeocodingItemsProvider((space: space, geocodingId: place.id)),
    );
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-place-items-page'),
      title: place.displayName,
      body: _C2Async<List<FotoItemDto>>(
        value: RiverpodAsync(value),
        emptyTitle: photoP1(PhotoP1TextKeys.placeItemsEmpty, '这个地点还没有照片'),
        emptyIcon: Icons.place_outlined,
        isEmpty: (l) => l.isEmpty,
        onRetry: () => ref.invalidate(
          photoGeocodingItemsProvider((space: space, geocodingId: place.id)),
        ),
        builder: (items) => PhotoGrid(
          key: const Key('photo-c2-place-items-grid'),
          items: items,
          space: space,
          onTap: (i) => _openViewer(context, items, i),
        ),
      ),
    );
  }
}

// ================================================================ 搜索
class PhotoSearchPage extends ConsumerStatefulWidget {
  const PhotoSearchPage({super.key});

  @override
  ConsumerState<PhotoSearchPage> createState() => _PhotoSearchPageState();
}

class _PhotoSearchPageState extends ConsumerState<PhotoSearchPage> {
  final _controller = TextEditingController();
  String _keyword = '';

  /// 正在输入的词（**防抖后**才用来取建议；`_keyword` 才是已提交的搜索词）
  String _typed = '';
  Timer? _debounce;

  /// 筛选面板选中的组 → 值（组名逐字来自 `Search.Filter/list`，如 `camera`）。
  /// 值一律是数组（官方筛选 reducer 的 `condition[组名] = [id…]`）。
  Map<String, List<Object?>> _filters = const {};

  bool get _hasQuery => _keyword.isNotEmpty || _filters.isNotEmpty;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 输入 → 300ms 防抖 → 取建议（`Search.Search/suggest`）。
  ///
  /// 防抖是**必须**的：每敲一个字符发一次 `suggest` 会把 NAS 打满，
  /// 而且返回顺序错乱时建议会跳。官方前端也是 onChange 才拉。
  void _onChanged(String raw) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _typed = raw.trim());
    });
  }

  void _commit(String value) {
    _controller.text = value;
    _debounce?.cancel();
    setState(() {
      _typed = '';
      _keyword = value.trim();
    });
    // P24：提交过就算一次"最近搜索"（空词不入历史；去重/裁剪在 notifier 里）
    if (_keyword.isNotEmpty) {
      unawaited(ref.read(photoSearchHistoryProvider.notifier).record(_keyword));
    }
    _search();
  }

  /// 发一次搜索（关键词 + 筛选面板）。游标/分页在 provider 里。
  void _search() {
    ref
        .read(photoSearchResultsProvider.notifier)
        .search(
          keyword: _keyword,
          filter: {
            for (final e in _filters.entries)
              if (e.value.isNotEmpty) e.key: e.value,
          },
        );
  }

  Future<void> _openFilters() async {
    final picked = await showModalBottomSheet<Map<String, List<Object?>>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SearchFilterSheet(initial: _filters),
    );
    if (picked == null || !mounted) return;
    setState(() => _filters = picked);
    if (_keyword.isNotEmpty || picked.isNotEmpty) _search();
  }

  @override
  Widget build(BuildContext context) {
    final space = ref.watch(fotoSpaceProvider);
    final activeFilters = _filters.values.where((v) => v.isNotEmpty).length;
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-search-page'),
      title: photoC2(PhotoC2TextKeys.search, '搜索照片'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: TextField(
              key: const Key('photo-c2-search-field'),
              controller: _controller,
              decoration: InputDecoration(
                hintText: photoC2(
                  PhotoC2TextKeys.searchHint,
                  '搜索文件名 / 地点 / 标签 / 人物 / 相机',
                ),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const Key('photo-c2-search-filter'),
                      tooltip: photoWave2(
                        PhotoWave2TextKeys.searchFilter,
                        '筛选',
                      ),
                      icon: Badge(
                        isLabelVisible: activeFilters > 0,
                        label: Text('$activeFilters'),
                        child: const Icon(Icons.tune),
                      ),
                      onPressed: _openFilters,
                    ),
                    IconButton(
                      key: const Key('photo-c2-search-go'),
                      icon: const Icon(Icons.search),
                      onPressed: () => _commit(_controller.text),
                    ),
                  ],
                ),
              ),
              onChanged: _onChanged,
              onSubmitted: _commit,
            ),
          ),
          if (activeFilters > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  photoWave2Fill(
                    PhotoWave2TextKeys.searchFilterActive,
                    '已启用 {count} 组筛选',
                    {'count': '$activeFilters'},
                  ),
                  key: const Key('photo-c2-search-filter-active'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          Expanded(
            child: _hasQuery
                ? _SearchResults(space: space)
                : _typed.isNotEmpty
                ? _SearchSuggestions(typed: _typed, onPick: _commit)
                // P24：空态先给"最近搜索"（有历史时）；没历史才是原来的引导。
                : _SearchHistoryList(onPick: _commit),
          ),
        ],
      ),
    );
  }
}

/// 最近搜索（P24）。
///
/// 官方证据：`id/search_history_keyword`、`menu/popup_menu_search_history`、
/// `string/delete_all_history`；服务端**没有** history 方法，官方也是本地保存。
/// 历史来自 [photoSearchHistoryProvider]（落盘，见 `photo_search_history.dart`）。
///
/// 没有历史时**回落到原来的空态引导**（不把"输入关键词开始搜索"这句弄丢）。
class _SearchHistoryList extends ConsumerWidget {
  const _SearchHistoryList({required this.onPick});

  /// 点一条历史 → 直接重搜（复用提交路径，会把它提到最前）。
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(photoSearchHistoryProvider);
    if (history.isEmpty) {
      return AppEmptyState(
        key: const Key('photo-c2-search-empty'),
        icon: Icons.search,
        title: photoC2(PhotoC2TextKeys.searchNoKeyword, '输入关键词开始搜索'),
      );
    }
    return ListView(
      key: const Key('photo-search-history'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                photoG1(PhotoG1TextKeys.searchHistoryTitle, '最近搜索'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              key: const Key('photo-search-history-clear'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await ref.read(photoSearchHistoryProvider.notifier).clear();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      photoG1(PhotoG1TextKeys.searchHistoryCleared, '已清除搜索历史'),
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.delete_sweep_outlined, size: 16),
              label: Text(photoG1(PhotoG1TextKeys.searchHistoryClear, '清除历史')),
            ),
          ],
        ),
        for (final keyword in history)
          DesignRowTile(
            key: Key('photo-search-history-item-$keyword'),
            dense: true,
            leading: const Icon(Icons.history, size: 18),
            title: Text(keyword),
            trailing: IconButton(
              key: Key('photo-search-history-remove-$keyword'),
              tooltip: context.t.dtoActionDelete,
              icon: const Icon(Icons.close, size: 16),
              onPressed: () =>
                  ref.read(photoSearchHistoryProvider.notifier).remove(keyword),
            ),
            onTap: () => onPick(keyword),
          ),
      ],
    );
  }
}

/// 搜索筛选面板（`Search.Filter/list` v4）。
///
/// 数据源就是服务端的真实分组（`aperture` / `camera` / `exposure_time_group` …）；
/// **认不出任何可显示项**（或请求失败）时给明确提示 + 重试 —— 绝不显示成"没有
/// 筛选项"的空面板。
class _SearchFilterSheet extends ConsumerStatefulWidget {
  const _SearchFilterSheet({required this.initial});

  final Map<String, List<Object?>> initial;

  @override
  ConsumerState<_SearchFilterSheet> createState() => _SearchFilterSheetState();
}

class _SearchFilterSheetState extends ConsumerState<_SearchFilterSheet> {
  late final Map<String, Set<Object?>> _selected = {
    for (final e in widget.initial.entries) e.key: {...e.value},
  };

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(photoSearchFiltersProvider);
    final count = _selected.values.fold<int>(0, (a, b) => a + b.length);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          key: const Key('photo-c2-search-filter-sheet'),
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        photoWave2(
                          PhotoWave2TextKeys.searchFilterTitle,
                          '筛选条件',
                        ),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      key: const Key('photo-c2-search-filter-clear'),
                      onPressed: () => setState(_selected.clear),
                      child: Text(
                        photoWave2(PhotoWave2TextKeys.searchFilterClear, '清空'),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _C2Async<List<FotoSearchFilterGroupDto>>(
                  value: RiverpodAsync(value),
                  emptyTitle: photoWave2(
                    PhotoWave2TextKeys.searchFilterUnavailable,
                    '筛选项暂时不可用',
                  ),
                  emptyIcon: Icons.filter_alt_off_outlined,
                  isEmpty: (groups) => groups.isEmpty,
                  onRetry: () => ref.invalidate(photoSearchFiltersProvider),
                  builder: (groups) => ListView(
                    children: [
                      for (final g in groups) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            Gap.md,
                            Gap.sm,
                            Gap.md,
                            Gap.xs,
                          ),
                          child: Text(
                            _groupLabel(g.key),
                            key: Key('photo-c2-search-filter-group-${g.key}'),
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        for (final o in g.options)
                          DesignCheckRow(
                            key: Key(
                              'photo-c2-search-filter-option-${g.key}-${o.label}',
                            ),
                            dense: true,
                            value: _selected[g.key]?.contains(o.value) ?? false,
                            title: Text(o.label),
                            onChanged: (on) => setState(() {
                              final set = _selected.putIfAbsent(
                                g.key,
                                () => {},
                              );
                              if (on) {
                                set.add(o.value);
                              } else {
                                set.remove(o.value);
                              }
                              if (set.isEmpty) _selected.remove(g.key);
                            }),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: FilledButton(
                  key: const Key('photo-c2-search-filter-apply'),
                  onPressed: () => Navigator.of(context).pop({
                    for (final e in _selected.entries)
                      if (e.value.isNotEmpty) e.key: e.value.toList(),
                  }),
                  child: Text(
                    count == 0
                        ? photoWave2(PhotoWave2TextKeys.searchFilterApply, '应用')
                        : context.t.photoWave2SearchFilterApplyCount(count),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 组名 → 可显示标题。组名是**服务端键**（`aperture` / `camera` …），
  /// 没有逐字文案表，所以按既有 `kFotoConditionTypes` 的中文习惯给一个映射，
  /// 认不出就原样显示组名（组名不是内部 id，是稳定的接口枚举）。
  static String _groupLabel(String key) => switch (key) {
    'aperture' => photoC2(PhotoC2TextKeys.groupAperture, '光圈'),
    'camera' => photoC2(PhotoC2TextKeys.groupCamera, '相机'),
    'lens' => photoC2(PhotoC2TextKeys.groupLens, '镜头'),
    'iso' => 'ISO',
    'flash' => photoC2(PhotoC2TextKeys.groupFlash, '闪光灯'),
    'exposure_time_group' => photoC2(PhotoC2TextKeys.groupExposureTime, '曝光时间'),
    'focal_length_group' => photoC2(PhotoC2TextKeys.groupFocalLength, '焦距'),
    'geocoding' => photoC2(PhotoC2TextKeys.groupGeocoding, '地点'),
    'person' => photoC2(PhotoC2TextKeys.groupPerson, '人物'),
    'general_tag' => photoC2(PhotoC2TextKeys.groupTag, '标签'),
    'concept' => photoC2(PhotoC2TextKeys.groupConcept, '场景'),
    'rating' => photoC2(PhotoC2TextKeys.groupRating, '评分'),
    'favorite' => photoC2(PhotoC2TextKeys.groupFavorite, '收藏'),
    'time' => photoC2(PhotoC2TextKeys.groupTime, '时间'),
    'item_type' => photoC2(PhotoC2TextKeys.groupItemType, '媒体类型'),
    _ => key,
  };
}

/// 搜索建议列表（`Search.Search / suggest`，官方取回后按 `type` 排序 + `slice(0,10)`）。
///
/// 官方每个建议项形如 `{type, id, name, passphrase, value}`（`Bt`/`F4` 原文），
/// 点下去是**跳到那个实体**；本仓库先退化为"用它再搜一次关键词"（见实施记录，
/// 实体跳转登记为待接线）。
class _SearchSuggestions extends ConsumerWidget {
  const _SearchSuggestions({required this.typed, required this.onPick});

  final String typed;
  final ValueChanged<String> onPick;

  /// 官方 `Be = e.slice(0, 10)`：建议最多 10 条。
  static const int _limit = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(searchSuggestProvider(typed));
    return _C2Async<List<Map<String, dynamic>>>(
      value: RiverpodAsync(value),
      emptyTitle: photoP1(PhotoP1TextKeys.searchSuggestEmpty, '没有搜索建议'),
      emptyIcon: Icons.search_off,
      isEmpty: (l) => l.isEmpty,
      onRetry: () => ref.invalidate(searchSuggestProvider(typed)),
      builder: (raw) {
        final items = raw.take(_limit).toList();
        return ListView.builder(
          key: const Key('photo-c2-search-suggest-list'),
          itemBuilder: (context, i) {
            final item = items[i];
            final name = '${item['name'] ?? ''}'.trim();
            final value = '${item['value'] ?? ''}'.trim();
            final label = name.isNotEmpty
                ? name
                : (value.isNotEmpty ? value : '${item['keyword'] ?? ''}');
            final type = '${item['type'] ?? ''}';
            return DesignRowTile(
              key: Key('photo-c2-search-suggest-$i'),
              leading: Icon(_iconFor(type)),
              title: Text(label),
              subtitle: type.isEmpty
                  ? null
                  : Text(
                      photoP1Fill(
                        PhotoP1TextKeys.searchSuggestTitle,
                        '建议 · {type}',
                        {'type': type},
                      ),
                    ),
              onTap: () {
                final q = label.isNotEmpty ? label : value;
                if (q.isNotEmpty) onPick(q);
              },
            );
          },
          itemCount: items.length,
        );
      },
    );
  }

  static IconData _iconFor(String type) => switch (type) {
    'person' => Icons.face_retouching_natural_outlined,
    'concept' => Icons.auto_awesome_outlined,
    'general_tag' => Icons.label_outline,
    'album' || 'normal' => Icons.photo_album_outlined,
    'folder' => Icons.folder_outlined,
    'geocoding' => Icons.place_outlined,
    _ => Icons.search,
  };
}

/// 搜索结果网格（`Search.Search/list_item` **v7**，`offset`/`limit` 分页）。
///
/// 分页状态在 [photoSearchResultsProvider] 里：这里只负责"触底续取 + footer"。
/// 失败由 `_C2Async` 给"加载失败 + 重试"（**不是空结果**）。
class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.space});

  final FotoSpace space;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(photoSearchResultsProvider);
    return _C2Async<PhotoSearchState>(
      value: RiverpodAsync(value),
      emptyTitle: photoC2(PhotoC2TextKeys.searchEmpty, '没有匹配的照片'),
      emptyIcon: Icons.search_off,
      isEmpty: (s) => s.isEmpty,
      onRetry: () => ref.read(photoSearchResultsProvider.notifier).retry(),
      builder: (state) => NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 600) {
            ref.read(photoSearchResultsProvider.notifier).loadMore();
          }
          return false;
        },
        child: CustomScrollView(
          slivers: [
            PhotoGrid(
              key: const Key('photo-c2-search-grid'),
              items: state.items,
              space: space,
              sliver: true,
              onTap: (i) => _openViewer(context, state.items, i),
            ),
            SliverToBoxAdapter(
              child: _SearchFooter(
                state: state,
                onLoadMore: () =>
                    ref.read(photoSearchResultsProvider.notifier).loadMore(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 搜索结果的"加载更多" footer（文案复用 wave1 的分页 key）。
class _SearchFooter extends StatelessWidget {
  const _SearchFooter({required this.state, required this.onLoadMore});

  final PhotoSearchState state;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(Gap.md),
        child: Center(
          child: CircularProgressIndicator(
            key: Key('photo-c2-search-loading-more'),
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
              key: const Key('photo-c2-search-load-more-error'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton(
              key: const Key('photo-c2-search-load-more-retry'),
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
            key: const Key('photo-c2-search-load-more'),
            onPressed: onLoadMore,
            child: Text(photoWave1(PhotoWave1TextKeys.loadMore, '加载更多')),
          ),
        ),
      );
    }
    return const SizedBox(height: Gap.md);
  }
}

// ================================================================ 条件相册

class PhotoConditionAlbumPage extends ConsumerWidget {
  const PhotoConditionAlbumPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(conditionAlbumsProvider);
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-condition-page'),
      title: photoC2(PhotoC2TextKeys.conditionAlbum, '条件相册'),
      body: _C2Async<List<FotoConditionAlbumDto>>(
        value: RiverpodAsync(value),
        emptyTitle: photoC2(PhotoC2TextKeys.conditionAlbumEmpty, '还没有条件相册'),
        emptyIcon: Icons.auto_awesome_motion_outlined,
        // 空列表**也要**能新建：不能走 `_C2Async` 的空态（那样"新建"入口会消失）
        isEmpty: (l) => false,
        onRetry: () => ref.invalidate(conditionAlbumsProvider),
        builder: (list) => list.isEmpty
            ? Column(
                children: [
                  const _ConditionCreateTile(),
                  Expanded(
                    child: Center(
                      child: Text(
                        photoC2(PhotoC2TextKeys.conditionAlbumEmpty, '还没有条件相册'),
                      ),
                    ),
                  ),
                ],
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: Gap.xl),
                itemCount: list.length + 1,
                itemBuilder: (context, i) {
                  // 第 0 行是"新建"入口（`Browse.ConditionAlbum/create` **v4**）
                  if (i == 0) return const _ConditionCreateTile();
                  final album = list[i - 1];
                  return DesignRowTile(
                    key: Key('photo-c2-condition-${album.id}'),
                    leading: const Icon(Icons.filter_alt_outlined),
                    title: Text(album.name),
                    subtitle: Text(
                      album.hasCondition
                          ? photoC2Fill(
                              PhotoC2TextKeys.conditionSummary,
                              '条件：{summary}',
                              {'summary': _conditionSummary(album.condition)},
                            )
                          : photoC2(PhotoC2TextKeys.conditionNone, '空条件'),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: Key('photo-c2-condition-edit-${album.id}'),
                          tooltip: photoP1(
                            PhotoP1TextKeys.conditionEdit,
                            '编辑条件',
                          ),
                          icon: const Icon(Icons.tune),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  _ConditionAlbumEditorPage(existing: album),
                            ),
                          ),
                        ),
                        IconButton(
                          key: Key('photo-c2-condition-delete-${album.id}'),
                          tooltip: photoC2(
                            PhotoC2TextKeys.conditionAlbumDelete,
                            '删除条件相册',
                          ),
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _confirmDelete(context, ref, album),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  /// 条件摘要：把 `condition_object` 的键翻成中文标签（键名逐字来自官方
  /// `ui/react_bundle.js` 模块 `96904` 的 `CP` 枚举）。
  /// 服务端 `condition_object` 里的**记账键**（不是用户选的条件）：
  /// `user_id` 每条都有，`<type>_policy` 是"同时/任一满足"的开关
  /// ⇒ 摘要里一律不显示（显示出来就是"其它条件"）。
  static const Set<String> _conditionNonKeys = {'user_id'};

  static bool _isConditionKey(String key) =>
      !_conditionNonKeys.contains(key) && !key.endsWith('_policy');

  /// ★ DA78（r417）：原来把 `condition_object` 的**所有键**都当条件翻，
  /// 于是真机上刚建好的"相机"条件相册读作 `Condition: Camera · Other`
  /// —— 那个 "Other" 就是记账键 `user_id`（读数见
  /// `docs/evidence-r417/nas/r417_after_cond_save.log`：
  /// `condition={"camera":[23],"user_id":4}`）。
  static String _conditionSummary(Map<String, dynamic> condition) {
    final parts = <String>[];
    for (final key in condition.keys) {
      if (!_isConditionKey(key)) continue;
      parts.add(_conditionKind(key));
    }
    return parts.isEmpty
        ? photoC2(PhotoC2TextKeys.conditionNone, '空条件')
        : parts.join(' · ');
  }

  static String _conditionKind(String key) => photoC2ConditionKindLabel(key);

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    FotoConditionAlbumDto album,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          photoC2(PhotoC2TextKeys.conditionAlbumDeleteConfirm, '删除条件相册？'),
        ),
        content: Text(
          photoC2Fill(
            PhotoC2TextKeys.conditionAlbumDeleteBody,
            '「{name}」会被移入回收站（照片本身不受影响）。',
            {'name': album.name},
          ),
        ),
        actions: [
          TextButton(
            key: const Key('photo-c2-condition-delete-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-c2-condition-delete-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.dtoActionDelete),
          ),
        ],
      ),
    );
    // 取消 → **一个请求都不发**
    if (ok != true) return;
    try {
      // 条件相册与普通相册共用同一张删除表（官方 `ui/react_bundle.js` 的
      // `DeleteAlbum` 动作对三种 albumType 都发 `Browse.Album/delete`）
      await ref.read(photoAlbumActionsProvider).remove([album.id]);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            photoC2(PhotoC2TextKeys.conditionAlbumDeleted, '条件相册已删除'),
          ),
        ),
      );
      ref.invalidate(conditionAlbumsProvider);
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(_c2Error(err, l10n))));
    }
  }
}

/// 「新建条件相册」入口（空列表时也要在，否则没相册就永远建不了）。
class _ConditionCreateTile extends StatelessWidget {
  const _ConditionCreateTile();

  @override
  Widget build(BuildContext context) => DesignRowTile(
    key: const Key('photo-c2-condition-create'),
    leading: const Icon(Icons.add),
    title: Text(photoP1(PhotoP1TextKeys.conditionCreate, '新建条件相册')),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const _ConditionAlbumEditorPage(),
      ),
    ),
  );
}

// ================================================================ 条件相册编辑
/// 条件相册的新建 / 编辑页。
///
/// 用到的四个官方 API：
///   * `Browse.ConditionAlbum/suggest`（v4）—— 条件值联想，参数 `A(user_id,
///     keyword, condition)`，`condition` 是**类型白名单数组**；
///   * `Browse.ConditionAlbum/peek_item_count`（v4）—— `{condition:…}` → `{count}`；
///   * `Browse.ConditionAlbum/create`（v4）—— `{name, condition}` → `{album}`；
///   * `Browse.ConditionAlbum/set_condition`（v4）—— `{id, condition}`，官方随后
///     再发 `Album/set_name` 改名。
///
/// `condition` 的**逐字**形状来自官方 Web 模块 `84966` 的 `function S(...)`：
/// ```
/// h = {user_id: e, item_type: p(n)}          // p(all)=[], p(photo)=[-1], p(video)=[-2]
/// t.length && (h.folder_filter = t)
/// (i!==ANY || a!==ANY) && (h.time = [{start_time? , end_time?}])
/// u.length && (h.rating = u)
/// d && (h.favorite = [true])
/// 每个 (类型, 值[]):
///   keyword            → h.keyword = 值.map(v => v.name)      // 字符串数组
///   et 里的类型         → h[类型] = 值.map(v => v.additional)   // 区间对象
///   其它                → h[类型] = 值.map(v => v.id)           // id 数组
///   带 policy 的类型     → h[policyKey] = policy
/// ```
class _ConditionAlbumEditorPage extends ConsumerStatefulWidget {
  const _ConditionAlbumEditorPage({this.existing});

  final FotoConditionAlbumDto? existing;

  @override
  ConsumerState<_ConditionAlbumEditorPage> createState() =>
      _ConditionAlbumEditorPageState();
}

class _ConditionAlbumEditorPageState
    extends ConsumerState<_ConditionAlbumEditorPage> {
  /// 本编辑器**开放**的条件类型（都是"值取 id"的类型）。
  ///
  /// 只开放这 6 个是**界面取舍**，不是取证结论：`time`（需要起止时间选择器）、
  /// `focal_length_group` / `exposure_time_group`（值是 `{start,end}` 区间）、
  /// `rating` / `favorite` / `folder_filter` 本批不做，见实施记录的「待接线」。
  static const List<String> _openTypes = [
    'person',
    'concept',
    'general_tag',
    'geocoding',
    'camera',
    'lens',
  ];

  final _name = TextEditingController();
  final _keyword = TextEditingController();

  /// 类型 → 已选值（`{id, name}`）
  final Map<String, List<Map<String, dynamic>>> _values = {};

  /// 类型 → `and` / `or`（只对 `kFotoConditionPolicyKeys` 里的类型有意义）
  final Map<String, String> _policy = {};

  String _itemType = 'all';
  int? _peek;
  String? _peekError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing == null) return;
    _name.text = existing.name;
    final condition = existing.condition;
    final kw = condition['keyword'];
    if (kw is List) _keyword.text = kw.join(', ');
    final itemType = condition['item_type'];
    if (itemType is List) {
      for (final e in kFotoConditionItemTypes.entries) {
        if (e.value.length == itemType.length &&
            e.value.every(itemType.contains)) {
          _itemType = e.key;
        }
      }
    }
    for (final type in _openTypes) {
      final raw = condition[type];
      if (raw is List) {
        _values[type] = [
          for (final v in raw)
            if (v != null) {'id': v, 'name': ''},
        ];
      }
    }
    for (final e in kFotoConditionPolicyKeys.entries) {
      final raw = condition[e.value];
      if (raw is String && raw.isNotEmpty) _policy[e.key] = raw;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _keyword.dispose();
    super.dispose();
  }

  /// 组装 `condition`（形状见类注释里的 `S(...)` 原文）。
  Map<String, dynamic> _buildCondition(String userId) {
    final out = <String, dynamic>{
      'user_id': int.tryParse(userId) ?? 0,
      'item_type': kFotoConditionItemTypes[_itemType] ?? const <int>[],
    };
    final kw = [
      for (final part in _keyword.text.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (kw.isNotEmpty) out['keyword'] = kw;
    for (final type in _openTypes) {
      final picked = _values[type] ?? const [];
      if (picked.isEmpty) continue;
      out[type] = [
        for (final v in picked)
          if (v['id'] != null) v['id'],
      ];
      final policyKey = kFotoConditionPolicyKeys[type];
      if (policyKey != null) out[policyKey] = _policy[type] ?? 'and';
      final policyKey2 = '${type}_policy';
      if (policyKey == null &&
          kFotoConditionPolicyKeys.containsValue(policyKey2)) {
        out[policyKey2] = _policy[type] ?? 'and';
      }
    }
    return out;
  }

  bool get _hasAnyCondition {
    if (_keyword.text.trim().isNotEmpty) return true;
    if (_itemType != 'all') return true;
    return _values.values.any((v) => v.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final userIdAsync = ref.watch(photoConditionUserIdProvider);
    final isEdit = widget.existing != null;
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-condition-editor-page'),
      title: isEdit
          ? photoP1(PhotoP1TextKeys.conditionEdit, '编辑条件')
          : photoP1(PhotoP1TextKeys.conditionCreate, '新建条件相册'),
      body: _C2Async<String>(
        value: RiverpodAsync(userIdAsync),
        emptyTitle: photoP1(
          PhotoP1TextKeys.conditionUserIdMissing,
          '读不到当前用户 id',
        ),
        onRetry: () => ref.invalidate(photoConditionUserIdProvider),
        builder: (userId) => ListView(
          padding: const EdgeInsets.only(bottom: Gap.xl),
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: TextField(
                key: const Key('photo-c2-condition-name'),
                controller: _name,
                decoration: InputDecoration(
                  labelText: photoP1(PhotoP1TextKeys.conditionName, '相册名称'),
                ),
              ),
            ),
            // ---- 媒体类型（`item_type`）
            _section(
              context,
              photoP1(PhotoP1TextKeys.conditionItemType, '媒体类型'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Wrap(
                spacing: Gap.xs,
                children: [
                  for (final e in kFotoConditionItemTypes.entries)
                    ChoiceChip(
                      key: Key('photo-c2-condition-item-type-${e.key}'),
                      label: Text(_itemTypeLabel(e.key)),
                      selected: _itemType == e.key,
                      onSelected: (_) {
                        setState(() {
                          _itemType = e.key;
                          _peek = null;
                        });
                      },
                    ),
                ],
              ),
            ),
            // ---- 关键词（`keyword`，值是字符串数组）
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: TextField(
                key: const Key('photo-c2-condition-keyword'),
                controller: _keyword,
                decoration: InputDecoration(
                  labelText: photoP1(
                    PhotoP1TextKeys.conditionKeyword,
                    '关键词（逗号分隔）',
                  ),
                ),
                onChanged: (_) => setState(() => _peek = null),
              ),
            ),
            // ---- 条件类型（值取 id，来自 suggest）
            _section(context, photoP1(PhotoP1TextKeys.conditionType, '条件类型')),
            for (final type in _openTypes)
              _TypeRow(
                type: type,
                userId: userId,
                picked: _values[type] ?? const [],
                policy: _policy[type] ?? 'and',
                canPolicy: kFotoConditionPolicyKeys.containsKey(type),
                onPick: () => _pickValues(type, userId),
                onClear: () => setState(() {
                  _values[type] = [];
                  _peek = null;
                }),
                onPolicy: (p) => setState(() => _policy[type] = p),
              ),
            const Divider(height: Gap.lg),
            // ---- 预览条数（`peek_item_count`）
            DesignRowTile(
              key: const Key('photo-c2-condition-peek'),
              leading: const Icon(Icons.numbers),
              title: Text(photoP1(PhotoP1TextKeys.conditionPeek, '预览符合条件的照片数')),
              subtitle: Text(
                _peekError != null
                    ? _peekError!
                    : _peek == null
                    ? photoP1(PhotoP1TextKeys.conditionNoPreview, '还没有预览')
                    : photoP1Fill(
                        PhotoP1TextKeys.conditionPeekResult,
                        '符合条件的照片：{count} 张',
                        {'count': '$_peek'},
                      ),
              ),
              onTap: !_hasAnyCondition || _busy
                  ? null
                  : () => _peekCount(userId),
            ),
            // ---- 保存
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: FilledButton.icon(
                key: const Key('photo-c2-condition-save'),
                icon: const Icon(Icons.save_outlined),
                label: Text(context.t.actionSave),
                onPressed: _busy ? null : () => _save(userId, isEdit),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
    child: Text(title, style: Theme.of(context).textTheme.labelLarge),
  );

  static String _itemTypeLabel(String key) => switch (key) {
    'photo' => photoP1(PhotoP1TextKeys.conditionItemTypePhoto, '照片'),
    'video' => photoP1(PhotoP1TextKeys.conditionItemTypeVideo, '视频'),
    _ => photoP1(PhotoP1TextKeys.conditionItemTypeAll, '全部'),
  };

  /// 选条件值：`suggest`（带类型白名单）+ 关键词过滤。
  Future<void> _pickValues(String type, String userId) async {
    final picked = await showModalBottomSheet<List<Map<String, dynamic>>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ConditionValueSheet(
        type: type,
        userId: userId,
        initial: _values[type] ?? const [],
      ),
    );
    if (picked == null) return;
    setState(() {
      _values[type] = picked;
      _peek = null;
    });
  }

  /// `peek_item_count`：**用户点才发**，不做实时预览（避免每次改条件都打 NAS）。
  Future<void> _peekCount(String userId) async {
    setState(() {
      _busy = true;
      _peekError = null;
    });
    try {
      final count = await ref.read(
        conditionPeekProvider(_buildCondition(userId)).future,
      );
      if (!mounted) return;
      setState(() => _peek = count);
    } catch (err) {
      if (!mounted) return;
      setState(
        () => _peekError = photoP1(PhotoP1TextKeys.conditionPeekFailed, '预览失败'),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(String userId, bool isEdit) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.t;
    final navigator = Navigator.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(photoP1(PhotoP1TextKeys.conditionNameEmpty, '请填写相册名称')),
        ),
      );
      return;
    }
    if (!_hasAnyCondition) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(photoP1(PhotoP1TextKeys.conditionNeedOne, '至少要选一个条件')),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    final condition = _buildCondition(userId);
    try {
      final actions = ref.read(photoC2ConditionActionsProvider);
      if (isEdit) {
        await actions.update(
          albumId: widget.existing!.id,
          condition: condition,
          name: name,
        );
      } else {
        await actions.create(name: name, condition: condition);
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            isEdit
                ? photoP1(PhotoP1TextKeys.conditionUpdated, '条件相册已更新')
                : photoP1(PhotoP1TextKeys.conditionCreated, '条件相册已创建'),
          ),
        ),
      );
      navigator.pop();
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(_c2Error(err, l10n))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 一行条件类型：显示已选值数量 + 选值按钮 + （带 policy 的类型）and/or。
class _TypeRow extends StatelessWidget {
  const _TypeRow({
    required this.type,
    required this.userId,
    required this.picked,
    required this.policy,
    required this.canPolicy,
    required this.onPick,
    required this.onClear,
    required this.onPolicy,
  });

  final String type;
  final String userId;
  final List<Map<String, dynamic>> picked;
  final String policy;
  final bool canPolicy;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final ValueChanged<String> onPolicy;

  @override
  Widget build(BuildContext context) {
    return DesignRowTile(
      key: Key('photo-c2-condition-type-$type'),
      // ★ r402：原来这里硬写 `conditionKindOther` ⇒ 6 行全是 "Other"。
      title: Text(photoC2ConditionKindLabel(type)),
      subtitle: Text(
        picked.isEmpty
            ? photoP1(PhotoP1TextKeys.conditionValueEmpty, '还没有选值')
            : photoP1Fill(PhotoP1TextKeys.conditionValue, '已选 {count} 项', {
                'count': '${picked.length}',
              }),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canPolicy)
            DropdownButton<String>(
              key: Key('photo-c2-condition-policy-$type'),
              value: policy,
              onChanged: (v) => onPolicy(v ?? 'and'),
              items: [
                DropdownMenuItem(
                  value: 'and',
                  child: Text(
                    photoP1(PhotoP1TextKeys.conditionPolicyAnd, '同时满足'),
                  ),
                ),
                DropdownMenuItem(
                  value: 'or',
                  child: Text(
                    photoP1(PhotoP1TextKeys.conditionPolicyOr, '任一满足'),
                  ),
                ),
              ],
            ),
          if (picked.isNotEmpty)
            IconButton(
              key: Key('photo-c2-condition-clear-$type'),
              icon: const Icon(Icons.backspace_outlined),
              onPressed: onClear,
            ),
          IconButton(
            key: Key('photo-c2-condition-pick-$type'),
            icon: const Icon(Icons.add),
            onPressed: onPick,
          ),
        ],
      ),
    );
  }
}

/// 条件值选择表（`suggest` 的 UI）。
class _ConditionValueSheet extends ConsumerStatefulWidget {
  const _ConditionValueSheet({
    required this.type,
    required this.userId,
    required this.initial,
  });

  final String type;
  final String userId;
  final List<Map<String, dynamic>> initial;

  @override
  ConsumerState<_ConditionValueSheet> createState() =>
      _ConditionValueSheetState();
}

class _ConditionValueSheetState extends ConsumerState<_ConditionValueSheet> {
  late final Set<String> _selected = {
    for (final v in widget.initial) '${v['id']}',
  };
  String _keyword = '';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(
      conditionSuggestProvider((
        userId: widget.userId,
        keyword: _keyword,
        type: widget.type,
      )),
    );
    return SafeArea(
      child: Column(
        key: const Key('photo-c2-condition-value-sheet'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: TextField(
              key: const Key('photo-c2-condition-value-search'),
              decoration: InputDecoration(
                hintText: photoP1(
                  PhotoP1TextKeys.conditionValueSearch,
                  '搜索条件值',
                ),
              ),
              onChanged: (v) => setState(() => _keyword = v.trim()),
            ),
          ),
          if (async.isLoading && !async.hasValue)
            const Padding(
              padding: EdgeInsets.all(Gap.lg),
              child: CircularProgressIndicator(
                key: Key('photo-c2-condition-value-loading'),
              ),
            )
          else if (async.hasError && !async.hasValue)
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                key: const Key('photo-c2-condition-value-error'),
                children: [
                  Text(
                    photoP1(PhotoP1TextKeys.conditionSuggestFailed, '条件值加载失败'),
                  ),
                  TextButton(
                    key: const Key('photo-c2-condition-value-retry'),
                    onPressed: () => setState(() {}),
                    child: Text(context.t.photoRetry),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: Builder(
                builder: (context) {
                  final items = async.value ?? const [];
                  if (items.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Text(
                        photoP1(PhotoP1TextKeys.conditionSuggestEmpty, '没有可选值'),
                        key: const Key('photo-c2-condition-value-empty'),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final item = items[i];
                      final id = '${item['id'] ?? ''}';
                      final name = '${item['name'] ?? id}';
                      return DesignCheckRow(
                        key: Key('photo-c2-condition-value-$i'),
                        value: _selected.contains(id),
                        title: Text(name),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selected.add(id);
                          } else {
                            _selected.remove(id);
                          }
                        }),
                      );
                    },
                  );
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    photoP1Fill(
                      PhotoP1TextKeys.conditionValue,
                      '已选 {count} 项',
                      {'count': '${_selected.length}'},
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('photo-c2-condition-value-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.t.actionCancel),
                ),
                FilledButton(
                  style: InlineButtonStyle.filled,
                  key: const Key('photo-c2-condition-value-ok'),
                  onPressed: () {
                    final items = async.value ?? const [];
                    Navigator.of(context).pop([
                      for (final item in items)
                        if (_selected.contains('${item['id']}'))
                          {'id': item['id'], 'name': item['name']},
                    ]);
                  },
                  child: Text(context.t.actionOk),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================ 相似照片

class PhotoSimilarPage extends ConsumerWidget {
  const PhotoSimilarPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setting = ref.watch(fotoSettingProvider);
    if (setting.isLoading) {
      return PhotoC2Scaffold(
        pageKey: const Key('photo-c2-similar-page'),
        title: photoC2(PhotoC2TextKeys.similar, '相似照片'),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    // 设置里关了 `enable_similar` → 连 `Similar/get_status` 都不发
    if (setting.value?.enableSimilar != true) {
      return PhotoC2Scaffold(
        pageKey: const Key('photo-c2-similar-page'),
        title: photoC2(PhotoC2TextKeys.similar, '相似照片'),
        body: AppEmptyState(
          key: const Key('photo-c2-similar-disabled'),
          icon: Icons.collections_outlined,
          title: photoC2(PhotoC2TextKeys.similarDisabled, '相似照片未启用'),
          message: photoC2(
            PhotoC2TextKeys.similarDisabledHint,
            '在 Photos 设置里打开「相似照片」后，这里才会出现分组。',
          ),
        ),
      );
    }
    final value = ref.watch(similarStatusProvider);
    final space = ref.watch(fotoSpaceProvider);
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-similar-page'),
      title: photoC2(PhotoC2TextKeys.similar, '相似照片'),
      body: _C2Async<FotoSimilarStatusDto>(
        value: RiverpodAsync(value),
        emptyTitle: context.t.photoLoadFailed,
        onRetry: () => ref.invalidate(similarStatusProvider),
        builder: (status) {
          if (!status.ready) {
            return AppEmptyState(
              key: const Key('photo-c2-similar-indexing'),
              icon: Icons.hourglass_top,
              title: photoC2(PhotoC2TextKeys.similarIndexing, '相似索引还在跑'),
              message: photoC2Fill(
                PhotoC2TextKeys.similarIndexingHint,
                '还有 {count} 张待索引（阶段 {stage}）。',
                {'count': '${status.waitingCount}', 'stage': status.stage},
              ),
            );
          }
          return _SimilarGrid(space: space);
        },
      ),
    );
  }
}

class _SimilarGrid extends ConsumerStatefulWidget {
  const _SimilarGrid({required this.space});

  final FotoSpace space;

  @override
  ConsumerState<_SimilarGrid> createState() => _SimilarGridState();
}

class _SimilarGridState extends ConsumerState<_SimilarGrid> {
  /// 当前页大小（点"加载更多"就往上加一页）
  int _limit = kFotoSimilarPageSize;

  @override
  Widget build(BuildContext context) {
    // P17：优先走**分组视图**（官方 `SimilarVo.id` 聚合）。
    // 分组里有可操作的分组 id 时用堆叠卡片；否则退回原来的扁平网格
    // （老服务器 / `SimilarItem/list` 回落路径没有分组信息）。
    final groups = ref.watch(photoSimilarGroupsProvider(_limit));
    final grouped = groups.value;
    if (grouped != null && grouped.any((g) => g.isActionable)) {
      return Column(
        children: [
          if (grouped.length >= _limit)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('photo-c2-similar-load-more'),
                onPressed: () => setState(() => _limit += kFotoSimilarPageSize),
                child: Text(photoP1(PhotoP1TextKeys.similarLoadMore, '加载更多')),
              ),
            ),
          Expanded(
            child: ListView.separated(
              key: const Key('photo-c2-similar-groups'),
              padding: const EdgeInsets.all(12),
              itemCount: grouped.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) => _SimilarGroupCard(
                group: grouped[i],
                space: widget.space,
                onOpen: () => showPhotoSimilarGroupSheet(context, grouped[i]),
              ),
            ),
          ),
        ],
      );
    }
    // 非分组路径：**同一个 provider**（回落时每张一组）展平回原来的照片网格
    // —— 不再另开一个 provider，避免重复打 Timeline/SimilarItem。
    return _C2Async<List<FotoItemDto>>(
      value: RiverpodAsync(
        switch (groups) {
          AsyncData(:final value) => AsyncValue.data(
            [for (final g in value) ...g.items],
          ),
          AsyncError(:final error, :final stackTrace) => AsyncValue.error(
            error,
            stackTrace,
          ),
          _ => const AsyncValue.loading(),
        },
      ),
      emptyTitle: photoC2(PhotoC2TextKeys.similarEmpty, '还没有相似分组'),
      emptyIcon: Icons.collections_outlined,
      isEmpty: (l) => l.isEmpty,
      onRetry: () => ref.invalidate(photoSimilarGroupsProvider(_limit)),
      builder: (items) => Column(
        children: [
          // 刚好取满一页 → 可能还有下一页（与时间轴加载器同一判定口径）
          if (items.length >= _limit)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('photo-c2-similar-load-more'),
                onPressed: () => setState(() => _limit += kFotoSimilarPageSize),
                child: Text(photoP1(PhotoP1TextKeys.similarLoadMore, '加载更多')),
              ),
            ),
          Expanded(
            child: PhotoGrid(
              key: const Key('photo-c2-similar-grid'),
              items: items,
              space: widget.space,
              onTap: (i) => _openViewer(context, items, i),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一组相似/重复照片的堆叠卡片（P17）：封面 + "共 N 张" + 主推标记。
class _SimilarGroupCard extends StatelessWidget {
  const _SimilarGroupCard({
    required this.group,
    required this.space,
    required this.onOpen,
  });

  final FotoSimilarGroupDto group;
  final FotoSpace space;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final cover = group.cover;
    return InkWell(
      key: Key('photo-c2-similar-group-${group.id}'),
      onTap: onOpen,
      child: Row(
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: cover == null
                ? const Icon(Icons.collections_outlined)
                : PhotoThumb(request: photoThumbRequest(cover, space)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.t.photoSimilarTotalN(group.count),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (group.topPickId.isNotEmpty)
                  Text(
                    context.t.photoTopPickSelected,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

/// 相似照片一页的大小（官方时间轴加载器走 `{offset, limit}`，
/// `SimilarItem/list` 的默认也是 200）。
const int kFotoSimilarPageSize = 200;

