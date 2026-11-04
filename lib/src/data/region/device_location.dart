// 设备定位（系统 GPS/网络定位）—— 天气与节假日要"我现在在哪儿"。
//
// Android 侧是 `LocationBridge.kt`（`LocationManager` + 运行时权限），
// 这里只做三件事：**要权限**、**要一次当前位置**、**看开关**。
//
// 为什么不用 `geolocator`：项目里已经有 NetworkBridge/KeystoreBridge 这套极小的
// MethodChannel 写法，引插件会带一堆 Android 依赖；我们也不需要持续监听。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/platform/app_platform.dart';

/// 定位权限的结果（和 Android 的三态对齐）
enum LocationPermission {
  granted('granted'),

  /// 这次没给（还能再问）
  denied('denied'),

  /// 平台没有定位能力（桌面/测试/没装）
  unsupported('unsupported');

  const LocationPermission(this.id);

  final String id;
}

/// 一次定位结果
@immutable
class DeviceLocation {
  const DeviceLocation({
    required this.latitude,
    required this.longitude,
    this.accuracyM,
    this.provider = '',
    required this.timeMs,
  });

  final double latitude;
  final double longitude;
  final double? accuracyM;
  final String provider;
  final int timeMs;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(timeMs);

  /// 定位精度够不够当"城市级"用（粗略定位也能到 1~3 km，都算能用）
  bool get isUsable => accuracyM == null || accuracyM! <= 50000;
}

/// 定位探针（测试里覆盖成假实现）
abstract class DeviceLocationProbe {
  /// 确保拿到权限（会弹系统授权框）；[interactive] = false 时**不弹**，只查现状
  Future<LocationPermission> ensurePermission({bool interactive = true});

  /// 定位服务（系统总开关）开着吗
  Future<bool> serviceEnabled();

  /// 取一次当前位置；拿不到回 null（超时/没权限/没开开关都回 null）
  Future<DeviceLocation?> current();

  /// 丢掉缓存，下次重新定位
  Future<void> clearCache();
}

/// 生产实现：`synhub/location` MethodChannel
class MethodChannelDeviceLocationProbe implements DeviceLocationProbe {
  MethodChannelDeviceLocationProbe({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('synhub/location');

  final MethodChannel _channel;

  /// 第 55 轮：`synhub/location` 只有 Kotlin 一份 ⇒ 宿主上不碰通道。
  static bool get _allowed =>
      capabilityGateAllows(AppCapability.deviceLocation);

  static void _logBlocked(String what) =>
      debugPrint(capabilityGateLog(AppCapability.deviceLocation, 'location.$what'));

  @override
  Future<LocationPermission> ensurePermission({bool interactive = true}) async {
    if (!_allowed) {
      _logBlocked('ensurePermission');
      return LocationPermission.unsupported;
    }
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      if (status?['granted'] == true) return LocationPermission.granted;
      if (!interactive) return LocationPermission.denied;
      final granted = await _channel.invokeMethod<bool>('requestPermission');
      return granted == true
          ? LocationPermission.granted
          : LocationPermission.denied;
    } on MissingPluginException {
      return LocationPermission.unsupported;
    } on PlatformException {
      // 平台异常（老系统/权限弹窗被系统拦下）也别崩：当作这次没给
      return LocationPermission.denied;
    }
  }

  @override
  Future<bool> serviceEnabled() async {
    if (!_allowed) {
      _logBlocked('serviceEnabled');
      return false;
    }
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      return status?['serviceEnabled'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<DeviceLocation?> current() async {
    if (!_allowed) {
      _logBlocked('current');
      return null;
    }
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('current');
      if (map == null) return null;
      final lat = (map['latitude'] as num?)?.toDouble();
      final lng = (map['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;
      return DeviceLocation(
        latitude: lat,
        longitude: lng,
        accuracyM: (map['accuracy'] as num?)?.toDouble(),
        provider: '${map['provider'] ?? ''}',
        timeMs: (map['time'] as num?)?.toInt() ?? 0,
      );
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> clearCache() async {
    if (!_allowed) {
      _logBlocked('clearCache');
      return;
    }
    try {
      await _channel.invokeMethod<bool>('clearCache');
    } catch (_) {
      // 没有平台实现时无所谓
    }
  }
}
