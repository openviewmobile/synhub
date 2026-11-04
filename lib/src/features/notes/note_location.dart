// N4：笔记**位置 / 地理标签**的数据层与能力位。
//
// ★ 官方形态（三路取证，逐条对应实现）：
//   1. **写**：`Note/set` 发 `latitude`/`longitude`（Gson→JSON **数字**，非 null 就发）
//      与 `location`（**非空才发**）—— APK `callables/operations/SetNoteOperation.java:233-244`；
//      回包字段同名 —— `vos/api/NoteVo.java:41-44`。`Note/create` 只发坐标、不发
//      `location` —— 官方 Web `createNoteAsync` 的白名单 `…ctime,mtime,latitude,longitude`。
//   2. **查**：`SYNO.NoteStation.Info` **v1** 的 `searchplace`，线参
//      `{format:true, radius:500, location:"<lat>,<lng>", query:"<关键字>"}`
//      —— 官方 Web `Map.Panel.getSearchStore` / `beforeload`；方法表出处
//      SPK `webapi/SYNO.NoteStation.lib`。见 [NoteStationApi.searchPlace]。
//   3. **显**：官方 `Info.Panel` 的可见行是 `location_display`，值由
//      `getLocationDisplayText(location, latitude, longitude)` 生成：
//        有名字 + 非零坐标 → `"{名称} ({lat},{lng})"`（坐标保留 2 位小数）
//        无名字 + 非零坐标 → `"({lat},{lng})"`
//        其它（含坐标 0）→ 名称原文（可能为空）
//      —— 官方 Web `ui/notestation.js` 逐字。
//
// ★ 能力位降级（不伪造位置）：
//   * `SYNO.NoteStation.Info` 不在能力表 → **整个位置入口隐藏**（[noteLocationCapabilityProvider]）；
//   * 设备定位：**没有权限 / 平台不支持 / 取不到坐标** → "用当前位置"不出现，
//     **绝不编一个坐标**；`searchplace` 的 `location` **必须是真坐标**，
//     否则真机上请求会挂到超时（只读探针实测）。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../data/dto/note_dto.dart';
import '../../data/note_api.dart';
import '../../data/region/device_location.dart';
import 'note_providers.dart';

/// 官方 `getLocationDisplayText` 的逐字移植（`ui/notestation.js`）。
///
/// 注意官方的判据是 **`location !== "" && lat !== 0 && lng !== 0`**，
/// 所以 `0` 坐标（= "已删除 GPS"）**不会**被当成有效位置。
String noteLocationDisplayText(
  String? location,
  double? latitude,
  double? longitude,
) {
  final name = (location ?? '').trim();
  final hasGps =
      latitude != null &&
      longitude != null &&
      latitude != 0 &&
      longitude != 0;
  if (!hasGps) return name;
  final coords =
      '(${latitude.toStringAsFixed(2)},${longitude.toStringAsFixed(2)})';
  return name.isEmpty ? coords : '$name $coords';
}

/// 这条笔记有没有可上屏的位置信息（名字或非零坐标）。
bool noteHasLocation(NoteDto note) =>
    noteLocationDisplayText(
      note.location,
      note.latitude,
      note.longitude,
    ).isNotEmpty;

/// 位置能力位。
///
/// 官方 `searchplace` 与 `Info/get` 同属 `SYNO.NoteStation.Info`（方法表 v1/v2/v3
/// 都有 `searchplace`）；`SYNO.API.Info` 只给 API 名、不给方法名，所以门控口径
/// 就是"这个 API 在不在能力表里"。缺位 → 位置入口隐藏；未检测 → fail-open。
final noteLocationCapabilityProvider = Provider<bool>((ref) {
  final snapshot = ref.watch(serviceAvailabilityProvider);
  return snapshot.hasApi(StationService.note, NoteStationApi.infoApi);
});

/// 设备定位探针（复用数据层已有的 MethodChannel 实现；测试覆盖成假实现）。
final noteDeviceLocationProbeProvider = Provider<DeviceLocationProbe>(
  (ref) => MethodChannelDeviceLocationProbe(),
);

/// 定位权限现状（**不弹**系统授权框，只查；与日历同一纪律）。
final noteLocationPermissionProvider = FutureProvider<LocationPermission>(
  (ref) async {
    final probe = ref.watch(noteDeviceLocationProbeProvider);
    return probe.ensurePermission(interactive: false);
  },
  retry: noRetry,
  dependencies: [noteDeviceLocationProbeProvider],
);

/// 取一次设备坐标；权限没给 / 开关没开 / 取不到 → **null**（不抛、不编）。
final noteDeviceLocationProvider = FutureProvider<DeviceLocation?>((ref) async {
  final probe = ref.watch(noteDeviceLocationProbeProvider);
  final permission = await probe.ensurePermission(interactive: false);
  if (permission != LocationPermission.granted) return null;
  if (!await probe.serviceEnabled()) return null;
  final fix = await probe.current();
  if (fix == null || !fix.isUsable) return null;
  return fix;
}, retry: noRetry, dependencies: [noteDeviceLocationProbeProvider]);

/// 地点搜索的 key：中心点 + 关键字（值相等即同一次搜索）。
@immutable
class NotePlaceQuery {
  const NotePlaceQuery({
    required this.latitude,
    required this.longitude,
    required this.query,
  });

  final double latitude;
  final double longitude;
  final String query;

  @override
  bool operator ==(Object other) =>
      other is NotePlaceQuery &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.query == query;

  @override
  int get hashCode => Object.hash(latitude, longitude, query);

  @override
  String toString() => 'NotePlaceQuery($query)';
}

/// `searchplace` 的结果（只读查询，`autoDispose` + 关自动重试）。
final notePlaceSearchProvider = FutureProvider.autoDispose
    .family<List<NotePlaceDto>, NotePlaceQuery>((ref, q) async {
      final api = ref.watch(noteApiProvider);
      if (api == null) return const <NotePlaceDto>[];
      return api.searchPlace(
        latitude: q.latitude,
        longitude: q.longitude,
        query: q.query,
      );
    }, retry: noRetry);
