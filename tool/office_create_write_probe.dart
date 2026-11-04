// ignore_for_file: avoid_print
// 第 258 轮真 NAS **写路径**探针：把 Drive/Office「新建」的全部形态
// 用**生产代码**真建一遍，看哪一个真的能成。
//
// 用户 2026-09-26 明确授权：**只允许**在 `/mydrive/__smoke_r258__/` 这个
// 临时目录内写；跑完连目录一起**永久删除**（FileStation deletePermanently）。
// 探针开始/结束都会打印"越界检查"，任何落在别处的文件都要报出来。
//
// 用法（凭据从 /tmp/nas_cred.env 来，不进仓库）：
//   set -a; . /tmp/nas_cred.env; set +a
//   SYNO_NAS_URL=https://nas.example.com:5001 \
//     dart run tool/office_create_write_probe.dart
//
// 为什么要这个探针：第 257 轮所有"新建"形态都只做了 Mock 核实，真 NAS 写
// 一个都没发过 ⇒ **参数形态到底对不对没人知道**。本轮把两种 `parent` 形态
// （`id:<file_id>` = 官方 `getPathId()` vs 人类可读路径）都打一遍，用回包说话。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String kRoot = '/mydrive';
const String kSmoke = '/mydrive/__smoke_r258__';
const String kSmokeFs = '/home/Drive/__smoke_r258__';
const String kPassword = 'smoke-r258-pw';

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
  final fs = FileStationApi(web);
  final office = OfficeApi(web);

  print('\n===== 0) 准备：临时目录 $kSmoke');
  await _ensureSmokeFolder(drive);
  final folderId = (await drive.get(path: kSmoke)).pathId;
  print('  临时目录 file_id = $folderId');
  if (folderId.isEmpty || folderId == 'id:') {
    print('  ✗ 拿不到临时目录 id，中止（不写任何东西）');
    exit(1);
  }

  final rootBefore = await _names(drive, kRoot);
  print('  根目录现有 ${rootBefore.length} 项（用于越界比对）');

  final made = <String>[];

  // ── 空白三类型：`Node:create` + `id:<file_id>`（我方 UI 现状） ─────────
  for (final type in OfficeNodeType.values) {
    await _attempt('Node:create 空白 ${type.value}（parent=id:<file_id>）',
        () async {
      final r = await office.createNode(
        parentId: folderId,
        type: type,
        title: 'r258_blank_${type.value}',
      );
      print('     file_id=${r.fileId} display_path=${r.displayPath}');
      made.add(r.fileId);
    });
  }

  // ── 加密空白（doc）：`encrypt=true` + `password` ──────────────────────
  await _attempt('Node:create 加密 doc（parent=id:<file_id>）', () async {
    final r = await office.createNode(
      parentId: folderId,
      type: OfficeNodeType.doc,
      title: 'r258_enc_doc',
      encrypt: true,
      password: kPassword,
    );
    print('     file_id=${r.fileId} display_path=${r.displayPath}');
    made.add(r.fileId);
  });

  // ── 从模板：三类型 × 两种 parent 形态 ────────────────────────────────
  final templates = await office.templateList();
  print('\n===== 模板库：${templates.length} 套');
  for (final type in OfficeNodeType.values) {
    final t = templates.firstWhere(
      (x) => officeNodeTypeFromObjectId(x.objectId) == type,
      orElse: () => throw StateError('模板库里没有 $type'),
    );
    // 形态 A：**我方现状** —— parent_id 直接给人类可读路径
    await _attempt('Template:make ${type.value}（parent=路径 "$kSmoke"）', () async {
      final r = await office.templateMake(
        parentId: kSmoke,
        objectId: t.objectId,
        title: 'r258_tpl_path_${type.value}',
      );
      print('     object_id=${t.objectId} file_id=${r['file_id']}');
      made.add('${r['file_id']}');
    });
    // 形态 B：**官方形态** —— parent_id 给 `id:<file_id>`
    await _attempt('Template:make ${type.value}（parent=id:<file_id>）', () async {
      final r = await office.templateMake(
        parentId: folderId,
        objectId: t.objectId,
        title: 'r258_tpl_id_${type.value}',
      );
      print('     object_id=${t.objectId} file_id=${r['file_id']}');
      made.add('${r['file_id']}');
    });
  }

  // ── 加密模板（官方 `openTplDialog({encrypt:true})`） ─────────────────
  final docTpl = templates.firstWhere(
    (x) => officeNodeTypeFromObjectId(x.objectId) == OfficeNodeType.doc,
  );
  await _attempt('Template:make 加密 doc（parent=id:<file_id>）', () async {
    final r = await office.templateMake(
      parentId: folderId,
      objectId: docTpl.objectId,
      title: 'r258_tpl_enc_doc',
      encrypt: true,
      password: kPassword,
    );
    print('     object_id=${docTpl.objectId} file_id=${r['file_id']}');
    made.add('${r['file_id']}');
  });

  // ── 结果：临时目录里到底有什么 ───────────────────────────────────────
  print('\n===== 1) 临时目录实际内容（Drive 视角）');
  final inside = await _entries(drive, kSmoke);
  for (final e in inside) {
    print('   ${e.name}  type=${e.fileId.isEmpty ? "?" : e.fileId}');
  }
  print('\n===== 2) 越界检查');
  final rootAfter = await _names(drive, kRoot);
  final leaked = rootAfter.where((n) => !rootBefore.contains(n)).toList();
  print('   根目录新增项：${leaked.isEmpty ? "无 ✓" : leaked}');
  print('   临时目录内 ${inside.length} 项；探针报告已建 id ${made.length} 个');

  // ── 清理：整个临时目录永久删除（用户授权范围内的唯一收尾动作） ────────
  print('\n===== 3) 清理：永久删除 $kSmokeFs');
  try {
    await fs.deletePermanently([kSmokeFs], recursive: true);
    print('   ✓ 已删除');
  } catch (e) {
    print('   ✗ 删除失败：$e  ← 必须人工处理！');
  }
  final left = await _names(drive, kRoot);
  print('   清理后根目录：${left.contains('__smoke_r258__') ? "仍存在 ✗" : "无临时目录 ✓"}');
  print('\n完成。');
}

Future<void> _ensureSmokeFolder(DriveApi drive) async {
  try {
    final e = await drive.get(path: kSmoke);
    print('  已存在（file_id=${e.pathId}）');
  } catch (_) {
    await drive.createFolder(path: kSmoke);
    print('  已创建');
  }
}

Future<List<String>> _names(DriveApi drive, String path) async =>
    (await _entries(drive, path)).map((e) => e.name).toList();

Future<List<DriveEntryDto>> _entries(DriveApi drive, String path) async {
  try {
    final r = await drive.list(path: path, limit: 200);
    return r.items;
  } catch (e) {
    print('  (列目录失败：$e)');
    return const [];
  }
}

Future<void> _attempt(String label, Future<void> Function() run) async {
  print('\n--- $label');
  try {
    await run();
    print('   ✓ 成功');
  } catch (e) {
    final msg = '$e';
    print('   ✗ 失败：${msg.length > 300 ? msg.substring(0, 300) : msg}');
  }
}

// 保留：需要看原始 JSON 时用
String pretty(Object? o) => const JsonEncoder.withIndent('  ').convert(o);
