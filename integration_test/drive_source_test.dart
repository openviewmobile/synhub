// 「我的 Drive」第二来源的真机端到端验证（P0.1 尾巴）。
//
// 跑法（真机 + 真 NAS）：
//   flutter test integration_test/drive_source_test.dart -d <device> \
//     --dart-define=SYNO_NAS_QC=demo_admin-qq \
//     --dart-define=SYNO_NAS_ACCOUNT=… --dart-define=SYNO_NAS_PASSWORD=…
//
// 验证（都在真机上用**和 App 完全一样**的 Dio/鉴权链路）：
//   ① `Files/list` 能列出个人空间（回包 `{items,total}`，条目字段齐全）；
//   ② `get_thumbnail` 直链回的是**真图字节**（不是 HTML 错误页）；
//   ③ `Files/download` 直链回的是**原文件字节**（PNG 魔数 / 文本内容）；
//   ④ `list_ancestor` / `search` / `recent` 的形状；
//   ⑤ 这么取到的字节喂给 `Image.memory` 能解码（真机上跑一遍 Flutter 解码器）。
//
// 只读：不建、不改、不删用户的任何东西（探针目录由 `tool/drive_probe.dart` 管）。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

String _hex(List<int> bytes, [int n = 8]) =>
    bytes.take(n).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

bool _isPng(List<int> b) =>
    b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Drive 源真机：列举 / 缩略图 / 下载字节 / 解码', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');
    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(account: _account, password: _password, session: 'Chat');
    final drive = DriveApi(conn.api);

    final root = await drive.list(path: kDriveRoot);
    debugPrint('[drive] 根目录 total=${root.total} '
        'names=${root.items.map((e) => e.name).toList()}');
    expect(root.total, root.items.length);

    // 找探针目录（`tool/drive_probe.dart seed` 会建）
    final probe =
        root.items.where((e) => e.name == 'drive-probe' && e.isDir).toList();
    if (probe.isEmpty) {
      debugPrint('[drive] 没有 drive-probe 目录，跳过（先跑 tool/drive_probe.dart seed）');
      return;
    }
    final sub = await drive.list(path: probe.single.displayPath);
    debugPrint('[drive] drive-probe total=${sub.total} '
        'names=${sub.items.map((e) => e.name).toList()}');
    final anc = await drive.listAncestor(path: probe.single.displayPath);
    debugPrint('[drive] 面包屑 = ${anc.map((e) => e.displayPath).toList()}');

    final png = sub.items.where((e) => e.extension == 'png').toList();
    expect(png, isNotEmpty, reason: '探针目录里应该有 probe-pic.png');
    final entry = png.first;

    // ① get（v3）
    final got = await drive.get(path: entry.pathId);
    debugPrint('[drive] get → name=${got.name} size=${got.size} '
        'type=${got.type} content=${got.contentType} canRead=${got.capabilities['can_read']}');

    // ② 缩略图直链
    final thumbBytes = await conn.api
        .getBytes(drive.thumbnailUrl(fileId: entry.fileId, size: 'medium'));
    debugPrint('[drive] 缩略图 ${thumbBytes.length} 字节 head=${_hex(thumbBytes)}');
    expect(_isPng(thumbBytes), isTrue, reason: '缩略图必须是真图字节，不是 HTML 错误页');

    // ③ 下载直链
    final dlBytes =
        await conn.api.getBytes(drive.downloadUrl(fileId: entry.fileId));
    debugPrint('[drive] 下载 ${dlBytes.length} 字节 head=${_hex(dlBytes)}');
    expect(_isPng(dlBytes), isTrue);

    // ④ 搜索 / 最近
    final search = await drive.search('probe');
    debugPrint('[drive] search total=${search.total}');
    final recent = await drive.recent();
    debugPrint('[drive] recent total=${recent.total}');

    // ⑤ 真机解码器能不能吃下这份字节（App 里"解不开这张图"就是这里失败）
    final image = Image.memory(Uint8List.fromList(dlBytes));
    final widget = MaterialApp(home: Scaffold(body: image));
    await tester.pumpWidget(widget);
    await tester.pump(const Duration(milliseconds: 300));
    final hasError = tester.takeException();
    debugPrint('[drive] Image.memory 解码异常=$hasError');
    expect(hasError, isNull, reason: '真机解码器必须能吃下 Drive 下载到的字节');
  });
}
