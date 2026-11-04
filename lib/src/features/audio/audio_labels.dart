// Audio Station 的**界面层文案 / 格式化**（数据层给值，界面层给文字）。
//
// 为什么单独一个文件：`lib/src/data/**` 不许 import flutter（要能被
// `dart run tool/*.dart` 加载），所以"枚举/状态 → 可读文案"的映射只能放在
// 界面层。这是本项目处理"纯 Dart 文件不能引 Flutter"的通用套路
// （见 docs/app-identity-and-i18n.md §4.6），与 `download_labels.dart` 同款。
library;

import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../data/dto/audio_station_dto.dart';

/// 音乐库标签页 → 文案。
String asTabLabel(AppText t, AudioBrowseKind kind) => switch (kind) {
  AudioBrowseKind.song => t.asTabSongs,
  AudioBrowseKind.album => t.asTabAlbums,
  AudioBrowseKind.artist => t.asTabArtists,
  AudioBrowseKind.genre => t.asTabGenres,
  AudioBrowseKind.folder => t.asTabFolders,
  AudioBrowseKind.playlist => t.asTabPlaylists,
  AudioBrowseKind.composer => t.asSearchGroupComposers,
};

/// 某标签页"一条都没有" → 文案。
String asEmptyLabel(AppText t, AudioBrowseKind kind) => switch (kind) {
  AudioBrowseKind.song => t.asEmptySongs,
  AudioBrowseKind.album => t.asEmptyAlbums,
  AudioBrowseKind.artist => t.asEmptyArtists,
  AudioBrowseKind.genre => t.asEmptyGenres,
  AudioBrowseKind.folder => t.asEmptyFolders,
  AudioBrowseKind.playlist => t.asEmptyPlaylists,
  // wave2：作曲家是独立标签页 → 不能借用"艺术家"的空态文案（会撒谎）。
  AudioBrowseKind.composer => asEmptyComposers,
};

/// 详情页列表段标题 → 文案（如艺术家详情里的"专辑"）。
String asDetailLabel(AppText t, AudioBrowseKind kind) => switch (kind) {
  AudioBrowseKind.album => t.asDetailAlbums,
  AudioBrowseKind.song => t.asDetailSongs,
  AudioBrowseKind.artist => t.asDetailArtists,
  AudioBrowseKind.folder => t.asDetailFolders,
  AudioBrowseKind.composer => t.asSearchGroupComposers,
  AudioBrowseKind.genre => t.asDetailArtists,
  AudioBrowseKind.playlist => t.asDetailSongs,
};

/// 详情页"一条都没有" → 文案。
String asDetailEmptyLabel(AppText t, AudioBrowseKind kind) => switch (kind) {
  AudioBrowseKind.album => t.asEmptyDetailAlbums,
  AudioBrowseKind.artist => t.asEmptyDetailArtists,
  AudioBrowseKind.genre => t.asEmptyDetailArtists,
  AudioBrowseKind.song => t.asEmptyDetailSongs,
  AudioBrowseKind.folder => t.asEmptyFolders,
  AudioBrowseKind.composer => asEmptyDetailComposers,
  AudioBrowseKind.playlist => t.asEmptyDetailSongs,
};

/// 音乐库总条数 → 文案（按分类选量词）。
String asCountLabel(AppText t, AudioBrowseKind kind, int total) =>
    switch (kind) {
      AudioBrowseKind.song || AudioBrowseKind.folder => t.asSongCount(total),
      AudioBrowseKind.album => t.asAlbumCount(total),
      AudioBrowseKind.artist ||
      AudioBrowseKind.genre => t.asArtistCount(total),
      // wave2：作曲家是独立分类 → 量词不能借用"艺术家"。
      AudioBrowseKind.composer => asComposerCount(total),
      AudioBrowseKind.playlist => t.asSongCount(total),
    };

