// ★ 第 273 轮：**硬编码中文界面文案的全局守卫**。
//
// 用户 2026-09-26 报障：「还是有大量的中英文混杂的界面，包括各种菜单和弹层里，
// 如果选择语言为英文，还是有很多地方显示了中文，我建议你全局彻底的清理一遍」。
//
// `test/i18n_coverage_test.dart`（第 259 轮）守的是**数据层**那条链路
// （`dataText('key','中文')` 有没有登记进 `dataTextMap`）。它的盲区正是用户
// 抱怨的那一类：**widget 代码里硬写的 `Text('确定')` / `tooltip: '更多'` /
// `labelText: '名称'`** —— 这些从不经过 `dataText`，所以没有任何用例能抓到。
//
// 本用例补上这一课：静态扫描 `lib/**/*.dart`（排除生成代码）里
// **字符串字面量中的中日韩字符**，逐个判断它是不是"用户能看到的文案"。
//
// ## 扫描口径
//
// * 只扫 `lib/`（`tool/`、`test/` 不是产品代码），排除 `lib/l10n/gen/**`
//   与 ARB（生成代码 / 本身就是译文表）；
// * 用**手写词法状态机**逐字符走一遍，把 `//`、`/* */`（含嵌套）注释整体剔除，
//   `'''`/`"""`/`r'…'` 都能正确识别，`'a' 'b'`（相邻拼接）各算一条，
//   `'${…}'` 里的插值表达式会被递归扫到（里面的字符串也算）；
// * CJK 判定 = `[\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF\u3400-\u4DBF]`
//   （含全角标点 —— `。`/`（`/`「` 出现在英文界面同样是"中文串进来了"）。
//
// ## 什么**不算**违规（结构判定，不是"人工放过"）
//
// 1. `_keyFallback`：`f(<key>, '中文原文')` 这种**译文回落对**。数据层/服务层
//    文案的既定写法，key 由 `test/i18n_coverage_test.dart` 的 ② 单独守。
//    key 可以写成 `'someKey'`（字符串）或 `SomeKeys.someKey`（枚举成员）。
// 2. `_logCalls`：`print` / `debugPrint` / `log` / `writeln` / `write` 的实参。
//    **只在日志调用内部才豁免** —— 裸在别处的同一句中文照样算违规。
// 3. `_regexCalls`：`RegExp('…')` 的实参（正则里的中文是模式，不是界面文案）。
// 4. `_messageCalls`：异常/断言/诊断面板的**内部说明**。`user_facing_error.dart`
//    是全仓唯一的「异常 → 用户文案」出口（`FormatException` → "数据格式不正确"、
//    `StateError`/`Error` → 兜底话术，**原文只进日志**），所以这些消息本身
//    不会直接渲染给用户；诊断列表（degradation/messages/out）只在渲染降级
//    说明区出现。
// 5. `_charTable`：长 CJK 串且不含空白/ASCII 字母数字 —— 字符集映射表
//    （`book_charset_table.dart` 之类），不是散文文案。
// 6. `_allowedFiles` / `_allowedEntries`：**逐条写明理由**的合法例外。
//
// 失败信息给出 `文件:行 文本（调用点）` + 修法提示（`context.t.xxx` /
// `dataText('key','中文')` + `dataTextMap` 登记 / 补 ARB 双语）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 中日韩字符 + 全角标点。
final RegExp _cjk =
    RegExp(r'[\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF\u3400-\u4DBF]');

/// 合法 key 的形状：标识符 / 点分枚举成员（可带 `!`）/ 字符串字面量
/// （允许 `'officeDocTocLevel$level'` 这种**动态前缀 key**）。
final RegExp _keyShape = RegExp(
    r"^(?:[A-Za-z_][A-Za-z0-9_.]*!?|'[^']*')$");

/// named 参数 `zh:` / `zhText:` / `fallback:` 的取值：本仓"key + 中文回落"
/// 的另一种写法（如 `_degradedCard(labelKey: '…', zh: '…')`）。
final RegExp _namedZhArg = RegExp(r'\b(?:zh|zhText|fallback)\s*:\s*$');

