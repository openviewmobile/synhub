// 完整播放器控制条的**界面层**离线测试（真假适配器，不碰平台通道）。
//
// 用**真实主题**（`AppTheme.dark()`）搭 `MaterialApp` —— 这正是上次真机
// Bug 1（音频舞台按钮被主题的 `minimumSize: Size.fromHeight(48)` 挤成 0 宽、
// 点不到）在离线漏网的原因：裸 `MaterialApp` 吃不到 `filledButtonTheme`。
//
// 覆盖：
//   * 控制条每个按钮**存在**且**禁用态**正确（第一个/最后一个、不可 seek）；
//   * 每个按钮**真的调到了适配器**（不是只画了个控件）；
//   * 画面比例 / 音轨 / 内封字幕菜单的选择；
//   * 全屏进入强制横屏、旋转、退出复位方向（系统栏 + 方向都不许泄漏）；
//   * Bug 2：编码不支持 / 网络失败 / 证书不可信 → **三句不同的具体文案** + 回退入口。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/chat/voice_message.dart'
    show VoicePlayer, voicePlayerProvider;
import 'package:synhub/src/features/media/media_audio_stage.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_tracks.dart';

/// 具有**完整控制**的假适配器（对应自研原生播放器）
class FakeFullAdapter implements MediaPlayerAdapter, MediaPlayerFullControls {
  final _changes = StreamController<void>.broadcast();

  final loaded = <String>[];
  final playlists = <({int index, List<String> urls})>[];
  int plays = 0;
  int pauses = 0;
  int disposes = 0;
  int nexts = 0;
  int previouses = 0;
  final seeks = <Duration>[];
  final skips = <Duration>[];
  final speeds = <double>[];
  final volumes = <double>[];
  final mutes = <bool>[];
  final aspects = <MediaAspectMode>[];
  final audioSelections = <String?>[];
  final subtitleSelections = <String?>[];

  Duration _position = Duration.zero;
  Duration? _duration = const Duration(seconds: 100);
  bool _playing = false;
  bool _ready = true;
  double _speed = 1;
  double _volume = 1;
  bool _muted = false;
  int _index = 0;
  int _count = 1;
  MediaAspectMode _aspect = MediaAspectMode.fit;
  String? _error;

  @override
  List<MediaTrackInfo> audioTracks = const [];
  @override
  List<MediaTrackInfo> subtitleTracks = const [];
  String? embeddedText;

  set position(Duration v) => _position = v;
  set duration(Duration? v) => _duration = v;
  set ready(bool v) => _ready = v;
  set count(int v) => _count = v;
  set index(int v) => _index = v;

  void emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 模拟"播放器运行中报错"（Bug 2 的入口：`_adapter.error` 变非空）
  void failWith(String message) {
    _error = message;
    emit();
  }

  @override
  Future<void> load(MediaSource source) async {
    loaded.add(source.uri);
    _error = null;
  }

  @override
  Future<void> setPlaylist(List<MediaSource> items, int index) async {
    playlists.add((index: index, urls: items.map((e) => e.uri).toList()));
    _count = items.length;
    _index = index;
  }

  @override
  Future<void> play() async {
    plays++;
    _playing = true;
    emit();
  }

  @override
  Future<void> pause() async {
    pauses++;
    _playing = false;
    emit();
  }

  @override
  Future<void> seekTo(Duration position) async {
    _position = position;
    seeks.add(position);
    emit();
  }

  @override
  Future<void> skipBy(Duration offset) async {
    skips.add(offset);
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    speeds.add(speed);
    emit();
  }

  @override
  Future<void> setVolume(double value) async {
    _volume = value;
    volumes.add(value);
    emit();
  }

  @override
  Future<void> setMuted(bool value) async {
    _muted = value;
    mutes.add(value);
    emit();
  }

  @override
  Future<void> playNext() async => nexts++;

  @override
  Future<void> playPrevious() async => previouses++;

  @override
  Future<void> selectAudioTrack(String? id) async {
    audioSelections.add(id);
  }

  @override
  Future<void> selectSubtitleTrack(String? id) async {
    subtitleSelections.add(id);
    if (id == null) embeddedText = null;
  }

  @override
  Future<void> setAspectMode(MediaAspectMode mode) async {
    _aspect = mode;
    aspects.add(mode);
    emit();
  }

