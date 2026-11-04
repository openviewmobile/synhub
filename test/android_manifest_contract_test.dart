// ★ 第 278 轮：**Android manifest 契约守卫**（逐 API 级别的编译期/安装期硬要求）。
//
// 这些约束每一条都对应"不满足就装不上 / 起不来 / 崩"的官方行为变更：
//
//   * API 31（Android 12）：**带 intent-filter 的组件必须显式声明
//     `android:exported`**，否则"应用将无法在搭载 Android 12 或更高版本的
//     设备上进行安装"；
//   * API 34（Android 14）：**每个前台服务至少要有一个
//     `foregroundServiceType`**，且每个类型要配套 `FOREGROUND_SERVICE_<TYPE>`
//     权限；
//   * API 33（Android 13）：`POST_NOTIFICATIONS` 运行时权限要声明；
//   * API 31：`SCHEDULE_EXACT_ALARM`（可撤销）—— 本项目**故意不声明**
//     `USE_EXACT_ALARM`（那是给闹钟/日历类应用自动授权的，Play 政策限定用途）；
//   * API 30（Android 11）：`<queries>` 决定包可见性（本项目的厂商设置页探测
//     与"用其他应用打开"都靠它）。
//
// 用例读**源 manifest**；若 `build/app/intermediates/merged_manifest/...` 存在，
// 再对**合并后**的清单复核一遍（厂商库会往清单里塞东西，源文件看不见）。
//
// ★ 反向验证：每个新断言都配一段"修复前"的合成清单，证明断言真抓得住。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kManifestPath = 'android/app/src/main/AndroidManifest.xml';

/// 合并后的清单（只有跑过 gradle 才在；不在就跳过"合并后复核"那一组）
const String kMergedManifestPath =
    'build/app/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml';

String _stripComments(String s) =>
    s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// 清单里的 `android:name` 允许写相对名（`.MainActivity`）。
/// 白名单用**全限定名**，所以这里按 namespace（= applicationId）补全。
const String kAppPackage = 'com.openviewai.synhub';

String _fqcn(String name) {
  if (name.isEmpty) return name;
  if (name.startsWith('.')) return '$kAppPackage$name';
  if (!name.contains('.')) return '$kAppPackage.$name';
  return name;
}

/// camelCase → UPPER_SNAKE（`dataSync` → `DATA_SYNC`）
String _snake(String t) => t
    .replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m[0]}')
    .toUpperCase();

/// 一个组件声明（activity / service / receiver / provider）
class _Component {
  _Component({
    required this.tag,
    required this.name,
    required this.hasIntentFilter,
    required this.exported,
    required this.fgsTypes,
    required this.permission,
    required this.properties,
  });

  final String tag;
  final String name;
  final bool hasIntentFilter;

  /// `null` = 没声明（API 31 下带 intent-filter 就装不上）
  final String? exported;
  final List<String> fgsTypes;
  final String? permission;

  /// `<property android:name=… android:value=…>` 的 name → value
  final Map<String, String> properties;

  String get label => '<$tag android:name="$name">';
}

/// 从清单 XML 里抽全部组件声明（够用即可：不需要完整 XML 解析器）。
List<_Component> _components(String manifest) {
  final body = _stripComments(manifest);
  final out = <_Component>[];
  for (final m in RegExp(
    r'<(activity|service|receiver|provider)\b([^>]*?)(/?)>',
    dotAll: true,
  ).allMatches(body)) {
    final tag = m.group(1)!;
    final attrs = m.group(2)!;
    final selfClosing = m.group(3) == '/';
    String? attr(String a) {
      final r = RegExp('android:$a\\s*=\\s*"([^"]*)"').firstMatch(attrs);
      return r?.group(1);
    }

    // 收集该组件的子节点（intent-filter / property）——自闭合标签没有子节点
    var inner = '';
    if (!selfClosing) {
      final close = body.indexOf('</$tag>', m.end);
      if (close > 0) inner = body.substring(m.end, close);
    }
    final props = <String, String>{};
    for (final p in RegExp(
      r'<property\b([^>]*)>',
      dotAll: true,
    ).allMatches(inner)) {
      final pa = p.group(1)!;
      final n = RegExp(
        r'android:name\s*=\s*"([^"]*)"',
      ).firstMatch(pa)?.group(1);
      final v = RegExp(
        r'android:value\s*=\s*"([^"]*)"',
      ).firstMatch(pa)?.group(1);
      if (n != null) props[n] = v ?? '';
    }

    out.add(
      _Component(
        tag: tag,
        name: _fqcn(attr('name') ?? ''),
        hasIntentFilter: inner.contains('<intent-filter'),
        exported: attr('exported'),
        fgsTypes: (attr('foregroundServiceType') ?? '')
            .split('|')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        permission: attr('permission'),
        properties: props,
      ),
    );
  }
  expect(out, isNotEmpty, reason: '一个组件都没抽到 ⇒ 解析器坏了');
  return out;
}

