// r426 · §5-15「照片地图瓦片」真机验证的**宿主侧**（跑法 = `flutter test tool/…`，
// 仪器91：不放进 `test/` ⇒ 不会被全量闸门② 收走，缺凭据也不会让闸门红）。
//
// 目的：地图页只在 `items` 非空时才画地图（`photo_map_page.dart` 的 `items.isEmpty`
// 分支），而 `items` = `Browse.Item/list + additional=[...,"gps"]` 里**有坐标**的条目。
// 所以真机验证的**前提**是：NAS 的 Photos 索引器能从照片 EXIF 里解出 GPS。
// 本探针就是来造这个前提并**回读**它：
//   ① 建 `/home/Photos/r426probe`（个人空间根，`FotoSpace.personal` ⇒ `SYNO.Foto.`）
//   ② 上传自造样本 `r426_gps.jpg`（EXIF GPS = N 31.2304 / E 121.4737，见台账 §S2）
//   ③ 用**和 App 同一条代码路径**（`FotoApi.timeline`，`kFotoItemAdditional`）回读，
//      逐条打印是否有 `gps`（键存在性，不是数值 0）＋ 打印经纬度
//   ④ `down` 阶段删掉探针目录并回读确认（当轮还原）
//
// 阶段（`--dart-define=STAGE=`）：`up` | `check` | `down`
// 凭据只走 `--dart-define`（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   export PATH="<flutter-sdk>/bin:$PATH"
//   flutter test tool/r426_map_probe_test.dart --dart-define=STAGE=up \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD"
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String stage = String.fromEnvironment('STAGE', defaultValue: 'check');
const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const String localFile = String.fromEnvironment(
  'LOCAL_FILE',
  defaultValue: '/tmp/r426/r426_gps.jpg',
);
const String probeDir = '/home/Photos/r426probe';
const String sampleName = 'r426_gps.jpg';

Future<DsmWebApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'FileStation');
  print('[r426] 已登录 $url as $account（sid 前缀 '
      '${api.session!.sid.substring(0, 6)}…）');
  return api;
}

/// 与 App 的地图页**同一条路径**：`FotoApi.timeline`（`additional` = `kFotoItemAdditional`）。
Future<void> dumpGeotagged(FotoApi foto) async {
  final items = await foto.timeline(limit: 200);
  print('[r426] Browse.Item/list ⇒ ${items.length} 条（个人空间时间轴）');
  var withGps = 0;
  for (final it in items) {
    if (!it.hasGps) continue;
    withGps++;
    print('[r426] gps  ${it.filename}  id=${it.id}  '
        'lat=${it.gps!.latitude}  lon=${it.gps!.longitude}  '
        'time=${it.time}');
  }
  print('[r426] 其中**有 GPS** 的条目 = $withGps（地图页只画这些）');
}

void main() {
  test('r426 地图瓦片前提探针', () async {
    if (url.isEmpty || account.isEmpty || password.isEmpty) {
      fail('缺 NAS_URL/NAS_ACCOUNT/NAS_PASSWORD（只从 --dart-define 来）');
    }
    final api = await connect();
    final fs = FileStationApi(api);
    final foto = FotoApi(api);

    switch (stage) {
      case 'up':
        try {
          await fs.deleteItems([probeDir], recursive: true);
        } catch (e) {
          print('[r426] 预清理（可忽略）: $e');
        }
        // Photos 个人空间的物理根 = 用户 home 下的 `Photos`
        await fs.createFolder(folderPath: '/home/Photos', name: 'r426probe');
        print('[r426] 已建 $probeDir');
        final size = await File(localFile).length();
        await fs.upload(
          folderPath: probeDir,
          filePath: localFile,
          fileName: sampleName,
          conflict: UploadConflictPolicy.overwrite,
        );
        print('[r426] 上传 $sampleName  ${size}B');
        final res = await fs.listFolder(folderPath: probeDir);
        for (final f in res.entries) {
          print('[r426] list  ${f.name}  ${f.size}B  dir=${f.isDir}');
        }
        await dumpGeotagged(foto);
      case 'check':
        await dumpGeotagged(foto);
      case 'down':
        await fs.deleteItems([probeDir], recursive: true);
        print('[r426] 已发删除 $probeDir');
        final parent = await fs.listFolder(folderPath: '/home/Photos');
        final hit = parent.entries.where((f) => f.name == 'r426probe').length;
        print('[r426] 回读 /home/Photos 里 r426probe 条目数 = $hit（期望 0）');
      default:
        fail('未知 STAGE=$stage');
    }
    await api.logout();
    print('[r426] 已登出（stage=$stage 收尾）');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
