// 消息里的附件渲染（Phase 5）：图片缩略图 / 文本预览 / 文件卡片 / 语音。
//
// 缩略图与原图都走 `SYNO.Chat.Post.File`，URL 里带 `_sid`（见 ChatApi.fileUrl），
// 所以可以直接交给 `Image.network` —— 不需要自己维护 cookie。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/system_open.dart';

import '../../core/settings/app_settings.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/ui/app_sheet.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/glass_pane.dart';
import 'file_actions.dart';
import '../../dsm/webapi.dart';
import '../../data/chat_api.dart';
import '../../data/dto/file_prop_dto.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/dto/post_dto.dart';
import 'attachment_access.dart';
import 'chat_image.dart';
import '../files/file_preview_page.dart' show openFilePreview;
import 'chat_session_controller.dart';
import 'download_dialog.dart';
import 'media_stream.dart';
import 'voice_message.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../../core/user_facing_error.dart';

/// 取附件的 MIME（服务端 `type` 只是扩展名，缩略图接口要 MIME）
String? mimeOfExtension(String ext) {
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'bmp':
      return 'image/bmp';
    case 'heic':
      return 'image/heic';
    default:
      return null;
  }
}

/// 上传时给 multipart 用的 MIME（图片之外一律 octet-stream）
String mimeForExtension(String ext) =>
    mimeOfExtension(ext) ?? 'application/octet-stream';

/// 没有应用能处理这个 MIME 时的哨兵返回值：调用方弹"打开方式"再重试
/// （原版 `FileUtil.showMimeTypeDialog`）
const String kNoStreamHandler = '__no_stream_handler__';

/// "用系统程序打开文件"这一步做成可注入的，测试里换成假的
/// （真实现会走 platform channel，单测环境里没有 handler）。
typedef AttachmentOpener = Future<OpenResult> Function(String path);

/// 真实现走 `system_open.dart`：测试环境直接 no-op（**不要把假文件交给
/// mac 的 Preview/QuickTime**），Android 上还是 `open_filex`。
Future<OpenResult> _defaultOpener(String path) => defaultSystemOpen(path);

/// 把一个 Chat 附件映射成统一预览页要的 [FileEntryDto]。
///
/// 为什么需要：§2.0.8 ④ —— **同一份文档，不同入口必须走同一个阅读器**。
/// Chat 附件没有 File Station 路径，所以 `path` 用一个合成键（`chat:<postId>`，
/// 只用于阅读进度/去重，不会拼成 FileStation URL），真正的字节由
/// [openFilePreview] 的 `bytesUrl`（`SYNO.Chat.Post.File/get` + `_sid`）喂进去。
FileEntryDto chatAttachmentAsFileEntry({
  required String name,
  required int postId,
  int size = 0,
  int mtime = 0,
}) => FileEntryDto(name: name, path: 'chat:$postId', size: size, mtime: mtime);

/// 下载附件到临时目录并用系统程序打开。
///
/// 返回 null 表示成功，否则是给用户看的错误文案。
Future<String?> openAttachment(
  ChatApi? api,
  PostDto post,
  FilePropDto prop, {
  String? localPath,
  AttachmentOpener opener = _defaultOpener,
  String? saveDir,
  String? savePath,
  AttachmentAccess? access,
  bool allowStreaming = false,
  MediaStreamOpener? streamOpener,
  DownloadTask? task,
  AppText? text,
}) async {
  final t = text ?? currentText();
  // 上传中的本地图片直接打开
  if (localPath != null && await File(localPath).exists()) {
    await opener(localPath);
    return null;
  }
  if (api == null || post.postId <= 0) return t.chatErrNoServerPost;
  // 音频/视频：把带 `_sid` 的直链交给外部播放器（原版 `VideoUtil.openStreaming`），
  // 不落盘、不整份下载。加密频道 / 证书不受信任的情形由调用方提前拦掉
  // （`allowStreaming = false`），因为外部播放器既拿不到密钥也认不了我们的指纹。
  if (allowStreaming) {
    final name = access?.decodeName(prop.label) ?? prop.label;
    if (isStreamingFile(name)) {
      final url = api.fileUrl(post.postId);
      final ok = await (streamOpener ?? defaultMediaStreamOpener)(
        url,
        mimeForFileName(name),
      );
      if (ok) return null;
      return kNoStreamHandler;
    }
  }
  final path = await resolveAttachmentPath(
    api,
    post,
    prop,
    saveDir: saveDir,
    savePath: savePath,
    access: access,
  );
  try {
    final err = await downloadAttachment(
      api,
      post,
      prop,
      path: path,
      access: access,
      task: task,
      text: text,
    );
    if (err != null) return err;
    final result = await opener(path);
    if (result.type == ResultType.done) return null;
    return t.chatErrNoAppForTypeSaved(path);
  } on DownloadCancelledException {
    // 用户取消：交给上层静默处理（不要变成"打开失败"）
    rethrow;
  } catch (e) {
    return t.chatErrOpenFailed(userFacingError(e));
  }
}

/// 附件落盘路径（加密频道用解密后的真名；文件名里的非法字符替换掉）
Future<String> resolveAttachmentPath(
  ChatApi? api,
  PostDto post,
  FilePropDto prop, {
  String? saveDir,
  String? savePath,
  AttachmentAccess? access,
}) async {
  if (savePath != null) return savePath;
  final dir =
      saveDir == null
            ? await Directory.systemTemp.createTemp('chat_att')
            : Directory(saveDir)
        ..createSync(recursive: true);
  final safe = (access?.decodeName(prop.label) ?? prop.label).replaceAll(
    RegExp(r'[\\/:*?"<>|]'),
    '_',
  );
  return '${dir.path}/$safe';
}

