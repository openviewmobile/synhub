// M37 分享链接「发送」的离线用例。
//
// 官方 DS file 创建分享链接后用 `email_link_context` + `EXTRA_SUBJECT` 把链接
// 发出去。本仓库现在的路径是：
//   1. **优先** 原生 `shareText`（既有 `synhub/media_open` 通道，
//      `MediaOpenBridge.kt` 的 ACTION_SEND + `EXTRA_TEXT`/`createChooser`）；
//   2. 桥不可用 / 返回 false → 回落既有 `url_launcher` 的 `mailto:`。
//
// 用例验证：优先走桥、桥 false 才回落邮件、空文本**不碰桥也不碰邮件**、
// 弹层把 url/subject 交给注入的 runner。原生桥用 mock channel 记录调用
// （不启动任何外部应用）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/features/files/file_link_share.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/file_sheets.dart';

const _channel = MethodChannel('synhub/media_open');

/// 装一个假的 `synhub/media_open`：记录调用并回 [result]。
///
/// 返回记录列表；调用 `setMockMethodCallHandler(_channel, null)` 即"通道不可用"。
List<MethodCall> _mockBridge(Object? result) {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return result;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
  return calls;
}

/// 记录 mailto 是否被回落调用。
({List<({String url, String subject})> calls, MailtoLauncher fn})
_mailtoRecorder(bool result) {
  final calls = <({String url, String subject})>[];
  Future<bool> fn({required String url, required String subject}) async {
    calls.add((url: url, subject: subject));
    return result;
  }

  return (calls: calls, fn: fn);
}

void main() {
  // `test()`（非 testWidgets）里用 MethodChannel mock 需要先起 binding
  TestWidgetsFlutterBinding.ensureInitialized();

  // 第 79 轮：`synhub/media_open` 的分享/落盘调用点加了能力门，而宿主（macOS）
  // 上 `systemShare` / `mediaStoreExport` 是 `unavailable` ⇒ 要让"优先走原生
  // shareText / 桥返回 false 回落"这些用例继续测到**桥被调用时发什么**，
  // 先把门打开（`debugForceCapabilityGate`，与 drive_saf 用例同一手法）。
  setUp(() => debugForceCapabilityGate = true);
  tearDown(() => debugForceCapabilityGate = false);

  test('shareLinkMailtoUri：链接在 body、文件名在 subject，空格是 %20', () {
    final uri = shareLinkMailtoUri(
      url: 'https://nas.example.com:5001/sharing/a b',
      subject: '季 报.txt',
    );
    expect(uri.scheme, 'mailto');
    final s = uri.toString();
    expect(
      s,
      contains('body=https%3A%2F%2Fnas.example.com%3A5001%2Fsharing%2Fa%20b'),
    );
    expect(s, contains('subject=%E5%AD%A3%20%E6%8A%A5.txt'));
    // mailto 的 query 不能出现 form 编码的 '+'
    expect(s, isNot(contains('+')));
  });

  test('shareLinkMailtoUri：空 subject 就不发 subject', () {
    final uri = shareLinkMailtoUri(url: 'https://nas/x', subject: '');
    expect(uri.toString(), 'mailto:?body=https%3A%2F%2Fnas%2Fx');
  });

  test('优先走原生 shareText：桥 true 时不发邮件', () async {
    final bridgeCalls = _mockBridge(true);
    final mail = _mailtoRecorder(true);

    final ok = await shareLinkWithFallback(
      url: 'https://nas/x',
      subject: 'a.txt',
      bridge: const TextShareBridge(),
      mailto: mail.fn,
    );

    expect(ok, isTrue);
    expect(bridgeCalls, hasLength(1), reason: '必须优先调原生文本桥');
    expect(bridgeCalls.single.method, 'shareText');
    expect(bridgeCalls.single.arguments['text'], 'https://nas/x');
    expect(bridgeCalls.single.arguments['subject'], 'a.txt');
    expect(mail.calls, isEmpty, reason: '桥成功就不要回落邮件');
  });

  test('桥返回 false → 回落 mailto（并沿用同一 url/subject）', () async {
    final bridgeCalls = _mockBridge(false);
    final mail = _mailtoRecorder(true);

    final ok = await shareLinkWithFallback(
      url: 'https://nas/y',
      subject: 'b.txt',
      bridge: const TextShareBridge(),
      mailto: mail.fn,
    );

    expect(ok, isTrue);
    expect(bridgeCalls.single.method, 'shareText');
    expect(mail.calls, hasLength(1), reason: '桥说没人能接才回落邮件');
    expect(mail.calls.single.url, 'https://nas/y');
    expect(mail.calls.single.subject, 'b.txt');
  });

  test('通道不可用（没挂桥）→ 回落 mailto', () async {
    // 不设 mock handler：invokeMethod 抛 MissingPluginException
    final mail = _mailtoRecorder(true);

    final ok = await shareLinkWithFallback(
      url: 'https://nas/z',
      subject: '',
      bridge: const TextShareBridge(),
      mailto: mail.fn,
    );

    expect(ok, isTrue);
    expect(mail.calls, hasLength(1));
  });

  test('text 为空：不碰桥也不碰 mailto', () async {
    final bridgeCalls = _mockBridge(true);
    final mail = _mailtoRecorder(true);

    final ok = await shareLinkWithFallback(
      url: '',
      subject: 'a.txt',
      bridge: const TextShareBridge(),
      mailto: mail.fn,
    );

    expect(ok, isFalse);
    expect(bridgeCalls, isEmpty);
    expect(mail.calls, isEmpty);

    // 桥本身也短路空文本
    expect(
      await const TextShareBridge().shareText(text: '', subject: 'a.txt'),
      isFalse,
    );
    expect(bridgeCalls, isEmpty);
  });

  testWidgets('创建成功弹层有「发送」，点了把 url/subject 交给分享桥', (tester) async {
    String? gotUrl;
    String? gotSubject;
    Future<bool> fake({required String url, required String subject}) async {
      gotUrl = url;
      gotSubject = subject;
      return true;
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [linkShareProvider.overrideWithValue(fake)],
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showShareLinkCreatedSheet(
                  context,
                  'https://nas.example.com:5001/sharing/abc',
                  subject: 'a.txt',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('发送'), findsOneWidget);
    await tester.tap(find.byKey(const Key('share-link-send')));
    await tester.pumpAndSettle();

    expect(gotUrl, 'https://nas.example.com:5001/sharing/abc');
    expect(gotSubject, 'a.txt');
    // 发出去后弹层关闭
    expect(find.text('发送'), findsNothing);
  });
}
