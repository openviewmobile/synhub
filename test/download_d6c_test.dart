// ⑥下载 **D-6c**：F10 内置链接浏览器（判定逻辑）+ F12 **系统通知栏**推送。
//
// F12 的历史：`download_completion.dart` 早就实现了完成/失败**差分与事件流**，
// 但当时明确登记"原生侧没有通用本地通知方法"这一能力边界。本轮补上
// `DownloadNotifications.kt`（通道 `synhub/download_notifications`），
// 所以这里断言的重点是：**新事件会推到系统通知**，而"首次基线/开关关闭/
// 系统未授权"三种情况**不推**。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/downloads/download_completion.dart';
import 'package:synhub/src/features/downloads/download_link_browser.dart';
import 'package:synhub/src/features/downloads/download_notification_sink.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';

import 'download_gaps_g3_test.dart' show boot, taskJson;

class _FakeSink implements DownloadNotificationSink {
  _FakeSink({this.allowed = true});

  final bool allowed;
  final List<({int id, String title, String text})> shown = [];

  @override
  Future<bool> available() async => allowed;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String text,
  }) async {
    shown.add((id: id, title: title, text: text));
  }
}

ProviderContainer _container(
  dynamic api, {
  required DownloadNotificationSink sink,
}) => ProviderContainer(
  overrides: [
    downloadApiProvider.overrideWithValue(api),
    downloadNotificationSinkProvider.overrideWithValue(sink),
  ],
);

