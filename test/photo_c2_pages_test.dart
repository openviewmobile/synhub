// C2（Photos 补齐）**页面层**离线测试。
//
// 每个功能四件套（用户验收口径）：
//   ① 成功路径（假响应 → 真渲染）
//   ② `105` → 无权限（入口隐藏 + 提示）
//   ③ `119` → 会话提示，入口**绝不**隐藏
//   ④ 能力位缺失 → 该入口隐藏（`partial`，Photos 模块本身照常）
// 危险操作再加一条：
//   ⑤ 取消二次确认 → **一个请求都不发**
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_c2_page.dart';
import 'package:synhub/src/features/photos/photo_c2_sections.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 透明 PNG（缩略图走**字节**链路，没有真字节只会画占位图标）
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

const _c2Table = {
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
  'SYNO.Foto.Sharing.Misc': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Sharing.Passphrase': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.PhotoRequest': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.Browse.Geocoding': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.Search.Search': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.Foto.Search.Filter': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.ConditionAlbum': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Similar': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.Browse.SimilarItem': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 能力表里"全都有"的集合（Photos 的必选 + 既有可选 + C2 的七个可选位）
const _allC2Apis = {
  'SYNO.Foto.Browse.Item',
  'SYNO.Foto.Browse.Album',
  'SYNO.Foto.Streaming',
  'SYNO.Foto.Thumbnail',
  'SYNO.Foto.Download',
  'SYNO.Foto.Setting.User',
  kFotoSharingApi,
  kFotoPhotoRequestApi,
  kFotoGeocodingApi,
  kFotoSearchApi,
  kFotoSearchFilterApi,
  kFotoConditionAlbumApi,
  kFotoSimilarApi,
};

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

/// 一个"检测过"的 Photos 能力快照（同 `drive_c1_pages_test.dart` 的口径）
ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values)
          s: s == StationService.photo
              ? classifyApiTable(kServiceRegistry[StationService.photo]!, apis)
              : AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 9, 22),
    );

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

/// 状态：真实接口调用的次数
int _callCount(FakeTransport t, String key) =>
    t.calls.where((c) => '${c['api']}.${c['method']}' == key).length;

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Set<String> apis = _allC2Apis,
  Map<String, int> failures = const {},
  bool enableSimilar = true,
}) async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._c2Table});
  t.downloadBytes = _png;
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (key == 'SYNO.Foto.Setting.User.get') {
      return {
        'team_space_permission': 'none',
        'enable_similar': enableSimilar,
        'timeline_group_unit': 'day',
      };
    }
    return responses[key] ?? const <String, dynamic>{};
  };
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis)),
      ),
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

