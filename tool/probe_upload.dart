// Phase 5 真机探针：上传一个文件 → 看服务端怎么回、列表里 `file_props` 长什么样、
// 下载回来的字节是否一致。跑完自己清理。
//
//   dart run -DSYNO_NAS_URL=… -DSYNO_NAS_ACCOUNT=… \
//            -DSYNO_NAS_PASSWORD=… tool/probe_upload.dart
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
  print('sid=${sess.sid.substring(0, 6)}…');

  // 造一个 1x1 PNG（真图片，能验证缩略图分支）
  final dir = Directory.systemTemp.createTempSync('p5');
  final png = File('${dir.path}/flt-probe-image.png')
    ..writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/AF+'
        'bT4AAAAASUVORK5CYII=',
      ),
    );
  final txt = File('${dir.path}/flt-probe-note.txt')
    ..writeAsStringSync('hello phase5 ${DateTime.now()}');

  final created = <int>[];
  try {
    for (final f in [png, txt]) {
      final raw = await chat.uploadPost(
        channelId: 1,
        connId: sess.sid,
        filePath: f.path,
        fileName: f.uri.pathSegments.last,
        message: 'flt-probe-upload ${f.uri.pathSegments.last}',
        mimeType: f.path.endsWith('.png') ? 'image/png' : 'text/plain',
        onProgress: (sent, total) => print('  进度 $sent/$total'),
      );
      print('上传 ${f.uri.pathSegments.last} → ${jsonEncode(raw)}');
      created.add((raw['post_id'] as num).toInt());
    }

    // 列表里看 file_props
    final posts = await chat.listPosts(
      channelId: 1,
      prevCount: 10,
      nextCount: 0,
      has: const ['thread'],
    );
    for (final p in posts) {
      final id = (p['post_id'] as num).toInt();
      if (created.contains(id)) {
        print(
          '列表项 $id: type=${p['type']} file_props=${jsonEncode(p['file_props'])}',
        );
      }
    }

    // 下载校验
    final pid = created[1];
    final bytes = await chat.downloadPostFile(pid);
    final text = utf8.decode(bytes);
    print('下载 $pid → ${bytes.length} 字节: $text');
    print('和原文件一致: ${text == txt.readAsStringSync()}');

    // 缩略图分支（图片消息）
    try {
      final thumb = await chat.downloadPostFile(
        created[0],
        thumbnail: true,
        size: ChatApi.thumbLarge,
      );
      print('缩略图 ${created[0]} → ${thumb.length} 字节');
    } catch (e) {
      print('缩略图失败: $e');
    }
    print('URL 样例: ${chat.fileUrl(pid)}');
  } finally {
    for (final id in created) {
      try {
        await chat.deletePost(id);
      } catch (_) {}
    }
    print('已清理 ${created.length} 条');
    dir.deleteSync(recursive: true);
  }
}
