// Download Station（阶段二 A 第一块）真机探针。
//
//   # 1) 匿名能力探测（不需要账号）：这台 NAS 装没装 Download Station
//   SYNO_NAS_URL=https://<nas>:<port> dart run tool/ds_probe.dart info
//
//   # 2) 真机功能往返（需要账号；会建一个测试任务，跑完自己删掉）
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/ds_probe.dart probe
//
//   # 3) 只清理探针留下的测试任务
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/ds_probe.dart clean
//
// 事实来源：`docs/stage2-audio-download-api.md`（SPK 4.1.2-5012 离线取证）。
// 探针只打**普通用户**方法（`Task.list/get/create/pause/resume/delete`、
// `Task.BT.get/set`、`Task.Statistic.get`、`Settings.Location.get`），
// 一个 admin-only 都不碰。
//
// ⚠️ 本探针是"核事实用"的：所有请求都打印实际发出的参数与回包形状，
// 以便把文档 §5 的不确定项（U2/U7/U12/U14）在真机上定案。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/dto/download_task_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// 探针建的测试任务标题（clean 按它删）。
const probeTitle = 'ds-probe-test';

Future<DsmWebApi> login() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'DownloadStation',
  );
  return api;
}

/// 匿名探测：只读 `SYNO.API.Info`（不需要登录）。
Future<void> info() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  final table = await api.discover();
  print('API 总数：${table.length}');
  final ds = table.keys.where((k) => k.contains('DownloadStation')).toList()
    ..sort();
  print('DownloadStation 相关 API：${ds.length}');
  for (final k in ds) {
    final e = table[k]!;
    print('  $k  v${e.minVersion}..${e.maxVersion}  path=${e.path}');
  }
  if (ds.isEmpty) {
    print('结论：这台 NAS **没有安装** Download Station（普通用户功能无法真机验证）');
    return;
  }
  // §5 U4/U12：新旧两代是否都被注册、注册 path 是不是 entry.cgi
  for (final name in [
    DownloadStationApi.apiTask,
    'SYNO.DownloadStation.Task',
  ]) {
    final e = table[name];
    print(
      '  $name → ${e == null ? '未注册' : 'v${e.minVersion}..${e.maxVersion} @ ${e.path}'}',
    );
  }
}

Future<void> probe() async {
  final api = await login();
  final ds = DownloadStationApi(api);
  print('installed=${ds.installed}');
  final dest = await _tryPrint('Settings.Location.get', () async {
    final d = await ds.defaultDestination();
    print('  default_destination=$d');
    return d;
  });
  print('--- list（第一页，含 status/type 过滤）');
  final page = await ds.listTasks(limit: 5);
  print('  total=${page.total} 本页=${page.items.length}');
  for (final t in page.items) {
    print(
      '  #${t.id} ${t.title} type=${t.type} status=${t.status} '
      'progress=${(t.progress * 100).toStringAsFixed(1)}% ${t.detail.destination}',
    );
  }
  print('--- statistic');
  final stat = await ds.statistic();
  print('  down=${stat.downloadRate}B/s up=${stat.uploadRate}B/s');
  print('--- create（磁力，一个绝不存在的 infohash）');
  try {
    final r = await ds.createUrlTask(
      urls: const [
        'magnet:?xt=urn:btih:0000000000000000000000000000000000000000'
            '&dn=$probeTitle',
      ],
      destination: (dest ?? '').isEmpty ? null : dest,
    );
    print('  create ok list_id=${r.listId}');
  } catch (e) {
    print('  create 失败：${describeDownloadError(e)}');
  }
  print('--- 找刚才建的测试任务');
  final after = await ds.listTasks(keyword: probeTitle, limit: 10);
  final mine = after.items.where((t) => t.title.contains(probeTitle)).toList();
  print('  命中 ${mine.length} 条');
  for (final t in mine) {
    print('  #${t.id} status=${t.status}');
    print('--- pause / resume');
    await _tryPrint('pause', () async => ds.pauseTasks([t.id]));
    await _tryPrint('resume', () async => ds.resumeTasks([t.id]));
    if (t.isBt) {
      print('--- Task.BT.get / set（单任务限速，normal）');
      await _tryPrint('BT.get', () async {
        final s = await ds.getBtSettings(t.id);
        print(
          '  max_up=${s.maxUploadRate} max_down=${s.maxDownloadRate} '
          'peers=${s.maxPeers} ratio=${s.seedingRatio}',
        );
        return s;
      });
      await _tryPrint('BT.set', () async {
        await ds.setBtSettings(
          t.id,
          const DownloadBtSettings(maxDownloadRate: 128, maxUploadRate: 64),
        );
      });
    }
    print('--- delete（连带文件，服务端行为；跑完不留垃圾）');
    await _tryPrint('delete', () async => ds.deleteTasks([t.id]));
  }
  if (mine.isEmpty) {
    print('提示：没找到测试任务——create 可能被拒（看上面的错误码），或磁力被服务端忽略。');
  }
}

Future<void> clean() async {
  final api = await login();
  final ds = DownloadStationApi(api);
  final page = await ds.listTasks(keyword: probeTitle, limit: 50);
  final mine = page.items.where((t) => t.title.contains(probeTitle)).toList();
  if (mine.isEmpty) {
    print('没有需要清理的测试任务。');
    return;
  }
  await ds.deleteTasks([for (final t in mine) t.id]);
  print('已删除 ${mine.length} 条测试任务。');
}

Future<T?> _tryPrint<T>(String what, Future<T> Function() run) async {
  try {
    final v = await run();
    print('  ✔ $what');
    return v;
  } catch (e) {
    print('  ✘ $what → ${describeDownloadError(e)}');
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
    case 'clean':
      await clean();
    default:
      stderr.writeln('用法: dart run tool/ds_probe.dart [info|probe|clean]');
      exitCode = 2;
  }
}
