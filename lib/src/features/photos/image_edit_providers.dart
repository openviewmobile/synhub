// 相册 AI 美化（图生图）的 provider 层：开关 / 一次性同意 / 单日上限 /
// 仅 WiFi / 后端配置 / **全局并发闸门（上限 1）**。
//
// 纪律：
//   * key **只在** `CloudKeyStore`（槽位 [SettingsService.kImageEditKeySlot]），
//     偏好表里没有它；这里读 key 也只走安全存储。
//   * 默认态保守：开关 false、仅 WiFi true、上限 3。
//   * provider 只做"配置与闸门"，**不碰网络**；真正发请求在批次②的 UI/控制器里。
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../core/settings/app_settings.dart'
    show SettingsService, settingsServiceProvider;
import '../../core/settings/cloud_key_store.dart' show cloudKeyStoreProvider;
import '../../data/ai/image_edit_client.dart';
import '../../data/ai/image_edit_pricing.dart'
    show ImageEditGate, kImageEditDefaultDailyCap;
import '../../data/dto/foto_dto.dart';
import 'photo_providers.dart' show fotoSpaceApiProvider;

/// **全局互斥**：同一时刻只允许一次图生图（并发上限 1，方案 §7.3）。
/// 放 `Provider` 而不是 `Notifier`：它只是把一把锁，不需要被 UI 重建。
final imageEditGateProvider = Provider<ImageEditGate>((ref) => ImageEditGate());

/// 图生图 HTTP 客户端（批次②接线用；测试覆盖成 Fake，**不碰网络**）。
final imageEditClientProvider = Provider<ImageEditClient>(
  (ref) => ImageEditClient(),
);

/// 并发闸门的**可观察镜像**（方案 §7.3：并发中 → 入口禁用）。
///
/// 只镜像 UI 需要的那一位：请求在跑时为 true，入口按钮 `onPressed=null`
/// 并给"正在美化中，请稍候"。真正的互斥仍由 [imageEditGateProvider] 保证。
final imageEditBusyProvider = NotifierProvider<ImageEditBusyNotifier, bool>(
  ImageEditBusyNotifier.new,
);

class ImageEditBusyNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool v) {
    if (ref.mounted) state = v;
  }
}

/// 取"要发给服务端的原图字节"。
///
/// 默认走既有下载链路（`Download/download` 原文件，与"存到本机"同一条）；
/// 测试用 [photoAiEditBytesLoaderProvider] 覆盖成固定夹具，**不发任何请求**。
typedef PhotoAiEditBytesLoader = Future<Uint8List> Function(FotoItemDto item);

final photoAiEditBytesLoaderProvider = Provider<PhotoAiEditBytesLoader>((ref) {
  return (item) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) {
      throw ImageEditException(ImageEditErrorKind.backendNotConfigured);
    }
    final bytes = await api.api.getBytes(api.downloadUrl(itemId: item.id));
    return Uint8List.fromList(bytes);
  };
});

