// Office 模板的**显示层派生**：官方双语标题 / 类型顺序 / 分组 / 宽高比。
//
// 为什么单独一个文件（不塞进 `office_library.dart`）：
//   网格（`office_library.dart`）与全屏预览（`office_template_preview.dart`）
//   都要用同一套"标题本地化 + 类型顺序 + 比例"，放在中间层就不会互相 import
//   形成回环。
//
// ★ 标题为什么必须查表（`docs/office-template-gallery.md` §3）：
//   服务端对**系统模板**回的 `title` 是 `<section>:<key>`
//   （如 `theme_presentation:country_road`），**不是给人看的**；
//   官方前端 `parseTemplateTitle` 拆开后查的正是官方本地化表。
//   这张表由 `office_template_titles.dart`（生成物）提供，中英各 67 条。
//
// ★ 语言判定沿用仓库既有套路（`surv_text.dart` / `mail_text.dart`）：
//   `AppTextEn` → 英文，其余（含无 delegate 时的 `AppTextZh`）→ 中文。
import '../../../l10n/gen/app_localizations_en.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../data/office_api.dart' show officeLibraryTitleFromKey;
import 'office_template_titles.dart';

/// 官方模板 section（出现在 `title` 的 `:` 前）。
const Set<String> kOfficeTemplateSections = <String>{
  'theme_presentation',
  'template_doc',
  'template_sheet',
};

/// `title` 是否形如**系统模板的** `<section>:<key>`（三个官方 section 之一）。
bool isOfficeSystemTemplateKey(String titleKey) {
  final i = titleKey.indexOf(':');
  if (i <= 0) return false;
  return kOfficeTemplateSections.contains(titleKey.substring(0, i));
}

/// `title` 的叶子 key（去掉 section 前缀）；没有 `:` → 原样。
String officeTemplateLeafKey(String titleKey) {
  final i = titleKey.indexOf(':');
  return i > 0 ? titleKey.substring(i + 1) : titleKey;
}

/// 官方 `SYNO.SDS.Office.Template.Utils.isDeprecatedTemplate` 的等价物：
/// 这 7 个系统演示文稿主题在官方界面里**沉底**（`kOfficeDeprecatedTemplateKeys`）。
bool isDeprecatedOfficeTemplateKey(String titleKey) =>
    kOfficeDeprecatedTemplateKeys.contains(officeTemplateLeafKey(titleKey));

/// 官方 `TYPE_ORDER = {doc:1, sheet:2, presentation:3}`；未知类型排最后。
int officeTemplateTypeOrder(String ntype) =>
    kOfficeTemplateTypeOrder[ntype] ?? 100;

/// 按官方顺序排序的**已知类型**（页签与分组标题用）。
const List<String> kOfficeTemplateKnownTypes = <String>[
  'doc',
  'sheet',
  'presentation',
];

/// 类型 → 本地化标签（`数据层 key + 中文回落`，见 AGENTS §2.0.13）。
String officeTemplateTypeLabel(String ntype) => switch (ntype) {
  'doc' => dataText('officeLibraryNtypeDoc', '文档'),
  'sheet' => dataText('officeLibraryNtypeSheet', '表格'),
  'presentation' => dataText('officeLibraryNtypePresentation', '演示文稿'),
  _ => ntype,
};

/// 缩略图宽高比（官方几何的等价物，见 `docs/office-template-gallery.md` §5）：
/// presentation **16:9**（真机 2x 384×216 就是 16:9）；doc/sheet **3:4**（竖版）。
double officeTemplateThumbAspect(String ntype) =>
    ntype == 'presentation' ? 16 / 9 : 3 / 4;

/// 服务端 `section:key` → 当前语言标题。
///
/// * 系统模板且表里有译文 → 官方译文（`template_sheet:calendar` 的 `{0}`
///   换成 [year]，默认当前年）；
/// * 系统模板但表里没有该 key → 用 [officeLibraryTitleFromKey] 的可读回落
///   （**绝不把 `theme_presentation:xxx` 原样上屏**）；
/// * 非系统模板（用户自己的模板，名字就是人看的字符串）→ 原样返回。
String officeTemplateTitleFromKey(
  String titleKey, {
  int? year,
  AppText? text,
}) {
  final key = titleKey.trim();
  if (key.isEmpty) return '';
  final t = text ?? currentText();
  if (!isOfficeSystemTemplateKey(key)) return key;
  final section = key.substring(0, key.indexOf(':'));
  final leaf = officeTemplateLeafKey(key);
  final table = t is AppTextEn ? kOfficeTemplateTitlesEn : kOfficeTemplateTitlesZh;
  final translated = table[section]?[leaf];
  if (translated == null || translated.isEmpty) {
    // 表里没有 → 可读回落（去前缀 + 拆词），保证不显示原始 key。
    return officeLibraryTitleFromKey(key);
  }
  return translated.replaceAll('{0}', '${year ?? DateTime.now().year}');
}

/// 只有英文表用的判定（给测试/调用方一个明确的入口）。
bool officeTemplateTitleIsEnglish([AppText? text]) =>
    (text ?? currentText()) is AppTextEn;
