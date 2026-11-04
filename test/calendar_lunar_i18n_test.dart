// ★ 第 260 轮：**英文界面里农历仍是中文**（"中英混排"）的回归用例。
//
// 真机现象（Honor LGE-AN10，英文语言）：日历卡片显示
//   「初二 九月初二」——`lunar` 包只给中文，`ChineseCalendar.infoFor`
//   直接把 `getMonthInChinese()`/`getDayInChinese()` 拼进了字符串。
//
// 修法：数据层不判断语言，把**两种写法都交给 ARB 模板**
// （zh `{zh}` / en `Lunar {m}/{d}`），取值时各语言自己挑占位符。
//
// 判据（对应用户能看到的现象）：**英文模式下这些串里不许出现任何汉字**。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/data_text.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/data/holidays/holiday_service.dart';

/// 中日韩统一汉字（含扩展 A）——出现一个就说明"混排"。
final _cjk = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff]');

void main() {
  // 覆盖三类分支（日期与农历值都用探针实测过，不是猜的）：
  //   * 2026-10-11 普通农历日 → 初二
  //   * 2026-10-12 普通农历日 → 初三
  //   * 2026-03-19 农历初一（无节日）→ 走"X月"分支
  //   * 2026-01-01 公历元旦 → 节日分支（靠 ARB 表翻译）
  final samples = <DateTime>[
    DateTime(2026, 10, 11),
    DateTime(2026, 10, 12),
    DateTime(2026, 3, 19),
    DateTime(2026, 1, 1),
  ];

  tearDown(() => setCurrentText(currentText()));

  test('① 英文模式：农历小标签 / 农历月日 **不含汉字**', () {
    setCurrentText(AppTextEn());
    for (final d in samples) {
      final info = ChineseCalendar.infoFor(d);
      // 节气名是农历包原文（无通行英文表）⇒ 本用例对它不作要求，
      // 但它在英文下也不该混进"农历日期"这两个字段。
      expect(
        _cjk.hasMatch(info.lunarMonthDay),
        isFalse,
        reason: '${d.toIso8601String()} 的 lunarMonthDay=「${info.lunarMonthDay}」仍是中文',
      );
      if (info.labelKind.name != 'solarTerm') {
        expect(
          _cjk.hasMatch(info.label),
          isFalse,
          reason: '${d.toIso8601String()} 的 label=「${info.label}」仍是中文',
        );
      }
    }
  });

  test('② 英文模式的具体写法（月/日用阿拉伯数字，且**不含歧义**）', () {
    setCurrentText(AppTextEn());
    // 普通农历日
    expect(ChineseCalendar.infoFor(DateTime(2026, 10, 11)).lunarMonthDay,
        'Lunar 9/2');
    expect(ChineseCalendar.infoFor(DateTime(2026, 10, 11)).label, 'Lunar day 2');
    expect(ChineseCalendar.infoFor(DateTime(2026, 10, 12)).lunarMonthDay,
        'Lunar 9/3');
    // 初一分支：**必须写清是"月"**（只写 `Lunar 9` 会和"初九"撞车）
    expect(ChineseCalendar.infoFor(DateTime(2026, 3, 19)).label, 'Lunar month 2');
    expect(ChineseCalendar.infoFor(DateTime(2026, 3, 19)).lunarMonthDay,
        'Lunar 2/1');
    // 节日走既有 i18n 表
    expect(ChineseCalendar.infoFor(DateTime(2026, 1, 1)).label, "New Year's Day");
  });

  test('③ 中文模式：仍保持原有中文写法（没把中文也改坏）', () {
    setCurrentText(AppTextZh());
    expect(ChineseCalendar.infoFor(DateTime(2026, 10, 11)).lunarMonthDay,
        '九月初二');
    expect(ChineseCalendar.infoFor(DateTime(2026, 10, 11)).label, '初二');
    expect(ChineseCalendar.infoFor(DateTime(2026, 10, 12)).lunarMonthDay,
        '九月初三');
    // 初一分支仍是"九月"（没被英文写法污染）
    expect(ChineseCalendar.infoFor(DateTime(2026, 3, 19)).label, '二月');
    expect(ChineseCalendar.infoFor(DateTime(2026, 3, 19)).lunarMonthDay, '二月初一');
  });

  test('④ 反向验证：未设置 en 表时回落中文（证明这条用例真能抓到现象）', () {
    // 数据层的**原始**构造方式（修复前就是这么写的）——英文下必然是中文，
    // 这正是用户看到的"中英混排"。
    setCurrentText(AppTextEn());
    final raw = dataText('不存在的key', '九月初二');
    expect(_cjk.hasMatch(raw), isTrue,
        reason: '未登记的 key 回落中文原文 —— 修法就是把这两种写法都登记进模板');
  });
}
