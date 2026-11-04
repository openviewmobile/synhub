// ★★★ ④笔记 第 242 轮**结项**：与官方**两条权威来源**的接口级对照 + 管理员 B1。
//
// 官方 APK 清单（前者）与官方服务端 `.lib`（后者）**不是一回事**，必须分开证：
//
// ① **APK 词表**：`~/synology_samples/apk/DSnote.apk` 的 `classes*.dex` 里逐字出现的
//    `SYNO.NoteStation*` 串，共 18 个。客户端只可能调这些。
//    ⚠️ 242 轮更正：129 轮那张"官方 APK 18 前缀"表把 `.lib` 的服务端 API
//    （`Export.*` / `Import.*` / `FTS` / `Note.AppLink` / `Note.AppTask` /
//    `Notebook.Polling` / `Notebook.Preset`）混了进来 —— 它们在 APK 里
//    **0 处出现**（全包 3818 个条目逐字节扫过）。这里换成真扫描出来的表。
//
// ② **`.lib` 表**：`weblib/NoteStation/webapi/SYNO.NoteStation.lib`（34 个 API、
//    逐版本方法表、`allowUser`）。下面把 34 条**逐字钉在测试里**，与 catalog
//    逐版本比对 —— 改成"先解析官方文件再比"会掩盖 catalog 被改坏的问题，
//    所以官方一侧必须是**不可变的字面量**。
//
// ③ **管理员（规则 B1）**：`Setting.Global` / `Setting.Volume` 是唯二
//    `allowUser=[admin.*]` 的笔记 API ⇒ 非管理员必须 **105**、管理员必须放行。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';

/// 官方 `.lib` 的 34 条（`api|版本:方法,方法|…`，方法按字典序）。
/// 事实来源：`~/synology_samples/weblib/NoteStation/webapi/SYNO.NoteStation.lib`。
const kOfficialLib = <String>[
  'SYNO.NoteStation.Export.Note|1:download,start,status,stop',
  'SYNO.NoteStation.Export.Notebook|1:start,status,stop',
  'SYNO.NoteStation.Export.Word|1:download,start,status,stop',
  'SYNO.NoteStation.FTS|1:search',
  'SYNO.NoteStation.Import.Enex|1:start,status,stop',
  'SYNO.NoteStation.Import.Evernote|1:add_import_task,check_oauth_token,get_oauth_token,get_oauth_url,get_polling_task,get_status,import,import_lock,import_status,import_stop,init,list_notebooks,prepare_notebooks,prepare_notebooks_status',
  'SYNO.NoteStation.Import.Notebook|1:start,status,stop',
  'SYNO.NoteStation.Info|1:get,searchplace|2:get,searchplace|3:get,searchplace',
  'SYNO.NoteStation.Note|1:copy,create,delete,download,get,idle,list,restore,set|2:copy,create,delete,download,get,idle,list,restore,set|3:copy,create,delete,download,get,idle,list,restore,set|4:copy,create,delete,download,get,get_attachment_text,idle,list,restore,set',
  'SYNO.NoteStation.Note.AppLink|1:get|2:get,resolve',
  'SYNO.NoteStation.Note.AppTask|2:get',
  'SYNO.NoteStation.Note.Encrypt|1:check,create,delete',
  'SYNO.NoteStation.Note.Ghost|2:create|3:create',
  'SYNO.NoteStation.Note.Polling|1:copy,copy_status,copy_stop,create,create_status,create_stop,set,set_status,set_stop|2:copy,copy_status,copy_stop,create,create_status,create_stop,set,set_status,set_stop|3:copy,copy_status,copy_stop,create,create_status,create_stop,set,set_status,set_stop',
  'SYNO.NoteStation.Note.Version|1:get,list,restore|2:get,list,restore',
  'SYNO.NoteStation.Notebook|1:create,delete,get,list,set|2:create,delete,get,list,set',
  'SYNO.NoteStation.Notebook.Polling|1:archive,archive_status,archive_stop',
  'SYNO.NoteStation.Notebook.Preset|1:set',
  'SYNO.NoteStation.Permission|1:delete,set',
  'SYNO.NoteStation.Permission.Group|1:delete,set',
  'SYNO.NoteStation.Permission.Public|1:delete,set',
  'SYNO.NoteStation.Permission.User|1:delete,set',
  'SYNO.NoteStation.Setting|1:get,init,set|2:get,init,set',
  'SYNO.NoteStation.Setting.DSM|1:get',
  'SYNO.NoteStation.Setting.Global|1:get,set',
  'SYNO.NoteStation.Setting.Volume|1:get_status,set',
  'SYNO.NoteStation.Shard|1:get,getjs,init',
  'SYNO.NoteStation.Shard.Link|1:get',
  'SYNO.NoteStation.Share.Priv|1:list|2:list',
  'SYNO.NoteStation.Shortcut|1:delete,list,set',
  'SYNO.NoteStation.Smart|1:create,delete,get,list,set',
  'SYNO.NoteStation.Stack|1:delete,set',
  'SYNO.NoteStation.Tag|1:delete,list,set|2:delete,list,set',
  'SYNO.NoteStation.Todo|1:create,delete,get,list,list_timeout,set|2:create,delete,get,list,list_timeout,set',
];

