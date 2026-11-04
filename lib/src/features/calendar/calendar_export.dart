// 日历导出（`SYNO.Cal.Cal/export` **v1**）—— **落盘 + 交给系统"打开/分享"**。
//
// 事实来源（**真机 2026-09-22，普通用户**）：
//   * 调用：`SYNO.Cal.Cal / export / v1 / {cal_id}`；
//   * **必需参数** `cal_id`（不给 → 117）；`cal_type` **不需要**（带上也成功，
//     所以不发）；**必须 v1**（v2–v5 全 103）；
//   * 回包是 **`text/calendar` 裸 ICS 文本**（不是 JSON！逐字见
//     `calendar_api.dart` 的 `exportCalendarIcs`）；
//   * 事件日历（`/demo_user/home/`）与待办日历（`/demo_user/home_todo/`）都能导。
//
// 为什么这个文件存在：把"取字节 → 落盘 → 交给系统"三步集中在一处，页面只留
// 一个 `onTap`（与 `download_export.dart` / `office_export.dart` 同一套做法）。
//
// ⚠️ **两个纪律**（对应用户要求）：
//   1. **文件名用日历显示名（`cal_displayname`），绝不用 `cal_id`** ——
//      内部 id 不上屏、也不进文件名（[calendarIcsFileName] 只接受显示名，
//      并把路径分隔符等非法字符净化掉）；
//   2. **本机电脑测试绝不调起 Preview / QuickTime** —— 走仓库既有的
//      `core/system_open.dart`（`FLUTTER_TEST` 下**直接 no-op**），
//      **不新写一套外部打开通道**。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/system_open.dart';
import '../../core/ui/app_states.dart';
import '../../data/calendar_api.dart';
import '../../data/dto/calendar_dto.dart';
import '../files/file_providers.dart' show fileDownloadDirectory;
import 'calendar_providers.dart';

/// `.ics` 的 MIME（交给系统打开/分享时显式给，别退化成 `*/*`）。
///
/// 为什么不在 `media_stream.dart` 的扩展名表里加一行：那是 chat feature 的
/// 文件，属于**别的批次**；这里只用一个本地常量，不动别人的表。
const String kCalendarIcsMime = 'text/calendar';

/// 落盘目录（`<应用文档>/downloads`）—— 与通讯录 vCard 导出 / 笔记导出 /
/// Office 导出**同一个目录、同一条通道**（`fileDownloadDirectory()`）。
/// 做成 provider 是为了测试里覆盖成临时目录。
final calExportDirProvider = Provider<Future<Directory> Function()>(
  (ref) => fileDownloadDirectory,
);

/// 写盘方式（做成 provider 是为了 widget 测试注入 `writeAsBytesSync`：
/// `testWidgets` 的假异步 zone 里 `File.writeAsBytes` 不会在 `pump` 之间落地）。
typedef CalendarExportWriter = Future<void> Function(File file, List<int> bytes);

final calExportWriterProvider = Provider<CalendarExportWriter>(
  (ref) => (file, bytes) => file.writeAsBytes(bytes),
);

/// 交给系统"打开/分享"（测试里覆盖成假的）。
///
/// 默认就是 `system_open.dart`：`FLUTTER_TEST` 下 **no-op**（不启动
/// Preview/QuickTime），Android 上弹应用选择器。
final calExportSystemOpenProvider = Provider<SystemOpenRunner>(
  (ref) => ref.watch(systemOpenProvider),
);

/// 日历显示名 → `.ics` 文件名。
///
/// **只接受 `cal_displayname`**：内部 `cal_id`（`/demo_user/home/`）绝不出现在
/// 文件名里。仍然做一层净化（路径分隔符 / Windows 保留字符 / 控制字符），
/// 免得显示名里的 `/` 之类把文件写到别的目录去。
///
/// 空显示名给**中性兜底** `calendar.ics` —— 也**不是** `cal_id`。
String calendarIcsFileName(String displayName) {
  var base = displayName
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // 只剩分隔符（例如显示名就是一个 `/`）→ 视同空名
  if (base.replaceAll('_', '').trim().isEmpty) base = 'calendar';
  if (!base.toLowerCase().endsWith('.ics')) base = '$base.ics';
  return base;
}

/// **纯函数式核心**：导出日历 → 落盘，返回落盘后的**完整路径**。
///
/// 不碰 provider，便于离线单测（真实 IO 可注入）。失败直接抛（调用方翻文案）。
Future<String> saveCalendarIcs({
  required CalendarApi api,
  required String calId,
  required String displayName,
  required Future<Directory> Function() dir,
  required CalendarExportWriter writer,
}) async {
  // ⚠️ 这一行拿回的是**裸 ICS 文本**（不是 JSON），解析路径与普通 `api.call`
  // 完全不同（见 `decodeCalendarIcsExport`）。
  final ics = await api.exportCalendarIcs(calId);
  final directory = await dir();
  final file = File('${directory.path}/${calendarIcsFileName(displayName)}');
  await writer(file, utf8.encode(ics));
  return file.path;
}

/// 页面级动作：导出这个日历 → 落盘 → 弹"已导出"（可打开/分享）。
///
/// 返回落盘路径（测试用）；失败**明说**（不静默），且**不写任何 `cal_id` 上屏**。
Future<String?> exportCalendar(
  BuildContext context,
  WidgetRef ref,
  CalendarDto calendar,
) async {
  final api = ref.read(calendarApiProvider);
  if (api == null) {
    AppSnack.show(
      context,
      '${dataText('calExportFailed', '导出失败')}'
      '：${currentText().setNotConnected}',
      error: true,
    );
    return null;
  }
  // await 之前把要用到的 provider 一次性取好：widget 卸载后 `ref` 不能再碰
  // （riverpod 3 的 `_assertNotDisposed`）。
  final dir = ref.read(calExportDirProvider);
  final writer = ref.read(calExportWriterProvider);
  final systemOpen = ref.read(calExportSystemOpenProvider);
  try {
    final path = await saveCalendarIcs(
      api: api,
      calId: calendar.calId,
      // ⚠️ 只用显示名（内部 cal_id 不入文件名）
      displayName: calendar.displayName,
      dir: dir,
      writer: writer,
    );
    if (!context.mounted) return path;
    await _showExportDone(context, path, systemOpen);
    return path;
  } catch (e) {
    if (!context.mounted) return null;
    AppSnack.show(
      context,
      '${dataText('calExportFailed', '导出失败')}：${describeCalendarError(e)}',
      error: true,
    );
    return null;
  }
}

/// "已导出"对话框：显示**文件名**（不是内部 id）+ 「打开 / 分享」。
Future<void> _showExportDone(
  BuildContext context,
  String path,
  SystemOpenRunner systemOpen,
) async {
  final name = path.split(Platform.pathSeparator).last;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('cal-export-done'),
      title: Text(dataText('calExportDone', '已导出')),
      content: Text('$name\n$path'),
      actions: [
        TextButton(
          key: const Key('cal-export-open'),
          onPressed: () async {
            // 走既有 `system_open.dart`：测试环境 no-op（不弹 Preview/QuickTime）
            await systemOpen(path);
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: Text(dataText('calExportOpen', '打开 / 分享')),
        ),
        TextButton(
          key: const Key('cal-export-close'),
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(dataText('actionOk', '好')),
        ),
      ],
    ),
  );
}
