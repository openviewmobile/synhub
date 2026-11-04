// 网络电台 **仪器64**（第 394 轮根因）的离线验证：**`icy-metaint` 必须与字节一起过中继**。
//
// 根因（三层证据，见 `docs/evidence-r394/`）：
//   ① 上游站：带 `Icy-MetaData: 1` 请求 ⇒ 响应 `icy-metaint: 1024`，**字节流**变成
//      「1024 字节音频 + 1 字节长度 + 16×长度 字节元数据」循环（原始字节逐帧核对：
//      不带请求头时 offset 0 起 ≥64 帧连续；带请求头时**第 4 帧就断在 offset 1254**）；
//   ② 播放器：`androidx.media3.exoplayer.source.ProgressiveMediaPeriod` 的常量池里
//      **逐字**有 `Icy-MetaData` = `"1"`；`androidx.media3.extractor.metadata.icy.IcyHeaders`
//      里逐字有 `icy-metaint` ⇒ 它**本来就会**按声明把元数据剥掉；
//   ③ 我方中继：把请求头转给了站，却**没把响应里的 `icy-metaint` 带回**，字节照搬
//      ⇒ ExoPlayer 把元数据当音频读 ⇒ `None of the available extractors could read
//      the stream … sniff failures: [NoDeclaredBrand, NoDeclaredBrand]`。
//
// 本文件覆盖（全部离线；真中继 + **假 HttpClient** 当上游，不碰真网络）：
//   ① `icyMetaIntToForward` 只放**正整数**（含反向：`0`/负/非数字/空）；
//   ② 端到端：上游声明 1024 ⇒ 中继把它带回，且**字节一字不改**（含元数据块）；
//      ★ 同时证明"请求头照搬、不代客户端编造"（假上游看到 `Icy-MetaData: 1`，规范大小写）；
//   ③ ★ 反向（回归守卫）：上游声明 `0` ⇒ **不**带回该头（`Blues Radio` 那类站就靠这条
//      不被"按 0 字节拆包"拆坏），字节同样一字不改；
//   ④ ★ 反向：客户端**没发** `Icy-MetaData` ⇒ 假上游也不该看到它（转发是照搬，不是补齐）；
//   ⑤ ★ 反向：上游声明垃圾值 `abc` ⇒ 不带回。
//   ⑥ 回环族收紧：`127.0.0.2` / 整数写法 `2130706433` 也**不许**当上游（SSRF 面）。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/audio/audio_radio_relay.dart';

/// 一小段**合法且连续**的 MP3 帧（帧头 `fffb9264` = MPEG-1 Layer III 128 kbps 44.1 kHz）。
List<int> _mp3Bytes(int frames) {
  const frameLength = 417; // 144*128000/44100 ≈ 417（无 padding）
  return [
    for (var f = 0; f < frames; f++) ...[0xFF, 0xFB, 0x92, 0x64, ...List.filled(frameLength - 4, 0x11)],
  ];
}

/// 假上游：把"站会怎么答"钉死成可复现的形状（响应头 + 字节体），并记录它收到的请求头。
class _FakeUpstream implements HttpClient {
  _FakeUpstream({required this.responseHeaders, required this.body});

  final Map<String, String> responseHeaders;

  /// 上游的字节流（用 `Stream` 表达 ⇒ 可以造"先到一段、隔一会儿再到"的形状）。
  final List<int> body;

  /// ★ 仪器65 用的形状：`(等待多久, 这一段字节)` 的序列。
  List<(Duration, List<int>)> schedule = const [];
  final List<Map<String, String>> seenRequestHeaders = [];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    seenRequestHeaders.add({});
    return _FakeRequest(this);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('假上游没实现 ${invocation.memberName}');
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.up);

  final _FakeUpstream up;

  @override
  late final HttpHeaders headers = _FakeHeaders(up);

  @override
  Future<HttpClientResponse> close() async => _FakeResponse(up);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('假上游没实现 ${invocation.memberName}');
}

class _FakeHeaders implements HttpHeaders {
  _FakeHeaders(this.up);

  final _FakeUpstream up;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    // 记下**中继实际发出去的头**（大小写也记，仪器64 的判据之一）
    up.seenRequestHeaders.last[name] = '$value';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse implements HttpClientResponse {
  _FakeResponse(this.up);

  final _FakeUpstream up;
  final _FakeRespHeaders _headers = _FakeRespHeaders();

  @override
  int get statusCode => 200;

  @override
  int get contentLength => -1;

  @override
  HttpHeaders get headers {
    _headers.reset(up.responseHeaders);
    return _headers;
  }

  Stream<List<int>> get _source {
    if (up.schedule.isEmpty) return Stream<List<int>>.value(up.body);
    return Stream<List<int>>.fromFutures([
      for (final step in up.schedule)
        Future<List<int>>.delayed(step.$1, () => step.$2),
    ]);
  }

  @override
  Stream<T> map<T>(T Function(List<int> event) convert) =>
      _source.map(convert);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _source.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('假响应没实现 ${invocation.memberName}');
}

class _FakeRespHeaders implements HttpHeaders {
  Map<String, String> _values = const {};

