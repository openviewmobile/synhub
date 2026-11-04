// DA105 结构守卫：`scripts/build_arm64_release.sh` 里**不许**再出现"无条件断言签名不同"。
//
// 背景（r458 真机）：脚本原来每建一次就打印
//   「⚠️ 与设备上已装包**签名不同** ⇒ 不能 -r 覆盖装；装了要卸载重装（清数据、需重新登录）」
// —— 但 r452 起验收机装的就是**发布签名包**（用户 2026-10-17 拍板"以后一律打发布包"），
// 这句话是**假警告**；照做会去卸载重装 ⇒ 清数据 + 丢登录。实测 r458 两次构建都是假警告：
// 设备 `base.apk` 与新产物 `apksigner` 证书 SHA-256 **逐字相同**（`c2db9c8b…`），
// `adb install -r` 正常 `Success`、`firstInstallTime` 未变。
//
// 判据（三条）：
//  ① 旧的无条件警告文案**不在**脚本里（改成"只有证书真不同才需要重装"的中性说明）；
//  ② 收尾有**真核对**：拉设备上 `base.apk` 与本次产物比 `apksigner` 证书摘要；
//  ③ 核对结论要能区分"同签名可 -r"与"真不同需卸载重装"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final script = File('scripts/build_arm64_release.sh');
  final src = script.readAsStringSync();

  group('DA105：构建脚本不许无条件断言「签名不同 ⇒ 不能 -r」', () {
    test('① 旧文案已删、且不再带 ⚠️ 前缀的绝对断言', () {
      expect(
        src.contains('⚠️ 与设备上已装包**签名不同** ⇒ 不能 -r 覆盖装'),
        isFalse,
        reason: 'DA105：这句是无条件打印的假警告（r452 起设备已装发布签名包）',
      );
      expect(
        src.contains('只有证书真不同才需要卸载重装'),
        isTrue,
        reason: 'DA105：要留下中性说明，别把"可能"说成"一定"',
      );
    });

    test('② 收尾有真核对（读设备 base.apk 与产物证书摘要逐字比）', () {
      expect(src.contains('设备同签名核对'), isTrue, reason: 'DA105：核对段必须存在');
      expect(
        src.contains('certificate SHA-256 digest'),
        isTrue,
        reason: 'DA105：判据取 apksigner 的证书摘要，不看 Gradle 打印',
      );
      expect(
        src.contains('s/^package://p'),
        isTrue,
        reason: 'DA105：设备路径要从 `pm path` 的 `package:` 前缀里取',
      );
      expect(
        RegExp(r'adb -s "\$SERIAL" pull').hasMatch(src),
        isTrue,
        reason: 'DA105：必须真把设备上的 base.apk 拉下来比，不许凭 gradle 猜',
      );
    });

    test('③ 两种结论都在（同签名可 -r / 真不同需卸载）', () {
      expect(src.contains('可 adb install -r'), isTrue);
      expect(src.contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE'), isTrue);
      expect(
        src.contains('在线设备数=\${DEV_COUNT}'),
        isTrue,
        reason: 'DA105：多设备/无设备时要**说清跳过原因**，别静默',
      );
    });
  });
}
