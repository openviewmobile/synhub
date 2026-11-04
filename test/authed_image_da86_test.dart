// DA86（r427）：NAS 直链图片必须走**鉴权字节通道**，不许用 `Image.network`。
//
// 真机事实（`docs/evidence-r427/`）：设备按 **IP** 连 NAS（`nas.example.com:5001`，
// `/proc/net/tcp` 实证），而证书 SAN 只有 `*.nas.example.com`
// （`openssl s_client -verify_hostname nas.example.com` → **verify error 62**）
// ⇒ `Image.network`（Dart 自带 HttpClient，严格主机名校验 + 不带 TrustStore）
// 握手失败 ⇒ `errorBuilder` ⇒ 一路静默退成图标占位。
// 真机像素：歌曲行 leading 是音符图标，而 `getsongcover` 明明回 `55,253 B` 真 JPEG。
//
// 本文件的判据分两层：
//   ① **行为**：字节通道拿到图 → 真出 `Image`（`MemoryImage`）；空/异常 → 回落；
//      同一 URL 只用取一次（会话级缓存）。
//   ② **结构**（防回退）：三个曾经泄漏的调用点源码里**不许再出现**
//      `Image.network(` 的代码行（注释里可以提 —— 讲清楚"为什么不用"）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_cover.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/media/authed_image.dart';
import 'package:synhub/src/core/theme/app_theme.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 真 PNG（能真解码；测试里绝不用假字节骗 `Image.memory`）
final Uint8List kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// 只在**传输层**覆盖 `getBytes`：记录请求过的 URL，按脚本回字节或抛异常。
///
/// 为什么不在 `DsmWebApi` 上覆盖：`AudioStationApi` 构造时会
/// `api.withModule('audio')` 生成**会话视图**，视图的 `getBytes` 直接转发到
/// `transport`（`webapi.dart:1906`）—— 在 api 层覆盖根本不会被走到（第一版
/// 用例就是这么假绿的：`asked.length == 0`）。所以假件必须贴在**传输层**，
/// 这也正是生产路径（仪器96：注入样本要与真实形态一致）。
class _BytesTransport extends FakeTransport {
  _BytesTransport({this.bytes, this.throwing = false});

  final Uint8List? bytes;
  final bool throwing;
  final List<String> asked = <String>[];

  @override
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) async {
    asked.add(url);
    if (throwing) throw const SocketException('握手失败（DA86 现场）');
    return bytes ?? const <int>[];
  }
}

Widget _host(Widget child, {_BytesTransport? t}) {
  final container = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(
        t == null ? null : AudioStationApi(DsmWebApi(t)),
      ),
    ],
  );
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child)),
  );
}

