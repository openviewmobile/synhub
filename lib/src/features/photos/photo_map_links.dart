// 相册「地点」→「在地图中打开」的**纯函数层**（第一期：外部地图，零依赖、零 key）。
//
// 本文件是 `docs/photo-map-evaluation.md` 里推荐的 **方案 A** 的落地：
//   * 我们**只拼 URL**，把 URL 交给系统（`url_launcher`，pubspec 里**既有**的依赖）——
//     **不发任何网络请求**，也不持有任何地图 API key；
//   * 区域检测只用 Dart 侧可得的信号（国家码 / IANA 时区），**不猜 VPN 出口 IP**；
//   * 境内默认高德、境外默认 Google，**可被用户覆盖**（见 `photo_map_prefs.dart`）。
//
// 坐标系（证据见 docs/photo-map-evaluation.md §2）：
//   * 我们手里/未来的 GPS 坐标是 **WGS-84**；
//   * 高德网页 URI 官方支持 `coordinate=wgs84` → **直传 WGS-84，不转换**；
//   * 腾讯 / 百度 App scheme 都吃 **GCJ-02** → 用数据层既有的
//     `wgs84ToGcj02`（`lib/src/data/region/china_gps.dart`）在**本地**换算。
//     换算公式本身是公开的，不涉及"公开算法"的合规问题，详见评估文档 §2 的原文引用。
//   * 高德**不**走 App scheme：官方写的是 `androidamap://viewMap`，而 Dart 的 `Uri`
//     会把 authority 归一成小写（`viewMap` → `viewmap`），我们自己拼字符串也绕不过
//     （`url_launcher` 收 `Uri`）。改走高德官方的 `callnative=1`
//     （网页里尝试调起 App）——URL 形态与官方文档逐字一致，语义等价。
//
// 官方文档来源（逐个 URL 形态都对着原文写，抓取于 2026-09-22）：
//   * 高德 URI API Web · 单点标注：
//     https://lbs.amap.com/api/uri-api/guide/mobile-web/point
//     `https://uri.amap.com/marker?position=lon,lat&name=&coordinate=wgs84|gaode&src=&callnative=0`
//   * 高德 URI API Web · 搜索查询：
//     https://lbs.amap.com/api/uri-api/guide/search/search
//     `https://uri.amap.com/search?keyword=&src=&view=list|map`
//   * 高德 URI API Web · 路径规划：
//     https://lbs.amap.com/api/uri-api/guide/travel/route
//     `https://uri.amap.com/navigation?from=&to=&mode=&callnative=`
//   * 高德 URI API App · Android 地图标注：
//     https://lbs.amap.com/api/amap-mobile/guide/android/marker
//     `androidamap://viewMap?sourceApplication=&poiname=&lat=&lon=&dev=0`
//   * Google Maps URLs（官方格式；本环境网络取不到该页，见评估文档 §1 备注）：
//     `https://maps.google.com/?q=<lat>,<lon>` 或 `?q=<关键词>`
//   * 腾讯位置服务 URI API（页面为 JS 渲染，本环境**未能抓到正文**）：
//     https://lbs.qq.com/webApi/uriV1/uriGuide/uriOverview
//     App 侧形态 `qqmap://map/marker?marker=coord:lat,lng;title:&referer=`
//   * 百度地图 URI API（官方页重定向到 SPA，本环境**未能抓到正文**）：
//     App 侧形态 `baidumap://map/marker?location=lat,lng&title=&content=&coord_type=gcj02&src=`
library;

import '../../data/region/china_gps.dart';
import '../../data/region/region_context.dart';

/// 所有 URL 里带的来源标识（高德 / 腾讯都建议填 `src`）。
const String kPhotoMapSrc = 'synhub';

/// 可选的地图服务。
///
/// 刻意**不**放 `auto`：`auto` 是"用户没有覆盖"的状态，用 `null` 表达，
/// 免得枚举里混一个不是服务的值。
enum PhotoMapService {
  google('google', 'Google 地图'),
  amap('amap', '高德地图'),
  tencent('tencent', '腾讯地图'),
  baidu('baidu', '百度地图');

  const PhotoMapService(this.id, this.zh);

  /// 落盘用的稳定 id（**不要**改，改了会读不回用户旧选择）
  final String id;

  /// 中文名（设置/弹层里的中文回落；多语言走 ARB key）
  final String zh;

  static PhotoMapService? fromId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final s in PhotoMapService.values) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// 主 URL 是「App scheme」还是「网页」
enum PhotoMapUriKind { app, web }

