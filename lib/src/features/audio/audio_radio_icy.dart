// 电台「这一首在播什么」—— ICY 元数据的**旁路只读探针**（r640 / `DA233`）。
//
// ════════════════════════════════════════════════════════════════════════
// 为什么不是"让播放器把标题读出来"
// ════════════════════════════════════════════════════════════════════════
//
// `audio_radio_relay.dart` 里那条**仪器64**的老账：`icy-metaint` 是"身体依赖它"的头，
// 播放器（Media3）靠它把「N 字节音频 + 1 字节长度 + 16×长度 字节元数据」拆开，
// 只把音频交给解码器。也就是说 **元数据字节确实流过了中继**，但被播放器**按协议丢掉**，
// 没有任何公开回调能把 `StreamTitle` 交给我们（ExoPlayer 的 `IcyDataSource`
// 只在内部用）。硬从播放器里抠标题 = 一次大改，且会把"能播"这条线置于风险中。
//
// 所以这里走**另一条只读的小连接**：自己带 `Icy-MetaData: 1` 去问电台，
// 只读到**第一个元数据块**就断开。代价是一次 `metaint` 量级的字节
// （SHOUTcast 常见 8–16 KB），拿到的却是用户真正想看的那一行 —— 歌名/艺术家。
//
// ★ 三条边界（写清不装神秘）：
//   ① **只读**：GET + 一个请求头；不写、不改、不占用播放链路；
//   ② **有界**：最多读 `metaint + 64 KB` 就放弃，且全程有超时；
//   ③ **失败即沉默**：任何错误返回 `null`，界面只是"这一行不出现"，
//      绝不能因为拿不到标题而影响播放或弹错误。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/audio_handler.dart';

/// 一次探测的结果。
class IcyNowPlaying {
  const IcyNowPlaying({required this.title, this.stationName = ''});

  /// `StreamTitle` 的内容（已 trim；不会为空 —— 空就当没拿到）。
  final String title;

  /// `icy-name`（电台自报的台名；只做日志/兜底，不直接上屏）。
  final String stationName;

  @override
  String toString() => 'IcyNowPlaying(title: $title, station: $stationName)';
}

/// ICY 元数据源（便于宿主用例注入假实现）。
abstract interface class IcyMetadataSource {
  /// 读**第一个**元数据块并返回；没有 / 读不到 / 超时 ⇒ `null`。
  Future<IcyNowPlaying?> probe(Uri streamUrl, {Duration? timeout});
}

/// 真实现：裸 `HttpClient`（与 `IoRadioStreamHttp` 同一套理由 ——
/// Dart 的 socket 不受 Android 明文策略约束，而电台绝大多数是明文 `http`）。
class IoIcyMetadataSource implements IcyMetadataSource {
  IoIcyMetadataSource({HttpClient? client}) : _client = client;

  final HttpClient? _client;

  static const Duration kDefaultTimeout = Duration(seconds: 8);

  /// 读多少就放弃：`metaint` 之后最多再读这么多（防"永远不插元数据"的站）。
  static const int kMaxBytesAfterMeta = 64 * 1024;

  static const String kUserAgent =
      'synhub/1.0 (Android; internet radio now-playing probe)';

  @override
  Future<IcyNowPlaying?> probe(Uri streamUrl, {Duration? timeout}) async {
    final limit = timeout ?? kDefaultTimeout;
    if (!streamUrl.hasScheme ||
        (streamUrl.scheme != 'http' && streamUrl.scheme != 'https')) {
      return null;
    }
    final client = _client ?? (HttpClient()..connectionTimeout = limit);
    try {
      final req = await client.getUrl(streamUrl).timeout(limit);
      req.headers.set('Icy-MetaData', '1');
      req.headers.set(HttpHeaders.userAgentHeader, kUserAgent);
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final res = await req.close().timeout(limit);
      // 只要第一个块：`_readFirstTitle` 内部已取消订阅，连接由
      // `client.close(force: true)` 收掉（不 drain —— drain 会一直读到流结束，
      // 等于把一条直播流整条拉下来，正好是要避免的事）。
      {
        if (res.statusCode != HttpStatus.ok) return null;
        final stationName = (res.headers.value('icy-name') ?? '').trim();
        final metaInt = int.tryParse((res.headers.value('icy-metaint') ?? '').trim());
        if (metaInt == null || metaInt <= 0) {
          // 这个站不插元数据（或明确说 `0`）⇒ 没有曲目可显示，别硬等。
          debugPrint(
            '[audio-radio-icy] no-metaint url=$streamUrl '
            'name=${stationName.isEmpty ? '-' : stationName}',
          );
          return null;
        }
        final parsed = await _readFirstTitle(
          res.cast<List<int>>(),
          metaInt: metaInt,
          limit: limit,
          maxBytes: metaInt + kMaxBytesAfterMeta,
        );
        debugPrint(
          '[audio-radio-icy] url=$streamUrl metaint=$metaInt '
          'title=${parsed ?? "-"} name=${stationName.isEmpty ? '-' : stationName}',
        );
        if (parsed == null) return null;
        return IcyNowPlaying(title: parsed, stationName: stationName);
      }
    } on TimeoutException {
      debugPrint('[audio-radio-icy] timeout url=$streamUrl');
      return null;
    } catch (e) {
      debugPrint('[audio-radio-icy] failed url=$streamUrl err=$e');
      return null;
    } finally {
      if (_client == null) client.close(force: true);
    }
  }

