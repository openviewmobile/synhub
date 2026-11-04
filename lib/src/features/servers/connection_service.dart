import 'package:dio/dio.dart';

import '../../core/i18n/l10n.dart';
import '../../core/net/dio_factory.dart';
import '../../core/net/trust_store.dart';
import '../../core/services/service_reporting_api.dart';
import '../../dsm/webapi.dart';
import '../../quickconnect/address_selector.dart';
import '../../quickconnect/serv_api.dart';
import 'server_profile.dart';

/// 一次成功连接的结果。
class DsmConnection {
  DsmConnection({
    required this.api,
    required this.endpoint,
    required this.profile,
    required this.dio,
    this.certPinned = false,
  });

  final DsmWebApi api;

  /// 实际连上的地址
  final ResolvedEndpoint endpoint;
  final ServerProfile profile;
  final Dio dio;

  /// 这次连接的服务器证书**没过系统 CA 校验**，是靠我们的固定指纹放行的。
  /// 外部播放器不认这种证书，所以音频/视频不能串流，只能先下载
  /// （对齐原版 `VideoUtil.handleIllegalCertificateStreaming`）。
  final bool certPinned;

  DsmSession? get session => api.session;

  String get describeKind => endpoint.source;
}

/// 连接过程中的一步，用于 UI 展示进度。
class ConnectStep {
  const ConnectStep(this.text, {this.ok = true});

  final String text;
  final bool ok;
}

/// 「拿到一个可用的 [DsmWebApi]」的全过程。
///
/// 打洞已搁置（见 `docs/holepunch-findings.md`），所以这里走的是
/// **直连**路径：QuickConnect 发现 → 地址候选 → 逐个探测。
/// 打洞隧道恢复后，只需在 [connect] 的候选列表里插入 TunnelTransport 分支。
class ConnectionService {
  ConnectionService({
    this.probeTimeout = const Duration(seconds: 6),
    this.qcRetryDelay = const Duration(milliseconds: 900),
    this.trustPolicy,
    this.dioBuilder,
    this.servApiFactory,
  });

  final Duration probeTimeout;

  /// QuickConnect 整轮解析失败后，重试前的等待（见
  /// [_resolveQuickConnectWithRetry]）。
  final Duration qcRetryDelay;

  /// 造 `ServApi` 的钩子（测试注入假实现用；为空就用真的）
  final ServApi Function()? servApiFactory;

  /// 首连信任策略（为空则沿用"一律放行"，集成测试/探针走这条路）
  final TrustPolicy? trustPolicy;

  /// 测试注入用：自己造 Dio（默认 [DioFactory.create]）
  final Dio Function(ResolvedEndpoint ep)? dioBuilder;

  /// 握手失败后由信任策略接管的错误标记
  static const String certErrorHint = 'CERT_UNTRUSTED';

  /// 解析 [profile] 并返回第一个探测成功的连接。
  ///
  /// [onStep] 每一步都会回调，便于 UI 实时显示。
  Future<DsmConnection> connect(
    ServerProfile profile, {
    void Function(ConnectStep)? onStep,
  }) async {
    final emit = onStep ?? (_) {};

    final endpoints = await _resolveEndpoints(profile, emit);
    if (endpoints.isEmpty) {
      throw StateError(currentText().srvNoAddress);
    }

    final tried = <String>[];
    for (final ep in endpoints) {
      final result = await _probeEndpoint(ep, emit);
      if (result != null) {
        emit(ConnectStep(currentText().srvConnected(ep.baseUrl, ep.source)));
        return DsmConnection(
          // `ServiceReportingApi` 是 `DsmWebApi` 的薄子类：行为完全一致，
          // 只在 `call` 失败时多回调一次"统一错误出口"→ 服务可用性状态层
          // （S2 接线，见 `service_reporting_api.dart`）。
          api: ServiceReportingApi(result.transport),
          endpoint: ep.withReachable(true),
          profile: profile,
          dio: result.dio,
          certPinned: result.certPinned,
        );
      }
      tried.add('${ep.baseUrl} ✗');
    }

    throw StateError(currentText().srvAllUnreachable(tried.join(', ')));
  }

