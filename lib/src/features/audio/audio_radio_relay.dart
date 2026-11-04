// 明文电台流的**回环中继**（Android release 档让"http 电台"能进原生播放器）。
//
// ════════════════════════════════════════════════════════════════════════
// ★★★ 为什么需要它（第 392 轮真机根因，逐字复现）
// ════════════════════════════════════════════════════════════════════════
//
// 本仓 `android/app/src/main/res/xml/network_security_config.xml` 的策略是
// **base-config 禁止一切明文**，只给 `127.0.0.1` / `localhost` 开口子
// （那是当年为"本机 Mock + `adb reverse`"留的测试通路）。
// 而网络电台绝大多数是 **明文 http**（SHOUTcast 目录里的站就是，逐字：
// `http://yp.shoutcast.com/sbin/tunein-station.pls?id=…` → `http://50.31.185.139/1005`）。
//
// 真机读数（r392，安装包 sha256 `6679b5f7…`）：
// ```
// E ExoPlayerImplInternal: Caused by: java.io.IOException:
//     Cleartext HTTP traffic to 50.31.185.139 not permitted
//   at com.android.okhttp.HttpHandler$CleartextURLFilter.checkURLPermitted
// ```
// ⇒ Media3/ExoPlayer 走**系统** `NetworkSecurityPolicy`，明文一律拒；
// 而 **Dart 的 `HttpClient` 走裸 socket、不受该策略约束** ——
// 同一轮真机日志里 `resolveRadioStreamUrl` 成功取回了那个 `http://` 的 `.pls`
// （`[audio-radio] play … resolved=true …`）。
//
// ★ 解法（**不放宽任何安全策略**）：让 ExoPlayer 拿到**回环地址**（策略本来就允许），
//   由 App 自己在 `127.0.0.1` 上做一个**只转发字节**的小中继，
//   上游取流仍走 Dart 的 socket。与官方 DSaudio 的网络配置形状保持一致
//   （官方 `res/8G.xml` 也只有 base-config + trust-anchors，**没有**放开明文）。
//
// ★ 安全边界（三条，写清不装神秘）：
//   ① 监听地址**只有** `127.0.0.1`（其它设备连不上）；
//   ② 路径里带**每次启动随机生成的 token**，别的 App 猜不到就没法拿它当跳板；
//   ③ 目标 URL 只允许 `http`/`https`，不接受 `file:` 之类（防本机文件被读出去）。
//
// ★ 只处理**需要**的情况：`https` 或本来就是回环的地址**原样返回**（不绕中继）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:math';

/// 进站请求的裁定结果（纯数据，便于单测）。
class RelayRoute {
  const RelayRoute({required this.target}) : error = '';
  const RelayRoute.reject(this.error) : target = null;

  /// 要转发的上游地址（被拒时 null）。
  final Uri? target;

  /// 拒的理由（`notFound` / `badRequest`；转发时为空串）。
  final String error;
}

/// 把"要播的地址"翻译成"ExoPlayer 能播的地址"。
abstract interface class RadioStreamRelay {
  /// 返回**回环中继地址**（需要时）或**原地址**（https / 已是回环）。
  ///
  /// 上游不可达不会在这里报错 —— 取流失败由中继在请求时回 `502`，
  /// 播放器照常报错，页面按既有失败分类提示。
  Future<String> playableUrl(String url);
}

/// 不需要中继的实现（测试默认用；也可作为"平台不支持时"的回落）。
class NoopRadioStreamRelay implements RadioStreamRelay {
  const NoopRadioStreamRelay();

  @override
  Future<String> playableUrl(String url) async => url;
}

/// 是否是**回环族**主机（`localhost` / `127.0.0.0/8` / `::1`，含 `127.0.0.1` 的
/// 整数写法 `2130706433`）。
///
/// ★ 第 394 轮补强：原来只比 `'127.0.0.1'` 字面量 ⇒ `http://127.0.0.2:8080/x`
/// 能当上游（`127.0.0.0/8` 全是本机回环）—— 与"防自环 / 防被当成读本机服务的手"
/// 这条规则的**本意**不符。现在按**整个回环族**判。
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '::1' || h == '0:0:0:0:0:0:0:1') return true;
  if (h.startsWith('127.')) return true;
  // 整数写法（`2130706433` = 127.0.0.1）：只认 127/8 那一段
  if (h.length <= 10 && h.isNotEmpty && int.tryParse(h) != null) {
    final n = int.parse(h);
    if (n >= 0x7F000000 && n <= 0x7FFFFFFF) return true;
  }
  return false;
}

/// 判断"这条地址要不要绕回环中继"。
///
/// 要绕的**只有一种**：`http`（明文）且主机**不是**回环 ——
/// `https` 走系统信任链正常播；回环地址本来就被策略允许。
bool needsCleartextRelay(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return false;
  if (uri.scheme != 'http') return false;
  if (uri.host.isEmpty) return false;
  if (isLoopbackHost(uri.host)) return false;
  return true;
}

