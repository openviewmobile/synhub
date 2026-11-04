// 大图页（P2 · SynologyPhotos）：左右滑、双指缩放、收藏、下载、看信息。
//
// 口径：
//   * 原图用 `FotoApi.thumbnailUrl(size:'xl')` —— 官方 App 也是这条
//     （`SYNO.Foto.Thumbnail/get` 的 `xl` 就是原图尺寸，`Download/download`
//     反而要 `unit_id`、适合"存到本机"）；
//   * 视频优先用**自研内嵌播放器**（`openMediaPlayer`，同一相册/时间轴里的
//     同类型视频组成播放列表）；拿不到流地址 / 通道不可用（证书/隧道/未连接）
//     或解码失败时才回退到既有"用其他应用打开 / 下载"面板；
//   * 收藏是**写操作**：`Browse.Item.set_favorite` 之后 invalidate 三个列表，
//     让服务端数据说话（不做本地乐观更新，免得双端不一致）。
import '../../design/kit/design_kit.dart';
import 'photo_cast.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../../design/design_palette.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/adaptive_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/system_open.dart';

import '../../core/media/fit_to_viewport.dart';
import '../../core/media/zoom_stage.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/foto_api.dart';
import '../../dsm/webapi.dart';
import '../media/media_player_view.dart';
import '../media/media_source.dart';
import '../servers/session_controller.dart';
import 'photo_browse_page.dart' show showAddToAlbumSheet;
import 'image_edit_providers.dart';
import 'photo_ai_edit_sheet.dart';
import 'photo_ai_edit_text.dart';
import 'photo_format_fallback.dart';
import 'photo_format_support.dart';
import 'photo_map_sheet.dart';
import 'photo_map_text.dart';
import 'photo_edit_date_sheet.dart';
import 'photo_live_photo.dart';
import 'photo_media_text.dart';
import 'photo_panorama_view.dart';
import 'photo_p0_text.dart';
import 'photo_p1_text.dart';
import 'photo_playback_settings.dart';
import 'photo_providers.dart';
import 'photo_rating.dart';
import 'photo_slideshow.dart';
import 'photo_wave3_page.dart';
import 'photo_widgets.dart';
import '../../core/net/media_tls_policy.dart';

/// 查看器右下角「收藏」FAB 的占位高度 —— 实况照片的播放开关必须抬到它上面。
///
/// 证据（1200×2400 画布的 widget 用例实测，`test/photo_media_live_test.dart` ⑥）：
///   * FAB（`FloatingActionButtonLocation.endFloat`，56×56 + 16 外边距）
///     占 `LTRB(1128, 2328, 1184, 2384)`；
///   * `LivePhotoStage` 原来的 `bottom: 12` 让 48×48 开关占
///     `LTRB(1140, 2340, 1188, 2388)` —— 中心 `(1164, 2364)` 落在 FAB 矩形内。
/// Scaffold 把 FAB **画在 body 之上**并优先命中手势 ⇒ 开关在真机上同样点不到。
/// 所以把 56（FAB）+ 16（外边距）+ 12（间隙）作为舞台右下控件的底边留白传下去。
const double kPhotoViewerLiveControlsInset = 56 + 16 + 12;

