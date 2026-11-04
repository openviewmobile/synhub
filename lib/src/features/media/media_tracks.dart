// 完整播放器控制的**纯数据模型**（音轨 / 字幕轨 / 画面比例 / 音量）。
//
// 这一层**不许** import flutter / package:flutter / l10n：
// `dart run tool/*.dart` 要用纯 Dart VM 直接加载它（同 `media_source.dart`）。
// 所以：
//   * 轨道参数一律是**结构化字段**（语言 / 编码 / 声道 / 是否默认），不是文案；
//   * 需要显示的名字由界面层拼（`context.t`），这里只给"没有 label 时的兜底串"。
//
// 事实来源：Media3 `androidx.media3.common.Tracks` / `Format`（1.4.1，
// 与 `video_player_android` 2.8.7 内部使用的版本一致）。原生桥把
// `Tracks.Group` 摊平成 `Map`，这里按同一套键回读（见 `MediaPlayerBridge.kt`）。
library;

/// 画面比例模式。
///
/// 与 ExoPlayer `AspectRatioFrameLayout` 的 resize mode 对照：
///   * [fit]     → `RESIZE_MODE_FIT`（contain：整幅画面放得下，四周可能留黑边）= 默认；
///   * [fill]    → `RESIZE_MODE_ZOOM` 的"无变形铺满"（cover：铺满容器，多出来的裁掉）；
///   * [zoom]    → 在 [fill] 基础上再放大 [kMediaZoomScale] 倍（裁切更狠，用来盖住
///                 硬字幕/水印一类的边缘内容）。放大**必须**做在 `FittedBox`
///                 **外面**（`media_aspect_surface.dart`）：`cover` 对 child 尺寸
///                 **尺度无关**，写进 child 会被精确抵消 —— 那是 `DA88` 的成因
///                 （真机 `Zoom` 与 `Fill` 出画逐字节相同）。
///   * [stretch] → `RESIZE_MODE_FILL`（拉伸铺满：**会变形**，但能占满整屏）。
///
/// 这四个在屏幕上**肉眼可分辨**，所以不做"两个档位其实一样"的假选项。
enum MediaAspectMode {
  fit('fit'),
  fill('fill'),
  zoom('zoom'),
  stretch('stretch');

  const MediaAspectMode(this.code);

  /// 稳定标识（原生通道 / 测试断言用；界面文案不许靠它判断）
  final String code;

  /// 未知/空串 → [fit]（不做假选项也不抛异常）
  static MediaAspectMode fromCode(String? code) {
    for (final mode in values) {
      if (mode.code == code) return mode;
    }
    return fit;
  }
}

/// [MediaAspectMode.zoom] 相对"铺满"的额外放大倍数
const double kMediaZoomScale = 1.25;

/// 轨道类型（原生通道用同一个 `code` 字符串）
enum MediaTrackKind {
  audio('audio'),
  subtitle('subtitle');

  const MediaTrackKind(this.code);
  final String code;
}

/// 当前选中的那一条轨道 —— **以适配器给的 id 为准**，`isSelected` 只作兜底。
///
/// ★ r657（**DA272**，真机撞到）：兜底引擎（`MpvPlayerAdapter`）把选中态放在
///   `selectedSubtitleTrackId` / `selectedAudioTrackId` 里，**不维护每条轨道上的
///   `isSelected`**；而「播放设置」行右侧的值原来只认 `isSelected` ⇒ 选好内封字幕、
///   画面已经在出字，那行却印 **"Subtitles off"**（音轨那行同理会停在 `#1`）。
///   同一个事实只能有一个来源：**id 优先**，`isSelected` 留作老引擎/老包的兜底。
MediaTrackInfo? selectedMediaTrack(
  Iterable<MediaTrackInfo> tracks,
  String? selectedId,
) {
  if (selectedId != null && selectedId.isNotEmpty) {
    for (final track in tracks) {
      if (track.id == selectedId) return track;
    }
  }
  for (final track in tracks) {
    if (track.isSelected) return track;
  }
  return null;
}

