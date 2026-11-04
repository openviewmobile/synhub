// 相册媒体增强批次（P13/P14/P36）离线用例的**共享测试脚手架**。
//
// 全部离线：`FakeTransport`，不连 NAS、不弹系统选择器、不碰设备。
// 本文件只放"三个用例文件都要用"的东西：能力表、条目构造器、pump 装配、
// 以及一张**真的等距柱状探针图**（球面重投影的用例必须有一张左右可区分的图，
// 1×1 纯色图重投影后无论怎么拖都是同一片颜色，测不出"画面变了"）。
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 相册相关的能力表（用例可覆盖 `maxVersion` 验版本裁剪分支）。
///
/// `SYNO.Foto.Browse.Item` 给 **9**：比真机的 7 还高一位，用来证明
/// `motion_photo` 的裁剪判据是 `>= 3`（官方 `SUPPORT_MOTION_PHOTO_VERSION`），
/// 而不是"跟着 maxVersion 走"。
const Map<String, Map<String, dynamic>> kPhotoMediaTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Streaming': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Download': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
};

Set<String> photoMediaApis() => {
  'SYNO.Foto.Browse.Item',
  'SYNO.Foto.Thumbnail',
  'SYNO.Foto.Streaming',
  'SYNO.Foto.Download',
  'SYNO.Foto.Setting.User',
};

/// 一张 **64×32 的等距柱状探针图**（左半红→右半蓝水平渐变，顶部 1/4 绿色带）。
///
/// 为什么必须"左右可区分"：`PanoramaView` 的球面重投影是**逐顶点采样纹理**，
/// 视角一变，同一屏幕像素采到的纹理坐标就变 → 画面颜色必须跟着变。
/// 纯色图做不到这个断言。
///
/// 为什么是**内嵌常量**而不是运行时 `PictureRecorder` 生成：本文件被
/// `testWidgets` 使用，而测试体跑在 FakeAsync 里 —— 引擎的
/// `toByteData`/`instantiateImageCodec` 这类真异步在那里**永远不会完成**，
/// 会让用例挂死（本批实际踩到过）。所以这张图离线生成好后内联进来，
/// 取字节是**同步**的。（生成脚本与参数见报告「探针图」一节。）
///
/// 像素格式：8-bit truecolor（color type 2），无隔行。
final Uint8List equirectProbePngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAIAAAAt/+nTAAAA/klEQVR42u3PQUcDAABH8XdoLBqN'
  'RtFYLIrGoiiKRmNR1GGHRlEURVEURbFRFMXGRqOxqMMOxUajKIqiWBRFURRFURRFHRZ9hHUaf94H'
  'eD/Ikt8JIIAAAgjwPwDZAn6MfBXxUcxbCS+lPJXzYOPOzk0VVzVcODmr47SB4yYOW9hvZddDup1U'
  'J1teEt1s9LDWR2yA6BCREUJjLE+wOMX8DAE/s3NMLzC5xHiQ0TDDKwyu0h+ndx1fAu8mXUk6tmnb'
  'wb2H64DmIxpPqM9Qe47jkuprKm+puMf6SNkzllfM75g+KfzG8PcvgAACCCCAAAIIIIAAAggggAAC'
  'CCBADoBfNKv4auQqghoAAAAASUVORK5CYII=',
);

/// 只建"假 NAS + [FotoApi]"（不看界面，只看**请求参数/直链**）。
Future<({FotoApi api, FakeTransport t})> photoMediaApi({
  Map<String, Map<String, dynamic>>? apiTable,
}) async {
  final t = FakeTransport(const {}, {
    ...FakeTransport.table,
    ...kPhotoMediaTable,
    ...?apiTable,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (api: FotoApi(api), t: t);
}

/// 在 `tester.runAsync` 里把探针图解成 `ui.Image`（供 `PanoramaView(image:)` 注入）。
///
/// **必须**走 `runAsync`：widget test 的测试体跑在 FakeAsync 里，引擎的真异步
/// （`instantiateImageCodec` / `toByteData`）在那里不会完成 —— 直接在测试体里
/// `await` 会挂死用例（本批实际踩到过，锁定过程见报告「踩坑」一节）。
Future<ui.Image> decodeProbeImage(WidgetTester tester) async {
  final image = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(equirectProbePngBytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  });
  return image!;
}

/// 构造一条照片/视频条目（默认普通照片）。
Map<String, dynamic> photoMediaItem(
  String id, {
  String type = 'photo',
  String filename = '',
  int time = 0,
  String folderId = '10',
  String? liveType,
  Map<String, dynamic>? motionPhoto,
  Map<String, dynamic>? extraAdditional,
}) => {
  'id': id,
  'filename': filename.isEmpty ? 'IMG_$id.jpg' : filename,
  'filesize': 2048,
  'time': time == 0
      ? DateTime(2026, 9, 18, 10).millisecondsSinceEpoch ~/ 1000
      : time,
  'folder_id': folderId,
  'type': type,
  if (liveType != null) 'live_type': liveType,
  'additional': {
    'thumbnail': {'sm': 'sm_$id', 'm': 'm_$id', 'cache_key': 'ck_$id'},
    ...?extraAdditional,
    if (motionPhoto != null) 'motion_photo': motionPhoto,
  },
};

/// 动态照片的 `additional.motion_photo`（形状是 `video_meta`：官方
/// `ImageTableAdditional.motionPhoto` 的类型就是 `ImageTableVideoMeta`）。
Map<String, dynamic> motionPhotoMeta({int duration = 3000}) => {
  'duration': duration,
  'resolution_x': 1920,
  'resolution_y': 1080,
  'video_codec': 'h264',
  'container_type': 'mp4',
};

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

ServiceAvailabilitySnapshot photoMediaSnap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values)
          s: s == StationService.photo
              ? classifyApiTable(kServiceRegistry[StationService.photo]!, apis)
              : AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 9, 24),
    );

