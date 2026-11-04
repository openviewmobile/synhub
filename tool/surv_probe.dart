// Surveillance Station（DS cam，阶段二 A 最后一批）真机探针。
//
//   # 1) 匿名能力探测（不需要账号）：这台 NAS 装没装 Surveillance Station
//   SYNO_NAS_URL=https://<nas>:<port> dart run tool/surv_probe.dart info
//
//   # 2) 只读功能往返（需要账号；**零写方法**，不会改NAS上的任何东西）
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/surv_probe.dart probe
//
// 事实来源：`docs/station-surveillance-mailplus-insight-research.md`（SPK
// `SurveillanceStation-x86_64-9.3.0-12139` 离线取证）。
//
// ⚠️ 本探针**只打只读方法**：`Camera.List` / `Camera.GetInfo` /
// `Camera.GetStmUrlPath` / `Recording.List`。**一个写方法都不碰** ——
// PTZ（`Move`/`AbsPtz`/`GoPreset`）会真的转动摄像机，本探针故意不调用；
// 相机增删/许可证/System 等管理员方法更不在范围内。
//
// 本探针是"核事实用"的：所有请求都打印实际发出的参数与回包形状，以便把
// research 的开放项（`authLevel=2` 在普通用户会话下到底能不能调、
// MJPEG `StmKey` 形态、Recording.List 时间戳语义）在真机上定案。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/dto/surveillance_dto.dart';
import 'package:synhub/src/data/surveillance_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<DsmWebApi> _connect() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  return api;
}

Future<DsmWebApi> login() async {
  final api = await _connect();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'SurveillanceStation',
  );
  return api;
}

/// 匿名探测：只读 `SYNO.API.Info`（不需要登录）。
Future<void> info() async {
  final api = await _connect();
  final table = await api.discover();
  print('API 总数：${table.length}');
  final ss =
      table.keys.where((k) => k.startsWith('SYNO.SurveillanceStation')).toList()
        ..sort();
  print('SYNO.SurveillanceStation.* 相关 API：${ss.length}');
  for (final k in ss) {
    final e = table[k]!;
    print('  $k  v${e.minVersion}..${e.maxVersion}  path=${e.path}');
  }
  if (ss.isEmpty) {
    print('结论：这台 NAS **没有安装** Surveillance Station');
    print('      （普通用户功能无法真机验证；Camera.List 未认证也回 102）');
    return;
  }
  // 本模块真正依赖的四个 API 是否注册、注册到哪个 path。
  for (final name in [
    SurveillanceStationApi.apiCamera,
    SurveillanceStationApi.apiPtz,
    SurveillanceStationApi.apiRecording,
    SurveillanceStationApi.apiStream,
  ]) {
    final e = table[name];
    print(
      '  $name → '
      '${e == null ? '未注册' : 'v${e.minVersion}..${e.maxVersion} @ ${e.path}'}',
    );
  }
}

