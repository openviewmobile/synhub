import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/features/chat/channel_row.dart';

Map<String, dynamic> j(int id, String name, String type, {int unread = 0, int mention = 0}) => {
  'channel_id': id, 'name': name, 'type': type, 'is_joined': true,
  'unread': unread, 'mention': mention, 'last_post_at': 1700000000000,
  'total_member_count': 3,
};

void main() {
  testWidgets('probe', (tester) async {
    final cases = [
      j(1, 'My Space', 'synobot'),
      j(2, '公共频道', 'public'),
      j(3, '私有频道', 'private', unread: 4),
      j(4, '匿名会话', 'anonymous'),
      j(5, '带提及', 'public', unread: 2, mention: 1),
      j(6, '无名字', '', unread: 0),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: ListView(children: [
        for (final c in cases)
          ChannelRow(channel: ChannelDto.fromJson(c), users: const <int, UserDto>{}, myUserId: 1, onTap: () {}),
      ])),
    ));
    await tester.pump();
    for (var i = 0; i < cases.length; i++) {
      final s = tester.getSize(find.byType(ChannelRow).at(i));
      debugPrint('ROW ${cases[i]['name']} type=${cases[i]['type']} size=${s.width}x${s.height}');
    }
  });
}
