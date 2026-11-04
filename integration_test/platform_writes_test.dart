// **写动词的跨平台走查**（macOS / Linux 都能跑，iOS/Web 见各自档案）。
//
// 为什么要有它（第 319 轮，补 `docs/platform-macos.md` §3 backlog 第 7 条）：
//   八模块的"读"已在 r63/r131 走查过，**写侧一直是空账** —— 不是没人做，
//   是原来的走查铁律禁止变更动词（那时打的是真 NAS）。macOS 上没有
//   `SYNO_NAS_PASSWORD`（宿主机 Keychain 里也没有，§2.0.39），所以真 NAS 写动词
//   在这台机器上**不可得**；能做的、也应当做的是**打到可写 Mock**：
//   `tool/mock_dsm --fs-demo` 装了一棵**内存文件系统**（`mock_fs_demo.dart`），
//   创建/改名/删除**真的改状态** ⇒ 判据是"服务端列表里有没有"，不是界面的乐观更新。
//
// 判据（每条都取服务端状态 + 界面像素）：
//   ① 登录 mock → 文件页出现种子目录（读链路基线）
//   ② 新建文件夹 → **列表里真的多出这一条**（先拍 before，再拍 after）
//   ③ 重命名 → 新名在、旧名不在
//   ④ 删除 → 列表里真的没了
//   ⑤ 上传 → 真字节进 Mock 的内存树（37 B）
//   ⑥ 新建下载任务 → **另一个客户端（HTTP 直连 Mock）**也看得到这条任务
//      （不靠 App 自己的乐观更新：判据是"服务端队列里有没有"）
//
// ⚠️ 跑法（**必须带 mock 参数**，别打到真 NAS）：
//   dart run tool/mock_dsm/bin/serve.dart --port 18080 --fs-demo --admin &
//   flutter test integration_test/platform_writes_test.dart -d macos \
//     --dart-define=WRITE_URL=http://127.0.0.1:18080
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/features/files/file_download_tasks.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/core/platform/app_paths.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/platform/fs_bookmark.dart';
import 'package:synhub/src/features/files/media_store_save.dart';
import 'package:synhub/src/features/files/file_upload_picker.dart';
import 'package:synhub/src/features/files/file_row.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/notes/note_background_sync_scheduler.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/session_controller.dart';
import 'package:synhub/src/core/router/app_router.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/downloads/download_create_page.dart';
import 'package:synhub/src/features/notes/notes_page.dart';
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart'
    show fotoApiProvider, photoTimelineProvider;
import 'package:synhub/src/features/shell/app_shell_page.dart';

const String _url = String.fromEnvironment(
  'WRITE_URL',
  defaultValue: 'http://127.0.0.1:18080',
);
const String _account = String.fromEnvironment(
  'WRITE_ACCOUNT',
  defaultValue: 'mockuser',
);
const String _password = String.fromEnvironment(
  'WRITE_PASSWORD',
  defaultValue: 'mockpass',
);

/// 聊天用例用的频道号：`tool/mock_dsm/fixtures/SYNO.Chat.Channel.list.json`
/// 里第一条 `general`（`is_joined: true`）。Mock 的聊天内存库按频道号隔离。
const int kMockChatChannelId = 1;

/// 截图落点 = App 容器 tmp（沙箱只许写容器内；与 r63 走查同口径）。
final Directory _shotDir =
    Directory('${Directory.systemTemp.path}/macwrite_r319')
      ..createSync(recursive: true);

final GlobalKey _rootKey = GlobalKey(debugLabel: 'write-root');
final List<String> _report = <String>[];

void _note(String s) {
  _report.add(s);
  debugPrint('[write] $s');
}

Future<void> _wait(WidgetTester tester, [int ms = 400]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 60));
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  String what,
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 80));
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  // ★ 第 328 轮：超时要把**屏上到底有什么**带出来。
  //   原来只有一句"等待超时：xxx"，于是"等不到锚点"到底是
  //   ①空态 ②错误态 ③还在转圈 —— 三种完全不同的根因，现场一个判据都没有
  //   （r328 为此白跑了一轮集成）。诊断串是**给排障看的**，不是用户文案（§2.0.47）。
  throw StateError('等待超时：$what ｜ 屏上文字：${_texts(tester)}');
}

/// 应用内自渲染像素（与 r63 走查同一手法：`RenderRepaintBoundary.toImage`）。
Future<int> _shot(WidgetTester tester, String name) async {
  final boundary =
      _rootKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (boundary == null) return 0;
  final img = await boundary.toImage(pixelRatio: 2);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  if (bd == null) return 0;
  final f = File('${_shotDir.path}/$name.png')..createSync(recursive: true);
  f.writeAsBytesSync(bd.buffer.asUint8List());
  return bd.lengthInBytes;
}

bool _hasText(String needle) => find
    .byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').contains(needle),
    )
    .evaluate()
    .isNotEmpty;

/// 当前屏幕上可见的文案（排障用：失败时把"到底看到什么"写进 reason）。
String _texts(WidgetTester tester) {
  final out = <String>[];
  for (final e in find.byType(Text).evaluate()) {
    final d = (e.widget as Text).data;
    if (d != null && d.isNotEmpty) out.add(d);
    // ★ r328 I4-b：上限 18 会把**尾部 footer**的文案正好截掉（相册那页
    //   前 18 条全是工具栏/底栏/分组头）⇒ 诊断里"没有"其实是"没打印"。
    // ★ 第 329 轮：26 又不够了 —— **对话框走 overlay，在树序里排在底栏之后**，
    //   26 条正好停在底栏（Chat|Files|Photos|Workspace）⇒ 任务行上的
    //   『存到本机』明明在屏上，诊断里却看不见。40 才够。

    if (out.length >= 40) break;
  }
  return out.join(' | ');
}

/// 相册时间轴尾部的**四态**探针（§2.0.50：诊断必须带"屏上到底是什么态"）。
///
/// `_TimelineFooter` 一共只可能落在这四种里，**每种一个 key**：
/// `all-loaded` / `load-more` / `loading-more`（转圈，**没有文案**）/ `load-more-retry`。
/// 第一版诊断只查了前两个 ⇒ 第三、四种会表现成"什么都没有"，是个**瞎的仪器**。
String _photoFooterStates(WidgetTester tester) {
  bool has(String k) => find.byKey(Key(k)).evaluate().isNotEmpty;
  final on = <String>[
    if (has('photo-timeline-all-loaded')) 'all-loaded',
    if (has('photo-timeline-load-more')) 'load-more',
    if (has('photo-timeline-loading-more')) 'loading-more',
    if (has('photo-timeline-load-more-retry')) 'load-more-retry',
  ];
  return on.isEmpty ? '（四态都没有！）' : on.join('+');
}

/// 相册时间轴那一根 `CustomScrollView` 自己的 `Scrollable`。
///
/// ★ 不能再用 `find.byType(Scrollable).first`：同屏还有顶栏密度/单元按钮的
///   **横向**滚动区，`.first` 会拖到它 ⇒ 纵向纹丝不动（"滚了但没滚"）。
Finder _photoTimelineScrollable() => find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    )
    .first;

/// **精确**判据：列表里有没有一个名字**恰好等于** [name] 的行。
///
/// ★ r319 踩到：改名后的提示条是 `Renamed to r319_x_renamed`，
/// 它**包含**旧名 `r319_x` ⇒ 用 `Text.contains` 判"旧名还在不在"会永远为真，
/// 用例就把一次成功的改名报成失败（假红）。列表判据只能看
/// `FileRow.entry.name` 这种**结构字段**。
bool _hasRow(String name) => find
    .byWidgetPredicate((w) => w is FileRow && w.entry.name == name)
    .evaluate()
    .isNotEmpty;

/// 假选择器要返回的文件（`_uploadFile` 在点 FAB 之前设置，用完清空）。
String? _fakePickedPath;
String? _fakePickedName;

/// 相册假选择器的**闸门**（r325）。
///
/// ★ 为什么是 `Completer` 而不是一个回调：`photoUploadPickerProvider` 的类型是
///   **值** `Future<List<PhotoUploadPick>>`（不是函数），`_boot` 建 `ProviderScope`
///   时就把这个 future 交给它了 ⇒ 用回调写法的话，"选什么"在 boot 那一刻就定死了
///   （那时用例还没写临时文件）。闸门把决定权**推迟到点上传之前**。
Completer<List<PhotoUploadPick>> _photoPickGate =
    Completer<List<PhotoUploadPick>>();

/// 让下一次"选照片"返回这张真文件。
void _queuePhotoPick({
  required String path,
  required String name,
  required int mtimeMs,
}) {
  _photoPickGate.complete(<PhotoUploadPick>[
    PhotoUploadPick(path: path, name: name, mtimeMs: mtimeMs),
  ]);
}

ProviderContainer? _container(WidgetTester tester) {
  final el = find.byType(SynologyChatApp);
  if (el.evaluate().isEmpty) return null;
  return ProviderScope.containerOf(tester.element(el.first), listen: false);
}

