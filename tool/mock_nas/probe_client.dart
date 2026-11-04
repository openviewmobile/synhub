// 用**本项目真实的 DSM 客户端代码**打本地 Mock NAS —— 证明 mock 与 App 的
// 协议实现兼容（登录的 RSA 加密、能力表解析、`_sid`/`SynoToken` 拼装、119 解析），
// 只是**不经过 Android**（真机网络策略只能在设备上验，见 README §"http vs https"）。
//
// 用法（先把 mock 跑起来，见 README）：
//   dart run tool/mock_nas/probe_client.dart --url=http://127.0.0.1:8788
//   dart run tool/mock_nas/probe_client.dart --url=http://127.0.0.1:8796   # 截断实例
//
// **零三方依赖**之外只依赖本项目自己的 `lib/`（dio 已在 pubspec 里）。
// 不打印任何真实 NAS 凭据；mock 的 sid/token 是明显假值。
//
// ignore_for_file: avoid_print

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

String _arg(List<String> argv, String key, String fallback) {
  for (final a in argv) {
    if (a.startsWith('$key=')) return a.substring(key.length + 1);
  }
  return fallback;
}

String _mask(String? s) {
  if (s == null || s.isEmpty) return '(none)';
  if (s.length <= 8) return '$s…';
  return '${s.substring(0, 6)}…(${s.length})';
}

Future<void> main(List<String> argv) async {
  final url = _arg(argv, '--url', 'http://127.0.0.1:8788');
  print('[probe] 目标 mock：$url');

  final api = DsmWebApi(DirectTransport.url(url, dio: DioFactory.create()));

  // ① 能力表（= 真机上的"降级"判据来源）
  final table = await api.discover();
  bool has(String n) => table.containsKey(n);
  print('[probe] discover：${table.length} 个 API');
  print('[probe]   SYNO.FileStation.List   = ${has('SYNO.FileStation.List')}');
  print('[probe]   SYNO.FileStation.Download = ${has('SYNO.FileStation.Download')}');
  print('[probe]   SYNO.Foto.Browse.Item  = ${has('SYNO.Foto.Browse.Item')}');
  print('[probe]   SYNO.Chat.Channel      = ${has('SYNO.Chat.Channel')}');

  // ② 登录（会真做 SYNO.API.Encryption getinfo + RSA(PKCS1) 加密 account/passwd）
  final session = await api.login(
    account: 'mock',
    password: 'mock',
    session: 'Chat',
  );
  print('[probe] login OK：sid=${_mask(session.sid)} '
      'synotoken=${_mask(session.synotoken)}');

  final fs = FileStationApi(api);

  // ③ 列目录
  try {
    final list = await fs.listFolder(folderPath: '/home/Books');
    print('[probe] List /home/Books：${list.entries.length} 项 → '
        '${list.entries.map((e) => '${e.name}${e.isDir ? '/' : ''}').join(', ')}');
  } catch (e) {
    print('[probe] List 失败（预期于 --list-error 实例）：$e');
  }

  // ④ 直链形态（Range 判定用）
  final dl = fs.downloadUrl(['/home/Books/mock-clip.mp4'], mode: 'download');
  final q = Uri.tryParse(dl)?.queryParameters ?? const {};
  print('[probe] downloadUrl：has _sid=${q['_sid'] != null} '
      'has SynoToken=${q['SynoToken'] != null} '
      'api=${q['api']} method=${q['method']}');

  // ⑤ 取前 64 字节（`getBytes(maxBytes:)` → `Range: bytes=0-63`）
  try {
    final head = await api.getBytes(dl, maxBytes: 64);
    print('[probe] getBytes(maxBytes=64)：收到 ${head.length} 字节'
        '${head.length == 64 ? '（若 --range=off 会明显多于 64）' : ''}');
    if (head.length == 38 &&
        String.fromCharCodes(head).contains('"code":119')) {
      print('[probe] ⚠️ 收到的是 119 的 JSON 体（HTTP 200）——'
          '这条只能靠调用方解析错误码，媒体通道会误判（见 README §4）');
    }
  } catch (e) {
    if (e is DsmApiException) {
      print('[probe] getBytes 抛 DsmApiException code=${e.code} '
          '（--download-error 注入，且 --error-http-status=403）');
    } else {
      print('[probe] getBytes 失败：${e.runtimeType}: $e');
      print('[probe]   （--download-truncate-after 实例会在此断流）');
    }
  }

  // ⑥ 会话失效的错误码路径：同一 sid 的下一次调用应拿到 119
  try {
    await api.call('SYNO.FileStation.List', 'list', params: {
      'folder_path': '/home/Books',
      'additional': '["size"]',
      'offset': 0,
      'limit': 0,
    });
    print('[probe] call List：成功（会话仍有效）');
  } on DsmApiException catch (e) {
    print('[probe] call List 抛 DsmApiException code=${e.code} '
        '${e.code == 119 ? '→ sessionExpired 分支（会话失效）' : ''}');
  } catch (e) {
    print('[probe] call List 其它失败：${e.runtimeType}: $e');
  }

  await api.transport.close();
  print('[probe] 结束');
}
