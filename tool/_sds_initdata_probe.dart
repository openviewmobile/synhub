// ignore_for_file: avoid_print
// 临时探针（第 252 轮，只读）：把真 NAS 上 DS 桌面初始化数据里的
// `Session` / `AppPrivilege` / `ActionPrivilege` / `ServiceStatus` 四个块
// 的**形状**打出来，用来回答"DSM 桌面按什么决定模块显示"。
// 只调用 get/list（无变更动词）。用完可删。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

void _describe(String label, Object? v) {
  if (v == null) {
    print('  $label: <缺失>');
    return;
  }
  if (v is List) {
    final sample = v.take(6).map((e) => e.toString()).toList();
    print('  $label: List[${v.length}] 例 $sample');
    return;
  }
  if (v is Map) {
    final keys = v.keys.take(14).toList();
    print('  $label: Map[${v.length}] 键例 $keys');
    return;
  }
  print('  $label: ${v.runtimeType} $v');
}

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

  for (final apiName in const [
    'SYNO.Core.Desktop.Initdata',
    'SYNO.Core.Desktop.Defs',
  ]) {
    for (final v in const [1, 2, 3]) {
      try {
        final r = await api.call(
          apiName,
          'get',
          preferredVersion: v,
          params: const {},
        );
        final json = jsonEncode(r);
        print('\n=== $apiName.get v$v 顶层键 ${r.keys.toList()}');
        print('   JSON 长度 ${json.length}；canLaunch 出现 '
            '${'canLaunch'.allMatches(json).length} 次；'
            'hidden 出现 ${'"hidden"'.allMatches(json).length} 次');
        for (final k in const [
          'Session',
          'AppPrivilege',
          'ActionPrivilege',
          'ServiceStatus',
          'Packages',
          'JSConfig',
        ]) {
          _describe(k, r[k]);
        }
        final session = r['Session'];
        if (session is Map) {
          for (final k in const [
            'is_admin',
            'domainUser',
            'ha_safemode',
            'isLogined',
            'standalone',
            'version',
          ]) {
            print('  Session.$k = ${session[k]}');
          }
        }
        final ap = r['ActionPrivilege'];
        if (ap is List) {
          print('  ActionPrivilege 全量(${ap.length}): $ap');
        }
        // 只保存一份样本到 /tmp，便于后续抽查（不写仓库）。
        File('/tmp/sds_${apiName.split('.').last}_v$v.json')
            .writeAsStringSync(json);
        break; // 该 API 第一个可用版本即可
      } catch (e) {
        print('=== $apiName.get v$v !! $e');
      }
    }
  }
  api.transport.close();
  exit(0);
}
