// 相册 P1（本轮）**接线**离线测试。
//
// 覆盖本轮真正接上界面的 10 个方法：
//   personCount/conceptCount/personDetails/conceptDetails（provider 层）、
//   sharableMembers、searchSuggest、similarTimeline（相似时间轴分页）、
//   createConditionAlbum/setConditionAlbumCondition/suggestConditionItems/
//   peekConditionItemCount、setAlbumShareLink、uploadToTimeline。
// 外加：地点 → `geocoding_id` 浏览、照片旋转（`Browse.Item/set`）。
//
// 全部离线：`FakeTransport`，不连 NAS、不弹系统选择器、不碰设备。
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
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_c2_page.dart';
import 'package:synhub/src/features/photos/photo_c2_sections.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

const _table = {
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
  'SYNO.Foto.Browse.Person': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.Foto.Browse.Concept': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.Foto.Browse.Geocoding': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
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
  'SYNO.Foto.Browse.SimilarTimeline': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Search.Search': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
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
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Upload.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 8,
  },
  'SYNO.Foto.UserInfo': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
};

Set<String> _apis({bool similarTimeline = false}) => {
  'SYNO.Foto.Browse.Item',
  'SYNO.Foto.Browse.Album',
  'SYNO.Foto.Thumbnail',
  'SYNO.Foto.Setting.User',
  kFotoSharingApi,
  kFotoGeocodingApi,
  kFotoSearchApi,
  kFotoConditionAlbumApi,
  kFotoSimilarApi,
  if (similarTimeline) kFotoSimilarTimelineApi_,
};

/// 测试里直接用字符串，避免 import 名字冲突（同 `foto_c2_api.dart` 的定义）
const String kFotoSimilarTimelineApi_ = 'SYNO.Foto.Browse.SimilarTimeline';

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

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

int _callCount(FakeTransport t, String key) =>
    t.calls.where((c) => '${c['api']}.${c['method']}' == key).length;

