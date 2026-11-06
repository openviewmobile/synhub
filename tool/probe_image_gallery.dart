// Phase 5 探针：图片墙用的 `Post/list` v3（`file_type` + `attributes`）到底怎么用、
// 哪些 `file_type` 值是服务端认的。跑完自清理。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

// ignore_for_file: avoid_print

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      const String.fromEnvironment('SYNO_NAS_URL'),
      dio: DioFactory.create(),
    ),
  );
  await api.discover();
  final sess = await api.login(
    account: const String.fromEnvironment('SYNO_NAS_ACCOUNT'),
    password: const String.fromEnvironment('SYNO_NAS_PASSWORD'),
    session: 'Chat',
  );
  final chat = ChatApi(api);
  final created = <int>[];
  final dir = Directory.systemTemp.createTempSync('p5g');
  try {
    // 真一点的图片（1x1 的空 png 服务端不认成图片，见 §image 判定）
    final png = File('${dir.path}/flt-p5g-img.png');
    final srcPng = File('/tmp/flt-real.png');
    if (srcPng.existsSync()) {
      png.writeAsBytesSync(srcPng.readAsBytesSync());
    } else {
      png.writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/AF+'
          'bT4AAAAASUVORK5CYII=',
        ),
      );
    }
    final txt = File('${dir.path}/flt-p5g-note.txt')
      ..writeAsStringSync('flt-p5g text');
    for (final f in [png, txt]) {
      final raw = await chat.uploadPost(
        channelId: 1,
        connId: sess.sid,
        filePath: f.path,
        fileName: f.uri.pathSegments.last,
      );
      created.add((raw['post_id'] as num).toInt());
      print(
        '上传 ${f.uri.pathSegments.last} → is_image='
        '${(raw['file_props'] as Map?)?['is_image']} '
        'type=${(raw['file_props'] as Map?)?['type']}',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    print('上传完成: $created');

    const attrs = '["post_id","file_props","message","thread_id","channel_id"]';
    // 基线：不带 file_type
    for (final ft in [
      null,
      '["image"]',
      '["png"]',
      '["txt"]',
      '["video"]',
      '["audio"]',
      '["document"]',
      '["file"]',
      '["other"]',
      '["image","video"]',
    ]) {
      try {
        final r = await api.call(
          'SYNO.Chat.Post',
          'list',
          preferredVersion: 3,
          params: {
            'channel_id': '1',
            'prev_count': '20',
            'next_count': '0',
            'file_type': ?ft,
            'attributes': attrs,
          },
        );
        final posts = (r['posts'] as List?) ?? const [];
        final ids = posts
            .map((p) => (p as Map)['post_id'])
            .where((id) => created.contains(id))
            .toList();
        print(
          'file_type=$ft → ${posts.length} 条，其中我上传的: $ids；'
          '首条 type=${posts.isEmpty ? '-' : (posts.first as Map)['file_props']}',
        );
      } catch (e) {
        print('file_type=$ft → ERR $e');
      }
    }

    // attributes 省略会怎样？
    try {
      final r = await api.call(
        'SYNO.Chat.Post',
        'list',
        preferredVersion: 3,
        params: {
          'channel_id': '1',
          'prev_count': '5',
          'next_count': '0',
          'file_type': '["image"]',
        },
      );
      final posts = (r['posts'] as List?) ?? const [];
      print(
        '不带 attributes → ${posts.length} 条，首条键=${posts.isEmpty ? '-' : (posts.first as Map).keys.join(",")}',
      );
    } catch (e) {
      print('不带 attributes → ERR $e');
    }
  } finally {
    for (final id in created) {
      try {
        await chat.deletePost(id);
      } catch (_) {}
    }
    dir.deleteSync(recursive: true);
    print('已清理 ${created.length} 条');
  }
}
