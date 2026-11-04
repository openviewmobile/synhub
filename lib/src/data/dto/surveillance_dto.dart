// Surveillance Station（DS cam）DTO —— `SYNO.SurveillanceStation.*` 的返回形状。
//
// ★ 事实来源（全部可在解包目录 `/tmp/spk/ex_SS` 里 grep 到原文）：
//   * `ui/sds.js` 的 `fieldCamera=[…]`（**官方前端 JsonStore 的字段表**，
//     是 Camera.List 回包字段的权威来源）与 `SYNO.SS.CamSts.*` 状态常量表；
//   * `ui/modules/Camera/Camera.js`：`GetStmUrlPath` 回包读
//     `b.pathInfos[0]`，字段 `unicastPath` / `unicastOverHttpPath` /
//     `mjpegHttpPath` / `mxpegHttpPath`；
//   * `ui/modules/Log/log.js`：`Recording.List` v5 的 store 声明
//     `root:"events"`、`totalProperty:"total"`、`idProperty:"recordId"`，
//     字段表 `SYNO.SS.App.Event.Def.storeEvtListFields`
//     （`ui/modules/Event/EventCommon.js`）。
//
// ⚠️ 本文件属**数据层**：不许 import flutter / package:flutter —— 它要能被
// `dart run tool/*.dart`（纯 Dart VM）加载（见 docs/app-identity-and-i18n.md §4.6）。
// 状态/错误的**文案**由界面层给（`surv_labels.dart`），数据层只给枚举/码。
library;

/// 摄像机连接状态 —— 逐字取自 `ui/sds.js` 的 `SYNO.SS.CamSts.*`。
///
/// 官方判据是 `SYNO.SS.Utils.GetCamStatusStr(camStatus)`。
abstract final class SurvCamStatus {
  static const int empty = 0;
  static const int normal = 1;
  static const int deleted = 2;
  static const int disconnected = 3;
  static const int unavailable = 4;
  static const int ready = 5;
  static const int inaccessible = 6;
  static const int disabled = 7;
  static const int unrecognized = 8;
  static const int setting = 9;
  static const int serverDisconnected = 10;
  static const int migrating = 11;
  static const int others = 12;
  static const int recStorageRemoved = 13;
  static const int stopping = 14;
  static const int hostFailed = 15;
  static const int unauthorized = 16;
  static const int rtspError = 17;
  static const int getNoVideo = 18;
  static const int diffCap = 19;
  static const int noCap = 20;
  static const int inactivated = 21;
  static const int fwIncompatible = 22;
  static const int modelNotMatched = 23;

  /// 「能出图」的状态集合（官方 `conn_status_normal` / `conn_status_ready`）。
  static bool isLive(int status) => status == normal || status == ready;
}

/// `Camera.List` / `Camera.GetInfo` 回包里的摄像机记录。
///
/// 字段名逐字对齐 `ui/sds.js` 的 `fieldCamera`；回包里缺字段一律给安全默认值
/// （老固件/精简 `basic:true` 请求会少字段）。
class SurvCameraDto {
  const SurvCameraDto({
    required this.id,
    this.name = '',
    this.dsId = 0,
    this.dsName = '',
    this.enabled = true,
    this.vendor = '',
    this.model = '',
    this.host = '',
    this.port = 0,
    this.status = SurvCamStatus.empty,
    this.camStatus = SurvCamStatus.empty,
    this.recStatus = 0,
    this.fps = 0,
    this.resolution = '',
    this.ownerDsId = 0,
    this.camIdOnRecServer = 0,
    this.camIdOnHost = 0,
    this.ptzCap = 0,
    this.enablePtzControl = false,
    this.presetNum = 0,
    this.autoPan = 0,
    this.objTrack = false,
    this.autoFocus = false,
    this.snapshotPath = '',
    this.blLiveviewPriv = true,
    this.blAudioPriv = false,
    this.deleted = false,
    this.deviceType = 0,
  });

