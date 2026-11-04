// 聊天深链（审计行 262）—— `synochat:` / `synochats:` / `synochatGuest:` /
// `synochatsGuest:` 四条 scheme 的**接收 + 登录页预填**。
//
// ## 官方证据（SynologyChat 2.11.1，当前真机安装版 2.11.1-607）
//
// ### ① 真机 intent-filter（`adb shell dumpsys package com.synology.dschat`）
//
// ```
// cc4aac7 com.synology.dschat/.ui.activity.SplashActivity filter f2fd81d
//   Action: "android.intent.action.VIEW"
//   Category: "android.intent.category.DEFAULT"
//   Category: "android.intent.category.BROWSABLE"
//   Scheme: "synochat"
//   Scheme: "synochats"
//   Scheme: "synochatGuest"
//   Scheme: "synochatsGuest"
// ```
//
// **没有** authority / path 约束（BROWSABLE 纯 scheme 过滤器）。同一个住院表里另有一条
// `synology-chat` = `net.openid.appauth.RedirectUriReceiverActivity`
// （authority `account`、`dsm`，path 字面量 `/login`）——那是 **OpenID Connect 的
// OAuth 回跳**（AppAuth 库自己的 receiver），**不是**登录预填深链，本模块不消费它。
//
// ### ② 参数解析（反编译 `ui/activity/LoginActivity.java:116-146`，
//    baksmali 二次核对 `LoginActivity.smali` 的 `.line 139-145`）
//
// ```java
// private void fillInData(Intent intent) {
//     if (TextUtils.equals(intent.getScheme(), "synochat")
//             || TextUtils.equals(intent.getScheme(), "synochats")
//             || TextUtils.equals(intent.getScheme(), "synochatGuest")
//             || TextUtils.equals(intent.getScheme(), "synochatsGuest")) {
//         String address = intent.getStringExtra("address");   // .line 139
//         String account = intent.getStringExtra("account");   // .line 140
//         boolean https = TextUtils.equals(intent.getScheme(), "synochats")
//                 || TextUtils.equals(intent.getScheme(), "synochatsGuest"); // .line 141
//         this.mAddressText.setText(address);
//         this.mAccountText.setText(account);
//         this.mHttpsBox.setChecked(https);                    // .line 144
//         this.mGuestBox.setChecked(true);                     // .line 145 — **无条件 true**
//         return;
//     }
//     // 否则用本地 PreferencesHelper.getInputField() 预填（上次填的地址/账号）
// }
// ```
//
// ⚠️ 两个**容易照抄错**的点（我们的旧审计文档写错了，这里以 smali 为准）：
//
// 1. 参数是 **Android Intent extras** `address` / `account`，**不是 URI 查询串**；
//    URI 本身（host/path）**完全不被读取**（真机过滤器也没有 path 约束）。
// 2. `mGuestBox.setChecked(true)` 是**无条件**的（smali `const/4 v4, 0x1` +
//    `invoke-virtual {p0, v4}, CheckBox;->setChecked(Z)`），即**四条 scheme 都会勾上
//    "访客登录"**。这是官方行为，不是反编译误差（jadx 与 baksmali 一致）。
//    但本行（262）只负责深链；"访客登录"本身是审计行 **261**（`SYNO.SAS.Guest/stat`
//    v1，本批未授权实现且证据不足）→ 我们**只解析并保留** `guest` 标志，
//    **不臆断**、不据此发起访客登录（否则等于偷偷替 261 下一个错误结论）。
//
// ### ③ 落点（`ui/activity/SplashActivity.java:54-70` `enter(MyAccount)`）
//
// ```java
// if (myAccount == null) {                     // 没有已保存的账号 → 去登录页
//     Intent intent = new Intent(this, LoginActivity.class);
//     intent.setData(getIntent().getData());   // URI 原样带过去
//     if (getIntent().getExtras() != null) intent.putExtras(getIntent().getExtras());
//     startActivity(intent);
// } else {                                     // **有已保存账号 → 直接进主界面，深链被丢弃**
//     Intent intent3 = new Intent(this, MainActivity.class);
//     startActivity(intent3);
// }
// ```
//
// 即：**已登录时深链不生效**（不会切服务器、不会预填）。`LoginActivity` 同时实现了
// `onNewIntent` → 登录页已经在前台时再来一条深链会**重新预填表单**。
//
// ## 我方落地
//
// * [ChatDeepLink]：官方 `fillInData` 的逐字等价物（含 `synochats*` → https、
//   `guest` 无条件 true 这个官方行为的**显式记录**）。
// * [ChatDeepLinkSource]：从原生取意图载荷（通道 `synhub/deep_link`，
//   与既有 `synhub/share_intent` 同构；单测注入假源）。
// * [ChatDeepLinkHost]：消费深链 → 写 [chatDeepLinkPrefillProvider] →
//   未登录时跳登录页；已登录时按官方**丢弃**（`SplashActivity.enter` 同款）。
// * 登录页真正把预填写进输入框（官方 `mAddressText.setText` / `mAccountText.setText`
//   / `mHttpsBox` / `mGuestBox` 四行）**需要登录页读一次
//   [chatDeepLinkPrefillProvider]** —— `lib/src/features/login/login_page.dart` 与
//   Android 清单/Kotlin 桥都不在本批可改范围（见
//   `docs/chat-note-gaps-implementation-report.md` 的"边界外交接"一节，已给出
//   可直接套用的补丁）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';

