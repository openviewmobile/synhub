// `DA278`：表情面板 —— 「emoji 不全，很多没有展示」＋「顶上的分类定位不准」。
//
// 用户 2026-10-25 报。两件事的根因：
//   ① 面板只画服务端 `is_emoji=true` 的分类（真机这台 NAS 只回了 3 个贴纸分类）
//      ⇒ 一个表情都没有；而且表情入口还受"有没有贴纸目录"门控。
//   ② 分类条是裸 `ListView`：选中项不滚进视野、末尾 chip 被屏幕边缘切一半，
//      与下面的内容**毫无联动**。
//
// 这里的判据分三层：
//   * 数据层：官方 `emojione1..8` 八组是否还原完整（1787 项、每项恰好一组）；
//   * 交互层：点 chip 能不能真的滚到那一段、滚内容时 chip 会不会跟着走；
//   * 结果层：点一个表情返回的是**短代码**（服务端只认它）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/sticker_dto.dart';
import 'package:synhub/src/data/emoji_table.dart';
import 'package:synhub/l10n/gen/app_localizations.dart';
import 'package:synhub/src/features/chat/emoji_picker_sheet.dart';
import 'package:synhub/src/features/chat/emoji_sections.dart';
import 'package:synhub/src/features/chat/post_actions_sheet.dart';
import 'package:synhub/src/features/chat/sticker_catalog.dart';

StickerCatalog _catalog() => StickerCatalog.parse({
  'categories': [
    {
      'category_id': 9,
      'name': 'business_man',
      'is_emoji': false,
      'stickers': [
        {'sticker_id': 81, 'name': 'business_man_01'},
        {'sticker_id': 82, 'name': 'business_man_02'},
      ],
    },
    {
      'category_id': 7,
      'name': 'dog',
      'is_emoji': false,
      'stickers': [
        {'sticker_id': 123, 'name': 'dog_01'},
      ],
    },
    // 服务端也有一份表情分类：名字**全在内置表里** ⇒ 不许在面板里再出现一遍
    {
      'category_id': 11,
      'name': 'emoji',
      'is_emoji': true,
      'stickers': [
        {'sticker_id': 900, 'name': 'grinning'},
        {'sticker_id': 901, 'name': 'thumbsup'},
      ],
    },
  ],
});

