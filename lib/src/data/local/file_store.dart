// 文件模块的本地缓存（Drift）—— 目录列表的 local-first。
//
// 为什么文件也要落库：跨家族架构里"一次登录全模块可用"解决的是**鉴权**，
// 但没解决**可达性**（休眠/外网/QuickConnect 打洞失败）。磁盘缓存让"上次看过的
// 目录"在离线时仍可浏览，并让刷新是"本地先出、网络回來再更新"。
//
// 键的选择：`path` 是服务端给的绝对路径（含共享名前缀），本身就是唯一键；
// 按 `parentPath` 整桶替换，避免删除的文件留在缓存里。
library;

import 'package:drift/drift.dart';

import '../../core/i18n/data_text.dart';
import '../../dsm/webapi.dart';
import '../dto/file_entry_dto.dart';
import 'database.dart';

class FileStore {
  FileStore(this.db);

  final ChatDatabase db;

  /// 某个目录下有哪些条目（一次性读）
  Future<List<FileEntryDto>> folder(String parentPath) async {
    final rows = await (db.select(
      db.fileEntryRows,
    )..where((t) => t.parentPath.equals(parentPath))).get();
    return _sort(rows.map(_fromRow).toList());
  }

  /// 监听某个目录（UI 用）
  Stream<List<FileEntryDto>> watchFolder(String parentPath) =>
      (db.select(db.fileEntryRows)
            ..where((t) => t.parentPath.equals(parentPath)))
          .watch()
          .map((rows) => _sort(rows.map(_fromRow).toList()));

  /// 用服务端返回的整份列表**替换**某个目录的缓存（事务内）。
  ///
  /// 删掉的不只是"这次没返回的"，还有"路径变了的老行"（重命名后 path 变了）。
  Future<void> replaceFolder(
    String parentPath,
    List<FileEntryDto> entries,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction(() async {
      final keep = entries.map((e) => e.path).toList();
      final del = db.delete(db.fileEntryRows)
        ..where((t) => t.parentPath.equals(parentPath));
      if (keep.isNotEmpty) {
        del.where((t) => t.path.isNotIn(keep));
      }
      await del.go();
      for (final e in entries) {
        await db
            .into(db.fileEntryRows)
            .insertOnConflictUpdate(_companion(e, parentPath, now));
      }
    });
  }

