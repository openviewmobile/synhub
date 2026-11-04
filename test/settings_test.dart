// Phase 9 设置层离线验证：
//   * `SettingsService` 的读写/默认值/落盘往返（key 名沿用原版）
//   * 主题三档真的改到 `MaterialApp.themeMode`
//   * 图片质量预处理（长边 1280 + JPEG 90；原图不动；动图放行）
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:synhub/src/core/media/image_prepare.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/settings/settings_page.dart';
import 'package:synhub/src/features/servers/nas_manager_page.dart';

import 'support/chat_harness.dart';

ChatStore _store() => ChatStore(ChatDatabase(NativeDatabase.memory()));

Uint8List _png(int w, int h) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(10, 200, 30));
  return Uint8List.fromList(img.encodePng(im));
}

void main() {
  group('SettingsService（本地偏好层）', () {
    test('默认值：主题跟随系统、图片标准、缓存 500MB、应用锁关', () async {
      final s = SettingsService(_store());
      expect(await s.themeChoice(), AppThemeChoice.system);
      expect(await s.imageQuality(), ImageQuality.standard);
      expect(await s.cacheLimitBytes(), kDefaultCacheLimitBytes);
      expect(await s.passcodeEnabled(), isFalse);
      expect(await s.fingerprintEnabled(), isFalse);
      expect(await s.passcodeExpiration(), PasscodeExpiration.always);
      expect(await s.passcodeHash(), isNull);
    });

    test('写入后能读回，且 key/取值与原版一致', () async {
      final store = _store();
      final s = SettingsService(store);

      await s.setThemeChoice(AppThemeChoice.dark);
      await s.setImageQuality(ImageQuality.original);
      await s.setCacheLimitBytes(1073741814); // 原版"1 GB"的字面值
      await s.setPasscodeEnabled(true);
      await s.setPasscodeExpiration(PasscodeExpiration.fiveMinutes);
      await s.setPasscodeHash('hash-x', 'salt-y');

      expect(await s.themeChoice(), AppThemeChoice.dark);
      expect(await s.imageQuality(), ImageQuality.original);
      expect(await s.cacheLimitBytes(), 1073741814);
      expect(await s.passcodeEnabled(), isTrue);
      expect(await s.passcodeExpiration(), PasscodeExpiration.fiveMinutes);
      expect(await s.passcodeHash(), 'hash-x');
      expect(await s.passcodeSalt(), 'salt-y');

      // 落盘用的 key 名跟反编译出来的一致
      final all = await store.allSettings();
      expect(all['dark_mode'], '2');
      expect(all['upload_quality'], 'original');
      expect(all['set_cache_limit'], '1073741814');
      expect(all['passcode_enable'], 'true');
      expect(all['passcode_expiration'], 'MIN_5');
    });

    test('clearPasscode 把口令与开关一起清掉', () async {
      final s = SettingsService(_store());
      await s.setPasscodeEnabled(true);
      await s.setFingerprintEnabled(true);
      await s.setPasscodeHash('h', 's');
      await s.clearPasscode();
      expect(await s.passcodeEnabled(), isFalse);
      expect(await s.fingerprintEnabled(), isFalse);
      expect(await s.passcodeHash(), '');
      expect(await s.passcodeSalt(), '');
    });

    test('未知/坏值回落到默认值，不抛异常', () async {
      final store = _store();
      await store.setSetting('dark_mode', 'not-a-number');
      await store.setSetting('upload_quality', 'weird');
      await store.setSetting('passcode_expiration', 'NOPE');
      final s = SettingsService(store);
      expect(await s.themeChoice(), AppThemeChoice.system);
      expect(await s.imageQuality(), ImageQuality.standard);
      expect(await s.passcodeExpiration(), PasscodeExpiration.always);
    });
  });

  group('主题偏好 → MaterialApp.themeMode', () {
    testWidgets('切到深色后 themeMode 变 ThemeMode.dark，并落盘', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: const _ThemeProbe(),
        ),
      );
      await tester.pumpAndSettle();

      MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app().themeMode, ThemeMode.system, reason: '默认跟随系统（-1）');

      await h.container
          .read(themeChoiceProvider.notifier)
          .set(AppThemeChoice.dark);
      await tester.pumpAndSettle();
      expect(app().themeMode, ThemeMode.dark);

      // 真的写进了本地库
      expect(
        await h.container.read(chatStoreProvider).setting('dark_mode'),
        '2',
      );

      await h.container
          .read(themeChoiceProvider.notifier)
          .set(AppThemeChoice.light);
      await tester.pumpAndSettle();
      expect(app().themeMode, ThemeMode.light);
      expect(
        await h.container.read(chatStoreProvider).setting('dark_mode'),
        '1',
      );
    });

    testWidgets('preload() 能在启动后把持久化值读进来', (tester) async {
      final h = await bootChat();
      await h.container.read(chatStoreProvider).setSetting('dark_mode', '2');
      await h.container.read(themeChoiceProvider.notifier).preload();
      expect(h.container.read(themeChoiceProvider), AppThemeChoice.dark);
    });
  });

  group('图片质量预处理', () {
    test('标准：长边缩到 1280，重编码成 JPEG，扩展名改 jpg', () {
      final out = prepareImageUpload(
        bytes: _png(2000, 1000),
        fileName: 'photo.png',
        quality: ImageQuality.standard,
      );
      expect(out.changed, isTrue);
      expect(out.mimeType, 'image/jpeg');
      expect(out.fileName, 'photo.jpg');
      final decoded = img.decodeJpg(out.bytes)!;
      expect(decoded.width, 1280);
      expect(decoded.height, 640, reason: '等比缩放');
    });

    test('标准：小图不放大，但也会重编码成 JPEG', () {
      final out = prepareImageUpload(
        bytes: _png(200, 100),
        fileName: 'small.png',
        quality: ImageQuality.standard,
      );
      expect(out.changed, isTrue);
      final decoded = img.decodeJpg(out.bytes)!;
      expect(decoded.width, 200);
      expect(decoded.height, 100);
    });

    test('原图：一个字节都不动', () {
      final src = _png(2000, 1000);
      final out = prepareImageUpload(
        bytes: src,
        fileName: 'photo.png',
        quality: ImageQuality.original,
      );
      expect(out.changed, isFalse);
      expect(out.bytes, same(src));
      expect(out.fileName, 'photo.png');
      expect(out.mimeType, 'image/png');
    });

    test('非图片原样返回', () {
      final txt = Uint8List.fromList('hello'.codeUnits);
      final out = prepareImageUpload(
        bytes: txt,
        fileName: 'a.txt',
        quality: ImageQuality.standard,
      );
      expect(out.changed, isFalse);
      expect(out.bytes, same(txt));
      expect(out.mimeType, 'application/octet-stream');
    });

    test('扩展名骗人也认得出图（按魔数）', () {
      final out = prepareImageUpload(
        bytes: _png(4000, 2000),
        fileName: 'noext',
        quality: ImageQuality.standard,
      );
      expect(out.changed, isTrue);
      expect(img.decodeJpg(out.bytes)!.width, 1280);
    });
  });

  group('设置页', () {
    testWidgets('渲染出主题/图片质量/缓存/关于，且点主题能改', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('设置'), findsOneWidget);
      expect(find.text('主题'), findsOneWidget);
      // 「外观」区的本地开关（动态取色/性能模式/减少动效）。
      // ★ r494：**「聊天页网格底纹」这一行已删除** —— r492 底纹退役后它就是死功能
      //   （拨了不会有任何像素变化），所以断言改成"它必须**不在**"。
      expect(find.text('动态取色'), findsOneWidget);
      expect(find.text('聊天页网格底纹'), findsNothing);
      // 点开主题 → 选深色（先做，页面还在顶部）
      await tester.tap(find.text('主题'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(h.container.read(themeChoiceProvider), AppThemeChoice.dark);
      expect(find.text('深色'), findsOneWidget, reason: '副标题显示当前档位');

      // 页面变长了（「外观」区多了四个开关），下面的项要滚下去才会构建。
      //
      // 不用 `scrollUntilVisible`：它对"下一步正好跨过目标"的情况不稳
      // （会直接 `Bad state: No element`），手写一个往下滚的循环更可控。
      Future<void> reveal(String label) async {
        final target = find.text(label);
        for (var i = 0; i < 24 && target.evaluate().isEmpty; i++) {
          await tester.drag(find.byType(ListView), const Offset(0, -240));
          await tester.pump(const Duration(milliseconds: 60));
        }
        expect(target, findsOneWidget, reason: label);
      }

      for (final label in const [
        // 严格按页面里的先后顺序滚（只会往下滚）
        '发送图片质量',
        '回车发送',
        '缓存上限',
        '清理已下载的文件',
        '收到消息通知时预加载消息',
        '应用锁',
        '版本',
      ]) {
        await reveal(label);
      }
      await tester.pumpAndSettle();
      expect(find.text(kAppVersion), findsOneWidget);
    });

    // ★ r450：**登录态下够得到「管理 NAS」**。
    //
    // 为什么要有这条：`NasManagerPage` 的唯一生产入口原来在**未登录/断连**的服务器页
    // （`server_setup_page.dart` 的 `NasSwitcherBar`），登录态通往那个页面只有"登出"
    // 一条路 ⇒ 已登录用户拿不到自己的多 NAS 列表。这一行就是那条缺失的接线。
    testWidgets('登录态设置页有「管理 NAS」入口，点它能打开管理页', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      // 「管理 NAS」在「安全」区（页面较长）⇒ 往下滚到它出现
      final entry = find.byKey(const Key('settings-nas-manager'));
      for (var i = 0; i < 24 && entry.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -240));
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(entry, findsOneWidget, reason: '设置页必须有「管理 NAS」这一行');
      // 行比改造前高（设计稿 62 起），"被构建出来"不等于"在视口里"：
      // 给它滚到可见再点，否则 tap 会派发到屏幕外（hit test 直接落空）。
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      expect(find.text('管理 NAS'), findsOneWidget, reason: '标题走 i18n（zh 模板）');
      expect(
        find.text('查看本机保存的 NAS 与账号，切换当前连接'),
        findsOneWidget,
        reason: '副标题要能独立读，且不是内部串',
      );

      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(
        find.byType(NasManagerPage),
        findsOneWidget,
        reason: '点这一行必须真的打开管理页（不是空 onTap）',
      );
      expect(
        find.text('我的 NAS'),
        findsOneWidget,
        reason: '管理页的标题（nasTitle）—— 证明打开的是它，不是别的页',
      );
    });
  });
}

/// 只为了从 widget 树里读 `MaterialApp.themeMode`
class _ThemeProbe extends ConsumerWidget {
  const _ThemeProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      themeMode: ref.watch(themeChoiceProvider).mode,
      home: const Scaffold(body: Text('probe')),
    );
  }
}
