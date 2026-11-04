// C2（Photos 补齐）的 provider 层：共享相册 / 照片请求 / 地点 / 搜索 /
// 条件相册 / 相似照片。
//
// 与既有相册模块同一套约定：
//   * API 从会话里取（未连接 → null），数据一律 `autoDispose` + **关掉自动重试**；
//   * 写操作后只 invalidate，不做乐观更新（服务端是唯一事实来源）；
//   * 能力位缺失 / `105` → **该入口隐藏**；`119`/`106` → 会话提示、
//     **绝不隐藏**；未检测 → fail-open（见 [ServiceAvailabilitySnapshot.hasApi]）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../data/dto/foto_c2_dto.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/foto_api.dart';
import '../../data/foto_c2_api.dart';
import '../../data/foto_g6_api.dart';
import '../../dsm/webapi.dart';
import 'photo_g6_providers.dart';
import 'photo_providers.dart';

Duration? _noRetry(int retryCount, Object error) => null;

/// 当前空间的 C2 API（未连接 → null；个人 / 共享空间只差前缀）
final fotoC2ApiProvider = Provider<FotoC2Api?>((ref) {
  final api = ref.watch(fotoSpaceApiProvider);
  return api == null ? null : FotoC2Api(api);
});

FotoC2Api _require(Ref ref) {
  final api = ref.read(fotoC2ApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api;
}

// ---------------------------------------------------------------- 数据

final sharedWithMeAlbumsProvider =
    FutureProvider.autoDispose<List<FotoAlbumDto>>((ref) async {
      return _require(ref).sharedWithMeAlbums();
    }, retry: _noRetry);

final sharedByMeAlbumsProvider = FutureProvider.autoDispose<List<FotoAlbumDto>>(
  (ref) async {
    return _require(ref).sharedByMeAlbums();
  },
  retry: _noRetry,
);

final photoRequestsProvider =
    FutureProvider.autoDispose<List<FotoPhotoRequestDto>>((ref) async {
      return _require(ref).photoRequests();
    }, retry: _noRetry);

final geocodingPlacesProvider =
    FutureProvider.autoDispose<List<FotoGeocodingPlaceDto>>((ref) async {
      return _require(ref).geocodingPlaces();
    }, retry: _noRetry);

final conditionAlbumsProvider =
    FutureProvider.autoDispose<List<FotoConditionAlbumDto>>((ref) async {
      return _require(ref).conditionAlbums();
    }, retry: _noRetry);

final similarStatusProvider = FutureProvider.autoDispose<FotoSimilarStatusDto>((
  ref,
) async {
  return _require(ref).similarStatus();
}, retry: _noRetry);

/// 一个相册的共享信息（成员 / 外链 / 隐私级别）。
final albumSharingProvider = FutureProvider.autoDispose
    .family<FotoAlbumSharingDto?, String>((ref, albumId) async {
      return _require(ref).albumSharingInfo(albumId);
    }, retry: _noRetry);

// ================================================================ 能力门控
//
// ⚠️ 这一族是**用户点名要求**的"统一检测 → 服务端没有该服务就降级"：
//   ① 能力位缺失（`SYNO.API.Info` 里没有该 API）→ **隐藏**该入口，且**连探测
//      请求都不发**（省一次必然 102/103 的往返）；
//   ② 探测回 `105`（无权限）→ **只隐藏出事的那个入口** + 顶部"无权限"提示；
//   ③ 探测回 `119`/`106`（会话失效）→ **一个入口都不许少**，只给会话提示；
//   ④ 其它错误 / 未确定 → **fail-open**（保留入口，不因不确定而砍功能）。
// 绝不允许把这一族当死代码删掉。

/// C2 的入口各对应一个服务端能力（wave2 追加 `tags` / `persons`）。
enum PhotoC2Feature {
  sharing,
  photoRequest,
  geocoding,
  search,
  conditionAlbum,
  similar,

  /// 标签浏览（`SYNO.Foto.Browse.GeneralTag`，wave2）
  tags,

  /// 人物 / 人脸（`SYNO.Foto.Browse.Person`，wave2）
  persons,

  /// 最近添加（`SYNO.Foto.Browse.RecentlyAdded`，本批）
  recentlyAdded,

  /// 用户后台任务（`SYNO.Foto.BackgroundTask.Info`，G6）
  backgroundTask,

  /// 迁移状态（`SYNO.Foto.Migration`，G6）
  migration,
}

/// 探测结果：哪些入口可见 / 被拒 / 会话是否失效。
class PhotoC2Availability {
  const PhotoC2Availability({
    this.visible = const <PhotoC2Feature>{},
    this.denied = const <PhotoC2Feature>{},
    this.sessionExpired = false,
  });

  final Set<PhotoC2Feature> visible;
  final Set<PhotoC2Feature> denied;
  final bool sessionExpired;
}

/// wave2 的两个能力位对应的服务端 API 名。
///
/// `service_registry.dart` 在本批次**禁改**，所以这两个常量定义在这里
/// （值逐字来自真机 `SYNO.API.Info`：`SYNO.Foto.Browse.GeneralTag` /
/// `SYNO.Foto.Browse.Person`）。
const String kFotoGeneralTagApi = 'SYNO.Foto.Browse.GeneralTag';
const String kFotoPersonApi = 'SYNO.Foto.Browse.Person';

/// 「最近添加」的服务端 API 名（本批新增）。
///
/// 真机 `SYNO.API.Info` 原文：`SYNO.Foto.Browse.RecentlyAdded`
/// `{minVersion:1, maxVersion:6, path:"entry.cgi"}`（`SYNO.FotoTeam.` 同区间）。
/// `service_registry.dart` 本批禁改 → 常量就地声明。
const String kFotoRecentlyAddedApi = 'SYNO.Foto.Browse.RecentlyAdded';

/// 每个能力位对应的服务端 API 名（`SYNO.API.Info` 的能力位键）
const Map<PhotoC2Feature, String> _c2FeatureApi = {
  PhotoC2Feature.sharing: kFotoSharingApi,
  PhotoC2Feature.photoRequest: kFotoPhotoRequestApi,
  PhotoC2Feature.geocoding: kFotoGeocodingApi,
  PhotoC2Feature.search: kFotoSearchApi,
  PhotoC2Feature.conditionAlbum: kFotoConditionAlbumApi,
  PhotoC2Feature.similar: kFotoSimilarApi,
  PhotoC2Feature.tags: kFotoGeneralTagApi,
  PhotoC2Feature.persons: kFotoPersonApi,
  PhotoC2Feature.recentlyAdded: kFotoRecentlyAddedApi,
  // G6：两个**全局**只读接口（无空间前缀），常量就地声明在
  // `photo_g6_providers.dart`。
  PhotoC2Feature.backgroundTask: kFotoBackgroundTaskInfoApi,
  PhotoC2Feature.migration: kFotoMigrationApi,
};

Future<void> _probeFeature(
  FotoC2Api api,
  FotoApi? foto,
  FotoG6Api? g6,
  PhotoC2Feature feature,
) async {
  switch (feature) {
    case PhotoC2Feature.sharing:
      await api.sharedWithMeAlbums(limit: 1);
    case PhotoC2Feature.photoRequest:
      await api.photoRequests(limit: 1);
    case PhotoC2Feature.geocoding:
      await api.geocodingCount();
    case PhotoC2Feature.search:
      await api.searchFilters(const {});
    case PhotoC2Feature.conditionAlbum:
      await api.conditionAlbums(limit: 1);
    case PhotoC2Feature.similar:
      await api.similarStatus();
    // wave2：只读浏览能力，用最便宜的 `count` 探针
    case PhotoC2Feature.tags:
      await foto?.generalTagCount();
    case PhotoC2Feature.persons:
      await foto?.personCount();
    // 本批：`RecentlyAdded` 没有 `count`，用 `limit:1` 的最小列表探针
    // （`offset`/`limit` 都是必需参数，缺一会 `120` —— 所以两个都给）。
    case PhotoC2Feature.recentlyAdded:
      await foto?.recentlyAdded(limit: 1);
    // G6：两条都是**无必填参数**的只读接口，直接原样调一次就是最便宜的探针
    // （真机实测 `{"list": []}` / `{"current":2,"status":"done","total":0}`）。
    case PhotoC2Feature.backgroundTask:
      await g6?.listUserTasks();
    case PhotoC2Feature.migration:
      await g6?.migrationStatus();
  }
}

/// 逐个能力发一条**最便宜**的探测请求（串行，避免一次打六个并发）。
Future<PhotoC2Availability> _probeC2Availability(Ref ref) async {
  final api = ref.read(fotoC2ApiProvider);
  final foto = ref.read(fotoSpaceApiProvider);
  final g6 = ref.read(fotoG6ApiProvider);
  final snapshot = ref.read(serviceAvailabilityProvider);
  final visible = <PhotoC2Feature>{};
  final denied = <PhotoC2Feature>{};
  var sessionExpired = false;
  for (final feature in PhotoC2Feature.values) {
    final apiName = _c2FeatureApi[feature]!;
    // ① 能力位缺失 → 隐藏，且不发探测请求
    if (!snapshot.hasApi(StationService.photo, apiName)) continue;
    if (api == null) {
      // 没连上不算"服务端没有" → fail-open
      visible.add(feature);
      continue;
    }
    try {
      await _probeFeature(api, foto, g6, feature);
      visible.add(feature);
    } on DsmApiException catch (err) {
      if (err.code == 105) {
        denied.add(feature);
      } else if (err.code == 119 || err.code == 106) {
        // ③ 会话失效：只提示，不隐藏
        sessionExpired = true;
        visible.add(feature);
      } else {
        visible.add(feature); // ④ fail-open
      }
    } catch (_) {
      visible.add(feature); // ④ fail-open
    }
  }
  // 相似照片还看用户设置 `enable_similar`（官方 `getUserEnableSimilar`）
  if (!(ref.read(fotoSettingProvider).value?.enableSimilar ?? true)) {
    visible.remove(PhotoC2Feature.similar);
    denied.remove(PhotoC2Feature.similar);
  }
  return PhotoC2Availability(
    visible: visible,
    denied: denied,
    sessionExpired: sessionExpired,
  );
}

final photoC2AvailabilityProvider =
    FutureProvider.autoDispose<PhotoC2Availability>(
      _probeC2Availability,
      retry: _noRetry,
    );

/// 相似照片还要看用户设置 `enable_similar`（官方 `getUserEnableSimilar`）。
///
/// 设置还没读到时**不隐藏**（fail-open）：先让入口在，读到 false 再收起来。
final similarFeatureEnabledProvider = Provider<bool>((ref) {
  return ref.watch(fotoSettingProvider).value?.enableSimilar ?? true;
});

// ---------------------------------------------------------------- 搜索

/// 关键词搜索（`Search.Search / list_item` **v7**）。
///
/// 关键词走**顶层** `keyword` 参数（官方前端 `Bo(e)` 原文
/// `bS(Search.Search.list_item,{keyword:r})`；这里经
/// `FotoC2Api.searchItems` 的 filter 透传）。
final photoSearchProvider = FutureProvider.autoDispose
    .family<List<FotoItemDto>, String>((ref, keyword) async {
      if (keyword.isEmpty) return const [];
      return _require(ref).searchItems({'keyword': keyword});
    }, retry: _noRetry);

/// 搜索建议（`Search.Search / suggest` **v7**）。
///
/// 空关键词**不发请求**（返回空），避免每敲一个字符前的无谓往返。
final searchSuggestProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, keyword) async {
      final q = keyword.trim();
      if (q.isEmpty) return const [];
      return _require(ref).searchSuggest(q);
    }, retry: _noRetry);

