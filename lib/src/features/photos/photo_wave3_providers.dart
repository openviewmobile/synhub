// 相册 wave3 的 provider + 能力门控层：照片 EXIF / 相册缓存 / 相册列表显示偏好。
//
// 与既有相册模块同一套约定：
//   * API 从会话里取（未连接 → null），数据一律 `autoDispose` + **关掉自动重试**
//     （失败要显式给"重试"，绝不让"接口失败"伪装成空结果 / 0）；
//   * 只读，**没有任何写操作**（`Download/clear_cache` 未取证 → 不做）；
//   * 门控复用既有 `ServiceAvailabilitySnapshot.hasApi`（三态 fail-open）：
//       ① 能力位缺失（`SYNO.API.Info` 里没有该 API）→ **隐藏**，且**不发探测请求**；
//       ② 回包 `105`/`160` → 只隐藏出事的那个小节；
//       ③ 回包 `119`/`106` → **不隐藏**，只给会话提示；
//       ④ 其它错误 / 未检测 → fail-open（保留 + 失败重试）。
//
// `service_registry.dart` 本批次**禁改**，所以三个 API 名常量定义在这里
// （值逐字来自 registry 的 required/optional 列表：`SYNO.Foto.Browse.Item` /
//  `SYNO.Foto.Browse.Album` / `SYNO.Foto.Download`）。既有能力位**一个都没删**。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../data/dto/foto_wave3_dto.dart';
import '../../data/foto_api.dart';
import '../../dsm/webapi.dart';
import 'photo_providers.dart';

Duration? _noRetry(int retryCount, Object error) => null;

/// 照片 EXIF 的能力位（`Browse.Item/get_exif` 属于该 API）。
const String kFotoBrowseItemApi = 'SYNO.Foto.Browse.Item';

/// 相册列表显示偏好的能力位（`Browse.Album/get_album_list_display`）。
const String kFotoBrowseAlbumApi = 'SYNO.Foto.Browse.Album';

/// 相册缓存的能力位（`Download/get_cache_status|calculate_cache_size`）。
const String kFotoDownloadApi = 'SYNO.Foto.Download';

FotoApi _requireFoto(Ref ref) {
  final api = ref.watch(fotoSpaceApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api;
}

/// 只读小节的四态判定结果。
enum PhotoWave3Gate {
  /// 能力位缺失 / `105` / `160` → 整个小节不渲染。
  hidden,

  /// `119` / `106` → 会话提示（**不隐藏**）。
  sessionHint,

  /// 正常（含"未检测 / 其它错误"的 fail-open）。
  visible,
}

/// 按既有纪律判定一个只读小节该显示成什么。
///
/// [hasApi] 由 `serviceAvailabilityProvider` 的 `hasApi(StationService.photo, …)`
/// 得到（缺失 → 隐藏；未检测 / absent / uncertain / unauthorized / 会话失效 → true
/// 的 fail-open 语义**原样复用**，不在这里重判）。
PhotoWave3Gate photoWave3Gate(
  AsyncValue<Object?> value, {
  required bool hasApi,
}) {
  if (!hasApi) return PhotoWave3Gate.hidden;
  if (value.hasError) {
    final err = value.error;
    if (err is DsmApiException) {
      if (err.code == DsmErrorCode.noPermission ||
          err.code == DsmErrorCode.noAppPrivilege) {
        return PhotoWave3Gate.hidden;
      }
      if (err.code == DsmErrorCode.sessionTimeout ||
          err.code == DsmErrorCode.sidNotFound) {
        return PhotoWave3Gate.sessionHint;
      }
    }
  }
  return PhotoWave3Gate.visible;
}

/// 相册设置入口是否可见：缓存 / 列表显示偏好**任一**能力位在就显示。
///
/// 缺失（`available`/`partial` 且集合里没有）→ 整个入口隐藏（连探测都不发）。
final photoWave3AlbumSettingsVisibleProvider = Provider<bool>((ref) {
  final snapshot = ref.watch(serviceAvailabilityProvider);
  return snapshot.hasApi(StationService.photo, kFotoDownloadApi) ||
      snapshot.hasApi(StationService.photo, kFotoBrowseAlbumApi);
});

/// 照片 EXIF（`Browse.Item/get_exif` **v1** + `id`）。
///
/// 空 / 非数字 id **不发请求**（返回空 DTO → 界面给明确空态）。
final photoExifProvider = FutureProvider.autoDispose
    .family<FotoExifDto, String>((ref, itemId) async {
      if (int.tryParse(itemId) == null) return const FotoExifDto();
      return _requireFoto(ref).getExif(itemId);
    }, retry: _noRetry);

/// 相册缓存状态（`Download/get_cache_status` **v2**）。
final photoAlbumCacheStatusProvider =
    FutureProvider.autoDispose<FotoCacheStatusDto>((ref) async {
      return _requireFoto(ref).getCacheStatus();
    }, retry: _noRetry);

/// 相册缓存大小（`Download/calculate_cache_size` **v2**）。
final photoAlbumCacheSizeProvider =
    FutureProvider.autoDispose<FotoCacheSizeDto>((ref) async {
      return _requireFoto(ref).calculateCacheSize();
    }, retry: _noRetry);

/// 相册列表显示偏好（`Browse.Album/get_album_list_display` **v3**，只读）。
final photoAlbumListDisplayProvider =
    FutureProvider.autoDispose<FotoAlbumListDisplayDto>((ref) async {
      return _requireFoto(ref).getAlbumListDisplay();
    }, retry: _noRetry);
