// 回归：`downloadOfficeAs` 在 widget 卸载后**不得**再碰 `ref`。
//
// 与 `attachment_view.dart` 同类：旧实现在 `await office.exportBytes(...)` 之后
// 才 `ref.read(officeDownloadDirProvider)`（L51），落盘后又
// `ref.read(systemOpenProvider)`（L56）。页面在导出期间被卸载时，riverpod 3 的
// `_assertNotDisposed` 会抛 StateError；而这个 Future 是按钮回调里没人 await 的，
// 错误逃逸后可能挂到全量跑时"当时正在跑的那个用例"上。
//
// 收敛要点（避免"真实时钟竞态窗口"）：
//   * 测试代码**直接调用** `downloadOfficeAs(capturedRef, ...)`，不经手势；
//   * 两段 await 各是一个显式 `Completer` 闸门；进入闸门用测试替身的
//     `Completer` 通知（microtask，`pump` 即可），卸载/放行的先后完全由测试决定；
//   * 完成信号是 `systemOpen` 替身里的 `Completer`（修复后必然触发）；
//     等待是"交替 flush microtask / 给真实 I/O 时间，直到信号触发"的条件等待。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_filex/open_filex.dart';

import 'package:synhub/src/core/system_open.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/office_export.dart';
import 'package:synhub/src/features/files/office_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// `exportBytes` 被闸门挡住（并通知"已进入"）。
class _GatedOfficeApi extends OfficeApi {
  _GatedOfficeApi(super.api, this.gate);

  final Future<void> Function() gate;
  final started = Completer<void>();
  int calls = 0;

  @override
  Future<List<int>> exportBytes({
    required String fileId,
    required String format,
    String? version,
    String? fileName,
    String password = '',
  }) async {
    calls++;
    if (!started.isCompleted) started.complete();
    await gate();
    return utf8.encode('%PDF-1.7 fake\n');
  }
}

/// 交替 flush microtask（`pump`）与给真实 I/O 时间（`runAsync`），直到 [done]。
Future<void> _settle(
  WidgetTester tester,
  bool Function() done, {
  int maxRounds = 300,
  Duration realStep = const Duration(milliseconds: 20),
}) async {
  for (var i = 0; i < maxRounds && !done(); i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(realStep));
  }
  await tester.pump();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  group('Office 导出：卸载后完成不得再碰 ref', () {
    testWidgets('导出取字节期间卸载 → 完成后无异常，文件仍按语义落盘', (tester) async {
      final dir = Directory.systemTemp.createTempSync('office_unmount_bytes');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final exportGate = Completer<void>();
      final office = _GatedOfficeApi(
        DsmWebApi(FakeTransport()),
        () => exportGate.future,
      );
      final opened = <String>[];
      final done = Completer<void>();
      // 挂一个 Consumer 只为拿到一个**已挂载**的 WidgetRef（不经按钮/手势）。
      late WidgetRef ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            officeApiProvider.overrideWithValue(office),
            officeDownloadDirProvider.overrideWithValue(() async => dir),
            systemOpenProvider.overrideWithValue((path) async {
              opened.add(path);
              if (!done.isCompleted) done.complete();
              return OpenResult(type: ResultType.done, message: 'fake');
            }),
          ],
          child: Consumer(
            builder: (_, r, _) {
              ref = r;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pump();

      // 同步跑到 `await exportBytes`，进入闸门。
      unawaited(
        downloadOfficeAs(
          ref,
          fileId: '9',
          name: '报告.odoc',
          format: OfficeExportFormat.ms,
          openAfter: true,
        ),
      );
      expect(office.calls, 1, reason: '应已进入 exportBytes 并卡住');
      expect(office.started.isCompleted, isTrue);

      // 导出还没回来就卸载。
      await _unmount(tester);

      // 现在才放行导出；`done` 由 systemOpen 替身触发（修复后必然走到）。
      exportGate.complete();
      await _settle(tester, () => done.isCompleted);

      expect(
        tester.takeException(),
        isNull,
        reason: '卸载后旧实现在 L51 ref.read(officeDownloadDirProvider) 抛异常',
      );
      expect(
        File('${dir.path}/报告.docx').existsSync(),
        isTrue,
        reason: '卸载不该改变"导出后落盘"的语义',
      );
      expect(opened, hasLength(1), reason: 'openAfter 语义不变：仍然把落盘文件交给系统打开');
    });

    testWidgets('落盘目录查询期间卸载 → 完成后 systemOpen 不碰 ref、语义不变', (tester) async {
      final dir = Directory.systemTemp.createTempSync('office_unmount_dir');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final dirGate = Completer<void>();
      final dirEntered = Completer<void>();
      // exportBytes 立即返回；只把"取落盘目录"这一步闸住。
      final office = _GatedOfficeApi(DsmWebApi(FakeTransport()), () async {});
      final opened = <String>[];
      final done = Completer<void>();
      late WidgetRef ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            officeApiProvider.overrideWithValue(office),
            officeDownloadDirProvider.overrideWithValue(() async {
              if (!dirEntered.isCompleted) dirEntered.complete();
              await dirGate.future;
              return dir;
            }),
            systemOpenProvider.overrideWithValue((path) async {
              opened.add(path);
              if (!done.isCompleted) done.complete();
              return OpenResult(type: ResultType.done, message: 'fake');
            }),
          ],
          child: Consumer(
            builder: (_, r, _) {
              ref = r;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pump();

      unawaited(
        downloadOfficeAs(
          ref,
          fileId: '9',
          name: '报告.odoc',
          format: OfficeExportFormat.ms,
          openAfter: true,
        ),
      );
      // exportBytes 立即完成，一个 microtask 后就进入取落盘目录。
      await tester.pump();
      expect(office.calls, 1);
      expect(dirEntered.isCompleted, isTrue, reason: '应已卡在取落盘目录');

      await _unmount(tester);

      dirGate.complete();
      await _settle(tester, () => done.isCompleted);

      expect(
        tester.takeException(),
        isNull,
        reason: '卸载后旧实现在 L56 ref.read(systemOpenProvider) 抛异常',
      );
      expect(
        opened,
        hasLength(1),
        reason: 'systemOpen 应在 await 之前取好，卸载后仍按语义执行',
      );
    });
  });
}
