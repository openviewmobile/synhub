// ignore_for_file: avoid_print
// 专项探针：`additional` 到底该怎么传（决定目录列表里有没有 size/time/owner/real_path）。
import 'dart:convert';
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'FileStation',
  );

  Future<void> show(String label, Map<String, dynamic> params) async {
    try {
      final r = await api.call(
        'SYNO.FileStation.List',
        'list',
        preferredVersion: 2,
        params: {'folder_path': '/docker', ...params},
      );
      final files = (r['files'] as List?) ?? const [];
      print('--- $label → ${files.length} 项');
      print('    raw[0] = ${jsonEncode(files.first)}');
    } catch (e) {
      print('--- $label → !! $e');
    }
  }

  await show('附加参数重复字段(当前实现)', {
    'additional': const ['size', 'time', 'owner', 'real_path', 'perm'],
  });
  await show('附加参数 JSON 字符串', {
    'additional': jsonEncode(['size', 'time', 'owner', 'real_path', 'perm']),
  });
  await show('附加参数 JSON 字符串(仅 time/size)', {
    'additional': jsonEncode(['time', 'size']),
  });
  await show('不带附加参数', const {});

  try {
    final r = await api.call(
      'SYNO.FileStation.List',
      'getinfo',
      preferredVersion: 2,
      params: {
        'path': '/docker',
        'additional': const ['real_path', 'time', 'owner', 'size'],
      },
    );
    print('--- getinfo raw = ${jsonEncode(r)}');
  } catch (e) {
    print('--- getinfo !! $e');
  }

  // CheckPermission.write 的 path 形态
  for (final p in const ['/docker', '["/docker"]']) {
    try {
      final r = await api.call(
        'SYNO.FileStation.CheckPermission',
        'write',
        preferredVersion: 3,
        params: {'path': p},
      );
      print('--- checkPermission(path=$p) = ${jsonEncode(r)}');
    } catch (e) {
      print('--- checkPermission(path=$p) !! $e');
    }
  }

  // VirtualFolder.list
  try {
    final r = await api.call(
      'SYNO.FileStation.VirtualFolder',
      'list',
      preferredVersion: 2,
      params: {'offset': 0, 'limit': 100},
    );
    print('--- virtualFolder.list = ${jsonEncode(r)}');
  } catch (e) {
    print('--- virtualFolder.list !! $e');
  }
  try {
    final r = await api.call(
      'SYNO.FileStation.VirtualFolder',
      'list',
      preferredVersion: 1,
      params: {'offset': 0, 'limit': 100},
    );
    print('--- virtualFolder.list v1 = ${jsonEncode(r)}');
  } catch (e) {
    print('--- virtualFolder.list v1 !! $e');
  }

  // VirtualFolder 到底认哪些参数
  for (final params in const [
    {'offset': 0, 'limit': 100},
    {'type': 'all', 'offset': 0, 'limit': 100},
    {'offset': 0, 'limit': 100, 'sort_by': 'name', 'sort_direction': 'asc'},
    {'offset': 0, 'limit': 100, 'additional': '["real_path","time"]'},
  ]) {
    try {
      final r = await api.call(
        'SYNO.FileStation.VirtualFolder',
        'list',
        preferredVersion: 2,
        params: params,
      );
      print('--- vf ${jsonEncode(params)} = ${jsonEncode(r)}');
    } catch (e) {
      print('--- vf ${jsonEncode(params)} !! $e');
    }
  }

  // CheckPermission 对一个确实可写的目录（/home 在 list_share 里 canWrite=true）
  for (final path in const ['/home', '/home/demo_user']) {
    try {
      final r = await api.call(
        'SYNO.FileStation.CheckPermission',
        'write',
        preferredVersion: 3,
        params: {'path': path, 'filename': 'flt-probe.tmp'},
      );
      print('--- checkPermission($path) = ${jsonEncode(r)}');
    } catch (e) {
      print('--- checkPermission($path) !! $e');
    }
  }

  api.transport.close();
  exit(0);
}
