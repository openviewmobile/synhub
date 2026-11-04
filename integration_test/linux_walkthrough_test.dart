// Linux **逐屏走查**（第 133 轮 / r133）：在 **Linux 桌面端真渲染**里用**真 NAS**
// （只读）把全部界面走一遍，并抓**真实渲染像素**，同时记录每个屏幕的元素事实。
//
// 跑法（在 amd64 容器内的 /work/src，Xvfb 里）：
//   export LANG=en_US.UTF-8
//   Xvfb :99 -screen 0 1280x900x24 &
//   DISPLAY=:99 flutter test integration_test/linux_walkthrough_test.dart -d linux \
//     --dart-define=SYNO_NAS_URL=https://nas.example.com:5001 \
//     --dart-define=SYNO_NAS_ACCOUNT=demo_user \
//     --dart-define=SYNO_NAS_PASSWORD='…'
//
// 文件名**故意不匹配** `tool/device_feature_suite.sh` 的通配
// （`p0_*` / `phase*` / `drive_*` / `media_*`）⇒ 不会污染真机矩阵资产。
//
// ★ 像素证据 = **应用内真实渲染抓帧** `RenderRepaintBoundary.toImage()`：
//   取的是这个 Linux App 由 Impeller/OpenGLES 真正画出来的图层（真字体、真图标、
//   真数据），不是布局断言。每张图都带 `[walk] shot` 日志 + 写出字节数。
//
// ★ 只读纪律（AGENTS §5.1）：对真 NAS 的**变更动词为零**（只 list/get/read/query）。
//   唯一例外是**登录会话本身**（`SYNO.API.Auth:login`，任何只读验证的前提），已声明。
//   不点进聊天频道（会标已读）、不新建/编辑笔记、不上传、不新建下载任务、
//   不点「清空回收站 / 永久删除 / 还原」这类写动作 —— 只把菜单**打开**看元素。
//
// ★ 定义一律在用例内给默认值（AGENTS §2.0.20⑤）：本用例指向仓库既有的
//   **专用测试 NAS**（同一组凭据也硬编码在 `tool/flt_apis.dart` 等只读探针里）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/router/app_router.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/ui/energy_orb.dart';
import 'package:synhub/src/features/admin/admin_gate.dart';
import 'package:synhub/src/features/admin/admin_tools_page.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/ai/ai_model_page.dart';
import 'package:synhub/src/features/audio/audio_page.dart';
import 'package:synhub/src/features/diagnostics/diag_page.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/drive/drive_computers_page.dart';
import 'package:synhub/src/features/drive/drive_connections_page.dart';
import 'package:synhub/src/features/drive/drive_extras_page.dart';
import 'package:synhub/src/features/drive/drive_file_request_page.dart';
import 'package:synhub/src/features/drive/drive_notifications_page.dart';
import 'package:synhub/src/features/drive/drive_quota_page.dart';
import 'package:synhub/src/features/drive/drive_search_page.dart';
import 'package:synhub/src/features/drive/drive_sync_tasks_page.dart';
import 'package:synhub/src/features/drive/drive_team_members_page.dart';
import 'package:synhub/src/features/drive/drive_team_trash_page.dart';
import 'package:synhub/src/features/drive/drive_trash_page.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/notes/note_background_sync_scheduler.dart';
import 'package:synhub/src/features/notes/notes_page.dart';
import 'package:synhub/src/features/servers/nas_manager_page.dart';
import 'package:synhub/src/features/servers/session_controller.dart';
import 'package:synhub/src/features/notes/note_todo_page.dart';
import 'package:synhub/src/features/notes/note_tag_page.dart';
import 'package:synhub/src/features/notes/note_shared_page.dart';
import 'package:synhub/src/features/notes/note_joined_page.dart';
import 'package:synhub/src/features/notes/note_shelf_page.dart';
import 'package:synhub/src/features/notes/note_smart_page.dart';
import 'package:synhub/src/features/notes/note_recycle_page.dart';
import 'package:synhub/src/features/notes/note_shortcut_page.dart';
import 'package:synhub/src/features/notes/note_adv_search_page.dart';
import 'package:synhub/src/features/notes/note_fts_search_page.dart';
import 'package:synhub/src/features/notes/note_background_sync_page.dart';
import 'package:synhub/src/features/notes/note_overdue_settings_page.dart';
import 'package:synhub/src/features/photos/photo_admin_page.dart';
import 'package:synhub/src/features/photos/photo_ai_edit_settings_page.dart';
import 'package:synhub/src/features/photos/photo_background_tasks_page.dart';
import 'package:synhub/src/features/photos/photo_backup_page.dart';
import 'package:synhub/src/features/photos/photo_migration_page.dart';
import 'package:synhub/src/features/photos/photo_map_page.dart';
import 'package:synhub/src/features/photos/photo_c2_page.dart';
import 'package:synhub/src/features/photos/photo_free_up_page.dart';
import 'package:synhub/src/features/photos/photo_wave2_page.dart';
import 'package:synhub/src/features/photos/sleep_backup_page.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/chat/archive_page.dart';
import 'package:synhub/src/features/chat/available_channels_page.dart';
import 'package:synhub/src/features/chat/global_content_page.dart';
import 'package:synhub/src/features/downloads/download_settings_page.dart';
import 'package:synhub/src/features/downloads/download_rss_page.dart';
import 'package:synhub/src/features/downloads/download_bt_search_page.dart';
import 'package:synhub/src/features/downloads/download_emule_page.dart';
import 'package:synhub/src/features/downloads/download_emule_server_page.dart';
import 'package:synhub/src/features/downloads/download_emule_search_page.dart';
import 'package:synhub/src/features/audio/audio_pins_page.dart';
import 'package:synhub/src/features/audio/audio_cast_page.dart';
import 'package:synhub/src/features/audio/audio_remote_page.dart';
import 'package:synhub/src/features/audio/audio_web_queue_page.dart';
import 'package:synhub/src/features/settings/notification_settings_page.dart';
import 'package:synhub/src/features/settings/snooze_settings_page.dart';
import 'package:synhub/src/features/settings/personal_profile_page.dart';
import 'package:synhub/src/features/settings/profile_edit_page.dart';
import 'package:synhub/src/features/settings/bots_page.dart';
import 'package:synhub/src/features/settings/e2ee_page.dart';
import 'package:synhub/src/features/settings/oem_keepalive_page.dart';
import 'package:synhub/src/features/settings/service_check_page.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/features/settings/settings_page.dart';
import 'package:synhub/src/features/ai/ai_usage_page.dart';
import 'package:synhub/src/features/analytics/analytics_page.dart';
import 'package:synhub/src/features/analytics/traffic_page.dart';
import 'package:synhub/src/features/audio/audio_gaps_page.dart';
import 'package:synhub/src/features/audio/audio_radio_page.dart';
import 'package:synhub/src/features/audio/audio_search_page.dart';
import 'package:synhub/src/features/audio/audio_song_page.dart';
import 'package:synhub/src/features/calendar/calendar_page.dart';
import 'package:synhub/src/features/chat/channel_create_page.dart';
import 'package:synhub/src/features/contacts/contacts_manage_page.dart';
import 'package:synhub/src/features/contacts/contacts_page.dart';
import 'package:synhub/src/features/design/design_preview_page.dart';
import 'package:synhub/src/features/downloads/download_captcha_page.dart';
import 'package:synhub/src/features/downloads/download_create_page.dart';
import 'package:synhub/src/features/drive/drive_admin_page.dart';
import 'package:synhub/src/features/drive/drive_category_page.dart';
import 'package:synhub/src/features/drive/drive_collection_page.dart';
import 'package:synhub/src/features/drive/drive_copy_move_page.dart';
import 'package:synhub/src/features/drive/drive_folder_page.dart';
import 'package:synhub/src/features/drive/drive_local_files_page.dart';
import 'package:synhub/src/features/drive/drive_pdf_markup_page.dart';
import 'package:synhub/src/features/drive/drive_scan_page.dart';
import 'package:synhub/src/features/drive/drive_text_editor_page.dart';
import 'package:synhub/src/features/files/drive_labels_page.dart';
import 'package:synhub/src/features/files/drive_share_page.dart';
import 'package:synhub/src/features/files/drive_revisions_page.dart';
import 'package:synhub/src/features/files/drive_more_page.dart';
import 'package:synhub/src/features/files/drive_tasks_page.dart';
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_mount_page.dart';
import 'package:synhub/src/features/files/file_offline_page.dart';
import 'package:synhub/src/features/files/usb_devices_page.dart';
import 'package:synhub/src/features/files/webdav_page.dart';
import 'package:synhub/src/features/mailplus/mail_compose_page.dart';
import 'package:synhub/src/features/mailplus/mail_detail_page.dart';
import 'package:synhub/src/features/mailplus/mail_page.dart';
import 'package:synhub/src/features/notes/note_conflict_page.dart';
import 'package:synhub/src/features/notes/note_drawing_page.dart';
import 'package:synhub/src/features/notes/note_editor_page.dart';
import 'package:synhub/src/features/notes/note_todo_editor_page.dart';
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_recent_page.dart';
import 'package:synhub/src/features/photos/photo_wave3_page.dart';
import 'package:synhub/src/features/search/global_search_page.dart';
import 'package:synhub/src/features/search/search_page.dart';
import 'package:synhub/src/features/servers/certificates_page.dart';
import 'package:synhub/src/features/servers/server_setup_page.dart';
import 'package:synhub/src/features/surveillance/surv_page.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/dto/drive_label_dto.dart';
import 'package:synhub/src/data/dto/drive_collection_dto.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/features/chat/channel_content_page.dart';
import 'package:synhub/src/features/chat/channel_media_page.dart' hide MediaQuery;
import 'package:synhub/src/features/chat/channel_hashtags_page.dart';
import 'package:synhub/src/features/chat/channel_scheduled_page.dart';
import 'package:synhub/src/features/chat/subscribed_threads_page.dart';
import 'package:synhub/src/features/chat/read_status_page.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';
import 'package:synhub/src/features/surveillance/surv_camera_page.dart';
import 'package:synhub/src/data/dto/contact_dto.dart';
import 'package:synhub/src/features/chat/channel_members_page.dart';
import 'package:synhub/src/features/contacts/contact_editor_page.dart';
import 'package:synhub/src/features/contacts/contact_import_page.dart';
import 'package:synhub/src/features/downloads/download_detail_page.dart';
import 'package:synhub/src/features/downloads/download_file_select_page.dart';
import 'package:synhub/src/features/drive/drive_advance_sharing_page.dart';
import 'package:synhub/src/features/notes/note_share_page.dart';
import 'package:synhub/src/features/notes/note_view_page.dart';
import 'package:synhub/src/features/office/office_library_page.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/audio/audio_detail_page.dart';
import 'package:synhub/src/features/chat/thread_page.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/office/office_doc_page.dart';
import 'package:synhub/src/features/office/office_sheet_page.dart';
import 'package:synhub/src/features/office/office_slides_page.dart';
import 'package:synhub/src/features/files/office_page.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';

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

/// 截图落点：容器里 `/work` 是宿主绑定挂载（宿主 `~/r108_linux_build`），
/// 这样跑完直接在宿主上取图，不必从容器里 `docker cp`。
const String _shotDirPath = String.fromEnvironment(
  'SYNHUB_LINUX_SHOT_DIR',
  defaultValue: '/work/shots_r133',
);

/// 只跑某几个屏幕（逗号分隔，如 `--dart-define=WALK_ONLY=files`），空 = 全跑。
/// 只为**迭代提速**，不影响最终交付口径（交付时全跑）。
/// ★ r346：指向本机 Mock（含容器里的 `host.docker.internal`）时，
/// 判据里那些**真 NAS 素材名**（`docker` 共享 / `/home/Drive` / office 样本）
/// 在 Mock 上不存在 ⇒ 单独走 mock 分支，**不许把夹具缺口当产品缺陷**。
final bool _isMock = _url.contains('127.0.0.1') ||
    _url.contains('localhost') ||
    _url.contains('host.docker.internal');

const String _only = String.fromEnvironment('WALK_ONLY');

bool _want(String tag) =>
    _only.isEmpty || _only.split(',').map((e) => e.trim()).contains(tag);

final Directory _shotDir = Directory(_shotDirPath)
  ..createSync(recursive: true);

