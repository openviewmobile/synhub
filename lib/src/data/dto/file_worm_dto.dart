// `SYNO.FileStation.Worm` 的**只读**模型（get / get_share_info，v1）。
//
// 事实来源（按规程 §1 的优先级）：
//   1. **真机实测**（DSM 7.x / DS923+，普通用户 `demo_user`，2026-09-22 本会话重新取证）
//      —— 逐字回包见 `docs/filestation-worm-photoupload-wave.md`；
//   2. **官方 FileStation Web 前端** `ui/file_browser/FileProperty.js` /
//      `ui/file_browser/FileBrowserUtil.js`（随 FileStation 1.5.1-2410 包发布）
//      —— 参数形态、字段名、**枚举数值**、以及"什么时候算未启用"的判定；
//   3. 服务端 `webapi/SYNO.FileStation.lib`
//      —— `Worm` v1 只有 `get` / `get_share_info`（v2 段**没有方法**，所以 v2 恒 103）。
//
// ⚠️ **DSfile 4.17.2-609 的 dex 里没有 `get_share_info`**：它是 Web 端专属调用点，
// 所以 `def_lock_*` / `subvol_mode` 这些字段名在 APK 里查不到，只能靠上面 1/2 两级。
import 'file_mount_dto.dart' show FileWormState;

/// 子卷 WORM 模式（`subvol_mode`）。
///
/// 数值逐字来自官方 `FileBrowserUtil.js`：
/// `WormShare.SubVolMode.{Normal=1, Enterprise=2, Compliance=3, NormalPlus=4}`。
abstract final class FileWormSubVolMode {
  static const int normal = 1;
  static const int enterprise = 2;
  static const int compliance = 3;
  static const int normalPlus = 4;
}

/// 共享默认锁定模式（`def_lock_mode`）。
///
/// 数值逐字来自官方 `FileBrowserUtil.js`：
/// `WormShare.DefLockMode.{Manual=1, Normal=2, Immutable=3, Appendable=4}`。
abstract final class FileWormDefLockMode {
  static const int manual = 1;
  static const int normal = 2;
  static const int immutable = 3;
  static const int appendable = 4;

  /// 官方 `WormShareFieldset.setWormShareInfo` 的判定原文：
  ///
  /// ```js
  /// i = DefLockMode.Immutable===e.def_lock_mode || DefLockMode.Appendable===e.def_lock_mode;
  /// s = i ? _WFT("common","enable") : _WFT("common","disable");
  /// if (!i) { setValue("auto_lock", s); this.get("share_lock_info").hide(); return; }
  /// ```
  ///
  /// ⇒ **只有 Immutable / Appendable 算"自动锁定已启用"**，其余（Manual / Normal）
  /// 一律是"停用 + 隐藏锁定详情"。真机这台 NAS 回的就是 `def_lock_mode: 2`（Normal）
  /// ⇒ 界面应显示**未启用**，而**不是**错误。
  static bool autoLockEnabled(int mode) =>
      mode == immutable || mode == appendable;
}

/// `Worm:get` **内层** `errors[].code` 的取值 —— 真机逐条取证。
///
/// ⚠️ 外层 `error.code` **恒为 `1500`**（连"成功问到但没有 WORM 状态"也是 1500），
/// 所以**判别力全在内层**：只看外层会把"没有 WORM"误判成失败。
abstract final class FileWormPathCode {
  /// 该路径（及其所在共享）**没有 WORM 状态** —— 这是"未启用"，**不是失败**。
  static const int noWorm = 0;

  /// `path` 缺失或为空串（真机无参 / `path:""` 都是这个）。
  static const int emptyPath = 400;

  /// 路径不存在（真机 `path:"/mydrive"`，本机没有这个共享）。
  static const int pathNotFound = 408;
}

/// `Worm:get_share_info` 的结果 —— **共享级**的 WriteOnce 配置。
class FileWormShareInfo {
  const FileWormShareInfo({
    required this.subvolMode,
    required this.defLockMode,
    required this.defLockDuration,
    required this.lockWaitTime,
  });

  /// [FileWormSubVolMode] 之一。
  final int subvolMode;

  /// [FileWormDefLockMode] 之一。
  final int defLockMode;

