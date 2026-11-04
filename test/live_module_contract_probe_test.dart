import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/calendar_api.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/contacts_api.dart';
import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
/// 记下每一次 `call` 的真实回包形状（**只记录，不改行为**）。
class RecordingApi extends DsmWebApi {
  RecordingApi(super.transport);

  final List<Map<String, Object?>> calls = [];

  @override
  Future<Map<String, dynamic>> call(
    String api,
    String method, {
    int preferredVersion = 1,
    Map<String, dynamic> params = const {},
    bool requiresAuth = true,
  }) async {
    final t0 = DateTime.now();
    try {
      final data = await super.call(
        api,
        method,
        preferredVersion: preferredVersion,
        params: params,
        requiresAuth: requiresAuth,
      );
      calls.add({
        'api': api,
        'method': method,
        'version': preferredVersion,
        'ok': true,
        'keys': data.keys.toList(),
        'listCount': _listCount(data),
        'ms': DateTime.now().difference(t0).inMilliseconds,
      });
      return data;
    } on DsmApiException catch (e) {
      calls.add({
        'api': api,
        'method': method,
        'version': preferredVersion,
        'ok': false,
        'code': e.code,
        'ms': DateTime.now().difference(t0).inMilliseconds,
      });
      rethrow;
    }
  }

  /// 回包里**第一个非空列表**的条数（用来判"服务端有数据、我方是空"）。
  static int? _listCount(Map<String, dynamic> data) {
    for (final v in data.values) {
      if (v is List) return v.length;
    }
    return null;
  }
}

/// 一个探针任务：跑一个**生产方法**，并把"返回了几条"算出来。
class Task {
  const Task(
    this.module,
    this.label,
    this.run,
    this.count, {
    this.expectCodes = const {},
  });

  final String module;
  final String label;
  final Future<Object?> Function() run;
  final int? Function(Object?) count;

  /// **已知会失败**的错误码（有出处、不是缺陷）——例如普通用户对根目录 `/`
  /// 拿 `105/401`（`filestation_api.dart:220` 有记录）。
  final Set<int> expectCodes;
}

/// 各模块 DTO 的分页容器字段名不统一（`items` / `entries` / `files` / `tasks`…），
/// 用 `dynamic` 探测常见字段名 —— 探针只关心**条数**，不关心类型。
int? _size(Object? v) {
  if (v == null) return null;
  if (v is List) return v.length;
  final d = v as dynamic;
  for (final field in const [
    'items', 'entries', 'files', 'tasks', 'albums', 'folders', 'contacts',
    'notes', 'events', 'calendars', 'templates', 'themes', 'songs',
  ]) {
    try {
      final x = switch (field) {
        'items' => d.items,
        'entries' => d.entries,
        'files' => d.files,
        'tasks' => d.tasks,
        'albums' => d.albums,
        'folders' => d.folders,
        'contacts' => d.contacts,
        'notes' => d.notes,
        'events' => d.events,
        'calendars' => d.calendars,
        'templates' => d.templates,
        'themes' => d.themes,
        'songs' => d.songs,
        _ => null,
      };
      if (x is List) return x.length;
    } on Object {
      // 没有这个字段就试下一个
    }
  }
  return null;
}

