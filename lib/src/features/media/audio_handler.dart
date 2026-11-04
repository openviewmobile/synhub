// 音频后台播放 / 通知栏 / 锁屏 / 耳机按键 —— `audio_service` 的 `AudioHandler`（P0-3）。
//
// 与官方 DSaudio 3.16.0-547 的 `mediasession/service/PlaybackService` +
// `MediaButtonReceiver` **同构**（证据见 `docs/audio-parity-audit.md:408` B9、
// `:448` P0-3；方案见 `docs/audio-background-playback-plan.md` §3.4–§3.6）。
//
// ## 职责边界（R6：**后台引擎里没有登录态**）
//
// `AudioService.init` 建引擎的方式与 Activity 共享（`audio_service-0.18.19` 的
// `AudioServicePlugin.getFlutterEngine` 用同一份 `FlutterEngineCache`），但
// **进程被系统重启后** `main()` 会再次执行、而那时**没有** `_sid` / QuickConnect
// 登录态。因此本 handler **只接收已经解析好的播放 URL 与元数据**：
//   * 不在本文件里发任何 DSM 请求、不读 KV 会话、不走 QuickConnect；
//   * 会话续期需要新 `_sid` 时，**回调页面注入的 [freshUrlFetcher]**（页面活在
//     主引擎里、有会话），handler 绝不自己登录（见 [renewAudioSession]）。
//
// ## 与既有播放层的关系（R7）
//
// 本 handler **包住** `features/audio/audio_player.dart` 的 [AudioStationPlayer]
// （真实实现 = `just_audio`）：页面从此只监听 handler 的
// `playbackState` / `queue` / `mediaItem`，不再自己维护一份
// `player.playing` / 队列下标 —— 消灭"两套状态打架"。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/i18n/data_text.dart';
import '../../core/platform/mpris_linux.dart';
import '../audio/audio_player.dart';
import '../audio/audio_radio_desc.dart';
import 'media_player.dart' show classifyPlayerError;
import 'media_source.dart'
    show
        MediaChannel,
        MediaKind,
        MediaSource,
        MediaUnavailableReason,
        kMediaSessionRenewMaxAttempts,
        mediaSessionRenewDelay,
        shouldRenewSession;

/// 一条**已经解析好**的音频曲目：URL + 展示元数据（R6：不含任何登录/会话逻辑）。
///
/// [url] 由页面的 `AudioStationApi.streamUrl` 生成（带 `_sid`；**只活在内存里**，
/// 绝不写进 `MediaItem`，否则会随媒体会话把凭据广播出去）。
/// 这一条音频**是什么**（r633）。
///
/// 全局迷你条要把同一件事做对：音乐条目点开进单曲页，电台条目点开进电台面板。
/// 光看 `MediaItem.id` 判不出来（自定义电台的 id 就是服务端给的 `radio_<n>`，
/// 而歌曲是 `music_<md5>` —— 两套前缀都不保证），所以在构造轨道时显式带上。
enum AudioTrackKind {
  song,
  radio;

  /// 落到 `MediaItem.extras` 的字符串（跨进程/跨页面只靠这个字符串认亲）。
  String get tag => name;

  static AudioTrackKind fromTag(Object? raw) =>
      raw == radio.tag ? radio : song;
}

class AudioTrackInfo {
  const AudioTrackInfo({
    required this.id,
    required this.url,
    required this.title,
    this.artist = '',
    this.album = '',
    this.duration,
    this.coverBytes,
    this.kind = AudioTrackKind.song,
  });

  /// 这条是歌曲还是电台（默认歌曲：绝大多数调用点都是歌曲）。
  final AudioTrackKind kind;

  /// 稳定身份（`AudioSongDto.id`，队列下标就是按它对回来的）。
  final String id;

  /// 鉴权直链（带 `_sid`；仅内存）。
  final String url;

  final String title;
  final String artist;
  final String album;

  /// 元数据时长（秒级，来自 `Song.getinfo`）；null = 未知。
  final Duration? duration;

  /// **内嵌封面字节**（页面用既有 `media_cover_view.dart` 的提取链取得：
  /// `embeddedSongCoverKey` + `mediaCoverProvider`，只发 FileStation Range 片段）。
  ///
  /// null = 这条没有内嵌封面 → **不给 `artUri`**（通知栏就不显示封面），
  /// 绝不为封面去联网取图（隐私，方案 §3.5）。
  final Uint8List? coverBytes;

  AudioTrackInfo withUrl(String url) => AudioTrackInfo(
    id: id,
    url: url,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    coverBytes: coverBytes,
    kind: kind,
  );

  AudioTrackInfo withCover(Uint8List? bytes) => AudioTrackInfo(
    id: id,
    url: url,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    coverBytes: bytes,
    kind: kind,
  );
}

