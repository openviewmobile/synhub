// r690 · Linux 站「视频画面」的两条守卫（`DA327` / `DA328`）。
//
// `DA327`：Linux 上 `hwdec` 用 media_kit 默认 `auto` ⇒ 无硬解环境里 mpv 报
//          `Could not open codec.` 并停播 ⇒ 被归因成「编码不支持」（假归因）。
//          改 `auto-safe`（失败自动回落软件解码）。
// `DA328`：纹理永远不来时界面无限转圈（黑屏时钟）⇒ 15 s 纹理看门狗 ＋
//          新归因 `videoOutputUnavailable`；并把 `VideoController` 改成按需创建
//          （纯音频/纯解码不建视频输出 —— 这也是 llvmpipe 下 `setVolume` 被卡死的根因）。
//
// 现场（容器 arm64 + Xvfb + llvmpipe）：libmpv 的解码与时间轴都在走
// （时长 4.000 s、位置 0 → 1.2 s），但 `media_kit` 的纹理永远不来
// （`VideoController.waitUntilFirstFrameRendered` 75 s 不返回）。
// 修法两层：
//   ① `MpvPlayerAdapter` 起一个 15 s 的纹理看门狗 ⇒ 落类型化失败；
//   ② 失败归因单列 `videoOutputUnavailable`（不许说成"文件解不了"）。
//
// 这条用例守的是**归因与文案**，真跑的那一半在
// `integration_test/r690_linux_playback_test.dart`（Linux 上跑）。
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_reason_text.dart';
import 'package:synhub/src/features/media/media_source.dart';

void main() {
  test('DA328 ① 类型化失败 ⇒ 归因到 videoOutputUnavailable（不是 decodeFailed）', () {
    expect(
      classifyPlayerError(const MediaPlaybackVideoOutputUnavailable()),
      MediaUnavailableReason.videoOutputUnavailable,
    );
    // 反向：平台没实现那条不能被抢走
    expect(
      classifyPlayerError(const MediaPlaybackUnsupportedOnHost()),
      MediaUnavailableReason.platformUnsupported,
    );
    // 反向：泛化文本仍落兜底
    expect(
      classifyPlayerError('something odd happened'),
      MediaUnavailableReason.decodeFailed,
    );
  });

  test('DA328 ② 文案点名图形栈，且复用既有标题 key（不新增 ARB）', () {
    final t = lookupAppTextSafe(const Locale('zh'));
    final text = mediaReasonText(
      t,
      MediaUnavailableReason.videoOutputUnavailable,
      MediaKind.video,
    );
    expect(text.title, t.chatErrPlaybackFailed);
    expect(text.detail, contains('图形栈'));
    // 枚举自带的 code / ARB key / 中文回落三件套都在
    const r = MediaUnavailableReason.videoOutputUnavailable;
    expect(r.code, 'video_output_unavailable');
    expect(r.arbKey, 'mediaErrNoVideoOutput');
    expect(r.zh, contains('图形栈'));
  });

  test('DA327/DA328 ③ 适配器：auto-safe ＋ 看门狗 ＋ 只在 Linux 生效', () {
    final src = File(
      'lib/src/features/media/mpv_player_adapter.dart',
    ).readAsStringSync();
    expect(src, contains('kVideoSurfaceTimeout'));
    expect(src, contains('_surfaceWatchdog'));
    expect(src, contains('MediaPlaybackVideoOutputUnavailable'));
    // 15 s 是个"有界但宽松"的值：改小会把慢机器误判，改大等于没看门狗
    expect(src, contains('Duration(seconds: 15)'));
    // 平台闸门：其它平台的纹理路径已真机验过，不许被误伤
    expect(src, contains('defaultTargetPlatform != TargetPlatform.linux'));
    // DA327：Linux 明确用 auto-safe，且不许退回 media_kit 默认的 auto
    expect(src, contains("hwdec: 'auto-safe'"));
    expect(src, isNot(contains("hwdec: 'auto'")));
    // 纹理到了要撤掉计时器（否则正常播放 15 s 后会被判失败）
    expect(src, contains('.id.addListener'));
    // ★ 只在**要画面时**武装（`vo=null` 的解码探针/纯音频页面没有纹理，
    //   挂在构造函数上必然误报 —— r690 真踩过）
    expect(src, contains('void _armSurfaceWatchdog()'));
    expect(src, contains('_armSurfaceWatchdog();'));
    final buildIdx = src.indexOf('Widget buildSurface(BuildContext context)');
    final armIdx = src.indexOf('_armSurfaceWatchdog();', buildIdx);
    expect(armIdx, greaterThan(buildIdx), reason: '武装必须发生在 buildSurface 内');
  });
}
