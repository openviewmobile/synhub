// 相册 wave2 页面层：标签浏览（标签入口 → 标签详情）+ 人物相册（含人脸条数）。
//
// 只读浏览，**不含任何写操作**（标签的重命名/删除服务端根本没有方法；
// 人物的 merge/separate/set/set_cover/add_face/delete_face 是写操作 → 本批不做，
// 登记在 `docs/photo-gaps-wave2.md` 的「后续」）。
//
// 复用既有件：`PhotoC2Scaffold`（外壳）/ `PhotoGrid` / `PhotoCell` / `PhotoAsync` /
// `PhotoAlbumTile` / `PhotoViewerPage`；分页 footer 复用 wave1 的文案 key。
library;

import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/responsive_grid.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/foto_dto.dart';
import '../../dsm/webapi.dart';
import 'photo_c2_sections.dart';
import 'photo_p0_text.dart';
import 'photo_providers.dart';
import 'photo_seen_tags.dart';
import 'photo_viewer_page.dart';
import 'photo_wave1_text.dart';
import 'photo_wave2_providers.dart';
import 'photo_wave2_text.dart';
import 'photo_widgets.dart';

void _openViewer(BuildContext context, List<FotoItemDto> items, int index) {
  Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => PhotoViewerPage(items: items, index: index),
    ),
  );
}

// ================================================================ 标签

