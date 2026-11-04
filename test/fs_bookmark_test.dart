// 第 328 轮：macOS「安全作用域书签」桥的守卫（backlog §3.4）。
//
// 这一组用例要钉住的是**四件互相独立的事**（缺一条就会退化成"文档里说有"）：
//   ① **能力位**：只有 macOS 是 `available`，其余宿主必须如实；
//   ② **entitlement**：两份 entitlements **原文**里真的有
//      `com.apple.security.files.bookmarks.app-scope`（不靠"我记得配了"），
//      且**没有**顺手放进过宽的权限；
//   ③ **通道契约**：Dart 侧发的通道名/方法名与 **Swift 源码逐字一致**
//      （改一处必须改两处；这里读源码原文）；
//   ④ **响应形状**：`{bookmark,path}` / `{path,started,stale}` / `{error}` 三种
//      回包都要能解析，异常与桥缺失一律**保守**（拿不到就是拿不到）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/platform/fs_bookmark.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('synhub/fsbookmark');
  final calls = <MethodCall>[];

  void mockChannel(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(() {
    calls.clear();
    debugForceAppHost = AppHost.macos; // 让能力门放行（真机上本来也是 macOS）
  });
  tearDown(() {
    debugForceAppHost = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('第 328 轮：安全作用域书签', () {
    test('① 能力位只有 macOS 是 available，其余宿主如实', () {
      final mac = staticCapabilitiesFor(AppHost.macos)
          .statusOf(AppCapability.fsBookmark);
      expect(mac.isAvailable, isTrue, reason: 'Swift 桥随 macOS target 编译');

      for (final h in [
        AppHost.android,
        AppHost.ios,
        AppHost.linux,
        AppHost.windows,
      ]) {
        final st = staticCapabilitiesFor(h).statusOf(AppCapability.fsBookmark);
        expect(
          st.isAvailable,
          isFalse,
          reason: '★ $h 上没有这条 Swift 桥 ⇒ 不许报 available（否则会撞通道缺失）',
        );
        expect(
          st.reason,
          CapabilityReason.bridgeMissing,
          reason: 'reason 必须是"桥缺失"（如实），不是"设备不支持"',
        );
      }
      final web = staticCapabilitiesFor(AppHost.web)
          .statusOf(AppCapability.fsBookmark);
      expect(web.isAvailable, isFalse);
      expect(web.reason, CapabilityReason.notSupportedOnHost);
    });

    test('② 两份 entitlements 原文里都有书签权限（且没有过宽权限）', () {
      for (final f in const [
        'macos/Runner/DebugProfile.entitlements',
        'macos/Runner/Release.entitlements',
      ]) {
        final text = File(f).readAsStringSync();
        expect(
          text,
          contains('com.apple.security.files.bookmarks.app-scope'),
          reason: '★ $f 必须真的申请（没有它 create 会直接报错）',
        );
        expect(
          text,
          contains('com.apple.security.app-sandbox'),
          reason: '$f 必须保留沙箱',
        );
        // 反向：不许为了图省事放进过宽权限（r55 的立场，r328 不变）
        for (final too in const [
          'com.apple.security.files.all',
          'com.apple.security.files.downloads.read-write',
          'com.apple.security.temporary-exception.files.absolute-path.read-write',
        ]) {
          expect(
            text,
            isNot(contains(too)),
            reason: '★ $f 里不许出现过宽权限 $too',
          );
        }
      }
    });

    test('③ 通道契约与 Swift 源码逐字一致（改一处必须改两处）', () {
      final swift = File('macos/Runner/FsBookmarkBridge.swift').readAsStringSync();
      expect(
        swift,
        contains('synhub/fsbookmark'),
        reason: '★ Swift 侧的通道名必须与 Dart 侧一字不差',
      );
      for (final m in const ['isSupported', 'create', 'startAccess', 'stopAccess']) {
        expect(
          swift,
          contains('"$m"'),
          reason: '★ Swift 侧必须实现方法 $m（Dart 侧会发这个字面量）',
        );
      }
      // Dart 侧确实用了同一个通道名（防止"只该了 Swift"）
      final dart = File('lib/src/core/platform/fs_bookmark.dart')
          .readAsStringSync();
      expect(dart, contains("MethodChannel('synhub/fsbookmark')"));
      // 桥必须在真 App 里注册过（否则能力位 available 是假的）
      final win = File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();
      expect(
        win,
        contains('FsBookmarkBridge.shared.register'),
        reason: '★ 注册点缺失 = 能力位 available 而通道不存在（假 available）',
      );
    });

    test('④ create：解析 {bookmark,path}；失败回 null（不抛）', () async {
      mockChannel((call) {
        expect(call.method, 'create');
        expect(call.arguments, {'path': '/Users/x/Picked'});
        return {'bookmark': 'Qk9PS01BUks=', 'path': '/Users/x/Picked'};
      });
      final b = MethodChannelFsBookmarkBridge();
      expect(await b.create('/Users/x/Picked'), 'Qk9PS01BUks=');

      // 桥回 `{error}` ⇒ null（没记住，但不影响本次保存）
      mockChannel((_) => {'error': 'Error Domain=NSCocoaErrorDomain Code=256'});
      expect(await b.create('/Users/x/Picked'), isNull);

      // 桥抛异常（通道缺失）⇒ null，绝不冒泡
      mockChannel((_) => throw MissingPluginException('no impl'));
      expect(await b.create('/Users/x/Picked'), isNull);
    });

    test('⑤ startAccess：解析 {path,started,stale}；错误一律保守', () async {
      mockChannel((call) {
        expect(call.method, 'startAccess');
        expect(call.arguments, {'bookmark': 'BM'});
        return {'path': '/Users/x/Picked', 'started': true, 'stale': false};
      });
      final b = MethodChannelFsBookmarkBridge();
      final ok = await b.startAccess('BM');
      expect(ok.ok, isTrue);
      expect(ok.path, '/Users/x/Picked');
      expect(ok.started, isTrue);
      expect(ok.stale, isFalse);

      // 过期但可用：路径照样给出来（调用方照用）
      mockChannel(
        (_) => {'path': '/Users/x/Picked', 'started': false, 'stale': true},
      );
      final stale = await b.startAccess('BM');
      expect(stale.ok, isTrue);
      expect(stale.stale, isTrue);
      expect(
        stale.started,
        isFalse,
        reason: '★ started=false 不代表不能用（同路径已开过时系统就这么回）',
      );

      mockChannel((_) => {'error': 'bookmark is not base64'});
      final bad = await b.startAccess('x');
      expect(bad.ok, isFalse);
      expect(bad.reason, contains('resolve-failed'));

      mockChannel((_) => throw PlatformException(code: 'x'));
      final boom = await b.startAccess('x');
      expect(boom.ok, isFalse);
      expect(boom.reason, contains('exception'));

      // stopAccess 静默：桥不在也不许抛
      mockChannel((_) => throw MissingPluginException('no impl'));
      await b.stopAccess('BM');
    });

    test('⑥ 能力门不放行时（Android）一次通道都不打', () async {
      debugForceAppHost = AppHost.android;
      var hits = 0;
      mockChannel((_) {
        hits++;
        return null;
      });
      final b = MethodChannelFsBookmarkBridge();
      expect(await b.isSupported(), isFalse);
      expect(await b.create('/tmp/x'), isNull);
      final acc = await b.startAccess('BM');
      expect(acc.ok, isFalse);
      expect(acc.reason, 'bridge-unavailable');
      await b.stopAccess('BM');
      expect(hits, 0, reason: '★ 门控必须在**发通道之前**生效（§2.0.45 的同族）');
    });

    test('⑦ 文件存储：真落盘往返 + 坏数据当没存过（★ 真文件系统）', () async {
      final tmp = Directory.systemTemp.createTempSync('r328_recent');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final dirs = (
        support: () async => tmp,
        documents: () async => tmp,
        cache: () async => tmp,
        temp: () async => tmp,
        external: () async => tmp,
      );
      final store = FileRecentSaveDirectoryStore(dirs: dirs);

      // ① 没写过 ⇒ null
      expect(await store.read(), isNull);

      // ② 往返：书签串含 `+` `/` `=`（base64）、路径里有空格与非 ASCII
      const v = RecentSaveDirectory(
        path: '/Users/x/带 空格/Picked',
        bookmark: 'Qk9P/K1BUks=+8=',
      );
      await store.write(v);
      final f = File(
        '${tmp.path}/${FileRecentSaveDirectoryStore.dirName}/'
        '${FileRecentSaveDirectoryStore.fileName}',
      );
      expect(f.existsSync(), isTrue, reason: '★ 必须**真**落盘（读不到就是没验）');
      final back = await store.read();
      expect(back?.path, v.path);
      expect(back?.bookmark, v.bookmark);

      // ③ 坏数据一律当"没存过"
      for (final bad in const ['', 'no-newline', '\n/path', 'BM\n']) {
        f.writeAsStringSync(bad);
        expect(
          await store.read(),
          isNull,
          reason: '★ 坏数据（${bad.replaceAll('\n', r'\n')}）必须回落"没存过"',
        );
      }
      // 纯函数也单独钉一遍（它们是编码契约本身）
      expect(decodeRecentSaveDirectory('BM\n/p'), isNotNull);
      expect(encodeRecentSaveDirectory(v), 'Qk9P/K1BUks=+8=\n${v.path}');

      // ④ clear 之后文件真的没了
      f.writeAsStringSync('BM\n/p');
      await store.clear();
      expect(f.existsSync(), isFalse, reason: 'clear 要真删文件');
      expect(await store.read(), isNull);
    });
  });
}
