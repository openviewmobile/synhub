// QuickConnect / Serv.php 发现层
//
// 逆向自 APK 的：
//   com.synology.sylibx.syhttp3.relay.apis.ApiRelayServers
//   com.synology.sylibx.syhttp3.relay.apis.ApiDSM
//   com.synology.sylibx.syhttp3.relay.models.DSMInfo
// 以及 libsynoholepunch.so 的 GetPunchServerListSSL。
//
// 为什么放在 Dart 侧：NDK 不自带 libcurl，而且 HTTPS/证书/代理交给 Dart 生态更合适。
// 原生层通过 synopunch_add_echo_server() / synopunch_set_candidate() 接收结果。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import '../core/i18n/l10n.dart';
import '../core/net/network_type.dart';
import '../core/net/traffic_meter.dart';

/// Serv.php 的两个入口
class ServEndpoint {
  /// GLOBAL_SERVER_WW = 0
  static const String worldwide = 'https://global.quickconnect.to/Serv.php';

  /// GLOBAL_SERVER_CN = 1
  static const String china = 'https://global.quickconnect.cn/Serv.php';
}

/// echo 服务器：多个 IP 共用一个端口
class EchoSite {
  const EchoSite(this.host, this.port);
  final String host;
  final int port;

  @override
  String toString() => '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is EchoSite && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// `command: "get_echo_list"` 的结果
class EchoListResult {
  const EchoListResult({
    required this.sites,
    this.udtTxMss = 0,
    this.errno = 0,
  });

  final List<EchoSite> sites;

  /// 0 表示服务器未提供
  final int udtTxMss;
  final int errno;

  bool get isEmpty => sites.isEmpty;
}

/// 打洞候选地址
class PunchCandidate {
  const PunchCandidate(this.host, this.port, this.source);

  final String host;
  final int port;

  /// `smartdns` | `external` | `lan` —— 用于日志与优先级排序
  final String source;

  @override
  String toString() => '$host:$port ($source)';
}

/// `server` 组
class ServerGroup {
  const ServerGroup({
    this.serverId,
    this.external,
    this.ddns,
    this.fqdn,
    this.udpPunchPort = 0,
    this.tcpPunchPort = 0,
    this.behindNat = false,
    this.interfaceIps = const [],
  });

  final String? serverId;

  /// 外网 IP
  final String? external;
  final String? ddns;
  final String? fqdn;
  final int udpPunchPort;
  final int tcpPunchPort;
  final bool behindNat;
  final List<String> interfaceIps;

  factory ServerGroup.fromJson(Map<String, dynamic> j) {
    final ifaces = <String>[];
    final raw = j['interface'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map && e['ip'] is String) ifaces.add(e['ip'] as String);
      }
    }
    return ServerGroup(
      serverId: j['serverID'] as String?,
      external: _externalIp(j['external']),
      ddns: j['ddns'] as String?,
      fqdn: j['fqdn'] as String?,
      udpPunchPort: _asInt(j['udp_punch_port']),
      tcpPunchPort: _asInt(j['tcp_punch_port']),
      behindNat: j['behind_nat'] == true,
      interfaceIps: ifaces,
    );
  }
}

/// `smartdns` 组
class SmartDnsGroup {
  const SmartDnsGroup({this.host, this.external, this.lans = const []});

  final String? host;
  final String? external;
  final List<String> lans;

  factory SmartDnsGroup.fromJson(Map<String, dynamic> j) {
    // 真实响应是 `smartdns.lan`（单数，字符串数组）；
    // 早期按 `lans` 解析会永远得到空列表，而官方 App 恰恰走的就是这条。
    final lans = <String>[];
    for (final key in const ['lan', 'lans']) {
      final raw = j[key];
      if (raw is List) {
        for (final e in raw) {
          if (e is String && e.isNotEmpty && !lans.contains(e)) lans.add(e);
        }
      } else if (raw is String && raw.isNotEmpty) {
        if (!lans.contains(raw)) lans.add(raw);
      }
    }
    return SmartDnsGroup(
      host: j['host'] as String?,
      external: _externalIp(j['external']),
      lans: lans,
    );
  }
}

