// 相册**播放设置**：HTTP / HTTP 端口 / 忽略证书错误（P48）。
//
// 官方证据（`photo-parity-audit.md:170` / `parity-recount-drive-photos.md:293`）：
//   * `str_stream_http`、`str_stream_http_port`、`str_player_setting_desc`、
//     `str_video_play_cert_invalid_desc`、`error_http_port_incorrect`；
//   * 服务端 API **不适用** —— 纯客户端播放设置，落到
//     `SYNO.Foto.Download` / `SYNO.Foto.Streaming` 的**直链**上。
//
// 自签证书场景（本机 NAS 就是自签）：原生播放器 / Media3 直接吃 https 直链时
// 会因证书校验失败拿不到流。官方给的出路就是这两条：
//   1. `useHttp`（+ 端口）→ **换 HTTP 直链**，绕开 TLS；
//   2. `ignoreCert` → 忽略证书错误。
//
// 本仓库的 `DioFactory` 本来就无条件放行自签证书，所以 `ignoreCert` 对**应用内
// HTTP 客户端**没有额外作用；它的实际价值在 [PhotoPlaybackSettings.preferBufferedPlayback]
// —— 置位后相册视频**优先走应用内客户端取字节**（`getBytes`，证书链在应用内、
// 已知可用），而不是把 https 直链交给原生播放器。这条是如实的取舍，见报告。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/foto_api.dart';
import 'photo_prefs_store.dart';

/// 合法端口范围（`error_http_port_incorrect` 的判据）。
const int kPhotoHttpPortMin = 1;
const int kPhotoHttpPortMax = 65535;

/// 官方 HTTP 播放的默认端口（DSM 默认 HTTP 端口）。
const int kPhotoHttpPortDefault = 5000;

/// 相册播放设置（不可变）。
class PhotoPlaybackSettings {
  const PhotoPlaybackSettings({
    this.useHttp = false,
    this.httpPort,
    this.ignoreCert = false,
  });

  /// 用 HTTP 而不是 HTTPS 取流。
  final bool useHttp;

  /// HTTP 端口；null = 用会话原本的端口。
  final int? httpPort;

  /// 自签证书时忽略证书错误（见文件头说明）。
  final bool ignoreCert;

  /// 端口非法时的错误 key（合法 → null）。
  String? get portError => FotoMediaUrlOverride.validatePort(httpPort);

  /// 交给 `foto_api.dart` 的 URL 改写器。
  FotoMediaUrlOverride get mediaOverride => FotoMediaUrlOverride(
    useHttp: useHttp,
    httpPort: httpPort,
    ignoreCert: ignoreCert,
  );

  /// `ignoreCert` 置位 → 相册视频优先走应用内客户端取字节（证书由应用负责）。
  bool get preferBufferedPlayback => ignoreCert;

  PhotoPlaybackSettings copyWith({
    bool? useHttp,
    Object? httpPort = _sentinel,
    bool? ignoreCert,
  }) => PhotoPlaybackSettings(
    useHttp: useHttp ?? this.useHttp,
    httpPort: identical(httpPort, _sentinel) ? this.httpPort : httpPort as int?,
    ignoreCert: ignoreCert ?? this.ignoreCert,
  );

  /// 把界面上输入的端口文本解析成 `int?`：空 → null（= 不覆盖）；
  /// 非法 → 原样保留 null 并由 [portError]... 这里返回 `-1` 表示"非法"。
  static int? parsePortInput(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    if (n == null) return -1;
    return n;
  }

  Map<String, dynamic> toJson() => {
    'use_http': useHttp,
    if (httpPort != null) 'http_port': httpPort,
    'ignore_cert': ignoreCert,
  };

  String encode() => jsonEncode(toJson());

  static PhotoPlaybackSettings parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const PhotoPlaybackSettings();
    }
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return const PhotoPlaybackSettings();
      final port = m['http_port'];
      return PhotoPlaybackSettings(
        useHttp: m['use_http'] == true,
        httpPort: port is num ? port.toInt() : int.tryParse('${port ?? ''}'),
        ignoreCert: m['ignore_cert'] == true,
      );
    } catch (_) {
      return const PhotoPlaybackSettings();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PhotoPlaybackSettings &&
      other.useHttp == useHttp &&
      other.httpPort == httpPort &&
      other.ignoreCert == ignoreCert;

  @override
  int get hashCode => Object.hash(useHttp, httpPort, ignoreCert);
}

const Object _sentinel = Object();

/// 相册播放设置（落盘：`photo_playback_settings_v1`）。
final photoPlaybackSettingsProvider =
    NotifierProvider<PhotoPlaybackSettingsNotifier, PhotoPlaybackSettings>(
      PhotoPlaybackSettingsNotifier.new,
    );

class PhotoPlaybackSettingsNotifier extends Notifier<PhotoPlaybackSettings> {
  /// 用户是否已经改过（改过之后异步恢复不许把新设置冲掉）。
  bool _touched = false;

  @override
  PhotoPlaybackSettings build() {
    unawaited(_restore());
    return const PhotoPlaybackSettings();
  }

  Future<void> _restore() async {
    final raw = await ref
        .read(photoPrefsStoreProvider)
        .read(kPhotoPlaybackSettingsSlot);
    if (!ref.mounted || _touched) return;
    final restored = PhotoPlaybackSettings.parse(raw);
    if (restored != state) state = restored;
  }

  Future<void> _update(PhotoPlaybackSettings next) async {
    _touched = true;
    state = next;
    await ref
        .read(photoPrefsStoreProvider)
        .write(kPhotoPlaybackSettingsSlot, next.encode());
  }

  Future<void> setUseHttp(bool on) => _update(state.copyWith(useHttp: on));

  Future<void> setIgnoreCert(bool on) =>
      _update(state.copyWith(ignoreCert: on));

  /// 设 HTTP 端口。非法（非数字 / 越界）**不落盘、不改状态**，返回 false，
  /// 由界面给出 `error_http_port_incorrect` 等价提示。
  Future<bool> setHttpPort(String raw) async {
    final parsed = PhotoPlaybackSettings.parsePortInput(raw);
    if (parsed == null) {
      await _update(state.copyWith(httpPort: null));
      return true;
    }
    if (parsed < kPhotoHttpPortMin || parsed > kPhotoHttpPortMax) return false;
    await _update(state.copyWith(httpPort: parsed));
    return true;
  }
}