/// **只下载**（不打开）：加密频道走解密、普通频道走 `Post.File get`。
/// 返回 null 表示成功，否则是给用户看的错误文案。
///
/// 另存到「下载」目录 / 分享（原版 `DownloadFragment` 的 option 1、2）都复用它。
Future<String?> downloadAttachment(
  ChatApi? api,
  PostDto post,
  FilePropDto prop, {
  required String path,
  AttachmentAccess? access,
  DownloadTask? task,
  AppText? text,
}) async {
  final t = text ?? currentText();
  if (api == null || post.postId <= 0) return t.chatErrNoServerPost;
  try {
    final bytes = access != null
        ? await access.bytes(
            post.postId,
            onProgress: task?.report,
            cancelToken: task?.cancelToken,
          )
        : await api.downloadPostFile(
            post.postId,
            onProgress: task?.report,
            cancelToken: task?.cancelToken,
          );
    if (bytes == null) return t.chatErrDecryptKey;
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(bytes);
    return null;
  } on DownloadCancelledException {
    rethrow;
  } catch (e) {
    return t.chatErrDownloadFailed(userFacingError(e));
  }
}

/// 一条消息的附件区域
class AttachmentList extends ConsumerWidget {
  const AttachmentList({
    super.key,
    required this.post,
    this.api,
    this.pendingLocalPath,
    this.onError,
    this.access,
  });

  final PostDto post;
  final ChatApi? api;

  /// 加密频道的附件访问器（null = 普通频道，走 URL）
  final AttachmentAccess? access;

