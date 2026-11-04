// 单台摄像机详情页（DS cam 的「单相机」屏）：实时地址 · 快照 · 云台 · 最近录像。
//
// 接口事实来源：`docs/station-surveillance-mailplus-insight-research.md`
//   * GetInfo v8 / GetStmUrlPath v8 / PTZ.Move v6 / AbsPtz v5 / GoPreset v4 /
//     ListPreset v1 / Recording.List v5。
//   * MJPEG/RTSP 地址模板来自包内 `.so`（research §2.4(d)）。
//
// ⚠️ 本页**不内置** RTSP/MJPEG 播放器：实时画面交给系统外部播放器，
// 页面上给的是可直接使用的地址 + 复制按钮（研究 §2.8：H.265 还需 AME codec）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/surveillance_dto.dart';
import '../../data/surveillance_station.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'surv_labels.dart';
import 'surv_providers.dart';

class SurvCameraPage extends ConsumerStatefulWidget {
  const SurvCameraPage({
    super.key,
    required this.cameraId,
    this.initialName = '',
  });

  final int cameraId;

  /// 列表页已知的名字（详情没回来前先顶上，避免标题闪空）。
  final String initialName;

  @override
  ConsumerState<SurvCameraPage> createState() => _SurvCameraPageState();
}

class _SurvCameraPageState extends ConsumerState<SurvCameraPage> {
  @override
  void initState() {
    super.initState();
    trackOnce(
      UsageModule.surveillance,
      UsageAction.view,
      objectType: 'camera',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final detail = ref.watch(survCameraProvider(widget.cameraId));
    final api = ref.watch(surveillanceApiProvider);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(
          detail.value?.name.isNotEmpty == true
              ? detail.value!.name
              : (widget.initialName.isNotEmpty
                    ? widget.initialName
                    : t.survCameraDetailTitle),
        ),
      ),
      body: api == null || !api.installed
          ? AppEmptyState(
              key: const Key('surv-detail-not-installed'),
              icon: Icons.extension_off_outlined,
              title: t.survErrNotInstalled,
              message: t.survNotInstalledHint,
            )
          : detail.when(
              loading: () => const AppListSkeleton(),
              error: (e, _) => AppErrorView(
                key: const Key('surv-detail-error'),
                icon: Icons.error_outline,
                title: t.survDetailLoadFailed,
                detail: describeSurvError(e),
                onRetry: () =>
                    ref.invalidate(survCameraProvider(widget.cameraId)),
              ),
              data: (cam) => cam == null
                  ? AppEmptyState(
                      key: const Key('surv-detail-missing'),
                      icon: Icons.videocam_off_outlined,
                      title: t.survEmptyTitle,
                    )
                  : _Body(camera: cam),
            ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.camera});

  final SurvCameraDto camera;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final theme = Theme.of(context);
    final meta = survCameraMeta(camera);
    // S2 能力位降级：缺 `SYNO.SurveillanceStation.Recording` 时，模块照常
    // （partial，不隐藏），但「录像」这一功能入口不可用 → 整块隐藏。
    final canRecordings = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.surveillance, kSurveillanceRecordingApi);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
      children: [
        // ---------------- 基本信息 ----------------
        Row(
          children: [
            Icon(
              camera.isLive
                  ? Icons.videocam_outlined
                  : Icons.videocam_off_outlined,
              size: 18,
              color: camera.isLive ? theme.colorScheme.primary : DesignPalette.of(context).dim,
            ),
            const SizedBox(width: Gap.sm),
            TelemetryLabel(
              survStatusLabel(t, camera),
              size: 12,
              color: camera.isLive ? theme.colorScheme.primary : DesignPalette.of(context).dim,
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(width: Gap.md),
              Expanded(child: TelemetryLabel(meta, size: 11, color: DesignPalette.of(context).dim)),
            ],
          ],
        ),
        const SizedBox(height: Gap.lg),

        // ---------------- 实时画面 ----------------
        _SectionTitle(t.survLiveSection),
        const SizedBox(height: Gap.sm),
        if (!camera.isLive)
          _Hint(
            key: const Key('surv-live-unavailable'),
            text: t.survLiveUnavailable,
          )
        else
          _LiveUrls(camera: camera),
        const SizedBox(height: Gap.lg),

        // ---------------- 云台 ----------------
        if (camera.hasPtz) ...[
          _SectionTitle(t.survPtzSection),
          const SizedBox(height: Gap.sm),
          _PtzPad(cameraId: camera.id),
          const SizedBox(height: Gap.lg),
        ],

        // ---------------- 录像（可选能力位：缺 Recording API 则整块不出现）----
        if (canRecordings) ...[
          _SectionTitle(t.survRecordingsSection),
          const SizedBox(height: Gap.sm),
          _Recordings(cameraId: camera.id),
        ],
      ],
    );
  }
}

/// 实时地址区：GetStmUrlPath 的真实路径 + 由模板拼的 RTSP/MJPEG 地址。
class _LiveUrls extends ConsumerWidget {
  const _LiveUrls({required this.camera});