/// 日志调用：只有**在这些调用内部**才豁免。
const _logCalls = <String>{
  'print',
  'debugPrint',
  'debugPrintSynchronously',
  'log',
  'writeln',
  'write',
};

/// 正则构造：实参是模式，不是界面文案。
const _regexCalls = <String>{'RegExp'};

/// 内部消息：异常/断言/诊断面板说明。见文件头第 4 条。
const _messageCalls = <String>{
  'assert',
  'assertAll',
  'ArgumentError',
  'StateError',
  'UnsupportedError',
  'RangeError',
  'FormatException',
  // 第 328 轮 D30：本仓自己的内部异常类型（`core/platform/app_secure_storage.dart`）——
  // 只被各家 store 的 `catch (_)` 吞掉/进日志，**不进界面**（界面文案是各家自己的 key）。
  'SecureStorageUnavailable',
  'report.note',
  '_report.note',
};

/// 诊断列表的接收者：`.add(...)` 收集的是渲染降级/词表缺口说明。
const _diagnosticReceivers = <String>{
  'degradations',
  'messages',
  'out',
  'report',
  'notes',
  'warnings',
  'unsupported',
};

/// 合法例外（文件级）：**每一条都要写清为什么**。
///
/// 判据：该文件里的中文**整体不是英文界面会渲染的文案**。
/// 一旦要往这些文件里加真正的 UI 文案，必须走 `context.t` / `dataText`。
const _allowedFiles = <String, String>{
  // —— 纯数据表（不是散文文案）——
  'lib/src/features/files/book_charset_table.dart':
      'CJK 编码映射表：连续汉字字符集，用于把字节按 GBK/Big5 等码表解码；'
          '不是界面文案，绝不翻译。',
  'lib/src/data/emoji_table.dart': 'emoji / 符号名表，含少量 CJK 符号，属数据。',
  'lib/src/data/holidays/holiday_service.dart':
      '节假日分类/名称数据（服务端与本地表），按数据展示，不翻译。',
  'lib/src/data/region/region_context.dart':
      '地区/度量衡分类数据表（公制/英制/跟随地区…），随地区而非语言变化。',
  'lib/src/data/weather/weather_client.dart':
      '天气供应商信息（含官方中文名与说明），属服务/数据层元信息。',
  'lib/src/features/office/office_template_titles.dart':
      'Office 模板标题双语文表：源数据是官方 chs/enu strings，中文列是数据本身。',
  'lib/src/data/office_collab/schema/doc_schema_generated.dart':
      '官方 schema 生成物，CJK 是官方文档字符串/示例值。',
  'lib/src/features/media/media_tracks.dart': '音轨/字幕的语言名表（含"中文"条目），属数据。',
  'lib/src/features/files/book_dictionary.dart':
      '词典词性/释义分类数据（名词/动词…），来自词典文件本身。',
  // —— LLM 提示词（发给模型的，不是界面）——
  'lib/src/features/ai/text_ai.dart': '端侧/云端 LLM 提示词与解析规则，不进界面。',
  'lib/src/features/ai/ai_prompts.dart': 'LLM 提示词模板，不进界面。',
  'lib/src/data/ai/image_edit_prompts.dart': '图生图提示词模板，不进界面。',
  'lib/src/data/ai/cloud_provider.dart': '云端服务商元信息与协议说明，配置用数据。',
  'lib/src/data/ai/cloud_llm_client.dart': 'LLM 客户端内置探活提示词，不进界面。',
  'lib/src/data/ai/image_edit_client.dart': '图生图客户端内部错误分类说明，走 dataText 出口。',
  // —— 分析埋点（事件名 / 内部标签）——
  'lib/src/features/analytics/usage_event.dart': '埋点事件名/维度键，不是界面文案。',
  'lib/src/features/analytics/usage_log.dart': '埋点日志说明，不进界面。',
  'lib/src/features/analytics/usage_analysis.dart': '分析维度的内部名，渲染前经 labels 表本地化。',
  'lib/src/features/analytics/analytics_labels.dart': '分析维度展示标签（深夜/早晨…），待随模块批次迁移。',
  'lib/src/features/analytics/analytics_registry.dart':
      '埋点覆盖注册表：surface 说明与"不埋点理由"，只被守卫用例消费，不进界面。',
  // —— 证据 / 差距表 / 未实现说明（开发者台账）——
  'lib/src/data/auth_extra_api.dart': '未实现能力的原因台账（开发者注释性质）。',
  'lib/src/data/media/media_format_support.dart': '媒体格式差距证据表（含抽取器取证说明）。',
  'lib/src/features/office/office_doc_view.dart': 'Office 节点覆盖证据表（golden 夹具来源说明）。',
  'lib/src/data/office_native/osheet_formula.dart': '公式解析器内部不支持项说明。',
  'lib/src/data/office_native/ofile.dart': 'OFile 原生格式内部说明/降级登记。',
  // —— WebAPI 错误码的中文回落表（有成对本地化访问器）——
  'lib/src/dsm/webapi.dart':
      'DsmErrorCode.messages 是**纯 Dart const 中文回落表**（文件头写明），'
          '本地化版本由 messagesText() 逐条 dataText("err*") 提供；表本身不直接渲染。',
  // —— 应用名（按语言二选一，属设计）——
  'lib/src/core/i18n/l10n.dart':
      'appNameIn() 只有 "星枢"：中文名 vs "SynHub" 是**按语言二选一**的产品决策。',
  // —— 深链路解析器的内部诊断（不直接渲染；见文件头第 4 条）——
  'lib/src/features/files/book_mobi.dart': 'MOBI/AZW3 解析器内部不支持项与损坏说明，属异常/诊断。',
  'lib/src/features/files/book_lit.dart': 'LIT DRM 解析器内部说明，属诊断/未实现台账。',
  // 第 281 轮：`lib/src/core/user_facing_error.dart` 的整文件豁免**已撤掉**。
  // 原来的理由（"字面量会被 userFacingError 处理"）站不住：它返回的就是**用户可见文案**，
  // 硬编码中文一旦被英文模板拼进去就中英混排（第 280 轮 macOS 像素实证）。
  // 现在该文件全部走 dataText('key','中文回落')，守卫必须能咬到它。
  // CacheUsage.toString() 调试统计，不进界面。
  'lib/src/core/media/cache_service.dart':
      'CacheUsage.toString() 调试统计，不进界面。',
  // ThumbStats.toString() 调试统计，不进界面。
  'lib/src/core/media/thumb_cache.dart':
      'ThumbStats.toString() 调试统计，不进界面。',
  // kHasLabels/kPostTypeLabels 是数据层中文回落表；界面走 hasLabelText()/postTypeLabelText()（dataText）。
  'lib/src/data/chat_api.dart':
      'kHasLabels/kPostTypeLabels 是数据层中文回落表；界面走 hasLabelText()/postTypeLabelText()（dataText）。',
  // _log() 日志文案，只进 logcat。
  'lib/src/data/e2ee/e2ee_service.dart':
      '_log() 日志文案，只进 logcat。',
  // FotoSpace 中文回落表；界面走 labelText()（dataText）。
  'lib/src/data/foto_api.dart':
      'FotoSpace 中文回落表；界面走 labelText()（dataText）。',
  // msg.contains("超时") 是网络报文匹配，不是界面文案。
  'lib/src/data/office_api.dart':
      'msg.contains("超时") 是网络报文匹配，不是界面文案。',
  // LLM 提示词的语言指示（"中文"），发给模型、不进界面。
  'lib/src/features/ai/ai_service.dart':
      'LLM 提示词的语言指示（"中文"），发给模型、不进界面。',
  // kOnDeviceModels 的 note/rationale 与 AiReadiness.label 中文回落表；界面走 noteIn()/labelIn()，rationale 仅测试断言。
  'lib/src/features/ai/on_device_ai.dart':
      'kOnDeviceModels 的 note/rationale 与 AiReadiness.label 中文回落表；界面走 noteIn()/labelIn()，rationale 仅测试断言。',
  // 只作为 Fb3FormatException 的 $what 片段，不进界面。
  'lib/src/features/files/book_fb3.dart':
      '只作为 Fb3FormatException 的 \$what 片段，不进界面。',
  // ODF style-name 判别值（"标题"），翻译会破坏解析。
  'lib/src/features/files/book_office.dart':
      'ODF style-name 判别值（"标题"），翻译会破坏解析。',
  // ChmUnsupportedException.toString() 异常诊断串，经 user_facing_error 收口。
  'lib/src/features/files/chm_archive.dart':
      'ChmUnsupportedException.toString() 异常诊断串，经 user_facing_error 收口。',
  // DjvuFormatException.toString() 异常诊断串，经 user_facing_error 收口。
  'lib/src/features/files/djvu_errors.dart':
      'DjvuFormatException.toString() 异常诊断串，经 user_facing_error 收口。',
  // PDF 解析器内部语法错误诊断串，经 user_facing_error 收口。
  'lib/src/features/files/pdf_doc.dart':
      'PDF 解析器内部语法错误诊断串，经 user_facing_error 收口。',
  // RarUnsupportedException.toString() 异常诊断串，经 user_facing_error 收口。
  'lib/src/features/files/rar_archive.dart':
      'RarUnsupportedException.toString() 异常诊断串，经 user_facing_error 收口。',
  // VideoFrameThumbStats.toString() 调试统计，不进界面。
  'lib/src/features/media/video_frame_thumb.dart':
      'VideoFrameThumbStats.toString() 调试统计，不进界面。',
  // NAS 端相册名（服务端数据，用于匹配/创建目录）+ 异常 toString。
  'lib/src/features/photos/photo_backup_target.dart':
      'NAS 端相册名（服务端数据，用于匹配/创建目录）+ 异常 toString。',
  // SnoozeOption/免打扰 中文回落表；界面走 labelIn()/subtitleIn()。
  'lib/src/features/settings/snooze_controller.dart':
      'SnoozeOption/免打扰 中文回落表；界面走 labelIn()/subtitleIn()。',
  // ServApiException 的消息累加，异常诊断不进界面。
  'lib/src/quickconnect/serv_api.dart':
      'ServApiException 的消息累加，异常诊断不进界面。',
};

