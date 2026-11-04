// ★★ ③Drive 第 246 轮 **D66**：SAF「按需下载」的设置页。
//
// 这一页要解决的问题：provider 被系统文件选择器**冷启动**拉起时，
// Flutter 引擎不在场 ⇒ 它必须有自己的一份凭据才能登录 DSM 现下文件。
// 所以这一页把**当前已保存的登录凭据**（账号/密码）交给 Kotlin 侧
// （`DriveSafSession` 用 Android Keystore 的 AES/GCM 加密存），
// 并显示"能不能冷启动自己下"、缓存占用、以及清缓存入口。
//
// ⚠️ 密码是**逐字转交**给原生侧加密存储的，Dart 侧不落盘（`SavedSession`
// 本来就已经有 Keystore 保护的明文入口，这里只是把同一份交给 provider）。
// 未登录/没有保存密码时**如实提示**，不给一个点了没用的开关。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/app_sheet.dart';
import '../../core/i18n/l10n.dart';
import '../servers/session_controller.dart';
import 'drive_saf_session.dart';
import 'filestation_g4_text.dart';

/// 面板正文（公开是为了让组件用例直接挂它，不必去点弹层）。
///
/// 打开面板的入口是 [showDriveSafOnDemandSheet]。
/// 打开「SAF 按需下载」设置页。
Future<void> showDriveSafOnDemandSheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    title: fsG4(FsG4TextKeys.safOnDemandTitle, '系统选择器 · 按需下载'),
    children: const [DriveSafOnDemandBody()],
  );
}

class DriveSafOnDemandBody extends ConsumerStatefulWidget {
  const DriveSafOnDemandBody({super.key});

  @override
  ConsumerState<DriveSafOnDemandBody> createState() =>
      DriveSafOnDemandBodyState();
}

class DriveSafOnDemandBodyState extends ConsumerState<DriveSafOnDemandBody> {
  DriveSafStatus _status = DriveSafStatus.unavailable;
  bool _busy = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await ref.read(driveSafSessionProvider).status();
    if (mounted) setState(() => _status = s);
  }

  /// 把当前保存的会话交给原生侧（provider 冷启动用）。
  Future<void> _enable() async {
    // 当前会话快照（含"上次登录"里保存的凭据）
    final saved = ref.read(sessionControllerProvider).saved;
    if (saved == null || saved.password == null || saved.password!.isEmpty) {
      setState(
        () => _message = fsG4(
          FsG4TextKeys.safOnDemandNeedPassword,
          '这条记录没有保存密码（或密码解不开）⇒ 无法让系统选择器自己登录。'
          '请在登录时勾选"记住密码"后再启用。',
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final s = await ref
          .read(driveSafSessionProvider)
          .storeCredentials(
            baseUrl: saved.lastBaseUrl ?? saved.profile.normalizedBaseUrl,
            username: saved.account,
            password: saved.password!,
            deviceId: saved.deviceId ?? '',
            onDemand: true,
          );
      if (mounted) {
        setState(() {
          _status = s;
          _message = s.canColdStartDownload
              ? fsG4(
                  FsG4TextKeys.safOnDemandEnabled,
                  '已启用：系统「文件」里打开 Drive 的云端文件时会自动下载',
                )
              : fsG4(FsG4TextKeys.safOnDemandNotConfigured, '系统「文件」里仍显示未设置');
        });
      }
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable() async {
    setState(() => _busy = true);
    try {
      await ref.read(driveSafSessionProvider).clearCredentials();
      if (mounted) {
        setState(() {
          _status = DriveSafStatus.unavailable;
          _message = fsG4(FsG4TextKeys.safOnDemandDisabled, '已关闭并清除已保存的账号');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearCache() async {
    setState(() => _busy = true);
    try {
      final freed = await ref.read(driveSafSessionProvider).clearCache();
      await _refresh();
      if (mounted) {
        setState(
          () => _message = fsG4Fill(FsG4TextKeys.safOnDemandCacheCleared,
            '已释放缓存（约 $freed 字节）',
            {'freed': '$freed'},
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 原生侧保存的账号名；空 = 还不知道（不编一个假的）。
  String _safAccount(BuildContext context) => _status.username.isEmpty
      ? context.t.safOnDemandUnknownAccount
      : _status.username;

  @override
  Widget build(BuildContext context) {
    final on = _status.canColdStartDownload;
    return AppSheetSection(
      label: fsG4(FsG4TextKeys.safOnDemandSection, '系统「文件」集成'),
      children: [
        AppSheetAction(
          key: const Key('saf-on-demand-toggle'),
          icon: on ? Icons.cloud_done_outlined : Icons.cloud_download_outlined,
          label: on
              ? fsG4(FsG4TextKeys.safOnDemandTurnOff, '关闭按需下载')
              : fsG4(FsG4TextKeys.safOnDemandTurnOn, '启用按需下载'),
          description: on
              ? fsG4Fill(FsG4TextKeys.safOnDemandOnDesc,
                  '已配置：打开云端文件时会自动登录并下载（缓存 ${_status.cachedBytes} 字节）',
                  {'cachedBytes': '${_status.cachedBytes}'},
                )
              : fsG4(
                  FsG4TextKeys.safOnDemandOffDesc,
                  '没配置时，系统「文件」里只有已下载的离线文件能打开',
                ),
          onTap: _busy ? null : (on ? _disable : _enable),
        ),
        AppSheetAction(
          key: const Key('saf-on-demand-clear-cache'),
          icon: Icons.delete_sweep_outlined,
          label: fsG4(FsG4TextKeys.safOnDemandClearCache, '清理按需下载缓存'),
          description: fsG4(
            FsG4TextKeys.safOnDemandClearCacheDesc,
            '删除"打开那一刻下载"临时落盘的文件（不影响已标为离线的文件）',
          ),
          onTap: _busy ? null : _clearCache,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            _message.isEmpty
                ? (_status.configured
                      ? context.t.safOnDemandConfiguredStatus(_safAccount(context))
                      : context.t.safOnDemandUnconfiguredStatus(
                          _safAccount(context),
                        ))
                : _message,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            // 如实标注：这段原生逻辑本仓跑不了真机
            context.t.safOnDemandNativeNote,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    );
  }
}
