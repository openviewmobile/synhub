// C2（Photos 补齐）新增 DTO。
//
// 事实来源（逐条对照，不许猜）：
//   1. 服务端能力表 `SYNO.Foto.lib` / `SYNO.FotoTeam.lib`
//      （`/tmp/spk/export_SynologyPhotos/usr/webapi/`，SynologyPhotos 1.9.1-10928）
//   2. 官方 Web 前端（同一包的 `ui/react_bundle.js`、`ui/photo_request_bundle.js`）
//      —— 官方客户端**实际发出去的参数**（见 `foto_c2_api.dart` 每条的注释）
//   3. 服务端 `.so` 的 rodata 参数名白名单（`strings` 抽出的 `"..."` 数组）
//
// 解析一律**宽松**：服务端字段可能 int/string 混用（沿用 `foto_dto.dart` 的
// `fText`/`fInt`/`fBool`）。响应结构没核实的地方**不硬编**——宁可给个 `usable`
// 标志让调用方回落，也不写一个看起来合理的假结构（同 `FotoBackupCheckResult`）。
library;

import 'foto_dto.dart';

/// 共享成员 / 成员的权限（`Sharing.Passphrase` 的 `permission` 数组元素）。
///
/// 证据原文（`ui/react_bundle.js`，模块 19051 的 `u`/`l` 两个 diff 函数）：
/// ```
/// n.push({role:m, action:"update", member:{type:p.get("type"), id:p.get("id")}})
/// n.push({action:"delete", member:{type:p.get("type"), id:p.get("id")}})
/// l => {action:"delete", member:{type:"public"}}
///   | {action:"update", role:"view",     member:{type:"public"}}
///   | {action:"update", role:"download", member:{type:"public"}}
/// ```
/// 角色枚举（同文件，模块 96904 导出 `F`/`_I`）：
/// `{VIEW:"view", DOWNLOAD:"download", UPLOAD:"upload", OWNER:"owner"}`（普通相册，
/// 服务端排序 0/1/2）与 `{view:0, download:1, upload:2, manage:3}`（共享空间文件夹）。
class FotoShareMemberDto {
  const FotoShareMemberDto({
    required this.type,
    required this.id,
    this.name = '',
    this.role = 'view',
  });

  /// `user` / `group` / `public`（官方 `member.type`）
  final String type;

  /// 用户 id / 组 id；`public` 成员没有 id
  final String id;
  final String name;

  /// `view` / `download` / `upload` / `manage` / `owner`
  final String role;

  bool get isPublic => type == 'public';

  static FotoShareMemberDto fromJson(Map<String, dynamic> j) {
    final member = (j['member'] as Map?)?.cast<String, dynamic>() ?? {};
    return FotoShareMemberDto(
      type: fText(member['type']),
      id: fText(member['id']),
      name: fText(j['name']).isEmpty ? fText(member['name']) : fText(j['name']),
      role: fText(j['role']).isEmpty ? fText(member['role']) : fText(j['role']),
    );
  }
}

/// 相册共享信息（`Browse.Album/get` + `additional=["sharing_info"]`）。
///
/// 证据原文（`ui/react_bundle.js`，`function NS(e)`）：
/// ```
/// bS(uF.Z.Foto.Browse.Album.get,{id:[e],additional:["sharing_info"]})
/// o=(r=(n=t.list[0]).additional.sharing_info).privacy_type
/// i=r.sharing_link; a=r.passphrase
/// Nc({passphrase:a,privacyType:o,shareLink:i,id:n.id,name:n.name,
///     shareEnabled:n.shared, sharingUserGroup:r.permission,
///     enablePassword:r.enable_password, expiration:r.expiration,
///     temporaryShared:n.temporary_shared})
/// ```
/// 所以：`sharing_info.permission` 就是**成员/权限数组**（邀请成员、改角色就改它），
/// `sharing_info.sharing_link` / `passphrase` 是外链，`privacy_type` 是
/// `management` / `private` / `public-view` / `public-download` / `public-upload`。
class FotoAlbumSharingDto {
  const FotoAlbumSharingDto({
    this.privacyType = 'private',
    this.sharingLink = '',
    this.passphrase = '',
    this.enabled = false,
    this.enablePassword = false,
    this.expiration = 0,
    this.temporaryShared = false,
    this.members = const [],
    this.ownerName = '',
  });

  /// `management` / `private` / `public-view` / `public-download` / `public-upload`
  final String privacyType;
  final String sharingLink;
  final String passphrase;

  /// 相册的 `shared` 字段（是否已共享）
  final bool enabled;
  final bool enablePassword;

