// ★★★ 第 131 轮 / ⑤音频：Mock 目录能否**校验**音频全部 API（规则 B）。
//
// 事实来源：`<home>/synology_samples/weblib/AudioStation/`
//   * `webapi/AudioStation.api`（DSM 核心 `.api`，权威：逐版本方法表）
//   * `SYNO.AudioStation.lib`（SPK 侧：Pin/Tag/Browse.Playlist/VoiceAssistant）
// 第 131 轮把这 20 条**空方法表**补齐（0 冲突，只做交叉印证不覆盖已有数据）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = jsonDecode(
    File('tool/mock_dsm/catalog.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final apis = (catalog['apis'] as Map).cast<String, dynamic>();
  final audioApis = apis.keys.where((k) => k.startsWith('SYNO.AudioStation')).toList()
    ..sort();

  test('★ 每个音频 API 都有方法表且 methodsVerified（Mock 才校验得了）', () {
    final bad = <String>[];
    for (final k in audioApis) {
      final e = apis[k] as Map;
      final m = e['methods'];
      if (m is! Map || m.isEmpty || e['methodsVerified'] != true) bad.add(k);
    }
    expect(bad, isEmpty, reason: '空方法表/未核实：$bad');
  });

  test('★ 写方法在表里（创建/删除/改名/改曲/另存/电台写）', () {
    Map methodsOf(String api) => (apis[api] as Map)['methods'] as Map;
    Set<String> flat(Map m) =>
        m.values.expand((v) => (v as List).map((x) => '$x')).toSet();

    expect(flat(methodsOf('SYNO.AudioStation.Playlist')), containsAll(<String>[
      'create', 'delete', 'rename', 'updatesongs', 'saveplaying',
      'createsmart', 'updatesmart', 'editsharing',
    ]));
    expect(flat(methodsOf('SYNO.AudioStation.Radio')), containsAll(<String>[
      'list', 'add', 'search', 'updateradios',
    ]));
    expect(flat(methodsOf('SYNO.AudioStation.Song')), containsAll(<String>[
      'list', 'search', 'getinfo', 'setrating', 'setsharing', 'getsharing',
    ]));
    expect(flat(methodsOf('SYNO.AudioStation.Browse.Playlist')),
        contains('add_track'));
  });

  test('★ 版本分散陷阱：`search` 只在 Radio v2 / `list_default_genre` 只在 v3', () {
    final playlist = (apis['SYNO.AudioStation.Playlist'] as Map)['methods'] as Map;
    final radio = (apis['SYNO.AudioStation.Radio'] as Map)['methods'] as Map;
    final genre = (apis['SYNO.AudioStation.Genre'] as Map)['methods'] as Map;

    // Radio：v1 没有 search，v2 才有 ⇒ 不能照抄 maxVersion 去 v1 找
    expect((radio['1'] as List), isNot(contains('search')));
    expect((radio['2'] as List), contains('search'));
    // 方法表本身要逐版本存在
    expect(playlist.keys.map((k) => '$k'), containsAll(<String>['1', '2', '3']));
    expect((genre['1'] as List), isNot(contains('list_default_genre')));
    expect((genre['3'] as List), contains('list_default_genre'));
  });

  test('★ 来源标注（可追溯，不写"我猜的"）', () {
    for (final k in audioApis) {
      final e = apis[k] as Map;
      expect('${e['methodsSource'] ?? e['source']}', isNotEmpty, reason: k);
    }
  });
}
