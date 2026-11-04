// 端侧模型的**离线保管库**（Model Vault）。
//
// 背景（用户 2026-09-25 明确要求）：
//   「手机上的端侧模型非常大，也不要反复下载，非常浪费流量，比如你经常为了测试
//   卸载 App，然后重新安装，安装完了如果需要测试端侧模型又得重新下载模型，
//   这样太浪费流量了」
//
// 事实：`flutter_gemma` 把模型放在 `getApplicationSupportDirectory()`，
// Android 上就是 `/data/data/<包名>/files/...` —— **卸载 App 会被一起删掉**。
//
// 解法（**两层**，互为补充）：
//
// ① **保管库**（工作缓存，本模块的主角）
//      `/data/data/<包名>/files/models_vault/<文件名>`
//    App 内"删掉模型"、覆盖安装新构建、清模型列表，都不会动它；
//    `install()` 命中保管库就直接 `fromFile(保管库路径)`
//    （插件对 FileSource 是**原地引用、不拷贝**）⇒ **一条网络请求都不发**。
//
// ② **收件箱**（宿主机送模型进来的口子）
//      `/storage/emulated/0/Android/media/<包名>/models/<文件名>`
//    `scripts/device_model_cache.sh restore` 会把宿主机备份的文件 push 到这里；
//    App 下次启动/打开模型页时把它 **搬进** 保管库（`importInbox()`），
//    搬完删掉收件箱那份，避免同一份模型在卡里躺两遍。
//
// ⚠️ **实测（LGE-AN10 / Android 12）**：卸载 App 后连
//    `Android/media/<包名>/` 一起没了（第 251 轮实测），所以**不能**把
//    "重装后还在"这件事押在手机目录上 —— 那是宿主机备份
//    （`~/synology_samples/device-models/` + `device_model_cache.sh`）的职责。
//
// 单元测试通过 [dirOverride] 注入临时目录，不碰真机路径。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/platform/app_paths.dart';

import 'on_device_ai.dart';

/// 本 App 的 Android 包名（与 `android/app/build.gradle.kts` 的 applicationId 一致）。
///
/// 不查 `package_info_plus` 是为了让本模块在纯 Dart 测试里也能跑。
const String kAndroidPackageName = 'com.openviewai.synhub';

/// 保管库里的一份模型及其旁注（大小/时间），仅用于展示与"像不像一份完整文件"的粗判。
class VaultEntry {
  const VaultEntry({
    required this.file,
    required this.bytes,
    required this.modelId,
  });

  final File file;
  final int bytes;

  /// 目录里能对上的是哪个已知模型（认不出就是空串）
  final String modelId;

  String get fileName => p.basename(file.path);

  String get sizeLabel => bytes >= 1024 * 1024 * 1024
      ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
      : '${(bytes / (1024 * 1024)).round()} MB';
}

/// 端侧模型离线保管库。
abstract final class ModelVault {
  /// 测试注入：非空时所有读写都落在这个目录（绕开 path_provider 与真机路径）。
  static Directory? dirOverride;

  /// 测试注入：非空时收件箱用这个目录。
  static Directory? inboxOverride;

  /// 旁注文件后缀（记录字节数与写入时间，便于诊断"这份缓存完不完整"）。
  static const String sidecarSuffix = '.vault.json';

  /// 一份模型至少要有这么多字节才被认为是"真文件"，不是当初留下的空壳。
  static const int minPlausibleBytes = 1024 * 1024; // 1 MB

  /// 还要求达到目录里登记体积的 [sizeFloorRatio] —— 防"下载断了一半的残档"
  /// 被当成可用缓存（那种档 `fromFile` 会装上一个加载即崩的假模型）。
  /// 目录里的 `sizeBytes` 是估值（同一份转换在不同仓库略有出入），所以给足余量。
  static const double sizeFloorRatio = 0.6;

  /// 这份文件像不像"一份完整的 [info]"。
  static bool plausibleSize(int bytes, AiModelInfo info) {
    if (bytes < minPlausibleBytes) return false;
    final expected = info.sizeBytes;
    if (expected <= 0) return true;
    return bytes >= (expected * sizeFloorRatio).round();
  }

