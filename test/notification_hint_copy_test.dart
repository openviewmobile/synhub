// ★★★ 第 349 轮（D77）：**「通知与免打扰」入口的副标题承诺了一个不存在的功能**。
//
// 事实（真机 + 源码双证）：
//   * `我的` 页那一行是 `app_shell_page.dart:1361` 的
//     `subtitle: context.t.meNotificationsHint`；
//   * 点进去是 `snooze_settings_page.dart`，**只有三行**：
//     `notifSnooze`（免打扰）/ `snoozeScheduleTitle`（定时免打扰）/ `snoozeTimezone`（时区）；
//   * 而旧文案是 zh `免打扰时段、提示音` / en `Quiet hours, notification sounds` ——
//     **全仓 Dart 侧没有任何"提示音/铃声/声音"设置**
//     （`grep -rniE "sound|ringtone|铃声|声音|提示音" lib/src/` 的命中全在
//      EPUB 词典/TTS、音频播放器音量、emoji 表，与本页无关）。
//   ⇒ 属于 §2.0.42「**登记了却不产生机制量**」的文案形态：**界面上承诺了没有的东西**。
//   ★ 通知声音的**真正**去处是 Android **系统通知渠道**（`NoteReminderPlugin.kt` +
//     `res/values*/strings.xml` 的 `待办提醒`/`备份进程`/`新消息`…），**不在 App 内**。
//
// 修法（§2.0.18 的口径：**改文案**而不是改字号/塞进去）：让承诺与实现一致。
//
// 本守卫把**承诺**与**实现**钉在一起 —— 只改文案不改页面（或反过来）都会红。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _zhArbPath = 'lib/l10n/app_zh.arb';
const _enArbPath = 'lib/l10n/app_en.arb';
const _zhGenPath = 'lib/l10n/gen/app_localizations_zh.dart';
const _enGenPath = 'lib/l10n/gen/app_localizations_en.dart';
const _pageSrcReadOnly = 'lib/src/features/settings/snooze_settings_page.dart';

/// 副标题**不许**出现的"声音"类词（两种语言各一组）。
const _soundWordsZh = ['提示音', '铃声', '声音'];
const _soundWordsEn = ['sound', 'ringtone', 'tone'];

Map<String, dynamic> _arb(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  group('D77 「通知与免打扰」副标题不许承诺提示音', () {
    test('①装置自证：两份 ARB 都真能解析、条目数合理、该 key 在', () {
      final zh = _arb(_zhArbPath);
      final en = _arb(_enArbPath);
      // 条目数下限：防"文件被清空/解析成空 map"这种假绿
      expect(zh.length, greaterThan(1000), reason: 'zh ARB 只有 ${zh.length} 条，可疑');
      expect(en.length, greaterThan(1000), reason: 'en ARB 只有 ${en.length} 条，可疑');
      expect(zh.containsKey('meNotificationsHint'), isTrue);
      expect(en.containsKey('meNotificationsHint'), isTrue);
    });

    test('★ DA6：②zh 副标题里不许出现任何"声音"类词', () {
      final hint = _arb(_zhArbPath)['meNotificationsHint'] as String;
      for (final w in _soundWordsZh) {
        expect(hint.contains(w), isFalse,
            reason: '副标题 `$hint` 承诺了 `$w`，但 App 内**没有**这个设置；'
                '声音在 Android **系统通知渠道**里，不在本页。'
                'D77 修法 = 改文案（`meNotificationsHint`）让它与 '
                '`snooze_settings_page.dart` 的三行一致。');
      }
    });

    test('③en 副标题里不许出现任何"声音"类词', () {
      final hint = _arb(_enArbPath)['meNotificationsHint'] as String;
      final low = hint.toLowerCase();
      for (final w in _soundWordsEn) {
        expect(low.contains(w), isFalse,
            reason: 'en 副标题 `$hint` 承诺了 `$w`，App 内没有这个设置（D77）');
      }
    });

    test('④改后的文案必须真的描述本页有的东西（时区）', () {
      final zhHint = _arb(_zhArbPath)['meNotificationsHint'] as String;
      final enHint = _arb(_enArbPath)['meNotificationsHint'] as String;
      expect(zhHint.contains('时区'), isTrue, reason: 'zh 应改成「免打扰时段、时区」');
      expect(enHint.toLowerCase().contains('timezone'), isTrue,
          reason: 'en 应改成 "Quiet hours, timezone"');
    });

    test('⑤gen-l10n 两处产物与 ARB 一致（§2.0.67 的四处齐全，UI key 查三处）', () {
      final zhGen = File(_zhGenPath).readAsStringSync();
      final enGen = File(_enGenPath).readAsStringSync();
      final zhHint = _arb(_zhArbPath)['meNotificationsHint'] as String;
      final enHint = _arb(_enArbPath)['meNotificationsHint'] as String;
      expect(zhGen.contains("get meNotificationsHint => '$zhHint';"), isTrue,
          reason: '生成物没跟着 ARB 更新 ⇒ 运行时读的是**生成物**，不是 ARB');
      expect(enGen.contains("get meNotificationsHint => '$enHint';"), isTrue);
    });

    test('⑥★★ 承诺↔实现 交叉核对：本页源码里既没有声音控件、也确实有"时区"和"定时"', () {
      final src = File(_pageSrcReadOnly).readAsStringSync();
      expect(src.trim(), isNotEmpty, reason: '读不到页面源码 ⇒ 这条是假绿');
      for (final w in _soundWordsZh) {
        expect(src.contains(w), isFalse,
            reason: '`$_pageSrcReadOnly` 里出现了 `$w`：要么本页真加了声音设置'
                '（那就要把副标题的承诺改回来），要么是别的写法（改名要同步本守卫）');
      }
      // 反向：本页**确实**有的两样，副标题/实现都不能丢
      expect(src.contains('snoozeTimezone'), isTrue, reason: '本页应有"时区"行');
      expect(src.contains('snoozeScheduleTitle'), isTrue, reason: '本页应有"定时免打扰"行');
    });
  });
}
