// Drive P3 全链路取证：版本（upload 两次 → list → restore）+ 共享链接（create_link → list）。
// 形态依据 Drive Server 自带 Web 客户端的 `SYNO.SDS.Drive.WebAPIDesc`
// （/tmp/spk/export_SynologyDrive/drive/synodrive_common.js）：
//   Revisions/list v1 · Revisions/restore v1 · Sharing/create_link v1 · Sharing/list v1
//   Files/upload_from_dsm v2 {path, dsm_paths, conflict_action:"version"}
// 跑完清场（删文件 + 清空回收站 + FileStation 兜底）。
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

  Future<Object?> upload() =>
      t('SYNO.SynologyDrive.Files', 'upload_from_dsm', 2, {
        'path': '/mydrive',
        'dsm_paths': jsonEncode(['/home/l1.png']),
        'conflict_action': '"version"',
      });

  for (final p in ['/home/Drive/l1.png', '/home/Drive/probe-cal.png']) {
    try {
      await flt.deleteItems([p]);
    } catch (_) {}
  }

  print('① 同一文件传两次（第二次 conflict_action=version → 多一个版本）');
  print('   1st → ${await upload()}');
  await Future<void>.delayed(const Duration(seconds: 4));
  print('   2nd → ${await upload()}');
  var listing = await drive.list(path: kDriveRoot);
  for (var i = 0; i < 20 && listing.items.isEmpty; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    listing = await drive.list(path: kDriveRoot);
  }
  print('   Tasks/list → ${await t('SYNO.SynologyDrive.Tasks', 'list', 1)}');
  print(
    '   /mydrive: ${[for (final e in listing.items) '${e.fileId}:${e.name} ${e.name}'].join(", ")}',
  );
  if (listing.items.isEmpty) {
    print('   空，退出');
    await api.logout();
    exit(1);
  }
  final id = listing.items.first.fileId;

  print('② Revisions/list v1 {path:id:$id}');
  final revs = await t('SYNO.SynologyDrive.Revisions', 'list', 1, {
    'path': 'id:$id',
  });
  print('   $revs');
  final ids = <String>[];
  if (revs is Map && revs['items'] is List) {
    for (final it in revs['items'] as List) {
      ids.add('${(it as Map)['version_id']}');
    }
  }
  print('   版本号：$ids');

  if (ids.length >= 2) {
    print('③ Revisions/restore v1 {path:id, version_id:${ids.last}}');
    print(
      '   裸串 → ${await t('SYNO.SynologyDrive.Revisions', 'restore', 1, {'path': 'id:$id', 'version_id': ids.last})}',
    );
    print(
      '   引号串 → ${await t('SYNO.SynologyDrive.Revisions', 'restore', 1, {'path': 'id:$id', 'version_id': '"${ids.last}"'})}',
    );
    print(
      '   restore 后再 list → ${await t('SYNO.SynologyDrive.Revisions', 'list', 1, {'path': 'id:$id'})}',
    );
  }

  print('④ 共享链接：create_link → Sharing/list');
  final link = await t('SYNO.SynologyDrive.Sharing', 'create_link', 1, {
    'path': 'id:$id',
  });
  print('   create_link v1 {path:id} → $link');
  print(
    '   Sharing/list v1 {path:id} → ${await t('SYNO.SynologyDrive.Sharing', 'list', 1, {'path': 'id:$id'})}',
  );
  print(
    '   Shares/list_active? → ${await t('SYNO.SynologyDrive.Sharing', 'list_active', 1)}',
  );
  print('⑤ Files/get 看 shared/permanent_link');
  final got = await t('SYNO.SynologyDrive.Files', 'get', 3, {'path': 'id:$id'});
  if (got is Map) {
    print(
      '   shared=${got['shared']} permanent_link=${got['permanent_link']} '
      'adv_shared=${got['adv_shared']} shared_with=${got['shared_with']} '
      'revisions=${got['revisions']} version_id=${got['version_id']}',
    );
  } else {
    print('   $got');
  }

  print('⑥ 清场');
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
  listing = await drive.list(path: kDriveRoot);
  print(
    '   /mydrive 条目 ${listing.items.length} · '
    '/home/Drive 条目 ${(await flt.listFolder(folderPath: '/home/Drive')).entries.length}',
  );
  await api.logout();
  exit(0);
}
