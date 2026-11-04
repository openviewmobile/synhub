// `DA307`（r676）：**回退面板不许把"解不开"说成"会话过期"**。
//
// 现场（iOS 模拟器，`/tmp/r676_video.log`）：点 `Citizen Kane (1941).mkv`，11.9s 后
// 面板出现（这是好事），但面板上写着
//   "Session expired; automatic resume failed. Tap Retry to sign in again."
// 并给了一个 `Retry` 按钮 —— 而真实原因是 **AVFoundation 认不出 matroska**
// （`-11828 / NSOSStatusErrorDomain(-12847)`）。重新登录一百次也解不开它。
//
// 机制：`MediaFallbackPanel` 里那句说明是**硬编码的会话语义**（`mediaSessionResumeFailedHint`），
// 触发条件只有 `onRetry != null`；而 `onRetry` 在 `decodeFailed` / `networkFailed` /
// `streamRejected` / `tunnelUnavailable` 上都会给 ⇒ 说明文案与原因脱钩。
//
// 判据：**只有 `sessionExpired` 才许挂那句说明**；其它可重试原因照样给 `Retry` 按钮，
// 但不许用"重新登录"解释它。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';

MediaSource _video(String name) => MediaSource(
  uri: 'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download&_sid=S',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: name,
  supportsRange: true,
);

Future<void> _pumpPanel(
  WidgetTester tester,
  MediaUnavailableReason reason,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: MediaFallbackPanel(
          source: _video('Citizen Kane (1941).mkv'),
          reason: reason,
          onRetry: () {},
          onOpenExternal: () {},
          onDownload: () {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('DA307：解不开容器（codecUnsupported）→ 不许说"会话过期"', (tester) async {
    await _pumpPanel(tester, MediaUnavailableReason.codecUnsupported);
    expect(
      find.byKey(const Key('media-session-resume-hint')),
      findsNothing,
      reason: '这不是会话问题 ⇒ 一个"重新登录"的字都不许出现',
    );
    expect(find.textContaining('会话过期'), findsNothing);
    // 出路照旧要给：用其他应用打开 / 下载
    expect(find.text('用其他应用打开'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
  });

  testWidgets('DA307：解码失败（decodeFailed）可重试，但说明不许说成会话', (tester) async {
    await _pumpPanel(tester, MediaUnavailableReason.decodeFailed);
    expect(
      find.byKey(const Key('media-session-retry')),
      findsOneWidget,
      reason: 'decodeFailed 是"重试一次也许能好"（网络抖动/瞬时失败）',
    );
    expect(
      find.byKey(const Key('media-session-resume-hint')),
      findsNothing,
      reason: '重试按钮的说明必须与原因一致（DA307）',
    );
  });

  testWidgets('反向：真会话失效时那句说明必须还在', (tester) async {
    await _pumpPanel(tester, MediaUnavailableReason.sessionExpired);
    expect(
      find.byKey(const Key('media-session-resume-hint')),
      findsOneWidget,
      reason: '会话问题就该说"重新登录"（既有行为不许回退）',
    );
    expect(find.byKey(const Key('media-session-retry')), findsOneWidget);
  });
}
