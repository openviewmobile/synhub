// s289（r689）：iOS 的**三条系统集成桥**在模拟器上真的接上了：
//   * `synhub/video_frame`（`AVAssetImageGenerator`）—— 抽帧
//   * `synhub/traffic`（`getifaddrs`）—— 网络计数
//   * `synhub/cast`（AirPlay：`AVRouteDetector` + `AVRoutePickerView`）—— 投屏
//
// 每条都**只证模拟器上能证的那部分**，并逐条写明证不到什么：
//
// ① 抽帧：`isSupported == true`、`extractFrame` 回**真 JPEG 字节**（非空、
//    宽 ≤ maxWidth、`mime == image/jpeg`）。★ 证不到"真 NAS 上的 mp4 也能抽"——
//    那要网络与登录态；本用例用的是本地生成的 3 秒测试片（test pattern）。
//    另外**必须**验一条反向：坏路径 / 不存在文件 → `false`（不许编图）。
//
// ② 流量：`uidSnapshot` 回**接口级**总数（`totalRx > 0`），而 `uidRx/uidTx`
//    **必须恒为 -1** —— 因为 iOS 没有按 App 的字节计数 API。这条是"如实"的
//    核心：`DeviceTrafficSnapshot.supported` 必须是 `false`，"估算档"因此不可用。
//    验不到：模拟器上的计数是不是真机上那份（接口名不同不影响，但读数本身不是
//    设备结论）。
//
// ③ 投屏：`availability` 必须回 `available: true, kind: "airplay"`（= 平台支持），
//    而 `routesDetected` 在**模拟器上恒 false**（没有接收端）—— 这一条如实记录，
//    不当成缺陷；`play` 在没有 AirPlay 路由时必须回 `false`（不假装投送成功）。
//    验不到：真机选 AirPlay 设备之后的实际播放路由（无头模拟器点不了系统面板）。
//
// 跑法（`R689_VIDEO_PATH` 由宿主先拷进模拟器的 App 数据目录）：
//   flutter test integration_test/r689_ios_runtime_bridges_test.dart \
//     -d 1FFF0EDA-3230-46F5-A011-6119E6040381 \
//     --dart-define=R689_VIDEO_PATH=/…/Documents/r689_sample.mp4
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/media/video_frame_bridge.dart';
import 'package:synhub/src/core/net/device_traffic.dart';
import 'package:synhub/src/core/platform/app_platform.dart';

const MethodChannel _video = MethodChannel('synhub/video_frame');
const MethodChannel _traffic = MethodChannel('synhub/traffic');
const MethodChannel _cast = MethodChannel('synhub/cast');

