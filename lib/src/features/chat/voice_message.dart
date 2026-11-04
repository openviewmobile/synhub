// 语音消息（Phase 5）：60 秒录音 + 播放。
//
// 反编译依据：
//   * `AudioRecordPresenter`：临时文件 `voiceMessage*.aac`，计时器上限 **60000ms**；
//   * `AccountManager.createPost(..., file0, file1)`：
//     文件名以 `voiceMessage` 开头且 MIME 含 `aac` 时，才带上
//     `voice_msg_length=<秒>`（服务端据此在气泡上显示时长）。
//
// 录音/播放都做成可替换的接口，测试里注入假实现（真机才用 record / just_audio）。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/i18n/l10n.dart';
import '../../core/user_facing_error.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';

/// 录音上限（`AudioRecordPresenter` 里是 60000L）
const kVoiceMaxSeconds = 60;

/// 语音条的最小宽度（dp）。下限要保证「Voice message」这个固定标签**一行放得下**
/// —— 真机上 94dp 就会折行（测试字体量不出来，见 AGENTS §2.0.55–64 ③）。
const kVoiceBarMin = 124.0;

/// 服务端认的语音文件名前缀（`AudioRecordPresenter.VOICE_MESSAGE`）
const kVoiceFileNamePrefix = 'voiceMessage';

/// 语音附件名：`voiceMessage-<毫秒>.aac`
String voiceFileName([DateTime? now]) =>
    '$kVoiceFileNamePrefix-${(now ?? DateTime.now()).millisecondsSinceEpoch}.aac';

bool isVoiceFileName(String name) =>
    name.startsWith(kVoiceFileNamePrefix) &&
    name.toLowerCase().endsWith('.aac');

/// 语音时长文案：`m:ss`
String formatVoiceDuration(int seconds) {
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 录音器（可注入）
abstract class VoiceRecorder {
  Future<bool> hasPermission();

  /// 开始录到 [path]
  Future<void> start(String path);

  /// 结束并返回文件路径（没录到东西返回 null）
  Future<String?> stop();

  /// 放弃并删除临时文件
  Future<void> cancel();
}

/// 「能报当前音量」的可选能力（录音动效用）。
///
/// 为什么单独一个接口、而不是往 [VoiceRecorder] 加成员：`VoiceRecorder` 有多个
/// `implements` 的假实现（测试），加成员会把它们全部弄红；而"能不能报音量"
/// 本来就是可选能力 —— 没有就退化成固定的呼吸动效，界面不会是死的。
abstract class VoiceAmplitudeSource {
  /// 当前音量，归一到 `0..1`（0 = 静音）
  Future<double> amplitude();
}

/// 真实实现（`record` 包，AAC-LC / m4a 容器，扩展名沿用原 App 的 `.aac`）
class RecordVoiceRecorder implements VoiceRecorder, VoiceAmplitudeSource {
  final _rec = AudioRecorder();

  @override
  Future<bool> hasPermission() => _rec.hasPermission();

  @override
  Future<void> start(String path) =>
      _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);

  @override
  Future<String?> stop() => _rec.stop();

  @override
  Future<void> cancel() => _rec.cancel();

  /// `record` 给的是 **dBFS**（0 = 满量程，-45 以下基本是静音）。
  /// 先归一到 `0..1` 再给界面，界面就不必知道单位。
  @override
  Future<double> amplitude() async {
    final a = await _rec.getAmplitude();
    final db = a.current;
    if (db.isNaN || db.isInfinite) return 0;
    return ((db + 45) / 45).clamp(0.0, 1.0);
  }
}

/// 播放器（可注入）
abstract class VoicePlayer {
  /// 播放某条语音（传下载用的鉴权 URL）。
  ///
  /// **同一个 URL 已经在播放器里时内部只续播、不重载**（见
  /// [MediaAudioStage] 的 Bug 3）：旧实现无条件 `setUrl`，在真机上表现为
  /// "拖动到 00:38 → 暂停 → 点播放"时新建 ExoPlayer 并从 00:00 重来。
  Future<void> play(String url);

  /// 从当前位置继续播（**不重载来源**）。
  ///
  /// 与 [play] 的区别就是 Bug 3 的修法：拖动/暂停之后要继续，必须走这条，
  /// 否则 just_audio 会 `setUrl` → 新建 ExoPlayer → 回到 0。
  /// 当前没有已载入的来源时是 no-op。
  Future<void> resume();

  Future<void> pause();

  Future<void> stop();