/// 只读功能往返：不需要任何写权限。
Future<void> probe() async {
  final api = await login();
  final ss = SurveillanceStationApi(api);
  print('installed=${ss.installed}');
  print(
    '能力表版本协商：Camera=${ss.negotiate(SurveillanceStationApi.apiCamera, const [8, 9])} '
    'PTZ.Move=${ss.negotiate(SurveillanceStationApi.apiPtz, const [6, 5, 4])} '
    'Recording=${ss.negotiate(SurveillanceStationApi.apiRecording, const [5, 4])}',
  );

  print('--- Camera.List v8（普通用户能否调通是 research 的开放项）');
  SurvCameraPageResult page;
  try {
    page = await ss.listCameras();
    print('  total=${page.total} 本页=${page.items.length}');
  } catch (e) {
    print('  ✘ Camera.List → $e');
    print('  归因：${surveillanceFailureKind(e)} / ${describeSurvError(e)}');
    print('  （若 error_code=471 NOT_ADMIN_USER，则确认 authLevel=2 对普通用户生效）');
    return;
  }
  if (page.items.isEmpty) {
    print('提示：这台 NAS 装了 SS 但**一路摄像机都没有** → 详情/录像无法继续验。');
    return;
  }
  for (final c in page.items.take(10)) {
    print(
      '  #${c.id} ${c.name} model=${c.model} host=${c.host} '
      'camStatus=${c.effectiveStatus}(${survStatusName(c.effectiveStatus)}) '
      'live=${c.isLive} ptz=${c.hasPtz} ownerDsId=${c.ownerDsId} '
      'camIdOnRecServer=${c.camIdOnRecServer}',
    );
  }

  final cam = page.items.first;
  print('--- Camera.GetInfo v8（camId=${cam.id}）');
  await _tryPrint('GetInfo', () async {
    final list = await ss.getCameraInfo([cam.id]);
    if (list.isEmpty) {
      print('  回包里没有 cameras[]');
      return null;
    }
    final d = list.first;
    print(
      '  name=${d.name} resolution=${d.resolution} fps=${d.fps} '
      'ptzCap=${d.ptzCap} presetNum=${d.presetNum} '
      'blLiveviewPriv=${d.blLiveviewPriv}',
    );
    return d;
  });

  print('--- Camera.GetStmUrlPath v8（camId=${cam.id}）');
  final path = await _tryPrint('GetStmUrlPath', () async {
    final p = await ss.getStreamPath(cam.id);
    if (p == null) {
      print('  回包里没有 pathInfos[]');
      return null;
    }
    print('  unicastPath=${p.unicastPath}');
    print('  unicastOverHttpPath=${p.unicastOverHttpPath}');
    print('  mjpegHttpPath=${p.mjpegHttpPath}');
    print('  mxpegHttpPath=${p.mxpegHttpPath}');
    return p;
  });
  if (path == null) {
    print('提示：本机 RTSP 模板拼出来是：');
  }
  print('  rtspUrl=${ss.rtspUrl(cameraId: cam.id, dsId: cam.ownerDsId)}');
  print('  mjpegUrl=${ss.mjpegUrl(cameraId: cam.id)}');
  print('  snapshotUrl=${ss.snapshotUrl(cameraId: cam.id)}');
  print('  snapshotUrlV9=${ss.snapshotUrlV9(id: cam.id)}');
  print('  （MJPEG 的 StmKey 形态 / 是否需要 sid 是 research §2.4(d) 的开放项）');

  print('--- Recording.List v5（camId=${cam.id}，最近 24h）');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  await _tryPrint('Recording.List', () async {
    final recs = await ss.listRecordings(
      cameraIds: [cam.id],
      fromTime: now - 24 * 3600,
      toTime: now,
      limit: 20,
    );
    print('  root=events total=${recs.total} 本页=${recs.items.length}');
    for (final r in recs.items.take(10)) {
      print(
        '  recordId=${r.recordId} cam=${r.cameraName} '
        'start=${r.startTime} stop=${r.stopTime} dur=${r.durationSeconds}s '
        'reason=${r.reason}',
      );
    }
    if (recs.items.isEmpty) {
      print('  （空空如也：可能是这段时间真没录像，也可能是 evtSrcType/时间戳语义不对）');
    }
    return recs;
  });
  print('--- 探针结束（全程零写方法，未改动 NAS 上任何状态）');
}

/// 状态码 → 官方常量名（对齐 `ui/sds.js` 的 `SYNO.SS.CamSts.*`）。
String survStatusName(int status) => switch (status) {
  0 => 'EMPTY',
  1 => 'NORMAL',
  2 => 'DELETED',
  3 => 'DISCONNECTED',
  4 => 'UNAVAILABLE',
  5 => 'READY',
  6 => 'INACCESSIBLE',
  7 => 'DISABLED',
  8 => 'UNRECOGNIZED',
  9 => 'SETTING',
  10 => 'SERVER_DISCONN',
  11 => 'MIGRATING',
  12 => 'OTHERS',
  13 => 'REC_STORAGE_REMOVED',
  14 => 'STOPPING',
  15 => 'HOST_FAILED',
  16 => 'UNAUTHORIZED',
  17 => 'RTSP_ERROR',
  18 => 'GET_NO_VIDEO',
  19 => 'DIFF_CAP',
  20 => 'NO_CAP',
  21 => 'INACTIVATED',
  22 => 'FW_INCOMPATIBLE',
  23 => 'MODEL_NOT_MATCHED',
  _ => 'UNKNOWN($status)',
};

Future<T?> _tryPrint<T>(String what, Future<T> Function() run) async {
  try {
    final v = await run();
    print('  ✔ $what');
    return v;
  } catch (e) {
    print('  ✘ $what → $e');
    print('  归因：${surveillanceFailureKind(e)} / ${describeSurvError(e)}');
    return null;
  }
}

Future<void> main(List<String> args) async {
  final cmd = args.isEmpty ? 'info' : args.first;
  switch (cmd) {
    case 'info':
      await info();
    case 'probe':
      await probe();
    default:
      stderr.writeln('用法: dart run tool/surv_probe.dart [info|probe]');
      exitCode = 2;
  }
}