/// 内嵌封面字节 → 本地 `file://` URI（通知栏 / 锁屏 / 车载取图用）。
///
/// 为什么必须是**本地文件**：`artUri` 是由 Android 媒体会话（系统/其它客户端）
/// 去取图的。指向服务端封面 URL 等于把带 `_sid` 的直链交出去，且方案明确
/// "不许联网取图"。所以只把已经解析到的**内嵌封面字节**落进应用缓存目录。
///
/// 拿不到目录 / 写失败 → `null`（通知栏就不显示封面，**如实降级**，
/// 不假装成功，也不因此打断播放）。
abstract class AudioArtworkCache {
  Future<Uri?> store(Uint8List bytes);

  Future<void> dispose();
}

/// 真实实现：应用临时目录（`path_provider`）下的 `audio_artwork/`。
class FileAudioArtworkCache implements AudioArtworkCache {
  FileAudioArtworkCache({Future<Directory?> Function()? dirResolver})
    : _dirResolver = dirResolver ?? _defaultDir;

  final Future<Directory?> Function() _dirResolver;
  Directory? _dir;
  final Map<String, File> _byFingerprint = {};

  static Future<Directory?> _defaultDir() async {
    try {
      final base = await getTemporaryDirectory();
      return Directory('${base.path}/audio_artwork');
    } catch (_) {
      // 无平台通道（纯单测）/ 权限异常 → 没有本地目录，封面就不上通知栏
      return null;
    }
  }

  /// 内容指纹（FNV-1a 32 位 + 长度）：同一张封面只写一次文件。
  ///
  /// 不引入 `crypto` 依赖：这里只需要"同一份字节 → 同一个文件名"，
  /// 不做安全用途。
  static String fingerprintOf(Uint8List bytes) {
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '${bytes.length}-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  @override
  Future<Uri?> store(Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    final fingerprint = fingerprintOf(bytes);
    final cached = _byFingerprint[fingerprint];
    if (cached != null && await cached.exists()) return cached.uri;
    try {
      final dir = _dir ??= await _dirResolver();
      if (dir == null) return null;
      await dir.create(recursive: true);
      final file = File('${dir.path}/$fingerprint.img');
      await file.writeAsBytes(bytes, flush: true);
      _byFingerprint[fingerprint] = file;
      return file.uri;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    _byFingerprint.clear();
  }
}

/// 音频焦点 / 打断（来电、其它 App 抢占、拔耳机）。
///
/// 抽成接口的理由与播放器适配器一致：真实实现要 `audio_session` 的平台通道，
/// 纯单测里起不来 —— 离线用假实现驱动"打断 → 暂停 / 结束 → 恢复"的语义
/// （方案 §3.5 第 5 条）。
abstract class AudioFocusController {
  /// 声明 music 用途并开始监听打断（失败 → 仅前台，如实降级）。
  Future<void> activate();

  /// true = 被打断（应暂停）；false = 打断结束（可恢复）。
  Stream<bool> get interruptions;

  /// 输出设备断开（拔耳机/蓝牙断）——暂停且**不**自动恢复。
  Stream<void> get becomingNoisy;

  Future<void> dispose();
}

/// 真实实现：`audio_session` 的 music 配置 + 打断 / 拔耳机事件。
class AudioSessionFocusController implements AudioFocusController {
  final _interruptions = StreamController<bool>.broadcast();
  final _noisy = StreamController<void>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  Stream<bool> get interruptions => _interruptions.stream;

  @override
  Stream<void> get becomingNoisy => _noisy.stream;

  @override
  Future<void> activate() async {
    final session = await AudioSession.instance;
    // music 用途：让系统知道我们是媒体播放，锁屏/通知栏/焦点按音乐类处理
    await session.configure(const AudioSessionConfiguration.music());
    _subs.add(
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          _interruptions.add(true);
        } else {
          _interruptions.add(false);
        }
      }),
    );
    _subs.add(session.becomingNoisyEventStream.listen((_) => _noisy.add(null)));
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _interruptions.close();
    await _noisy.close();
  }
}

/// 会话续期的结果（[renewAudioSession] 的返回值，供 handler 与离线单测断言）。
class AudioRenewOutcome {
  const AudioRenewOutcome._(this.kind, this.url, this.attempts);

  /// `renewed` / `notRenewable` / `exhausted`（枚举串，测试与日志用）。
  final String kind;

  /// 续期成功时的新 URL（带新 `_sid`）；否则 null。
  final String? url;

  final int attempts;

  bool get renewed => url != null && url!.isNotEmpty;

  /// 这条失败**本来就不该续期**（网络中断 / 服务端拒绝 / 不支持 Range…）。
  static const AudioRenewOutcome notRenewable = AudioRenewOutcome._(
    'notRenewable',
    null,
    0,
  );

  static AudioRenewOutcome renewedWith(String url, int attempts) =>
      AudioRenewOutcome._('renewed', url, attempts);

  static AudioRenewOutcome exhausted(int attempts) =>
      AudioRenewOutcome._('exhausted', null, attempts);
}