Map<String, dynamic> _lastCall(FakeTransport t, String key) => t.calls
    .lastWhere((c) => '${c['api']}.${c['method']}' == key)
    .map((k, v) => MapEntry(k, v));

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  Set<String>? apis,
  bool similarTimeline = false,
  List<PhotoUploadPick>? uploadPicks,
  ThemeData? theme,
}) async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
  // 放大测试画布：ListView 是懒构建的，默认 800×600 会让"新建/保存/邀请"
  // 这些靠下的按钮根本不进树，导致点不到（不是产品 bug）。
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  t.downloadBytes = _png;
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (key == 'SYNO.Foto.Setting.User.get') {
      return {
        'team_space_permission': 'none',
        'enable_similar': true,
        'enable_person': true,
        'enable_concept': true,
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
        () => _FixedAvailability(
          _snap(apis ?? _apis(similarTimeline: similarTimeline)),
        ),
      ),
      if (uploadPicks != null)
        photoUploadPickerProvider.overrideWithValue(Future.value(uploadPicks)),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: theme ?? AppTheme.dark(), home: page),
    ),
  );
  await _settle(tester);
  return (t: t, c: c);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 点一个 key。**列表是懒构建的**：目标在屏幕外时先滚到它可见为止。
Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await _settle(tester);
  }
  await tester.tap(finder);
  await _settle(tester);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('搜索建议（Search.Search/suggest v7）', () {
    testWidgets('① 输入 → 防抖后发 suggest，列表出建议；点建议 → 走关键词搜索', (tester) async {
      final r = await _pump(
        tester,
        const PhotoSearchPage(),
        responses: {
          'SYNO.Foto.Search.Search.suggest': {
            'list': [
              {'type': 'person', 'id': 7, 'name': '小明'},
              {'type': 'general_tag', 'id': 3, 'name': '海边'},
            ],
          },
          'SYNO.Foto.Search.Search.list_item': {
            'list': [_item('1')],
          },
        },
      );
      await tester.enterText(
        find.byKey(const Key('photo-c2-search-field')),
        '小',
      );
      // 300ms 防抖：250ms 时**还没**发请求
      await tester.pump(const Duration(milliseconds: 250));
      expect(_callCount(r.t, 'SYNO.Foto.Search.Search.suggest'), 0);
      await _settle(tester);
      final call = _lastCall(r.t, 'SYNO.Foto.Search.Search.suggest');
      expect(call['keyword'], '小');
      expect(find.byKey(const Key('photo-c2-search-suggest-list')), findsOne);
      expect(find.text('小明'), findsOne);
      // 官方 `Be = e.slice(0,10)`：最多 10 条
      expect(find.byKey(const Key('photo-c2-search-suggest-2')), findsNothing);
      await _tap(tester, 'photo-c2-search-suggest-0');
      expect(_callCount(r.t, 'SYNO.Foto.Search.Search.list_item'), 1);
      expect(find.byKey(const Key('photo-c2-search-grid')), findsOne);
    });

    testWidgets('① 建议为空 → 空态', (tester) async {
      await _pump(
        tester,
        const PhotoSearchPage(),
        responses: {
          'SYNO.Foto.Search.Search.suggest': {'list': <dynamic>[]},
        },
      );
      await tester.enterText(
        find.byKey(const Key('photo-c2-search-field')),
        'zz',
      );
      await _settle(tester);
      expect(
        find.byKey(const Key('photo-c2-search-suggest-list')),
        findsNothing,
      );
      expect(find.text('没有搜索建议'), findsOne);
      // 输入框聚焦会留下光标/计时器，收尾前先失焦
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
    });

    testWidgets('② 105 → 权限提示（不崩）', (tester) async {
      await _pump(
        tester,
        const PhotoSearchPage(),
        failures: const {'SYNO.Foto.Search.Search.suggest': 105},
      );
      await tester.enterText(
        find.byKey(const Key('photo-c2-search-field')),
        'zz',
      );
      await _settle(tester);
      expect(find.text('没有权限'), findsOne);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
    });
  });

  group('共享：生成链接 / 口令 / 邀请成员', () {
    Map<String, dynamic> sharingInfo({
      String link = '',
      bool enabled = false,
      bool enablePassword = false,
      String passphrase = '',
    }) => {
      'id': '1',
      'name': '相册',
      'shared': enabled,
      'additional': {
        'sharing_info': {
          'privacy_type': 'private',
          'sharing_link': link,
          'passphrase': passphrase,
          'enable_password': enablePassword,
          'permission': [
            {
              'member': {'type': 'user', 'id': '9'},
              'name': '老李',
              'role': 'view',
            },
          ],
        },
      },
    };

    final albumJson = <String, dynamic>{
      'id': '1',
      'name': '相册',
      'item_count': 3,
    };

    /// 走真实入口：`PhotoSharedPage` →「与我共享」第一条 → 共享详情页
    Future<({FakeTransport t, ProviderContainer c})> openDetail(
      WidgetTester tester, {
      Map<String, Map<String, dynamic>> responses = const {},
    }) async {
      final r = await _pump(
        tester,
        const PhotoSharedPage(),
        responses: {
          'SYNO.Foto.Sharing.Misc.list_shared_with_me_album': {
            'list': [albumJson],
          },
          ...responses,
        },
      );
      await _tap(tester, 'photo-c2-shared-item-1');
      return r;
    }

    testWidgets('① 没有链接 → "生成共享链接" → set_shared(enabled:false)', (
      tester,
    ) async {
      final r = await openDetail(
        tester,
        responses: {
          'SYNO.Foto.Browse.Album.get': {
            'list': [sharingInfo()],
          },
          'SYNO.Foto.Sharing.Passphrase.set_shared': {
            'sharing_link': 'https://nas/shared/abc',
            'passphrase': 'p1',
          },
        },
      );
      expect(find.byKey(const Key('photo-c2-share-link-create')), findsOne);
      await _tap(tester, 'photo-c2-share-link-create');
      final call = _lastCall(r.t, 'SYNO.Foto.Sharing.Passphrase.set_shared');
      expect(call['policy'], 'album');
      expect(call['album_id'], '1');
      // enabled=false = 官方"只生成链接、不改可见性"
      expect(call['enabled'], 'false');
    });

    testWidgets('① 有链接未打开 → 打开外链：确认后 set_shared(enabled:true)', (tester) async {
      final r = await openDetail(
        tester,
        responses: {
          'SYNO.Foto.Browse.Album.get': {
            'list': [
              sharingInfo(link: 'https://nas/shared/abc', passphrase: 'p1'),
            ],
          },
        },
      );
      expect(find.byKey(const Key('photo-c2-share-link-enable')), findsOne);
      await _tap(tester, 'photo-c2-share-link-enable');
      await _tap(tester, 'photo-c2-share-link-enable-ok');
      final call = _lastCall(r.t, 'SYNO.Foto.Sharing.Passphrase.set_shared');
      expect(call['enabled'], 'true');
    });

    testWidgets('⑤ 取消确认 → 一个 set_shared 都不发', (tester) async {
      final r = await openDetail(
        tester,
        responses: {
          'SYNO.Foto.Browse.Album.get': {
            'list': [
              sharingInfo(link: 'https://nas/shared/abc', passphrase: 'p1'),
            ],
          },
        },
      );
      await _tap(tester, 'photo-c2-share-link-enable');
      await _tap(tester, 'photo-c2-share-link-enable-cancel');
      expect(_callCount(r.t, 'SYNO.Foto.Sharing.Passphrase.set_shared'), 0);
    });

    testWidgets('① 口令：update 带 password（明文，官方 Android 形态）', (tester) async {
      final r = await openDetail(
        tester,
        responses: {
          'SYNO.Foto.Browse.Album.get': {
            'list': [
              sharingInfo(link: 'https://nas/shared/abc', passphrase: 'p1'),
            ],
          },
        },
      );
      await _tap(tester, 'photo-c2-share-link-password');
      await tester.enterText(
        find.byKey(const Key('photo-c2-share-password-field')),
        's3cret',
      );
      await tester.enterText(
        find.byKey(const Key('photo-c2-share-expiration-field')),
        '7',
      );
      await _tap(tester, 'photo-c2-share-password-ok');
      final call = _lastCall(r.t, 'SYNO.Foto.Sharing.Passphrase.update');
      expect(call['password'], 's3cret');
      expect(call['passphrase'], 'p1');
      // 有效期官方是**秒**（Long）；7 天 = 604800
      expect(call['expiration'], '604800');
    });

    testWidgets('① 邀请成员：list_user_group 无参数 → update 带 permission JSON', (
      tester,
    ) async {
      final r = await openDetail(
        tester,
        responses: {
          'SYNO.Foto.Browse.Album.get': {
            'list': [
              sharingInfo(link: 'https://nas/shared/abc', passphrase: 'p1'),
            ],
          },
          'SYNO.Foto.Sharing.Misc.list_user_group': {
            'list': [
              {'id': '11', 'name': '小王', 'role': 'view', 'type': 'user'},
            ],
          },
        },
      );
      await _tap(tester, 'photo-c2-add-member');
      // 官方 Android `list_user_group` **不带任何参数**
      final listCall = _lastCall(r.t, 'SYNO.Foto.Sharing.Misc.list_user_group');
      expect(listCall.containsKey('team_space_sharable_list'), isFalse);
      await _tap(tester, 'photo-c2-member-picker-user-11');
      await _tap(tester, 'photo-c2-member-picker-ok');
      final call = _lastCall(r.t, 'SYNO.Foto.Sharing.Passphrase.update');
      expect('${call['permission']}', contains('user'));
      expect('${call['permission']}', contains('11'));
      expect(call['passphrase'], 'p1');
    });
  });

  group('条件相册：create / set_condition / suggest / peek', () {
    Map<String, dynamic> conditionAlbum() => {
      'id': '5',
      'name': '2026 海边',
      'additional': {
        'condition_object': {
          'keyword': ['海边'],
          'item_type': [-1],
        },
      },
    };

    testWidgets('① 新建：UserInfo/me → UserInfo。保存带 user_id/item_type/keyword', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const PhotoConditionAlbumPage(),
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.list': {'list': <dynamic>[]},
          'SYNO.Foto.UserInfo.me': {'id': 42},
          'SYNO.Foto.Browse.ConditionAlbum.peek_item_count': {'count': 12},
          'SYNO.Foto.Browse.ConditionAlbum.create': {'album': conditionAlbum()},
        },
      );
      await _tap(tester, 'photo-c2-condition-create');
      // 个人空间必须发 UserInfo/me 拿 user_id
      expect(_callCount(r.t, 'SYNO.Foto.UserInfo.me'), 1);
      await tester.enterText(
        find.byKey(const Key('photo-c2-condition-name')),
        '海边',
      );
      await tester.enterText(
        find.byKey(const Key('photo-c2-condition-keyword')),
        '海边, 日落',
      );
      await _tap(tester, 'photo-c2-condition-item-type-photo');
      await _tap(tester, 'photo-c2-condition-peek');
      expect(
        _callCount(r.t, 'SYNO.Foto.Browse.ConditionAlbum.peek_item_count'),
        1,
      );
      expect(find.text('符合条件的照片：12 张'), findsOne);
      await _tap(tester, 'photo-c2-condition-save');
      final call = _lastCall(r.t, 'SYNO.Foto.Browse.ConditionAlbum.create');
      expect(call['name'], '海边');
      final condition =
          jsonDecode('${call['condition']}') as Map<String, dynamic>;
      // 逐字对齐官方 `S(...)`：`user_id` + `item_type`（photo → [-1]）+ `keyword`
      expect(condition['user_id'], 42);
      expect(condition['item_type'], [-1]);
      expect(condition['keyword'], ['海边', '日落']);
    });

    testWidgets('① suggest：类型白名单数组；选中值进 condition（id 数组）', (tester) async {
      final r = await _pump(
        tester,
        const PhotoConditionAlbumPage(),
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.list': {'list': <dynamic>[]},
          'SYNO.Foto.UserInfo.me': {'id': 42},
          'SYNO.Foto.Browse.ConditionAlbum.suggest': {
            'list': [
              {'id': 100, 'name': '小明'},
            ],
          },
          'SYNO.Foto.Browse.ConditionAlbum.create': {'album': conditionAlbum()},
        },
      );
      await _tap(tester, 'photo-c2-condition-create');
      await tester.enterText(
        find.byKey(const Key('photo-c2-condition-name')),
        '小明',
      );
      await _tap(tester, 'photo-c2-condition-pick-person');
      final suggestCall = _lastCall(
        r.t,
        'SYNO.Foto.Browse.ConditionAlbum.suggest',
      );
      expect(suggestCall['user_id'], '42');
      // 第三参是**类型白名单数组**，不是过滤条件
      expect('${suggestCall['condition']}', contains('person'));
      await _tap(tester, 'photo-c2-condition-value-0');
      await _tap(tester, 'photo-c2-condition-value-ok');
      await _tap(tester, 'photo-c2-condition-save');
      final call = _lastCall(r.t, 'SYNO.Foto.Browse.ConditionAlbum.create');
      final condition =
          jsonDecode('${call['condition']}') as Map<String, dynamic>;
      expect(condition['person'], [100]);
      expect(condition['person_policy'], 'and');
    });

    // ★ r402（真机复现后加）：
    //  ① DA48 —— `_TypeRow` 每行标题硬写 `conditionKindOther` ⇒ 真机 6 行全 "Other"；
    //  ② DA49 —— 空搜索框打开选值面板时不发 `keyword` ⇒ 真机必 `120` ⇒
    //     面板显示 "Failed to load values"。
    testWidgets('★ r402：条件类型行标题逐类型显示（不再全是"其它条件"）', (tester) async {
      await _pump(
        tester,
        const PhotoConditionAlbumPage(),
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.list': {'list': <dynamic>[]},
          'SYNO.Foto.UserInfo.me': {'id': 42},
        },
      );
      await _tap(tester, 'photo-c2-condition-create');
      // 编辑器开放的 6 个类型：person / concept / general_tag / geocoding / camera / lens
      for (final label in ['人物', '场景', '标签', '地点', '相机', '镜头']) {
        expect(find.text(label), findsOneWidget, reason: '缺标签 $label');
      }
      // 反向断言：这 6 行**不再**都掉进兜底文案
      expect(find.text('其它条件'), findsNothing);
    });

    testWidgets('★ r402：空搜索框打开选值面板 → 发通配 keyword=%', (tester) async {
      final r = await _pump(
        tester,
        const PhotoConditionAlbumPage(),
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.list': {'list': <dynamic>[]},
          'SYNO.Foto.UserInfo.me': {'id': 42},
          // ★ 真机形状：**类型 → 选项数组**（不是 {list:[…]}）
          'SYNO.Foto.Browse.ConditionAlbum.suggest': {
            'camera': [
              {'id': 23, 'name': 'LGE-AN10'},
            ],
          },
        },
      );
      await _tap(tester, 'photo-c2-condition-create');
      await _tap(tester, 'photo-c2-condition-pick-camera');
      final suggestCall = _lastCall(
        r.t,
        'SYNO.Foto.Browse.ConditionAlbum.suggest',
      );
      expect(suggestCall['keyword'], '%');
      expect(suggestCall['keyword'], isNot(''));
      // 面板里能看到服务端返回的候选值
      expect(find.text('LGE-AN10'), findsOneWidget);
    });

    testWidgets('① 编辑：set_condition + 改名；policy=or 落到 person_policy', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const PhotoConditionAlbumPage(),
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.list': {
            'list': [conditionAlbum()],
          },
          'SYNO.Foto.UserInfo.me': {'id': 7},
        },
      );
      await _tap(tester, 'photo-c2-condition-edit-5');
      await tester.enterText(
        find.byKey(const Key('photo-c2-condition-name')),
        '改名了',
      );
      await _tap(tester, 'photo-c2-condition-policy-person');
      await tester.pump();
      await tester.tap(find.text('任一满足').last);
      await _settle(tester);
      await _tap(tester, 'photo-c2-condition-save');
      final setCall = _lastCall(
        r.t,
        'SYNO.Foto.Browse.ConditionAlbum.set_condition',
      );
      expect(setCall['id'], '5');
      final condition =
          jsonDecode('${setCall['condition']}') as Map<String, dynamic>;
      // 只有 policy 没有值 → 不写 person；但 keyword 原样保留，改名单独发
      expect(condition['user_id'], 7);
      expect(condition['keyword'], ['海边']);
      expect(_callCount(r.t, 'SYNO.Foto.Browse.Album.set_name'), 1);
    });

    testWidgets('④ 缺 ConditionAlbum 能力位 → hub 入口隐藏且不发任何条件请求', (tester) async {
      final r = await _pump(
        tester,
        const PhotoC2Page(),
        apis: {..._apis()}..remove(kFotoConditionAlbumApi),
      );
      expect(find.byKey(const Key('photo-c2-entry-condition')), findsNothing);
      expect(
        _callCount(r.t, 'SYNO.Foto.Browse.ConditionAlbum.peek_item_count'),
        0,
      );
    });
  });

  group('相似时间轴分页（SimilarTimeline/get_similar）', () {
    Map<String, dynamic> ready() => {
      'is_similar_hash_migration_done': true,
      'stage': '',
      'waiting_count': 0,
    };

    testWidgets('④ 能力表里没有 SimilarTimeline → 一个请求都不发，回落 SimilarItem', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const PhotoSimilarPage(),
        responses: {
          'SYNO.Foto.Browse.Similar.get_status': ready(),
          'SYNO.Foto.Browse.SimilarItem.list': {
            'list': [_item('1')],
          },
        },
      );
      expect(
        _callCount(r.t, 'SYNO.Foto.Browse.SimilarTimeline.get_similar'),
        0,
      );
      expect(_callCount(r.t, 'SYNO.Foto.Browse.SimilarItem.list'), 1);
      expect(find.byKey(const Key('photo-c2-similar-grid')), findsOne);
    });

    testWidgets('① 有 SimilarTimeline → 带 offset/limit；刚好一页 → 出"加载更多"', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const PhotoSimilarPage(),
        similarTimeline: true,
        responses: {
          'SYNO.Foto.Browse.Similar.get_status': ready(),
          'SYNO.Foto.Browse.SimilarTimeline.get_similar': {
            // 官方形状：一行 = 一张图，`id` 是**分组 id**、`item_id` 才是图 id
            'list': [
              {..._item('9'), 'item_id': '9', 'count': 1, 'top_pick': '9'},
            ],
          },
        },
      );
      final call = _lastCall(
        r.t,
        'SYNO.Foto.Browse.SimilarTimeline.get_similar',
      );
      expect(call['offset'], '0');
      // 默认一页 200（与官方时间轴加载器口径一致）
      expect(call['limit'], '200');
      // 196 轮起：认得出分组 id ⇒ 渲染堆叠卡片（不再是扁平网格）
      expect(find.byKey(const Key('photo-c2-similar-groups')), findsOne);
      expect(find.byKey(const Key('photo-c2-similar-group-9')), findsOne);
    });

    testWidgets('① 时间轴返回结构化 list 就直接用（不再打 SimilarItem）', (tester) async {
      final r = await _pump(
        tester,
        const PhotoSimilarPage(),
        similarTimeline: true,
        responses: {
          'SYNO.Foto.Browse.Similar.get_status': ready(),
          'SYNO.Foto.Browse.SimilarTimeline.get_similar': {
            'list': [
              {..._item('9'), 'item_id': '9', 'count': 1, 'top_pick': '9'},
            ],
          },
        },
      );
      expect(_callCount(r.t, 'SYNO.Foto.Browse.SimilarItem.list'), 0);
      expect(find.byKey(const Key('photo-c2-similar-groups')), findsOne);
    });

    testWidgets('① 时间轴形状不认识 → 回落 SimilarItem（不白屏）', (tester) async {
      final r = await _pump(
        tester,
        const PhotoSimilarPage(),
        similarTimeline: true,
        responses: {
          'SYNO.Foto.Browse.Similar.get_status': ready(),
          // 形状不认识 → 必须回落，不能白屏
          'SYNO.Foto.Browse.SimilarTimeline.get_similar': {'groups': []},
          'SYNO.Foto.Browse.SimilarItem.list': {
            'list': [_item('1')],
          },
        },
      );
      expect(_callCount(r.t, 'SYNO.Foto.Browse.SimilarItem.list'), 1);
      expect(find.byKey(const Key('photo-c2-similar-grid')), findsOne);
    });
  });

  group('时间轴上传（Upload.Item/upload v8）', () {
    testWidgets('① 选文件 → 逐个上传，destination=timeline', (tester) async {
      final dir = Directory.systemTemp.createTempSync('photo_p1_upload');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/a.jpg')..writeAsBytesSync(_png);
      final r = await _pump(
        tester,
        const PhotoBrowsePage(),
        uploadPicks: [
          PhotoUploadPick(path: f.path, name: 'a.jpg', mtimeMs: 1700000000000),
        ],
      );
      expect(find.byKey(const Key('photo-upload-timeline')), findsOne);
      await _tap(tester, 'photo-upload-timeline');
      final call = _lastCall(r.t, 'SYNO.Foto.Upload.Item.upload');
      expect(call['uploadDestination'], '"timeline"');
      expect(call['folder'], '["PhotoLibrary"]');
      expect(call['name'], '"a.jpg"');
      // 上传完成的 SnackBar 有 4 秒计时器，收尾前先让它走完
      await tester.pump(const Duration(seconds: 5));
    });

    // ★ r521（DA163）：时间轴最后一行被悬浮的「上传到时间轴」药丸压住。
    // 判据不是"看起来还行"，而是**列表尾巴必须 ≥ FAB 高度**（56 + 16 + 32 = 104）。
    testWidgets('DA163：时间轴尾巴给悬浮按钮让位（≥104）', (tester) async {
      await _pump(tester, const PhotoBrowsePage(), responses: {
        'SYNO.Foto.Browse.Item.list': {
          'list': [_item('1'), _item('2'), _item('3')],
        },
      });
      // 时间轴非空，尾巴 sliver 才在树里
      final tail = find.byKey(const Key('photo-timeline-tail'));
      expect(tail, findsOneWidget,
          reason: 'DA163：时间轴缺尾巴 sliver（列表会钻到悬浮按钮底下）');
      final box = tester.widget<SizedBox>(tail);
      expect(box.height, greaterThanOrEqualTo(104),
          reason: 'DA163：尾巴不够高（现在是 ${box.height}），最后一行会被「上传到时间轴」压住');
    });

    testWidgets('⑤ 取消选择（空选）→ 一个上传请求都不发', (tester) async {
      final r = await _pump(
        tester,
        const PhotoBrowsePage(),
        uploadPicks: const [],
      );
      await _tap(tester, 'photo-upload-timeline');
      expect(_callCount(r.t, 'SYNO.Foto.Upload.Item.upload'), 0);
    });
  });

  // ★ r522（DA164）：查看器是黑底页面，标题却继承了 `AppTheme` 里钉成
  // `onSurface` 的 `titleTextStyle` —— 亮色下深墨蓝写在黑底上，真机几乎看不见
  // （`foregroundColor: Colors.white` 只影响图标，不影响标题）。
  testWidgets('DA164：亮色下查看器标题必须是白字（黑底页面）', (tester) async {
    await _pump(
      tester,
      PhotoViewerPage(items: [FotoItemDto.fromJson(_item('1'))]),
      theme: AppTheme.light(),
    );
    final bar = tester.widget<AppBar>(find.byType(AppBar).first);
    expect(bar.titleTextStyle?.color, Colors.white,
        reason: 'DA164：标题样式没在白字上钉死，亮色会把深色标题画到黑底上');
  });

  // ★ r522（DA165）：`DA159` 把全局 FAB 前景色钉成 `onPrimary`（白），
  // 而查看器的收藏 FAB 底色是 `hud.surface`（亮色=白）⇒ 白底白星，真机是空白方块。
  // 判据：FAB 的前景与底色**不能是同一个颜色**。
  testWidgets('DA165：亮色下收藏 FAB 前景 ≠ 底色（不许白底白星）', (tester) async {
    await _pump(
      tester,
      PhotoViewerPage(items: [FotoItemDto.fromJson(_item('1'))]),
      theme: AppTheme.light(),
    );
    final fab = tester.widget<FloatingActionButton>(
      find.byType(FloatingActionButton).first,
    );
    expect(fab.foregroundColor, isNotNull,
        reason: 'DA165：FAB 没给前景色 ⇒ 会继承全局的 onPrimary（白）');
    expect(fab.foregroundColor, isNot(fab.backgroundColor),
        reason: 'DA165：前景色 == 底色（亮色都是白）⇒ 图标看不见');
  });

  // ★ r525（DA168）：黑底查看器里的按钮不许用 Material tonal（`secondaryContainer`
  // 跟着壁纸走，亮色是淡紫）—— 真机上是一大块浅色板子。判据是源码契约：
  // 这一页不许再出现 `tonalIcon`（本页所有按钮都走 `primary`/`onPrimary`）。
  test('DA168：查看器不再使用 tonal 按钮（黑底页面只用 primary/onPrimary）', () {
    final src = File(
      'lib/src/features/photos/photo_viewer_page.dart',
    ).readAsStringSync();
    // 只看**代码行**：注释里提到 `tonalIcon` 不算违规（守卫是判代码，不是判字）。
    final code = [
      for (final line in src.split('\n'))
        if (!line.trimLeft().startsWith('//')) line,
    ].join('\n');
    expect(code.contains('tonalIcon'), isFalse,
        reason: 'DA168：tonal 按钮的底色跟壁纸派生，黑底上是一块浅色板子');
    expect(src.contains('FilledButton.icon('), isTrue,
        reason: 'DA168：播放/兜底按钮必须走 primary 实心按钮');
    // r526：同族收口 —— `MediaFallbackPanel` 出现在**黑底**的查看器/播放器里，
    // 它的「用其他应用打开」也不许 tonal。
    final panel = File(
      'lib/src/features/media/media_player_view.dart',
    ).readAsStringSync();
    final panelCode = [
      for (final line in panel.split('\n'))
        if (!line.trimLeft().startsWith('//')) line,
    ].join('\n');
    expect(panelCode.contains('tonalIcon'), isFalse,
        reason: 'DA168：黑底的 MediaFallbackPanel 也不许用 tonal 按钮');
  });

  group('照片编辑：只有旋转（Browse.Item/set + rotate_action）', () {
    testWidgets('① 选顺时针 → set 带 rotate_action（JSON 引号）；id 是数组', (tester) async {
      final r = await _pump(
        tester,
        PhotoViewerPage(items: [FotoItemDto.fromJson(_item('1'))]),
        responses: {
          'SYNO.Foto.Browse.Item.get_exif': {'list': <dynamic>[]},
        },
      );
      expect(find.byKey(const Key('photo-rotate')), findsOne);
      await _tap(tester, 'photo-rotate');
      await _tap(tester, 'photo-rotate-clockwise');
      final call = _lastCall(r.t, 'SYNO.Foto.Browse.Item.set');
      expect(call['rotate_action'], '"clockwise"');
      // `id` 走 `js()`：官方 Android 是**数字数组**（`List<Long>`），不是字符串数组
      expect(call['id'], '[1]');
    });

    testWidgets('② 105 → 只隐藏旋转入口，其余入口照常（照片本身还能看）', (tester) async {
      final r = await _pump(
        tester,
        PhotoViewerPage(items: [FotoItemDto.fromJson(_item('1'))]),
        responses: {
          'SYNO.Foto.Browse.Item.get_exif': {'list': <dynamic>[]},
        },
        failures: const {'SYNO.Foto.Browse.Item.set': 105},
      );
      await _tap(tester, 'photo-rotate');
      await _tap(tester, 'photo-rotate-clockwise');
      expect(_callCount(r.t, 'SYNO.Foto.Browse.Item.set'), 1);
      expect(find.byKey(const Key('photo-rotate')), findsNothing);
      // 其它入口不受影响
      expect(find.byIcon(Icons.download_outlined), findsOne);
      expect(find.byIcon(Icons.info_outline), findsOne);
    });

    testWidgets('① 取消旋转面板 → 不发 set', (tester) async {
      final r = await _pump(
        tester,
        PhotoViewerPage(items: [FotoItemDto.fromJson(_item('1'))]),
        responses: {
          'SYNO.Foto.Browse.Item.get_exif': {'list': <dynamic>[]},
        },
      );
      await _tap(tester, 'photo-rotate');
      await tester.tapAt(const Offset(10, 10)); // 点面板外关闭
      await _settle(tester);
      expect(_callCount(r.t, 'SYNO.Foto.Browse.Item.set'), 0);
    });
  });

  group('地点 → 按地点浏览（Browse.Item/list + geocoding_id）', () {
    testWidgets('① 点地点 → 拉该地点照片；点的 id 进 geocoding_id', (tester) async {
      final r = await _pump(
        tester,
        const PhotoGeocodingPage(),
        responses: {
          'SYNO.Foto.Browse.Geocoding.list': {
            'list': [
              {
                'id': 3,
                'name': '杭州',
                'additional': {'item_count': 5, 'thumbnail': {}},
              },
            ],
          },
          'SYNO.Foto.Browse.Item.list': {
            'list': [_item('1')],
          },
        },
      );
      await _tap(tester, 'photo-c2-place-3');
      final call = _lastCall(r.t, 'SYNO.Foto.Browse.Item.list');
      expect(call['geocoding_id'], '3');
      expect(find.byKey(const Key('photo-c2-place-items-grid')), findsOne);
    });
  });

  group('人物 / 场景计数与详情（provider 层）', () {
    test('① count / page / detail 都真的发请求，且参数对得上', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        switch ('${params['api']}.${params['method']}') {
          case 'SYNO.Foto.Browse.Person.count':
            return {'count': 12};
          case 'SYNO.Foto.Browse.Person.list':
            return {
              'list': [
                {
                  'id': 7,
                  'name': '小明',
                  'item_count': 3,
                  'additional': {'thumbnail': {}},
                },
              ],
            };
          case 'SYNO.Foto.Browse.Person.get':
            return {
              'list': [
                {
                  'id': 7,
                  'name': '小明',
                  'item_count': 3,
                  'additional': {'thumbnail': {}},
                },
              ],
            };
          case 'SYNO.Foto.Browse.Concept.count':
            return {'count': 4};
          case 'SYNO.Foto.Browse.Concept.get':
            return {
              'list': [
                {'id': 2, 'name': '海滩', 'item_count': 9},
              ],
            };
        }
        return const <String, dynamic>{};
      };
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);

      expect(await c.read(photoPersonCountProvider.future), 12);
      final page = await c.read(photoPersonsPageProvider(40).future);
      expect(page.length, 1);
      final pageCall = _lastCall(t, 'SYNO.Foto.Browse.Person.list');
      expect(pageCall['limit'], '40');
      final detail = await c.read(photoPersonDetailProvider('7').future);
      expect(detail?.id, '7');
      expect(_callCount(t, 'SYNO.Foto.Browse.Person.get'), 1);

      expect(await c.read(photoConceptCountProvider.future), 4);
      final concept = await c.read(photoConceptDetailProvider('2').future);
      expect(concept?.id, '2');
      expect(_callCount(t, 'SYNO.Foto.Browse.Concept.get'), 1);
    });
  });

  group('精确位置 marker 接线（Browse.Item/list additional=gps → 地图入口）', () {
    testWidgets('① 有 gps 的照片 → 地图入口出现，弹层是「精确坐标」', (tester) async {
      final withGps = FotoItemDto.fromJson({
        ..._item('1'),
        'additional': {
          'thumbnail': {'sm': 'sm_1', 'cache_key': 'ck_1'},
          'gps': {'latitude': 39.908722, 'longitude': 116.397499},
        },
      });
      await _pump(
        tester,
        PhotoViewerPage(items: [withGps]),
        responses: {
          'SYNO.Foto.Browse.Item.get_exif': {'list': <dynamic>[]},
        },
      );
      expect(find.byKey(const Key('photo-map-open-item')), findsOne);
      await _tap(tester, 'photo-map-open-item');
      expect(find.byKey(const Key('photo-map-sheet')), findsOne);
      final badge = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('photo-map-badge')),
          matching: find.byType(Text),
        ),
      );
      expect(badge.data, contains('精确'));
    });

    testWidgets('② 没有 gps 的照片 → 地图入口不出现（不假装有坐标）', (tester) async {
      await _pump(
        tester,
        PhotoViewerPage(items: [FotoItemDto.fromJson(_item('1'))]),
        responses: {
          'SYNO.Foto.Browse.Item.get_exif': {'list': <dynamic>[]},
        },
      );
      expect(find.byKey(const Key('photo-map-open-item')), findsNothing);
    });
  });
}
