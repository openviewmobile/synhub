// 手机自动备份 / 批量打标签的**真机接口探针**（活体，需要账号，不进默认测试套件）。
//
// 用途：把我们实现的请求形态与真实 NAS 对一遍，并把服务端**原始回包**打出来
// （调研文档 §1.3/§5 里标注"未核实"的参数/响应，靠它定案）。
//
// 用法：
//   SYNO_NAS_URL=https://nas.example.com:5001 \
//   SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//   dart run tool/photo_backup_probe.dart
//
// 做四件事（都可重跑；结束时清掉自己建的东西）：
//   ① 打印 `SYNO.API.Info` 里 Upload.Item / Browse.GeneralTag / Browse.Item 的版本表；
//   ② 建一个探针目录 → `upload_to_folder` 传一张 1×1 PNG → 列目录确认；
//   ③ 再跑一次去重判定（同名同大小 → skip）；
//   ④ 标签：列出/联想（只读，不建标签以免留垃圾）→ `get_tag` → `add_tag`（用已有标签）。
//
// 清场：删掉探针目录里的照片与目录本身；**标签不做增删**（`GeneralTag` 没有 delete 接口）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const _probeFolder = 'huihub-backup-probe';

/// 1×1 透明 PNG（最小合法图片）
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

Future<void> main() async {
  final url = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_PASSWORD'];
  if (url == null || account == null || password == null) {
    stderr.writeln('需要 SYNO_NAS_URL / SYNO_ACCOUNT / SYNO_PASSWORD');
    exit(2);
  }
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'FileStation');
  final foto = FotoApi(api);

  print('==== ① 能力表');
  for (final name in const [
    'SYNO.Foto.Upload.Item',
    'SYNO.Foto.Browse.GeneralTag',
    'SYNO.Foto.Browse.Item',
  ]) {
    final e = api.apiTable?[name];
    print(
      '  $name → ${e == null ? "未注册" : "v${e.minVersion}-${e.maxVersion}"}',
    );
  }

  print('\n==== ② 上传到探针目录');
  final root = await foto.folderRoot();
  final existing = (await foto.folders()).where((f) => f.name == _probeFolder);
  final folder = existing.isNotEmpty
      ? existing.first
      : await foto.createFolder(parentId: root.id, name: _probeFolder);
  print('  目录 ${folder.id}:${folder.name}（root=${root.id}）');

  final tmp = File(
    '${Directory.systemTemp.path}/huihub-probe-${DateTime.now().millisecondsSinceEpoch}.png',
  )..writeAsBytesSync(_png);
  try {
    final unitId = await foto.uploadToFolder(
      folderId: folder.id,
      filePath: tmp.path,
      fileName: 'huihub-probe.png',
      mtimeMs: DateTime.now().millisecondsSinceEpoch,
      mimeType: 'image/png',
    );
    print('  upload_to_folder → unitId="$unitId"');
    final items = await foto.folderItems(folder.id);
    print(
      '  目录内容：${items.map((e) => "${e.filename}(${e.filesize}B)").join(", ")}',
    );

    print('\n==== ③ 去重（同名同大小 → 应跳过）');
    final remote = [for (final e in items) RemoteEntry(e.filename, e.filesize)];
    final dup = remote.any((r) => r.name == 'huihub-probe.png');
    print('  目标目录里已存在同名？$dup（实现里命中即 skip）');

    print('\n==== ④ 标签（只读 + add_tag）');
    final tags = await foto.generalTags();
    print('  已有标签：${tags.map((e) => "${e.id}:${e.name}").join(", ")}');
    if (tags.isEmpty) {
      print('  没有标签 → 跳过 add_tag（GeneralTag 无 delete，不建垃圾）');
    } else if (items.isNotEmpty) {
      final before = await foto.itemTagIds([items.first.id]);
      print('  加之前 intersection=$before');
      final failed = await foto.addTags(
        itemIds: [items.first.id],
        tagIds: [tags.first.id],
      );
      print('  add_tag error_list=$failed');
      final after = await foto.itemTagIds([items.first.id]);
      print('  加之后 intersection=$after');
    }

    print('\n==== 清场');
    for (final e in await foto.folderItems(folder.id)) {
      final r = await api.call(
        'SYNO.Foto.Browse.Item',
        'delete',
        preferredVersion: 7,
        params: {'id': '[${e.id}]'},
      );
      print('  删照片 ${e.id}:${e.filename} → $r');
    }
    print(
      '  删目录 → ${await api.call('SYNO.Foto.Browse.Folder', 'delete', preferredVersion: 5, params: {'id': '[${folder.id}]'})}',
    );
  } finally {
    tmp.deleteSync();
  }
}

/// 只为本探针的最小去重视图
class RemoteEntry {
  const RemoteEntry(this.name, this.size);
  final String name;
  final int size;
}
