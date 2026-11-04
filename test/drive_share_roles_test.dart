// ★★ **③Drive 第 62 轮：D41「权限角色细分 / 禁下载」重新裁决**
//
// ## D41 缺口原文
// > `D41 / :376 | 权限角色细分 | previewer/commenter/organizer/禁下载 | 🟠部分 |
// >  实现：`data/drive_api.dart` 共享 role 仅基础档 |
// >  缺口：预览者/组织者/禁下载配不出`
//
// ## 取证结论：**三条逐一裁定**
//
// ### ① 角色细分 —— **早已不是缺口**（判定口径纠正）
// 官方「**成员共享**」权限选择器恰好 **6 个**
// （`AddSharingAccountPermissionFragment:383-399`）：
//
// | Android id | `SharingPermissionType` | role 串 |
// |---|---|---|
// | `permission_can_view` | Viewer | `viewer` |
// | `permission_can_preview` | Previewer | `previewer` |
// | `permission_can_preview_comment` | PreviewCommenter | `preview_commenter` |
// | `permission_can_comment` | Commenter | `commenter` |
// | `permission_can_edit` | Editor | `editor` |
// | `permission_can_manage` | Organizer | `organizer` |
//
// 我方 `DriveShareRole` **就是这 6 个**，且成员共享 UI
// （`features/files/drive_share_page.dart:556`
//  `for (final r in DriveShareRole.values)`）**全部列出** ⇒ 已对齐。
//
// 而**公开链接**界面官方只有 **3 个**（`public_link_can_view` /
// `_can_comment` / `_can_edit`），我方高级共享页也是 3 个 ⇒ 也对齐。
//
// ### ② 禁下载 —— **不是客户端能力**（➖ 非缺口）
// `disable_download` 只出现在**响应** VO 里
// （`FileInfoVo.disable_download` / `TeamFolderVo.disable_download`），
// **官方客户端从不 `putParam` 它** —— 它是服务端按团队文件夹策略
// **算出来**的标志。⇒ 官方 App 也"配不出"，不是我们漏做。
//
// ### ③ `Sharing/get_base_url`（v2）—— 服务端有，**官方安卓端不用**
// 服务端 `.lib`：`SYNO.SynologyDrive.Sharing` `maxVersion: 2`，
// v2 方法 = v1 的 5 个 + **`get_base_url`**。
// 但该串**在 APK 全树与 SPK 前端 JS 里都搜不到** ⇒ 官方安卓端未使用。
//
// 全程内存 Mock，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/drive_share_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  group('DR41-1. ★★★ 角色细分：我方 6 个 = 官方成员共享选择器的 6 个', () {
    test('★★★ `DriveShareRole` 的值集合与官方 `SharingPermissionType` 一一对应', () {
      // 官方 `ApiSynoDriveSharing.java:40-45` 的六个 ROLE__ 常量
      const official = {
        'viewer', // permission_can_view
        'previewer', // permission_can_preview
        'preview_commenter', // permission_can_preview_comment
        'commenter', // permission_can_comment
        'editor', // permission_can_edit
        'organizer', // permission_can_manage
      };
      final ours = {for (final r in DriveShareRole.values) r.value};
      expect(
        ours,
        official,
        reason:
            '★★★ 少一个 = 官方能配我们配不出（D41 的原缺口）；'
            '多一个 = 服务端不认（会被降级成默认权限，**不报错**）',
      );
      expect(ours.length, 6, reason: '★ 官方选择器就是 6 个单选');
    });

    test('★★ 每个角色都有中/英标签（UI 才显示得出，不会露 key）', () {
      for (final r in DriveShareRole.values) {
        expect(r.label, isNotEmpty, reason: '${r.value} 缺中文回落');
        expect(r.labelKey, isNotEmpty, reason: '${r.value} 缺 ARB key');
      }
    });
  });

  group('DR41-2. ★★★ 禁下载：不是客户端能设的（反证）', () {
    test('★★★ `Sharing/update` 的载荷里**不得**出现 `disable_download`', () async {
      final backend = MockDsmBackend(catalog: DsmCatalog.load());
      backend.login(username: 'demo_user', admin: false);
      final web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      await web.login(account: 'demo_user', password: 'x');

      final payload = const DriveShareChange.invite(
        name: 'alice',
        type: 'user',
        role: DriveShareRole.previewer,
      ).toJson();
      expect(
        payload.containsKey('disable_download'),
        isFalse,
        reason:
            '★★★ 官方 `ApiSynoDriveSharing` **从不** putParam 这个字段 ——'
            ' 它是服务端按团队文件夹策略算出来的**响应**标志'
            '（`FileInfoVo.disable_download`）。'
            '若我们自作聪明去发它，服务端会**忽略**（不报错），'
            '用户以为设上了、其实没设 —— 这正是最坏的一种"假成功"',
      );
      expect(payload.containsKey('role'), isTrue, reason: '角色才是客户端能设的');
    });

    test('★★ 载荷形状与官方 `convertPermissionActions` 一致', () {
      final update = const DriveShareChange.invite(
        name: 'alice',
        type: 'user',
        role: DriveShareRole.organizer,
      ).toJson();
      expect(update['action'], 'update'); // 官方 PERMISSION_ACTION__UPDATE
      expect(update['role'], 'organizer');
      expect(update['member'], {'type': 'user', 'name': 'alice'});

      final remove = const DriveShareChange.remove(
        name: 'alice',
        type: 'user',
      ).toJson();
      expect(remove['action'], 'delete'); // 官方 PERMISSION_ACTION__DELETE
      expect(
        remove.containsKey('role'),
        isFalse,
        reason: '★ 移除成员不带 role（官方 convertPermissionActions 同理）',
      );
    });
  });

  group('DR41-3. ★ `Sharing` 版本：v1 的 5 个方法可用，官方安卓端不用 v2', () {
    test('★★ v1 五个方法都在（官方 APK 明确的 `list`/`update`/`create_link` 等）', () {
      final cat = DsmCatalog.load();
      final spec = cat['SYNO.SynologyDrive.Sharing'];
      expect(spec, isNotNull);
      expect(
        spec!.methods[1],
        containsAll(<String>[
          'list',
          'update',
          'create_link',
          'use_link',
          'sync_to_device',
        ]),
        reason: '★ `.lib` 逐版本方法表是权威',
      );
      expect(spec.minVersion, 1);
    });

    test('★★ v2 **只多一个** `get_base_url`（记录在案，非安卓端缺口）', () {
      final spec = DsmCatalog.load()['SYNO.SynologyDrive.Sharing']!;
      expect(spec.maxVersion, 2, reason: '★ 服务端确实有 v2 —— 我方只谈 v1 是有意的');
      final v2Only = spec.methods[2]!.toSet().difference(
        spec.methods[1]!.toSet(),
      );
      expect(
        v2Only,
        {'get_base_url'},
        reason:
            '★★ v2 只比 v1 多这一个。它在 **APK 全树与 SPK 前端 JS 里都搜不到**'
            '（官方安卓端未使用）⇒ 不构成安卓对齐缺口，但在此留痕，'
            '将来做 Web/桌面端对齐时要用',
      );
      // 我方与该 API 实际交互只用 v1
      expect(
        spec.methods[1],
        contains('list'),
        reason: '★ 我方 `listShares` 走的是 v1',
      );
    });
  });
}