void main() {
  group('F10：链接判定是**纯函数**（WebView 本体只能真机取证）', () {
    test('magnet / ed2k / .torrent / .nzb 命中，且大小写不敏感', () {
      expect(
        classifyDownloadLink('magnet:?xt=urn:btih:ABC'),
        DownloadLinkKind.magnet,
      );
      expect(
        classifyDownloadLink('  MAGNET:?xt=urn:btih:abc  '),
        DownloadLinkKind.magnet,
      );
      expect(
        classifyDownloadLink('ed2k://|file|a.iso|1|H|/'),
        DownloadLinkKind.ed2k,
      );
      expect(
        classifyDownloadLink('https://e.com/a/b.torrent'),
        DownloadLinkKind.torrent,
      );
      expect(
        classifyDownloadLink('https://e.com/a/b.NZB'),
        DownloadLinkKind.nzb,
      );
    });

    test('query/hash 不影响后缀判定', () {
      expect(
        classifyDownloadLink('https://e.com/x.torrent?token=1#frag'),
        DownloadLinkKind.torrent,
      );
      expect(
        classifyDownloadLink('https://e.com/x.nzb?u=2'),
        DownloadLinkKind.nzb,
      );
    });

    test('普通网页 / 空串 / 非下载后缀 → null（= 正常导航）', () {
      expect(classifyDownloadLink('https://example.com/page'), isNull);
      expect(classifyDownloadLink(''), isNull);
      expect(classifyDownloadLink('   '), isNull);
      expect(classifyDownloadLink('https://e.com/a.iso'), isNull);
      expect(
        classifyDownloadLink('https://e.com/torrent/x'),
        isNull,
        reason: '路径里带 torrent 但不是 .torrent 后缀',
      );
    });
  });

  // ★★ DA60 第二形态（r408 真机）：输入框里**贴**下载链接时，
  //   以前无条件 `loadRequest` ⇒ WebView 报 `net::ERR_UNKNOWN_URL_SCHEME`，
  //   用户拿不到"添加到下载"。现在两条路（点进去 / 贴进去）走同一个判据。
  group('DA60b：输入框「打开」的去向是纯函数', () {
    test('贴 ed2k / magnet / .torrent / .nzb ⇒ 交给"添加到下载"（不导航）', () {
      expect(
        planBrowserGo(
          'ed2k://|file|synhub-r408-smoke.bin|1048576|0123456789abcdef|/',
        ).addKind,
        DownloadLinkKind.ed2k,
      );
      expect(
        planBrowserGo('magnet:?xt=urn:btih:ABC').addKind,
        DownloadLinkKind.magnet,
      );
      expect(
        planBrowserGo('https://e.com/a.torrent').addKind,
        DownloadLinkKind.torrent,
      );
      expect(planBrowserGo('https://e.com/a.nzb').addKind, DownloadLinkKind.nzb);
    });

    test('交给"添加到下载"时链接**逐字**保留（不编码、不截断）', () {
      const link =
          'ed2k://|file|a b.bin|1048576|0123456789abcdef0123456789abcdef|/';
      expect(planBrowserGo('  $link  ').uri, link);
    });

    test('普通网址 ⇒ 正常导航；缺 scheme 时补 https://', () {
      final p1 = planBrowserGo('https://example.com/page');
      expect(p1.addKind, isNull);
      expect(p1.uri, 'https://example.com/page');
      final p2 = planBrowserGo('example.com/x');
      expect(p2.addKind, isNull);
      expect(p2.uri, 'https://example.com/x');
      // 其它 scheme 不许被改写
      final p3 = planBrowserGo('ftp://nas.local/a.iso');
      expect(p3.addKind, isNull);
      expect(p3.uri, 'ftp://nas.local/a.iso');
    });
  });

  // ★★ DA62（r409）：内置浏览器页的系统返回键。
  //   真机三组实验（台账 §S2）：WebView **加载过任何一页**之后，`keyevent 4`
  //   就到不了 Flutter（焦点在谁身上都一样）；没加载网页时是正常的。
  //   ⇒ 修复在视图树之上（Kotlin `BrowserBackBridge`），Dart 只负责"收键盘/回历史/退页"。
  group('DA62：系统返回键的三选一（纯函数 + 执行器）', () {
    test('键盘开着 ⇒ 先收键盘（安卓惯例，不管有没有历史）', () {
      expect(
        planBrowserBack(keyboardVisible: true, canGoBack: true),
        BrowserBackAction.dismissKeyboard,
      );
      expect(
        planBrowserBack(keyboardVisible: true, canGoBack: false),
        BrowserBackAction.dismissKeyboard,
      );
    });

    test('键盘关着 + 有历史 ⇒ 回上一页（浏览器语义）', () {
      expect(
        planBrowserBack(keyboardVisible: false, canGoBack: true),
        BrowserBackAction.goBack,
      );
    });

    test('键盘关着 + 没历史 ⇒ 退页（与工具栏 Back 一致）', () {
      expect(
        planBrowserBack(keyboardVisible: false, canGoBack: false),
        BrowserBackAction.popPage,
      );
    });

    test('执行器：三条腿各只走一条（另外两条不许被顺带调到）', () async {
      Future<({int kb, int back, int pop})> run({
        required bool keyboard,
        required bool canBack,
      }) async {
        var kb = 0, back = 0, pop = 0;
        final d = BrowserBackDispatcher(
          keyboardVisible: () => keyboard,
          canGoBack: () async => canBack,
          goBack: () async => back++,
          popPage: () async => pop++,
          dismissKeyboard: () => kb++,
        );
        final action = await d.handle();
        expect(action, planBrowserBack(keyboardVisible: keyboard, canGoBack: canBack));
        return (kb: kb, back: back, pop: pop);
      }

      expect(await run(keyboard: true, canBack: true), (kb: 1, back: 0, pop: 0));
      expect(await run(keyboard: false, canBack: true), (kb: 0, back: 1, pop: 0));
      expect(await run(keyboard: false, canBack: false), (kb: 0, back: 0, pop: 1));
    });

    test('执行器：不回历史时**不许**白问一次"能不能回"', () async {
      var asked = 0;
      final d = BrowserBackDispatcher(
        keyboardVisible: () => true, // 键盘开着 ⇒ 直接收键盘
        canGoBack: () async {
          asked++;
          return true;
        },
        goBack: () async {},
        popPage: () async {},
        dismissKeyboard: () {},
      );
      await d.handle();
      expect(asked, 0, reason: '先收键盘是**同步可判**的，不该为它去 await WebView');
    });

    test('通道名两侧对读：Dart 常量 == Kotlin 里的字符串（改名会让守卫红）', () {
      final kt = File(
        'android/app/src/main/kotlin/com/openviewai/synhub/BrowserBackBridge.kt',
      ).readAsStringSync();
      expect(kt.contains('"$kBrowserBackChannelName"'), isTrue);
      // 两个方法名也必须两侧一致（Dart 发 setActive / Kotlin 回 onBack）
      expect(kt.contains('"setActive"'), isTrue);
      final dart = File(
        'lib/src/features/downloads/download_link_browser.dart',
      ).readAsStringSync();
      expect(dart.contains("invokeMethod<void>('setActive'"), isTrue);
      expect(kt.contains('invokeMethod("onBack"'), isTrue);
      expect(dart.contains("call.method != 'onBack'"), isTrue);
    });

    test('作用域边界：进入/离开本页要**成对**发 setActive(true/false)', () {
      final dart = File(
        'lib/src/features/downloads/download_link_browser.dart',
      ).readAsStringSync();
      expect(dart.contains("invokeMethod<void>('setActive', true)"), isTrue);
      expect(dart.contains("invokeMethod<void>('setActive', false)"), isTrue);
      // 撤防必须在 dispose 里（不许只在 initState 里"开了就不关"）
      expect(dart.contains('setMethodCallHandler(null)'), isTrue);
    });
  });

  group('F12：完成/失败事件推到**系统通知栏**', () {
    test('首次基线不推；随后进入完成态才推一条（标题=任务名）', () async {
      final (api, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [taskJson(id: 't9', title: 'first.iso', status: 2)],
            'total': 1,
          },
        },
      );
      final sink = _FakeSink();
      final c = _container(api, sink: sink);
      addTearDown(c.dispose);
      final n = c.read(downloadCompletionProvider.notifier);

      await n.poll();
      expect(sink.shown, isEmpty, reason: '首次只建基线');

      t.responses['SYNO.DownloadStation2.Task.list'] = {
        'task': [taskJson(id: 't9', title: 'first.iso', status: 5)],
        'total': 1,
      };
      await n.poll();
      expect(sink.shown.length, 1);
      expect(sink.shown.single.text, 'first.iso');
      expect(sink.shown.single.id, 't9'.hashCode);

      // 再轮一次：已经推过，不重复
      await n.poll();
      expect(sink.shown.length, 1, reason: '同一任务不重复推');
    });

    test('失败态也推，标题是"下载失败"', () async {
      final (api, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [taskJson(id: 'e1', title: 'bad.iso', status: 2)],
            'total': 1,
          },
        },
      );
      final sink = _FakeSink();
      final c = _container(api, sink: sink);
      addTearDown(c.dispose);
      final n = c.read(downloadCompletionProvider.notifier);
      await n.poll();
      t.responses['SYNO.DownloadStation2.Task.list'] = {
        'task': [taskJson(id: 'e1', title: 'bad.iso', status: 102)],
        'total': 1,
      };
      await n.poll();
      expect(sink.shown.length, 1);
      expect(sink.shown.single.title, '下载失败');
    });

    test('系统未授权（available=false）→ **不推**，不报错', () async {
      final (api, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [taskJson(id: 't1', title: 'a.iso', status: 2)],
            'total': 1,
          },
        },
      );
      final sink = _FakeSink(allowed: false);
      final c = _container(api, sink: sink);
      addTearDown(c.dispose);
      final n = c.read(downloadCompletionProvider.notifier);
      await n.poll();
      t.responses['SYNO.DownloadStation2.Task.list'] = {
        'task': [taskJson(id: 't1', title: 'a.iso', status: 5)],
        'total': 1,
      };
      final added = await n.poll();
      expect(added, 1, reason: '事件仍然产生（应用内提示不受影响）');
      expect(sink.shown, isEmpty, reason: '但没有系统通知权限就不推');
    });

    test('用户关掉完成通知开关（enabled=false）→ 不推也不产生事件', () async {
      final (api, t) = await boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [taskJson(id: 't1', title: 'a.iso', status: 2)],
            'total': 1,
          },
        },
      );
      final sink = _FakeSink();
      final c = _container(api, sink: sink);
      addTearDown(c.dispose);
      final n = c.read(downloadCompletionProvider.notifier);
      await n.poll(enabled: false);
      t.responses['SYNO.DownloadStation2.Task.list'] = {
        'task': [taskJson(id: 't1', title: 'a.iso', status: 5)],
        'total': 1,
      };
      final added = await n.poll(enabled: false);
      expect(added, 0);
      expect(sink.shown, isEmpty);
    });
  });
}
