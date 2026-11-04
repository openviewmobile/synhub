// 加密频道里的附件访问：文件名解码 + 内容解密。
//
// 加密频道的规则（见 `docs/phase7-protocol.md` §1）：
//   * 文件名：`base64` 换成 `hex` 的 secretbox 密文 → 必须解出来才能显示；
//   * 文件内容：`nonce(24) || MAC(16) || 密文` 的**原始字节**；
//   * 缩略图接口服务端没法用（它没有频道密钥），图片只能整份下载再解密。
//
// 非加密频道返回 null，界面继续走原来的 `Image.network` / URL 路径。
import '../../data/chat_api.dart';
import '../../data/e2ee/e2ee_service.dart';
import '../../dsm/webapi.dart';

class AttachmentAccess {
  AttachmentAccess({
    required this.channelId,
    required this.svc,
    required this.api,
  });

  final int channelId;
  final E2eeService svc;
  final ChatApi api;

  /// 服务端存的是 hex 密文；解不开就原样返回（宁可显示乱码也别丢信息）
  String decodeName(String raw) {
    if (raw.isEmpty) return raw;
    final name = svc.tryDecryptFileName(channelId, raw);
    return name ?? raw;
  }

  /// 整份下载并解密（缩略图对 E2EE 频道不适用）
  /// [onProgress] / [cancelToken] 必须一路转发给 `downloadPostFile` ——
  /// 否则**加密频道的下载没有进度、取消无效**（第 38 轮实测：进度框里点
  /// 「取消」后字节仍然到货并落盘 15 字节，因为 `getBytes` 收到的
  /// `cancelToken` 是 `null`）。非加密分支一直是转发的，这里补齐对齐。
  Future<List<int>?> bytes(
    int postId, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
  }) async {
    if (postId <= 0) return null;
    final raw = await api.downloadPostFile(
      postId,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    return svc.tryDecryptFileBytes(channelId, raw);
  }
}
