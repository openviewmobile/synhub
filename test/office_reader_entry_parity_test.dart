// ★★★ 第 256 轮（用户裁决）：**同一份文档，NAS「文件」与「我的 Drive」必须用同一个阅读器**。
//
// 用户原话：「同一份文档在 nas files 里和 my drive 里打开不一样？这块我觉得需要保持
// 统一，nas files 如果打开 office 三种格式的文档要调用 my drive 里的阅读器」。
//
// 真机证据（LGE-AN10，`Dynamic.oslides` 8.8 MB，同一份文件）：
//   * 「我的 Drive」→ `OfficeSlidesPage`：渐变母版 + 白字标题 + **缩略图 1/15**；
//   * 「NAS files」（修复前）→ `OfficeNativeViewer` 的降级渲染：白底黑字小标题、无缩略图。
// 差别不在数据而在**路由**。修法：`openFileUnified` 把「文件」侧接到 `driveOpenEntry`。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/drive/drive_open_entry.dart'
    show openFileUnified;
import 'package:synhub/src/features/files/drive_providers.dart'
    show driveApiProvider;

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

FileEntryDto _entry(String name, String path) => FileEntryDto(
  name: name,
  path: path,
  isDir: false,
  size: 9003452,
  mtime: 1789739500,
);

const _apiTable = <String, Map<String, dynamic>>{
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.Office.Snapshot': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Office.Node': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

/// 渲染一个按钮，点它就调用 [openFileUnified]（模拟「文件」里点一行）。
Future<void> _pump(WidgetTester tester, FakeTransport t, FileEntryDto e) async {
  final api = await _loggedIn(t);
  final container = ProviderContainer(
    overrides: [driveApiProvider.overrideWithValue(DriveApi(api))],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              key: const Key('open-entry'),
              onPressed: () => openFileUnified(context, ref, e),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-entry')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('★ NAS「文件」打开 /home/Drive 下的 .oslides ⇒ 落到 My Drive 的 OfficeSlidesPage', (
    tester,
  ) async {
    final t = FakeTransport({
      'SYNO.SynologyDrive.Files.get': {
        'file_id': '974347287371232766',
        'name': 'Dynamic.oslides',
        'type': 'file',
        'display_path': '/mydrive/Dynamic.oslides',
        'permanent_link': '19yWIOD27yPuEj72uzvkhqhQH4wX3Lka',
        'size': 9003452,
      },
      'SYNO.Office.Node.Encrypt.check': {'encrypted': false},
    }, {...FakeTransport.table, ..._apiTable});

    await _pump(tester, t, _entry('Dynamic.oslides', '/home/Drive/Dynamic.oslides'));

    // 统一后的落点：与「我的 Drive」完全同一个页面
    expect(
      find.byKey(const Key('office-slides-page')),
      findsOneWidget,
      reason: '★ 必须落到 OfficeSlidesPage（My Drive 的阅读器），不是原生降级视图',
    );
    expect(
      find.byKey(const Key('preview-office-native')),
      findsNothing,
      reason: '★ 不允许再落到只读原生降级查看器（那正是"两边不一样"）',
    );
  });

  testWidgets('非 Drive 可映射路径（/docker）⇒ 不冒充，仍走原来的原生预览', (tester) async {
    final t = FakeTransport({}, {...FakeTransport.table, ..._apiTable});
    await _pump(tester, t, _entry('Dynamic.oslides', '/docker/Dynamic.oslides'));

    expect(
      t.calls.any((c) => c['api'] == 'SYNO.SynologyDrive.Files'),
      isFalse,
      reason: '不猜映射：非个人空间路径不该去打 Drive',
    );
    expect(
      find.byKey(const Key('preview-office-native')),
      findsOneWidget,
      reason: '回落通道必须仍然可用（文件要能打开）',
    );
  });

  testWidgets('非 Office 原生文件（xlsx）⇒ 一律走原路径，不受分流影响', (tester) async {
    final t = FakeTransport({}, {...FakeTransport.table, ..._apiTable});
    await _pump(tester, t, _entry('预算.xlsx', '/home/Drive/预算.xlsx'));
    expect(
      t.calls.any((c) => c['api'] == 'SYNO.SynologyDrive.Files'),
      isFalse,
      reason: '只有 .odoc/.osheet/.oslides 三种才分流',
    );
  });
}