/// `env` 组
class EnvInfo {
  const EnvInfo({this.controlHost, this.relayRegion});

  final String? controlHost;
  final String? relayRegion;

  /// 真实响应用**下划线**命名（`control_host` / `relay_region`）；
  /// 驼峰形态也一并认，避免上游换写法时静默变成 null。
  factory EnvInfo.fromJson(Map<String, dynamic> j) => EnvInfo(
    controlHost: (j['control_host'] ?? j['controlHost']) as String?,
    relayRegion: (j['relay_region'] ?? j['relayRegion']) as String?,
  );
}

/// `server.external` 在真实响应里是对象 `{"ip": "...", "ipv6": "..."}`，
/// 不是字符串 —— 早期版本按 `as String?` 解析会抛
/// `type '_Map<String, dynamic>' is not a subtype of type 'String?'`。
/// 这里两种形态都认。
String? _externalIp(dynamic v) {
  if (v is String) return (v.isEmpty || v == 'NULL') ? null : v;
  if (v is Map) {
    final ip = v['ip'];
    if (ip is String && ip.isNotEmpty && ip != 'NULL') return ip;
  }
  return null;
}

/// `command: "get_server_info"` 的结果
class DsmInfo {
  const DsmInfo({
    this.env,
    this.server,
    this.smartdns,
    this.relayServers = const [],
    this.servicePort = 0,
    this.serviceExtPort = 0,
  });

  final EnvInfo? env;
  final ServerGroup? server;
  final SmartDnsGroup? smartdns;
  final List<String> relayServers;
  final int servicePort;
  final int serviceExtPort;

  factory DsmInfo.fromJson(Map<String, dynamic> j) {
    // relay_servers 有两个来源，原库 DSMInfo.parseServerInfo 都认：
    //   · errno == 0 → 响应里的 relay_servers 字段
    //   · errno != 0 → 响应里的 sites[]（远程客户端走中继时就是这个形态）
    final relays = <String>[];
    for (final key in const ['relay_servers', 'sites']) {
      final raw = j[key];
      if (raw is List) {
        for (final e in raw) {
          if (e is String && e.isNotEmpty && !relays.contains(e)) relays.add(e);
        }
      }
    }
    final svc = j['service'];
    return DsmInfo(
      env: j['env'] is Map
          ? EnvInfo.fromJson(Map<String, dynamic>.from(j['env'] as Map))
          : null,
      server: j['server'] is Map
          ? ServerGroup.fromJson(Map<String, dynamic>.from(j['server'] as Map))
          : null,
      smartdns: j['smartdns'] is Map
          ? SmartDnsGroup.fromJson(
              Map<String, dynamic>.from(j['smartdns'] as Map),
            )
          : null,
      relayServers: relays,
      servicePort: svc is Map ? _asInt(svc['port']) : 0,
      serviceExtPort: svc is Map ? _asInt(svc['extPort']) : 0,
    );
  }

  /// 按优先级给出打洞候选。
  ///
  /// 优先 smartdns 的 host（它同时是 DDNS/FQDN，解析到最优地址），
  /// 其次 server.external。端口一律用 `udp_punch_port`。
  List<PunchCandidate> punchCandidates() {
    final port = server?.udpPunchPort ?? 0;
    if (port <= 0) return const [];

    final out = <PunchCandidate>[];
    void add(String? host, String source) {
      // QuickConnect 用字面量 "NULL" 表示「无此地址」，必须过滤
      if (host == null || host.isEmpty || host == 'NULL') return;
      if (out.any((c) => c.host == host)) return;
      out.add(PunchCandidate(host, port, source));
    }

    add(smartdns?.host, 'smartdns');
    add(server?.external, 'external');
    add(server?.ddns, 'ddns');
    add(server?.fqdn, 'fqdn');
    for (final ip in server?.interfaceIps ?? const <String>[]) {
      add(ip, 'lan');
    }
    return out;
  }
}

/// 响应里 `errno != 0` 时抛出
class ServApiException implements Exception {
  ServApiException(this.message, {this.errno});
  final String message;
  final int? errno;

  @override
  String toString() =>
      'ServApiException($message${errno == null ? '' : ', errno=$errno'})';
}