/// **会话到期后的有界续期**：复用 `media_source.dart` 的既有判定与退避策略。
///
/// * 判定 = [shouldRenewSession]（会话失效 **且** 可 seek **且** 有 renewer）——
///   不另造一套"要不要续"的规则；
/// * 预算 = [kMediaSessionRenewMaxAttempts]（2 次）、第 n 次前等
///   [mediaSessionRenewDelay]（指数退避）——**有界**，绝不无限循环；
/// * 全部失败 → [AudioRenewOutcome.exhausted]，由调用方**暂停 + 如实提示**
///   （R8：不允许夸口"后台一定能续"）。
class AudioSessionRenewer {
  const AudioSessionRenewer({
    this.maxAttempts = kMediaSessionRenewMaxAttempts,
    this.delayOf = mediaSessionRenewDelay,
  });

  final int maxAttempts;
  final Duration Function(int attempt) delayOf;

  Future<AudioRenewOutcome> renew({
    required MediaSource source,
    required MediaUnavailableReason reason,
    required Future<String> Function() fetchFreshUrl,
  }) async {
    if (!shouldRenewSession(source, reason)) {
      return AudioRenewOutcome.notRenewable;
    }
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final wait = delayOf(attempt);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      try {
        final url = await fetchFreshUrl();
        if (url.isNotEmpty) return AudioRenewOutcome.renewedWith(url, attempt);
      } catch (_) {
        // 这一跳失败：还有额度就退避后再试，没有就如实报 exhausted
      }
    }
    return AudioRenewOutcome.exhausted(maxAttempts);
  }
}

/// 把一条音频来源包成 [MediaSource]，只为**复用** [shouldRenewSession] 的判定。
///
/// AS 的 `Stream.stream` / `transcode` 都吃 HTTP Range（真机已证，审计 §1.7）
/// → `supportsRange = true`：会话失效时"原位置续播"这条硬约束成立。
/// `renew` 只表示"这条来源有续期能力"，真正的取新 URL 交给 [freshUrlFetcher]。
MediaSource renewableAudioSource({
  required String url,
  required String displayName,
  required int size,
}) => MediaSource(
  uri: url,
  // AS 音频没有独立通道枚举（file/drive/photos/chat），归 other；
  // 续期判定不看 channel。
  channel: MediaChannel.other,
  kind: MediaKind.audio,
  displayName: displayName,
  size: size,
  supportsRange: true,
  renew: () async => renewableAudioSource(
    url: url,
    displayName: displayName,
    size: size,
  ),
);

/// 续期完成后的**页面提示**（成功/失败各一条；失败必须是明确的"已暂停"）。
enum AudioRenewNoticeKind { renewed, failedPaused }

class AudioRenewNotice {
  const AudioRenewNotice(this.kind);

  final AudioRenewNoticeKind kind;
}

/// 一次**不可续期**的引擎失败（起播 / 取流 / 解码），交由**页面**如实提示用户。
///
/// 为什么要有它（第 393 轮修 **DA43**）：`_onEngineError` 原先只处理"会话过期
/// → 续期"，其余失败**直接 return**（源码里那句 `// 不是会话问题，不在这里动播放`
/// 之后就没别的读者了）。真机后果 = **页面静默**：点 `113.fm Blues Town`
/// 既没有声音、也没有任何提示（`docs/evidence-r392/r392_113fm_gap.txt`）。
///
/// 语义：一条失败**只报一次**；[message] 是引擎给的**诊断串**（只进日志，
/// 绝不上屏 —— 上了屏就是又一个"诊断串当用户文案"的旁路）。
class AudioEngineFailure {
  const AudioEngineFailure({required this.mediaId, required this.message});

  /// 出问题的那条曲目 id（页面据此判"是不是我刚点的那条"，避免陈旧提示）。
  final String? mediaId;

  /// 引擎原始诊断（`StateError: ...` / 原生 `describePlaybackError` 摘要）。
  final String message;
}

/// 音频后台 handler：`audio_service` 的系统回调 → 既有 [AudioStationPlayer]。
///
/// 单一状态源：`playbackState` / `queue` / `mediaItem`（页面只监听这三个）。
class SynologyAudioHandler extends BaseAudioHandler with SeekHandler {
  SynologyAudioHandler({
    AudioStationPlayer? player,
    AudioFocusController? focus,
    AudioArtworkCache? artwork,
    AudioSessionRenewer renewer = const AudioSessionRenewer(),
  }) : _player = player ?? createDefaultAudioStationPlayer(),
       _focus = focus ?? AudioSessionFocusController(),
       _artwork = artwork ?? FileAudioArtworkCache(),
       _renewer = renewer {
    _subs.add(_player.changes.listen((_) => unawaited(_syncFromPlayer())));
    _subs.add(_player.durationStream.listen(_onDuration));
    _subs.add(_player.positionStream.listen(_onPosition));
    final extras = _extras;
    if (extras != null) {
      _subs.add(extras.errors.listen(_onEngineError));
    }
    _subs.add(_focus.interruptions.listen(_onInterruption));
    _subs.add(_focus.becomingNoisy.listen((_) => unawaited(_onBecomingNoisy())));
  }

