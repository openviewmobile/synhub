// 文件模块「工具」入口（G4）：把 223 外接设备（USB）与 219 离线文件两个
// **不依赖具体条目**的入口集中到一处。
//
// 为什么用"一个按钮 + 一个面板"而不是各加一个顶栏图标：
// `file_browse_page.dart` 的顶栏在 360dp 窄屏已经逼近溢出（该文件自带注释
// 记录了实测溢出），再塞两个固定图标会把它推过界。面板是**一个有界的新行**，
// 后续要加工具也不会再挤顶栏。
import 'package:flutter/material.dart';

import '../../core/ui/app_sheet.dart';
import '../admin/admin_gate.dart';
import 'drive_saf_on_demand_page.dart';
import 'file_offline_page.dart';
import 'filestation_g4_text.dart';
import 'filestation_webdav_text.dart';
import 'usb_devices_page.dart';
import 'webdav_page.dart';

/// 打开「文件工具」面板。
Future<void> showFileToolsSheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    title: fsG4(FsG4TextKeys.toolsTitle, '文件工具'),
    children: [
      AppSheetSection(
        label: fsG4(FsG4TextKeys.toolsSection, '更多'),
        children: [
          // ★★ r371（用户新规 R2 + DA25 的收口）：**外接设备入口是管理员专属**，
          //   非管理员界面**隐藏**（不是"显示但打不开"）。
          //
          // 判据（两层，都不是猜的）：
          //   * **服务端**：普通账号调 `SYNO.Core.ExternalDevice.Storage.USB/list`
          //     拿到的是 DSM 404 业务码（r370 真机：U 盘在插、`Files` 能进那个盘，
          //     本页仍回 404 ⇒ 走 `notFound` 分支）；
          //   * **官方前端**：DSM 7.2.2 自带 FileStation 1.4.2-1575 的
          //     `ui/file_browser/FileBrowser.js` 里 `initExtDeviceInfo` 与 eject
          //     都在 `_S("is_admin") && …` 之下 ⇒ 这条列表在 DSM 侧只给管理员。
          //
          // ⇒ 按"管理员专属功能在非管理员界面隐藏"处理；门控**只走**
          //   `admin_gate.dart` 的 [AdminOnly]（§5 铁律：不许各页面自己写 `if (isAdmin)`）。
          //   fail-closed：身份未知/查询失败 ⇒ 同样不显示（AdminOnly 的既定语义）。
          // ★ 管理员功能**不做真机验收**（用户裁定，r352/r367 已记）⇒ 真机只验
          //   "非管理员看不见"这一半。
          AdminOnly(
            key: const Key('file-tools-usb-gate'),
            child: AppSheetAction(
              key: const Key('file-tools-usb'),
              icon: Icons.usb,
              label: fsG4(FsG4TextKeys.usbTitle, '外接设备'),
              description: fsG4(
                FsG4TextKeys.usbEntry,
                '查看插在 NAS 上的 U 盘 / 移动硬盘，并安全弹出（需要管理员）',
              ),
              onTap: () => _push(context, const UsbDevicesPage()),
            ),
          ),
          AppSheetAction(
            key: const Key('file-tools-offline'),
            icon: Icons.cloud_off_outlined,
            label: fsG4(FsG4TextKeys.offlineTitle, '离线文件'),
            description: fsG4(
              FsG4TextKeys.offlineEntrySubtitle,
              '你标记为离线可用的文件（本地清单，不占用服务器）',
            ),
            onTap: () => _push(context, const FileOfflinePage()),
          ),
          // ★ 246 轮 D66：系统「文件」里的 Drive 云端文件"按需下载"
          AppSheetAction(
            key: const Key('file-tools-saf-on-demand'),
            icon: Icons.cloud_download_outlined,
            label: fsG4(FsG4TextKeys.safOnDemandTitle, '系统选择器 · 按需下载'),
            description: fsG4(
              FsG4TextKeys.safOnDemandOffDesc,
              '没配置时，系统「文件」里只有已下载的离线文件能打开',
            ),
            onTap: () => _pushSheet(context, showDriveSafOnDemandSheet),
          ),
          AppSheetAction(
            key: const Key('file-tools-webdav'),
            icon: Icons.cloud_outlined,
            label: fsWebDav(FsWebDavTextKeys.title, 'WebDAV 连接'),
            description: fsWebDav(
              FsWebDavTextKeys.entry,
              '用 WebDAV 协议连接 NAS 并浏览目录（只读；官方 DSM 7 起标废弃）',
            ),
            onTap: () => _push(context, const WebDavPage()),
          ),
        ],
      ),
    ],
  );
}

/// 从面板里打开**另一个面板**（`showAppSheet` 的用法与页面不同：
/// 先 pop 掉当前面板，再打开新的，避免两个 sheet 叠在一起）。
void _pushSheet(BuildContext context, Future<void> Function(BuildContext) open) {
  final nav = Navigator.of(context);
  nav.pop();
  open(context);
}

void _push(BuildContext context, Widget page) {
  // 先抓住 navigator：pop 之后本 context 就失效了
  final nav = Navigator.of(context);
  nav.pop();
  nav.push<void>(MaterialPageRoute<void>(builder: (_) => page));
}
