// 网络流量计量（**精确档**）：挂在 `HttpClientAdapter` 上，按"字节真的流过"计数。
//
// 为什么挂 adapter 而不是 Dio 的 onRequest/onResponse 拦截器：
//   * `onResponse` 只有在**整个响应体读完之后**才触发 —— 想在那里量流式响应，
//     就得先把 body 收完（正是任务里禁止的"为了测量而缓冲"）；
//   * `HttpClientAdapter.fetch(options, requestStream, cancelFuture)` 拿到的是
//     **请求字节流**与 **ResponseBody.stream**，我们在两条流上各套一层
//     `map`，字节经过时累加 ⇒ 天然支持流式、分块（chunked）、Range(206)，
//     且**不缓冲任何东西**；
//   * 一次 `fetch` = 一次真实往返 ⇒ 请求 +1、响应 +1，重试/重放是新的 fetch，
//     各算各的；重定向若由 Dart `HttpClient` 在同一 fetch 内部完成，我们只
//     量到最终那一跳的 body（**宁可少算，绝不重复算**）。
//
// 归属（module）来自 `RequestOptions.extra[kTrafficModuleKey]`，**调用点显式写**，
// 不从 URL / API 名去猜（见 `DsmWebApi.withModule` 与各业务 API 类的构造器）。
// 没打标签的走 [TrafficModules.unattributed] —— 宁可显示"未归属"，也不静默丢。
//
// 档位（tier）：
//   * [TrafficTier.exact]   —— 本文件量的，Dart HTTP 客户端的全部真实字节；
//   * [TrafficTier.estimated] —— 原生播放器/原生桥绕过 Dart 的流量，由
//     `device_traffic.dart` 在**已知活动会话**前后采 UID 计数得出，**估算**。
//     两条路绝不混在一起（见 `docs/network-traffic-analytics.md`）。
//
// 隐私：本文件不接触 URL / host / path —— 只读 module 标签、方向、字节数、
// 时刻；`TrafficSample` 里根本没有承载地址的字段。守卫
// `test/traffic_privacy_test.dart` 静态扫描本文件禁用的键。
//
// 成本：每 chunk 一次加法和一次 map 转发，无缓冲、无按字节日志、无定时器；
// 实测（`test/traffic_meter_test.dart`）在 1 MB / 64 KB 分块下没有可观测开销。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 流量档位（**落库常量，只增不改**）
enum TrafficTier {
  /// Dart HTTP 客户端实际传输的字节（请求 + 响应，按流计）。
  exact('exact'),

  /// 原生组件（播放器 / 原生桥 / 原生下载）绕过 Dart 的流量，
  /// 由 UID 计数在**已知活动会话**窗口内差分得到。
  estimated('estimated');

  const TrafficTier(this.id);

  final String id;

