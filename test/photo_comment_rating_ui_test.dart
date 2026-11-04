// 相册 P40（评分）页面层离线承重：星级控件 / 弹层 / 入口门控 / 成功与失败反馈。
//
// 接口层证据见 `test/photo_comment_rating_test.dart` 的文件头（官方 APK
// `ApiBrowseItem` 的 `set` + `rating`，能力位 `Browse.Item.maxVersion >= 2`）。
//
// 本文件覆盖：
//   * `PhotoRatingBar`：只读/可交互两种形态、满星/空星、未评分文案、清除；
//   * 大图页 AppBar 入口：能力位为真才渲染（缺失 → findsNothing，不是置灰）；
//   * 信息面板里的评分行：同样按能力位出现 / 消失；
//   * 评分弹层：点第 N 颗星 → `Browse.Item/set`（`rating` 裸十进制串）；
//   * 错误态：服务端拒绝 → 弹「设置评分失败：…」人话；
//   * 多选栏：批量评分入口同门控。
//
// ⚠️ §5.1：全部走 `FakeTransport` 离线桩，**不真调**任何变更动词方法。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_rating.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

Map<String, Map<String, dynamic>> _table(int itemMaxVersion) => {
  ...FakeTransport.table,
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': itemMaxVersion,
  },
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

Map<String, dynamic> _itemJson(String id, {int? rating}) => {
  'id': id,
  'filename': 'IMG_$id.jpg',
  'filesize': 1024,
  'time': DateTime(2026, 9, 18, 10).millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': 'photo',
  'additional': {
    'thumbnail': {'sm': 'sm_$id', 'm': 'm_$id', 'cache_key': 'ck'},
    if (rating != null) 'rating': rating,
  },
};

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  int itemMaxVersion = 7,
  Map<String, int> failures = const {},
}) async {
  final t = FakeTransport(<String, Map<String, dynamic>>{
    'SYNO.Foto.Setting.User.get': {
      'team_space_permission': 'none',
      'timeline_group_unit': 'day',
      'item_sort_by': 'takentime',
      'sort_direction': 'desc',
    },
  }, _table(itemMaxVersion));
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (key == 'SYNO.Foto.Browse.Item.list') {
      return {
        'list': [_itemJson('1', rating: 2)],
        'total': 1,
      };
    }
    return t.responses[key] ?? const <String, dynamic>{};
  };
  t.failures.addAll(failures);
  final api = await _loggedIn(t);
  final c = ProviderContainer(
    overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (t: t, c: c);
}

IconData _starIcon(WidgetTester tester, int star) {
  final icon = tester.widget<Icon>(
    find.descendant(
      of: find.byKey(Key('photo-rating-star-$star')),
      matching: find.byType(Icon),
    ),
  );
  return icon.icon!;
}