  /// 保管库目录；机器上建不出来时返回 null（功能降级为"每次都下"，不影响其它功能）。
  static Future<Directory?> dir() async {
    final override = dirOverride;
    if (override != null) {
      // 注入目录也要兜底：建不出来就"没有保管库"，
      // 绝不能让一个坏路径把整个端侧 AI 页面炸掉。
      try {
        if (!await override.exists()) await override.create(recursive: true);
        return override;
      } catch (_) {
        return null;
      }
    }
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory(p.join(base.path, 'models_vault'));
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }

  /// 收件箱目录：`/storage/emulated/0/Android/media/<包名>/models`。
  ///
  /// 宿主机 `device_model_cache.sh restore` 往这里 push；App 用
  /// [importInbox] 把它搬进保管库。取不到（没外置存储）就返回 null。
  static Future<Directory?> inboxDir({bool create = false}) async {
    final override = inboxOverride;
    if (override != null) {
      if (create) {
        try {
          if (!await override.exists()) await override.create(recursive: true);
        } catch (_) {
          return null;
        }
      }
      return override;
    }
    // 第 279 轮：路径口径统一走 `AppPaths` —— 桌面上**没有**"收件箱"这回事
    // （宿主机就是本机，不需要"先 push 再 import"那一跳）⇒ 返回空根，
    // 调用方据此隐藏"从收件箱导入"。设计与裁决见 `docs/platform-macos.md`。
    final root = await AppPaths.modelInboxRoot();
    if (!root.exists) return null;
    final d = Directory(root.path);
    if (create) {
      try {
        if (!await d.exists()) await d.create(recursive: true);
      } catch (_) {
        return null;
      }
    }
    return d;
  }

  /// 把收件箱里"保管库还没有"的模型搬进保管库（搬完删掉收件箱那份）。
  ///
  /// 只认目录里已知的模型文件名 —— 收件箱是外部可写的，不能让任意文件进库。
  /// 返回搬进来的份数。任何一步失败都只跳过那一份，不影响其它。
  static Future<int> importInbox() async {
    final inbox = await inboxDir();
    final vault = await dir();
    if (inbox == null || vault == null) return 0;
    if (!await inbox.exists()) return 0;
    var moved = 0;
    for (final info in kOnDeviceModels) {
      try {
        final src = File(p.join(inbox.path, info.fileName));
        if (!await src.exists()) continue;
        final len = await src.length();
        if (!plausibleSize(len, info)) continue; // 半截档不进库
        final dst = File(p.join(vault.path, info.fileName));
        final sameBytes = await dst.exists() && await dst.length() == len;
        if (!sameBytes) {
          final tmp = File('${dst.path}.part');
          await src.copy(tmp.path);
          if (await tmp.length() != len) {
            await tmp.delete();
            continue;
          }
          await tmp.rename(dst.path);
          await _writeSidecar(dst, info.id, len);
        }
        await src.delete(); // 搬走，不重复占空间
        moved++;
      } catch (_) {
        continue;
      }
    }
    return moved;
  }

  /// 人类可读的位置说明（设置页/诊断用；取不到就给空串）。
  static Future<String> locationLabel() async {
    final d = await dir();
    return d?.path ?? '';
  }

  /// 收件箱位置（宿主机 push 模型的地方；诊断用）
  static Future<String> inboxLabel() async {
    final d = await inboxDir();
    return d?.path ?? '';
  }

  /// 保管库里有没有这份模型（以文件系统为准，不信旁注）。
  static Future<File?> find(AiModelInfo info) async {
    final d = await dir();
    if (d == null) return null;
    final f = File(p.join(d.path, info.fileName));
    if (!await f.exists()) return null;
    final len = await f.length();
    // 半个文件/空壳/明显偏小：当作没有（宁可重下，也不能装上一个崩的模型）
    if (!plausibleSize(len, info)) return null;
    return f;
  }