class PhotoViewerPage extends ConsumerStatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.items,
    this.index = 0,
    this.albumId,
    this.albumName,
  });

  final List<FotoItemDto> items;
  final int index;

  /// 从相册里点开时带上：多给「设为封面 / 移出相册」两个动作
  final String? albumId;
  final String? albumName;

  @override
  ConsumerState<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends ConsumerState<PhotoViewerPage> {
  late final PageController _pager;
  late int _index = widget.index;

  /// P65：投送（Chromecast）会话与能力探测结果。
  ///
  /// **探测失败/无 GMS ⇒ 按钮根本不出现**（官方也只在有 Cast 能力时才显示），
  /// 不做一个点了没反应的按钮。
  PhotoCastSession? _cast;
  bool _castReady = false;
  bool _busy = false;

  /// 服务端回过 `105`（没有权限）之后，**只隐藏"旋转"这个入口**
  /// （其余入口、其它照片照常；换一张照片不会重置 —— 权限是账号级的）
  bool _rotateDenied = false;

  /// 当前页是否已放大：放大后把 `PageView` 的横滑关掉，让单指手势去平移图片
  /// （否则"放大想看细节"会被识别成"切下一张"，这是真机上很烦的一种错）
  bool _zoomed = false;

  /// P13：正在"实况播放"的条目 id（null = 没有在放）。
  ///
  /// 用 id 而不是 bool：翻到下一张时播放态**自动失效**（官方 `onTouchUp` 即停，
  /// 且离开条目必须停，否则视频层会盖在别的照片上）。
  String? _livePlayingId;

  // ---------------------------------------------------------------- 幻灯片（P49）
  //
  // 官方 `id/action_slideshow` + `str_slideshow_settings`：纯客户端的自动播放。
  // 只把**照片**放进序列（视频在这一页是"点播放"进内嵌播放器，自动播放会在
  // 幻灯片里插一段不可控的交互），并且**循环播放**到用户按停止为止。
  bool _slideshow = false;
  Timer? _slideshowTimer;

  /// 本次幻灯片的播放下标序列（`widget.items` 的下标）。
  List<int> _slideshowOrder = const [];

  /// 当前在序列里的位置。
  int _slideshowPosition = 0;

  FotoItemDto get _current => widget.items[_index];

  @override
  void initState() {
    super.initState();
    _pager = PageController(initialPage: _index);
    unawaited(_probeCast());
  }

  @override
  void dispose() {
    _slideshowTimer?.cancel();
    _slideshowTimer = null;
    // 离开查看器就断开投送（未投送时 `stop()` 一个字节都不发）
    unawaited(_cast?.stop() ?? Future<void>.value());
    _pager.dispose();
    super.dispose();
  }

  /// P65：探测本机投送能力。桥不可用（无 GMS / 通道未实现）⇒ 按钮不出现。
  Future<void> _probeCast() async {
    final bridge = ref.read(photoCastBridgeProvider);
    final session = PhotoCastSession(bridge);
    final ok = await session.probe();
    if (!mounted) return;
    setState(() {
      _cast = session;
      _castReady = ok;
    });
  }

  /// P65：开始 / 停止投送。
  ///
  /// 开始前先问桥要**可投送设备**：一个都没有 ⇒ 明确提示，**不调 `start`**
  /// （避免发一个没有目标的 `identify`）。
  Future<void> _toggleCast() async {
    final session = _cast;
    if (session == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (session.state == PhotoCastState.projecting) {
      await session.stop();
      if (!mounted) return;
      setState(() {});
      messenger.showSnackBar(
        SnackBar(content: Text(context.t.photoCastStopped)),
      );
      return;
    }
    final bridge = ref.read(photoCastBridgeProvider);
    List<Map<String, dynamic>> devices;
    try {
      final info = await bridge.availability();
      final raw = info['devices'];
      devices = [
        if (raw is List)
          for (final d in raw)
            if (d is Map) Map<String, dynamic>.from(d),
      ];
    } on Object {
      devices = const [];
    }
    if (!mounted) return;
    if (devices.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(context.t.photoCastNoDevices)),
      );
      return;
    }
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        key: const Key('photo-cast-device-picker'),
        title: Text(context.t.photoCastPickDevice),
        children: [
          for (final d in devices)
            SimpleDialogOption(
              key: Key('photo-cast-device-${d['id'] ?? ''}'),
              onPressed: () => Navigator.of(context).pop(d),
              child: Text(
                '${d['name'] ?? d['id'] ?? photoP0(PhotoP0TextKeys.castUnknownDevice, '未知设备')}',
              ),
            ),
          SimpleDialogOption(
            key: const Key('photo-cast-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t.actionCancel),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final ok = await session.start('${picked['id'] ?? ''}');
    if (!mounted) return;
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            session.lastError ?? context.t.photoCastConnectFailed,
          ),
        ),
      );
      return;
    }
    setState(() {});
    // 连上就把当前这张送过去（官方时序：identify → goto_index）
    await session.project(_index);
  }

  /// 开始幻灯片（用当前设置；随机模式每次开一个不同的种子）。
  void _startSlideshow() {
    final photos = <int>[
      for (var i = 0; i < widget.items.length; i++)
        if (!widget.items[i].isVideo) i,
    ];
    if (photos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          key: const Key('photo-slideshow-empty'),
          content: Text(
            photoG1(PhotoG1TextKeys.slideshowNoPhotos, '这个列表里没有可放映的照片'),
          ),
        ),
      );
      return;
    }
    final settings = ref.read(photoSlideshowSettingsProvider);
    _slideshowOrder = slideshowSequence(
      photos,
      order: settings.order,
      seed: DateTime.now().microsecondsSinceEpoch,
    );
    final at = _slideshowOrder.indexOf(_index);
    _slideshowPosition = at < 0 ? 0 : at;
    setState(() => _slideshow = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const Key('photo-slideshow-started'),
        duration: const Duration(seconds: 2),
        content: Text(photoG1(PhotoG1TextKeys.slideshowStarted, '幻灯片播放中')),
      ),
    );
    _scheduleSlideshow();
  }

  void _stopSlideshow() {
    _slideshowTimer?.cancel();
    _slideshowTimer = null;
    if (!_slideshow) return;
    setState(() => _slideshow = false);
  }

  void _scheduleSlideshow() {
    _slideshowTimer?.cancel();
    final settings = ref.read(photoSlideshowSettingsProvider);
    _slideshowTimer = Timer(settings.interval, () {
      if (!mounted) return;
      _advanceSlideshow();
    });
  }

  void _advanceSlideshow() {
    if (_slideshowOrder.isEmpty) {
      _stopSlideshow();
      return;
    }
    var pos = _slideshowPosition + 1;
    if (pos >= _slideshowOrder.length) pos = 0; // 循环
    _slideshowPosition = pos;
    final target = _slideshowOrder[pos];
    if (target != _index && target >= 0 && target < widget.items.length) {
      _pager.animateToPage(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    }
    _scheduleSlideshow();
  }

  /// 幻灯片设置（速度 + 顺序；官方 `str_slideshow_settings`）。
  Future<void> _openSlideshowSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => const _SlideshowSettingsSheet(),
    );
    if (!mounted) return;
    // 设置改了 → 用新间隔/新顺序重排并继续
    if (_slideshow) {
      final settings = ref.read(photoSlideshowSettingsProvider);
      final photos = [
        for (final i in _slideshowOrder)
          if (!widget.items[i].isVideo) i,
      ];
      _slideshowOrder = slideshowSequence(
        photos,
        order: settings.order,
        seed: DateTime.now().microsecondsSinceEpoch,
      );
      _slideshowPosition = 0;
      _scheduleSlideshow();
    }
  }

  Future<void> _toggleFavorite() async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null || _busy) return;
    final item = _current;
    final next = !item.isFavorite;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    try {
      await api.setFavorite([item.id], next);
      // 服务端是唯一事实来源：改完重新拉列表
      ref.invalidate(photoTimelineProvider);
      ref.invalidate(photoFavoritesProvider);
      ref.invalidate(photoAlbumsProvider);
      messenger.showSnackBar(
        SnackBar(content: Text(next ? t.photoFavorited : t.photoUnfavorited)),
      );
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.photoFavoriteFailed(describePhotoError(err, t))),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 旋转照片（`Browse.Item / set` + `rotate_action`，**v7**）。
  ///
  /// 取证原文（jadx `ApiBrowseItem.java`）：`API_ID="Browse.Item"`、
  /// `API_VERSION=7`；L115 `ROTATE_ACTIONS = {"clockwise","180","counter_clockwise"}`；
  /// L1204 `map.put(KEY_ROTATE_ACTION, gson.toJson(str2))`（值要 JSON 引号）；
  /// L482-486 只认 1~3。**官方 App 的照片编辑只有旋转**（没有裁剪/滤镜/参数滑块），
  /// 所以这里也只做旋转，其它一律不做（见实施记录的「无证据」清单）。
  ///
  /// 权限：官方用 `canEdit(hasManagePermission)` 门控。我们没有逐相册的
  /// `hasManagePermission`，所以**先发**，`105` 回来就把这个入口**隐藏**
  /// （能力/降级门控口径：只隐藏该条目 + 给无权限提示，其余功能照常）。
  Future<void> _rotate() async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null || _busy) return;
    final item = _current;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final action = await showModalBottomSheet<FotoRotateAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          key: const Key('photo-rotate-sheet'),
          mainAxisSize: MainAxisSize.min,
          children: [
            DesignRowTile(
              key: const Key('photo-rotate-clockwise'),
              leading: const Icon(Icons.rotate_right),
              title: Text(photoP1(PhotoP1TextKeys.editorRotateCw, '顺时针旋转 90°')),
              onTap: () =>
                  Navigator.of(context).pop(FotoRotateAction.clockwise),
            ),
            DesignRowTile(
              key: const Key('photo-rotate-180'),
              leading: const Icon(Icons.rotate_90_degrees_cw_outlined),
              title: Text(photoP1(PhotoP1TextKeys.editorRotate180, '旋转 180°')),
              onTap: () =>
                  Navigator.of(context).pop(FotoRotateAction.rotate180),
            ),
            DesignRowTile(
              key: const Key('photo-rotate-counter-clockwise'),
              leading: const Icon(Icons.rotate_left),
              title: Text(
                photoP1(PhotoP1TextKeys.editorRotateCcw, '逆时针旋转 90°'),
              ),
              onTap: () =>
                  Navigator.of(context).pop(FotoRotateAction.counterClockwise),
            ),
          ],
        ),
      ),
    );
    if (action == null) return; // 取消 → 一个请求都不发
    setState(() => _busy = true);
    try {
      await api.setItemRotation(itemIds: [item.id], action: action);
      // 服务端是唯一事实来源：缩略图 + 三个列表全部重取
      ref.invalidate(photoThumbProvider);
      ref.invalidate(photoTimelineProvider);
      ref.invalidate(photoAlbumsProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(photoP1(PhotoP1TextKeys.editorSaved, '已保存旋转结果')),
        ),
      );
    } catch (err) {
      final denied = err is DsmApiException && err.code == 105;
      if (denied && mounted) {
        // 105 = 没有权限 → 只隐藏"旋转"这一个入口，并给无权限提示
        setState(() => _rotateDenied = true);
      }
      messenger.showSnackBar(
        SnackBar(content: Text(describePhotoError(err, t))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 加入相册（普通相册才列得出来；没有就现建一个）
  Future<void> _addToAlbum() async {
    await showAddToAlbumSheet(context, ref, itemIds: [_current.id]);
  }

  /// 编辑拍摄日期时间（P36）。
  ///
  /// ⚠️ **写操作**：`Browse.Item/set` + `time`（绝对 epoch 秒）。链路是
  /// [showPhotoEditDateSheet]（收集意图 + **确认弹窗**）→ 用户点了确认框的
  /// "保存" → 才在这里发请求；取消 / 没改动 → **一个请求都不发**。
  ///
  /// 官方口径与逐字证据见 [FotoApi.setItemTime]。
  Future<void> _openEditDate() async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null || _busy) return;
    final item = _current;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final chosen = await showPhotoEditDateSheet(context, item: item);
    if (chosen == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await api.setItemTime(itemIds: [item.id], time: chosen);
      // 服务端是唯一事实来源：时间轴/缩略图/相册全部重取（时间改了会改变排序，
      // 本地乐观更新一定会和真机不一致）。
      ref.invalidate(photoThumbProvider);
      ref.invalidate(photoTimelineProvider);
      ref.invalidate(photoAlbumsProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            photoMedia(PhotoMediaTextKeys.editDateSaved, '已修改拍摄时间。'),
          ),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(
          key: const Key('photo-edit-date-failed'),
          content: Text(
            photoMediaFill(
              PhotoMediaTextKeys.editDateFailed,
              '修改拍摄时间失败：{error}',
              {'error': describePhotoError(err, t)},
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// AI 美化（图生图）。**只加按钮，不动既有链路**：
  /// 入口可见性 = 总开关 + 后端已配置（`photoAiEditEntryVisibleProvider`），
  /// 其余门控（同意 / key / 网络 / 额度 / 并发）在面板内逐条给文案。
  Future<void> _openAiEdit() async {
    final item = _current;
    if (item.isVideo) return;
    await showPhotoAiEditSheet(context, item: item);
  }

  /// 设为这个相册的封面（照片必须已经在相册里，服务端才认）
  Future<void> _setCover() async {
    final albumId = widget.albumId;
    if (albumId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    try {
      await ref.read(photoAlbumActionsProvider).setCover(albumId, _current.id);
      messenger.showSnackBar(SnackBar(content: Text(t.photoCoverSet)));
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.photoCoverFailed(describePhotoError(err, t)))),
      );
    }
  }

  /// 移出相册（照片本身还在照片库里）
  Future<void> _removeFromAlbum() async {
    final albumId = widget.albumId;
    if (albumId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    try {
      await ref.read(photoAlbumActionsProvider).removeItems(albumId, [
        _current.id,
      ]);
      if (mounted) Navigator.of(context).maybePop();
      messenger.showSnackBar(SnackBar(content: Text(t.photoRemovedFromAlbum)));
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.photoRemoveFailed(describePhotoError(err, t))),
        ),
      );
    }
  }

  /// 删除当前项（`Browse.Item/delete` → **DSM 回收站**）。
  ///
  /// 官方口径（`ui/texts/enu/strings` + APK `str_setting_deletion_desc` 原文）：
  /// `delete_photos = "Delete and move to the Recycle Bin?"`；能否还原取决于
  /// **DSM 控制面板 > 共享文件夹 > 启用回收站**。官方 Foto 侧**没有**回收站
  /// 浏览/还原 API（`SYNO.Foto.lib` 零命中），所以这里**不伪造**还原入口，
  /// 只把这句话写进确认框（见 [PhotoP0TextKeys.deleteBody]）。
  Future<void> _delete() async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null || _busy) return;
    final item = _current;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(photoP0(PhotoP0TextKeys.deleteTitle, '删除所选项？')),
        content: Text(
          photoP0(
            PhotoP0TextKeys.deleteBody,
            '删除后会移入 DSM 回收站；能否还原取决于共享文件夹是否已启用回收站。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-viewer-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final failed = await ref.read(photoDeleteActionsProvider).delete([
        item.id,
      ]);
      if (!mounted) return;
      if (failed.isEmpty) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              photoP0Fill(PhotoP0TextKeys.deletedCount, '已删除 {count} 项', {
                'count': '1',
              }),
            ),
          ),
        );
        Navigator.of(context).maybePop();
      } else {
        messenger.showSnackBar(
          SnackBar(content: Text(t.photoDeleteFailed(item.filename))),
        );
      }
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.photoDeleteFailed(describePhotoError(err, t))),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 下载原文件（[forItem] 默认当前页；视频回退面板要针对**它自己**那一项）
  Future<void> _download({
    required bool openAfter,
    FotoItemDto? forItem,
  }) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final item = forItem ?? _current;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    try {
      // 照片/视频都走 Download/download：`item.id` 是 `Browse.Item/list` 的
      // **item id**，官方 `u9` 对 Item 种类发的是 `item_id=[…]`（不是 unit_id）。
      final bytes = await api.api.getBytes(api.downloadUrl(itemId: item.id));
      final dir = await ref.read(photoDownloadDirectoryProvider)();
      final file = File('${dir.path}/${item.filename}');
      await file.writeAsBytes(bytes);
      if (openAfter) await ref.read(systemOpenProvider)(file.path);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            openAfter
                ? t.photoOpenedWith(item.filename)
                : t.photoDownloaded(item.filename),
          ),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.photoDownloadFailed(describePhotoError(err, t))),
        ),
      );
    }
  }

  /// 评分（P40）：`Browse.Item/set` + `rating`，**v2+**。
  ///
  /// 门控：[FotoApi.supportsRating] 为 false（老 Photos）时入口整个不渲染
  /// —— 见 build 里的 `if (ratingSupported)`，以及 `_showInfo` 里的那一行。
  Future<void> _setRating(int rating) async {
    final item = _current;
    await setPhotoRating(
      context,
      ref,
      itemIds: [item.id],
      rating: rating,
    );
  }

  Future<void> _openRating() async {
    final picked = await showPhotoRatingSheet(
      context,
      initial: _current.rating,
    );
    if (picked == null || !mounted) return;
    await _setRating(picked);
  }

  void _showInfo() {
    final item = _current;
    final ratingSupported = ref.read(fotoSpaceApiProvider)?.supportsRating ?? false;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: DesignPalette.of(context).bg,
      builder: (_) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.filename,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: Gap.sm),
              _InfoRow(
                context.t.photoTakenAt,
                photoGroupLabel(item.takenAt, unit: 'day', l10n: context.t),
              ),
              _InfoRow(context.t.photoFileSize, photoBytes(item.filesize)),
              _InfoRow(
                context.t.photoKind,
                item.isVideo ? context.t.photoVideo : context.t.photoKindPhoto,
              ),
              _InfoRow(
                context.t.photoFolder,
                item.folderId.isEmpty ? '—' : item.folderId,
              ),
              _InfoRow(
                context.t.photoSectionFavorites,
                item.isFavorite ? context.t.photoYes : context.t.photoNo,
              ),
              // 评分（P40）：能力位缺失 → 整行不渲染（不是置灰）
              if (ratingSupported) ...[
                const SizedBox(height: Gap.xs),
                Text(
                  context.t.asRating,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                PhotoRatingBar(
                  key: const Key('photo-info-rating'),
                  rating: item.rating,
                  showClear: true,
                  onChanged: _busy
                      ? null
                      : (v) {
                          Navigator.of(context).pop();
                          _setRating(v);
                        },
                ),
              ],
              // wave3：`Browse.Item/get_exif` v1（只读；能力位缺失/无权限 → 整段不渲染）
              PhotoExifSection(itemId: item.id),
            ],
          ),
        ),
      ),
    );
  }

  /// 画质偏好三档的界面名（官方 `array/video_quality` 的 Auto/Quality first/Speed first）
  String _biasLabel(FotoVideoQualityBias b) => switch (b) {
    FotoVideoQualityBias.auto => photoP0(
      PhotoP0TextKeys.videoQualityAuto,
      '自动',
    ),
    FotoVideoQualityBias.quality => photoP0(
      PhotoP0TextKeys.videoQualityFirst,
      '画质优先',
    ),
    FotoVideoQualityBias.speed => photoP0(
      PhotoP0TextKeys.videoSpeedFirst,
      '速度优先',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final api = ref.watch(fotoSpaceApiProvider);
    final item = _current;
    // 当前项是视频 → 订阅它的"通道计划"（原文件 / 转码档）。素材到位后
    // 重建一次，`_videoSource` 就能拿到 Streaming 档位。
    if (item.isVideo) ref.watch(fotoVideoPlanProvider(item.id));
    // S2 能力位降级（设计 §3 矩阵 #7）：缺 `SYNO.Foto.Streaming` 时，
    // 相册本身照常（partial，不隐藏），但**视频项不可播**——给降级提示，
    // 不崩、不空白。`hasApi` 是 fail-open（未确定时不降级）。
    final canStream = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.photo, kFotoStreamingApi);
    // AI 美化的入口可见性 / 并发态（不改既有任何门控）
    final photoAiEditVisible = ref.watch(photoAiEditEntryVisibleProvider);
    final aiEditBusy = ref.watch(imageEditBusyProvider);
    // 评分（P40）门控：官方 `isSupportRating = Browse.Item.maxVersion >= 2`。
    // 能力位缺失（老 Photos）→ **入口整个不渲染**。
    final ratingSupported = api?.supportsRating ?? false;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        // ★ r522（DA164，真机亮色像素）：查看器是**黑底**页面，但
        // `AppTheme.appBarTheme.titleTextStyle` 把标题色钉成了 `onSurface`
        // （亮色 = 深墨蓝）⇒ 真机上标题「Screenshot_2025…」在黑底上几乎看不见，
        // 而返回/删除这些图标是白的（`foregroundColor` 只影响图标）。
        // 标题样式必须**在调用点显式覆盖**，不能指望 foregroundColor。
        titleTextStyle: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: Colors.white),
        // ★ r522（DA164，真机亮色像素）：查看器是**黑底**页面，但
        // `AppTheme.appBarTheme.titleTextStyle` 把标题色钉成了 `onSurface`
        // （亮色 = 深墨蓝）⇒ 真机上标题「Screenshot_2025…」在黑底上几乎看不见，
        // 而返回/删除这些图标是白的（`foregroundColor` 只影响图标）。
        // 标题样式必须**在调用点显式覆盖**，不能指望 foregroundColor。
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              '${photoGroupLabel(item.takenAt, unit: 'day', l10n: context.t)}'
              '${widget.items.length > 1 ? ' · ${_index + 1}/${widget.items.length}' : ''}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white70),
            ),
          ],
        ),
        actions: adaptiveActions([
          // P65：投送（本机没有 Cast 能力 ⇒ 这个按钮不出现）
          if (_castReady)
            IconButton(
              key: const Key('photo-viewer-cast'),
              tooltip: _cast?.state == PhotoCastState.projecting
                  ? photoP0(PhotoP0TextKeys.castStop, '停止投送')
                  : photoP0(PhotoP0TextKeys.castToScreen, '投送到大屏'),
              icon: Icon(
                _cast?.state == PhotoCastState.projecting
                    ? Icons.cast_connected
                    : Icons.cast,
              ),
              onPressed: _toggleCast,
            ),
          if (item.isVideo)
            PopupMenuButton<FotoVideoQualityBias>(
              key: const Key('photo-video-quality'),
              tooltip: photoP0(PhotoP0TextKeys.videoQuality, '画质'),
              initialValue: ref.watch(fotoVideoQualityBiasProvider),
              onSelected: (b) {
                ref.read(fotoVideoQualityBiasProvider.notifier).set(b);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      photoP0Fill(
                        PhotoP0TextKeys.videoQualityApplied,
                        '画质偏好：{name}',
                        {'name': _biasLabel(b)},
                      ),
                    ),
                  ),
                );
              },
              itemBuilder: (_) => [
                for (final b in FotoVideoQualityBias.values)
                  PopupMenuItem(value: b, child: Text(_biasLabel(b))),
              ],
            ),
          IconButton(
            tooltip: context.t.dtoActionDelete,
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy ? null : _delete,
          ),
          // P49 幻灯片：开始/停止 + 设置（官方 `id/action_slideshow` /
          // `str_slideshow_settings`）。纯客户端，不走任何服务端写接口。
          IconButton(
            key: const Key('photo-slideshow'),
            tooltip: _slideshow
                ? photoG1(PhotoG1TextKeys.slideshowStop, '停止幻灯片')
                : photoG1(PhotoG1TextKeys.slideshowStart, '幻灯片播放'),
            icon: Icon(
              _slideshow ? Icons.stop_circle_outlined : Icons.slideshow,
            ),
            onPressed: _slideshow ? _stopSlideshow : _startSlideshow,
          ),
          IconButton(
            tooltip: context.t.photoAddToAlbum,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: _busy ? null : _addToAlbum,
          ),
          // 照片编辑：官方只有旋转（`Browse.Item/set` + `rotate_action`）；
          // 视频没有这一项，`105` 之后也隐藏。
          if (!item.isVideo && !_rotateDenied)
            IconButton(
              key: const Key('photo-rotate'),
              tooltip: photoP1(PhotoP1TextKeys.editorTitle, '旋转照片'),
              icon: const Icon(Icons.rotate_right),
              onPressed: _busy ? null : _rotate,
            ),
          // 编辑日期时间（P36）：官方 `id/btn_edit_date` → `sheet_edit_date`，
          // 只在**照片**上有（视频没有这个入口）。
          // ⚠️ 写操作：`Browse.Item/set` + `time`；发请求前必过确认框。
          if (!item.isVideo)
            IconButton(
              key: const Key('photo-edit-date'),
              tooltip: photoMedia(
                PhotoMediaTextKeys.editDateMenuAction,
                '编辑日期时间',
              ),
              icon: const Icon(Icons.edit_calendar_outlined),
              onPressed: _busy ? null : _openEditDate,
            ),
          // 评分（P40）：`Browse.Item/set` + `rating`（v2+）。
          // 服务端能力位缺失 → 不渲染（不是置灰）。
          if (ratingSupported)
            IconButton(
              key: const Key('photo-rating'),
              tooltip: context.t.asRating,
              icon: Icon(
                item.hasRating ? Icons.star : Icons.star_border,
                color: item.hasRating ? Colors.amber : null,
              ),
              onPressed: _busy ? null : _openRating,
            ),
          // AI 美化（图生图）：总开关 + 后端已配置才出现；并发中禁用
          if (!item.isVideo && photoAiEditVisible)
            IconButton(
              key: const Key('photo-ai-edit'),
              tooltip: aiEditBusy
                  ? photoAiEdit(PhotoAiEditTextKeys.busyTooltip, '正在美化中，请稍候')
                  : photoAiEdit(PhotoAiEditTextKeys.entryTooltip, 'AI 美化（图生图）'),
              icon: const Icon(Icons.auto_fix_high),
              onPressed: (_busy || aiEditBusy) ? null : _openAiEdit,
            ),
          if (widget.albumId != null)
            PopupMenuButton<String>(
              tooltip: context.t.photoAlbumActions,
              onSelected: (v) {
                switch (v) {
                  case 'cover':
                    _setCover();
                  case 'remove':
                    _removeFromAlbum();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'cover',
                  child: Text(context.t.photoSetAsCover),
                ),
                PopupMenuItem(
                  value: 'remove',
                  child: Text(
                    context.t.photoRemoveFromAlbumNamed(
                      widget.albumName ?? context.t.navPhotos,
                    ),
                  ),
                ),
              ],
            ),
          // 「在地图中打开」：**只有服务端给了 `additional.gps`** 才出现
          // （`item.hasGps` 是**键存在性**的结论，不是"数值非零"）。
          // 有坐标 → 精确 marker；经纬度是 WGS-84，服务商换算在 links 层。
          if (item.hasGps)
            IconButton(
              key: const Key('photo-map-open-item'),
              tooltip: photoMap(PhotoMapTextKeys.open, '在地图中打开'),
              icon: const Icon(Icons.map_outlined),
              onPressed: () => showPhotoMapSheet(
                context,
                name: item.filename,
                latitude: item.gps!.latitude,
                longitude: item.gps!.longitude,
              ),
            ),
          IconButton(
            tooltip: context.t.photoInfo,
            icon: const Icon(Icons.info_outline),
            onPressed: _showInfo,
          ),
          IconButton(
            tooltip: context.t.dtoActionDownload,
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _download(openAfter: false),
          ),
          IconButton(
            tooltip: context.t.photoOpenWithOther,
            icon: const Icon(Icons.open_in_new),
            onPressed: () => _download(openAfter: true),
          ),
          // ★★ 第 344 轮（D56）：这一页的标题是**两行**（文件名 + 日期·第几张），
          //   而 `reserve` 默认 112 只够单行标题。真机 375dp 上 13 个动作
          //   （其中 `相册操作` 是复合控件、恒不折叠）把标题挤成**一个字符**
          //   （逐字 `2…`）⇒ 这里显式把标题预算抬到 200dp（≈ 4 个字符的字号
          //   宽度 + 两行余量），像素复核见 `docs/evidence-r343/README.md` §3.7。
          //   800dp 测试窗口下仍然一格都不折（`plain = (800-200)/48 = 12`，
          //   可折叠候选 12 ⇒ 全在行内），既有 key 断言不受影响。
        ], reserve: 200),
      ),
      body: api == null
          ? Center(
              child: Text(
                context.t.photoNotConnected,
                style: const TextStyle(color: Colors.white70),
              ),
            )
          : Stack(
              children: [
                PageView.builder(
                  controller: _pager,
                  physics: _zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemCount: widget.items.length,
                  onPageChanged: (i) {
                    setState(() {
                      _index = i;
                      _zoomed = false;
                      // P13：离开条目必须停播（官方 `onTouchUp` 即停）——
                      // 否则实况视频层会盖在下一张照片上。
                      _livePlayingId = null;
                      if (_slideshow) {
                        // 用户手动滑了 → 幻灯片位置跟着对齐（不跳回旧位置）
                        final at = _slideshowOrder.indexOf(i);
                        if (at >= 0) _slideshowPosition = at;
                      }
                    });
                    // P65：正在投送 ⇒ 跟着翻页（未投送时 `project` 不发）
                    unawaited(_cast?.project(i) ?? Future<void>.value());
                  },
                  itemBuilder: (context, i) {
                    final it = widget.items[i];
                    if (it.isVideo) {
                      final source = _videoSource(it, api);
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          _VideoStage(
                            source: source,
                            // 缺 `SYNO.Foto.Streaming` → 视频项级降级（矩阵 #7）
                            streamingUnavailable: !canStream,
                            onPlay: () => _openVideo(it),
                            onOpenExternal: () => _openVideoViaSystem(it),
                            onDownload: () =>
                                _download(openAfter: false, forItem: it),
                          ),
                          // P14：全景**视频**。官方用 Google VR 原生球面渲染
                          // （`Video360Activity` + `libpano_video_renderer.so`），
                          // 本仓播放器**不做球面** → 如实降级并给明确说明，
                          // **不假装在放球面**（正式说明见报告）。
                          if (it.isPanoramaVideo)
                            const Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: _PanoramaVideoNotice(),
                            ),
                        ],
                      );
                    }
                    // P14：360 全景**静图** → 自研球面重投影浏览
                    // （等距柱状 → 透视，拖动改变视角；零新依赖）。
                    if (it.isPanoramaPhoto) {
                      return _PanoramaPhoto(
                        item: it,
                        space: ref.watch(fotoSpaceProvider),
                        onDownload: () =>
                            _download(openAfter: false, forItem: it),
                        onOpenExternal: () =>
                            _download(openAfter: true, forItem: it),
                      );
                    }
                    // 原图同样走**鉴权字节链路**（`Image.network` 在自签证书的
                    // NAS 上根本不工作，见 `photo_providers.dart` 的说明）
                    final still = _OriginalPhoto(
                      item: it,
                      space: ref.watch(fotoSpaceProvider),
                      onDownload: () =>
                          _download(openAfter: false, forItem: it),
                      onOpenExternal: () =>
                          _download(openAfter: true, forItem: it),
                      onZoomChanged: (z) {
                        if (mounted && z != _zoomed) {
                          setState(() => _zoomed = z);
                        }
                      },
                    );
                    // P13：实况 / 动态照片 → 静图 + 可播的内嵌短视频层。
                    if (it.isLiveOrMotion) {
                      final playback = resolveLivePhotoPlayback(
                        it,
                        items: widget.items,
                      );
                      final playing = _livePlayingId == it.id;
                      return LivePhotoStage(
                        item: it,
                        still: still,
                        playback: playback,
                        videoSource: playing
                            ? _liveVideoSource(it, api, playback)
                            : null,
                        playing: playing,
                        controlsBottomInset: kPhotoViewerLiveControlsInset,
                        onToggle: () => setState(() {
                          _livePlayingId = playing ? null : it.id;
                        }),
                      );
                    }
                    return still;
                  },
                ),
                if (_slideshow)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _SlideshowBar(
                      onStop: _stopSlideshow,
                      onSettings: _openSlideshowSettings,
                    ),
                  ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        tooltip: item.isFavorite
            ? context.t.photoUnfavorite
            : context.t.photoSectionFavorites,
        // ★ r522（DA165，真机亮色像素）：`DA159` 把**全局** FAB 前景色钉成
        // `onPrimary`（白），这里却把底色改成 `surface`（亮色=白）⇒ 白底白星，
        // 真机上就是一块**空白方块**。显式给前景色，别让两处主题互相打。
        backgroundColor: hud.surface,
        foregroundColor: hud.primary,
        onPressed: _toggleFavorite,
        child: Icon(
          item.isFavorite ? Icons.star : Icons.star_border,
          color: item.isFavorite ? Colors.amber : null,
        ),
      ),
    );
  }

  /// 这次连接是不是"证书被固定"（自签证书靠我们的指纹放行）
  ///
  /// Media3（`video_player`）走**系统信任链**，这种证书必然握手失败
  /// （调研 §5.4 第 1 条）→ 直接降级为回退面板，别让播放器去撞墙。
  bool get _certPinned {
    final conn = ref.read(sessionControllerProvider).connection;
    if (conn == null || !conn.certPinned) return false;
    // ★ 第 293 轮修（真机缺陷：File Station 所有音视频都播不了）：
    // `certPinned` 的语义是"这枚证书不是系统 CA 验证过的"，**不等于**"播不了"。
    // r259 起 `session_controller._syncMediaTlsPolicy` 已经把该主机的 TLS 政策
    // 下发给原生播放器（`host|fingerprint`）⇒ Media3 能信任它 ⇒ 照常内置播放。
    // 只有在**政策没下发成功**时才降级为"下载 / 交给别的 App"。
    return !MediaTlsPolicy.isInstalledFor(conn.endpoint.baseUrl);
  }

  /// 这次连接是不是隧道传输（`tcpPort == 0` 时 `authenticatedUrl` 返回空串）
  bool get _tunnelTransport {
    final conn = ref.read(sessionControllerProvider).connection;
    if (conn == null) return false;
    return isTunnelTransport(conn.api.transport.describeKind);
  }

  /// 相册视频 → `SYNO.Foto.Download` 直链（`_sid`+`SynoToken` 在查询串）
  ///
  /// Range **真机已证**（2026-09-22：`Download:download` + `Range: bytes=0-1023`
  /// → `206` + `Content-Range: bytes 0-1023/1876693`，见
  /// docs/live-nas-verification.md §4.3）→ `resolvePhotosSource` 默认
  /// `downloadRangeProven = true`：主源可拖动 / 可定位，页面不用改。
  ///
  /// 回退的 `Streaming` 腿**未取证 / 很可能不可用**（必填 `quality` 枚举未解），
  /// 其 `supportsRange` 恒为 false（见 `kFotoStreamingRangeProven`）。
  MediaSource _videoSource(
    FotoItemDto item,
    FotoApi api, {
    FotoVideoPlaybackPlan? plan,
  }) {
    // `fotoSpaceApiProvider` 已经 `inSpace(当前空间)`，别再套一层
    final team = ref.read(fotoSpaceProvider) == FotoSpace.team;
    // 画质三档选出来的通道（`fotoVideoPlanProvider`）：原文件 → Download 主源；
    // 转码档 → Streaming 主源 + 该档位。取不到素材 / 播放列表批量构造时
    // 一律按"原文件"（避免给列表里每个视频都发一次 `Browse.Item/get`）。
    final resolved =
        plan ??
        ref.read(fotoVideoPlanProvider(item.id)).value ??
        const FotoVideoPlaybackPlan.original();
    // P48 播放设置：自签证书下的两条出路（官方 `str_stream_http` /
    // `str_video_play_cert_invalid_desc`）。
    //   * `useHttp` → 直链已经是 `http://`（由 `FotoApi.mediaUrlOverride` 改写），
    //     TLS 根本不参与，所以"证书被固定"不再成立；
    //   * `ignoreCert` → 走应用内客户端取字节（`DioFactory` 无条件放行自签），
    //     也不该拿"证书不可信"把视频判死。
    // 两者任一开启 → 不再把 [certPinned] 传给媒体层，否则会直接降级成
    // `certificateUntrusted` 面板，用户就永远看不到自己刚打开的那个开关起效。
    final playback = ref.read(photoPlaybackSettingsProvider);
    return resolvePhotosSource(
      displayName: item.filename,
      kind: MediaKind.video,
      // `item.id` 是 **item id**（不是 `thumb.unitId`）：官方前端取流就是
      // `id` + `type="item"`，参数名以前误叫 `unitId`（本批改名）。
      itemId: item.id,
      foto: api,
      team: team,
      size: item.filesize,
      certPinned: _certPinned && !playback.useHttp && !playback.ignoreCert,
      tunnelTransport: _tunnelTransport,
      // `raw`/`original` **永不**出现在这里（`chooseFotoVideoPlayback` 结构保证）
      streamingQuality: resolved.streamingQuality,
      streamingPrimary: !resolved.isOriginal,
    );
  }

  /// 实况 / 动态照片的**短视频层**媒体源（P13）。
  ///
  /// 两条路（判据与逐字证据见 `photo_live_photo.dart` 的文件头）：
  ///   * **动态照片**（服务端给了配对信息）→ `Streaming` 的 `quality=motion_photo`
  ///     档，并且官方明确此时 `type="item"`（`composeVideoPlayInfo:8445-8446`）
  ///     → 这里用 `streamingPrimary: true` 让 Streaming 当主源；
  ///   * **实况照片**（`live_type == "video"` 的配对条目）→ 直接复用既有
  ///     [_videoSource]（那条视频本来就是普通视频，走它自己的通道计划）。
  ///
  /// 返回 `null` = 不可播 → [LivePhotoStage] 会显示"短视频不可用"说明层，
  /// **不会**给出一个点了没反应的播放按钮。
  MediaSource? _liveVideoSource(
    FotoItemDto item,
    FotoApi api,
    LivePhotoPlayback playback,
  ) {
    if (playback.streamingQuality == null && playback.pairedVideoItem == null) {
      return null;
    }
    final team = ref.read(fotoSpaceProvider) == FotoSpace.team;
    if (playback.streamingQuality != null) {
      final playbackSettings = ref.read(photoPlaybackSettingsProvider);
      return resolvePhotosSource(
        displayName: item.filename,
        kind: MediaKind.video,
        itemId: item.id,
        foto: api,
        team: team,
        size: item.filesize,
        certPinned:
            _certPinned &&
            !playbackSettings.useHttp &&
            !playbackSettings.ignoreCert,
        tunnelTransport: _tunnelTransport,
        streamingQuality: playback.streamingQuality,
        streamingPrimary: true,
      );
    }
    return _videoSource(playback.pairedVideoItem!, api);
  }

  /// 同一相册/时间轴里的**同类型视频** = 播放列表（上一个/下一个）
  /// 只收"能播"的（空 URL / 证书固定 / 隧道 的条目放进去只会让原生侧拿到空串），
  /// 所以当前项一定在里面，用 [MediaSource.uri] 定位下标。
  List<MediaSource> _videoPlaylist(FotoApi api) {
    final out = <MediaSource>[];
    for (final it in widget.items) {
      if (!it.isVideo) continue;
      final s = _videoSource(
        it,
        api,
        plan: const FotoVideoPlaybackPlan.original(),
      );
      if (s.playable) out.add(s);
    }
    return out;
  }

  /// 点"播放"：优先**自研内嵌播放器**；来源不可播时按钮根本不会出现
  /// （见 `_VideoStage` 的回退面板），这里再做一次防御。
  Future<void> _openVideo(FotoItemDto item) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    // P48：用户选了"忽略证书错误" → **优先走应用内客户端取字节**（整段下载后
    // 交给系统播放器）。理由是如实的：证书信任掌握在我们自己的 Dio 里，
    // 而 `video_player`/Media3 走系统信任链，自签证书必然握手失败。
    if (ref.read(photoPlaybackSettingsProvider).preferBufferedPlayback) {
      await _openVideoViaSystem(item);
      return;
    }
    final source = _videoSource(item, api);
    if (!source.playable) {
      await _openVideoViaSystem(item);
      return;
    }
    final playlist = _videoPlaylist(api);
    final index = playlist.indexWhere((s) => s.uri == source.uri);
    await openMediaPlayer(
      context,
      source: source,
      playlist: playlist,
      playlistIndex: index < 0 ? 0 : index,
      // 解码失败/编码不支持 → 播放器内的回退面板复用这一对回调
      onOpenExternal: () => _openVideoViaSystem(item),
      onDownload: () => _download(openAfter: false, forItem: item),
    );
  }

  /// 回退路径：整段下载 → 交给系统应用（只在拿不到流地址 / 通道不可用 /
  /// 内嵌解码失败时走）。
  ///
  /// 通道与内嵌播放器**同一优先级**：先 `Download`（官方 `quality="raw"` 的原文件
  /// 端点，item 种类 → `item_id=[…]`），失败才退回 `Streaming & type=item`
  /// （转码档兜底）。见 docs/media-streaming-diagnosis.md §1.2。
  Future<void> _openVideoViaSystem(FotoItemDto item) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    try {
      List<int> bytes;
      try {
        bytes = await api.api.getBytes(api.downloadUrl(itemId: item.id));
      } catch (_) {
        bytes = await api.api.getBytes(api.streamingUrl(itemId: item.id));
      }
      final dir = await ref.read(photoDownloadDirectoryProvider)();
      final file = File('${dir.path}/${item.filename}');
      await file.writeAsBytes(bytes);
      await ref.read(systemOpenProvider)(file.path);
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.photoOpenVideoFailed(describePhotoError(err, t))),
        ),
      );
    }
  }
}

