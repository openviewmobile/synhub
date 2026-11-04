// ★★★ 第 129 轮 / ④笔记**结项**：Mock/目录覆盖把笔记的**全部 API** 兜住
// （含管理员专属），并钉死"官方 APK 清单 ⊆ 我方目录"。
//
// 事实来源：`tool/mock_dsm/catalog.json`（由反编译 SPK `webapi/*.lib` 生成，
// 权威 JSON：逐版本 methods / authLevel / allowUser / adminOnly）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 官方 `DSnote.apk` **dex 里逐字出现**的 `SYNO.NoteStation*` 串（共 18 个）。
///
/// ⚠️ 242 轮**更正**：本表原先（129 轮）混入了官方**服务端 `.lib`** 的 API
/// （`Export.*` / `Import.*` / `FTS` / `Note.AppLink` / `Note.AppTask` /
/// `Notebook.Polling` / `Notebook.Preset`）—— 它们在 APK 全包 3818 个条目里
/// **0 处出现**。还原命令（可复现）：
/// ```
/// unzip -p ~/synology_samples/apk/DSnote.apk 'classes*.dex' | strings \
///   | grep -oE "SYNO\.NoteStation[.A-Za-z0-9]*" | sort -u
/// ```
/// 服务端 34 条 `.lib` 的对照在 `note_official_api_parity_test.dart`。
const _officialApkPrefixes = <String>[
  'SYNO.NoteStation.Info',
  'SYNO.NoteStation.Note',
  'SYNO.NoteStation.Note.Encrypt',
  'SYNO.NoteStation.Note.Ghost',
  'SYNO.NoteStation.Note.Polling',
  'SYNO.NoteStation.Note.Version',
  'SYNO.NoteStation.Notebook',
  'SYNO.NoteStation.Permission',
  'SYNO.NoteStation.Permission.Group',
  'SYNO.NoteStation.Permission.Public',
  'SYNO.NoteStation.Permission.User',
  'SYNO.NoteStation.Setting',
  'SYNO.NoteStation.Shard.Link',
  'SYNO.NoteStation.Share.Priv',
  'SYNO.NoteStation.Shortcut',
  'SYNO.NoteStation.Smart',
  'SYNO.NoteStation.Tag',
  'SYNO.NoteStation.Todo',
];
void main() {
  final catalog = jsonDecode(
    File('tool/mock_dsm/catalog.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final apis = (catalog['apis'] as Map).cast<String, dynamic>();
  final noteApis = apis.keys.where((k) => k.startsWith('SYNO.NoteStation')).toList()
    ..sort();

  test('★ 官方 APK dex 的 18 个前缀，我方目录一个不少（允许超集）', () {
    final missing = _officialApkPrefixes.where((p) => !apis.containsKey(p)).toList();
    expect(missing, isEmpty, reason: '官方有而我们没有 ⇒ 缺口：$missing');
    expect(noteApis.length, greaterThanOrEqualTo(_officialApkPrefixes.length));
  });

  test('★ 每个笔记 API 都有方法表 + methodsVerified（Mock 能兜住）', () {
    final bad = <String>[];
    for (final k in noteApis) {
      final e = apis[k] as Map;
      final methods = e['methods'];
      final empty = methods is! Map || methods.isEmpty;
      if (empty || e['methodsVerified'] != true) bad.add(k);
    }
    expect(bad, isEmpty, reason: '方法表缺失/未核实的：$bad');
  });

  test('★ 管理员专属笔记 API 都已标 adminOnly（供 Mock 105 门控）', () {
    final adminOnly = noteApis
        .where((k) => (apis[k] as Map)['adminOnly'] == true)
        .toList()
      ..sort();
    expect(adminOnly, ['SYNO.NoteStation.Setting.Global',
        'SYNO.NoteStation.Setting.Volume']);
    for (final k in adminOnly) {
      final e = apis[k] as Map;
      expect(e['normal'], false, reason: '$k 不该对普通用户开放');
      expect(
        (e['allowUser'] as List).every((u) => '$u'.startsWith('admin.')),
        isTrue,
        reason: '$k 的 allowUser 必须只有 admin.*',
      );
    }
  });

  test('★ 版本区间自洽（minVersion ≤ maxVersion，版本号都在 methods 里）', () {
    for (final k in noteApis) {
      final e = apis[k] as Map;
      final min = e['minVersion'] as int;
      final max = e['maxVersion'] as int;
      expect(min, lessThanOrEqualTo(max), reason: k);
      final versions = (e['methods'] as Map).keys.map((k) => int.parse('$k')).toList();
      expect(versions, contains(min), reason: '$k 的 minVersion 没方法');
      expect(versions.every((v) => v >= min && v <= max), isTrue, reason: k);
    }
  });
}
