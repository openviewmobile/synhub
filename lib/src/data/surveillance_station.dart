// Surveillance Station（DS cam）业务 API（**只做普通用户功能**）—— 在
// [DsmWebApi] 之上把 `SYNO.SurveillanceStation.*` 收敛成强类型方法。
//
// ★ 权威事实来源：`docs/station-surveillance-mailplus-insight-research.md`
//   （本项目对 SurveillanceStation-x86_64-9.3.0-12139.spk 的离线取证）。
//   本文件里的 **api 名 / method / 版本 / 参数名** 逐字对齐该文档
//   §2.3–§2.4 与包内官方 Web 前端（`ui/modules/**`）。回包字段见
//   `dto/surveillance_dto.dart` 顶部注释。**不要凭记忆改。**
//
// 已实现（普通用户）：
//   * `Camera.List` v8 · `Camera.GetInfo` v8 · `Camera.GetStmUrlPath` v8
//   * `Camera.GetSnapshot` **v1**（`cameraId`+`timestamp`+`preview`）与
//     **v9**（`id`+`profileType`）—— 两代参数名不同，见 research §2.4(e)
//   * `Stream.VideoStreaming.Stream` v1（MJPEG/MXPEG URL 模板）
//   * `PTZ.Move` v6 · `PTZ.AbsPtz` v5 · `PTZ.GoPreset` v4 · `PTZ.ListPreset` v1
//   * `Recording.List` **v5**（root `events`）
//
// 明确**不做**（参数或回包**未取证**，代码里不留半成品；理由见 research §2.5）：
//   * `Camera.StartLive` / `Camera.GetLiveViewPath` v9 / `Camera.Save|Delete`
//     （增删改相机是管理员职能；前两者包内 UI 无调用点、参数未核实）
//   * `Recording.Download` v4 / `Recording.Stream` / `BrowserStream` /
//     `Recording.RangeExport` v6（导出/回放流参数未核实）
//   * `RecordingPicker.EnumInterval` / `InstantSearch`（**请求参数已取证**，
//     但**回包字段未取证**，宁可先不做也不乱解）
//   * `SnapShot.*` / `Event.*` / `Notification.*` / `HomeMode.*`
//   * `License.*` / `UserPrivilege.*` / `System.*` / `CMS.*` / `Face.*` /
//     `IVA.*` / `Switch.*` / `ThirdParty.*` —— 管理员面，不做
//
// ⚠️ 数据层：**不许** import flutter / package:flutter（要能被 `dart run tool/*.dart`
// 加载）；文案走 `dataText(key, 中文原文)`（见 docs/app-identity-and-i18n.md §4.6）。
library;

import '../core/i18n/data_text.dart';
import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/surveillance_dto.dart';

/// `SYNO.SurveillanceStation.*` 的高层封装。**不持有传输** —— 传输由 [DsmWebApi] 管。
class SurveillanceStationApi {
  SurveillanceStationApi(DsmWebApi api)
    : api = api.withModule(TrafficModules.surveillance);

  final DsmWebApi api;

  // ------------------------------------------------------------ 常量（逐字）
  static const String apiCamera = 'SYNO.SurveillanceStation.Camera';
  static const String apiPtz = 'SYNO.SurveillanceStation.PTZ';
  static const String apiRecording = 'SYNO.SurveillanceStation.Recording';
  static const String apiStream =
      'SYNO.SurveillanceStation.Stream.VideoStreaming';

  /// 本机 DS 的 id（官方前端常量 `LOCAL_DS_ID = 0`）。
  static const int localDsId = 0;

  /// `Recording.List` v5 的 `evtSrcType` 取值（官方 `EVENT_SRC_LOCAL`）。
  static const String evtSrcLocal = 'local';

  /// `evtSrcType` 的远端（slave DS）取值（官方 `EVENT_SRC_SLAVEDS`）。
  static const String evtSrcSlaveDs = 'slaveDs';

  /// `GetInfo` 的 `privCamType` 位：实时取景（官方 `SYNO.SS.CamPriv.LIVEVIEW`）。
  static const int privLiveview = 1;

  /// `GetInfo` 的 `privCamType` 位：回放（官方 `SYNO.SS.CamPriv.PLAYBACK`）。
  static const int privPlayback = 2;

