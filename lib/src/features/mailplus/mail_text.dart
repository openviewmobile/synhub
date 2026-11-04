// MailPlus（Webmail 客户端）**界面文案**。
//
// ★ 与 `surv_text.dart` 同一套路：本批与其它批次并发写 `lib/l10n/*.arb`，
//   任务书硬约束**不动 ARB**。为了既遵守约束又让代码现在就能编译/跑测试，
//   这里用 Dart 扩展给 [AppText] 挂上**与计划 ARB key 同名**的 getter/method。
//   等父 agent 把 key 追加进 ARB 并 `flutter gen-l10n` 后，生成类的实例成员会
//   遮蔽本扩展，调用点 `context.t.mailXxx` 自动切到 ARB 文案，本文件可整份删除。
//
// 语言判定：`AppTextEn` → 英文，其余（含无 delegate 的 `AppTextZh`）→ 中文。
import '../../../l10n/gen/app_localizations_en.dart';
import '../../core/i18n/l10n.dart';

String _pick(AppText t, {required String zh, required String en}) =>
    t is AppTextEn ? en : zh;

/// 见文件头：与计划 ARB key 同名的扩展文案。
extension MailAppTextX on AppText {
  // ---- 列表 / 空态 / 错误态 ----
  String get mailTitle => _pick(this, zh: '邮件', en: 'MailPlus');
  String get mailEmptyTitle => _pick(this, zh: '没有邮件', en: 'No messages');
  String get mailEmptyMessage =>
      _pick(this, zh: '这个信箱里暂时没有邮件', en: 'This mailbox is empty');
  String get mailErrNotInstalled => _pick(
    this,
    zh: '这台 NAS 没有安装 MailPlus',
    en: 'MailPlus is not installed on this NAS',
  );
  String get mailNotInstalledHint => _pick(
    this,
    zh: '在 DSM「套件中心」安装 MailPlus（并先装好 MailPlus Server）后即可使用',
    en: 'Install MailPlus (and MailPlus Server first) from DSM Package Center',
  );
  String get mailErrNoPrivilege => _pick(
    this,
    zh: '这个账号没有使用 MailPlus 的权限',
    en: 'This account has no permission to use MailPlus',
  );
  String get mailNoPrivilegeHint => _pick(
    this,
    zh: '请联系管理员为这个账号授予 MailPlus 权限',
    en: 'Ask an administrator to grant this account MailPlus access',
  );
  String get mailLoadFailed =>
      _pick(this, zh: '邮箱列表加载失败', en: 'Failed to load mailboxes');
  String get mailThreadsFailed =>
      _pick(this, zh: '邮件列表加载失败', en: 'Failed to load messages');
  String get mailDetailFailed =>
      _pick(this, zh: '邮件内容加载失败', en: 'Failed to load the message');
  String get mailRetry => _pick(this, zh: '重试', en: 'Retry');

  // ---- 邮件列表 ----
  String get mailNoSubject => _pick(this, zh: '（无主题）', en: '(no subject)');
  String mailThreadCount(int count) =>
      _pick(this, zh: '共 $count 封', en: '$count messages');
  String get mailUnread => _pick(this, zh: '未读', en: 'Unread');
  String get mailFlagged => _pick(this, zh: '已加星标', en: 'Starred');
  String get mailHasAttachment => _pick(this, zh: '有附件', en: 'Attachment');
  String get mailLoadMore => _pick(this, zh: '加载更多', en: 'Load more');
  String get mailRefreshed => _pick(this, zh: '已刷新', en: 'Refreshed');

  // ---- 邮件详情 ----
  String get mailFrom => _pick(this, zh: '发件人', en: 'From');
  String get mailTo => _pick(this, zh: '收件人', en: 'To');
  String get mailDate => _pick(this, zh: '时间', en: 'Date');
  String get mailAttachments => _pick(this, zh: '附件', en: 'Attachments');
  String get mailNoBody =>
      _pick(this, zh: '这封邮件没有可显示的正文', en: 'No readable body');
  String get mailMarkRead => _pick(this, zh: '标为已读', en: 'Mark as read');
  String get mailMarkUnread => _pick(this, zh: '标为未读', en: 'Mark as unread');
  String get mailStar => _pick(this, zh: '加星标', en: 'Star');
  String get mailUnstar => _pick(this, zh: '取消星标', en: 'Unstar');
  String get mailMoveTo => _pick(this, zh: '移动到…', en: 'Move to…');
  String get mailActionDone => _pick(this, zh: '已完成', en: 'Done');
  String mailActionFailed(String reason) =>
      _pick(this, zh: '操作失败：$reason', en: 'Action failed: $reason');
  String get mailUnreadInMailbox =>
      _pick(this, zh: '未读邮件', en: 'Unread messages');

  // ---- 写信 ----
  String get mailCompose => _pick(this, zh: '写邮件', en: 'Compose');
  String get mailSubject => _pick(this, zh: '主题', en: 'Subject');
  String get mailCc => _pick(this, zh: '抄送', en: 'Cc');
  String get mailBcc => _pick(this, zh: '密送', en: 'Bcc');
  String get mailBody => _pick(this, zh: '正文', en: 'Body');
  String get mailSend => _pick(this, zh: '发送', en: 'Send');
  String get mailSendDone => _pick(this, zh: '邮件已发送', en: 'Message sent');
  String get mailSendFailed => _pick(this, zh: '发送失败', en: 'Failed to send');
  String get mailNeedRecipient =>
      _pick(this, zh: '请至少填写一个收件人', en: 'Add at least one recipient');
  String get mailRecipientHint =>
      _pick(this, zh: '多个地址用逗号分隔', en: 'Separate addresses with commas');

  // ---- 配额 / 其它 ----
  String get mailQuotaFailed =>
      _pick(this, zh: '取不到邮箱配额', en: 'Quota unavailable');
  String mailQuota(String used, String total) =>
      _pick(this, zh: '已用 $used / $total', en: '$used of $total used');
}
