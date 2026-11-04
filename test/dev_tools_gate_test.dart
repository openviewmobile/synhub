// 静态守卫：**临时/调试页面在 release 档必须不可达**（r378 起，用户上线要求；r389 加固）。
//
// ★ 为什么用静态守卫而不是 widget 用例：`kDevTools` 是**编译期常量**
//   （`bool.fromEnvironment`），widget 用例里改不了它的取值；
//   而"release 包里没有这两个入口"正是**由编译期保证**的
//   ⇒ 要守的就是"每个入口都挂在 `if (kDevTools)` 里面"这个**结构事实**。
//
// ★★ r389 加固的原因（**先证伪旧守卫，再改**）：
//   旧守卫只扫两个**限定引用字面量** `AppRoutes.designPreview` / `AppRoutes.diagnostics`。
//   我在 `app_router.dart` 里注入了一条**没有守**的 dev 路由
//   （`path: '/dev-sandbox'` + `builder: … const DesignPreviewPage()`，全程不出现那两个字面量），
//   旧守卫 **4/4 全绿** ⇒ 它是**假绿**：新加一个临时页面照样能发出去。
//   ⇒ 现在的扫面从 1 个扩成 3 个（见下）。
//
// 扫面（§2.0.63⑤：守卫必须说清它认哪些形状）：
//   ① **引用面**：`AppRoutes.designPreview( Name)` / `AppRoutes.diagnostics( Name)`
//      + 两个页面的**控件类名** `DesignPreviewPage` / `DiagPage`
//      （类名只扫"不是这两个页面自己文件"的地方 —— 定义处不算引用）；
//   ② **路由注册面**：`app_router.dart` 里每一条 `path:` 表达式都要么在
//      **_prodPaths 冻结清单**里，要么被 `if (kDevTools)` 守住
//      ⇒ **新增任何一条路由（哪怕换了新名字/新字面量）都会红**，逼作者表态；
//   ③ **自述面**：凡是在注释里自述"临时页面/调试页/仅供开发/debug only"的
//      `.dart` 文件必须出现在 **_devMarkedFiles 冻结清单**里
//      ⇒ 新写一个临时页面时，就算它没走路由（走弹层），清单对不上也会红。
//
// ★ 判"被守住了"的判据（缩进法）：引用点之前**最近**的一个 `if (kDevTools)`
//   必须存在，且 —— ① 引用点缩进 > 守卫行缩进；② 守卫与引用点之间**没有**任何
//   一行缩进 ≤ 守卫行缩进（= 没有人从 `if` 语句里"退出去"）。
//   这两条一起就把"搬出 `if` 却没删守卫"这种假绿挡住了。
//
// ★ 反向验证在文件底部：故意没守的片段（没守卫 / 缩进回落 / 从块里退出 /
//   类名形态 / 路由名形态 / 新路由字面量）**必须**被判红 —— 否则这条守卫等于没守（§2.0.51）。
//
// ★ 仍然守不住的（**如实声明，别当成守住了**）：一个**全新**的调试页面，
//   既不用这两个类、又没在注释里自述、还只通过弹层/`showDialog` 出现
//   —— 静态文本守卫**原理上**认不出来。兜底是**产物级**检查：
//   release 的 `libapp.so` 里不该出现该页面的专属文案（见 r389 台账 §S1/S2，
//   本轮实测：`dpBubble1`/`dpAttachGrid`/`diagStepTunnelOk`/`diagEchoEmpty`
//   在 release AOT 里 **0 命中**，而活文案 `Magnet link`/`磁力链接` 各 1 命中）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 被守的对象：限定引用/类名 → 允许出现的文件与次数（**清点式**，出现新文件即红）。
const Map<String, int> _expectedSites = {
  'lib/src/core/router/app_router.dart': 6, // 2 path + 2 name + 2 类名
  'lib/src/features/servers/server_setup_page.dart': 2,
  'lib/src/features/settings/settings_page.dart': 1,
  'lib/src/features/chat/chat_page.dart': 1,
};

const List<String> _needles = <String>[
  'AppRoutes.designPreview',
  'AppRoutes.designPreviewName',
  'AppRoutes.diagnostics',
  'AppRoutes.diagnosticsName',
  'DesignPreviewPage',
  'DiagPage',
];

/// 两个临时页面的**自己的文件**：类名在这里是"定义"而不是"引用"。
const Set<String> _devPageFiles = {
  'lib/src/features/design/design_preview_page.dart',
  'lib/src/features/diagnostics/diag_page.dart',
};

const String _guardMarker = 'if (kDevTools)';

/// ② 路由注册面：允许**不被** `if (kDevTools)` 守住的 path 表达式（r389 冻结）。
/// 新增路由（新名字、新字面量都算）不在这张表里 ⇒ 必须挂到开关上，否则红。
const List<String> _prodPaths = <String>[
  'AppRoutes.setup',
  'AppRoutes.login',
  'AppRoutes.home',
  'AppRoutes.chat', // 实际写成 '${AppRoutes.chat}/:channelId'，归一化成外层常量
  "'thread/:postId'",
  "'content/:kind'",
  "'hashtags'",
  "'scheduled'",
  "'reminders'",
  "'members'",
  "'media'",
  'AppRoutes.channelCreate',
  'AppRoutes.search',
  'AppRoutes.bots',
  'AppRoutes.settings',
  'AppRoutes.profileEdit',
  'AppRoutes.notifications',
  'AppRoutes.snooze',
  'AppRoutes.archives',
  'AppRoutes.certificates',
  'AppRoutes.serviceCheck',
  'AppRoutes.e2ee',
];

