// ★ r678（`DA311`）：libmpv 的**环境性警告**不许当成"这个文件播不了"。
//
// 现场（iOS 模拟器 · `.mkv`）：兜底引擎已经把画面解出来了
// （`ready=true`、`aspectRatio=1.778`），但 mpv 同时报
// `Could not open/initialize audio device -> no sound.`（模拟器没有音频设备）。
// 原来我们把 `stream.error` 里**任何**串都当致命 ⇒ 页面判 `decode_failed`
// ⇒ 用户看到"播放失败"，而事实是"能看，没声音"。
//
// 反向验证：把 `isMpvNonFatalError` 改回恒 `false` ⇒ 第一条红。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/media/mpv_player_adapter.dart'
    show isMpvNonFatalError;

void main() {
  test('DA311 没有音频设备 = 环境性警告（不致命）', () {
    expect(
      isMpvNonFatalError('Could not open/initialize audio device -> no sound.'),
      isTrue,
    );
    expect(isMpvNonFatalError('ao_coreaudio: Cannot init audio'), isTrue);
    expect(isMpvNonFatalError('Audio device is busy'), isTrue);
  });

  test('DA311 反向：真正的解码/容器错误照旧致命（不许被吞掉）', () {
    expect(isMpvNonFatalError('Failed to open /video/x.mkv'), isFalse);
    expect(isMpvNonFatalError('Could not open codec.'), isFalse);
    expect(isMpvNonFatalError('errors parsing option tls-verify'), isFalse);
    expect(isMpvNonFatalError(''), isFalse);
  });
}