Future<void> _boot(WidgetTester tester) async {
  WidgetsFlutterBinding.ensureInitialized();
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
          // ★ 原生选择器（macOS `NSOpenPanel`）自动化点不到 ⇒ 注入一个
          //   返回**指定临时文件**的假选择器（默认实现仍是 `FilePicker.pickFile()`，
          //   生产路径逐字不变）。见 `lib/src/features/files/file_upload_picker.dart`。
          // ★ 第 328 轮：宿主的"存到本机"走 `save_destination.dart` 的双轨，
          //   A 轨要弹 `NSOpenPanel`（自动化点不到）⇒ 这里注入"用户取消"
          //   （返回 null）⇒ 走 B 轨（容器 downloads）。生产默认实现在
          //   `test/host_file_save_test.dart` ① 里另有守卫（分派 + 生产注入点）。
          mediaStoreSaverProvider.overrideWithValue(
            HostFileSaveSaver(pickDirectory: () async => null),
          ),
          fileUploadPickerProvider.overrideWithValue(() async {
            final path = _fakePickedPath;
            if (path == null) return null;
            return PickedUploadFile(
              path: path,
              name: _fakePickedName ?? 'picked.bin',
              size: File(path).lengthSync(),
            );
          }),
          // ★ r325：相册的"选照片"同样走平台选择器（`file_picker`）⇒ 用
          //   `photoUploadPickerProvider` 这个缝注入**真文件**（字节由用例写），
          //   生产路径逐字不变（默认实现仍是 `FilePicker.pickFiles()`）。
          //   注意类型是**值**（future）⇒ 见 `_photoPickGate` 的说明。
          photoUploadPickerProvider.overrideWithValue(_photoPickGate.future),
        ],
        child: const SynologyChatApp(),
      ),
    ),
  );
  await _wait(tester, 2000);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('写动词走查：新建 → 列表可见 → 改名 → 删除（打在可写 Mock 上）', (
    tester,
  ) async {
    debugPrint('[write] 截图目录 = ${_shotDir.path}  目标 = $_url');
    await _boot(tester);

    final container = _container(tester)!;
    final ctl = container.read(sessionControllerProvider.notifier);
    // ⚠️ 状态对象是不可变快照：**每一次判断都要重新 read**（第一次我写成
    //    `final session = read(...)` 后反复看它 ⇒ `restoring` 永远是那个旧值，
    //    用例在"等 restore 结束"上超时，而且差点在真 NAS 会话上继续跑写动词）。
    bool isLoggedIn() => container.read(sessionControllerProvider).loggedIn;

    // ★★ r328 的一次**误诊**记录（第 11–15 次走查，别重犯）：
    //   那 5 次都停在"（登录）connect 开始"，Mock 一条请求都收不到，
    //   5 分钟后 "did not complete"。我一度判成"**登录前**做真 I/O 把
    //   `ctl.connect` 吊死了"（甚至加了 `tester.runAsync` 包一层）。
    //   **两个判断都错**：真因是 **D30**（登录钥匙串授权弹框把平台调用挂住 ——
    //   `sample` 里 `SecItemCopyMatching` 停住、`SecurityAgent` 在位），
    //   与"登录前后的 I/O 时序"**无关**（把它挪回登录后照样挂，见第 15 次）。
    //   修法在**产品侧**：`appSecureStorage()` 的 `SecureStorageGate`
    //   超时+熔断（`lib/src/core/platform/app_secure_storage.dart`）。
    //   第 16 次走查 `All tests passed!`（04:13，03:03 → 04:13 的那 70 s 就是
    //   一次 45 s 闸门超时 + 余量）。

    // ---- 登录
    //
    // ★★ 安全闸门（**先于任何写动词**）：本用例只允许打 Mock。
    //    宿主上 App 可能"冷启动静默重登"到**真 NAS**（r319 实测确实发生了），
    //    那种情况下继续往下跑就等于对用户的 NAS 做 create/rename/delete。
    //    所以这里先登出、再连 Mock，并在写之前核对 endpoint 逐字相等。
    if (container.read(sessionControllerProvider).restoring) {
      await _waitFor(
        tester,
        'restore 结束',
        () => !container.read(sessionControllerProvider).restoring,
        timeout: const Duration(seconds: 90),
      );
    }
    if (isLoggedIn()) {
      _note('① 启动时已静默重登（可能是真 NAS）⇒ 先登出，改用 Mock');
      await ctl.logout();
      await _wait(tester, 2000);
    }
    _note('（登录）connect 开始');
    final ok = await ctl.connect(
      ServerProfile(kind: ServerAddressKind.direct, value: _url),
    );
    _note('（登录）connect → $ok');
    expect(ok, isTrue, reason: '要能连上 Mock：$_url');
    final logged = await ctl.login(account: _account, password: _password);
    _note('（登录）login → $logged');
    expect(logged, isTrue, reason: '要能登录 Mock（$_account）');
    await _waitFor(
      tester,
      '进入主壳',
      isLoggedIn,
      timeout: const Duration(seconds: 60),
    );
    await _wait(tester, 3000);
    final live = container.read(sessionControllerProvider);
    expect(
      live.connection?.profile.value,
      _url,
      reason: '★ 写动词之前必须确认打的是 Mock（不是真 NAS）',
    );
    _note('② 会话 endpoint = ${live.connection?.profile.value}');
    final bytes0 = await _shot(tester, '00_logged_in');
    _note('① 登录成功：$_account@$_url（首图 $bytes0 字节）');

    // ---- 进文件页
    container.read(appTabProvider.notifier).select(AppTab.files);
    await _wait(tester, 3500);
    await _waitFor(
      tester,
      '共享文件夹列表出现',
      () => _hasText('home') || _hasText('photo'),
      timeout: const Duration(seconds: 45),
    );
    final before = await _shot(tester, '01_shares_before');
    _note('② 文件页已渲染（$before 字节），种子共享可见');

    // ---- ② 新建文件夹
    final folderName =
        'r319_write_${DateTime.now().millisecondsSinceEpoch % 100000}';
    final created = await _createFolder(tester, container, folderName);
    _note('③ 新建文件夹 $folderName → ${created.ok ? '成功' : '失败（${created.why}）'}');
    expect(created.ok, isTrue, reason: '新建文件夹要走通：${created.why}');
    await _wait(tester, 2500);
    final after = await _shot(tester, '02_created');
    expect(
      _hasRow(folderName),
      isTrue,
      reason: '新建后的**服务端列表**里必须真有它（判据是列表，不是提示条）',
    );
    _note('④ 列表里已出现 $folderName（$after 字节）—— 服务端状态，不是乐观更新');

    // ---- ③ 重命名
    final renamed = '${folderName}_renamed';
    final didRename = await _renameEntry(tester, folderName, renamed);
    _note(
      '⑤ 改名 $folderName → $renamed：'
      '${didRename.ok ? '成功' : '失败（${didRename.why}）'}',
    );
    expect(didRename.ok, isTrue, reason: didRename.why);
    await _wait(tester, 2500);
    await _shot(tester, '03_renamed');
    expect(_hasRow(renamed), isTrue, reason: '改名后新名字要在列表里');
    expect(_hasRow(folderName), isFalse, reason: '旧名字必须消失');

    // ---- ④ 删除
    final didDelete = await _deleteEntry(tester, renamed);
    _note('⑥ 删除 $renamed：${didDelete.ok ? '成功' : '失败（${didDelete.why}）'}');
    expect(didDelete.ok, isTrue, reason: didDelete.why);
    await _wait(tester, 2500);
    await _shot(tester, '04_deleted');
    expect(_hasRow(renamed), isFalse, reason: '删除后必须从列表消失');

    // ---- ⑤ 上传文件（写动词里**唯一带字节**的一条）
    //
    // 原生选择器（macOS `NSOpenPanel`）自动化点不到 ⇒ 用 `fileUploadPickerProvider`
    // 注入一个假选择器（默认实现仍是 `FilePicker.pickFile()`，生产路径不变）。
    // 判据：Mock 的 `List.list` 里出现该文件**且字节数等于我们写的字节数**。
    final upName = 'r319_up_${DateTime.now().millisecondsSinceEpoch % 100000}.bin';
    final upBytes = List<int>.generate(37, (i) => (i * 7) % 256);
    final tmpFile = File('${Directory.systemTemp.path}/$upName')
      ..writeAsBytesSync(upBytes);
    final up = await _uploadFile(tester, container, tmpFile.path, upName);
    _note('⑦ 上传 $upName（${upBytes.length} B）→ ${up.ok ? '成功' : '失败（${up.why}）'}');
    expect(up.ok, isTrue, reason: up.why);
    await _wait(tester, 2500);
    await _shot(tester, '05_uploaded');

    // ---- ★★ 第 329 轮：文件浏览器 →「下载到本机」→「存到本机」（**全真 UI 链**）----
    //
    // r328 记的那条诚实缺口原文是：「宿主『存到本机』按钮在集成里**不可达** ——
    // Mock 没有二进制 `FileStation.Download` 夹具」。缺口已补
    // （`mock_fs_demo.dart` 的 `rawFixture`：字节 = `(i*31+7)%256`，
    //  长度 = 树里登记的 `size` ⇒ 可独立重算核对）。
    // 现在这条链第一次**从界面**跑完，且每一段都有独立判据：
    //   ① 行 ⋮ → 『下载到本机』（真 HTTP 字节 → 容器内落盘）
    //   ② 任务对话框里出现 `download-task-save-<id>`（**真的下载完成了**才有这个键）
    //   ③ 点它 → 提示条里带**真路径**（B 轨容器目录 / 记住的目录）
    //   ④ 从容器外**读回真文件**逐字节比对（判据不是"界面说保存成功"）
    final upSize = upBytes.length;
    final upRow = find.byWidgetPredicate(
      (w) => w is FileRow && w.entry.name == upName,
    );
    expect(upRow.evaluate(), isNotEmpty, reason: '上传后列表里必须有这一行');
    final upMenu = find.descendant(
      of: upRow.first,
      matching: find.byIcon(Icons.more_vert),
    );
    expect(upMenu.evaluate(), isNotEmpty, reason: '行上没有 ⋮');
    await tester.tap(upMenu.first, warnIfMissed: false);
    await _wait(tester, 1200);
    final pickedDownload = await _tapTextAny(tester, const [
      'Download to this device',
      '下载到本机',
    ]);
    expect(
      pickedDownload,
      isTrue,
      reason: '行菜单里应有『下载到本机』（当前可见：${_texts(tester)}）',
    );
    _note('⑨ 行菜单已点『下载到本机』（真二进制夹具：$upSize B）');

    // 任务对话框里的"存到本机"键：**只有任务真的下载完才出现**
    // （`localPath != null`）⇒ 它出现本身就是"字节落盘了"的机制量。
    final saveBtn = find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> && k.value.startsWith('download-task-save-');
    });
    final saveDeadline = DateTime.now().add(const Duration(seconds: 40));
    while (DateTime.now().isBefore(saveDeadline)) {
      await _wait(tester, 500);
      if (saveBtn.evaluate().isNotEmpty) break;
    }
    expect(
      saveBtn.evaluate(),
      isNotEmpty,
      reason: '★ 下载完成后任务行上必须有『存到本机』（没有 ⇒ 要么没下完，'
          '要么界面没画出这个入口）\n'
          '  任务列表状态：${_downloadTaskDump(container)}\n'
          '  当前可见：${_texts(tester)}',
    );
    await _shot(tester, '05b_download_task_save');
    await tester.tap(saveBtn.first, warnIfMissed: false);
    await _wait(tester, 1500);

    // 提示条里的**真路径**（§2.0.57：只认结果里的位 + 必须说出文件在哪）
    //
    // ★★ 仪器缺陷 I6 的第二半（第 3 次走查才抓到）：**匹配词必须用"词干"**。
    //   落点文件名是 `<名字> (1).bin`（同名不覆盖）⇒ `contains(upName)`
    //   （带扩展名的完整原名）**永远不成立**，于是"提示条明明在屏上"却读不到，
    //   现象还是"savedPath == null"。两次走查都栽在这一处 ——
    //   教训：**判据字符串要按"将要变成什么"写，不是按"我喂进去什么"写**。
    final savedStem = upName.substring(0, upName.lastIndexOf('.'));
    String? savedPath;
    final pathDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(pathDeadline) && savedPath == null) {
      await _wait(tester, 400);
      // ★★ 第 329 轮（仪器缺陷 I6）：**不许从 `_texts()` 里捞路径**。
      //   `_texts()` 有 40 条上限，而提示条走的是 overlay —— 树序里排在
      //   **任务对话框之后**，正好被截掉 ⇒ 现象是"savedPath == null"，
      //   于是看起来像"产品没给出路径"。真相是：**文件早就存好了**
      //   （`…/Documents/downloads/r319_up_… (1).bin`，37 B，逐字节等于公式），
      //   只是仪表没读到那一行。§2.0.50：先修仪器，再报结论。
      //   正确读法 = **按类型直接取 SnackBar 的 content**（不受任何上限影响）。
      for (final e in find.byType(SnackBar).evaluate()) {
        final w = e.widget as SnackBar;
        final c = w.content;
        final d = c is Text ? (c.data ?? '') : '';
        if (d.contains(savedStem)) {
          savedPath = d
              .replaceAll(RegExp(r'^(Saved to|已保存到)\s*'), '')
              .trim();
          break;
        }
      }
    }
    expect(
      savedPath,
      isNotNull,
      reason: '★ 保存后必须**说出真路径**（只说"已保存"等于没说；'
          '当前可见：${_texts(tester)}）',
    );
    // ★ 路径里带的是**落点文件名**：B 轨的目标目录正好就是 App 私有的下载目录
    //   （`<容器>/Documents/downloads`）⇒ 同名已存在 ⇒ `_uniquePath` 自动加
    //   ` (1)`（「绝不覆盖」是硬要求）。所以这里比**词干**，不是完整原名。
    expect(savedPath, contains(savedStem), reason: '路径里必须带文件名（词干）');
    expect(savedPath, endsWith('.bin'), reason: '扩展名要保留');
    final savedFile = File(savedPath!);
    expect(
      savedFile.existsSync(),
      isTrue,
      reason: '★ 判据取**容器外的真文件系统**：$savedPath 必须真有文件',
    );
    // 夹具字节是公式生成的 ⇒ 用例自己重算一遍（不与被验实现共用生成器）
    final expectBytes = List<int>.generate(upSize, (i) => (i * 31 + 7) % 256);
    expect(
      savedFile.readAsBytesSync(),
      expectBytes,
      reason: '★ 逐字节相等：从 Mock 下来的字节，一路走到宿主文件',
    );
    _note('⑩ 存到本机 → $savedPath（$upSize B，逐字节核对通过）');
    await _shot(tester, '05c_saved_to_host');

    // ★★ 仪器缺陷 I7（第 4 次走查抓到）：**任务对话框是模态的，用完必须关**。
    //   不关的后果不是"多一个窗口"，而是**后面所有步骤全废**：行 ⋮ 被
    //   模态遮罩挡住 ⇒ 点不开菜单 ⇒ ⑧ 清理报"行菜单里没有 Delete"，
    //   看起来像"删除入口没了"。产品侧没有问题（`Close` 一直在屏上）。
    final closedDialog = await _tapTextAny(tester, const ['Close', '关闭']);
    expect(
      closedDialog,
      isTrue,
      reason: '下载任务对话框必须能关（关不掉的话后面的行菜单全被遮罩挡住）',
    );
    await _wait(tester, 900);

    // 收尾：把上传的文件删掉（判据 = 列表里没了）
    final didDeleteUp = await _deleteEntry(tester, upName);
    _note('⑧ 清理上传件：${didDeleteUp.ok ? '成功' : '失败（${didDeleteUp.why}）'}');
    expect(didDeleteUp.ok, isTrue, reason: didDeleteUp.why);

    // ★ 第 328 轮修的**仪器缺陷**（别嫌啰嗦，这条已经造成过一次假红）：
    //   下面这些用例原来隐含假设"下载队列开始时是空的"。可 Mock 的内存队列
    //   **跨轮次存活** —— 只要上一轮在 ㉔ 之前失败，残留任务就留在队列里，
    //   于是这一轮**同一标题**命中两条：`_serverTask(title)` 取第一条、
    //   收尾删的却是另一条 ⇒ 末尾"队列必须空"必然红（看起来像产品缺陷，其实是仪器）。
    //   前置条件要**主动建立**，不许依赖"上次跑得干净"（§2.0.27 同族）。
    final polluted = await _serverTasks();
    if (polluted.isNotEmpty) {
      _note('⓪ 前置清理：Mock 队列有 ${polluted.length} 条残留（上一轮失败留下的）：'
          '${_dumpServer(polluted)}');
      await _purgeServerTasks();
    }
    expect(await _serverTasks(), isEmpty, reason: '前置条件：下载队列必须是空的');

    // ---- ⑥ 新建下载任务（r320）
    //
    // 判据**不是**界面上的行：`_serverTaskTitles()` 另起一个 HTTP 客户端直连
    // Mock 问队列 ⇒ 拿到的是**服务端状态**（App 的乐观更新骗不到它）。
    // Mock 侧 `--download-demo` 装的是内存队列（`mock_ds_demo.dart`），
    // 上面那条前置清理保证了创建前是**空队列** ⇒ 看到的这一条必然是这一轮创建的。
    final dlTitle =
        'r320_dl_${DateTime.now().millisecondsSinceEpoch % 100000}.bin';
    final dlUrl = 'https://example.com/files/$dlTitle';
    final dl = await _createDownloadTask(tester, container, dlUrl, dlTitle);
    _note('⑨ 新建下载任务 $dlTitle → ${dl.ok ? '成功' : '失败（${dl.why}）'}');
    expect(dl.ok, isTrue, reason: dl.why);
    await _wait(tester, 1500);
    await _shot(tester, '07_download_task');
    // 再独立核一次"服务端队列里确实有它"（截图之后状态没变）
    expect(
      await _serverTaskTitles(),
      contains(dlTitle),
      reason: '★ 服务端队列里必须有这条任务（判据来自另一个客户端，不是界面）',
    );
    _note('⑩ 服务端队列（HTTP 直连）已含 $dlTitle');

    // ---- ⑪⑫ 暂停 / 恢复（r321；判据 = 服务端 status，3 ⇄ 2）
    final dlPause = await _toggleDownloadTask(
      tester,
      dlTitle,
      expectStatus: 3,
      what: '点行上的暂停键',
    );
    _note('⑪ 暂停 $dlTitle → ${dlPause.ok ? '成功' : '失败（${dlPause.why}）'}');
    expect(dlPause.ok, isTrue, reason: dlPause.why);
    await _wait(tester, 900);
    await _shot(tester, '08_download_paused');

    final dlResume = await _toggleDownloadTask(
      tester,
      dlTitle,
      expectStatus: 2,
      what: '点行上的恢复键',
    );
    _note('⑫ 恢复 $dlTitle → ${dlResume.ok ? '成功' : '失败（${dlResume.why}）'}');
    expect(dlResume.ok, isTrue, reason: dlResume.why);
    await _wait(tester, 900);

    // ---- ⑬ 删除下载任务（r320 第二个写动词；判据同 ⑨ = 服务端队列）
    final dlDel = await _deleteDownloadTask(tester, dlTitle);
    _note('⑬ 删除下载任务 $dlTitle → ${dlDel.ok ? '成功' : '失败（${dlDel.why}）'}');
    expect(dlDel.ok, isTrue, reason: dlDel.why);
    await _wait(tester, 1200);
    await _shot(tester, '09_download_deleted');
    expect(
      await _serverTaskTitles(),
      isNot(contains(dlTitle)),
      reason: '★ 服务端队列里不许还有这条任务',
    );
    _note('⑭ 服务端队列（HTTP 直连）已不含 $dlTitle');

    // ---- ⑧ r322：**行 ⋮「结束任务」**（`Task.delete` 的 `force_complete=true` 语义）
    //
    // 同一接口两种语义，判据必须能区分它们：
    //   * 不带 `force_complete` = **删除**（⑬ 已验：队列里没了）；
    //   * 带 `force_complete`   = **结束任务**（文件归档、`status` ⇒ 5、
    //     **任务留在列表**、此后不能续传）。
    // ★ 这条是 r321 修 Mock 缺陷 D21 的**反向验收**：D21 之前 Mock 把
    //   `force_complete` 当成删除 ⇒ "结束任务"会悄悄删掉用户的任务，
    //   而当时的用例只有"队列里没了"这一种断言，**恰好也是绿的**。
    final fcTitle =
        'r322_fc_${DateTime.now().millisecondsSinceEpoch % 100000}.bin';
    final fcCreate = await _createDownloadTask(
      tester,
      container,
      'https://example.com/files/$fcTitle',
      fcTitle,
    );
    _note('⑮ 新建下载任务 $fcTitle（准备「结束任务」）→ ${fcCreate.ok ? '成功' : '失败（${fcCreate.why}）'}');
    expect(fcCreate.ok, isTrue, reason: fcCreate.why);
    await _wait(tester, 1200);
    // ★ r322 第一版直接对"下载中"的任务找 ⋮ ⇒ 找不到（用例当场红）。
    //   读实现才明白：行上那个 ⋮ **是按任务状态门控的**
    //   （`task.isError || task.isPaused || (isFinished && isBt)`）——
    //   官方 quick action「结束任务」只给"已经落地了文件的"那些状态
    //   （文件会被归档 ⇒ 不能再续传）。所以用例必须先把任务带到那个状态。
    //   ★ 通式：**"这个动作写在哪一行" ≠ "它在哪些状态下能被点到"**；
    //     写用例前先读入口的**出现条件**，别把"状态门控"误判成"功能缺失"。
    final fcPause = await _toggleDownloadTask(
      tester,
      fcTitle,
      expectStatus: 3,
      what: '点行上的暂停键（让「结束任务」入口出现）',
    );
    _note('⑯a 暂停 $fcTitle（为「结束任务」入口创造状态）→ ${fcPause.ok ? '成功' : '失败（${fcPause.why}）'}');
    expect(fcPause.ok, isTrue, reason: fcPause.why);
    await _wait(tester, 1000);
    final fc = await _forceCompleteDownloadTask(tester, fcTitle);
    _note('⑯b 结束任务 $fcTitle → ${fc.ok ? '成功' : '失败（${fc.why}）'}');
    expect(fc.ok, isTrue, reason: fc.why);
    await _wait(tester, 1200);
    await _shot(tester, '10_force_complete');

    // ---- ⑨ r322：四个批量动作（`pause_condition`/`resume_condition`/
    //      `delete_condition` v2）—— 每一个都要有"**不该被动的那些不许动**"
    //      的反向断言，否则"批量"最容易变成"全删了也算绿"。
    final magTitle =
        'r322_mag_${DateTime.now().millisecondsSinceEpoch % 100000}.bin';
    final magUrl = 'magnet:?xt=urn:btih:C0FFEE0123456789&dn=$magTitle';
    final magCreate = await _createDownloadTask(
      tester,
      container,
      magUrl,
      magTitle,
    );
    _note('⑰ 新建 magnet 任务 $magTitle → ${magCreate.ok ? '成功' : '失败（${magCreate.why}）'}');
    expect(magCreate.ok, isTrue, reason: magCreate.why);
    await _wait(tester, 1200);
    final mag = await _serverTask(magTitle);
    expect(mag, isNotNull, reason: '★ 服务端队列里必须有这条 magnet 任务');
    expect(
      mag!.type,
      'bt',
      reason: '★ magnet ⇒ type=bt（Mock D20 修好后才能端到端证明；修之前一律 http）',
    );
    _note('⑱ 服务端读到 $magTitle 的 type=${mag.type}（magnet ⇒ bt，D20 的端到端判据）');

    final pauseAll = await _batchDownloadAction(tester, 'ds-batch-pause-all');
    expect(pauseAll.ok, isTrue, reason: pauseAll.why);
    var q = await _waitServer(
      (l) =>
          l.any((x) => x.title == magTitle && x.status == 3) &&
          l.any((x) => x.title == fcTitle && x.status == 5),
    );
    expect(
      q.where((x) => x.title == magTitle).first.status,
      3,
      reason: '全部暂停 ⇒ magnet 那条必须变 3；队列：${_dumpServer(q)}',
    );
    expect(
      q.where((x) => x.title == fcTitle).first.status,
      5,
      reason: '★ 已完成(5)的任务**不许**被"全部暂停"改动；队列：${_dumpServer(q)}',
    );
    _note('⑲ 批量「全部暂停」⇒ $magTitle=3，而已完成的 $fcTitle 仍=5');

    final resumeAll = await _batchDownloadAction(tester, 'ds-batch-resume-all');
    expect(resumeAll.ok, isTrue, reason: resumeAll.why);
    q = await _waitServer((l) => l.any((x) => x.title == magTitle && x.status == 2));
    expect(
      q.where((x) => x.title == magTitle).first.status,
      2,
      reason: '全部恢复 ⇒ magnet 那条必须回到 2；队列：${_dumpServer(q)}',
    );
    expect(
      q.where((x) => x.title == fcTitle).first.status,
      5,
      reason: '★ 已完成的仍不许被动；队列：${_dumpServer(q)}',
    );
    _note('⑳ 批量「全部恢复」⇒ $magTitle=2，$fcTitle 仍=5');

    // 错误任务：Mock 的仪器约定 = URL 里含 `fail` ⇒ 一创建就是错误态(101)。
    final badTitle =
        'r322_fail_${DateTime.now().millisecondsSinceEpoch % 100000}.bin';
    final badCreate = await _createDownloadTask(
      tester,
      container,
      'https://example.com/fail/$badTitle',
      badTitle,
    );
    _note('㉑ 新建"必然失败"任务 $badTitle → ${badCreate.ok ? '成功' : '失败（${badCreate.why}）'}');
    expect(badCreate.ok, isTrue, reason: badCreate.why);
    await _wait(tester, 1200);
    final bad = await _serverTask(badTitle);
    expect(
      bad?.status,
      101,
      reason: '★ 仪器约定：URL 含 fail ⇒ status=101（错误态）',
    );
    await _shot(tester, '11_error_task');

    final rmErr = await _batchDownloadAction(tester, 'ds-batch-remove-errors');
    expect(rmErr.ok, isTrue, reason: rmErr.why);
    q = await _waitServer((l) => !l.any((x) => x.title == badTitle));
    expect(
      q.map((x) => x.title),
      isNot(contains(badTitle)),
      reason: '删除错误任务 ⇒ 错误那条必须没；队列：${_dumpServer(q)}',
    );
    expect(
      q.map((x) => x.title),
      containsAll(<String>[magTitle, fcTitle]),
      reason: '★ 反向：正常(2)与已完成(5)的任务**都不许**被"删除错误任务"删掉；队列：${_dumpServer(q)}',
    );
    _note('㉒ 批量「删除错误任务」⇒ $badTitle 没了，$magTitle/$fcTitle 都还在');

    final clr = await _batchDownloadAction(tester, 'ds-batch-clear-finished');
    expect(clr.ok, isTrue, reason: clr.why);
    q = await _waitServer((l) => !l.any((x) => x.title == fcTitle));
    expect(
      q.map((x) => x.title),
      isNot(contains(fcTitle)),
      reason: '清除已完成 ⇒ status=5 的那条必须没；队列：${_dumpServer(q)}',
    );
    expect(
      q.map((x) => x.title),
      contains(magTitle),
      reason: '★ 反向：下载中(2)的任务不许被"清除已完成"删掉；队列：${_dumpServer(q)}',
    );
    _note('㉓ 批量「清除已完成」⇒ $fcTitle 没了，$magTitle 还在');
    await _shot(tester, '12_batch_done');

    // ---- ⑩ r323：改目的地（`Task.edit`）—— 这个封装**从 r1 起没有 caller**
    //      （§2.0.45「封装了但没有 caller = 死功能」），本轮把入口接上。
    //      判据 = 服务端 `Task/list` 里 `additional.detail.destination` 真的变了。
    final beforeDest = (await _serverTask(magTitle))?.destination ?? '';
    final edit = await _editDownloadDestination(
      tester,
      magTitle,
      '/volume1/video',
    );
    _note('㉔ 改目的地 $magTitle（$beforeDest → /volume1/video）→ ${edit.ok ? '成功' : '失败（${edit.why}）'}');
    expect(edit.ok, isTrue, reason: edit.why);
    // ★ 第 328 轮修的**第二个仪器缺陷**：原来紧跟着**读一次**服务端。
    //   而 `_editDownloadDestination` 点完保存就返回了（不等请求往返）⇒
    //   读回可能早于请求到达 Mock，看到旧值 ⇒ **假红**（r328 第一跑就是这么红的：
    //   同一份代码同一台 Mock，重跑就绿）。判据要**轮询到状态改变**。
    final afterQ = await _waitServer(
      (l) => l.any(
        (x) => x.title == magTitle && x.destination == '/volume1/video',
      ),
    );
    final afterDest =
        afterQ.where((x) => x.title == magTitle).firstOrNull?.destination ?? '';
    expect(
      afterDest,
      '/volume1/video',
      reason: '★ 服务端读回来的 destination 必须真的变了（不是"请求回了 success"）；'
          '队列：${_dumpServer(afterQ)}',
    );
    await _wait(tester, 1200);
    await _shot(tester, '13_edit_destination');

    // 收尾：把剩下那条删净（判据 = 服务端队列真的空）
    final clean = await _deleteDownloadTask(tester, magTitle);
    _note('㉕ 清理 $magTitle → ${clean.ok ? '成功' : '失败（${clean.why}）'}');
    expect(clean.ok, isTrue, reason: clean.why);
    final finalQ = await _serverTasks();
    expect(
      finalQ,
      isEmpty,
      reason: '★ 收尾后服务端队列必须是空的；实际：${_dumpServer(finalQ)}',
    );
    _note('㉖ 服务端队列（HTTP 直连）已清空（${finalQ.length} 条）');

    // ---- ⑪ r324：笔记模块的写动词（`Note/set` / `Note/create`）
    //
    // 为什么这一档值得单独做：文件站与下载站的写动词已经在 r319–r323 打穿，
    // 而**笔记模块在 Mock Server 上原来一条夹具都没有** ⇒ 「新建/编辑笔记」
    // 的"成功没有"在**跨进程**意义上是不可判定的（§2.0.38 的"未注册夹具 ⇒ 空 data"
    // 是契约，但它让写动词变成"看不见的"）。
    final nsBefore = await _serverNotes();
    _note('㉗ 进笔记模块前，服务端笔记库有 ${nsBefore.length} 条：${[for (final n in nsBefore) n.title].join(' / ')}');
    await _openNotesModule(tester);
    await _waitFor(
      tester,
      '笔记列表出现（种子笔记）',
      () =>
          find.byKey(const Key('note-row-note_1')).evaluate().isNotEmpty ||
          _hasText('mock seeded note'),
      timeout: const Duration(seconds: 40),
    );
    await _shot(tester, '14_notes_list');
    _note('㉘ 笔记列表已渲染（种子笔记可见）');

    final opened = await _openNoteEditor(tester, 'note_1');
    _note('㉙ 打开种子笔记的编辑器 → ${opened.ok ? '成功' : '失败（${opened.why}）'}');
    expect(opened.ok, isTrue, reason: opened.why);
    final newTitle = 'r324 改过的标题 ${DateTime.now().millisecondsSinceEpoch % 100000}';
    final edited = await _editNoteTitle(tester, newTitle);
    _note('㉚ 改标题并保存 → ${edited.ok ? '成功' : '失败（${edited.why}）'}');
    expect(edited.ok, isTrue, reason: edited.why);
    final afterEdit = await _serverNotes();
    final editedOnServer = afterEdit.where((n) => n.id == 'note_1').toList();
    expect(editedOnServer, hasLength(1), reason: '★ 服务端必须还有这条笔记（改 = set，不是删）');
    expect(
      editedOnServer.first.title,
      newTitle,
      reason: '★ 服务端回读的 title 必须真的变了；实际：${editedOnServer.first.title}',
    );
    expect(
      editedOnServer.first.ver,
      isNot(nsBefore.firstWhere((n) => n.id == 'note_1').ver),
      reason: '★ 乐观锁版本号必须 +1（服务端记账，不是"回了 success"）',
    );
    _note('㉛ 服务端回读：note_1.title=「${editedOnServer.first.title}」 ver='
        '${nsBefore.firstWhere((n) => n.id == 'note_1').ver}→${editedOnServer.first.ver}');

    // 返回列表 → 新建一条（`Note/create`）
    rootNavigatorKey.currentState?.maybePop();
    await _wait(tester, 1500);
    final createdTitle = 'r324 新笔记 ${DateTime.now().millisecondsSinceEpoch % 100000}';
    final madeNote = await _createNote(tester, createdTitle);
    _note('㉜ 新建笔记 → ${madeNote.ok ? '成功' : '失败（${madeNote.why}）'}');
    expect(madeNote.ok, isTrue, reason: madeNote.why);
    final afterCreate = await _serverNotes();
    expect(
      afterCreate.map((n) => n.title),
      contains(createdTitle),
      reason: '★ 服务端笔记库必须多出这一条；实际：${[for (final n in afterCreate) n.title].join(' / ')}',
    );
    expect(
      afterCreate.length,
      nsBefore.length + 1,
      reason: '★ 只该多一条（"新建"不许把种子笔记挤掉）；实际 ${afterCreate.length} 条',
    );
    await _shot(tester, '15_note_created');
    _note('㉝ 服务端回读：笔记库 ${afterCreate.length} 条，新笔记在列表里');

    // ---- ⑩ r325：相册写动词（上传照片）----
    //
    // 为什么打在 Mock 上：相册模块在 Mock Server 上**原来一条夹具都没有**
    // （§2.0.38 的"未注册夹具 ⇒ 空 data"契约），列表永远 0 条 ⇒「上传成功」
    // 在跨进程意义上不可判定。r325 新增 `--photo-demo`（内存相册库 +
    // `Browse.Item/list` + `Upload.Item/upload` + 二进制 `Thumbnail/get`）。
    // 判据链：点界面上传真文件 ⇒ **另起一个 HTTP 客户端**回读 `Browse.Item/list`
    // 看到新条目、且 `filesize` == 我们写的字节数、`time` == 我们给的照片时间。
    // ★ 第 328 轮修的**第三个仪器缺陷**：相册库也是**进程内存**，
    //   跨轮次存活。而时间轴用例的前提是"首屏就到底"
    //   （`photo-timeline-all-loaded` 锚点）。r328 实测：库里涨到 4 条后锚点
    //   **再也不出现**（分页没到底）——看起来像相册缺陷，其实是仪器不干净。
    //   删除走**真接口**（`Browse.Item/delete`，r328 给 Mock 补的夹具）+ 保留种子。
    //
    // ★ I4-b（**治本的那一半**）：壳里的 `WidgetSnapshotHost` 会
    //   `ref.listen(photoTimelineProvider)`，而**订阅本身就会初始化 provider**
    //   ⇒ App 登录一完成就把时间轴拉过一次（拿到的是**清理前**的那一页）。
    //   第 10 次走查实测：屏上分组计数 `4`、服务端回读 `2`，且 Mock 日志里
    //   `delete` 之后**再没有一条 `Browse.Item/list`** —— 它压根没再问。
    //   ⇒ 清完**必须**主动作废时间轴（下面 `container.invalidate`），
    //     否则"先清服务端"是**无效前置条件**。
    final purgedPhotos = await _purgeServerPhotosExceptSeeds();
    if (purgedPhotos > 0) {
      _note('（前置）相册库清理：删掉上一轮残留 $purgedPhotos 条（保留两条种子）');
    }
    final phBefore = await _serverPhotos();
    expect(
      phBefore,
      hasLength(2),
      reason: '前置条件：相册库只剩两条种子（否则时间轴首屏到不了底）；实际：'
          '${[for (final i in phBefore) i.filename].join(' / ')}',
    );
    _note('㉞ 进相册前，服务端时间轴 ${phBefore.length} 条：'
        '${[for (final i in phBefore) i.filename].join(' / ')}');
    final enteredPhotos = await _openPhotosModule(tester);
    _note('㉟ 进相册模块 → ${enteredPhotos.ok ? '成功（${enteredPhotos.why}）' : '失败（${enteredPhotos.why}）'}');
    expect(enteredPhotos.ok, isTrue, reason: enteredPhotos.why);
    // ★ I4-b 的后半：**主动作废**时间轴（等价于点相册头部的「刷新」，但不受
    //   "预取发生在哪一刻"的影响）⇒ 客户端必然拿到刚复核过的那 2 条。
    container.invalidate(photoTimelineProvider);
    await tester.pump(const Duration(milliseconds: 400));
    // 「没有更多了」锚点（§2.0.47）：2 条种子 < 页大小 ⇒ hasMore=false
    //
    // ★ r328 第四次仪器缺陷（I4）：原来这里**只**等锚点，而锚点是**滚动列表
    //   尾部**的一个 footer —— 分组头 + 瓦片高度随密度/字号变，它有时不在视口里
    //   （`_waitFor` 不等布局 ⇒ 同一份代码 5 次里 3 次超时，看起来像相册缺陷）。
    //   修法：先等"首屏真的画出来了"（分组头或任一 footer），**再滚到底复核**
    //   （§2.0.47 的"说没有必须先滚到锚点"反过来用在自己的前置条件上）；
    //   滚完还是 `load-more` ⇒ 那是**真** hasMore，诊断里能一眼看到。
    await _waitFor(
      tester,
      '时间轴首屏渲染（分组头/尾部锚点出现）',
      () =>
          find
              .byKey(const Key('photo-timeline-all-loaded'))
              .evaluate()
              .isNotEmpty ||
          find.byKey(const Key('photo-timeline-load-more')).evaluate().isNotEmpty ||
          find
              .byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(
                      'photo-timeline-section-',
                    ),
              )
              .evaluate()
              .isNotEmpty,
      timeout: const Duration(seconds: 40),
    );
    var anchorSeen = false;
    for (var i = 0; i < 8; i++) {
      if (find
          .byKey(const Key('photo-timeline-all-loaded'))
          .evaluate()
          .isNotEmpty) {
        anchorSeen = true;
        break;
      }
      // hasMore 还在 ⇒ 说明服务端还有下一页（2 条种子不该出现这种情况）
      if (find.byKey(const Key('photo-timeline-load-more')).evaluate().isNotEmpty) {
        break;
      }
      if (find
          .byKey(const Key('photo-timeline-loading-more'))
          .evaluate()
          .isNotEmpty) {
        // 正在续取：等它落地，别把"在转圈"当成"到底了"
        await tester.pump(const Duration(milliseconds: 600));
        continue;
      }
      await tester.drag(_photoTimelineScrollable(), const Offset(0, -260));
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(
      anchorSeen,
      isTrue,
      reason: '前置条件：时间轴到底（2 条种子 < 页大小）；实际尾部状态：'
          '${_photoFooterStates(tester)}；屏上（前 26 条文案）：${_texts(tester)}',
    );
    await _shot(tester, '16_photos_timeline');
    _note('㊱ 时间轴已渲染（种子一图一视频）');

    final upPhotoName =
        'r325_up_${DateTime.now().millisecondsSinceEpoch % 100000}.jpg';
    final upPhotoBytes = List<int>.generate(86, (i) => (i * 11) % 256);
    final tmpPhoto = File('${Directory.systemTemp.path}/$upPhotoName')
      ..writeAsBytesSync(upPhotoBytes);
    final photoMtimeMs = DateTime.now().millisecondsSinceEpoch;
    _queuePhotoPick(
      path: tmpPhoto.path,
      name: upPhotoName,
      mtimeMs: photoMtimeMs,
    );
    final uploadedPhoto = await _uploadPhotoFromTimeline(tester);
    _note('㊲ 上传照片 $upPhotoName（${upPhotoBytes.length} B）→ '
        '${uploadedPhoto.ok ? '成功' : '失败（${uploadedPhoto.why}）'}');
    expect(uploadedPhoto.ok, isTrue, reason: uploadedPhoto.why);

    final phAfter = await _serverPhotos();
    expect(
      phAfter.length,
      phBefore.length + 1,
      reason: '★ 服务端时间轴必须多出**恰好一条**；实际 ${phAfter.length} 条：'
          '${[for (final i in phAfter) i.filename].join(' / ')}',
    );
    final landed = phAfter.where((i) => i.filename == upPhotoName).toList();
    expect(
      landed,
      hasLength(1),
      reason: '★ 回读里必须有 $upPhotoName（判据取 list，不取 upload 的响应体）；实际：'
          '${[for (final i in phAfter) i.filename].join(' / ')}',
    );
    expect(
      landed.first.filesize,
      upPhotoBytes.length,
      reason: '★ 字节数必须等于我们写进临时文件的字节数（"真字节落库"的唯一判据）',
    );
    // ★ 第 325 轮踩到：客户端把 `mtimeMs` 换成服务端的**秒**用的是
    //   `(mtimeMs / 1000).round()`（**四舍五入**，不是截断）⇒ 用例里写
    //   `~/ 1000` 会有一半概率差 1 秒（毫秒余数 ≥500 时）——那是个**定时炸弹式**
    //   的假红。判据必须按客户端的口径算同一个数。
    expect(
      landed.first.time,
      (photoMtimeMs / Duration.millisecondsPerSecond).round(),
      reason: '★ 服务端按**秒**记账，且客户端的换算是四舍五入',
    );
    await _shot(tester, '17_photo_uploaded');
    _note('㊳ 服务端回读：时间轴 ${phAfter.length} 条，$upPhotoName='
        '${landed.first.filesize} B time=${landed.first.time}');

    // ---- ★ 第 328 轮：相册「上传到**指定文件夹**」（`Upload.Item/upload_to_folder`）----
    //
    // 为什么在集成档做、且**不经界面**：相册备份页的**源**是 `synhub/media`
    // （Android `MediaStore` 桥，`AppCapability.localMediaLibrary` 在
    // `kAndroidOnlyBridgeCapabilities` 里）⇒ 在 macOS 上"用界面选一批本机照片
    // 传进某个相册文件夹"这条链路**结构上不可得**，不许假装走过。
    // 可做且应当做的是：在**真跑起来的 macOS 进程**里调产品代码
    // （`FotoApi.uploadToFolder`，不是测试自造的 HTTP），再让**另一个客户端**
    // 回读 `Browse.Item/list?folder_id=…` 判"落进了哪个目录"。
    // ★ r325 的诚实缺口（evidence §99「本轮不涉及 upload_to_folder」）在这一轮闭掉。
    final folders = await _serverFolders();
    _note('㊹ 服务端根目录文件夹 ${folders.length} 个：'
        '${[for (final f in folders) '${f.id}=${f.name}'].join(' / ')}');
    expect(folders, isNotEmpty, reason: 'Mock 的 Browse.Folder/list 必须有夹具');
    final target = folders.last;

    final folderApi = _container(tester)?.read(fotoApiProvider);
    expect(folderApi, isNotNull, reason: '必须能从 App 容器里取到 FotoApi（真产品路径）');
    final folderPhotoName =
        'r328_folder_${DateTime.now().millisecondsSinceEpoch % 100000}.jpg';
    final folderPhotoBytes = List<int>.generate(57, (i) => (i * 7) % 256);
    final tmpFolderPhoto =
        File('${Directory.systemTemp.path}/$folderPhotoName')
          ..writeAsBytesSync(folderPhotoBytes);
    final folderMtimeMs = DateTime.now().millisecondsSinceEpoch;
    final inFolderBefore = await _serverPhotos(folderId: target.id);
    String uploadedId = '';
    String uploadError = '';
    try {
      uploadedId = await folderApi!.uploadToFolder(
        folderId: target.id,
        filePath: tmpFolderPhoto.path,
        fileName: folderPhotoName,
        mtimeMs: folderMtimeMs,
      );
    } catch (e) {
      uploadError = '$e';
    }
    _note('㊺ uploadToFolder(${target.id}/${target.name}) → '
        '${uploadError.isEmpty ? '成功 id=$uploadedId' : '失败（$uploadError）'}');
    expect(uploadError, isEmpty, reason: uploadError);

    final inFolderAfter = await _serverPhotos(folderId: target.id);
    expect(
      inFolderAfter.length,
      inFolderBefore.length + 1,
      reason: '★ 目标目录的回读只该多一条（判据取 list，不取 upload 的响应体）',
    );
    final landedInFolder = inFolderAfter
        .where((i) => i.filename == folderPhotoName)
        .toList();
    expect(landedInFolder, hasLength(1), reason: '★ 回读里必须有 $folderPhotoName');
    expect(
      landedInFolder.first.filesize,
      folderPhotoBytes.length,
      reason: '★ 字节数必须等于写进临时文件的数量',
    );
    expect(
      landedInFolder.first.folderId,
      target.id,
      reason: '★ 必须落进**指定**目录（upload_to_folder 的唯一语义）',
    );
    // ★ 成对反向断言：另一个目录的回读里**不许**出现它（否则"落进了指定目录"是假判据）
    final otherFolders = folders.where((f) => f.id != target.id).toList();
    if (otherFolders.isNotEmpty) {
      final other = await _serverPhotos(folderId: otherFolders.first.id);
      expect(
        other.where((i) => i.filename == folderPhotoName),
        isEmpty,
        reason: '★ ${otherFolders.first.id} 里不该有它（过滤真的生效）',
      );
    }
    _shot(tester, '17b_photo_folder_upload');
    _note('㊻ 服务端回读（目录 ${target.id}）：${inFolderAfter.length} 条，'
        '$folderPhotoName=${landedInFolder.first.filesize} B '
        'folder_id=${landedInFolder.first.folderId}');

    // 像素：切到相册的「Folders」板块 —— `upload_to_folder` 的落点在**界面**上
    // 就是这里（上面那张 17b 拍的还是**时间轴**，它证明不了"文件夹里多了一张"）。
    // ⚠️ 这一屏**不是**"界面驱动的上传"（macOS 上没有那条路，见上面的说明），
    //   只是把服务端已经收到的结果画出来 ⇒ 像素 + 回读两个判据各说各的，别混。
    final foldersChip = find.text('Folders');
    if (foldersChip.evaluate().isNotEmpty) {
      await _tapFinder(tester, foldersChip.first);
      await _wait(tester, 2500);
      final shotBytes = await _shot(tester, '17c_photo_folders_tab');
      _note('㊼ 相册「Folders」板块像素 ${shotBytes ~/ 1024} KB'
          '（目标目录 ${target.id}/${target.name} 应带上封面/计数）');
    } else {
      _note('㊼ 相册工具栏上没有「Folders」入口（屏上文字：${_texts(tester)}）');
    }

    // ---- ★ 第 328 轮：宿主「存到本机」（`HostFileSaveSaver` 的双轨）----
    //
    // 为什么**不**从界面点：那个按钮（`download-task-save-…`）只挂在
    // "**已下载到本机**的下载任务"上，而 Mock 没有二进制
    // `FileStation.Download` 夹具 ⇒ 集成走查里根本产生不了这样的任务，
    // 按钮**不可达**（这是"仪器没有"，不是"界面没有"，但结论一样：界面这条路
    // 在本装置上验不了）。
    // 于是改为在**真跑起来的 macOS 沙盒进程里**调产品实现本身，
    // 再回**真文件系统**读回来（判据 = 绝对路径 + 逐字节）。
    // ★ 这条同时验了一件单元测试验不了的事：**沙盒允许写那个目录**。
    final saver = _container(tester)?.read(mediaStoreSaverProvider);
    expect(saver, isNotNull, reason: '必须能从 App 容器里取到导出器（真产品路径）');
    final hostSaveName =
        'r328_hostsave_${DateTime.now().millisecondsSinceEpoch % 100000}.bin';
    final hostSaveBytes = List<int>.generate(31, (i) => (i * 5) % 256);
    final hostSrc = File('${Directory.systemTemp.path}/$hostSaveName')
      ..writeAsBytesSync(hostSaveBytes);
    final hostSaved = await saver!.saveToDownloads(
      sourcePath: hostSrc.path,
      name: hostSaveName,
    );
    _note('㊽ 宿主"存到本机" → ${hostSaved.ok ? '成功' : '失败'}'
        '${hostSaved.hostTrack ? '（本机路径轨）' : ''}：${hostSaved.uri ?? hostSaved.reason}');
    expect(hostSaved.ok, isTrue, reason: 'unsupported=${hostSaved.unsupported}');
    expect(
      hostSaved.hostTrack,
      isTrue,
      reason: '★ 宿主上必须报"本机路径轨"（否则界面会把容器路径藏起来）',
    );
    final hostSavedFile = File(hostSaved.uri!);
    expect(
      hostSavedFile.existsSync(),
      isTrue,
      reason: '★ 判据取**真文件系统**：路径必须真有文件（不是"回了 ok"）',
    );
    expect(
      hostSavedFile.readAsBytesSync(),
      hostSaveBytes,
      reason: '★ 逐字节相等',
    );
    expect(
      hostSaved.uri,
      contains('${Platform.pathSeparator}Documents${Platform.pathSeparator}'),
      reason: '★ B 轨的落点必须在容器的 Documents 下（如实告诉用户在哪）',
    );

    // ---- ★ 第 328 轮：**安全作用域书签**（backlog §3.4）在真沙盒里跑一次 ----
    //
    // 这一条验的是**离线用例验不到**的东西：
    //   ① entitlement `files.bookmarks.app-scope` 真的批了（没批 ⇒ `create`
    //      直接回 `{error}`，离线假桥永远看不见这一层）；
    //   ② Swift 桥真的在**跑起来的 App 里**注册过（能力位 available 但通道不在
    //      = 假 available）；
    //   ③ Keychain（`flutter_secure_storage`）在 macOS 上真的能存"上次选的目录"。
    // ★ 诚实边界：这里选的目录在**容器内**（真"容器外目录"必须由用户点面板，
    //   本机没有 Accessibility TCC ⇒ 点不到）；所以**沙箱扩展本身**没被逼到极限，
    //   被验到的是"书签往返 + 开/关扩展 + 真写进去"。
    // ★★ 第 330 轮：这一段是 **macOS 专有**的（`FsBookmarkBridge.swift` 只编进
    //   macOS target；iOS 虽有安全作用域书签 API，但 A 轨（`getDirectoryPath`）
    //   在 iOS 上根本拿不到目录 ⇒ iOS 上"记住目录"没有使用者，
    //   能力位就该是 unavailable）。所以 iOS 走查时**整段跳过并如实记录**，
    //   不许用"iOS 上它当然不支持"糊过去，也不许因为跳过就假装验过。
    final isMac = currentAppHost == AppHost.macos;
    if (!isMac) {
      _note('㊾ 安全作用域书签：本宿主（${currentAppHost.name}）不适用 ⇒ '
          '整段跳过（能力位 unavailable；A 轨在 iOS 上拿不到目录）');
    }
    final bmContainer = isMac ? _container(tester) : null;
    final bmBridge = bmContainer?.read(fsBookmarkBridgeProvider);
    final recentStore = bmContainer?.read(recentSaveDirectoryStoreProvider);
    if (isMac) {
    expect(bmBridge, isNotNull, reason: '必须能取到书签桥（真产品路径）');
    expect(recentStore, isNotNull);
    expect(
      await bmBridge!.isSupported(),
      isTrue,
      reason: '★ macOS 上桥必须自报支持（否则能力位 available 是假的）',
    );
    final bmDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}r328_bookmark_dir',
    )..createSync(recursive: true);
    final bookmark = await bmBridge.create(bmDir.path);
    _note('㊾a 书签生成 ${bookmark == null ? '失败' : '成功（${bookmark.length} 字符 base64）'}');
    expect(
      bookmark,
      isNotNull,
      reason: '★ entitlement `files.bookmarks.app-scope` 没批时这里必红',
    );
    final access = await bmBridge.startAccess(bookmark!);
    expect(access.ok, isTrue, reason: '解析必须成功：${access.reason}');
    expect(
      access.path.replaceAll('/private/', '/').replaceAll(RegExp(r'/+$'), ''),
      bmDir.path
          .replaceAll('/private/', '/')
          .replaceAll(RegExp(r'/+$'), ''),
      reason: '★ 解回的路径必须就是当初那个目录',
    );
    final bmFile = File('${access.path}${Platform.pathSeparator}r328_bm.bin')
      ..writeAsBytesSync(<int>[11, 22, 33]);
    expect(
      bmFile.readAsBytesSync(),
      <int>[11, 22, 33],
      reason: '★ 拿过扩展之后必须**真能写**（判据取文件系统，不取返回值）',
    );
    await bmBridge.stopAccess(bookmark);
    _note('㊾b 解书签 + 开/关扩展 + 真写盘：成功（${bmFile.path}）');

    // ③ "上次选的目录"落盘并读回来
    //
    // ★ r328 实测：**Keychain 这条路在本机不可用** —— ad-hoc 签名（无 team ID）下
    //   `flutter_secure_storage` 的 write/delete 抛
    //   `PlatformException(-34018 "A required entitlement is not present.")`、read 恒 null
    //   （探针原文见 `docs/evidence-r328/README.md` §4.5）⇒ 生产实现改成
    //   **容器内文件**（书签串不是秘密）。
    final recentName = 'r328_recent_${DateTime.now().millisecondsSinceEpoch % 100000}';
    await recentStore!.write(
      RecentSaveDirectory(path: '/tmp/$recentName', bookmark: bookmark),
    );
    final back = await recentStore.read();
    expect(back?.path, '/tmp/$recentName', reason: '★ 落盘往返（macOS 真写文件）');
    expect(back?.bookmark, bookmark);
    final recentFile = File(
      '${(await AppPaths.documentsDirectory()).path}/'
      '${FileRecentSaveDirectoryStore.dirName}/'
      '${FileRecentSaveDirectoryStore.fileName}',
    );
    expect(
      recentFile.existsSync(),
      isTrue,
      reason: '★ 判据取**真文件**（"读了回来"也可能是内存假象）：${recentFile.path}',
    );
    _note('㊾c 「上次选的目录」真落盘：${recentFile.path}（'
        '${recentFile.lengthSync()} B）');
    await recentStore.clear();
    expect(await recentStore.read(), isNull, reason: 'clear 之后必须真没了');
    expect(recentFile.existsSync(), isFalse, reason: 'clear 必须删掉那个文件');
    }

    // ---- ★ 第 326 轮：聊天「发一条消息」 ----
    //
    // 判据两层（缺一不可）：
    //   ① **界面层**：频道页的输入框只有在 `connId != null` 时才 `enabled`
    //      （`chat_page.dart:1676`），而 `connId` 来自 socket 的 `client.init`
    //      事件 —— 用例断言"输入框可用"，就是断言**握手真的走通了**；
    //   ② **服务端层**：另起一个 HTTP 客户端回读 `SYNO.Chat.Post/list`
    //      （不取 `Post/create` 的响应体）。
    // ★ Mock 侧还要**认这个 conn_id**（必须是本进程 socket 刚下发的那个，
    //   否则回 101）—— 这条保证了①不是"恰好非空"。
    final chatPostsBefore = await _serverPosts(kMockChatChannelId);
    _note('㊴ 进聊天前，服务端频道 $kMockChatChannelId 有 ${chatPostsBefore.length} 条：'
        '${[for (final m in chatPostsBefore) m.message].join(' / ')}');
    final enteredChat = await _openChatChannel(tester);
    _note('㊵ 进聊天频道 → ${enteredChat.ok ? '成功（${enteredChat.why}）' : '失败（${enteredChat.why}）'}');
    expect(enteredChat.ok, isTrue, reason: enteredChat.why);
    await _shot(tester, '18_chat_channel');

    final composer = await _chatComposerReady(tester);
    _note('㊶ 输入框可用性（= `connId` 非空 = socket 握手成功）→ '
        '${composer.ok ? '可用' : '不可用（${composer.why}）'}');
    expect(composer.ok, isTrue, reason: composer.why);

    final chatText = 'r326 发出去的第 ${DateTime.now().millisecondsSinceEpoch % 100000} 条';
    final sent = await _sendChatMessage(tester, chatText);
    _note('㊷ 发消息「$chatText」→ ${sent.ok ? '成功' : '失败（${sent.why}）'}');
    expect(sent.ok, isTrue, reason: sent.why);

    final chatPostsAfter = await _serverPosts(kMockChatChannelId);
    expect(
      chatPostsAfter.length,
      chatPostsBefore.length + 1,
      reason: '★ 服务端必须多出**恰好一条**；实际 ${chatPostsAfter.length} 条：'
          '${[for (final m in chatPostsAfter) m.message].join(' / ')}',
    );
    expect(
      [for (final m in chatPostsAfter) m.message],
      contains(chatText),
      reason: '★ 回读里必须有刚发的那句话（判据取 `Post/list`，不取响应体）；实际：'
          '${[for (final m in chatPostsAfter) m.message].join(' / ')}',
    );
    _note('㊸ 服务端回读：频道 $kMockChatChannelId 现在 ${chatPostsAfter.length} 条，'
        '最后一条=「${chatPostsAfter.last.message}」');
    await _shot(tester, '19_chat_sent');

    debugPrint('[write] ---- 结论 ----');
    for (final l in _report) {
      debugPrint('[write] $l');
    }
  });
}

