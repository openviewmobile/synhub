// r431 · 宿主侧探针（**自建探针目录内的写动词 + 只读**，仪器91：放 `tool/` 不进闸门②）。
//
// 目的：给「视频播放器二级面板」那三条**缺样本**的保留项造素材（
//   `docs/android-remaining-todo-r418.md` §二点八 第 2/3/4 条）＋ 顺带覆盖
//   "非 mp4/mkv/avi 容器"这一条：
//     ① `r431_noaudio.mp4`  —— 纯视频（无音轨）⇒ 音轨面板的**空列表分支**（`mediaNoTracks`）
//     ② `r431_lang.mp4`     —— 双音轨，容器 `mdhd` 真写 `eng` / `jpn` ⇒ 语言标签显示
//     ③ `r431_webm.webm`    —— VP8 + Opus（非 mp4/mkv/avi 容器）
//     ④ `r431_mov.mov`      —— QuickTime（非 mp4/mkv/avi 容器）
//
// 阶段（`--dart-define=STAGE=`）：
//   up    建 `/home/r431probe` ＋ 上传 4 个样本 ＋ list 读数（尺寸/mtime）
//   walk  只读：`list` 与 `getinfo` 逐条对比（两把尺子）
//   down  删 `/home/r431probe`（**当轮还原**）＋ 回读 `/home` 确认残留 0
//
// 凭据只走 `--dart-define`（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   export PATH="<flutter-sdk>/bin:$PATH"
//   flutter test tool/r431_probe_test.dart --dart-define=STAGE=up \
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
  defaultValue: '/tmp/r431',
);
const String probeDir = String.fromEnvironment(
  'PROBE_DIR',
  defaultValue: '/home/r431probe',
);

const List<String> samples = [
  'r431_noaudio.mp4',
  'r431_lang.mp4',
  'r431_webm.webm',
  'r431_mov.mov',
];

Future<DsmWebApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'FileStation');
  print('[r431] 已登录 $url as $account（sid 前缀 '
      '${api.session!.sid.substring(0, 6)}…）');
  return api;
}

Future<void> readBack(FileStationApi fs, String tag) async {
  final res = await fs.listFolder(folderPath: probeDir);
  print('[r431][$tag] list 条目数 = ${res.entries.length}');
  for (final e in res.entries) {
    print('[r431][$tag] ${e.name}  size=${e.size}  mtime=${e.mtime}');
  }
}

void main() {
  test('r431 视频二级面板素材探针', () async {
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
          print('[r431] 预清理（可忽略）: $e');
        }
        final base = probeDir.split('/').last;
        await fs.createFolder(folderPath: '/home', name: base);
        print('[r431] 已建 $probeDir');
        for (final name in samples) {
          final local = File('$localDir/$name');
          final len = await local.length();
          print('[r431] 本地 $name = ${len}B ⇒ 上传');
          await fs.upload(
            folderPath: probeDir,
            filePath: local.path,
            fileName: name,
            conflict: UploadConflictPolicy.overwrite,
          );
        }
        await readBack(fs, 'up');
      case 'up2':
        // 只上传两条**长样本**（180 s）：真机上"开面板"的动作链要 8–15 s，
        // 30 s 的样本会在动作中途自动续播到下一集（r431 真机踩到）。
        for (final name in const ['r431_noaudio180.mp4', 'r431_lang180.mp4']) {
          final local = File('$localDir/$name');
          print('[r431] 本地 $name = ${await local.length()}B ⇒ 上传');
          await fs.upload(
            folderPath: probeDir,
            filePath: local.path,
            fileName: name,
            conflict: UploadConflictPolicy.overwrite,
          );
        }
        await readBack(fs, 'up2');
      case 'walk':
        final res = await fs.listFolder(folderPath: probeDir);
        print('[r431] list 条目数 = ${res.entries.length}');
        for (final e in res.entries) {
          final info = await fs.getInfo('$probeDir/${e.name}');
          final same = e.size == info.size && e.mtime == info.mtime;
          print(
            '[r431] ${e.name}\n'
            '        list    size=${e.size} mtime=${e.mtime}\n'
            '        getinfo size=${info.size} mtime=${info.mtime}\n'
            '        ⇒ ${same ? "一致" : "★打架"}',
          );
        }
      case 'down':
        await fs.deleteItems([probeDir], recursive: true);
        print('[r431] 已发删除 $probeDir');
        final base = probeDir.split('/').last;
        final home = await fs.listFolder(folderPath: '/home');
        final hit = home.entries.where((f) => f.name == base).toList();
        print('[r431] 回读 /home 里 $base 条目数 = ${hit.length}（期望 0）');
        print('[r431] 回读 /home 总条目数 = ${home.entries.length}');
      default:
        fail('未知 STAGE=$stage');
    }
    await api.logout();
    print('[r431] 已登出（stage=$stage 收尾）');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
