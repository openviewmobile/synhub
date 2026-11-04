// ★★ **视频「相册选择 / 录制」的真实 seam 验证**
// —— ②聊天 审计行 **161 / 162**（规则 B2）。
//
// ## 既有测试缺哪一环
//
// `test/chat_video_attach_test.dart`（5 条）验的是「入口 → 上传链」，但它
// **override 了我们自己那层 `chatVideoPickerProvider`**：
//
// ```dart
// chatVideoPickerProvider.overrideWithValue((source) async {
//   sources.add(source);            // ← 把 source 记下来就算"验证"了
//   return XFile('/tmp/flt-video.mp4');
// })
// ```
//
// ⇒ 它证明了"我们**要求**的是 gallery/camera"，但**跳过了 `ImagePicker()` 这一环**：
//   真实的 `ImagePicker().pickVideo(source:)` 到底把 `ImageSource` 翻成了什么、
//   有没有带上 `CameraDevice.rear`、取消时回什么、权限被拒时抛什么 —— **都没测**。
//   审计行 161/162 的判定也因此停在「真机未验」「依赖系统相机 App」。
//
// 用户 2026-09-23 新规 B2：「真机/真 NAS 无法验证的也一律通过 Mock Server 验证」。
// ⇒ 本文件把 `ImagePickerPlatform.instance` 换成假的（**`image_picker` 官方文档
//   推荐的测试方式**），让**真实的 `ImagePicker()`** 跑起来。
//
// ## 链路
// ```
//   chatVideoPickerProvider（真实默认实现）
//     → ImagePicker().pickVideo(source: ImageSource.gallery|camera)
//       → ImagePickerPlatform.instance.getVideo(source:, preferredCameraDevice:, maxDuration:)
//         → [本文件替换的假 platform]
// ```
//
// ## 事实来源
// * `image_picker-1.2.3/lib/image_picker.dart:313-323` ——
//   `pickVideo` 就是 `platform.getVideo(source:, preferredCameraDevice:
//   CameraDevice.rear, maxDuration: null)`（**逐字**，不是我推的）。
// * `image_picker_android-0.8.13+23` —— 安卓侧再把它翻成
//   `SourceSpecification(type: SourceType.gallery|camera, camera: SourceCamera.rear)`
//   并经 Pigeon `ImagePickerApi.pickVideos` 下发（该 codec 是私有的，
//   测试侧无法构造，所以这里选官方推荐的 platform seam）。
//
// ## 不做什么
// 不碰真机、不碰真 NAS（§5.1）。本文件全程离线。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:synhub/src/features/chat/chat_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 一次 `getVideo` 调用的实参记录。
class _Call {
  _Call(this.source, this.device, this.maxDuration);

  final ImageSource source;
  final CameraDevice device;
  final Duration? maxDuration;

  @override
  String toString() => 'getVideo(source=$source, device=$device)';
}

/// 假的 platform：记录实参，按剧本返回 / 抛异常。
///
/// ⚠️ 直接 `extends ImagePickerPlatform`（不是 Mockito mock），
/// 所以 `PlatformInterface.verifyToken` 会通过。
class _FakePickerPlatform extends ImagePickerPlatform {
  _FakePickerPlatform({this.result, this.error});

  /// 返回的视频路径；`null` = 用户取消。
  final String? result;

  /// 非空则抛它（模拟权限被拒 / 无相机 App）。
  final Object? error;

  final List<_Call> calls = [];

  @override
  Future<XFile?> getVideo({
    required ImageSource source,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    Duration? maxDuration,
  }) async {
    calls.add(_Call(source, preferredCameraDevice, maxDuration));
    if (error != null) throw error!;
    return result == null ? null : XFile(result!);
  }
}

Widget _app(ProviderContainer c, int channelId) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: channelId)),
);

