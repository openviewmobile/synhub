// Bug 1（P0）的**离线承重**用例：Android 11+ 的**包可见性**。
//
// 真机 R4（新包 sha256 `ad1f5554…`，HONOR LGE-AN10 / API 31）实测：
//   * `.pdf` 的「用其他应用打开」✅ 弹出系统选择器（`Complete action using`）；
//   * `.mp4` ❌ logcat 逐字：
//     `W SynologyChatMedia: 没有应用能处理 video/mp4（也没有 video/* / audio/* 兜底）：…`
//   * `.mkv` ❌ 同上（MIME `video/x-matroska`）；
//   * 反证（决定性）：`adb shell pm query-activities -a android.intent.action.VIEW
//     -t video/mp4 -c android.intent.category.DEFAULT` → **2 activities found**
//     （`com.huawei.himovie/hwvplayer.FullscreenActivity`）→ 系统里有 handler，
//     但**本 App 看不见**。
//
// 根因：`AndroidManifest.xml` 的 `<queries>` 只声明了 `PROCESS_TEXT + text/plain`；
// `MediaOpenBridge.viewLocal` / `view` 用 `queryIntentActivities` 预探测 → 被
// 包可见性过滤成空 → 直接 `return false`，连 `startActivity` 都没发生。
//
// 本文件解析**真实的** `android/app/src/main/AndroidManifest.xml`（先剥 XML 注释 ——
// 注释里举了 `*/*` 作为反例，不剥会被当成真声明，`file_provider_paths_test.dart`
// 已经踩过同类坑），断言 `<queries>` 覆盖了这些 MIME 且**不含 `*/*`**。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kManifestPath = 'android/app/src/main/AndroidManifest.xml';

/// 修复前的 `<queries>`（逐字复刻真机报错时磁盘上的内容）—— 用来做
/// "这套断言是承重的" 的反证：只声明 `PROCESS_TEXT` 时，`video/mp4` 无人覆盖。
const String kPreFixQueriesXml = '''
<queries>
    <intent>
        <action android:name="android.intent.action.PROCESS_TEXT"/>
        <data android:mimeType="text/plain"/>
    </intent>
</queries>
''';

/// `<queries>` 里的一条 `<intent>` 声明。
class QueriesIntent {
  const QueriesIntent({
    required this.actions,
    required this.categories,
    required this.mimeTypes,
    this.schemes = const [],
  });

  final List<String> actions;
  final List<String> categories;
  final List<String> mimeTypes;

  /// `<data android:scheme="…">`（**scheme 型** ACTION_VIEW，例如相册地图的
  /// `qqmap://` / `baidumap://`）。这类声明**天然没有 mimeType** ——
  /// 见下面 `hasAnyData` 的注释。
  final List<String> schemes;

  bool get isActionView => actions.contains('android.intent.action.VIEW');

  bool get hasDefaultCategory =>
      categories.contains('android.intent.category.DEFAULT');

  /// 一条 VIEW 声明至少要有一种 `<data>`（MIME **或** scheme）。
  ///
  /// **不能**要求"必须有 mimeType"：`<queries>` 里声明自定义 URL scheme 同样是
  /// 合法且必需的形态（Android 11+ 包可见性下，`canLaunchUrl` 对
  /// `qqmap://` 这类 scheme 也要能被看见），它本来就不带 MIME。
  bool get hasAnyData => mimeTypes.isNotEmpty || schemes.isNotEmpty;

  @override
  String toString() =>
      'QueriesIntent(actions=$actions, categories=$categories, mime=$mimeTypes, '
      'scheme=$schemes)';
}

/// 解析 `<queries>` 块（先剥注释）。找不到 `<queries>` → 空列表。
List<QueriesIntent> parseQueriesIntents(String manifestXml) {
  final body = manifestXml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  final block = RegExp(
    r'<queries\b[^>]*>(.*?)</queries>',
    dotAll: true,
  ).firstMatch(body);
  if (block == null) return const [];
  final inner = block.group(1)!;
  return [
    for (final m in RegExp(
      r'<intent\b[^>]*>(.*?)</intent>',
      dotAll: true,
    ).allMatches(inner))
      QueriesIntent(
        actions: _allAttr(m.group(1)!, 'action', 'name'),
        categories: _allAttr(m.group(1)!, 'category', 'name'),
        mimeTypes: _allAttr(m.group(1)!, 'data', 'mimeType'),
        schemes: _allAttr(m.group(1)!, 'data', 'scheme'),
      ),
  ];
}

List<String> _allAttr(String xml, String tag, String attr) => [
  for (final m in RegExp(
    '<$tag\\b[^>]*android:$attr\\s*=\\s*"([^"]*)"',
  ).allMatches(xml))
    m.group(1)!,
];

