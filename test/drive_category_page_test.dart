// D23「分类浏览」（官方 Home 的 photos/documents/audio/videos 分类图标）测试。
//
// 覆盖：
//   ① 纯逻辑：条目 → 分类（图片/视频/音频/文档、目录不进分类、无扩展名算文档）
//      + 四个分类的计数（0 也要在）+ 过滤顺序；
//   ② 页面：四个 chip 带计数、默认照片、点音频只出音频、空态；
//   ③ 入口：`DriveMorePage` 上的 `drive-more-categories` 在，点开进分类页。
//
// 证据口径见 `lib/src/features/drive/drive_category_page.dart` 文件头：
// 官方**没有**分类接口（`Files` 全版本无 category 方法、3.9.0 smali 里
// `file_type` 零命中）⇒ 客户端按扩展名分组，本页只读 `Files/recent`。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/drive/drive_category_page.dart';
import 'package:synhub/src/features/files/drive_more_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Trash': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.TeamFolders': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

const _allDriveApis = {
  'SYNO.SynologyDrive.Files',
  'SYNO.SynologyDrive.Trash',
  'SYNO.SynologyDrive.TeamFolders',
};

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
      checkedAt: DateTime(2026, 9, 24),
    );

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

DriveEntryDto _e(String name, {String id = '1', String type = 'file'}) =>
    DriveEntryDto(
      fileId: id,
      name: name,
      type: type,
      path: '/$name',
      displayPath: '/mydrive/$name',
      parentId: '0',
      size: 1024,
      modifiedTime: 1789775507,
      createdTime: 1789775501,
      contentType: 'application/octet-stream',
      starred: false,
      shared: false,
      owner: 'demo_user',
      canDownload: true,
      canPreview: true,
      canWrite: true,
      capabilities: const {'can_write': true},
    );