/// 播放列表徽标（个人/共享 + 智能）。
String asPlaylistBadge(AppText t, AudioPlaylistDto p) {
  final scope = p.library == 'shared'
      ? t.asSharedPlaylist
      : t.asPersonalPlaylist;
  return p.isSmart ? '$scope · ${t.asSmartPlaylist}' : scope;
}

/// 采样率：`44100` → `44.1 kHz`（纯符号，不翻译）。
String asFrequencyText(int hz) {
  if (hz <= 0) return '';
  if (hz % 1000 == 0) return '${hz ~/ 1000} kHz';
  return '${(hz / 1000).toStringAsFixed(1)} kHz';
}

/// 声道：`2` → `2ch`（纯符号，不翻译）。
String asChannelText(int channel) => channel > 0 ? '${channel}ch' : '';

/// 单曲**次要行**：时长 · 码率 · 采样率 · 大小（缺什么少什么）。
String asSongMetaLine(AudioSongDto song, {bool withSize = true}) {
  final parts = <String>[
    if (song.duration > 0) song.durationText,
    if (song.bitrate > 0) song.bitrateText,
    if (song.frequency > 0) asFrequencyText(song.frequency),
    // ★ r482（DA120）：**列表行**不画体积。设计稿的次要行是
    //   "artist · album · 3:51 · 320 kbps"，真机上多一个体积字段就把行
    //   挤到省略号（`9.0…` 这种"数字被切一半"最难看）。体积留在单曲页。
    if (withSize && song.filesize > 0) asHumanBytes(song.filesize),
  ];
  return parts.join(' · ');
}

/// **给人看的**那一行元数据（r631）：只有时长，最多再带年份。
///
/// 为什么要把技术参数从这里拿掉（用户 2026-10-23 原话）：
/// 「很多音频技术参数没有必要罗列在界面上，可以收在某一个菜单项里，
///   界面上应该更多是给人类使用的功能」。
///
/// 旧行为（`asSongMetaLine`）在**列表行**与**单曲页标题下**都写
/// `3:51 · 320 kbps · 44.1 kHz · 9.0 MB` —— 比特率/采样率/体积是
/// **排障信息**，不是用户选歌时要看的；它们现在只在「歌曲信息」面板里出现。
///
/// 保留 `asSongMetaLine` 本身：那个面板仍然按原样展示全部技术字段。
String asSongHumanMetaLine(AudioSongDto song) {
  final parts = <String>[
    if (song.duration > 0) song.durationText,
    if (song.year > 0) '${song.year}',
  ];
  return parts.join(' · ');
}

/// 播放进度**左端**的读数（r638 / **DA231**）。
///
/// 缺口（真机像素 `docs/evidence-r638/05_进度零位是破折号.png`）：还没起播
/// 或者刚拖回 0 时，左端写的是 `—`（`asDurationText(0)` 的"未知"约定）。
/// 用户读到的却是"**不知道播到哪儿**"——而事实是"**在开头**"。
/// 起点与"不知道"是两件事：0 秒就该写 `0:00`。
///
/// 右端（总长）继续保持"未知就写 `—`"：那是**真的不知道**这个文件多长。
String asPositionText(Duration position) {
  if (position <= Duration.zero) return '0:00';
  return asDurationText(position.inSeconds);
}

/// 队列行的标题 —— **认不出的标题就退到文件名，绝不把乱码原样画给用户**
/// （r486 / `DA127`：真机 Play queue 里唯一那行标题是
/// `αφąÊ¤øαĂα+Õś…`，是服务端回的字节被按 Latin-1/希腊字母解出来的残渣）。
///
/// 判据是"像不像一段人话"：CJK 直接算；纯 ASCII 字母数字算；
/// 若 Latin-1 补充区（U+0080–U+00FF）与希腊字母区（U+0370–U+03FF）
/// 占比 > 0.3 就判定为乱码（正常西文名如 `café` 只有 0.25）。
String asQueueDisplayTitle(String title, String path) {
  final t = title.trim();
  if (t.isNotEmpty && _looksLikeText(t)) return t;
  final base = path.split('/').last.trim();
  if (base.isNotEmpty && _looksLikeText(base)) return base;
  return dataText('asUnnamedName', '未命名');
}

