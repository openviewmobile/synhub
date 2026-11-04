// 219（M67）离线文件（Pin）—— **纯客户端**能力。
//
// ## 为什么说它纯客户端
//
// 官方 DS file 的 `command/Pin.java`（`extends Get`，字段 `mLocalPath` /
// `mLast_update`）与 `PinFileBrowserFragment` 是**本地命令 + 本地目录**：
// 把一个 NAS 路径登记到本地"离线文件"清单、把文件缓存到本地；
// `DrawerFragment` 的 Offline Files 只是读这份本地清单。
// 本仓库 `api-server-authoritative.md` 里**没有任何** offline/Pin 服务端方法
// （`docs/parity-recount-chat-files.md:425` 逐字结论），所以"没有服务端 API"
// **不等于做不了**——它本来就该在本地做。
//
// ## 本实现的范围（如实登记）
//
//   * **清单持久化**：`path → {name, size, pinnedAt, localPath}`，槽位
//     `file_offline_pin_v1`（沿用仓库既有安全存储，与
//     `drive_gaps_stores.dart` 同一降级纪律：读不出来当空表、写不进去只影响
//     下次还在不在）；
//   * **入口/列表/取消**：`file_tools_sheet.dart` → `FileOfflinePage`；
//   * **登记与缓存是两件事**：登记只写清单（秒回、不联网）；**真把字节放到
//     本机**由 `file_download_resume.dart` 的缓存层完成（第 302 轮补 —— 在此之前
//     `localPath` 全仓没有生产者，"系统文件里能看到离线文件"是条死路）。
//     缓存失败**不回滚登记**：清单里如实显示"未缓存"，与官方
//     `Pin` 在、`mLocalPath` 空的形态一致。
//   * **不自动下载整棵目录**：官方 Pin 的后台批量缓存是"下载队列 + 目录布局"
//     一整套工程（重判文档判 **L**）；这里只做**用户点过的那一个文件**。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'drive_saf_index.dart';
import 'file_download_resume.dart';
import 'drive_providers.dart';
import 'drive_saf_prefetch.dart';
import 'drive_saf_remote.dart';
import '../../core/platform/app_secure_storage.dart';

/// 一条离线登记。
class OfflinePinEntry {
  const OfflinePinEntry({
    required this.path,
    required this.name,
    this.size = 0,
    this.pinnedAt = 0,
    this.localPath = '',
  });

  /// NAS 上的完整路径（清单主键）
  final String path;

  /// 文件名（官方 `Pin.mName`）
  final String name;

  /// 字节数（官方 `Pin` 的 size）
  final int size;

  /// 登记时间（epoch 秒；对应官方 `mLast_update`）
  final int pinnedAt;

  /// 已缓存到本地的路径（官方 `mLocalPath`）；**未缓存时为空串**
  final String localPath;

  bool get hasLocalCopy => localPath.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'size': size,
    'pinned_at': pinnedAt,
    if (localPath.isNotEmpty) 'local_path': localPath,
  };

  static OfflinePinEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = '${raw['path'] ?? ''}';
    if (path.isEmpty) return null;
    return OfflinePinEntry(
      path: path,
      name: '${raw['name'] ?? path.split('/').last}',
      size: raw['size'] is num ? (raw['size'] as num).toInt() : 0,
      pinnedAt: raw['pinned_at'] is num
          ? (raw['pinned_at'] as num).toInt()
          : 0,
      localPath: '${raw['local_path'] ?? ''}',
    );
  }
}

/// 离线清单的存取（可注入 → 离线可测）。
abstract class OfflinePinStore {
  Future<List<OfflinePinEntry>> read();
  Future<void> write(List<OfflinePinEntry> entries);
}

class SecureOfflinePinStore implements OfflinePinStore {
  SecureOfflinePinStore([FlutterSecureStorage? storage])
    : _storage =
          storage ?? appSecureStorage(android: const AndroidOptions());

  static const String slot = 'file_offline_pin_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<List<OfflinePinEntry>> read() async {
    try {
      final raw = await _storage.read(key: slot);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (OfflinePinEntry.fromJson(e) case final entry?) entry,
      ];
    } catch (_) {
      // 存储不可用 / 旧值损坏 → 当空清单（绝不让坏的持久化把页面打崩）
      return const [];
    }
  }

  @override
  Future<void> write(List<OfflinePinEntry> entries) async {
    try {
      if (entries.isEmpty) {
        await _storage.delete(key: slot);
        return;
      }
      await _storage.write(
        key: slot,
        value: jsonEncode([for (final e in entries) e.toJson()]),
      );
    } catch (_) {
      // 写不进去只影响"下次还在不在"
    }
  }
}

/// 内存实现（单测用）
class MemoryOfflinePinStore implements OfflinePinStore {
  MemoryOfflinePinStore([List<OfflinePinEntry>? initial])
    : _items = [...?initial];

  List<OfflinePinEntry> _items;