  /// 链接有效期（秒；`0` = 不过期。官方 `enableExpiration = 0 !== expiration`）
  final int expiration;
  final bool temporaryShared;
  final List<FotoShareMemberDto> members;
  final String ownerName;

  /// 只保留非 `public` 的成员（界面「成员」列表用）
  List<FotoShareMemberDto> get userMembers => [
    for (final m in members)
      if (!m.isPublic) m,
  ];

  /// `public` 那个成员（外链权限），没有则 null
  FotoShareMemberDto? get publicMember {
    for (final m in members) {
      if (m.isPublic) return m;
    }
    return null;
  }

  bool get hasLink => sharingLink.isNotEmpty;

  static FotoAlbumSharingDto fromAlbumJson(Map<String, dynamic> album) {
    final additional =
        (album['additional'] as Map?)?.cast<String, dynamic>() ?? {};
    final info = (additional['sharing_info'] as Map?)?.cast<String, dynamic>();
    final owner = (info?['owner'] as Map?)?.cast<String, dynamic>();
    return FotoAlbumSharingDto(
      privacyType: fText(info?['privacy_type']).isEmpty
          ? 'private'
          : fText(info?['privacy_type']),
      sharingLink: fText(info?['sharing_link']),
      passphrase: fText(info?['passphrase']),
      enabled: fBool(album['shared']),
      enablePassword: fBool(info?['enable_password']),
      expiration: fInt(info?['expiration']),
      temporaryShared: fBool(album['temporary_shared']),
      members: _members(info?['permission']),
      ownerName: fText(owner?['name']),
    );
  }

  static List<FotoShareMemberDto> _members(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) FotoShareMemberDto.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

/// 可共享的用户 / 群组（`Sharing.Misc/list_user_group` 的元素）。
///
/// 证据原文（`ui/react_bundle.js`，`function NI(e)`）：
/// ```
/// bS(uF.Z.Foto.Sharing.Misc.listUserGroup,{team_space_sharable_list:e})
/// ... t.list ... r.findIndex(function(e){return e.id===n})  // 过滤掉自己
/// ```
/// 服务端 `.so`（`SYNO.Foto.Sharing.so` rodata）只有 `list_user_group` 与
/// `team_space_sharable_list` 两个串，**没有** `type`/`name` 的入参证据；
/// 响应里的 `type`（`user`/`group`）由官方按 `member.type` 写回，故这里**宽松**取。
class FotoSharableMemberDto {
  const FotoSharableMemberDto({
    required this.id,
    this.name = '',
    this.type = 'user',
  });

  final String id;
  final String name;

  /// `user` / `group`（认不出就按 `user`）
  final String type;

  static FotoSharableMemberDto fromJson(Map<String, dynamic> j) {
    final rawType = fText(j['type']).isEmpty
        ? fText(j['member_type'])
        : fText(j['type']);
    return FotoSharableMemberDto(
      id: fText(j['id']),
      name: fText(j['name']).isEmpty ? fText(j['nickname']) : fText(j['name']),
      type: rawType.isEmpty ? 'user' : rawType,
    );
  }
}

/// 「照片请求」（Photo Request，官方 Photos 里给外部访客开的收图链接）。
///
/// 证据原文（`ui/react_bundle.js`）：
/// ```
/// // 列表
/// t={offset:0,limit:5e3}; e.keyword&&(t.keyword=e.keyword)
/// bS(uF.Z.Foto.PhotoRequest.list,t)               // → .list
/// // 删除（注意 passphrase 是**数组**）
/// n={passphrase:[t=e.passphrase]}
/// bS(uF.Z.Foto.PhotoRequest.delete,n)
/// ```
class FotoPhotoRequestDto {
  const FotoPhotoRequestDto({
    required this.passphrase,
    this.name = '',
    this.sharingLink = '',
    this.expiration = 0,
    this.itemCount = 0,
  });

  final String passphrase;
  final String name;
  final String sharingLink;
  final int expiration;
  final int itemCount;

  static FotoPhotoRequestDto fromJson(Map<String, dynamic> j) =>
      FotoPhotoRequestDto(
        passphrase: fText(j['passphrase']),
        name: fText(j['name']),
        sharingLink: fText(j['sharing_link']),
        expiration: fInt(j['expiration']),
        itemCount: fInt(j['item_count']),
      );
}

/// 一个「地点」（`Browse.Geocoding/list` 的元素）。
///
/// 证据原文（`ui/react_bundle.js`，reducer 解析 geocoding 相册项）：
/// ```
/// u.country=i.country; u.country_id=i.country_id; u.first_level=i.first_level
/// ```
/// 列表请求形态（`ui/react_bundle.js` 的自动相册加载器 `Cd`）：
/// `bS(r.list, {...{additional:["thumbnail"]}, ...filter})`，其中
/// `r = getSmartAPI(ALBUM_TYPE.GEOCODING) = Foto.Browse.Geocoding`。
class FotoGeocodingPlaceDto {
  const FotoGeocodingPlaceDto({
    required this.id,
    this.name = '',
    this.country = '',
    this.countryId = '',
    this.firstLevel = '',
    this.itemCount = 0,
    this.cover,
  });

