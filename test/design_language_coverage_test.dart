// **r489** · 设计语言覆盖率闸门（`DA130`）—— 三档判据；**r490** 起棘轮基线随清扫下调（`DA131`）；
// **r491** 全站收口（`DA132`）：`HudTokens` 只剩设计样张那一页
// `DA133`：`ListTile(` 也清零（基线 0），行卡全部走 `DesignRowTile`
//
// 这一轮把最后 12 个页面从 `HudScaffold` 迁移到 `DesignScaffold` 之后，
// **功能目录里 `HudScaffold(` 的数量第一次归零**。但"骨架换了"不等于"整页换了"：
// 还有 100 多个文件在用裸 `ListTile(`、HUD 令牌和网格背景。
//
// 所以这里写成**三档**，每档都能红：
//   ① 硬零：`HudScaffold(` 必须为 0（一次改完了，谁再写就红）；
//   ② 棘轮：`HudTokens` / `field_backdrop` / 裸 `ListTile(` / `CheckboxListTile(` /
//      `SwitchListTile(` 的**文件数不许变多**。每轮迁移完，把这里的数**往下调**；
//      数字被调大 = 明着退步，会被人看见。
//   ③ 下界：`DesignScaffold` / `DesignRowTile` / `DesignSwitchRow` / `DesignCheckRow`
//      的实际用量不许低于当前值（防止"删了页面"冒充"改好了"）。
//
// 判据读的是**真实文件**，不是手抄名单；新增页面若照抄旧写法，① 或 ② 立刻红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 棘轮基线（r491）。**只许往下调**：每迁完一批就把数字改小。
///
/// `HudTokens` 从 r489 的 133 一路降到 **1** —— 只剩 `design_preview_page.dart`，
/// 那一页是**故意**展示 HUD 组件的设计样张（它的存在就是为了看旧语言长什么样），
/// 所以留着它、并用下面的白名单把"唯一允许"钉死。
const _baseline = <String, int>{
  'HudTokens': 1,
  // ★ r517：`field_backdrop.dart` 在 features 里已经是 0 个引用（r492 起只有
  // HudScaffold 自己裹一层），基线从 41 收到 **0** —— 再出现就是有人在页面里
  // 私自裹了全屏底纹。
  'field_backdrop.dart': 0,
  'ListTile(': 0,
  // ★ r513（DA156）：15 处换成设计组件 `DesignCheckRow`，只剩遗留预览页 1 处。
  'CheckboxListTile(': 1,
  // ★ r512（DA155）：37 处换成设计组件 `DesignSwitchRow`，只剩遗留预览页 1 处。
  'SwitchListTile(': 1,
};

/// 下界（r489 实测值）。
const _floors = <String, int>{
  // 下界一律钉在"当前实测值"，掉了就红 —— 这是防止"悄悄换回旧组件"的唯一手段。
  'DesignScaffold(': 46,
  'DesignRowTile(': 386, // r517 实测 386 处 / 126 个文件
  'DesignSwitchRow(': 52, // r512 换皮后实测 52 处 / 29 个文件
  'DesignCheckRow(': 20, // r513 换皮后实测 20 处 / 17 个文件
};

int _countFiles(List<File> files, String needle) => files
    .where((f) => f.readAsStringSync().contains(needle))
    .length;

int _countOccurrences(List<File> files, String needle) => files
    .map((f) => needle.allMatches(f.readAsStringSync()).length)
    .fold(0, (a, b) => a + b);

