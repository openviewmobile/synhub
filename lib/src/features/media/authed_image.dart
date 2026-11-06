// NAS 直链图片的**唯一**取图通道（DA86，2026-10-16 真机取证后新建）。
//
// 为什么不能再用 `Image.network`：
//   `Image.network` 走的是 Dart 自带的 `HttpClient` —— 它既不带 `DioFactory`
//   的信任库，也不接受"证书有效但主机名不匹配"的直链。真机现场
//   （HONOR LGE-AN10，`docs/evidence-r427/`）：
//     * 设备按 **IP** 连 NAS：`nas.example.com:5001`（`/proc/net/tcp` 实证）；
//     * 证书是**有效的 Let's Encrypt**，但 `SAN = *.nas.example.com`
//       ⇒ `openssl s_client -verify_hostname nas.example.com` → **verify error 62
//       hostname mismatch**；
//     * `Image.network` 因此握手失败 → `errorBuilder` → 一路静默退到图标占位
//       （真机像素：歌曲行 leading 是音符图标，而 `getsongcover` 明明回
//       55,253 B 真 JPEG）。
//   这和第 259/319 轮 chat / Photos 的结论是同一条：**凡是 NAS 直链图片，
//   都必须走应用自己的鉴权字节通道**（`api.getBytes` = Dio + TrustStore + `_sid`），
//   再 `Image.memory`。所以这里把"取字节"抽成一个可注入 loader 的小部件，
//   让音频封面 / Drive 直链缩略图共用**一个实现**（§2.0.8 ④）。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 取一个直链的字节。返回值可以是空（当作失败，走 [AuthedImage.fallback]）。
///
/// 刻意收 `Future<List<int>>`（而不是 `Uint8List`）：这样各 API 的
/// `getBytes`（`DsmWebApi.getBytes`，带一堆可选命名参数）可以**直接 tear-off**
/// 传进来，调用点不必每处写一层 lambda（§2.0.8 ④ 一个实现）。
typedef ImageBytesLoader = Future<List<int>> Function(String url);

/// 已取到的图片字节（会话级内存缓存）。
///
/// 列表滚动会把行重建、`State` 重来，没有缓存就会对同一张封面反复
/// 走一次 NAS 往返。只缓存**成功**的字节（失败不缓存，下次仍可恢复），
/// 上限 [capacity] 条、按插入顺序淘汰（封面单张 ≤ 100 KB，够用）。
class AuthedImageCache {
  AuthedImageCache._();

  static final Map<String, Uint8List> _entries = <String, Uint8List>{};
  static int capacity = 64;

  static Uint8List? get(String key) => _entries[key];

  static void put(String key, Uint8List bytes) {
    if (bytes.isEmpty) return;
    _entries.remove(key);
    _entries[key] = bytes;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  static int get length => _entries.length;

  /// 计数字段（用例断言"同一 URL 只取一次"）
  static int hits = 0;
  static int misses = 0;

  /// ★ r652（**DA252**）：**在途请求合并**（single-flight）的计数器。
  ///
  /// `hits` 只覆盖"已经取完的字节"，**覆盖不到在途**：一屏 17 行 + 专辑网格 +
  /// 迷你条一起挂上来时，同一个 `identity|url` 会在第一张图回来之前各发一次
  /// `getBytes` —— 真机上就是同一张封面打好几次 NAS。
  static int joins = 0;

  static final Map<String, Future<Uint8List?>> _inflight =
      <String, Future<Uint8List?>>{};

  /// 同一个 key 只允许一个在途请求：有就**搭车**，没有才真的跑 [loader]。
  ///
  /// 语义：
  ///   * 命中已完成缓存 → 直接给值（`hits++`，不跑 loader）；
  ///   * 有在途 → 返回同一个 future（`joins++`，不跑 loader）；
  ///   * 都没有 → 跑 loader（`misses++`），完成后写缓存并从在途表里摘掉
  ///     （失败也摘 —— 下次重进还会再试一次，并受调用方的失败记忆约束）。
  static Future<Uint8List?> obtain(
    String key,
    Future<Uint8List> Function() loader,
  ) {
    final cached = get(key);
    if (cached != null) {
      hits++;
      return Future<Uint8List?>.value(cached);
    }
    final pending = _inflight[key];
    if (pending != null) {
      joins++;
      return pending;
    }
    misses++;
    final future = loader().then<Uint8List?>((bytes) {
      if (bytes.isEmpty || !_looksLikeImage(bytes)) return null;
      put(key, bytes);
      return bytes;
    }).catchError((Object _) => null);
    _inflight[key] = future;
    unawaited(future.whenComplete(() => _inflight.remove(key)));
    return future;
  }

  /// 用例用：当前在途条数（生产代码不读）
  @visibleForTesting
  static int get inflight => _inflight.length;

  /// 用例用：清空（生产代码不调用）
  @visibleForTesting
  static void reset() {
    _entries.clear();
    _inflight.clear();
    hits = 0;
    misses = 0;
    joins = 0;
  }
}

/// 走鉴权字节通道的图片：加载中/失败都显示 [fallback]，成功换 [Image.memory]。
///
/// 刻意保持"没有 url 就不建 future"的同步分支，UI 首帧不会闪 loading。
class AuthedImage extends StatefulWidget {
  const AuthedImage({
    super.key,
    required this.url,
    required this.load,
    required this.fallback,
    this.identity,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.onFailed,
  });

