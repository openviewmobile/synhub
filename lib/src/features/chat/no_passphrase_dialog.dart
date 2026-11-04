// 「有成员没设口令」弹窗（加密频道的创建 / 邀请共用）。
//
// 对位原版 `dialog_no_passphrase.xml` + `NamedCreateFragment.showNoPublicKeyUsers`
// / `AnonymousInviteFragment.removeNoPassphraseUsers`：
//
//   * 标题 `R.string.error`，正文 `error_no_passphrase_desc`：
//     "%1$d of the selected users have not configured their passphrase.
//      Click %2$s to remove these users and proceed with channel encryption."
//   * 一个**默认不勾**的复选框 `notify_no_passphrase_users`：
//     "Notify unauthorized users to configure their passphrases."
//     —— 勾了才会调 `User / notify_encrypt` 去提醒这些人。
//   * 点「确定」= **把这些人移出邀请列表**，用剩下的人继续建/邀请。
//
// 返回 true = 勾了「通知他们」，false = 确定但没勾，null = 取消/点空白关掉。
import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';

Future<bool?> showNoPassphraseDialog(
  BuildContext context, {
  required int count,
}) {
  var notify = false;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(ctx.t.chatNoPassphraseTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ctx.t.chatNoPassphraseBody(count)),
            const SizedBox(height: 10),
            InkWell(
              onTap: () => setState(() => notify = !notify),
              child: Row(
                children: [
                  Checkbox(
                    value: notify,
                    onChanged: (v) => setState(() => notify = v ?? false),
                  ),
                  Expanded(child: Text(ctx.t.chatNoPassphraseNotify)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // 取消 → pop(null)，与「确定但没勾通知」的 false 区分开
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(notify),
            child: Text(ctx.t.actionOk),
          ),
        ],
      ),
    ),
  );
}
