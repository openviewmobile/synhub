// r432 · 宿主侧探针（**自建探针目录内的写动词 + 只读**，仪器91：放 `tool/` 不进闸门②）。
//
// 目的：把 r431 的「自动续播误报『can't be played in-app』」**先定性再动手**。
// r431 只证明了"提示与画面同时存在"，但**没证明画面是"新条目渲染出来的"
// 还是"上一条留在 surface 上的冻结帧"** —— 这两者的结论相反：
//   * 若新条目真的在渲染 ⇒ 提示是**假的**（Dart 侧看门狗误判）；
//   * 若画面是**冻结的旧帧** ⇒ 提示在机制上**是对的**（新条目确实零画面证据），
//     真正的缺陷是"**换集后旧画面不撤**，用户以为在播"。
//
// 为此造两条**内容可判**的样本：
//   ① `r432_a12_blue.mp4`      —— 12 s 纯深蓝（H.264；`framemd5` 逐帧**完全相同**）
//   ② `r432_b180_testsrc.webm` —— 180 s `testsrc`（VP8+Opus；`framemd5` 逐帧**互不相同**：
//      走势图 + 走动的时间码）⇒ **只要在渲染，两次截屏就不可能逐字节相同**
//
// 阶段（`--dart-define=STAGE=`）：
//   up    建 `/home/r432probe` ＋ 上传 2 个样本 ＋ list 读数（尺寸/mtime）
//   walk  只读：`list` 与 `getinfo` 逐条对比（两把尺子）
//   down  删 `/home/r432probe`（**当轮还原**）＋ 回读 `/home` 确认残留 0
//
// 凭据只走 `--dart-define`（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   export PATH="<flutter-sdk>/bin:$PATH"
//   flutter test tool/r432_probe_test.dart --dart-define=STAGE=up \
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
  defaultValue: '/tmp/r432',
);
const String probeDir = String.fromEnvironment(
  'PROBE_DIR',
  defaultValue: '/home/r432probe',
);

// ★ 顺序即**播放列表顺序**（服务端按文件名排）：`01` 蓝 2 s → **`02` testsrc 2 s**
// → 03 蓝 12 s → 04 静态彩条 180 s → 05 testsrc 180 s。
// 2 秒那两条是**主探针**：自动续播到的下一条**很快到结尾**，于是 Dart 看门狗里
// "位置还在推进就抑制上报"（`_positionAdvanced && !_reachedEnd`）这条豁免**自动失效**，
// 提示要么出现要么不出现，一次就能判；而 `testsrc` 自带**走动的图案**，
// 配合 01 的纯蓝可以判决"屏上那张到底是新条目的帧、还是上一条留下的旧帧"。
const List<String> samples = [
  'r432_01_blue2s.mp4',
  'r432_02_testsrc2s.webm',
  'r432_03_blue12.mp4',
  'r432_04_smpte180.webm',
  'r432_05_testsrc180.webm',
];

// ★ 复现用：r431 的**原样本集合**（真机在那一轮**确实**撞到过提示）
const List<String> samplesB = [
  'r431_lang.mp4',
  'r431_lang180.mp4',
  'r431_mov.mov',
  'r431_noaudio.mp4',
  'r431_noaudio180.mp4',
  'r431_webm.webm',
];

Future<DsmWebApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'FileStation');
  print('[r432] 已登录 $url as $account（sid 前缀 '
      '${api.session!.sid.substring(0, 6)}…）');
  return api;
}

Future<void> readBack(FileStationApi fs, String tag) async {
  final res = await fs.listFolder(folderPath: probeDir);
  print('[r432][$tag] list 条目数 = ${res.entries.length}');
  for (final e in res.entries) {
    print('[r432][$tag] ${e.name}  size=${e.size}  mtime=${e.mtime}');
  }
}

