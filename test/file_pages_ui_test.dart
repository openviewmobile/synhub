// 「文件」模块的附属页面：分享链接（只读管理）、后台任务、收藏、搜索。
//
// 这些页面和浏览页共用 `FakeTransport` 那一套：既断言渲染，也断言**发出去的请求**
// （分享链接删除要发 id 的 JSON 数组串、清理失效只调 clear_invalid 等 ——
// 这几条都是真机上踩过或差一步就踩的坑）。
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_link_share.dart';
import 'package:synhub/src/features/files/file_pages.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_link_expiry.dart';
import 'package:synhub/src/features/files/file_sheets.dart';
import 'package:synhub/src/core/ui/app_sheet.dart' show AppSheetAction;

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 能力表：只挑这几页要用到的接口（真机 `SYNO.API.Info` 的快照子集）
const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.FileStation.Sharing': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.FileStation.BackgroundTask': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.FileStation.Favorite': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Search': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  // 浏览页要用：列目录 + 能力探测（还顺带看 VirtualFolder 以决定要不要显示 Drive 源）
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.VirtualFolder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.BackgroundTask.list': <String, dynamic>{},
  // 任务中心里"停止任务"要按任务自己的 API 去调 stop
  'SYNO.FileStation.CopyMove': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  // M58 重试要重发原 api（如 Compress.start）
  'SYNO.FileStation.Compress': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.FileStation.DirSize': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Future<({FileStationApi fs, FakeTransport t, ChatDatabase db})> _boot(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, int> failures = const {},
}) async {
  // 带上 FakeTransport 自带的那张表（登录/加密相关），否则 login 会 102
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  return (fs: FileStationApi(api), t: t, db: db);
}

