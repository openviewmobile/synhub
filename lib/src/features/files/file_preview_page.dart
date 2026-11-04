// 文件内嵌预览（P0.1）。
//
// 按类型分流，能内嵌就内嵌、不能内嵌就**老实说"交给系统应用"**（不假装支持）：
//
//   图片  → `InteractiveViewer` 缩放/拖动 + 左右滑看同目录的下一张；
//           先用缩略图垫着，原图下来后替换（大图不内嵌，直接引导下载）
//           **HEIC/HEIF 例外**：原图字节客户端解不了 → 只取服务端缩略图
//           （`needsServerDecodedImage`，见 `file_thumb.dart`）
//   文本  → **只取前 64KB**（`Range: bytes=0-N`，真机实测支持），等宽渲染
//   音频  → 复用聊天的播放器（`voicePlayerProvider`，just_audio）+ **可拖进度**
//           （FileStation `Download` 直链真机实测支持 Range；拖不动时滑块置灰）
//   视频  → **内置播放器**（`video_player` / Media3，流式 + 可拖 + 全屏），
//           来源不支持（Drive 无 Range / 空 URL / 证书固定 / 编码不支持）→ 老实回退
//   PDF   → **内嵌翻页**（`pdfrx`/PDFium；先用鉴权链路取字节，见 file_pdf_view.dart）
//   其他  → Office/压缩包：下载后用 `open_filex` 交给系统应用
//
// 大文件一律先问一句：内嵌预览是"顺手看一眼"，不该让手机把 2GB 视频读进内存。
// 视频是**流式**播放的，不受"整段读进内存"那个阈值限制。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/media/zoom_stage.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/local/book_store.dart' show driveBookKey, fsBookKey;
import '../../data/local/file_store.dart' show describeFileError;
import '../office/office_sheet_view.dart';
import '../office/office_sheet_xlsx.dart';
import '../media/media_audio_stage.dart';
import '../media/media_player_view.dart';
import '../media/media_reason_text.dart';
import '../media/media_source.dart';
import '../servers/session_controller.dart';
import 'drive_providers.dart' show driveApiProvider;
import 'file_download.dart';
import 'drive_download.dart';
import '../../data/office_api.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'drive_browse_view.dart' show refreshDriveViews;
import 'office_export.dart';
import 'office_providers.dart';
import 'office_viewer_page.dart';
import 'file_book_view.dart';
import 'file_pdf_view.dart';
import 'file_providers.dart';
import 'file_row.dart' show fileIconFor, formatFileTime;
import 'file_thumb.dart';
import '../../core/net/media_tls_policy.dart';
import '../../core/theme/app_theme.dart';

/// 预览方式
enum FilePreviewKind {
  image,
  text,
  audio,
  video,
  pdf,
  office,
  archive,

  /// 电子书（EPUB / FB2 / CBZ / MOBI / AZW3 / CHM / DJVU）—— 内嵌只读阅读
  book,

  /// ★ 第 67 轮 D62：**`.xlsx`/`.xlsm` 的内嵌网格查看**。
  ///
  /// 与 [office] 分开是必要的：`office` 那一支是"下载后交外部应用"，
  /// 而这一支要**在 App 内**解析 OOXML 并用 `OfficeSheetView` 画网格。
  officeSheet,

  /// 是电子书/文档但**解不开**（如带 DRM 的版本）等：交系统应用
  other,
}

/// 文本预览只读开头这么多字节（真机支持 `Range`，不会整份下载）
const int kTextHeadBytes = 64 * 1024;

/// 超过这个大小就不内嵌显示原图/文本（先让用户确认）
const int kInlinePreviewMaxBytes = 40 * 1024 * 1024;

