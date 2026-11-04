// Phase 5 媒体页（图片墙 / 文件列表）离线验证。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/file_prop_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/channel_media_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

PostDto _post(int id, Map<String, dynamic> prop, {String message = ''}) =>
    PostDto.fromJson({
      'post_id': id,
      'channel_id': 5,
      'creator_id': 3,
      'create_at': 1700000000000,
      'type': 'file',
      'message': message,
      'file_props': prop,
    });

const _imgProp = {
  'name': 'flt-pic.png',
  'type': 'png',
  'size': 4000,
  'is_image': true,
  'image': {'width': 64, 'height': 64},
};
const _txtProp = {'name': 'note.txt', 'type': 'txt', 'size': 20};
const _mp4Prop = {'name': 'clip.mp4', 'type': 'mp4', 'size': 900000};
const _mp3Prop = {'name': 'song.mp3', 'type': 'mp3', 'size': 8000};

/// 合法 1x1 PNG（缩略图桩必须喂真图片，否则 IMAGE RESOURCE SERVICE 会上报
/// `Invalid image data`，且错误异步泄漏到下一个用例的 zone）。
const List<int> _png1x1 = <int>[
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 218, 99, 252, 207, 192, 80, 15, 0, 4, 133, 1, 128, 132, 169, 140, 33, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

void main() {
  group('tab 归类', () {
    test('图片/视频/音频走服务端分类，文件要本地筛', () {
      expect(mediaQueryFor(MediaTab.image).fileTypes, [kMediaImage]);
      expect(mediaQueryFor(MediaTab.video).fileTypes, [kMediaVideo]);
      expect(mediaQueryFor(MediaTab.audio).fileTypes, [kMediaAudio]);
      // 真机实测 file/document/other 都不是有效分类
      expect(mediaQueryFor(MediaTab.file).fileTypes, isEmpty);
      expect(mediaQueryFor(MediaTab.file).clientFilter, isNotNull);
      expect(mediaQueryFor(MediaTab.file).fileTypes, isNot(contains('file')));
    });

    test('isGenericFile 只挑既不是图也不是音视频的', () {
      FilePropDto prop(Map<String, dynamic> j) =>
          FilePropDto.parseList(j).single;
      expect(isGenericFile(prop(_txtProp)), isTrue);
      expect(isGenericFile(prop({'name': 'a.pdf', 'type': 'pdf'})), isTrue);
      expect(isGenericFile(prop(_imgProp)), isFalse);
      expect(isGenericFile(prop(_mp4Prop)), isFalse);
      expect(isGenericFile(prop(_mp3Prop)), isFalse);
    });

    test('matchesTab 按各自规则挑消息', () {
      final img = _post(1, _imgProp);
      final txt = _post(2, _txtProp);
      final mp4 = _post(3, _mp4Prop);
      final mp3 = _post(4, _mp3Prop);
      final q = mediaQueryFor;
      expect(matchesTab(q(MediaTab.image), img), isTrue);
      expect(matchesTab(q(MediaTab.image), txt), isFalse);
      expect(matchesTab(q(MediaTab.video), mp4), isTrue);
      expect(matchesTab(q(MediaTab.video), img), isFalse);
      expect(matchesTab(q(MediaTab.audio), mp3), isTrue);
      expect(matchesTab(q(MediaTab.file), txt), isTrue);
      expect(matchesTab(q(MediaTab.file), img), isFalse);
      expect(matchesTab(q(MediaTab.file), mp4), isFalse);
      // 没有附件的普通消息不出现在任何 tab
      final plain = PostDto.fromJson(const {
        'post_id': 9,
        'channel_id': 5,
        'creator_id': 3,
        'type': 'normal',
        'message': 'hi',
      });
      for (final t in MediaTab.values) {
        expect(matchesTab(q(t), plain), isFalse);
      }
    });
  });

  group('listPostsByType 协议', () {
    Future<ChatApi> api(FakeTransport t) async {
      final dsm = DsmWebApi(t);
      await dsm.discover();
      await dsm.login(account: 'u', password: 'p', session: 'Chat');
      return ChatApi(dsm);
    }

    test('file_type / attributes 都要 JSON 编码，版本 v3', () async {
      final t = FakeTransport();
      t.responses['SYNO.Chat.Post.list'] = {
        'posts': [
          {'post_id': 1, 'channel_id': 5, 'file_props': _imgProp},
        ],
      };
      final chat = await api(t);
      final out = await chat.listPostsByType(
        channelId: 5,
        fileTypes: const [kMediaImage],
      );
      final call = t.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.list',
      );
      expect(call['version'], '3');
      expect(call['file_type'], '["image"]');
      expect(
        call['attributes'],
        '["post_id","file_props","message","thread_id","channel_id"]',
      );
      expect(call['has'], ['thread']);
      expect(out.single['post_id'], 1);
    });

    test('不带 file_type 时（文件 tab 的前置查询）就不发这个字段', () async {
      final t = FakeTransport();
      t.responses['SYNO.Chat.Post.list'] = {'posts': []};
      final chat = await api(t);
      await chat.listPostsByType(channelId: 5);
      final call = t.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.list',
      );
      expect(call.containsKey('file_type'), isFalse);
    });

    test('翻页用 post_id 当游标', () async {
      final t = FakeTransport();
      t.responses['SYNO.Chat.Post.list'] = {'posts': []};
      final chat = await api(t);
      await chat.listPostsByType(
        channelId: 5,
        fileTypes: const [kMediaVideo],
        postId: 4294967300,
      );
      final call = t.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.list',
      );
      expect(call['post_id'], '4294967300');
      expect(call['file_type'], '["video"]');
    });
  });

  group('loadMedia（控制器）', () {
    test('把服务端结果写进本地库', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.list'] = {
        'posts': [
          {
            'post_id': 5001,
            'channel_id': 5,
            'creator_id': 3,
            'create_at': 1,
            'type': 'file',
            'file_props': _imgProp,
          },
        ],
      };
      final n = await h.ctrl.loadMedia(
        channelId: 5,
        fileTypes: const [kMediaImage],
      );
      expect(n, 1);
      final post = await h.container.read(chatStoreProvider).postById(5, 5001);
      expect(post!.attachments.single.extension, 'png');
      expect(post.attachments.single.imageWidth, 64);
      expect(post.attachments.single.imageHeight, 64);
      expect(
        h.transport.calls.any((c) => c['file_type'] == '["image"]'),
        isTrue,
      );
    });

    test('服务端报错时往上抛（媒体页要能提示 + 重试）', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.list'] = 403;
      expect(
        () => h.ctrl.loadMedia(channelId: 5, fileTypes: const [kMediaImage]),
        throwsA(isA<DsmApiException>()),
      );
    });

    test('文件 tab 不带 file_type 查询', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.list'] = {'posts': []};
      await h.ctrl.loadMedia(channelId: 5);
      final call = h.transport.calls.lastWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.list',
      );
      expect(call.containsKey('file_type'), isFalse);
    });
  });

  group('媒体页 UI', () {
    testWidgets('图片 tab 显示网格缩略图', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.list'] = {
        'posts': [
          {
            'post_id': 6001,
            'channel_id': 5,
            'creator_id': 3,
            'create_at': 1,
            'type': 'file',
            'file_props': _imgProp,
          },
        ],
      };
      // 缩略图走 `access.bytes` → `downloadPostFile`：喂合法 PNG 字节
      h.transport.bytesByUrl['post_id=6001'] = _png1x1;
      // `entry.cgi?api=…&method=download` 这类下载 URL 一律给合法图片
      h.transport.bytesByUrl['download'] = _png1x1;
      // 兜底：所有下载默认字节也都是合法图片（桩默认值原是非图片字节）
      h.transport.downloadBytes = _png1x1;
      await pumpMedia(
        tester,
        h.container,
        const ChannelMediaPage(channelId: 5),
      );
      expect(find.text('图片'), findsOneWidget);
      expect(find.text('视频'), findsOneWidget);
      expect(find.text('音频'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
      // r261 起图片墙走 `access.bytes`（内存解码）⇒ 不再限定 NetworkImage。
      // 这里量"用户看得见的行为"：封面真的渲染出来了，且走的是内存解码那条路。
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images, isNotEmpty, reason: '图片 tab 必须渲染封面');
      expect(
        images.any((i) => i.image is MemoryImage),
        isTrue,
        reason: '图片墙封面来自 access.bytes（内存解码）',
      );
    });

    testWidgets('文件 tab 显示声音/文件列表（本地筛掉图片）', (tester) async {
      final h = await bootChat();
      // 本夹具含一张图片（6003）：图片墙阶段会解码它，桩必须回真图片
      h.transport.bytesByUrl['download'] = _png1x1;
      // 兜底：所有下载默认字节也都是合法图片（桩默认值原是非图片字节）
      h.transport.downloadBytes = _png1x1;
      h.transport.responses['SYNO.Chat.Post.list'] = {
        'posts': [
          {
            'post_id': 6002,
            'channel_id': 5,
            'creator_id': 3,
            'create_at': 2,
            'type': 'file',
            'file_props': _txtProp,
          },
          {
            'post_id': 6003,
            'channel_id': 5,
            'creator_id': 3,
            'create_at': 1,
            'type': 'file',
            'file_props': _imgProp,
          },
        ],
      };
      await pumpMedia(
        tester,
        h.container,
        const ChannelMediaPage(channelId: 5),
      );
      // 切到"文件"tab
      await tester.tap(find.text('文件'));
      await tester.pumpAndSettle();

      expect(find.text('note.txt'), findsOneWidget);
      expect(find.text('flt-pic.png'), findsNothing, reason: '图片不该出现在文件 tab');
    });

    testWidgets('加载失败时给出重试按钮', (tester) async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.list'] = 403;
      await pumpMedia(
        tester,
        h.container,
        const ChannelMediaPage(channelId: 5),
      );
      expect(find.textContaining('加载失败'), findsWidgets);
      expect(find.text('重试'), findsOneWidget);
      // 重试时把错误清掉并重新请求
      final before = h.transport.calls.length;
      h.transport.failures.clear();
      h.transport.responses['SYNO.Chat.Post.list'] = {'posts': []};
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(h.transport.calls.length, greaterThan(before));
    });
  });
}

/// 建 widget 并跑完"首帧 → postFrame 拉取 → 重建"这几拍
Future<void> pumpMedia(
  WidgetTester tester,
  ProviderContainer c,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}
