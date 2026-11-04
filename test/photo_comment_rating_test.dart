// 相册 P40（评分）+ P39（评论：登记为 ➖ 非缺口）接口层离线承重。
//
// ## 为什么是这些方法（逐条取证）
// 官方 APK 2.4.0-644（jadx 1.5.3）
// `com/synology/projectkailash/datasource/network/api/ApiBrowseItem.java`：
//   * `:55` `API_ID = "Browse.Item"`、`:56` `API_VERSION = 7`；
//   * `:42` `METHOD_SET = "set"`、`:71` `KEY_RATING = "rating"`；
//   * `:97` `SUPPORT_RATING_VERSION = 2`；
//   * `:53` `ADDITIONAL_RATING = "rating"`（读取走 `additional`）；
//   * `:1208-1210` `map.put("rating", String.valueOf(num.intValue()))`
//     —— 值是**十进制字符串、不带 JSON 引号**；
//   * `ConnectionManager.java:1814` `isSupportRating = Browse.Item.maxVersion >= 2`；
//   * `ApiBrowseItem.filterByApiVersion`（`:1386`）按能力位把 `"rating"` 从
//     `additional` 里裁掉。
//
// ## 本文件覆盖
//   * DTO：`additional.rating` 解析 / 缺键归 0 / 顶层回落 / `hasRating`；
//   * 能力位：`Browse.Item` maxVersion ≥ 2 → `supportsRating == true`；
//   * `additional`：能力位为真才带 `rating`（对齐官方 filterByApiVersion）；
//   * `setItemRating`：api/method/version/参数形态（`id` 数字数组串 + `rating`
//     裸十进制串）+ 0..5 收敛；`clearItemRating` = 0；
//   * 门控：能力位缺失 → **不发请求**并抛 `FotoRatingUnsupportedException`。
//
// ⚠️ §5.1：本文件**不真调**任何变更动词方法（全部走 FakeTransport 离线桩），
// 下面对 `set` 的调用只是"离线用例"，不会打到任何真实 NAS。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 一份"对方是支持的服务器"的能力表（`Browse.Item` v7）。
Map<String, Map<String, dynamic>> _table(int itemMaxVersion) => {
  ...FakeTransport.table,
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': itemMaxVersion,
  },
  'SYNO.Foto.Browse.RecentlyAdded': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': itemMaxVersion,
  },
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

FakeTransport _transport(int itemMaxVersion) =>
    FakeTransport(<String, Map<String, dynamic>>{}, _table(itemMaxVersion));

Map<String, dynamic> _lastSet(FakeTransport t) =>
    t.calls.lastWhere((c) => '${c['method']}' == 'set');

int _callCount(FakeTransport t, String key) =>
    t.calls.where((c) => '${c['api']}.${c['method']}' == key).length;

