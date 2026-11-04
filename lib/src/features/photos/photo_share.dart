// P52：把**已经下载到本地**的照片/视频交给系统分享面板（官方「发送到」）。
//
// ## 为什么能直接复用既有原生桥
//
// 仓库的 Android 原生桥 `MediaOpenBridge.kt`（channel `synhub/media_open`）
// 已经有 `share {path,name,mime}` 与 `canShare {path,mime}` 两个方法
// （Drive G4 / D34「发送副本」走的就是它）。
// ⇒ P52 **不新开 channel、不动 `android/**`、不加依赖**，与 Drive 保持单一事实来源。
//
// ## 测试纪律（与仓库其它桥一致）
//
// 桌面/`flutter test` 没有插件通道 ⇒ `share`/`canShare` 表现为"桥不可用"，
// 调用方按**明确失败**提示，绝不静默装成成功。
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synhub/src/core/platform/app_platform.dart';

/// 分享桥（与 Drive G4 同一个原生通道）。
abstract class PhotoShareBridge {
  /// 只问"有没有应用能接这个分享"（无副作用）。
  Future<bool> canShare({required String path, required String mime});

  /// 拉起系统分享面板；`true` = 选择器已打开。
  Future<bool> share({
    required String path,
    required String name,
    required String mime,
  });
}

/// 真实实现：`MethodChannel('synhub/media_open')`。
class MediaOpenPhotoShareBridge implements PhotoShareBridge {
  MediaOpenPhotoShareBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('synhub/media_open');

  final MethodChannel _channel;

  /// 桥不可用 / 原生回非 true ⇒ **false**（调用方据此给明确失败提示）。
  Future<bool> _boolCall(String method, Map<String, dynamic> args) async {
    // 第 79 轮：`synhub/media_open` 只有 Kotlin 一份 ⇒ 碰通道前过能力门。
    if (!capabilityGateAllows(AppCapability.systemShare)) return false;
    try {
      final raw = await _channel.invokeMethod<Object?>(method, args);
      return raw == true;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> canShare({required String path, required String mime}) =>
      _boolCall('canShare', {'path': path, 'mime': mime});

  @override
  Future<bool> share({
    required String path,
    required String name,
    required String mime,
  }) => _boolCall('share', {'path': path, 'name': name, 'mime': mime});
}

final photoShareBridgeProvider = Provider<PhotoShareBridge>(
  (ref) => MediaOpenPhotoShareBridge(),
);

/// 一个待分享的本地文件。
class PhotoShareTarget {
  const PhotoShareTarget({
    required this.path,
    required this.name,
    required this.mime,
  });

  final String path;
  final String name;
  final String mime;
}

/// 分享结果：成功/失败**分开计数**（与批量操作的汇报口径一致）。
class PhotoShareOutcome {
  const PhotoShareOutcome({required this.shared, required this.unsupported});

  final int shared;
  final int unsupported;

  bool get isEmpty => shared == 0 && unsupported == 0;
}

/// 逐个分享 [targets]。
///
/// * 空列表 ⇒ **一个调用都不发**；
/// * 每一项先 `canShare`（官方语义：只问、无副作用），**不能接就跳过并计数**；
/// * `canShare` 为真才 `share`；`share` 回 false（用户没有可选项/拉起失败）
///   也算 `unsupported`，**不谎报成功**。
Future<PhotoShareOutcome> sharePhotoTargets({
  required PhotoShareBridge bridge,
  required List<PhotoShareTarget> targets,
}) async {
  var shared = 0;
  var unsupported = 0;
  for (final t in targets) {
    if (t.path.isEmpty) {
      unsupported++;
      continue;
    }
    final ok = await bridge.canShare(path: t.path, mime: t.mime);
    if (!ok) {
      unsupported++;
      continue;
    }
    final done = await bridge.share(path: t.path, name: t.name, mime: t.mime);
    if (done) {
      shared++;
    } else {
      unsupported++;
    }
  }
  return PhotoShareOutcome(shared: shared, unsupported: unsupported);
}
