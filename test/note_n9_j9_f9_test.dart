// ★★ ④笔记 第 235 轮：**N9 存储位置** + **J9 分享出去** + **F9 视图切换** 用例。
//
// 三条都是 234 轮复核里挂着的行：N9 ❌（未实现）、J9 🟠（缺出站）、F9 🟠（缺用例）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/notes/note_providers.dart'
    show NoteViewMode, noteViewModeProvider;
import 'package:synhub/src/features/notes/note_share_out.dart';
import 'package:synhub/src/features/notes/note_storage_location.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/notes/note_theme_sheet.dart'
    show showNoteThemeSheetImpl;

void main() {
  group('N9 存储位置 · 解析与回退', () {
    test('内部 ⇒ 用内部目录，不回退', () async {
      final r = await resolveNoteStorageRoot(
        NoteStorageLocation.internal,
        resolver: (external) async => external ? '/sdcard/app' : '/data/app',
      );
      expect(r.location, NoteStorageLocation.internal);
      expect(r.path, '/data/app');
      expect(r.fellBack, isFalse);
    });

    test('外置可用 ⇒ 用外置目录', () async {
      final r = await resolveNoteStorageRoot(
        NoteStorageLocation.external,
        resolver: (external) async => external ? '/sdcard/app' : '/data/app',
      );
      expect(r.location, NoteStorageLocation.external);
      expect(r.path, '/sdcard/app');
      expect(r.fellBack, isFalse);
    });

    test('★ 外置取不到 ⇒ **退回内部并如实 fellBack=true**（不假装外置成功）', () async {
      final r = await resolveNoteStorageRoot(
        NoteStorageLocation.external,
        resolver: (external) async => external ? null : '/data/app',
      );
      expect(r.location, NoteStorageLocation.internal);
      expect(r.path, '/data/app');
      expect(r.fellBack, isTrue);
    });

    test('外置返回空串也当不可用（防"路径存在但没内容"）', () async {
      final r = await resolveNoteStorageRoot(
        NoteStorageLocation.external,
        resolver: (external) async => external ? '' : '/data/app',
      );
      expect(r.fellBack, isTrue);
      expect(r.path, '/data/app');
    });

    test('wire 值逐字对齐官方（internal_storage / external_storage）', () {
      expect(NoteStorageLocation.internal.wire, 'internal_storage');
      expect(NoteStorageLocation.external.wire, 'external_storage');
      expect(
        NoteStorageLocation.fromWire('external_storage'),
        NoteStorageLocation.external,
      );
      expect(
        NoteStorageLocation.fromWire('乱写的值'),
        NoteStorageLocation.internal,
        reason: '未知值按默认内部处理（官方也是这个兜底）',
      );
      expect(kNoteStorageLocationKey, 'note_storage_location');
    });
  });

  group('J9 分享出去 · 载荷构造', () {
    test('标题空 ⇒ 官方兜底文案；标题有 ⇒ 原样（去首尾空白）', () {
      expect(noteShareSubject(title: '   '), 'Synology Note');
      expect(noteShareSubject(title: ' 会议纪要 '), '会议纪要');
    });

    test('正文原样（空正文就是空串，**不编内容**）', () {
      expect(noteShareBody(body: ''), '');
      expect(noteShareBody(body: '第一行\r\n第二行'), '第一行\n第二行');
    });

    test('超长正文在**行边界**截断并加省略号（不甩半行）', () {
      final body = List.generate(400, (i) => '第$i行内容').join('\n');
      final out = noteShareBody(body: body, maxChars: 200);
      expect(out.length, lessThanOrEqualTo(201));
      expect(out.endsWith('…'), isTrue);
      expect(out.endsWith('\n…'), isFalse, reason: '省略号不该接在换行后面');
      for (final line in out.substring(0, out.length - 1).split('\n')) {
        expect(line, matches(RegExp(r'^第\d+行内容$')));
      }
    });

    test('正好不超限 ⇒ 一个字都不改', () {
      final body = 'a' * kNoteShareBodyMaxChars;
      expect(noteShareBody(body: body), body);
    });
  });

  group('J9 分享出去 · 通道契约与调用', () {
    test('走 shareText，subject/text 都带上；成功返回 true', () async {
      final b = RecordingNoteShareOutBridge();
      final ok = await shareNoteOut(title: '标题', body: '正文', bridge: b);
      expect(ok, isTrue);
      expect(b.calls.single.subject, '标题');
      expect(b.calls.single.text, '正文');
    });

    test('原生失败（没有可接收 App）⇒ 如实 false', () async {
      final b = RecordingNoteShareOutBridge()..result = false;
      expect(await shareNoteOut(title: 't', body: 'b', bridge: b), isFalse);
    });

    test('通道抛异常 ⇒ false，不假装分享成功', () async {
      expect(
        await shareNoteOut(
          title: 't',
          body: 'b',
          bridge: _ThrowingShareBridge(),
        ),
        isFalse,
      );
    });

    test('与 Kotlin 的跨语言契约（通道名 / 方法名 / ACTION_SEND）', () {
      final kt = File(
        'android/app/src/main/kotlin/com/openviewai/synhub/'
        'ShareTextBridge.kt',
      ).readAsStringSync();
      expect(kNoteShareOutChannel, 'synhub/share_text');
      expect(kt, contains('"$kNoteShareOutChannel"'));
      expect(kt, contains('"shareText"'));
      expect(kt, contains('Intent.ACTION_SEND'));
      expect(kt, contains('Intent.EXTRA_SUBJECT'));
      expect(kt, contains('Intent.EXTRA_TEXT'));
      expect(kt, contains('Intent.createChooser'));
    });
  });

  group('F9 视图切换 · 语义（Notifier 真行为）', () {
    test('toggle 在 snippet ⇄ card 之间互转；set 可显式设值', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(noteViewModeProvider.notifier);
      expect(c.read(noteViewModeProvider), NoteViewMode.snippet);
      n.toggle();
      expect(c.read(noteViewModeProvider), NoteViewMode.card);
      n.toggle();
      expect(c.read(noteViewModeProvider), NoteViewMode.snippet);
      n.set(NoteViewMode.card);
      expect(c.read(noteViewModeProvider), NoteViewMode.card);
    });

    test('官方口径：`view_by` 只有本地设置，**没有服务端 API**（源码事实）', () {
      final src = File(
        'lib/src/features/notes/note_providers.dart',
      ).readAsStringSync();
      expect(src, contains('view_by'));
      expect(src, contains('snippet'));
      expect(src, contains('card'));
    });
  });

  group('N9 存储位置 · 设置面板入口', () {
    testWidgets('★ 面板里有「内部/外置」两项，点外置就落到 provider（与 N7 同一套 KV）', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Builder(
              builder: (ctx) => TextButton(
                key: const Key('open-sheet'),
                onPressed: () => showNoteThemeSheetImpl(
                  ctx,
                  ProviderScope.containerOf(ctx, listen: false),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-sheet')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('note-storage-internal_storage')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('note-storage-external_storage')),
        findsOneWidget,
      );
      // 半屏面板 + 5 个选项 ⇒ 外置选项在折叠线下，必须先滚到可见再点
      final external = find.byKey(const Key('note-storage-external_storage'));
      await tester.ensureVisible(external);
      await tester.pumpAndSettle();
      await tester.tap(external);
      await tester.pumpAndSettle();
      expect(
        container.read(noteStorageLocationProvider),
        NoteStorageLocation.external,
      );
    });
  });
}

class _ThrowingShareBridge implements NoteShareOutBridge {
  @override
  Future<bool> shareText({
    required String subject,
    required String text,
  }) async => throw PlatformException(code: 'no_channel');
}
