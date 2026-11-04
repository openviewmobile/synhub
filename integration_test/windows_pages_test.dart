// Windows **逐页深扫**（r703）：在 **Windows 桌面端真渲染**里用**真 NAS**（只读）
// 把集成 harness 里点名过的 ~100 个页面 widget 逐个推上来，每个抓一张**真实渲染像素**
// ＋ 记一组"这页到底画出了什么"的事实。
//
// 这是 Linux 站 r695 那三段深扫（③e 零参数页 48 屏 / ③f 带参数页 34 屏 /
// ③g 剩余界面单元 17 屏 ＋ 204_drive_versions_office）的 **Windows 移植版**：
// 页面构造、夹具合成、判据全部照抄，只把"平台相关"的部分换掉（见下）。
//
// 跑法（Windows 宿主机，PowerShell）：
//   flutter test integration_test/windows_pages_test.dart -d windows `
//     --dart-define=SYNO_NAS_URL=https://nas.example.com:5001 `
//     --dart-define=SYNO_NAS_ACCOUNT=demo_user `
//     --dart-define=SYNO_NAS_PASSWORD='…'
//
// 截图落点 = 环境变量 `SYNHUB_WIN_SHOT_DIR`（默认 `C:\src\shots-win`）。
// 文件名**故意不匹配** `tool/device_feature_suite.sh` 的通配
// （`p0_*` / `phase*` / `drive_*` / `media_*`）⇒ 不会污染真机矩阵资产。
//
// ★ 像素证据 = **应用内真实渲染抓帧** `RenderRepaintBoundary.toImage()`：
//   取的是这个 Windows App 由 Impeller/D3D 真正画出来的图层（真字体、真图标、
//   真数据），不是布局断言。每张图都带 `[walk] shot` 日志 + 写出字节数。
//   **不用** `vmrun captureScreen`：本机这份 guest 上它只给 1×1/全黑
//   （宿主控制台不在交互会话里），拿它当证据等于把"仪器坏"记成"页面黑"。
//
// ★ 只读纪律（AGENTS §5.1）：对真 NAS 的**变更动词为零**（只 `list`/`get`/`read`/
//   `query`）。唯一例外是**登录会话本身**（`SYNO.API.Auth:login`，任何只读验证
//   的前提），已在此声明。不点进聊天频道（进入会标已读）、不新建/编辑笔记、
//   不上传、不新建下载任务、不点「清空回收站 / 永久删除 / 还原」这类写动作 ——
//   只把页面**打开**看元素。
//
// ★ 判据（与 Linux ③e/③f/③g 完全一致，不编数据）：
//     ① 页面真渲染出 `Scaffold`（不是白屏/异常页）；
//     ② 本屏可见 `Text` 条数 > 0（**空态/错误态也算渲染**，不判"有数据"）。
//   ⇒ "参数为空 ⇒ 列表空 ⇒ 空态"是**合法读数**：它证明的是"这页在 Windows 上
//     能打开、能画、不崩"，不是"里面有数据"。带参数页用的是**本地合成夹具**
//     （不走网络、不碰真 NAS 的写动词）⇒ 只证明界面单元存在且可用。
//
// ★ 定义一律在用例内给默认值（AGENTS §2.0.20⑤）：本用例指向仓库既有的
//   **专用测试 NAS**（同一组凭据也硬编码在 `tool/flt_apis.dart` 等只读探针里）。
import 'package:synhub/src/features/servers/nas_store.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/features/media/media_cover.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/media/video_frame_thumb.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/media/mpv_video_frame_extractor.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/router/app_router.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/ui/energy_orb.dart';
import 'package:synhub/src/data/dto/contact_dto.dart';
import 'package:synhub/src/data/dto/drive_collection_dto.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/features/files/drive_browse_view.dart';

import 'package:synhub/src/data/dto/drive_label_dto.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/features/ai/ai_usage_page.dart';
import 'package:synhub/src/features/analytics/analytics_page.dart';
import 'package:synhub/src/features/analytics/traffic_page.dart';
import 'package:synhub/src/features/audio/audio_detail_page.dart';
import 'package:synhub/src/features/audio/audio_gaps_page.dart';
import 'package:synhub/src/features/audio/audio_radio_page.dart';
import 'package:synhub/src/features/audio/audio_search_page.dart';
import 'package:synhub/src/features/media/audio_lyrics.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_song_page.dart';
import 'package:synhub/src/features/calendar/calendar_page.dart';
import 'package:synhub/src/features/chat/channel_content_page.dart';
import 'package:synhub/src/features/chat/channel_create_page.dart';
import 'package:synhub/src/features/chat/channel_hashtags_page.dart';
import 'package:synhub/src/features/chat/channel_media_page.dart' hide MediaQuery;
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/channel_members_page.dart';
import 'package:synhub/src/features/chat/channel_scheduled_page.dart';
import 'package:synhub/src/features/chat/read_status_page.dart';
import 'package:synhub/src/features/chat/subscribed_threads_page.dart';
import 'package:synhub/src/features/chat/thread_page.dart';
import 'package:synhub/src/features/contacts/contact_editor_page.dart';
import 'package:synhub/src/features/contacts/contact_import_page.dart';
import 'package:synhub/src/features/contacts/contacts_manage_page.dart';
import 'package:synhub/src/features/contacts/contacts_page.dart';
import 'package:synhub/src/features/design/design_preview_page.dart';
import 'package:synhub/src/features/downloads/download_captcha_page.dart';
import 'package:synhub/src/features/downloads/download_create_page.dart';
import 'package:synhub/src/features/downloads/download_detail_page.dart';
import 'package:synhub/src/features/downloads/download_file_select_page.dart';
import 'package:synhub/src/features/downloads/download_rss_page.dart';
import 'package:synhub/src/features/drive/drive_admin_page.dart';
import 'package:synhub/src/features/drive/drive_advance_sharing_page.dart';
import 'package:synhub/src/features/drive/drive_category_page.dart';
import 'package:synhub/src/features/drive/drive_collection_page.dart';
import 'package:synhub/src/features/drive/drive_copy_move_page.dart';
import 'package:synhub/src/features/drive/drive_folder_page.dart';
import 'package:synhub/src/features/drive/drive_local_files_page.dart';
import 'package:synhub/src/features/drive/drive_pdf_markup_page.dart';
import 'package:synhub/src/features/drive/drive_scan_page.dart';
import 'package:synhub/src/features/drive/drive_team_members_page.dart';
import 'package:synhub/src/features/drive/drive_team_trash_page.dart';
import 'package:synhub/src/features/drive/drive_text_editor_page.dart';
import 'package:synhub/src/features/files/drive_labels_page.dart';
import 'package:synhub/src/features/files/drive_more_page.dart';
import 'package:synhub/src/features/files/drive_revisions_page.dart';
import 'package:synhub/src/features/files/drive_share_page.dart';
import 'package:synhub/src/features/files/drive_tasks_page.dart';
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_mount_page.dart';
import 'package:synhub/src/features/files/file_offline_page.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/office_viewer_page.dart';
import 'package:synhub/src/features/files/office_page.dart';
import 'package:synhub/src/features/files/usb_devices_page.dart';
import 'package:synhub/src/features/files/webdav_page.dart';
import 'package:synhub/src/features/mailplus/mail_compose_page.dart';
import 'package:synhub/src/features/mailplus/mail_detail_page.dart';
import 'package:synhub/src/features/mailplus/mail_page.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/notes/note_background_sync_scheduler.dart';
import 'package:synhub/src/features/notes/note_conflict_page.dart';
import 'package:synhub/src/features/notes/note_drawing_page.dart';
import 'package:synhub/src/features/notes/note_editor_page.dart';
import 'package:synhub/src/features/notes/note_joined_page.dart';
import 'package:synhub/src/features/notes/note_share_page.dart';
import 'package:synhub/src/features/notes/note_smart_page.dart';
import 'package:synhub/src/features/notes/note_todo_editor_page.dart';
import 'package:synhub/src/features/notes/note_view_page.dart';
import 'package:synhub/src/features/office/office_doc_page.dart';
import 'package:synhub/src/features/office/office_library_page.dart';
import 'package:synhub/src/features/office/office_sheet_page.dart';
import 'package:synhub/src/features/office/office_slides_page.dart';
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_recent_page.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';
import 'package:synhub/src/features/photos/photo_wave2_page.dart';
import 'package:synhub/src/features/photos/photo_wave3_page.dart';
import 'package:synhub/src/features/search/global_search_page.dart';
import 'package:synhub/src/features/search/search_page.dart';
import 'package:synhub/src/features/servers/certificates_page.dart';
import 'package:synhub/src/features/servers/server_setup_page.dart';
import 'package:synhub/src/features/servers/session_controller.dart';
import 'package:synhub/src/features/settings/snooze_settings_page.dart';
import 'package:synhub/src/features/home/home_page.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';
import 'package:synhub/src/features/surveillance/surv_camera_page.dart';
import 'package:synhub/src/features/surveillance/surv_page.dart';
import 'package:synhub/src/features/admin/admin_tools_page.dart';
import 'package:synhub/src/features/ai/ai_model_page.dart';
import 'package:synhub/src/features/audio/audio_cast_page.dart';
import 'package:synhub/src/features/audio/audio_pins_page.dart';
import 'package:synhub/src/features/audio/audio_remote_page.dart';
import 'package:synhub/src/features/audio/audio_web_queue_page.dart';
import 'package:synhub/src/features/chat/archive_page.dart';
import 'package:synhub/src/features/chat/available_channels_page.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/chat/global_content_page.dart';
import 'package:synhub/src/features/diagnostics/diag_page.dart';
import 'package:synhub/src/features/downloads/download_bt_search_page.dart';
import 'package:synhub/src/features/downloads/download_emule_page.dart';
import 'package:synhub/src/features/downloads/download_emule_search_page.dart';
import 'package:synhub/src/features/downloads/download_emule_server_page.dart';
import 'package:synhub/src/features/downloads/download_settings_page.dart';
import 'package:synhub/src/features/drive/drive_computers_page.dart';
import 'package:synhub/src/features/drive/drive_connections_page.dart';
import 'package:synhub/src/features/drive/drive_extras_page.dart';
import 'package:synhub/src/features/drive/drive_file_request_page.dart';
import 'package:synhub/src/features/drive/drive_notifications_page.dart';
import 'package:synhub/src/features/drive/drive_quota_page.dart';
import 'package:synhub/src/features/drive/drive_search_page.dart';
import 'package:synhub/src/features/drive/drive_sync_tasks_page.dart';
import 'package:synhub/src/features/drive/drive_trash_page.dart';
import 'package:synhub/src/features/login/login_page.dart';
import 'package:synhub/src/features/notes/note_adv_search_page.dart';
import 'package:synhub/src/features/notes/note_background_sync_page.dart';
import 'package:synhub/src/features/notes/note_fts_search_page.dart';
import 'package:synhub/src/features/notes/note_overdue_settings_page.dart';
import 'package:synhub/src/features/notes/note_recycle_page.dart';
import 'package:synhub/src/features/notes/note_shared_page.dart';
import 'package:synhub/src/features/notes/note_shelf_page.dart';
import 'package:synhub/src/features/notes/note_shortcut_page.dart';
import 'package:synhub/src/features/notes/note_tag_page.dart';
import 'package:synhub/src/features/notes/note_todo_page.dart';
import 'package:synhub/src/features/photos/photo_admin_page.dart';
import 'package:synhub/src/features/photos/photo_ai_edit_settings_page.dart';
import 'package:synhub/src/features/photos/photo_background_tasks_page.dart';
import 'package:synhub/src/features/photos/photo_backup_page.dart';
import 'package:synhub/src/features/photos/photo_c2_page.dart';
import 'package:synhub/src/features/photos/photo_free_up_page.dart';
import 'package:synhub/src/features/photos/photo_map_page.dart';
import 'package:synhub/src/features/photos/photo_migration_page.dart';
import 'package:synhub/src/features/photos/sleep_backup_page.dart';
import 'package:synhub/src/features/servers/nas_manager_page.dart';
import 'package:synhub/src/features/settings/bots_page.dart';
import 'package:synhub/src/features/settings/e2ee_page.dart';
import 'package:synhub/src/features/settings/notification_settings_page.dart';
import 'package:synhub/src/features/settings/oem_keepalive_page.dart';
import 'package:synhub/src/features/settings/personal_profile_page.dart';
import 'package:synhub/src/features/settings/service_check_page.dart';
import 'package:synhub/src/features/settings/settings_page.dart';

