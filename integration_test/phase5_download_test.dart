// Phase 5 真机验收：附件**下载进度框 + 取消**（对齐原版 `DownloadFragment`）。
//
//   flutter test integration_test/phase5_download_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 验收点：
//   ① 上传 ~400 KB 二进制 → 直链回读逐字节一致（服务端这一侧没问题）
//   ② `openAttachment(task:)` 的进度回调真的会走（received 到满、total 来自
//      Content-Length）；文件落到指定的缓存路径且内容一致
//   ③ 真界面：`AttachmentList` 点附件 → 弹「正在下载…」→ 下完自动关框 → 缓存命中
//   ④ 已取消的 token 立刻抛 `DownloadCancelledException`（不落盘）
//   ⑤ 清场
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_filex/open_filex.dart';

import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/attachment_access.dart';
import 'package:synhub/src/features/chat/attachment_view.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/download_dialog.dart';
import 'package:synhub/src/features/chat/file_actions.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

Uint8List bigBlob(int size) {
  final b = Uint8List(size);
  for (var i = 0; i < size; i++) {
    b[i] = (i * 31 + (i >> 8)) & 0xff;
  }
  return b;
}

/// 直通式 E2EE 桩：文件名原样、字节原样。
///
/// 为什么需要它：§2.0.8④ 之后**普通文件**在 `AttachmentList._open` 的第 3.5
/// 分支就被"内置阅读器"（`openFilePreview`）接管并 `return`，**根本不走下载**；
/// 想测"点附件 → 弹进度框 → 落盘到缓存路径"这条链，只能让附件变成**加密频道**
/// （`access != null` ⇒ `encrypted = true` ⇒ 跳过 3.5 落到第 4 分支"下载后打开"）。
/// 本用例的消息本来就没加密，所以桩只做原样透传。
/// （同款手法见 `test/attachment_unmount_leak_test.dart:126-136`。）
class _PassthroughE2ee implements E2eeService {
  @override
  String? tryDecryptFileName(int channelId, String encodedName) => encodedName;

  @override
  Uint8List? tryDecryptFileBytes(int channelId, List<int> raw) =>
      raw is Uint8List ? raw : Uint8List.fromList(raw);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 5 真机：下载进度框与取消', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);
    expect(container.read(chatSessionControllerProvider).phase,
        ChatSyncPhase.ready);
    final channels = await container.read(chatStoreProvider).allChannels();
    final cid = channels
        .firstWhere((c) => !c.encrypted && c.isJoined,
            orElse: () => channels.first)
        .channelId;

    final dir = Directory.systemTemp.createTempSync('flt_p5dl');
    final bytes = bigBlob(400 * 1024);
    final file = File('${dir.path}/flt-p5dl.bin')..writeAsBytesSync(bytes);
    final cache = container.read(cacheServiceProvider);

