// 当前网络类型（Wi-Fi / 移动数据 / 其它）。
//
// 为什么需要它：原版「收到消息通知时预加载消息」默认是 **仅 Wi-Fi**
// （`pref_setting.xml` 的 `preview_new_message` 默认 `ONLY_WIFI`），
// `PostPreviewWorker.fetchServerPostIfNecessary` 拿
// `ConnectionStateManager.getCurrentNetworkType() == 1` 判 Wi-Fi。
// 我们不想为一个布尔判断引入 `connectivity_plus`，所以自己开一个
// 极小的 MethodChannel（Android 侧 `NetworkBridge.kt`，`ConnectivityManager`）。
//
// 判定不出来（桌面/测试/权限缺失）时给 [NetworkType.unknown] —— 调用方
// **按"不是 Wi-Fi"处理**（保守：不偷偷用流量）。
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';

/// 与原版 `ConnectionStateManager` 的取值对齐
enum NetworkType {
  /// `TYPE_WIFI`（原版 int 1）
  wifi('wifi'),

  /// `TYPE_MOBILE`
  mobile('mobile'),

  /// 以太网 / VPN / 其它有网的情况
  other('other'),

  /// 没网
  none('none'),

  /// 查不出来
  unknown('unknown');

  const NetworkType(this.rawValue);

  final String rawValue;

  static NetworkType fromRaw(String? raw) => switch (raw) {
    'wifi' => NetworkType.wifi,
    'mobile' => NetworkType.mobile,
    'other' => NetworkType.other,
    'none' => NetworkType.none,
    _ => NetworkType.unknown,
  };

  /// 这个网络下能不能预加载（原版 `PreviewMode.ONLY_WIFI` 只认 Wi-Fi；
  /// `WIFI_AND_OTHER` 连移动数据也认）
  bool get isWifi => this == NetworkType.wifi;
}

/// 网络类型探针（测试里覆盖成固定值）
abstract class NetworkTypeProbe {
  Future<NetworkType> current();
}

/// 生产实现：走 Android 的 `ConnectivityManager`
class MethodChannelNetworkTypeProbe implements NetworkTypeProbe {
  MethodChannelNetworkTypeProbe({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('synhub/network');

  final MethodChannel _channel;

  @override
  Future<NetworkType> current() async {
    // ★ 第 55 轮：这一处的平台判断改问**能力层**（不再裸看
    // `defaultTargetPlatform`）—— `synhub/network` 是 Android
    // `ConnectivityManager` 的桥，宿主能力层报
    // `unavailable:not-implemented-on-host` ⇒ `mayTry == false` ⇒
    // 明确回 [NetworkType.unknown] 并**连通道都不碰**。
    // Android 上静态结论是 `unknown`（放过去试桥），与旧判断等价。
    // 语义保持原样：unknown ⇒ 调用方按"不是 Wi-Fi"保守处理。
    if (!capabilityGateAllows(AppCapability.networkInfo)) {
      return NetworkType.unknown;
    }
    try {
      final raw = await _channel.invokeMethod<String>('current');
      return NetworkType.fromRaw(raw);
    } catch (_) {
      // 平台没实现（桌面/测试）或权限不足：当作查不出来
      return NetworkType.unknown;
    }
  }
}

/// `synhub/network` 上读 MCC 的方法名。
///
/// ★ **与 `NetworkBridge.kt` 的 `when` 分支逐字对应**（跨语言契约）。
/// 单测的 Mock 通道**证不了**这一点（Mock 会照着 Dart 侧的名字答应），
/// 改名只会让**真机**静默失效 ⇒ 由 `test/network_country_iso_test.dart`
/// 的静态守卫直接读 Kotlin 源文件比对。
const String kNetworkCountryIsoMethod = 'networkCountryIso';

/// 网络**注册地**国家码（Android `TelephonyManager.getNetworkCountryIso()`，形如 `cn`）。
///
/// 这是官方 QuickConnect `QuickConnectUtil.isDeviceInChina(Context)` 的
/// **第一顺位**输入。`[取证]`：官方 APK `Android-DSfinder.2.5.7-484.ww.apk` 的
/// `com/synology/sylibx/syhttp3/util/QuickConnectUtil.smali` ——
/// **MCC 非空即判 `"cn".equals(iso, ignoreCase)` 并到此为止（不再看 locale）**，
/// 为空才回落 `getResources().getConfiguration().locales[0].getISO3Country()=="CHN"`。
///
/// 为什么需要它：只看 locale 会把"系统语言设成英文、人在中国"的用户判成非中国区
/// ⇒ 官方客户端会先试 `global.quickconnect.cn`、我们却先试 `.to` ⇒ **首次登录更慢**。
///
/// ★ **拿不到一律回 `null`，绝不回 `false`**（AGENTS §2.0.26④「不知道必须与假分开」）：
/// 非 Android（宿主能力层报 `unavailable:not-implemented-on-host`，**连通道都不碰**）、
/// 没有电话服务 / Wi-Fi-only 设备、桥抛异常 —— 全部回 `null`，
/// 由调用方按官方同款顺序**回落 locale**。
/// 回 `false` 会把"不知道"伪造成"不在中国" —— 那是**编造结论**。
///
/// ★ 走的是**已有**的 `synhub/network` 桥与**已有**的 [AppCapability.networkInfo]
/// 能力门：**不新开平台通道、不新造平台信息抽象**。
Future<String?> platformNetworkCountryIso({MethodChannel? channel}) async {
  if (!capabilityGateAllows(AppCapability.networkInfo)) return null;
  try {
    final raw = await (channel ?? const MethodChannel('synhub/network'))
        .invokeMethod<String>(kNetworkCountryIsoMethod);
    final trimmed = raw?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  } catch (_) {
    // 平台没实现（桌面/测试）/ 没有电话服务 / 权限不足：一律"查不出来" ⇒ null
    return null;
  }
}
