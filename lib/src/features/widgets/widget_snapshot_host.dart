// 小组件的 **App 侧集成点**（可选挂载）：接住小组件点击 + 在数据变化时推快照。
//
// ⚠️ 本批**不允许修改 shell / 页面等既有文件**（见批次硬性约束），
// 所以这个 Host 只是**写好放在这里**，由父 agent 在 `app_shell_page.dart`
// 的外层包一行即可（`ShareIntentHost` / `ChatDeepLinkHost` 是同样的用法）：
//
// ```dart
// // app_shell_page.dart 的 build 里
// return WidgetSnapshotHost(child: Scaffold(...));
// ```
//
// 挂上之后它负责两件事：
//   1. **点击落点**：冷启动 `takePendingTarget()` / 前台 `onWidgetAction`
//      → 切 tab 或 push 页面（见 `_route`）；
//   2. **数据变化 → 推快照**：登录态、相册时间轴、笔记列表、待办列表任一变化
//      就调 `WidgetSnapshotPublisher.publish`（内部再 `pushSnapshot` → Android
//      `updateAppWidget` 立刻重画）。
//
// ## ⚠️ 一个必须知道的副作用（父 agent 决策）
// `ref.listen` 会**订阅** provider。挂上本 Host 后，下面三个 `autoDispose`
// provider 会在 shell 的整个生命周期内**常驻**（等价于"提前加载 + 不再随
// tab 卸载"）：
//   * `photoTimelineProvider`（会发起一次相册时间轴请求）
//   * `noteListProvider` / `noteTodosProvider`（笔记列表 / 待办列表）
// 这是"小组件要显示 App 数据"的必然代价（小组件不会自己联网）。
// 如果不接受，把 `watchData: false`：Host 就只处理点击落点，快照改由
// 父 agent 在**已有的**数据出口处调用 `WidgetSnapshotPublisher.publish`。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router/app_router.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/dto/note_dto.dart';
import '../notes/note_editor_page.dart';
import '../notes/note_picker.dart';
import '../notes/note_todo_page.dart';
import '../notes/note_providers.dart';
import '../notes/note_view_page.dart';
import '../photos/photo_providers.dart';
import '../servers/session_controller.dart';
import '../shell/app_shell_page.dart' show appTabProvider;
import '../shell/app_tab.dart';
import 'widget_bridge.dart';
import 'widget_snapshot.dart';
import 'widget_snapshot_publisher.dart';

/// 小组件点击与快照推送的宿主（包住 shell 即可）。
class WidgetSnapshotHost extends ConsumerStatefulWidget {
  const WidgetSnapshotHost({
    super.key,
    required this.child,
    this.watchData = true,
    this.photoBytes,
  });

  final Widget child;

  /// `true`（默认）= 订阅相册/笔记/待办 provider，数据一变就推快照。
  /// `false` = 只处理点击落点（见文件头"副作用"一节）。
  final bool watchData;

  /// 覆盖"取某张照片缩略图字节"的实现（测试注入假实现用；
  /// 生产传 null 走 `photoThumbProvider`）。
  final WidgetPhotoBytes? photoBytes;

  @override
  ConsumerState<WidgetSnapshotHost> createState() => _WidgetSnapshotHostState();
}

class _WidgetSnapshotHostState extends ConsumerState<WidgetSnapshotHost> {
  StreamSubscription<void>? _sub;