  // 版本**固定在官方客户端实际发出的那一版**（包内 `BaseWebAPIConfig.data`
  // 的 registry 逐字取证），不是"越高越好"：SS 的各方法版本之间有语义差异，
  // 官方前端就是钉死的。服务器只支持更低版本时才退让（`negotiate` 的兜底）。
  static const List<int> _cameraVersions = [8];
  static const List<int> _infoVersions = [8];
  static const List<int> _stmVersions = [8];
  static const List<int> _ptzMoveVersions = [6];
  static const List<int> _ptzAbsVersions = [5];
  static const List<int> _ptzPresetVersions = [4];
  static const List<int> _ptzListPresetVersions = [1];
  static const List<int> _recordingVersions = [5];
  static const List<int> _streamVersions = [1];

  // ------------------------------------------------------------ 能力 / 版本

  /// 候选版本里挑一个服务器真正支持的（与 `DownloadStationApi.negotiate` 同规则）。
  int negotiate(String apiName, List<int> candidates) {
    final entry = api.apiTable?[apiName];
    if (entry == null || candidates.isEmpty) {
      return candidates.isEmpty ? 1 : candidates.first;
    }
    final within = candidates.where(
      (c) => c >= entry.minVersion && c <= entry.maxVersion,
    );
    if (within.isNotEmpty) return within.reduce((a, b) => a > b ? a : b);
    return entry.maxVersion < candidates.last
        ? entry.maxVersion
        : entry.minVersion;
  }

  /// 服务器是否声明了某 API（`SYNO.API.Info` 实测表）。
  ///
  /// 表为空（未 discover）时按"未知"处理，返回 true —— 交给调用时的错误兜底。
  bool hasApi(String apiName) {
    final table = api.apiTable;
    if (table == null) return true;
    return table.containsKey(apiName);
  }

  /// **套件未安装**的强判据：能力表里没有 `SYNO.SurveillanceStation.Camera`。
  ///
  /// 与"有 API 但没权限（105/160）"和"网络不通"区分开，界面才能给对的空态
  /// （任务书硬要求：不要一律"加载失败"）。
  bool get installed => hasApi(apiCamera);

  /// 服务器是否支持某 API 的某版本（`minVersion <= v <= maxVersion`）。
  bool supports(String apiName, int version) {
    final entry = api.apiTable?[apiName];
    if (entry == null) return false;
    return version >= entry.minVersion && version <= entry.maxVersion;
  }

  // ------------------------------------------------------------ 摄像机列表

