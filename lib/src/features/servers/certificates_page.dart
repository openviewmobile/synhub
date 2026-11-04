// Phase 9：证书管理页（原版 `BaseAbstractCertificateManageActivity` 的精简版）。
//
// 只做移动端真正需要的事：列出已信任的服务器证书（按地址），能看指纹、
// 能删除（下次连接会重新走首连信任）。原版还有"从 Synology 其他 App 导入证书"
// （`queryCertificatesFromSynoApps`）——那是同一家 App 之间的共享，我们没有对应载体，
// 有意不做。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/net/trust_store.dart';
import '../servers/session_controller.dart';
import 'connection_error_text.dart';

final trustedCertsProvider = FutureProvider<List<TrustedCert>>((ref) {
  return ref.watch(trustPolicyProvider).trusted();
});

class CertificatesPage extends ConsumerWidget {
  const CertificatesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final certs = ref.watch(trustedCertsProvider);
    return DesignScaffold(
      appBar: AppBar(title: Text(context.t.meCertificates)),
      body: certs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        // 真机缺陷同类修复（2026-09-22）：**不得**把异常原文当用户文案。
        // 连接阶段的异常一律走 `connectionUserFacingError`（用户语言 + 可操作建议），
        // 原文只进日志。详见 docs/connection-log-device-defect.md。
        error: (e, st) {
          logConnectionErrorForDiagnostics('certificates', e, st);
          return Center(child: Text(context.t.srvLoadFailed(connectionUserFacingError(e))));
        },
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(context.t.srvCertEmpty),
              ),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => _CertTile(
              cert: list[i],
              onForget: () => _forget(context, ref, list[i]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _forget(
    BuildContext context,
    WidgetRef ref,
    TrustedCert cert,
  ) async {
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.srvCertUntrustTitle),
        content: Text(t.srvCertUntrustMessage(cert.host)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(trustPolicyProvider).forget(cert.host);
    ref.invalidate(trustedCertsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.srvCertForgotten(cert.host))));
    }
  }
}

class _CertTile extends StatelessWidget {
  const _CertTile({required this.cert, required this.onForget});

  final TrustedCert cert;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DesignRowTile(
      leading: const Icon(Icons.verified_user_outlined),
      title: Text(cert.host),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            cert.sha256
                .replaceAllMapped(RegExp(r'.{2}'), (m) => '${m[0]}:')
                .replaceAll(RegExp(r':$'), ''),
            style: theme.textTheme.bodySmall,
          ),
          if (cert.savedAt.millisecondsSinceEpoch > 0)
            Text(
              context.t.srvCertTrustedAt(_fmt(cert.savedAt)),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (cert.subject.isNotEmpty)
            Text(
              cert.subject,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      trailing: IconButton(
        tooltip: context.t.srvCertUntrustTitle,
        icon: const Icon(Icons.delete_outline),
        onPressed: onForget,
      ),
    );
  }

  static String _fmt(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
