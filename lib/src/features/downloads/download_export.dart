// 任务源文件（`.torrent`/`.nzb`）导出（F7）—— **复用仓库既有的落盘通道**。
//
// 事实来源（**真机已证实**）：`docs/download-api-live.md:36`（`Task.Source:download`
// v2，参数 **`id`**）+ §6.4（HTTP 200、20792 字节、bencode 开头的真实 `.torrent`）
// + NAS 包内官方前端 `ui/download.js` 的 `InfoGeneral`
// （`getBaseURL({api, method:"download", version:2, params:{id,t}}, true,
// title+".torrent")` —— 一条**带鉴权的直链**）。
//
// 为什么这样落盘：不新造平台通道。目录用 FileStation/Office 导出共用的
// `fileDownloadDirectory()`（`<应用文档>/downloads`），写文件用 `dart:io` 的
// `File.writeAsBytes` —— 与 `office_export.dart` 的 `downloadOfficeAs` 同一套做法。
//
// ⚠️ 二进制：直链回的是 bencode 字节流，**不能按 JSON 解析**（`getBytes` 原样返回；
// 非 BT 任务的 `HTTP 404 + HTML` 会被传输层还原成带状态码的异常）。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/download_station.dart';
import '../files/file_providers.dart' show fileDownloadDirectory;
import 'download_providers.dart';

/// 落盘目录（`<应用文档>/downloads`）。做成 provider 是为了**测试**：
/// 纯 Dart/widget 测试没有 `path_provider` 平台通道，覆盖成临时目录即可
/// （与 `officeDownloadDirProvider` 同款）。
final dsDownloadDirProvider = Provider<Future<Directory> Function()>(
  (ref) => fileDownloadDirectory,
);

/// **纯函数式核心**：取源文件字节 → 落盘，返回落盘后的完整路径。
///
/// 不碰 provider，便于离线单测（真实 IO）。失败直接抛（调用方翻文案）。
Future<String> saveTaskSource({
  required DownloadStationApi api,
  required Future<Directory> Function() dir,
  required String taskId,
  required String title,
}) async {
  final bytes = await api.downloadSource(taskId);
  final name = dsTorrentFileName(title);
  final directory = await dir();
  final file = File('${directory.path}/$name');
  await file.writeAsBytes(bytes);
  return file.path;
}

/// 「导出源文件」的页面级动作。
///
/// 做成 provider 是为了让 **widget 测试不必碰真实文件 IO**（`testWidgets` 的
/// 假异步 zone 里 `File.writeAsBytes` 不会完成 → 会挂住测试）；默认实现就是
/// 上面那条既有落盘通道。
typedef DsSourceSaver = Future<String> Function(String taskId, String title);

final dsSourceSaverProvider = Provider<DsSourceSaver>((ref) {
  return (taskId, title) {
    final api = ref.read(downloadApiProvider);
    if (api == null) throw StateError('未连接');
    // await 之前把要用的 provider 一次性取好：widget 卸载后 `ref` 不能再碰
    // （riverpod 3 的 `_assertNotDisposed`）。
    final dir = ref.read(dsDownloadDirProvider);
    return saveTaskSource(
      api: api,
      dir: dir,
      taskId: taskId,
      title: title,
    );
  };
});

/// 任务标题 → `.torrent` 文件名（官方是直接 `title + ".torrent"`）。
///
/// 只做必要净化：把路径分隔符换掉（标题理论上不含，但不给落盘留坑），
/// 空标题给 `task`，缺 `.torrent` 后缀补上。
String dsTorrentFileName(String title) {
  var base = title.trim().replaceAll(RegExp(r'[/\\]+'), '_');
  if (base.isEmpty) base = 'task';
  if (!base.toLowerCase().endsWith('.torrent')) base = '$base.torrent';
  return base;
}
