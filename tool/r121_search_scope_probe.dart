// ignore_for_file: avoid_print
// 第 121 轮（Android UI 审计）：只读核对 `SYNO.FileStation.Search` 的
// `folder_path` 语义 —— 证明"全局文件搜索搜不到"是真缺陷还是服务端空集。
//
// 只用 list / Search.start+stop+clean（搜索任务本身不改任何用户数据）。
// 用法：
//   SYNO_NAS_URL=https://nas.example.com:5001 SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/r121_search_scope_probe.dart
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final url = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_ACCOUNT']!;
  final password = Platform.environment['SYNO_PASSWORD']!;
  final web = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await web.discover();
  await web.login(account: account, password: password, session: 'FileStation');
  final fs = FileStationApi(web);

  Future<void> probe(String folder, String pattern) async {
    print('\n===== folder_path="$folder" pattern="$pattern"');
    try {
      final start = await fs.startSearch(folderPath: folder, pattern: pattern);
      print('  start.taskId=${start.taskId}');
      var n = 0;
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final res = await fs.searchResults(taskId: start.taskId, limit: 500);
        n = res.entries.length;
        if (n > 0) break;
      }
      print('  命中 $n 条');
      for (final e in (await fs.searchResults(taskId: start.taskId, limit: 5))
          .entries) {
        print('    ${e.path}');
      }
      await fs.stopSearch(start.taskId);
      await fs.cleanSearch(start.taskId);
    } catch (e) {
      print('  失败：$e');
    }
  }

  /// 直接打裸响应：`Search:start` + `Search:list` 逐版本，看服务端到底回什么。
  Future<void> raw(String folder, String pattern) async {
    print('\n##### RAW folder="$folder" pattern="$pattern"');
    for (final v in const [1, 2]) {
      try {
        final data = await web.call(
          'SYNO.FileStation.Search',
          'start',
          preferredVersion: v,
          params: {'folder_path': folder, 'pattern': pattern},
        );
        final taskId = (data['taskid'] ?? data['task_id'] ?? '').toString();
        print('  v$v start → $data');
        await Future<void>.delayed(const Duration(seconds: 2));
        final list = await web.call(
          'SYNO.FileStation.Search',
          'list',
          preferredVersion: v,
          params: {'taskid': taskId, 'limit': 100, 'offset': 0},
        );
        print('  v$v list  → total=${list['total']} files=${(list['files'] as List?)?.length} finished=${list['finished']}');
        if ((list['files'] as List?)?.isNotEmpty ?? false) {
          for (final f in (list['files'] as List).take(3)) {
            print('     ${(f as Map)['path']}');
          }
        }
        await web.call('SYNO.FileStation.Search', 'stop',
            preferredVersion: v, params: {'taskid': taskId});
        await web.call('SYNO.FileStation.Search', 'clean',
            preferredVersion: v, params: {'taskid': taskId});
      } catch (e) {
        print('  v$v 失败：$e');
      }
    }
  }

  // 先证明 /home 下确实有 mp4（list 只读）
  try {
    final shares = await fs.listShares();
    print('共享文件夹：${shares.entries.map((e) => e.name).join(', ')}');
  } catch (e) {
    print('listShares 失败：$e');
  }
  try {
    final home = await fs.listFolder(folderPath: '/home');
    print('/home 下 ${home.entries.length} 项：'
        '${home.entries.map((e) => e.name).join(', ')}');
    final video = await fs.listFolder(folderPath: '/home/Video');
    print('/home/Video 下 ${video.entries.length} 项：'
        '${video.entries.take(6).map((e) => e.name).join(', ')}');
  } catch (e) {
    print('/home 列举失败：$e');
  }

  await probe('/home', 'Books');
  await probe('/home', 'Video');
  await probe('/', 'home');
  await probe('/', 'home*');
  await probe('/home', '01_1');
  await raw('/home', 'Video');
}
