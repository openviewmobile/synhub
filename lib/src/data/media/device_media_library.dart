// 本机相册（MediaStore）读取 —— 手机自动备份的"源"。
//
// Android 侧是 `MediaLibraryBridge.kt`（`MediaStore` 查询 + 运行时权限），
// 这里只做四件事：**查权限**、**要权限**、**枚举图片/视频**、**把 content uri
// 落成可上传的本地文件**。
//
// 为什么不用 `photo_manager`：项目里已经有 NetworkBridge/KeystoreBridge/
// LocationBridge 这套极小的 MethodChannel 写法，引插件会带一堆 Android 依赖；
// 而且我们不只要"选几张"，还要枚举整库 + 拿 content uri（见
// `docs/p2-photos-backup-research.md` §2.2 的两条路线对比）。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/platform/app_platform.dart';

/// 相册读取权限的结果（Android 三态 + Android 14 的"部分授权"）。
enum MediaPermission {
  /// 全部图片/视频可见
  granted('granted'),

  /// Android 14+：用户只授权了**选中的那几张**（备份会不完整，必须引导"允许全部"）
  partial('partial'),

  /// 这次没给（还能再问）
  denied('denied'),

  /// 平台没有这个能力（桌面/测试/没装桥）
  unsupported('unsupported');

  const MediaPermission(this.id);

  final String id;

  bool get isUsable => this == MediaPermission.granted;
}

/// 本机相册里的一个文件（图片或视频）。
@immutable
class DeviceMediaAsset {
  const DeviceMediaAsset({
    required this.id,
    required this.uri,
    required this.displayName,
    required this.size,
    required this.takenTimeMs,
    required this.modifiedTimeMs,
    this.mimeType = '',
    this.isVideo = false,
    this.relativePath = '',
  });

  /// MediaStore 的 `_id`（**只当这一轮枚举到的句柄**，不保证跨重扫稳定）
  final String id;

  /// `content://media/external/file/<id>`
  final String uri;
  final String displayName;
  final int size;

  /// 拍摄时间（`DATE_TAKEN`；缺失时桥侧回落到 `DATE_MODIFIED`）
  final int takenTimeMs;
  final int modifiedTimeMs;
  final String mimeType;
  final bool isVideo;

  /// `Pictures/Screenshots` 这类（API 29+ 才有）
  final String relativePath;

  /// **本地稳定身份**：相对路径 + 文件名 + 大小 + 拍摄时间。
  ///
  /// `_id` 不保证稳定（重扫/重挂载会变），所以本地记账用它，不用 [_id]。
  String get stableKey => '$relativePath|$displayName|$size|$takenTimeMs';

  int get takenSeconds => takenTimeMs ~/ 1000;
  int get modifiedSeconds => modifiedTimeMs ~/ 1000;

  /// 服务端去重用的键（**文件名 + 大小**）—— `unit.duplicate_hash` 之外的
  /// 客户端可见维度，和 `mobile_cache_mtime` 一起够做增量判断。
  String get remoteKey => '$displayName|$size';

  @override
  bool operator ==(Object other) =>
      other is DeviceMediaAsset && other.stableKey == stableKey;

  @override
  int get hashCode => stableKey.hashCode;
}

/// 平台能不能"由应用请求删除相册文件"。
///
/// 官方相机备份的「释放空间」在 Android 上走的也是这套分段删除确认
/// （`str_rel_space_multi_perm_check` / `freeupspace.FreeUpSpaceService`）。
enum MediaDeleteSupport {
  /// Android 11+：系统会弹**确认框**，用户同意后才删得掉该批文件
  systemConfirm('system_confirm'),

  /// 系统版本太低，应用无法请求删除相册文件 —— 只能引导用户去系统设置手动清理
  settingsOnly('settings_only'),

  /// 平台没有这个能力（桌面 / 测试 / 没装桥）
  unsupported('unsupported');

  const MediaDeleteSupport(this.id);

  final String id;

  /// 只有这一档能真正"由应用代删"（而且**必然**经过系统确认框）。
  bool get canDeleteOnDevice => this == MediaDeleteSupport.systemConfirm;

  static MediaDeleteSupport fromId(String? id) =>
      MediaDeleteSupport.values.firstWhere(
        (s) => s.id == id,
        orElse: () => MediaDeleteSupport.unsupported,
      );
}

/// 一次"请求删除本地相册文件"的真实结局。
///
/// ⚠️ **这个类型只描述事实，不描述期望**：用户拒绝确认、平台不支持、调用失败时
/// [deletedUris] 一律为空 —— 调用方**不允许**把它包装成"已释放空间"。
@immutable
class MediaDeleteOutcome {
  const MediaDeleteOutcome({
    required this.support,
    required this.confirmed,
    required this.requested,
    this.deletedUris = const [],
    this.failedUris = const [],
    this.error = '',
  });

  /// 平台判决时报告的删除形态
  final MediaDeleteSupport support;

  /// 用户是否点了系统确认框的"允许"
  final bool confirmed;

