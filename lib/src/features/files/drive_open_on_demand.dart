// ★★★ ③Drive **D66「SAF 云端条目：打开那一刻真去下载」** —— 第 246 轮。
//
// ## 缺口（227 轮之后仍剩的）
// 227 轮加了**有界预取**：小文件先落到 App 私有缓存 ⇒ 系统选择器里能直接打开。
// 但超过上限的文件（大视频、大压缩包）仍然打不开 —— provider 不自登录 DSM。
//
// ## 本轮做到哪儿
// 把"按需下载"做出来：**打开时若本地没有副本就现下**。两条腿：
//   * **App 内的这条腿（本文件）**：`DriveOpenOnDemand.open()` ——
//     查缓存 → 没有就 `Files/download` 直链取字节 → 落缓存 → 交路径。
//     这条腿**用 Mock Server 验证**（含二进制接口，246 轮给 mock 补的
//     `handleRaw`）。
//   * **provider 冷启动那条腿（Kotlin）**：`DriveSafSession.kt` ——
//     在系统文件选择器把 provider 拉起、Flutter 引擎不在场时，
//     provider 自己登录 DSM 再下（凭据用 Android Keystore 加密存）。
//     这部分**真机未验**（本仓不跑 Gradle/无设备），如实标注。
//
// ## 与 227 轮预取的关系（**两套独立的缓存，别混**）
//   * 227 轮预取：目录 `saf_cache/`（Documents 下），**提前**把小的搬过来，
//     结果写进索引的 `localPath`；
//   * 本轮按需下载：目录 `saf_ondemand/`（**cacheDir** 下，Kotlin 侧同名），
//     **打开那一刻**才搬 —— 大文件不进索引（免得每次刷新都重扫），
//     由 provider 直接交句柄。
// 两个目录并存是**故意的**：预取的那份可以随时清、按需的那份跟着缓存策略走。

// ## 本模块的角色（如实说明，别夸大）
// App 内打开云端文件走的是既有的 `getBytes`/编辑器路径；真正需要"冷启动自己下"
// 的场景在 **provider**（Kotlin）。所以本模块是：
//   ① 与 Kotlin **同一套协议**的 Dart 实现，用来**用 Mock Server 验证协议本身**
//      （直链参数、失败码、超限、原子落盘、路径穿越消毒）；
//   ② 与 Kotlin 共用目录/文件名/阈值约定的**单一事实来源**（契约测试读它）。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../data/drive_api.dart';
import 'files_i18n.dart';

/// 取二进制（下载直链）的注入点 —— 生产环境走带 `_sid` 的直链；用例走 Mock。
typedef DriveBinaryFetcher = Future<List<int>> Function(String url);

/// 一次"按需打开"的结果。
class DriveOnDemandResult {
  const DriveOnDemandResult({
    required this.status,
    this.path = '',
    this.bytes = 0,
    this.reason = '',
  });

  final DriveOnDemandStatus status;
  final String path;
  final int bytes;
  final String reason;

  bool get ok => status != DriveOnDemandStatus.failed;

  Map<String, Object?> toJson() => {
    'status': status.wire,
    'path': path,
    'bytes': bytes,
    if (reason.isNotEmpty) 'reason': reason,
  };
}

enum DriveOnDemandStatus {
  /// 本地已有副本（没发任何网络请求）
  cached('cached'),

  /// 现下成功
  downloaded('downloaded'),

  /// 超出"打开即下"上限 —— **明确拒绝**，不假装成功
  tooLarge('too_large'),

  /// 下载/登录失败（带原因）
  failed('failed');

  const DriveOnDemandStatus(this.wire);
  final String wire;
}

/// 按需打开的策略（刻意保守：手机上"打开一个大文件"不该静默吃掉流量/空间）。
class DriveOnDemandPolicy {
  const DriveOnDemandPolicy({
    this.enabled = true,
    // 官方那种"点开就下"没有硬上限；我们给个可配的默认值（256 MB），
    // 超过就如实拒绝并提示——比"悄悄下 2 GB"更负责任。
    this.maxBytes = 256 << 20,
    this.cacheLimitBytes = 512 << 20,
  });

  final bool enabled;
  final int maxBytes;

  /// 缓存目录软上限：超了先删最旧的，再下。
  final int cacheLimitBytes;

  static const DriveOnDemandPolicy off = DriveOnDemandPolicy(enabled: false);
}

/// 按需下载服务。
class DriveOpenOnDemand {
  DriveOpenOnDemand({
    required this.api,
    required this.fetchBytes,
    required this.cacheDir,
    this.policy = const DriveOnDemandPolicy(),
    this.nowMs,
  });

