// 笔记正文渲染（只读）：NoteStation HTML → Delta → `flutter_quill` 只读编辑器。
//
// 为什么用 Quill 渲染而不是自己写一套 HTML widget 树：**编辑与渲染共用一套
// Delta 模型**，格式在两边永远一致（自己写渲染器就要维护两份方言映射）。
//
// 图片：正文里是 `<img … ref="…">`（真机实测服务端原样保存这一串），要靠附件表的
// `ref` → `file_id` 换出 `Note/download` 直链，再**带鉴权取字节**（不走
// `Image.network`：下载要 `_sid` + CSRF 头，交给传输层最稳）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/media/zoom_stage.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/note_dto.dart';
import 'note_html.dart';
import 'note_providers.dart';
import '../../core/user_facing_error.dart';

/// 只读笔记正文
class NoteBody extends StatefulWidget {
  const NoteBody({
    super.key,
    required this.html,
    this.note,
    this.padding = const EdgeInsets.all(Gap.lg),
    this.localPreviews = const {},
  });

  final String html;

  /// 带附件表的笔记（有图时必须给，否则图片渲染不出来）
  final NoteDto? note;
  final EdgeInsets padding;

  /// 「刚插入、还没上传」的图：`ref` → 本地路径（编辑器预览用）
  final Map<String, String> localPreviews;

  @override
  State<NoteBody> createState() => _NoteBodyState();
}

class _NoteBodyState extends State<NoteBody> {
  /// 控制器跟着 HTML 走：`build` 里现建不释放会漏（Quill 的控制器带监听）
  quill.QuillController? _controller;

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void didUpdateWidget(NoteBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html || oldWidget.note != widget.note) {
      _controller?.dispose();
      _build();
    }
  }

  void _build() {
    final attachments = widget.note?.attachments ?? const {};
    final resolver = NoteImageResolver.ofAttachments(attachments);
    final delta = noteHtmlToDelta(widget.html, resolver: resolver);
    final hasImage = delta.any(
      (op) => op['insert'] is Map && (op['insert'] as Map)['image'] != null,
    );
    if (notePlainText(widget.html).isEmpty && !hasImage) {
      _controller = null;
      return;
    }
    _controller = quill.QuillController(
      document: quill.Document.fromJson(delta),
      selection: const TextSelection.collapsed(offset: 0),
      readOnly: true,
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Padding(
        padding: widget.padding,
        child: Text(
          context.t.noteEmptyBody,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: DesignPalette.of(context).dim),
        ),
      );
    }
    return QuillReadOnly(
      controller: controller,
      padding: widget.padding,
      objectId: widget.note?.objectId ?? '',
      attachments: widget.note?.attachments ?? const {},
      localPreviews: widget.localPreviews,
    );
  }
}

/// 只读 Quill 渲染（控制器由调用方持有并释放）
class QuillReadOnly extends StatelessWidget {
  const QuillReadOnly({
    super.key,
    required this.controller,
    this.padding = const EdgeInsets.all(Gap.lg),
    this.objectId = '',
    this.attachments = const {},
    this.localPreviews = const {},
  });

  final quill.QuillController controller;
  final EdgeInsets padding;

  /// 图片附件下载要用（`Note/download` 的 `object_id`）
  final String objectId;
  final Map<String, NoteAttachmentDto> attachments;

  /// 「刚插入、还没上传」的图：`ref` → 本地路径
  final Map<String, String> localPreviews;

  @override
  Widget build(BuildContext context) {
    return quill.QuillEditor.basic(
      controller: controller,
      config: quill.QuillEditorConfig(
        // ⚠️ 只在**有界**父容器里用（调用方给 Expanded）。真机踩过：
        // `scrollable: true` + `expands: false` 塞进 `SingleChildScrollView`
        // 会让编辑器高度算成 0 —— 正文整块不见（列表里有字，详情页空白）。
        scrollable: true,
        padding: padding,
        autoFocus: false,
        expands: true,
        showCursor: false,
        embedBuilders: [
          NoteImageEmbedBuilder(
            objectId: objectId,
            attachments: attachments,
            localPreviews: localPreviews,
          ),
          const NoteHrEmbedBuilder(),
        ],
      ),
    );
  }
}

/// 分割线（官方 `CMD_HORIZONTAL_RULE="inserthorizontalrule"`）。
///
/// `flutter_quill` 11.6 **没有** hr 控件，所以用自定义块 embed（Delta 里的
/// `{'insert': {'hr': ''}}`）；没有这个 builder 时 Quill 会抛
/// `Embeddable type "hr" is not supported`，整块正文变 ErrorBox（图片踩过同样的坑）。
class NoteHrEmbedBuilder extends quill.EmbedBuilder {
  const NoteHrEmbedBuilder();

  @override
  String get key => 'hr';

  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.md),
      child: Divider(
        height: 1,
        thickness: 1,
        color: Theme.of(context).dividerColor,
      ),
    );
  }
}