/// 不 dispose 容器（理由见 file_browse_ui_test.dart 顶部注释）
Future<void> _pump(
  WidgetTester tester,
  FileStationApi fs,
  ChatDatabase db,
  Widget page, {
  List<Object?> moreOverrides = const [],
}) async {
  final container = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(fs),
      ...moreOverrides.cast(),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// 搜索是"异步任务 + 轮询"：`Search.list` 之间夹着 400ms 的 `Future.delayed`，
/// 所以要一段一段推时钟，不能只 pump 一次。
Future<void> _pumpSearch(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// ★ r316：把轮询**跑满上限**（`_kSearchPollMax` = 90 次 × 400ms ≈ 36s）
/// —— 专门用来验"服务端一直没说搜完"时界面到底怎么说。
Future<void> _pumpSearchLong(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 96; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// 页面上发出去过的接口名（`api.method`）
Set<String> _calls(FakeTransport t, String prefix) => t.calls
    .map((c) => '${c['api']}.${c['method']}')
    .where((s) => s.startsWith(prefix))
    .toSet();

/// ★ r315：把"今天 HH:mm:ss"算成确定的时刻，避免用例写死日历日
/// （写死日历日 ⇒ 第二天就落到 `昨天` 分支，断言必然假红）。
DateTime _todayAt(int h, int m, int s) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, h, m, s);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('分享链接页（只读管理）', () {
    testWidgets('列出链接，失效/密码/有效期都写在副标题里', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': [
            {
              'id': 'L1',
              'name': '季度报告',
              'path': '/home/report.pdf',
              'isdir': false,
              'status': 'valid',
              'has_password': true,
              'date_expired': '2026-01-01',
            },
            {
              'id': 'L2',
              'name': '旧链接',
              'path': '/home/old',
              'isdir': true,
              'status': 'broken',
            },
          ],
          'total': 2,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());

      expect(find.text('季度报告'), findsOneWidget);
      expect(find.textContaining('有密码'), findsOneWidget);
      expect(find.textContaining('至 2026-01-01'), findsOneWidget);
      expect(find.textContaining('已失效'), findsOneWidget);
      // 只读：没有"新建链接"之类的入口
      expect(find.textContaining('新建'), findsNothing);
    });

    testWidgets('空态指向真正的创建入口（文件操作菜单）', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());
      expect(find.text('没有分享链接'), findsOneWidget);
      // 空态必须把用户**指到真入口**——分享链接确实能创建（文件/文件夹 ⋮ →「创建分享链接」），
      // 旧文案写"不提供新建入口"是假话，会让用户以为这个功能不存在（r301 真机发现）。
      expect(find.textContaining('创建分享链接'), findsOneWidget);
    });

    testWidgets('删除单个链接 → Sharing.delete，id 是 JSON 数组串', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': [
            {
              'id': 'L9',
              'name': '待删',
              'path': '/home/x',
              'isdir': false,
              'status': 'valid',
            },
          ],
          'total': 1,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());
      await tester.tap(find.byTooltip('删除链接'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final del = boot.t.calls.lastWhere(
        (c) => c['method'] == 'delete',
        orElse: () => const {},
      );
      expect(del['api'], 'SYNO.FileStation.Sharing');
      expect(
        del['id'],
        '["L9"]',
        reason: 'delete 收 JSON 数组串（APK: CompositeApiParameter("id", List)）',
      );
    });

    testWidgets('清理失效只调 clear_invalid（不再先发空 delete）', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());
      await tester.tap(find.byTooltip('清理失效链接'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        _calls(boot.t, 'SYNO.FileStation.Sharing'),
        contains('SYNO.FileStation.Sharing.clear_invalid'),
      );
      // 空数组的 delete 在真机上会 101，所以不该出现
      expect(boot.t.calls.where((c) => c['method'] == 'delete'), isEmpty);
    });

    // ⚠️ 这条用例**原先断言的是错的**：按 `delete` 的形状把 `id` 钉成 JSON
    // 数组，理由写的是"与 delete/getinfo 同一形状" —— 这个假设**双错**：
    // `getinfo` 同样不发数组。第 28 轮反编译官方 DS file 4.17.2-609 确认：
    //   `editShareLink`/`getShareLink` → `SingleApiParameter("id", p1)`（裸值）
    //   `deleteShareLinks(List)`       → `CompositeApiParameter`（数组）
    // ⇒ **这里是修正一个错误假设，不是"改代码迁就测试"。**
    testWidgets('M36 编辑：改密码 → Sharing.edit（id 是**裸字符串** + 新密码）', (
      tester,
    ) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': [
            {
              'id': 'L7',
              'name': '季度报告',
              'path': '/home/report.pdf',
              'isdir': false,
              'status': 'valid',
              'has_password': true,
              'date_expired': '2026-01-01',
            },
          ],
          'total': 1,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());

      await tester.tap(find.byTooltip('编辑分享链接'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('编辑分享链接'), findsWidgets);

      // 原本有密码 → 开关默认开；留空 = 保持，填了 = 换新密码
      await tester.enterText(find.byType(TextField), 'newpw');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final edit = boot.t.calls.lastWhere(
        (c) => c['method'] == 'edit',
        orElse: () => const {},
      );
      expect(edit['api'], 'SYNO.FileStation.Sharing');
      expect(edit['version'], '3');
      expect(
        edit['id'],
        'L7',
        reason: '★ 裸 id —— 不是 ["L7"]（旧假设错的；只有 delete 发数组）',
      );
      expect(edit['password'], 'newpw');
      // 没点有效期 chip → 不发 date_expired（保持原值）
      expect(edit.containsKey('date_expired'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('M36 编辑：移除密码 → Sharing.edit 发空串 password', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': [
            {
              'id': 'L8',
              'name': '旧链接',
              'path': '/home/x',
              'isdir': false,
              'status': 'valid',
              'has_password': true,
            },
          ],
          'total': 1,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());

      await tester.tap(find.byTooltip('编辑分享链接'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // 关掉「启用密码保护」开关 → 保存 = 移除密码（空串，未取证）
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final edit = boot.t.calls.lastWhere(
        (c) => c['method'] == 'edit',
        orElse: () => const {},
      );
      expect(edit['password'], '');
    });

    testWidgets('M37 发送：管理页把已有链接交给分享桥（不复制、不改服务端）', (tester) async {
      String? sentUrl;
      String? sentSubject;
      Future<bool> fake({required String url, required String subject}) async {
        sentUrl = url;
        sentSubject = subject;
        return true;
      }

      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': [
            {
              'id': 'L5',
              'name': '季度报告',
              'path': '/home/report.pdf',
              'url': 'https://nas.example.com:5001/sharing/abc',
              'isdir': false,
              'status': 'valid',
            },
          ],
          'total': 1,
          'offset': 0,
        },
      });
      await _pump(
        tester,
        boot.fs,
        boot.db,
        const FileShareLinksPage(),
        moreOverrides: [linkShareProvider.overrideWithValue(fake)],
      );
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(sentUrl, 'https://nas.example.com:5001/sharing/abc');
      expect(sentSubject, '季度报告');
      // 纯客户端动作：不该为它发任何写请求
      expect(boot.t.calls.where((c) => c['method'] == 'edit'), isEmpty);
    });
  });

  group('后台任务页（统一任务中心）', () {
    testWidgets('空态文案点出哪些操作会出现在这里', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': <dynamic>[],
          'total': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());
      expect(find.text('没有后台任务'), findsOneWidget);
      expect(find.textContaining('压缩'), findsWidgets);
    });

    testWidgets('进行中的任务显示进度、完成的显示"完成"、失败数也显示', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': [
            {
              'taskid': 'T1',
              'api': 'SYNO.FileStation.Compress',
              'method': 'start',
              'finished': false,
              'progress': 0.42,
              'path': '/home/a.zip',
            },
            {
              'taskid': 'T2',
              'api': 'SYNO.FileStation.CopyMove',
              'method': 'start',
              'finished': true,
              'progress': 1.0,
              'path': '/home/b',
              'processing_path': '/home/b/c',
              'errors': [
                {'path': '/home/b/x', 'code': 105},
              ],
            },
          ],
          'total': 2,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());

      expect(find.text('42%'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      expect(find.text('1 个文件失败'), findsOneWidget);
      // 完成的没有进度条，进行中的有
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('第 304 轮 进行中的任务要摊开"已经跑了多久"（卡死任务唯一的失败面）', (tester) async {
      // 真机 r303：卡死的压缩任务永远 `0%` + 「任务错误：没有错误」。服务端唯一
      // 下发的事实是 `crtime` ⇒ 客户端把它变成"已运行 N 分钟"，让"1 秒的任务跑了
      // 25 分钟"可见。断言钉**服务端时间差**（25 分钟），不钉"某文案在不在"。
      final now = DateTime.now();
      String ago(Duration d) =>
          '${now.subtract(d).millisecondsSinceEpoch ~/ 1000}';
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': [
            {
              'taskid': 'T1',
              'api': 'SYNO.FileStation.Compress',
              'method': 'start',
              'finished': false,
              'progress': 0.0,
              'path': '/home/stuck.zip',
              'crtime': ago(const Duration(minutes: 25)),
            },
            {
              'taskid': 'T2',
              'api': 'SYNO.FileStation.Compress',
              'method': 'start',
              'finished': true,
              'progress': 1.0,
              'path': '/home/done.zip',
              'crtime': ago(const Duration(minutes: 25)),
            },
            {
              'taskid': 'T3',
              'api': 'SYNO.FileStation.Compress',
              'method': 'start',
              'finished': false,
              'progress': 0.1,
              'path': '/home/noCrtime.zip',
            },
          ],
          'total': 3,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());

      // 卡住的那个：0% + 已运行 25 分钟
      expect(find.text('已运行 25 分钟'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);
      // 反向：**完成**的任务不显示运行时长（同一个 crtime，不许显示）
      // 反向：**没有 crtime** 的任务不显示（不许编造时长）
      expect(find.textContaining('已运行'), findsOneWidget);
    });

    testWidgets('★ r315 昨天的时间显示「昨天」（不带时钟，与文件列表同一套规则）', (
      tester,
    ) async {
      final y = _todayAt(2, 15, 41).subtract(const Duration(days: 1));
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': [
            {
              'taskid': 'T2',
              'api': 'SYNO.FileStation.Compress',
              'method': 'start',
              'finished': true,
              'progress': 1.0,
              'path': '/home/y.zip',
              'crtime': '${y.millisecondsSinceEpoch ~/ 1000}',
            },
          ],
          'total': 1,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());
      await tester.tap(find.text('/home/y.zip'));
      await tester.pumpAndSettle();
      expect(find.textContaining('昨天'), findsOneWidget);
      // 反向：昨天**不带**时钟（`formatFileTime` 的既有规则，不是本轮新造的）
      expect(find.textContaining('02:15'), findsNothing);
      // 更不许退回裸 epoch 秒
      expect(find.text('${y.millisecondsSinceEpoch ~/ 1000}'), findsNothing);
    });

    testWidgets('第 304 轮 任务详情的时间是人读的，不是裸 epoch 秒', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': [
            {
              'taskid': 'T1',
              'api': 'SYNO.FileStation.Compress',
              'method': 'start',
              'finished': true,
              'progress': 1.0,
              'path': '/home/a.zip',
              // ★ r315 修正**日期定时炸弹**：原来写死 `2026-10-08 02:15:41`，
              // 而 `formatFileTime` 的规则是「今天 → 今天 HH:mm」「昨天 → **昨天**（不带时钟）」
              // 「同年 → MM-DD」⇒ 到了 10-09 这天 diff=1，显示"昨天"，
              // 断言 '02:15' 必然 0 命中（**不是 App 坏了，是用例写死了日历日**）。
              // 改成"相对今天"，永远落在「今天」分支。
              'crtime':
                  '${_todayAt(2, 15, 41).millisecondsSinceEpoch ~/ 1000}',
            },
          ],
          'total': 1,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());
      await tester.tap(find.text('/home/a.zip'));
      await tester.pumpAndSettle();

      // 键名照旧在，值变成相对时间
      expect(find.text('crtime'), findsOneWidget);
      expect(find.textContaining('02:15'), findsOneWidget);
      expect(
        find.text(
          '${_todayAt(2, 15, 41).millisecondsSinceEpoch ~/ 1000}',
        ),
        findsNothing,
        reason: '裸 epoch 秒不许再上屏',
      );
    });

    testWidgets('进行中的任务给「停止」，taskid 发裸字符串', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': [
            {
              'taskid': 'FileStation_ABC',
              'api': 'SYNO.FileStation.CopyMove',
              'method': 'start',
              'finished': false,
              'progress': 0.1,
              'path': '/home/a',
            },
          ],
          'total': 1,
        },
        'SYNO.FileStation.CopyMove.stop': <String, dynamic>{},
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());
      await tester.tap(find.byTooltip('停止任务'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final stop = boot.t.calls.lastWhere(
        (c) => c['method'] == 'stop',
        orElse: () => const {},
      );
      expect(stop['api'], 'SYNO.FileStation.CopyMove');
      expect(
        stop['taskid'],
        'FileStation_ABC',
        reason: '裸字符串，不是 ["FileStation_ABC"]',
      );
    });

    testWidgets('完成的 / 不支持的 API 没有「停止」按钮', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': [
            {
              'taskid': 'T1',
              'api': 'SYNO.FileStation.Compress',
              'method': 'start',
              'finished': true,
              'progress': 1.0,
              'path': '/home/a.zip',
            },
            {
              'taskid': 'T2',
              'api': 'SYNO.FileStation.SomeOther',
              'method': 'start',
              'finished': false,
              'progress': 0.5,
              'path': '/home/b',
            },
          ],
          'total': 2,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());
      expect(find.byTooltip('停止任务'), findsNothing);
    });

    testWidgets('点任务行 → 详情弹层有「后台任务详情」标题 + 参数/错误分组', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': [
            {
              'taskid': 'T1',
              'api': 'SYNO.FileStation.Compress',
              'method': 'start',
              'finished': true,
              'progress': 1.0,
              'path': '/home/a.zip',
              'params': {'format': 'zip'},
              'errors': [
                {'path': '/home/b/x', 'code': 105},
              ],
            },
          ],
          'total': 1,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());
      await tester.tap(find.text('压缩'));
      await tester.pumpAndSettle();

      // C5 遗留的 `fsC5TaskDetail` 接上 UI：这是"官方 DETAIL"对应的弹层标题
      expect(find.byKey(const Key('file-task-detail-title')), findsOneWidget);
      expect(find.text('后台任务详情'), findsOneWidget);
      expect(find.text('任务参数'), findsOneWidget);
      expect(find.text('任务错误'), findsOneWidget);
      expect(find.text('format'), findsOneWidget, reason: '参数真的列出来了');
    });

    // ★★ 第 303 轮真机缺陷：`BackgroundTask/list` 的 `params` 快照会把压缩/解压的
    // **口令原样回下来**（真机逐字：`password  r303Zz9pw`），详情页照原样渲染
    // ⇒ 屏幕上出现明文密码。修法：只对**显示**打码，数据层不动（重试要用原值）。
    testWidgets('第 303 轮 任务详情的口令类参数必须打码（非口令参数照旧显示）', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': [
            {
              'taskid': 'T-SECRET',
              'api': 'SYNO.FileStation.Compress',
              'method': 'start',
              'finished': true,
              'progress': 1.0,
              'path': '/home/r303sec2.zip',
              'params': {
                'password': 'r303Zz9pw',
                // ★ 真机形状：DSM 7.4.1 的快照**没有** password 键，口令被记在
                // `codepage` 上（逐字 `codepage  r303Zz9pw`）⇒ 两层判据都要盖住。
                'codepage': 'r303Zz9pw',
                'format': 'zip',
                'dest_file_path': '/home/r303sec2.zip',
                // 17 字符的长键名 —— 真机上曾被截成 `dest_folder_p…`
                'dest_folder_path': '/home/r303sec2',
              },
            },
          ],
          'total': 1,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());
      await tester.tap(find.text('压缩'));
      await tester.pumpAndSettle();

      expect(
        find.text('r303Zz9pw'),
        findsNothing,
        reason: '明文口令**绝对**不许出现在界面上（第 303 轮真机缺陷：'
            '`password` 键与错位回显的 `codepage` 键两处都要挡住）',
      );
      expect(find.text('已隐藏（口令类参数不显示明文）'), findsNWidgets(2));
      // 反向验证：非口令参数不能被一起打码，否则详情页就失去意义
      expect(find.text('format'), findsOneWidget);
      expect(find.text('zip'), findsOneWidget);
      expect(find.text('/home/r303sec2.zip'), findsWidgets);

      // ★ 第 303 轮附带修：参数名原来钉死 88dp（`TelemetryLabel` maxLines:1 +
      // 省略号）⇒ 真机 `dest_folder_path` 被截成 `dest_folder_p…`。
      // 改成按比例分栏（4:6）后，"键名那一栏"必然宽于 88dp —— 钉这个**机制量**，
      // 而不是钉"字符串还在不在"（`find.text` 看不出视觉截断）。
      expect(find.text('dest_folder_path'), findsOneWidget);
      expect(
        tester.getSize(find.text('dest_folder_path')).width,
        greaterThan(88),
        reason: '键名栏必须是弹性宽度；钉死 88dp 会把长参数名截掉',
      );
    });

    testWidgets('M58 失败任务详情给「重试」→ 重发原 api + 原参数快照（不臆造）', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': [
            {
              'taskid': 'T-FAIL',
              'api': 'SYNO.FileStation.Compress',
              'method': 'start',
              'finished': true,
              'progress': 1.0,
              'path': '/home/a',
              'params': {
                'path': '["/home/a"]',
                'dest_file_path': '/home/a.zip',
                'format': 'zip',
                'level': 'moderate',
                'mode': 'add',
              },
              'errors': [
                {'path': '/home/a', 'code': 105},
              ],
            },
          ],
          'total': 1,
        },
        'SYNO.FileStation.Compress.start': {'taskid': 'T-RETRY'},
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());
      await tester.tap(find.text('压缩'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('file-task-retry')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('file-task-retry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final retry = boot.t.calls.lastWhere(
        (c) =>
            c['api'] == 'SYNO.FileStation.Compress' && c['method'] == 'start',
        orElse: () => const {},
      );
      expect(retry['path'], '["/home/a"]');
      expect(retry['dest_file_path'], '/home/a.zip');
      expect(retry['mode'], 'add');
      expect(find.text('已重新提交任务'), findsOneWidget);
    });

    testWidgets('M58 参数快照不全的失败任务：没有「重试」按钮', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': [
            {
              'taskid': 'T-NOPLAN',
              'api': 'SYNO.FileStation.CopyMove',
              'method': 'start',
              'finished': true,
              'progress': 1.0,
              'path': '/home/a',
              'params': {'remove_src': true},
              'errors': [
                {'path': '/home/a', 'code': 408},
              ],
            },
          ],
          'total': 1,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());
      await tester.tap(find.text('移动'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('file-task-retry')), findsNothing);
    });

    testWidgets('清理已完成 → 必须先二次确认；取消则一个写请求都不发', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': <dynamic>[],
          'total': 0,
        },
        'SYNO.FileStation.BackgroundTask.clear_finished': <String, dynamic>{},
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());

      await tester.tap(find.byTooltip('清理已完成'));
      await tester.pumpAndSettle();

      // 官方 APK `res/values-zh-rCN/strings.xml:798` 的 `sure_to_clear_finish` 逐字
      expect(find.text('已完成的任务会被清除。您确定要继续吗？'), findsOneWidget);
      // ⚠️ 只弹层、还没确认 ⇒ 绝不能发 clear_finished（破坏性写接口）
      expect(
        _calls(boot.t, 'SYNO.FileStation.BackgroundTask'),
        isNot(contains('SYNO.FileStation.BackgroundTask.clear_finished')),
      );

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        _calls(boot.t, 'SYNO.FileStation.BackgroundTask'),
        isNot(contains('SYNO.FileStation.BackgroundTask.clear_finished')),
        reason: '点了取消还发写请求 = 二次确认形同虚设',
      );
    });

    testWidgets('清理已完成 → 确认后才真的发 clear_finished', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': <dynamic>[],
          'total': 0,
        },
        'SYNO.FileStation.BackgroundTask.clear_finished': <String, dynamic>{},
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());

      await tester.tap(find.byTooltip('清理已完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '清理已完成'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        _calls(boot.t, 'SYNO.FileStation.BackgroundTask'),
        contains('SYNO.FileStation.BackgroundTask.clear_finished'),
      );
    });

    testWidgets('任务内部 id（taskid）不上屏 —— 行与详情弹层都不许露', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': [
            {
              'taskid': 'FileStation_ZzInternalId42',
              'api': 'SYNO.FileStation.Compress',
              'method': 'start',
              'finished': true,
              'progress': 1.0,
              'path': '/home/a.zip',
            },
          ],
          'total': 1,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileTasksPage());
      expect(find.textContaining('FileStation_ZzInternalId42'), findsNothing);

      await tester.tap(find.text('压缩'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('FileStation_ZzInternalId42'),
        findsNothing,
        reason: 'taskid 只允许出现在 Key / 请求 / 断言里',
      );
    });
  });

  group('收藏页', () {
    testWidgets('读 favorites 键渲染（不是 files/shares）', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Favorite.list': {
          'favorites': [
            {
              'name': '项目',
              'path': '/home/proj',
              'isdir': true,
              'status': 'valid',
            },
          ],
          'total': 1,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileFavoritesPage());
      expect(find.text('项目'), findsOneWidget);
    });

    testWidgets('空态给指路文案', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Favorite.list': {
          'favorites': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileFavoritesPage());
      expect(find.text('还没有收藏'), findsOneWidget);
      expect(find.textContaining('加入收藏'), findsWidgets);
    });

    testWidgets('取消收藏 → Favorite.delete 带 JSON 数组串，并重新拉列表', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Favorite.list': {
          'favorites': [
            {
              'name': '项目',
              'path': '/home/proj',
              'isdir': true,
              'status': 'valid',
            },
          ],
          'total': 1,
          'offset': 0,
        },
        'SYNO.FileStation.Favorite.delete': <String, dynamic>{},
      });
      await _pump(tester, boot.fs, boot.db, const FileFavoritesPage());

      await tester.tap(find.text('项目'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('取消收藏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final del = boot.t.calls.lastWhere(
        (c) =>
            c['api'] == 'SYNO.FileStation.Favorite' && c['method'] == 'delete',
        orElse: () => const {},
      );
      expect(del['path'], '["/home/proj"]');
      // 删完要重新列一次（收藏页不能停留在旧数据上）
      expect(
        boot.t.calls
            .where(
              (c) =>
                  c['api'] == 'SYNO.FileStation.Favorite' &&
                  c['method'] == 'list',
            )
            .length,
        greaterThanOrEqualTo(2),
      );
    });
    testWidgets('行尾星标一点即取消收藏 —— 文件也走这条路（不必先进预览）', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Favorite.list': {
          'favorites': [
            {
              'name': '报告.pdf',
              'path': '/home/报告.pdf',
              'isdir': false,
              'status': 'valid',
            },
          ],
          'total': 1,
          'offset': 0,
        },
        'SYNO.FileStation.Favorite.delete': <String, dynamic>{},
      });
      await _pump(tester, boot.fs, boot.db, const FileFavoritesPage());

      // 已收藏 → 行尾实心星（"怎么删收藏"的可见入口）
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.star_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final del = boot.t.calls.lastWhere(
        (c) =>
            c['api'] == 'SYNO.FileStation.Favorite' && c['method'] == 'delete',
        orElse: () => const {},
      );
      expect(del['path'], '["/home/报告.pdf"]');
      expect(find.text('已取消收藏'), findsOneWidget);
    });

    testWidgets(
      'M50 重排：上移后保存 → Favorite/replace_all v2 的 path/name 两个平行数组（顺序=重排后）',
      (tester) async {
        final boot = await _boot({
          'SYNO.FileStation.Favorite.list': {
            'favorites': [
              {
                'name': 'A',
                'path': '/home/a',
                'isdir': true,
                'status': 'valid',
              },
              {
                'name': 'B',
                'path': '/home/b',
                'isdir': true,
                'status': 'valid',
              },
            ],
            'total': 2,
            'offset': 0,
          },
          'SYNO.FileStation.Favorite.replace_all': <String, dynamic>{},
        });
        await _pump(tester, boot.fs, boot.db, const FileFavoritesPage());

        await tester.tap(find.byKey(const Key('file-favorites-reorder')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('favorite-reorder-dialog')),
          findsOneWidget,
        );

        // 把 B 上移到 A 前面，然后保存
        await tester.tap(find.byKey(const Key('favorite-up-1')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('favorite-reorder-save')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final save = boot.t.calls.lastWhere(
          (c) => c['method'] == 'replace_all',
          orElse: () => const {},
        );
        expect(save['api'], 'SYNO.FileStation.Favorite');
        expect(save['version'], '2');
        // 真机取证形态：两个 JSON 数组串、同序；重排后 B 在 A 前
        expect(save['path'], '["/home/b","/home/a"]');
        expect(save['name'], '["B","A"]');
        expect(find.text('收藏顺序已保存'), findsOneWidget);
        expect(find.textContaining('收藏顺序保存失败'), findsNothing);
      },
    );

    testWidgets('M50 保存失败（真机 400）→ 明确提示、不当成功、不刷新（原顺序保留）', (tester) async {
      final boot = await _boot(
        {
          'SYNO.FileStation.Favorite.list': {
            'favorites': [
              {
                'name': 'A',
                'path': '/home/a',
                'isdir': true,
                'status': 'valid',
              },
              {
                'name': 'B',
                'path': '/home/b',
                'isdir': true,
                'status': 'valid',
              },
            ],
            'total': 2,
            'offset': 0,
          },
        },
        failures: {'SYNO.FileStation.Favorite.replace_all': 400},
      );
      await _pump(tester, boot.fs, boot.db, const FileFavoritesPage());
      final listCallsBefore = boot.t.calls
          .where(
            (c) =>
                c['method'] == 'list' &&
                c['api'] == 'SYNO.FileStation.Favorite',
          )
          .length;

      await tester.tap(find.byKey(const Key('file-favorites-reorder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('favorite-up-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('favorite-reorder-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 400 按"保存失败"处理，且**不能**套用 DsmErrorCode 的 400（那是"密码错误"）
      expect(find.textContaining('收藏顺序保存失败'), findsOneWidget);
      expect(find.textContaining('服务端拒绝了这组参数'), findsOneWidget);
      expect(find.text('收藏顺序已保存'), findsNothing);
      // 失败不刷新 → 界面上的顺序没有被服务端覆盖
      expect(
        boot.t.calls
            .where(
              (c) =>
                  c['method'] == 'list' &&
                  c['api'] == 'SYNO.FileStation.Favorite',
            )
            .length,
        listCallsBefore,
        reason: '保存失败不该再拉一次列表（列表会覆盖成服务端顺序）',
      );
    });

    testWidgets('M51 固定「个人文件夹」入口 → 打开 /home（List.list folder_path=/home）', (
      tester,
    ) async {
      final boot = await _boot({
        'SYNO.FileStation.Favorite.list': {
          'favorites': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
        'SYNO.FileStation.List.list': {
          'files': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileFavoritesPage());

      expect(find.byKey(const Key('file-home-entry')), findsOneWidget);
      // 空收藏时固定入口仍在（用户不会因为"没有收藏"而找不到个人文件夹）
      expect(find.text('还没有收藏'), findsOneWidget);

      await tester.tap(find.byKey(const Key('file-home-entry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final list = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.List' && c['method'] == 'list',
        orElse: () => const {},
      );
      expect(list['folder_path'], '/home');
    });
  });

  group('搜索页', () {
    testWidgets('输入关键词 → Search.start + list，结果渲染', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Search.start': {'taskid': 'ST1', 'offset': 0},
        'SYNO.FileStation.Search.list': {
          'files': [
            {
              'name': 'report.pdf',
              'path': '/home/report.pdf',
              'isdir': false,
              'additional': {'size': 2048},
            },
          ],
          'total': 1,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileSearchPage());

      expect(find.text('输入关键词开始搜索'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'report');
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await _pumpSearch(tester);

      final start = boot.t.calls.firstWhere(
        (c) => c['method'] == 'start',
        orElse: () => const {},
      );
      expect(start['api'], 'SYNO.FileStation.Search');
      expect(start['pattern'], 'report');
      expect(find.text('report.pdf'), findsOneWidget);
    });

    testWidgets('搜不到时区分"没搜过"和"没找到"', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Search.start': {'taskid': 'ST2', 'offset': 0},
        'SYNO.FileStation.Search.list': {
          'files': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileSearchPage());
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await _pumpSearch(tester);

      expect(find.text('没有找到匹配的文件'), findsOneWidget);
    });

    // ★★★ r316 真机抓到的**假否定**：`Files → NAS files → 搜索` 搜 `Download`
    // （`/home` 下真有这个目录）第一次命中、清空重搜却回 `No matching files`，
    // 再等 25s 依旧 —— 那一刻服务端**从没说过** `finished:true`。
    // 两条守卫（一正一反）钉住"只有服务端说搜完才允许说没有"。
    testWidgets('r316 服务端没说完（finished:false）→ 不许说"没有找到"，给"仍在进行"+重试', (
      tester,
    ) async {
      final boot = await _boot({
        'SYNO.FileStation.Search.start': {'taskid': 'ST9', 'offset': 0},
        'SYNO.FileStation.Search.list': {
          'files': <dynamic>[],
          'total': 0,
          'offset': 0,
          'finished': false,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileSearchPage());
      await tester.enterText(find.byType(TextField), 'Download');
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await _pumpSearchLong(tester);

      expect(
        find.text('没有找到匹配的文件'),
        findsNothing,
        reason: '服务端一次都没说 finished:true ⇒ 界面不许下"没有"的结论',
      );
      expect(find.text('搜索仍在进行'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget, reason: '必须给用户出口，不能死转圈');
      final lists = boot.t.calls.where((c) => c['method'] == 'list').length;
      expect(lists, greaterThanOrEqualTo(90));
    });

    testWidgets('r316 服务端说 finished:true 且 0 条 → 才允许说"没有找到"（真 0 命中）', (
      tester,
    ) async {
      final boot = await _boot({
        'SYNO.FileStation.Search.start': {'taskid': 'ST10', 'offset': 0},
        'SYNO.FileStation.Search.list': {
          'files': <dynamic>[],
          'total': 0,
          'offset': 0,
          'finished': true,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileSearchPage());
      await tester.enterText(find.byType(TextField), 'zzz-not-exist');
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await _pumpSearchLong(tester);

      expect(find.text('没有找到匹配的文件'), findsOneWidget);
      expect(find.text('搜索仍在进行'), findsNothing);
      // r316：服务端说"真 0 命中"时，空态要给出**出路**（页面里已有的全局搜索）
      expect(find.textContaining('服务端文件索引可能滞后'), findsOneWidget);
      final lists = boot.t.calls.where((c) => c['method'] == 'list').length;
      expect(lists, 1);
    });

    testWidgets('搜索失败 → 显示文件模块的文案（不是"账号已停用"）', (tester) async {
      final boot = await _boot(
        {
          'SYNO.FileStation.Search.start': {'taskid': 'ST3', 'offset': 0},
        },
        failures: {'SYNO.FileStation.Search.start': 401},
      );
      await _pump(tester, boot.fs, boot.db, const FileSearchPage());
      await tester.enterText(find.byType(TextField), 'x');
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await _pumpSearch(tester);

      expect(find.text('搜索失败'), findsOneWidget);
      expect(find.textContaining('没有权限访问该位置'), findsOneWidget);
      expect(find.textContaining('账号已停用'), findsNothing);
    });
  });

  // ==================================================================
  // r121：搜索根**不许**是 `/`
  //
  // 真机像素 + 宿主只读探针：`Search:start` 传 `folder_path='/'` 时
  // `Citizen`/`home`/`home*`/`mp4` **全部 0 命中**，而 `/home`、`/home/Video`
  // 都能命中 ⇒ 原来写死 `'/'` 的搜索等于"永远搜不到"。
  // ==================================================================
  group('r121 搜索根', () {
    testWidgets('带浏览上下文：folder_path 用**当前目录**，不是 `/`', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Search.start': {'taskid': 'SR1', 'offset': 0},
        'SYNO.FileStation.Search.list': {
          'files': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
      });
      await _pump(
        tester,
        boot.fs,
        boot.db,
        const FileSearchPage(folderPath: '/home/Video'),
      );
      await tester.enterText(find.byType(TextField), 'Citizen');
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await _pumpSearch(tester);

      final start = boot.t.calls.firstWhere(
        (c) => c['method'] == 'start',
        orElse: () => const {},
      );
      expect(start['api'], 'SYNO.FileStation.Search');
      expect(
        start['folder_path'],
        '/home/Video',
        reason: '搜索根必须跟着当前目录走',
      );
    });

    testWidgets('没有浏览上下文：回落到 /home，**绝不**是 `/`', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Search.start': {'taskid': 'SR2', 'offset': 0},
        'SYNO.FileStation.Search.list': {
          'files': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileSearchPage());
      await tester.enterText(find.byType(TextField), 'report');
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await _pumpSearch(tester);

      final start = boot.t.calls.firstWhere(
        (c) => c['method'] == 'start',
        orElse: () => const {},
      );
      expect(start['folder_path'], kFileSearchDefaultRoot);
      expect(
        start['folder_path'],
        isNot('/'),
        reason: '`/` 在真机上对任何关键字都是 0 命中（NAS 不认它当搜索根）',
      );
    });
  });

  group('搜索页高级筛选（P0-b）', () {
    testWidgets('类型=图片 + 大小范围 → extension 取官方清单、size 换算成字节', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Search.start': {'taskid': 'SF1', 'offset': 0},
        'SYNO.FileStation.Search.list': {
          'files': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileSearchPage());

      await tester.tap(find.byTooltip('筛选'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('图片'));
      await tester.pump();
      // 搜索页自己的关键词框还在树里(0)；面板里是 最小(1) / 最大(2) / 所有者(3)
      await tester.enterText(find.byType(TextField).at(1), '1');
      await tester.enterText(find.byType(TextField).at(2), '10');
      await tester.tap(find.text('应用'));
      await _pumpSearch(tester);

      final start = boot.t.calls.firstWhere(
        (c) => c['api'] == 'SYNO.FileStation.Search' && c['method'] == 'start',
        orElse: () => const {},
      );
      expect(start['extension'], contains('jpg'));
      expect(start['extension'], contains('png'));
      expect(start.containsKey('filetype'), isFalse);
      // 官方 `SearchOptionsFragment`：MB × 1048576
      expect(start['size_from'], 1 * 1048576);
      expect(start['size_to'], 10 * 1048576);
    });

    testWidgets('类型=文件夹 → filetype=dir（不发 extension）', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Search.start': {'taskid': 'SF2', 'offset': 0},
        'SYNO.FileStation.Search.list': {
          'files': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileSearchPage());

      await tester.tap(find.byTooltip('筛选'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('文件夹'));
      await tester.pump();
      await tester.tap(find.text('应用'));
      await _pumpSearch(tester);

      final start = boot.t.calls.firstWhere(
        (c) => c['api'] == 'SYNO.FileStation.Search' && c['method'] == 'start',
        orElse: () => const {},
      );
      expect(start['filetype'], 'dir');
      expect(start.containsKey('extension'), isFalse);
    });

    testWidgets('自定义扩展名 + 所有者 → extension/owner 原样发出', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Search.start': {'taskid': 'SF3', 'offset': 0},
        'SYNO.FileStation.Search.list': {
          'files': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileSearchPage());

      await tester.tap(find.byTooltip('筛选'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('自定义扩展名'));
      await tester.pump();
      // 关键词(0) / 扩展名(1) / 最小(2) / 最大(3) / 所有者(4)
      await tester.enterText(find.byType(TextField).at(1), 'pdf,docx');
      await tester.enterText(find.byType(TextField).at(4), 'alice');
      await tester.tap(find.text('应用'));
      await _pumpSearch(tester);

      final start = boot.t.calls.firstWhere(
        (c) => c['api'] == 'SYNO.FileStation.Search' && c['method'] == 'start',
        orElse: () => const {},
      );
      expect(start['extension'], 'pdf,docx');
      expect(start['owner'], 'alice');
    });

    testWidgets('最小大小 > 最大大小 → 面板内报错，不发请求', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Search.start': {'taskid': 'SF4', 'offset': 0},
      });
      await _pump(tester, boot.fs, boot.db, const FileSearchPage());

      await tester.tap(find.byTooltip('筛选'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).at(1), '20');
      await tester.enterText(find.byType(TextField).at(2), '5');
      await tester.tap(find.text('应用'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('最小大小不能大于最大大小'), findsOneWidget);
      expect(
        boot.t.calls.where((c) => c['api'] == 'SYNO.FileStation.Search'),
        isEmpty,
      );
    });

    test('修改时间换算：起始当天 0 点、结束当天 23:59:59（官方 getTimestampString）', () {
      final filter = FileSearchFilter(
        mtimeFrom: DateTime(2026, 1, 2, 15, 30),
        mtimeTo: DateTime(2026, 1, 9, 8, 0),
      );
      expect(
        filter.mtimeFromSeconds,
        DateTime(2026, 1, 2).millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        filter.mtimeToSeconds,
        DateTime(2026, 1, 10).millisecondsSinceEpoch ~/ 1000 - 1,
      );
    });
  });

  group('从收藏/搜索跳进浏览页', () {
    testWidgets('initialPath 直接把目录栈补全，并请求那个目录', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.List.list': {
          'files': [
            {
              'name': 'b.txt',
              'path': '/home/Drive/b.txt',
              'isdir': false,
              'additional': {'size': 5},
            },
          ],
          'total': 1,
          'offset': 0,
        },
        'SYNO.FileStation.VirtualFolder.list': {
          'folders': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
        'SYNO.FileStation.Info.get': <String, dynamic>{},
        'SYNO.FileStation.BackgroundTask.list': {
          'tasks': <dynamic>[],
          'total': 0,
        },
      });
      final container = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(boot.db),
          fileApiProvider.overrideWithValue(boot.fs),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: FileBrowsePage(initialPath: '/home/Drive'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 请求的是 /home/Drive（而不是根）
      final liste = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.List' && c['method'] == 'list',
        orElse: () => const {},
      );
      expect(liste['folder_path'], '/home/Drive');
      // 面包屑补齐到 /home/Drive，文件也渲染出来
      expect(find.text('Drive'), findsWidgets);
      expect(find.text('b.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // r306：真机把"照抄 list 解析 getinfo"打回原形 —— `getinfo` 的回包**不是**
  // `{links:[…]}`（真机 `success:true` 却 0 条）。这一组钉住形状容错本身。
  group('r306 getinfo 回包形状 / 二维码 data URI', () {
    test('parseShareLinkInfo：三种形状都收；都不是 ⇒ 空（= 服务端没说）', () {
      // ① 扁平单体（真机遇到的那种）
      final flat = parseShareLinkInfo({
        'id': 'L1',
        'url': 'https://gofile.me/7KwTC/L1',
        'has_password': true,
        'date_expired': '2026-10-09',
      });
      expect(flat.length, 1);
      expect(flat.first.id, 'L1');
      expect(flat.first.hasPassword, isTrue);
      expect(flat.first.dateExpired, '2026-10-09');

      // ② 包一层
      expect(parseShareLinkInfo({'link': {'id': 'L2'}}).single.id, 'L2');
      expect(parseShareLinkInfo({'info': {'id': 'L3'}}).single.id, 'L3');
      // ③ 与 list 同形
      expect(parseShareLinkInfo({'links': [{'id': 'L4'}]}).single.id, 'L4');
      // ④ 都不是 ⇒ 空列表：**"服务端没说"不是"没密码"**
      expect(parseShareLinkInfo({'success': true}), isEmpty);
    });

    test('缺键 ≠ false/空：`expiryKnown`/`passwordKnown` 必须分开', () {
      // 缺键 = 服务端没说
      const omitted = ShareLinkDto(id: 'L1');
      expect(omitted.expiryKnown, isFalse);
      expect(omitted.passwordKnown, isFalse);
      // 键在但空/假 = 服务端明确说"永久 / 没密码"
      final told = parseShareLinkInfo({
        'id': 'L2',
        'has_password': false,
        'date_expired': '',
      }).single;
      expect(told.passwordKnown, isTrue);
      expect(told.expiryKnown, isTrue);
      expect(told.hasPassword, isFalse);
      expect(told.dateExpired, isEmpty);
    });

    testWidgets('服务端**整块缺字段** ⇒ 显示"服务端未返回"，不替它说"永久/没密码"', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': [
            {
              'id': 'L1',
              'name': 'x.txt',
              'path': '/home/x.txt',
              'isdir': false,
              'status': 'valid',
            },
          ],
          'total': 1,
          'offset': 0,
        },
        // 只有 id/url：没有 has_password、没有 date_expired
        'SYNO.FileStation.Sharing.getinfo': {
          'id': 'L1',
          'url': 'https://gofile.me/7KwTC/L1',
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());
      await tester.tap(find.byKey(const Key('share-link-row-L1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('服务端未返回'), findsNWidgets(2), reason: '密码与有效期各一处');
      expect(find.text('永久'), findsNothing);
      expect(find.text('没有'), findsNothing);
    });

    test('qrImageBytes：data URI 解出字节；非 data URI / 坏 base64 ⇒ null', () {
      final png = base64Encode(const [1, 2, 3, 4]);
      expect(qrImageBytes('data:image/png;base64,$png'), [1, 2, 3, 4]);
      expect(qrImageBytes('https://nas/qr.png'), isNull);
      expect(qrImageBytes('data:image/png;base64,!!!'), isNull);
      expect(qrImageBytes(''), isNull);
    });

    testWidgets('详情面板：二维码解成图片显示，**不**把 base64 铺满屏', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': [
            {
              'id': 'L1',
              'name': 'x.txt',
              'path': '/home/x.txt',
              'isdir': false,
              'status': 'valid',
            },
          ],
          'total': 1,
          'offset': 0,
        },
        'SYNO.FileStation.Sharing.getinfo': {
          'id': 'L1',
          'url': 'https://gofile.me/7KwTC/L1',
          'qrcode': 'data:image/png;base64,${base64Encode(const [1, 2, 3, 4])}',
          'has_password': true,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());
      await tester.tap(find.byKey(const Key('share-link-row-L1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('share-link-detail-qr')), findsOneWidget);
      expect(find.textContaining('base64,'), findsNothing);
      // 扁平单体形状也被读进来了（url 上屏）
      expect(
        find.textContaining('https://gofile.me/7KwTC/L1'),
        findsOneWidget,
      );
    });
  });

  // r306：区分"服务端说…"与"服务端没说"；并要求到期时间按官方格式发。
  group('r306 到期时间格式 / 缺键语义', () {
    test('shareLinkExpiryWire：官方**安卓**格式 `yyyy-MM-dd`，永久不发', () {
      // ★ r318 真机更正：r306 曾按官方 **Web** 前端的 `Y-m-d H:i:s` 发，
      //   真机两条路径（创建选 7 天 / 编辑选 30 天）服务端都**没存**这个到期时间
      //   ⇒ 改回官方安卓 APK 的 `DateUtils.DATE_FORMAT_LOCALE` = 只发日期，
      //   时刻由服务端自己补（`.so` 里有 `" 23:59:59"`）。
      final now = DateTime(2026, 10, 8, 15, 30);
      expect(shareLinkExpiryWire(now, 7), '2026-10-15');
      expect(shareLinkExpiryWire(now, 1), '2026-10-09');
      expect(shareLinkExpiryWire(now, 30), '2026-11-07');
      // 跨月/跨年补零
      expect(shareLinkExpiryWire(DateTime(2026, 12, 30), 3), '2027-01-02');
      // 永久（0 / 负数）⇒ **不发**这个字段
      expect(shareLinkExpiryWire(now, 0), isNull);
      expect(shareLinkExpiryWire(now, -3), isNull);
    });

    testWidgets('创建面板选「7 天」→ 交给页面的 dateExpired 是官方格式', (tester) async {
      ShareLinkDraft? draft;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () async {
                    draft = await showCreateShareLinkSheet(context);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('7 天'));
      await tester.pump();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      final sent = draft?.dateExpired;
      expect(sent, isNotNull);
      // ★ 机制量：**只发日期**（官方安卓格式；带时刻的 r306 写法已被 r318 真机推翻）
      expect(
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(sent!),
        isTrue,
        reason: '实际发出：$sent',
      );
      // 且确实是"今天 +7 天"
      final want = shareLinkExpiryWire(DateTime.now(), 7);
      expect(sent, want);
    });
  });

  group('DTO 细节', () {
    test('ShareLinkDto：失效/密码/有效期', () {
      const broken = ShareLinkDto(id: 'x', status: 'broken');
      expect(broken.isValid, isFalse);
      const good = ShareLinkDto(
        id: 'y',
        name: 'n',
        path: '/p',
        isFolder: true,
        hasPassword: true,
        dateExpired: '2026-01-01',
      );
      expect(good.isValid, isTrue);
      expect(good.isFolder, isTrue);
      expect(good.hasPassword, isTrue);
    });
  });

  // r305：`SYNO.FileStation.Extract / list`（不解压先看包里有什么）。
  // 之前**只有 API、没有入口**（"登记了却不产生机制量"）⇒ 这一组既钉入口，
  // 也钉面板本身的四条状态（有内容 / 空包 / 读不了 / 加密后重试）。
  group('r305 查看压缩包内容（Extract/list）', () {
    FileEntryDto entryFor(String name, {bool dir = false, int size = 0}) =>
        FileEntryDto(name: name, path: '/home/$name', isDir: dir, size: size);

    /// 面板比 800x600 高（错误态还有按钮）⇒ 先把测试视口放大。
    /// ⚠️ 用 `tester.view.physicalSize`（`setSurfaceSize` 根本改不动
    /// `MediaQuery`，见 §2.0.36），dpr=1 让坐标就是逻辑像素。
    void useTallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(1000, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<void> openSheet(
      WidgetTester tester,
      Future<FileListResult> Function({String? password}) load, {
      String fileName = 'pkg.zip',
    }) async {
      useTallView(tester);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showArchiveContentsSheet(
                    context,
                    fileName: fileName,
                    load: load,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('列出条目：名字 + 大小 + 条目数（目录不显示大小）', (tester) async {
      await openSheet(tester, ({String? password}) async {
        expect(password, isNull, reason: '第一次不带密码');
        return FileListResult(
          total: 3,
          entries: [
            entryFor('docs', dir: true),
            entryFor('a.txt', size: 2048),
            entryFor('b.bin', size: 3 * 1024 * 1024),
          ],
        );
      });
      expect(find.text('docs'), findsOneWidget);
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('b.bin'), findsOneWidget);
      expect(find.text('共 3 个条目'), findsOneWidget);
      // 机制量：**文件**有大小、目录没有
      expect(find.text('2.0 KB'), findsOneWidget);
      expect(find.text('3.0 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空包：说"没有条目"，不留白也不假报错', (tester) async {
      await openSheet(
        tester,
        ({String? password}) async => const FileListResult(),
      );
      expect(find.text('压缩包里没有条目'), findsOneWidget);
      expect(find.text('共 0 个条目'), findsNothing);
    });

    testWidgets('读不了：原样说出原因 + 给"输入密码后重试"入口；填了密码就带密码重试', (tester) async {
      final seen = <String?>[];
      await openSheet(tester, ({String? password}) async {
        seen.add(password);
        if (password == null) {
          throw DsmApiException(401, method: 'SYNO.FileStation.Extract');
        }
        return FileListResult(
          total: 1,
          entries: [entryFor('secret.txt', size: 10)],
        );
      });
      expect(find.textContaining('读不了压缩包'), findsOneWidget);
      expect(find.text('secret.txt'), findsNothing);

      // ⚠️ 这里**直接调回调**而不是 `tap()`：flutter_test 的视口里
      // `showModalBottomSheet` 的整块面板会被下移（实测面板底 = 2292 > 屏高 2200），
      // 短面板因此几乎整块落在屏外，`tap()` 只会给一条 "would not hit test" 警告
      // （点了等于没点）——**这是测试视口的现象，不是产品缺陷**（真机截图里
      // 面板正常）。所以要验的是"回调接对了没"，不是"像素点得到没"。
      final retry = find.byKey(const Key('archive-contents-password'));
      expect(retry, findsOneWidget);
      tester.widget<AppSheetAction>(retry).onTap!.call();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'r305pw',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 机制量：第二次请求真的带上了密码，并且换成了内容
      expect(seen, [null, 'r305pw']);
      expect(find.text('secret.txt'), findsOneWidget);
      expect(find.text('共 1 个条目'), findsOneWidget);
      expect(find.textContaining('读不了压缩包'), findsNothing);
    });

    Future<void> pumpMenu(WidgetTester tester, FileEntryDto e) async {
      // 每次都用**新的 Navigator**（`UniqueKey`）：否则上一次打开的面板会
      // 留在被复用的 Navigator 栈里，第二次 `tap` 全打在面板上
      // （flutter_test 会报 "would not hit test on the specified widget"）。
      useTallView(tester);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          key: UniqueKey(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showFileItemSheet(context, entry: e),
                  child: const Text('menu'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('menu'));
      await tester.pumpAndSettle();
    }

    testWidgets('菜单：压缩包有"查看压缩包内容"，普通文件没有', (tester) async {
      await pumpMenu(tester, entryFor('pkg.zip'));
      expect(
        find.byKey(const Key('file-action-archive-contents')),
        findsOneWidget,
      );
      expect(find.text('查看压缩包内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('菜单：普通文件**不出现**"查看压缩包内容"（反向验证）', (tester) async {
      await pumpMenu(tester, entryFor('note.txt'));
      expect(find.byKey(const Key('file-action-archive-contents')), findsNothing);
      expect(find.text('查看压缩包内容'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // r306：`Sharing/getinfo` 此前**全仓 0 个调用方**（死代码，台账如实写着）。
  // 这一组既钉"接上了"，也钉**面板显示的是服务端读数、不是列表快照**。
  group('r306 分享链接详情（Sharing/getinfo）', () {
    Map<String, dynamic> linkFixture({
      String id = 'L1',
      String name = '季度报告',
      bool hasPassword = true,
      String dateExpired = '2026-01-01',
      String url = 'https://nas.example.com:5001/sharing/L1',
    }) => {
      'id': id,
      'name': name,
      'path': '/home/report.pdf',
      'isdir': false,
      'status': 'valid',
      'has_password': hasPassword,
      'date_expired': dateExpired,
      'url': url,
    };

    int infoCalls(FakeTransport t) => t.calls
        .where(
          (c) =>
              c['api'] == 'SYNO.FileStation.Sharing' &&
              c['method'] == 'getinfo',
        )
        .length;

    testWidgets('点一行 → 用 getinfo 的服务端读数**覆盖**列表快照（id 发裸串）', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': [linkFixture()],
          'total': 1,
          'offset': 0,
        },
        // 服务端此刻的真相与列表快照**不一样**（快照：有密码 + 至 2026-01-01；
        // getinfo：没密码 + 永久）⇒ 屏幕上显示哪一组就是判据
        'SYNO.FileStation.Sharing.getinfo': {
          'links': [linkFixture(hasPassword: false, dateExpired: '')],
          'total': 1,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());
      await tester.tap(find.byKey(const Key('share-link-row-L1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final info = boot.t.calls.lastWhere(
        (c) =>
            c['api'] == 'SYNO.FileStation.Sharing' && c['method'] == 'getinfo',
        orElse: () => const {},
      );
      // ★ 机制量：`getinfo`/`edit` 的 id 是**裸串**，只有 `delete` 是 JSON 数组串
      //   （照抄 delete 是本仓修过的真缺陷）
      expect(info['id'], 'L1');
      // 服务端读数真的上了屏
      expect(find.text('永久'), findsOneWidget);
      expect(find.text('没有'), findsOneWidget);
      expect(find.text('至 2026-01-01'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('getinfo 失败 → 原样说原因 + 「重试」；重试成功后换成服务端读数', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': [linkFixture()],
          'total': 1,
          'offset': 0,
        },
        'SYNO.FileStation.Sharing.getinfo': {
          'links': [linkFixture(hasPassword: false, dateExpired: '')],
          'total': 1,
          'offset': 0,
        },
      });
      // 第一次失败、之后成功 ⇒ 正好验"重试"按钮真的重发了请求
      boot.t.failTimes['SYNO.FileStation.Sharing.getinfo'] = 408;
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());
      await tester.tap(find.byKey(const Key('share-link-row-L1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('取不了详情'), findsOneWidget);
      final retry = find.byKey(const Key('share-link-detail-retry'));
      expect(retry, findsOneWidget);
      expect(infoCalls(boot.t), 1);

      // ⚠️ 直调回调：测试视口里底部面板会被下移，"点得到/点不到"不是产品判据
      tester.widget<AppSheetAction>(retry).onTap!.call();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(infoCalls(boot.t), 2, reason: '重试必须真的再发一次 getinfo');
      expect(find.textContaining('取不了详情'), findsNothing);
      expect(find.text('永久'), findsOneWidget);
    });

    testWidgets('服务端回空 ⇒ 说"没有返回详情"，不拿快照冒充服务端真相', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': [linkFixture()],
          'total': 1,
          'offset': 0,
        },
        'SYNO.FileStation.Sharing.getinfo': {
          'links': <dynamic>[],
          'total': 0,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());
      await tester.tap(find.byKey(const Key('share-link-row-L1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('服务端没有返回这条链接的详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有链接地址才给「复制链接」', (tester) async {
      final boot = await _boot({
        'SYNO.FileStation.Sharing.list': {
          'links': [linkFixture()],
          'total': 1,
          'offset': 0,
        },
        'SYNO.FileStation.Sharing.getinfo': {
          'links': [linkFixture()],
          'total': 1,
          'offset': 0,
        },
      });
      await _pump(tester, boot.fs, boot.db, const FileShareLinksPage());
      await tester.tap(find.byKey(const Key('share-link-row-L1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('share-link-detail-copy')), findsOneWidget);
      expect(
        find.textContaining('https://nas.example.com:5001/sharing/L1'),
        findsOneWidget,
      );
    });
  });
}
