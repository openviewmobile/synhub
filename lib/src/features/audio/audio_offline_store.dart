// Audio Station 离线下载缓存的**落盘层**（D2）。
//
// 与 `features/media/media_playback_store.dart` 同一套路：
//   * 纯 IO 逻辑收在一个类里，测试注入内存实现；
//   * 拿不到应用文档目录（无平台通道的纯单测 / 权限异常）→ **静默降级**，
//     绝不让"存不了缓存"把播放变成失败；
//   * 只存**服务端返回的原始打包字节**，文件名用曲目 id（不拼接用户输入，
//     避免路径穿越）。
//
// ⚠️ 本机（DSM 7.2.1 / AS 7.2.1-6006）`Info.getinfo.settings.enable_download=false`，
// 且 `Download.download` 真机只回 `{"success": true}`（17 字节，无打包载荷）
// —— 所以这里同时提供 [looksLikeServerStub]：把这种"成功但没内容"如实识别出来，
// 不写一个假的空 zip 到磁盘。
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// `Download.download` 的返回是不是"成功但没内容"的桩响应。
///
/// 真机原文（只读探测）：`GET AudioStation/download.cgi?...&method=download&id=…`
/// → HTTP 200 / `{"success": true}`（17 字节）。真正的打包下载应是 zip 字节流
/// （PK\x03\x04 开头）。这里两种都认：太小、或 JSON 文本 → 视为桩。
bool looksLikeServerStub(List<int> bytes) {
  if (bytes.length < 4) return true;
  // zip 魔数 `PK\x03\x04`
  if (bytes[0] == 0x50 && bytes[1] == 0x4B) return false;
  // JSON 文本（`{"`）→ 桩
  final head = String.fromCharCodes(bytes.take(2));
  return head.trimLeft().startsWith('{');
}

/// 离线缓存接口。
abstract interface class AudioOfflineStore {
  /// 已缓存的曲目 id。
  Future<Set<String>> ids();

  /// 某曲目是否已缓存。
  Future<bool> has(String id);

  /// 写入缓存；返回是否**真的**存下来了（false → 调用方如实提示）。
  Future<bool> save(String id, List<int> bytes);

  /// 缓存文件路径（没缓存 / 拿不到目录 → null）。
  Future<String?> pathOf(String id);
}

/// 内存实现（测试 / 无文档目录时兜底）。
class InMemoryAudioOfflineStore implements AudioOfflineStore {
  InMemoryAudioOfflineStore({Map<String, List<int>>? files})
    : _files = {...?files};

  final Map<String, List<int>> _files;

  @override
  Future<Set<String>> ids() async => _files.keys.toSet();

  @override
  Future<bool> has(String id) async => _files.containsKey(id);

  @override
  Future<bool> save(String id, List<int> bytes) async {
    _files[id] = List<int>.from(bytes);
    return true;
  }

  @override
  Future<String?> pathOf(String id) async =>
      _files.containsKey(id) ? 'memory://$id' : null;
}

/// 应用文档目录实现：`<docs>/audio_offline/<id>.zip`。
class AppAudioOfflineStore implements AudioOfflineStore {
  AppAudioOfflineStore({Future<Directory?> Function()? dirResolver})
    : _dirResolver = dirResolver ?? _defaultDir;

  static const String dirName = 'audio_offline';
  static const String _ext = '.zip';

  final Future<Directory?> Function() _dirResolver;

  static Future<Directory?> _defaultDir() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      return Directory('${base.path}/$dirName');
    } catch (_) {
      return null;
    }
  }

  /// 只接受安全 id（防路径穿越）：字母/数字/下划线/短横线/点以外的字符一律拒绝。
  static bool isSafeId(String id) =>
      id.isNotEmpty && RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id);

  Future<Directory?> _dir() async {
    final d = await _dirResolver();
    if (d == null) return null;
    try {
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Set<String>> ids() async {
    final d = await _dir();
    if (d == null) return const {};
    try {
      final out = <String>{};
      await for (final e in d.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!name.endsWith(_ext)) continue;
        out.add(name.substring(0, name.length - _ext.length));
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<bool> has(String id) async {
    if (!isSafeId(id)) return false;
    final d = await _dir();
    if (d == null) return false;
    try {
      return await File('${d.path}/$id$_ext').exists();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> save(String id, List<int> bytes) async {
    if (!isSafeId(id)) return false;
    final d = await _dir();
    if (d == null) return false;
    try {
      await File('${d.path}/$id$_ext').writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> pathOf(String id) async {
    if (!isSafeId(id)) return null;
    final d = await _dir();
    if (d == null) return null;
    try {
      final f = File('${d.path}/$id$_ext');
      return await f.exists() ? f.path : null;
    } catch (_) {
      return null;
    }
  }
}

/// 离线缓存存储（测试覆盖成内存实现；生产用文档目录）。
final audioOfflineStoreProvider = Provider<AudioOfflineStore>(
  (ref) => AppAudioOfflineStore(),
);
