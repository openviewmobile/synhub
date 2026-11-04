// Phase 7：加密频道的附件（文件名 hex + 内容 secretbox）。
//
// 覆盖上传/下载两条路，都用 App 自己的代码：
//   * 上传：multipart 里发出去的必须是 hex 文件名 + 密文字节，服务端存不到明文；
//   * 下载：`AttachmentAccess.bytes` 整份下载后解密回原字节。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/attachment_view.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/settings/e2ee_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

const _encryptedChannelJson = {
  'channel_id': 5,
  'name': '加密频道',
  'type': 'private',
  'is_joined': true,
  'encrypted': true,
  'channel_key_enc': 'SEALED',
  'last_post_at': 1000,
};

final _plain = Uint8List.fromList(List<int>.generate(2048, (i) => i % 251));

void main() {
  test('加密频道上传附件：服务端拿到的是 hex 名字 + 密文内容', () async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Channel.list': {
          'channels': [_encryptedChannelJson],
        },
      },
    );
    final svc = h.container.read(e2eeServiceProvider);
    await h.container.read(e2eeControllerProvider.notifier).setup('p');
    svc.putChannelKey(5, List.filled(32, 7));

    // 明文附件落到临时文件
    final dir = await Directory.systemTemp.createTemp('e2ee_up');
    final src = File('${dir.path}/报表.xlsx')..writeAsBytesSync(_plain);

    h.transport.responses['SYNO.Chat.Post.create'] = {
      'post': {
        'post_id': 4294967500,
        'channel_id': 5,
        'creator_id': 14,
        'create_at': 4000,
        'type': 'file',
        'message': 'CIPHERTEXT',
        'props': {'encrypted': true},
      },
    };
    expect(
      await h.ctrl.sendAttachment(
        channelId: 5,
        filePath: src.path,
        fileName: '报表.xlsx',
        message: '这是字幕',
        mimeType: 'application/vnd.ms-excel',
      ),
      isTrue,
    );

    final call = h.transport.calls.lastWhere((c) => c['method'] == 'create');
    // 文件名必须是 hex（解出来才是原名）
    final wireName = call['file_name'] as String;
    expect(wireName, isNot('报表.xlsx'));
    expect(svc.tryDecryptFileName(5, wireName), '报表.xlsx');
    // 字幕也要加密
    expect(svc.tryDecryptMessage(5, call['message'] as String), '这是字幕');
    // 上传那一刻的字节是密文（临时文件发完就删了，所以看 fake 记下来的快照）
    final uploaded = call['file_bytes'] as List<int>;
    expect(uploaded, isNot(_plain));
    expect(svc.tryDecryptFileBytes(5, uploaded), orderedEquals(_plain));

    // 本地那条留明文
    final store = h.container.read(chatStoreProvider);
    final local = (await store.postsForChannel(
      5,
      limit: 5,
    )).firstWhere((p) => p.postId == 4294967500);
    expect(local.message, '这是字幕');
    expect(local.encrypted, isTrue);
  });

  test('加密频道下载附件：整份下载后解密回原字节', () async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Channel.list': {
          'channels': [_encryptedChannelJson],
        },
      },
    );
    final svc = h.container.read(e2eeServiceProvider);
    await h.container.read(e2eeControllerProvider.notifier).setup('p');
    svc.putChannelKey(5, List.filled(32, 8));

    final channel = ChannelDto.fromJson(_encryptedChannelJson);
    final access = h.ctrl.attachmentAccessFor(channel);
    expect(access, isNotNull);
    expect(access!.decodeName(svc.encryptFileName(5, '图.png')), '图.png');

    h.transport.downloadBytes = svc.encryptFileBytes(5, _plain);
    expect(await access.bytes(4294967500), orderedEquals(_plain));
  });

  test('file_props 是数组时附件不能丢（服务端多附件就是这个形状）', () async {
    final post = PostDto.fromJson({
      'post_id': 1,
      'channel_id': 5,
      'file_props': [
        {'name': 'a.png', 'type': 'png', 'size': 10},
        {'name': 'b.pdf', 'type': 'pdf', 'size': 20},
      ],
    });
    expect(post.attachments.length, 2);
    expect(post.attachments.first.label, 'a.png');

    // 字符串包一层也要能解
    final wrapped = PostDto.fromJson({
      'post_id': 2,
      'channel_id': 5,
      'file_props': '[{"name":"c.txt","type":"txt","size":1}]',
    });
    expect(wrapped.attachments.single.label, 'c.txt');

    // 本地库来回一趟还在
    final h = await bootChat();
    final store = h.container.read(chatStoreProvider);
    await store.upsertPosts([post]);
    final back = (await store.postsForChannel(
      5,
      limit: 5,
    )).firstWhere((p) => p.postId == 1);
    expect(back.attachments.length, 2);
    expect(back.attachments.last.label, 'b.pdf');
  });

  test('普通频道没有附件访问器（继续走 URL）', () async {
    final h = await bootChat();
    expect(
      h.ctrl.attachmentAccessFor(ChannelDto.fromJson(testChannelJson)),
      isNull,
    );
  });

  testWidgets('加密频道的文件卡片显示解出来的真名', (tester) async {
    final h = await bootChat();
    final svc = h.container.read(e2eeServiceProvider);
    await h.container.read(e2eeControllerProvider.notifier).setup('p');
    svc.putChannelKey(5, List.filled(32, 9));
    final access = h.ctrl.attachmentAccessFor(
      ChannelDto.fromJson(_encryptedChannelJson),
    )!;

    final post = PostDto.fromJson({
      'post_id': 4294967600,
      'channel_id': 5,
      'creator_id': 14,
      'create_at': 5000,
      'type': 'file',
      'message': '',
      'file_props': [
        {
          'name': svc.encryptFileName(5, '季度报表.xlsx'),
          'type': 'xlsx',
          'size': 2048,
        },
      ],
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: AttachmentList(
              post: post,
              access: access,
              api: h.container.read(chatApiProvider),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('季度报表.xlsx'), findsOneWidget);
    expect(post.attachments.first.label, isNot('季度报表.xlsx'));
  });
}