/// 装配一个"照片页 + 假 NAS"的环境。
Future<({FakeTransport t, ProviderContainer c})> pumpPhotoMedia(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  Set<String>? apis,
  Map<String, Map<String, dynamic>>? apiTable,
  int surfaceWidth = 1200,
  int surfaceHeight = 2400,
  bool downloadProbeImage = true,
}) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final t = FakeTransport(const {}, {
    ...FakeTransport.table,
    ...kPhotoMediaTable,
    ...?apiTable,
  });
  // 大画布：顶栏动作条目多，默认 800×600 会让右侧按钮不进树（点不到）。
  tester.view.physicalSize = Size(
    surfaceWidth.toDouble(),
    surfaceHeight.toDouble(),
  );
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (downloadProbeImage) {
    t.downloadBytes = equirectProbePngBytes;
  }
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (key == 'SYNO.Foto.Setting.User.get') {
      return {
        'team_space_permission': 'none',
        'enable_similar': true,
        'enable_person': true,
        'enable_concept': true,
        'timeline_group_unit': 'day',
      };
    }
    // `get_exif` 被 `PhotoExifSection` 订阅：不给就会一直 loading。
    if (key == 'SYNO.Foto.Browse.Item.get_exif') {
      return {'list': <dynamic>[]};
    }
    return responses[key] ?? const <String, dynamic>{};
  };
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(photoMediaSnap(apis ?? photoMediaApis())),
      ),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await settlePhotoMedia(tester);
  return (t: t, c: c);
}

/// 多泵几帧把微任务/动画推完（**不用** `pumpAndSettle`：有无限转圈的
/// `CircularProgressIndicator` 时会超时）。
Future<void> settlePhotoMedia(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 点一个 key（目标在屏幕外时先滚到可见）。
Future<void> tapPhotoMediaKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await settlePhotoMedia(tester);
  }
  await tester.tap(finder);
  await settlePhotoMedia(tester);
}

/// 等 `PageView` 的翻页过渡**真的落定**（旧页被拆掉）之后再做断言。
///
/// 为什么 [settlePhotoMedia]（10×50ms）不够：`PageScrollPhysics` 的落定是
/// **弹簧**仿真，实测要把 `page` 收敛到整数值需要 ~800–1000ms 的模拟时间；
/// 500ms 时 `page == 0.982` —— `onPageChanged` **早就触发了**（`page == 0.83`
/// 时就触发，播放态已清），但旧页**仍在树里**，于是"旧页上的 key 应该消失"
/// 这类断言会**假失败**（诊断数据见 P13 查看器接线报告）。
Future<void> settlePhotoMediaPager(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    final finder = find.byType(PageView);
    if (finder.evaluate().isEmpty) return;
    final controller = tester.widget<PageView>(finder.first).controller;
    if (controller != null &&
        controller.hasClients &&
        !controller.position.isScrollingNotifier.value) {
      return;
    }
  }
}

/// 某个 `api.method` 被调用了几次。
int photoMediaCallCount(FakeTransport t, String key) =>
    t.calls.where((c) => '${c['api']}.${c['method']}' == key).length;

/// 最后一次某个 `api.method` 的请求参数。
Map<String, dynamic> photoMediaLastCall(FakeTransport t, String key) =>
    t.calls.lastWhere((c) => '${c['api']}.${c['method']}' == key);

/// 从请求 URL 里取查询参数（`Streaming` 的直链是拼在 URL 上的，不在 `calls` 里）。
Map<String, String> queryOf(String url) {
  final uri = Uri.parse(url);
  return {for (final e in uri.queryParameters.entries) e.key: e.value};
}

/// 便捷：把条目 map 变成 DTO。
List<FotoItemDto> photoMediaItems(List<Map<String, dynamic>> raw) => [
  for (final j in raw) FotoItemDto.fromJson(j),
];
