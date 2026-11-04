// `SYNO.SynologyDrive.Info:quota`（**v2**）的 VO —— Drive 存储空间 / 配额。
//
// 权威事实（NAS 上装的 **SynologyDrive 4.2.0-30058** SPK 内的官方 Web 前端）：
//   * 描述符逐字：`get_quota:{api:"SYNO.SynologyDrive.Info",version:2,method:"quota"}`
//     （`/tmp/spk/export_SynologyDrive/drive/synodrive_common.js`，
//     sha256 `9b5bd0ce…`）。**必须 v2**：`Info` v1 只有 `get/noop`
//     （`docs/api-server-authoritative.md:768`），真机 v1 回 `103`。
//   * 无参调用；回包 `data.share_list[]`，条目字段：
//     `is_home` / `name` / `quota` / `share_quota` / `share_used` /
//     `support_per_share_quota` / `used`。
//   * 真机回包（`docs/api-method-level-gaps.md:123`）：
//     `{"data":{"share_list":[{"is_home":true,"name":"homes","quota":0,
//       "share_quota":0,"share_used":4871229.5,"support_per_share_quota":true,
//       "used":17307.96484375}]}}`。
//
// 两个**最容易做错**的点：
//   1. **单位是 MiB，不是字节**。官方渲染一律
//      `Ext.util.Format.fileSize(1024 * t * 1024)`（`synodrive_common.js` 的
//      `Info.showProgressBar`，`t = used`、上限 = `quota`）。⇒ DTO 里同时给出
//      MiB 原始值与换算后的字节数，UI 只许用后者格式化。
//   2. **`quota <= 0` = 不限额**（不是"0 字节容量"）。官方
//      `if(!(0 < e)) { used(...) }` —— 只显示已用量、**不显示总容量**；官方串表
//      `[quota] description` 逐字："仅当已为用户设置了配额上限时，才会显示总容量"
//      （`ui/texts/chs/strings:1600`，`used` = `"已使用 {0}"` `:1609`）。
//      ⇒ 绝不可把 `quota:0` 渲染成 "0 B / 0 B"。
//
// ⚠️ 不显示任何内部 id：本 DTO 只承载份额名 / 用量 / 上限；`share_list` 里
// 本来也没有 `file_id`。

/// 一个配额份额（个人空间 `is_home:true`，或一个团队/共享文件夹）。
class DriveQuotaShareDto {
  const DriveQuotaShareDto({
    required this.name,
    required this.isHome,
    required this.quotaMib,
    required this.usedMib,
    required this.shareQuotaMib,
    required this.shareUsedMib,
    required this.supportPerShareQuota,
  });

  /// 份额名（官方原样返回；个人空间真机回 `homes`，UI 不直接展示这个名字）
  final String name;

  /// `true` = 个人空间（官方 `is_home`；`quota`/`used` 就是它）
  final bool isHome;

  /// 配额上限（**MiB**；`<= 0` = 不限额）
  final double quotaMib;

  /// 已用（**MiB**）
  final double usedMib;

  /// 该份额所在存储空间的配额（**MiB**；`<= 0` = 未设）
  final double shareQuotaMib;

  /// 该份额所在存储空间的已用（**MiB**）
  final double shareUsedMib;

  /// 服务端是否支持"每个共享文件夹单独配额"
  final bool supportPerShareQuota;

  static const double bytesPerMib = 1024 * 1024;

  /// 是否设置了配额上限。**`false` 表示不限额**，不是"容量为 0"。
  bool get hasQuota => quotaMib > 0;

  /// 所在存储空间是否设了配额上限。
  bool get hasShareQuota => shareQuotaMib > 0;

  int get usedBytes => _toBytes(usedMib);
  int get quotaBytes => _toBytes(quotaMib);
  int get shareUsedBytes => _toBytes(shareUsedMib);
  int get shareQuotaBytes => _toBytes(shareQuotaMib);

  /// 已用比例（0–1）。不限额时返回 0（官方对不限额不画进度条）。
  double get ratio =>
      hasQuota ? (usedMib / quotaMib).clamp(0.0, 1.0).toDouble() : 0.0;

  /// 已满（官方 `99 < percent && 2 > quotaGB - usedGB`）。
  bool get nearlyFull {
    if (!hasQuota) return false;
    final percent = 100 * usedMib / quotaMib;
    final quotaGib = quotaMib / 1024;
    final usedGib = usedMib / 1024;
    return percent > 99 && (quotaGib - usedGib) < 2;
  }

  /// 字节数上界：取 **2^53-1**（JS 的 `int` 精确上限）而不是 `0x7FFF…`（64 位）。
  /// 语义无差：这是防溢出的兜底，9 PB 之上没有任何 NAS 配额（第 335 轮修 web 编译）。
  static const int _kMaxBytes = 9007199254740991;

  static int _toBytes(double mib) =>
      (mib * bytesPerMib).round().clamp(0, _kMaxBytes);

  static double _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  static DriveQuotaShareDto fromJson(Map<String, dynamic> json) =>
      DriveQuotaShareDto(
        name: '${json['name'] ?? ''}',
        isHome: json['is_home'] == true,
        quotaMib: _num(json['quota']),
        usedMib: _num(json['used']),
        shareQuotaMib: _num(json['share_quota']),
        shareUsedMib: _num(json['share_used']),
        supportPerShareQuota: json['support_per_share_quota'] == true,
      );

  @override
  String toString() =>
      'DriveQuotaShareDto(name: $name, isHome: $isHome, '
      'usedMib: $usedMib, quotaMib: $quotaMib)';
}

/// `Info:quota` 的整个回包
class DriveQuotaDto {
  const DriveQuotaDto({required this.shares});

  final List<DriveQuotaShareDto> shares;

  /// 个人空间那条（官方 `is_home`）；服务端没给就 `null`。
  DriveQuotaShareDto? get home {
    for (final s in shares) {
      if (s.isHome) return s;
    }
    return null;
  }

  /// **主目录**：优先个人空间，其次第一条（官方左栏"我的文件"就是 home）。
  DriveQuotaShareDto? get primary =>
      home ?? (shares.isEmpty ? null : shares.first);

  /// 有配额的份额（官方列表只列 `support_per_share_quota == true` 的；
  /// 这里保留全部，UI 自行决定展示哪些）。
  List<DriveQuotaShareDto> get quotaShares =>
      shares.where((s) => s.hasQuota).toList(growable: false);

  static DriveQuotaDto fromJson(Map<String, dynamic> data) {
    final raw = data['share_list'];
    final list = <DriveQuotaShareDto>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          list.add(DriveQuotaShareDto.fromJson(e.cast<String, dynamic>()));
        }
      }
    }
    return DriveQuotaDto(shares: List.unmodifiable(list));
  }

  /// 官方对不限额的份额不画进度条：这里给 UI 一个"是否有任何上限"的汇总。
  bool get hasAnyQuota => shares.any((s) => s.hasQuota);
}
