// C2（Photos 补齐）协议层：共享相册 / 照片请求 / 地点 / 搜索 / 条件相册 / 相似照片。
//
// ★ 事实来源，逐条对照，**不猜**（SynologyPhotos `1.9.1-10928`）：
//   1. 服务端能力表 `.lib`（JSON，`maxVersion` + 每个版本的 `methods`）：
//      `/tmp/spk/export_SynologyPhotos/usr/webapi/SYNO.Foto.lib`、
//      `SYNO.FotoTeam.lib`
//   2. 官方 Web 前端的**逐方法版本表**（`ui/react_bundle.js` 模块 `5137`，
//      `t2 = {Foto: d, FotoTeam: c}`）—— 官方客户端"钉死"的版本；下文每条都标了。
//   3. 官方 Web 前端的**实际调用点**（参数名与形态的原文），下文每条都摘了原文。
//   4. 服务端 `.so` 的 rodata 参数名白名单（`strings`）：参数名一律用**服务端
//      的 snake_case 形态**（`SYNO.Foto.Sharing.so` 里有 `sort_by` /
//      `sort_direction` / `shared_with_me_sort_by` / `share_status` /
//      `team_space_sharable_list` …）。官方 JS 里出现的 camelCase
//      （`sortBy`/`sortDirection`）是前端封装层的便利写法，服务端统一换算成
//      snake_case——本仓库既有 `foto_api.dart` 在真机上用的也是 snake_case。
//
// ⚠️ 本文件**只新增**，不改 `foto_api.dart` 的任何既有行为（尤其
// `downloadUrl` = `SYNO.Foto.Download` + `item_id=[…]` 那条主通道）。
library;

import '../core/i18n/data_text.dart';
import '../dsm/webapi.dart';
import 'dto/foto_c2_dto.dart';
import 'dto/foto_dto.dart';
import 'foto_api.dart';

/// C2 协议层：在既有 [FotoApi] 之上补共享 / 地点 / 搜索 / 条件相册 / 相似。
///
/// 复用 [FotoApi] 的**空间前缀**、能力表协商与 JSON 串编码约定；自己不发任何
/// 请求之外的事情（无缓存、无重试）。
class FotoC2Api {
  const FotoC2Api(this.foto);

  final FotoApi foto;

  DsmWebApi get api => foto.api;
  FotoSpace get space => foto.space;

  FotoC2Api inSpace(FotoSpace s) => FotoC2Api(foto.inSpace(s));

  String _name(String apiId) => '${space.prefix}$apiId';

  int _version(String apiId, List<int> candidates) =>
      foto.negotiate(_name(apiId), candidates);

  static String js(Object? v) => FotoApi.js(v);

  static List<int> _intIds(Iterable<String> ids) => [
    for (final id in ids)
      if (int.tryParse(id) != null) int.parse(id),
  ];

