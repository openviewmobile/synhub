// r691 · `DA330`：Linux 上的 PDF 出图（`pdfx` 在 Linux 没有实现）。
//
// 三件事必须机检：
//   ① **平台分流**：Linux 走 poppler（`PdfRasterRunner` 可注入），其它平台仍是 pdfx；
//   ② **失败要能说人话**：没装 `pdftoppm` ⇒ `PdfRasterFailure.toolMissing`（页面给
//      "装 poppler-utils" 的提示），不是空白/转圈；
//   ③ **真出图**：给定一个合成的最小 PDF，`popplerRenderPage` 必须产非空 PNG
//      —— 这条用**注入的假 runner 写一张已知 PNG** 来验"字节真的被读回来"，
//      真 poppler 的像素证据在 `integration_test/r691_linux_pdf_test.dart`。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/pdf_cover.dart';
import 'package:synhub/src/features/files/pdf_poppler_view.dart';

/// 1×1 PNG（最小合法图片字节）
final Uint8List _tinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  group('DA330 · poppler 渲染器', () {
    test('① 没装 pdftoppm（ProcessException）⇒ toolMissing，不是"文件坏了"', () async {
      Future<PdfRasterResult> missing(String exe, List<String> args) =>
          throw ProcessException(exe, args, 'No such file or directory', 2);

      await expectLater(
        popplerRenderPage(Uint8List.fromList([1, 2, 3]), page: 1, run: missing),
        throwsA(
          isA<PdfRasterException>().having(
            (e) => e.failure,
            'failure',
            PdfRasterFailure.toolMissing,
          ),
        ),
      );
    });

    test('② 调用成功但没产出文件 ⇒ noOutput（不静默返回空）', () async {
      Future<PdfRasterResult> lying(String exe, List<String> args) async =>
          const PdfRasterResult(exitCode: 0, stdout: '', stderr: '');

      await expectLater(
        popplerRenderPage(Uint8List.fromList([1, 2, 3]), page: 1, run: lying),
        throwsA(
          isA<PdfRasterException>().having(
            (e) => e.failure,
            'failure',
            PdfRasterFailure.noOutput,
          ),
        ),
      );
    });

    test('③ 成功路径：把输出文件读回来（字节非空、PNG 头对）', () async {
      // 假 runner：按 pdftoppm 的约定，最后两个参数是 input 与输出前缀
      Future<PdfRasterResult> fake(String exe, List<String> args) async {
        final outPrefix = args.last;
        await File('$outPrefix.png').writeAsBytes(_tinyPng, flush: true);
        return const PdfRasterResult(exitCode: 0, stdout: '', stderr: '');
      }

      final png = await popplerRenderPage(
        Uint8List.fromList([1, 2, 3]),
        page: 1,
        run: fake,
      );
      expect(png, isNotEmpty);
      expect(png.sublist(0, 8), _tinyPng.sublist(0, 8));
    });

    test('④ 页数读不出来 ⇒ null（不编数字）', () async {
      Future<PdfRasterResult> badInfo(String exe, List<String> args) async =>
          const PdfRasterResult(exitCode: 1, stdout: '', stderr: 'boom');
      expect(
        await popplerPageCount(Uint8List.fromList([1]), badInfo),
        isNull,
      );
    });

    test('⑤ pdfinfo 的 Pages 行能读出来', () async {
      Future<PdfRasterResult> info(String exe, List<String> args) async =>
          const PdfRasterResult(
            exitCode: 0,
            stdout: 'Title: x\nPages:          7\nEncrypted: no\n',
            stderr: '',
          );
      expect(await popplerPageCount(Uint8List.fromList([1]), info), 7);
    });

    test('⑥ 封面：poppler 失败 ⇒ null（退分类图标，与 pdfx 契约一致）', () async {
      // 这里没有注入点（封面 provider 用真实 runner）；在**没有 poppler** 的宿主上
      // 它必须安静地返回 null 而不是抛。装着 poppler 的宿主上则返回真 PNG。
      final out = await renderPdfFirstPageCoverWithPoppler(
        Uint8List.fromList([1, 2, 3]),
      );
      expect(out == null || out.isNotEmpty, isTrue);
    });
  });

  group('DA330 · 平台分流与源码契约', () {
    final view = File(
      'lib/src/features/files/file_pdf_view.dart',
    ).readAsStringSync();
    final cover = File(
      'lib/src/features/files/pdf_cover.dart',
    ).readAsStringSync();

    test('⑦ 观看页按 Linux 分流到 poppler，其它平台仍是 pdfx', () {
      expect(
        view,
        contains('defaultTargetPlatform == TargetPlatform.linux'),
      );
      expect(view, contains('buildPopplerPdfViewer'));
      expect(view, contains('buildPdfxViewer'));
    });

    test('⑧ 封面同样按 Linux 分流', () {
      expect(
        cover,
        contains('defaultTargetPlatform == TargetPlatform.linux'),
      );
      expect(cover, contains('renderPdfFirstPageCoverWithPoppler'));
    });

    test('⑨ Linux 提示必须点名"装 poppler-utils"，不许只说"打开失败"', () {
      final poppler = File(
        'lib/src/features/files/pdf_poppler_view.dart',
      ).readAsStringSync();
      expect(poppler, contains('pdfLinuxNoPoppler'));
      final arb = File('lib/l10n/app_en.arb').readAsStringSync();
      expect(arb, contains('poppler-utils'));
      expect(arb, contains('pdftoppm'));
    });
  });

  group('DA330 · 页面表现（宿主上没装 poppler 时）', () {
    testWidgets('⑩ 缺 pdftoppm ⇒ 明确提示"装 poppler-utils"，并提供重试', (tester) async {
      final container = ProviderContainer(
        overrides: [
          // 模拟"这台机器没有 pdftoppm"
          pdfRasterRunnerProvider.overrideWithValue(
            (exe, args) async =>
                throw ProcessException(exe, args, 'No such file', 2),
          ),
        ],
      );
      addTearDown(container.dispose);
      // ★ 真 IO（临时文件/子进程）在 widget 测试里**只有 runAsync 期间**才推进；
      //   在 fake-async 区里发起的 Future 永远不完成（会一直停在 "Parsing PDF…"）。
      //   所以 pumpWidget + 等待都放进 runAsync，之后再 pump 一帧看结果。
      await tester.runAsync(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark(),
              localizationsDelegates: AppText.localizationsDelegates,
              supportedLocales: AppText.supportedLocales,
              home: Scaffold(
                body: PopplerPdfView(bytes: Uint8List.fromList([1, 2, 3])),
              ),
            ),
          ),
        );
        // ★ 轮询而不是死等 400ms：并行跑全量时这一步偶尔还没完成（假红，
        //   第 438 轮全量里连红两次、单独跑恒绿）。判据仍然是"结果出现"。
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (find.byKey(const Key('pdf-poppler-error')).evaluate().isNotEmpty) {
            break;
          }
        }
      });
      await tester.pump();
      expect(find.byKey(const Key('pdf-poppler-error')), findsOneWidget);
      final txt = (tester.widget<Text>(find.byKey(const Key('pdf-poppler-error'))))
          .data!;
      expect(txt.toLowerCase(), contains('poppler'));
      expect(find.byType(TextButton), findsOneWidget);
    });

    testWidgets('⑪ 渲染成功时页面给 PNG 与翻页条（注入假 runner）', (tester) async {
      final container = ProviderContainer(
        overrides: [
          pdfRasterRunnerProvider.overrideWithValue((exe, args) async {
            if (exe == 'pdfinfo') {
              return const PdfRasterResult(
                exitCode: 0,
                stdout: 'Pages: 2\n',
                stderr: '',
              );
            }
            await File('${args.last}.png').writeAsBytes(_tinyPng, flush: true);
            return const PdfRasterResult(exitCode: 0, stdout: '', stderr: '');
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark(),
              localizationsDelegates: AppText.localizationsDelegates,
              supportedLocales: AppText.supportedLocales,
              home: Scaffold(
                body: PopplerPdfView(bytes: Uint8List.fromList([1, 2, 3])),
              ),
            ),
          ),
        );
        // 这里要等到「PNG 也解出来」为止：只等翻页条会在并行负载下缺 Image
        // （解码晚一拍 ⇒ 假红）。判据仍是"结果出现"，不是放宽断言。
        for (var i = 0; i < 120; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          final ready = find.byKey(const Key('pdf-poppler-page-indicator')).evaluate().isNotEmpty &&
              find.byType(Image).evaluate().isNotEmpty;
          if (ready) break;
        }
      });
      await tester.pump();
      expect(find.byKey(const Key('pdf-poppler-page-indicator')), findsOneWidget);
      expect(find.byKey(const Key('pdf-poppler-prev')), findsOneWidget);
      expect(find.byKey(const Key('pdf-poppler-next')), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });
  });
}
