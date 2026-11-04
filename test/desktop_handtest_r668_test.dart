// r668：用户 macOS 手测报的四条「桌面端】（+ 一条安卓也有）缺陷的守卫。
//
// 这五条的共同点：**都不是"某段代码写错了"，而是"某个平台/某种窗口尺寸下
// 根本没人管"**。所以用例一律判"结构不变量"，不判某句话：
//
//   DA290  五端图标还停在脚手架自带的 Flutter 蓝 F 标（macOS/iOS/Web/Windows）
//   DA291  宽屏文件站右栏钻进子目录后**没有任何回父目录的入口**
//   DA292  工作台卡片写死 2 列 ⇒ 宽窗口里每格 450–780dp，一大半是空白
//   DA293  桌面端点「拍照」没有任何反应（image_picker 桌面无相机实现）
//   DA294  聊天页顶部链路状态每秒抖好几次 ⇒ 整页上下跳
//
// 反向验证（都跑过）：把各自的旧行为恢复 ⇒ 对应用例转红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('DA290 · 五端应用图标必须来自品牌资产，不许留脚手架默认图', () {
    test('macOS 的 app_icon_1024 与 iOS 的 Icon-1024 不再是同一张默认图', () {
      final mac = File(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
      );
      final ios = File(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png',
      );
      expect(mac.existsSync(), isTrue);
      expect(ios.existsSync(), isTrue);
      // 脚手架默认图是 Flutter 的蓝 F（~10–13 KB、无品牌背景）；品牌图是
      // 深蓝六边形网络（≥200 KB）。判字节大小足以区分，且不依赖渲染。
      expect(mac.lengthSync(), greaterThan(200 * 1024),
          reason: 'macOS 图标还像脚手架默认的 Flutter 标（字节过小）');
      expect(ios.lengthSync(), greaterThan(200 * 1024),
          reason: 'iOS 图标还像脚手架默认的 Flutter 标（字节过小）');
    });

    test('图标生成脚本必须覆盖 Android/iOS/macOS/Web/Windows 五端', () {
      final sh = _read('tool/branding/gen_icons.sh');
      // 少一端就是"下次又忘"：这五条路径必须同时出现在脚本里
      for (final needle in const [
        'android/app/src/main/res',
        'ios/Runner/Assets.xcassets/AppIcon.appiconset',
        'macos/Runner/Assets.xcassets/AppIcon.appiconset',
        r'$WEB/icons',
        'windows/runner/resources/app_icon.ico',
      ]) {
        expect(sh.contains(needle), isTrue, reason: 'gen_icons.sh 缺 $needle');
      }
      // Windows 的 ico 必须是多尺寸的（单尺寸在 4K/100% DPI 下会糊）
      expect(File('windows/runner/resources/app_icon.ico').existsSync(), isTrue);
    });

    test('iOS 图标不许带 alpha（App Store 会拒）', () {
      final d = File(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png',
      ).readAsBytesSync();
      // PNG IHDR: ... colorType 在第 25 字节（0-based）；6 = RGBA，2 = RGB
      final colorType = d[25];
      expect(colorType, 2,
          reason: 'iOS 图标是 RGBA（带 alpha）⇒ 应先用 flatten_alpha.py 合成底色');
    });
  });

  group('DA291 · 宽屏右栏必须有「上一级」与可点的路径', () {
    test('右栏 head 带 file-wide-up，且不是只在根目录', () {
      final src = _read('lib/src/features/files/file_wide_pane.dart');
      expect(src.contains("Key('file-wide-up')"), isTrue);
      expect(src.contains("Key('file-wide-crumb-"), isTrue);
      // 父目录由 selection 合成（`isDir: true`），不新增取数路径
      expect(src.contains('parentPath'), isTrue);
    });

    test('窄屏面包屑常驻带字的「上一级」（不再只靠折进 ⋮ 的图标）', () {
      final src = _read('lib/src/features/files/file_browse_page.dart');
      expect(src.contains("Key('file-breadcrumb-up')"), isTrue);
      // 高的点击区：30dp 时代的"点不准"必须被钉住
      final m = RegExp(r'class _Breadcrumb[\s\S]{0,600}?height: (\d+)')
          .firstMatch(src);
      expect(m, isNotNull);
      expect(int.parse(m!.group(1)!), greaterThanOrEqualTo(44));
    });

    test('Drive 右栏的上一级走既有 Drive 栈（popTo），不新造父目录 DTO', () {
      final src = _read('lib/src/features/files/file_browse_page.dart');
      expect(src.contains('popTo('), isTrue);
      expect(src.contains('onUp:'), isTrue);
    });
  });

  group('DA292 · 工作台卡片列数跟窗口宽度走', () {
    test('列数由宽度算出来，不是写死 2', () {
      final src = _read('lib/src/features/shell/app_shell_page.dart');
      expect(src.contains('crossAxisCount: cols'), isTrue,
          reason: '还写死 crossAxisCount: 2 ⇒ 宽窗里一格 450–780dp');
      expect(src.contains('minTileW'), isTrue);
      // 卡片高度必须封顶（否则窄列 + 高上限又会长成一块空地）
      // r670：几何算到 `workspaceTileGeometry()` 里了（纯函数，好按任意宽度验算）
      expect(RegExp(r'clamp\(104\.0 \* textScale, 200\.0 \* textScale\)')
          .hasMatch(src), isTrue,
          reason: '卡片高度必须夹在 104*scale..200*scale');
    });

    test('几何算出来：1600dp 宽窗一格 ≤ 420dp，窄窗仍保 2 列', () {
      // ★ r670：像素只能证明"当前这一档窗口"，宽窗那一档用**纯函数**验算。
      final wide = workspaceTileGeometry(1600, 1.0);
      expect(wide.columns, greaterThanOrEqualTo(4),
          reason: '1600dp 只排到 ${wide.columns} 列 ⇒ 一格会成广场（DA292）');
      expect(wide.tileWidth, lessThanOrEqualTo(420.0));
      expect(wide.tileHeight, lessThanOrEqualTo(200.0),
          reason: '高度必须封顶，宽窗里不许长成一块空地');

      final mid = workspaceTileGeometry(1000, 1.0);
      expect(mid.columns, greaterThanOrEqualTo(3));
      expect(mid.tileWidth, lessThanOrEqualTo(420.0));

      // 窄窗（手机宽度）仍然 2 列，且不溢出
      final narrow = workspaceTileGeometry(360, 1.0);
      expect(narrow.columns, 2);
      expect(narrow.tileWidth * narrow.columns, lessThanOrEqualTo(360));

      // 2.0 字号：高度下限跟着字号走（否则三行文字会被裁）
      final big = workspaceTileGeometry(360, 2.0);
      expect(big.tileHeight, greaterThanOrEqualTo(208.0));
    });

    test('相册三个网格（相册/人物/概念）也必须跟宽度走', () {
      final helper = _read('lib/src/design/responsive_grid.dart');
      expect(helper.contains('int albumColumnsFor(double maxWidth)'), isTrue);
      final photo = _read('lib/src/features/photos/photo_browse_page.dart');
      // 原来 3 处写死 crossAxisCount: 2
      expect(photo.contains('crossAxisCount: 2'), isFalse,
          reason: '相册页还有写死 2 列的网格 ⇒ 宽窗一格 500dp 空地');
      expect(RegExp(r'albumColumnsFor\(').allMatches(photo).length,
          greaterThanOrEqualTo(3));
      final wave2 = _read('lib/src/features/photos/photo_wave2_page.dart');
      expect(wave2.contains('crossAxisCount: 2'), isFalse);
    });
  });

  group('DA293 · 没有相机的平台不许摆「拍照」，且挑图失败要给人话', () {
    test('能力开关按平台判定', () {
      final src = _read('lib/src/core/media/camera_support.dart');
      expect(src.contains('kCameraCaptureSupported'), isTrue);
      expect(src.contains('TargetPlatform.android'), isTrue);
      expect(src.contains('TargetPlatform.iOS'), isTrue);
      // 桌面三端**不许**出现在支持名单里
      for (final p in const ['macOS', 'windows', 'linux']) {
        expect(src.contains('TargetPlatform.$p'), isFalse,
            reason: '桌面端被算成"有相机"⇒ 又会出现点了没反应');
      }
    });

    test('四个拍照入口全部受门控 + 全部有 try/catch', () {
      for (final f in const [
        'lib/src/features/settings/profile_edit_page.dart',
        'lib/src/features/chat/chat_page.dart',
        'lib/src/features/notes/note_editor_page.dart',
        'lib/src/features/drive/drive_scan_page.dart',
      ]) {
        final src = _read(f);
        expect(src.contains('kCameraCaptureSupported'), isTrue,
            reason: '$f 没有按平台门控拍照入口');
      }
      // profile：avatar 挑图必须兜住异常并给 SnackBar
      final prof = _read('lib/src/features/settings/profile_edit_page.dart');
      expect(prof.contains('catch (e)'), isTrue);
      expect(prof.contains('showSnackBar'), isTrue);
    });
  });

  group('DA294 · 聊天页链路状态抖动不得改变布局', () {
    test('相位文案走抖动抑制组件（稳定 700ms 才上屏）', () {
      final src = _read('lib/src/features/chat/channel_list_page.dart');
      expect(src.contains('DebouncedStatusLine('), isTrue);
      final w = _read('lib/src/core/ui/debounced_status_line.dart');
      expect(w.contains('milliseconds: 700'), isTrue);
      // ★ 反面：`late` 惰性初始化会让"新==旧"恒成立 ⇒ 抖动抑制静默失效
      //   （本轮实测踩到：`late _shownPhase = widget.phase`）。判据落在**代码行**
      //   而不是注释：字段声明必须是不带初始化表达式的 `late Object _shownStatus;`，
      //   并在 `initState` 里赋值。
      expect(w.contains('late Object _shownStatus;'), isTrue);
      expect(RegExp(r'^\s*late Object _shownStatus;\s*$', multiLine: true)
          .hasMatch(w), isTrue);
      final init = w.substring(w.indexOf('void initState()'));
      expect(init.contains('_shownStatus = widget.status;'), isTrue);
    });

    test('行为判据：连续抖动不改布局、停手才更新', () {
      final t = _read('test/chat_header_jump_r668_test.dart');
      expect(t.contains('连续抖动 20 次'), isTrue);
      expect(t.contains('停手 700ms 后文案才更新'), isTrue);
    });

    test('遥测带只放稳定事实：相位/socket 状态不许回到 strip', () {
      final src = _read('lib/src/features/chat/channel_list_page.dart');
      final strip = RegExp(r'final strip = <String>\[([\s\S]*?)\];')
          .firstMatch(src)!
          .group(1)!;
      expect(strip.contains('chatChannelCount'), isTrue);
      expect(strip.contains('chatUserCount'), isTrue);
      expect(strip.contains('_statusLine'), isFalse,
          reason: '相位又回到遥测带 ⇒ strip 文本长度随状态变 ⇒ 折行数变 ⇒ 页面跳');
      expect(strip.contains('chatLinkDisconnected'), isFalse);
    });

    test('遥测带与错误槽都是定高（布局不变量）', () {
      final src = _read('lib/src/features/chat/channel_list_page.dart');
      expect(src.contains('_stripLineHeight(context)'), isTrue);
      // 至少两处定高：遥测带 + 错误槽
      final heights =
          RegExp(r'height: _stripLineHeight\(context\)').allMatches(src).length;
      expect(heights, greaterThanOrEqualTo(2));
      // 相位行本身也必须定高（组件在 core/ui，供其它"会抖的状态行"复用）
      final w = _read('lib/src/core/ui/debounced_status_line.dart');
      expect(RegExp(r'return SizedBox\(\s*height: height').hasMatch(w), isTrue);
      expect(w.contains('maxLines: 1'), isTrue);
    });
  });
}
