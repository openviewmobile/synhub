// ★★★ r723 守卫：**生产的实时通道必须接首连信任策略**。
//
// 事故形状：`ChatSocket` 的 `allowSelfSigned` 默认 `true`，而
// `chatSocketFactoryProvider` 以前**不传任何裁决** ⇒ 实时通道对任何证书都放行，
// 与 HTTP 那条"Dio + TrustPolicy 指纹钉住"的安全等级不一致。
// 本用例只钉一件事：工厂产出的 socket 手上**有裁决**（不是默认放行）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

void main() {
  test('chatSocketFactoryProvider 产出的 ChatSocket 带 certVerifier', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final factory = container.read(chatSocketFactoryProvider);
    final socket = factory('https://nas.example.com:5001/', 'SID', null);
    addTearDown(socket.dispose);
    expect(
      socket.certVerifier,
      isNotNull,
      reason: '没接首连信任 ⇒ 自签/换证书一律放行（MITM 口子）',
    );
  });
}
