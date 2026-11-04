// P0.1「内嵌预览 / 缩略图」的真机端到端验证。
//
// 跑法（真机 + 真 NAS）：
//   flutter test integration_test/p0_preview_test.dart -d <device> \
//     --dart-define=SYNO_NAS_QC=demo_admin-qq \
//     --dart-define=SYNO_NAS_ACCOUNT=… --dart-define=SYNO_NAS_PASSWORD=… \
//     --dart-define=SYNO_LIVE_POST=true
//
// 验证的东西（都看服务器的真实反应）：
//   ① 缩略图三档都是**真图字节**（不是 HTML 错误页）；
//   ② 文本预览只取开头（`Range` 生效，服务端回 206）；
//   ③ 不存在的文件：`getBytes` **必须抛**（以前会把 HTML 当文件返回）；
//   ④ 预览页挂真连接，能把真实文件内容渲染出来。
//
// 写操作只落在自己的临时目录里，结尾删干净。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_thumb.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _liveRaw = String.fromEnvironment('SYNO_LIVE_POST');
bool get _live => _liveRaw.isNotEmpty && _liveRaw != 'false';

/// 造一张**够大**的 PNG（太小的图服务端会直接把原图回给你，看不出缩略图效果）
List<int> bigPng({int w = 900, int h = 600}) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, x % 256, y % 256, (x + y) % 256);
    }
  }
  return img.encodePng(image);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('P0.1 真机：缩略图 / 文本 Range / 预览页', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(account: _account, password: _password, session: 'Chat');
    final fs = FileStationApi(conn.api);
    debugPrint('[p01] 连接：${conn.endpoint.source} ${conn.endpoint.baseUrl}');

    // 临时工作区（这台 NAS 上普通用户可写的是 home 共享）
    final dir = '/home/flt-preview-${DateTime.now().millisecondsSinceEpoch}';
    var created = false;
    addTearDown(() async {
      if (!created) return;
      try {
        await conn.api.call('SYNO.FileStation.Delete', 'delete',
            preferredVersion: 2,
            params: {
              'path': FileEntryDto.encodePaths([dir]),
              'recursive': true,
            });
        debugPrint('[p01] 已清理 $dir');
      } catch (e) {
        debugPrint('[p01] 清理失败（请手动删 $dir）: $e');
      }
    });
    if (!_live) {
      debugPrint('[p01] 未开 SYNO_LIVE_POST，跳过上传部分');
    }

    await fs.createFolder(folderPath: '/home', name: dir.split('/').last);
    created = true;

    // 上传一张真图 + 一个超过 64KB 的文本
    final pngPath = '${Directory.systemTemp.path}/flt-preview.png';
    File(pngPath).writeAsBytesSync(bigPng());
    final pngSize = File(pngPath).lengthSync();
    await fs.upload(folderPath: dir, filePath: pngPath, fileName: 'pic.png');

    final txtPath = '${Directory.systemTemp.path}/flt-preview.txt';
    final lines = List.generate(3000, (i) => 'line $i: 预览测试数据 hello world');
    File(txtPath).writeAsStringSync(lines.join('\n'));
    final txtSize = File(txtPath).lengthSync();
    await fs.upload(folderPath: dir, filePath: txtPath, fileName: 'notes.log');
    debugPrint('[p01] 上传完成：pic.png $pngSize B, notes.log $txtSize B');

    // ① 缩略图三档都是真图
    final sizes = <String, int>{};
    for (final size in ['small', 'medium', 'large']) {
      final raw = await conn.api.getBytes(fs.thumbnailUrl('$dir/pic.png', size: size));
      final bytes = Uint8List.fromList(raw);
      expect(looksLikeImage(bytes), isTrue,
          reason: 'Thumb[$size] 必须是真图字节（不是 HTML 错误页）');
      sizes[size] = bytes.length;
    }
    debugPrint('[p01] ① 缩略图 $sizes');
    expect(sizes['small'], lessThan(pngSize),
        reason: 'small 缩略图应该明显小于原图（$pngSize B）');

    // ② 文本只取开头
    final head = await conn.api.getBytes(
      fs.downloadUrl(['$dir/notes.log']),
      maxBytes: kTextHeadBytes,
    );
    expect(head.length, lessThanOrEqualTo(kTextHeadBytes));
    expect(head.length, lessThan(txtSize), reason: 'Range 生效就要小于全量');
    final decoded = decodeTextHead(head);
    expect(decoded.text, contains('line 0:'));
    expect(decoded.truncated, isTrue, reason: '文件比 64KB 大，应判为截断');
    debugPrint('[p01] ② 文本头 ${head.length}B/${txtSize}B 截断=${decoded.truncated}');

    // ③ 不存在的文件必须抛错（以前会把 HTML 错误页当文件返回）
    var threw = false;
    try {
      await conn.api
          .getBytes(fs.thumbnailUrl('$dir/definitely-missing-9f3a.png'));
    } catch (e) {
      threw = true;
      debugPrint('[p01] ③ 缺文件按预期抛错：$e');
    }
    expect(threw, isTrue, reason: '404/502 的 HTML 不能被当成文件内容');

    // ④ 预览页挂真连接：文本内容真的渲染出来
    //
    // ⚠️ 这里用 `.log` 而不是 `.txt`：本仓第 256 轮起 `.txt`/`.md`/`.docx`…
    //    走**内嵌阅读器**（`filePreviewKind` → `FilePreviewKind.book`），
    //    文本舞台（`_TextStage`）只认 `FilePreviewKind.text`
    //    （`log/json/xml/ini/conf/dart/…`）。原来喂 `.txt` 时这一步根本到不了
    //    文本舞台 ⇒ 红灯是**测试前提过期**，不是预览不可用；
    //    钉子见 `test/file_preview_test.dart:267-270`（`.txt`=book / `.dart`=text）
    //    与 `lib/src/features/files/file_preview_page.dart:174-185`（改道注释）。
    //
    // ⚠️ 这台机器上 integration_test 的 live binding 只能稳定 pump 两次，
    //    所以只做 "pumpWidget + 一次 pump"。
    final textEntry = FileEntryDto(
      name: 'notes.log',
      path: '$dir/notes.log',
      isDir: false,
      size: txtSize,
      mtime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    // 把"这个扩展名确实路由到文本舞台"钉在用例里：以后谁再把 `.log` 改道，
    // 这里会**直接**报出原因，而不是又变成一句 `Found 0 widgets`。
    expect(filePreviewKind(textEntry), FilePreviewKind.text);
    final db = ChatDatabase(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(fs),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: FilePreviewPage(entry: textEntry)),
    ));
    await Future<void>.delayed(const Duration(seconds: 4));
    await tester.pump();
    expect(find.textContaining('line 0:'), findsOneWidget,
        reason: '预览页应该把真实文件内容渲染出来');
    expect(find.textContaining('只显示开头'), findsOneWidget,
        reason: '大文本应提示被截断');
    debugPrint('[p01] ④ 预览页渲染 OK');

    debugPrint('[p01] ✅ 全部通过');
  });
}