/// 合法例外（单条）：`文件\u0000规范化文本` → 理由。
///
/// 只有当某一句确实合法、又不属于任何结构性类别时才放这里；能进
/// `_allowedFiles` 的不要拆散成一条条。
const _allowedEntries = <String, String>{
  // lib/src/features/files/office_viewer_page.dart：OFile 字节诊断串（异常路径），不进界面。
  'lib/src/features/files/office_viewer_page.dart\u0000字节不是 Synology Office 原生 OFile，而是转换后的包':
      'OFile 字节诊断串（异常路径），不进界面。',
  // lib/src/features/office/office_doc_ooxml_view.dart：kOfficeDocTocTitles：判断文档是否真有目录的内容匹配集，不是界面文案。
  'lib/src/features/office/office_doc_ooxml_view.dart\u0000目录':
      'kOfficeDocTocTitles：判断文档是否真有目录的内容匹配集，不是界面文案。',
  'lib/src/features/office/office_doc_ooxml_view.dart\u0000目錄':
      'kOfficeDocTocTitles：判断文档是否真有目录的内容匹配集，不是界面文案。',
  'lib/src/features/office/office_doc_ooxml_view.dart\u0000目录页':
      'kOfficeDocTocTitles：判断文档是否真有目录的内容匹配集，不是界面文案。',
  'lib/src/features/office/office_doc_ooxml_view.dart\u0000目次':
      'kOfficeDocTocTitles：判断文档是否真有目录的内容匹配集，不是界面文案。',
  // lib/src/features/office/office_doc_table.dart：渲染降级诊断登记（notes/"如实登记"），只进诊断区不进本地化界面。
  'lib/src/features/office/office_doc_table.dart\u0000边框样式非 solid（虚线/点线）无逐像素画笔 → 按 solid 渲染（如实登记）':
      '渲染降级诊断登记（notes/"如实登记"），只进诊断区不进本地化界面。',
  // lib/src/features/office/office_sheet_edit.dart：待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。
  'lib/src/features/office/office_sheet_edit.dart\u0000status 2 重放 {x} 次仍过期':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_sheet_edit.dart\u0000{x} 被服务端拒绝（{x}）':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_sheet_edit.dart\u0000{x} 版本一直过期，改动仍保留在待确认队列':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_sheet_edit.dart\u0000（{x}，重放 {x} 次）':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_sheet_edit.dart\u0000{x} 发送失败：{x}（改动仍在待确认队列）':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_sheet_edit.dart\u0000{x} 的服务端结果无法确认：{x}':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_sheet_edit.dart\u0000（改动仍在待确认队列）':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  // lib/src/features/office/office_sheet_page.dart：OOXML→OFile 回落通道诊断串，不进界面。
  'lib/src/features/office/office_sheet_page.dart\u0000OOXML 字节获取失败 → 回落 OFile 兼容通道：{x}':
      'OOXML→OFile 回落通道诊断串，不进界面。',
  'lib/src/features/office/office_sheet_page.dart\u0000未取到 OOXML(XLSX) 字节 → 回落 OFile 兼容通道':
      'OOXML→OFile 回落通道诊断串，不进界面。',
  // lib/src/features/office/office_slides_canvas.dart：渲染降级诊断登记（unsupportedReason/notes），只作诊断与 semantics 说明。
  'lib/src/features/office/office_slides_canvas.dart\u0000shape_box 没有 shape 子节点':
      '渲染降级诊断登记（unsupportedReason/notes），只作诊断与 semantics 说明。',
  'lib/src/features/office/office_slides_canvas.dart\u0000(空)':
      '渲染降级诊断登记（unsupportedReason/notes），只作诊断与 semantics 说明。',
  'lib/src/features/office/office_slides_canvas.dart\u0000cust_points 非空':
      '渲染降级诊断登记（unsupportedReason/notes），只作诊断与 semantics 说明。',
  // lib/src/features/office/office_slides_edit.dart：待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。
  'lib/src/features/office/office_slides_edit.dart\u0000：{x}':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_slides_edit.dart\u0000status {x}：历史不可用':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_slides_edit.dart\u0000服务端错误 {x}':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_slides_edit.dart\u0000poll 失败：{x}':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_slides_edit.dart\u0000version 重放 {x} 次仍过期':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_slides_edit.dart\u0000{x} 被服务端拒绝（{x}）':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_slides_edit.dart\u0000{x} version 一直过期，改动仍保留在待确认队列':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_slides_edit.dart\u0000（{x}，重放 {x} 次）':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_slides_edit.dart\u0000{x} 拉取远端增量失败（{x}，改动仍在待确认队列）':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_slides_edit.dart\u0000{x} 发送失败：{x}（改动仍在待确认队列）':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_slides_edit.dart\u0000{x} 的服务端结果无法确认：{x}':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  'lib/src/features/office/office_slides_edit.dart\u0000（改动仍在待确认队列）':
      '待确认队列/重放/服务端结果诊断串，描述服务端交互，不进界面。',
  // lib/src/features/photos/photo_c2_sections.dart：已经是 photoC2(key, 中文) 回落对（key 由三元表达式给出），已本地化。
  'lib/src/features/photos/photo_c2_sections.dart\u0000你还没有共享过相册':
      '已经是 photoC2(key, 中文) 回落对（key 由三元表达式给出），已本地化。',
  'lib/src/features/photos/photo_c2_sections.dart\u0000还没有人共享相册给你':
      '已经是 photoC2(key, 中文) 回落对（key 由三元表达式给出），已本地化。',
  // lib/src/features/photos/photo_widgets.dart：@Deprecated 注解的开发者说明，不进界面。
  'lib/src/features/photos/photo_widgets.dart\u0000用 coverRequest（走鉴权字节链路）':
      '@Deprecated 注解的开发者说明，不进界面。',
};

