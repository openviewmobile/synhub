// **r443** · 网络电台「多选批量删除」的离线验证（`DA97`/`DA98` 同轮落地）。
//
// 事实来源（真 NAS **有界写**探针，`tool/r443_radio_batch_delete_probe_test.dart`
// 逐条量出，收尾残留 0）：
//   * `{offset, limit:n, radios_json:'[]'}` **一次删一段连续的 n 行**（1→0）；
//   * 段删完**后面的行号前移** ⇒ 多段必须 **从高往低** 发（B 段：选首尾两条、
//     留下中间那条，读数 `total=1 残留=[r443probe-2]`）；
//   * `limit` 越界 ⇒ **钳到末尾**、不报错（C 段 `limit:99` 后 `total` 回到 T0）；
//   * `limit:0` ⇒ 服务端**拒绝**（`101`），那条**不会被删**（D 段：不是静默清空）；
//   * ★ `Radio.add {title:"", url:""}` ⇒ **服务端照收**，列表里多出一条
//     `id="radio_" / title="" / url=""` 的**死行**（E 段）⇒ `DA97`。
//
// 本文件覆盖（全部**离线**：假传输 + 假引擎）：
//   ① 纯逻辑：段划分 / 发出顺序（高→低）/ 调用形状 / 容器行判据；
//   ② 页面动作级：长按进入多选、点行反选、全选、确认或取消、**逐段请求形状**；
//   ③ 反向：分类层/根层**没有**多选入口（写动词的 container 必须与本页一致）；
//   ④ `DA97`：新建电台**名称/URL 必填** —— 空值 ⇒ **零请求**且对话框不关；
//   ⑤ `DA98`：`SYNO.AudioStation.Radio.*` 的 `101` 不再说"播放列表名称"；
//   ⑥ 结构性守卫（仪器122：钉**声明**）：批量删除必须经 `radioDeleteCalls`。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/user_facing_error.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_radio_page.dart';
import 'package:synhub/src/features/audio/audio_radio_relay.dart';
import 'package:synhub/src/features/audio/audio_radio_selection.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _as = 'SYNO.AudioStation';

