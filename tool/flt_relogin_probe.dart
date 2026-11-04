// 探针：真机/真服务端上验证"会话过期自动重登"的机制。
//
//   SYNO_NAS_URL=… SYNO_NAS_ACCOUNT=… SYNO_NAS_PASSWORD=… \
//     dart run tool/flt_relogin_probe.dart
//
// 步骤：
//   ① 正常登录 → 调一个认证接口（通）；
//   ② 用**同一个 sid** 调 `SYNO.API.Auth / logout`（session=Chat）把它废掉；
//   ③ 再用旧 sid 调同一个接口 → 应当拿到 119（sid 不存在）；
//   ④ 装上 `onSessionExpired`（内部重新 login）→ 再调一次 → 应当**自动成功**，
//      且 sid 已经换新。
//
// 这一步是为了证明"逼出 119"的手法有效，后面真机用例（integration_test）才靠它。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final url = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password = Platform.environment['SYNO_NAS_PASSWORD']!;

  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  final s1 = await api.login(
    account: account,
    password: password,
    session: 'Chat',
  );
  print('① 登录 sid=${s1.sid.substring(0, 6)}…');
  final ch = await api.call('SYNO.Chat.Channel', 'list');
  print('① 认证调用 OK：channels=${(ch['channels'] as List?)?.length}');

  // ② 把它废掉：拿同一个 sid 走 logout（我们的 logout 默认 requiresAuth:false，
  //    所以这里手动带 _sid 调）
  try {
    await api.call(
      'SYNO.API.Auth',
      'logout',
      preferredVersion: 6,
      params: {'session': 'Chat'},
    );
    print('② logout（带 sid）已发出');
  } catch (e) {
    print('② logout 失败：$e');
  }

  // ③ 旧 sid 应当已经无效
  try {
    await api.call('SYNO.Chat.Channel', 'list');
    print('③ ⚠️ 旧 sid 仍然可用（服务端没作废？）');
  } on DsmApiException catch (e) {
    print('③ 旧 sid 已失效：code=${e.code}（${DsmErrorCode.describe(e.code)}）');
  }

  // ④ 装上自动重登 → 再调一次应当自动成功
  var relogins = 0;
  api.onSessionExpired = () async {
    relogins++;
    await api.login(account: account, password: password, session: 'Chat');
  };
  final ch2 = await api.call('SYNO.Chat.Channel', 'list');
  print(
    '④ 自动重登 relogins=$relogins sid=${api.session!.sid.substring(0, 6)}… '
    'channels=${(ch2['channels'] as List?)?.length}',
  );
  exit(0);
}