  /// 定位到某个位置（**文件预览页的进度条拖动**靠它）。
  ///
  /// 服务端必须支持 HTTP Range 才有意义（`just_audio` 官方明确要求）；
  /// 本项目走 FileStation `Download` 直链，真机实测支持 206（调研 §3.1）。
  Future<void> seek(Duration position);

  /// 是否正在播放（界面按钮状态用它，别自己维护一份可能与真实状态脱节的 bool）
  bool get playing;

  /// 播放速率（1.0 = 原速）
  Future<void> setSpeed(double speed);

  /// 当前播放速率（界面显示倍速用）
  double get speed;

  /// 当前播放的 URL；还没载入任何来源时是 null
  ///
  /// ⚠️ `stop()` 会把它清成 null（"没有在播"），所以调用方要判断"是不是同一个
  /// 来源"必须**先**看它、再看 [hasSource]。
  String? get currentUrl;

  /// 播放器里是不是已经有载入好的来源（暂停/放完都算，[stop] 之后不算）。
  bool get hasSource;

  Duration get position;

  Duration? get duration;

  /// 位置 / 状态变化
  Stream<void> get changes;
}

/// 音频播放器**额外**能力：把播放链路的错误暴露出来。
///
/// 为什么单独一个能力接口（与视频侧 `MediaPlayerFullControls` 同一取舍）：
/// `just_audio` 有 `errorStream`，但 [VoicePlayer] 的既有实现（含测试假实现）
/// 未必都有 —— 给基类硬塞成员会强迫所有实现改代码。界面用
/// `player is VoicePlaybackErrors` 做**能力判断**，没有就不做"会话失效自动续播"。
///
/// 暴露的 [error] 只是**原始错误串**：会话失效（DSM `119`/`106`）还是网络中断，
/// 由调用方用**同一套** `classifyPlayerError`（`media_player.dart`）判定，
/// 播放器这一层**不**自造第二套判定。
abstract class VoicePlaybackErrors {
  /// 最近一次播放错误的一句话（null = 没出错）
  String? get error;

  /// 成功重载 / 续播之后清掉错误（否则界面会一直停在失败态）
  void clearError();
}

/// 音频播放器**额外**能力：把"已经播到片尾（`completed`）"这件事**同步**暴露出来。
///
/// 为什么必须有这个能力（D-R5-7 真机缺陷"片尾重播要点两次"的代码级根因）：
/// `just_audio` 在 `completed` 时，本类的 `playerStateStream` 监听会紧接着做
/// `stop() + seek(0)`，把位置**异步**复位成 0。界面（`media_audio_stage.dart`）
/// 的 listener 是**异步**投递的，它读到 `position` 时可能已经是 0
/// ⇒ 只按"位置 ≥ 时长"判定"在片尾"会在真实复位顺序下**漏判**，第一次点击就
/// 走了对 `completed` 播放器无效的 `resume()`（只归零不出声、要再点一次）。
/// 位置是**流上的瞬时量**，`completed` 是**播放器的状态**；把状态单独同步报出来，
/// 判定就不再依赖两个异步回调的先后。
///
/// 与 [VoicePlaybackErrors] 同一取舍：给基类硬塞成员会强迫所有假实现改代码。
abstract class VoicePlaybackEnded {
  /// 是否处于"播到片尾"的状态（`ProcessingState.completed`）。
  bool get ended;

  /// 重播 / 换源 / 显式 seek 之后清掉（否则下一次点击会被误判成重播）。
  void clearEnded();
}

