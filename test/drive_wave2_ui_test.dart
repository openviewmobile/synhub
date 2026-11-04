// Drive **wave2** 界面层离线测试：能力门控 + 展示语义（不谎报 / 不上屏内部 id）。
//
// 覆盖：
//   * 扩展页「存储空间」入口：能力表缺 `Info` → 隐藏；105（unauthorized）→ 隐藏；
//     119（sessionExpired）→ 保留（**绝不隐藏**）；
//   * 配额页：`quota:0` → 显示「不限额」而**不是** "0 B / 0 B"；有配额 → 进度条；
//   * 转 Office 面板：已提交 / 完成 / 失败三态；`async_task_id` **绝不上屏**；
//     `Files` 能力位缺失 → 提交按钮禁用。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/drive/drive_convert_office_sheet.dart';
import 'package:synhub/src/features/drive/drive_extras_page.dart';
import 'package:synhub/src/features/drive/drive_info_sheet.dart';
import 'package:synhub/src/features/drive/drive_quota_page.dart';
import 'package:synhub/src/features/drive/drive_wave2_providers.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Tasks': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

const _allDriveApis = {
  'SYNO.SynologyDrive.Files',
  'SYNO.SynologyDrive.Info',
  'SYNO.SynologyDrive.Trash',
  'SYNO.SynologyDrive.TeamFolders',
  'SYNO.SynologyDrive.FileRequest',
  'SYNO.SynologyDrive.Notifications',
};

/// 固定快照的可用性 notifier（测试直接给结果，不走真探测）
class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

ServiceAvailabilitySnapshot _snap(
  Set<String> driveApis, {
  AvailabilityState? driveState,
}) => ServiceAvailabilitySnapshot(
  states: {
    for (final s in StationService.values)
      s: s == StationService.drive
          ? (driveState ??
                classifyApiTable(
                  kServiceRegistry[StationService.drive]!,
                  driveApis,
                ))
          : AvailabilityState.available,
  },
  apis: driveApis,
  checkedAt: DateTime(2026, 9, 22),
);

DriveEntryDto _fileEntry({String name = 'notes.txt', String id = '5'}) =>
    DriveEntryDto(
      fileId: id,
      name: name,
      type: 'file',
      path: '/$name',
      displayPath: '/mydrive/$name',
      parentId: '1',
      size: 2048,
      modifiedTime: 1789775507,
      createdTime: 1789775400,
      contentType: 'text',
      starred: false,
      shared: false,
      owner: 'demo_user',
      canDownload: true,
      canPreview: true,
      canWrite: true,
      capabilities: const {'can_download': true, 'can_preview': true},
    );

Map<String, dynamic> _quotaReply({double quota = 0, double used = 17307.96}) =>
    {
      'share_list': [
        {
          'is_home': true,
          'name': 'homes',
          'quota': quota,
          'share_quota': 0,
          'share_used': 4871229.5,
          'support_per_share_quota': true,
          'used': used,
        },
      ],
    };

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Set<String> apis = _allDriveApis,
  AvailabilityState? driveState,
  bool zeroPoll = false,
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key]};
  };
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final c = ProviderContainer(
    overrides: [
      driveApiProvider.overrideWithValue(DriveApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis, driveState: driveState)),
      ),
      if (zeroPoll)
        driveConvertOfficeRunnerProvider.overrideWithValue(
          DriveConvertOfficeRunner(
            api: DriveApi(api),
            pollInterval: Duration.zero,
            maxPolls: 3,
          ),
        ),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (t: t, c: c);
}

String? _convertStatus(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('drive-convert-status'))).data;