/// ③ 自述面：注释里自述是临时/调试用途的文件（r389 冻结）。
const Set<String> _devMarkedFiles = {
  'lib/src/core/dev/dev_tools.dart',
  'lib/src/core/router/app_router.dart',
  'lib/src/core/router/app_routes.dart',
  'lib/src/features/design/design_preview_page.dart',
  'lib/src/features/diagnostics/diag_page.dart',
};

const List<String> _devMarkers = <String>[
  '临时页面',
  '调试页',
  '仅供开发',
  'debug only',
  'Debug only',
];

/// ★ 逐字匹配：`AppRoutes.designPreview` **不该**把 `AppRoutes.designPreviewName`
///   也算成命中（子串会多算一倍）。判据 = 命中后紧跟的字符不是标识符字符。
bool _hasNeedle(String line, {List<String> needles = _needles}) {
  for (final n in needles) {
    var i = line.indexOf(n);
    while (i >= 0) {
      final after = i + n.length < line.length ? line[i + n.length] : ' ';
      if (!RegExp(r'[A-Za-z0-9_]').hasMatch(after)) return true;
      i = line.indexOf(n, i + 1);
    }
  }
  return false;
}

int _indentOf(String line) => line.length - line.trimLeft().length;

/// 返回违规说明；`null` = 这个引用点确实被 `if (kDevTools)` 守住了。
String? unguardedReason(List<String> lines, int index) {
  final line = lines[index];
  final indent = _indentOf(line);
  for (var i = index - 1; i >= 0; i--) {
    final l = lines[i];
    if (l.contains(_guardMarker)) {
      final guardIndent = _indentOf(l);
      if (indent <= guardIndent) {
        return '第 ${index + 1} 行缩进 $indent 不大于守卫行 ${i + 1} 的缩进 $guardIndent';
      }
      // 守卫与引用点之间不许有人"退出 if 语句"（缩进回落到 ≤ 守卫行）。
      for (var j = i + 1; j < index; j++) {
        final ml = lines[j];
        if (ml.trim().isEmpty) continue;
        if (_indentOf(ml) <= guardIndent) {
          return '第 ${j + 1} 行从守卫（第 ${i + 1} 行）里退了出去：${ml.trim()}';
        }
      }
      return null;
    }
  }
  return '第 ${index + 1} 行之前找不到 `$_guardMarker`';
}

/// ② 的取路径表达式：把 `path: <expr>,` 抽出来并归一化。
/// `'${AppRoutes.chat}/:channelId'` ⇒ `AppRoutes.chat`（**只看外层常量**），
/// 这样"换了一层插值"不会造成假红。
final RegExp _pathLine = RegExp(r'path:\s*(.+?),\s*$');
final RegExp _interp = RegExp(r'\$\{AppRoutes\.([A-Za-z0-9_]+)\}');

String? _pathExpr(String line) {
  final m = _pathLine.firstMatch(line);
  if (m == null) return null;
  final raw = m.group(1)!;
  if (raw.contains('\${AppRoutes.')) {
    return 'AppRoutes.${_interp.firstMatch(raw)!.group(1)!}';
  }
  return raw;
}

