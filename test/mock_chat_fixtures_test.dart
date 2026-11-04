// Mock 的 **Chat 数据夹具**回归锁（第 283 轮）。
//
// 背景：Mock 此前没有任何 Chat 频道夹具 ⇒ 客户端列到空列表，UI 显示
// `No channels yet · 0 channels`，看代码像"功能没做"，其实只是 Mock 没数据。
// 本用例把"Mock 必须能列出频道"钉住，四个平台都能据此**离线**验证 Chat 列表页。
//
// 口径：夹具里的**键名**必须与仓库自己的解析器一致
// （`lib/src/data/dto/channel_dto.dart` 的 `ChannelDto.fromJson`），
// 否则"有夹具但解析成空"会再次伪装成"功能没做"。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/mock_dsm/mock_dsm_server.dart';

void main() {
  late MockDsmHttpServer mock;
  late String sid;

  setUpAll(() async {
    mock = await MockDsmHttpServer.start(port: 0);
    sid = mock.backend.login(username: 'mockuser', admin: false);
  });

  tearDownAll(() async => mock.stop());

  Future<Map<String, dynamic>> get(String api, String method) async {
    final http = HttpClient();
    final uri = Uri.parse(
      '${mock.baseUrl}webapi/entry.cgi'
      '?api=$api&method=$method&version=1&_sid=$sid',
    );
    final res = await (await http.getUrl(uri)).close();
    final body = await res.transform(utf8.decoder).join();
    http.close();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  test('① 频道列表非空，且字段能被 ChannelDto 解析器的键名读到', () async {
    final json = await get('SYNO.Chat.Channel', 'list');
    expect(json['success'], isTrue, reason: '回包：$json');
    final data = json['data'] as Map<String, dynamic>;
    final channels = data['channels'] as List<dynamic>;
    expect(channels, isNotEmpty, reason: 'Mock 必须给出频道夹具（否则 UI 又是 Empty）');
    // 逐字对齐 ChannelDto.fromJson 读的键
    for (final c in channels.cast<Map<String, dynamic>>()) {
      expect(c['channel_id'], isA<int>());
      expect(c['name'], isA<String>());
      expect(c['type'], isA<String>());
      expect(c['is_joined'], isA<bool>());
      expect(c['members'], isA<List<dynamic>>());
      expect(c['user'], isA<Map<String, dynamic>>());
    }
    // 至少一条公开 + 一条私有：UI 的两种分支都要有数据可走
    final types = channels
        .cast<Map<String, dynamic>>()
        .map((c) => c['type'])
        .toSet();
    expect(types.length, greaterThanOrEqualTo(2), reason: '类型分支覆盖不足：$types');
  });

  test('② ACL 夹具仍在（频道权限门控依赖它）', () async {
    final json = await get('SYNO.Chat.Misc', 'acl');
    expect(json['success'], isTrue, reason: '回包：$json');
    final acls = (json['data'] as Map<String, dynamic>)['acls'] as List<dynamic>;
    expect(acls.length, 14, reason: '真机是 14 条（见夹具 _source）');
  });
}