/// 进到 `/home`（**导航走 provider**：本用例的被测对象是"写动词的 UI 链路"，
/// 不是"点一下能不能进目录"——那一条在 r63/r131 走查里已经单独验过）。
Future<bool> _enterHome(WidgetTester tester, ProviderContainer container) async {
  container.read(fileBrowseStackProvider.notifier).open('/home');
  // 种子文件 `/home/mockfs_home.txt` 出现在列表 = 服务端确实回了这个目录
  await _waitFor(
    tester,
    '/home 列表出现（种子文件）',
    () => _hasText('mockfs_home.txt'),
    timeout: const Duration(seconds: 30),
  );
  return true;
}

/// `FAB(New / Upload) → New folder → 填名 → Create`。
///
/// 为什么用 FAB 而不是顶栏 ⋮：`_showCreateSheet` 只挂在 FAB 上（见
/// `file_browse_page.dart` 的 `floatingActionButton`），顶栏那段是筛选/视图。
///
/// 返回 `(成功?, 卡在哪一步)` —— 失败必须能说清是哪一步，否则下一个人只能重跑。
Future<({bool ok, String why})> _createFolder(
  WidgetTester tester,
  ProviderContainer container,
  String name,
) async {
  if (!await _enterHome(tester, container)) {
    return (ok: false, why: '进 /home 失败');
  }
  await _waitNoSnackBar(tester);
  if (!await _tapTooltipAny(tester, const ['New / Upload', '新建 / 上传'])) {
    return (ok: false, why: '找不到 FAB（New / Upload）');
  }
  await _wait(tester, 900);
  if (!await _tapTextAny(tester, const ['New folder', '新建文件夹'])) {
    return (ok: false, why: 'FAB 面板里没有 New folder');
  }
  await _wait(tester, 900);
  final fields = find.byType(TextField);
  if (fields.evaluate().isEmpty) {
    return (ok: false, why: '命名对话框没出现输入框');
  }
  await tester.enterText(fields.last, name);
  await _wait(tester, 400);
  if (!await _tapButtonAny(tester, const ['Create', '创建', '确定', 'OK'])) {
    return (ok: false, why: '命名对话框里找不到 Create');
  }
  // 判据 = **服务端列表**里出现（不是提示条、不是乐观插入）
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await _wait(tester, 500);
    if (_hasRow(name)) return (ok: true, why: '列表已出现');
  }
  return (ok: false, why: '创建后列表里没有这一条');
}

