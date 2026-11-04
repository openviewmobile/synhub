// 备份去重用的**内容哈希** —— 官方 Synology Drive 相机备份的两把尺子。
//
// 逐字证据（`docs/drive-parity-audit.md:274`，反编译官方 Drive 安卓端）：
//
//   ① **抽样 MD5**（本机"这条记录内容变了吗"）：
//      `util/MD5Utils.java:31-47` —— 一次读 `(1000+200)*1024` 字节；
//      文件长度 ≥ 该值时**只取这段的最后 `204800` 字节**（即"前 1.2MB 的
//      最后 200KB"）再做 MD5；文件更短时就是整个文件。
//      `PBUtils.java:164-168` 以 `forLocal=true` 调用；
//      `PBTaskManager.java:240-246` 在时间戳相等时才走这条。
//
//   ② **全文件 MD4**（与服务端已有内容比）：
//      `PhotoBackupManager.java:298-306` `getMD4Hash(file)` + `checkFileExist(mD4Hash,path)`，
//      比对 `FileInfoVo.java:28` 的 `String hash`。
//
// 实现只用**已有依赖** `pointycastle`（`pubspec.yaml` 不许改；`trust_store.dart`
// 已经在用它的 `SHA256Digest`），与官方字节级同构：抽样窗口/长度都照抄，
// 不"顺手改成更合理的算法" —— 那样就和服务端记录对不上了。
//
// ⚠️ 抽样窗口只有 200KB：不同文件**理论上可能撞哈希**。所以账本 token 额外带上
// 文件大小（见 `PhotoBackupQueue.ledgerToken`），把碰撞面收窄；真正的兜底是服务端
// 自己的 `duplicate_hash`（见 `docs/p2-photos-backup-research.md` §1.5）。
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/md4.dart';
import 'package:pointycastle/digests/md5.dart';

import 'photo_backup_queue.dart' show PhotoBackupHasher;

/// 官方 `MD5Utils` 的窗口常量：`(1000 + 200) * 1024`。
const int kSampledMd5WindowBytes = (1000 + 200) * 1024;

/// 窗口内**只取最后**这么多字节（`takeLast(bArr, 204800)`）。
const int kSampledMd5TailBytes = 200 * 1024;

/// 生产实现：`dart:io` + pointycastle。
class FilePhotoBackupHasher implements PhotoBackupHasher {
  const FilePhotoBackupHasher();

  @override
  Future<String> sampledMd5(String localPath) async {
    try {
      final file = File(localPath);
      final length = await file.length();
      if (length <= 0) return '';
      final readBytes = length < kSampledMd5WindowBytes
          ? length
          : kSampledMd5WindowBytes;
      final raf = await file.open();
      try {
        final buffer = Uint8List(readBytes);
        final got = await raf.readInto(buffer);
        if (got <= 0) return '';
        var bytes = got == buffer.length ? buffer : buffer.sublist(0, got);
        // 官方：文件 ≥ 窗口长度时**只**哈希窗口的最后 200KB
        if (length >= kSampledMd5WindowBytes &&
            bytes.length > kSampledMd5TailBytes) {
          bytes = bytes.sublist(bytes.length - kSampledMd5TailBytes);
        }
        return _hex(MD5Digest().process(bytes));
      } finally {
        await raf.close();
      }
    } catch (_) {
      // 算不出来 = 这一项没有抽样哈希（账本退回 stableKey），不抛。
      return '';
    }
  }

  @override
  Future<String> fullMd4(String localPath) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) return '';
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return '';
      return _hex(MD4Digest().process(bytes));
    } catch (_) {
      return '';
    }
  }

  static String _hex(Uint8List bytes) {
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }
}

/// 抽样 MD5 的**纯函数**形态：给定窗口内容与文件长度，算 MD5。
///
/// 拆出来是为了让"官方窗口语义"能被离线用例直接钉住（不用造 1.2MB 真文件）。
String sampledMd5OfWindow(Uint8List window, {required int fileLength}) {
  var bytes = window;
  if (fileLength >= kSampledMd5WindowBytes &&
      window.length > kSampledMd5TailBytes) {
    bytes = window.sublist(window.length - kSampledMd5TailBytes);
  }
  return FilePhotoBackupHasher._hex(MD5Digest().process(bytes));
}

/// 全文件 MD4 的纯函数形态。
String fullMd4OfBytes(Uint8List bytes) =>
    FilePhotoBackupHasher._hex(MD4Digest().process(bytes));