void main() {
  test('r432 自动续播定性素材探针', () async {
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
          print('[r432] 预清理（可忽略）: $e');
        }
        final base = probeDir.split('/').last;
        await fs.createFolder(folderPath: '/home', name: base);
        print('[r432] 已建 $probeDir');
        for (final name in samples) {
          final local = File('$localDir/$name');
          final len = await local.length();
          print('[r432] 本地 $name = ${len}B ⇒ 上传');
          await fs.upload(
            folderPath: probeDir,
            filePath: local.path,
            fileName: name,
            conflict: UploadConflictPolicy.overwrite,
          );
        }
        await readBack(fs, 'up');
      case 'up2':
        // 只补第三条（`smptebars` **静态彩条**）：它是"画面在 / 提示也在"那个
        // 现场的**同族**样本，用来做**颜色身份**判决（蓝 vs 彩条 ⇒ 屏上到底是哪一条的帧）。
        for (final name in const ['r432_06_calib.mp4']) {
          final local = File('$localDir/$name');
          print('[r432] 本地 $name = ${await local.length()}B ⇒ 上传');
          await fs.upload(
            folderPath: probeDir,
            filePath: local.path,
            fileName: name,
            conflict: UploadConflictPolicy.overwrite,
          );
        }
        await readBack(fs, 'up2');
      case 'upB':
        const dirB = '/home/r432bprobe';
        try {
          await fs.deleteItems([dirB], recursive: true);
        } catch (e) {
          print('[r432] 预清理（可忽略）: $e');
        }
        await fs.createFolder(folderPath: '/home', name: dirB.split('/').last);
        print('[r432] 已建 $dirB');
        for (final name in samplesB) {
          final local = File('/tmp/r431/$name');
          print('[r432] 本地 $name = ${await local.length()}B ⇒ 上传');
          await fs.upload(
            folderPath: dirB,
            filePath: local.path,
            fileName: name,
            conflict: UploadConflictPolicy.overwrite,
          );
        }
        final resB = await fs.listFolder(folderPath: dirB);
        print('[r432][upB] 条目数 = ${resB.entries.length}');
        for (final e in resB.entries) {
          print('[r432][upB] ${e.name} size=${e.size}');
        }
      case 'walk':
        final res = await fs.listFolder(folderPath: probeDir);
        print('[r432] list 条目数 = ${res.entries.length}');
        for (final e in res.entries) {
          final info = await fs.getInfo('$probeDir/${e.name}');
          final same = e.size == info.size && e.mtime == info.mtime;
          print(
            '[r432] ${e.name}\n'
            '        list    size=${e.size} mtime=${e.mtime}\n'
            '        getinfo size=${info.size} mtime=${info.mtime}\n'
            '        ⇒ ${same ? "一致" : "★打架"}',
          );
        }
      case 'down':
        await fs.deleteItems([probeDir], recursive: true);
        print('[r432] 已发删除 $probeDir');
        final base = probeDir.split('/').last;
        final home = await fs.listFolder(folderPath: '/home');
        final hit = home.entries.where((f) => f.name == base).toList();
        print('[r432] 回读 /home 里 $base 条目数 = ${hit.length}（期望 0）');
        print('[r432] 回读 /home 总条目数 = ${home.entries.length}');
      case 'downB':
        const dirB = '/home/r432bprobe';
        await fs.deleteItems([dirB], recursive: true);
        print('[r432] 已发删除 $dirB');
        final homeB = await fs.listFolder(folderPath: '/home');
        final hitB = homeB.entries.where((f) => f.name == 'r432bprobe').toList();
        print('[r432] 回读 /home 里 r432bprobe 条目数 = ${hitB.length}（期望 0）');
        print('[r432] 回读 /home 总条目数 = ${homeB.entries.length}');
        for (final e in homeB.entries) {
          print('[r432] /home 残留: ${e.name}');
        }
      default:
        fail('未知 STAGE=$stage');
    }
    await api.logout();
    print('[r432] 已登出（stage=$stage 收尾）');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