/// 某个地点的照片（`Browse.Item/list` **v7** + `geocoding_id`）。
///
/// 与人物 / 场景两条"名下照片"同源；地点板块点进去就是这条。
final photoGeocodingItemsProvider = FutureProvider.autoDispose
    .family<List<FotoItemDto>, ({FotoSpace space, String geocodingId})>((
      ref,
      arg,
    ) async {
      final api = ref.watch(fotoSpaceApiProvider);
      final scoped = api?.inSpace(arg.space);
      if (scoped == null) throw StateError(currentText().setNotConnected);
      return scoped.geocodingItems(arg.geocodingId);
    }, retry: _noRetry);

// ---------------------------------------------------------------- 条件相册

/// 条件值联想（`Browse.ConditionAlbum / suggest` **v4**）。
///
/// 官方 `A(user_id, keyword, condition)` 的第三参 `condition` 是**条件类型白名单
/// 数组**（`ui/react_bundle.js`：`{keyword:keyword,user_id:user_id,
/// condition:condition, additional:["thumbnail"]}`），不是过滤条件本身。
///
/// ⚠️ family 的 key 只用**标量**（`userId` / `keyword` / 单个 `type`）：
/// Dart 的 record 对 `List` 字段走**同一性**比较，把 `[type]` 塞进 key 会让
/// 每次 rebuild 都算成新 provider → 永远停在 loading。白名单在这里拼。
final conditionSuggestProvider = FutureProvider.autoDispose
    .family<
      List<Map<String, dynamic>>,
      ({String userId, String keyword, String type})
    >((ref, arg) async {
      return _require(ref).suggestConditionItems(
        userId: arg.userId,
        keyword: arg.keyword,
        conditionTypes: [arg.type],
      );
    }, retry: _noRetry);

