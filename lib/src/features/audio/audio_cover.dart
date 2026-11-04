// Audio Station 封面缩略图（列表行 / 单曲页头图）。
//
// **接线说明**：`AudioStationApi` 的 5 个封面 URL 方法此前**只有测试引用**
// （审计 `docs/audio-parity-audit.md` §4.2 死代码清单第 2–6 条）。本批接进 UI：
//   * `songCoverUrl`   → 单曲页头图；
//   * `albumCoverUrl`  → 专辑行；
//   * `artistCoverUrl` → 艺术家行；
//   * `genreCoverUrl`  → 流派行；
//   * `folderCoverUrl` → 文件夹行（目录）。
// 鉴权形态已修为 `_sid=`（真机实测：`sid=` → 105、`_sid=` → 200 `image/jpeg`，
// 审计 §1.6），封面通道从此可用。
//
// ⚠️ `_dc` 时间戳会让 URL 每次拼都不一样，所以这里**只认第一次拿到的 URL**
// （以 [identity] 作为内容身份）；`identity` 变了才重新取 URL，避免列表重建时
// 反复重新下载同一张图。
//
// W1-2 追加：单曲封面两级 —— **① 文件内嵌封面优先**（[embeddedSongCoverKey]，
// 走 FileStation Range 片段取文件头/尾解析），② 拿不到才退上面的服务器封面
// `Cover.getsongcover`，③ 都没有走图标占位。用户明确要求"音视频同样都要支持
// 内嵌封面图 + 服务器缩略图回退"。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/audio_station_dto.dart';
import '../../data/audio_station.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/filestation_api.dart';
import '../media/authed_image.dart';
import '../media/media_cover_provider.dart';
import '../files/file_thumb.dart' show looksLikeImage;
import '../media/media_source.dart' show MediaKind, resolveFileStationSource;
import 'audio_album_cover.dart';
import 'audio_providers.dart';

/// 单曲文件的**内嵌封面**请求（FileStation Range 片段，不整份下载）。
///
/// 拿不到稳定身份（未连 FileStation / `path` 为空 / 不是文件）→ null →
/// 调用方退回服务器封面。AS 的 `path` 是 DSM 文件路径（`/volume1/music/...`），
/// 所以内嵌封面与文件预览页走同一条 FileStation `Download` 通道。
MediaCoverKey? embeddedSongCoverKey({
  required AudioSongDto song,
  required FileStationApi? fs,
}) {
  if (fs == null || song.path.isEmpty) return null;
  final name = song.path.split('/').last;
  if (name.isEmpty || name == song.path) return null;
  final entry = FileEntryDto(
    name: name,
    path: song.path,
    isDir: false,
    size: song.filesize,
    mtime: 0,
  );
  final source = resolveFileStationSource(
    displayName: name,
    kind: MediaKind.audio,
    fs: fs,
    path: song.path,
    size: song.filesize,
  );
  return mediaCoverKeyFor(entry, source);
}

/// 把封面字节**交给 handler**（`mediaItem.artUri` 的唯一入口）。
///
/// ★ r653（`DA254`）真机缺陷的形状：取图是**异步**的，而"当前播放区"在切歌时
/// 会被整块重建 —— 老的 State 在 `await` 回来时 `mounted == false`，
/// 原来的写法在这里 `return`，于是**已经拿到手的 55 KB 封面被丢掉**
/// （logcat：`attach idx=1 … bytes=55253 mounted=false`），
/// 通知栏就成了"第一首有图、下一首没图"。
///
/// 判据：这件事与"发起取图的页面还在不在"无关 —— artUri 是按**曲目 id**
/// 存的，播的不是它就不会被显示。所以这里只保留两条真实的否决条件：
/// **没取到** / **取到空**；不许出现生命周期判据。
Future<void> deliverCoverBytesToHandler({
  required String mediaId,
  required Future<Uint8List?> Function() load,
  required Future<void> Function(String mediaId, Uint8List bytes) attach,
}) async {
  Uint8List? bytes;
  try {
    bytes = await load();
  } catch (_) {
    // 取图失败 = 没有封面（不许把异常抛进播放链路）
    bytes = null;
  }
  if (bytes == null || bytes.isEmpty) return;
  await attach(mediaId, bytes);
}