  /// 直链（空 = 没有可用的图 → 直接 [fallback]）。
  final String? url;

  /// 取字节（通常是 `api.getBytes`）。
  final ImageBytesLoader load;

  /// 拿不到图时显示什么（图标/骨架都行）。
  final Widget fallback;

  /// 内容身份：变了就重新取（默认用 [url]）。
  final String? identity;

  final double? width;
  final double? height;
  final BoxFit fit;

  /// 取不到图（空/不是图/抛错）时回调一次（r439：专辑封面据此换"逐首探"拿到的 URL）。
  ///
  /// 只在**真的失败**时回调：`url` 为空（同步分支）不算失败，加载中也**不**回调。
  final VoidCallback? onFailed;

  @override
  State<AuthedImage> createState() => _AuthedImageState();
}

/// 这批字节看起来是图片吗（只看魔数）。
///
/// 为什么要它：服务端"没这张图"时回的是 **404 + HTML 正文**，而 `getBytes`
/// 在 404 上直接抛异常（实测 `DsmTransportException(HTTP 404, …)`）—— 但
/// HTTP 200 却带 HTML 的中间态在历史上出现过（`Chat`/`Photos` 的取证里都有）。
/// 与其把一段 HTML 交给 `Image.memory` 去解码（白白产生一条解码异常日志），
/// 不如在这里判定"不是图" ⇒ 走 fallback。
bool _looksLikeImage(List<int> b) {
  if (b.length < 12) return false;
  if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true; // JPEG
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return true; // PNG
  }
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true; // GIF
  if (b[0] == 0x42 && b[1] == 0x4D) return true; // BMP
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    return true; // RIFF....WEBP
  }
  return false;
}

class _AuthedImageState extends State<AuthedImage> {
  Future<Uint8List?>? _pending;

  /// 当前 pending 对应的 key（url + identity）
  String? _key;

  /// 本轮 pending 是否已经报过失败（同一轮只报一次，避免 build 反复回调）
  bool _failedNotified = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(AuthedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.identity != widget.identity) {
      _start();
    }
  }

  void _start() {
    final url = widget.url;
    final key = '${widget.identity ?? ''}|${url ?? ''}';
    _key = key;
    _failedNotified = false;
    if (url == null || url.isEmpty) {
      _pending = null;
      return;
    }
    // 缓存命中 / 在途搭车 / 真发一次 —— 全部交给缓存层（`DA252`）：
    // 同一个 `identity|url` 在**第一张图回来之前**也只发一次 `getBytes`。
    _pending = AuthedImageCache.obtain(key, () async {
      final bytes = await widget.load(url);
      return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    if (pending == null) return widget.fallback;
    return FutureBuilder<Uint8List?>(
      key: ValueKey<String?>(_key),
      future: pending,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) {
          // 已经"跑完但没图" ⇒ 才算失败（加载中不报，保持原有"图标先出"的观感）
          if (snap.connectionState == ConnectionState.done &&
              widget.onFailed != null &&
              !_failedNotified) {
            _failedNotified = true;
            final notify = widget.onFailed!;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) notify();
            });
          }
          return widget.fallback;
        }
        return Image.memory(
          bytes,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => widget.fallback,
        );
      },
    );
  }
}