/// 打开「+」面板并点某个入口（与既有 `chat_video_attach_test.dart` 同法：
/// `_attach` 里有真 I/O 的 `File(path).length()`，需要真实事件循环时间）。
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
  late ImagePickerPlatform original;

  setUp(() {
    original = ImagePickerPlatform.instance;
  });

  tearDown(() {
    ImagePickerPlatform.instance = original;
  });

  group('VP-1. ★ 直接打真实 provider：`ImagePicker()` 这一环终于被覆盖', () {
    // 不 override `chatVideoPickerProvider` —— 用的是生产默认实现。
    ProviderContainer makeContainer() => ProviderContainer();

    test('★ `ImageSource.gallery` 原样传到 platform.getVideo', () async {
      final fake = _FakePickerPlatform(result: '/tmp/a.mp4');
      ImagePickerPlatform.instance = fake;
      final c = makeContainer();
      addTearDown(c.dispose);

      final picked = await c.read(chatVideoPickerProvider)(ImageSource.gallery);

      expect(fake.calls, hasLength(1), reason: '必须真的到了 platform 层');
      expect(fake.calls.single.source, ImageSource.gallery);
      expect(picked?.path, '/tmp/a.mp4');
    });

    test('★ `ImageSource.camera`（录制）原样传到 platform.getVideo', () async {
      final fake = _FakePickerPlatform(result: '/tmp/b.mp4');
      ImagePickerPlatform.instance = fake;
      final c = makeContainer();
      addTearDown(c.dispose);

      await c.read(chatVideoPickerProvider)(ImageSource.camera);

      expect(fake.calls.single.source, ImageSource.camera);
    });

    test('★ 官方默认的 `CameraDevice.rear` 与 `maxDuration=null`（逐字对齐源码）', () async {
      final fake = _FakePickerPlatform(result: '/tmp/c.mp4');
      ImagePickerPlatform.instance = fake;
      final c = makeContainer();
      addTearDown(c.dispose);

      await c.read(chatVideoPickerProvider)(ImageSource.gallery);

      // `image_picker.dart:318-322` 只传 source/preferredCameraDevice/maxDuration
      expect(fake.calls.single.device, CameraDevice.rear);
      expect(fake.calls.single.maxDuration, isNull);
    });

    test('★ 用户取消（platform 回 null）⇒ 我们的 provider 回 null，不抛', () async {
      ImagePickerPlatform.instance = _FakePickerPlatform(result: null);
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(
        await c.read(chatVideoPickerProvider)(ImageSource.gallery),
        isNull,
      );
    });
  });

  group('VP-2. ★ 端到端：真实 provider + 上传链（不 override 任何东西）', () {
    testWidgets('★「相册视频」→ 真 `ImagePicker()` → `Post/create`（video/mp4）', (
      tester,
    ) async {
      final fake = _FakePickerPlatform(result: '/tmp/flt-video.mp4');
      ImagePickerPlatform.instance = fake;
      // ⚠️ **不**传 `moreOverrides` ⇒ 走生产默认的 `chatVideoPickerProvider`
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await _openAttachAndTap(tester, '相册视频');

      expect(fake.calls.single.source, ImageSource.gallery);
      final ups = _uploads(h.transport);
      expect(ups, hasLength(1), reason: '视频必须真的走上传链路');
      expect(ups.single['file_name'], 'flt-video.mp4');
      expect(ups.single['mime_type'], 'video/mp4');
      expect(ups.single['type'], 'file');
    });

    testWidgets('★「录制视频」→ 真 `ImagePicker()` → `Post/create`（video/quicktime）', (
      tester,
    ) async {
      final fake = _FakePickerPlatform(result: '/tmp/flt-record.mov');
      ImagePickerPlatform.instance = fake;
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await _openAttachAndTap(tester, '录制视频');

      expect(fake.calls.single.source, ImageSource.camera);
      final ups = _uploads(h.transport);
      expect(ups, hasLength(1));
      expect(ups.single['mime_type'], 'video/quicktime');
    });

    testWidgets('★ 录制权限被拒（platform 抛 PlatformException）⇒ 明确文案、**零请求**', (
      tester,
    ) async {
      ImagePickerPlatform.instance = _FakePickerPlatform(
        error: PlatformException(
          code: 'camera_access_denied',
          message: 'No camera permission',
        ),
      );
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await _openAttachAndTap(tester, '录制视频');

      expect(_uploads(h.transport), isEmpty, reason: '没拿到文件就不该发请求');
      expect(find.textContaining('无法访问相机或麦克风'), findsOneWidget);
    });

    testWidgets('★ 相册读取被拒 ⇒ 另一条文案、**零请求**', (tester) async {
      ImagePickerPlatform.instance = _FakePickerPlatform(
        error: PlatformException(code: 'photo_access_denied', message: 'x'),
      );
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await _openAttachAndTap(tester, '相册视频');

      expect(_uploads(h.transport), isEmpty);
      expect(find.textContaining('无法读取相册视频'), findsOneWidget);
    });

    testWidgets('★ 用户取消（回 null）⇒ 零请求、零报错', (tester) async {
      ImagePickerPlatform.instance = _FakePickerPlatform(result: null);
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await _openAttachAndTap(tester, '相册视频');

      expect(_uploads(h.transport), isEmpty);
      // 不该弹任何错误提示
      expect(find.textContaining('失败'), findsNothing);
      expect(find.textContaining('无法'), findsNothing);
    });
  });

  group('VP-3. §5.1：只读', () {
    test('★ 本文件所有请求都不含变更动词', () async {
      final fake = _FakePickerPlatform(result: '/tmp/x.mp4');
      ImagePickerPlatform.instance = fake;
      final h = await bootChat();
      // 只驱动 provider 本身，不点 UI
      await h.container.read(chatVideoPickerProvider)(ImageSource.gallery);
      const mutating = {
        'create',
        'delete',
        'update',
        'set',
        'add',
        'remove',
        'upload',
        'cancel',
        'rename',
        'move',
        'copy',
        'clear',
        'stop',
        'start',
      };
      for (final c in h.transport.calls) {
        expect(
          mutating,
          isNot(contains('${c['method']}')),
          reason: '出现了变更动词 ${c['method']}',
        );
      }
    });
  });
}