/// ★ r653（`DA254`）：**通知栏/锁屏封面**的字节 —— 内嵌优先，退服务器封面。
///
/// 真机缺口：`Audio Station` 的歌 `path` 常常为空 ⇒ [embeddedSongCoverKey] 给
/// null ⇒ 通知栏**从来没有封面**（`largeIcon=null`），而页面上明明有那张
/// `Cover.getsongcover` 的图。同一个东西在两处显示，却只有一处能拿到图。
///
/// 三条纪律（沿用既有口径）：
///   * 只把**已经是图**的字节交出去（`looksLikeImage`；`entry.cgi` 偶尔
///     用 200 回一整页 HTML）；
///   * 任何一步失败都**不打断播放**，只是"没有封面"（如实降级）；
///   * 取到的字节只用于**本地** `file://` artUri —— 带 `_sid` 的 URL 不交给系统。
Future<Uint8List?> resolveNotificationCoverBytes({
  required Future<Uint8List?> Function() embedded,
  required Future<List<int>> Function() fetchServerCover,
}) async {
  try {
    final local = await embedded();
    if (local != null && local.isNotEmpty && looksLikeImage(local)) return local;
  } catch (_) {
    // 内嵌封面解析失败 ⇒ 继续走服务器封面
  }
  try {
    final raw = await fetchServerCover();
    final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    return looksLikeImage(bytes) ? bytes : null;
  } catch (_) {
    return null;
  }
}

/// **专辑行**的两级封面回退（r439）：主 URL（专辑级 `Cover.getcover`）取不到图时，
/// 交给 [AlbumCoverResolver] 逐首探 `getsongcover`（有界 ＋ 会话级负缓存）。
///
/// `identity` 传 `album.name`，与 [AudioCoverImage.identity] **一致**（共享取图缓存）。
Future<String?> Function()? albumCoverFallbackOf(
  AlbumCoverResolver? resolver,
  AudioAlbumDto album, {
  /// ★ r638：**列表行**的 `AudioCoverImage.identity` 与专辑网格不同
  /// （`song-row-album:<专辑>|<艺人>`，避免同名不同艺人串图）。
  /// 解析器写缓存用的键里含 identity ⇒ 这里必须传**同一个**，否则
  /// "探到了却没有命中" 会让同一张封面多打一次 NAS（r638 用例②当场抓到）。
  String? identity,
}) {
  if (resolver == null) return null;
  return () => resolver.resolve(
    album: album.name,
    albumArtist: album.albumArtist,
    identity: identity ?? album.name,
    // 主 URL 已经失败才会走到这里 ⇒ 专辑级不必再探一遍
    albumAlreadyTried: true,
  );
}

/// 异步封面图：拿不到就回落到 [fallbackIcon]（与原列表 `leading` 图标一致）。
///
/// ★ **DA86（r427）**：这里原来直接 `Image.network(url)`。真机取证表明它在本
/// 环境**恒不显示**（设备按 IP 连 NAS、证书 SAN 只有 `*.nas.example.com`
/// ⇒ hostname mismatch ⇒ 握手失败 ⇒ 静默退回图标）。现在改走**应用自己的
/// 鉴权字节通道**（`AudioStationApi.api.getBytes` = Dio + TrustStore + `_sid`）
/// 再由 [AuthedImage] 出 `Image.memory`。`url: null` 的同步分支行为不变。
class AudioCoverImage extends ConsumerStatefulWidget {
  const AudioCoverImage({
    super.key,
    required this.url,
    required this.identity,
    this.size = 40,
    this.fallbackIcon = Icons.music_note_outlined,
    this.radius = 6,
    this.resolveFallback,
  });

  /// 封面 URL（`null` = 没有可用的封面/未连接 → 直接回落）。
  final String? url;

  /// 内容身份（歌曲 id / 专辑名 / 路径…）。变了才重新取 URL。
  final String identity;

  final double size;
  final IconData fallbackIcon;
  final double radius;

  /// **r439**：主 URL 取不到图时再问一次"有没有别的 URL"（专辑封面走
  /// [AlbumCoverResolver] 的逐首探测）。返回 `null`／同一个 URL ⇒ 保持占位图标。
  ///
  /// 只在这个 [identity] 上试**一次**（失败也记住），避免列表重建时反复探测。
  final Future<String?> Function()? resolveFallback;

  @override
  ConsumerState<AudioCoverImage> createState() => _AudioCoverImageState();
}

class _AudioCoverImageState extends ConsumerState<AudioCoverImage> {
  String? _url;

  /// 已经为哪个 [AudioCoverImage.identity] 试过回退（**每张专辑只探一次**）
  String? _fallbackTriedFor;