/// 一条可选轨道（音轨或**内封**字幕轨）。
///
/// 字段与 Media3 `Format` 一一对应：`id` / `label` / `language` / `codec` /
/// `channelCount` / `selectionFlags(DEFAULT)`；另外带上原生侧重建
/// `TrackSelectionOverride` 需要的 `groupIndex` / `trackIndex`。
class MediaTrackInfo {
  const MediaTrackInfo({
    required this.id,
    required this.kind,
    this.label = '',
    this.language = '',
    this.codec = '',
    this.channels = 0,
    this.isDefault = false,
    this.isSelected = false,
    this.isSupported = true,
    this.isExternal = false,
    this.groupIndex = 0,
    this.trackIndex = 0,
  });

  /// 原生侧给的稳定 id（形如 `audio:0:1`；重建 override 时直接解析它）
  final String id;

  final MediaTrackKind kind;

  /// `Format.label`（容器里写的标题，可能为空）
  final String label;

  /// `Format.language`（ISO 639-2/T，例如 `zho` / `eng`；可能为空）
  final String language;

  /// `Format.codec`（例如 `mp4a.40.2` / `subrip`）
  final String codec;

  /// 声道数（音轨才有意义；0 = 未知）
  final int channels;

  /// `Format.selectionFlags & SELECTION_FLAG_DEFAULT`
  final bool isDefault;

  /// 当前是否被选中（从 `Tracks.Group.isTrackSelected` 回读）
  final bool isSelected;

  /// ★ r654（`DA260`）：**本机能不能解码这一条**（`Tracks.Group.isTrackSupported`）。
  ///
  /// 为什么非要这个字段：容器里出现 AC3/EAC3/DTS 音轨时，vanilla Media3 没有
  /// 软件解码器，设备也没有硬解 —— 它会**照常出画面、但不出声**。之前在界面上
  /// 这条音轨和一普通音轨长得一样，用户只会得出"这个 App 播放没声音"。
  /// 默认 `true`：老原生包不给这个键时行为与改前一致（不做假告警）。
  final bool isSupported;

  /// 是不是**外挂**字幕（Dart 侧解析出来的；原生只认内封）
  final bool isExternal;

  final int groupIndex;
  final int trackIndex;

  /// 界面显示名：label → 语言 → `#序号`
  ///
  /// **不是**本地化文案（纯逻辑层不碰 l10n）：只是为了"没标签时别显示空白"。
  ///
  /// ★ r645（**DA243**，真机 2026-10-23）：这里原来还有一档 `codec` 兜底，
  ///   于是「播放设置 → 音轨」那行右侧印出的是 **`audio/mpeg`** —— 一个 MIME 串。
  ///   容器没给标题、也没给语言时，用户看到的是协议名而不是"第几条音轨"，
  ///   这跟"技术参数别摆界面上"是同一件事。**编码不再当名字**：
  ///   它仍写在第二行（`detail`，小字，选轨时用来区分两条同语言音轨），
  ///   但名字档位只到 `#序号` 为止。
  String get displayLabel {
    final l = label.trim();
    if (l.isNotEmpty && !_looksLikeMimeOrCodec(l)) return l;
    if (language.isNotEmpty) return mediaLanguageName(language);
    return '#${trackIndex + 1}';
  }

  /// `audio/mpeg` / `application/x-subrip` 这种**协议名**，或 `mp4a.40.2`
  /// 这种**编码 id**：都不该出现在"名字"的位置。
  static bool _looksLikeMimeOrCodec(String v) {
    final mime = RegExp(r'^[a-z]+/[\w.+-]+$').hasMatch(v);
    final codecId = RegExp(r'^[a-z0-9]+(\.[a-z0-9]+){2,}$').hasMatch(v);
    return mime || codecId;
  }

  /// 音轨的补充说明（声道 / 编码），字幕轨给语言
  String get detail {
    final parts = <String>[];
    if (codec.isNotEmpty) parts.add(codec);
    if (channels > 0) parts.add('$channels ch');
    return parts.join(' · ');
  }

  MediaTrackInfo copyWith({
    bool? isSelected,
    bool? isExternal,
    bool? isSupported,
  }) =>
      MediaTrackInfo(
        id: id,
        kind: kind,
        label: label,
        language: language,
        codec: codec,
        channels: channels,
        isDefault: isDefault,
        isSelected: isSelected ?? this.isSelected,
        isExternal: isExternal ?? this.isExternal,
        isSupported: isSupported ?? this.isSupported,
        groupIndex: groupIndex,
        trackIndex: trackIndex,
      );

