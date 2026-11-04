// 贴纸探针（Phase 5 补齐）：
//   1. `SYNO.Chat.Sticker / list` v1 与 v2 的原始返回结构（分类/字段名）
//   2. 贴纸图片直链 `GET {base}sc/stickers/{sticker_id}/{size}` 在带 `_sid` 时能否取到字节
//   3. 发一条 `type=sticker` 的消息，看服务端存下来的 `message` 到底是什么
//
// 用法：
//   SYNO_NAS_URL=… SYNO_NAS_ACCOUNT=… SYNO_NAS_PASSWORD=… \
//   dart run tool/flt_sticker_probe.dart [channelId]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

void main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_NAS_ACCOUNT']!,
    password: Platform.environment['SYNO_NAS_PASSWORD']!,
    session: 'Chat',
  );
  final chat = ChatApi(api);

  print('=== 1) API 表里的版本');
  for (final v in [1, 2, 3]) {
    final entry = api.apiTable?['SYNO.Chat.Sticker'];
    print(
      '  v$v ? ${entry != null && entry.maxVersion >= v} '
      '(min=${entry?.minVersion} max=${entry?.maxVersion} path=${entry?.path})',
    );
  }

  for (final ver in [1, 2]) {
    try {
      final data = await api.call(
        'SYNO.Chat.Sticker',
        'list',
        preferredVersion: ver,
        params: {},
      );
      print('=== list v$ver 顶层 keys: ${data.keys.toList()}');
      final cats = (data['categories'] as List?) ?? const [];
      print('  分类数 ${cats.length}');
      for (final c in cats.cast<Map>()) {
        final sts = (c['stickers'] as List?) ?? const [];
        print(
          '  category ${c['category_id']} name=${c['name']} '
          'is_emoji=${c['is_emoji']} count=${sts.length} '
          '其它 keys=${c.keys.where((k) => !['category_id', 'name', 'is_emoji', 'stickers'].contains(k)).toList()}',
        );
        if (c['is_emoji'] == true || sts.length <= 3) {
          print('    样例: ${jsonEncode(sts.take(3).toList())}');
        } else {
          print('    首个: ${jsonEncode(sts.first)}');
        }
      }
    } catch (e) {
      print('=== list v$ver 失败: $e');
    }
  }

  print('=== 2) 贴纸图片直链');
  final data = await api.call(
    'SYNO.Chat.Sticker',
    'list',
    preferredVersion: 1,
    params: {},
  );
  final first = ((data['categories'] as List).first as Map);
  final stickerId = ((first['stickers'] as List).first as Map)['sticker_id'];
  final stickerName = ((first['stickers'] as List).first as Map)['name'];
  print('  取第一个贴纸 id=$stickerId name=$stickerName');
  for (final size in ['1x', '2x', '4x', 'original']) {
    final url = api.authenticatedUrl('/sc/stickers/$stickerId/$size', const {});
    try {
      final bytes = await api.getBytes(url);
      print(
        '  size=$size → ${bytes.length} 字节 '
        'magic=${bytes.take(4).map((b) => b.toRadixString(16)).join(' ')}',
      );
    } catch (e) {
      print('  size=$size → 失败: $e');
    }
  }

  print('=== 2b) 不带 _sid（靠 cookie）的直链，以及出错时的正文');
  final plain =
      '${Platform.environment['SYNO_NAS_URL']}/sc/stickers/$stickerId/2x';
  print('  plain url = $plain');
  try {
    final bytes = await api.getBytes(plain);
    print(
      '  → ${bytes.length} 字节 magic=${bytes.take(4).map((b) => b.toRadixString(16)).join(' ')}',
    );
    if (bytes.length < 400) {
      print(
        '  正文: ${utf8.decode(bytes, allowMalformed: true).replaceAll('\n', ' ')}',
      );
    }
  } catch (e) {
    print('  → 失败: $e');
  }
  final withSid = await api.getBytes(
    api.authenticatedUrl('/sc/stickers/$stickerId/2x', const {}),
  );
  if (withSid.length < 400) {
    print(
      '  带 _sid 的正文: ${utf8.decode(withSid, allowMalformed: true).replaceAll('\n', ' ')}',
    );
  }

  print('=== 2c) 试试 webapi 的 file / get 方法');
  for (final method in ['file', 'get']) {
    for (final params in [
      {'sticker_id': '$stickerId', 'size': '2x'},
      {'sticker_id': '$stickerId'},
      {'sticker_name': '$stickerName', 'size': '2x'},
    ]) {
      try {
        final data = await api.call(
          'SYNO.Chat.Sticker',
          method,
          preferredVersion: 1,
          params: params,
        );
        print(
          '  $method $params → keys=${data.keys.toList().take(6)} '
          'data=${jsonEncode(data).substring(0, data.toString().length > 160 ? 160 : data.toString().length)}',
        );
      } catch (e) {
        print('  $method $params → 失败: $e');
      }
    }
  }

  print('=== 3) 发一条 type=sticker 的消息');
  final cid =
      int.tryParse(Platform.environment['FLT_CHANNEL'] ?? '') ??
      int.tryParse(Platform.environment['SYNO_CHANNEL'] ?? '') ??
      int.parse(Platform.environment['CHANNEL_ID'] ?? '1');
  print('  频道 #$cid（想换频道用 CHANNEL_ID=…）');
  try {
    final post = await chat.createPost(
      channelId: cid,
      message: ':$stickerName:',
      type: 'sticker',
      connId: '',
    );
    final map = Map<String, dynamic>.from((post['post'] ?? post) as Map);
    print(
      '  发出 post_id=${map['post_id']} type=${map['type']} '
      'message=${jsonEncode(map['message'])}',
    );
    print('  删除: ${map['post_id']}');
    await chat.deletePost((map['post_id'] as num).toInt());
    print('  已删除');
  } catch (e) {
    print('  失败: $e');
  }
}
