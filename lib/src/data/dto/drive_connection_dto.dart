// `SYNO.SynologyDrive.Connection:list`（**v2**，v1 亦可用）的 VO ——
// 「已连接的客户端 / 设备」。
//
// 本文件只承载**服务端真正会回的字段**，不做加法。
//
// ## 权威事实（三处，逐条可查）
//
// 1. **方法表**：`/tmp/spk/export_SynologyDrive/webapi/drive/SYNO.SynologyDrive.lib`
//    逐字 `"SYNO.SynologyDrive.Connection"` → `minVersion: 1, maxVersion: 2`，
//    `methods: {1:[list, delete], 2:[list, delete, summary]}`，
//    `allowUser` 含 `normal.local/local/domain/ldap`（**普通用户可调**，
//    不是管理员专属；这与真机普通账号 `success` 一致）。
//    `openapi_v2.json` 的 `/admin/client` 也标 `x-syno-version: 2` /
//    `x-syno-method: list`。
//
// 2. **回包字段白名单**（`lib/SYNO.SynologyDrive.so` 内的字符串常量，
//    紧邻 `ConnectionListHandler`）：
//    ```
//    ["client_id", "client_name", "login_time", "client_status",
//     "client_type", "client_ip", "client_location", "client_version",
//     "last_auth_time"]
//    ```
//    ⇒ 这九项就是 `list` 条目的**全部**字段，DTO 只解析这九项。
//
// 3. **真机只读实测**（普通账号，DSM 7.2，`docs/g6-api-probe-facts.md:37`）：
//    `Connection:list` v1 与 v2 都 `success`，回 `{"items": [], "total": 0}`
//    ⇒ **无必填参数**；本账号没有任何已连接设备（**空态是这台 NAS 上的真实表现**）。
//
// ## 两条纪律
//
// * **`client_id` 绝不上屏**（内部 id，只允许出现在 Key / 断言里）；
// * **`client_status` 是枚举串**：只有 `connected` 在 `.so` 里有字面证据，
//   其余取值一律**不把原文透给用户**（[statusLabelKey] 返回 null 让 UI 直接不画）。

/// 一个已连接的 Drive 客户端 / 设备。
class DriveConnectionDto {
  const DriveConnectionDto({
    required this.clientId,
    required this.clientName,
    required this.loginTime,
    required this.clientStatus,
    required this.clientType,
    required this.clientIp,
    required this.clientLocation,
    required this.clientVersion,
    required this.lastAuthTime,
  });

  /// 内部 id（**不上屏**；只用 Key）
  final String clientId;

  /// 客户端名（官方 `client_name`，如设备主机名）
  final String clientName;

  /// 登录时间（**epoch 秒**；0 = 服务端没给）
  final int loginTime;

  /// 连接状态（**枚举串**；见文件头说明）
  final String clientStatus;

  /// 客户端类型（官方 `client_type`，如 `desktop` / `mobile`）
  final String clientType;

  /// 客户端 IP
  final String clientIp;

  /// 客户端位置（官方 `client_location`，通常由 IP 归属地得出）
  final String clientLocation;

  /// 客户端版本号
  final String clientVersion;

  /// 最近一次鉴权时间（**epoch 秒**；0 = 服务端没给）
  final int lastAuthTime;

  /// UI 用的显示名：**永不为空**，且**绝不回落到 `client_id`**。
  ///
  /// 兜底是一句人话（"未知设备"的 key 由 UI 提供），不是内部 id。
  String displayName(String fallback) =>
      clientName.trim().isNotEmpty ? clientName.trim() : fallback;

  /// 状态文案 key（**null = 不认识 → UI 不画这一行**，绝不透原文）。
  ///
  /// * `connected` —— `.so` 字符串常量里有这个字面值，唯一的**有证据**取值；
  /// * `offline` / `disconnected` —— 防御性映射（未取得取证）；
  /// * 其它（含空串）—— null。
  String? statusLabelKey() => switch (clientStatus.trim().toLowerCase()) {
    'connected' => 'driveG6ConnectionStatusConnected',
    'offline' || 'disconnected' => 'driveG6ConnectionStatusOffline',
    _ => null,
  };

  static String _str(Object? v) => v == null ? '' : '$v';

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static DriveConnectionDto fromJson(Map<String, dynamic> json) =>
      DriveConnectionDto(
        clientId: _str(json['client_id']),
        clientName: _str(json['client_name']),
        loginTime: _int(json['login_time']),
        clientStatus: _str(json['client_status']),
        clientType: _str(json['client_type']),
        clientIp: _str(json['client_ip']),
        clientLocation: _str(json['client_location']),
        clientVersion: _str(json['client_version']),
        lastAuthTime: _int(json['last_auth_time']),
      );

  @override
  String toString() =>
      'DriveConnectionDto(${clientName.isEmpty ? '(unnamed)' : clientName}, '
      'type: $clientType, status: $clientStatus)';
}

/// `Connection:list` 的整个回包（`{items, total}`；与 FileStation 的
/// `files` / Drive `Files:list` 的 `items` 同一口径）。
class DriveConnectionListDto {
  const DriveConnectionListDto({required this.items, required this.total});

  final List<DriveConnectionDto> items;

  /// 服务端给的条数（**可能与 `items.length` 不等**：分页时 `total` 是总数）
  final int total;

  static DriveConnectionListDto fromJson(Map<String, dynamic> data) {
    final raw = data['items'];
    final list = <DriveConnectionDto>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          list.add(DriveConnectionDto.fromJson(e.cast<String, dynamic>()));
        }
      }
    }
    final total = data['total'];
    final t = total is num
        ? total.toInt()
        : (total is String ? int.tryParse(total) : null);
    return DriveConnectionListDto(
      items: List.unmodifiable(list),
      total: t ?? list.length,
    );
  }

  bool get isEmpty => items.isEmpty;
}