/// 这个文件该用哪种方式预览
FilePreviewKind filePreviewKind(FileEntryDto e) {
  if (e.isDir) return FilePreviewKind.other;
  return switch (e.extension) {
    'jpg' ||
    'jpeg' ||
    'png' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'heic' ||
    'heif' => FilePreviewKind.image,
    'log' ||
    'json' ||
    'xml' ||
    'yaml' ||
    'yml' ||
    'csv' ||
    'ini' ||
    'conf' ||
    'sh' ||
    'dart' ||
    'java' ||
    'kt' ||
    'py' ||
    'js' ||
    'ts' ||
    'c' ||
    'cpp' ||
    'h' ||
    'go' ||
    'rs' ||
    'sql' => FilePreviewKind.text,
    'mp3' ||
    'wav' ||
    'aac' ||
    'm4a' ||
    'ogg' ||
    'flac' ||
    'opus' ||
    // 系统解码器通常解不了的音频（见 `lib/src/data/media/media_format_support.dart`）：
    // 必须**归到 audio** 才会走 `_mediaOrExternal` → `resolveEntryMediaSource` →
    // 拿到 `formatUnsupported` 的**明确提示**（"格式不支持 + 用其他应用打开"）。
    // 留在 `other` 只会给一句泛化的 `fileWhyOther`，用户报告的那句"不支持"
    // 就没被解释清楚（本批修复面）。
    'wma' ||
    'ape' ||
    'wv' ||
    'dsf' ||
    'dff' ||
    'mid' ||
    'midi' => FilePreviewKind.audio,
    'mp4' ||
    'mov' ||
    'mkv' ||
    'avi' ||
    'webm' ||
    'm4v' ||
    'flv' ||
    // 同理：这几个容器 Media3 1.9.2 没有抽取器（rm/rmvb 是 RealMedia，
    // wmv/asf 是 ASF）→ 归到 video 才能拿到明确的 `formatUnsupported`
    'wmv' ||
    'asf' ||
    'rm' ||
    'rmvb' => FilePreviewKind.video,
    'pdf' => FilePreviewKind.pdf,
    // 电子书：全部走"解析成 BookContent → 复用同一个只读阅读器"这条路。
    //
    //   * EPUB / FB2 / CBZ：老一批；
    //   * MOBI / AZW / AZW3：`book_mobi.dart`（PalmDB + PalmDOC）；
    //   * TXT / MD / HTML / RTF / TCR：`book_text.dart`（含编码探测）；
    //   * DOCX / ODT / OPF：`book_office.dart`（zip / 散装包）；
    //   * FBZ / CBT / CB7 / PDB / PRC：`file_book.dart` / `book_comic.dart` /
    //     `book_mobi.dart`（CB7 明确报"不支持 7z"）；
    //   * CBR：自研纯 Dart RAR 解压（`rar_archive.dart`），和 CBZ 同一个漫画视图；
    //   * CHM：自研纯 Dart ITSF 容器 + LZX 解压（`chm_archive.dart` +
    //     `book_chm.dart`），正文是 HTML → 复用同一个只读阅读器；
    //   * DJVU：自研纯 Dart 容器 + BZZ 文本层 + JB2 掩码 + IW44 小波
    //     （`djvu_*.dart` / `book_djvu.dart`）：有位图页走翻页器，只有文本层
    //     走富文本阅读器。DjVuLibre 是 GPL-2.0 → **不引**，全部自己写。
    //   * XPS / OXPS：自研纯 Dart OPC 包 + FixedPage 版式解析（`book_xps.dart`），
    //     Glyphs → 富文本、ImageBrush → 图片，一页一段；
    //   * FB3：zip + XML 的 FictionBook 3（`book_fb3.dart`），与 FB2 同体验；
    //   * LIT / RB：自研容器解析（`book_lit.dart` / `book_rb.dart`），做不到的
    //     变体（加密等）明确报"能力边界"；SNB 公开信息不足，只给明确结论。
    //
    // 注意：`.txt` / `.md` / `.docx` / `.odt` / `.rtf` 从"文本预览 / Office 服务端
    // 抽取"改到内嵌阅读器 —— 这条路能出目录、进度、书签、搜索、TTS，
    // 是用户要的"基本所有电子书格式都能读"。
    'epub' ||
    'fb2' ||
    'cbz' ||
    'cbr' ||
    'chm' ||
    'mobi' ||
    'azw' ||
    'azw3' ||
    'txt' ||
    'md' ||
    'markdown' ||
    'html' ||
    'htm' ||
    'xhtml' ||
    'rtf' ||
    'tcr' ||
    'docx' ||
    'odt' ||
    // ★ 215 轮 D62：`.pptx`/`.ods`/`.odp` 走**客户端只读查看器**
    //   （按页/按表抽结构），不再走服务端 `Office.File.extract` 的纯文本；
    //   `.xlsx` **不在这里** —— 它保持第 67 轮的内嵌**网格**（`officeSheet`），
    //   网格比正文流更适合表格（见下面 `officeSheet` 那一支）。
    'pptx' ||
    'ods' ||
    'odp' ||
    'pdb' ||
    'prc' ||
    'fbz' ||
    'cbt' ||
    'cb7' ||
    'djvu' ||
    'djv' ||
    'xps' ||
    'oxps' ||
    'fb3' ||
    'lit' ||
    'rb' ||
    'snb' ||
    'opf' => FilePreviewKind.book,
    // ★ 第 67 轮 D62：`.xlsx` 走**内嵌网格**（复用 `office_sheet_xlsx.dart`
    // 的解析器 + `OfficeSheetView`），不再只是"下载后用外部 App 开"。
    'xlsx' || 'xlsm' => FilePreviewKind.officeSheet,
    'doc' ||
    'xls' ||
    'ppt' ||
    // Synology Office 自己的三种格式：官方 Web/App 也是在 Drive 里直接打开，
    // 而**安卓上没有第三方 App 能打开它们**，所以必须走我们自己的
    // `Office.File.extract` 只读正文这条路（真机实测 `.odoc` 能抽出正文）。
    'odoc' ||
    'osheet' ||
    'oslides' => FilePreviewKind.office,
    'zip' ||
    'rar' ||
    '7z' ||
    'tar' ||
    'gz' ||
    'bz2' ||
    'xz' => FilePreviewKind.archive,
    _ => FilePreviewKind.other,
  };
}

/// 文本预览的"能不能内嵌"判断（也是给测试用的纯函数）
bool canPreviewInline(FileEntryDto e) {
  switch (filePreviewKind(e)) {
    case FilePreviewKind.image:
    case FilePreviewKind.text:
    case FilePreviewKind.audio:
    case FilePreviewKind.pdf:
    case FilePreviewKind.book:
      // 已知大小的超大文件先不内嵌
      return e.size <= kInlinePreviewMaxBytes || e.size == 0;
    case FilePreviewKind.officeSheet:
      // 与 `.xlsx` 解析器的防御上限一致（见 `office_sheet_xlsx.dart`）
      return e.size <= kInlinePreviewMaxBytes || e.size == 0;
    case FilePreviewKind.video:
    case FilePreviewKind.office:
    case FilePreviewKind.archive:
    case FilePreviewKind.other:
      return false;
  }
}

/// 解码文本开头：去 BOM、容忍非法 UTF-8、判断是否被截断
({String text, bool truncated}) decodeTextHead(List<int> bytes) {
  var data = bytes;
  // UTF-8 BOM
  if (data.length >= 3 &&
      data[0] == 0xEF &&
      data[1] == 0xBB &&
      data[2] == 0xBF) {
    data = data.sublist(3);
  }
  // 二进制文件误判成文本时，别把控制字符灌进界面
  final text = utf8.decode(data, allowMalformed: true);
  // 我们请求的就是这么多 → 说明后面可能还有
  final truncated = bytes.length >= kTextHeadBytes;
  return (text: text, truncated: truncated);
}

/// 预览页里"能左右滑着看"的同级文件（浏览页筛 siblings 时要用同一条规则）。
///
/// 为什么要把规则放在这里而不是调用方：调用方（文件浏览页）原来硬编码成
/// "只要图片"，于是**预览页里扩了可滑类型也没用**——两边规则必须是一份。
List<FileEntryDto> previewSwipeSiblings(List<FileEntryDto> entries) => [
  for (final e in entries)
    if (canSwipePreview(e)) e,
];

/// 单个文件能否参与"同级文件左右滑"（见 [_FilePreviewPageState._swipeable] 的取舍）
bool canSwipePreview(FileEntryDto e) {
  if (e.isDir) return false;
  return switch (filePreviewKind(e)) {
    FilePreviewKind.image || FilePreviewKind.text => true,
    FilePreviewKind.pdf => canPreviewInline(e),
    _ => false,
  };
}

