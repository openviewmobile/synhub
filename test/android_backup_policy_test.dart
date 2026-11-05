// ★★★ r723 安全守卫：**不许把数据交给系统自动备份**。
//
// 事故形状：`<application>` 没有 `android:allowBackup` ⇒ 默认 `true` ⇒
// `<dataDir>` 里的 Drift 库（账号、聊天/笔记缓存、首连信任指纹）会被
// Google Drive 自动备份带走 —— 一份本机之外的副本，和"凭据只留本机"冲突。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _manifest() => File('android/app/src/main/AndroidManifest.xml')
    .readAsStringSync()
    .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

void main() {
  test('allowBackup=false 且云备份/迁移规则排除了所有域', () {
    final m = _manifest();
    expect(m, contains('android:allowBackup="false"'),
        reason: '默认 true 会把 dataDir 备份到 Google Drive');
    expect(m, contains('android:fullBackupContent="false"'));
    expect(m, contains('android:dataExtractionRules="@xml/data_extraction_rules"'));

    final rules =
        File('android/app/src/main/res/xml/data_extraction_rules.xml')
            .readAsStringSync();
    for (final domain in ['root', 'file', 'database', 'sharedpref', 'external']) {
      expect(rules, contains('<exclude domain="$domain" />'),
          reason: '数据迁移/云备份必须排除 $domain');
    }
    expect('<cloud-backup>'.allMatches(rules).length, 1);
    expect('<device-transfer>'.allMatches(rules).length, 1);
  });
}