/// 扫描结果。
class CjkHit {
  CjkHit(this.file, this.line, this.text, this.call);
  final String file;
  final int line;

  /// 整条字面量；字符串插值渲染成 `{x}`（便于比对与 allowlist）。
  final String text;
  final String? call;

  String get where => '$file:$line';

  @override
  String toString() => '$where  $text${call == null ? '' : '  [$call]'}';
}

/// 扫描一段 Dart 源码，返回**未豁免**的 CJK 字面量。
List<CjkHit> scanCjkLiterals(String src, String file) {
  final tokens = _scanStrings(src);
  final masked = _maskComments(src, tokens);
  final calls = _findCalls(masked);
  final out = <CjkHit>[];
  for (final t in tokens) {
    final lit = t.segs.map((s) => src.substring(s.$1, s.$2)).join();
    if (!_cjk.hasMatch(lit)) continue;
    final call = _innermostCall(calls, t.start);
    final exempt = _exempt(src, file, masked, t, call);
    if (exempt != null) continue;
    out.add(CjkHit(file, '\n'.allMatches(src.substring(0, t.start)).length + 1,
        _wholeText(src, t), call?.name));
  }
  return out;
}

String? _exempt(
    String src, String file, String masked, _StrTok t, _Call? call) {
  if (call != null) {
    final name = call.name;
    if (_logCalls.contains(name)) return 'log';
    if (_regexCalls.contains(name)) return 'regex';
    if (_messageCalls.contains(name)) return 'message';
    if (name.endsWith('Exception') || name.endsWith('Error')) return 'message';
    if (name.contains('.')) {
      final recv = name.split('.').first;
      if (name.endsWith('.add') && _diagnosticReceivers.contains(recv)) {
        return 'diagnostic';
      }
    }
    // `f(<key>, '中文原文')`：key 形参 + 第二个及以后的实参
    final args = _argRanges(masked, call.open, call.close);
    final idx =
        args.indexWhere((r) => r.$1 <= t.start && t.start < r.$2);
    if (idx >= 1) {
      final a0 = src.substring(args[0].$1, args[0].$2).trim();
      if (_keyShape.hasMatch(a0)) return 'keyFallback';
    }
    // `f(labelKey: '…', zh: '中文')` 这种 named 参数写法
    final head = src.substring(t.start > 40 ? t.start - 40 : 0, t.start);
    if (_namedZhArg.hasMatch(head.replaceAll(RegExp(r'\s+'), ' '))) {
      return 'keyFallbackNamed';
    }
  }
  if (_allowedFiles.containsKey(file)) return 'allowedFile';
  // 字符集表：长 CJK 串，且不含空白 / ASCII 字母数字
  final lit = t.segs.map((s) => src.substring(s.$1, s.$2)).join();
  if (!lit.contains(RegExp(r'[\sA-Za-z0-9]')) && lit.length >= 12) {
    return 'charTable';
  }
  return null;
}