/// 条件相册预览条数（`Browse.ConditionAlbum / peek_item_count` **v4**）。
final conditionPeekProvider = FutureProvider.autoDispose
    .family<int, Map<String, dynamic>>((ref, condition) async {
      return _require(ref).peekConditionItemCount(condition);
    }, retry: _noRetry);

/// 当前用户 id —— 条件相册 `condition.user_id` 的来源。
///
/// 官方口径（`ui/react_bundle.js` 的 `function P9(e)`）：
///   * 共享空间（team space）→ 恒为 `0`，**不发任何请求**；
///   * 个人空间 → 当前用户 id（本仓库走 `UserInfo / me`）。
///
/// 个人空间拿不到 id 时**抛错**（宁可让编辑页显示错误，也不能用 0 去查别人的相册）。
final photoConditionUserIdProvider = FutureProvider.autoDispose<String>((
  ref,
) async {
  final space = ref.watch(fotoSpaceProvider);
  if (space == FotoSpace.team) return '0';
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  final id = await api.userInfoMe();
  if (id.isEmpty) {
    // 官方 Web 的个人空间条件相册一定带真实 `user_id`；读不到就**报错**，
    // 绝不退回 `0`（`0` 在官方口径里专指共享空间）。
    throw DsmApiException(DsmErrorCode.unknown);
  }
  return id;
}, retry: _noRetry);

