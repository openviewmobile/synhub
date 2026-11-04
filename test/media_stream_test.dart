// Phase 5：音频/视频附件的**外部串流**（对齐原版 `VideoUtil` + `FileUtil`）。
//
// 原版语义：
//   * `FileUtil.isStreaming(name)`：MIME 含 audio/video 或 rm/rmvb 结尾；
//   * 直链 = `getStreamingUrlOfPostId` = `webapi/{Post.File.path}` +
//     `api=SYNO.Chat.Post.File&method=get&version=1&post_id=X&_sid=…`；
//   * `Intent(ACTION_VIEW).setDataAndType(uri, mime)`（**必须带 type**）；
//   * 没应用能处理 → `showMimeTypeDialog`（打开方式）；
//   * 加密频道 / 证书不受信任 / 缓存里已有整份 → **不串流，改为下载**
//     （前两者各带一次性确认框，偏好键 `video_encrypted` /
//     `video_illegal_certificate`）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/media/cache_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/dto/file_prop_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/attachment_view.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/media_stream.dart';
import 'package:open_filex/open_filex.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';
import 'support/pump_until.dart';

PostDto postWith(
  int postId,
  Map<String, dynamic> fileProp, {
  int channelId = 5,
}) => PostDto.fromJson({
  'post_id': postId,
  'channel_id': channelId,
  'creator_id': 14,
  'create_at': 1700000000000,
  'file_props': [fileProp],
});

Map<String, dynamic> fileJson(
  String name, {
  bool image = false,
  int size = 1024,
}) => {
  'file_id': 1,
  'post_id': 1,
  'name': name,
  'type': fileExtensionOf(name),
  'size': size,
  'mime_type': mimeForFileName(name),
  'is_image': image,
};

