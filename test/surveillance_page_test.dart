// Surveillance Station 页面层离线验证（阶段二 A 最后一批）。
//
// 接口层用例在 `test/surveillance_station_test.dart`；这里只验：
//   * 列表页把请求发对了，把摄像机画出来了；
//   * 空态/错误态**区分**套件未安装 / 无权限 / 网络失败（图标+文案都要不同，
//     未安装态**不给重试**，改用"去套件中心安装"的引导）；
//   * 详情页的实时地址、PTZ、录像三块。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/surveillance_station.dart';
import 'package:synhub/src/features/surveillance/surv_camera_page.dart';
import 'package:synhub/src/features/surveillance/surv_page.dart';
import 'package:synhub/src/features/surveillance/surv_providers.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

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

Map<String, dynamic> _cam({
  int id = 1,
  String name = '前门',
  int camStatus = 1,
  bool ptz = false,
  String resolution = '1920x1080',
  int fps = 25,
}) => {
  'id': id,
  'name': name,
  'camStatus': camStatus,
  'enablePtzControl': ptz,
  'resolution': resolution,
  'fps': fps,
  'host': '10.0.0.9',
};

const _livePaths = {
  'pathInfos': [
    {
      'unicastPath': 'rtsp://10.0.0.9:554/live',
      'mjpegHttpPath': 'http://10.0.0.9/mjpeg',
    },
  ],
};