Map<String, dynamic> _recentJson(List<DriveEntryDto> items) => {
  'items': [
    for (final e in items)
      {
        'file_id': e.fileId,
        'name': e.name,
        'type': e.type,
        'path': e.path,
        'display_path': e.displayPath,
        'parent_id': e.parentId,
        'size': e.size,
        'modified_time': e.modifiedTime,
        'created_time': e.createdTime,
        'content_type': e.contentType,
        'starred': e.starred,
        'shared': e.shared,
        'owner': {'name': e.owner},
      },
  ],
  'total': items.length,
};

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  List<DriveEntryDto> items = const [],
  // ★ 仪器⑯（r356 订正）：以前这里是**裸 `MaterialApp`**（没有
  // `localizationsDelegates`）⇒ `context.t` 恒回落 `AppTextZh()`，
  // 于是"中文 chip"断言**通过的理由是错的**（不是因为中文模式，而是因为
  // 根本没有本地化装置），英文漏翻在这条用例里**永远测不出来**（DA11 就是
  // 这么漏过去的）。现在显式装 delegate + locale，并把数据层翻译器
  // （`driveG4` → `dataText`）一起按语言装好，与
  // `SynologyChatApp.build → setCurrentText` 同一条路径。
  Locale locale = const Locale('zh'),
}) async {
  setCurrentText(locale.languageCode == 'en' ? AppTextEn() : AppTextZh());
  addTearDown(() => setCurrentText(AppTextZh()));
  final responses = {
    'SYNO.SynologyDrive.Files.recent': _recentJson(items),
  };
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key], 'success': true};
  };
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      driveApiProvider.overrideWithValue(DriveApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(_allDriveApis)),
      ),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: locale,
        localizationsDelegates: AppText.localizationsDelegates,
        // ★ 与 `lib/src/app.dart` 同款：**必须显式给 supportedLocales**，
        // 否则 MaterialApp 默认只支持 `en_US` ⇒ 传 `Locale('zh')` 会被解析成
        // 英文（`driveCategoryChip` 变成半角括号那版），中文断言就又在
        // "装置不对"的情况下通过/失败了。
        supportedLocales: AppText.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  return (t: t, c: c);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('D23 纯逻辑：分类判据与计数', () {
    test('★ 扩展名 → 分类（图片/视频/音频）', () {
      expect(driveMediaKindOf(_e('a.JPG')), DriveMediaKind.photo);
      expect(driveMediaKindOf(_e('b.heic')), DriveMediaKind.photo);
      expect(driveMediaKindOf(_e('c.mkv')), DriveMediaKind.video);
      expect(driveMediaKindOf(_e('d.mp3')), DriveMediaKind.audio);
      expect(driveMediaKindOf(_e('e.flac')), DriveMediaKind.audio);
    });

    test('★ 其余非目录一律「文档」；无扩展名也算文档（口径=完整划分）', () {
      expect(driveMediaKindOf(_e('f.pdf')), DriveMediaKind.document);
      expect(driveMediaKindOf(_e('g.docx')), DriveMediaKind.document);
      expect(driveMediaKindOf(_e('noext')), DriveMediaKind.document);
      expect(driveMediaKindOf(_e('.hidden')), DriveMediaKind.document);
    });

    test('★ 目录不进任何分类', () {
      expect(driveMediaKindOf(_e('dir', type: 'dir')), isNull);
      expect(
        driveMediaCounts([_e('dir', type: 'dir')]).values.every((v) => v == 0),
        isTrue,
      );
    });

    test('★ 四个 key 始终在（0 也要在，官方 Home 就四个固定图标）', () {
      final c = driveMediaCounts([_e('a.jpg'), _e('b.mp4'), _e('c.mp3')]);
      expect(c.keys.toSet(), DriveMediaKind.values.toSet());
      expect(c[DriveMediaKind.photo], 1);
      expect(c[DriveMediaKind.video], 1);
      expect(c[DriveMediaKind.audio], 1);
      expect(c[DriveMediaKind.document], 0);
    });

    test('★ 过滤保持服务端顺序，且大小写不敏感', () {
      final items = [
        _e('1.pdf', id: '1'),
        _e('2.JPG', id: '2'),
        _e('3.PNG', id: '3'),
        _e('4.jpg', id: '4'),
      ];
      expect(
        driveMediaFilter(items, DriveMediaKind.photo).map((e) => e.fileId),
        ['2', '3', '4'],
      );
      expect(driveMediaFilter(items, DriveMediaKind.document).single.fileId, '1');
    });

    test('★ 官方埋点值与枚举名一一对应（不许改官方字符串）', () {
      expect(DriveMediaKind.photo.analyticsValue, 'category_photo');
      expect(DriveMediaKind.video.analyticsValue, 'category_video');
      expect(DriveMediaKind.audio.analyticsValue, 'category_audio');
      expect(DriveMediaKind.document.analyticsValue, 'category_doc');
    });
  });

  group('D23 页面：chip 计数 / 过滤 / 空态', () {
    testWidgets('★ 四个 chip 带计数，默认照片；点音频只出音频', (tester) async {
      final r = await _pump(
        tester,
        const DriveCategoryPage(),
        items: [
          _e('a.jpg', id: '1'),
          _e('b.png', id: '2'),
          _e('c.mp3', id: '3'),
          _e('d.pdf', id: '4'),
        ],
      );
      expect(find.byKey(const Key('drive-category-chip-photo')), findsOneWidget);
      expect(find.byKey(const Key('drive-category-chip-video')), findsOneWidget);
      expect(find.byKey(const Key('drive-category-chip-audio')), findsOneWidget);
      expect(
        find.byKey(const Key('drive-category-chip-document')),
        findsOneWidget,
      );
      // 计数逐项核对
      expect(find.text('照片（2）'), findsOneWidget);
      expect(find.text('视频（0）'), findsOneWidget);
      expect(find.text('音频（1）'), findsOneWidget);
      expect(find.text('文档（1）'), findsOneWidget);
      // 默认照片：只出 jpg/png
      expect(find.byKey(const Key('drive-category-item-1')), findsOneWidget);
      expect(find.byKey(const Key('drive-category-item-2')), findsOneWidget);
      expect(find.byKey(const Key('drive-category-item-3')), findsNothing);
      // 切音频
      await tester.tap(find.byKey(const Key('drive-category-chip-audio')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-category-item-3')), findsOneWidget);
      expect(find.byKey(const Key('drive-category-item-1')), findsNothing);
      // 只读：一次写方法都没发
      final driveCalls = r.t.calls
          .where((c) => c['api'] == 'SYNO.SynologyDrive.Files')
          .toList();
      expect(driveCalls, isNotEmpty);
      // 只读：一次写方法都没发（§5.1）
      for (final call in driveCalls) {
        expect(call['method'], 'recent');
      }
    });

    testWidgets('★ DA11：英文模式下四个 chip 与标题都是英文（真机英文界面同款判据）',
        (tester) async {
      // 真机读数（r356，英文界面）：改前这里是 `照片 (1)` / `文档 (16)`
      // —— 模板是英文的（半角括号）而 label 回落了中文兜底。
      // 本用例把装置按 en 装齐（delegate + supportedLocales + locale +
      // 数据层翻译器），所以它**能**红；改前的老用例是裸 MaterialApp，
      // 恒中文 ⇒ 这类漏翻结构上测不出来（仪器⑯）。
      await _pump(
        tester,
        const DriveCategoryPage(),
        locale: const Locale('en'),
        items: [
          _e('a.jpg', id: '1'),
          _e('b.png', id: '2'),
          _e('c.mp3', id: '3'),
          _e('d.pdf', id: '4'),
        ],
      );
      // 装置自证：标题走 `driveG4`（数据层翻译器）、chip 走 `context.t`（delegate），
      // 两条路都得是英文，否则下面的断言就是"装置不对"的假绿。
      expect(find.text('Browse by category'), findsOneWidget);
      expect(currentText(), isA<AppTextEn>());
      expect(find.text('Photos (2)'), findsOneWidget);
      expect(find.text('Videos (0)'), findsOneWidget);
      expect(find.text('Audio (1)'), findsOneWidget);
      expect(find.text('Documents (1)'), findsOneWidget);
      // 中文兜底（全角或半角）一个都不许上屏
      expect(find.text('照片 (2)'), findsNothing);
      expect(find.text('照片（2）'), findsNothing);
      expect(find.text('分类浏览'), findsNothing);
    });

    testWidgets('★ 全空（真机最近为空时）→ 空态', (tester) async {
      await _pump(tester, const DriveCategoryPage(), items: const []);
      expect(find.byKey(const Key('drive-category-empty')), findsOneWidget);
      expect(find.byKey(const Key('drive-category-chip-photo')), findsOneWidget);
    });
  });

  group('D23 入口', () {
    testWidgets('★ Drive「更多」页有分类浏览入口，点开进分类页', (tester) async {
      await _pump(tester, const DriveMorePage(), items: [_e('a.jpg')]);
      final entry = find.byKey(const Key('drive-more-categories'));
      expect(entry, findsOneWidget);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(DriveCategoryPage), findsOneWidget);
    });
  });
}