// ---------------------------------------------------------------- 参数
const String _url = String.fromEnvironment(
  'SYNO_NAS_URL',
  defaultValue: 'https://nas.example.com:5001',
);
const String _account = String.fromEnvironment(
  'SYNO_NAS_ACCOUNT',
  defaultValue: 'demo_user',
);
const String _password = String.fromEnvironment(
  'SYNO_NAS_PASSWORD',
  defaultValue: '', // 用 --dart-define=SYNO_NAS_PASSWORD=… 提供
);
const String _qc = String.fromEnvironment(
  'SYNO_NAS_QC',
  defaultValue: 'demo_admin-qq',
);

/// 截图落点：Windows 宿主上的一个普通目录（跑完直接去那里取图）。
const String _shotDirPath = String.fromEnvironment(
  'SYNHUB_WIN_SHOT_DIR',
  defaultValue: r'C:\src\shots-win',
);

final Directory _shotDir = Directory(_shotDirPath)..createSync(recursive: true);

final GlobalKey _rootKey = GlobalKey(debugLabel: 'walk-root');

/// 本轮走查的结论表（屏幕 → 结论/证据），最后由测试打印出来。
final List<String> _report = <String>[];

void _note(String s) {
  _report.add(s);
  debugPrint('[walk] $s');
}

// ---------------------------------------------------------------- 工具

/// 推若干帧 + 真实等待（**不能用 pumpAndSettle**：HUD 背景是常驻动画）。
Future<void> _wait(WidgetTester tester, [int ms = 500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 32));
    await Future<void>.delayed(const Duration(milliseconds: 32));
  }
}

/// 等条件成立（真实时间）。
Future<void> _waitFor(
  WidgetTester tester,
  String label,
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TestFailure('等待超时：$label');
}

bool _hasKey(String k) => find.byKey(Key(k)).evaluate().isNotEmpty;

/// ★ 只认**真的在屏幕上**的文字：外壳用 `IndexedStack` 保活，
/// 非当前 tab 的页面仍在 widget 树里（Offstage）⇒ 裸 `find.text` 会命中
/// 别的 tab 里的同名文字，`tap(warnIfMissed:false)` 于是**静默打空**。
bool _hasText(String s) => find.text(s).hitTestable().evaluate().isNotEmpty;

/// ★★ **不看 hitTest 的**存在性版本 —— 判"界面给没给这个条目"只能用这条。
/// 实测反例：宽屏两栏下 `home` 行确实在控件树里（dump 打得出来），
/// 但 `.hitTestable()` 回假（行文字被父级 InkWell/裁剪吃掉半个矩形）
/// ⇒ 拿 `_hasText` 当存在性判据会得到假否定（AGENTS §2.0.63「渲染了但被裁」同型）。
bool _hasTextAny(String s) => find.text(s).evaluate().isNotEmpty;

/// 抓一张**真实渲染**像素图。
Future<void> _shot(WidgetTester tester, String name) async {
  await _wait(tester, 350);
  final ro = _rootKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    _note('截图失败（没有 RepaintBoundary）：$name');
    return;
  }
  await tester.runAsync(() async {
    final img = await ro.toImage(pixelRatio: 2.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    final f = File('${_shotDir.path}/$name.png');
    f.writeAsBytesSync(bd!.buffer.asUint8List());
    _note('SHOT $name → ${f.path} (${img.width}x${img.height}, '
        '${bd.lengthInBytes}B)');
  });
}

/// 点第 [index] 个 [EnergyOrb]（页面里的「主行动」）——**先滚动到可见**。
Future<bool> _tapOrb(WidgetTester tester, {int index = 0}) async {
  final all = find.byType(EnergyOrb);
  if (all.evaluate().length <= index) return false;
  final f = all.at(index);
  try {
    await tester.ensureVisible(f);
  } catch (_) {
    // 没有可滚动祖先：原地即可
  }
  await _wait(tester, 250);
  await tester.tap(f, warnIfMissed: false);
  await _wait(tester, 600);
  return true;
}

/// 走查里每个屏幕失败时必须能立刻看出**卡在哪一态**（loading / failure / 空 / 正常）。
void _dumpUi(WidgetTester tester, String tag) {
  const keys = <String>[
    'office-doc-view', 'office-doc-loading', 'office-doc-failure',
    'office-doc-empty-doc', 'office-doc-session-expired',
    'office-sheet-page', 'office-sheet-loading', 'office-sheet-failure',
    'office-slides-page', 'office-slides-loading', 'office-slides-failure',
    'office-template-library', 'office-template-library-loading',
    'office-template-library-empty', 'office-template-library-error',
    'file-page-loading', 'file-page-error', 'file-no-more',
    // 其它模块的"这一页真的画出来了"锚点
    'as-home-recently-played', 'as-library-personal', 'as-home-menu',
    'note-fts-entry', 'note-joined-entry', 'note-c3-import-entry',
    'photo-album-create', 'photo-backup-entry', 'photo-concepts-count',
    'ds-add-task', 'ds-browser-open', 'ds-batch-menu',
    // 本轮的锚点
    'file-up', 'file-source-pager', 'file-tools-entry',
    'ds-stat-bar', 'photo-timeline-view-bar', 'photo-album-settings',
    'admin-tools-page', 'diag-page', 'ai-model-page',
    'preview-video-stage', 'preview-audio-stage', 'media-play-pause',
    'audio-play-pause', 'audio-progress',
  ];
  final present = keys.where((k) => _hasKey(k)).toList();
  final texts = <String>[];
  for (final e in find.byType(Text).evaluate().take(50)) {
    final d = (e.widget as Text).data;
    if (d != null && d.trim().isNotEmpty) texts.add(d.trim());
  }
  _note('$tag keys=${present.join('|')} texts=${texts.take(20).join(' / ')}');
}

/// 回到外壳首页：把所有推入的路由弹掉，并回到聊天空。
Future<void> _resetToShell(WidgetTester tester) async {
  final nav = rootNavigatorKey.currentState;
  if (nav != null) {
    var guard = 0;
    while (nav.canPop() && guard++ < 8) {
      nav.pop();
      await _wait(tester, 250);
    }
  }
  final container = _container(tester);
  if (container != null) {
    container.read(appTabProvider.notifier).select(AppTab.chat);
    await _wait(tester, 500);
  }
}

ProviderContainer? _container(WidgetTester tester) {
  final el = find.byType(SynologyChatApp);
  if (el.evaluate().isEmpty) return null;
  return ProviderScope.containerOf(tester.element(el.first), listen: false);
}

/// 推一个页面（用于"工作台里没有磁贴"的模块，与 macOS/Linux 走查同一手法）。
Future<void> _push(WidgetTester tester, Widget page) async {
  rootNavigatorKey.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => page),
  );
  await _wait(tester, 2000);
}

