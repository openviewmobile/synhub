// r424 · 视频二级面板探针的**宿主侧**（跑法 = `flutter test tool/…`，仪器91：
// 不放进 `test/` ⇒ 不会被全量闸门② 收走，缺凭据也不会让闸门红）。
//
// 目的：给真机造两条**异容器 / 双音轨 / 异显示比例**的样本，验
//   ① §4.1-3 `Aspect ratio` / `Audio track` 二级面板（真机点选）
//   ② §4.1-1 非 mp4/mkv/avi 容器的缩略图/抽帧表现
//
// 阶段（`--dart-define=STAGE=`）：
//   up    建 `/home/r424probe` ＋ 上传两条样本（**写动词**）
//   list  只读回读（名字/大小/时间）
//   down  删掉 `/home/r424probe`（**当轮还原**）＋ 回读确认已消失
//
// 凭据只走 `--dart-define`（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   export PATH="<flutter-sdk>/bin:$PATH"
//   flutter test tool/r424_video_probe_test.dart --dart-define=STAGE=up \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD"
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String stage = String.fromEnvironment('STAGE', defaultValue: 'list');
const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const String localDir = String.fromEnvironment(
  'LOCAL_DIR',
  defaultValue: '/tmp/r424probe',
);
const String probeDir = '/home/r424probe';
const List<String> samples = ['r424probe2a.mov', 'r424probe2b.webm'];

Future<DsmWebApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(
      url,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'FileStation');
  print('[r424] 已登录 $url as $account（sid 前缀 '
      '${api.session!.sid.substring(0, 6)}…）');
  return api;
}

Future<void> dumpList(FileStationApi fs) async {
  final res = await fs.listFolder(folderPath: probeDir);
  if (res.entries.isEmpty) {
    print('[r424] list $probeDir ⇒ **空/不存在**');
  }
  for (final f in res.entries) {
    print('[r424] list  ${f.name}  ${f.size}B  ${f.mtime}  dir=${f.isDir}');
  }
}

void main() {
  test('r424 视频样本探针', () async {
    if (url.isEmpty || account.isEmpty || password.isEmpty) {
      fail('缺 NAS_URL/NAS_ACCOUNT/NAS_PASSWORD（只从 --dart-define 来）');
    }
    final api = await connect();
    final fs = FileStationApi(api);

    switch (stage) {
      case 'up':
        // 幂等：先清掉同名目录（上一轮残留也要清）
        try {
          await fs.deleteItems([probeDir], recursive: true);
        } catch (e) {
          print('[r424] 预清理（可忽略）: $e');
        }
        await fs.createFolder(folderPath: '/home', name: 'r424probe');
        print('[r424] 已建 $probeDir');
        for (final name in samples) {
          final local = '$localDir/$name';
          final size = await File(local).length();
          final t0 = DateTime.now();
          await fs.upload(
            folderPath: probeDir,
            filePath: local,
            fileName: name,
            conflict: UploadConflictPolicy.overwrite,
          );
          final ms = DateTime.now().difference(t0).inMilliseconds;
          print('[r424] 上传 $name  ${size}B  ${ms}ms');
        }
        await dumpList(fs);
      case 'list':
        await dumpList(fs);
      case 'down':
        await fs.deleteItems([probeDir], recursive: true);
        print('[r424] 已发删除 $probeDir');
        // 回读：目录不应再在 /home 列表里
        final home = await fs.listFolder(folderPath: '/home');
        final hit =
            home.entries.where((f) => f.name == 'r424probe').toList();
        print('[r424] 回读 /home 里 r424probe 条目数 = ${hit.length}（期望 0）');
      default:
        fail('未知 STAGE=$stage');
    }
    await api.logout();
    print('[r424] 已登出（stage=$stage 收尾）');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
