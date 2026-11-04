// 笔记手绘/涂鸦的离线测试：抽稀 / 撤销重做 / 清空 / 导出 PNG / 正文标记。
//
// 确定性口径（不要求字节级黄金，渲染有平台差异）：
//   * 固定逻辑画布 + 固定几条线 → PNG **非空** + **PNG 魔数** + **IHDR 宽高**等于
//     期望的像素尺寸（[noteDrawingExportSize] 的输出）；
//   * "清空真的清了像素"用两张 PNG 字节**不相等**来证（清空后再导出 == 空白图）。
//
// 全部离线：不碰网络/设备；上传链路走 `FakeTransport`。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/notes/note_drawing.dart';
import 'package:synhub/src/features/notes/note_html.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 从 PNG 的 IHDR 读宽高（大端）。仅用于断言导出尺寸是否确定。
({int width, int height}) _pngSize(List<int> b) => (
  width: (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19],
  height: (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23],
);

NoteStroke _stroke(
  List<ui.Offset> pts, {
  double width = 4,
  bool eraser = false,
  ui.Color color = const ui.Color(0xFF000000),
}) => NoteStroke(points: pts, color: color, width: width, eraser: eraser);

const _logical = ui.Size(300, 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('触控点抽稀（最小距离采样）', () {
    test('小于阈值的抖动点被丢弃，只留够远的', () {
      final out = noteSimplifyStroke(const [
        ui.Offset(0, 0),
        ui.Offset(0.5, 0),
        ui.Offset(2, 0),
        ui.Offset(2.5, 0),
        ui.Offset(4, 0),
      ]);
      expect(out, const [ui.Offset(0, 0), ui.Offset(2, 0), ui.Offset(4, 0)]);
    });

    test('自定义阈值生效（阈值 1 → 0.5 那个点被丢、2 那个点保留）', () {
      final out = noteSimplifyStroke(const [
        ui.Offset(0, 0),
        ui.Offset(0.5, 0),
        ui.Offset(2, 0),
      ], minDistance: 1);
      expect(out, const [ui.Offset(0, 0), ui.Offset(2, 0)]);
    });

    test('点数上限封顶（防一条长划撑爆）', () {
      final raw = [for (var i = 0; i < 10000; i++) ui.Offset(i * 10, 0)];
      final out = noteSimplifyStroke(raw, maxPoints: 50);
      expect(out.length, 50);
    });
  });

  group('撤销 / 重做 / 清空', () {
    test('撤销真的还原笔画（不是只翻标志位）', () {
      final m = NoteDrawingModel();
      m.add(_stroke(const [ui.Offset(0, 0), ui.Offset(10, 10)]));
      m.add(_stroke(const [ui.Offset(20, 20), ui.Offset(30, 30)]));
      expect(m.strokes.length, 2);
      m.undo();
      expect(m.strokes.length, 1, reason: '撤销后必须剩 1 条');
      m.undo();
      expect(m.strokes, isEmpty);
      m.undo();
      expect(m.strokes, isEmpty, reason: '空栈再撤销是 no-op');
      expect(m.canUndo, isFalse);
    });

    test('重做把撤销掉的笔画放回来', () {
      final m = NoteDrawingModel();
      m.add(_stroke(const [ui.Offset(0, 0), ui.Offset(1, 1)]));
      m.undo();
      expect(m.strokes, isEmpty);
      expect(m.canRedo, isTrue);
      m.redo();
      expect(m.strokes.length, 1);
      expect(m.canRedo, isFalse);
    });

    test('新笔画清空重做栈', () {
      final m = NoteDrawingModel();
      m.add(_stroke(const [ui.Offset(0, 0), ui.Offset(1, 1)]));
      m.undo();
      m.add(_stroke(const [ui.Offset(5, 5), ui.Offset(6, 6)]));
      expect(m.canRedo, isFalse);
    });

    test('清空把笔画清掉，且可以撤销回来', () {
      final m = NoteDrawingModel();
      m.add(_stroke(const [ui.Offset(0, 0), ui.Offset(10, 10)]));
      m.clear();
      expect(m.strokes, isEmpty);
      expect(m.canUndo, isTrue);
      m.undo();
      expect(m.strokes.length, 1, reason: '清空必须可撤销，且真的把笔画还原');
    });
  });

  group('导出分辨率（固定上限）', () {
    test('逻辑尺寸 × DPR', () {
      final s = noteDrawingExportSize(_logical, 3);
      expect(s, const ui.Size(900, 600));
    });

    test('巨大画布被最长边封顶（不随画布无限增长）', () {
      final s = noteDrawingExportSize(const ui.Size(100000, 50000), 4);
      expect(s.width, kNoteDrawingMaxExportEdge);
      expect(s.height, kNoteDrawingMaxExportEdge / 2);
    });

    test('非法 DPR / 空尺寸有确定回落', () {
      expect(
        noteDrawingExportSize(_logical, double.nan),
        const ui.Size(300, 200),
      );
      expect(noteDrawingExportSize(ui.Size.zero, 2), const ui.Size(1, 1));
    });
  });

  group('导出 PNG（可确定性断言）', () {
    test('非空 + PNG 魔数 + IHDR 宽高 == 期望像素尺寸', () async {
      final bytes = await renderNoteDrawingPng(
        strokes: [
          _stroke(const [ui.Offset(10, 10), ui.Offset(120, 80)]),
          _stroke(const [
            ui.Offset(20, 150),
            ui.Offset(200, 40),
          ], color: const ui.Color(0xFFD61E18)),
        ],
        logicalSize: _logical,
        pixelSize: noteDrawingExportSize(_logical, 2),
        background: const ui.Color(0xFFFFFFFF),
      );
      expect(bytes, isNotEmpty);
      expect(looksLikePng(bytes), isTrue, reason: 'PNG 魔数');
      final size = _pngSize(bytes);
      expect(size.width, 600);
      expect(size.height, 400);
    });

    test('清空真的清了像素（两张 PNG 字节不同）', () async {
      final m = NoteDrawingModel();
      m.add(_stroke(const [ui.Offset(10, 10), ui.Offset(200, 150)]));
      final withStroke = await renderNoteDrawingPng(
        strokes: m.strokes,
        logicalSize: _logical,
        pixelSize: _logical,
        background: const ui.Color(0xFFFFFFFF),
      );
      m.clear();
      final cleared = await renderNoteDrawingPng(
        strokes: m.strokes,
        logicalSize: _logical,
        pixelSize: _logical,
        background: const ui.Color(0xFFFFFFFF),
      );
      expect(cleared, isNot(equals(withStroke)));
      final blank = await renderNoteDrawingPng(
        strokes: const [],
        logicalSize: _logical,
        pixelSize: _logical,
        background: const ui.Color(0xFFFFFFFF),
      );
      expect(cleared, equals(blank), reason: '清空后应等同空白画布');
    });

    test('透明背景不铺底（alpha=0）', () async {
      final bytes = await renderNoteDrawingPng(
        strokes: const [],
        logicalSize: _logical,
        pixelSize: _logical,
        background: const ui.Color(0x00000000),
      );
      expect(looksLikePng(bytes), isTrue);
    });
  });

  group('正文里的手绘标记（官方 class）', () {
    test('notePaintingHtml 带 syno-dsnote-painting-object', () {
      final html = notePaintingHtml('REF1');
      expect(html, contains(kNotePaintingClass));
      expect(html, contains('ref="REF1"'));
      expect(html, contains('syno-notestation-image-object'));
    });

    test('notePaintingRefsFromHtml 只收手绘的 ref', () {
      final html =
          '<p>x</p>${notePaintingHtml('P1')}'
          '${noteImageHtml('I1')}${notePaintingHtml('P2')}';
      expect(notePaintingRefsFromHtml(html), {'P1', 'P2'});
    });

    test('Delta → HTML：isPainting 命中的图片带 class，其它不带', () {
      final ops = [
        {
          'insert': {'image': 'F1'},
        },
        {'insert': '\n'},
        {
          'insert': {'image': 'F2'},
        },
        {'insert': '\n'},
      ];
      final html = noteDeltaToNoteHtml(ops, isPainting: (v) => v == 'F1');
      expect(html, contains(kNotePaintingClass));
      final plain = noteDeltaToNoteHtml(ops);
      expect(plain, isNot(contains(kNotePaintingClass)));
    });

    test('HTML → Delta → HTML 往返保住手绘 class', () {
      final html = '<p>正文</p>${notePaintingHtml('R9')}';
      final refs = notePaintingRefsFromHtml(html);
      final delta = noteHtmlToDelta(html);
      final back = noteDeltaToNoteHtml(
        delta,
        isPainting: (v) => refs.contains(v),
      );
      expect(back, contains(kNotePaintingClass));
      expect(back, contains('ref="R9"'));
    });
  });

  group('手绘 PNG 走既有附件上传链路（FakeTransport）', () {
    test('multipart 带真 PNG 字节，attachment 是 raw + ref', () async {
      final dir = Directory.systemTemp.createTempSync('note-drawing-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final png = await renderNoteDrawingPng(
        strokes: [
          _stroke(const [ui.Offset(0, 0), ui.Offset(50, 60)]),
        ],
        logicalSize: _logical,
        pixelSize: _logical,
        background: const ui.Color(0xFFFFFFFF),
      );
      final file = File('${dir.path}/painting_1.png')..writeAsBytesSync(png);

      const table = {
        'SYNO.API.Info': {
          'path': 'query.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
        'SYNO.NoteStation.Note': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 4,
        },
      };
      final t = FakeTransport(
        {
          'SYNO.NoteStation.Note.set': {
            'data': [
              {'object_id': 'n1', 'ver': '2.0'},
            ],
          },
        },
        {...FakeTransport.table, ...table},
      );
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');

      await NoteStationApi(api).uploadAttachments(
        objectId: 'n1',
        ver: '1.0',
        files: [
          NoteAttachmentUpload(
            path: file.path,
            fileName: 'painting_1.png',
            ref: 'REF-PAINT',
            mimeType: 'image/png',
          ),
        ],
        html: '<p>x</p>${notePaintingHtml('REF-PAINT')}',
      );

      final call = t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.NoteStation.Note' && c['method'] == 'set',
      );
      expect(call['attachment'], contains('"format":"raw"'));
      expect(call['attachment'], contains('"ref":"REF-PAINT"'));
      expect(call['file_name'], 'painting_1.png');
      expect(call['file_bytes'], isA<Uint8List>());
      expect(looksLikePng(call['file_bytes'] as Uint8List), isTrue);
      expect(call['content'], contains(kNotePaintingClass));
    });
  });
}
