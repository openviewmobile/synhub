// 相册 wave3（照片 EXIF / 相册缓存 / 相册列表显示偏好）离线测试。
//
// 覆盖：
//   * 接口层请求形状（api / method / version / params）：
//     `Browse.Item/get_exif`（**v1** + `id`）、`Download/get_cache_status`（**v2**）、
//     `Download/calculate_cache_size`（**v2**）、
//     `Browse.Album/get_album_list_display`（**v3**）；
//   * DTO 宽松解析（只认有出处的字段名；未知键进 rawKeys 不上屏；空回包明确空态）；
//   * 门控：能力位缺失 → 隐藏且不发请求；`105`/`160` → 隐藏；`119`/`106` → 会话提示；
//     其它 → fail-open；
//   * 页面层：相册设置（缓存只读、状态非 done 不显示成"已完成"）、EXIF 小节空态。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/dto/foto_wave3_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_local_cache.dart';
import 'package:synhub/src/features/photos/photo_prefs_store.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';
import 'package:synhub/src/features/photos/photo_wave3_page.dart';
import 'package:synhub/src/features/photos/photo_wave3_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _wave3Table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.Foto.Browse.Album': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Browse.NormalAlbum': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
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
};

const _allWave3Apis = {
  'SYNO.Foto.Browse.Item',
  'SYNO.Foto.Browse.Album',
  'SYNO.Foto.Browse.NormalAlbum',
  'SYNO.Foto.Browse.Folder',
  'SYNO.Foto.Thumbnail',
  'SYNO.Foto.Setting.User',
  'SYNO.Foto.Download',
};

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

/// 显式把 Photos 定为 `available`（不经过 `classifyApiTable` 的 required 判定），
/// 这样"能力位在集合里没有"就**一定**等于 `hasApi == false`，门控可被单点钉死。
ServiceAvailabilitySnapshot _snapForce(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values) s: AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 9, 23),
    );

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
    {...FakeTransport.table, ..._wave3Table},
  );
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (key == 'SYNO.Foto.Setting.User.get') {
      return {'team_space_permission': 'none', 'timeline_group_unit': 'day'};
    }
    return responses[key] ?? const <String, dynamic>{};
  };
  t.failures.addAll(failures);
  return t;
}

Map<String, dynamic> _item(String id) => {
  'id': id,
  'filename': 'IMG_$id.jpg',
  'filesize': 2048,
  'time': DateTime(2026, 9, 18, 10).millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': 'photo',
  'additional': {
    'thumbnail': {'sm': 'sm_$id', 'm': 'm_$id', 'cache_key': 'ck_$id'},
  },
};

int _callCount(FakeTransport t, String key) =>
    t.calls.where((c) => '${c['api']}.${c['method']}' == key).length;

Map<String, dynamic> _lastCall(FakeTransport t, String key) => t.calls
    .lastWhere((c) => '${c['api']}.${c['method']}' == key)
    .map((k, v) => MapEntry(k, v));

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
  Set<String> apis = _allWave3Apis,
  List<Object> extra = const [],
}) async {
  final t = _transport(responses: responses, failures: failures);
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snapForce(apis)),
      ),
      ...extra.cast(),
    ],
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

/// 内存版本地缓存（P53 页面用例：**不做任何文件 I/O**）。
class _FakeCache extends PhotoLocalCache {
  _FakeCache(this._stats) : super(root: Directory.systemTemp);

  PhotoLocalCacheStats _stats;
  final List<int> enforceCalls = [];
  int clearCalls = 0;

  @override
  Future<PhotoLocalCacheStats> stats() async => _stats;

  @override
  Future<int> clear() async {
    clearCalls++;
    final freed = _stats.bytes;
    _stats = const PhotoLocalCacheStats(bytes: 0, fileCount: 0);
    return freed;
  }

  @override
  Future<int> enforceLimit(int maxBytes) async {
    enforceCalls.add(maxBytes);
    return 0;
  }
}