void main() {
  group('扩展名 / MIME / isStreaming', () {
    test('视频与音频都算"可串流"（原版 isStreaming 的原样语义）', () {
      for (final n in [
        'a.mp4',
        'a.m4v',
        'b.mov',
        'c.avi',
        'd.mkv',
        'e.webm',
        'f.3gp',
        'g.mpg',
        'h.mpeg',
        'i.ts',
        'a.mp3',
        'b.m4a',
        'c.wav',
        'd.aac',
        'e.ogg',
        'f.flac',
        'g.amr',
        'old.rm',
        'old.rmvb',
      ]) {
        expect(isStreamingFile(n), isTrue, reason: n);
      }
    });

    test('大小写不敏感（原版 toLowerCase）', () {
      expect(isStreamingFile('VIDEO.MP4'), isTrue);
      expect(isStreamingFile('song.MP3'), isTrue);
      expect(isStreamingFile('movie.RMVB'), isTrue);
    });

    test('文档 / 图片 / 压缩包 / 无扩展名 不是流媒体', () {
      for (final n in [
        'a.pdf',
        'a.jpg',
        'a.png',
        'a.zip',
        'a.txt',
        'a.apk',
        'noext',
        '.hidden',
        'a.rmx',
      ]) {
        expect(isStreamingFile(n), isFalse, reason: n);
      }
    });

    test('MIME 取值与兜底', () {
      expect(mimeForFileName('a.mp4'), 'video/mp4');
      expect(mimeForFileName('a.MOV'), 'video/quicktime');
      expect(mimeForFileName('a.flac'), 'audio/flac');
      expect(mimeForFileName('a.pdf'), 'application/pdf');
      expect(mimeForFileName('a.unknownext'), 'application/octet-stream');
      expect(mimeOrNullForFileName('a.unknownext'), isNull);
      expect(fileExtensionOf('x/y/a.b.MP4'), 'mp4');
      expect(fileExtensionOf('noext'), '');
    });
  });

  group('openAttachment 的串流分支', () {
    test('视频 → 打开带 _sid 的直链 + video/mp4，且不下载文件', () async {
      final h = await bootChat();
      final calls = <(String, String)>[];
      final err = await openAttachment(
        h.apiForTest,
        postWith(42, fileJson('clip.mp4')),
        FilePropDto.fromJson(fileJson('clip.mp4')),
        allowStreaming: true,
        streamOpener: (url, mime) async {
          calls.add((url, mime));
          return true;
        },
      );
      expect(err, isNull);
      expect(calls, hasLength(1));
      expect(calls.single.$1, contains('post_id=42'));
      expect(calls.single.$1, contains('method=get'));
      expect(calls.single.$1, contains('api=SYNO.Chat.Post.File'));
      expect(calls.single.$1, contains('_sid='));
      expect(calls.single.$2, 'video/mp4');
      // 没有走字节下载（串流不该整份拉下来）
      expect(h.transport.downloads, isEmpty);
    });

    test('没有应用能处理 → 返回哨兵，不偷偷下载', () async {
      final h = await bootChat();
      final err = await openAttachment(
        h.apiForTest,
        postWith(43, fileJson('clip.mkv')),
        FilePropDto.fromJson(fileJson('clip.mkv')),
        allowStreaming: true,
        streamOpener: (_, __) async => false,
      );
      expect(err, kNoStreamHandler);
      expect(h.transport.downloads, isEmpty);
    });

    test('普通文件（pdf）不走串流，仍旧下载后打开', () async {
      final h = await bootChat();
      var streamed = 0;
      final dir = Directory.systemTemp.createTempSync('flt_stream_test');
      final err = await openAttachment(
        h.apiForTest,
        postWith(44, fileJson('report.pdf')),
        FilePropDto.fromJson(fileJson('report.pdf')),
        allowStreaming: true,
        saveDir: dir.path,
        streamOpener: (_, __) async {
          streamed++;
          return true;
        },
        opener: (path) async {
          expect(File(path).existsSync(), isTrue);
          return OpenResult(type: ResultType.done);
        },
      );
      expect(streamed, 0, reason: 'pdf 不该被当成流媒体');
      expect(err, isNull);
      expect(h.transport.downloads, hasLength(1));
    });

    test('allowStreaming=false（加密频道/证书不受信任）时一律下载', () async {
      final h = await bootChat();
      var streamed = 0;
      final dir = Directory.systemTemp.createTempSync('flt_stream_test2');
      final err = await openAttachment(
        h.apiForTest,
        postWith(45, fileJson('clip.mp4')),
        FilePropDto.fromJson(fileJson('clip.mp4')),
        allowStreaming: false,
        saveDir: dir.path,
        streamOpener: (_, __) async {
          streamed++;
          return true;
        },
        opener: (path) async => OpenResult(type: ResultType.done),
      );
      expect(streamed, 0);
      expect(err, isNull);
      expect(h.transport.downloads, hasLength(1));
    });
  });

  group('界面接线', () {
    /// 点一下附件并等真实异步（缓存查询/文件 IO 需要 runAsync）
    Future<void> tapFile(
      WidgetTester tester,
      ProviderContainer c, {
      required String name,
    }) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: AttachmentList(
                post: postWith(100, fileJson(name)),
                api: c.read(chatApiProvider),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text(name));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('视频附件点击 → 直接串流，不下载', (tester) async {
      final calls = <(String, String)>[];
      final dir = Directory.systemTemp.createTempSync('flt_stream_ui0');
      final h = await bootChat(
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(CacheService(root: dir)),
          mediaStreamOpenerProvider.overrideWithValue((url, mime) async {
            calls.add((url, mime));
            return true;
          }),
        ],
      );
      await tapFile(tester, h.container, name: 'clip.mp4');
      // ★ r447：真实异步（缓存查询/文件 IO/读设置）要**等到条件成立**，
      // 不许"先睡 150ms 再断言"（全量并发下会看到"还没发生"）。
      await pumpUntil(tester, () => calls.isNotEmpty);
      expect(calls, hasLength(1));
      expect(calls.single.$2, 'video/mp4');
      expect(calls.single.$1, contains('post_id=100'));
      expect(calls.single.$1, contains('_sid='));
      expect(h.transport.downloads, isEmpty);
    });

    testWidgets('没有应用能处理 → 弹"打开方式"，选完带该 MIME 再试', (tester) async {
      final calls = <(String, String)>[];
      var fail = true;
      final dir = Directory.systemTemp.createTempSync('flt_stream_ui1');
      final h = await bootChat(
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(CacheService(root: dir)),
          mediaStreamOpenerProvider.overrideWithValue((url, mime) async {
            calls.add((url, mime));
            return !fail;
          }),
        ],
      );
      await tapFile(tester, h.container, name: 'clip.mkv');
      await pumpUntilFound(tester, find.text('打开方式'));
      expect(find.text('打开方式'), findsOneWidget);
      fail = false;
      await tester.runAsync(() async {
        await tester.tap(find.text('视频'));
      });
      await tester.pump();
      await pumpUntil(tester, () => calls.length >= 2);
      expect(calls, hasLength(2));
      expect(calls.last.$2, 'video/*');
    });

    testWidgets('证书不受信任：先弹确认框，确认后改为下载', (tester) async {
      final calls = <(String, String)>[];
      final dir = Directory.systemTemp.createTempSync('flt_stream_ui2');
      final h = await bootChat(
        certPinned: true,
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(CacheService(root: dir)),
          mediaStreamOpenerProvider.overrideWithValue((url, mime) async {
            calls.add((url, mime));
            return true;
          }),
        ],
      );
      expect(
        h.container.read(chatSessionControllerProvider).certUntrusted,
        isTrue,
      );
      await tapFile(tester, h.container, name: 'clip.mp4');
      await pumpUntilFound(tester, find.text('服务器证书不受信任'));
      expect(find.text('服务器证书不受信任'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('确定'));
      });
      await tester.pump();
      await pumpUntil(tester, () => h.transport.downloads.isNotEmpty);
      expect(calls, isEmpty, reason: '不受信任的证书不该串流');
      expect(h.transport.downloads, hasLength(1));
    });

    testWidgets('"不再提示"写进 video_illegal_certificate，下次直接下载', (tester) async {
      final calls = <(String, String)>[];
      final dir = Directory.systemTemp.createTempSync('flt_stream_ui3');
      final h = await bootChat(
        certPinned: true,
        moreOverrides: [
          cacheServiceProvider.overrideWithValue(CacheService(root: dir)),
          mediaStreamOpenerProvider.overrideWithValue((url, mime) async {
            calls.add((url, mime));
            return true;
          }),
        ],
      );
      await tapFile(tester, h.container, name: 'clip.mp4');
      await pumpUntilFound(tester, find.text('不再提示'));
      await tester.runAsync(() async {
        await tester.tap(find.text('不再提示'));
      });
      await tester.pump();
      // 勾必须**真的**置上（否则后面的"写进偏好"就没意义了）
      await pumpUntil(
        tester,
        () => find.byType(Checkbox).evaluate().isNotEmpty &&
            tester.widget<Checkbox>(find.byType(Checkbox)).value == true,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('确定'));
      });
      await tester.pump();

      final settings = h.container.read(settingsServiceProvider);
      await pumpUntilAsync(tester, () => settings.streamingIllegalCertificate());
      expect(await settings.streamingIllegalCertificate(), isTrue);
      expect(calls, isEmpty);
    });
  });
}
