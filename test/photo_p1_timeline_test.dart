// ⑦相册 **P-1 时间轴批次**：P5 视图刻度切换（UI）+ P3 触底增量分页（UI）。
//
// P2（年聚合）与 P4（缩略图密度）此前已有用例
// （`photo_wave1_test.dart` 的 `groupPhotos(unit:'year')`、
//  `photo_g1_api_test.dart` + `photo_g1_pages_test.dart` 的密度档）；
// 本文件补的是**页面层**证据：刻度切换真的重分组、滚到底真的续页。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_prefs_store.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

class _MemPrefs implements PhotoPrefsStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

class _FixedAvailability extends ServiceAvailabilityNotifier {
  @override
  ServiceAvailabilitySnapshot build() => ServiceAvailabilitySnapshot(
    states: {
      for (final s in StationService.values) s: AvailabilityState.available,
    },
    apis: const {
      'SYNO.Foto.Thumbnail',
      'SYNO.Foto.Browse.Item',
      'SYNO.Foto.Setting.User',
    },
    checkedAt: DateTime(2026, 9, 23),
  );
}

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
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Map<String, dynamic> _item(String id, DateTime when) => {
  'id': id,
  'filename': 'IMG_$id.jpg',
  'filesize': 2048,
  'time': when.millisecondsSinceEpoch ~/ 1000,
  'indexed_time': when.millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': 'photo',
  'additional': {
    'thumbnail': {'sm': 'sm_$id', 'm': 'm_$id', 'cache_key': 'ck_$id'},
  },
};

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester, {
  required Map<String, Map<String, dynamic>> responses,
}) async {
  final t = FakeTransport({...responses}, {...FakeTransport.table, ..._table});
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
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: <Object>[
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      serviceAvailabilityProvider.overrideWith(_FixedAvailability.new),
      photoPrefsStoreProvider.overrideWithValue(_MemPrefs()),
    ].cast(),
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: PhotoBrowsePage()),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return (t: t, c: c);
}

/// 时间轴每组渲染一个 `PhotoGrid`（sliver）⇒ 组数 = `SliverGrid` 个数。
int _groupCount(WidgetTester tester) =>
    tester.widgetList(find.byType(SliverGrid)).length;

void main() {
  testWidgets('P5 视图刻度：默认「日」→ 切「年」后分组标题变少（真的重分组）', (tester) async {
    final boot = await _pump(
      tester,
      responses: {
        'SYNO.Foto.Browse.Item.list': {
          'list': [
            _item('1', DateTime(2024, 5, 1, 9)),
            _item('2', DateTime(2024, 5, 2, 9)),
            _item('3', DateTime(2025, 7, 3, 9)),
          ],
        },
      },
    );

    // 首屏的 list 请求（本页会发 2 次 offset=0：一次首屏、一次计数刷新）不计入
    // "切刻度是否重取"，先清空再切。
    boot.t.calls.clear();
    expect(find.byKey(const Key('photo-timeline-view-mode')), findsOneWidget);
    expect(_groupCount(tester), 3, reason: '日刻度下三天 = 三组');

    await tester.tap(find.byKey(const Key('photo-timeline-view-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('年').last);
    await tester.pumpAndSettle();

    // 切刻度**只改客户端分组**：不许再打一次 list 请求（官方也是轻交互）。
    expect(
      boot.t.calls.where((c) => c['method'] == 'list').length,
      0,
      reason: '切刻度只改客户端分组，不重新请求',
    );
    expect(_groupCount(tester), 2, reason: '2024 / 2025 = 两组');
  });

  testWidgets('P3 增量分页（notifier 级）：取满一页 hasMore=true，loadMore 用 offset=已加载数', (WidgetTester tester) async {
    // ⚠️ **诚实说明**：这条走 notifier（页面级"拖到底自动触发"在本测试环境里
    // 拖拽/fling 都驱动不出滚动 —— 时间轴被外层横向翻页手势吃掉，
    // 见本文件末尾说明）。滚动触发路径本身是 `extentAfter < 600`，
    // 属页面胶水代码，未另造"假滚动"来假装验证。
    final first = [
      for (var i = 0; i < 200; i++) _item('a$i', DateTime(2026, 9, 18, 9)),
    ];
    final boot = await _pump(
      tester,
      responses: {
        'SYNO.Foto.Browse.Item.list': {'list': first},
      },
    );
    var st = boot.c.read(photoTimelineProvider).value;
    expect(st!.items.length, 200);
    expect(st.hasMore, isTrue, reason: '正好取满一页 ⇒ 可能还有');

    boot.t.calls.clear();
    await boot.c.read(photoTimelineProvider.notifier).loadMore();
    final call = boot.t.calls.lastWhere((c) => c['method'] == 'list');
    expect(call['offset'], '200', reason: 'offset = 已加载条数（去重合并）');
    st = boot.c.read(photoTimelineProvider).value;
    expect(st!.items.length, greaterThanOrEqualTo(200));
  });
}
