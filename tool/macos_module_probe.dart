// ignore_for_file: avoid_print
// macOS 走查（第 63 轮）的**只读**导航/载荷探针：为桌面端逐模块走查确定
// 「从 UI 哪里点进去、点进去应该看到什么」。只发 list/get，**零变更动词**。
//
// 用法：
//   SYNO_NAS_URL=https://nas.example.com:5001 SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/macos_module_probe.dart
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> _try(String label, Future<void> Function() body) async {
  try {
    await body();
  } catch (e) {
    print('   ✗ $label：${'$e'.split('\n').first}');
  }
}

Future<void> main() async {
  final url = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_PASSWORD'];
  if (url == null || account == null || password == null) {
    print('需要 SYNO_NAS_URL / SYNO_ACCOUNT / SYNO_PASSWORD');
    exit(2);
  }
  final web = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await web.discover();
  await web.login(account: account, password: password, session: 'Chat');
  final fs = FileStationApi(web);
  final drive = DriveApi(web);
  final chat = ChatApi(web);

  await _try('listShares', () async {
    final shares = await fs.listShares(limit: 100);
    print('=== ① FS 根（list_share）：${shares.entries.length} 项');
    for (final e in shares.entries) {
      print('   ${e.name}  dir=${e.isDir} rw=${e.canWrite}');
    }
  });

  for (final path in ['/home', '/home/Drive', '/home/Music', '/home/Video']) {
    await _try('list $path', () async {
      final r = await fs.listFolder(folderPath: path, limit: 100);
      print('=== FS list $path：${r.entries.length} 项');
      for (final e in r.entries.take(14)) {
        print('   ${e.name}  dir=${e.isDir} size=${e.size}');
      }
    });
  }

  await _try('drive /mydrive', () async {
    final r = await drive.list(path: '/mydrive');
    print('=== Drive /mydrive：${r.items.length} 项');
    for (final e in r.items) {
      print('   ${e.name}  dir=${e.isDir}');
    }
  });

  await _try('chat channels', () async {
    final ch = await chat.listChannels();
    print('=== Chat 频道：${ch.length} 个');
    for (final c in ch.take(10)) {
      print('   #${c.channelId} ${c.name}');
    }
  });

  web.transport.close();
  exit(0);
}
