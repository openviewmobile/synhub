// ★★ ③Drive 第 211 轮 **D45「评论 / 活动流」** 的客户端半边。
//
// D45 的结论（已有回归用例 `test/drive_comment_test.dart` 钉住）：
//   * 服务端**没有** `SYNO.SynologyDrive.Comment` / `Activity`
//     （活体 `API.Info` 1047 个 API、官方 Photos APK、权威 `.lib` 三处一致）；
//   * 官方 **Drive Android 客户端也没有评论编辑器/活动流页**。
// ⇒ 作为"独立功能"是非缺口（➖）。
//
// 但评论**确实会到客户端**：以**通知**形式。官方 `NotificationVo$Type` 枚举里有
// `drive#comment` / `drive#comment_reply` / `drive#mention`，
// `NotificationVo$ContentVo` 的字段里有 `comment`（getter `getComment()`），
// `NotificationAdapter$ItemViewHolder` 读 `Notification.getComment()` 显示。
// 本文件钉的就是这条**唯一的官方评论通道**：类型标签 + 评论文本必须显示出来，
// 而不是把裸的 `drive#comment` 串丢给用户。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/drive_notification_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/features/drive/drive_notifications_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Notifications': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

DriveNotificationDto _dto(String type, Map<String, Object?> content) =>
    DriveNotificationDto.fromJson({
      'notification_id': 'n-$type',
      'type': type,
      'time': 1789775507,
      'content': content,
    });

void main() {
  group('D45 · DTO：官方 11 种通知类型', () {
    test('类型标签逐个对齐官方 `NotificationVo$Type` 枚举', () {
      // 官方枚举值（`NotificationVo$Type.smali` 的 `value = "drive#…"`）。
      const expected = {
        'drive#background_task': '后台任务',
        'drive#comment': '评论',
        'drive#comment_reply': '评论回复',
        'drive#mention': '@提到',
        'drive#share_with_me': '分享给我',
        'drive#shared_label': '共享标签',
        'drive#shared_label_owner_transfer': '标签所有者转移',
        'drive#request': '访问请求',
        'drive#request_unlock': '解锁请求',
        'drive#request_office_template': 'Office 模板请求',
      };
      for (final e in expected.entries) {
        expect(_dto(e.key, const {}).typeLabel, e.value, reason: e.key);
      }
      // `drive#upload_task` 保留历史的 'upload'（既有用例与页面依赖它）
      expect(_dto('drive#upload_task', const {}).typeLabel, 'upload');
      // 不认识的类型**原样显示**（官方也是直接显示 type 串，不硬猜）
      expect(_dto('drive#brand_new_thing', const {}).typeLabel,
          'drive#brand_new_thing');
    });

    test('评论文本来自 `content.comment`（官方 ContentVo.comment）', () {
      final dto = _dto('drive#comment', const {
        'comment': '这句话得改改',
        'name': 'a.docx',
        'fileId': '42',
      });
      expect(dto.commentText, '这句话得改改');
      expect(dto.fileName, 'a.docx');
      expect(dto.contentMap['fileId'], '42');

      // 没有评论字段（上传任务）⇒ 空串，不许编
      expect(_dto('drive#upload_task', const {'action': 'upload'}).commentText,
          isEmpty);
      // content 根本不是 map（老服务端可能回字符串）⇒ 也不能炸
      final str = DriveNotificationDto.fromJson(const {
        'notification_id': 'x',
        'type': 'drive#share_with_me',
        'content': 'plain text',
      });
      expect(str.commentText, isEmpty);
      expect(str.fileName, isEmpty);
      expect(str.names, isEmpty);
    });
  });

  group('D45 · 通知页渲染', () {
    Future<FakeTransport> pump(
      WidgetTester tester,
      List<Map<String, dynamic>> items,
    ) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        if ('${params['method']}' == 'list') {
          return {'items': items, 'total': items.length};
        }
        return {'success': true};
      };
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c = ProviderContainer(
        overrides: [driveApiProvider.overrideWithValue(DriveApi(api))],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: DriveNotificationsPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return t;
    }

    testWidgets('评论通知要显示**评论文本**，不是裸的 drive#comment', (tester) async {
      await pump(tester, [
        {
          'notification_id': 'c1',
          'type': 'drive#comment',
          'time': 1789775507,
          'content': {'comment': '这个数字不对', 'name': 'a.docx'},
        },
        {
          'notification_id': 'm1',
          'type': 'drive#mention',
          'time': 1789775508,
          'content': {'comment': '帮我看一眼', 'name': 'b.osheet'},
        },
        {
          'notification_id': 'r1',
          'type': 'drive#comment_reply',
          'time': 1789775509,
          'content': {'comment': '已经改好了', 'name': 'a.docx'},
        },
      ]);
      expect(find.textContaining('这个数字不对'), findsOneWidget);
      expect(find.textContaining('帮我看一眼'), findsOneWidget);
      expect(find.textContaining('已经改好了'), findsOneWidget);
      // 类型标签 + 文件名都要在
      expect(find.textContaining('评论 · a.docx'), findsOneWidget);
      expect(find.textContaining('@提到 · b.osheet'), findsOneWidget);
      expect(find.text('drive#comment'), findsNothing);
    });

    testWidgets('只有文件名的通知（分享/请求）也要带类型标签，不显示裸串', (tester) async {
      await pump(tester, [
        {
          'notification_id': 's1',
          'type': 'drive#share_with_me',
          'time': 1789775510,
          'content': {'name': 'c.pdf'},
        },
        {
          'notification_id': 'q1',
          'type': 'drive#request',
          'time': 1789775511,
          'content': {'name': 'd.txt'},
        },
      ]);
      expect(find.textContaining('分享给我 · c.pdf'), findsOneWidget);
      expect(find.textContaining('访问请求 · d.txt'), findsOneWidget);
      expect(find.text('drive#share_with_me'), findsNothing);
      expect(find.text('drive#request'), findsNothing);
    });
  });
}