/// 官方四条深链 scheme（真机 `dumpsys` 住院表实测，见文件头注释）
const String kChatDeepLinkScheme = 'synochat';
const String kChatDeepLinkSecureScheme = 'synochats';
const String kChatDeepLinkGuestScheme = 'synochatGuest';
const String kChatDeepLinkSecureGuestScheme = 'synochatsGuest';

/// 四条 scheme 的集合（顺序与官方 `fillInData` 的判断顺序一致）
const Set<String> kChatDeepLinkSchemes = {
  kChatDeepLinkScheme,
  kChatDeepLinkSecureScheme,
  kChatDeepLinkGuestScheme,
  kChatDeepLinkSecureGuestScheme,
};

/// `synology-chat`：官方是 **OAuth 回跳**（AppAuth 的 `RedirectUriReceiverActivity`），
/// 不是登录预填深链 → 本模块只识别、不消费（识别出来是为了"不误吞"）。
const String kChatOAuthRedirectScheme = 'synology-chat';

/// 原生载荷里可能出现的键（`DeepLinkBridge` 约定；`uri` 是 extras 缺失时的兜底）
const String kChatDeepLinkKeyScheme = 'scheme';
const String kChatDeepLinkKeyAddress = 'address';
const String kChatDeepLinkKeyAccount = 'account';
const String kChatDeepLinkKeyUri = 'uri';

/// 一次聊天深链的解析结果（= 官方 `fillInData` 里那四个控件要设的值）。
@immutable
class ChatDeepLink {
  const ChatDeepLink({
    required this.scheme,
    this.address = '',
    this.account = '',
  });

  /// 命中的 scheme（一定是 [kChatDeepLinkSchemes] 之一）
  final String scheme;

  /// `intent.getStringExtra("address")`；缺失 = `''`（官方拿到 null → 置空）
  final String address;

  /// `intent.getStringExtra("account")`；缺失 = `''`
  final String account;

  /// `synochats` / `synochatsGuest` → 勾选 HTTPS（官方 `.line 141`）
  bool get secure =>
      scheme == kChatDeepLinkSecureScheme ||
      scheme == kChatDeepLinkSecureGuestScheme;

  /// ⚠️ 官方对**四条 scheme 一律**勾访客登录（`LoginActivity.java:145`）。
  /// 保留这个标志只为如实记录官方行为；访客登录本身是审计行 261，本批不实现。
  bool get guest => true;

  /// 是否带上了可用的登录预填（地址或账号任一非空）
  bool get hasLoginPrefill => address.isNotEmpty || account.isNotEmpty;

  /// 官方 `LoginActivity.fillInData(Intent)` 的等价物。
  ///
  /// * `scheme` 不是四条之一（含 null / 空串 / `synology-chat` 的 OAuth 回跳）
  ///   → 返回 `null`（官方会落到"用本地偏好预填"那条分支，不是深链）；
  /// * 只认 `address` / `account` 两个键，**不解析 URI 的 host/path/query**
  ///   （官方同样不解析）。
  static ChatDeepLink? fromIntentData(Map<Object?, Object?> data) {
    final rawScheme = data[kChatDeepLinkKeyScheme];
    var scheme = rawScheme is String ? rawScheme : '';
    if (scheme.isEmpty) {
      // 兜底：原生只给了 URI（浏览器/邮件链接那种，没有 extras）→ 取 URI 的 scheme
      final rawUri = data[kChatDeepLinkKeyUri];
      if (rawUri is String && rawUri.isNotEmpty) {
        scheme = Uri.tryParse(rawUri)?.scheme ?? '';
      }
    }
    if (!kChatDeepLinkSchemes.contains(scheme)) return null;
    final address = data[kChatDeepLinkKeyAddress];
    final account = data[kChatDeepLinkKeyAccount];
    return ChatDeepLink(
      scheme: scheme,
      address: address is String ? address : '',
      account: account is String ? account : '',
    );
  }

