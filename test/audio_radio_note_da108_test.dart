// **DA108**（r472）：电台页那条说明被单行截断，丢掉"只列表、不播放"的关键半句。
//
// 真机逐字（修前）：`Tap a category to open it; tap a station to start…`
// —— 被截掉的正是"SHOUTcast 地址是 .pls 播放列表，起播前会先解析真实流地址"
// 这半句，用户读到的就只是"点一下就播"（和实际行为不符）。
// 修法：`_RadioListNote` 换成 `DesignNote`（自动换行、设计语言里的说明卡）。
//
// 本用例是**静态守卫**（像素证据见
// `docs/evidence-r472/device/r472_01_radio_note_truncated_before.png` 与 `..._02_...png`），
// 防的是"以后有人为了省版面又把它塞回单行标签"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DA108：电台页说明必须是会换行的说明卡（不是单行截断标签）', () {
    final src = File(
      'lib/src/features/audio/audio_radio_page.dart',
    ).readAsStringSync();

    expect(
      src.contains('DesignNote(asRadioListNote'),
      isTrue,
      reason: 'DA108：说明要用 DesignNote（自动换行）',
    );
    expect(
      src.contains('TelemetryLabel(\n        asRadioListNote'),
      isFalse,
      reason: 'DA108：不许回到单行 TelemetryLabel（会被省略号截断）',
    );
  });
}