/// 探针是**串行**的（逐个 await），要多次 pump 才全部落地
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await _settle(tester);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('hub 入口可用性（① ② ③ ④）', () {
    testWidgets('① 六个能力位都在 → 六个入口全在', (tester) async {
      await _pump(tester, const PhotoC2Page());
      for (final key in const [
        'photo-c2-entry-sharing',
        'photo-c2-entry-photo-request',
        'photo-c2-entry-geocoding',
        'photo-c2-entry-search',
        'photo-c2-entry-condition',
        'photo-c2-entry-similar',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
      expect(find.byKey(const Key('photo-c2-permission-hint')), findsNothing);
      expect(find.byKey(const Key('photo-c2-session-hint')), findsNothing);
    });

    testWidgets('④ 缺 SYNO.Foto.Search.Search → 搜索入口消失，其余照常，且没发搜索请求', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const PhotoC2Page(),
        apis: {..._allC2Apis}..remove(kFotoSearchApi),
      );
      expect(find.byKey(const Key('photo-c2-entry-search')), findsNothing);
      expect(find.byKey(const Key('photo-c2-entry-sharing')), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-entry-condition')), findsOneWidget);
      // 能力位缺失 → 连探测请求都不该发
      expect(_callCount(r.t, 'SYNO.Foto.Search.Filter.list'), 0);
      expect(_callCount(r.t, 'SYNO.Foto.Search.Search.suggest'), 0);
    });

    testWidgets('④ 缺 SYNO.Foto.Sharing.Misc → 共享入口消失，Photos 不隐藏', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const PhotoC2Page(),
        apis: {..._allC2Apis}..remove(kFotoSharingApi),
      );
      expect(find.byKey(const Key('photo-c2-entry-sharing')), findsNothing);
      expect(
        find.byKey(const Key('photo-c2-entry-photo-request')),
        findsOneWidget,
      );
      expect(
        _callCount(r.t, 'SYNO.Foto.Sharing.Misc.list_shared_with_me_album'),
        0,
      );
    });

    testWidgets('② 105 → 该入口隐藏 + 无权限提示（其它入口保留）', (tester) async {
      await _pump(
        tester,
        const PhotoC2Page(),
        failures: const {
          'SYNO.Foto.Sharing.Misc.list_shared_with_me_album': 105,
        },
      );
      expect(find.byKey(const Key('photo-c2-entry-sharing')), findsNothing);
      expect(find.byKey(const Key('photo-c2-permission-hint')), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-entry-search')), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-session-hint')), findsNothing);
    });

    testWidgets('② 105 只隐藏出事的那个入口（相似 105 不影响共享）', (tester) async {
      await _pump(
        tester,
        const PhotoC2Page(),
        failures: const {'SYNO.Foto.Browse.Similar.get_status': 105},
      );
      expect(find.byKey(const Key('photo-c2-entry-similar')), findsNothing);
      expect(find.byKey(const Key('photo-c2-entry-sharing')), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-entry-geocoding')), findsOneWidget);
    });

    testWidgets('③ 119 → 会话提示，六个入口**一个都不许少**', (tester) async {
      await _pump(
        tester,
        const PhotoC2Page(),
        failures: const {'SYNO.Foto.PhotoRequest.list': 119},
      );
      expect(find.byKey(const Key('photo-c2-session-hint')), findsOneWidget);
      for (final key in const [
        'photo-c2-entry-sharing',
        'photo-c2-entry-photo-request',
        'photo-c2-entry-geocoding',
        'photo-c2-entry-search',
        'photo-c2-entry-condition',
        'photo-c2-entry-similar',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
    });

    testWidgets('③ 106 与 119 同款：只提示、不隐藏', (tester) async {
      await _pump(
        tester,
        const PhotoC2Page(),
        failures: const {'SYNO.Foto.Search.Filter.list': 106},
      );
      expect(find.byKey(const Key('photo-c2-session-hint')), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-entry-search')), findsOneWidget);
    });

    testWidgets('未知错误 → fail-open：入口保留（不因不确定而隐藏）', (tester) async {
      await _pump(
        tester,
        const PhotoC2Page(),
        failures: const {'SYNO.Foto.Browse.Geocoding.count': 900},
      );
      expect(find.byKey(const Key('photo-c2-entry-geocoding')), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-session-hint')), findsNothing);
      expect(find.byKey(const Key('photo-c2-permission-hint')), findsNothing);
    });

    testWidgets('相似照片：设置里 enable_similar=false → 相似入口不出现', (tester) async {
      await _pump(tester, const PhotoC2Page(), enableSimilar: false);
      expect(find.byKey(const Key('photo-c2-entry-similar')), findsNothing);
      expect(find.byKey(const Key('photo-c2-entry-sharing')), findsOneWidget);
    });
  });

  group('相册页入口接线', () {
    testWidgets('相册页顶部有 photo-c2-entry，点了进 hub', (tester) async {
      await _pump(tester, const PhotoBrowsePage());
      expect(find.byKey(const Key('photo-c2-entry')), findsOneWidget);
      await _tap(tester, 'photo-c2-entry');
      expect(find.byKey(const Key('photo-c2-page')), findsOneWidget);
    });
  });

  group('共享相册页', () {
    Map<String, Map<String, dynamic>> sharedResponses() => {
      'SYNO.Foto.Sharing.Misc.list_shared_with_me_album': {
        'list': [
          {'id': 7, 'name': '同事的相册', 'shared': true, 'owner_user_id': 3},
        ],
      },
      'SYNO.Foto.Browse.Album.list': {
        'list': [
          {'id': 11, 'name': '我的旅行', 'shared': true, 'item_count': 5},
        ],
      },
      'SYNO.Foto.Browse.Album.get': {
        'list': [
          {
            'id': 7,
            'name': '同事的相册',
            'shared': true,
            'additional': {
              'sharing_info': {
                'privacy_type': 'public-view',
                'sharing_link': 'https://nas/photo/#/shared/abc',
                'passphrase': 'abc',
                'expiration': 0,
                'permission': [
                  {
                    'role': 'view',
                    'member': {'type': 'public'},
                  },
                  {
                    'role': 'download',
                    'member': {'type': 'user', 'id': 8, 'name': '阿明'},
                  },
                ],
                'owner': {'name': '老王'},
              },
            },
          },
        ],
      },
    };

    testWidgets('① 与我共享列表 + 点进详情看外链和成员', (tester) async {
      await _pump(
        tester,
        const PhotoSharedPage(),
        responses: sharedResponses(),
      );
      expect(find.byKey(const Key('photo-c2-shared-item-7')), findsOneWidget);
      await _tap(tester, 'photo-c2-shared-item-7');
      expect(
        find.byKey(const Key('photo-c2-share-detail-page')),
        findsOneWidget,
      );
      expect(find.text('https://nas/photo/#/shared/abc'), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-member-user-8')), findsOneWidget);
      expect(find.text('阿明'), findsOneWidget);
      // public 成员不进"成员"列表
      expect(find.byKey(const Key('photo-c2-member-public-')), findsNothing);
    });

    testWidgets('① 切到"我共享的"页签 → Browse.Album/list category=shared', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const PhotoSharedPage(),
        responses: sharedResponses(),
      );
      await _tap(tester, 'photo-c2-shared-others-tab');
      expect(find.byKey(const Key('photo-c2-shared-item-11')), findsOneWidget);
      final call = r.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.Album' && c['method'] == 'list',
      );
      expect(call['category'], 'shared');
    });

    testWidgets('② 列表 105 → "没有权限"（内容不渲染）', (tester) async {
      await _pump(
        tester,
        const PhotoSharedPage(),
        failures: const {
          'SYNO.Foto.Sharing.Misc.list_shared_with_me_album': 105,
        },
      );
      expect(find.text('没有权限'), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-shared-item-7')), findsNothing);
    });

    testWidgets('★ DA77 关闭外链：取消 → 一个请求都不发', (tester) async {
      final r = await _pump(
        tester,
        const PhotoSharedPage(),
        responses: sharedResponses(),
      );
      await _tap(tester, 'photo-c2-shared-item-7');
      await _tap(tester, 'photo-c2-share-disable');
      expect(find.text('关闭外链分享？'), findsOneWidget);
      await _tap(tester, 'photo-c2-share-disable-cancel');
      expect(_callCount(r.t, 'SYNO.Foto.Sharing.Passphrase.update'), 0);
      expect(_callCount(r.t, 'SYNO.Foto.Sharing.Passphrase.set_shared'), 0);
      // 弹层关掉、详情页还在
      expect(
        find.byKey(const Key('photo-c2-share-detail-page')),
        findsOneWidget,
      );
    });

    testWidgets('★ DA77 关闭外链：点"确定" → set_shared(enabled:false)（不是 update）', (
      tester,
    ) async {
      // 老用例（r402 写的）把 `Passphrase/update {privacy_type:private}` 当**正确行为**，
      // 而 r417 真机 + NAS 侧原始读数是：那条调用**回 success 但一个字段都不改**
      // （`shared` 仍 true、`category=shared` 仍有它）⇒ 界面弹「已关闭」是谎报。
      // 真判据只能钉在 `set_shared(enabled:false)` 上（读数见
      // `docs/evidence-r417/nas/r417_disable_shapes.log`）。
      final r = await _pump(
        tester,
        const PhotoSharedPage(),
        responses: {
          ...sharedResponses(),
          'SYNO.Foto.Sharing.Passphrase.set_shared': <String, dynamic>{},
        },
      );
      await _tap(tester, 'photo-c2-shared-item-7');
      await _tap(tester, 'photo-c2-share-disable');
      await _tap(tester, 'photo-c2-share-disable-ok');
      expect(
        _callCount(r.t, 'SYNO.Foto.Sharing.Passphrase.update'),
        0,
        reason: '★ DA77：update 那条在真机上什么都改不了',
      );
      final call = r.t.calls.lastWhere(
        (c) =>
            c['api'] == 'SYNO.Foto.Sharing.Passphrase' &&
            c['method'] == 'set_shared',
      );
      expect(call['policy'], 'album');
      expect(call['album_id'], '7');
      expect('${call['enabled']}', 'false');
    });

    testWidgets('⑤ 移除成员：取消不发请求；确定发 action=delete', (tester) async {
      final r = await _pump(
        tester,
        const PhotoSharedPage(),
        responses: {
          ...sharedResponses(),
          'SYNO.Foto.Sharing.Passphrase.update': <String, dynamic>{},
        },
      );
      await _tap(tester, 'photo-c2-shared-item-7');
      await _tap(tester, 'photo-c2-member-remove-8');
      expect(find.text('移除成员？'), findsOneWidget);
      await _tap(tester, 'photo-c2-member-remove-cancel');
      expect(_callCount(r.t, 'SYNO.Foto.Sharing.Passphrase.update'), 0);

      await _tap(tester, 'photo-c2-member-remove-8');
      await _tap(tester, 'photo-c2-member-remove-ok');
      expect(_callCount(r.t, 'SYNO.Foto.Sharing.Passphrase.update'), 1);
      final call = r.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Sharing.Passphrase',
      );
      expect(
        call['permission'],
        '[{"action":"delete","member":{"type":"user","id":"8"}}]',
      );
    });
  });

  group('照片请求页', () {
    Map<String, Map<String, dynamic>> requestResponses() => {
      'SYNO.Foto.PhotoRequest.list': {
        'list': [
          {
            'passphrase': 'p1',
            'name': '婚礼收图',
            'item_count': 12,
            'expiration': 0,
          },
        ],
      },
    };

    testWidgets('① 列表渲染', (tester) async {
      await _pump(
        tester,
        const PhotoRequestsPage(),
        responses: requestResponses(),
      );
      expect(find.byKey(const Key('photo-c2-request-p1')), findsOneWidget);
      expect(find.text('婚礼收图'), findsOneWidget);
      expect(find.text('永不过期'), findsOneWidget);
    });

    testWidgets('⑤ 删除：取消 → PhotoRequest/delete 一个都不发', (tester) async {
      final r = await _pump(
        tester,
        const PhotoRequestsPage(),
        responses: requestResponses(),
      );
      await _tap(tester, 'photo-c2-request-delete-p1');
      expect(find.text('删除照片请求？'), findsOneWidget);
      await _tap(tester, 'photo-c2-request-delete-cancel');
      expect(_callCount(r.t, 'SYNO.Foto.PhotoRequest.delete'), 0);
    });

    testWidgets('⑤ 删除：确定 → passphrase 是数组', (tester) async {
      final r = await _pump(
        tester,
        const PhotoRequestsPage(),
        responses: {
          ...requestResponses(),
          'SYNO.Foto.PhotoRequest.delete': <String, dynamic>{},
        },
      );
      await _tap(tester, 'photo-c2-request-delete-p1');
      await _tap(tester, 'photo-c2-request-delete-ok');
      expect(_callCount(r.t, 'SYNO.Foto.PhotoRequest.delete'), 1);
      final call = r.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.PhotoRequest' && c['method'] == 'delete',
      );
      expect(call['passphrase'], '["p1"]');
    });

    testWidgets('③ 新建：填主题/团队空间/上限 20MB → create 字段对齐官方 smali', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const PhotoRequestsPage(),
        responses: {
          ...requestResponses(),
          'SYNO.Foto.PhotoRequest.create': <String, dynamic>{},
        },
      );
      await _tap(tester, 'photo-c2-request-new');
      expect(find.byKey(const Key('photo-c2-request-editor')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('photo-c2-request-subject')),
        '毕业照收集',
      );
      await tester.enterText(
        find.byKey(const Key('photo-c2-request-description')),
        '请上传原图',
      );
      await tester.tap(find.byKey(const Key('photo-c2-request-team')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('photo-c2-request-size-mb')),
        '20',
      );
      await _tap(tester, 'photo-c2-request-save');
      final call = r.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.PhotoRequest' && c['method'] == 'create',
      );
      expect(call['version'], '1');
      expect(call['subject'], '毕业照收集');
      expect(call['description'], '请上传原图');
      expect(call['library'], 'shared_space', reason: '官方 isTeamLibToString');
      expect(call['filesize_limit'], '${20 * 1024 * 1024}', reason: 'MB→字节');
      expect(call.containsKey('expiration'), isFalse, reason: '没填就不发');
    });

    testWidgets('③ 新建：取消 → create 一个都不发', (tester) async {
      final r = await _pump(
        tester,
        const PhotoRequestsPage(),
        responses: requestResponses(),
      );
      await _tap(tester, 'photo-c2-request-new');
      await tester.enterText(
        find.byKey(const Key('photo-c2-request-subject')),
        '不该发出去',
      );
      await _tap(tester, 'photo-c2-request-cancel');
      expect(_callCount(r.t, 'SYNO.Foto.PhotoRequest.create'), 0);
    });

    testWidgets('③ 新建：主题为空 → 保存按钮禁用（不发半个请求）', (tester) async {
      final r = await _pump(
        tester,
        const PhotoRequestsPage(),
        responses: requestResponses(),
      );
      await _tap(tester, 'photo-c2-request-new');
      final save = tester.widget<FilledButton>(
        find.byKey(const Key('photo-c2-request-save')),
      );
      expect(save.onPressed, isNull);
      expect(_callCount(r.t, 'SYNO.Foto.PhotoRequest.create'), 0);
    });

    testWidgets('③ 编辑：点行 → update，首字段 passphrase 是裸串', (tester) async {
      final r = await _pump(
        tester,
        const PhotoRequestsPage(),
        responses: {
          ...requestResponses(),
          'SYNO.Foto.PhotoRequest.update': <String, dynamic>{},
        },
      );
      await tester.tap(find.byKey(const Key('photo-c2-request-p1')));
      await tester.pumpAndSettle();
      expect(find.text('编辑照片请求'), findsOneWidget);
      // 主题预填了原值
      expect(find.text('婚礼收图'), findsWidgets);
      await _tap(tester, 'photo-c2-request-save');
      final call = r.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.PhotoRequest' && c['method'] == 'update',
      );
      expect(call['passphrase'], 'p1', reason: 'update 首字段是裸串 passphrase');
      expect(call['subject'], '婚礼收图');
      expect(call['library'], 'personal_space');
    });

    testWidgets('② 105 → "没有权限"且不发第二次', (tester) async {
      final r = await _pump(
        tester,
        const PhotoRequestsPage(),
        failures: const {'SYNO.Foto.PhotoRequest.list': 105},
      );
      expect(find.text('没有权限'), findsOneWidget);
      // 自愈重试关掉了：失败后不该无限重打
      expect(_callCount(r.t, 'SYNO.Foto.PhotoRequest.list'), 1);
    });
  });

  group('地点页', () {
    testWidgets('① 地点列表 + 张数', (tester) async {
      await _pump(
        tester,
        const PhotoGeocodingPage(),
        responses: {
          'SYNO.Foto.Browse.Geocoding.list': {
            'list': [
              {'id': 101, 'name': '东京', 'country': '日本', 'item_count': 20},
              {'id': 102, 'first_level': '关东'},
            ],
          },
        },
      );
      expect(find.byKey(const Key('photo-c2-place-101')), findsOneWidget);
      expect(find.text('东京'), findsOneWidget);
      expect(find.text('20 张照片'), findsOneWidget);
      // 没有名字 → 回落 first_level
      expect(find.text('关东'), findsOneWidget);
    });

    testWidgets('① 空列表 → 空态', (tester) async {
      await _pump(
        tester,
        const PhotoGeocodingPage(),
        responses: {
          'SYNO.Foto.Browse.Geocoding.list': {'list': <Map<String, dynamic>>[]},
        },
      );
      expect(find.text('还没有带地点的照片'), findsOneWidget);
    });
  });

  group('搜索页', () {
    testWidgets('① 输入关键词 → Search.Search/list_item 带 keyword，出网格', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const PhotoSearchPage(),
        responses: {
          'SYNO.Foto.Search.Search.list_item': {
            'list': [_item('1'), _item('2')],
          },
        },
      );
      expect(find.byKey(const Key('photo-c2-search-empty')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('photo-c2-search-field')),
        '海边',
      );
      await _tap(tester, 'photo-c2-search-go');
      expect(find.byKey(const Key('photo-c2-search-grid')), findsOneWidget);
      final call = r.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Search.Search',
      );
      expect(call['method'], 'list_item');
      expect(call['keyword'], '海边');
    });

    testWidgets('① 无结果 → 空态', (tester) async {
      await _pump(
        tester,
        const PhotoSearchPage(),
        responses: {
          'SYNO.Foto.Search.Search.list_item': {
            'list': <Map<String, dynamic>>[],
          },
        },
      );
      await tester.enterText(
        find.byKey(const Key('photo-c2-search-field')),
        '不存在',
      );
      await _tap(tester, 'photo-c2-search-go');
      expect(find.text('没有匹配的照片'), findsOneWidget);
    });

    testWidgets('② 105 → "没有权限"', (tester) async {
      await _pump(
        tester,
        const PhotoSearchPage(),
        failures: const {'SYNO.Foto.Search.Search.list_item': 105},
      );
      await tester.enterText(
        find.byKey(const Key('photo-c2-search-field')),
        '海边',
      );
      await _tap(tester, 'photo-c2-search-go');
      expect(find.text('没有权限'), findsOneWidget);
    });
  });

  group('条件相册页', () {
    Map<String, Map<String, dynamic>> conditionResponses() => {
      'SYNO.Foto.Browse.ConditionAlbum.list': {
        'list': [
          {
            'id': 31,
            'name': '去年夏天',
            'item_count': 88,
            'additional': {
              'condition_object': {
                'time': [
                  {'start_time': 1, 'end_time': 2},
                ],
                'geocoding': [
                  {'id': 101},
                ],
              },
            },
          },
        ],
      },
    };

    testWidgets('① 列表 + 条件摘要（键名翻中文）', (tester) async {
      await _pump(
        tester,
        const PhotoConditionAlbumPage(),
        responses: conditionResponses(),
      );
      expect(find.byKey(const Key('photo-c2-condition-31')), findsOneWidget);
      expect(find.text('去年夏天'), findsOneWidget);
      expect(find.text('条件：时间 · 地点'), findsOneWidget);
    });

    testWidgets('★ DA78 记账键 user_id / *_policy 不许当成条件显示', (tester) async {
      // 真机读数（r417，`docs/evidence-r417/nas/r417_after_cond_save.log`）：
      // 刚建的"相机"条件相册在服务端是
      // `condition={"camera":[23],"user_id":4}`，
      // 而列表行原来读作 `Condition: Camera · Other` —— "Other" 就是 `user_id`。
      await _pump(
        tester,
        const PhotoConditionAlbumPage(),
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.list': {
            'list': [
              {
                'id': 41,
                'name': 'r417cond',
                'item_count': 10,
                'additional': {
                  'condition_object': {
                    'camera': [
                      {'id': 23, 'name': 'LGE-AN10'},
                    ],
                    'user_id': 4,
                    'camera_policy': 'and',
                  },
                },
              },
            ],
          },
        },
      );
      expect(find.text('条件：相机'), findsOneWidget);
      expect(
        find.text('其它条件'),
        findsNothing,
        reason: '★ DA78：user_id / *_policy 是记账键，不是条件',
      );
    });

    testWidgets('⑤ 删除：取消 → Browse.Album/delete 一个都不发', (tester) async {
      final r = await _pump(
        tester,
        const PhotoConditionAlbumPage(),
        responses: conditionResponses(),
      );
      await _tap(tester, 'photo-c2-condition-delete-31');
      expect(find.text('删除条件相册？'), findsOneWidget);
      await _tap(tester, 'photo-c2-condition-delete-cancel');
      expect(_callCount(r.t, 'SYNO.Foto.Browse.Album.delete'), 0);
    });

    testWidgets('⑤ 删除：确定 → Browse.Album/delete（id 数组）', (tester) async {
      final r = await _pump(
        tester,
        const PhotoConditionAlbumPage(),
        responses: {
          ...conditionResponses(),
          'SYNO.Foto.Browse.Album.delete': <String, dynamic>{},
        },
      );
      await _tap(tester, 'photo-c2-condition-delete-31');
      await _tap(tester, 'photo-c2-condition-delete-ok');
      final call = r.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.Album' && c['method'] == 'delete',
      );
      expect(call['id'], '[31]');
    });

    testWidgets('② 105 → "没有权限"', (tester) async {
      await _pump(
        tester,
        const PhotoConditionAlbumPage(),
        failures: const {'SYNO.Foto.Browse.ConditionAlbum.list': 105},
      );
      expect(find.text('没有权限'), findsOneWidget);
    });
  });

  group('相似照片页', () {
    testWidgets('① 设置没开 → "相似照片未启用"（不发 status 请求）', (tester) async {
      final r = await _pump(
        tester,
        const PhotoSimilarPage(),
        enableSimilar: false,
      );
      expect(
        find.byKey(const Key('photo-c2-similar-disabled')),
        findsOneWidget,
      );
      expect(_callCount(r.t, 'SYNO.Foto.Browse.Similar.get_status'), 0);
    });

    testWidgets('① 索引没跑完 → 显示待索引张数', (tester) async {
      await _pump(
        tester,
        const PhotoSimilarPage(),
        responses: {
          'SYNO.Foto.Browse.Similar.get_status': {
            'is_similar_hash_migration_done': false,
            'stage': 'running',
            'waiting_count': 120,
          },
        },
      );
      expect(
        find.byKey(const Key('photo-c2-similar-indexing')),
        findsOneWidget,
      );
      expect(find.text('还有 120 张待索引（阶段 running）。'), findsOneWidget);
    });

    testWidgets('① 索引就绪 → 拉相似分组照片出网格', (tester) async {
      final r = await _pump(
        tester,
        const PhotoSimilarPage(),
        responses: {
          'SYNO.Foto.Browse.Similar.get_status': {
            'is_similar_hash_migration_done': true,
            'stage': '',
            'waiting_count': 0,
          },
          'SYNO.Foto.Browse.SimilarItem.list': {
            'list': [_item('9')],
          },
        },
      );
      expect(find.byKey(const Key('photo-c2-similar-grid')), findsOneWidget);
      final call = r.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.SimilarItem',
      );
      expect(call['method'], 'list');
      // 分组 id 参数名没有原文 → 不许凭空造；这里必须**不带**任何分组参数
      expect(call.keys.where((k) => k.contains('similar_group')), isEmpty);
    });

    testWidgets('② 105 → "没有权限"', (tester) async {
      await _pump(
        tester,
        const PhotoSimilarPage(),
        failures: const {'SYNO.Foto.Browse.Similar.get_status': 105},
      );
      expect(find.text('没有权限'), findsOneWidget);
    });
  });
}