/// 要定位的目标：**坐标可选**，地名可选。
///
/// 关键事实（`docs/photo-map-evaluation.md` §3）：我们手里的
/// `FotoGeocodingPlaceDto`（`lib/src/data/dto/foto_c2_dto.dart:229`）**没有经纬度**，
/// 只有 `id/name/country/country_id/first_level/item_count/thumbnail`。
/// 所以第一期界面里 `latitude/longitude` **恒为 null**，链接只能是"按地名搜索"，
/// 这一点在 UI 上必须如实说明（不许假装是精确定位）。
class PhotoMapTarget {
  const PhotoMapTarget({this.name = '', this.latitude, this.longitude});

  final String name;
  final double? latitude;
  final double? longitude;

  bool get hasCoordinates => latitude != null && longitude != null;

  bool get hasName => name.trim().isNotEmpty;

  /// 有没有任何可用来打开地图的信息
  bool get isUsable => hasCoordinates || hasName;
}

/// 拼出来的地图链接。
class PhotoMapLink {
  const PhotoMapLink({
    required this.service,
    required this.uri,
    required this.kind,
    required this.precise,
    this.fallbackUri,
    this.fallbackService,
  });

  /// 用户/区域选中的服务
  final PhotoMapService service;

  /// 首选 URL（`kind == app` 时是 scheme，`web` 时是 https）
  final Uri uri;
  final PhotoMapUriKind kind;

  /// `true` = 用了坐标（精确定位）；`false` = 只按地名搜索
  final bool precise;

  /// 首选打不开时的回落 URL（通常是对应的 https 页面）
  final Uri? fallbackUri;

  /// 回落页属于哪家（腾讯 / 百度的 key-free 网页不存在，回落到高德网页）
  final PhotoMapService? fallbackService;

  bool get hasFallback => fallbackUri != null;
}

/// 是不是**中国大陆**（港澳台按"Google 可用"处理，默认走 Google；可被用户覆盖）。
///
/// 理由：`国外用谷歌地图，国内选国内的地图` 的现实约束是**大陆**的 Google
/// 不可用（见评估文档 §1）；港澳台 Google 可用，且高德也覆盖，留给用户覆盖。
bool isChinaMainland(String countryCode) =>
    countryCode.trim().toUpperCase() == 'CN';

/// 解析"这是哪儿"的国家码：**显式国家码优先，IANA 时区兜底**。
///
/// `countryCode` 一般来自设备 locale（`PlatformDispatcher.instance.locale.countryCode`，
/// 见 `lib/src/features/calendar/calendar_env.dart:289` 的 `deviceCountryCode()`）。
/// 局限（**必须如实标注**）：locale 反映的是**系统语言/地区设置**，不是物理位置——
/// 人在国内但系统语言是英文(美国)时会给 `US`。所以：
///   * 绝不用 VPN 出口 IP 去猜；
///   * 一律允许用户手动覆盖（`photo_map_prefs.dart`）。
String mapRegionCountryCode({String countryCode = '', String timezone = ''}) {
  final cc = countryCode.trim().toUpperCase();
  if (cc.isNotEmpty) return cc;
  return countryFromTimezone(timezone.trim());
}

/// 按区域给默认服务：中国大陆 → 高德，其余 → Google。
PhotoMapService defaultPhotoMapService({
  String countryCode = '',
  String timezone = '',
}) =>
    isChinaMainland(
      mapRegionCountryCode(countryCode: countryCode, timezone: timezone),
    )
    ? PhotoMapService.amap
    : PhotoMapService.google;

/// 坐标格式化：6 位小数、去掉末尾多余的 0（`39.900000` → `39.9`）。
String photoMapCoord(double v) {
  var s = v.toStringAsFixed(6);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s;
}

String _enc(String v) => Uri.encodeQueryComponent(v);

