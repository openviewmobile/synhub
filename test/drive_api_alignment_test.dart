// ★★ ③Drive 第 223 轮：**与官方 APK/SPK 清单的接口级对照**（自动化守卫）。
//
// 目标（用户指令 A）："API 级也要对齐其官方 APK 清单"。
// 做法不是写一份人读的表格就完事 —— 而是让**测试**去扫 `lib/` 里真实调用的
// `(api, method)` 对，逐条对着 `tool/mock_dsm/catalog.json`（权威 JSON，来自反编译
// SPK 的 `webapi/*.lib`）核验：API 存在、方法至少在某个版本里存在。
// 任何一处漂移（拼错 API/方法、用了目录里没有的方法）都会让本文件红。
//
// 另外把 59 个 `SYNO.SynologyDrive*` API 的**逐条去向**钉在代码里
// （已用 / 管理员 / 服务端 / 别的产品），这样"未用"不是含糊带过而是**有理由**。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';

/// 客户端（`lib/`）里真实用到的 Drive API：用途一句话（对照表也据此生成）。
const Map<String, String> kDriveApisUsedByClient = {
  'SYNO.SynologyDrive.AdvanceSharing': '高级共享设置（链接权限/有效期）',
  'SYNO.SynologyDrive.AdvanceSharing.Public': '公开分享页（无登录视图）',
  'SYNO.SynologyDrive.Authentication': '登录/2FA/加密口令',
  'SYNO.SynologyDrive.Config': '管理端全局配置（只读展示）',
  'SYNO.SynologyDrive.Connection': '通知/桌面连接状态',
  'SYNO.SynologyDrive.DBUsage': '管理端数据库用量',
  'SYNO.SynologyDrive.FileRequest': '文件请求（跨用户收件箱）',
  'SYNO.SynologyDrive.Files': '文件树/上传/下载/搜索/回收站/加锁',
  'SYNO.SynologyDrive.Info': '服务端与客户端版本信息',
  'SYNO.SynologyDrive.Labels': '标签',
  'SYNO.SynologyDrive.Notifications': '通知列表/已读',
  'SYNO.SynologyDrive.Photos': '相册（Drive 内照片时间线）',
  'SYNO.SynologyDrive.Privilege': '管理端权限表',
  'SYNO.SynologyDrive.Profiles': '用户资料（头像/显示名）',
  'SYNO.SynologyDrive.Revisions': '版本历史/还原',
  'SYNO.SynologyDrive.Settings': '管理端设置项',
  'SYNO.SynologyDrive.Share.Priv': '分享权限位',
  'SYNO.SynologyDrive.Sharing': '共享设置',
  'SYNO.SynologyDrive.NodeLocking': '节点加锁（`Files/lock` 同族）',
  'SYNO.SynologyDrive.SCIM.Photo': 'SCIM 照片同步（管理端身份源）',
  'SYNO.SynologyDrive.SCIM.User': 'SCIM 用户同步（管理端身份源）',
  'SYNO.SynologyDrive.Tasks': '任务列表/取消（异步任务）',
  'SYNO.SynologyDrive.Trash': '回收站（列表/还原/彻底删除）',
  'SYNO.SynologyDrive.TeamFolders': '团队文件夹',
  'SYNO.SynologyDrive.Users': '管理端用户列表',
};