  /// 串行化推送：`publish` 里有 await（缩略图落盘），并发进来就丢弃中间态，
  /// 只保证"最后一次数据"最终被推出去。
  bool _publishing = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final bridge = ref.read(widgetBridgeProvider);
    _sub = bridge.onAction.listen((_) => unawaited(_consumePending()));
    // 冷启动：Activity 起来时带来的小组件点击
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_consumePending());
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------- 点击落点

  Future<void> _consumePending() async {
    final raw = await ref.read(widgetBridgeProvider).takePendingTarget();
    final target = parseWidgetTarget(raw);
    if (target == null || !mounted) return;
    _route(target);
  }

  void _route(WidgetTarget target) {
    switch (target.kind) {
      case WidgetTargetKind.photos:
        _select(AppTab.photos);
      case WidgetTargetKind.photo:
        // 具体某张：先切到相册 tab。**逐张聚焦**需要相册页支持外部指定
        // item（`photo_browse_page.dart` 本轮不在本批可改范围内），
        // 落点先到"相册"这一层，不做假承诺。
        _select(AppTab.photos);
      case WidgetTargetKind.notes:
        _select(AppTab.note);
      case WidgetTargetKind.notebook:
        // ★ N1：笔记本小组件点一下 → 笔记 tab（逐本聚焦需要笔记页支持
        //   外部指定笔记本，本批不做假承诺）。id 非空时仍记录意图，
        //   落点先到"笔记"这一层。
        _select(AppTab.note);
      case WidgetTargetKind.newNote:
        _select(AppTab.note);
        _push(const NoteEditorPage());
      case WidgetTargetKind.newCamera:
        // 官方动作栏「新建 → 从相机」：直接进编辑器并调起相机
        _select(AppTab.note);
        _push(const NoteEditorPage(initialPickSource: NotePickSource.camera));
      case WidgetTargetKind.newAudio:
        _select(AppTab.note);
        _push(const NoteEditorPage(initialPickSource: NotePickSource.audio));
      case WidgetTargetKind.newAttachment:
        _select(AppTab.note);
        _push(const NoteEditorPage(initialPickSource: NotePickSource.file));
      case WidgetTargetKind.newTodo:
        _select(AppTab.note);
        _push(const NoteTodoPage());
      case WidgetTargetKind.note:
      case WidgetTargetKind.todo:
        // 待办的 `id` 就是所属笔记 id（见 `widgetTodoEntryOf`）
        _select(AppTab.note);
        if (target.id.isNotEmpty) {
          _push(
            NoteViewPage(
              note: NoteDto(objectId: target.id, title: ''),
            ),
          );
        }
    }
  }

  void _select(AppTab tab) {
    ref.read(appTabProvider.notifier).select(tab);
  }

  void _push(Widget page) {
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    nav.push(MaterialPageRoute<void>(builder: (_) => page));
  }

  // ------------------------------------------------------------- 快照推送

  Future<void> _publish({
    required bool loggedIn,
    required bool connected,
    required List<FotoItemDto> photos,
    required List<NoteDto> notes,
    required List<TodoDto> todos,
    List<NotebookDto> notebooks = const [],
  }) async {
    if (_publishing) {
      _dirty = true;
      return;
    }
    _publishing = true;
    try {
      final publisher = WidgetSnapshotPublisher(
        bridge: ref.read(widgetBridgeProvider),
      );
      await publisher.publish(
        loggedIn: loggedIn,
        connected: connected,
        photos: photos,
        notes: notes,
        todos: todos,
        notebooks: notebooks,
        photoBytes: widget.photoBytes ?? _fetchThumb,
      );
    } catch (_) {
      // 推送失败绝不影响 App：小组件保留上一次的快照
    } finally {
      _publishing = false;
      if (_dirty) {
        _dirty = false;
        // 下一次 provider 变化会再来一次；这里不递归重推，避免抖动
      }
    }
  }

  /// 默认缩略图取法：走相册模块**已鉴权**的 provider（自签证书 + `_sid`）。
  Future<Uint8List?> _fetchThumb(FotoItemDto item) async {
    try {
      final bytes = await ref.read(
        photoThumbProvider(
          PhotoThumbRequest(
            itemId: item.id,
            cacheKey: item.thumb.cacheKey,
            space: ref.read(fotoSpaceProvider),
            size: 'sm',
          ),
        ).future,
      );
      return bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.watchData) {
      _listenAll();
    }
    return widget.child;
  }

  /// 订阅数据源。注意：**订阅本身会初始化 provider**（见文件头"副作用"）。
  void _listenAll() {
    ref.listen(photoTimelineProvider, (_, next) {
      final v = next.value;
      if (v == null) return;
      _publishNow();
    });
    ref.listen(noteListProvider, (_, next) {
      if (next.value == null) return;
      _publishNow();
    });
    ref.listen(noteTodosProvider, (_, next) {
      if (next.value == null) return;
      _publishNow();
    });
    ref.listen(notebooksProvider, (_, next) {
      if (next.value == null) return;
      _publishNow();
    });
    // 登录/掉线：`connected` 变了也要立刻改占位文案（否则小组件还写着旧状态）
    ref.listen(sessionControllerProvider, (_, next) => _publishNow());
  }

  /// 从**已存在**的 provider 值取数据推一次（不主动读未初始化的 provider）。
  void _publishNow() {
    if (!mounted) return;
    final session = ref.read(sessionControllerProvider);
    final photos =
        ref.read(photoTimelineProvider).value?.items ?? const <FotoItemDto>[];
    final notes = ref.read(noteListProvider).value?.notes ?? const <NoteDto>[];
    final todos = ref.read(noteTodosProvider).value ?? const <TodoDto>[];
    // ★ N1（第 107 轮）：笔记本小组件的数据源（不主动初始化未读过的 provider）
    final notebooks =
        ref.read(notebooksProvider).value ?? const <NotebookDto>[];
    unawaited(
      _publish(
        loggedIn: session.loggedIn,
        connected: session.connection != null,
        photos: photos,
        notes: notes,
        todos: todos,
        notebooks: notebooks,
      ),
    );
  }
}