/// 条件相册的写操作（新建 / 改条件 / 删）。
class PhotoC2ConditionActions {
  PhotoC2ConditionActions(this.ref);

  final Ref ref;

  /// 新建（`Browse.ConditionAlbum / create` **v4**）。
  Future<FotoAlbumDto?> create({
    required String name,
    required Map<String, dynamic> condition,
  }) async {
    final dto = await _require(
      ref,
    ).createConditionAlbum(name: name, condition: condition);
    ref.invalidate(conditionAlbumsProvider);
    return dto;
  }

  /// 改条件（`Browse.ConditionAlbum / set_condition` **v4**）。
  ///
  /// 官方**同时**改名字：`setCondition({id, condition})` 之后紧跟
  /// `Album/setName({id, name})`（`ui/react_bundle.js` 的 `function Rt(e)` 第 3~4 步）
  /// —— 所以这里也把改名带上（名字非空时）。
  Future<void> update({
    required String albumId,
    required Map<String, dynamic> condition,
    String? name,
  }) async {
    await _require(
      ref,
    ).setConditionAlbumCondition(albumId: albumId, condition: condition);
    final wanted = name?.trim() ?? '';
    if (wanted.isNotEmpty) {
      final spaceApi = ref.read(fotoSpaceApiProvider);
      await spaceApi?.renameAlbum(albumId: albumId, name: wanted);
    }
    ref.invalidate(conditionAlbumsProvider);
  }
}

final photoC2ConditionActionsProvider = Provider<PhotoC2ConditionActions>(
  (ref) => PhotoC2ConditionActions(ref),
);

/// 可邀请的用户 / 群组（`Sharing.Misc / list_user_group` **v1**）。
///
/// 官方 Android（jadx `ApiSharingMisc.java:38-40`）**不带任何参数**，所以这里也
/// 不传 `team_space_sharable_list`（那个键只在官方 Web 前端出现过）。
final sharableMembersProvider =
    FutureProvider.autoDispose<List<FotoSharableMemberDto>>((ref) async {
      return _require(ref).sharableMembers();
    }, retry: _noRetry);

/// ★ DA76（r417）：`set_shared(enabled:false)` 生成的外链**只在回包里**。
///
/// 真机读数（r417，NAS 侧只读回读）：生成之后 `Browse.Album/get` +
/// `additional=["sharing_info"]` 回的 `sharing_info.sharing_link` **仍是空串**
/// （`privacy_type=private`、`passphrase=<len=9>`）⇒ 界面若以 `sharingLink`
/// 为判据，"打开外链分享"这条入口**永远不会出现**，外链分享在 App 内走不通
/// （相册也永远进不了"我共享的"列表 = 本轮要验的非空分支）。
///
/// 所以：生成后把**回包里的链接**记在这里，页面用它显示 / 复制 / 继续下一步。
final photoC2GeneratedShareLinkProvider =
    NotifierProvider.family<
      PhotoC2GeneratedShareLink,
      String?,
      String
    >(PhotoC2GeneratedShareLink.new);

class PhotoC2GeneratedShareLink extends Notifier<String?> {
  PhotoC2GeneratedShareLink(this.albumId);

