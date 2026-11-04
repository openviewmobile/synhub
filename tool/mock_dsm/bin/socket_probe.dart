// Chat 实时通道（Engine.IO v3 / socket.io v2）**宿主侧只读探针**。
//
// 用途：证明"客户端 → Mock/真 NAS 的实时通道"到底通不通，**与平台无关**。
// 第 282 轮新增，起因：第 280 轮 macOS 上 Chat 显示 `Sync failed / 0 channels`，
// 当时无法判断是 macOS 特有还是 Mock 缺口 ⇒ 有了本探针，任何平台都能跑同一实验。
//
// 用法（Mock 先起来：`dart run tool/mock_dsm/bin/serve.dart`）：
//
//     dart run tool/mock_dsm/bin/socket_probe.dart                      # 打 Mock(18080)
//     dart run tool/mock_dsm/bin/socket_probe.dart https://nas:5001     # 打真 NAS（**只读**）
//
// 它**只**做：连 socket、等 open/`40`、发一个 get 类事件、打印收到的帧。
// **零变更动词**（不发 post/delete/create…）。
import 'dart:async';
import 'dart:io';

import 'package:synhub/src/data/remote/socket/eio3_client.dart';

Future<void> main(List<String> argv) async {
  final baseUrl = argv.isNotEmpty ? argv[0] : 'http://127.0.0.1:18080';
  final client = Eio3Client(baseUrl: baseUrl);

  final frames = <String>[];
  final opened = Completer<void>();
  final connected = Completer<void>();

  client.events.listen((e) {
    frames.add('event ${e.name} ${e.payload}');
    stdout.writeln('[probe] ← 事件 ${e.name} ${e.payload}');
  });
  client.onError = (Object e) => stdout.writeln('[probe] !! 错误：$e');
  client.onDisconnected = () => stdout.writeln('[probe] 已断开');

  stdout.writeln('[probe] 连接 $baseUrl/sc/socket.io （EIO=3, transport=websocket）');
  final started = DateTime.now();
  try {
    await client.connect();
  } on Object catch (e) {
    stdout.writeln('[probe] 连接失败（${DateTime.now().difference(started).inMilliseconds} ms）：$e');
    stdout.writeln('结论：**实时通道在此地址上不通**（与运行平台无关，同一实验结果可在 Android/macOS 复现）');
    exitCode = 2;
    return;
  }
  stdout.writeln('[probe] 已连接（${DateTime.now().difference(started).inMilliseconds} ms）');

  // 参考 `chat_socket.dart` 的语义：连上之后问一次频道列表（只读 get）。
  client.emit('get', {'type': 'channel_list'});
  stdout.writeln('[probe] → 已发 get{channel_list}');

  await Future<void>.delayed(const Duration(seconds: 3));
  stdout.writeln('[probe] 收到帧数=${frames.length}（若为 0，说明服务端没回事件）');
  await client.close();
  if (!opened.isCompleted) opened.complete();
  if (!connected.isCompleted) connected.complete();
  stdout.writeln('结论：**实时通道可用**（open + 命名空间握手成功）');
}
