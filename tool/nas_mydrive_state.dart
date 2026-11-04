// ignore_for_file: avoid_print
// 真 NAS **只读**状态核对工具（第 258 轮新增）。
//
// 用途：写探针（`office_create_write_probe.dart`）跑完之后，用**全新会话**
// 复核"该清的清了、该在的还在"。写探针收尾那次 list 常常拿到的是
// **陈旧列表**（第 258 轮实测：删完仍打印"仍存在 ✗"），所以复核必须重新登录、
// 重新列一次 —— 这就是本工具存在的理由。
//
// 只发 `list`/`get`，**零变更动词**。用法：
//   set -a; . /tmp/nas_cred.env; set +a
//   SYNO_NAS_URL=https://nas.example.com:5001 \
//     SYNO_ACCOUNT=$NAS_ACCOUNT SYNO_PASSWORD=$NAS_PASSWORD \
//     dart run tool/nas_mydrive_state.dart
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String kRoot = '/mydrive';
const String kSmoke = '/mydrive/__smoke_r258__';

Future<void> main() async {
  final web = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await web.discover();
  await web.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'FileStation',
  );
  final drive = DriveApi(web);

  final root = await drive.list(path: kRoot);
  print('\n===== /mydrive 根目录：${root.items.length} 项');
  for (final e in root.items) {
    print('   ${e.name}  isDir=${e.isDir}  size=${e.size ?? '-'}');
  }
  final leaked = root.items.where((e) => e.name == '__smoke_r258__').toList();
  print(leaked.isEmpty
      ? '   越界检查：无 __smoke_r258__ ✓'
      : '   越界检查：仍有 __smoke_r258__ ✗');

  try {
    final inside = await drive.list(path: kSmoke);
    print('   临时目录可读，仍有 ${inside.items.length} 项 ✗（应当已不存在）');
  } catch (e) {
    print('   临时目录不可读（= 已删除 ✓）：${'$e'.split('\n').first}');
  }

  print('\n===== 回收站');
  // FileStation 会话常因"密码已过期"被拒（408），回收站改从 Drive 侧看更稳
  try {
    final trash = await drive.list(path: '/mydrive/#recycle');
    print('   （Drive 视角）回收站：${trash.items.length} 项');
    for (final f in trash.items) {
      print('   ${f.name}');
    }
  } catch (e) {
    print('   回收站读取失败：${'$e'.split('\n').first}');
  }
  print('\n完成（全程只读）。');
}
