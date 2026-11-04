// 错误态回归（第 260 轮，R1）："用户走不出去的状态"。
//
// 审计结论（AGENTS §2.0.8 铁律②）：凡是"某个用户可改设置 / 一次重试就能恢复"
// 的页面，报错时**必须**保留那个入口（或给一键重试），且**失败不能渲染成空 /
// 永久转圈 / 静默吞掉**，原因要给用户能看懂的中文。
//
// 本文件逐条钉住本轮修过的页面：
//   * 失败时**出现可点的重试入口**；
//   * 点了之后**真的重新发请求 / 重新读取**（用计数器证明）；
//   * 失败原因**可见且非空**；
//   * 失败**不被当成空结果**。
//
// 反向验证：把本轮修复还原（旧代码只看 `.value` / 吞异常 / 错误分支只
// `Text(...)` 或 `SizedBox.shrink()`）后，下面每条都会红。
//
// ★ Drive 本地文件页（H3）单列在 `error_recovery_r1_drive_test.dart`：
//   它的依赖链会拉到 `media_player_view.dart`，与其它用例隔离免得被牵连。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/contact_dto.dart'
    show AddressbookDto;
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/url_prop_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/contacts/contacts_manage_page.dart';
import 'package:synhub/src/features/contacts/contacts_providers.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/link_preview_card.dart';
import 'package:synhub/src/features/chat/thread_page.dart';
import 'package:synhub/src/features/notes/note_conflict_page.dart';
import 'package:synhub/src/features/notes/note_editor_page.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_sync.dart';
import 'package:synhub/src/features/photos/image_edit_providers.dart';
import 'package:synhub/src/features/photos/photo_ai_edit_settings.dart';
import 'package:synhub/src/features/search/search_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 统一包装：无 localization 也需要 `MaterialApp`（`Theme`/`ScaffoldMessenger`）。
Widget _app(ProviderContainer c, Widget home) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: home),
);

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  // ────────────────────────────────────────────────────────────────────────
  // H1 · 通讯录管理页：加载失败 = 可读原因 + 可点重试（原来是纯文本、无出路）
  // ────────────────────────────────────────────────────────────────────────
  group('H1 通讯录管理页失败可重试', () {
    testWidgets('列表失败 → 显示原因 + 重试；点重试真的重新请求', (tester) async {
      var calls = 0;
      final c = ProviderContainer(
        overrides: [
          addressbooksProvider.overrideWith((ref) async {
            calls++;
            if (calls == 1) throw Exception('simulated failure');
            return const <AddressbookDto>[];
          }),
        ],
      );
      addTearDown(c.dispose);

      await tester.pumpWidget(_app(c, const ContactsManagePage()));
      await _pumpFrames(tester);

      // 失败态出现（不是空态、不是转圈）
      expect(
        find.byKey(const Key('contact-books-error')),
        findsOneWidget,
        reason: '★ 列表失败必须有明确错误态',
      );
      expect(find.textContaining('重试'), findsWidgets, reason: '★ 必须给重试入口');
      expect(calls, 1);

      // 点重试 → 真的重新请求
      await tester.tap(find.textContaining('重试').first);
      await _pumpFrames(tester);
      expect(calls, 2, reason: '★★ 点重试必须真的重新发请求');
      expect(
        find.byKey(const Key('contact-books-error')),
        findsNothing,
        reason: '第二次成功 → 错误态消失',
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // H4 · AI 美化设置卡：读设置失败 = 错误态 + 重试（原来是永久转圈）
  // ────────────────────────────────────────────────────────────────────────
  group('H4 AI 美化设置失败可重试', () {
    testWidgets('读设置失败 → 不再永久转圈；重试真的重新读', (tester) async {
      var calls = 0;
      final c = ProviderContainer(
        overrides: [
          photoAiEditSettingsProvider.overrideWith((ref) async {
            calls++;
            if (calls == 1) throw Exception('simulated failure');
            return const PhotoAiEditSettings(
              enabled: false,
              consent: false,
              dailyCap: 3,
              wifiOnly: true,
              backendId: 'openai_images_edits',
              baseUrl: '',
              model: '',
              apiKey: '',
            );
          }),
        ],
      );
      addTearDown(c.dispose);

      await tester.pumpWidget(
        _app(c, const Scaffold(body: PhotoAiEditSettingsCard())),
      );
      await _pumpFrames(tester);

      expect(
        find.byKey(const Key('image-edit-settings-error')),
        findsOneWidget,
        reason: '★ 失败必须给错误态，而不是无限 CircularProgressIndicator',
      );
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '★★ 失败不能继续转圈',
      );
      expect(find.textContaining('重试'), findsWidgets);
      expect(calls, 1);

      await tester.tap(find.textContaining('重试').first);
      await _pumpFrames(tester);
      expect(calls, 2, reason: '★★ 重试必须真的重新读设置');
      expect(
        find.byKey(const Key('image-edit-settings-card')),
        findsOneWidget,
        reason: '第二次成功 → 设置卡正常渲染',
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // H2 · 笔记冲突页：裁决失败原来被静默吞掉（无 catch）
  // ────────────────────────────────────────────────────────────────────────
  group('H2 冲突裁决失败可见且可重试', () {
    testWidgets('裁决抛异常 → 提示失败原因 + 可点重试；重试真的再执行', (tester) async {
      var attempts = 0;
      final c = ProviderContainer(
        overrides: [
          noteSyncProvider.overrideWith(
            () => _ThrowingSyncNotifier(() => attempts++),
          ),
        ],
      );
      addTearDown(c.dispose);

      await tester.pumpWidget(_app(c, const NoteConflictPage()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('note-conflict-keep-local')), findsOneWidget);
      expect(attempts, 0);

      await tester.tap(find.byKey(const Key('note-conflict-keep-local')));
      await tester.pumpAndSettle();

      // 失败必须可见（原来静默吞掉：什么都没有）
      expect(
        find.textContaining('操作失败'),
        findsOneWidget,
        reason: '★ 裁决失败必须给用户可见的原因',
      );
      expect(find.text('重试'), findsOneWidget, reason: '★ 必须给重试入口');
      expect(attempts, 1);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(attempts, 2, reason: '★★ 点重试必须真的再执行一次裁决');
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // M6 · 链接预览卡：会话未就绪时不再永久转圈，失败给重试入口
  // ────────────────────────────────────────────────────────────────────────
  group('M6 链接预览失败不永久转圈', () {
    testWidgets('chatApi 为空 → 失败态 + 可点重试（不是无限转圈）', (tester) async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(c.dispose);

      await tester.pumpWidget(
        _app(
          c,
          const Scaffold(
            body: LinkPreviewCard(
              postId: 7,
              prop: UrlPropDto(
                url: 'https://example.com/a',
                title: 't',
                image: 'https://example.com/a.png',
              ),
            ),
          ),
        ),
      );
      await _pumpFrames(tester);

      expect(
        find.byKey(const Key('link-preview-retry')),
        findsOneWidget,
        reason: '★ 会话未就绪时必须给失败/重试入口',
      );
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '★★ 不能永久转圈',
      );

      // 重试入口可点（不会抛）
      await tester.tap(find.byKey(const Key('link-preview-retry')));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('link-preview-retry')), findsOneWidget);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // M5 · 搜索页：请求失败 ≠ "没有匹配结果"，且可重试
  // ────────────────────────────────────────────────────────────────────────
  group('M5 搜索失败≠无结果且可重试', () {
    testWidgets('搜索失败 → 错误态带重试；点重试真的重新搜索并出结果', (tester) async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.search'] = 403;

      await tester.pumpWidget(_app(h.container, const SearchPage()));
      await tester.pump();

      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('search-error')), findsOneWidget);
      expect(
        find.text('没有匹配的消息'),
        findsNothing,
        reason: '★★ 失败不能被渲染成空结果',
      );
      expect(find.textContaining('搜索失败'), findsOneWidget);

      // 恢复服务端 → 点重试必须真的重新请求并出结果
      h.transport.failures.remove('SYNO.Chat.Post.search');
      h.transport.responses['SYNO.Chat.Post.search'] = {
        'search_results': [
          {
            'post_id': 1,
            'channel_id': 5,
            'creator_id': 14,
            'create_at': 1700000000000,
            'type': 'normal',
            'message': 'r1 命中',
          },
        ],
        'total': 1,
        'offset': 0,
        'limit': 30,
      };
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      final calls = h.transport.calls
          .where((c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search')
          .length;
      expect(calls, 2, reason: '★★ 点重试必须真的重新搜索');
      expect(find.textContaining('r1 命中'), findsOneWidget);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // M4 · 话题页：回复流失败给重试入口（原来只有一行文本）
  // ────────────────────────────────────────────────────────────────────────
  group('M4 话题回复失败可重试', () {
    testWidgets('回复流报错 → 错误态带重试；重试后真的重新订阅并出内容', (tester) async {
      var subscribes = 0;
      // 用可控开关（而不是"第一次失败"）：provider 在首帧可能被订阅多次，
      // 只有开关才能稳定制造"当前就是错误态"。
      var failing = true;
      final h = await bootChat(
        moreOverrides: [
          threadRepliesProvider.overrideWith((ref, key) {
            subscribes++;
            if (failing) {
              return Stream<List<PostDto>>.error(Exception('simulated'));
            }
            return Stream.value([
              const PostDto(
                postId: 101,
                channelId: 5,
                creatorId: 4,
                message: '重试后的回复',
                createAt: 1700000001000,
              ),
            ]);
          }),
        ],
      );
      await h.container.read(chatStoreProvider).upsertPosts(const [
        PostDto(
          postId: 100,
          channelId: 5,
          creatorId: 3,
          message: '原消息',
          createAt: 1700000000000,
          commentCount: 1,
        ),
      ]);

      await tester.pumpWidget(
        _app(h.container, const ThreadPage(channelId: 5, parentPostId: 100)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('thread-replies-error')), findsOneWidget);
      expect(find.textContaining('重试'), findsWidgets, reason: '★ 必须给重试入口');
      final before = subscribes;

      // 恢复后点重试 → 必须真的重新订阅并出内容
      failing = false;
      await tester.tap(find.textContaining('重试').first);
      await tester.pumpAndSettle();
      expect(subscribes, greaterThan(before), reason: '★★ 重试必须真的重新订阅回复流');
      expect(find.textContaining('重试后的回复'), findsWidgets);
    });
  });
  // ────────────────────────────────────────────────────────────────────────
  // M1 · 笔记编辑器：取正文失败原来是永久转圈（不看 `hasError`）
  // ────────────────────────────────────────────────────────────────────────
  group('M1 笔记编辑器取正文失败可重试', () {
    testWidgets('取正文失败 → 错误态 + 重试；重试真的重新取', (tester) async {
      var calls = 0;
      final c = ProviderContainer(
        overrides: [
          noteDetailProvider.overrideWith((ref, id) async {
            calls++;
            throw Exception('simulated detail failure');
          }),
        ],
      );
      addTearDown(c.dispose);

      await tester.pumpWidget(
        _app(
          c,
          const NoteEditorPage(note: NoteDto(objectId: 'n1', title: 'T')),
        ),
      );
      await _pumpFrames(tester);

      expect(
        find.byKey(const Key('note-editor-detail-error')),
        findsOneWidget,
        reason: '★ 取正文失败必须给错误态，而不是永久转圈',
      );
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '★★ 失败不能继续转圈',
      );
      final before = calls;

      // 点重试 → 真的重新取（本例继续失败：断言"重新发起了请求"而不是"成功"，
      // 免得为渲染 Quill 再装 localization delegate，偏离本用例主题）
      await tester.tap(find.textContaining('重试').first);
      await _pumpFrames(tester);
      expect(calls, greaterThan(before), reason: '★★ 重试必须真的重新取正文');
      expect(find.byKey(const Key('note-editor-detail-error')), findsOneWidget);
    });
  });
}

/// 冲突裁决必抛的同步器（只在 build 里给一条冲突，所有裁决动作都失败）。
class _ThrowingSyncNotifier extends NoteSyncNotifier {
  _ThrowingSyncNotifier(this.onResolve);

  final void Function() onResolve;

  @override
  NoteSyncStatus build() => const NoteSyncStatus(
    conflicts: [
      NoteConflict(
        objectId: 'n1',
        title: '冲突笔记',
        baseVer: 'v1',
        serverVer: 'v2',
        localContent: '<p>本地</p>',
        serverContent: '<p>服务端</p>',
        serverFetched: true,
      ),
    ],
  );

  Future<void> _fail() async {
    onResolve();
    throw Exception('simulated resolve failure');
  }

  @override
  Future<void> resolveWithLocal(NoteConflict conflict) => _fail();

  @override
  Future<void> resolveWithServer(NoteConflict conflict) => _fail();

  @override
  Future<void> keepBothOnConflict(NoteConflict conflict) => _fail();
}
