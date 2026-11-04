// 相册「迁移状态」页（G6）：PhotoStation / Moments → Synology Photos 的迁移状态。
//
// ## 协议与证据
//
// * `SYNO.Foto.Migration:get_status` **v1**，**无必填参数**；字段与状态枚举的
//   证据（`.so` 字符串常量 + 官方迁移工具字面值）见
//   `data/dto/foto_g6_dto.dart` 文件头。**`status` 是枚举串，不是布尔**。
// * 版本协商交给 `FotoG6Api._negotiate`（与 `SYNO.API.Info` 的区间取交集），
//   **不硬编码 maxVersion**。
// * 真机只读实测：`{"current": 2, "status": "done", "title_key": "", "total": 0}`
//   （`docs/g6-api-probe-facts.md:39`）。
//
// ## ⚠️ 未知状态绝不透原文
//
// 本仓刚做过一轮「异常/协议原文不得进 UI」的清理：`status` 只通过
// [FotoMigrationState] 映射成 ARB key，**认不出的取值走 [FotoMigrationState.unknown]
// 的通用人话**；`title_key` 也只映射有证据的三个阶段名，其余**不画**。
// 界面**永远不显示** `status` / `title_key` 的原始字符串。
//
// ## ⚠️ 空态就是本页在真机上的表现
//
// 真机回的是 `total: 0` + `status: "done"` ⇒ 页面画「没有正在进行的迁移」
// 的人话空态，绝不是白屏。用例见 `test/photo_g6_wiring_test.dart`。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/foto_g6_dto.dart';
import 'photo_c2_sections.dart';
import 'photo_g6_providers.dart';
import 'photo_g6_text.dart';
import 'photo_widgets.dart';

class PhotoMigrationPage extends ConsumerWidget {
  const PhotoMigrationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(photoMigrationStatusProvider);
    return PhotoC2Scaffold(
      pageKey: const Key('photo-g6-migration-page'),
      title: photoG6(PhotoG6TextKeys.migrationTitle, '迁移状态'),
      body: PhotoAsync<FotoMigrationStatusDto>(
        value: RiverpodAsync(async),
        emptyTitle: photoG6(
          PhotoG6TextKeys.migrationIdleTitle,
          '当前没有正在进行的迁移',
        ),
        emptyMessage: photoG6(
          PhotoG6TextKeys.migrationIdleBody,
          'Photo Station / Moments 的照片迁移完成后，这里会显示结果。',
        ),
        onRetry: () => ref.invalidate(photoMigrationStatusProvider),
        // "空" = **真的没有任何可报的迁移**：已完成且阶段总数为 0
        //（真机就是这一支：`status:"done", total:0`）。
        // ⚠️ 只有这一支算空；`running`/`failed`/**未知状态**即使 `total == 0`
        // 也照常渲染正文（**绝不把"不确定/失败"装成"空态"**）。
        isEmpty: (m) => m.total <= 0 && m.state == FotoMigrationState.done,
        builder: (m) => _MigrationBody(status: m),
      ),
    );
  }
}

class _MigrationBody extends StatelessWidget {
  const _MigrationBody({required this.status});

  final FotoMigrationStatusDto status;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final meta = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: hud.dim);
    // 未知状态走 general 人话；**绝不显示原始 status 串**
    final label = switch (status.state) {
      FotoMigrationState.done => photoG6(
        PhotoG6TextKeys.migrationStatusDone,
        '迁移已完成',
      ),
      FotoMigrationState.running => photoG6(
        PhotoG6TextKeys.migrationStatusRunning,
        '正在迁移',
      ),
      FotoMigrationState.failed => photoG6(
        PhotoG6TextKeys.migrationStatusFailed,
        '迁移失败，请在 DSM 的 Synology Photos 中查看详情',
      ),
      FotoMigrationState.unknown => photoG6(
        PhotoG6TextKeys.migrationStatusUnknown,
        '暂时读不到迁移状态，请稍后重试',
      ),
    };
    // 阶段名只映射有证据的三个；认不出 → 不画（**绝不透 title_key 原文**）
    final stage = switch (status.stageLabelKey) {
      'photoG6MigrationStagePhotoStation' => photoG6(
        PhotoG6TextKeys.migrationStagePhotoStation,
        '正在迁移 Photo Station 的照片',
      ),
      'photoG6MigrationStageMomentsPersonal' => photoG6(
        PhotoG6TextKeys.migrationStageMomentsPersonal,
        '正在迁移 Moments 的个人照片',
      ),
      'photoG6MigrationStageBoth' => photoG6(
        PhotoG6TextKeys.migrationStageBoth,
        '正在迁移 Photo Station 与 Moments 的照片',
      ),
      _ => '',
    };
    return ListView(
      key: const Key('photo-g6-migration-body'),
      padding: const EdgeInsets.all(Gap.md),
      children: [
        Card(
          color: hud.surface,
          child: DesignRowTile(
            key: const Key('photo-g6-migration-status'),
            leading: Icon(
              status.state == FotoMigrationState.failed
                  ? Icons.error_outline
                  : status.state == FotoMigrationState.running
                  ? Icons.sync
                  : Icons.check_circle_outline,
              color: hud.dim,
            ),
            title: Text(label),
            subtitle: stage.isEmpty ? null : Text(stage, style: meta),
          ),
        ),
        if (status.total > 0) ...[
          const SizedBox(height: Gap.md),
          Text(
            photoG6Fill(
              PhotoG6TextKeys.migrationProgress,
              '第 {current} / {total} 步',
              {'current': '${status.current}', 'total': '${status.total}'},
            ),
            style: meta,
          ),
          const SizedBox(height: Gap.xs),
          LinearProgressIndicator(value: status.ratio),
        ],
      ],
    );
  }
}
