// 贴纸渲染 + 贴纸/表情选择面板。
//
// 反编译依据（Android-SynologyChat 2.11.1）：
//   * 贴纸消息：`type=sticker`、`message=":<name>:"`；`CommonViewBinder.bindSticker`
//     把图按 **150dp × 150dp**、`fitCenter` 画出来，size 用 `2x`。
//   * 贴纸名 → id：`StickerLoader` 用 `:(\S+?):` 抠出名字，再查本地贴纸表拿 id，
//     最后 `GET {base}sc/stickers/{id}/{size}`。
//   * 面板（分类 tab + 网格）在 `emoji_picker_sheet.dart`：表情是**内置**八组，
//     贴纸是服务端分类；这里只负责"一张贴纸怎么画"。
//   * emoji 分类里点一个 → **插进输入框**（`ChatUtil.insertEmojiInEditText`），
//     不是发一条消息；贴纸分类点一个 → 立刻 `Post/create type=sticker`。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/sticker_dto.dart';
import 'chat_session_controller.dart';
import 'sticker_catalog.dart';

/// 贴纸消息的显示尺寸（原版 `PixelUtil.convertDpToPixel(150f)`）
const double kStickerEdge = 150;

/// 一张贴纸图。
///
/// [name] 与 [stickerId] 二选一：消息里只有名字（`:dog_01:`），要过目录查 id。
class StickerView extends ConsumerStatefulWidget {
  const StickerView({
    super.key,
    this.stickerId = 0,
    this.name = '',
    this.size = '2x',
    this.edge = kStickerEdge,
    this.onTap,
  });

  final int stickerId;
  final String name;
  final String size;
  final double edge;
  final VoidCallback? onTap;

  @override
  ConsumerState<StickerView> createState() => _StickerViewState();
}

class _StickerViewState extends ConsumerState<StickerView> {
  Future<List<int>>? _future;

  int? _resolveId(StickerCatalog? catalog) {
    if (widget.stickerId > 0) return widget.stickerId;
    // 消息里存的是 `:dog_01:`，要抠出短代码再查目录
    final raw = widget.name;
    final name =
        StickerCatalog.nameFromMessage(raw) ??
        (raw.startsWith(':') ? raw.replaceAll(':', '') : raw);
    if (name.isEmpty) return null;
    return catalog?.idOf(name);
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(stickerCatalogProvider).value;
    final api = ref.watch(chatApiProvider);
    final id = _resolveId(catalog);
    if (id == null || api == null) {
      // 目录还没到 / 名字查不到：先把短代码显示出来（原版也是透明底兜底）
      return _fallback(context);
    }
    _future ??= loadStickerBytes(api, id, size: widget.size);
    return FutureBuilder<List<int>>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) return _fallback(context);
        if (!snap.hasData) {
          return SizedBox(
            width: widget.edge,
            height: widget.edge,
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final image = Image.memory(
          Uint8List.fromList(snap.data!),
          width: widget.edge,
          height: widget.edge,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        );
        return widget.onTap == null
            ? image
            : GestureDetector(onTap: widget.onTap, child: image);
      },
    );
  }

  Widget _fallback(BuildContext context) {
    final label = widget.name.isNotEmpty
        ? widget.name
        : (widget.stickerId > 0 ? '🖼${widget.stickerId}' : '🖼');
    return Container(
      width: widget.edge,
      height: widget.edge,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, textAlign: TextAlign.center),
    );
  }
}
