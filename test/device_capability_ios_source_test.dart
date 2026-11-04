// ★★★ D5（第二个生产者 · P1）：`_ramBaselineTier(0) → unsupported` 的回归锁
// —— **iOS 路径**（`source == 'proc'`、内存这一项没读到）。
//
// ## 事实（pass9 取证）
// iOS 上没有硬件桥、也没有 `/proc/meminfo` ⇒ `readProcCapabilitySnapshot()`
// 给的是 `source: 'proc'` + `totalRamBytes: 0`。旧代码把 `0` 判成
// `DeviceComputeTier.unsupported` ⇒ 端侧 AI 模块被**连带隐藏**，
// 而且与像素层已经画出的 `—`（"没读到"）**自相矛盾**。
//
// AGENTS §2.0.6②：**探测失败 ≠ 硬件不行**；只有**拿到结论**时才 fail-closed。
// `RAM == 0` / 未知必须落到"**未知 ⇒ 不隐藏**"（或 `—`），不许编成 `Unsupported`。
//
// ## 生产者清点（§2.0.26，逐个裁定见交付报告）
// 本文件钉的是**结论源**：同一份 iOS 式快照下，
//   * `tier` 只能落在未判定档；
//   * `moduleVisible` / `aiModuleVisibleFor` 不许因此为假；
//   * "确实小"（512MB，已知事实）仍必须 fail-closed。
//
// ## 断言口径（§2.0.30②）
// 钉**机制量**：`tier` / `source` 派生的 `ramUnknown`·`hardwareUndetermined` /
// `moduleVisible` / `notes` 里的 `veto:` —— **不**钉"界面上有没有那个按钮"。
//
// ## 反向验证
// 把 `device_capability.dart` 的
// `if (ramBytes <= 0) return DeviceComputeTier.unknown;` 改回
// `return DeviceComputeTier.unsupported;` ⇒ 本文件 `D5b-1` 与既有
// `test/device_capability_test.dart`「内存读不到（0）⇒ unknown」**当场红**
// （原文见交付报告），随后恢复。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/device/device_capability.dart';
import 'package:synhub/src/features/ai/ai_device_fit.dart';

const int _gb = 1024 * 1024 * 1024;

/// iOS 式快照：从 `/proc` 回落、**内存这一项没读到**。
DeviceCapabilitySnapshot _iosLike() => const DeviceCapabilitySnapshot(
  // iOS 的 `/proc` 回落拿不到 SoC 型号，但 `Platform.numberOfProcessors` 拿得到核数
  hardware: '',
  cpuCores: 6,
  totalRamBytes: 0, // ★ 关键：内存事实没拿到（不是"内存是 0"）
  freeStorageBytes: 0,
  source: 'proc', // ★ iOS 走的是 /proc 回落：既不是 host，也不是原生桥的 platform
);

void main() {
  test('★★★ D5b-1：iOS 式快照（proc + RAM 没读到）⇒ tier=unknown，**不是** unsupported，且不隐藏', () {
    final p = classifyDevice(_iosLike());

    expect(
      p.tier,
      DeviceComputeTier.unknown,
      reason: '★★ 探测失败 ≠ 硬件不行：没有内存事实就**不下档位结论**',
    );
    expect(
      p.tier,
      isNot(DeviceComputeTier.unsupported),
      reason: '★ 反向：unsupported = "有事实、结论太弱"（会隐藏），不许拿它冒充"没读到"',
    );
    // 两个派生只读视图（判据仍只是 tier / snapshot，不参与门控）
    expect(p.hardwareUndetermined, isTrue);
    expect(p.ramUnknown, isTrue);

    // ★ 门控机制量：未判定 ⇒ 模块**不隐藏**
    expect(p.moduleVisible, isTrue, reason: '§2.0.6②：未判定不许隐藏');
    expect(aiModuleVisibleFor(p), isTrue);
    // 注：`eligibleModelsFor(p)` 在未判定时**为空**是刻意的（fail-closed：
    // 不发起下载），但理由不是"本机不行" —— 模块本身仍可见。这里只钉"可见"。
    // 原始事实仍如实带出来（界面据此画 `—`）
    expect(p.notes, contains('ram:0'));
  });

  test('★★ D5b-2（反向）：内存**确实**小（512MB，已知事实）⇒ 仍 unsupported + 隐藏', () {
    // 别把"事实不足"与"事实就是很差"混成一条路：后者必须 fail-closed。
    final p = classifyDevice(
      const DeviceCapabilitySnapshot(
        cpuCores: 8,
        abis: ['arm64-v8a'],
        totalRamBytes: 512 * 1024 * 1024,
        freeStorageBytes: 64 * _gb,
        source: 'platform',
      ),
    );
    expect(p.tier, DeviceComputeTier.unsupported);
    expect(p.ramUnknown, isFalse, reason: '有事实（就是小），不算"没读到"');
    expect(p.moduleVisible, isFalse);
    expect(aiModuleVisibleFor(p), isFalse);
  });

  test('★★ D5b-3：其它"没读到"的字段（核数 0 / ABI 空）也不许编成 unsupported', () {
    // 硬否决的每一条都带"有事实"守卫：cpuCores > 0、abis.isNotEmpty。
    final p = classifyDevice(
      const DeviceCapabilitySnapshot(
        cpuCores: 0, // 没读到
        totalRamBytes: 4 * _gb, // 内存读到了 ⇒ 正常判档
        source: 'proc',
      ),
    );
    expect(
      p.notes.where((n) => n.startsWith('veto:')),
      isEmpty,
      reason: '★ 核数/ABI 缺项不是"事实"，不许触发硬否决',
    );
    expect(p.tier, DeviceComputeTier.mainstream);
    expect(p.moduleVisible, isTrue);
  });
}