  final DriveApi api;
  final DriveBinaryFetcher fetchBytes;
  final Directory cacheDir;
  final DriveOnDemandPolicy policy;
  final int Function()? nowMs;

  /// 打开（必要时下载）一个云端文件，返回本地路径。
  ///
  /// [sizeBytes] 已知且超限 ⇒ [DriveOnDemandStatus.tooLarge]（**不发请求**）。
  Future<DriveOnDemandResult> open({
    required String fileId,
    required String name,
    int? sizeBytes,
  }) async {
    if (!policy.enabled) {
      return DriveOnDemandResult(
        status: DriveOnDemandStatus.failed,
        reason: fsT('driveOnDemandNotEnabled', '按需下载未开启'),
      );
    }
    if (fileId.isEmpty) {
      return DriveOnDemandResult(
        status: DriveOnDemandStatus.failed,
        reason: fsT('driveOnDemandMissingFileId', '缺少 fileId'),
      );
    }
    final safeName = _safeName(name.isEmpty ? fileId : name);
    final path = '${cacheDir.path}/${fileId}_$safeName';
    final f = File(path);
    if (await f.exists() && await f.length() > 0) {
      return DriveOnDemandResult(
        status: DriveOnDemandStatus.cached,
        path: path,
        bytes: await f.length(),
      );
    }
    if (sizeBytes != null && sizeBytes > policy.maxBytes) {
      return DriveOnDemandResult(
        status: DriveOnDemandStatus.tooLarge,
        reason: fsTFill(
          'driveOnDemandTooLarge',
          '文件 ${_mb(sizeBytes)} 超过"打开即下"上限 ${_mb(policy.maxBytes)}，'
              '请先在 App 里选择"离线可用"',
          {'size': _mb(sizeBytes), 'limit': _mb(policy.maxBytes)},
        ),
      );
    }
    final url = api.downloadUrl(fileId: fileId);
    try {
      await cacheDir.create(recursive: true);
      await _trimCache(keepPath: path);
      final bytes = await fetchBytes(url);
      if (bytes.isEmpty) {
        return DriveOnDemandResult(
          status: DriveOnDemandStatus.failed,
          reason: fsT('driveOnDemandEmptyContent', '服务端返回空内容'),
        );
      }
      // ★ 247 轮**真机抓到的第二个 bug**：DSM 的错误也是 **HTTP 200 + JSON 信封**
      // （mock/真机都一样），上一版会把 `{"success":false,"error":{"code":119}}`
      // 当"文件内容"存下来 —— 真机缓存里就出现过 38 字节的
      // `real_drive-demo.txt`（内容是错误 JSON）。必须**先认出错误再落盘**。
      final errCode = dsmErrorCodeFromBytes(bytes);
      if (errCode != null) {
        return DriveOnDemandResult(
          status: DriveOnDemandStatus.failed,
          reason: fsTFill(
            'driveOnDemandRejected',
            '下载被拒绝（DSM 错误码 $errCode）',
            {'code': '$errCode'},
          ),
        );
      }
      if (bytes.length > policy.maxBytes) {
        // 体积是下完才知道的 ⇒ 超限就**不落盘**（浪费的流量如实说明）
        return DriveOnDemandResult(
          status: DriveOnDemandStatus.tooLarge,
          reason: fsTFill(
            'driveOnDemandActualTooLarge',
            '实际大小 ${_mb(bytes.length)} 超过上限 ${_mb(policy.maxBytes)}，已丢弃',
            {'size': _mb(bytes.length), 'limit': _mb(policy.maxBytes)},
          ),
        );
      }
      // 原子落盘：先写 .part 再 rename，避免"半个文件"被当成可用副本
      final part = File('$path.part');
      await part.writeAsBytes(Uint8List.fromList(bytes), flush: true);
      await part.rename(path);
      return DriveOnDemandResult(
        status: DriveOnDemandStatus.downloaded,
        path: path,
        bytes: bytes.length,
      );
    } catch (e) {
      return DriveOnDemandResult(
        status: DriveOnDemandStatus.failed,
        reason: fsTFill('driveOnDemandFailed', '下载失败：$e', {'error': '$e'}),
      );
    }
  }

