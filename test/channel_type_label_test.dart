// D55 守卫：频道 `type`（服务端枚举）**不许原样当用户文案**。
//
// 为什么需要它：r340 的守卫只扫 ARB；r342 的守卫只认三种接口形状；r343 的守卫④是
// `key=value` snake_case —— 而 `public · 3 人` 这种"**裸枚举值**"是第四种旁路形态
// （D47/D51/D52/D54 同族）。所以判据钉在**生产者**上（§2.0.26）：
//   ① 两个渲染点文件里**不许**再出现裸 `.type` 插值，且**必须**调用 `channelTypeLabel(`；
//   ② token 清单从 `channel_dto.dart` **现扫**（不许手抄），逐条断言标签 ≠ token；
//   ③ 兜底必须是通用名词（不能把 token 原样返回）。
//
// 反向验证（已做）：把 `channelTypeLabel` 的 `default` 改成 `return type;` ⇒ 本守卫应转红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/features/chat/channel_type_label.dart';

/// `type` 的**全部渲染点**（新增一处必须加进来，否则守卫会漏）。
const List<String> _renderFiles = <String>[
  'lib/src/features/chat/channel_row.dart',
  'lib/src/features/chat/channel_manage_sheet.dart',
  // ★★ r348 D58：详情页 AppBar 副标题 `_ChannelSubtitle` 也是**第三个**渲染点
  //   （真机逐字 `public · 3 人`）。r344 把它漏在名单外 ⇒ 守卫从来没扫过它。
  'lib/src/features/chat/chat_page.dart',
];

/// token 的权威生产者（DTO 里 `type == 'x'` 的判定就是枚举取值清单）。
const String _dtoFile = 'lib/src/data/dto/channel_dto.dart';

/// 从 DTO 里扫出 `type == '...'` / `'...'` 比较里出现过的 token。
Set<String> _tokensFromRepo() {
  final src = File(_dtoFile).readAsStringSync();
  final re = RegExp(r"type\s*==\s*'([a-z0-9_]+)'");
  return <String>{
    for (final m in re.allMatches(src)) m.group(1)!,
  };
}

/// 去掉 `//` 行注释与 `///` 文档注释 —— 注释里**会**写到旧写法
/// （本文件自己就写了 `` `'${widget.channel.type}'` ``），
/// 不剥就会把自己的注释当命中（§2.0.63⑤「静态守卫要清点它认哪些字面形状」）。
String _stripComments(String src) => src
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

void main() {
  final zh = AppTextZh();
  final en = AppTextEn();

  test('渲染点：不许裸 `.type` 插值，且必须走唯一生产者', () {
    for (final path in _renderFiles) {
      final src = _stripComments(File(path).readAsStringSync());
      // 裸插值：`${x.type}` / `${widget.channel.type}`
      final raw = RegExp(r'\$\{[^}]*\.type\}').allMatches(src).toList();
      expect(
        raw,
        isEmpty,
        reason: '$path 里仍有裸 `\${….type}` 插值：'
            '${raw.map((m) => m.group(0)).join(', ')}（应走 channelTypeLabel()）',
      );
      expect(
        src.contains('channelTypeLabel('),
        isTrue,
        reason: '$path 必须调用 channelTypeLabel()（否则副标题又会印裸枚举）',
      );
      // ★★ r348 D58 补的形状：**裸表达式当值**（不是插值）——
      //   `x ? t.chatChannel : channel.type,` / 集合里单列一行 `.type,`。
      //   旧守卫只认 `${….type}`，所以 D58 这个形状从它眼皮下走过去。
      //   允许的合法用法：比较（`==`/`!=`）、`.isEmpty/.isNotEmpty`、`?? 默认值`。
      final asValue = RegExp(r'[?:]\s*[A-Za-z_?!.\[\]]*\.type\s*,')
          .allMatches(src)
          .toList();
      final standalone =
          RegExp(r'^\s*[A-Za-z_?!.\[\]]*\.type,\s*$', multiLine: true)
              .allMatches(src)
              .toList();
      expect(
        [...asValue, ...standalone],
        isEmpty,
        reason: '$path 里把 `.type` **当值**用（裸枚举会直接印到界面上）：'
            '${[...asValue, ...standalone].map((m) => m.group(0)!.trim()).join(' | ')}',
      );
    }
  });

  test('token 清单来自真仓且非空', () {
    final found = _tokensFromRepo();
    expect(found.length, greaterThanOrEqualTo(3), reason: 'DTO 里应扫出 ≥3 个 type token');
    expect(found, containsAll(<String>['public', 'private']));
    // 生产者登记的清单必须覆盖真仓扫出来的（§2.0.29：删到 0 / 漏登记都不行）
    for (final tok in found) {
      expect(
        kChannelTypeTokens,
        contains(tok),
        reason: '$tok 出现在 $_dtoFile 但没登记进 kChannelTypeTokens',
      );
    }
  });

  test('每个 token 都有用户文案，且**永不等同于 token 本身**', () {
    for (final tok in kChannelTypeTokens) {
      final z = channelTypeLabel(tok, zh);
      final e = channelTypeLabel(tok, en);
      expect(z, isNotEmpty);
      expect(e, isNotEmpty);
      expect(z.toLowerCase(), isNot(tok), reason: 'zh 把 token 原样返回了：$tok');
      // en 按**大小写敏感**比：`Public`（人写的标签）≠ `public`（裸 token）
      expect(e, isNot(tok), reason: 'en 把 token 原样返回了：$tok');
      expect(e[0], e[0].toUpperCase(), reason: 'en 标签首字母应大写（人写的样子）：$e');
      expect(z.contains('_'), isFalse, reason: 'zh 文案里出现下划线：$z');
      // 中文文案不该是纯 ASCII（否则就是没翻）
      expect(RegExp(r'[A-Za-z]').hasMatch(z), isFalse, reason: 'zh 文案仍是英文：$z');
    }
  });

  test('大小写/空白容错与兜底：未知与空都回通用名词', () {
    expect(channelTypeLabel('  PUBLIC  ', zh), zh.chatTypePublic);
    expect(channelTypeLabel('Private', en), en.chatTypePrivate);
    // 兜底：既不是 token 原样、也不是"未知"那种宣称，而是通用名词「频道」
    expect(channelTypeLabel('', zh), zh.chatChannel);
    expect(channelTypeLabel('weird_new_type', zh), zh.chatChannel);
    expect(channelTypeLabel('weird_new_type', zh).toLowerCase(), isNot('weird_new_type'));
    // 两个机器人 token 同一句话（官方 isChatBot 只看 chatbot，synobot 是官方机器人）
    expect(channelTypeLabel('chatbot', zh), channelTypeLabel('synobot', zh));
  });
}