  @override
  Future<void> dispose() async {
    disposes++;
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  bool get playing => _playing;

  @override
  bool get ready => _ready;

  @override
  double get speed => _speed;

  @override
  String? get error => _error;

  @override
  double get aspectRatio => 16 / 9;

  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(key: Key('fake-full-surface'), color: Colors.black);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  double get volume => _volume;

  @override
  bool get muted => _muted;

  @override
  int get playlistIndex => _index;

  @override
  int get playlistLength => _count;

  @override
  bool get hasPrevious => _count > 1 && _index > 0;

  @override
  bool get hasNext => _count > 1 && _index < _count - 1;

  @override
  String? get selectedAudioTrackId {
    for (final t in audioTracks) {
      if (t.isSelected) return t.id;
    }
    return null;
  }

  @override
  String? get selectedSubtitleTrackId {
    for (final t in subtitleTracks) {
      if (t.isSelected) return t.id;
    }
    return null;
  }

  @override
  MediaAspectMode get aspectMode => _aspect;

  @override
  String? get embeddedSubtitleText => embeddedText;
}

/// 只有基础能力的假适配器（对应 `video_player` 回退）
class FakeBasicAdapter implements MediaPlayerAdapter {
  final _changes = StreamController<void>.broadcast();
  final loaded = <String>[];
  int plays = 0;
  Duration _position = Duration.zero;
  String? _error;

  void failWith(String message) {
    _error = message;
    _changes.add(null);
  }

  @override
  Future<void> load(MediaSource source) async {
    loaded.add(source.uri);
  }

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(Duration position) async => _position = position;

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Duration get position => _position;

  @override
  Duration? get duration => const Duration(seconds: 100);

  @override
  bool get playing => false;

  @override
  bool get ready => true;

  @override
  double get speed => 1;

  @override
  String? get error => _error;

  @override
  double get aspectRatio => 16 / 9;

  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(key: Key('fake-basic-surface'), color: Colors.black);

  @override
  Stream<void> get changes => _changes.stream;
}

/// 假音频播放器（`VoicePlayer`，Bug 1 的回归对象）
class FakeVoicePlayer implements VoicePlayer {
  final _changes = StreamController<void>.broadcast();
  final played = <String>[];
  final seeks = <Duration>[];
  final speeds = <double>[];
  int pauses = 0;
  int stops = 0;
  int resumes = 0;
  Duration _position = Duration.zero;

  @override
  String? currentUrl;

  @override
  bool get hasSource => _hasSource;
  bool _hasSource = false;

  @override
  bool playing = false;

  @override
  double speed = 1;

  /// 真机复现时 just_audio 还没拿到时长 → 界面显示 `--:--`
  @override
  Duration? duration;

  @override
  Duration get position => _position;

  @override
  Stream<void> get changes => _changes.stream;

  void setPosition(Duration d) {
    _position = d;
    _changes.add(null);
  }

  @override
  Future<void> play(String url) async {
    played.add(url);
    currentUrl = url;
    _hasSource = true;
    // 重新载入来源 = 回到 0（真机 just_audio `setUrl` 的语义）；续播要走 resume()
    _position = Duration.zero;
    playing = true;
    _changes.add(null);
  }

  @override
  Future<void> resume() async {
    if (!_hasSource) return;
    resumes++;
    playing = true;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    pauses++;
    playing = false;
    _changes.add(null);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    seeks.add(position);
    _changes.add(null);
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
    speeds.add(value);
  }

