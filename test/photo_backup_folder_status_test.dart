// ★★★ D78 分类器的验证 —— 第 100 轮。
//
// 官方基准（smali 一级来源，见
// `lib/src/features/photos/photo_backup_folder_status.dart` 文件头）：
// `BackupFolderStatus$Type` 9 型 + `backup_status_*` 串。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/photos/photo_backup_folder_status.dart';

void main() {
  group('D78. 官方分类学映射（证据驱动）', () {
    test('★ HandshakeException → certificateMismatch', () {
      expect(
        PhotoBackupFolderStatus.classify(const HandshakeException('cert fail')),
        PhotoBackupFolderStatus.certificateMismatch,
      );
    });

    test('★ SocketException → noNetwork', () {
      expect(
        PhotoBackupFolderStatus.classify(
          const SocketException('connection refused'),
        ),
        PhotoBackupFolderStatus.noNetwork,
      );
    });

    test('★ DsmApiException 105 → noPermission（官方串 no_permission）', () {
      expect(
        PhotoBackupFolderStatus.classify(DsmApiException(105, method: 'list')),
        PhotoBackupFolderStatus.noPermission,
      );
    });

    test('★ DsmApiException 115 → noQuota（⚠️ 弱映射，见文件头）', () {
      expect(
        PhotoBackupFolderStatus.classify(
          DsmApiException(115, method: 'upload'),
        ),
        PhotoBackupFolderStatus.noQuota,
      );
    });

    test('★ 会话失效（106/107/119）→ error 族', () {
      for (final code in const [106, 107, 119]) {
        expect(
          PhotoBackupFolderStatus.classify(
            DsmApiException(code, method: 'list'),
          ),
          PhotoBackupFolderStatus.error,
          reason: 'code=$code',
        );
      }
    });

    test('★ 认不出 → unknown（不硬猜）', () {
      expect(
        PhotoBackupFolderStatus.classify(null),
        PhotoBackupFolderStatus.init_,
      );
      expect(
        PhotoBackupFolderStatus.classify(StateError('whatever')),
        PhotoBackupFolderStatus.unknown,
      );
      expect(
        PhotoBackupFolderStatus.classify(DsmApiException(117, method: 'x')),
        PhotoBackupFolderStatus
            .error, // ⚠️ 初稿期望 unknown 是口径写错：117 是已知 DSM 错误 ⇒ error；unknown 只给非 DSM 异常
      );
    });
  });

  group('D78. 官方对齐锚点：`officialStatusKey` 必须是官方 dex 里真实存在的串', () {
    // 官方 dex 字符串（SynologyDrive 3.9.0-1113，strings 提取）
    const officialKeys = {
      'backup_status_enabled',
      'backup_status_running',
      'backup_status_wait_network',
      'backup_status_wait_wifi',
      'backup_status_wait_charge',
      'backup_status_error_certificate',
      'backup_status_error_no_quota',
      'backup_status_error_no_permission',
      'backup_status_error_general',
      'backup_status_error_unknown',
    };

    test('★★★ 每个状态的锚点串都在官方串集合里（防止手滑编出假串）', () {
      for (final s in PhotoBackupFolderStatus.values) {
        expect(
          officialKeys.contains(s.officialStatusKey),
          isTrue,
          reason: '${s.name} 的锚点 ${s.officialStatusKey} 不在官方串里',
        );
      }
    });

    test('★ isError 的口径：错误族为真、运行/等待/成功为假', () {
      expect(PhotoBackupFolderStatus.certificateMismatch.isError, isTrue);
      expect(PhotoBackupFolderStatus.noQuota.isError, isTrue);
      expect(PhotoBackupFolderStatus.noPermission.isError, isTrue);
      expect(PhotoBackupFolderStatus.error.isError, isTrue);
      expect(PhotoBackupFolderStatus.success.isError, isFalse);
      expect(PhotoBackupFolderStatus.running.isError, isFalse);
      expect(PhotoBackupFolderStatus.noNetwork.isError, isFalse);
      expect(PhotoBackupFolderStatus.waitCharge.isError, isFalse);
      expect(PhotoBackupFolderStatus.unknown.isError, isFalse);
    });
  });
}
