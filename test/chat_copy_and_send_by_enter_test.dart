// ★ **②聊天 第 38 轮：剪贴板（行 140）+ 回车发送（行 300）**
//
// ## 行 140「复制正文 / 复制文件描述」
// 既有 `test/chat_post_actions_test.dart:613-622` 只验了**标签分支**
// （`copyActionLabel(post, t)`：`type=='file'` → `chatActionCopyDesc`，否则
// `chatActionCopyText`）—— 也就是"菜单上写的是哪个词"。
// **真正写进剪贴板这件事从来没测过**（审计行的残留就是「无真机（剪贴板）」）。
//
// ⇒ 本轮挂 `SystemChannels.platform` 的 mock 截获 `Clipboard.setData`，
//   把**实际复制的字符串**钉住。
//   ⚠️ 为什么必须挂 mock：测试环境里 `Clipboard.getData` 没有平台实现，
//   `await` 会**永远挂住**（这个坑 `test/drive_p3_pages_test.dart:209-210`
//   已经记录过，照抄同一手法）。
//
// ## 行 300「回车发送」
// 实现是齐的（`chat_page.dart:3297,3367-3379`）：
// `maxLines: sendByEnter ? 1 : 5`、`textInputAction: send ? send : newline`、
// `onSubmitted: sendByEnter ? (_) { onSend(); } : null`。
// 但**没有任何用例验过它**（全仓 `test/` 里搜 `TextInputAction.send` 只命中
// 下载页的 `search`）。⇒ 本轮从**真实输入框**上验三件事都随开关切换。
//
// ## 不做什么
// 不碰真机、不碰真 NAS（§5.1）。全程 widget 测试 + 内存 Mock。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/post_actions_sheet.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 挂一个只截获 `Clipboard.setData` 的平台通道 mock，返回一个读取器。
String? Function() _mockClipboard(WidgetTester tester) {
  String? copied;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return () => copied;
}

void main() {
  group('CP-1. 行 140：复制真的写进剪贴板（内容 + 标签两套分开）', () {
    testWidgets('★ 文本消息 → 复制的是**正文**，标签是「复制文字」', (tester) async {
      final copied = _mockClipboard(tester);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => copyPostMessage(ctx, '这是一条正文 <b>不转义</b>'),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(copied(), '这是一条正文 <b>不转义</b>', reason: '官方也是纯文本复制，不做任何转义/渲染');
      // 复制后有提示
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('★ 文件消息 → 复制的是 `post.message`（即文件描述，不是文件名）', (tester) async {
      final copied = _mockClipboard(tester);
      const desc = '这是文件描述，不是 file_name.txt';
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => copyPostMessage(ctx, desc),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(copied(), desc);
    });

    test("★ 标签分支：type 为 file → 复制描述；其余 → 复制文字", () async {
      // 用真实 `PostDto` + 真实 `AppText`，不用字符串字面量代替
      final t = _appText();
      final file = PostDto(postId: 1, channelId: 5, type: 'file', message: 'd');
      final text = PostDto(postId: 2, channelId: 5, type: 'text', message: 'm');
      final normal = PostDto(
        postId: 3,
        channelId: 5,
        message: 'm',
      ); // 默认 normal
      expect(copyActionLabel(file, t), t.chatActionCopyDesc);
      expect(copyActionLabel(text, t), t.chatActionCopyText);
      expect(copyActionLabel(normal, t), t.chatActionCopyText);
    });

    testWidgets('★ 空正文也能复制（不崩、不抛）', (tester) async {
      final copied = _mockClipboard(tester);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => copyPostMessage(ctx, ''),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(copied(), '');
    });
  });

  group('EN-1. 行 300：回车发送开关**真的**改输入框行为', () {
    /// 找到 composer 的输入框（`ChatPage` 里唯一带 hint 的那个）。
    TextField composerField(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField).first);

    testWidgets('★ 默认（关）：多行 + newline 动作 + 提交不发消息', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final f = composerField(tester);
      expect(f.maxLines, 5, reason: '关着时是多行输入框');
      expect(
        f.textInputAction,
        TextInputAction.newline,
        reason: 'IME 动作必须是"换行"',
      );
      expect(f.onSubmitted, isNull, reason: '关着时不该接提交回调');

      // 真按一次回车 ⇒ 不发任何 create
      await tester.enterText(find.byType(TextField).first, 'hello');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        h.transport.calls.where((c) => c['method'] == 'create'),
        isEmpty,
        reason: '回车发送是**关**的 ⇒ 回车绝不能发消息',
      );
    });

    testWidgets('★ 打开：单行 + send 动作 + 提交**真的**发消息', (tester) async {
      final h = await bootChat();
      // 打开「回车发送」（真实设置项 → provider）
      await h.container.read(sendByEnterProvider.notifier).set(true);
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final f = composerField(tester);
      expect(f.maxLines, 1, reason: '开着时输入框变**单行**（官方 setSingleLine）');
      expect(
        f.textInputAction,
        TextInputAction.send,
        reason: '官方 `IME_ACTION_SEND`',
      );
      expect(f.onSubmitted, isNotNull);

      await tester.enterText(find.byType(TextField).first, 'hello');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      final creates = h.transport.calls
          .where((c) => c['method'] == 'create' && c['api'] == 'SYNO.Chat.Post')
          .toList();
      expect(creates, hasLength(1), reason: '★ 开着时回车必须真的发出 create');
    });

    testWidgets('★ 开关是**实时**的：同一次会话里改设置，输入框跟着变', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(composerField(tester).maxLines, 5);

      await h.container.read(sendByEnterProvider.notifier).set(true);
      await tester.pump();
      expect(
        composerField(tester).maxLines,
        1,
        reason: 'provider 变了就该重新渲染（watch 而不是 read）',
      );
      await h.container.read(sendByEnterProvider.notifier).set(false);
      await tester.pump();
      expect(composerField(tester).maxLines, 5);
    });
  });
}

Widget _app(ProviderContainer c, int channelId) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: channelId)),
);

/// 拿一个真实的 `AppText`（走 `gen-l10n` 的 zh 实例），
/// 避免用字符串字面量冒充"标签分支正确"。
AppText _appText() => lookupAppText(const Locale('zh'));
