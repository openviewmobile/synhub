// r679 · iOS 模拟器「格式矩阵 + 音频输出真相」验收（宿主本机 HTTP 样本）
//
// 为什么能在模拟器上验：
//   * 样本用 ffmpeg 现造（HEVC / 双音轨 mkv(AAC+AC3) / .ts / .mov），
//     由宿主 `python3 /tmp/r679_media/serve.py` 在 **回环**上提供（支持 Range）；
//   * iOS 模拟器与宿主**共用网络栈** ⇒ 模拟器里的 `127.0.0.1` 就是这台 Mac；
//   * 于是「换个容器/编码还播不播」这件事**不需要真机、也不需要往 NAS 写文件**。
//
// 断言口径（与 r678 同一套，防"黑屏时钟"假绿）：
//   ① 必须有 `media-video-surface`；② 进度必须**前进 ≥500ms/3s**；
//   ③ 视觉引擎身份用 `media-engine-mpv` key 判（在 = libmpv 出画；不在 = 原生 AVFoundation）；
//   ④ 每场景留**两张相隔 3s** 的设备像素（宿主截图握手，与 r132/r674 同一套协议）。
//
// 跑法：
//   (cd /tmp/r679_media && python3 serve.py 8791 &)
//   tool/r132_ios_shot_poller.sh com.openviewai.synhub.ios /tmp/r679_shots &
//   flutter test integration_test/r679_ios_media_matrix_test.dart -d <sim-id> \
//     --dart-define=AUDIT_SCENES=s250,s251,s252,s253
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:record/record.dart';
import 'package:synhub/src/features/media/mpv_player_adapter.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/core/net/media_tls_policy.dart';
import 'package:synhub/src/features/media/media_source.dart';

const String _base = String.fromEnvironment(
  'MEDIA_BASE',
  defaultValue: 'http://127.0.0.1:8791',
);
const String _onlyScenes = String.fromEnvironment('AUDIT_SCENES');

bool _want(String name) =>
    _onlyScenes.isEmpty ||
    _onlyScenes.split(',').map((e) => e.trim()).any(name.startsWith);

final Directory _syncDir = Directory('${Directory.systemTemp.path}/r132_ios_ui')
  ..createSync(recursive: true);
File get _req => File('${_syncDir.path}/req.txt');
File get _ack => File('${_syncDir.path}/ack.txt');

final List<String> _report = <String>[];
void _note(String s) {
  _report.add(s);
  debugPrint('[ios679] $s');
}

Future<void> _wait(WidgetTester tester, [int ms = 500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 32));
    await Future<void>.delayed(const Duration(milliseconds: 32));
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  String label,
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    await tester.pump(const Duration(milliseconds: 64));
    await Future<void>.delayed(const Duration(milliseconds: 64));
  }
  throw StateError('等待超时：$label');
}

Future<bool> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  if (f.evaluate().isEmpty) return false;
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, 700);
  return true;
}

Future<void> _mark(WidgetTester tester, String name) async {
  try {
    if (_ack.existsSync()) _ack.deleteSync();
  } catch (_) {}
  try {
    _req.writeAsStringSync(name, flush: true);
  } catch (e) {
    _note('MARK-WRITE-FAIL $name: $e');
    return;
  }
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    try {
      if (_ack.existsSync() && _ack.readAsStringSync().trim() == name) {
        _note('MARK $name');
        return;
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  _note('MARK-TIMEOUT $name');
}

/// 打开一个**本机回环**上的样本（走真实工厂：iOS = Fallback(Native, mpv)）。
///
/// ★ 必须**不传** `adapter`：`_ownsAdapter = widget.adapter == null`，只有自己造的
///   才会调 `_bootstrap()` 去 `load()`；借来的按"已经在播"处理，**一次请求都不发**
///   （本轮第一次跑就踩到：四个场景全"等待超时出画"，服务器日志只有一条 GET）。
Future<void> _open(
  WidgetTester tester,
  String file, {
  bool audio = false,
  String? url,
}) async {
  // 每个场景一个**独立的 State**（key 含文件名）：否则 pumpWidget 会复用上一场景的
  // State，换 source 不一定重载，导致后面几场一个请求都不发（本轮实测踩到）。
  await tester.pumpWidget(const SizedBox.shrink());
  await _wait(tester, 200);
  final src = MediaSource(
    uri: url ?? '$_base/$file',
    channel: MediaChannel.other,
    kind: audio ? MediaKind.audio : MediaKind.video,
    displayName: file,
    supportsRange: true,
  );
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: MediaPlayerView(
            key: Key('r679-player-$file'),
            source: src,
            showFullscreenButton: false,
          ),
        ),
      ),
    ),
  );
  await _wait(tester, 800);
}

