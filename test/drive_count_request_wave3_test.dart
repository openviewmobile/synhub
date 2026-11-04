// Drive：目录条目数（`Files:count_files` v11）+ 申请访问权
// （`Files:request_access` v11）离线测试。
//
// 契约全部来自**权威证据**（见交付报告）：
//   * APK：`VERSION_SUPPORT_FILE_COUNT_QUERY = 0xb`（=11）、方法枚举
//     `FILE_COUNT_QUERY → count_files`、`REQUEST_ACCESS → request_access`；
//   * 真机只读探针（2026-09-22）：
//       - `count_files v11 {paths:'["/mydrive"]'}` → `{"data":{"/mydrive":14}}`
//         （空参 `114` 报错原文点名 `paths`，类型数组）；
//       - `request_access` 空参 → `120 {"name":"path","reason":"required"}`；
//         `{path:[…]}` → `120 {"name":"path","reason":"type"}`（标量字符串）；
//         `{path:<不存在>}` → `1003 request access failed`（名字/形态跃迁确认）。
//
// ⚠️ 写路径：`request_access` 的**成功路径从未被真实调用**。这里的 widget 测试
// 只对 `FakeTransport` 操作，不碰任何真实 NAS。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/drive/drive_info_sheet.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _files = 'SYNO.SynologyDrive.Files';

Map<String, Map<String, dynamic>> _table(int filesMax) => {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  _files: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': filesMax},
};

const _allDriveApis = {
  _files,
  'SYNO.SynologyDrive.Info',
  'SYNO.SynologyDrive.Trash',
  'SYNO.SynologyDrive.TeamFolders',
  'SYNO.SynologyDrive.FileRequest',
  'SYNO.SynologyDrive.Notifications',
};

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

ServiceAvailabilitySnapshot _snap(Set<String> driveApis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values)
          s: s == StationService.drive
              ? classifyApiTable(
                  kServiceRegistry[StationService.drive]!,
                  driveApis,
                )
              : AvailabilityState.available,
      },
      apis: driveApis,
      checkedAt: DateTime(2026, 9, 22),
    );

Future<({FakeTransport t, DsmWebApi api})> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (t: t, api: api);
}

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
  int filesMax = 11,
}) {
  final t = FakeTransport(
    {...responses},
    {...FakeTransport.table, ..._table(filesMax)},
  );
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key]};
  };
  return t;
}