/// 打开面板。`onPicked` 拿到面板返回值（用来验"点一个表情返回什么"）。
Future<void> _openPicker(
  WidgetTester tester, {
  StickerCatalog? catalog,
  bool reactionsOnly = false,
  void Function(EmojiPicked?)? onPicked,
}) async {
  final container = ProviderContainer(
    overrides: [
      if (catalog != null)
        stickerCatalogProvider.overrideWith((ref) async => catalog),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        localizationsDelegates: AppText.localizationsDelegates,
        supportedLocales: AppText.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  final r = await showEmojiPicker(
                    context,
                    reactionsOnly: reactionsOnly,
                  );
                  onPicked?.call(r);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder _chip(String label) => find.widgetWithText(ChoiceChip, label);

void main() {
  group('DA278：八组内置表情', () {
    test('① 顺序 = 官方 emojione1..8', () {
      expect(
        emojiGroups().map((g) => g.category).toList(),
        kEmojiCategoryOrder,
      );
      expect(kEmojiCategoryOrder, hasLength(8));
    });

    test('② 一项不少：八组加起来正好是整张表，没有一组是空的', () {
      final groups = emojiGroups();
      final total = groups.fold<int>(0, (n, g) => n + g.length);
      expect(total, kEmojiShortcodes.length);
      for (final g in groups) {
        expect(g.length, greaterThan(20), reason: '${g.category} 太少，像掉了数据');
      }
    });

    test('③ 每一项恰好归一组，且都能画成字符', () {
      final seen = <String>{};
      for (final g in emojiGroups()) {
        for (final name in g.names) {
          expect(seen.add(name), isTrue, reason: '$name 出现在两组里');
          expect(kEmojiShortcodes[name], isNotEmpty, reason: '$name 没有字符');
          expect(kEmojiShortcodes[name], isNot(name), reason: '$name 被当成字符了');
        }
      }
      expect(seen.length, kEmojiShortcodes.length);
    });

    test('④ 组内顺序 = 表里的原始顺序（官方数组顺序，不排序）', () {
      final people = emojiGroups().first;
      // 表里 people 组的前几项就是 APK 里的前几项
      expect(people.names.take(4).toList(), [
        'grinning',
        'grimacing',
        'grin',
        'joy',
      ]);
    });

    test('⑤ 服务端自定义表情：只挑内置表没有的名字', () {
      expect(customEmojiNames(['grinning', 'my_custom']), ['my_custom']);
      expect(customEmojiNames(['grinning', 'thumbsup']), isEmpty);
    });
  });

  group('DA278：面板', () {
    testWidgets('⑥ 没有贴纸目录也照样能出表情（入口不再被贴纸门控）', (tester) async {
      await _openPicker(tester);
      expect(_chip('表情'), findsOneWidget);
      expect(_chip('旗帜'), findsOneWidget);
      expect(find.text('😀'), findsOneWidget);
    });

    testWidgets('⑦ 顶上的分类条：八组都在，且末尾那颗不被切掉', (tester) async {
      await _openPicker(tester);
      for (final label in ['表情', '自然', '食物', '活动', '出行', '物品', '符号', '旗帜']) {
        expect(_chip(label), findsOneWidget, reason: '缺分类 $label');
      }
      // 分类条是横滑的：允许离屏，但**不许被窗口边缘切一半**式地漂着
      final rect = tester.getRect(_chip('表情'));
      expect(rect.left, greaterThanOrEqualTo(0));
    });

    testWidgets('⑧ 点「旗帜」⇒ 内容真的滚到旗帜段（定位准）', (tester) async {
      await _openPicker(tester);
      final flags = emojiGroups().last;
      // 旗帜段的第一颗（按官方顺序）+ 深一点的一颗（一开始不该在视野里）
      final firstFlag = kEmojiShortcodes[flags.names.first]!;
      final deepFlag = kEmojiShortcodes[flags.names[60]]!;
      expect(find.text(deepFlag), findsNothing, reason: '一开始不该看到旗帜');
      await tester.tap(_chip('旗帜'));
      await tester.pumpAndSettle();
      expect(
        find.text(firstFlag),
        findsWidgets,
        reason: '点了「旗帜」却还停在别处 —— 分类与内容没对上',
      );
      // 点完以后这颗 chip 必须自己在视野里（上一版会停在屏幕外/被边缘切一半）
      final chip = tester.getRect(_chip('旗帜'));
      final screen = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(chip.right, lessThanOrEqualTo(screen));
      expect(chip.left, greaterThanOrEqualTo(0));
    });

    testWidgets('⑨ 滚内容 ⇒ 高亮跟着走（不再是死 chip）', (tester) async {
      await _openPicker(tester, catalog: _catalog());
      expect(tester.widget<ChoiceChip>(_chip('表情')).selected, isTrue);
      // 先点远的分类（验证"点 chip ⇒ 内容跟着走"那一半）
      await tester.tap(_chip('旗帜'));
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(_chip('旗帜')).selected, isTrue);
      expect(tester.widget<ChoiceChip>(_chip('表情')).selected, isFalse);
      // 再一路滚到底（验证"内容滚 ⇒ chip 跟着走"那一半）
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -40000));
      await tester.pumpAndSettle();
      // 到底了：高亮的是最后一段（服务端贴纸分类 dog），旗帜已经退出
      expect(tester.widget<ChoiceChip>(_chip('dog')).selected, isTrue);
      expect(tester.widget<ChoiceChip>(_chip('旗帜')).selected, isFalse);
    });

    testWidgets('⑩ 服务端贴纸分类还在；服务端那份 emoji 分类不重复出现', (tester) async {
      await _openPicker(tester, catalog: _catalog());
      expect(_chip('business_man'), findsOneWidget);
      expect(_chip('dog'), findsOneWidget);
      // 服务端 emoji 分类里全是内置表已有的名字 ⇒ 不出这一段
      expect(_chip('emoji'), findsNothing);
    });

    testWidgets('⑪ 点一个表情 ⇒ 返回短代码（服务端只认它）', (tester) async {
      EmojiPicked? picked;
      await _openPicker(tester, onPicked: (r) => picked = r);
      await tester.tap(find.text('😀'));
      await tester.pumpAndSettle();
      expect(picked?.shortcode, 'grinning');
      expect(picked?.sticker, isNull);
    });

    testWidgets('⑫ 表情回应模式：只给表情，不给贴纸', (tester) async {
      await _openPicker(tester, catalog: _catalog(), reactionsOnly: true);
      expect(_chip('表情'), findsOneWidget);
      expect(_chip('business_man'), findsNothing);
      expect(_chip('dog'), findsNothing);
    });

    testWidgets('⑭ 表情回应面板：六个常用之外能打开全部表情，选完给短代码', (tester) async {
      String? reaction;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            locale: const Locale('zh'),
            localizationsDelegates: AppText.localizationsDelegates,
            supportedLocales: AppText.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () async {
                      reaction = await showReactionPicker(context);
                    },
                    child: const Text('react'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('react'));
      await tester.pumpAndSettle();
      // 常用六个还在
      expect(find.text('👍'), findsOneWidget);
      // 「全部表情」⇒ 完整面板
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(_chip('表情'), findsOneWidget);
      expect(_chip('business_man'), findsNothing);
      await tester.tap(find.text('😀'));
      await tester.pumpAndSettle();
      expect(reaction, 'grinning');
    });

    testWidgets('⑬ 英文界面：分类标题是英文（不是中文漏翻）', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            locale: const Locale('en'),
            localizationsDelegates: AppText.localizationsDelegates,
            supportedLocales: AppText.supportedLocales,
            home: const Scaffold(body: EmojiPickerSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_chip('Smileys & people'), findsOneWidget);
      expect(_chip('Flags'), findsOneWidget);
      expect(find.text('表情'), findsNothing);
    });
  });
}