  void reset(Map<String, String> values) => _values = values;

  @override
  String? value(String name) {
    for (final e in _values.entries) {
      if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 起一个**真**中继（`HttpServer.bind` 回环），上游用假 `HttpClient`。
Future<
  ({
    LoopbackRadioStreamRelay relay,
    String url,
    _FakeUpstream up,
    void Function() close,
  })
>
_start({
  required Map<String, String> upstreamHeaders,
  required List<int> body,
  List<(Duration, List<int>)> schedule = const [],
  Duration? timeout,
}) async {
  final up = _FakeUpstream(responseHeaders: upstreamHeaders, body: body);
  up.schedule = schedule;
  final relay = LoopbackRadioStreamRelay(
    client: up,
    timeout: timeout ?? const Duration(seconds: 15),
  );
  // 假上游不许是回环（回环族当上游会被规则拒），用公网字面量即可 ——
  // 真实连接不会发生（`getUrl` 被假客户端接管）。
  final url = await relay.playableUrl('http://50.31.185.139/1005');
  return (
    relay: relay,
    url: url,
    up: up,
    close: () {
      unawaited(relay.close());
    },
  );
}

Future<({int status, Map<String, String> headers, List<int> body})> _get(
  String url, {
  Map<String, String> requestHeaders = const {},
}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    requestHeaders.forEach(req.headers.set);
    final res = await req.close();
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    return (
      status: res.statusCode,
      headers: {
        for (final name in const ['content-type', 'icy-metaint'])
          if (res.headers.value(name) != null) name: res.headers.value(name)!,
      },
      body: bytes,
    );
  } finally {
    client.close(force: true);
  }
}

const List<int> _kOneFrame = [0xFF, 0xFB, 0x92, 0x64, 0x11, 0x11, 0x11, 0x11];

void main() {
  group('仪器64 · icy-metaint 的转发判据（纯函数）', () {
    test('① 只放正整数（原样，去空白）', () {
      expect(icyMetaIntToForward('1024'), '1024');
      expect(icyMetaIntToForward(' 4096 '), '4096');
      expect(icyMetaIntToForward('1'), '1');
    });

    test('① 反向：0 / 负 / 非数字 / 空一律不放行', () {
      // ★ 这条就是"别把 Blues Radio 那类好流拆坏"的判别式
      for (final bad in const ['0', '-1', '-1024', 'abc', '1e3', '1024.0', '', '   ']) {
        expect(
          icyMetaIntToForward(bad),
          isEmpty,
          reason: '「$bad」不是正整数 ⇒ 绝不能声明给播放器',
        );
      }
      expect(icyMetaIntToForward(null), isEmpty);
    });
  });

  group('仪器64 · 真中继端到端（假上游）', () {
    test('② 上游声明 1024 ⇒ 中继带回 1024；字节一字不改；请求头照搬不编造', () async {
      // 形状 = 真站的样子：1024 字节音频 + 1 字节长度 + 16 字节元数据，循环。
      final audio = _mp3Bytes(3); // 1251 字节（>1024，必然跨过一个元数据块）
      final body = <int>[
        ...audio.take(1024),
        1, // 长度字节 = 1 ⇒ 随后 16 字节元数据
        ...List.filled(16, 0x41), // 'A' × 16（元数据）
        ...audio.skip(1024),
      ];
      final s = await _start(
        upstreamHeaders: {'content-type': 'audio/mpeg', 'icy-metaint': '1024'},
        body: body,
      );
      addTearDown(s.close);

      final res = await _get(s.url, requestHeaders: {'Icy-MetaData': '1'});

      // ① 形状声明跟着字节一起过来（这是修复的正面判据）
      expect(res.headers['icy-metaint'], '1024');
      expect(res.headers['content-type'], 'audio/mpeg');
      // ② 字节**一字不改**（含那 1+16 字节元数据 —— 中继不替播放器拆包）
      expect(res.body, body);
      // ③ 请求头是**照搬**：假上游看到的就是客户端发的那一份（规范大小写）
      expect(s.up.seenRequestHeaders.single['Icy-MetaData'], '1');
    });

    test('③ ★ 反向：上游声明 0 ⇒ 不带回该头（好流不被"按 0 字节拆包"拆坏）', () async {
      final audio = _mp3Bytes(4); // 1668 字节纯音频（`Blues Radio` 那类的形状）
      final s = await _start(
        upstreamHeaders: {'content-type': 'audio/mpeg', 'icy-metaint': '0'},
        body: audio,
      );
      addTearDown(s.close);

      final res = await _get(s.url, requestHeaders: {'Icy-MetaData': '1'});

      expect(
        res.headers.containsKey('icy-metaint'),
        isFalse,
        reason: '0 不是"要拆包"的信号，转发过去会毁掉本来就干净的流',
      );
      expect(res.body, audio, reason: '只丢声明，绝不丢字节');
    });

    test('④ ★ 反向：客户端没发 Icy-MetaData ⇒ 假上游也看不到它（不代客户端补齐）', () async {
      final s = await _start(
        upstreamHeaders: {'content-type': 'audio/mpeg'},
        body: _mp3Bytes(2),
      );
      addTearDown(s.close);

      final res = await _get(s.url); // 不带任何请求头

      expect(s.up.seenRequestHeaders.single.containsKey('Icy-MetaData'), isFalse);
      expect(s.up.seenRequestHeaders.single.containsKey('icy-metadata'), isFalse);
      expect(res.status, 200);
      expect(res.headers.containsKey('icy-metaint'), isFalse);
    });

    test('⑤ ★ 反向：上游声明垃圾值 ⇒ 不带回', () async {
      final s = await _start(
        upstreamHeaders: {'content-type': 'audio/mpeg', 'icy-metaint': 'abc'},
        body: _mp3Bytes(1),
      );
      addTearDown(s.close);
      final res = await _get(s.url);
      expect(res.headers.containsKey('icy-metaint'), isFalse);
    });
  });

  group('仪器65 · 直播流不许被"空闲超时"切断（DA44，真机撞到的新缺陷）', () {
    // 真机读数（r394，登记为 **DA44**）：站方连续供流（宿主机 45 s 收 858,151 B、唯一间隔 1.0 s），
    // 而中继每 15.00 s 报一次 `timeout` ⇒ 是**消费者背压**（IOSink 满 → 上游被 pause），
    // 不是站方停流。判据：只有"首字节都不来"才算卡死。
    test('⑦ 上游接了连接但**一个字节都不发** ⇒ 仍要按超时失败（正面）', () async {
      final s = await _start(
        upstreamHeaders: {'content-type': 'audio/mpeg'},
        body: const [],
        schedule: [(const Duration(milliseconds: 600), _kOneFrame)],
        timeout: const Duration(milliseconds: 250),
      );
      addTearDown(s.close);

      // 中继要么回 502（首字节超时），要么把连接断掉 —— 两种都算"没把死连接当过好"
      Object? err;
      List<int> got = const [];
      try {
        final res = await _get(s.url);
        got = res.body;
        if (res.status == 200) {
          err = 'status=200 但一个字节都没有（伪装成"正常空流"）';
        }
      } catch (e) {
        err = e;
      }
      expect(
        err != null || got.isEmpty,
        isTrue,
        reason: '上游一个字节都不发必须被发现，不许当成正常的空响应',
      );
    });

    test('⑧ ★ 反向：先来一段、**之后静默超过超时** ⇒ 不许切断（背压 ≠ 故障）', () async {
      const first = [0xFF, 0xFB, 0x92, 0x64, 0x11, 0x11, 0x11, 0x11];
      const second = [0x22, 0x22, 0x22, 0x22];
      final s = await _start(
        upstreamHeaders: {'content-type': 'audio/mpeg'},
        body: const [],
        // 第一段立刻到；第二段要等 600 ms（> 250 ms 的超时窗口）
        schedule: [
          (Duration.zero, first),
          (const Duration(milliseconds: 600), second),
        ],
        timeout: const Duration(milliseconds: 250),
      );
      addTearDown(s.close);

      final sw = Stopwatch()..start();
      final res = await _get(s.url);
      sw.stop();

      expect(res.status, 200);
      expect(
        res.body,
        [...first, ...second],
        reason: '开流之后的静默可能是背压 —— 这一段必须仍然送到，绝不能被超时切断',
      );
      expect(
        sw.elapsedMilliseconds >= 500,
        isTrue,
        reason: '第二段确实等了 600 ms 才到（证明这条用例真的跨过了超时窗口）',
      );
    });
  });

  group('仪器64 · 回环族收紧（写用例时发现的 SSRF 面）', () {
    test('⑥ 127.0.0.0/8 与整数写法都属于回环 ⇒ 不许当上游、也不绕中继', () {
      for (final u in const [
        'http://127.0.0.1:8899/x',
        'http://127.0.0.2:8899/x',
        'http://127.255.255.254/x',
        'http://localhost/x',
        'http://[::1]/x',
        'http://2130706433/x',
      ]) {
        expect(
          needsCleartextRelay(u),
          isFalse,
          reason: '「$u」是回环 ⇒ 不需要（也不许）绕中继',
        );
        final r = LoopbackRadioStreamRelay.parseRelayRoute(
          path: '/r/abc123',
          query: {'u': u},
          token: 'abc123',
        );
        expect(
          r.target,
          isNull,
          reason: '「$u」是回环 ⇒ 必须拒（否则 token 泄露就能读本机服务）',
        );
        expect(r.error, 'badRequest');
      }
      // 反向：真正的公网明文站仍然要绕、仍然放行
      expect(needsCleartextRelay('http://50.31.185.139/1005'), isTrue);
      final ok = LoopbackRadioStreamRelay.parseRelayRoute(
        path: '/r/abc123',
        query: const {'u': 'http://50.31.185.139/1005'},
        token: 'abc123',
      );
      expect(ok.target.toString(), 'http://50.31.185.139/1005');
    });
  });
}