void main() {
  group('① 扩展页「存储空间」入口门控', () {
    testWidgets('能力齐全 → 配额入口出现', (tester) async {
      await _pump(tester, const DriveExtrasPage());
      expect(find.byKey(const Key('drive-extras-quota')), findsOneWidget);
    });

    testWidgets('能力表缺 Info → 配额入口隐藏，其余照旧', (tester) async {
      await _pump(
        tester,
        const DriveExtrasPage(),
        apis: {..._allDriveApis}..remove(kDriveInfoApiName),
      );
      expect(find.byKey(const Key('drive-extras-quota')), findsNothing);
      expect(find.byKey(const Key('drive-extras-trash')), findsOneWidget);
    });

    testWidgets('105（unauthorized）→ 配额入口隐藏', (tester) async {
      await _pump(
        tester,
        const DriveExtrasPage(),
        driveState: AvailabilityState.unauthorized,
      );
      expect(find.byKey(const Key('drive-extras-quota')), findsNothing);
    });

    testWidgets('119（sessionExpired）→ 入口保留，绝不隐藏', (tester) async {
      await _pump(
        tester,
        const DriveExtrasPage(),
        driveState: AvailabilityState.sessionExpired,
      );
      expect(find.byKey(const Key('drive-extras-quota')), findsOneWidget);
    });
  });

  group('② 配额页展示（quota:0 = 不限额）', () {
    testWidgets('quota:0 → 显示「不限额」，绝不显示 0 B / 0 B', (tester) async {
      await _pump(
        tester,
        const DriveQuotaPage(),
        responses: {'SYNO.SynologyDrive.Info.quota': _quotaReply()},
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('drive-quota-primary-unlimited')),
        findsOneWidget,
      );
      expect(find.text('不限额'), findsOneWidget);
      // 已使用 + 真实用量
      final used = tester.widget<Text>(
        find.byKey(const Key('drive-quota-primary-used')),
      );
      expect(used.data, contains('已使用'));
      expect(used.data, isNot(contains('0 B')));
      // 全页也不该出现 "0 B"
      expect(find.textContaining('0 B'), findsNothing);
      // 不限额 → 不画进度条
      expect(
        find.byKey(const Key('drive-quota-primary-progress')),
        findsNothing,
      );
    });

    testWidgets('设了配额 → 进度条 + 百分比', (tester) async {
      await _pump(
        tester,
        const DriveQuotaPage(),
        responses: {
          'SYNO.SynologyDrive.Info.quota': _quotaReply(
            quota: 20480,
            used: 10240,
          ),
        },
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('drive-quota-primary-progress')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('drive-quota-primary-unlimited')),
        findsNothing,
      );
      expect(find.textContaining('已用 50%'), findsOneWidget);
    });
  });

  group('③ 转 Office 面板（结果提示 + 不上屏内部 id）', () {
    testWidgets('已提交（轮询未确认）→ 只说"已提交"，且不出现 task id', (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: DriveConvertOfficeSheet(entry: _fileEntry(name: 'plan.odoc')),
        ),
        responses: {
          'SYNO.SynologyDrive.Files.convert_office': {
            'async_task_id': 'task-140',
          },
          'SYNO.SynologyDrive.Tasks.get': {
            'task_id': 'task-140',
            'status': 'in_progress',
            'progress': 30,
          },
        },
        zeroPoll: true,
      );
      await tester.tap(find.byKey(const Key('drive-convert-submit')));
      await tester.pumpAndSettle();

      final status = _convertStatus(tester);
      expect(status, contains('已提交'));
      // 不得报"转换完成"（消息里提到"完成后…"是正常措辞，但结论不能是完成）
      expect(status, isNot(contains('转换完成')));
      // 内部 id 绝不上屏
      expect(find.textContaining('task-140'), findsNothing);
      expect(find.textContaining('974457808523148038'), findsNothing);
    });

    testWidgets('轮询确认 finished → 显示"转换完成"', (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: DriveConvertOfficeSheet(entry: _fileEntry(name: 'plan.odoc')),
        ),
        responses: {
          'SYNO.SynologyDrive.Files.convert_office': {
            'async_task_id': 'task-140',
          },
          'SYNO.SynologyDrive.Tasks.get': {
            'task_id': 'task-140',
            'status': 'finished',
            'result': {'action': 'convert_office'},
          },
        },
        zeroPoll: true,
      );
      await tester.tap(find.byKey(const Key('drive-convert-submit')));
      await tester.pumpAndSettle();
      expect(_convertStatus(tester), contains('转换完成'));
      expect(find.textContaining('task-140'), findsNothing);
    });

    testWidgets('105 → 无权限说明（门控语义）', (tester) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) => null;
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      // convert_office 固定回 105
      final c = ProviderContainer(
        overrides: [
          driveApiProvider.overrideWithValue(DriveApi(api)),
          serviceAvailabilityProvider.overrideWith(
            () => _FixedAvailability(_snap(_allDriveApis)),
          ),
          driveConvertOfficeRunnerProvider.overrideWithValue(
            DriveConvertOfficeRunner(
              api: DriveApi(api),
              pollInterval: Duration.zero,
              maxPolls: 1,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      t.failures['SYNO.SynologyDrive.Files.convert_office'] = 105;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: DriveConvertOfficeSheet(
                entry: _fileEntry(name: 'plan.odoc'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('drive-convert-submit')));
      await tester.pumpAndSettle();
      expect(_convertStatus(tester), contains('没有访问该功能的权限'));
    });

    testWidgets('Files 能力位缺失 → 提交禁用', (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: DriveConvertOfficeSheet(entry: _fileEntry(name: 'plan.odoc')),
        ),
        apis: {..._allDriveApis}..remove(kDriveFilesApiName),
      );
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('drive-convert-submit')),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('④ 信息面板里的转换入口门控', () {
    testWidgets('Files 可用 → 出现转换按钮', (tester) async {
      await _pump(
        tester,
        Scaffold(body: DriveInfoSheet(entry: _fileEntry())),
        responses: const {},
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('drive-info-convert-office')),
        findsOneWidget,
      );
    });

    testWidgets('Files 缺失 → 转换按钮隐藏', (tester) async {
      await _pump(
        tester,
        Scaffold(body: DriveInfoSheet(entry: _fileEntry())),
        apis: {..._allDriveApis}..remove(kDriveFilesApiName),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-info-convert-office')), findsNothing);
    });
  });
}