/// 真实实现（`just_audio`）
class JustAudioVoicePlayer
    implements VoicePlayer, VoicePlaybackErrors, VoicePlaybackEnded {
  final _player = AudioPlayer();
  final _changes = StreamController<void>.broadcast();

  JustAudioVoicePlayer() {
    _player.positionStream.listen((_) => _changes.add(null));
    // 播放链路错误（just_audio `PlayerException`：会话失效 / 网络 / 解码都从这里出）
    // → 交给上层用 `classifyPlayerError` 判定，不在这里分叉。
    _player.errorStream.listen((e) {
      _error = e.message;
      _changes.add(null);
    });
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        // ★ 先**同步**置位，再做下面的异步 `stop()+seek(0)`：复位会把
        //   `position` 冲成 0，晚到的界面 listener 就再也看不到"在片尾"了。
        _ended = true;
      }
      _changes.add(null);
      if (state.processingState == ProcessingState.completed) {
        // 播完回到起点：下次 [resume]/[play] 从 0 开始（"重播"语义），
        // 这也是"拖到文件末尾后再播放"的边界行为（见 media_audio_stage.dart）。
        _player.stop();
        _player.seek(Duration.zero);
      }
    });
  }

  /// 见 [VoicePlaybackEnded]：与位置复位无关的"已在片尾"状态。
  bool _ended = false;

  @override
  bool get ended => _ended;

  @override
  void clearEnded() => _ended = false;

  @override
  String? get currentUrl => _current;
  String? _current;

  /// 最近一次播放错误（`just_audio.errorStream` 的 message）
  String? _error;

  @override
  String? get error => _error;

  @override
  void clearError() => _error = null;

  /// 有没有载入过来源（`stop()` 之后 just_audio 仍保留 source，但语义上要当没有）
  bool _hasSource = false;

  @override
  bool get hasSource => _hasSource;

  @override
  Duration get position => _player.position;

  @override
  Duration? get duration => _player.duration;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> play(String url) async {
    // 同一个来源 + 播放器里已经载入 → 只续播：重载会新建 ExoPlayer 并回到 0
    // （真机 A2：拖动 seek 后点播放从 00:00 重来）。
    if (_hasSource && _current == url) {
      await resume();
      return;
    }
    _current = url;
    _hasSource = true;
    _ended = false;
    await _player.setUrl(url);
    _error = null;
    unawaited(_player.play());
  }

  @override
  Future<void> resume() async {
    if (!_hasSource) return;
    _error = null;
    // ★ 片尾重播一次点击（与 `VideoPlayerAdapter.play` / `MediaPlayerBridge.kt`
    //   的 `STATE_ENDED → seekTo(0)` 同一条修法）：`completed` 态下 just_audio 的
    //   `play()` 是 no-op。界面即使漏判（位置已被异步复位），这里也必须兜住。
    if (_ended || _player.processingState == ProcessingState.completed) {
      _ended = false;
      await _player.seek(Duration.zero);
    }
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) async {
    // 显式 seek（拖动/歌词跳转）离开片尾 ⇒ 清掉"已在片尾"，否则下一次点击
    // 会被误判成重播而多一次 seek(0)。
    _ended = false;
    await _player.seek(position);
  }

  @override
  bool get playing => _player.playing;

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  double get speed => _player.speed;

  @override
  Future<void> stop() async {
    _current = null;
    _hasSource = false;
    await _player.stop();
  }
}

/// 录音临时文件工厂（测试里要换掉：`path_provider` 在单测里没有平台通道）
final voiceTempFileProvider = Provider<Future<File> Function()>((ref) {
  return newVoiceTempFile;
});

final voiceRecorderProvider = Provider<VoiceRecorder>((ref) {
  final r = RecordVoiceRecorder();
  ref.onDispose(() {});
  return r;
});

final voicePlayerProvider = Provider<VoicePlayer>((ref) {
  final p = JustAudioVoicePlayer();
  ref.onDispose(p.stop);
  return p;
});

/// 录音临时文件（`getTemporaryDirectory()/voiceMessage-*.aac`）
Future<File> newVoiceTempFile([DateTime? now]) async {
  final dir = await getTemporaryDirectory();
  final sub = Directory('${dir.path}/voice');
  if (!sub.existsSync()) sub.createSync(recursive: true);
  return File('${sub.path}/${voiceFileName(now)}');
}

/// 波形柱数量（最近 [kVoiceWaveBars] 次采样）。
const int kVoiceWaveBars = 28;

/// 音量采样间隔（~11 帧/秒：既跟得上说话，又不会把 `getAmplitude` 打爆）。
const Duration kVoiceAmpInterval = Duration(milliseconds: 90);

/// 录音浮层：**录音 → 试听确认**两步。
///
/// 用户 2026-09-27 报告（第 6 条）：
///   * 录音界面"不够炫酷、缺乏音频动效" ⇒ 加**真实音量驱动**的波形；
///   * 「60 秒倒计时结束之后自动发送」是错的 ⇒ 到上限**只停录**，
///     进入试听页，由用户自己点「发送」；手动停止同样进试听页。
///   * 试听页必须给「播放」按钮，可以先听效果再决定发不发。
///
/// `showVoiceRecorderSheet()` 返回选中的文件路径（放弃/取消返回 null）。
class VoiceRecorderSheet extends ConsumerStatefulWidget {
  const VoiceRecorderSheet({super.key});

  @override
  ConsumerState<VoiceRecorderSheet> createState() => _VoiceRecorderSheetState();
}

class _VoiceRecorderSheetState extends ConsumerState<VoiceRecorderSheet> {
  Timer? _timer;
  Timer? _ampTimer;
  int _seconds = 0;
  String? _error;
  bool _stopping = false;