  /// `Camera / List`（v8）—— 摄像机列表。
  ///
  /// 参数逐字对齐 research §2.4(a)（来源 `ui/modules/CameraPreview/CameraPreview.js`）：
  /// ```
  /// { ownerDsId, blIncludeRecCnt:false, blIncludeAuInfo:false,
  ///   blIncludeDeletedCam:true, blCameraIdChecked:true, basic:true, ptz:true,
  ///   fisheye:true, deviceOutCap:true, streamInfo:true, blGetMulticastInfo:true,
  ///   camIdList:<camId>, additional:"video", userId:<DSM userId> }
  /// ```
  /// 回包 root 是 **`cameras`**（`ui/sds.js` 的 `dsCamera` store `root:"cameras"`）。
  ///
  /// [camIds] 非空时只查这几路（官方 `camIdList`）；[ownerDsId] 官方取当前 DS，
  /// 本机固定 0；[userId] 只对跨 DS（CMS）场景有意义。
  Future<SurvCameraPageResult> listCameras({
    List<int>? camIds,
    int ownerDsId = localDsId,
    String userId = '',
    bool includeDeleted = true,
  }) async {
    final data = await api.call(
      apiCamera,
      'List',
      preferredVersion: negotiate(apiCamera, _cameraVersions),
      params: {
        'ownerDsId': ownerDsId,
        'blIncludeRecCnt': false,
        'blIncludeAuInfo': false,
        'blIncludeDeletedCam': includeDeleted,
        'blCameraIdChecked': true,
        'basic': true,
        'ptz': true,
        'fisheye': true,
        'deviceOutCap': true,
        'streamInfo': true,
        'blGetMulticastInfo': true,
        if (camIds != null && camIds.isNotEmpty) 'camIdList': camIds.join(','),
        'additional': 'video',
        if (userId.isNotEmpty) 'userId': userId,
      },
    );
    final raw = data['cameras'];
    final items = <SurvCameraDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) SurvCameraDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return SurvCameraPageResult(
      items: items,
      total: _intOf(data['total'], items.length),
    );
  }

  /// `Camera / GetInfo`（v8）—— 单个/多个摄像机详情。
  ///
  /// 参数逐字对齐 research §2.4(b)（来源 `ui/modules/Camera/CameraPublic.js`）：
  /// `{cameraIds, privCamType, blIncludeDeletedCam, basic, streamInfo, optimize,
  ///   intercom, eventDetection, camAppInfo, blGetMulticastInfo, fisheye}`。
  /// 回包 root 同样是 **`cameras`**。
  Future<List<SurvCameraDto>> getCameraInfo(
    List<int> cameraIds, {
    int privCamType = privLiveview | privPlayback,
  }) async {
    if (cameraIds.isEmpty) return const [];
    final data = await api.call(
      apiCamera,
      'GetInfo',
      preferredVersion: negotiate(apiCamera, _infoVersions),
      params: {
        'cameraIds': cameraIds.join(','),
        'privCamType': privCamType,
        'blIncludeDeletedCam': true,
        'basic': true,
        'streamInfo': true,
        'optimize': true,
        'intercom': true,
        'eventDetection': true,
        'camAppInfo': true,
        'blGetMulticastInfo': true,
        'fisheye': true,
      },
    );
    final raw = data['cameras'] ?? data['camera'];
    return <SurvCameraDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) SurvCameraDto.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  /// 单个摄像机详情（找不到就是 null）。
  Future<SurvCameraDto?> getCamera(int cameraId) async {
    final list = await getCameraInfo([cameraId]);
    return list.isEmpty ? null : list.first;
  }

  // ------------------------------------------------------------ 实时流 URL

  /// `Camera / GetStmUrlPath`（v8）—— 实时流的路径集合。
  ///
  /// 参数逐字对齐 research §2.4(c)（来源 `ui/modules/Camera/Camera.js`）：
  /// `{cameraIds:<camId>}`；回包 `pathInfos[]`（字段见 [SurvStreamPathDto]）。
  Future<SurvStreamPathDto?> getStreamPath(int cameraId) async {
    final data = await api.call(
      apiCamera,
      'GetStmUrlPath',
      preferredVersion: negotiate(apiCamera, _stmVersions),
      params: {'cameraIds': '$cameraId'},
    );
    final raw = data['pathInfos'];
    if (raw is! List || raw.isEmpty) return null;
    final first = raw.first;
    if (first is! Map) return null;
    return SurvStreamPathDto.fromJson(Map<String, dynamic>.from(first));
  }

  /// **MJPEG 实时流 URL** —— 逐字对齐 research §2.4(d)（来源
  /// `webapi/Camera/src/SYNO.SurveillanceStation.Camera.so` 内嵌模板）：
  /// ```
  /// http://<host>:<port>/webapi/entry.cgi
  ///   ?api=SYNO.SurveillanceStation.Stream.VideoStreaming&version=1&method=Stream
  ///   &format=mjpeg&cameraId=<id>&StmKey="<stmKey>"
  /// ```
  ///
  /// ⚠️ `.so` 里的 `StmKey` 值**带一对双引号**（是给内部 ffmpeg 命令行用的
  /// 模板）；这里给的是**不带引号**的 HTTP 查询参数形态，真机需复核（写进
  /// research 的开放项）。URL 由 [DsmWebApi.authenticatedUrl] 拼，带 `_sid`。
  String mjpegUrl({
    required int cameraId,
    String stmKey = '',
    String format = 'mjpeg',
  }) => api.authenticatedUrl(api.apiPath(apiStream), {
    'api': apiStream,
    'version': '${negotiate(apiStream, _streamVersions)}',
    'method': 'Stream',
    'format': format,
    'cameraId': '$cameraId',
    if (stmKey.isNotEmpty) 'StmKey': stmKey,
  });

  /// **RTSP 实时流 URL**（由 `Sms=<camId>.unicast` 模板拼）。
  ///
  /// 模板逐字取自 `.so`（research §2.4(d)）：
  /// `rtsp://<host>:<port>/webman/3rdparty/SurveillanceStation/cgi/rtsp.cgi?Sms=<id>.unicast&DsId=<dsId>&StmKey=<stmKey>`
  ///
  /// [dsId] 默认本机 0；[stmKey] 为空时省略（此时通常要求走 `SYNO.API.Auth`
  /// 拿到的会话 cookie）。播放由系统外部播放器承担，本客户端不内置 RTSP 栈。
  String rtspUrl({
    required int cameraId,
    int dsId = localDsId,
    String stmKey = '',
  }) {
    final hostPort = _hostPort();
    final qp = <String, String>{
      'Sms': '$cameraId.unicast',
      'DsId': '$dsId',
      if (stmKey.isNotEmpty) 'StmKey': stmKey,
    };
    return 'rtsp://$hostPort/webman/3rdparty/SurveillanceStation/cgi/rtsp.cgi?'
        '${qp.entries.map((e) => '${e.key}=${e.value}').join('&')}';
  }

  /// **快照 URL**（v1 形态）。
  ///
  /// 参数逐字对齐 research §2.4(e)：`cameraId` + `timestamp` + `preview`。
  /// [stmKey] 可选；不给就走会话鉴权。
  String snapshotUrl({
    required int cameraId,
    int? timestamp,
    bool preview = true,
    String stmKey = '',
  }) => api.authenticatedUrl(api.apiPath(apiCamera), {
    'api': apiCamera,
    'version': '1',
    'method': 'GetSnapshot',
    'cameraId': '$cameraId',
    'timestamp': '${timestamp ?? 1}',
    'preview': '$preview',
    if (stmKey.isNotEmpty) 'StmKey': stmKey,
  });

  /// **快照 URL**（v9 形态）—— ⚠️ v9 用 `id` 而不是 `cameraId`（research §2.4(e)）。
  String snapshotUrlV9({required int id, int profileType = 0}) =>
      api.authenticatedUrl(api.apiPath(apiCamera), {
        'api': apiCamera,
        'version': '9',
        'method': 'GetSnapshot',
        'id': '$id',
        'profileType': '$profileType',
      });

  // ------------------------------------------------------------ PTZ

  /// `PTZ / Move`（v6）—— 连续/步进/停止。
  ///
  /// 参数逐字对齐 research §2.4(f)（来源 `ui/modules/WebPlayer/PtzControl.js`
  /// 的 `OnPtz`）：
  /// `{cameraId, moveType:"Start"|"Stop"|"Step", direction, ptSpeed,
  ///   profileType, control}`；`control`（`in`/`out`）只有 Zoom/Focus/Iris 用。
  Future<void> ptzMove({
    required int cameraId,
    required String moveType,
    String direction = '',
    int? ptSpeed,
    int? profileType,
    String control = '',
  }) async {
    await api.call(
      apiPtz,
      'Move',
      preferredVersion: negotiate(apiPtz, _ptzMoveVersions),
      params: {
        'cameraId': cameraId,
        'moveType': moveType,
        if (direction.isNotEmpty) 'direction': direction,
        if (ptSpeed != null) 'ptSpeed': ptSpeed,
        if (profileType != null) 'profileType': profileType,
        if (control.isNotEmpty) 'control': control,
      },
    );
  }

  /// `PTZ / AbsPtz`（v5）—— 绝对坐标（来源同上：`{cameraId, posX, posY}`）。
  Future<void> ptzAbsolute({
    required int cameraId,
    required int posX,
    required int posY,
  }) async {
    await api.call(
      apiPtz,
      'AbsPtz',
      preferredVersion: negotiate(apiPtz, _ptzAbsVersions),
      params: {'cameraId': cameraId, 'posX': posX, 'posY': posY},
    );
  }

  /// `PTZ / GoPreset`（v4）—— 调预置位。
  ///
  /// 参数逐字对齐 `ui/modules/WebPlayer/PatrolControl.js`：
  /// `{cameraId, position, speed, type, isPreview:1}`。
  Future<void> ptzGoPreset({
    required int cameraId,
    required int position,
    int speed = 0,
    int type = 0,
    int isPreview = 1,
  }) async {
    await api.call(
      apiPtz,
      'GoPreset',
      preferredVersion: negotiate(apiPtz, _ptzPresetVersions),
      params: {
        'cameraId': cameraId,
        'position': position,
        'speed': speed,
        'type': type,
        'isPreview': isPreview,
      },
    );
  }

  /// `PTZ / ListPreset`（v1）—— 预置位列表。
  ///
  /// 参数**本轮新增取证**（research §2.4(f) 未列）：`ui/modules/Camera/Camera.js`
  /// 字面量 `method:"ListPreset",params:{cameraId:this.camData.id,doSync:true}`。
  ///
  /// ⚠️ **回包字段未取证**（官方前端直接把它喂给下拉框）→ 这里只发请求，
  /// 回包原样返回给调用方/探针，不做 DTO（宁可少解析也不乱解析）。
  Future<Map<String, dynamic>> ptzListPreset({
    required int cameraId,
    bool doSync = true,
  }) => api.call(
    apiPtz,
    'ListPreset',
    preferredVersion: negotiate(apiPtz, _ptzListPresetVersions),
    params: {'cameraId': cameraId, 'doSync': doSync},
  );

  // ------------------------------------------------------------ 录像

  /// `Recording / List`（**v5**）—— 录像/事件检索。
  ///
  /// 参数逐字对齐 research §2.4(i) + `ui/modules/Log/log.js` 的 store 声明：
  /// ```
  /// baseParams: {cameraIds, fromTime, toTime, evtSrcType, evtSrcId,
  ///              timezoneOffset}
  /// + {dsId, limit, start}
  /// ```
  /// 回包 root 是 **`events`**、total 是 **`total`**（不是 items/total！）。
  ///
  /// [evtSrcType] 取 [evtSrcLocal] / [evtSrcSlaveDs]；本机用 local。
  Future<SurvRecordingPage> listRecordings({
    List<int> cameraIds = const [],
    required int fromTime,
    required int toTime,
    String evtSrcType = evtSrcLocal,
    int evtSrcId = localDsId,
    int dsId = localDsId,
    int start = 0,
    int limit = 50,
    int? timezoneOffset,
  }) async {
    final data = await api.call(
      apiRecording,
      'List',
      preferredVersion: negotiate(apiRecording, _recordingVersions),
      params: {
        'cameraIds': cameraIds.join(','),
        'fromTime': fromTime,
        'toTime': toTime,
        'evtSrcType': evtSrcType,
        'evtSrcId': evtSrcId,
        'timezoneOffset': timezoneOffset ?? 0,
        'dsId': dsId,
        'start': start,
        'limit': limit,
      },
    );
    final raw = data['events'];
    final items = <SurvRecordingDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) SurvRecordingDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return SurvRecordingPage(
      items: items,
      total: _intOf(data['total'], items.length),
    );
  }

  // ------------------------------------------------------------ 内部

  /// `<host>:<port>`（从 [DsmWebApi.baseUrl] 里抠；端口缺省按 scheme 补）。
  String _hostPort() {
    final uri = Uri.parse(api.baseUrl);
    final host = uri.host;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    return '$host:$port';
  }
}

