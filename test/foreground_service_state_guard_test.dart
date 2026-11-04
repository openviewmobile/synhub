// 静态守卫：常驻服务状态**只有一个来源**（第 342 轮 D45）。
//
// ★ 为什么有这条（r342 真机）：`设置` 里「通知与后台」那一行读的是
//   `ChatSyncState.foregroundService` —— 一个**会话内存里的快照**，只在两条路上更新
//   （socket 就绪时、用户手动拨开关时）。真机实证：`adb install -r` 之后系统把上一进程的
//   `ChatForegroundService` 又拉起来了（`dumpsys activity services` 里明明有 `ServiceRecord`），
//   而这一行显示「前台服务未运行」——**跟系统说的相反**。
//   ⇒ §2.0.26：「服务在不在跑」被造成了两份表示（快照 + 系统真值），两份不一致时界面就说谎。
//
// 修法：删掉快照字段，界面一律 `ref.watch(foregroundServiceRunningProvider)`
//（实时 `isRunning()`；回到前台 `invalidate` 再问一次）。
//
// 判据（两条，都扫真仓）：
//   R1 `ChatSyncState` / `ChatSessionController` 里**不许**再出现 `foregroundService` 字段与 copyWith 项；
//   R2 两个设置渲染面必须读 `foregroundServiceRunningProvider`，且**不许**出现 `.foregroundService` 读取。
//
// ★ 已知边界：只认这些字面形状（`.foregroundService` / `final bool foregroundService` /
//   `foregroundService:`）；换名写法（如局部变量 `final fgs = sync.xxx`）判不出来 —— 靠评审。
// ★ 注释不算（`_stripComments`），因为**要留**的实现说明里就有这个词。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _controller = 'lib/src/features/chat/chat_session_controller.dart';
const List<String> _renderSites = <String>[
  'lib/src/features/settings/settings_page.dart',
  'lib/src/features/settings/notification_settings_page.dart',
];

/// 去掉整行注释与行尾 `// …`（字符串里的 `//` 会被误伤，但这些文件里没有 URL 字面量）。
String stripComments(String s) => s
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

/// R1：控制器里还有没有那个快照字段。
List<String> snapshotHits(String src) {
  final code = stripComments(src);
  final out = <String>[];
  for (final pat in <String>[
    'final bool foregroundService',
    'foregroundService:',
    'this.foregroundService',
    'bool? foregroundService',
  ]) {
    if (code.contains(pat)) out.add(pat);
  }
  return out;
}

/// R2：渲染面有没有读快照（`foregroundServiceRunningProvider` 不算）。
List<String> snapshotReads(String src) {
  final code = stripComments(src);
  final out = <String>[];
  for (final m in RegExp(r'[\w.]*\.foregroundService\b').allMatches(code)) {
    final hit = m.group(0)!;
    if (hit.endsWith('foregroundServiceRunningProvider')) continue;
    out.add(hit);
  }
  return out;
}

void main() {
  test('R1：控制器里不许再留「常驻服务在跑」的快照字段', () {
    final hits = snapshotHits(File(_controller).readAsStringSync());
    expect(
      hits,
      isEmpty,
      reason: '$_controller 里仍有快照表示：$hits\n'
          '「服务在不在跑」只能有一个来源（实时 `isRunning()`），'
          '不许再有会话内存快照（D45 / §2.0.26）。',
    );
  });

  test('R2：两个设置渲染面必须实时查询，不许读快照', () {
    for (final p in _renderSites) {
      final src = File(p).readAsStringSync();
      expect(
        src.contains('foregroundServiceRunningProvider'),
        isTrue,
        reason: '$p 没有读实时 provider',
      );
      final reads = snapshotReads(src);
      expect(reads, isEmpty, reason: '$p 仍在读快照：$reads');
    }
  });

  test('判据本身有效（反向：假样本必红、真 provider 名不误报）', () {
    expect(snapshotHits('  final bool foregroundService;').isNotEmpty, isTrue);
    expect(snapshotHits('  state = state.copyWith(foregroundService: x);').isNotEmpty, isTrue);
    expect(snapshotHits('  final fgs = ref.watch(foregroundServiceRunningProvider);'), isEmpty);
    expect(
      snapshotReads('final x = sync.foregroundService ? 1 : 0;').isNotEmpty,
      isTrue,
    );
    expect(
      snapshotReads('ref.watch(foregroundServiceRunningProvider)').isEmpty,
      isTrue,
      reason: '实时 provider 的名字里也含 foregroundService，不许被误报',
    );
    // 注释里的词不许算命中（否则这条守卫会被"解释性注释"逼着删注释）
    expect(snapshotHits('// final bool foregroundService; 说明').isEmpty, isTrue);
  });

  test('防空转：真仓里确实有人读那个 provider（否则 R2 是假绿）', () {
    var n = 0;
    for (final p in _renderSites) {
      if (File(p).readAsStringSync().contains('foregroundServiceRunningProvider')) {
        n++;
      }
    }
    expect(n, _renderSites.length);
    // 反向：`ChatSyncState` 真的还在（别把文件路径写错导致"扫了空文件也绿"）
    final c = File(_controller).readAsStringSync();
    expect(c.contains('class ChatSyncState'), isTrue);
    expect(c.length, greaterThan(20000));
  });
}