void main() {
  test('kDevTools 默认必须是 false（release 档没有临时页面）', () {
    final src = File('lib/src/core/dev/dev_tools.dart').readAsStringSync();
    expect(
      src.contains("bool.fromEnvironment('SYNHUB_DEV_TOOLS')"),
      isTrue,
      reason: '开关必须走编译期常量',
    );
    expect(
      RegExp(r"bool\.fromEnvironment\(\s*'SYNHUB_DEV_TOOLS'\s*,\s*true\s*\)")
          .hasMatch(src),
      isFalse,
      reason: 'defaultValue 必须是 false；写 true 等于把临时页面发出去',
    );
    // 别名必须跟着总开关，不许单独放开。
    expect(src.contains('const bool kDesignPreviewEnabled = kDevTools;'), isTrue);
    expect(src.contains('const bool kDiagnosticsEnabled = kDevTools;'), isTrue);
  });

  test('① 引用面：每一个临时页面入口都必须挂在 `if (kDevTools)` 里', () {
    final found = <String, int>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // 设计稿原型（lib/src/design/generated/）：类名形如 `DesignDiagPage`，
      // 含 `DiagPage` 子串会让本守卫误判；这些页面**只有一条入口**
      // （设置页里的 `Design gallery`，已在 kDevTools 块内）⇒ 由路由面②兜底。
      if (entity.path.startsWith('lib/src/design/')) continue;
      final path = entity.path;
      final lines = entity.readAsLinesSync();
      // 类名在"这两个页面自己的文件"里是定义，不算引用。
      final needles = _devPageFiles.contains(path)
          ? _needles.where((n) => n != 'DesignPreviewPage' && n != 'DiagPage').toList()
          : _needles;
      var hits = 0;
      for (var i = 0; i < lines.length; i++) {
        if (!_hasNeedle(lines[i], needles: needles)) continue;
        hits++;
        final why = unguardedReason(lines, i);
        expect(
          why,
          isNull,
          reason:
              '$path:${i + 1} 是**没有 dev 开关**的临时页面入口 ⇒ '
              'release 包里用户点得到。$why',
        );
      }
      if (hits > 0) found[path] = hits;
    }
    expect(
      found,
      _expectedSites,
      reason:
          '入口清点对不上：新增/删除入口必须同步这张表（并确认新入口也被 kDevTools 守住）',
    );
  });

  test('② 路由注册面：`app_router.dart` 里每一条 `path:` 都要么是已声明的生产路由，要么被守住', () {
    final path = 'lib/src/core/router/app_router.dart';
    final lines = File(path).readAsLinesSync();
    final seen = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final expr = _pathExpr(lines[i]);
      if (expr == null) continue;
      if (_prodPaths.contains(expr)) {
        seen.add(expr);
        continue;
      }
      // 不在生产清单里 ⇒ 必须被 `if (kDevTools)` 守住（临时/新路由都走这条）。
      final why = unguardedReason(lines, i);
      expect(
        why,
        isNull,
        reason:
            '$path:${i + 1} 的 `path: $expr` 既不在 _prodPaths 冻结清单里，'
            '又没有被 `if (kDevTools)` 守住 ⇒ release 包里多了一条可达路由。$why',
      );
      seen.add(expr);
    }
    // 生产路由一条都不能少（删路由同样是大事，必须当轮改这张表）。
    for (final p in _prodPaths) {
      expect(
        seen.where((e) => e == p).length,
        1,
        reason: '生产路由 `$p` 的注册条数不是 1（被删了？还是重复注册？）',
      );
    }
  });

  test('③ 自述面：自述"临时页面/调试页"的文件清单必须与冻结清单一致', () {
    final marked = <String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      if (_devMarkers.any(src.contains)) marked.add(entity.path);
    }
    expect(
      marked,
      _devMarkedFiles,
      reason:
          '有文件新自述成"临时/调试"用途（或旧的自述被删）⇒ 必须同步这张清单，'
          '并确认这个页面的入口全部挂在 kDevTools 上（③ 是给"不走路由的调试页"兜底的）',
    );
  });

  test('检测器本身有效（反向：故意没守的片段必须被判红，受守的必须放行）', () {
    // 反向 ①–③ 只考"引用面"的缩进判据。
    const unguarded = <String>[
      'ListTile(\n  onTap: () => context.push(AppRoutes.diagnostics),\n)',
      'if (kDevTools)\n  a();\ncontext.push(AppRoutes.designPreview);',
      'if (kDevTools) [\n  a(),\n];\ncontext.push(AppRoutes.diagnostics);',
      // ④ **r389 的假绿原形**：类名形态（旧守卫认不出来）
      "GoRoute(\n  path: '/dev-sandbox',\n  builder: (_, __) => const DesignPreviewPage(),\n)",
      // ⑤ 路由名形态
      "if (kDevTools)\n  a();\ncontext.pushNamed(AppRoutes.designPreviewName);",
    ];
    for (final snip in unguarded) {
      final lines = snip.split('\n');
      final idx = lines.indexWhere((l) => _hasNeedle(l));
      expect(idx, isNot(-1), reason: '片段本身没命中 needle，测试写错了：\n$snip');
      expect(
        unguardedReason(lines, idx),
        isNotNull,
        reason: '这段必须被判红，否则守卫是假绿：\n$snip',
      );
    }
    // 受守的片段必须放行（否则守卫会满屏假阳性）。
    const guarded =
        'if (kDevTools)\n  ListTile(\n    onTap: () => context.push(AppRoutes.diagnostics),\n  ),';
    final g = guarded.split('\n');
    expect(unguardedReason(g, g.indexWhere((l) => _hasNeedle(l))), isNull);
  });

  test('路由面检测器本身有效（新 path 必须被守住；冻结清单里的不许被要求守）', () {
    // 新字面量路径、没守卫 ⇒ 红。
    const bad = "  GoRoute(\n    path: '/dev-sandbox',\n    builder: (_, __) => x,\n  ),";
    final b = bad.split('\n');
    final bi = b.indexWhere((l) => _pathExpr(l) != null);
    expect(_pathExpr(b[bi]), "'/dev-sandbox'");
    expect(unguardedReason(b, bi), isNotNull);
    // 同一个新路径放进守卫里 ⇒ 放行。
    const good =
        "  if (kDevTools)\n    GoRoute(\n      path: '/dev-sandbox',\n      builder: (_, __) => x,\n    ),";
    final g = good.split('\n');
    final gi = g.indexWhere((l) => _pathExpr(l) != null);
    expect(unguardedReason(g, gi), isNull);
  });
}
