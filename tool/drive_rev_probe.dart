// 版本历史 / 共享链接 参数取证（Shape 取自 Drive Server 自带 Web 客户端的
// `SYNO.SDS.Drive.WebAPIDesc`，`/tmp/spk/export_SynologyDrive/drive/synodrive_common.js`）：
//   list_revisions      SYNO.SynologyDrive.Revisions/list      v1
//   restore_revisions   SYNO.SynologyDrive.Revisions/restore   v1
//   list_office_revisions  SYNO.Office.Node.Version/list       v1
//   get_file_link       SYNO.SynologyDrive.Sharing/create_link v1
//   list_app_priv       SYNO.SynologyDrive.Share.Priv/list     v1
//   list_label_files    SYNO.SynologyDrive.Files/list_labelled v2
//   upload_files_from_nas  SYNO.SynologyDrive.Files/upload_from_dsm v2
//     params {path, dsm_paths, conflict_action:"version"}
// 为了有个真文件：用 `upload_from_dsm` 把 `/home/l1.png` 传进 Drive（服务端自己拷，
// 这样 Drive 的索引里也有），探完删掉 + 清空回收站 + 用 FileStation 收尾。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/filestation_api.dart';
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
  final flt = FileStationApi(api);
  final drive = DriveApi(api);

  Future<Object?> t(
    String a,
    String m,
    int v, [
    Map<String, dynamic> p = const {},
  ]) async {
    try {
      return await api.call(a, m, preferredVersion: v, params: p);
    } catch (e) {
      return e;
    }
  }

  // 收尾掉上一轮 FileStation 直接拷进去的残留（Drive 索引看不到它）
  for (final p in ['/home/Drive/l1.png', '/home/Drive/probe-cal.png']) {
    try {
      await flt.deleteItems([p]);
    } catch (_) {}
  }

  print('⓪ upload_from_dsm：/home/l1.png → /mydrive');
  final up = await t('SYNO.SynologyDrive.Files', 'upload_from_dsm', 2, {
    'path': '/mydrive',
    'dsm_paths': jsonEncode(['/home/l1.png']),
    'conflict_action': '"version"',
  });
  print('   → $up');
  await Future<void>.delayed(const Duration(seconds: 4));

  final listing = await drive.list(path: kDriveRoot);
  print(
    '   /mydrive 条目 ${listing.items.length}: '
    '${[for (final e in listing.items) '${e.fileId}:${e.name}'].join(", ")}',
  );
  if (listing.items.isEmpty) {
    print('   Drive 里还是空，退出');
    await api.logout();
    exit(1);
  }
  final id = listing.items.first.fileId;

  print('① Files/get（共享/版本相关字段）');
  final got = await t('SYNO.SynologyDrive.Files', 'get', 3, {'path': 'id:$id'});
  print('   ${'$got'.length > 1200 ? '${'$got'.substring(0, 1200)}…' : got}');

  print('② Revisions/list');
  for (final v in [1, 2]) {
    print(
      '   v$v {path:id} → ${await t('SYNO.SynologyDrive.Revisions', 'list', v, {'path': 'id:$id'})}',
    );
  }
  print(
    '   v1 {path:id,offset,limit} → ${await t('SYNO.SynologyDrive.Revisions', 'list', 1, {'path': 'id:$id', 'offset': '0', 'limit': '30'})}',
  );
  print(
    '   v1 {path:"id:$id"} → ${await t('SYNO.SynologyDrive.Revisions', 'list', 1, {'path': '"id:$id"'})}',
  );

  print('③ Office 版本（对 png 应是空/报错，仅记录形态）');
  print(
    '   → ${await t('SYNO.Office.Node.Version', 'list', 1, {'path': 'id:$id'})}',
  );

  print('④ Sharing/list + Share/list + create_link');
  for (final v in [1, 2]) {
    print(
      '   Sharing/list v$v {path:id} → ${await t('SYNO.SynologyDrive.Sharing', 'list', v, {'path': 'id:$id'})}',
    );
  }
  print(
    '   Sharing/list v1 {path:"id:$id"} → ${await t('SYNO.SynologyDrive.Sharing', 'list', 1, {'path': '"id:$id"'})}',
  );
  print(
    '   Sharing/list v1 {} → ${await t('SYNO.SynologyDrive.Sharing', 'list', 1)}',
  );
  print(
    '   Share/list v1 {} → ${await t('SYNO.SynologyDrive.Share', 'list', 1)}',
  );
  final link = await t('SYNO.SynologyDrive.Sharing', 'create_link', 1, {
    'path': 'id:$id',
  });
  print('   Sharing/create_link v1 {path:id} → $link');

  // 清场
  print('⑤ 清场');
  if (link is Map && link['link'] != null) {
    // 共享链接留在文件上没意义：删文件即可
  }
  try {
    await drive.delete(fileIds: [id]);
    await Future<void>.delayed(const Duration(seconds: 3));
    await drive.emptyTrash();
    await Future<void>.delayed(const Duration(seconds: 2));
  } catch (e) {
    print('   Drive 清场失败：$e');
  }
  for (final p in ['/home/Drive/l1.png', '/home/Drive/probe-cal.png']) {
    try {
      await flt.deleteItems([p]);
    } catch (_) {}
  }
  print('   /mydrive 条目 ${(await drive.list(path: kDriveRoot)).items.length}');
  print(
    '   /home/Drive 条目 ${(await flt.listFolder(folderPath: '/home/Drive')).entries.length}',
  );
  await api.logout();
  exit(0);
}
