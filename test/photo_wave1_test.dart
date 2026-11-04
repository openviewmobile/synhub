// 相册 wave1：时间轴分页 / 年视图 / 相册排序 / 移到复制到文件夹 / 缩略图就绪态。
//
// 全部离线（假 transport），钉死**请求参数形态**与**状态机行为**：
//   * A14：时间轴 >200 张必须能触底续取（以前单次 `limit:200` 就断了）。
//     分页走 `Browse.Item/list` 的 `offset`/`limit`（真机实探
//     `docs/photo-api-live.md` §2/§4 确认 OK，且 `Browse.Diff` 不是翻页游标）；
//   * 年视图：`timeline_group_unit` 之外客户端可切 year（官方 `str_year_view_mode`）；
//   * A15：`Browse.Album/get|set_album_list_order`（下限 v2）+ `list` 的
//     `sort_by`/`sort_direction`；
//   * 批量移动/复制：`Browse.Item/move|copy` 的
//     `id`（数字数组 JSON 串）+ `target_folder_id`（裸数字）+ `action`；
//   * 缩略图每个尺寸独立就绪态（`preview: "broken"` 真实存在）。
import 'dart:convert';

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
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// 时间轴用例的 fake 服务端：按 `offset/limit` 切片，验证分页。
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
    'maxVersion': 3,
  },
  'SYNO.Foto.Browse.Folder': {
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

Map<String, dynamic> _itemJson(String id, DateTime t) => {
  'id': id,
  'filename': 'IMG_$id.jpg',
  'filesize': 2048,
  'time': t.millisecondsSinceEpoch ~/ 1000,
  'indexed_time': t.millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': 'photo',
  'additional': {
    'thumbnail': {
      'sm': 'ready',
      'm': 'ready',
      'xl': 'ready',
      'preview': 'broken',
      'cache_key': 'ck_$id',
      'unit_id': 9000,
    },
    'favorite': false,
  },
};

DateTime _stamp(int i) => DateTime(2026, 9, 1).add(Duration(minutes: i));

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

Map<String, dynamic> _settingReply({String timelineUnit = 'day'}) => {
  'team_space_permission': 'none',
  'enable_person': false,
  'timeline_group_unit': timelineUnit,
  'item_sort_by': 'takentime',
  'sort_direction': 'desc',
};

/// 分页切片回包（`Browse.Item/list`）
Map<String, dynamic> _page(int offset, int limit, int total) {
  final end = (offset + limit).clamp(0, total);
  return {
    'list': [for (var i = offset; i < end; i++) _itemJson('$i', _stamp(i))],
    'total': total,
  };
}

/// 挂相册页；[onCall] 完全由用例决定回包。
Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester, {
  required Map<String, dynamic>? Function(Map<String, dynamic>) onCall,
}) async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
  t.downloadBytes = _png;
  t.onCall = onCall;
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: PhotoBrowsePage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (t: t, c: c);
}

/// 纯 provider 级挂载（不渲染 widget，避免几百个格子拖慢用例）
Future<ProviderContainer> _container(FakeTransport t) async {
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  // `photoTimelineProvider` 是 autoDispose：只 `read` 会让它在 loading 中就被
  // 调度销毁（`disposed during loading state`）。留一个订阅把它钉住。
  final sub = c.listen(photoTimelineProvider, (_, _) {});
  addTearDown(sub.close);
  return c;
}