  /// 从字节流里按 ICY 分块规则取出第一个**非空** `StreamTitle`。
  ///
  /// 规则：读 `metaInt` 字节音频 → 1 字节 `k` → 读 `k*16` 字节元数据
  /// （`k == 0` 表示"这一轮没有元数据"，继续下一轮）。
  Future<String?> _readFirstTitle(
    Stream<List<int>> body, {
    required int metaInt,
    required Duration limit,
    required int maxBytes,
  }) async {
    var audioLeft = metaInt;
    var metaLeft = -1;
    final meta = <int>[];
    var total = 0;
    final done = Completer<String?>();
    late final StreamSubscription<List<int>> sub;
    final timer = Timer(limit, () {
      if (!done.isCompleted) done.complete(null);
    });
    sub = body.listen(
      (chunk) {
        total += chunk.length;
        var i = 0;
        while (i < chunk.length) {
          if (metaLeft < 0) {
            final take = min(audioLeft, chunk.length - i);
            i += take;
            audioLeft -= take;
            if (audioLeft > 0) continue;
            // 下一次要读长度字节
            if (i >= chunk.length) break;
            metaLeft = chunk[i] * 16;
            i++;
            meta.clear();
            if (metaLeft == 0) {
              audioLeft = metaInt;
              metaLeft = -1;
            }
            continue;
          }
          final take = min(metaLeft - meta.length, chunk.length - i);
          meta.addAll(chunk.sublist(i, i + take));
          i += take;
          if (meta.length >= metaLeft) {
            final title = _titleFromMeta(meta);
            if (title != null) {
              if (!done.isCompleted) done.complete(title);
              return;
            }
            // 这一块是空元数据（很多站会插 `k=0` 或空 StreamTitle）⇒ 继续
            audioLeft = metaInt;
            metaLeft = -1;
          }
        }
        if (total > maxBytes && !done.isCompleted) done.complete(null);
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete(null);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(null);
      },
      cancelOnError: true,
    );
    final result = await done.future;
    timer.cancel();
    await sub.cancel();
    return result;
  }

  /// 元数据块里的 `StreamTitle='…'`（Icecast/SHOUTcast 都是这个形状）。
  static final RegExp _titleApos = RegExp(r"StreamTitle='([^']*)'");
  static final RegExp _titleQuote = RegExp(r'StreamTitle="([^"]*)"');

  static String? _titleFromMeta(List<int> bytes) {
    if (bytes.isEmpty) return null;
    // 块尾用 NUL 填充
    var end = bytes.length;
    while (end > 0 && bytes[end - 1] == 0) {
      end--;
    }
    if (end == 0) return null;
    final text = utf8.decode(bytes.sublist(0, end), allowMalformed: true);
    final m = _titleApos.firstMatch(text) ?? _titleQuote.firstMatch(text);
    final raw = (m?.group(1) ?? '').trim();
    return raw.isEmpty ? null : raw;
  }
}

/// 一次探测的结果（**供界面读的**状态）。
class RadioNowPlaying {
  const RadioNowPlaying({this.mediaId, this.title});

  /// 这条曲目对应的 `MediaItem.id` —— 界面**必须**拿它跟自己正在显示的那条比。
  ///
  /// 为什么钉 id 而不是"最后点过的电台"：电台页的播放条会显示**任何**在播的东西
  /// （包括在别的页面点的歌）⇒ 只按"最后点过"显示，会把上一个电台的歌名
  /// 挂到一首歌下面（自相矛盾）。
  final String? mediaId;

  /// 正在播的曲目（拿不到就是 `null` —— 界面不出现这一行）。
  final String? title;

  bool matches(String? id) => id != null && id == mediaId && title != null;
}

/// 轮询控制器：**只**为"正在播的那一个电台"跑一条小探针。
///
/// * `start(id, url)`：换台/重播时调用（同一条 url 重复调用不会重连）；
/// * `stop()`：停止轮询并清空（停止播放、关闭电台面板时调用）；
/// * 每次探测前先看一眼"当前在播的还是不是这条"（`handler.currentMediaId`）——
///   用户在别的页面切了歌，这里会**自己停**，不会留着一条过期歌名。
class RadioNowPlayingController extends Notifier<RadioNowPlaying> {
  /// 轮询间隔：电台换歌通常是分钟级；20 s 足够跟上，又不会太费流量。
  static const Duration kPollInterval = Duration(seconds: 20);

