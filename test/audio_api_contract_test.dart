// 音频模块**契约守卫**：我方引用的 `SYNO.AudioStation.*` 必须与真机存在的集合一致。
//
// 为什么需要它：真机（第 17 轮，`SYNO.API.Info?query=all`）实测
// **20 个 `SYNO.AudioStation.*`**，且**全部**不在 `entry.cgi`：
//
//   SYNO.AudioStation.Album    → AudioStation/album.cgi
//   SYNO.AudioStation.Song     → AudioStation/song.cgi
//   SYNO.AudioStation.Playlist → AudioStation/playlist.cgi
//   …
//
// 这台 NAS 上有 **18,608 首歌 / 1,210 张专辑 / 8 个播放列表**，
// 所以这份契约不是纸面推演 —— 它是**真实可点的库**。
//
// 本用例守两件事：
//   1. **我方声明支持的音频 API ⊆ 真机存在的集合**（不能引用不存在的 API）；
//   2. **真机存在的音频 API ⊆ 我方声明的集合**（不能漏做）；
//      —— 即**两边必须完全相等**。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/real_nas_api_fixture.dart';

/// 从源码里抓出我方引用的 `SYNO.AudioStation.*` 字面量。
Set<String> _apisReferencedByApp() {
  final files = Directory('lib/src/data')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  final re = RegExp(r"'SYNO\.AudioStation\.[A-Za-z.]+'");
  final out = <String>{};
  for (final f in files) {
    for (final m in re.allMatches(f.readAsStringSync())) {
      out.add(m.group(0)!.replaceAll("'", ''));
    }
  }
  return out;
}

/// 从源码里抓出我方为这些 API 声明的 **path**（`apiXxx: 'AudioStation/yyy.cgi'`）。
Set<String> _pathsReferencedByApp() {
  final files = Directory('lib/src/data')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  final re = RegExp(r"'((?:AudioStation|DownloadStation)/[a-z_]+\.cgi)'");
  final out = <String>{};
  for (final f in files) {
    for (final m in re.allMatches(f.readAsStringSync())) {
      out.add(m.group(1)!);
    }
  }
  return out;
}

/// 真机快照里有、但**我们有理由不做**的音频 API（每一条都要给理由）。
const Map<String, String> kKnownAudioGaps = {
  // 语音助手技能（Amazon Alexa / Google Home 的服务端对接）。
  // 手机客户端**不会**调用它 —— 它是给智能音箱用的服务端技能。
  'SYNO.AudioStation.VoiceAssistant.Browse': '语音助手技能（服务端，非手机客户端）',
  'SYNO.AudioStation.VoiceAssistant.Challenge': '语音助手技能（服务端，非手机客户端）',
  'SYNO.AudioStation.VoiceAssistant.Info': '语音助手技能（服务端，非手机客户端）',
  'SYNO.AudioStation.VoiceAssistant.Stream': '语音助手技能（服务端，非手机客户端）',
  // ⚠️ 这一条**不是**"决定不做"，而是"**方法名尚未查明**"：
  // 真机 v1 上把 list/get/getinfo/list_item/browse 全试了一遍，**全回 103**
  // ⇒ 在查明它的方法名之前，**不能宣称它是一个功能缺口**。
  // 而"浏览播放列表内容"这个用户可见能力，我方已由
  // `SYNO.AudioStation.Playlist/list`（实测 `total: 8`）覆盖。
  'SYNO.AudioStation.Browse.Playlist': '方法名未查明（候选全 103）；能力已由 Playlist/list 覆盖',
};

