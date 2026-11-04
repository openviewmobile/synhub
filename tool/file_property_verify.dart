// 文件属性扩展（MD5 / Property.*）的真机验证脚本 —— 属性面板的**服务端口径**。
//
// 用法：
//   SYNO_NAS_URL=https://<host>:<port> SYNO_ACCOUNT=<u> SYNO_PASSWORD=<p> \
//     dart run tool/file_property_verify.dart [/home/l1.png]
//
// 它同时是"这台 NAS 上的事实说明书"：
//   * Property.CompressSize / Mtime / ACLOwner 只认 **real_path**（/volume1/...），
//     传 FileStation 虚拟路径（/home/...）分别回 401 / 401 / 407；
//   * 真机回包里 `diskSize` / `mtime` 是**字符串数字**（"1916928"）；
//   * `SYNO.FileStation.MD5` 的任务**存活窗口只有几十毫秒**：
//     `start` 之后 0/25ms 查得到，50ms 起稳定 599（任务已被回收）。
//     所以客户端只能"start → 立刻 status"，慢了就整对重来；官方 Web 端那种
//     每秒轮询在这台机器上永远拿不到结果。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> argv) async {
  final target = argv.isEmpty ? '/home/l1.png' : argv.first;
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
  final fs = FileStationApi(api);

  for (final name in const [
    'SYNO.FileStation.MD5',
    'SYNO.FileStation.Property.CompressSize',
    'SYNO.FileStation.Property.Mtime',
    'SYNO.FileStation.Property.ACLOwner',
  ]) {
    print('能力表 $name：${api.apiTable?.containsKey(name) == true}');
  }

  final entry = await fs.getInfo(target);
  final real = entry.realPath ?? '';
  print('\n样本 $target');
  print('  real_path      = $real');
  print('  size(列表)     = ${entry.size}');
  print('  compressSize   = ${await fs.compressSize(real)}');
  print('  mtime          = ${await fs.mtimeOf(real)}');
  final owner = await fs.aclOwner(real);
  print('  ACLOwner       = ${owner.label} hasPrivilege=${owner.hasPrivilege}');

  // MD5：镜像 App 的做法（start → 立刻 status，最多 4 轮）
  print('\nMD5（start → 立刻 status）');
  for (var round = 0; round < 4; round++) {
    final id = await fs.startMd5([target]);
    for (final delay in const [0, 0, 0, 5, 10, 20]) {
      if (delay > 0) {
        await Future<void>.delayed(Duration(milliseconds: delay));
      }
      try {
        final st = await fs.md5Status(id);
        if (st.finished && st.md5.isNotEmpty) {
          print('  第 $round 轮 / ${delay}ms → ${st.md5}');
          return;
        }
        if (st.failed) {
          print('  第 $round 轮 / ${delay}ms → 服务端说算不了');
          return;
        }
      } catch (e) {
        if (round == 0 && delay == 0) print('  第一次 status：$e');
        break;
      }
    }
    await fs.stopMd5(id).catchError((_) {});
  }
  print('  服务端没保住结果（任务存活窗口过短）');
}
