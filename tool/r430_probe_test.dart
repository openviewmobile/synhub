// r430 · 宿主侧探针（**只读 + 自建探针目录内的写动词**，仪器91：放 `tool/` 不进闸门②）。
//
// 目的：把 `docs/android-remaining-todo-r418.md` §一 第 5 条那个"**未定性**"的观察项
//   ——「新上传/被覆盖的文件，Files 列表仍显示旧尺寸/时间，下拉刷新与重进目录都不刷新」
//   —— 先在地上（宿主 → 真 NAS）分清**是谁陈旧**：
//     ① 服务端 `List` 在覆盖后回的是**新**值还是**旧**值？（同一个 `List` 立刻再问一次）
//     ② `List.getinfo`（fresh stat）与 `List.list` 是否**打架**？
//     ③ 隔一段时间再问，`list` 会不会自己变新？（判"是缓存还是滞后"）
//
// 阶段（`--dart-define=STAGE=`）：
//   up    建 `/home/r430probe` ＋ 上传 v1（2048 B）＋ list
//   over  用 v2（7168 B）**同名覆盖** ⇒ 立刻 list ＋ getinfo ＋ 隔 3/10/30 s 再 list（各打印）
//   walk  只读：目录里每个文件的 `list` 值 vs `getinfo` 值逐条对比（找"两把尺子打架"）
//   down  删 `/home/r430probe`（**当轮还原**）＋ 回读 `/home` 确认 0 条
//
// 凭据只走 `--dart-define`（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   export PATH="<flutter-sdk>/bin:$PATH"
//   flutter test tool/r430_probe_test.dart --dart-define=STAGE=up \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD"
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String stage = String.fromEnvironment('STAGE', defaultValue: 'walk');
const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const String localDir = String.fromEnvironment(
  'LOCAL_DIR',
  defaultValue: '/tmp/r430',
);
const String probeDir = String.fromEnvironment(
  'PROBE_DIR',
  defaultValue: '/home/r430probe',
);
const String sampleName = String.fromEnvironment(
  'SAMPLE',
  defaultValue: 'r430probeA.bin',
);

Future<DsmWebApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'FileStation');
  print('[r430] 已登录 $url as $account（sid 前缀 '
      '${api.session!.sid.substring(0, 6)}…）');
  return api;
}

/// `list` 口径的一行读数（**尺寸 + mtime 秒**）。
Future<String> listLine(FileStationApi fs, String path) async {
  final res = await fs.listFolder(folderPath: path);
  final hit = res.entries.where((e) => e.name == sampleName).toList();
  if (hit.isEmpty) return '（$sampleName 不在 list 里）';
  final e = hit.first;
  return 'list  ⇒ size=${e.size}  mtime=${e.mtime}';
}

Future<String> infoLine(FileStationApi fs, String path) async {
  try {
    final e = await fs.getInfo('$path/$sampleName');
    return 'getinfo ⇒ size=${e.size}  mtime=${e.mtime}';
  } catch (err) {
    return 'getinfo ⇒ 失败: $err';
  }
}

Future<void> stamp(FileStationApi fs, String path, String tag) async {
  print('[r430][$tag] ${await listLine(fs, path)}');
  print('[r430][$tag] ${await infoLine(fs, path)}');
}

void main() {
  test('r430 列表元数据陈旧性探针', () async {
    if (url.isEmpty || account.isEmpty || password.isEmpty) {
      fail('缺 NAS_URL/NAS_ACCOUNT/NAS_PASSWORD（只从 --dart-define 来）');
    }
    final api = await connect();
    final fs = FileStationApi(api);

    switch (stage) {
      case 'up':
        try {
          await fs.deleteItems([probeDir], recursive: true);
        } catch (e) {
          print('[r430] 预清理（可忽略）: $e');
        }
        final base = probeDir.split('/').last;
        await fs.createFolder(folderPath: '/home', name: base);
        print('[r430] 已建 $probeDir');
        final v1 = File('$localDir/v1.bin');
        print('[r430] 本地 v1 = ${await v1.length()}B');
        await fs.upload(
          folderPath: probeDir,
          filePath: v1.path,
          fileName: sampleName,
          conflict: UploadConflictPolicy.overwrite,
        );
        await stamp(fs, probeDir, 'up/v1');
      case 'over':
        final v2 = File('$localDir/v2.bin');
        print('[r430] 本地 v2 = ${await v2.length()}B ⇒ 同名覆盖 $sampleName');
        await fs.upload(
          folderPath: probeDir,
          filePath: v2.path,
          fileName: sampleName,
          conflict: UploadConflictPolicy.overwrite,
        );
        await stamp(fs, probeDir, 'over/t+0');
        for (final wait in [3, 10, 30]) {
          await Future<void>.delayed(Duration(seconds: wait));
          await stamp(fs, probeDir, 'over/t+$wait');
        }
      case 'tall':
        // 大列表样本：20 个 1 KB 文件 ⇒ 列表高度超过一屏（可滚动）
        try {
          await fs.deleteItems([probeDir], recursive: true);
        } catch (e) {
          print('[r430] 预清理（可忽略）: $e');
        }
        final base = probeDir.split('/').last;
        await fs.createFolder(folderPath: '/home', name: base);
        for (var i = 0; i < 20; i++) {
          final local = File('$localDir/f$i.bin');
          await fs.upload(
            folderPath: probeDir,
            filePath: local.path,
            fileName: 'f${i.toString().padLeft(2, '0')}.bin',
            conflict: UploadConflictPolicy.overwrite,
          );
        }
        print('[r430] 已建 $probeDir ＋ 20×1 KB');
        final res0 = await fs.listFolder(folderPath: probeDir);
        print('[r430] list 条目数 = ${res0.entries.length}');
      case 'big':
        final v3 = File('$localDir/v3.bin');
        print('[r430] 本地 v3 = ${await v3.length()}B ⇒ 同名覆盖 $sampleName');
        await fs.upload(
          folderPath: probeDir,
          filePath: v3.path,
          fileName: sampleName,
          conflict: UploadConflictPolicy.overwrite,
        );
        await stamp(fs, probeDir, 'big/t+0');
      case 'walk':
        final res = await fs.listFolder(folderPath: probeDir);
        print('[r430] list 条目数 = ${res.entries.length}');
        for (final e in res.entries) {
          final info = await fs.getInfo('$probeDir/${e.name}');
          final same = e.size == info.size && e.mtime == info.mtime;
          print(
            '[r430] ${e.name}\n'
            '        list    size=${e.size} mtime=${e.mtime}\n'
            '        getinfo size=${info.size} mtime=${info.mtime}\n'
            '        ⇒ ${same ? "一致" : "★打架"}',
          );
        }
      case 'down':
        await fs.deleteItems([probeDir], recursive: true);
        print('[r430] 已发删除 $probeDir');
        final base = probeDir.split('/').last;
        final home = await fs.listFolder(folderPath: '/home');
        final hit = home.entries.where((f) => f.name == base).toList();
        print('[r430] 回读 /home 里 $base 条目数 = ${hit.length}（期望 0）');
      default:
        fail('未知 STAGE=$stage');
    }
    await api.logout();
    print('[r430] 已登出（stage=$stage 收尾）');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