// ---------------------------------------------------------------- 错误分类

/// 失败的**大类**：界面据此给出不同的空态/图标/标题。
///
/// 任务书硬要求："区分套件未安装 / 无权限 / 网络失败，不要一律加载失败"。
enum SurvFailureKind {
  /// 这台 NAS 没装（或没启用）Surveillance Station（能力表里没有该 API）。
  notInstalled,

  /// 装了，但这账号没有权限（`105` / `160` / SS 的 `471 NOT_ADMIN_USER`、
  /// `472 SVS_PERM_DENIED`）。
  noPrivilege,

  /// 会话过期，需要重新登录。
  sessionExpired,

  /// 连不上（断网/隧道未起/证书问题）。
  network,

  /// 其它（业务错误、参数错误……）。
  other,
}

/// 把异常归到 [SurvFailureKind]（判据与 [describeSurvError] 一致）。
SurvFailureKind surveillanceFailureKind(Object error) {
  if (error is DsmTransportException) return SurvFailureKind.network;
  if (error is! DsmApiException) return SurvFailureKind.other;
  switch (error.code) {
    case DsmErrorCode.apiNotFound:
    case DsmErrorCode.methodNotFound:
    case DsmErrorCode.notSupportedVersion:
    case DsmErrorCode.noMatchLibEntry:
      return SurvFailureKind.notInstalled;
    case DsmErrorCode.noPermission:
    case DsmErrorCode.noAppPrivilege:
    case 471: // SS_WEBAPI_ERR_NOT_ADMIN_USER
    case 472: // SS_WEBAPI_ERR_SVS_PERM_DENIED
      return SurvFailureKind.noPrivilege;
    case DsmErrorCode.sessionTimeout:
    case DsmErrorCode.sidNotFound:
    case 537: // SS_WEBAPI_ERR_LOGIN_USER_EXPIRED
      return SurvFailureKind.sessionExpired;
    case 405: // SS_WEBAPI_ERR_CONN_REFUSED
    case 406: // SS_WEBAPI_ERR_RELATED_SERVER_CONN_FAILED
      return SurvFailureKind.network;
    default:
      return SurvFailureKind.other;
  }
}