  /// 这一批请求删了几项
  final int requested;

  /// **真的删掉了**的 uri（唯一可信的成功证据）
  final List<String> deletedUris;

  /// 没能删掉的 uri
  final List<String> failedUris;

  /// 平台侧的错误原文（只进诊断，**不上界面**）
  final String error;

  int get deletedCount => deletedUris.length;

  /// 用户明确拒绝了这次删除（什么都没删）
  bool get rejected => support.canDeleteOnDevice && !confirmed;

  /// 平台根本不支持由应用代删（什么都没删）
  bool get unsupported =>
      support == MediaDeleteSupport.unsupported ||
      support == MediaDeleteSupport.settingsOnly;

  bool get anyDeleted => deletedUris.isNotEmpty;
}

/// **删除本地相册文件**的能力（与读取分开，避免把删除能力塞进只读探针）。
///
/// 单独的接口是为了让"只读的相册列举"与"会动用户照片的删除"在类型上分开：
/// * 生产实现只有 [MethodChannelDeviceMediaLibrary]；
/// * 用例里注入假实现，**绝不真的删任何文件**。
///
/// ⚠️ 删除发生在**手机本地**（这是本功能的目的），而且必须走系统确认框；
/// 与 NAS 没有任何写操作。
abstract class DeviceMediaDeleter {
  /// 这台设备上"由应用请求删除相册文件"能做到哪一步。
  Future<MediaDeleteSupport> deleteSupport();

  /// 请求删除这批本地文件 —— 平台**必须**弹系统确认框。
  ///
  /// 返回的是**真实结局**：用户拒绝 / 平台不支持 / 出错时
  /// [MediaDeleteOutcome.deletedUris] 为空。
  Future<MediaDeleteOutcome> requestDelete(List<DeviceMediaAsset> assets);

  /// 打不开系统设置就回 false（调用方按"没跳过去"处理，**不假装成功**）。
  Future<bool> openSystemSettings();

  /// 清掉 App 自己在上传过程中落下的临时副本（**不是**用户相册里的照片）。
  ///
  /// 这是纯 App 私有目录，不需要系统确认框；失败回 false。
  Future<bool> clearUploadCache();
}

/// 本机相册探针（测试里覆盖成假实现）。
abstract class DeviceMediaLibrary {
  /// 当前权限（**不弹框**）
  Future<MediaPermission> permissionStatus();

  /// 确保拿到权限（会弹系统授权框）；[interactive] = false 时只看现状
  Future<MediaPermission> ensurePermission({bool interactive = true});

  /// 枚举本机相册（按拍摄时间倒序）。
  Future<List<DeviceMediaAsset>> list({
    bool includeVideos = true,
    int limit = 500,
    int offset = 0,
  });

  /// 把 content uri 复制进 App 缓存目录，返回**可上传的本地路径**；
  /// 失败回 null（不抛，交给队列记一次失败重试）。
  Future<String?> materialize(DeviceMediaAsset asset);
}

