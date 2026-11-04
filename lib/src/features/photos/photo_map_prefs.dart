// 相册「地图链接」的**状态层**：区域判定、用户覆盖（可持久化）、启动器。
//
// 为什么单独一个文件：`photo_map_links.dart` 要能**纯 Dart** 跑（单测/探针），
// 不能碰 flutter 的插件与 `dart:ui`；`url_launcher`、`PlatformDispatcher`、
// `flutter_secure_storage` 都在这里，界面层只读 provider。
//
// 覆盖为什么要落盘：区域判定只看**设备 locale 的国家码**（不是物理位置），
// 国人系统语言设成英文(美国)时会给 `US` → 默认跳 Google，在国内直接打不开。
// 所以 `"使用哪个地图服务"` **必须**可被用户手选并记住（用户要求逐字：
// "国外用谷歌地图，国内选国内的地图"）。
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/system_open.dart' show isTestEnvironment;
import 'photo_map_links.dart';
import '../../core/platform/app_secure_storage.dart';

/// 用户覆盖的落盘 key。改这个字符串会让用户旧选择读不回来。
const String kPhotoMapServiceSlot = 'photo_map_service';

/// 「境外服务 + 精确坐标」一次性告知的落盘 key。
///
/// 坐标 = 行踪轨迹 = **敏感个人信息**；把坐标交给 **境外** 服务（Google）
/// 属于**数据出境**，按合规要求必须**单独告知并取得同意**。本 key 记住
/// "用户已经确认过"，避免每次打开都弹。改字符串会让用户旧确认读不回来。
const String kPhotoMapOverseasConsentSlot = 'photo_map_overseas_consent_v1';

/// 地图服务偏好的存取（安全存储；失败一律静默，绝不让地点页崩）。
///
/// 用 `flutter_secure_storage` 而不是普通 SharedPreferences 的原因很现实：
/// 本批次**不许**改 `pubspec.yaml`、**不许**改 `lib/src/core/**`，而 core 的设置门面
/// (`SettingsService`) 的 key 都是写死的、也没有公开的裸 KV 写入口。
/// 安全存储是**既有依赖**（`lib/src/core/settings/cloud_key_store.dart` 同款），
/// 值本身不是秘密，放这里只是"能持久化且不动 core"的最短路径。
abstract class PhotoMapPrefsStore {
  Future<String?> read();
  Future<void> write(String? serviceId);

  /// 「境外（Google）+ 精确坐标」是否已一次性确认过。
  Future<bool> readOverseasConsent();

  /// 记住用户的确认（`true` = 同意过；`false` = 撤销/清除）。
  Future<void> writeOverseasConsent(bool granted);
}

class SecurePhotoMapPrefsStore implements PhotoMapPrefsStore {
  SecurePhotoMapPrefsStore([FlutterSecureStorage? storage])
    : _storage =
          storage ?? appSecureStorage(android: const AndroidOptions());

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: kPhotoMapServiceSlot);
    } catch (_) {
      // Keystore 损坏 / 桌面无插件 → 当作"用户没选过"
      return null;
    }
  }

  @override
  Future<void> write(String? serviceId) async {
    try {
      if (serviceId == null || serviceId.isEmpty) {
        await _storage.delete(key: kPhotoMapServiceSlot);
        return;
      }
      await _storage.write(key: kPhotoMapServiceSlot, value: serviceId);
    } catch (_) {
      // 写不进去不影响本次会话使用（内存里的 state 已经更新）
    }
  }

  @override
  Future<bool> readOverseasConsent() async {
    try {
      return await _storage.read(key: kPhotoMapOverseasConsentSlot) ==
          'granted';
    } catch (_) {
      // 读不出来 → **当作没同意**（保守：宁可不弹少，不可少弹）
      return false;
    }
  }

  @override
  Future<void> writeOverseasConsent(bool granted) async {
    try {
      if (!granted) {
        await _storage.delete(key: kPhotoMapOverseasConsentSlot);
        return;
      }
      await _storage.write(key: kPhotoMapOverseasConsentSlot, value: 'granted');
    } catch (_) {
      // 同 write：写不进去只影响"下次要不要再弹"
    }
  }
}

/// 内存实现（单测用）。
class MemoryPhotoMapPrefsStore implements PhotoMapPrefsStore {
  MemoryPhotoMapPrefsStore([this._value, this._overseasConsent = false]);