/// [mime] 是否被 [declared] 里的某条声明覆盖（精确、`type/*` 通配、或 `*/*`）。
///
/// `*/*` **也**算覆盖 —— 这正是它危险的地方（什么都匹配得到，包括
/// `com.android.packageinstaller/.InstallStart`），所以覆盖断言必须再配一条
/// "绝不声明 `*/*`" 的显式断言。
bool mimeCovered(String mime, Iterable<String> declared) {
  if (declared.contains('*/*')) return true;
  final slash = mime.indexOf('/');
  if (slash <= 0) return false;
  final wildcard = '${mime.substring(0, slash)}/*';
  return declared.contains(mime) || declared.contains(wildcard);
}

/// 覆盖 [mime] 的 ACTION_VIEW 声明（`type/*` 通配也算）。
List<QueriesIntent> actionViewIntentsFor(
  String mime,
  List<QueriesIntent> intents,
) => [
  for (final intent in intents)
    if (intent.isActionView && mimeCovered(mime, intent.mimeTypes)) intent,
];

void main() {
  late final String manifest;
  late final List<QueriesIntent> intents;
  late final List<String> actionViewMimes;

  setUpAll(() {
    final file = File(kManifestPath);
    expect(
      file.existsSync(),
      isTrue,
      reason: '找不到 $kManifestPath（flutter test 的 cwd 应为包根）',
    );
    manifest = file.readAsStringSync();
    intents = parseQueriesIntents(manifest);
    actionViewMimes = [
      for (final intent in intents)
        if (intent.isActionView) ...intent.mimeTypes,
    ];
  });

  group('真实 AndroidManifest.xml 的 <queries> 覆盖 ACTION_VIEW', () {
    test('<queries> 块存在，且原有 PROCESS_TEXT 声明未被删（无回归）', () {
      expect(intents, isNotEmpty, reason: '没有 <queries> 就没有包可见性');
      final processText = [
        for (final intent in intents)
          if (intent.actions.contains('android.intent.action.PROCESS_TEXT'))
            intent,
      ];
      expect(
        processText,
        hasLength(1),
        reason: 'PROCESS_TEXT 是 Flutter 引擎文本处理要用的，删了会破坏既有功能',
      );
      expect(processText.single.mimeTypes, contains('text/plain'));
    });

    test('每一条 ACTION_VIEW 声明都带 category DEFAULT 且至少有一种 <data>', () {
      final views = [
        for (final intent in intents)
          if (intent.isActionView) intent,
      ];
      expect(views, isNotEmpty, reason: '一条 ACTION_VIEW 都没有 = Bug 1 没修');
      for (final view in views) {
        expect(
          view.hasDefaultCategory,
          isTrue,
          reason: '隐式 ACTION_VIEW 的解析按 CATEGORY_DEFAULT 走：$view',
        );
        // MIME 型（`video/*` 等）与 scheme 型（`qqmap://` 等）都是合法形态：
        // 前者给"用其他应用打开"，后者给相册地图调起国内地图 App。
        expect(
          view.hasAnyData,
          isTrue,
          reason: '既没有 MIME 也没有 scheme 的 VIEW 声明没有意义：$view',
        );
      }
      // MIME 型必须仍是那 5 条规范通配（video/audio/image/text/application）——
      // 新增 scheme 型声明**不得**把它们顶掉或合并。
      final mimeViews = [
        for (final view in views)
          if (view.mimeTypes.isNotEmpty) view,
      ];
      expect(
        mimeViews,
        hasLength(5),
        reason: '规范通配的 MIME 声明应恰为 5 条，实际：$mimeViews',
      );
      // scheme 型的必须覆盖相册地图真正会调起的三家 App 的 4 个 scheme。
      final schemeNames = [for (final view in views) ...view.schemes];
      for (final scheme in ['qqmap', 'baidumap', 'androidamap', 'amapuri']) {
        expect(
          schemeNames,
          contains(scheme),
          reason: '$scheme 未声明 → Android 11+ 下 canLaunchUrl 看不见对应地图 App',
        );
      }
    });

    test('.mp4 / .mkv / .wav / .pdf 等外开类型都被覆盖（Bug 1 的正断言）', () {
      // 逐条对应 `MediaOpenBridge.viewLocal` / `view` 真的会发出去的 MIME
      // （来源：`lib/src/features/chat/media_stream.dart#kMimeByExtension`）。
      const required = <String>[
        'video/mp4', // clip-h264.mp4（R4 实测失败）
        'video/x-matroska', // theora.mkv（R4 实测失败）
        'video/webm',
        'audio/x-wav', // audiotone.wav
        'audio/flac',
        'application/pdf', // r4-doc.pdf（R4 实测通过）
        'application/epub+zip',
        'text/plain',
        'image/jpeg',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/zip',
      ];
      for (final mime in required) {
        expect(
          actionViewIntentsFor(mime, intents),
          isNotEmpty,
          reason:
              '$mime 没有 ACTION_VIEW 声明 → 真机 queryIntentActivities 返回空 → '
              'viewLocal 直接 return false（选择器永不弹出）',
        );
      }
    });

    test('video/* 与 audio/* 用规范通配覆盖细分 MIME', () {
      expect(actionViewMimes, contains('video/*'));
      expect(actionViewMimes, contains('audio/*'));
    });

    test('绝不声明 `*/*`（历史回归的硬约束）', () {
      for (final intent in intents) {
        expect(
          intent.mimeTypes,
          isNot(contains('*/*')),
          reason: '`*/*` 会让 .mkv 落到 InstallStart（docs/…-research.md §10.3）',
        );
      }
      expect(
        actionViewMimes,
        isNot(contains('*/*')),
        reason: 'ACTION_VIEW 里出现 `*/*` 就是退回旧缺陷',
      );
    });
  });

  group('falsification：这套断言确实是承重的', () {
    test('修复前的 <queries>（只有 PROCESS_TEXT）→ 视频两类全都不被覆盖', () {
      final legacy = parseQueriesIntents(kPreFixQueriesXml);
      expect(legacy, hasLength(1), reason: '反证素材本身要是合法的 PROCESS_TEXT 声明');
      for (final mime in ['video/mp4', 'video/x-matroska', 'audio/x-wav']) {
        expect(
          actionViewIntentsFor(mime, legacy),
          isEmpty,
          reason:
              '修复前就该复现「没有应用能处理 $mime」—— 用例若在这里返回非空，'
              '说明它根本没在测包可见性',
        );
      }
      expect(mimeCovered('video/mp4', const ['text/plain']), isFalse);
    });

    test('只删 ACTION_VIEW 那几条 → 视频立刻失去覆盖（单点承重）', () {
      final withoutView = [
        for (final intent in intents)
          if (!intent.isActionView) intent,
      ];
      // 不再硬编码"ACTION_VIEW 恰好 5 条"（新增 scheme 型声明会让它变成 9 条，
      // 那是**合法扩展**）；改断言：所有 VIEW 都被摘掉，且逐一验证承重效果。
      expect(
        withoutView.any((i) => i.isActionView),
        isFalse,
        reason: '这里应当只剩非 VIEW 声明（PROCESS_TEXT 那条）',
      );
      expect(withoutView, isNotEmpty, reason: 'PROCESS_TEXT 不该被一起摘掉，否则这条反证不成立');
      for (final mime in [
        'video/mp4',
        'video/x-matroska',
        'audio/x-wav',
        'application/pdf',
      ]) {
        expect(
          actionViewIntentsFor(mime, withoutView),
          isEmpty,
          reason: '摘掉 VIEW 声明后 $mime 必须失去覆盖 —— 说明正断言是承重的',
        );
      }
      // 先证明"有 VIEW 时确实被覆盖"，否则上面的 isEmpty 可能只是因为常量写错。
      for (final mime in ['video/mp4', 'application/pdf']) {
        expect(actionViewIntentsFor(mime, intents), isNotEmpty);
      }
    });

    test('`*/*` 会"覆盖"一切 —— 所以必须靠显式断言把它钉死', () {
      const wildcardOnly = [
        QueriesIntent(
          actions: ['android.intent.action.VIEW'],
          categories: ['android.intent.category.DEFAULT'],
          mimeTypes: ['*/*'],
        ),
      ];
      // 这正是修复**不能**走的路：`*/*` 也能让覆盖率断言通过
      expect(actionViewIntentsFor('video/mp4', wildcardOnly), isNotEmpty);
      // 但真实 manifest 里不许出现它（上一条 group 的显式断言）
      expect(actionViewMimes, isNot(contains('*/*')));
    });

    test('解析器先剥注释：注释里的示例声明不算数', () {
      const withComment = '''
<manifest>
  <queries>
    <!-- 反例：<intent><action android:name="android.intent.action.VIEW"/>
         <data android:mimeType="*/*"/></intent> -->
    <intent>
      <action android:name="android.intent.action.PROCESS_TEXT"/>
      <data android:mimeType="text/plain"/>
    </intent>
  </queries>
</manifest>
''';
      final parsed = parseQueriesIntents(withComment);
      expect(parsed, hasLength(1));
      expect(parsed.single.mimeTypes, ['text/plain']);
      expect(
        actionViewMimes,
        isNot(contains('*/*')),
        reason: '注释里的 `*/*` 不能出现在真实声明里',
      );
    });
  });
}