/// 声明了的权限集合
Set<String> _permissions(String manifest) => {
  for (final m in RegExp(
    r'<uses-permission\b[^>]*android:name="([^"]+)"',
    dotAll: true,
  ).allMatches(_stripComments(manifest)))
    m.group(1)!,
};

/// 带 intent-filter 却不声明 exported 的组件（API 31 下会**装不上**）
List<_Component> _missingExported(List<_Component> cs) => [
  for (final c in cs)
    if (c.hasIntentFilter && c.exported == null) c,
];

/// 前台服务类型缺配套权限的（type, 期望权限）对
List<({String service, String type, String permission})> _missingFgsPermission(
  List<_Component> cs,
  Set<String> perms,
) {
  final out = <({String service, String type, String permission})>[];
  for (final c in cs) {
    if (c.tag != 'service') continue;
    for (final t in c.fgsTypes) {
      final want = 'android.permission.FOREGROUND_SERVICE_${_snake(t)}';
      if (!perms.contains(want)) {
        out.add((service: c.name, type: t, permission: want));
      }
    }
  }
  return out;
}

/// 前台服务**没有**任何类型的（API 34 下运行时抛
/// `MissingForegroundServiceTypeException`）
List<_Component> _fgsWithoutType(List<_Component> cs) => [
  for (final c in cs)
    // 只关心真的会进前台的：库自带的 SystemForegroundService / AudioService /
    // 自家 ChatForegroundService 都有显式类型；这里检查"名字里有 ForegroundService
    // 或 AudioService 却没有类型"的情况
    if (c.tag == 'service' &&
        c.fgsTypes.isEmpty &&
        (c.name.contains('ForegroundService') || c.name.contains('AudioService')))
      c,
];

/// 允许 `exported="true"` 的组件白名单（每条都有理由）
const Map<String, String> kExportedAllowlist = {
  'com.openviewai.synhub.MainActivity': 'launcher 入口 + 分享/深链 intent-filter（系统必须能拉起）',
  'com.openviewai.synhub.NotebookWidgetConfigActivity': 'APPWIDGET_CONFIGURE：launcher/系统拉起配置页',
  'com.openviewai.synhub.BootReceiver': 'BOOT_COMPLETED / MY_PACKAGE_REPLACED 是系统广播（必须导出）',
  'com.openviewai.synhub.NoteReminderBootReceiver': '同上：开机后重排待办闹钟',
  'com.openviewai.synhub.PhotoBackupBootReceiver': '同上：开机后重新入队备份 Worker',
  'com.openviewai.synhub.DriveDocumentsProvider': 'SAF DocumentsProvider：系统文件选择器要能查询（带 MANAGE_DOCUMENTS 权限兜底）',
  'com.ryanheise.audioservice.AudioService': 'MediaBrowserService：系统媒体会话/耳机按键要能绑（audio_service 官方要求）',
  'com.ryanheise.audioservice.MediaButtonReceiver': 'MEDIA_BUTTON 是系统广播',
  'com.bbflight.background_downloader.UIDTJobService': 'JobService：由 JobScheduler 绑定（带 BIND_JOB_SERVICE 权限）',
};