  final SurvCameraDto camera;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final paths = ref.watch(survStreamPathProvider(camera.id));
    final api = ref.watch(surveillanceApiProvider);
    return paths.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: Gap.md),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (e, _) =>
          _Hint(key: const Key('surv-live-error'), text: describeSurvError(e)),
      data: (p) {
        final rtsp = (p?.unicastPath.isNotEmpty ?? false)
            ? p!.unicastPath
            : api?.rtspUrl(cameraId: camera.id, dsId: camera.ownerDsId) ?? '';
        final mjpeg = api?.mjpegUrl(cameraId: camera.id) ?? '';
        return Column(
          key: const Key('surv-live-urls'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _UrlRow(label: t.survRtspUrl, value: rtsp),
            const SizedBox(height: Gap.sm),
            _UrlRow(label: t.survMjpegUrl, value: mjpeg),
            const SizedBox(height: Gap.sm),
            _CopyRow(
              key: const Key('surv-snapshot-url'),
              label: t.survSnapshot,
              value: api?.snapshotUrl(cameraId: camera.id) ?? '',
              actionLabel: t.survOpenSnapshot,
            ),
            const SizedBox(height: Gap.xs),
            Text(t.survLiveHint, style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      },
    );
  }
}

/// 云台方向盘 + 缩放 + 回起始位置。
class _PtzPad extends ConsumerWidget {
  const _PtzPad({required this.cameraId});

  final int cameraId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    return Column(
      key: const Key('surv-ptz'),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _PtzButton(
              key: const Key('surv-ptz-up'),
              icon: Icons.keyboard_arrow_up,
              tooltip: t.survPtzUp,
              onTap: () => _move(context, ref, 'Start', 'Up'),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _PtzButton(
              key: const Key('surv-ptz-left'),
              icon: Icons.keyboard_arrow_left,
              tooltip: t.survPtzLeft,
              onTap: () => _move(context, ref, 'Start', 'Left'),
            ),
            const SizedBox(width: Gap.sm),
            _PtzButton(
              key: const Key('surv-ptz-home'),
              icon: Icons.home_outlined,
              tooltip: t.survPtzHome,
              onTap: () => _run(context, ref, (a) => a.home(cameraId)),
            ),
            const SizedBox(width: Gap.sm),
            _PtzButton(
              key: const Key('surv-ptz-right'),
              icon: Icons.keyboard_arrow_right,
              tooltip: t.survPtzRight,
              onTap: () => _move(context, ref, 'Start', 'Right'),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _PtzButton(
              key: const Key('surv-ptz-down'),
              icon: Icons.keyboard_arrow_down,
              tooltip: t.survPtzDown,
              onTap: () => _move(context, ref, 'Start', 'Down'),
            ),
          ],
        ),
        const SizedBox(height: Gap.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _PtzButton(
              key: const Key('surv-ptz-zoom-in'),
              icon: Icons.zoom_in,
              tooltip: t.survPtzZoomIn,
              onTap: () =>
                  _run(context, ref, (a) => a.zoom(cameraId, inwards: true)),
            ),
            const SizedBox(width: Gap.sm),
            _PtzButton(
              key: const Key('surv-ptz-zoom-out'),
              icon: Icons.zoom_out,
              tooltip: t.survPtzZoomOut,
              onTap: () =>
                  _run(context, ref, (a) => a.zoom(cameraId, inwards: false)),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _move(
    BuildContext context,
    WidgetRef ref,
    String moveType,
    String direction,
  ) => _run(
    context,
    ref,
    (a) => a.move(cameraId: cameraId, moveType: moveType, direction: direction),
  );

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function(SurvActions actions) op,
  ) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await op(ref.read(survActionsProvider));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.survPtzMoveFailed(describeSurvError(e)))),
      );
    }
  }
}

/// 最近录像（`Recording.List` v5，最近 24 小时）。
class _Recordings extends ConsumerWidget {
  const _Recordings({required this.cameraId});

  final int cameraId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final page = ref.watch(survRecordingsProvider(cameraId));
    return page.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: Gap.md),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (e, _) =>
          _Hint(key: const Key('surv-rec-error'), text: describeSurvError(e)),
      data: (p) {
        final items = p?.items ?? const <SurvRecordingDto>[];
        if (items.isEmpty) {
          return _Hint(
            key: const Key('surv-rec-empty'),
            text: t.survRecordingsEmpty,
          );
        }
        return Column(
          key: const Key('surv-rec-list'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TelemetryLabel(t.survRecordingCount(items.length), size: 11),
            const SizedBox(height: Gap.xs),
            for (final r in items.take(20))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: TelemetryLabel(
                        survRecordingTimeText(r.startTime),
                        size: 12,
                        letterSpacing: 0.2,
                      ),
                    ),
                    TelemetryLabel(
                      t.survRecordingDuration(
                        survDurationText(r.durationSeconds),
                      ),
                      size: 11,
                      color: DesignPalette.of(context).dim,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TelemetryLabel(text, size: 12),
  );
}

class _Hint extends StatelessWidget {
  const _Hint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}

class _UrlRow extends StatelessWidget {
  const _UrlRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => _CopyRow(label: label, value: value);
}

/// 一行「标签 + 值 + 复制按钮」。值为空时整行不渲染。
class _CopyRow extends StatelessWidget {
  const _CopyRow({
    super.key,
    required this.label,
    required this.value,
    this.actionLabel,
  });

  final String label;
  final String value;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: TelemetryLabel(label, size: 11, color: DesignPalette.of(context).dim),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        IconButton(
          tooltip: actionLabel ?? t.survCopyUrl,
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(t.survCopyDone)));
            }
          },
        ),
      ],
    );
  }
}

class _PtzButton extends StatelessWidget {
  const _PtzButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) =>
      IconButton(tooltip: tooltip, icon: Icon(icon), onPressed: onTap);
}