  static List<T> _list<T>(
    Map<String, dynamic> data,
    T Function(Map<String, dynamic>) parse,
  ) {
    final raw = data['list'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) parse(e.cast<String, dynamic>()),
    ];
  }

  // ================================================================ 共享相册

  /// 官方前端钉死的共享相册一页大小。
  ///
  /// 证据原文（`ui/react_bundle.js`）：`SHARED_ALBUM:50`（分页常量表）。
  static const int kSharedAlbumPageSize = 50;

  /// 「与我共享」的相册（`SYNO.Foto.Sharing.Misc / list_shared_with_me_album`，**v2**）。
  ///
  /// 版本证据：官方版本表 `Sharing:{Misc:{list_shared_with_me_album:2,list_user_group:1}}`；
  /// `.lib` 的 `SYNO.Foto.Sharing.Misc` `maxVersion=2` 且 v1/v2 都只有这个方法。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function BZ(e)`）：
  /// ```
  /// bS(uF.Z.Foto.Sharing.Misc.listSharedWithMeAlbum,
  ///     {additional:["sharing_info","thumbnail","access_permission"],
  ///      offset:t, limit:n, sortBy:r, sortDirection:o})
  /// ```
  /// 参数名白名单见 `SYNO.Foto.Sharing.so` rodata：
  /// `additional` `offset` `limit` `sort_by` `sort_direction`
  /// `shared_with_me_sort_by` `shared_with_me_sort_direction` `share_status`。
  Future<List<FotoAlbumDto>> sharedWithMeAlbums({
    int offset = 0,
    int limit = kSharedAlbumPageSize,
    String sortBy = 'share_modify_time',
    String sortDirection = 'desc',
    List<String> additional = const [
      'sharing_info',
      'thumbnail',
      'access_permission',
    ],
  }) async {
    final apiId = 'Sharing.Misc';
    final data = await api.call(
      _name(apiId),
      'list_shared_with_me_album',
      preferredVersion: _version(apiId, const [2, 1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'sort_by': sortBy,
        'sort_direction': sortDirection,
        'additional': js(additional),
      },
    );
    return _list(data, FotoAlbumDto.fromJson);
  }

  /// 「我共享出去的」的相册（`Browse.Album / list` + `category=shared`，**v4**）。
  ///
  /// 版本证据：官方版本表 `Browse:{Album:{get:4,count:3,delete:1,download:2,list:4,…}}`。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，共享列表 saga `_3`）：
  /// ```
  /// {offset, limit, sortBy, sortDirection,
  ///  additional:["sharing_info","thumbnail"], category:"shared",
  ///  AlbumAPI: uF.Z.Foto.Browse.Album}
  /// ```
  /// `category` 白名单（`SYNO.Foto.Browse.so` rodata）：
  /// `["normal","all","shared","addable","normal_share_with_me"]`。
  Future<List<FotoAlbumDto>> sharedByMeAlbums({
    int offset = 0,
    int limit = kSharedAlbumPageSize,
    String sortBy = 'share_modify_time',
    String sortDirection = 'desc',
    List<String> additional = const ['sharing_info', 'thumbnail'],
  }) async {
    final apiId = 'Browse.Album';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [4, 3, 2, 1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'category': 'shared',
        'sort_by': sortBy,
        'sort_direction': sortDirection,
        'additional': js(additional),
      },
    );
    return _list(data, FotoAlbumDto.fromJson);
  }

  /// 相册的共享信息（`Browse.Album / get` + `additional=["sharing_info"]`，**v4**）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function NS(e)`）：
  /// ```
  /// bS(uF.Z.Foto.Browse.Album.get,{id:[e],additional:["sharing_info"]})
  /// ```
  /// 注意 **`id` 是数组**（和其它 `*Album.delete` 同一个形态）。
  Future<FotoAlbumSharingDto?> albumSharingInfo(String albumId) async {
    final ids = _intIds([albumId]);
    if (ids.isEmpty) return null;
    final apiId = 'Browse.Album';
    final data = await api.call(
      _name(apiId),
      'get',
      preferredVersion: _version(apiId, const [4, 3, 2, 1]),
      params: {
        'id': js(ids),
        'additional': js(const ['sharing_info']),
      },
    );
    final list = _list(data, (j) => j);
    if (list.isEmpty) return null;
    return FotoAlbumSharingDto.fromAlbumJson(list.first);
  }

  /// 取（必要时先建）相册的外链（`Sharing.Passphrase / set_shared`，**v1**）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function NS(e)` 与 `function Nx(e,t)`）：
  /// ```
  /// bS(uF.Z.Foto.Sharing.Passphrase.setShared,{policy:"album",album_id:e,enabled:!1})
  ///   // → {sharing_link, passphrase}       （case 2 直接读这两个字段）
  /// n={album_id:e,policy:"album",enabled:t}; bS(...setShared,n)
  /// ```
  /// `policy` 白名单见 `SYNO.Foto.Sharing.so` rodata（`policy`）。
  ///
  /// ⚠️ 官方语义：`enabled:false` 是**只生成链接不改可见性**（`NS` 在
  /// `sharing_link` 为空时就这么调）；`enabled:true` 才是"打开外链分享"。
  Future<FotoAlbumSharingDto> setAlbumShareLink({
    required String albumId,
    required bool enabled,
  }) async {
    final apiId = 'Sharing.Passphrase';
    final data = await api.call(
      _name(apiId),
      'set_shared',
      preferredVersion: _version(apiId, const [1]),
      params: {
        'policy': 'album',
        'album_id': albumId,
        'enabled': enabled ? 'true' : 'false',
      },
    );
    return FotoAlbumSharingDto(
      sharingLink: fText(data['sharing_link']),
      passphrase: fText(data['passphrase']),
      enabled: enabled,
    );
  }

  /// 改相册共享设置（`Sharing.Passphrase / update`，**v1**）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，模块 `19051` 的 `d` 函数 + `Nk`）：
  /// ```js
  /// d = function(passphrase, origPrivacyType, privacyType,
  ///              origPermissionList, permissionList,
  ///              hasPassword, password, expiration) {
  ///   var f = {passphrase: passphrase};
  ///   if (hasPassword) f.password = password;
  ///   if (expiration !== undefined) f.expiration = expiration;
  ///   var p = [];
  ///   var h = l(origPrivacyType, privacyType);   // 外链可见性 diff
  ///   if (h) p.push(h);
  ///   p.push(...u(origPermissionList, permissionList));  // 成员 diff
  ///   if (p.length) f.permission = p;
  ///   return f;
  /// };
  /// // 调用点：
  /// u = Nf.Uh(e,t,n,r,o,i,a,s);
  /// (0,Eo.Z)({api:"SYNO.Foto.Sharing.Passphrase",method:"update",version:1,
  ///           params:(0,n1.hH)(u), encryption:["password"]})
  /// ```
  /// 成员 diff（同模块 `u`）产生的每一项：
  /// `{action:"update"|"delete", role, member:{type:"user"|"group", id}}`；
  /// 外链 diff（同模块 `l`）产生：
  /// `{action:"delete",member:{type:"public"}}` /
  /// `{action:"update",role:"view",member:{type:"public"}}` /
  /// `{action:"update",role:"download",member:{type:"public"}}` /
  /// `{action:"update",role:"upload",member:{type:"public"}}`。
  ///
  /// **口令（[password]）的发送形态以官方 Android 为准**（jadx 1.5.3）：
  ///   * `ApiSharingPassphrase.java:48-50` 的请求签名是
  ///     `update(path, api, "update", version, @Field("passphrase") String, @FieldMap Map<String,String>)`
  ///     —— 口令**不是**单独的 `@Field`，而是并进 `@FieldMap optionalParams`；
  ///   * `:29` `KEY_PASSWORD = "password"`（该常量只在未反编译完的
  ///     `getUpdatePermissionResponse` 体里用到，jadx 标注 "Method dump skipped"）；
  ///   * `ApiSharingPassphrase.java:39` `API_VERSION = 1`；
  ///   * 全库 grep `encryption` 只命中 `SynoApiEncryption`（登录取公钥），
  ///     `Sharing.Passphrase.update` **没有**加密包装 → Android 就是**明文发 `password`**。
  ///
  /// 官方 **Web** 前端那条调用点带 `encryption:["password"]`（前端框架的通用字段加密
  /// 信号），这是**两个客户端实现的差异**：本仓库按 Android 的明文形态发，并在
  /// 实施记录里把"Web 加密形态"登记为待取证（真机若回 `400`/`402` 优先怀疑这里）。
  ///
  /// [password] 传 `''` 表示**清除口令**（官方 `setPassword("")` 分支，
  /// `isPasswordDirty = password.isNotEmpty || sharing.enablePassword`）；
  /// 传 `null` 表示**本次不改口令**（字段根本不出现 —— 既有用例断言的正是这条）。
  ///
  /// [members] 里的每一项都按官方成员 diff 的 `action:"update"` 发；
  /// [removedMembers] 按 `action:"delete"` 发（官方 `u` 函数的两条分支）。
  Future<void> updateAlbumSharing({
    required String passphrase,
    String? privacyType,
    List<FotoShareMemberDto> members = const [],
    List<FotoShareMemberDto> removedMembers = const [],
    int? expiration,
    String? password,
  }) async {
    final permission = <Map<String, dynamic>>[];
    if (privacyType != null) {
      switch (privacyType) {
        case 'private':
          permission.add({
            'action': 'delete',
            'member': {'type': 'public'},
          });
        case 'public-view':
          permission.add({
            'action': 'update',
            'role': 'view',
            'member': {'type': 'public'},
          });
        case 'public-download':
          permission.add({
            'action': 'update',
            'role': 'download',
            'member': {'type': 'public'},
          });
        case 'public-upload':
          permission.add({
            'action': 'update',
            'role': 'upload',
            'member': {'type': 'public'},
          });
        default:
          break;
      }
    }
    for (final m in members) {
      permission.add({
        'action': 'update',
        'role': m.role,
        'member': {'type': m.type, if (m.id.isNotEmpty) 'id': m.id},
      });
    }
    for (final m in removedMembers) {
      permission.add({
        'action': 'delete',
        'member': {'type': m.type, if (m.id.isNotEmpty) 'id': m.id},
      });
    }
    final params = <String, dynamic>{'passphrase': passphrase};
    if (password != null) params['password'] = password;
    if (expiration != null) params['expiration'] = '$expiration';
    if (permission.isNotEmpty) params['permission'] = js(permission);
    final apiId = 'Sharing.Passphrase';
    await api.call(
      _name(apiId),
      'update',
      preferredVersion: _version(apiId, const [1]),
      params: params,
    );
  }

  /// 可共享的用户 / 群组（`Sharing.Misc / list_user_group`，**v1**）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function NI(e)` / `function Uz()`）：
  /// ```
  /// bS(uF.Z.Foto.Sharing.Misc.listUserGroup,{team_space_sharable_list:e})
  /// bS(uF.Z.Foto.Sharing.Misc.listUserGroup)          // 只取用户组目录，不带筛选
  /// ```
  /// 参数名 `team_space_sharable_list` 见 `SYNO.Foto.Sharing.so` rodata。
  /// 响应取 `.list`（官方：`t.list`）。
  Future<List<FotoSharableMemberDto>> sharableMembers({
    bool? teamSpaceSharableList,
  }) async {
    final apiId = 'Sharing.Misc';
    final data = await api.call(
      _name(apiId),
      'list_user_group',
      preferredVersion: _version(apiId, const [1]),
      params: {
        if (teamSpaceSharableList != null)
          'team_space_sharable_list': teamSpaceSharableList ? 'true' : 'false',
      },
    );
    return _list(data, FotoSharableMemberDto.fromJson);
  }

  // ================================================================ 照片请求

  /// 「照片请求」列表（`SYNO.Foto.PhotoRequest / list`，**v1**）。
  ///
  /// 版本证据：官方版本表 `PhotoRequest:{create:1,delete:1,get:1,list:1,update:1}`；
  /// `.lib` 的 `SYNO.Foto.PhotoRequest` `maxVersion=1`。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function Fo(e)`）：
  /// ```
  /// t={offset:0,limit:5e3}; e.keyword&&(t.keyword=e.keyword);
  /// bS(uF.Z.Foto.PhotoRequest.list,t)                  // → .list
  /// ```
  Future<List<FotoPhotoRequestDto>> photoRequests({
    String keyword = '',
    int offset = 0,
    int limit = 5000,
  }) async {
    final apiId = 'PhotoRequest';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        if (keyword.isNotEmpty) 'keyword': keyword,
      },
    );
    return _list(data, FotoPhotoRequestDto.fromJson);
  }

  /// 删除一条「照片请求」（`PhotoRequest / delete`，**v1**）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function Fu(e)`）：
  /// ```
  /// n={passphrase:[t=e.passphrase]}; bS(uF.Z.Foto.PhotoRequest.delete,n)
  /// ```
  /// ⚠️ **`passphrase` 是数组**（不是裸串）。
  ///
  /// 这是**危险操作**（会让外部访客的收图链接失效）→ 页面必须先二次确认。
  Future<void> deletePhotoRequest(String passphrase) async {
    if (passphrase.isEmpty) return;
    final apiId = 'PhotoRequest';
    await api.call(
      _name(apiId),
      'delete',
      preferredVersion: _version(apiId, const [1]),
      params: {
        'passphrase': js([passphrase]),
      },
    );
  }

  /// 新建「照片请求」（`PhotoRequest / create`，**v1**）。
  ///
  /// **证据（最硬：官方安卓 APK smali 的 `@Field` 逐字）** ——
  /// `ApiPhotoRequest$PhotoRequestRequests.create` 的字段顺序与名字：
  /// ```
  /// api, method, version, subject, description, library,
  /// folder_home_path, album_id, album_passphrase, filesize_limit, expiration
  /// ```
  /// 其中 `library` 由 `ApiPhotoRequest.isTeamLibToString` 产出，取值
  /// **`shared_space` / `personal_space`**（同文件 smali 常量）。
  /// `ApiPhotoRequest` 另有 `byteToMB` / `mbToByte` ⇒ UI 用 MB，**线上传字节**。
  ///
  /// `expiration` 是 `long`（smali `J`）；调用方给**秒级时间戳**，0 = 不过期。
  Future<void> createPhotoRequest({
    required String subject,
    String description = '',
    required bool teamLibrary,
    String folderHomePath = '',
    String? albumId,
    String? albumPassphrase,
    int? fileSizeLimitBytes,
    int expiration = 0,
  }) async {
    final apiId = 'PhotoRequest';
    await api.call(
      _name(apiId),
      'create',
      preferredVersion: _version(apiId, const [1]),
      params: {
        'subject': subject,
        'description': description,
        'library': teamLibrary ? 'shared_space' : 'personal_space',
        if (folderHomePath.isNotEmpty) 'folder_home_path': folderHomePath,
        if (albumId != null && albumId.isNotEmpty) 'album_id': albumId,
        if (albumPassphrase != null && albumPassphrase.isNotEmpty)
          'album_passphrase': albumPassphrase,
        if (fileSizeLimitBytes != null && fileSizeLimitBytes > 0)
          'filesize_limit': '$fileSizeLimitBytes',
        if (expiration > 0) 'expiration': '$expiration',
      },
    );
  }

  /// 改一条「照片请求」（`PhotoRequest / update`，**v1**）。
  ///
  /// 同一份 smali 的 `update` 字段：首字段是 **`passphrase`**（定位用），
  /// 其余与 create 完全一致（`subject/description/library/folder_home_path/
  /// album_id/album_passphrase/filesize_limit/expiration`）。
  Future<void> updatePhotoRequest({
    required String passphrase,
    required String subject,
    String description = '',
    required bool teamLibrary,
    String folderHomePath = '',
    String? albumId,
    String? albumPassphrase,
    int? fileSizeLimitBytes,
    int expiration = 0,
  }) async {
    if (passphrase.isEmpty) return;
    final apiId = 'PhotoRequest';
    await api.call(
      _name(apiId),
      'update',
      preferredVersion: _version(apiId, const [1]),
      params: {
        'passphrase': passphrase,
        'subject': subject,
        'description': description,
        'library': teamLibrary ? 'shared_space' : 'personal_space',
        if (folderHomePath.isNotEmpty) 'folder_home_path': folderHomePath,
        if (albumId != null && albumId.isNotEmpty) 'album_id': albumId,
        if (albumPassphrase != null && albumPassphrase.isNotEmpty)
          'album_passphrase': albumPassphrase,
        if (fileSizeLimitBytes != null && fileSizeLimitBytes > 0)
          'filesize_limit': '$fileSizeLimitBytes',
        if (expiration > 0) 'expiration': '$expiration',
      },
    );
  }

  // ================================================================ 地点

  /// 地点（地理编码）列表（`Browse.Geocoding / list`，**v1**）。
  ///
  /// 版本证据：官方版本表 `Browse:{Geocoding:{count:1,get:1,list:1}}`；
  /// `.lib` 的 `SYNO.Foto.Browse.Geocoding` `maxVersion=1`（v1 = `count get list`）。
  ///
  /// 参数证据原文：
  ///   * 官方 Web 前端的**自动相册加载器**（`ui/react_bundle.js`，`function Cd(e)`）：
  ///     ```
  ///     AlbumAPI = getSmartAPI(ALBUM_TYPE.GEOCODING) = Foto.Browse.Geocoding
  ///     bS(r.list, {...{additional:["thumbnail"]}, ...filter})
  ///     ```
  ///     `v3(e,t,n,r,o)` 分组时读 `country_id` / `country` / `first_level`。
  ///   * 服务端 `.so` rodata（`SYNO.Foto.Browse.so`）：`geocoding_accept_language`
  ///     与 `additional` 相邻，属同一张参数白名单。
  ///
  /// `offset`/`limit` 是本 API 族通用分页参数（同 `.lib` 各 list 方法的既有用法）。
  Future<List<FotoGeocodingPlaceDto>> geocodingPlaces({
    int offset = 0,
    int limit = 200,
    String acceptLanguage = '',
  }) async {
    final apiId = 'Browse.Geocoding';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(const ['thumbnail']),
        if (acceptLanguage.isNotEmpty)
          'geocoding_accept_language': acceptLanguage,
      },
    );
    return _list(data, FotoGeocodingPlaceDto.fromJson);
  }

  /// 地点个数（`Browse.Geocoding / count`，**v1**）。官方 `r.count(filter)`。
  Future<int> geocodingCount() async {
    final apiId = 'Browse.Geocoding';
    final data = await api.call(
      _name(apiId),
      'count',
      preferredVersion: _version(apiId, const [1]),
    );
    return fInt(data['count']);
  }

  // ================================================================ 搜索

  /// 搜索照片（`Search.Search / list_item`，**v7**）。
  ///
  /// 版本证据：官方版本表
  /// `Search:{Search:{get_search_timeline:7,suggest:7,list_item:7,count_item:7,
  /// get_geocoding:7,list_basic_timeline_info:7}}`；
  /// `.lib` 的 `SYNO.Foto.Search.Search` `maxVersion=7`。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，时间轴加载 saga `function Zo(e,t)`）：
  /// ```
  /// bS(i, { offset:l.get("itemOffset"), limit:l.get("itemLimit"),
  ///         additional:["thumbnail","resolution","orientation","video_convert",
  ///                     "video_meta","address","favorite"],
  ///         ...filter })
  /// ```
  /// 其中 `i = ItemAPI = Foto.Search.Search.listItem`，`filter` 是搜索条件对象
  /// （`EF(e,t)` → `filter:(0,tw._)({},n,r)`，`n=t.search`）。
  ///
  /// [filter] 的可用键**逐字取自服务端 `.so` rodata**
  /// （`SYNO.Foto.Search.so`，`strings` 抽出的参数白名单）：
  /// `keyword`、`keyword_additional`、`start_time`、`end_time`、`geocoding_id`、
  /// `person`、`general_tag`、`condition`、`item_type`、`folder_id`、
  /// `folder_filter`、`favorite`、`album_id`、`rating`、`aperture`、`camera`、
  /// `lens`、`iso`、`exposure_time_group`、`focal_length_group`、`flash`、
  /// `person_policy`、`general_tag_policy`、`geocoding_accept_language`、
  /// `period`、`setting`、`timeline_group_unit`。
  /// 官方搜索框只发 `keyword`；带日期时另发
  /// `keyword_additional:{filtered_keyword, period:[{start,end}]}`
  /// （同文件 `function GE(e)`）。
  Future<List<FotoItemDto>> searchItems(
    Map<String, dynamic> filter, {
    int offset = 0,
    int limit = 100,
  }) async {
    final apiId = 'Search.Search';
    final data = await api.call(
      _name(apiId),
      'list_item',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(const [
          'thumbnail',
          'resolution',
          'orientation',
          'video_convert',
          'video_meta',
          'address',
          'favorite',
        ]),
        ..._encodeFilter(filter),
      },
    );
    return _list(data, FotoItemDto.fromJson);
  }

  /// 搜索结果数量（`Search.Search / count_item`，**v7**）。官方 `r.count(filter)`。
  Future<int> searchCount(Map<String, dynamic> filter) async {
    final apiId = 'Search.Search';
    final data = await api.call(
      _name(apiId),
      'count_item',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: _encodeFilter(filter),
    );
    return fInt(data['count']);
  }

  /// 搜索建议（`Search.Search / suggest`，**v7**）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function Bo(e)`）：
  /// ```
  /// bS(uF.Z.Foto.Search.Search.suggest,{keyword:r})   // → {list:[…]}
  /// ```
  Future<List<Map<String, dynamic>>> searchSuggest(String keyword) async {
    if (keyword.isEmpty) return const [];
    final apiId = 'Search.Search';
    final data = await api.call(
      _name(apiId),
      'suggest',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: {'keyword': keyword},
    );
    return _list(data, (j) => j);
  }

  /// 搜索结果的时间轴分组（`Search.Search / get_search_timeline` **v7**）。
  ///
  /// 证据（官方 Web 前端 `ui/react_bundle.js`）：
  ///   * 版本表 `Search.Search {get_search_timeline:7, suggest:7, list_item:7,
  ///     count_item:7, get_geocoding:7, list_basic_timeline_info:7}`；
  ///   * `function EY(e)` 把搜索时间轴的 `TimelineAPI` 指向
  ///     `Foto.Search.Search.getSearchTimeline`；
  ///   * 通用时间轴 saga 的原文是 **`bS(e.TimelineAPI, e.filter)`** ——
  ///     也就是**把同一份 filter 原样发过去**（`ER(e)` 里已带
  ///     `timeline_group_unit`），**没有**额外的固定参数名。
  ///
  /// 因此这里同样**原样透传** [filter]（编码约定与 [searchItems] 一致）。
  /// ⚠️ 成功回包的分组结构**未逐字取证**（真机只验了方法存在），所以返回原始
  /// Map，不猜字段；见报告「未取证清单」。
  Future<Map<String, dynamic>> searchTimeline(
    Map<String, dynamic> filter,
  ) async {
    final apiId = 'Search.Search';
    return api.call(
      _name(apiId),
      'get_search_timeline',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: _encodeFilter(filter),
    );
  }

  /// 可用筛选项（`Search.Filter / list`，**v4**）。
  ///
  /// 版本证据：官方版本表 `Search:{Filter:{list:4,list_in_similar:4}}`。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function DF(e)`：
  /// `bS(e.FilterAPI, {...e.params})`）——**整个 params 原样透传**，没有固定键。
  /// 这里同样透传，只把值统一编码成服务端要的形态。
  Future<Map<String, dynamic>> searchFilters(
    Map<String, dynamic> params,
  ) async {
    final apiId = 'Search.Filter';
    return api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [4, 3, 2, 1]),
      params: _encodeFilter(params),
    );
  }

  /// 把搜索 / 筛选条件编码成查询参数。
  ///
  /// 约定（与服务端 `SYNO.Foto.Browse.so` / `SYNO.Foto.Search.so` rodata 一致）：
  ///   * `String`/`num`/`bool` → 原样（bool 用 `true`/`false`）
  ///   * `List`/`Map` → **JSON 串**（和 `additional` 同一个约定）
  static Map<String, dynamic> _encodeFilter(Map<String, dynamic> filter) => {
    for (final e in filter.entries)
      e.key: switch (e.value) {
        null => '',
        final List<Object?> v => js(v),
        final Map<String, Object?> v => js(v),
        final bool v => v ? 'true' : 'false',
        final Object v => '$v',
      },
  };

  // ================================================================ 条件相册

  /// 条件相册列表（`Browse.ConditionAlbum / list`，**v4**）。
  ///
  /// 版本证据：官方版本表
  /// `Browse:{ConditionAlbum:{count:4,create:4,get:4,list:4,peek_item_count:4,
  /// set_condition:4,suggest:4}}`（`.lib` 同样 `maxVersion=4`，v1–v4 方法集相同）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function O8(e)`）：
  /// ```
  /// a={sort_by:o,sort_direction:i}; t?a.album_id=t:n&&(a.passphrase=n)
  /// ```
  /// 列表本身走通用的 `Browse.ConditionAlbum.list`（`OV` 那个透传 saga）。
  Future<List<FotoConditionAlbumDto>> conditionAlbums({
    int offset = 0,
    int limit = 100,
  }) async {
    final apiId = 'Browse.ConditionAlbum';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [4, 3, 2, 1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(const ['thumbnail', 'condition_object']),
      },
    );
    return _list(data, FotoConditionAlbumDto.fromJson);
  }

  /// 单个条件相册（`Browse.ConditionAlbum / get`，**v4**）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，条件相册编辑 saga）：
  /// ```
  /// r={additional:["condition_object"]}; t?r.id=[t]:n&&(r.passphrase=n);
  /// bS(uF.Z.Foto.Browse.ConditionAlbum.get,r)     // → {list:[{id, additional:{condition_object}}]}
  /// ```
  /// ⚠️ `id` 是**数组**。
  Future<FotoConditionAlbumDto?> conditionAlbum(String albumId) async {
    final ids = _intIds([albumId]);
    if (ids.isEmpty) return null;
    final apiId = 'Browse.ConditionAlbum';
    final data = await api.call(
      _name(apiId),
      'get',
      preferredVersion: _version(apiId, const [4, 3, 2, 1]),
      params: {
        'id': js(ids),
        'additional': js(const ['condition_object']),
      },
    );
    final list = _list(data, FotoConditionAlbumDto.fromJson);
    return list.isEmpty ? null : list.first;
  }

  /// 条件项候选（`Browse.ConditionAlbum / suggest`，**v4**）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，模块 `84966` 的 `A` 函数）：
  /// ```js
  /// A = function(user_id, keyword, condition = c)   // c = 条件类型白名单数组
  ///   { return {keyword:keyword, user_id:user_id, condition:condition,
  ///             additional:["thumbnail"]}; };
  /// // 调用点：P8 → bS(uF.Z.Foto.Browse.ConditionAlbum.suggest, r)
  /// ```
  /// `condition` 是**条件类型字符串数组**，取值逐字来自同文件模块 `96904` 的
  /// `CP`：`keyword`、`person`、`aperture`、`camera`、`concept`、
  /// `exposure_time_group`、`flash`、`focal_length_group`、`general_tag`、
  /// `geocoding`、`iso`、`lens`（`ee` = 这一整套）。
  ///
  /// ### ★ r402 真机订正：`keyword` 是**必填**，空搜索框要发 `%`
  ///
  /// 真机读数（2026-10-14，`SYNO.Foto.Browse.ConditionAlbum/suggest` v4，
  /// 本 NAS = Synology Photos，账号 `demo_user`）：
  ///
  /// ```
  /// 空参            → 120 {"name":"user_id","reason":"required"}
  /// 只给 user_id    → 120 {"name":"keyword","reason":"required"}   ← 必填
  /// keyword:''      → 120 {"name":"keyword","reason":"required"}   ← 空串也算"没给"
  /// keyword:'LGE'   → 200 {"camera":[{"id":23,"name":"LGE-AN10"}]}
  /// keyword:'%'     → 200 全部值                                    ← LIKE 通配
  /// keyword:'0'/'10'→ 120 {"name":"keyword","reason":"type"}        ← 纯数字串被拒
  /// 不给 condition  → 120 {"name":"condition","reason":"required"}
  /// ```
  ///
  /// 修法：空搜索框发服务端自己的 LIKE 通配 [kFotoConditionSuggestAllKeyword]
  /// （`%`），这样"打开选值面板"就能列出全部候选；否则面板必现
  /// "Failed to load values"（`120`），**条件相册实际上没法建**。
  Future<List<Map<String, dynamic>>> suggestConditionItems({
    required String userId,
    String keyword = '',
    List<String> conditionTypes = kFotoConditionTypes,
  }) async {
    final apiId = 'Browse.ConditionAlbum';
    final data = await api.call(
      _name(apiId),
      'suggest',
      preferredVersion: _version(apiId, const [4, 3, 2, 1]),
      params: {
        'user_id': userId,
        'keyword': keyword.isEmpty ? kFotoConditionSuggestAllKeyword : keyword,
        'condition': js(conditionTypes),
        'additional': js(const ['thumbnail']),
      },
    );
    return _parseSuggest(data, conditionTypes);
  }

  /// 解析 `suggest` 回包（★ r402 真机订正：真形状是**类型 → 选项数组**）。
  ///
  /// 真机回包（v4，只读探针原文）：
  /// ```
  /// keyword:'LGE' + condition:["camera"]
  ///   → {"camera":[{"id":23,"name":"LGE-AN10"}]}
  /// keyword:'LGE' + 六类型
  ///   → {"camera":[{"id":23,"name":"LGE-AN10"}],"general_tag":[],"geocoding":[],"lens":[]}
  /// ```
  /// 以前这里按 `{list:[…]}`（`_list`）解析 ⇒ 真机上**永远返回空**，面板显示
  /// "没有可选值"（DA50）。Mock 夹具当初就写成 `{list:[…]}`，所以用例一直是绿的
  /// —— **Mock 契约与真机不一致 = 假绿**。
  ///
  /// 现在：先按真形状**逐类型**取（选项里补 `type` 字段便于调用方区分），
  /// 取不到再退回兼容层 `{list:[…]}`（老夹具仍然可用）。
  static List<Map<String, dynamic>> _parseSuggest(
    Object? data,
    List<String> conditionTypes,
  ) {
    if (data is! Map) return const [];
    final out = <Map<String, dynamic>>[];
    for (final type in conditionTypes) {
      final raw = data[type];
      if (raw is! List) continue;
      for (final e in raw) {
        if (e is Map) out.add({...e.cast<String, dynamic>(), 'type': type});
      }
    }
    if (out.isNotEmpty) return out;
    return _list(Map<String, dynamic>.from(data), (j) => j);
  }

  /// 条件相册的**预览条数**（`Browse.ConditionAlbum / peek_item_count`，**v4**）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function Rd(e)`）：
  /// ```
  /// l=(0,It.qN)(e,t,n,r,o,i,a,s,u);
  /// bS(uF.Z.Foto.Browse.ConditionAlbum.peekItemCount,l)   // → {count}
  /// ```
  /// `qN = w`（同模块）：`w = (...) => ({condition: S(...)})` —— 所以只有 `condition`。
  Future<int> peekConditionItemCount(Map<String, dynamic> condition) async {
    final apiId = 'Browse.ConditionAlbum';
    final data = await api.call(
      _name(apiId),
      'peek_item_count',
      preferredVersion: _version(apiId, const [4, 3, 2, 1]),
      params: {'condition': js(condition)},
    );
    return fInt(data['count']);
  }

  /// 改条件相册的条件（`Browse.ConditionAlbum / set_condition`，**v4**）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function Rt(e)`）：
  /// ```
  /// bS(uF.Z.Foto.Browse.ConditionAlbum.setCondition,(0,tw._)({id:e},r))
  ///   // r = {condition: S(...)}
  /// ```
  Future<void> setConditionAlbumCondition({
    required String albumId,
    required Map<String, dynamic> condition,
  }) async {
    final ids = _intIds([albumId]);
    if (ids.isEmpty) return;
    final apiId = 'Browse.ConditionAlbum';
    await api.call(
      _name(apiId),
      'set_condition',
      preferredVersion: _version(apiId, const [4, 3, 2, 1]),
      params: {'id': '${ids.first}', 'condition': js(condition)},
    );
  }

  /// 新建条件相册（`Browse.ConditionAlbum / create`，**v4**）。
  ///
  /// 参数证据原文（`ui/react_bundle.js`，`function Re()` + 模块 `84966` 的 `I`）：
  /// ```
  /// e=bS(P7)   // P7 = {name, condition: S(...)}
  /// bS(uF.Z.Foto.Browse.ConditionAlbum.create,e)     // → {album}
  /// I = function(name, …) { return {name:name, condition:S(…)}; }
  /// ```
  Future<FotoAlbumDto?> createConditionAlbum({
    required String name,
    required Map<String, dynamic> condition,
  }) async {
    final apiId = 'Browse.ConditionAlbum';
    final data = await api.call(
      _name(apiId),
      'create',
      preferredVersion: _version(apiId, const [4, 3, 2, 1]),
      params: {'name': name, 'condition': js(condition)},
    );
    final album = (data['album'] as Map?)?.cast<String, dynamic>();
    return album == null ? null : FotoAlbumDto.fromJson(album);
  }

  // ================================================================ 相似照片

  /// 相似照片索引状态（`Browse.Similar / get_status`，**v1**）。
  ///
  /// 版本证据：官方版本表
  /// `Browse:{Similar:{get_status:1,ungroup:1,add_item:1,set_top_pick:1,get:1,
  /// remove_item:1}}`（`.lib` `maxVersion=1`）。
  /// 官方调用点（`ui/react_bundle.js`，相似索引轮询 saga）无参数：
  /// `bS(e.GetStatusAPI)`；响应字段 `is_similar_hash_migration_done` /
  /// `stage` / `waiting_count`（同文件读法，见 DTO 注释）。
  Future<FotoSimilarStatusDto> similarStatus() async {
    final apiId = 'Browse.Similar';
    final data = await api.call(
      _name(apiId),
      'get_status',
      preferredVersion: _version(apiId, const [1]),
    );
    return FotoSimilarStatusDto.fromJson(data);
  }

  /// 某个相似分组的照片（`Browse.SimilarItem / list`，**v2**）。
  ///
  /// 版本证据：官方版本表 `SimilarItem:{list:2,list_with_filter:2,list_similar:2,…}`；
  /// 官方把 `SimilarItem.list` 当作相似相册的 `ItemAPI`（`function EU/EY`：
  /// `ItemAPI:uF.Z.Foto.Browse.SimilarItem.list`），走时间轴加载器
  /// `{offset, limit, additional:[…], ...filter}`（同 `Zo`）。
  ///
  /// ⚠️ **没有**任何原文出现过"相似分组 id"这种参数名
  /// （`SYNO.Foto.Browse.so` rodata 里没有 `similar_group_id` /
  /// `similar_id`）→ 本方法只透传 [filter]，**不自造**分组参数；
  /// 分组维度登记为待取证（见实施记录）。
  Future<List<FotoItemDto>> similarGroupItems({
    Map<String, dynamic> filter = const {},
    int offset = 0,
    int limit = 200,
  }) async {
    final apiId = 'Browse.SimilarItem';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [2, 1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(const ['thumbnail', 'favorite']),
        ..._encodeFilter(filter),
      },
    );
    return _list(data, FotoItemDto.fromJson);
  }

  /// 把一张照片**加进某个相似分组**（`Browse.Similar / add_item`，**v1**）。
  ///
  /// **参数证据（官方安卓 APK smali 的 `@Field` 逐字）** ——
  /// `ApiBrowseSimilar$BrowseSimilarRequests.addItem`：
  /// `id`（JVM `J`=long）、`item_id`（String）、`top_pick`（J），版本 `1`。
  /// ⚠️ 官方同一族方法里 `id`/`item_id` 的 JVM 类型**并不一致**
  /// （`set_top_pick` 的 `item_id` 是 long、`ungroup` 的 `id` 是 String）——
  /// 表单编码到线上都是字符串，所以本层统一收 String，**不替服务端做类型判断**。
  Future<void> similarAddItem({
    required String groupId,
    required String itemId,
    int topPick = 0,
  }) async {
    if (groupId.isEmpty || itemId.isEmpty) return;
    final apiId = 'Browse.Similar';
    await api.call(
      _name(apiId),
      'add_item',
      preferredVersion: _version(apiId, const [1]),
      params: {
        'id': groupId,
        'item_id': itemId,
        'top_pick': '$topPick',
      },
    );
  }

  /// 把一张照片**移出相似分组**（`Browse.Similar / remove_item`，**v1**）。
  ///
  /// 字段（同一份 smali）：`id`（J）、`item_id`（String）。
  Future<void> similarRemoveItem({
    required String groupId,
    required String itemId,
  }) async {
    if (groupId.isEmpty || itemId.isEmpty) return;
    final apiId = 'Browse.Similar';
    await api.call(
      _name(apiId),
      'remove_item',
      preferredVersion: _version(apiId, const [1]),
      params: {'id': groupId, 'item_id': itemId},
    );
  }

  /// 设/取消**分组封面（最佳照片）**（`Browse.Similar / set_top_pick`，**v1**）。
  ///
  /// 字段（同一份 smali）：`id`（J）、`item_id`（**J**，官方此方法为 long）。
  Future<void> similarSetTopPick({
    required String groupId,
    required String itemId,
  }) async {
    if (groupId.isEmpty || itemId.isEmpty) return;
    final apiId = 'Browse.Similar';
    await api.call(
      _name(apiId),
      'set_top_pick',
      preferredVersion: _version(apiId, const [1]),
      params: {'id': groupId, 'item_id': itemId},
    );
  }

  /// **拆散一个相似分组**（`Browse.Similar / ungroup`，**v1**）。
  ///
  /// 字段（同一份 smali）：只有 `id`（**String**）。
  Future<void> similarUngroup({required String groupId}) async {
    if (groupId.isEmpty) return;
    final apiId = 'Browse.Similar';
    await api.call(
      _name(apiId),
      'ungroup',
      preferredVersion: _version(apiId, const [1]),
      params: {'id': groupId},
    );
  }

  /// 相似相册时间轴的初始化（`Browse.SimilarTimeline / get_similar`，**v2**）。
  ///
  /// 版本证据：官方版本表 `SimilarTimeline:{get:2,get_with_filter:2,
  /// get_similar:2,get_init_timeline:2}`；官方调用点（`function EJ`）：
  /// `TimelineAPI:uF.Z.Foto.Browse.SimilarTimeline.getSimilar`，
  /// 参数 = `e.filter` 原样（同 `Zi`：`bS(e.TimelineAPI,e.filter)`）。
  Future<Map<String, dynamic>> similarTimeline(
    Map<String, dynamic> filter,
  ) async {
    final apiId = 'Browse.SimilarTimeline';
    return api.call(
      _name(apiId),
      'get_similar',
      preferredVersion: _version(apiId, const [2, 1]),
      params: _encodeFilter(filter),
    );
  }

  // ======================= 管理员（B1：一律 Mock 核实） =======================
  //
  // 权威出处：`SynologyPhotos/usr/webapi/SYNO.Foto.lib`
  //   * `SYNO.Foto.Setting.Admin` v1 → methods `get` / `set`（`authLevel 1`，
  //     挂 `SYNO.Foto.AppInstance` 权限）；
  //   * `SYNO.Foto.Development.Admin` v1 → `refetch_geocoding` /
  //     `regenerate_concept_album` / `update_concept_threshold`，
  //     其中后两者与 `refetch_geocoding` 一样在方法级把 `allowUser`
  //     收窄到 `admin.local/admin.domain/admin.ldap`。
  //
  // `set` / `regenerate_concept_album` / `update_concept_threshold` 的**参数**
  // 在 SPK 与 APK 里都没有逐字证据 ⇒ 只实现有证据的 `get` 与
  // `refetch_geocoding`（无参），**不编参数**。

  /// 管理端设置（`SYNO.Foto.Setting.Admin/get` v1）。
  ///
  /// 直接把服务端返回的字段原样交出去（界面按 key 显示，**不猜字段**）。
  Future<Map<String, dynamic>> adminSettings() async {
    final apiId = 'Setting.Admin';
    final data = await api.call(
      _name(apiId),
      'get',
      preferredVersion: _version(apiId, const [1]),
      params: const {},
    );
    return Map<String, dynamic>.from(data);
  }

  /// 重新做一次地理编码（`SYNO.Foto.Development.Admin/refetch_geocoding` v1，无参）。
  ///
  /// **会动服务端数据** ⇒ 只在管理员页、且用户二次确认后才调用；
  /// 测试一律走 Mock（§5.1 声明）。
  Future<Map<String, dynamic>> adminRefetchGeocoding() async {
    final apiId = 'Development.Admin';
    final data = await api.call(
      _name(apiId),
      'refetch_geocoding',
      preferredVersion: _version(apiId, const [1]),
      params: const {},
    );
    return Map<String, dynamic>.from(data);
  }
}