/// 打开预览页（浏览页/收藏页/搜索结果都用它，行为保持一致）。
///
/// [siblings] 传同目录的其他文件时，图片可以左右滑着看。
/// [bytesUrl] / [downloadUrl] 给"非 FileStation 来源"用（目前是 Drive）：
/// 字节从这条鉴权直链取，而不是按 [FileEntryDto.path] 拼 FileStation 的 URL。
void openFilePreview(
  BuildContext context,
  FileEntryDto entry, {
  List<FileEntryDto> siblings = const [],
  String? bytesUrl,
  String? downloadUrl,
  String? officeLinkId,
  String? officeDrivePath,
  String? officeNativeBytesUrl,
}) {
  Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => FilePreviewPage(
        entry: entry,
        siblings: siblings,
        bytesUrl: bytesUrl,
        downloadUrl: downloadUrl,
        officeLinkId: officeLinkId,
        officeDrivePath: officeDrivePath,
        officeNativeBytesUrl: officeNativeBytesUrl,
      ),
    ),
  );
}

/// 预览页：可传同目录的 [siblings] 以支持图片左右滑
class FilePreviewPage extends ConsumerStatefulWidget {
  const FilePreviewPage({
    super.key,
    required this.entry,
    this.siblings = const [],
    this.bytesUrl,
    this.downloadUrl,
    this.officeLinkId,
    this.officeDrivePath,
    this.officeNativeBytesUrl,
  });

  final FileEntryDto entry;

  /// 同目录的其他文件（只有图片会被拿来做左右滑）
  final List<FileEntryDto> siblings;

  /// 取字节用的鉴权直链（为空 = 按 `entry.path` 走 FileStation）
  final String? bytesUrl;

  /// 下载/交给系统应用时用的鉴权直链（为空 = 走 FileStation 的下载队列）
  final String? downloadUrl;

  /// Drive 条目的 `permanent_link`：Office 文档「服务端抽取正文」的钥匙
  /// （`SYNO.Office.File.extract` 只认它，见 `lib/src/data/office_api.dart`）；
  /// 也是 `Office.Snapshot:get` v4 的 `link_id`。
  final String? officeLinkId;

  /// Drive 视角的展示路径（`/mydrive/...`）：`officeLinkId` 为空时，
  /// Snapshot 只读通道按真机取法（`Files:get {path:'/mydrive/<name>'}`）
  /// 现取一次 `permanent_link`（**Drive API 只认 `/mydrive`**）。
  final String? officeDrivePath;

  /// **Office 原生文档**（`.odoc/.osheet/.oslides`）的**原生字节**直链。
  ///
  /// 为什么不复用 [bytesUrl]：真机批次证实 Drive 自己的 `Files/download` 会把
  /// Office 原生文档**转码成 OOXML/PDF**（内容与扩展名不符），而 File Station
  /// 按真实路径（`home/Drive/...`）下载能拿到原生字节。调用方（Drive 行）
  /// 用 [officeNativeFileStationPath] 算出真实路径并给出这条直链。
  /// 为空时退化为 [bytesUrl]（可能被转码，由查看器给出专属提示）。
  final String? officeNativeBytesUrl;

