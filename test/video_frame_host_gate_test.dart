// 视频首帧：**宿主结构上抽不了帧**时的门控回归（第 132 轮 iOS 逐屏走查 / 缺陷 D4）。
//
// 背景（真机日志逐字，不是推测）：iOS App 里相册每个视频格都走完整抽帧流水线 ——
//   真下 6 MiB 头片段、写临时文件、再交给 no-op 的原生抽帧桥 ⇒ 最后记一条
//     `[photoVideoThumb] FAIL key=vframe|photos:personal:9659|1749238389|1876693
//      ext=mp4 size=1876693 range=true reason=extract-failed stage=unknown
//      container=iso-bmff`
//   界面还挂"提取失败"角标（负面缓存 TTL 内不再重试）。
// 根因：`AppCapability.videoFrameExtraction` 在 iOS/macOS/Linux/Windows 上是
//   `unavailable:not-implemented-on-host`，但两个 provider 照旧**无条件**接上
//   完整流水线 ⇒ "这台机器做不了"被说成"这个文件抽不出帧"（AGENTS §2.0.6②/③）。
//
// 本文件锁定修好后的口径：
//   ① 宿主静态结论不放行（非 Android）；
//   ② 生产容器（无 override）取图 = null，**且不算失败**（stats.failures=0、
//      不写失败记忆、不写失败原因），**且一个字节都不下**（headFetcher 零调用）；
//   ③ 反向验证：把"宿主能做"这一关打开（等价于 Android 的静态 `unknown` 放行）
//      ⇒ 流水线**真的**跑起来（headFetcher 被调用过、失败原因有分层）——
//      证明②的红不是"门把一切都挡死了"。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/media/video_frame_thumb.dart';

void main() {
  // 与 iOS 像素里那条失败同形（真机 `photos:personal:9659`，mp4、1.87 MB、
  // 支持 Range ⇒ `videoFrameDownloadPlan` 会规划一个 6 MiB 量级的头片段）。
  final request = VideoFrameThumbRequest.forPath(
    path: '/home/Photos/clip.mp4',
    uri: 'https://nas.example:5001/webapi/entry.cgi?path=%2Fhome%2FPhotos%2Fclip.mp4',
    extension: 'mp4',
    size: 1876693,
    mtime: 1749238389,
  );

  setUp(() => debugForceVideoFrameExtractionPossible = false);
  tearDown(() => debugForceVideoFrameExtractionPossible = false);

  test('① 宿主静态结论：非 Android 宿主抽不了帧 ⇒ 门不放行', () {
    // 前提：测试宿主是 macOS/桌面 ⇒ `unavailable:not-implemented-on-host`。
    // 这条也是**反向前提**：若哪天在 Android 设备上跑本用例，它会当场变红。
    expect(videoFrameExtractionPossibleOnThisHost(), isFalse);
  });

  test('② 生产容器（无 override）：null，且不记失败、不下任何字节', () async {
    var headCalls = 0;
    final container = ProviderContainer(
      overrides: [
        videoFrameHeadFetcherProvider.overrideWithValue((
          r, {
          required int maxBytes,
        }) async {
          headCalls++;
          return Uint8List(1024);
        }),
      ],
    );
    addTearDown(container.dispose);

    final cache = container.read(videoFrameThumbCacheProvider);
    final bytes = await cache.get(request);

    expect(bytes, isNull);
    // ★ 修复前：failures=1、isRememberedFailure=true、failureFor 非空、headCalls=1
    //   （真机那行 `reason=extract-failed` 就是这么来的）。
    expect(cache.stats.failures, 0);
    expect(cache.failuresRemembered, 0);
    expect(cache.isRememberedFailure(request.cacheKey), isFalse);
    expect(cache.failureFor(request.cacheKey), isNull);
    // ★ "抽不了帧"就不该下 6 MiB 头片段（真机上是真下了）。
    expect(headCalls, 0, reason: '宿主没有抽帧能力时不许下载头片段');
  });

  test('③ 反向验证：门打开后（等价 Android）流水线真会跑，失败带分层', () async {
    debugForceVideoFrameExtractionPossible = true;
    var headCalls = 0;
    final container = ProviderContainer(
      overrides: [
        videoFrameHeadFetcherProvider.overrideWithValue((
          r, {
          required int maxBytes,
        }) async {
          headCalls++;
          return Uint8List(0); // 空头 ⇒ 在"下头部"这一段就失败
        }),
        videoFrameTempDirectoryProvider.overrideWithValue(
          () async => Directory.systemTemp,
        ),
      ],
    );
    addTearDown(container.dispose);

    final outcome = await container.read(
      videoFrameDetailedLoaderProvider,
    )(request);

    expect(headCalls, greaterThan(0), reason: '门放行时才会真的去下头部');
    expect(outcome.bytes, isNull);
    expect(outcome.failure, isNotNull);
    expect(outcome.platformUnavailable, isFalse);
  });
}