/// 拼一个地图链接。
///
/// * **首选一定是 https 网页**（Google / 高德）；腾讯、百度没有 key-free 的网页 URI
///   （官方网页 URI 要 `referer` key），所以它们的网页路径统一落到**高德网页**，
///   并置 [PhotoMapLink.fallbackService] = `amap`；
/// * [preferApp] = true 且**有坐标**时，腾讯 / 百度**再**尝试 App scheme
///   （`qqmap://map/...`、`baidumap://map/...` —— 这两家 scheme 的 authority 本来就是
///   小写 `map`，能安全穿过 Dart `Uri` 的 host 归一化）；装不了 App 就回落网页；
/// * 高德**不**用 App scheme：官方 Android 标注页写的是 `androidamap://viewMap`
///   （[来源](https://lbs.amap.com/api/amap-mobile/guide/android/marker)），
///   而 Dart 的 `Uri` 会把 authority 归一成小写（`viewMap` → `viewmap`），
///   自己拼字符串也绕不过去（`url_launcher` 收的是 `Uri`）。
///   所以走高德**官方**的"网页里带 `callnative=1`"机制去调起 App
///   （[来源](https://lbs.amap.com/api/uri-api/guide/mobile-web/point)）——语义等价、
///   且 URL 形态与官方文档逐字一致。这一点在评估文档 §1/§9 里有记录。
/// * **没有坐标**时（第一期的常态）一律"按地名搜索"，`precise == false`，
///   UI 要如实说明，**绝不许**拼出看起来精确的 URL。
PhotoMapLink buildPhotoMapLink({
  required PhotoMapService service,
  required PhotoMapTarget target,
  bool preferApp = true,
}) {
  final name = target.name.trim();
  final precise = target.hasCoordinates;
  final lat = target.latitude;
  final lng = target.longitude;

  switch (service) {
    case PhotoMapService.google:
      // Google 网页链接：坐标是 WGS-84，直传。
      final q = precise
          ? '${photoMapCoord(lat!)},${photoMapCoord(lng!)}'
          : _enc(name);
      return PhotoMapLink(
        service: service,
        uri: Uri.parse('https://maps.google.com/?q=$q'),
        kind: PhotoMapUriKind.web,
        precise: precise,
      );

    case PhotoMapService.amap:
      if (!precise) {
        // 没有坐标：按地名搜索（官方 search URI 同样支持 callnative）
        return PhotoMapLink(
          service: service,
          uri: _amapSearchUri(name, callnative: preferApp),
          kind: PhotoMapUriKind.web,
          precise: false,
        );
      }
      // `coordinate=wgs84`：官方文档明说支持 GPS 原始坐标 → 不换算。
      // `callnative=1`：官方"尝试调起高德地图APP"开关（装了就走 App）。
      return PhotoMapLink(
        service: service,
        uri: _amapMarkerUri(
          lat: lat!,
          lng: lng!,
          name: name,
          coordinate: 'wgs84',
          callnative: preferApp,
        ),
        kind: PhotoMapUriKind.web,
        precise: true,
      );

    case PhotoMapService.tencent:
      // 腾讯 official 坐标体系 = GCJ-02；网页回落交高德，所以先算 GCJ-02 再拼。
      final gcj = precise ? wgs84ToGcj02(lat!, lng!) : null;
      final web = gcj == null
          ? _amapSearchUri(name, callnative: false)
          : _amapMarkerUri(
              lat: gcj.lat,
              lng: gcj.lng,
              name: name,
              // 高德网页用 `coordinate=gaode` 收 GCJ-02
              coordinate: 'gaode',
              callnative: false,
            );
      if (gcj == null || !preferApp) {
        return PhotoMapLink(
          service: service,
          uri: web,
          kind: PhotoMapUriKind.web,
          precise: precise,
          fallbackService: PhotoMapService.amap,
        );
      }
      return PhotoMapLink(
        service: service,
        uri: Uri.parse(
          'qqmap://map/marker?marker=coord:${photoMapCoord(gcj.lat)},'
          '${photoMapCoord(gcj.lng)};title:${_enc(name)};addr:${_enc(name)}'
          '&referer=$kPhotoMapSrc',
        ),
        kind: PhotoMapUriKind.app,
        precise: true,
        fallbackUri: web,
        fallbackService: PhotoMapService.amap,
      );

    case PhotoMapService.baidu:
      // 百度 scheme 收 GCJ-02（`coord_type=gcj02`），不是 BD-09。
      final gcj = precise ? wgs84ToGcj02(lat!, lng!) : null;
      final web = gcj == null
          ? _amapSearchUri(name, callnative: false)
          : _amapMarkerUri(
              lat: gcj.lat,
              lng: gcj.lng,
              name: name,
              coordinate: 'gaode',
              callnative: false,
            );
      if (gcj == null || !preferApp) {
        return PhotoMapLink(
          service: service,
          uri: web,
          kind: PhotoMapUriKind.web,
          precise: precise,
          fallbackService: PhotoMapService.amap,
        );
      }
      return PhotoMapLink(
        service: service,
        uri: Uri.parse(
          'baidumap://map/marker?location=${photoMapCoord(gcj.lat)},'
          '${photoMapCoord(gcj.lng)}&title=${_enc(name)}&content=${_enc(name)}'
          '&coord_type=gcj02&src=$kPhotoMapSrc',
        ),
        kind: PhotoMapUriKind.app,
        precise: true,
        fallbackUri: web,
        fallbackService: PhotoMapService.amap,
      );
  }
}

/// 高德网页「单点标注」。
///
/// `coordinate` 取 `wgs84`（直传 GPS 原始坐标）或 `gaode`（GCJ-02）。
Uri _amapMarkerUri({
  required double lat,
  required double lng,
  required String name,
  required String coordinate,
  required bool callnative,
}) => Uri.parse(
  'https://uri.amap.com/marker?position=${photoMapCoord(lng)},'
  '${photoMapCoord(lat)}&name=${_enc(name)}&coordinate=$coordinate'
  '&src=$kPhotoMapSrc&callnative=${callnative ? 1 : 0}',
);

