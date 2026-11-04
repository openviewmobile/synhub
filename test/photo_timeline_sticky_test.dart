// 时间轴「悬浮日期指示」测试（第 263 轮）。
//
// 需求（用户原话）：「timeline的时间标签在向下滑动的时候可以替换掉上方状态栏
// Time scale 这几个字，起到一个悬浮指示的效果」。
//
// 落地口径（`lib/src/features/photos/photo_browse_page.dart`）：
//   * 顶栏（`photo-timeline-view-bar`）**固定不动**，左槽在「时间刻度」与
//     「当前分组日期」之间切换；右槽两枚时间刻度按钮（密度 / 日-月-年）原位保留；
//   * 当前分组 = **视口顶边所在的分组**，由 [photoTopmostSectionIndex] 按
//     "各分组标题的滚动起点"算出（起点是**实测**的 `RenderBox` 全局 Y，
//     不是按行高估算的）。
//
// 本文件的口径：
//   1. 纯函数 [photoTopmostSectionIndex] 的边界；
//   2. 标签**真的**跟着滚动换成"顶边所在分组"的日期，且与测试侧**独立量出的**
//      顶边分组一致；
//   3. 时间刻度按钮滚动前后**都在屏内、互不重叠、点得开**（矩形断言）；
//   4. 标签不被截断 —— 用 `RenderParagraph.didExceedMaxLines` 判，不用布局断言。
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/media/media_player.dart'
    show MediaPlayerAdapter, mediaPlayerAdapterFactoryProvider;
import 'package:synhub/src/features/media/media_source.dart'
    show MediaSource;
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 真 PNG（缩略图走字节链路，没有能解码的字节只会画占位图标）。
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

const _fotoTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Browse.Album': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Browse.Folder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 假播放器适配器（本文件用不到播放，只为满足 provider 覆盖）。
class _FakeVideoAdapter implements MediaPlayerAdapter {
  final _changes = StreamController<void>.broadcast();

  @override
  Future<void> load(MediaSource source) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(Duration position) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => null;

  @override
  bool get playing => false;

  @override
  bool get ready => true;

  @override
  double get speed => 1;

  @override
  String? get error => null;

  @override
  double get aspectRatio => 16 / 9;

  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(color: Colors.black);

  @override
  Stream<void> get changes => _changes.stream;
}

Map<String, dynamic> _item(String id, int day, int n) => {
  'id': id,
  'filename': 'IMG_$id.jpg',
  'filesize': 1024 * 512,
  'time': DateTime(2026, 9, day, 10, n).millisecondsSinceEpoch ~/ 1000,
  'indexed_time': DateTime(2026, 9, day, 11).millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': 'photo',
  'additional': {
    'thumbnail': {'sm': 'ready', 'm': 'ready', 'xl': 'ready', 'cache_key': 'ck_$id'},
  },
};

/// 3 天，每天 **6 / 5 / 4** 张（共 15 张）—— 计数**故意不相等**，
/// 这样"滚到下一段后 N 真的换了"才是一条能被用例抓住的断言。
List<Map<String, dynamic>> _items() => [
  for (final (day, n) in <(int, int)>[(20, 6), (19, 5), (18, 4)])
    for (var i = 0; i < n; i++) _item('$day$i', day, i),
];

const double _kWidth = 400;
const double _kHeight = 480;

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  double width = _kWidth,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = Size(width * 3, _kHeight * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final t = FakeTransport(const {}, {...FakeTransport.table, ..._fotoTable});
  t.downloadBytes = _png;
  t.onCall = (params) {
    final method = '${params['method']}';
    if (method == 'get' && '${params['api']}'.contains('Setting.User')) {
      return {
        'team_space_permission': 'none',
        'enable_person': false,
        'timeline_group_unit': 'day',
        'item_sort_by': 'takentime',
        'sort_direction': 'desc',
      };
    }
    if (method == 'list') {
      final all = _items();
      return {'list': all, 'total': all.length};
    }
    return const <String, dynamic>{};
  };
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      // 内嵌播放器：假适配器，绝不碰平台通道（`video_player` 在单测里起不来）
      mediaPlayerAdapterFactoryProvider.overrideWithValue(
        () => _FakeVideoAdapter(),
      ),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: PhotoBrowsePage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return c;
}

final Finder _bar = find.byKey(const Key('photo-timeline-view-bar'));

