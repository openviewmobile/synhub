// ignore_for_file: avoid_print
// 第 254 轮真机/真 NAS 只读探针：用**生产代码路径**验证"权限画像"。
//
// 目的：证明 `SessionEntitlement` 解析的是**真实** `Initdata` 响应
// （不是合成 fixture），并证明 `resolveIsAdmin()` 的结论来自画像，
// 且整条链**只**发 get（零变更动词）。
//
// 用法（凭据从 /tmp/nas_cred.env 来，不进仓库）：
//   set -a; . /tmp/nas_cred.env; set +a
//   SYNO_NAS_URL=https://nas.example.com:5001 \
//     dart run tool/session_entitlement_probe.dart
import 'dart:io';

import 'package:synhub/src/core/entitlement/session_entitlement.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/auth_extra_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final web = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await web.discover();
  await web.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'FileStation',
  );

  final api = AuthExtraApi(web);

  print('\n=== ① AuthExtraApi.sessionEntitlement()（生产解析器）');
  final ent = await api.sessionEntitlement();
  print('  ${ent.describe()}');
  print('  known=${ent.known} source=${ent.source}');
  print('  AppPrivilege 键数=${ent.appPrivilege.entries.length}');
  final denied = ent.appPrivilege.entries.entries
      .where((e) => !e.value)
      .map((e) => e.key)
      .toList();
  print('  明确拒绝(${denied.length}) = $denied');
  print('  通配键 allowAll=${ent.allowAllApps}');
  print('  ActionPrivilege 条数=${ent.actionAllowList.length} '
      '（空=不知道：allowsAction(...)=${ent.allowsAction('x')}）');
  print('  ServiceStatus 条数=${ent.serviceStatus.length}');
  print('  support_wol=${ent.supportWol} support_findme=${ent.supportFindme} '
      'hostname=${ent.hostname} serial=${ent.serialNumber}');

  print('\n=== ② 模块可见性（信号 1）抽查');
  for (final key in const [
    'SYNO.SDS.Chat.Application',
    'SYNO.SDS.App.FileStation3.Instance',
    'SYNO.SDS.NoteStation.Application',
    'SYNO.SDS.Drive.Application',
    'SYNO.SDS.NotInstalled.MadeUp',
  ]) {
    print('  allows($key)=${ent.allowsApp([key])} '
        'denied=${ent.deniedApp([key])}');
  }

  print('\n=== ③ 身份链结论（应当只打 Initdata/NormalUser）');
  print('  resolveIsAdmin()=${await api.resolveIsAdmin()}');
  print('  initDataCapability(support_wol)='
      '${await api.initDataCapability('support_wol')}');

  print('\n=== ④ 退化路径：形状为空时必须是 unavailable（不是"全拒"）');
  final empty = SessionEntitlement.fromInitdata(const {});
  print('  fromInitdata({}) => ${empty.describe()} known=${empty.known}');
  print('\n完成：全程只读（get）。');
}
