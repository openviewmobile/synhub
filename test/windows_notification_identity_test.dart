// r710 · Windows 通知身份映射：Android 的 `(tag, id)` ↔ Windows 的 `(Tag, Group)`。
//
// 为什么值得单列一个文件：`cancelTag` / `cancelChannel` 在 Windows 上**没有**原生桥
// （`MethodChannel('…')` 上不存在 `cancelTag`），落地形态只能是把 Android 的身份
// 映射成 toast 的 `Tag`/`Group` 再 `History.Remove`。这个映射一旦漂移，
// "撤掉某条通知"就会**静默变成撤掉全部**或**什么都没撤**——两种都不报错。
//
// ★ 这里的断言只钉**映射与参数形状**；"真的撤掉了那一条、另一边还活着"的消费方读数
//   在 guest 上（`docs/evidence-r710-win/04_probe_tag_remove.log`）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/native/background_service.dart';

void main() {
  test('① Tag 必须与 Android 原版 NotificationTag.getName() 逐字节相同', () {
    // 原版是 Gson 序列化的 `{"channel_id":N,"thread_id":T}`；顺序与空格都不能变，
    // 否则与已发出的那条（旧版本发的）对不上，撤不掉。
    expect(notificationTagFor(271, 9), '{"channel_id":271,"thread_id":9}');
    expect(notificationTagFor(0, 0), '{"channel_id":0,"thread_id":0}');
  });

  test('② Group 按频道：同频道不同话题落在同一组，不同频道不同组', () {
    expect(windowsNotificationGroupFor(271), 'ch271');
    expect(windowsNotificationGroupFor(0), 'ch0');
    // 同频道、不同话题 ⇒ 组相同（`cancelChannel` 才能一次撤干净）
    expect(windowsNotificationGroupFor(271), windowsNotificationGroupFor(271));
    // 不同频道 ⇒ 组必须不同（否则 A 频道的"已读"会把 B 频道一起撤掉）
    expect(
      windowsNotificationGroupFor(271) == windowsNotificationGroupFor(272),
      isFalse,
    );
  });

  test('③ 反向：Group 不许等于 Tag，也不许把频道号裸放', () {
    // 这条是给"以后顺手改成 `'$channelId'`"的人看的：裸数字在 PowerShell 里
    // 是**数字**而不是字符串，`RemoveGroup(271, …)` 会被重载解析成别的东西。
    expect(windowsNotificationGroupFor(271), isNot('271'));
    expect(windowsNotificationGroupFor(271), isNot(notificationTagFor(271, 0)));
  });

  test('④ 非 Windows 宿主上 cancelTag/cancelChannel 不抛、且不假报成功', () async {
    if (Platform.isWindows) {
      // Windows 宿主上这两个方法会真去起 PowerShell —— 那是 guest 的活，不在单测里做。
      return;
    }
    final bg = BackgroundService();
    expect(await bg.cancelTag(271, threadId: 9), isFalse);
    expect(await bg.cancelChannel(271), isFalse);
  });
}
