// Office 模板**缩略图**：官方 `SYNO.Office.Template.Thumb:get` 的字节通道
// + 三层缓存（内存 LRU / 磁盘 / 失败记忆）+ 懒加载卡片。
//
// 真机契约（`docs/office-template-gallery.md` §2.2，第 260 轮实测）：
//   * `SYNO.Office.Template.Thumb` v1 只有 `get`，`allowDownload:true`
//     ⇒ 回的是 **PNG 字节**（不是 JSON 信封）；
//   * 参数 `object_id` + `ver` + `retina`（`false`→1x、`true`→2x，真机 2x 384×216）；
//   * 因此必须走 `DsmWebApi.getBytes`，走 `api.call` 会解不出。
//
// 为什么把它单独放一个文件（而不是塞进 `office_library.dart`）：
//   * 缓存要能被 `office_library_test.dart` / 预览页**注入**（离线测试不碰网络）；
//   * 与 `office_doc_image.dart` 的 `OfficeDocImageCache` 同套路：读盘失败**不打扰
//     用户**、单测（无 path_provider 通道）自动降级成"只用内存"。
//
// 设计取舍（对齐官方 `ui.doc.js` 的 `onLoadItem`）：
//   * **懒加载**：`OfficeTemplateThumbnail` 只在卡片**被 build**（= 进入视口/
//     预取区）时才发起取图；`SliverGrid` 的 builder 天然保证这一点；
//   * **失败记忆**：同一个 key 失败后不再每次滚动重打网络（记住当时的错误，
//     直到用户主动 `invalidate`）；
//   * **占位尺寸稳定**：加载态用官方骨架底色 `#e2e6ea` 铺满卡片预留框，
//     所以图片到达时**不会跳动**。
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 取一张模板缩略图的字节。
///
/// 生产实现是 `OfficeApi.templateThumbBytes`；测试注入假实现即可离线跑。
typedef OfficeTemplateThumbFetcher =
    Future<Uint8List> Function({
      required String objectId,
      String? ver,
      required bool retina,
    });

/// 官方骨架 / 占位底色（`ui/dist/doc.css` 的缩略图加载态 `#e2e6ea`）。
const Color kOfficeTemplateThumbSkeleton = Color(0xFFE2E6EA);

/// 模板缩略图缓存：**内存 LRU + 磁盘 + 失败记忆**，key = `objectId|ver|retina`。
class OfficeTemplateThumbCache {
  OfficeTemplateThumbCache({
    this.memoryCapacity = 64,
    Future<Directory?> Function()? diskRoot,
  }) : _diskRoot = diskRoot;

  /// 内存里最多缓存几张（LRU 淘汰最久未用）。
  final int memoryCapacity;

  /// 磁盘根目录解析器；null = 用 `path_provider` 的应用缓存目录。
  final Future<Directory?> Function()? _diskRoot;

  final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();
  final Map<String, Future<Uint8List>> _inflight = {};

  /// 失败记忆：key → 当时的错误。命中时**直接重抛，不再发网络**。
  final Map<String, Object> _failed = {};

  /// 缓存 key（含 `retina`，1x/2x 各存一份）。
  static String keyOf(String objectId, String? ver, bool retina) =>
      '$objectId|${ver ?? ''}|${retina ? '2x' : '1x'}';

  /// 当前内存缓存里的 key（测试断言 LRU / 命中用）。
  Iterable<String> get memoryKeys => _memory.keys;

  /// 已被记住失败的 key。
  Iterable<String> get failedKeys => _failed.keys;

  /// 加载：内存命中 → 直接返回；失败记忆命中 → 重抛（不发网络）；
  /// 否则磁盘命中 → 返回；再否则 [fetch] 并发去重取图并落内存+磁盘。
  Future<Uint8List> load(String key, Future<Uint8List> Function() fetch) {
    final cached = _memory[key];
    if (cached != null) {
      _touch(key, cached);
      return Future<Uint8List>.value(cached);
    }
    final failure = _failed[key];
    if (failure != null) {
      // ★ 失败记忆：滚动回到这张卡片时不要再打一次网络。
      return Future<Uint8List>.error(failure);
    }
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = _loadDiskElseFetch(key, fetch);
    _inflight[key] = future;
    future.then<void>(
      (_) {
        _inflight.remove(key);
      },
      onError: (Object _) {
        _inflight.remove(key);
      },
    );
    return future;
  }