  @override
  Future<void> stop() async {
    stops++;
    playing = false;
    _hasSource = false;
    _changes.add(null);
  }
}

MediaSource _playable({
  MediaKind kind = MediaKind.video,
  bool supportsRange = true,
  String uri =
      'https://fake.test/webapi/entry.cgi?api=SYNO.FileStation.Download',
  String name = 'clip.mp4',
}) => MediaSource(
  uri: uri,
  channel: MediaChannel.fileStation,
  kind: kind,
  displayName: name,
  supportsRange: supportsRange,
);

FileEntryDto _entry(String name, {String? path, int size = 4096}) =>
    FileEntryDto(
      name: name,
      path: path ?? '/home/$name',
      isDir: false,
      size: size,
      mtime: 1758100000,
    );

/// 用**真实主题**挂 `MediaPlayerView`（裸 MaterialApp 会漏掉
/// `filledButtonTheme` 的无限宽 minimumSize —— 上一轮的漏网原因）
Future<ProviderContainer> _pumpView(
  WidgetTester tester,
  MediaSource source, {
  required MediaPlayerAdapterFactory factory,
  VoidCallback? onOpenExternal,
  VoidCallback? onDownload,
}) async {
  final container = ProviderContainer(
    overrides: [mediaPlayerAdapterFactoryProvider.overrideWithValue(factory)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: MediaPlayerView(
            source: source,
            onOpenExternal: onOpenExternal,
            onDownload: onDownload,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return container;
}

/// r630：四个复合菜单已搬进「播放设置」面板 ⇒ 先开面板再点。
Future<void> _openSettings(WidgetTester tester) async {
  await _closeSettings(tester);
  await tester.tap(find.byKey(const Key('media-settings')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 关掉面板（只点遮罩，不碰列表里的菜单）
Future<void> _closeSettings(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    if (find.byKey(const Key('media-settings-sheet')).evaluate().isEmpty) {
      return;
    }
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
  }
}

void main() {
  group('控制条：按钮存在与禁用态', () {
    testWidgets('完整控制下所有按钮都在', (tester) async {
      final adapter = FakeFullAdapter()..count = 3;
      await _pumpView(tester, _playable(), factory: () => adapter);

      for (final key in const [
        'media-play-pause',
        'media-prev',
        'media-next',
        'media-back10',
        'media-forward10',
        'media-mute',
        'media-settings',
        'media-fullscreen',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: '缺 $key');
      }
      // ★ r646（DA246）：常驻音量滑杆已收进「播放设置」，控制条上不再有它
      expect(
        find.byKey(const Key('media-volume')),
        findsNothing,
        reason: '手机上硬件键/左半屏竖滑都能调音量，96dp 滑杆是冗余，还挤窄动作行',
      );
      // r630：四个带文字的选项在「播放设置」面板里（不再挤在一行里溢出）
      await _openSettings(tester);
      for (final key in const [
        'media-speed',
        'media-aspect',
        'media-audio-track',
        'media-subtitle',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: '设置面板里缺 $key');
      }
    });

    // ★ r456 真机像素抓到的缺陷（DA103）：三个复合菜单入口的图标**没给颜色**，
    //   在播放器的黑底控制条上峰值只有 5/255（肉眼不可见）——而同一行显式白字的
    //   `1.0x` 峰值是 255。按钮"存在"（key 找得到、点得到）**不等于"看得见"**，
    //   所以这条断言钉的是 `Icon.color`，不是 `findsOneWidget`。
    testWidgets('三个复合菜单的图标必须是白字实心（黑底上要看得见）', (tester) async {
      final adapter = FakeFullAdapter()..count = 3;
      await _pumpView(tester, _playable(), factory: () => adapter);
      // r630：四个复合菜单已改成带文字的面板行（不再是黑底上的图标），
      // 行里剩下的三个图标按钮仍然必须显式白色。
      for (final key in const [
        'media-settings',
        'media-mute',
        'media-online-subtitle',
      ]) {
        final icon = tester.widget<Icon>(
          find
              .descendant(
                of: find.byKey(Key(key)),
                matching: find.byType(Icon),
              )
              .first,
        );
        expect(
          icon.color,
          Colors.white,
          reason: '$key 的图标不是白色 ⇒ 播放器黑底上看不见（真机峰值 5/255）',
        );
      }
    });

    testWidgets('第一个禁用"上一个"、最后一个禁用"下一个"', (tester) async {
      final adapter = FakeFullAdapter()..count = 1;
      await _pumpView(tester, _playable(), factory: () => adapter);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('media-prev')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('media-next')))
            .onPressed,
        isNull,
      );

      adapter.count = 1;
      adapter.index = 0;
      adapter.emit();
      await tester.pump();

      adapter.count = 3;
      adapter.index = 0;
      adapter.emit();
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('media-prev')))
            .onPressed,
        isNull,
        reason: '第一集',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('media-next')))
            .onPressed,
        isNotNull,
      );

      adapter.index = 2;
      adapter.emit();
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('media-prev')))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('media-next')))
            .onPressed,
        isNull,
        reason: '最后一集',
      );
    });

    testWidgets('不可 seek 的来源把快进/快退置灰，可 seek 时可用', (tester) async {
      final adapter = FakeFullAdapter();
      await _pumpView(
        tester,
        _playable(supportsRange: false),
        factory: () => adapter,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('media-back10')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('media-forward10')))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('media-no-seek-hint')), findsOneWidget);

      final adapter2 = FakeFullAdapter();
      await _pumpView(
        tester,
        _playable(supportsRange: true),
        factory: () => adapter2,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('media-back10')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('没有完整控制的回退适配器：扩展按钮不出现（不给假按钮）', (tester) async {
      await _pumpView(tester, _playable(), factory: FakeBasicAdapter.new);
      expect(find.byKey(const Key('media-play-pause')), findsOneWidget);
      expect(find.byKey(const Key('media-fullscreen')), findsOneWidget);
      for (final key in const [
        'media-prev',
        'media-next',
        'media-back10',
        'media-forward10',
        'media-volume',
        'media-mute',
        'media-aspect',
        'media-audio-track',
        'media-subtitle',
      ]) {
        expect(find.byKey(Key(key)), findsNothing, reason: '不该出现 $key');
      }
    });
  });

  group('控制条：点击真的调到适配器', () {
    testWidgets('快进 / 快退 ±10 秒', (tester) async {
      final adapter = FakeFullAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      await tester.tap(find.byKey(const Key('media-forward10')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('media-back10')));
      await tester.pump();
      expect(adapter.skips, [
        const Duration(seconds: 10),
        const Duration(seconds: -10),
      ]);
    });

    testWidgets('上一个 / 下一个', (tester) async {
      final adapter = FakeFullAdapter()
        ..count = 3
        ..index = 1;
      await _pumpView(tester, _playable(), factory: () => adapter);
      await tester.tap(find.byKey(const Key('media-prev')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('media-next')));
      await tester.pump();
      expect(adapter.previouses, 1);
      expect(adapter.nexts, 1);
    });

    // ★ r646（DA246）：滑杆从控制条搬进「播放设置 → 音量」。
    //   判据：面板里拖滑杆真的调到适配器、百分比跟着变；控制条上**没有**滑杆；
    //   静音键仍在行内（一个按钮就能救命，不必进菜单）。
    //   反向验证：把滑杆搬回控制条 ⇒ 上面「控制条不再有 media-volume」那条红。
    testWidgets('音量：面板滑杆 → setVolume ＋ 百分比；静音按钮 → setMuted', (
      tester,
    ) async {
      final adapter = FakeFullAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      expect(find.byKey(const Key('media-volume')), findsNothing);

      await _openSettings(tester);
      expect(
        find.byKey(const Key('media-settings-row-volume')),
        findsOneWidget,
        reason: '音量必须能在面板里调',
      );
      expect(find.text('100%'), findsOneWidget, reason: '先看到当前值');
      final slider = tester.widget<Slider>(
        find.byKey(const Key('media-settings-volume')),
      );
      expect(slider.onChanged, isNotNull);
      slider.onChanged!(0.25);
      await tester.pump();
      expect(adapter.volumes, [0.25]);
      expect(find.text('25%'), findsOneWidget, reason: '百分比要跟着动');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ModalBarrier).last, warnIfMissed: false);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('media-mute')));
      await tester.pump();
      expect(adapter.mutes, [true]);
      expect(
        find.descendant(
          of: find.byKey(const Key('media-mute')),
          matching: find.byIcon(Icons.volume_off_rounded),
        ),
        findsOneWidget,
        reason: '静音后图标要变',
      );
    });

    testWidgets('DA249 音量为 0 时点静音键 = 「把声音叫回来」，不是再静音一次', (
      tester,
    ) async {
      final adapter = FakeFullAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      adapter.setVolume(0);
      // 适配器变更走 stream ⇒ 需要两拍：一拍让事件送达，一拍让界面重建
      await tester.pump();
      await tester.pump();

      // 音量为 0 但 muted=false：界面已经是"没声音"的样子
      expect(
        find.descendant(
          of: find.byKey(const Key('media-mute')),
          matching: find.byIcon(Icons.volume_off_rounded),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('media-mute')));
      await tester.pump();

      expect(
        adapter.mutes,
        [false],
        reason: 'DA249：听不见时按键必须解除静音（再置一次 true 等于死键）',
      );

      // 反向：有声时按键仍然是"静音"
      adapter.mutes.clear();
      adapter.setVolume(0.7);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('media-mute')));
      await tester.pump();
      expect(adapter.mutes, [true], reason: '有声时点一下必须是静音');
    });

    testWidgets('画面比例菜单：四个档位可选，选了就装配到适配器', (tester) async {
      final adapter = FakeFullAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);

      await _openSettings(tester);
      await tester.tap(find.byKey(const Key('media-aspect')));
      await tester.pumpAndSettle();
      expect(find.text('适应（留黑边）'), findsWidgets);
      expect(find.text('铺满（裁切）'), findsWidgets);
      expect(find.text('放大（裁切更多）'), findsWidgets);
      expect(find.text('拉伸（铺满）'), findsWidgets);
      // PopupMenu 在 overlay 里，`find.text` 的命中判定会误报（菜单项在
      // ListBody 里、文字自己不算命中目标）；真正算数的是下面"选中的值真的
      // 传给了适配器"的断言。
      await tester.tap(find.text('放大（裁切更多）'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(adapter.aspects, [MediaAspectMode.zoom]);
    });

    testWidgets('音轨菜单：没有轨道时给"没有可选项"，有轨道时能选', (tester) async {
      final adapter = FakeFullAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      await _openSettings(tester);
      await tester.tap(find.byKey(const Key('media-audio-track')));
      await tester.pumpAndSettle();
      expect(find.text('没有可选项'), findsWidgets);
      await _openSettings(tester);

      adapter.audioTracks = const [
        MediaTrackInfo(
          id: 'audio:0:0',
          kind: MediaTrackKind.audio,
          language: 'zho',
          isSelected: true,
        ),
        MediaTrackInfo(
          id: 'audio:0:1',
          kind: MediaTrackKind.audio,
          language: 'eng',
        ),
      ];
      adapter.emit();
      await tester.pump();
      await tester.tap(find.byKey(const Key('media-audio-track')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(adapter.audioSelections, ['audio:0:1']);
    });

    // ★ r424 / DA82：顶栏 `⋮` → 音轨**面板**（`_pickSheet`）与底部条的那个
    // 弹出菜单是两个入口，旧实现各写一套：
    //   ① 面板里"清空选择"那行复用了 **字幕** 的 "Subtitles off"（错话）；
    //   ② 面板只画 `displayLabel`，两条**同 codec、容器没给标题/语言**的音轨
    //      两行一模一样（真机读数：`mp4a.40.2` ×2）。
    // 反向判据：把 `#序号` 前缀与 `detail` 去掉 ⇒ 两行文本相同、`findsOneWidget` 会红。
    testWidgets('DA82：音轨面板每行唯一（#序号 ＋ 编码·声道），且不再说"关闭字幕"', (
      tester,
    ) async {
      final adapter = FakeFullAdapter();
      adapter.audioTracks = const [
        MediaTrackInfo(
          id: 'audio:0:0',
          kind: MediaTrackKind.audio,
          codec: 'mp4a.40.2',
          channels: 2,
          isSelected: true,
        ),
        MediaTrackInfo(
          id: 'audio:0:1',
          kind: MediaTrackKind.audio,
          codec: 'mp4a.40.2',
          channels: 2,
        ),
      ];
      await _pumpView(tester, _playable(), factory: () => adapter);
      await tester.tap(find.byKey(const Key('media-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('音轨').last, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('关闭字幕'), findsNothing); // ① 不再是字幕的文案
      expect(find.text('#1 · mp4a.40.2 · 2 ch'), findsOneWidget); // ② 两行可分辨
      expect(find.text('#2 · mp4a.40.2 · 2 ch'), findsOneWidget);

      await tester.tap(find.text('#2 · mp4a.40.2 · 2 ch'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(adapter.audioSelections, ['audio:0:1']);
    });

    testWidgets('DA82：音轨面板没有轨道时给"没有可选项"（与底部条同一句）', (tester) async {
      final adapter = FakeFullAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      await tester.tap(find.byKey(const Key('media-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('音轨').last, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('关闭字幕'), findsNothing);
      expect(find.text('没有可选项'), findsWidgets);
    });

    testWidgets('字幕菜单：关闭 / 内封轨切换；内封文本画到 overlay 上', (tester) async {
      final adapter = FakeFullAdapter();
      adapter.subtitleTracks = const [
        MediaTrackInfo(
          id: 'subtitle:0:0',
          kind: MediaTrackKind.subtitle,
          label: '简体',
          isSelected: true,
        ),
      ];
      adapter.embeddedText = '第一句字幕';
      await _pumpView(tester, _playable(), factory: () => adapter);
      expect(find.text('第一句字幕'), findsOneWidget);

      await _openSettings(tester);
      await tester.tap(find.byKey(const Key('media-subtitle')));
      await tester.pumpAndSettle();
      // 面板行会再显示一次"当前值"（关闭字幕 / 简体）⇒ 允许多个命中
      expect(find.text('关闭字幕'), findsWidgets);
      expect(find.text('简体'), findsWidgets);
      await tester.tap(find.text('关闭字幕'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(adapter.subtitleSelections, [null]);

      // 关掉之后 overlay 不该再显示（适配器把文本清了）
      adapter.subtitleTracks = const [
        MediaTrackInfo(
          id: 'subtitle:0:0',
          kind: MediaTrackKind.subtitle,
          label: '简体',
        ),
      ];
      adapter.emit();
      await tester.pump();
      expect(find.text('第一句字幕'), findsNothing);
    });

    testWidgets('进度条拖动仍然真的 seek（完整控制没破坏原行为）', (tester) async {
      final adapter = FakeFullAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      final slider = tester.widget<Slider>(
        find.byKey(const Key('media-progress')),
      );
      slider.onChangeStart!(30 * 1000);
      slider.onChanged!(30 * 1000);
      slider.onChangeEnd!(30 * 1000);
      await tester.pumpAndSettle();
      expect(adapter.seeks.single, const Duration(seconds: 30));
    });

    testWidgets('倍速菜单仍然可用', (tester) async {
      final adapter = FakeFullAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      await _openSettings(tester);
      await tester.tap(find.byKey(const Key('media-speed')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2.0x').last, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(adapter.speeds, contains(2.0));
    });
  });

  group('全屏 / 方向（不泄漏给其它页面）', () {
    testWidgets('进入全屏页强制横屏；旋转切竖屏；退出复位系统栏与方向', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method.startsWith('SystemChrome.')) calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final adapters = <FakeFullAdapter>[];
      await _pumpView(
        tester,
        _playable(name: '旅途.mp4'),
        factory: () {
          final a = FakeFullAdapter();
          adapters.add(a);
          return a;
        },
      );
      await tester.tap(find.byKey(const Key('media-fullscreen')));
      await tester.pumpAndSettle();
      expect(find.byType(MediaPlayerPage), findsOneWidget);
      // ★ r647（DA247）：全屏页**借**预览页的适配器 —— 再建一个就会把原生
      //   player/texture 抢走，退出时连预览页一起废掉。
      expect(adapters, hasLength(1), reason: '全屏页借同一个适配器，不再新建');
      expect(find.byKey(const Key('media-rotate')), findsOneWidget);
      expect(find.byKey(const Key('media-exit-fullscreen')), findsOneWidget);

      // ⚠️ 必须每次**现取**：`calls` 是活的，进页面时的锁横屏已经进去过，
      // 若在 tap 之前 toList() 成快照，后面的断言永远看不到旋转/复位那两条。
      List<MethodCall> orientCalls() => calls
          .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
          .toList();
      expect(orientCalls(), isNotEmpty, reason: '进全屏必须锁方向');
      List<Object?> lastArgs() => orientCalls().last.arguments as List<Object?>;
      expect(
        lastArgs().any((o) => '$o'.contains('landscape')),
        isTrue,
        reason: '进全屏锁横屏',
      );

      // 旋转按钮 → 竖屏
      await tester.tap(find.byKey(const Key('media-rotate')));
      await tester.pumpAndSettle();
      expect(
        (orientCalls().last.arguments as List<Object?>).any(
          (o) => '$o'.contains('portrait'),
        ),
        isTrue,
        reason: '旋转按钮要真的锁竖屏',
      );

      // 退出全屏 → dispose 复位成"所有方向"
      await tester.tap(find.byKey(const Key('media-exit-fullscreen')));
      await tester.pumpAndSettle();
      // ★ r648（DA248）：复位是**两步**（先竖屏、隔一帧再 values），
      // 第二步在真实时间里落地 —— 用例里必须让它真的走完再断言。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MediaPlayerPage), findsNothing);
      // ① 必须先把方向**明确**扳回竖屏（否则平放设备会留在横屏）
      expect(
        orientCalls().any((c) {
          final a = c.arguments as List<Object?>;
          return a.length == 1 && '$a'.contains('portrait');
        }),
        isTrue,
        reason: 'DA248：复位要先锁竖屏，再交还传感器',
      );
      final reset = orientCalls().last;
      final resetArgs = reset.arguments as List<Object?>;
      expect(
        resetArgs.any((o) => '$o'.contains('landscape')) &&
            resetArgs.any((o) => '$o'.contains('portrait')),
        isTrue,
        reason: '退出时必须 DeviceOrientation.values（不能留在横屏）',
      );
      expect(
        calls.any(
          (c) =>
              c.method == 'SystemChrome.setEnabledSystemUIMode' &&
              '${c.arguments}'.contains('edgeToEdge'),
        ),
        isTrue,
        reason: '退出时还原系统栏',
      );
    });
  });

  group('Bug 2：播放器错误要真的有面板，且文案要能区分', () {
    testWidgets('编码不支持 → 具体的编码文案 + 交给系统应用可点', (tester) async {
      final adapter = FakeFullAdapter();
      var opened = 0;
      await _pumpView(
        tester,
        _playable(),
        factory: () => adapter,
        onOpenExternal: () => opened++,
      );
      adapter.failWith(
        'ERROR_CODE_DECODING_FORMAT_UNSUPPORTED: V_THEORA is not supported.',
      );
      await tester.pumpAndSettle();

      expect(find.text('播放失败'), findsOneWidget);
      expect(find.textContaining('系统解码器不支持这个文件的编码'), findsOneWidget);
      expect(find.textContaining('视频用系统播放器看最稳'), findsOneWidget);
      await tester.tap(find.text('用其他应用打开'));
      await tester.pump();
      expect(opened, 1, reason: '回退出路必须真的能点');
    });

    testWidgets('网络失败 → 说清"连不上"，和编码问题不是同一句', (tester) async {
      final adapter = FakeFullAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      adapter.failWith('ERROR_CODE_IO_NETWORK_CONNECTION_FAILED: timeout');
      await tester.pumpAndSettle();
      expect(find.text('播放失败'), findsOneWidget);
      expect(find.textContaining('连不上文件地址'), findsOneWidget);
      expect(find.textContaining('系统解码器不支持'), findsNothing);
    });

    testWidgets('证书不可信 → 仍然是"服务器证书不受信任"（没退化）', (tester) async {
      final adapter = FakeFullAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      adapter.failWith(
        'SSL handshake aborted: Trust anchor for cert not found',
      );
      await tester.pumpAndSettle();
      expect(find.text('服务器证书不受信任'), findsOneWidget);
    });

    testWidgets('基础回退适配器也同样上报（video_player 路线）', (tester) async {
      final adapter = FakeBasicAdapter();
      await _pumpView(
        tester,
        _playable(),
        factory: () => adapter,
        onOpenExternal: () {},
      );
      adapter.failWith(
        'ERROR_CODE_DECODING_FORMAT_UNSUPPORTED: V_THEORA is not supported.',
      );
      await tester.pumpAndSettle();
      expect(find.text('播放失败'), findsOneWidget);
      expect(find.textContaining('系统解码器不支持这个文件的编码'), findsOneWidget);
    });

    testWidgets('嗅探失败（响应不是媒体）不再冒充"编码不支持"', (tester) async {
      // ⚠️ 服务端对缺 `_sid`/`SynoToken` 的下载 URL 回 HTTP 200 + JSON 119，
      // Media3 嗅探失败报的就是这串；它和"真正的编码不支持"在文本上无法区分，
      // 旧实现把它归到 codecUnsupported → 对正常 H.264 误报"编码不支持"。
      final adapter = FakeBasicAdapter();
      await _pumpView(
        tester,
        _playable(),
        factory: () => adapter,
        onOpenExternal: () {},
      );
      adapter.failWith(
        'UnrecognizedInputFormatException: none of the extractors',
      );
      await tester.pumpAndSettle();
      expect(find.text('播放失败'), findsOneWidget);
      expect(find.textContaining('系统解码器不支持'), findsNothing);
      expect(find.textContaining('视频用系统播放器看最稳'), findsOneWidget);
    });
  });

  group('Bug 1 回归：音频舞台按钮在**真实主题**下必须画得出来且能点', () {
    Future<FakeVoicePlayer> pumpAudio(
      WidgetTester tester,
      MediaSource source, {
      FakeVoicePlayer? player,
    }) async {
      final p = player ?? FakeVoicePlayer();
      final container = ProviderContainer(
        overrides: [voicePlayerProvider.overrideWithValue(p)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            // ⚠️ 真实主题：`filledButtonTheme.minimumSize = Size.fromHeight(48)`
            theme: AppTheme.dark(),
            home: Scaffold(
              body: MediaAudioStage(
                entry: _entry('mediaverify-tone.wav'),
                source: source,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return p;
    }

    testWidgets('时长未知（--:--）时按钮与时间文字都有非零尺寸，且点了真的 play', (tester) async {
      final player = await pumpAudio(
        tester,
        _playable(
          kind: MediaKind.audio,
          name: 'mediaverify-tone.wav',
          uri:
              'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download&_sid=S1',
        ),
      );
      // 真机复现时的状态：时长还没拿到 → `--:--`
      expect(find.text('--:--'), findsOneWidget);

      final button = tester.getSize(find.byKey(const Key('audio-play-pause')));
      expect(button.width, greaterThan(0), reason: '按钮被挤成 0 宽就是真机那个 bug');
      expect(button.height, greaterThan(0));

      final total = tester.getSize(find.text('--:--'));
      expect(total.width, greaterThan(0), reason: '两侧时间不能被挤没');
      final progress = tester.getSize(find.text('00:00'));
      expect(progress.width, greaterThan(0));

      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(player.played.single, contains('_sid=S1'), reason: '必须真的能点播');
    });

    testWidgets('拿到时长后：按钮可点、拖进度真的 seek', (tester) async {
      final player = FakeVoicePlayer()..duration = const Duration(seconds: 100);
      await pumpAudio(
        tester,
        _playable(kind: MediaKind.audio, name: 'song.mp3'),
        player: player,
      );
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(player.played, hasLength(1));

      final slider = tester.widget<Slider>(
        find.byKey(const Key('audio-progress')),
      );
      expect(slider.onChanged, isNotNull);
      slider.onChangeStart!(42 * 1000);
      slider.onChanged!(42 * 1000);
      slider.onChangeEnd!(42 * 1000);
      await tester.pumpAndSettle();
      expect(player.seeks.single, const Duration(seconds: 42));
      expect(tester.getSize(find.text('00:42')).width, greaterThan(0));
    });
  });

  // ===== r630：播放器控制条改版（DA210 修法的用例）—— 三层结构 / 主控不折叠 / 拖动气泡
  //   DA212（英文界面下面板标题仍中文）的回归入口也在这组：面板标题取 `.photoPlaybackSettings`，
  //   真机英文环境读数见 docs/evidence-r630/device_player_after_settings_sheet_en.png。
  group('r630 新版控制条', () {
    testWidgets('窄屏 360dp：播放键与 ±10、上一集/下一集都在「主控行」里，不折进 ⋮', (tester) async {
      tester.view.physicalSize = const Size(1080, 2160);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final adapter = FakeFullAdapter()..count = 3;
      await _pumpView(tester, _playable(), factory: () => adapter);

      for (final key in const [
        'media-play-pause',
        'media-back10',
        'media-forward10',
        'media-next',
        'media-prev',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(const Key('media-primary-row')),
            matching: find.byKey(Key(key)),
          ),
          findsOneWidget,
          reason: '$key 不在主控行里（窄屏被折叠 ⇒ 用户要开菜单才能播放）',
        );
      }
      // 48dp 是最小点击区
      final size = tester.getSize(find.byKey(const Key('media-play-pause')));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('进度区给「当前 / 总时长」两个独立读数', (tester) async {
      final adapter = FakeFullAdapter()..duration = const Duration(seconds: 252);
      await _pumpView(tester, _playable(), factory: () => adapter);
      await adapter.seekTo(const Duration(seconds: 13));
      adapter.emit();
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('media-time-current'))).data,
        '00:13',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('media-time-total'))).data,
        '04:12',
      );
    });

    testWidgets('拖动进度：气泡给出目标时间与增量，松手后消失', (tester) async {
      final adapter = FakeFullAdapter();
      await _pumpView(tester, _playable(), factory: () => adapter);
      expect(find.byKey(const Key('media-seek-bubble')), findsNothing);
      final slider = tester.widget<Slider>(
        find.byKey(const Key('media-progress')),
      );
      slider.onChangeStart!(40000);
      slider.onChanged!(40000);
      await tester.pump();
      final bubble = find.byKey(const Key('media-seek-bubble'));
      expect(bubble, findsOneWidget);
      expect(
        tester.widget<Text>(find.descendant(of: bubble, matching: find.byType(Text))).data,
        contains('00:40'),
      );
      slider.onChangeEnd!(40000);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('media-seek-bubble')), findsNothing);
      expect(adapter.seeks.single, const Duration(seconds: 40));
    });
  });

  group('DA247 全屏往返：全屏页借同一个适配器，不碰原生资源', () {
    // 真机现场（2026-10-23）：进全屏再退回来，预览页**画面全黑**、进度钉死、
    // 点播放图标会变但不前进。根因：原生桥只有**一个** `player` + **一个**
    // `textureEntry`，全屏页（另一个 MediaPlayerView）自己又建了一个适配器，
    // 它 `dispose()` 时把预览页那份一起 `releasePlayer()` 掉 ⇒ 预览页手里的
    // `textureId` 成了死 ID。
    // 修法：全屏页**借用**预览页的适配器（同一个 player / 同一条位置）。
    // 判据：进出全屏**不多建**适配器、**不 dispose** 预览页的适配器、
    //       也**不重新 load**（重新 load 会把进度拉回 00:00）。
    testWidgets('进出全屏不多建、不 dispose、不重载', (tester) async {
      final made = <FakeFullAdapter>[];
      await _pumpView(
        tester,
        _playable(),
        factory: () {
          final a = FakeFullAdapter()..duration = const Duration(minutes: 10);
          made.add(a);
          return a;
        },
      );
      await tester.pumpAndSettle();
      final first = made.first;
      await first.seekTo(const Duration(seconds: 30));
      await tester.pump();
      final loadsBefore = first.loaded.length;

      await tester.tap(find.byKey(const Key('media-fullscreen')));
      await tester.pumpAndSettle();
      expect(
        made.length,
        1,
        reason: '全屏页必须借同一个适配器（再建一个就会把原生纹理抢走）',
      );
      expect(
        find.byKey(const Key('media-exit-fullscreen')),
        findsOneWidget,
        reason: '已经在全屏页里（借来的适配器也要显示退出入口）',
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(first.disposes, 0, reason: '预览页的适配器不许被全屏页收拾掉');
      expect(
        first.loaded.length,
        loadsBefore,
        reason: '回来不许重新 load（会把进度拉回 00:00）',
      );
      expect(
        tester.widget<MediaPlayerView>(find.byType(MediaPlayerView).first).adapter,
        isNull,
        reason: '预览页是**拥有者**（没有借别人的）',
      );
    });
  });
}