  /// 默认锁定期间（秒）。真机未设置时回 **-1**（不是 0）。
  final int defLockDuration;

  /// 自动锁定等待时间（秒）。真机未设置时回 **-1**。
  final int lockWaitTime;

  /// 自动锁定是否启用（判定见 [FileWormDefLockMode.autoLockEnabled]）。
  bool get autoLockEnabled => FileWormDefLockMode.autoLockEnabled(defLockMode);

  /// 没有 `def_lock_mode` 就认为"没拿到共享配置"（返回 null，别硬凑默认值）。
  static FileWormShareInfo? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final mode = json['def_lock_mode'];
    if (mode is! num) return null;
    return FileWormShareInfo(
      subvolMode: _int(json['subvol_mode']),
      defLockMode: mode.toInt(),
      defLockDuration: _int(json['def_lock_duration'], fallback: -1),
      lockWaitTime: _int(json['lock_wait_time'], fallback: -1),
    );
  }
}

/// `Worm:get` 的结果 —— **逐路径**的 WriteOnce 状态。
///
/// 两种来源合并成同一个模型：
///   * 服务端 `success:true` + `data{worm_state, lock_time, unlock_time, …}`；
///   * 服务端 `success:false` + `error{code:1500, errors:[{code,path}]}`
///     —— 真机常态（[parseInner]）。
class FileWormPathStatus {
  const FileWormPathStatus({
    this.state,
    this.lockTime,
    this.unlockTime,
    this.lockDuration,
    this.lastUpdateTime,
    this.serverTime,
    this.code,
  });

  /// `worm_state`（线上下标 0..9，语义见 [FileWormState]）。
  final int? state;

  /// `lock_time` / `unlock_time` / `lock_duration` / `last_update_time` /
  /// `ds_current_time` —— 字段名来自官方 `WormFieldset.setLockRetention`。
  final int? lockTime;
  final int? unlockTime;
  final int? lockDuration;
  final int? lastUpdateTime;
  final int? serverTime;

  /// 内层 `errors[].code`；`null` = 走的是 `success:true` 分支。
  final int? code;

  /// 是否有真实的 WORM 状态（`success:true` 且有 `worm_state`）。
  bool get hasState => code == null && state != null;

  /// 该路径没有 WORM 状态（内层 code=0，或成功但服务端没给状态）。
  bool get notInWorm =>
      !hasState && (code == null || code == FileWormPathCode.noWorm);

  /// 官方 `WormState.isLockState`：状态值是 [FileWormState] 的位掩码结果。
  bool get isLocked =>
      state != null && FileWormState.isLocked(FileWormState.normalize(state!));

  bool get isOpen =>
      state != null && FileWormState.isOpen(FileWormState.normalize(state!));

  bool get isExpired =>
      state != null && FileWormState.isExpired(FileWormState.normalize(state!));

  /// `success:true` 的 `data` 分支。
  static FileWormPathStatus fromData(Map<String, dynamic> data) {
    return FileWormPathStatus(
      state: _intOrNull(data['worm_state']),
      lockTime: _intOrNull(data['lock_time']),
      unlockTime: _intOrNull(data['unlock_time']),
      lockDuration: _intOrNull(data['lock_duration']),
      lastUpdateTime: _intOrNull(data['last_update_time']),
      serverTime: _intOrNull(data['ds_current_time']),
    );
  }

  /// `success:false` 的**内层** `errors[]` 分支。
  ///
  /// 返回 null 表示"这不像是 Worm 的逐路径错误体"（外层不是 1500 / 没有 errors）
  /// —— 调用方据此决定是否照常抛异常。
  ///
  /// [outerCode] 必须是服务端的 `error.code`（`1500`）。
  static FileWormPathStatus? parseInner(
    Map<String, dynamic>? raw, {
    required int outerCode,
  }) {
    const wormOuterError = 1500;
    if (outerCode != wormOuterError) return null;
    final err = raw?['error'];
    if (err is! Map) return null;
    final errors = err['errors'];
    if (errors is! List || errors.isEmpty) return null;
    final first = errors.first;
    if (first is! Map) return null;
    final code = first['code'];
    if (code is! num) return null;
    return FileWormPathStatus(code: code.toInt());
  }
}

int _int(Object? v, {int fallback = 0}) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

int? _intOrNull(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