/// 顶栏**左槽**（悬浮指示的槽位，`Expanded`）——量"左边缘"必须盯这个槽里的文字。
final Finder _stickySlot = find.byKey(const Key('photo-timeline-sticky-slot'));

/// 顶栏左槽当前显示的文字（`AnimatedSwitcher` 结束后只有一个）。
///
/// 只找左槽内的 `Text` —— 顶栏里还有两枚 chip 的文字，不能靠 `.first` 碰运气。
String _stickyText(WidgetTester tester) {
  final texts = find.descendant(of: _stickySlot, matching: find.byType(Text));
  return tester.widget<Text>(texts.first).data ?? '';
}

/// 顶栏左槽里**那个 `Text` 的矩形**（居中 bug 的钉子量的是它）。
Rect _stickyRect(WidgetTester tester) => tester.getRect(
  find.descendant(of: _stickySlot, matching: find.byType(Text)).first,
);

/// 分组 [g] 的标题文字（从**列表里的分组标题**上读，不硬编码语言）。
String _sectionLabel(WidgetTester tester, int g) {
  final row = find.byKey(Key('photo-timeline-section-$g'));
  final texts = find.descendant(of: row, matching: find.byType(Text));
  return tester.widget<Text>(texts.first).data ?? '';
}

/// 分组 [g] 在**列表标题行右端**显示的条目数 —— 这就是"权威来源"。
///
/// 悬浮日期括号里的 N 必须等于它（同源：都来自 `groupPhotos` 的 `$2.length`）。
int _sectionCount(WidgetTester tester, int g) {
  final row = find.byKey(Key('photo-timeline-section-$g'));
  final texts = find.descendant(of: row, matching: find.byType(Text));
  return int.parse(tester.widget<Text>(texts.at(1)).data!);
}

/// 列表当前的滚动偏移（纵向那一条）。
double _offset(WidgetTester tester) {
  final s = tester.state<ScrollableState>(
    find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    ),
  );
  return s.position.pixels;
}

/// 测试侧**独立**量出"顶边所在分组"。
///
/// 不在滚动后量标题的当前 Y（那时"顶边那一组"的标题早已被回收、根本不在树里），
/// 而是：先在 **offset = 0** 量出各组标题的起点 [starts]，滚动后再用
/// **真实滚动偏移** 按同一几何定义重算一遍。两边都只依赖 `tester` 的渲染几何，
/// 不读实现里存的那份 offsets。
int? _topmostFromStarts(List<double> starts, double offset) {
  int? best;
  for (var g = 0; g < starts.length; g++) {
    if (starts[g] <= offset + 0.5) best = g;
  }
  return best;
}

/// 当前测试视口的逻辑宽度（不写死 400，窄屏用例也复用这个断言）。
double _vw(WidgetTester tester) =>
    tester.view.physicalSize.width / tester.view.devicePixelRatio;

/// 断言两枚时间刻度按钮：**≥48dp**、都在屏内、互不重叠、不与左槽文字重叠。
void _expectControlsUsable(WidgetTester tester, {required String because}) {
  final density = tester.getRect(find.byKey(const Key('photo-grid-density')));
  final mode = tester.getRect(find.byKey(const Key('photo-timeline-view-mode')));
  final label = _stickyRect(tester);
  expect(density.overlaps(mode), isFalse, reason: '密度/日-月-年 不能叠在一起：$because');
  expect(label.overlaps(density), isFalse, reason: '悬浮日期不能压住密度按钮：$because');
  // 左槽文字必须在两枚按钮**左边**（左对齐之后它贴着槽左沿）。
  expect(label.right, lessThanOrEqualTo(density.left + 0.5),
      reason: '左槽文字必须整段在两枚按钮左侧：$because');
  for (final (name, r) in [('密度', density), ('日-月-年', mode)]) {
    // AGENTS §2.0.10：48dp 是最小点击区。
    expect(r.width, greaterThanOrEqualTo(48 - 0.5),
        reason: '$name 点击区宽度必须 ≥48dp（$r）：$because');
    expect(r.height, greaterThanOrEqualTo(48 - 0.5),
        reason: '$name 点击区高度必须 ≥48dp（$r）：$because');
    expect(r.left >= -0.5 && r.right <= _vw(tester) + 0.5, isTrue,
        reason: '$name 按钮必须完整在屏内（$r）：$because');
    expect(r.top >= -0.5 && r.bottom <= _kHeight + 0.5, isTrue,
        reason: '$name 按钮必须完整在屏内（$r）：$because');
  }
}