/// Surveillance Station 错误 → 可读文案。
///
/// 错误码表**逐字**取自包内官方前端 `ui/sds.js` 的
/// `SS_WEBAPI_ERR_*` 常量（177 条里的普通用户相关子集 + 通用 WebAPI 码）。
///
/// 数据层只认 key + 中文原文；英文由 Flutter 层注入（§4.6）。
String describeSurvError(Object error) {
  if (error is DsmTransportException) {
    return dataText('survErrNetwork', '网络连接失败，请检查网络后重试');
  }
  if (error is! DsmApiException) return '$error';
  switch (error.code) {
    // 通用 WebAPI 码
    case DsmErrorCode.apiNotFound: // 102
    case DsmErrorCode.methodNotFound: // 103
    case DsmErrorCode.notSupportedVersion: // 104
    case DsmErrorCode.noMatchLibEntry: // 121
      return dataText(
        'survErrNotInstalled',
        '这台 NAS 没有安装 Surveillance Station',
      );
    case DsmErrorCode.noPermission: // 105
    case DsmErrorCode.noAppPrivilege: // 160
    case 471: // NOT_ADMIN_USER
    case 472: // SVS_PERM_DENIED
      return dataText(
        'survErrNoPrivilege',
        '这个账号没有使用 Surveillance Station 的权限',
      );
    case DsmErrorCode.sessionTimeout: // 106
    case 537: // LOGIN_USER_EXPIRED
      return dataText('errLoginExpired', '登录已过期，请重新登录');
    case DsmErrorCode.sidNotFound: // 119
      return dataText('errSidNotFound', '登录状态无效，请重新登录');
    // SS 业务码（SS_WEBAPI_ERR_*，见 ui/sds.js）
    case 400: // EXECUTE_FAILED
      return dataText('survErrExecuteFailed', '操作执行失败');
    case 401: // PARAM_INVALID
      return dataText('survErrParamInvalid', '请求参数不被接受');
    case 402: // CAM_DISABLED
      return dataText('survErrCamDisabled', '这台摄像机已被停用');
    case 403: // INSUFFICIENT_LICENSE
      return dataText('survErrLicense', '摄像机许可不足，请联系管理员');
    case 404: // CODEC_ACTIVATION_FAILED
      return dataText(
        'survErrCodec',
        '缺少播放所需的多媒体解码器（需 Advanced Media Extensions）',
      );
    case 405: // CONN_REFUSED
    case 406: // RELATED_SERVER_CONN_FAILED
    case 416: // MSG_CONNECT_HOST_FAILED
    case 535: // SEND_REQUEST_FAIL
      return dataText('survErrNetwork', '网络连接失败，请检查网络后重试');
    case 407: // CMS_CLOSED_RELOAD
      return dataText('survErrCmsClosed', '录像服务器已关闭，请重新加载');
    case 410: // SERVICE_DISABLED
      return dataText('survErrServiceDisabled', 'Surveillance Station 服务当前不可用');
    case 418: // OBJECT_NOT_EXIST
      return dataText('survErrObjectNotExist', '对象不存在（可能已被删除）');
    case 419: // NAME_REPETITION
    case 420: // CAMERA_NAME_REPETITION
      return dataText('survErrNameRepeated', '名称重复');
    case 533: // CLIENT_BLOCKED
      return dataText('survErrClientBlocked', '该客户端已被管理员锁定');
    case 591: // RECORDING_ENCRYPTED
      return dataText('survErrRecordingEncrypted', '这段录像已加密，无法直接播放');
    default:
      return dataText(
        'survErrUnknown',
        '未知错误（{code}）',
      ).replaceAll('{code}', '${error.code}');
  }
}

int _intOf(Object? v, int fallback) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}
