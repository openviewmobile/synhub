// 「Office 文档只读」（batch ③ Office L1）的离线测试。
//
// 钉死的东西：
//   1. `SYNO.Office.File.extract` 的参数形态 —— **只发 `link_id`**
//      （真机实测 `path`/`id:`/`object_id` 全失败），版本只能 v1；
//   2. 回包 `{data:"<正文>"}` → 页面渲染成可选中的文本，并标明"只读·服务端抽取"；
//   3. 断网 → 报错 + 重试，不白屏、不假装有内容；
//   4. **没有 Drive link id 的 NAS 文件** → 不瞎调接口，说清原因并给"下载/交给系统"；
//   5. `Office.Info.get` 的版本串拼装（`3.7.2`）。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/office_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _officeTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Office.File': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Office.Info': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

FileEntryDto _docx({String path = 'drive:1'}) => FileEntryDto(
  path: path,
  // ★ 第 67 轮 D62：这里测的是「**服务端抽取正文**」那条预览通道，
  // 所以样本名必须选一个**仍走 `FilePreviewKind.office`** 的扩展名。
  // `.xlsx` 已改走内嵌网格（`officeSheet`）；**215 轮起 `.pptx`/`.ods`/`.odp`
  // 也改走内置只读查看器** ⇒ 这里换成仍在 office 那条路上的老二进制 `.ppt`。
  name: 'probe-doc.ppt',
  isDir: false,
  size: 947,
  mtime: 1789742646,
);

void main() {
  group('OfficeApi：参数与官方对齐', () {
    test('extract 只发 link_id、用 v1，回包 data 当正文', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._officeTable,
      });
      t.onCall = (params) => {'data': 'office probe 2026-09-18'};
      final api = await _loggedIn(t);
      final text = await OfficeApi(
        api,
      ).extract(linkId: '19wEMJG0KyQTlkshZgwjHzL48cT9JYKR');

      final call = t.calls.last;
      expect(call['api'], 'SYNO.Office.File');
      expect(call['method'], 'extract');
      expect(call['version'], '1', reason: 'Office.File 只有 v1');
      // ⚠️ 真机实测：只认 link_id。多发参数只会让服务端报 114/1000
      expect(call['link_id'], '19wEMJG0KyQTlkshZgwjHzL48cT9JYKR');
      expect(call.containsKey('path'), isFalse);
      expect(call.containsKey('object_id'), isFalse);
      expect(text, 'office probe 2026-09-18');
    });

    test('extract 的 data 不是字符串时也不炸', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._officeTable,
      });
      t.onCall = (params) => {
        'data': {'text': 'x'},
      };
      final api = await _loggedIn(t);
      final text = await OfficeApi(api).extract(linkId: 'l');
      expect(text, contains('x'));
    });

    test('Info.get 的版本串（3.7.2）与 schema 字段容错', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._officeTable,
      });
      t.onCall = (params) => {
        'uid': 1028,
        'username': 'demo_user',
        'version': {'major': '3', 'minor': 7, 'hotfix': '2'},
        'schema_doc': 13,
        'schema_sheet': 5,
        'schema_slide': 13,
      };
      final api = await _loggedIn(t);
      final info = await OfficeApi(api).info();
      expect(t.calls.last['method'], 'get');
      expect(info.uid, 1028);
      expect(info.username, 'demo_user');
      expect(info.version, '3.7.2');
      expect(info.schemaDoc, 13);
      expect(info.schemaSheet, 5);
    });
  });

  group('Office 只读预览页', () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      String? linkId,
      bool offline = false,
      String body = '第一段\n第二段',
    }) async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._officeTable,
      });
      t.onCall = (params) => {'data': body};
      if (offline) t.offlineKeys.add('SYNO.Office.File.extract');
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          officeApiProvider.overrideWithValue(OfficeApi(api)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: FilePreviewPage(entry: _docx(), officeLinkId: linkId),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return c;
    }

    testWidgets('有 link id → 服务端抽正文并渲染（只读标识 + 可选文本）', (tester) async {
      await pump(tester, linkId: '19wEMJG0KyQTlkshZgwjHzL48cT9JYKR');
      expect(find.textContaining('只读 · 服务端抽取的正文'), findsOneWidget);
      expect(find.textContaining('第一段'), findsOneWidget);
      expect(find.byType(SelectableText), findsWidgets);
    });

    testWidgets('抽取为空 → 说清"是空正文"并给系统打开的出路', (tester) async {
      await pump(tester, linkId: 'l', body: '   ');
      expect(find.textContaining('抽取到的是空正文'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsWidgets);
    });

    testWidgets('断网 → 报错 + 重试（不白屏、不假装有内容）', (tester) async {
      await pump(tester, linkId: 'l', offline: true);
      expect(find.text('重试'), findsOneWidget);
      expect(find.textContaining('Office 正文由服务端抽取'), findsOneWidget);
      expect(find.textContaining('第一段'), findsNothing);
    });

    testWidgets('Synology Office 自家格式（.osheet/.odoc/.oslides）也走服务端抽取', (
      tester,
    ) async {
      // 真机实测：这几个扩展名的文件在 Drive 里点开时，官方是内嵌打开的；
      // 安卓上没有第三方 App 认识它们，所以必须归到 Office 只读路径。
      await pump(tester, linkId: '19wsdGqZJ7KBnvrXXTVxBevMdFV8Klz0');
      expect(find.textContaining('只读 · 服务端抽取的正文'), findsOneWidget);
      expect(find.textContaining('第一段'), findsOneWidget);
    });

    testWidgets('没有 Drive link id 的 NAS 文件 → 不瞎调接口，讲清原因', (tester) async {
      await pump(tester);
      expect(find.textContaining('把文件放进「我的 Drive」'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsWidgets);
    });
  });
}
