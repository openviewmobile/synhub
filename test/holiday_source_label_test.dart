// ★★★ 第 349 轮 D70：节假日来源行**把聚合器的原始 id 当用户文案**
// （真机像素实测 `节假日 nager+lunar`），而 `HolidaySource.labelText()`
// 明明已经存在、ARB 键中英文齐全、**却一个调用点都没有**。
//
// 同一行里**天气源**走 `provider.nameText()`（本地化名字），
// 只有节假日这一条漏了 ⇒ §2.0.26「同一语义被造成两份表示」
// ＋ §2.0.57「封装了没有 caller = 死功能」。
//
// 本文件钉住三件事（缺少反向的那一条，"永远返回空串"也能全绿）：
//   ① id 必须渲染成**本地化标签**，不许再出现原始 id；
//   ② ★ 反向：**认不出的 id 必须原样保留**（不许把来源悄悄吞掉）；
//   ③ ★ 反向：`fromId` 对未知/空串返回 null（不许瞎猜一个源）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/data/holidays/holiday_service.dart';

void main() {
  setUp(() => setCurrentText(lookupAppText(const Locale('zh'))));

  group('★ r349 D70 节假日来源名：走本地化标签，不走原始 id', () {
    test('① 真机像素里那一条（nager+lunar）必须变成可读来源名', () {
      final out = HolidaySource.sourceLabels(const ['nager', 'lunar']);
      // 像素上的缺陷串
      expect(
        out.contains('nager+lunar'),
        isFalse,
        reason: '原始 id 不许再出现在用户可见文案里',
      );
      expect(out.contains('Nager.Date'), isTrue, reason: '必须是本地化标签');
      expect(out.contains('农历'), isTrue);
    });

    test('① 单个源与三个源都走同一条路', () {
      expect(
        HolidaySource.sourceLabels(const ['nager']).contains('nager'),
        isFalse,
      );
      final all = HolidaySource.sourceLabels(const [
        'openholidays',
        'nager',
        'lunar',
      ]);
      expect(all.contains('OpenHolidays'), isTrue);
      expect(all.contains('Nager.Date'), isTrue);
      expect(all.contains('农历'), isTrue);
    });

    test('② ★ 反向：认不出的 id 必须**原样保留**（不许把来源吞掉）', () {
      final out = HolidaySource.sourceLabels(const ['nager', 'weird-source']);
      expect(
        out.contains('weird-source'),
        isTrue,
        reason: '宁可显示一个陌生代号，也不许悄悄丢来源',
      );
      expect(out.contains('Nager.Date'), isTrue);
    });

    test('③ ★ 反向：fromId 对未知 id / 空串必须返回 null（不许瞎猜）', () {
      expect(HolidaySource.fromId('nope'), isNull);
      expect(HolidaySource.fromId(''), isNull);
      expect(HolidaySource.fromId('Nager'), isNull, reason: '大小写敏感，别模糊匹配');
      // 正向：真 id 必须查得到（否则上面的 null 断言毫无意义）
      expect(HolidaySource.fromId('nager'), HolidaySource.nager);
      expect(HolidaySource.fromId('lunar'), HolidaySource.lunar);
      expect(HolidaySource.fromId('openholidays'), HolidaySource.openHolidays);
    });

    test('③ labelText() 必须真的本地化（不许等于 id、也不许等于英文键名）', () {
      for (final s in HolidaySource.values) {
        final label = s.labelText();
        expect(label, isNotEmpty);
        expect(label, isNot(s.id), reason: '${s.id} 的标签不能退回成 id');
        expect(label, isNot(s.labelKey));
      }
    });
  });

  // ★ r520（DA162，真机像素）：来源行把**实现细节**当用户文案画出来 ——
  // 真机亮色实测一行读到
  // `CN (Calendar timezone) · Holidays Nager.Date (204 countries worldwide) +
  //  Local lunar calendar (traditional festivals / solar terms / Chinese make-up days)`
  // 并被省略号截断。来源名只该是**名字**，括号里的"多少国/哪些节气"是文档。
  test('DA162：节假日来源名里不许出现括号补充说明', () {
    for (final lang in const [Locale('zh'), Locale('en')]) {
      final t = lookupAppText(lang);
      final labels = <String>[
        t.holidaySourceOpenHolidays,
        t.holidaySourceNager,
        t.holidaySourceLunar,
      ];
      for (final label in labels) {
        expect(label.contains('(') || label.contains('（'), isFalse,
            reason: 'DA162：$lang 的来源名「$label」还带着实现细节');
        expect(label.length, lessThanOrEqualTo(24),
            reason: 'DA162：$lang 的来源名「$label」太长，会把整行挤到省略号');
      }
    }
  });
}
