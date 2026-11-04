// ★★★ I5：**退出加密时是否删除附件** —— 官方偏好 + 确认框对齐。
//
// ## 官方证据（DSnote APK dex，一级来源）
// * 偏好键 **`delete_attachments_when_leave_encrypt`**
//   （Java 常量 `DELETE_ATTACH_WHEN_LEAVE_ENCRYPT`）；
// * 确认框文案 **`delete_attachments_when_leave_encrypt_confirm`**
//   （另有 `delete_attachment_confirm` 是普通删除附件的确认）。
//
// ## 语义
// 加密笔记"离开加密"（官方 Web/Android 的 `Note/copy` + `encrypt:false`，
// 我方菜单「复制到明文」）时，**加密附件在明文笔记里没有意义**，
// 官方因此给了一个"**同时删掉原笔记的附件**"选项，并把选择**记住**
// （下次默认沿用）——这就是 `..._leave_encrypt` 这个偏好的用途。
//
// ## 我方现状（第 106 轮）
// 之前"复制到明文"直接执行，**不问、不删**：原加密笔记的附件留着。
// 本轮补上决策层 + 落盘偏好 + UI 确认框。
import 'dart:convert';

/// 用户在"退出加密"确认框里的选择。
///
/// * [proceed] == false ⇒ 整个动作取消（不复制、不删）。
/// * [deleteAttachments] ⇒ 复制成功后删掉**原加密笔记**的附件。
typedef LeaveEncryptChoice = ({bool proceed, bool deleteAttachments});

/// 纯决策：根据"有没有附件 + 记住的偏好"算出确认框的**默认勾选**。
///
/// 没有附件时**不弹框**（官方也只在这时候需要问）。
bool defaultDeleteAttachments({
  required int attachmentCount,
  required bool remembered,
}) => attachmentCount > 0 && remembered;

/// 偏好落盘形态：`'1'` / `'0'`；认不出按 `false`。
String encodeLeaveEncryptPreference(bool deleteAttachments) =>
    deleteAttachments ? '1' : '0';

bool decodeLeaveEncryptPreference(Object? raw) {
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  final s = '$raw'.trim().toLowerCase();
  return s == '1' || s == 'true' || s == 'yes';
}

/// 偏好键（与官方同名，便于对照取证）。
const String leaveEncryptDeleteAttachmentsKey =
    'delete_attachments_when_leave_encrypt';

/// 需要弹确认框吗？（有附件才弹 —— 与官方一致）
bool shouldAskDeleteAttachments(int attachmentCount) => attachmentCount > 0;

/// 把选择序列化成 Drift KV 的字符串值。
String choiceToKv(LeaveEncryptChoice choice) =>
    jsonEncode({'proceed': choice.proceed, 'del': choice.deleteAttachments});