  final String id;
  final String name;
  final String country;
  final String countryId;
  final String firstLevel;
  final int itemCount;
  final FotoThumbDto? cover;

  /// 界面显示名：`country` 为空时用 `first_level`（官方分组逻辑同款回落）
  String get displayName {
    if (name.isNotEmpty) return name;
    if (country.isNotEmpty) return country;
    return firstLevel;
  }

  static FotoGeocodingPlaceDto fromJson(Map<String, dynamic> j) {
    final additional = (j['additional'] as Map?)?.cast<String, dynamic>() ?? {};
    final cover = additional['thumbnail'];
    final country = fText(j['country']);
    final firstLevel = fText(j['first_level']);
    return FotoGeocodingPlaceDto(
      id: fText(j['id']),
      name: fText(j['name']).isEmpty
          ? (country.isNotEmpty ? country : firstLevel)
          : fText(j['name']),
      country: country,
      countryId: fText(j['country_id']),
      firstLevel: firstLevel,
      itemCount: fInt(j['item_count']),
      cover: cover is Map
          ? FotoThumbDto.fromJson(cover.cast<String, dynamic>())
          : null,
    );
  }
}

/// 条件相册（`Browse.ConditionAlbum/list|get` 的元素）。
///
/// 证据原文（`ui/react_bundle.js`）：
/// ```
/// // get：id 是**数组**
/// r={additional:["condition_object"]}; t?r.id=[t]:n&&(r.passphrase=n)
/// bS(uF.Z.Foto.Browse.ConditionAlbum.get,r)                // → {list:[{id, additional:{condition_object}}]}
/// // 改条件：{id, condition}
/// bS(uF.Z.Foto.Browse.ConditionAlbum.setCondition,{id:o.list[0].id,condition:i})
/// // 建：{name, condition}
/// bS(uF.Z.Foto.Browse.ConditionAlbum.create,e)             // → {album}
/// ```
class FotoConditionAlbumDto {
  const FotoConditionAlbumDto({
    required this.id,
    this.name = '',
    this.condition = const {},
    this.isValid = true,
    this.itemCount = 0,
    this.cover,
  });

  final String id;
  final String name;

  /// `additional.condition_object`（原样保留；字段名来自 `SYNO.Foto.Browse.so`
  /// 的 `condition_object` 串与官方 `It.ot` 解码器）
  final Map<String, dynamic> condition;
  final bool isValid;
  final int itemCount;
  final FotoThumbDto? cover;

  bool get hasCondition => condition.isNotEmpty;

  static FotoConditionAlbumDto fromJson(Map<String, dynamic> j) {
    final additional = (j['additional'] as Map?)?.cast<String, dynamic>() ?? {};
    final cover = additional['thumbnail'];
    final rawCondition = additional['condition_object'] ?? j['condition'];
    final condition = rawCondition is Map
        ? rawCondition.cast<String, dynamic>()
        : <String, dynamic>{};
    return FotoConditionAlbumDto(
      id: fText(j['id']),
      name: fText(j['name']),
      condition: condition,
      isValid: j.containsKey('is_valid') ? fBool(j['is_valid']) : true,
      itemCount: fInt(j['item_count']),
      cover: cover is Map
          ? FotoThumbDto.fromJson(cover.cast<String, dynamic>())
          : null,
    );
  }
}

/// 相似照片索引状态（`Browse.Similar/get_status`）。
///
/// 证据原文（`ui/react_bundle.js`，相似索引轮询组件的 `s()` saga）：
/// ```
/// var e=r.get("waiting_count"), t=r.get("stage"), n=r.get("is_similar_hash_migration_done");
/// if(0===e&&n) return null;                       // 索引就绪
/// if(e>0&&"running"===t)...                        // 正在索引
/// ```
/// 门控位 = `Setting.User/get` 的 `enable_similar`（同文件：
/// `E=function(e){return ...get("enable_similar")}`）。
class FotoSimilarStatusDto {
  const FotoSimilarStatusDto({
    this.migrationDone = false,
    this.stage = '',
    this.waitingCount = 0,
  });

  final bool migrationDone;
  final String stage;
  final int waitingCount;

  /// 索引跑完 → 可以看相似分组
  bool get ready => migrationDone && waitingCount == 0;

  bool get running => stage == 'running' && waitingCount > 0;

