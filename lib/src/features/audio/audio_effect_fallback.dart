// ★ r413（DA72）：**可选依赖（音频效果链）不许把主功能带死**。
//
// ## 真机现场（r413，HONOR LGE-AN10 / Android 12）
//
// 点播放后：界面与通知栏都进入"正在播放"，却**一点声音都没有**、
// 进度永远 `0:00`。logcat 逐字：
//
// ```
// [audio-station] play-start song=music_28045 mode=direct transcode=false as-url-auth ok
// [audio-station] play-failure song=music_28045 reason=decodeFailed
//   error=PlatformException(Error: java.lang.NullPointerException: Attempt to invoke
//   virtual method 'short android.media.audiofx.Equalizer.getNumberOfBands()'
//   on a null object reference, …)
// ```
//
// ## 根因（读 `just_audio` 0.10.6 源码，两处逐字对上）
//
// * `lib/just_audio.dart` 的 `_setPlatformActive()`：**先**逐个
//   `await audioEffect._activate(platform)`，**后**才 `await _load(...)`
//   ⇒ 效果激活失败会把整次 `load()` 带塌（我们的 `playQueue` 抛 ⇒ 页面判
//   `decodeFailed`）；
// * `AndroidEqualizer._activate()` 会向平台要频段参数
//   （`androidEqualizerGetParameters`），而 Java 侧
//   （`AudioPlayer.java:831`）是
//   `Equalizer equalizer = (Equalizer)audioEffectsMap.get("AndroidEqualizer");
//    for (short i = 0; i < equalizer.getNumberOfBands(); i++)`
//   —— `audioEffectsMap` 要等 `onAudioSessionIdChanged`（`setAudioSessionId`）
//   才填。播放器**首次接上平台**时这一次是空的 ⇒ 拿到 `null` ⇒ NPE。
//
// 结论：这是"可选增强（均衡器）与主链路（起播）耦合"导致的**主功能级**故障，
// 而且**每次都犯**（失败后平台被拆，下次接上还是同一顺序）。
//
// ## 口径
//
// 效果链建不起来 ⇒ **降级为"无均衡器模式"并照常出声**，同时在均衡器界面上
// 如实显示"本机不可用"（既有 `available=false` 通路，不假装成功）。
// 判据只认**音频效果**这一族错误：鉴权 / 解码 / 网络等错误**不许**触发降级，
// 否则会把真错误掩盖成"均衡器不可用"。
library;

/// 音频效果族的错误指纹（`just_audio` 的 Java 侧 + Android framework 的方法名）。
///
/// 只放**不会误伤**的串：`android.media.audiofx` 是框架包名，
/// `AndroidEqualizer` 是 `just_audio` 的效果类型名，`getNumberOfBands`
/// 是 `equalizerAudioEffectGetParameters()` 里唯一会打到空引用的方法。
const List<String> kAudioEffectErrorSignatures = <String>[
  'android.media.audiofx',
  'AndroidEqualizer',
  'getNumberOfBands',
];

/// `error` 是不是"音频效果链建不起来"这一族。
///
/// 判据取**整个错误的 `toString()`**（`PlatformException` 的 `code` 与
/// `message` 都在里面）—— 不依赖 `PlatformException` 类型，纯字符串判据，
/// 这样本函数可以离线用例直接覆盖（含"别的错误不许命中"的反向用例）。
bool isAudioEffectFailure(Object? error) {
  if (error == null) return false;
  final text = error.toString();
  if (text.isEmpty) return false;
  for (final signature in kAudioEffectErrorSignatures) {
    if (text.contains(signature)) return true;
  }
  return false;
}

/// 起播失败后要不要"摘掉均衡器再试一次"。
///
/// * 只对音频效果族的错误降级；
/// * **只降一次**（`alreadyDegraded` ⇒ 不再试，避免"失败—重建"打转）；
/// * 空错误 / 别的族一律 `false`（把真错误原样抛给页面分类提示）。
bool shouldFallbackToNoEqualizer(
  Object? error, {
  required bool alreadyDegraded,
}) {
  if (alreadyDegraded) return false;
  return isAudioEffectFailure(error);
}