Map<String, dynamic> _callOf(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

/// 一个"我没有任何权限"的共享目录条目。
DriveEntryDto _lockedDir() => const DriveEntryDto(
  fileId: '77',
  name: 'Photos',
  type: 'dir',
  path: '/Photos',
  displayPath: '/mydrive/Photos',
  parentId: '1',
  size: 0,
  modifiedTime: 1789775507,
  createdTime: 1789775400,
  contentType: 'dir',
  starred: false,
  shared: true,
  owner: 'demo_user',
  canDownload: false,
  canPreview: false,
  canWrite: false,
  capabilities: {},
);

DriveEntryDto _openDir() => const DriveEntryDto(
  fileId: '78',
  name: 'Shared',
  type: 'dir',
  path: '/Shared',
  displayPath: '/mydrive/Shared',
  parentId: '1',
  size: 0,
  modifiedTime: 1789775507,
  createdTime: 1789775400,
  contentType: 'dir',
  starred: false,
  shared: false,
  owner: 'demo_user',
  canDownload: true,
  canPreview: true,
  canWrite: true,
  capabilities: {},
);

Map<String, dynamic> _dirReply(DriveEntryDto e) => {
  'file_id': e.fileId,
  'name': e.name,
  'type': 'dir',
  'path': e.path,
  'display_path': e.displayPath,
  'parent_id': e.parentId,
  'owner': {'display_name': e.owner},
  'capabilities': {
    'can_download': e.canDownload,
    'can_preview': e.canPreview,
    'can_write': e.canWrite,
  },
};

Future<({FakeTransport t, ProviderContainer c})> _pumpSheet(
  WidgetTester tester,
  DriveEntryDto entry, {
  Map<String, Map<String, dynamic>> responses = const {},
  int filesMax = 11,
  Map<String, int> failures = const {},
}) async {
  final base = {'$_files.get': _dirReply(entry), ...responses};
  final t = _transport(responses: base, filesMax: filesMax);
  t.failures.addAll(failures);
  final s = await _loggedIn(t);
  final c = ProviderContainer(
    overrides: [
      driveApiProvider.overrideWithValue(DriveApi(s.api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(_allDriveApis)),
      ),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(body: DriveInfoSheet(entry: entry)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (t: t, c: c);
}

void main() {
  group('① count_files（Files v11）接口层', () {
    test('v11 + paths 是 JSON 数组字符串 + 回包 path→数量 映射', () async {
      final t = _transport(
        responses: {
          '$_files.count_files': {'/mydrive': 14, '/mydrive/PhotoBackup': 4},
        },
      );
      final s = await _loggedIn(t);
      final counts = await DriveApi(
        s.api,
      ).countFiles(['/mydrive', '/mydrive/PhotoBackup']);

      final call = _callOf(t, 'count_files');
      expect(call['api'], _files);
      // APK：VERSION_SUPPORT_FILE_COUNT_QUERY = 0xb → **必须 11**
      expect(call['version'], '11');
      // 形态：JSON **数组字符串**（不是裸值、不是重复字段）
      expect(call['paths'], jsonEncode(['/mydrive', '/mydrive/PhotoBackup']));
      expect(call['paths'], isA<String>());

      expect(counts['/mydrive'], 14);
      expect(counts['/mydrive/PhotoBackup'], 4);
    });

    test('服务器 Files < v11 → 不发请求、返回空映射（不猜老版本）', () async {
      final t = _transport(
        responses: {
          '$_files.count_files': {'/mydrive': 99},
        },
        filesMax: 10,
      );
      final s = await _loggedIn(t);
      final counts = await DriveApi(s.api).countFiles(['/mydrive']);
      expect(counts, isEmpty);
      expect(t.calls.any((c) => c['method'] == 'count_files'), isFalse);
    });

    test('空 paths → 不发请求', () async {
      final t = _transport(responses: const {});
      final s = await _loggedIn(t);
      expect(await DriveApi(s.api).countFiles(const []), isEmpty);
      expect(t.calls.any((c) => c['method'] == 'count_files'), isFalse);
    });
  });

  group('② request_access（Files v11）接口层', () {
    test('v11 + 参数只有 path（标量字符串）', () async {
      final t = _transport(responses: {'$_files.request_access': const {}});
      final s = await _loggedIn(t);
      await DriveApi(s.api).requestAccess(path: '/mydrive/Photos');

      final call = _callOf(t, 'request_access');
      expect(call['api'], _files);
      expect(call['version'], '11');
      expect(call['path'], '/mydrive/Photos');
      // 只探明了一个参数：不能臆造别的字段
      final business = call.keys
          .where((k) => !{'api', 'version', 'method'}.contains(k))
          .where((k) => !k.startsWith('_'))
          .toList();
      expect(business, ['path']);
    });
  });

  group('③ 详情面板：目录条目数（只显示数字，不上屏原始映射）', () {
    testWidgets('有计数 → 显示「14 项」，绝不显示 {path: count} 原文', (tester) async {
      await _pumpSheet(
        tester,
        _openDir(),
        responses: {
          '$_files.count_files': {'/mydrive/Shared': 14},
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('包含条目'), findsOneWidget);
      expect(find.text('14 项'), findsOneWidget);
      // 原始映射 / JSON 一律不上屏
      expect(find.textContaining('":'), findsNothing);
      expect(find.textContaining('14}'), findsNothing);
    });

    testWidgets('计数失败 → 显示「暂时取不到」（**不静默、不装空**）', (tester) async {
      await _pumpSheet(
        tester,
        _openDir(),
        responses: {
          '$_files.count_files': {'/mydrive/Shared': 14},
        },
        failures: {'$_files.count_files': 105},
      );
      await tester.pumpAndSettle();

      expect(find.text('包含条目'), findsOneWidget);
      expect(find.text('暂时取不到'), findsOneWidget);
      expect(find.text('14 项'), findsNothing);
    });

    testWidgets('服务器 Files < v11 → 这一行根本不出现（不是失败）', (tester) async {
      await _pumpSheet(
        tester,
        _openDir(),
        responses: {
          '$_files.count_files': {'/mydrive/Shared': 14},
        },
        filesMax: 10,
      );
      await tester.pumpAndSettle();

      expect(find.text('包含条目'), findsNothing);
    });
  });

  group('④ 详情面板：申请访问权（写操作要确认，成功/失败都提示）', () {
    testWidgets('无权限目录 → 按钮出现；确认后才调用，且成功有提示', (tester) async {
      final r = await _pumpSheet(
        tester,
        _lockedDir(),
        responses: {'$_files.request_access': const {}},
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('drive-info-request-access')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('drive-info-request-access')));
      await tester.pumpAndSettle();

      // 先确认框，未确认前**不发写请求**
      expect(
        find.byKey(const Key('drive-request-access-confirm')),
        findsOneWidget,
      );
      expect(r.t.calls.any((c) => c['method'] == 'request_access'), isFalse);

      await tester.tap(find.byKey(const Key('drive-request-access-confirm')));
      await tester.pumpAndSettle();

      final call = _callOf(r.t, 'request_access');
      expect(call['version'], '11');
      // 真实调用走展示路径
      expect(call['path'], '/mydrive/Photos');
      expect(find.text('已发送访问权申请'), findsOneWidget);
    });

    testWidgets('取消确认 → 绝不发写请求', (tester) async {
      final r = await _pumpSheet(tester, _lockedDir());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('drive-info-request-access')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drive-request-access-cancel')));
      await tester.pumpAndSettle();

      expect(r.t.calls.any((c) => c['method'] == 'request_access'), isFalse);
    });

    testWidgets('已有权限 → 按钮不出现', (tester) async {
      await _pumpSheet(tester, _openDir());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-info-request-access')), findsNothing);
    });

    testWidgets('写失败 → 明确提示失败（不静默）', (tester) async {
      await _pumpSheet(
        tester,
        _lockedDir(),
        responses: {'$_files.request_access': const {}},
        failures: {'$_files.request_access': 105},
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('drive-info-request-access')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drive-request-access-confirm')));
      await tester.pumpAndSettle();

      expect(find.textContaining('申请失败'), findsOneWidget);
      expect(find.text('已发送访问权申请'), findsNothing);
    });
  });
}