/// Serv.php 客户端
class ServApi {
  ServApi({
    Dio? dio,
    this.useChinaSite = false,
    this.fallbackToChinaSite = true,
    this.deviceInChina,
    this.networkCountryIsoProbe,
    Duration? timeout,
    String? controlUrl,
  }) : _controlUrl = controlUrl,
       _dio = tagDioWithModule(
         dio ??
             Dio(
               BaseOptions(
                 connectTimeout: timeout ?? const Duration(seconds: 30),
                 receiveTimeout: timeout ?? const Duration(seconds: 30),
               ),
             ),
         TrafficModules.unattributed,
       );

  final Dio _dio;

  /// 释放内部 Dio。ServApi 是一次性用途（发现完就丢），用完即关。
  void close() {
    _dio.close(force: true);
  }

  final bool useChinaSite;

  /// 【概念③】worldwide 控制服务器**失败后**是否回落 `global.quickconnect.cn`。
  ///
  /// ★ 三个概念**互相独立**（AGENTS §2.0.26「同一语义不许造两份表示」），
  /// **任何一个都不许赋值给另一个**：
  ///   · ① [useChinaSite] = **用户显式选站点**（最高优先，压过一切）——
  ///     对齐官方 APK `ApiRelayServers(serverId, serviceId, isCallChinaSite)`：
  ///     它直接**换掉端点**，是"选哪个站"，不是错误分支；
  ///   · ② [deviceInChina] = **区域优先**（默认顺序的输入）——
  ///     对齐官方 APK `QuickConnectUtil.isDeviceInChina(Context)`；
  ///   · ③ [fallbackToChinaSite] = **失败后的回落分支** —— 对齐官方 SPK
  ///     `SYNO.Core.QuickConnect.so` 的 `SendControlServRequestWithFailover()`
  ///     与 `etc/synosupauthd.conf` 的 `control_server_host_fallback`。
  final bool fallbackToChinaSite;

  /// 【概念②】设备/网络是否在中国大陆 —— 官方 `isDeviceInChina(Context)` 的**结论**。
  ///
  /// `null`（默认）= 交给 [resolveIsDeviceInChina] 按平台事实推断（**平台 MCC 优先、
  /// 拿不到才回落 locale**）；测试**必须注入** `true`/`false`，否则用例结果会跟着
  /// **跑测机器的 locale** 变（§2.0.28 的假红来源）。
  final bool? deviceInChina;

  /// 【概念② 的输入通路】平台 MCC（`TelephonyManager.getNetworkCountryIso()`）**注入接缝**。
  ///
  /// `null`（默认）⇒ 走 [platformNetworkCountryIso]（**已有**的 `synhub/network` 桥 +
  /// **已有**的 [AppCapability.networkInfo] 能力门）；测试注入假探针 ⇒
  /// **零平台、零联网**。
  ///
  /// ★ 探针**拿不到时必须回 `null`（不是 `false`）** —— 由 [resolveIsDeviceInChina]
  /// 按官方顺序回落 locale。回 `false` 会把"不知道"伪造成"不在中国"。
  final Future<String?> Function()? networkCountryIsoProbe;

  /// 覆盖控制服务器 URL（测试用）
  final String? _controlUrl;

  /// 主控制服务器 URL（**显式选择**语义：`useChinaSite` 只换端点，
  /// 不参与回落决策，见 [controlServerCandidates]）。
  String get controlServerUrl =>
      _controlUrl ??
      (useChinaSite ? ServEndpoint.china : ServEndpoint.worldwide);

  /// 是否"中国区" —— **客户端顺序**决策的输入。
  ///
  /// 优先级**逐字照抄官方** `QuickConnectUtil.isDeviceInChina(Context)`：
  ///   ① 注入的 [deviceInChina]（测试/显式覆盖，最高优先）；
  ///   ② 平台 MCC `getNetworkCountryIso()` —— **非空即判、到此为止**（不看 locale）；
  ///   ③ MCC 为**空/拿不到**才回落 `getISO3Country()` / 平台 locale。
  ///
  /// ★ **判定逻辑一字未改**，就是 [deviceInChinaFrom]；这里只负责"接线"：
  /// 把 MCC 从 [networkCountryIsoProbe]（生产＝`synhub/network` 桥）取来。
  /// ★ 探针回 `null`（非 Android / 没有电话服务 / 桥抛异常）⇒ 走 ③ 回落，
  /// **绝不把"拿不到"当成"不在中国"**（§2.0.26④）。
  Future<bool> resolveIsDeviceInChina() async {
    final injected = deviceInChina;
    if (injected != null) return injected;
    final iso = await (networkCountryIsoProbe ?? platformNetworkCountryIso)();
    return deviceInChinaFrom(
      networkCountryIso: iso,
      localeCountryCode: platformLocale()?.countryCode,
    );
  }

