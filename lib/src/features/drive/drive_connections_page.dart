// Drive「已连接的设备」页（G6）：列出正在用 Drive 客户端连着这台 NAS 的
// 客户端 / 设备（`SYNO.SynologyDrive.Connection:list`）。
//
// ## 协议与证据
//
// * **方法表**（SPK 自带，权威）：`/tmp/spk/export_SynologyDrive/webapi/drive/
//   SYNO.SynologyDrive.lib` → `minVersion:1, maxVersion:2`，
//   `methods:{1:[list,delete], 2:[list,delete,summary]}`，普通用户可调。
//   我们**只做 `list`**（`delete` 命中 §5.1 变更动词黑名单，永不调用）。
// * **版本协商**：候选 `[2, 1]` 交给 `DriveApi._negotiate`，与 `SYNO.API.Info`
//   的真实区间取交集 —— **不硬编码 maxVersion**。
// * **真机只读实测**：`{"items": [], "total": 0}`，无必填参数
//   （`docs/g6-api-probe-facts.md:37`）。
//
// ## ⚠️ 空态是本页在真机上的**唯一**表现
//
// 本账号没有任何已连接设备 ⇒ 页面**必须**画人话空态（标题 + 说明），
// 绝不是白屏、也不是"技术上成功了但什么都没画"。用例见
// `test/drive_g6_wiring_test.dart` 的「空响应 → 人话空态」。
//
// ## 入口
//
// `drive_extras_page.dart` 的「已连接的设备」项（`DriveExtrasPage` 本来就是
// "操作型入口"的汇集处）。能力位缺失 → 该入口直接不出现。
//
// ## 纪律
//
// `client_id` 是内部 id：只允许出现在 Key 里，**绝不上屏**。
// `client_status` 是枚举串：只画认识的值，认不出的**不画**（不透原文）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_connection_dto.dart';
import 'drive_g6_providers.dart';
import 'drive_g6_text.dart';
import '../files/file_row.dart' show formatFileTime;

class DriveConnectionsPage extends ConsumerWidget {
  const DriveConnectionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveConnectionsProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-connections-page'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: t.calBack,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(
                        driveG6(
                          DriveG6TextKeys.connectionsTitle,
                          '已连接的设备',
                        ),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      key: const Key('drive-connections-refresh'),
                      tooltip: t.photoRefresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: () => ref.invalidate(driveConnectionsProvider),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Text(
                  driveG6(
                    DriveG6TextKeys.connectionsSubtitle,
                    '正在用 Drive 客户端连着这台 NAS 的设备',
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => AppEmptyState(
                    key: const Key('drive-connections-error'),
                    icon: Icons.error_outline,
                    title: driveG6(
                      DriveG6TextKeys.connectionsLoadFailed,
                      '暂时取不到已连接的设备',
                    ),
                    // 非 1076 的传输/业务错误 → 既有「异常 → 人话」出口
                    message: describeDriveG6Error(e),
                    actionLabel: t.photoRetry,
                    onAction: () => ref.invalidate(driveConnectionsProvider),
                  ),
                  data: (page) {
                    if (page.items.isEmpty) {
                      return AppEmptyState(
                        key: const Key('drive-connections-empty'),
                        icon: Icons.devices_other_outlined,
                        title: driveG6(
                          DriveG6TextKeys.connectionsEmptyTitle,
                          '当前没有已连接的设备',
                        ),
                        message: driveG6(
                          DriveG6TextKeys.connectionsEmptyBody,
                          '在电脑或手机上用 Synology Drive 客户端登录这台 NAS 后，'
                              '这里会列出该设备。',
                        ),
                      );
                    }
                    return ListView.separated(
                      key: const Key('drive-connections-list'),
                      padding: const EdgeInsets.all(Gap.md),
                      itemCount: page.items.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: Gap.xs),
                      itemBuilder: (context, i) =>
                          _ConnectionRow(connection: page.items[i]),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({required this.connection});

  final DriveConnectionDto connection;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final meta = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: hud.dim);
    // 状态：认识的才画（认不出的枚举值**不透原文**）
    final statusKey = connection.statusLabelKey();
    final statusLabel = switch (statusKey) {
      'driveG6ConnectionStatusConnected' => driveG6(
        DriveG6TextKeys.connectionStatusConnected,
        '已连接',
      ),
      'driveG6ConnectionStatusOffline' => driveG6(
        DriveG6TextKeys.connectionStatusOffline,
        '离线',
      ),
      _ => '',
    };
    final loginLabel = formatFileTime(connection.loginTime, t: t);
    final subtitle = [
      if (statusLabel.isNotEmpty) statusLabel,
      if (connection.clientType.isNotEmpty) connection.clientType,
      if (connection.clientVersion.isNotEmpty) connection.clientVersion,
      if (connection.clientIp.isNotEmpty) connection.clientIp,
      if (connection.clientLocation.isNotEmpty) connection.clientLocation,
      if (loginLabel.isNotEmpty) loginLabel,
    ].join(' · ');
    return DesignRowTile(
      // ⚠️ 内部 id 只进 Key，**不上屏**
      key: Key('drive-connection-${connection.clientId}'),
      leading: const Icon(Icons.devices_other_outlined),
      title: Text(
        connection.displayName(
          driveG6(DriveG6TextKeys.connectionUnknownDevice, '未知设备'),
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: meta,
      ),
    );
  }
}
