// `<queries>` 声明 与 Dart 侧 scheme 门控 的**一致性**断言（离线读源文件，不构建）。
//
// 为什么要它：Android 11+（API 30+）的包可见性下，
//   * 漏声明 `qqmap` / `baidumap` / `com.tencent.map` / `com.baidu.BaiduMap` /
//     `com.autonavi.minimap` 中的任何一个 → `canLaunchUrl` 对这些 scheme 永远
//     `false`（与"App 没装"不可区分）→ **装了 App 也永远回落网页**；
//   * 多声明 Google Maps（`com.google.android.apps.maps`）→ 境外走 https 根本
//     不需要包可见性，纯属**扩大暴露面**，违反最小化要求。
//
// 与 `photo_map_links.dart` 的 `PhotoMapCanLaunch` 注释逐条对应：
// 那份注释说"已声明这四个 scheme / 三个包"，这里就是**可执行**的证明。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 只取 `<queries>…</queries>`，避免在 `<application>` 或权限里误命中。
///
/// **不能**用 `expect`（加载期还没进 test body，会抛 `OutsideTestException`）→
/// 用 `StateError` 明确报错。
String _queriesBlock(String xml) {
  final start = xml.indexOf('<queries>');
  final end = xml.indexOf('</queries>');
  if (start < 0 || end <= start) {
    throw StateError('manifest 里找不到闭合的 <queries>');
  }
  return xml.substring(start, end);
}

void main() {
  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();
  final queries = _queriesBlock(manifest);

  test('地图 scheme 都在 <queries> 里声明（漏一个 → canLaunchUrl 永远 false）', () {
    for (final scheme in const [
      'qqmap',
      'baidumap',
      'androidamap',
      'amapuri',
    ]) {
      expect(
        queries,
        contains('<data android:scheme="$scheme"/>'),
        reason: '缺少 scheme `$scheme` → Android 11+ 看不到对应 App',
      );
    }
  });

  test('地图 package 都在 <queries> 里声明', () {
    for (final pkg in const [
      'com.tencent.map',
      'com.baidu.BaiduMap',
      'com.autonavi.minimap',
    ]) {
      expect(
        queries,
        contains('<package android:name="$pkg"/>'),
        reason: '缺少 package `$pkg`',
      );
    }
  });

  test('**不**声明 Google Maps（境外走 https，最小暴露面）', () {
    expect(queries, isNot(contains('com.google.android.apps.maps')));
    // 更强的形态断言：整个 <queries> 里**不得**出现任何 com.google.* 的 <package>。
    // （只用 `<package android:name=` 前缀匹配，避免误伤注释里的
    //  `maps.google.com` 之类的说明文字。）
    expect(queries, isNot(contains('<package android:name="com.google.')));
  });
}
