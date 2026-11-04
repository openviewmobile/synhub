// 中国境内的坐标偏移换算：**BD09 / GCJ02 → WGS84**。
//
// 为什么必须有这个：日程里的 `location_info.gps` 会带 `map_type`，
// 官方 Web UI 用百度/高德地图时存的是**偏移后**的坐标（BD09 偏 ~500m，
// GCJ02 偏 ~300m）。偏移本身不大，但**country 反查、天气格点**都是按坐标取数的，
// 而且"在中国用百度坐标"与"在境外用 WGS84"混在一起时，反查会直接落到隔壁国家。
// 所以：**只在中国境内**做换算，境外原样返回。
//
// 算法是公开的（GCJ02 的加密偏移公式 + BD09 的二次偏移），这里按 Dart 重写，
// 并用**往返一致性**与公开的"天安门参考点"两组断言钉住（见 test/env_info_test.dart）。
import 'dart:math' as math;

const double kChinaLatMin = 0.8293;
const double kChinaLatMax = 55.8271;
const double kChinaLngMin = 72.004;
const double kChinaLngMax = 137.8347;

/// 是否在中国境外（境外不做任何偏移）
bool isOutOfChina(double lat, double lng) =>
    lng < kChinaLngMin ||
    lng > kChinaLngMax ||
    lat < kChinaLatMin ||
    lat > kChinaLatMax;

const double _a = 6378245.0; // 克拉索夫斯基椭球长半轴
const double _ee = 0.00669342162296594323; // 偏心率平方

double _transformLat(double x, double y) {
  var ret =
      -100.0 +
      2.0 * x +
      3.0 * y +
      0.2 * y * y +
      0.1 * x * y +
      0.2 * math.sqrt(x.abs());
  ret +=
      (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret +=
      (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret +=
      (160.0 * math.sin(y / 12.0 * math.pi) +
          320 * math.sin(y * math.pi / 30.0)) *
      2.0 /
      3.0;
  return ret;
}

double _transformLng(double x, double y) {
  var ret =
      300.0 +
      x +
      2.0 * y +
      0.1 * x * x +
      0.1 * x * y +
      0.1 * math.sqrt(x.abs());
  ret +=
      (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret +=
      (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret +=
      (150.0 * math.sin(x / 12.0 * math.pi) +
          300.0 * math.sin(x / 30.0 * math.pi)) *
      2.0 /
      3.0;
  return ret;
}

/// WGS84 → GCJ02（火星坐标）
({double lat, double lng}) wgs84ToGcj02(double lat, double lng) {
  if (isOutOfChina(lat, lng)) return (lat: lat, lng: lng);
  var dLat = _transformLat(lng - 105.0, lat - 35.0);
  var dLng = _transformLng(lng - 105.0, lat - 35.0);
  final radLat = lat / 180.0 * math.pi;
  var magic = math.sin(radLat);
  magic = 1 - _ee * magic * magic;
  final sqrtMagic = math.sqrt(magic);
  dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
  dLng = (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
  return (lat: lat + dLat, lng: lng + dLng);
}

/// GCJ02 → WGS84（反解：迭代逼近，误差 <1e-7 度 ≈ 1cm）
({double lat, double lng}) gcj02ToWgs84(double lat, double lng) {
  if (isOutOfChina(lat, lng)) return (lat: lat, lng: lng);
  var wgsLat = lat;
  var wgsLng = lng;
  for (var i = 0; i < 6; i++) {
    final guess = wgs84ToGcj02(wgsLat, wgsLng);
    final dLat = guess.lat - lat;
    final dLng = guess.lng - lng;
    if (dLat.abs() < 1e-7 && dLng.abs() < 1e-7) break;
    wgsLat -= dLat;
    wgsLng -= dLng;
  }
  return (lat: wgsLat, lng: wgsLng);
}

/// GCJ02 → BD09（百度在火星坐标上再做一次偏移）
({double lat, double lng}) gcj02ToBd09(double lat, double lng) {
  const xPi = math.pi * 3000.0 / 180.0;
  final z = math.sqrt(lat * lat + lng * lng) + 0.00002 * math.sin(lng * xPi);
  final theta = math.atan2(lat, lng) + 0.000003 * math.cos(lng * xPi);
  return (lat: z * math.sin(theta) + 0.006, lng: z * math.cos(theta) + 0.0065);
}

/// BD09 → GCJ02
({double lat, double lng}) bd09ToGcj02(double lat, double lng) {
  const xPi = math.pi * 3000.0 / 180.0;
  final x = lng - 0.0065;
  final y = lat - 0.006;
  final z = math.sqrt(x * x + y * y) - 0.00002 * math.sin(y * xPi);
  final theta = math.atan2(y, x) - 0.000003 * math.cos(x * xPi);
  return (lat: z * math.sin(theta), lng: z * math.cos(theta));
}

/// BD09 → WGS84
({double lat, double lng}) bd09ToWgs84(double lat, double lng) {
  final gcj = bd09ToGcj02(lat, lng);
  return gcj02ToWgs84(gcj.lat, gcj.lng);
}

/// 按日程里的 `map_type` 归一成 WGS84。
///
/// 取值（官方 Web UI 用的就是这几个）：`baidu` → BD09；`google`（实际是 GCJ02，
/// 境内地图服务都这样）→ GCJ02；其余/空 → 当成 WGS84 原样返回。
({double lat, double lng}) toWgs84(
  double lat,
  double lng, {
  String mapType = '',
}) {
  final t = mapType.toLowerCase();
  if (t.contains('baidu') || t.contains('bd')) return bd09ToWgs84(lat, lng);
  if (t.contains('google') || t.contains('gcj') || t.contains('amap')) {
    return gcj02ToWgs84(lat, lng);
  }
  return (lat: lat, lng: lng);
}
