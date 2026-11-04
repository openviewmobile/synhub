// 底栏 tab 定义 + **纯函数** tab 可见性规则（呈现层 S1，见设计 §2.3）。
//
// 从 `app_shell_page.dart` 拆出来单独成文件，是为了让 [visibleTabs] 能被
// **纯单测**直接调用（不 pump 整个外壳），也让 shell 的 index 计算只依赖
// 这一个真相来源 —— 固定 enum + 固定 index 的错位隐患在这里被消除。
import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/services/service_registry.dart';

/// 底栏 tab。
///
/// 前三个是**主槽**（chat/files/photos，受服务可用性影响）；
/// `workspace` / `me` **始终保留**；`home` 只在三个主服务全不可用时出现
/// （受限模式首页）；其余是顶替主槽的模块 tab（顶替者自身必须 available）。
enum AppTab {
  chat(Icons.forum_outlined, Icons.forum),
  files(Icons.folder_outlined, Icons.folder),
  photos(Icons.photo_library_outlined, Icons.photo_library),
  workspace(Icons.grid_view_outlined, Icons.grid_view),
  me(Icons.person_outline, Icons.person),

  // ---- 受限模式首页（三个主服务全不可用时）
  home(Icons.home_outlined, Icons.home),

  // ---- 顶替主槽的模块（按 kReplacementOrder）
  note(Icons.sticky_note_2_outlined, Icons.sticky_note_2),
  calendar(Icons.event_outlined, Icons.event),
  contacts(Icons.contacts_outlined, Icons.contacts),
  drive(Icons.cloud_outlined, Icons.cloud),
  download(Icons.download_outlined, Icons.download),
  audio(Icons.library_music_outlined, Icons.library_music),
  surveillance(Icons.videocam_outlined, Icons.videocam),
  mailplus(Icons.mail_outline, Icons.mail);

  const AppTab(this.icon, this.activeIcon);
  final IconData icon;
  final IconData activeIcon;

  /// 是否内容型 tab（用于"最近常用"记账；工作台/我的/首页不算）。
  bool get isContent =>
      this != AppTab.workspace && this != AppTab.me && this != AppTab.home;

  String labelIn(AppText t) => switch (this) {
    AppTab.chat => t.navChat,
    AppTab.files => t.navFiles,
    AppTab.photos => t.navPhotos,
    AppTab.workspace => t.navWorkspace,
    AppTab.me => t.navMe,
    AppTab.note => t.wsNotes,
    AppTab.calendar => t.wsCalendar,
    AppTab.contacts => t.wsContacts,
    AppTab.download => t.dsTitle,
    AppTab.audio => t.asTitle,
    AppTab.surveillance => t.survTitle,
    AppTab.mailplus => t.mailTitle,
    AppTab.home => t.navHome,
    AppTab.drive => t.navDrive,
  };
}

/// 主槽 tab ↔ 服务的双向映射（只有这三个服务占主槽）。
const Map<StationService, AppTab> kPrimaryTabByService = {
  StationService.chat: AppTab.chat,
  StationService.file: AppTab.files,
  StationService.photo: AppTab.photos,
};

/// 服务 → 顶替 tab（[kReplacementOrder] 里的可呈现模块）。
const Map<StationService, AppTab> kReplacementTabByService = {
  StationService.note: AppTab.note,
  StationService.calendar: AppTab.calendar,
  StationService.contacts: AppTab.contacts,
  StationService.drive: AppTab.drive,
  StationService.download: AppTab.download,
  StationService.audio: AppTab.audio,
  StationService.surveillance: AppTab.surveillance,
  StationService.mailplus: AppTab.mailplus,
};

/// 主槽 tab 对应的服务。
StationService? primaryServiceForTab(AppTab tab) {
  for (final e in kPrimaryTabByService.entries) {
    if (e.value == tab) return e.key;
  }
  return null;
}

/// tab 对应的服务（主槽 + 顶替模块；workspace / me / home 返回 null）。
///
/// 用来给**所有**模块 tab 统一判定 `sessionExpired` / `unreachable`：
/// 会话一过期，不管当前在哪个模块，都显示同一句"会话已过期，请重新登录"。
StationService? serviceForTab(AppTab tab) {
  final primary = primaryServiceForTab(tab);
  if (primary != null) return primary;
  for (final e in kReplacementTabByService.entries) {
    if (e.value == tab) return e.key;
  }
  return null;
}

/// 三个主槽服务（顺序即候选顺序）。
const List<StationService> kPrimaryServices = [
  StationService.chat,
  StationService.file,
  StationService.photo,
];

/// 被隐藏的主槽服务（`absent` 未安装 / `unauthorized` 无权限）。
List<StationService> hiddenPrimaryServices(
  Map<StationService, AvailabilityState> states,
) => [
  for (final s in kPrimaryServices)
    if (hidesModule(states[s] ?? AvailabilityState.unknown)) s,
];

/// **纯函数**：由服务状态算出底栏可见 tab 列表（可单测，设计 §2.3 / §3）。
///
/// 规则：
///   * 固定候选顺序 `[chat, files, photos]`，`workspace` / `me` 始终保留；
///   * 主服务 `absent`（未安装）或 `unauthorized`（无权限）→ 该 tab 隐藏；
///   * **`sessionExpired`（119/106）/ `unreachable` / `unknown` / `partial`
///     一律保留**——会话一过期就隐藏会让整个 App 变空白；
///   * 主槽少于 3 个 → 从 `kReplacementOrder` 里按顺序顶替，**顶替者自身必须
///     `available`**；
///   * 三个主服务全隐藏 → 受限模式首页（`AppTab.home`）+ workspace / me；
///   * [showHidden] = 用户在「设置 → 服务检测」打开的"临时显示隐藏的模块"
///     安全阀：为 true 时即使 `absent` / `unauthorized` 也恢复可见。
List<AppTab> visibleTabs(
  Map<StationService, AvailabilityState> states, {
  bool showHidden = false,
}) {
  AvailabilityState stateOf(StationService s) =>
      states[s] ?? AvailabilityState.unknown;
  bool hidden(StationService s) => !showHidden && hidesModule(stateOf(s));

  final primary = <AppTab>[];
  for (final service in kPrimaryServices) {
    if (!hidden(service)) primary.add(kPrimaryTabByService[service]!);
  }

  // 三个主服务全隐藏 → 受限模式首页（不再顶替内容 tab）。
  if (primary.isEmpty) {
    return const [AppTab.home, AppTab.workspace, AppTab.me];
  }

  final tabs = [...primary];
  for (final service in kReplacementOrder) {
    if (tabs.length >= 3) break;
    final tab = kReplacementTabByService[service];
    if (tab == null) continue;
    if (stateOf(service) != AvailabilityState.available) continue; // 顶替者必须自身可用
    tabs.add(tab);
  }
  tabs.add(AppTab.workspace);
  tabs.add(AppTab.me);
  return tabs;
}

/// 服务的显示名（服务检测页 / 受限模式首页用）。
///
/// 主槽与顶替模块复用底栏 label；office / ai 是拉丁品牌名，直接给出。
String serviceLabelIn(AppText t, StationService service) {
  final primary = kPrimaryTabByService[service];
  if (primary != null) return primary.labelIn(t);
  final replacement = kReplacementTabByService[service];
  if (replacement != null) return replacement.labelIn(t);
  return switch (service) {
    StationService.office => 'Office',
    StationService.ai => 'AI',
    _ => service.name,
  };
}