void main() {
  group('评分 DTO（additional.rating）', () {
    test('additional.rating=3 → rating=3，hasRating=true', () {
      final dto = FotoItemDto.fromJson({
        'id': '1',
        'filename': 'a.jpg',
        'additional': {'rating': 3},
      });
      expect(dto.rating, 3);
      expect(dto.hasRating, isTrue);
    });

    test('没有 rating 键 → 0（未评分），不是"解析失败"', () {
      final dto = FotoItemDto.fromJson({
        'id': '1',
        'filename': 'a.jpg',
        'additional': {'thumbnail': <String, dynamic>{}},
      });
      expect(dto.rating, 0);
      expect(dto.hasRating, isFalse);
    });

    test('additional 被剥掉、rating 在顶层 → 两种形态都认', () {
      final dto = FotoItemDto.fromJson({
        'id': '1',
        'filename': 'a.jpg',
        'rating': 5,
      });
      expect(dto.rating, 5);
      expect(dto.hasRating, isTrue);
    });

    test('rating=0（服务端明确回 0）→ 未评分', () {
      final dto = FotoItemDto.fromJson({
        'id': '1',
        'filename': 'a.jpg',
        'additional': {'rating': 0},
      });
      expect(dto.rating, 0);
      expect(dto.hasRating, isFalse);
    });
  });

  group('评分能力位（Browse.Item maxVersion >= 2）', () {
    test('v7 → supportsRating=true', () async {
      final api = await _loggedIn(_transport(7));
      expect(FotoApi(api).supportsRating, isTrue);
    });

    test('v2（官方 SUPPORT_RATING_VERSION 的下界）→ true', () async {
      final api = await _loggedIn(_transport(2));
      expect(FotoApi(api).supportsRating, isTrue);
    });

    test('v1 → false（老 Photos 没有评分）', () async {
      final api = await _loggedIn(_transport(1));
      expect(FotoApi(api).supportsRating, isFalse);
    });

    test('能力表里没有 Browse.Item → false（宁可不给入口）', () async {
      final t = FakeTransport(<String, Map<String, dynamic>>{}, {
        ...FakeTransport.table,
      });
      final api = await _loggedIn(t);
      expect(FotoApi(api).supportsRating, isFalse);
    });

    test('团队空间（FotoTeam）单独判：只看自己前缀的 maxVersion', () async {
      final t = FakeTransport(<String, Map<String, dynamic>>{}, {
        ...FakeTransport.table,
        'SYNO.Foto.Browse.Item': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 7,
        },
        'SYNO.FotoTeam.Browse.Item': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      });
      final api = await _loggedIn(t);
      expect(FotoApi(api).supportsRating, isTrue);
      expect(FotoApi(api, space: FotoSpace.team).supportsRating, isFalse);
    });
  });

  group('additional 的 rating 键按能力位裁剪', () {
    test('支持 → timeline 的 additional 里带 rating', () async {
      final t = _transport(7);
      final api = await _loggedIn(t);
      await FotoApi(api).timeline();
      final call = t.calls.lastWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Foto.Browse.Item.list',
      );
      expect(jsonDecode(call['additional'] as String), contains('rating'));
    });

    test('不支持 → additional 里不带 rating（老服务器不认这个键）', () async {
      final t = _transport(1);
      final api = await _loggedIn(t);
      await FotoApi(api).timeline();
      final call = t.calls.lastWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Foto.Browse.Item.list',
      );
      expect(
        jsonDecode(call['additional'] as String),
        isNot(contains('rating')),
      );
    });

    test('itemAdditional 不重复追加（调用方自己带了 rating 也只一份）', () async {
      final api = await _loggedIn(_transport(7));
      final foto = FotoApi(api);
      final out = foto.itemAdditional(['thumbnail', 'rating']);
      // 支持 motion_photo 的服务器（v7 ≥ 3）还会追加 motion_photo（P13 同期实现）；
      // 本用例只钉"rating 不重复"。
      expect(out.where((e) => e == 'rating').length, 1);
      expect(out, contains('rating'));
    });

    test('收藏列表 / 相册列表的 additional 同样带 rating（支持时）', () async {
      final t = _transport(7);
      final api = await _loggedIn(t);
      final foto = FotoApi(api);
      await foto.favorites();
      await foto.albumItems('7');
      await foto.folderItems('9');
      await foto.recentlyAdded();
      for (final c in t.calls.where(
        (c) => '${c['method']}' == 'list' && '${c['api']}'.contains('Browse'),
      )) {
        expect(jsonDecode(c['additional'] as String), contains('rating'));
      }
    });
  });

  group('setItemRating 参数形态（官方 ApiBrowseItem:478-479 / 1208-1210）', () {
    test('api/method/version + id 数字数组串 + rating 裸十进制串', () async {
      final t = _transport(7);
      final api = await _loggedIn(t);
      await FotoApi(api).setItemRating(['9547', '9548'], 4);
      final call = _lastSet(t);
      expect(call['api'], 'SYNO.Foto.Browse.Item');
      expect(call['method'], 'set');
      // 版本由能力表协商（候选 v7..v1，本表 maxVersion=7）
      expect('${call['version']}', '7');
      expect(jsonDecode(call['id'] as String), [9547, 9548]);
      // ⚠️ rating 不带 JSON 引号（与 rotate_action 不同）
      expect(call['rating'], '4');
      expect(call['rating'], isA<String>());
    });

    test('版本协商：能力表 maxVersion=5 → 发 5（不硬编码 7）', () async {
      final t = _transport(5);
      final api = await _loggedIn(t);
      await FotoApi(api).setItemRating(['1'], 2);
      expect('${_lastSet(t)['version']}', '5');
    });

    test('rating 越界收敛到 0..5', () async {
      final t = _transport(7);
      final api = await _loggedIn(t);
      final foto = FotoApi(api);
      await foto.setItemRating(['1'], 9);
      expect(_lastSet(t)['rating'], '5');
      await foto.setItemRating(['1'], -1);
      expect(_lastSet(t)['rating'], '0');
    });

    test('clearItemRating = rating 0（官方 rating_bar 的"未评分"）', () async {
      final t = _transport(7);
      final api = await _loggedIn(t);
      await FotoApi(api).clearItemRating(['7']);
      final call = _lastSet(t);
      expect(call['rating'], '0');
      expect(jsonDecode(call['id'] as String), [7]);
    });

    test('非数字 id → 不发请求（与其它写入口同口径）', () async {
      final t = _transport(7);
      final api = await _loggedIn(t);
      await FotoApi(api).setItemRating(['abc'], 3);
      expect(_callCount(t, 'SYNO.Foto.Browse.Item.set'), 0);
    });
  });

  group('评分门控：能力位缺失不发请求（§能力门控）', () {
    test(
      'Browse.Item v1 → setItemRating 抛 FotoRatingUnsupportedException',
      () async {
        final t = _transport(1);
        final api = await _loggedIn(t);
        await expectLater(
          FotoApi(api).setItemRating(['1'], 3),
          throwsA(isA<FotoRatingUnsupportedException>()),
        );
        expect(_callCount(t, 'SYNO.Foto.Browse.Item.set'), 0);
      },
    );

    test('能力表没有 Browse.Item → 同样抛 + 不发请求', () async {
      final t = FakeTransport(<String, Map<String, dynamic>>{}, {
        ...FakeTransport.table,
      });
      final api = await _loggedIn(t);
      await expectLater(
        FotoApi(api).clearItemRating(['1']),
        throwsA(isA<FotoRatingUnsupportedException>()),
      );
      expect(_callCount(t, 'SYNO.Foto.Browse.Item.set'), 0);
    });
  });

  group('社区域名不冲突：团队空间走 FotoTeam 前缀', () {
    test('team 空间的 set 发 SYNO.FotoTeam.Browse.Item.set', () async {
      final t = FakeTransport(<String, Map<String, dynamic>>{}, {
        ...FakeTransport.table,
        'SYNO.FotoTeam.Browse.Item': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 7,
        },
      });
      final api = await _loggedIn(t);
      await FotoApi(api, space: FotoSpace.team).setItemRating(['5'], 1);
      final call = _lastSet(t);
      expect(call['api'], 'SYNO.FotoTeam.Browse.Item');
      expect(call['rating'], '1');
      expect(jsonDecode(call['id'] as String), [5]);
    });
  });
}
