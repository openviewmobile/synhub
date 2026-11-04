// MailPlus 的**界面层文案/格式映射**（数据层给码，界面层给文字）。
//
// 与 `features/downloads/download_labels.dart`、`features/surveillance/surv_labels.dart`
// 同一套路：数据层不许 import flutter。
library;

import '../../core/i18n/l10n.dart';
import '../../core/media/cache_service.dart' show humanBytes;
import '../../data/dto/mailplus_dto.dart';

/// 邮件时间：今天的只给 `HH:mm`，更早的给 `MM-dd HH:mm`，跨年给 `yyyy-MM-dd`。
String mailTimeText(int unixSeconds, {DateTime? now}) {
  if (unixSeconds <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  final ref = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final sameDay =
      d.year == ref.year && d.month == ref.month && d.day == ref.day;
  if (sameDay) return '${two(d.hour)}:${two(d.minute)}';
  if (d.year == ref.year) {
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// 附件大小（复用全局的 `humanBytes`）。
String mailSizeText(int bytes) => humanBytes(bytes);

/// 会话列表的次要行：发件人 · 预览（截断）。
String mailThreadSubtitle(MailThreadDto thread, {int maxPreview = 60}) {
  final from = thread.from;
  final preview = thread.preview.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (preview.isEmpty) return from;
  final shown = preview.length > maxPreview
      ? '${preview.substring(0, maxPreview)}…'
      : preview;
  return from.isEmpty ? shown : '$from · $shown';
}

/// 邮箱行的次要行：路径（+ 未读数）。
String mailMailboxSubtitle(AppText t, MailMailboxDto box) {
  final parts = <String>[];
  if (box.path.isNotEmpty) parts.add(box.path);
  if (box.unreadCount > 0) parts.add('${t.mailUnread} ${box.unreadCount}');
  return parts.join(' · ');
}
