// ★ 第 278 轮：**network security config 契约守卫**（API 28 起明文默认被禁）。
//
// 背景（官方 behavior-changes-28 逐字）："如果应用以 Android 9 或更高版本为
// 目标平台，则 `isCleartextTrafficPermitted()` 方法默认返回 `false`。如果您的
// 应用需要针对特定网域启用明文，则您必须在应用的网络安全配置中，针对这些网域
// 明确将 `cleartextTrafficPermitted` 设置为 `true`。"
//
// 本文件把下面四条钉死：
//   ① 明文**默认关闭**（只给回环开例外 —— 那是 `adb reverse` 的本机 mock 通路）；
//   ② 信任锚 = **系统 CA + 用户装的 CA**：NAS 自签证书的现实处置是"用户把
//      NAS 的 CA 装进系统「用户证书」"，而 Android 7（API 24）起 App **默认
//      不信任用户安装的 CA** —— 少了 `src="user"`，用户装完也连不上，且报错
//      与"没装"无法区分（AGENTS §2.0.11 是同一类问题的原生栈版本）；
//   ③ 回环例外**只**含 127.0.0.1 / localhost，不含局域网网段
//      （明文 NAS 需要用户显式选择，默认一律 https）；
//   ④ 不设 `<debug-overrides>`（那会让非 release 构建额外信任 debug CA）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kConfigPath =
    'android/app/src/main/res/xml/network_security_config.xml';
const String kManifestPath = 'android/app/src/main/AndroidManifest.xml';

String _stripComments(String s) =>
    s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// 抽出 `<base-config …>` 标签本体
String _baseConfigTag(String xml) {
  final m = RegExp(
    r'<base-config\b([^>]*)>',
    dotAll: true,
  ).firstMatch(_stripComments(xml));
  return m == null ? '' : m.group(0)!;
}

String _baseConfigBody(String xml) {
  final body = _stripComments(xml);
  final open = RegExp(r'<base-config\b([^>]*?)(/?)>', dotAll: true).firstMatch(body);
  if (open == null) return '';
  if (open.group(2) == '/') return ''; // 自闭合：没有子节点
  final close = body.indexOf('</base-config>', open.end);
  return close < 0 ? '' : body.substring(open.end, close);
}

/// 抽出所有 `<domain-config …>` 的 (允许明文?, 域名列表)
List<({bool cleartext, List<String> domains})> _domainConfigs(String xml) {
  final body = _stripComments(xml);
  final out = <({bool cleartext, List<String> domains})>[];
  for (final m in RegExp(
    r'<domain-config\b([^>]*?)>(.*?)</domain-config>',
    dotAll: true,
  ).allMatches(body)) {
    final attrs = m.group(1)!;
    final inner = m.group(2)!;
    out.add((
      cleartext: RegExp(
        r'cleartextTrafficPermitted\s*=\s*"true"',
      ).hasMatch(attrs),
      domains: [
        for (final d in RegExp(
          r'<domain\b[^>]*>([^<]*)</domain>',
        ).allMatches(inner))
          d.group(1)!.trim(),
      ],
    ));
  }
  return out;
}

