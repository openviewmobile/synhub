// ③Drive **管理员页**（新规 B1：管理员接口一律走 Mock Server 核实并必须通过）。
//
// 逐字证据（接口侧）全部在 `data/drive_admin_api.dart` 的文件头：
//   * `Settings/list`  v1  无 params（官方 `ui/cloudstation.js`）
//   * `Config/get`     v1  无 params（官方 `SYNO.SDS.CSTN.WebAPI.Config.api`）
//   * `DBUsage/get`    v1  `params:{}`
//   * `DBUsage/status` v1  `params:{}`
//   * `Privilege/list` v1  `{additional:["status","enabled"]}`
//
// ## 只读页
//
// 官方管理端还能改设置（`Settings/update`、`Config/set`、`DBUsage/start|stop`、
// `Privilege/set`）—— 那些是**变更动词**，按 §5.1 本条**一个都没实现**。
// 本页只把服务端原样回的值展示出来（不猜字段、不做本地推断）。
//
// ## 门控
//
// 入口在 `drive_extras_page.dart` 里用 `AdminOnly` 包住（非管理员**看不见**）；
// 本页自身再判一次（直接 `open` 也不给非管理员调用机会，fail-closed）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/drive_admin_api.dart';
import '../admin/admin_gate.dart';
import '../files/drive_providers.dart' show driveApiProvider;

/// 管理端 API 实例（未连接 → `null`，页面自己提示）。
final driveAdminApiProvider = Provider<DriveAdminApi?>((ref) {
  final api = ref.watch(driveApiProvider);
  return api == null ? null : DriveAdminApi(api.api);
});

/// `Settings/list` v1（无参）。
final driveAdminSettingsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
      final api = ref.watch(driveAdminApiProvider);
      if (api == null) throw StateError('not connected');
      return api.settings();
    }, retry: (_, _) => null);

/// `Config/get` v1（无参）。
final driveAdminConfigProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
      final api = ref.watch(driveAdminApiProvider);
      if (api == null) throw StateError('not connected');
      return api.config();
    }, retry: (_, _) => null);

/// `DBUsage/get` v1（`params:{}`）。
final driveAdminDbUsageProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
      final api = ref.watch(driveAdminApiProvider);
      if (api == null) throw StateError('not connected');
      return api.dbUsage();
    }, retry: (_, _) => null);

/// `Privilege/list` v1（`additional:["status","enabled"]`）。
final driveAdminPrivilegesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final api = ref.watch(driveAdminApiProvider);
      if (api == null) throw StateError('not connected');
      return api.privileges();
    }, retry: (_, _) => null);

/// 打开 Drive 管理页。
Future<void> openDriveAdminPage(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const DriveAdminPage()),
    );

/// Drive 管理页（只读）。
class DriveAdminPage extends ConsumerWidget {
  const DriveAdminPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final admin = ref.watch(isAdminProvider).value == true;
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(title: Text(context.t.driveAdminTitle)),
      body: admin
          ? const _AdminBody()
          : Center(
              // fail-closed：身份不是明确的管理员 ⇒ 什么都不给
              child: Text(
                context.t.adminPermissionRequired,
                key: const Key('drive-admin-denied'),
              ),
            ),
    );
  }
}

class _AdminBody extends ConsumerWidget {
  const _AdminBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    return ListView(
      key: const Key('drive-admin-page'),
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      children: [
        _sectionTitle(context, hud, context.t.driveAdminSectionSettings),
        _kvSection(
          context: context,
          ref: ref,
          async: ref.watch(driveAdminSettingsProvider),
          sectionKey: 'settings',
          fieldPrefix: 'drive-admin-field-',
          onRetry: () => ref.invalidate(driveAdminSettingsProvider),
        ),
        _sectionTitle(context, hud, context.t.driveAdminSectionDatabase),
        _kvSection(
          context: context,
          ref: ref,
          async: ref.watch(driveAdminConfigProvider),
          sectionKey: 'config',
          fieldPrefix: 'drive-admin-config-field-',
          onRetry: () => ref.invalidate(driveAdminConfigProvider),
        ),
        _kvSection(
          context: context,
          ref: ref,
          async: ref.watch(driveAdminDbUsageProvider),
          sectionKey: 'db-usage',
          fieldPrefix: 'drive-admin-db-field-',
          onRetry: () => ref.invalidate(driveAdminDbUsageProvider),
        ),
        _sectionTitle(context, hud, context.t.driveAdminSectionPrivilege),
        _privilegeSection(context, ref, hud),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, DesignPalette hud, String text) =>
      Padding(
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(color: hud.dim, letterSpacing: 1.1),
    ),
  );

  /// 服务端回什么就列什么（**不猜字段**、不做本地格式化）。
  Widget _kvSection({
    required BuildContext context,
    required WidgetRef ref,
    required AsyncValue<Map<String, dynamic>> async,
    required String sectionKey,
    required String fieldPrefix,
    required VoidCallback onRetry,
  }) => async.when(
    loading: () => const Padding(
      padding: EdgeInsets.all(Gap.md),
      child: LinearProgressIndicator(minHeight: 2),
    ),
    error: (e, _) => AppErrorView(
      key: Key('drive-admin-error-$sectionKey'),
      detail: context.t.driveAdminReadFailed(sectionKey),
      onRetry: onRetry,
    ),
    data: (map) {
      if (map.isEmpty) {
        return Padding(
          key: Key('drive-admin-empty-$sectionKey'),
          padding: const EdgeInsets.all(Gap.md),
          child: Text(context.t.driveAdminNoFields),
        );
      }
      final keys = map.keys.toList()..sort();
      return Column(
        key: Key('drive-admin-section-$sectionKey'),
        children: [
          for (final k in keys)
            DesignRowTile(
              key: Key('$fieldPrefix$k'),
              dense: true,
              title: Text(k),
              subtitle: Text('${map[k]}'),
            ),
        ],
      );
    },
  );

  Widget _privilegeSection(BuildContext context, WidgetRef ref, DesignPalette hud) {
    final async = ref.watch(driveAdminPrivilegesProvider);
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(Gap.md),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (e, _) => AppErrorView(
        key: const Key('drive-admin-error-privilege'),
        detail: context.t.driveAdminReadFailed('privilege'),
        onRetry: () => ref.invalidate(driveAdminPrivilegesProvider),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Padding(
            key: const Key('drive-admin-empty-privilege'),
            padding: const EdgeInsets.all(Gap.md),
            child: Text(context.t.driveAdminNoUsers),
          );
        }
        return Column(
          key: const Key('drive-admin-section-privilege'),
          children: [
            for (final p in items)
              DesignRowTile(
                key: Key('drive-admin-privilege-${p['name']}'),
                dense: true,
                title: Text('${p['name']}'),
                subtitle: Text(
                  'enable=${p['enable']} status=${p['status']}',
                ),
              ),
          ],
        );
      },
    );
  }
}