/// ★★★ 仪器64：`icy-metaint` 是**"身体依赖它"的头** —— 决定要不要转发它。
///
/// 上游一旦声明 `icy-metaint: N (N>0)`，后面的字节流就**不是**纯音频，而是
/// 「N 字节音频 + 1 字节长度 + 16×长度 字节元数据」的循环。播放器**必须**知道 N
/// 才能把元数据剥掉（Media3：`IcyHeaders.parse` → `IcyDataSource`）。
/// 第 394 轮真机根因就是这里：中继把请求头 `Icy-MetaData: 1`
/// （Media3 `ProgressiveMediaPeriod` 的常量池里逐字就有这个字面量）转给了站，
/// 站于是回 `icy-metaint: 1024` 并在流里插元数据，**而中继把 `icy-metaint` 吃了**、
/// 字节却照搬 —— 于是 ExoPlayer 把元数据当音频读，报
/// `None of the available extractors could read the stream … sniff failures: [NoDeclaredBrand, …]`。
///
/// 反向（同样致命）：`0` / 负数 / 非数字**绝不能**转发 —— 那种站**没有**插元数据，
/// 而播放器看到 `icy-metaint: 0` 会走进"按 0 字节拆包"的分支，把**好流拆坏**
/// （`Blues Radio` 那类站正是 `icy-metaint: 0`）。所以"只转发正整数"是这条修复的
/// **判别式**，不是顺手加的过滤器。
///
/// 返回要转发的值（正整数原样，已去空白）；不该转发时返回空串。
String icyMetaIntToForward(String? declared) {
  final raw = declared?.trim() ?? '';
  if (raw.isEmpty) return '';
  final n = int.tryParse(raw);
  if (n == null || n <= 0) return '';
  return raw;
}

/// 真实现：`127.0.0.1` 上的**单向上游转发**小服务（懒启动，进程内只起一次）。
class LoopbackRadioStreamRelay implements RadioStreamRelay {
  LoopbackRadioStreamRelay({
    HttpClient? client,
    Random? random,
    Duration? timeout,
  }) : _client = client,
       _random = random ?? Random.secure(),
       _timeout = timeout ?? const Duration(seconds: 15);

  final HttpClient? _client;
  final Random _random;
  final Duration _timeout;

  HttpServer? _server;
  String? _token;

  /// 已启动的中继端口（未启动时为 null；单测直接读它）。
  int? get port => _server?.port;

  /// 每次启动随机的路径 token（其它 App 拿到也没用 —— 目标由服务端侧决定）
  String? get token => _token;

  /// 转发的请求数（单测/真机诊断用）。
  int forwarded = 0;

  static const String _kPathPrefix = '/r/';

