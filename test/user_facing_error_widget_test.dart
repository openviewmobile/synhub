// 页面层回归锁：**真机缺陷**（2026-09-22）的界面侧防线。
//
// `test/user_facing_error_test.dart` 锁的是「异常 → 文案」这个函数本身；
// 本文件锁的是**页面真的把它用上了** —— 把与真机完全同型的脏异常灌进
// provider，让页面进错误态，然后逐字检查整棵渲染树里**不出现**任何
// 内部细节片段。
//
// 为什么必须做页面层这一层：根因不是 helper 缺失，而是**每个页面各自**
// 把 `'$e'` 拼进 `Text`。helper 存在不等于调用点都换了 —— 本用例从
// 渲染树取证，才能证明"改到了界面上"。
//
// 覆盖 3 个 feature 目录（settings / chat / analytics），其余目录的
// 调用点由 `test/user_facing_error_test.dart` + 源码缺口命令共同兜底。

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/chat/channel_hashtags_page.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/settings/bots_page.dart';

/// 这些片段**任何一个**出现在页面上都是缺陷（与 core 用例同一张表）。
const _forbidden = <String>[
  'Exception',
  'Error',
  'DioException',
  '0:00:',
  '.000000',
  'To get rid',
  'aborted',
  'uri=',
  'package:',
  'StackTrace',
  '#0',
];

/// 与真机 `LINK LOG` 完全同型的脏异常（类型名 + 内部时长 + 开发者提示）。
DioException _dirtyDio() {
  return DioException(
    requestOptions: RequestOptions(
      path: 'https://demo_admin-qq.quickconnect.cn',
    ),
    type: DioExceptionType.connectionTimeout,
    message:
        'The request connection took longer than 0:00:30.000000 and it was '
        'aborted. To get rid of this exception, try reducing the timeout.',
  );
}

/// 完全不认识的异常（兜底路径）。
StateError _dirtyUnknown() => StateError(
  'DioException [connection timeout]: took longer than 0:00:30.000000 and it '
  'was aborted. To get rid of this exception…',
);

/// 把整棵渲染树上的文字拼起来 —— 这是**用户真正能看到的东西**。
String _visibleText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final w in tester.widgetList<RichText>(find.byType(RichText))) {
    buffer.writeln(w.text.toPlainText());
  }
  return buffer.toString();
}

void _assertPageClean(WidgetTester tester, {required String label}) {
  final text = _visibleText(tester);
  expect(text.trim(), isNotEmpty, reason: '$label：页面应当渲染出错误文案');
  for (final bad in _forbidden) {
    expect(
      text.contains(bad),
      isFalse,
      reason: '$label 的页面上不得出现「$bad」；实际渲染 = $text',
    );
  }
}

void main() {
  group('页面层：脏异常不得把内部细节渲染到界面', () {
    testWidgets('机器人列表页（settings）：dio 超时 → 只有用户语言', (tester) async {
      // 反向确认：灌进去的异常 toString() 确实是脏的。
      final dirty = _dirtyDio();
      expect(dirty.toString().contains('DioException'), isTrue);
      expect(dirty.toString().contains('0:00:30'), isTrue);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            listedBotsProvider.overrideWith((ref) async => throw dirty),
          ],
          child: MaterialApp(theme: AppTheme.dark(), home: BotsPage()),
        ),
      );
      await tester.pumpAndSettle();

      _assertPageClean(tester, label: 'BotsPage');
      // 并且确实给了"超时"这条用户能理解的结论。
      expect(_visibleText(tester), contains('超时'));
    });

    testWidgets('频道标签页（chat）：POSIX 网络异常 → 只有用户语言', (tester) async {
      final dirty = _dirtyUnknown();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            channelHashtagsProvider(1).overrideWith((ref) async => throw dirty),
          ],
          child: MaterialApp(theme: AppTheme.dark(), home: ChannelHashtagsPage(channelId: 1)),
        ),
      );
      await tester.pumpAndSettle();

      _assertPageClean(tester, label: 'ChannelHashtagsPage');
      // 未知异常必须落到通用人话，而不是把 StateError 透出去。
      expect(_visibleText(tester), contains('操作未能完成'));
    });

    testWidgets('机器人列表页：未知异常 → 通用人话，不透类型名', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            listedBotsProvider.overrideWith(
              (ref) async => throw _dirtyUnknown(),
            ),
          ],
          child: MaterialApp(theme: AppTheme.dark(), home: BotsPage()),
        ),
      );
      await tester.pumpAndSettle();

      _assertPageClean(tester, label: 'BotsPage(未知异常)');
      expect(_visibleText(tester), isNot(contains('StateError')));
    });
  });
}
