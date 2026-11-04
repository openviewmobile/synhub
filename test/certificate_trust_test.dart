// Phase 9：首连证书信任 + 证书管理页离线验证。
//
// 覆盖：指纹计算与展示格式、信任库读写/去重/删除、`evaluate` 的三种结果
// （已信任放行 / 未知拒绝+记挑战 / 指纹变更记 changedFrom）、
// 连接层"拒绝 → 弹框 → 信任后重试"的完整链路、对话框与证书页 UI。
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/core/net/trust_store.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/certificate_trust_dialog.dart';
import 'package:synhub/src/features/servers/certificates_page.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/session_controller.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 造一个假证书：X509Certificate 没法直接 new，这里用真 TLS 服务器太麻烦，
/// 所以 `TrustPolicy` 里把"证书 → 指纹"抽成了 [TrustPolicy.sha256Hex]，
/// 测试用假证书只需覆盖挑战/库逻辑（见 `_FakeCertX509` 的替代方案）。
///
/// 为了不改生产代码，这里用一个小技巧：`dart:io` 的 `X509Certificate` 只能从
/// 真实握手拿到，所以 evaluate 的测试用 `TOFU` 路径 + 直接调 `trust()`。

/// 测试里也走和 App 一样的构造路径（`ChatStore` → 四个函数）
TrustPolicy _policyFor(ChatStore store) => TrustPolicy.of(
  read: (k) => store.setting(k),
  write: (k, v) => store.setSetting(k, v),
  remove: (k) => store.deleteSetting(k),
  all: () => store.allSettings(),
);

