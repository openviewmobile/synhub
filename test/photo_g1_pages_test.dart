// G1 批次（相册未实现功能补齐）—— **页面层**离线测试。
//
// 每行一条页面用例（全部离线 mock，不连真机、不碰平台通道）：
//   * P4  时间轴上的「缩略图密度」控件改列数（并落盘）；
//   * P15 HEIC 大图失败 → 生成预览引导 → 确认后才发写请求（取消则零请求）；
//   * P16 RAW 大图失败 → 兜底文案（且**不**给"生成预览"按钮）；
//   * P24 搜索页空态列出「最近搜索」+ 单条删除 + 全部清除；
//   * P25 全局搜索页出现「照片」分组并可点开；
//   * P29 多选删除 → Snackbar 撤销（撤销 = 零请求；不撤销到点才真删）；
//   * P48 设置页播放设置（HTTP / 端口 / 忽略证书错误）落盘；
//   * P49 大图页幻灯片：开始 → 自动翻页 → 设置 → 停止。
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/media/media_player.dart'
    show mediaPlayerAdapterFactoryProvider, MediaPlayerAdapter;
import 'package:synhub/src/features/media/media_source.dart'
    show MediaSource;
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_c2_sections.dart'
    show PhotoSearchPage;
import 'package:synhub/src/features/photos/photo_delete_undo.dart';
import 'package:synhub/src/features/photos/photo_grid_density.dart';
import 'package:synhub/src/features/photos/photo_playback_settings.dart';
import 'package:synhub/src/features/photos/photo_prefs_store.dart';
import 'package:synhub/src/features/photos/photo_format_fallback.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_search_history.dart';
import 'package:synhub/src/features/photos/photo_slideshow.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';
import 'package:synhub/src/features/photos/photo_wave3_page.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';
import 'package:synhub/src/features/search/global_search_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

// ---------------------------------------------------------------- 脚手架

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

class _MemPrefs implements PhotoPrefsStore {
  _MemPrefs([Map<String, String>? seed]) {
    if (seed != null) data.addAll(seed);
  }
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);
  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

class _FixedColumns extends PhotoGridColumnsNotifier {
  _FixedColumns(this.value);
  final int value;

  @override
  int build() => value;
}

class _FixedSlideshow extends PhotoSlideshowSettingsNotifier {
  _FixedSlideshow(this.value);
  final PhotoSlideshowSettings value;

  @override
  PhotoSlideshowSettings build() => value;
}

ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values) s: AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 9, 23),
    );

class _FakeVideoAdapter implements MediaPlayerAdapter {
  final _changes = StreamController<void>.broadcast();

  @override
  Future<void> load(MediaSource source) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => null;
  @override
  bool get playing => false;
  @override
  bool get ready => true;
  @override
  double get speed => 1;
  @override
  String? get error => null;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(color: Colors.black);
  @override
  Stream<void> get changes => _changes.stream;
}

const _fotoTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Browse.Album': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Browse.Folder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Download': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.Foto.Streaming': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Search.Search': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.Foto.RegeneratePreview': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Map<String, dynamic> _item(
  String id, {
  String name = 'IMG',
  String ext = 'jpg',
  int day = 18,
}) => {
  'id': id,
  'filename': '${name}_$id.$ext',
  'filesize': 2048,
  'time': DateTime(2026, 9, day, 10).millisecondsSinceEpoch ~/ 1000,
  'indexed_time': DateTime(2026, 9, day, 11).millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': 'photo',
  'additional': {
    'thumbnail': {
      'sm': 'sm_$id',
      'm': 'm_$id',
      'xl': 'xl_$id',
      'cache_key': 'ck_$id',
    },
  },
};

FotoItemDto _dto(String id, {String ext = 'jpg', String name = 'IMG'}) =>
    FotoItemDto.fromJson(_item(id, name: name, ext: ext));

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
}) {
  final t = FakeTransport(
    {...responses},
    {...FakeTransport.table, ..._fotoTable},
  );
  t.downloadBytes = _png;
  t.onCall = (params) {
    final method = '${params['method']}';
    if (method == 'get' && '${params['api']}'.contains('Setting.User')) {
      return {
        'team_space_permission': 'none',
        'enable_person': false,
        'timeline_group_unit': 'day',
        'item_sort_by': 'takentime',
        'sort_direction': 'desc',
      };
    }
    return responses['${params['api']}.$method'] ?? const <String, dynamic>{};
  };
  t.failures.addAll(failures);
  return t;
}

