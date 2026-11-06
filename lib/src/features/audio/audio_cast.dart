// C3：Chromecast（官方 `chromecast/IChromeCastService` +
// `mediasession/service/ChromeCastService` + Google Cast SDK）。
//
// 官方事实（dex 取证，见 `docs/admin-parity-requirement.md` §90）：
//   * 依赖 **Google Cast SDK**（`com/google/android/gms/cast/*`，dex 里 293 处）；
//   * 自带进程内 AIDL `IChromeCastService`（`_Parcel`/`Stub`/`Proxy`）
//     + `chromecast/AudioMessageStream`（`OnReceiveMessage` 投音频流）；
//   * `AbstractChromeCastService` / `ChromeCastService` 派生自 `MediaBrowserService`。
//
// 本文件是**第③步（Dart 侧契约）**：抽象 + 可用性探测 + 投送。
// ★ 原则与 B10 一致：**能力拿不到就如实说"本机不支持"，并且零调用**；
//   绝不假装投送成功。Android 侧（Cast SDK + CastOptionsProvider +
//   原生桥）是另一侧，未完成前 `availability().available` 恒为 false。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';

/// 平台通道契约（另一侧是 Android 的 GMS Cast SDK 桥）。
///
/// * `availability` → `{'available': bool, 'devices': [{'id','name'}]}`；
/// * `connect` → `{'deviceId': String}`；
/// * `play` → `{'mediaUrl': String, 'positionSeconds': int?}`；
/// * `disconnect` → 无参。
abstract class AudioCastBridge {
  Future<Map<String, dynamic>> availability();
  Future<void> connect(String deviceId);
  Future<void> play(String mediaUrl, {int? positionSeconds});
  Future<void> disconnect();
}

/// 真实实现：MethodChannel `synhub/cast`。
///
/// ★ 通道另一侧未实现时 `MissingPluginException` 会被控制器收敛成
/// "本机不支持"，**不假装成功**。
class MethodChannelCastBridge implements AudioCastBridge {
  MethodChannelCastBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('synhub/cast');

  final MethodChannel _channel;

  /// 第 55 轮：`synhub/cast` 只有 Kotlin 一份（`CastBridge.kt`）⇒
  /// 宿主上能力层报 `unavailable:not-implemented-on-host`，**不碰通道**。
  static bool get _allowed => capabilityGateAllows(AppCapability.cast);

  static void _logBlocked(String what) =>
      debugPrint(capabilityGateLog(AppCapability.cast, 'cast.$what'));

  @override
  Future<Map<String, dynamic>> availability() async {
    if (!_allowed) {
      _logBlocked('availability');
      return {
        'available': false,
        'reason': capabilityGateReason(AppCapability.cast),
      };
    }
    final raw = await _channel.invokeMethod<Object?>('availability');
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {'available': false};
  }

  @override
  Future<void> connect(String deviceId) async {
    if (!_allowed) {
      _logBlocked('connect');
      return;
    }
    await _channel.invokeMethod<void>('connect', {'deviceId': deviceId});
  }

  @override
  Future<void> play(String mediaUrl, {int? positionSeconds}) async {
    if (!_allowed) {
      _logBlocked('play');
      return;
    }
    await _channel.invokeMethod<void>('play', {
      'mediaUrl': mediaUrl,
      'positionSeconds': ?positionSeconds,
    });
  }

  @override
  Future<void> disconnect() async {
    if (!_allowed) {
      _logBlocked('disconnect');
      return;
    }
    await _channel.invokeMethod<void>('disconnect');
  }
}

final audioCastBridgeProvider = Provider<AudioCastBridge>(
  (ref) => MethodChannelCastBridge(),
);

class AudioCastDevice {
  const AudioCastDevice({required this.id, required this.name});

  final String id;
  final String name;

  static AudioCastDevice? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final name = raw['name'];
    return AudioCastDevice(
      id: id,
      name: (name is String && name.isNotEmpty) ? name : id,
    );
  }
}

class AudioCastState {
  const AudioCastState({
    this.loaded = false,
    this.available = false,
    this.devices = const [],
    this.connectedId,
  });

  final bool loaded;
  final bool available;
  final List<AudioCastDevice> devices;
  final String? connectedId;

  AudioCastState copyWith({
    bool? loaded,
    bool? available,
    List<AudioCastDevice>? devices,
    String? connectedId,
    bool clearConnected = false,
  }) => AudioCastState(
    loaded: loaded ?? this.loaded,
    available: available ?? this.available,
    devices: devices ?? this.devices,
    connectedId: clearConnected ? null : (connectedId ?? this.connectedId),
  );
}

final audioCastProvider = NotifierProvider<AudioCastController, AudioCastState>(
  AudioCastController.new,
);

class AudioCastController extends Notifier<AudioCastState> {
  @override
  AudioCastState build() => const AudioCastState();

  Future<void> preload() async {
    var available = false;
    var devices = const <AudioCastDevice>[];
    try {
      final caps = await ref.read(audioCastBridgeProvider).availability();
      available = caps['available'] == true;
      final list = caps['devices'];
      if (list is List) {
        devices = [
          for (final e in list)
            ?AudioCastDevice.tryParse(e),
        ];
      }
    } on MissingPluginException {
      available = false;
    } catch (_) {
      available = false;
    }
    state = AudioCastState(
      loaded: true,
      available: available,
      devices: devices,
    );
  }

  /// 连接某台设备。**不可用时零调用**。
  Future<bool> connect(String deviceId) async {
    if (!state.available) return false;
    try {
      await ref.read(audioCastBridgeProvider).connect(deviceId);
      state = state.copyWith(connectedId: deviceId);
      return true;
    } on MissingPluginException {
      state = state.copyWith(available: false);
      return false;
    } catch (_) {
      return false; // 失败不改成"已连接"
    }
  }

  /// 把某个媒体 URL 投给已连接设备。**未连接/不可用时零调用**。
  Future<bool> play(String mediaUrl, {int? positionSeconds}) async {
    final id = state.connectedId;
    if (!state.available || id == null || mediaUrl.isEmpty) return false;
    try {
      await ref
          .read(audioCastBridgeProvider)
          .play(mediaUrl, positionSeconds: positionSeconds);
      return true;
    } on MissingPluginException {
      state = state.copyWith(available: false);
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> disconnect() async {
    if (!state.available || state.connectedId == null) return;
    try {
      await ref.read(audioCastBridgeProvider).disconnect();
    } catch (_) {
      // 断开失败也要清状态，避免界面骗人
    }
    state = state.copyWith(clearConnected: true);
  }
}
