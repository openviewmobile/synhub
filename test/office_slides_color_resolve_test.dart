// `.oslides` **颜色解引用**用例（r17）：`clrScheme` / `clrMap` / 修饰符演算 /
// 背景继承链。
//
// ## 为什么这个文件用**合成** pptx（而不是真机样本）
// 三份真机样本里 `schemeClr`/`sysClr`/`prstClr`/`lumMod`/`lumOff`/`tint`/`shade`
// 的出现次数**全部是 0**（逐字统计见 `test/support/pptx_fixture.dart` 文件头）。
// 只用真样本，这段代码**永远无法被观测**，等于没有回归锁。
// ⇒ 这里用 [buildSyntheticPptx] 造合法 pptx，把每条规则**逐条钉住**。
//
// ## 关于"外部真值"
// `lumMod`/`lumOff` 的数值不是自证：断言里用了 **Office 官方主题调色板**的
// 公开派生色（`accent1 = 4F81BD` 的 Lighter 40% = `B8CCE4`、
// Darker 25% = `366092`）。这条外部真值同时把**取整口径**（截断 vs 四舍五入）
// 钉死了 —— 详见 `oslides_ooxml.dart` 里 `_mapChannels` 的注释。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';

import 'support/pptx_fixture.dart';

/// 取第 [i] 个形状的填充色。
int? _fill(OSlidesDeck deck, int i) => deck.slides.first.shapes[i].fillArgb;

String _solid(String inner) => '<a:solidFill>$inner</a:solidFill>';