/// 行尾 `⋮ → Rename`（`showFileItemSheet` 的 `photoRename`）。
///
/// 行定位用 `FileRow.entry.name`（不是 `find.byTooltip('More actions')` 的第 N 个：
/// 那种按下标取元素的做法在列表重排时会静默点错行）。
Future<({bool ok, String why})> _renameEntry(
  WidgetTester tester,
  String from,
  String to,
) async {
  final row = find.byWidgetPredicate(
    (w) => w is FileRow && w.entry.name == from,
  );
  if (row.evaluate().isEmpty) return (ok: false, why: '列表里找不到行 $from');
  final menu = find.descendant(
    of: row.first,
    matching: find.byIcon(Icons.more_vert),
  );
  if (menu.evaluate().isEmpty) return (ok: false, why: '行上没有 ⋮');
  await tester.tap(menu.first, warnIfMissed: false);
  await _wait(tester, 1000);
  if (!await _tapTextAny(tester, const ['Rename', '重命名'])) {
    return (ok: false, why: '行菜单里没有 Rename');
  }
  await _wait(tester, 1000);
  final fields = find.byType(TextField);
  if (fields.evaluate().isEmpty) {
    return (ok: false, why: '改名对话框没出现输入框');
  }
  await tester.enterText(fields.last, to);
  await _wait(tester, 400);
  if (!await _tapButtonAny(tester, const ['Rename', '重命名', 'OK', '确定'])) {
    return (ok: false, why: '改名对话框里找不到确认键');
  }
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await _wait(tester, 500);
    if (_hasRow(to) && !_hasRow(from)) return (ok: true, why: '新名在、旧名没了');
  }
  return (ok: false, why: '改名后列表里没变成 $to（新名在=${_hasRow(to)}）');
}

