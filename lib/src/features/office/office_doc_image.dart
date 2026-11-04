// Office 文档里的图片 —— 从"数据里的附件引用"变成"用户看见的图片"。
//
// 为什么需要这个文件（用户投诉的根因，取证见
// `docs/office-doc-render-design.md` §2 / §4）：
//   * 真实文档里的图片不是 URL：`picture` 节点把引用放在
//     `attrs.config.file_id`（32 hex），`src` 在真实文档里出现 **0 次**；
//   * 字节通道是 `SYNO.Office.Node.Attachment:get` **v2**，且
//     `object_id` + `file_id` **必须同时给**（只给 file_id → 404）；
//   * 之前的渲染器既没留下 `Snapshot:get` 的 `object_id`，也没封装这条通道，
//     于是用户看到的是"附件路径"或一片空白。
//
// 本文件的契约：
//   1. **三态**：加载骨架 → 图片 → 失败态（"图片加载失败" + 原因分类 + 重试）；
//   2. **排版**：应用 `width`/`height`（px→逻辑像素）、`crop`、`deg`、
//      `flip_h`/`flip_v`、`alignment`；
//   3. **无障碍与失败文案**用 `alt`/`file_alt`（原文件名）；
//      **绝不把 `file_id`/`ref`/路径显示给用户**（内部标识只用于取数据）；
//   4. **缓存**：内存 LRU + 磁盘缓存，key = `objectId/fileId`；
//      同一 key 第二次取**不再发 HTTP**（离线用例断言提供者只被调用一次）；
//   5. **可注入**：[provider] 允许离线测试注入真实 PNG 字节；
//      [cache] 允许注入临时目录/内存缓存。
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme/app_tokens.dart';
import '../../data/office_api.dart'
    show OfficeAttachmentErrorKind, OfficeAttachmentException;
import 'office_write_gate.dart' show officeDocText;

/// 取一张文档图片的字节。
///
/// [objectId] 来自 `Snapshot:get` 回包的 `data.object_id`；
/// [fileId] 来自 `picture.attrs.config.file_id`（或 `image.attrs.file_id`）。
/// 生产实现是 `OfficeApi.attachmentGet`；测试注入假提供者即可离线跑。
typedef OfficeAttachmentBytesProvider =
    Future<Uint8List> Function({
      required String objectId,
      required String fileId,
    });

/// 图片缓存：**内存 LRU + 磁盘**，key = `objectId/fileId`。
///
/// * 内存：最近用的 [memoryCapacity] 张留在 [LinkedHashMap] 里（访问即提升）；
/// * 磁盘：`<cache>/office_doc_images/<base64(key)>`，进程重启后仍命中；
/// * [diskRoot] 为 null 时走 `path_provider`；**解析失败（单测/无平台通道）
///   自动降级成"只用内存"**，绝不因为缓存不可用而让图片加载失败。
class OfficeDocImageCache {
  OfficeDocImageCache({
    this.memoryCapacity = 24,
    Future<Directory?> Function()? diskRoot,
  }) : _diskRoot = diskRoot;

  /// 内存里最多缓存几张（LRU 淘汰最久未用）。
  final int memoryCapacity;

  /// 磁盘根目录解析器；null = 用 `path_provider` 的应用缓存目录。
  final Future<Directory?> Function()? _diskRoot;

  final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();
  final Map<String, Future<Uint8List>> _inflight = {};

  /// 缓存 key：`objectId/fileId`（与取证文档一致，便于日志核对）。
  static String keyOf(String objectId, String fileId) => '$objectId/$fileId';

  /// 当前内存缓存里的 key（测试断言 LRU 用）。
  Iterable<String> get memoryKeys => _memory.keys;