  static TrafficTier? byId(String id) {
    for (final t in TrafficTier.values) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// 方向：`down` = 设备收到的字节（Rx），`up` = 设备发出的字节（Tx）
enum TrafficDirection {
  down('down'),
  up('up');

  const TrafficDirection(this.id);

  final String id;

  static TrafficDirection? byId(String id) {
    for (final d in TrafficDirection.values) {
      if (d.id == id) return d;
    }
    return null;
  }
}

/// 与 `UsageModule.id` **逐一对应**的模块 id 常量。
///
/// 为什么不直接用 `UsageModule`：`lib/src/dsm/**`、`lib/src/data/**` 不能
/// import `features/**`（分层，且数据层要保持纯 Dart 可加载）。这里登记一份
/// 常量，守卫 `test/traffic_coverage_test.dart` 断言它与 `UsageModule`
/// 的 id **双向一致** —— 加模块时两边都会被逼着改。
abstract final class TrafficModules {
  static const String workspace = 'workspace';
  static const String files = 'files';
  static const String drive = 'drive';
  static const String notes = 'notes';
  static const String photos = 'photos';
  static const String calendar = 'calendar';
  static const String contacts = 'contacts';
  static const String chat = 'chat';
  static const String search = 'search';
  static const String reader = 'reader';
  static const String office = 'office';
  static const String settings = 'settings';
  static const String audio = 'audio';
  static const String media = 'media';
  static const String ai = 'ai';
  static const String downloads = 'downloads';
  static const String admin = 'admin';
  static const String surveillance = 'surveillance';
  static const String mailplus = 'mailplus';

  /// **未归属**：任何没打模块标签的 Dart 请求都落这里。
  /// 它不是一个"功能模块"，但必须存在 —— 否则未打标签的流量会凭空消失。
  static const String unattributed = 'unattributed';

  /// 全部合法标签（守卫用）
  static const Set<String> all = {
    workspace,
    files,
    drive,
    notes,
    photos,
    calendar,
    contacts,
    chat,
    search,
    reader,
    office,
    settings,
    audio,
    media,
    ai,
    downloads,
    admin,
    surveillance,
    mailplus,
    unattributed,
  };
}

/// `RequestOptions.extra` 里的模块标签键（`DsmWebApi` / 独立客户端写入）
const String kTrafficModuleKey = 'synhub.traffic.module';

/// `RequestOptions.extra` 里的档位键（默认 `exact`；原生桥的量不走这里）
const String kTrafficTierKey = 'synhub.traffic.tier';

/// `RequestOptions.extra` 里的接入方式键（`wifi` / `mobile` / `other`；可空）
const String kTrafficTransportKey = 'synhub.traffic.transport';

/// 一条**精确**流量样本，正好是落库需要的字段（无地址、无内容）
class TrafficSample {
  const TrafficSample({
    required this.at,
    required this.module,
    required this.direction,
    required this.bytes,
    this.tier = TrafficTier.exact,
    this.transport = '',
  });

  final DateTime at;
  final String module;
  final TrafficDirection direction;
  final int bytes;
  final TrafficTier tier;
  final String transport;

  @override
  String toString() =>
      'TrafficSample(${at.toIso8601String()}, $module, ${direction.id}, '
      '$bytes B, ${tier.id})';
}

/// 一个**已知活动会话**的估算流量（原生组件绕过 Dart 的那部分）。
///
/// 只有"会话开始 → 会话结束"之间的 UID 差分才会被估算并归属；
/// 空闲期的差值永远不归属给任何模块。
class TrafficEstimate {
  const TrafficEstimate({
    required this.from,
    required this.to,
    required this.module,
    required this.direction,
    required this.bytes,
    this.transport = '',
  });

  final DateTime from;
  final DateTime to;
  final String module;
  final TrafficDirection direction;
  final int bytes;
  final String transport;
}

/// 计量接收端。生产实现是 `TrafficLog`（写本地聚合库）；
/// 测试用内存实现。整条链路 fire-and-forget：失败只丢样本，绝不抛回业务。
abstract class TrafficSink {
  /// 记一笔精确流量（可能是**每 chunk 合并后**的一次）
  void addExact(TrafficSample sample);

  /// 记一笔估算流量（会话窗口差分）
  void addEstimate(TrafficEstimate estimate);
}

TrafficSink? _sink;

/// 启动时注入（`app.dart`）；没注入时计量是纯 no-op
void setGlobalTrafficSink(TrafficSink? sink) => _sink = sink;

/// 当前接收端（测试/诊断用）
TrafficSink? get globalTrafficSink => _sink;

/// 当前接入方式（wifi/mobile/other/''），由 app 注入的同步读取器提供。
/// 只在**打标签时**读一个字符串，不做 IO、不阻塞请求。
String Function()? _transportIdReader;

void setTrafficTransportReader(String Function()? reader) =>
    _transportIdReader = reader;

String _currentTransport() {
  try {
    return _transportIdReader?.call() ?? '';
  } catch (_) {
    return '';
  }
}

/// 把一个 Dio 变成"带计量的 Dio"：包一层 `HttpClientAdapter`。
///
/// 幂等：重复 attach 不会叠加（最外层只保留一层计量）。
/// 返回传入的 dio，便于链式使用。
Dio attachTrafficMeter(Dio dio) {
  final adapter = dio.httpClientAdapter;
  if (adapter is MeteredHttpClientAdapter) return dio;
  dio.httpClientAdapter = MeteredHttpClientAdapter(adapter);
  return dio;
}

/// 给"整条 Dio 都属于某个模块"的独立客户端装计量 + 统一标签。
///
/// 适合自建 Dio 的客户端（天气 / 地理 / 节假日 / 云端 LLM / 图生图 / WebDAV）：
/// 它们的模块归属在**客户端构造处**声明一次，不用逐个调用点重复写。
/// `DsmWebApi` 的路径不同 —— 那里按 `withModule` 句柄打标签。
Dio tagDioWithModule(Dio dio, String module, {String transport = ''}) {
  attachTrafficMeter(dio);
  if (!dio.interceptors.any((i) => i is TrafficTagInterceptor)) {
    dio.interceptors.insert(
      0,
      TrafficTagInterceptor(module, transport: transport),
    );
  }
  return dio;
}

/// 统一给请求写模块标签的拦截器
class TrafficTagInterceptor extends Interceptor {
  TrafficTagInterceptor(this.module, {this.transport = ''});

  final String module;
  final String transport;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[kTrafficModuleKey] = TrafficModules.all.contains(module)
        ? module
        : TrafficModules.unattributed;
    if (transport.isNotEmpty) {
      options.extra[kTrafficTransportKey] = transport;
    }
    handler.next(options);
  }
}

/// 计量适配器：**只做字节计数**，不改语义、不改 header、不碰 body 内容。
class MeteredHttpClientAdapter implements HttpClientAdapter {
  MeteredHttpClientAdapter(this.inner);

