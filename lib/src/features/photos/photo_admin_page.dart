// ⑦相册 **管理员页**（新规 B1：管理员接口一律走 Mock 核实并必须通过）。
//
// 权威出处（`SynologyPhotos/usr/webapi/SYNO.Foto.lib`）：
//   * `SYNO.Foto.Setting.Admin` v1 → `get` / `set`；
//   * `SYNO.Foto.Development.Admin` v1 → `refetch_geocoding` /
//     `regenerate_concept_album` / `update_concept_threshold`
//     （方法级 `allowUser` 收窄到 admin）。
//
// 本页只做**有逐字证据**的两件事：
//   ① 读管理端设置（`get`，无参）——把服务端字段原样列出，**不猜字段**；
//   ② 重新地理编码（`refetch_geocoding`，无参）——**会动服务端数据**，
//      所以必须二次确认，并且只在管理员可见（`AdminOnly` 门控）。
//
// 门槛规则（与新规 R2/R3 一致）：**非管理员完全看不到入口**，
// 由 `photo_c2_page.dart` 里的 `AdminOnly` 负责；本页自身再兜一层
// （直接 open 也不会给非管理员调用机会 —— 失败方向 fail-closed）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_tokens.dart';
import '../admin/admin_gate.dart';
import 'photo_c2_providers.dart';

/// 管理端设置（原样返回服务端字段）。
final photoAdminSettingsProvider = FutureProvider.autoDispose((ref) async {
  final api = ref.watch(fotoC2ApiProvider);
  if (api == null) return const <String, dynamic>{};
  return api.adminSettings();
}, retry: (_, _) => null);

/// 照片管理页。
class PhotoAdminPage extends ConsumerStatefulWidget {
  const PhotoAdminPage({super.key});

  @override
  ConsumerState<PhotoAdminPage> createState() => _PhotoAdminPageState();
}

class _PhotoAdminPageState extends ConsumerState<PhotoAdminPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final admin = ref.watch(isAdminProvider).value == true;
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(title: Text(context.t.photoAdminTitle)),
      body: admin
          ? _body(context, hud)
          : Center(
              // fail-closed：身份不是明确的管理员 ⇒ 什么都不给
              child: Text(
                context.t.adminPermissionRequired,
                key: const Key('photo-admin-denied'),
              ),
            ),
    );
  }

  Widget _body(BuildContext context, DesignPalette hud) {
    final value = ref.watch(photoAdminSettingsProvider);
    return ListView(
      key: const Key('photo-admin-page'),
      padding: const EdgeInsets.all(Gap.md),
      children: [
        value.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(Gap.md),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (err, _) => Text(
            context.t.photoAdminLoadFailed('$err'),
            key: const Key('photo-admin-error'),
            style: TextStyle(color: hud.dim),
          ),
          data: (settings) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.t.photoAdminSettingsTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: Gap.sm),
              if (settings.isEmpty)
                Text(
                  context.t.photoAdminSettingsEmpty,
                  key: const Key('photo-admin-settings-empty'),
                  style: TextStyle(color: hud.dim),
                )
              else
                for (final e in settings.entries)
                  DesignRowTile(
                    dense: true,
                    key: Key('photo-admin-field-${e.key}'),
                    title: Text(e.key),
                    subtitle: Text('${e.value}'),
                  ),
            ],
          ),
        ),
        const Divider(height: Gap.xl),
        DesignRowTile(
          key: const Key('photo-admin-refetch'),
          leading: const Icon(Icons.travel_explore_outlined),
          title: Text(context.t.photoAdminRefetch),
          subtitle: Text(
            context.t.photoAdminRefetchHint,
            style: TextStyle(color: hud.dim),
          ),
          enabled: !_busy,
          onTap: _busy ? null : _confirmRefetch,
        ),
      ],
    );
  }

  Future<void> _confirmRefetch() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('photo-admin-refetch-confirm'),
        title: Text(context.t.photoAdminRefetchTitle),
        content: Text(context.t.photoAdminRefetchBody),
        actions: [
          TextButton(
            key: const Key('photo-admin-refetch-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-admin-refetch-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.calStartLabel),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = ref.read(fotoC2ApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await api.adminRefetchGeocoding();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(context.t.photoAdminRefetchQueued)),
      );
    } catch (err) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(context.t.photoAdminRefetchFailed('$err'))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