  /// 控制服务器的**尝试顺序**（顺序尝试、**绝不并发**；同一条 URL 只出现一次）。
  ///
  /// ★ 取值依据 —— **服务端顺序 ≠ 客户端顺序**，我们照**客户端**：
  ///   · **中国区 ⇒ `[CN, WW]`（CN 优先）** `[取证]`：官方 APK `DSfinder 2.5.7-484`
  ///     `RelayManager.fetchRelayOrEnv` 在 `isDeviceInChina(context)` 为真时，先
  ///     `List;->add` CN 任务、再在 `:cond_0` `add` WW 任务（smali 行 532 / 536）
  ///     ⇒ 迭代器先吐 **CN**；循环里 `submit` 一个就立刻 `take` 一个，
  ///     **只有失败才 `goto :goto_0` 取下一个** ⇒ 严格顺序，不是并发。
  ///   · **非中国区**：官方客户端**压根不纳入 CN**（list 只有 WW）。本仓**多保留**
  ///     CN 作最后兜底 ⇒ `[WW, CN]`，依据是 `[取证]` 的 **SPK 服务端**
  ///     `control_server_host` + `control_server_host_fallback` 与 D4 台账验收
  ///     （worldwide 失败要能回落 CN）；该兜底受 [fallbackToChinaSite] 开关控制，
  ///     **想"只 WW"就把它关掉** ⇒ `[WW]`。
  ///   · [useChinaSite] 为真 ⇒ `[CN]` **唯一**（显式选站点，行为与改造前逐字节一致）。
  ///   · [_controlUrl] 被覆盖（离线单测的 loopback）⇒ `[该 URL]` **唯一** ——
  ///     否则会打到真实的 `global.quickconnect.cn`（单测绝不允许联网）。
  ///
  /// 异步是因为区域要读平台 MCC（[resolveIsDeviceInChina]）；顺序本身是纯函数
  /// [_candidatesFor] —— **只有这一份实现**（不另存第二份表示）。
  Future<List<String>> controlServerCandidates() async =>
      _candidatesFor(await resolveIsDeviceInChina());

  /// **唯一的顺序实现**；[controlServerCandidates] 解析出区域后调它。
  List<String> _candidatesFor(bool inChina) {
    if (_controlUrl != null) return [_controlUrl];
    if (useChinaSite) return const [ServEndpoint.china];
    if (inChina) {
      return const [ServEndpoint.china, ServEndpoint.worldwide];
    }
    return fallbackToChinaSite
        ? const [ServEndpoint.worldwide, ServEndpoint.china]
        : const [ServEndpoint.worldwide];
  }

