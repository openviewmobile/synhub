// Phase 9 真机验收：「收到消息通知时预加载消息」（原版 `PostPreviewWorker`）
//   + 回车发送偏好 + Android 侧的网络类型探针。
//
//   flutter test integration_test/phase9_preview_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 只有真机能回答的问题：
//   ① `NetworkBridge.kt`（ConnectivityManager）在真机上到底报什么 —— 单测里
//      平台通道永远是 `unknown`，那样"仅 Wi-Fi"这一档会永远不预加载；
//   ② 40+40 的请求形态 2.4.7 服务端认不认、`replaceChannelPosts` 落到真库里
//      是不是"替换主列表但保住本地待发消息"。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/net/network_type.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/notifications/notification_service.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：消息预加载 40+40 + 网络类型探针 + 偏好往返', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(account: _account, password: _password, session: 'Chat');

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);
    final store = container.read(chatStoreProvider);
    final settings = SettingsService(store);

    // ---------- ① 真机的网络类型（验 NetworkBridge.kt）----------
    final net = await container.read(networkTypeProbeProvider).current();
    debugPrint('[p9pv] 真机网络类型 = ${net.rawValue}');
    expect(net, isNot(NetworkType.unknown),
        reason: '平台通道没通（Kotlin 侧没注册/抛异常）→ ONLY_WIFI 档会永远不预加载');

    // ---------- ② 挑一个真有消息的频道 ----------
    // （本地库是新的，消息只有进过频道才会落库 —— 所以这里逐个试，
    //   服务端返回非空就继续；全是空频道就直接失败，别假装通过）
    final channels = await store.allChannels();
    expect(channels, isNotEmpty, reason: '本地库里得有频道（start() 会同步）');
    var picked = channels.first;
    var n = 0;
    for (final c in channels.take(8)) {
      n = await ctrl.prefetchChannelPosts(c.channelId);
      debugPrint('[p9pv] 试频道 #${c.channelId}「${c.name}」→ $n 条');
      if (n > 0) {
        picked = c;
        break;
      }
    }
    expect(n, greaterThan(0), reason: '真服务端该返回消息');

    // ---------- ③ 真拉 40+40 ----------
    debugPrint('[p9pv] 选定频道 #${picked.channelId}「${picked.name}」，prefetch → $n 条');

    final after = await store.postsForChannel(picked.channelId);
    debugPrint('[p9pv] 替换后主列表 ${after.length} 条，最新 post_id=${after.first.postId}');
    expect(after.length, greaterThanOrEqualTo(n - 1),
        reason: '拉回来的应该都进库了（可能有话题根被归并）');

    // 和服务端直接比一次"最新一条"：prefetch 之后本地最新应等于服务端最新
    final api = ctrl.chatApi!;
    final wire = await api.listPosts(
      channelId: picked.channelId,
      prevCount: 1,
      nextCount: 0,
      has: kPostHas,
    );
    // 服务端 `Post/list` 的返回顺序不保证（实测是**旧的在前**），取最大值
    final serverIds = wire
        .map((p) => (p['post_id'] as num?)?.toInt() ?? 0)
        .where((id) => id > 0);
    final serverNewest =
        serverIds.isEmpty ? 0 : serverIds.reduce((a, b) => a > b ? a : b);
    expect(after.first.postId, serverNewest,
        reason: '预加载后本地最新一条要跟服务端一致');

    // ---------- ④ 门禁：CLOSE 不发请求 / ONLY_WIFI 在真机（Wi-Fi）下要发 ----------
    final svc = NotificationService(
        container.read(notificationServiceProvider).ref,
        background: container.read(backgroundServiceProvider));

    await settings.setPostPreviewMode(PostPreviewMode.close);
    await container.read(postPreviewModeProvider.notifier).preload();
    expect(await svc.maybePrefetchPosts(picked.channelId), isFalse,
        reason: 'CLOSE 档不发');
    debugPrint('[p9pv] CLOSE 档 → 不预加载 ✓');

    await settings.setPostPreviewMode(PostPreviewMode.onlyWifi);
    await container.read(postPreviewModeProvider.notifier).preload();
    final onWifi = net.isWifi;
    final ok = await svc.maybePrefetchPosts(picked.channelId);
    expect(ok, onWifi,
        reason: onWifi ? 'Wi-Fi 下该预加载' : '非 Wi-Fi 下 ONLY_WIFI 不该预加载');
    debugPrint('[p9pv] ONLY_WIFI（wifi=$onWifi）→ 预加载=${ok ? "是" : "否"} ✓');

    // ---------- ⑤ 偏好往返（真库）----------
    final oldEnter = await settings.sendByEnter();
    final oldMode = await settings.postPreviewMode();
    await settings.setSendByEnter(!oldEnter);
    await settings.setPostPreviewMode(PostPreviewMode.wifiAndOther);
    expect(await settings.sendByEnter(), !oldEnter);
    expect(await settings.postPreviewMode(), PostPreviewMode.wifiAndOther);
    // 还原
    await settings.setSendByEnter(oldEnter);
    await settings.setPostPreviewMode(oldMode);
    expect(await settings.sendByEnter(), oldEnter);
    expect(await settings.postPreviewMode(), oldMode);
    debugPrint('[p9pv] 偏好往返 + 还原 ✓');

    debugPrint('[p9pv] ✅ 预加载 / 网络类型 / 偏好 验收完成');
  });
}