/// 行尾 `⋮ → Delete → 确认`。
Future<({bool ok, String why})> _deleteEntry(
  WidgetTester tester,
  String name,
) async {
  final row = find.byWidgetPredicate(
    (w) => w is FileRow && w.entry.name == name,
  );
  if (row.evaluate().isEmpty) return (ok: false, why: '列表里找不到行 $name');
  final menu = find.descendant(
    of: row.first,
    matching: find.byIcon(Icons.more_vert),
  );
  if (menu.evaluate().isEmpty) return (ok: false, why: '行上没有 ⋮');
  await tester.tap(menu.first, warnIfMissed: false);
  await _wait(tester, 1000);
  if (!await _tapTextAny(tester, const ['Delete', '删除'])) {
    return (ok: false, why: '行菜单里没有 Delete（当前可见：${_texts(tester)}）');
  }
  await _wait(tester, 1200);
  // 危险确认框（`confirmDanger` 的确认键 = `dtoActionDelete`）
  if (!await _tapButtonAny(tester, const ['Delete', '删除', 'OK', '确定'])) {
    return (ok: false, why: '确认框里找不到删除键（当前可见：${_texts(tester)}）');
  }
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await _wait(tester, 500);
    if (!_hasRow(name)) return (ok: true, why: '列表里没了');
  }
  return (ok: false, why: '删除后列表里还有 $name（当前可见：${_texts(tester)}）');
}

/// `FAB(New / Upload) → Upload file`，**选择器可注入**（见 `file_upload_picker.dart`）。
///
/// 注意：这里**不改生产代码的默认行为** —— 只在测试里覆盖 provider，
/// 让"FAB → 选文件 → 冲突检测 → 上传 → 列表刷新"整链真的跑一遍。
Future<({bool ok, String why})> _uploadFile(
  WidgetTester tester,
  ProviderContainer container,
  String localPath,
  String name,
) async {
  if (!await _enterHome(tester, container)) {
    return (ok: false, why: '进 /home 失败');
  }
  // 让注入的假选择器返回这个文件（`_boot` 里已 override）
  _fakePickedPath = localPath;
  _fakePickedName = name;
  try {
    return await _uploadViaUi(tester, localPath, name);
  } finally {
    _fakePickedPath = null;
    _fakePickedName = null;
  }
}

