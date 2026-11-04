// ★★★ 第 317 轮真机缺陷 D14 的守卫：**`dataTextMap` 产出的必须是"带占位符的模板"**。
//
// 真机取证（LGE-AN10）：播放器「在线字幕搜索」失败时界面逐字显示 `source: message`；
// 同型还有 18 条（其中 5 条会显示 `-987654321`）。根因与修法见
// `lib/src/core/i18n/data_text_map_scan.dart` 的头注释。
//
// 本用例三条：
//   ① **真仓扫描**：ARB 里声明了 `{name}` 的每个 key，只要进了 `dataTextMap`，
//      其值就必须含**每一个** `{name}`（中英各一遍）；
//   ② **防空转**：ARB 占位符条目数、表内条目数、被检查到的条目数都要够多，
//      否则等于没扫到东西（AGENTS §1.3.0.1「校验 0 条不是成功，是没校验」）；
//   ③ **反向验证**：喂一份"就是当年那两种坏形态"的合成表，必须**恰好**报出它们 ——
//      只断言 `isEmpty == true` 的负向测试没有鉴别力（AGENTS §2.0.29）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/data_text_map_scan.dart';
import 'package:synhub/src/core/i18n/l10n.dart';

Map<String, dynamic> _arb(String lang) =>
    jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('dataTextMap 模板形态', () {
    test('① 真仓（zh）：ARB 声明的每个 {name} 都必须出现在表值里', () {
      final required = arbPlaceholders(_arb('zh'));
      final bad = dataTextMapMissingPlaceholders(dataTextMap(AppTextZh()), required);
      expect(bad, isEmpty, reason: '这些条目会把占位符原样画到界面上：\n${bad.join('\n')}');
    });

    test('① 真仓（en）：同上', () {
      final required = arbPlaceholders(_arb('en'));
      final bad = dataTextMapMissingPlaceholders(dataTextMap(AppTextEn()), required);
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('② 防空转：真的扫到了足够多的条目', () {
      final zh = arbPlaceholders(_arb('zh'));
      final map = dataTextMap(AppTextZh());
      final checked = zh.keys.where(map.containsKey).length;
      expect(zh.length, greaterThan(300), reason: 'ARB 里带占位符的条目太少 ⇒ 扫描口径变了');
      expect(map.length, greaterThan(1000), reason: 'dataTextMap 条目太少 ⇒ 表没被解析到');
      expect(checked, greaterThan(300), reason: '被检查到的条目太少 ⇒ 守卫在空转');
    });

    test('③ 反向验证：当年那两种坏形态必须被报出来（恰好报出它们）', () {
      // 形态一：生成 getter 的字面参数填了进去（真机逐字 `source: message`）。
      // 形态二：`_kTemplateInt` 没被 `_intTemplate` 包住（界面出现 -987654321）。
      final broken = <String, String>{
        'mediaSubtitleFailureLine': 'source：message',
        'contactLabelValue': 'label：value',
        'noteGapsSelectedCount': '已选 -987654321 项',
        'setGapServerLabel': '{base}（source）', // 半对：base 对、source 错
        'errHttpStatus': '{code}', // 对照：正确形态，**不该**被报
      };
      final required = <String, Set<String>>{
        'mediaSubtitleFailureLine': {'source', 'message'},
        'contactLabelValue': {'label', 'value'},
        'noteGapsSelectedCount': {'count'},
        'setGapServerLabel': {'base', 'source'},
        'errHttpStatus': {'code'},
      };
      final bad = dataTextMapMissingPlaceholders(broken, required);
      expect(bad.length, 4);
      expect(bad.join('\n'), contains('mediaSubtitleFailureLine'));
      expect(bad.join('\n'), contains('contactLabelValue'));
      expect(bad.join('\n'), contains('noteGapsSelectedCount'));
      expect(bad.join('\n'), contains('setGapServerLabel'));
      expect(bad.join('\n'), isNot(contains('errHttpStatus')));
    });
  });
}