Future<void> _runProbe(String url, String account, String password) async {
  final api = RecordingApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'FileStation');
  debugPrint('✔ 登录成功（只读探针）\n');

  final fs = FileStationApi(api);
  final drive = DriveApi(api);
  final office = OfficeApi(api);
  final chat = ChatApi(api);
  final audio = AudioStationApi(api);
  final dl = DownloadStationApi(api);
  final cal = CalendarApi(api);
  final contacts = ContactsApi(api);
  final foto = FotoApi(api);

  final tasks = <Task>[
    // ---------------- 文件
    Task('文件', 'List/list_share（共享目录）', fs.listShares, _size),
    // 普通用户对 `/` 回 105/401 是**已取证的已知行为**（FileStation 语义如此），
    // 这里是"记录它在真机上的表现"，不是缺陷。
    Task('文件', 'List/list（根目录 /）', () => fs.listFolder(folderPath: '/'), _size,
        expectCodes: const {105, 401}),
    // ★ 真正走一遍"列目录"的生产路径：进**第一个真实共享目录**看条目。
    Task('文件', 'List/list（首个共享目录内）', () async {
      final shares = await fs.listShares();
      if (shares.entries.isEmpty) return const <Object>[];
      return fs.listFolder(folderPath: '/${shares.entries.first.name}');
    }, _size),
    Task('文件', 'Info/get（存储概览）', () => fs.getInfo('/'), (v) => null),
    Task('文件', 'Favorite/list', fs.listFavorites, _size),
    Task('文件', 'VirtualFolder/list', fs.listVirtualFolders, _size),
    Task('文件', 'Mount.List/get', fs.listMounts, (v) => null),
    // ---------------- Drive
    Task('Drive', 'Files/list（/mydrive）', drive.list, _size),
    Task('Drive', 'Files/get（/mydrive）', () => drive.get(path: kDriveRoot), (_) => 1),
    Task('Drive', 'Files/list_starred', drive.listStarred, _size),
    Task('Drive', 'Files/recent', drive.recent, _size),
    Task('Drive', 'TeamFolders/list', drive.teamFolders, _size),
    // ---------------- Office
    Task('Office', 'Info/get', office.info, (_) => 1),
    Task('Office', 'Template/list', office.templateList, _size),
    Task('Office', 'Theme/list（presentation）',
        () => office.themeList(ntype: 'presentation'), _size),
    // ---------------- 聊天
    Task('聊天', 'Channel/list（已加入）', chat.listChannels, _size),
    Task('聊天', 'User/list', chat.listUsers, _size),
    // ---------------- 音频
    Task('音频', 'Info/get', audio.getInfo, (_) => 1),
    Task('音频', 'Song/list', audio.listSongs, _size),
    Task('音频', 'Album/list', audio.listAlbums, _size),
    Task('音频', 'Artist/list', audio.listArtists, _size),
    Task('音频', 'Genre/list', audio.listGenres, _size),
    // ---------------- 下载
    Task('下载', 'Task.List（全部）', dl.listTasks, _size),
    // ---------------- 日历
    Task('日历', 'Calendar/list', cal.listCalendars, _size),
    Task('日历', 'EventColor/list', cal.listEventColors, _size),
    // ---------------- 联系人
    Task('联系人', 'Contact/list', contacts.contacts, _size),
    Task('联系人', 'Info/get', contacts.info, (_) => 1),
    // ---------------- 相册
    Task('相册', 'Browse.Album/list', foto.albums, _size),
    Task('相册', 'Browse.Album（普通相册）', foto.normalAlbums, _size),
    Task('相册', 'Browse.Folder/list（root）', foto.folders, _size),
    Task('相册', 'Browse.Item（最近添加）', foto.recentlyAdded, _size),
  ];

  final results = <Map<String, Object?>>[];
  for (final t in tasks) {
    final before = api.calls.length;
    String verdict;
    int? got;
    try {
      final r = await t.run();
      got = t.count(r);
      verdict = 'OK';
    } on DsmApiException catch (e) {
      verdict = t.expectCodes.contains(e.code)
          ? 'OK（已知 ${e.code}：非管理员对该路径无权限，已取证）'
          : '★THREW 错误码 ${e.code}';
    } on Object catch (e) {
      final s = '$e';
      verdict = '★THREW ${s.length > 90 ? s.substring(0, 90) : s}';
    }
    final newCalls = api.calls.skip(before).toList();
    final serverList = newCalls
        .map((c) => c['listCount'])
        .whereType<int>()
        .fold<int?>(null, (a, b) => a == null || b > a ? b : a);
    var flag = '';
    if (verdict.startsWith('★')) {
      flag = '❌';
    } else if (got == 0 && (serverList ?? 0) > 0) {
      // ★ 服务端那个列表非空、我方却返回 0 —— 静默为空（第 260 轮 `items` 那类）
      flag = '❌★SILENT-EMPTY';
    } else if (got == 0) {
      flag = '· 空';
    } else {
      flag = '✅';
    }
    final apis = newCalls.map((c) => '${c['api']}:${c['method']}').join(', ');
    debugPrint('$flag ${t.module.padRight(4)} ${t.label.padRight(26)} '
        '我方=${got ?? '-'} 服务端列表=${serverList ?? '-'} $verdict');
    if (flag.startsWith('❌')) debugPrint('      ↳ 实际调用: $apis');
    results.add({
      'module': t.module,
      'label': t.label,
      'verdict': verdict,
      'got': got,
      'serverList': serverList,
      'flag': flag,
      'calls': newCalls,
    });
  }

  final bad = results.where((r) => '${r['flag']}'.startsWith('❌')).toList();
  debugPrint('\n===== 汇总 =====');
  debugPrint('任务 ${results.length} 个，发现问题 ${bad.length} 个');
  debugPrint('（✅ 有数据 / · 空是正常的空 / ❌ 抛异常或静默为空）');
  final out = File('/tmp/live_module_contract.json');
  out.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'nas': Platform.environment['SYNO_NAS_URL'],
      'tasks': results.length,
      'problems': bad.length,
      'results': results,
      'allCalls': api.calls,
    }),
  );
  debugPrint('明细 → ${out.path}');
  await api.logout();
  expect(bad, isEmpty,
      reason: '真 NAS 只读契约对照发现 ${bad.length} 个问题：\n'
          '${bad.map((r) => '${r['module']}/${r['label']} → ${r['verdict']}'
              '（我方 ${r['got']}，服务端列表 ${r['serverList']}）').join('\n')}');
}

/// 从 `/tmp/nas_cred.env` 读凭据（`NAS_ACCOUNT=… / NAS_PASSWORD=…`）。
Map<String, String>? _creds() {
  final f = File('/tmp/nas_cred.env');
  if (!f.existsSync()) return null;
  final out = <String, String>{};
  for (final line in f.readAsLinesSync()) {
    final m = RegExp(r'^\s*(?:export\s+)?(NAS_ACCOUNT|NAS_PASSWORD)\s*=\s*(.+?)\s*$')
        .firstMatch(line);
    if (m != null) {
      out[m.group(1)!] = m.group(2)!.replaceAll(RegExp(r'''^["']|["']$'''), '');
    }
  }
  final hasEnv = Platform.environment['SYNO_ACCOUNT'] != null;
  if (hasEnv) {
    out['NAS_ACCOUNT'] = Platform.environment['SYNO_ACCOUNT']!;
    out['NAS_PASSWORD'] = Platform.environment['SYNO_PASSWORD']!;
  }
  return out.length == 2 ? out : null;
}

void main() {
  final creds = _creds();
  test(
    '真 NAS 只读契约对照：各模块生产方法都能吃下真实回包',
    () async {
      await _runProbe(
        Platform.environment['SYNO_NAS_URL'] ?? 'https://nas.example.com:5001',
        creds!['NAS_ACCOUNT']!,
        creds['NAS_PASSWORD']!,
      );
    },
    skip: creds == null ? '未提供真 NAS 凭据（/tmp/nas_cred.env 缺失）' : null,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