  /// 缓存占用（诊断/清理用）。
  Future<int> cacheBytes() async {
    if (!await cacheDir.exists()) return 0;
    var total = 0;
    await for (final e in cacheDir.list()) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  /// 清空缓存（"释放空间"入口用）。
  Future<int> clearCache() async {
    if (!await cacheDir.exists()) return 0;
    var freed = 0;
    await for (final e in cacheDir.list()) {
      if (e is File) {
        freed += await e.length();
        await e.delete();
      }
    }
    return freed;
  }

  /// 缓存超软上限时，删掉最旧的直到降到 80%。
  Future<void> _trimCache({required String keepPath}) async {
    if (!await cacheDir.exists()) return;
    final files = <File>[];
    await for (final e in cacheDir.list()) {
      if (e is File && e.path != keepPath) files.add(e);
    }
    var total = 0;
    final stats = <({File f, int len, DateTime at})>[];
    for (final f in files) {
      final len = await f.length();
      total += len;
      stats.add((f: f, len: len, at: await f.lastModified()));
    }
    if (total <= policy.cacheLimitBytes) return;
    // 同一时间戳的文件必须有确定顺序（`List.sort` 不稳定 ⇒ 摇摆在两次
    // 清理之间会删掉不同的文件；Linux 上已实测到 old1 反而活下来）。
    stats.sort((a, b) {
      final byTime = a.at.compareTo(b.at);
      return byTime != 0 ? byTime : a.f.path.compareTo(b.f.path);
    });
    final target = (policy.cacheLimitBytes * 0.8).round();
    for (final s in stats) {
      if (total <= target) break;
      try {
        await s.f.delete();
        total -= s.len;
      } catch (_) {
        // 删不掉就跳过（不因为清理失败而让下载失败）
      }
    }
  }

  static String _mb(int bytes) =>
      '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';

  /// 文件名消毒：目录分隔符与 `..` 一律替换（防路径穿越）。
  static String _safeName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/]'), '_')
        .replaceAll('..', '_')
        .replaceAll(RegExp(r'[\x00-\x1f]'), '');
    final trimmed = cleaned.trim();
    if (trimmed.isEmpty) return 'file';
    return trimmed.length > 120 ? trimmed.substring(0, 120) : trimmed;
  }
}

/// 缓存目录约定（Dart 与 Kotlin **必须一致**）。
///
/// Kotlin 侧用 `context.cacheDir/saf_ondemand`；Dart 侧用
/// `getTemporaryDirectory()/saf_ondemand`。两边指向同一个物理目录。
const String kSafOnDemandDirName = 'saf_ondemand';

/// 从字节里认出 **DSM 错误信封**（`{"success":false,"error":{"code":N}}`）并返回 `N`。
///
/// 为什么需要：DSM 的业务错误是 **HTTP 200 + JSON 信封**，下载直链也一样
/// （247 轮真机：mock 回 200+`{"success":false,"error":{"code":119}}`，
/// 上一版把这段 38 字节的 JSON 当文件存进了缓存）。
/// 判据保守：只有**整个响应是 JSON 对象且 `success == false`** 才算错误，
/// 免得把"内容恰好是 JSON 的文件"误判（真文件基本不会带着 `success` 键）。
int? dsmErrorCodeFromBytes(List<int> bytes) {
  if (bytes.isEmpty || bytes.length > 64 * 1024) return null;
  // JSON 对象必须以 `{` 开头（跳过前导空白/换行）
  var i = 0;
  while (i < bytes.length &&
      (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0a || bytes[i] == 0x0d)) {
    i++;
  }
  if (i >= bytes.length || bytes[i] != 0x7b) return null;
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) return null;
    if (decoded['success'] != false) return null;
    final err = decoded['error'];
    if (err is Map && err['code'] is num) return (err['code'] as num).toInt();
    return -1;
  } catch (_) {
    return null;
  }
}

/// 与 Kotlin 一致的缓存文件名（`<fileId>_<消毒后的名字>`）。
String safOnDemandFileName({required String fileId, required String name}) =>
    '${fileId}_${DriveOpenOnDemand._safeName(name.isEmpty ? fileId : name)}';

/// 供 UI 显示的"要不要先下"的判断（不触碰网络）。
bool safOnDemandNeedsDownload({
  required bool cached,
  required int? sizeBytes,
  DriveOnDemandPolicy policy = const DriveOnDemandPolicy(),
}) {
  if (cached) return false;
  if (!policy.enabled) return false;
  if (sizeBytes == null) return true;
  return sizeBytes <= policy.maxBytes;
}

/// 进度的粗略估算（给 UI 一个"大约多大"的提示；未知返回 0）。
int safOnDemandEstimateBytes(int? sizeBytes, DriveOnDemandPolicy policy) =>
    sizeBytes == null ? 0 : math.min(sizeBytes, policy.maxBytes);