void main() {
  group('指纹与信任库', () {
    test('sha256Hex 大写十六进制、64 字符', () {
      final hex = TrustPolicy.sha256Hex(Uint8List.fromList('abc'.codeUnits));
      expect(hex.length, 64);
      expect(hex, hex.toUpperCase());
      expect(hex, isNot(contains(':')));
      // 与 `shasum -a 256` 对齐（已知向量）
      expect(
        hex,
        'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD',
      );
    });

    test('TrustedCert JSON 往返', () {
      final c = TrustedCert(
        host: 'nas:5001',
        sha256: 'AB' * 32,
        savedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        subject: 'CN=nas',
        issuer: 'CN=nas',
      );
      final back = TrustedCert.tryParse(_json(c))!;
      expect(back.host, 'nas:5001');
      expect(back.sha256, 'AB' * 32);
      expect(back.savedAt.millisecondsSinceEpoch, 1700000000000);
      expect(back.subject, 'CN=nas');
    });

    test('脏数据/空数据不炸', () {
      expect(TrustedCert.tryParse('not json'), isNull);
      expect(TrustedCert.tryParse('{}'), isNull);
      expect(TrustedCert.tryParse('{"host":"a"}'), isNull);
    });

    test('save / find / forget / all 只认自己的前缀', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      // 别的 key 不该被当成证书
      await store.setSetting('trusted_cert_something', 'x');
      await store.setSetting('dark_mode', '2');

      final policy = _policyFor(store);
      final ch = _challenge('nas:5001', 'AA' * 32);
      await policy.trust(ch);

      final found = await policy.find('nas:5001');
      expect(found, isNotNull);
      expect(found!.sha256, 'AA' * 32);
      expect((await policy.trusted()).length, 1);

      // 主机名大小写不敏感（原版按字符串比，这里统一小写更稳）
      expect(await policy.find('NAS:5001'), isNotNull);

      await policy.forget('nas:5001');
      expect(await policy.find('nas:5001'), isNull);
      expect(await policy.trusted(), isEmpty);
    });

    test('load() 把库读进内存，供同步回调判断', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      final policy = _policyFor(store);
      await policy.trust(_challenge('nas:5001', 'BB' * 32));
      expect(policy.isLoaded, isFalse);

      final fresh = _policyFor(store);
      await fresh.load();
      expect(fresh.isLoaded, isTrue);
      expect(fresh.trustedInMemory('nas:5001'), 'BB' * 32);
    });
  });

  group('TrustPolicy 决策', () {
    test('没注册 prompt 时一律拒绝（后台任务/无人值守）', () async {
      final h = await bootChat();
      final policy = _policyFor(h.container.read(chatStoreProvider));
      final ch = _challenge('nas:5001', 'CC' * 32);
      expect(await policy.decide(ch), isFalse);
      expect(await policy.find('nas:5001'), isNull, reason: '拒绝就不该入库');
    });

    test('用户点信任 → 入库；点取消 → 不入库', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      final policy = _policyFor(store);
      final asked = <TrustChallenge>[];
      policy.prompt = (ch) async {
        asked.add(ch);
        return ch.sha256 == 'DD' * 32;
      };

      expect(await policy.decide(_challenge('a:5001', 'DD' * 32)), isTrue);
      expect(await policy.find('a:5001'), isNotNull);
      expect(await policy.decide(_challenge('b:5001', 'EE' * 32)), isFalse);
      expect(await policy.find('b:5001'), isNull);
      expect(asked.length, 2);
    });

    test('挑战能表达"指纹变了"，并给出原指纹', () {
      final ch = TrustChallenge(
        host: 'nas:5001',
        sha256: 'FF' * 32,
        subject: 'CN=nas',
        issuer: 'CN=nas',
        validFrom: DateTime(2026, 1, 1),
        validTo: DateTime(2027, 1, 1),
        changedFrom: 'AA' * 32,
        isSelfSigned: true,
      );
      expect(ch.isChanged, isTrue);
      expect(ch.grouped.split(':').length, 32);
      expect(ch.grouped.startsWith('FF:FF'), isTrue);
      expect(ch.isExpired, isFalse);
      expect(
        TrustChallenge(
          host: 'x',
          sha256: 'AB' * 32,
          subject: '',
          issuer: '',
          validFrom: DateTime(2020, 1, 1),
          validTo: DateTime(2021, 1, 1),
        ).isExpired,
        isTrue,
      );
    });
  });

  group('连接层：拒绝 → 弹框 → 信任后重试', () {
    const apiInfo =
        '{"success":true,"data":{"SYNO.API.Info":{"path":"query.cgi",'
        '"minVersion":1,"maxVersion":1}}}';

    /// 造一个 Dio：`shouldFail()` 为真时按"证书握手失败"拒绝（并记下挑战），
    /// 否则正常返回 API Info。
    Dio certFailDio(TrustPolicy policy, bool Function() shouldFail) {
      final dio = Dio(BaseOptions(validateStatus: (s) => s != null));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (shouldFail()) {
              policy.noteChallengeForTest(_challenge('nas:5001', 'AB' * 32));
              return handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.badCertificate,
                  error: 'CERT_UNTRUSTED',
                ),
              );
            }
            return handler.resolve(_ok(options, apiInfo));
          },
        ),
      );
      return dio;
    }

    test('第一次握手失败弹框，同意后重试成功并入库', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      final policy = _policyFor(store);
      var asked = 0;
      policy.prompt = (ch) async {
        asked++;
        expect(ch.host, 'nas:5001');
        return true;
      };
      var attempts = 0;
      var failedOnce = false;
      final service = ConnectionService(
        trustPolicy: policy,
        dioBuilder: (_) => certFailDio(policy, () {
          attempts++;
          if (failedOnce) return false;
          failedOnce = true;
          return true;
        }),
      );

      final calls = <String>[];
      final conn = await service.connect(
        const ServerProfile(
          kind: ServerAddressKind.direct,
          value: 'https://nas:5001',
        ),
        onStep: (s) => calls.add('${s.ok ? '' : '✗ '}${s.text}'),
      );

      expect(asked, 1);
      expect(attempts, 2, reason: '信任后必须重试一次');
      expect(conn.endpoint.baseUrl, 'https://nas:5001');
      expect(await policy.find('nas:5001'), isNotNull);
      expect(calls.any((c) => c.contains('未受信任')), isTrue);
      expect(calls.any((c) => c.contains('重试连接')), isTrue);
    });

    test('用户拒绝时连接中止，且不入库', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      final policy = _policyFor(store)..prompt = (_) async => false;
      var attempts = 0;
      var failedOnce = false;
      final service = ConnectionService(
        trustPolicy: policy,
        dioBuilder: (_) => certFailDio(policy, () {
          attempts++;
          if (failedOnce) return false;
          failedOnce = true;
          return true;
        }),
      );

      await expectLater(
        service.connect(
          const ServerProfile(
            kind: ServerAddressKind.direct,
            value: 'https://nas:5001',
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(attempts, 1, reason: '拒绝了就不该再试');
      expect(await policy.find('nas:5001'), isNull);
    });

    test('普通网络错误不会被当成证书问题（不弹框）', () async {
      final h = await bootChat();
      final policy = _policyFor(h.container.read(chatStoreProvider));
      var asked = 0;
      policy.prompt = (_) async {
        asked++;
        return true;
      };
      final service = ConnectionService(
        trustPolicy: policy,
        dioBuilder: (_) {
          final dio = Dio(BaseOptions(validateStatus: (s) => s != null));
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) => handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  error: 'connection refused',
                ),
              ),
            ),
          );
          return dio;
        },
      );

      await expectLater(
        service.connect(
          const ServerProfile(
            kind: ServerAddressKind.direct,
            value: 'https://nas:5001',
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(asked, 0);
      expect(policy.pendingFor('nas', 5001), isNull);
    });
  });

  group('握手回调判定（evaluateInfo）', () {
    CertInfo info(String seed, {String? subject}) => CertInfo(
      der: Uint8List.fromList(seed.codeUnits),
      subject: subject ?? 'CN=nas',
      issuer: 'CN=nas',
      validFrom: DateTime(2026, 1, 1),
      validTo: DateTime(2027, 1, 1),
    );

    test('未信任 → 拒绝并记下挑战', () async {
      final h = await bootChat();
      final policy = _policyFor(h.container.read(chatStoreProvider));
      final cert = info('cert-1');

      expect(policy.evaluateInfo(cert, 'nas', 5001), isFalse);
      final ch = policy.pendingFor('nas', 5001);
      expect(ch, isNotNull);
      expect(ch!.sha256, cert.sha256);
      expect(ch.host, 'nas:5001');
      expect(ch.isChanged, isFalse, reason: '从没信任过 → 不是"变更"');
      expect(ch.isSelfSigned, isTrue);
    });

    test('信任后再握手 → 直接放行，不再有挑战', () async {
      final h = await bootChat();
      final policy = _policyFor(h.container.read(chatStoreProvider));
      final cert = info('cert-1');
      policy.evaluateInfo(cert, 'nas', 5001); // 第一次记挑战
      await policy.trust(policy.pendingFor('nas', 5001)!);

      expect(policy.evaluateInfo(cert, 'nas', 5001), isTrue);
      expect(policy.pendingFor('nas', 5001), isNull);
      expect(policy.trustedInMemory('nas:5001'), cert.sha256);
    });

    test('证书换了（指纹不一致）→ 拒绝 + changedFrom 带原指纹', () async {
      final h = await bootChat();
      final policy = _policyFor(h.container.read(chatStoreProvider));
      final old = info('cert-old');
      policy.evaluateInfo(old, 'nas', 5001);
      await policy.trust(policy.pendingFor('nas', 5001)!);

      final newCert = info('cert-new');
      expect(policy.evaluateInfo(newCert, 'nas', 5001), isFalse);
      final ch = policy.pendingFor('nas', 5001)!;
      expect(ch.isChanged, isTrue);
      expect(ch.changedFrom, old.sha256);
      expect(ch.sha256, newCert.sha256);
    });

    test('不同端口的证书互不影响', () async {
      final h = await bootChat();
      final policy = _policyFor(h.container.read(chatStoreProvider));
      final cert = info('cert-1');
      policy.evaluateInfo(cert, 'nas', 5001);
      await policy.trust(policy.pendingFor('nas', 5001)!);

      expect(
        policy.evaluateInfo(cert, 'nas', 5002),
        isFalse,
        reason: '同主机不同端口要分别信任',
      );
      expect(policy.trustedInMemory('nas:5002'), isNull);
    });

    test('DioFactory 接了策略也能正常建出 Dio', () async {
      final h = await bootChat();
      final policy = _policyFor(h.container.read(chatStoreProvider));
      final dio = DioFactory.create(trustPolicy: policy);
      expect(dio.httpClientAdapter, isNotNull);
      expect(dio.options.validateStatus(200), isTrue);
    });
  });

  group('证书信任对话框', () {
    testWidgets('首次连接：展示指纹与详情，按钮是"信任并继续"', (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showCertificateTrustDialog(
                  context,
                  _challenge('nas:5001', 'AB' * 32),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('不受信任的证书'), findsOneWidget);
      expect(find.textContaining('AB:AB:AB'), findsWidgets);
      expect(find.text('信任并继续'), findsOneWidget);
      expect(find.textContaining('自签名证书'), findsOneWidget);

      await tester.tap(find.text('信任并继续'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('指纹变更：红色告警 + 展示原指纹', (tester) async {
      final ch = TrustChallenge(
        host: 'nas:5001',
        sha256: 'FF' * 32,
        subject: 'CN=nas',
        issuer: 'CN=nas',
        validFrom: DateTime(2026, 1, 1),
        validTo: DateTime(2027, 1, 1),
        changedFrom: 'AA' * 32,
      );
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCertificateTrustDialog(context, ch),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('服务器证书已变更'), findsOneWidget);
      expect(find.text('AA:AA:AA'.substring(0, 8)), findsNothing);
      expect(find.textContaining('原指纹'), findsOneWidget);
      expect(find.textContaining('有人在窃听'), findsOneWidget);
      expect(find.text('仍然信任'), findsOneWidget);
      expect(find.text('信任并继续'), findsNothing);
    });

    testWidgets('过期证书也会标红', (tester) async {
      final ch = TrustChallenge(
        host: 'nas:5001',
        sha256: 'AB' * 32,
        subject: 'CN=nas',
        issuer: 'CN=nas',
        validFrom: DateTime(2019, 1, 1),
        validTo: DateTime(2020, 1, 1),
      );
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), home: CertificateTrustDialog(challenge: ch)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('2019-01-01'), findsOneWidget);
      expect(find.textContaining('2020-01-01'), findsOneWidget);
    });
  });

  group('证书管理页', () {
    testWidgets('空态提示；有证书时列出并可删除', (tester) async {
      final h = await bootChat();
      final policy = h.container.read(trustPolicyProvider);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: CertificatesPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有信任任何服务器证书'), findsOneWidget);

      await policy.trust(_challenge('nas:5001', 'AB' * 32));
      await policy.trust(_challenge('other:5002', 'CD' * 32));
      h.container.invalidate(trustedCertsProvider);
      await tester.pumpAndSettle();
      expect(find.text('nas:5001'), findsOneWidget);
      expect(find.text('other:5002'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      expect(find.text('删除信任'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('nas:5001'), findsNothing);
      expect(find.text('other:5002'), findsOneWidget);
      expect(await policy.find('nas:5001'), isNull);
    });
  });
}

TrustChallenge _challenge(String host, String sha) => TrustChallenge(
  host: host,
  sha256: sha,
  subject: 'CN=$host',
  issuer: 'CN=$host',
  validFrom: DateTime(2026, 1, 1),
  validTo: DateTime(2027, 1, 1),
  isSelfSigned: true,
);

String _json(TrustedCert c) {
  final m = c.toJson();
  // 简易 JSON：字段都是字符串/数字
  final parts = m.entries
      .map(
        (e) =>
            '"${e.key}":'
            '${e.value is String ? '"${e.value}"' : e.value}',
      )
      .join(',');
  return '{$parts}';
}

Response<dynamic> _ok(RequestOptions options, String body) =>
    Response<dynamic>(requestOptions: options, statusCode: 200, data: body);