/// 正文里的图片附件：按 `file_id` 取字节并渲染（点开可看大图）。
///
/// 取不到（服务端没给附件表 / 不是本笔记的附件）时退化成一行说明文字，
/// 而不是一个破图图标。
class NoteImageEmbedBuilder extends quill.EmbedBuilder {
  NoteImageEmbedBuilder({
    required this.objectId,
    this.attachments = const {},
    this.localPreviews = const {},
  });

  final String objectId;
  final Map<String, NoteAttachmentDto> attachments;

  /// 「刚插入、还没上传」的图：`ref` → 本地文件路径。
  /// 上传成功后这些值会被换成附件 `file_id`（见 `note_editor_page.dart`）。
  final Map<String, String> localPreviews;

  @override
  String get key => 'image';

  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) {
    final value = '${embedContext.node.value.data}';
    final localPath = localPreviews[value];
    if (localPath != null) {
      // 还没上传：直接显示本地文件，所见即所得
      return _LocalImagePreview(path: localPath);
    }
    final attachment = attachments[value];
    if (objectId.isEmpty || attachment == null) {
      return _NoteImageFallback(label: attachment?.name ?? value);
    }
    return NoteImage(
      objectId: objectId,
      attachment: attachment,
      // 同一张笔记里的所有图片（左右滑看下一张）；顺序取附件表本身
      siblings: [
        for (final a in attachments.values)
          if (a.isImage) a,
      ],
      maxWidth: MediaQuery.sizeOf(context).width,
    );
  }
}

/// 「待上传」图片的本地预览（灰底 + 圆角，尺寸跟正式图片一致）
class _LocalImagePreview extends StatelessWidget {
  const _LocalImagePreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width,
          ),
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Container(
              constraints: const BoxConstraints(minHeight: 72, minWidth: 72),
              color: hud.surface,
              alignment: Alignment.center,
              child: Icon(Icons.image_outlined, size: 18, color: hud.dim),
            ),
          ),
        ),
      ),
    );
  }
}

/// 列表里的封面缩略图（不点开也能看到内容概览）。
///
/// 用的是同一个 `Note/download`（`file_id = thumb.thumb_source`，`thumb=true`），
/// 所以这里只做"固定尺寸的圆角小图 + 占位"。
class NoteThumb extends ConsumerWidget {
  const NoteThumb({
    super.key,
    required this.objectId,
    required this.thumb,
    this.size = 40,
    this.maxSlotHeight,
  });

  final String objectId;
  final NoteThumbDto thumb;
  final double size;

  /// 整个左侧槽位（含本组件自身的 [topPad] 内边距）允许的最大高度。
  ///
  /// 不传 = 保持原样（`size × 1.25`；网格卡用它，卡片高度固定、无所谓）。
  /// 列表行传 [listRowThumbSlotHeight]：**行高必须由文字（内容）决定，缩略图只是
  /// 装饰** —— 否则 40×50+2＝52dp 的缩略图会把「有图的行」撑到 68dp，比「无图的行」
  /// （52dp）高出一截（D10，真机可复现）。给定后图片按 `BoxFit.cover` 裁进这个高度。
  final double? maxSlotHeight;

  /// 缩略图自身的 top 内边距（计入 [maxSlotHeight]，保证槽位真正不超限）。
  static const double topPad = 2;

  /// 图片盒子的实际高度（槽位高 − top 内边距）。
  double get boxHeight =>
      maxSlotHeight == null ? size * 1.25 : maxSlotHeight! - topPad;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final bytes = ref.watch(
      noteImageProvider(NoteImageRequest(objectId, thumb.source, thumb: true)),
    );
    final side = (w: size, h: boxHeight);
    return Padding(
      padding: const EdgeInsets.only(right: Gap.md, top: topPad),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: bytes.when(
          loading: () => _icon(hud, side, loading: true),
          error: (e, __) => _icon(hud, side),
          data: (data) => Image.memory(
            data,
            width: size,
            height: side.h,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _icon(hud, side),
          ),
        ),
      ),
    );
  }

  Widget _icon(
    DesignPalette hud,
    ({double w, double h}) side, {
    bool loading = false,
  }) => Container(
    width: side.w,
    height: side.h,
    color: hud.surface,
    alignment: Alignment.center,
    child: loading
        ? const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(Icons.image_outlined, size: 16, color: hud.dim),
  );
}

/// 列表行左侧缩略图槽位的高度上限（含 [NoteThumb.topPad]）。
///
/// 取「标题 + meta」两行文字的高度：`titleSmall`(14sp → 20) + 4 + telemetry(10sp → 12)
/// = **36dp**。为什么是这个值（D10，机制量用 `tester.getSize` 量过）：
///   * 无缩略图的行内容高 = `max(图标 22, 文字 36)` = 36，行高 = 36 + 上下 8 = **52dp**；
///   * `NoteThumb` 默认 40×50（+2）= **52dp** ⇒ 有缩略图的行高 = 52 + 16 = **68dp**，
///     比无图行**多 16dp**（≈ 一个行盒）—— 这是「附件行比普通行高」的机械来源之一。
/// ⇒ 缩略图不许决定行高：用本常量把槽位封在两行文字的高度里，多出的部分 `BoxFit.cover`
///   裁掉（宽度不变 ⇒ 文字列不会被推得更右）。
const double listRowThumbSlotHeight = 36;