  List<OfflinePinEntry> get items => List.unmodifiable(_items);

  @override
  Future<List<OfflinePinEntry>> read() async => [..._items];

  @override
  Future<void> write(List<OfflinePinEntry> entries) async =>
      _items = [...entries];
}

final offlinePinStoreProvider = Provider<OfflinePinStore>(
  (ref) => SecureOfflinePinStore(),
);

/// ★ D66：把"离线文件"清单同步成 **SAF 索引**，让系统文件选择器
/// （`DriveDocumentsProvider`，见 `android/.../DriveDocumentsProvider.kt`）
/// 能看到已经缓存到本地的文件。
///
/// 写成可注入的函数 provider：默认写
/// `getApplicationDocumentsDirectory()/saf/drive_index.json`；单测里换成记录器，
/// 断言"登记/取消登记都会同步索引"（**不碰** path_provider 的平台通道）。
final safIndexSinkProvider =
    Provider<Future<void> Function(List<OfflinePinEntry>)>((ref) {
      return (pins) async {
        try {
          final dir = await getApplicationDocumentsDirectory();
          await writeSafIndex(
            dir,
            SafIndex(
              rootTitle: safOfflineRootTitle,
              entries: buildSafIndex(pins),
            ),
          );
        } catch (_) {
          // 索引写不进去只影响"系统选择器里有没有离线文件"，不拖垮主流程。
        }
      };
    });

/// ★ 221 轮 D66：要把哪些 Drive 目录镜像进 SAF 索引（远端半边）。
/// 默认只镜像「我的文件」一层树（深度上限见 `drive_saf_remote.dart`）。
/// ★ 227 轮 D66：云端条目的**有界预取策略**（默认单文件 8MB / 总 24MB / 20 个）。
final safPrefetchPolicyProvider = Provider<SafPrefetchPolicy>(
  (ref) => const SafPrefetchPolicy(),
);

final safRemoteFoldersProvider = Provider<List<String>>(
  (ref) => const ['/mydrive'],
);

/// 合并后（离线 + 云端镜像）的索引落盘口。
///
/// 与 [safIndexSinkProvider] 分开：老 sink 只负责"离线那部分"的兼容行为
/// （已有用例在断言它），新 sink 收的是**合并结果**。
final safMergedIndexSinkProvider = Provider<Future<void> Function(SafIndex)>((
  ref,
) {
  return (index) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      await writeSafIndex(dir, index);
    } catch (_) {
      // 同上：写不进去只影响系统选择器，不拖垮主流程。
    }
  };
});

/// 离线清单（按登记时间倒序，最新的在前）。
class OfflinePinNotifier extends Notifier<List<OfflinePinEntry>> {
  @override
  List<OfflinePinEntry> build() => const [];

  /// 页面 `initState` 调一次，把落盘的清单读回内存。
  Future<void> preload() async {
    final items = await ref.read(offlinePinStoreProvider).read();
    if (ref.mounted) state = _sorted(items);
  }

  bool isPinned(String path) => state.any((e) => e.path == path);

  /// 登记 / 取消登记（返回**操作后**是否处于已登记态）。
  Future<bool> toggle(OfflinePinEntry entry) async {
    final pinned = isPinned(entry.path);
    if (pinned) {
      await unpin(entry.path);
      return false;
    }
    await pin(entry);
    return true;
  }

  Future<void> pin(OfflinePinEntry entry) async {
    final next = [
      entry,
      ...state.where((e) => e.path != entry.path),
    ];
    state = _sorted(next);
    await ref.read(offlinePinStoreProvider).write(state);
    await _syncSaf(state);
  }

  Future<void> unpin(String path) async {
    // ★ 302：取消登记要**连本地副本一起删**，否则磁盘上留孤儿字节
    // （用户以为"移出离线"就释放了空间）。
    for (final e in state.where((e) => e.path == path)) {
      await deleteOfflineCopy(e.localPath);
    }
    final next = state.where((e) => e.path != path).toList(growable: false);
    state = next;
    await ref.read(offlinePinStoreProvider).write(next);
    await _syncSaf(next);
  }

  Future<void> clear() async {
    for (final e in state) {
      await deleteOfflineCopy(e.localPath);
    }
    state = const [];
    await ref.read(offlinePinStoreProvider).write(const []);
    await _syncSaf(const []);
  }

