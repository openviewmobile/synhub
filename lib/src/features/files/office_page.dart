// Synology Office 的入口页（工作台扩容 P0-1 → 2026-09-22 收口到 Drive 里）。
//
// 为什么是这个形态（而不是"新造一个 Office 文档列表"）：
//   * `SYNO.Office.*` **没有文档列表 API** —— `office_api.dart` 只有
//     `Info/get`、`Node.Version/list|rename|restore`、`File/extract`、
//     `Export/download`、`Import/check|convert`（出处见 `office_api.dart`
//     顶部与 `docs/api-server-authoritative.md` §Office）；
//   * Office 原生文档（`.odoc/.osheet/.oslides`）就住在文件 / Drive 目录里，
//     官方 Web 端也是在 Drive 里直接打开（Office 包自述
//     "…in Synology Drive"，且带 `drive/hook/libsynoffice_drivehook.so`）；
//   * 既有打开逻辑（只读抽取正文、导出为 ms/odf、转换为 Office 文档、
//     版本历史）全部挂在文件预览 / 行菜单上。
//
// 所以这个入口**复用既有的 `DriveBrowseView`**：不新造查看器、不发送任何
// 未取证的请求（`SYNO.Office.Shard.*` 的协同编辑通道本 App 不碰）。
//
// 2026-09-22 用户拍板：工作台不再有独立 Office 磁贴，入口移进 Drive 的
// 「更多」页（`drive_more_page.dart` 的 `drive-more-office`）。本页因此默认
// 走 `officeOnly: true`——只列 Office 原生文档（+ 目录，用于导航）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/services/service_availability.dart';
import '../office/office_library.dart' show officeLibraryText;
import '../office/office_library_page.dart';
import 'drive_browse_view.dart';

/// Office 文档页：标题由调用方传入（品牌名 "Office"），内容复用 Drive 文件
/// 浏览（Office 文档的既有打开路径），并**只看 Office 文档**。
///
/// 2026-09-22（批 D 接线）：AppBar 追加「模板库」入口（`office-page-templates`）。
/// 门控走既有的统一可用性快照（[officeTemplateLibraryAvailable]）：
/// 服务端能力表里没有 `SYNO.Office.Template` → **入口整个隐藏**，
/// 不给一个点了报错的按钮。
class OfficePage extends ConsumerWidget {
  const OfficePage({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final availability = ref.watch(serviceAvailabilityProvider);
    return Scaffold(
      key: const Key('office-page'),
      backgroundColor: DesignPalette.of(context).bg,
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (officeTemplateLibraryAvailable(availability))
            IconButton(
              key: const Key('office-page-templates'),
              tooltip: officeLibraryText('officeTemplateLibraryTitle', '模板库'),
              icon: const Icon(Icons.dashboard_customize_outlined),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const OfficeTemplateLibraryPage(),
                ),
              ),
            ),
        ],
      ),
      body: const SafeArea(child: DriveBrowseView(officeOnly: true)),
    );
  }
}