  @override
  ConsumerState<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends ConsumerState<FilePreviewPage> {
  /// 图片放大后：关掉 `PageView` 的横滑，让单指手势去平移图片（同相册大图页）
  bool _zoomed = false;

  /// 当前条目的取字节直链：非 FileStation 来源（Drive）用传进来的那条，
  /// FileStation 来源返回 null（下游按 path 自己拼）。
  String? _bytesUrlFor(FileEntryDto e) =>
      e.path == widget.entry.path ? widget.bytesUrl : null;

  /// 当前条目的 Office link id（同 [_bytesUrlFor]，只对"本条目"给）
  String? _officeLinkFor(FileEntryDto e) =>
      e.path == widget.entry.path ? widget.officeLinkId : null;

  /// 当前条目的 **Office 原生字节**直链（只对"本条目"给）。
  String? _officeNativeBytesUrlFor(FileEntryDto e) =>
      e.path == widget.entry.path ? widget.officeNativeBytesUrl : null;

  /// 当前条目的 Drive 展示路径（`/mydrive/...`，只对"本条目"给）。
  String? _officeDrivePathFor(FileEntryDto e) =>
      e.path == widget.entry.path ? widget.officeDrivePath : null;

  /// Drive 条目的 `file_id`（`driveEntryAsFile` 把 path 编成 `drive:<fileId>`）。
  /// `Office.Export/download` 只认 `path=id:<file_id>`，FileStation 来源没有它。
  String? _driveFileIdFor(FileEntryDto e) =>
      e.path.startsWith('drive:') ? e.path.substring('drive:'.length) : null;

  /// 阅读进度 / 书签的键。Drive 条目的 `permanent_link` 是稳定 id（同一个
  /// 文件换目录、换设备都对得上），FileStation 只有路径可用。
  String _bookKeyFor(FileEntryDto e) {
    final link = _officeLinkFor(e);
    if (link != null && link.isNotEmpty) return driveBookKey(link);
    return fsBookKey(e.path);
  }

  /// 可以**左右滑动连续查看**的同级文件。
  ///
  /// 哪些类型能进来（这是"手势冲突"的取舍结果）：
  ///   * **图片 / 文本 / 能内嵌的 PDF**：各自的正文都是竖向滚动，横向滑动没有
  ///     别的用途 → 直接进；
  ///   * **电子书（EPUB/FB2/CBZ/MOBI/AZW3）不进**：它们自己的横向手势是"翻章/翻页"，
  ///     再套一层"翻文件"必然打架（用户会分不清滑的是哪一层）；
  ///   * **Office / 音频 / 视频 / 压缩包不进**：音频视频的横向手势是拖动进度条，
  ///     Office 文件的同级没有 Drive link id（抽不出正文），硬滑只会滑到
  ///     "请用其他应用打开"的提示页。
  late List<FileEntryDto> _swipeable;
  late PageController _pager;
  int _index = 0;

  /// 内嵌视频的**当前播放项**（播放器「下一个」/自动续播都跟随）。
  ///
  /// null = 非视频 / 还没起播 → 顶栏回落到条目自己的名字。R7-5-1：顶栏与播放器
  /// 回退面板必须同时显示当前项（面板读 `MediaPlayerView._currentSource`，顶栏读这里）。
  final ValueNotifier<MediaSource?> _playingMedia = ValueNotifier(null);

  FileEntryDto get _current =>
      _swipeable.isEmpty ? widget.entry : _swipeable[_index];

  @override
  void initState() {
    super.initState();
    final siblings = previewSwipeSiblings(widget.siblings);
    if (siblings.isEmpty || !siblings.any((e) => e.path == widget.entry.path)) {
      _swipeable = const [];
      _pager = PageController();
      _index = 0;
    } else {
      _swipeable = siblings;
      _index = siblings.indexWhere((e) => e.path == widget.entry.path);
      _pager = PageController(initialPage: _index);
    }
  }

  @override
  void dispose() {
    _pager.dispose();
    _playingMedia.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = _current;
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final t = context.t;

    // ★ r658（`DA273`，用户 2026-10-25 真机反馈「标题栏太高、视频有效区域很小，
    //   横屏和画中画特别明显」）：视频能内置播时**不再挂 AppBar**。
    //   那条 AppBar 是**布局**高度（56dp ＋ 状态栏 ≈ 88dp），从画面里永久扣掉：
    //   竖屏少一条、横屏少一条、画中画窗口里 56dp 直接吃掉三分之一；
    //   而它的三样内容（返回 / 文件名 / 更多动作）播放器的**浮层**顶栏都有，
    //   且跟控制条同显同隐（`MediaPlayerView.hostChrome`）。
    final inlineVideo = _inlineVideo(e);
    return Scaffold(
      backgroundColor: inlineVideo ? Colors.black : null,
      appBar: inlineVideo ? null : AppBar(
        // R7-5-1：内嵌视频「下一个」/自动续播后，顶栏必须与播放器面板显示同一条
        // （`onCurrentSourceChanged` 回填 `_playingMedia`）。
        title: ValueListenableBuilder<MediaSource?>(
          valueListenable: _playingMedia,
          builder: (_, playing, __) {
            // ★ r645（**DA244**，真机 2026-10-23）：在播时顶栏把**容器格式**当成了
            //   标题和副标题：标题是 `60招基础街球S01E01.AVI`（扩展名占掉 4 个字，
            //   真正想看的名字在 `A…` 处就被截断），第二行整整一行只写 `AVI`。
            //   格式属于技术参数 ⇒ 它已经在「播放设置 / 文件信息」里，顶栏不再占地：
            //   标题去掉扩展名，副标题只在**真的还有话要说**（同目录还有别的条目，
            //   给 `2/5` 这种位置）时才出现。
            final name = playing?.displayName ?? e.name;
            final title = playing == null ? name : mediaNameWithoutExtension(name);
            final subtitleParts = <String>[
              if (playing == null)
                e.extension.isEmpty
                    ? t.chatFilterFile
                    : e.extension.toUpperCase(),
              if (playing == null && !e.isDir && e.humanSize.isNotEmpty)
                e.humanSize,
              if (_swipeable.length > 1) '${_index + 1}/${_swipeable.length}',
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitleParts.isNotEmpty)
                  Text(
                    subtitleParts.join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                  ),
              ],
            );
          },
        ),
        actions: [
          // Office L2（§11 第 ⑧ 项）：原生文档「下载为 …」，
          // 能转换的上传文件「转换为 Office 文档」。两者都要求 Drive 来源
          // （`Office.*` 只认 `id:<file_id>` / `permanent_link`）。
          if (_driveFileIdFor(e) != null &&
              (isOfficeNativeName(e.name) || isOfficeConvertibleName(e.name)))
            PopupMenuButton<String>(
              key: const Key('preview-office-menu'),
              tooltip: t.fileOfficeExport,
              icon: const Icon(Icons.ios_share_outlined),
              onSelected: (v) => _officeAction(e, v),
              itemBuilder: (_) => [
                for (final f in officeExportFormatsFor(e.name))
                  PopupMenuItem(
                    value: 'office_export_${f.code}',
                    child: Text(t.driveDownloadAs(f.labelText())),
                  ),
                if (isOfficeConvertibleName(e.name))
                  PopupMenuItem(
                    value: 'office_convert',
                    child: Text(t.driveConvertToOffice),
                  ),
              ],
            ),
          IconButton(
            tooltip: t.dtoActionDownload,
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _download(e, openAfter: false),
          ),
          IconButton(
            tooltip: t.photoOpenWithOther,
            icon: const Icon(Icons.open_in_new),
            onPressed: () => _download(e, openAfter: true),
          ),
        ],
      ),
      body: _swipeable.length > 1
          ? PageView.builder(
              key: const Key('preview-file-pager'),
              controller: _pager,
              physics: _zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: _swipeable.length,
              onPageChanged: (i) => setState(() {
                _index = i;
                _zoomed = false;
              }),
              itemBuilder: (context, i) =>
                  _stageFor(_swipeable[i], active: i == _index),
            )
          : _stageFor(e, active: true),
    );
  }

  /// 一个文件对应的正文舞台（[active] 只给图片做预加载提示用）
  Widget _stageFor(FileEntryDto e, {required bool active}) {
    final kind = filePreviewKind(e);
    return switch (kind) {
      FilePreviewKind.image => _ImageStage(
        key: ValueKey(e.path),
        entry: e,
        bytesUrl: _bytesUrlFor(e),
        active: active,
        onZoomChanged: (z) {
          if (mounted && z != _zoomed) setState(() => _zoomed = z);
        },
      ),
      FilePreviewKind.text => _TextStage(entry: e, bytesUrl: _bytesUrlFor(e)),
      // 音频：能内嵌就内嵌（**带 seek**）；来源不支持就老实交系统应用
      FilePreviewKind.audio => _mediaOrExternal(
        e,
        MediaKind.audio,
        const Key('preview-audio-stage'),
      ),
      // 视频：内置播放器（流式 + 拖进度 + 全屏），不支持才回退
      FilePreviewKind.video => _mediaOrExternal(
        e,
        MediaKind.video,
        const Key('preview-video-stage'),
      ),
      // PDF：能内嵌就内嵌翻页；太大则老实交系统阅读器
      FilePreviewKind.pdf =>
        canPreviewInline(e)
            ? FilePdfStage(entry: e, bytesUrl: _bytesUrlFor(e))
            : _ExternalStage(
                entry: e,
                kind: FilePreviewKind.pdf,
                onDownload: () => _download(e, openAfter: false),
                onOpen: () => _download(e, openAfter: true),
              ),
      // Office：没有 Drive link id 就老实交系统应用；
      // 有的话让服务端抽正文，Flutter 原生渲染（不塞 WebView）
      // 电子书：EPUB/FB2（HTML 正文）/CBZ（图片包）
      FilePreviewKind.book =>
        canPreviewInline(e)
            ? FileBookStage(
                entry: e,
                bytesUrl: _bytesUrlFor(e),
                // 阅读进度/书签的键：Drive 用 permanent_link（稳定），
                // FileStation 用路径
                bookKey: _bookKeyFor(e),
              )
            : _ExternalStage(
                entry: e,
                kind: FilePreviewKind.book,
                onDownload: () => _download(e, openAfter: false),
                onOpen: () => _download(e, openAfter: true),
              ),
      FilePreviewKind.officeSheet =>
        canPreviewInline(e)
            ? _XlsxStage(entry: e, bytesUrl: _bytesUrlFor(e))
            : _ExternalStage(
                entry: e,
                kind: FilePreviewKind.officeSheet,
                onDownload: () => _download(e, openAfter: false),
                onOpen: () => _download(e, openAfter: true),
              ),
      FilePreviewKind.office =>
        // Synology Office **原生文档**（.odoc/.osheet/.oslides）：走自研只读
        // 查看器（纯 UI，调用已定稿的 `OfficeNativeDocument.parse`）。
        // 其余 Office 文件（docx/xlsx/…）仍走服务端抽取正文那条老路。
        isOfficeNativeName(e.name)
            ? OfficeNativeViewer(
                key: const Key('preview-office-native'),
                entry: e,
                // 三跳优先级（见 office_viewer_page.dart）：
                // ① Snapshot:get（link_id）→ ② File Station 原生字节 →
                // ③ Drive 直链（会被转码，查看器给专属提示）。
                linkId: _officeLinkFor(e) ?? '',
                drivePath: _officeDrivePathFor(e),
                nativeBytesUrl: _officeNativeBytesUrlFor(e),
                bytesUrl: _bytesUrlFor(e),
                onDownload: () => _download(e, openAfter: false),
                onOpen: () => _download(e, openAfter: true),
              )
            : _OfficeStage(
                entry: e,
                linkId: _officeLinkFor(e),
                onDownload: () => _download(e, openAfter: false),
                onOpen: () => _download(e, openAfter: true),
              ),
      _ => _ExternalStage(
        entry: e,
        kind: kind,
        onDownload: () => _download(e, openAfter: false),
        onOpen: () => _download(e, openAfter: true),
      ),
    };
  }

  /// 这次连接是不是"证书被固定"（自签证书靠我们的指纹放行）
  ///
  /// Media3（`video_player` / `just_audio`）走**系统信任链**，这种证书必然握手失败
  /// （调研 §5.4 第 1 条）→ 直接降级为"下载后交给系统应用"，别让播放器去撞墙。
  bool get _certPinned {
    final conn = ref.read(sessionControllerProvider).connection;
    if (conn == null || !conn.certPinned) return false;
    // ★ 第 293 轮修（真机缺陷：File Station 所有音视频都播不了）：
    // `certPinned` 的语义是"这枚证书不是系统 CA 验证过的"，**不等于**"播不了"。
    // r259 起 `session_controller._syncMediaTlsPolicy` 已经把该主机的 TLS 政策
    // 下发给原生播放器（`host|fingerprint`）⇒ Media3 能信任它 ⇒ 照常内置播放。
    // 只有在**政策没下发成功**时才降级为"下载 / 交给别的 App"。
    return !MediaTlsPolicy.isInstalledFor(conn.endpoint.baseUrl);
  }

  /// 这次连接是不是隧道传输（`tcpPort == 0` 时 `authenticatedUrl` 返回空串）
  bool get _tunnelTransport {
    final conn = ref.read(sessionControllerProvider).connection;
    if (conn == null) return false;
    return isTunnelTransport(conn.api.transport.describeKind);
  }

  /// 按来源解析"可播放 URL"（FileStation 主通道 / Drive 降级 / 空 URL 拒绝）
  MediaSource _mediaSourceFor(FileEntryDto e, MediaKind kind) =>
      resolveEntryMediaSource(
        entry: e,
        kind: kind,
        fs: ref.read(fileApiProvider),
        drive: ref.read(driveApiProvider),
        bytesUrl: _bytesUrlFor(e),
        certPinned: _certPinned,
        tunnelTransport: _tunnelTransport,
      );

  /// 当前条目是不是「能用内置播放器播」的视频（见 `build` 里的 `DA273`）
  ///
  /// 只看**能不能播**：不能播的走 `_ExternalStage`（那是"交给系统应用"的说明页，
  /// 必须留着 AppBar 才有返回与下载入口）；相册/图片/音频/文档都不受这条影响。
  bool _inlineVideo(FileEntryDto e) =>
      filePreviewKind(e) == FilePreviewKind.video &&
      _mediaSourceFor(e, MediaKind.video).reason == null;

  /// 能播 → 内置播放器；不能播 → 说清原因 + 交给系统应用（不假装支持）
  Widget _mediaOrExternal(FileEntryDto e, MediaKind kind, Key key) {
    final source = _mediaSourceFor(e, kind);
    Future<void> onDownload() => _download(e, openAfter: false);
    Future<void> onOpen() => _download(e, openAfter: true);
    final reason = source.reason;
    if (reason != null) {
      final text = mediaReasonText(context.t, reason, kind);
      return _ExternalStage(
        key: key,
        entry: e,
        kind: kind == MediaKind.video
            ? FilePreviewKind.video
            : FilePreviewKind.audio,
        why: '${text.title}\n${text.detail}',
        onDownload: onDownload,
        onOpen: onOpen,
      );
    }
    if (kind == MediaKind.video) {
      // 视频走**流式**播放（不受"整段读进内存"的 40MB 阈值限制）
      return MediaPlayerView(
        key: key,
        source: source,
        // 目录条目：播放列表（上一个/下一个）与同名字幕要靠它
        entry: e,
        // ★ r658（`DA273`）：内嵌也由播放器画顶栏 ⇒ 本页不再需要 AppBar
        hostChrome: true,
        onBack: () {
          final nav = Navigator.of(context);
          if (nav.canPop()) nav.maybePop();
        },
        onOpenExternal: onOpen,
        onDownload: onDownload,
        // R7-5-1：当前播放项回填顶栏（换集/自动续播必须与面板一致）
        onCurrentSourceChanged: (current) => _playingMedia.value = current,
      );
    }
    return MediaAudioStage(
      key: key,
      entry: e,
      source: source,
      // ★ r651（`DA251`）：换歌（上一首/下一首/接下来播放）后顶栏也要跟着换，
      // 与视频侧同一写法 —— 否则舞台上已是下一首、顶栏还挂着点开时那首。
      onCurrentSourceChanged: (current) => _playingMedia.value = current,
      onOpenExternal: onOpen,
      onDownload: onDownload,
    );
  }

  /// 溢出菜单里的 Office 动作（下载为 … / 转换为 Office 文档）
  Future<void> _officeAction(FileEntryDto e, String action) async {
    final t = context.t;
    final fileId = _driveFileIdFor(e);
    if (fileId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (action.startsWith('office_export_')) {
      final code = action.substring('office_export_'.length);
      final format = OfficeExportFormat.values.firstWhere(
        (f) => f.code == code,
        orElse: () => OfficeExportFormat.pdf,
      );
      try {
        final fileName = await downloadOfficeAs(
          ref,
          fileId: fileId,
          name: e.name,
          format: format,
          t: t,
        );
        trackFile(
          ref,
          UsageModule.drive,
          UsageAction.download,
          e.name,
          size: e.size,
          detail: {'office_format': format.code},
        );
        messenger.showSnackBar(
          SnackBar(content: Text(t.driveExported(fileName))),
        );
      } catch (err) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(t.driveExportFailed(describeOfficeError(err, t))),
          ),
        );
      }
      return;
    }
    if (action == 'office_convert') {
      var password = '';
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final converted = await convertToOfficeDocument(
            ref,
            fileId: fileId,
            name: e.name,
            password: password,
            t: t,
          );
          refreshDriveViews(ref);
          messenger.showSnackBar(
            SnackBar(content: Text(t.driveConverted(converted))),
          );
          return;
        } on OfficeConvertException catch (err) {
          if (!err.needsPassword || attempt > 0) {
            messenger.showSnackBar(SnackBar(content: Text(err.message)));
            return;
          }
          if (!mounted) return;
          final input = await promptOfficePassword(context, name: e.name);
          if (input == null) return;
          password = input;
        } catch (err) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(t.driveConvertFailed(describeOfficeError(err, t))),
            ),
          );
          return;
        }
      }
    }
  }

  Future<void> _download(FileEntryDto e, {required bool openAfter}) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    // Drive 来源：没有 FileStation 的下载队列，直接取字节落盘
    //
    // Office 原生文档的**内容与文件名必须一致**（真机缺陷：Drive 的
    // `Files/download` 会把 `.osheet` 转成 xlsx 字节却仍叫 `.osheet`）：
    //   * 有原生字节直链（File Station 真实路径）→ 原样下载、保留原名；
    //   * 只有 Drive 直链（会转码）→ 保存成**真实扩展名**并明确提示"已转换"。
    final plan = planOfficeDownload(
      name: e.name,
      driveUrl: widget.downloadUrl ?? '',
      nativeUrl: _officeNativeBytesUrlFor(e),
    );
    final url = _bytesUrlFor(e) == null ? null : plan.url;
    if (url != null) {
      // ★ D26：这条也是"保存到本机"，改走**断点续传引擎**
      // （原来是 `api.getBytes` 整份进内存，断了从头再来）。
      await downloadResumableWithUi(
        context,
        ref,
        resumeKey: 'preview:${e.path}',
        url: url,
        saveName: plan.saveName,
        usageName: e.name,
        usageSize: e.size,
        channel: plan.url == (_officeNativeBytesUrlFor(e) ?? '')
            ? DriveDownloadChannel.native
            : DriveDownloadChannel.drive,
        transcoded: plan.transcoded,
        openAfter: openAfter,
      );
      return;
    }
    final actions = ref.read(fileActionsProvider);
    final result = await downloadFileEntry(
      context,
      e,
      actions: actions,
      openAfter: openAfter,
    );
    if (!mounted) return;
    switch (result.status) {
      case FileDownloadStatus.ok:
        if (openAfter) {
          messenger.showSnackBar(
            SnackBar(content: Text(t.photoOpenedWith(e.name))),
          );
        } else {
          messenger.showSnackBar(
            SnackBar(content: Text(t.driveDownloaded(e.name))),
          );
        }
      case FileDownloadStatus.cancelled:
        break;
      case FileDownloadStatus.failed:
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              t.fileDownloadFailed(result.message ?? t.fileUnknownReason),
            ),
          ),
        );
    }
  }
}

