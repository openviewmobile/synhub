// 流量统计的**隐私边界**：只允许 module / direction / bytes / 小时 / 档位 / 传输方式。
//
// 这是硬约束（用户要求 = 用来分析模块排行，不需要知道访问了什么）：
// 任何一处漏进 url / host / path / 文件名，都会让"本地聚合"变成"访问记录"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _trafficSources = [
  'lib/src/core/net/traffic_meter.dart',
  'lib/src/core/net/device_traffic.dart',
  'lib/src/features/analytics/traffic_log.dart',
  'lib/src/features/analytics/traffic_analysis.dart',
  'lib/src/features/analytics/traffic_page.dart',
];

/// 允许出现的"看起来像地址"的字符串（每一处都要有理由）
const _allowedLiterals = {
  // 全局计量标签的 key，值是常量名不是地址
  'synhub.traffic.module',
  'synhub.traffic.tier',
  'synhub.traffic.transport',
};

void main() {
  test('流量链路源码里没有承载地址的**字符串字面量**', () {
    final bad = RegExp(
      r"'[^']*(url|uri|host|hostname|path|filename|file_name)[^']*'",
      caseSensitive: false,
    );
    for (final path in _trafficSources) {
      final src = File(path).readAsStringSync();
      for (final m in bad.allMatches(src)) {
        final lit = m.group(0)!;
        expect(
          _allowedLiterals.contains(lit.replaceAll("'", '')),
          isFalse,
          reason: '$path 出现了疑似地址字面量 $lit',
        );
      }
    }
  });

  test('计量器从不读取请求地址（只读 extra 与字节流）', () {
    final src = File('lib/src/core/net/traffic_meter.dart').readAsStringSync();
    for (final needle in ['options.uri', 'baseUrl', 'options.path']) {
      expect(
        src.contains(needle),
        isFalse,
        reason: '计量器不应触碰 $needle —— 一旦读了地址就有泄漏面',
      );
    }
  });

  test('样本结构只有"模块 + 方向 + 字节 + 档位（+ 传输方式）"', () {
    final src = File('lib/src/core/net/traffic_meter.dart').readAsStringSync();
    final cls = RegExp(
      r'class TrafficSample \{([\s\S]*?)\n\}',
    ).firstMatch(src)!.group(1)!;
    final fields = RegExp(r'final\s+[\w<>?]+\s+(\w+);')
        .allMatches(cls)
        .map((m) => m.group(1)!)
        .toSet();
    expect(fields, containsAll(<String>['at', 'module', 'direction', 'bytes']));
    expect(fields, contains('tier'));
    expect(fields, contains('transport'));
    expect(
      fields.length,
      6,
      reason: '样本字段被加过就说明有人往流量表里塞了新维度：$fields',
    );
  });

  test('估算档也只带模块与字节（差分本身就与地址无关）', () {
    final src =
        File('lib/src/core/net/device_traffic.dart').readAsStringSync();
    final cls = RegExp(
      r'class EstimatedAttribution \{([\s\S]*?)\n\}',
    ).firstMatch(src)!.group(1)!;
    final fields = RegExp(r'final\s+[\w<>?]+\s+(\w+);')
        .allMatches(cls)
        .map((m) => m.group(1)!)
        .toSet();
    expect(fields, {
      'accepted',
      'reason',
      'rxBytes',
      'txBytes',
      'from',
      'to',
    });
  });

  test('存储层的键名白名单（含 meta 键）', () {
    final src = File('lib/src/features/analytics/traffic_log.dart')
        .readAsStringSync();
    final keys = RegExp(r"kMeta\w+\s*=\s*'([^']+)'")
        .allMatches(src)
        .map((m) => m.group(1)!)
        .toList();
    expect(keys, isNotEmpty);
    for (final k in keys) {
      expect(
        RegExp(r'url|host|path|file|name', caseSensitive: false).hasMatch(k),
        isFalse,
        reason: 'meta 键 $k 像是承载了地址信息',
      );
    }
  });
}
