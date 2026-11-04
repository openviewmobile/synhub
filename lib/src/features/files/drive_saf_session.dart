// ★★ ③Drive 第 246 轮 **D66** 的 Dart 半边：与 Kotlin `DriveSafBridge` 对话，
// 把"启用 SAF 按需下载"这件事落到 provider 能读到的地方。
//
// 为什么 Dart 还要参与：**凭据只有 Dart 侧知道**（用户是在 App 里登录的）。
// Kotlin 侧把它用 Android Keystore 加密存进 SharedPreferences，
// 这样系统文件选择器把 provider 冷启动拉起时（Flutter 引擎不在场）
// provider 也能自己登录 → 下载 → 打开。
//
// 契约（`test/drive_saf_session_contract_test.dart` 用**读两边源码**的方式钉住）：
//   * 通道 `synhub/drive_saf`
//   * 方法 `storeCredentials` / `clearCredentials` / `setOnDemand` / `status` /
//     `clearCache` / `prefetch`
//   * 参数键 `baseUrl` `username` `password` `otp` `deviceId` `onDemand` `on`
//   * 缓存目录名 `saf_ondemand`、文件名 `<fileId>_<消毒名>`
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import 'drive_open_on_demand.dart';

/// 通道名（Kotlin `DriveSafSession.CHANNEL` 必须一致）。
const String kDriveSafChannel = 'synhub/drive_saf';

/// 方法名（Kotlin `DriveSafBridge` 的 `when(call.method)` 必须一致）。
const String kDriveSafStoreCredentials = 'storeCredentials';
const String kDriveSafClearCredentials = 'clearCredentials';
const String kDriveSafSetOnDemand = 'setOnDemand';
const String kDriveSafStatus = 'status';
const String kDriveSafClearCache = 'clearCache';
const String kDriveSafPrefetch = 'prefetch';

/// Kotlin 侧 `DriveSafSession` 的 SharedPreferences 键（契约钉住）。
const String kDriveSafPrefs = 'drive_saf';
const String kDriveSafKeyBaseUrl = 'base_url';
const String kDriveSafKeyUsername = 'username';
const String kDriveSafKeyPasswordEnc = 'password_enc';
const String kDriveSafKeyOtp = 'otp';
const String kDriveSafKeyDeviceId = 'device_id';
const String kDriveSafKeySid = 'sid';
const String kDriveSafKeyOnDemand = 'on_demand';

/// Kotlin 侧登录用的接口与版本（**必须与 Dart 的登录实现一致**）。
const String kDriveSafLoginApi = 'SYNO.API.Auth';
const String kDriveSafLoginMethod = 'login';
const int kDriveSafLoginVersion = 6;
const String kDriveSafLoginSession = 'SynologyDrive';

/// Kotlin 侧下载用的接口与版本（必须与 `DriveApi.downloadUrl` 一致）。
const String kDriveSafDownloadApi = 'SYNO.SynologyDrive.Files';
const String kDriveSafDownloadMethod = 'download';
const int kDriveSafDownloadVersion = 2;

/// provider 按需下载的状态。
class DriveSafStatus {
  const DriveSafStatus({
    required this.configured,
    required this.onDemand,
    required this.baseUrl,
    required this.username,
    required this.hasSid,
    required this.cachedBytes,
  });

  final bool configured;
  final bool onDemand;
  final String baseUrl;
  final String username;
  final bool hasSid;
  final int cachedBytes;

  /// 能不能"冷启动自己下"：有凭据 **且** 开了开关。
  bool get canColdStartDownload => configured && onDemand;

  static DriveSafStatus fromMap(Map<Object?, Object?> m) => DriveSafStatus(
    configured: m['configured'] == true,
    onDemand: m['onDemand'] == true,
    baseUrl: '${m['baseUrl'] ?? ''}',
    username: '${m['username'] ?? ''}',
    hasSid: m['hasSid'] == true,
    cachedBytes: (m['cachedBytes'] as num?)?.toInt() ?? 0,
  );

  static const DriveSafStatus unavailable = DriveSafStatus(
    configured: false,
    onDemand: false,
    baseUrl: '',
    username: '',
    hasSid: false,
    cachedBytes: 0,
  );
}

