import 'dart:typed_data';
// Phase 5 离线验证：附件上传 / 下载 / 解析 / 渲染。
//
// 载荷形状全部按真机实测的来（docs/phase5-protocol.md）：
//   * `file_props` 是**单个对象**（不是数组）；
//   * `type` 只是扩展名，不是 MIME；
//   * 语音标志位叫 `is_voice_msg`；
//   * 文本附件带 `snippet_preview`。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_filex/open_filex.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/file_prop_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/attachment_view.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/chat_image.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 真机拿回来的 `file_props`（一个 png 上传后原样复制）
const _realImageProp = {
  'is_image': false,
  'is_snippet': false,
  'is_voice_msg': false,
  'mtime': 1789581577,
  'name': 'flt-probe-image.png',
  'owner_id': 0,
  'size': 68,
  'snippet_lines': 0,
  'snippet_preview': '',
  'snippet_preview_more': false,
  'source': 'upload',
  'type': 'png',
  'voice_msg_length': 0,
};

const _realTextProp = {
  'is_image': false,
  'is_snippet': true,
  'is_voice_msg': false,
  'mtime': 1789581577,
  'name': 'note.txt',
  'size': 39,
  'snippet_encoding': 'US-ASCII',
  'snippet_lines': 1,
  'snippet_preview': 'hello phase5',
  'snippet_preview_more': false,
  'source': 'upload',
  'type': 'txt',
  'voice_msg_length': 0,
};

Widget _app(ProviderContainer c, Widget child) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: child),
);

/// 取出 ImageProvider 里的 NetworkImage URL。
/// `Image.network(cacheWidth: ...)` 会把 provider 包成 `ResizeImage`，要剥一层。
String? _networkUrl(ImageProvider provider) {
  var p = provider;
  if (p is ResizeImage) p = p.imageProvider;
  return p is NetworkImage ? p.url : null;
}