void main() {
  setUp(AuthedImageCache.reset);

  group('① 行为：鉴权字节通道', () {
    testWidgets('DA86 拿到字节 ⇒ 真出 Image（MemoryImage），不再只有图标', (tester) async {
      final api = _BytesTransport(bytes: kPng1x1);
      await tester.pumpWidget(
        _host(
          const AudioCoverImage(
            key: Key('c'),
            identity: 'music_1',
            url: 'https://nas.example.com:5001/webapi/AudioStation/cover.cgi'
                '?method=getsongcover&id=music_1',
          ),
          t: api,
        ),
      );
      await tester.pump(); // 让 future 落地
      await tester.pump();
      expect(api.asked.length, 1, reason: '封面必须走 getBytes（Application 通道）');
      expect(find.byType(Image), findsOneWidget);
      final img = tester.widget<Image>(find.byType(Image));
      expect(img.image, isA<MemoryImage>());
      expect(find.byIcon(Icons.music_note_outlined), findsNothing);
    });

    testWidgets('DA86 取字节抛异常（真机就是这个）⇒ 回落图标，不崩', (tester) async {
      final api = _BytesTransport(throwing: true);
      await tester.pumpWidget(
        _host(
          const AudioCoverImage(
            key: Key('c'),
            identity: 'music_2',
            url: 'https://nas.example.com:5001/x',
          ),
          t: api,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(api.asked.length, 1);
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
    });

    testWidgets('DA86 服务端回空字节（404 的 HTML 之外的空响应）⇒ 回落图标', (tester) async {
      final api = _BytesTransport(bytes: Uint8List(0));
      await tester.pumpWidget(
        _host(
          const AudioCoverImage(
            key: Key('c'),
            identity: 'music_3',
            url: 'https://nas.example.com:5001/x',
          ),
          t: api,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
    });

    testWidgets('DA86 回来的是 HTML（200 却带正文）⇒ 判定非图、回落图标', (tester) async {
      final api = _BytesTransport(
        bytes: Uint8List.fromList(utf8.encode('<html><body>404</body></html>')),
      );
      await tester.pumpWidget(
        _host(
          const AudioCoverImage(identity: 'music_html', url: 'https://nas/x'),
          t: api,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
    });

    testWidgets('DA86 同一 URL 只取一次（会话级字节缓存，列表滚动不反复打 NAS）', (tester) async {
      final api = _BytesTransport(bytes: kPng1x1);
      const url = 'https://nas.example.com:5001/same';
      for (var i = 0; i < 3; i++) {
        await tester.pumpWidget(
          _host(
            const AudioCoverImage(identity: 'album_x', url: url),
            t: api,
          ),
        );
        await tester.pump();
        await tester.pump();
        // 卸载（= 列表滚出屏幕）：下一次是**全新 State**，只能靠字节缓存省请求
        await tester.pumpWidget(_host(const SizedBox.shrink(), t: api));
        await tester.pump();
      }
      expect(api.asked.length, 1, reason: '第 2/3 次必须命中缓存');
      expect(AuthedImageCache.hits, greaterThan(0));
      expect(AuthedImageCache.length, 1);
    });

    testWidgets('DA86 没有 url（未连接/无封面）⇒ 同步回落，一个请求都不发', (tester) async {
      final api = _BytesTransport(bytes: kPng1x1);
      await tester.pumpWidget(
        _host(
          const AudioCoverImage(identity: 'music_4', url: null),
          t: api,
        ),
      );
      await tester.pump();
      expect(api.asked, isEmpty);
      expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
    });

    testWidgets('DA86 未连接（api=null）⇒ 回落图标而不是抛异常', (tester) async {
      await tester.pumpWidget(
        _host(
          const AudioCoverImage(identity: 'music_5', url: 'https://x'),
          t: null,
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
    });
  });

  group('② 结构防回退：泄漏过的三个调用点', () {
    // 注释里允许出现 `Image.network`（讲"为什么不用"），只禁**代码行**。
    bool hasCodeUse(String path) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!line.contains('Image.network(')) continue;
        final code = line.split('//').first;
        if (code.contains('Image.network(')) {
          // ignore: avoid_print
          print('泄漏行 $path:${i + 1}: $line');
          return true;
        }
      }
      return false;
    }

    test('DA86 音频封面 / 标签行 / Drive 直链缩略图不许再用 Image.network', () {
      for (final path in const [
        'lib/src/features/audio/audio_cover.dart',
        'lib/src/features/audio/audio_song_page.dart',
        'lib/src/features/files/drive_browse_view.dart',
      ]) {
        expect(
          hasCodeUse(path),
          isFalse,
          reason: '$path 必须走 AuthedImage（DA86：主机名不匹配 ⇒ Image.network 恒失败）',
        );
      }
    });

    test('DA86 AuthedImage 不绑任何具体 API（取字节靠注入）且只出 Image.memory', () {
      final path = 'lib/src/features/media/authed_image.dart';
      expect(File(path).existsSync(), isTrue);
      final src = File(path).readAsStringSync();
      final imports = RegExp(r"^import '([^']+)';", multiLine: true)
          .allMatches(src)
          .map((m) => m.group(1)!)
          .toList();
      // 只许依赖 Flutter 本体 —— 一旦 import 某个 data/ API 就说明它开始绑具体
      // 通道（音频/Drive/笔记…各自不同），"一个实现"会退化成"一个特例"。
      expect(
        imports.where((i) => !i.startsWith('dart:') && !i.startsWith('package:flutter/')),
        isEmpty,
        reason: 'imports = $imports',
      );
      // 只看**代码行**（注释里必然要提 `Image.network` 才能讲清为什么不用它，
      // §2.0.48：纯文本守卫会把注释数进去）
      bool codeHas(String needle) => src
          .split('\n')
          .any((l) => l.split('//').first.contains(needle));
      expect(codeHas('Image.network'), isFalse);
      expect(codeHas('Image.memory'), isTrue);
    });
  });
}