  /// 顶层 `id`。
  final int id;
  final String name;

  /// 所属 DS 的 id（本机 = `LOCAL_DS_ID`，通常 0）。
  final int dsId;
  final String dsName;
  final bool enabled;
  final String vendor;
  final String model;
  final String host;
  final int port;

  /// 顶层 `status`（老字段）。
  final int status;

  /// 顶层 `camStatus`（新字段，`SYNO.SS.CamSts.*` 取值）。
  ///
  /// 两者都收；界面取 [effectiveStatus]（`camStatus` 优先，为 0 时回落 `status`）。
  final int camStatus;
  final int recStatus;
  final int fps;
  final String resolution;

  /// 录像服务器上的 owner DS（`fieldCamera.ownerDsId`）。
  final int ownerDsId;

  /// 录像服务器上的摄像机 id（`camIdOnRecServer`）。
  final int camIdOnRecServer;

  /// 当前主机上的摄像机 id（`camIdOnHost`）。
  final int camIdOnHost;

  /// PTZ 能力位（`ptzCap`）。
  final int ptzCap;
  final bool enablePtzControl;
  final int presetNum;
  final int autoPan;
  final bool objTrack;
  final bool autoFocus;
  final String snapshotPath;

  /// 该账号对该摄像机是否有实时取景权限（`blLiveviewPriv`）。
  final bool blLiveviewPriv;
  final bool blAudioPriv;
  final bool deleted;
  final int deviceType;

  /// 界面用的状态码。
  int get effectiveStatus =>
      camStatus != SurvCamStatus.empty ? camStatus : status;

  /// 是否「在删列表里」（`deleted=true`）——列表默认已过滤，这里再兜一次。
  bool get isDeleted => deleted || effectiveStatus == SurvCamStatus.deleted;

  /// 是否能出图（`conn_status_normal` / `conn_status_ready` 且未禁用）。
  bool get isLive =>
      enabled && !isDeleted && SurvCamStatus.isLive(effectiveStatus);

  /// 是否有 PTZ 控制入口（官方前端判 `enablePtzControl` 与 `ptzCap`）。
  bool get hasPtz => enablePtzControl || ptzCap > 0;

  factory SurvCameraDto.fromJson(Map<String, dynamic> json) => SurvCameraDto(
    id: _int(json['id']),
    name: _str(json['name']),
    dsId: _int(json['dsId']),
    dsName: _str(json['dsName']),
    enabled: _bool(json['enabled'], fallback: true),
    vendor: _str(json['vendor']),
    model: _str(json['model']),
    host: _str(json['host']),
    port: _int(json['port']),
    status: _int(json['status']),
    camStatus: _int(json['camStatus']),
    recStatus: _int(json['recStatus']),
    fps: _int(json['fps']),
    resolution: _str(json['resolution']),
    ownerDsId: _int(json['ownerDsId']),
    camIdOnRecServer: _int(json['camIdOnRecServer']),
    camIdOnHost: _int(json['camIdOnHost']),
    ptzCap: _int(json['ptzCap']),
    enablePtzControl: _bool(json['enablePtzControl']),
    presetNum: _int(json['presetNum']),
    autoPan: _int(json['autoPan']),
    objTrack: _bool(json['objTrack']),
    autoFocus: _bool(json['autoFocus']),
    snapshotPath: _str(json['snapshot_path']),
    blLiveviewPriv: _bool(json['blLiveviewPriv'], fallback: true),
    blAudioPriv: _bool(json['blAudioPriv']),
    deleted: _bool(json['deleted']),
    deviceType: _int(json['deviceType']),
  );
}

/// `Camera.GetStmUrlPath` 回包 `pathInfos[]` 的一项。
///
/// 逐字对齐 `ui/modules/Camera/Camera.js` 的 `SetStmUrl(a)`：
/// `a.unicastPath` / `a.unicastOverHttpPath` / `a.mjpegHttpPath` / `a.mxpegHttpPath`。
class SurvStreamPathDto {
  const SurvStreamPathDto({
    this.unicastPath = '',
    this.unicastOverHttpPath = '',
    this.mjpegHttpPath = '',
    this.mxpegHttpPath = '',
  });