/// 官方 **APK dex** 里真实出现的 18 个前缀（`strings` 扫描，242 轮重新取证）。
const kOfficialApkVocabulary = <String>[
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

Map<String, dynamic> _catalog() =>
    (jsonDecode(File('tool/mock_dsm/catalog.json').readAsStringSync())
            as Map<String, dynamic>)['apis'] as Map<String, dynamic>;

/// catalog 的一侧：`api|版本:方法…`（与官方字面量同构，便于逐字比）。
List<String> _ours(Map<String, dynamic> apis, String k) {
  final methods = Map<String, dynamic>.from(
    (apis[k] as Map)['methods'] as Map,
  );
  final keys = methods.keys.map(int.parse).toList()..sort();
  return [
    [
      k,
      for (final v in keys)
        '$v:${(methods['$v'] as List).map((x) => '$x').toList()..sort()}'.replaceAll(
          RegExp(r'[\[\] ]'),
          '',
        ),
    ].join('|'),
  ];
}

MockDsmBackend _backend({required bool admin}) {
  final b = MockDsmBackend(catalog: DsmCatalog.load());
  b.login(username: admin ? 'admin' : 'kukakaka', admin: admin);
  return b;
}

MockDsmResponse _call(MockDsmBackend b, String api, String method) =>
    b.handle('entry.cgi', {
      'api': api,
      'method': method,
      'version': 1,
      '_sid': b.sessions.first,
    });

void main() {
  final apis = _catalog();
  final noteApis = apis.keys.where((k) => k.startsWith('SYNO.NoteStation')).toList()
    ..sort();

  group('④笔记结项 · 与官方 `.lib` 逐版本对齐（34/34）', () {
    test('★ 数量一致：官方 34 == 我方 34（无缺、无多余）', () {
      expect(noteApis.length, 34);
      expect(kOfficialLib.length, 34);
      final officialNames =
          kOfficialLib.map((s) => s.split('|').first).toSet().toList()..sort();
      expect(noteApis, officialNames, reason: '两侧 API 名单必须逐字相同');
    });

    test('★ 逐条方法表逐版本一致（把官方表钉成字面量，防 catalog 被改坏）', () {
      final official = {
        for (final line in kOfficialLib) line.split('|').first: line,
      };
      final bad = <String>[];
      for (final k in noteApis) {
        final ours = _ours(apis, k).single;
        if (official[k] != ours) bad.add('$k\n  官方: ${official[k]}\n  我方: $ours');
      }
      expect(bad, isEmpty, reason: '方法表不一致：\n${bad.join("\n")}');
    });

    test('★ 版本区间自洽：methods 的键就是官方那几版（不做"取 maxVersion"的傻事）', () {
      for (final k in noteApis) {
        final e = apis[k] as Map;
        final min = e['minVersion'] as int;
        final max = e['maxVersion'] as int;
        final vers = (e['methods'] as Map).keys.map((v) => int.parse('$v')).toList()..sort();
        expect(min, lessThanOrEqualTo(max), reason: k);
        expect(vers.first, min, reason: '$k 第一版应为 minVersion');
        // 允许中间有洞（官方就是分散的），但不允许越界
        expect(vers.every((v) => v >= min && v <= max), isTrue, reason: k);
      }
    });
  });

  group('④笔记结项 · 与官方 **APK** 词表对齐', () {
    test('★ APK dex 真实出现的 18 个前缀，catalog 一个不少', () {
      final missing =
          kOfficialApkVocabulary.where((p) => !apis.containsKey(p)).toList();
      expect(missing, isEmpty, reason: '官方 APK 会调而我们没有 ⇒ 缺口：$missing');
    });

    test('★ 真扫描（APK 在本地时）：dex 里的 NoteStation 串全部被 catalog 覆盖', () {
      final apk = File(
        '${Platform.environment['HOME']}/synology_samples/apk/DSnote.apk',
      );
      if (!apk.existsSync()) {
        // 没有样本时不假装通过：只核对上面那张"已取证"的常量表
        expect(kOfficialApkVocabulary.length, 18);
        return;
      }
      final bytes = _dexBytes(apk);
      final found = RegExp(r'SYNO\.NoteStation[.A-Za-z0-9]*')
          .allMatches(bytes)
          .map((m) => m.group(0)!)
          .toSet()
        ..removeWhere((s) => s.endsWith('.'));
      final missing = found.where((s) => !apis.containsKey(s)).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason: 'APK 里出现但 catalog 没有的：$missing',
      );
      for (final p in kOfficialApkVocabulary) {
        expect(found, contains(p), reason: '常量表里的 $p 在 APK 里找不到 ⇒ 表过期了');
      }
    });

    test('★ 服务端专属（APK 不调的）也仍在 catalog 里 —— Mock 兜得住', () {
      final serverOnly = kOfficialLib
          .map((s) => s.split('|').first)
          .where((k) => !kOfficialApkVocabulary.contains(k))
          .toList();
      expect(serverOnly, isNotEmpty, reason: '确有 APK 不调的服务端 API');
      for (final k in serverOnly) {
        expect(apis.containsKey(k), isTrue, reason: '$k 在官方 .lib 里，catalog 不能没有');
      }
    });
  });

  group('④笔记结项 · 管理员 B1（Mock 双轨，必须通过）', () {
    test('★ adminOnly 恰为 Setting.Global / Setting.Volume，且 allowUser 只有 admin.*', () {
      final adminOnly =
          noteApis.where((k) => (apis[k] as Map)['adminOnly'] == true).toList()
            ..sort();
      expect(adminOnly, [
        'SYNO.NoteStation.Setting.Global',
        'SYNO.NoteStation.Setting.Volume',
      ]);
      for (final k in adminOnly) {
        final allow = ((apis[k] as Map)['allowUser'] as List).map((u) => '$u');
        expect(allow.every((u) => u.startsWith('admin.')), isTrue, reason: k);
      }
    });

    test('★ 非管理员 → 105（Global/get、Volume/set 各一次）', () {
      final b = _backend(admin: false);
      for (final (api, method) in [
        ('SYNO.NoteStation.Setting.Global', 'get'),
        ('SYNO.NoteStation.Setting.Volume', 'set'),
      ]) {
        final r = _call(b, api, method);
        expect(r.errorCode, 105, reason: '$api/$method 是 admin-only，必须拦');
      }
    });

    test('★ 管理员 → 放行，且**不是 103**（方法真在表里）', () {
      final b = _backend(admin: true);
      for (final (api, method) in [
        ('SYNO.NoteStation.Setting.Global', 'get'),
        ('SYNO.NoteStation.Setting.Volume', 'set'),
      ]) {
        final r = _call(b, api, method);
        expect(r.errorCode, isNot(105), reason: '$api/$method 管理员该放行');
        expect(
          r.errorCode,
          isNot(103),
          reason: '$api/$method 报 103 = catalog 方法表错了',
        );
      }
    });

    test('★ 反证闸门是真的：普通笔记 API 同样两轨都放行（105 不是"一律拦"）', () {
      final b = _backend(admin: false);
      final r = _call(b, 'SYNO.NoteStation.Note', 'list');
      expect(r.errorCode, isNot(105));
    });
  });
}

/// 解开 APK（zip）里全部 `classes*.dex`，拼成可正则扫的文本。
///
/// ★ 必须**真解压**：dex 在 zip 里是 deflate 的，直接对整包字节做 latin1
/// 扫不到任何 API 串（我第一次就这么写的，等于假绿）。
String _dexBytes(File apk) {
  final archive = ZipDecoder().decodeBytes(apk.readAsBytesSync());
  final buf = StringBuffer();
  for (final f in archive) {
    if (!f.isFile || !f.name.contains('classes') || !f.name.endsWith('.dex')) {
      continue;
    }
    final data = f.content as List<int>;
    buf.write(latin1.decode(data, allowInvalid: true));
    buf.write('\n');
  }
  return buf.toString();
}
