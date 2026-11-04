// 使用日志库的**连接层（非 web）** —— 磁盘库 / 内存库。
//
// 为什么把"连接"单独拆一个文件（第 334 轮）：`drift/native` 与 `drift_flutter`
// 都会传递到 `package:sqlite3` 的 FFI 后端 ⇒ 只要 `main.dart` 可达图里出现它们，
// `flutter build web` 就编译不过。web 上要的是 drift 的 **wasm** 后端
// （`drift/wasm.dart` + `sqlite3.wasm` 资产），那是**另一个后端**，不是加个 shim
// 能糊过去的（见 `docs/platform-web.md` §14）。
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../core/platform/app_paths.dart';

/// 磁盘库（Linux 站 P0-2 的修法保留：走 [AppPaths.documentsDirectory]）
QueryExecutor analyticsConnection() => driftDatabase(
  name: 'synology_analytics',
  native: DriftNativeOptions(databaseDirectory: AppPaths.documentsDirectory),
);

/// 内存库：离线测试，以及"磁盘开库失败"时的兜底
QueryExecutor analyticsMemoryConnection() => NativeDatabase.memory();
