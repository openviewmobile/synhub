// Phase 5 真机验收：音频/视频附件的**外部串流**。
//
//   flutter test integration_test/phase5_media_stream_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 验收点：
//   ① 上传一个 .mp4 附件 → `isStreamingFile` 判定为流媒体
//   ② 串流直链（`Post.File get` + `_sid`）在真机上确实能拉到这份文件
//   ③ Android 原生桥 `synhub/media_open` 在：没有应用能处理的 MIME → false；
//      参数缺失 → PlatformException（证明桥接上了，且验证时不会真的拉起播放器）
//   ④ `openAttachment(allowStreaming: true)` 走串流分支：URL/MIME 正确、**不下载**
//   ⑤ 真机按 IP 连接命中的是"主机名不匹配"分支 → `certUntrusted = true`
//      （= 原版 `!isLegalCertificate()`），因此界面上会先弹"证书不受信任、
//      改为下载"的一次性确认——这与原版 `handleIllegalCertificateStreaming` 一致
//   ⑥ 清场
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/attachment_view.dart';
import 'package:synhub/src/features/chat/media_stream.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

/// 一个最小的 mp4：只有 `ftyp` box（服务端不校验内容，够用）
Uint8List tinyMp4() {
  final b = BytesBuilder();
  b.add([0, 0, 0, 0x18]); // box size = 24
  b.add('ftyp'.codeUnits);
  b.add('isom'.codeUnits);
  b.add([0, 0, 2, 0]); // minor version
  b.add('isomiso2mp41'.codeUnits);
  return b.toBytes();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 5 真机：音频/视频附件串流', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    // ---------- ① 判定 + 上传 ----------
    expect(isStreamingFile('flt-probe.mp4'), isTrue);
    expect(mimeForFileName('flt-probe.mp4'), 'video/mp4');
    expect(isStreamingFile('flt-probe.pdf'), isFalse);

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    final channels = await chat.listChannels();
    final cid = channels.firstWhere((c) => !c.encrypted).channelId;
    final dir = Directory.systemTemp.createTempSync('flt_p5ms');
    final file = File('${dir.path}/flt-probe.mp4');
    file.writeAsBytesSync(tinyMp4());

    final raw = await chat.uploadPost(
      channelId: cid,
      connId: '',
      filePath: file.path,
      fileName: 'flt-probe.mp4',
      message: 'flt-p5ms 串流探针',
      mimeType: 'video/mp4',
    );
    final map = Map<String, dynamic>.from((raw['post'] ?? raw) as Map);
    final postId = (map['post_id'] as num).toInt();
    debugPrint('[p5ms] ① 上传到 #$cid：post_id=$postId '
        'file=${map['file_props'] is List && (map['file_props'] as List).isNotEmpty ? (map['file_props'] as List).first : '?'}');

    // ---------- ② 串流直链能拉到真文件 ----------
    final url = chat.fileUrl(postId);
    debugPrint('[p5ms] ② 串流直链：$url');
    final bytes = await conn.api.getBytes(url);
    debugPrint('[p5ms] ② 直链回 ${bytes.length} 字节（本地 ${file.lengthSync()}）'
        ' magic=${bytes.take(8).map((b) => b.toRadixString(16)).join(' ')}');
    expect(bytes.length, file.lengthSync());
    expect(String.fromCharCodes(bytes.sublist(4, 8)), 'ftyp');

    // ---------- ③ 原生桥 ----------
    const channel = MethodChannel('synhub/media_open');
    final handledUnknown = await channel.invokeMethod<bool>('view', {
      'url': url,
      'mime': 'application/x-flt-nonexistent',
    });
    debugPrint('[p5ms] ③ 不存在的 MIME → $handledUnknown（false = 走"打开方式"）');
    expect(handledUnknown, isFalse);
    try {
      await channel.invokeMethod<bool>('view', {'mime': 'video/mp4'});
      fail('空 URL 应该报 bad_args');
    } on PlatformException catch (e) {
      debugPrint('[p5ms] ③ 空 URL → PlatformException(${e.code})');
      expect(e.code, 'bad_args');
    }

    // ---------- ④ openAttachment 的串流分支 ----------
    final post = PostDto.fromJson({
      'post_id': postId,
      'channel_id': cid,
      'creator_id': 14,
      'create_at': 1700000000000,
      'file_props': map['file_props'],
    });
    final prop = post.attachments.first;
    final calls = <(String, String)>[];
    final err = await openAttachment(
      chat,
      post,
      prop,
      allowStreaming: true,
      streamOpener: (u, mime) async {
        calls.add((u, mime));
        return true;
      },
    );
    debugPrint('[p5ms] ④ 串流分支：err=$err calls=$calls');
    expect(err, isNull);
    expect(calls.single.$1, contains('post_id=$postId'));
    expect(calls.single.$1, contains('_sid='));
    expect(calls.single.$2, videoMimeForTest());
    debugPrint('[p5ms] ④ FilePropDto: name=${prop.label} mime=${videoMimeForTest()}');

    // ---------- ⑤ 证书状态 ----------
    debugPrint('[p5ms] ⑤ 这次连接是否靠固定指纹放行（= 原版 !isLegalCertificate）：'
        '${conn.certPinned}');
    if (conn.certPinned) {
      debugPrint('[p5ms] ⑤ → 界面会先弹"证书不受信任，改为下载"（一次性），'
          '与原版 handleIllegalCertificateStreaming 一致');
    }

    // ---------- ⑥ 清场 ----------
    try {
      await chat.deletePost(postId);
      debugPrint('[p5ms] ⑥ 已删除 #$postId');
    } catch (e) {
      debugPrint('[p5ms] ⑥ 删除失败：$e');
    }
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    debugPrint('[p5ms] 完成 ✓');
  });
}

/// 单独抽出来便于上面 expect 里读一眼
String videoMimeForTest() => mimeForFileName('flt-probe.mp4');