/// 原图（`size=xl`）：字节 → `Image.memory`，可双指缩放。
class _OriginalPhoto extends ConsumerWidget {
  const _OriginalPhoto({
    required this.item,
    required this.space,
    required this.onZoomChanged,
    this.onDownload,
    this.onOpenExternal,
  });

  final FotoItemDto item;
  final FotoSpace space;
  final ValueChanged<bool> onZoomChanged;

  /// 兜底面板上的两条出路（P15/P16）；为空则不显示对应按钮。
  final VoidCallback? onDownload;
  final VoidCallback? onOpenExternal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final req = PhotoThumbRequest(
      itemId: item.id,
      cacheKey: item.thumb.cacheKey,
      space: space,
      size: 'xl',
    );
    final async = ref.watch(photoThumbProvider(req));
    final bytes = async.value;
    if (bytes == null) {
      if (async.hasError) {
        // P15/P16：取不到大图时**必须先分清楚是哪种"取不到"** ——
        // HEIC → 引导 NAS 生成预览；RAW/AVIF → 官方不承诺的兜底文案；
        // 其它 → 原来的"解码失败"。
        return PhotoFormatFallback(
          filename: item.filename,
          onDownload: onDownload,
          onOpenExternal: onOpenExternal,
        );
      }
      return const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white54,
          ),
        ),
      );
    }
    // 双指缩放 + 双击放大到点到的地方；放大状态回给外层去关掉翻页
    //
    // ★★★ r131（macOS 走查 D20）：这里原来是 `Center(child: Image.memory(fit: contain))`。
    //   `Center` 给的是**松约束**，而 `RenderImage` 在松约束下会缩到**图自己的固有尺寸**
    //   ⇒ `BoxFit.contain` 根本没有可缩放的空间：小图就按 1:1 像素画在画布正中。
    //   真机像素证据：`p16_photo_viewer.png` 里那张图只占 **127×127 px（画布的 0.84%）**，
    //   而同一张图在时间线的磁贴（`p10`）里占 **527 px**（磁贴给的是紧约束 ⇒ 正常放大）。
    //   修法：**给图片一个视口大小的盒**（用 `LayoutBuilder` 取包围盒；万一是无界约束
    //   就退到 `MediaQuery` 的屏尺寸），`contain` 这才真的把图放大/缩小到可视区。
    //   断言钉在机制量上（`RawImage` 的布局尺寸 = 视口、`scale = min(box/img)`），
    //   见 `test/photo_viewer_fit_test.dart`（小图必须 scale>1、大图必须 scale<=1）。
    return ZoomStage(
      onZoomChanged: onZoomChanged,
      child: FitToViewport(
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          cacheWidth: req.decodeWidth,
          errorBuilder: (_, __, ___) => PhotoFormatFallback(
            filename: item.filename,
            onDownload: onDownload,
            onOpenExternal: onOpenExternal,
          ),
        ),
      ),
    );
  }
}

