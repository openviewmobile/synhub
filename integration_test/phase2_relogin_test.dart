// Phase 2/9 真机验收：会话过期自动重登（原版 `RetryInterceptor`）。
//
//   flutter test integration_test/phase2_relogin_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_E2EE_PASSCODE=…
//
// 这条用例做的是**真的把 App 的会话在服务端废掉**，再看它自己能不能活过来：
//   ① 正常连上并登录（`SessionController` 会装上自动重登钩子）→ 实时通道 ready；
//   ② 拿**同一个 sid** 调 `SYNO.API.Auth / logout`（真机探针验证过：这样服务端
//      会把这条会话注销，紧接着用旧 sid 调接口就是 119）；
//   ③ 照常发一个认证请求（拉频道列表）→ 应当**自动重登 + 重放**，用户无感；
//   ④ sid 换新、实时通道用新 sid 重建（`restartRealtime`）；
//   ⑤ 收尾：再登出一次，别在 NAS 上留活会话。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

Future<void> _sleep(WidgetTester tester, int ms) =>
    tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 2 真机：会话被注销后自动重登并重放', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });

    // ---------- ① 连接 + 登录（走 SessionController，才会装钩子） ----------
    final session = container.read(sessionControllerProvider.notifier);
    final profile = const ServerProfile(
        kind: ServerAddressKind.quickConnect, value: _qc);
    expect(await session.connect(profile), isTrue);
    expect(await session.login(account: _account, password: _password), isTrue);

    final conn = container.read(sessionControllerProvider).connection!;
    final oldSid = container.read(sessionControllerProvider).session!.sid;
    debugPrint('[p2rl] ① 已登录 sid=${_short(oldSid)} '
        '钩子已装=${conn.api.onSessionExpired != null}');
    expect(conn.api.onSessionExpired, isNotNull);

    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);
    var sync = container.read(chatSessionControllerProvider);
    debugPrint('[p2rl] ① 实时通道 phase=${sync.phase.name} realtime=${sync.realtime}');
    expect(sync.realtime, isTrue, reason: '先要有一条活着的实时通道');

    // ---------- ② 把这条会话在服务端注销掉 ----------
    await conn.api.call('SYNO.API.Auth', 'logout',
        preferredVersion: 6, params: {'session': 'Chat'});
    debugPrint('[p2rl] ② 已用同一个 sid 调 logout（服务端应已注销它）');

    // 先确认旧 sid 真的死了。⚠️ 这里必须**绕过 `DsmWebApi.call`**：钩子装上
    // 之后任何认证请求都会自动愈合，那样就验不到"失效"这个前提了。所以直接
    // 拿旧 sid 打一次原始请求（真机第一次跑就是这么发现的：还没断言，日志里
    // 已经出现"会话过期已自动重登"）。
    final rawBody = await conn.api.transport.postForm(
      conn.api.apiPath('SYNO.Chat.Channel'),
      {
        'api': 'SYNO.Chat.Channel',
        'version': '1',
        'method': 'list',
        '_sid': oldSid,
      },
    );
    final rawJson = jsonDecode(rawBody) as Map;
    final rawCode = (rawJson['error'] as Map?)?['code'];
    debugPrint('[p2rl] ② 旧 sid 原始请求 → error=$rawCode');
    expect(rawCode, isNotNull,
        reason: '前提：旧 sid 必须已经失效，否则这条用例没验到东西');
    expect('$rawCode', '${DsmErrorCode.sidNotFound}');

    // ---------- ③ 照常发请求：应当自动重登 + 重放 ----------
    final api = ChatApi(conn.api);
    final channels = await api.listChannels();
    final newSid = container.read(sessionControllerProvider).session!.sid;
    debugPrint('[p2rl] ③ 重登后列表仍可用：channels=${channels.length} '
        'sid=${_short(oldSid)}→${_short(newSid)}');
    expect(channels, isNotEmpty, reason: '重放必须拿到真数据（用户无感）');
    expect(newSid, isNot(oldSid), reason: 'sid 必须换新');
    expect(container.read(sessionControllerProvider).error, isNull);

    // 新 sid 真的能用（直接再打一次认证接口）
    final users = await api.listUsers();
    expect(users, isNotEmpty);

    // ---------- ④ 实时通道用新 sid 重建 ----------
    var realtimeBack = false;
    for (var i = 0; i < 40; i++) {
      await _sleep(tester, 500);
      sync = container.read(chatSessionControllerProvider);
      if (sync.realtime) {
        realtimeBack = true;
        break;
      }
    }
    debugPrint('[p2rl] ④ 实时通道恢复=$realtimeBack '
        'phase=${sync.phase.name} status=${sync.socketStatus.name}');
    expect(realtimeBack, isTrue, reason: 'sid 换了之后实时通道必须用新 sid 重连上');

    // ---------- ⑤ 收尾：别在 NAS 上留活会话 ----------
    try {
      await conn.api.logout();
      debugPrint('[p2rl] ⑤ 已登出');
    } catch (e) {
      debugPrint('[p2rl] ⑤ 登出失败（忽略）：$e');
    }
    debugPrint('[p2rl] 完成 ✓');
  });
}

String _short(String sid) => sid.length > 6 ? '${sid.substring(0, 6)}…' : sid;