  final AudioStationPlayer _player;

  /// ★ 368：页面/服务要用的**同一个**播放器实例。
  ///
  /// 真机缺陷（本轮定位）：生产上 `main.dart` 只覆盖了 [audioHandlerProvider]，
  /// 而 `AudioService.init` 的 builder 是 `SynologyAudioHandler.new`
  /// —— 它自己 `createDefaultAudioStationPlayer()` 建了**播放器 P1**；
  /// 容器里的 `audioStationPlayerProvider` 又懒建了**第二个闲置播放器 P2**。
  /// 页面读 P2 ⇒ `androidAudioSessionId` 恒为 null、`AudioSpectrumSession`
  /// 永远拿不到会话、原生均衡器永远"还没接上"（真频谱因此一直回落推导动效，
  /// `dumpsys media.audio_flinger` 里 0 条 effect chain）。
  /// `main.dart` 现在用本 getter 把 `audioStationPlayerProvider` 覆盖成同一个
  /// 实例（单一状态源）。
  AudioStationPlayer get player => _player;

  final AudioFocusController _focus;
  final AudioArtworkCache _artwork;
  final AudioSessionRenewer _renewer;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// 引擎的附加能力（缓冲进度 / 异步错误 / 释放）；假引擎没有就按"没有"处理。
  AudioEngineExtras? get _extras =>
      _player is AudioEngineExtras ? _player as AudioEngineExtras : null;

  final _renewNotices = StreamController<AudioRenewNotice>.broadcast();

  final _engineFailures = StreamController<AudioEngineFailure>.broadcast();

  List<AudioTrackInfo> _tracks = const [];
  final Map<String, Uri?> _artUriByTrackId = {};
  Duration _lastPublishedPosition = Duration.zero;

  /// 失效前最后已知位置（续期成功后 seek 回这里，容差语义同 `media_source.dart`）。
  Duration _lastKnownPosition = Duration.zero;

  bool _resumeAfterInterruption = false;
  bool _stopped = true;
  bool _renewing = false;
  bool _disposed = false;

  /// ★ r699 / `DA339`：Linux 的 MPRIS 服务（媒体键 / 系统媒体面板）。
  ///
  /// `audio_service` 在 Linux 上没有平台实现 ⇒ 系统媒体卡与媒体键本来是没有的。
  /// 这里在**第一次有曲目**时懒起一个 `org.mpris.MediaPlayer2` 服务；
  /// 起不来（无会话总线 / 名字被占）就一直是 null，播放照常（不许因为
  /// "媒体键接不上"把播放挡住）。
  MprisLinuxService? _mpris;
  bool _mprisStarting = false;

  /// 起过一次、确认这台机器上**没有**会话总线（或名字被别人占了）⇒ 不再重试。
  bool _mprisGaveUp = false;

  /// 页面注入的"用**当前会话**重新解析某条曲目 URL"回调（返回带新 `_sid` 的直链）。
  ///
  /// R6：新 `_sid` 只能由主引擎里的页面拿到；handler **不**自己登录。
  Future<String> Function(String mediaId)? freshUrlFetcher;

  /// 续期结果通知（页面据此给"已续上"或"续期失败已暂停"的明确提示）。
  Stream<AudioRenewNotice> get renewNotices => _renewNotices.stream;

  /// **不可续期**的引擎失败（页面据此给"这个电台没能播放"的可读提示 + 重试入口）。
  ///
  /// 与 [renewNotices] 的分工：续期那条路已经自己会"暂停 + 提示"，这里只报
  /// **不归续期管**的失败，两条互不重复。
  Stream<AudioEngineFailure> get engineFailures => _engineFailures.stream;

  // ------------------------------------------------------------ 页面/测试读的口

  Stream<Duration> get positionStream => _player.positionStream;

  Stream<Duration?> get durationStream => _player.durationStream;

  Duration get position => _player.position;

  Duration? get duration => _player.duration;

  /// 当前曲目身份（= `mediaItem.value?.id`；页面据此判断"是不是这条在播"）。
  String? get currentMediaId => mediaItem.value?.id;

  /// 当前队列（页面队列按钮的启用态用它；与 `queue` 流同源）。
  List<AudioTrackInfo> get tracks => _tracks;

  // ------------------------------------------------------------ 生命周期

  /// 声明音频焦点（music）+ 开始监听来电/其它 App 抢占/拔耳机。
  ///
  /// 失败**不抛**：平台不支持时退化成"仅前台播放"，不假装有后台能力。
  Future<void> activate() async {
    try {
      await _focus.activate();
    } catch (_) {
      // 没有音频焦点能力：照常播，只是不处理打断
    }
  }

