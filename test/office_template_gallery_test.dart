// ★ 第 260 轮：Office 模板库「网格 + 官方缩略图 + 预览」的回归守卫。
//
// 口径直接对准真机契约与用户可见行为（`docs/office-template-gallery.md`）：
//   * `Template:list` 顶层是 **`items`**、`ver` 是 **40 位哈希串**、
//     系统模板 `title` 是 **`section:key`**（第 257 轮真机白屏就是这些）；
//   * 缩略图走官方 `Template.Thumb:get`（`object_id` + `ver` + `retina`）；
//   * **懒加载**（只对进入视口的卡片取图）；**失败记忆**（不重打网络）；
//   * 网格两列（同组两张卡 x 不同、y 相同）；官方 `TYPE_ORDER` + 过时主题沉底；
//   * 点卡片 = 预览（**不发 `Template:make`**）；预览里点「使用此模板」才新建；
//   * `section:key` 在中英两种语言下都必须本地化，绝不原样上屏。
//
// 无网络 / 无设备 / 无构建。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/office/office_library.dart';
import 'package:synhub/src/features/office/office_template_text.dart';
import 'package:synhub/src/features/office/office_template_thumbs.dart';
import 'package:synhub/src/features/office/office_template_titles.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Office.Template': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Office.Template.Thumb': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// 1x1 透明 PNG（真的要能被 `Image.memory` 解码，不能拿随机字节糊）。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// 真机 40 位哈希 `ver`（`docs/office-template-gallery.md` §2.1 逐字）。
const _verCountryRoad = 'f26e4bacf7a38332c3f078c399c2bacdc8a198f6';

/// 一条**真机形状**的模板条目（字段逐字，缺一不可）。
Map<String, dynamic> _item({
  required String objectId,
  required String ntype,
  required String title,
  String? ver = _verCountryRoad,
  bool system = true,
  Object? sortOrder,
}) => {
  'capabilities': {
    'can_download': true,
    'can_preview': true,
    'can_read': true,
  },
  'category': 'node',
  'ctime': 0,
  'encrypt': false,
  'is_template': true,
  'mtime': 0,
  'ntype': ntype,
  'object_id': objectId,
  'perm': 'ro',
  'system': system,
  'title': title,
  'ver': ver,
  'sort_order': ?sortOrder,
};

OfficeTemplateDto _dto(Map<String, dynamic> json) =>
    OfficeTemplateDto.fromJson(json);

Future<OfficeApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return OfficeApi(api);
}

/// 记录取图请求的假 fetcher（离线、可断言参数与次数）。
class _RecordingFetcher {
  final List<({String objectId, String? ver, bool retina})> calls = [];
  final Set<String> failIds;

  _RecordingFetcher({this.failIds = const {}});

  Future<Uint8List> call({
    required String objectId,
    String? ver,
    required bool retina,
  }) async {
    calls.add((objectId: objectId, ver: ver, retina: retina));
    if (failIds.contains(objectId)) {
      throw StateError('thumb failed for $objectId');
    }
    return _png;
  }
}

OfficeTemplateThumbCache _memoryOnlyCache() =>
    OfficeTemplateThumbCache(diskRoot: () async => null);

/// ★ 第 263 轮真机缺陷：把 `Template:list` 的**内容哈希**当缩略图 `ver` 发时，
/// 真机服务端对下面这 4 个哈希回
/// `120 {"errors":{"name":"ver","reason":"type"}}`（对**任意** object_id 都拒），
/// 于是 53 个模板里这 4 个永远没有缩略图。哈希逐字来自真机 `Template:list`
/// （出处：`docs/office-template-gallery.md` §8.1）。
const Map<String, String> kRealRejectedThumbVers = <String, String>{
  '1_navy_blue.tpl.slide': '884397ebc79f13571c14bc77ca447e82ea773413',
  '1_royal_blue.tpl.slide': '288e7fbf827e8368ae75a2f149d4b6a962ab0b13',
  '1_meeting_agenda.tpl.doc': '3e18c20601de0da32bd0cc955fbface533c099cf',
  '1_business_plan.tpl.doc': '9eae011c16624a53bd904927ee55b5833bebd9db',
};