int _progressMs(WidgetTester tester) {
  final f = find.byKey(const Key('media-progress'));
  if (f.evaluate().isEmpty) return -1;
  return tester.widget<Slider>(f.first).value.round();
}

Future<void> _revealControls(WidgetTester tester) async {
  final surface = find.byKey(const Key('media-video-surface'));
  for (var i = 0; i < 6 && _progressMs(tester) < 0; i++) {
    if (surface.evaluate().isEmpty) {
      await _wait(tester, 500);
      continue;
    }
    await tester.tap(surface.first, warnIfMissed: false);
    await _wait(tester, 400);
  }
}

/// 「真的在播」：3 秒内进度前进 ≥500ms。
Future<int> _assertReallyPlaying(WidgetTester tester, String label) async {
  await _revealControls(tester);
  final a = _progressMs(tester);
  if (a < 0) throw StateError('$label 读不到进度（控件条点不出来）');
  await _wait(tester, 3000);
  final b = _progressMs(tester);
  final delta = b - a;
  _note('$label posMs: $a -> $b (delta=${delta}ms)');
  if (delta < 500) {
    throw StateError('$label 进度没前进（$a -> $b，delta=${delta}ms）');
  }
  return b;
}

/// 一个格式场景：出画 + 引擎身份 + 前后两张像素。
Future<void> _scene(
  WidgetTester tester, {
  required String scene,
  required String file,
  required bool expectMpv,
  bool twoAudioTracks = false,
  bool audio = false,
}) async {
  _note('=== $scene · $file (expectMpv=$expectMpv) ===');
  await _open(tester, file, audio: audio);
  await _waitFor(
    tester,
    '$scene 出画',
    () => find.byKey(const Key('media-video-surface')).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 60),
  );
  await _assertReallyPlaying(tester, scene);

  final mpv = find.byKey(const Key('media-engine-mpv')).evaluate().isNotEmpty;
  final panel =
      find.byKey(const Key('media-fallback-panel')).evaluate().isNotEmpty;
  _note('$scene engine=${mpv ? "mpv" : "native"} fallbackPanel=$panel');
  expect(panel, isFalse, reason: '$scene 不该落回回退面板');
  expect(mpv, expectMpv, reason: '$scene 引擎身份不符（mpv=$mpv 期望 $expectMpv）');

  if (twoAudioTracks) {
    // ★ 音轨菜单在「播放设置」弹层里（`media-settings` → `media-settings-sheet`
    //   → 行 `audio` 的 `media-audio-track`），**不在**控制条上 —— 直接找控制条
    //   会得到"没有音轨菜单"的假红（本轮第二次跑就踩到）。
    await _revealControls(tester);
    final settings = find.byKey(const Key('media-settings'));
    expect(settings.evaluate().isNotEmpty, isTrue, reason: '$scene 没有「播放设置」入口');
    await tester.tap(settings.first, warnIfMissed: false);
    await _wait(tester, 700);
    expect(
      find.byKey(const Key('media-settings-sheet')).evaluate().isNotEmpty,
      isTrue,
      reason: '$scene 播放设置弹层没打开',
    );
    final menu = find.byKey(const Key('media-audio-track'));
    expect(menu.evaluate().isNotEmpty, isTrue, reason: '$scene 没有音轨菜单');
    await tester.tap(menu.first, warnIfMissed: true);
    await _wait(tester, 800);
    await _mark(tester, '${scene}_audio_menu');
    // 弹层在 Overlay 里 ⇒ 一定要 `skipOffstage: false`，否则数到 0（本轮假红）。
    final items = find
        .byType(PopupMenuItem<String>, skipOffstage: false)
        .evaluate()
        .length;
    final checked = find
        .byType(CheckedPopupMenuItem<String>, skipOffstage: false)
        .evaluate()
        .length;
    _note('$scene popupItems=$items checked=$checked');
    // ★ `find.byType` 是**精确 runtimeType**（r132 的老坑）：条目是
    //   `CheckedPopupMenuItem`（`PopupMenuItem` 的子类）⇒ 数 `PopupMenuItem` 得 0。
    expect(checked, greaterThanOrEqualTo(2), reason: '$scene 应看到 ≥2 条音轨（mpv 多轨）');

    // 切到第 2 条：行值应当跟着变（这才是"多音轨真的能用"，不是只摆两条文字）。
    String rowValue() {
      final row = find.byKey(const Key('media-settings-row-audio'));
      if (row.evaluate().isEmpty) return '';
      final texts = find
          .descendant(of: row.first, matching: find.byType(Text))
          .evaluate()
          .map((e) => (e.widget as Text).data ?? '')
          .where((t) => t.isNotEmpty)
          .toList();
      return texts.isEmpty ? '' : texts.last;
    }

    final before = rowValue();
    final items2 = find.byType(CheckedPopupMenuItem<String>, skipOffstage: false);
    await tester.tap(items2.at(1), warnIfMissed: false);
    await _wait(tester, 900);
    await _revealControls(tester);
    await _tapKey(tester, 'media-settings');
    final after = rowValue();
    _note('$scene audioTrackRowValue "$before" -> "$after"');
    expect(after.isNotEmpty && after != before, isTrue,
        reason: '$scene 切到第 2 条音轨后行值没变（"$before" -> "$after"）');
    await tester.tapAt(const Offset(20, 40)); // 关掉设置弹层（点遮罩）
    await _wait(tester, 500);
  }

  await _mark(tester, '${scene}_a');
  await _wait(tester, 3000);
  await _revealControls(tester);
  await _mark(tester, '${scene}_b');
  _note('$scene OK');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    MediaKit.ensureInitialized();
  });

  group('r679 · iOS 模拟器格式矩阵', () {
    testWidgets('s250 HEVC(hevc1) in mp4', (tester) async {
      if (!_want('s250')) return;
      await _scene(tester, scene: 's250_hevc_mp4', file: 'hevc.mp4', expectMpv: false);
    });

    testWidgets('s251 mkv · 双音轨 AAC+AC3', (tester) async {
      if (!_want('s251')) return;
      await _scene(
        tester,
        scene: 's251_mkv_two_audio',
        file: 'mkv_two_audio.mkv',
        expectMpv: true,
        twoAudioTracks: true,
      );
    });

    testWidgets('s252 MPEG-TS h264+aac', (tester) async {
      if (!_want('s252')) return;
      await _scene(tester, scene: 's252_ts', file: 'h264_aac.ts', expectMpv: true);
    });

    testWidgets('s253 QuickTime .mov h264+aac', (tester) async {
      if (!_want('s253')) return;
      await _scene(tester, scene: 's253_mov', file: 'h264.mov', expectMpv: false);
    });

    // s254 · 「证书链合法、仅主机名不匹配」这条支（`platform-ios.md` §5 第 3 项）。
    //
    // 装置：宿主自建 CA（已 `simctl keychain add-root-cert` 装进模拟器信任库）
    // 给 `CN=nas.example.com` 签一张服务器证书，却在 `127.0.0.1:9443` 上提供
    // —— 于是**链合法、主机名不匹配**，与真 NAS 自签证书那条一模一样的错。
    // 判据：① 不装政策 ⇒ 播不了（这是 Android r259 那个缺陷的同构现象）；
    //       ② `MediaTlsPolicy.install` 之后 ⇒ **真出画 + 进度前进**。
    testWidgets('s254 TLS: 链合法/主机名不匹配（装政策前后对照）', (tester) async {
      if (!_want('s254')) return;
      const url = 'https://127.0.0.1:9443/h264.mov';
      _note('=== s254_tls_hostname_mismatch · $url ===');

      // ① 对照：**不装**政策
      MediaTlsPolicy.resetForTest();
      await _open(tester, 'h264.mov', url: url);
      var played = false;
      try {
        await _waitFor(
          tester,
          's254 对照组出画',
          () => find.byKey(const Key('media-video-surface')).evaluate().isNotEmpty,
          timeout: const Duration(seconds: 25),
        );
        await _revealControls(tester);
        played = _progressMs(tester) >= 0;
      } on StateError {
        played = false;
      }
      _note('s254 control(no policy) played=$played');
      expect(played, isFalse, reason: 's254 没装政策就播了 ⇒ 对照失效（判据要重想）');

      // ② 装政策后
      await MediaTlsPolicy.install(baseUrl: 'https://127.0.0.1:9443');
      _note('s254 policy installed=${MediaTlsPolicy.isInstalledFor(url)}');
      await _open(tester, 'h264.mov', url: url);
      await _waitFor(
        tester,
        's254 装政策后出画',
        () => find.byKey(const Key('media-video-surface')).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 40),
      );
      await _assertReallyPlaying(tester, 's254_tls');
      final panel =
          find.byKey(const Key('media-fallback-panel')).evaluate().isNotEmpty;
      expect(panel, isFalse, reason: 's254 装政策后不该落回退面板');
      await _mark(tester, 's254_tls_hostname_mismatch_a');
      await _wait(tester, 3000);
      await _revealControls(tester);
      await _mark(tester, 's254_tls_hostname_mismatch_b');
      _note('s254 OK');
    });

    // （原本这里有个 s255「读 libmpv 音频属性」的探针，已删：没有 `vo` 时
    //   `open()` 不返回、`aid=auto`、`positionMs=0` ⇒ 它量到的是"没起播"，
    //   不是"没有音频设备"。模拟器上"音频输出打不开"的证据改为取**真实播放**
    //   的 mpv 警告行 `Could not open/initialize audio device -> no sound.`，
    //   见 §17.4。）
    // s257 · 麦克风权限弹窗（`platform-ios.md` §5 第 4 项的一半）。
    //
    // 为什么这条**能**在模拟器上验：mic 是"模拟器也会真弹"的系统权限
    // （相机不行 —— 模拟器没有摄像头硬件，所以那一半只能真机）。
    // 装置：`AudioRecorder().hasPermission()` 会触发系统授权框；
    // 用例只负责"把它叫出来"，像素由宿主截图泵取（弹窗是系统画的，不在 Flutter 树里）。
    testWidgets('s257 麦克风权限弹窗', (tester) async {
      if (!_want('s257')) return;
      final rec = AudioRecorder();
      bool? granted;
      unawaited(
        rec.hasPermission().then((v) => granted = v).catchError((Object e) {
          _note('s257 hasPermission 异常：$e');
          return false;
        }),
      );
      await _wait(tester, 4000);
      await _mark(tester, 's257_mic_permission_prompt');
      await _wait(tester, 3000);
      _note('s257 granted=$granted（null = 还在等用户点，这正是"弹窗在等"）');
      await rec.dispose();
    });

    // s258 · 授权之后这条路真的通（与 s257 成对：弹窗 → 允许 ⇒ granted=true）。
    // 装置：先由宿主 `xcrun simctl privacy booted grant microphone <bundle>`，
    // 再跑本场景；`granted=true` 就是"权限层接上了"的可断言读数。
    testWidgets('s258 麦克风授权后 hasPermission', (tester) async {
      if (!_want('s258')) return;
      final rec = AudioRecorder();
      try {
        final granted = await rec.hasPermission();
        _note('s258 granted=$granted');
        expect(granted, isTrue, reason: 's258 授权后仍拿不到麦克风');
        await _mark(tester, 's258_mic_granted');
      } finally {
        await rec.dispose();
      }
    });

    // s256 · 「切音轨之后轨道表还在吗」—— 纯适配器层，不经 UI。
    //
    // 为什么会怀疑它：s251 里弹层明明列出 2 条（`checked=2`），可行值读数是
    // `没有可选项`（= `audioTracks.isEmpty`）。先量清楚是**适配器丢了表**，
    // 还是我这套仪器读错了行。
    testWidgets('s256 切音轨前后 audioTracks 的数量', (tester) async {
      if (!_want('s256')) return;
      final adapter = MpvPlayerAdapter();
      try {
        // ★ 不许 `await`：没有 `vo`（纹理）时 libmpv 的 `open()` 不返回
        //   （r678 的老账：无 `vo` 只解容器不解码）⇒ 这里只发不等。
        unawaited(adapter.load(const MediaSource(
          uri: '$_base/mkv_two_audio.mkv',
          channel: MediaChannel.other,
          kind: MediaKind.audio,
          displayName: 'mkv_two_audio.mkv',
          supportsRange: true,
        )));
        await _wait(tester, 6000);
        _note('s256 before n=${adapter.audioTracks.length} '
            'ids=${adapter.audioTracks.map((e) => e.id).toList()} '
            'selected=${adapter.selectedAudioTrackId}');
        final second =
            adapter.audioTracks.length >= 2 ? adapter.audioTracks[1].id : null;
        if (second != null) {
          await adapter.selectAudioTrack(second);
          await _wait(tester, 2500);
        }
        _note('s256 after n=${adapter.audioTracks.length} '
            'ids=${adapter.audioTracks.map((e) => e.id).toList()} '
            'selected=${adapter.selectedAudioTrackId}');
        expect(adapter.audioTracks.length, greaterThanOrEqualTo(2),
            reason: 's256 切音轨之后轨道表掉了（这就是行值变「没有可选项」的根因）');
      } finally {
        await adapter.dispose();
      }
    });

 });

  tearDownAll(() {
    _note('SUMMARY');
    for (final l in _report) {
      if (l.startsWith('MARK')) continue;
      debugPrint('[ios679-summary] $l');
    }
  });
}
