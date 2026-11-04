// Surveillance Station 摄像机列表页（阶段二 A 最后一批，只做普通用户功能）。
//
// 接口事实来源：`docs/station-surveillance-mailplus-insight-research.md`
//   * 列表 = `SYNO.SurveillanceStation.Camera.List` v8（root `cameras`）；
//   * 详情 = `Camera.GetInfo` v8；实时流 = `Camera.GetStmUrlPath` v8。
//
// 页面结构对齐现有模块（见 `features/downloads/download_page.dart`、
// `features/audio/audio_page.dart`）：刷新 · 空态/错误态（**区分套件未安装/
// 无权限/网络失败**，三态图标与文案各不相同）· 未安装时**不给重试按钮**。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/surveillance_dto.dart';
import '../../data/surveillance_station.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'surv_camera_page.dart';
import 'surv_labels.dart';
import 'surv_providers.dart';

class SurveillancePage extends ConsumerStatefulWidget {
  const SurveillancePage({super.key});

  @override
  ConsumerState<SurveillancePage> createState() => _SurveillancePageState();
}

class _SurveillancePageState extends ConsumerState<SurveillancePage> {
  @override
  void initState() {
    super.initState();
    trackView(UsageModule.surveillance, screen: 'live');
    // build 里不能发请求，首帧之后再拉第一页。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(survCameraListProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final state = ref.watch(survCameraListProvider);
    final api = ref.watch(surveillanceApiProvider);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(t.survTitle),
        actions: [
          IconButton(
            key: const Key('surv-refresh'),
            tooltip: t.photoRefresh,
            icon: const Icon(Icons.refresh),
            // 未安装时也允许刷新（用户可能刚装完套件）；但"未安装"空态本身
            // **不放重试按钮**（任务书硬要求）。
            onPressed: () =>
                ref.read(survCameraListProvider.notifier).refresh(),
          ),
        ],
      ),
      body: _body(context, state, api),
    );
  }

  Widget _body(
    BuildContext context,
    SurvCameraListState state,
    SurveillanceStationApi? api,
  ) {
    final t = context.t;
    // 1) 还没连接会话
    if (state.apiMissing || api == null) {
      return AppEmptyState(
        key: const Key('surv-no-session'),
        icon: Icons.cloud_off,
        title: t.setNotConnected,
        message: t.survNotInstalledHint,
      );
    }
    // 2) 套件未安装：给结论 + 引导套件中心，**不给**"重试"（重试也装不上）
    if (state.failure == SurvFailureKind.notInstalled) {
      return AppEmptyState(
        key: const Key('surv-not-installed'),
        icon: Icons.extension_off_outlined,
        title: t.survErrNotInstalled,
        message: t.survNotInstalledHint,
      );
    }
    // 3) 无权限（105/160/471/472）
    if (state.failure == SurvFailureKind.noPrivilege && state.items.isEmpty) {
      return AppEmptyState(
        key: const Key('surv-no-privilege'),
        icon: Icons.lock_outline,
        title: t.survErrNoPrivilege,
        message: t.survNoPrivilegeHint,
      );
    }
    // 4) 首次加载
    if (state.loading && !state.loaded) return const AppListSkeleton();
    // 5) 失败（网络/其它）—— 这里才给"重试"
    if (state.failure != null && state.items.isEmpty) {
      final network =
          state.failure == SurvFailureKind.network ||
          state.failure == SurvFailureKind.sessionExpired;
      return AppErrorView(
        key: const Key('surv-error'),
        icon: network ? Icons.wifi_off : Icons.error_outline,
        title: t.survLoadFailed,
        detail: state.errorText,
        onRetry: () => ref.read(survCameraListProvider.notifier).load(),
      );
    }
    // 6) 空态（装了但一路摄像机都没有）
    if (state.items.isEmpty) {
      return AppEmptyState(
        key: const Key('surv-empty'),
        icon: Icons.videocam_off_outlined,
        title: t.survEmptyTitle,
        message: t.survEmptyMessage,
      );
    }
    // 7) 列表
    return RefreshIndicator(
      onRefresh: () => ref.read(survCameraListProvider.notifier).refresh(),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xxl),
        itemCount: state.items.length + 1,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          color: DesignPalette.of(context).dim.withValues(alpha: 0.12),
        ),
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              key: const Key('surv-count'),
              padding: const EdgeInsets.fromLTRB(
                Gap.lg,
                Gap.xs,
                Gap.lg,
                Gap.xs,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TelemetryLabel(
                  t.survCameraCount(state.items.length),
                  size: 11,
                ),
              ),
            );
          }
          return _CameraRow(camera: state.items[i - 1]);
        },
      ),
    );
  }
}

/// 一行摄像机：状态图标 · 名称 · 型号/分辨率/地址 · PTZ 标记。
class _CameraRow extends StatelessWidget {
  const _CameraRow({required this.camera});

  final SurvCameraDto camera;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;
    final live = camera.isLive;
    final statusColor = live ? theme.colorScheme.primary : DesignPalette.of(context).dim;
    final meta = survCameraMeta(camera);
    return DesignRowTile(
      key: Key('surv-camera-${camera.id}'),
      onTap: () => Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              SurvCameraPage(cameraId: camera.id, initialName: camera.name),
        ),
      ),
      leading: Icon(
        live ? Icons.videocam_outlined : Icons.videocam_off_outlined,
        color: statusColor,
      ),
      title: Text(
        camera.name.isEmpty ? t.survCameraDetailTitle : camera.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: Gap.xxs),
          // ★ r489：2.0 倍字号 + 英文下这两个标签并排会挤出 14px（真机同样会）。
          //   两段都进 `Flexible` 并各自单行省略 —— 状态优先，元信息让位。
          Row(
            children: [
              Flexible(
                child: Text(
                  survStatusLabel(t, camera),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: DesignType.labelSmallSize,
                    color: statusColor,
                  ),
                ),
              ),
              if (meta.isNotEmpty) ...[
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: DesignType.labelSmallSize,
                      color: DesignPalette.of(context).dim,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      trailing: camera.hasPtz
          ? Icon(Icons.control_camera_outlined, size: 18, color: DesignPalette.of(context).dim)
          : null,
    );
  }
}
