// P0-6：「分享到 Chat」（`ACTION_SEND` / `ACTION_SEND_MULTIPLE`）。
//
// 官方证据：exported `ShareActivity` 的两个 intent-filter
// （`AndroidManifest.xml:224-241`，`*/*`），`ShareEditFragment.handleIntent`
// 读 `EXTRA_TEXT` / `EXTRA_SUBJECT` / `EXTRA_STREAM`，最多 50 个附件。
//
// 本文件覆盖三件事：
//   ① Android 侧真的注册了 SEND / SEND_MULTIPLE（读真实 manifest）
//   ② 原生载荷 → `ShareIntentData` 的解析（含空载荷、溢出计数）
//   ③ Dart 接收路径：选频道 → 用**既有**发送链路发文本 / 附件
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/chat/share_intent.dart';
import 'package:synhub/src/features/chat/share_intent_host.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

const String kManifestPath = 'android/app/src/main/AndroidManifest.xml';

/// 离线假源：给什么 pending 就返回什么，`push` 模拟前台时的来件。
class _FakeShareSource implements ShareIntentSource {
  _FakeShareSource(this.pending);

  ShareIntentData? pending;
  final _events = StreamController<ShareIntentData>.broadcast();

  @override
  Stream<ShareIntentData> get incoming => _events.stream;

  @override
  Future<ShareIntentData?> takePending() async {
    final p = pending;
    pending = null;
    return p;
  }

  void push(ShareIntentData d) => _events.add(d);

  @override
  void dispose() {
    if (!_events.isClosed) _events.close();
  }
}

Widget _hostApp(ProviderContainer c) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), 
    home: Scaffold(body: ShareIntentHost(child: SizedBox.shrink())),
  ),
);