  // ------------------------------------------------------------ 系统回调

  @override
  Future<void> play() async {
    _stopped = false;
    await _player.resume();
    _publishState(updatePosition: _player.position);
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _publishState(updatePosition: _player.position);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    await _player.stop();
    _publishState(updatePosition: Duration.zero);
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _lastKnownPosition = position;
    _publishState(updatePosition: position);
  }

  @override
  Future<void> skipToNext() async {
    await _player.next();
    await _syncFromPlayer();
  }

  @override
  Future<void> skipToPrevious() async {
    await _player.previous();
    await _syncFromPlayer();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (_tracks.isEmpty) return;
    final i = index.clamp(0, _tracks.length - 1);
    _stopped = false;
    await _player.playQueue(_engineQueue(), startIndex: i);
    await _syncFromPlayer();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await _player.setRepeat(_repeatModeOf(repeatMode));
    _publishState(updatePosition: _player.position);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await _player.setShuffle(shuffleMode != AudioServiceShuffleMode.none);
    _publishState(updatePosition: _player.position);
  }

  /// 冷启动/系统回灌队列（只有元数据，没有 URL → 不可播）。
  ///
  /// 如实登记：进程被系统重启后**没有**登录态，无法重拼带 `_sid` 的直链，
  /// 所以能匹配到旧 URL 的条目保留 URL，其余 URL 为空（切到就播不了）。
  /// 不假装能"从通知栏冷启动继续播"。
  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    final byId = {for (final t in _tracks) t.id: t};
    _tracks = [
      for (final item in newQueue)
        AudioTrackInfo(
          id: item.id,
          url: byId[item.id]?.url ?? '',
          title: item.title,
          artist: item.artist ?? '',
          album: item.album ?? '',
          duration: item.duration,
        ),
    ];
    queueTitle.add('');
    _publishQueue();
    if (_tracks.isNotEmpty) _publishMediaItem(0);
    _publishState(updatePosition: _player.position);
  }

  // ------------------------------------------------------------ 页面入口

  /// 起播一个队列（页面把**已解析**的 URL + 元数据交进来）。
  ///
  /// 顺序：先发 `queue`/`mediaItem`（通知栏立刻有标题/封面）→ 再驱动引擎。
  /// 引擎抛错（起播失败）**向上抛**，由页面按既有 `classifyPlayerError` 分类提示
  /// —— 不在这里吞掉。
  Future<void> startQueue(
    List<AudioTrackInfo> tracks, {
    int startIndex = 0,
  }) async {
    if (tracks.isEmpty) return;
    _tracks = List.unmodifiable(tracks);
    _stopped = false;
    final index = startIndex.clamp(0, _tracks.length - 1);
    await _attachArtworkFor(index);
    _publishQueue();
    _publishMediaItem(index);
    await _player.playQueue(_engineQueue(), startIndex: index);
    await _syncFromPlayer();
  }

  /// 页面后续拿到某条曲目的内嵌封面时补上（队列推进到下一首时用）。
  ///
  /// 只影响 `mediaItem.artUri`；拿不到本地目录 → 保持无封面（不联网取图）。
  Future<void> attachArtwork(String mediaId, Uint8List? bytes) async {
    final uri = bytes == null ? null : await _artwork.store(bytes);
    _artUriByTrackId[mediaId] = uri;
    final index = _tracks.indexWhere((t) => t.id == mediaId);
    if (index >= 0) {
      _tracks = List.unmodifiable([
        for (final t in _tracks)
          if (t.id == mediaId) t.withCover(bytes) else t,
      ]);
      _publishQueue();
    }
    if (mediaItem.value?.id == mediaId) _publishMediaItem(index);
  }

  // ------------------------------------------------------------ 打断

  Future<void> _onInterruption(bool begin) async {
    if (_disposed) return;
    if (begin) {
      // 来电/其它 App 抢占：记住是否正在播 → 暂停
      _resumeAfterInterruption = _player.playing;
      if (_player.playing) {
        await _player.pause();
        _publishState(updatePosition: _player.position);
      }
    } else if (_resumeAfterInterruption) {
      _resumeAfterInterruption = false;
      await _player.resume();
      _publishState(updatePosition: _player.position);
    }
  }

  Future<void> _onBecomingNoisy() async {
    if (_disposed) return;
    // 拔耳机：暂停且**不**自动恢复（继续外放打扰旁人是最糟的默认）
    _resumeAfterInterruption = false;
    await _player.pause();
    _publishState(updatePosition: _player.position);
  }

  // ------------------------------------------------------------ 状态发布

  Future<void> _syncFromPlayer() async {
    if (_disposed) return;
    final index = _player.currentIndex;
    final position = _player.position;
    _lastKnownPosition = position;
    _lastPublishedPosition = position;
    if (index >= 0 && index < _tracks.length) {
      await _attachArtworkFor(index);
      _publishMediaItem(index);
    }
    _publishState(updatePosition: position);
  }

  void _onDuration(Duration? duration) {
    if (_disposed) return;
    final id = mediaItem.value?.id;
    if (id == null) return;
    final index = _tracks.indexWhere((t) => t.id == id);
    if (index < 0) return;
    // 引擎报到的时长补进 mediaItem（通知栏进度条/锁屏时长要用）
    _publishMediaItem(index, durationOverride: duration);
  }

  void _onPosition(Duration position) {
    if (_disposed) return;
    _lastKnownPosition = position;
    // 只有跨过 1 秒的整数格才广播（audio_service 的"位置不是连续流"约定：
    // 每 200ms 推一次平台通道既费电又没必要，通知栏会自动外推）。
    final delta = (position - _lastPublishedPosition).abs();
    if (delta < const Duration(seconds: 1)) return;
    _lastPublishedPosition = position;
    _publishState(updatePosition: position);
  }

  void _publishQueue() {
    queue.add([
      for (final t in _tracks)
        MediaItem(
          id: t.id,
          // ⚠️ 标题为空时**不许**回落成 URL —— 那会把 `_sid` 广播给媒体会话。
          title: t.title.isNotEmpty ? t.title : t.id,
          artist: t.artist.isEmpty ? null : t.artist,
          album: t.album.isEmpty ? null : t.album,
          duration: t.duration,
          artUri: _artUriByTrackId[t.id],
          extras: <String, dynamic>{'kind': t.kind.tag},
        ),
    ]);
  }

  void _publishMediaItem(int index, {Duration? durationOverride}) {
    if (index < 0 || index >= _tracks.length) {
      mediaItem.add(null);
      return;
    }
    final t = _tracks[index];
    // ★ r653（`DA258`）：**通知栏的副标题也要说人话**。
    //   真机现场：SHOUTcast 的 `desc` 就是 `MP3 (192 kbps)`，页面上早已清洗，
    //   通知栏却把编码串原样印出来（"同一个东西两处两种读数"）。
    //   电台：清洗后有人话就用人话，没有就用「正在播放」（此刻用户真正关心的）；
    //   歌曲：不动（`artist` 本来就是人话）。
    final isRadio = t.kind == AudioTrackKind.radio;
    final cleaned = isRadio ? asRadioHumanDesc(t.artist) : t.artist;
    final subtitle = isRadio
        ? (cleaned.isEmpty ? dataText('asRadioNowPlaying', '正在播放') : cleaned)
        : (cleaned.isEmpty ? null : cleaned);
    mediaItem.add(
      MediaItem(
        id: t.id,
        title: t.title.isNotEmpty ? t.title : t.id,
        artist: subtitle,
        album: t.album.isEmpty ? null : t.album,
        duration: durationOverride ?? t.duration ?? _player.duration,
        artUri: _artUriByTrackId[t.id],
        // ★ r633：让**任何页面**（含外壳的全局迷你条）都能分清"这是歌还是电台"。
        //   不用 id 前缀猜：自定义电台的 id 是服务端给的（`radio_<n>`），
        //   歌曲是 `music_<md5>`，两套前缀都不保证，猜错就会把歌画成电台。
        extras: <String, dynamic>{'kind': t.kind.tag},
      ),
    );
  }

  /// 通知栏/蓝牙/车机上的一个控制键（图标 + **本地化标签**）。
  ///
  /// `MediaControl` 自带 `skipToPrevious` 之类的常量，但它们的 label 是写死的
  /// 英文（`Previous`）—— 读屏与车机会把它念出来。这里按当前语言重建。
  MediaControl _ctl(
    MediaAction action,
    String key,
    String fallback, {
    required String androidIcon,
  }) => MediaControl(
    action: action,
    androidIcon: androidIcon,
    label: dataText(key, fallback),
  );

  /// `playbackState`（**唯一**的状态源：playing / 位置 / 缓冲 / 速度 / 队列下标 / 模式）。
  void _publishState({Duration? updatePosition}) {
    final playing = _player.playing;
    final state = PlaybackState(
      // ★ r653：**通知栏的三个按钮**（人视角）。
      //
      // ① 只用「上一首 / 播放暂停 / 下一首」—— `stop` 从按钮行拿掉：
      //    音乐 App 的通知栏上按「停止」是罕见动作，占掉一个位置反而挤掉常用键；
      //    真要收掉通知，暂停后划走即可（`androidStopForegroundOnPause`）。
      // ② 标签走 l10n：系统会把 action 的 label 念给读屏/车载听，
      //    以前这里恒为英文的 `Previous`/`Pause`/`Next`，中文环境里像 bug。
      controls: [
        _ctl(MediaAction.skipToPrevious, 'mediaCtlPrevious', '上一首',
            androidIcon: 'drawable/audio_service_skip_previous'),
        if (playing)
          _ctl(MediaAction.pause, 'mediaCtlPause', '暂停',
              androidIcon: 'drawable/audio_service_pause')
        else
          _ctl(MediaAction.play, 'mediaCtlPlay', '播放',
              androidIcon: 'drawable/audio_service_play_arrow'),
        _ctl(MediaAction.skipToNext, 'mediaCtlNext', '下一首',
            androidIcon: 'drawable/audio_service_skip_next'),
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: _stopped || _tracks.isEmpty
          ? AudioProcessingState.idle
          : AudioProcessingState.ready,
      playing: playing,
      updatePosition: updatePosition ?? _player.position,
      bufferedPosition: _extras?.bufferedPosition ?? Duration.zero,
      speed: 1.0,
      queueIndex: _player.currentIndex >= 0 ? _player.currentIndex : null,
      repeatMode: _serviceRepeatOf(_player.repeatMode),
      shuffleMode: _player.shuffleEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    );
    playbackState.add(state);
    unawaited(_syncMpris(updatePosition ?? _player.position));
  }

  /// 把当前状态推给 MPRIS（Linux 之外直接返回；失败只打日志）。
  ///
  /// 判据来源与 `_publishState` **同一份**：曲目身份取 `mediaItem`，
  /// 位置取播放器，能力位取队列长度 —— 不另建一套"面板以为的状态"。
  Future<void> _syncMpris(Duration position) async {
    if (kIsWeb) return;
    if (_disposed) return;
    // ★ 判据**不按平台**：`flutter_test` 会把 `defaultTargetPlatform` 强设成
    //   android（`_platform_io.dart` 里 `FLUTTER_TEST` 那段），按平台门控
    //   会让这条能力**永远测不到**（也就永远证不了接线）。
    //   这里改成"试一次，拿不到会话总线就不再试"：非 Linux（含安卓/iOS）
    //   第一次 `DBusClient.session()` 就抛，被 `MprisLinuxService.start`
    //   吃掉 ⇒ 一次日志、之后零开销，行为与"按平台门控"等价但可测。
    if (_mprisGaveUp) return;
    if (_tracks.isEmpty) {
      // 队列空了：告诉系统"停了"，但服务留着（下一首还能被媒体键唤起）。
      await _mpris?.update(
        const MprisPlaybackSnapshot(stopped: true, playing: false),
      );
      return;
    }
    if (_mpris == null) {
      if (_mprisStarting) return;
      _mprisStarting = true;
      try {
        _mpris = await MprisLinuxService.start(
          callbacks: MprisCallbacks(
            play: play,
            pause: pause,
            next: skipToNext,
            previous: skipToPrevious,
            stop: stop,
            seek: seek,
          ),
        );
      } catch (e) {
        debugPrint('[mpris] 启动失败（忽略）：$e');
      } finally {
        _mprisStarting = false;
      }
      if (_mpris == null) {
        _mprisGaveUp = true;
        return;
      }
    }
    final item = mediaItem.value;
    final idx = _player.currentIndex;
    final hasPrev = _tracks.length > 1 && idx > 0;
    final hasNext = _tracks.length > 1 && idx >= 0 && idx < _tracks.length - 1;
    await _mpris!.update(
      MprisPlaybackSnapshot(
        stopped: _stopped || _tracks.isEmpty,
        playing: _player.playing && !_stopped,
        trackId: item?.id,
        title: item?.title,
        artist: item?.artist,
        album: item?.album,
        artUrl: item?.artUri?.toString(),
        duration: item?.duration ?? _player.duration,
        position: position,
        canNext: hasNext,
        canPrevious: hasPrev,
      ),
    );
  }

  Future<void> _attachArtworkFor(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final t = _tracks[index];
    if (_artUriByTrackId.containsKey(t.id)) return;
    final bytes = t.coverBytes;
    if (bytes == null || bytes.isEmpty) {
      _artUriByTrackId[t.id] = null;
      return;
    }
    _artUriByTrackId[t.id] = await _artwork.store(bytes);
  }

  // ------------------------------------------------------------ 会话续期（R8）

  Future<void> _onEngineError(Object error) async {
    if (_disposed) return;
    final index = _player.currentIndex;
    if (index < 0 || index >= _tracks.length) return;
    final reason = classifyPlayerError(error);
    final track = _tracks[index];
    if (!shouldRenewSession(
      renewableAudioSource(url: track.url, displayName: track.title, size: 0),
      reason,
    )) {
      // 网络中断 / 服务端拒绝 / 解码失败：**不是**会话问题，不在这里续期 ——
      // 但**必须报出去**（第 393 轮 DA43：原先这里静默 return，真机上表现为
      // "点了没声也没提示"）。诊断串只进日志，页面按 key 出可读文案。
      debugPrint(
        '[audio-engine-failure] id=${track.id} reason=$reason err=$error',
      );
      if (!_engineFailures.isClosed) {
        _engineFailures.add(
          AudioEngineFailure(
            mediaId: track.id,
            message: error.toString(),
          ),
        );
      }
      return;
    }
    await _renewAndResume(index, reason);
  }

  /// 会话过期 → 有界续期 → 续上就**原位置续播**，续不上就**暂停 + 如实提示**。
  Future<void> _renewAndResume(int index, MediaUnavailableReason reason) async {
    if (_renewing || _disposed) return;
    _renewing = true;
    try {
      final track = _tracks[index];
      final fetch = freshUrlFetcher;
      if (fetch == null) {
        // 页面还没注入续期回调 → 不能假装能续：暂停 + 如实提示
        await _pauseAndNoticeFailure();
        return;
      }
      final outcome = await _renewer.renew(
        source: renewableAudioSource(
          url: track.url,
          displayName: track.title,
          size: 0,
        ),
        reason: reason,
        fetchFreshUrl: () => fetch(track.id),
      );
      if (!outcome.renewed) {
        await _pauseAndNoticeFailure();
        return;
      }
      final updated = [..._tracks];
      updated[index] = track.withUrl(outcome.url!);
      _tracks = List.unmodifiable(updated);
      final resumeAt = _lastKnownPosition;
      await _player.playQueue(_engineQueue(), startIndex: index);
      await _player.seek(resumeAt);
      await _syncFromPlayer();
      _renewNotices.add(const AudioRenewNotice(AudioRenewNoticeKind.renewed));
    } finally {
      _renewing = false;
    }
  }

  Future<void> _pauseAndNoticeFailure() async {
    await _player.pause();
    _publishState(updatePosition: _player.position);
    _renewNotices.add(
      const AudioRenewNotice(AudioRenewNoticeKind.failedPaused),
    );
  }

  // ------------------------------------------------------------ 工具

  List<AudioQueueEntry> _engineQueue() => [
    for (final t in _tracks)
      AudioQueueEntry(id: t.id, url: t.url, title: t.title),
  ];

  static AudioRepeatMode _repeatModeOf(AudioServiceRepeatMode mode) =>
      switch (mode) {
        AudioServiceRepeatMode.one => AudioRepeatMode.one,
        AudioServiceRepeatMode.all => AudioRepeatMode.all,
        AudioServiceRepeatMode.none ||
        AudioServiceRepeatMode.group => AudioRepeatMode.off,
      };

  static AudioServiceRepeatMode _serviceRepeatOf(AudioRepeatMode mode) =>
      switch (mode) {
        AudioRepeatMode.one => AudioServiceRepeatMode.one,
        AudioRepeatMode.all => AudioServiceRepeatMode.all,
        AudioRepeatMode.off => AudioServiceRepeatMode.none,
      };

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _renewNotices.close();
    await _engineFailures.close();
    final extras = _extras;
    if (extras != null) {
      await extras.dispose();
    } else {
      // 假引擎/无附加能力：至少停掉，别让声音继续
      await _player.stop();
    }
    await _focus.dispose();
    await _artwork.dispose();
    final mpris = _mpris;
    _mpris = null;
    await mpris?.dispose();
  }
}

