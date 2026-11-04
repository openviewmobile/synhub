// 服务端设置（`SYNO.Chat.Admin.Setting / get` + 实时 `setting.update` 广播）。
//
// 原版把这些塞进 `PreferencesHelper`（`setFileSizeLimit` / `allowEncryption` /
// `setDefaultNotificationType` / `allowReadStatus` / `setAllowEditMessage` …），
// 我们一样落在本地键值表里（序列化成一条 JSON），启动时先 preload 成同步可读，
// 登录成功后 `refreshFromServer()` 拉一次，之后靠 `setting.update` 增量覆盖。
//
// ⚠️ 默认值必须"最宽松"：设置还没拉回来之前，不要让用户突然不能编辑/发文件
// （原版也是先给一套默认值）。真机上 `allow_read_status` 这类字段受版本门控，
// 老服务器不带这些字段 → 保持默认。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/server_settings_dto.dart';
import 'app_settings.dart';

/// 本地键值表里的 key（原版是各自独立的偏好 key，我们存一整块 JSON）
const String kServerSettingsKey = 'server_settings_json';

final serverSettingsProvider =
    NotifierProvider<ServerSettingsNotifier, ServerSettings>(
      ServerSettingsNotifier.new,
    );

class ServerSettingsNotifier extends Notifier<ServerSettings> {
  @override
  ServerSettings build() => const ServerSettings();

  /// 启动时把上次缓存的服务端设置读进来（离线也能用对限制）
  Future<void> preload() async {
    final raw = await ref.read(settingsServiceProvider).serverSettingsJson();
    if (raw == null || raw.isEmpty) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (ref.mounted) state = ServerSettings.fromJson(json);
    } catch (e) {
      debugPrint('[settings] 服务端设置缓存解析失败：$e');
    }
  }

  /// 服务端推来 / 拉到一份新设置 → 落库 + 更新内存
  Future<void> apply(ServerSettings settings, {bool merge = false}) async {
    final next = merge ? state.merge(settings) : settings;
    state = next;
    await ref
        .read(settingsServiceProvider)
        .setServerSettingsJson(jsonEncode(next.toJson()));
  }
}

/// 服务端设置的**便利读法**（配合 [ServerSettings] 的语义做判断）
extension ServerSettingsQuery on ServerSettings {
  /// 编辑窗口是否还有效（`-1` / `0` = 不限时间）
  bool editWindowExpired(int createAtMs, {int? nowMs}) {
    final window = editWindowMs;
    if (window <= 0) return false; // 不限时间
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return now - createAtMs > window;
  }

  /// 附件是否超过服务端大小上限（0 = 不限制）
  bool fileTooLarge(int sizeBytes) =>
      fileSizeLimitBytes > 0 && sizeBytes > fileSizeLimitBytes;
}