/// **另起一个客户端**直接问 Mock：下载队列里现在有哪些任务。
///
/// 为什么不用界面上的列表当判据：下载页是"创建成功 → 重新拉列表"的形态，
/// 界面上的行**可能**来自乐观更新（r319 的上传就吃过一次"看着有、服务端没有"的
/// 反面教材）。这里绕开 App 走 HTTP 直连 Mock（`SYNO.API.Auth/login` 拿 sid →
/// `Task/list`），得到的是**服务端状态**这个独立判据。
///
/// 失败一律回空表（判据是"列表里有它"，拿不到就当没有，不许猜）。
/// 收掉屏上所有提示条（`SnackBar`），**推路由之前**必须调。
///
/// ★ 第 324 轮踩到（teardown 时抛异常，而 ㉗–㉝ 全都过了）：
///   `There are multiple heroes that share the same tag within a subtree.
///    In this case, multiple heroes had the following tag:
///    `SnackBar Hero tag - Text("Download destination updated")>`
///   根因在 Flutter 侧（`material/snack_bar.dart:877`）：
///   **每一条 `SnackBar` 都被包进 `Hero(tag: '<SnackBar Hero tag - ${content}>')`**
///   —— 标签由**文案**生成；而 `ScaffoldMessengerState._updateScaffolds()` 会把
///   当前提示条发给**每一个"根" Scaffold**（本 App 里 = 外壳那个 Scaffold +
///   被 push 的模块页自己的 Scaffold，它们是**兄弟**、各自都算 root）。
///   于是"提示条还挂着时推路由"就会让同一 tag 的 Hero 出现在两个子树里。
///   release 构建没有断言（只有 debug 抛），但**走查里它会污染判据**
///   ⇒ 每次推模块页之前先清干净（仪器动作，不是产品行为）。
void _dismissSnackBars() {
  final ctx = rootNavigatorKey.currentContext;
  if (ctx == null) return;
  ScaffoldMessenger.maybeOf(ctx)?.clearSnackBars();
}

/// 点一个 **Key** 定位的部件（r320：下载入口只能用 Key，文案会随语言变）。
Future<bool> _tapKey(WidgetTester tester, String key, {int settle = 700}) async {
  final f = find.byKey(Key(key));
  if (f.evaluate().isEmpty) return false;
  await _tapFinder(tester, f.first);
  await _wait(tester, settle);
  return true;
}

/// 直连 Mock 发一次 `entry.cgi` 表单请求（**另起一个客户端**的公共部分）。
Future<Map<String, dynamic>> _postDsm(Map<String, String> fields) async {
  final base = _url.endsWith('/') ? _url : '$_url/';
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('${base}webapi/entry.cgi'));
    req.headers.contentType = ContentType.parse(
      'application/x-www-form-urlencoded',
    );
    req.write(Uri(queryParameters: fields).query);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
  } catch (e) {
    debugPrint('[write] 直连 Mock 失败（${fields['api']}.${fields['method']}）：$e');
    return <String, dynamic>{};
  } finally {
    client.close(force: true);
  }
}

/// 直连 Mock 登录取 sid（`SYNO.API.Auth/login` v3）。
Future<String> _dsmSid() async {
  // mock 的登录**不校验口令**（它没有私钥、按配置发会话），带 account 即可
  final login = await _postDsm({
    'api': 'SYNO.API.Auth',
    'method': 'login',
    'version': '3',
    'account': _account,
    'passwd': _password,
    'session': 'webui',
    'format': 'sid',
  });
  return '${((login['data'] as Map?)?['sid']) ?? ''}';
}

/// **另起一个客户端**把 Mock 的下载队列删干净（用例的**前置条件**）。
///
/// 为什么需要它：Mock 的内存队列跨轮次存活，而这条用例假设"开始时是空的"。
/// 用直连 HTTP 删（不动界面），删完由调用方断言"真的空了"。
Future<void> _purgeServerTasks() async {
  final sid = await _dsmSid();
  if (sid.isEmpty) return;
  for (final t in await _serverTasks()) {
    await _postDsm({
      'api': 'SYNO.DownloadStation2.Task',
      'method': 'delete',
      'version': '2',
      '_sid': sid,
      'id': jsonEncode(<String>[t.id]),
    });
  }
}

Future<List<({String id, String title, int status, String type, String destination})>>
_serverTasks() async {
  try {
    final sid = await _dsmSid();
    if (sid.isEmpty) return const [];
    final list = await _postDsm({
      'api': 'SYNO.DownloadStation2.Task',
      'method': 'list',
      'version': '2',
      '_sid': sid,
      'offset': '0',
      'limit': '50',
    });
    final tasks = ((list['data'] as Map?)?['task'] as List?) ?? const [];
    return [
      for (final t in tasks)
        if (t is Map)
          (
            id: '${t['id']}',
            title: '${t['title']}',
            status: _asInt(t['status']),
            type: '${t['type']}',
            destination:
                '${(((t['additional'] as Map?)?['detail']) as Map?)?['destination'] ?? ''}',
          ),
    ];
  } catch (e) {
    debugPrint('[write] 直连 Mock 查队列失败：$e');
    return const [];
  }
}

/// **另起一个客户端**问 Mock：相册时间轴上现在有哪些照片。
///
/// 判据取 `SYNO.Foto.Browse.Item/list` 的**回读值** —— 不取 `Upload.Item/upload`
/// 的响应体（"回了 success" 说明不了字节真的落进了库）。
Future<List<({String id, String filename, int filesize, int time, String folderId})>>
_serverPhotos({String folderId = ''}) async {
  final sid = await _dsmSid();
  if (sid.isEmpty) return const [];
  final list = await _postDsm({
    'api': 'SYNO.Foto.Browse.Item',
    'method': 'list',
    'version': '7',
    '_sid': sid,
    'offset': '0',
    'limit': '50',
    'sort_by': 'takentime',
    'sort_direction': 'desc',
    // 空串 = 不过滤（时间轴）；非空 = 只回该目录里的条目
    if (folderId.isNotEmpty) 'folder_id': folderId,
  });
  final items = ((list['data'] as Map?)?['list'] as List?) ?? const [];
  return [
    for (final i in items)
      if (i is Map)
        (
          id: '${i['id']}',
          filename: '${i['filename']}',
          filesize: _asInt(i['filesize']),
          time: _asInt(i['time']),
          folderId: '${i['folder_id']}',
        ),
  ];
}

/// **另起一个客户端**把相册库清到"只剩种子"（用例的**前置条件**）。
///
/// 删除走**真接口** `SYNO.Foto.Browse.Item/delete`（`id` = JSON 数组文本），
/// 保留 `mock seeded ` 开头的两条种子。返回删掉的条数。
Future<int> _purgeServerPhotosExceptSeeds() async {
  final sid = await _dsmSid();
  if (sid.isEmpty) return 0;
  final all = await _serverPhotos();
  final stale = [
    for (final i in all)
      if (!i.filename.startsWith('mock seeded ')) i,
  ];
  if (stale.isEmpty) return 0;
  final r = await _postDsm({
    'api': 'SYNO.Foto.Browse.Item',
    'method': 'delete',
    'version': '7',
    '_sid': sid,
    'id': jsonEncode(<String>[for (final i in stale) i.id]),
  });
  return r['success'] == true ? stale.length : 0;
}

/// **另起一个客户端**问 Mock：根目录下有哪些相册文件夹（`Browse.Folder/list`）。
Future<List<({String id, String name})>> _serverFolders() async {
  final sid = await _dsmSid();
  if (sid.isEmpty) return const [];
  final list = await _postDsm({
    'api': 'SYNO.Foto.Browse.Folder',
    'method': 'list',
    'version': '2',
    '_sid': sid,
    'id': '0',
    'offset': '0',
    'limit': '50',
  });
  final items = ((list['data'] as Map?)?['list'] as List?) ?? const [];
  return [
    for (final f in items)
      if (f is Map) (id: '${f['id']}', name: '${f['name']}'),
  ];
}

/// **另起一个客户端**问 Mock：某个频道里现在有哪些消息。
///
/// 判据取 `SYNO.Chat.Post/list` 的**回读值** —— 不取 `Post/create` 的响应体
/// （"回了 success" 说明不了消息真的落进了库）。
Future<List<({int postId, String message, int createAt})>> _serverPosts(
  int channelId,
) async {
  final sid = await _dsmSid();
  if (sid.isEmpty) return const [];
  final list = await _postDsm({
    'api': 'SYNO.Chat.Post',
    'method': 'list',
    'version': '2',
    '_sid': sid,
    'channel_id': '$channelId',
    'prev_count': '50',
    'next_count': '0',
  });
  final posts = ((list['data'] as Map?)?['posts'] as List?) ?? const [];
  return [
    for (final m in posts)
      if (m is Map)
        (
          postId: _asInt(m['post_id']),
          message: '${m['message']}',
          createAt: _asInt(m['create_at']),
        ),
  ];
}

/// **另起一个客户端**问 Mock：笔记库里现在有哪些笔记。
///
/// 判据取 `SYNO.NoteStation.Note/list` 的**回读值**（不是"请求回了 success"），
/// 与 r319/r322/r323 的下载/文件判据同一条纪律。
Future<List<({String id, String title, String ver})>> _serverNotes() async {
  final sid = await _dsmSid();
  if (sid.isEmpty) return const [];
  final list = await _postDsm({
    'api': 'SYNO.NoteStation.Note',
    'method': 'list',
    'version': '4',
    '_sid': sid,
    'field': '["object_id","title","brief","parent_id","ctime","mtime","ver"]',
    'sort_by': 'mtime',
    'sort_direction': 'desc',
  });
  final notes = ((list['data'] as Map?)?['notes'] as List?) ?? const [];
  return [
    for (final n in notes)
      if (n is Map)
        (
          id: '${n['object_id']}',
          title: '${n['title']}',
          ver: '${n['ver']}',
        ),
  ];
}

/// 只要标题（多数判据用不到 id）。
Future<List<String>> _serverTaskTitles() async =>
    [for (final t in await _serverTasks()) t.title];

int _asInt(Object? v) => switch (v) {
  int i => i,
  num n => n.toInt(),
  String s => int.tryParse(s) ?? 0,
  _ => 0,
};

