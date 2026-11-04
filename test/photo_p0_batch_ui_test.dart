// 相册 P0：**批量操作条**（下载/删除/收藏/加入相册/打标签/移出相册）与
// **大图页删除 + 单项下载落盘 + 视频画质三档** 的离线承重。
//
// 证据/口径见 `docs/photo-p0-implementation.md` 与
// `test/photo_p0_delete_quality_test.dart` 的文件头。本文件只测"接线 + 反馈"：
//   * 每个批量操作真的打到了哪个 API、参数形态对不对；
//   * **成功 N / 失败 M** 如实显示（不静默失败）；
//   * 单项下载**字节落盘到磁盘路径**（审计 §7 #3 指出这条以前没有 mock）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
import 'package:synhub/src/features/photos/photo_delete_undo.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';
import 'package:synhub/src/features/photos/photo_share.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;
import 'support/pump_until.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

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
  'SYNO.Foto.Browse.NormalAlbum': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Album': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Download': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.Foto.Streaming': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 最小假播放器：内嵌播放页不碰平台通道即可。
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

Map<String, dynamic> _itemJson(String id, {bool video = false}) => {
  'id': id,
  'filename': video ? 'MOV_$id.mp4' : 'IMG_$id.jpg',
  'filesize': 1024,
  'time': DateTime(2026, 9, 18, 10).millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': video ? 'video' : 'photo',
  'additional': {
    'thumbnail': {'sm': 'sm_$id', 'cache_key': 'ck_$id'},
    'favorite': false,
  },
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

/// 挂一个装了相册 provider 的容器；[child] 走进 `MaterialApp` 的首页。
Future<({FakeTransport t, ProviderContainer c, Directory dir})> _pump(
  WidgetTester tester,
  Widget child, {
  Map<String, Map<String, dynamic>> byApi = const {},
  Map<String, int> failures = const {},
  List<Object> extra = const [],
}) async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._fotoTable});
  t.downloadBytes = _png;
  t.onCall = (params) => byApi['${params['api']}.${params['method']}'];
  t.failures.addAll(failures);
  final api = await _loggedIn(t);
  // ⚠️ `testWidgets` 跑在 FakeAsync 里：**真异步的 dart:io 调用不会完成**，
  // 所以临时目录用同步 API 建，下载落盘的断言放 `tester.runAsync`。
  final dir = Directory.systemTemp.createTempSync('photo-p0-test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      photoDownloadDirectoryProvider.overrideWithValue(() async => dir),
      // P29 起删除是"延迟删除 + Snackbar 撤销"：本文件只测批量删除的**汇报口径**，
      // 所以把宽限期压到 0（撤销窗口语义由 test/photo_g1_pages_test.dart 专测）。
      photoDeleteGraceProvider.overrideWithValue(Duration.zero),
      mediaPlayerAdapterFactoryProvider.overrideWithValue(
        () => _FakeVideoAdapter(),
      ),
      ...extra.cast(),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (t: t, c: c, dir: dir);
}

/// 在**真实异步**里点一个按钮并等落盘完成（`File.writeAsBytes` 是真 IO）。
Future<void> _tapAndWaitIo(
  WidgetTester tester,
  Finder finder,
  Directory dir,
) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // 只看"有文件"会在**文件已创建、字节还没 flush** 时提前跳出（全量跑时
      // 负载高，紧接着的 `readAsBytesSync` 就会读到空数组）。这里要求真写进去。
      final files = dir.listSync().whereType<File>();
      if (files.any((f) => f.lengthSync() > 0)) break;
    }
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 只挂批量操作条
Future<({FakeTransport t, ProviderContainer c, Directory dir})> _pumpBar(
  WidgetTester tester, {
  required List<FotoItemDto> items,
  Map<String, Map<String, dynamic>> byApi = const {},
  Map<String, int> failures = const {},
  String? albumId,
  VoidCallback? onClear,
  VoidCallback? onAddToAlbum,
  FotoSpace space = FotoSpace.personal,
  List<Object> extra = const [],
}) => _pump(
  tester,
  Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: PhotoSelectionBar(
        items: items,
        space: space,
        albumId: albumId,
        onClear: onClear ?? () {},
        onAddToAlbum: onAddToAlbum ?? () {},
      ),
    ),
  ),
  byApi: byApi,
  failures: failures,
  extra: extra,
);


/// P52：假分享桥（可控 canShare / share 并记录参数）。
class _FakeShareBridge implements PhotoShareBridge {
  _FakeShareBridge({this.can = true});

