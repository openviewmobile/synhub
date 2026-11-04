// File Station C5（远程挂载 / 虚拟卷）的状态与动作层。
//
// 分层与 `file_providers.dart` 一致：
//   FileStationApi（协议，`SYNO.FileStation.Mount` / `Mount.List` / `VirtualFolder`）
//   → 本文件的 providers → `file_mount_page.dart`
//
// 取证要点（详见 `docs/filestation-parity-audit.md` §7.5 C3 与
// `/tmp/spk/export_FileStation/webapi/SYNO.FileStation.lib`）：
//   * 官方 VFS **只有 cifs + iso**；WebDAV 官方自己标废弃（不做）；
//   * `Mount` / `Mount.List` 的 allowUser 都含 `normal.*`，普通用户可用，
//     但服务器仍可能按共享/应用权限回 **105**，或按应用权限回 **160** ——
//     这两种一律**隐藏入口 + 给明确提示**，不留必失败的按钮。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/dto/file_mount_dto.dart';
import '../../data/filestation_api.dart';
import '../../dsm/webapi.dart';
import 'file_providers.dart';

/// 105（noPermission）/ 160（noAppPrivilege）→ 这个账号不能管挂载。
bool isMountPermissionError(int code) =>
    code == DsmErrorCode.noPermission || code == DsmErrorCode.noAppPrivilege;

/// 「新增挂载」入口的**官方门控**（服务端能力 × 身份 / 首页）。
///
/// ★ 逐字依据：官方 FileStation **1.5.1-2410** 前端
/// （样例库 `spk/FileStation-1.5.1-2410.spk` → 解包
/// `ui/file_browser/FileBrowser.js`，压缩成 3 行，按字符偏移引用）：
///
/// ```js
/// // onGetUserGrpDone（offset 395,971）；MountListDialog.loadData 同形（144,148）
/// this.mountConfig = t.support_virtual,   // ← SYNO.FileStation.Info:get v1 回包字段
/// ...
/// this.mountConfig.enable_remote_mount
///   ? (_S("is_admin") || this.dirTree.getNodeById("remote/home")
///        ? this.btnMountRemote && this.btnMountRemote.show()
///        : this.btnMountRemote.hide())
///   : this.btnMountRemote && this.btnMountRemote.hide(),
/// this.mountConfig.enable_iso_mount
///   ? this.btnMountISO && this.btnMountISO.show()
///   : this.btnMountISO && this.btnMountISO.hide(),
/// ```
///
/// * **不依赖**"已有挂载列表非空"（判据附近没有任何 `remoteList.length`）；
/// * `remote/home` = **用户的 `home` 文件夹**（User Home 已启用）—— 语义由官方
///   文案钉死（同包 `ui/file_browser/texts/enu/strings:742/747`）：
///   `config_remote_info = "Non-administrators can only mount remote folders
///   within their "home" folder."` ·
///   `err_remote_no_home = ""User Home" has to be enabled for this function.
///   Please contact your administrator."`；
/// * 另有 `_D("supportmount")==="yes"` 一道 DSM 变量门（决定按钮**是否被创建**）
///   —— 本仓的等价物是 [FileMountCapability]（服务端注册表里有没有 `Mount`）。
///
/// ⇒ `enable_*_mount` 为 false 时官方**整个藏掉**入口，而不是"点进去才报错"。
class FileMountGate {
  const FileMountGate({
    required this.remoteAllowed,
    required this.isoAllowed,
    this.remoteNeedsHome = false,
  });

  /// `enable_remote_mount && (is_admin || home)` —— 官方 `btnMountRemote`
  final bool remoteAllowed;

  /// `enable_iso_mount` —— 官方 `btnMountISO`
  final bool isoAllowed;

  /// 服务端**开了**远程卷，但**当前身份不满足**（非管理员且没有 `home`）——
  /// 用于把"服务器没开"和"你得在自己 home 里"两句原因分开说，别误报。
  final bool remoteNeedsHome;