  String? _url;
  Timer? _timer;
  Timer? _retry;
  bool _inFlight = false;

  /// 面板"在看着"（开过且还没关）。
  ///
  /// 为什么需要它：面板可能在**起播成功之前**就打开了 —— 真机路径正是
  /// 「离线点台 → 失败 → 打开面板 → 恢复网络 → 面板里点重试 → 成功」。
  /// 那时 `resumePolling()` 还没有 `_url`（`start()` 只在成功后才调），
  /// 于是轮询根本没起来 ⇒ 面板已经开着却要等关掉再开才显示在播曲目。
  /// 记住这个意愿，`start()` 后立刻补上（r641）。
  bool _wantPolling = false;

  /// 一首歌都没拿到时的"快重试"次数（最多 [kFastRetries] 次）。
  ///
  /// 为什么需要它：有的站**首块元数据是空的**（广告/换歌瞬间），要等下一轮才给标题。
  /// 光靠 20 s 轮询，用户第一眼看到的是"没有这一行"，过 20 s 才补上 —— 太慢。
  static const int kFastRetries = 3;
  static const Duration kFastRetryDelay = Duration(seconds: 6);
  int _fastRetried = 0;

  @override
  RadioNowPlaying build() {
    ref.onDispose(_cancel);
    return const RadioNowPlaying();
  }

  /// 开始（或切换到）某个电台。
  void start(String mediaId, String streamUrl) {
    if (streamUrl.isEmpty) return;
    if (_url == streamUrl && state.mediaId == mediaId) return;
    _url = streamUrl;
    _cancel();
    // 同一条电台重播时**保留上一次的歌名**（否则会先闪一下空白再出现）
    final keep = state.mediaId == mediaId ? state.title : null;
    state = RadioNowPlaying(mediaId: mediaId, title: keep);
    _fastRetried = 0;
    // ★ 不在 `start()` 里连网：**只有面板打开时才去问**（见 [resumePolling]）。
    //   理由两条：① 用户没打开面板时这一行字根本看不见 ⇒ 不为它耗流量；
    //   ② 起播路径不该被一个"可选装饰"的 IO 拖住。
    _cancel();
    // 面板已经在看着（常见于"失败了 → 面板里重试成功"）⇒ 现在补起轮询。
    if (_wantPolling) {
      _timer = Timer.periodic(kPollInterval, (_) => _probeOnce());
      _probeOnce();
    }
  }

  /// 面板打开时开始轮询（幂等）：立刻探一次，之后每 [kPollInterval] 一次。
  void resumePolling() {
    _wantPolling = true;
    if (_url == null || state.mediaId == null) return;
    _timer ??= Timer.periodic(kPollInterval, (_) => _probeOnce());
    _probeOnce();
  }

  /// 面板关闭时暂停轮询（**不清状态**：再打开时先把上次的歌名显示出来）。
  void pausePolling() {
    _wantPolling = false;
    _cancel();
  }

  /// 停止轮询（停止播放 / 关闭播放条）。
  void stop() {
    _url = null;
    _wantPolling = false;
    _cancel();
    if (state.mediaId != null || state.title != null) {
      state = const RadioNowPlaying();
    }
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _retry?.cancel();
    _retry = null;
  }

  Future<void> _probeOnce() async {
    final url = _url;
    final id = state.mediaId;
    if (url == null || id == null || _inFlight) return;
    // 还在播这一条吗？（换歌 / 停止后不再为它耗流量）
    final handler = ref.read(audioHandlerProvider);
    if (handler.currentMediaId != id) {
      stop();
      return;
    }
    _inFlight = true;
    try {
      final source = ref.read(icyMetadataSourceProvider);
      final got = await source.probe(Uri.parse(url));
      if (!ref.mounted) return;
      if (_url != url || state.mediaId != id) return;
      // 拿不到就**保持原样**（不要清掉上一次的歌名 —— 电台换歌时会短暂拿不到，
      // 清掉会让界面上那行闪一下消失再出现）。
      if (got == null) {
        // 还没有任何歌名时，别干等 20 s：快速补几次
        if (state.title == null && _fastRetried < kFastRetries) {
          _fastRetried++;
          _retry?.cancel();
          _retry = Timer(kFastRetryDelay, _probeOnce);
        }
        return;
      }
      _fastRetried = 0;
      if (state.title == got.title) return;
      state = RadioNowPlaying(mediaId: id, title: got.title);
    } catch (_) {
      // 探针失败 = 少一行字，绝不影响播放
    } finally {
      _inFlight = false;
    }
  }
}

/// 探针实现（宿主机用例覆盖成假实现）。
final icyMetadataSourceProvider = Provider<IcyMetadataSource>(
  (ref) => IoIcyMetadataSource(),
);

/// 电台「正在播的曲目」全局状态（跨页面/面板共享）。
final radioNowPlayingProvider =
    NotifierProvider<RadioNowPlayingController, RadioNowPlaying>(
      RadioNowPlayingController.new,
    );
