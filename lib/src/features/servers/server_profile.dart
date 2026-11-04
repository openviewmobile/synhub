/// 服务器地址的两种录入方式。
enum ServerAddressKind {
  /// 用户输入 QuickConnect ID（如 `demo_admin-qq`），走发现链路
  quickConnect,

  /// 用户直接给主机或 URL（局域网 IP、DDNS 域名等）
  direct,
}

/// 用户在「添加服务器」页填的东西。
class ServerProfile {
  const ServerProfile({
    required this.kind,
    required this.value,
    this.displayName,
  });

  final ServerAddressKind kind;

  /// QuickConnect ID，或直接地址（允许 `host`、`host:port`、`https://…`）
  final String value;

  /// 展示名；未填时由 [value] 推导
  final String? displayName;

  String get label => displayName ?? value;

  /// 归一化后的 http(s) 基地址；仅 [ServerAddressKind.direct] 有意义。
  ///
  /// - 无协议 → 补 `https://`
  /// - 无端口 → 由调用方决定（QuickConnect 用 `service.port`，直连用 5001/5000）
  String get normalizedBaseUrl {
    var v = value.trim();
    if (v.startsWith('http://') || v.startsWith('https://')) return v;
    return 'https://$v';
  }

  @override
  String toString() => 'ServerProfile(${kind.name}, $value)';
}

/// 发现链路解析出的一个可尝试的地址。
class ResolvedEndpoint {
  const ResolvedEndpoint({
    required this.baseUrl,
    required this.source,
    this.reachable,
  });

  final String baseUrl;

  /// 来源标记：`lan` | `ddns` | `external` | `smartdns` | `direct`
  final String source;

  /// 探测结果；`null` 表示还没探过
  final bool? reachable;

  ResolvedEndpoint withReachable(bool ok) =>
      ResolvedEndpoint(baseUrl: baseUrl, source: source, reachable: ok);

  @override
  String toString() =>
      '$baseUrl ($source)${reachable == null
          ? ''
          : reachable!
          ? ' ✓'
          : ' ✗'}';
}