/// 一张笔记图片（缩略图 → 点开看原图）
class NoteImage extends ConsumerStatefulWidget {
  const NoteImage({
    super.key,
    required this.objectId,
    required this.attachment,
    this.siblings = const [],
    this.maxWidth = 320,
  });

  final String objectId;
  final NoteAttachmentDto attachment;

  /// 同一条笔记里的其它图片（全屏看大图时左右滑切换）
  final List<NoteAttachmentDto> siblings;
  final double maxWidth;

  @override
  ConsumerState<NoteImage> createState() => _NoteImageState();
}

class _NoteImageState extends ConsumerState<NoteImage> {
  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    // 先加载缩略图（原图可能几 MB），点开大图时才要原图
    final req = NoteImageRequest(
      widget.objectId,
      widget.attachment.fileId,
      thumb: true,
    );
    final bytes = ref.watch(noteImageProvider(req));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: bytes.when(
        loading: () => _placeholder(hud, loading: true),
        error: (e, __) => _placeholder(hud, failed: true),
        data: (data) => GestureDetector(
          onTap: () => _openFull(context),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxWidth),
              child: Image.memory(
                data,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _placeholder(hud, failed: true),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(
    DesignPalette hud, {
    bool loading = false,
    bool failed = false,
  }) => Container(
    constraints: BoxConstraints(
      maxWidth: widget.maxWidth,
      minHeight: 72,
      minWidth: 72,
    ),
    decoration: BoxDecoration(
      color: hud.surface,
      border: Border.all(color: hud.line),
      borderRadius: BorderRadius.circular(6),
    ),
    padding: const EdgeInsets.all(Gap.md),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (loading)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(Icons.broken_image_outlined, size: 18, color: hud.dim),
        const SizedBox(width: Gap.sm),
        Flexible(
          child: Text(
            failed
                ? context.t.noteImageOpenFailed(widget.attachment.name)
                : (widget.attachment.name.isEmpty
                      ? context.t.noteImageAttachment
                      : widget.attachment.name),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: hud.dim),
          ),
        ),
      ],
    ),
  );

  Future<void> _openFull(BuildContext context) async {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => NoteImagePage(
          objectId: widget.objectId,
          attachment: widget.attachment,
          siblings: widget.siblings,
        ),
      ),
    );
  }
}

/// 附件占位（没有附件信息时用）
class _NoteImageFallback extends StatelessWidget {
  const _NoteImageFallback({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_outlined, size: 18, color: hud.dim),
          const SizedBox(width: Gap.xs),
          Text(
            label.isEmpty ? context.t.noteImageInNote : label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: hud.dim),
          ),
        ],
      ),
    );
  }
}

/// 全屏看原图（可缩放、可左右滑看同一条笔记里的其它图）
class NoteImagePage extends ConsumerStatefulWidget {
  const NoteImagePage({
    super.key,
    required this.objectId,
    required this.attachment,
    this.siblings = const [],
  });

  final String objectId;
  final NoteAttachmentDto attachment;

  /// 同一条笔记里的其它图片（左右滑切换）
  final List<NoteAttachmentDto> siblings;

  @override
  ConsumerState<NoteImagePage> createState() => _NoteImagePageState();
}

class _NoteImagePageState extends ConsumerState<NoteImagePage> {
  late final List<NoteAttachmentDto> _items = widget.siblings.isEmpty
      ? [widget.attachment]
      : widget.siblings;
  late int _index = _initialIndex();
  late final PageController _pages = PageController(initialPage: _index);

  int _initialIndex() {
    final i = _items.indexWhere((a) => a.fileId == widget.attachment.fileId);
    return i < 0 ? 0 : i;
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _items[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${current.name}'
          '${_items.length > 1 ? '  ${_index + 1}/${_items.length}' : ''}',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          if (current.size > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: Gap.md),
                child: Text(
                  current.displaySize,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
            ),
        ],
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: _items.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) =>
            _FullImage(objectId: widget.objectId, attachment: _items[i]),
      ),
    );
  }
}

class _FullImage extends ConsumerStatefulWidget {
  const _FullImage({required this.objectId, required this.attachment});

  final String objectId;
  final NoteAttachmentDto attachment;

  @override
  ConsumerState<_FullImage> createState() => _FullImageState();
}

class _FullImageState extends ConsumerState<_FullImage> {
  @override
  Widget build(BuildContext context) {
    final bytes = ref.watch(
      noteImageProvider(
        NoteImageRequest(widget.objectId, widget.attachment.fileId),
      ),
    );
    return bytes.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, __) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Text(
            context.t.noteImageOpenError(userFacingError(e)),
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      ),
      // 双指缩放 + 双击放大到点到的地方；未放大时单指手势留给外层 `PageView`
      // （真机踩过：不让的话左右滑会一直停在同一张）—— 与相册/文件预览同一套
      data: (data) => ZoomStage(
        child: Center(
          child: Image.memory(data, fit: BoxFit.contain, gaplessPlayback: true),
        ),
      ),
    );
  }
}