/// 图片舞台：先缩略图，再原图；可缩放、可双击复位
class _ImageStage extends ConsumerStatefulWidget {
  const _ImageStage({
    super.key,
    required this.entry,
    this.active = true,
    required this.onZoomChanged,
    this.bytesUrl,
  });

  final FileEntryDto entry;
  final bool active;

  /// 放大状态回给外层：放大时外层要关掉 `PageView` 的横滑（同相册大图页）
  final ValueChanged<bool> onZoomChanged;

  /// 取字节直链（Drive 等非 FileStation 来源；为空则按 path 走 FileStation）
  final String? bytesUrl;

  @override
  ConsumerState<_ImageStage> createState() => _ImageStageState();
}

class _ImageStageState extends ConsumerState<_ImageStage> {
  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    // 不活跃的页先不加载原图（左右滑的时候别一次下三张）
    if (!widget.active) {
      return const Center(child: CircularProgressIndicator());
    }
    if (e.size > kInlinePreviewMaxBytes) {
      return _TooBigStage(entry: e);
    }

    // HEIC/HEIF：原图字节客户端解不了（`file_thumb.dart` 的 `looksLikeImage`
    // 故意不收 HEIC —— Flutter 解码器不认）。既然 `filePreviewKind` 把它声明成
    // "可预览图片"，就必须真能显示：改走**服务端缩略图** `SYNO.FileStation.Thumb`
    // （回 JPEG）；服务端给不出时由 [FileThumb] 出明确占位 + 原因，
    // **不**把 HEIC 原图喂给 `Image.memory`（那只会是通用解码失败）。
    if (needsServerDecodedImage(e.extension)) {
      return ZoomStage(
        onZoomChanged: widget.onZoomChanged,
        child: Center(
          child: FileThumb(
            entry: e,
            scale: ThumbScale.large,
            size: 320,
            iconSize: 64,
            radius: 16,
            fit: BoxFit.contain,
            showUnavailableReason: true,
          ),
        ),
      );
    }