/// 相似/重复堆叠里的**一组**（官方 `SimilarVo` 逐字取证）。
///
/// ## 证据（APK 2.4.0-644 smali）
///
/// `datasource/network/vo/SimilarVo.smali` 的 `@SerializedName`：
/// `count` / **`id`** / `item_id` / `top_pick`。
///
/// ⚠️ **关键理解（196 轮修正）**：响应里的 `list` 是**扁平的"每张图一行"**
/// —— 每一行的 `id` 是**它所属的分组 id**，`item_id` 才是**这张图自己的 id**；
/// 同一个分组的多张图共享同一个 `id`。APK 正是这么落库的：
/// `SimilarTable{groupId, count, images(ToMany), topPick}` —— `images` 是把
/// 同 `id` 的行聚起来得到的（`SimilarRepository` 用 `SimilarTable` + 关系表）。
/// 所以本仓早先把"一行"当"一张普通照片"来渲染，缩略图对、**分组语义全丢**。
class FotoSimilarGroupDto {
  const FotoSimilarGroupDto({
    required this.id,
    required this.count,
    required this.topPickId,
    required this.items,
  });

  /// 分组 id（官方 `SimilarVo.id`）—— 写操作 `add_item`/`remove_item`/
  /// `set_top_pick`/`ungroup` 要的就是它。
  final String id;

