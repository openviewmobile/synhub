// r427 · DA86 的**机制取证**（宿主只读探针）：证明"封面 URL 本身没问题，
// 是 `Image.network` 那条通道拿不到图"。
//
// 三次取同一张专辑封面（`Cover.getcover`，与 App 同一条 URL 构造路径）：
//   ① Dart 默认 `HttpClient`（= `Image.network` 用的那条）→ 预期握手失败；
//   ② 同一 HttpClient + `badCertificateCallback = true` → 预期 200 + 真 JPEG
//      （证明"不是服务端/URL/鉴权的问题，只差 TLS 主机名校验"）；
//   ③ App 自己的 `api.getBytes`（Dio + 信任库 + `_sid` = 修复后的通道）→ 200 + JPEG。
//
// 只读；凭据只从 `--dart-define` 来：
//   set -a; . ~/.synhub-nas.env; set +a
//   flutter test tool/r427_cover_tls_probe_test.dart \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD" \
//     --dart-define=ALBUM="示例专辑" --dart-define=ALBUM_ARTIST="示例歌手"
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const String album = String.fromEnvironment('ALBUM', defaultValue: '示例专辑');
const String albumArtist =
    String.fromEnvironment('ALBUM_ARTIST', defaultValue: '示例歌手');

String classify(List<int> b) {
  if (b.isEmpty) return '空';
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'JPEG';
  }
  if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50) return 'PNG';
  if (b[0] == 0x3C) return 'HTML';
  return '未知';
}

void main() {
  test('r427 DA86：封面 URL × 三条 TLS 通道（只读）', () async {
    if (url.isEmpty || account.isEmpty || password.isEmpty) {
      fail('缺 NAS_URL/NAS_ACCOUNT/NAS_PASSWORD（只从 --dart-define 来）');
    }
    final api = DsmWebApi(
      DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
    );
    await api.discover();
    await api.login(account: account, password: password, session: 'AudioStation');
    final as = AudioStationApi(api);
    final cover = as.albumCoverUrl(album, albumArtist: albumArtist);
    print('[r427] 封面 URL（App 同路径）：$cover');
    print('');

    // ① 默认 HttpClient —— 与 `Image.network` 同一条通道
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final r = await (await c.getUrl(Uri.parse(cover))).close();
      final b = await r.fold<List<int>>(<int>[], (a, x) => a..addAll(x));
      print('[r427] ① 默认 HttpClient：HTTP ${r.statusCode} ${b.length}B ${classify(b)}');
    } catch (e) {
      final msg = '$e'.replaceAll(RegExp(r'\s+'), ' ');
      print('[r427] ① 默认 HttpClient：**失败** ${e.runtimeType}: $msg');
    }

    // ② 同一通道 + 放行证书
    try {
      final c = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..badCertificateCallback = ((cert, host, port) => true);
      final r = await (await c.getUrl(Uri.parse(cover))).close();
      final b = await r.fold<List<int>>(<int>[], (a, x) => a..addAll(x));
      print('[r427] ② 放宽证书后：HTTP ${r.statusCode} ${b.length}B ${classify(b)}');
    } catch (e) {
      print('[r427] ② 放宽证书后：失败 ${e.runtimeType}: '
          '${'$e'.replaceAll(RegExp(r'\s+'), ' ')}');
    }

    // ③ App 自己的字节通道（DA86 修复后的通道）
    try {
      final b = await api.getBytes(cover);
      print('[r427] ③ api.getBytes：${b.length}B ${classify(b.map((e) => e).toList())}');
    } catch (e) {
      print('[r427] ③ api.getBytes：失败 ${e.runtimeType}: $e');
    }

    // ④ 反例：一张服务端没有封面的专辑（00s Love Songs）在 ③ 通道上回什么
    try {
      final b = await api.getBytes(as.albumCoverUrl('00s Love Songs',
          albumArtist: 'Various Artists'));
      final u = Uint8List.fromList(List<int>.from(b));
      print('[r427] ④ 无封面专辑：${u.length}B ${classify(u.toList())}'
          '（前端靠空/非图判定回落）');
    } catch (e) {
      print('[r427] ④ 无封面专辑：失败 ${e.runtimeType}: $e');
    }

    await api.logout();
    print('[r427] 已登出（零写动词）');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
