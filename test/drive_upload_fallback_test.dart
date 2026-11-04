// ★★ r371（DA13）：**Drive 源「上传文件」的通道回落**。
//
// 真机事实（r359，DA13）：Drive 源 FAB → `Upload file` 上传本机文件
// **必失败**，提示条原文是裸码 `Error code 1003`（Drive 的 `Files/upload`），
// 文件从不落盘；而**同一账号、同一目标目录、同一文件**走 FileStation
// （Files 源）上传 2/2 成功，且 Drive 秒级索引到 `/mydrive/…`。
// ⇒ 账号/权限/路径都已被对照实验排除，问题在 Drive 原生上传通道本身；
//   根因本轮仍未在服务端侧钉死（见缺陷表 DA13 的留白）。
//
// 本轮的处理：个人空间（能词法映射出 `/home/Drive/…`）**退回那条已验证可用的
// FileStation 通道**，并把 Drive 的原始错误码带进埋点 detail（`via`）；
// 团队/共享空间映射不出 DSM 路径时**不假装能用**，照原样把错误抛给界面。
//
// 本文件三条判据（缺一不可）：
//   ① Drive 上传失败 + 个人空间 ⇒ 真的发了 FileStation 上传（路径 `/home/Drive`）；
//   ② 反向：Drive 上传**没失败**时 ⇒ **不许**多发一次 FileStation 上传
//      （证明回落是"失败才走"，不是无条件走）；
//   ③ 反向：团队文件夹（映射不出 `/home/Drive`）⇒ 不回落、明确报错。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/drive_browse_view.dart';
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_upload_picker.dart';

import 'support/chat_harness.dart';

/// 能力表：Drive `Files` 与 FileStation `Upload` 的版本区间。
/// 缺了它们，协商会退回"服务端没声明"的分支 —— 用例就测不到真实报文。
const _apiTable = <String, Map<String, dynamic>>{
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.FileStation.Upload': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

const _probeName = 'r371_probe.txt';

/// `Files/get` 的响应：**必须回 `file_id`**，否则 `pathId` 是 `id:`（长度 3）
/// 会被上层判成"解析失败"而**绕过 Drive 通道**，用例就测不到回落。
Map<String, dynamic> _getFixture() => {
  'file_id': '123',
  'name': _probeName,
  'type': 'file',
  'path': '/mydrive/$_probeName',
  'display_path': '/mydrive/$_probeName',
  'size': 4,
  'isdir': false,
};

class _Host extends StatelessWidget {
  const _Host({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.dark(),
    locale: const Locale('zh'),
    localizationsDelegates: const [
      AppText.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: AppText.supportedLocales,
    home: Scaffold(
      body: Consumer(
        builder: (ctx, ref, _) => ElevatedButton(
          onPressed: () => driveUploadToCurrent(ctx, ref, path),
          child: const Text('go-upload'),
        ),
      ),
    ),
  );
}

void main() {
  late Directory tmp;
  late File local;
  late FakeTransport transport;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r371_up');
    local = File('${tmp.path}/$_probeName')..writeAsStringSync('abcd');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 起一个带假传输的壳，并打开上传入口。
  ///
  /// ★ 刻意**不用 `bootChat`**：它建的是聊天会话，`sessionControllerProvider` 的
  /// `connection` 仍是 null ⇒ `driveApiProvider` / `fileApiProvider` 都是 null，
  /// 被测函数会走"未连接"的早退分支（第一版就是这么假绿的）。
  /// 直接覆盖这两个 provider，拿到的 API 就在同一个假传输上。
  Future<ProviderContainer> pumpUpload(
    WidgetTester tester, {
    required String drivePath,
    required bool driveUploadFails,
  }) async {
    final t = FakeTransport({
      'SYNO.SynologyDrive.Files.get': _getFixture(),
    }, {...FakeTransport.table, ..._apiTable});
    transport = t;
    if (driveUploadFails) {
      t.failures['SYNO.SynologyDrive.Files.upload'] = 1003;
    }
    final api = DsmWebApi(t);
    await api.discover();
    await api.login(account: 'a', password: 'b');
    final c = ProviderContainer(
      overrides: [
        driveApiProvider.overrideWithValue(DriveApi(api)),
        fileApiProvider.overrideWithValue(FileStationApi(api)),
        fileUploadPickerProvider.overrideWithValue(
          () async => PickedUploadFile(
            path: local.path,
            name: _probeName,
            size: 4,
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: _Host(path: drivePath),
      ),
    );
    await tester.tap(find.text('go-upload'));
    await tester.pump();
    // ★ 必须 `runAsync`：FileStation 的上传先 `await File(...).length()`
    //    ——**真实文件 I/O 在假时钟下永远不会完成**（第一版就是因此才看到
    //   "Drive 试过了、回落没发生"：其实回落已经在跑，只是卡在 I/O 上）。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    // 上传进度框里有转圈动画 ⇒ 不能用 pumpAndSettle（会等动画超时）
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return c;
  }

  /// 被测容器用的假传输（由 `pumpUpload` 赋值；同一个测试内顺序执行）。
  /// ★ 局部**函数**而不是 getter —— Dart 的局部作用域里不允许声明 getter。
  List<Map<String, dynamic>> calls() => transport.calls;

  bool sentFileStationUpload() => calls().any(
    (c) => '${c['api']}' == 'SYNO.FileStation.Upload',
  );

  testWidgets('★★ ① Drive 上传失败（1003）⇒ 个人空间退回 FileStation 且成功', (tester) async {
    await pumpUpload(tester, drivePath: '/mydrive', driveUploadFails: true);

    // Drive 通道确实**试过**（不是直接跳过）
    expect(
      calls().any((c) => '${c['api']}' == 'SYNO.SynologyDrive.Files'),
      isTrue,
      reason: '先该走 Drive 原生上传，失败后才回落',
    );
    expect(sentFileStationUpload(), isTrue, reason: '★★ 回落必须真的发出去');
    final up = calls().lastWhere(
      (c) => '${c['api']}' == 'SYNO.FileStation.Upload',
    );
    expect(up['path'], '/home/Drive', reason: '个人空间的 FileStation 落点');
    expect(up['file_name'], _probeName);
  });

  testWidgets('★★ ② 反向：Drive 上传成功时**不发** FileStation（回落是有条件的）', (tester) async {
    await pumpUpload(tester, drivePath: '/mydrive', driveUploadFails: false);
    expect(
      sentFileStationUpload(),
      isFalse,
      reason: '★ 无条件回落 = 每次都多传一遍，这条防的就是它',
    );
  });

  testWidgets('★★ ③ 反向：团队文件夹（映射不出 /home/Drive）⇒ 不回落、明确报错', (tester) async {
    await pumpUpload(
      tester,
      drivePath: '/team_folder/abc',
      driveUploadFails: true,
    );
    expect(
      sentFileStationUpload(),
      isFalse,
      reason: '团队空间没有 FileStation 落点 ⇒ 不许假装能传',
    );
    // 界面给出的是**人话**（describeFileError 的 1003 文案），不是裸码
    expect(find.textContaining('1003'), findsNothing);
    expect(find.textContaining('目标位置不存在'), findsOneWidget);
  });
}