/// 高德网页「按地名搜索」——**没有坐标时唯一的诚实路径**。
Uri _amapSearchUri(String name, {required bool callnative}) => Uri.parse(
  'https://uri.amap.com/search?keyword=${_enc(name)}&src=$kPhotoMapSrc'
  '&callnative=${callnative ? 1 : 0}',
);

/// 「在地图中打开」的启动器签名（测试里换成记录调用的假实现）。
typedef PhotoMapLauncher = Future<bool> Function(Uri uri);

/// 「这个 App scheme 现在能不能用」的可注入判定。
///
/// 生产侧应传 `url_launcher` 的 `canLaunchUrl`（`photo_map_prefs.dart` 的
/// `defaultPhotoMapLaunch` 同一依赖），测试里传假实现——**绝不真调系统**。
///
/// 为什么需要它：Android 11+（API 30+）的**包可见性**让 `canLaunchUrl` /
/// `launchUrl` 在 `<queries>` 未声明对应 scheme/package 时**直接失败**，且与
/// "App 没装"无法区分。`android/app/src/main/AndroidManifest.xml` 的 `<queries>`
/// 里已声明本 App 真的会调起的地图目标：
/// `qqmap` / `baidumap` / `androidamap` / `amapuri` 四个 scheme，以及
/// `com.tencent.map` / `com.baidu.BaiduMap` / `com.autonavi.minimap` 三个包
/// （**不含** Google Maps：境外走 https，不需要包可见性）。
/// 声明之后 `canLaunch` 才会对已装 App 给 `true` —— 于是"装了 App 就走 App"，
/// 而不是无脑回落网页。
typedef PhotoMapCanLaunch = Future<bool> Function(Uri uri);

/// 一次打开的结果。
class PhotoMapOpenResult {
  const PhotoMapOpenResult({
    required this.ok,
    required this.usedFallback,
    required this.tried,
  });

  final bool ok;
  final bool usedFallback;

  /// 依次尝试过的 URL（断言/日志用）
  final List<Uri> tried;
}

/// 打开地图链接：**先首选，失败再回落**（App 没装 / scheme 被包可见性挡住
/// 都会走到回落）。
///
/// [launcher] 可注入；默认由调用方传（生产实现见 `photo_map_prefs.dart`
/// 的 `defaultPhotoMapLaunch`）。
///
/// [canLaunch] 也可注入（生产侧是 `canLaunchUrl`）。**给了它才启用"scheme 可用性
/// 门控"**，语义是：
///   * 首选不是 App scheme（[PhotoMapUriKind.web]，如 Google / 高德 https）→ 不查，
///     行为与第一期逐字一致；
///   * 首选是 App scheme 且 [canLaunch] 回 **true**（系统里确实有这个 handler，
///     `<queries>` 已声明）→ 正常尝试；**成功就不回落**；
///   * 首选是 App scheme 且 [canLaunch] 回 **false**（没装 / 被包可见性挡住）→
///     不白试一次，**直接**走网页回落；
///   * 无论哪种情况，"尝试了却失败 → 回落"的**降级路径都保留**，一条都不删。
/// [canLaunch] 传 `null` 时**完全等价于**第一期实现（不改 URL 形态、不放宽断言）。
Future<PhotoMapOpenResult> openPhotoMapLink(
  PhotoMapLink link, {
  required PhotoMapLauncher launcher,
  PhotoMapCanLaunch? canLaunch,
}) async {
  final candidates = <Uri>[
    link.uri,
    if (link.fallbackUri != null) link.fallbackUri!,
  ];
  var skippedScheme = false;
  if (canLaunch != null && link.kind == PhotoMapUriKind.app) {
    var available = false;
    try {
      available = await canLaunch(link.uri);
    } catch (_) {
      // 判定本身抛异常（插件缺失等）→ 当作"不可用"，仍走回落，绝不因此崩。
      available = false;
    }
    if (!available) {
      skippedScheme = true;
      candidates.removeAt(0); // 首选就是 link.uri（见上面的构造）
    }
  }
  final tried = <Uri>[];
  for (final uri in candidates) {
    tried.add(uri);
    var ok = false;
    try {
      ok = await launcher(uri);
    } catch (_) {
      ok = false;
    }
    if (ok) {
      return PhotoMapOpenResult(
        ok: true,
        usedFallback: skippedScheme || tried.length > 1,
        tried: tried,
      );
    }
  }
  return PhotoMapOpenResult(
    ok: false,
    usedFallback: skippedScheme,
    tried: tried,
  );
}