/// AS 能力表（`Radio` 给到 v2，真机形状）——与 r441 搜索用例同一张。
Map<String, Map<String, dynamic>> _table() => {
  'SYNO.AudioStation.Info': {
    'path': 'AudioStation/info.cgi',
    'minVersion': 1,
    'maxVersion': 6,
  },
  '$_as.Radio': {
    'path': 'AudioStation/radio.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

int _countOf(FakeTransport t, String api, String method) =>
    t.calls.where((c) => c['api'] == api && c['method'] == method).length;

List<Map<String, dynamic>> _callsOf(
  FakeTransport t,
  String api,
  String method,
) => [
  for (final c in t.calls)
    if (c['api'] == api && c['method'] == method) c,
];

// ─────────────────────────────────────────────────────────── 夹具（真机形状）

/// `UserDefined` 层的电台行（真机：`id` 前缀 `radio_`、`url` 有值、`type=station`）。
Map<String, dynamic> _userDefined(List<String> titles) => {
  'radios': [
    for (var i = 0; i < titles.length; i++)
      {
        'id': 'radio_${titles[i]}',
        'title': titles[i],
        'type': 'station',
        'url': 'https://example.invalid/${titles[i]}',
        'desc': 'MP3 (128 kbps)',
      },
  ],
  'total': titles.length,
};

Future<(FakeTransport, ProviderContainer)> _pumpRadio(
  WidgetTester tester, {
  required Map<String, Map<String, dynamic>> responses,
  String? container,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ..._table(),
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final c = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(AudioStationApi(api)),
      audioStationPlayerProvider.overrideWithValue(_FakePlayer()),
      radioStreamRelayProvider.overrideWithValue(const NoopRadioStreamRelay()),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: AudioRadioPage(container: container, titleOverride: '电台'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return (t, c);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// 长按第 [index] 行进入多选（再点别的行 = 反选加选）。
Future<void> _longPressRow(WidgetTester tester, String title) async {
  await tester.longPress(
    find.byKey(Key('as-radio-station-tile-radio_$title')),
  );
  await _settle(tester);
}

Future<void> _tapRow(WidgetTester tester, String title) async {
  await tester.tap(find.byKey(Key('as-radio-station-tile-radio_$title')));
  await _settle(tester);
}

/// 点「删除所选」→ 在确认框里点 [confirm]。
Future<void> _batchDelete(
  WidgetTester tester, {
  bool confirm = true,
}) async {
  await tester.tap(find.byKey(const Key('as-radio-batch-delete')));
  await _settle(tester);
  await tester.tap(
    find.byKey(
      Key(confirm ? 'as-radio-batch-delete-ok' : 'as-radio-batch-delete-cancel'),
    ),
  );
  await _settle(tester);
  await _settle(tester);
}

void main() {
  group('r443 · 纯逻辑：段划分与发出顺序（真机读数的形状来源）', () {
    test('① 连续归一段、不连续另起一段；乱序/重复/负数都收拾干净', () {
      expect(radioDeleteRuns([3, 1, 2, 7]), [
        [1, 2, 3],
        [7],
      ]);
      expect(radioDeleteRuns([5, 5, 4]), [
        [4, 5],
      ]);
      expect(radioDeleteRuns([-1, 0, -3]), [
        [0],
      ]);
      expect(radioDeleteRuns(const <int>[]), isEmpty);
    });

    test('★★② 发出顺序 **从高往低**（删低位段会让高位行号前移）', () {
      // 真机 B 段：选首尾两条（行号 0 与 2）⇒ 先发 offset=2，再发 offset=0。
      expect(radioDeleteOrder([0, 2]), [
        [2],
        [0],
      ]);
      // 多段混合：`[0,1,4,5,9]` ⇒ 段 `[0,1] [4,5] [9]` ⇒ 发出顺序 9 / 4 / 0。
      expect(radioDeleteOrder([0, 1, 4, 5, 9]), [
        [9],
        [4, 5],
        [0, 1],
      ]);
    });

    test('③ 调用形状：每段一对 `(offset, limit)`，与真机探针逐字同', () {
      expect(radioDeleteCalls([0, 1, 2]), [(0, 3)]);
      expect(radioDeleteCalls([0, 2]), [(2, 1), (0, 1)]);
      expect(radioDeleteCalls([0, 1, 4, 5, 9]), [(9, 1), (4, 2), (0, 2)]);
      expect(radioDeleteCalls(const <int>[]), isEmpty);
    });

    test('④ 选中项落在容器行上 ⇒ 判据为真（不许删容器）', () {
      expect(radioSelectionHitsContainer([0, 2], {2, 3}), isTrue);
      expect(radioSelectionHitsContainer([1], {2, 3}), isFalse);
    });
  });

  group('r443 · 页面：自定义电台页的多选批量删除', () {
    testWidgets('⑤ 长按进入多选、点行加选 ⇒ **逐段**发请求（高→低）＋ 提示条 ＋ 重载',
        (tester) async {
      final (t, _) = await _pumpRadio(
        tester,
        container: AudioRadioDto.containerUserDefined,
        responses: {
          '$_as.Radio.list': _userDefined(['A', 'B', 'C']),
          '$_as.Radio.updateradios': const {},
        },
      );
      final listBefore = _countOf(t, '$_as.Radio', 'list');

      // 长按第 1 行 ⇒ 多选态；点第 3 行 ⇒ 加选（选中的是 0 与 2，不连续）。
      await _longPressRow(tester, 'A');
      expect(find.byKey(const Key('as-radio-selection-bar')), findsOneWidget);
      await _tapRow(tester, 'C');
      expect(
        find.textContaining('已选'),
        findsOneWidget,
        reason: '底部条要显示已选条数',
      );

      await _batchDelete(tester);
      final calls = _callsOf(t, '$_as.Radio', 'updateradios');
      expect(calls.length, 2, reason: '两段 = 两次调用（连续段才合并）');
      // ★★ 顺序 = 从高往低（先 offset 2，再 offset 0）—— 反过来就会删错行。
      expect(calls[0]['offset'], 2);
      expect(calls[0]['limit'], 1);
      expect(calls[1]['offset'], 0);
      expect(calls[1]['limit'], 1);
      for (final c in calls) {
        expect(c['container'], AudioRadioDto.containerUserDefined);
        expect(c['radios_json'], '[]', reason: '删除 = 把这一段替换成**空**');
      }
      expect(find.byKey(const Key('as-radio-batch-deleted')), findsOneWidget);
      expect(
        _countOf(t, '$_as.Radio', 'list'),
        greaterThan(listBefore),
        reason: '删完必须**服务端回读**（重载列表）',
      );
      expect(
        find.byKey(const Key('as-radio-selection-bar')),
        findsNothing,
        reason: '成功后退出多选态',
      );
    });

    testWidgets('⑥ 连续多选 ⇒ **一次**调用（limit = 段长）', (tester) async {
      final (t, _) = await _pumpRadio(
        tester,
        container: AudioRadioDto.containerUserDefined,
        responses: {
          '$_as.Radio.list': _userDefined(['A', 'B', 'C', 'D']),
          '$_as.Radio.updateradios': const {},
        },
      );
      await _longPressRow(tester, 'B');
      await _tapRow(tester, 'C');
      await _tapRow(tester, 'D');
      await _batchDelete(tester);
      final calls = _callsOf(t, '$_as.Radio', 'updateradios');
      expect(calls.length, 1, reason: 'B/C/D 连续 ⇒ 一段');
      expect(calls.single['offset'], 1);
      expect(calls.single['limit'], 3);
    });

    testWidgets('⑦ 确认框点「取消」⇒ **零写动词**（多选态保留）', (tester) async {
      final (t, _) = await _pumpRadio(
        tester,
        container: AudioRadioDto.containerUserDefined,
        responses: {
          '$_as.Radio.list': _userDefined(['A', 'B']),
          '$_as.Radio.updateradios': const {},
        },
      );
      await _longPressRow(tester, 'A');
      await _batchDelete(tester, confirm: false);
      expect(_countOf(t, '$_as.Radio', 'updateradios'), 0);
      expect(find.byKey(const Key('as-radio-selection-bar')), findsOneWidget);
    });

    testWidgets('⑧ 顶栏「全选」⇒ 一次调用吃掉全部电台行', (tester) async {
      final (t, _) = await _pumpRadio(
        tester,
        container: AudioRadioDto.containerUserDefined,
        responses: {
          '$_as.Radio.list': _userDefined(['A', 'B', 'C']),
          '$_as.Radio.updateradios': const {},
        },
      );
      await _longPressRow(tester, 'A');
      await tester.tap(find.byKey(const Key('as-radio-select-all')));
      await _settle(tester);
      await _batchDelete(tester);
      final calls = _callsOf(t, '$_as.Radio', 'updateradios');
      expect(calls.length, 1);
      expect(calls.single['offset'], 0);
      expect(calls.single['limit'], 3);
    });

    testWidgets('⑨ 反向：分类层 / 根层**没有**多选入口（写动词 container 必须同页）',
        (tester) async {
      final (t, _) = await _pumpRadio(
        tester,
        container: 'SHOUTcast',
        responses: {
          '$_as.Radio.list': _userDefined(['A', 'B']),
          '$_as.Radio.updateradios': const {},
        },
      );
      expect(find.byKey(const Key('as-radio-select-mode')), findsNothing);
      expect(find.byKey(const Key('as-radio-check-radio_A')), findsNothing);
      // 长按也不进多选（分类层没有可多选的行）。
      await _longPressRow(tester, 'A');
      expect(find.byKey(const Key('as-radio-selection-bar')), findsNothing);
      expect(_countOf(t, '$_as.Radio', 'updateradios'), 0);
    });

    testWidgets('⑩ 反向：收藏页也**没有**批量删除（多选只给自定义电台页）',
        (tester) async {
      await _pumpRadio(
        tester,
        container: AudioRadioDto.containerFavorite,
        responses: {'$_as.Radio.list': _userDefined(['A', 'B'])},
      );
      expect(find.byKey(const Key('as-radio-select-mode')), findsNothing);
      expect(find.byKey(const Key('as-radio-check-radio_A')), findsNothing);
    });
  });

  group('r443 · DA97：新建电台的名称 / URL 必填', () {
    testWidgets('⑪ 两个都空 ⇒ 对话框**不关**、**零请求**，两条原因都写出来',
        (tester) async {
      final (t, _) = await _pumpRadio(
        tester,
        container: AudioRadioDto.containerUserDefined,
        responses: {'$_as.Radio.list': _userDefined(const [])},
      );
      await tester.tap(find.byKey(const Key('as-radio-add')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('as-radio-ok')));
      await _settle(tester);
      expect(_countOf(t, '$_as.Radio', 'add'), 0, reason: '★ 空值不许发 `Radio.add`');
      expect(find.byKey(const Key('as-radio-ok')), findsOneWidget,
          reason: '校验不过 ⇒ 留在对话框里（不许关掉当成功）');
      expect(find.text('请填写电台名称'), findsOneWidget);
      expect(find.text('请填写电台地址（URL）'), findsOneWidget);

      // 只补名称、URL 仍空 ⇒ 仍不许发。
      await tester.enterText(
        find.byKey(const Key('as-radio-title-field')),
        'r443fixture',
      );
      await tester.tap(find.byKey(const Key('as-radio-ok')));
      await _settle(tester);
      expect(_countOf(t, '$_as.Radio', 'add'), 0);

      // 两个都补齐 ⇒ 才发（且 trim 过）。
      await tester.enterText(
        find.byKey(const Key('as-radio-url-field')),
        'https://example.invalid/live',
      );
      await tester.tap(find.byKey(const Key('as-radio-ok')));
      await _settle(tester);
      final calls = _callsOf(t, '$_as.Radio', 'add');
      expect(calls.length, 1, reason: '两个都填好才允许新建');
      expect(calls.single['title'], 'r443fixture');
      expect(calls.single['url'], 'https://example.invalid/live');
    });
  });

  group('r443 · DA98：电台写动词的 101 不再说"播放列表名称"', () {
    test('⑫ `Radio.*` + 101 ⇒ 电台语境文案；`Playlist.*`/无 method 一位不动', () {
      const radio = '$_as.Radio.updateradios';
      final radioText = DsmErrorCode.describe(101, method: radio);
      expect(radioText, '电台请求未被服务端接受');
      expect(radioText, isNot(contains('播放列表')));
      // 真机 D 段读数：用户真正看到的那句话（`userFacingError` 出口）。
      final shown = userFacingError(DsmApiException(101, method: radio));
      expect(shown, contains('101'));
      expect(shown, contains('电台请求未被服务端接受'));
      expect(shown, isNot(contains('播放列表')));
      // 反向：播放列表语境的 101 仍是音频表的官方文案。
      expect(
        DsmErrorCode.describe(101, method: '$_as.Playlist.create'),
        '播放列表名称不被接受',
      );
      // 反向：不带 method 时通用码语义不变。
      expect(
        DsmErrorCode.describe(101),
        DsmErrorCode.messages[101],
        reason: '不带 method 时通用码语义不变（101 = 请求无效）',
      );
      // 反向：电台的其它码仍走音频表（只动 101 这一档）。
      expect(
        DsmErrorCode.describe(411, method: radio),
        '有重复的歌曲',
      );
    });
  });

  group('r443 · 结构性守卫（仪器122：钉声明）', () {
    test('⑬ 批量删除必须经 `radioDeleteCalls`（不许各写一份段逻辑）', () {
      final src = File('lib/src/features/audio/audio_radio_page.dart')
          .readAsStringSync();
      expect(src, contains('radioDeleteCalls(indices)'));
      expect(src, contains("import 'audio_radio_selection.dart';"));
      // ★ 反向：页面里**不许**直接写 `offset: i` 之类的自造段逻辑
      //   （批量删除的 offset 只能来自纯逻辑函数）。
      expect(
        RegExp(r'for \(final \(offset, limit\) in radioDeleteCalls').hasMatch(src),
        isTrue,
        reason: '段 → 调用的映射只有一个来源',
      );
      final helper =
          File('lib/src/features/audio/audio_radio_selection.dart')
              .readAsStringSync();
      expect(helper, contains('radioDeleteRuns(indices).reversed'));
    });
  });
}

// ─────────────────────────────────────────────────────────── 假引擎（只读占位）

class _FakePlayer implements AudioStationPlayer {
  @override
  String? get currentUrl => null;
  @override
  bool get playing => false;
  @override
  int get currentIndex => -1;
  @override
  int get queueLength => 0;
  @override
  List<AudioQueueEntry> get queue => const [];
  @override
  bool get shuffleEnabled => false;
  @override
  AudioRepeatMode get repeatMode => AudioRepeatMode.off;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => null;
  @override
  Stream<void> get changes => const Stream<void>.empty();
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
  @override
  Future<void> play(String url) async {}
  @override
  Future<void> playQueue(List<AudioQueueEntry> entries, {int startIndex = 0}) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> next() async {}
  @override
  Future<void> previous() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setShuffle(bool enabled) async {}
  @override
  Future<void> setRepeat(AudioRepeatMode mode) async {}
}