    final full = ref.watch(
      fileBytesProvider(FileBytesRequest(e.path, url: widget.bytesUrl)),
    );
    final hud = DesignPalette.of(context);

    return Stack(
      children: [
        Positioned.fill(
          child: full.when(
            loading: () => const Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (err, __) => _PreviewError(
              detail: describeFileError(err),
              onRetry: () => ref.invalidate(
                fileBytesProvider(
                  FileBytesRequest(e.path, url: widget.bytesUrl),
                ),
              ),
            ),
            data: (bytes) => ZoomStage(
              onZoomChanged: widget.onZoomChanged,
              child: Center(
                child: bytes.isEmpty
                    ? Text(context.t.fileEmptyFile)
                    : Image.memory(
                        Uint8List.fromList(bytes),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => Center(
                          child: Text(context.t.fileImageDecodeFailed),
                        ),
                      ),
              ),
            ),
          ),
        ),
        // 原图还在路上时，用缩略图先占个位（比空白舒服，也不会闪）
        if (full.isLoading)
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.5,
                child: Center(
                  child: FileThumb(
                    entry: e,
                    scale: ThumbScale.large,
                    size: 220,
                    iconSize: 48,
                    radius: 12,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
        // ★ r532（DA169，真机亮色像素）：原来只给 `left`+`bottom`，
        // 文本宽度**无界** ⇒ 英文提示 "…· pinch to zoom" 直接冲出屏幕右边缘被裁掉
        // （`ellipsis` 根本不会触发）。补 `right` 约束 + 允许 2 行。
        Positioned(
          left: Gap.md,
          right: Gap.md,
          bottom: Gap.md,
          child: TelemetryLabel(
            context.t.fileImageGestureHint,
            size: 10,
            color: hud.dim,
            maxLines: 2,
          ),
        ),
      ],
    );
  }
}

class _TooBigStage extends StatelessWidget {
  const _TooBigStage({required this.entry});