  /// 这一组有几张（官方 `count`；缺失时回落成 [items] 长度）。
  final int count;

  /// 主推那张的 **item id**（官方 `top_pick`）。
  final String topPickId;

  /// 组内各张（每张的 `id` 已换成它自己的 `item_id`，缩略图可用）。
  final List<FotoItemDto> items;

  /// 整组封面：优先主推，其次第一张。
  FotoItemDto? get cover {
    if (items.isEmpty) return null;
    for (final it in items) {
      if (it.id == topPickId) return it;
    }
    return items.first;
  }

  bool get isActionable => id.isNotEmpty && items.isNotEmpty;

  List<String> get itemIds => [for (final it in items) it.id];

  bool get isEmpty => items.isEmpty;
}

/// 把 `Browse.SimilarTimeline` / `Browse.SimilarItem` 的响应解析成分组。
///
/// * 每一行按 [FotoItemDto] 解析，但**行内 `id` 是分组 id** ⇒ 真正的图 id 取
///   `item_id`（有则覆盖，没有才退回 `id`，避免丢掉缩略图）；
/// * 按分组 id 聚合、**保持首次出现顺序**；没有分组 id 的行**不编造分组**
///   （整组丢弃，宁可少显示也不给错的操作目标）。
List<FotoSimilarGroupDto> parseSimilarGroups(Map<String, dynamic> data) {
  final raw = data['list'];
  if (raw is! List) return const [];
  final order = <String>[];
  final members = <String, List<FotoItemDto>>{};
  final counts = <String, int>{};
  final topPicks = <String, String>{};
  for (final e in raw) {
    if (e is! Map) continue;
    final map = e.cast<String, dynamic>();
    final groupId = '${map['id'] ?? ''}';
    if (groupId.isEmpty) continue;
    final itemId = '${map['item_id'] ?? ''}';
    // 官方形状里 `item_id` 是**必给**的（`SimilarVo` 的 `@SerializedName`）。
    // 缺它就说明这份响应不是分组形状 ⇒ **不聚组**（整份回落给调用方去走
    // `SimilarItem/list`），免得把分组 id 当成图 id 发出去。
    if (itemId.isEmpty) continue;
    final item = FotoItemDto.fromJson({...map, 'id': itemId});
    if (item.id.isEmpty) continue;
    if (!members.containsKey(groupId)) {
      order.add(groupId);
      members[groupId] = <FotoItemDto>[];
      counts[groupId] = map['count'] is int
          ? map['count'] as int
          : int.tryParse('${map['count']}') ?? 0;
      topPicks[groupId] = '${map['top_pick'] ?? ''}';
    }
    members[groupId]!.add(item);
  }
  return [
    for (final gid in order)
      FotoSimilarGroupDto(
        id: gid,
        count: counts[gid]! > 0 ? counts[gid]! : members[gid]!.length,
        topPickId: topPicks[gid]!,
        items: members[gid]!,
      ),
  ];

}

