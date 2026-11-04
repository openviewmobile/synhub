// Phase 5 真机验收：附件上传（multipart）→ 服务端 file_props → 下载/缩略图 → 清理。
//
//   flutter test integration_test/phase5_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_LIVE_POST=true
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/channel_media_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _postRaw = String.fromEnvironment('SYNO_LIVE_POST');
final _doPost = _postRaw == '1' || _postRaw == 'true';

String _marker(String kind) =>
    'flt-p5-$kind-${DateTime.now().millisecondsSinceEpoch}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 5 真机：上传 txt/png、file_props、下载与缩略图', (tester) async {
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
    final sync = container.read(chatSessionControllerProvider);
    expect(sync.phase, ChatSyncPhase.ready);
    final store = container.read(chatStoreProvider);

    final channels = await store.allChannels();
    final target = channels.firstWhere((c) => !c.encrypted && c.isJoined,
        orElse: () => channels.first);
    debugPrint('[p5] 频道=#${target.channelId}');

    // 造测试文件
    final dir = Directory.systemTemp.createTempSync('p5dev');
    final txtBody = '${_marker('body')} 中文内容 line2\nline3';
    final txt = File('${dir.path}/${_marker('note')}.txt')
      ..writeAsStringSync(txtBody);
    // 64x64 的真 PNG：1x1 的空图服务端不会判成图片（`is_image` 仍是 false）
    final png = File('${dir.path}/${_marker('img')}.png')
      ..writeAsBytesSync(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAABH0lEQVR4nO3PkaKDAAAF0GAQBIMgCIJBMAiCQRAMgiAIgsEgCIJBMAgGQTAYBEEQBMEgCILBIAiCIAiCIBgEQRAE7xPeD9zzB4cgCGK325EkSVHUfr+naZphGJZlOY47HA48zx+PR0EQRFE8nU6SJMmyfD6fFUVRVVXTNF3XDcO4XC7X69U0TcuybNu+3W6O49zvd9d1H4+H53m+7z+fz9frFQRBGIZRFMVxnCRJmqbv9zvLsjzPi6L4fD7f77csy6qq6rpumqZt267r+r4fhmEcx9/vN03TPM/Lsqzrum0bgQACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAgj8F/gDmnuhWk7edLMAAAAASUVORK5CYII='));

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

    if (!_doPost) {
      debugPrint('[p5] 未开 SYNO_LIVE_POST，只验证离线部分');
      return;
    }

    // ---------- ① 上传 txt（走控制器，验证"占位 → 确认"整条链） ----------
    var progressSeen = false;
    final caption = _marker('caption');
    final okTxt = await ctrl.sendAttachment(
      channelId: target.channelId,
      filePath: txt.path,
      fileName: txt.uri.pathSegments.last,
      message: caption,
      mimeType: 'text/plain',
      onProgress: (sent, total) {
        if (total > 0) progressSeen = true;
      },
    );
    expect(okTxt, isTrue);
    expect(progressSeen, isTrue);
    final txtPost = (await store.postsForChannel(target.channelId))
        .firstWhere((p) => p.attachments.any((a) => a.name.endsWith('.txt')));
    created.add(txtPost.postId);
    final txtProp = txtPost.attachments.single;
    debugPrint('[p5] txt post=${txtPost.postId} type=${txtPost.type} '
        'name=${txtProp.name} size=${txtProp.size} '
        'snippet=${jsonEncode(txtProp.snippetPreview)} '
        'voice=${txtProp.isVoiceMessage}');
    expect(txtPost.type, 'file');
    expect(txtProp.extension, 'txt');
    expect(txtProp.size, greaterThan(0));
    expect(txtProp.snippetPreview, contains('中文内容'),
        reason: '服务端会截文本预览，界面直接显示它');
    expect(txtPost.message, caption,
        reason: 'multipart 的 message 不能被引号包住（实测坑）');
    expect(sync.pendingFiles, isEmpty, reason: '上传完成后本地预览要清掉');

    // ---------- ② 服务端列表里也带 file_props（重进频道能看到附件） ----------
    final listed = await chat.listPosts(
        channelId: target.channelId, prevCount: 20, nextCount: 0,
        has: const ['thread']);
    final listedPost =
        listed.firstWhere((p) => (p['post_id'] as num).toInt() == txtPost.postId);
    expect(listedPost['file_props'], isNotNull,
        reason: '普通 Post/list 就该带附件（不需要额外开关）');
    debugPrint('[p5] 列表里的 file_props=${jsonEncode(listedPost['file_props'])}');

    // ---------- ③ 下载原文件，比对内容 ----------
    final bytes = await chat.downloadPostFile(txtPost.postId);
    expect(utf8.decode(bytes), txtBody);
    debugPrint('[p5] 下载 txt ${bytes.length} 字节，内容一致 ✓');

    // ---------- ④ 上传 png + 缩略图 ----------
    final okPng = await ctrl.sendAttachment(
      channelId: target.channelId,
      filePath: png.path,
      fileName: png.uri.pathSegments.last,
      mimeType: 'image/png',
    );
    expect(okPng, isTrue);
    // ⚠️ 上传的明明是 png，落库可能是 **jpg**：Phase 9 的"标准质量"会在上传前
    // 重编码（长边 1280 + JPEG90）并把扩展名改成 jpg，与原版 `upload_quality`
    // 行为一致。所以这里两种都收。
    final localPosts = await store.postsForChannel(target.channelId);
    final pngPost = localPosts.firstWhere(
      (p) =>
          p.attachments.any((a) => a.extension == 'png' || a.extension == 'jpg'),
      orElse: () => throw StateError(
          '本地没有刚上传的图片消息（store 里 ${localPosts.length} 条）'),
    );
    created.add(pngPost.postId);
    final pngProp = pngPost.attachments.single;
    debugPrint('[p5] png post=${pngPost.postId} name=${pngProp.name} '
        'size=${pngProp.size} showsThumbnail=${pngProp.showsThumbnail}');
    expect(pngProp.showsThumbnail, isTrue,
        reason: '真机 is_image 是 false，只能靠扩展名判断');

    final thumb = await chat.downloadPostFile(pngPost.postId,
        thumbnail: true, size: ChatApi.thumbLarge);
    expect(thumb.length, greaterThan(0));
    debugPrint('[p5] 缩略图 ${thumb.length} 字节 ✓');

    final url = chat.fileUrl(pngPost.postId, thumbnail: true, size: ChatApi.thumbLarge);
    expect(url, contains('_sid='));
    expect(url, contains('method=thumbnail'));
    debugPrint('[p5] 缩略图 URL ✓ ${url.split('?').first}?…');

    // ---------- ⑤ 让另一个会话也能看到（跨会话/跨设备一致性） ----------
    final posts2 = await chat.listPosts(
        channelId: target.channelId, prevCount: 20, nextCount: 0);
    final seen = posts2
        .where((p) =>
            (p['post_id'] as num).toInt() == txtPost.postId ||
            (p['post_id'] as num).toInt() == pngPost.postId)
        .length;
    expect(seen, 2);
    debugPrint('[p5] 重进频道能看到两条附件消息 ✓');

    // ---------- ⑥ 媒体页（图片墙 / 文件列表） ----------
    final imgCount = await ctrl.loadMedia(
        channelId: target.channelId, fileTypes: const [kMediaImage]);
    debugPrint('[p5] 图片墙 loadMedia(image) → $imgCount 条');
    expect(imgCount, greaterThanOrEqualTo(1));
    final mediaPosts =
        await store.postsForChannel(target.channelId, limit: 500);
    final inImageTab = mediaPosts
        .where((p) => matchesTab(mediaQueryFor(MediaTab.image), p))
        .map((p) => p.postId)
        .toList();
    final inFileTab = mediaPosts
        .where((p) => matchesTab(mediaQueryFor(MediaTab.file), p))
        .map((p) => p.postId)
        .toList();
    debugPrint('[p5] 图片 tab=$inImageTab 文件 tab=$inFileTab');
    expect(inImageTab, contains(pngPost.postId));
    expect(inFileTab, contains(txtPost.postId));
    expect(inFileTab, isNot(contains(pngPost.postId)),
        reason: '图片不该出现在文件 tab');
    expect(inImageTab, isNot(contains(txtPost.postId)));

    // 服务端按分类筛：图片墙里不该混进 txt
    final galleryRaw = await chat.listPostsByType(
        channelId: target.channelId, fileTypes: const [kMediaImage]);
    final gallery = galleryRaw.map((e) => PostDto.fromJson(e)).toList();
    expect(gallery.any((p) => p.postId == txtPost.postId), isFalse,
        reason: 'file_type=["image"] 由服务端筛选');
    debugPrint('[p5] 服务端 file_type=["image"] 返回 ${gallery.length} 条 ✓');

    // ---------- ⑦ 删除（附件消息也能删） ----------
    for (final id in [...created]) {
      await chat.deletePost(id);
    }
    created.clear();
    debugPrint('[p5] 清理完成 ✓');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