void main() {
  group('① `a:clrScheme` 十色 + `a:clrMap` 逻辑名映射', () {
    test('`schemeClr` 直接命中主题槽位（6 个 accent 各不相同）', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:schemeClr val="accent1"/>'),
          _solid('<a:schemeClr val="accent2"/>'),
          _solid('<a:schemeClr val="accent3"/>'),
          _solid('<a:schemeClr val="accent4"/>'),
          _solid('<a:schemeClr val="accent5"/>'),
          _solid('<a:schemeClr val="accent6"/>'),
          _solid('<a:schemeClr val="dk2"/>'),
          _solid('<a:schemeClr val="lt2"/>'),
          _solid('<a:schemeClr val="hlink"/>'),
          _solid('<a:schemeClr val="folHlink"/>'),
        ]),
      )!;
      expect(_fill(deck, 0), 0xFF4F81BD);
      expect(_fill(deck, 1), 0xFFC0504D);
      expect(_fill(deck, 2), 0xFF9BBB59);
      expect(_fill(deck, 3), 0xFF8064A2);
      expect(_fill(deck, 4), 0xFF4BACC6);
      expect(_fill(deck, 5), 0xFFF79646);
      expect(_fill(deck, 6), 0xFF1F497D);
      expect(_fill(deck, 7), 0xFFEEECE1);
      expect(_fill(deck, 8), 0xFF0000FF);
      expect(_fill(deck, 9), 0xFF800080);
    });

    test('`dk1`/`lt1` 是 `sysClr`，颜色取 **lastClr**', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:schemeClr val="dk1"/>'),
          _solid('<a:schemeClr val="lt1"/>'),
        ]),
      )!;
      expect(_fill(deck, 0), 0xFF000000, reason: 'dk1 = sysClr windowText');
      expect(_fill(deck, 1), 0xFFFFFFFF, reason: 'lt1 = sysClr window');
    });

    test('★ `clrMap` 把逻辑名映射到槽位：tx1→dk1、bg1→lt1、tx2→dk2、bg2→lt2', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:schemeClr val="tx1"/>'),
          _solid('<a:schemeClr val="bg1"/>'),
          _solid('<a:schemeClr val="tx2"/>'),
          _solid('<a:schemeClr val="bg2"/>'),
        ]),
      )!;
      expect(_fill(deck, 0), 0xFF000000);
      expect(_fill(deck, 1), 0xFFFFFFFF);
      expect(_fill(deck, 2), 0xFF1F497D);
      expect(_fill(deck, 3), 0xFFEEECE1);
    });

    test('★ 母版换了 `clrMap` 的排序，解引用必须跟着换（不是写死 tx1→dk1）', () {
      // 一个"反色"映射：tx1→lt1（白字）、bg1→dk1（黑底）。
      const inverted =
          '<p:clrMap bg1="dk1" tx1="lt1" bg2="dk2" tx2="lt2" '
          'accent1="accent1" accent2="accent2" accent3="accent3" '
          'accent4="accent4" accent5="accent5" accent6="accent6" '
          'hlink="hlink" folHlink="folHlink"/>';
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:schemeClr val="tx1"/>'),
          _solid('<a:schemeClr val="bg1"/>'),
        ], masterClrMap: inverted),
      )!;
      expect(_fill(deck, 0), 0xFFFFFFFF, reason: '这份文件的 tx1 指向 lt1');
      expect(_fill(deck, 1), 0xFF000000, reason: '这份文件的 bg1 指向 dk1');
    });

    test('主题缺该槽位 ⇒ **不静默丢**：退回原名再查一次，仍无则无填充', () {
      // 只给 dk1 一个槽位的残缺主题。
      const tiny =
          '<a:clrScheme name="t"><a:dk1><a:srgbClr val="112233"/></a:dk1>'
          '</a:clrScheme>';
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:schemeClr val="dk1"/>'),
          _solid('<a:schemeClr val="accent3"/>'),
          _solid('<a:schemeClr val="tx1"/>'),
        ], clrScheme: tiny),
      )!;
      expect(
        deck.slides.first.shapes,
        hasLength(2),
        reason: '中间那个"查不到颜色"的形状应当**整条不上色**（不猜颜色）',
      );
      expect(_fill(deck, 0), 0xFF112233);
      // accent3 主题里没有、`clrMap` 里也没有 ⇒ 无填充 ⇒ 该形状不出现在结果里。
      // tx1 有 clrMap 映射到 dk1 ⇒ 仍然查得到。
      expect(_fill(deck, 1), 0xFF112233);
    });
  });

  group('② 三种字面色写法：srgbClr / sysClr / prstClr', () {
    test('`srgbClr` 字面值 + `alpha` 修饰符', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:srgbClr val="0069E6"/>'),
          _solid('<a:srgbClr val="0069E6"><a:alpha val="100000"/></a:srgbClr>'),
          _solid('<a:srgbClr val="0069E6"><a:alpha val="50000"/></a:srgbClr>'),
          _solid('<a:srgbClr val="0069E6"><a:alpha val="0"/></a:srgbClr>'),
        ]),
      )!;
      expect(_fill(deck, 0), 0xFF0069E6);
      expect(_fill(deck, 1), 0xFF0069E6, reason: 'alpha 100% = 不透明');
      expect(_fill(deck, 2), 0x7F0069E6, reason: 'alpha 50% → 0x7F（截断）');
      expect(_fill(deck, 3), 0x000069E6, reason: 'alpha 0 = 全透明');
    });

    test('`sysClr` 取 `lastClr`；`prstClr` 走预设表', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:sysClr val="windowText" lastClr="123456"/>'),
          _solid('<a:prstClr val="red"/>'),
          _solid('<a:prstClr val="white"/>'),
        ]),
      )!;
      expect(_fill(deck, 0), 0xFF123456);
      expect(_fill(deck, 1), 0xFFFF0000);
      expect(_fill(deck, 2), 0xFFFFFFFF);
    });

    test('已知缺口：`scrgbClr` **未实现** ⇒ 无填充（不猜颜色）', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:scrgbClr val="50000,50000,50000"/>'),
        ]),
      )!;
      expect(
        deck.slides.first.shapes,
        isEmpty,
        reason: '未实现的写法必须"无填充"降级（整条形状不上色）；哪天实现了这条要主动改掉',
      );
    });
  });

  group('③ DrawingML 修饰符演算（ISO/IEC 29500-1 §20.1.2.3）', () {
    test('★ `tint`：规范原文"10% tint = 10% 输入色 + 90% 白"', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          // 4F81BD = (79,129,189)；C' = C*0.1 + 255*0.9
          //   R 7.9+229.5 = 237.4 → 237(ED)
          //   G 12.9+229.5 = 242.4 → 242(F2)
          //   B 18.9+229.5 = 248.4 → 248(F8)
          _solid(
            '<a:schemeClr val="accent1"><a:tint val="10000"/></a:schemeClr>',
          ),
          // 100% tint = 不变
          _solid(
            '<a:schemeClr val="accent1"><a:tint val="100000"/></a:schemeClr>',
          ),
          // 0% tint = 全白
          _solid('<a:schemeClr val="accent1"><a:tint val="0"/></a:schemeClr>'),
        ]),
      )!;
      expect(_fill(deck, 0), 0xFFEDF2F8);
      expect(_fill(deck, 1), 0xFF4F81BD);
      expect(_fill(deck, 2), 0xFFFFFFFF);
    });

    test('★ `shade`：规范原文"10% shade = 10% 输入色 + 90% 黑"', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid(
            '<a:schemeClr val="accent1"><a:shade val="10000"/></a:schemeClr>',
          ),
          _solid(
            '<a:schemeClr val="accent1"><a:shade val="100000"/></a:schemeClr>',
          ),
          _solid('<a:schemeClr val="accent1"><a:shade val="0"/></a:schemeClr>'),
        ]),
      )!;
      // (79,129,189)*0.1 = (7.9,12.9,18.9) → 截断 (7,12,18) = 07 0C 12
      expect(_fill(deck, 0), 0xFF070C12);
      expect(_fill(deck, 1), 0xFF4F81BD);
      expect(_fill(deck, 2), 0xFF000000);
    });

    test('★★ `lumMod`+`lumOff` 必须复现 **Office 官方主题调色板**（外部真值）', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          // accent1 = 4F81BD 的官方公开派生色
          _solid(
            '<a:schemeClr val="accent1"><a:lumMod val="40000"/>'
            '<a:lumOff val="60000"/></a:schemeClr>',
          ),
          _solid(
            '<a:schemeClr val="accent1"><a:lumMod val="75000"/></a:schemeClr>',
          ),
        ]),
      )!;
      expect(
        _fill(deck, 0),
        0xFFB8CCE4,
        reason:
            '4F81BD 的官方 "Lighter 40%" 是 B8CCE4 —— '
            '这条同时钉死了取整口径（四舍五入会得到 B9CDE5）',
      );
      expect(
        _fill(deck, 1),
        0xFF366092,
        reason: '4F81BD 的官方 "Darker 25%" 是 366092',
      );
    });

    test('★ 修饰符**按文档顺序**作用：先 mod 后 off ≠ 先 off 后 mod', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid(
            '<a:schemeClr val="accent1"><a:lumMod val="40000"/>'
            '<a:lumOff val="60000"/></a:schemeClr>',
          ),
          _solid(
            '<a:schemeClr val="accent1"><a:lumOff val="60000"/>'
            '<a:lumMod val="40000"/></a:schemeClr>',
          ),
        ]),
      )!;
      expect(_fill(deck, 0), 0xFFB8CCE4);
      expect(
        _fill(deck, 1),
        isNot(0xFFB8CCE4),
        reason: '顺序不该被忽略 —— 交换顺序必须得到不同结果',
      );
    });

    test('`lumMod` 只动 L：色相与饱和度不变（规范原文口径）', () {
      // 纯红 FF0000（H=0,S=1,L=0.5）lumMod 50% ⇒ L=0.25 ⇒ FF0000 的等比暗版 800000。
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:srgbClr val="FF0000"><a:lumMod val="50000"/></a:srgbClr>'),
          _solid('<a:srgbClr val="4F81BD"><a:lumOff val="20000"/></a:srgbClr>'),
        ]),
      )!;
      // FF0000：H=0,S=1,L=0.5 → lumMod 50% ⇒ L=0.25 ⇒ R=0.5*255=127.5 → 截断 127
      expect(_fill(deck, 0), 0xFF7F0000, reason: 'H=0 的暗半（截断口径 = 7F0000）');
      // 4F81BD：L=0.52549 → +0.2 = 0.72549
      //   q = l+s-l*s = 0.85027，p = 2l-q = 0.60071
      //   R = p*255 = 153.18 → 153(99)
      //   G = (p+(q-p)*((2/3-h)*6))*255 = 0.71415*255 = 182.10 → 182(B6)
      //   B = q*255 = 216.82 → 216(D8)
      expect(_fill(deck, 1), 0xFF99B6D8);
    });

    test('修饰符叠在 `srgbClr` 上也生效（不只 `schemeClr`）', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:srgbClr val="000000"><a:tint val="50000"/></a:srgbClr>'),
          _solid('<a:srgbClr val="FFFFFF"><a:shade val="50000"/></a:srgbClr>'),
        ]),
      )!;
      expect(_fill(deck, 0), 0xFF7F7F7F, reason: '黑 + 50% tint = 127.5 → 127');
      expect(_fill(deck, 1), 0xFF7F7F7F, reason: '白 + 50% shade = 127.5 → 127');
    });

    test('未实现的修饰符**跳过不改色**，但同一元素上的已实现修饰符仍生效', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid(
            '<a:schemeClr val="accent1"><a:satMod val="200000"/>'
            '<a:lumMod val="75000"/></a:schemeClr>',
          ),
        ]),
      )!;
      expect(
        _fill(deck, 0),
        0xFF366092,
        reason: 'satMod 未实现 ⇒ 跳过（不假装认识）；lumMod 照常生效',
      );
    });
  });

  group('④ 底色/背景的继承链（本页 → 版式 → 母版）', () {
    test('★ 本页没有 `<p:bg>` ⇒ 取**版式**的（真机 Technology 第 1 页就是这条）', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(
          <String>[_solid('<a:srgbClr val="000000"/>')],
          layoutBg: '0069E6',
          masterBg: 'FFFFFF',
        ),
      )!;
      expect(deck.slides.first.backgroundArgb, 0xFF0069E6);
      expect(deck.slides.first.backgroundInherited, isTrue);
    });

    test('版式也没有 ⇒ 取**母版**的', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:srgbClr val="000000"/>'),
        ], masterBg: '112233'),
      )!;
      expect(deck.slides.first.backgroundArgb, 0xFF112233);
      expect(deck.slides.first.backgroundInherited, isTrue);
    });

    test('★ 本页自己有 `<p:bg>` ⇒ **优先**于版式与母版', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(
          <String>[_solid('<a:srgbClr val="000000"/>')],
          slideBg: 'AABBCC',
          layoutBg: '0069E6',
          masterBg: 'FFFFFF',
        ),
      )!;
      expect(deck.slides.first.backgroundArgb, 0xFFAABBCC);
      expect(deck.slides.first.backgroundInherited, isFalse);
    });

    test('★ 背景也能用引用色（`schemeClr` + `lumMod`）', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(
          <String>[_solid('<a:srgbClr val="000000"/>')],
          layoutBgXml:
              '<p:bg><p:bgPr><a:solidFill><a:schemeClr val="accent1">'
              '<a:lumMod val="40000"/><a:lumOff val="60000"/>'
              '</a:schemeClr></a:solidFill></p:bgPr></p:bg>',
        ),
      )!;
      expect(
        deck.slides.first.backgroundArgb,
        0xFFB8CCE4,
        reason: '版式底色的引用色走的是同一条解引用路径（含修饰符）',
      );
      expect(deck.slides.first.backgroundInherited, isTrue);
    });
  });

  group('⑤ `clrMapOvr` 覆盖映射的继承顺序', () {
    // 一个"反色"覆盖映射（tx1↔bg1）。
    const override =
        '<a:overrideClrMapping bg1="dk1" tx1="lt1" bg2="dk2" tx2="lt2" '
        'accent1="accent1" accent2="accent2" accent3="accent3" '
        'accent4="accent4" accent5="accent5" accent6="accent6" '
        'hlink="hlink" folHlink="folHlink"/>';

    test('本页 `overrideClrMapping` 优先于母版 `clrMap`', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:schemeClr val="tx1"/>'),
        ], slideClrMapOvr: override),
      )!;
      expect(_fill(deck, 0), 0xFFFFFFFF, reason: '本页把 tx1 覆盖成 lt1（白）');
    });

    test('版式 `overrideClrMapping` 对版式装饰生效', () {
      final deck = OSlidesDeck.parse(
        buildSyntheticPptx(
          slideSpTree: '',
          layoutClrMapOvr: '<p:clrMapOvr>$override</p:clrMapOvr>',
          layoutExtraShapes: syntheticRect(
            id: 50,
            fill: _solid('<a:schemeClr val="tx1"/>'),
          ),
        ),
      )!;
      // 唯一的形状来自版式装饰 ⇒ 用版式的覆盖映射 ⇒ 白。
      expect(deck.slides.first.shapes, hasLength(1));
      expect(_fill(deck, 0), 0xFFFFFFFF);
    });

    test('`<a:masterClrMapping/>` 的语义是"用母版的"，不能被当成空映射', () {
      final deck = OSlidesDeck.parse(
        syntheticPptxWithFills(<String>[
          _solid('<a:schemeClr val="tx1"/>'),
        ], slideClrMapOvr: '<a:masterClrMapping/>'),
      )!;
      expect(_fill(deck, 0), 0xFF000000, reason: '母版 tx1→dk1（黑）');
    });

    test('本页覆盖优先于版式覆盖', () {
      // 版式把 tx1→lt1，本页把它改回 tx1→dk1。
      final deck = OSlidesDeck.parse(
        buildSyntheticPptx(
          slideSpTree: syntheticRect(
            id: 2,
            fill: _solid('<a:schemeClr val="tx1"/>'),
          ),
          layoutClrMapOvr: '<p:clrMapOvr>$override</p:clrMapOvr>',
          slideClrMapOvr:
              '<a:overrideClrMapping bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" '
              'accent1="accent1" accent2="accent2" accent3="accent3" '
              'accent4="accent4" accent5="accent5" accent6="accent6" '
              'hlink="hlink" folHlink="folHlink"/>',
        ),
      )!;
      expect(_fill(deck, 0), 0xFF000000, reason: '本页覆盖 > 版式覆盖');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('⑥ 真机样本的客观事实（报告里的统计数字必须能被机器复核）', () {
    // 统计口径：**独立**用 `ZipDecoder` 解包（不走被测解析器），
    // 只统计 `ppt/slides|slideLayouts|slideMasters/**.xml`（**不含** theme）。
    final counts = <String, Map<String, int>>{};
    for (final name in <String>[
      'technology.oslides',
      'dynamic.oslides',
      'celestial.oslides',
    ]) {
      final bytes = File(
        'test/fixtures/office_slides_o3/$name',
      ).readAsBytesSync();
      final zip = ZipDecoder().decodeBytes(bytes);
      final buf = StringBuffer();
      for (final f in zip.files) {
        if (!f.isFile) continue;
        final n = f.name;
        final inDeck =
            n.startsWith('ppt/slides/') ||
            n.startsWith('ppt/slideLayouts/') ||
            n.startsWith('ppt/slideMasters/');
        if (inDeck && n.endsWith('.xml')) {
          buf.write(utf8.decode(f.content as List<int>, allowMalformed: true));
        }
      }
      final text = buf.toString();
      counts[name] = <String, int>{
        for (final t in <String>[
          'srgbClr',
          'schemeClr',
          'sysClr',
          'prstClr',
          'alpha',
          'lumMod',
          'lumOff',
          'tint',
          'shade',
          'overrideClrMapping',
        ])
          t: RegExp('<a:$t[ />]').allMatches(text).length,
      };
    }

    test('★ 三份样本**一个引用色、一个修饰符都没有**（所以修饰符演算对它们零效果）', () {
      for (final entry in counts.entries) {
        for (final t in <String>[
          'schemeClr',
          'sysClr',
          'prstClr',
          'lumMod',
          'lumOff',
          'tint',
          'shade',
          'overrideClrMapping',
        ]) {
          expect(
            entry.value[t],
            0,
            reason:
                '${entry.key} 里出现了 ${entry.value[t]} 个 $t —— '
                '报告里"真样本不受修饰符演算影响"的结论会因此失效，必须重写',
          );
        }
        expect(
          entry.value['srgbClr'],
          greaterThan(200),
          reason: '${entry.key} 的填充几乎全是字面 srgbClr',
        );
      }
    });

    test('★ 逐份样本的字面色/透明度计数（报告引用的数字）', () {
      expect(counts['technology.oslides']!['srgbClr'], 302);
      expect(counts['technology.oslides']!['alpha'], 25);
      expect(counts['dynamic.oslides']!['srgbClr'], 308);
      expect(counts['dynamic.oslides']!['alpha'], 14);
      expect(counts['celestial.oslides']!['srgbClr'], 217);
      expect(counts['celestial.oslides']!['alpha'], 19);
    });
  });
}