/// r695：推一个**只读页面**上来、抓一张像素、记一条事实。
/// ★ 异常只**记录**不中断（`PROBE-THROW`）：一轮上百屏，单页抛错不该让后面的屏全丢；
///   事后逐条定性是「页面自身缺陷」还是「平台缺插件」，不许混进"都跑过了"里。
Future<String?> _probePage(
  WidgetTester tester,
  String shot,
  Widget page,
  String tag,
) async {
  String? err;
  await _resetToShell(tester);
  try {
    await _push(tester, page);
    await _wait(tester, 5000);
    // ★ **页面自己在异步里抛的异常**必须在这里就地取走，否则它会脱出本步骤，
    //   一路把整轮走查打断。取走后记成一条 PROBE-THROW，该页照样算失败屏，
    //   但**后面的屏还能继续验**。
    final frameEx = tester.takeException();
    if (frameEx != null) {
      err = '页面异步异常：$frameEx';
      _note('PROBE-THROW $tag $shot: $frameEx');
    }
    await _shot(tester, shot);
    _dumpUi(tester, '$tag $shot');
    expect(find.byType(Scaffold), findsWidgets, reason: '$shot 没有 Scaffold（白屏/异常页）');
    final texts = find.byType(Text).evaluate().length;
    _note('$tag $shot：Scaffold 在，Text=$texts'
        '${err == null ? '' : '（另有页面异步异常，见 PROBE-THROW）'}');
  } catch (e) {
    err = '$e';
    _note('PROBE-THROW $tag $shot: $e');
  }
  return err;
}

/// 与 [_probePage] 同形，但**可指定 settle 时长**（给"这台 NAS 上天生慢"的页用）。
/// 只多一个参数，判据与记录格式完全一致 —— 免得为了多等几秒复制出第二套判据。
Future<String?> _probePageSlow(
  WidgetTester tester,
  String shot,
  Widget page,
  String tag, {
  required Duration settle,
}) async {
  String? err;
  await _resetToShell(tester);
  try {
    await _push(tester, page);
    await _wait(tester, settle.inMilliseconds);
    final frameEx = tester.takeException();
    if (frameEx != null) {
      err = '页面异步异常：$frameEx';
      _note('PROBE-THROW $tag $shot: $frameEx');
    }
    await _shot(tester, shot);
    _dumpUi(tester, '$tag $shot');
    expect(find.byType(Scaffold), findsWidgets, reason: '$shot 没有 Scaffold（白屏/异常页）');
    final texts = find.byType(Text).evaluate().length;
    final spinners = find.byType(CircularProgressIndicator).evaluate().length;
    _note('$tag $shot：Scaffold 在，Text=$texts，spinner=$spinners');
  } catch (e) {
    err = '$e';
    _note('PROBE-THROW $tag $shot: $e');
  }
  return err;
}

/// r707：抽帧后端探针要用的"能力门提前打开"开关
/// （`--dart-define=SYN_WIN_FORCE_FRAMES=true`）。
///
/// ★ 为什么必须**在建 App 之前**设置：`videoFrameDetailedLoaderProvider` 是
///   **非 autoDispose** 的 `Provider` —— 第一次 `read` 就把闭包定死；如果等到
///   ③o 才设标志，前面相册页早已把它读成"不可用"的 no-op 版本
///   ⇒ 探针只会拿到 `platformUnavailable=true`（r707 第一次跑就是这个假 SKIP）。
const bool _forceFrames = bool.fromEnvironment('SYN_WIN_FORCE_FRAMES');


/// 只跑 r705 那段（③k）：`--dart-define=SYN_WIN_K_ONLY=true`。
/// 用途只有一个 —— 补三张外壳/慢页的像素时不必把 160 页重跑一遍（25 min → 3 min）。
const bool _kOnly = bool.fromEnvironment('SYN_WIN_K_ONLY');

