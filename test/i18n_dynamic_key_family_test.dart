// ★★ DA11（r356 真机取证）：**"拼出来的 key"是 i18n 守卫的结构性盲区**。
//
// 真机读数（HONOR LGE-AN10，英文界面）：Drive「分类浏览」页四个 chip 显示
// `照片 (1)` / `文档 (16)` —— 模板是英文的（半角括号），**只有 label 是中文**。
//
// 根因：`DriveMediaKind.label()` 用 `driveG4('driveCategory$name', zh)`，
// key 是**插值拼出来的**。而两道静态守卫都看不见它：
//   * `test/i18n_coverage_test.dart` 的 `_usedKeys()` 正则要求**字面 key**
//     （`'([A-Za-z0-9_]+)'`），插值串不匹配 ⇒ ②"漏登记"查不到；
//   * `test/i18n_source_scan_test.dart` 只扫 `*Text(` 家族、且**豁免翻译助手的
//     第 2 实参**（那是 i18n 入口本身）⇒ 中文兜底原文不算"硬编码中文"。
// 运行时 `dataText` 查不到 key 就**静默回落中文原文**（`data_text.dart`），
// 所以中文模式下看不出来、英文模式下当场露馅。
//
// 本文件是**动态 key 家族的枚举守卫**（静态那一半在 `i18n_coverage_test` 的
// 第 ⑦ 条：插值 key 的调用点必须进 allowlist 并写明理由）。这里对着**真实的
// 翻译器**（`setCurrentText`，与 `SynologyChatApp.build` 同一条注入路径）逐条
// 断言"英文下不许回落中文"——**枚举得出来才能守住**。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/data_text.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/data/region/region_context.dart';
import 'package:synhub/src/features/drive/drive_category_page.dart';

/// 中日韩字符 + 全角标点（与 `i18n_coverage_test.dart` 同一把尺子）。
final _cjk = RegExp(r'[\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF]');

void main() {
  tearDown(() => setCurrentText(AppTextZh()));

  group('DA11：Drive 分类 chip 的字面 key', () {
    test('★ 四个分类的 key 必须是字面量（不许再拼 key）', () {
      for (final k in DriveMediaKind.values) {
        expect(
          k.i18nKey.contains(r'$'),
          isFalse,
          reason: '${k.name} 的 i18nKey 又变成插值串了：${k.i18nKey}',
        );
        expect(k.i18nKey, startsWith('driveCategory'));
      }
      // 具体读数（防"随便起了个名字也算过"）
      expect(DriveMediaKind.photo.i18nKey, 'driveCategoryPhoto');
      expect(DriveMediaKind.video.i18nKey, 'driveCategoryVideo');
      expect(DriveMediaKind.audio.i18nKey, 'driveCategoryAudio');
      expect(DriveMediaKind.document.i18nKey, 'driveCategoryDocument');
    });

    test('★ 英文下四个 label 不许回落中文（真机英文界面同款判据）', () {
      setCurrentText(AppTextEn());
      // 装置自证：翻译器确实装上了（不是"反正没装 ⇒ 永远中文"那种假绿）
      expect(currentText(), isA<AppTextEn>());
      expect(
        dataText('driveCategoryPhoto', '照片'),
        'Photos',
        reason: '翻译器没生效或 key 没登记（真机英文界面就是这个形态）',
      );

      final labels = {
        for (final k in DriveMediaKind.values) k: k.label(),
      };
      for (final e in labels.entries) {
        expect(
          _cjk.hasMatch(e.value),
          isFalse,
          reason: '${e.key.name} 在英文模式下回落了中文兜底：${e.value}',
        );
      }
      expect(labels[DriveMediaKind.photo], 'Photos');
      expect(labels[DriveMediaKind.video], 'Videos');
      expect(labels[DriveMediaKind.audio], 'Audio');
      expect(labels[DriveMediaKind.document], 'Documents');
    });

    test('★ 反向验证：同一判据在中文表下必须红（证明它不是空转）', () {
      setCurrentText(AppTextZh());
      final zhLabels = [
        for (final k in DriveMediaKind.values) k.label(),
      ];
      expect(
        zhLabels.where(_cjk.hasMatch).length,
        DriveMediaKind.values.length,
        reason: '中文表下四个 label 本来就该含中文 —— 若这里不红，'
            '上面的"英文下不许含中文"就是空转判据',
      );
    });
  });

  group('动态 key 家族：officeDocTocLevel<N>（DA11b）', () {
    test('★ 6 个层级的语义标签全部登记（英文下不回落中文）', () {
      setCurrentText(AppTextEn());
      for (var n = 1; n <= 6; n++) {
        final v = dataText('officeDocTocLevel$n', '$n 级标题');
        expect(
          _cjk.hasMatch(v),
          isFalse,
          reason: '第 $n 级标题在英文下回落了中文：$v',
        );
        expect(v, 'Heading $n');
      }
      // 反向：中文表下本来就该是中文（证明判据不是空转）
      setCurrentText(AppTextZh());
      expect(dataText('officeDocTocLevel3', '3 级标题'), '3 级标题');
    });
  });

  group('动态 key 家族：regionCountry<CC>', () {
    test('★ 53 个国家/地区名全部登记（英文下不回落中文）', () {
      setCurrentText(AppTextEn());
      final offenders = <String, String>{};
      kCountryNames.forEach((cc, zh) {
        final v = countryName(cc);
        if (_cjk.hasMatch(v)) offenders[cc] = v;
      });
      expect(
        kCountryNames.length,
        greaterThan(50),
        reason: '防呆：国家表条数太少，可能没读到（AGENTS §1.3.0.1）',
      );
      expect(
        offenders,
        isEmpty,
        reason: '这些国家码在英文下回落了中文：$offenders',
      );
      // 抽样具体读数
      expect(countryName('CN'), 'China');
      expect(countryName('US'), 'United States');
    });

    test('★ 认不出的国家码原样返回（不许编一个名字）', () {
      setCurrentText(AppTextEn());
      expect(countryName('ZZ'), 'ZZ');
      expect(countryName(''), 'Unknown');
    });
  });
}