  bool can;
  final List<Map<String, String>> shared = [];

  @override
  Future<bool> canShare({required String path, required String mime}) async => can;

  @override
  Future<bool> share({
    required String path,
    required String name,
    required String mime,
  }) async {
    shared.add({'path': path, 'name': name, 'mime': mime});
    return true;
  }
}

void main() {
  group('P52 发送到（复用 MediaOpenBridge）', () {
    testWidgets('点「发送到」：先落盘再交给桥，参数带 filename/mime', (tester) async {
      final bridge = _FakeShareBridge();
      final r = await _pumpBar(
        tester,
        items: [FotoItemDto.fromJson(_itemJson('11'))],
        extra: [photoShareBridgeProvider.overrideWithValue(bridge)],
      );
      expect(find.byKey(const Key('photo-selection-share')), findsOneWidget);
      await _tapAndWaitIo(
        tester,
        find.byKey(const Key('photo-selection-share')),
        r.dir,
      );
      // ★ r447：落盘之后**还**要等桥被真的调到（假红就是"文件有了、shared 还是 []"）
      await pumpUntil(tester, () => bridge.shared.isNotEmpty);
      expect(bridge.shared, hasLength(1));
      expect(bridge.shared.single['name'], 'IMG_11.jpg');
      expect(bridge.shared.single['mime'], 'image/jpeg');
      expect(bridge.shared.single['path'], startsWith(r.dir.path));
    });

    testWidgets('桥说"没有应用能接" ⇒ 明确失败提示，不谎报成功', (tester) async {
      final bridge = _FakeShareBridge(can: false);
      final r = await _pumpBar(
        tester,
        items: [FotoItemDto.fromJson(_itemJson('11'))],
        extra: [photoShareBridgeProvider.overrideWithValue(bridge)],
      );
      await _tapAndWaitIo(
        tester,
        find.byKey(const Key('photo-selection-share')),
        r.dir,
      );
      await pumpUntilFound(tester, find.textContaining('失败'));
      expect(bridge.shared, isEmpty);
      expect(find.textContaining('失败'), findsOneWidget);
    });
  });

  group('批量操作条（P0-2）', () {
    testWidgets('五个能力都在：下载 / 删除 / 收藏 / 加入相册 / 打标签', (tester) async {
      final items = [
        FotoItemDto.fromJson(_itemJson('11')),
        FotoItemDto.fromJson(_itemJson('12')),
      ];
      await _pumpBar(tester, items: items);
      expect(find.byKey(const Key('photo-selection-download')), findsOneWidget);
      expect(find.byKey(const Key('photo-selection-delete')), findsOneWidget);
      expect(find.byKey(const Key('photo-selection-favorite')), findsOneWidget);
      expect(find.byKey(const Key('photo-selection-album')), findsOneWidget);
      expect(find.byKey(const Key('photo-selection-tag')), findsOneWidget);
      // 不在相册里 → 没有"移出相册"
      expect(find.byKey(const Key('photo-selection-remove')), findsNothing);
    });

    testWidgets('批量删除：确认后 delete v7 + id 数字数组，反馈"已删除 2 项"', (tester) async {
      var cleared = false;
      final items = [
        FotoItemDto.fromJson(_itemJson('11')),
        FotoItemDto.fromJson(_itemJson('12')),
      ];
      final r = await _pumpBar(
        tester,
        items: items,
        onClear: () => cleared = true,
        byApi: {
          'SYNO.Foto.Browse.Item.delete': {'error_list': <dynamic>[]},
        },
      );
      await tester.tap(find.byKey(const Key('photo-selection-delete')));
      await tester.pumpAndSettle();
      // 确认框必须给出"回收站"口径
      expect(find.textContaining('回收站'), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-selection-delete-confirm')));
      await tester.pumpAndSettle();
      // P29：延迟删除要等宽限期（这里归零）走完并回包后才汇报
      await tester.pump();
      await tester.pumpAndSettle();

      final call = r.t.calls.lastWhere((c) => c['method'] == 'delete');
      expect(call['api'], 'SYNO.Foto.Browse.Item');
      expect('${call['version']}', '7');
      expect(call['id'], '[11,12]');
      expect(find.text('已删除 2 项'), findsOneWidget);
      expect(cleared, isTrue);
    });

    testWidgets('批量删除部分失败 → "成功 1 项，失败 1 项"（不静默）', (tester) async {
      final items = [
        FotoItemDto.fromJson(_itemJson('11')),
        FotoItemDto.fromJson(_itemJson('12')),
      ];
      await _pumpBar(
        tester,
        items: items,
        byApi: {
          'SYNO.Foto.Browse.Item.delete': {
            'error_list': [
              {'id': 12},
            ],
          },
        },
      );
      await tester.tap(find.byKey(const Key('photo-selection-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-selection-delete-confirm')));
      await tester.pumpAndSettle();
      // P29：延迟删除要等宽限期（这里归零）走完并回包后才汇报
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.textContaining('成功 1 项，失败 1 项'), findsOneWidget);
    });

    testWidgets('批量删除整批失败 → "全部失败（2 项）"', (tester) async {
      final items = [
        FotoItemDto.fromJson(_itemJson('11')),
        FotoItemDto.fromJson(_itemJson('12')),
      ];
      await _pumpBar(
        tester,
        items: items,
        failures: {'SYNO.Foto.Browse.Item.delete': 500},
      );
      await tester.tap(find.byKey(const Key('photo-selection-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-selection-delete-confirm')));
      await tester.pumpAndSettle();
      // P29：延迟删除要等宽限期（这里归零）走完并回包后才汇报
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.textContaining('全部失败（2 项）'), findsOneWidget);
    });

    testWidgets('批量下载：force_download + item_id 数组，zip 真的落盘', (tester) async {
      final items = [
        FotoItemDto.fromJson(_itemJson('11')),
        FotoItemDto.fromJson(_itemJson('12')),
      ];
      final r = await _pumpBar(tester, items: items);
      // zip 字节（不是 PNG）
      r.t.downloadBytes = utf8.encode('PK\x03\x04fake-zip');
      await _tapAndWaitIo(
        tester,
        find.byKey(const Key('photo-selection-download')),
        r.dir,
      );

      final url = r.t.downloads.lastWhere(
        (u) => u.contains('SYNO.Foto.Download'),
      );
      expect(url, contains('method=download'));
      expect(url, contains('force_download=true'));
      expect(
        url.contains('[11,12]') || url.contains('%5B11%2C12%5D'),
        isTrue,
        reason: url,
      );

      final zips = r.dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.zip'))
          .toList();
      expect(zips, hasLength(1), reason: '批量下载必须有一个 zip 落盘');
      expect(zips.single.readAsBytesSync(), utf8.encode('PK\x03\x04fake-zip'));
      expect(find.textContaining('zip'), findsWidgets);
    });

    testWidgets('批量下载：服务端回空体 → 不落 0 字节 zip，如实提示', (tester) async {
      final items = [
        FotoItemDto.fromJson(_itemJson('11')),
        FotoItemDto.fromJson(_itemJson('12')),
      ];
      final r = await _pumpBar(tester, items: items);
      r.t.downloadBytes = Uint8List(0);
      await _tapAndWaitIo(
        tester,
        find.byKey(const Key('photo-selection-download')),
        r.dir,
      );

      final zips = r.dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.zip'))
          .toList();
      expect(zips, isEmpty, reason: '空响应不许写一个 0 字节 zip 假装成功');
      expect(find.textContaining('没有返回内容'), findsOneWidget);
    });

    testWidgets('批量收藏：set_favorite + id 数组 + favorite=true', (tester) async {
      final items = [
        FotoItemDto.fromJson(_itemJson('11')),
        FotoItemDto.fromJson(_itemJson('12')),
      ];
      final r = await _pumpBar(
        tester,
        items: items,
        byApi: {
          'SYNO.Foto.Browse.Item.set_favorite': {'success': true},
        },
      );
      await tester.tap(find.byKey(const Key('photo-selection-favorite')));
      await tester.pumpAndSettle();
      final call = r.t.calls.lastWhere((c) => c['method'] == 'set_favorite');
      expect(call['id'], '[11,12]');
      expect(call['favorite'], 'true');
    });

    testWidgets('相册内多选 → 多出"移出相册"，走 NormalAlbum/delete_item', (tester) async {
      final items = [FotoItemDto.fromJson(_itemJson('11'))];
      final r = await _pumpBar(
        tester,
        items: items,
        albumId: '7',
        byApi: {
          'SYNO.Foto.Browse.NormalAlbum.delete_item': {
            'error_list': <dynamic>[],
          },
        },
      );
      expect(find.byKey(const Key('photo-selection-remove')), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-selection-remove')));
      await tester.pumpAndSettle();
      final call = r.t.calls.lastWhere((c) => c['method'] == 'delete_item');
      expect(call['api'], 'SYNO.Foto.Browse.NormalAlbum');
      expect(call['id'], '7');
      expect(call['item'], '[11]');
    });
  });

  group('大图页：删除 + 单项下载落盘（P0-1 / 审计 §7 #3）', () {
    testWidgets('单项下载 → Download/download 的 item_id，字节落到磁盘路径', (tester) async {
      final items = [FotoItemDto.fromJson(_itemJson('42'))];
      final r = await _pump(
        tester,
        PhotoViewerPage(items: items),
        byApi: {
          'SYNO.Foto.Browse.Item.get': {
            'list': [_itemJson('42')],
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));

      final bytes = utf8.encode('JPEG-BYTES-42');
      r.t.downloadBytes = bytes;
      await _tapAndWaitIo(tester, find.byTooltip('下载'), r.dir);

      final url = r.t.downloads.lastWhere(
        (u) => u.contains('SYNO.Foto.Download'),
      );
      expect(url, contains('method=download'));
      expect(url.contains('item_id='), isTrue, reason: url);
      expect(url.contains('unit_id='), isFalse, reason: 'item 种类发 item_id');

      // 关键：**落盘路径**真的有文件、内容就是下载字节
      final saved = File('${r.dir.path}/IMG_42.jpg');
      expect(saved.existsSync(), isTrue, reason: '下载必须真的写到下载目录');
      expect(saved.readAsBytesSync(), bytes);
      expect(find.textContaining('IMG_42.jpg'), findsWidgets);
    });

    testWidgets('单项下载失败 → 如实报错（不静默）', (tester) async {
      final items = [FotoItemDto.fromJson(_itemJson('42'))];
      final r = await _pump(
        tester,
        PhotoViewerPage(items: items),
        byApi: {
          'SYNO.Foto.Browse.Item.get': {
            'list': [_itemJson('42')],
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      r.t.failures['SYNO.Foto.Download'] = 500;
      await tester.tap(find.byTooltip('下载'));
      await tester.pumpAndSettle();
      expect(find.textContaining('下载失败'), findsOneWidget);
      expect(
        Directory(r.dir.path).listSync().whereType<File>(),
        isEmpty,
        reason: '失败不许留下半个文件',
      );
    });

    testWidgets('大图页删除：确认框含回收站口径 → delete v7 → 反馈并退出', (tester) async {
      final items = [FotoItemDto.fromJson(_itemJson('42'))];
      final r = await _pump(
        tester,
        PhotoViewerPage(items: items),
        byApi: {
          'SYNO.Foto.Browse.Item.get': {
            'list': [_itemJson('42')],
          },
          'SYNO.Foto.Browse.Item.delete': {'error_list': <dynamic>[]},
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.textContaining('回收站'), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-viewer-delete-confirm')));
      await tester.pumpAndSettle();

      final call = r.t.calls.lastWhere((c) => c['method'] == 'delete');
      expect(call['api'], 'SYNO.Foto.Browse.Item');
      expect('${call['version']}', '7');
      expect(call['id'], '[42]');
      expect(find.textContaining('已删除 1 项'), findsOneWidget);
    });
  });

  group('视频画质三档（P0-3 界面）', () {
    testWidgets('视频项才显示画质菜单；三档可选且写进 provider', (tester) async {
      final items = [FotoItemDto.fromJson(_itemJson('7', video: true))];
      final r = await _pump(
        tester,
        PhotoViewerPage(items: items),
        byApi: {
          'SYNO.Foto.Browse.Item.get': {
            'list': [_itemJson('7', video: true)],
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(r.c.read(fotoVideoQualityBiasProvider), FotoVideoQualityBias.auto);

      await tester.tap(find.byKey(const Key('photo-video-quality')));
      await tester.pumpAndSettle();
      expect(find.text('自动'), findsOneWidget);
      expect(find.text('画质优先'), findsOneWidget);
      expect(find.text('速度优先'), findsOneWidget);

      await tester.tap(find.text('速度优先'));
      await tester.pumpAndSettle();
      expect(
        r.c.read(fotoVideoQualityBiasProvider),
        FotoVideoQualityBias.speed,
      );
      expect(find.textContaining('画质偏好'), findsOneWidget);
    });

    testWidgets('照片项没有画质菜单（不误导）', (tester) async {
      final items = [FotoItemDto.fromJson(_itemJson('8'))];
      await _pump(
        tester,
        PhotoViewerPage(items: items),
        byApi: {
          'SYNO.Foto.Browse.Item.get': {
            'list': [_itemJson('8')],
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('photo-video-quality')), findsNothing);
    });
  });
}