/// 搜索结果（`Search.Search/list_item`）每页大小。
///
/// 官方 Web 前端搜索 saga 发的就是 `{offset: itemOffset, limit: itemLimit}`
/// （`function Zo(e,t)`，见 `searchItems` 注释），页大小由前端 store 给出；
/// 这里对齐既有时间线的 100 档，避免一次拉太多缩略图。
const int kFotoSearchPageSize = 100;

/// 条件项类型白名单（官方 `ui/react_bundle.js` 模块 `96904` 的 `CP` 枚举，
/// 取值就是服务端 `.so` rodata 里的那些串）。条件相册的 `condition` 键只能取这些。
const List<String> kFotoConditionTypes = [
  'keyword',
  'person',
  'aperture',
  'camera',
  'concept',
  'exposure_time_group',
  'flash',
  'focal_length_group',
  'general_tag',
  'geocoding',
  'iso',
  'lens',
];

/// 条件相册 `item_type` 的取值（官方模块 `96904` 的 `Ni` + 取值映射函数 `p`）。
///
/// `p(ALL) = []`、`p(PHOTO) = [-1]`、`p(VIDEO) = [-2]`。
const Map<String, List<int>> kFotoConditionItemTypes = {
  'all': [],
  'photo': [-1],
  'video': [-2],
};

