// 223（M71）「外接设备（USB）」页：列出外接 USB 存储并可**安全弹出**。
//
// 协议/取证见 [FileStationApi.listUsbDevices] / [FileStationApi.ejectUsbDevice]
// 的注释（DS file 反编译 + FileStation `conf/resource` 的 `allow_other_apis` +
// 本会话只读真机探针）。
//
// ⚠️ 弹出（`eject`）是**写操作**：必须二次确认，且本批**没有在真机上调过它**。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/provider_retry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/filestation_api.dart';
import '../../data/local/file_store.dart' show describeFileError;
import 'file_providers.dart' show fileApiProvider;
import 'filestation_g4_text.dart';

/// USB 设备列表（可注入的 API 来自 `fileApiProvider`）。
final usbDevicesProvider = FutureProvider.autoDispose<UsbDeviceList>((
  ref,
) async {
  final fs = ref.watch(fileApiProvider);
  if (fs == null) throw StateError('not connected');
  return fs.listUsbDevices();
}, retry: noRetry);

class UsbDevicesPage extends ConsumerWidget {
  const UsbDevicesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(usbDevicesProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('fs-usb-page'),
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
                        fsG4(FsG4TextKeys.usbTitle, '外接设备'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      key: const Key('fs-usb-refresh'),
                      tooltip: t.photoRefresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: () => ref.invalidate(usbDevicesProvider),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, __) => AppEmptyState(
                    icon: Icons.usb_off_outlined,
                    title: fsG4(
                      FsG4TextKeys.usbLoadFailed,
                      '暂时取不到外接设备',
                    ),
                    message: describeFileError(e),
                    actionLabel: t.photoRetry,
                    onAction: () => ref.invalidate(usbDevicesProvider),
                  ),
                  data: (list) {
                    if (list.isEmpty) {
                      // ★ r370/r395（DA25）：`notFound` 与"服务端回了一个空列表"
                      //   **不是同一件事**，而且 404 **不等于"没插盘"**。
                      //
                      // r395 原始读数（见 `docs/evidence-r395/`）：同一分钟
                      // `list_share` 里 `usbshare1` → `real_path=/volumeUSB1/usbshare`
                      // （8.05 GB 的卷真的挂载着、Files 能列内容），本调用仍回 404；
                      // 直呼与 `SYNO.Entry.Request/compound` 两种形态都是 404，
                      // 而同一个 compound 里的兄弟 `eSATA/list` 回 **105**（权限）
                      // ⇒ 404 既不是"盘不在"也不是"没权限"，确切语义**仍未取到**。
                      //   所以这里**不许**叫用户"把 U 盘插上"（那是在撒谎），
                      //   也不许断言"NAS 上没有 U 盘"。
                      return AppEmptyState(
                        key: const Key('fs-usb-empty'),
                        icon: Icons.usb_off_outlined,
                        title: list.notFound
                            ? fsG4(
                                FsG4TextKeys.usbNoDeviceTitle,
                                '服务端没有返回外接设备（404）',
                              )
                            : fsG4(
                                FsG4TextKeys.usbEmpty,
                                '没有检测到 USB 设备',
                              ),
                        message: list.notFound
                            ? fsG4(
                                FsG4TextKeys.usbNoDeviceBody,
                                '这不代表 NAS 上没有 U 盘：本机实测 U 盘已挂载、'
                                    '「文件」里能看到它时，这个列表仍然回 404。'
                                    '在 DSM 上它通常只对管理员开放——想用盘请直接在'
                                    '「文件」里打开它。',
                              )
                            : fsG4(
                                FsG4TextKeys.usbEmptyBody,
                                '把 U 盘或移动硬盘插到 NAS 的 USB 口后，点右上角刷新。',
                              ),
                      );
                    }
                    return ListView(
                      key: const Key('fs-usb-list'),
                      padding: const EdgeInsets.all(Gap.md),
                      children: [
                        for (final d in list.devices) _UsbCard(device: d),
                      ],
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

class _UsbCard extends ConsumerWidget {
  const _UsbCard({required this.device});

  final UsbDeviceDto device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final meta = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: hud.dim);
    return Card(
      key: Key('fs-usb-device-${device.devId}'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.usb),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    device.title.isEmpty ? device.devId : device.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  key: Key('fs-usb-eject-${device.devId}'),
                  icon: const Icon(Icons.eject_outlined, size: 18),
                  label: Text(fsG4(FsG4TextKeys.usbEject, '安全弹出')),
                  onPressed: () => _confirmEject(context, ref),
                ),
              ],
            ),
            for (final p in device.partitions)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.title.isEmpty
                          ? (p.shareName.isEmpty ? p.nameId : p.shareName)
                          : p.title,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Text(
                      [
                        if (p.filesystem.isNotEmpty) p.filesystem,
                        if (p.status.isNotEmpty)
                          fsG4Fill(
                            FsG4TextKeys.usbStatus,
                            '状态：{status}',
                            {'status': p.status},
                          ),
                        if (p.totalSizeMb > 0)
                          fsG4Fill(
                            FsG4TextKeys.usbUsedOfTotal,
                            '已用 {used} / 共 {total}',
                            {
                              'used': '${p.usedSizeMb} MB',
                              'total': '${p.totalSizeMb} MB',
                            },
                          ),
                      ].join(' · '),
                      style: meta,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmEject(BuildContext context, WidgetRef ref) async {
    final fs = ref.read(fileApiProvider);
    final messenger = ScaffoldMessenger.of(context);
    if (fs == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(fsG4(FsG4TextKeys.usbEjectConfirmTitle, '安全弹出设备？')),
        content: Text(
          fsG4Fill(
            FsG4TextKeys.usbEjectConfirmBody,
            '将停止对 “{name}” 的所有读写。正在进行的传输会失败，请先确认没有任务在跑。',
            {
              'name': device.title.isEmpty ? device.devId : device.title,
            },
          ),
        ),
        actions: [
          TextButton(
            key: const Key('fs-usb-eject-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('fs-usb-eject-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(fsG4(FsG4TextKeys.usbEject, '安全弹出')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await fs.ejectUsbDevice(device.devId);
      ref.invalidate(usbDevicesProvider);
      messenger.showSnackBar(
        SnackBar(content: Text(fsG4(FsG4TextKeys.usbEjectDone, '已弹出设备'))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            fsG4Fill(FsG4TextKeys.usbEjectFailed, '弹出失败：{error}', {
              'error': describeFileError(e),
            }),
          ),
        ),
      );
    }
  }
}