  /// 上传中的本地文件（还没拿到 post_id 时先预览）
  final String? pendingLocalPath;
  final void Function(String message)? onError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final props = post.attachments;
    if (props.isEmpty && pendingLocalPath == null) {
      return const SizedBox.shrink();
    }
    // 图片在附件里的序号（Hero tag 与查看器分页都用它，两处必须一致）。
    // postId <= 0（上传中的本地图）没有可转场的查看器，别给 tag —— 否则多条
    // 本地图会共用 `image-0-0`，同路由重复 tag 会触发 Hero 断言。
    final images = props.where((p) => p.showsThumbnail).toList(growable: false);
    var imageIndex = 0;
    final children = <Widget>[];
    for (final p in props) {
      final isImage = p.showsThumbnail;
      final tag = isImage && post.postId > 0
          ? imageHeroTag(post.postId, imageIndex)
          : null;
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _build(
            context,
            ref,
            p,
            heroTag: tag,
            images: images,
            imageIndex: isImage ? imageIndex++ : 0,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _build(
    BuildContext context,
    WidgetRef ref,
    FilePropDto prop, {
    String? heroTag,
    List<FilePropDto> images = const [],
    int imageIndex = 0,
  }) {
    if (prop.showsThumbnail) {
      return _ImageBubble(
        post: post,
        prop: prop,
        api: api,
        pendingLocalPath: pendingLocalPath,
        onError: onError,
        access: access,
        heroTag: heroTag,
        images: images,
        imageIndex: imageIndex,
      );
    }
    if (prop.isVoiceMessage) {
      return VoiceBubble(post: post, prop: prop, api: api, access: access);
    }
    if (prop.isSnippet && prop.snippetPreview.isNotEmpty) {
      return _SnippetBubble(
        prop: prop,
        label: access?.decodeName(prop.label) ?? prop.label,
        onOpen: () => _open(context, ref, prop),
      );
    }
    return _FileBubble(
      prop: prop,
      label: access?.decodeName(prop.label) ?? prop.label,
      onOpen: () => _open(context, ref, prop),
    );
  }

  /// 点附件：音频/视频优先**串流给外部播放器**，其余（以及加密频道 /
  /// 证书不受信任 / 缓存里已有整份文件）走"下载后打开"。
  ///
  /// 原版对照：`ChannelFragment.onOpen` → `VideoUtil.ExistInDownloadCache`
  /// → 缓存命中就下载对话框；`isStreaming` 且加密频道 → `handleEncryptedStreaming`
  /// （一次性确认）；证书不受信任 → `handleIllegalCertificateStreaming`；
  /// 否则 `openStreaming`。缓存命中时原版也弹下载框（等于直接打开本地文件），
  /// 我们直接开本地那份。
  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    FilePropDto prop,
  ) async {
    final t = context.t;
    final name = access?.decodeName(prop.label) ?? prop.label;
    final encrypted = access != null;
    final certUntrusted = ref.read(chatSessionControllerProvider).certUntrusted;
    final streaming = isStreamingFile(name);
    // await 之前把要用的 provider 一次性取好：widget 卸载后 `ref` 就不能再碰了
    // （riverpod 3 会抛 "Using ref ... unmounted"），异步续体只依赖这些局部
    // 引用 —— 否则长下载/弹框结束时 widget 已卸载，续体就炸在外面。
    final cacheService = ref.read(cacheServiceProvider);
    final cacheLimit = ref.read(cacheLimitProvider);
    final streamOpener = ref.read(mediaStreamOpenerProvider);
    final settings = ref.read(settingsServiceProvider);

    // 1) 缓存里已经有整份文件 → 直接开本地的（不再重复下载/串流）
    if (streaming) {
      final cached = await cacheService.pathFor(post.postId, name);
      if (post.postId > 0 && await File(cached).exists()) {
        final result = await _defaultOpener(cached);
        if (result.type != ResultType.done && context.mounted) {
          onError?.call(t.chatErrNoAppForTypeAt(cached));
        }
        return;
      }
    }

    // 2) 加密频道 / 证书不受信任：先一次性确认，再改成下载
    var allowStreaming = streaming;
    if (streaming && post.postId > 0 && (encrypted || certUntrusted)) {
      final skip = encrypted
          ? await settings.streamingEncryptedMessage()
          : await settings.streamingIllegalCertificate();
      if (!skip && context.mounted) {
        final proceed = await _confirmDownload(context, encrypted: encrypted);
        if (!proceed) return;
      }
      allowStreaming = false;
    }

    // 3) 串流：没有应用能处理该 MIME → 弹"打开方式"再试一次
    if (allowStreaming && post.postId > 0 && api != null) {
      final url = api!.fileUrl(post.postId);
      if (await streamOpener(url, mimeForFileName(name))) return;
      if (!context.mounted) return;
      final mime = await showOpenAsDialog(context);
      if (mime == null) return;
      if (!await streamOpener(url, mime) && context.mounted) {
        onError?.call(t.chatErrNoAppForType);
      }
      return;
    }

    // 3.5) ★ 普通文件优先交给**内置阅读器**（§2.0.8 ④）。
    //   以前这里一律"下载到缓存目录 → `open_filex` 交给外部 App"，于是收到的
    //   Word/PDF/电子书在 App 里**根本没有阅读器入口**（用户报告第 4 条）。
    //   现在按 Files/Drive 的**同一个**入口 `openFilePreview` 打开：
    //     * 字节走 `SYNO.Chat.Post.File/get`（带 `_sid` 的鉴权直链，Dio+信任库）；
    //     * 类型分流（pdf / office / 电子书 / 文本 / 图片 / 音视频）与文件模块完全一致；
    //     * 不认识的类型由预览页给出**明确**的"用其它应用打开"页，而不是静默无反应。
    //   加密频道（`access != null`）/ 证书不受信任的直链拿不到可用 URL，仍走老路。
    final chatApi = api;
    if (!streaming && !encrypted && post.postId > 0 && chatApi != null) {
      // 上面几个 await（读设置/确认框）可能已经把页面关掉了
      if (!context.mounted) return;
      openFilePreview(
        context,
        chatAttachmentAsFileEntry(
          name: name,
          postId: post.postId,
          size: prop.size,
          mtime: post.updateAt,
        ),
        bytesUrl: chatApi.fileUrl(post.postId),
      );
      return;
    }

    // 4) 普通文件 / 被拦下来的流媒体：下载后打开（顺带写进缓存目录，
    //    下次点就直接命中第 1 步）
    final cachePath = post.postId > 0
        ? await cacheService.pathFor(post.postId, name)
        : null;
    String? err;
    final needsNetwork = post.postId > 0 && pendingLocalPath == null;
    if (needsNetwork) {
      // 走网络下载 → 先弹进度框（原版 `DownloadFragment`：正在下载 + 文件名 +
      // 进度 + 取消；服务端没给长度时转圈）
      if (!context.mounted) return;
      final outcome = await runWithDownloadDialog(context, (task) async {
        err = await openAttachment(
          api,
          post,
          prop,
          localPath: pendingLocalPath,
          access: access,
          savePath: cachePath,
          allowStreaming: false,
          task: task,
          text: t,
        );
      }, filename: name);
      // 取消：原版直接关框，不弹错误
      if (outcome == kDownloadCancelled) return;
      if (outcome != null) {
        // 下载期间 widget 可能已被卸载 —— 不能再往父级 context 弹提示。
        if (context.mounted) onError?.call(outcome);
        return;
      }
    } else {
      err = await openAttachment(
        api,
        post,
        prop,
        localPath: pendingLocalPath,
        access: access,
        savePath: cachePath,
        allowStreaming: false,
        text: t,
      );
    }
    if (err == kNoStreamHandler) {
      if (context.mounted) onError?.call(t.chatErrNoAppForType);
      return;
    }
    // err 是在闭包里赋值的，取个局部量才能做空提升
    final message = err;
    if (message != null) {
      if (context.mounted) onError?.call(message);
      return;
    }
    if (cachePath != null) {
      // 缓存账用 await 前取好的 service：即使 widget 已经卸载，这是纯数据层
      // 收尾（刷新 mtime / 按上限淘汰），不该也不需要通过 `ref` 再走一遍。
      await cacheService.touch(cachePath);
      await cacheService.enforceLimit(cacheLimit, protect: {cachePath});
    }
  }
}

/// 加密频道 / 证书不受信任时的"改为下载"确认框（原版
/// `download_video_for_enc_channel` / `download_video_for_untrusted_server`）。
/// 返回 true = 用户点确定（继续下载）。
Future<bool> _confirmDownload(
  BuildContext context, {
  required bool encrypted,
}) async {
  final t = context.t;
  var skip = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(
          encrypted
              ? t.chatStreamEncryptedTitle
              : t.chatStreamUntrustedCertTitle,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              encrypted
                  ? t.chatStreamEncryptedHint
                  : t.chatStreamUntrustedCertHint,
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => setState(() => skip = !skip),
              child: Row(
                children: [
                  Checkbox(
                    value: skip,
                    onChanged: (v) => setState(() => skip = v ?? false),
                  ),
                  Text(t.chatSkipAgain),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.actionOk),
          ),
        ],
      ),
    ),
  );
  if (skip) {
    // 上面 await 过弹框，取 container 之前确认还在树上
    if (!context.mounted) return ok == true;
    final store = ProviderScope.containerOf(context, listen: false);
    final settings = store.read(settingsServiceProvider);
    if (encrypted) {
      await settings.setStreamingEncryptedMessage(true);
    } else {
      await settings.setStreamingIllegalCertificate(true);
    }
  }
  return ok == true;
}

/// "打开方式"（原版 `open_as_action`：文本 / 音频 / 视频 / 图片）。
/// 返回选中的 MIME，取消返回 null。
Future<String?> showOpenAsDialog(BuildContext context) {
  final t = context.t;
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(t.chatOpenAsTitle),
      children: [
        for (final (mime, label) in openAsChoices(t))
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(mime),
            child: Text(label),
          ),
      ],
    ),
  );
}

/// 图片查看器的 Hero tag：缩略图与查看器**必须**由同一个函数生成，
/// 否则 tag 配不上就没有转场。postId + 图片序号保证同一条消息的多张图互不冲突。
String imageHeroTag(int postId, int index) => 'image-$postId-$index';