  /// 官方 `btnMountList` 的判据：`enable_remote_mount || enable_iso_mount`
  bool get anyAllowed => remoteAllowed || isoAllowed;

  factory FileMountGate.of({
    required FileMountConfig config,
    required bool isAdmin,
    required bool hasHome,
  }) {
    final canRemote = config.enableRemoteMount && (isAdmin || hasHome);
    return FileMountGate(
      remoteAllowed: canRemote,
      isoAllowed: config.enableIsoMount,
      remoteNeedsHome: config.enableRemoteMount && !canRemote,
    );
  }
}

/// 挂载能力：服务器**注册表里有没有** `Mount` / `Mount.List` / `VirtualFolder`。
///
/// `apiTable` 为空（未发现 / 未登录）时 fail-open（当作有），与
/// [FileCapabilities] 同一约定：真正的拒绝交给运行时 105/160 兜底。
class FileMountCapability {
  const FileMountCapability({
    this.canManage = true, // Mount + Mount.List 都在
    this.canList = true, // Mount.List.get
    this.canMount = true, // Mount.mount_remote / mount_iso
    this.canUnmount = true, // Mount.unmount / Mount.List.unmount
    this.canVirtualFolder = true, // VirtualFolder.list
  });

  /// 挂载管理入口的总开关（缺 `Mount` 或 `Mount.List` 就整个藏掉）
  final bool canManage;
  final bool canList;
  final bool canMount;
  final bool canUnmount;
  final bool canVirtualFolder;

  static FileMountCapability probe(FileStationApi? api) {
    if (api == null) return const FileMountCapability();
    final table = api.api.apiTable;
    if (table == null) return const FileMountCapability();
    bool has(String name) => table.containsKey(name);
    final mount = has('SYNO.FileStation.Mount');
    final list = has('SYNO.FileStation.Mount.List');
    return FileMountCapability(
      canManage: mount || list,
      canList: list,
      canMount: mount,
      canUnmount: mount || list,
      canVirtualFolder: has('SYNO.FileStation.VirtualFolder'),
    );
  }
}

final fileMountCapabilityProvider = Provider<FileMountCapability>(
  (ref) => FileMountCapability.probe(ref.watch(fileApiProvider)),
);

/// 一次挂载列表读取的结果。
///
/// [permissionDenied] 为真 = 服务端回了 105/160；页面据此**换掉**新增/卸载
/// 按钮并显示原因，而不是让用户点了再失败。
class FileMountSnapshot {
  const FileMountSnapshot({
    this.list = const FileMountList(),
    this.permissionDenied = false,
    this.errorCode,
  });

  final FileMountList list;
  final bool permissionDenied;
  final int? errorCode;
}

/// `SYNO.FileStation.Mount.List / get`
final fileMountsProvider =
    FutureProvider.autoDispose<FileMountSnapshot>((ref) async {
      final api = ref.watch(fileApiProvider);
      if (api == null) return const FileMountSnapshot();
      if (!ref.watch(fileMountCapabilityProvider).canList) {
        return const FileMountSnapshot();
      }
      try {
        return FileMountSnapshot(list: await api.listMounts());
      } on DsmApiException catch (e) {
        if (isMountPermissionError(e.code)) {
          return FileMountSnapshot(permissionDenied: true, errorCode: e.code);
        }
        rethrow;
      }
    }, retry: noRetry);