  final FileEntryDto entry;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_size_select_actual_outlined,
              size: 48,
              color: hud.dim,
            ),
            const SizedBox(height: Gap.md),
            Text(
              t.fileImageTooBig(entry.humanSize),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Gap.xs),
            Text(
              t.fileImageTooBigHint,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 文本

class _TextStage extends ConsumerWidget {
  const _TextStage({required this.entry, this.bytesUrl});

  final FileEntryDto entry;
  final String? bytesUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final req = FileBytesRequest(
      entry.path,
      maxBytes: kTextHeadBytes,
      url: bytesUrl,
    );
    final head = ref.watch(fileBytesProvider(req));
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);

    return head.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, __) => _PreviewError(
        detail: describeFileError(err),
        onRetry: () => ref.invalidate(fileBytesProvider(req)),
      ),
      data: (bytes) {
        if (bytes.isEmpty) {
          return Center(child: Text(context.t.fileEmptyFile));
        }
        final decoded = decodeTextHead(bytes);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (decoded.truncated)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.md,
                  vertical: Gap.xs,
                ),
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.6,
                ),
                child: Row(
                  children: [
                    Icon(Icons.short_text, size: 14, color: hud.dim),
                    const SizedBox(width: Gap.xs),
                    Expanded(
                      child: Text(
                        context.t.fileTextHeadOnly(
                          kTextHeadBytes ~/ 1024,
                          entry.humanSize,
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hud.dim,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Gap.md),
                child: SelectableText(
                  decoded.text,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------- 其余类型

/// Office 文档只读：**服务端抽取正文 → Flutter 原生渲染**。
///
/// 为什么不内嵌 OOXML 渲染器、也不开 WebView：
///   * 官方自己不做端上编辑器，它开 WebView 灌服务端 Office 资源；
///   * 而服务端本来就有 `Office.File.extract`（真机回 `{data:"<正文>"}`），
///     用它 + 我们现成的文本舞台，只读这一层既保真又零新增依赖；
///   * L2/L3（换算/公式/编辑）才是"重写 Office"的大坑，留远期。
class _OfficeStage extends ConsumerWidget {
  const _OfficeStage({
    required this.entry,
    required this.linkId,
    required this.onDownload,
    required this.onOpen,
  });

  final FileEntryDto entry;

  /// `permanent_link`；为空 = 这个文件没进 Drive 索引（NAS 目录里的文档）
  final String? linkId;
  final VoidCallback onDownload;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final link = linkId;

    if (link == null || link.isEmpty) {
      return _NotIndexedStage(
        entry: entry,
        onDownload: onDownload,
        onOpen: onOpen,
      );
    }

    final text = ref.watch(officeExtractProvider(link));
    return text.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, __) => _PreviewError(
        detail:
            '${describeFileError(err)}\n'
            '${context.t.fileOfficeExtractHint}',
        onRetry: () => ref.invalidate(officeExtractProvider(link)),
      ),
      data: (body) => body.trim().isEmpty
          ? _NotIndexedStage(
              entry: entry,
              onDownload: onDownload,
              onOpen: onOpen,
              // 真机实测（2026-09-20）：`Office.File.extract` 对 Synology Office 自家的
              // `.odoc/.osheet/.oslides` **是有效的**（`.osheet` 抽出过 `Sheet1`），
              // 空正文只说明这份文档本来就是空的（或者正文全是图）—— 别把话说成
              // "不支持这种格式"。
              why: context.t.fileOfficeEmptyBody,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Gap.md,
                    vertical: Gap.xs,
                  ),
                  color: hud.surface,
                  child: Row(
                    children: [
                      Icon(
                        Icons.auto_awesome_outlined,
                        size: 14,
                        color: hud.dim,
                      ),
                      const SizedBox(width: Gap.xs),
                      Expanded(
                        child: Text(
                          '${context.t.fileOfficeReadonlyBody(body.length)}'
                          '${entry.extension.isEmpty ? '' : ' · ${entry.extension.toUpperCase()}'}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(Gap.md),
                    child: SelectableText(
                      body,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 没进 Drive 索引的 Office 文档（或抽取为空）：说清原因 + 给两条出路
class _NotIndexedStage extends StatelessWidget {
  const _NotIndexedStage({
    required this.entry,
    required this.onDownload,
    required this.onOpen,
    this.why,
  });

  final FileEntryDto entry;
  final VoidCallback onDownload;
  final VoidCallback onOpen;
  final String? why;

  @override
  Widget build(BuildContext context) {
    return _ExternalStage(
      entry: entry,
      kind: FilePreviewKind.office,
      onDownload: onDownload,
      onOpen: onOpen,
      why: why ?? context.t.fileOfficeNotIndexed,
    );
  }
}

/// ★ 第 67 轮 D62：**`.xlsx` / `.xlsm` 的内嵌网格查看**。
///
/// 复用现成的两件东西，不新写解析器：
/// * `office_sheet_xlsx.dart` 的 `parseOfficeSheetXlsx(bytes)`（纯函数，
///   已支持真实列宽/行高/样式/数字格式/冻结/合并）；
/// * `OfficeSheetView`（`workbook:` 参数让它接受**已解析好的模型**）。
///
/// ## 为什么这是"通用查看器"该做的事
/// 官方安卓端对 `.xlsx` 是**下载后交外部应用**（它自己没有本地 xlsx 渲染）；
/// 我们这边原本也是 `_ExternalStage`。而纯 Dart 解析器**已经存在**
/// （为 Drive 的 Synology Office 页面写的），白白不用才是缺口。
///
/// ## 失败时的纪律
/// 解析失败**必须回落**到 [FilePreviewKind.office] 那条"交外部应用"的路，
/// 并把原因说清楚 —— 不能只留一个空白网格，
/// 也不能把"这不是 xlsx"（比如 `.xls` 是 BIFF 二进制）说成解析错误。
class _XlsxStage extends ConsumerWidget {
  const _XlsxStage({required this.entry, this.bytesUrl});

  final FileEntryDto entry;
  final String? bytesUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final req = FileBytesRequest(entry.path, url: bytesUrl);
    final async = ref.watch(fileBytesProvider(req));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, __) => _BookLikeHint(
        icon: Icons.error_outline,
        title: t.bookOpenFailed,
        detail: describeFileError(e),
        onRetry: () => ref.invalidate(fileBytesProvider(req)),
      ),
      data: (bytes) {
        // 非 ZIP（`PK\x03\x04`）说明这其实不是 OOXML（典型：`.xls` 是 BIFF）
        if (!isOfficeSheetOoxmlBytes(bytes)) {
          return _BookLikeHint(
            icon: Icons.table_chart_outlined,
            title: t.fileWhyOffice,
            detail: t.bookUnsupportedFormat,
          );
        }
        try {
          final workbook = parseOfficeSheetXlsx(bytes);
          return OfficeSheetView(
            key: const Key('preview-xlsx-grid'),
            // 只读：`sections` 是 OFile 回落通道，OOXML 主通道走 `workbook`
            sections: const {},
            workbook: workbook,
          );
        } catch (e) {
          // 解不开就**如实说**，并让用户仍能下载后用外部应用打开
          return _BookLikeHint(
            icon: Icons.table_chart_outlined,
            title: t.fileWhyOffice,
            detail: describeFileError(e),
            onRetry: () => ref.invalidate(fileBytesProvider(req)),
          );
        }
      },
    );
  }
}

/// 与书籍查看器的提示块同构（本文件里已有 `_BookHint` 语义，
/// 但那是 `file_book_view.dart` 的私有件，这里保持本文件自洽）。
class _BookLikeHint extends StatelessWidget {
  const _BookLikeHint({
    required this.icon,
    required this.title,
    this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: hud.dim),
            const SizedBox(height: Gap.sm),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: hud.dim),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: Gap.sm),
              TextButton(onPressed: onRetry, child: Text(t.photoRetry)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ExternalStage extends StatelessWidget {
  const _ExternalStage({
    super.key,
    required this.entry,
    required this.kind,
    required this.onDownload,
    required this.onOpen,
    this.why,
  });

  final FileEntryDto entry;
  final FilePreviewKind kind;
  final VoidCallback onDownload;
  final VoidCallback onOpen;
  final String? why;

  String _whyIn(AppText t) =>
      why ??
      switch (kind) {
        FilePreviewKind.video => t.fileWhyVideo,
        FilePreviewKind.pdf => t.fileWhyPdf,
        FilePreviewKind.officeSheet => t.fileWhyOffice,
        FilePreviewKind.office => t.fileWhyOffice,
        FilePreviewKind.archive => t.fileWhyArchive,
        _ => t.fileWhyOther,
      };

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final icon = fileIconFor(entry);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: ShapeDecoration(
                shape: const ChamferBorder(cut: 18),
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.6,
                ),
              ),
              child: Icon(icon, size: 44, color: hud.dim),
            ),
            const SizedBox(height: Gap.lg),
            Text(
              entry.name,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: Gap.xs),
            Text(
              '${entry.humanSize}${entry.mtime > 0 ? ' · ${formatFileTime(entry.mtime, t: t)}' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
            const SizedBox(height: Gap.md),
            Text(
              _whyIn(t),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
            const SizedBox(height: Gap.lg),
            Wrap(
              spacing: Gap.sm,
              children: [
                FilledButton.tonalIcon( style: InlineButtonStyle.filled,
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new),
                  label: Text(t.photoOpenWithOther),
                ),
                OutlinedButton.icon( style: InlineButtonStyle.outlined,
                  onPressed: onDownload,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(t.dtoActionDownload),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewError extends StatelessWidget {
  const _PreviewError({required this.detail, required this.onRetry});

  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 40, color: hud.dim),
            const SizedBox(height: Gap.md),
            Text(
              context.t.fileOpenFailed,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Gap.xs),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
            const SizedBox(height: Gap.md),
            OutlinedButton(
              onPressed: onRetry,
              child: Text(context.t.photoRetry),
            ),
          ],
        ),
      ),
    );
  }
}
