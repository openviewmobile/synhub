// ★★★ I5（第 106 轮）：退出加密时删附件 —— 官方偏好 + 决策层验证。
//
// 官方证据（DSnote APK dex）：偏好 `delete_attachments_when_leave_encrypt`
// （常量 `DELETE_ATTACH_WHEN_LEAVE_ENCRYPT`）+ 确认文案
// `delete_attachments_when_leave_encrypt_confirm`。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/notes/note_leave_encrypt.dart';

void main() {
  group('I5. 决策层（官方同名偏好）', () {
    test('★ 没有附件 ⇒ 不弹框（官方也只在有附件时问）', () {
      expect(shouldAskDeleteAttachments(0), isFalse);
      expect(shouldAskDeleteAttachments(1), isTrue);
    });

    test('★ 默认勾选 = 有附件 且 上次选了删', () {
      expect(
        defaultDeleteAttachments(attachmentCount: 2, remembered: true),
        isTrue,
      );
      expect(
        defaultDeleteAttachments(attachmentCount: 2, remembered: false),
        isFalse,
      );
      // 没附件时即使记住了也是 false（不弹框，值无意义但不该变 true）
      expect(
        defaultDeleteAttachments(attachmentCount: 0, remembered: true),
        isFalse,
      );
    });

    test('★ 偏好编解码：只认 1/true/yes，其余 false', () {
      expect(encodeLeaveEncryptPreference(true), '1');
      expect(encodeLeaveEncryptPreference(false), '0');
      expect(decodeLeaveEncryptPreference('1'), isTrue);
      expect(decodeLeaveEncryptPreference('true'), isTrue);
      expect(decodeLeaveEncryptPreference('YES'), isTrue);
      expect(decodeLeaveEncryptPreference(true), isTrue);
      expect(decodeLeaveEncryptPreference(1), isTrue);
      expect(decodeLeaveEncryptPreference('0'), isFalse);
      expect(decodeLeaveEncryptPreference(null), isFalse);
      expect(decodeLeaveEncryptPreference('garbage'), isFalse);
    });

    test('★★ 偏好键必须是官方原名（防手滑改名导致对照失效）', () {
      expect(
        leaveEncryptDeleteAttachmentsKey,
        'delete_attachments_when_leave_encrypt',
      );
    });

    test('选择可序列化（进 Drift KV）', () {
      final s = choiceToKv((proceed: true, deleteAttachments: true));
      expect(s.contains('"proceed":true'), isTrue);
      expect(s.contains('"del":true'), isTrue);
    });
  });
}