/// 服务器自带的两个虚拟根里的内容（官方 DS file 的
/// `[__VIRTUAL__CIFS__]` / `[__VIRTUAL__ISO__]` 哨兵走的就是这条路）。
///
/// ✅ 这一批把审计 §5 U9 的**死代码**接上：官方前端
/// `FileBrowserUtil.js` 的树加载器对 `fm_rf_root` 用
/// `VirtualFolder.list` + `baseParams.type=["cifs","nfs"]`，对 `fm_vd_root`
/// 用 `type="iso"`（**裸字符串**，不是数组）。
final fileVirtualFoldersProvider = FutureProvider.autoDispose
    .family<List<FileEntryDto>, FileMountType>((ref, type) async {
      final api = ref.watch(fileApiProvider);
      if (api == null) return const [];
      if (!ref.watch(fileMountCapabilityProvider).canVirtualFolder) {
        return const [];
      }
      try {
        final result = await api.listVirtualFolders(
          type: [type.listValue],
          bareType: type == FileMountType.iso,
        );
        return result.entries;
      } on DsmApiException catch (e) {
        // 普通用户对虚拟根可能 105；这是"看不到"而不是"崩"
        if (isMountPermissionError(e.code) ||
            e.code == DsmErrorCode.apiNotFound ||
            e.code == DsmErrorCode.methodNotFound) {
          return const [];
        }
        rethrow;
      }
    }, retry: noRetry);

/// 挂载动作控制器：新增 / 卸载 / 重连 / 重挂，成功后失效列表。
class FileMountActions {
  FileMountActions(this._ref);

  final Ref _ref;

  FileStationApi get _api {
    final api = _ref.read(fileApiProvider);
    if (api == null) {
      throw DsmApiException(
        DsmErrorCode.apiNotFound,
        method: 'FileStation（未连接）',
      );
    }
    return api;
  }

  void _invalidate() {
    _ref.invalidate(fileMountsProvider);
    for (final t in FileMountType.values) {
      _ref.invalidate(fileVirtualFoldersProvider(t));
    }
  }

  /// 新增 CIFS 远程挂载（`Mount.mount_remote`，凭据按官方原文发明文）。
  Future<void> mountCifs({
    required String serverIp,
    required String mountPoint,
    required String account,
    required String password,
    required bool autoMount,
    bool userSet = true,
  }) async {
    await _api.mountCifs(
      serverIp: serverIp,
      mountPoint: mountPoint,
      account: account,
      password: password,
      autoMount: autoMount,
      userSet: userSet,
    );
    _invalidate();
  }

  /// 新增 ISO 挂载（`Mount.mount_iso`）。
  Future<void> mountIso({
    required String source,
    required String mountPoint,
    required bool autoMount,
    bool userSet = true,
  }) async {
    await _api.mountIso(
      source: source,
      mountPoint: mountPoint,
      autoMount: autoMount,
      userSet: userSet,
    );
    _invalidate();
  }

  /// 卸载（`Mount.List.unmount`，`mount_point` 是数组）。
  Future<void> unmount(List<String> mountPoints) async {
    await _api.unmountMounts(mountPoints);
    _invalidate();
  }

  /// 单点卸载（`Mount.unmount`，带 `mount_type` + `is_mount_point`）。
  Future<void> unmountOne(FileMountDto mount) async {
    final type = mount.mountType;
    if (type == null) {
      await unmount([mount.mountPoint]);
      return;
    }
    await _api.unmountVolume(
      mountType: type.volumeValue,
      mountPoint: mount.mountPoint,
    );
    _invalidate();
  }

  /// 重连远端卷（CIFS）。
  Future<void> reconnect(List<String> mountPoints) async {
    await _api.reconnectMounts(mountPoints);
    _invalidate();
  }

  /// 重挂某类型的所有卷（iso / remote）。
  Future<void> remount(FileMountType type) async {
    await _api.remountAll(type.volumeValue);
    _invalidate();
  }
}

final fileMountActionsProvider = Provider<FileMountActions>(
  FileMountActions.new,
);

/// "这个账号已经被服务器拒过挂载权限"——一旦为真，浏览页就**不再显示入口**。
///
/// 只由 [FileMountActions] / 页面在拿到 105/160 时置位；不落盘（重启后重探，
/// 权限是可能在 DSM 侧被改的）。
class FileMountDeniedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void mark() {
    if (!state) state = true;
  }
}

final fileMountPermissionDeniedProvider =
    NotifierProvider<FileMountDeniedNotifier, bool>(
      FileMountDeniedNotifier.new,
    );