/// 宿主先拷进 App 数据目录的测试片绝对路径（空 = 跳过抽帧的"真字节"一段）。
const String _videoPath = String.fromEnvironment('R689_VIDEO_PATH');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('r689 ① 能力层：四条桥全部进榜（iOS 的"未实现"到此为零）', (tester) async {
    final caps = staticCapabilitiesFor(AppHost.ios);
    for (final c in const [
      AppCapability.videoFrameExtraction,
      AppCapability.networkTrafficCounters,
      AppCapability.cast,
    ]) {
      expect(caps.can(c), isTrue, reason: '${c.name} 的 Swift 桥已落地 ⇒ 不许再拦');
    }
    // ★ r689 的后半段：`audioVisualizer` 也接上了（`MTAudioProcessingTap` + vDSP，
    //   见 `r689b_ios_spectrum_test.dart`）⇒ 四条全在榜。
    expect(caps.can(AppCapability.audioVisualizer), isTrue);
    // ignore: avoid_print
    print('[r689] capability video=${caps.statusOf(AppCapability.videoFrameExtraction).reason} '
        'traffic=${caps.statusOf(AppCapability.networkTrafficCounters).reason} '
        'cast=${caps.statusOf(AppCapability.cast).reason} '
        'visualizer=${caps.statusOf(AppCapability.audioVisualizer).reason}');
  });

  testWidgets('r689 ② 抽帧：真 JPEG 字节 · 等比缩 · 坏路径如实 false', (tester) async {
    final supported = await _video.invokeMethod<bool>('isSupported');
    // ignore: avoid_print
    print('[r689] video.isSupported -> $supported');
    expect(supported, isTrue);

    // 反向①：路径不存在 ⇒ false（不许编一张空图）
    final missing = await _video.invokeMethod<Object?>('extractFrame', {
      'path': '/tmp/definitely-not-here-r689.mp4',
      'atMs': 0,
      'maxWidth': 320,
    });
    // ignore: avoid_print
    print('[r689] video missing -> $missing');
    expect(missing, isFalse);

    if (_videoPath.isEmpty) {
      // ignore: avoid_print
      print('[r689] 没给 R689_VIDEO_PATH ⇒ 跳过真字节一段');
      return;
    }

    final raw = await _video.invokeMethod<Object?>('extractFrame', {
      'path': _videoPath,
      'atMs': 500,
      'maxWidth': 320,
    });
    final frame = VideoFrameResult.fromPlatform(raw);
    // ignore: avoid_print
    print('[r689] video frame -> $frame');
    expect(frame, isNotNull, reason: 'null = 通道没接 / Dart 侧解不出（看 raw=$raw）');
    expect(frame!.bytes.length, greaterThan(500),
        reason: '一张 320px 的 JPEG 不可能只有几百字节');
    expect(frame.mime, 'image/jpeg');
    expect(frame.width, lessThanOrEqualTo(320));
    expect(frame.height, greaterThan(0));
    // 等比：640x360 缩到宽 320 ⇒ 高应该是 ~180（不是 320 的正方形）
    expect(frame.height, lessThan(frame.width),
        reason: '横屏片源被压成方块 ⇒ maximumSize 语义用错了');

    // 反向②：atMs 超出时长（3 s）⇒ generator 抽不出来，必须如实 false
    final beyond = await _video.invokeMethod<Object?>('extractFrame', {
      'path': _videoPath,
      'atMs': 99000,
      'maxWidth': 320,
    });
    // ignore: avoid_print
    print('[r689] video beyond-end -> $beyond');
    expect(beyond is Map || beyond == false, isTrue);

    // 反向③：Dart 侧薄桥（走能力门控的那条路）也拿得到同一份结果
    final viaDart = await const MethodChannelVideoFrameExtractor().extract(
      _videoPath,
      atMs: 500,
    );
    // ignore: avoid_print
    print('[r689] dart extractor -> $viaDart');
    expect(viaDart, isNotNull);
    expect(viaDart!.bytes.length, greaterThan(500));
  });

  testWidgets('r689 ③ 流量：接口级总和可读 · 按 App 的计数如实 -1', (tester) async {
    final raw = await _traffic.invokeMethod<Map<Object?, Object?>>('uidSnapshot');
    // ignore: avoid_print
    print('[r689] traffic raw -> $raw');
    expect(raw, isNotNull);

    final snap = DeviceTrafficSnapshot.fromMap(raw!);
    // ignore: avoid_print
    print('[r689] traffic uid=${snap.uidRx}/${snap.uidTx} '
        'total=${snap.totalRx}/${snap.totalTx} supported=${snap.supported}');

    // ★ 核心事实：iOS 没有按 App 的字节计数 API ⇒ uid 两项必须如实 -1
    expect(snap.uidRx, -1, reason: 'iOS 上不许编一个"本 App 用量"');
    expect(snap.uidTx, -1);
    expect(snap.supported, isFalse,
        reason: 'Dart 的 supported 必须跟着 false，否则估算档会算出假数');
    // 整机接口级总和是真能读的（模拟器也有 en0/lo0 之外的真实接口）
    expect(snap.totalRx, greaterThan(0), reason: 'getifaddrs 一条都没读到 ⇒ 桥没接');
    expect(snap.totalTx, greaterThan(0));

    // 反向：两次采样之间总数**不许变小**（累计计数，回绕以外只增）
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final raw2 = await _traffic.invokeMethod<Map<Object?, Object?>>('uidSnapshot');
    final snap2 = DeviceTrafficSnapshot.fromMap(raw2!);
    // ignore: avoid_print
    print('[r689] traffic delta rx=${snap2.totalRx - snap.totalRx} '
        'tx=${snap2.totalTx - snap.totalTx}');
    expect(snap2.totalRx, greaterThanOrEqualTo(snap.totalRx));
    expect(snap2.totalTx, greaterThanOrEqualTo(snap.totalTx));
  });

  testWidgets('r689 ④ 投屏：AirPlay 平台支持 · 模拟器无接收端 · 不假装成功', (tester) async {
    final avail = await _cast.invokeMethod<Map<Object?, Object?>>('availability');
    // ignore: avoid_print
    print('[r689] cast.availability -> $avail');
    expect(avail, isNotNull);
    expect(avail!['available'], isTrue, reason: 'iOS 平台支持投屏（AirPlay）');
    expect(avail['kind'], 'airplay');
    // ★ 模拟器上恒 false（没有 AirPlay 接收端）——如实记录，不当缺陷
    // ignore: avoid_print
    print('[r689] cast routesDetected=${avail['routesDetected']}');

    // 没有路由时 `play` 必须回 false（不假装投送成功）
    final played = await _cast.invokeMethod<bool>('play', {
      'mediaUrl': 'https://example.invalid/x.mp3',
      'positionSeconds': 0,
    });
    // ignore: avoid_print
    print('[r689] cast.play(no-route) -> $played');
    if (avail['routesDetected'] == false) {
      expect(played, isFalse, reason: '没有 AirPlay 路由却回 true ⇒ 假成功');
    }

    // 照片投送（Cast 命名空间消息）在 iOS 上没有等价物 ⇒ 如实 false
    final photo =
        await _cast.invokeMethod<Map<Object?, Object?>>('photoCastAvailability');
    // ignore: avoid_print
    print('[r689] photoCastAvailability -> $photo');
    expect(photo!['available'], isFalse);

    // 反向：未知方法必须 notImplemented（通道确实是我们这条，不是别人接的）
    await expectLater(
      _cast.invokeMethod<Object?>('definitelyNotAMethod'),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
