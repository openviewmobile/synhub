// CLI：在电脑上起一台 DSM Mock Server。
//
//     dart run tool/mock_dsm/bin/serve.dart [--port 18080] [--account admin] [--admin]
//       [--drive-demo] [--fs-demo] [--download-demo]
//
// 真机把它当服务器地址填（`http://<电脑局域网 IP>:<port>`）即可在不碰真 NAS 的
// 前提下验证客户端 —— 这也是新规里"无法验证的也通过模拟服务器来验证"的手段。
import 'dart:async';
import 'dart:io';

import '../mock_dsm_core.dart';
import '../mock_dsm_server.dart';

Future<void> main(List<String> argv) async {
  var port = 18080;
  var account = 'mockuser';
  var admin = false;
  var driveDemo = false;
  var fsDemo = false;
  var downloadDemo = false;
  var noteDemo = false;
  var photoDemo = false;
  // ★ r436：相册「人物 / 场景」这一面（`enable_person`/`enable_concept` = true
  //   ＋ 人物名册 / 场景夹具）。
  var smartAlbumDemo = false;
  var chatDemo = false;
  // ★ r433：`AppPrivilege` 画像（模块可见性实验）。
  // r701 · B12 弱网仪器（容器无 CAP_NET_ADMIN ⇒ 用 Mock 侧整型代替 tc/netem）
  var latencyMs = 0;
  var failAfter = 0;
  var failRate = 0.0;
  var privReal = false;
  var privAllowAll = false;
  final privOff = <String>{};
  final privOmit = <String>{};
  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--port':
        port = int.parse(argv[++i]);
      case '--account':
        account = argv[++i];
      case '--admin':
        admin = true;
      case '--drive-demo':
        driveDemo = true;
      case '--fs-demo':
        fsDemo = true;
      case '--download-demo':
        downloadDemo = true;
      case '--note-demo':
        noteDemo = true;
      case '--photo-demo':
        photoDemo = true;
      case '--smart-album-demo':
        smartAlbumDemo = true;
      case '--chat-demo':
        chatDemo = true;
      case '--latency-ms':
        latencyMs = int.parse(argv[++i]);
      case '--fail-after':
        failAfter = int.parse(argv[++i]);
      case '--fail-rate':
        failRate = double.parse(argv[++i]);
      case '--priv-real':
        privReal = true;
      case '--priv-allow-all':
        privAllowAll = true;
      case '--priv-off':
        privOff.addAll(argv[++i].split(','));
      case '--priv-omit':
        privOmit.addAll(argv[++i].split(','));
      case '-h':
      case '--help':
        stdout.writeln(
          '用法: serve.dart [--port 18080] [--account <名>] [--admin] '
          '[--drive-demo] [--fs-demo] [--download-demo] [--note-demo]'
          ' [--photo-demo] [--smart-album-demo] [--chat-demo]'
          ' [--priv-real] [--priv-off <键[,键]>] [--priv-omit <键[,键]>]'
          ' [--priv-allow-all] [--latency-ms <ms>] [--fail-after <n>]'
          ' [--fail-rate <0..1>]\n'
          '  --latency-ms : 每个请求延迟这么多毫秒（验加载态）\n'
          '  --fail-after : 前 n 个请求正常（够登录/首屏），之后才可能失败\n'
          '  --fail-rate  : 超过 --fail-after 后按比例回 503（验错误态/重试）\n'
          '  --smart-album-demo : 相册人物/场景面（enable_person/enable_concept=true\n'
          '                        + 人物名册 / 场景夹具）\n'
          '  --priv-real : 按真机形状回 AppPrivilege（默认只回通配键）\n'
          '  --priv-off  : 这些模块权限键回 false（= 明确拒绝）\n'
          '  --priv-omit : 这些键**完全不出现**（= 键不存在，官方判不放行）',
        );
        return;
    }
  }

  final s = await MockDsmHttpServer.start(
    port: port,
    account: account,
    admin: admin,
    driveDemo: driveDemo,
    fsDemo: fsDemo,
    downloadDemo: downloadDemo,
    noteDemo: noteDemo,
    photoDemo: photoDemo,
    smartAlbumDemo: smartAlbumDemo,
    chatDemo: chatDemo,
    appPrivilegeProfileKeys: privReal ? kMockRealAppPrivilegeKeys : null,
    appPrivilegeDenied: privOff,
    appPrivilegeOmitted: privOmit,
    appPrivilegeAllowAll: privAllowAll,
    latencyMs: latencyMs,
    failAfter: failAfter,
    failRate: failRate,
  );
  final cat = DsmCatalog.load();
  stdout
    ..writeln('DSM Mock Server 已启动')
    ..writeln('  本机    : ${s.baseUrl}')
    ..writeln('  局域网  : ${await s.lanUrl()}')
    ..writeln(
      '  目录    : ${cat.apiCount} 个 API'
      '（普通 ${cat.normalOnly.length} / 仅管理员 ${cat.adminOnly.length}）',
    )
    ..writeln('  夹具    : ${s.fixturesLoaded} 条')
    ..writeln('  会话    : $account${admin ? '（管理员）' : '（普通用户）'}');
  if (latencyMs > 0 || failRate > 0) {
    stdout.writeln(
      '  弱网    : latency=${latencyMs}ms '
      'failAfter=$failAfter failRate=$failRate（Mock 侧整型，不是 tc/netem）',
    );
  }
  if (privReal) {
    final n = kMockRealAppPrivilegeKeys.length - privOmit.length;
    stdout.writeln(
      '  权限画像: **真机形状** ${kMockRealAppPrivilegeKeys.length} 键'
      '（回 $n 个，false ${privOff.length} 个'
      '${privOmit.isEmpty ? '' : '，省略 ${privOmit.length} 个'}'
      '${privAllowAll ? '，＋通配键' : ''}）',
    );
    if (privOff.isNotEmpty) stdout.writeln('    回 false : ${privOff.join(', ')}');
    if (privOmit.isNotEmpty) stdout.writeln('    省略     : ${privOmit.join(', ')}');
  }
  if (driveDemo) {
    stdout
      ..writeln('  Drive   : demo 夹具已装')
      ..writeln('    文件 id : $kDriveDemoFileId')
      ..writeln('    文件名  : $kDriveDemoFileName')
      ..writeln('    sid     : ${s.demoSid}');
  }
  if (fsDemo) {
    stdout.writeln('  文件系统: 可写内存树已装（List/CreateFolder/Rename/Delete/Upload）');
  }
  if (chatDemo) {
    stdout.writeln('聊天库  : 可写内存频道消息已装（--chat-demo，socket 会下发 client.init）');
  }
  if (photoDemo) {
    stdout.writeln('相册库  : 可写内存时间轴已装（--photo-demo）');
  }
  if (noteDemo) {
    stdout.writeln('  笔记库  : 可写内存笔记本/笔记已装（Notebook/Note 的 list/get/create/set/delete）');
  }
  if (downloadDemo) {
    stdout.writeln(
      '  下载队列: 可写内存队列已装（Task.list/get/create/delete · Statistic · Location）',
    );
  }
  await ProcessSignal.sigint.watch().first;
  await s.stop();
}