/// AI 美化的**设置快照**：入口可见性 / 设置卡 / 发起前门控都读它。
///
/// 为什么不用批次①的 `imageEditEnabledProvider`：那个 `Notifier` 需要冷启动
/// `preloadImageEditSettings`（在 `app.dart` 里接线，本批不许改 app.dart）。
/// 这里改成 `FutureProvider` 直接读偏好表 —— 无需冷启动预读，测试也更好构造。
class PhotoAiEditSettings {
  const PhotoAiEditSettings({
    required this.enabled,
    required this.consent,
    required this.dailyCap,
    required this.wifiOnly,
    required this.backendId,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  final bool enabled;
  final bool consent;
  final int dailyCap;
  final bool wifiOnly;
  final String backendId;
  final String baseUrl;
  final String model;
  final String apiKey;

  ImageEditBackend get backend => ImageEditBackend.fromId(backendId);

  bool get backendConfigured =>
      backendId.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  /// 云端后端要 key；自建（A1111）允许没有 key（Q10 待取证，沿用批次①口径）
  bool get keyPresent => apiKey.trim().isNotEmpty || backend.isSelfHosted;

  /// 完整配置（`null` = 还没配好 → 入口隐藏）
  ImageEditConfig? get config => backendConfigured
      ? ImageEditConfig(
          backend: backend,
          baseUrl: baseUrl,
          apiKey: apiKey,
          model: model,
        )
      : null;

  PhotoAiEditSettings copyWith({
    bool? enabled,
    bool? consent,
    int? dailyCap,
    bool? wifiOnly,
    String? backendId,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) => PhotoAiEditSettings(
    enabled: enabled ?? this.enabled,
    consent: consent ?? this.consent,
    dailyCap: dailyCap ?? this.dailyCap,
    wifiOnly: wifiOnly ?? this.wifiOnly,
    backendId: backendId ?? this.backendId,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
  );
}

/// key 从安全存储读（偏好表里没有它）；其它从偏好表读。
final photoAiEditSettingsProvider = FutureProvider<PhotoAiEditSettings>((
  ref,
) async {
  final s = ref.watch(settingsServiceProvider);
  final consent = await s.imageEditConsentV1();
  final apiKey =
      await ref
          .watch(cloudKeyStoreProvider)
          .read(SettingsService.kImageEditKeySlot) ??
      '';
  return PhotoAiEditSettings(
    enabled: await s.imageEditEnabled(),
    consent: consent != null && consent.trim().isNotEmpty,
    dailyCap: await s.imageEditDailyCap(),
    wifiOnly: await s.imageEditWifiOnly(),
    backendId: (await s.imageEditBackend()).trim(),
    baseUrl: (await s.imageEditBaseUrl() ?? '').trim(),
    model: (await s.imageEditModel() ?? '').trim(),
    apiKey: apiKey,
  );
}, retry: noRetry);

/// 入口是否可见：**总开关打开 + 后端已配置**（方案 §2.2 / §8）。
///
/// 未配后端 → 隐藏入口（不是禁用）；缺 key / 未同意 / 网络类问题都**不隐藏**
/// 入口，而是在发起前拦下并给明确文案（"不许静默回到初始态"）。
/// `AsyncValue.value == null`（还没读到）时按"不可见"处理，避免闪一下入口。
final photoAiEditEntryVisibleProvider = Provider<bool>((ref) {
  final s = ref.watch(photoAiEditSettingsProvider).value;
  return s != null && s.enabled && s.backendConfigured;
});

/// 图生图总开关（**默认 false**，比 `ai_enabled` 更保守）
final imageEditEnabledProvider =
    NotifierProvider<ImageEditEnabledNotifier, bool>(
      ImageEditEnabledNotifier.new,
    );

class ImageEditEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  Future<void> preload() async {
    final v = await ref.read(settingsServiceProvider).imageEditEnabled();
    if (!ref.mounted) return;
    state = v;
  }

  Future<void> set(bool v) async {
    state = v;
    await ref.read(settingsServiceProvider).setImageEditEnabled(v);
  }
}

/// 一次性同意（`image_edit_consent_v1`；**默认未同意**）
final imageEditConsentProvider =
    NotifierProvider<ImageEditConsentNotifier, bool>(
      ImageEditConsentNotifier.new,
    );

class ImageEditConsentNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  Future<void> preload() async {
    final v = await ref.read(settingsServiceProvider).imageEditConsentV1();
    if (!ref.mounted) return;
    state = v != null && v.trim().isNotEmpty;
  }

  /// 只有显式点"我理解并同意"才写入
  Future<void> grant() async {
    state = true;
    await ref.read(settingsServiceProvider).setImageEditConsentV1('granted');
  }

  /// 撤销：清同意 + 关总开关（方案 §6.3）
  Future<void> revoke() async {
    state = false;
    final s = ref.read(settingsServiceProvider);
    await s.clearImageEditConsent();
    await s.setImageEditEnabled(false);
    if (!ref.mounted) return;
    await ref.read(imageEditEnabledProvider.notifier).set(false);
  }
}

/// 单日额度（张/日；默认 3；0 = 关闭功能）
final imageEditDailyCapProvider =
    NotifierProvider<ImageEditDailyCapNotifier, int>(
      ImageEditDailyCapNotifier.new,
    );

class ImageEditDailyCapNotifier extends Notifier<int> {
  @override
  int build() => kImageEditDefaultDailyCap;

  Future<void> preload() async {
    final v = await ref.read(settingsServiceProvider).imageEditDailyCap();
    if (!ref.mounted) return;
    state = v;
  }

  Future<void> set(int v) async {
    final c = v < 0 ? 0 : v;
    state = c;
    await ref.read(settingsServiceProvider).setImageEditDailyCap(c);
  }
}

/// 仅 WiFi（**默认 true**）
final imageEditWifiOnlyProvider =
    NotifierProvider<ImageEditWifiOnlyNotifier, bool>(
      ImageEditWifiOnlyNotifier.new,
    );

class ImageEditWifiOnlyNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  Future<void> preload() async {
    final v = await ref.read(settingsServiceProvider).imageEditWifiOnly();
    if (!ref.mounted) return;
    state = v;
  }

  Future<void> set(bool v) async {
    state = v;
    await ref.read(settingsServiceProvider).setImageEditWifiOnly(v);
  }
}

/// 冷启动预读（与 `preloadAiSettings` 同法）
Future<void> preloadImageEditSettings(dynamic ref) async {
  await ref.read(imageEditEnabledProvider.notifier).preload();
  await ref.read(imageEditConsentProvider.notifier).preload();
  await ref.read(imageEditDailyCapProvider.notifier).preload();
  await ref.read(imageEditWifiOnlyProvider.notifier).preload();
}

/// 后端配置（**null = 还没配好**）。
///
/// key 从安全存储读；读不到也返回 config（云端由 preflight 的 `keyPresent`
/// 拦，本地 A1111 允许无 key）。
final imageEditConfigProvider = FutureProvider<ImageEditConfig?>((ref) async {
  final s = ref.watch(settingsServiceProvider);
  final backendId = (await s.imageEditBackend()).trim();
  final baseUrl = (await s.imageEditBaseUrl() ?? '').trim();
  if (backendId.isEmpty || baseUrl.isEmpty) return null;
  final backend = ImageEditBackend.fromId(backendId);
  final model = (await s.imageEditModel() ?? '').trim();
  final apiKey =
      await ref
          .watch(cloudKeyStoreProvider)
          .read(SettingsService.kImageEditKeySlot) ??
      '';
  return ImageEditConfig(
    backend: backend,
    baseUrl: baseUrl,
    apiKey: apiKey,
    model: model,
  );
}, retry: noRetry);