/// 视频页：能播 → "播放"进自研内嵌播放器；不可播 → **复用**媒体层的回退面板。
///
/// 回退面板是既有组件（`MediaFallbackPanel`，文案走 `mediaReasonText` +
/// `classifyPlayerError`），不在这里另造一套"用其他应用打开/下载"。
class _VideoStage extends StatelessWidget {  const _VideoStage({
    required this.source,
    required this.onPlay,
    required this.onOpenExternal,
    required this.onDownload,
    this.streamingUnavailable = false,
  });

  final MediaSource source;

  /// 服务端缺 `SYNO.Foto.Streaming`（能力表明确没有）→ 视频项级降级。
  final bool streamingUnavailable;

  final VoidCallback onPlay;
  final VoidCallback onOpenExternal;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    // 矩阵 #7：能力表明确没有 `SYNO.Foto.Streaming` → **不尝试播**，
    // 给一句话降级提示（不崩、不空白）；相册其余部分照常。
    if (streamingUnavailable) {
      return Center(
        key: const Key('photo-video-unavailable'),
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.videocam_off_outlined,
                size: 48,
                color: Colors.white70,
              ),
              const SizedBox(height: Gap.md),
              Text(
                source.displayName,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Gap.sm),
              Text(
                // S2 收口：这里专指"缺 `Foto.Streaming` → 视频播不了"，
                // 用更贴切的 key，而不是通用 partial 文案。
                context.t.photoVideoUnavailable,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    // 空 URL / 证书固定 / 隧道未起 / 未连接 → 说清原因 + 两条出路
    final reason = source.reason;
    if (reason != null) {
      return MediaFallbackPanel(
        source: source,
        reason: reason,
        onOpenExternal: onOpenExternal,
        onDownload: onDownload,
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.play_circle_outline,
            size: 64,
            color: Colors.white70,
          ),
          const SizedBox(height: Gap.md),
          Text(
            source.displayName,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.md),
          // 复用既有 key `fileMediaPlay`（"播放"），不新增 ARB
          //
          // ★ r525（DA168，真机亮色像素）：原来是 `tonalIcon` ⇒
          // `secondaryContainer`（跟壁纸派生出来的淡紫），画在**纯黑**的查看器里
          // 就是一大块浅色板子，和整屏的白色 chrome 不在一个语言里。
          // 这一页是黑底，按钮一律走 `primary`/`onPrimary`。
          FilledButton.icon(
            style: InlineButtonStyle.filled,
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow, size: 16),
            label: Text(context.t.fileMediaPlay),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

/// 幻灯片播放时的底部控制条（P49）：停止 + 设置。
///
/// 单独一个小部件是为了让"播放循环"（`_PhotoViewerPageState`）与"设置入口"
/// 解耦：循环只管定时器，条子只管两个按钮。
class _SlideshowBar extends ConsumerWidget {
  const _SlideshowBar({required this.onStop, required this.onSettings});

  final VoidCallback onStop;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(photoSlideshowSettingsProvider);
    final order = settings.order == PhotoSlideshowOrder.shuffle
        ? photoG1(PhotoG1TextKeys.slideshowShuffle, '随机')
        : photoG1(PhotoG1TextKeys.slideshowSequential, '顺序');
    return Material(
      key: const Key('photo-slideshow-bar'),
      color: Colors.black.withValues(alpha: 0.55),
      child: SafeArea(
        top: false,
        child: Padding(
          // ★★★ r332：**右边必须给 FAB 让路**。`Scaffold` 把右下角那个「收藏」FAB
          // （`FloatingActionButtonLocation.endFloat`）**画在 body 之上并优先命中手势**，
          // 而换了真实产品主题后按钮变宽 ⇒ 「停止幻灯片」被 FAB 压住：
          // 800x600 下实测 停止 `LTRB(668.5,548,788,596)`、FAB `LTRB(728,528,784,584)`
          // ⇒ 停止按钮**中心 (728.3,572) 正好落在 FAB 里**，点"停止"其实会点到收藏。
          // 复用已经量过的常量（56 FAB + 16 外边距 + 12 间隙，见文件顶部注释）。
          padding: const EdgeInsets.fromLTRB(
            Gap.md,
            Gap.xs,
            kPhotoViewerLiveControlsInset,
            Gap.xs,
          ),
          // ★★★ r332：**窄屏上这两个动作必须"只留图标"**。原先用带文字的
          // `TextButton.icon`，真机 375dp 上「Slideshow settings」167dp +「Stop slideshow」144dp
          // 就吃掉 311dp（控制条可用才 343dp）⇒ 左边的间隔文案被 `Expanded` 压到只剩约 10dp，
          // **一个字一行竖着排**（真机像素：`docs/evidence-r332/img/r332_07_android_slideshow_vertical_text.png`）。
          // 改成 40dp 的 `IconButton`（文案进 tooltip/Semantics，可访问性不丢）
          // ⇒ 固定开销 106dp，间隔文案在真机上有 169dp。
          child: Row(
            children: [
              const Icon(Icons.slideshow, color: Colors.white70, size: 18),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  key: const Key('photo-slideshow-interval'),
                  photoG1Fill(
                    PhotoG1TextKeys.slideshowInterval,
                    '每 {seconds} 秒 · {order}',
                    {'seconds': '${settings.seconds}', 'order': order},
                  ),
                  // 极窄/大字号下最多两行，别退化成"一字一列"。
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              IconButton(
                key: const Key('photo-slideshow-settings'),
                onPressed: onSettings,
                tooltip: photoG1(PhotoG1TextKeys.slideshowSettings, '幻灯片设置'),
                icon: const Icon(Icons.tune, size: 18, color: Colors.white70),
              ),
              IconButton(
                key: const Key('photo-slideshow-stop'),
                onPressed: onStop,
                tooltip: photoG1(PhotoG1TextKeys.slideshowStop, '停止幻灯片'),
                icon: const Icon(
                  Icons.stop_circle_outlined,
                  size: 18,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 幻灯片设置面板（官方 `str_slideshow_settings`：速度 + 播放顺序）。
class _SlideshowSettingsSheet extends ConsumerWidget {
  const _SlideshowSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(photoSlideshowSettingsProvider);
    final notifier = ref.read(photoSlideshowSettingsProvider.notifier);
    return SafeArea(
      key: const Key('photo-slideshow-settings-sheet'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              photoG1(PhotoG1TextKeys.slideshowSettings, '幻灯片设置'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Gap.md),
            Text(
              photoG1(PhotoG1TextKeys.slideshowSpeed, '速度'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.sm,
              children: [
                for (final s in kPhotoSlideshowSeconds)
                  ChoiceChip(
                    key: Key('photo-slideshow-speed-$s'),
                    label: Text(
                      photoG1Fill(
                        PhotoG1TextKeys.slideshowSeconds,
                        '{seconds} 秒',
                        {'seconds': '$s'},
                      ),
                    ),
                    selected: settings.seconds == s,
                    onSelected: (_) => notifier.setSeconds(s),
                  ),
              ],
            ),
            const SizedBox(height: Gap.md),
            Text(
              photoG1(PhotoG1TextKeys.slideshowOrder, '播放顺序'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.sm,
              children: [
                ChoiceChip(
                  key: const Key('photo-slideshow-order-sequential'),
                  label: Text(
                    photoG1(PhotoG1TextKeys.slideshowSequential, '顺序'),
                  ),
                  selected: settings.order == PhotoSlideshowOrder.sequential,
                  onSelected: (_) =>
                      notifier.setOrder(PhotoSlideshowOrder.sequential),
                ),
                ChoiceChip(
                  key: const Key('photo-slideshow-order-shuffle'),
                  label: Text(photoG1(PhotoG1TextKeys.slideshowShuffle, '随机')),
                  selected: settings.order == PhotoSlideshowOrder.shuffle,
                  onSelected: (_) =>
                      notifier.setOrder(PhotoSlideshowOrder.shuffle),
                ),
              ],
            ),
            const SizedBox(height: Gap.md),
          ],
        ),
      ),
    );
  }
}

/// 360 全景**静图**页（P14）：走既有的鉴权字节链路取原图，再交给
/// [PanoramaView] 做等距柱状 → 透视的球面重投影。
///
/// 为什么单独一个组件而不是塞进 [_OriginalPhoto]：全景要的是**原始字节**
/// （`ui.Image` 给 `ImageShader` 用），而 [_OriginalPhoto] 交给 `Image.memory`
/// 去解码 + `ZoomStage` 做仿射缩放 —— 两套都不适用于球面重投影。
/// 取图这一段两者**完全一样**（同一个 `photoThumbProvider` + `size: 'xl'`），
/// 所以失败分支也复用既有 [PhotoFormatFallback]。
class _PanoramaPhoto extends ConsumerWidget {
  const _PanoramaPhoto({
    required this.item,
    required this.space,
    this.onDownload,
    this.onOpenExternal,
  });

  final FotoItemDto item;
  final FotoSpace space;
  final VoidCallback? onDownload;
  final VoidCallback? onOpenExternal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final req = PhotoThumbRequest(
      itemId: item.id,
      cacheKey: item.thumb.cacheKey,
      space: space,
      size: 'xl',
    );
    final async = ref.watch(photoThumbProvider(req));
    final bytes = async.value;
    if (bytes == null) {
      if (async.hasError) {
        return PhotoFormatFallback(
          filename: item.filename,
          onDownload: onDownload,
          onOpenExternal: onOpenExternal,
        );
      }
      return const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white54,
          ),
        ),
      );
    }
    return PanoramaView(
      key: Key('photo-pano-${item.id}'),
      bytes: bytes,
    );
  }
}

/// 全景**视频**的降级说明条（P14）。
///
/// 官方 Android 用 Google VR 的 `VrVideoView` + `libpano_video_renderer.so`
/// 做**球面**视频渲染（`Video360Activity.java:444-454` `vrVideoView.loadVideo(...)`）；
/// 本仓的播放器（Media3/`video_player`）**只做平面播放**，硬约束又禁止引入
/// 新依赖 → 所以按平面播放，并**明确写出来**，不让用户以为拖动能转视角。
class _PanoramaVideoNotice extends StatelessWidget {
  const _PanoramaVideoNotice();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        key: const Key('photo-pano-video-notice'),
        width: double.infinity,
        color: Colors.black54,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          photoMedia(
            PhotoMediaTextKeys.panoVideoFlatNotice,
            '这是 360 全景视频。本版播放器暂不支持球面视角（只能按普通平面视频播放）。',
          ),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
  }
}