  Future<Uint8List> _loadDiskElseFetch(
    String key,
    Future<Uint8List> Function() fetch,
  ) async {
    final path = await _diskPath(key, create: false);
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            _touch(key, bytes);
            return bytes;
          }
        }
      } catch (_) {
        // 读盘失败（坏文件/权限）→ 当作没缓存，回落网络，不打扰用户。
      }
    }
    try {
      final bytes = await fetch();
      _touch(key, bytes);
      await _writeDisk(key, bytes);
      _failed.remove(key);
      return bytes;
    } catch (e) {
      // ★ 记住失败：下次命中这个 key 直接重抛，不再发网络。
      _failed[key] = e;
      rethrow;
    }
  }

  void _touch(String key, Uint8List bytes) {
    _memory.remove(key);
    _memory[key] = bytes;
    while (_memory.length > memoryCapacity) {
      _memory.remove(_memory.keys.first);
    }
  }

  /// 清掉一个 key 的缓存与失败记忆（预览"重试"/会话切换后重取）。
  void invalidate(String key) {
    _memory.remove(key);
    _failed.remove(key);
  }

  /// 清空全部（登出 / 切换会话时用，避免把上一台 NAS 的图留给下一台）。
  void clear() {
    _memory.clear();
    _failed.clear();
    _inflight.clear();
  }

  Future<void> _writeDisk(String key, Uint8List bytes) async {
    try {
      final path = await _diskPath(key, create: true);
      if (path == null) return;
      await File(path).writeAsBytes(bytes, flush: false);
    } catch (_) {
      // 写盘失败不影响本次显示。
    }
  }

  Future<String?> _diskPath(String key, {required bool create}) async {
    try {
      Directory? root;
      final resolver = _diskRoot;
      if (resolver != null) {
        root = await resolver();
      } else {
        try {
          root = await getApplicationCacheDirectory();
        } catch (_) {
          root = null; // 单测 / 无平台通道 → 只用内存
        }
      }
      if (root == null) return null;
      final dir = Directory('${root.path}/office_template_thumbs');
      if (create && !await dir.exists()) {
        await dir.create(recursive: true);
      }
      // base64url 是确定性的、文件系统安全的，且不会撞名。
      final name = base64Url.encode(utf8.encode(key));
      return '${dir.path}/$name';
    } catch (_) {
      return null;
    }
  }
}

/// 进程级默认缩略图缓存（网格与预览页共享；测试可注入自己的实例）。
final OfficeTemplateThumbCache officeTemplateThumbCache =
    OfficeTemplateThumbCache();

/// 一张模板缩略图（卡片 / 预览大图共用）。
///
/// * 懒加载：只有被 build（进入视口）的卡片才会取图；
/// * 加载态 = 官方骨架底色 `#e2e6ea` 铺满预留框 ⇒ 图片到达**不跳动**；
/// * 失败态 = 同一底色 + 破图图标（**不弹错误码**、不提供假重试），
///   且失败被 [OfficeTemplateThumbCache] 记住，滚动回来不再打网络；
/// * [fetcher] 为 null（未连接 / 单测没注入）时**不发任何请求**，直接占位。
class OfficeTemplateThumbnail extends StatefulWidget {
  const OfficeTemplateThumbnail({
    super.key,
    required this.objectId,
    this.ver,
    this.retina = true,
    this.fetcher,
    this.cache,
    this.iconSize,
    this.semanticLabel,
  });

  final String objectId;
  final String? ver;

  /// true = 2x（官方 retina；真机 384×216）。卡片与预览都用 2x，
  /// 高清屏下不糊，且单张仅 ~9 KB。
  final bool retina;
  final OfficeTemplateThumbFetcher? fetcher;
  final OfficeTemplateThumbCache? cache;
  final double? iconSize;

  /// 无障碍标签（本地化标题，**不显示 object_id**）。
  final String? semanticLabel;

  @override
  State<OfficeTemplateThumbnail> createState() =>
      _OfficeTemplateThumbnailState();
}

class _OfficeTemplateThumbnailState extends State<OfficeTemplateThumbnail> {
  Future<Uint8List>? _future;

  OfficeTemplateThumbCache get _cache =>
      widget.cache ?? officeTemplateThumbCache;

  String get _cacheKey =>
      OfficeTemplateThumbCache.keyOf(widget.objectId, widget.ver, widget.retina);

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(OfficeTemplateThumbnail old) {
    super.didUpdateWidget(old);
    if (old.objectId != widget.objectId ||
        old.ver != widget.ver ||
        old.retina != widget.retina) {
      _start();
    }
  }

  void _start() {
    final fetcher = widget.fetcher;
    if (fetcher == null || widget.objectId.isEmpty) {
      _future = null;
      return;
    }
    final future = _cache.load(
      _cacheKey,
      () => fetcher(
        objectId: widget.objectId,
        ver: widget.ver,
        retina: widget.retina,
      ),
    );
    _future = future;
    // ★ 静默降级必须能说出原因（AGENTS §2.0.17 ②）：失败进日志（release 包
    // 也进 logcat，tag `flutter`）。用 `then(onError:)` 而不是 `catchError`
    // 是为了"消费掉"这个错误副本，不给测试/Zone 留一个未处理的 future。
    future.then<void>(
      (_) {},
      onError: (Object e) {
        debugPrint(
          '[officeTemplateThumb] FAIL key=$_cacheKey reason=$e',
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final future = _future;
    if (future == null) {
      return _placeholder(const Key('office-template-thumb-missing'), null);
    }
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return _placeholder(
            Key('office-template-thumb-failed-${widget.objectId}'),
            Icons.image_not_supported_outlined,
          );
        }
        final bytes = snap.data;
        if (bytes == null) {
          return _placeholder(
            Key('office-template-thumb-loading-${widget.objectId}'),
            Icons.image_outlined,
          );
        }
        return Image.memory(
          bytes,
          key: Key('office-template-thumb-${widget.objectId}'),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          semanticLabel: widget.semanticLabel,
          errorBuilder: (context, error, stack) => _placeholder(
            Key('office-template-thumb-failed-${widget.objectId}'),
            Icons.image_not_supported_outlined,
          ),
        );
      },
    );
  }

  Widget _placeholder(Key key, IconData? icon) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: key,
      color: kOfficeTemplateThumbSkeleton,
      alignment: Alignment.center,
      child: icon == null
          ? null
          : Icon(
              icon,
              size: widget.iconSize ?? 28,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
    );
  }
}