void main() {
  group('PhotoRatingBar 控件', () {
    testWidgets('只读：rating=3 → 前三颗实心、后两颗空心', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: PhotoRatingBar(rating: 3))),
      );
      expect(_starIcon(tester, 1), Icons.star);
      expect(_starIcon(tester, 3), Icons.star);
      expect(_starIcon(tester, 4), Icons.star_border);
      expect(_starIcon(tester, 5), Icons.star_border);
    });

    testWidgets('交互：点第 4 颗星 → onChanged(4)', (tester) async {
      final picked = <int>[];
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: PhotoRatingBar(rating: 0, onChanged: picked.add),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('photo-rating-star-4')));
      expect(picked, [4]);
    });

    testWidgets('交互 + showClear：点「未评分」→ onChanged(0)', (tester) async {
      final picked = <int>[];
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: PhotoRatingBar(
              rating: 5,
              showClear: true,
              onChanged: picked.add,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('photo-rating-clear')));
      expect(picked, [0]);
    });

    testWidgets('只读且未评分 → 显示「未评分」空态文案', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: PhotoRatingBar(rating: 0))),
      );
      expect(find.byKey(const Key('photo-rating-unrated')), findsOneWidget);
    });

    testWidgets('只读形态下点星星不会触发回调（没有按钮）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: PhotoRatingBar(rating: 2))),
      );
      final btn = tester.widget<IconButton>(
        find.byKey(const Key('photo-rating-star-4')),
      );
      expect(btn.onPressed, isNull);
    });
  });

  group('大图页入口门控（能力位）', () {
    testWidgets('Browse.Item v7 → AppBar 出现评分入口', (tester) async {
      final r = await _pump(
        tester,
        PhotoViewerPage(items: [FotoItemDto.fromJson(_itemJson('1'))]),
      );
      expect(find.byKey(const Key('photo-rating')), findsOneWidget);
      // 既有入口不倒退
      expect(find.byKey(const Key('photo-rotate')), findsOneWidget);
      expect(r.t.calls, isNotEmpty);
    });

    testWidgets('Browse.Item v1（老 Photos）→ 评分入口整个不渲染', (tester) async {
      await _pump(
        tester,
        PhotoViewerPage(items: [FotoItemDto.fromJson(_itemJson('1'))]),
        itemMaxVersion: 1,
      );
      expect(find.byKey(const Key('photo-rating')), findsNothing);
      // 其它入口照常
      expect(find.byKey(const Key('photo-rotate')), findsOneWidget);
    });
  });

  group('信息面板里的评分行', () {
    testWidgets('支持 → 打开信息能看到评分控件与当前星级', (tester) async {
      await _pump(
        tester,
        PhotoViewerPage(
          items: [FotoItemDto.fromJson(_itemJson('1', rating: 3))],
        ),
      );
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-info-rating')), findsOneWidget);
      expect(_starIcon(tester, 3), Icons.star);
      expect(_starIcon(tester, 4), Icons.star_border);
    });

    testWidgets('不支持 → 信息面板里没有评分行（不是置灰）', (tester) async {
      await _pump(
        tester,
        PhotoViewerPage(items: [FotoItemDto.fromJson(_itemJson('1'))]),
        itemMaxVersion: 1,
      );
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-info-rating')), findsNothing);
    });
  });

  group('评分弹层与写入链路', () {
    testWidgets('点评分入口 → 弹层 → 选 4 星 → Browse.Item/set(rating=4)', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        PhotoViewerPage(items: [FotoItemDto.fromJson(_itemJson('1'))]),
      );
      await tester.tap(find.byKey(const Key('photo-rating')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-rating-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-rating-star-4')));
      await tester.pumpAndSettle();

      final call = r.t.calls.lastWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Foto.Browse.Item.set',
      );
      expect('${call['version']}', '7');
      expect(call['rating'], '4');
      expect(call['id'], '[1]');
      expect(find.textContaining('已设置评分'), findsOneWidget);
    });

    testWidgets('选「未评分」→ rating=0', (tester) async {
      final r = await _pump(
        tester,
        PhotoViewerPage(
          items: [FotoItemDto.fromJson(_itemJson('1', rating: 3))],
        ),
      );
      await tester.tap(find.byKey(const Key('photo-rating')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-rating-clear')));
      await tester.pumpAndSettle();

      final call = r.t.calls.lastWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Foto.Browse.Item.set',
      );
      expect(call['rating'], '0');
    });

    testWidgets('服务端拒绝（105 无权限）→ 弹人话，不静默失败', (tester) async {
      await _pump(
        tester,
        PhotoViewerPage(items: [FotoItemDto.fromJson(_itemJson('1'))]),
        failures: {'SYNO.Foto.Browse.Item.set': 105},
      );
      await tester.tap(find.byKey(const Key('photo-rating')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-rating-star-5')));
      await tester.pumpAndSettle();
      expect(find.textContaining('设置评分失败'), findsOneWidget);
    });
  });

  group('多选栏批量评分（官方 dialog_set_ratings）', () {
    testWidgets('支持 → 出现评分按钮；不支持 → 不出现', (tester) async {
      Future<void> pump(int maxVersion) => _pump(
        tester,
        Scaffold(
          body: PhotoSelectionBar(
            items: [FotoItemDto.fromJson(_itemJson('1'))],
            space: FotoSpace.personal,
            onClear: () {},
            onAddToAlbum: () {},
          ),
        ),
        itemMaxVersion: maxVersion,
      );
      await pump(7);
      expect(find.byKey(const Key('photo-selection-rating')), findsOneWidget);
      await pump(1);
      expect(find.byKey(const Key('photo-selection-rating')), findsNothing);
    });

    testWidgets('批量选 3 星 → 一次性把整批 id 发出去', (tester) async {
      final r = await _pump(
        tester,
        Scaffold(
          body: PhotoSelectionBar(
            items: [
              FotoItemDto.fromJson(_itemJson('1')),
              FotoItemDto.fromJson(_itemJson('2')),
            ],
            space: FotoSpace.personal,
            onClear: () {},
            onAddToAlbum: () {},
          ),
        ),
      );
      await tester.ensureVisible(
        find.byKey(const Key('photo-selection-rating')),
      );
      await tester.tap(find.byKey(const Key('photo-selection-rating')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-rating-star-3')));
      await tester.pumpAndSettle();
      final call = r.t.calls.lastWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Foto.Browse.Item.set',
      );
      expect(call['rating'], '3');
      expect(call['id'], '[1,2]');
    });
  });
}
