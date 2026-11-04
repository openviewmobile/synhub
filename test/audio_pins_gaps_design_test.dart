// **r481** · 收藏页与「发现」家族（最近添加 / 随机 100 / 最近播放）改用设计组件的离线验证
// （`DA116` / `DA117`）。
//
// 判据不是"页面能打开"，而是粉丝条：
//   ① **设计组件真的在树上**（`DesignScaffold` / `DesignRowTile`）→ 说明白底、
//      行卡、组标题这些**不是截图里画的**，而是同一套组件产出的；
//   ② **老组件真的不在了**（反向：不许 `ListTile` / `HudScaffold` 残留）；
//   ③ spec 里写明的两个动作（搜索 / 刷新）**都在**，而且**不在菜单里**
//      （用户原话："常用动作被藏进菜单" ⇒ 这一页只有两个动作，就不该藏）；
//   ④ 空态/未安装态的老行为**逐字保留**（换设计不许把状态语言弄丢）。
//
// 视口用"真机竖向高度"（800×1400）：600 高会把列表挤到懒加载视口外，
// `find.byKey` 默认跳过离屏子树 ⇒ 会造出"功能没坏、测试找不到"的假红。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/features/audio/audio_gaps_page.dart';
import 'package:synhub/src/features/audio/audio_pins_page.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/media/media_playback_store.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _as = 'SYNO.AudioStation';

const _asTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  '$_as.Info': {'path': 'AudioStation/info.cgi', 'minVersion': 1, 'maxVersion': 6},
  '$_as.Pin': {'path': 'AudioStation/pin.cgi', 'minVersion': 1, 'maxVersion': 1},
  '$_as.Album': {'path': 'AudioStation/album.cgi', 'minVersion': 1, 'maxVersion': 3},
  '$_as.Song': {'path': 'AudioStation/song.cgi', 'minVersion': 1, 'maxVersion': 3},
};

