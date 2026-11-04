// 「分享到 Chat」（`ACTION_SEND` / `ACTION_SEND_MULTIPLE`）的 Dart 入口。
//
// 原版是 exported `ShareActivity` + `ShareEditFragment`（`AndroidManifest.xml:224-241`）：
// 读 `EXTRA_TEXT` / `EXTRA_SUBJECT` / `EXTRA_STREAM`，最多 50 个附件，选频道后发。
// 这边把「读原生 intent」抽成 [ShareIntentSource]，好让单测离线注入假源；
// 真实现走 MethodChannel `synhub/share_intent`（见 Kotlin 的
// `ShareIntentBridge.kt`）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';

/// 分享进来的一个附件（原生已经把 `content://` 复制到 cache，给的是真实路径）。
class ShareIntentFile {
  const ShareIntentFile({
    required this.path,
    required this.name,
    required this.mime,
    this.size = 0,
  });

  final String path;
  final String name;
  final String mime;
  final int size;

  static ShareIntentFile? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final path = '${raw['path'] ?? ''}';
    if (path.isEmpty) return null;
    final name = '${raw['name'] ?? ''}';
    return ShareIntentFile(
      path: path,
      name: name.isEmpty ? path.split('/').last : name,
      mime: '${raw['mime'] ?? ''}',
      size: raw['size'] is num ? (raw['size'] as num).toInt() : 0,
    );
  }
}

/// 一次分享的完整载荷。
class ShareIntentData {
  const ShareIntentData({
    required this.action,
    required this.mimeType,
    required this.text,
    required this.subject,
    required this.files,
    this.overflow = 0,
  });

  final String action;
  final String mimeType;
  final String text;
  final String subject;
  final List<ShareIntentFile> files;

  /// 超过 50 个被原生砍掉的个数（原版 `error_share_exceed_max_files`）
  final int overflow;

  bool get hasFiles => files.isNotEmpty;
  bool get hasText => text.trim().isNotEmpty;

  /// 解析原生载荷；没什么可发的返回 null（原生也会过滤一遍）。
  static ShareIntentData? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final files = <ShareIntentFile>[];
    final list = raw['files'];
    if (list is List) {
      for (final one in list) {
        final f = ShareIntentFile.fromMap(one);
        if (f != null) files.add(f);
      }
    }
    final text = '${raw['text'] ?? ''}';
    if (files.isEmpty && text.trim().isEmpty) return null;
    return ShareIntentData(
      action: '${raw['action'] ?? ''}',
      mimeType: '${raw['mime_type'] ?? ''}',
      text: text,
      subject: '${raw['subject'] ?? ''}',
      files: files,
      overflow: raw['overflow'] is num
          ? (raw['overflow'] as num).toInt()
          : 0,
    );
  }
}

/// 「分享到 Chat」的来源（测试里换成假实现）。
abstract class ShareIntentSource {
  /// 取走并清空当前待处理的分享（没有则 null）。
  Future<ShareIntentData?> takePending();

  /// App 已经在前台时，新的分享会从这里推过来。
  Stream<ShareIntentData> get incoming;

  void dispose();
}

class MethodChannelShareIntentSource implements ShareIntentSource {
  MethodChannelShareIntentSource([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('synhub/share_intent') {
    // 第 55 轮：只在"能力层放行"时注册监听（Android 才有的桥）。
    if (!capabilityGateAllows(AppCapability.systemShare)) return;
    // 原生侧只发一个"有新分享"的空提醒；真正取载荷统一走 takePending，
    // 这样冷启动 / 前台只有一个消费路径，不会重复处理。
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onShare') return null;
      final data = await takePending();
      if (data != null && !_events.isClosed) _events.add(data);
      return null;
    });
  }

  final MethodChannel _channel;
  final _events = StreamController<ShareIntentData>.broadcast();

  @override
  Stream<ShareIntentData> get incoming => _events.stream;

  @override
  Future<ShareIntentData?> takePending() async {
    // 第 55 轮：`synhub/share_intent` 只有 Android 侧实现 ⇒ 先问能力层。
    if (!capabilityGateAllows(AppCapability.systemShare)) {
      debugPrint(
        capabilityGateLog(AppCapability.systemShare, 'share_intent.getPending'),
      );
      return null;
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('getPending');
      return ShareIntentData.fromMap(raw);
    } catch (e) {
      // 平台上没有这个 channel（纯桌面/单测）不是错误
      debugPrint('[share] getPending 失败：$e');
      return null;
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    if (!_events.isClosed) _events.close();
  }
}

final shareIntentSourceProvider = Provider<ShareIntentSource>((ref) {
  final source = MethodChannelShareIntentSource();
  ref.onDispose(source.dispose);
  return source;
});