  /// 原生 `Map` → 模型（缺字段一律**按默认值**，不抛）
  ///
  /// 键名与 `MediaPlayerBridge.kt` 的 `trackMap()` 逐字对应；
  /// 这样"通道换了"只改一处。
  factory MediaTrackInfo.fromMap(Map<Object?, Object?> map) {
    final kindCode = '${map['kind'] ?? 'audio'}';
    return MediaTrackInfo(
      id: '${map['id'] ?? ''}',
      kind: kindCode == MediaTrackKind.subtitle.code
          ? MediaTrackKind.subtitle
          : MediaTrackKind.audio,
      label: '${map['label'] ?? ''}',
      language: '${map['language'] ?? ''}',
      codec: '${map['codec'] ?? ''}',
      channels: _intOf(map['channels']),
      isDefault: map['default'] == true,
      isSelected: map['selected'] == true,
      isExternal: map['external'] == true,
      // 缺键 → true（老包兼容；见字段注释）
      isSupported: map['supported'] != false,
      groupIndex: _intOf(map['group']),
      trackIndex: _intOf(map['index']),
    );
  }

  /// 模型 → `Map`（测试里造事件用；形状与原生一致）
  Map<String, Object?> toMap() => {
    'id': id,
    'kind': kind.code,
    'label': label,
    'language': language,
    'codec': codec,
    'channels': channels,
    'default': isDefault,
    'selected': isSelected,
    'external': isExternal,
    'supported': isSupported,
    'group': groupIndex,
    'index': trackIndex,
  };

  @override
  String toString() =>
      'MediaTrackInfo(${kind.code}/$id, lang=$language, default=$isDefault, '
      'selected=$isSelected)';
}

int _intOf(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse('${raw ?? ''}') ?? 0;
}

/// 解析原生 `List` → 轨道模型列表（非 Map 项直接跳过，不抛）
List<MediaTrackInfo> parseTrackList(Object? raw) {
  if (raw is! List) return const [];
  final out = <MediaTrackInfo>[];
  for (final item in raw) {
    if (item is Map) {
      out.add(MediaTrackInfo.fromMap(Map<Object?, Object?>.from(item)));
    }
  }
  return out;
}

/// 常见 ISO 639 语言码 → 可读名（**静态数据表**，不是 l10n）
///
/// 只覆盖最常见的十几条；认不出就原样返回（例如 `zho` 之外的冷门语言）。
/// 界面只在"容器没写 label"时才用它兜底，所以永远有东西可显示。
String mediaLanguageName(String code) {
  final key = code.toLowerCase().replaceAll('_', '-');
  final base = key.split('-').first;
  const table = <String, String>{
    'zh': '中文',
    'zho': '中文',
    'chi': '中文',
    'chs': '简体中文',
    'cht': '繁体中文',
    'hans': '简体中文',
    'hant': '繁体中文',
    'en': 'English',
    'eng': 'English',
    'ja': '日本語',
    'jpn': '日本語',
    'ko': '한국어',
    'kor': '한국어',
    'fr': 'Français',
    'fra': 'Français',
    'fre': 'Français',
    'de': 'Deutsch',
    'deu': 'Deutsch',
    'ger': 'Deutsch',
    'es': 'Español',
    'spa': 'Español',
    'ru': 'Русский',
    'rus': 'Русский',
    'pt': 'Português',
    'por': 'Português',
    'it': 'Italiano',
    'ita': 'Italiano',
    'ar': 'العربية',
    'ara': 'العربية',
    'th': 'ไทย',
    'tha': 'ไทย',
    'vi': 'Tiếng Việt',
    'vie': 'Tiếng Việt',
    'und': '未标注',
  };
  return table[key] ?? table[base] ?? code;
}

/// 音轨/字幕轨的"选中"判定：字幕轨 `null` = 关闭
///
/// 放在纯逻辑层是因为"关闭字幕"和"没有字幕轨"是两件事，界面和适配器都要用
/// 同一个判定，不能各写一遍。
bool isTrackSelected(List<MediaTrackInfo> tracks, String? selectedId) =>
    selectedId == null
    ? tracks.every((t) => !t.isSelected)
    : tracks.any((t) => t.id == selectedId && t.isSelected);