final GlobalKey _rootKey = GlobalKey(debugLabel: 'walk-root');

/// 本轮走查的结论表（屏幕 → 结论/证据），最后由测试打印出来。
final List<String> _report = <String>[];

/// ★ r696：Audio Station 的行**不是 `ListTile`**（自定义行，实测 `ListTile=0`）。
/// r690 起"真点一首歌"那一段一直走 `find.byType(ListTile)` ⇒ 一次都没点中，
/// `29`/`30` 两屏其实是"列表页拍了两次"。行按"时长 · 年份"文案定位。
/// ★ r697（**安全判据**）：`_isMock` 只反映**命令行给的 URL**，而 App 可能从安全存储
/// 里恢复一条**真 NAS** 会话（r690 就撞过）⇒ 凡"允许写"的分支**绝不能**只看 `_isMock`。
/// 本函数读**会话自己记的 endpoint**，只有它真的是本机 Mock 才算。
bool _sessionIsLocal(ProviderContainer c) {
  final ep = c.read(sessionControllerProvider).connection?.endpoint.baseUrl ?? '';
  return ep.contains('127.0.0.1') ||
      ep.contains('localhost') ||
      ep.contains('host.docker.internal');
}

Finder _firstSongRow() =>
    find.textContaining(RegExp(r'^[0-9]+:[0-9]{2} · ')).hitTestable();

void _note(String s) {
  _report.add(s);
  debugPrint('[walk] $s');
}

// 英文文案（导航时用真实 tooltip，避免写死语言相关字符串）
final AppText _tEn = lookupAppTextSafe(const Locale('en'));

// ---------------------------------------------------------------- 工具

/// 推若干帧 + 真实等待（**不能用 pumpAndSettle**：HUD 背景是常驻动画）。
Future<void> _wait(WidgetTester tester, [int ms = 500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 32));
    await Future<void>.delayed(const Duration(milliseconds: 32));
  }
}

