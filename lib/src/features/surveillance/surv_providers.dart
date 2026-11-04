// Surveillance Station（DS cam）模块的依赖注入、状态与动作（阶段二 A 最后一批）。
//
// 分层与其它模块一致：`DsmWebApi → SurveillanceStationApi（协议）→ providers → 页面`。
// 接口层事实来源：`docs/station-surveillance-mailplus-insight-research.md`。
//
// **只做普通用户功能**：相机增删、许可证、用户权限、System/CMS/Face/IVA 等
// 管理员面不在这里，也不在 UI 里（见 `surveillance_station.dart` 顶部注释）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/surveillance_dto.dart';
import '../../data/surveillance_station.dart';
import '../../dsm/webapi.dart';
import '../servers/session_controller.dart';

/// 监控模块的 API 层。未连接时为 null（页面显示"未连接"而不是崩）。
final surveillanceApiProvider = Provider<SurveillanceStationApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : SurveillanceStationApi(conn.api);
});

/// 摄像机列表状态（加载中 / 失败大类 / 是否加载过）。
class SurvCameraListState {
  const SurvCameraListState({
    this.items = const [],
    this.loading = false,
    this.loaded = false,
    this.failure,
    this.errorText,
    this.apiMissing = false,
  });

  final List<SurvCameraDto> items;
  final bool loading;
  final bool loaded;

  /// 失败大类（套件未安装 / 无权限 / 网络 / 其它）。
  final SurvFailureKind? failure;

  /// 失败的可读文案（`describeSurvError`）。
  final String? errorText;

  /// 还没连接会话（`surveillanceApiProvider == null`）。
  final bool apiMissing;

  SurvCameraListState copyWith({
    List<SurvCameraDto>? items,
    bool? loading,
    bool? loaded,
    SurvFailureKind? failure,
    String? errorText,
    bool? apiMissing,
    bool clearError = false,
  }) => SurvCameraListState(
    items: items ?? this.items,
    loading: loading ?? this.loading,
    loaded: loaded ?? this.loaded,
    failure: clearError ? null : (failure ?? this.failure),
    errorText: clearError ? null : (errorText ?? this.errorText),
    apiMissing: apiMissing ?? this.apiMissing,
  );
}

class SurvCameraListController extends Notifier<SurvCameraListState> {
  @override
  SurvCameraListState build() => const SurvCameraListState();

  SurveillanceStationApi? get _api => ref.read(surveillanceApiProvider);

  /// 拉摄像机列表。[silent] 为 true 时不清空旧数据（下拉刷新）。
  Future<void> load({bool silent = false}) async {
    final api = _api;
    if (api == null) {
      state = state.copyWith(
        loading: false,
        apiMissing: true,
        clearError: true,
      );
      return;
    }
    // 能力表已 discover 且里面没有这个 API → 套件未安装，直接给结论，
    // 不用发一次注定 102 的请求。
    if (!api.installed) {
      state = state.copyWith(
        loading: false,
        loaded: true,
        items: const [],
        failure: SurvFailureKind.notInstalled,
        errorText: describeSurvError(
          DsmApiException(DsmErrorCode.apiNotFound, method: 'Camera.List'),
        ),
      );
      return;
    }
    state = state.copyWith(
      loading: true,
      apiMissing: false,
      items: silent ? null : const [],
      clearError: true,
    );
    try {
      final page = await api.listCameras();
      state = state.copyWith(
        loading: false,
        loaded: true,
        items: page.items,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        loaded: true,
        failure: surveillanceFailureKind(e),
        errorText: describeSurvError(e),
      );
    }
  }

  Future<void> refresh() => load(silent: true);
}

final survCameraListProvider =
    NotifierProvider<SurvCameraListController, SurvCameraListState>(
      SurvCameraListController.new,
    );

/// 单个摄像机详情（`Camera.GetInfo` v8）。
final survCameraProvider = FutureProvider.family<SurvCameraDto?, int>((
  ref,
  id,
) async {
  final api = ref.watch(surveillanceApiProvider);
  if (api == null || !api.installed) return null;
  return api.getCamera(id);
});

/// 单路实时流路径（`Camera.GetStmUrlPath` v8）。
final survStreamPathProvider = FutureProvider.family<SurvStreamPathDto?, int>((
  ref,
  id,
) async {
  final api = ref.watch(surveillanceApiProvider);
  if (api == null || !api.installed) return null;
  return api.getStreamPath(id);
});

/// 单路最近录像（`Recording.List` v5，默认最近 24 小时）。
final survRecordingsProvider = FutureProvider.family<SurvRecordingPage?, int>((
  ref,
  cameraId,
) async {
  final api = ref.watch(surveillanceApiProvider);
  if (api == null || !api.installed) return null;
  final now = DateTime.now();
  final to = now.millisecondsSinceEpoch ~/ 1000;
  final from = to - 24 * 3600;
  return api.listRecordings(cameraIds: [cameraId], fromTime: from, toTime: to);
});

/// 预置位列表（`PTZ.ListPreset` v1）——回包字段未取证，原样返回给页面/探针。
final survPresetsProvider = FutureProvider.family<Map<String, dynamic>, int>((
  ref,
  cameraId,
) async {
  final api = ref.watch(surveillanceApiProvider);
  if (api == null) throw StateError('未连接');
  return api.ptzListPreset(cameraId: cameraId);
});

/// 写操作（PTZ/绝对定位/预置位）—— 页面直接用，失败抛给页面提示。
class SurvActions {
  const SurvActions(this.api);

  final SurveillanceStationApi? api;

  Future<void> move({
    required int cameraId,
    required String moveType,
    String direction = '',
    int? ptSpeed,
    String control = '',
  }) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.ptzMove(
      cameraId: cameraId,
      moveType: moveType,
      direction: direction,
      ptSpeed: ptSpeed,
      control: control,
    );
  }

  Future<void> home(int cameraId) =>
      move(cameraId: cameraId, moveType: 'Start', direction: 'Home');

  Future<void> stop(int cameraId) => move(cameraId: cameraId, moveType: 'Stop');

  Future<void> goPreset(int cameraId, int position) async {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a.ptzGoPreset(cameraId: cameraId, position: position);
  }

  Future<void> zoom(int cameraId, {required bool inwards}) => move(
    cameraId: cameraId,
    moveType: 'Start',
    control: inwards ? 'in' : 'out',
  );
}

final survActionsProvider = Provider<SurvActions>(
  (ref) => SurvActions(ref.watch(surveillanceApiProvider)),
);