  /// RTSP 单播地址（**注意**：回包里的 host 是服务端视角，跨网/反代时未必可达）。
  final String unicastPath;
  final String unicastOverHttpPath;
  final String mjpegHttpPath;
  final String mxpegHttpPath;

  /// 至少有一条可用路径。
  bool get isEmpty =>
      unicastPath.isEmpty &&
      unicastOverHttpPath.isEmpty &&
      mjpegHttpPath.isEmpty &&
      mxpegHttpPath.isEmpty;

  factory SurvStreamPathDto.fromJson(Map<String, dynamic> json) =>
      SurvStreamPathDto(
        unicastPath: _str(json['unicastPath']),
        unicastOverHttpPath: _str(json['unicastOverHttpPath']),
        mjpegHttpPath: _str(json['mjpegHttpPath']),
        mxpegHttpPath: _str(json['mxpegHttpPath']),
      );
}

/// `Recording.List` v5 回包 `events[]` 的一项。
///
/// 字段名逐字对齐 `ui/modules/Event/EventCommon.js` 的
/// `storeEvtListFields`（`recordId` 是该 store 的 `idProperty`）。
class SurvRecordingDto {
  const SurvRecordingDto({
    required this.recordId,
    this.fileId = '',
    this.cameraId = 0,
    this.cameraName = '',
    this.mountId = 0,
    this.name = '',
    this.startTime = 0,
    this.stopTime = 0,
    this.reason = 0,
    this.archived = false,
  });

  /// `recordId`（store 的 idProperty）。
  final String recordId;

  /// 底层 `id`（录像文件 id；老固件可能只在 `id` 里给）。
  final String fileId;
  final int cameraId;
  final String cameraName;
  final int mountId;
  final String name;

  /// Unix 秒（服务端 `startTime` / `stopTime`）。
  final int startTime;
  final int stopTime;
  final int reason;
  final bool archived;

  /// 时长（秒），负数/异常一律归 0。
  int get durationSeconds {
    final d = stopTime - startTime;
    return d > 0 ? d : 0;
  }

  DateTime? get startAt => startTime > 0
      ? DateTime.fromMillisecondsSinceEpoch(startTime * 1000)
      : null;

  factory SurvRecordingDto.fromJson(Map<String, dynamic> json) =>
      SurvRecordingDto(
        recordId: _str(json['recordId']).isEmpty
            ? _str(json['id'])
            : _str(json['recordId']),
        fileId: _str(json['id']),
        cameraId: _int(json['cameraId']),
        cameraName: _str(json['camera_name']).isEmpty
            ? _str(json['cameraName'])
            : _str(json['camera_name']),
        mountId: _int(json['mountId']),
        name: _str(json['name']),
        startTime: _int(json['startTime']),
        stopTime: _int(json['stopTime']),
        reason: _int(json['reason']),
        archived: _bool(json['archived']),
      );
}

/// `Camera.List` 的分页包装（root `cameras`，v8 回包里还有 `total`）。
///
/// 名字里的 `Result` 是为了**不与页面 widget `SurvCameraPage` 撞名**。
class SurvCameraPageResult {
  const SurvCameraPageResult({this.items = const [], this.total = 0});

  final List<SurvCameraDto> items;
  final int total;
}

/// `Recording.List` 的分页包装（root **`events`**、total **`total`**）。
class SurvRecordingPage {
  const SurvRecordingPage({this.items = const [], this.total = 0});

  final List<SurvRecordingDto> items;
  final int total;
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

String _str(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is num || v is bool) return '$v';
  return '';
}

bool _bool(Object? v, {bool fallback = false}) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true' || s == '1') return true;
    if (s == 'false' || s == '0') return false;
  }
  return fallback;
}