  final HttpClientAdapter inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final module = _moduleOf(options);
    final tier = _tierOf(options);
    final transport = _transportOf(options);

    var sent = 0;
    Stream<Uint8List>? meteredRequest;
    if (requestStream != null) {
      meteredRequest = requestStream.map((chunk) {
        sent += chunk.length;
        return chunk;
      });
    }

    final ResponseBody body;
    try {
      body = await inner.fetch(options, meteredRequest, cancelFuture);
    } catch (_) {
      // 发失败也算发过：底层适配器已经消费（或尝试消费）了请求流
      if (requestStream != null) {
        _emit(options, module, tier, transport, TrafficDirection.up, sent);
      }
      rethrow;
    }

    // 请求流由底层适配器消费；fetch 返回时请求体已发完 ⇒ 在这里补报 Tx。
    if (requestStream != null) {
      _emit(options, module, tier, transport, TrafficDirection.up, sent);
    }

    var received = 0;
    final metered = body.stream.map((chunk) {
      received += chunk.length;
      return chunk;
    });
    final reported = metered.transform(
      StreamTransformer<Uint8List, Uint8List>.fromHandlers(
        handleData: (data, sink) => sink.add(data),
        handleDone: (sink) {
          _emit(
            options,
            module,
            tier,
            transport,
            TrafficDirection.down,
            received,
          );
          sink.close();
        },
        handleError: (e, st, sink) {
          _emit(
            options,
            module,
            tier,
            transport,
            TrafficDirection.down,
            received,
          );
          sink.addError(e, st);
          sink.close();
        },
      ),
    );

    return ResponseBody(
      reported,
      body.statusCode,
      statusMessage: body.statusMessage,
      isRedirect: body.isRedirect,
      redirects: body.redirects,
      headers: body.headers,
    );
  }

  @override
  void close({bool force = false}) => inner.close(force: force);

  static void _emit(
    RequestOptions options,
    String module,
    TrafficTier tier,
    String transport,
    TrafficDirection direction,
    int bytes,
  ) {
    if (bytes <= 0) return;
    final sink = _sink;
    if (sink == null) return;
    try {
      sink.addExact(
        TrafficSample(
          at: DateTime.now(),
          module: module,
          direction: direction,
          bytes: bytes,
          tier: tier,
          transport: transport.isEmpty ? _currentTransport() : transport,
        ),
      );
    } catch (_) {
      // 计量失败绝不影响业务
    }
  }

  static String _moduleOf(RequestOptions options) {
    final m = options.extra[kTrafficModuleKey];
    if (m is String && m.isNotEmpty && TrafficModules.all.contains(m)) {
      return m;
    }
    return TrafficModules.unattributed;
  }

  static TrafficTier _tierOf(RequestOptions options) {
    final t = options.extra[kTrafficTierKey];
    if (t is String) return TrafficTier.byId(t) ?? TrafficTier.exact;
    return TrafficTier.exact;
  }

  static String _transportOf(RequestOptions options) {
    final t = options.extra[kTrafficTransportKey];
    if (t is String) return t;
    return _currentTransport();
  }
}

/// 把模块标签写进一次请求的 `extra`（独立 Dio 客户端用）。
///
/// `DsmWebApi` 有自己的 `withModule` 句柄；这里是给 `weather_client` /
/// `geocode_client` / `holiday_service` / `cloud_llm_client` 这类**自建 Dio**
/// 的接入点 —— 同样显式、同样默认落在 `unattributed`。
Options trafficOptions(
  String module, {
  Options? base,
  String transport = '',
}) {
  final extra = <String, dynamic>{
    ...?base?.extra,
    kTrafficModuleKey: TrafficModules.all.contains(module)
        ? module
        : TrafficModules.unattributed,
    if (transport.isNotEmpty) kTrafficTransportKey: transport,
  };
  return (base ?? Options()).copyWith(extra: extra);
}