int _calls(FakeTransport t, String api, String method) =>
    t.calls.where((c) => c['api'] == api && c['method'] == method).length;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  Set<String> apis = const {
    'SYNO.Foto.Thumbnail',
    'SYNO.Foto.Browse.Item',
    'SYNO.Foto.Setting.User',
    'SYNO.Foto.Download',
    'SYNO.Foto.Search.Search',
    'SYNO.Foto.RegeneratePreview',
  },
  _MemPrefs? prefs,
  List<Object> extra = const [],
}) async {
  final t = _transport(responses: responses, failures: failures);
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: <Object>[
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis)),
      ),
      mediaPlayerAdapterFactoryProvider.overrideWithValue(
        () => _FakeVideoAdapter(),
      ),
      photoPrefsStoreProvider.overrideWithValue(prefs ?? _MemPrefs()),
      ...extra,
    ].cast(),
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await _settle(tester);
  return (t: t, c: c);
}

void main() {
  // ================================================================ P4

  testWidgets('P4 时间轴密度控件：选「密」→ 网格列数变 5 且落盘', (tester) async {
    final prefs = _MemPrefs();
    final boot = await _pump(
      tester,
      const PhotoBrowsePage(),
      responses: {
        'SYNO.Foto.Browse.Item.list': {
          'list': [_item('1'), _item('2'), _item('3', day: 17)],
        },
      },
      prefs: prefs,
      extra: [photoGridColumnsProvider.overrideWith(() => _FixedColumns(3))],
    );

    int columns() {
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid).first);
      final d = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      return d.crossAxisCount;
    }

    expect(columns(), 3);
    await tester.tap(find.byKey(const Key('photo-grid-density')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('密').last);
    await tester.pumpAndSettle();
    expect(columns(), 5);
    expect(boot.c.read(photoGridColumnsProvider), 5);
    expect(prefs.data[kPhotoGridColumnsSlot], '5');
  });

  // ================================================================ P50

  testWidgets('P50 第三方应用打开：回调确实被触发；未给回调 ⇒ 不渲染入口', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: PhotoFormatFallback(
            filename: 'a.dng',
            onDownload: () {},
            onOpenExternal: () => opened++,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('photo-format-fallback')), findsOneWidget);
    expect(find.byKey(const Key('photo-format-open-external')), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-format-open-external')));
    await tester.pump();
    expect(opened, 1, reason: '点一次就回调一次，绝不静默吞掉');

    // 门控：没有外部打开能力时**不渲染**该入口（不能给一个点了没反应的按钮）
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: PhotoFormatFallback(filename: 'a.dng', onDownload: null),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('photo-format-open-external')), findsNothing);
  });

  // ================================================================ P15

  testWidgets('P15 HEIC：生成预览要二次确认；取消 → 零写请求', (tester) async {
    final boot = await _pump(
      tester,
      PhotoViewerPage(items: [_dto('1', ext: 'heic')]),
      failures: {'SYNO.Foto.Thumbnail': 102},
    );
    expect(find.byKey(const Key('photo-format-fallback')), findsOneWidget);
    expect(find.byKey(const Key('photo-heic-regenerate')), findsOneWidget);

    // 状态查询（只读）已经发过
    expect(
      _calls(boot.t, 'SYNO.Foto.RegeneratePreview', 'list_regenerating'),
      1,
    );

    // 取消 → 一个写请求都不发
    await tester.tap(find.byKey(const Key('photo-heic-regenerate')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      _calls(
        boot.t,
        'SYNO.Foto.RegeneratePreview',
        'regenerate_preview_by_nas',
      ),
      0,
    );
  });

  testWidgets('P15 HEIC：确认后发 regenerate_preview_by_nas（v1）并提示', (tester) async {
    final boot = await _pump(
      tester,
      PhotoViewerPage(items: [_dto('1', ext: 'heic')]),
      failures: {'SYNO.Foto.Thumbnail': 102},
    );
    await tester.tap(find.byKey(const Key('photo-heic-regenerate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-heic-regenerate-confirm')));
    await tester.pumpAndSettle();
    expect(
      _calls(
        boot.t,
        'SYNO.Foto.RegeneratePreview',
        'regenerate_preview_by_nas',
      ),
      1,
    );
    final call = boot.t.calls.lastWhere(
      (c) => c['method'] == 'regenerate_preview_by_nas',
    );
    expect(call['version'], '1');
    expect(find.byKey(const Key('photo-heic-regenerate-done')), findsOneWidget);
  });

  // ================================================================ P16

  testWidgets('P16 RAW：兜底文案出现，且没有「生成预览」按钮', (tester) async {
    await _pump(
      tester,
      PhotoViewerPage(
        items: [_dto('9', ext: 'dng', name: 'RAW')],
      ),
      failures: {'SYNO.Foto.Thumbnail': 102},
    );
    expect(find.byKey(const Key('photo-format-fallback')), findsOneWidget);
    expect(find.textContaining('RAW'), findsWidgets);
    expect(find.byKey(const Key('photo-heic-regenerate')), findsNothing);
    // 两条出路：下载 / 用其他应用打开
    expect(find.byKey(const Key('photo-format-download')), findsOneWidget);
  });

  // ================================================================ P24

  testWidgets('P24 搜索空态列历史：可点、可删单条、可全部清除', (tester) async {
    final prefs = _MemPrefs({
      kPhotoSearchHistorySlot: encodePhotoSearchHistory(['cat', 'dog']),
    });
    final boot = await _pump(tester, const PhotoSearchPage(), prefs: prefs);
    expect(find.byKey(const Key('photo-search-history')), findsOneWidget);
    expect(
      find.byKey(const Key('photo-search-history-item-cat')),
      findsOneWidget,
    );

    // 单条删除
    await tester.tap(find.byKey(const Key('photo-search-history-remove-dog')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('photo-search-history-item-dog')),
      findsNothing,
    );
    expect(boot.c.read(photoSearchHistoryProvider), ['cat']);

    // 全部清除 → 回到原来的空态引导
    await tester.tap(find.byKey(const Key('photo-search-history-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-search-history')), findsNothing);
    expect(find.byKey(const Key('photo-c2-search-empty')), findsOneWidget);
    expect(prefs.data.containsKey(kPhotoSearchHistorySlot), isFalse);
  });

  testWidgets('P24 提交搜索会记进历史', (tester) async {
    final prefs = _MemPrefs();
    final boot = await _pump(
      tester,
      const PhotoSearchPage(),
      responses: {
        'SYNO.Foto.Search.Search.list_item': {
          'list': [_item('1')],
        },
      },
      prefs: prefs,
    );
    await tester.enterText(
      find.byKey(const Key('photo-c2-search-field')),
      'flower',
    );
    await tester.tap(find.byKey(const Key('photo-c2-search-go')));
    await _settle(tester);
    expect(boot.c.read(photoSearchHistoryProvider), ['flower']);
    expect(decodePhotoSearchHistory(prefs.data[kPhotoSearchHistorySlot]), [
      'flower',
    ]);
  });

  // ================================================================ P25

  testWidgets('P25 全局搜索出现照片分组并可点开大图', (tester) async {
    final boot = await _pump(
      tester,
      const GlobalSearchPage(),
      responses: {
        'SYNO.Foto.Search.Search.list_item': {
          'list': [_item('7', name: 'beach')],
        },
      },
    );
    await tester.enterText(
      find.byKey(const Key('global-search-field')),
      'beach',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);
    expect(_calls(boot.t, 'SYNO.Foto.Search.Search', 'list_item'), 1);
    expect(find.byKey(const Key('global-search-group-photos')), findsOneWidget);
    expect(find.byKey(const Key('global-search-photo-7')), findsOneWidget);

    await tester.tap(find.byKey(const Key('global-search-photo-7')));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerPage), findsOneWidget);
  });

  // ================================================================ P29

  testWidgets('P29 多选删除：Snackbar 撤销 → 零删除请求', (tester) async {
    final boot = await _pump(
      tester,
      Scaffold(
        body: PhotoSelectionBar(
          items: [_dto('1'), _dto('2')],
          space: FotoSpace.personal,
          onClear: () {},
          onAddToAlbum: () {},
        ),
      ),
      extra: [
        photoDeleteGraceProvider.overrideWithValue(const Duration(seconds: 5)),
      ],
    );
    await tester.tap(find.byKey(const Key('photo-selection-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-selection-delete-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-delete-undo-snackbar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('photo-delete-undo-action')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-delete-undone')), findsOneWidget);
    // 撤销后即使过了窗口也不该发请求
    await tester.pump(const Duration(seconds: 6));
    await _settle(tester);
    expect(_calls(boot.t, 'SYNO.Foto.Browse.Item', 'delete'), 0);
  });

  testWidgets('P29 多选删除：不撤销 → 过了窗口才真删', (tester) async {
    final boot = await _pump(
      tester,
      Scaffold(
        body: PhotoSelectionBar(
          items: [_dto('1')],
          space: FotoSpace.personal,
          onClear: () {},
          onAddToAlbum: () {},
        ),
      ),
      responses: {
        'SYNO.Foto.Browse.Item.delete': {'id': <int>[]},
      },
      extra: [
        photoDeleteGraceProvider.overrideWithValue(const Duration(seconds: 2)),
      ],
    );
    await tester.tap(find.byKey(const Key('photo-selection-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-selection-delete-confirm')));
    await tester.pumpAndSettle();
    // 窗口内还没删
    expect(_calls(boot.t, 'SYNO.Foto.Browse.Item', 'delete'), 0);
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);
    expect(_calls(boot.t, 'SYNO.Foto.Browse.Item', 'delete'), 1);
    final call = boot.t.calls.lastWhere((c) => c['method'] == 'delete');
    expect(call['version'], '7');
  });

  // ================================================================ P48

  testWidgets('P48 播放设置：开关与端口落盘，且不发任何请求', (tester) async {
    final prefs = _MemPrefs();
    final boot = await _pump(
      tester,
      const PhotoAlbumSettingsPage(),
      prefs: prefs,
      apis: const {},
    );
    expect(find.byKey(const Key('photo-playback-settings')), findsOneWidget);

    // HTTP 开关打开 → 出现端口输入框
    await tester.tap(find.byKey(const Key('photo-playback-http')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-playback-http-port')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('photo-playback-http-port')),
      '8080',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('photo-playback-cert')));
    await tester.pumpAndSettle();

    final saved = PhotoPlaybackSettings.parse(
      prefs.data[kPhotoPlaybackSettingsSlot],
    );
    expect(saved.useHttp, isTrue);
    expect(saved.httpPort, 8080);
    expect(saved.ignoreCert, isTrue);
    expect(boot.c.read(photoPlaybackSettingsProvider), saved);
  });

  testWidgets('P48 非法端口：报错且不落盘非法值', (tester) async {
    final prefs = _MemPrefs();
    await _pump(
      tester,
      const PhotoAlbumSettingsPage(),
      prefs: prefs,
      apis: const {},
    );
    await tester.tap(find.byKey(const Key('photo-playback-http')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('photo-playback-http-port')),
      '99999',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('端口不正确'), findsOneWidget);
    final saved = PhotoPlaybackSettings.parse(
      prefs.data[kPhotoPlaybackSettingsSlot] ?? '{}',
    );
    expect(saved.httpPort, isNull);
  });

  // ================================================================ P49

  testWidgets('P49 幻灯片：开始 → 自动翻页 → 改设置 → 停止', (tester) async {
    final prefs = _MemPrefs();
    final boot = await _pump(
      tester,
      PhotoViewerPage(items: [_dto('1'), _dto('2'), _dto('3')]),
      prefs: prefs,
      extra: [
        photoSlideshowSettingsProvider.overrideWith(
          () => _FixedSlideshow(const PhotoSlideshowSettings(seconds: 3)),
        ),
      ],
    );
    expect(find.byKey(const Key('photo-slideshow-bar')), findsNothing);

    await tester.tap(find.byKey(const Key('photo-slideshow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-slideshow-bar')), findsOneWidget);
    expect(find.textContaining('1/3'), findsOneWidget);

    // 到点自动翻到第 2 张
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('2/3'), findsOneWidget);

    // 设置：速度 15 秒
    await tester.tap(find.byKey(const Key('photo-slideshow-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-slideshow-speed-15')));
    await tester.pumpAndSettle();
    expect(boot.c.read(photoSlideshowSettingsProvider).seconds, 15);

    // 关掉设置面板（点遮罩）再停止
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('photo-slideshow-settings-sheet')),
      findsNothing,
    );

    // ★★★ r332：**FAB 不许盖住「停止幻灯片」**。Scaffold 把右下角收藏 FAB 画在 body 之上
    // 并优先命中手势；真实主题下按钮变宽 ⇒ 修前停止按钮中心 (728.3,572) 落在 FAB
    // `LTRB(728,528,784,584)` 里（点"停止"会点到收藏）。先钉住"中心不在 FAB 内"，
    // 再点它 —— 修前这条会红。
    final stopCenter = tester.getCenter(
      find.byKey(const Key('photo-slideshow-stop')),
    );
    expect(
      tester.getRect(find.byType(FloatingActionButton)).contains(stopCenter),
      isFalse,
      reason: '「停止幻灯片」的中心不能被收藏 FAB 压住（FAB 优先命中手势）',
    );

    // 停止
    await tester.tap(find.byKey(const Key('photo-slideshow-stop')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-slideshow-bar')), findsNothing);
  });

  // ★★★ r332：**真机几何 375x814**（LGE-AN10：1148x2492 @490dpi ⇒ 375×814dp）。
  // 真机像素抓到的缺陷：控制条上两个**带文字**的动作在小屏吃掉几乎整条宽度
  // （`Slideshow settings` 167dp + `Stop slideshow` 144dp = 311dp，控制条可用才 343dp）
  // ⇒ 中间的间隔文案被 `Expanded` 压到只剩约 10dp，**一个字一行竖着排**
  // （`docs/evidence-r332/img/r332_07_android_slideshow_vertical_text.png`）。
  // 这里钉两条机制量（不是"看着还行"）：① 间隔文案**最多两行**且**宽不是窄条**；
  // ② 「停止幻灯片」中心仍不在收藏 FAB 里。修前（带文字按钮）这两条都红。
  testWidgets('P49b 真机 375dp：控制条不把间隔文案压成竖排', (tester) async {
    tester.view.physicalSize = const Size(1148, 2492);
    tester.view.devicePixelRatio = 490 / 160;
    addTearDown(tester.view.reset);

    final prefs = _MemPrefs();
    await _pump(
      tester,
      PhotoViewerPage(items: [_dto('1'), _dto('2')]),
      prefs: prefs,
      extra: [
        photoSlideshowSettingsProvider.overrideWith(
          () => _FixedSlideshow(const PhotoSlideshowSettings(seconds: 5)),
        ),
      ],
    );
    await tester.tap(find.byKey(const Key('photo-slideshow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-slideshow-bar')), findsOneWidget);

    final interval = find.byKey(const Key('photo-slideshow-interval'));
    final size = tester.getSize(interval);
    expect(
      size.height,
      lessThanOrEqualTo(52),
      reason: '间隔文案最多两行，不能被压成"一字一列"（真机像素 §6.6）',
    );
    expect(
      size.width,
      greaterThanOrEqualTo(96),
      reason: '间隔文案的宽不能被两个动作按钮挤成窄条',
    );

    final stopCenter = tester.getCenter(
      find.byKey(const Key('photo-slideshow-stop')),
    );
    expect(
      tester.getRect(find.byType(FloatingActionButton)).contains(stopCenter),
      isFalse,
      reason: '「停止幻灯片」的中心不能被收藏 FAB 压住',
    );
  });

  testWidgets('P49 只有视频时：给「没有可放映的照片」提示，不进入幻灯片', (tester) async {
    final dto = FotoItemDto.fromJson({
      ..._item('5'),
      'type': 'video',
      'filename': 'clip_5.mp4',
    });
    await _pump(tester, PhotoViewerPage(items: [dto]));
    await tester.tap(find.byKey(const Key('photo-slideshow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-slideshow-empty')), findsOneWidget);
    expect(find.byKey(const Key('photo-slideshow-bar')), findsNothing);
  });

  // ================================================================ 回收：PhotoGrid 默认跟随密度

  testWidgets('P4 接线：未显式给列数时，PhotoGrid 跟随用户密度档', (tester) async {
    await _pump(
      tester,
      const Scaffold(
        body: PhotoGrid(items: [], space: FotoSpace.personal, onTap: _noop),
      ),
      extra: [photoGridColumnsProvider.overrideWith(() => _FixedColumns(5))],
    );
    final grid = tester.widget<GridView>(find.byType(GridView).first);
    final d = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(d.crossAxisCount, 5);
  });
}

void _noop(int index) {}