  /// 已经走完（发送 / 放弃）——`dispose` 不能再碰录音器，否则会重复 cancel
  bool _closed = false;

  late final VoiceRecorder _recorder;

  /// 录完待确认的本地文件；null = 还在录（或还没起来）
  String? _recorded;

  /// 最近若干次音量采样（画波形；末尾 = 最新）
  final List<double> _levels = List<double>.generate(kVoiceWaveBars, (_) => 0);

  VoicePlayer? _player;
  StreamSubscription<void>? _playerSub;
  bool _playing = false;

  /// Start time of the current preview audition (timed complete on stop)
  DateTime? _previewStartedAt;

  bool get _reviewing => _recorded != null;

  @override
  void initState() {
    super.initState();
    _recorder = ref.read(voiceRecorderProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ampTimer?.cancel();
    _playerSub?.cancel();
    // 没点过任何按钮就关掉（例如系统返回键）：必须把录音器收干净，
    // 否则麦克风会一直被占着（老实现只 cancel 了计时器）。
    if (!_closed && _recorded == null) {
      unawaited(_recorder.cancel());
    }
    final p = _player;
    if (p != null) unawaited(p.stop());
    super.dispose();
  }

  Future<void> _start() async {
    final t = context.t;
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) setState(() => _error = t.chatErrNoMicPermission);
        return;
      }
      final file = await ref.read(voiceTempFileProvider)();
      await _recorder.start(file.path);
      if (!mounted) return;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _seconds++);
        // ★ 到上限只**停录**，不发送 —— 进试听页让用户自己决定
        if (_seconds >= kVoiceMaxSeconds) unawaited(_stopRecording());
      });
      _startAmpPolling();
    } catch (e) {
      if (mounted) {
        setState(() => _error = t.chatErrRecordFailed(userFacingError(e)));
      }
    }
  }

  /// 音量采样：有真实音量就走真实音量，没有（假实现 / 平台不支持）就用
  /// 计时驱动的呼吸动效 —— **别让界面看起来是死的**。
  void _startAmpPolling() {
    final src = _recorder is VoiceAmplitudeSource
        ? _recorder as VoiceAmplitudeSource
        : null;
    _ampTimer = Timer.periodic(kVoiceAmpInterval, (_) async {
      var level = 0.0;
      if (src != null) {
        try {
          level = await src.amplitude();
        } catch (_) {
          level = 0;
        }
      } else {
        level =
            0.35 +
            0.35 * (1 + math.sin(_seconds * 2.0 + _levels.length * 0.4)) / 2;
      }
      if (!mounted || _reviewing) return;
      setState(() {
        _levels.removeAt(0);
        _levels.add(level.clamp(0.0, 1.0));
      });
    });
  }

  /// 结束录音 → 进入**试听确认**（不发送）。
  ///
  /// 手动「停止」和 60 秒上限都走这里（同一个实现，§2.0.8 ④）。
  Future<void> _stopRecording() async {
    if (_stopping || _reviewing) return;
    _stopping = true;
    _timer?.cancel();
    _ampTimer?.cancel();
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = null;
    }
    if (!mounted) return;
    // 太短（连 1 秒都不到）或没录到东西 → 当取消，别让用户"试听"一段空音频
    if (path == null || _seconds < 1) {
      await _discard();
      return;
    }
    setState(() {
      _stopping = false;
      _recorded = path;
    });
  }

  /// 放弃：删临时文件 + 收干净录音器 + 关闭浮层
  Future<void> _discard() async {
    if (_closed) return;
    _closed = true;
    _stopping = true;
    _timer?.cancel();
    _ampTimer?.cancel();
    await _stopPreview();
    final path = _recorded;
    if (path != null) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // 删不掉不影响"放弃"的语义
      }
    }
    try {
      await _recorder.cancel();
    } catch (_) {
      // 已经 stop 过，cancel 失败无所谓
    }
    if (!mounted) return;
    Navigator.of(context).pop(null);
  }

  /// 发送：把试听停掉再返回（调用方负责真正上传）
  Future<void> _send() async {
    final path = _recorded;
    if (path == null || _stopping || _closed) return;
    _closed = true;
    _stopping = true;
    await _stopPreview();
    if (!mounted) return;
    Navigator.of(context).pop(_ChosenVoice(path, _seconds));
  }

  VoicePlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final p = ref.read(voicePlayerProvider);
    _player = p;
    _playerSub = p.changes.listen((_) {
      if (mounted) setState(() => _playing = p.playing);
    });
    return p;
  }

  /// 试听 / 暂停试听（本地文件用 `file://` URI 交给同一个播放器）
  Future<void> _togglePreview() async {
    final path = _recorded;
    if (path == null) return;
    final player = _ensurePlayer();
    try {
      if (player.playing) {
        await player.pause();
        _finishPreviewAudition();
      } else {
        await player.play(Uri.file(path).toString());
        // analytics: auditioning the freshly recorded voice (object type only)
        _previewStartedAt = DateTime.now();
        trackOnce(UsageModule.chat, UsageAction.audition, objectType: 'voice');
      }
    } catch (e) {
      trackOnceFailure(
        UsageModule.chat,
        UsageAction.audition,
        objectType: 'voice',
        reason: 'preview',
        error: e,
      );
      // 试听失败不阻塞发送：用户还能直接发
    }
    if (mounted) setState(() => _playing = player.playing);
  }

  /// Audition ended -> emit a timed complete event
  void _finishPreviewAudition() {
    final started = _previewStartedAt;
    if (started == null) return;
    _previewStartedAt = null;
    trackComplete(
      UsageModule.chat,
      action: UsageAction.audition,
      duration: DateTime.now().difference(started),
      objectType: 'voice',
    );
  }

  Future<void> _stopPreview() async {
    _finishPreviewAudition();
    final p = _player;
    if (p == null) return;
    try {
      await p.stop();
    } catch (_) {
      // 收尾失败无所谓
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;
    final recording = _error == null && !_reviewing;

    return AlertDialog(
      title: Text(recording ? t.chatRecording : t.chatVoiceReviewHint),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null)
            Text(_error!, style: TextStyle(color: theme.colorScheme.error))
          else ...[
            VoiceWaveform(
              levels: _levels,
              active: recording,
              color: recording
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              formatVoiceDuration(_seconds),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _seconds / kVoiceMaxSeconds),
            const SizedBox(height: 8),
            Text(
              recording
                  ? t.chatVoiceMaxSeconds(kVoiceMaxSeconds)
                  : t.chatVoiceReviewHint,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: _error != null
          ? [
              TextButton(
                onPressed: () => _discard(),
                child: Text(t.actionCancel),
              ),
              // 没权限时"发送"禁用（保持既有语义：按钮在，但点不动）
              FilledButton(onPressed: null, child: Text(t.chatSend)),
            ]
          : recording
          ? [
              TextButton(
                onPressed: () => _discard(),
                child: Text(t.actionCancel),
              ),
              FilledButton(
                onPressed: _stopping ? null : () => _stopRecording(),
                child: Text(t.chatVoiceStop),
              ),
            ]
          : [
              TextButton(
                onPressed: () => _discard(),
                child: Text(t.chatVoiceDiscard),
              ),
              TextButton.icon(
                onPressed: _togglePreview,
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                label: Text(
                  _playing ? t.chatVoicePreviewPause : t.chatVoicePreview,
                ),
              ),
              FilledButton(
                onPressed: _stopping ? null : () => _send(),
                child: Text(t.chatSend),
              ),
            ],
    );
  }
}

/// 录音波形：每根柱子 = 一次音量采样。
///
/// 高度随音量变化（`levels` 每 [kVoiceAmpInterval] 更新一次）⇒ 真机上是
/// **跟着说话起伏的真动效**，不是固定动画。
class VoiceWaveform extends StatelessWidget {
  const VoiceWaveform({
    super.key,
    required this.levels,
    this.active = true,
    this.color,
    this.height = 48,
  });

  final List<double> levels;

  /// 录音中 = 彩色 + 有最小高度；停止后 = 灰色定格（让人看出"已经录完了"）
  final bool active;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.primary;
    return SizedBox(
      key: const Key('voice-waveform'),
      height: height,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final level in levels)
            Container(
              width: 3,
              height: 4 + level * (height - 6),
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: active
                    ? c.withValues(alpha: 0.35 + 0.65 * level)
                    : theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}

/// 录音浮层的返回值
class _ChosenVoice {
  const _ChosenVoice(this.path, this.seconds);
  final String path;
  final int seconds;
}

/// 录音结果（给调用方用）
class RecordedVoice {
  const RecordedVoice(this.path, this.seconds);
  final String path;
  final int seconds;
}

/// 弹出录音浮层；返回录音结果（取消/失败返回 null）
Future<RecordedVoice?> showVoiceRecorderSheet(BuildContext context) async {
  final out = await showDialog<Object?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const VoiceRecorderSheet(),
  );
  if (out is _ChosenVoice) return RecordedVoice(out.path, out.seconds);
  return null;
}