  /// ★ D66：清单变了就同步一次 SAF 索引（Kotlin provider 读的就是它）。
  ///
  /// ★ 221 轮补**远端半边**：已连 Drive 时再拉一次目录树镜像（`:real:`），
  /// 与离线那份合并后落盘 ⇒ 系统选择器里能**浏览/搜索云端文件**；
  /// 没连/拉取失败就只写离线那份（**退化成 213 轮的行为，不报错**）。
  Future<void> _syncSaf(List<OfflinePinEntry> items) async {
    // ★ r502：**每次 `await` 之后都要先问 `ref.mounted`**。
    //   这里整条链是"登记 → 落盘 → 同步 SAF 索引"，最后一跳可能落到
    //   `uid` 已经销毁之后（真机/用例里 provider 被 dispose 的时机不受控），
    //   于是 `ref.read` 抛 `UnmountedRefException` —— 本轮的
    //   `files_extra_ui_test` 就是这么红的（异常发生在用例结束之后，报成偶发）。
    if (!ref.mounted) return;
    try {
      await ref.read(safIndexSinkProvider)(items);
    } catch (_) {
      // 同上：索引是"锦上添花"，失败不影响清单本身。
    }
    if (!ref.mounted) return;
    final local = SafIndex(
      rootTitle: safOfflineRootTitle,
      entries: buildSafIndex(items),
    );
    var merged = local;
    final api = ref.read(driveApiProvider);
    if (api != null) {
      try {
        final mirror = await buildSafRemoteIndex(
          folders: ref.read(safRemoteFoldersProvider),
          listFolder: (p) async => (await api.list(path: p, limit: 200)).items,
        );
        // ★ 227 轮 D66：有界预取（小文件下载到私有缓存）
        // ⇒ 这些 `:real:` 条目在系统选择器里**直接能打开**。
        var pinned = const <String, String>{};
        final policy = ref.read(safPrefetchPolicyProvider);
        if (policy.enabled) {
          final cacheDir = await getApplicationDocumentsDirectory();
          final writer = SafPrefetchFileWriter('${cacheDir.path}/saf_cache');
          final r = await prefetchSafCloudEntries(
            entries: mirror.entries,
            policy: policy,
            fetch: (fileId, name) async => api.api.getBytes(
              api.downloadUrl(fileId: fileId, isPreview: false),
            ),
            writeLocal: writer.write,
          );
          pinned = r.localPaths;
        }
        merged = mergeSafIndexes(
          local: local,
          remote: SafIndex(
            rootTitle: safRemoteRootTitle,
            entries: mirror.entries,
          ),
          localByDocumentId: pinned,
        );
      } catch (_) {
        // 远端镜像失败（没网/权限）⇒ 保持离线那份
      }
    }
    if (!ref.mounted) return;
    try {
      await ref.read(safMergedIndexSinkProvider)(merged);
    } catch (_) {
      // 同上
    }
  }

  /// 更新某条已登记项的本地副本路径（下载完成后回填 `mLocalPath`）。
  Future<void> setLocalPath(String path, String localPath) async {
    final next = [
      for (final e in state)
        if (e.path == path)
          OfflinePinEntry(
            path: e.path,
            name: e.name,
            size: e.size,
            pinnedAt: e.pinnedAt,
            localPath: localPath,
          )
        else
          e,
    ];
    state = next;
    await ref.read(offlinePinStoreProvider).write(next);
    await _syncSaf(next);
  }

  List<OfflinePinEntry> _sorted(List<OfflinePinEntry> items) {
    final copy = [...items];
    copy.sort((a, b) => b.pinnedAt.compareTo(a.pinnedAt));
    return copy;
  }
}

final offlinePinProvider =
    NotifierProvider<OfflinePinNotifier, List<OfflinePinEntry>>(
      OfflinePinNotifier.new,
    );

/// 已登记的路径集合（列表页一次 watch，避免每行各 watch 一次）。
final offlinePinnedPathsProvider = Provider<Set<String>>((ref) {
  return {for (final e in ref.watch(offlinePinProvider)) e.path};
});

/// 离线清单的**容量汇总**（219 的"容量提示"）。
///
/// 为什么需要它：清单可能很长，用户想知道"我到底标记了多少东西、占多少"。
/// 注意语义边界（页面上也写）：这里统计的是**登记时记下的原始大小之和**，
/// 不是"本机已占用" —— 未下载（[OfflinePinEntry.hasLocalCopy] 为 false）
/// 的条目一个字节都还没落盘。
class OfflinePinUsage {
  const OfflinePinUsage({
    required this.totalBytes,
    required this.knownCount,
    required this.unknownCount,
  });

  /// 已知大小的条目之和（字节）
  final int totalBytes;

  /// 有大小信息的条目数
  final int knownCount;

  /// 大小为 0 / 未知的条目数（服务端没给 size 时）
  final int unknownCount;

  /// 有 ≥1 条大小未知 → UI 要显示"另有 N 项大小未知"
  bool get hasUnknown => unknownCount > 0;
}

/// 汇总一份离线清单（纯函数 → 离线可测）。
OfflinePinUsage offlinePinUsage(List<OfflinePinEntry> items) {
  var total = 0;
  var known = 0;
  var unknown = 0;
  for (final e in items) {
    if (e.size > 0) {
      total += e.size;
      known++;
    } else {
      unknown++;
    }
  }
  return OfflinePinUsage(
    totalBytes: total,
    knownCount: known,
    unknownCount: unknown,
  );
}
