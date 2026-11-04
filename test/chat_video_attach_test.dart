// P0-1：视频「从相册选择 / 录制」的发送侧验证。
//
// 官方证据（`docs/chat-parity-audit.md:161-162`）：
//   * `input_section.xml` `video`（`:104`）→ `launchVideo`
//     （`CreatePostFragment.java:490-556`，走系统选择器 `video/*`）
//   * `input_section.xml` `record`（`:112`）→ `launchRecord`
//     （`android.media.action.VIDEO_CAPTURE` + `EXTRA_VIDEO_QUALITY=1`）
// 两者发送时都复用同一条附件上传链路（`Post/create` multipart），
// 所以本文件只验"入口 → 取视频 source 正确 → 真的走了既有上传链"。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:synhub/src/features/chat/chat_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Widget _app(ProviderContainer c, int channelId) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: channelId)),
);

/// 打开「+」面板并点某个入口。
///
/// `_attach` 里 `File(path).length()`（大小上限校验）是**真 I/O**，在
/// widget test 的 fake-async 区里只有 `runAsync` 才会推进，所以点完给一段
/// 真实事件循环时间。
Future<void> _openAttachAndTap(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('发送图片 / 文件'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump();
}

List<Map<String, dynamic>> _uploads(FakeTransport t) => t.calls
    .where((c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'create')
    .toList();

void main() {
  testWidgets('「相册视频」→ pickVideo(gallery) → 走附件上传链（video/mp4）', (tester) async {
    final sources = <ImageSource>[];
    final h = await bootChat(
      moreOverrides: [
        chatVideoPickerProvider.overrideWithValue((source) async {
          sources.add(source);
          return XFile('/tmp/flt-video.mp4');
        }),
      ],
    );
    await tester.pumpWidget(_app(h.container, 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await _openAttachAndTap(tester, '相册视频');

    expect(sources, [ImageSource.gallery]);
    final ups = _uploads(h.transport);
    expect(ups, hasLength(1), reason: '视频必须真的走上传链路');
    expect(ups.single['file_name'], 'flt-video.mp4');
    expect(
      ups.single['mime_type'],
      'video/mp4',
      reason: 'picker 不回 mimeType 时按扩展名回落 video/mp4，别发 octet-stream',
    );
    expect(ups.single['type'], 'file');
  });

  testWidgets('「录制视频」→ pickVideo(camera)（官方 VIDEO_CAPTURE 那条）', (tester) async {
    final sources = <ImageSource>[];
    final h = await bootChat(
      moreOverrides: [
        chatVideoPickerProvider.overrideWithValue((source) async {
          sources.add(source);
          return XFile('/tmp/flt-record.mov');
        }),
      ],
    );
    await tester.pumpWidget(_app(h.container, 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await _openAttachAndTap(tester, '录制视频');

    expect(sources, [ImageSource.camera]);
    final ups = _uploads(h.transport);
    expect(ups, hasLength(1));
    expect(ups.single['mime_type'], 'video/quicktime');
  });

  testWidgets('用户取消 → 不发任何请求、不报错', (tester) async {
    final sources = <ImageSource>[];
    final h = await bootChat(
      moreOverrides: [
        chatVideoPickerProvider.overrideWithValue((source) async {
          sources.add(source);
          return null;
        }),
      ],
    );
    await tester.pumpWidget(_app(h.container, 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await _openAttachAndTap(tester, '相册视频');

    expect(sources, [ImageSource.gallery]);
    expect(_uploads(h.transport), isEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('录制权限被拒 → 明确文案（相机/麦克风），且不发请求', (tester) async {
    final h = await bootChat(
      moreOverrides: [
        chatVideoPickerProvider.overrideWithValue(
          (source) async => throw PlatformException(
            code: 'camera_access_denied',
            message: 'denied',
          ),
        ),
      ],
    );
    await tester.pumpWidget(_app(h.container, 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await _openAttachAndTap(tester, '录制视频');

    expect(_uploads(h.transport), isEmpty);
    expect(find.textContaining('无法访问相机或麦克风'), findsOneWidget);
  });

  testWidgets('相册读取被拒 → 另一条文案（相册权限）', (tester) async {
    final h = await bootChat(
      moreOverrides: [
        chatVideoPickerProvider.overrideWithValue(
          (source) async =>
              throw PlatformException(code: 'photo_access_denied'),
        ),
      ],
    );
    await tester.pumpWidget(_app(h.container, 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await _openAttachAndTap(tester, '相册视频');

    expect(_uploads(h.transport), isEmpty);
    expect(find.textContaining('无法读取相册视频'), findsOneWidget);
  });
}