bool _looksLikeText(String s) {
  var suspicious = 0;
  var meaningful = 0;
  for (final r in s.runes) {
    if ((r >= 0x4E00 && r <= 0x9FFF) ||
        (r >= 0x3040 && r <= 0x30FF) ||
        (r >= 0xAC00 && r <= 0xD7AF)) {
      meaningful++;
      continue;
    }
    if ((r >= 0x30 && r <= 0x39) ||
        (r >= 0x41 && r <= 0x5A) ||
        (r >= 0x61 && r <= 0x7A)) {
      meaningful++;
      continue;
    }
    if ((r >= 0x80 && r <= 0xFF) || (r >= 0x370 && r <= 0x3FF)) {
      suspicious++;
    }
  }
  final total = s.runes.length;
  if (meaningful == 0) return false;
  return suspicious / total <= 0.3;
}

/// 列表里显示的"名字"——**空名字必须有占位**（r486 / `DA126`）。
///
/// 真机上艺术家分页第一条只有图标和箭头、没有一个字：服务端下发了
/// `name: ""`，而 `Text('')` 就是一行看不见的可点区域（正是用户抱怨的
/// "看不见却能点的元素"）。三处名字型列表（专辑/艺术家流派作曲家/播放列表）
/// 都必须经过这里。
String asDisplayName(String raw) =>
    raw.trim().isEmpty ? dataText('asUnnamedName', '未命名') : raw;

/// 专辑次要行：专辑艺术家 · 年份 · 平均评分。
String asAlbumMetaLine(AudioAlbumDto album) {
  final parts = <String>[
    if (album.albumArtist.isNotEmpty) album.albumArtist,
    if (album.year > 0) '${album.year}',
    if (album.avgRating > 0) '★${album.avgRating.toStringAsFixed(1)}',
  ];
  return parts.join(' · ');
}

/// 名字型记录（艺术家/作曲家/流派）次要行：平均评分。
String asNameMetaLine(AudioNameDto name) =>
    name.avgRating > 0 ? '★${name.avgRating.toStringAsFixed(1)}' : '';

/// 收藏记录类型 → 文案（认不出就回原类型名，不编）。
String asPinTypeLabel(AppText t, String type) => switch (type) {
  'album' => t.asTabAlbums,
  'artist' => t.asTabArtists,
  'genre' => t.asTabGenres,
  'folder' => t.asTabFolders,
  'playlist' => t.asTabPlaylists,
  'composer' => t.asSearchGroupComposers,
  _ => type,
};

// ---------------------------------------------------------------- 网络电台（wave2）

// 以下文案经 `dataText(key, 中文回落)` 取译文（key 已登记进 `dataTextMap`）：
// 英文模式下查表得英文，查不到/未装翻译器时回落中文原文。

/// 电台页标题 / 入口 tooltip。
String get asRadioTitle => dataText('asRadioTitle', '网络电台');

/// 一条电台都没有。
String get asRadioEmpty => dataText('asRadioEmpty', '还没有电台');

/// ★ r441：关键字搜台（`Radio.search` v2）。
String get asRadioSearchTitle => dataText('asRadioSearchTitle', '搜台');

String get asRadioSearchHint =>
    dataText('asRadioSearchHint', '输入关键字搜索网络电台');

String get asRadioSearchEmpty =>
    dataText('asRadioSearchEmpty', '没有匹配的电台');

/// 服务器只支持 `Radio.list` v1（没有 `Radio.search`）时的如实空态。
String get asRadioSearchUnsupported =>
    dataText('asRadioSearchUnsupported', '这台 NAS 的 Audio Station 不支持关键字搜台');

/// 电台列表加载失败（区分于空态）。
String get asRadioLoadFailed => dataText('asRadioLoadFailed', '电台加载失败');