  /// 正在探（防止同一帧内重复触发）
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _url = widget.url;
  }

  @override
  void didUpdateWidget(AudioCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity ||
        (widget.url == null && oldWidget.url != null)) {
      _url = widget.url;
      _fallbackTriedFor = null;
      _resolving = false;
    }
  }

  /// 主 URL 失败 ⇒ 问一次回退解析器（r439：逐首探 `getsongcover`）。
  void _onPrimaryFailed() {
    final resolve = widget.resolveFallback;
    if (resolve == null || _resolving) return;
    if (_fallbackTriedFor == widget.identity) return;
    _fallbackTriedFor = widget.identity;
    _resolving = true;
    resolve().then((alt) {
      _resolving = false;
      if (!mounted) return;
      if (alt == null || alt.isEmpty || alt == _url) return;
      setState(() => _url = alt);
    }).catchError((Object _) {
      _resolving = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    final fallback = SizedBox(
      width: widget.size,
      height: widget.size,
      child: Icon(widget.fallbackIcon),
    );
    final api = ref.watch(audioApiProvider);
    if (url == null || url.isEmpty || api == null) {
      return fallback;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: AuthedImage(
        key: ValueKey(widget.identity),
        url: url,
        identity: widget.identity,
        // DA86：走鉴权字节通道，不用 `Image.network`
        load: api.api.getBytes,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        fallback: fallback,
        onFailed: widget.resolveFallback == null ? null : _onPrimaryFailed,
      ),
    );
  }
}

/// ★ r638（**DA230**）：**音乐列表行的专辑封面**。
///
/// 用户视角的缺口（真机像素 `docs/evidence-r638/01_列表无封面.png` 与
/// `02_详情有封面.png` 并排看最直观）：**同一首歌**，列表里是同一个灰色音符
/// 图标，点进详情页却是真封面 —— 一屏十行长得一模一样，认不出哪一行是哪张专辑。
/// Plexamp / Apple Music / 群晖官方 AS 的列表都带封面。
///
/// 接线=**与专辑行同一条两级路**（r439 / `DA93`）：主 URL 是专辑级
/// `Cover.getcover`，取不到图才由 [AlbumCoverResolver] 有界逐首探
/// `Cover.getsongcover`。不新造第二套逻辑。
///
/// **URL 记忆**（[SongRowCoverUrlMemo]）是这个组件存在的另一半理由：
/// `_coverUrl` 每次都带 `_dc=<now>` ⇒ 同一张专辑 20 行会拼出 **20 个不同 URL**，
/// 而 [AuthedImageCache] 的键是 `identity|url` ⇒ 一次都不用命中的话，
/// 滑一屏就是 20 次 NAS 往返（每张 ~55 KB）。记忆之后同一会话同一张专辑只算一次。
class SongRowCoverUrlMemo {
  SongRowCoverUrlMemo(this._api);

  final AudioStationApi? _api;

  /// 专辑键 → 封面 URL（**只认第一次拼出来的那条**）
  final Map<String, String> _byAlbum = <String, String>{};

  /// 这张专辑的封面 URL（`null` = 未连接 / 这首歌没有专辑名）。
  String? albumUrlFor(AudioSongDto song) {
    final api = _api;
    if (api == null) return null;
    final album = song.album.trim();
    if (album.isEmpty) return null;
    final key = '${song.albumArtist}\u0000$album';
    final hit = _byAlbum[key];
    if (hit != null) return hit;
    final url = api.albumCoverUrl(album, albumArtist: song.albumArtist);
    _byAlbum[key] = url;
    return url;
  }

  /// 没有专辑名时退回**单曲**封面（`Cover.getsongcover`，真机实测有内嵌图）。
  String? songUrlFor(AudioSongDto song) {
    final api = _api;
    if (api == null || song.id.isEmpty) return null;
    return api.songCoverUrl(song.id);
  }
}

/// 列表行的封面（r638 / `DA230`）：有专辑名走专辑封面（两级回退），
/// 没专辑名走单曲封面，都没有才回落到音符图标。
class SongRowCover extends ConsumerWidget {
  const SongRowCover({
    super.key,
    required this.song,
    this.size = 44,
    this.radius = 8,
  });

  final AudioSongDto song;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = song.support
        ? Icons.music_note_outlined
        : Icons.report_outlined;
    final api = ref.watch(audioApiProvider);
    if (api == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Icon(icon),
      );
    }
    final album = song.album.trim();
    if (album.isEmpty) {
      return AudioCoverImage(
        identity: 'song-row:${song.id}',
        url: ref.read(songRowCoverUrlProvider).songUrlFor(song),
        size: size,
        radius: radius,
        fallbackIcon: icon,
      );
    }
    final identity = 'song-row-album:$album|${song.albumArtist}';
    return AudioCoverImage(
      identity: identity,
      url: ref.read(songRowCoverUrlProvider).albumUrlFor(song),
      size: size,
      radius: radius,
      fallbackIcon: icon,
      resolveFallback: albumCoverFallbackOf(
        ref.watch(albumCoverResolverProvider),
        AudioAlbumDto(name: album, albumArtist: song.albumArtist),
        identity: 'song-row-album:$album|${song.albumArtist}',
      ),
    );
  }
}