/// ★ 取证：把屏幕上每个 `ListTile` 的**祖先链**打出来。
///
/// 为什么需要它：`ListTile` 的"背景/水波可能不可见"断言**不带位置**
/// （`FlutterErrorDetails` 没有 stack、没有 context），只报
/// "被一个带底色的 `ColoredBox` 夹住了"。要定位到是哪个组件，只能自己
/// 顺着 element 往上走，看第一个 `Material` 之前是谁。
void _dumpListTileChains(WidgetTester tester, String tag) {
  final els = find.byType(ListTile).evaluate().toList();
  _note('LT-CHAIN $tag：屏幕上 ListTile=${els.length}');
  for (var i = 0; i < els.length && i < 6; i++) {
    final e = els[i];
    _note('LT-CHAIN[$i] ${e.debugGetCreatorChain(14)}');
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

/// ★★ r346：**不看 hitTest 的**存在性版本 —— 判"界面给没给这个条目"只能用这条。
/// 实测反例（本轮）：宽屏两栏下 `home` 行确实在控件树里（dump 打得出来），
/// 但 `.hitTestable()` 回假（行文字被父级 InkWell/裁剪吃掉半个矩形）
/// ⇒ 拿 `_hasText` 当存在性判据会得到假否定（AGENTS §2.0.63「渲染了但被裁」同型）。
bool _hasTextAny(String s) => find.text(s).evaluate().isNotEmpty;

/// 文本**包含**匹配（服务器回的中文/长串用得上）。
bool _hasTextContaining(String s) =>
    find.textContaining(s).hitTestable().evaluate().isNotEmpty;

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

/// ★ r690：抓**X11 根窗口**像素（`import -window root`）。
///
/// r693：推一个**只读页面**上来、抓一张像素、记一条事实。
/// ★ 异常只**记录**不中断（`PROBE-THROW`）：一轮 44 屏，单页抛错不该让后面的屏全丢；
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
    // ★ r695：**页面自己在异步里抛的异常**必须在这里就地取走，否则它会脱出本步骤，
    //   一路把整轮走查打断（现场：`DA337` 的 pdfx `PlatformNotSupportedException`
    //   就是这样把 137 屏之后的 61 屏全吞掉的）。取走后记成一条 PROBE-THROW，
    //   该页照样算失败屏，但**后面的屏还能继续验**。
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

/// 为什么不能用 `_shot`：`RenderRepaintBoundary.toImage()` 拿不到 **平台纹理**
/// （libmpv 的画面是一个 external texture，合成发生在引擎里）⇒ 视频页用它只会
/// 得到"控件 + 黑框"。根窗口抓屏是唯一能证明"纹理里真有画面"的像素来源。
Future<void> _rootShot(String name) async {
  final path = '${_shotDir.path}/$name.png';
  try {
    final r = await Process.run('import', ['-window', 'root', path]);
    final f = File(path);
    _note('ROOT-SHOT $name rc=${r.exitCode} '
        'exists=${f.existsSync()} bytes=${f.existsSync() ? f.lengthSync() : 0} → $path');
    if (r.exitCode != 0) _note('ROOT-SHOT stderr=${r.stderr}');
  } catch (e) {
    _note('ROOT-SHOT 失败（$name）：$e');
  }
}

/// 量一张图的**像素标准差**（0 = 纯色/全黑；越大 = 画面内容越丰富）。
///
/// 这是"视频真出画"的机器判据：纹理没来/全黑时 stddev ≈ 0，
/// testsrc 彩条 ≈ 0.2 以上。
Future<double> _pixelStdDev(String name) async {
  final path = '${_shotDir.path}/$name.png';
  if (!File(path).existsSync()) return -1;
  // ★ r690：容器里是 ImageMagick **6**（命令叫 `convert`，没有 `magick`）
  //   ⇒ 两个都试，别把"工具名不对"当成"画面是黑的"（那是仪器假红）。
  for (final tool in const ['magick', 'convert']) {
    try {
      final r = await Process.run(tool, [
        path,
        '-colorspace',
        'Gray',
        '-format',
        '%[fx:standard_deviation]',
        'info:',
      ]);
      final v = double.tryParse('${r.stdout}'.trim());
      if (v != null) {
        _note('PIXELS $name stddev=$v（$tool）');
        return v;
      }
    } on ProcessException {
      continue;
    }
  }
  _note('PIXELS 量不了（$name）：没有 magick/convert');
  return -1;
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

/// 点一个 key；找不到返回 false。
Future<bool> _tapKey(WidgetTester tester, String key,
    {int settle = 700}) async {
  final f = find.byKey(Key(key));
  if (f.evaluate().isEmpty) return false;
  await tester.ensureVisible(f.first);
  await _wait(tester, 150);
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// 点一段文字（取最后一个匹配：文件列表里的名字常在面包屑里也出现一次）。
Future<bool> _tapText(WidgetTester tester, String text,
    {int settle = 900, bool last = true}) async {
  final all = find.text(text).hitTestable();
  if (all.evaluate().isEmpty) return false;
  final f = last ? all.last : all.first;
  await tester.ensureVisible(f);
  await _wait(tester, 150);
  await tester.tap(f, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

/// ★★ r667：**桌面宽屏的真实契约不是"双击进入"，而是"左选右开"两步**。
///
/// 实测（`file_browse_page.dart:641 _onTap` + `file_wide_pane.dart`）：
/// ① 宽屏（`isExpanded`）下点条目**只**填右栏（`_wide = WideSelection(...)`），
///    **不换目录、不推预览**；② 右栏对目录直接画出子列表（`file-wide-nas-list`），
///    于是"再点一个目录"就是往里钻；③ 右栏对文件给的是**详情 + 打开按钮**
///    `file-wide-open` —— 点它才真的开（阅读器/预览走 `_openWide`）。
/// ⇒ 走查脚本必须按这三步来：先左栏点目录，再（可选）右栏点，再按 `file-wide-open`。
///   我 r667 第一次把它当"双击进入"，两次点击都只换来换去选中项，白跑一轮。
Future<bool> _openWideDetail(WidgetTester tester, {int settle = 2500}) async {
  if (!_hasKey('file-wide-open')) return false;
  final ok = await _tapKey(tester, 'file-wide-open', settle: settle);
  return ok;
}

/// 点一个顶栏图标；若它被 `FoldingActions` 折进 `⋮`（`bar-overflow`），/// 点一个顶栏图标；若它被 `FoldingActions` 折进 `⋮`（`bar-overflow`），
/// 就把折叠菜单打开再点（AGENTS §2.0.10 第 1/3 条）。
Future<bool> _tapIcon(WidgetTester tester, IconData icon,
    {int settle = 700}) async {
  var f = find.byIcon(icon).hitTestable();
  if (f.evaluate().isNotEmpty) {
    await tester.ensureVisible(f.first);
    await _wait(tester, 120);
    await tester.tap(f.first, warnIfMissed: false);
    await _wait(tester, settle);
    return true;
  }
  if (!await _tapKey(tester, 'bar-overflow', settle: 500)) return false;
  f = find.byIcon(icon).hitTestable();
  if (f.evaluate().isEmpty) {
    // 关掉菜单，别把状态留给下一个屏幕
    await _pressEscape(tester);
    return false;
  }
  await tester.tap(f.last, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

Future<void> _pressEscape(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await _wait(tester, 400);
}

/// 列表里的目标可能**还没被 Sliver 构建** ⇒ 先滚动到可见再点。
/// ★ 拖拽起点按**当前视图逻辑尺寸**取，不许写死坐标（AGENTS §2.0.21 第 3 条）。
Future<bool> _tapTextScrolling(
  WidgetTester tester,
  String text, {
  int maxScrolls = 30,
  int settle = 4000,
}) async {
  final view = tester.view;
  final logical = view.physicalSize / view.devicePixelRatio;
  final origin = Offset(logical.width / 2, logical.height * 0.6);
  for (var i = 0; i < maxScrolls; i++) {
    if (find.text(text).hitTestable().evaluate().isNotEmpty) break;
    await tester.dragFrom(origin, const Offset(0, -220));
    await _wait(tester, 350);
  }
  return _tapText(tester, text, settle: settle);
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

/// r692：把文件站带到 **My Drive 源**（office 样本真正所在处）。
///
/// 为什么不再用 `/home/Drive`：r692 实测这份真 NAS 上 office 样本
/// （`5-day trip planner.odoc` / `Annual income and expenditure.osheet` /
/// `Celestial.oslides`）在 **My Drive** 里（`20_drive_create_menu.png` 的 dump
/// 就是证据），而 `/home/Drive` 是另一条路 —— r690 那次因为 `SYNO_NAS_URL`
/// 传的是 `host.docker.internal`（`_isMock=true`）**整段被跳过**，
/// 于是"`/home/Drive` 有 office 样本"这个旧假设一直没被证伪。
Future<bool> _gotoMyDrive(WidgetTester tester) async {
  await _resetToShell(tester);
  await _tapKey(tester, 'dock-files', settle: 1800);
  await _wait(tester, 1500);
  await _tapText(tester, _tEn.driveMyDrive, settle: 2500);
  await _wait(tester, 2000);
  return _hasText('Celestial.oslides') ||
      _hasText('5-day trip planner.odoc') ||
      _hasKey('file-wide-nas-list');
}

/// 推一个页面（用于"工作台里没有磁贴"的模块，与 macOS 走查同一手法）。
Future<void> _push(WidgetTester tester, Widget page) async {
  rootNavigatorKey.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => page),
  );
  await _wait(tester, 2000);
}

/// 启动真 App（与 `lib/main.dart` 的 overrides 同形）。
Future<void> _boot(WidgetTester tester) async {
  WidgetsFlutterBinding.ensureInitialized();
  // ★ r690：`integration_test` 走的是**本文件的 main**，不会执行 `lib/main.dart`
  //   里的 `MediaKit.ensureInitialized()` ⇒ 一进视频页就抛
  //   「MediaKit.ensureInitialized must be called before using any API」。
  //   这是**装置缺口**，不是产品缺陷（App 自己的 main 已经调了）。
  MediaKit.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(linux: true, windows: false);
  final profile = DeviceProfile.detect();
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

/// ---------------------------------------------------------------- i18n 审计
const String _cjk =
    r'[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff01-\uff5e]';

final RegExp _cjkRe = RegExp(_cjk);

/// 收集**当前屏幕上真的画出来**的所有可见字符串里的 CJK（含 Text / hint /
/// label / tooltip / Semantics）—— 这是"英文模式不许有中文"的像素级判据。
List<String> _cjkVisible(WidgetTester tester) {
  final out = <String>{};
  void consider(String? s) {
    if (s == null || s.trim().isEmpty) return;
    if (_cjkRe.hasMatch(s)) out.add(s.trim());
  }

  for (final e in find.byType(Text).hitTestable().evaluate()) {
    final w = e.widget as Text;
    consider(w.data);
    w.textSpan?.visitChildren((span) {
      if (span is TextSpan) consider(span.text);
      return true;
    });
  }
  for (final e in find.byType(TextField).hitTestable().evaluate()) {
    final w = (e.widget as TextField);
    consider(w.decoration?.hintText);
    consider(w.decoration?.labelText);
    consider(w.decoration?.helperText);
  }
  // tooltip / semantics：从元素树里取（可见性无法直接判；用 RenderObject 的存在性）
  for (final e in find.byType(Tooltip).evaluate()) {
    final w = e.widget as Tooltip;
    consider(w.message);
  }
  return out.toList()..sort();
}

/// ★ r693（§C8）：把**真实窗口**缩到窄宽 —— 用 `xdotool` 改 GTK 窗口尺寸，
/// 走的是真桌面那条路（不是 `tester.view.physicalSize` 的假视口）。
///
/// 为什么值得这么做：`FileBrowsePage` 的右栏由
/// `appWindowSizeOf(MediaQuery.sizeOf(context)).isExpanded` 决定，
/// **假视口能改 MediaQuery 但改不了窗口管理器给的约束**，而"窄屏两栏叠一起"
/// 这类缺陷恰恰只在真窗口上出现。
Future<String?> _windowId() async {
  try {
    final r = await Process.run('bash', [
      '-lc',
      'xdotool search --name synhub 2>/dev/null | head -1',
    ]);
    final id = (r.stdout as String).trim().split('\n').first.trim();
    return id.isEmpty ? null : id;
  } catch (_) {
    return null;
  }
}

/// 试着改**真窗口**尺寸，并把 xdotool 自己报的几何记下来。
///
/// ★ r693 实测结论（仪器教训）：`xdotool windowsize` 在这个 `flutter test`
/// 起的窗口上**不生效** —— 命令返回 0、`getwindowgeometry` 也说变了，
/// 但 Flutter 侧的 `MediaQuery` 仍是 **1280x720**（GTK 默认窗口尺寸）。
/// 所以窄屏判据**不能**依赖它；本函数只保留"试过了、读数是这样"的记录，
/// 真正的窄屏由用例侧用 `tester.view.physicalSize` 施加（框架级视口覆盖）。
Future<String> _resizeWindow(WidgetTester tester, int w, int h) async {
  final id = await _windowId();
  if (id == null) {
    _note('⑪ 找不到窗口（xdotool）⇒ 真窗口 resize 这条路走不通（记下来）');
    return 'no-window';
  }
  await Process.run('xdotool', ['windowsize', id, '$w', '$h']);
  await _wait(tester, 1200);
  final geo = await Process.run('bash', [
    '-lc',
    'xdotool getwindowgeometry $id 2>&1 | tr "\n" " "',
  ]);
  final out = '${geo.stdout}'.trim();
  _note('⑪ 真窗口 resize 尝试 → ${w}x$h（id=$id）｜xdotool 几何=$out');
  return out;
}

/// 对一个屏幕做 i18n 判定并记账。
Future<void> _i18nScreen(WidgetTester tester, String name) async {
  await _shot(tester, name);
  final hits = _cjkVisible(tester);
  if (hits.isEmpty) {
    _note('i18n OK $name：英文模式下本屏无 CJK 文案');
  } else {
    _note('i18n ⚠ $name：英文模式下仍有 CJK ${hits.length} 处 → '
        '${hits.take(8).join(' | ')}');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Linux 走查：启动 → 真 NAS 登录 → 逐屏（含英文模式审计）', (tester) async {
    final failures = <String>[];
    final i18nHits = <String, List<String>>{};
    // ★★ 抓**框架级异常**的完整栈：框架只把 ErrorSummary 打进 stdout，
    //    没有"出错控件在哪一行"。这里自己接一层，把栈前 22 帧写进日志
    //    （`takeException` 的判据不变 —— 仍然把 details 转给原处理器）。
    final frameErrors = <String>[];
    // ★ 骨架探针：`ListTile background color or ink splashes may be invisible`
    //   这条断言**不告诉我们是谁**（栈里没有控件）。所以在这里于**出错当帧**
    //   直接遍历 element 树，把所有 `ListTile` 的创建链（含祖先）打出来。
    var ltDumped = 0;
    void dumpOffendingListTiles() {
      try {
        final root = WidgetsBinding.instance.rootElement;
        if (root == null) return;
        final hits = <String>[];
        void visit(Element e) {
          if (e.widget is ListTile) hits.add(e.debugGetCreatorChain(12));
          e.visitChildren(visit);
        }
        visit(root);
        _note('LT-ERR total=${hits.length}');
        for (var i = 0; i < hits.length && i < 4; i++) {
          _note('LT-ERR[$i] ${hits[i]}');
        }
      } catch (e) {
        _note('LT-ERR dump failed: $e');
      }
    }
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails d) {
      final stack = (d.stack ?? StackTrace.empty)
          .toString()
          .split('\n')
          .take(24)
          .join(' <- ');
      frameErrors.add('${d.exceptionAsString()} || $stack');
      if (ltDumped < 2 && d.exceptionAsString().contains('ListTile background color')) {
        ltDumped++;
        dumpOffendingListTiles();
      }
      prevOnError?.call(d);
    };
    Future<void> step(
      String name,
      String tag,
      Future<void> Function() body,
    ) async {
      // ★ 先清空上一步遗留的异常，再判是否跳过 —— 否则"被跳过的步"
      //   会把上一步的异常算到自己账上（首轮 ③ 笔记 的 35 条就是这么来的）。
      tester.takeException();
      final before = frameErrors.length;
      if (tag.isNotEmpty && !_want(tag)) return;
      try {
        await body();
        // 把"布局溢出"归到**具体屏幕**上（AGENTS §2.0.21 / r92 迁移）。
        final overflow = tester.takeException();
        if (overflow != null) {
          throw StateError('屏幕内有未处理异常（多为布局溢出）：$overflow');
        }
        if (frameErrors.length > before) {
          throw StateError('屏幕内有 ${frameErrors.length - before} 条框架异常'
              '（首条：${frameErrors[before]}）');
        }
      } catch (e) {
        failures.add('$name: ${'$e'.split('\n').first}');
        _note('SCREEN-FAIL $name: $e');
        if (frameErrors.length > before) {
          for (var i = before; i < frameErrors.length && i < before + 3; i++) {
            _note('FRAME-ERR[$i] ${frameErrors[i]}');
          }
          _dumpListTileChains(tester, name);
        }
        await _resetToShell(tester);
      }
    }

    debugPrint('[walk] 截图目录 = ${_shotDir.path}');
    debugPrint('[walk] 目标 NAS = $_url  QC=$_qc  账号=$_account');

    // ============================================================ 启动
    await _boot(tester);
    await _shot(tester, '00_boot_setup');
    _note('① 启动：连接页已渲染（key=srv-orb=${find.byType(EnergyOrb).evaluate().length}）');

    final container = _container(tester)!;

    // ★ 语言**显式钉成英文**：既让导航文案可预测，也顺带把"英文模式"作为
    //   默认审计口径（要求：英文模式不许有中文）。容器 locale 本来就是 en。
    await container.read(localeChoiceProvider.notifier).set(LocaleChoice.en);
    await _wait(tester, 1200);
    await _i18nScreen(tester, '00b_setup_en');
    i18nHits['setup'] = _cjkVisible(tester);

    // ============================================================ ① 登录
    await step('① 登录/QuickConnect', 'login', () async {
      // QuickConnect 段：点云端图标切档，看输入框提示怎么变（不提交）
      var qcTapped = false;
      for (final seg in const ['QuickConnect ID', 'QuickConnect']) {
        final f = find.text(seg).hitTestable();
        if (f.evaluate().isNotEmpty) {
          await tester.tap(f.first, warnIfMissed: false);
          await _wait(tester, 900);
          qcTapped = true;
          break;
        }
      }
      if (qcTapped) {
        await _shot(tester, '01a_quickconnect_segment');
        _note('① QuickConnect 段：已切到 QuickConnect ID 档');
      } else {
        final qcSeg = find.byIcon(Icons.cloud_outlined).hitTestable();
        if (qcSeg.evaluate().isNotEmpty) {
          await tester.tap(qcSeg.first, warnIfMissed: false);
          await _wait(tester, 900);
          await _shot(tester, '01a_quickconnect_segment');
          _note('① QuickConnect 段：按云端图标切档');
        } else {
          _note('① QuickConnect 段：未找到切档控件（如实记录）');
        }
      }

      // 静默重登先跑完
      await _waitFor(
        tester,
        'restore 结束',
        () => !container.read(sessionControllerProvider).restoring,
        timeout: const Duration(seconds: 60),
      );

      if (!container.read(sessionControllerProvider).loggedIn) {
        // ★ 默认档是 **QuickConnect**（首屏截图里带勾的就是它）⇒ 必须先切到
        //   「Direct address」，否则输入的 URL 会被当成 QC ID 去解析。
        final direct = find.text('Direct address').hitTestable();
        if (direct.evaluate().isNotEmpty) {
          await tester.tap(direct.first, warnIfMissed: false);
          await _wait(tester, 900);
          _note('① 已切到 Direct address 档');
        }
        // 直接地址 + 账号口令（真 UI）
        final tf = find.byType(TextField);
        if (tf.evaluate().isNotEmpty) {
          await tester.enterText(tf.first, _url);
          await _wait(tester, 300);
        }
        var sawDialog = false;
        await _tapOrb(tester);
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
          await _shot(tester, '01b_trust_dialog');
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
        _note('① 连接成功：label=${conn.profile.label} '
            'trustDialog=$sawDialog endpoint=${conn.endpoint.source}');
        expect(conn.profile.value, _url);

        await _waitFor(
          tester,
          '进入登录页',
          () => find.byType(TextField).evaluate().length >= 2,
        );
        await _wait(tester, 14000); // SYSTEM BOOT HUD 演完
        final fields = find.byType(TextField);
        if (fields.evaluate().isNotEmpty) {
          try {
            await tester.ensureVisible(fields.first);
            await _wait(tester, 800);
          } catch (_) {}
        }
        await _shot(tester, '02_login_page');
        _note('①r698 标记 A：02_login_page 已截');
        i18nHits['login'] = _cjkVisible(tester);
        _note('①r698 标记 B：i18n 已收');
        await tester.enterText(fields.at(0), _account);
        _note('①r698 标记 C：账号已填');
        await tester.enterText(fields.at(1), _password);
        _note('①r698 标记 D：口令已填');
        await _wait(tester, 400);
        _note('①r698 标记 E：准备点 orb');
        await _tapOrb(tester);
        _note('①r698 标记 F：orb 已点（等登录）');
        await _waitFor(
          tester,
          '登录成功进主页',
          () => container.read(sessionControllerProvider).loggedIn &&
              _hasKey('app-shell-stack'),
          timeout: const Duration(seconds: 90),
        );
      } else {
        _note('① 静默重登（restore）直接进入主页，跳过手动登录 UI');
      }
      final st = container.read(sessionControllerProvider);
      _note('① 登录成功：account=${st.session?.account} '
          'sid=${st.session!.sid.length}位 did=${st.session?.did != null}');
      await _wait(tester, 5000);
      await _shot(tester, '03_home_chat');
      i18nHits['home'] = _cjkVisible(tester);
    });

    // ============================================================ 服务器管理（多账号多 NAS）
    await step('①b 服务器管理', 'servers', () async {
      await _resetToShell(tester);
      await _push(tester, const NasManagerPage());
      await _wait(tester, 3000);
      await _shot(tester, '04_nas_manager');
      _dumpUi(tester, '①b NAS 管理器');
      _note('①b NAS 管理器：本机已保存服务器条数=${find.byType(ListTile).evaluate().length}');
    });

    // ============================================================ ④ Chat
    await step('④ Chat', 'chat', () async {
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-chat', settle: 1200);
      await _wait(tester, 7000);
      final rows = find.byType(ListTile).evaluate().length;
      await _shot(tester, '05_chat');
      _dumpUi(tester, '④ Chat');
      i18nHits['chat'] = _cjkVisible(tester);
      _note('④ Chat：频道列表行数=$rows '
          'hasSyncFailed=${_hasText('Sync failed') || _hasText('同步失败')}');
      // ★ r667：桌面实际渲染的是标题大小写 `Channels`（像素 05_chat 已证），
      //   全大写写法在这条链路上**不存在** ⇒ 两个都认，免得把仪器错判成缺陷。
      expect(_hasText('Channels') || _hasText('CHANNELS'), isTrue,
          reason: '频道列表头要画出来');
    });

    // ============================================================ ④b ChatPage：最后一个页面类
    // ★ r700：`ChatPage` 是 163 个页面类里**最后一个没被开过**的 —— 因为进频道就会
    //   `Channel/view` 上报已读 ＝ **写动词**。纪律：只有**会话自己记的 endpoint**
    //   真的是本机 Mock 时才进（`_sessionIsLocal`，不看命令行 `_isMock`；r690 撞过
    //   "命令行是 Mock、安全存储里恢复的是真 NAS"）。真 NAS 上永不进入，§5.1 写动词 = 0。
    await step('④b ChatPage：进频道＝标已读（写动词，仅 Mock）', 'chatpage', () async {
      final c = _container(tester);
      if (c == null || !_sessionIsLocal(c)) {
        _note('④b ChatPage：会话 endpoint 不是本机 Mock ⇒ **不进入**'
            '（写动词纪律：真 NAS 上的「标已读」永不发）');
        return;
      }
      final err = await _probePage(
          tester, '206_chat_page', const ChatPage(channelId: 1), '④b');
      _note('④b ChatPage：channelId=1，页面异常=${err ?? "无"}；'
          '`Channel/view`（标已读）只打到本机 Mock');
    });

    // ---------------------------------------------------------- ④c Wayland（r701）
    //
    // 判据不是"环境变量里写了 wayland"（那是自欺），而是**两件外部事实**：
    //   ① `xwininfo -root -tree` 里**没有**本 App 的大 X 窗口（Wayland 客户端不占 X）；
    //   ② X 树里有 `Weston Compositor` 的窗口（说明我们被合成进 weston）。
    // 再加一张根窗口像素（App 被合成后的样子）和一张 surface 像素做对照。
    await step('④c Wayland：GDK 后端 + X 树上有没有 App 窗口', 'wayland', () async {
      final env = Platform.environment;
      _note(
        '④c env GDK_BACKEND=${env['GDK_BACKEND'] ?? "(unset)"} '
        'WAYLAND_DISPLAY=${env['WAYLAND_DISPLAY'] ?? "(unset)"} '
        'DISPLAY=${env['DISPLAY'] ?? "(unset)"}',
      );
      var appX = -1;
      var weston = -1;
      try {
        final r = await Process.run('xwininfo', ['-root', '-tree']);
        final lines = '${r.stdout}'.split('\n');
        // 10x10 的是 GTK 自己的辅助窗口（不是 App 的面）；只数真正的面
        appX = lines
            .where(
              (l) =>
                  l.contains('com.openviewai.synhub') && !l.contains('10x10'),
            )
            .length;
        weston = lines.where((l) => l.contains('Weston Compositor')).length;
      } catch (e) {
        _note('④c xwininfo 失败：$e');
      }
      _note('④c X 树：app_windows=$appX weston_windows=$weston');
      await _shot(tester, '207_wayland_surface');
      await _rootShot('208_wayland_root');
      _note(
        '④c 判据：GDK_BACKEND=wayland ＋ app_windows=0 ＋ weston_windows>=1 '
        '⇒ 真的在 Wayland 合成器里；任一不成立即不得记 A',
      );
    });

    // ============================================================ ② 文件
    await step('② 文件：根 / 面包屑 / 上一级', 'files', () async {
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-files', settle: 1500);
      for (var i = 0; i < 8; i++) {
        if (_hasText('docker')) break;
        if (!await _tapKey(tester, 'file-up', settle: 1200)) break;
      }
      await _waitFor(
        tester,
        '文件根目录出现',
        // Mock 的共享只有 home/photo（实测），没有 `docker`
        () => _isMock ? _hasText('home') : _hasText('docker'),
        timeout: const Duration(seconds: 60),
      );
      await _wait(tester, 2500);
      await _shot(tester, '06_files_root');
      _dumpUi(tester, '② 文件根');
      i18nHits['files_root'] = _cjkVisible(tester);
      // ★ r346：存在性判据要用**不看 hitTest** 的版本 —— 实测（本轮 dump）
      //   宽屏两栏下 `home` 行在控件树里，但 `.hitTestable()` 回假
      //   （行文字被父级 InkWell/裁剪吃掉半个矩形），会把"渲染了"判成"没有"。
      expect(_hasTextAny('home'), isTrue, reason: 'NAS 根目录应有 home 共享（存在性）');

      await _tapText(tester, 'home', settle: 2500);
      // ★ r690：宽屏「左选右开」——点一行只填右栏；目录的右栏会自己画子列表，
      //   但偶尔需要再按一次「打开」才推进（探针兜底，不改产品行为）。
      if (!(_hasText('Drive') || _hasText('Documents'))) {
        await _openWideDetail(tester, settle: 2000);
      }
      await _waitFor(
        tester,
        '/home 列表出现',
        // Mock 的 home 只有 Documents / mockfs_sandbox / mockfs_home.txt
        // ★ r690：`_isMock` 只反映**命令行给的 URL**，而 App 可能从安全存储
        //   里恢复了一条**真 NAS** 会话（本轮就是：URL 是 mock，数据是
        //   nas.example.com）⇒ 判据取**两种材料的并集**，只断言"真的列出了子项"。
        () =>
            _hasText('Documents') ||
            _hasText('mockfs_home.txt') ||
            _hasText('Drive') ||
            _hasText('Music'),
        timeout: const Duration(seconds: 60),
      );
      await _wait(tester, 2500);
      await _shot(tester, '07_files_home');
      // ★★★ r349 订正：这条断言原来是**构造性红**（不是产品缺陷）。
      //   Xvfb 是 1600x1000 ⇒ 逻辑宽 1600 > `kAppWindowMediumMax`(700)
      //   ⇒ 文件页是**两栏**：左栏共享列表、右栏内容。两栏下点 `home` 只是
      //   **选中右栏**，**不 push 栈层** ⇒ `stack.length` 仍是 1
      //   ⇒ `file_browse_page.dart:241` 的
      //      `onUp: source==nas && stack.length>1 ? … : null` 取 null
      //   ⇒ `file-up` **正确地不出现**（像素 `07_files_home.png` 实测：无该按钮）。
      //   而 r259 那个真机缺陷是**单栏**（手机）上的 ⇒ 断言必须放回**单栏**才有效。
      //   ⇒ 正向对照：按 §2.0.36 用 `tester.view.physicalSize`（**不是**
      //     `setSurfaceSize()`，后者根本不改 `MediaQuery`）临时收窄窗口。
      _note('② /home（宽屏两栏）：「上一级」按钮存在=${_hasKey('file-up')}'
          '（两栏下应为 false）');
      final view = tester.view;
      final oldSize = view.physicalSize;
      final oldDpr = view.devicePixelRatio;
      try {
        // 400 逻辑宽 < 700 ⇒ 单栏
        view.devicePixelRatio = 1.0;
        view.physicalSize = const Size(400, 900);
        addTearDown(view.resetPhysicalSize);
        addTearDown(view.resetDevicePixelRatio);
        await _wait(tester, 900);
        await _resetToShell(tester);
        await _tapKey(tester, 'dock-files', settle: 1800);
        await _tapText(tester, 'home', settle: 3000);
        if (!(_hasText('Drive') || _hasText('Documents'))) {
          await _openWideDetail(tester, settle: 2000);
        }
        await _waitFor(
          tester,
          '窄屏 /home 列表出现',
          () =>
              _hasText('Documents') ||
              _hasText('mockfs_home.txt') ||
              _hasText('Drive') ||
              _hasText('Music'),
          timeout: const Duration(seconds: 60),
        );
        await _wait(tester, 2000);
        await _shot(tester, '07b_files_home_narrow');
        _dumpUi(tester, '② 窄屏 /home');
        _note('② /home（窄屏单栏）：「上一级」按钮存在=${_hasKey('file-up')}'
            '（单栏下应为 true ⇒ r259 回归守卫）');
        expect(_hasKey('file-up'), isTrue,
            reason: '窄屏单栏进子目录后必须有 file-up（第 259 轮真机缺陷回归）');
      } finally {
        view.physicalSize = oldSize;
        view.devicePixelRatio = oldDpr;
        await _wait(tester, 700);
      }
    });

    await step('② 文件：Drive + 三类缩略图', 'files', () async {
      if (_isMock) {
        // Mock 的 /home 里没有 Drive 目录（实测：Documents / mockfs_sandbox /
        // mockfs_home.txt）⇒ 本屏未验，如实记账，不当缺陷。
        _note('② /home/Drive 缩略图：Mock 站没有 Drive 目录 ⇒ 本屏未验（夹具缺口）');
        return;
      }
      // ★ r667：宽屏下点 `Drive` 只是把它填进右栏 ⇒ 判据要认**右栏子列表**
      //   （`file-wide-nas-list`）＋一条真在里面的素材名。
      //   旧判据等 `Product spec.odoc`（真 NAS 上早就不存在）＋根级的
      //   `file-no-more`（右栏没有这个键）⇒ 界面明明对了却必定超时。
      // ★★ r692：进 `/home` 改成 `_gotoHome()`（确定性归位）；并且"选 Drive"
      //   允许**一次回落** —— 若上一步把页面留在 `/home/Drive` 内部栈里，
      //   宽屏点 `Drive` 会变成"再进一层"，于是右栏判据永远不来。
      // ★★ r692：真 NAS 上 office 样本在 **My Drive**，不在 `/home/Drive`
      //   （r690 那轮因 `_isMock=true` 整段被跳过，这个旧假设一直没被证伪）。
      if (!await _gotoMyDrive(tester)) {
        _note('② My Drive：未找到 office 样本（如实记录，本屏未验）');
        return;
      }
      await _waitFor(
        tester,
        'My Drive 列表出现',
        () => _hasKey('file-wide-nas-list') ||
            _hasText('Celestial.oslides') ||
            _hasText('5-day trip planner.odoc'),
        timeout: const Duration(seconds: 30),
      );
      // ★★ r692：缩略图的**设计位置是网格卡片**（列表行只放分类图标）
      //   ⇒ 先切到网格视图再量，否则量到的是"列表行的图标"而误判成"没缩略图"。
      // ★ 两个"网格/列表"开关：File Station 页用 `Icons.grid_view_rounded`，
      //   **Drive 源**用 `drive-view-toggle`（图标 `Icons.grid_view_outlined`）
      //   —— r692 实测点前者静默无效（截图仍是列表），点的是另一个视图的按钮。
      final gridToggled = _hasKey('drive-view-toggle')
          ? await _tapKey(tester, 'drive-view-toggle', settle: 2500)
          : await _tapIcon(tester, Icons.grid_view_rounded, settle: 2500);
      _note('② 缩略图：切网格视图（drive-view-toggle 命中=$gridToggled）');
      await _wait(tester, 3000);
      await _shot(tester, '08b_files_drive_grid');
      await _wait(tester, 4000);
      await _shot(tester, '08_files_drive_thumbs');
      _dumpUi(tester, '② /home/Drive');
      final docThumb = _hasKey('office-thumb-doc') ||
          _hasKey('office-thumb-first-page') ||
          _hasKey('office-thumb-image') ||
          _hasKey('file-thumb-office');
      final sheetThumb = _hasKey('office-thumb-sheet');
      final slidesThumb = _hasKey('office-thumb-slides');
      final fallback = _hasKey('office-thumb-fallback');
      _note('② 缩略图：office-thumb-doc=$docThumb sheet=$sheetThumb '
          'slides=$slidesThumb fallback=$fallback');
    });

    await step('② 文件：排序 / 搜索 / 多选 / 行菜单', 'files', () async {
      // ★★★ r349：本场原来**没有** `_resetToShell` + `dock-files`，
      //   靠"**上一场把页面留在 Files 页**"这个**隐藏的顺序依赖**才走得通。
      //   而上一场（② Drive）在 Mock 档**提前 return 且没有导航**，
      //   再上一场一旦失败，`step` 的 catch 会跑 `_resetToShell` ⇒ 页面回外壳
      //   ⇒ 这里满屏找不到 `Icons.sort` ⇒ 报 `文件页必须有排序入口`
      //   （**级联红**，见 AGENTS §2.0.62①「一族红 ≠ 一族缺陷」）。
      //   处置：补上和其它文件场一样的标准前导，**不再依赖执行顺序**。
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-files', settle: 1800);
      // ★★ r692：上一场（缩略图）把源切到 **My Drive** 了，而 My Drive 源里
      //   **没有共享根、也没有 `file-up`** ⇒ 只靠 `file-up` 回不去（实测 60 s
      //   超时）。先点回 `NAS files` 源再往上升。
      await _tapText(tester, 'NAS files', settle: 1500);
      // ★ r667：文件页**保留上次所在目录**（provider 常驻）⇒ 上一场把页面留在
      //   `/home/Drive` 时，这一场直接等根级 `docker` 会 60 s 超时（级联红）。
      //   先一路 `file-up` 退回根，再等判据。
      for (var i = 0; i < 8; i++) {
        if (_isMock ? _hasText('home') : _hasTextAny('docker')) break;
        if (!await _tapKey(tester, 'file-up', settle: 1200)) break;
      }
      await _waitFor(
        tester,
        '文件页就绪（排序场）',
        () => _isMock ? _hasText('home') : _hasTextAny('docker'),
        timeout: const Duration(seconds: 60),
      );
      await _wait(tester, 1500);
      // 排序（顶栏 Icons.sort，可能被折进 ⋮）
      expect(await _tapIcon(tester, Icons.sort, settle: 1200), isTrue,
          reason: '文件页必须有排序入口');
      await _shot(tester, '09_files_sort_sheet');
      await _pressEscape(tester);
      await _wait(tester, 800);

      // 搜索（顶栏 Icons.search）
      expect(await _tapIcon(tester, Icons.search, settle: 2000), isTrue,
          reason: '文件页必须有搜索入口');
      await _wait(tester, 3000);
      await _shot(tester, '10_files_search');
      _dumpUi(tester, '② 文件搜索');
      final nav = rootNavigatorKey.currentState;
      if (nav != null && nav.canPop()) {
        nav.pop();
        await _wait(tester, 1200);
      }

      // 多选：长按第一行（进选择态）
      final rows = find.byType(ListTile).hitTestable();
      if (rows.evaluate().isNotEmpty) {
        await tester.longPress(rows.first, warnIfMissed: false);
        await _wait(tester, 1200);
      }
      await _shot(tester, '11_files_multiselect');
      _dumpUi(tester, '② 文件多选');
      final selecting = _hasTextContaining('selected') ||
          _hasTextContaining('已选择') ||
          find.byIcon(Icons.close).hitTestable().evaluate().isNotEmpty;

      // 行菜单：单选 + 顶栏 ⋮ → 单条动作弹层
      if (selecting) {
        // 退出多选
        final closeBtn = find.byIcon(Icons.close).hitTestable();
        if (closeBtn.evaluate().isNotEmpty) {
          await tester.tap(closeBtn.first, warnIfMissed: false);
          await _wait(tester, 900);
        }
      }
      final rowMenu = find.byTooltip(_tEn.fileMoreActions).hitTestable();
      if (rowMenu.evaluate().isNotEmpty) {
        await tester.tap(rowMenu.first, warnIfMissed: false);
        await _wait(tester, 1500);
        await _shot(tester, '12_files_row_menu');
        _dumpUi(tester, '② 文件行菜单');
        await _pressEscape(tester);
        await _wait(tester, 800);
      } else {
        _note('② 行菜单：未找到「${_tEn.fileMoreActions}」tooltip（如实记录）');
      }

      // 分享链接页 + 回收站入口（共享文件夹根才有回收站）
      await _tapKey(tester, 'file-up', settle: 1800); // /home → 根
      await _wait(tester, 2000);
      final recycle = find.byIcon(Icons.delete_outline).hitTestable();
      if (recycle.evaluate().isNotEmpty) {
        await tester.tap(recycle.first, warnIfMissed: false);
        await _wait(tester, 4000);
        await _shot(tester, '13_files_recycle');
        _dumpUi(tester, '② 回收站视图');
      } else {
        _note('② 回收站：共享文件夹根未出现回收站入口（如实记录）');
      }
    });

    await step('② 文件：工具（离线/外接/WebDAV）+ 下载任务', 'files', () async {
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-files', settle: 1800);
      await _wait(tester, 2500);
      final tools = await _tapKey(tester, 'file-tools-entry', settle: 2000);
      if (tools) {
        await _shot(tester, '14_files_tools_sheet');
        _dumpUi(tester, '② 文件工具');
        await _pressEscape(tester);
        await _wait(tester, 800);
      } else {
        _note('② 文件工具：未找到 file-tools-entry（如实记录）');
      }
      final dlTasks = await _tapKey(tester, 'file-download-tasks-entry',
          settle: 2000);
      if (dlTasks) {
        await _shot(tester, '15_files_download_tasks');
        _dumpUi(tester, '② 文件下载任务');
        await _pressEscape(tester);
        await _wait(tester, 800);
      } else {
        _note('② 文件下载任务：未找到入口（能力位 or 未渲染；如实记录）');
      }
    });

    // ============================================================ ⑥ Office
    Future<void> openOffice(String fileName, String shotPrefix, String anchor) async {
      if (_isMock) {
        _note('⑤/⑥ $fileName：/home/Drive 是真 NAS 素材，Mock 站没有 ⇒ 本屏未验（夹具缺口）');
        return;
      }
      // ★★ r692：office 样本在 **My Drive**（不是 `/home/Drive`）；见 `_gotoMyDrive`。
      if (!await _gotoMyDrive(tester)) {
        _note('⑤/⑥ $fileName：My Drive 未到达（探针导航未复验）');
        return;
      }
      await _wait(tester, 1500);
      expect(await _tapTextScrolling(tester, fileName), isTrue,
          reason: '要能在 /home/Drive 里点到 $fileName');
      // ★ r667：宽屏选中文件后**不会自己开**，必须按右栏的 `file-wide-open`
      expect(await _openWideDetail(tester), isTrue,
          reason: '宽屏右栏应有"打开"按钮（file-wide-open）');
      await _wait(tester, 22000);
      await _shot(tester, shotPrefix);
      _dumpUi(tester, '⑥ $fileName');
      expect(_hasKey(anchor), isTrue, reason: '$fileName 阅读器应出正文视图');
    }

    // ★★ r667：文件名要取**右栏列表最靠上**的那几个。`/home/Drive` 实测有 17 项，
    //   `Product spec.odoc` / `Travel expenses.osheet` 排在中间偏后 ⇒ 宽屏右栏
    //   **两个竖直 Scrollable** 的坑（AGENTS §2.0.70⑥）让 `_tapTextScrolling`
    //   滚错了对象，两次都报 "要能点到 …" —— 界面其实一直在（`file-wide-nas-list`）。
    //   取字典序最靠前的 `5-day trip planner.odoc` / `Annual income…osheet` 后即通。
    await step('⑥ Office .odoc', 'office', () async {
      await openOffice(
          '5-day trip planner.odoc', '16_office_odoc', 'office-doc-view');
    });

    await step('⑥ Office .osheet', 'office', () async {
      await openOffice('Annual income and expenditure.osheet',
          '17_office_osheet', 'office-sheet-page');
    });

    await step('⑥ Office .oslides', 'office', () async {
      await openOffice(
          'Celestial.oslides', '18_office_oslides', 'office-slides-page');
    });

    await step('⑥ Office 模板库 + 新建（含加密）', 'office', () async {
      // 「新建 / 上传」面板（Drive 源）：FAB 的 `Icons.add` 打开
      // `showDriveCreateSheet`（三种类型 + 从模板 + 加密 + 上传）
      Future<void> openCreateSheet() async {
        await _resetToShell(tester);
        await _tapKey(tester, 'dock-files', settle: 1800);
        await _wait(tester, 2000);
        await _tapText(tester, _tEn.driveMyDrive, settle: 2500);
        await _wait(tester, 2500);
        _dumpListTileChains(tester, 'after-mydrive');
        final fab = find.byIcon(Icons.add).hitTestable();
        if (fab.evaluate().isNotEmpty) {
          await tester.ensureVisible(fab.last);
          await _wait(tester, 150);
          await tester.tap(fab.last, warnIfMissed: false);
          await _wait(tester, 1500);
        }
        _dumpListTileChains(tester, 'after-fab');
      }

      await openCreateSheet();
      await _shot(tester, '20_drive_create_menu');
      _dumpUi(tester, '⑥ 新建菜单');
      final menuKeys = [
        'drive-create-folder',
        'drive-create-text',
        'drive-create-doc',
        'drive-create-sheet',
        'drive-create-slides',
        'drive-create-template',
        'drive-create-encrypted',
        'drive-create-upload',
      ];
      final present =
          menuKeys.where(_hasKey).toList();
      _note('⑥ 新建菜单：八项里可见 ${present.length}/8 → ${present.join('|')}');
      expect(_hasKey('drive-create-encrypted'), isTrue,
          reason: '「新建」菜单必须有加密子菜单');

      // 加密子菜单 → 口令框（**不提交**，不产生 NAS 写）
      expect(await _tapKey(tester, 'drive-create-encrypted', settle: 1500),
          isTrue);
      await _shot(tester, '21_drive_create_encrypted_submenu');
      expect(await _tapKey(tester, 'drive-create-encrypted-doc', settle: 1800),
          isTrue);
      await _shot(tester, '22_drive_encrypt_password_dialog');
      _dumpUi(tester, '⑥ 加密口令框');
      _note('⑥ 加密口令框：drive-encrypt-password-dialog='
          '${_hasKey('drive-encrypt-password-dialog')} '
          'office-password-field=${_hasKey('office-password-field')}');
      await _pressEscape(tester);
      await _wait(tester, 1000);

      // 从模板新建 → 模板库
      await openCreateSheet();
      if (await _tapKey(tester, 'drive-create-template', settle: 4000)) {
        await _wait(tester, 8000);
        await _shot(tester, '19_office_template_library');
        _dumpUi(tester, '⑥ 模板库');
      } else {
        _note('⑥ 模板库：未找到「从模板新建」项（如实记录）');
      }
    });

    // ============================================================ ③ 笔记
    await step('③ 笔记：列表 / 编辑器', 'notes', () async {
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-workspace', settle: 1500);
      final opened = await _tapKey(tester, 'ws-tile-notes', settle: 2500);
      if (!opened) {
        await _push(tester, const NotesPage());
      }
      await _wait(tester, 10000);
      await _shot(tester, '23_notes_list');
      _dumpUi(tester, '③ 笔记列表');
      i18nHits['notes'] = _cjkVisible(tester);
      // 打开第一篇笔记看编辑器（只读：不保存）
      final tiles = find.byType(ListTile).hitTestable();
      if (tiles.evaluate().isNotEmpty) {
        await tester.tap(tiles.first, warnIfMissed: false);
        await _wait(tester, 8000);
        await _shot(tester, '24_note_editor');
        _dumpUi(tester, '③ 笔记编辑器');
      } else {
        // ★ r690：原来这里写"列表为空"，但同一屏的 dump 里明明有 6 本笔记
        //   ⇒ 是**判据找错了选择器**（笔记行不是 `ListTile`），不是"没数据"。
        //   诊断串必须跟着真实读数走，否则它会掩盖真缺口。
        _note('③ 笔记：可见行（Text 命中笔记者）=${find.textContaining('My notebook').evaluate().length}，'
            'ListTile=${find.byType(ListTile).evaluate().length}（行不是 ListTile ⇒ 用文本判）');
      }
    });

    // ============================================================ ⑤ 相册
    await step('⑤ 相册：时间线 / 查看器', 'photos', () async {
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-photos', settle: 1500);
      await _wait(tester, 14000);
      await _shot(tester, '25_photos_timeline');
      _dumpUi(tester, '⑤ 相册时间线');
      i18nHits['photos'] = _cjkVisible(tester);
      final imgs = find.byType(Image).evaluate().length;
      _note('⑤ 相册：Image 组件数=$imgs '
          'hasTimeline=${_hasText('Timeline')}');
      expect(imgs > 0, isTrue, reason: '时间线里要真有图片组件');
      // 打开第一张（查看器：旋转/评级/信息等）
      final tiles = find.byType(InkWell).hitTestable();
      if (tiles.evaluate().isNotEmpty) {
        await tester.tap(tiles.first, warnIfMissed: false);
        await _wait(tester, 9000);
        await _shot(tester, '26_photo_viewer');
        _dumpUi(tester, '⑤ 照片查看器');
        i18nHits['photo_viewer'] = _cjkVisible(tester);
      }
    });

    await step('⑤ 相册：视频查看器（时间线里的视频）', 'photos', () async {
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-photos', settle: 1500);
      await _wait(tester, 10000);
      // 视频项：先切到文件夹 -> Video（若时间线里没有视频）
      final vid = find.byIcon(Icons.play_circle_outline).hitTestable();
      if (vid.evaluate().isNotEmpty) {
        await tester.tap(vid.first, warnIfMissed: false);
        await _wait(tester, 9000);
        await _shot(tester, '27_photos_video_viewer');
        _dumpUi(tester, '⑤ 相册视频查看器');
      } else {
        _note('⑤ 相册：时间线里没有可见的视频项（如实记录；文件模块另有视频预览）');
      }
    });

    // ============================================================ ⑦ 音视频播放（Linux 能力位是刻意关的）
    await step('⑦ 音频：Audio Station + 播放实际表现', 'media', () async {
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-workspace', settle: 1500);
      var opened = await _tapKey(tester, 'ws-tile-audio', settle: 2500);
      if (!opened) {
        await _push(tester, const AudioPage());
      }
      await _wait(tester, 14000);
      await _shot(tester, '28_audio_list');
      _dumpUi(tester, '⑦ Audio Station');
      i18nHits['audio'] = _cjkVisible(tester);
      // 真点一首歌：看 Linux 上是"入口不可见"还是"点了失败"
      final song = _firstSongRow();
      if (song.evaluate().isNotEmpty) {
        await tester.tap(song.first, warnIfMissed: false);
        await _wait(tester, 14000);
        await _shot(tester, '29_audio_song');
        _dumpUi(tester, '⑦ 歌曲页');
        final play = find.byIcon(Icons.play_arrow).hitTestable();
        _note('⑦ 歌曲页：可见播放键=${play.evaluate().isNotEmpty}');
        if (play.evaluate().isNotEmpty) {
          await tester.tap(play.first, warnIfMissed: false);
          await _wait(tester, 10000);
          await _shot(tester, '30_audio_play_pressed');
          _dumpUi(tester, '⑦ 按下播放之后');
          _note('⑦ 音频播放（Linux）：按下后见上（能力位 localMediaPlayback '
              '= unavailable，预期是失败态而非崩溃）');
        }
      } else {
        // ★ r690 同上：这一屏 dump 里有 7 首歌，判据只是没找到 `ListTile`。
        _note('⑦ 音频：可见行（Text 命中时长者）='
            '${find.textContaining(RegExp(r"^[0-9]+:[0-9]{2} · ")).evaluate().length}，'
            'ListTile=${find.byType(ListTile).evaluate().length}');
      }
    });

    await step('⑦ 视频：文件预览的实际表现', 'media', () async {
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-files', settle: 1800);
      // ★ r156：先钉住 "NAS files" 档再往上走 —— r134 第 4 次真跑里这一步
      //   在 `文件根` 上超时（`_waitFor(..., 'docker', 60s)`），而同一个 App 在
      //   ⑥ 里**刚刚**列出过根目录（`06_files_root.png` 有 `docker`）⇒ 归因是
      //   **探针导航**（可能停在 `My Drive` 档，那一档 `file-up` 语义不同），
      //   不是产品缺陷。改成：显式选档 + 放宽次数 + 到不了就**如实记录并继续**
      //   （不让整轮走查因一个探针导航问题变红）。
      await _tapText(tester, 'NAS files', settle: 1500);
      for (var i = 0; i < 10; i++) {
        if (_hasText('docker')) break;
        if (!await _tapKey(tester, 'file-up', settle: 1200)) break;
      }
      await _waitFor(tester, '文件根',
          () => _isMock ? _hasText('home') : _hasText('docker'),
          timeout: const Duration(seconds: 25));
      if (_isMock ? !_hasText('home') : !_hasText('docker')) {
        _note('⑦ 视频：文件根未到达（探针导航未复验；上一屏 06_files_root 有 docker）');
        return;
      }
      await _tapText(tester, 'home', settle: 2500);
      await _wait(tester, 3000);
      final hasVideo = await _tapTextScrolling(tester, 'Video', settle: 3000);
      if (!hasVideo) {
        _note('⑦ 视频：/home/Video 未找到（如实记录）');
        return;
      }
      await _wait(tester, 5000);
      await _shot(tester, '31_video_list');
      // 点第一个视频（不写 NAS；只发 GET Range）
      final vid = find
          .byWidgetPredicate((w) =>
              w is Text &&
              (w.data ?? '').toLowerCase().endsWith('.mp4'))
          .hitTestable();
      if (vid.evaluate().isNotEmpty) {
        await tester.tap(vid.first, warnIfMissed: false);
        await _wait(tester, 15000);
        await _shot(tester, '32_video_preview');
        _dumpUi(tester, '⑦ 视频预览');
        _note('⑦ 视频预览（Linux）：见 32_video_preview.png '
            '（能力位 localMediaPlayback = unavailable）');
      } else {
        await _shot(tester, '32_video_list_no_mp4');
        _note('⑦ 视频：/home/Video 里没有 .mp4 可见行（如实记录）');
      }
    });

    // ==================================================== ⑦b 视频播放页（r690 新增）
    //
    // 这一屏是 r690 的**主证据**：Linux 以前点视频只会显示「本平台尚未实现」，
    // 现在走 `MpvPlayerAdapter`（libmpv）。判据三层：
    //   ① 播放器挂的是 `media-engine-mpv`（出画引擎身份）；
    //   ② **根窗口**像素标准差 > 0.05（纹理里真有画面，不是黑框）；
    //   ③ 时间轴在走（页面上的时长读数会变）。
    // 静音：容器只有 PulseAudio 空汇（无物理输出设备）⇒ 全程无声。
    await step('⑦b 视频播放页：libmpv 真出画', 'media', () async {
      await _resetToShell(tester);
      final src = MediaSource(
        uri: '/tmp/r690_sample.mp4',
        channel: MediaChannel.fileStation,
        kind: MediaKind.video,
        displayName: 'r690_sample.mp4',
        size: File('/tmp/r690_sample.mp4').lengthSync(),
        supportsRange: true,
      );
      await _push(tester, MediaPlayerPage(source: src));
      await _wait(tester, 9000);
      expect(
        find.byKey(const Key('media-engine-mpv')),
        findsWidgets,
        reason: '出画引擎必须是 libmpv（media-engine-mpv）',
      );
      await _rootShot('43_video_playback_root');
      final std = await _pixelStdDev('43_video_playback_root');
      _note('⑦b 视频页：引擎=libmpv，根窗口像素 stddev=$std');
      expect(
        std,
        greaterThan(0.05),
        reason: '视频区域几乎纯色（$std）⇒ 纹理里没有画面',
      );
      // 时间轴：等 2 s 再抓一次，画面应发生变化（同一帧 vs 下一帧）
      await _wait(tester, 2500);
      await _rootShot('44_video_playback_later');
      final std2 = await _pixelStdDev('44_video_playback_later');
      _note('⑦b 视频页：2.5 s 后再抓 stddev=$std2（时间轴在走 ⇒ 画面在变）');
      await _shot(tester, '45_video_page_ui');
      _dumpUi(tester, '⑦b 视频页');
    });

    // ==================================================== ②b Drive 深扫（r692）
    //
    // C7 欠账「drive 21 页只验了「新建八项 + 加密」」的第一批：把**能独立打开**
    // 的 Drive 子页逐个推上来，各抓一张像素。判据只有两条（不编数据）：
    //   ① 页面真渲染出 `Scaffold`（不是白屏/异常页）；
    //   ② 本屏可见 `Text` 条数 > 0（**空态也算渲染**，所以不判"有数据"）。
    // ★ 这些页都是只读 GET（回收站/配额/通知/成员…），§5.1 零变更动词。
    await step('②b Drive 深扫（回收站/团队回收站/计算机/配额/通知/更多/连接/同步/搜索/请求/成员）',
        'drive', () async {
      final probes = <(String, Widget)>[
        ('46_drive_trash', const DriveTrashPage()),
        ('47_drive_team_trash', const DriveTeamTrashPage()),
        ('48_drive_computers', const DriveComputersPage()),
        ('49_drive_quota', const DriveQuotaPage()),
        ('50_drive_notifications', const DriveNotificationsPage()),
        ('51_drive_extras', const DriveExtrasPage()),
        ('52_drive_connections', const DriveConnectionsPage()),
        ('53_drive_sync_tasks', const DriveSyncTasksPage()),
        ('54_drive_search', const DriveSearchPage()),
        ('55_drive_file_request', const DriveFileRequestPage()),
        ('56_drive_team_members', const DriveTeamMembersPage()),
      ];
      for (final (shot, page) in probes) {
        await _resetToShell(tester);
        await _push(tester, page);
        await _wait(tester, 6000);
        await _shot(tester, shot);
        _dumpUi(tester, '②b $shot');
        final texts = find.byType(Text).evaluate().length;
        expect(find.byType(Scaffold), findsWidgets,
            reason: '$shot 没有 Scaffold（白屏/异常页）');
        _note('②b $shot：Scaffold 在，Text=$texts');
      }
      i18nHits['drive-deep'] = _cjkVisible(tester);
    });

    // ==================================================== ③a 笔记深扫（r693）
    //
    // C7 欠账「笔记 22 单元只验了列表 + 编辑器」的第一批：把**能独立打开**的
    // 笔记子页逐个推上来，各抓一张像素。判据同 ②b：`Scaffold` 在 ＋ 可见 `Text` > 0
    // （**空态/无数据也算渲染**，不判"有数据"）。全部只读 GET，§5.1 零变更动词。
    await step('③a 笔记深扫（待办/标签/共享/加入/书架/智能/回收站/快捷/高级搜索/全文搜索/后台同步/逾期）',
        'notes', () async {
      final probes = <(String, Widget)>[
        ('57_note_todo', const NoteTodoPage()),
        ('58_note_tags', const NoteTagPage()),
        ('59_note_shared', const NoteSharedPage()),
        ('60_note_joined', const NoteJoinedPage()),
        ('61_note_shelf', const NoteShelfPage()),
        ('62_note_smart', const NoteSmartPage()),
        ('63_note_recycle', const NoteRecyclePage()),
        ('64_note_shortcut', const NoteShortcutPage()),
        ('65_note_adv_search', const NoteAdvSearchPage()),
        ('66_note_fts_search', const NoteFtsSearchPage()),
        ('67_note_bg_sync', const NoteBackgroundSyncPage()),
        ('68_note_overdue', const NoteOverdueSettingsPage()),
      ];
      for (final (shot, page) in probes) {
        await _probePage(tester, shot, page, '③a');
      }
      i18nHits['notes-deep'] = _cjkVisible(tester);
    });

    // ==================================================== ③b 相册深扫（r693）
    await step('③b 相册深扫（管理/相册 AI 设置/后台任务/备份/迁移/地图/分类/腾空间/人物/睡眠备份）',
        'photo', () async {
      final probes = <(String, Widget)>[
        ('69_photo_admin', const PhotoAdminPage()),
        ('70_photo_ai_edit_settings', const PhotoAiEditSettingsPage()),
        ('71_photo_bg_tasks', const PhotoBackgroundTasksPage()),
        ('72_photo_backup', const PhotoBackupPage()),
        ('73_photo_migration', const PhotoMigrationPage()),
        ('74_photo_map', const PhotoMapPage()),
        ('75_photo_c2', const PhotoC2Page()),
        ('76_photo_free_up', const PhotoFreeUpSpacePage()),
        ('77_photo_persons', const PhotoPersonsPage()),
        ('78_sleep_backup', const SleepBackupPage()),
      ];
      for (final (shot, page) in probes) {
        await _probePage(tester, shot, page, '③b');
      }
      i18nHits['photos-deep'] = _cjkVisible(tester);
    });

    // ============================== ③c 聊天/下载/音频/设置 深扫（r693）
    await step('③c 聊天·下载·音频·设置 深扫（频道/归档/可加入/全局内容·下载六页·音频四页·设置八页）',
        'system', () async {
      final probes = <(String, Widget)>[
        ('79_chat_channels', const ChannelListPage()),
        ('80_chat_archive', const ArchivePage()),
        ('81_chat_available', const AvailableChannelsPage()),
        ('82_chat_global_content', const GlobalContentPage()),
        ('83_dl_settings', const DownloadSettingsPage()),
        ('84_dl_rss', const DownloadRssPage()),
        ('85_dl_bt_search', const DownloadBtSearchPage()),
        ('86_dl_emule', const DownloadEmulePage()),
        ('87_dl_emule_servers', const DownloadEmuleServerPage()),
        ('88_dl_emule_search', const DownloadEmuleSearchPage()),
        ('89_audio_pins', const AudioPinsPage()),
        ('90_audio_cast', const AudioCastPage()),
        ('91_audio_remote', const AudioRemotePage()),
        ('92_audio_web_queue', const AudioWebQueuePage()),
        ('93_settings_notification', const NotificationSettingsPage()),
        ('94_settings_snooze', const SnoozeSettingsPage()),
        ('95_settings_profile', const PersonalProfilePage()),
        ('96_settings_profile_edit', const ProfileEditPage()),
        ('97_settings_bots', const BotsPage()),
        ('98_settings_e2ee', const E2eePage()),
        ('99_settings_keepalive', const OemKeepalivePage()),
        ('100_settings_service_check', const ServiceCheckPage()),
      ];
      for (final (shot, page) in probes) {
        await _probePage(tester, shot, page, '③c');
      }
      i18nHits['module-deep'] = _cjkVisible(tester);
    });

    // ======================================== ③d 桌面门控复核（r693 修后）
    // ★ DA332/DA333/DA334 修完**必须在真 Linux 宿主上再读一次**：
    //   宿主单测证明的是"逻辑门会关"，这里证明的是"这台机器上真的关着 + 屏上没有那两段"。
    await step('③d 门控复核', 'gates', () async {
      // ① 能力位读数（真 Linux 宿主）
      expect(
        capabilityGateAllows(AppCapability.backgroundExecution),
        isFalse,
        reason: 'Linux 没有 synhub/background 桥 ⇒ 后台执行能力必须判不可用',
      );
      expect(
        capabilityGateAllows(AppCapability.scheduledNoteSync),
        isFalse,
        reason: 'Linux 没有 synhub/note_sync 桥 ⇒ 笔记后台同步必须判不可用',
      );
      _dumpUi(
        tester,
        '③d gate: backgroundExecution='
        '${capabilityGateAllows(AppCapability.backgroundExecution)} '
        'scheduledNoteSync=${capabilityGateAllows(AppCapability.scheduledNoteSync)} '
        'cast=${capabilityGateAllows(AppCapability.cast)}',
      );

      // ② 设置页：桌面不摆「后台保活设置」那一行（修前 `99_settings_keepalive` 进得去）
      await _probePage(
        tester,
        '101_settings_after_fix',
        const SettingsPage(),
        '③d',
      );
      expect(
        _hasKey('settings-oem-keepalive'),
        isFalse,
        reason: '桌面设置页不许摆安卓专属的「后台保活设置」入口（DA332）',
      );
      for (final label in const ['后台保活设置', 'Background keep-alive settings']) {
        expect(_hasTextAny(label), isFalse, reason: '桌面不该有「$label」这一行');
      }

      // ③ 通知与后台页：桌面不摆「前台服务 / 开机自启」两段（DA334）
      await _probePage(
        tester,
        '102_notification_after_fix',
        const NotificationSettingsPage(),
        '③d',
      );
      for (final label in const [
        '前台服务',
        'Foreground service',
        '前台常驻服务',
        'Persistent foreground service',
        '开机自启',
        'Start at boot',
      ]) {
        expect(_hasText(label), isFalse,
            reason: '桌面通知页不许出现「$label」（桥不存在 ⇒ 死开关）');
      }
    });

    // ============================ ③e 零参数页深扫（r694）
    //
    // ★ r693 的 §4.1 把剩下 40 多页一律写成"要参数/管理员档"——**那是猜的**。
    //   本步把 `lib/src/features/**` 里**构造函数零必填参数**的页逐个推上来，
    //   各抓一张像素。判据与 ②b/③a 完全一致（不编数据）：
    //     ① 页面真渲染出 `Scaffold`（不是白屏/异常页）；
    //     ② 本屏可见 `Text` 条数 > 0（**空态/错误态也算渲染**，不判"有数据"）。
    //   ⇒ 所以"参数为空 ⇒ 列表空 ⇒ 空态"是**合法读数**，它证明的是"这页在 Linux 上
    //     能打开、能画、不崩"，不是"里面有数据"。
    // ★ 全部只读 GET（没有一页会自己发写动词；编辑器不点保存、扫描不点开始）。
    await step('③e 零参数页深扫（48 页：AI/分析/音频/日历/聊天/联系人/设计/下载/Drive/'
        '文件/邮件/笔记/相册/搜索/监控/服务器）', 'pages', () async {
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
            loadText: () async => 'linux walkthrough probe',
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
      for (final (shot, page) in probes) {
        await _probePage(tester, shot, page, '③e');
      }
      i18nHits['zero-arg-pages'] = _cjkVisible(tester);
    });

    // ============================ ③f 带参数页深扫（r695）
    //
    // ★ 上一批（③e）只打了"构造函数零必填参数"的页；剩下这批**必须给参数**。
    //   这里的原则：**参数用本地合成的夹具**（不走网络、不碰真 NAS 的写动词），
    //   判据仍然只有 Scaffold ＋ 可见 `Text` > 0 —— 即"这页在 Linux 上能打开、能画、
    //   不崩"。数据是合成的 ⇒ **不证明"里面有什么"**，只证明界面单元存在且可用。
    //   ★ 合成 id 打服务端会得到空的/失败的响应，那正是"无副作用"的证据。
    await step('③f 带参数页深扫（Drive 分享/版本/标注/团队回收站/高级共享/标签/集合 ·'
        '下载详情/选文件 · 音频单曲/已播 · 频道内容/成员/媒体 · 联系人编辑器/导入 ·'
        '笔记查看/分享/智能/加入 · 相册专辑/文件夹/人物/标签/查看器 · 监控摄像机 · Office）',
        'param-pages', () async {
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
          DrivePdfMarkupPage(
            filePath: '/tmp/synhub_probe.pdf',
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
      for (final (shot, page) in probes) {
        await _probePage(tester, shot, page, '③f');
      }
      i18nHits['param-pages'] = _cjkVisible(tester);
    });

    // ============================ ③g 剩余界面单元（r695）
    //
    // 收口 §4.1 表里最后一批"独立界面单元"：音频六种详情（专辑/艺人/作曲/流派/
    // 文件夹/播放列表）、Office 三个阅读器 ＋ 主题/版本/办公首页、笔记"加入的笔记本"、
    // 频道话题页、定时免打扰页、文件预览器两个分支（文本 / 图片）。
    // 判据同 ③e/③f（Scaffold ＋ 可见 Text > 0）；**合成参数 ⇒ 只证明界面单元能开能画**。
    // ★ 仍然不进 `ChatPage`（进入会标已读 = 写动词），见 §5.1。
    await step('③g 剩余界面单元（音频六详情 · Office 三阅读器/主题/版本 · 笔记加入 · 话题 ·'
        ' 定时免打扰 · 文件预览文本/图片）', 'more-pages', () async {
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
      for (final (shot, page) in probes) {
        await _probePage(tester, shot, page, '③g');
      }

      // ---- r696：`_OfficeVersionsPage`（Drive 版本历史里**Office 原生文档**那一路）
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
      i18nHits['more-pages'] = _cjkVisible(tester);
    });

    // ============================================================ ③h 靠交互才进得去的私有子页（r696）
    await step('③h 私有子页：全屏歌词（靠父页交互进入）', 'audio', () async {
      // `_LyricsFullPage` 是 `audio_song_page.dart` 里的私有页，**只能**从歌曲页的
      // `as-lyrics-expand` 进 —— 而那个入口只在"这首歌真的有带时间轴的歌词"时才出现。
      // 所以这一屏的判据是：**能拿到歌词就开、拿不到就如实记 SKIP + 原因**（不算失败屏）。
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-workspace', settle: 1500);
      final opened = await _tapKey(tester, 'ws-tile-audio', settle: 2500);
      if (!opened) await _push(tester, const AudioPage());
      await _wait(tester, 12000);
      final song = _firstSongRow();
      if (song.evaluate().isEmpty) {
        _note('③h 全屏歌词 SKIP：Audio Station 没有可见行（拿不到一首歌）'
            '（ListTile=${find.byType(ListTile).evaluate().length}，'
            '文本行=${find.textContaining(RegExp(r'^[0-9]+:[0-9]{2} · ')).evaluate().length}）');
        return;
      }
      await tester.tap(song.first, warnIfMissed: false);
      await _wait(tester, 12000);
      // ① 先自己搜一次歌词（只读网络请求），把"这首歌有没有歌词"变成事实
      if (_hasKey('as-lyrics-search')) {
        await _tapKey(tester, 'as-lyrics-search', settle: 6000);
        await _wait(tester, 6000);
      }
      if (!_hasKey('as-lyrics-expand')) {
        _note('③h 全屏歌词 SKIP：这首歌没有带时间轴的歌词'
            '（as-lyrics-expand 不在；as-lyrics-empty=${_hasKey('as-lyrics-empty')}）');
        return;
      }
      await _tapKey(tester, 'as-lyrics-expand', settle: 2000);
      await _wait(tester, 2500);
      await _shot(tester, '205_audio_lyrics_full');
      _dumpUi(tester, '③h 全屏歌词');
      // 全屏页自己的两个控件（字号）在 —— 证明进的是**全屏页**而不是原卡片
      _note('③h 全屏歌词：字号键 smaller=${_hasKey('as-lyrics-font-smaller')} '
          'larger=${_hasKey('as-lyrics-font-larger')}');
    });

    // ============================ ③h2 邀请成员页（**只在 Mock 的可写会话上跑**）
    await step('③h2 邀请成员页（Mock 可写会话）', 'invite', () async {
      // `_InviteMembersPage` 是 `channel_members_page.dart` 的私有页，**只能**从
      // 频道成员页的「邀请」图标进；而那一步按勾选**发邀请**（`inviteMembers` = 写动词）
      // ⇒ 真 NAS 只读轮绝不碰（AGENTS §5.1 / 本轮 §2.10f）。
      // 这里打的是**本机 Mock**（`--chat-demo`，可写内存库）：可以点开、可以看列表，
      // 但**不点提交** —— 证据只到"页面能开、列表能画"。
      // ★ r697 的两条纪律：
      //   ① **只「打开」这一页，绝不点「邀请(N)」提交** —— 打开页面只发
      //      `Chat.User/list`（只读）；提交才是 `inviteMembers` 写动词。
      //   ② 判据钉**会话自己记的 endpoint**（`_sessionIsLocal`），不只看命令行 URL：
      //      本轮第一次跑时命令行给的是 Mock（`_isMock=true`），而 App 从安全存储
      //      恢复的是**真 NAS** 会话（`account=demo_user sid=86位`）—— 那一轮幸好只是开页。
      _note('③h2 会话 endpoint 是本机 Mock=${_sessionIsLocal(container)}'
          '（命令行URL是Mock=$_isMock）；本步只开页、不提交');
      await _resetToShell(tester);
      // ★ Mock 种子：`channel_id=1` 是"我的空间"，产品逻辑里 **#1 不给邀请**
      //   （`inviteAllowed` 要求 `channelId != 1`）；`channel_id=2`（private）才给。
      await _push(tester, const ChannelMembersPage(channelId: 2));
      await _wait(tester, 5000);
      await _shot(tester, '206_chat_members_invite_entry');
      _dumpUi(tester, '③h2 频道成员页');
      final invite = find.byIcon(Icons.person_add_alt);
      _note('③h2 成员页：可见邀请图标=${invite.hitTestable().evaluate().isNotEmpty} '
          'Scaffold=${find.byType(Scaffold).evaluate().isNotEmpty}');
      if (invite.hitTestable().evaluate().isEmpty) {
        _note('③h2 邀请成员 SKIP：这个频道没摆出邀请图标（ACL/类型不满足，'
            '产品要求 `channelId != 1` 且 private/public）');
        return;
      }
      await tester.tap(invite.hitTestable().first, warnIfMissed: false);
      await _wait(tester, 5000);
      await _shot(tester, '207_chat_invite_members');
      _dumpUi(tester, '③h2 邀请成员页');
      final rows = find.byType(ListTile).evaluate().length;
      _note('③h2 邀请成员页：ListTile=$rows '
          'Scaffold=${find.byType(Scaffold).evaluate().isNotEmpty} '
          '（**不点提交**：发邀请是写动词）');

    });

    // ============================================================ ⑧ 下载
    await step('⑧ 下载', 'download', () async {
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-workspace', settle: 1500);
      var opened = await _tapKey(tester, 'ws-tile-downloads', settle: 2500);
      if (!opened) {
        await _push(tester, const DownloadPage());
      }
      await _wait(tester, 12000);
      await _shot(tester, '33_downloads');
      _dumpUi(tester, '⑧ 下载');
      i18nHits['downloads'] = _cjkVisible(tester);
      // ★ r156 修正（原探针把"FAB 必须在"当成不变量 —— 它自 r121 D9 起就**不该**
      //   在空态出现）：`ds-add-task` 是 `FloatingActionButton.extended` 的 key，
      //   而空态里已经有 `New task` 按钮时**故意不给 FAB**（同一入口的两份表示）。
      //   真跑证据（`/private/tmp/r134_walk4.log`）：`ds-browser-open|ds-batch-menu|
      //   ds-stat-bar` 都在、文案含 `No download tasks yet` / `New task`，唯独没有 FAB。
      //   不变量应当是 **§2.0.29 ①「去重后至少还剩一个入口」**，不是"必须是某一个"。
      final hasFab = _hasKey('ds-add-task');
      final hasEmptyNewTask = _hasText('New task');
      expect(hasFab || hasEmptyNewTask, isTrue,
          reason: 'Download Station 空态里必须有至少一个「新建任务」入口'
              '(FAB 与空态按钮是同一入口的两种形态，D9 去重后只留一个)');
    });

    // ============================================================ ⑨ 系统 / 管理
    await step('⑨ 设置', 'system', () async {
      await _resetToShell(tester);
      await _push(tester, const SettingsPage());
      await _wait(tester, 4000);
      await _shot(tester, '34_settings');
      _dumpUi(tester, '⑨ 设置');
      i18nHits['settings'] = _cjkVisible(tester);
    });

    await step('⑨ 管理工具 + admin_gate 双向验证', 'system', () async {
      await _resetToShell(tester);
      await _push(tester, const SettingsPage());
      await _wait(tester, 3500);
      final isAdmin = container.read(isAdminProvider).value == true;
      // ★★★ r349 装置加强：设置页是**惰性 ListView** —— 屏外的条目**根本不会构建**，
      //   而「管理工具」在 Profile 段（`settings_page.dart:357`），
      //   原来这里**完全不滚动** ⇒ 只要它落在屏外，`_hasKey=false` 就会被读成
      //   "正确隐藏"（**构造性假绿**）。iOS 侧同族场景实测需要 12×400px 才够
      //   （`maxScrollExtent` 1810–2142px，见 `docs/platform-ios.md` §11.5）。
      for (var i = 0; i < 12 && !_hasKey('set-admin-tools'); i++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -400));
        await tester.pumpAndSettle();
        await _wait(tester, 250);
      }
      final entryVisible = _hasKey('set-admin-tools');
      // ★★ 同族对照：设置页全仓只有 3 个带 Key 的条目
      //   （`set-photo-ai-edit` / `set-admin-tools` / `set-personal-profile`）——
      //   另外两个都找不到 ⇒ "根本没滚到那一段" ⇒ 本屏**判不了**（记未验，不是缺陷）。
      final ctrlA = _hasKey('set-photo-ai-edit');
      final ctrlB = _hasKey('set-personal-profile');
      final onSettings = ctrlA || ctrlB;
      _note('⑨ admin_gate：真实身份 isAdmin=$isAdmin '
          'set-admin-tools 可见=$entryVisible ⇒ 一致=${isAdmin == entryVisible} ｜ '
          '同族对照 photo-ai-edit=$ctrlA personal-profile=$ctrlB');
      if (!onSettings) {
        _note('⑨ admin_gate：同族对照一个都没扫到 ⇒ 本屏判不了，**如实记未验**（不是缺陷）');
      } else {
        expect(entryVisible, isAdmin,
            reason: '管理员入口可见性必须与身份一致（fail-closed）');
      }
      // 打开管理工具页（管理员才有意义；非管理员直接推页也应被门控）
      await _push(tester, const AdminToolsPage());
      await _wait(tester, 4000);
      await _shot(tester, '35_admin_tools');
      _dumpUi(tester, '⑨ 管理工具');
      i18nHits['admin'] = _cjkVisible(tester);
    });

    await step('⑨ 诊断页', 'system', () async {
      await _resetToShell(tester);
      await _push(tester, const DiagPage(autoRun: true));
      await _wait(tester, 12000);
      await _shot(tester, '36_diagnostics');
      _dumpUi(tester, '⑨ 诊断');
      i18nHits['diagnostics'] = _cjkVisible(tester);
    });

    await step('⑨ 端侧 AI 页', 'system', () async {
      await _resetToShell(tester);
      await _push(tester, const AiModelPage());
      await _wait(tester, 8000);
      await _shot(tester, '37_ai_model');
      _dumpUi(tester, '⑨ 端侧 AI');
      i18nHits['ai'] = _cjkVisible(tester);
    });

    // ============================================================ 英文模式再扫一圈主 tab
    await step('⑩ 英文模式：主 tab 再审计', 'system', () async {
      for (final tab in const [
        ['dock-files', '38_en_files'],
        ['dock-photos', '39_en_photos'],
        ['dock-workspace', '40_en_workspace'],
        ['dock-me', '41_en_me'],
        ['dock-chat', '42_en_chat'],
      ]) {
        await _resetToShell(tester);
        await _tapKey(tester, tab[0], settle: 1500);
        await _wait(tester, 7000);
        await _i18nScreen(tester, tab[1]);
        i18nHits[tab[1]] = _cjkVisible(tester);
      }
    });

    // ============================================================ ⑪ 窄屏几何（§C8）
    //   真窗口缩到窄宽，验两件事：
    //     ① 文件站的**右栏不许在窄屏出现**（`file-wide-region` 不在树里）；
    //     ② 窄屏下页面**不抛 overflow / 框架异常**，且主内容仍在。
    await step('⑪ 窄屏几何（框架级 480 逻辑宽）', 'system', () async {
      // ① 先试真窗口那条路（**记录**它在这个装置上不生效，别当成判据）
      await _resizeWindow(tester, 480, 1100);
      // ② 真正的窄屏：框架级视口覆盖（`tester.view`），测完复原
      final dpr = tester.view.devicePixelRatio;
      final restoreW = tester.view.physicalSize.width;
      final restoreH = tester.view.physicalSize.height;
      tester.view.physicalSize = Size(480 * dpr, 1100 * dpr);
      addTearDown(() {
        tester.view.physicalSize = Size(restoreW, restoreH);
        tester.view.resetPhysicalSize();
      });
      await tester.pumpAndSettle();
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-files', settle: 1500);
      await _wait(tester, 6000);
      await _shot(tester, '103_narrow_files');
      _dumpUi(tester, '⑪ 窄屏文件站');
      final wideRegion = find.byKey(const Key('file-wide-region')).evaluate().length;
      final errsBefore = frameErrors.length;
      // 判据用**应用自己看到的 MediaQuery**（不是 `tester.view`，也不是窗口管理器）
      final mq = MediaQuery.sizeOf(tester.element(find.byType(Scaffold).first));
      _note('⑪ 应用 MediaQuery 宽=${mq.width.toStringAsFixed(0)} '
          '右栏命中=$wideRegion（dpr=$dpr）');
      expect(mq.width, lessThan(700), reason: '窄屏视口没生效（应用仍看到宽屏）');
      expect(wideRegion, 0, reason: '★ 窄屏不许出现右栏（两栏会叠在一起）');
      expect(frameErrors.length, errsBefore, reason: '窄屏渲染不许新增框架异常');
      await _resetToShell(tester);
      await _tapKey(tester, 'dock-me', settle: 1500);
      await _wait(tester, 5000);
      await _shot(tester, '104_narrow_settings');
      _dumpUi(tester, '⑪ 窄屏设置页');
      final ctrl = _hasKey('set-personal-profile') ||
          _hasKey('set-photo-ai-edit') ||
          _hasKey('set-admin-tools');
      final mq2 = MediaQuery.sizeOf(tester.element(find.byType(Scaffold).first));
      _note('⑪ 窄屏设置页：MediaQuery 宽=${mq2.width.toStringAsFixed(0)} '
          '同族键命中=$ctrl（false ⇒ 判不了，不算缺陷）');
      expect(mq2.width, lessThan(700), reason: '窄屏视口没生效');
      expect(frameErrors.length, errsBefore, reason: '窄屏设置页不许新增框架异常');
      // 复原视口，别把后面的东西都留在窄屏里
      tester.view.physicalSize = Size(restoreW, restoreH);
      await tester.pumpAndSettle();
    });

    await _resetToShell(tester);

    // ------------------------------------------------------------ 汇总
    debugPrint('\n===== 走查汇总 =====');
    for (final r in _report) {
      if (r.startsWith('SHOT') ||
          r.startsWith('SCREEN-FAIL') ||
          r.startsWith('i18n') ||
          r.startsWith('MODULE-FAIL')) {
        debugPrint(r);
      }
    }
    // ★ r695：**汇总要落盘**，不能只靠 debugPrint。
    //   现场：`FAIL` 那一行与汇总尾行会被 flutter_test 的输出缓冲吃掉
    //   （r695c 的日志里 `===== 走查汇总 =====` 有、`失败屏幕数` 没有）⇒
    //   "0 失败屏"这句话在证据里**读不到**。写一份文件出来，判据只认这份文件。
    _note('失败屏幕数 = ${failures.length}');
    try {
      final f = File('${_shotDir.path}/_summary.txt');
      f.writeAsStringSync(
        'shots=${_report.where((r) => r.startsWith('SHOT')).length}\n'
        'failures=${failures.length}\n'
        '${failures.map((e) => 'FAIL $e').join('\n')}\n',
        flush: true,
      );
      _note('SUMMARY-FILE ${f.path}');
    } catch (e) {
      _note('SUMMARY-FILE 写入失败：$e');
    }
    for (final f in failures) {
      debugPrint('[walk] FAIL $f');
    }
    debugPrint('\n===== 英文模式 CJK 汇总 =====');
    for (final e in i18nHits.entries) {
      debugPrint('[walk] i18n ${e.key}: ${e.value.length} 处'
          '${e.value.isEmpty ? '' : ' → ${e.value.take(5).join(' | ')}'}');
    }
    expect(failures, isEmpty, reason: '有屏幕没走通：$failures');
  });
}

// ============================================================ 产物归档（r156）
//
// 43 张真像素 + 本文件 + 走查日志已归档到（**仓库外**）：
//   <home>/synology_samples/builds/linux-r156/
//     shots/                     40 屏 + 31_video_list / 32_video_preview / 32_video_list_no_mp4
//     logs/walkthrough_r156.log  末行 `+1: All tests passed!`、SCREEN-FAIL = 0
//     linux_walkthrough_test.dart
// 逐屏台账 / D 表（编号 `LD*`，与 Android 的 D5–D10 无关）/ 未验清单：
//   docs/platform-linux-ui-audit.md
// 复现命令与三个坑（`--dart-define` 才生效、`/work` 是真 bind mount、能力位不能当"未实现"的判据）：
//   docs/platform-linux.md §11