  final String albumId;

  @override
  String? build() => null;

  void set(String link) => state = link;

  void clear() => state = null;
}

// ---------------------------------------------------------------- 共享写操作

/// 共享相册的写操作（改成员角色 / 移除成员 / 开关外链 / 生成链接 / 设口令）。
class PhotoC2SharingActions {
  PhotoC2SharingActions(this.ref);

  final Ref ref;

  /// 生成 / 打开外链（`Sharing.Passphrase / set_shared` **v1**）。
  ///
  /// `enabled` = false 是官方"只生成链接不改可见性"，true 才是"打开外链分享"。
  /// [deactivating] = 这次调用是**关掉**一个已经公开着的相册（页面知道这件事，
  /// 服务端回包里区分不出来）：此时**不记**回包里的链接 —— 真机上这一步的回包会
  /// 把**正在作废**的那条链接原样回给我们（读数见
  /// `docs/evidence-r417/nas/r417_disable_shapes.log` ④）。
  Future<FotoAlbumSharingDto> setLink({
    required String albumId,
    required bool enabled,
    bool deactivating = false,
  }) async {
    final dto = await _require(
      ref,
    ).setAlbumShareLink(albumId: albumId, enabled: enabled);
    // ★ DA76：链接只在回包里（`album get` 在未公开时不回它）⇒ 记下来。
    // ★ DA77：**关掉**时既不留旧缓存、也不记这次回包（那条链接正在作废）。
    final notifier = ref.read(
      photoC2GeneratedShareLinkProvider(albumId).notifier,
    );
    if (deactivating) {
      notifier.clear();
    } else if (dto.sharingLink.isNotEmpty) {
      notifier.set(dto.sharingLink);
    }
    ref.invalidate(albumSharingProvider);
    return dto;
  }

  Future<void> updateSharing({
    required String passphrase,
    String? privacyType,
    List<FotoShareMemberDto> members = const [],
    List<FotoShareMemberDto> removedMembers = const [],
    int? expiration,
    String? password,
  }) async {
    await _require(ref).updateAlbumSharing(
      passphrase: passphrase,
      privacyType: privacyType,
      members: members,
      removedMembers: removedMembers,
      expiration: expiration,
      password: password,
    );
    ref.invalidate(albumSharingProvider);
  }
}

final photoC2SharingActionsProvider = Provider<PhotoC2SharingActions>(
  PhotoC2SharingActions.new,
);

/// 照片请求的写操作（目前只有"删除"这一条，官方 v1 方法表里
/// `create/update` 的参数形态没有原文 → 未实现，见实施记录）。
class PhotoC2RequestActions {
  PhotoC2RequestActions(this.ref);

  final Ref ref;

  /// 新建「照片请求」（`PhotoRequest/create` v1）。
  ///
  /// `fileSizeLimitBytes` 是**字节**（官方 `mbToByte`/`byteToMB`：界面用 MB、
  /// 线上传字节）；`expiration` 原样透传（**UI 不做任何时间换算**）。
  Future<void> create({
    required String subject,
    required bool teamLibrary,
    String description = '',
    String folderHomePath = '',
    int? fileSizeLimitBytes,
    int expiration = 0,
  }) async {
    await _require(ref).createPhotoRequest(
      subject: subject,
      description: description,
      teamLibrary: teamLibrary,
      folderHomePath: folderHomePath,
      fileSizeLimitBytes: fileSizeLimitBytes,
      expiration: expiration,
    );
    ref.invalidate(photoRequestsProvider);
  }

  /// 改一条「照片请求」（`PhotoRequest/update` v1，首字段 passphrase 定位）。
  Future<void> update({
    required String passphrase,
    required String subject,
    required bool teamLibrary,
    String description = '',
    String folderHomePath = '',
    int? fileSizeLimitBytes,
    int expiration = 0,
  }) async {
    await _require(ref).updatePhotoRequest(
      passphrase: passphrase,
      subject: subject,
      description: description,
      teamLibrary: teamLibrary,
      folderHomePath: folderHomePath,
      fileSizeLimitBytes: fileSizeLimitBytes,
      expiration: expiration,
    );
    ref.invalidate(photoRequestsProvider);
  }

  Future<void> remove(String passphrase) async {
    await _require(ref).deletePhotoRequest(passphrase);
    ref.invalidate(photoRequestsProvider);
  }
}

final photoC2RequestActionsProvider = Provider<PhotoC2RequestActions>(
  PhotoC2RequestActions.new,
);
