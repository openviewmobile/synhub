// FileStation **G4 批次**新增文案：**key + 中文原文**，与
// `filestation_p0b_text.dart` / `filestation_c5_text.dart` 同构。
// key 已同步追加进 `lib/l10n/app_zh.arb` / `app_en.arb`。
import '../../core/i18n/data_text.dart';

/// 取 G4 文案
String fsG4(String key, String zh) => dataText(key, zh);

/// 带 `{...}` 占位符的文案填充
String fsG4Fill(String key, String zh, Map<String, String> values) {
  var out = fsG4(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// FileStation G4 新增的 ARB key
abstract final class FsG4TextKeys {
  // ---- 146 多卷解压提示
  static const volumeFirstTitle = 'fsG4VolumeFirstTitle';
  static const volumeFirstBody = 'fsG4VolumeFirstBody';
  static const volumeLaterTitle = 'fsG4VolumeLaterTitle';
  static const volumeLaterBody = 'fsG4VolumeLaterBody';
  static const volumeKindRarPart = 'fsG4VolumeKindRarPart';
  static const volumeKindRarOld = 'fsG4VolumeKindRarOld';
  static const volumeKindNumeric = 'fsG4VolumeKindNumeric';
  static const volumeKindZip = 'fsG4VolumeKindZip';

  // ---- 文件「工具」入口（223 + 219 的公共入口）
  static const toolsTitle = 'fsG4ToolsTitle';

  // ★ 246 轮 D66：SAF「按需下载」设置页
  static const safOnDemandTitle = 'fsG4SafOnDemandTitle';
  static const safOnDemandSection = 'fsG4SafOnDemandSection';
  static const safOnDemandTurnOn = 'fsG4SafOnDemandTurnOn';
  static const safOnDemandTurnOff = 'fsG4SafOnDemandTurnOff';
  static const safOnDemandOnDesc = 'fsG4SafOnDemandOnDesc';
  static const safOnDemandOffDesc = 'fsG4SafOnDemandOffDesc';
  static const safOnDemandClearCache = 'fsG4SafOnDemandClearCache';
  static const safOnDemandClearCacheDesc = 'fsG4SafOnDemandClearCacheDesc';
  static const safOnDemandHint = 'fsG4SafOnDemandHint';
  static const safOnDemandNeedPassword = 'fsG4SafOnDemandNeedPassword';
  static const safOnDemandEnabled = 'fsG4SafOnDemandEnabled';
  static const safOnDemandDisabled = 'fsG4SafOnDemandDisabled';
  static const safOnDemandNotConfigured = 'fsG4SafOnDemandNotConfigured';
  static const safOnDemandCacheCleared = 'fsG4SafOnDemandCacheCleared';
  static const toolsSection = 'fsG4ToolsSection';

  // ---- 223 USB / 外接设备
  static const usbTitle = 'fsG4UsbTitle';
  static const usbEntry = 'fsG4UsbEntry';
  static const usbEmpty = 'fsG4UsbEmpty';
  static const usbEmptyBody = 'fsG4UsbEmptyBody';
  /// r370：`list` 被服务端拒/找不到（App 把 DSM 的 404 折算成"空"）时，**不要**
  /// 再叫用户"把 U 盘插上" —— 真机上 U 盘已插、FileStation 也能看到它，
  /// 但这一列在 DSM 侧通常只对管理员开放（官方 FileStation 前端
  /// `initExtDeviceInfo` 就是 `_S("is_admin") && …`）。见 DA25。
  static const usbNoDeviceTitle = 'fsG4UsbNoDeviceTitle';
  static const usbNoDeviceBody = 'fsG4UsbNoDeviceBody';
  static const usbLoadFailed = 'fsG4UsbLoadFailed';
  static const usbEject = 'fsG4UsbEject';
  static const usbEjectConfirmTitle = 'fsG4UsbEjectConfirmTitle';
  static const usbEjectConfirmBody = 'fsG4UsbEjectConfirmBody';
  static const usbEjectDone = 'fsG4UsbEjectDone';
  static const usbEjectFailed = 'fsG4UsbEjectFailed';
  static const usbPartition = 'fsG4UsbPartition';
  static const usbStatus = 'fsG4UsbStatus';
  static const usbUsedOfTotal = 'fsG4UsbUsedOfTotal';

  // ---- 219 离线文件（Pin）
  static const offlineTitle = 'fsG4OfflineTitle';
  static const offlineEntry = 'fsG4OfflineEntry';
  static const offlineEntrySubtitle = 'fsG4OfflineEntrySubtitle';
  static const offlineEmpty = 'fsG4OfflineEmpty';
  static const offlineEmptyBody = 'fsG4OfflineEmptyBody';
  static const offlinePin = 'fsG4OfflinePin';
  static const offlineUnpin = 'fsG4OfflineUnpin';
  static const offlinePinned = 'fsG4OfflinePinned';
  static const offlineUnpinned = 'fsG4OfflineUnpinned';
  static const offlineRemove = 'fsG4OfflineRemove';
  static const offlineOnlyFiles = 'fsG4OfflineOnlyFiles';
  static const offlineCount = 'fsG4OfflineCount';
  // 219 的容量提示（本批补齐）
  static const offlineTotal = 'fsG4OfflineTotal';
  static const offlineTotalPartial = 'fsG4OfflineTotalPartial';
  // ★ 302：离线文件的**真缓存到本机**（此前 localPath 无生产者，恒"未缓存"）
  static const offlineCached = 'fsG4OfflineCached';
  static const offlineCacheFailed = 'fsG4OfflineCacheFailed';
  static const offlineCacheNow = 'fsG4OfflineCacheNow';
  static const offlineNotCached = 'fsG4OfflineNotCached';
}
