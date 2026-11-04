import '../features/servers/server_profile.dart';
import 'serv_api.dart';

/// 把 QuickConnect 的 `get_server_info` 结果翻译成**按优先级排序**的可达地址。
///
/// 优先级对齐原 App（`RelayManager.resolveInSequence`）：
///
/// ```
/// LAN（smartdns.lan / interface.ip） → WAN_DDNS(ddns) → WAN_IP(external)
///   → smartdns.host → （打洞隧道，见 docs/holepunch-findings.md）
/// ```
///
/// 官方 App 在本机网络下的实际选择印证了这一点：它先解析 `direct.quickconnect.cn`
/// 失败，随后用 `192-168-0-181.….direct.quickconnect.cn:5001`（LAN）连上。
extension DsmInfoAddressSelection on DsmInfo {
  /// 服务端口。原库优先 `service.port`，缺失时退回 `ext_port`。
  int get effectiveServicePort =>
      servicePort > 0 ? servicePort : serviceExtPort;

  /// 生成候选地址，已去重、已排序。
  ///
  /// [scheme] 默认 `https`；[port] 为 0 时用 [effectiveServicePort]。
  List<ResolvedEndpoint> httpCandidates({String scheme = 'https', int? port}) {
    final p = port ?? effectiveServicePort;
    if (p <= 0) return const [];

    final out = <ResolvedEndpoint>[];
    void add(String? host, String source) {
      if (host == null || host.isEmpty || host == 'NULL') return;
      final url = '$scheme://$host:$p';
      if (out.any((e) => e.baseUrl == url)) return;
      out.add(ResolvedEndpoint(baseUrl: url, source: source));
    }

    // ① 局域网：SmartDNS 的 lan 列表最权威（原 App 就是走这条）
    for (final h in smartdns?.lans ?? const <String>[]) {
      add(h, 'lan');
    }
    for (final ip in server?.interfaceIps ?? const <String>[]) {
      add(ip, 'lan');
    }

    // ② 广域网
    add(server?.ddns, 'ddns');
    add(server?.external, 'external');
    add(server?.fqdn, 'fqdn');
    add(smartdns?.host, 'smartdns');

    return out;
  }
}