/// 平台初始化：注册后台 handler（渠道 id / 名称 / 常驻策略按方案 §3.4）。
///
/// 失败（非 Android / 清单没配好）→ 返回一个**仅前台**的 handler：照常能播，
/// 但不假装有通知栏/后台能力。
Future<SynologyAudioHandler> createBackgroundAudioHandler() async {
  SynologyAudioHandler handler;
  try {
    handler = await AudioService.init(
      builder: SynologyAudioHandler.new,
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.openviewai.synhub.audio',
        androidNotificationChannelName: dataText(
          'mediaAudioChannelName',
          '播放控制',
        ),
        // 暂停即退前台（避免常驻占用）；常驻只发生在播放态。
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        // ★ r653：**单色**小图标（`mipmap/ic_launcher` 是彩色的，状态栏里会被
        //   系统渲染成一个彩色方块，深色状态栏上几乎看不见）。
        androidNotificationIcon: 'drawable/ic_stat_audio',
      ),
    );
  } catch (_) {
    handler = SynologyAudioHandler();
  }
  await handler.activate();
  return handler;
}

/// handler 的唯一入口（页面只依赖它）。
///
/// * 生产：`main.dart` 用 [createBackgroundAudioHandler] 返回的**同一个** handler
///   覆盖本 provider（`AudioService.init` 的 handler 就是媒体会话背后的那个）；
/// * 离线测试：覆盖 `audioStationPlayerProvider` 成假引擎，本 provider 自动包住它
///   —— 页面与 handler 的接线因此在**没有平台通道**时也能测。
final audioHandlerProvider = Provider<SynologyAudioHandler>((ref) {
  final handler = SynologyAudioHandler(
    player: ref.watch(audioStationPlayerProvider),
  );
  ref.onDispose(handler.dispose);
  return handler;
});
