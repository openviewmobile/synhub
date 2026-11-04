// 聊天里的**远端图片字节**加载（用户报告第 3 条：收到的图片都不显示、
// 点开大图提示"图片加载失败"）。
//
// 根因（真 NAS 只读实测 + 宿主侧 Dart 探针，2026-09-27）：
//   * 图片 URL 形状本身是对的 ——
//     `SYNO.Chat.Post.File / thumbnail|get` + `post_id` + `_sid`
//     （`curl -k` 拿到 HTTP 200 + 540 B JPEG 64×64 / 1023 B 原图）；
//   * 但 `Image.network` 用的是 **Dart 自带的 `HttpClient`**，它既不带
//     `DioFactory` 的信任库、也没有 `badCertificateCallback` ⇒ 对 NAS 的
//     自签证书直接 `HandshakeException: CERTIFICATE_VERIFY_FAILED`。
//     实测：
//       default: FAIL HandshakeException: CERTIFICATE_VERIFY_FAILED …
//       relaxed(badCertificateCallback=true): HTTP 200 bytes=540
//     ⇒ `loadingBuilder` 连第一帧都拿不到，`errorBuilder` 退回占位/文案。
//
// 这和第 259 轮 Photos 的结论一模一样（见 `photo_providers.dart:72`）：
// **凡是 NAS 自签证书的直链，都必须走应用自己的鉴权字节通道**（`api.getBytes`
// → Dio + TrustStore）。所以这里不再用 `Image.network`，改成一个
// `FutureProvider` + `Image.memory`，并在失败时把原因打到 logcat。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import 'chat_session_controller.dart';

/// Riverpod 3 默认对失败的 provider 做指数退避重试 → UI 一直停在 loading。
/// 图片失败就失败，不要偷偷重试。
Duration? _noRetry(int retryCount, Object error) => null;

/// 按 URL 取图片字节（走 `ChatApi.api.getBytes` = Dio + 信任库 + `_sid`）。
final chatImageBytesProvider = FutureProvider.autoDispose.family<Uint8List, String>(
  (ref, url) async {
    final api = ref.watch(chatApiProvider);
    if (api == null) throw StateError(currentText().setNotConnected);
    final bytes = await api.api.getBytes(url);
    if (bytes.isEmpty) {
      throw StateError(currentText().chatImageLoadFailed);
    }
    return Uint8List.fromList(bytes);
  },
  retry: _noRetry,
);

/// 聊天里的远端图片：三态（加载中 / 失败可说出原因 / 成功出图）。
///
/// 为什么单独一个 widget：气泡缩略图、大图查看器、频道媒体页三处都要用，
/// **一个实现**（§2.0.8 ④）。
class ChatRemoteImage extends ConsumerWidget {
  const ChatRemoteImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit,
    this.cacheWidth,
    this.cacheHeight,
    this.loading,
    this.failure,
    this.gaplessPlayback = true,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final int? cacheWidth;
  final int? cacheHeight;

  /// 加载中占位（默认一个转圈）
  final Widget? loading;

  /// 失败占位（默认一个破图标）；失败原因一律 `debugPrint`
  final Widget? failure;

  final bool gaplessPlayback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(chatImageBytesProvider(url));
    return async.when(
      loading: () =>
          loading ??
          SizedBox(
            width: width,
            height: height,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
      error: (e, st) {
        // 真机定位用：release 包也会进 logcat（tag `flutter`）
        debugPrint('[chatImage] FAIL url=$url reason=$e');
        return failure ??
            SizedBox(
              width: width,
              height: height,
              child: const Center(child: Icon(Icons.broken_image_outlined)),
            );
      },
      data: (bytes) => Image.memory(
        bytes,
        width: width,
        height: height,
        fit: fit,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        gaplessPlayback: gaplessPlayback,
      ),
    );
  }
}
