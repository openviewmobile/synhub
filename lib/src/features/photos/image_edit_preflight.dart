// 图生图的**发起前门控（探测 + 拦截）** —— 把方案 §2.2 的 L1..L5 与 §8 的
// 离线分支落成一个**纯函数**（可离线单测，不碰网络/设备）。
//
// 总纪律（方案 §8 尾）：**任何分支都不得"静默回到初始态"**。所以这个函数
// 永远返回"要拦就返回一个确定的错误类型"，绝不返回 null 之外的模糊状态。
import '../../core/net/network_type.dart';
import '../../data/ai/cloud_pricing.dart';
import '../../data/ai/image_edit_client.dart';
import '../../data/ai/image_edit_pricing.dart';

/// 发起前判定。返回要拦的错误类型；`null` = 放行。
///
/// 顺序对齐方案 §2.2（L1 开关 → L2 已配置 → L3 同意 → key → 网络 → L4 仅 WiFi
/// → L5 额度）。放在最前面的都是"确定不可能"，越靠后越接近"能试一下"。
ImageEditErrorKind? imageEditPreflight({
  required bool enabled,
  required bool consent,
  required bool backendConfigured,
  required bool keyPresent,
  required NetworkType network,
  required bool wifiOnly,
  required bool allowMobile,
  required List<CloudUsageRecord> records,
  required int nowMs,
  required int dailyCap,
  int requestedImages = 1,
}) {
  // L1 总开关关闭：入口隐藏 + client 层再拦一次
  if (!enabled) return ImageEditErrorKind.disabled;
  // L2 后端没配好
  if (!backendConfigured) return ImageEditErrorKind.backendNotConfigured;
  // L3 一次性同意
  if (!consent) return ImageEditErrorKind.consentRequired;
  // 云端后端没有 key：不发请求
  if (!keyPresent) return ImageEditErrorKind.missingKey;
  // 无网络：不发请求，立即返回
  if (network == NetworkType.none) return ImageEditErrorKind.noNetwork;
  // 仅 WiFi：mobile/other 直接拦；网络类型**查不出**时按非 WiFi 保守处理，
  // 但用单独的 kind 让 UI 能说清"是查不出，不是确定在用流量"
  if (wifiOnly && !allowMobile) {
    if (network == NetworkType.wifi) {
      // 放行
    } else if (network == NetworkType.unknown) {
      return ImageEditErrorKind.networkUnknown;
    } else {
      return ImageEditErrorKind.wifiOnlyBlocked;
    }
  }
  // L5 单日额度（发起前拦；变体数计入）
  return imageEditQuotaBlock(
    records: records,
    nowMs: nowMs,
    cap: dailyCap,
    requested: requestedImages,
  );
}