/// 模拟真机服务端：带 `ver=` 的缩略图请求回 `120`（生产里由
/// `DirectTransport._bytesOf` 的 JSON 信封判定转成 `DsmApiException(120)`），
/// 去掉 `ver` 后回真 PNG。用来验证 `templateThumbBytes` 的"去掉 ver 重试"。
class _VerRejectingTransport extends FakeTransport {
  _VerRejectingTransport()
    : super(const {}, {...FakeTransport.table, ..._table});

  @override
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) async {
    downloads.add(url);
    if (url.contains('&ver=')) {
      throw DsmApiException(DsmErrorCode.requestParameterInvalid);
    }
    onProgress?.call(_png.length, _png.length);
    return _png;
  }
}

/// 永远 500 的传输：**网络类失败不得**触发"去掉 ver 重试"（重试同一死因没意义，
/// 且会把一次失败放大成两次请求）。
class _AlwaysFailingTransport extends FakeTransport {
  _AlwaysFailingTransport()
    : super(const {}, {...FakeTransport.table, ..._table});

  @override
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) async {
    downloads.add(url);
    throw DsmTransportException('HTTP 500', statusCode: 500, uri: url);
  }
}

Widget _host(Widget child) => MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child));

Future<void> _pumpView(
  WidgetTester tester, {
  required List<Map<String, dynamic>> items,
  _RecordingFetcher? fetcher,
  OfficeTemplateThumbCache? cache,
  OfficeTemplateLibraryView Function(
    List<OfficeTemplateDto> templates,
    _RecordingFetcher? fetcher,
    OfficeTemplateThumbCache? cache,
  )?
  build,
  Size size = const Size(420, 900),
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final templates = items.map(_dto).toList();
  await tester.pumpWidget(
    _host(
      build?.call(templates, fetcher, cache) ??
          OfficeTemplateLibraryView(
            templates: templates,
            thumbFetcher: fetcher?.call,
            thumbCache: cache,
          ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  tearDown(() => setCurrentText(AppTextZh()));

  group('G1. 真机 list 形状：items 键 / 40 位哈希 ver / 宽松解析', () {
    test('★ 顶层读 items（读 list 会静默 0 条，真机实测）', () {
      final fromItems = OfficeTemplateDto.listFromJson({
        'items': [
          _item(
            objectId: '1_country_road.tpl.slide',
            ntype: 'presentation',
            title: 'theme_presentation:country_road',
          ),
        ],
        'offset': 0,
        'total': 1,
      });
      expect(fromItems, hasLength(1));
      expect(fromItems.single.objectId, '1_country_road.tpl.slide');
      expect(fromItems.single.ntype, 'presentation');
      // ★ ver 必须是 String（40 位哈希），不是 int
      expect(fromItems.single.ver, _verCountryRoad);
      // ★ 第 263 轮：`ver` 是**内容哈希**，**不是**缩略图接口的 `ver`。
      // 官方 `getThumbImg` 对系统模板发应用版本（我们拿不到 ⇒ 不发），
      // 发内容哈希会被真机服务端 `120 {"name":"ver","reason":"type"}` 拒。
      expect(
        fromItems.single.thumbVer,
        isNull,
        reason: '系统模板不得把内容哈希当缩略图 ver 发（第 263 轮真机 4/53 无图）',
      );
      expect(fromItems.single.system, isTrue);
      expect(fromItems.single.perm, 'ro');
      expect(fromItems.single.isTemplate, isTrue);
      expect(fromItems.single.encrypt, isFalse);
      expect(fromItems.single.category, 'node');
      expect(fromItems.single.canRead, isTrue);
      expect(fromItems.single.canPreview, isTrue);
      expect(fromItems.single.canDownload, isTrue);

      // 故意喂旧代码会读的 `list` 键 ⇒ 必须 0 条（证明我们读的是 items）。
      expect(
        OfficeTemplateDto.listFromJson({
          'list': [
            _item(
              objectId: 'x',
              ntype: 'doc',
              title: 'template_doc:invoice',
            ),
          ],
        }),
        isEmpty,
      );
    });

    test('★ 宽松解析：布尔/数字用 int/字符串喂也不炸（AGENTS §2.0.12）', () {
      final dto = _dto({
        'object_id': 123, // 服务端偶发把 id 回成数字
        'ntype': 'sheet',
        'title': 'template_sheet:calendar',
        'system': 1,
        'perm': 'ro',
        'is_template': 'true',
        'encrypt': 'false',
        'capabilities': {'can_read': 'true', 'can_preview': 1},
        'sort_order': '5',
        'ver': 7,
      });
      expect(dto.objectId, '123');
      expect(dto.system, isTrue);
      expect(dto.isTemplate, isTrue);
      expect(dto.encrypt, isFalse);
      expect(dto.canRead, isTrue);
      expect(dto.canPreview, isTrue);
      expect(dto.canDownload, isFalse);
      expect(dto.sortOrder, 5);
      expect(dto.ver, '7');
    });
  });

  group('G2. 缩略图请求：官方 object_id / ver / retina 参数', () {
    test('★ templateThumbBytes 走 getBytes，URL 带三个参数', () async {
      final t = FakeTransport(
        const {},
        {...FakeTransport.table, ..._table},
      )..downloadBytes = _png;
      final office = await _api(t);

      final bytes = await office.templateThumbBytes(
        objectId: '1_country_road.tpl.slide',
        ver: _verCountryRoad,
        retina: true,
      );
      expect(bytes, _png);
      final url = t.downloads.single;
      expect(url, contains('api=SYNO.Office.Template.Thumb'));
      expect(url, contains('version=1'));
      expect(url, contains('method=get'));
      expect(url, contains('object_id=1_country_road.tpl.slide'));
      expect(url, contains('ver=$_verCountryRoad'));
      expect(url, contains('retina=true'));
    });

    test('retina=false 发 1x；ver 缺失时不发 ver（官方 getThumbImg 同款）', () async {
      final t = FakeTransport(
        const {},
        {...FakeTransport.table, ..._table},
      );
      final raw = DsmWebApi(t);
      await raw.discover();
      final office = OfficeApi(raw);
      final u1 = office.templateThumbUrl(
        objectId: 'a.tpl.doc',
        retina: false,
      );
      expect(u1, contains('retina=false'));
      expect(u1, isNot(contains('&ver=')));
      final u2 = office.templateThumbUrl(
        objectId: 'a.tpl.doc',
        ver: 'v1',
        retina: true,
      );
      expect(u2, contains('ver=v1'));
      expect(u2, contains('retina=true'));
    });
  });

  group('G3. 缩略图缓存：内存 LRU / 失败记忆 / 失效', () {
    test('★ 失败记住后不再重打网络（滚动回来不重复请求）', () async {
      var calls = 0;
      final cache = _memoryOnlyCache();
      Future<Uint8List> fetch() async {
        calls++;
        throw StateError('boom');
      }

      await expectLater(cache.load('k', fetch), throwsStateError);
      await expectLater(cache.load('k', fetch), throwsStateError);
      expect(calls, 1, reason: '第二次必须命中失败记忆，不再发网络');
      expect(cache.failedKeys, contains('k'));

      cache.invalidate('k');
      await expectLater(cache.load('k', fetch), throwsStateError);
      expect(calls, 2, reason: 'invalidate 之后才允许重试');
    });

    test('★ 内存命中不再取图；key 含 objectId+ver+retina', () async {
      var calls = 0;
      final cache = _memoryOnlyCache();
      Future<Uint8List> fetch() async {
        calls++;
        return _png;
      }

      final key = OfficeTemplateThumbCache.keyOf('a.tpl.doc', 'v9', true);
      expect(key, 'a.tpl.doc|v9|2x');
      expect(
        OfficeTemplateThumbCache.keyOf('a.tpl.doc', 'v9', false),
        'a.tpl.doc|v9|1x',
      );
      await cache.load(key, fetch);
      await cache.load(key, fetch);
      expect(calls, 1);
      expect(cache.memoryKeys, contains(key));
    });
  });

  group('G4. 标题本地化：section:key 绝不原样上屏', () {
    test('★ 中英两种语言都本地化；用户模板名原样保留', () {
      expect(
        officeTemplateTitleFromKey(
          'theme_presentation:country_road',
          text: AppTextZh(),
        ),
        '乡村',
      );
      expect(
        officeTemplateTitleFromKey(
          'theme_presentation:country_road',
          text: AppTextEn(),
        ),
        'Countryside',
      );
      expect(
        officeTemplateTitleFromKey(
          'template_doc:trip_planner',
          text: AppTextZh(),
        ),
        '5 天旅行计划表',
      );
      expect(
        officeTemplateTitleFromKey(
          'template_doc:trip_planner',
          text: AppTextEn(),
        ),
        '5-day trip planner',
      );
      // `template_sheet:calendar` 的 `{0}` 换成指定年份。
      expect(
        officeTemplateTitleFromKey('template_sheet:calendar', year: 2031),
        '2031 日历',
      );
      // 用户自己的模板（名字就是人看的字符串）→ 原样。
      expect(officeTemplateTitleFromKey('我的季度报告'), '我的季度报告');
      // 表里没有的 key → 可读回落，**绝不出现 `section:` 原样**。
      final fallback = officeTemplateTitleFromKey(
        'template_doc:not_a_real_key',
        text: AppTextZh(),
      );
      expect(fallback, isNotEmpty);
      expect(fallback, isNot(contains(':')));
      expect(fallback, isNot(contains('template_doc')));
    });

    testWidgets('★ 中文界面显示「乡村」，不显示 theme_presentation:country_road', (tester) async {
      setCurrentText(AppTextZh());
      await _pumpView(
        tester,
        items: [
          _item(
            objectId: '1_country_road.tpl.slide',
            ntype: 'presentation',
            title: 'theme_presentation:country_road',
          ),
        ],
      );
      expect(find.text('乡村'), findsOneWidget);
      expect(find.textContaining('theme_presentation'), findsNothing);
    });

    testWidgets('★ 英文界面显示 Countryside（不允许中英混排）', (tester) async {
      setCurrentText(AppTextEn());
      await _pumpView(
        tester,
        items: [
          _item(
            objectId: '1_country_road.tpl.slide',
            ntype: 'presentation',
            title: 'theme_presentation:country_road',
          ),
        ],
      );
      expect(find.text('Countryside'), findsOneWidget);
      expect(find.textContaining('theme_presentation'), findsNothing);
    });
  });

  group('G5. 排序：TYPE_ORDER + 过时主题沉底 + sort_order', () {
    test('★ 分组顺序 doc → sheet → presentation（官方 TYPE_ORDER）', () {
      final groups = groupOfficeTemplates([
        _dto(_item(objectId: 'p', ntype: 'presentation', title: 'theme_presentation:opinion')),
        _dto(_item(objectId: 's', ntype: 'sheet', title: 'template_sheet:invoice')),
        _dto(_item(objectId: 'd', ntype: 'doc', title: 'template_doc:invoice')),
      ]);
      expect(groups.keys.toList(), ['doc', 'sheet', 'presentation']);
    });

    test('★ 7 个过时演示主题沉底（官方 isDeprecatedTemplate 名单）', () {
      expect(kOfficeDeprecatedTemplateKeys, hasLength(7));
      for (final k in kOfficeDeprecatedTemplateKeys) {
        expect(
          isDeprecatedOfficeTemplateKey('theme_presentation:$k'),
          isTrue,
          reason: '$k 必须被判为过时',
        );
      }
      final sorted = sortedOfficeTemplates([
        _dto(_item(
          objectId: 'old.tpl.slide',
          ntype: 'presentation',
          title: 'theme_presentation:water_party',
        )),
        _dto(_item(
          objectId: 'new.tpl.slide',
          ntype: 'presentation',
          title: 'theme_presentation:opinion',
        )),
      ]);
      expect(sorted.last.objectId, 'old.tpl.slide', reason: '过时主题必须沉底');
      expect(sorted.first.objectId, 'new.tpl.slide');
    });

    test('组内按 sort_order（缺失的排后）', () {
      final sorted = sortedOfficeTemplates([
        _dto(_item(
          objectId: 'no_order.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:invoice',
        )),
        _dto(_item(
          objectId: 'order2.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:invoice',
          sortOrder: 20,
        )),
        _dto(_item(
          objectId: 'order1.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:invoice',
          sortOrder: 10,
        )),
      ]);
      expect(
        sorted.map((t) => t.objectId).toList(),
        ['order1.tpl.doc', 'order2.tpl.doc', 'no_order.tpl.doc'],
      );
    });
  });

  group('G6. 网格：两列 + 分组标题 + 空态', () {
    testWidgets('★ 同组两张卡 x 不同、y 相同（确实排成了网格，不是列表）',
        (tester) async {
      await _pumpView(
        tester,
        items: [
          _item(objectId: 'd1.tpl.doc', ntype: 'doc', title: 'template_doc:invoice'),
          _item(
            objectId: 'd2.tpl.doc',
            ntype: 'doc',
            title: 'template_doc:business_plan',
          ),
        ],
      );
      expect(find.byKey(const Key('office-template-list')), findsOneWidget);
      expect(find.byKey(const Key('office-template-group-doc')), findsOneWidget);
      final a = tester.getTopLeft(
        find.byKey(const Key('office-template-item-d1.tpl.doc')),
      );
      final b = tester.getTopLeft(
        find.byKey(const Key('office-template-item-d2.tpl.doc')),
      );
      expect(a.dy, moreOrLessEquals(b.dy, epsilon: 0.5), reason: '同一行');
      expect(
        (a.dx - b.dx).abs(),
        greaterThan(100),
        reason: '两列 ⇒ x 必须明显不同',
      );
    });

    testWidgets('★ 空态有明确文案（不是空白页）', (tester) async {
      await _pumpView(tester, items: const []);
      expect(
        find.byKey(const Key('office-template-library-empty')),
        findsOneWidget,
      );
    });

    testWidgets('★ 加载态是骨架（官方 #e2e6ea 底色），不是转圈', (tester) async {
      await tester.pumpWidget(_host(const OfficeTemplateGridSkeleton()));
      expect(
        find.byKey(const Key('office-template-library-loading')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('G7. 懒加载 + 缩略图请求参数（视口内的卡片才取图）', () {
    testWidgets('★ 进入视口的卡片取 2x 图；远处卡片不发请求', (tester) async {
      final fetcher = _RecordingFetcher();
      final cache = _memoryOnlyCache();
      final items = [
        for (var i = 0; i < 40; i++)
          _item(
            objectId: 'far$i.tpl.doc',
            ntype: 'doc',
            title: 'template_doc:invoice',
            ver: _verCountryRoad,
          ),
      ];
      await _pumpView(
        tester,
        items: items,
        fetcher: fetcher,
        cache: cache,
      );

      expect(fetcher.calls, isNotEmpty, reason: '可见卡片必须取图');
      expect(
        fetcher.calls.every((c) => c.retina),
        isTrue,
        reason: '高清屏取 2x（官方 retina=true）',
      );
      expect(
        fetcher.calls.every((c) => c.ver == null),
        isTrue,
        reason: '系统模板不发 ver（官方对 system 模板发应用版本；拿不到就不发）',
      );
      expect(
        fetcher.calls.map((c) => c.objectId),
        isNot(contains('far39.tpl.doc')),
        reason: '未进入视口的卡片不得发请求（懒加载）',
      );
    });

    testWidgets('★ 缩略图请求失败 ⇒ 占位（不弹错误码），且被记住', (tester) async {
      final fetcher = _RecordingFetcher(failIds: {'bad.tpl.doc'});
      final cache = _memoryOnlyCache();
      await _pumpView(
        tester,
        items: [
          _item(objectId: 'bad.tpl.doc', ntype: 'doc', title: 'template_doc:invoice'),
        ],
        fetcher: fetcher,
        cache: cache,
      );
      expect(
        find.byKey(const Key('office-template-thumb-failed-bad.tpl.doc')),
        findsOneWidget,
      );
      expect(cache.failedKeys, contains('bad.tpl.doc||2x'));
      expect(fetcher.calls, hasLength(1));
    });
  });

  group('G8. 点卡片 = 预览（绝不直接新建）', () {
    testWidgets('★ 点卡片打开全屏预览，且没有发 Template:make', (tester) async {
      var makeCalls = 0;
      await _pumpView(
        tester,
        items: [
          _item(
            objectId: '1_country_road.tpl.slide',
            ntype: 'presentation',
            title: 'theme_presentation:country_road',
          ),
        ],
        build: (templates, fetcher, cache) => OfficeTemplateLibraryView(
          templates: templates,
          thumbFetcher: fetcher?.call,
          thumbCache: cache,
          makeTemplate: (template, title) async {
            makeCalls++;
            return const <String, dynamic>{};
          },
        ),
      );
      await tester.tap(
        find.byKey(const Key('office-template-item-1_country_road.tpl.slide')),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(const Key('office-template-preview')),
        findsOneWidget,
        reason: '点卡片必须打开预览',
      );
      expect(makeCalls, 0, reason: '★ 预览不能有副作用：不得直接新建');
      // 预览里必须写清"只是官方缩略图，不是正文渲染"。
      expect(
        find.byKey(const Key('office-template-preview-note')),
        findsOneWidget,
      );
      expect(find.text('乡村'), findsOneWidget);
    });

    testWidgets('★ 预览里点「使用此模板」才进新建流程（标题对话框 → make）',
        (tester) async {
      final made = <String>[];
      await _pumpView(
        tester,
        items: [
          _item(
            objectId: '1_country_road.tpl.slide',
            ntype: 'presentation',
            title: 'theme_presentation:country_road',
          ),
        ],
        build: (templates, fetcher, cache) => OfficeTemplateLibraryView(
          templates: templates,
          thumbFetcher: fetcher?.call,
          thumbCache: cache,
          makeTemplate: (template, title) async {
            made.add('${template.objectId}|${title ?? ''}');
            return const <String, dynamic>{};
          },
        ),
      );
      await tester.tap(
        find.byKey(const Key('office-template-item-1_country_road.tpl.slide')),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(made, isEmpty);
      await tester.tap(
        find.byKey(
          const Key('office-template-preview-use-1_country_road.tpl.slide'),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(const Key('office-template-make-dialog')),
        findsOneWidget,
      );
      expect(made, isEmpty, reason: '对话框确认前不得发 make');
      await tester.tap(find.byKey(const Key('office-template-make-confirm')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(made, hasLength(1));
      expect(
        made.single,
        '1_country_road.tpl.slide|乡村',
        reason: '对话框默认文件名 = 本地化标题（不是 section:key）',
      );
    });

    testWidgets('★ 长按卡片 = 底部菜单（预览 / 使用此模板）——手机没有 hover',
        (tester) async {
      await _pumpView(
        tester,
        items: [
          _item(objectId: 'd1.tpl.doc', ntype: 'doc', title: 'template_doc:invoice'),
        ],
        build: (templates, fetcher, cache) => OfficeTemplateLibraryView(
          templates: templates,
          thumbFetcher: fetcher?.call,
          thumbCache: cache,
          makeTemplate: (template, title) async => const <String, dynamic>{},
        ),
      );
      await tester.longPress(
        find.byKey(const Key('office-template-item-d1.tpl.doc')),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(const Key('office-template-menu-sheet')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-template-menu-preview-d1.tpl.doc')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-template-menu-make-d1.tpl.doc')),
        findsOneWidget,
      );
    });
  });

  group('G9. 预览页翻页', () {
    testWidgets('★ 左右滑动换模板，页码跟着变', (tester) async {
      await _pumpView(
        tester,
        items: [
          _item(
            objectId: '1_country_road.tpl.slide',
            ntype: 'presentation',
            title: 'theme_presentation:country_road',
          ),
          _item(
            objectId: '1_abstract.tpl.slide',
            ntype: 'presentation',
            title: 'theme_presentation:abstract',
          ),
        ],
        build: (templates, fetcher, cache) => OfficeTemplateLibraryView(
          templates: templates,
          thumbFetcher: fetcher?.call,
          thumbCache: cache,
          makeTemplate: (template, title) async => const <String, dynamic>{},
        ),
      );
      await tester.tap(
        find.byKey(const Key('office-template-item-1_country_road.tpl.slide')),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('office-template-preview-pager')),
        const Offset(-400, 0),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('抽象'), findsOneWidget);
    });
  });

  group('G10. 第 263 轮：缩略图 ver 语义（真机 4/53 无图缺陷）', () {
    test('★ 真机 4 个被拒哈希：系统模板的 thumbVer 必须是 null（不发内容哈希）', () {
      for (final e in kRealRejectedThumbVers.entries) {
        final dto = _dto(
          _item(
            objectId: e.key,
            ntype: e.key.contains('.sh')
                ? 'sheet'
                : e.key.contains('.slide')
                ? 'presentation'
                : 'doc',
            title: 'template_doc:invoice',
            ver: e.value,
          ),
        );
        expect(dto.ver, e.value, reason: '内容哈希本身要照常解析（${e.key}）');
        expect(dto.system, isTrue);
        expect(
          dto.thumbVer,
          isNull,
          reason: '${e.key} 的哈希被真机 120 拒，绝不能当缩略图 ver 发',
        );
      }
    });

    test('★ 官方语义：只有用户模板发 publish_version；系统/未知一律不发', () {
      // system=false + publish_version ⇒ 发它（官方 `e.publish_version` 同款）。
      final user = _dto({
        ..._item(
          objectId: 'u.tpl.doc',
          ntype: 'doc',
          title: 'My template',
          ver: _verCountryRoad,
          system: false,
        ),
        'publish_version': 'publish-hash-abc',
      });
      expect(user.system, isFalse);
      expect(user.thumbVer, 'publish-hash-abc');

      // system=false 但服务端没给 publish_version ⇒ 不发（不拿内容哈希顶替）。
      final userNoPublish = _dto(
        _item(
          objectId: 'u2.tpl.doc',
          ntype: 'doc',
          title: 'My template 2',
          ver: _verCountryRoad,
          system: false,
        ),
      );
      expect(userNoPublish.thumbVer, isNull);

      // system=true ⇒ 一律不发（应用版本移动端拿不到；真机不发也出图）。
      final sys = _dto({
        ..._item(
          objectId: 's.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:invoice',
          ver: _verCountryRoad,
        ),
        'publish_version': 'publish-hash-abc',
      });
      expect(sys.thumbVer, isNull);
    });

    test('★ 带 ver 被 120 拒 ⇒ 去掉 ver 重试一次并出图（真机实测 53/53 出图）', () async {
      final t = _VerRejectingTransport();
      final office = await _api(t);

      final bytes = await office.templateThumbBytes(
        objectId: '1_navy_blue.tpl.slide',
        ver: kRealRejectedThumbVers['1_navy_blue.tpl.slide'],
        retina: true,
      );
      expect(bytes, _png, reason: '去掉 ver 的重试必须成功');
      expect(t.downloads, hasLength(2), reason: '第一次带 ver、第二次不带 ver');
      expect(t.downloads.first, contains('&ver='));
      expect(
        t.downloads.last,
        isNot(contains('&ver=')),
        reason: '第二次必须真的不带 ver',
      );
      expect(
        t.downloads.last,
        contains('object_id=1_navy_blue.tpl.slide'),
      );
    });

    test('★ 网络类失败（500）不走去掉 ver 的退路（不放大负载）', () async {
      final t = _AlwaysFailingTransport();
      final office = await _api(t);

      await expectLater(
        office.templateThumbBytes(
          objectId: '1_navy_blue.tpl.slide',
          ver: kRealRejectedThumbVers['1_navy_blue.tpl.slide'],
          retina: true,
        ),
        throwsA(
          isA<OfficeAttachmentException>().having(
            (e) => e.kind,
            'kind',
            OfficeAttachmentErrorKind.network,
          ),
        ),
      );
      expect(t.downloads, hasLength(1), reason: '只有一次请求，不许重试');
    });

    testWidgets('★ 端到端：真机 4 个"无图"模板经网格取图时不发 ver 且全部出图', (
      tester,
    ) async {
      final fetcher = _RecordingFetcher();
      final cache = _memoryOnlyCache();
      await _pumpView(
        tester,
        items: [
          for (final e in kRealRejectedThumbVers.entries)
            _item(
              objectId: e.key,
              ntype: 'presentation',
              title: 'theme_presentation:navy_blue',
              ver: e.value,
            ),
        ],
        fetcher: fetcher,
        cache: cache,
      );

      expect(fetcher.calls, isNotEmpty);
      // 让 FutureBuilder 拿到字节并渲染（fetcher 是异步的）。
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        fetcher.calls.every((c) => c.ver == null),
        isTrue,
        reason: '真机 4 个被拒哈希一个都不许发出去',
      );
      expect(cache.failedKeys, isEmpty, reason: '不许再把它们记成失败');
      for (final e in kRealRejectedThumbVers.keys) {
        expect(
          find.byKey(Key('office-template-thumb-$e')),
          findsOneWidget,
          reason: '$e 现在必须有真缩略图',
        );
      }
    });
  });
}