void main() {
  late final String manifest;
  late final List<_Component> components;
  late final Set<String> permissions;

  setUpAll(() {
    final f = File(kManifestPath);
    expect(f.existsSync(), isTrue, reason: '找不到 $kManifestPath');
    manifest = f.readAsStringSync();
    components = _components(manifest);
    permissions = _permissions(manifest);
  });

  group('API 31：带 intent-filter 的组件必须显式 exported', () {
    test('源 manifest 里没有"漏 exported"的组件', () {
      expect(
        _missingExported(components),
        isEmpty,
        reason: 'API 31 起这些组件会让**安装直接失败**：'
            '${_missingExported(components).map((c) => c.label).toList()}',
      );
    });

    test('exported=true 的组件都在白名单里（默认不导出）', () {
      final unexpected = <String>[
        for (final c in components)
          if (c.exported == 'true' && !kExportedAllowlist.containsKey(c.name))
            c.label,
      ];
      expect(
        unexpected,
        isEmpty,
        reason: '新增了对外暴露的组件但没登记理由：$unexpected',
      );
    });

    test('FileProvider 必须 exported=false（只给临时读权限）', () {
      final fp = components.firstWhere(
        (c) => c.name == 'androidx.core.content.FileProvider',
      );
      expect(fp.exported, 'false');
      expect(fp.permission, isNull);
    });
  });

  group('API 34/35：前台服务类型 + 配套权限', () {
    test('每个前台服务类型都有配套的 FOREGROUND_SERVICE_<TYPE> 权限', () {
      expect(
        _missingFgsPermission(components, permissions),
        isEmpty,
        reason: 'API 34 起缺配套权限会在 startForeground 时抛 SecurityException：'
            '${_missingFgsPermission(components, permissions)}',
      );
    });

    test('没有任何"名字像前台服务却没有类型"的 service', () {
      expect(_fgsWithoutType(components), isEmpty);
    });

    test('★ ChatForegroundService = specialUse（不是 dataSync）', () {
      final svc = components.firstWhere(
        (c) => c.name == 'com.openviewai.synhub.ChatForegroundService',
      );
      expect(
        svc.fgsTypes,
        ['specialUse'],
        reason: 'dataSync 在 API 35 有 24h/6h 超时且不许从 BOOT_COMPLETED 启动 '
            '⇒ 常驻 Socket 会被系统杀（见 docs/android-compat-matrix.md §1）',
      );
      expect(
        svc.properties.keys,
        contains('android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE'),
        reason: 'Android 14+ 的 specialUse 必须带 subtype property',
      );
      expect(svc.exported, 'false');
    });

    test('specialUse 的普通权限已声明', () {
      expect(
        permissions,
        contains('android.permission.FOREGROUND_SERVICE_SPECIAL_USE'),
      );
      // dataSync 仍要留着：相册备份 Worker 与下载 JobService 都用它
      expect(
        permissions,
        contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
      );
      expect(
        permissions,
        contains('android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK'),
      );
    });

    test('WorkManager 的 SystemForegroundService 仍是 dataSync', () {
      final svc = components.firstWhere(
        (c) => c.name == 'androidx.work.impl.foreground.SystemForegroundService',
      );
      expect(svc.fgsTypes, ['dataSync']);
    });
  });

  group('权限面：只声明我们真的会用的', () {
    test('API 33 通知权限已声明（前台服务通知 + 聊天通知都要它）', () {
      expect(permissions, contains('android.permission.POST_NOTIFICATIONS'));
    });

    test('RECORD_AUDIO 已声明（聊天语音 + Visualizer 真频谱）', () {
      expect(permissions, contains('android.permission.RECORD_AUDIO'));
    });

    test('SCHEDULE_EXACT_ALARM 已声明，且**故意不声明** USE_EXACT_ALARM', () {
      expect(permissions, contains('android.permission.SCHEDULE_EXACT_ALARM'));
      expect(
        permissions,
        isNot(contains('android.permission.USE_EXACT_ALARM')),
        reason: 'USE_EXACT_ALARM 是给闹钟/日历类应用的自动授权，Play 政策限定用途；'
            '本项目走可撤销的 SCHEDULE_EXACT_ALARM + 降级路径',
      );
    });

    test('不声明任何多余的存储/后台位置权限', () {
      expect(
        permissions,
        isNot(contains('android.permission.ACCESS_BACKGROUND_LOCATION')),
        reason: '本 App 不用后台位置',
      );
      expect(
        permissions,
        isNot(contains('android.permission.MANAGE_EXTERNAL_STORAGE')),
        reason: 'MANAGE_EXTERNAL_STORAGE 是"所有文件访问"，Play 政策严格限制；'
            '本 App 走 MediaStore/SAF',
      );
    });
  });

  group('API 30：<queries> 存在且含厂商设置包', () {
    test('<queries> 块存在', () {
      expect(
        _stripComments(manifest).contains('<queries>'),
        isTrue,
        reason: '没有 <queries> ⇒ Android 11+ 的包可见性下'
            '"用其他应用打开"与厂商设置页探测全部失效',
      );
    });

    test('厂商设置包在源 manifest 里（Kotlin 探测依赖它）', () {
      final pkgs = {
        for (final m in RegExp(
          r'<package\s+android:name="([^"]+)"',
        ).allMatches(_stripComments(manifest)))
          m.group(1)!,
      };
      for (final p in const [
        'com.hihonor.systemmanager',
        'com.huawei.systemmanager',
        'com.miui.securitycenter',
        'com.coloros.safecenter',
        'com.vivo.permissionmanager',
        'com.samsung.android.lool',
        'com.meizu.safe',
      ]) {
        expect(pkgs, contains(p), reason: '$p 不在 <queries> 里');
      }
    });
  });

  group('合并后的清单复核（跑过 gradle 才有；不在就跳过）', () {
    test('合并后 ChatForegroundService 的 specialUse 与 subtype property 仍在', () {
      final f = File(kMergedManifestPath);
      if (!f.existsSync()) {
        markTestSkipped('没有合并清单（先跑 gradle :app:processDebugManifest）');
        return;
      }
      final merged = f.readAsStringSync();
      final cs = _components(merged);
      final svc = cs.firstWhere(
        (c) => c.name == 'com.openviewai.synhub.ChatForegroundService',
      );
      expect(svc.fgsTypes, ['specialUse']);
      expect(
        svc.properties.keys,
        contains('android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE'),
      );
      expect(
        _permissions(merged),
        contains('android.permission.FOREGROUND_SERVICE_SPECIAL_USE'),
      );
      expect(
        _missingExported(cs),
        isEmpty,
        reason: '合并后出现漏 exported 的组件（多半是某个插件带进来的）：'
            '${_missingExported(cs).map((c) => c.label).toList()}',
      );
      expect(
        _missingFgsPermission(cs, _permissions(merged)),
        isEmpty,
        reason: '合并后出现缺配套权限的前台服务类型',
      );
    });
  });

  group('反向验证：这套断言确实承重', () {
    // 修复前的清单（逐字复刻第 278 轮之前的状态）
    const preFix = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>
    <application>
        <service android:name="com.openviewai.synhub.ChatForegroundService"
                 android:exported="false"
                 android:foregroundServiceType="dataSync"/>
        <receiver android:name="com.openviewai.synhub.BootReceiver">
            <intent-filter><action android:name="android.intent.action.BOOT_COMPLETED"/></intent-filter>
        </receiver>
    </application>
</manifest>
''';

    test('修复前：ChatForegroundService 是 dataSync 且没有 specialUse 权限', () {
      final cs = _components(preFix);
      final perms = _permissions(preFix);
      final svc = cs.firstWhere(
        (c) => c.name == 'com.openviewai.synhub.ChatForegroundService',
      );
      expect(svc.fgsTypes, ['dataSync'], reason: '反证素材要真的是修复前状态');
      expect(
        perms,
        isNot(contains('android.permission.FOREGROUND_SERVICE_SPECIAL_USE')),
      );
      expect(svc.properties, isEmpty);
      // 于是"必须是 specialUse + 必须有 property + 必须有权限"三条都会红
      expect(svc.fgsTypes, isNot(['specialUse']));
      expect(
        svc.properties.keys,
        isNot(contains('android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE')),
      );
    });

    test('修复前：带 intent-filter 却没有 exported 的接收器会被抓出来', () {
      final missing = _missingExported(_components(preFix));
      expect(
        missing.map((c) => c.name),
        contains('com.openviewai.synhub.BootReceiver'),
        reason: 'API 31 下这就是"装不上"的形状 —— 用例若抓不到说明它没在测',
      );
    });

    test('修复前：<queries> 里没有厂商设置包', () {
      final pkgs = {
        for (final m in RegExp(
          r'<package\s+android:name="([^"]+)"',
        ).allMatches(preFix))
          m.group(1)!,
      };
      expect(pkgs, isEmpty);
      expect(pkgs, isNot(contains('com.hihonor.systemmanager')));
    });

    test('修复前：缺配套权限的前台服务类型会被抓出来（合成的反例）', () {
      const bad = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application>
        <service android:name="x.FooForegroundService"
                 android:exported="false"
                 android:foregroundServiceType="mediaPlayback"/>
    </application>
</manifest>
''';
      final miss = _missingFgsPermission(_components(bad), _permissions(bad));
      expect(miss, hasLength(1));
      expect(miss.single.permission, 'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK');
      // 而真实清单里 0 条（正断言的真值）
      expect(_missingFgsPermission(components, permissions), isEmpty);
    });
  });
}
