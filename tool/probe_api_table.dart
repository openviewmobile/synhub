// 打印真实 NAS 的 `SYNO.Chat.*` API 版本表（Phase 4/6 的版本协商依据）。
//
// 用法：
//   SYNO_NAS_URL=… SYNO_NAS_ACCOUNT=… SYNO_NAS_PASSWORD=… \
//     dart run tool/probe_api_table.dart
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

// ignore_for_file: avoid_print

void main() async {
  final url = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password = Platform.environment['SYNO_NAS_PASSWORD']!;

  final api = DsmWebApi(DirectTransport.url(url, dio: DioFactory.create()));
  await api.discover();
  await api.login(account: account, password: password, session: 'Chat');

  final table = api.apiTable ?? const {};

  // 落成 fixture：离线测试可以拿"真实版本表"来校验版本协商
  final dump = <String, Map<String, Object?>>{
    for (final e in table.entries)
      e.key: {
        'path': e.value.path,
        'minVersion': e.value.minVersion,
        'maxVersion': e.value.maxVersion,
      },
  };
  File(
    'test/fixtures/api_table.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(dump));
  print('已写入 test/fixtures/api_table.json（${dump.length} 个 API）');

  print('=== SYNO.Chat.* / 相关 API 的版本范围 ===');
  final rows = <List<String>>[];
  for (final entry in table.entries) {
    if (!entry.key.startsWith('SYNO.Chat')) continue;
    rows.add([
      entry.key,
      '${entry.value.minVersion}',
      '${entry.value.maxVersion}',
    ]);
  }
  rows.sort((a, b) => a[0].compareTo(b[0]));
  for (final r in rows) {
    print('${r[0].padRight(38)} v${r[1]}..v${r[2]}');
  }

  print('');
  print('=== 我们关心的方法候选版本 vs 服务器支持 ===');
  const probes = <String, List<int>>{
    'SYNO.Chat.Post': [8, 4, 1],
    'SYNO.Chat.Post.Reaction': [1],
    'SYNO.Chat.Post.Subscribe': [2, 1],
    'SYNO.Chat.Post.Hashtag': [1],
    'SYNO.Chat.Post.Vote': [1],
    'SYNO.Chat.Post.Schedule': [1],
    'SYNO.Chat.Channel': [5, 2, 1],
  };
  for (final p in probes.entries) {
    final info = table[p.key];
    final candidates = p.value;
    final picked = info == null
        ? -1
        : candidates.firstWhere(
            (v) => v <= info.maxVersion,
            orElse: () => info.minVersion,
          );
    print(
      '${p.key.padRight(38)} 服务器上限='
      '${info?.maxVersion ?? '-'}  我们会用=$picked',
    );
  }
}