  String? _value;
  bool _overseasConsent;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String? serviceId) async => _value = serviceId;

  @override
  Future<bool> readOverseasConsent() async => _overseasConsent;

  @override
  Future<void> writeOverseasConsent(bool granted) async =>
      _overseasConsent = granted;
}

final photoMapPrefsStoreProvider = Provider<PhotoMapPrefsStore>(
  (ref) => SecurePhotoMapPrefsStore(),
);

/// 用户选择的"用哪个地图服务"。`null` = 没有覆盖，按区域自动判。
class PhotoMapServiceNotifier extends Notifier<PhotoMapService?> {
  @override
  PhotoMapService? build() => null;

  /// 从落盘读回（地点页 `initState` 调一次）
  Future<void> preload() async {
    final raw = await ref.read(photoMapPrefsStoreProvider).read();
    final parsed = PhotoMapService.fromId(raw);
    if (ref.mounted) state = parsed;
  }

  /// 手选（传 `null` = 恢复"跟随地区"）
  Future<void> setOverride(PhotoMapService? service) async {
    state = service;
    await ref.read(photoMapPrefsStoreProvider).write(service?.id);
  }
}

final photoMapServiceProvider =
    NotifierProvider<PhotoMapServiceNotifier, PhotoMapService?>(
      PhotoMapServiceNotifier.new,
    );

/// 「境外（Google）+ 精确坐标」的一次性告知状态。
///
/// 语义：`false` = 还没确认过（首次把坐标发给 Google 前必须弹一次告知）；
/// `true` = 已确认，之后不再打扰。**只有 Google 需要**：高德 / 腾讯 / 百度
/// 都是境内服务，不涉及数据出境（坐标仍是个人信息，所以默认不显示数字）。
class PhotoMapOverseasConsentNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// 从落盘读回（弹层 `initState` 调一次）
  Future<void> preload() async {
    final granted = await ref
        .read(photoMapPrefsStoreProvider)
        .readOverseasConsent();
    if (ref.mounted) state = granted;
  }

  /// 用户点了"同意"
  Future<void> grant() async {
    state = true;
    await ref.read(photoMapPrefsStoreProvider).writeOverseasConsent(true);
  }
}

final photoMapOverseasConsentProvider =
    NotifierProvider<PhotoMapOverseasConsentNotifier, bool>(
      PhotoMapOverseasConsentNotifier.new,
    );

/// 区域判定的输入：设备 locale 的国家码。
///
/// **已知局限**（必须如实标注，见 `docs/photo-map-evaluation.md` §4）：
///   * locale 是"系统语言/地区设置"，**不是物理位置**；
///   * 纯 Dart 拿不到 IANA 时区（`DateTime.timeZoneName` 在 Android 是 `CST` 这类
///     缩写，没法映射国家），所以这里**只喂国家码**；
///     纯函数 `defaultPhotoMapService(countryCode:, timezone:)` 保留了时区入参，
///     将来若由日程模块传入 IANA 时区即可启用，第一期不跨模块取；
///   * **绝不**用 VPN 出口 IP 猜（会南辕北辙）。
final photoMapRegionCountryCodeProvider = Provider<String>(
  (ref) => (PlatformDispatcher.instance.locale.countryCode ?? '').toUpperCase(),
);

/// 当前生效的服务：用户覆盖优先，否则按区域判定。
final resolvedPhotoMapServiceProvider = Provider<PhotoMapService>((ref) {
  final override = ref.watch(photoMapServiceProvider);
  if (override != null) return override;
  return defaultPhotoMapService(
    countryCode: ref.watch(photoMapRegionCountryCodeProvider),
  );
}, dependencies: [photoMapServiceProvider, photoMapRegionCountryCodeProvider]);

/// 生产用的"打开 URL"实现：`ACTION_VIEW` 交给系统（App scheme 或 https 都走它）。
///
/// * `flutter test` 里**直接返回 false**（不启动任何外部程序，和
///   `core/system_open.dart` 同一约定）→ 测试要断言就得覆盖
///   `photoMapLauncherProvider`；
/// * scheme 没装对应 App / 被 Android 11+ 包可见性挡住 → `launchUrl` 抛异常或
///   返回 false → 由 `openPhotoMapLink` 回落网页。
Future<bool> defaultPhotoMapLaunch(Uri uri) async {
  if (isTestEnvironment) return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

final photoMapLauncherProvider = Provider<PhotoMapLauncher>(
  (ref) => defaultPhotoMapLaunch,
);