void main() {
  late final String xml;

  setUpAll(() {
    final f = File(kConfigPath);
    expect(f.existsSync(), isTrue, reason: '找不到 $kConfigPath');
    xml = f.readAsStringSync();
  });

  group('① 明文：默认关闭，只给回环开例外', () {
    test('base-config 明确禁止明文', () {
      expect(
        _baseConfigTag(xml),
        contains('cleartextTrafficPermitted="false"'),
        reason: 'Android 9+ 默认就是 false；显式写死才有"我们是有意如此"的证据',
      );
    });

    test('允许明文的 domain-config 只覆盖回环地址', () {
      final allow = [
        for (final d in _domainConfigs(xml))
          if (d.cleartext) d.domains,
      ];
      expect(allow, hasLength(1), reason: '只应有回环那一条 domain-config');
      expect(allow.single.toSet(), {'127.0.0.1', 'localhost'});
    });

    test('明文例外里绝不出现局域网/私有网段（不放松真实场景）', () {
      final all = [for (final d in _domainConfigs(xml)) ...d.domains];
      for (final bad in const [
        '192.168.0.0',
        '10.0.0.0',
        '172.16.0.0',
        '0.0.0.0',
        '*',
        'quickconnect.to',
      ]) {
        expect(
          all,
          isNot(contains(bad)),
          reason: '$bad 不该被放行明文（明文 NAS 需用户显式选择）',
        );
      }
    });
  });

  group('② 信任锚：系统 CA + 用户装的 CA（NAS 自签证书的现实路径）', () {
    test('base-config 里同时有 system 与 user 两个信任锚', () {
      final body = _baseConfigBody(xml);
      expect(body, contains('<trust-anchors>'), reason: '没有 trust-anchors');
      expect(body, contains('<certificates src="system"/>'));
      expect(
        body,
        contains('<certificates src="user"/>'),
        reason: 'Android 7+ App 默认不信任用户安装的 CA；缺这条则"用户按 '
            'Synology 引导装了 NAS 的 CA"对平台网络栈（Media3/ExoPlayer、'
            'WebView、HttpURLConnection）无效',
      );
    });

    test('base-config 是显式开标签（自闭合就装不下 trust-anchors）', () {
      expect(_baseConfigBody(xml), isNotEmpty);
    });
  });

  group('③ 不引入额外的信任放宽面', () {
    test('没有 <debug-overrides>', () {
      expect(
        _stripComments(xml).contains('debug-overrides'),
        isFalse,
        reason: 'debug-overrides 会让非 release 构建额外信任 debug CA；'
            '本项目的本机 mock 已由"回环明文例外"覆盖，不需要它',
      );
    });

    test('没有声明 pin-set（钉证书走代码里的 MediaTlsPolicy，见 AGENTS §2.0.11）', () {
      expect(_stripComments(xml).contains('pin-set'), isFalse);
      expect(_stripComments(xml).contains('digest='), isFalse);
    });
  });

  group('④ manifest 真的引用这份配置', () {
    test('application 上声明了 android:networkSecurityConfig', () {
      final m = File(kManifestPath).readAsStringSync();
      expect(
        _stripComments(m),
        contains('android:networkSecurityConfig="@xml/network_security_config"'),
        reason: '不引用的话这份文件等于不存在（平台会走默认：禁明文 + 只信系统 CA）',
      );
    });
  });

  group('反向验证：这套断言确实承重', () {
    // 修复前的配置（第 278 轮之前逐字）
    const preFix = '''
<network-security-config>
    <base-config cleartextTrafficPermitted="false"/>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
        <domain includeSubdomains="false">localhost</domain>
    </domain-config>
</network-security-config>
''';

    test('修复前：base-config 自闭合 ⇒ 没有 user 信任锚（NAS 自签 CA 用不上）', () {
      expect(_baseConfigTag(preFix), contains('cleartextTrafficPermitted="false"'));
      expect(_baseConfigBody(preFix), isEmpty);
      expect(_baseConfigBody(preFix), isNot(contains('src="user"')));
    });

    test('合成反例：把局域网放进明文例外时必须被抓出来', () {
      const bad = '''
<network-security-config>
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors><certificates src="system"/></trust-anchors>
    </base-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="true">192.168.0.0</domain>
    </domain-config>
</network-security-config>
''';
      final allow = [
        for (final d in _domainConfigs(bad))
          if (d.cleartext) d.domains,
      ];
      expect(allow.single, contains('192.168.0.0'));
      expect(allow.single.toSet(), isNot({'127.0.0.1', 'localhost'}));
      expect(_baseConfigBody(bad), isNot(contains('src="user"')));
    });

    test('合成反例：debug-overrides 必须被判定为存在', () {
      const bad = '''
<network-security-config>
    <base-config cleartextTrafficPermitted="false"/>
    <debug-overrides><trust-anchors><certificates src="user"/></trust-anchors></debug-overrides>
</network-security-config>
''';
      expect(_stripComments(bad).contains('debug-overrides'), isTrue);
    });
  });
}