  /// 同一 key 多个组件同时加载时**只发一次**：进行中的 Future 直接复用。
  Future<Uint8List> load(String key, Future<Uint8List> Function() fetch) {
    final cached = _memory[key];
    if (cached != null) {
      putMemory(key, cached); // 命中即提升（LRU touch）
      return Future<Uint8List>.value(cached);
    }
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = _loadDiskElseFetch(key, fetch);
    _inflight[key] = future;
    // 无论成败都清掉"进行中"标记。
    // ⚠️ 必须用**块体**：`Map.remove` 会返回被移除的那个失败 Future，
    // 若把它当作 onError 的返回值，`then` 的结果 Future 会继承同一个错误
    // → 变成"没人处理的异步错误"，Widget 测试直接判红。
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

  /// 放进内存 LRU（超过容量淘汰最久未用的）。
  void putMemory(String key, Uint8List bytes) {
    _memory.remove(key);
    _memory[key] = bytes;
    while (_memory.length > memoryCapacity) {
      _memory.remove(_memory.keys.first);
    }
  }

  /// 失效一个 key（"重试"按钮用：下次必然重新取字节）。
  void evict(String key) => _memory.remove(key);

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
            putMemory(key, bytes);
            return bytes;
          }
        }
      } catch (_) {
        // 读盘失败（坏文件/权限）→ 当作没缓存，回落网络，不打扰用户。
      }
    }
    final bytes = await fetch();
    putMemory(key, bytes);
    await _writeDisk(key, bytes);
    return bytes;
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
      final dir = Directory('${root.path}/office_doc_images');
      if (create && !await dir.exists()) {
        await dir.create(recursive: true);
      }
      // base64url(key) 是确定性的、文件系统安全的，且不会撞名。
      final name = base64Url.encode(utf8.encode(key));
      return '${dir.path}/$name';
    } catch (_) {
      return null;
    }
  }
}

/// 进程级默认图片缓存（页面之间共享；测试可注入自己的实例）。
final OfficeDocImageCache officeDocImageCache = OfficeDocImageCache();

/// `picture.config.alignment` / `image` 的段落对齐。
enum OfficeDocImageAlignment { inline, left, center, right }

/// 把 `alignment` 字符串归一（不认识的一律当 inline，**不报错、不上屏**）。
OfficeDocImageAlignment officeDocImageAlignmentFrom(Object? value) =>
    switch ('$value'.trim().toLowerCase()) {
      'left' => OfficeDocImageAlignment.left,
      'center' || 'centre' || 'middle' => OfficeDocImageAlignment.center,
      'right' => OfficeDocImageAlignment.right,
      _ => OfficeDocImageAlignment.inline,
    };

/// `picture.config.crop` → 归一化的 `{l,t,r,b}`（0..1，坏值当 0）。
class OfficeDocImageCrop {
  const OfficeDocImageCrop({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  /// 全都是 0 = 不裁切。
  bool get isIdentity => left == 0 && top == 0 && right == 0 && bottom == 0;

  /// 裁完之后**可见部分**占原图的比例（留 1% 下限，避免除零/翻转）。
  double get visibleWidth => (1 - left - right).clamp(0.01, 1.0);
  double get visibleHeight => (1 - top - bottom).clamp(0.01, 1.0);

  /// Flutter `Alignment`：`-1` 左 / `1` 右，`-1` 上 / `1` 下。
  ///
  /// 裁切窗口中心在源图的比例是 `(l + (1-r))/2`，换算成 Alignment 就是
  /// `l - r`（纵向同理 `t - b`）。
  Alignment get alignment => Alignment(left - right, top - bottom);

  /// 放大倍数：把可见区域铺满原尺寸的框。
  double get scaleX => 1 / visibleWidth;
  double get scaleY => 1 / visibleHeight;

  static OfficeDocImageCrop from(Object? raw) {
    if (raw is! Map) return const OfficeDocImageCrop();
    double at(String k) => officeDocImagePx(raw[k]) ?? 0; // crop 的值实测是 0..1 的比例
    return OfficeDocImageCrop(
      left: at('l'),
      top: at('t'),
      right: at('r'),
      bottom: at('b'),
    );
  }
}

/// `width`/`height` 这类值：数字直接用，`"296px"`/`"12.5"` 取数字，其余 null。
double? officeDocImagePx(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) {
    final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(value);
    if (m != null) return double.tryParse(m.group(0)!);
  }
  return null;
}

/// `deg` → 弧度。
double officeDocImageRadians(Object? deg) {
  final v = officeDocImagePx(deg) ?? 0;
  return v * math.pi / 180;
}

/// `flip_h`/`flip_v` → 变换矩阵（供测试直接断言"翻转真的生效"）。
Matrix4 officeDocImageFlipMatrix({
  required bool horizontal,
  required bool vertical,
}) => Matrix4.diagonal3Values(horizontal ? -1 : 1, vertical ? -1 : 1, 1);

/// 文档里的一张图片。
///
/// 三态由一次 [FutureBuilder] 驱动：加载中 → 骨架；成功 → `Image`；
/// 失败 → 失败文案 + 原因 + 重试（重试会先 [OfficeDocImageCache.evict]）。
class OfficeDocImage extends StatefulWidget {
  const OfficeDocImage({
    super.key,
    required this.objectId,
    required this.fileId,
    this.width,
    this.height,
    this.alt = '',
    this.crop = const OfficeDocImageCrop(),
    this.degrees = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.alignment = OfficeDocImageAlignment.inline,
    this.provider,
    this.cache,
  });

