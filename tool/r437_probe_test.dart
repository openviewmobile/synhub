// r437 · 宿主侧探针（**自建探针目录内的写动词 + 只读**，仪器91：放 `tool/` 不进闸门②）。
//
// 目的：给 `DA91`（自动续播的"零画面证据"提示：证据没有条目归属 / 事件不保序）
// 的真机复验造**两条对照** —— 都是"片尾自动续播到下一集"，只差下一条**有没有画面**：
//   * `neg/`（**阴性对照**：下一条真能解码出画）
//     `r437_neg_a_blue12.mp4`（12 s 纯蓝）→ `r437_neg_b_testsrc180.webm`（VP8，180 s，带时间码）
//     ⇒ 期望：续播后**画面在动、且没有提示条**。
//   * `pos/`（**阳性对照**：下一条**零画面证据**但**不报错**）
//     `r437_pos_a_blue12.mp4`（12 s 纯蓝）→ `r437_pos_b_silent30.mp4`（**只有 AAC 音轨、没有视频流**，
//     扩展名 `.mp4` ⇒ 应用按 `kVideoExtensions` 当**视频**来源 ⇒ `_expectsVideo` 为真、
//     永远不会有尺寸/首帧、也不会报错）
//     ⇒ 期望：确认窗口到点后**仍然出现提示**（R7-11 不回归），且这一刻屏上是**上一条的蓝帧**。
//
// ★ 为什么下一条用"只有音轨的 mp4"而不是 Theora：本机 ffmpeg **没有 `libtheora`**（实测
//   `Unknown encoder 'libtheora'`），而"零画面 + 零错误"这条路径要的是**没有视频流**，
//   不是"编解码器不支持"（后者会先给 `error`，提示链提前 return）。
//
// 阶段（`--dart-define=STAGE=`）：
//   up    建 `/home/r437probe` ＋ `neg`/`pos` 两个子目录 ＋ 上传 4 个样本 ＋ list 读数
//   down  删 `/home/r437probe`（**当轮还原**）＋ 回读 `/home` 确认残留 0
//
// 凭据只走 `--dart-define`（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   export PATH="<flutter-sdk>/bin:$PATH"
//   flutter test tool/r437_probe_test.dart --dart-define=STAGE=up \
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
  defaultValue: '/tmp/r437/samples',
);
const String probeDir = String.fromEnvironment(
  'PROBE_DIR',
  defaultValue: '/home/r437probe',
);

/// 子目录 ⇒ 该目录里的样本（顺序即真机播放顺序：按文件名排序）
const Map<String, List<String>> layout = {
  'neg': ['r437_neg_a_blue12.mp4', 'r437_neg_b_testsrc180.webm'],
  'pos': ['r437_pos_a_blue12.mp4', 'r437_pos_b_silent30.mp4'],
};

Future<DsmWebApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'FileStation');
  print('[r437] 已登录 $url as $account（sid 前缀 '
      '${api.session!.sid.substring(0, 6)}…）');
  return api;
}

Future<void> readBack(FileStationApi fs, String dir, String tag) async {
  final res = await fs.listFolder(folderPath: dir);
  print('[r437][$tag] $dir 条目数 = ${res.entries.length}');
  for (final e in res.entries) {
    print('[r437][$tag] ${e.name}  size=${e.size}  mtime=${e.mtime}');
  }
}

void main() {
  test('r437 DA91 自动续播两条对照的素材探针', () async {
    if (url.isEmpty || account.isEmpty || password.isEmpty) {
      fail('缺 NAS_URL/NAS_ACCOUNT/NAS_PASSWORD（只从 --dart-define 来）');
    }
    final api = await connect();
    final fs = FileStationApi(api);
    final base = probeDir.split('/').last;

    switch (stage) {
      case 'up':
        try {
          await fs.deleteItems([probeDir], recursive: true);
        } catch (e) {
          print('[r437] 预清理（可忽略）: $e');
        }
        await fs.createFolder(folderPath: '/home', name: base);
        print('[r437] 已建 $probeDir');
        for (final entry in layout.entries) {
          final sub = entry.key;
          await fs.createFolder(folderPath: probeDir, name: sub);
          for (final name in entry.value) {
            final local = File('$localDir/$sub/$name');
            print('[r437] 本地 $sub/$name = ${await local.length()}B ⇒ 上传');
            await fs.upload(
              folderPath: '$probeDir/$sub',
              filePath: local.path,
              fileName: name,
              conflict: UploadConflictPolicy.overwrite,
            );
          }
          await readBack(fs, '$probeDir/$sub', 'up');
        }
      case 'walk':
        for (final entry in layout.entries) {
          final dir = '$probeDir/${entry.key}';
          final res = await fs.listFolder(folderPath: dir);
          print('[r437] $dir 条目数 = ${res.entries.length}');
          for (final e in res.entries) {
            final info = await fs.getInfo('$dir/${e.name}');
            final same = e.size == info.size && e.mtime == info.mtime;
            print('[r437] ${e.name}  size=${e.size}  '
                'list/getinfo ⇒ ${same ? "一致" : "★打架"}');
          }
        }
      case 'down':
        await fs.deleteItems([probeDir], recursive: true);
        print('[r437] 已发删除 $probeDir');
        final home = await fs.listFolder(folderPath: '/home');
        final hit = home.entries.where((f) => f.name == base).toList();
        print('[r437] 回读 /home 里 $base 条目数 = ${hit.length}（期望 0）');
        print('[r437] 回读 /home 总条目数 = ${home.entries.length}');
      default:
        fail('未知 STAGE=$stage');
    }
    await api.logout();
    print('[r437] 已登出（stage=$stage 收尾）');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