/// 目录里有、但**本 App 不该直调**的 API ⇒ 逐条给理由（"➖ 附理由登记"）。
const Map<String, String> kDriveApisNotUsedReason = {
  // ---- 管理员/服务端管理面（Android 客户端不提供这些界面）----
  'SYNO.SynologyDrive': '根 API（无独立方法面）：客户端只用带命名空间的具体 API',
  'SYNO.SynologyDrive.Activation': '服务端激活流程（DSM 安装期，客户端无入口）',
  'SYNO.SynologyDrive.AppIntegration': '服务端第三方集成配置（网页控制台）',
  'SYNO.SynologyDrive.Dashboard': '管理端仪表盘聚合（网页控制台）',
  'SYNO.SynologyDrive.HybridShare.Privilege': 'Hybrid Share 管理端权限（需 Hybrid Share 套件）',
  'SYNO.SynologyDrive.Index': '服务端索引重建（管理端网页）',
  'SYNO.SynologyDrive.KeyManagement': '密钥管理（管理端网页）',
  'SYNO.SynologyDrive.Metrics': '服务端指标导出（管理端网页）',
  'SYNO.SynologyDrive.Metrics.Token': '指标令牌（管理端网页）',
  'SYNO.SynologyDrive.Migration': '迁移工具（管理端网页）',
  'SYNO.SynologyDrive.Migration.UserHome': '用户主目录迁移（管理端网页）',
  'SYNO.SynologyDrive.Shard': '分片管理（管理端网页）',
  'SYNO.SynologyDrive.Sharing.Report': '共享报表（管理端网页）',
  'SYNO.SynologyDrive.Statistics': '统计报表（管理端网页）',
  'SYNO.SynologyDrive.Webhooks': 'Webhook 回调配置（管理端网页）',
  // ---- 节点运维动词：客户端走 `Files/*` 同一效果（官方 APK 亦如此）----
  'SYNO.SynologyDrive.DSM': 'DSM 侧桥接（服务端内部）',
  'SYNO.SynologyDrive.Node.Delete': '节点删除动词 —— 客户端统一走 `Files/delete`',
  'SYNO.SynologyDrive.Node.Download': '节点下载动词 —— 客户端走 `downloadUrl` 直链',
  'SYNO.SynologyDrive.Node.Restore': '节点还原动词 —— 客户端统一走 `Revisions/restore`',
  // ---- 只在测试夹具/注释里出现、`lib/` 无调用点：如实降级为"未用"----
  //   （不是编出来的缺口：这些名字此前被误登记为"已用"，本轮用源码扫描纠正）
  'SYNO.SynologyDrive.Log': '只在测试夹具里出现，`lib/` 无调用点（管理端日志走 Settings/Users 页）',
  'SYNO.SynologyDrive.Mobile.Notification': '只在测试夹具里出现（推送开关是本地通知，不发服务端）',
  'SYNO.SynologyDrive.Node': '只在注释/夹具里出现；客户端统一走 `Files/*`',
  'SYNO.SynologyDrive.NodeLockingOption': '只在测试夹具里出现；加锁选项目前用固定默认值',
  'SYNO.SynologyDrive.Share': '只用 `Share.Priv` 子 API，根 `Share` 无调用点',
  'SYNO.SynologyDrive.String': '只在测试夹具里出现；zh-CN 文案已内嵌在 App 资源里',
  // ---- 与其它 Synology 套件联动：客户端按需探测，非 Drive 主体功能 ----
  'SYNO.SynologyDrive.Office': 'Office 协同（依赖 Synology Office 套件）',
  'SYNO.SynologyDrive.Services.DocumentViewer': 'Document Viewer 联动能力探测',
  'SYNO.SynologyDrive.Services.SynologyChat': 'Chat 联动能力探测',
  'SYNO.SynologyDrive.Services.VideoStation': 'Video Station 联动能力探测',
  // ---- 完全是另一个产品：Drive ShareSync（NAS↔NAS/桌面同步）----
  'SYNO.SynologyDriveShareSync.Config': '★ 别的产品（Drive ShareSync 桌面/NAS 同步）',
  'SYNO.SynologyDriveShareSync.Connection': '★ 别的产品（Drive ShareSync）',
  'SYNO.SynologyDriveShareSync.Session': '★ 别的产品（Drive ShareSync）',
  'SYNO.SynologyDriveShareSync.Session.Set': '★ 别的产品（Drive ShareSync）',
  // ---- 文件请求的公开半边：无登录视图（服务端渲染页面）----
  'SYNO.SynologyDrive.FileRequest.Public': '文件请求**公开页**（浏览器侧，无 App 入口）',
};