  /// 探一个候选地址。证书不被信任时走"弹框 → 信任后重试一次"。
  Future<({DirectTransport transport, Dio dio, bool certPinned})?>
  _probeEndpoint(ResolvedEndpoint ep, void Function(ConnectStep) emit) async {
    // 探针 Dio：`probeTimeout`（6 s）**只**用于回答"这份候选地址现在通不通"
    // —— 多个候选要快速 failover，这里必须短。
    Dio newDio() =>
        dioBuilder?.call(ep) ??
        DioFactory.create(
          connectTimeout: probeTimeout,
          receiveTimeout: probeTimeout,
          trustPolicy: trustPolicy,
        );

    // ★★ r403（DA52）：探通之后**交给整个会话**的那把 Dio 必须换回正式超时。
    //
    // 真机实证（LGE-AN10，仪器㊷ 重建重装的带插桩包）：
    //   `[r403] searchLyrics title="Demo Song" artist="Demo Artist" id="music_28045"`
    //   `[r403] searchLyrics ERR elapsed=6013ms type=DsmTransportException`
    //   `…took longer than 0:00:06.000000 to receive data…`
    // 而同一请求在宿主只读探针里是 **~16 s 后 `200 {}`**
    // （`tool/probe_r403c_lyrics_latency.dart`）⇒ 服务端答得出来，是**客户端 6 s 就掐了**。
    // 根因就是这个函数把**探针**的 Dio 原样塞进 `DsmConnection.dio`
    // （`return (transport: transport, dio: dio, …)`）⇒ 会话里**每个**请求的
    // `receiveTimeout` 都是 6 s。凡"服务端要自己出网/算一会儿"的接口
    // （联网搜歌词、报告生成…）都会必然失败。
    //
    // 纪律：`dioBuilder` 是测试注入的假 Dio —— 保持原样（测试自己承担它的超时语义）。
    Dio sessionDioOf(Dio probe) =>
        dioBuilder != null ? probe : DioFactory.create(trustPolicy: trustPolicy);

    /// 把 transport 换成正式超时的 Dio（测试注入的那把不动）。
    ({DirectTransport transport, Dio dio}) promote(
      DirectTransport probeTransport,
      Dio probe,
    ) {
      final session = sessionDioOf(probe);
      if (identical(session, probe)) {
        return (transport: probeTransport, dio: probe);
      }
      return (
        transport: DirectTransport.url(ep.baseUrl, dio: session),
        dio: session,
      );
    }

    try {
      var dio = newDio();
      var transport = DirectTransport.url(ep.baseUrl, dio: dio);
      try {
        await transport.describe();
        final p0 = promote(transport, dio);
        return (
          transport: p0.transport,
          dio: p0.dio,
          certPinned: false,
        );
      } catch (e) {
        final challenge = await _certChallengeFor(ep, e);
        if (challenge == null) {
          emit(
            ConnectStep(
              currentText().srvUnreachable(ep.baseUrl, ep.source, _brief(e)),
              ok: false,
            ),
          );
          return null;
        }
        emit(
          ConnectStep(
            currentText().srvCertWaiting(ep.baseUrl, challenge.grouped),
            ok: false,
          ),
        );
        final ok = await trustPolicy!.decide(challenge);
        if (!ok) {
          emit(
            ConnectStep(currentText().srvCertRejected(ep.baseUrl), ok: false),
          );
          return null;
        }
        emit(ConnectStep(currentText().srvCertTrusted(challenge.host)));
        // 重建 Dio：旧 HttpClient 已经握过手失败，换一个干净的重试
        dio = newDio();
        transport = DirectTransport.url(ep.baseUrl, dio: dio);
        try {
          await transport.describe();
          // 走到这里说明系统的 CA 校验没过、是靠我们的固定指纹放行的
          // （= 原版 `CertificateStorageManager.isLegalCertificate() == false`）
          final p1 = promote(transport, dio);
          return (
            transport: p1.transport,
            dio: p1.dio,
            certPinned: true,
          );
        } catch (e2) {
          emit(
            ConnectStep(
              currentText().srvRetryFailed(ep.baseUrl, _brief(e2)),
              ok: false,
            ),
          );
          return null;
        }
      }
    } catch (e) {
      emit(
        ConnectStep(
          currentText().srvUnreachable(ep.baseUrl, ep.source, _brief(e)),
          ok: false,
        ),
      );
      return null;
    }
  }

