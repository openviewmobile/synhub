// 探 NAS 上有没有 AI 相关能力（AI Console 包 / SYNO.AI.* / 第三方 LLM 入口）。
// ignore_for_file: avoid_print
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
  final table = api.apiTable ?? const {};
  print('== 表里带 AI / Chatbot / LLM 的 API ==');
  for (final k in table.keys) {
    final lk = k.toLowerCase();
    if (lk.contains('ai') ||
        lk.contains('chatbot') ||
        lk.contains('llm') ||
        lk.contains('generat') ||
        lk.contains('openai') ||
        lk.contains('assist')) {
      final e = table[k]!;
      print('   $k  path=${e.path} minV=${e.minVersion} maxV=${e.maxVersion}');
    }
  }
  print('== 已安装的包 ==');
  try {
    final pkgs = await api.call(
      'SYNO.Core.Package',
      'list',
      preferredVersion: 2,
    );
    final items = (pkgs['packages'] ?? pkgs['data'] ?? const []) as List;
    for (final p in items) {
      final m = (p as Map).cast<String, dynamic>();
      final id = '${m['id']}';
      print('   ${id.padRight(28)} ${m['version']}  ${m['name']}');
    }
  } catch (e) {
    print('   包列表失败：$e');
  }
  await api.logout();
  exit(0);
}
