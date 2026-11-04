// r405 探针：收藏（Pin）**写侧** —— 为了在真机上做「≥4 条长距离拖动」的
// 动作级验收，需要先在服务端准备 ≥4 条收藏；验完必须**还原成空**。
//
// 事实来源（载荷形态）：
//   * `Pin.pin` v1 —— 参数 `items` = 记录数组的 JSON
//     （`{type, criteria, name}`，见 `lib/src/data/audio_station.dart`
//      `AudioStationApi.addPins` / `AudioPinRequest.toJson`）；
//   * `Pin.unpin` v1 —— 参数 `items` = **id 数组**的 JSON（r398 真机定案）。
//
// 模式：
//   seed  <n>   取 n 个真实艺术家 → `Pin.pin` 建 n 条 → 打印 `Pin.list`
//   list        只读打印 `Pin.list`
//   clear       读出全部 id → `Pin.unpin` → 打印 `Pin.list`（应为空）
//
// ⚠️ 这是**用户库写动词**（收藏）。跑完必须 `clear`，并把终态与基线逐字对照。
//
// 运行：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/probe_r405_pins_write.dart <mode> [tag] [n]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

const _pin = 'SYNO.AudioStation.Pin';

Future<void> _readPin(DsmWebApi api, String tag) async {
  final raw = await api.call(_pin, 'list', params: {
    'offset': '0',
    'limit': '-1',
  });
  print('[$tag] Pin.list raw=${jsonEncode(raw)}');
  final items = raw['items'];
  print('[$tag] items=${items is List ? items.length : "非 List"} total=${raw['total']}');
}

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'list' : args.first;
  final tag = args.length > 1 ? args[1] : 'r405p';
  final n = args.length > 2 ? int.parse(args[2]) : 4;
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_PASSWORD'];
  if (base == null || account == null || password == null) {
    print('需要 SYNO_NAS_URL / SYNO_ACCOUNT / SYNO_PASSWORD');
    exit(2);
  }
  final api = DsmWebApi(
    DirectTransport.url(base, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');
  final audio = AudioStationApi(api);

  switch (mode) {
    case 'seed':
      // 取 n 个真实艺术家（这样"点收藏行"能打开真实详情页）。
      final artists = await api.call(
        'SYNO.AudioStation.Artist',
        'list',
        preferredVersion: 3,
        params: {'offset': '0', 'limit': '$n'},
      );
      final items = (artists['artists'] ?? artists['items']) as List?;
      final reqs = <AudioPinRequest>[];
      for (final e in items ?? const []) {
        if (e is Map && e['name'] != null) {
          final name = e['name'].toString();
          print('[$tag] 选中艺术家 $name');
          reqs.add(
            AudioPinRequest(type: 'artist', criteria: {'artist': name}, name: name),
          );
        }
      }
      print('[$tag] → Pin.pin items=${jsonEncode([for (final r in reqs) r.toJson()])}');
      await audio.addPins(reqs);
      await _readPin(api, tag);
    case 'list':
      await _readPin(api, tag);
    case 'clear':
      final raw = await api.call(_pin, 'list', params: {
        'offset': '0',
        'limit': '-1',
      });
      final items = (raw['items'] as List?) ?? const [];
      final ids = [
        for (final e in items)
          if (e is Map && e['id'] != null) e['id'].toString(),
      ];
      print('[$tag] 待清理 ids=$ids');
      if (ids.isEmpty) {
        print('[$tag] 没有可清理的（已是空）');
      } else {
        await audio.removePins(ids);
        print('[$tag] → Pin.unpin items=${jsonEncode(ids)}');
      }
      await _readPin(api, tag);
    default:
      print('未知 mode：$mode（可选 seed / list / clear）');
  }
  await api.logout(session: 'AudioStation');
  exit(0);
}