void main() {
  group('AndroidManifest 注册（P0-6 的承重断言）', () {
    late final String manifest;

    setUpAll(() {
      manifest = File(kManifestPath).readAsStringSync();
    });

    test('ACTION_SEND 与 ACTION_SEND_MULTIPLE 都以 */* 注册', () {
      final body = manifest.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
      for (final action in const [
        'android.intent.action.SEND',
        'android.intent.action.SEND_MULTIPLE',
      ]) {
        final filter = RegExp(
          '<intent-filter>(?:(?!</intent-filter>).)*?'
          '<action android:name="$action"/>'
          '(?:(?!</intent-filter>).)*?</intent-filter>',
          dotAll: true,
        ).firstMatch(body);
        expect(filter, isNotNull, reason: '$action 没有 intent-filter');
        expect(
          filter!.group(0),
          contains('android:mimeType="*/*"'),
          reason: '$action 的过滤器要收 */*（对齐官方 ShareActivity）',
        );
      }
    });

    test('接收方是 exported 的 MainActivity（singleTop → 前台走 onNewIntent）', () {
      final body = manifest.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
      final activity =
          RegExp(r'<activity\b(?:(?!</activity>).)*?</activity>', dotAll: true)
              .allMatches(body)
              .map((m) => m.group(0)!)
              .firstWhere(
                (a) => a.contains('android.intent.action.SEND'),
                orElse: () => '',
              );
      expect(activity, isNotEmpty);
      expect(activity, contains('android:name=".MainActivity"'));
      expect(activity, contains('android:exported="true"'));
      expect(activity, contains('android:launchMode="singleTop"'));
    });
  });

  group('ShareIntentData 解析', () {
    test('纯文本', () {
      final d = ShareIntentData.fromMap({
        'action': 'android.intent.action.SEND',
        'mime_type': 'text/plain',
        'text': 'https://example.com/a',
        'subject': '看看这个',
        'files': const [],
        'overflow': 0,
      });
      expect(d, isNotNull);
      expect(d!.hasText, isTrue);
      expect(d.hasFiles, isFalse);
      expect(d.subject, '看看这个');
    });

    test('带附件（原生已把 content:// 落成路径）', () {
      final d = ShareIntentData.fromMap({
        'action': 'android.intent.action.SEND_MULTIPLE',
        'mime_type': 'image/jpeg',
        'text': '',
        'subject': '',
        'files': [
          {
            'path': '/data/cache/share_in/1_a.jpg',
            'name': 'a.jpg',
            'mime': 'image/jpeg',
            'size': 12,
          },
        ],
        'overflow': 3,
      });
      expect(d!.files.single.path, '/data/cache/share_in/1_a.jpg');
      expect(d.files.single.name, 'a.jpg');
      expect(d.overflow, 3, reason: '超过 50 个的计数要传下来提示用户');
    });

    test('既没有文件也没有文本 → null；坏路径被丢掉', () {
      expect(ShareIntentData.fromMap(null), isNull);
      expect(
        ShareIntentData.fromMap({'text': '  ', 'files': const []}),
        isNull,
      );
      final d = ShareIntentData.fromMap({
        'text': '有字',
        'files': [
          {'name': 'no-path.jpg'},
        ],
      });
      expect(d!.files, isEmpty);
      expect(d.hasText, isTrue);
    });
  });

  group('Dart 接收 → 选频道 → 发送', () {
    testWidgets('纯文本分享：选频道后走 Post/create', (tester) async {
      final source = _FakeShareSource(
        const ShareIntentData(
          action: 'android.intent.action.SEND',
          mimeType: 'text/plain',
          text: '分享进来的一句话',
          subject: '',
          files: [],
        ),
      );
      final h = await bootChat(
        moreOverrides: [shareIntentSourceProvider.overrideWithValue(source)],
      );
      await tester.pumpWidget(_hostApp(h.container));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('分享到频道'), findsOneWidget);
      await tester.tap(find.text('测试频道'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final creates = h.transport.calls
          .where(
            (c) =>
                c['api'] == 'SYNO.Chat.Post' &&
                c['method'] == 'create' &&
                // form 那条路的 message 是 Gson 再编码的（带引号），见 createPost
                '${c['message']}'.contains('分享进来的一句话'),
          )
          .toList();
      expect(creates, hasLength(1));
    });

    testWidgets('纯 URL + EXTRA_SUBJECT → 只发 URL，subject **不进正文**（遗留 2 的裁决）', (
      tester,
    ) async {
      // 求证结论（反编译 `/tmp/chat_audit_src` 的 `ShareEditFragment.java:451-475`）：
      // `handleText(subject, text)` 只在 `text` 是**恰好一个 URL** 时把 subject
      // 塞进 `mOGTitleView`（本地链接预览标题），**从不**写进正文；
      // `createPost` 发的也只有「正文 + 空格 + URL」。所以 subject 不必也不该被接上。
      final source = _FakeShareSource(
        const ShareIntentData(
          action: 'android.intent.action.SEND',
          mimeType: 'text/plain',
          text: 'https://example.com/news',
          subject: '页面标题不该进正文',
          files: [],
        ),
      );
      final h = await bootChat(
        moreOverrides: [shareIntentSourceProvider.overrideWithValue(source)],
      );
      await tester.pumpWidget(_hostApp(h.container));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('测试频道'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final creates = h.transport.calls
          .where((c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'create')
          .toList();
      expect(creates, hasLength(1));
      final message = '${creates.single['message']}';
      expect(message, contains('https://example.com/news'));
      expect(
        message.contains('页面标题不该进正文'),
        isFalse,
        reason: '官方把 EXTRA_SUBJECT 当本地预览标题，不写进正文、也不发给服务端',
      );
      // URL 正文会触发链接预览的 4s / 12s 补刷定时器 → 都跑完再结束用例
      await tester.pump(const Duration(seconds: 13));
    });

    testWidgets('带附件分享：走 multipart 上传链路', (tester) async {
      final source = _FakeShareSource(
        const ShareIntentData(
          action: 'android.intent.action.SEND',
          mimeType: 'image/jpeg',
          text: '',
          subject: '',
          files: [
            ShareIntentFile(
              path: '/tmp/flt-shared.jpg',
              name: 'flt-shared.jpg',
              mime: 'image/jpeg',
            ),
          ],
        ),
      );
      final h = await bootChat(
        moreOverrides: [shareIntentSourceProvider.overrideWithValue(source)],
      );
      await tester.pumpWidget(_hostApp(h.container));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('测试频道'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pumpAndSettle();

      final ups = h.transport.calls
          .where(
            (c) =>
                c['api'] == 'SYNO.Chat.Post' &&
                c['method'] == 'create' &&
                c['file_name'] != null,
          )
          .toList();
      expect(ups, isNotEmpty, reason: '分享的附件必须真的上传');
      expect(ups.single['file_name'], 'flt-shared.jpg');
    });
  });
}