/// `任务行 ⏸/▶ → 服务端 status 必须真的变`（`Task.pause`/`Task.resume` v2）。
///
/// ★ 判据仍是**另一个客户端**读到的队列状态，不是界面上那个图标 ——
///   图标是"我请求过"的表示，服务端 status 才是"事情真的发生了"。
Future<({bool ok, String why})> _toggleDownloadTask(
  WidgetTester tester,
  String title, {
  required int expectStatus,
  required String what,
}) async {
  final tasks = await _serverTasks();
  final hit = tasks.where((t) => t.title == title).toList();
  if (hit.isEmpty) return (ok: false, why: '服务端队列里没有 $title');
  final key = Key('ds-toggle-${hit.first.id}');
  if (find.byKey(key).evaluate().isEmpty) {
    return (ok: false, why: '行上没有 $key；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, find.byKey(key));
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await _wait(tester, 700);
    final now = await _serverTasks();
    final cur = now.where((t) => t.title == title).toList();
    if (cur.isEmpty) return (ok: false, why: '任务不见了');
    if (cur.first.status == expectStatus) {
      return (ok: true, why: '$what ⇒ status=${cur.first.status}');
    }
  }
  final now = await _serverTasks();
  final cur = now.where((t) => t.title == title).toList();
  return (
    ok: false,
    why: '$what 后期望 status=$expectStatus，实际 ${cur.isEmpty ? '任务不见了' : cur.first.status}',
  );
}

/// `任务行 ⋮/垃圾桶 → Delete → 确认` ⇒ 服务端队列里真的没了。
///
/// ★ 用**服务端给的真实 id** 定位按钮（`Key('ds-delete-<id>')`），不靠猜：
///   行上那个 `IconButton` 的 key 就是 `ds-delete-${task.id}`。
Future<({bool ok, String why})> _deleteDownloadTask(
  WidgetTester tester,
  String title,
) async {
  final tasks = await _serverTasks();
  final hit = tasks.where((t) => t.title == title).toList();
  if (hit.isEmpty) return (ok: false, why: '服务端队列里没有 $title');
  final row = find.byKey(Key('ds-delete-${hit.first.id}'));
  if (row.evaluate().isEmpty) {
    return (ok: false, why: '行上没有 ds-delete-${hit.first.id}；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, row);
  await _wait(tester, 900);
  if (find.byKey(const Key('ds-delete-dialog')).evaluate().isEmpty) {
    return (ok: false, why: '删除确认框没出现；屏上文字：${_texts(tester)}');
  }
  if (!await _tapButtonAny(tester, const ['Delete', '删除'])) {
    return (ok: false, why: '确认框里找不到 Delete');
  }
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    await _wait(tester, 700);
    final now = await _serverTaskTitles();
    if (!now.contains(title)) {
      // 服务端已消失；界面这一行也该消失（刷新回来）
      final uiDeadline = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(uiDeadline)) {
        if (!_hasText(title)) return (ok: true, why: '服务端 + 界面都没了');
        await _wait(tester, 500);
      }
      return (ok: true, why: '服务端已删（界面那一行还在渲染，判据以服务端为准）');
    }
  }
  return (ok: false, why: '服务端队列里 $title 还在');
}

/// 服务端队列里按标题取一条（带 `type`）。
Future<({String id, String title, int status, String type, String destination})?> _serverTask(
  String title,
) async {
  for (final t in await _serverTasks()) {
    if (t.title == title) return t;
  }
  return null;
}

/// 轮询服务端直到满足 [until]；返回最后一次读到的队列（便于写失败原因）。
Future<List<({String id, String title, int status, String type, String destination})>>
_waitServer(
  bool Function(List<({String id, String title, int status, String type, String destination})>)
  until, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  var last = await _serverTasks();
  while (DateTime.now().isBefore(deadline)) {
    if (until(last)) return last;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    last = await _serverTasks();
  }
  return last;
}

/// 本机下载任务列表的**状态快照**（诊断用，§2.0.57④）。
///
/// 没有它，"任务行上没出现『存到本机』"这一个现象背后至少有四种根因：
/// 没发请求 / 服务端 408 / 下完了但 `localPath` 为空 / 界面没画入口 ——
/// 上一轮为这一句话白跑了一次 1 小时 25 分钟的集成。
String _downloadTaskDump(ProviderContainer container) {
  try {
    final list = container.read(fileDownloadTaskListProvider);
    if (list.tasks.isEmpty) return '（空：请求根本没进列表）';
    return list.tasks
        .map(
          (t) => '${t.name}#${t.status.name}'
              '${t.localPath == null ? '' : ' → ${t.localPath}'}'
              '${t.error == null ? '' : ' err=${t.error}'}',
        )
        .join(' | ');
  } catch (e) {
    return '（读不到任务列表：$e）';
  }
}

String _dumpServer(
  List<({String id, String title, int status, String type, String destination})> q,
) => q
    .map((t) => '${t.title}#${t.id}=${t.status}/${t.type}/${t.destination}')
    .join(', ');

/// `任务行 ⋮ → 结束任务 → 确认` ⇒ 服务端 `status` 变成 **5** 且**任务还在**
/// （`Task.delete v2` 的 `force_complete=true` 语义：文件归档、任务保留、不可续传）。
///
/// ★ 这是 r321 修掉 Mock 缺陷 **D21** 之后才有的判据：修之前 `force_complete`
///   被实现成"删除"，于是"结束任务"会**悄悄删掉**用户的任务（比不实现更坏）。
Future<({bool ok, String why})> _forceCompleteDownloadTask(
  WidgetTester tester,
  String title,
) async {
  final t = await _serverTask(title);
  if (t == null) return (ok: false, why: '服务端队列里没有 $title');
  final more = find.byKey(Key('ds-more-${t.id}'));
  if (more.evaluate().isEmpty) {
    return (ok: false, why: '行上没有 ds-more-${t.id}；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, more);
  await _wait(tester, 900);
  final item = find.byKey(Key('ds-force-complete-${t.id}'));
  if (item.evaluate().isEmpty) {
    return (ok: false, why: '行菜单里没有 ds-force-complete-${t.id}；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, item);
  await _wait(tester, 900);
  final dlg = find.byKey(const Key('ds-force-complete-dialog'));
  if (dlg.evaluate().isEmpty) {
    return (ok: false, why: '结束任务确认框没出现；屏上文字：${_texts(tester)}');
  }
  // ★ 按**对话框子树**定位确认键（locale 会给中文按钮文案，别按文案找）
  final confirm = find.descendant(
    of: dlg,
    matching: find.byType(FilledButton),
  );
  if (confirm.evaluate().isEmpty) {
    return (ok: false, why: '确认框里没有 FilledButton；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, confirm.first);
  final q = await _waitServer(
    (list) => list.any((x) => x.title == title && x.status == 5),
  );
  final hit = q.where((x) => x.title == title).toList();
  if (hit.isEmpty) {
    return (ok: false, why: '★ 任务被删掉了 —— force_complete 必须是"结束"不是"删除"；队列：${_dumpServer(q)}');
  }
  if (hit.first.status == 5) {
    return (ok: true, why: 'status=5 且任务保留（结束任务，不是删除）');
  }
  return (ok: false, why: '期望 status=5，实际 ${hit.first.status}；队列：${_dumpServer(q)}');
}

/// 进笔记模块。
///
/// ★ 与下载页同一条教训（§2.0.49 ①）：笔记也是"**顶替主槽的模块**"，
///   `select(AppTab.note)` 会被 shell 静默忽略 ⇒ 正确入口是**工作台磁贴**
///   `ws-tile-notes`；拿不到就退回"根导航直接推 `NotesPage`"（与 r131 走查同路），
///   并且**日志如实写**走的是哪条路。
Future<bool> _openNotesModule(WidgetTester tester) async {
  _dismissSnackBars();
  await _wait(tester, 500);
  await _tapKey(tester, 'dock-workspace', settle: 1800);
  final opened = await _tapKey(tester, 'ws-tile-notes', settle: 2800);
  if (!opened) {
    rootNavigatorKey.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => const NotesPage()),
    );
    await _wait(tester, 2500);
    _note('（工作台里没有 ws-tile-notes，改用根导航直接推 NotesPage）');
  } else {
    _note('（入口：工作台磁贴 ws-tile-notes）');
  }
  return opened;
}

/// 进相册模块（时间轴）。
///
/// 相册是**主槽模块**（不像下载/笔记那样顶替主槽）⇒ 外壳底栏的 `dock-photos`
/// 就是正门；点完必须看到 `photo-upload-timeline`（上传入口）才算"进去了"，
/// 否则把屏上文字写进 reason（r320 的纪律：入口找不到要能说清看到什么）。
Future<({bool ok, String why})> _openPhotosModule(WidgetTester tester) async {
  _dismissSnackBars();
  // ★ 第 325 轮踩到（第一次跑就判红在这里）：上一段走查（㉗–㉝ 笔记）是在
  //   **根导航上 push** 的模块页（macOS 没有 `ws-tile-notes` ⇒ 走兜底分支），
  //   不先退回外壳就**看不到底栏** ⇒ `dock-photos` 一定找不到，
  //   而失败信息里"屏上文字"全是笔记页的（与"入口不存在"完全不同的原因）。
  //   通式：**用底栏入口之前，先确认自己在不在外壳上**。
  final nav = rootNavigatorKey.currentState;
  if (nav != null && nav.canPop()) {
    nav.popUntil((r) => r.isFirst);
    await _wait(tester, 2000);
    _note('（相册入口前先把根导航退到外壳：popUntil isFirst）');
  }
  if (!await _tapKey(tester, 'dock-photos', settle: 2500)) {
    return (ok: false, why: '外壳里没有 dock-photos 入口；屏上文字：${_texts(tester)}');
  }
  final up = find.byKey(const Key('photo-upload-timeline'));
  if (up.evaluate().isEmpty) {
    return (
      ok: false,
      why: '进相册后没有 photo-upload-timeline；屏上文字：${_texts(tester)}',
    );
  }
  return (ok: true, why: '入口：dock-photos');
}

/// 点时间轴上的「上传」按钮（`photo-upload-timeline`）。
Future<({bool ok, String why})> _uploadPhotoFromTimeline(
  WidgetTester tester,
) async {
  final f = find.byKey(const Key('photo-upload-timeline'));
  if (f.evaluate().isEmpty) {
    return (ok: false, why: '相册页没有 photo-upload-timeline；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, f.first);
  // 上传是"选中 → 逐个 POST → 提示条" —— 给 Mock 落盘 + invalidate 留时间
  await _wait(tester, 4000);
  return (ok: true, why: '已点上传');
}

/// 进聊天模块并打开 `SYNO.Chat.Channel.list.json` 里的 `general` 频道。
///
/// ★ 与相册同一个前置条件：**先退回外壳**（上一步可能是在根导航上 push 的模块页）。
Future<({bool ok, String why})> _openChatChannel(WidgetTester tester) async {
  _dismissSnackBars();
  final nav = rootNavigatorKey.currentState;
  if (nav != null && nav.canPop()) {
    nav.popUntil((r) => r.isFirst);
    await _wait(tester, 2000);
  }
  if (!await _tapKey(tester, 'dock-chat', settle: 2500)) {
    return (ok: false, why: '外壳里没有 dock-chat 入口；屏上文字：${_texts(tester)}');
  }
  // 频道列表要等 Mock 回 `Chat.Channel/list` + 用户表
  await _wait(tester, 4000);
  // 点频道行：文案就是夹具里的 `general`（找不到就报屏上文字，别静默）
  final row = find.text('general');
  if (row.evaluate().isEmpty) {
    return (
      ok: false,
      why: '频道列表里没有 general；屏上文字：${_texts(tester)}',
    );
  }
  await _tapFinder(tester, row.first);
  // 进频道要跑 `Channel/view` + `Post/list`（+ socket 握手），给足时间
  await _wait(tester, 5000);
  return (ok: true, why: '入口：dock-chat → general');
}

/// 聊天页的输入框是否**可用**。
///
/// ★ 这条是**机制量**：`chat_page.dart:1676` 把 `enabled` 绑在
/// `connId != null && connId.isNotEmpty` 上；而 `connId` 只可能来自 socket 的
/// `client.init` 事件 ⇒ "输入框可用" ⟺ "实时通道握手成功"。
/// Mock 以前从不下发 `client.init` ⇒ 这里必然不可用（那是 **Mock 缺口**）。
Future<({bool ok, String why})> _chatComposerReady(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    final fields = find.byType(TextField).evaluate().toList();
    final enabled = [
      for (final e in fields)
        if ((e.widget as TextField).enabled ?? false) e.widget as TextField,
    ];
    if (enabled.isNotEmpty) return (ok: true, why: '输入框可用');
    await _wait(tester, 1000);
  }
  final hints = [
    for (final e in find.byType(TextField).evaluate())
      '${(e.widget as TextField).decoration?.hintText}'
          '（enabled=${(e.widget as TextField).enabled}）',
  ];
  return (
    ok: false,
    why: '聊天页没有**可用**的输入框（= `connId` 为空 = socket 没握手）；'
        '现有输入框：${hints.join(' / ')}；屏上文字：${_texts(tester)}',
  );
}

/// 往输入框打字并点发送球（`Icons.send` 只在输入框有文字时出现）。
Future<({bool ok, String why})> _sendChatMessage(
  WidgetTester tester,
  String text,
) async {
  final fields = find.byType(TextField).evaluate().toList();
  final targets = [
    for (final e in fields)
      if ((e.widget as TextField).enabled ?? false) (e.widget as TextField),
  ];
  if (targets.isEmpty) {
    return (ok: false, why: '没有可用输入框；屏上文字：${_texts(tester)}');
  }
  final field = find.byWidget(targets.first);
  await tester.enterText(field, text);
  await _wait(tester, 1200);
  final sendIcon = find.byIcon(Icons.send);
  if (sendIcon.evaluate().isEmpty) {
    return (
      ok: false,
      why: '打字后没出现发送球（`Icons.send`）；屏上文字：${_texts(tester)}',
    );
  }
  await _tapFinder(tester, sendIcon.first);
  // 发送 = `Post/create`（要能被 Mock 认下 conn_id）+ 本地乐观插入
  await _wait(tester, 4000);
  return (ok: true, why: '已点发送');
}

/// 点编辑器右上角的「保存」。
///
/// 这个按钮**没有 key**、文案随语言变（`actionSave` = Save / 保存）
/// ⇒ 两种文案都试，都找不到就报错（不许静默当"已经保存了"）。
Future<bool> _tapEditorSave(WidgetTester tester) async {
  for (final label in const ['Save', '保存']) {
    final f = find.widgetWithText(TextButton, label);
    if (f.evaluate().isNotEmpty) {
      await _tapFinder(tester, f.first);
      await _wait(tester, 2000);
      return true;
    }
  }
  return false;
}

/// 打开笔记列表里**第一条**行（`note-row-<id>`）。
Future<({bool ok, String why})> _openNoteRow(
  WidgetTester tester,
  String noteId,
) async {
  final row = find.byKey(Key('note-row-$noteId'));
  if (row.evaluate().isEmpty) {
    return (ok: false, why: '列表里没有 note-row-$noteId；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, row.first);
  await _wait(tester, 2000);
  return (ok: true, why: '已点开 $noteId');
}

/// 点「编辑」图标（`Icons.edit_outlined` 的 `IconButton`；**没有 key**）。
///
/// ★ 为什么不用 `Icons.edit`：同一个 `IconData` 在整屏里唯一才行 ——
///   这里用 `widgetWithIcon` 会在"编辑器里也有一个编辑图标"时歧义，
///   所以显式按 `IconButton + IconData` 精确定位，并要求**恰好一个**。
Future<bool> _tapEditIcon(WidgetTester tester) async {
  final f = find.byWidgetPredicate(
    (w) => w is IconButton && w.icon is Icon && (w.icon as Icon).icon == Icons.edit_outlined,
  );
  if (f.evaluate().isNotEmpty) {
    await _tapFinder(tester, f.first);
    await _wait(tester, 2200);
    return true;
  }
  // ★★ 第 330 轮（iOS 模拟器上实测到的仪器缺陷 I8）：笔记正文页的顶部动作用的是
  //   `adaptiveActions([...])`（§2.0.10）—— iPhone 16 只有 **393pt** 宽
  //   ⇒ 9 个 48dp 点击区排不下 ⇒ ✏️ **被折进 `⋮` 菜单**（折叠项在菜单项里，
  //   **不进部件树**）。macOS 的 1600dp 宽窗里它永远是行内的，
  //   所以这条路径**在 macOS 上永远走不到**（AGENTS §2.0.21 第 3 条：
  //   "iOS 是假绿温床"）。
  //   ⇒ 判据要按"可达"写：行内没有就打开 `⋮` 再点标题为「编辑/Edit」的那一项。
  final overflow = find.byKey(const Key('bar-overflow'));
  if (overflow.evaluate().isEmpty) return false;
  await _tapFinder(tester, overflow.first);
  await _wait(tester, 700);
  final item = find.text('编辑').evaluate().isNotEmpty
      ? find.text('编辑').last
      : find.text('Edit').last;
  if (item.evaluate().isEmpty) return false;
  await _tapFinder(tester, item);
  await _wait(tester, 2200);
  return true;
}

/// 从笔记列表一路点到**编辑器**（宽屏是"主从布局"：点行 ⇒ 右栏预览 ⇒
/// 「在新窗口打开」⇒ 正文页 ⇒ ✏️ 编辑）。
///
/// ★ 第 324 轮踩到：**800×600 的 macOS 用例走的是 expanded（≥700dp）主从布局**
///   （§2.0.36 的门槛），`_onNoteTap` 在宽屏**不 push 路由**、只填右栏
///   ⇒ 直接在列表上找 `TextField` 永远找不到（屏上确实有 `Nothing here`/预览）。
///   窄屏（<700dp）才会 push。用例必须**两条分支都能走**，不许只认一条。
Future<({bool ok, String why})> _openNoteEditor(
  WidgetTester tester,
  String noteId,
) async {
  final tapped = await _openNoteRow(tester, noteId);
  if (!tapped.ok) return tapped;
  // 宽屏：右栏出现（`note-wide-detail`）⇒ 用「在新窗口打开」进正文页
  final wideOpen = find.byKey(const Key('note-wide-open'));
  if (wideOpen.evaluate().isNotEmpty) {
    await _tapFinder(tester, wideOpen.first);
    await _wait(tester, 2200);
  }
  if (!await _tapEditIcon(tester)) {
    return (
      ok: false,
      why: '找不到编辑图标（Icons.edit_outlined 的 IconButton）；屏上文字：${_texts(tester)}',
    );
  }
  if (find.byType(TextField).evaluate().isEmpty) {
    return (ok: false, why: '编辑器没出来（没有 TextField）；屏上文字：${_texts(tester)}');
  }
  return (ok: true, why: '编辑器已打开（$noteId）');
}

/// 改**第一条笔记的标题**并保存（`Note/set`）。
///
/// ★ 只改标题：正文是 Quill 富文本编辑器，`tester.enterText` 进不去它的文档模型
///   （Quill 自己管输入）；标题是普通 `TextField`，可以逐字 `enterText`。
///   判据不在界面上，而是**另一个 HTTP 客户端**回读 `Note/list` 的 title/ver。
Future<({bool ok, String why})> _editNoteTitle(
  WidgetTester tester,
  String newTitle,
) async {
  final fields = find.byType(TextField);
  if (fields.evaluate().isEmpty) {
    return (ok: false, why: '编辑器里没有 TextField；屏上文字：${_texts(tester)}');
  }
  // 编辑器里**第一个** TextField 是标题（正文走 Quill / Markdown 字段）
  await tester.enterText(fields.first, newTitle);
  await _wait(tester, 600);
  if (!await _tapEditorSave(tester)) {
    return (ok: false, why: '找不到保存键（Save/保存）；屏上文字：${_texts(tester)}');
  }
  return (ok: true, why: '已提交标题「$newTitle」');
}

/// 新建一条笔记（列表页 FAB「新建笔记」→ 填标题 → 保存 ⇒ `Note/create`）。
Future<({bool ok, String why})> _createNote(
  WidgetTester tester,
  String title,
) async {
  final fab = find.byType(FloatingActionButton);
  if (fab.evaluate().isEmpty) {
    return (ok: false, why: '笔记列表页没有 FAB；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, fab.first);
  await _wait(tester, 2200);
  final fields = find.byType(TextField);
  if (fields.evaluate().isEmpty) {
    return (ok: false, why: '新建编辑器没出来；屏上文字：${_texts(tester)}');
  }
  await tester.enterText(fields.first, title);
  await _wait(tester, 600);
  if (!await _tapEditorSave(tester)) {
    return (ok: false, why: '找不到保存键（Save/保存）；屏上文字：${_texts(tester)}');
  }
  return (ok: true, why: '已提交新建「$title」');
}

/// `任务行 ⋮ → 改目的地 → 填路径 → 保存` ⇒ 服务端 `additional.detail.destination` 变了。
Future<({bool ok, String why})> _editDownloadDestination(
  WidgetTester tester,
  String title,
  String destination,
) async {
  final t = await _serverTask(title);
  if (t == null) return (ok: false, why: '服务端队列里没有 $title');
  final more = find.byKey(Key('ds-more-${t.id}'));
  if (more.evaluate().isEmpty) {
    return (ok: false, why: '行上没有 ds-more-${t.id}（可编辑状态才有）');
  }
  await _tapFinder(tester, more);
  await _wait(tester, 900);
  final item = find.byKey(Key('ds-edit-dest-${t.id}'));
  if (item.evaluate().isEmpty) {
    return (ok: false, why: '行菜单里没有 ds-edit-dest-${t.id}；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, item);
  await _wait(tester, 900);
  final dlg = find.byKey(const Key('ds-edit-dest-dialog'));
  if (dlg.evaluate().isEmpty) {
    return (ok: false, why: '改目的地对话框没出现；屏上文字：${_texts(tester)}');
  }
  await tester.enterText(find.byKey(const Key('ds-edit-dest-field')), destination);
  await _wait(tester, 500);
  // 像素要落在"**输入框里已经填好、还没提交**"这一刻 ——
  // 只拍提交后的列表是**证明不了**对话框长什么样的（§2.0.36"布局断言证明不了渲染"）。
  await _shot(tester, '13_edit_dest_dialog');
  final submit = find.byKey(const Key('ds-edit-dest-submit'));
  if (submit.evaluate().isEmpty) {
    return (ok: false, why: '对话框里没有 ds-edit-dest-submit');
  }
  await _tapFinder(tester, submit);
  return (ok: true, why: '已提交 $destination');
}

/// 点 `批量操作` 菜单里的某一项；破坏性两项会弹 `ds-batch-dialog` 二次确认。
Future<({bool ok, String why})> _batchDownloadAction(
  WidgetTester tester,
  String itemKey,
) async {
  final menu = find.byKey(const Key('ds-batch-menu'));
  if (menu.evaluate().isEmpty) {
    return (ok: false, why: '工具条上没有 ds-batch-menu；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, menu);
  await _wait(tester, 700);
  final item = find.byKey(Key(itemKey));
  if (item.evaluate().isEmpty) {
    return (ok: false, why: '批量菜单里没有 $itemKey；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, item);
  await _wait(tester, 800);
  final dlg = find.byKey(const Key('ds-batch-dialog'));
  if (dlg.evaluate().isNotEmpty) {
    final confirm = find.descendant(
      of: dlg,
      matching: find.byType(FilledButton),
    );
    if (confirm.evaluate().isEmpty) {
      return (ok: false, why: '二次确认框里没有 FilledButton；屏上文字：${_texts(tester)}');
    }
    await _tapFinder(tester, confirm.first);
  }
  return (ok: true, why: '已点 $itemKey');
}

/// `下载页 FAB(New task) → 填链接 → Create → 服务端队列里出现这条任务`。
Future<({bool ok, String why})> _createDownloadTask(
  WidgetTester tester,
  ProviderContainer container,
  String url,
  String expectedTitle,
) async {
  // ★ r320 踩到：`select(AppTab.download)` **切不过去** —— 下载是"顶替主槽的
  //   模块"（`kReplacementOrder`），不在主槽/侧边栏里，选择它会被 shell 忽略，
  //   屏幕仍停在聊天页（屏上文字是 CHANNELS/0 channels）。
  //   正确入口 = **工作台磁贴**（与 r131/r132 走查同一条路）。
  // ★ 判据是"**入口在不在**"（key 或文案），不是"FAB 在不在" ——
  //   r320 上一版把 `ds-add-task` 写进了兜底条件，于是**空队列下永远走兜底**，
  //   日志还谎称"工作台磁贴没打开"（其实磁贴是好的）。判据写错会把
  //   "真实入口可用"这条证据一起弄没。
  bool addKey() => find.byKey(const Key('ds-add-task')).evaluate().isNotEmpty;
  bool addText() => _hasText('New task') || _hasText('新建任务');
  _dismissSnackBars();
  await _wait(tester, 500);
  await _tapKey(tester, 'dock-workspace', settle: 1800);
  final opened = await _tapKey(tester, 'ws-tile-downloads', settle: 2800);
  if (!opened) {
    // 兜底：工作台里没有磁贴就直接推真实页面（走查里也是这么兜的）
    rootNavigatorKey.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => const DownloadPage()),
    );
    await _wait(tester, 2500);
    _note('（工作台里没有 ws-tile-downloads，改用根导航直接推 DownloadPage）');
  } else {
    _note('（入口：工作台磁贴 ws-tile-downloads）');
  }
  // ★ 「新建」入口有**两个形态，二选一**（D9：`_emptyStateHasNewTask()` 一个判据
  //   同时决定"空态里的按钮"与"FAB"）：队列为空 ⇒ 空态里的按钮；
  //   队列非空 ⇒ FAB（带 key `ds-add-task`）。**别只等 key** ——
  //   r320 第一次就死等 `ds-add-task`，而空队列下它按设计**不存在**，
  //   表现是"下载页没出来"（其实页面早就出来了，屏上文字已经能看到分类条）。
  // ★ `_waitFor` 超时是**抛异常**、返回 void（别写成 `if (!await …)`）
  try {
    await _waitFor(
      tester,
      '下载页出现「新建任务」入口（FAB 或空态按钮）',
      () => addKey() || addText(),
      timeout: const Duration(seconds: 30),
    );
  } on StateError {
    return (ok: false, why: '下载页没出来；屏上文字：${_texts(tester)}');
  }
  await _waitNoSnackBar(tester);
  // 创建前的像素（**空队列** → 空态按钮形态），与创建后成对
  await _shot(tester, '06_download_before');
  final usedKey = addKey();
  if (!usedKey && !await _tapTextAny(tester, const ['New task', '新建任务'])) {
    return (ok: false, why: '点不到空态里的「新建任务」；屏上文字：${_texts(tester)}');
  }
  _note('（下载入口形态：${usedKey ? 'FAB（队列非空）' : '空态按钮（队列为空）'}）');
  // ★★ r348 仪器修正（§2.0.50「先修仪器，再报结论」）：`_tapFinder` 用的是
  //   `warnIfMissed: false` —— **点空了不报错**。本轮 macOS 重验时它就这么静默点空，
  //   表现成"create 页没有输入框"，而同一台机、同一个 Mock 上独立仪器
  //   `AUDIT_MODE=mock tool/r131_macos_audit.sh download` 的 `d11_download_create`
  //   是 **OK** 的（创建页渲染正常）⇒ 判"产品缺陷"之前必须先把这条仪器修成**可证伪**的。
  //   修法：点完**必须看见 create 页**（按类型找，不靠文案），最多 3 次；
  //   入口形态（FAB / 空态按钮）每次重新判，别把第一次的结论用到底。
  bool createOpen() => find.byType(DownloadCreatePage).evaluate().isNotEmpty;
  for (var attempt = 0; attempt < 3 && !createOpen(); attempt++) {
    if (addKey()) {
      await _tapFinder(tester, find.byKey(const Key('ds-add-task')).first);
    } else {
      await _tapTextAny(tester, const ['New task', '新建任务']);
    }
    try {
      await _waitFor(
        tester,
        '「新建任务」后 create 页出现（第 ${attempt + 1} 次）',
        createOpen,
        timeout: const Duration(seconds: 12),
      );
    } on StateError {
      // 没出现 ⇒ 下一轮重试（这里**不**吞掉最终判据）
    }
  }
  if (!createOpen()) {
    return (
      ok: false,
      why: '点了「新建任务」但 create 页没出现（已重试 3 次）；屏上文字：${_texts(tester)}',
    );
  }
  await _wait(tester, 400);
  // 「链接」输入框（create 页的 URL 字段）
  Finder? field;
  for (final label in const ['Link', '链接']) {
    final f = find.widgetWithText(TextField, label);
    if (f.evaluate().isNotEmpty) {
      field = f.first;
      break;
    }
  }
  field ??= find.byType(TextField).evaluate().isNotEmpty
      ? find.byType(TextField).first
      : null;
  if (field == null) {
    return (ok: false, why: 'create 页没有输入框；屏上文字：${_texts(tester)}');
  }
  await tester.enterText(field, url);
  await _wait(tester, 400);
  // ★ r320 第二个坑：create 页是 **`ListView`** ⇒ 屏外的 `ds-create-submit`
  //   **根本没被 build**（`find.byKey` 空）—— 这类"屏外"不是"被裁掉"而是
  //   "不在树里"，`ensureVisible` 也救不了，必须**滚过去**（§2.0.48 ④ 的同族）。
  final submit = find.byKey(const Key('ds-create-submit'));
  if (submit.evaluate().isEmpty) {
    try {
      await tester.scrollUntilVisible(
        submit,
        300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 30,
      );
      await _wait(tester, 400);
    } catch (e) {
      return (ok: false, why: '滚不到 ds-create-submit（$e）；屏上文字：${_texts(tester)}');
    }
  }
  if (submit.evaluate().isEmpty) {
    return (ok: false, why: '找不到 ds-create-submit；屏上文字：${_texts(tester)}');
  }
  await _tapFinder(tester, submit);
  // 判据一：服务端（另一个客户端）队列里出现它
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  var serverSeen = false;
  while (DateTime.now().isBefore(deadline)) {
    await _wait(tester, 800);
    final titles = await _serverTaskTitles();
    if (titles.contains(expectedTitle)) {
      serverSeen = true;
      break;
    }
  }
  if (!serverSeen) {
    return (ok: false, why: '服务端队列里没有 $expectedTitle（界面：${_texts(tester)}）');
  }
  // 判据二：界面回到列表并且能看见这条（判据一已经是服务端状态）
  final uiDeadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(uiDeadline)) {
    if (_hasText(expectedTitle)) return (ok: true, why: '服务端 + 界面都有');
    await _wait(tester, 500);
  }
  return (ok: false, why: '服务端有了，但界面列表里没显示 $expectedTitle');
}

/// 等底部提示条消失。
///
/// ★ r319 第七个坑（**像素判决**）：`AppSnack` 用的是真 `SnackBar`，它**整条压在 FAB 上**
/// ——`04_deleted.png` 里删完的那条 "Deleted" 正好盖住右下角的「New / Upload」，
/// `tester.tap` 打到了提示条，于是 `_tapTextAny('Upload file')` 永远找不到
/// （表现是"FAB 面板没开"，而不是任何错误）。所以**开 FAB 之前先等它退场**。
Future<void> _waitNoSnackBar(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 14));
  while (DateTime.now().isBefore(deadline)) {
    if (find.byType(SnackBar).evaluate().isEmpty) return;
    await _wait(tester, 400);
  }
}

Future<({bool ok, String why})> _uploadViaUi(
  WidgetTester tester,
  String localPath,
  String name,
) async {
  await _waitNoSnackBar(tester);
  if (!await _tapTooltipAny(tester, const ['New / Upload', '新建 / 上传'])) {
    return (ok: false, why: '找不到 FAB');
  }
  await _wait(tester, 1600);
  if (!await _tapTextAny(tester, const ['Upload file', '上传文件'])) {
    return (ok: false, why: 'FAB 面板里没有 Upload file；屏上文字：${_texts(tester)}');
  }
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    await _wait(tester, 500);
    if (_hasRow(name)) return (ok: true, why: '列表已出现');
  }
  return (ok: false, why: '上传后列表里没有 $name');
}

Future<bool> _tapText(WidgetTester tester, String text) async {
  final f = find.byWidgetPredicate(
    (w) => w is Text && (w.data ?? '') == text,
  );
  if (f.evaluate().isEmpty) return false;
  return _tapFinder(tester, f.first);
}

/// 点一个 finder —— **先滚进视口**再点。
///
/// ★ r319 踩到：800x600 的 macOS 窗口里，行菜单底部 sheet 的靠后几项
/// （`Delete`）会被裁到屏外；`warnIfMissed:false` 会把这种"点了但没点到"
/// 静默吃掉 ⇒ 表现为"点了删除，服务端一条请求都没收到"。
Future<bool> _tapFinder(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) return false;
  try {
    await tester.ensureVisible(f);
    await tester.pump(const Duration(milliseconds: 120));
  } catch (_) {
    // 不在可滚动容器里就会抛，忽略：直接点
  }
  await tester.tap(f, warnIfMissed: false);
  return true;
}

/// 优先点**按钮**里的文案（`FilledButton` / `TextButton` / `ElevatedButton`）。
///
/// ★ r319 踩到：改名对话框的标题与确认键**都是 `photoRename`**（"Rename"），
/// 于是 `find.text('Rename').first` 点到的是**标题**（不可点）⇒ 对话框不关、
/// 请求不发，而用例只在最后一步报"列表没变"（看着像服务端不认）。
/// 判据：确认动作一律按"按钮子树里的文案"定位。
Future<bool> _tapButtonAny(WidgetTester tester, List<String> labels) async {
  for (final l in labels) {
    for (final finder in <Finder>[
      find.widgetWithText(FilledButton, l),
      find.widgetWithText(TextButton, l),
      find.widgetWithText(ElevatedButton, l),
    ]) {
      if (finder.evaluate().isNotEmpty) {
        return _tapFinder(tester, finder.first);
      }
    }
  }
  // 兜底：老式 `TextButton` 之外的自绘按钮（`AppSheetAction` 等）
  return _tapTextAny(tester, labels);
}

Future<bool> _tapTextAny(WidgetTester tester, List<String> texts) async {
  for (final t in texts) {
    if (await _tapText(tester, t)) return true;
  }
  return false;
}

Future<bool> _tapTooltipAny(WidgetTester tester, List<String> tooltips) async {
  for (final t in tooltips) {
    final f = find.byTooltip(t);
    if (f.evaluate().isNotEmpty) {
      await tester.tap(f.first, warnIfMissed: false);
      return true;
    }
  }
  return false;
}