void main() {
  group('photoTopmostSectionIndex（纯函数）', () {
    test('空表 / 全 null → null', () {
      expect(photoTopmostSectionIndex(const [], 100), isNull);
      expect(photoTopmostSectionIndex(const [null, null], 100), isNull);
    });

    test('顶边落在哪个分组就是哪个分组', () {
      const starts = <double?>[0, 100, 250];
      expect(photoTopmostSectionIndex(starts, 0), 0);
      expect(photoTopmostSectionIndex(starts, 99), 0);
      expect(photoTopmostSectionIndex(starts, 100), 1, reason: '正好等于起点算下一组');
      expect(photoTopmostSectionIndex(starts, 249.2), 1);
      expect(photoTopmostSectionIndex(starts, 250), 2);
      expect(photoTopmostSectionIndex(starts, 99999), 2);
    });

    test('深在某个大分组内部（它的标题已滚出缓存 = null）结论仍然正确', () {
      // 第 1 组的标题已被回收 ⇒ null，但它的起点早已记下（100）。
      const starts = <double?>[0, 100, null];
      expect(photoTopmostSectionIndex(starts, 400), 1);
      // 第 0 组同理。
      expect(photoTopmostSectionIndex(const <double?>[0, null, null], 50), 0);
    });

    test('还没滚到任何分组的起点之后 → null（界面显示「时间刻度」）', () {
      expect(photoTopmostSectionIndex(const <double?>[40, 200], 0), isNull);
    });
  });

  group('时间轴悬浮日期指示（真机形态的 widget 测试）', () {
    testWidgets('① 未滚动时左槽是「时间刻度」，滚起来换成顶边分组的日期', (
      tester,
    ) async {
      await _pump(tester);

      // offset = 0 时量基线：各组标题的**起点**（= 标题全局 Y − 列表顶边 Y）
      // 与标题文字。只量已经构建出来的那些组。
      final listTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
      final starts = <double>[];
      final labels = <String>[];
      final counts = <int>[];
      for (var g = 0; g < 3; g++) {
        final f = find.byKey(Key('photo-timeline-section-$g'));
        if (f.evaluate().isEmpty) break;
        starts.add(tester.getTopLeft(f).dy - listTop);
        labels.add(_sectionLabel(tester, g));
        counts.add(_sectionCount(tester, g));
      }
      expect(starts.length, greaterThanOrEqualTo(2), reason: '至少要有两段可测');
      expect(_offset(tester), 0);

      // 一进来（offset = 0）：还是「时间刻度」——第一段标题还没被顶栏"吃掉"。
      expect(
        _stickyText(tester),
        '时间刻度',
        reason: '未滚动时不该抢在分组标题前面显示日期',
      );
      _expectControlsUsable(tester, because: '未滚动');
      final density0 = tester.getRect(
        find.byKey(const Key('photo-grid-density')),
      );

      // ①-a 只滚一点点（< 第一段标题高度）：还是「时间刻度」。
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -24));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        _stickyText(tester),
        '时间刻度',
        reason: '第一段标题还没整个滚出顶边，先不顶替（要看着它"滑上去"）',
      );
      _expectControlsUsable(tester, because: '轻滚');

      // ①-b 滚进第一段内部：左槽换成第一段的日期。
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -220));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final o1 = _offset(tester);
      final expected1 = _topmostFromStarts(starts, o1);
      expect(expected1, 0, reason: 'offset=$o1 只进了第一段（starts=$starts）');
      expect(
        _stickyText(tester),
        '${labels[0]} (${counts[0]})',
        reason: '悬浮日期 = 顶边所在分组的标题 + 该组条目数（同源计数）',
      );
      expect(_stickyText(tester), isNot('${labels[1]} (${counts[1]})'));
      _expectControlsUsable(tester, because: '滚动中');

      // ①-c 继续滚进第二段：标签跟着换（"always matches"）。
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final o2 = _offset(tester);
      final expected2 = _topmostFromStarts(starts, o2);
      expect(expected2, isNotNull);
      expect(
        _stickyText(tester),
        '${labels[expected2!]} (${counts[expected2]})',
        reason: 'offset=$o2 时悬浮日期必须等于顶边所在分组的标题 + 该组计数',
      );
      // 这一段必须真的换了（否则"跟着滚动"没有证据）。
      expect(expected2, greaterThanOrEqualTo(1), reason: 'offset=$o2 已越过第一段');
      expect(_stickyText(tester), isNot('${labels[0]} (${counts[0]})'));
      _expectControlsUsable(tester, because: '滚动到第二段');
      // 密度按钮的矩形尺寸不随滚动变化（说明它没被挤出/压缩）。
      expect(
        tester.getRect(find.byKey(const Key('photo-grid-density'))).size,
        density0.size,
      );
    });

    testWidgets('② 滚动后两枚时间刻度按钮仍可点（点得开菜单）', (tester) async {
      await _pump(tester);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -220));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 密度菜单打得开
      await tester.tap(find.byKey(const Key('photo-grid-density')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.text('中'),
        findsWidgets,
        reason: '密度菜单必须还能打开（默认档是"中"）',
      );
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 日/月/年 菜单打得开
      await tester.tap(find.byKey(const Key('photo-timeline-view-mode')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('月'), findsWidgets, reason: '日-月-年菜单必须还能打开');
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('③ 悬浮日期不被截断（RenderParagraph.didExceedMaxLines）', (
      tester,
    ) async {
      await _pump(tester);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -220));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final para = tester.renderObject<RenderParagraph>(
        find.descendant(of: _bar, matching: find.byType(Text)).first,
      );
      expect(
        para.didExceedMaxLines,
        isFalse,
        reason: '悬浮日期必须完整显示（截断了就得改文案/宽度，不能靠缩字号）',
      );
      // 而且它得是**真的画出来了**（不是空串）。
      expect(_stickyText(tester).trim(), isNotEmpty);
    });

    // ★★★ r332：**真机几何**（LGE-AN10 逻辑宽 375dp，AGENTS §2.0.46）单独钉一条。
    // 修前：真主题下 `<日期> (N)` 需要 277.4dp，375dp 下左槽只有约 268dp ⇒ 中文日期被省略成
    // `2026 年 9 月 20 …`。修法 = 收回 16+4dp 的条内边距 + **装不下 `(N)` 就退成只有日期**
    // （条目数在列表内分组标题里本来就有）。这条在"把修复拿掉"时会真红。
    testWidgets('③b 真机 375dp：悬浮日期同样不被截断（装不下 (N) 时退成只有日期）', (
      tester,
    ) async {
      await _pump(tester, width: 375);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -220));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final para = tester.renderObject<RenderParagraph>(
        find.descendant(of: _bar, matching: find.byType(Text)).first,
      );
      expect(
        para.didExceedMaxLines,
        isFalse,
        reason: '375dp（真机几何）下悬浮日期必须完整显示：装不下 `(N)` 就退成只有日期',
      );
      final shown = _stickyText(tester);
      expect(shown.trim(), isNotEmpty);
      expect(shown, isNot('时间刻度'), reason: '已经滚进分组了，就该显示日期');
    });

    testWidgets('④ 悬浮日期的**左边缘** == 「时间刻度」的左边缘（居中 bug 的钉子）', (
      tester,
    ) async {
      await _pump(tester);

      // 基线：未滚动时左槽是「时间刻度」，量它那个 Text 的矩形。
      // ★ 这里连基线一起钉 —— 修复前连「时间刻度」都是被 AnimatedSwitcher 的
      // 默认 `Stack(alignment: center)` 居中的（槽 12→287.2、文字中心 149.6）。
      expect(_stickyText(tester), '时间刻度');
      final base = _stickyRect(tester);
      final slot = tester.getRect(_stickySlot);
      expect(
        base.left - slot.left,
        closeTo(0, 0.5),
        reason: '「时间刻度」必须贴着左槽左沿（修复前它被居中在槽里）：base=$base slot=$slot',
      );

      // 滚进第一段：换成日期（文字宽度不同）——左边缘必须**一动不动**。
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -220));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_stickyText(tester), isNot('时间刻度'), reason: '该换成日期了');
      final pinned0 = _stickyRect(tester);
      expect(
        pinned0.left,
        closeTo(base.left, 0.5),
        reason:
            '★ 居中 bug 的钉子：日期左边缘(${pinned0.left}) 必须等于 '
            '「时间刻度」左边缘(${base.left})；二者文字宽度不同，'
            '居中必然对不齐',
      );

      // 再滚进第二段（文字宽度又变）：左边缘仍然不动。
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        _stickyRect(tester).left,
        closeTo(base.left, 0.5),
        reason: '换到第二段后左边缘仍必须与基线一致',
      );
    });

    testWidgets('⑤ 括号里 N == 该分组标题右端的条目数（滚动换组后仍成立）', (
      tester,
    ) async {
      await _pump(tester);

      final labels = <String>[];
      final counts = <int>[];
      for (var g = 0; g < 3; g++) {
        final f = find.byKey(Key('photo-timeline-section-$g'));
        if (f.evaluate().isEmpty) break;
        labels.add(_sectionLabel(tester, g));
        counts.add(_sectionCount(tester, g));
      }
      expect(counts.length, greaterThanOrEqualTo(2), reason: '至少两段可测');
      expect(counts[0], 6, reason: '构造数据：第一天 6 张（三天是 6/5/4）');

      // 滚进第一段：文案必须是 `<第一段标题> (6)`，形态严格是 "… (N)"。
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -220));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final shown0 = _stickyText(tester);
      expect(shown0, '${labels[0]} (${counts[0]})');
      final m0 = RegExp(r'^(.*) \((\d+)\)$').firstMatch(shown0);
      expect(m0, isNotNull, reason: '必须是"… (N)"形态：$shown0');
      expect(m0!.group(1), labels[0], reason: '括号左边就是分组标题本身');
      expect(
        int.parse(m0.group(2)!),
        counts[0],
        reason: '★ N 必须等于该段标题右端的数字（同源，不是第二份计数）',
      );

      // 继续滚进第二段：N 跟着换成**第二段**的条目数（真的变了才算数）。
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        _stickyText(tester),
        '${labels[1]} (${counts[1]})',
        reason: '换组后 N 必须换成新分组的条目数',
      );
      expect(counts[1], isNot(counts[0]), reason: '两段计数相同就用例抓不住"没换"');
    });

    testWidgets('⑥ 切到「月」刻度：N = **那个月**的条目数（不是某一天）', (tester) async {
      await _pump(tester);

      // 日-月-年 菜单 → 选「月」。
      await tester.tap(find.byKey(const Key('photo-timeline-view-mode')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('月').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 3 天都在 2026-09 ⇒ 月刻度下只有 1 段、计数 = 全部 18 张。
      expect(
        find.byKey(const Key('photo-timeline-section-1')),
        findsNothing,
        reason: '月刻度下不该再按天切成 3 段',
      );
      final monthLabel = _sectionLabel(tester, 0);
      expect(_sectionCount(tester, 0), 15, reason: '"这个月"含全部 15 张，不是 6 张');

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -220));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        _stickyText(tester),
        '$monthLabel (15)',
        reason: '月刻度下括号里是**整月**的条目数',
      );
    });

    // ⑦ 320/360/414dp × 1.0/2.0 字号：每个组合**各起一条用例**。
    // （在一条用例里反复 `_pump` 整页会留下待处理的 Timer，
    //   测试框架会以 "A Timer is still pending" 判红 —— 不是布局问题。）
    for (final w in <double>[320, 360, 414]) {
      for (final scale in <double>[1.0, 2.0]) {
        final tag = '${w.toInt()}dp @${scale}x';
        testWidgets('⑦ $tag：顶栏不溢出、按钮 ≥48dp、左槽仍左对齐', (tester) async {
          await _pump(tester, width: w, textScale: scale);
          expect(
            tester.takeException(),
            isNull,
            reason: '$tag 顶栏不得有 RenderFlex overflow',
          );
          // 两枚按钮仍要 ≥48dp、在屏内、不重叠（含左槽文字）。
          _expectControlsUsable(tester, because: tag);
          // 左槽文字仍然左对齐（不是被挤成居中）。
          final slot = tester.getRect(_stickySlot);
          expect(
            _stickyRect(tester).left - slot.left,
            closeTo(0, 0.5),
            reason: '$tag 左槽文字必须仍贴左沿',
          );
          // 滚起来（换成日期）也不许溢出 —— 日期带括号计数后更长。
          await tester.drag(find.byType(CustomScrollView), const Offset(0, -220));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull, reason: '$tag 滚动后仍不得溢出');
          _expectControlsUsable(tester, because: '$tag（已滚动）');
          expect(
            _stickyRect(tester).left - tester.getRect(_stickySlot).left,
            closeTo(0, 0.5),
            reason: '$tag 滚动换日期后仍必须贴左沿',
          );
        });
      }
    }
  });
}
