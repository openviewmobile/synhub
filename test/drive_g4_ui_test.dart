// G4 批次**界面层**离线测试：把新增的每一个页面/面板都真的渲染一次，
// 并断言关键的 key 与"点了会发生什么"。
//
// 覆盖：
//   * D21 `DriveComputersPage`（列表 / 空态）
//   * D22 `DriveLocalFilesPage`（不可用态：本机根目录可注入）
//   * D31/D34/D35 `showDriveTransferSheet`（多选显示 3 项、单选不显示"打包分享"）
//   * D40 `DriveAdvanceSharingPage` 的密码校验块（有密码才出现）
//   * 146 `showExtractSheet` 的分卷提示（第 1 卷 / 第 N 卷 两种 key）
//   * 219 `FileOfflinePage`（空态 / 列表 / 移出）
//   * 219 `FileRow` 的离线标记
//   * 223 `UsbDevicesPage`（设备卡片 / 空态 / 弹出确认）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/drive/drive_advance_sharing_page.dart';
import 'package:synhub/src/features/drive/drive_computers_page.dart';
import 'package:synhub/src/features/drive/drive_local_files_page.dart';
import 'package:synhub/src/features/drive/drive_transfer_sheet.dart';
import 'package:synhub/src/features/files/file_offline_page.dart';
import 'package:synhub/src/features/files/file_offline_pin.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_row.dart';
import 'package:synhub/src/features/files/file_sheets.dart';
import 'package:synhub/src/features/files/drive_providers.dart'
    show driveApiProvider;
