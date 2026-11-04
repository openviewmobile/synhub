// P65：把照片/视频投送到 Chromecast（官方 `chromecast/*` 整套 + Google Cast SDK）。
//
// ## 官方事实（APK 2.4.0-644，smali 逐字取证）
//
// * 命名空间：`urn:x-cast:com.synology.photos`
//   （`chromecast/ChromecastHelper.smali` 的 `const-string`）；
// * 消息通道：`chromecast/CastMessageChannel`（自建 `Cast.MessageReceivedCallback`，
//   不是标准 media namespace）—— 说明接收端是**群晖自己的 Cast Receiver**，
//   投送内容靠自定义消息而非 `MediaInfo`；
// * 信封（`chromecast/item/SenderItem`）：字段 **`command` / `data` / `version`**；
// * 命令（`SenderItem$Companion` + `CastMessageChannel` 常量）：
//   `identify`、`goto_index`、`photo_list`、`disconnect`，
//   接收端错误另有 `challenge` / `error`（`error` 带 `code`、`detail`）；
// * `goto_index` 的载荷（`chromecast/item/GotoIndexItem`）：字段 **`index`**；
// * 相关类：`ChromecastHelper`、`CastOptionsProvider`、`CastSessionManagerListener`、
//   `chromecast/ui/VideoControlsActivity`（视频投送的遥控界面）、`item/*`。
//
// ## 本文件做到哪一步（**不吹**）
//
// 已做：**协议层 + 会话状态机 + Mock 可验证的桥**。
// 未做（登记待取证/待原生）：
//   ① `IdentifyItem` / `PhotoItem` 的**字段名**与 `version` 的**取值**没取证到
//      ⇒ 本文件只把 `data` 当**不透明 map** 透传，不臆造字段；
//   ② Android 侧 GMS Cast SDK 桥（与 ⑤音频 C3 共用 `synhub/cast` 通道，
//      本文件走 `photoCastSend` 方法）；
//   ③ 投送 UI（遥控界面）。
//
// ★ 原则与 ⑤音频 C3 一致：**能力拿不到就如实说"本机不支持"，零调用**，
//   绝不假装投送成功。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';

/// 官方 Cast 命名空间（逐字取自 `ChromecastHelper.smali`）。
const String kPhotoCastNamespace = 'urn:x-cast:com.synology.photos';

/// 官方命令常量（`SenderItem$Companion` / `CastMessageChannel`）。
abstract final class PhotoCastCommand {
  /// 握手：投送端自我介绍。
  static const identify = 'identify';

  /// 跳到第 N 张（载荷 `{'index': int}`）。
  static const gotoIndex = 'goto_index';

  /// 把当前相册的列表交给接收端。
  static const photoList = 'photo_list';

  /// 结束投送。
  static const disconnect = 'disconnect';

  /// 接收端挑战（入会校验）。
  static const challenge = 'challenge';

  /// 接收端错误（载荷带 `code` / `detail`）。
  static const error = 'error';
}

/// 构造官方信封 `{command, data, version}`。
///
/// `version` 是官方信封里的真实字段（`SenderItem`），但**具体取值没取证到**，
/// 所以这里由调用方显式给出、默认 `1`，并把"未取证"写在文档里 ——
/// 不假装知道官方发的是几。
Map<String, dynamic> photoCastEnvelope(
  String command,
  Map<String, dynamic> data, {
  int version = 1,
}) => {'command': command, 'data': data, 'version': version};

/// `goto_index` 的载荷（官方 `GotoIndexItem` 字段就叫 `index`）。
Map<String, dynamic> photoCastGotoIndex(int index) => {'index': index};

/// 接收端错误的可读描述：官方 `error` 消息带 `code` 与 `detail`。
///
/// 两者都可能缺 ⇒ 缺了就如实回落，**不编造**错误码。
String? photoCastErrorDetail(Map<String, dynamic> message) {
  final code = message['code'];
  final detail = message['detail'];
  if (code == null && detail == null) return null;
  if (detail == null) return 'code=$code';
  if (code == null) return '$detail';
  return 'code=$code, detail=$detail';
}

/// 投送桥（另一侧是 Android 的 GMS Cast SDK）。
///
/// 与 ⑤音频 C3 的 `synhub/cast` 通道**共用一条**，方法名区分：
/// `photoCastAvailability` / `photoCastConnect` / `photoCastSend` /
/// `photoCastDisconnect`。
abstract class PhotoCastBridge {
  Future<Map<String, dynamic>> availability();
  Future<void> connect(String deviceId);
  Future<void> send(Map<String, dynamic> message);
  Future<void> disconnect();
}

/// 真实实现：`MethodChannel('synhub/cast')`。
///
/// 通道另一侧没有实现时抛 `MissingPluginException` —— 由
/// [PhotoCastSession.start] 收敛成"本机不支持"，**不假装成功**。
class MethodChannelPhotoCastBridge implements PhotoCastBridge {
  MethodChannelPhotoCastBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('synhub/cast');

