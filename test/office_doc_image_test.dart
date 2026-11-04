// Office 文档图片管线（批 A）的离线用例 —— **真机真实字节 + 真实 picture 节点**。
//
// 夹具（本会话从真实 NAS 只读取回，含 sha256，见
// `test/fixtures/office_doc_images/MANIFEST.json`）：
//   * `logo_2.png` 13,909 B / `icon.png` 1,026 B，都是真 PNG 魔数
//     `89504e470d0a1a0a`；
//   * `picture` 节点 JSON 逐字来自 `docs/office-doc-render-design.md` §2 E3
//     （`Restaurant menu.odoc` 的 `attrs.config`）。
//
// 钉死的契约（用户投诉项）：
//   1. `Attachment:get` 必须**同时**带 `object_id` + `file_id`（只给 file_id → 404）；
//   2. 渲染器对 `picture`/`image` **必须真的渲染出 `Image`**，尺寸符合 width/height，
//      界面上**不得**出现 `file_id`/`ref`/路径；
//   3. 失败态给"图片加载失败 + 原因 + 重试"，同样不得出现路径；
//   4. 同 key 二次取**不得**触发第二次 HTTP（内存 LRU + 磁盘缓存）。
//
// 无网络、无设备、无构建。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/office/office_doc_image.dart';
import 'package:synhub/src/features/office/office_doc_view.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

// ------------------------------------------------------------------ 真实夹具

/// 真实 PNG 字节（sha256 见 MANIFEST）。
Uint8List _fixtureBytes(String name) =>
    File('test/fixtures/office_doc_images/$name').readAsBytesSync();

const _pngMagic = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/// E3 的真实 `picture` 节点（`Restaurant menu.odoc`，逐字）。
Map<String, Object?> _realPictureNode() => <String, Object?>{
  'type': 'picture',
  'attrs': <String, Object?>{
    'id': 'pic-1',
    'config': <String, Object?>{
      'alignment': 'inline',
      'alt': 'logo_2.png',
      'file_alt': 'logo_2.png',
      'file_id': 'd0306eae10464b51907412deaefd07f7',
      'file_type': 'image',
      'crop': <String, Object?>{'b': 0, 'l': 0, 'r': 0, 't': 0},
      'customized_points': <String, Object?>{},
      'deg': 0,
      'fill': 'none',
      'flip_h': false,
      'flip_v': false,
      'height': 153,
      'left': 100,
      'order': 0,
      'prst': 'rect',
      'ref': '',
      'stroke': '#2E3133',
      'stroke-width': 0,
      'top': 100,
      'type': 'rect',
      'width': 296,
    },
  },
};

const _objectId = '1028_35AO5B4V1P53DFEPKM2O8';
const _fileId = 'd0306eae10464b51907412deaefd07f7';

/// 真实文档树：`doc → edit_area → paragraph → picture`。
Map<String, Object?> _docWithPicture(Map<String, Object?> picture) =>
    <String, Object?>{
      'type': 'doc',
      'content': <Object?>[
        <String, Object?>{
          'type': 'edit_area',
          'content': <Object?>[
            <String, Object?>{
              'type': 'paragraph',
              'content': <Object?>[picture],
            },
          ],
        },
      ],
    };

// ------------------------------------------------------------------ 假传输

/// `Attachment:get/list` 的可编程传输（复用脚手架的 `postForm`/URL 拼装）。
class _AttachmentTransport extends FakeTransport {
  _AttachmentTransport([
    Map<String, Map<String, dynamic>>? responses,
    Map<String, Map<String, dynamic>>? apiTable,
  ]) : super(
         responses,
         apiTable ??
             const <String, Map<String, dynamic>>{
               'SYNO.Office.Node.Attachment': {
                 'path': 'entry.cgi',
                 'minVersion': 1,
                 'maxVersion': 2,
               },
             },
       );

  List<int> imageBytes = const <int>[];

  /// 非空 → `getBytes` 抛 `DsmApiException(code)`（DSM JSON 信封错误）。
  int? apiCodeError;

  /// 只在 URL 里 `version=<v>` 时抛该码（DA197：v2 回 120、v1 正常）。
  int? apiCodeErrorOnVersion;
  int? apiCodeErrorVersion;

  /// 非空 → 抛 `DsmTransportException(statusCode:)`（HTTP 层错误，404 走这里）。
  int? httpError;

  /// 非空 → 抛无状态码的传输错误（超时/断网）。
  String? networkMessage;

  final List<String> byteUrls = <String>[];