/// 启动真 App（与 `lib/main.dart` 的 overrides 同形）。
Future<void> _boot(WidgetTester tester) async {
  WidgetsFlutterBinding.ensureInitialized();
  // ★ `integration_test` 走的是**本文件的 main**，不会执行 `lib/main.dart` 里的
  //   媒体初始化 ⇒ 一进音频/视频页就抛
  //   「MediaKit.ensureInitialized must be called before using any API」
  //   （或音频后端的 `Player()` 构造失败）。这是**装置缺口**，不是产品缺陷
  //   （App 自己的 main 已经调了，r703 起 Windows 也在那一列里）。
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    _note('MediaKit 初始化失败（视频退回主引擎/插件）：$e');
  }
  try {
    JustAudioMediaKit.ensureInitialized(linux: false, windows: true);
  } catch (e) {
    _note('just_audio_media_kit 初始化失败（音频退回插件）：$e');
  }
  if (_forceFrames) {
    // 桌面抽帧探针：在**任何 provider 被读**之前把门打开
    debugForceVideoFrameExtractionPossible = true;
    _note('r707 抽帧门已强制打开（SYN_WIN_FORCE_FRAMES=true）');
  }
  final profile = DeviceProfile.detect();
  await NoteStationApi.initNoteDeviceName();
  await registerNoteBackgroundSync();
  final audioHandler = await createBackgroundAudioHandler();
  await tester.pumpWidget(
    RepaintBoundary(
      key: _rootKey,
      child: ProviderScope(
        overrides: [
          deviceProfileProvider.overrideWithValue(profile),
          biometricAuthenticatorProvider.overrideWithValue(
            LocalAuthBiometricAuthenticator(),
          ),
          audioHandlerProvider.overrideWithValue(audioHandler),
        ],
        child: const SynologyChatApp(),
      ),
    ),
  );
  await _wait(tester, 2500);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows 逐页深扫：启动 → 真 NAS 登录 → 逐页开一遍', (tester) async {
    final failures = <String>[];
    Future<void> step(String name, Future<void> Function() body) async {
      try {
        await body();
        // ★ 把"布局溢出"归到**具体步骤**上：每步结束立刻取异常，creator 链才是活的
        //   （整轮结束再取时 widget 已经 DISPOSED，全是 `(DEFUNCT)`，认不出是谁）。
        final overflow = tester.takeException();
        if (overflow != null) {
          throw StateError('步骤内有未处理异常（多为布局溢出）：$overflow');
        }
      } catch (e) {
        failures.add('$name: ${'$e'.split('\n').first}');
        _note('STEP-FAIL $name: $e');
        await _resetToShell(tester);
      }
    }

    debugPrint('[walk] 截图目录 = ${_shotDir.path}');
    debugPrint('[walk] 目标 NAS = $_url  QC=$_qc  账号=$_account');

    // ============================================================ 启动
    await _boot(tester);
    await _shot(tester, '00_boot_setup');
    _note('① 启动：连接页已渲染（key=srv-orb='
        '${find.byType(EnergyOrb).evaluate().length}，'
        'Direct address：可见=${_hasText('Direct address')} '
        '在树里=${_hasTextAny('Direct address')}）');

    final container = _container(tester)!;

    // 静默重登（restore）先跑完，否则连接按钮是禁用的
    await _waitFor(
      tester,
      'restore 结束',
      () => !container.read(sessionControllerProvider).restoring,
    );

    // ============================================================ ① 登录
    await step('① 登录', () async {
      if (container.read(sessionControllerProvider).loggedIn) {
        // 上一轮跑过 ⇒ 冷启动静默重登已经进了主页（这也是"登录可用"的一种形态）
        _note('① 静默重登（restore）直接进入主页，跳过手动登录 UI');
        await _wait(tester, 3000);
        await _shot(tester, '03_home_chat');
        return;
      }
      // 用真 UI：切到「直接地址」段（按图标找，避免语言相关文案）→ 填地址 → 点能量核
      final seg = find.byIcon(Icons.lan_outlined);
      if (seg.evaluate().isNotEmpty) {
        await tester.tap(seg.first, warnIfMissed: false);
        await _wait(tester, 400);
        _note('① 已切到「直接地址」段（Icons.lan_outlined）');
      } else {
        _note('① 未找到「直接地址」段图标，改用控制器直连');
      }
      final tf = find.byType(TextField);
      if (tf.evaluate().isNotEmpty) {
        await tester.enterText(tf.first, _url);
        await _wait(tester, 300);
      }
      // 首连信任：App 自己的 prompt 会弹真框，这里抓图后点「信任」。
      var sawDialog = false;
      await _tapOrb(tester);
      // 握手 + 首连信任框（轮询真实时间；不能 pumpAndSettle）
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 80));
        if (find.byType(AlertDialog).evaluate().isNotEmpty) {
          sawDialog = true;
          break;
        }
        if (container.read(sessionControllerProvider).connection != null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      if (sawDialog) {
        await _shot(tester, '01_trust_dialog');
        final ok = find.byType(FilledButton);
        if (ok.evaluate().isNotEmpty) {
          await tester.tap(ok.last, warnIfMissed: false);
        }
        await _wait(tester, 1200);
      }
      await _waitFor(
        tester,
        '连接建立',
        () => container.read(sessionControllerProvider).connection != null,
        timeout: const Duration(seconds: 90),
      );
      final conn = container.read(sessionControllerProvider).connection!;
      _note(
        '① 连接成功：label=${conn.profile.label} '
        'trustDialog=$sawDialog',
      );
      expect(conn.profile.value, _url);

      // 登录页
      await _waitFor(
        tester,
        '进入登录页',
        () => find.byType(TextField).evaluate().length >= 2,
      );
      // ★ 进登录页后会先播一段 `SYSTEM BOOT` HUD（SELF-TEST/LINK/CRYPTO/HUD），
      //   它会盖住表单 ⇒ 等它演完，并把第一个输入框滚进视口再拍。
      await _wait(tester, 14000);
      final fields = find.byType(TextField);
      if (fields.evaluate().isNotEmpty) {
        try {
          await tester.ensureVisible(fields.first);
          await _wait(tester, 800);
        } catch (_) {}
      }
      await _shot(tester, '02_login_page');
      await tester.enterText(fields.at(0), _account);
      await tester.enterText(fields.at(1), _password);
      await _wait(tester, 400);
      await _tapOrb(tester);
      try {
        await _waitFor(
          tester,
          '登录成功进主页',
          () =>
              container.read(sessionControllerProvider).loggedIn &&
              _hasKey('app-shell-stack'),
          timeout: const Duration(seconds: 90),
        );
      } catch (_) {
        final e = container.read(sessionControllerProvider);
        _note(
          '① 登录失败诊断：error=${e.error} otp=${e.otpRequired} '
          'busy=${e.busy} connected=${e.connected}',
        );
        rethrow;
      }
      final st = container.read(sessionControllerProvider);
      _note(
        '① 登录成功：account=${st.session?.account} '
        'sid=${st.session!.sid.length}位 did=${st.session?.did != null} '
        'endpoint=${st.connection!.endpoint.source} '
        'certPinned=${st.connection!.certPinned}',
      );
      await _wait(tester, 4000); // 服务可用性探测 + 频道列表
      await _shot(tester, '03_home_chat');

    });

    // ============================ ③e 零参数页深扫（Linux r694 移植）
    //
    // ★ 把 `lib/src/features/**` 里**构造函数零必填参数**的页逐个推上来，各抓一张像素。
    //   判据与 Linux 站一致：① 真渲染出 `Scaffold`；② 可见 `Text` > 0
    //   （**空态/错误态也算渲染**，不判"有数据"）。
    // ★ 全部只读 GET（没有一页会自己发写动词；编辑器不点保存、扫描不点开始）。
    await step('③e 零参数页深扫（48 页：AI/分析/音频/日历/聊天/联系人/设计/下载/Drive/'
        '文件/邮件/笔记/相册/搜索/监控/服务器）', () async {
      final probes = <(String, Widget)>[
        // AI / 分析
        ('105_ai_usage', const AiUsagePage()),
        ('106_analytics_usage', const UsageAnalyticsPage()),
        ('107_analytics_traffic', const TrafficPage()),
        // 音频
        ('108_audio_recently_added', const AudioRecentlyAddedPage()),
        ('109_audio_random100', const AudioRandom100Page()),
        ('110_audio_radio', const AudioRadioPage()),
        ('111_audio_radio_search', const AudioRadioSearchPage()),
        ('112_audio_search', const AudioSearchPage()),
        // 日历 / 聊天 / 联系人 / 设计
        ('113_calendar', const CalendarPage()),
        ('114_chat_channel_create', const ChannelCreatePage()),
        ('115_contacts_manage', const ContactsManagePage()),
        ('116_contacts', const ContactsPage()),
        ('117_design_preview', const DesignPreviewPage()),
        // 下载
        ('118_dl_captcha', const DownloadCaptchaPage()),
        ('119_dl_create', const DownloadCreatePage()),
        ('120_dl_rss_feed', const DownloadRssFeedPage(title: 'RSS')),
        // Drive
        ('121_drive_admin', const DriveAdminPage()),
        ('122_drive_category', const DriveCategoryPage()),
        ('123_drive_collection', const DriveCollectionPage()),
        ('124_drive_labels', const DriveLabelsPage()),
        ('125_drive_more', const DriveMorePage()),
        ('126_drive_tasks', const DriveTasksPage()),
        ('127_drive_folder', const DriveFolderPage(rootFileId: '', title: '/')),
        ('128_drive_scan', const DriveScanPage(folderId: '')),
        ('129_drive_local_files', const DriveLocalFilesPage(targetDrivePath: '/home')),
        ('130_drive_copy_move',
            const DriveCopyMovePage(entries: <DriveEntryDto>[], move: true)),
        (
          '131_drive_text_editor',
          DriveTextEditorPage(
            title: 'probe.txt',
            loadText: () async => 'windows walkthrough probe',
            saveText: (text) async {},
          ),
        ),
        // 文件
        ('132_files_browse', const FileBrowsePage(initialPath: '')),
        ('133_files_mount', const FileMountPage()),
        ('134_files_offline', const FileOfflinePage()),
        ('135_files_usb', const UsbDevicesPage()),
        ('136_files_webdav', const WebDavPage()),
        // 邮件
        ('137_mail', const MailPage()),
        ('138_mail_compose', const MailComposePage()),
        ('139_mail_detail', const MailDetailPage(threadId: '1')),
        // 笔记编辑器 / 冲突 / 绘图
        ('140_note_conflict', const NoteConflictPage()),
        ('141_note_drawing', const NoteDrawingPage()),
        ('142_note_editor', const NoteEditorPage()),
        ('143_note_todo_editor', const NoteTodoEditorPage()),
        // 相册
        ('144_photo_browse', const PhotoBrowsePage()),
        ('145_photo_recent', const PhotoRecentlyAddedPage()),
        ('146_photo_tags', const PhotoTagsPage()),
        ('147_photo_album_settings', const PhotoAlbumSettingsPage()),
        // 搜索
        ('148_search_global', const GlobalSearchPage()),
        ('149_search', const SearchPage()),
        // 监控 / 服务器
        ('150_surveillance', const SurveillancePage()),
        ('151_servers_certificates', const CertificatesPage()),
        ('152_servers_setup', const ServerSetupPage()),
      ];
      for (final (shot, page) in (_kOnly ? const <(String, Widget)>[] : probes)) {
        await _probePage(tester, shot, page, '③e');
      }
    });

    // ============================ ③f 带参数页深扫（Linux r695 移植）
    //
    // ★ 上一批（③e）只打了"构造函数零必填参数"的页；剩下这批**必须给参数**。
    //   参数用**本地合成的夹具**（不走网络、不碰真 NAS 的写动词），判据仍然只有
    //   Scaffold ＋ 可见 `Text` > 0 —— 即"这页在 Windows 上能打开、能画、不崩"。
    //   ★ 合成 id 打服务端会得到空的/失败的响应，那正是"无副作用"的证据。
    await step('③f 带参数页深扫（Drive 分享/版本/标注/团队回收站/高级共享/标签/集合 ·'
        '下载详情/选文件 · 音频单曲/已播 · 频道内容/成员/媒体 · 联系人编辑器/导入 ·'
        '笔记查看/分享/智能/加入 · 相册专辑/文件夹/人物/标签/查看器 · 监控摄像机 · Office）',
        () async {
      // 合成条目：Drive 的"文件"（不指向真文件，只用于把页面画出来）
      const probeEntry = DriveEntryDto(
        fileId: 'probe-file-1',
        name: 'probe.txt',
        type: 'file',
        path: '/probe.txt',
        displayPath: '/probe.txt',
        parentId: '0',
        size: 12,
        modifiedTime: 0,
        createdTime: 0,
        contentType: 'text/plain',
        starred: false,
        shared: false,
        owner: 'demo_user',
        canDownload: true,
        canPreview: true,
        canWrite: false,
        capabilities: <String, dynamic>{},
      );
      // 合成 PDF（最小合法结构，供标注页渲染；不落盘）
      const probePdf = <int>[
        0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34, 0x0a, // %PDF-1.4
      ];
      final probes = <(String, Widget)>[
        // Drive
        ('153_drive_share', const DriveSharePage(entry: probeEntry)),
        ('154_drive_revisions', const DriveRevisionsPage(entry: probeEntry)),
        (
          '155_drive_pdf_markup',
          // ★ 平台适配：Linux 用的是 `/tmp/synhub_probe.pdf`；Windows 没有 `/tmp`，
          //   换成宿主临时目录（批注旁挂文件读写不到就走错误态，仍是"能开能画"）。
          DrivePdfMarkupPage(
            filePath: '${Directory.systemTemp.path}/synhub_probe.pdf',
            fileName: 'probe.pdf',
            bytes: Uint8List.fromList(probePdf),
          ),
        ),
        ('156_drive_team_member_list',
            const DriveTeamMemberListPage(teamId: '1', teamName: 'probe')),
        ('157_drive_folder_trash',
            const DriveFolderTrashPage(folderId: '1', folderName: 'probe')),
        ('158_drive_advance_sharing',
            const DriveAdvanceSharingPage(path: '/probe.txt', entryName: 'probe.txt')),
        (
          '159_drive_labelled',
          const DriveLabelledPage(
            label: DriveLabelDto(
              labelId: 'l1',
              name: 'probe',
              color: 'blue',
              position: 0,
              type: 'normal',
            ),
          ),
        ),
        (
          '160_drive_collection_files',
          const DriveCollectionFilesPage(
            collection: DriveCollectionDto(
              collectionId: 'c1',
              name: 'probe',
              type: 'normal',
              color: 'blue',
              position: 0,
              fileCount: 0,
            ),
          ),
        ),
        // 下载
        ('161_dl_detail', const DownloadDetailPage(taskId: '1')),
        ('162_dl_file_select', const DownloadFileSelectPage(listId: '1')),
        // 音频
        ('163_audio_song_detail',
            const AudioSongDetailPage(songId: '1', title: 'probe')),
        ('164_audio_played', const AudioPlayedPage(mode: AudioPlayedMode.recently)),
        // 聊天（**不进 ChatPage**：进入会标已读 = 写动词）
        ('165_chat_pinned',
            const ChannelContentPage(channelId: 1, kind: ChannelContentKind.pinned)),
        ('166_chat_bookmarks',
            const ChannelContentPage(channelId: 1, kind: ChannelContentKind.bookmarks)),
        ('167_chat_hashtags', const ChannelHashtagsPage(channelId: 1)),
        ('168_chat_media', const ChannelMediaPage(channelId: 1)),
        ('169_chat_members', const ChannelMembersPage(channelId: 1)),
        ('170_chat_scheduled', const ScheduledMessagesPage(channelId: 1)),
        ('171_chat_reminders', const RemindersPage(channelId: 1)),
        ('172_chat_subscribed', const SubscribedThreadsPage(channelId: 1)),
        ('173_chat_read_status', const ReadStatusPage(postId: 1)),
        // 联系人
        ('174_contacts_editor', const ContactEditorPage(addressbookId: '1')),
        ('175_contacts_import', const ContactImportPage(books: <AddressbookDto>[])),
        // 笔记（合成 NoteDto ⇒ 只读查看面）
        (
          '176_note_view',
          const NoteViewPage(note: NoteDto(objectId: 'probe-note-1', title: 'probe')),
        ),
        (
          '177_note_share',
          const NoteSharePage(note: NoteDto(objectId: 'probe-note-1', title: 'probe')),
        ),
        (
          '178_note_smart_notes',
          const NoteSmartNotesPage(
            smart: SmartNotebookDto(objectId: 'probe-smart-1', title: 'probe'),
          ),
        ),
        // 相册
        (
          '179_photo_album_items',
          const PhotoAlbumItemsPage(album: FotoAlbumDto(id: '1', name: 'probe')),
        ),
        (
          '180_photo_folder',
          const PhotoFolderPage(folder: FotoFolderDto(id: '1', name: 'probe')),
        ),
        (
          '181_photo_smart_album',
          const PhotoSmartAlbumPage(
            kind: PhotoSmartAlbumKind.person,
            id: '1',
            title: 'probe',
          ),
        ),
        ('182_photo_person_album',
            const PhotoPersonAlbumPage(personId: '1', name: 'probe')),
        (
          '183_photo_tag_detail',
          const PhotoTagDetailPage(tag: FotoTagDto(id: '1', name: 'probe')),
        ),
        (
          '184_photo_viewer',
          const PhotoViewerPage(
            items: <FotoItemDto>[FotoItemDto(id: '1', filename: 'probe.jpg')],
          ),
        ),
        // 监控
        ('185_surv_camera', const SurvCameraPage(cameraId: 1, initialName: 'probe')),
        // Office
        ('186_office_template_library', const OfficeTemplateLibraryPage()),
      ];
      for (final (shot, page) in (_kOnly ? const <(String, Widget)>[] : probes)) {
        await _probePage(tester, shot, page, '③f');
      }
    });

    // ============================ ③g 剩余界面单元（Linux r695 移植）
    //
    // 音频六种详情（专辑/艺人/作曲/流派/文件夹/播放列表）、Office 三个阅读器 ＋
    // 主题/版本/办公首页、笔记"加入的笔记本"、频道话题页、定时免打扰页、
    // 文件预览器两个分支（文本 / 图片）。
    // 判据同 ③e/③f（Scaffold ＋ 可见 Text > 0）；**合成参数 ⇒ 只证明界面单元能开能画**。
    // ★ 仍然不进 `ChatPage`（进入会标已读 = 写动词），见 §5.1。
    await step('③g 剩余界面单元（音频六详情 · Office 三阅读器/主题/版本 · 笔记加入 · 话题 ·'
        ' 定时免打扰 · 文件预览文本/图片）', () async {
      const probeDoc = OfficeDocRequest(fileId: 'probe-doc-1', name: 'probe.odoc');
      const probeSheet = OfficeSheetRequest(fileId: 'probe-sheet-1', name: 'probe.osheet');
      const probeSlides =
          OfficeSlidesRequest(fileId: 'probe-slides-1', name: 'probe.oslides');
      final probes = <(String, Widget)>[
        // 音频六种详情（合成名字 / 合成 id）
        ('187_audio_artist', const AudioDetailPage.artist(name: 'probe')),
        ('188_audio_composer', const AudioDetailPage.composer(name: 'probe')),
        ('189_audio_genre', const AudioDetailPage.genre(name: 'probe')),
        ('190_audio_album', const AudioDetailPage.album(name: 'probe')),
        ('191_audio_folder', const AudioDetailPage.folder(id: '1', path: '/probe')),
        ('192_audio_playlist', const AudioDetailPage.playlist(id: '1', name: 'probe')),
        // Office 三阅读器 ＋ 主题 / 版本 / 办公首页
        ('193_office_doc', const OfficeDocPage(request: probeDoc)),
        ('194_office_sheet', const OfficeSheetPage(request: probeSheet)),
        ('195_office_slides', const OfficeSlidesPage(request: probeSlides)),
        (
          '196_office_themes',
          const OfficeThemesPage(
            entry: DriveEntryDto(
              fileId: 'probe-file-1',
              name: 'probe.odoc',
              type: 'file',
              path: '/probe.odoc',
              displayPath: '/probe.odoc',
              parentId: '0',
              size: 12,
              modifiedTime: 0,
              createdTime: 0,
              contentType: 'application/vnd.oasis.opendocument.text',
              starred: false,
              shared: false,
              owner: 'demo_user',
              canDownload: true,
              canPreview: true,
              canWrite: false,
              capabilities: <String, dynamic>{},
            ),
          ),
        ),
        (
          '197_office_versions',
          const OfficeVersionsReadOnlyPage(
            entry: DriveEntryDto(
              fileId: 'probe-file-1',
              name: 'probe.odoc',
              type: 'file',
              path: '/probe.odoc',
              displayPath: '/probe.odoc',
              parentId: '0',
              size: 12,
              modifiedTime: 0,
              createdTime: 0,
              contentType: 'application/vnd.oasis.opendocument.text',
              starred: false,
              shared: false,
              owner: 'demo_user',
              canDownload: true,
              canPreview: true,
              canWrite: false,
              capabilities: <String, dynamic>{},
            ),
          ),
        ),
        ('198_office_home', const OfficePage(title: 'Office')),
        // 笔记「加入的笔记本」
        (
          '199_note_joined_notebook',
          const NoteJoinedNotebookPage(
            notebook: NotebookDto(objectId: 'probe-nb-1', title: 'probe'),
          ),
        ),
        // 频道话题页（只读取帖）
        ('200_chat_thread', const ThreadPage(channelId: 1, parentPostId: 1)),
        // 定时免打扰
        ('201_settings_schedule_snooze', const ScheduleSnoozePage()),
        // 文件预览器两个分支：文本 / 图片（合成 FileEntryDto，只证明分支能画）
        (
          '202_files_text_preview',
          const FilePreviewPage(
            entry: FileEntryDto(name: 'probe.txt', path: '/probe.txt', size: 12),
          ),
        ),
        (
          '203_files_image_preview',
          const FilePreviewPage(
            entry: FileEntryDto(name: 'probe.png', path: '/probe.png', size: 12),
          ),
        ),
      ];
      for (final (shot, page) in (_kOnly ? const <(String, Widget)>[] : probes)) {
        await _probePage(tester, shot, page, '③g');
      }

      // ---- `_OfficeVersionsPage`（Drive 版本历史里**Office 原生文档**那一路）
      //   ★ 它和 `OfficeVersionsReadOnlyPage` 是**两条不同的数据路**
      //     （`SYNO.Office.Node.Version` vs Office 版本列表）：只验后者等于没验前者。
      //   进法：`DriveRevisionsPage` 的 build 在「.odoc/.osheet/.oslides + permanentLink」
      //   时**直接返回** `_OfficeVersionsPage` —— 所以一个合成 entry 就能把它点名开出来。
      await _probePage(
        tester,
        '204_drive_versions_office',
        const DriveRevisionsPage(
          entry: DriveEntryDto(
            fileId: 'probe-office-1',
            name: 'probe.odoc',
            type: 'file',
            path: '/probe.odoc',
            displayPath: '/My Drive/probe.odoc',
            parentId: '0',
            size: 1024,
            modifiedTime: 1700000000,
            createdTime: 1700000000,
            contentType: 'application/vnd.synology.odoc',
            starred: false,
            shared: false,
            owner: 'probe',
            canDownload: true,
            canPreview: true,
            canWrite: false,
            capabilities: <String, dynamic>{},
            permanentLink: 'probe-permanent-link',
          ),
        ),
        '③h',
      );

      // ==================== ③i 收尾清扫：r703 深扫**没点名**的页面类
      // Linux r697 的「只开页不提交」纪律照搬：只把页面**推上来**、抓像素、
      // 记一条事实，不点任何写动作（不新建/不保存/不上传/不加入/不删除）。
      // 每一行都是 `docs/windows-page-coverage.md` 里原本记 U 的页面类 ——
      // 这一段的唯一目的就是**逐个点名**，把「没验过」变成「验过或说清为什么」。
      // ★ `DiagPage` 用 `autoRun: false`：真跑诊断会打原生探针（不属于"打开页面"）。
      final sweep = <(String, Widget)>[
        ('205_admin_tools_page', const AdminToolsPage()),
        ('206_ai_model_page', const AiModelPage()),
        ('207_audio_cast_page', const AudioCastPage()),
        ('208_audio_pins_page', const AudioPinsPage()),
        ('209_audio_remote_page', const AudioRemotePage()),
        ('210_audio_web_queue_page', const AudioWebQueuePage()),
        ('211_archive_page', const ArchivePage()),
        ('212_available_channels_page', const AvailableChannelsPage()),
        ('213_channel_list_page', const ChannelListPage()),
        ('214_global_content_page', const GlobalContentPage()),
        ('215_diag_page', const DiagPage(autoRun: false)),
        ('216_download_bt_search_page', const DownloadBtSearchPage()),
        ('217_download_emule_page', const DownloadEmulePage()),
        ('218_download_emule_search_page', const DownloadEmuleSearchPage()),
        ('219_download_emule_server_page', const DownloadEmuleServerPage()),
        ('220_download_rss_page', const DownloadRssPage()),
        ('221_download_settings_page', const DownloadSettingsPage()),
        ('222_drive_computers_page', const DriveComputersPage()),
        ('223_drive_connections_page', const DriveConnectionsPage()),
        ('224_drive_extras_page', const DriveExtrasPage()),
        ('225_drive_file_request_page', const DriveFileRequestPage()),
        ('226_drive_notifications_page', const DriveNotificationsPage()),
        ('227_drive_quota_page', const DriveQuotaPage()),
        ('228_drive_search_page', const DriveSearchPage()),
        ('229_drive_sync_tasks_page', const DriveSyncTasksPage()),
        ('230_drive_team_members_page', const DriveTeamMembersPage()),
        ('231_drive_team_trash_page', const DriveTeamTrashPage()),
        ('232_drive_trash_page', const DriveTrashPage()),
        ('233_login_page', const LoginPage()),
        ('234_note_adv_search_page', const NoteAdvSearchPage()),
        ('235_note_background_sync_page', const NoteBackgroundSyncPage()),
        ('236_note_fts_search_page', const NoteFtsSearchPage()),
        ('237_note_joined_page', const NoteJoinedPage()),
        ('238_note_overdue_settings_page', const NoteOverdueSettingsPage()),
        ('239_note_recycle_page', const NoteRecyclePage()),
        ('240_note_shared_page', const NoteSharedPage()),
        ('241_note_shelf_page', const NoteShelfPage()),
        ('242_note_shortcut_page', const NoteShortcutPage()),
        ('243_note_smart_page', const NoteSmartPage()),
        ('244_note_tag_page', const NoteTagPage()),
        ('245_note_todo_page', const NoteTodoPage()),
        ('246_photo_admin_page', const PhotoAdminPage()),
        ('247_photo_ai_edit_settings_page', const PhotoAiEditSettingsPage()),
        ('248_photo_background_tasks_page', const PhotoBackgroundTasksPage()),
        ('249_photo_backup_page', const PhotoBackupPage()),
        ('250_photo_c2_page', const PhotoC2Page()),
        ('251_photo_free_up_space_page', const PhotoFreeUpSpacePage()),
        ('252_photo_map_page', const PhotoMapPage()),
        ('253_photo_migration_page', const PhotoMigrationPage()),
        ('254_photo_persons_page', const PhotoPersonsPage()),
        ('255_sleep_backup_page', const SleepBackupPage()),
        ('256_nas_manager_page', const NasManagerPage()),
        ('257_bots_page', const BotsPage()),
        ('258_e2ee_page', const E2eePage()),
        ('259_notification_settings_page', const NotificationSettingsPage()),
        ('260_oem_keepalive_page', const OemKeepalivePage()),
        ('261_personal_profile_page', const PersonalProfilePage()),
        ('262_service_check_page', const ServiceCheckPage()),
        ('263_settings_page', const SettingsPage()),
        ('264_snooze_settings_page', const SnoozeSettingsPage()),
      ];
      for (final (shot, page) in (_kOnly ? const <(String, Widget)>[] : sweep)) {
        await _probePage(tester, shot, page, '③i');
      }
    });

    // ==================== ③k 外壳两页 + 「慢页」个人资料（r705）
    //
    // ★ 上一轮（r704）把 60 个零参数页抓完，只剩 6 条 U。这 3 条**能测**，
    //   只是各有装置原因，所以单列一段：
    //   1) `AppShellPage` / `HomePage`：r703/r704 深扫**整轮都在用**它们，但按口径
    //      「单独推上来抓一张」才算该页的像素证据 —— 这一段的全部意义就是补这一张。
    //   2) `PersonalProfilePage`：r704 抓到的是一颗加载圈。宿主侧实测这台 NAS
    //      **一次登录往返就 4.8 s**，所以 5 s 的 settle 判不了"出不出内容"
    //      ⇒ 这里给它 **25 s**，把"慢"和"卡死"分开（判据不变，只是多等）。
    await step('③k 外壳两页 + 慢页复核（AppShell / Home / 个人资料 25 s）',
        () async {
      await _probePage(tester, '265_app_shell_page', const AppShellPage(), '③k');
      await _probePage(tester, '266_home_page', const HomePage(), '③k');
      await _probePageSlow(
        tester,
        '267_personal_profile_slow',
        const PersonalProfilePage(),
        '③k',
        settle: const Duration(seconds: 25),
      );
    });

    // ==================== ③l 私有子页：`_InviteMembersPage`（r706）
    //
    // ★ 它是 `ChannelMembersPage` 里 `_invite()` push 的**私有路由**，
    //   没有构造参数以外的入口 ⇒ 只能「进频道成员页 → 点『邀请成员』」把它打开。
    // ★ **只开面板，不发邀请**：面板里的勾选/发送一个都不点（写动词 = 0）。
    //   进「成员页」本身不是"进频道"（不标已读），也不发任何写请求。
    // ★ 频道 id **从会话里现取**（`channelsProvider` 的只读流），不写死 ——
    //   r703 的 `169_chat_members` 就是因为写死 `channelId: 1` 才落到错误态。
    await step('③l 私有子页 `_InviteMembersPage`（只开面板、不发邀请）', () async {
      await _resetToShell(tester);
      final chans =
          container.read(channelsProvider).value ?? const <ChannelDto>[];
      // ★ 只挑**公开/私有频道**：`inviteAllowed` 要求 `type == 'public' | 'private'`，
      //   而且 `#1`（我的空间）与聊天机器人恒不给邀请（见页面里的原版注释）。
      //   私聊（type=chat）没有『邀请』入口 —— r706 第一版就是撞在这里。
      final cands = chans
          .where((c) =>
              c.isPublicOrPrivate && c.channelId != 1 && !c.isChatBotType)
          .take(3)
          .toList();
      _note('③l 候选频道=${cands.length}：'
          '${cands.map((c) => '${c.channelId}/${c.type}').join(', ')}');
      if (cands.isEmpty) {
        _note('③l SKIP：会话里还没有公开/私有频道');
        return;
      }
      for (final ch in cands) {
        await _push(tester, ChannelMembersPage(channelId: ch.channelId));
        await _wait(tester, 7000);
        final inv = find.byIcon(Icons.person_add_alt);
        _note('③l 频道 ${ch.channelId}（${ch.type}）邀请按钮=${inv.evaluate().length}');
        if (inv.evaluate().isNotEmpty) {
          await tester.tap(inv.first);
          await _wait(tester, 7000); // 面板要拉一次用户列表（只读）
          await _shot(tester, '268_invite_members_page');
          _dumpUi(tester, '③l 268_invite_members_page');
          _note('③l 268_invite_members_page：Scaffold='
              '${find.byType(Scaffold).evaluate().length}，'
              'Text=${find.byType(Text).evaluate().length}');
          final close = find.byIcon(Icons.close);
          if (close.evaluate().isNotEmpty) {
            await tester.tap(close.first);
            await _wait(tester, 600);
          }
          return;
        }
      }
      _note('③l PROBE-SKIP 268：候选频道都没有『邀请』入口（ACL 不给邀请）');
    });

    // ==================== ③m 私有子 widget：`_SlidePage`（r706）
    //
    // ★ `_SlidePage` 是 `.oslides` 查看器里**每页幻灯片**的 widget
    //   （`office_viewer_page.dart::_slidePager` 的 itemBuilder），没有构造参数以外的入口。
    // ★ 走**用户路径**打开：Office 首页 → 点一个 `.oslides` 条目 → 预览页
    //   （`OfficeNativeViewer`）→ 解析 sections → 渲染逐页幻灯片。**全程只读**：
    //   不新建、不上传、不改名，只 `get`。
    // ★ 选 `Celestial.oslides`（3.3 KB，最少页数 ⇒ 最快出首屏）；找不到就退到第一个 `.oslides`。
    await step('③m 私有子 widget `_SlidePage`（只读打开 .oslides 预览）', () async {
      await _resetToShell(tester);
      final api = container.read(driveApiProvider);
      if (api == null) {
        _note('③m SKIP：driveApi 还没就绪');
        return;
      }
      // ★ 只读列目录找 `.oslides`（不做 drive 的 access 上报 —— 那是一次写动词，
      //   所以我们**绕开** `openDriveEntry`，直接推 `OfficeNativeViewer`）。
      final hits = <DriveEntryDto>[];
      Future<void> scan(String path, int depth) async {
        if (depth > 1) return;
        final r = await api.list(path: path, limit: 200);
        hits.addAll(r.items.where((e) => e.name.toLowerCase().endsWith('.oslides')));
        for (final d in r.items.where((e) => e.isDir).take(4)) {
          await scan(d.displayPath, depth + 1);
        }
      }

      try {
        await scan(kDriveRoot, 0);
      } catch (e) {
        _note('③m 列目录失败：$e');
      }
      // ★ 选**体积最大**的那份：`Celestial.oslides`（3.3 KB）只有 1 页且无文本，
      //   空态能证明 `_SlidePage` 被 build 出来，但证明不了**有文本**那一支。
      //   `Dynamic.oslides`（8.8 MB）带真实内容 ⇒ 同一段里两条分支都留读数。
      hits.sort((a, b) => b.size.compareTo(a.size));
      final found = hits.isEmpty ? null : hits.first;
      if (found == null) {
        _note('③m PROBE-SKIP 269：Drive 里没找到 .oslides');
        return;
      }
      _note('③m .oslides 命中=${hits.map((e) => '${e.name}(${e.size}B)').join(', ')}');
      _note('③m 选中 ${found.name} path=${found.displayPath} '
          'link=${found.permanentLink.isEmpty ? '-' : found.permanentLink}');
      await _push(
        tester,
        OfficeNativeViewer(
          entry: driveEntryAsFile(found),
          linkId: found.permanentLink,
          drivePath: found.displayPath,
          onDownload: () {},
          onOpen: () {},
        ),
      );
      await _wait(tester, 40000); // Snapshot:get → sections → 逐页布局（8.8 MB 要慢些）
      await _shot(tester, '269_slide_page');
      _dumpUi(tester, '③m 269_slide_page');
      _note('③m 269_slide_page：Scaffold=${find.byType(Scaffold).evaluate().length}'
          '，PageView=${find.byType(PageView).evaluate().length}'
          '，Text=${find.byType(Text).evaluate().length}');
    });

    // ==================== ③n 私有路由：`_LyricsFullPage`（r706）
    //
    // ★ 它是单曲页歌词卡片标题（≥48dp 热区，右侧写「全屏歌词」）点出来的**私有路由**
    //   （`audio_song_page.dart::_openFullLyrics`），只有拿到 `LrcDocument` 才存在。
    // ★ 全程只读：`Song.list` 取一首歌 → 单曲页（**不点播放**）→ 等歌词解析 →
    //   点标题进全屏歌词。不写任何东西。
    await step('③n 私有路由 `_LyricsFullPage`（只点全屏歌词，不播放）', () async {
      await _resetToShell(tester);
      final page = await container.read(audioRandom100Provider.future);
      final all = page.items.where((s) => s.id.isNotEmpty).toList();
      _note('③n 库里歌曲=${all.length}');
      // ★ 先把歌单**照实**吐出来（只读 `Song.list`）。r706 第一版直接拿前三首试，
      //   三首都是讲课录音 ⇒ 等不到 `LrcDocument`；这批清单拿去和公开歌词库核对，
      //   才知道"该用哪首"（不是猜，是查）。
      _note('③n TITLES=${all.map((s) => '${s.title}||${s.artist}').join(' ## ')}');
      if (all.isEmpty) {
        _note('③n PROBE-SKIP 270：Audio Station 里没有歌');
        return;
      }
      // ★ 挑歌的**判据**：这 100 首里哪一首在公开歌词库（lrclib.net）真有词。
      //   歌单已打印在上面（`③n TITLES=…`），宿主侧逐条核过再回来——
      //   「猜一首流行歌」不算证据，`Song.list` 里有什么才是事实。
      // ★ 选歌**不猜、不写死**：拿页面同一套歌词源（lrclib）先只读试一遍，
      //   哪首真有词就用哪首。这台 NAS 上绝大多数是 Great Courses 讲课录音
      //   （`Lect.*` / `Track*`），公开源没有词 —— r706 前几版就是栽在这上面。
      // ★ 这一步只读公网 + 写**本机**歌词缓存；对 NAS 零写动词。
      final lookup = container.read(mediaLyricsLookupProvider);
      var song = all.first;
      var found = false;
      var tried = 0;
      for (final s in all.take(40)) {
        tried++;
        try {
          final r = await lookup.search(
            LyricsQuery(title: s.title, artist: s.artist),
          );
          if (r.document != null && !r.document!.isEmpty) {
            song = s;
            found = true;
            _note('③n 有公开歌词：${s.title}/${s.artist}'
                '（doc=${r.document!.lines.length} 行，chosen=${r.chosen?.id}）');
            break;
          }
        } catch (e) {
          _note('③n 查歌词失败（${s.title}）：$e');
        }
      }
      _note('③n 试过 $tried 首，命中=$found；选歌=${song.title}/${song.artist}'
          ' id=${song.id}');
      if (!found) {
        _note('③n PROBE-SKIP 270：前 $tried 首在公开源都没有词 '
            '（这台库是讲课录音为主）⇒ 没有 `LrcDocument`，私有路由不存在');
        await _shot(tester, '270_lyrics_full_page');
        return;
      }
      await _push(
        tester,
        AudioSongDetailPage(songId: song.id, title: song.title),
      );
      // 歌词是异步查的（`Lyrics.getlyrics` → lrclib），给足时间但**不点播放**
      await _wait(tester, 20000);
      var full = find.textContaining('全屏歌词');
      _note('③n 「全屏歌词」入口数=${full.evaluate().length}（首轮）');
      if (full.evaluate().isEmpty) {
        // 还没词就按页面自己的入口让它在公网源里搜一次（`as-lyrics-search`，只读）
        final search = find.byKey(const Key('as-lyrics-search'));
        _note('③n 「搜歌词」按钮数=${search.evaluate().length}');
        if (search.evaluate().isNotEmpty) {
          await tester.ensureVisible(search.first);
          await _wait(tester, 300);
          await tester.tap(search.first);
          await _wait(tester, 15000);
        }
        full = find.textContaining('全屏歌词');
        _note('③n 「全屏歌词」入口数=${full.evaluate().length}（搜过之后）');
        // 公开源会 503/超时（实测 lrclib 时不常「ServerOverloaded」）⇒ 再点一次
        if (full.evaluate().isEmpty && search.evaluate().isNotEmpty) {
          await tester.tap(search.first);
          await _wait(tester, 20000);
          full = find.textContaining('全屏歌词');
          _note('③n 「全屏歌词」入口数=${full.evaluate().length}（第二次搜完）');
        }
      }
      if (full.evaluate().isEmpty) {
        await _shot(tester, '270_lyrics_full_page');
        _dumpUi(tester, '③n 270 未出现全屏入口');
        _note('③n PROBE-SKIP 270：「全屏歌词」入口没出现（没有 `LrcDocument`）');
        return;
      }
      await tester.ensureVisible(full.first);
      await _wait(tester, 400);
      await tester.tap(full.first);
      await _wait(tester, 5000);
      await _shot(tester, '270_lyrics_full_page');
      _dumpUi(tester, '③n 270_lyrics_full_page');
      _note('③n 270_lyrics_full_page：Scaffold='
          '${find.byType(Scaffold).evaluate().length}，'
          'Text=${find.byType(Text).evaluate().length}');
    });

/// 从 `ui.Image` 采样**不同颜色数**（每 [step] 像素取一个点）。
///
/// ★ 为什么必须有这一条：`bytes.length > 0` 证明不了"抽到的是画面"——
///   全黑图也有字节。判据与 r703 出帧同款：**画面要有内容**。
Future<int> sampleFrameColors(ui.Image image, {int step = 8}) async {
  final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (raw == null) return 0;
  final bytes = raw.buffer.asUint8List();
  final w = image.width;
  final h = image.height;
  final seen = <int>{};
  for (var y = 0; y < h; y += step) {
    for (var x = 0; x < w; x += step) {
      final i = (y * w + x) * 4;
      if (i + 3 >= bytes.length) continue;
      seen.add((bytes[i] << 24) | (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3]);
    }
  }
  return seen.length;
}

    // ==================== ③o Windows 抽帧后端（r707）
    //
    // ★ r707 的三次试跑读数是**同一类坑**，记在这里（别再重踩）：
    //   ① `videoFrameDetailedLoaderProvider` 是**非 autoDispose** ⇒ 相册页先读过
    //      就把"不可用"的 no-op 闭包定死了（第一次 `platformUnavailable=true`）；
    //   ② 定死之后就算作废重读，**能力门**也必须在建 App 之前打开
    //      （`SYN_WIN_FORCE_FRAMES`），否则相册页根本不会去抽帧；
    //   ③ 最关键的一条：**"mpv 打得开" ≠ "有视频轨"**。相册里唯一那个
    //      `SVID_*.mp4` 在 guest 里的读数是 `dur=15665ms playing=true
    //      width=nullxnull vp=nullxnull errors=[]` —— 文件能播、有声、**没有视频轨**
    //      ⇒ 任何截图策略都只能拿 0 字节（A_pause/B_play/C_raw/D_seek 四变体
    //      全是 `jpeg=0B png=0B width=[]`）。**先查数据前提**（r706 ① 同款教训）。
    //   ⇒ 判据必须钉在"**轨道表里有 video**"上，且候选要跨相册/Drive 找**真有视频轨**的样本。
    // ★ 全程只读：相册列表 + `SYNO.Foto.Download` / Drive 的 Range 取头片段。
    await step('③o Windows 抽帧后端（libmpv → 真帧 + 整条流水线）', () async {
      final host = AppPlatformCapabilities.current().host;
      _note('③o 宿主=$host，能力门=${capabilityGateAllows(AppCapability.videoFrameExtraction)}'
          '（翻位后这里必须是 true，**不许**靠 SYN_WIN_FORCE_FRAMES）'
          '，Mpv 后端 hostSupported=${MpvVideoFrameExtractor.hostSupported()}');
      if (!capabilityGateAllows(AppCapability.videoFrameExtraction)) {
        _note('③o PROBE-SKIP 271：能力门还是 false（先翻位再跑这一段）');
        return;
      }

      final dir = await getTemporaryDirectory();
      final tmpDir = Directory('${dir.path}/r707_frames');
      await tmpDir.create(recursive: true);
      final fetchHead = container.read(videoFrameHeadFetcherProvider);

      // 候选：相册视频 + Drive 视频（只读列目录，最多两层）
      final cands = <({String label, VideoFrameThumbRequest req})>[];
      final timeline = await container.read(photoTimelineProvider.future);
      final photos = timeline.items
          .where((i) =>
              kVideoFrameContainers.contains(normalizeMediaExtension(i.filename)))
          .toList()
        ..sort((a, b) => a.filesize.compareTo(b.filesize));
      final foto = container.read(fotoApiProvider);
      for (final item in photos.take(6)) {
        final req = photoVideoFrameRequest(item, foto, FotoSpace.personal);
        if (req == null) continue;
        cands.add((label: 'photos:${item.filename}', req: req));
      }
      final api = container.read(driveApiProvider);
      if (api != null) {
        final hits = <DriveEntryDto>[];
        Future<void> scan(String path, int depth) async {
          if (depth > 1) return;
          try {
            final r = await api.list(path: path, limit: 200);
            hits.addAll(r.items.where((e) =>
                !e.isDir &&
                kVideoFrameContainers
                    .contains(normalizeMediaExtension(e.name))));
            for (final d in r.items.where((e) => e.isDir).take(4)) {
              await scan(d.displayPath, depth + 1);
            }
          } catch (e) {
            _note('③o Drive 列目录失败（$path）：$e');
          }
        }

        await scan(kDriveRoot, 0);
        hits.sort((a, b) => a.size.compareTo(b.size));
        _note('③o Drive 视频候选=${hits.length}'
            '${hits.isEmpty ? '' : '：${hits.take(5).map((e) => '${e.name}(${e.size}B)').join(', ')}'}');
        for (final f in hits.take(6)) {
          final entry = driveEntryAsFile(f);
          final source = resolveEntryMediaSource(
            entry: entry,
            kind: MediaKind.video,
            fs: container.read(fileApiProvider),
            drive: api,
          );
          final req = videoFrameThumbRequestFor(entry, source);
          if (req == null) continue;
          cands.add((label: 'drive:${f.name}', req: req));
        }
      }
      _note('③o 候选总数=${cands.length}（相册 ${photos.length} + Drive）');
      if (cands.isEmpty) {
        _note('③o PROBE-SKIP 271：没有任何视频候选');
        return;
      }

      final loader = container.read(videoFrameDetailedLoaderProvider);
      var noVideoTrack = 0;
      for (final c in cands) {
        // ① 先确认**真的有视频轨**（r707 教训：能播 ≠ 有视频轨）
        Uint8List? head;
        try {
          head = await fetchHead(c.req, maxBytes: 8 * 1024 * 1024);
        } on Object catch (e) {
          _note('③o ${c.label} 取字节失败：$e');
          continue;
        }
        if (head.isEmpty) {
          _note('③o ${c.label} 取到 0 字节');
          continue;
        }
        final file = File('${tmpDir.path}/probe_$noVideoTrack.bin');
        await file.writeAsBytes(head, flush: true);
        final info = await probeMpvTracks(file);
        await file.delete();
        _note('③o ${c.label} ${head.length}B → $info');
        if (info.contains('video=0')) {
          noVideoTrack++;
          continue;
        }

        // ② 走**生产流水线**（下头片段 → 落盘 → 抽帧 → 缩放），不是直接调 extract
        final sw = Stopwatch()..start();
        final outcome = await loader(c.req);
        sw.stop();
        _note('③o ${c.label} 流水线：bytes=${outcome.bytes?.length ?? 0}，'
            'platformUnavailable=${outcome.platformUnavailable}，'
            'stage=${outcome.failure?.stage}，耗时=${sw.elapsedMilliseconds}ms');
        final bytes = outcome.bytes;
        if (bytes == null || bytes.isEmpty) continue;

        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final img = frame.image;
        final colors = await sampleFrameColors(img);
        _note('③o 像素 271_video_frame：${img.width}x${img.height}，'
            '采样色数=$colors，magic=${bytes[0].toRadixString(16)}');
        img.dispose();
        codec.dispose();
        if (colors < 8) {
          _note('③o ${c.label} 抽到的帧几乎是纯色（色数=$colors）⇒ 不算证据');
          continue;
        }
        final ev = File('${_shotDir.path}/271_video_frame.png');
        await ev.writeAsBytes(bytes, flush: true);
        _note('SHOT 271_video_frame → ${ev.path} (${bytes.length}B, 色数=$colors)');
        _note('③o PASS 抽帧后端与生产流水线都成立（${c.label}）');
        return;
      }
      _note('③o PROBE-SKIP 271：候选里没有"有视频轨且真出帧"的样本'
          '（无视频轨 $noVideoTrack 个）');
    });

    // ==================== ③p 凭据落盘：**读实际键值**，别读文件字节（r707）
    //
    // ★ 装置教训：直接 `ReadAllBytes(synhub.sqlite)` 找子串**证明不了"行还在"**
    //   —— SQLite 的空闲页/旧版本页会留着被删字符串。判据必须读**当前键值**：
    //   `nas_configs` / `saved_session` 里每条 `secret_sealed` 是 true 还是 false、
    //   值里有没有明文口令。
    await step('③p 凭据落盘：读键值判断"有没有明文行"', () async {
      final st = container.read(chatStoreProvider);
      const pw = 'demo_admin-qq';

      /// 报"哪个字段脏"——**不打印字段值**（凭据不进日志）。
      void reportEntry(String label, Map<String, dynamic> m) {
        final dirty = <String>[];
        for (final e in m.entries) {
          if ('${e.value}'.contains(pw)) dirty.add(e.key);
        }
        // ★ 只打印**非机密**字段（地址/账号/显示名/did），凭据本身永不进日志。
        _note('③p $label keys=${m.keys.toList()} '
            'sealed=${m['secret_sealed']} dirtyFields=$dirty '
            'kind=${m['kind']} value=${m['value']} '
            'account=${m['account']} display=${m['display_name']} '
            'did=${m['did']} last=${m['last_base_url']}');
      }

      Future<void> dump(String key) async {
        final v = await st.setting(key);
        if (v == null || v.isEmpty) {
          _note('③p $key=<空>');
          return;
        }
        final top = NasStore.decodeMap(v);
        if (top == null) {
          _note('③p $key 解析失败 len=${v.length} dirty=${v.contains(pw)}');
          return;
        }
        _note('③p $key len=${v.length} topKeys=${top.keys.toList()}');
        final items = top['items'];
        if (items is List) {
          for (var i = 0; i < items.length; i++) {
            final raw = items[i];
            final m = raw is String ? NasStore.decodeMap(raw) : null;
            if (m == null) {
              reportEntry('$key[$i]', top);
              continue;
            }
            reportEntry('$key[$i]', m);
          }
        } else {
          reportEntry(key, top);
        }
      }

      await dump('nas_configs');
      await dump('saved_session');
      final snap = await container.read(savedSessionStoreProvider).nas.load();
      _note('③p NasStore.load：条目=${snap.configs.length} '
          'active=${snap.activeId} partial=${snap.partial} '
          '密码可得=${snap.configs.where((c) => (c.password ?? '').isNotEmpty).length}');
      await dump('nas_configs');
      await dump('saved_session');
    });

    // ============================================================ 收尾
    await _resetToShell(tester);
    final pages = _report
        .where((l) =>
            l.startsWith('SHOT ') && RegExp(r'^SHOT \d{3}_').hasMatch(l))
        .length;
    final throws = _report.where((l) => l.startsWith('PROBE-THROW')).length;
    _note('DONE pages=$pages PROBE-THROW=$throws failures=${failures.length} '
        'dir=${_shotDir.path}');
    expect(failures, isEmpty);
  });
}