  static FotoSimilarStatusDto fromJson(Map<String, dynamic> j) =>
      FotoSimilarStatusDto(
        migrationDone: fBool(j['is_similar_hash_migration_done']),
        stage: fText(j['stage']),
        waitingCount: fInt(j['waiting_count']),
      );
}

// ================================================================ 搜索筛选面板

/// 搜索筛选面板的一个**可选项**（`Search.Filter/list` 一组里的元素）。
///
/// 服务端字段名没有逐字取证（真机只验了"回真实分组"），所以这里**不用固定键**
/// 去解释业务语义，只做"能显示 / 能回填"的两件事：
///   * [label] = 可显示文案（`name` / `label` / `value` 依次取，**取不到就丢弃
///     这一项**——绝不把内部 id 当文案显示给用户）；
///   * [value] = 回填给 `Search.Search/list_item` 的值。标量选项就是原值，
///     `focal_length_group` / `exposure_time_group` 这类区间组是**对象**
///     （官方 reducer：`i = b.a.includes(o) ? fromJS(e) : e.id`）。
class FotoSearchFilterOptionDto {
  const FotoSearchFilterOptionDto({required this.label, required this.value});

  final String label;

  /// 标量（`String`/`num`/`bool`）或区间对象（`Map`）
  final Object value;

  static FotoSearchFilterOptionDto? fromJson(Object? raw, {Object? id}) {
    if (raw is! Map) return null;
    final label = [
      fText(raw['name']),
      fText(raw['label']),
      fText(raw['title']),
      fText(raw['value']),
    ].firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
    if (label.trim().isEmpty) return null;
    // 区间组（值是对象）→ 回填对象本身；否则回填 id（没有 id 才退回原始值）
    final isComplex = raw['start'] != null || raw['end'] != null;
    final value = isComplex ? raw : (id ?? raw['id'] ?? raw['value']);
    if (value == null) return null;
    return FotoSearchFilterOptionDto(label: label, value: value);
  }
}

/// 搜索筛选面板的一个**分组**（`Search.Filter/list` v4 的一个顶层键）。
///
/// 回包形状证据（官方 Web 前端 `ui/react_bundle.js`，筛选 reducer）：
/// 顶层是一个 **组名 → 选项数组** 的 Map，reducer 逐组 `e[o].forEach(...)`
/// 且对每组判断 `b.a.includes(o)`（区间组的值整体回填）——与
/// `docs/photo-api-live.md` §2「回真实分组 `aperture`/`camera`/`exposure_time_group`」
/// 一致。**没有** `{list:[…]}` 这层包装（真机实探也没有）。
///
/// 解析**宽松**：认顶层 Map 形态；认不出可显示项的分组直接丢掉（不猜、不显示 id）。
class FotoSearchFilterGroupDto {
  const FotoSearchFilterGroupDto({required this.key, required this.options});

  /// 组名（服务端键，逐字；如 `aperture` / `camera` / `exposure_time_group`）
  final String key;

  final List<FotoSearchFilterOptionDto> options;

  /// 解析 `Search.Filter/list` 的回包；空 Map / 认不出来 → 空列表
  /// （调用方据此显示"筛选项不可用"，**不当成空结果**）。
  static List<FotoSearchFilterGroupDto> parse(Object? data) {
    if (data is! Map) return const [];
    final groups = <FotoSearchFilterGroupDto>[];
    data.forEach((k, v) {
      if (v is! List) return;
      final key = '$k';
      if (key == 'list') return; // 兼容层：`{list:[…]}` 里才是分组对象
      final options = <FotoSearchFilterOptionDto>[];
      for (final e in v) {
        final opt = FotoSearchFilterOptionDto.fromJson(e);
        if (opt != null) options.add(opt);
      }
      if (options.isNotEmpty) {
        groups.add(FotoSearchFilterGroupDto(key: key, options: options));
      }
    });
    // 兼容层：`{list:[{key/type, values/items/options:[…]}]}`
    final nested = data['list'];
    if (groups.isEmpty && nested is List) {
      for (final g in nested) {
        if (g is! Map) continue;
        final key = fText(g['key']).isNotEmpty
            ? fText(g['key'])
            : fText(g['type']);
        final rawOptions =
            g['values'] ?? g['items'] ?? g['options'] ?? g['list'];
        if (key.isEmpty || rawOptions is! List) continue;
        final options = <FotoSearchFilterOptionDto>[];
        for (final e in rawOptions) {
          final opt = FotoSearchFilterOptionDto.fromJson(e);
          if (opt != null) options.add(opt);
        }
        if (options.isNotEmpty) {
          groups.add(FotoSearchFilterGroupDto(key: key, options: options));
        }
      }
    }
    return groups;
  }
}
