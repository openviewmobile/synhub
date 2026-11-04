// QuickConnect 解析的**重试**行为（离线，注入假 ServApi）。
//
// 为什么要有这个：真机连跑多轮集成测试时遇到过
// `ServApiException(所有 relay_servers 都查询失败 → cnc.quickconnect.cn:
// Connection reset by peer)` —— 控制服务器抖一下，用户就登不上。
// 现在整轮失败后会隔一小会儿再解析一轮（见 `_resolveQuickConnectWithRetry`）。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/quickconnect/serv_api.dart';

/// 前 [failCount] 次 `resolve` 直接失败，之后返回一个"能解析出候选地址"的 DsmInfo。
class _FlakyServApi extends ServApi {
  _FlakyServApi(this.failCount, {this.alwaysFail = false});

  final int failCount;
  final bool alwaysFail;
  int calls = 0;
  bool closed = false;

  @override
  Future<DsmInfo> resolve({
    required String serverId,
    required String serviceId,
    String? externalIp,
  }) async {
    calls++;
    if (alwaysFail || calls <= failCount) {
      throw ServApiException('假的失败（第 $calls 次）');
    }
    return DsmInfo.fromJson(const {
      'relay_servers': <String>[],
      'service': {'port': 5001, 'extPort': 0},
      'server': {'external': 'nas.example.com', 'udp_punch_port': 0},
    });
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  const profile = ServerProfile(
    kind: ServerAddressKind.quickConnect,
    value: 'demo_admin-qq',
  );

  test('第一轮失败 → 等一会儿再来一轮（第二轮成功）', () async {
    final fake = _FlakyServApi(1);
    final service = ConnectionService(
      servApiFactory: () => fake,
      qcRetryDelay: const Duration(milliseconds: 1),
      probeTimeout: const Duration(milliseconds: 200),
    );

    final steps = <String>[];
    // 候选地址是假的，探测一定失败 —— 这里只关心"解析重试"这件事
    await expectLater(
      service.connect(profile, onStep: (s) => steps.add(s.text)),
      throwsA(isA<StateError>()),
    );

    expect(fake.calls, 2, reason: '第一轮失败后必须补一轮');
    expect(
      steps.any((s) => s.contains('QuickConnect 查询失败，稍后重试')),
      isTrue,
      reason: '重试要告诉用户（进度条上能看到）',
    );
    expect(
      steps.any((s) => s.contains('候选')),
      isTrue,
      reason: '第二轮成功 → 应该走到"列候选地址"',
    );
    expect(fake.closed, isTrue, reason: 'ServApi 是一次性的，解析完要关掉');
  });

  test('两轮都失败 → 把错误抛出去（不无限重试）', () async {
    final fake = _FlakyServApi(0, alwaysFail: true);
    final service = ConnectionService(
      servApiFactory: () => fake,
      qcRetryDelay: const Duration(milliseconds: 1),
    );

    await expectLater(
      service.connect(profile),
      throwsA(isA<ServApiException>()),
    );
    expect(fake.calls, 2, reason: '最多两轮，别把登录拖死');
    expect(fake.closed, isTrue);
  });
}