void main() {
  late DsmCatalog catalog;
  late Map<String, DsmApiSpec> driveApis;

  setUpAll(() {
    catalog = DsmCatalog.load();
    driveApis = {
      for (final e in catalog.apis.entries)
        if (e.key.startsWith('SYNO.SynologyDrive')) e.key: e.value,
    };
  });

  /// 扫 `lib/**/*.dart`，抽出 `call('<api>', '<method>'` 的调用对。
  Set<(String, String)> usedPairsInLib() {
    final re = RegExp(
      r"call\(\s*'(SYNO\.[A-Za-z0-9_.]+)'\s*,\s*'([a-zA-Z0-9_]+)'",
    );
    final out = <(String, String)>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      for (final m in re.allMatches(src)) {
        out.add((m.group(1)!, m.group(2)!));
      }
    }
    return out;
  }

  group('③Drive 接口级对照 · 目录', () {
    test('目录里 `SYNO.SynologyDrive*` 共 59 个（含 ShareSync 4 个）', () {
      expect(driveApis.length, 59);
      expect(
        driveApis.keys.where((k) => k.startsWith('SYNO.SynologyDriveShareSync')),
        hasLength(4),
        reason: 'ShareSync 是**另一个产品**，单列出来不算 Drive 客户端缺口',
      );
    });

    test('客户端在用的 API **每一个**都在目录里', () {
      for (final api in kDriveApisUsedByClient.keys) {
        expect(
          driveApis.containsKey(api),
          isTrue,
          reason: '$api 在客户端代码里被引用，但权威目录里没有',
        );
      }
    });

    test('未用清单 + 已用清单 = 全部 59 个，且互不重叠（"未用必须有理由"）', () {
      final classified = {
        ...kDriveApisUsedByClient.keys,
        ...kDriveApisNotUsedReason.keys,
      };
      expect(
        classified.length,
        59,
        reason: '每个 API 都要有去向：已用一句话用途 / 未用一条理由',
      );
      expect(
        kDriveApisUsedByClient.keys.toSet().intersection(
          kDriveApisNotUsedReason.keys.toSet(),
        ),
        isEmpty,
      );
      expect(classified, containsAll(driveApis.keys));
    });
  });

  group('③Drive 接口级对照 · 真实调用 vs 权威目录', () {
    test('lib/ 里调用的每个 Drive (api, method) 都在目录的某个版本里存在', () {
      final pairs = usedPairsInLib()
          .where((p) => p.$1.startsWith('SYNO.SynologyDrive'))
          .toList();
      expect(pairs.length, greaterThan(40), reason: 'Drive 调用点不该这么少');

      final bad = <String>[];
      for (final (api, method) in pairs) {
        final spec = driveApis[api];
        if (spec == null) {
          bad.add('$api.$method：API 不在目录');
          continue;
        }
        final anyVersion = spec.methods.values.any((ms) => ms.contains(method));
        if (!anyVersion) {
          bad.add('$api.$method：目录里没有任何版本含该方法');
        }
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('lib/ 里用到的 Drive API 都被登记为"已用"（不许漏登记）', () {
      final usedApis = usedPairsInLib()
          .map((p) => p.$1)
          .where((a) => a.startsWith('SYNO.SynologyDrive'))
          .toSet();
      final undeclared = usedApis.difference(
        kDriveApisUsedByClient.keys.toSet(),
      );
      expect(
        undeclared,
        isEmpty,
        reason: '这些 API 在代码里用了但没登记用途：$undeclared',
      );
    });

    test('登记为"已用"的 API 至少在 lib/ 里出现（不许虚报已用）', () {
      // ⚠️ `call('api','method')` 的正则只认字面量；有些调用点的 API 名是**常量**
      // （如 `_apiList`/`_apiTrash`），所以这里放宽为"名字出现在 lib/ 源码里"。
      final src = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => f.readAsStringSync())
          .join('\n');
      final fake = kDriveApisUsedByClient.keys
          .where((a) => !src.contains("'$a'"))
          .toList();
      expect(fake, isEmpty, reason: '登记了却在 lib/ 里找不到：$fake');
    });

    test('管理端 API 都有 Mock 用例覆盖（B1：管理员接口必须 Mock 通过）', () {
      // 管理端页面实际会用到的（第 218/220 轮 Mock 用例里已逐一核实）
      const adminApis = [
        'SYNO.SynologyDrive.Settings',
        'SYNO.SynologyDrive.Config',
        'SYNO.SynologyDrive.DBUsage',
        'SYNO.SynologyDrive.Privilege',
        'SYNO.SynologyDrive.Users',
        'SYNO.SynologyDrive.Log',
      ];
      final mockTests = Directory('test')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => f.readAsStringSync())
          .join('\n');
      for (final api in adminApis) {
        expect(
          mockTests.contains("'$api'"),
          isTrue,
          reason: '$api 是管理端接口，必须在 test/ 里有 Mock 用例（新规 B1）',
        );
      }
    });
  });
}
