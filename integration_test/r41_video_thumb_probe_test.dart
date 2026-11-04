// 第 41 轮：File Station 视频缩略图 —— 零坐标真机探针（只读）。
//
// 跑法（**跑完必须装回正常包**，否则设备上留下的是测试入口，会永远停在 splash）：
//   flutter drive --keep-app-running --driver=test_driver/integration_test.dart \
//     --target=integration_test/r41_video_thumb_probe_test.dart -d <id> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… --dart-define=SYNO_NAS_PASSWORD='…'
//
// 三层证据：① 闸门（req/supported）② 头部 Range 实测（status/Content-Range/实收字节）
//          ③ 原生 extractFrameEx 的 `stage`（失败在哪一段）。
// §5.1：只读（list + Range 读 + 本地临时文件），对 NAS 变更动词为零。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/features/media/media_cover.dart'
    show normalizeMediaExtension;
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/video_frame_thumb.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _folder = String.fromEnvironment(
  'SYNO_PROBE_FOLDER',
  defaultValue: '/home/Video',
);
const _ch = MethodChannel('synhub/video_frame');
const int _headBytes = kVideoFrameHeadBytes; // ★ 6 MB：必须与 App 一致（512KB 是我上一版的错误参数）

Future<Uint8List> _rangeGet(Uri uri, int maxBytes) async {
  final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
  try {
    final req = await client.getUrl(uri);
    req.headers.set('Range', 'bytes=0-${maxBytes - 1}');
    final resp = await req.close().timeout(const Duration(seconds: 30));
    final b = BytesBuilder();
    await for (final chunk in resp) {
      b.add(chunk);
      if (b.length >= maxBytes) break; // ★ 截断保护：绝不把整份 4.7GB 拉下来
    }
    debugPrint(
      '[probeA] status=${resp.statusCode} '
      'contentRange=${resp.headers.value('content-range')} '
      'contentLength=${resp.headers.contentLength} got=${b.length}',
    );
    client.close(force: true);
    return b.takeBytes();
  } finally {
    client.close(force: true);
  }
}


/// 帧图平均亮度（0=全黑，255=全白）——"黑帧"要用像素判，不能靠肉眼。
Future<int> _meanLuma(Uint8List encoded) async {
  try {
    final codec = await ui.instantiateImageCodec(encoded);
    final f = await codec.getNextFrame();
    final bd = await f.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return -1;
    final b = bd.buffer.asUint8List();
    var sum = 0, n = 0;
    for (var i = 0; i + 2 < b.length; i += 4) {
      sum += (b[i] * 299 + b[i + 1] * 587 + b[i + 2] * 114) ~/ 1000;
      n++;
    }
    return n == 0 ? -1 : sum ~/ n;
  } catch (_) {
    return -2;
  }
}

Future<void> _probeFrames(String tag, String path, {bool asUrl = true}) async {
  for (final atMs in <int>[0]) { // ★ 黑场重试已进原生，这里只测真实调用点
    try {
      final raw = await _ch.invokeMethod<Object?>('extractFrameEx', {
        if (asUrl) 'url': path else 'path': path,
        'headers': const <String, String>{},
        'atMs': atMs,
        'maxWidth': 512,
      });
      if (raw is! Map) {
        debugPrint('[probeC] $tag atMs=$atMs 非 Map: ${raw.runtimeType}');
        continue;
      }
      final bytes = raw['bytes'];
      if (bytes is Uint8List && bytes.isNotEmpty) {
        final luma = await _meanLuma(bytes);
        debugPrint('[probeC] $tag mode=${asUrl ? "url" : "file"} via=${raw['via']} '
            'stage=${raw['stage']} 帧=${bytes.length}B luma=$luma 原生luma=${raw['luma']} '
            'tried=${raw['triedAtMs']} dur=${raw['durationMs']} fourcc=${raw['videoFourcc']} '
            'codec=${raw['codecMime']} w=${raw['width']} h=${raw['height']}');
      } else {
        debugPrint('[probeC] $tag atMs=$atMs via=${raw['via']} stage=${raw['stage']} '
            '无帧 tried=${raw['triedAtMs']} err=${raw['error']}');
      }
    } catch (err) {
      debugPrint('[probeC] $tag atMs=$atMs 异常：$err');
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('第 41 轮：视频抽帧三层探针（只读）', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');
    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(account: _account, password: _password, session: 'Chat');
    final fs = FileStationApi(conn.api);

    final listing = await fs.listFolder(folderPath: _folder, limit: 200);
    debugPrint('[probe] $_folder 共 ${listing.entries.length} 项');

    var n = 0;
    for (final e in listing.entries) {
      if (e.isDir) continue;
      final ext = normalizeMediaExtension(e.extension);
      if (!kVideoFrameContainers.contains(ext)) continue;
      n++;
      final src = resolveEntryMediaSource(
        entry: e,
        kind: MediaKind.video,
        fs: fs,
      );
      final req = videoFrameThumbRequestFor(e, src);
      debugPrint(
        '[probe] #$n ${e.name} | size=${e.size} ext=$ext | uri=${src.uri.isEmpty ? "empty" : "ok"} '
        'range=${src.supportsRange} req=${req != null} supported=${videoFrameThumbSupported(req)}',
      );

      // ① 头部 Range 实测
      Uint8List head;
      try {
        head = await _rangeGet(Uri.parse(src.uri), _headBytes);
      } catch (err) {
        debugPrint('[probeA] #$n 取头部异常：$err');
        continue;
      }
      debugPrint('[probeA] #$n 收到 ${head.length} 字节');

      // ② 原生抽帧（用同一份头部字节落盘）
      final tmp = File('${Directory.systemTemp.path}/probe_$n.$ext');
      await tmp.writeAsBytes(head);
      await _probeFrames('#$n ${e.name}', src.uri);
      await _probeFrames('#$n ${e.name}', tmp.path, asUrl: false);
      await tmp.delete().catchError((_) => tmp);
    }
    debugPrint('[probe] 共测视频 $n 个');
    expect(n, greaterThan(0));
  });
}
