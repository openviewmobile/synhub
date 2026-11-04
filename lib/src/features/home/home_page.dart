import 'package:flutter/material.dart';

import '../shell/app_shell_page.dart';

/// 主页 = 应用外壳（`聊天 · 文件 · 相册 · 工作台 · 我的`）。
///
/// Phase 0/1 时这里只是「登录成功」的占位页；Phase 2 起由 [ChannelListPage]
/// 接管；P0 批次起换成带底栏的外壳（[AppShellPage]），聊天仍是默认 tab
/// （见 docs/client-station-plan.md §5）。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => const AppShellPage();
}
