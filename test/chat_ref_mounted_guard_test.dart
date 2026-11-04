// 守卫：`ChatSessionController` 里**异步空隙之后不许裸写 `state`**。
//
// ★ r670（`DA296`）：Windows 站真机整轮跑完后炸 `UnmountedRefException` ——
//   根因是 `_syncLists` 的 **`catch` 里裸写 `state`**（r319 只守了成功路径）。
//   本文件同时升级扫描器：① `catch/finally` 是边界（否则回溯会越过它找到 try 里的
//   守卫，判「已守」）② 扫描前剥掉行注释（否则注释里提到 `ref.mounted` 会被当判据）。
//
// ## 为什么有这条（r319 实测，不是推测）
//
// macOS 写动词走查（`integration_test/platform_writes_test.dart`）在**收尾**时抛出：
// ```
// UnmountedRefException: Cannot use the Ref of
//   NotifierProvider<ChatSessionController, ChatSyncState>#36c07 after it has been disposed.
//   #2 ChatSessionController._connectSocket (chat_session_controller.dart:602)
// ```
// 根因：`await socket.connect()` / `await socket.waitReady(...)` 之后直接写 `state`，
// 而这时页面/会话可能已经销毁。Riverpod 自己给的口径就是
// **"check `ref.mounted` after async gaps"**。
//
// 修法是机械的（在会跨 `await` 的 `state = …` 前加 `if (!ref.mounted) return;`），
// 但**机械修改最容易漏**：9 处里漏一处就还是炸。所以配一个静态守卫，
// 并附**反向用例**（喂一段故意漏守卫的源码，必须报出来）——否则"0 违规"
// 可能只是扫描器根本不会命中（§1.3.0.1「校验 0 条不是成功，是没校验」）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _path = 'lib/src/features/chat/chat_session_controller.dart';

/// 扫描一段源码，返回"跨了 `await` 却没有 `ref.mounted` 守卫"的 `state = …` 行号。
///
/// 判据（保守实现，宁可漏报不误报）：
///  * 只看 `state = …` 的赋值行（`state.copyWith` 里的读取不算）；
///  * 往上看同一个方法体内是否有 `await`；
///  * 中间出现 `ref.mounted` ⇒ 合规；
///  * 遇到方法签名（缩进 ≤ 2 且含 `(` 且以 `{` 或 `=>` 结尾）⇒ 判定边界，停止回溯。
/// 去掉行注释（`// …`）—— **注释里提到 `ref.mounted` 不算守卫**。
/// r670 实测踩到：catch 上方那段注释解释了 r319 加了 `ref.mounted`，
/// 扫描器把注释当判据 ⇒ 真的漏守反而"通过"。
String stripLineComments(String source) => source
    .split('\n')
    .map((l) => l.replaceFirst(RegExp(r'//.*$'), ''))
    .join('\n');

List<int> unguardedStateWrites(String source) {
  final lines = stripLineComments(source).split('\n');
  final bad = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    // 赋值（`state =` / `state = state.copyWith`），排除 `state ==` 比较
    if (!RegExp(r'^\s*state\s*=\s').hasMatch(line)) continue;
    var sawAwait = false;
    var guarded = false;
    for (var j = i - 1; j >= 0 && i - j < 60; j--) {
      final up = lines[j];
      if (RegExp(r'^\s{0,2}\S.*\(.*(\{|=>)\s*$').hasMatch(up)) {
        break; // 方法签名 = 边界
      }
      // ★ r670：**`catch` / `on … catch` / `finally` 也是边界**。
      //   原来的回溯会越过 `} catch (e) {` 继续往上，找到 `try` 里那句
      //   `if (!ref.mounted) return;` 就判"已守" ⇒ 失败路径裸写被**静默放过**
      //   （Windows 站实测：整轮跑完才炸 `UnmountedRefException`）。
      if (RegExp(r'^\s*\}\s*(on\s+\S+\s+)?(catch|finally)\b').hasMatch(up)) {
        // `try { … await … } catch { state = … }`：跨 await 是**必然**的，
        // 而 try 里的守卫**不覆盖** catch ⇒ 直接判"跨 await 且未守"。
        sawAwait = true;
        guarded = false;
        break;
      }
      if (up.contains('ref.mounted')) {
        guarded = true;
        break;
      }
      if (RegExp(r'(^|\s)await\s').hasMatch(up)) {
        sawAwait = true;
      }
    }
    if (sawAwait && !guarded) bad.add(i + 1);
  }
  return bad;
}

void main() {
  test('真实文件里没有"跨 await 裸写 state"的地方', () {
    final src = File(_path).readAsStringSync();
    final bad = unguardedStateWrites(src);
    expect(
      bad,
      isEmpty,
      reason: '这些行在 await 之后直接写 state（应在上面加 `if (!ref.mounted) return;`）：$bad',
    );
  });

  test('防空转：文件里确实有 await + state + ref.mounted（否则上面的空是假的）', () {
    final src = File(_path).readAsStringSync();
    expect(src.contains('await '), isTrue);
    expect(src.contains('state = '), isTrue);
    expect(
      src.contains('ref.mounted'),
      isTrue,
      reason: '一个 ref.mounted 都没有 ⇒ 第一条用例是"没校验"，不是"通过"',
    );
  });

  test('★ 反向验证：故意漏守卫的源码必须被扫出来', () {
    const broken = '''
class C {
  Future<void> bad() async {
    await something();
    state = state.copyWith(phase: 1);
  }
}
''';
    expect(unguardedStateWrites(broken), [4]);

    const fixed = '''
class C {
  Future<void> good() async {
    await something();
    if (!ref.mounted) return;
    state = state.copyWith(phase: 1);
  }
}
''';
    expect(unguardedStateWrites(fixed), isEmpty);

    // 同一个方法里"先 await 再守卫再 await 再写"也必须算合规
    const doubleGap = '''
class C {
  Future<void> good2() async {
    await a();
    if (!ref.mounted) return;
    await b();
    if (!ref.mounted) return;
    state = state.copyWith(phase: 2);
  }
}
''';
    expect(unguardedStateWrites(doubleGap), isEmpty);
  });
}
