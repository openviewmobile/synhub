// ★★★ 第 112 轮 / 台账 L6：官方 DSnote 的 `commit_msg.device` 是
// **真实 `Build.MODEL`**（smali 三处取证：`SyncPushCallable` / `LoginTask` /
// `SyncCallable`），我方此前硬编码 `'Flutter'`。
//
// 这里守三件事：
//   ① 纯函数口径：非空用真型号、空/空白回落 `'Flutter'`（**不假装**机型）；
//   ② 静态字段被 `useDeviceModel` 正确覆盖，且**空值不覆盖**；
//   ③ `commit_msg` 外壳把它带出去（`{device, listable}` 结构位不变）。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/device/device_model.dart';
import 'package:synhub/src/data/note_api.dart';

void main() {
  group('112. commit_msg.device = 真实设备型号（官方 Build.MODEL）', () {
    test('★ 非空用真型号', () {
      expect(noteCommitDeviceFrom('LGE-AN10'), 'LGE-AN10');
      expect(noteCommitDeviceFrom('  SM-G991B '), 'SM-G991B');
    });

    test('★ 空/null/纯空白 → 回落 Flutter（不假装是某台机器）', () {
      expect(noteCommitDeviceFrom(null), 'Flutter');
      expect(noteCommitDeviceFrom(''), 'Flutter');
      expect(noteCommitDeviceFrom('   '), 'Flutter');
      // 显式 fallback 也可换
      expect(noteCommitDeviceFrom(null, fallback: 'desktop'), 'desktop');
    });

    test('★ useDeviceModel：非空覆盖，空值**保持原值**', () {
      final original = NoteStationApi.deviceName;
      addTearDown(() => NoteStationApi.useDeviceModel(original));
      NoteStationApi.useDeviceModel('LGE-AN10');
      expect(NoteStationApi.deviceName, 'LGE-AN10');
      NoteStationApi.useDeviceModel('');
      expect(NoteStationApi.deviceName, 'LGE-AN10', reason: '空值不许清掉型号');
      NoteStationApi.useDeviceModel(null);
      expect(NoteStationApi.deviceName, 'LGE-AN10');
      NoteStationApi.useDeviceModel('  X  ');
      expect(NoteStationApi.deviceName, 'X', reason: '两侧空白要去掉');
    });

    test('★ commit_msg 外壳照旧（device + listable 结构位）', () {
      final original = NoteStationApi.deviceName;
      addTearDown(() => NoteStationApi.useDeviceModel(original));
      NoteStationApi.useDeviceModel('LGE-AN10');
      final msg = NoteStationApi.commitMsg();
      expect(msg['device'], 'LGE-AN10');
      expect(msg['listable'], isFalse);
      expect(NoteStationApi.commitMsg(listable: true)['listable'], isTrue);
    });

    test('★ 测试环境读原生桥 → null（不碰平台通道、不抛）', () async {
      expect(await readDeviceModel(), isNull);
    });
  });
}