  final MethodChannel _channel;

  /// 第 55 轮：`synhub/cast` 只有 Kotlin 一份 ⇒ 宿主上不碰通道。
  static bool get _allowed => capabilityGateAllows(AppCapability.cast);

  static void _logBlocked(String what) =>
      debugPrint(capabilityGateLog(AppCapability.cast, 'photo_cast.$what'));

  @override
  Future<Map<String, dynamic>> availability() async {
    if (!_allowed) {
      _logBlocked('availability');
      return {
        'available': false,
        'devices': <Object?>[],
        'reason': capabilityGateReason(AppCapability.cast),
      };
    }
    final raw = await _channel.invokeMethod<Object?>('photoCastAvailability');
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {'available': false, 'devices': <Object?>[]};
  }

  @override
  Future<void> connect(String deviceId) async {
    if (!_allowed) {
      _logBlocked('connect');
      return;
    }
    await _channel.invokeMethod<void>('photoCastConnect', {'deviceId': deviceId});
  }

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (!_allowed) {
      _logBlocked('send');
      return;
    }
    await _channel.invokeMethod<void>('photoCastSend', {
      'namespace': kPhotoCastNamespace,
      'message': message,
    });
  }

  @override
  Future<void> disconnect() async {
    if (!_allowed) {
      _logBlocked('disconnect');
      return;
    }
    await _channel.invokeMethod<void>('photoCastDisconnect');
  }
}

/// 投送桥（默认走 MethodChannel；真机/Web 之外的平台没有实现 ⇒
/// `MissingPluginException` ⇒ 收敛成"本机不支持"）。
///
/// 用例里用 `overrideWithValue` 换成假桥，**不碰设备**。
final photoCastBridgeProvider = Provider<PhotoCastBridge>(
  (ref) => MethodChannelPhotoCastBridge(),
);

/// 投送会话状态。
enum PhotoCastState {
  /// 本机没有 Cast 能力（或桥不可用）。
  unsupported,

  /// 空闲（有能力、未连接）。
  idle,

  /// 已连接接收端，正在投送。
  projecting,
}

/// 投送会话（**纯 Dart，可 Mock**）。
///
/// 时序与官方一致：`availability` → `connect` → `identify`；
/// 之后每次翻页发 `goto_index`；结束发 `disconnect`。
/// 接收端报 `error` ⇒ 记录 [lastError] 并停止投送（**不吞错**）。
class PhotoCastSession {
  PhotoCastSession(this._bridge);

  final PhotoCastBridge _bridge;

  PhotoCastState _state = PhotoCastState.unsupported;
  PhotoCastState get state => _state;

  String? _deviceId;
  String? get deviceId => _deviceId;

  String? _lastError;
  String? get lastError => _lastError;

  /// 已发出的消息（只读，便于用例断言；真机上不落盘）。
  final List<Map<String, dynamic>> sent = [];

  /// 探测能力。桥抛异常 ⇒ [PhotoCastState.unsupported]（零后续调用）。
  Future<bool> probe() async {
    try {
      final info = await _bridge.availability();
      final ok = info['available'] == true;
      _state = ok ? PhotoCastState.idle : PhotoCastState.unsupported;
      return ok;
    } on Object {
      _state = PhotoCastState.unsupported;
      return false;
    }
  }

  /// 连接并握手。**能力不可用 / 没有 deviceId ⇒ 一个字节都不发。**
  Future<bool> start(String deviceId) async {
    if (_state == PhotoCastState.unsupported || deviceId.isEmpty) return false;
    try {
      await _bridge.connect(deviceId);
      _deviceId = deviceId;
      await _send(PhotoCastCommand.identify, const {});
      _state = PhotoCastState.projecting;
      return true;
    } on Object catch (err) {
      _lastError = '$err';
      return false;
    }
  }

  /// 跳到第 N 张。**未投送 ⇒ 不发。**
  Future<void> project(int index) async {
    if (_state != PhotoCastState.projecting) return;
    await _send(PhotoCastCommand.gotoIndex, photoCastGotoIndex(index));
  }

  /// 接收端来消息。目前只处理 `error`（记录 code/detail）。
  void onReceiverMessage(Map<String, dynamic> message) {
    if (message['command'] == PhotoCastCommand.error) {
      _lastError = photoCastErrorDetail(message) ?? 'unknown';
      _state = PhotoCastState.idle;
    }
  }

  /// 结束投送。未投送 ⇒ 不发 `disconnect`（避免无意义请求）。
  Future<void> stop() async {
    if (_state != PhotoCastState.projecting) return;
    await _send(PhotoCastCommand.disconnect, const {});
    _state = PhotoCastState.idle;
    _deviceId = null;
    try {
      await _bridge.disconnect();
    } on Object {
      // 断开失败不影响本地状态：连接已经不在我们手里了
    }
  }

  Future<void> _send(String command, Map<String, dynamic> data) async {
    final envelope = photoCastEnvelope(command, data);
    sent.add(envelope);
    await _bridge.send(envelope);
  }
}