/// 内存版相册偏好（P53 用例：验"档位落盘"）。
class _MemPrefs implements PhotoPrefsStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // ================================================================ 接口层

  group('照片 EXIF 接口（wave3）', () {
    test('getExif：Browse.Item/get_exif v1 + id 数字数组', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Item.get_exif': {
            'camera': 'LGE-AN10',
            'aperture': 'F1.8',
          },
        },
      );
      final api = await _loggedIn(t);
      final exif = await FotoApi(api).getExif('12');
      expect(exif.camera, 'LGE-AN10');
      expect(exif.aperture, 'F1.8');
      final call = _lastCall(t, 'SYNO.Foto.Browse.Item.get_exif');
      expect(call['version'], '1');
      expect(jsonDecode(call['id'] as String), [12]);
    });

    test('getExif：非数字 id → 不发请求（空 DTO）', () async {
      final t = _transport();
      final api = await _loggedIn(t);
      expect((await FotoApi(api).getExif('abc')).isEmpty, isTrue);
      expect(_callCount(t, 'SYNO.Foto.Browse.Item.get_exif'), 0);
    });

    test('getExif：宽松解析（exif 嵌套 / list 形态 / 未知键进 rawKeys）', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Item.get_exif': {
            'exif': {
              'focal_length': '5.4 mm',
              'iso': 'ISO640',
              'owner_id': '991', // 内部字段名 → 不上屏
              'mystery': 'x', // 认不出 → 不上屏
            },
          },
        },
      );
      final api = await _loggedIn(t);
      final exif = await FotoApi(api).getExif('7');
      expect(exif.focalLength, '5.4 mm');
      expect(exif.iso, 'ISO640');
      expect(
        exif.fields.map((f) => f.key),
        containsAll(['focal_length', 'iso']),
      );
      expect(exif.rawKeys, contains('owner_id'));
      expect(exif.rawKeys, contains('mystery'));
      // 认不出的字段绝不进 fields（不上屏）
      expect(exif.fields.map((f) => f.key), isNot(contains('mystery')));
    });

    test('getExif：空回包 → isEmpty（明确空态，不是 0 项）', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Browse.Item.get_exif': <String, dynamic>{}},
      );
      final api = await _loggedIn(t);
      expect((await FotoApi(api).getExif('7')).isEmpty, isTrue);
    });

    test('getExif：裸 list 形态也能认', () {
      final dto = FotoExifDto.fromJson({
        'list': [
          {'camera': 'X', 'lens': 'L'},
        ],
      });
      expect(dto.camera, 'X');
      expect(dto.lens, 'L');
    });
  });

  group('相册缓存接口（wave3）', () {
    test('getCacheStatus：Download/get_cache_status v2 → status', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Download.get_cache_status': {'status': 'done'},
        },
      );
      final api = await _loggedIn(t);
      final dto = await FotoApi(api).getCacheStatus();
      expect(dto.status, 'done');
      expect(dto.isDone, isTrue);
      final call = _lastCall(t, 'SYNO.Foto.Download.get_cache_status');
      expect(call['version'], '2');
    });

    test('getCacheStatus：非 done 一律不 isDone', () {
      expect(
        FotoCacheStatusDto.fromJson({'status': 'processing'}).isDone,
        false,
      );
      expect(
        FotoCacheStatusDto.fromJson({'status': 'processing'}).isProcessing,
        true,
      );
      expect(FotoCacheStatusDto.fromJson({'status': 'weird'}).isDone, false);
      expect(FotoCacheStatusDto.fromJson(<String, dynamic>{}).isDone, false);
      expect(FotoCacheStatusDto.fromJson(null).isEmpty, isTrue);
    });

    test(
      'calculateCacheSize：Download/calculate_cache_size v2 → cache_size',
      () async {
        final t = _transport(
          responses: {
            'SYNO.Foto.Download.calculate_cache_size': {'cache_size': 4096},
          },
        );
        final api = await _loggedIn(t);
        final dto = await FotoApi(api).calculateCacheSize();
        expect(dto.bytes, 4096);
        final call = _lastCall(t, 'SYNO.Foto.Download.calculate_cache_size');
        expect(call['version'], '2');
      },
    );

    test('calculateCacheSize：缺 cache_size → bytes 为 null（不伪装 0）', () {
      expect(FotoCacheSizeDto.fromJson(<String, dynamic>{}).hasValue, isFalse);
      expect(FotoCacheSizeDto.fromJson({'cache_size': null}).hasValue, isFalse);
      expect(FotoCacheSizeDto.fromJson({'other': 5}).hasValue, isFalse);
    });
  });

  group('相册列表显示接口（wave3）', () {
    test(
      'getAlbumListDisplay：Browse.Album/get_album_list_display v3',
      () async {
        final t = _transport(
          responses: {
            'SYNO.Foto.Browse.Album.get_album_list_display': {
              'album_display_type': 'all_album',
            },
          },
        );
        final api = await _loggedIn(t);
        final dto = await FotoApi(api).getAlbumListDisplay();
        expect(dto.isAllAlbums, isTrue);
        final call = _lastCall(
          t,
          'SYNO.Foto.Browse.Album.get_album_list_display',
        );
        expect(call['version'], '3');
      },
    );

    test('album_display_type：my_album / 未识别值', () {
      expect(
        FotoAlbumListDisplayDto.fromJson({
          'album_display_type': 'my_album',
        }).isMyAlbums,
        isTrue,
      );
      final unknown = FotoAlbumListDisplayDto.fromJson({
        'album_display_type': 'brand_new',
      });
      expect(unknown.isUnknown, isTrue);
      expect(
        FotoAlbumListDisplayDto.fromJson(<String, dynamic>{}).isEmpty,
        isTrue,
      );
    });
  });

  // ================================================================ 门控纯函数

  group('photoWave3Gate 四态', () {
    test('能力位缺失 → hidden', () {
      expect(
        photoWave3Gate(const AsyncData<Object?>(null), hasApi: false),
        PhotoWave3Gate.hidden,
      );
    });

    test('105 / 160 → hidden；119 / 106 → sessionHint；其它 → visible', () {
      AsyncError<Object?> err(int code) =>
          AsyncError<Object?>(DsmApiException(code), StackTrace.empty);
      expect(photoWave3Gate(err(105), hasApi: true), PhotoWave3Gate.hidden);
      expect(photoWave3Gate(err(160), hasApi: true), PhotoWave3Gate.hidden);
      expect(
        photoWave3Gate(err(119), hasApi: true),
        PhotoWave3Gate.sessionHint,
      );
      expect(
        photoWave3Gate(err(106), hasApi: true),
        PhotoWave3Gate.sessionHint,
      );
      expect(photoWave3Gate(err(117), hasApi: true), PhotoWave3Gate.visible);
    });
  });

  // ================================================================ 页面层

  group('相册设置页（P53 客户端本地缓存：上限 + 清理）', () {
    late _FakeCache cache;
    late _MemPrefs prefs;

    setUp(() {
      cache = _FakeCache(
        const PhotoLocalCacheStats(bytes: 3 * 1024 * 1024, fileCount: 2),
      );
      prefs = _MemPrefs();
    });

    Future<({FakeTransport t, ProviderContainer c})> pumpSettings(
      WidgetTester tester,
    ) => _pump(
      tester,
      const PhotoAlbumSettingsPage(),
      responses: {
        'SYNO.Foto.Download.get_cache_status': {'status': 'done'},
        'SYNO.Foto.Download.calculate_cache_size': {'cache_size': 2048},
        'SYNO.Foto.Browse.Album.get_album_list_display': {
          'album_display_type': 'my_album',
        },
      },
      extra: [
        photoLocalCacheProvider.overrideWith((ref) async => cache),
        photoPrefsStoreProvider.overrideWithValue(prefs),
      ],
    );

    testWidgets('① 显示本机占用 + 档位选择**落盘**并立即按上限收敛', (tester) async {
      // ⚠️ 这里用**假**缓存实现：`testWidgets` 的假时钟驱动不了真实文件 I/O
      //    （本仓既有教训，见 `photo_backup_test.dart` 的 NoopHasher 注释）。
      //    "超限 → 最旧先删" 由 `photo_local_cache_test.dart` 用真文件钉住。
      final r = await pumpSettings(tester);
      expect(find.byKey(const Key('photo-local-cache')), findsOneWidget);
      expect(find.textContaining('3.0 MB'), findsOneWidget);

      await tester.tap(find.byKey(const Key('photo-cache-limit-select')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('photo-cache-limit-200')).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(prefs.data[kPhotoLocalCacheLimitSlot], '${200 * 1024 * 1024}');
      expect(cache.enforceCalls, [200 * 1024 * 1024], reason: '选小了要立刻收敛');
      // 只动本地缓存，绝不发任何 NAS 写请求
      expect(_callCount(r.t, 'SYNO.Foto.Download.clear_cache'), 0);
    });

    testWidgets('② 清理：取消 → 零删除；确认 → 调一次本地清理', (tester) async {
      final r = await pumpSettings(tester);
      await tester.tap(find.byKey(const Key('photo-cache-clear')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('photo-cache-clear-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(cache.clearCalls, 0, reason: '取消 = 一个文件都不删');

      await tester.tap(find.byKey(const Key('photo-cache-clear')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('photo-cache-clear-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(cache.clearCalls, 1);
      expect(_callCount(r.t, 'SYNO.Foto.Download.clear_cache'), 0);
    });
  });

  group('相册设置页（缓存只读 + 列表显示）', () {
    testWidgets('① 两个能力都在 → 两个 section + 三个只读请求', (tester) async {
      final r = await _pump(
        tester,
        const PhotoAlbumSettingsPage(),
        responses: {
          'SYNO.Foto.Download.get_cache_status': {'status': 'done'},
          'SYNO.Foto.Download.calculate_cache_size': {'cache_size': 2048},
          'SYNO.Foto.Browse.Album.get_album_list_display': {
            'album_display_type': 'my_album',
          },
        },
      );
      expect(
        find.byKey(const Key('photo-wave3-cache-section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('photo-wave3-album-display-section')),
        findsOneWidget,
      );
      expect(find.text('已完成'), findsOneWidget);
      expect(find.text('我的相册'), findsOneWidget);
      expect(_callCount(r.t, 'SYNO.Foto.Download.get_cache_status'), 1);
      expect(_callCount(r.t, 'SYNO.Foto.Download.calculate_cache_size'), 1);
      expect(
        _callCount(r.t, 'SYNO.Foto.Browse.Album.get_album_list_display'),
        1,
      );
      // 只读：没有任何 clear / set 请求
      expect(_callCount(r.t, 'SYNO.Foto.Download.clear_cache'), 0);
      expect(
        _callCount(r.t, 'SYNO.Foto.Browse.Album.set_album_list_display'),
        0,
      );
    });

    testWidgets('② Download 缺失 → 缓存小节隐藏 + 一个请求都不发', (tester) async {
      final r = await _pump(
        tester,
        const PhotoAlbumSettingsPage(),
        apis: _allWave3Apis.difference({'SYNO.Foto.Download'}),
      );
      expect(find.byKey(const Key('photo-wave3-cache-section')), findsNothing);
      expect(_callCount(r.t, 'SYNO.Foto.Download.get_cache_status'), 0);
      expect(_callCount(r.t, 'SYNO.Foto.Download.calculate_cache_size'), 0);
      // 列表显示不受影响（只降级自己那一节）
      expect(
        find.byKey(const Key('photo-wave3-album-display-section')),
        findsOneWidget,
      );
    });

    testWidgets('③ Browse.Album 缺失 → 列表显示小节隐藏', (tester) async {
      final r = await _pump(
        tester,
        const PhotoAlbumSettingsPage(),
        apis: _allWave3Apis.difference({'SYNO.Foto.Browse.Album'}),
      );
      expect(
        find.byKey(const Key('photo-wave3-album-display-section')),
        findsNothing,
      );
      expect(
        _callCount(r.t, 'SYNO.Foto.Browse.Album.get_album_list_display'),
        0,
      );
      expect(
        find.byKey(const Key('photo-wave3-cache-section')),
        findsOneWidget,
      );
    });

    testWidgets('④ status=running → 状态未知（绝不显示成"已完成"）', (tester) async {
      await _pump(
        tester,
        const PhotoAlbumSettingsPage(),
        responses: {
          'SYNO.Foto.Download.get_cache_status': {'status': 'running'},
          'SYNO.Foto.Download.calculate_cache_size': {'cache_size': 1024},
        },
      );
      expect(find.text('已完成'), findsNothing);
      expect(find.text('状态未知'), findsOneWidget);
    });

    testWidgets('⑤ status=processing → "正在处理"', (tester) async {
      await _pump(
        tester,
        const PhotoAlbumSettingsPage(),
        responses: {
          'SYNO.Foto.Download.get_cache_status': {'status': 'processing'},
          'SYNO.Foto.Download.calculate_cache_size': {'cache_size': 1024},
        },
      );
      expect(find.text('正在处理'), findsOneWidget);
      expect(find.text('已完成'), findsNothing);
    });

    testWidgets('⑥ cache_size 缺失 → "暂时取不到缓存大小"（不显示 0 B）', (tester) async {
      await _pump(
        tester,
        const PhotoAlbumSettingsPage(),
        responses: {
          'SYNO.Foto.Download.get_cache_status': {'status': 'done'},
          'SYNO.Foto.Download.calculate_cache_size': <String, dynamic>{},
        },
      );
      expect(find.text('暂时取不到缓存大小'), findsOneWidget);
      expect(find.textContaining('0 B'), findsNothing);
    });

    testWidgets('⑦ get_cache_status 回 105 → 缓存小节隐藏', (tester) async {
      await _pump(
        tester,
        const PhotoAlbumSettingsPage(),
        failures: const {'SYNO.Foto.Download.get_cache_status': 105},
      );
      expect(find.byKey(const Key('photo-wave3-cache-section')), findsNothing);
    });

    testWidgets('⑧ get_cache_status 回 119 → 会话提示，不隐藏', (tester) async {
      await _pump(
        tester,
        const PhotoAlbumSettingsPage(),
        responses: {
          'SYNO.Foto.Download.calculate_cache_size': {'cache_size': 1024},
        },
        failures: const {'SYNO.Foto.Download.get_cache_status': 119},
      );
      expect(
        find.byKey(const Key('photo-wave3-cache-section')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('photo-wave3-session-hint')), findsOneWidget);
    });
  });

  group('照片 EXIF 小节', () {
    testWidgets('① 有回包 → 只渲染有值的识别字段', (tester) async {
      await _pump(
        tester,
        const Scaffold(body: PhotoExifSection(itemId: '12')),
        responses: {
          'SYNO.Foto.Browse.Item.get_exif': {
            'camera': 'LGE-AN10',
            'aperture': 'F1.8',
            'iso': 'ISO640',
            'owner_id': '99',
            'mystery': 'nope',
          },
        },
      );
      expect(find.byKey(const Key('photo-wave3-exif')), findsOneWidget);
      expect(find.text('相机'), findsOneWidget);
      expect(find.text('LGE-AN10'), findsOneWidget);
      expect(find.text('光圈'), findsOneWidget);
      expect(find.text('ISO'), findsOneWidget);
      // 没有值的字段不显示空行
      expect(find.text('镜头'), findsNothing);
      // 认不出的 / 内部字段名不上屏
      expect(find.text('mystery'), findsNothing);
      expect(find.text('owner_id'), findsNothing);
      expect(find.text('99'), findsNothing);
    });

    testWidgets('② 空回包 → 明确空态（不是空白表格）', (tester) async {
      await _pump(
        tester,
        const Scaffold(body: PhotoExifSection(itemId: '12')),
        responses: {'SYNO.Foto.Browse.Item.get_exif': <String, dynamic>{}},
      );
      expect(find.byKey(const Key('photo-wave3-exif-empty')), findsOneWidget);
      expect(find.text('这张照片没有可显示的拍摄信息'), findsOneWidget);
    });

    testWidgets('③ 能力位缺失 → 整段不渲染 + 不发 get_exif', (tester) async {
      final r = await _pump(
        tester,
        const Scaffold(body: PhotoExifSection(itemId: '12')),
        apis: _allWave3Apis.difference({'SYNO.Foto.Browse.Item'}),
      );
      expect(find.byKey(const Key('photo-wave3-exif')), findsNothing);
      expect(_callCount(r.t, 'SYNO.Foto.Browse.Item.get_exif'), 0);
    });

    testWidgets('④ get_exif 回 105 → 整段不渲染', (tester) async {
      await _pump(
        tester,
        const Scaffold(body: PhotoExifSection(itemId: '12')),
        failures: const {'SYNO.Foto.Browse.Item.get_exif': 105},
      );
      expect(find.byKey(const Key('photo-wave3-exif')), findsNothing);
    });

    testWidgets('⑤ 接进大图信息面板（点 ⓘ → 拍摄信息）', (tester) async {
      await _pump(
        tester,
        PhotoViewerPage(items: [FotoItemDto.fromJson(_item('12'))]),
        responses: {
          'SYNO.Foto.Browse.Item.get_exif': {'camera': 'LGE-AN10'},
        },
      );
      await tester.tap(find.byIcon(Icons.info_outline));
      await _settle(tester);
      expect(find.byKey(const Key('photo-wave3-exif')), findsOneWidget);
      expect(find.text('相机'), findsOneWidget);
      expect(find.text('LGE-AN10'), findsOneWidget);
    });
  });

  group('相册设置入口（相册段）', () {
    testWidgets('① 能力都在 → 相册段显示设置入口并可进入', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final r = await _pump(
        tester,
        const PhotoBrowsePage(),
        responses: {
          'SYNO.Foto.Browse.Album.list': {'list': <dynamic>[]},
          'SYNO.Foto.Browse.NormalAlbum.list': {'list': <dynamic>[]},
        },
      );
      r.c.read(photoSectionProvider.notifier).select(PhotoSection.albums);
      await _settle(tester);
      expect(find.byKey(const Key('photo-album-settings')), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-album-settings')));
      await _settle(tester);
      expect(
        find.byKey(const Key('photo-wave3-album-settings')),
        findsOneWidget,
      );
    });

    testWidgets('② 两个能力位都缺 → 设置入口隐藏', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final r = await _pump(
        tester,
        const PhotoBrowsePage(),
        apis: _allWave3Apis.difference({
          'SYNO.Foto.Download',
          'SYNO.Foto.Browse.Album',
        }),
        responses: {
          'SYNO.Foto.Browse.Album.list': {'list': <dynamic>[]},
          'SYNO.Foto.Browse.NormalAlbum.list': {'list': <dynamic>[]},
        },
      );
      r.c.read(photoSectionProvider.notifier).select(PhotoSection.albums);
      await _settle(tester);
      expect(find.byKey(const Key('photo-album-settings')), findsNothing);
    });
  });

  // 保证 `_item` 与 `mensio` 引用的 DTO 可用（避免未使用告警）
  test('夹具可用', () {
    expect(FotoItemDto.fromJson(_item('1')).id, '1');
  });
}
