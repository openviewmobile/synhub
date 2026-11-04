// 相册「封面 / 文件夹封面 / 缩略状态门控」契约 —— 针对三条**真机取证**
// 缺陷的回归保护（证据：`docs/thumbnail-apis.md`，第 261 轮真 NAS 只读实测）。
//
//   1. **相册封面 id/type 配对**：`SYNO.Foto.Thumbnail:get` 的 `type` 与 `id`
//      **不可互换** —— `type=item` 只认 item id、`type=unit` 只认 unit id。
//      旧 `photoCoverRequest` 默认 `type=item` 却传 `cover.unit_id` ⇒ 真机 404。
//   2. **文件夹封面形态**：旧 `folderCoverUrl` 用 `type=folder`+`folder_cover_seq`
//      ⇒ v1 `120 type condition`、v2 **HTTP 502**。正解 = 候选 `unit_id` +
//      `type=unit`；且候选数组**第一项可能是坏视频**（`sm:"ame_defect"`），
//      必须挑就绪项。
//   3. **缩略状态门控**：`additional.thumbnail` 的 `sm/m/xl` 值可能是状态串
//      （`ame_defect`/`broken`/`not_ready`）—— 非 `ready` 表示"图坏了"，
//      不是"有图" ⇒ 必须画占位、**不发必然 404 的请求**。
//
// 全部离线（假 transport），断言的可观测点就是"请求里 `type`/`id` 配对"与
// "请求对象是不是 null"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Future<FotoApi> _api() async {
  final t = FakeTransport(<String, Map<String, dynamic>>{}, {
    ...FakeTransport.table,
    ..._table,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FotoApi(api);
}

/// 真机形态的缩略对象。`unit_id` 是真实数组里的一项。
FotoThumbDto _thumb({
  String sm = '',
  String m = '',
  String xl = '',
  String unitId = '',
  String cacheKey = 'ck',
}) => FotoThumbDto.fromJson({
  'sm': sm,
  'm': m,
  'xl': xl,
  'unit_id': unitId,
  'cache_key': cacheKey,
});

/// 真机视频例：`sm/m/xl = ame_defect`、`preview = broken`。
FotoThumbDto get _brokenVideo => _thumb(
  sm: 'ame_defect',
  m: 'ame_defect',
  xl: 'ame_defect',
  unitId: '9429',
  cacheKey: 'ck_bad',
);

FotoItemDto _item(FotoThumbDto thumb, {String id = '28045', String type = 'video'}) =>
    FotoItemDto.fromJson({
      'id': id,
      'filename': 'IMG_$id.mp4',
      'type': type,
      'additional': {
        'thumbnail': {
          'sm': thumb.sm,
          'm': thumb.m,
          'xl': thumb.xl,
          'unit_id': thumb.unitId,
          'cache_key': thumb.cacheKey,
        },
      },
    });

/// 取查询串里某个参数（**已 URL 解码**）。
///
/// 官方前端走 Gson，`type`/`size`/`cache_key` 在线上是**带引号的 JSON 串**
/// （`type="unit"` ⇒ 编码成 `type=%22unit%22`），只有 `id` 是裸值。
/// 所以断言要落在"解码后的值"上，而不是裸字符串 `type=unit`。
String? _q(String url, String key) => Uri.parse(url).queryParameters[key];

void main() {
  group('① 相册封面：id 在 unit_id，type 必须 unit', () {
    test('photoCoverRequest 产出的请求是 type=unit + id=unit_id', () async {
      final api = await _api();
      final cover = _thumb(sm: 'ready', unitId: '9428', cacheKey: 'ck_ok');
      final req = photoCoverRequest(cover, FotoSpace.personal);

      expect(req, isNotNull, reason: 'sm=ready 的封面必须能出图');
      expect(req!.thumbType, 'unit', reason: 'unit_id 必须配 type=unit');
      expect(req.itemId, '9428', reason: 'id 必须是 unit_id，不是照片 item id');

      // 端到端拼接：可观测到 URL 查询串里的 type/id 配对。
      final url = api.thumbnailUrl(
        itemId: req.itemId,
        cacheKey: req.cacheKey,
        size: req.size,
        type: req.thumbType,
      );
      expect(url, contains('api=SYNO.Foto.Thumbnail'), reason: url);
      expect(_q(url, 'type'), '"unit"', reason: url);
      expect(_q(url, 'id'), '9428', reason: url);
      expect(_q(url, 'type'), isNot('"item"'), reason: url);
    });

    test('封面状态非 ready / 缺 unit_id → 不产请求（画占位）', () {
      expect(
        photoCoverRequest(_brokenVideo, FotoSpace.personal),
        isNull,
        reason: 'ame_defect 是"图坏了"，发请求必然 404',
      );
      expect(
        photoCoverRequest(_thumb(sm: 'ready'), FotoSpace.personal),
        isNull,
        reason: '没有 unit_id 就没有封面可请求',
      );
      expect(photoCoverRequest(null, FotoSpace.personal), isNull);
    });
  });

  group('② Photos 文件夹封面：type=unit + 候选 unit_id', () {
    test('文件夹封面走 thumbnailUrl(type:unit)，不再用 type=folder/folder_cover_seq', () async {
      final api = await _api();
      // ★ 第 327 轮：`folderCoverUrl` 这个专用方法已删（§2.0.45 死功能 ——
      //   零产品调用点；而 `thumbnailUrl(type:'unit')` 是同一语义的既有实现）。
      //   界面侧改由 `_FolderCover` 调 `photoSmartAlbumCoverRequest` 生成请求。
      final url = api.thumbnailUrl(
        itemId: '9428',
        cacheKey: 'ck_ok',
        type: 'unit',
      );

      expect(url, contains('method=get'), reason: url);
      expect(_q(url, 'type'), '"unit"', reason: url);
      expect(_q(url, 'id'), '9428', reason: url);
      expect(_q(url, 'type'), isNot('"folder"'), reason: url);
      expect(url.contains('folder_cover_seq'), isFalse, reason: url);
    });

    test('cache_key 为空时不发这个参数（unit 候选常常没有）', () async {
      final api = await _api();
      final url = api.thumbnailUrl(itemId: '9428', cacheKey: '', type: 'unit');
      expect(url.contains('cache_key'), isFalse, reason: url);
      final withKey = api.thumbnailUrl(
        itemId: '9428',
        cacheKey: 'ck_ok',
        type: 'unit',
      );
      expect(_q(withKey, 'cache_key'), '"ck_ok"', reason: withKey);
    });

    test('候选数组不能盲取第一项：跳过 ame_defect 取 ready', () {
      final broken = _thumb(sm: 'ame_defect', unitId: '9429');
      final ready = _thumb(sm: 'ready', unitId: '9428');

      final picked = FotoApi.pickFolderCover([broken, ready]);
      expect(picked, isNotNull);
      expect(picked!.unitId, '9428', reason: '第一项是坏视频，必须跳过');
      expect(FotoApi.pickFolderCover([broken]), isNull, reason: '一个就绪的都没有');
      expect(FotoApi.pickFolderCover(const []), isNull);
    });
  });

  group('③ 缩略状态门控：非 ready 一律占位、不发请求', () {
    test('item 缩略图：ame_defect → null；就绪 → 按可用档位请求', () {
      final space = FotoSpace.personal;

      expect(photoThumbRequest(_item(_brokenVideo), space), isNull);

      final full = _item(
        _thumb(sm: 'ready', m: 'ready', xl: 'ready', unitId: '1'),
      );
      final m = photoThumbRequest(full, space, size: 'm');
      expect(m, isNotNull);
      expect(m!.size, 'm');
      expect(m.thumbType, 'item', reason: '照片条目走 item id + type=item');
      expect(m.itemId, '28045');

      // 请求 m 但只有 sm 就绪 → 降到 sm（否则必然 404）
      final smOnly = _item(_thumb(sm: 'ready', m: 'broken', unitId: '1'));
      expect(photoThumbRequest(smOnly, space, size: 'm')!.size, 'sm');
    });

    test('智能相册（人物/场景）：非 ready → null；有 unit_id 走 unit', () {
      final space = FotoSpace.personal;

      expect(
        photoSmartAlbumCoverRequest(
          _brokenVideo,
          space,
          type: 'person',
          id: '12',
        ),
        isNull,
      );

      final unitReady = _thumb(sm: 'ready', unitId: '77');
      final u = photoSmartAlbumCoverRequest(
        unitReady,
        space,
        type: 'person',
        id: '12',
      );
      expect(u!.thumbType, 'unit');
      expect(u.itemId, '77');

      final entityReady = _thumb(sm: 'ready');
      final p = photoSmartAlbumCoverRequest(
        entityReady,
        space,
        type: 'person',
        id: '12',
      );
      expect(p!.thumbType, 'person');
      expect(p.itemId, '12');
    });

    testWidgets('request==null 时 PhotoThumb 渲染"缩略图不可用"占位（不请求）', (
      tester,
    ) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: PhotoThumb(request: null, isVideo: true)),
          ),
        ),
      );
      expect(find.byKey(const Key('photo-thumb-unavailable')), findsOneWidget);
      expect(
        find.byKey(const Key('photo-thumb-fallback')),
        findsNothing,
        reason: '这不是能力位降级，是服务端缩略状态坏了',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