  /// 官方 `QuickConnectUtil.isDeviceInChina(Context)` 的**逐条移植**（`[取证]`）。
  ///
  /// 官方 smali（样例库 APK `Android-DSfinder.2.5.7-484.ww.apk`，
  /// `com/synology/sylibx/syhttp3/util/QuickConnectUtil.smali`）的分支顺序：
  ///   ① `getApplicationContext() == null` ⇒ `false`；
  ///   ② `getSystemService("phone")` 拿不到 `TelephonyManager` ⇒ `false`；
  ///   ③ `tm.getNetworkCountryIso()`（**网络**国家码，**不是** SIM 的
  ///      `getSimCountryIso()`）**非空** ⇒ `"cn".equals(iso, ignoreCase)` —— **到此为止**；
  ///   ④ ③ 为空 ⇒ 回落 `getResources().getConfiguration().locales[0]` 的
  ///      `getISO3Country()`，判 `"CHN".equals(..., ignoreCase)`；
  ///   ⑤ 取不到 / 抛异常 ⇒ `false`（= 非中国区）。
  ///
  /// 本仓对 ③④ 两个输入的**来源**（诚实标注，**别当等价**）：
  ///   · ③ `getNetworkCountryIso()` ⇒ 由 [networkCountryIsoProbe] 提供；
  ///     生产实现是 [platformNetworkCountryIso]（**已有**的 `synhub/network` 桥，
  ///     `NetworkBridge.kt` 的 `networkCountryIso`，**没有新开通道**），
  ///     经**已有**的 [AppCapability.networkInfo] 能力门；非 Android / 没有电话服务 /
  ///     桥抛异常 ⇒ **`null`（不是 `false`）** ⇒ 自动落到 ④；
  ///   · ④ `locales[0]` ⇒ [platformLocale]（本仓平台语言的**唯一**入口，不另造一套），
  ///     其 `countryCode` 是 **ISO 3166-1 alpha-2**（`CN`），而 Android 的
  ///     `getISO3Country()` 是 alpha-3（`CHN`）—— **同一个国家的两种书写** ⇒ 两者都收。
  static bool deviceInChinaFrom({
    String? networkCountryIso,
    String? localeCountryCode,
  }) {
    final iso = networkCountryIso?.trim() ?? '';
    if (iso.isNotEmpty) return iso.toUpperCase() == 'CN';
    final code = localeCountryCode?.trim() ?? '';
    if (code.isEmpty) return false;
    final upper = code.toUpperCase();
    return upper == 'CHN' || upper == 'CN';
  }

  /// `command: "get_echo_list"` —— 打洞服务器列表
  ///
  /// 响应形如：
  ///   {"errno":0,"sites":["1.2.3.4","5.6.7.8"],"port":1234,"udt_tx_mss":1400}
  /// 注意 `sites` 是 IP 字符串数组，**共用一个 port**。
  Future<EchoListResult> fetchEchoList({String? url}) async {
    // 原库的 version 在 get_echo_list 里是字符串 "1"
    final body = await _post(url ?? controlServerUrl, {
      'version': '1',
      'command': 'get_echo_list',
    });

    final errno = _asInt(body['errno']);
    if (errno != 0) {
      throw ServApiException('get_echo_list errno=$errno', errno: errno);
    }

    final sitesRaw = body['sites'];
    final port = _asInt(body['port']);
    if (sitesRaw is! List) {
      throw ServApiException('get_echo_list: "sites" 不是数组');
    }
    if (body['port'] is! num) {
      throw ServApiException('get_echo_list: "port" 不是整数');
    }

    final sites = <EchoSite>[];
    for (final e in sitesRaw) {
      // 原库 isString() 判断，非字符串跳过
      if (e is String && e.isNotEmpty) sites.add(EchoSite(e, port));
    }

    var mss = _asInt(body['udt_tx_mss']);
    if (mss <= 0) mss = 0;

    return EchoListResult(sites: sites, udtTxMss: mss, errno: errno);
  }

  /// `command: "get_server_info"` —— 拿到 relay_servers / 打洞端口 / 外网地址
  ///
  /// [relayServer] 为空时打全球控制服务器；否则打区域中继服务器。
  /// 两个阶段的请求体完全相同（都用 `id` 字段）。
  Future<DsmInfo> fetchServerInfo({
    required String serverId,
    required String serviceId,
    String? relayServer,
    String? url,
  }) async {
    final target =
        url ??
        (relayServer == null
            ? controlServerUrl
            : 'https://$relayServer/Serv.php');

    final body = await _post(target, {
      'version': 1,
      'command': 'get_server_info',
      'serverID': serverId,
      'id': serviceId,
      'get_ca_fingerprints': true,
    });

    final errno = _asInt(body['errno']);
    if (errno != 0) {
      // ★ errno != 0 **不是错误**。原库 DSMInfo.parseServerInfo：
      //     errno != 0 且 sites[] 非空 → sites 就是中继服务器列表
      //     （远程客户端无法直连时，QuickConnect 就是这样回的）
      //   只有 sites 也为空时才算真失败。
      final sites = body['sites'];
      final hasSites = sites is List && sites.isNotEmpty;
      if (!hasSites) {
        throw ServApiException('get_server_info errno=$errno', errno: errno);
      }
      return DsmInfo.fromJson(body);
    }
    if (body['server'] is! Map) {
      throw ServApiException('get_server_info: 响应缺少 "server"');
    }
    return DsmInfo.fromJson(body);
  }

