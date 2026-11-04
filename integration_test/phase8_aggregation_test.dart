// Phase 8/9 真机验收：通知聚合（同一 (频道, 话题) 只挂一条 + InboxStyle 明细 + 摘要）。
//
//   flutter test integration_test/phase8_aggregation_test.dart -d AXGE022428000622
//
// 这里走**真实原生层**（NotificationManager 真的挂了通知），并用测试专用的
// `notificationTags` 通道读回系统里的通知，验证：
//   ① 同频道 3 条消息 → 只挂 1 条消息通知 + 1 条群摘要；
//   ② 那条通知的 InboxStyle 明细就是这 3 条（旧→新），标题是「3 条新消息 | 频道名」；
//   ③ 不同话题各自一条；
//   ④ `cancelChannel` 撤掉该频道全部话题 + 摘要（"已读"走的就是这条路）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/features/notifications/notification_service.dart';
import 'package:synhub/src/native/background_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 8 真机：通知按 (频道,话题) 聚合 + InboxStyle 明细', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final bg = container.read(backgroundServiceProvider);
    await bg.cancelAll();
    // API 33+ 才有运行时权限；这里先要一下（真机 API 31 直接返回 true）
    debugPrint('[p8a] 通知权限=${await bg.requestNotificationPermission()}');

    final tag = notificationTagFor(5, 0);
    final id = notificationIdFor(5, 0);

    // ---------- ① 同频道 3 条 ----------
    for (var i = 1; i <= 3; i++) {
      await bg.show(MessageNotification(
        channelId: 5,
        postId: 1000 + i,
        title: i == 1 ? '张三 · flt-p8' : '$i 条新消息 | flt-p8',
        text: '消息$i',
        lines: List.generate(i, (k) => '消息${k + 1}'),
      ));
      // 让 NotificationManager 落盘（每次都有间隔）
      await tester.pump(const Duration(milliseconds: 120));
    }
    final active = await bg.activeTags();
    debugPrint('[p8a] 挂着的通知：'
        '${active.map((a) => '${a.tag}#${a.id}(${a.lines.length}行)').join(', ')}');

    final mine = active.where((a) => a.tag == tag).toList();
    expect(mine, hasLength(1), reason: '同频道同话题必须只挂一条');
    expect(mine.single.id, id);
    expect(mine.single.title, '3 条新消息 | flt-p8');
    expect(mine.single.lines, ['消息1', '消息2', '消息3'],
        reason: 'InboxStyle 明细（旧→新）');

    final summary = active.where((a) => a.tag == 'synhub_summary').toList();
    expect(summary, hasLength(1), reason: '群摘要');
    expect(summary.single.id, 536870912);
    // 群摘要标题 = **本 App 自己的应用名**，由原生 `context.getString(R.string.app_name)`
    // 决定（`ChatNotifications.kt:305`；`values/strings.xml` = SynHub / `values-zh` = 星枢）。
    // 原来写死官方 App 名 'Synology Chat' —— 那是原版的标签，不是这个产品该显示的。
    // `platformAppName()` 就是原生资源同一套映射（en→SynHub，其余→星枢）。
    // ⚠️ 已知边界：zh-Hant（values-zh-rHK/rTW = 「星樞」）与 Dart 的「星枢」差一个字形，
    //    本机系统语言是英文（实测回 SynHub），故相等。
    expect(summary.single.title, platformAppName(),
        reason: '群摘要标题应是本 App 的应用名（跟系统语言）');
    debugPrint('[p8a] 群摘要：${summary.single.title} / ${summary.single.lines}');

    // ---------- ② 另一个话题 → 独立一条 ----------
    await bg.show(const MessageNotification(
      channelId: 5,
      postId: 2001,
      threadId: 7,
      title: '话题 · flt-p8',
      text: '话题里的消息',
      lines: ['话题里的消息'],
    ));
    await tester.pump(const Duration(milliseconds: 120));
    final two = await bg.activeTags();
    final mine2 = two.where((a) => a.tag == notificationTagFor(5, 7)).toList();
    expect(mine2, hasLength(1));
    expect(two.where((a) => a.tag == tag), hasLength(1), reason: '原来那条还在');
    debugPrint('[p8a] 不同话题各自一条 ✓（共 ${two.length} 条通知）');

    // ---------- ③ 已读 → 撤掉该频道所有话题 + 摘要 ----------
    await bg.cancelChannel(5);
    await tester.pump(const Duration(milliseconds: 150));
    final after = await bg.activeTags();
    expect(after.where((a) => a.tag == tag), isEmpty);
    expect(after.where((a) => a.tag == notificationTagFor(5, 7)), isEmpty);
    expect(after.where((a) => a.tag == 'synhub_summary'), isEmpty,
        reason: '全撤干净后不留空群头');
    debugPrint('[p8a] cancelChannel(5) → 消息与摘要全撤 ✓');

    // 收尾
    await bg.cancelAll();
    debugPrint('[p8a] 清理完成 ✓');
  });
}