  @override
  Future<String> playableUrl(String url) async {
    if (!needsCleartextRelay(url)) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    await _ensureStarted();
    return 'http://127.0.0.1:${_server!.port}$_kPathPrefix$_token'
        '?u=${Uri.encodeQueryComponent(url)}';
  }

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    _token = _newToken();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(_serve(server));
  }

  String _newToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 解析一条进站请求该"转发到哪 / 直接拒"（**纯函数**，安全边界就是它）。
  ///
  /// 返回值：`target != null` ⇒ 转发到它；否则按 [error] 回码
  /// （`notFound` = 路径/token 不对，`badRequest` = 目标不合法）。
  static RelayRoute parseRelayRoute({
    required String path,
    required Map<String, String> query,
    required String? token,
  }) {
    if (token == null || path != '$_kPathPrefix$token') {
      return const RelayRoute.reject('notFound');
    }
    final raw = query['u'];
    final uri = raw == null ? null : Uri.tryParse(raw);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return const RelayRoute.reject('badRequest');
    }
    // 不许转发回自己/回环目标（防自环；也防止被当成读本机服务的手）——
    // 判据是**整个回环族**（`127.0.0.0/8` / `::1` / `localhost`），不是单个字面量。
    if (isLoopbackHost(uri.host)) {
      return const RelayRoute.reject('badRequest');
    }
    return RelayRoute(target: uri);
  }

  /// 关掉中继（测试收尾；生产进程退出即回收）。
  Future<void> close() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  Future<void> _serve(HttpServer server) async {
    await for (final req in server) {
      unawaited(_handle(req));
    }
  }

  Future<void> _handle(HttpRequest req) async {
    // 路径/token/目标合法性：判据全在**纯函数**里（单测直接测它）
    final route = parseRelayRoute(
      path: req.uri.path,
      query: req.uri.queryParameters,
      token: _token,
    );
    final targetUri = route.target;
    if (targetUri == null) {
      req.response.statusCode = route.error == 'notFound'
          ? HttpStatus.notFound
          : HttpStatus.badRequest;
      await req.response.close();
      return;
    }

    final client = _client ?? (HttpClient()..connectionTimeout = _timeout);
    try {
      final up = await client.getUrl(targetUri).timeout(_timeout);
      // 只搬"取流"需要的头：Range（拖动/续播）+ 常见媒体请求头。
      // ★ `Icy-MetaData` 照搬（**不代客户端编造**）：Media3 的
      //   `ProgressiveMediaPeriod` 会自己发 `Icy-MetaData: 1`；站据此才在流里
      //   插元数据、并在响应里声明 `icy-metaint`。请求头与响应头必须**成对**过中继，
      //   少哪一半都会把流读坏（见 `icyMetaIntToForward` 的注释）。
      for (final name in const ['range', 'user-agent', 'accept', 'icy-metadata']) {
        final v = req.headers.value(name);
        if (v != null) {
          up.headers.set(name == 'icy-metadata' ? 'Icy-MetaData' : name, v);
        }
      }
      if (req.headers.value('user-agent') == null) {
        up.headers.set(HttpHeaders.userAgentHeader, _kUserAgent);
      }
      final res = await up.close().timeout(_timeout);
      forwarded++;
      final declaredMetaInt = res.headers.value('icy-metaint');
      debugPrint(
        '[audio-radio-relay] up=${targetUri.toString()} status=${res.statusCode} '
        'type=${res.headers.value('content-type') ?? '-'} '
        'len=${res.contentLength} '
        'reqRange=${req.headers.value('range') ?? '-'} '
        'reqIcy=${req.headers.value('icy-metadata') ?? '-'} '
        'upMetaint=${declaredMetaInt ?? '-'} '
        'reqUA=${req.headers.value('user-agent') ?? '-'}',
      );
      final out = req.response;
      out.statusCode = res.statusCode;
      // 逐字搬回：内容类型/长度/Range 语义（透明代理的判据）
      for (final name in const [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
        'icy-name',
        'icy-genre',
        'icy-br',
      ]) {
        final v = res.headers.value(name);
        if (v != null) out.headers.set(name, v);
      }
      // ★ 仪器64：字节流的**形状**声明必须与字节一起过中继。
      //   只转发正整数 —— `0`/负数/非数字意味着上游没插元数据（转发过去会让
      //   播放器按"0 字节拆包"把好流拆坏）。字节本身**一字不改**。
      final metaInt = icyMetaIntToForward(declaredMetaInt);
      if (metaInt.isNotEmpty) out.headers.set('icy-metaint', metaInt);
      var bytes = 0;
      var head = '';
      // ★★ 只在**首字节**之前兜底超时（`-- 仪器65`）。
      //   原来这里写的是 `addStream(...).timeout(_timeout)`：把"15 秒没有数据事件"
      //   一律当"上游死了"。**这是错的** —— 事件停下来的原因还可能是**我方不收了**：
      //   `IOSink.addStream` 走背压，播放器缓冲满了会 `pause()` 上游订阅，
      //   于是中继自己制造出 15 秒静默，然后**亲手切断一条健康的直播流**。
      //   真机读数（r394）：站方宿主机实测 45 s 收到 858,151 B、唯一一次间隔 1.0 s
      //   （连续供流），而中继每 15.00 s 报一次 `timeout`、播放器
      //   `buffered position` 冻在 21080 ms ⇒ 是**消费者背压**，不是站方停流。
      //   正确语义：上游**接了连接却一个字节都不发**才是卡死；开流之后不设空闲超时
      //   （`onTimeout` 里什么都不做 ⇒ Dart 会重启计时器，等于只在首字节前生效）。
      var started = false;
      await out.addStream(
        res
            .map((chunk) {
              started = true;
              if (head.isEmpty && chunk.isNotEmpty) {
                head = chunk
                    .take(8)
                    .map((b) => b.toRadixString(16).padLeft(2, '0'))
                    .join();
              }
              bytes += chunk.length;
              return chunk;
            })
            .timeout(
              _timeout,
              onTimeout: (sink) {
                if (!started) {
                  sink.addError(
                    TimeoutException('中继首字节超时（上游接了连接但不发流）', _timeout),
                  );
                }
                // 已开流：不报错、不关闭 ⇒ 计时器重启（背压不是故障）
              },
            ),
      );
      await out.close();
      debugPrint('[audio-radio-relay] done bytes=$bytes head=$head');
    } on TimeoutException {
      // 取流超时：留痕（否则真机上只看到播放器报"读不出"，不知道是我方超时）
      debugPrint('[audio-radio-relay] timeout up=${targetUri.toString()}');
      await _fail(req, HttpStatus.gatewayTimeout);
    } catch (e) {
      // 任何转发失败都要有读者：真机复验时"502 是为什么"只能看这一行
      debugPrint('[audio-radio-relay] failed up=${targetUri.toString()} err=$e');
      await _fail(req, HttpStatus.badGateway);
    } finally {
      if (_client == null) client.close(force: true);
    }
  }

  Future<void> _fail(HttpRequest req, int code) async {
    try {
      req.response.statusCode = code;
      await req.response.close();
    } catch (_) {
      // 客户端已经走了：不用管
    }
  }

  static const String _kUserAgent = 'synhub/1.0 (Android; internet radio relay)';
}