/// `type:"container"` 的**分类容器**徽标（真机首屏回的就是容器，不是电台项）。
String get asRadioContainerBadge =>
    dataText('asRadioContainerBadge', '电台分类');

/// 可播放电台项的兜底徽标（没有 `desc` 时用）。
String get asRadioStationBadge => dataText('asRadioStationBadge', '电台');

/// 电台页顶部的**如实提示**（第 392 轮起**真的能播了**）：
/// 点分类进下一层、点电台即起播；SHOUTcast 的地址是 `.pls` 播放列表，
/// 起播前先解析出真正的流地址。
///
/// ⚠️ 就地订正（第 392 轮）：这里的**中文回落**原先写的是
/// "本页只列出电台条目；电台播放暂未提供。" —— 修好播放后它就成了**撒谎的副本文案**
/// （没装翻译器/查不到 key 的路径会显示它）。回落必须与 ARB 同义。
String get asRadioListNote => dataText(
  'asRadioListNote',
  '点分类进入下一层；点电台即开始播放。SHOUTcast 的地址是 .pls 播放列表，起播前会先解析出真正的流地址。',
);

/// **这个电台没能开始播放**（第 393 轮修 DA43；起播失败必须说出来，不许静默）。
///
/// 为什么不带引擎原文：引擎给的是诊断串（`None of the available extractors …`
/// / `describePlaybackError` 摘要），那是给日志的，不是给用户的（AGENTS §2.0.47）。
String get asRadioPlayFailed =>
    dataText('asRadioPlayFailed', '这个电台没能开始播放，可以换一个电台或重试。');

/// 播放条上的**简短**失败态（r641 / **DA234**）。
///
/// 为什么还要一条短的：完整那句是给提示条的；播放条副标题只有一行，
/// 写全会被截断（"这个电台没能开始播放，可以换…"）。短句 + 重试键足够。
String get asRadioPlayFailedShort =>
    dataText('asRadioPlayFailedShort', '没能播放');

/// 上面那条提示的**重试**动作文案。
String get asRadioPlayRetry => dataText('asRadioPlayRetry', '重试');

/// 作曲家分类的空态（wave2；不借用"艺术家"文案）。
String get asEmptyComposers => dataText('asEmptyComposers', '还没有作曲家');

/// 作曲家详情页的空态（wave2）。
String get asEmptyDetailComposers =>
    dataText('asEmptyDetailComposers', '这里还没有作曲家');

/// 作曲家条数（wave2；不借用 `asArtistCount`）。
String asComposerCount(int total) =>
    dataText('asComposerCount', '{n} 位作曲家').replaceAll('{n}', '$total');

// ---------------------------------------------------------------- 服务端播放队列（wave2）

/// 服务端 Web Player 队列面板标题。
String get asWebQueueTitle => dataText('asWebQueueTitle', '播放队列');

/// 服务端队列为空。
String get asWebQueueEmpty =>
    dataText('asWebQueueEmpty', '服务端播放队列是空的');

/// 服务端队列加载失败。
String get asWebQueueLoadFailed =>
    dataText('asWebQueueLoadFailed', '播放队列加载失败');

/// 能力表缺 `AudioStation.WebPlayer` → 明确说"不支持"，不给必然失败的入口。
String get asWebQueueUnsupported => dataText(
  'asWebQueueUnsupported',
  '这台 NAS 的 Audio Station 不支持播放队列',
);

/// 随机播放：开。
String get asWebQueueShuffleOn => dataText('asWebQueueShuffleOn', '随机播放：开');

/// 随机播放：关。
String get asWebQueueShuffleOff =>
    dataText('asWebQueueShuffleOff', '随机播放：关');

/// 播放模式 `normal`（唯一已取证取值）。
String get asWebQueueModeNormal => dataText('asWebQueueModeNormal', '顺序播放');

/// 播放模式 → 文案；**认不出的模式回原值**（不编）。
String asWebQueueModeText(String mode) {
  if (mode.isEmpty) return '';
  if (mode == 'normal') return asWebQueueModeNormal;
  return mode;
}
