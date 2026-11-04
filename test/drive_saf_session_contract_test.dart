// ★★ ③Drive 第 246 轮：**D66 的跨语言契约测试**（Dart ↔ Kotlin）。
//
// 为什么要有它：SAF provider 的"冷启动自己下"必须**两边对齐**——
// 通道名、方法名、参数键、SharedPreferences 键、接口与版本号、
// 缓存目录/文件名约定。任何一边改了名字，另一边就静默失效
// （provider 报"没配置凭据"，用户只看到打不开）。
// 这里直接**读 Kotlin 源码**做断言：改了就必须同步改测试。
//
// 与"真机未验"的分工：本用例证明**两边文本契约一致**；
// 网络路径/Keystore/冷启动时序仍**真机未验**（见 docs/device-verification.md）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/files/drive_open_on_demand.dart';
import 'package:synhub/src/features/files/drive_saf_session.dart';

const _ktDir = 'android/app/src/main/kotlin/com/openviewai/synhub';

String _read(String name) {
  final f = File('$_ktDir/$name');
  expect(f.existsSync(), isTrue, reason: '$name 必须存在（契约的另一半）');
  return f.readAsStringSync();
}

void main() {
  // 通道调用要有 binding（没有 Kotlin 对端时 invokeMethod 会抛
  // MissingPluginException，客户端必须安全降级）
  TestWidgetsFlutterBinding.ensureInitialized();

  group('D66 跨语言契约 · SAF 按需下载（Dart ↔ Kotlin）', () {
    late String session;
    late String bridge;
    late String provider;

    setUpAll(() {
      session = _read('DriveSafSession.kt');
      bridge = _read('DriveSafBridge.kt');
      provider = _read('DriveDocumentsProvider.kt');
    });

    test('★ 通道名两边一致，且已在 MainActivity 注册', () {
      expect(kDriveSafChannel, 'synhub/drive_saf');
      expect(session, contains('const val CHANNEL = "$kDriveSafChannel"'));
      expect(bridge, contains('const val CHANNEL = DriveSafSession.CHANNEL'));
      final main = _read('MainActivity.kt');
      expect(
        main,
        contains('DriveSafBridge.attach(applicationContext, flutterEngine)'),
        reason: '没挂到引擎上 ⇒ Dart 侧永远 MissingPluginException',
      );
    });

    test('★ 六个方法名两边一致（Dart 常量 vs Kotlin when 分支）', () {
      for (final m in [
        kDriveSafStoreCredentials,
        kDriveSafClearCredentials,
        kDriveSafSetOnDemand,
        kDriveSafStatus,
        kDriveSafClearCache,
        kDriveSafPrefetch,
      ]) {
        expect(
          bridge,
          contains('"$m"'),
          reason: 'Kotlin DriveSafBridge 缺少分支 `$m`',
        );
      }
    });

    test('★ 参数键两边一致（baseUrl/username/password/otp/deviceId/onDemand/on）', () {
      for (final k in [
        'baseUrl',
        'username',
        'password',
        'otp',
        'deviceId',
        'onDemand',
        'on',
        'fileId',
        'name',
      ]) {
        final readAsString = bridge.contains('call.argument<String>("$k")');
        final readAsBool = bridge.contains('call.argument<Boolean>("$k")');
        expect(
          readAsString || readAsBool,
          isTrue,
          reason: 'Kotlin 没读参数 `$k`',
        );
      }
    });

    test('★ SharedPreferences 键两边一致（provider 冷启动就靠它）', () {
      expect(session, contains('const val PREFS = "$kDriveSafPrefs"'));
      for (final k in [
        kDriveSafKeyBaseUrl,
        kDriveSafKeyUsername,
        kDriveSafKeyPasswordEnc,
        kDriveSafKeyOtp,
        kDriveSafKeyDeviceId,
        kDriveSafKeySid,
        kDriveSafKeyOnDemand,
      ]) {
        expect(session, contains('"$k"'), reason: 'Kotlin 缺少 prefs 键 `$k`');
      }
      // 密码必须是**加密**存的，不能明文
      expect(session, contains('encrypt(password)'));
      expect(session, contains('AndroidKeyStore'));
      expect(session, contains('AES/GCM/NoPadding'));
    });

    test('★ 登录接口/版本与 Dart 侧登录一致（v6 + session=SynologyDrive）', () {
      expect(session, contains('"api" to "$kDriveSafLoginApi"'));
      expect(session, contains('"method" to "$kDriveSafLoginMethod"'));
      expect(session, contains('"version" to "$kDriveSafLoginVersion"'));
      expect(session, contains('"session" to SESSION_NAME'));
      expect(session, contains('SESSION_NAME = "$kDriveSafLoginSession"'));
    });

    test('★ 下载接口/参数与 Dart `DriveApi.downloadUrl` 逐字一致（v2）', () {
      expect(session, contains('"api" to "$kDriveSafDownloadApi"'));
      expect(session, contains('"method" to "$kDriveSafDownloadMethod"'));
      expect(session, contains('"version" to "$kDriveSafDownloadVersion"'));
      expect(session, contains(r'"files" to "[\"id:$fileId\"]"'));
      expect(session, contains('"force_download" to "true"'));
      expect(session, contains('"is_preview" to "false"'));
      expect(session, contains('"_sid" to sid'));
    });

    test('★ 缓存目录名与文件名约定两边一致', () {
      expect(kSafOnDemandDirName, 'saf_ondemand');
      expect(session, contains('const val ONDEMAND_DIR = "$kSafOnDemandDirName"'));
      expect(session, contains('File(ctx.cacheDir, ONDEMAND_DIR)'));
      // 文件名：`<fileId>_<消毒名>`
      expect(session, contains('return "\${fileId}_\$safe"'));
      expect(safOnDemandFileName(fileId: 'abc', name: 'a/b'), 'abc_a_b');
      // 两边的消毒规则：`/`、`\\`、`..` 都要处理
      for (final s in ["replace('/', '_')", "replace('\\\\', '_')", 'replace("..", "_")']) {
        expect(session, contains(s), reason: 'Kotlin 缺消毒规则 $s');
      }
    });

    test('★ 文档 id → fileId 的解析：`real` 是标签不是 id（247 轮真机抓到的 bug）', () {
      // 真机序列：`:real:drive-demo-1` 曾经被解析成 `real`
      expect(safFileIdFromDocumentId(':real:drive-demo-1'), 'drive-demo-1');
      expect(safFileIdFromDocumentId(':local:offline-9'), 'offline-9');
      expect(safFileIdFromDocumentId(':label:work'), '');
      expect(safFileIdFromDocumentId(':create_folder:x'), '');
      expect(safFileIdFromDocumentId('virtualTop'), '');
      expect(safFileIdFromDocumentId(''), '');
      // 含冒号的 id 也要完整保留（不能截断）
      expect(safFileIdFromDocumentId(':real:a:b'), 'a:b');
      // Kotlin 侧必须是**逐前缀剥掉**（`startsWith` + `substring`），
      // 不能是"找冒号"那种写法
      expect(provider, contains('documentId.startsWith(PREFIX_REAL)'));
      expect(provider, contains('documentId.substring(PREFIX_REAL.length)'));
      expect(provider, contains('documentId.startsWith(PREFIX_LOCAL)'));
      // 不得用"找冒号"解析文件 id（247 轮真机 bug 的根因）
      expect(provider.contains("indexOf(':')"), isFalse);
    });

    test('★ provider 真的会走"按需下载"（并且失败时如实报错）', () {
      expect(provider, contains('openOnDemand(e, documentId)'));
      expect(provider, contains('DriveSafSession.download('));
      expect(provider, contains('按需下载失败'));
      expect(provider, contains('extractFileId'));
    });

    test('★ DSM 错误信封守卫两边都有（247 轮真机：200+错误 JSON 被当文件存过）', () {
      expect(session, contains('rejectDsmEnvelope(part)'));
      expect(session, contains('private fun rejectDsmEnvelope'));
      expect(session, contains(r'下载被拒绝（DSM 错误码 $code）'));
      // Dart 侧同规则（用例见 drive_open_on_demand_test.dart）
      expect(
        dsmErrorCodeFromBytes(utf8.encode('{"success":false,"error":{"code":119}}')),
        119,
      );
    });

    test('★ 原子落盘：Kotlin 也用 `.part` + rename（不留半个缓存）', () {
      expect(session, contains('.part'));
      expect(session, contains('part.renameTo(dest)'));
    });

    test('★ 非 Android / 通道缺失时 Dart 侧安全降级（返回"不可用"）', () async {
      // 测试环境没有 Kotlin 对端 ⇒ invokeMethod 抛 MissingPluginException，
      // 客户端必须**安全降级**而不是把异常抛给页面
      final s = DriveSafSession(
        channel: const MethodChannel('synhub/drive_saf'),
      );
      final st = await s.status();
      expect(st.configured, isFalse);
      expect(st.canColdStartDownload, isFalse);
    });
  });
}