/// 标签浏览入口页（`Browse.GeneralTag/list` v2 + `count` v2）。
class PhotoTagsPage extends ConsumerWidget {
  const PhotoTagsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(photoTagsProvider);
    final total = ref.watch(photoTagCountProvider);
    final space = ref.watch(fotoSpaceProvider).name;
    // 服务端 `list` **为空**时补上"本机见过"的标签（DA70：这台 NAS 的
    // `list/count/get` 恒空而 `suggest` 有 ⇒ 只认 list 会让本 App 建的标签
    // 在本 App 里永远看不到）。服务端有数据时**一律以服务端为准**。
    final view = photoTagView(
      server: value.value ?? const <FotoTagDto>[],
      seen: ref.watch(photoSeenTagsProvider),
      space: space,
    );
    final localNote =
        !value.isLoading && !value.hasError && view.serverIsEmptyButLocal;
    // 表头数字必须与**屏上列出来的那份**一致（服务端 count 恒 0 时尤其重要，
    // 否则就是"屏上 1 个标签、表头写 0 个"的自相矛盾）。
    final serverCount = total.value;
    final displayedCount = serverCount == null
        ? null
        : (serverCount > view.tags.length ? serverCount : view.tags.length);
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-tags-page'),
      title: photoWave2(PhotoWave2TextKeys.tags, '标签'),
      body: Column(
        children: [
          // 总数来自 `GeneralTag/count`（独立接口）；失败时**不给数字**也不报空。
          if (total.hasError)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.md,
                vertical: Gap.xs,
              ),
              child: Row(
                key: const Key('photo-c2-tag-count-error'),
                children: [
                  Expanded(
                    child: Text(
                      photoWave2(
                        PhotoWave2TextKeys.partialUnavailable,
                        '这部分内容暂时取不到，可稍后重试。',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    key: const Key('photo-c2-tag-count-retry'),
                    onPressed: () => ref.invalidate(photoTagCountProvider),
                    child: Text(context.t.photoRetry),
                  ),
                ],
              ),
            )
          else if (displayedCount != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  photoWave2Fill(PhotoWave2TextKeys.tagTotal, '共 {count} 个标签', {
                    'count': '$displayedCount',
                  }),
                  key: const Key('photo-c2-tag-total'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          // 补来的东西要**说出来源**（不静默）：服务端列表为空、这部分来自本机。
          if (localNote)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  photoWave2(
                    PhotoWave2TextKeys.tagsLocalNote,
                    '服务端标签列表当前为空，以下为本机见过的标签',
                  ),
                  key: const Key('photo-c2-tag-local-note'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          Expanded(
            child: PhotoAsync<List<FotoTagDto>>(
              // 服务端失败时照旧给错误态；成功时给"服务端 ∪ 本机见过"这一份。
              value: RiverpodAsync(
                value.hasError ? value : AsyncValue.data(view.tags),
              ),
              emptyTitle: photoWave2(PhotoWave2TextKeys.tagsEmpty, '还没有标签'),
              emptyIcon: Icons.label_outline,
              isEmpty: (tags) => tags.isEmpty,
              onRetry: () => ref.invalidate(photoTagsProvider),
              builder: (tags) => ListView.builder(
                padding: const EdgeInsets.only(bottom: Gap.xl),
                itemCount: tags.length,
                itemBuilder: (context, i) {
                  final tag = tags[i];
                  return DesignRowTile(
                    key: Key('photo-c2-tag-${tag.id}'),
                    leading: const Icon(Icons.label_outline),
                    title: Text(tag.name),
                    subtitle: tag.count > 0
                        ? Text(
                            photoWave2Fill(
                              PhotoWave2TextKeys.tagItemCount,
                              '{count} 张照片',
                              {'count': '${tag.count}'},
                            ),
                          )
                        : null,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => PhotoTagDetailPage(tag: tag),
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

/// 某个标签名下的照片（`Browse.Item/list_with_filter` v7 + `general_tag_id`）。
class PhotoTagDetailPage extends ConsumerStatefulWidget {
  const PhotoTagDetailPage({super.key, required this.tag});

  final FotoTagDto tag;

  @override
  ConsumerState<PhotoTagDetailPage> createState() => _PhotoTagDetailPageState();
}

class _PhotoTagDetailPageState extends ConsumerState<PhotoTagDetailPage> {
  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final space = ref.watch(fotoSpaceProvider);
    final async = ref.watch(photoTagItemsProvider(widget.tag.id));
    final detail = ref.watch(photoTagDetailProvider(widget.tag.id));
    // 服务端给的真总数（`GeneralTag/get`）—— 拿不到就是 null，**不许**拿
    // "已加载的条数"冒充它。
    final knownTotal = detail.value?.count;
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-tag-detail-page'),
      title: widget.tag.name,
      body: PhotoAsync<PhotoTagItemsState>(
        value: RiverpodAsync(async),
        emptyTitle: photoWave2(PhotoWave2TextKeys.tagPhotosEmpty, '这个标签还没有照片'),
        emptyIcon: Icons.label_outline,
        isEmpty: (s) => s.isEmpty,
        onRetry: () => ref.invalidate(photoTagItemsProvider(widget.tag.id)),
        builder: (state) => NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.extentAfter < 600) {
              ref
                  .read(photoTagItemsProvider(widget.tag.id).notifier)
                  .loadMore();
            }
            return false;
          },
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
                  child: Text(
                    // ★ r412 DA71：这一行**不能**在不知道总数时自称总数。
                    // 真机读数：标签 `huihubtag` 实际 112 张，而首屏（分页 100/页）
                    // 这一行写 `100 photos`，滚到底 footer 才写 `All loaded (112 photos)`
                    // ⇒ 顶部那行在撒谎。`GeneralTag/get` 在这台 NAS 上恒空
                    // （DA70 的同一现场事实）⇒ 拿不到真总数就**换一句诚实的**。
                    // ★ 两个分支各自是**字面量 key 的整调用**（不许把 key 写成三元）——
                    // 否则 `i18n_hardcoded_cjk` 守卫认不出「key ↔ 中文兜底」这层配对，
                    // 会把兜底串当硬编码中文（r412 被守卫当场抓住一次）。
                    knownTotal == null || knownTotal <= 0
                        ? photoWave2Fill(
                            PhotoWave2TextKeys.tagLoaded,
                            '已加载 {count} 张',
                            {'count': '${state.items.length}'},
                          )
                        : photoWave2Fill(
                            PhotoWave2TextKeys.tagItemCount,
                            '{count} 张照片',
                            {'count': '$knownTotal'},
                          ),
                    key: const Key('photo-c2-tag-detail-count'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: hud.dim),
                  ),
                ),
              ),
              PhotoGrid(
                key: const Key('photo-c2-tag-detail-grid'),
                items: state.items,
                space: space,
                size: 'm',
                padding: const EdgeInsets.all(Gap.sm),
                sliver: true,
                onTap: (i) => _openViewer(context, state.items, i),
              ),
              SliverToBoxAdapter(
                child: _Wave2Footer(
                  loadingMore: state.loadingMore,
                  error: state.loadMoreError,
                  hasMore: state.hasMore,
                  loaded: state.items.length,
                  onLoadMore: () => ref
                      .read(photoTagItemsProvider(widget.tag.id).notifier)
                      .loadMore(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================================================================ 人物 / 人脸

/// 人物入口页（`Browse.Person/list|count` v1 + `suggest` v3）。
///
/// 只读：点人 → 人物相册（`PhotoPersonAlbumPage`）；改名/合并/拆分/设封面
/// 都是写操作 → 本批不做。
class PhotoPersonsPage extends ConsumerStatefulWidget {
  const PhotoPersonsPage({super.key});

  @override
  ConsumerState<PhotoPersonsPage> createState() => _PhotoPersonsPageState();
}

class _PhotoPersonsPageState extends ConsumerState<PhotoPersonsPage> {
  final _controller = TextEditingController();
  String _prefix = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final setting = ref.watch(fotoSettingProvider).value;
    // NAS 端没开人脸识别 → 引导态（不发必然空的请求），与既有「人物」段同口径。
    if (setting != null && !setting.enablePerson) {
      return PhotoC2Scaffold(
        pageKey: const Key('photo-c2-persons-page'),
        title: photoWave2(PhotoWave2TextKeys.persons, '人物'),
        body: AppEmptyState(
          key: const Key('photo-c2-persons-disabled'),
          icon: Icons.face_retouching_natural_outlined,
          title: context.t.photoEmptyPersonsDisabledTitle,
          message: context.t.photoEmptyPersonsDisabledMessage,
        ),
      );
    }
    // 有搜索词 → 走 `Person/suggest`（前缀联想）；否则走 `Person/list`。
    if (_prefix.isNotEmpty) {
      final suggest = ref.watch(photoPersonSuggestProvider(_prefix));
      return PhotoC2Scaffold(
        pageKey: const Key('photo-c2-persons-page'),
        title: photoWave2(PhotoWave2TextKeys.persons, '人物'),
        body: Column(
          children: [
            _prefixField(context),
            Expanded(
              child: PhotoAsync<List<FotoPersonDto>>(
                value: RiverpodAsync(suggest),
                emptyTitle: photoWave2(
                  PhotoWave2TextKeys.personSuggestEmpty,
                  '没有匹配的人物',
                ),
                emptyIcon: Icons.person_search_outlined,
                isEmpty: (p) => p.isEmpty,
                onRetry: () =>
                    ref.invalidate(photoPersonSuggestProvider(_prefix)),
                builder: (people) => _personList(context, ref, people),
              ),
            ),
          ],
        ),
      );
    }
    final async = ref.watch(photoPersonsProvider);
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-persons-page'),
      title: photoWave2(PhotoWave2TextKeys.persons, '人物'),
      body: Column(
        children: [
          _prefixField(context),
          if (async is AsyncError<List<FotoPersonDto>>) _migrationOrError(ref),
          Expanded(
            child: PhotoAsync<List<FotoPersonDto>>(
              value: RiverpodAsync(async),
              emptyTitle: context.t.photoEmptyPersonsTitle,
              emptyMessage: context.t.photoEmptyPersonsMessage,
              emptyIcon: Icons.face_retouching_natural_outlined,
              isEmpty: (people) => people.isEmpty,
              onRetry: () => ref.invalidate(photoPersonsProvider),
              builder: (people) => _personList(context, ref, people),
            ),
          ),
        ],
      ),
    );
  }

  Widget _prefixField(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Gap.md),
    child: TextField(
      key: const Key('photo-c2-person-search'),
      controller: _controller,
      decoration: InputDecoration(
        hintText: photoWave2(PhotoWave2TextKeys.personSearchHint, '按名字前缀找人'),
        suffixIcon: IconButton(
          key: const Key('photo-c2-person-search-clear'),
          icon: const Icon(Icons.clear),
          onPressed: () {
            _controller.clear();
            setState(() => _prefix = '');
          },
        ),
      ),
      onChanged: (v) => setState(() => _prefix = v.trim()),
    ),
  );

  /// `901` = 人脸迁移未完成（**不是错误**）：给"正在整理"，别当失败。
  Widget _migrationOrError(WidgetRef ref) {
    final async = ref.watch(photoPersonsProvider);
    final error = async is AsyncError<List<FotoPersonDto>> ? async.error : null;
    if (error is! DsmApiException || error.code != 901) {
      return const SizedBox.shrink();
    }
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
    return Padding(
      key: const Key('photo-c2-persons-migrating'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: Text(
        context.t.photoPersonsMigratingLine(
          context.t.photoPersonsMigratingTitle,
          message,
        ),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  Widget _personList(
    BuildContext context,
    WidgetRef ref,
    List<FotoPersonDto> people,
  ) => GridView.builder(
    key: const Key('photo-c2-persons-grid'),
    padding: const EdgeInsets.all(Gap.md),
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      // ★ DA292 同族：宽窗里写死 2 列 ⇒ 每个人物一格 500dp 空地
      crossAxisCount: albumColumnsFor(MediaQuery.sizeOf(context).width),
      mainAxisSpacing: Gap.md,
      crossAxisSpacing: Gap.md,
      childAspectRatio: 0.86,
    ),
    itemCount: people.length,
    itemBuilder: (context, i) {
      final p = people[i];
      final name = p.name.isEmpty ? context.t.photoPersonUntitled : p.name;
      return PhotoAlbumTile(
        key: Key('photo-c2-person-${p.id}'),
        title: name,
        subtitle: p.itemCount > 0
            ? context.t.photoPhotoCount(p.itemCount)
            : null,
        iconFallback: Icons.face_retouching_natural_outlined,
        coverRequest: photoSmartAlbumCoverRequest(
          p.cover,
          ref.watch(fotoSpaceProvider),
          type: 'person',
          id: p.id,
        ),
        onTap: () => Navigator.of(context, rootNavigator: true).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => PhotoPersonAlbumPage(personId: p.id, name: name),
          ),
        ),
      );
    },
  );
}

/// 人物相册（`Browse.Item/list` v7 + `person_id`）+ 人脸条数
/// （`Browse.Person/list_face` v1，只取条数：人脸对象字段未取证，不猜）。
class PhotoPersonAlbumPage extends ConsumerWidget {
  const PhotoPersonAlbumPage({
    super.key,
    required this.personId,
    required this.name,
  });

  final String personId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final space = ref.watch(fotoSpaceProvider);
    final async = ref.watch(
      photoPersonItemsProvider((space: space, personId: personId)),
    );
    return Scaffold(
      backgroundColor: DesignPalette.of(context).bg,
      appBar: AppBar(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: PhotoAsync<List<FotoItemDto>>(
        value: RiverpodAsync(async),
        emptyTitle: context.t.photoEmptyPersonTitle,
        emptyMessage: context.t.photoEmptyPersonMessage,
        isEmpty: (items) => items.isEmpty,
        onRetry: () => ref.invalidate(
          photoPersonItemsProvider((space: space, personId: personId)),
        ),
        builder: (items) => Column(
          children: [
            _PersonFacesLine(
              personId: personId,
              itemIds: [for (final e in items) e.id],
            ),
            Expanded(
              child: PhotoGrid(
                key: const Key('photo-c2-person-album-grid'),
                items: items,
                space: space,
                size: 'm',
                onTap: (i) => _openViewer(context, items, i),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 人脸条数（`Browse.Person/list_face`）。加载中 / 失败 / 有值三态都给，
/// **失败不当空**（给"重试"）。
class _PersonFacesLine extends ConsumerWidget {
  const _PersonFacesLine({required this.personId, required this.itemIds});

  final String personId;
  final List<String> itemIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (itemIds.isEmpty) return const SizedBox.shrink();
    final key = (personId: personId, itemIdsKey: itemIds.join(','));
    final value = ref.watch(photoPersonFacesProvider(key));
    if (value.hasError) {
      return Padding(
        key: const Key('photo-c2-person-faces-error'),
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.md,
          vertical: Gap.xs,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                photoWave2(PhotoWave2TextKeys.personFacesFailed, '人脸信息暂时取不到'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              key: const Key('photo-c2-person-faces-retry'),
              onPressed: () => ref.invalidate(photoPersonFacesProvider(key)),
              child: Text(context.t.photoRetry),
            ),
          ],
        ),
      );
    }
    final count = value.value;
    if (count == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
        child: LinearProgressIndicator(
          key: Key('photo-c2-person-faces-loading'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          photoWave2Fill(PhotoWave2TextKeys.personFaces, '本页识别到 {count} 张人脸', {
            'count': '$count',
          }),
          key: const Key('photo-c2-person-faces-count'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

// ================================================================ 分页 footer

/// 标签详情 / 人物相册共用的"加载更多"，文案与行为复用 wave1（同一套 key）。
class _Wave2Footer extends StatelessWidget {
  const _Wave2Footer({
    required this.loadingMore,
    required this.error,
    required this.hasMore,
    required this.loaded,
    required this.onLoadMore,
  });

  final bool loadingMore;
  final Object? error;
  final bool hasMore;
  final int loaded;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(Gap.md),
        child: Center(
          child: CircularProgressIndicator(
            key: Key('photo-wave2-loading-more'),
          ),
        ),
      );
    }
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          children: [
            Text(
              photoWave1Fill(
                PhotoWave1TextKeys.loadMoreFailed,
                '加载下一页失败：{error}',
                {'error': describePhotoError(error!, context.t)},
              ),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton(
              key: const Key('photo-wave2-load-more-retry'),
              onPressed: onLoadMore,
              child: Text(context.t.photoRetry),
            ),
          ],
        ),
      );
    }
    if (hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Center(
          child: TextButton(
            key: const Key('photo-wave2-load-more'),
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
            'count': '$loaded',
          }),
          key: const Key('photo-wave2-all-loaded'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