  /// 完整的发现流程：全球控制服务器拿 relay_servers → 逐个区域服务器查询。
  ///
  /// 与 `ApiDSM` 一致：并发查询，**第一个成功返回的胜出**。
  Future<DsmInfo> resolve({
    required String serverId,
    required String serviceId,
  }) async {
    final entry = await _fetchEntryInOrder(
      serverId: serverId,
      serviceId: serviceId,
    );

    // 全球服务器已给出完整 server 信息时直接用（部分部署如此）
    if (entry.server != null && entry.relayServers.isEmpty) return entry;

    final relays = entry.relayServers;
    if (relays.isEmpty) {
      throw ServApiException('响应里没有 relay_servers');
    }

    // 逐个查，并把每个失败的原因带上 —— 否则只剩「都失败了」，无从排查
    final failures = <String>[];
    for (final r in relays) {
      try {
        final info = await fetchServerInfo(
          serverId: serverId,
          serviceId: serviceId,
          relayServer: r,
        );
        if (info.server != null) return info;
        failures.add('$r: 响应里没有 server');
      } catch (e) {
        failures.add('$r: $e');
      }
    }
    throw ServApiException('所有 relay_servers 都查询失败 → ${failures.join(' | ')}');
  }

  /// 向控制服务器取 entry（`get_server_info`），按 [controlServerCandidates] **顺序**。
  ///
  /// 官方依据（`[取证]`）见 [controlServerCandidates] 的注释：客户端
  /// `RelayManager.fetchRelayOrEnv` 是"**中国区 CN 优先**、失败才试下一个"的
  /// **顺序**尝试；SPK 服务端的 `SendControlServRequestWithFailover()` /
  /// `control_server_host_fallback` 是 worldwide 主 + CN 回落。
  ///
  /// 「什么算失败」= 这次请求**抛出任何异常**：DNS/连接失败（即台账实测的 `000`）、
  /// 超时、HTTP ≥ 500（`_post` 的 `validateStatus` 只放过 < 500）、空 body、
  /// 非 JSON、以及 `errno != 0` 且 `sites[]` 也为空。
  /// **一个成功就立刻返回，后面的端点一次都不碰**（回落是"失败后才试"，不是并发都试）。
  ///
  /// 全部失败时**抛回最先尝试那次的原始异常**（含原始栈）—— 中国区抛 CN 的、
  /// 非中国区抛 WW 的；既不换成后一个端点的文案，也保证"候选只有一个"时
  /// 交付的错误路径与改动前**逐字节一致**。
  Future<DsmInfo> _fetchEntryInOrder({
    required String serverId,
    required String serviceId,
  }) async {
    Object? firstError;
    StackTrace? firstStack;
    for (final url in await controlServerCandidates()) {
      try {
        return await fetchServerInfo(
          serverId: serverId,
          serviceId: serviceId,
          url: url,
        );
      } catch (e, st) {
        if (firstError == null) {
          firstError = e;
          firstStack = st;
        }
      }
    }
    // 到这里说明每个候选都失败了（候选列表按构造非空）。
    Error.throwWithStackTrace(
      firstError ?? StateError('controlServerCandidates is empty'),
      firstStack ?? StackTrace.current,
    );
  }

  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> payload,
  ) async {
    // 原库用 OkHttp，Content-Type 为 text/plain（不是 application/json）
    final resp = await _dio.post<dynamic>(
      url,
      data: jsonEncode(payload),
      options: Options(
        contentType: 'text/plain',
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s < 500,
      ),
    );

    final data = resp.data;
    if (data is! String || data.isEmpty) {
      throw ServApiException('$url 返回空响应 (status=${resp.statusCode})');
    }
    final decoded = jsonDecode(data);
    if (decoded is! Map) {
      throw ServApiException('$url 返回的不是 JSON 对象');
    }
    return Map<String, dynamic>.from(decoded);
  }
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}
