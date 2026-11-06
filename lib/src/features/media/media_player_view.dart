// 内置播放器：**可复用的播放视图** + 一个独立播放页。
//
// 用法：
//   * 文件预览页里 `FilePreviewKind.video` 且来源可播 → 内嵌 [MediaPlayerView]；
//   * 视图右下角"全屏"→ `openMediaPlayer(...)` 推一个 [MediaPlayerPage]；
//   * 相册（photos）视频同样只调 `openMediaPlayer`，并传同类型视频的 `playlist`，
//     不另写一套播放器。
//
// 控制能力分两层（见 `media_player.dart`）：
//   * `MediaPlayerAdapter`：播放/暂停/seek/倍速/画面本体 —— `video_player` 也有；
//   * `MediaPlayerFullControls`：**自研原生播放器才有** —— 快进/快退、上一个/下一个、
//     音量、画面比例、音轨、内封字幕。界面用 `adapter is MediaPlayerFullControls`
//     判断能力，缺能力时**按钮不出现**（出现了却点了没反应是最糟的体验）。
//
// 这个文件只做"接线 + 画控件 + 方向/系统栏"：纯逻辑（播放列表排序、字幕解析与
// 同名匹配、画面比例语义）都在 `media_playlist.dart` / `media_subtitles.dart` /
// `media_tracks.dart`（不 import flutter，能被 `dart run` 与离线单测直接跑）。
//
// ── 控制层重做（对齐 MX Player / VLC / nPlayer / B 站的手感）────────────────
//   * 顶栏：更多 `⋮`（倍速/画面比例/音轨/字幕/方向）+ 收起控件；
//   * 单击画面中央 = 显隐控件；控件 10s 无操作自动隐藏（播放中才计时）；
//   * 双击画面左 40% / 右 40% = 快退 10s / 快进 10s，中间 20% 当单击用，
//     并弹一个"⟲10 秒"的中央提示动画；
//   * 左半屏竖直拖动 = 亮度、右半屏竖直拖动 = 音量，中央 HUD 显示百分比
//     （**向上 = 加大**，与主流播放器一致）；
//   * 底部：可拖进度条（当前/总时长）+ 播放/暂停 + 上一个/下一个 + 全屏；
//   * 字幕菜单：关闭 / 内封轨 / 同名外挂 / **在线搜索**（见
//     `media_subtitle_search.dart`）。
//
// 诚实边界（做不到就说做不到，别画一个假的）：
//   * **改不了系统亮度** —— 本仓没有亮度插件，所以"亮度"是画面上一层
//     **调暗遮罩**（`media-dim-overlay`）：只能变暗，不能超过系统亮度，
//     退出播放也不会影响别的界面；
//   * **拿不到缓冲进度** —— 原生 `MediaPlayerBridge` 没暴露 buffered position，
//     所以只给"缓冲中转圈"，**不画缓冲条**（画一条永远 0 的才是骗人）；
//   * 自动隐藏只认"播放中"：暂停时不自动收，否则用户暂停去点按钮时控件自己消失；
//   * 内嵌播放视图的顶栏**不重复显示文件名**（宿主页 AppBar 已经有一份，
//     两份同样的文字会让 `find.text(文件名)` 之类断言出现"找到 2 个"）；
//   * 在线字幕：免密钥源（Gestdown，全量免费）+ OpenSubtitles（匿名有配额，
//     被拒时如实提示"需要密钥"），密钥存在 `cloudKeyStoreProvider`。
//     下载的字幕存进 App 缓存目录并按文件记忆（`online:<缓存文件名>`），
//     缓存没了就静默降级 —— 详情与实测证据见 `media_subtitle_search.dart` 头注释；
//   * 单测里必须换掉"真磁盘 + Keychain"两处平台依赖：缓存走
//     `SubtitleCacheStore(backend: MemorySubtitleCacheBackend())`、
//     密钥走 `MemoryCloudKeyStore`（否则 widget 测试会挂在平台通道上）。
//
// 不做的（明确边界）：后台/锁屏播放、通知栏控制、画中画（PiP）、服务端转码、
// ASS 样式（字体/位置/特效，只抽 Dialogue 文本）、在线字幕的"上传/翻译"。
import '../../design/kit/design_kit.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/net/device_traffic.dart';
import '../../core/net/traffic_meter.dart';
import '../../core/settings/cloud_key_store.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/adaptive_actions.dart';
import '../../core/theme/app_theme.dart';
import '../../data/dto/file_entry_dto.dart';
import '../files/file_providers.dart';
import '../files/file_thumb.dart' show ThumbScale;
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'media_aspect_surface.dart';
import 'media_cover_provider.dart';
import 'media_cover_view.dart';
import 'media_library_loader.dart';
import 'media_playback_store.dart';
import 'media_player.dart';
import 'media_playlist.dart' show parentPathOf;
import 'media_reason_text.dart';
import 'media_resume_store.dart';
import 'media_source.dart';
import 'media_subtitle_search.dart';
import 'media_subtitle_transcript.dart';
import 'media_subtitles.dart';
import 'media_tracks.dart';
import 'upnp_cast.dart';
import 'video_cast.dart';
import 'native_video_player.dart' show NativeVideoPlayerAdapter;
import 'video_pip.dart';

/// 在线字幕这一套依赖（多源服务 + 磁盘缓存）。
///
/// 为什么做成 provider：单测要把它换成**假 HTTP + 临时目录**，
/// 否则 widget 测试一碰 `getApplicationCacheDirectory()` 就是
/// `MissingPluginException`（没有平台实现）。

/// r678 临时诊断开关（`--dart-define=R678_TRACE=true`）；不进产品行为。
const bool _r678Trace = bool.fromEnvironment('R678_TRACE');

class SubtitleSearchBundle {
  const SubtitleSearchBundle({required this.service, required this.cache});

  final SubtitleSearchService service;
  final SubtitleCacheStore cache;
}

final subtitleSearchBundleProvider = Provider<SubtitleSearchBundle>((ref) {
  final http = DartIoSubtitleHttp();
  return SubtitleSearchBundle(
    service: SubtitleSearchService.defaults(http: http),
    cache: SubtitleCacheStore(directory: getApplicationCacheDirectory),
  );
});

/// 倍速档位（速率选择只是几个数字，不需要 ARB）
///
/// 与持久化共用一份（`media_playback_store.dart`）：菜单里选得到的档位 ==
/// 重启后能吸附回去的档位，避免"存进去的值菜单里没有"。
const List<double> kMediaSpeeds = kMediaPlaybackSpeeds;

/// 字幕字号档位（DA226）。离散档而不是连续滑块：手机上"调到合适"只要两下，
/// 连续滑块反而难停在同一个值（下次看又要重调）。
const List<double> kMediaSubtitleScales = <double>[0.8, 1.0, 1.2, 1.4, 1.6];

/// 字幕**垂直偏移**档位（r655 · DA263），单位 = 逻辑像素，正值把字幕往上抬。
///
/// 为什么需要：内嵌/外挂字幕的默认基线在**画面底部**，遇到三种真实场景会被吃掉或
/// 挡画面 —— ① 电影下沿有硬字幕/台标；② 21:9 片源在 16:9 屏上"fit"后有大黑边，
/// 字幕沉在黑边里离画面太远；③ 底部控件条弹出时压住第二行字幕。
/// 四档是"够用又不难选"的折中（0 = 原样，最高 +120 = 大约三行字高）。
///
/// ★ r656（`DA270`）：档位表移到 `media_playback_store.dart`（持久化要拿同一份
/// 做吸附），这里只保留一个转出，避免两处各写一遍又慢慢对不上。
const List<double> kMediaSubtitleOffsets = kMediaSubtitleOffsetSteps;

/// 字幕**背景条**透明度档位（0 = 没有背景）。
///
/// 为什么是"开/关"而不是连续滑杆：字幕背景只有一个用途 —— 让白字在雪景/白墙/
/// 亮色画面上仍然读得出来。它要么需要要么不需要，中间档只是让人多点两下。
const double kMediaSubtitleBackgroundAlpha = 0.55;

/// 快进/快退步长（需求写死 ±10 秒）
const Duration kMediaSkipStep = Duration(seconds: 10);

/// 播放器内调光的最大遮罩不透明度（左半竖直滑到最下面时的压暗程度）
const double kMediaMaxDim = 0.85;

/// 在线字幕"首尾 64KB"指纹的块大小（OpenSubtitles 官方算法就是 64 KiB）
const int kSubtitleHashChunk = 64 * 1024;

/// 控件自动隐藏延时。
///
/// ★ 取 10 秒不是"随手写"：既有用例会 `pump` 到 5 秒左右（`media_r5_followup_test`），
/// 若用播放器常见的 3 秒会让"控件早已隐藏"变成隐藏的时序陷阱。10 秒既够长
/// （用户看得清），又不会在既有用例的 pump 窗口里生效。
const Duration kMediaControlsAutoHide = Duration(seconds: 10);

/// 「已经在片尾」的判定容差（末尾重播用）。
///
/// 原生位置事件是 250ms 一 tick（`MediaPlayerBridge.TICK_MS`），最后一个 tick
/// 可能落在 `duration` **之前**；用 `position >= duration` 的等号判定时，
/// 片尾的第一次点击会走不进 `seekTo(0)`，表现为"第一次不出声、再点一次才重播"
/// （R5-7 的音频路径同源）。取 500ms ≈ 2 个 tick，又远小于"用户在半途暂停"的
/// 尺度，暂停态点播放不会被误判成重播。
const Duration kMediaEndReplayTolerance = Duration(milliseconds: 500);

/// "已重新连接"**非阻塞**提示的显示时长。
///
/// 4s ≈ 一行提示被读到一次（与系统 toast 同量级）；到点自动消失，
/// 不需要用户点任何东西，也**不**会挡住播放器与控制条。
const Duration kMediaReconnectedNoticeDuration = Duration(seconds: 4);