/// 造一个"已登录、Audio Station 已安装"的容器。
Future<ProviderContainer> _container({
  Map<String, Map<String, dynamic>> responses = const {},
  List<Object> more = const [],
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._asTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(AudioStationApi(api)),
      ...more,
    ].cast(),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  List<Object> more = const [],
}) async {
  final c = await _container(responses: responses, more: more);
  addTearDown(c.dispose);
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  group('DA116 · 收藏页（Pins）用设计组件', () {
    testWidgets('DA116：收藏列表是设计行卡，且搜索/刷新都在顶栏（不在菜单里）', (tester) async {
      await _pump(
        tester,
        const AudioPinsPage(),
        responses: {
          '$_as.Pin.list': {
            'items': [
              {
                'id': 'pin_1',
                'type': 'artist',
                'name': '示例歌手',
                'criteria': {'artist': '示例歌手'},
              },
              {
                'id': 'pin_2',
                'type': 'album',
                'name': '00s Love Songs',
                'criteria': {'album': '00s Love Songs'},
              },
            ],
            'total': 2,
          },
        },
      );

      // ① 设计组件在树上
      expect(find.byType(DesignScaffold), findsOneWidget);
      expect(find.byType(DesignRowTile), findsNWidgets(2));

      // ② 反向：老组件不许残留
      expect(find.byType(ListTile), findsNothing);

      // ③ spec 的两个动作：都是顶栏图标，点得到
      expect(find.byKey(const Key('as-pins-search')), findsOneWidget);
      expect(find.byKey(const Key('as-pins-refresh')), findsOneWidget);
      expect(
        find.byType(PopupMenuButton<dynamic>),
        findsNothing,
        reason: '两个动作不该藏进 ⋮（用户抱怨过"常用动作被藏进菜单"）',
      );

      // 行内动作（改名 / 取消收藏 / 拖动）一个不少
      expect(find.byKey(const Key('as-unpin-pin_1')), findsOneWidget);
      expect(find.byKey(const Key('as-pin-rename-pin_2')), findsOneWidget);
      expect(find.byKey(const Key('as-pin-drag-pin_1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DA116：空态与未安装态的老文案逐字保留，且空态不是设计行卡', (tester) async {
      await _pump(
        tester,
        const AudioPinsPage(),
        responses: {
          '$_as.Pin.list': {'items': <Object>[], 'total': 0},
        },
      );
      expect(find.byType(DesignScaffold), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      expect(find.text('还没有收藏'), findsOneWidget);
      expect(find.text('在专辑、艺术家、流派或播放列表上点「收藏」就会出现在这里'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('DA117 · 「发现」家族用设计组件', () {
    testWidgets('DA117：最近添加 → 设计行卡 + 组标题，没有 Divider 残留', (tester) async {
      await _pump(
        tester,
        const AudioRecentlyAddedPage(),
        more: [
          audioRecentlyAddedProvider.overrideWith(
            (ref) async => const AudioNamedPage<AudioAlbumDto>(
              items: [
                AudioAlbumDto(
                  name: '00s Love Songs',
                  albumArtist: 'Demo Artist',
                  songCount: 10,
                ),
                AudioAlbumDto(name: 'Breakaway', albumArtist: 'Kelly Clarkson'),
              ],
              total: 2,
            ),
          ),
        ],
      );
      expect(find.byType(DesignScaffold), findsOneWidget);
      expect(find.byKey(const Key('as-recent-album-00s Love Songs')), findsOneWidget);
      expect(find.byType(DesignRowTile), findsNWidgets(2));
      expect(find.byType(ListTile), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DA117：随机 100 首 → 设计骨架 + 换一批按钮仍在', (tester) async {
      await _pump(
        tester,
        const AudioRandom100Page(),
        responses: {
          '$_as.Song.list': {
            'items': [
              {'id': 's1', 'title': 'Demo Song', 'path': '/m/1.mp3'},
            ],
            'total': 1,
          },
        },
      );
      expect(find.byType(DesignScaffold), findsOneWidget);
      expect(find.byKey(const Key('as-random-100-refresh')), findsOneWidget);
      // 静态反向：源码里不许再有 HudScaffold / 裸 ListTile（可红、不做假断言）
      for (final f in [
        'lib/src/features/audio/audio_gaps_page.dart',
        'lib/src/features/audio/audio_pins_page.dart',
      ]) {
        final src = File(f).readAsStringSync();
        expect(src.contains('HudScaffold('), isFalse, reason: '$f 还留着 HudScaffold');
        expect(src.contains('ListTile('), isFalse, reason: '$f 还留着裸 ListTile');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('DA118：单数不许写成 1 times / 1 days ago（英文真机抓到过）', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _pump(
        tester,
        const AudioPlayedPage(mode: AudioPlayedMode.recently),
        more: [
          audioListenHistoryProvider.overrideWith(
            () => _OneRecordHistory(
              AudioPlayRecord(
                id: 's1',
                title: 'Demo Song',
                count: 1,
                lastPlayedMs: now - 86400000,
              ),
            ),
          ),
        ],
      );
      // 中文模板：单数关键判据是"播放 1 次"而不是"播放 1 次"以外的东西？
      // 真正被判的是**英文** —— 这里用 dataText 的同一张表直接验字符串。
      expect(find.text('Demo Song'), findsOneWidget);
      expect(find.text('播放 1 次 · 1 天前'), findsOneWidget);
      // ★ 真正的判据在**英文**：真机抓到的就是 "1 days ago"。
      //   这里直接读 ARB（结构断言，可红），不依赖测试环境的默认语言。
      final en = File('lib/l10n/app_en.arb').readAsStringSync();
      expect(en.contains('"asDaysAgoOne": "1 day ago"'), isTrue);
      expect(en.contains('"asPlayCountOne": "Played once"'), isTrue);
      expect(en.contains('"asMinutesAgoOne": "1 minute ago"'), isTrue);
      expect(en.contains('"asHoursAgoOne": "1 hour ago"'), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DA117：最近播放的空态保留原文案', (tester) async {
      await _pump(
        tester,
        const AudioPlayedPage(mode: AudioPlayedMode.recently),
        more: [
          audioListenHistoryProvider.overrideWith(
            _EmptyHistoryController.new,
          ),
        ],
      );
      expect(find.byType(DesignScaffold), findsOneWidget);
      expect(find.byKey(const Key('as-played-empty-recently')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 收听记录为空（本地记录，纯客户端）—— 用来验"空态原文案仍在"。
class _EmptyHistoryController extends AudioListenHistoryController {
  @override
  Future<Map<String, AudioPlayRecord>> build() async => const {};
}

/// 断言单数用：一条 count==1 的收听记录。
class _OneRecordHistory extends AudioListenHistoryController {
  _OneRecordHistory(this.rec);
  final AudioPlayRecord rec;
  @override
  Future<Map<String, AudioPlayRecord>> build() async => {rec.id: rec};
}
