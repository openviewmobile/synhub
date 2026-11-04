// Surveillance Station 接口层离线验证（阶段二 A 最后一批）。
//
// 事实来源：`docs/station-surveillance-mailplus-insight-research.md` §2.3–§2.4
// （api/method/版本/参数逐字对齐 NAS 上 SurveillanceStation 9.3.0-12139 包内的
// 官方 Web 前端与 `.so` 模板）。
// 这里只验"客户端把请求拼对了、把回包解对了、把错误码翻对了"，不打真机。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/surveillance_dto.dart';
import 'package:synhub/src/data/surveillance_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 真实 `SYNO.API.Info` 里 SS 的条目形状（版本区间来自 SPK 内的 `.lib`）。
const _ssTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SurveillanceStation.Camera': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.SurveillanceStation.PTZ': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 6,
  },
  'SYNO.SurveillanceStation.Recording': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.SurveillanceStation.Stream.VideoStreaming': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Future<(SurveillanceStationApi, FakeTransport)> boot({
  Map<String, Map<String, dynamic>> responses = const {},
  bool noSs = false,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    if (!noSs) ..._ssTable,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (SurveillanceStationApi(api), t);
}

Map<String, dynamic> callOf(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

void main() {
  group('能力探测 / 未安装判据', () {
    test('能力表有 Camera → installed=true', () async {
      final (ss, _) = await boot();
      expect(ss.installed, isTrue);
    });

    test('能力表没有 SS 命名空间 → installed=false（套件未安装）', () async {
      final (ss, _) = await boot(noSs: true);
      expect(ss.installed, isFalse);
    });

    test('版本固定在官方客户端那一版（Camera 8、PTZ.Move 6、Recording 5）', () async {
      final (ss, _) = await boot();
      expect(ss.negotiate(SurveillanceStationApi.apiCamera, const [8]), 8);
      expect(ss.negotiate(SurveillanceStationApi.apiPtz, const [6]), 6);
      expect(ss.negotiate(SurveillanceStationApi.apiRecording, const [5]), 5);
    });

    test('老服务器只支持低版本时退让到它的 maxVersion', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._ssTable,
        'SYNO.SurveillanceStation.Camera': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 4,
        },
      });
      final api = DsmWebApi(t);
      await api.discover();
      final ss = SurveillanceStationApi(api);
      expect(ss.negotiate(SurveillanceStationApi.apiCamera, const [8]), 4);
    });
  });

  group('Camera.List v8 请求形态（research §2.4(a)）', () {
    test('逐字参数 + root cameras 解析', () async {
      final (ss, t) = await boot(
        responses: {
          'SYNO.SurveillanceStation.Camera.List': {
            'total': 2,
            'cameras': [
              {
                'id': 1,
                'name': '前门',
                'model': 'DS-2CD',
                'host': '10.0.0.9',
                'camStatus': 1,
                'ptzCap': 1,
                'enablePtzControl': true,
                'presetNum': 3,
                'resolution': '1920x1080',
                'fps': 25,
              },
              {'id': 2, 'name': '车库', 'status': 3},
            ],
          },
        },
      );
      final page = await ss.listCameras();
      final call = callOf(t, 'List');
      expect(call['api'], 'SYNO.SurveillanceStation.Camera');
      expect(call['version'], '8');
      expect(call['ownerDsId'], 0);
      expect(call['blIncludeRecCnt'], false);
      expect(call['blIncludeAuInfo'], false);
      expect(call['blIncludeDeletedCam'], true);
      expect(call['blCameraIdChecked'], true);
      expect(call['basic'], true);
      expect(call['ptz'], true);
      expect(call['fisheye'], true);
      expect(call['deviceOutCap'], true);
      expect(call['streamInfo'], true);
      expect(call['blGetMulticastInfo'], true);
      expect(call['additional'], 'video');
      expect(call.containsKey('camIdList'), isFalse);

      expect(page.total, 2);
      expect(page.items, hasLength(2));
      expect(page.items.first.name, '前门');
      expect(page.items.first.isLive, isTrue);
      expect(page.items.first.hasPtz, isTrue);
      // 第二条只有老字段 status=3（disconnected）
      expect(page.items[1].effectiveStatus, SurvCamStatus.disconnected);
      expect(page.items[1].isLive, isFalse);
    });

    test('camIds 非空 → camIdList 逗号串；cameras 缺失 → 空页', () async {
      final (ss, t) = await boot();
      final page = await ss.listCameras(camIds: [3, 7]);
      expect(callOf(t, 'List')['camIdList'], '3,7');
      expect(page.items, isEmpty);
      expect(page.total, 0);
    });

    test('cameras 不是 List（回包变形）→ 不崩、给空列表', () async {
      final (ss, _) = await boot(
        responses: {
          'SYNO.SurveillanceStation.Camera.List': {'cameras': 'oops'},
        },
      );
      final page = await ss.listCameras();
      expect(page.items, isEmpty);
    });
  });

  group('GetInfo / GetStmUrlPath', () {
    test('GetInfo v8 用 cameraIds 逗号串，回包 root cameras', () async {
      final (ss, t) = await boot(
        responses: {
          'SYNO.SurveillanceStation.Camera.GetInfo': {
            'cameras': [
              {'id': 5, 'name': 'A'},
            ],
          },
        },
      );
      final list = await ss.getCameraInfo([5, 6]);
      final call = callOf(t, 'GetInfo');
      expect(call['version'], '8');
      expect(call['cameraIds'], '5,6');
      expect(call['blIncludeDeletedCam'], true);
      expect(call['streamInfo'], true);
      expect(list.single.id, 5);
    });

    test('GetInfo 空 cameraIds → 直接返回空，不发请求', () async {
      final (ss, t) = await boot();
      expect(await ss.getCameraInfo(const []), isEmpty);
      expect(t.calls.where((c) => c['method'] == 'GetInfo'), isEmpty);
    });

    test('getCamera 找不到 → null', () async {
      final (ss, _) = await boot(
        responses: {
          'SYNO.SurveillanceStation.Camera.GetInfo': {'cameras': []},
        },
      );
      expect(await ss.getCamera(1), isNull);
    });

    test('GetStmUrlPath v8：{cameraIds} → pathInfos[0] 四路径', () async {
      final (ss, t) = await boot(
        responses: {
          'SYNO.SurveillanceStation.Camera.GetStmUrlPath': {
            'pathInfos': [
              {
                'unicastPath': 'rtsp://10.0.0.9:554/stream',
                'unicastOverHttpPath': 'http://10.0.0.9/live',
                'mjpegHttpPath': 'http://10.0.0.9/mjpeg',
                'mxpegHttpPath': 'http://10.0.0.9/mxpeg',
              },
            ],
          },
        },
      );
      final p = await ss.getStreamPath(9);
      expect(callOf(t, 'GetStmUrlPath')['cameraIds'], '9');
      expect(p!.unicastPath, 'rtsp://10.0.0.9:554/stream');
      expect(p.mjpegHttpPath, 'http://10.0.0.9/mjpeg');
      expect(p.isEmpty, isFalse);
    });

    test('GetStmUrlPath 没有 pathInfos → null', () async {
      final (ss, _) = await boot();
      expect(await ss.getStreamPath(1), isNull);
    });
  });

  group('PTZ 请求形态（research §2.4(f)）', () {
    test('Move v6：cameraId/moveType/direction/ptSpeed/control', () async {
      final (ss, t) = await boot();
      await ss.ptzMove(
        cameraId: 4,
        moveType: 'Start',
        direction: 'Left',
        ptSpeed: 3,
      );
      final call = callOf(t, 'Move');
      expect(call['api'], 'SYNO.SurveillanceStation.PTZ');
      expect(call['version'], '6');
      expect(call['cameraId'], 4);
      expect(call['moveType'], 'Start');
      expect(call['direction'], 'Left');
      expect(call['ptSpeed'], 3);
      expect(call.containsKey('control'), isFalse);
    });

    test('AbsPtz v5：posX/posY', () async {
      final (ss, t) = await boot();
      await ss.ptzAbsolute(cameraId: 4, posX: 120, posY: 55);
      final call = callOf(t, 'AbsPtz');
      expect(call['version'], '5');
      expect(call['posX'], 120);
      expect(call['posY'], 55);
    });

    test('GoPreset v4：position/speed/type/isPreview=1', () async {
      final (ss, t) = await boot();
      await ss.ptzGoPreset(cameraId: 4, position: 2, speed: 5, type: 1);
      final call = callOf(t, 'GoPreset');
      expect(call['version'], '4');
      expect(call['position'], 2);
      expect(call['isPreview'], 1);
    });

    test('ListPreset v1：{cameraId, doSync:true}（本轮新增取证）', () async {
      final (ss, t) = await boot(
        responses: {
          'SYNO.SurveillanceStation.PTZ.ListPreset': {
            'presetList': [
              {'position': 1, 'name': 'home'},
            ],
          },
        },
      );
      final data = await ss.ptzListPreset(cameraId: 8);
      final call = callOf(t, 'ListPreset');
      expect(call['version'], '1');
      expect(call['cameraId'], 8);
      expect(call['doSync'], true);
      // 回包字段未取证 → 原样返回，不做 DTO
      expect(data['presetList'], isA<List<dynamic>>());
    });
  });

  group('Recording.List v5（研究 §2.4(i)：root events）', () {
    test('逐字参数 + root events/total 解析', () async {
      final (ss, t) = await boot(
        responses: {
          'SYNO.SurveillanceStation.Recording.List': {
            'total': 2,
            'events': [
              {
                'recordId': 'r-1',
                'cameraId': 3,
                'camera_name': '前门',
                'startTime': 1700000000,
                'stopTime': 1700000060,
                'reason': 1,
                'archived': false,
              },
              {'id': 'r-2', 'startTime': 1700000100, 'stopTime': 1700000090},
            ],
          },
        },
      );
      final page = await ss.listRecordings(
        cameraIds: [3],
        fromTime: 1699990000,
        toTime: 1700001000,
        timezoneOffset: 28800,
        start: 0,
        limit: 20,
      );
      final call = callOf(t, 'List');
      expect(call['api'], 'SYNO.SurveillanceStation.Recording');
      expect(call['version'], '5');
      expect(call['cameraIds'], '3');
      expect(call['fromTime'], 1699990000);
      expect(call['toTime'], 1700001000);
      expect(call['evtSrcType'], 'local');
      expect(call['evtSrcId'], 0);
      expect(call['dsId'], 0);
      expect(call['timezoneOffset'], 28800);
      expect(call['start'], 0);
      expect(call['limit'], 20);

      expect(page.total, 2);
      expect(page.items.first.recordId, 'r-1');
      expect(page.items.first.cameraName, '前门');
      expect(page.items.first.durationSeconds, 60);
      // 第二条只有 id → recordId 回落 id；stop<start → 时长归 0
      expect(page.items[1].recordId, 'r-2');
      expect(page.items[1].durationSeconds, 0);
    });

    test('events 缺失 → 空页', () async {
      final (ss, _) = await boot();
      final page = await ss.listRecordings(fromTime: 1, toTime: 2);
      expect(page.items, isEmpty);
      expect(page.total, 0);
    });
  });

  group('流地址 / 快照 URL 拼装（research §2.4(d)(e)）', () {
    test(
      'mjpegUrl：Stream.VideoStreaming v1 + format/cameraId/StmKey',
      () async {
        final (ss, _) = await boot();
        final url = ss.mjpegUrl(cameraId: 7, stmKey: 'KEY123');
        expect(url, contains('/webapi/entry.cgi'));
        expect(
          url,
          contains('api=SYNO.SurveillanceStation.Stream.VideoStreaming'),
        );
        expect(url, contains('version=1'));
        expect(url, contains('method=Stream'));
        expect(url, contains('format=mjpeg'));
        expect(url, contains('cameraId=7'));
        expect(url, contains('StmKey=KEY123'));
      },
    );

    test('rtspUrl：rtsp.cgi 模板 + Sms=<id>.unicast + DsId', () async {
      final (ss, _) = await boot();
      final url = ss.rtspUrl(cameraId: 7, dsId: 0, stmKey: 'K');
      expect(url, startsWith('rtsp://nas.example.com:5001/'));
      expect(
        url,
        contains('/webman/3rdparty/SurveillanceStation/cgi/rtsp.cgi'),
      );
      expect(url, contains('Sms=7.unicast'));
      expect(url, contains('DsId=0'));
    });

    test(
      'snapshotUrl v1 用 cameraId/timestamp/preview；v9 用 id/profileType',
      () async {
        final (ss, _) = await boot();
        final v1 = ss.snapshotUrl(cameraId: 7, timestamp: 123, preview: false);
        expect(v1, contains('version=1'));
        expect(v1, contains('method=GetSnapshot'));
        expect(v1, contains('cameraId=7'));
        expect(v1, contains('timestamp=123'));
        expect(v1, contains('preview=false'));

        final v9 = ss.snapshotUrlV9(id: 7, profileType: 2);
        expect(v9, contains('version=9'));
        expect(v9, contains('id=7'));
        expect(v9, contains('profileType=2'));
      },
    );
  });

  group('错误分类与文案（三态判据）', () {
    test('102/103/104/121 → notInstalled', () {
      for (final c in [102, 103, 104, 121]) {
        expect(
          surveillanceFailureKind(DsmApiException(c)),
          SurvFailureKind.notInstalled,
        );
      }
    });

    test('105/160/471/472 → noPrivilege', () {
      for (final c in [105, 160, 471, 472]) {
        expect(
          surveillanceFailureKind(DsmApiException(c)),
          SurvFailureKind.noPrivilege,
        );
      }
    });

    test('网络异常 → network；405/406 → network；其它 → other', () {
      expect(
        surveillanceFailureKind(DsmTransportException('offline')),
        SurvFailureKind.network,
      );
      expect(
        surveillanceFailureKind(DsmApiException(405)),
        SurvFailureKind.network,
      );
      expect(
        surveillanceFailureKind(DsmApiException(400)),
        SurvFailureKind.other,
      );
    });

    test('describeSurvError 给出可读中文（未安装/无权限/许可/非管理员）', () {
      expect(
        describeSurvError(DsmApiException(102)),
        '这台 NAS 没有安装 Surveillance Station',
      );
      expect(
        describeSurvError(DsmApiException(160)),
        '这个账号没有使用 Surveillance Station 的权限',
      );
      expect(
        describeSurvError(DsmApiException(471)),
        '这个账号没有使用 Surveillance Station 的权限',
      );
      expect(describeSurvError(DsmApiException(403)), contains('许可不足'));
      expect(describeSurvError(DsmApiException(400)), '操作执行失败');
      expect(describeSurvError(DsmApiException(999)), contains('999'));
    });
  });

  group('DTO 缺字段 / null / 变形', () {
    test('摄像机全空对象 → 安全默认值，不崩', () {
      final c = SurvCameraDto.fromJson(const {});
      expect(c.id, 0);
      expect(c.name, '');
      expect(c.enabled, isTrue);
      expect(c.blLiveviewPriv, isTrue);
      expect(c.isLive, isFalse); // status=0(EMPTY)
      expect(c.hasPtz, isFalse);
    });

    test('字符串/数字混杂的布尔与整数字段都能收', () {
      final c = SurvCameraDto.fromJson(const {
        'id': '12',
        'camStatus': '1',
        'enabled': 1,
        'enablePtzControl': 'true',
        'deleted': 'false',
      });
      expect(c.id, 12);
      expect(c.effectiveStatus, 1);
      expect(c.enabled, isTrue);
      expect(c.hasPtz, isTrue);
      expect(c.isDeleted, isFalse);
    });

    test('录像 recordId 缺 → 回落 id；null 字段不崩', () {
      final r = SurvRecordingDto.fromJson(const {
        'id': 'abc',
        'camera_name': null,
        'archived': null,
      });
      expect(r.recordId, 'abc');
      expect(r.fileId, 'abc');
      expect(r.cameraName, '');
      expect(r.archived, isFalse);
    });

    test('stream path 全空 → isEmpty=true', () {
      expect(SurvStreamPathDto.fromJson(const {}).isEmpty, isTrue);
    });
  });
}
