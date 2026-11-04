// **r488** · 下载模块（12 个页面）整体换到设计语言（`DA129`）。
//
// 与音频那几轮同一套判据，但这里**一次扫全模块**（12 个文件）：
//   ① 源码反向：`HudScaffold(` / `ListTile(` / `HudTokens` / `field_backdrop` 全部为 0；
//   ② 组件选择：勾选行必须是 `DesignCheckRow`，开关行必须是 `DesignSwitchRow`
//      （不许退回 Material 的 `CheckboxListTile` / `SwitchListTile`）；
//   ③ 至少有一个页面真的以 `DesignScaffold` 为骨架（离线渲染验证）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';
import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _ds2 = 'SYNO.DownloadStation2';

/// 模块里的 12 个页面（与 `lib/src/features/downloads/` 下带 `DesignScaffold` 的文件一致）。
const _pages = <String>[
  'download_bt_search_page.dart',
  'download_captcha_page.dart',
  'download_create_page.dart',
  'download_detail_page.dart',
  'download_emule_page.dart',
  'download_emule_search_page.dart',
  'download_emule_server_page.dart',
  'download_file_select_page.dart',
  'download_link_browser.dart',
  'download_page.dart',
  'download_rss_page.dart',
  'download_settings_page.dart',
];

void main() {
  group('DA129 · 下载模块整体设计语言化', () {
    test('DA129：12 个页面源码反向（HUD 骨架 / 裸行 / HUD 令牌 / 网格背景全清零）', () {
      final offenders = <String>[];
      for (final name in _pages) {
        final f = File('lib/src/features/downloads/$name');
        expect(f.existsSync(), isTrue, reason: '$name 不存在（清单过期）');
        final src = f.readAsStringSync();
        for (final bad in const [
          'HudScaffold(',
          'ListTile(',
          'HudTokens',
          'field_backdrop.dart',
        ]) {
          if (src.contains(bad)) offenders.add('$name: $bad');
        }
      }
      expect(offenders, isEmpty, reason: '这些地方还留在旧语言里：\n${offenders.join('\n')}');
    });

    test('DA129：勾选/开关必须用设计组件，不许退回 Material 版', () {
      for (final name in _pages) {
        final src = File('lib/src/features/downloads/$name').readAsStringSync();
        expect(
          src.contains('CheckboxListTile('),
          isFalse,
          reason: '$name 还在用 Material 的 CheckboxListTile',
        );
        expect(
          src.contains('SwitchListTile('),
          isFalse,
          reason: '$name 还在用 Material 的 SwitchListTile',
        );
      }
      // 反向验证：这两个设计组件确实在模块里被用到了（否则上面的断言是空的）
      final all = _pages
          .map((n) => File('lib/src/features/downloads/$n').readAsStringSync())
          .join('\n');
      expect(all.contains('DesignCheckRow('), isTrue);
      expect(all.contains('DesignSwitchRow('), isTrue);
      expect(all.contains('DesignScaffold('), isTrue);
    });

    testWidgets('DA129：下载页空态以 DesignScaffold 为骨架（离线渲染）', (tester) async {
      final t = FakeTransport({
        '$_ds2.Task.list': {'task': <dynamic>[], 'total': 0},
        '$_ds2.Statistic.get': {'download_rate': 0, 'upload_rate': 0},
      }, {
        ...FakeTransport.table,
        '$_ds2.Task': {
          'path': 'DownloadStation2/task.cgi',
          'minVersion': 1,
          'maxVersion': 2,
        },
        '$_ds2.Statistic': {
          'path': 'DownloadStation2/statistic.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      });
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c = ProviderContainer(
        overrides: [downloadApiProvider.overrideWithValue(DownloadStationApi(api))],
      );
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: const DownloadPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(DesignScaffold), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
