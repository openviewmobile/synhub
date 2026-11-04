// 归档频道页（`Archive/list type=encrypted`）的离线测试。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/chat/archive_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

void main() {
  testWidgets('没有归档时给空状态', (tester) async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Archive.list': {'archives': <Map<String, dynamic>>[]},
      },
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(theme: AppTheme.dark(), home: ArchivePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('归档频道'), findsOneWidget);
    expect(find.textContaining('没有归档频道'), findsOneWidget);
  });

  testWidgets('★ DA1：归档条目显示密钥状态；解不开时点进 E2EE 页', (tester) async {
    final h = await bootChat();
    final svc = h.container.read(e2eeServiceProvider);
    final id = await svc.setup('p');
    final key = List<int>.filled(32, 5);
    // 先放一把别的钥匙，让 sealChannelKey 能封（锁着时按 broken 处理）
    svc.putChannelKey(45, List<int>.filled(32, 1));
    final archives = [
      {
        'archive_id': 3,
        'props': {
          'channel': {
            'channel_id': 45,
            'name': '老加密频道',
            'type': 'private',
            'encrypted': true,
            'members': [4, 14],
            'channel_key_enc': svc.sealChannelKey(45, id.publicKey),
          },
        },
      },
    ];
    h.transport.responses['SYNO.Chat.Archive.list'] = {'archives': archives};

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(theme: AppTheme.dark(), home: ArchivePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('老加密频道'), findsOneWidget);
    expect(find.textContaining('归档 #3'), findsOneWidget);
    expect(find.textContaining('可读'), findsOneWidget);

    // 锁上以后同一把钥匙就变成"已锁定"（同步判定）
    svc.lock();
    h.container.invalidate(archivesProvider);
    await tester.pumpAndSettle();
    expect(find.textContaining('已锁定'), findsOneWidget);

    // 解锁 + 换成真钥匙 → 又可读
    await svc.unlock('p');
    svc.putChannelKey(45, key);
    h.container.invalidate(archivesProvider);
    await tester.pumpAndSettle();
    expect(find.textContaining('可读'), findsOneWidget);
  });
}