/// 生产实现：`synhub/media` MethodChannel
class MethodChannelDeviceMediaLibrary
    implements DeviceMediaLibrary, DeviceMediaDeleter {
  MethodChannelDeviceMediaLibrary({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('synhub/media');

  final MethodChannel _channel;

  /// 第 55 轮：`synhub/media` 是 Android `MediaStore` 的桥 ⇒ 宿主上能力层
  /// 报 `unavailable:not-implemented-on-host`，**不碰通道**。
  static bool get _allowed =>
      capabilityGateAllows(AppCapability.localMediaLibrary);

  static void _logBlocked(String what) => debugPrint(
    capabilityGateLog(AppCapability.localMediaLibrary, 'media_library.$what'),
  );

  static MediaPermission _fromMap(Map<String, Object?>? map) {
    if (map == null) return MediaPermission.unsupported;
    if (map['granted'] == true) return MediaPermission.granted;
    if (map['partial'] == true) return MediaPermission.partial;
    return MediaPermission.denied;
  }

  @override
  Future<MediaPermission> permissionStatus() async {
    if (!_allowed) {
      _logBlocked('permissionStatus');
      return MediaPermission.unsupported;
    }
    try {
      return _fromMap(
        await _channel.invokeMapMethod<String, Object?>('status'),
      );
    } on MissingPluginException {
      return MediaPermission.unsupported;
    } catch (_) {
      return MediaPermission.denied;
    }
  }

  @override
  Future<MediaPermission> ensurePermission({bool interactive = true}) async {
    if (!_allowed) {
      _logBlocked('ensurePermission');
      return MediaPermission.unsupported;
    }
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      final current = _fromMap(status);
      // 部分授权也当作"已授权"问过一次就不再弹（否则每次都弹，真机上很烦）
      if (current == MediaPermission.granted ||
          current == MediaPermission.partial) {
        return current;
      }
      if (!interactive) return current;
      return _fromMap(
        await _channel.invokeMapMethod<String, Object?>('requestPermission'),
      );
    } on MissingPluginException {
      return MediaPermission.unsupported;
    } on PlatformException {
      return MediaPermission.denied;
    }
  }

  @override
  Future<List<DeviceMediaAsset>> list({
    bool includeVideos = true,
    int limit = 500,
    int offset = 0,
  }) async {
    if (!_allowed) {
      _logBlocked('list');
      return const <DeviceMediaAsset>[];
    }
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('list', {
        'includeVideos': includeVideos,
        'limit': limit,
        'offset': offset,
      });
      final raw = map?['items'];
      if (raw is! List) return const [];
      return [
        for (final e in raw)
          if (e is Map) _asset(e.cast<String, Object?>()),
      ];
    } on MissingPluginException {
      return const [];
    } catch (_) {
      return const [];
    }
  }

  DeviceMediaAsset _asset(Map<String, Object?> j) => DeviceMediaAsset(
    id: '${j['id'] ?? ''}',
    uri: '${j['uri'] ?? ''}',
    displayName: '${j['name'] ?? ''}',
    size: (j['size'] as num?)?.toInt() ?? 0,
    takenTimeMs: (j['takenTime'] as num?)?.toInt() ?? 0,
    modifiedTimeMs: (j['modifiedTime'] as num?)?.toInt() ?? 0,
    mimeType: '${j['mime'] ?? ''}',
    isVideo: j['isVideo'] == true,
    relativePath: '${j['relativePath'] ?? ''}',
  );

  @override
  Future<String?> materialize(DeviceMediaAsset asset) async {
    if (!_allowed) {
      _logBlocked('materialize');
      return null;
    }
    try {
      final path = await _channel.invokeMethod<String>('materialize', {
        'uri': asset.uri,
        'name': asset.displayName,
      });
      return (path == null || path.isEmpty) ? null : path;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------- 释放手机空间

  @override
  Future<MediaDeleteSupport> deleteSupport() async {
    if (!_allowed) {
      _logBlocked('deleteSupport');
      return MediaDeleteSupport.unsupported;
    }
    try {
      final map = await _channel.invokeMapMethod<String, Object?>(
        'deleteSupport',
      );
      return MediaDeleteSupport.fromId('${map?['support'] ?? ''}');
    } on MissingPluginException {
      return MediaDeleteSupport.unsupported;
    } catch (_) {
      return MediaDeleteSupport.unsupported;
    }
  }

  @override
  Future<MediaDeleteOutcome> requestDelete(
    List<DeviceMediaAsset> assets,
  ) async {
    if (!_allowed) {
      _logBlocked('requestDelete');
      return MediaDeleteOutcome(
        support: MediaDeleteSupport.unsupported,
        confirmed: false,
        requested: 0,
      );
    }
    final uris = [
      for (final a in assets)
        if (a.uri.isNotEmpty) a.uri,
    ];
    if (uris.isEmpty) {
      return const MediaDeleteOutcome(
        support: MediaDeleteSupport.systemConfirm,
        confirmed: false,
        requested: 0,
      );
    }
    try {
      final map = await _channel.invokeMapMethod<String, Object?>(
        'requestDelete',
        {'uris': uris},
      );
      // 桥不认这个调用（老版本 App / 无宿主）时回 null → **不支持**，
      // 绝不能当成"删掉了"。
      if (map == null) {
        return MediaDeleteOutcome(
          support: MediaDeleteSupport.unsupported,
          confirmed: false,
          requested: uris.length,
        );
      }
      final support = MediaDeleteSupport.fromId('${map['support'] ?? ''}');
      return MediaDeleteOutcome(
        support: support,
        // 只有平台明确说 confirmed 才算用户同意过
        confirmed: map['confirmed'] == true,
        requested: (map['requested'] as num?)?.toInt() ?? uris.length,
        deletedUris: _uriList(map['deleted']),
        failedUris: _uriList(map['failed']),
        error: '${map['error'] ?? ''}',
      );
    } on MissingPluginException {
      return MediaDeleteOutcome(
        support: MediaDeleteSupport.unsupported,
        confirmed: false,
        requested: uris.length,
      );
    } catch (err) {
      return MediaDeleteOutcome(
        support: MediaDeleteSupport.unsupported,
        confirmed: false,
        requested: uris.length,
        error: '$err',
      );
    }
  }

  static List<String> _uriList(Object? raw) => raw is List
      ? [
          for (final e in raw)
            if (e != null) '$e',
        ]
      : const [];

  @override
  Future<bool> openSystemSettings() async {
    if (!_allowed) {
      _logBlocked('openSystemSettings');
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> clearUploadCache() async {
    if (!_allowed) {
      _logBlocked('clearUploadCache');
      return false;
    }
    try {
      // 复用桥里既有的 `clearCache`：它删的是 `cacheDir/photo_backup`
      // （上传时落下的临时副本），**不是**用户相册里的照片。
      return await _channel.invokeMethod<bool>('clearCache') ?? false;
    } catch (_) {
      return false;
    }
  }
}