  /// 这次失败是不是"证书没被信任"？是的话返回挑战对象。
  Future<TrustChallenge?> _certChallengeFor(
    ResolvedEndpoint ep,
    Object error,
  ) async {
    final policy = trustPolicy;
    if (policy == null) return null;
    final uri = Uri.tryParse(ep.baseUrl);
    if (uri == null || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final ch = policy.pendingFor(uri.host, port);
    if (ch != null) return ch;
    if (!_looksLikeTlsError(error)) return null;
    return null;
  }

  static bool _looksLikeTlsError(Object error) {
    final s = error.toString().toLowerCase();
    return s.contains('handshake') ||
        s.contains('certificate') ||
        s.contains('tls') ||
        s.contains('ssl') ||
        s.contains(certErrorHint.toLowerCase());
  }

  /// 把 [ServerProfile] 变成有序的候选地址列表。
  Future<List<ResolvedEndpoint>> _resolveEndpoints(
    ServerProfile profile,
    void Function(ConnectStep) emit,
  ) async {
    switch (profile.kind) {
      case ServerAddressKind.direct:
        final url = _ensurePort(profile.normalizedBaseUrl);
        emit(ConnectStep(currentText().srvUseDirect(url)));
        return [ResolvedEndpoint(baseUrl: url, source: 'direct')];

      case ServerAddressKind.quickConnect:
        emit(ConnectStep(currentText().srvQueryingQc(profile.value)));
        // `cnc.quickconnect.cn` 本身偶尔会 reset 连接（真机连跑多轮实测：
        // 一次「所有 relay_servers 都查询失败 → Connection reset by peer」，
        // 隔一会儿再查就好）。原版 `ServApi` 也是"轮着试 relay"，
        // 这里在整轮失败后再补一轮，别因为对方抖一下就登不上。
        final api = servApiFactory?.call() ?? ServApi();
        try {
          final info = await _resolveQuickConnectWithRetry(api, profile, emit);
          final port = info.effectiveServicePort;
          emit(
            ConnectStep(
              currentText().srvServicePort(
                port,
                info.env?.controlHost ?? '?',
                info.env?.relayRegion ?? '?',
              ),
            ),
          );
          final cands = info.httpCandidates();
          for (final c in cands) {
            emit(ConnectStep(currentText().srvCandidate(c.baseUrl, c.source)));
          }
          return cands;
        } finally {
          api.close();
        }
    }
  }

  /// QuickConnect 解析：整轮（所有 relay）失败后隔 [qcRetryDelay] 再试一次。
  ///
  /// 只重试**网络层**的失败；`ServApi.resolve` 自己已经会在多个 relay 之间轮询，
  /// 所以这里最多再补一轮（共两轮），不会把登录流程拖太久。
  Future<DsmInfo> _resolveQuickConnectWithRetry(
    ServApi api,
    ServerProfile profile,
    void Function(ConnectStep) emit,
  ) async {
    Object? firstError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await api.resolve(
          serverId: profile.value,
          serviceId: 'dsm_https',
        );
      } catch (e) {
        firstError ??= e;
        if (attempt == 0) {
          emit(ConnectStep(currentText().srvQcFailedRetry(_brief(e))));
          await Future<void>.delayed(qcRetryDelay);
        }
      }
    }
    throw firstError!;
  }

  /// 直连地址没写端口时补默认值：https → 5001。
  static String _ensurePort(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    if (uri.hasPort) return url;
    return '$url:5001';
  }

  static String _brief(Object e) {
    final s = e.toString();
    return s.length > 70 ? '${s.substring(0, 70)}…' : s;
  }
}