  /// 纯 URI 形态（浏览器/邮件链接只能带 URI，带不了 extras）。
  ///
  /// 与官方一致：URI 的内容**不被读取**，所以 `address` / `account` 为空，
  /// 只有 scheme 决定 https / guest。要带地址和账号，链接方必须设置 intent extras。
  static ChatDeepLink? fromUri(Uri uri) =>
      fromIntentData({kChatDeepLinkKeyScheme: uri.scheme});

  /// 调试 / 测试用文本（不含任何凭据）
  @override
  String toString() =>
      'ChatDeepLink($scheme, address=$address, account=$account, '
      'secure=$secure, guest=$guest)';
}

/// 深链载荷来源（测试里换成假实现）。
abstract class ChatDeepLinkSource {
  /// 取走并清空当前待处理的深链（没有则 null）
  Future<ChatDeepLink?> takePending();

  /// App 已在前台时，新的深链会从这里推过来
  Stream<ChatDeepLink> get incoming;

  void dispose();
}

/// 真实现：MethodChannel `synhub/deep_link`（与 `ShareIntentBridge` 同构：
/// 原生只发一个"有新深链"的空提醒，真正取载荷统一走 `getPending`）。
class MethodChannelChatDeepLinkSource implements ChatDeepLinkSource {
  MethodChannelChatDeepLinkSource([MethodChannel? channel])
    : _channel =
          channel ?? const MethodChannel('synhub/deep_link') {
    // 第 55 轮：只在"能力层放行"时注册监听（Android 才有的桥）。
    if (!capabilityGateAllows(AppCapability.deepLink)) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onDeepLink') return null;
      final link = await takePending();
      if (link != null && !_events.isClosed) _events.add(link);
      return null;
    });
  }

  final MethodChannel _channel;
  final _events = StreamController<ChatDeepLink>.broadcast();

  @override
  Stream<ChatDeepLink> get incoming => _events.stream;

  @override
  Future<ChatDeepLink?> takePending() async {
    // 第 55 轮：`synhub/deep_link` 只有 Android 侧实现 ⇒ 先问能力层，
    // 宿主上如实报"未实现"，别把 MissingPluginException 冒到界面。
    if (!capabilityGateAllows(AppCapability.deepLink)) {
      debugPrint(
        capabilityGateLog(AppCapability.deepLink, 'deep_link.getPending'),
      );
      return null;
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('getPending');
      if (raw is! Map) return null;
      return ChatDeepLink.fromIntentData(Map<Object?, Object?>.from(raw));
    } catch (e) {
      // 平台上没有这个 channel（纯桌面/单测）不是错误
      debugPrint('[deeplink] getPending 失败：$e');
      return null;
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    if (!_events.isClosed) _events.close();
  }
}

final chatDeepLinkSourceProvider = Provider<ChatDeepLinkSource>((ref) {
  final source = MethodChannelChatDeepLinkSource();
  ref.onDispose(source.dispose);
  return source;
});

/// 最近一次深链解析出的**登录预填**（官方 `fillInData` 写进四个控件的那套值）。
///
/// 登录页读它即可完成官方那四行（`mAddressText` / `mAccountText` / `mHttpsBox` /
/// `mGuestBox`）；读完置 null 由消费方负责（或留着也无害，页面只在自己的
/// `initState` 读一次）。
///
/// Riverpod 3.x 已移除 `StateProvider`，这里用最朴素的 `Notifier`（同
/// `channel_scheduled_page.dart` 的 `scheduleRevisionProvider`）。
final chatDeepLinkPrefillProvider =
    NotifierProvider<ChatDeepLinkPrefill, ChatDeepLink?>(
      ChatDeepLinkPrefill.new,
    );

class ChatDeepLinkPrefill extends Notifier<ChatDeepLink?> {
  @override
  ChatDeepLink? build() => null;

  /// 记下一次深链预填；消费方读完可 [clear]
  void set(ChatDeepLink link) => state = link;

  void clear() => state = null;
}


/// 官方 `SplashActivity.enter()` 的落点判定：**已登录 → 丢弃**（进主界面），
/// 未登录 → 深链生效（预填登录页）。抽成纯函数便于离线断言。
bool chatDeepLinkShouldApply({required bool loggedIn}) => !loggedIn;
