// ★★★ ④笔记 **N9「存储位置（内部 / 外置 SD）」** —— 第 235 轮（234 轮复核的 ❌）。
//
// 官方 Android Note Station 在设置里让用户选附件/离线数据的落点：
// **内部存储**（应用私有目录）或**外置 SD**。
//
// 本文件把这件事做成**可判定、可注入**的一层：
//   * [NoteStorageLocation]：`internal` / `external`（wire 值逐字用官方的
//     `internal_storage` / `external_storage` 口径）；
//   * [resolveNoteStorageRoot]：给出根目录 + **是否回退**（外置不可用时退回内部
//     并如实报告 `fellBack = true`，**不假装外置成功**）；
//   * [NoteStorageLocationNotifier]：KV 落库（与 N7 默认字号同一套 `chatStore`
//     setting 机制），设置页改完立刻生效。
//
// ⚠️ Android 10+ 的分区存储下 `getExternalStorageDirectory()` 返回的是**应用专属
// 外置目录**（卸载即清），不是任意 SD 卡路径 —— 这一点在台账里如实写明，
// 不把它说成"能写用户任意 SD 卡"。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_session_controller.dart' show chatStoreProvider;

import '../../core/platform/app_paths.dart' show AppPaths;
import '../../core/platform/app_platform.dart' show CapabilityReason;

/// 官方 wire 值（`internal_storage` / `external_storage`）
enum NoteStorageLocation {
  internal('internal_storage'),
  external('external_storage');

  const NoteStorageLocation(this.wire);

  final String wire;

  static NoteStorageLocation fromWire(String? raw) {
    for (final v in NoteStorageLocation.values) {
      if (v.wire == raw) return v;
    }
    return NoteStorageLocation.internal;
  }
}

/// 设置里用的 KV key（官方 Android `PrefsSettingsFragment` 的"存储位置"项；
/// 值口径同 [NoteStorageLocation.wire]）。
const String kNoteStorageLocationKey = 'note_storage_location';

/// 根目录解析结果：`path` 为最终落点，`fellBack` 表示外置不可用已退回内部。
class NoteStorageRoot {
  const NoteStorageRoot({
    required this.location,
    required this.path,
    required this.fellBack,
  });

  final NoteStorageLocation location;
  final String path;
  final bool fellBack;

  @override
  String toString() =>
      'NoteStorageRoot(${location.wire}, $path, fellBack=$fellBack)';
}

/// 目录解析器（可注入 ⇒ 用例不碰平台通道）
typedef NoteStorageDirResolver = Future<String?> Function(bool external);

Future<String?> _defaultResolver(bool external) async {
  // 第 279 轮：口径统一走 `AppPaths.noteStorageRoot()`。
  // macOS/Linux/Windows 上**没有**"外置存储"这一档 ⇒ 回内部路径 +
  // `not-supported-on-host`（界面据此把"外置"置灰并写明原因，
  // 而不是静默当成外置成功）。
  final r = await AppPaths.noteStorageRoot(external: external);
  return r.path.isEmpty ? null : r.path;
}

/// 桌面宿主上"外置存储"这档的原因码（空串 = 这一档在本平台真实存在）。
String noteExternalStorageReason() =>
    AppPaths.host.isMobile ? '' : CapabilityReason.notSupportedOnHost;

/// 解析附件/离线数据的根目录。
///
/// 外置取不到（模拟器无 SD、权限被拒、被系统清理）⇒ **回退内部** 并 `fellBack=true`。
Future<NoteStorageRoot> resolveNoteStorageRoot(
  NoteStorageLocation location, {
  NoteStorageDirResolver? resolver,
}) async {
  final r = resolver ?? _defaultResolver;
  if (location == NoteStorageLocation.internal) {
    final dir = await r(false);
    return NoteStorageRoot(
      location: NoteStorageLocation.internal,
      path: dir ?? '',
      fellBack: false,
    );
  }
  final ext = await r(true);
  if (ext != null && ext.isNotEmpty) {
    return NoteStorageRoot(
      location: NoteStorageLocation.external,
      path: ext,
      fellBack: false,
    );
  }
  final dir = await r(false);
  return NoteStorageRoot(
    location: NoteStorageLocation.internal,
    path: dir ?? '',
    fellBack: true,
  );
}

/// 存储位置偏好（KV 落库；附件落盘时生效）。
final noteStorageLocationProvider =
    NotifierProvider<NoteStorageLocationNotifier, NoteStorageLocation>(
      NoteStorageLocationNotifier.new,
    );

class NoteStorageLocationNotifier extends Notifier<NoteStorageLocation> {
  /// 用户是否已经显式选过。
  ///
  /// ★ 235 轮实测踩到：`build()` 里的 KV 异步读**晚于**用户点击到达，
  /// 若读不到值就按默认写回 state ⇒ **把用户刚选的档位冲掉**
  /// （用例 `N9 存储位置 · 设置面板入口` 就是靠这个断言抓出来的）。
  /// 因此异步回填只在"用户还没动过"时生效。
  bool _userChose = false;

  @override
  NoteStorageLocation build() {
    // KV 异步：先给官方默认（内部），读到值再更新（首帧不阻塞）。
    Future<void>(() async {
      try {
        final raw = await ref
            .read(chatStoreProvider)
            .setting(kNoteStorageLocationKey);
        if (_userChose || raw == null) return;
        final v = NoteStorageLocation.fromWire(raw);
        if (state != v) state = v;
      } catch (_) {
        // 读不到就用默认
      }
    });
    return NoteStorageLocation.internal;
  }

  Future<void> set(NoteStorageLocation value) async {
    _userChose = true;
    state = value;
    await ref
        .read(chatStoreProvider)
        .setSetting(kNoteStorageLocationKey, value.wire);
  }
}

/// 附件缓存根目录（给 `downloadNoteAttachmentToCache(rootDir:)` 用）。
///
/// 返回值里的 `fellBack` 要跟着结果一起用（UI 可提示"外置不可用，已存内部"）。
Future<NoteStorageRoot> noteAttachmentCacheRoot(Ref ref) async {
  final location = ref.read(noteStorageLocationProvider);
  return resolveNoteStorageRoot(location);
}