/// 与 Kotlin 对话的客户端。**非 Android / 通道缺失时全部返回"不可用"**，
/// 不抛异常（这样桌面/测试环境调用它是安全的）。
class DriveSafSession {
  DriveSafSession({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kDriveSafChannel);

  final MethodChannel _channel;

  /// 第 55 轮：SAF 会话（DocumentsProvider）只有 Kotlin 一份 ⇒ 宿主上
  /// 能力层报 `unavailable:not-implemented-on-host`，所有方法**不碰通道**。
  static bool get _allowed =>
      capabilityGateAllows(AppCapability.driveSafSession);

  static void _logBlocked(String what) => debugPrint(
    capabilityGateLog(AppCapability.driveSafSession, 'drive_saf.$what'),
  );

  Future<DriveSafStatus> status() async {
    if (!_allowed) {
      _logBlocked('status');
      return DriveSafStatus.unavailable;
    }
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>(
        kDriveSafStatus,
      );
      return r == null ? DriveSafStatus.unavailable : DriveSafStatus.fromMap(r);
    } on MissingPluginException {
      return DriveSafStatus.unavailable;
    } on PlatformException {
      return DriveSafStatus.unavailable;
    }
  }

  /// 把凭据交给 Kotlin（Keystore 加密存）。返回最新状态。
  Future<DriveSafStatus> storeCredentials({
    required String baseUrl,
    required String username,
    required String password,
    String otp = '',
    String deviceId = '',
    bool onDemand = true,
  }) async {
    if (!_allowed) {
      _logBlocked('storeCredentials');
      return DriveSafStatus.unavailable;
    }
    final r = await _channel.invokeMethod<Map<Object?, Object?>>(
      kDriveSafStoreCredentials,
      {
        'baseUrl': baseUrl,
        'username': username,
        'password': password,
        'otp': otp,
        'deviceId': deviceId,
        'onDemand': onDemand,
      },
    );
    return r == null ? DriveSafStatus.unavailable : DriveSafStatus.fromMap(r);
  }

  Future<void> clearCredentials() async {
    if (!_allowed) {
      _logBlocked('clearCredentials');
      return;
    }
    await _channel.invokeMethod<void>(kDriveSafClearCredentials);
  }

  Future<DriveSafStatus> setOnDemand(bool on) async {
    if (!_allowed) {
      _logBlocked('setOnDemand');
      return DriveSafStatus.unavailable;
    }
    final r = await _channel.invokeMethod<Map<Object?, Object?>>(
      kDriveSafSetOnDemand,
      {'on': on},
    );
    return r == null ? DriveSafStatus.unavailable : DriveSafStatus.fromMap(r);
  }

  Future<int> clearCache() async {
    if (!_allowed) {
      _logBlocked('clearCache');
      return 0;
    }
    return await _channel.invokeMethod<int>(kDriveSafClearCache) ?? 0;
  }

  /// 立刻下一份到 provider 缓存（"离线可用"按钮用）。
  Future<String> prefetch({required String fileId, required String name}) async {
    if (!_allowed) {
      _logBlocked('prefetch');
      return '';
    }
    final r = await _channel.invokeMethod<Map<Object?, Object?>>(
      kDriveSafPrefetch,
      {'fileId': fileId, 'name': name},
    );
    return '${r?['path'] ?? ''}';
  }
}

/// 与 Kotlin 对话的客户端（测试可覆盖成假通道）。
final driveSafSessionProvider = Provider<DriveSafSession>(
  (ref) => DriveSafSession(),
);

/// 从文档 id 抽 fileId —— **与 Kotlin `DriveDocumentsProvider.extractFileId` 同规则**。
///
/// ⚠️ 247 轮真机抓到的 bug：早先实现是"取第一个冒号到下一个冒号之间的段"，
/// 于是 `:real:drive-demo-1` 被解析成 **`real`**（那是**标签**不是 id），
/// 下载请求带着 `files=["id:real"]` ⇒ 服务端 **408 文件不存在**。
/// 官方前缀是**定长已知**的，必须逐前缀剥掉，不能"找冒号"。
String safFileIdFromDocumentId(String documentId) {
  for (final prefix in const [':real:', ':local:']) {
    if (documentId.startsWith(prefix)) {
      return documentId.substring(prefix.length);
    }
  }
  // `:label:` / `:create_folder:` / `virtualTop` 都不是可下载的文件节点
  return '';
}

/// provider 缓存目录（**Dart 与 Kotlin 指向同一个物理目录**：
/// Dart 的 `getTemporaryDirectory()/saf_ondemand` ≈ Kotlin 的 `cacheDir/saf_ondemand`）。
Directory driveSafOnDemandDir(Directory tempDir) =>
    Directory('${tempDir.path}/$kSafOnDemandDirName');