/// 挂一个页面：假传输 + 只覆盖监控模块的 API provider。
Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  bool noSs = false,
  bool noSession = false,
  void Function(FakeTransport t)? setup,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    if (!noSs) ..._ssTable,
  });
  t.failures.addAll(failures);
  setup?.call(t);
  final api = DsmWebApi(t);
  await api.discover();
  final c = ProviderContainer(
    overrides: [
      surveillanceApiProvider.overrideWithValue(
        noSession ? null : SurveillanceStationApi(api),
      ),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump(); // postFrameCallback → load()
  await tester.pump(const Duration(milliseconds: 200));
  return (t: t, c: c);
}

void main() {
  group('空态 / 错误态（三态必须互相区分）', () {
    testWidgets('没连会话 → 未连接，不是"没安装"', (tester) async {
      await _pump(tester, const SurveillancePage(), noSession: true);
      expect(find.byKey(const Key('surv-no-session')), findsOneWidget);
      expect(find.byKey(const Key('surv-not-installed')), findsNothing);
      expect(find.text('这台 NAS 没有安装 Surveillance Station'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('套件未安装 → 说"没有安装"+套件中心引导，不给重试', (tester) async {
      await _pump(tester, const SurveillancePage(), noSs: true);
      expect(find.byKey(const Key('surv-not-installed')), findsOneWidget);
      expect(find.text('这台 NAS 没有安装 Surveillance Station'), findsOneWidget);
      expect(
        find.text('在 DSM「套件中心」安装 Surveillance Station 后即可使用'),
        findsOneWidget,
      );
      expect(find.text('重试'), findsNothing);
      expect(find.text('摄像机列表加载失败'), findsNothing);
      expect(find.byKey(const Key('surv-no-privilege')), findsNothing);
      // 未安装不给"添加摄像机"之类的动作按钮
      expect(find.byIcon(Icons.extension_off_outlined), findsOneWidget);
    });

    testWidgets('无权限（105）→ 说权限 + 找管理员，不是"加载失败"', (tester) async {
      await _pump(
        tester,
        const SurveillancePage(),
        failures: {'SYNO.SurveillanceStation.Camera.List': 105},
      );
      expect(find.byKey(const Key('surv-no-privilege')), findsOneWidget);
      expect(find.text('这个账号没有使用 Surveillance Station 的权限'), findsOneWidget);
      expect(
        find.text('请联系管理员为这个账号授予 Surveillance Station 权限'),
        findsOneWidget,
      );
      expect(find.text('摄像机列表加载失败'), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('无权限（471 非管理员）也归到"无权限"，不是"加载失败"', (tester) async {
      await _pump(
        tester,
        const SurveillancePage(),
        failures: {'SYNO.SurveillanceStation.Camera.List': 471},
      );
      expect(find.byKey(const Key('surv-no-privilege')), findsOneWidget);
      expect(find.text('摄像机列表加载失败'), findsNothing);
    });

    testWidgets('网络失败 → 网络文案 + 可重试；图标与上面两种不同', (tester) async {
      await _pump(
        tester,
        const SurveillancePage(),
        setup: (t) => t.onCall = (p) {
          if (p['method'] == 'List' &&
              p['api'] == 'SYNO.SurveillanceStation.Camera') {
            throw DsmTransportException('offline');
          }
          return null;
        },
      );
      expect(find.byKey(const Key('surv-error')), findsOneWidget);
      expect(find.text('摄像机列表加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off), findsOneWidget);
      expect(find.byKey(const Key('surv-not-installed')), findsNothing);
      expect(find.byKey(const Key('surv-no-privilege')), findsNothing);
    });

    testWidgets('装了但一路都没有 → 空态（不是错误，也不是未安装）', (tester) async {
      await _pump(
        tester,
        const SurveillancePage(),
        responses: {
          'SYNO.SurveillanceStation.Camera.List': {'total': 0, 'cameras': []},
        },
      );
      expect(find.byKey(const Key('surv-empty')), findsOneWidget);
      expect(find.text('还没有摄像机'), findsOneWidget);
      expect(find.byKey(const Key('surv-not-installed')), findsNothing);
      expect(find.byKey(const Key('surv-error')), findsNothing);
      expect(find.text('重试'), findsNothing);
    });
  });

  group('列表页正常路径', () {
    testWidgets('两路摄像机 → 显示名称/状态/行；计数正确', (tester) async {
      final r = await _pump(
        tester,
        const SurveillancePage(),
        responses: {
          'SYNO.SurveillanceStation.Camera.List': {
            'total': 2,
            'cameras': [
              _cam(id: 1, name: '前门'),
              _cam(id: 2, name: '车库', camStatus: 3),
            ],
          },
        },
      );
      expect(find.byKey(const Key('surv-camera-1')), findsOneWidget);
      expect(find.byKey(const Key('surv-camera-2')), findsOneWidget);
      expect(find.text('前门'), findsOneWidget);
      expect(find.text('车库'), findsOneWidget);
      expect(find.text('直播中'), findsOneWidget);
      expect(find.text('已断开'), findsOneWidget);
      expect(find.text('共 2 路'), findsOneWidget);
      // 请求形态：确实打了 Camera.List，带 blIncludeDeletedCam
      final call = r.t.calls.firstWhere(
        (c) =>
            c['method'] == 'List' &&
            c['api'] == 'SYNO.SurveillanceStation.Camera',
      );
      expect(call['version'], '8');
      expect(call['blIncludeDeletedCam'], true);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点行 → 进详情页（标题=摄像机，有实时地址块）', (tester) async {
      await _pump(
        tester,
        const SurveillancePage(),
        responses: {
          'SYNO.SurveillanceStation.Camera.List': {
            'total': 1,
            'cameras': [_cam(id: 1, name: '前门')],
          },
          'SYNO.SurveillanceStation.Camera.GetInfo': {
            'cameras': [_cam(id: 1, name: '前门')],
          },
          'SYNO.SurveillanceStation.Camera.GetStmUrlPath': _livePaths,
          'SYNO.SurveillanceStation.Recording.List': {'total': 0, 'events': []},
        },
      );
      await tester.tap(find.byKey(const Key('surv-camera-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('surv-live-urls')), findsOneWidget);
      expect(find.text('RTSP 地址'), findsOneWidget);
      expect(find.text('MJPEG 地址'), findsOneWidget);
      expect(find.textContaining('rtsp://'), findsWidgets);
      expect(find.byKey(const Key('surv-rec-empty')), findsOneWidget);
    });
  });

  group('详情页', () {
    Future<({FakeTransport t, ProviderContainer c})> pumpDetail(
      WidgetTester tester, {
      Map<String, Map<String, dynamic>> responses = const {},
    }) => _pump(
      tester,
      const SurvCameraPage(cameraId: 1),
      responses: {
        'SYNO.SurveillanceStation.Camera.GetInfo': {
          'cameras': [_cam(id: 1, name: '前门', ptz: true)],
        },
        'SYNO.SurveillanceStation.Camera.GetStmUrlPath': _livePaths,
        'SYNO.SurveillanceStation.Recording.List': {
          'total': 1,
          'events': [
            {
              'recordId': 'r-1',
              'camera_name': '前门',
              'startTime': 0,
              'stopTime': 0,
            },
          ],
        },
        ...responses,
      },
    );

    testWidgets('有 PTZ 能力 → 出现九宫格按键；录像列表出来', (tester) async {
      final r = await pumpDetail(tester);
      expect(find.byKey(const Key('surv-ptz')), findsOneWidget);
      expect(find.byKey(const Key('surv-ptz-up')), findsOneWidget);
      expect(find.byKey(const Key('surv-ptz-home')), findsOneWidget);
      expect(find.byKey(const Key('surv-rec-list')), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 详情页只调只读方法：不该出现任何 PTZ 写方法
      expect(
        r.t.calls.where(
          (c) =>
              c['api'] == 'SYNO.SurveillanceStation.PTZ' &&
              c['method'] != 'ListPreset',
        ),
        isEmpty,
      );
    });

    testWidgets('离线摄像机 → 实时块给出"不在线"而不是地址', (tester) async {
      await _pump(
        tester,
        const SurvCameraPage(cameraId: 1),
        responses: {
          'SYNO.SurveillanceStation.Camera.GetInfo': {
            'cameras': [_cam(id: 1, name: '前门', camStatus: 3)],
          },
          'SYNO.SurveillanceStation.Recording.List': {'events': []},
        },
      );
      expect(find.byKey(const Key('surv-live-unavailable')), findsOneWidget);
      expect(find.text('这台摄像机当前不在线，暂时取不到实时画面'), findsOneWidget);
      expect(find.byKey(const Key('surv-live-urls')), findsNothing);
    });

    testWidgets('没连会话 → 详情页说"没安装"，不崩', (tester) async {
      await _pump(
        tester,
        const SurvCameraPage(cameraId: 1),
        noSession: true,
        responses: const {},
      );
      expect(
        find.byKey(const Key('surv-detail-not-installed')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
