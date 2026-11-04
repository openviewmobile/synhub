// ★★★ **管理员门控**（用户 2026-09-23 新规 · 第 73 轮）
//
// 新规 R2/R3：
// * 非管理员登录 ⇒ 所有管理员功能**隐藏不展示**；
// * 管理员登录 ⇒ 正常展示。
//
// ## 为什么必须集中在这里（不能各页面自己判）
// 如果每个页面自己写 `if (isAdmin)`，那么
// **漏掉的那几处就是 R2 的破口**，而且没人会发现 ——
// 因为漏掉的表现是"非管理员也能看到管理入口"，
// 而日常开发我们都用管理员账号。
//
// ⇒ 全仓**只允许**通过本文件的 [AdminOnly] / [isAdminProvider] 判定。
// 新增管理入口时挂 [AdminOnly] 即可，不需要知道身份从哪来。
//
// ## 失败方向：**fail-closed**（一律藏）
// 身份还在查 / 查失败 / 未连接 ⇒ **一律不显示**。
// 理由与新规 R2 一致：宁可让管理员在弱网下**暂时**看不到管理入口
// （刷新即恢复），也不能让非管理员看到（那是权限泄漏的既视感）。
// 反过来的取舍会"看起来更好用"，但方向是错的。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_identity.dart';
import 'admin_gaps_text.dart';

// 身份从哪来的问题由 `admin_identity.dart` 负责（会话级缓存、登录后加载、
// 三棒接力）。本文件只负责**门控的显示语义**。
export 'admin_identity.dart'
    show
        isAdminProvider,
        adminIdentityProvider,
        authExtraApiProvider,
        systemAdminApiProvider,
        AdminIdentity;

/// **只有管理员才看得见**的子树。
///
/// 用法：
/// ```dart
/// AdminOnly(child: DesignRowTile(title: Text('套件中心'), ...))
/// ```
///
/// 行为：
/// * 身份是 `true` ⇒ 渲染 [child]；
/// * 身份是 `false` / 还在查 / 查询失败 / 未连接 ⇒ 渲染 [fallback]
///   （默认 `SizedBox.shrink()`，即**什么都不显示**）。
///
/// [fallback] 一般**不要**用来显示"需要管理员权限"之类的提示 ——
/// 新规 R2 要求的是**隐藏**，不是"告诉你你不能用"。
/// （个别确实需要说明的场合可以传，但要在用例里写明理由。）
class AdminOnly extends ConsumerWidget {
  const AdminOnly({super.key, required this.child, this.fallback});

  final Widget child;

  /// 非管理员（或身份未知）时显示什么。默认什么都不显示。
  final Widget? fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final admin = ref.watch(isAdminProvider);
    // ★ fail-closed：`loading` 与 `error` 都走这里
    final visible = admin.value == true;
    if (!visible) return fallback ?? const SizedBox.shrink();
    return child;
  }
}

/// 非 widget 场合（菜单项列表、路由表）用的判定。
///
/// [isAdminProvider] 还没出结果时返回 `false`（同样 fail-closed）。
bool adminOnlyVisible(WidgetRef ref) =>
    ref.watch(isAdminProvider).value == true;

/// 给"整个页面"用的门控：非管理员进入时给一句说明并允许返回。
///
/// 与 [AdminOnly] 的区别：这里**不是**隐藏（页面已经被路由到了），
/// 而是明确告知"需要管理员权限"。用户新规 R2 针对的是**入口的展示**；
/// 若有人已经进了深链，给一句说明比白屏好。
///
/// ⚠️ 这类页面**不应该**出现在非管理员的任何导航里 ——
/// 本 widget 只是深链/竞态下的兜底，不是"入口可以摆出来"的许可。
class AdminPageGate extends ConsumerWidget {
  const AdminPageGate({super.key, required this.child, this.title});

  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final admin = ref.watch(isAdminProvider);
    if (admin.value == true) return child;
    return Scaffold(
      key: const Key('admin-page-gate'),
      appBar: AppBar(title: Text(title ?? '')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            adminGap(AdminGapTextKeys.adminOnlyNeedsAdmin, '需要管理员权限才能查看此页面。'),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