  /// `Snapshot:get` 的 `object_id`。
  final String objectId;

  /// `picture.config.file_id`（或 `image.attrs.file_id`）。
  final String fileId;

  /// 版式尺寸（逻辑像素，来自 `config.width/height`）。
  final double? width;
  final double? height;

  /// 无障碍语义 / 失败时的友好名字（原文件名，**不是** file_id/路径）。
  final String alt;

  final OfficeDocImageCrop crop;
  final double degrees;
  final bool flipHorizontal;
  final bool flipVertical;
  final OfficeDocImageAlignment alignment;

  /// 字节提供者；null = 未连接（显示失败态，可重试）。
  final OfficeAttachmentBytesProvider? provider;

  /// 缓存；null = [officeDocImageCache]。
  final OfficeDocImageCache? cache;

  /// 未标注尺寸时的兜底显示框（逻辑像素）。
  static const double fallbackWidth = 160;
  static const double fallbackHeight = 120;

  @override
  State<OfficeDocImage> createState() => _OfficeDocImageState();
}

class _OfficeDocImageState extends State<OfficeDocImage> {
  late Future<Uint8List> _future;

  String get _cacheKey =>
      OfficeDocImageCache.keyOf(widget.objectId, widget.fileId);

  OfficeDocImageCache get _cache => widget.cache ?? officeDocImageCache;

  double get _boxWidth => widget.width ?? OfficeDocImage.fallbackWidth;
  double get _boxHeight => widget.height ?? OfficeDocImage.fallbackHeight;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(OfficeDocImage old) {
    super.didUpdateWidget(old);
    if (old.objectId != widget.objectId ||
        old.fileId != widget.fileId ||
        old.provider != widget.provider) {
      _future = _load();
    }
  }

  Future<Uint8List> _load() {
    final provider = widget.provider;
    if (widget.fileId.isEmpty) {
      return Future<Uint8List>.error(
        const OfficeAttachmentException(
          OfficeAttachmentErrorKind.missingParam,
          detail: 'picture/image 节点没有 file_id',
        ),
      );
    }
    if (provider == null) {
      return Future<Uint8List>.error(
        const OfficeAttachmentException(
          OfficeAttachmentErrorKind.unknown,
          detail: '没有可用的附件字节通道（未连接）',
        ),
      );
    }
    return _cache.load(
      _cacheKey,
      () => provider(objectId: widget.objectId, fileId: widget.fileId),
    );
  }

