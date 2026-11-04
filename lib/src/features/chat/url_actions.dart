// 点链接的行为 —— 逐条对齐 APK 的 `util/UrlUtil.java`。
//
// 原版 `UrlUtil.viewUrlOrJumpChannel(context, url, db)`：
//   ① 先试 `jumpChannel()`：**只有**「同一台服务器」或「QuickConnect 域名」的链接、
//      且 fragment 形如 `channels/<id>`（大小写不敏感）才算频道链接 → 跳到频道；
//      频道不在本地库 → 提示"私密频道"；频道存在但没加入 → 提示"未加入"。
//   ② 否则 `openWebPage()`：`ACTION_VIEW` 丢给浏览器（外部打开）。
//
// 我们另外把「消息正文里的 URL 点击」也接到这里 —— 之前只是弹个
// "Phase 5 接入打开" 的提示，属于欠账。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/l10n.dart';
import '../../core/system_open.dart';

import '../../core/router/app_routes.dart';
import '../chat/chat_session_controller.dart';

/// fragment `channels/<id>` → 频道 id；不是频道链接就返回 null。
///
/// 原版 `isValidChannelFragment`：前缀 `channels/`（大小写不敏感），
/// 后面必须能解析成整数（`fragment.substring(9)` → 注意 `channels/` 是 9 个字符）。
int? channelIdFromFragment(String fragment) {
  if (fragment.isEmpty) return null;
  final lower = fragment.toLowerCase();
  if (!lower.startsWith('channels/')) return null;
  return int.tryParse(fragment.substring(9));
}

/// 这个 URL 指向"本机服务器"吗（原版 `isSameHost && isSamePath && isSamePort`
/// 或 QuickConnect 域名判断）。
bool isServerLink(String url, {required String baseUrl}) {
  final target = Uri.tryParse(url);
  final base = Uri.tryParse(baseUrl);
  if (target == null || base == null) return false;
  final lo = target.host.toLowerCase();
  final bo = base.host.toLowerCase();
  if (lo.isEmpty || bo.isEmpty) return false;
  // QuickConnect：主机是 <id>.quickconnect.to / .quickconnect.cn
  bool qc(String host) =>
      host.endsWith('.quickconnect.to') || host.endsWith('.quickconnect.cn');
  if (qc(bo)) {
    final id = bo.split('.').first;
    return qc(lo) && lo.startsWith('$id.');
  }
  final samePort =
      target.port == 0 || base.port == 0 || target.port == base.port;
  return lo == bo &&
      samePort &&
      _stripSlashes(target.path) == _stripSlashes(base.path);
}

String _stripSlashes(String s) {
  var out = s;
  while (out.startsWith('/')) {
    out = out.substring(1);
  }
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// 频道链接 → 频道 id（不是频道链接返回 null）
int? channelIdFromLink(String url, {required String baseUrl}) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (!isServerLink(url, baseUrl: baseUrl)) return null;
  return channelIdFromFragment(uri.fragment);
}

/// 点一个链接：能跳频道就跳，否则丢给系统浏览器。
///
/// [knownChannelIds] 用来判断频道在不在本地库（原版查 DB）；
/// 传 null 表示"都当已知"（例如从频道列表点进来时）。
Future<void> openUrlOrJumpChannel(
  BuildContext context,
  String url, {
  required String baseUrl,
  Set<int>? knownChannelIds,

  /// ★ 这条消息被服务端标成"含恶意链接"（`post.props.safe_url == false`）。
  ///
  /// 官方在**打开前**多一层确认：`unsafe_website_confirm_open`
  /// （原文：「以下网站可能由 Google 安全浏览归类为恶意网站。我们建议您不要
  /// 访问它。是否确定要打开它？」）。**用户点"仍然打开"才真的打开。**
  /// 我方原先只有横幅提示（`chatLinkRisky`）、**没有这层确认** —— 本轮按官方补齐。
  ///
  /// ⚠️ 只拦"丢给外部浏览器"这一条路；**本机频道链接不受影响**
  /// （官方也是先 `jumpChannel()` 再 `openWebPage()`，安全提示只针对后者）。
  bool unsafe = false,
}) async {
  final t = context.t;
  final channelId = channelIdFromLink(url, baseUrl: baseUrl);
  if (channelId != null) {
    if (knownChannelIds != null && !knownChannelIds.contains(channelId)) {
      _toast(context, t.chatErrChannelNotInList);
      return;
    }
    context.push(AppRoutes.chatOf(channelId));
    return;
  }
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) {
    _toast(context, t.chatErrCannotOpenLink(url));
    return;
  }
  if (unsafe) {
    final confirmed = await _confirmUnsafe(context);
    if (!confirmed) return;
    if (!context.mounted) return;
  }
  var ok = false;
  try {
    // 测试环境不启动浏览器（见 `core/system_open.dart`）
    ok = isTestEnvironment
        ? false
        : await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) _toast(context, t.chatErrNoAppForLink);
}

/// 打开不安全链接前的确认（官方 `unsafe_website_confirm_open`）。
///
/// 返回 `true` = 用户坚持要打开。取消 / 点外部 → `false`。
/// ⚠️ 文案用官方原文（zh 取自 APK `values-zh-rCN/strings.xml`，
/// en 取自 `values/strings.xml`），**不是我编的**。
Future<bool> _confirmUnsafe(BuildContext context) async {
  final t = context.t;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: Text(t.chatLinkRisky),
      content: Text(t.chatUnsafeWebsiteConfirmOpen),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(false),
          child: Text(t.chatUnsafeWebsiteCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dctx).pop(true),
          child: Text(t.chatUnsafeWebsiteOpen),
        ),
      ],
    ),
  );
  return ok ?? false;
}

void _toast(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// 从 Controller 里读服务器地址（判断"是不是本机链接"要用）
String baseUrlOf(WidgetRef ref) =>
    ref.read(chatSessionControllerProvider).baseUrl;