void main() {
  final files = Directory('lib/src/features')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  group('DA130 · 设计语言覆盖率（硬零 / 棘轮 / 下界）', () {
    test('DA130：扫描规模合理（防止路径写错导致空扫）', () {
      expect(files.length, greaterThan(200), reason: 'features 下的 dart 文件数异常');
    });

    test('DA130①：功能目录里 `HudScaffold(` 必须为 0', () {
      final offenders = files
          .where((f) => f.readAsStringSync().contains('HudScaffold('))
          .map((f) => f.path)
          .toList();
      expect(offenders, isEmpty, reason: '这些页面还在用 HudScaffold：\n${offenders.join('\n')}');
    });

    // `DA131`（r490）：`HudTokens` 文件 133 → 107，基线同步下调；这条用例就是它的守卫。
    test('DA130②：旧形态文件数不许变多（棘轮）', () {
      final grown = <String>[];
      for (final e in _baseline.entries) {
        final actual = e.key == 'ListTile('
            ? files.where((f) => RegExp(r'(?<![A-Za-z_])ListTile\(').hasMatch(f.readAsStringSync())).length
            : _countFiles(files, e.key);
        if (actual > e.value) {
          grown.add('${e.key}: $actual > 基线 ${e.value}');
        }
      }
      expect(
        grown,
        isEmpty,
        reason: '这些旧形态变多了（要么是回退，要么该更新基线并说明原因）：\n${grown.join('\n')}',
      );
    });

    test('DA148：控件家族（开关/复选/单选/滑杆/分段/提示）必须走设计令牌', () {
      final theme = File('lib/src/core/theme/app_theme.dart').readAsStringSync();
      for (final key in const [
        'switchTheme:',
        'checkboxTheme:',
        'radioTheme:',
        'sliderTheme:',
        'segmentedButtonTheme:',
        'tooltipTheme:',
      ]) {
        expect(theme.contains(key), isTrue, reason: 'DA148：缺 $key');
      }
      // 颜色必须取设计令牌（dp.*），不许直接用 Material 的 scheme.*
      final seg = theme.substring(theme.indexOf('switchTheme:'));
      expect(seg.contains('dp.primary'), isTrue);
      expect(seg.contains('dp.line'), isTrue);
    });

    test('DA151+DA152：品牌行不许全大写；设置页不许把遥测码当用户文案', () {
      final en = File('lib/l10n/app_en.arb').readAsStringSync();
      final zh = File('lib/l10n/app_zh.arb').readAsStringSync();
      // 全大写品牌码（`SYNOLOGY DRIVE · …`）是上一版 HUD 的写法
      expect(en.contains('SYNOLOGY'), isFalse, reason: 'DA151：en ARB 里还有全大写品牌码');
      expect(zh.contains('SYNOLOGY'), isFalse, reason: 'DA151：zh ARB 里还有全大写品牌码');
      // 设置页那条 `SVC ON · CONN <id> · SOCKET …` 是诊断串，不许当文案
      final page = File(
        'lib/src/features/settings/notification_settings_page.dart',
      ).readAsStringSync();
      final code = page
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      for (final token in const ["'SVC ", "'SOCKET ", "'CONN "]) {
        expect(code.contains(token), isFalse,
            reason: 'DA152：遥测码 $token 又回到用户可见文案里了');
      }
    });

    test('DA150：全仓 features 里不许再有"遥测代号"字距 1.2', () {
      final dir = Directory('lib/src/features');
      final offenders = <String>[];
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final code = f
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        if (code.contains('letterSpacing: 1.2')) offenders.add(f.path);
      }
      expect(offenders, isEmpty,
          reason: 'DA150：副标题/分区标签一律用安静次级文字；'
              '全大写 + 1.2 字距是上一版 HUD 的仪表标签写法（r506 只清了日历一处，'
              'r507 把剩下 12 处一起清掉）');
    });

    test('DA149：日历页头副标题不许用"加字距的遥测代号"写法', () {
      final src =
          File('lib/src/features/calendar/calendar_page.dart').readAsStringSync();
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('letterSpacing: 1.2'), isFalse,
          reason: 'DA149：全大写 + 加字距是上一版 HUD 的仪表标签写法；'
              '副标题是安静次级文字，字号/行高不动、只去掉字距');
    });

    test('DA147：弹层菜单（PopupMenuButton）必须走设计令牌', () {
      final theme = File('lib/src/core/theme/app_theme.dart').readAsStringSync();
      expect(theme.contains('popupMenuTheme: PopupMenuThemeData('), isTrue,
          reason: 'DA147：不设 popupMenuTheme ⇒ Material 默认灰紫底 + 4px 圆角，'
              '亮色下真机像素是 (239,240,244)，与白卡设计语言不是一套');
      final seg = theme.substring(theme.indexOf('popupMenuTheme: PopupMenuThemeData('));
      expect(seg.contains('color: dp.surface'), isTrue);
      expect(seg.contains('BorderSide(color: dp.line)'), isTrue);
      expect(seg.contains('BorderRadius.circular(14)'), isTrue);
    });

    test('DA146：系统消息胶囊在亮色下必须有可见的底', () {
      final hud = File('lib/src/core/ui/hud_widgets.dart').readAsStringSync();
      // 反模式：胶囊底取 `surface2`。亮色下 surface2(#E8EEF6) 与聊天底色
      // (#F2F5F9) 只差几阶 —— 真机像素取样两者都是 (241,245,250)。
      expect(hud.contains('.surface2,'), isFalse,
          reason: 'DA146：胶囊底要用 surface（亮=白/暗=#1A1F27），'
              'surface2 在亮色下与页面底几乎同色');
      expect(hud.contains('.surface,'), isTrue);
    });

    test('DA145：离线清单同步 SAF 的每一跳都要先问 ref.mounted', () {
      final src =
          File('lib/src/features/files/file_offline_pin.dart').readAsStringSync();
      final body = src.substring(src.indexOf('Future<void> _syncSaf('));
      final end = body.indexOf('/// 更新某条已登记项的本地副本路径');
      final seg = end > 0 ? body.substring(0, end) : body;
      // 三个"之后还要用 ref"的位置：入口、第一次落盘后、合并落盘前
      expect('if (!ref.mounted) return;'.allMatches(seg).length >= 3, isTrue,
          reason: 'DA145：provider 可能在"登记→落盘→同步索引"链上被销毁；'
              '每个 await 之后用 ref 之前都要先判 mounted');
    });

    test('DA144：聊天家族的"日期分隔/状态/附件元信息"也要落在设计语言上', () {
      final chat = File('lib/src/features/chat/chat_page.dart').readAsStringSync();
      final att =
          File('lib/src/features/chat/attachment_view.dart').readAsStringSync();
      final list =
          File('lib/src/features/chat/channel_list_page.dart').readAsStringSync();
      String code(String src) => src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code(chat).contains('TelemetryLabel('), isFalse,
          reason: '日期分隔/最新消息分隔不许再用等宽遥测字');
      expect(code(chat).contains('AppType.telemetry('), isFalse);
      expect(code(att).contains('AppType.telemetry('), isFalse,
          reason: '附件元信息（大小/类型/时长）统一走 DesignType');
      expect(code(list).contains('TelemetryLabel('), isFalse,
          reason: '分组状态标签不许再用等宽遥测字');
    });

    test('DA143：聊天元信息与系统消息落在设计语言上', () {
      final chat = File('lib/src/features/chat/chat_page.dart').readAsStringSync();
      final hud = File('lib/src/core/ui/hud_widgets.dart').readAsStringSync();
      expect(chat.contains('AppType.telemetry('), isFalse,
          reason: '消息时间戳/元信息不许再用等宽遥测字（r501 已统一到 DesignType）');
      expect(chat.contains('DesignType.labelSmallSize'), isTrue);
      expect(hud.contains('ChamferBorder('), isFalse,
          reason: 'HudChip（系统消息）不许回到切角造型；系统消息是提示，用胶囊');
    });

    test('DA142：聊天列表页头不许把 conn_id 当用户文案', () {
      final page =
          File('lib/src/features/chat/channel_list_page.dart').readAsStringSync();
      final code = page
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('chatStatusConnSuffix(sync.connId'), isFalse,
          reason: 'conn_id 是诊断串（形如 bD2WEjbkkksq4Mg5Bvnm），'
              '拼在页头会让链路行折行、并把连接标识暴露到界面上');
    });

    test('DA141：相册缩略图的圆角必须套在 AspectRatio **里面**', () {
      final w =
          File('lib/src/features/photos/photo_widgets.dart').readAsStringSync();
      // 反模式：`ClipRRect(child: AspectImage(...))` —— 裁剪框拿到整格尺寸，
      // 竖图比格子窄 ⇒ 图片自己的角根本没被裁（r499 第一次就这么错的，像素已证）。
      final bad = RegExp(
        r'ClipRRect\(\s*borderRadius: BorderRadius\.circular\(Radii\.cut\),\s*child: AspectImage\(',
      );
      expect(bad.hasMatch(w), isFalse,
          reason: '圆角必须写在 AspectImage 的 child 里（AspectRatio 内层），'
              '否则窄图/竖图的角不会被裁');
    });

    test('DA140：外壳的卡片必须用设计令牌的 surface + line 描边', () {
      final shell =
          File('lib/src/features/shell/app_shell_page.dart').readAsStringSync();
      final code = shell
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      // `surfaceContainerHigh @0.4` 在亮色下 ≈ 底色 ⇒ 卡片"看不见"（r498 真机像素）
      expect(code.contains('surfaceContainerHigh'), isFalse,
          reason: '外壳卡片/搜索框必须用设计令牌的 surface；'
              'containerHigh@0.4 在亮色下与底色几乎同值');
      expect(code.contains('DesignPalette.of(context).line'), isTrue,
          reason: '卡片必须带 1px line 描边（亮色下白卡靠描边与底色分开）');
    });

    test('DA139：外壳页头（Drive/Workspace/Me）不许带遥测代号，且左对齐', () {
      final shell =
          File('lib/src/features/shell/app_shell_page.dart').readAsStringSync();
      final code = shell
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      // 只看 `_TabTitle` 这一个类：`Me` 页把 NAS 地址也放在页头附近，
      // 那个是**信息**（r497 已改设计令牌），不在本判据范围里。
      final tabTitle = code.substring(code.indexOf('class _TabTitle'));
      final tabTitleBody = tabTitle.substring(0, tabTitle.indexOf('\nclass '));
      expect(tabTitleBody.contains('TelemetryLabel'), isFalse,
          reason: '页头右侧的 DRIVE/WORKSPACE/PROFILE 是 HUD 装饰，已删；不许回退');
      // 页头必须撑满宽度（Column 默认 center 会让标题居中）
      expect(code.contains('width: double.infinity'), isTrue,
          reason: '_TabTitle 必须撑满宽度，否则标题会被 Column 居中');

      // 相册 FAB 必须用主色（与 Files 的 + 同一套）
      final photos =
          File('lib/src/features/photos/photo_browse_page.dart').readAsStringSync();
      expect(photos.contains('foregroundColor: hud.onPrimary'), isTrue);
    });

    test('DA138：相册家族页头去 HUD 遥测字', () {
      final browse =
          File('lib/src/features/photos/photo_browse_page.dart').readAsStringSync();
      final c2 = File('lib/src/features/photos/photo_c2_page.dart').readAsStringSync();
      // 只看代码（注释里会提到旧写法，不能把注释当实现）
      final String code = browse
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('SYNOLOGY PHOTOS'), isFalse,
          reason: '全大写产品名是 HUD 遥测字；页头副标题应为普通大小写的产品名');
      for (final pair in <(String, String)>[
        ('photo_browse_page', browse),
        ('photo_c2_page', c2),
      ]) {
        // 副标题不许再有"遥测字距"（letterSpacing ≥ 1.0）
        final bad = RegExp(r'letterSpacing:\s*(1\.\d|[2-9])')
            .allMatches(pair.$2)
            .map((m) => m.group(0))
            .toList();
        expect(bad, isEmpty,
            reason: '${pair.$1} 的页头副标题不许再用 HUD 字距：$bad');
      }
    });

    test('DA137：`FieldBackdrop` 只剩 HudScaffold 一个调用点', () {
      final hits = <String>[];
      for (final f in Directory('lib/src')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final s = f.readAsStringSync();
        if (f.path.endsWith('field_backdrop.dart')) continue;
        if (s.contains('FieldBackdrop(')) hits.add(f.path);
      }
      expect(hits, isEmpty,
          reason: 'r495 已把 52 处调用点拆掉（组件只剩"底色 + Material"）；'
              '再包一层就是纯噪音。历史理由见 docs/evidence-r495/README.md');

      // HudScaffold 必须自己铺底：拆掉外层之后它曾经露黑底（测试量到 L=0.000）
      final backdrop = File('lib/src/core/ui/field_backdrop.dart').readAsStringSync();
      expect(backdrop.contains('body: FieldBackdrop('), isTrue,
          reason: 'HudScaffold 的 body 必须自己裹 FieldBackdrop，否则透明 Scaffold 露黑底');
    });

    test('DA136：底纹退役后的"死控件"不许留在设置页', () {
      final settings =
          File('lib/src/features/settings/settings_page.dart').readAsStringSync();
      expect(settings.contains('EffectKind.chatGrid'), isFalse,
          reason: '底纹已退役；设置页再出现这个开关就是死功能（拨了没有像素变化）');
      // 档位摘要里的"网格 bottom"一项也必须删掉（否则等于在界面上撒谎）
      final en = File('lib/l10n/app_en.arb').readAsStringSync();
      final zh = File('lib/l10n/app_zh.arb').readAsStringSync();
      for (final pair in <(String, String)>[('en', en), ('zh', zh)]) {
        expect(pair.$2.contains('grid {grid}'), isFalse,
            reason: '${pair.$1} 的档位摘要不许再提网格底纹');
        expect(pair.$2.contains('网格底纹{grid}'), isFalse);
      }
    });

    test('DA135：聊天家族必须落在设计语言上（行卡/页头/组头/AppBar）', () {
      final row = File('lib/src/features/chat/channel_row.dart').readAsStringSync();
      expect(row.contains('DesignRowShell('), isTrue,
          reason: '聊天行必须与设计行卡同一套几何');
      expect(row.contains('_EnergyBar'), isFalse,
          reason: '未读能量条是 HUD 装饰，未读态由 selected 承载');

      final list =
          File('lib/src/features/chat/channel_list_page.dart').readAsStringSync();
      expect(list.contains('TechFrame('), isFalse,
          reason: '频道列表页头不许再套座舱面板');
      expect(list.contains('DesignSectionHeader('), isTrue,
          reason: '组头必须是设计组件');

      final theme = File('lib/src/core/theme/app_theme.dart').readAsStringSync();
      // 只看**代码行**（注释里会提到旧类名，不能把注释当实现）
      final code = theme
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('HudBarBorder('), isFalse,
          reason: '全 App 的 AppBar 刻度已退役；恢复前先改这条判据与文档');
    });

    test('DA134：科幻底纹退役不可悄悄回退（底纹层只剩底色）', () {
      final f = File('lib/src/core/ui/field_backdrop.dart').readAsStringSync();
      expect(f.contains('CustomPaint'), isFalse,
          reason: 'FieldBackdrop 只允许"底色 + Material"；出现 CustomPaint = 网格/星尘回来了');
      expect(f.contains('_FieldPainter') || f.contains('_ScanlinePainter'),
          isFalse);
      // 组件名与参数必须保留：74 处调用点还在用
      expect(f.contains('class FieldBackdrop'), isTrue);
      expect(f.contains('class HudScaffold'), isTrue,
          reason: 'HudScaffold 与本组件同文件；删底纹时**不许**连它一起删（r492 踩过）');
    });

    test('DA134：文件行必须套 `DesignRowShell`，且不许重复画体积', () {
      final f = File('lib/src/features/files/file_row.dart').readAsStringSync();
      expect(f.contains('DesignRowShell('), isTrue,
          reason: '自定义行必须与设计行卡同一套几何（外 16/5、圆角 13、内 16/20）');
      // 反例守卫：行尾再画一遍体积 ⇒ 窄屏溢出（r492 实测 17–41px）
      final rowClass = f.substring(f.indexOf('class FileRow'));
      expect(
        RegExp(r'entry\.humanSize').allMatches(rowClass).length,
        lessThanOrEqualTo(2),
        reason: 'FileRow 里体积只允许出现在 `_subtitle`（1 处判定 + 1 处拼接）；'
            '行尾再来一份就是窄屏溢出的来源',
      );
    });

    test('DA131：`HudTokens` 只剩设计样张那一页（白名单精确匹配）', () {
      final offenders = files
          .where((f) => f.readAsStringSync().contains('HudTokens'))
          .map((f) => f.path.replaceAll(r'\\', '/'))
          .toSet();
      expect(
        offenders,
        <String>{'lib/src/features/design/design_preview_page.dart'},
        reason: 'HUD 令牌只允许留在设计样张页；其它页面出现就是回退',
      );
    });

    test('DA130③：设计组件用量不低于下界', () {
      final shrunk = <String>[];
      for (final e in _floors.entries) {
        final actual = _countOccurrences(files, e.key);
        if (actual < e.value) {
          shrunk.add('${e.key}: $actual < 下界 ${e.value}');
        }
      }
      expect(
        shrunk,
        isEmpty,
        reason: '设计组件用量掉下来了（是不是删了页面/换回了旧组件？）：\n${shrunk.join('\n')}',
      );
    });

    test('DA130② 反向验证：把基线调小 1，这条闸门立刻会红', () {
      // 构造一个"比基线少一个文件"的假想：用真实计数证明判据不是恒真。
      final actual = _countFiles(files, 'HudTokens');
      expect(actual, lessThanOrEqualTo(_baseline['HudTokens']!));
      // 若把基线写成 actual-1，上面的判据就会报 actual > baseline。
      expect(actual > actual - 1, isTrue, reason: '判据的比较方向必须是"多了才红"');
    });
  });
}