  /// 目录里现存的所有模型（含认不出的历史文件）。
  static Future<List<VaultEntry>> list() async {
    final d = await dir();
    if (d == null) return const [];
    if (!await d.exists()) return const [];
    final out = <VaultEntry>[];
    await for (final e in d.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name.endsWith(sidecarSuffix)) continue;
      if (name.endsWith('.part')) continue;
      final len = await e.length();
      if (len < minPlausibleBytes) continue;
      final known = kOnDeviceModels.where((m) => m.fileName == name);
      out.add(
        VaultEntry(
          file: e,
          bytes: len,
          modelId: known.isEmpty ? '' : known.first.id,
        ),
      );
    }
    out.sort((a, b) => b.bytes.compareTo(a.bytes));
    return out;
  }

  /// 总占用字节数。
  static Future<int> totalBytes() async {
    var sum = 0;
    for (final e in await list()) {
      sum += e.bytes;
    }
    return sum;
  }

  /// 把**插件托管目录里那份已下载好的模型**收进保管库。
  ///
  /// 下载完成后调用；已有同内容（同文件名同字节数）就直接返回，不再拷贝。
  /// 先写 `.part` 再 rename，避免中途失败留下半个文件被 `find()` 当成可用缓存。
  static Future<File?> adopt(AiModelInfo info) async {
    final d = await dir();
    if (d == null) return null;
    final dst = File(p.join(d.path, info.fileName));
    try {
      final srcPath = await FlutterGemma.getModelPath(info.fileName);
      final src = File(srcPath);
      if (!await src.exists()) return null;
      final srcLen = await src.length();
      if (!plausibleSize(srcLen, info)) return null;
      if (await dst.exists() && await dst.length() == srcLen) {
        return dst; // 已经在库里，省一次拷贝
      }
      final tmp = File('${dst.path}.part');
      await src.copy(tmp.path);
      if (await tmp.length() != srcLen) {
        await tmp.delete();
        return null;
      }
      await tmp.rename(dst.path);
      await _writeSidecar(dst, info.id, srcLen);
      return dst;
    } catch (_) {
      return null;
    }
  }

  /// 把一份**外部文件**（例如宿主机 `adb push` 回来的备份）登记进保管库。
  ///
  /// `scripts/device_model_cache.sh restore` 走的就是这条路：先 push 到
  /// `Android/media/<包名>/models/`，App 这边无需任何额外动作即可命中。
  static Future<File?> ingestFile(File src, AiModelInfo info) async {
    final d = await dir();
    if (d == null) return null;
    if (!await src.exists()) return null;
    final len = await src.length();
    if (!plausibleSize(len, info)) return null;
    final dst = File(p.join(d.path, info.fileName));
    if (src.path != dst.path) {
      if (await dst.exists() && await dst.length() == len) return dst;
      await src.copy(dst.path);
    }
    await _writeSidecar(dst, info.id, len);
    return dst;
  }

  /// 丢掉一份坏缓存（例如 `fromFile` 装上后引擎报错）。
  static Future<void> forget(AiModelInfo info) async {
    final d = await dir();
    if (d == null) return;
    for (final f in [
      File(p.join(d.path, info.fileName)),
      File('${p.join(d.path, info.fileName)}$sidecarSuffix'),
      File('${p.join(d.path, info.fileName)}.part'),
    ]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// 清空保管库（用户显式要求"彻底删除"时才调用），返回删掉的字节数。
  static Future<int> purge() async {
    var freed = 0;
    for (final e in await list()) {
      freed += e.bytes;
      try {
        await e.file.delete();
      } catch (_) {}
      try {
        final side = File('${e.file.path}$sidecarSuffix');
        if (await side.exists()) await side.delete();
      } catch (_) {}
    }
    return freed;
  }

  static Future<void> _writeSidecar(File model, String modelId, int bytes) async {
    try {
      final side = File('${model.path}$sidecarSuffix');
      await side.writeAsString(
        jsonEncode({
          'modelId': modelId,
          'fileName': p.basename(model.path),
          'bytes': bytes,
          'savedAt': DateTime.now().toIso8601String(),
          'package': kAndroidPackageName,
        }),
        flush: true,
      );
    } catch (_) {
      // 旁注只是诊断用，写不进去不影响模型本身可用
    }
  }
}