void main() {
  group('音频模块 API 契约（真机快照）', () {
    test('我方引用的 AudioStation API **全部**在真机存在（不允许幻影 API）', () {
      final app = _apisReferencedByApp();
      final real = kRealNasAudioStationApis;

      expect(app, isNotEmpty);
      expect(
        app.difference(real),
        isEmpty,
        reason: '我方引用了真机上【不存在】的音频 API（真的会 102/104）',
      );
      expect(app, hasLength(22));
    });

    test('真机集合减去我方 = **已知且已给理由**的那几条', () {
      final missing = kRealNasAudioStationApis.difference(
        _apisReferencedByApp(),
      );
      expect(
        missing,
        kKnownAudioGaps.keys.toSet(),
        reason:
            '出现了【没有登记理由】的音频 API 缺口 —— '
            '要么补实现，要么在 kKnownAudioGaps 里写明为什么不做',
      );
    });

    test('每一条已知缺口都写了理由（非空字符串）', () {
      kKnownAudioGaps.forEach((api, why) {
        expect(why.trim(), isNotEmpty, reason: '$api 没写理由');
        expect(
          kRealNasAudioStationApis,
          contains(api),
          reason: '$api 不在真机快照里 ⇒ 这条"缺口"是虚构的',
        );
      });
    });

    test('真机快照里有 27 个音频 API，且 path 分布符合实测', () {
      expect(kRealNasAudioStationApis, hasLength(27));

      // 实测分布：**大多数**在 `AudioStation/*.cgi`，
      // 少数（`VoiceAssistant.*` / `Browse.Playlist` / `Pin` / `Tag`）走 `entry.cgi`。
      // ⇒ 这里断言的是"**不是一律 entry.cgi**"，
      // 而不是"每个都必须以 AudioStation/ 开头"（我一开始就是这么错的）。
      var cgi = 0;
      var entry = 0;
      for (final api in kRealNasAudioStationApis) {
        final path = kRealNasApiPaths[api];
        expect(path, isNotNull, reason: '$api 不在快照里');
        expect(path, isNotEmpty, reason: '$api 的 path 为空');
        if (path == 'entry.cgi') {
          entry++;
        } else {
          expect(
            path,
            startsWith('AudioStation/'),
            reason: '$api 的 path=$path 既不是 entry.cgi 也不是 AudioStation/*.cgi',
          );
          cgi++;
        }
      }
      expect(
        cgi,
        greaterThan(entry),
        reason: '实测大多数音频 API 在 AudioStation/*.cgi（cgi=$cgi entry=$entry）',
      );
      expect(entry, greaterThan(0), reason: '实测确实有少数走 entry.cgi');
    });

    test('我方确实为音频模块声明了非 entry.cgi 的 path', () {
      final paths = _pathsReferencedByApp();
      expect(
        paths,
        isNotEmpty,
        reason: '我方代码里找不到 AudioStation/*.cgi 或 DownloadStation/*.cgi 的字面量',
      );
      // 至少覆盖到这几个核心模块
      for (final need in [
        'AudioStation/album.cgi',
        'AudioStation/song.cgi',
        'AudioStation/playlist.cgi',
      ]) {
        expect(paths, contains(need), reason: '缺少 $need 的 path 声明');
      }
    });
  });

  group('真机快照自身的完整性', () {
    test('快照非空，且非 entry.cgi 的 path 数量合理', () {
      expect(kRealNasApiPaths, isNotEmpty);
      final nonEntry = kRealNasApiPaths.entries
          .where((e) => e.value != 'entry.cgi')
          .toList();
      expect(
        nonEntry.length,
        greaterThan(20),
        reason: '实测有 28+ 个 API 不在 entry.cgi',
      );
      expect(kNonEntryCgiPaths, isNotEmpty);
    });

    test('快照里所有 path 都不带前导 /webapi/（我们拼路径时会加）', () {
      for (final e in kRealNasApiPaths.entries) {
        expect(
          e.value.startsWith('/'),
          isFalse,
          reason: '${e.key} 的 path=${e.value} 不该有前导斜杠',
        );
      }
    });

    test('已知的关键 API 在快照里，且 path 与实测一致', () {
      const expectPaths = {
        'SYNO.AudioStation.Song': 'AudioStation/song.cgi',
        'SYNO.AudioStation.Playlist': 'AudioStation/playlist.cgi',
        'SYNO.DownloadStation.Task': 'DownloadStation/task.cgi',
        'SYNO.DownloadStation.Info': 'DownloadStation/info.cgi',
        'SYNO.DownloadStation.Statistic': 'DownloadStation/statistic.cgi',
        'SYNO.Foto.Browse.Item': 'entry.cgi',
        'SYNO.SynologyDrive.Files': 'entry.cgi',
        'SYNO.Cal.Event': 'entry.cgi',
      };
      expectPaths.forEach((api, path) {
        expect(kRealNasApiPaths[api], path, reason: '$api 的 path 实测是 $path');
      });
    });
  });
}
