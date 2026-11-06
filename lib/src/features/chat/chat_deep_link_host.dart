// 聊天深链的**消费端**（审计行 262）：接住原生送来的 [ChatDeepLink]，
// 按官方 `SplashActivity.enter()` 的落点规则处理。
//
// 官方规则（反编译 `ui/activity/SplashActivity.java:54-70`）：
//   * 没有已保存账号 → 把 URI + extras 原样交给 `LoginActivity`（登录页预填）；
//   * **有已保存账号 → 直接进主界面，深链丢弃**（不切服务器、不预填）。
//
// 我们照此实现：未登录 → 写 [chatDeepLinkPrefillProvider] 并跳登录页；
// 已登录 → 不作任何动作。挂载方式与「分享到 Chat」的 `ShareIntentHost` 同款
// （包住子树的 `ConsumerStatefulWidget`，见 `channel_list_page.dart`）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_routes.dart';
import '../servers/session_controller.dart';
import 'chat_deep_link.dart';

class ChatDeepLinkHost extends ConsumerStatefulWidget {
  const ChatDeepLinkHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ChatDeepLinkHost> createState() => _ChatDeepLinkHostState();
}

class _ChatDeepLinkHostState extends ConsumerState<ChatDeepLinkHost> {
  StreamSubscription<ChatDeepLink>? _sub;
  ChatDeepLink? _pending;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final source = ref.read(chatDeepLinkSourceProvider);
    _sub = source.incoming.listen(_enqueue);
    // 冷启动：Activity 起来时带来的深链（`getPending` 取完即清）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = await source.takePending();
      if (pending != null) _enqueue(pending);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _enqueue(ChatDeepLink link) {
    _pending = link;
    _maybeHandle();
  }

  /// 会话状态就绪后处理。没有专门的"恢复中"信号（`SessionState.restoring`
  /// 只在异常出口被置位），所以判据就是官方那一条：**已登录 → 丢弃**。
  void _maybeHandle() {
    if (_busy || !mounted || _pending == null) return;
    final link = _pending!;
    _pending = null;
    _busy = true;
    _handle(link).whenComplete(() {
      _busy = false;
      if (_pending != null) _maybeHandle();
    });
  }

  Future<void> _handle(ChatDeepLink link) async {
    final session = ref.read(sessionControllerProvider);
    if (!chatDeepLinkShouldApply(loggedIn: session.loggedIn)) {
      // 官方：已登录 → 丢弃（`SplashActivity.enter` 有 MyAccount 时直接进主界面）
      return;
    }
    ref.read(chatDeepLinkPrefillProvider.notifier).set(link);
    if (!mounted) return;
    // 单测里可能没有 GoRouter（只搭 MaterialApp）→ 别为了跳转把用例打挂
    final router = GoRouter.maybeOf(context);
    if (router != null && router.state.uri.path != AppRoutes.login) {
      context.go(AppRoutes.login);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 会话状态变化后再试一次（例如冷启动恢复登录完成后，把积压的深链判掉）
    ref.listen(sessionControllerProvider, (_, _) => _maybeHandle());
    return widget.child;
  }
}