String _wholeText(String src, _StrTok t) {
  final buf = StringBuffer();
  var cur = t.start + (t.triple ? 3 : 1);
  for (final s in t.segs) {
    if (s.$1 > cur) buf.write('{x}');
    buf.write(src.substring(s.$1, s.$2));
    cur = s.$2;
  }
  final end = t.end - (t.triple ? 3 : 1);
  if (cur < end) buf.write('{x}');
  return buf.toString();
}

class _StrTok {
  _StrTok(this.start, this.end, this.segs, this.triple);
  final int start;
  final int end;
  final List<(int, int)> segs;
  final bool triple;
}

class _Call {
  _Call(this.name, this.open, this.close);
  final String name;
  final int open;
  final int close;
}

/// 手写词法：抽出所有字符串字面量（不含注释里的）。
List<_StrTok> _scanStrings(String src) => _Lexer(src).scan();

class _Lexer {
  _Lexer(this.src);
  final String src;
  late final int n = src.length;
  final out = <_StrTok>[];

  List<_StrTok> scan() {
    _skipCode(0);
    return out;
  }

  int _skipCode(int i, {bool stopAtBrace = false}) {
    var brace = 0;
    while (i < n) {
      final c = src[i];
      if (c == '/' && i + 1 < n && src[i + 1] == '/') {
        final j = src.indexOf('\n', i);
        i = j < 0 ? n : j;
        continue;
      }
      if (c == '/' && i + 1 < n && src[i + 1] == '*') {
        var depth = 1;
        i += 2;
        while (i < n && depth > 0) {
          if (src[i] == '/' && i + 1 < n && src[i + 1] == '*') {
            depth++;
            i += 2;
          } else if (src[i] == '*' && i + 1 < n && src[i + 1] == '/') {
            depth--;
            i += 2;
          } else {
            i++;
          }
        }
        continue;
      }
      if (c == '}' && stopAtBrace && brace == 0) return i;
      if (c == '{') {
        brace++;
      } else if (c == '}') {
        brace--;
      }
      if (c == "'" || c == '"') {
        i = _scanString(i);
        continue;
      }
      i++;
    }
    return i;
  }