/// r707 装置诊断①：mpv 打开文件后**轨道表**长什么样。
///
/// 判据来源：`SVID_*.mp4` 的 `dur=15665ms playing=true width=nullxnull` 说明
/// "能播"完全不代表"有视频轨" —— 抽帧前必须先看轨道表。
Future<String> probeMpvTracks(File file) async {
  final player = Player(configuration: const PlayerConfiguration(muted: true));
  try {
    await player.open(Media(file.path), play: true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final t = player.state.tracks;
    return 'dur=${player.state.duration.inMilliseconds}ms '
        'video=${t.video.length} audio=${t.audio.length} '
        'width=${player.state.width}x${player.state.height}';
  } on Object catch (e) {
    return 'THROW ${e.runtimeType}: $e';
  } finally {
    try {
      await player.dispose();
    } on Object {
      // 诊断忽略释放异常
    }
  }
}

/// r707 装置诊断②：**真去截一帧**（先播到有画面再暂停再截；
/// mpv 的 `screenshot-raw` 只认"当前已解码的帧"，暂停在 0 位通常拿不到）。
Future<({Uint8List? bytes, String note})> probeMpvScreenshot(
  File file, {
  String strategy = 'H_vo_libmpv',
}) async {
  final sw = Stopwatch()..start();
  final vo = strategy.contains('libmpv') ? 'libmpv' : 'null';
  final player = Player(
    configuration: PlayerConfiguration(muted: true, vo: vo),
  );
  try {
    await player.open(Media(file.path), play: true);
    // ★★ 关键：media_kit 在 `_create()` 里写死 `--vid=no`（"省得白解码"），
    //   由 `VideoController` attach 时才改 `--vid=auto`。**没有 widget 就永远没有
    //   `vid=auto`** ⇒ 轨道表里有 video、`width` 恒 null、截图恒 0 字节。
    //   `Player.setVideoTrack(VideoTrack.auto())` 是公开 API，正是这一格的钥匙。
    await player.setVideoTrack(VideoTrack.auto());
    final got = Completer<void>();
    final sub = player.stream.width.listen((w) {
      if (w != null && w > 0 && !got.isCompleted) got.complete();
    });
    try {
      await got.future.timeout(const Duration(seconds: 6));
    } on TimeoutException {
      // 继续，下面照截一次
    } finally {
      await sub.cancel();
    }
    await player.seek(const Duration(milliseconds: 1000));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final shot = await player.screenshot(format: 'image/jpeg');
    return (
      bytes: shot,
      note: 'vo=$vo jpeg=${shot?.length ?? 0}B '
          'width=${player.state.width}x${player.state.height} '
          '${sw.elapsedMilliseconds}ms',
    );
  } on Object catch (e) {
    return (bytes: null, note: 'THROW ${e.runtimeType}: $e');
  } finally {
    try {
      await player.dispose().timeout(const Duration(seconds: 10));
    } on Object {
      // 诊断忽略释放异常
    }
  }
}