  @override
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) async {
    byteUrls.add(url);
    // 版本专属错误优先（DA197 用它模拟"v2 回 120、v1 回别的"）
    if (apiCodeErrorOnVersion != null &&
        apiCodeErrorVersion != null &&
        url.contains('version=$apiCodeErrorVersion')) {
      throw DsmApiException(apiCodeErrorOnVersion!);
    }
    if (apiCodeError != null) throw DsmApiException(apiCodeError!);
    if (httpError != null) {
      throw DsmTransportException(
        'HTTP $httpError',
        statusCode: httpError,
        uri: url,
      );
    }
    if (networkMessage != null) {
      throw DsmTransportException(networkMessage!, uri: url);
    }
    return imageBytes;
  }
}

OfficeApi _officeApi(_AttachmentTransport t) => OfficeApi(DsmWebApi(t));

// ------------------------------------------------------------------ 文本工具

/// 界面上的全部可见文本（Text.data + Text.rich 的纯文本）。
List<String> _visibleTexts(WidgetTester tester) => <String>[
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    if (t.data != null) t.data!,
  for (final r in tester.widgetList<RichText>(find.byType(RichText)))
    r.text.toPlainText(),
];

/// 在所有 `RichText` 里找 [needle] 文本**生效后**的 `TextStyle`
/// （子 span 没有自己的样式时继承父 span 的，例如段落级的 lineHeight）。
TextStyle? _styleOf(WidgetTester tester, String needle) {
  TextStyle? found;
  void walk(InlineSpan span, TextStyle? inherited) {
    if (found != null) return;
    if (span is! TextSpan) return;
    final style = span.style ?? inherited;
    if (span.text == needle) {
      found = style;
      return;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(rich.text, null);
    if (found != null) break;
  }
  return found;
}

/// 段落根 `TextSpan` 的 style（RichText 自身那层是 DefaultTextStyle）。
TextStyle? _rootStyle(WidgetTester tester, String needle) =>
    _styleOf(tester, needle);

void main() {
  final logoBytes = _fixtureBytes('logo_2.png');
  final iconBytes = _fixtureBytes('icon.png');

  group('I1. Attachment 数据层（object_id + file_id，错误可分类）', () {
    test('真机夹具字节：attachmentGet 取回真 PNG，URL 同时带 object_id/file_id', () async {
      // 夹具自检（sha256/字节数与 MANIFEST 一致）
      expect(logoBytes.length, 13909);
      expect(iconBytes.length, 1026);
      expect(logoBytes.take(8).toList(), _pngMagic);

      final t = _AttachmentTransport()..imageBytes = logoBytes;
      final bytes = await _officeApi(
        t,
      ).attachmentGet(objectId: _objectId, fileId: _fileId);
      expect(bytes, hasLength(13909));
      expect(bytes.take(8).toList(), _pngMagic);

      final url = t.byteUrls.single;
      expect(url, contains('api=SYNO.Office.Node.Attachment'));
      expect(url, contains('method=get'));
      // 真机取证：只给 file_id → 404，所以这两个**必须同时出现**。
      expect(url, contains('object_id=$_objectId'));
      expect(url, contains('file_id=$_fileId'));
      // 真机取证过的版本是 v2。
      expect(url, contains('version=2'));
    });

    // ★ DA197：真机上 `5-day trip planner.odoc` 的 10 张图里有 2 张在 **v2**
    //   回 120（缺参数），另外 8 张 v2 正常。`SYNO.Office.Node.Attachment`
    //   的 v1/v2 **都有 `get`** ⇒ v2 的 120 不能直接判死，要按 v1 再问一次。
    test('DA197 v2 回 120 → 自动按 v1 再取一次，取到字节即成功', () async {
      final t = _AttachmentTransport()
        ..imageBytes = logoBytes
        ..apiCodeErrorOnVersion = 120
        ..apiCodeErrorVersion = 2;
      final bytes = await _officeApi(
        t,
      ).attachmentGet(objectId: _objectId, fileId: _fileId);
      expect(bytes, hasLength(13909));
      expect(t.byteUrls, hasLength(2), reason: '应当只发两次（v2 失败 + v1 重试）');
      expect(t.byteUrls.first, contains('version=2'));
      expect(t.byteUrls.last, contains('version=1'));
    });

    test('DA197 v1 也失败 → 仍报第一次（v2 的 120）的原因', () async {
      final t = _AttachmentTransport()
        ..imageBytes = logoBytes
        ..apiCodeErrorOnVersion = 120
        ..apiCodeErrorVersion = 2
        ..apiCodeError = 105;
      await expectLater(
        _officeApi(t).attachmentGet(objectId: _objectId, fileId: _fileId),
        throwsA(
          isA<OfficeAttachmentException>().having(
            (e) => e.dsmCode,
            'dsmCode',
            120,
          ),
        ),
      );
      expect(t.byteUrls, hasLength(2));
    });

    test('DA197 120（真机：参数齐全也回 120）→ 附件通道报 notFound，不再"暂时不可用"', () async {
      final t = _AttachmentTransport()
        ..apiCodeError = kOfficeAttachmentServerGone;
      await expectLater(
        _officeApi(t).attachmentGet(objectId: _objectId, fileId: _fileId),
        throwsA(
          isA<OfficeAttachmentException>()
              .having((e) => e.kind, 'kind', OfficeAttachmentErrorKind.notFound)
              .having((e) => e.dsmCode, 'dsmCode', 120),
        ),
        reason: '120 落到 unknown 会让界面说"暂时不可用 + 可重试"，真机点几次都不会好',
      );
      // ★ 模板缩略图那条通道**必须保持** unknown：它的退路是"去掉 ver 再取一次"。
      expect(
        officeAttachmentExceptionFor(code: kOfficeAttachmentServerGone).kind,
        OfficeAttachmentErrorKind.unknown,
      );
    });

    test('DA197 105（无权限）**不**降级重试', () async {
      final t = _AttachmentTransport()..apiCodeError = 105;
      await expectLater(
        _officeApi(t).attachmentGet(objectId: _objectId, fileId: _fileId),
        throwsA(isA<OfficeAttachmentException>()),
      );
      expect(t.byteUrls, hasLength(1), reason: '无权限换个版本也不会变好');
    });

    test('404 → notFound（附件不存在）', () async {
      final t = _AttachmentTransport()..httpError = 404;
      await expectLater(
        _officeApi(t).attachmentGet(objectId: _objectId, fileId: _fileId),
        throwsA(
          isA<OfficeAttachmentException>().having(
            (e) => e.kind,
            'kind',
            OfficeAttachmentErrorKind.notFound,
          ),
        ),
      );
    });

    test('105 → noPermission；119/106 → sessionExpired', () async {
      final t105 = _AttachmentTransport()..apiCodeError = 105;
      await expectLater(
        _officeApi(t105).attachmentGet(objectId: _objectId, fileId: _fileId),
        throwsA(
          isA<OfficeAttachmentException>()
              .having(
                (e) => e.kind,
                'kind',
                OfficeAttachmentErrorKind.noPermission,
              )
              .having((e) => e.dsmCode, 'code', 105),
        ),
      );
      for (final code in <int>[119, 106]) {
        final t = _AttachmentTransport()..apiCodeError = code;
        await expectLater(
          _officeApi(t).attachmentGet(objectId: _objectId, fileId: _fileId),
          throwsA(
            isA<OfficeAttachmentException>()
                .having((e) => e.isSessionExpired, 'isSessionExpired', isTrue)
                .having((e) => e.dsmCode, 'code', code),
          ),
        );
      }
    });

    test('超时（码 6 / 传输层 timeout 消息）→ timeout，可区分', () async {
      expect(
        officeAttachmentExceptionFor(code: kOfficeAttachmentTimeoutCode).kind,
        OfficeAttachmentErrorKind.timeout,
      );
      final t = _AttachmentTransport()
        ..networkMessage = 'The request connection timed out';
      await expectLater(
        _officeApi(t).attachmentGet(objectId: _objectId, fileId: _fileId),
        throwsA(
          isA<OfficeAttachmentException>().having(
            (e) => e.kind,
            'kind',
            OfficeAttachmentErrorKind.timeout,
          ),
        ),
      );
    });

    test('入参不全 → missingParam（客户端错误，可区分）', () async {
      final t = _AttachmentTransport();
      await expectLater(
        _officeApi(t).attachmentGet(objectId: '', fileId: _fileId),
        throwsA(
          isA<OfficeAttachmentException>().having(
            (e) => e.kind,
            'kind',
            OfficeAttachmentErrorKind.missingParam,
          ),
        ),
      );
      expect(t.byteUrls, isEmpty, reason: '缺参数时不该发请求');
    });

    test('attachmentList 缺 object_id → missingParam；有则透传原始条目（字段未取证）', () async {
      final t = _AttachmentTransport(<String, Map<String, dynamic>>{
        'SYNO.Office.Node.Attachment.list': <String, dynamic>{
          'attachments': <Object?>[
            <String, dynamic>{'file_id': 'x', 'name': 'logo_2.png'},
          ],
        },
      });
      await expectLater(
        _officeApi(t).attachmentList(objectId: ''),
        throwsA(
          isA<OfficeAttachmentException>().having(
            (e) => e.kind,
            'kind',
            OfficeAttachmentErrorKind.missingParam,
          ),
        ),
      );
      final list = await _officeApi(t).attachmentList(objectId: _objectId);
      // 根键名/条目字段名**未取证**：只透传原始 Map，不编字段。
      expect(list, hasLength(1));
      expect(list.single['name'], 'logo_2.png');
    });
  });

  group('I2. OfficeDocImage 三态 + 缓存 + 排版', () {
    Widget host(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: child),
    );

    OfficeDocImageCache memoryOnly() =>
        OfficeDocImageCache(diskRoot: () async => null);

    testWidgets('成功态：渲染出 Image，尺寸符合 width/height，界面无 file_id/ref', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          Center(
            child: OfficeDocImage(
              objectId: _objectId,
              fileId: _fileId,
              width: 296,
              height: 153,
              alt: 'logo_2.png',
              provider: ({required objectId, required fileId}) async =>
                  logoBytes,
              cache: memoryOnly(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.width, 296);
      expect(image.height, 153);
      expect(find.byKey(const Key('office-doc-image-box')), findsOneWidget);
      expect(find.byKey(const Key('office-doc-image-failed')), findsNothing);

      final texts = _visibleTexts(tester).join('\n');
      expect(texts, isNot(contains(_fileId)));
      expect(texts, isNot(contains('ref')));
      expect(texts, isNot(contains('/mydrive')));
    });

    testWidgets('加载态：字节未回来时是骨架，不是文字也没崩', (tester) async {
      final gate = Completer<Uint8List>();
      await tester.pumpWidget(
        host(
          OfficeDocImage(
            objectId: _objectId,
            fileId: _fileId,
            provider: ({required objectId, required fileId}) => gate.future,
            cache: memoryOnly(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('office-doc-image-loading')), findsOneWidget);
      gate.complete(logoBytes);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('DA198 notFound → 不给「重试」（换个时间点也一样），且无路径', (tester) async {
      await tester.pumpWidget(
        host(
          OfficeDocImage(
            objectId: _objectId,
            fileId: _fileId,
            alt: 'logo_2.png',
            provider: ({required objectId, required fileId}) async =>
                throw const OfficeAttachmentException(
                  OfficeAttachmentErrorKind.notFound,
                ),
            cache: memoryOnly(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('office-doc-image-failed')), findsOneWidget);
      expect(find.textContaining('图片加载失败'), findsOneWidget);
      expect(find.text('服务器上找不到这张图片'), findsOneWidget);
      // ★ DA198：真机上 `01.png` 的「重试」点了三次全是同一个失败 ⇒ 永久性
      //   失败（notFound / missingParam）不给重试按钮。
      expect(find.byKey(const Key('office-doc-image-retry')), findsNothing);

      final texts = _visibleTexts(tester).join('\n');
      expect(texts, isNot(contains(_fileId)));
      expect(texts, isNot(contains('/mydrive')));
      expect(texts, isNot(contains('404')));
    });

    testWidgets('DA198 可恢复的失败（unknown/网络）仍给「重试」', (tester) async {
      await tester.pumpWidget(
        host(
          OfficeDocImage(
            objectId: _objectId,
            fileId: _fileId,
            provider: ({required objectId, required fileId}) async =>
                throw const OfficeAttachmentException(
                  OfficeAttachmentErrorKind.unknown,
                ),
            cache: memoryOnly(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-image-retry')), findsOneWidget);
    });

    testWidgets('失败后点重试 → 重新取字节并成功', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          OfficeDocImage(
            objectId: _objectId,
            fileId: _fileId,
            provider: ({required objectId, required fileId}) async {
              calls++;
              if (calls == 1) {
                throw const OfficeAttachmentException(
                  OfficeAttachmentErrorKind.timeout,
                );
              }
              return logoBytes;
            },
            cache: memoryOnly(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-image-retry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('office-doc-image-retry')));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(calls, 2);
    });

    testWidgets('缓存：同一 key 两个组件 → 提供者只被调用 1 次', (tester) async {
      var calls = 0;
      final cache = memoryOnly();
      Future<Uint8List> provider({
        required String objectId,
        required String fileId,
      }) async {
        calls++;
        return logoBytes;
      }

      await tester.pumpWidget(
        host(
          Column(
            children: <Widget>[
              OfficeDocImage(
                objectId: _objectId,
                fileId: _fileId,
                provider: provider,
                cache: cache,
              ),
              OfficeDocImage(
                objectId: _objectId,
                fileId: _fileId,
                provider: provider,
                cache: cache,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNWidgets(2));
      expect(calls, 1, reason: '同 key 第二次取必须命中缓存，不得再发 HTTP');
    });

    test('磁盘缓存：换一个 cache 实例（同一目录）也不再取字节', () async {
      // 真磁盘 I/O 不能在 testWidgets 的假异步里跑 → 这里直接测缓存本身。
      final dir = Directory.systemTemp.createTempSync('office_doc_img_test');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      var calls = 0;
      Future<Uint8List> fetch() async {
        calls++;
        return logoBytes;
      }

      const key = '$_objectId/$_fileId';
      final first = OfficeDocImageCache(diskRoot: () async => dir);
      final bytes = await first.load(key, fetch);
      expect(bytes, hasLength(13909));
      expect(calls, 1);

      // 新实例、同一磁盘目录 → 命中磁盘，不再取字节。
      final second = OfficeDocImageCache(diskRoot: () async => dir);
      final again = await second.load(key, fetch);
      expect(again, hasLength(13909));
      expect(calls, 1, reason: '磁盘缓存必须命中（否则会重复下载文档图片）');
    });

    test('内存 LRU：超过容量淘汰最久未用的 key', () async {
      final cache = OfficeDocImageCache(
        memoryCapacity: 2,
        diskRoot: () async => null,
      );
      Future<Uint8List> fetch() async => logoBytes;
      await cache.load('o/a', fetch);
      await cache.load('o/b', fetch);
      await cache.load('o/c', fetch); // 淘汰 o/a
      expect(cache.memoryKeys.toList(), <String>['o/b', 'o/c']);
    });

    testWidgets('alignment=left/right/center 各产生一个 Align', (tester) async {
      for (final entry in <OfficeDocImageAlignment, Alignment>{
        OfficeDocImageAlignment.left: Alignment.centerLeft,
        OfficeDocImageAlignment.center: Alignment.center,
        OfficeDocImageAlignment.right: Alignment.centerRight,
      }.entries) {
        await tester.pumpWidget(
          host(
            OfficeDocImage(
              objectId: _objectId,
              fileId: _fileId,
              alignment: entry.key,
              provider: ({required objectId, required fileId}) async =>
                  logoBytes,
              cache: memoryOnly(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final align = tester.widget<Align>(
          find.byKey(const Key('office-doc-image-align')),
        );
        expect(align.alignment, entry.value);
      }
      // inline（默认）不产生 Align。
      await tester.pumpWidget(
        host(
          OfficeDocImage(
            objectId: _objectId,
            fileId: _fileId,
            provider: ({required objectId, required fileId}) async => logoBytes,
            cache: memoryOnly(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-image-align')), findsNothing);
    });

    testWidgets('crop 生效：可见比例 → 放大倍数 + 对齐点', (tester) async {
      const crop = OfficeDocImageCrop(
        left: 0.1,
        top: 0.2,
        right: 0.3,
        bottom: 0.4,
      );
      expect(crop.visibleWidth, closeTo(0.6, 1e-9));
      expect(crop.visibleHeight, closeTo(0.4, 1e-9));
      expect(crop.alignment.x, closeTo(-0.2, 1e-9));
      expect(crop.alignment.y, closeTo(-0.2, 1e-9));

      await tester.pumpWidget(
        host(
          OfficeDocImage(
            objectId: _objectId,
            fileId: _fileId,
            crop: crop,
            provider: ({required objectId, required fileId}) async => logoBytes,
            cache: memoryOnly(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final transform = tester.widget<Transform>(
        find.byKey(const Key('office-doc-image-crop')),
      );
      expect(transform.transform.storage[0], closeTo(1 / 0.6, 1e-6));
      expect(transform.transform.storage[5], closeTo(1 / 0.4, 1e-6));
      expect(transform.alignment, crop.alignment);
    });

    testWidgets('flip/deg 生效：翻转变换与旋转矩阵', (tester) async {
      expect(
        officeDocImageFlipMatrix(horizontal: true, vertical: false).storage[0],
        -1,
      );
      expect(
        officeDocImageFlipMatrix(horizontal: false, vertical: true).storage[5],
        -1,
      );

      await tester.pumpWidget(
        host(
          OfficeDocImage(
            objectId: _objectId,
            fileId: _fileId,
            flipHorizontal: true,
            provider: ({required objectId, required fileId}) async => logoBytes,
            cache: memoryOnly(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      var transform = tester.widget<Transform>(
        find.byKey(const Key('office-doc-image-transform')),
      );
      expect(transform.transform.storage[0], -1);

      await tester.pumpWidget(
        host(
          OfficeDocImage(
            objectId: _objectId,
            fileId: _fileId,
            degrees: 90,
            provider: ({required objectId, required fileId}) async => logoBytes,
            cache: memoryOnly(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      transform = tester.widget<Transform>(
        find.byKey(const Key('office-doc-image-transform')),
      );
      expect(transform.transform.storage[0], closeTo(0, 1e-6));
      expect(transform.transform.storage[1], closeTo(1, 1e-6));
    });
  });

  group('I3. 渲染器接线：真实 picture 节点 → Image（不是文字/路径）', () {
    Widget host(
      Object doc,
      OfficeAttachmentBytesProvider provider,
      OfficeDocImageCache cache,
    ) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: OfficeDocView(
          doc: doc,
          showHeaderNote: false,
          objectId: _objectId,
          imageBytesProvider: provider,
          imageCache: cache,
        ),
      ),
    );

    testWidgets('picture（attrs.config）→ Image，尺寸 296×153，无降级、无 file_id', (
      tester,
    ) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(
        host(_docWithPicture(_realPictureNode()), ({
          required objectId,
          required fileId,
        }) async {
          // 真机连通性：必须两个参数都收到
          expect(objectId, _objectId);
          expect(fileId, _fileId);
          return logoBytes;
        }, OfficeDocImageCache(diskRoot: () async => null)),
      );
      await tester.pumpAndSettle();

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.width, 296);
      expect(image.height, 153);
      expect(image.semanticLabel, 'logo_2.png');
      expect(report.unsupportedNodeTypes, isNot(contains('picture')));
      expect(report.unknownNodeTypes, isEmpty);

      final texts = _visibleTexts(tester).join('\n');
      expect(texts, isNot(contains(_fileId)));
      expect(texts, isNot(contains('ref')));
      expect(texts, isNot(contains('picture')));
    });

    testWidgets('image 节点（attrs.file_id/width/height/alt）也接到图片组件', (
      tester,
    ) async {
      final doc = _docWithPicture(<String, Object?>{
        'type': 'image',
        'attrs': <String, Object?>{
          'file_id': _fileId,
          'width': '180px',
          'height': 90,
          'alt': 'icon.png',
        },
      });
      await tester.pumpWidget(
        host(
          doc,
          ({required objectId, required fileId}) async => iconBytes,
          OfficeDocImageCache(diskRoot: () async => null),
        ),
      );
      await tester.pumpAndSettle();
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.width, 180);
      expect(image.height, 90);
      expect(image.semanticLabel, 'icon.png');
    });

    testWidgets('拿不到字节（404）→ 失败态，界面无 file_id/ref/路径', (tester) async {
      await tester.pumpWidget(
        host(
          _docWithPicture(_realPictureNode()),
          ({required objectId, required fileId}) async =>
              throw const OfficeAttachmentException(
                OfficeAttachmentErrorKind.notFound,
              ),
          OfficeDocImageCache(diskRoot: () async => null),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-image-failed')), findsOneWidget);
      // DA198：404（= notFound）是永久失败，不再给"重试"
      expect(find.byKey(const Key('office-doc-image-retry')), findsNothing);
      final texts = _visibleTexts(tester).join('\n');
      expect(texts, isNot(contains(_fileId)));
      expect(texts, isNot(contains('/mydrive')));
    });
  });

  group('I4. 文本 marks 与段落排版', () {
    Widget host(Object doc) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: OfficeDocView(
          doc: doc,
          showHeaderNote: false,
          imageBytesProvider: ({required objectId, required fileId}) async =>
              logoBytes,
        ),
      ),
    );

    Map<String, Object?> paragraph(
      List<Object?> children, {
      Map<String, Object?> attrs = const <String, Object?>{},
      List<Object?> marks = const <Object?>[],
    }) => <String, Object?>{
      'type': 'paragraph',
      'attrs': attrs,
      if (marks.isNotEmpty) 'marks': marks,
      'content': children,
    };

    Map<String, Object?> text(
      Object? value, [
      List<Object?> marks = const [],
    ]) => <String, Object?>{
      'type': 'text',
      'text': value,
      if (marks.isNotEmpty) 'marks': marks,
    };

    Object docOf(List<Object?> paragraphs) => <String, Object?>{
      'type': 'doc',
      'content': <Object?>[
        <String, Object?>{'type': 'edit_area', 'content': paragraphs},
      ],
    };

    testWidgets(
      '内联 marks：strong/em/underline/strike/font_size/color/背景/字体/上下标',
      (tester) async {
        await tester.pumpWidget(
          host(
            docOf(<Object?>[
              paragraph(<Object?>[
                text('B', <Object?>[
                  <String, Object?>{'_': 'strong'},
                ]),
                text('I', <Object?>[
                  <String, Object?>{'_': 'em'},
                ]),
                text('U', <Object?>[
                  <String, Object?>{'_': 'underline'},
                ]),
                text('S', <Object?>[
                  <String, Object?>{'_': 'strike'},
                ]),
                text('F', <Object?>[
                  <String, Object?>{'_': 'font_size', 'value': 20},
                ]),
                text('C', <Object?>[
                  <String, Object?>{'_': 'color', 'value': '#ff0000'},
                ]),
                text('H', <Object?>[
                  <String, Object?>{
                    '_': 'background_color',
                    'value': '#ffff00',
                  },
                ]),
                text('M', <Object?>[
                  <String, Object?>{'_': 'font_family', 'value': 'Courier New'},
                ]),
                text('P', <Object?>[
                  <String, Object?>{'_': 'superscript'},
                ]),
                text('Q', <Object?>[
                  <String, Object?>{'_': 'subscript'},
                ]),
              ]),
            ]),
          ),
        );
        await tester.pumpAndSettle();

        expect(_styleOf(tester, 'B')?.fontWeight, FontWeight.bold);
        expect(_styleOf(tester, 'I')?.fontStyle, FontStyle.italic);
        expect(_styleOf(tester, 'U')?.decoration, TextDecoration.underline);
        expect(_styleOf(tester, 'S')?.decoration, TextDecoration.lineThrough);
        expect(_styleOf(tester, 'F')?.fontSize, 20);
        expect(_styleOf(tester, 'C')?.color, const Color(0xffff0000));
        expect(_styleOf(tester, 'H')?.backgroundColor, const Color(0xffffff00));
        expect(_styleOf(tester, 'M')?.fontFamily, 'Courier New');
        expect(
          _styleOf(
            tester,
            'P',
          )?.fontFeatures?.contains(const FontFeature.superscripts()),
          isTrue,
        );
        expect(
          _styleOf(
            tester,
            'Q',
          )?.fontFeatures?.contains(const FontFeature.subscripts()),
          isTrue,
        );
      },
    );

    testWidgets('link mark：可点（WidgetSpan + 手势），不打印 href/内部名', (tester) async {
      await tester.pumpWidget(
        host(
          docOf(<Object?>[
            paragraph(<Object?>[
              text('链接', <Object?>[
                <String, Object?>{'_': 'link', 'href': 'https://example.com'},
              ]),
            ]),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('链接'), findsOneWidget);
      expect(find.byType(GestureDetector), findsWidgets);
      final texts = _visibleTexts(tester).join('\n');
      expect(texts, isNot(contains('href')));
      expect(texts, isNot(contains('example.com')));
    });

    testWidgets('未知 mark：忽略（不崩、不上屏），只进 report', (tester) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: OfficeDocView(
              doc: docOf(<Object?>[
                paragraph(<Object?>[
                  text('KEEP', <Object?>[
                    <String, Object?>{'_': 'mystery_mark'},
                  ]),
                ]),
              ]),
              showHeaderNote: false,
              report: report,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(report.unknownMarkNames['mystery_mark'], 1);
      final texts = _visibleTexts(tester).join('\n');
      expect(texts, contains('KEEP'));
      expect(texts, isNot(contains('mystery_mark')));
      expect(texts, isNot(contains('mystery')));
    });

    testWidgets('段落 attrs：textAlign/lineHeight/缩进/背景色', (tester) async {
      await tester.pumpWidget(
        host(
          docOf(<Object?>[
            paragraph(
              <Object?>[text('段落')],
              attrs: <String, Object?>{
                'textAlign': 'center',
                'lineHeight': 1.8,
                'indentLeft': 24,
                'indentFirst': 12,
                'backgroundColor': '#ffff00',
              },
            ),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      final rich = tester.widget<RichText>(find.byType(RichText).first);
      expect(rich.textAlign, TextAlign.center);
      expect(_rootStyle(tester, '段落')?.height, 1.8);

      final padding = tester
          .widgetList<Padding>(find.byType(Padding))
          .map((p) => p.padding)
          .whereType<EdgeInsets>()
          .firstWhere((e) => e.left == 24, orElse: () => EdgeInsets.zero);
      expect(padding.left, 24);
      expect(padding.right, 0);

      final decorated = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.color == const Color(0xffffff00));
      expect(decorated, isNotEmpty);
    });

    testWidgets('块级 attr mark：text_align / line_height / direction 生效', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          docOf(<Object?>[
            paragraph(
              <Object?>[text('RTL')],
              marks: <Object?>[
                <String, Object?>{'_': 'text_align', 'value': 'right'},
                <String, Object?>{'_': 'line_height', 'value': 2.0},
                <String, Object?>{'_': 'direction', 'value': 'rtl'},
              ],
            ),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      final rich = tester.widget<RichText>(find.byType(RichText).first);
      expect(rich.textAlign, TextAlign.right);
      expect(rich.textDirection, TextDirection.rtl);
      expect(_rootStyle(tester, 'RTL')?.height, 2.0);
    });

    testWidgets('pseudo_list_item：真项目符号前缀，不打印节点名', (tester) async {
      await tester.pumpWidget(
        host(
          docOf(<Object?>[
            paragraph(<Object?>[
              <String, Object?>{'type': 'pseudo_list_item'},
              text('条目'),
            ]),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      final texts = _visibleTexts(tester).join('\n');
      expect(texts, contains('条目'));
      expect(texts, contains('•'));
      expect(texts, isNot(contains('pseudo_list_item')));
    });

    testWidgets('未声明的 attr 一律忽略（不崩、不上屏）', (tester) async {
      await tester.pumpWidget(
        host(
          docOf(<Object?>[
            paragraph(
              <Object?>[text('忽略我')],
              attrs: <String, Object?>{'notAnAttr': 'SHOULD-NOT-SHOW'},
            ),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        _visibleTexts(tester).join('\n'),
        isNot(contains('SHOULD-NOT-SHOW')),
      );
    });
  });

  group('I5. DA204 图片的"名字"只许是短文件名', () {
    // 真机 r613 的 dump 里读到可访问名 `null?_sid=%22KoFcFq3S0Spqc13C0…`
    // —— 那是服务端下发的 `file_alt`，原来被原样喂给 semanticLabel 与失败卡标题。
    test('DA204 正常文件名原样保留', () {
      expect(officeDocImageLabel('logo_2.png'), 'logo_2.png');
      expect(officeDocImageLabel('  01.png  '), '01.png');
      expect(officeDocImageLabel('封面图.jpg'), '封面图.jpg');
    });

    test('DA204 URL 片段 / 内部串一律当成"没有名字"', () {
      const junk = <String>[
        'null?_sid=%22KoFcFq3S0Spqc13C0',
        'https://nas.example.com/webapi/entry.cgi?api=SYNO.Office',
        'dir/sub/logo.png',
        r'C:\temp\a.png',
        'a&b.png',
        'img#3',
      ];
      for (final raw in junk) {
        expect(officeDocImageLabel(raw), '', reason: '「$raw」不该上屏/进读屏');
      }
    });

    test('DA204 超长与纯符号也不算名字', () {
      expect(officeDocImageLabel('x' * 49), '');
      expect(officeDocImageLabel('…'), '');
      expect(officeDocImageLabel('-- --'), '');
      expect(officeDocImageLabel(''), '');
    });

    testWidgets('DA204 失败卡不许把 URL 片段当图片名', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfficeDocImage(
              objectId: 'obj_1',
              fileId: 'file_1',
              alt: 'null?_sid=%22KoFcFq3S0Spqc13C0',
              width: 120,
              height: 120,
              provider: ({required objectId, required fileId}) async =>
                  throw const OfficeAttachmentException(
                    OfficeAttachmentErrorKind.notFound,
                  ),
              cache: OfficeDocImageCache(diskRoot: () async => null),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final texts = _visibleTexts(tester);
      expect(texts.join('\n'), isNot(contains('_sid')));
      expect(texts.join('\n'), isNot(contains('%22')));
      expect(find.bySemanticsLabel(RegExp('_sid')), findsNothing);
    });
  });
}