  int _scanString(int i) {
    final raw = i > 0 &&
        src[i - 1] == 'r' &&
        (i - 2 < 0 || !_isIdent(src[i - 2]));
    final q = src[i];
    final triple = src.startsWith(q * 3, i);
    final delim = triple ? 3 : 1;
    var j = i + delim;
    final segs = <(int, int)>[];
    var segStart = j;
    int? contentEnd;
    while (j < n) {
      final c = src[j];
      if (!raw) {
        if (c == r'\') {
          j += 2;
          continue;
        }
        if (c == r'$') {
          if (j > segStart) segs.add((segStart, j));
          if (j + 1 < n && src[j + 1] == '{') {
            final k = _skipCode(j + 2, stopAtBrace: true);
            j = k + 1;
          } else {
            var k = j + 1;
            while (k < n && _isIdent(src[k])) {
              k++;
            }
            j = k;
          }
          segStart = j;
          continue;
        }
      }
      if (triple) {
        if (src.startsWith(q * 3, j)) {
          contentEnd = j;
          j += 3;
          break;
        }
      } else {
        if (c == q) {
          contentEnd = j;
          j++;
          break;
        }
        if (c == '\n') {
          contentEnd = j;
          break;
        }
      }
      j++;
    }
    contentEnd ??= j;
    if (contentEnd > segStart) segs.add((segStart, contentEnd));
    out.add(_StrTok(i, j, segs, triple));
    return j;
  }
}

