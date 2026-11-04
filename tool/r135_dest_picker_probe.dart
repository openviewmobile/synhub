// ignore_for_file: avoid_print
// 第 135 轮：只读定位「复制/移动 → 目标目录选择器」在真机上空列表的根因。
//
// 真机像素：`Copy to...` 在 `/home` 与 `Root` 都是**只有当前路径行、没有任何目录**，
// 而同一个 build 的 Files 页在 `/home` 明明列出 10 个目录。
// 选择器是 `FileDestinationPickerPage._load()`：`result.entries.where((e) => e.isDir)`。
//
// 本探针只做 `SYNO.FileStation.List / list` 与 `list_share`（**纯读**，不改任何数据），
// 逐一分离两个候选根因：
//   ① `limit: 1000`（选择器传 1000，Files 页传 pageSize）→ 服务端回空集？
//   ② `additional` 不含 `type` → 回包里没有 `isdir` → `isDir` 全 false？
//
// 用法：
//   SYNO_NAS_URL=https://nas.example.com:5001 SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/r135_dest_picker_probe.dart
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
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

  // 裸调一次，把**回包第一项的键**打出来 —— 有没有 `isdir` 一眼可见。
  Future<void> raw(String method, Map<String, Object?> params) async {
    try {
      final data = await web.call(
        'SYNO.FileStation.List',
        method,
        preferredVersion: 2,
        params: params,
      );
      final map = data as Map<String, Object?>;
      final files = (map['files'] as List?) ?? const [];
      print('    raw: total=${map['total']} files=${files.length}');
      if (files.isNotEmpty) {
        final first = files.first as Map<String, Object?>;
        print('    raw: first keys=${first.keys.toList()}');
        print('    raw: first isdir=${first['isdir']} path=${first['path']}');
      }
    } catch (e) {
      print('    raw: 失败 $e');
    }
  }

  Future<void> probe(
    String label,
    int limit,
    List<String> additional,
  ) async {
    print('\n===== $label (limit=$limit, additional=$additional)');
    try {
      final r = await fs.listFolder(
        folderPath: '/home',
        limit: limit,
        additional: additional,
      );
      final dirs = r.entries.where((e) => e.isDir).length;
      print('    listFolder: entries=${r.entries.length} 其中 isDir=$dirs');
    } catch (e) {
      print('    listFolder: 失败 $e');
    }
  }

  print('### A. limit 是否是根因（additional 用默认 browse）');
  await probe('A1 默认 limit=0', 0, FileAdditional.browse);
  await probe('A2 Files 页量级 limit=200', 200, FileAdditional.browse);
  await probe('A3 选择器 limit=1000', 1000, FileAdditional.browse);

  print('\n### B. additional 不含 type 是否是根因（limit 固定 0）');
  await probe('B1 browse（当前默认）', 0, FileAdditional.browse);
  await probe('B2 browse + type', 0, [...FileAdditional.browse, 'type']);

  print('\n### C. 裸回包：第一项到底有哪些键');
  await raw('list', {
    'folder_path': '/home',
    'additional': jsonEncode(FileAdditional.browse),
    'offset': 0,
    'limit': 0,
    'sort_by': 'name',
    'sort_direction': 'asc',
    'filetype': 'all',
  });
  await raw('list', {
    'folder_path': '/home',
    'additional': jsonEncode([...FileAdditional.browse, 'type']),
    'offset': 0,
    'limit': 0,
    'sort_by': 'name',
    'sort_direction': 'asc',
    'filetype': 'all',
  });

  print('\n### D. 根的 list_share（选择器在 Root 走这条路）');
  try {
    final r = await fs.listShares(limit: 1000);
    print('    listShares(limit=1000): entries=${r.entries.length} '
        '其中 isDir=${r.entries.where((e) => e.isDir).length}');
  } catch (e) {
    print('    listShares(limit=1000): 失败 $e');
  }
  try {
    final r = await fs.listShares(limit: 0);
    print('    listShares(limit=0): entries=${r.entries.length} '
        '其中 isDir=${r.entries.where((e) => e.isDir).length}');
  } catch (e) {
    print('    listShares(limit=0): 失败 $e');
  }
  await raw('list_share', {
    'additional': jsonEncode(['perm', 'worm_share']),
    'offset': 0,
    'limit': 1000,
  });

  print('\n完成（只读：list / list_share，未调用任何变更动词）');
}