/// 遥测字色。主题里没注册 `DesignPalette` 时（老用例直接 `MaterialApp(home:)`）
/// 退回 `colorScheme`，既不硬编码颜色也不会因为拿不到扩展而崩。
Color _metaColor(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<DesignPalette>()?.dim ??
      theme.colorScheme.onSurfaceVariant;
}

// ---------------------------------------------------------------- 图片
class _ImageBubble extends StatefulWidget {
  const _ImageBubble({
    required this.post,
    required this.prop,
    this.api,
    this.pendingLocalPath,
    this.onError,
    this.access,
    this.heroTag,
    this.images = const [],
    this.imageIndex = 0,
  });

  final PostDto post;
  final FilePropDto prop;
  final ChatApi? api;
  final String? pendingLocalPath;
  final void Function(String message)? onError;
  final AttachmentAccess? access;

  /// Hero tag（null = 不是图片序号里的可转场项）
  final String? heroTag;

  /// 同一条消息里的全部图片附件（点开时交给查看器做 PageView）
  final List<FilePropDto> images;
  final int imageIndex;

  @override
  State<_ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<_ImageBubble> {
  /// 加密频道的解密 Future：用 `??=` 缓存，避免每次 build 都重新整份下载 + 解密
  /// （照 `sticker_view.dart` 的写法）。postId / access 变了才失效。
  Future<List<int>?>? _future;

  @override
  void didUpdateWidget(_ImageBubble old) {
    super.didUpdateWidget(old);
    // ⚠️ `attachmentAccessFor` 每次调用都 new 一个实例，所以不能比 identity；
    // 只有 postId / 是否加密 / 频道变了才让缓存失效，否则重建一次就重解密一次。
    final channelChanged = old.access?.channelId != widget.access?.channelId;
    final encryptedChanged = (old.access == null) != (widget.access == null);
    if (old.post.postId != widget.post.postId ||
        channelChanged ||
        encryptedChanged) {
      _future = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final post = widget.post;
    final prop = widget.prop;
    final access = widget.access;
    final local = widget.pendingLocalPath;
    final width = (prop.imageWidth > 0 ? prop.imageWidth : 220).toDouble();
    final height = (prop.imageHeight > 0 ? prop.imageHeight : 160).toDouble();
    // 别让一张图占满屏幕：等比缩到 260 宽 / 320 高以内
    final maxW = 260.0;
    final maxH = 320.0;
    final scale = (width / maxW) > (height / maxH)
        ? width / maxW
        : (height / maxH);
    final w = scale > 1 ? width / scale : width;
    final h = scale > 1 ? height / scale : height;

    // 按显示尺寸 × 设备像素比解码：4000px 的原图按原尺寸解一张就 ~64MB
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheW = (w * dpr).round();
    final cacheH = (h * dpr).round();

    Widget image;
    if (local != null && File(local).existsSync()) {
      image = Image.file(
        File(local),
        width: w,
        height: h,
        fit: BoxFit.cover,
        cacheWidth: cacheW,
        cacheHeight: cacheH,
      );
    } else if (access != null && post.postId > 0) {
      // 加密频道：服务端缩略图是密文，整份下载 + 解密后再画
      _future ??= access.bytes(post.postId);
      image = FutureBuilder<List<int>?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return SizedBox(
              width: w,
              height: h,
              child: const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final bytes = snap.data;
          if (bytes == null || bytes.isEmpty) return _placeholder(theme, w, h);
          return Image.memory(
            Uint8List.fromList(bytes),
            width: w,
            height: h,
            fit: BoxFit.cover,
            cacheWidth: cacheW,
            cacheHeight: cacheH,
          );
        },
      );
    } else if (widget.api != null && post.postId > 0) {
      // 缩略图 type 是尺寸串（原版气泡用 L），不是 MIME
      final thumbUrl = widget.api!.fileUrl(
        post.postId,
        thumbnail: true,
        size: ChatApi.thumbLarge,
      );
      // ★ 必须走**鉴权的字节通道**（见 `chat_image.dart` 的根因说明）：
      // `Image.network` 用 Dart 自带 `HttpClient`，对 NAS 自签证书
      // `HandshakeException` ⇒ 真机"图片永远不显示"。
      image = ChatRemoteImage(
        url: thumbUrl,
        width: w,
        height: h,
        fit: BoxFit.cover,
        cacheWidth: cacheW,
        cacheHeight: cacheH,
        loading: SizedBox(
          width: w,
          height: h,
          child: const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        failure: _placeholder(theme, w, h),
      );
    } else {
      image = _placeholder(theme, w, h);
    }

    // 缩略图圆角统一走 Radii.embed（原版各处 10/16 混用，这里是内嵌内容）
    final content = ClipRRect(
      borderRadius: BorderRadius.circular(Radii.embed),
      child: image,
    );
    final tag = widget.heroTag;

    return InkWell(
      borderRadius: BorderRadius.circular(Radii.embed),
      onTap: () {
        final api = widget.api;
        if (api == null || post.postId <= 0) {
          if (local != null) openAttachment(null, post, prop, localPath: local);
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ImageViewerPage(
              url: access != null ? '' : api.fileUrl(post.postId),
              title: access?.decodeName(prop.label) ?? prop.label,
              api: api,
              post: post,
              prop: prop,
              access: access,
              // 多图时带上整条消息的图片列表，查看器里左右滑切换
              images: widget.images,
              initialIndex: widget.imageIndex,
            ),
          ),
        );
      },
      child: tag == null ? content : Hero(tag: tag, child: content),
    );
  }

  Widget _placeholder(ThemeData theme, double w, double h) => Container(
    width: w,
    height: h,
    color: theme.colorScheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: Icon(
      Icons.image_not_supported_outlined,
      color: theme.colorScheme.onSurfaceVariant,
    ),
  );
}

/// 全屏看图：Hero 转场 + 双指缩放 + 双击放大/还原 + 多图左右切 + 下滑关闭 +
/// 长按（/右上角）「保存到下载 / 分享 / 用其它应用打开」。
///
/// 原版对照：`ImagePagerFragment` 的 `Callbacks.onDownload`（=> `DownloadFragment`
/// option 1）与 `Callbacks.onShare`（=> option 2）。
///
/// 手势实现说明：`InteractiveViewer` 内部**始终**注册了 `ScaleGestureRecognizer`，
/// 单指横滑会被它吃掉（[flutter#57913]），所以页面切换/下滑关闭用**更靠内层**的
/// `GestureDetector`（在 InteractiveViewer 的 child 里）来抢手势；放大后把这些
/// 单指手势让回 InteractiveViewer 做平移。
class ImageViewerPage extends ConsumerStatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.url,
    required this.title,
    this.api,
    this.post,
    this.prop,
    this.access,
    this.images,
    this.initialIndex = 0,
  });

  final String url;
  final String title;
  final ChatApi? api;
  final PostDto? post;
  final FilePropDto? prop;

  /// 加密频道：看原图也要先下载 + 解密
  final AttachmentAccess? access;

  /// 同一条消息里的全部图片附件；多于一张才包 `PageView`（单图不包，避免
  /// 无意义的手势竞争）
  final List<FilePropDto>? images;

  /// 打开时定位到第几张
  final int initialIndex;

  @override
  ConsumerState<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends ConsumerState<ImageViewerPage>
    with TickerProviderStateMixin {
  /// 双击放大的目标倍数（1 ↔ 2.5 平滑过渡）
  static const double _zoomScale = 2.5;

  /// 下滑关闭的位移阈值（px）
  static const double _closeThreshold = 120;

  late final List<TransformationController> _transforms;
  late final PageController _pages;
  late final AnimationController _zoom;
  late final AnimationController _drag;
  Animation<Matrix4>? _zoomTween;
  Animation<double>? _dragTween;

  /// 加密频道的解密 Future（缓存，避免每帧重建都重新下载 + 解密）
  Future<List<int>?>? _decrypt;

  int _index = 0;

  /// 当前页是否已放大（放大后单指横/竖手势交回 InteractiveViewer 平移）
  bool _zoomed = false;

  /// 下滑关闭的跟手位移 / 横滑切页的跟手位移
  double _dragY = 0;
  double _pageDrag = 0;

  /// 双击落点（相对视口），用于「放大到点到的地方」
  Offset? _tapPoint;

  bool get _multi => (widget.images?.length ?? 0) > 1;
  int get _count => _multi ? widget.images!.length : 1;

  FilePropDto? _propAt(int i) => _multi ? widget.images![i] : widget.prop;

  String _titleAt(int i) {
    final p = _propAt(i);
    if (p == null) return widget.title;
    return widget.access?.decodeName(p.label) ?? p.label;
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, _count - 1);
    _transforms = List.generate(_count, (_) => TransformationController());
    for (final t in _transforms) {
      t.addListener(_onTransformChanged);
    }
    _pages = PageController(initialPage: _index);
    _zoom = AnimationController(vsync: this, duration: Motion.base)
      ..addListener(() {
        final v = _zoomTween?.value;
        if (v != null) _transforms[_index].value = v;
      });
    _drag = AnimationController(vsync: this, duration: Motion.fast)
      ..addListener(() {
        final v = _dragTween?.value;
        if (v != null && mounted) setState(() => _dragY = v);
      });
    final postId = widget.post?.postId ?? 0;
    if (widget.access != null && postId > 0) {
      _decrypt = widget.access!.bytes(postId);
    }
  }

  @override
  void dispose() {
    for (final t in _transforms) {
      t.removeListener(_onTransformChanged);
      t.dispose();
    }
    _pages.dispose();
    _zoom.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final zoomed = _transforms[_index].value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed && mounted) setState(() => _zoomed = zoomed);
  }

  // ------------------------------------------------------------ 缩放
  void _animateZoom(TransformationController ctrl, Matrix4 target) {
    _zoomTween = Matrix4Tween(begin: ctrl.value, end: target).animate(
      CurvedAnimation(parent: _zoom, curve: Motion.resolveCurve(Motion.out)),
    );
    _zoom.duration = Motion.resolve(Motion.base);
    _zoom.forward(from: 0);
  }

  void _toggleZoom() {
    final ctrl = _transforms[_index];
    if (ctrl.value.getMaxScaleOnAxis() > 1.01) {
      _animateZoom(ctrl, Matrix4.identity());
      return;
    }
    // 以双击点为锚放大：T·S 作用到点上等于把该点钉住
    final p = _tapPoint ?? Offset.zero;
    final size = MediaQuery.sizeOf(context);
    var tx = -p.dx * (_zoomScale - 1);
    var ty = -p.dy * (_zoomScale - 1);
    tx = tx.clamp(-size.width * (_zoomScale - 1), 0.0);
    ty = ty.clamp(-size.height * (_zoomScale - 1), 0.0);
    _animateZoom(
      ctrl,
      Matrix4.identity()
        ..translateByDouble(tx, ty, 0, 1)
        ..scaleByDouble(_zoomScale, _zoomScale, 1, 1),
    );
  }

  // ------------------------------------------------------------ 下滑关闭
  void _onDragUpdate(DragUpdateDetails d) {
    setState(() => _dragY = (_dragY + d.delta.dy).clamp(0.0, 600.0));
  }

  void _onDragEnd(DragEndDetails d) {
    if (_dragY > _closeThreshold || d.velocity.pixelsPerSecond.dy > 900) {
      Navigator.of(context).maybePop();
      return;
    }
    // 没到阈值：弹回原位（减少动效时直接归零）
    if (!Motion.enabled) {
      setState(() => _dragY = 0);
      return;
    }
    _dragTween = Tween<double>(
      begin: _dragY,
      end: 0,
    ).animate(CurvedAnimation(parent: _drag, curve: Motion.out));
    _drag.duration = Motion.fast;
    _drag.forward(from: 0);
  }

  // ------------------------------------------------------------ 左右切图
  void _onPageDragStart(DragStartDetails d) => _pageDrag = 0;

  void _onPageDragUpdate(DragUpdateDetails d) =>
      setState(() => _pageDrag += d.delta.dx);

  void _onPageDragEnd(DragEndDetails d) {
    final width = MediaQuery.sizeOf(context).width;
    final v = d.velocity.pixelsPerSecond.dx;
    var target = _index;
    if (_pageDrag < -width * 0.18 || v < -700) target = _index + 1;
    if (_pageDrag > width * 0.18 || v > 700) target = _index - 1;
    target = target.clamp(0, _count - 1);
    setState(() => _pageDrag = 0);
    if (_pages.hasClients && target != _index) {
      _pages.animateToPage(
        target,
        duration: Motion.resolve(Motion.base),
        curve: Motion.resolveCurve(Motion.out),
      );
    }
  }

  void _onPageChanged(int i) {
    setState(() {
      _index = i;
      _dragY = 0;
      _pageDrag = 0;
      _zoomed = _transforms[i].value.getMaxScaleOnAxis() > 1.01;
    });
  }

  // ------------------------------------------------------------ 操作面板
  void _showActions() {
    final post = widget.post;
    final api = widget.api;
    final t = context.t;
    final f = _propAt(_index) ?? widget.prop;
    if (api == null || post == null || f == null) return;
    HapticFeedbackCompat.medium();
    final name = widget.access?.decodeName(f.label) ?? f.label;
    showAppSheet<void>(
      context,
      title: t.chatMediaImage,
      children: [
        AppSheetSection(
          children: [
            AppSheetAction(
              icon: Icons.download_outlined,
              label: t.chatSaveToDownloads,
              description: name,
              onTap: () {
                Navigator.of(context).pop();
                _save(f, name);
              },
            ),
            AppSheetAction(
              icon: Icons.share_outlined,
              label: t.chatShare,
              onTap: () {
                Navigator.of(context).pop();
                _share(f, name);
              },
            ),
            AppSheetAction(
              icon: Icons.open_in_new,
              label: t.chatOpenWithOtherApp,
              onTap: () {
                Navigator.of(context).pop();
                _openExternal(f);
              },
            ),
          ],
        ),
      ],
    );
  }

  Future<String> _cachePath(FilePropDto f) async {
    final name = widget.access?.decodeName(f.label) ?? f.label;
    return ref.read(cacheServiceProvider).pathFor(widget.post!.postId, name);
  }

  Future<void> _save(FilePropDto f, String name) async {
    final t = context.t;
    final api = widget.api;
    final post = widget.post;
    if (api == null || post == null) return;
    final path = await _cachePath(f);
    if (!mounted) return;
    final outcome = await saveAttachmentToDownloads(
      context,
      api: api,
      post: post,
      access: widget.access,
      cachePath: path,
      name: name,
      text: t,
    );
    if (!mounted || outcome.cancelled) return;
    final err = outcome.error;
    AppSnack.show(
      context,
      err ?? t.chatSavedToDownloads(name),
      error: err != null,
    );
  }

  Future<void> _share(FilePropDto f, String name) async {
    final t = context.t;
    final api = widget.api;
    final post = widget.post;
    if (api == null || post == null) return;
    final path = await _cachePath(f);
    if (!mounted) return;
    final err = await shareAttachment(
      context,
      api: api,
      post: post,
      access: widget.access,
      cachePath: path,
      name: name,
      text: t,
    );
    if (err != null && mounted) AppSnack.show(context, err, error: true);
  }

  Future<void> _openExternal(FilePropDto f) async {
    final err = await openAttachment(
      widget.api,
      widget.post!,
      f,
      access: widget.access,
    );
    if (err != null && mounted) AppSnack.show(context, err, error: true);
  }

  // ------------------------------------------------------------ 渲染
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // 图片垫在顶栏下面，玻璃 AppBar 才能透出图（顶栏颜色交给 AppBarTheme）
      extendBodyBehindAppBar: true,
      backgroundColor: scheme.scrim.withValues(alpha: 0.92),
      appBar: AppBar(
        title: Text(_titleAt(_index), overflow: TextOverflow.ellipsis),
        actions: [
          if (_count > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Center(
                child: Text(
                  '${_index + 1}/$_count',
                  style: TextStyle(
                    fontSize: DesignType.labelSmallSize,
                    color: DesignPalette.of(context).dim,
                  ),
                ),
              ),
            ),
          if (widget.api != null && widget.post != null)
            IconButton(
              tooltip: context.t.chatImageActions,
              icon: const Icon(Icons.more_vert),
              onPressed: _showActions,
            ),
        ],
      ),
      body: _multi
          ? PageView.builder(
              controller: _pages,
              itemCount: _count,
              onPageChanged: _onPageChanged,
              itemBuilder: _buildPage,
            )
          : _buildPage(context, 0),
    );
  }

  /// 单张图片按屏幕尺寸 × 像素比解码（查看器也不需要 4000px 原始分辨率）
  Widget _buildPage(BuildContext context, int i) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final size = MediaQuery.sizeOf(context);
    final cacheW = (size.width * dpr).round();
    final cacheH = (size.height * dpr).round();
    final postId = widget.post?.postId ?? 0;

    Widget image;
    if (widget.access != null) {
      image = FutureBuilder<List<int>?>(
        future: _decrypt,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final bytes = snap.data;
          if (bytes == null || bytes.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Text(
                context.t.chatErrDecryptKey,
                style: TextStyle(color: scheme.onInverseSurface),
              ),
            );
          }
          return Image.memory(
            Uint8List.fromList(bytes),
            fit: BoxFit.contain,
            cacheWidth: cacheW,
            cacheHeight: cacheH,
            gaplessPlayback: true,
          );
        },
      );
    } else {
      final url = widget.url.isNotEmpty
          ? widget.url
          : (widget.api != null ? widget.api!.fileUrl(postId) : '');
      final failed = Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Text(
          context.t.chatImageLoadFailed,
          style: TextStyle(color: scheme.onInverseSurface),
        ),
      );
      image = url.isEmpty
          ? failed
          : ChatRemoteImage(
              url: url,
              fit: BoxFit.contain,
              cacheWidth: cacheW,
              cacheHeight: cacheH,
              loading: const Center(child: CircularProgressIndicator()),
              failure: failed,
            );
    }

    final hero = Hero(
      tag: imageHeroTag(postId, i),
      // 转场时先显示缩略图那边已加载好的画面，别在飞行中闪一个转圈
      flightShuttleBuilder:
          (flightContext, animation, direction, fromContext, toContext) {
            final hero = direction == HeroFlightDirection.push
                ? fromContext.widget
                : toContext.widget;
            return (hero as Hero).child;
          },
      child: image,
    );

    return InteractiveViewer(
      transformationController: _transforms[i],
      minScale: 1,
      maxScale: 6,
      // 放大后才允许内部平移；未放大时把单指手势让给内层的切页/下滑关闭
      panEnabled: _zoomed,
      child: SizedBox.expand(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTapDown: (d) => _tapPoint = d.localPosition,
          onDoubleTap: _toggleZoom,
          onLongPress: _showActions,
          onVerticalDragUpdate: _zoomed ? null : _onDragUpdate,
          onVerticalDragEnd: _zoomed ? null : _onDragEnd,
          onHorizontalDragStart: _multi && !_zoomed ? _onPageDragStart : null,
          onHorizontalDragUpdate: _multi && !_zoomed ? _onPageDragUpdate : null,
          onHorizontalDragEnd: _multi && !_zoomed ? _onPageDragEnd : null,
          child: Transform.translate(
            offset: Offset(_pageDrag * 0.25, _dragY),
            child: Opacity(
              // 下滑时跟着淡出，给"要关掉了"的反馈
              opacity: (1 - _dragY / 500).clamp(0.25, 1.0),
              child: Center(child: hero),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 文本预览
class _SnippetBubble extends StatelessWidget {
  const _SnippetBubble({
    required this.prop,
    required this.onOpen,
    required this.label,
  });

  final FilePropDto prop;

  /// 显示用文件名（加密频道里是解出来的真名）
  final String label;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = prop.snippetPreview;
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.embed),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.description_outlined, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              // meta（大小）走设计令牌的次级字（r502：不再用等宽遥测字）
              Text(
                prop.humanSize,
                style: TextStyle(
                  fontSize: DesignType.labelSmallSize,
                  color: _metaColor(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(prop.label),
                content: SizedBox(
                  width: 520,
                  child: SingleChildScrollView(
                    child: SelectableText(
                      prop.snippetPreview,
                      style: kCodeStyle,
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(context.t.photoClose),
                  ),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onOpen();
                    },
                    child: Text(context.t.chatOpenFile),
                  ),
                ],
              ),
            ),
            child: Text(
              preview,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: kCodeStyle,
            ),
          ),
          if (prop.snippetPreviewMore)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '…',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 文件
class _FileBubble extends StatelessWidget {
  const _FileBubble({
    required this.prop,
    required this.onOpen,
    required this.label,
  });

  final FilePropDto prop;

  /// 显示用文件名（加密频道里是解出来的真名）
  final String label;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(Radii.embed),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.embed),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _iconFor(prop.extension),
              size: 28,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  // meta（大小 · 类型）走设计令牌的次级字
                  Text(
                    [
                      prop.humanSize,
                      if (prop.extension.isNotEmpty)
                        prop.extension.toUpperCase(),
                    ].where((s) => s.isNotEmpty).join(' · '),
                    style: TextStyle(
                      fontSize: DesignType.labelSmallSize,
                      color: _metaColor(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.download_outlined, size: 18),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(String ext) {
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'doc':
      case 'docx':
        return Icons.article_outlined;
      case 'xls':
      case 'xlsx':
      case 'csv':
        return Icons.table_chart_outlined;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow_outlined;
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return Icons.folder_zip_outlined;
      case 'mp3':
      case 'wav':
      case 'aac':
      case 'm4a':
        return Icons.audiotrack_outlined;
      case 'mp4':
      case 'mov':
      case 'mkv':
        return Icons.movie_outlined;
      case 'txt':
      case 'md':
      case 'log':
        return Icons.text_snippet_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}

// ---------------------------------------------------------------- 语音
/// 语音气泡：点一下播放/暂停，播放时显示进度。
///
/// 播放地址用带 `_sid` 的 `Post.File/get`（和图片一样，不用自己管 cookie）。
class VoiceBubble extends ConsumerStatefulWidget {
  const VoiceBubble({
    super.key,
    required this.post,
    required this.prop,
    this.api,
    this.access,
  });

  final PostDto post;
  final FilePropDto prop;
  final ChatApi? api;
  final AttachmentAccess? access;

  /// 语音条宽度（纯函数，便于直接量判据，不依赖测试字体）。
  ///
  /// ★ DA194：下限不能是 80 —— 7 秒的条只有 ~94dp，**真机上**（测试字体量不出来）
  ///   `Voice message` 装不下会折成两行，同一条会话里语音气泡就高矮不一。
  ///   下限按「标签一行放得下」取 [kVoiceBarMin]；上限 200 不变，
  ///   所以「时长越长条越长」的语义还在。
  static double barWidthFor(int seconds) {
    if (seconds <= 0) return kVoiceBarMin;
    final t = (seconds / kVoiceMaxSeconds).clamp(0.0, 1.0);
    final proportional = 80 + t * 120;
    return proportional < kVoiceBarMin ? kVoiceBarMin : proportional;
  }

  /// 加密频道里的语音要先解密成临时文件再播（`file://` URL）
  Future<String?> resolveUrl() async {
    final api = this.api;
    if (api == null) return null;
    if (access == null) return api.fileUrl(post.postId);
    final bytes = await access!.bytes(post.postId);
    if (bytes == null) return null;
    final dir = await Directory.systemTemp.createTemp('chat_voice');
    final path = '${dir.path}/voice_${post.postId}.aac';
    await File(path).writeAsBytes(bytes);
    return Uri.file(path).toString();
  }

  @override
  ConsumerState<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends ConsumerState<VoiceBubble> {
  String? _failed;
  bool _busy = false;

  /// Start time of the current audition (used to emit a timed complete on stop)
  DateTime? _auditionStartedAt;

  String get _label {
    final seconds = widget.prop.voiceMsgLength;
    if (seconds > 0) return formatVoiceDuration(seconds);
    return widget.prop.humanSize;
  }

  String? get _url {
    if (widget.access != null) return _decryptedUrl;
    final api = widget.api;
    if (api == null) return null;
    return api.fileUrl(widget.post.postId);
  }

  /// 加密频道播放前解出来的本地 URL（播放过一次就复用）
  String? _decryptedUrl;

  /// 静止时的固定长度条：按 `voiceMsgLength` 成比例（min [kVoiceBarMin] / max 200）。
  /// 未播放时不再画 0% 进度条 —— 那会让人以为"内容就是空的/卡住了"。
  double get _barWidth => VoiceBubble.barWidthFor(widget.prop.voiceMsgLength);

  Future<void> _toggle(VoicePlayer player) async {
    if (_busy) return;
    final t = context.t;
    setState(() => _busy = true);
    var url = _url;
    if (url == null && widget.access != null) {
      url = await widget.resolveUrl();
      if (url != null && mounted) setState(() => _decryptedUrl = url);
    }
    if (url == null) {
      trackOnceFailure(
        UsageModule.chat,
        UsageAction.audition,
        objectType: 'voice',
        reason: 'decrypt',
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = t.chatErrDecrypt;
        });
      }
      return;
    }
    try {
      // ★ DA195：片尾时 `currentUrl` 仍是这一条，若照旧判"同源 = 在播"就会走
      //   `pause+stop` —— 用户点一次没声音（真机"片尾重播要点两次"的老毛病）。
      //   片尾必须当成"重新播"。
      final ended =
          player is VoicePlaybackEnded && (player as VoicePlaybackEnded).ended;
      if (player.currentUrl == url && !ended) {
        await player.pause();
        await player.stop();
        _finishAudition();
      } else {
        await player.play(url);
        // analytics: auditioning a voice attachment (object type only)
        _auditionStartedAt = DateTime.now();
        trackOnce(UsageModule.chat, UsageAction.audition, objectType: 'voice');
      }
      // 片尾状态下重新播：`resume()` 内部会 seek(0)，这里再把"已在片尾"清掉，
      // 否则下一次构建仍按已结束渲染（DA195）。
      if (player is VoicePlaybackEnded) {
        (player as VoicePlaybackEnded).clearEnded();
      }
      if (mounted) setState(() => _failed = null);
    } catch (e) {
      trackOnceFailure(
        UsageModule.chat,
        UsageAction.audition,
        objectType: 'voice',
        reason: 'playback',
        error: e,
      );
      // 真机上常见：文件被删 / 网络断了
      if (mounted) setState(() => _failed = t.chatErrPlaybackFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Audition ended (pause/stop) -> emit a timed complete event
  void _finishAudition() {
    final started = _auditionStartedAt;
    if (started == null) return;
    _auditionStartedAt = null;
    trackComplete(
      UsageModule.chat,
      action: UsageAction.audition,
      duration: DateTime.now().difference(started),
      objectType: 'voice',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = ref.watch(voicePlayerProvider);
    return StreamBuilder<void>(
      stream: player.changes,
      builder: (context, _) {
        final url = _url;
        final active = url != null && player.currentUrl == url;
        final total = player.duration;
        final position = player.position;
        // ★ DA195：播完后 `currentUrl` 仍在（just_audio 是 stop+seek(0)，不是清源），
        //   只看 `active` 会把按钮永久停在"暂停 + 空进度条"。必须问播放器
        //   "是不是在片尾"（[VoicePlaybackEnded]，正是为这种漏判加的能力）。
        final ended =
            player is VoicePlaybackEnded &&
            (player as VoicePlaybackEnded).ended;
        final playing =
            active && !ended && total != null && total.inMilliseconds > 0;
        final progress = playing
            ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;
        return InkWell(
          onTap: () => _toggle(player),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.embed),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  // ★ DA195：这里原来按 `active`（"载入了来源"）判 —— 播完之后
                  //   `currentUrl` 还在，于是图标永久停在暂停。必须按 **playing** 判。
                  playing
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                // ★ DA193：这条 Row 是 `mainAxisSize: min`，但里面**全是定宽**（图标 +
                //   `_barWidth` 最多 200dp + 时长），一旦外层气泡的 maxWidth 小一点
                //   （群聊/长昵称/60 秒语音）就必然溢出 —— 而 Flutter **不裁** Row 的溢出，
                //   时长会被画到气泡圆角外面、压在深青底上几乎看不见（真机 1.08:1）。
                //   ⇒ 让"条"可收缩，时长永远留在气泡内。
                Flexible(
                  child: SizedBox(
                    width: _barWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _failed ?? context.t.chatVoiceMessage,
                          // 标签是固定文案，必须单行；宽度下限已保证放得下（DA194）
                          maxLines: 1,
                          softWrap: false,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: _failed != null
                                ? theme.colorScheme.error
                                : null,
                          ),
                        ),
                        const SizedBox(height: 4),
                        // 播放中才是真实进度；静止时是固定长度条（无进度语义）
                        SizedBox(
                          height: 3,
                          child: playing
                              ? LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 3,
                                )
                              : DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.28),
                                    borderRadius: BorderRadius.circular(
                                      Radii.capsule,
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // meta（时长）走设计令牌的次级字
                Text(
                  _label,
                  style: TextStyle(
                    fontSize: DesignType.labelSmallSize,
                    color: _metaColor(context),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