String formatMediaDuration(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// 打不开时的面板：标题 + 解释 + 两条出路（**交给系统应用** / 下载）。
///
/// 复用既有 ARB key，文案来自 [mediaReasonText]。
class MediaFallbackPanel extends StatelessWidget {
  const MediaFallbackPanel({
    super.key,
    required this.source,
    required this.reason,
    this.onOpenExternal,
    this.onDownload,
    this.onRetry,
  });

  final MediaSource source;
  final MediaUnavailableReason reason;
  final VoidCallback? onOpenExternal;
  final VoidCallback? onDownload;

  /// **手动重试**（会话失效 + 这条来源可 seek + 有 renewer 时才给）。
  ///
  /// 自动续期是**有界**的（[kMediaSessionRenewMaxAttempts]）；用尽之后不能
  /// "静默停住"，也不能强迫用户重新登录 —— 所以给一个明确的「重试」按钮，
  /// 再走一次"重登 → 重拼 URL → seek 回原位"。
  /// null = 这条来源没有可重试的恢复路径（**不**给假按钮）。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final text = mediaReasonText(t, reason, source.kind);
    return Center(
      // ★ r676（`DA306`）：兜底面板要有**可机检的身份**。以前它只有文案，
      //   验收装置只能靠"某段中文在不在树上"猜；iOS `.mkv`/`.AVI` 的判据
      //   （"有界时间内必须说清原因"）需要它。
      key: const Key('media-fallback-panel'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              source.kind == MediaKind.video
                  ? Icons.videocam_off_outlined
                  : Icons.music_off_outlined,
              size: 44,
              color: DesignPalette.of(context).dim,
            ),
            const SizedBox(height: Gap.md),
            Text(
              source.displayName,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: Gap.xs),
            Text(
              text.title,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.xs),
            Text(
              text.detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: DesignPalette.of(context).dim,
              ),
            ),
            const SizedBox(height: Gap.lg),
            // ★ r676（`DA307`）：这行说明只说**会话**。以前只要 `onRetry != null`
            //   就挂它 —— 于是"容器解不开"（iOS `.mkv`）的黑屏面板上也写着
            //   "会话过期，自动续期失败，点重试重新登录"，把用户引向一个**根本
            //   不存在的问题**（重新登录也解不开 matroska）。判据 = 失败原因本身。
            if (onRetry != null && reason == MediaUnavailableReason.sessionExpired) ...[
              Text(
                mediaSessionResumeFailedHint(),
                key: const Key('media-session-resume-hint'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: DesignPalette.of(context).dim,
                ),
              ),
              const SizedBox(height: Gap.sm),
            ],
            Wrap(
              spacing: Gap.sm,
              children: [
                if (onRetry != null)
                  FilledButton.icon(
                    style: InlineButtonStyle.filled,
                    key: const Key('media-session-retry'),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    // 复用既有 key（本批禁改 ARB）：`photoRetry` = 重试 / Retry
                    label: Text(t.photoRetry),
                  ),
                // ★ r526（DA168 同族收口）：这块面板出现在**黑底**查看器/播放器里，
                // `tonalIcon` 的 `secondaryContainer` 跟壁纸走（亮色淡紫）⇒ 浅色板子。
                // 黑底容器里的按钮一律 `primary`/`onPrimary`。
                FilledButton.icon(
                  style: InlineButtonStyle.filled,
                  onPressed: onOpenExternal,
                  icon: const Icon(Icons.open_in_new),
                  label: Text(t.photoOpenWithOther),
                ),
                OutlinedButton.icon(
                  style: InlineButtonStyle.outlined,
                  onPressed: onDownload,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(t.dtoActionDownload),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 可复用的播放视图（内嵌 / 全屏页都用它）。
class MediaPlayerView extends ConsumerStatefulWidget {
  const MediaPlayerView({
    super.key,
    required this.source,
    this.entry,
    this.playlist,
    this.playlistIndex = 0,
    this.onOpenExternal,
    this.onDownload,
    this.onExitFullscreen,
    this.onRotate,
    this.onBack,
    this.hostChrome = false,
    this.autoPlay = true,
    this.showFullscreenButton = true,
    this.isFullscreen = false,
    this.onCurrentSourceChanged,
    this.resumeStore,
    this.adapter,
    this.pip,
  });

  final MediaSource source;

  /// 当前文件的目录条目（非 null 才能算"上一个/下一个"和同名字幕）
  ///
  /// 相册等"没有目录条目"的场景传 null：播放器照常工作，只是没有播放列表与字幕。
  final FileEntryDto? entry;

  /// 调用方**直接给好**的播放列表（相册/时间轴用；纯追加，null = 老行为）。
  ///
  /// 文件页的播放列表是从目录条目现算的（[entry] + `loadMediaDirectoryContext`），
  /// 相册没有 FileStation 目录，只有一串 `FotoItemDto`，所以在页面侧先解析成
  /// 同类型视频的 [MediaSource] 列表再传进来。**只对支持完整控制的适配器生效**。
  final List<MediaSource>? playlist;

  /// [playlist] 里当前这条的下标（列表为空/未传时忽略）
  final int playlistIndex;

  /// 当前播放项变化时回调（换集 / 自动续播 / 播放列表索引变化）。
  ///
  /// **为什么要往外报**：回退面板在本视图里（直接读 [_currentSource] 即可），
  /// 但**顶栏标题在 [MediaPlayerPage] 那一层** —— 它必须拿到"现在播的是哪一条"
  /// 才能不显示"打开播放器时的文件名"（R5 实测瑕疵）。只有完整控制的适配器
  /// 才有播放列表索引（`video_player` 回退拿不到），所以回退实现不会触发本回调。
  final ValueChanged<MediaSource>? onCurrentSourceChanged;

  /// 「上次看到哪儿」的本机记忆（`DA227`）。
  ///
  /// null = 老行为（不记忆、不续播）。做成**可选注入**而不是内部单例：
  /// 用例可以用临时目录/内存实现，播放器的续播逻辑因此可测；
  /// 相册幻灯片等场景也不需要跨会话记忆。
  final MediaResumeStore? resumeStore;

  final VoidCallback? onOpenExternal;
  final VoidCallback? onDownload;

  /// 全屏页里"退出全屏"（一般是 `Navigator.pop`）
  final VoidCallback? onExitFullscreen;

  /// 全屏页里"旋转屏幕"（方向归**页面**管，见 [MediaPlayerPage]）
  final VoidCallback? onRotate;

  /// 内嵌时玩家自绘顶栏上的"返回"（`DA273`：宿主页不再占一条 AppBar）
  ///
  /// 只有 [hostChrome] 为真时才用到；null 时不画返回（宿主可能没有上一页）。
  final VoidCallback? onBack;

  /// **把顶栏交给播放器**（`DA273`）。
  ///
  /// 为真时，内嵌视图也画"返回 ＋ 标题 ＋ ⋮"这一条**浮层**顶栏，并跟控制条
  /// 同显同隐。宿主页（文件预览页）因此可以**不留 AppBar** —— 那条常驻
  /// AppBar（56dp ＋ 状态栏）是从画面里**永久扣掉**的高度，竖屏 / 横屏 /
  /// 画中画三种情境下都在吃有效区域（画中画最狠）。
  final bool hostChrome;

  /// 载入后自动开始（用户点进来看视频一般是"点开就播"）
  final bool autoPlay;

  /// 全屏页里自己就是全屏，不再显示"全屏"按钮
  final bool showFullscreenButton;

  /// 自己在全屏页里（显示"退出全屏"与"旋转"）
  final bool isFullscreen;

  /// **借用别人的适配器**（全屏页用）。
  ///
  /// ★ r647（**DA247**）：原生桥只有 **一个** `player` + **一个** `textureEntry`。
  /// 全屏页若自己再造一个适配器，它 `dispose()` 时会把预览页那一份一起
  /// `releasePlayer()` 掉 —— 真机现场：退出全屏回到预览页，画面全黑、进度钉死、
  /// 点播放图标会变但不前进。现在全屏页**直接借**预览页的适配器：同一个
  /// player、同一张纹理、同一个位置，退出全屏就是"接着看"，没有任何交接
  /// （借来的适配器由**拥有者**负责 `dispose`）。
  final MediaPlayerAdapter? adapter;

  /// 画中画控制器（**可选注入**）。
  ///
  /// null = 真实系统通道（生产默认）。用例注入假实现，才能在无 Android 宿主
  /// 的测试进程里断言"按了按钮要发生什么"与"小窗里收起控件"。
  final VideoPipController? pip;

  @override
  ConsumerState<MediaPlayerView> createState() => _MediaPlayerViewState();
}

class _MediaPlayerViewState extends ConsumerState<MediaPlayerView> {
  /// 借来的适配器不归本 State 所有（见 [MediaPlayerView.adapter]）
  late final bool _ownsAdapter = widget.adapter == null;

  /// ★ r690（`DA329`）：适配器**在 `initState` 里就建好**，不再用
  /// `late final … = ref.read(…)` 的"首次读取才求值"。
  ///
  /// 现场（Linux 走查 · 视频页）：`_loadSubtitleStyle()` 的异步尾巴
  /// `_applySubtitleStyle()` 在**页面已经 dispose 之后**才跑，它读 `_adapter`
  /// ⇒ 触发 `ProviderScope.containerOf` 的
  /// 「Looking up a deactivated widget's ancestor is unsafe」，而且**在临死时
  /// 新建了一个播放器**（`MpvPlayerAdapter`）。前者是框架异常，后者是资源泄漏。
  /// 判据：`late` 的惰性求值 + `ref` 生命周期 = 两个都不许出现在异步尾巴里。
  late final MediaPlayerAdapter _adapter;
  StreamSubscription<void>? _sub;

  /// r655（`DA264`）投屏：控制器**懒创建**（没人点投屏就不搜网、不占 socket）
  VideoCastController? _castController;
  StreamSubscription<VideoCastSnapshot>? _castSub;
  VideoCastSnapshot _castState = const VideoCastSnapshot();

  /// r654（`DA259`）画中画：控制器、是否支持、是否正在小窗、自动进入的上一态
  late final VideoPipController _pip = widget.pip ?? systemVideoPip();
  bool _pipSupported = false;
  bool _inPip = false;
  bool? _pipAutoEnter;

  /// 当前**有效**来源：会话续期成功后会用新 `_sid` 的来源替换（其余字段不变）
  late MediaSource _activeSource;

  /// 运行时失败（枚举；界面文案由 [mediaReasonText] 渲染）
  MediaUnavailableReason? _failure;

  /// 播放段计时：`trackStart` 与 `trackComplete` 的时长来源（= 实际在播的墙钟时间）。
  final Stopwatch _playClock = Stopwatch();
  bool _playSegmentOpen = false;

  /// 失效前的**最后已知播放位置**：119 到达时播放器可能已经把位置清 0，
  /// 续播就靠这里累计的最后一个有效值（见 [kMediaSessionResumeTolerance]）。
  Duration _lastKnownPosition = Duration.zero;

  /// ★ r637：字幕全文面板的"心跳"。
  ///
  /// 面板是 `showModalBottomSheet` 里的一棵**独立子树**，父视图 `setState`
  /// 不会重建它 —— 想让"当前这句"跟着播放走，只能给一个可取值的源。
  /// 只放位置，不放别的状态（越窄越不容易和父视图打架）。
  final ValueNotifier<Duration> _positionTick = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// 正在做会话续期（期间不弹失败面板、不重复触发）
  bool _renewing = false;

  /// 已经自动续期过几次（[kMediaSessionRenewMaxAttempts] 之后不再自动恢复）
  int _renewAttempts = 0;

  /// 续期成功后显示"已重新连接"**非阻塞**提示（几秒后自动消失）
  bool _reconnected = false;
  Timer? _reconnectedTimer;

  /// 已经换过一次**通道回退**（[MediaSource.fallback]）。只换一次，避免
  /// "Download 失败 → Streaming 失败 → Download …" 的乒乓。
  bool _usedFallback = false;

  /// 换通道后的**播放列表覆盖**：相册的播放列表里每一条都带自己的
  /// [MediaSource.fallback]，失败时整表换成兜底通道，原生侧才能继续"上/下一个"。
  List<MediaSource>? _fallbackPlaylist;

  /// 换通道后要恢复的播放列表下标（[MediaPlayerView.playlistIndex] 是**打开时**的
  /// 下标，换通道时用户可能已经切到别的条目）。
  int? _fallbackIndex;

  /// 拖动中的目标位置（毫秒）；非 null = 用户正按着滑块
  double? _dragValue;

  /// 拖动前是否在播（松手后要接着播）
  bool _resumeAfterDrag = false;

  /// 目录上下文（播放列表 + 外挂字幕候选）；null = 没条目 / 列目录失败
  MediaDirectoryContext? _dir;

  /// 已经解析好的外挂字幕轨
  SubtitleTrack? _externalTrack;

  /// 当前选中的外挂字幕（null = 没选外挂）
  SubtitleMatch? _externalChoice;

  /// 正在取字幕正文（菜单里显示转圈）
  bool _subtitleBusy = false;

  /// 正在下载在线字幕（菜单里显示转圈）
  bool _onlineBusy = false;

  /// 在线字幕：当前挂着的那一条 + 它在缓存目录里的文件名
  ///
  /// 名字**确定性**（`SubtitleCacheStore.fileNameFor`）⇒ 记忆里只存这个名字，
  /// 重启后按名字回读；文件不在了就如实降级（不假装挂上了）。
  SubtitleSearchHit? _onlineHit;
  String? _onlineCacheFile;
  SubtitleFormat? _onlineFormat;

  /// 控件是否可见（主流播放器：点画面中间显示/隐藏）
  bool _controlsVisible = true;

  /// 控件自动隐藏的定时器（10s，见 [kMediaControlsAutoHide]）
  Timer? _controlsTimer;

  /// ★ r634（DA223）：上一拍是否"在播"。
  ///
  /// 只认**边沿**（停→播）来武装自动隐藏计时：原生播放器的 `changes` 流在播放中
  /// 会因位置/缓冲/码率等持续发事件，若"每次在播都重新武装"，计时永远被重置
  /// ⇒ 真机上控件**根本不收**（r633 修 DA217 时引入，真机 15 s 仍常驻才抓到）。
  bool _wasPlaying = false;

  /// 双击时的落点（用来判"左半 / 右半"；`onDoubleTap` 本身不给坐标）
  Offset? _doubleTapPosition;

  /// 播放器内亮度遮罩（0 = 不遮，0.85 = 最暗）
  ///
  /// ★ 为什么不是"系统亮度"：Flutter 侧没有改系统亮度的公开 API，本仓也没有
  /// 相应插件；要动系统亮度得加插件并申请 `WRITE_SETTINGS`（属于本轮允许改的
  /// 文件之外）。所以这里做的是**播放器内调光**（画面遮罩），与 VLC 的
  /// "视频内亮度"同一类；详见文件末尾"边界"注释。
  double _dimOpacity = 0;

  /// 中央手势提示（快进/快退/亮度/音量）
  _GestureHudData? _hud;
  Timer? _hudTimer;

  /// 竖直滑动手势：开始时判定在哪一侧、基准值是多少
  _GestureSide? _verticalSide;
  bool _verticalDragged = false;

  /// 竖直滑动的基准值（音量 0~1 / 亮度 0~1；每帧更新为增量基线）
  double _dragBase = 0;

  /// ★ r635（DA224）：横滑拖进度。
  ///
  /// 现场：VLC / Plex / YouTube 上**横滑画面**就是拖进度（人类第一条肌肉记忆），
  /// 而本播放器只有"点进度条那条细线"和"双击 ±10s"两条路 —— 想跳到 8:00
  /// 只能把 10 秒按钮点十几次。横滑补的就是这条缺失的路。
  ///
  /// 口径：**整屏宽 = 整段时长**（VLC 语义），松手才真正 seek（拖动中只更新提示，
  /// 不狂发 seek 请求）。只有可 seek 的源才响应（Drive 的 `Accept-Ranges: none` 不装样子）。
  /// `DA227`：读到的“上次看到哪儿”（非 null 时顶部给一条可撤销的提示）。
  Duration? _resumedFrom;

  /// 续播判定是否**已经有结论**（播放列表自动续播进来的条目不许被拉回旧位置）。
  bool _resumeApplied = false;

  /// 正在查/正在 seek（防重入：事件密集时不许并发跑两遍）。
  bool _resumeApplying = false;

  /// 用户**自己动过进度**（拖条 / 双击跳 / 拖画面）—— 一旦动过，就绝不抢方向盘。
  ///
  /// 原先用"位置 > 3 s"当判据，真机上就翻车了：`ready` 与首个位置事件往往
  /// 比 3 s 还晚到，于是**每次都判成"用户已经动过"**、续播永远不发生
  /// （r636 真机：同一集第二次打开直接回到 00:00 且无提示）。
  /// 判据要钉**谁动的**，不能钉"现在在第几秒"。
  bool _userSeeked = false;

  /// 上次落盘的进度（节流：每 10 s 或暂停/退出时再写）。
  Duration? _lastSavedPosition;

  /// 实际使用的进度记忆：注入优先，否则用**真实本机存储**（生产默认）。
  ///
  /// 用例里 `path_provider` 没有宿主实现 ⇒ 真实存储退化为 no-op，
  /// 想断言行为的用例注入内存实现即可（见 `test/media_player_r636_test.dart`）。
  MediaResumeStore? _store;

  /// 续播提示自动收起的计时器（10 s；用户先点了「从头播放」就提前收）。
  Timer? _resumeBannerTimer;

  Duration? _seekDragBase;
  Duration? _seekDragTarget;
  double _seekDraggedDx = 0;

  /// ★ r635（DA226）：字幕字号倍率（0.8–1.6，仅本次播放会话）。
  ///
  /// 现场：手机上看带字幕的课程，默认字号在 6.7 寸屏上"贴着看才看清"；
  /// 而字幕是要**边看边读**的，不像正文可以放大慢慢读。做法与播放器设置里的
  /// 其他项一致：**收进「播放设置」**，不在画面上摆一排技术参数。
  double _subtitleScale = 1;

  /// 字幕垂直偏移（逻辑像素，正值向上）—— 见 [kMediaSubtitleOffsets]
  ///
  /// ★ r656（`DA270`）：这两个值从"本次播放会话"升级成**跨会话记住**
  ///   （`MediaPlaybackStore.loadSubtitleStyle`）；以前退出播放页就回到默认，
  ///   用户每次重看都要再调两下。
  double _subtitleOffset = 0;

  /// 字幕背景条（true = 半透明黑底）—— 见 [kMediaSubtitleBackgroundAlpha]
  bool _subtitleBackground = false;

  /// 偏好读回来之前不要回写（否则"打开页面"会把用户存的 +80 覆盖成 0）
  bool _subtitleStyleLoaded = false;

  /// ★ r635（DA225）：长按 2 倍速（松开即恢复原速）。
  ///
  /// 现场：看课程/讲座时"这段想快点过"是高频动作，原来只能开「播放设置」点倍速，
  /// 再回去把它调回 1.0 —— 两步，而且经常忘了调回来。
  double? _speedBeforeHold;

  /// 只有自研原生播放器才有完整控制（`video_player` 回退没有）
  MediaPlayerFullControls? get _full => _adapter is MediaPlayerFullControls
      ? _adapter as MediaPlayerFullControls
      : null;

  /// 已经往外报过的当前播放项（避免每 250ms 一个位置 tick 都回调父层）
  MediaSource? _reportedSource;

  /// 播放偏好/队列的持久化（W1-2）。测试用内存实现覆盖。
  MediaPlaybackStore get _prefs => ref.read(mediaPlaybackStoreProvider);

  /// 队列持久化去重：上次落盘的目录 + 下标（避免每个位置 tick 都写盘）
  String? _lastQueueKey;
  int? _lastQueueIndex;

  /// 字幕记忆的 key（拿不到稳定身份 → null，**不拿 URL 当 key**）
  String? get _subtitleMemoryKey {
    final entry = widget.entry;
    if (entry == null) return null;
    return mediaSubtitleMemoryKey(path: entry.path, size: entry.size);
  }

  /// 当前播放列表（调用方显式给的优先，否则目录现算的）；null = 单条。
  ///
  /// 优先级必须与 [_loadSource] **完全一致**：面板/顶栏要跟着
  /// `full.playlistIndex` 取同一条，不能各算各的。
  List<MediaSource>? get _playlistItems {
    final override = _fallbackPlaylist;
    if (override != null && override.isNotEmpty) return override;
    final explicit = widget.playlist;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final dir = _dir;
    if (dir != null && dir.playlist.isNotEmpty) return dir.playlist;
    return null;
  }

  /// **当前播放项**（含换集 / 自动续播）：标题与回退面板只许用它。
  ///
  /// R5 实测瑕疵：面板/顶栏原来取的是"打开播放器时的 `widget.source`"，用户
  /// 「下一个」切到 `theora.mkv` 后仍显示 `clip-h264.mp4`。这里改成按播放器的
  /// `playlistIndex` 在播放列表里取当前这条；取不到（`video_player` 回退 / 单条 /
  /// 下标越界）才退回 [_activeSource]。
  MediaSource get _currentSource {
    final full = _full;
    final items = _playlistItems;
    if (full == null || items == null) return _activeSource;
    // 与 `NativeVideoPlayerAdapter.setPlaylist` 一样跳过空 URL 的条目，
    // 否则下标会错位（播放列表里混了不可播条目时）。
    final playable = [
      for (final item in items)
        if (item.uri.isNotEmpty) item,
    ];
    final index = full.playlistIndex;
    if (index < 0 || index >= playable.length) return _activeSource;
    return playable[index];
  }

  /// 把"当前播放项"报给父层（顶栏标题）；没有变化就不触发重建。
  void _syncCurrentSource() {
    // 队列下标/条目变化顺手落盘（W1-2）：重启后队列顺序与当前条目都还在。
    _persistQueue();
    final callback = widget.onCurrentSourceChanged;
    if (callback == null) return;
    final current = _currentSource;
    if (identical(current, _reportedSource)) return;
    _reportedSource = current;
    callback(current);
  }

  /// 恢复上一次的**队列顺序 + 当前条目**（只认 FileStation 目录来源）。
  ///
  /// 语义（见 `docs/media-player-download-ux-w1-2-3.md`）：
  ///   * 顺序来自快照（自定义/上次的顺序重启后还在）；
  ///   * 已消失的条目丢掉、新出现的补到末尾（`reconcileMediaQueue`）；
  ///   * 下标 = 快照里的"上次播到的那条"；**仅当**这次打开的就是那条时沿用，
  ///     否则从用户点开的这一条开始（不抢用户的选择）。
  Future<void> _restoreQueueMemory() async {
    final entry = widget.entry;
    final dir = _dir;
    if (entry == null || dir == null || dir.playlist.isEmpty) return;
    if (dir.paths.length != dir.playlist.length || dir.paths.isEmpty) return;
    final snap = await _prefs.loadQueue(parentPathOf(entry.path));
    if (!mounted || snap == null) return;
    final available = [
      for (var i = 0; i < dir.playlist.length; i++)
        MediaQueueRef(path: dir.paths[i], name: dir.playlist[i].displayName),
    ];
    final restored = reconcileMediaQueue(snap, available);
    if (restored == null) return;
    final byPath = {for (var i = 0; i < dir.paths.length; i++) dir.paths[i]: i};
    final order = <int>[];
    for (final p in restored.paths) {
      final i = byPath[p];
      if (i != null) order.add(i);
    }
    if (order.isEmpty) return;
    var index = restored.index;
    if (snap.currentPath != entry.path) {
      final opened = order.indexOf(byPath[entry.path] ?? -1);
      index = opened < 0 ? 0 : opened;
    }
    if (index < 0 || index >= order.length) index = 0;
    _dir = MediaDirectoryContext(
      playlist: [for (final i in order) dir.playlist[i]],
      index: index,
      paths: [for (final i in order) dir.paths[i]],
      subtitleMatches: dir.subtitleMatches,
      subtitleEntries: dir.subtitleEntries,
    );
  }

  /// 载入完成后把上次的倍速用回去（必须在 `load` 之后：`setSpeed` 之前的
  /// 控制器还不存在，视频实现会静默丢掉）。
  Future<void> _applySavedSpeed() async {
    final saved = await _prefs.loadSpeed();
    if (saved == null || !mounted) return;
    if (saved == _adapter.speed) return;
    try {
      await _adapter.setSpeed(saved);
    } catch (_) {
      // 平台拒绝倍速（极少数）→ 保持原速，不把播放变失败
    }
  }

  /// 落盘当前队列（去重；只认"目录现算的播放列表"，相册/兜底通道无路径身份）。
  void _persistQueue() {
    final entry = widget.entry;
    final dir = _dir;
    final full = _full;
    if (entry == null || dir == null || full == null) return;
    if (widget.playlist != null && widget.playlist!.isNotEmpty) return;
    if (_fallbackPlaylist != null && _fallbackPlaylist!.isNotEmpty) return;
    if (dir.paths.length != dir.playlist.length || dir.paths.isEmpty) return;
    final index = full.playlistIndex;
    if (index < 0 || index >= dir.paths.length) return;
    final key = parentPathOf(entry.path);
    if (key == _lastQueueKey && index == _lastQueueIndex) return;
    _lastQueueKey = key;
    _lastQueueIndex = index;
    unawaited(
      _prefs.saveQueue(
        MediaQueueSnapshot(
          queueKey: key,
          items: [
            for (var i = 0; i < dir.paths.length; i++)
              MediaQueueRef(
                path: dir.paths[i],
                name: dir.playlist[i].displayName,
              ),
          ],
          currentPath: dir.paths[index],
        ),
      ),
    );
  }

  /// 用户选了倍速 → 立即生效并**记住**（重启后还在）。
  Future<void> _setSpeed(double speed) async {
    await _adapter.setSpeed(speed);
    await _prefs.saveSpeed(speed);
    if (mounted) setState(() {});
  }

  /// 恢复上次的字幕选择（外挂按文件名、内封按轨道 id）。
  ///
  /// **如实降级**：外挂字幕文件不在了 / 内封轨道 id 不再出现（换了容器或版本）
  /// → 保留自动匹配的结果（或关闭），**不假装**选中了一个不存在的轨。
  Future<void> _restoreSubtitle() async {
    final key = _subtitleMemoryKey;
    final full = _full;
    if (key == null || full == null) return;
    final saved = await _prefs.loadSubtitle(key);
    if (!mounted || saved == null || saved.isEmpty) return;
    if (saved == 'off') {
      await _selectSubtitle(const _SubtitleChoice.off(), full);
      return;
    }
    const externalPrefix = 'external:';
    if (saved.startsWith(externalPrefix)) {
      final name = saved.substring(externalPrefix.length);
      for (final match in _dir?.subtitleMatches ?? const <SubtitleMatch>[]) {
        if (match.name == name) {
          await _selectSubtitle(_SubtitleChoice.external(match), full);
          return;
        }
      }
      return;
    }
    const embeddedPrefix = 'embedded:';
    if (saved.startsWith(embeddedPrefix)) {
      final id = saved.substring(embeddedPrefix.length);
      for (final track in full.subtitleTracks) {
        if (track.id == id) {
          await _selectSubtitle(_SubtitleChoice.embedded(track), full);
          return;
        }
      }
      return;
    }
    // 在线字幕：`online:<缓存文件名>` —— 按名字从**缓存目录**回读。
    // 文件不在了（用户清了缓存 / 换机）就如实降级：保持自动匹配结果，不假装。
    const onlinePrefix = 'online:';
    if (saved.startsWith(onlinePrefix)) {
      await _restoreOnlineSubtitle(saved.substring(onlinePrefix.length), full);
    }
  }

  /// 重启后按缓存文件名把在线字幕挂回来（读不到就什么都不做）
  Future<void> _restoreOnlineSubtitle(
    String cacheFileName,
    MediaPlayerFullControls full,
  ) async {
    if (cacheFileName.isEmpty) return;
    try {
      final bundle = ref.read(subtitleSearchBundleProvider);
      final download = await bundle.cache.load(cacheFileName);
      if (!mounted || download == null) return;
      final track = download.toTrack();
      if (track == null || track.cues.isEmpty) return;
      await _selectSubtitle(
        _SubtitleChoice.online(cacheFileName, download.format),
        full,
      );
    } catch (_) {
      // 缓存目录拿不到（缺平台实现 / 权限）→ 静默降级，绝不让播放器崩
    }
  }

  /// 上报"开始播放"（每段只报一次；播→停→播算两段）。
  void _reportPlayStarted() {
    if (_playSegmentOpen) return;
    _playSegmentOpen = true;
    _playClock
      ..reset()
      ..start();
    trackStart(
      UsageModule.media,
      UsageAction.play,
      objectType: _activeSource.kind.code,
    );
    // 估算档：原生播放器绕过 Dart，只有"已知在播"的窗口才采 UID 差分
    unawaited(EstimatedTraffic.begin(TrafficModules.media));
  }

  /// 上报"这一段播放结束"（暂停 / 播完 / 离开页面）。
  void _reportPlayStopped() {
    if (!_playSegmentOpen) return;
    _playSegmentOpen = false;
    _playClock.stop();
    trackComplete(
      UsageModule.media,
      action: UsageAction.play,
      duration: _playClock.elapsed,
      objectType: _activeSource.kind.code,
    );
    // 会话结束 → 采第二次 UID 计数，可信才归属（否则丢弃，见 device_traffic.dart）
    unawaited(EstimatedTraffic.end());
  }

  /// 上报"这条来源播不了"（原因 = 既有 [MediaUnavailableReason] 稳定枚举）。
  void _reportPlayUnavailable(
    MediaSource source,
    MediaUnavailableReason reason,
  ) {
    trackOnceFailure(
      UsageModule.media,
      UsageAction.play,
      objectType: source.kind.code,
      reason: reason,
    );
  }

  /// **运行时失败 → 分类 → 回退 → 面板**（顺序每一步都有理由）。
  ///
  /// 1. `refinePlayerErrorForSource` + `classifyPlayerError`（既有分类）；
  /// 2. **会话语义复核**（R7-13-B）：错误串里没带 119/106，但服务端用
  ///    `HTTP 200` + JSON 信封承载时，Media3 只会报"不是媒体"
  ///    （`ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED`）。用
  ///    [MediaSource.probeSessionCode] 走**同一鉴权字节链路**取一小段应答体，
  ///    还原出 119/106 → 归 `sessionExpired`（只有真会话码才升级）；
  /// 3. 会话失效 + 能 seek + 有 renewer → 既有**自动续期**（续期失败才面板）；
  /// 4. 还有**下一跳**（相册 `Download` → `Streaming`）且失败不是会话/网络层
  ///    → 原地换通道重试；
  /// 5. 都不行 → 明确面板（三类文案互不相同）。
  Future<void> _handleRuntimeFailure(Object err) async {
    final source = _currentSource;
    var reason = refinePlayerErrorForSource(source, classifyPlayerError(err));
    final probe = source.probeSessionCode;
    if (reason != MediaUnavailableReason.sessionExpired && probe != null) {
      final code = await probe();
      if (!mounted) return;
      if (isMediaSessionCode(code)) {
        reason = MediaUnavailableReason.sessionExpired;
      }
    }
    if (!mounted || _failure != null || _renewing) return;
    if (shouldRenewSession(_activeSource, reason) &&
        _renewAttempts < kMediaSessionRenewMaxAttempts) {
      await _renewAndResume(reason);
      return;
    }
    if (!_usedFallback && shouldTryFallbackSource(_activeSource, reason)) {
      if (await _tryFallbackSource()) return;
      if (!mounted) return;
    }
    debugPrint('[r678view] fatal failure=${reason.code}');
    _reportPlayUnavailable(source, reason);
    setState(() => _failure = reason);
    // 失败面板要写"当前这条"的名字（用户「下一个」到坏文件时不能写上一个）
    _syncCurrentSource();
  }

  /// 切到 [MediaSource.fallback] 并**原地**重试（相册 `Download` → `Streaming`）。
  ///
  /// * 单条：直接换 [_activeSource]；
  /// * 有播放列表（相册/时间轴）：把**整表**换成各自的兜底来源并保留当前下标，
  ///   否则原生侧还拿着 Download 的 playlist，"上/下一个"会再次踩同一个坑。
  ///
  /// 返回 false = 这条来源根本没有下一跳 / 换完还是装不上 → 调用方回面板。
  Future<bool> _tryFallbackSource() async {
    final resumeAt = _lastKnownPosition;
    final items = _playlistItems;
    final full = _full;
    if (items != null && items.isNotEmpty && full != null) {
      final index = full.playlistIndex.clamp(0, items.length - 1);
      final switched = [for (final s in items) s.fallback ?? s];
      final changed = [
        for (var i = 0; i < switched.length; i++)
          if (switched[i].uri != items[i].uri) i,
      ].isNotEmpty;
      if (!changed) return false;
      _fallbackPlaylist = switched;
      _fallbackIndex = index;
      _activeSource = switched[index];
    } else {
      final next = _activeSource.fallback;
      if (next == null) return false;
      _activeSource = next;
    }
    _usedFallback = true;
    _failure = null;
    try {
      await _loadSource();
      if (resumeAt > Duration.zero) await _adapter.seekTo(resumeAt);
      await _adapter.play();
    } catch (_) {
      return false;
    }
    if (mounted) setState(() {});
    return true;
  }

  /// 自动续播进入的条目"窗口内没有任何画面证据"的**非阻塞**提示。
  ///
  /// 只有实现了 [MediaPlayerContinuationNotice] 的适配器（自研原生播放器的看门狗）
  /// 会给；`video_player` 回退与既有假适配器都不实现 → 永远为 false。
  bool get _continuationNotice {
    final adapter = _adapter;
    return adapter is MediaPlayerContinuationNotice &&
        (adapter as MediaPlayerContinuationNotice)
            .hasNoPictureContinuationNotice;
  }

  @override
  void initState() {
    super.initState();
    // 先建适配器（见 `_adapter` 的注释）：之后的任何异步尾巴都不再碰 `ref`。
    _adapter = widget.adapter ?? ref.read(mediaPlayerAdapterFactoryProvider)();
    _activeSource = widget.source;
    trackView(UsageModule.media, screen: 'player');
    final initialReason = _activeSource.reason;
    if (initialReason != null) {
      _reportPlayUnavailable(_activeSource, initialReason);
    }
    unawaited(_initPip());
    // ★ r656（`DA270`）：字幕位置/背景条是**看的人的偏好**，进页面就该是上次那样。
    unawaited(_loadSubtitleStyle());
    _sub = _adapter.changes.listen((_) {
      if (!mounted) return;
      // 播/停的**边沿**：start 与 complete 成对，时长 = 实际在播的墙钟时间。
      final playingNow = _adapter.playing;
      // r654（DA259）：自动进入小窗**只跟着"在播"**走 —— 暂停时关掉，
      // 否则用户想按 Home 退出去聊天，画面也跟着缩成小窗。
      if (_wasPlaying != playingNow) unawaited(_syncPipAutoEnter(playingNow));
      if (playingNow) {
        _reportPlayStarted();
        // ★ r633（DA217）：起播/恢复播放才重新武装自动隐藏（暂停时控件常驻）。
        // ★ r634（DA223）：只认**边沿** —— 播放中每次事件都武装会让计时被无限重置。
        if (_controlsVisible && !_wasPlaying) _armAutoHide();
      } else {
        _reportPlayStopped();
        // 暂停 ⇒ 撤掉计时器，控件留在屏上（用户此刻正要操作它们）。
        _controlsTimer?.cancel();
        // `DA227`：暂停是"我可能要走了"的最强信号 ⇒ 立刻把进度落盘。
        _persistPosition(force: true);
      }
      _wasPlaying = playingNow;
      // ★ r678（`DA311`）：**换引擎窗口**里先别判死。
      //   主引擎（iOS 的 AVFoundation 对 `.mkv` 报 `-11828`）的错误会先到，
      //   而 libmpv 兜底往往一秒多就出画面 ⇒ 这窗口里挂致命面板就是"明明能播
      //   却写着解不开"。窗口结束后（成功或失败）再按老逻辑分类。
      // ★ 接口之间没有子类型关系 ⇒ `is` 不会把 `MediaPlayerAdapter` 提升成
      //   `MediaPlayerEngineSwitchable`，必须显式转型（同 `_audioAllUnsupported`）。
      final switchingEngine = _adapter is MediaPlayerEngineSwitchable
          ? _adapter as MediaPlayerEngineSwitchable
          : null;
      final switchWindow = switchingEngine?.engineSwitchPending ?? false;
      // 兜底引擎已经接上且**没有错误**了 ⇒ 把之前记下的失败撤掉（页面回到画面）
      final recovered = switchingEngine != null &&
          switchingEngine.usingFallbackEngine &&
          _adapter.error == null &&
          _adapter.ready;
      if (recovered && _failure != null && !_renewing) {
        debugPrint('[r678view] recovered -> clear failure');
        setState(() => _failure = null);
      }
      if (_r678Trace) {
        debugPrint('[r678view] tick err=${_adapter.error} '
            'failure=${_failure?.code} ready=${_adapter.ready} '
            'win=$switchWindow rec=$recovered'
            ' kind=${_adapter.runtimeType}');
      }
      final err = _adapter.error;
      if (err != null && _failure == null && !_renewing && !switchWindow) {
        // 分类 + 通道回退 + 会话续期是**异步**的（R7-13-B 要用鉴权字节链路复核
        // 应答体），所以整体交给 [_handleRuntimeFailure]。
        unawaited(_handleRuntimeFailure(err));
        return;
      }
      if (switchWindow) {
        // 换引擎中：只刷一次界面（不落盘位置、不判死），等兜底引擎的事件
        if (mounted) setState(() {});
        return;
      }
      setState(() {
        if (_failure == null && !_renewing) {
          _lastKnownPosition = _adapter.position;
          _positionTick.value = _adapter.position;
        }
      });
      // 换集 / 自动续播 / 播放列表索引变化 → 顶栏与回退面板跟着当前播放项
      _syncCurrentSource();
      // `DA227`：播放中每 10 s 落一次盘 —— 进程被杀（清后台）也丢不了多少。
      if (playingNow) _persistPosition();
      // 装载那一刻还没就绪（时长/首帧都没有）⇒ 就绪后补做续播判定。
      if (!_resumeApplied && _adapter.ready) unawaited(_applyResume());
    });
    if (widget.source.playable) {
      if (_ownsAdapter) {
        unawaited(_bootstrap());
      } else {
        // 借来的播放器**已经在播**：重复 `load()` 会把它拉回 00:00，
        // 所以只做"接管显示"，顺便把「上次看到哪儿」的自动续播判据按掉。
        _resumeApplied = true;
        _lastKnownPosition = _adapter.position;
        _positionTick.value = _adapter.position;
      }
    }
    // 控件自动隐藏：10s 后收起（主流播放器的行为）。只在**点过画面之后**才重置；
    // 初装也起一个，让"打开就一直不动"的情况也能收起。
    _armAutoHide();
  }

  /// 显示并重置自动隐藏计时（点击画面 / 操作控件后调用）
  ///
  /// ★ r633（**DA217**）：**暂停时不自动收控件**。
  ///
  /// 真机现场（r632 取证时顺手拍到的）：暂停后盯着画面看 10 秒，控件整层消失
  /// ⇒ 想再点播放 / 拖进度 / 打开字幕，必须先在画面中间点一下把它们叫回来。
  /// 用户暂停的动机十有八九**就是**要操作控件（看进度、找字幕、调设置），
  /// 这时候把它收走是反人类的。主流播放器（Plex / 播客类）暂停时控件常驻。
  void _armAutoHide() {
    _controlsTimer?.cancel();
    // 暂停（含首帧还没起播）⇒ 不起计时器；真正开播时由监听器补上。
    if (!_adapter.playing) return;
    _controlsTimer = Timer(kMediaControlsAutoHide, () {
      if (!mounted || !_controlsVisible) return;
      // 计时器跑到时如果已经暂停，同样不收起（暂停可能发生在计时中途）。
      if (!_adapter.playing) return;
      setState(() => _controlsVisible = false);
    });
  }

  /// 中间单击：显示 / 隐藏控件（隐藏时立即取消自动隐藏计时）
  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _armAutoHide();
    } else {
      _controlsTimer?.cancel();
    }
  }

  /// 同一个 State 被换上新来源（同一测试/页面里 pump 两次、或父层复用本视图）时，
  /// 缓存的 [_activeSource] 必须跟着走：否则"能不能 seek"会拿旧来源判断
  /// （旧代码在 build/controls 里直接读 `widget.source`，这是等价语义）。
  @override
  void didUpdateWidget(covariant MediaPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.source, oldWidget.source)) {
      _activeSource = widget.source;
      _failure = null;
      _renewAttempts = 0;
      _reconnected = false;
      _reconnectedTimer?.cancel();
      _lastKnownPosition = Duration.zero;
      _reportedSource = null;
      _usedFallback = false;
      _fallbackPlaylist = null;
      _fallbackIndex = null;
      _lastQueueKey = null;
      _lastQueueIndex = null;
    }
  }

  /// 列目录（只为扩展控制做）→ 载入 → 自动播 → 自动挂同名字幕
  Future<void> _bootstrap() async {
    final full = _full;
    final entry = widget.entry;
    if (full != null && entry != null) {
      _dir = await loadMediaDirectoryContext(
        fs: ref.read(fileApiProvider),
        entry: entry,
        kind: widget.source.kind,
        sourceOf: _sourceOf,
      );
      // 队列顺序/下标在装载**之前**恢复（`_loadSource` 会读 `_dir`）；
      // 只在"有目录身份 + 有完整控制"时才多一次异步，普通单条播放不变。
      if (mounted) await _restoreQueueMemory();
    }
    await _load();
    // 倍速必须在 `load` 之后用回去（之前控制器还不存在）；不阻塞起播。
    unawaited(_applySavedSpeed());
    if (widget.autoPlay) {
      try {
        await _adapter.play();
      } catch (err) {
        // 起播请求就失败 → 与运行时失败走**同一条**分类/回退/续期链
        if (mounted) unawaited(_handleRuntimeFailure(err));
        return;
      }
    }
    if (mounted) setState(() {});
    // 播放列表装好后，当前播放项才是准的（`playlistIndex` 已由播放器回报）
    _syncCurrentSource();
    unawaited(_autoSubtitle().then((_) => _restoreSubtitle()));
  }

  /// 目录里的条目 → FileStation 直链（与预览页同一套规则）
  MediaSource _sourceOf(FileEntryDto e) => resolveFileStationSource(
    displayName: e.name,
    kind: _activeSource.kind,
    fs: ref.read(fileApiProvider),
    path: e.path,
    size: e.size,
  );

  Future<void> _load() async {
    try {
      await _loadSource();
    } catch (err) {
      // 装载失败 → 与运行时失败走**同一条**分类/回退/续期链
      if (mounted) unawaited(_handleRuntimeFailure(err));
      return;
    }
    if (mounted) setState(() {});
  }

  /// 真正装进播放器（会抛异常，由调用方决定"回退面板"还是"续期失败"）
  Future<void> _loadSource() async {
    final full = _full;
    final dir = _dir;
    // 播放列表优先级：**通道回退覆盖** > 调用方显式给的（相册）> 目录现算的
    // （文件页）> 单条
    final override = _fallbackPlaylist;
    final explicit = widget.playlist;
    if (full != null && override != null && override.isNotEmpty) {
      final index = (_fallbackIndex ?? 0).clamp(0, override.length - 1);
      await full.setPlaylist(override, index);
    } else if (full != null && explicit != null && explicit.isNotEmpty) {
      final index = widget.playlistIndex.clamp(0, explicit.length - 1);
      await full.setPlaylist(explicit, index);
    } else if (full != null && dir != null && dir.playlist.isNotEmpty) {
      await full.setPlaylist(dir.playlist, dir.index);
    } else {
      await _adapter.load(_activeSource);
    }
    // ★ 不 `await`：起播不许被"读本地进度文件"拖住（真机上是几毫秒，
    //   但这是**用户点了播放到出画面**的路径，不能有任何不必要的等待）。
    //   进度记忆是"加分项"，慢一拍也能用 `changes` 里的就绪回调补上。
    unawaited(_applyResume());
  }

  /// `DA227`「上次看到 4:31，这次接着看」。
  ///
  /// 只对**可 seek 的源**、只对**本次播放器第一次装进来的条目**生效：
  ///   * 直播 / 不支持 Range 的流没有"上次的位置"，硬 seek 只会失败；
  ///   * 自动续播 / 用户点「下一个」进来的条目，位置由播放器自己定 ——
  ///     这里再拉回旧值等于"换集后又跳回去"，是反人类的。
  ///
  /// 读到之后**先 seek 再起播**（[_bootstrap] 里 play 在本方法之后），
  /// 用户不会看到"从 00:00 闪一下再跳到 04:31"。
  Future<void> _applyResume() async {
    if (_resumeApplied || _resumeApplying) return;
    final store = _store ??= widget.resumeStore ?? MediaResumeStore();
    final source = _activeSource;
    if (!source.seekable) {
      // 不可 seek 的源没有"上次的位置"这回事 —— 直接给结论，别再查。
      _resumeApplied = true;
      return;
    }
    // ★★ 真机教训（两条都要）：
    //   ① `setPlaylist` 刚返回时 Media3 **还没报出时长**（`duration == null`）⇒ 时长未知
    //      只表示"**还不知道**"，留待就绪后的那次事件再试（见 `changes` 监听里的调用）；
    //   ② **就绪之前不许 seek**：真机实测在 `ready == false` 时 seek 会让这一条直接
    //      起播失败（界面报"服务端拒绝了这个流"，还会被误判成会话过期）。
    //      所以续播必须等"首帧已就绪"这一拍。
    if (!_adapter.ready) return;
    final total = _adapter.duration;
    if (total == null || total <= Duration.zero) return;
    _resumeApplying = true;
    try {
      final saved = await store.load(source.uri, duration: total);
      _resumeApplied = true;
      if (saved == null || !mounted) return;
      // 用户自己拖过进度 ⇒ 别抢方向盘（只认"用户动作"，不认"现在第几秒"）
      if (_userSeeked) {
        _resumeApplied = true;
        return;
      }
      await _adapter.seekTo(saved);
      if (!mounted) return;
      setState(() => _resumedFrom = saved);
      _resumeBannerTimer?.cancel();
      _resumeBannerTimer = Timer(const Duration(seconds: 10), () {
        if (!mounted) return;
        setState(() => _resumedFrom = null);
      });
    } finally {
      _resumeApplying = false;
    }
  }

  /// 当前进度写回本机记忆（节流；失败静默）。`force` = 暂停/退出时必须落盘。
  void _persistPosition({bool force = false}) {
    final store = _store ??= widget.resumeStore ?? MediaResumeStore();
    final source = _activeSource;
    if (!source.seekable) return;
    // ★★ 真机教训（r636 第五轮）：**续播判定还没落地之前，一个字节都不许写**。
    //   起播那一拍位置是 `00:00`，`save()` 见到"太短"会**清掉**旧值 ⇒
    //   "上次看到 02:47"被自己清成 0，再进来就从 00:00 开始（真机实测过）。
    //   判定完成（`_resumeApplied`）后正常落盘；起播顺带也不再被读盘拖住。
    if (!_resumeApplied) return;
    final total = _adapter.duration;
    if (total == null || total <= Duration.zero) return;
    final pos = _adapter.position;
    if (!force) {
      final last = _lastSavedPosition;
      if (last != null && (pos - last).abs() < const Duration(seconds: 10)) {
        return;
      }
    }
    _lastSavedPosition = pos;
    unawaited(store.save(source.uri, pos, duration: total));
  }

  /// 「从头播放」：清掉记忆、回到 00:00，并把顶部提示收掉。
  Future<void> _startOver() async {
    final store = _store ??= widget.resumeStore ?? MediaResumeStore();
    final source = _activeSource;
    setState(() => _resumedFrom = null);
    await _adapter.seekTo(Duration.zero);
    _lastSavedPosition = Duration.zero;
    await store.clear(source.uri);
  }

  /// **会话续期 → 原地续播**（P0）。
  ///
  /// 触发点 = `changes` 监听里 `classifyPlayerError == sessionExpired`
  /// 且 [shouldRenewSession] 为真（`supportsRange` + 有 [MediaSource.renew]）。
  /// 网络中断走 [MediaUnavailableReason.networkFailed]，**不会**到这里。
  ///
  /// 步骤：重解析新直链 → （目录播放列表也换新凭据）→ 重建播放项 →
  /// seek 回 [_lastKnownPosition] → 继续播。
  ///
  /// **有界 + 指数退避**：最多 [kMediaSessionRenewMaxAttempts] 次，第二次之前
  /// 等 [mediaSessionRenewDelay]。全部失败 → 才显示既有会话失效面板
  /// （带"手动重试"入口）——**绝不**无限循环，也**绝不**静默停住。
  Future<void> _renewAndResume(MediaUnavailableReason reason) async {
    if (_renewing) return;
    _renewing = true;
    final resumeAt = _lastKnownPosition;
    var recovered = false;
    try {
      while (_renewAttempts < kMediaSessionRenewMaxAttempts) {
        if (_renewAttempts > 0) {
          final wait = mediaSessionRenewDelay(_renewAttempts + 1);
          if (wait > Duration.zero) await Future<void>.delayed(wait);
          if (!mounted) return;
        }
        _renewAttempts++;
        try {
          final renew = _activeSource.renew;
          if (renew == null) throw StateError('source has no renewer');
          final fresh = await renew();
          if (!fresh.playable) {
            throw StateError('renew produced an unplayable source');
          }
          _activeSource = fresh;
          await _refreshDirectory();
          await _loadSource();
          // 回到失效前的位置（容差见 [kMediaSessionResumeTolerance]）
          await _adapter.seekTo(resumeAt);
          await _adapter.play();
          recovered = true;
          break;
        } catch (_) {
          // 这一跳失败：还有额度就退避后再试（循环条件），没有就回面板
        }
      }
      if (recovered) {
        _showReconnectedNotice();
      } else if (mounted) {
        _reportPlayUnavailable(_activeSource, reason);
        setState(() => _failure = reason);
      }
    } finally {
      _renewing = false;
      if (mounted) setState(() {});
    }
  }

  /// 续期成功 → **非阻塞**提示（不弹窗打断，自动消失）。
  void _showReconnectedNotice() {
    _reconnectedTimer?.cancel();
    _reconnectedTimer = Timer(kMediaReconnectedNoticeDuration, () {
      if (mounted) setState(() => _reconnected = false);
    });
    if (mounted) setState(() => _reconnected = true);
  }

  /// 这条失败**能不能**给"手动重试"入口。
  ///
  /// 复用 [shouldRenewSession]（会话失效 + 可 seek + 有 renewer）——
  /// 不能 seek 的来源（Drive / 相册 Streaming 腿）**不给假按钮**。
  ///
  /// ★ r633（**DA218**）：**网络层 / 服务端拒绝 / 解码失败也给"重试"**。
  ///
  /// 真机现场：手机上播放中途 Wi-Fi 切到 4G、或服务端短暂 5xx，面板上只有
  /// 「用其他应用打开 / 下载」，**没有"再试一次"** —— 用户唯一能做的动作反而
  /// 不在屏上，只能退出去重进（还得重新找位置）。这三类都是**瞬时**失败
  /// （重拉一次常常就好了），所以给按钮是真有意义的；而
  /// [MediaUnavailableReason.codecUnsupported]、[formatUnsupported] 这类
  /// "这个文件本身解不了"的**不给** —— 那是假按钮（AGENTS §2.0.52）。
  bool _canManualRetry(MediaUnavailableReason reason) {
    if (shouldRenewSession(_activeSource, reason)) return true;
    return switch (reason) {
      MediaUnavailableReason.networkFailed ||
      MediaUnavailableReason.streamRejected ||
      MediaUnavailableReason.decodeFailed ||
      MediaUnavailableReason.tunnelUnavailable => true,
      _ => false,
    };
  }

  /// 用户点「重试」：重置自动预算后**再走一次**完整的续期→续播链。
  ///
  /// 重置预算是明确的：自动路径有界（[kMediaSessionRenewMaxAttempts]），但用户
  /// 主动要求重试时不该被已用掉的额度挡住 —— 每次点击仍然最多
  /// [kMediaSessionRenewMaxAttempts] 次自动尝试，**不会**无限。
  ///
  /// ★ r633（DA218）：不是"会话失效"的那几类走**重载**这条路（重新解析直链 →
  /// 装进播放器 → 回到原来的位置继续）。旧版这里无条件走 `_renewAndResume`，
  /// 对网络/解码类失败等于"什么都没做又失败一次"。
  Future<void> _manualRetry() async {
    if (_renewing) return;
    final reason = _failure ?? _activeSource.reason;
    final resumeAt = _lastKnownPosition;
    _renewAttempts = 0;
    if (mounted) setState(() => _failure = null);
    if (reason == null || shouldRenewSession(_activeSource, reason)) {
      await _renewAndResume(MediaUnavailableReason.sessionExpired);
      return;
    }
    // —— 非会话类：重新装载一次（直链可能已过期 / 网络刚刚恢复）
    await _load();
    if (!mounted || _failure != null) return;
    if (resumeAt > Duration.zero) {
      try {
        await _adapter.seekTo(resumeAt);
      } catch (_) {
        // 位置恢复失败不阻断播放（有些容器首帧前不能 seek）
      }
    }
    try {
      await _adapter.play();
    } catch (err) {
      if (mounted) unawaited(_handleRuntimeFailure(err));
    }
  }

  /// 目录播放列表/外挂字幕的直链也带旧 `_sid` → 续期后重新列一次。
  /// 失败（返回 null）只是丢掉"上一个/下一个"，**不能**让续播失败。
  Future<void> _refreshDirectory() async {
    final entry = widget.entry;
    if (_dir == null || entry == null) return;
    _dir = await loadMediaDirectoryContext(
      fs: ref.read(fileApiProvider),
      entry: entry,
      kind: _activeSource.kind,
      sourceOf: _sourceOf,
    );
  }

  /// 自动匹配同名字幕（有就挂上，失败静默 —— 字幕是增强不是必需）
  Future<void> _autoSubtitle() async {
    final match = _dir?.autoMatch;
    if (match == null || _full == null) return;
    await _applySubtitle(match);
  }

  Future<void> _applySubtitle(SubtitleMatch? match) async {
    final fs = ref.read(fileApiProvider);
    if (match == null || fs == null) {
      if (mounted) {
        setState(() {
          _externalChoice = null;
          _externalTrack = null;
        });
      }
      return;
    }
    final entry = _dir?.subtitleEntries[match.name];
    if (entry == null) return;
    setState(() => _subtitleBusy = true);
    final source = resolveFileStationSource(
      displayName: entry.name,
      kind: widget.source.kind,
      fs: fs,
      path: entry.path,
      size: entry.size,
    );
    final track = await fetchSubtitleTrack(
      api: fs.api,
      source: source,
      match: match,
    );
    if (!mounted) return;
    setState(() {
      _subtitleBusy = false;
      if (track != null && track.cues.isNotEmpty) {
        _externalTrack = track;
        _externalChoice = match;
      } else {
        // 解析不出内容（坏文件 / 不是真字幕）→ 别装作挂上了
        _externalTrack = null;
        _externalChoice = null;
      }
    });
  }

  /// 关掉外挂字幕（回到"内封字幕由 Media3 决定"的状态）
  void _clearExternalSubtitle() {
    if (!mounted) return;
    setState(() {
      _externalTrack = null;
      _externalChoice = null;
      _onlineHit = null;
      _onlineCacheFile = null;
      _onlineFormat = null;
    });
  }

  /// 打开"搜索在线字幕"面板（顶栏/字幕菜单/AppBar 三处入口共用这一个）
  // ── 投屏（r655 · DA264）─────────────────────────────────────────────────

  /// 懒创建控制器 + 一次性订阅：只有真的点过「投屏」才碰网络。
  void _ensureCast() {
    if (_castController != null) return;
    final controller = VideoCastController(
      cast: ref.read(videoCastFactoryProvider)(),
    );
    _castController = controller;
    _castSub = controller.changes.listen((snapshot) {
      if (!mounted) return;
      final wasCasting = _castState.phase == VideoCastPhase.casting;
      setState(() => _castState = snapshot);
      // ★ 投上去就**停本地**（否则手机和电视同时出声），但只在"刚进入投屏"
      //   的那一次动它：之后用户自己按的暂停/继续不该被这里覆盖。
      if (!wasCasting &&
          snapshot.phase == VideoCastPhase.casting &&
          snapshot.remotePlaying &&
          _adapter.playing) {
        unawaited(_adapter.pause());
      }
    });
  }

  /// 失败原因 → 用户能听懂、且能据此决定下一步的一句话。
  String _castReasonText(UpnpCastFailure? failure) {
    switch (failure) {
      case UpnpCastFailure.noRenderer:
        return dataText('mediaCastReasonNoRenderer', '同一网络里没有找到支持投屏的设备。');
      case UpnpCastFailure.unreachable:
        return dataText('mediaCastReasonUnreachable', '设备连不上（可能已关机，或不在同一个网络）。');
      case UpnpCastFailure.rejected:
        return dataText(
          'mediaCastReasonRejected',
          '电视不接受这个视频（格式不支持，或被电视的策略拒绝）。',
        );
      case UpnpCastFailure.playbackFailed:
        return dataText(
          'mediaCastReasonPlaybackFailed',
          '电视拿到了地址却放不出来 —— 它拉不到 NAS 上的视频，检查网络或证书。',
        );
      case null:
        return dataText('mediaCastFailed', '投屏失败');
    }
  }

  Future<void> _openCastSheet() async {
    _ensureCast();
    final controller = _castController!;
    final position = _adapter.position;
    final playing = _adapter.playing;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CastSheet(
        controller: controller,
        reasonText: _castReasonText,
        onStart: (renderer) => controller.start(
          renderer,
          widget.source,
          position: position,
          playing: playing,
        ),
        onStop: controller.stop,
      ),
    );
  }

  Future<void> openSubtitleSearchSheet() async {
    if (_full == null) return;
    final bundle = ref.read(subtitleSearchBundleProvider);
    final keyStore = ref.read(cloudKeyStoreProvider);
    final mediaFileName = widget.entry?.name ?? _currentSource.displayName;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SubtitleSearchSheet(
        mediaFileName: mediaFileName,
        initialQuery: parseMediaFileName(mediaFileName).title,
        bundle: bundle,
        keyStore: keyStore,
        hashProvider: _computeMediaHash,
        onPick: _applyOnlineDownload,
      ),
    );
  }

  /// 媒体"首尾 64KB"指纹（OpenSubtitles 哈希）。
  ///
  /// * 只有在**知道文件大小**且 URL 非空时才算（否则返回 null ⇒ 只按标题搜）；
  /// * 分两次 Range 请求（`maxBytes` / `tailBytes` 在 [DsmWebApi.getBytes] 里
  ///   **互斥**，一次只能要一段）；
  /// * 任何失败都返回 null —— **拿不到指纹就不做哈希匹配**，绝不硬编一个。
  Future<String?> _computeMediaHash() async {
    final size = widget.entry?.size;
    final fs = ref.read(fileApiProvider);
    final uri = _activeSource.uri;
    if (fs == null || size == null || size <= 0 || uri.isEmpty) return null;
    try {
      if (hashNeedsWholeFile(size)) {
        final all = await fs.api.getBytes(uri, maxBytes: size);
        if (all.isEmpty) return null;
        return openSubtitlesHashHex(head: all, tail: const [], fileSize: size);
      }
      final head = await fs.api.getBytes(uri, maxBytes: kSubtitleHashChunk);
      final tail = await fs.api.getBytes(uri, tailBytes: kSubtitleHashChunk);
      if (head.isEmpty || tail.isEmpty) return null;
      return openSubtitlesHashHex(head: head, tail: tail, fileSize: size);
    } catch (_) {
      return null;
    }
  }

  /// 在线字幕下载完 → 挂上（返回 false = 内容解析不出，由面板如实报错）
  Future<bool> _applyOnlineDownload(
    SubtitleSearchHit hit,
    SubtitleDownload download,
    String cacheFileName,
  ) async {
    final track = download.toTrack();
    if (track == null || track.cues.isEmpty) {
      if (mounted) {
        setState(() {
          _onlineBusy = false;
          _onlineHit = null;
          _onlineCacheFile = null;
          _onlineFormat = null;
        });
      }
      return false;
    }
    await _full?.selectSubtitleTrack(null);
    if (!mounted) return true;
    setState(() {
      _onlineBusy = false;
      _externalTrack = track;
      _externalChoice = null;
      _onlineHit = hit;
      _onlineCacheFile = cacheFileName;
      _onlineFormat = download.format;
    });
    final key = _subtitleMemoryKey;
    if (key != null) {
      unawaited(_prefs.saveSubtitle(key, 'online:$cacheFileName'));
    }
    return true;
  }

  /// 把缓存里已有的在线字幕挂回来（菜单里选中"在线字幕"时走这条）
  Future<void> _applyOnlineFromCache(String cacheFileName) async {
    if (cacheFileName.isEmpty) return;
    setState(() => _onlineBusy = true);
    try {
      final download = await ref
          .read(subtitleSearchBundleProvider)
          .cache
          .load(cacheFileName);
      if (!mounted) return;
      final track = download?.toTrack();
      if (track == null || track.cues.isEmpty) {
        setState(() {
          _onlineBusy = false;
          _externalTrack = null;
          _onlineCacheFile = null;
          _onlineFormat = null;
        });
        return;
      }
      setState(() {
        _onlineBusy = false;
        _externalTrack = track;
        _externalChoice = null;
        _onlineCacheFile = cacheFileName;
        _onlineFormat = download!.format;
      });
    } catch (_) {
      // 缓存目录不可用 → 如实清掉（不假装挂上了）
      if (mounted) {
        setState(() {
          _onlineBusy = false;
          _externalTrack = null;
          _onlineCacheFile = null;
          _onlineFormat = null;
        });
      }
    }
  }

  /// r654（`DA259`）：问一次设备支持与否，并订阅"进/出小窗"。
  ///
  /// 不支持就不渲染按钮（**不摆假入口**）；支持也要等 `ready` 之后才出现，
  /// 因为比例要从实际视频取。
  Future<void> _initPip() async {
    final supported = await _pip.supported();
    if (!mounted) return;
    _pip.inPictureInPicture.addListener(_onPipChanged);
    setState(() => _pipSupported = supported);
  }

  void _onPipChanged() {
    if (!mounted) return;
    final inPip = _pip.inPictureInPicture.value;
    if (inPip == _inPip) return;
    setState(() {
      _inPip = inPip;
      // 小窗里不该有整套控件/提示条：进去就收起，出来再叫回来
      if (inPip) {
        _controlsVisible = false;
        _controlsTimer?.cancel();
      } else {
        _controlsVisible = true;
      }
    });
    if (!inPip) {
      // r661（`DA277`）：原生在**出小窗**那一刻会把 autoEnter 清掉并重设参数
      // （否则"暂停→缩窗→放大→再按 Home"会凭旧参数又缩一次）。这边的缓存
      // 必须跟着作废并重新对齐，不然"放大回全屏、继续播、再按 Home"就再也不
      // 缩窗了 —— 那是把缺陷修成功能回退。
      _pipAutoEnter = null;
      unawaited(_syncPipAutoEnter(_adapter.playing));
    }
  }

  /// 播放中允许"按 Home 自动缩成小窗"（Android 12+；低版本原生侧忽略）。
  Future<void> _syncPipAutoEnter(bool playing) async {
    if (!_pipSupported) return;
    if (_pipAutoEnter == playing) return;
    _pipAutoEnter = playing;
    await _pip.setAutoEnter(playing);
  }

  /// 手动进小窗（按钮）。
  Future<void> _enterPip() async {
    final ratio = _adapter.aspectRatio;
    final ok = await _pip.enter(ratio.isFinite && ratio > 0 ? ratio : 16 / 9);
    // 失败的常见原因：系统此刻不允许（权限/后台/正在转场）。**预期失败不崩**，
    // 也不弹错误框 —— 用户再点一次或按 Home 即可。
    if (!mounted || !ok) return;
  }

  /// 有没有"音轨解不了"这件事（`DA260`）。
  ///
  /// 判据钉**当前选中的那条**：有多条音轨时，选中支持的就不该报警；没有选中
  /// 标记时（部分容器）只有在**全都**不支持时才报。
  bool get _audioUnsupported {
    final full = _full;
    if (full == null) return false;
    final tracks = full.audioTracks;
    if (tracks.isEmpty) return false;
    final selectedId = full.selectedAudioTrackId;
    final selected = tracks.where((track) => track.id == selectedId).toList();
    if (selected.isNotEmpty) return !selected.first.isSupported;
    return tracks.every((track) => !track.isSupported);
  }

  /// 当前报警要说的编码（优先选中那条；没有选中就给第一条）
  String get _unsupportedCodec {
    final tracks = _full?.audioTracks ?? const <MediaTrackInfo>[];
    if (tracks.isEmpty) return '';
    final selectedId = _full?.selectedAudioTrackId;
    final selected = tracks.where((track) => track.id == selectedId).toList();
    final codec = (selected.isNotEmpty ? selected.first : tracks.first).codec;
    return codec.isEmpty ? dataText('mediaAudioTrack', '音轨') : codec;
  }

  @override
  void dispose() {
    _reconnectedTimer?.cancel();
    _hudTimer?.cancel();
    _controlsTimer?.cancel();
    _sub?.cancel();
    _resumeBannerTimer?.cancel();
    _reportPlayStopped();
    // `DA227`：退出（含直接 pop 走）也要记住看到哪儿。
    _persistPosition(force: true);
    _positionTick.dispose();
    // 控制器是**进程级共享**（见 `systemVideoPip()`）：这里只摘监听，
    // 不能 dispose —— 否则退出全屏会把预览页那份的事件通道一起清掉。
    _pip.inPictureInPicture.removeListener(_onPipChanged);
    // ★ r661（`DA277`）：**页面没了，"自动进入小窗"必须一起关掉。**
    // 它是写在 Activity 上的参数（`setAutoEnterEnabled`），不随 Flutter 路由
    // 消失；留着它的后果是：用户退出播放器回工作台，按 Home 时系统仍把整个
    // App 缩成小窗 —— 小窗里根本没有视频，用户看到的是"我明明退出了，PiP 还在"。
    _pipAutoEnter = null;
    unawaited(_pip.setAutoEnter(false));
    // 投屏：先摘监听再停投（停止会打设备一次 Stop；设备不在了也不等它）
    _castSub?.cancel();
    final cast = _castController;
    _castController = null;
    if (cast != null) unawaited(cast.dispose());
    // 借来的适配器归预览页所有 —— 在这里 dispose 正是 DA247 的成因
    if (_ownsAdapter) unawaited(_adapter.dispose());
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_adapter.playing) {
      await _adapter.pause();
    } else {
      // 播完/拖到末尾后再点播放：**一次点击**就要从 00:00 起播（视频播放器的
      // 通用行为）。判据带 [kMediaEndReplayTolerance] 容差，别让最后一个位置
      // tick 的偏差吃掉这次 `seekTo(0)`（否则 play() 落在片尾 = 没反应）。
      final total = _adapter.duration;
      if (total != null &&
          total > Duration.zero &&
          _adapter.position + kMediaEndReplayTolerance >= total) {
        await _adapter.seekTo(Duration.zero);
      }
      await _adapter.play();
    }
    if (mounted) setState(() {});
  }

  /// 拖动进度：`onChangeStart` 记状态、`onChangeEnd` 真 seek（并续播）
  void _onDragStart(double v) {
    _userSeeked = true;
    _resumeAfterDrag = _adapter.playing;
    unawaited(_adapter.pause());
    setState(() => _dragValue = v);
  }

  void _onDragUpdate(double v) => setState(() => _dragValue = v);

  Future<void> _onDragEnd(double v) async {
    await _adapter.seekTo(Duration(milliseconds: v.round()));
    setState(() => _dragValue = null);
    if (_resumeAfterDrag) await _adapter.play();
  }

  void _openFullscreen() {
    // ★ r647（**DA247**）：**不再暂停**、也不归还播放器 —— 全屏页借用同一个
    //   适配器（见 [MediaPlayerView.adapter]），进出全屏就是**接着看**。
    //   r646 之前这里先 `pause()` 再 push，全屏页另起一个原生播放器，退出时
    //   把预览页的纹理一起释放掉（真机：黑屏＋进度钉死）。
    // ★ DA30（r384 真机撞到 / r385 修）：这里原来传 `widget.source`
    // ——「**打开播放器时**那一条」。于是自动续播或「下一个」换集之后再点
    // 「全屏」，全屏页会退回**第一集**。真机读数：内嵌顶栏已是
    // `60招基础街球S01E01.AVI`（AVI 真出画），点全屏后全屏页标题与画面
    // 都变回 `01_1._The_Rate_of_Chemical_Reactions__10-12.mp4` 的片头。
    // 口径与顶栏/回退面板**同一个**：当前播放项只许取 [_currentSource]
    // （R5 已经在标题上踩过同一个坑）；并把**同一份播放列表 + 当前下标**
    // 交给全屏页（相册页 `photo_viewer_page.dart` 就是这个传法），
    // 让全屏页能接着往下换集，而不是只认识打开时那一条。
    final items = _playlistItems;
    final current = _currentSource;
    final index = items == null
        ? 0
        : items.indexWhere((s) => s.uri == current.uri);
    openMediaPlayer(
      context,
      source: current,
      entry: widget.entry,
      playlist: items,
      playlistIndex: index < 0 ? 0 : index,
      onOpenExternal: widget.onOpenExternal,
      onDownload: widget.onDownload,
      adapter: _adapter,
    );
  }

  /// 当前该显示的字幕文本：**外挂优先**（用户手选的），否则用 Media3 给的内封文本
  String? get _subtitleText {
    final external = _externalTrack;
    if (external != null) return external.textAt(_adapter.position);
    return _full?.embeddedSubtitleText;
  }

  /// 当前引擎**自己画字幕**（`DA269`：兜底引擎 libmpv 就是这样）。
  ///
  /// 这时我们的浮层插不上手：字号/背景条/垂直偏移都只对自家浮层生效 ⇒
  /// 那几行控件必须**藏起来**（宁可少给，也不给"调了没反应"的假控件）。
  bool get _engineDrawsOwnSubtitles {
    final full = _full;
    return full is MediaPlayerSelfRenderedSubtitles &&
        (full as MediaPlayerSelfRenderedSubtitles).rendersOwnSubtitles;
  }

  /// 现在要不要摆"字幕位置 / 背景条"这两行（r656 · `DA271`）。
  ///
  /// 判据钉**有没有字幕**，不钉"谁画的字幕"：
  ///   * 外挂/在线字幕在手上 ⇒ 有（哪怕这一帧恰好没有字）；
  ///   * 主引擎给了内封文本 ⇒ 有；
  ///   * 兜底引擎（mpv 自己画）⇒ 看**有没有选中字幕轨**（它的文本不上报）。
  /// 只要"有"，一个实现了 [MediaPlayerSubtitleStyling] 的引擎就会照这两项去画。
  bool get _subtitleAdjustable {
    // 引擎自己画、又**听不懂**这两项 ⇒ 摆出来就是假控件（`DA269` 的反向守卫）。
    if (_engineDrawsOwnSubtitles && _adapter is! MediaPlayerSubtitleStyling) {
      return false;
    }
    if (_externalTrack != null) return true;
    final text = _subtitleText;
    if (text != null && text.isNotEmpty) return true;
    final full = _full;
    return full != null && full.selectedSubtitleTrackId != null;
  }

  /// r656（`DA270`）：把本机记住的字幕样式读回来（一次，进页面时）。
  ///
  /// 读失败/没存过 ⇒ 保持默认（原样 + 无背景条），**不提示、不报错**：
  /// 记不住偏好是小事，不该在播放页上弹一个错误条。
  Future<void> _loadSubtitleStyle() async {
    MediaSubtitleStyle style = MediaSubtitleStyle.defaults;
    try {
      style = await _prefs.loadSubtitleStyle();
    } catch (_) {
      // 偏好读不出来 ⇒ 用默认（不允许影响播放）
    }
    if (!mounted) return;
    setState(() {
      _subtitleOffset = normalizeMediaSubtitleOffset(style.offset);
      _subtitleBackground = style.background;
      _subtitleStyleLoaded = true;
    });
    await _applySubtitleStyle();
  }

  /// 把当前位置/背景条交给**能听懂的引擎**（主引擎的字幕是我们自己画的，不需要）。
  Future<void> _applySubtitleStyle() async {
    // dispose 之后不需要、也不该再动引擎（DA329）。
    if (!mounted) return;
    final adapter = _adapter;
    if (adapter is! MediaPlayerSubtitleStyling) return;
    try {
      await (adapter as MediaPlayerSubtitleStyling).setSubtitleStyle(
        offsetPx: _subtitleOffset.round(),
        background: _subtitleBackground,
      );
    } catch (_) {
      // 引擎不认这项设置 ⇒ 只是这一项没生效，播放照常
    }
  }

  /// 落盘（用户改一次存一次；`DA270` 之前这两项退出页面就丢）
  void _saveSubtitleStyle() {
    // 偏好还没读回来时**不许**回写 —— 否则"打开页面"就把用户存的 +80 冲成 0。
    if (!_subtitleStyleLoaded) return;
    unawaited(
      _prefs.saveSubtitleStyle(
        MediaSubtitleStyle(
          offset: _subtitleOffset,
          background: _subtitleBackground,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 标题/面板一律取**当前播放项**（换集、自动续播都跟随；R5 的标题瑕疵）
    final source = _currentSource;
    // 来源本身就不能播（空 URL / 隧道 / 证书固定 / Drive 视频 …）→ 直接给回退面板
    final sourceReason = _activeSource.reason;
    if (sourceReason != null) {
      return MediaFallbackPanel(
        source: source,
        reason: sourceReason,
        onOpenExternal: widget.onOpenExternal,
        onDownload: widget.onDownload,
        onRetry: _canManualRetry(sourceReason) ? _manualRetry : null,
      );
    }
    // 播放器运行时失败（编码不支持 / 握手失败 …）
    final failure = _failure;
    if (failure != null) {
      return MediaFallbackPanel(
        source: source,
        reason: failure,
        onOpenExternal: widget.onOpenExternal,
        onDownload: widget.onDownload,
        // 有界重试用尽后的**手动**出口（不能 seek / 没有 renewer 时不出现）
        onRetry: _canManualRetry(failure) ? _manualRetry : null,
      );
    }
    if (!_adapter.ready) {
      // 载入中：有内嵌封面就把封面当**海报**垫在下面（音频尤其受益）；
      // 没有内嵌封面时用**服务端缩略图**兜底（相册视频/无内嵌封面的容器）；
      // 两级都没有 → 明确占位（不是空白框）。
      // ★ r678（`DA311`）：libmpv 没纹理就不解码 ⇒ 载入期间也要把画面挂上。
      // 判据是**能力接口**（不是具体类）：视频条 + 引擎自己说要。
      final needsSurfaceEarly =
          widget.source.kind == MediaKind.video &&
          _adapter is MediaPlayerNeedsSurfaceWhileLoading &&
          (_adapter as MediaPlayerNeedsSurfaceWhileLoading)
              .needsSurfaceWhileLoading;
      final entry = widget.entry;
      final thumb = entry == null
          ? null
          : ref
                .watch(
                  fileThumbProvider(
                    FileThumbRequest.of(entry, ThumbScale.large),
                  ),
                )
                .value;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (needsSurfaceEarly)
            // 引擎正在等纹理（libmpv）：先给一块黑 + 真 surface，转圈盖在上面
            Positioned.fill(
              child: KeyedSubtree(
                key: const Key('media-video-surface'),
                child: _surface(context),
              ),
            )
          else
            MediaCoverBackdrop(
              request: mediaCoverKeyOfSource(source),
              thumbBytes: thumb,
              fallback: const Center(child: MediaCoverPlaceholder()),
            ),
          const Center(child: CircularProgressIndicator()),
        ],
      );
    }
    final continuationNotice = _continuationNotice;
    // ★ r658（`DA273`）：宿主页不再有 AppBar ⇒ 提示条直接顶到屏幕最上沿，
    //   和状态栏的图标叠字。这里只给**提示条**让出状态栏高度（画面本身照旧
    //   铺满，不让位）；没有提示条时一个像素都不占。
    final bannerInset =
        (!_inPip &&
            (_reconnected ||
                continuationNotice ||
                _resumedFrom != null ||
                _audioUnsupported))
        ? MediaQuery.paddingOf(context).top
        : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (bannerInset > 0) SizedBox(height: bannerInset),
        // 小窗里只留画面（`DA259`）：提示条会把"视频"挤成一条缝
        // 会话续期成功的**非阻塞**提示：不弹窗、不打断，几秒后自己消失
        if (!_inPip && _reconnected) _reconnectedBanner(context),
        // 自动续播进入的条目零画面证据 → **非阻塞**提示，绝不允许静默黑屏
        // （R5 真实漏报路径）。只有自研原生播放器的看门狗会给这条。
        if (!_inPip && continuationNotice) _continuationBanner(context, source),
        // `DA227` 续播提示：**可撤销**（用户想从头看就点一下），不是通知弹窗
        if (!_inPip && _resumedFrom != null)
          _resumeBanner(context, _resumedFrom!),
        // `DA260`：音轨本机解不了 → 说明"为什么没声音"并给两条出路
        if (!_inPip && _audioUnsupported)
          _audioUnsupportedBanner(context, source),
        Expanded(
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              children: [
                Positioned.fill(
                  child: KeyedSubtree(
                    key: const Key('media-video-surface'),
                    child: _surface(context),
                  ),
                ),
                // ★ r438：本条**零画面证据**时盖黑上一条留在 surface 上的残帧。
                //
                // r437 真机读数：自动续播到"只有音轨、没有视频流"的条目时，顶栏已是**新条目**、
                // 提示条也在，而画面区仍是**上一条的最后一帧**（`px(574,1400)=(0,0,244)` 纯蓝）。
                // Media3 在新条目渲染出自己的第一帧之前**不清面**，所以"提示说本条播不了、
                // 画面却是上一条"是自相矛盾的观感 —— 用户会以为播错了东西。
                // 这里只盖**画面区**：提示条、控制条、音频播放都不受影响（音频本来就该继续）。
                if (continuationNotice)
                  const Positioned.fill(
                    child: IgnorePointer(
                      // 不透光的黑：半透明挡不住残帧（用例量 `color.a == 1.0`）
                      child: ColoredBox(
                        key: Key('media-no-picture-blackout'),
                        color: Colors.black,
                      ),
                    ),
                  ),
                // 播放中缓冲：转圈但**不算**"未就绪"（原生 buffering 位）
                if (_buffering)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            key: Key('media-buffering'),
                            strokeWidth: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                // 播放器内调光（左半竖直滑动）——见 `_dimOpacity` 的说明
                if (_dimOpacity > 0)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(
                        key: const Key('media-dim-overlay'),
                        color: Colors.black.withValues(alpha: _dimOpacity),
                      ),
                    ),
                  ),
                Positioned(
                  left: Gap.md,
                  right: Gap.md,
                  // 垂直偏移是**加在默认基线之上**的（不替换默认值）：这样
                  // "控件条弹出时抬一点"仍然是同一套语义，不会因为偏移而互相打架。
                  bottom: (_controlsVisible ? 96 : Gap.md) + _subtitleOffset,
                  child: _SubtitleOverlay(
                    key: const Key('media-subtitle-text'),
                    text: _subtitleText,
                    scale: _subtitleScale,
                    background: _subtitleBackground,
                  ),
                ),
                // 手势层在字幕之上、控件之下：中间那块空白归它，
                // 控件条自己的按钮仍然优先拿到点击（它在更上层）。
                //
                // ★ r654 真机（**DA261**）：小窗里**不许**再吃点击。
                //   第一次真机验收时，小窗里点一下画面就把视频 seek 走了
                //   （画面直接跳到十几分钟后），而系统的"放大/关闭"控件
                //   同时挂在上面 —— 用户点"放大"会先被我们当"右半屏快进"。
                //   PiP 里手势一律让给系统：放大、关闭、拖动小窗都归它。
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: _inPip,
                    child: _gestureLayer(context),
                  ),
                ),
                if (_hud != null) Center(child: _gestureHud(context)),
                if (_controlsVisible && !_inPip)
                  Positioned.fill(child: _controlsOverlay(context)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// `DA260`：**音轨本机解不了**时说明"为什么没声音"。
  ///
  /// 现场（r654 复核）：NAS 影视库里 AC3/EAC3/DTS 是高频音轨，vanilla Media3
  /// 没有这些的**软件**解码器、设备也没有硬解 ⇒ ExoPlayer 照常出画面但不发声。
  /// 之前界面上这条音轨与普通音轨长得一样，用户只会得出"这个 App 播放没声音"
  /// —— 这类"静默失败"比报错更伤人：报错至少知道该换播放器。
  ///
  /// 形态沿用既有提示条（顶部一条、不挡控件），但**不是几秒消失**：
  /// 只要这条音轨还没换掉，事实就一直成立。出路按"能不能自己解决"排序：
  /// ① 有别的可解音轨 → 「换一条音轨」；② 没有 → 「用其他应用打开」。
  Widget _audioUnsupportedBanner(BuildContext context, MediaSource source) {
    final theme = Theme.of(context);
    final t = context.t;
    final tracks = _full?.audioTracks ?? const <MediaTrackInfo>[];
    final switchable = tracks.any(
      (track) => track.isSupported && track.id != _full?.selectedAudioTrackId,
    );
    final message = dataText(
      'mediaAudioUnsupported',
      '这台设备播不了这条音轨（{codec}），会有画面没声音。',
    ).replaceAll('{codec}', _unsupportedCodec);
    return Material(
      key: const Key('media-audio-unsupported'),
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.only(
          left: Gap.md,
          right: Gap.xs,
          top: Gap.xs,
          bottom: Gap.xs,
        ),
        child: Row(
          children: [
            Icon(
              Icons.volume_off_outlined,
              size: 16,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            if (switchable)
              TextButton(
                key: const Key('media-audio-unsupported-switch'),
                onPressed: () => unawaited(_pickAudioTrack(t, _full!)),
                child: Text(t.mediaAudioUnsupportedSwitch),
              )
            else if (widget.onOpenExternal != null)
              TextButton(
                key: const Key('media-audio-unsupported-external'),
                onPressed: widget.onOpenExternal,
                child: Text(context.t.photoOpenWithOther),
              ),
          ],
        ),
      ),
    );
  }

  /// 会话续期成功的**非阻塞**提示条（自动消失；播放器与控制条照常可用）。
  ///
  /// 为什么用"条"而不是 toast/弹窗：媒体页既有习惯就是顶部一条
  /// [Key]`media-continuation-notice`（自动续播零画面证据），复用同一形态
  /// 用户不会误以为"又出错了"；而且 [MediaPlayerView] 也可能被嵌在没有
  /// `Scaffold` 的预览页里，`ScaffoldMessenger` 的 SnackBar 不保证有宿主。
  Widget _reconnectedBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('media-session-reconnected'),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.md,
          vertical: Gap.xs,
        ),
        child: Row(
          children: [
            Icon(
              Icons.wifi_tethering,
              size: 16,
              color: DesignPalette.of(context).dim,
            ),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(
                mediaSessionReconnectedNotice(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `DA227`「已从 4:31 继续播放 · 从头播放」。
  ///
  /// 为什么要这条提示：**没有提示的"自动跳转"比"从头播"更让人困惑** ——
  /// 用户会以为自己刚才看的位置丢了、或者点错了片子。给出读数 + 一个撤销入口，
  /// 这个行为才从"播放器自作主张"变成"帮我接着看"。
  /// 形态与 [_reconnectedBanner] 一致（顶部一条、不挡控件），并且 10 s 后自己收，
  /// 不长期占着画面。
  Widget _resumeBanner(BuildContext context, Duration at) {
    final theme = Theme.of(context);
    // ★ r636 真机：只把「从头播放」做成一个 `TextButton` 时，真机上照着画出来的位置
    //   点下去**没反应**（连点三次，像素上一个字节都没变，见台账 §4）。人不会去猜
    //   "哪一小块才是按钮" —— 所以**整条提示都能点**：点哪儿都是从头上。
    //   高度也按 48dp 最小点击区给足（`ConstrainedBox`），不再依赖一行小字。
    return Material(
      key: const Key('media-resume-banner'),
      color: theme.colorScheme.secondaryContainer,
      child: InkWell(
        key: const Key('media-resume-banner-tap'),
        onTap: () => unawaited(_startOver()),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.only(
              left: Gap.md,
              right: Gap.md,
              top: Gap.xs,
              bottom: Gap.xs,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.history,
                  size: 16,
                  color: DesignPalette.of(context).dim,
                ),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    dataText(
                      'mediaResumedFrom',
                      '已从 {time} 继续播放',
                    ).replaceAll('{time}', _formatClock(at)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Text(
                  key: const Key('media-resume-start-over'),
                  dataText('mediaStartOver', '从头播放'),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 自动续播零画面证据的顶栏提示（非阻塞：播放器与控制条仍在，只是加一行说明）。
  Widget _continuationBanner(BuildContext context, MediaSource source) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('media-continuation-notice'),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.md,
          vertical: Gap.xs,
        ),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: 16,
              color: DesignPalette.of(context).dim,
            ),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(
                mediaAutoContinueNotice(source.displayName),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (widget.onOpenExternal != null)
              TextButton(
                key: const Key('media-continuation-open-external'),
                onPressed: widget.onOpenExternal,
                child: Text(context.t.photoOpenWithOther),
              ),
          ],
        ),
      ),
    );
  }

  /// 画面本体 + 画面比例。
  ///
  /// 有完整控制时按 [MediaAspectMode] 铺开（语义表见 `media_tracks.dart`）；
  /// 没有（`video_player` 回退）就保持老行为：`AspectRatio` 居中 contain。
  Widget _surface(BuildContext context) {
    final surface = _adapter.buildSurface(context);
    final full = _full;
    if (full == null) {
      return Center(
        child: AspectRatio(aspectRatio: _adapter.aspectRatio, child: surface),
      );
    }
    return MediaAspectSurface(
      mode: full.aspectMode,
      aspectRatio: _adapter.aspectRatio,
      child: surface,
    );
  }

  /// 是否真的在缓冲（只有自研原生播放器有这个位；`video_player` 回退没有）
  bool get _buffering {
    final adapter = _adapter;
    return adapter is NativeVideoPlayerAdapter && adapter.buffering;
  }

  /// 控件层：顶部标题栏（仅**内嵌**时）+ 底部控制条。
  ///
  /// 本层**没有背景**，中间空出来的区域不拦点击 ⇒ 单击/双击/竖直滑动都落到
  /// 下面的 [_gestureLayer]（与 MX Player / VLC 的手感一致）。
  Widget _controlsOverlay(BuildContext context) {
    return Stack(
      children: [
        // ★ r650（`DA250`）：全屏页也画这条浮层顶栏（返回/标题/更多），
        //   它和底部控制条一起显隐 —— 不再有"常驻 AppBar"永久吃高度。
        Positioned(top: 0, left: 0, right: 0, child: _topBar(context)),
        Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar(context)),
      ],
    );
  }

  /// 播放器内的顶部条（**只在 `Column` 模式/内嵌时显示**）。
  ///
  /// ★ 这里**故意不重复文件名**：内嵌视图的宿主页（文件预览页 / 相册预览）
  /// 自己的顶栏已经显示"当前播放项"，再来一份就成了两份标题 —— 实测会把既有
  /// 用例 `media_photos_download_test.dart`「顶栏标题跟随当前播放项」打成
  /// "Found 2 widgets with text"。所以：
  ///   * **全屏页**的"返回 + 文件名 + 更多"由 [MediaPlayerPage] 的 `AppBar`
  ///     提供（那里才是真正的路由返回，文件名在 title 上）；
  ///   * **内嵌**时这里只留"更多 ⋮ + 隐藏控件"，标题归宿主页。
  Widget _topBar(BuildContext context) {
    final full = _full;
    // ★ r650（**DA250**，真机 2026-10-24）：横屏全屏页原本顶着一条**常驻 56dp
    //   AppBar** ＋ 状态栏（合计约 80dp），画面无论看不看控件都被永久压掉一截 ——
    //   而顶栏的信息（返回 / 标题 / 更多）本来就该跟控制条一起显隐。
    //   现在：全屏页**没有** AppBar，这一条浮层顶栏承担「返回 ＋ 标题 ＋ 更多」，
    //   与底下的控制条同生同灭（`_controlsVisible` 控制整层）。
    final actions = FoldingActions(
      children: [
        // 复合控件放最前：`FoldingActions` 折叠的是**尾部 IconButton**，
        // 尾部若混进 `PopupMenuButton<T≠int>` 会被丢掉（见该文件注释）。
        if (full != null) _moreMenu(context, full),
        IconButton(
          key: const Key('media-hide-controls'),
          tooltip: dataText('mediaHideControls', '隐藏控件'),
          icon: const Icon(Icons.visibility_off_outlined, color: Colors.white),
          onPressed: _toggleControls,
        ),
      ],
    );
    return Container(
      key: const Key('media-top-bar'),
      alignment: Alignment.topRight,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x99000000), Color(0x00000000)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Gap.sm, Gap.lg),
      child: (widget.isFullscreen || widget.hostChrome)
          // ★ r658（`DA273`）：宿主页不再有 AppBar ⇒ 这一条顶栏可能贴在状态栏
          //   下面。SafeArea 只吃"当前还剩多少 inset"（全屏页外层已经吃过一次，
          //   这里看到的是 0），所以两种入口都只让开一次。
          ? SafeArea(
              bottom: false,
              child: Row(
                children: [
                  IconButton(
                    key: const Key('media-top-back'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: widget.isFullscreen
                        ? widget.onExitFullscreen
                        : widget.onBack,
                  ),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(
                      mediaNameWithoutExtension(_currentSource.displayName),
                      key: const Key('media-top-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: Gap.xs),
                  actions,
                ],
              ),
            )
          : actions,
    );
  }

  /// 内嵌顶栏的「更多 ⋮」：画面比例 / 音轨 / 倍速 / 在线字幕。
  ///
  /// 底部条上这些是弹出菜单；在窄屏上想要"一个入口全都有"时走这里。
  Widget _moreMenu(BuildContext context, MediaPlayerFullControls full) {
    final t = context.t;
    return PopupMenuButton<String>(
      key: const Key('media-more'),
      tooltip: dataText('mediaMore', '更多'),
      icon: const Icon(Icons.more_vert, color: Colors.white),
      onSelected: (id) {
        switch (id) {
          case 'subtitle':
            unawaited(openSubtitleSearchSheet());
          case 'aspect':
            unawaited(_pickAspect(t, full));
          case 'audio':
            unawaited(_pickAudioTrack(t, full));
          case 'speed':
            unawaited(_pickSpeed(full));
          case 'transcript':
            unawaited(_openSubtitleTranscript());
          case 'download':
            widget.onDownload?.call();
          case 'external':
            widget.onOpenExternal?.call();
        }
      },
      itemBuilder: (_) => [
        // ★ r637：外挂字幕载入后才有「字幕全文」（内封拿不到整条轨道 ⇒ 不摆假入口）
        if (_externalTrack != null && _externalTrack!.cues.isNotEmpty)
          PopupMenuItem(
            value: 'transcript',
            child: Text(context.t.mediaSubtitleTranscript),
          ),
        PopupMenuItem(
          value: 'subtitle',
          child: Text(dataText('mediaSubtitleSearchEllipsis', '搜索在线字幕…')),
        ),
        PopupMenuItem(value: 'aspect', child: Text(t.mediaAspect)),
        PopupMenuItem(value: 'audio', child: Text(t.mediaAudioTrack)),
        PopupMenuItem(
          value: 'speed',
          child: Text(
            dataText(
              'mediaSpeedValue',
              '倍速 {speed}x',
            ).replaceAll('{speed}', '${_adapter.speed}'),
          ),
        ),
        // ★ r658（`DA273`）：宿主页那条 AppBar 退场后，"下载 / 用其他应用打开"
        //   这两个动作必须还有地方摆 —— 搬进这里（只在宿主真给了回调时才出现，
        //   相册幻灯片等没有这两个动作的入口不会多出无效项）。
        if (widget.onDownload != null)
          PopupMenuItem(
            key: const Key('media-more-download'),
            value: 'download',
            child: Text(t.dtoActionDownload),
          ),
        if (widget.onOpenExternal != null)
          PopupMenuItem(
            key: const Key('media-more-external'),
            value: 'external',
            child: Text(t.photoOpenWithOther),
          ),
      ],
    );
  }

  /// 通用"选一个"底部面板（顶栏 ⋮ 用；底部条上仍是弹出菜单）
  Future<void> _pickSheet<T>({
    required String title,
    required List<T> values,
    required String Function(T value) label,
    required bool Function(T value) selected,
    required Future<void> Function(T value) onPick,
  }) async {
    final picked = await showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            DesignRowTile(dense: true, enabled: false, title: Text(title)),
            for (final value in values)
              DesignRowTile(
                dense: true,
                selected: selected(value),
                title: Text(label(value)),
                onTap: () => Navigator.of(ctx).maybePop(value),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await onPick(picked);
  }

  Future<void> _pickAspect(AppText t, MediaPlayerFullControls full) =>
      _pickSheet(
        title: t.mediaAspect,
        values: MediaAspectMode.values,
        label: (mode) => _aspectLabel(t, mode),
        selected: (mode) => full.aspectMode == mode,
        onPick: full.setAspectMode,
      );

  /// 顶栏 `⋮` → 音轨面板。
  ///
  /// ★ r424（DA82）改两处，改前真机取证见 `docs/android-ui-audit-r424.md`：
  /// ① **不再复用字幕的 "Subtitles off"** —— 那是"关闭字幕"的文案，
  ///    画在"音轨"面板里是明摆着的错话；底部条那个弹出菜单本来就没有这个
  ///    "清空选择"项（只列轨道，空时给 `mediaNoTracks`），两个入口现在一致；
  /// ② 每行加 **`#列表序号`** 前缀 ＋ `detail`（编码 · 声道）——容器不给
  ///    标题/语言时旧实现两行都是同一串 `mp4a.40.2`，用户根本分不清哪条是哪条
  ///    （`displayLabel` 的兜底 `#n` 只在 label/language/codec **全空**时才轮到）。
  Future<void> _pickAudioTrack(AppText t, MediaPlayerFullControls full) {
    final tracks = full.audioTracks.toList(growable: false);
    if (tracks.isEmpty) {
      return _pickSheet<String>(
        title: t.mediaAudioTrack,
        values: const [''],
        label: (_) => t.mediaNoTracks,
        selected: (_) => false,
        onPick: (_) => full.selectAudioTrack(null),
      );
    }
    return _pickSheet<String?>(
      title: t.mediaAudioTrack,
      values: [for (final track in tracks) track.id],
      label: (id) {
        final i = tracks.indexWhere((track) => track.id == id);
        if (i < 0) return id ?? '';
        return _trackPickLabel(i, tracks[i]);
      },
      selected: (id) => full.selectedAudioTrackId == id,
      onPick: full.selectAudioTrack,
    );
  }

  /// 音轨面板一行的文本：`#列表序号 · 显示名 · [编码] · [声道]`。
  ///
  /// 编码只在"显示名不是编码"时补一遍（`displayLabel` 兜底本来就是编码，
  /// 否则会出现 `mp4a.40.2 · mp4a.40.2` 这种重复）。
  String _trackPickLabel(int index, MediaTrackInfo track) {
    // ★ r645（DA243 的连带）：`displayLabel` 在容器没给标题/语言时**本身就是**
    //   `#n`（编码不再当名字），所以这里再无条件加一个 `#列表序号` 会印出
    //   `#1 · #1 · mp4a.40.2`。只有"显示名不是这个序号"时才补前缀。
    final ordinal = '#${index + 1}';
    final name = track.displayLabel;
    // 兜底序号（`#1`）用的是 Media3 的 `trackIndex`，与**列表序号**是两套口径
    // （自动生成的字幕轨会占号），两个都给会印出 `#2 · #1 · …`。列表里统一用列表序号。
    final isOrdinal = RegExp(r'^#\d+$').hasMatch(name);
    final parts = <String>[if (!isOrdinal) ordinal, isOrdinal ? ordinal : name];
    if (track.codec.isNotEmpty && track.codec != track.displayLabel) {
      parts.add(track.codec);
    }
    if (track.channels > 0) parts.add('${track.channels} ch');
    // ★ r654（DA260）：解不了的音轨**在菜单里就说清楚**，别等用户选中后
    //   才发现没声音（那时他已经"看过画面"了，只会觉得播放器坏了）。
    if (!track.isSupported) {
      parts.add(dataText('mediaTrackUnsupported', '本机不支持'));
    }
    return parts.join(' · ');
  }

  Future<void> _pickSpeed(MediaPlayerFullControls full) => _pickSheet<double>(
    title: dataText('mediaSpeed', '倍速'),
    values: kMediaSpeeds,
    label: (speed) => '${speed}x',
    selected: (speed) => speed == _adapter.speed,
    onPick: _setSpeed,
  );

  /// 底部控制条：时间 + 进度（可拖）+ 一排动作 + 音量。
  ///
  /// ★ 动作那一排走 [FoldingActions]（AGENTS §2.0.10 铁律 1）：动作数量是**条件
  /// 渲染**出来的（有没有完整控制、能不能 seek、是不是全屏页），放不下时折叠进
  /// `⋮`，绝不会像真机那样"按钮叠到返回键上"。复合控件（4 个弹出菜单）必须排在
  /// 前面 —— 折叠的是尾部 IconButton，尾部混进 `PopupMenuButton<T≠int>` 会被丢掉。
  /// 底部控制条（第 630 轮重做）。
  ///
  /// **为什么要重做**（真机 2026-10-23 拍到的现场，`docs/evidence-r630/`）：
  ///   * 旧版把「上一集 / -10s / 播放 / +10s / 下一集 / 静音 / 全屏」**全部**
  ///     塞进一行 `FoldingActions`，窄屏下**播放键被折进 `⋮`** —— 用户看到的是
  ///     `1.0x / 画面比例 / 音轨 / 字幕 / ⋮ / 音量`，最主要的动作得开菜单才能点；
  ///   * 顶栏还有一个 `⋮`，两个溢出菜单内容重叠；
  ///   * 一条 `Slider` 既当进度条又当拖拽目标，拖动时**只动滑块**，不告诉你要去哪。
  ///
  /// **新版三行结构**（YouTube / Netflix / MX Player 的通行做法）：
  ///   ① 进度区：当前时间 ＋ 粗触控区进度条 ＋ 总时长；拖动时上方浮出目标时间气泡；
  ///   ② 主控区：上一集 / -10s / **大播放键** / +10s / 下一集 —— **永不折叠**；
  ///   ③ 次控区：倍速 / 画面比例 / 音轨 / 字幕 / 静音 / 在线字幕 / 旋转 / 全屏 ＋ 音量。
  ///
  /// 键位全部沿用（`media-play-pause` 等 16 个），既有用例不动；新增
  /// `media-primary-row` / `media-center-play` / `media-seek-bubble` /
  /// `media-time-current` / `media-time-total` 供新版用例断言。
  Widget _bottomBar(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final full = _full;
    final total = _adapter.duration;
    final maxMs = total == null ? 0.0 : total.inMilliseconds.toDouble();
    final posMs = (_dragValue ?? _adapter.position.inMilliseconds.toDouble())
        .clamp(0.0, maxMs <= 0 ? 0.0 : maxMs);
    // 拖不动就别给假希望（Drive 写死 Accept-Ranges: none，调研 §3.4）
    final canSeek = _activeSource.seekable && total != null && maxMs > 0;
    // 快进/快退也要能 seek；没有完整控制就不显示这两个按钮
    final canSkip = full != null && canSeek;
    // ★ r630：次控行**只放 `IconButton`**（可折叠）。
    //   旧版把 4 个 `PopupMenuButton`（倍速/比例/音轨/字幕）排在行里，
    //   而它们**永不能折叠** ⇒ 360dp 真机必溢出（单元测试实测
    //   `A RenderFlex overflowed by 2.4 pixels`）。现在它们进了下面这个
    //   带文字的「播放设置」面板（YouTube 齿轮那种），行里只剩一个齿轮。
    final secondary = <Widget>[
      _compactIcon(
        key: const Key('media-settings'),
        tooltip: context.t.photoPlaybackSettings,
        icon: Icons.tune_rounded,
        onPressed: () => unawaited(_openSettingsSheet()),
      ),
      if (full != null)
        _compactIcon(
          key: const Key('media-mute'),
          tooltip: (full.muted || full.volume == 0)
              ? t.mediaUnmute
              : t.mediaMute,
          icon: _volumeIcon(full),
          // `DA249`：**"没声音"有两种**（静音标记 / 音量 0），按键只认
          // "现在听不听得见" —— 听不见就把它叫回来，而不是再置一次静音标记。
          onPressed: () =>
              unawaited(full.setMuted(!(full.muted || full.volume == 0))),
        ),
      if (full != null)
        _compactIcon(
          key: const Key('media-online-subtitle'),
          tooltip: dataText('mediaSubtitleSearch', '搜索在线字幕'),
          icon: Icons.travel_explore_outlined,
          onPressed: () => unawaited(openSubtitleSearchSheet()),
        ),
      // r655（DA264）：投屏 —— 只在**视频**上出现（音频走音频页那条路）。
      // 播放器没就绪时不给：这条路的输入必然是"当前在播的这条直链"。
      if (widget.source.kind == MediaKind.video && _adapter.ready)
        _compactIcon(
          key: const Key('media-cast'),
          tooltip: dataText('mediaCast', '投屏'),
          icon: _castState.phase == VideoCastPhase.casting
              ? Icons.cast_connected
              : Icons.cast,
          onPressed: () => unawaited(_openCastSheet()),
        ),
      // r654（DA259）：画中画 —— 和全屏同一排（都是"把画面换个地方"）。
      // 只在设备真支持、且播放器已就绪时出现：不支持不摆假按钮。
      if (_pipSupported && !_inPip && _adapter.ready)
        _compactIcon(
          key: const Key('media-pip'),
          tooltip: t.mediaPip,
          icon: Icons.picture_in_picture_alt_outlined,
          onPressed: () => unawaited(_enterPip()),
        ),
      if (widget.isFullscreen) ...[
        if (widget.onRotate != null)
          _compactIcon(
            key: const Key('media-rotate'),
            tooltip: t.mediaRotate,
            icon: Icons.screen_rotation_outlined,
            onPressed: widget.onRotate,
          ),
        _compactIcon(
          key: const Key('media-exit-fullscreen'),
          tooltip: t.mediaExitFullscreen,
          icon: Icons.fullscreen_exit,
          onPressed: widget.onExitFullscreen,
        ),
      ] else if (widget.showFullscreenButton)
        _compactIcon(
          key: const Key('media-fullscreen'),
          tooltip: t.mediaFullscreen,
          icon: Icons.fullscreen,
          onPressed: _openFullscreen,
        ),
    ];
    final primary = <Widget>[
      if (full != null)
        _compactIcon(
          key: const Key('media-prev'),
          tooltip: t.mediaPrevious,
          icon: Icons.skip_previous_rounded,
          onPressed: full.hasPrevious
              ? () => unawaited(full.playPrevious())
              : null,
        ),
      if (full != null)
        _compactIcon(
          key: const Key('media-back10'),
          tooltip: t.mediaBackward10,
          icon: Icons.replay_10_rounded,
          onPressed: canSkip
              ? () => unawaited(full.skipBy(-kMediaSkipStep))
              : null,
        ),
      // ★ 主键：56dp 实心圆，永远在这一行中央，**不参与折叠**
      SizedBox(
        width: 56,
        height: 56,
        child: IconButton.filled(
          key: const Key('media-play-pause'),
          onPressed: _toggle,
          tooltip: _adapter.playing ? t.fileMediaPause : t.fileMediaPlay,
          iconSize: 32,
          icon: Icon(
            _adapter.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
        ),
      ),
      if (full != null)
        _compactIcon(
          key: const Key('media-forward10'),
          tooltip: t.mediaForward10,
          icon: Icons.forward_10_rounded,
          onPressed: canSkip
              ? () => unawaited(full.skipBy(kMediaSkipStep))
              : null,
        ),
      if (full != null)
        _compactIcon(
          key: const Key('media-next'),
          tooltip: t.mediaNext,
          icon: Icons.skip_next_rounded,
          onPressed: full.hasNext ? () => unawaited(full.playNext()) : null,
        ),
    ];
    return Container(
      key: const Key('media-bottom-bar'),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xE6000000), Color(0x00000000)],
        ),
      ),
      // ★ r630 真机：最下一排（设置/静音/在线字幕/全屏＋音量）
      //   原本距屏底只有 ~30dp，落在**系统手势区**里：真机 `input tap`
      //   完全没反应（而同一条栏的播放键、上方眼睛图标都点得动）。
      //   这里把底边距至少留出 `Gap.xl`（=手势区高度），
      //   并加上系统自报的 `viewPadding.bottom`（三钮导航机型非 0）。
      padding: EdgeInsets.fromLTRB(
        // ★ r658（`DA273`）：全屏页不再外包一层 SafeArea（那是从画面里扣高度），
        //   横向刘海/挖孔由这里让开，纵向手势区照旧按 `viewPadding.bottom` 让。
        Gap.md + MediaQuery.viewPaddingOf(context).left,
        Gap.lg,
        Gap.md + MediaQuery.viewPaddingOf(context).right,
        Gap.xl + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_activeSource.seekable)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(
                children: [
                  Icon(
                    Icons.lock_clock_outlined,
                    size: 14,
                    color: DesignPalette.of(context).dim,
                  ),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(
                      t.bookDownloadHint,
                      key: const Key('media-no-seek-hint'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: DesignPalette.of(context).dim,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // ---- ① 进度区（拖动时上方浮出目标时间）
          _seekBubble(context, posMs, maxMs, total),
          Row(
            children: [
              _timeLabel(
                formatMediaDuration(Duration(milliseconds: posMs.round())),
                key: const Key('media-time-current'),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3.5,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 20,
                    ),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                    overlayColor: Colors.white24,
                  ),
                  child: Slider(
                    key: const Key('media-progress'),
                    value: maxMs <= 0 ? 0 : posMs,
                    max: maxMs <= 0 ? 1 : maxMs,
                    onChangeStart: canSeek ? _onDragStart : null,
                    onChanged: canSeek ? _onDragUpdate : null,
                    onChangeEnd: canSeek ? _onDragEnd : null,
                  ),
                ),
              ),
              _timeLabel(
                total == null ? '--:--' : formatMediaDuration(total),
                key: const Key('media-time-total'),
              ),
            ],
          ),
          const SizedBox(height: Gap.xs),
          // ---- ② 主控区：永不折叠
          Row(
            key: const Key('media-primary-row'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < primary.length; i++) ...[
                if (i > 0) const SizedBox(width: Gap.xs),
                primary[i],
              ],
            ],
          ),
          const SizedBox(height: Gap.xs),
          // ---- ③ 次控区：宽了才折叠（音量固定在右侧）
          Row(
            children: [
              Expanded(
                child: FoldingActions(reserve: Gap.md, children: secondary),
              ),
              // ★ r646（**DA246**，真机 2026-10-23）：这里原来常驻一根 96dp 的
              //   音量滑杆。手机上它纯属冗余 —— 硬件音量键会调媒体音量、屏幕
              //   **左半边竖滑**已经能调（`_GestureSide.volume`）、旁边还有静音键；
              //   而这 96dp 是**永不折叠**的固定开销 —— 现役 4 个动作在 320–360dp
              //   还放得下（实测：`FoldingActions` 在这里一个都不折），但可用宽度
              //   只剩约 230dp：多一个动作（外挂字幕/投屏）就会提前折叠。所以这不是
              //   "现在挡了谁"，而是**把不该常驻的东西撤出常驻位置**。
              //   做法：滑杆收进「播放设置 → 音量」（技术型/少用型控件按用户原话
              //   「收在菜单里」），行内只留静音键；手势与硬件键都不动。
              if (full == null)
                Text(
                  widget.source.channel.code,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: DesignPalette.of(context).dim,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 时间标签（等宽数字，避免拖动时左右抖）
  Widget _timeLabel(String text, {required Key key}) => Text(
    text,
    key: key,
    style: const TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
    ),
  );

  /// 拖动进度时浮在进度条上方的目标时间气泡：`03:12` ＋ 相对当前位置的 `+0:42`
  Widget _seekBubble(
    BuildContext context,
    double posMs,
    double maxMs,
    Duration? total,
  ) {
    if (_dragValue == null) return const SizedBox.shrink();
    final delta = (posMs - _adapter.position.inMilliseconds).round();
    final sign = delta >= 0 ? '+' : '-';
    final d = formatMediaDuration(Duration(milliseconds: delta.abs()));
    return Align(
      alignment: Alignment.center,
      child: Container(
        key: const Key('media-seek-bubble'),
        margin: const EdgeInsets.only(bottom: Gap.xs),
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(Radii.capsule),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(
          '${formatMediaDuration(Duration(milliseconds: posMs.round()))}'
          '  ·  $sign$d',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  /// 「播放设置」底部面板（r630）：倍速 / 画面比例 / 音轨 / 字幕 —— **带文字**的一处入口。
  ///
  /// 为什么不是继续在控制条上排 4 个图标菜单：
  ///   ① 一行放不下（360dp 实测溢出 2.4px，`PopupMenuButton` 又不可折叠）；
  ///   ② 图标本身不带语义（`graphic_eq` 是音轨还是均衡器？），面板里给中文/英文标签；
  ///   ③ 与 YouTube / Netflix 的齿轮面板同构，用户的肌肉记忆能直接用。
  Future<void> _openSettingsSheet() async {
    final t = context.t;
    if (!mounted) return;
    // ★ r659（`DA274`）：面板**不许拿打开那一刻的快照**。
    //
    // 现场（r657 真机）：面板开着选「字幕 → 中文测试」，画面已经出字，
    // 而「Subtitles」行右侧仍印着打开那一刻的 "Subtitles off"，
    // **关掉重开才对**。两个原因叠在一起：
    //   ① 行值读的是 `showModalBottomSheet` 之前抓的 `full` 局部量；
    //   ② 更根本：适配器事件只让**宿主页** `setState`，弹层路由的 builder
    //      压根不会再被调 —— 数据再新也画不出来。
    // 修法：弹层订阅同一条 `changes` 流，用 `ValueNotifier` 打一拍重建；
    // `full` 在 builder 里**现取**（引擎中途换成 libmpv 兜底也照样对）。
    final tick = ValueNotifier<int>(0);
    final sub = _adapter.changes.listen((_) => tick.value++);
    // ★ r637（真机实测）：面板**会超出屏幕**。
    //
    // 现场：挂了在线字幕后多出「字幕大小」「字幕全文」两行，最后一行
    // 「Subtitle transcript」落在 `y≈2417`，而 App 窗口只到 `2377`
    // （导航栏之上）—— 看得见、**点不到**，等于没有。
    // 所以面板必须：① 可滚动；② 最高只占屏幕 80%。
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (outer) => ValueListenableBuilder<int>(
        valueListenable: tick,
        builder: (outerRebuild, _, _) => StatefulBuilder(
          // ★ r635（DA226）：字幕字号要在面板里当场看到变化 ⇒ 需要局部 setState
          builder: (ctx, setSheet) {
            // ★ r659（`DA274`）：**现取**，不用外面的快照
            final full = _full;
            final hud = DesignPalette.of(ctx);
            final theme = Theme.of(ctx);
            return SafeArea(
              key: const Key('media-settings-sheet'),
              top: false,
              child: ConstrainedBox(
                // 80% 上限 + 内部滚动：多行时最后一行也**点得到**（r637 真机缺陷）
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.8,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Gap.lg,
                          0,
                          Gap.lg,
                          Gap.xs,
                        ),
                        child: Text(
                          context.t.photoPlaybackSettings,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      _sheetMenuRow(
                        key: 'speed',
                        icon: Icons.speed_rounded,
                        label: t.mediaSpeed,
                        value: '${_adapter.speed}x',
                        menu: _speedMenu(
                          theme,
                          rowChild: const SizedBox.shrink(),
                        ),
                        hud: hud,
                        ctx: ctx,
                        theme: theme,
                      ),
                      if (full != null)
                        _sheetMenuRow(
                          key: 'aspect',
                          icon: Icons.aspect_ratio_rounded,
                          label: t.mediaAspect,
                          value: _aspectLabel(t, full.aspectMode),
                          menu: _aspectMenu(
                            t,
                            full,
                            rowChild: const SizedBox.shrink(),
                          ),
                          hud: hud,
                          ctx: ctx,
                          theme: theme,
                        ),
                      if (full != null)
                        _sheetMenuRow(
                          key: 'audio',
                          icon: Icons.graphic_eq_rounded,
                          label: t.mediaAudioTrack,
                          value: full.audioTracks.isEmpty
                              ? t.mediaNoTracks
                              // ★ r657（`DA272`）：同一条根因的另一半 —— 只在
                              //   `isSelected` 上找，兜底引擎换到第 2 条仍印第 1 条。
                              : (selectedMediaTrack(
                                          full.audioTracks,
                                          full.selectedAudioTrackId,
                                        ) ??
                                        full.audioTracks.first)
                                    .displayLabel,
                          menu: _audioTrackMenu(
                            t,
                            full,
                            rowChild: const SizedBox.shrink(),
                          ),
                          hud: hud,
                          ctx: ctx,
                          theme: theme,
                        ),
                      if (full != null)
                        _sheetMenuRow(
                          key: 'subtitle',
                          icon: Icons.subtitles_outlined,
                          label: t.mediaSubtitle,
                          value: _subtitleSheetValue(t, full),
                          menu: _subtitleMenu(
                            t,
                            full,
                            rowChild: const SizedBox.shrink(),
                          ),
                          hud: hud,
                          ctx: ctx,
                          theme: theme,
                        ),
                      // ★ r635（DA226）：字幕字号（只在"有字幕文本"时出现，不给假入口）
                      // ★ r655（DA269）：引擎自己画字幕时也藏起来 —— 那条路上的字号
                      //   由 mpv 决定，摆在这儿只会是假控件。
                      if (_subtitleText != null &&
                          _subtitleText!.isNotEmpty &&
                          !_engineDrawsOwnSubtitles)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            Gap.lg,
                            Gap.xs,
                            Gap.lg,
                            Gap.xs,
                          ),
                          child: Row(
                            key: const Key('media-settings-row-subtitle-size'),
                            children: [
                              Icon(
                                Icons.text_fields_rounded,
                                size: 20,
                                color: hud.muted,
                              ),
                              const SizedBox(width: Gap.sm),
                              Expanded(
                                child: Text(
                                  dataText('mediaSubtitleSize', '字幕大小'),
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                              IconButton(
                                key: const Key('media-subtitle-smaller'),
                                tooltip: dataText(
                                  'mediaSubtitleSmaller',
                                  '字幕小一点',
                                ),
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.text_decrease_rounded),
                                onPressed:
                                    _subtitleScale <= kMediaSubtitleScales.first
                                    ? null
                                    : () {
                                        setState(() {
                                          final i = kMediaSubtitleScales
                                              .indexOf(_subtitleScale);
                                          _subtitleScale =
                                              kMediaSubtitleScales[(i - 1)
                                                  .clamp(
                                                    0,
                                                    kMediaSubtitleScales
                                                            .length -
                                                        1,
                                                  )];
                                        });
                                        setSheet(() {});
                                      },
                              ),
                              Text(
                                '${(_subtitleScale * 100).round()}%',
                                key: const Key('media-subtitle-size-value'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: hud.dim,
                                ),
                              ),
                              IconButton(
                                key: const Key('media-subtitle-larger'),
                                tooltip: dataText(
                                  'mediaSubtitleLarger',
                                  '字幕大一点',
                                ),
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.text_increase_rounded),
                                onPressed:
                                    _subtitleScale >= kMediaSubtitleScales.last
                                    ? null
                                    : () {
                                        setState(() {
                                          final i = kMediaSubtitleScales
                                              .indexOf(_subtitleScale);
                                          _subtitleScale =
                                              kMediaSubtitleScales[(i + 1)
                                                  .clamp(
                                                    0,
                                                    kMediaSubtitleScales
                                                            .length -
                                                        1,
                                                  )];
                                        });
                                        setSheet(() {});
                                      },
                              ),
                            ],
                          ),
                        ),
                      // ★ r655（DA263）：字幕位置 —— 只给"上/下"两个方向 + 档位读数，
                      //   因为用户要的是"别压住画面/别沉在黑边里"，不是像素级调参。
                      // ★ r656（`DA271`）：位置/背景条这两行**不**再按"引擎自己画字幕"
                      //   一刀切藏掉 —— libmpv 完全听得懂（`sub-margin-y` /
                      //   `sub-border-style`），藏起来等于少给一半能力。能不能生效
                      //   由 [_subtitleAdjustable] 判：有字幕轨就摆出来。
                      if (_subtitleAdjustable)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            Gap.lg,
                            Gap.xs,
                            Gap.lg,
                            Gap.xs,
                          ),
                          child: Row(
                            key: const Key(
                              'media-settings-row-subtitle-position',
                            ),
                            children: [
                              Icon(
                                Icons.vertical_align_center_rounded,
                                size: 20,
                                color: hud.muted,
                              ),
                              const SizedBox(width: Gap.sm),
                              Expanded(
                                child: Text(
                                  dataText('mediaSubtitlePosition', '字幕位置'),
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                              IconButton(
                                key: const Key('media-subtitle-lower'),
                                tooltip: dataText('mediaSubtitleLower', '字幕往下'),
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.arrow_downward_rounded),
                                onPressed:
                                    _subtitleOffset <=
                                        kMediaSubtitleOffsets.first
                                    ? null
                                    : () {
                                        setState(() {
                                          final i = kMediaSubtitleOffsets
                                              .indexOf(_subtitleOffset);
                                          _subtitleOffset =
                                              kMediaSubtitleOffsets[(i - 1)
                                                  .clamp(
                                                    0,
                                                    kMediaSubtitleOffsets
                                                            .length -
                                                        1,
                                                  )];
                                        });
                                        setSheet(() {});
                                        unawaited(_applySubtitleStyle());
                                        _saveSubtitleStyle();
                                      },
                              ),
                              Text(
                                _subtitleOffset <= 0
                                    ? dataText(
                                        'mediaSubtitlePositionDefault',
                                        '默认',
                                      )
                                    : '+${_subtitleOffset.round()}',
                                key: const Key('media-subtitle-position-value'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: hud.dim,
                                ),
                              ),
                              IconButton(
                                key: const Key('media-subtitle-higher'),
                                tooltip: dataText(
                                  'mediaSubtitleHigher',
                                  '字幕往上',
                                ),
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.arrow_upward_rounded),
                                onPressed:
                                    _subtitleOffset >=
                                        kMediaSubtitleOffsets.last
                                    ? null
                                    : () {
                                        setState(() {
                                          final i = kMediaSubtitleOffsets
                                              .indexOf(_subtitleOffset);
                                          _subtitleOffset =
                                              kMediaSubtitleOffsets[(i + 1)
                                                  .clamp(
                                                    0,
                                                    kMediaSubtitleOffsets
                                                            .length -
                                                        1,
                                                  )];
                                        });
                                        setSheet(() {});
                                        unawaited(_applySubtitleStyle());
                                        _saveSubtitleStyle();
                                      },
                              ),
                            ],
                          ),
                        ),
                      // ★ r655（DA263）：字幕背景条 —— 白字压在雪景/白墙/亮色画面上
                      //   完全读不出来，这是**看得见**的问题，所以给一个明确的开关。
                      // ★ r656（`DA271`）：位置/背景条这两行**不**再按"引擎自己画字幕"
                      //   一刀切藏掉 —— libmpv 完全听得懂（`sub-margin-y` /
                      //   `sub-border-style`），藏起来等于少给一半能力。能不能生效
                      //   由 [_subtitleAdjustable] 判：有字幕轨就摆出来。
                      if (_subtitleAdjustable)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            Gap.lg,
                            0,
                            Gap.lg,
                            Gap.xs,
                          ),
                          child: Row(
                            key: const Key(
                              'media-settings-row-subtitle-backdrop',
                            ),
                            children: [
                              Icon(
                                Icons.branding_watermark_outlined,
                                size: 20,
                                color: hud.muted,
                              ),
                              const SizedBox(width: Gap.sm),
                              Expanded(
                                child: Text(
                                  dataText('mediaSubtitleBackground', '字幕背景条'),
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                              Switch(
                                key: const Key('media-subtitle-background'),
                                value: _subtitleBackground,
                                onChanged: (v) {
                                  setState(() => _subtitleBackground = v);
                                  setSheet(() {});
                                  unawaited(_applySubtitleStyle());
                                  _saveSubtitleStyle();
                                },
                              ),
                            ],
                          ),
                        ),
                      // ★ r646（DA246）：音量滑杆落到这里。给「百分比」是因为滑杆
                      //   只能看个大概，而**投屏/外放时到底调没调到位**要有个数。
                      if (full != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            Gap.lg,
                            Gap.xs,
                            Gap.lg,
                            Gap.xs,
                          ),
                          child: Row(
                            key: const Key('media-settings-row-volume'),
                            children: [
                              Icon(
                                _volumeIcon(full),
                                size: 20,
                                color: hud.muted,
                              ),
                              const SizedBox(width: Gap.sm),
                              Text(
                                t.mediaVolume,
                                style: theme.textTheme.bodyMedium,
                              ),
                              Expanded(
                                child: Slider(
                                  key: const Key('media-settings-volume'),
                                  value: full.volume.clamp(0.0, 1.0),
                                  onChanged: (v) {
                                    unawaited(full.setVolume(v));
                                    setSheet(() {});
                                  },
                                ),
                              ),
                              SizedBox(
                                width: 44,
                                child: Text(
                                  '${(full.volume.clamp(0.0, 1.0) * 100).round()}%',
                                  key: const Key('media-settings-volume-value'),
                                  textAlign: TextAlign.end,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: hud.dim,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: Gap.sm),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    // 面板关掉：先断订阅再释放，之后不会再有人碰这个 notifier
    await sub.cancel();
    tick.dispose();
  }

  /// ★ r637：**字幕全文**（同步滚动）。
  ///
  /// 用户原话（第一轮需求）：「字幕的同步滚动效果这个还没有」。
  /// 内封字幕走 Media3 只给"当前这一帧的文本"（拿不到整条轨道），所以这一页
  /// **只对外挂字幕开放**（`.srt/.vtt/.ass` 解析成 `SubtitleCue` 之后整条都在手上）——
  /// 不给假入口：没有外挂字幕时这一行根本不出现。
  ///
  /// 交互按"人怎么看字幕"来设计：
  ///   * 打开就**停在正在播的那一句**（不是从第一句开始翻）；
  ///   * 播放推进时列表跟着滚，当前句高亮；
  ///   * 用户手动滚开 ⇒ 自动跟随让位一段时间（不跟手指抢）；
  ///   * 点任意一句 ⇒ 跳到那句（想重听/想跳到后面，不用先关面板再拖进度条）。
  ///
  /// 复用 [SyncedLyricsView]（全屏歌词那套已过真机的滚动/让位/居中算法），
  /// 只把 `SubtitleCue` 转成 `LrcDocument` —— 同一份时间轴，不重写第二套滚动逻辑。
  Future<void> _openSubtitleTranscript() async {
    final track = _externalTrack;
    if (track == null || track.cues.isEmpty) return;
    if (!mounted) return;
    const double sheetHeight = 360;
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (outer) => MediaSubtitleTranscript(
        cues: track.cues,
        position: _positionTick,
        height: sheetHeight,
        onSeek: (target) {
          // 点字幕行 = 用户动作 ⇒ 续播判定之后也不许再被"自动跳回"
          _userSeeked = true;
          unawaited(_adapter.seekTo(target));
        },
      ),
    );
  }

  /// 面板里的一行：左边图标＋标签，右边当前值＋箭头；整行就是那个 `PopupMenuButton`。
  ///
  /// 菜单本体传进来时 `rowChild` 是空盒子 —— 用 `Stack` 把它压在整行下面，
  /// 这样既保留原来的 key（`media-speed` / `media-aspect` / …）与点开行为，
  /// 又不必把四个菜单的 itemBuilder 重写一遍。
  Widget _sheetMenuRow({
    required String key,
    required IconData icon,
    required String label,
    required String value,
    required Widget menu,
    required DesignPalette hud,
    required BuildContext ctx,
    required ThemeData theme,
  }) {
    return Stack(
      children: [
        // 透明但**可点**的菜单层：整行都是它的点击区
        Positioned.fill(child: Opacity(opacity: 0.01, child: menu)),
        IgnorePointer(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.lg,
              vertical: Gap.sm,
            ),
            child: Row(
              key: Key('media-settings-row-$key'),
              children: [
                Icon(icon, size: 20, color: hud.muted),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
                Text(
                  value,
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
                const SizedBox(width: Gap.xs),
                Icon(Icons.chevron_right_rounded, size: 20, color: hud.dim),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 字幕项在面板上的"当前值"：关 / 内封轨名 / 外挂文件名 / 在线源
  String _subtitleSheetValue(AppText t, MediaPlayerFullControls full) {
    if (_externalChoice != null) return _externalChoice!.name;
    if (_onlineCacheFile != null) return _onlineHit?.sourceLabel ?? 'Online';
    // ★ r657（`DA272`）：**先认 id**（兜底引擎只在 id 上说真话），`isSelected` 兜底。
    final selected = selectedMediaTrack(
      full.subtitleTracks,
      full.selectedSubtitleTrackId,
    );
    return selected?.displayLabel ?? t.mediaSubtitleOff;
  }

  /// 倍速菜单（档位与持久化共用一份 `kMediaSpeeds`）
  Widget _speedMenu(ThemeData theme, {Widget? rowChild}) =>
      PopupMenuButton<double>(
        key: const Key('media-speed'),
        tooltip: '${_adapter.speed}x',
        onSelected: (v) => unawaited(_setSpeed(v)),
        itemBuilder: (_) => [
          for (final s in kMediaSpeeds)
            PopupMenuItem(value: s, child: Text('${s}x')),
        ],
        child:
            rowChild ??
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.xs,
                vertical: Gap.xs,
              ),
              child: Text(
                '${_adapter.speed}x',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: Colors.white,
                ),
              ),
            ),
      );

  /// 手势层：单击显隐控件、双击左/右 ±10s、左半竖直调亮度、右半竖直调音量。
  ///
  /// 放在**字幕之上、控件之下**：中间那块空白归它，控件条自己的按钮仍然优先
  /// 拿到点击（控件层在更上层）。
  Widget _gestureLayer(BuildContext context) {
    return GestureDetector(
      key: const Key('media-gesture-layer'),
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      onDoubleTapDown: (d) => _doubleTapPosition = d.localPosition,
      onDoubleTap: _onDoubleTap,
      // ★ r635（DA224）：横滑拖进度（整屏宽 = 整段时长，松手才 seek）
      onHorizontalDragStart: _onHorizontalDragStart,
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: (_) => _onHorizontalDragEnd(),
      onHorizontalDragCancel: _onHorizontalDragCancel,
      // ★ r635（DA225）：长按 2 倍速，松开恢复
      onLongPressStart: (_) => _onLongPressStart(),
      onLongPressEnd: (_) => _onLongPressEnd(),
      onLongPressCancel: _onLongPressCancel,
      onVerticalDragStart: _onVerticalDragStart,
      onVerticalDragUpdate: _onVerticalDragUpdate,
      onVerticalDragEnd: (_) => _onVerticalDragEnd(),
      child: const SizedBox.expand(),
    );
  }

  /// 双击：左半快退 10s、右半快进 10s（中间 20% 留给"误触"不算）
  void _onDoubleTap() {
    final full = _full;
    if (full == null || !_activeSource.seekable) return;
    _userSeeked = true;
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    final x = _doubleTapPosition?.dx ?? width / 2;
    if (x < width * 0.4) {
      if (!_controlsVisible) _toggleControls();
      unawaited(full.skipBy(-kMediaSkipStep));
      _showHud(
        icon: Icons.replay_10_rounded,
        text: dataText(
          'mediaBackwardN',
          '快退 {n} 秒',
        ).replaceAll('{n}', '${kMediaSkipStep.inSeconds}'),
      );
    } else if (x > width * 0.6) {
      if (!_controlsVisible) _toggleControls();
      unawaited(full.skipBy(kMediaSkipStep));
      _showHud(
        icon: Icons.forward_10_rounded,
        text: dataText(
          'mediaForwardN',
          '快进 {n} 秒',
        ).replaceAll('{n}', '${kMediaSkipStep.inSeconds}'),
      );
    } else {
      _toggleControls();
    }
  }

  void _onVerticalDragStart(DragStartDetails d) {
    _verticalDragged = false;
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    _verticalSide = d.localPosition.dx < width / 2
        ? _GestureSide.brightness
        : _GestureSide.volume;
    final full = _full;
    // 音量以"当前值"为基准；亮度以"当前可见度"（1 - 遮罩）为基准
    _dragBase = _verticalSide == _GestureSide.volume
        ? (full?.volume ?? 1).clamp(0.0, 1.0)
        : (1 - _dimOpacity / kMediaMaxDim).clamp(0.0, 1.0);
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    final side = _verticalSide;
    if (side == null) return;
    final height = context.size?.height ?? MediaQuery.sizeOf(context).height;
    if (height <= 0) return;
    // 全高 = 100%（向上加、向下减）；每帧只加增量，避免累计漂移
    final next = (_dragBase - (d.primaryDelta ?? 0) / height).clamp(0.0, 1.0);
    _dragBase = next;
    _verticalDragged = true;
    switch (side) {
      case _GestureSide.volume:
        final full = _full;
        if (full == null) return;
        final before = full.muted;
        if (before && next > 0) unawaited(full.setMuted(false));
        unawaited(full.setVolume(next));
        _showHud(
          icon: next == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          text: dataText(
            'mediaVolumePercent',
            '音量 {n}%',
          ).replaceAll('{n}', '${(next * 100).round()}'),
        );
      case _GestureSide.brightness:
        setState(() => _dimOpacity = (1 - next) * kMediaMaxDim);
        _showHud(
          icon: Icons.brightness_6_outlined,
          text: dataText(
            'mediaBrightnessPercent',
            '亮度 {n}%',
          ).replaceAll('{n}', '${(next * 100).round()}'),
        );
    }
  }

  void _onVerticalDragEnd() {
    if (!_verticalDragged) return;
    // 松手后提示再留一会儿（[`_showHud`] 自己的 900ms 计时负责收起）
    _armAutoHide();
  }

  // ── 横滑拖进度（DA224）──────────────────────────────────────────────
  //
  // 判据：**松手才 seek**。拖动中只更新 `_seekDragTarget` 与中央提示，
  // 这样快速来回拖不会把 seek 排成一条长队（真机上会明显卡顿）。
  void _onHorizontalDragStart(DragStartDetails d) {
    final total = _adapter.duration;
    if (total == null || total <= Duration.zero) return;
    if (!_activeSource.seekable) return;
    _seekDragBase = _adapter.position;
    _seekDragTarget = _adapter.position;
    _seekDraggedDx = 0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    final base = _seekDragBase;
    final total = _adapter.duration;
    if (base == null || total == null || total <= Duration.zero) return;
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    _seekDraggedDx += d.primaryDelta ?? 0;
    final deltaMs = (total.inMilliseconds * (_seekDraggedDx / width)).round();
    var targetMs = base.inMilliseconds + deltaMs;
    targetMs = targetMs.clamp(0, total.inMilliseconds);
    final target = Duration(milliseconds: targetMs);
    _seekDragTarget = target;
    _showHud(
      icon: deltaMs >= 0
          ? Icons.fast_forward_rounded
          : Icons.fast_rewind_rounded,
      text: '${_formatClock(target)} / ${_formatClock(total)}',
      // 拖动中提示**不许**自己消失（默认 900ms 会中途收掉）
      hold: true,
    );
  }

  void _onHorizontalDragEnd() {
    final target = _seekDragTarget;
    if (target != null) _userSeeked = true;
    _seekDragBase = null;
    _seekDragTarget = null;
    _seekDraggedDx = 0;
    _clearHud();
    if (target == null) return;
    unawaited(_adapter.seekTo(target));
    _armAutoHide();
  }

  void _onHorizontalDragCancel() {
    _seekDragBase = null;
    _seekDragTarget = null;
    _seekDraggedDx = 0;
    _clearHud();
  }

  /// `m:ss` / `h:mm:ss`（播放器里的时间一律不带毫秒）
  String _formatClock(Duration d) {
    final total = d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final sec = total % 60;
    final two = sec.toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$two';
    return '$m:$two';
  }

  // ── 长按 2 倍速（DA225）──────────────────────────────────────────────
  void _onLongPressStart() {
    final before = _speedBeforeHold;
    if (before != null) return;
    // 只在"已经在播"时加速：暂停着长按没有任何收益，反而会改掉用户设的倍速
    if (!_adapter.playing) return;
    _speedBeforeHold = _adapter.speed;
    unawaited(_adapter.setSpeed(2));
    _showHud(
      icon: Icons.fast_forward_rounded,
      text: dataText('mediaHoldBoost', '松手恢复原速 · 2×'),
      hold: true,
    );
  }

  void _onLongPressEnd() => _restoreSpeedAfterHold();

  void _onLongPressCancel() => _restoreSpeedAfterHold();

  void _restoreSpeedAfterHold() {
    final before = _speedBeforeHold;
    if (before == null) return;
    _speedBeforeHold = null;
    unawaited(_adapter.setSpeed(before));
    _clearHud();
    _armAutoHide();
  }

  /// 中央手势提示（快进/快退/亮度/音量）：一次性淡入，900ms 后自己消失
  Widget _gestureHud(BuildContext context) {
    final data = _hud!;
    return IgnorePointer(
      child: Center(
        child: Container(
          key: const Key('media-gesture-hud'),
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.md,
            vertical: Gap.sm,
          ),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(Radii.embed),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(data.icon, color: Colors.white, size: 20),
              const SizedBox(width: Gap.xs),
              Text(data.text, style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }

  /// 显示中央提示并重置它的消失计时
  /// [hold] = 手势还在进行中（拖动/长按），提示**不许自己消失**，
  /// 由手势结束时的 [_clearHud] 收掉。默认 900ms 自动淡出。
  void _showHud({
    required IconData icon,
    required String text,
    bool hold = false,
  }) {
    _hudTimer?.cancel();
    setState(() => _hud = _GestureHudData(icon, text));
    if (hold) return;
    _hudTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() => _hud = null);
    });
  }

  void _clearHud() {
    _hudTimer?.cancel();
    if (!mounted) return;
    if (_hud != null) setState(() => _hud = null);
  }

  IconData _volumeIcon(MediaPlayerFullControls full) {
    if (full.muted || full.volume == 0) return Icons.volume_off_rounded;
    if (full.volume < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  /// 动作图标。
  ///
  /// ★ 用标准的 **48dp 最小点击区**（AGENTS §2.0.10 铁律 2）：原来挤到 36dp
  /// 属于"用更小的按钮糊过去"；现在放不下就由 [FoldingActions] 折叠进 `⋮`。
  Widget _compactIcon({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    // ★ r630：显式白色 —— 控制条在黑底上，靠主题继承在真机上可能变成
    // "黑底黑字"（DA103 那类）。显式写死才能用 `Icon.color` 断言。
    icon: Icon(icon, size: 22, color: Colors.white),
    onPressed: onPressed,
  );

  Widget _aspectMenu(
    AppText t,
    MediaPlayerFullControls full, {
    Widget? rowChild,
  }) => PopupMenuButton<MediaAspectMode>(
    key: const Key('media-aspect'),
    tooltip: t.mediaAspect,
    onSelected: (mode) => unawaited(full.setAspectMode(mode)),
    itemBuilder: (_) => [
      for (final mode in MediaAspectMode.values)
        CheckedPopupMenuItem<MediaAspectMode>(
          value: mode,
          checked: full.aspectMode == mode,
          child: Text(_aspectLabel(t, mode)),
        ),
    ],
    // ★ r456 真机像素：不给颜色时这个图标**在黑底上峰值只有 5/255**（看不见），
    //   而同一行 `1.0x`（显式白字）峰值 255。三个复合菜单入口必须显式白。
    child:
        rowChild ??
        const Padding(
          padding: EdgeInsets.all(Gap.xs),
          child: Icon(
            Icons.aspect_ratio_rounded,
            size: 20,
            color: Colors.white,
          ),
        ),
  );

  String _aspectLabel(AppText t, MediaAspectMode mode) => switch (mode) {
    MediaAspectMode.fit => t.mediaAspectFit,
    MediaAspectMode.fill => t.mediaAspectFill,
    MediaAspectMode.zoom => t.mediaAspectZoom,
    MediaAspectMode.stretch => t.mediaAspectStretch,
  };

  Widget _audioTrackMenu(
    AppText t,
    MediaPlayerFullControls full, {
    Widget? rowChild,
  }) => PopupMenuButton<String>(
    key: const Key('media-audio-track'),
    tooltip: t.mediaAudioTrack,
    onSelected: (id) =>
        unawaited(full.selectAudioTrack(id.isEmpty ? null : id)),
    itemBuilder: (_) {
      final tracks = full.audioTracks;
      if (tracks.isEmpty) {
        return [
          PopupMenuItem<String>(enabled: false, child: Text(t.mediaNoTracks)),
        ];
      }
      return [
        for (final track in tracks)
          CheckedPopupMenuItem<String>(
            value: track.id,
            checked: track.isSelected,
            child: _trackLabel(track),
          ),
      ];
    },
    child:
        rowChild ??
        const Padding(
          padding: EdgeInsets.all(Gap.xs),
          child: Icon(Icons.graphic_eq_rounded, size: 20, color: Colors.white),
        ),
  );

  Widget _subtitleMenu(
    AppText t,
    MediaPlayerFullControls full, {
    Widget? rowChild,
  }) {
    final choices = <_SubtitleChoice>[
      const _SubtitleChoice.off(),
      for (final track in full.subtitleTracks) _SubtitleChoice.embedded(track),
      for (final match in _dir?.subtitleMatches ?? const <SubtitleMatch>[])
        _SubtitleChoice.external(match),
      // 已经下载过的在线字幕（重启后按缓存文件名回读，见 `_restoreOnlineSubtitle`）
      if (_onlineCacheFile != null)
        _SubtitleChoice.online(
          _onlineCacheFile!,
          _onlineFormat,
          _onlineHit?.sourceLabel ?? '',
        ),
      // 外挂字幕载入后才有「字幕全文」（内封拿不到整条轨道 ⇒ 不摆假入口）
      if (_externalTrack != null && _externalTrack!.cues.isNotEmpty)
        const _SubtitleChoice.transcript(),
      const _SubtitleChoice.onlineSearch(),
    ];
    return PopupMenuButton<_SubtitleChoice>(
      key: const Key('media-subtitle'),
      tooltip: t.mediaSubtitle,
      onSelected: (choice) => unawaited(_selectSubtitle(choice, full)),
      itemBuilder: (_) => [
        for (final choice in choices)
          CheckedPopupMenuItem<_SubtitleChoice>(
            value: choice,
            checked: choice.isSelected(
              full,
              externalChoice: _externalChoice,
              onlineFile: _onlineCacheFile,
            ),
            child: Row(
              children: [
                Flexible(child: Text(choice.label(t))),
                if ((_subtitleBusy && choice.isExternal) ||
                    (_onlineBusy && choice.isSearchEntry))
                  const Padding(
                    padding: EdgeInsets.only(left: Gap.xs),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
      ],
      child:
          rowChild ??
          const Padding(
            padding: EdgeInsets.all(Gap.xs),
            child: Icon(
              Icons.subtitles_outlined,
              size: 20,
              color: Colors.white,
            ),
          ),
    );
  }

  Future<void> _selectSubtitle(
    _SubtitleChoice choice,
    MediaPlayerFullControls full,
  ) async {
    // "搜索在线字幕…" 不是一条字幕选择：开面板，记不进"上次用的字幕"
    if (choice.isSearchEntry) {
      await openSubtitleSearchSheet();
      return;
    }
    // 「字幕全文」不是一条字幕选择：开同步滚动面板，不改当前字幕
    if (choice.isTranscript) {
      await _openSubtitleTranscript();
      return;
    }
    switch (choice.kind) {
      case _SubtitleChoiceKind.off:
        _clearExternalSubtitle();
        await full.selectSubtitleTrack(null);
      case _SubtitleChoiceKind.embedded:
        _clearExternalSubtitle();
        await full.selectSubtitleTrack(choice.track?.id);
      case _SubtitleChoiceKind.external:
        // 外挂字幕由 Dart 渲染 → 先把内封关掉，避免两条字幕叠在一起
        await full.selectSubtitleTrack(null);
        await _applySubtitle(choice.match);
      case _SubtitleChoiceKind.online:
        await full.selectSubtitleTrack(null);
        await _applyOnlineFromCache(choice.cacheFileName ?? '');
      case _SubtitleChoiceKind.transcript:
        // 上面已单独处理（开面板），这里只是让 switch 穷尽
        return;
      case _SubtitleChoiceKind.onlineSearch:
        return;
    }
    // 记住选择（W1-2）：重启后自动用回来，找不到就如实降级（见 `_restoreSubtitle`）
    final key = _subtitleMemoryKey;
    if (key != null) {
      unawaited(_prefs.saveSubtitle(key, _subtitleMemoryValue(choice)));
    }
  }

  /// 选择 → 持久化值（`off` / `embedded:<id>` / `external:<fileName>` / `online:<缓存文件>`）
  String _subtitleMemoryValue(_SubtitleChoice choice) => switch (choice.kind) {
    _SubtitleChoiceKind.off => 'off',
    _SubtitleChoiceKind.embedded => 'embedded:${choice.track!.id}',
    _SubtitleChoiceKind.external => 'external:${choice.match!.name}',
    _SubtitleChoiceKind.online => 'online:${choice.cacheFileName}',
    _SubtitleChoiceKind.transcript => '',
    _SubtitleChoiceKind.onlineSearch => '',
  };

  Widget _trackLabel(MediaTrackInfo track) {
    final detail = track.detail;
    if (detail.isEmpty) return Text(track.displayLabel);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(track.displayLabel),
        Text(detail, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// 字幕覆盖层：白字 + 黑描边阴影，底部居中，最多 3 行
///
/// 为什么自绘而不是用 Media3 `PlayerView` 的 SubtitleView：画面走的是
/// `TextureRegistry.SurfaceProducer` 纹理（视图树里没有 `PlayerView`），
/// 自绘还能和 App 的排版/字号保持一致；内封字幕仍由 Media3 解码，文本经
/// `Player.Listener.onCues` → EventChannel 送到这里。
/// 投屏面板（r655 · DA264）。
///
/// 五个状态**都必须有话说**（空列表要说"没找到 + 怎么让电视被找到"，失败要说
/// "哪一环断的"）—— 不许出现"点了投屏，什么都没有"。
class _CastSheet extends StatefulWidget {
  const _CastSheet({
    required this.controller,
    required this.reasonText,
    required this.onStart,
    required this.onStop,
  });

  final VideoCastController controller;
  final String Function(UpnpCastFailure?) reasonText;
  final Future<void> Function(UpnpRenderer renderer) onStart;
  final Future<void> Function() onStop;

  @override
  State<_CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<_CastSheet> {
  late final StreamSubscription<VideoCastSnapshot> _sub;
  late VideoCastSnapshot _state;

  @override
  void initState() {
    super.initState();
    _state = widget.controller.snapshot;
    _sub = widget.controller.changes.listen((snapshot) {
      if (!mounted) return;
      setState(() => _state = snapshot);
      // 「停止投屏」之后回到 idle：面板还开着的话应当**自动重新找设备**
      // （用户的下一步多半是"换一台投"）。不自动重搜就会留一个空面板。
      if (snapshot.phase == VideoCastPhase.idle) {
        unawaited(widget.controller.search());
      }
    });
    // 用户点「投屏」的意图就是"找一台设备出来放" ⇒ 打开面板就搜一轮。
    if (_state.phase == VideoCastPhase.idle ||
        _state.phase == VideoCastPhase.failed) {
      unawaited(widget.controller.search());
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.7;
    return ConstrainedBox(
      key: const Key('media-cast-sheet'),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width,
        maxHeight: maxHeight,
      ),
      // ★ 用 Material 而不是 Container + decoration：`ListTile` 的水波纹画在最近的
      //   Material 上，外面套一层带背景色的 DecoratedBox 会把水波纹盖住
      //   （框架会直接抛断言 —— 宿主用例①当场抓到）。
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Gap.lg,
                  Gap.md,
                  Gap.sm,
                  Gap.xs,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cast, size: 20),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(
                        dataText('mediaCastTitle', '投屏到电视'),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    if (_state.phase != VideoCastPhase.searching)
                      TextButton.icon(
                        key: const Key('media-cast-search'),
                        onPressed: () => unawaited(widget.controller.search()),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(dataText('mediaCastSearch', '重新搜索')),
                      ),
                  ],
                ),
              ),
              Flexible(child: _body(context, theme)),
              const SizedBox(height: Gap.sm),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ThemeData theme) {
    switch (_state.phase) {
      case VideoCastPhase.idle:
      case VideoCastPhase.searching:
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.lg,
            vertical: Gap.xl,
          ),
          child: Row(
            key: const Key('media-cast-searching'),
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text(
                  dataText('mediaCastSearching', '正在搜索同一网络里的电视/投影…'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        );
      case VideoCastPhase.ready:
        return ListView.builder(
          shrinkWrap: true,
          itemCount: _state.renderers.length,
          itemBuilder: (context, i) {
            final r = _state.renderers[i];
            // 自绘行而不是 `ListTile` 组件：仓库设计语言禁止新增这种旧形态
            // （`test/design_language_coverage_test.dart` 的棘轮按**原文**数这种旧形态，
            // 连注释里带括号的写法都会被算进去），且这里的行要有 ≥48dp 点击区。
            return InkWell(
              key: Key('media-cast-renderer-$i'),
              onTap: () => unawaited(widget.onStart(r)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.lg,
                  vertical: Gap.sm,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.tv_rounded),
                    const SizedBox(width: Gap.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.friendlyName,
                            style: theme.textTheme.bodyLarge,
                          ),
                          if (r.modelName.isNotEmpty)
                            Text(
                              r.modelName,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ),
              ),
            );
          },
        );
      case VideoCastPhase.casting:
        final name = _state.renderer?.friendlyName ?? '';
        return Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                key: const Key('media-cast-current'),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: Gap.xs),
              Text(
                _state.remotePlaying
                    ? dataText('mediaCastRemotePlaying', '电视正在播放')
                    : dataText('mediaCastRemotePaused', '电视已暂停'),
                key: const Key('media-cast-remote-state'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Gap.sm),
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.xs,
                children: [
                  FilledButton.icon(
                    key: const Key('media-cast-toggle'),
                    style: InlineButtonStyle.filled,
                    onPressed: () =>
                        unawaited(widget.controller.toggleRemotePlayback()),
                    icon: Icon(
                      _state.remotePlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                    label: Text(
                      _state.remotePlaying
                          ? dataText('mediaCastPauseRemote', '暂停电视播放')
                          : dataText('mediaCastResumeRemote', '继续在电视上播放'),
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('media-cast-stop'),
                    onPressed: () => unawaited(widget.onStop()),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(dataText('mediaCastStop', '停止投屏')),
                  ),
                ],
              ),
              if (_state.failure != null) ...[
                const SizedBox(height: Gap.sm),
                Text(
                  widget.reasonText(_state.failure),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        );
      case VideoCastPhase.failed:
        final none = _state.failure == UpnpCastFailure.noRenderer;
        return Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                key: const Key('media-cast-error'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    none ? Icons.tv_off_outlined : Icons.error_outline_rounded,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      none
                          ? dataText('mediaCastEmpty', '没有找到可投屏的设备')
                          : widget.reasonText(_state.failure),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
              if (none) ...[
                const SizedBox(height: Gap.xs),
                Text(
                  dataText(
                    'mediaCastEmptyHint',
                    '确认电视已开机、和手机在同一个 Wi-Fi，并已打开「屏幕投射 / DLNA」。',
                  ),
                  key: const Key('media-cast-empty-hint'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: Gap.sm),
              FilledButton.icon(
                key: const Key('media-cast-retry'),
                style: InlineButtonStyle.filled,
                onPressed: () => unawaited(widget.controller.search()),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(dataText('mediaCastSearch', '重新搜索')),
              ),
            ],
          ),
        );
    }
  }
}

class _SubtitleOverlay extends StatelessWidget {
  const _SubtitleOverlay({
    super.key,
    required this.text,
    this.scale = 1,
    this.background = false,
  });

  final String? text;

  /// 字号倍率（DA226）。1 = 原来的 16sp。
  final double scale;

  /// 是否给字幕加半透明背景条（DA263）
  final bool background;

  @override
  Widget build(BuildContext context) {
    final value = text;
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    final body = Text(
      value,
      textAlign: TextAlign.center,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Colors.white,
        fontSize: 16 * scale,
        height: 1.3,
        fontWeight: FontWeight.w500,
        shadows: const [
          Shadow(blurRadius: 3, color: Colors.black, offset: Offset(0, 1)),
          Shadow(blurRadius: 6, color: Colors.black),
        ],
      ),
    );
    return IgnorePointer(
      // 背景条：只包住文字本身（`Container` 随内容自适应），**不铺满整行** ——
      // 铺满会变成一条横贯画面的黑带，比分段字幕更碍事。
      child: background
          ? Center(
              child: Container(
                key: const Key('media-subtitle-backdrop'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(
                    alpha: kMediaSubtitleBackgroundAlpha,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: body,
              ),
            )
          : body,
    );
  }
}

/// "搜索在线字幕"面板。
///
/// 四种状态都要能看见（**不许静默失败**）：
///   * `loading`：转圈（key `media-subtitle-search-loading`）；
///   * `error`：可读原因 + 每个源的失败明细 + 「重试」（`…-error` / `…-retry`）；
///   * `empty`：问过了但没找到（`…-empty`），与"失败"分开；
///   * `results`：可点的结果列表（`media-subtitle-result-<i>`）。
class _SubtitleSearchSheet extends StatefulWidget {
  const _SubtitleSearchSheet({
    required this.mediaFileName,
    required this.initialQuery,
    required this.bundle,
    required this.keyStore,
    required this.hashProvider,
    required this.onPick,
  });

  final String mediaFileName;
  final String initialQuery;
  final SubtitleSearchBundle bundle;
  final CloudKeyStore keyStore;

  /// 媒体"首尾 64KB"指纹（拿不到 → null ⇒ 只按标题搜）
  final Future<String?> Function() hashProvider;

  /// 下载成功 → 挂上；返回 false = 这条内容解析不出（面板就地报错）
  final Future<bool> Function(
    SubtitleSearchHit hit,
    SubtitleDownload download,
    String cacheFileName,
  )
  onPick;

  @override
  State<_SubtitleSearchSheet> createState() => _SubtitleSearchSheetState();
}

/// 目标语言的三个档（不发明"语言列表"，只给最常用的三档）
enum _SubtitleLangMode { chinese, english, any }

class _SubtitleSearchSheetState extends State<_SubtitleSearchSheet> {
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );
  late final TextEditingController _key = TextEditingController();

  bool _loading = false;
  bool _keyLoaded = false;
  bool _hasKey = false;
  bool _hashTried = false;
  String? _hash;
  SubtitleSearchOutcome? _outcome;
  String? _error;
  String? _busyHitId;
  _SubtitleLangMode _lang = _SubtitleLangMode.chinese;

  @override
  void initState() {
    super.initState();
    unawaited(_loadKey());
  }

  @override
  void dispose() {
    _query.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _loadKey() async {
    try {
      final value = await widget.keyStore.read(kOpenSubtitlesKeySlot);
      if (!mounted) return;
      setState(() {
        _keyLoaded = true;
        _hasKey = (value ?? '').trim().isNotEmpty;
        if (_hasKey) _key.text = value!.trim();
      });
    } catch (_) {
      // 安全存储不可用（旧机/无 Keystore）→ 当"未配置密钥"，界面照实说
      if (mounted) setState(() => _keyLoaded = true);
    }
  }

  Future<void> _saveKey() async {
    final value = _key.text.trim();
    try {
      if (value.isEmpty) {
        await widget.keyStore.delete(kOpenSubtitlesKeySlot);
      } else {
        await widget.keyStore.write(kOpenSubtitlesKeySlot, value);
      }
      if (mounted) setState(() => _hasKey = value.isNotEmpty);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = dataText(
            'mediaSubtitleKeySaveFailed',
            '密钥保存失败（安全存储不可用）',
          ),
        );
      }
    }
  }

  List<String> get _languages => switch (_lang) {
    _SubtitleLangMode.chinese => const ['zh-cn', 'zh', 'zh-tw', 'en'],
    _SubtitleLangMode.english => const ['en'],
    _SubtitleLangMode.any => const [],
  };

  Future<void> _run() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _outcome = null;
    });
    // 指纹只算一次（两次 Range 请求，别每次搜索都打）
    if (!_hashTried) {
      _hashTried = true;
      _hash = await widget.hashProvider();
    }
    SubtitleSearchOutcome? outcome;
    String? error;
    try {
      outcome = await widget.bundle.service.search(
        SubtitleSearchQuery(
          fileName: widget.mediaFileName,
          title: _query.text.trim(),
          hash: _hash,
          languages: _languages,
        ),
        apiKey: _key.text.trim().isEmpty ? null : _key.text.trim(),
      );
    } on SubtitleSearchFailure catch (e) {
      error = e.message;
    } catch (e) {
      error = dataText(
        'mediaSubtitleSearchFailed',
        '搜索失败：{err}',
      ).replaceAll('{err}', '$e');
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _outcome = outcome;
      _error = error;
    });
  }

  Future<void> _download(SubtitleSearchHit hit) async {
    final source = widget.bundle.service.sourceById(hit.sourceId);
    if (source == null) {
      setState(
        () => _error = dataText(
          'mediaSubtitleSourceUnavailable',
          '这个源已经不可用了（{source}）',
        ).replaceAll('{source}', hit.sourceLabel),
      );
      return;
    }
    setState(() {
      _busyHitId = hit.id;
      _error = null;
    });
    try {
      final result = await widget.bundle.cache.fetchAndStore(
        source: source,
        hit: hit,
        mediaFileName: widget.mediaFileName,
        apiKey: _key.text.trim().isEmpty ? null : _key.text.trim(),
      );
      final applied = await widget.onPick(
        hit,
        result.download,
        result.fileName,
      );
      if (!mounted) return;
      setState(() => _busyHitId = null);
      if (!applied) {
        setState(
          () => _error = dataText(
            'mediaSubtitleUnreadableContent',
            '这条字幕解析不出内容（可能不是文本字幕）',
          ),
        );
        return;
      }
      // 字幕选择（语言偏好；`hit.language` 是稳定语言码，不是文件名）。
      trackSelect(
        UsageModule.media,
        hit.language.isEmpty ? 'unknown' : hit.language,
        kind: 'subtitle',
      );
      Navigator.of(context).maybePop();
    } on SubtitleSearchFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _busyHitId = null;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyHitId = null;
        _error = dataText(
          'mediaSubtitleDownloadFailed',
          '下载失败：{err}',
        ).replaceAll('{err}', '$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        key: const Key('media-subtitle-search-sheet'),
        padding: EdgeInsets.only(
          left: Gap.md,
          right: Gap.md,
          bottom: MediaQuery.viewInsetsOf(context).bottom + Gap.md,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.subtitles_outlined, size: 20),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(
                      dataText('mediaSubtitleSearch', '搜索在线字幕'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    key: const Key('media-subtitle-close'),
                    tooltip: t.photoClose,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              Text(
                widget.mediaFileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Gap.sm),
              TextField(
                key: const Key('media-subtitle-search-field'),
                controller: _query,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => unawaited(_run()),
                decoration: InputDecoration(
                  labelText: dataText('mediaSubtitleTitleField', '片名'),
                  hintText: dataText('mediaSubtitleTitleHint', '剧集请带 S01E02'),
                  isDense: true,
                ),
              ),
              const SizedBox(height: Gap.xs),
              Wrap(
                spacing: Gap.xs,
                children: [
                  for (final mode in _SubtitleLangMode.values)
                    ChoiceChip(
                      key: Key('media-subtitle-lang-${mode.name}'),
                      label: Text(switch (mode) {
                        _SubtitleLangMode.chinese => dataText(
                          'mediaSubtitleLangChinese',
                          '中文优先',
                        ),
                        _SubtitleLangMode.english => dataText(
                          'mediaSubtitleLangEnglish',
                          '英文优先',
                        ),
                        _SubtitleLangMode.any => dataText(
                          'mediaSubtitleLangAny',
                          '任意',
                        ),
                      }),
                      selected: _lang == mode,
                      onSelected: (_) => setState(() => _lang = mode),
                    ),
                ],
              ),
              const SizedBox(height: Gap.xs),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('media-subtitle-key-field'),
                      controller: _key,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: dataText(
                          'mediaSubtitleApiKeyLabel',
                          'OpenSubtitles API Key（可选）',
                        ),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('media-subtitle-key-save'),
                    tooltip: t.actionSave,
                    icon: const Icon(Icons.key_outlined),
                    onPressed: () => unawaited(_saveKey()),
                  ),
                ],
              ),
              if (_keyLoaded && !_hasKey)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(
                    dataText(
                      'mediaSubtitleKeyMissing',
                      '未配置密钥：先用免密钥源（Gestdown 全免；OpenSubtitles 匿名有配额）',
                    ),
                    key: const Key('media-subtitle-key-missing'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (_hash != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(
                    dataText(
                      'mediaSubtitleHash',
                      '已算媒体指纹 {hash}…（支持按首尾 64KB 匹配）',
                    ).replaceAll('{hash}', _hash!.substring(0, 8)),
                    key: const Key('media-subtitle-hash'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: Gap.sm),
              FilledButton.icon(
                key: const Key('media-subtitle-search-run'),
                onPressed: _loading ? null : () => unawaited(_run()),
                icon: const Icon(Icons.search),
                label: Text(t.calEnvSearch),
              ),
              const SizedBox(height: Gap.sm),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: Gap.md),
                  child: Center(
                    child: SizedBox(
                      key: Key('media-subtitle-search-loading'),
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              if (_error != null) ...[
                Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: Gap.xs),
                    Expanded(
                      child: Text(
                        _error!,
                        key: const Key('media-subtitle-search-error'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const Key('media-subtitle-search-retry'),
                      onPressed: _loading ? null : () => unawaited(_run()),
                      child: Text(t.serviceRetry),
                    ),
                  ],
                ),
              ],
              if (!_loading && _outcome != null) ...[
                for (final failure in _outcome!.failures)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.xs),
                    child: Text(
                      dataText('mediaSubtitleFailureLine', '{source}：{message}')
                          .replaceAll('{source}', failure.sourceLabel)
                          .replaceAll('{message}', failure.failure.message),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                if (_outcome!.isEmpty && _error == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _outcome!.allFailed
                              ? dataText(
                                  'mediaSubtitleAllSourcesFailed',
                                  '所有在线字幕源都失败了，见上面的原因',
                                )
                              : dataText(
                                  'mediaSubtitleNoMatch',
                                  '没有找到匹配的字幕（可以改片名或换语言再试）',
                                ),
                          key: const Key('media-subtitle-search-empty'),
                          style: theme.textTheme.bodySmall,
                        ),
                        // ★ "全都失败"必须有**重试**：只列原因不给重试等于让用户
                        //   自己去猜怎么再来一次（需求原文：失败要有可读原因 + 重试）。
                        if (_outcome!.allFailed)
                          TextButton(
                            key: const Key('media-subtitle-search-retry'),
                            onPressed: _loading
                                ? null
                                : () => unawaited(_run()),
                            child: Text(t.serviceRetry),
                          ),
                      ],
                    ),
                  ),
                for (var i = 0; i < _outcome!.hits.length; i++)
                  _hitTile(t, _outcome!.hits[i], i),
              ],
              const SizedBox(height: Gap.sm),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hitTile(AppText t, SubtitleSearchHit hit, int index) {
    final busy = _busyHitId == hit.id;
    final subtitle = [
      hit.sourceLabel,
      if (hit.language.isNotEmpty) mediaLanguageName(hit.language),
      if (hit.release.isNotEmpty) hit.release,
      if (hit.downloads > 0) '↓${hit.downloads}',
      if (hit.note.isNotEmpty) hit.note,
    ].join(' · ');
    return DesignRowTile(
      key: Key('media-subtitle-result-$index'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(hit.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download_outlined, size: 18),
      onTap: _busyHitId != null ? null : () => unawaited(_download(hit)),
    );
  }
}

/// 字幕菜单的一项（关闭 / 内封轨 / 外挂候选 / 在线下载的 / "去搜索"）
enum _SubtitleChoiceKind {
  off,
  embedded,
  external,
  online,
  transcript,
  onlineSearch,
}

class _SubtitleChoice {
  const _SubtitleChoice.off()
    : kind = _SubtitleChoiceKind.off,
      track = null,
      match = null,
      cacheFileName = null,
      format = null,
      extra = '';
  const _SubtitleChoice.embedded(this.track)
    : kind = _SubtitleChoiceKind.embedded,
      match = null,
      cacheFileName = null,
      format = null,
      extra = '';
  const _SubtitleChoice.external(this.match)
    : kind = _SubtitleChoiceKind.external,
      track = null,
      cacheFileName = null,
      format = null,
      extra = '';

  /// 已经下载到缓存里的在线字幕（只记"哪个文件"，正文回读时再解析）
  const _SubtitleChoice.online(
    this.cacheFileName,
    this.format, [
    this.extra = '',
  ]) : kind = _SubtitleChoiceKind.online,
       track = null,
       match = null;

  /// 菜单里的「字幕全文」入口（不是一条字幕选择；只在外挂字幕载入后出现）
  const _SubtitleChoice.transcript()
    : kind = _SubtitleChoiceKind.transcript,
      track = null,
      match = null,
      cacheFileName = null,
      format = null,
      extra = '';

  /// 菜单里的"搜索在线字幕…"入口（不是一条真的字幕选择）
  const _SubtitleChoice.onlineSearch()
    : kind = _SubtitleChoiceKind.onlineSearch,
      track = null,
      match = null,
      cacheFileName = null,
      format = null,
      extra = '';

  final _SubtitleChoiceKind kind;
  final MediaTrackInfo? track;
  final SubtitleMatch? match;
  final String? cacheFileName;
  final SubtitleFormat? format;

  /// 附加说明（在线字幕用：源名 / 语言）
  final String extra;

  bool get isExternal => kind == _SubtitleChoiceKind.external;
  bool get isOnline => kind == _SubtitleChoiceKind.online;
  bool get isSearchEntry => kind == _SubtitleChoiceKind.onlineSearch;

  bool get isTranscript => kind == _SubtitleChoiceKind.transcript;

  /// 界面文案（关闭 / 语言或格式标签）
  String label(AppText t) => switch (kind) {
    _SubtitleChoiceKind.off => t.mediaSubtitleOff,
    _SubtitleChoiceKind.embedded => track!.displayLabel,
    _SubtitleChoiceKind.external =>
      match!.language.isEmpty
          ? '${match!.name} · ${match!.format.tag}'
          : '${mediaLanguageName(match!.language)} · ${match!.name}',
    _SubtitleChoiceKind.online =>
      '${dataText('mediaSubtitleOnline', '在线字幕')} · ${format?.tag ?? ''}'
          '${extra.isEmpty ? '' : ' · $extra'}',
    _SubtitleChoiceKind.transcript => t.mediaSubtitleTranscript,
    _SubtitleChoiceKind.onlineSearch => dataText(
      'mediaSubtitleSearchEllipsis',
      '搜索在线字幕…',
    ),
  };

  bool isSelected(
    MediaPlayerFullControls full, {
    SubtitleMatch? externalChoice,
    String? onlineFile,
  }) => switch (kind) {
    _SubtitleChoiceKind.off =>
      externalChoice == null &&
          onlineFile == null &&
          full.selectedSubtitleTrackId == null,
    _SubtitleChoiceKind.embedded =>
      externalChoice == null &&
          onlineFile == null &&
          track!.id == full.selectedSubtitleTrackId,
    _SubtitleChoiceKind.external =>
      onlineFile == null && match!.name == externalChoice?.name,
    _SubtitleChoiceKind.online =>
      onlineFile != null && onlineFile == cacheFileName,
    _SubtitleChoiceKind.transcript => false,
    _SubtitleChoiceKind.onlineSearch => false,
  };
}

/// 独立播放页（全屏/横屏）。
class MediaPlayerPage extends StatefulWidget {
  const MediaPlayerPage({
    super.key,
    required this.source,
    this.entry,
    this.playlist,
    this.playlistIndex = 0,
    this.onOpenExternal,
    this.onDownload,
    this.adapter,
  });

  final MediaSource source;
  final FileEntryDto? entry;

  /// 预览页借来的适配器（见 [MediaPlayerView.adapter]；null = 本页自己建）
  final MediaPlayerAdapter? adapter;

  /// 调用方直接给好的播放列表（相册/时间轴；见 [MediaPlayerView.playlist]）
  final List<MediaSource>? playlist;
  final int playlistIndex;
  final VoidCallback? onOpenExternal;
  final VoidCallback? onDownload;

  @override
  State<MediaPlayerPage> createState() => _MediaPlayerPageState();
}

class _MediaPlayerPageState extends State<MediaPlayerPage> {
  /// 指向播放视图：顶栏的「在线字幕」要调到**播放器**去开面板（面板要用
  /// 当前媒体、缓存目录、已下载的指纹），页面这层拿不到这些。
  final GlobalKey<_MediaPlayerViewState> _viewKey =
      GlobalKey<_MediaPlayerViewState>();

  /// 当前是不是强制横屏
  bool _landscape = true;

  /// 顶栏标题 = **当前播放项**（换集 / 自动续播都跟随）。
  ///
  /// 用 [ValueNotifier] 而不是 `setState`：标题由 [MediaPlayerView] 在播放器
  /// 状态变化时回填（`onCurrentSourceChanged`），不需要整页重建、更不会重启
  /// 播放器实例。
  late final ValueNotifier<MediaSource> _currentSource = ValueNotifier(
    widget.source,
  );

  @override
  void initState() {
    super.initState();
    // 「进入全屏**强制横屏**」：一进来就锁横屏。退出时在 dispose 无条件复位成
    // `DeviceOrientation.values` —— 绝不能把方向泄漏给其它页面。
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    // r650（`DA250`）：进页面即沉浸 —— 状态栏不再永久压着画面
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
  }

  @override
  void didUpdateWidget(covariant MediaPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.source, oldWidget.source)) {
      _currentSource.value = widget.source;
    }
  }

  @override
  void dispose() {
    _currentSource.dispose();
    // 进入本页就强制过方向，离开时必须还原（系统栏/方向都不许泄漏）
    unawaited(_releaseOrientation());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  /// 退出本页时把方向还回去：**先明确回竖屏，再把方向权交给传感器**。
  ///
  /// ★ r648（**DA248**，真机 2026-10-24 实测）：原来只发一次
  /// `DeviceOrientation.values`（= 四向都允许）。设备**平放在桌面上**时
  /// 重力没有水平分量、系统判不出该用哪个方向，于是**保持当前横屏**——
  /// 用户退出全屏后整机停在横屏（连文件页都是横的），得自己把手机转一下才回竖屏。
  /// 修法：先锁 `portraitUp`（让竖屏**真的提交**），隔一帧再把方向权还给传感器：
  /// 平放设备留在竖屏，真横着拿的手机会在传感器下一次上报时自然转回去。
  static Future<void> _releaseOrientation() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  /// 横屏 ↔ 竖屏（有些设备系统自动旋转被关了，给手动按钮）
  Future<void> _toggleOrientation() async {
    final next = !_landscape;
    await SystemChrome.setPreferredOrientations(
      next
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [
              DeviceOrientation.portraitUp,
              DeviceOrientation.portraitDown,
            ],
    );
    if (mounted) setState(() => _landscape = next);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // ★ r650（`DA250`）：这里原来是一条常驻 `AppBar`（标题＋在线字幕＋沉浸式开关）。
      //   横屏全屏时它和状态栏一起永久吃掉约 80dp 画面，而这三样在**控制条/浮层顶栏**
      //   里都有（`media-online-subtitle` / `media-top-back` / `media-more`）——
      //   所以全屏页不再有 AppBar：chrome 只在用户叫出控件时浮出。
      appBar: null,
      // ★ r658（`DA273`）：全屏页**不再**外包 SafeArea —— 它把状态栏／手势区
      //   从画面里扣掉（横屏约 24–33dp，纵屏约 24dp），而画面本该铺满整块屏。
      //   让位改由**控件条自己**做：顶栏有 `SafeArea`，底栏按 `viewPadding`
      //   留边（两者都只在浮出时存在，不给画面永久扣高）。
      body: MediaPlayerView(
        key: _viewKey,
        source: widget.source,
        entry: widget.entry,
        playlist: widget.playlist,
        playlistIndex: widget.playlistIndex,
        onOpenExternal: widget.onOpenExternal,
        onDownload: widget.onDownload,
        isFullscreen: true,
        adapter: widget.adapter,
        onRotate: _toggleOrientation,
        onExitFullscreen: () => Navigator.of(context).maybePop(),
        showFullscreenButton: false,
        onCurrentSourceChanged: (source) => _currentSource.value = source,
      ),
    );
  }
}

/// 打开内置播放页（文件页 / 相册页共用同一个入口）
///
/// [playlist] / [playlistIndex] 是**纯追加**的：文件页不传 → 播放列表仍从 [entry]
/// 的目录现算；相册页传入同一时间轴/相册里的同类型视频，就能用"上一个/下一个"。
Future<void> openMediaPlayer(
  BuildContext context, {
  required MediaSource source,
  FileEntryDto? entry,
  List<MediaSource>? playlist,
  int playlistIndex = 0,
  VoidCallback? onOpenExternal,
  VoidCallback? onDownload,
  MediaPlayerAdapter? adapter,
}) => Navigator.of(context, rootNavigator: true).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => MediaPlayerPage(
      source: source,
      entry: entry,
      playlist: playlist,
      playlistIndex: playlistIndex,
      onOpenExternal: onOpenExternal,
      onDownload: onDownload,
      adapter: adapter,
    ),
  ),
);

/// 竖直滑动的两侧（左半调亮度、右半调音量）
enum _GestureSide { brightness, volume }

/// 中央手势提示的内容
class _GestureHudData {
  const _GestureHudData(this.icon, this.text);

  final IconData icon;
  final String text;
}
