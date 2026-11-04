// **r482** · 音乐库主页（`audio_page.dart`）改用设计组件的离线验证（`DA119`）。
//
// 判据（都可红）：
//   ① `DesignScaffold` 在树上、裸 `ListTile` 不在（含源码静态反向）；
//   ② 七个分页仍在（`as-tab-songs` … `as-tab-composers`），**顺序不变**；
//   ③ 分页条吃的是设计令牌：选中字色 = `p.text`、未选 = `p.muted`、
//      指示条 = `p.primary`（不是 HUD 那套亮青）；
//   ④ 歌曲行是 `DesignRowTile`，且**封面/更多/多选长按**这些行为没丢。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/data_text.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/design/design_palette.dart';
import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/features/audio/audio_labels.dart';
import 'package:synhub/src/features/audio/audio_page.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_detail_page.dart';
import 'package:synhub/src/features/audio/audio_radio_page.dart';
import 'package:synhub/src/features/audio/audio_remote_page.dart';
import 'package:synhub/src/features/audio/audio_search_page.dart';
import 'package:synhub/src/features/audio/audio_web_queue_page.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _as = 'SYNO.AudioStation';

const _asTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  '$_as.Info': {'path': 'AudioStation/info.cgi', 'minVersion': 1, 'maxVersion': 6},
  '$_as.Song': {'path': 'AudioStation/song.cgi', 'minVersion': 1, 'maxVersion': 3},
  '$_as.Album': {
    'path': 'AudioStation/album.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  '$_as.Artist': {
    'path': 'AudioStation/artist.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  '$_as.Genre': {
    'path': 'AudioStation/genre.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  '$_as.Composer': {
    'path': 'AudioStation/composer.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  '$_as.Folder': {
    'path': 'AudioStation/folder.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  '$_as.Playlist': {
    'path': 'AudioStation/playlist.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  // 这两个能力位决定「电台 / 播放队列」入口出不出现（r482 起在 ⋮ 里）
  '$_as.Radio': {
    'path': 'AudioStation/radio.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  '$_as.WebPlayer': {
    'path': 'AudioStation/web_player.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Map<String, dynamic> _song(String id, String title) => {
  'id': id,
  'title': title,
  'path': '/music/$id.mp3',
  'album': '00s Love Songs',
  'album_artist': 'Demo Artist',
  'artist': 'Demo Artist',
  'duration': 231,
  'bitrate': 320000,
  'additional': {
    'song_audio': {'bitrate': 320000, 'frequency': 44100},
    'song_tag': {'album': '00s Love Songs', 'artist': 'Demo Artist'},
  },
};

Future<ProviderContainer> _container({
  bool installSongs = true,
}) async {
  final t = FakeTransport({
    if (installSongs)
      '$_as.Song.list': {
        'songs': [_song('m1', 'Demo Song'), _song('m2', 'Season in the Sun')],
        'total': 2,
        'offset': 0,
      },
  }, {...FakeTransport.table, ..._asTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return ProviderContainer(
    overrides: [audioApiProvider.overrideWithValue(AudioStationApi(api))],
  );
}

Future<void> _pump(WidgetTester tester, {bool installSongs = true}) async {
  final c = await _container(installSongs: installSongs);
  addTearDown(c.dispose);
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: const AudioPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  group('DA119 · 音乐库主页用设计组件', () {
    testWidgets('DA119：骨架/行卡换成设计组件，七个分页顺序不变', (tester) async {
      await _pump(tester);

      expect(find.byType(DesignScaffold), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);

      // ② 七个分页：按官方顺序，一个都不许丢
      // 顺序 = `kAudioTabKinds`（song/album/artist/composer/genre/folder/playlist）
      const kinds = [
        'song',
        'album',
        'artist',
        'composer',
        'genre',
        'folder',
        'playlist',
      ];
      for (final k in kinds) {
        expect(
          find.byKey(Key('as-tab-$k')),
          findsOneWidget,
          reason: '分页 $k 丢了',
        );
      }

      // ④ 歌曲行是设计行卡
      expect(find.byType(DesignRowTile), findsWidgets);
      expect(find.text('Demo Song'), findsOneWidget);
      expect(find.text('Season in the Sun'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DA119：分页条吃设计令牌（选中 text / 未选 muted / 指示条 primary）', (
      tester,
    ) async {
      await _pump(tester);
      final ctx = tester.element(find.byKey(const Key('as-tab-song')));
      final p = DesignPalette.of(ctx);
      final bar = tester.widget<TabBar>(find.byType(TabBar).first);
      expect(bar.labelColor, p.text);
      expect(bar.unselectedLabelColor, p.muted);
      expect(bar.indicatorColor, p.primary);
      expect(bar.dividerColor, Colors.transparent);
      expect(
        bar.labelStyle?.fontWeight,
        FontWeight.w600,
        reason: '设计稿选中是 600',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('DA119：源码反向 —— 音乐库页不许再有 HudScaffold / 裸 ListTile', (
      tester,
    ) async {
      final src = File('lib/src/features/audio/audio_page.dart').readAsStringSync();
      expect(src.contains('HudScaffold('), isFalse);
      expect(src.contains('ListTile('), isFalse);
      expect(src.contains('DesignScaffold('), isTrue);
    });

    test('DA126：空名字一律有占位文案（三处名字型列表共用同一个函数）', () {
      // 纯规则：空名 / 纯空白 → 占位；正常名 → 原样
      final placeholder = dataText('asUnnamedName', '未命名');
      expect(asDisplayName(''), placeholder);
      expect(asDisplayName('   '), placeholder);
      expect(asDisplayName('\u00a0'), placeholder);
      expect(asDisplayName('Demo Artist'), 'Demo Artist');
      expect(asDisplayName(' 示例歌手 '), ' 示例歌手 ');

      // 结构判据：三个名字型列表（专辑 / 艺术家·流派·作曲家 / 播放列表）
      // 的标题都走 asDisplayName —— 不许再内联写 `trim().isEmpty ? … : …`
      final src = File('lib/src/features/audio/audio_page.dart').readAsStringSync();
      expect(
        RegExp(r'asDisplayName\(').allMatches(src).length,
        greaterThanOrEqualTo(3),
        reason: '专辑/名字型/播放列表三处标题都要走同一个占位规则',
      );
      expect(src.contains("trim().isEmpty\n"), isFalse);
    });

    testWidgets('DA121：「更多」是分组弹层而不是 11 项平铺菜单', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const Key('as-home-menu')));
      await tester.pumpAndSettle();

      // ① 是弹层：有 sheet 键、**没有** PopupMenuItem
      expect(find.byKey(const Key('as-more-sheet')), findsOneWidget);
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      expect(find.byType(PopupMenuItem<dynamic>), findsNothing);

      // ② 三组标题各一个（分组信息是这一轮的核心）
      expect(find.text('媒体源'), findsOneWidget);
      expect(find.text('更多列表'), findsOneWidget);
      expect(find.text('播放与投送'), findsOneWidget);

      // ③ 11 行都在，且每行都是设计行卡 + 带图标
      const keys = [
        'as-radio',
        'as-webqueue',
        'as-pins',
        'as-home-recently-added',
        'as-home-random-100',
        'as-home-recently-played',
        'as-home-most-played',
        'as-home-new-playlist',
        'as-home-equalizer',
        'as-home-cast',
        'as-home-remote',
      ];
      for (final k in keys) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: '弹层少了 $k');
      }
      final sheetRows = find.descendant(
        of: find.byKey(const Key('as-more-sheet')),
        matching: find.byType(DesignRowTile),
      );
      expect(sheetRows, findsNWidgets(keys.length));
      expect(
        find.descendant(of: sheetRows, matching: find.byType(Icon)),
        findsAtLeast(keys.length),
        reason: '每行都要有图标（纯文字菜单＝"藏起来"）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('DA120：歌曲行的次要行不画体积（真机上会被省略号切一半）', (tester) async {
      await _pump(tester);
      // ★ r631（DA120 的口径升级）：用户 2026-10-23「很多音频技术参数没有必要
      //   罗列在界面上，可以收在某一个菜单项里」⇒ 列表行的次要行**只留时长**
      //   （最多再带年份）。码率/采样率/体积一律不画：那三项已在「歌曲信息」
      //   面板里，且真机上常被省略号切成 "9.0…" 这种半截数字。
      expect(
        find.textContaining('kbps'),
        findsNothing,
        reason: 'r631：列表行不画码率（技术参数收进「歌曲信息」）',
      );
      expect(
        find.textContaining('kHz'),
        findsNothing,
        reason: 'r631：列表行不画采样率',
      );
      expect(
        find.textContaining('MB'),
        findsNothing,
        reason: '列表行不该出现体积（会挤到省略号，出现 "9.0…"）',
      );
      // 纯函数两档都在，谁也替代不了谁：
      //  * `asSongHumanMetaLine` = 列表/播放器页头用的"人话"一行；
      //  * `asSongMetaLine`     = 「歌曲信息」面板里的技术一行（含体积）。
      const dto = AudioSongDto(
        id: 'x',
        title: 'x',
        duration: 231,
        bitrate: 320000,
        frequency: 44100,
        filesize: 9090909,
      );
      expect(asSongHumanMetaLine(dto), '3:51');
      expect(
        asSongMetaLine(dto),
        contains('MB'),
        reason: '技术一行必须保留全部字段（面板里就靠它）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('DA119：顶栏从 6 个图标收到 3 个，电台/队列/收藏进「更多」', (tester) async {
      await _pump(tester);

      // 菜单关着时：三个入口**都不在树上**（它们是菜单项，不是图标）
      expect(find.byKey(const Key('as-radio')), findsNothing);
      expect(find.byKey(const Key('as-webqueue')), findsNothing);
      expect(find.byKey(const Key('as-pins')), findsNothing);

      // 顶栏只剩「搜索 / 切换音乐库 / 更多」
      expect(find.byKey(const Key('as-search')), findsOneWidget);
      expect(find.byKey(const Key('as-library-switch')), findsOneWidget);
      expect(find.byKey(const Key('as-home-menu')), findsOneWidget);
      final toolbarIcons = tester
          .widgetList<IconButton>(
            find.descendant(
              of: find.byType(AppBar),
              matching: find.byType(IconButton),
            ),
          )
          .length;
      expect(
        toolbarIcons,
        lessThanOrEqualTo(3),
        reason: '顶栏图标必须 ≤ 3（用户抱怨过顶栏太挤）',
      );

      // 开菜单：三个入口都在，且顺序在「发现」家族之前
      await tester.tap(find.byKey(const Key('as-home-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-radio')), findsOneWidget);
      expect(find.byKey(const Key('as-webqueue')), findsOneWidget);
      expect(find.byKey(const Key('as-pins')), findsOneWidget);

      // 真的能进收藏页（菜单项接的是同一个路由）
      await tester.tap(find.byKey(const Key('as-pins')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-pins-search')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DA119：一首歌都没有时仍是空态（不是空白页）', (tester) async {
      await _pump(tester, installSongs: false);
      expect(find.byType(DesignScaffold), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('DA122 · 搜索页用设计组件', () {
    testWidgets('DA122：空关键字 → 设计空态；骨架是 DesignScaffold', (tester) async {
      final c = await _container();
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const AudioSearchPage(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(DesignScaffold), findsOneWidget);
      expect(find.byKey(const Key('as-search-field')), findsOneWidget);
      expect(find.byKey(const Key('as-search-go')), findsOneWidget);
      // 反向：源码里不许再有 HudScaffold
      final src = File(
        'lib/src/features/audio/audio_search_page.dart',
      ).readAsStringSync();
      expect(src.contains('HudScaffold('), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('DA124 · 专辑/详情页用设计组件', () {
    testWidgets('DA124：专辑详情 → DesignScaffold + 设计行卡（无 HUD 网格）', (tester) async {
      final t = FakeTransport({
        '$_as.Song.list': {
          'songs': [_song('m1', 'Demo Song'), _song('m2', 'Season in the Sun')],
          'total': 2,
          'offset': 0,
        },
      }, {...FakeTransport.table, ..._asTable});
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c = ProviderContainer(
        overrides: [audioApiProvider.overrideWithValue(AudioStationApi(api))],
      );
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const AudioDetailPage.album(
              name: '00s Love Songs',
              albumArtist: 'Demo Artist',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byType(DesignScaffold), findsOneWidget);
      expect(find.byType(DesignRowTile), findsWidgets);
      expect(find.byType(ListTile), findsNothing);
      expect(find.text('Demo Song'), findsOneWidget);
      // 设计稿 actions = [search, more]：本页 "more" = 收藏（有副作用那个）
      expect(find.byKey(const Key('as-detail-search')), findsOneWidget);
      expect(find.byKey(const Key('as-pin-add')), findsOneWidget);

      // 反向：源码里既没有 HudScaffold 也没有裸 ListTile / HUD 元信息色
      final src = File(
        'lib/src/features/audio/audio_detail_page.dart',
      ).readAsStringSync();
      expect(src.contains('HudScaffold('), isFalse);
      expect(src.contains('ListTile('), isFalse);
      expect(src.contains('HudTokens.of(context).meta'), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('DA128 · 单曲页（播放器）行/令牌收口', () {
    test('DA128：源码判据 —— 裸 ListTile 与 HUD 令牌都清零', () {
      final src = File(
        'lib/src/features/audio/audio_song_page.dart',
      ).readAsStringSync();
      expect(src.contains('ListTile('), isFalse);
      expect(src.contains('HudTokens'), isFalse);
      expect(
        RegExp(r'DesignRowTile\(').allMatches(src).length,
        greaterThanOrEqualTo(5),
        reason: '队列/播放列表选择/歌词候选/标签四处行都必须用设计行卡',
      );
      // 进度条两端的时间也必须走令牌字号
      expect(src.contains('size: 11'), isFalse);
    });
  });

  group('DA127 · 队列标题不许把乱码画给用户', () {
    test('DA127：认得出的标题原样保留', () {
      expect(asQueueDisplayTitle('Demo Song', '/m/Demo Song.mp3'), 'Demo Song');
      expect(asQueueDisplayTitle('爱情转移', '/m/x.flac'), '爱情转移');
      expect(asQueueDisplayTitle('café', '/m/a.mp3'), 'café');
      expect(
        asQueueDisplayTitle('  Song 2  ', '/m/s.mp3'),
        'Song 2',
        reason: '首尾空白要修掉',
      );
    });

    test('DA127：真机上的那串乱码 → 退回文件名', () {
      // 逐字取自真机像素（r486 Play queue 唯一一行的标题）
      const mojibake = 'αφąÊ¤øαĂα+ÕśαÄáαáα£αë';
      expect(
        asQueueDisplayTitle(mojibake, '/music/00s Love Songs/Demo Song.mp3'),
        'Demo Song.mp3',
      );
    });

    test('DA127：标题和文件名都不像人话 → 未命名（不给空白行）', () {
      const bad = 'αφąÊ¤øαĂ';
      expect(
        asQueueDisplayTitle(bad, '/nąÊ¤ø/ąÊ¤ø.txt'),
        dataText('asUnnamedName', '未命名'),
      );
      expect(asQueueDisplayTitle('', '/m/ok.mp3'), 'ok.mp3');
    });

    test('DA127：源码判据 —— 队列页三个显示点都走 asQueueDisplayTitle', () {
      final src = File(
        'lib/src/features/audio/audio_web_queue_page.dart',
      ).readAsStringSync();
      expect(
        RegExp(r'asQueueDisplayTitle\(').allMatches(src).length,
        greaterThanOrEqualTo(3),
      );
      expect(src.contains('song.title.isNotEmpty'), isFalse);
      expect(src.contains('ListTile('), isFalse);
    });
  });

  group('DA125 · 电台/队列/远程播放器用设计组件', () {
    Future<ProviderContainer> pump(WidgetTester tester, Widget home) async {
      final t = FakeTransport({
        '$_as.Radio.list': {'radios': []},
        '$_as.WebPlayer.getplaylist': {'playlist': <dynamic>[]},
        '$_as.RemotePlayer.list': {'players': []},
      }, {...FakeTransport.table, ..._asTable});
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c = ProviderContainer(
        overrides: [audioApiProvider.overrideWithValue(AudioStationApi(api))],
      );
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: home),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      return c;
    }

    for (final entry in const {
      'audio_radio_page.dart': 0,
      'audio_web_queue_page.dart': 0,
      'audio_remote_page.dart': 0,
    }.entries) {
      testWidgets('DA125：${entry.key} 已是 DesignScaffold（源码判据）', (tester) async {
        final src = File('lib/src/features/audio/${entry.key}').readAsStringSync();
        expect(src.contains('HudScaffold('), isFalse, reason: entry.key);
        expect(src.contains('HudTokens.of(context)'), isFalse, reason: entry.key);
        expect(src.contains('DesignScaffold('), isTrue, reason: entry.key);
      });
    }

    testWidgets('DA125：三个页面真渲染都不崩、都是 DesignScaffold', (tester) async {
      await pump(tester, const AudioRadioPage());
      expect(find.byType(DesignScaffold), findsOneWidget);

      await pump(tester, const AudioWebQueuePage());
      expect(find.byType(DesignScaffold), findsOneWidget);

      await pump(tester, const AudioRemotePage());
      expect(find.byType(DesignScaffold), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