  void _retry() {
    _cache.evict(_cacheKey);
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        final Widget content;
        if (snapshot.hasError) {
          content = _failure(context, snapshot.error);
        } else if (snapshot.connectionState == ConnectionState.done &&
            snapshot.data != null) {
          content = _ready(context, snapshot.data!);
        } else {
          content = _skeleton(context);
        }
        return _aligned(content);
      },
    );
  }

  Widget _aligned(Widget child) {
    switch (widget.alignment) {
      case OfficeDocImageAlignment.inline:
        return child;
      case OfficeDocImageAlignment.left:
      case OfficeDocImageAlignment.center:
      case OfficeDocImageAlignment.right:
        return Align(
          key: const Key('office-doc-image-align'),
          alignment: switch (widget.alignment) {
            OfficeDocImageAlignment.left => Alignment.centerLeft,
            OfficeDocImageAlignment.right => Alignment.centerRight,
            _ => Alignment.center,
          },
          child: child,
        );
    }
  }

  Widget _skeleton(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      key: const Key('office-doc-image-loading'),
      width: _boxWidth,
      height: _boxHeight,
      alignment: Alignment.center,
      color: t.colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.image_outlined,
        color: t.colorScheme.onSurfaceVariant,
        size: math.min(_boxWidth, _boxHeight) * 0.4,
      ),
    );
  }

  Widget _ready(BuildContext context, Uint8List bytes) {
    final alt = officeDocImageLabel(widget.alt);
    Widget image = Image.memory(
      bytes,
      width: _boxWidth,
      height: _boxHeight,
      fit: BoxFit.fill,
      gaplessPlayback: true,
      semanticLabel: alt.isEmpty ? null : alt,
      errorBuilder: (context, error, stack) => _failureBody(
        context,
        const OfficeAttachmentException(
          OfficeAttachmentErrorKind.unknown,
          detail: '字节不是可解码的图片',
        ),
        // 解码失败不提供"重试"（重试同一份字节没意义）。
        allowRetry: false,
      ),
    );

    final crop = widget.crop;
    if (!crop.isIdentity) {
      image = Transform(
        key: const Key('office-doc-image-crop'),
        alignment: crop.alignment,
        transform: Matrix4.diagonal3Values(crop.scaleX, crop.scaleY, 1),
        child: image,
      );
    }

    if (widget.degrees != 0 || widget.flipHorizontal || widget.flipVertical) {
      final matrix = officeDocImageFlipMatrix(
        horizontal: widget.flipHorizontal,
        vertical: widget.flipVertical,
      );
      if (widget.degrees != 0) {
        matrix.rotateZ(officeDocImageRadians(widget.degrees));
      }
      image = Transform(
        key: const Key('office-doc-image-transform'),
        alignment: Alignment.center,
        transform: matrix,
        child: image,
      );
    }

    return SizedBox(
      key: const Key('office-doc-image-box'),
      width: _boxWidth,
      height: _boxHeight,
      child: ClipRect(child: image),
    );
  }

  Widget _failure(BuildContext context, Object? error) {
    // ★ DA198：`notFound`（服务端就是没有这张图）/`missingParam`（文档里没有可用的
    //   引用）换个时间点也一样 ⇒ 不给"重试"，否则用户点几次都不会变（真机上
    //   `01.png` 的按钮点了三次全是同一个失败）。能变的错（网络/超时/权限/会话）
    //   才给重试。
    final kind = error is OfficeAttachmentException
        ? error.kind
        : OfficeAttachmentErrorKind.unknown;
    final retriable =
        kind != OfficeAttachmentErrorKind.notFound &&
        kind != OfficeAttachmentErrorKind.missingParam;
    return _failureBody(context, error, allowRetry: retriable);
  }

  Widget _failureBody(
    BuildContext context,
    Object? error, {
    required bool allowRetry,
  }) {
    final t = Theme.of(context);
    final kind = error is OfficeAttachmentException
        ? error.kind
        : OfficeAttachmentErrorKind.unknown;
    final reason = officeDocImageErrorReason(kind);
    final name = officeDocImageLabel(widget.alt);
    final title = name.isEmpty
        ? officeDocText('officeDocImageFailed', '图片加载失败')
        : officeDocText(
            'officeDocImageFailedNamed',
            '图片加载失败：{name}',
          ).replaceAll('{name}', name);
    return Container(
      key: const Key('office-doc-image-failed'),
      width: _boxWidth,
      constraints: BoxConstraints(minHeight: _boxHeight),
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        border: Border.all(color: t.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
        color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: t.colorScheme.outline),
          const SizedBox(height: Gap.xxs),
          Text(
            title,
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: Gap.xxs),
          Text(
            reason,
            textAlign: TextAlign.center,
            style: t.textTheme.labelSmall?.copyWith(
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
          if (allowRetry) ...[
            const SizedBox(height: Gap.xs),
            TextButton(
              key: const Key('office-doc-image-retry'),
              onPressed: _retry,
              child: Text(officeDocText('officeDocImageRetry', '重试')),
            ),
          ],
        ],
      ),
    );
  }
}