import 'package:synhub/src/features/files/usb_devices_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.AdvanceSharing': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Core.ExternalDevice.Storage.USB': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Future<({FakeTransport t, DsmWebApi api})> _boot(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, int> failures = const {},
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.failures.addAll(failures);
  t.onCall = (params) => {
    ...?responses['${params['api']}.${params['method']}'],
    'success': true,
  };
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (t: t, api: api);
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget page, {
  List<Object?> overrides = const [],
}) async {
  final container = ProviderContainer(overrides: overrides.cast());
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

DriveEntryDto _driveEntry({
  String id = '1',
  String name = 'a.txt',
  String type = 'file',
  String dir = '/mydrive',
}) => DriveEntryDto.fromJson({
  'file_id': id,
  'name': name,
  'type': type,
  'path': '/$name',
  'display_path': '$dir/$name',
  'parent_id': '900',
  'size': type == 'dir' ? 0 : 2048,
  'modified_time': 1789739500,
  'created_time': 1789739400,
  'content_type': type == 'dir' ? 'dir' : 'document',
  'owner': {'display_name': 'demo_user', 'name': 'demo_user'},
  'capabilities': {'can_download': true},
});

FileEntryDto _fileEntry(String name) => FileEntryDto.fromJson({
  'name': name,
  'path': '/home/$name',
  'isdir': false,
  'size': 1024,
  'additional': {
    'size': 1024,
    'time': {'mtime': 1789739500},
  },
});

void main() {
  group('D21 DriveComputersPage', () {
    testWidgets('列出电脑 + 总数', (tester) async {
      final boot = await _boot({
        'SYNO.SynologyDrive.Files.list_backup_tasks': {
          'items': [
            {
              'file_id': 'c1',
              'name': 'DESKTOP-1',
              'type': 'dir',
              'display_path': '/mydrive/Computers/DESKTOP-1',
              'size': 0,
              'modified_time': 1789739500,
            },
          ],
          'total': 1,
        },
      });
      await _pump(
        tester,
        const DriveComputersPage(),
        overrides: [driveApiProvider.overrideWithValue(DriveApi(boot.api))],
      );
      expect(find.byKey(const Key('drive-computers-page')), findsOneWidget);
      expect(find.text('DESKTOP-1'), findsOneWidget);
    });

    testWidgets('空列表 → 空态', (tester) async {
      final boot = await _boot({
        'SYNO.SynologyDrive.Files.list_backup_tasks': {
          'items': const [],
          'total': 0,
        },
      });
      await _pump(
        tester,
        const DriveComputersPage(),
        overrides: [driveApiProvider.overrideWithValue(DriveApi(boot.api))],
      );
      expect(find.byKey(const Key('drive-computers-empty')), findsOneWidget);
    });
  });

  group('D22 DriveLocalFilesPage', () {
    testWidgets('本机根目录为空（不可用）→ 明确提示，不假装有文件', (tester) async {
      final boot = await _boot(const {});
      await _pump(
        tester,
        const DriveLocalFilesPage(targetDrivePath: '/mydrive'),
        overrides: [
          driveApiProvider.overrideWithValue(DriveApi(boot.api)),
          driveLocalRootsProvider.overrideWith(
            (ref) async => const <Directory>[],
          ),
        ],
      );
      expect(find.byKey(const Key('drive-local-files-page')), findsOneWidget);
      expect(find.byKey(const Key('drive-local-unavailable')), findsOneWidget);
    });

    testWidgets('有本机目录 → 先列根，进入后列出条目与上传入口', (tester) async {
      final boot = await _boot(const {});
      final dir = Directory.systemTemp.createTempSync('g4_local');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      File('${dir.path}/note.txt').writeAsStringSync('hi');
      await _pump(
        tester,
        const DriveLocalFilesPage(targetDrivePath: '/mydrive'),
        overrides: [
          driveApiProvider.overrideWithValue(DriveApi(boot.api)),
          driveLocalRootsProvider.overrideWith((ref) async => [dir]),
        ],
      );
      expect(find.byKey(const Key('drive-local-files-page')), findsOneWidget);
      expect(find.byKey(const Key('drive-local-roots')), findsOneWidget);

      // 进入根目录后才列本机文件
      await tester.tap(find.byKey(const Key('drive-local-root-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-local-list')), findsOneWidget);
      expect(
        find.byKey(const Key('drive-local-entry-note.txt')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('drive-local-upload-note.txt')),
        findsOneWidget,
      );
    });
  });

  group('D31/D34/D35 传输面板', () {
    Future<void> open(WidgetTester tester, List<DriveEntryDto> entries) async {
      final boot = await _boot(const {});
      final container = ProviderContainer(
        overrides: [driveApiProvider.overrideWithValue(DriveApi(boot.api))],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () =>
                        showDriveTransferSheet(context, ref, entries),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('多选：打包下载 + 打包分享（+ 不显示发送副本）', (tester) async {
      await open(tester, [
        _driveEntry(id: '1', name: 'a.txt'),
        _driveEntry(id: '2', name: 'b.txt'),
      ]);
      expect(find.byKey(const Key('drive-transfer-sheet')), findsOneWidget);
      expect(
        find.byKey(const Key('drive-transfer-archive-download')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('drive-transfer-archive-share')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('drive-transfer-send-copy')), findsNothing);
    });

    testWidgets('单选文件：发送副本在，打包分享不在', (tester) async {
      await open(tester, [_driveEntry(id: '1', name: 'a.txt')]);
      expect(find.byKey(const Key('drive-transfer-send-copy')), findsOneWidget);
      expect(
        find.byKey(const Key('drive-transfer-archive-share')),
        findsNothing,
      );
    });

    test('driveArchiveNameFor：单文件去扩展名、目录用名、多选用所在目录名', () {
      expect(driveArchiveNameFor([_driveEntry(name: 'a.txt')]), 'a');
      expect(
        driveArchiveNameFor([_driveEntry(name: 'docs', type: 'dir')]),
        'docs',
      );
      // 多选取**所在目录名**（官方 `fileName` 传的是目录名）
      expect(
        driveArchiveNameFor([
          _driveEntry(id: '1', name: 'a.jpg', dir: '/mydrive/Photos'),
          _driveEntry(id: '2', name: 'b.jpg', dir: '/mydrive/Photos'),
        ]),
        'Photos',
      );
    });
  });

  group('D40 AdvanceSharing 密码校验块', () {
    testWidgets('服务端回显密码 → 出现校验输入；否则不出现', (tester) async {
      final boot = await _boot({
        'SYNO.SynologyDrive.AdvanceSharing.get': {
          'sharing_link': 'abc',
          'url': 'https://nas/sharing/abc',
          'role': 'viewer',
          'protect_password': 'secret',
          'due_date': 0,
        },
      });
      await _pump(
        tester,
        const DriveAdvanceSharingPage(path: 'id:1', entryName: 'a.txt'),
        overrides: [driveApiProvider.overrideWithValue(DriveApi(boot.api))],
      );
      expect(
        find.byKey(const Key('drive-advance-sharing-password-input')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('drive-advance-sharing-password-verify')),
        findsOneWidget,
      );
    });

    testWidgets('没有密码 → 不渲染校验块', (tester) async {
      final boot = await _boot({
        'SYNO.SynologyDrive.AdvanceSharing.get': {
          'sharing_link': 'abc',
          'url': 'https://nas/sharing/abc',
          'role': 'viewer',
          'protect_password': '',
          'due_date': 0,
        },
      });
      await _pump(
        tester,
        const DriveAdvanceSharingPage(path: 'id:1', entryName: 'a.txt'),
        overrides: [driveApiProvider.overrideWithValue(DriveApi(boot.api))],
      );
      expect(
        find.byKey(const Key('drive-advance-sharing-password-input')),
        findsNothing,
      );
    });
  });

  group('146 解压面板的分卷提示', () {
    Future<void> openExtract(WidgetTester tester, String fileName) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showExtractSheet(context, fileName: fileName),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('第 1 卷 → 提示"会自动读其余分卷"', (tester) async {
      await openExtract(tester, 'movie.part1.rar');
      expect(find.byKey(const Key('fs-extract-volume-first')), findsOneWidget);
    });

    testWidgets('第 N 卷 → 提示"请改选第 1 卷"', (tester) async {
      await openExtract(tester, 'movie.part2.rar');
      expect(find.byKey(const Key('fs-extract-volume-later')), findsOneWidget);
    });

    testWidgets('普通压缩包 → 没有任何分卷提示', (tester) async {
      await openExtract(tester, 'plain.zip');
      expect(find.byKey(const Key('fs-extract-volume-first')), findsNothing);
      expect(find.byKey(const Key('fs-extract-volume-later')), findsNothing);
    });
  });

  group('219 离线文件', () {
    testWidgets('空清单 → 空态', (tester) async {
      await _pump(
        tester,
        const FileOfflinePage(),
        overrides: [
          offlinePinStoreProvider.overrideWithValue(MemoryOfflinePinStore()),
        ],
      );
      expect(find.byKey(const Key('file-offline-page')), findsOneWidget);
      expect(find.byKey(const Key('file-offline-empty')), findsOneWidget);
    });

    testWidgets('有登记 → 列表；点移出后落到空态', (tester) async {
      final store = MemoryOfflinePinStore([
        const OfflinePinEntry(
          path: '/home/a.txt',
          name: 'a.txt',
          size: 1024,
          pinnedAt: 1789739500,
        ),
      ]);
      await _pump(
        tester,
        const FileOfflinePage(),
        overrides: [offlinePinStoreProvider.overrideWithValue(store)],
      );
      expect(find.byKey(const Key('file-offline-list')), findsOneWidget);
      expect(
        find.byKey(const Key('file-offline-entry-/home/a.txt')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('file-offline-unpin-/home/a.txt')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('file-offline-empty')), findsOneWidget);
      expect(store.items, isEmpty);
    });

    testWidgets('FileRow：pinned=true 才出现离线标记', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Column(
              children: [
                FileRow(entry: _fileEntry('a.txt'), pinned: true),
                FileRow(entry: _fileEntry('b.txt')),
              ],
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('file-row-offline-pinned')), findsOneWidget);
    });
  });

  group('223 USB 外接设备', () {
    testWidgets('列出设备与分区；点弹出要二次确认，确认后发 eject', (tester) async {
      final boot = await _boot({
        'SYNO.Core.ExternalDevice.Storage.USB.list': {
          'devices': [
            {
              'dev_id': 'usb1',
              'dev_title': 'SanDisk Cruzer',
              'partitions': [
                {
                  'name_id': 'usb1p1',
                  'partition_title': 'usbshare1',
                  'share_name': 'usbshare1',
                  'filesystem': 'vfat',
                  'status': 'normal',
                  'total_size_mb': '30436',
                  'used_size_mb': '124',
                },
              ],
            },
          ],
        },
      });
      await _pump(
        tester,
        const UsbDevicesPage(),
        overrides: [
          fileApiProvider.overrideWithValue(FileStationApi(boot.api)),
        ],
      );
      expect(find.byKey(const Key('fs-usb-page')), findsOneWidget);
      expect(find.text('SanDisk Cruzer'), findsOneWidget);
      expect(find.textContaining('usbshare1'), findsWidgets);

      await tester.tap(find.byKey(const Key('fs-usb-eject-usb1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fs-usb-eject-confirm')), findsOneWidget);

      await tester.tap(find.byKey(const Key('fs-usb-eject-confirm')));
      await tester.pumpAndSettle();
      expect(
        boot.t.calls.any(
          (c) =>
              c['method'] == 'eject' &&
              c['dev_id'] == 'usb1' &&
              c['version'] == '1',
        ),
        isTrue,
      );
    });

    testWidgets('404（没有插盘）→ 空态而不是错误页', (tester) async {
      final boot = await _boot(
        const {},
        failures: {'SYNO.Core.ExternalDevice.Storage.USB.list': 404},
      );
      await _pump(
        tester,
        const UsbDevicesPage(),
        overrides: [
          fileApiProvider.overrideWithValue(FileStationApi(boot.api)),
        ],
      );
      expect(find.byKey(const Key('fs-usb-empty')), findsOneWidget);
    });

    testWidgets('105（无权限）→ 错误态，不伪装成"没有设备"', (tester) async {
      final boot = await _boot(
        const {},
        failures: {'SYNO.Core.ExternalDevice.Storage.USB.list': 105},
      );
      await _pump(
        tester,
        const UsbDevicesPage(),
        overrides: [
          fileApiProvider.overrideWithValue(FileStationApi(boot.api)),
        ],
      );
      expect(find.byKey(const Key('fs-usb-empty')), findsNothing);
      expect(find.byKey(const Key('fs-usb-list')), findsNothing);
    });
  });
}