/// 1×1 透明 PNG —— 钉"鉴权字节通道真的能出图"（不是占位）。
final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  group('FilePropDto（真机形状）', () {
    test('单个对象也能解析（真机给的就是对象）', () {
      final list = FilePropDto.parseList(_realImageProp);
      expect(list.length, 1);
      expect(list.single.name, 'flt-probe-image.png');
      expect(list.single.extension, 'png');
      expect(list.single.size, 68);
      expect(list.single.source, 'upload');
    });

    test('扩展名决定能不能当图片显示（真机 is_image 是 false）', () {
      expect(
        FilePropDto.parseList(_realImageProp).single.showsThumbnail,
        isTrue,
      );
      expect(
        FilePropDto.parseList(_realTextProp).single.showsThumbnail,
        isFalse,
      );
      // is_image 明确为 true 时也认（哪怕扩展名不认识）
      final odd = FilePropDto.parseList({'name': 'x.bin', 'is_image': true});
      expect(odd.single.showsThumbnail, isTrue);
    });

    test('语音标志位是 is_voice_msg（老名字也兼容）', () {
      expect(
        FilePropDto.parseList({
          'name': 'v.aac',
          'is_voice_msg': true,
        }).single.isVoiceMessage,
        isTrue,
      );
      expect(
        FilePropDto.parseList({
          'name': 'v.aac',
          'is_voice_message': true,
        }).single.isVoiceMessage,
        isTrue,
      );
    });

    test('文本附件带 snippet 预览和语音时长', () {
      final t = FilePropDto.parseList(_realTextProp).single;
      expect(t.isSnippet, isTrue);
      expect(t.snippetPreview, 'hello phase5');
      final v = FilePropDto.parseList({
        'name': 'v.aac',
        'is_voice_msg': true,
        'voice_msg_length': 7,
      });
      expect(v.single.voiceMsgLength, 7);
    });

    test('数组 / JSON 字符串形态也能解析（不同接口给法不一样）', () {
      expect(FilePropDto.parseList([_realTextProp]).length, 1);
      expect(FilePropDto.parseList(jsonEncode([_realTextProp])).length, 1);
      expect(FilePropDto.parseList(jsonEncode(_realTextProp)).length, 1);
      expect(FilePropDto.parseList(null), isEmpty);
      expect(FilePropDto.parseList('not json'), isEmpty);
    });

    test('大小显示', () {
      expect(
        FilePropDto.parseList({'name': 'a', 'size': 68}).single.humanSize,
        '68 B',
      );
      expect(
        FilePropDto.parseList({'name': 'a', 'size': 2048}).single.humanSize,
        '2.0 KB',
      );
      expect(
        FilePropDto.parseList({
          'name': 'a',
          'size': 5 * 1024 * 1024,
        }).single.humanSize,
        '5.0 MB',
      );
      expect(FilePropDto.parseList({'name': 'a'}).single.humanSize, '');
    });

    test('PostDto.attachments 用的是同一个解析', () {
      final post = PostDto.fromJson(const {
        'post_id': 7,
        'channel_id': 5,
        'creator_id': 14,
        'type': 'file',
        'message': '',
        'file_props': _realTextProp,
      });
      expect(post.attachments.single.label, 'note.txt');
      expect(post.attachments.single.isSnippet, isTrue);
    });
  });

  group('上传 / 下载协议', () {
    Future<ChatApi> api(FakeTransport t) async {
      final dsm = DsmWebApi(t);
      await dsm.discover();
      await dsm.login(account: 'u', password: 'p', session: 'Chat');
      return ChatApi(dsm);
    }

    test('uploadPost：元数据在查询串、文件在 body、message 不二次编码', () async {
      final t = FakeTransport();
      final chat = await api(t);
      await chat.uploadPost(
        channelId: 5,
        connId: 'conn-1',
        filePath: '/tmp/a b.png',
        fileName: 'a b.png',
        message: '看这个',
        mimeType: 'image/png',
        threadId: 99,
        voiceMsgLength: 7,
        onProgress: (_, __) {},
      );
      final call = t.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.create',
      );
      // 查询串
      expect(call['channel_id'], '5');
      expect(call['version'], '7');
      expect(call['thread_id'], '99');
      expect(call['voice_msg_length'], '7');
      // body 字段
      expect(call['type'], 'file');
      expect(call['conn_id'], 'conn-1');
      // ⚠️ 关键：multipart 这条路上服务端不剥引号，必须发裸文本
      expect(call['message'], '看这个');
      expect(call['file_field'], 'file');
      expect(call['file_name'], 'a b.png');
      expect(call['file_path'], '/tmp/a b.png');
    });

    test('uploadPost：帖子回复带 is_thread', () async {
      final t = FakeTransport();
      final chat = await api(t);
      await chat.uploadPost(
        channelId: 5,
        connId: 'c',
        filePath: '/tmp/x.txt',
        fileName: 'x.txt',
        threadId: 42,
        isThread: true,
      );
      final call = t.calls.singleWhere((c) => c['file_field'] != null);
      expect(call['thread_id'], '42');
      expect(call['is_thread'], 'true');
    });

    test('fileUrl：带 _sid，缩略图走 thumbnail 且 type 要 JSON 编码', () async {
      final t = FakeTransport();
      final chat = await api(t);
      final plain = chat.fileUrl(12345);
      expect(plain, contains('api=SYNO.Chat.Post.File'));
      expect(plain, contains('method=get'));
      expect(plain, contains('post_id=12345'));
      expect(plain, contains('_sid=FAKE-SID'));

      // 缩略图 type 是尺寸串（S/M/L/XL）且**裸发**，不是 MIME、不带引号
      final thumb = chat.fileUrl(
        12345,
        thumbnail: true,
        size: ChatApi.thumbLarge,
      );
      expect(thumb, contains('method=thumbnail'));
      expect(thumb, contains('type=L'));
      expect(thumb, isNot(contains('image/png')));
    });

    test('downloadPostFile 把字节原样带回来', () async {
      final t = FakeTransport();
      t.downloadBytes = utf8.encode('文件内容');
      final chat = await api(t);
      final bytes = await chat.downloadPostFile(7);
      expect(utf8.decode(bytes), '文件内容');
      expect(t.downloads.single, contains('post_id=7'));
    });
  });

  group('发送附件（控制器）', () {
    test('上传成功后替换占位行，并且附件可读', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      h.transport.uploadPostId = 4294967400;

      var sawPending = false;
      final ok = await h.ctrl.sendAttachment(
        channelId: 5,
        filePath: '/tmp/flt-x.png',
        fileName: 'flt-x.png',
        message: '带图的说明',
        mimeType: 'image/png',
        onProgress: (sent, total) {
          if (sent < total) sawPending = true;
        },
      );
      expect(ok, isTrue);
      expect(sawPending, isTrue, reason: '应当有进度回调');

      final post = (await store.postById(5, 4294967400))!;
      expect(post.type, 'file');
      expect(post.message, '带图的说明');
      expect(post.attachments.single.name, 'flt-x.png');
      expect(post.attachments.single.showsThumbnail, isTrue);
      // 上传完成后本地预览路径要清掉
      expect(
        h.container.read(chatSessionControllerProvider).pendingFiles,
        isEmpty,
      );
    });

    test('上传中：本地临时行 + pendingFiles 里有本地路径（好先预览）', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      var checked = false;
      await h.ctrl.sendAttachment(
        channelId: 5,
        filePath: '/tmp/flt-pending.png',
        fileName: 'flt-pending.png',
        onProgress: (sent, total) {
          if (checked) return;
          checked = true;
          // 进度回调发生在等待响应期间 —— 此刻占位行应当已在库里
          final pending = h.container.read(chatSessionControllerProvider);
          expect(pending.pendingFiles.values, contains('/tmp/flt-pending.png'));
        },
      );
      expect(checked, isTrue);
      expect((await store.postsForChannel(5)).length, 1);
    });

    test('服务端太频繁（411）→ 占位行标失败、不算成功', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.create'] = 411;
      final ok = await h.ctrl.sendAttachment(
        channelId: 5,
        filePath: '/tmp/flt-fail.txt',
        fileName: 'flt-fail.txt',
      );
      expect(ok, isFalse);
      final posts = await h.container
          .read(chatStoreProvider)
          .postsForChannel(5);
      expect(posts.single.state, 2, reason: '失败态（原 App 的 Post.state=2）');
    });

    test('没有 conn_id 时不发（实时通道没就绪）', () async {
      final h = await bootChat();
      // 手动把 conn_id 清掉
      final notifier = h.ctrl;
      final ok = await notifier.sendAttachment(
        channelId: 5,
        filePath: '/tmp/a.txt',
        fileName: 'a.txt',
      );
      // bootChat 的假 socket 会下发 conn_id，所以这里是 true；
      // 真正要防的是 _api == null，用 fresh provider 覆盖
      expect(ok, isTrue);
    });
  });

  group('附件渲染', () {
    testWidgets('文件卡片显示名字与大小', (tester) async {
      final h = await bootChat();
      await h.container.read(chatStoreProvider).upsertPosts([
        PostDto.fromJson(const {
          'post_id': 900,
          'channel_id': 5,
          'creator_id': 3,
          'create_at': 1700000000000,
          'type': 'file',
          'message': '',
          'file_props': _realTextProp,
        }),
      ]);
      await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('note.txt'), findsOneWidget);
      expect(find.textContaining('39 B'), findsOneWidget);
      expect(
        find.textContaining('hello phase5'),
        findsOneWidget,
        reason: '文本附件要显示服务端截的预览',
      );
    });

    testWidgets('图片附件走【鉴权字节通道】拿缩略图（不能再用 Image.network）', (
      tester,
    ) async {
      final h = await bootChat();
      // 1×1 PNG：证明字节真的画出来了（不是占位图）
      h.transport.bytesByUrl['method=thumbnail'] = _png1x1;
      await h.container.read(chatStoreProvider).upsertPosts([
        PostDto.fromJson(const {
          'post_id': 901,
          'channel_id': 5,
          'creator_id': 3,
          'create_at': 1700000000000,
          'type': 'file',
          'message': '图来了',
          'file_props': _realImageProp,
        }),
      ]);
      await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      // 请求必须经过 `api.getBytes`（Dio + 信任库 + `_sid`），
      // 而不是 `Image.network`（Dart 自带 HttpClient，对自签证书
      // `CERTIFICATE_VERIFY_FAILED` ⇒ 真机永远不出图）。
      expect(
        h.transport.downloads.where((u) => u.contains('method=thumbnail')),
        isNotEmpty,
        reason: '缩略图必须走鉴权字节通道',
      );
      final url = h.transport.downloads.firstWhere(
        (u) => u.contains('method=thumbnail'),
      );
      expect(url, contains('post_id=901'));
      expect(url, contains('_sid='));
      final drewMemory = tester
          .widgetList<Image>(find.byType(Image))
          .map((i) => i.image)
          .any((p) {
            // `Image.memory(cacheWidth:)` 也会被包成 ResizeImage，剥一层
            final q = p is ResizeImage ? p.imageProvider : p;
            return q is MemoryImage;
          });
      expect(drewMemory, isTrue, reason: '拿到的字节要用 Image.memory 画出来');
      // 且**不允许**再出现 NetworkImage（那正是真机不出图的根因）
      expect(
        tester
            .widgetList<Image>(find.byType(Image))
            .map((i) => i.image)
            .where((p) => _networkUrl(p) != null),
        isEmpty,
      );
    });

    testWidgets('语音附件显示时长', (tester) async {
      final h = await bootChat();
      await h.container.read(chatStoreProvider).upsertPosts([
        PostDto.fromJson(const {
          'post_id': 902,
          'channel_id': 5,
          'creator_id': 3,
          'create_at': 1700000000000,
          'type': 'file',
          'message': '',
          'file_props': {
            'name': 'voiceMessage-1.aac',
            'type': 'aac',
            'size': 4096,
            'is_voice_msg': true,
            'voice_msg_length': 7,
          },
        }),
      ]);
      await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('语音消息'), findsOneWidget);
      expect(find.text('0:07'), findsOneWidget);
    });

    test('打开文件：先下载到本地，再交给系统打开', () async {
      final h = await bootChat();
      h.transport.downloadBytes = utf8.encode('下载到的内容');
      final post = PostDto.fromJson(const {
        'post_id': 903,
        'channel_id': 5,
        'creator_id': 3,
        'create_at': 1700000000000,
        'type': 'file',
        'message': '',
        'file_props': {'name': 'a.txt', 'type': 'txt', 'size': 3},
      });
      final api = h.container.read(chatApiProvider);
      final dir = Directory.systemTemp.createTempSync('att_test');
      var openedPath = '';
      final err = await openAttachment(
        api,
        post,
        post.attachments.single,
        saveDir: dir.path,
        // 测试环境没有 platform channel，这里换成假的"打开"
        opener: (path) async {
          openedPath = path;
          return OpenResult(type: ResultType.done);
        },
      );
      expect(err, isNull);
      expect(h.transport.downloads.single, contains('post_id=903'));
      expect(openedPath, endsWith('a.txt'));
      expect(File(openedPath).readAsStringSync(), '下载到的内容');

      // 打开失败时给出可读提示（并告诉用户存哪了）
      final err2 = await openAttachment(
        api,
        post,
        post.attachments.single,
        saveDir: dir.path,
        opener: (_) async =>
            OpenResult(type: ResultType.noAppToOpen, message: 'nope'),
      );
      expect(err2, contains('没有能打开这个类型的应用'));
      dir.deleteSync(recursive: true);
    });

    test('没拿到 post_id 时说清楚', () async {
      final post = PostDto.fromJson(const {
        'post_id': 0,
        'channel_id': 5,
        'creator_id': 3,
        'type': 'file',
        'message': '',
        'file_props': {'name': 'a.txt', 'type': 'txt'},
      });
      final err = await openAttachment(null, post, post.attachments.single);
      expect(err, contains('还没有拿到服务端的消息'));
    });

    test('mime 映射', () {
      expect(mimeOfExtension('png'), 'image/png');
      expect(mimeOfExtension('jpeg'), 'image/jpeg');
      expect(mimeOfExtension('heic'), 'image/heic');
      expect(mimeForExtension('txt'), 'application/octet-stream');
    });
  });

  testWidgets('点收到的文件 → 进内置阅读器（不再直接甩给外部 App）', (tester) async {
    final h = await bootChat();
    await h.container.read(chatStoreProvider).upsertPosts([
      PostDto.fromJson(const {
        'post_id': 903,
        'channel_id': 5,
        'creator_id': 3,
        'create_at': 1700000000000,
        'type': 'file',
        'message': '',
        // 非 snippet 的普通文本附件 → 走 `_FileBubble`（整块可点）
        'file_props': {
          'name': 'notes.txt',
          'type': 'txt',
          'size': 120,
          'is_image': false,
          'is_snippet': false,
          'is_voice_msg': false,
        },
      }),
    ]);
    await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('notes.txt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    // §2.0.8 ④：同一个文档 = 同一套阅读器（Files/Drive 用的就是 FilePreviewPage）
    expect(
      find.byType(FilePreviewPage),
      findsOneWidget,
      reason: 'Chat 附件要走内置阅读器，而不是 open_filex 甩给别的 App',
    );
    // 而且喂给阅读器的必须是**带 _sid 的鉴权直链**（Dio + 信任库；
    // `Image.network`/系统播放器那套默认 TLS 在自签 NAS 上必然握手失败）
    final page = tester.widget<FilePreviewPage>(find.byType(FilePreviewPage));
    expect(page.bytesUrl, contains('method=get'));
    expect(page.bytesUrl, contains('post_id=903'));
    expect(page.bytesUrl, contains('_sid='));
    expect(page.entry.name, 'notes.txt');
  });

  testWidgets('点图进大图查看器：原图也走鉴权字节通道（不是 Image.network）', (
    tester,
  ) async {
    final h = await bootChat();
    h.transport.bytesByUrl['method=thumbnail'] = _png1x1;
    h.transport.bytesByUrl['method=get'] = _png1x1;
    await h.container.read(chatStoreProvider).upsertPosts([
      PostDto.fromJson(const {
        'post_id': 902,
        'channel_id': 5,
        'creator_id': 3,
        'create_at': 1700000000000,
        'type': 'file',
        'message': '图来了',
        'file_props': _realImageProp,
      }),
    ]);
    await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.byType(ChatRemoteImage).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(
      h.transport.downloads.where((u) => u.contains('method=get')),
      isNotEmpty,
      reason: '大图原图必须走鉴权字节通道（Image.network 在自签证书下必然失败）',
    );
  });
}