/// 图片的可访问名 / 失败卡里的"图片名"（`DA204`）。
///
/// 真机 r613（Drive Office 编辑态）的 `uiautomator dump` 里读到过一个可访问名
/// `null?_sid=%22KoFcFq3S0Spqc13C0…` —— 那是**文档自带的 `file_alt`**（服务端
/// 下发的原始串），我们原来原样喂给 `Image.semanticLabel` 与失败卡标题 ⇒
/// 读屏用户会听到一段 URL 片段，失败卡上会显示 `图片加载失败：null?_sid=…`。
///
/// 判据：只有"像文件名的短串"才允许上屏/进读屏；带 `?` `%` `=` `/` `\\`
/// 或超过 [maxLength] 的，一律当成**没有名字**（界面按"图片加载失败"兜底）。
String officeDocImageLabel(String raw, {int maxLength = 48}) {
  final s = raw.trim();
  if (s.isEmpty) return '';
  if (s.length > maxLength) return '';
  for (final bad in const <String>['?', '%', '=', '/', '\\', '&', '#']) {
    if (s.contains(bad)) return '';
  }
  // 控制字符 / 纯符号（`null?`、`--`、`…`）都不算名字。
  final word = RegExp(r'[A-Za-z0-9\u4e00-\u9fff]');
  var letterOrDigit = 0;
  for (final r in s.runes) {
    if (r < 0x20 || r == 0x7f) return '';
    if (word.hasMatch(String.fromCharCode(r))) letterOrDigit++;
  }
  if (letterOrDigit == 0) return '';
  return s;
}

/// 失败原因分类 → **用户能懂**的一句话（不含任何内部标识）。
String officeDocImageErrorReason(OfficeAttachmentErrorKind kind) =>
    switch (kind) {
      OfficeAttachmentErrorKind.missingParam => officeDocText(
        'officeDocImageReasonMissing',
        '这张图片没有可用的引用',
      ),
      OfficeAttachmentErrorKind.notFound => officeDocText(
        'officeDocImageReasonNotFound',
        '服务器上找不到这张图片',
      ),
      OfficeAttachmentErrorKind.noPermission => officeDocText(
        'officeDocImageReasonNoPermission',
        '没有查看这张图片的权限',
      ),
      OfficeAttachmentErrorKind.sessionExpired => officeDocText(
        'officeDocImageReasonSession',
        '登录状态已过期，重新登录后可重试',
      ),
      OfficeAttachmentErrorKind.timeout => officeDocText(
        'officeDocImageReasonTimeout',
        '网络超时',
      ),
      OfficeAttachmentErrorKind.network => officeDocText(
        'officeDocImageReasonNetwork',
        '网络连接失败',
      ),
      OfficeAttachmentErrorKind.empty => officeDocText(
        'officeDocImageReasonEmpty',
        '服务器返回了空图片',
      ),
      OfficeAttachmentErrorKind.unknown => officeDocText(
        'officeDocImageReasonUnknown',
        '暂时无法显示',
      ),
    };
