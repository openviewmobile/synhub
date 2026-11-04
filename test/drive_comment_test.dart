// P39（相册评论）/ D45（Drive 评论 · 活动流）—— **➖ 非缺口** 的文字化登记。
//
// ## 为什么是"非缺口"而不是"没做"
// 这两行的结论是**服务端没有这套 API**，硬写实现只能编。证据分三层：
//
// 1. **活体只读探测**（本次任务当场重跑，`/tmp/live_probe_lib.py` +
//    `/tmp/live_session.json`，只发 `SYNO.API.Info/query`：
//    `query=all` 回 **1047** 个 API）：
//    * `SYNO.Foto.*` 共 **73** 个，**没有任何 `Foto.Comment` / `Foto.Rating`**
//      （评分不是独立 API，是 `Browse.Item/set` 的 `rating` 参数，见 P40）；
//    * `SYNO.SynologyDrive.*` 中 **没有 `Comment` / `Activity`**；
//      与"活动"沾边的只有 `SynologyDrive.Log`（审计日志）与
//      `SynologyDrive.Notifications`（通知）—— 官方 Drive **Android** 只用了后者
//      （`/tmp/drive_app_apis.txt` 里 `SynologyDrive.Log` **0 命中**）。
// 2. **官方 Photos APK 2.4.0-644**（jadx）：`ApiComment` / `ApiActivity` 这类
//    Retrofit 接口**不存在**；`ui/comment` 包不存在；`activity_comment` /
//    `fragment_comment` 只有资源条目，`AlbumContentActivity` 里那个
//    `R.id.action_comment` 菜单项**没有任何点击处理**（`hasUnreadComment` 甚至
//    是构造时直接置 true 的假状态）。⇒ 连官方 App 都没在 Foto API 上做评论。
// 3. **权威方法表**（`docs/api-server-authoritative.md` §4 Foto 73 表 / §5 Drive
//    55 表，SPK `.lib` 导出）：Foto/FotoTeam 全表无 `Comment`；Drive 无 `Comment`
//    —— 与 1、2 完全一致。
//
// 本文件把"服务端确实没有"钉成可回归的断言：能力表 fixture 里不允许出现
// 评论/活动相关的 API 名。哪天 Synology 真的加了 `SYNO.Foto.Comment`，这条用例
// 会先红，逼着重新取证，而不是让"非缺口"的结论悄悄过期。
//
// 参考：`docs/gap-backlog-actionable.md`（P39 / D45 行）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _guessedCommentApis = [
  // 任务书里点名"自己查证、不要照抄"的那些候选名，逐个钉死在"不存在"。
  'SYNO.Foto.Comment',
  'SYNO.Foto.Rating',
  'SYNO.FotoTeam.Comment',
  'SYNO.FotoTeam.Rating',
  'SYNO.SynologyDrive.Comment',
  'SYNO.SynologyDrive.Activity',
];

void main() {
  late Map<String, dynamic> table;

  setUpAll(() {
    final f = File('test/fixtures/api_table.json');
    expect(f.existsSync(), isTrue, reason: '能力表 fixture 必须存在');
    table = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  });

  group('P39 相册评论 = ➖ 非缺口（服务端无 Foto.Comment）', () {
    test('能力表里有 73 个 Foto API，但一个评论 API 都没有', () {
      final foto = table.keys.where((k) => k.startsWith('SYNO.Foto')).toList();
      expect(foto.length, 73);
      expect(
        foto.where((k) => k.contains('Comment') || k.contains('comment')),
        isEmpty,
      );
    });

    test('任务书里的候选名逐个不存在', () {
      for (final name in _guessedCommentApis) {
        expect(table.containsKey(name), isFalse, reason: '$name 不该存在');
      }
    });

    test('不存在"评论"相关的 Foto 子模块（Foto.Sharing.* 里也没有）', () {
      final sharing = table.keys.where(
        (k) =>
            k.startsWith('SYNO.Foto.Sharing') ||
            k.startsWith('SYNO.FotoTeam.Sharing'),
      );
      expect(sharing, isNotEmpty);
      expect(
        sharing.where((k) => k.toLowerCase().contains('comment')),
        isEmpty,
      );
    });
  });

  group('D45 Drive 评论 = ➖ 非缺口（服务端无 Drive.Comment）', () {
    test('SynologyDrive 家族里没有任何 Comment API', () {
      final drive = table.keys.where((k) => k.startsWith('SYNO.SynologyDrive'));
      expect(drive, isNotEmpty);
      expect(drive.where((k) => k.toLowerCase().contains('comment')), isEmpty);
    });
  });

  group('D45 Drive 活动流 = 已由通知中心覆盖（无独立活动流 API）', () {
    test('不存在 SynologyDrive.Activity；也没有 Foto.Activity', () {
      expect(table.containsKey('SYNO.SynologyDrive.Activity'), isFalse);
      expect(table.containsKey('SYNO.Foto.Activity'), isFalse);
      expect(
        table.keys.where(
          (k) =>
              (k.startsWith('SYNO.SynologyDrive') ||
                  k.startsWith('SYNO.Foto')) &&
              k.toLowerCase().contains('activity'),
        ),
        isEmpty,
      );
    });

    test('官方 Drive App 的"活动"通道 = 通知中心（Notifications）', () {
      // 已在 `lib/src/data/drive_api.dart` 实现（listNotifications / clearNotifications）
      // 与 `lib/src/features/drive/drive_notifications_page.dart` 呈现。
      expect(table.containsKey('SYNO.SynologyDrive.Notifications'), isTrue);
      expect(
        table.containsKey('SYNO.SynologyDrive.Mobile.Notification'),
        isTrue,
      );
    });

    test('SynologyDrive.Log 存在，但它是审计日志（v1: delete/export/list），'
        '官方 Drive APK 0 命中 → 不当作"活动流"缺口实现', () {
      expect(table.containsKey('SYNO.SynologyDrive.Log'), isTrue);
      final log = table['SYNO.SynologyDrive.Log'] as Map<String, dynamic>;
      expect(log['maxVersion'], 1);
      // 官方 Drive APK 的能力表里没有它（`/tmp/drive_app_apis.txt`），
      // 所以本批次**不为它造 UI**；如未来产品要"操作日志"，那是新需求。
    });
  });
}