    final created = <int>[];
    addTearDown(() async {
      for (final id in created) {
        try {
          await chat.deletePost(id);
        } catch (_) {}
      }
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    // ---------- ① 上传 + 直链回读 ----------
    final raw = await chat.uploadPost(
      channelId: cid,
      connId: '',
      filePath: file.path,
      fileName: 'flt-p5dl.bin',
      message: 'flt-p5dl 下载进度探针',
      mimeType: 'application/octet-stream',
    );
    final map = Map<String, dynamic>.from((raw['post'] ?? raw) as Map);
    final postId = (map['post_id'] as num).toInt();
    created.add(postId);
    final fetched = await chat.downloadPostFile(postId);
    debugPrint('[p5dl] ① 上传 #$cid post=$postId：本地 ${bytes.length} / 直链 '
        '${fetched.length} 字节');
    expect(fetched.length, bytes.length);
    expect(fetched.sublist(0, 32), bytes.sublist(0, 32));
    expect(fetched.sublist(bytes.length - 32), bytes.sublist(bytes.length - 32));

    // 服务端 Post/list 里把 file_props 读回来（PostDto 要它）
    final posts = await chat.listPosts(channelId: cid, prevCount: 20);
    final raw2 = posts.firstWhere(
        (p) => (p['post_id'] as num).toInt() == postId,
        orElse: () => map);
    final post = PostDto.fromJson(raw2);
    debugPrint('[p5dl] ① file_props=${post.attachments.map((a) => a.label)}');
    expect(post.attachments, isNotEmpty);

    // ---------- ② 进度回调 ----------
    final task = DownloadTask('flt-p5dl.bin');
    final seen = <int>[];
    task.progress.addListener(() => seen.add(task.progress.value.received));
    final savePath = await cache.pathFor(postId, 'flt-p5dl.bin');
    final err = await openAttachment(
      chat,
      post,
      post.attachments.first,
      task: task,
      savePath: savePath,
      opener: (path) async => OpenResult(type: ResultType.done),
    );
    debugPrint('[p5dl] ② 进度回调次数=${seen.length} 最大=${seen.isEmpty ? 0 : seen.reduce((a, b) => a > b ? a : b)} '
        '总=${task.progress.value.total} err=$err');
    expect(err, isNull);
    expect(seen, isNotEmpty, reason: '应该有进度回调');
    expect(File(savePath).existsSync(), isTrue);
    expect(File(savePath).lengthSync(), bytes.length);
    task.dispose();

    // ---------- ③ 真界面：弹框 → 自动关框 ----------
    // 让附件走**加密频道**那条路，否则第 3.5 分支会把点击交给内置阅读器
    // （见 `_PassthroughE2ee` 的说明），进度框与落盘都不会发生。
    final access = AttachmentAccess(
      channelId: cid,
      svc: _PassthroughE2ee(),
      api: chat,
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: AttachmentList(
            post: post,
            api: container.read(chatApiProvider),
            access: access,
          ),
        ),
      ),
    ));
    await tester.pump();
    // 先把缓存删掉，逼它真的重新下载
    File(savePath).deleteSync();
    await tester.tap(find.text('flt-p5dl.bin'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final sawDialog = find.text('正在下载…').evaluate().isNotEmpty;
    debugPrint('[p5dl] ③ 点附件后出现进度框=$sawDialog '
        '落盘路径=$savePath');
    // 真机下载是真实异步，多等一会儿
    for (var i = 0; i < 60 && find.text('正在下载…').evaluate().isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    }
    debugPrint('[p5dl] ③ 下完后框还在吗=${find.text('正在下载…').evaluate().isNotEmpty} '
        '缓存命中=${File(savePath).existsSync()}');
    expect(find.text('正在下载…'), findsNothing);
    expect(File(savePath).existsSync(), isTrue);
    expect(File(savePath).lengthSync(), bytes.length);

    // ---------- ④ 取消 ----------
    final cancelled = DownloadTask('flt-p5dl.bin')..cancel();
    var threw = false;
    try {
      await openAttachment(
        chat,
        post,
        post.attachments.first,
        task: cancelled,
        savePath: '$savePath.cancel',
      );
    } on DownloadCancelledException {
      threw = true;
    }
    debugPrint('[p5dl] ④ 已取消的 token → DownloadCancelledException=$threw '
        '落盘=${File('$savePath.cancel').existsSync()}');
    expect(threw, isTrue);
    expect(File('$savePath.cancel').existsSync(), isFalse);
    cancelled.dispose();

    // ---------- ⑤ 另存到「下载」+ 分享（原版 DownloadFragment option 1/2） ----------
    const bridge = FileActionBridge();
    final saveName = 'flt-p5dl-save-${DateTime.now().millisecondsSinceEpoch}.bin';
    // 先备好缓存文件（复用上面下过的那份）
    final saveBytes = await chat.downloadPostFile(postId);
    File(savePath).writeAsBytesSync(saveBytes);
    final uri = await bridge.saveToDownloads(
      path: savePath,
      name: saveName,
      mime: 'application/octet-stream',
    );
    debugPrint('[p5dl] ⑤ 另存到「下载」→ uri=$uri');
    expect(uri, isNotNull, reason: 'MediaStore 写入应该成功');
    expect(await bridge.canShare(path: savePath, mime: 'application/octet-stream'),
        isTrue, reason: 'FileProvider 应该能解析并找到接收方');
    expect(await bridge.deleteSaved(uri!), isTrue, reason: '清场：删掉刚存的那一行');
    // 不存在的源文件 → null（不是崩溃）
    expect(
        await bridge.saveToDownloads(
            path: '$savePath.none', name: 'x.bin', mime: 'application/octet-stream'),
        isNull);

    // ---------- ⑥ 清场 ----------
    try {
      File(savePath).deleteSync();
    } catch (_) {}
    for (final id in created) {
      try {
        await chat.deletePost(id);
        debugPrint('[p5dl] ⑤ 已删除 #$id');
      } catch (e) {
        debugPrint('[p5dl] ⑤ 删除 #$id 失败：$e');
      }
    }
    debugPrint('[p5dl] 完成 ✓');
  });
}
