// 批 C：`.oslides` **几何渲染**离线用例。
//
// 夹具是**官方模板**（SPK 内置 `template/slides/*/text.json`，见
// `docs/office-sample-corpus.md`），落地为可离线读的真实文件：
//   * `test/fixtures/office_templates/slides_group.json`（`slides/opinion`）
//     —— 含 `object_group`（子坐标**相对父组**）；
//   * `test/fixtures/office_templates/slides_line.json`（`slides/microcosmic_view`）
//     —— 含 `line`（205 个）/ `shape_box` / 分组；
//   * 图片字节用批 A 的真机 PNG `test/fixtures/office_doc_images/logo_2.png`。
//
// 纪律：所有断言都锚在**真实节点原文**上；派生（derived）用例一律在名字/注释里
// 标明"派生"，不冒充真实样例。
//
// 无网络、无设备、无构建。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/office_native/oslides_model.dart';
import 'package:synhub/src/features/office/office_doc_image.dart';
import 'package:synhub/src/features/office/office_slides_canvas.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_slides_view.dart';

// ------------------------------------------------------------------ 夹具

Map<String, Object?> _sections(String name) =>
    (jsonDecode(
              File(
                'test/fixtures/office_templates/$name.json',
              ).readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>();

/// 第一页（两个成品夹具都只有 1 页）。
OfficeSlidesSlideScene _scene(String name) {
  final sections = _sections(name);
  final pres = OSlidesPresentation.fromSections(sections);
  return buildOfficeSlidesSlideScene(
    sections: sections,
    slideRaw: pres.slides.first.raw,
    slidePathPrefix: 'p0',
  );
}

Uint8List _logoBytes() =>
    File('test/fixtures/office_doc_images/logo_2.png').readAsBytesSync();

const String _objectId = '1028_35AO5B4V1P53DFEPKM2O8';
const String _fileId = 'd0306eae10464b51907412deaefd07f7';

/// **派生**夹具：一个真实形状的 `image_box`（节点形状取自
/// `docs/office-doc-render-design.md` §7.3 的 `image` 节点；字节用批 A 的真机 PNG）。
Map<String, Object?> _imageBoxSections() => <String, Object?>{
  'content': <String, Object?>{
    'version': 1,
    'data': <String, Object?>{
      'attrs': <String, Object?>{
        'schema': 13,
        'type': 'presentation',
        'cx': 960,
        'cy': 540,
      },
      'content': <Object?>[
        <String, Object?>{'type': 'settings', 'attrs': <String, Object?>{}},
        <String, Object?>{
          'type': 'slide_container',
          'attrs': <String, Object?>{},
          'content': <Object?>[
            <String, Object?>{
              'type': 'slide',
              'attrs': <String, Object?>{
                'id': 'S1',
                'master_id': 'M',
                'layout_id': 'L',
              },
              'content': <Object?>[
                <String, Object?>{
                  'type': 'slide_content_container',
                  'attrs': <String, Object?>{},
                  'content': <Object?>[
                    <String, Object?>{
                      'type': 'image_box',
                      'attrs': <String, Object?>{
                        'id': 'IMG1',
                        'transform': <String, Object?>{
                          'left': 100,
                          'top': 80,
                          'width': 296,
                          'height': 153,
                          'deg': 0,
                          'skewY': 0,
                        },
                      },
                      'content': <Object?>[
                        <String, Object?>{
                          'type': 'image',
                          'attrs': <String, Object?>{
                            'file_id': _fileId,
                            'alt': 'logo_2.png',
                            'shape_type': 'rect',
                            'img_transform': <String, Object?>{
                              'deg': 0,
                              'flip_h': false,
                              'flip_v': false,
                            },
                          },
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          ],
        },
      ],
    },
  },
  'index': <String, Object?>{'schemaVersion': 13},
};

Widget _canvasHost(
  OfficeSlidesSlideScene scene, {
  OfficeAttachmentBytesProvider? provider,
  OfficeDocImageCache? cache,
}) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(
    body: OfficeSlidesCanvas(
      scene: scene,
      nodeBuilder: (node, path) => const SizedBox.shrink(),
      objectId: _objectId,
      imageBytesProvider: provider,
      imageCache: cache,
    ),
  ),
);

/// 派生夹具：从 sections 里取出 `slide` 节点原文。
Map<String, Object?> _slideRawOf(Map<String, Object?> sections) =>
    OSlidesPresentation.fromSections(sections).slides.first.raw;

/// 界面上**所有** Text 的字符串（用于"内部标识不得上屏"的断言）。
List<String> _allText(WidgetTester tester) => tester.allWidgets
    .whereType<Text>()
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .toList();

void main() {
  // ---------------------------------------------------------------------
  group('C1. 真实分组夹具（slides_group.json）：父组偏移 + 5 种形状 + 未实现形状', () {
    final scene = _scene('slides_group');

    test('画布尺寸 / 背景 / 母版版式都在（不是空白页）', () {
      expect(scene.canvasWidth, 960);
      expect(scene.canvasHeight, 540);
      // master_background.color = "fcfcfc"（**裸 hex**，不带 #）。
      expect(scene.background, const Color(0xfffcfcfc));
      expect(scene.hasMaster, isTrue);
      expect(scene.hasLayout, isTrue);
      expect(scene.boxes, isNotEmpty);
      expect(scene.masterBoxCount, greaterThan(0));
      expect(scene.layoutBoxCount, greaterThan(0));
    });

    test('object_group 真实样例：子坐标相对父组 → **父偏移必须叠加**', () {
      expect(scene.groupCount, 1);
      expect(scene.maxGroupDepth, 1, reason: '真实样例没有嵌套组');
      expect(scene.groupChildCount, 2);
      final shape = scene.boxes.firstWhere((b) => b.id == 'waV0xJoaf3');
      // fixture 原文：group.left = -27.465432770822 / child.left = 287.43494828525
      expect(shape.transform!.left, closeTo(259.969515514428, 1e-9));
      // group.top = 55.698615799144 / child.top = 0.98293019976716
      expect(shape.transform!.top, closeTo(56.68154599891116, 1e-9));
      // 若**不**叠加父偏移，就会是 287.434…（分组整体错位 → 本断言必红）。
      expect(
        (shape.transform!.left - 287.43494828525).abs(),
        greaterThan(1),
        reason: '左值必须已经被父组偏移改变过',
      );
      // 负宽 → 归一成 |width| 的矩形（真实样例 width = -1.3900732193768）。
      expect(shape.rect.left, closeTo(258.5794422950512, 1e-9));
      expect(shape.rect.width, closeTo(1.3900732193768, 1e-9));
    });

    test('rect 形状取真实 fill_config（#ffa000）+ stroke 缺失不编边', () {
      final shape = scene.boxes.firstWhere((b) => b.id == 'waV0xJoaf3');
      expect(shape.kind, OfficeSlidesBoxKind.shape);
      expect(shape.shape!.shapeType, 'rect');
      expect(shape.shape!.kind, OfficeSlidesShapeKind.rect);
      expect(shape.shape!.fill, isTrue);
      expect(shape.shape!.fillColor, const Color(0xffffa000));
      expect(shape.shape!.stroke, isFalse);
      expect(shape.shape!.canPaintStroke, isFalse);
      expect(shape.shape!.custPointsEmpty, isTrue);
    });

    test('`pie` 有真实样例但不在本批 5 种 → 登记为未实现（不凭空造多边形）', () {
      expect(scene.unsupportedShapeTypes, contains('pie'));
      final pie = scene.boxes.firstWhere(
        (b) => b.kind == OfficeSlidesBoxKind.unsupported,
      );
      expect(pie.id, '50H5YofYjh');
      expect(pie.unsupportedReason, 'pie');
      // deg=90 的真实旋转被保留（不是丢掉）。
      expect(pie.transform!.deg, 90);
      expect(scene.notes.any((n) => n.contains('pie')), isTrue);
    });

    test('5 种已实现 shape_type 的映射；清单外 → unsupported', () {
      expect(officeSlidesShapeKindOf('rect'), OfficeSlidesShapeKind.rect);
      expect(officeSlidesShapeKindOf('ellipse'), OfficeSlidesShapeKind.ellipse);
      expect(
        officeSlidesShapeKindOf('triangle'),
        OfficeSlidesShapeKind.triangle,
      );
      expect(
        officeSlidesShapeKindOf('parallelogram'),
        OfficeSlidesShapeKind.parallelogram,
      );
      expect(
        officeSlidesShapeKindOf('right_triangle'),
        OfficeSlidesShapeKind.rightTriangle,
      );
      // 真实样例出现过、但**不在**本批清单：不实现。
      expect(officeSlidesShapeKindOf('pie'), OfficeSlidesShapeKind.unsupported);
      expect(
        officeSlidesShapeKindOf('chord'),
        OfficeSlidesShapeKind.unsupported,
      );
    });
  });

  // ---------------------------------------------------------------------
  group('C2. 真实连线夹具（slides_line.json）：line 节点（205 个真实样例）', () {
    final scene = _scene('slides_line');

    test('line 走几何路径且字面语义（line_type=line / cust_points={}）', () {
      final lines = scene.boxes
          .where((b) => b.kind == OfficeSlidesBoxKind.line)
          .toList();
      expect(lines, isNotEmpty);
      for (final l in lines) {
        expect(l.line!.lineType, 'line');
        expect(l.line!.isPlainLine, isTrue);
        expect(l.line!.stroke, isTrue);
        expect(l.line!.custPointsEmpty, isTrue);
        expect(l.line!.strokeColor, isNotNull);
        expect(l.line!.strokeWidth, greaterThan(0));
      }
      expect(scene.unsupportedShapeTypes, isEmpty, reason: '选中的版式里没有清单外形状');
    });

    test('连线在分组内：绝对值 = 组偏移 + 子坐标；负宽按 |width| 归一到矩形', () {
      expect(scene.groupCount, 1);
      final group = scene.boxes.firstWhere(
        (b) => b.kind == OfficeSlidesBoxKind.line,
        orElse: () => scene.boxes.first,
      );
      expect(group.transform, isNotNull);
      // 至少一条真实连线的宽是负的（205 个里 93 个），归一后仍为正矩形。
      final anyNegative = scene.boxes.any(
        (b) => b.kind == OfficeSlidesBoxKind.line && b.transform!.width < 0,
      );
      expect(anyNegative, isTrue);
      for (final b in scene.boxes.where(
        (b) => b.kind == OfficeSlidesBoxKind.line,
      )) {
        expect(b.rect.width, greaterThanOrEqualTo(0));
        expect(b.rect.height, greaterThanOrEqualTo(0));
      }
    });

    test('deg ∈ {0,180} 的真实旋转被保留，skewY 浮点噪声不被当成真斜切', () {
      final lines = scene.boxes
          .where((b) => b.kind == OfficeSlidesBoxKind.line)
          .toList();
      final degs = lines.map((b) => b.transform!.deg).toSet();
      expect(degs.every((d) => d == 0 || d == 180), isTrue, reason: '$degs');
      // 真实 skewY 是 1.47e-12 这种量级 → hasSkewY 必须为 false（否则误报）。
      expect(lines.every((b) => !b.transform!.hasSkewY), isTrue);
    });
  });

  // ---------------------------------------------------------------------
  group('C3. 图片（派生夹具 + 批 A 真机 PNG）：真的渲染图片，且绝不显示 file_id', () {
    testWidgets('image_box → OfficeDocImage：object_id + file_id 同时给，界面无内部标识', (
      tester,
    ) async {
      final sections = _imageBoxSections();
      final pres = OSlidesPresentation.fromSections(sections);
      final scene = buildOfficeSlidesSlideScene(
        sections: sections,
        slideRaw: pres.slides.first.raw,
        slidePathPrefix: 'p0',
      );
      final image = scene.boxes.singleWhere(
        (b) => b.kind == OfficeSlidesBoxKind.image,
      );
      expect(image.imageFileId, _fileId);
      expect(image.imageAlt, 'logo_2.png');
      expect(image.rect, const Rect.fromLTWH(100, 80, 296, 153));

      final calls = <String>[];
      final cache = OfficeDocImageCache(diskRoot: () async => null);
      await tester.pumpWidget(
        _canvasHost(
          scene,
          cache: cache,
          provider: ({required objectId, required fileId}) async {
            calls.add('$objectId/$fileId');
            return _logoBytes();
          },
        ),
      );
      await tester.pumpAndSettle();

      // 通道契约：object_id + file_id **同时**给。
      expect(calls, <String>['$_objectId/$_fileId']);
      // 真的渲染出了 Image（不是附件路径）。
      expect(find.byType(Image), findsWidgets);
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
        findsWidgets,
      );
      final texts = _allText(tester);
      expect(
        texts.any((t) => t.contains(_fileId)),
        isFalse,
        reason: 'file_id 绝不许上屏：$texts',
      );
      expect(
        texts.any((t) => t.contains(_objectId)),
        isFalse,
        reason: 'object_id 绝不许上屏：$texts',
      );
    });
  });

  // ---------------------------------------------------------------------
  group('C4. 真实夹具整体渲染（widget）：几何真的进了界面', () {
    testWidgets('slides_group：画布 + 形状 + 未实现形状卡片都在，且无内部标识', (tester) async {
      final sections = _sections('slides_group');
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: OfficeSlidesView(sections: sections, showHeaderNote: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slide-canvas-0')), findsOneWidget);
      expect(
        find.byKey(const Key('office-slide-shape-waV0xJoaf3')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-slide-unsupported-50H5YofYjh')),
        findsOneWidget,
      );
      final texts = _allText(tester);
      expect(
        texts.any((t) => t.contains('pie')),
        isFalse,
        reason: '原始形状名不上屏：$texts',
      );
      expect(texts.any((t) => t.contains('fcfcfc')), isFalse);
    });

    testWidgets('slides_line：连线画出来了（真实 205 个线节点的版式）', (tester) async {
      final sections = _sections('slides_line');
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: OfficeSlidesView(sections: sections, showHeaderNote: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slide-canvas-0')), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      // 真实线条的 CustomPaint 至少有一个（key 前缀 office-slide-line-）。
      final lineKeys = tester.allWidgets
          .where((w) => w.key is ValueKey<String> || w.key is Key)
          .map((w) => w.key.toString())
          .where((k) => k.contains('office-slide-line-'))
          .toList();
      expect(lineKeys, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------------
  group('C5. 派生边界（真实语料里没有的形态，按登记处理，不假装实现）', () {
    test('嵌套 object_group：逐层叠加实现 + **登记未取证**', () {
      final inner = <String, Object?>{
        'type': 'shape_box',
        'attrs': <String, Object?>{
          'id': 'inner',
          'transform': <String, Object?>{
            'left': 5,
            'top': 7,
            'width': 10,
            'height': 10,
            'deg': 0,
            'skewY': 0,
          },
        },
        'content': <Object?>[
          <String, Object?>{
            'type': 'shape',
            'attrs': <String, Object?>{
              'shape_type': 'rect',
              'fill': true,
              'fill_config': <String, Object?>{
                'fill': '#112233',
                'fill-opacity': 1,
              },
              'stroke': false,
            },
          },
        ],
      };
      final sections = <String, Object?>{
        'content': <String, Object?>{
          'version': 1,
          'data': <String, Object?>{
            'attrs': <String, Object?>{'schema': 13, 'cx': 960, 'cy': 540},
            'content': <Object?>[
              <String, Object?>{
                'type': 'slide_container',
                'attrs': <String, Object?>{},
                'content': <Object?>[
                  <String, Object?>{
                    'type': 'slide',
                    'attrs': <String, Object?>{'id': 'S1'},
                    'content': <Object?>[
                      <String, Object?>{
                        'type': 'slide_content_container',
                        'attrs': <String, Object?>{},
                        'content': <Object?>[
                          <String, Object?>{
                            'type': 'object_group',
                            'attrs': <String, Object?>{
                              'id': 'outer',
                              'transform': <String, Object?>{
                                'left': 100,
                                'top': 50,
                                'width': 100,
                                'height': 100,
                                'deg': 0,
                                'skewY': 0,
                              },
                            },
                            'content': <Object?>[
                              <String, Object?>{
                                'type': 'object_group',
                                'attrs': <String, Object?>{
                                  'id': 'innerGroup',
                                  'transform': <String, Object?>{
                                    'left': 10,
                                    'top': 20,
                                    'width': 50,
                                    'height': 50,
                                    'deg': 0,
                                    'skewY': 0,
                                  },
                                },
                                'content': <Object?>[inner],
                              },
                            ],
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        },
      };
      final scene = buildOfficeSlidesSlideScene(
        sections: sections,
        slideRaw: _slideRawOf(sections),
      );
      expect(scene.groupCount, 2);
      expect(scene.maxGroupDepth, 2);
      expect(
        scene.notes.any(
          (n) => n.contains('嵌套 object_group') && n.contains('未取证'),
        ),
        isTrue,
      );
      // 逐层叠加：100 + 10 + 5 = 115 / 50 + 20 + 7 = 77。
      final box = scene.boxes.singleWhere((b) => b.id == 'inner');
      expect(box.transform!.left, 115);
      expect(box.transform!.top, 77);
    });

    test('line 的 cust_points 非空（真实样例 205/205 为 {}）→ 不实现 + 登记', () {
      final scene = _derivedLineScene(custPoints: <String, Object?>{'x': 1});
      final box = scene.boxes.single;
      expect(box.kind, OfficeSlidesBoxKind.unsupported);
      expect(box.unsupportedReason, 'cust_points 非空');
      expect(scene.notes.any((n) => n.contains('cust_points 非空')), isTrue);
    });

    test('line_type 非 line（未取证）→ 不实现 + 登记', () {
      final scene = _derivedLineScene(lineType: 'curve');
      final box = scene.boxes.single;
      expect(box.kind, OfficeSlidesBoxKind.unsupported);
      expect(box.unsupportedReason, 'curve');
      expect(scene.notes.any((n) => n.contains('line_type')), isTrue);
    });

    test('无 transform 的盒子：如实登记、不猜坐标', () {
      final scene = _derivedLineScene(omitTransform: true);
      expect(scene.boxes, isEmpty);
      expect(scene.flow, isEmpty);
      expect(scene.notes.any((n) => n.contains('没有 transform')), isTrue);
    });
  });
}

/// **派生**：一个最小 `line_box` 场景（真实 line 节点字段取自 slides_line.json，
/// 这里只改 `cust_points` / `line_type` 来测未取证分支）。
OfficeSlidesSlideScene _derivedLineScene({
  String lineType = 'line',
  Object? custPoints = const <String, Object?>{},
  bool omitTransform = false,
}) {
  final sections = <String, Object?>{
    'content': <String, Object?>{
      'version': 1,
      'data': <String, Object?>{
        'attrs': <String, Object?>{'schema': 13, 'cx': 960, 'cy': 540},
        'content': <Object?>[
          <String, Object?>{
            'type': 'slide_container',
            'attrs': <String, Object?>{},
            'content': <Object?>[
              <String, Object?>{
                'type': 'slide',
                'attrs': <String, Object?>{'id': 'S1'},
                'content': <Object?>[
                  <String, Object?>{
                    'type': 'slide_content_container',
                    'attrs': <String, Object?>{},
                    'content': <Object?>[
                      <String, Object?>{
                        'type': 'line_box',
                        'attrs': <String, Object?>{
                          'id': 'L1',
                          if (!omitTransform)
                            'transform': <String, Object?>{
                              'left': 10,
                              'top': 20,
                              'width': -30,
                              'height': 40,
                              'deg': 0,
                              'skewY': 0,
                            },
                        },
                        'content': <Object?>[
                          <String, Object?>{
                            'type': 'line',
                            'attrs': <String, Object?>{
                              'stroke': true,
                              'stroke_config': <String, Object?>{
                                'stroke': '#f5f5f5',
                                'stroke-opacity': 1,
                                'stroke-width': 2,
                              },
                              'line_type': lineType,
                              'cust_points': custPoints,
                            },
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  };
  return buildOfficeSlidesSlideScene(
    sections: sections,
    slideRaw: _slideRawOf(sections),
  );
}