/// 条件项候选 `suggest` 的"全部值"关键词（**r402 真机读数**）。
///
/// `ConditionAlbum/suggest` 的 `keyword` 是**必填**，且空串会被判
/// `120 {"name":"keyword","reason":"required"}`；服务端把它当 **LIKE 模式**用
/// （真机：`'%'` → 全部值、`'_'` → 单字符匹配、`'LGE'` → 相机一条）。所以
/// "空搜索框"按服务端自己的通配发 `%`，不新造参数、不猜语义。
const String kFotoConditionSuggestAllKeyword = '%';

/// 条件相册里"带 policy（and/or）"的四个类型 → 对应的 policy 参数名。
///
/// 证据原文（`ui/react_bundle.js` 模块 `84966` 的 `m` 函数）：
/// ```
/// GENERAL_TAG → "general_tag_policy"; FILENAME_DESCRIPTION → "keyword_policy";
/// PERSON → "person_policy";           CONCEPT → "concept_policy"
/// ```
const Map<String, String> kFotoConditionPolicyKeys = {
  'general_tag': 'general_tag_policy',
  'keyword': 'keyword_policy',
  'person': 'person_policy',
  'concept': 'concept_policy',
};

/// 相似时间轴的 API 名（`SYNO.Foto.Browse.SimilarTimeline`）。
///
/// 官方 Web 把相似相册的时间轴钉在 `Browse.SimilarTimeline.get_similar`
/// （`ui/react_bundle.js` 的 `EJ`：`TimelineAPI: …SimilarTimeline.getSimilar`，
/// 紧随其后的是 `ItemAPI: …SimilarItem.listSimilar`、`BasicInfoAPI:
/// …SimilarItem.listSimilarBasicTimelineInfo`）。**官方 Android 2.4.0-644 的
/// jadx 输出里没有 `ApiBrowseSimilarTimeline` 这个类** → 安卓端不调它。
///
/// ⚠️ 为此：客户端只在 `SYNO.API.Info` 里确实有这个 API 时才发
/// `SimilarTimeline/get_similar`（否则必然吃 `103`），拿不到结构化 `list`
/// 就回落到官方另一个 API `SimilarItem/list`。
const String kFotoSimilarTimelineApi = 'SYNO.Foto.Browse.SimilarTimeline';

/// C2 新增文案的 key（真正的中文原文在 `features/photos/photo_c2_text.dart`）。
///
/// 放在数据层只为让"哪些 key 要补 ARB"有一个**单点清单**（`foto_api.dart`
/// 的 `FotoSpace.labelKey` 同一套约定）；数据层不碰 `AppText`。
abstract final class FotoC2TextKeys {
  static const sharing = 'fotoC2Sharing';
  static const photoRequest = 'fotoC2PhotoRequest';
  static const geocoding = 'fotoC2Geocoding';
  static const search = 'fotoC2Search';
  static const conditionAlbum = 'fotoC2ConditionAlbum';
  static const similar = 'fotoC2Similar';
  static const noPermission = 'fotoC2NoPermission';
  static const notAvailable = 'fotoC2NotAvailable';
  static const deleteConfirm = 'fotoC2DeleteConfirm';
}

/// 数据层里唯一用得上的一条本地化：无权限提示的**兜底**文案
/// （界面一律走 `photo_c2_text.dart` / `context.t`）。
String fotoC2NoPermissionText() =>
    dataText(FotoC2TextKeys.noPermission, '没有权限');
