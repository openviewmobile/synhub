// 表情表的回归测试。
//
// 这张表是从 APK 的 `EmojiOne.java` 生成出来的（tool/gen_emoji_table.py），
// 生成脚本一旦改动就可能悄悄歪掉，所以这里盯住"抽样几个必须是正确的"
// 以及"结构上不能有脏数据"。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/emoji_table.dart';
import 'package:synhub/src/features/chat/post_actions_sheet.dart';

void main() {
  group('emoji_table', () {
    test('规模对得上（APK 里是 1787 项）', () {
      expect(kEmojiShortcodes.length, 1787);
      expect(kEmojiCategories.length, kEmojiShortcodes.length);
    });

    test('抽样核对短代码 → 字符', () {
      const samples = {
        'grinning': '😀',
        'joy': '😂',
        'thumbsup': '👍',
        'pray': '🙏',
        'eyes': '👀',
        'tada': '🎉',
        'heart': '❤',
      };
      samples.forEach((name, emoji) {
        expect(kEmojiShortcodes[name], emoji, reason: '$name 应当是 $emoji');
      });
    });

    test('肤色组合和旗帜是多码点', () {
      // e_v_tone1_270c_1f3fb → ✌ + 肤色
      expect(kEmojiShortcodes['v_tone1'], '✌🏻');
      expect(kEmojiShortcodes['flag_us']!.runes.length, 2);
      expect(kEmojiShortcodes['flag_cn']!.contains('🇨'), isTrue);
    });

    test('没有空值 / 也没把名字当字符', () {
      for (final e in kEmojiShortcodes.entries) {
        expect(e.value, isNotEmpty, reason: '${e.key} 是空的');
        expect(
          e.value.startsWith('e_'),
          isFalse,
          reason: '${e.key} 解析歪了：${e.value}',
        );
      }
    });

    test('分类都在已知集合里', () {
      const known = {
        'people',
        'nature',
        'food',
        'activity',
        'travel',
        'objects',
        'symbols',
        'flags',
      };
      for (final c in kEmojiCategories.values) {
        expect(known, contains(c));
      }
    });

    test('反向表能把字符查回短代码', () {
      expect(kEmojiNames['😀'], 'grinning');
      expect(kEmojiNames['👍'], 'thumbsup');
    });

    test('★ DA278：没有一个字符是"别的文字冒充表情"', () {
      // r663 真机面板上出现豆腐块：生成脚本把 drawable 名里的英文单词当码点，
      // `e_neutral_face_1f610` 的 `face` → U+FACE ⇒ 表里是 "U+FACE U+1F610"，
      // 面板上就是"汉字 + 表情"两格。这类脏数据一律不许再出现。
      //
      // 判据：每个字符要么是 1F000+ 的补充平面表情，要么在 BMP 的表情/符号区
      // （箭头 / 星座 / 标点 / 键帽底字 + 组合符）。
      const bmpOk = <int>{
        0x00A9, 0x00AE, 0x203C, 0x2049, 0x2122, 0x2139, 0x20E3, 0x200D, 0xFE0F,
        0x0023, 0x002A, 0x0030, 0x0031, 0x0032, 0x0033, 0x0034, 0x0035,
        0x0036, 0x0037, 0x0038, 0x0039,
      };
      final dirty = <String>[];
      for (final e in kEmojiShortcodes.entries) {
        for (final c in e.value.runes) {
          final ok = c >= 0x1F000 ||
              bmpOk.contains(c) ||
              (c >= 0x2190 && c <= 0x2BFF) || // 箭头 / 星座 / 几何标记
              (c >= 0x3030 && c <= 0x303D) ||
              (c >= 0x3297 && c <= 0x3299);
          if (!ok) {
            dirty.add('${e.key}: U+${c.toRadixString(16).toUpperCase()}');
            break;
          }
        }
      }
      expect(dirty, isEmpty, reason: '这些表情里混进了非表情字符：$dirty');
    });

    test('★ DA278：被截断的组合序列已补全（家庭 / 情侣 / 亲吻）', () {
      // 旧实现只取尾部两个码点 ⇒ family_wwb 变成「👩👦」、kiss_mm 变成「💋👨」
      expect(kEmojiShortcodes['family_wwb'], '\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F466}');
      expect(kEmojiShortcodes['couple_ww'],
          '\u{1F469}\u{200D}\u{2764}\u{FE0F}\u{200D}\u{1F469}');
      expect(kEmojiShortcodes['kiss_mm'],
          '\u{1F468}\u{200D}\u{2764}\u{FE0F}\u{200D}\u{1F48B}\u{200D}\u{1F468}');
      // 组合序列的计数：必须真的多于两个码点
      for (final name in const ['family_mwgb', 'family_mmgg', 'kiss_ww']) {
        expect(kEmojiShortcodes[name]!.runes.length, greaterThan(2), reason: name);
      }
    });

    test('★ DA278：20 个"带前缀汉字"的表情已修好', () {
      for (final name in const [
        'neutral_face', 'tired_face', 'dizzy_face', 'thermometer_face',
        'crying_cat_face', 'person_with_pouting_face', 'nauseated_face',
        'drooling_face', 'lying_face', 'sneezing_face', 'panda_face',
        'lion_face', 'monkey_face', 'dragon_face', 'new_moon_with_face',
        'full_moon_with_face', 'first_quarter_moon_with_face',
        'last_quarter_moon_with_face', 'sun_with_face', 'wind_blowing_face',
        '1234', 'abcd', 'capital_abcd',
      ]) {
        expect(
          kEmojiShortcodes[name]!.runes.length,
          1,
          reason: '$name 应当只有一个码点（旧版前面粘了 U+FACE/U+1234/U+ABCD）',
        );
      }
      expect(kEmojiShortcodes['neutral_face'], '\u{1F610}');
    });

    test('回应面板用短代码，展示用字符', () {
      // 服务端要短代码，所以这里绝不能是 emoji 本体
      for (final name in kQuickReactions) {
        expect(
          kEmojiShortcodes.containsKey(name),
          isTrue,
          reason: '$name 不在短代码表里，服务端会拒',
        );
        expect(emojiForName(name), isNot(name));
      }
      expect(emojiForName('thumbsup'), '👍');
      expect(emojiForName('不认识的贴纸'), '不认识的贴纸');
    });
  });
}