  /// 单个条目的最新快照（重命名/属性用）
  Future<FileEntryDto?> entry(String path) async {
    final row = await (db.select(
      db.fileEntryRows,
    )..where((t) => t.path.equals(path))).getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  Future<void> upsertEntry(String parentPath, FileEntryDto entry) async {
    await db
        .into(db.fileEntryRows)
        .insertOnConflictUpdate(
          _companion(entry, parentPath, DateTime.now().millisecondsSinceEpoch),
        );
  }

  /// 重命名后把本地缓存里那条也搬过去（省得下次刷新前显示旧名）
  Future<void> renameEntry(String oldPath, String newName) async {
    final existing = await entry(oldPath);
    if (existing == null) return;
    final slash = oldPath.lastIndexOf('/');
    final newPath = slash < 0
        ? newName
        : '${oldPath.substring(0, slash)}/$newName';
    await db.transaction(() async {
      await (db.delete(
        db.fileEntryRows,
      )..where((t) => t.path.equals(oldPath))).go();
      await db
          .into(db.fileEntryRows)
          .insertOnConflictUpdate(
            _companion(
              FileEntryDto(name: newName, path: newPath, isDir: existing.isDir),
              existing.path.contains('/')
                  ? existing.path.substring(0, existing.path.lastIndexOf('/'))
                  : '',
              DateTime.now().millisecondsSinceEpoch,
            ),
          );
    });
  }

  /// 删除本地缓存里的若干条目
  Future<void> removeEntries(List<String> paths) async {
    if (paths.isEmpty) return;
    await (db.delete(db.fileEntryRows)..where((t) => t.path.isIn(paths))).go();
  }

  /// 清空整张缓存表（退出登录 / 换服务器时用）
  Future<void> clear() async => db.delete(db.fileEntryRows).go();

  /// 这张表有多大（设置页显示缓存占用）
  Future<int> count() async {
    final rows = await db
        .customSelect('SELECT COUNT(*) AS c FROM file_entry_rows')
        .getSingle();
    return rows.read<int>('c');
  }

  // ------------------------------------------------------------ 映射

  static FileEntryRowsCompanion _companion(
    FileEntryDto e,
    String parentPath,
    int cachedAt,
  ) => FileEntryRowsCompanion(
    path: Value(e.path),
    parentPath: Value(parentPath),
    name: Value(e.name),
    isDir: Value(e.isDir),
    size: Value(e.size),
    mtime: Value(e.mtime),
    crtime: Value(e.crtime),
    owner: Value(e.owner ?? ''),
    group: Value(e.group ?? ''),
    realPath: Value(e.realPath ?? ''),
    mountPointType: Value(e.mountPointType ?? ''),
    description: Value(e.description ?? ''),
    canRead: Value(e.canRead),
    canWrite: Value(e.canWrite),
    canExecute: Value(e.canExecute),
    disableDownload: Value(e.disableDownload),
    isWormShare: Value(e.isWormShare),
    // null（服务端没给 / 老库读出来）统一落空串 = 未知，读取时还原成 null
    wormState: Value(e.wormState ?? ''),
    cachedAt: Value(cachedAt),
  );

  static FileEntryDto _fromRow(FileEntryRow r) => FileEntryDto(
    name: r.name,
    path: r.path,
    isDir: r.isDir,
    size: r.size,
    mtime: r.mtime,
    crtime: r.crtime,
    owner: r.owner.isEmpty ? null : r.owner,
    group: r.group.isEmpty ? null : r.group,
    realPath: r.realPath.isEmpty ? null : r.realPath,
    mountPointType: r.mountPointType.isEmpty ? null : r.mountPointType,
    description: r.description.isEmpty ? null : r.description,
    canRead: r.canRead,
    canWrite: r.canWrite,
    canExecute: r.canExecute,
    disableDownload: r.disableDownload,
    isWormShare: r.isWormShare,
    // 空串 = 未知（老库 / 服务端没给）→ null，`wormLocked` 保持 fail-open
    wormState: r.wormState.isEmpty ? null : r.wormState,
  );

  /// 目录在前、同类按名称（与服务端 `sort_by=name` 的观感一致）
  static List<FileEntryDto> _sort(List<FileEntryDto> rows) {
    rows.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return rows;
  }
}

/// 「写权限」探测的结果缓存用不上：FileStation 每个目录都要单独问
/// `CheckPermission.write`，所以这里只提供错误码到中文的兜底文案。
///
/// ⚠️ `DsmErrorCode.messages[401]` 是**聊天**的"账号已停用"；FileStation 的
/// 401 实际是"没有权限"（真机实测：普通用户列 `/` 返回 401）。
/// 所以文件模块必须自己解释这几个码，不能直接 `DsmErrorCode.describe`。
String describeFileError(Object error) {
  if (error is DsmApiException) {
    // 105 在压缩/解压上是**账号没被授予该权限**（DSM 的 File Station
    // 应用权限里"压缩"和"解压"是分开的两项）—— 真机实测：demo_user 建目录/
    // 上传/改名/复制/删除/解压都行，唯独 **Compress 一律 105**。
    // 所以这里按方法分开说，别把"只是不能压缩"说成"压缩解压都不行"。
    final method = error.method ?? '';
    if (error.code == DsmErrorCode.noPermission) {
      if (method.startsWith('SYNO.FileStation.Compress')) {
        return dataText(
          'errNoCompressPermission',
          '这个账号没有压缩权限（DSM → 控制面板 → 应用程序权限 → File Station）',
        );
      }
      if (method.startsWith('SYNO.FileStation.Extract')) {
        return dataText(
          'errNoExtractPermission',
          '这个账号没有解压权限（DSM → 控制面板 → 应用程序权限 → File Station）',
        );
      }
    }
    switch (error.code) {
      case DsmErrorCode.noPermission:
        return dataText('errNoPathPermission', '没有权限访问该位置');
      // 408 在聊天里是"密码过期"，在 FileStation 里是**路径/文件不存在**
      // （真机：对不存在的目录 list、解压到不存在的目标目录都是 408）。
      case DsmErrorCode.fileNotFound:
      // Drive 的 1003 与 FileStation 的 408 **同义**（"这个对象不存在/访问失败"，
      // 真机只读实测原文见 `DsmErrorCode.drivePathNotFound`）⇒ 复用同一条文案，
      // 否则用户会看见裸 `Error code 1003`（DA10；r355 真机像素取证）。
      case DsmErrorCode.drivePathNotFound:
        return dataText('errTargetNotFound', '目标位置不存在（可能已被移动或删除）');
      case DsmErrorCode.authAccountDisabled:
      case DsmErrorCode.authPermissionDenied:
        return dataText('errNoPathPermission', '没有权限访问该位置');
      case DsmErrorCode.authMaxTries: // 407
        // ★ r395 订正（DA23 的"撒谎文案"就在这一行）：
        //
        // 旧代码把 FileStation 的 **407** 当成 Auth 的"限流"⇒ 用户看
        // 「请求过于频繁，请稍后再试」，于是**一直重试**（永远不会好）。
        // 官方 FileStation 1.5.1-2410 前端
        // （`ui/file_browser/FileBrowserUtil.js` 的 `getWebAPIErrStr`）逐字写着
        // `case 407: case 409: return _WFT("error","error_privilege_not_enough")`；
        // 真机原始读数一致：`List/list v2 {folder_path:"/teamdrivetest/#recycle"}`
        // → `{"error":{"code":407}}`，而同一分钟列该共享本体**成功**（r395 证据）。
        // ⇒ FileStation 家族一律按"权限"说（409 同理）；其它模块保持原样
        //   （聊天有自己的表 `DsmErrorCode.chatMessages`）。
        if (method.startsWith('SYNO.FileStation') ||
            method.startsWith('SYNO.Core.RecycleBin')) {
          return DsmErrorCode.describe(error.code, method: method);
        }
        return dataText('errTooManyRequests', '请求过于频繁，请稍后再试');
      case DsmErrorCode.apiNotFound:
        return dataText('errNoFileService', '这台 NAS 没有开启文件服务');
      case DsmErrorCode.methodNotFound:
      case DsmErrorCode.notSupportedVersion:
        return dataText('errFileServiceVersionMismatch', '这台 NAS 的文件服务版本不兼容');
      case DsmErrorCode.requestParameterInvalid:
        return dataText('errBadPathOrName', '参数不被接受（可能是路径或文件名）');
      case DsmErrorCode.sessionTimeout:
      case DsmErrorCode.sidNotFound:
        return dataText('errLoginExpired', '登录已过期，请重新登录');
      default:
        return DsmErrorCode.describe(error.code, method: error.method);
    }
  }
  return '$error';
}
