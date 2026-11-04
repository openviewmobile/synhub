// Phase 9：首连证书信任对话框。
//
// 对应原版 `AbstractCertificateUtil.showCertificateAlertDialog`
// （`str_android_certificate_not_trust_alert_content` + 证书详情 + 信任/取消）。
// 我们把证书详情直白摊开：主体、签发者、有效期、SHA-256 指纹，
// 并在**指纹变了**（可能被中间人）时用醒目提示，别让用户盲点"信任"。
import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/net/trust_store.dart';

/// 弹信任框，返回用户是否点了"信任"
Future<bool> showCertificateTrustDialog(
  BuildContext context,
  TrustChallenge challenge,
) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => CertificateTrustDialog(challenge: challenge),
  );
  return ok ?? false;
}

class CertificateTrustDialog extends StatelessWidget {
  const CertificateTrustDialog({super.key, required this.challenge});

  final TrustChallenge challenge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: Icon(
        challenge.isChanged ? Icons.gpp_maybe : Icons.verified_user_outlined,
        color: challenge.isChanged ? theme.colorScheme.error : null,
      ),
      title: Text(
        challenge.isChanged
            ? context.t.srvCertChangedTitle
            : context.t.srvCertUntrustedTitle,
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              challenge.isChanged
                  ? context.t.srvCertChangedBody(challenge.host)
                  : context.t.srvCertUntrustedBody(challenge.host),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            if (challenge.isChanged && challenge.changedFrom != null)
              _row(
                context,
                context.t.srvCertOldFingerprint,
                challenge.changedFrom!
                    .replaceAllMapped(RegExp(r'.{2}'), (m) => '${m[0]}:')
                    .replaceAll(RegExp(r':$'), ''),
                danger: true,
              ),
            _row(
              context,
              context.t.srvCertFingerprint,
              challenge.grouped,
              danger: challenge.isChanged,
            ),
            _row(
              context,
              context.t.srvCertSubject,
              challenge.subject.isEmpty ? '-' : challenge.subject,
            ),
            _row(
              context,
              context.t.srvCertIssuer,
              challenge.issuer.isEmpty ? '-' : challenge.issuer,
            ),
            _row(
              context,
              context.t.srvCertValidity,
              '${_fmt(challenge.validFrom)} ~ ${_fmt(challenge.validTo)}',
              danger: challenge.isExpired,
            ),
            if (challenge.isSelfSigned)
              _row(context, context.t.photoKind, context.t.srvCertSelfSigned),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.t.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: challenge.isChanged
              ? FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                )
              : null,
          child: Text(
            challenge.isChanged
                ? context.t.srvCertTrustAnyway
                : context.t.srvCertTrustAndContinue,
          ),
        ),
      ],
    );
  }

  static String _fmt(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  Widget _row(
    BuildContext context,
    String label,
    String value, {
    bool danger = false,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: danger ? theme.colorScheme.error : null,
                fontWeight: danger ? FontWeight.bold : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
