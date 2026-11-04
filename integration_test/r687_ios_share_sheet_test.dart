// s287（r687）：iOS 的**系统分享面板**真的摆出来了 —— `UIActivityViewController`。
//
// 背景：`DA320` 是"iOS 上分享不出去"。Dart 有两处出站：
//   * `lib/src/features/notes/note_share_out.dart` → `synhub/share_text`.shareText；
//   * `lib/src/features/files/file_link_share.dart` → `synhub/media_open`.shareFiles。
// 到 r686 为止两条都只有 Kotlin 实现，iOS 上能力层直接拦住 ⇒ 返回 false。
//
// 本用例只做**模拟器上能证的那部分**：
//   ① 能力层在 iOS 上真的放行 `systemShare`（不再被自己的门拦下）；
//   ② 两条通道在 iOS 上都回 true（= 面板真的 present 了，而不是 MissingPlugin）；
//   ③ 空载荷 / 不存在的附件必须回 false（"不假装拉起过"）。
// **验不到**：用户在面板里点了哪个 App、面板里有没有内容 —— 那要真实点击/截图
// 于面板内部（无头模拟器点不了），见 `docs/platform-ios.md` §25.4。
//
// 跑法：
//   flutter test integration_test/r687_ios_share_sheet_test.dart \
//     -d 1FFF0EDA-3230-46F5-A011-6119E6040381
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';

const MethodChannel _shareText = MethodChannel('synhub/share_text');
const MethodChannel _mediaOpen = MethodChannel('synhub/media_open');

/// 取面板像素时用：`--dart-define=R687_HOLD_SECONDS=15` 会让用例在**面板摆着**
/// 的状态停住，好让 `xcrun simctl io … screenshot` 抓到它（像素证据
/// `docs/evidence-r687-690-ios/r687_share_sheet.png`）。默认 0 = 不停。
const int _holdSeconds = int.fromEnvironment('R687_HOLD_SECONDS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('r687 系统分享面板：能力放行 + 两条通道都能拉起 + 空载荷如实拒绝', (
    tester,
  ) async {
    // ① 能力层：iOS 上 systemShare 必须 available（这是 r687 的改动）
    final caps = staticCapabilitiesFor(AppHost.ios);
    expect(caps.can(AppCapability.systemShare), isTrue,
        reason: 'iOS 的 ShareBridge 已落地 ⇒ 能力层不许再拦');
    // ignore: avoid_print
    print('[r687] capability systemShare='
        '${caps.statusOf(AppCapability.systemShare).reason}');

    // ②-a 文本分享（笔记正文那条路）
    final textOk = await _shareText.invokeMethod<bool>('shareText', {
      'subject': 'SynHub r687 分享探针',
      'text': '这是一条由 integration_test 触发的分享文本（r687）。',
    });
    // ignore: avoid_print
    print('[r687] shareText -> $textOk');
    expect(textOk, isTrue, reason: '面板必须真的 present（false = 桥没接/没 VC）');

    await tester.pump(const Duration(milliseconds: 800));

    // ②-b 附件分享（笔记附件那条路）
    final tmp = File('${Directory.systemTemp.path}/r687_share_probe.txt');
    await tmp.writeAsString('r687 attachment probe\n');
    final filesOk = await _mediaOpen.invokeMethod<bool>('shareFiles', {
      'paths': <String>[tmp.path],
      'text': 'r687 附件',
      'subject': 'SynHub r687',
      'mime': 'text/plain',
    });
    // ignore: avoid_print
    print('[r687] shareFiles -> $filesOk');
    expect(filesOk, isTrue, reason: '真实存在的附件必须能分享出去');

    if (_holdSeconds > 0) {
      // ignore: avoid_print
      print('[r687] holding $_holdSeconds s for pixel evidence');
      for (var i = 0; i < _holdSeconds * 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pump(const Duration(milliseconds: 800));

    // ③ 反向：空载荷与不存在的附件必须如实 false（不假装拉起过）
    final emptyText = await _shareText
        .invokeMethod<bool>('shareText', {'subject': '', 'text': ''});
    final missingFile = await _mediaOpen.invokeMethod<bool>('shareFiles', {
      'paths': <String>['/tmp/r687-does-not-exist.txt'],
      'text': '',
      'subject': '',
      'mime': 'text/plain',
    });
    // ignore: avoid_print
    print('[r687] emptyText=$emptyText missingFile=$missingFile');
    expect(emptyText, isFalse, reason: '空文本不许拉起面板');
    expect(missingFile, isFalse, reason: '不存在的附件不许拉起面板');

    await tester.pump(const Duration(milliseconds: 300));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