bool _isIdent(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x30 && u <= 0x39) ||
      (u >= 0x41 && u <= 0x5A) ||
      (u >= 0x61 && u <= 0x7A) ||
      c == '_';
}

/// 把注释整体替换成空格（保留长度与换行），便于按位置找"外层调用"。
String _maskComments(String src, List<_StrTok> tokens) {
  final buf = src.split('');
  // 只把**字面量内容与引号**抹掉；`${…}` 插值里的代码必须保留，
  // 否则 `'${dataText('k','中文')}'` 这种"文案外层又被插值包一层"的
  // 结构性豁免会失效（插值内层调用看不见 ⇒ 误报）。
  void blank(int from, int to) {
    for (var k = from; k < to && k < buf.length; k++) {
      if (buf[k] != '\n') buf[k] = ' ';
    }
  }

  for (final t in tokens) {
    final delim = t.triple ? 3 : 1;
    blank(t.start, t.start + delim);
    blank(t.end - delim, t.end);
    for (final s in t.segs) {
      blank(s.$1, s.$2);
    }
  }
  final n = src.length;
  final tokAt = <int, int>{for (final t in tokens) t.start: t.end};
  var i = 0;
  while (i < n) {
    final skip = tokAt[i];
    if (skip != null) {
      i = skip;
      continue;
    }
    final c = src[i];
    if (c == '/' && i + 1 < n && src[i + 1] == '/') {
      final j0 = src.indexOf('\n', i);
      final j = j0 < 0 ? n : j0;
      for (var k = i; k < j; k++) {
        if (buf[k] != '\n') buf[k] = ' ';
      }
      i = j;
      continue;
    }
    if (c == '/' && i + 1 < n && src[i + 1] == '*') {
      var depth = 1;
      i += 2;
      final k0 = i - 2;
      while (i < n && depth > 0) {
        if (src[i] == '/' && i + 1 < n && src[i + 1] == '*') {
          depth++;
          i += 2;
        } else if (src[i] == '*' && i + 1 < n && src[i + 1] == '/') {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
      for (var k = k0; k < (i < n ? i : n); k++) {
        if (buf[k] != '\n') buf[k] = ' ';
      }
      continue;
    }
    i++;
  }
  return buf.join();
}

List<_Call> _findCalls(String masked) {
  final out = <_Call>[];
  final re = RegExp(r'([A-Za-z_][A-Za-z0-9_.]*)\s*\(');
  for (final m in re.allMatches(masked)) {
    final start = m.end - 1;
    var depth = 1;
    var j = start + 1;
    final n = masked.length;
    while (j < n && depth > 0) {
      final c = masked[j];
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
      }
      j++;
    }
    out.add(_Call(m.group(1)!, start, j));
  }
  return out;
}

_Call? _innermostCall(List<_Call> calls, int pos) {
  _Call? best;
  for (final c in calls) {
    if (c.open <= pos && pos < c.close) {
      if (best == null || (c.close - c.open) < (best.close - best.open)) {
        best = c;
      }
    }
  }
  return best;
}

List<(int, int)> _argRanges(String masked, int a, int b) {
  final rs = <(int, int)>[];
  var depth = 0;
  var start = a + 1;
  for (var i = a + 1; i < b - 1; i++) {
    final c = masked[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
    } else if (c == ',' && depth == 0) {
      rs.add((start, i));
      start = i + 1;
    }
  }
  rs.add((start, b - 1));
  return rs;
}

void main() {
  test('⑥ lib/ 里没有硬编码的中文界面文案（含菜单/弹层/tooltip/Semantics）', () {
    final hits = <CjkHit>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      // 设计稿原型（lib/src/design/）是 `design/emit_gallery.py` 的产物：
      // 中文/英文成对写在 `_zh ? … : …` 里（文案即设计源），不是漏翻；
      // 这些页面只经 dev 档画廊可达，release 里不被引用、AOT 会摇掉。
      if (f.path.startsWith('lib/src/design/')) continue;

      if (f.path.contains('l10n/gen/')) continue;
      final src = f.readAsStringSync();
      for (final h in scanCjkLiterals(src, _norm(f.path))) {
        final allowKey = '${h.file}\u0000${h.text}';
        if (_allowedEntries.containsKey(allowKey)) continue;
        hits.add(h);
      }
    }
    hits.sort((a, b) => a.where.compareTo(b.where));
    final byFile = <String, int>{};
    for (final h in hits) {
      byFile[h.file] = (byFile[h.file] ?? 0) + 1;
    }
    expect(
      hits,
      isEmpty,
      reason: '发现 ${hits.length} 处硬编码中文界面文案（${byFile.length} 个文件）：\n'
          '${hits.map((h) => '  ${h.where}  ${h.text}').join('\n')}\n'
          '\n修法：\n'
          '  * widget 里有 context → 用 `context.t.<key>`（先补 app_zh.arb + '
          'app_en.arb，再 `flutter gen-l10n`）；\n'
          '  * 非 Flutter 层（data/service/model）→ `dataText(\'<key>\', \'中文原文\')` '
          '并在 `lib/src/core/i18n/l10n.dart` 的 dataTextMap 里登记；\n'
          '  * 确实是数据/正则/日志/内部诊断且不该翻译的 → 加进 '
          '`_allowedFiles` / `_allowedEntries` 并**写清理由**。',
    );
  });

  test('⑦ 反向验证：这条守卫真的能抓到新写进去的中文界面文案', () {
    const planted = '''
      class X {
        Widget build(BuildContext context) {
          return Text('确定');
        }
      }
    ''';
    final hits = scanCjkLiterals(planted, 'planted.dart');
    expect(hits, isNotEmpty, reason: '故意植入的 Text(\'确定\') 必须被扫出来');
    expect(hits.first.text, '确定');

    // 注释里的中文不算（否则误报率爆掉）。
    const commented = '''
      // 这是注释：确定
      /* 块注释：取消 */
      /// 文档注释：保存
      class X {}
    ''';
    expect(scanCjkLiterals(commented, 'c.dart'), isEmpty);

    // 日志调用内部不算；裸在别处照样算。
    const logged = "void f(){ print('保存失败'); }";
    expect(scanCjkLiterals(logged, 'l.dart'), isEmpty);
    const bare = "final s = '保存失败';";
    expect(scanCjkLiterals(bare, 'b.dart'), isNotEmpty);

    // `f(key, '中文')` 译文回落对不算。
    const fallback = "void f(){ dataText('k', '保存失败'); }";
    expect(scanCjkLiterals(fallback, 'k.dart'), isEmpty);
  });
}

String _norm(String p) => p.replaceAll(r'\', '/');