void main() {
  group('A14 时间轴增量分页（>200 张）', () {
    test('超过单页 200 张时触底续取，offset 递增到取完', () async {
      const total = 450;
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.downloadBytes = _png;
      t.onCall = (params) {
        final method = '${params['method']}';
        final api = '${params['api']}';
        if (api.endsWith('Setting.User')) return _settingReply();
        if (api.endsWith('Browse.Item') && method == 'list') {
          return _page(
            int.parse('${params['offset'] ?? 0}'),
            int.parse('${params['limit'] ?? 0}'),
            total,
          );
        }
        return null;
      };
      final c = await _container(t);
      final first = await c.read(photoTimelineProvider.future);
      expect(first.items.length, kFotoTimelinePageSize);
      expect(first.hasMore, isTrue);

      await c.read(photoTimelineProvider.notifier).loadMore();
      var state = c.read(photoTimelineProvider).value!;
      expect(state.items.length, 400);
      expect(state.hasMore, isTrue);

      await c.read(photoTimelineProvider.notifier).loadMore();
      state = c.read(photoTimelineProvider).value!;

      final offsets = [
        for (final call in t.calls)
          if ('${call['api']}'.endsWith('Browse.Item') &&
              call['method'] == 'list')
            '${call['offset']}',
      ];
      // ↓ 这两条就是 P0 的 falsification 锚点：退回单次 `limit:200` 时，
      //   条数停在 200、也永远不会出现 offset=200。
      expect(
        state.items.length,
        greaterThan(200),
        reason: '时间轴必须能加载超过单页 200 张（分页状态机失效则停在 200）',
      );
      expect(
        offsets,
        contains('200'),
        reason: '触底续取必须用 offset=200 取第二页，而不是单次 limit:200',
      );
      expect(state.items.length, total);
      expect(state.hasMore, isFalse, reason: '不足一页即收尾');
      expect(state.items.map((e) => e.id).toSet().length, total);
    });

    test('重复页（服务端回同一批）不会死循环，会收尾', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.downloadBytes = _png;
      var served = 0;
      t.onCall = (params) {
        final method = '${params['method']}';
        final api = '${params['api']}';
        if (api.endsWith('Setting.User')) return _settingReply();
        if (api.endsWith('Browse.Item') && method == 'list') {
          // 永远回同一批满页（模拟服务端不认 offset）
          served++;
          return {
            'list': [
              for (var i = 0; i < kFotoTimelinePageSize; i++)
                _itemJson('$i', _stamp(i)),
            ],
          };
        }
        return null;
      };
      final c = await _container(t);
      await c.read(photoTimelineProvider.future);
      await c.read(photoTimelineProvider.notifier).loadMore();
      final state = c.read(photoTimelineProvider).value!;
      final offsets = [
        for (final call in t.calls)
          if ('${call['api']}'.endsWith('Browse.Item') &&
              call['method'] == 'list')
            '${call['offset']}',
      ];
      expect(state.hasMore, isFalse, reason: '本页零新增必须收尾，不能无限翻页');
      expect(state.items.length, kFotoTimelinePageSize);
      expect(offsets, contains('200'));
      // 收尾后不再发新的翻页请求（重复页只取了一次 offset=200）
      expect(offsets.where((o) => o == '200').length, 1);
      expect(served, lessThanOrEqualTo(3));
    });

    testWidgets('滚到底自动续取下一页，并在末尾显示"已全部加载"', (tester) async {
      const total = 250;
      final boot = await _pump(
        tester,
        onCall: (params) {
          final method = '${params['method']}';
          final api = '${params['api']}';
          if (api.endsWith('Setting.User')) return _settingReply();
          if (api.endsWith('Browse.Item') && method == 'list') {
            return _page(
              int.parse('${params['offset'] ?? 0}'),
              int.parse('${params['limit'] ?? 0}'),
              total,
            );
          }
          return null;
        },
      );
      // 首屏只有一页
      expect(boot.c.read(photoTimelineProvider).value!.items.length, 200);
      expect(boot.c.read(photoTimelineProvider).value!.hasMore, isTrue);

      // 往下滚 → `NotificationListener` 在距底 <600px 时自动续取
      final vertical = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      );
      final offscreen = find.byKey(const Key('photo-timeline-all-loaded'));
      var i = 0;
      while (i < 40 && offscreen.evaluate().isEmpty) {
        await tester.drag(vertical.first, const Offset(0, -3000));
        await tester.pump();
        i++;
      }
      await tester.pump(const Duration(milliseconds: 300));

      final state = boot.c.read(photoTimelineProvider).value!;
      expect(state.items.length, total, reason: '触底应自动把第二页取回来');
      expect(state.hasMore, isFalse);
      expect(
        find.byKey(const Key('photo-timeline-all-loaded')),
        findsOneWidget,
      );
      final offsets = [
        for (final call in boot.t.calls)
          if ('${call['api']}'.endsWith('Browse.Item') &&
              call['method'] == 'list')
            '${call['offset']}',
      ];
      expect(offsets, contains('200'));
    });
  });

  group('A14 年视图', () {
    test('groupPhotos(unit: year) 按年分组', () {
      final items = [
        FotoItemDto.fromJson(_itemJson('1', DateTime(2026, 9, 1))),
        FotoItemDto.fromJson(_itemJson('2', DateTime(2026, 3, 1))),
        FotoItemDto.fromJson(_itemJson('3', DateTime(2025, 12, 1))),
      ];
      final groups = groupPhotos(items, unit: 'year');
      expect(groups.map((e) => e.$1).toList(), ['2026 年', '2025 年']);
      expect(groups.first.$2.length, 2);
    });

    testWidgets('时间刻度菜单可切到"年"，分组标题变成年份', (tester) async {
      await _pump(
        tester,
        onCall: (params) {
          final method = '${params['method']}';
          final api = '${params['api']}';
          if (api.endsWith('Setting.User')) return _settingReply();
          if (api.endsWith('Browse.Item') && method == 'list') {
            return {
              'list': [
                _itemJson('1', DateTime(2026, 9, 1)),
                _itemJson('2', DateTime(2025, 12, 1)),
              ],
            };
          }
          return null;
        },
      );
      expect(find.text('2026 年 9 月 1 日'), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-timeline-view-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('年').last);
      await tester.pumpAndSettle();
      expect(find.text('2026 年'), findsOneWidget);
      expect(find.text('2025 年'), findsOneWidget);
      expect(find.text('2026 年 9 月 1 日'), findsNothing);
    });
  });

  group('A15 相册排序', () {
    testWidgets('读取服务端默认排序，切换后写回 set_album_list_order', (tester) async {
      final boot = await _pump(
        tester,
        onCall: (params) {
          final method = '${params['method']}';
          final api = '${params['api']}';
          if (api.endsWith('Setting.User')) return _settingReply();
          if (api.endsWith('Browse.Album') &&
              method == 'get_album_list_order') {
            return {
              'data': {
                'album_list_sort_by': 'album_name',
                'album_list_sort_direction': 'asc',
              },
            };
          }
          if (api.endsWith('Browse.Album') && method == 'list') {
            return {
              'list': [
                {
                  'id': 'a1',
                  'name': '旅行',
                  'item_count': 1,
                  'type': 'normal',
                  'additional': {'thumbnail': <String, dynamic>{}},
                },
              ],
            };
          }
          if (api.endsWith('Browse.NormalAlbum') && method == 'list') {
            return {'list': <dynamic>[]};
          }
          if (api.endsWith('Browse.Album') &&
              method == 'set_album_list_order') {
            return {'data': <String, dynamic>{}};
          }
          return null;
        },
      );
      await tester.tap(find.text('相册').last);
      await tester.pumpAndSettle();

      // 服务端默认排序是否真的被读到（先钉 DTO/请求这一层）
      expect(
        boot.c.read(photoAlbumListOrderProvider).value?.sortBy,
        'album_name',
        reason: 'get_album_list_order 的服务端默认应被解析出来',
      );

      // 服务端默认 album_name/asc 被用于 Album/list
      final listCalls = [
        for (final c in boot.t.calls)
          if ('${c['api']}'.endsWith('Browse.Album') && c['method'] == 'list')
            c,
      ];
      expect(listCalls, isNotEmpty);
      expect(listCalls.map((c) => c['sort_by']), contains('album_name'));
      expect(listCalls.map((c) => c['sort_direction']), contains('asc'));

      // 点方向 → 写回 desc
      await tester.tap(find.byKey(const Key('photo-album-sort-direction')));
      await tester.pumpAndSettle();
      final setCall = boot.t.calls.firstWhere(
        (c) => c['method'] == 'set_album_list_order',
      );
      expect(setCall['album_list_sort_by'], 'album_name');
      expect(setCall['album_list_sort_direction'], 'desc');

      // ★ r523（DA166）：排序行不再画「相册排序」这个视觉标签（英文下会被
      // 两颗 chip 挤成两行）。这里反向钉住：**行内只剩下控件**，标签只在
      // `Semantics` 里（读屏仍可读）。
      expect(find.text('相册排序'), findsNothing,
          reason: 'DA166：视觉标签应已移除（改由 Semantics 承担）');
      // 切换字段 → 写回 create_time
      await tester.tap(find.byKey(const Key('photo-album-sort-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建时间').last);
      await tester.pumpAndSettle();
      final setCalls = [
        for (final c in boot.t.calls)
          if (c['method'] == 'set_album_list_order') c,
      ];
      expect(setCalls.last['album_list_sort_by'], 'create_time');
      final after = [
        for (final c in boot.t.calls)
          if ('${c['api']}'.endsWith('Browse.Album') && c['method'] == 'list')
            c,
      ];
      expect(after.last['sort_by'], 'create_time');
      // 版本下限：v2（真机 v1 → 103）；请求参数一律字符串化
      expect(setCall['version'], '5');
    });

    test('老服务器只有 v1 时，negotiate 不假装支持 v2+（方法本就不存在）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._table,
        'SYNO.Foto.Browse.Album': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      });
      final api = await _loggedIn(t);
      final foto = FotoApi(api);
      // 只验协商结果：v2+ 的下限不被"猜"成 v1 可用（真机 v1 → 103）
      expect(foto.negotiate('SYNO.Foto.Browse.Album', const [5, 4, 3, 2]), 1);
    });
  });

  group('批量移动 / 复制（Browse.Item/move|copy）', () {
    test('请求形态：id 数字数组串 + target_folder_id 裸数字 + action', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      final api = await _loggedIn(t);
      final foto = FotoApi(api);
      t.onCall = (params) {
        if ('${params['api']}'.endsWith('Browse.Item')) {
          return {'error_list': <dynamic>[]};
        }
        return null;
      };
      final failed = await foto.moveItems(
        itemIds: ['9547', '9548'],
        targetFolderId: '10',
      );
      expect(failed, isEmpty);
      final move = t.calls.firstWhere((c) => c['method'] == 'move');
      expect(move['id'], '[9547,9548]');
      expect(move['target_folder_id'], '10');
      expect(move['action'], 'skip');

      await foto.copyItems(
        itemIds: ['9547'],
        targetFolderId: '11',
        action: FotoCopyMoveAction.overwrite,
      );
      final copy = t.calls.firstWhere((c) => c['method'] == 'copy');
      expect(copy['id'], '[9547]');
      expect(copy['target_folder_id'], '11');
      expect(copy['action'], 'overwrite');
    });

    test('目标目录 id 非数字：不发请求，整批如实回报失败', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      final api = await _loggedIn(t);
      final foto = FotoApi(api);
      final before = t.calls.length;
      final failed = await foto.moveItems(
        itemIds: ['1', '2'],
        targetFolderId: 'not-a-number',
      );
      expect(failed, ['1', '2']);
      expect(t.calls.length, before);
    });

    testWidgets('多选栏"移到文件夹"选目录后发出 move', (tester) async {
      final boot = await _pump(
        tester,
        onCall: (params) {
          final method = '${params['method']}';
          final api = '${params['api']}';
          if (api.endsWith('Setting.User')) return _settingReply();
          if (api.endsWith('Browse.Item') && method == 'list') {
            return {
              'list': [
                _itemJson('1', DateTime(2026, 9, 1)),
                _itemJson('2', DateTime(2026, 9, 2)),
              ],
            };
          }
          if (api.endsWith('Browse.Folder') && method == 'list') {
            return {
              'list': [
                {'id': '10', 'name': 'Photos', 'parent_id': '0'},
              ],
            };
          }
          if (api.endsWith('Browse.Item') && method == 'move') {
            return {'error_list': <dynamic>[]};
          }
          return null;
        },
      );
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-selection-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photos').last);
      await tester.pumpAndSettle();
      final move = boot.t.calls.firstWhere((c) => c['method'] == 'move');
      expect(move['target_folder_id'], '10');
      expect(move['id'], contains('1'));
    });

    testWidgets('move 失败时逐条回报（全部失败）', (tester) async {
      final boot = await _pump(
        tester,
        onCall: (params) {
          final method = '${params['method']}';
          final api = '${params['api']}';
          if (api.endsWith('Setting.User')) return _settingReply();
          if (api.endsWith('Browse.Item') && method == 'list') {
            return {
              'list': [_itemJson('1', DateTime(2026, 9, 1))],
            };
          }
          if (api.endsWith('Browse.Folder') && method == 'list') {
            return {
              'list': [
                {'id': '10', 'name': 'Photos', 'parent_id': '0'},
              ],
            };
          }
          return null;
        },
      );
      boot.t.failures['SYNO.Foto.Browse.Item.move'] = 802;
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-selection-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photos').last);
      await tester.pumpAndSettle();
      // 失败提示里出现"失败"字样（不是静默）
      expect(find.textContaining('失败'), findsWidgets);
    });
  });

  group('缩略图每尺寸就绪态（真机回包 preview:"broken"）', () {
    test('bestSize 跳过 broken，不回内部 id', () {
      // 真机 `docs/photo-api-live.md` §3：sm/m/xl=ready、preview=broken
      final ok = FotoThumbDto.fromJson({
        'sm': 'ready',
        'm': 'ready',
        'xl': 'ready',
        'preview': 'broken',
        'cache_key': '9320_1789922099',
        'unit_id': 9320,
      });
      expect(ok.bestSize, 'sm');
      expect(ok.hasAny, isTrue);

      // sm broken → 降到 m
      final mOnly = FotoThumbDto.fromJson({
        'sm': 'broken',
        'm': 'ready',
        'xl': 'not_ready',
        'preview': 'broken',
      });
      expect(mOnly.bestSize, 'm');

      // 全 broken → 仍然给一个档位名（UI 那边取不到就画占位图标），
      // 绝不把 cache_key / unit_id 当图片地址
      final allBroken = FotoThumbDto.fromJson({
        'sm': 'broken',
        'm': 'broken',
        'xl': 'broken',
        'preview': 'broken',
      });
      expect(allBroken.hasAny, isFalse);
      expect(allBroken.bestSize, 'sm');
    });
  });
}
