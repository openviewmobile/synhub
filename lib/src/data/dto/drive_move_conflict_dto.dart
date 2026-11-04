// Drive 复制/移动的冲突项（P0-7）。
//
// 权威原文（**官方 Web 的 `mvcpNode` 先发 `dry_run:true` 探冲突**，
// `drive/synodrive_common.js:20`）：
//
// ```js
// mvcpNode:function(e,t,i,n){var o=String.format("{0}_files",e),
//   s=Ext.applyIf(t||{},{dry_run:!0});
//   if(s.conflict_action||!1===s.dry_run)return delete s.dry_run,void this.doMvcpNode(...);
//   SYNO.SDS.Drive.WebAPICore.sendPromise(o,s).then(function(t){
//     delete s.dry_run,
//     t.result&&this.needToShowConflictDialog(t.result)?this.showConflictDialog(...):
//       this.doMvcpNode(e,s,i,n)}...
// needToShowConflictDialog:function(e){if(Ext.isArray(e)&&0!==e.length){
//   return e.filter(function(e){return!e.dst_locked_by_others}).length>0}}
// doMvcpNode:function(e,t,i,n,o){t.conflict_action||(t.conflict_action=o||"autorename"),...}
// showConflictDialog:function(e,t,i,n){...e.src_info.file_id/name/display_path/size/
//   modified_time/file_type/e.renamed ... e.dst_info.file_id/name/display_path ...
// ```
//
// 上行白名单（`synodrive_common.js:20`）：
//   * `copyNode` → `files,to_parent_folder,conflict_action,dry_run`
//   * `moveNode` → `files,to_parent_folder,conflict_action,dry_run,change_name`
//
// ⇒ **dry_run 是官方原文**（不是我们发明的）；冲突回包形状就是这里解析的
// `result[]`，每一项带 `src_info` / `dst_info` / `dst_locked_by_others` / `renamed`。
//
// ⚠️ 与官方 Android 的差异（如实记录）：APK 的 `setAsMove`/`setAsCopy`
// **不探测**，恒发 `conflict_action:"autorename"`（`ApiSynoDriveFiles.java:557-587`）。
// 本实现采用官方 **Web** 的探测流程（同一条服务端接口），默认值仍是
// Android 的 `autorename` —— 两处原文都以参数值形式保留在
// `DriveApi.copyOrMove`。

/// `Files/{copy,move}` 的 `conflict_action` 取值
/// （APK `ApiSynoDriveFiles.java:44-47`，四个官方常量里我们用得上的三个）。
abstract final class DriveConflictAction {
  /// 自动重命名（官方 Android 的默认值，`ApiSynoDriveFiles.java:563/585`）
  static const String autorename = 'autorename';

  /// 覆盖同名目标（`ApiSynoDriveFiles.java:45`）
  static const String overwrite = 'overwrite';

  /// 遇到同名就停下（`ApiSynoDriveFiles.java:46`）
  static const String stop = 'stop';
}

/// `dry_run:true` 回包里的一条同名冲突
class DriveMoveConflict {
  const DriveMoveConflict({
    required this.sourceName,
    required this.sourcePath,
    required this.destName,
    required this.destPath,
    required this.destLockedByOthers,
    this.renamed = '',
    this.size = 0,
    this.modifiedTime = 0,
    this.fileType = '',
  });

  final String sourceName;
  final String sourcePath;
  final String destName;
  final String destPath;

  /// `dst_locked_by_others`：目标被别人锁住 → 官方**不算可处理的冲突**
  /// （`needToShowConflictDialog` 里被 filter 掉），我们照抄。
  final bool destLockedByOthers;

  /// `renamed`：官方给"自动重命名"后要落的名字
  final String renamed;

  final int size;
  final int modifiedTime;
  final String fileType;

  /// 从 `dry_run` 回包的一项构造（字段缺失一律回落，不抛）
  factory DriveMoveConflict.fromJson(Map<String, dynamic> json) {
    final src = (json['src_info'] as Map?)?.cast<String, dynamic>() ?? const {};
    final dst = (json['dst_info'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DriveMoveConflict(
      sourceName: '${src['name'] ?? ''}',
      sourcePath: '${src['display_path'] ?? src['path'] ?? ''}',
      destName: '${dst['name'] ?? ''}',
      destPath: '${dst['display_path'] ?? dst['path'] ?? ''}',
      destLockedByOthers: _bool(json['dst_locked_by_others']),
      renamed: '${json['renamed'] ?? ''}',
      size: _int(src['size']),
      modifiedTime: _int(src['modified_time']),
      fileType: '${src['file_type'] ?? ''}',
    );
  }

  /// 回包 `result` 数组 → 冲突列表。
  ///
  /// 与官方 `needToShowConflictDialog` 等价：非数组 / 空 / 全是
  /// `dst_locked_by_others` 时不弹框（返回空列表）。
  static List<DriveMoveConflict> listFromResult(Object? result) {
    if (result is! List) return const [];
    final all = result
        .whereType<Map>()
        .map((e) => DriveMoveConflict.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
    return all.where((c) => !c.destLockedByOthers).toList(growable: false);
  }
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}

bool _bool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return false;
}
