// MailPlus 写信页 —— 发送 = `Draft.create` v7 再 `Draft.send` v7（官方同一流程）。
//
// ⚠️ 参数逐字对齐包内官方 `ui/mailclient.js` 的 `_getDraftParam` / `WebAPI.send`：
//   create/set: `to,cc,bcc,subject,body,attachment,temp_attachment,draft_type,
//   refer_to,enable_read_request,enable_delivery_request`（+ 可选 `from`）；
//   send: `{id}`。
// 本批只做**纯文本**正文与最基础的收件人/抄送/主题（附件上传属后置，见
// `mailplus.dart` 顶部"明确不做"）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/mailplus.dart';
import 'mail_providers.dart';

class MailComposePage extends ConsumerStatefulWidget {
  const MailComposePage({super.key});

  @override
  ConsumerState<MailComposePage> createState() => _MailComposePageState();
}

class _MailComposePageState extends ConsumerState<MailComposePage> {
  final _to = TextEditingController();
  final _cc = TextEditingController();
  final _subject = TextEditingController();
  final _body = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _to.dispose();
    _cc.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return DesignScaffold(
      appBar: AppBar(title: Text(t.mailCompose)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
        children: [
          TextField(
            key: const Key('mail-compose-to'),
            controller: _to,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: t.mailTo,
              helperText: t.mailRecipientHint,
            ),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('mail-compose-cc'),
            controller: _cc,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(labelText: t.mailCc),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('mail-compose-subject'),
            controller: _subject,
            decoration: InputDecoration(labelText: t.mailSubject),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('mail-compose-body'),
            controller: _body,
            minLines: 6,
            maxLines: 20,
            decoration: InputDecoration(labelText: t.mailBody),
          ),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            key: const Key('mail-send'),
            onPressed: _sending ? null : () => _send(context),
            icon: _sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined),
            label: Text(t.mailSend),
          ),
        ],
      ),
    );
  }

  Future<void> _send(BuildContext context) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final to = _splitAddrs(_to.text);
    if (to.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(t.mailNeedRecipient)));
      return;
    }
    setState(() => _sending = true);
    try {
      await ref
          .read(mailActionsProvider)
          .send(
            to: to,
            cc: _splitAddrs(_cc.text),
            subject: _subject.text,
            body: _body.text,
          );
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(t.mailSendDone)));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (context.mounted) setState(() => _sending = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.mailSendFailedDetail(t.mailSendFailed, describeMailError(e))),
        ),
      );
    }
  }

  /// 收件人按逗号/分号/换行拆开，去空白、去空项。
  static List<String> _splitAddrs(String raw) => [
    for (final part in raw.split(RegExp(r'[,;\n]')))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}
