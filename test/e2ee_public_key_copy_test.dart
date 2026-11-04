// ★★ r344 / D57：端到端加密页的「我的公钥」被**单行省略号**截断，而它是全应用
// **唯一**展示公钥的地方，且没有复制/展开出口 ⇒ 用户永远读不到自己的公钥
// （§2.0.18「固定预算里的文本截断只能靠测量/改文案」的镜像形态：
//  这里截的不是"诊断读数"，而是**用户自己的密钥**，所以必须给出口）。
//
// 真机现象（包 M，375dp）：`已开启，当前锁定` / `我的公钥：Io1lASoH1Z+J2R2RUrLiyakRURW…`
// —— `…` 后面那 32 个字符在界面上**任何地方都看不到**。
//
// 本用例钉三件事（缺一条这个缺陷就能回来）：
//   ① **真**写进剪贴板（挂 `SystemChannels.platform` mock 截获实际字符串，
//      照抄 `test/chat_copy_and_send_by_enter_test.dart:31-54` 的手法）；
//   ② 复制的是**完整**公钥 —— 特别钉住**尾段**（显示串正是从尾段开始被切掉的，
//      所以"复制了显示串"这条错法一定会红）；
//   ③ 页面那条渲染点**接上了**这条出口 + 两个语言都有文案（静态守卫，带非空锚）。
//
// 不碰真机、不碰真 NAS（§5.1）。完整链路的最后一跳（手指点下去真弹提示条）
// 由真机像素背书（`docs/evidence-r343/r344-e2ee-copy-key.png`）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/settings/e2ee_page.dart';

/// 合成公钥：长度与真机一致（44 字符 base64），且**故意带 `+` `/` `=`**
/// —— 真机的 key 也是这个形状（`Io1lASoH1Z+J2R2RUrLiyakRURW…`）。
const String kFullKey = 'Io1lASoH1Z+J2R2RUrLiyakRURWqkDl2cQx0XB7m5sT4=';

/// 挂一个只截获 `Clipboard.setData` 的平台通道 mock，返回读取器。
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

Future<void> _pump(WidgetTester tester, String key) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => copyE2eePublicKey(ctx, key),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 去掉注释后计数 —— 否则注释里提到 `t.e2eePublicKey(` 会把静态判据带偏
/// （§2.0.63⑤ 的老坑：守卫要清点它"认哪些字面形状"）。
String _stripComments(String s) {
  final out = StringBuffer();
  for (final line in s.split('\n')) {
    final i = line.indexOf('//');
    out.writeln(i < 0 ? line : line.substring(0, i));
  }
  return out.toString();
}

void main() {
  group('E2EE-KEY-1. 公钥必须能**完整**取走（D57）', () {
    testWidgets('★ 复制真的写进剪贴板，且内容是**完整**公钥（尾段也在）', (tester) async {
      final copied = _mockClipboard(tester);
      await _pump(tester, kFullKey);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      final got = copied();
      expect(got, isNotNull, reason: '点下去必须真的写剪贴板');
      expect(got, kFullKey, reason: '复制的必须是原值，不是显示串');
      expect(got!.length, kFullKey.length);
      // ★ 尾段是显示串被切掉的那半 —— 复制"显示串"这条错法会先在这里红。
      expect(
        got.substring(30),
        kFullKey.substring(30),
        reason: '显示串从第 31 个字符起就是 `…`，尾段必须在',
      );
      expect(got.endsWith('…'), isFalse);
      expect(find.byType(SnackBar), findsOneWidget, reason: '复制后要有提示');
    });

    testWidgets('★ 空白公钥不写剪贴板、也不弹提示（不制造"已复制"的假成功）', (tester) async {
      final copied = _mockClipboard(tester);
      await _pump(tester, '   ');
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(copied(), isNull);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('E2EE-KEY-2. 页面那条渲染点必须接上出口（静态接线守卫）', () {
    final raw = File(
      'lib/src/features/settings/e2ee_page.dart',
    ).readAsStringSync();
    final code = _stripComments(raw);

    test('★ 非空锚：公钥**只有一处**展示点（守卫不是空转）', () {
      expect(
        't.e2eePublicKey('.allMatches(code).length,
        1,
        reason: '若展示点变多了，这条守卫的"唯一出口"前提就不成立，必须重新审',
      );
      expect(code.contains('state.publicKey.isNotEmpty'), isTrue);
    });

    test('★ 展示点挂着复制入口，且复制的是 `state.publicKey` 原值', () {
      expect(code.contains("Key('e2ee-copy-public-key')"), isTrue);
      expect(
        code.contains('copyE2eePublicKey(context, state.publicKey)'),
        isTrue,
        reason: '必须是原值；复制 `t.e2eePublicKey(...)` 那种显示串 = 缺陷没修',
      );
      // 复制入口与唯一展示点必须在**同一个 if** 里（不能只挂在别的分支上）
      final ifIdx = code.indexOf('state.publicKey.isNotEmpty');
      final tapIdx = code.indexOf("Key('e2ee-copy-public-key')");
      expect(tapIdx, greaterThan(ifIdx));
    });

    test('★ 两语言都有文案键（缺一个就会露出 raw key 或空提示）', () {
      for (final p in const ['lib/l10n/app_zh.arb', 'lib/l10n/app_en.arb']) {
        final arb = File(p).readAsStringSync();
        expect(arb.contains('"e2eeCopyPublicKey"'), isTrue, reason: p);
        expect(arb.contains('"e2eePublicKeyCopied"'), isTrue, reason: p);
      }
    });
  });
}
