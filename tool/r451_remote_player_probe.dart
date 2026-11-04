// r451 只读探针（不写任何数据）：确认 ⑥-B「DLNA 正支」的权威条件是否仍不可得。
//  ① `SYNO.AudioStation.Info::getinfo` v6 → 账号画像里的 `privilege.remote_player`
//     与 `settings.disable_upnp`（UPnP 总开关，管理员级设置）
//  ② `SYNO.AudioStation.RemotePlayer::list` v3 → 当前可见渲染器数量
// 两个都是**只读**动词；本探针不调用任何 set/delete/create/update。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(DirectTransport.url(Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true)));
  await api.discover();
  await api.login(
      account: Platform.environment['SYNO_NAS_ACCOUNT']!,
      password: Platform.environment['SYNO_NAS_PASSWORD']!,
      session: 'AudioStation');
  final info = await api.call('SYNO.AudioStation.Info', 'getinfo', preferredVersion: 6);
  print('info keys=${info.keys.toList()}');
  print('  settings.disable_upnp=${(info['settings'] as Map?)?['disable_upnp']}');
  print('  privilege=${jsonEncode(info['privilege'])}');
  // ★ r457 加印：官方包版本 + 本账号是不是管理员 + 三个旁证位（都只读）。
  //   用途：用户问「在哪儿勾、是不是普通用户没这功能」时，先钉死**他看到的是哪个版本的 UI**。
  print('  version_string=${info['version_string']} version=${info['version']}');
  print('  is_manager=${info['is_manager']} remote_controller=${info['remote_controller']} '
      'same_subnet=${info['same_subnet']} support_usb=${info['support_usb']}');
  final players = await api.call('SYNO.AudioStation.RemotePlayer', 'list', preferredVersion: 3);
  final list = (players['players'] as List?) ?? const [];
  print('remoteplayer.list players=${list.length} raw=${jsonEncode(players)}');
  await api.logout();
  print('logout ok（只读探针结束）');
}
