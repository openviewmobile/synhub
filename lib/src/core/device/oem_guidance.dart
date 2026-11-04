// ★ Android **厂商（OEM）后台保活**指引的**纯 Dart 决策层**（第 278 轮）。
//
// 为什么要有这一层：本 App **故意不用 FCM**（AGENTS §2 硬约束）。没有 FCM
// 就**没有厂商推送白名单**这条通道 —— 国内 ROM 的「应用启动管理 / 自启动 /
// 智能省电 / 深度睡眠」是唯一能决定"后台服务活不活、通知到不到"的东西。
// 于是"把用户带到正确的系统设置页"本身就是**功能的一部分**，不是文档。
//
// 三条纪律（与 `device_capability.dart` / `device_model.dart` 一致）：
//   ① **纯函数**：不碰平台通道、不碰 IO、不 import Flutter —— 这样它能被
//      离线单测逐家断言（`test/oem_guidance_test.dart`）；
//   ② **按厂商给，不给一套通稿**：每家 ROM 的设置路径不同（`oemPath*`），
//      文案走 `dataText(key, 中文回落)`，key 已登记进 `dataTextMap`，
//      并同时进了 `app_zh.arb` + `app_en.arb`（AGENTS §2.0.13 三步规则）；
//   ③ **能探测的不猜**：某家 ROM 上到底有没有「自启动管理」这个系统页面，
//      由原生 `OemCompatBridge` 用 `PackageManager` **验真**后才返回
//      （见 `oem_compat_platform.dart` 的 `autostartComponent`）；探不到就
//      只显示文字路径（`oemAutostartMissing`），**不放一个点了会报错的按钮**。
//
// 证据档位（逐家，完整矩阵见 `docs/android-compat-matrix.md`）：
//   * `honor` —— **真机验证**（HONOR LGE-AN10 / Android 12 / MagicUI 6.0.0，
//     实测 `com.hihonor.systemmanager/.startupmgr.ui.StartupNormalAppListActivity`
//     与 `/power.ui.PowerSettingActivity` 都能 `resolve-activity` 到）；
//   * `huawei` / `xiaomi` / `oppo` / `vivo` / `oneplus` / `samsung` / `meizu` /
//     `realme` / `transsion` / `google` —— **仅文档**（组件名来自公开资料，
//     本机没有这些设备 ⇒ 只做"验真后可用"，绝不假定存在）。
library;

import '../i18n/data_text.dart';

/// OEM 厂商的**稳定 id**。
///
/// ⚠️ 与原生 `OemCompatBridge.oemId()` 的字符串**一一对应**：改一边必须改两边
/// （守卫 `test/oem_guidance_test.dart` 会逐字断言这 12 个 id）。
enum OemVendor {
  xiaomi('xiaomi'),
  huawei('huawei'),
  honor('honor'),
  oppo('oppo'),
  vivo('vivo'),
  oneplus('oneplus'),
  samsung('samsung'),
  meizu('meizu'),
  realme('realme'),
  transsion('transsion'),
  google('google'),

  /// 探不到/未收录的厂商（含所有非 Android 宿主）。
  other('other');

  const OemVendor(this.id);

  /// 原生侧字符串 id（小写 ASCII）
  final String id;

  /// 原生 id → 枚举；`null`/未知 ⇒ [OemVendor.other]（**不抛**）。
  static OemVendor fromId(String? id) {
    final want = (id ?? '').trim().toLowerCase();
    for (final v in values) {
      if (v.id == want) return v;
    }
    return OemVendor.other;
  }
}

/// 该厂商省电策略的**激进程度**。
///
/// 只影响文案口吻与是否把「自启动」列为硬性步骤，不是运行时行为开关。
/// 依据（`docs/android-compat-matrix.md` §2）：dontkillmyapp 的厂商榜 +
/// 各 ROM「应用启动管理」默认值。
enum OemKillLevel {
  /// 未放行时通常几十分钟内就会被清掉（国内 ROM 主流）
  aggressive,

  /// 长时间不用会被清理
  moderate,

  /// 只有系统级 Doze / 待机分桶
  standard,
}

/// 一个**可以打开**的系统设置落点。
///
/// ⚠️ 这些 intents **只改系统设置页的可见性，不改任何 App 状态** ——
/// 不是变更动词（AGENTS §5.1），与既有的
/// `PhotoBackupPlugin.requestIgnoreBatteryOptimization` 同类。
enum OemSettingsTarget {
  /// 该厂商的「自启动 / 应用启动管理」页（组件名由原生验真后给）
  autostart('autostart'),

  /// 系统的「电池优化白名单」列表页
  /// （`Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`）
  batteryWhitelist('battery_whitelist'),

  /// 本 App 的「应用详情」页（`ACTION_APPLICATION_DETAILS_SETTINGS`）——
  /// 自启动页探不到时的**兜底落点**，用户从那里也能进「电池」分页
  appDetails('app_details');

  const OemSettingsTarget(this.id);

  final String id;

  static OemSettingsTarget? fromId(String? id) {
    final want = (id ?? '').trim();
    for (final t in values) {
      if (t.id == want) return t;
    }
    return null;
  }
}

/// 一条指引步骤。
class OemGuidanceStep {
  const OemGuidanceStep({required this.id, required this.text, this.target});

  /// 稳定 id —— 界面上的 `Key('oem-step-$id')` 就是它（测试可点）
  final String id;

  /// 已本地化的说明文字
  final String text;

  /// 可选的"打开设置"落点
  final OemSettingsTarget? target;

  @override
  String toString() => 'OemGuidanceStep($id, target=$target)';
}

/// 一个厂商的完整保活指引。
class OemGuidance {
  const OemGuidance({
    required this.vendor,
    required this.level,
    required this.path,
    required this.note,
    required this.steps,
  });

  final OemVendor vendor;
  final OemKillLevel level;

  /// 该 ROM 的**手动设置路径**（品牌专有；探不到自启动页时用户就照这个走）
  final String path;

  /// 该 ROM 特有的一句提示（例如"休眠应用要手动移出"）
  final String note;

  final List<OemGuidanceStep> steps;

  /// 该厂商是否**天然存在**「自启动 / 应用启动管理」白名单（决定要不要列出
  /// 这一步）。探不到页面 ≠ 没有这一步，所以这里只按厂商回答。
  bool get expectsAutostartPage => const {
    OemVendor.xiaomi,
    OemVendor.huawei,
    OemVendor.honor,
    OemVendor.oppo,
    OemVendor.vivo,
    OemVendor.oneplus,
    OemVendor.realme,
    OemVendor.meizu,
    OemVendor.transsion,
  }.contains(vendor);
}

/// 激进档（国内 ROM 主流）
const Set<OemVendor> kAggressiveOem = {
  OemVendor.xiaomi,
  OemVendor.huawei,
  OemVendor.honor,
  OemVendor.oppo,
  OemVendor.vivo,
  OemVendor.realme,
  OemVendor.meizu,
  OemVendor.transsion,
};

/// 中等档
const Set<OemVendor> kModerateOem = {OemVendor.oneplus, OemVendor.samsung};

/// 厂商 → 激进程度。
OemKillLevel oemKillLevel(OemVendor vendor) {
  if (kAggressiveOem.contains(vendor)) return OemKillLevel.aggressive;
  if (kModerateOem.contains(vendor)) return OemKillLevel.moderate;
  return OemKillLevel.standard;
}

/// 该厂商的「手动设置路径」文案（`dataText` 取译文，缺译文回落中文）。
String oemPathText(OemVendor vendor) => switch (vendor) {
  OemVendor.xiaomi => dataText(
    'oemPathXiaomi',
    '设置 → 应用设置 → 应用管理 → 星枢 → 自启动；返回后进「省电策略」选「无限制」',
  ),
  OemVendor.huawei => dataText(
    'oemPathHuawei',
    '设置 → 应用和服务 → 应用启动管理 → 星枢 → 关闭「自动管理」，勾选允许自启动／关联启动／后台活动',
  ),
  OemVendor.honor => dataText(
    'oemPathHonor',
    '设置 → 应用 → 应用启动管理 → 星枢 → 关闭「自动管理」，勾选允许自启动／关联启动／后台活动',
  ),
  OemVendor.oppo => dataText(
    'oemPathOppo',
    '设置 → 应用 → 应用管理 → 星枢 → 允许自启动／关联启动／后台活动 → 耗电管理选「允许后台运行」',
  ),
  OemVendor.vivo => dataText(
    'oemPathVivo',
    '设置 → 应用与权限 → 权限管理 → 自启动 → 允许星枢；再进「电池」→ 后台高耗电 → 允许',
  ),
  OemVendor.oneplus => dataText(
    'oemPathOneplus',
    '设置 → 应用 → 应用管理 → 星枢 → 耗电管理 → 允许后台运行；再关掉「智能省电」',
  ),
  OemVendor.samsung => dataText(
    'oemPathSamsung',
    '设置 → 电池和设备维护 → 电池 → 后台使用限制 → 把星枢从「休眠应用／深度休眠应用」里移除',
  ),
  OemVendor.meizu => dataText(
    'oemPathMeizu',
    '设置 → 应用管理 → 权限管理 → 后台管理 → 允许星枢后台运行',
  ),
  OemVendor.realme => dataText(
    'oemPathRealme',
    '设置 → 应用 → 应用管理 → 星枢 → 允许自启动／关联启动／后台活动 → 耗电管理选「允许后台运行」',
  ),
  OemVendor.transsion => dataText(
    'oemPathTranssion',
    '设置 → 应用 → 应用管理 → 星枢 → 允许自启动与后台活动 → 电池 → 关闭省电优化',
  ),
  OemVendor.google => dataText(
    'oemPathGoogle',
    '设置 → 应用 → 星枢 → 电池 → 选「无限制」',
  ),
  OemVendor.other => dataText(
    'oemPathOther',
    '设置 → 应用 → 星枢 → 电池 → 允许后台活动；再到「电池优化」里把星枢设为「不优化」',
  ),
};

/// 该厂商特有的一句提示。
String oemNoteText(OemVendor vendor) => switch (vendor) {
  OemVendor.huawei => dataText(
    'oemNoteHuawei',
    '华为／荣耀没装谷歌服务不影响本 App，但「应用启动管理」默认是自动管理，必须手动改。',
  ),
  OemVendor.honor => dataText(
    'oemNoteHonor',
    '荣耀 MagicOS 的「应用启动管理」默认自动管理；不手动放行时前台服务也可能被冻结。',
  ),
  OemVendor.xiaomi => dataText(
    'oemNoteXiaomi',
    'HyperOS／MIUI 还会在「最近任务」里清后台，建议同时锁定卡片。',
  ),
  OemVendor.oppo => dataText(
    'oemNoteOppo',
    'ColorOS 的「智能省电」与「深度睡眠」会冻结后台，两个都要放行。',
  ),
  OemVendor.vivo => dataText(
    'oemNoteVivo',
    'OriginOS／FuntouchOS 的「后台高耗电」默认关闭，需手动允许。',
  ),
  OemVendor.samsung => dataText(
    'oemNoteSamsung',
    'One UI 的「休眠应用／深度休眠应用」会自动把不常用的 App 加进去，需手动移出。',
  ),
  OemVendor.meizu => dataText('oemNoteMeizu', 'Flyme 的「后台管理」默认限制后台运行，需手动允许。'),
  OemVendor.realme => dataText(
    'oemNoteRealme',
    'realme UI 与 ColorOS 同源，「智能省电」同样会冻结后台。',
  ),
  OemVendor.transsion => dataText(
    'oemNoteTranssion',
    '传音机型（Tecno／Infinix／itel）的省电管理较激进，且通常没有系统级推送通道。',
  ),
  OemVendor.oneplus => dataText(
    'oemNoteOneplus',
    'OxygenOS 在 ColorOS 合并后也带「智能省电」，建议一并关闭。',
  ),
  OemVendor.google => dataText(
    'oemNoteGoogle',
    '原生／AOSP 只有 Doze 与待机分桶，没有厂商白名单；仍建议允许不受限后台。',
  ),
  OemVendor.other => dataText('oemNoteOther', '未见过的厂商：按通用步骤放行后台即可。'),
};

/// 一行的「电池优化白名单」状态文案。
String oemBatteryStateText({required bool ignored}) => ignored
    ? dataText('oemBatteryIgnored', '已加入电池优化白名单')
    : dataText('oemBatteryNotIgnored', '尚未加入电池优化白名单');

/// 厂商 → 完整指引（**纯函数**，逐家可断言）。
///
/// [autostartAvailable]：原生是否在这台机器上**验真**到了自启动系统页。
/// `false` 时不给自启动步骤挂落点（界面显示"没找到，照路径手动走"），
/// 其余步骤不受影响。
OemGuidance oemGuidanceFor(
  OemVendor vendor, {
  bool autostartAvailable = false,
}) {
  final level = oemKillLevel(vendor);
  final steps = <OemGuidanceStep>[];

  // ① 自启动（只有真的存在这套白名单的 ROM 才列）
  final expects = const {
    OemVendor.xiaomi,
    OemVendor.huawei,
    OemVendor.honor,
    OemVendor.oppo,
    OemVendor.vivo,
    OemVendor.oneplus,
    OemVendor.realme,
    OemVendor.meizu,
    OemVendor.transsion,
  }.contains(vendor);
  if (expects) {
    steps.add(
      OemGuidanceStep(
        id: 'autostart',
        text: dataText('oemStepAutostart', '允许「自启动／应用启动管理」'),
        // 探不到就**不挂落点**：点了会报错的按钮比没有按钮更糟
        target: autostartAvailable ? OemSettingsTarget.autostart : null,
      ),
    );
  }

  // ② 后台活动 / 关联启动（CN ROM 的第二道闸）
  if (level == OemKillLevel.aggressive) {
    steps.add(
      OemGuidanceStep(
        id: 'background-activity',
        text: dataText('oemStepBackgroundActivity', '允许「后台活动／关联启动」'),
      ),
    );
  }

  // ③ 电池优化（所有平台都有，落点是系统页）
  steps.add(
    OemGuidanceStep(
      id: 'battery',
      text: dataText(
        'oemStepBatteryUnrestricted',
        '电池优化设为「不限制／允许后台高耗电」',
      ),
      target: OemSettingsTarget.batteryWhitelist,
    ),
  );

  // ④ 锁定最近任务卡片（CN ROM 的"一键清理"会直接杀进程）
  if (level == OemKillLevel.aggressive) {
    steps.add(
      OemGuidanceStep(
        id: 'lock-recents',
        text: dataText(
          'oemStepLockRecents',
          '在最近任务里锁定本 App，避免被「一键清理」',
        ),
      ),
    );
  }

  return OemGuidance(
    vendor: vendor,
    level: level,
    path: oemPathText(vendor),
    note: oemNoteText(vendor),
    steps: steps,
  );
}

/// 通用（非厂商特有）的三条背景说明 —— 界面顶部固定显示。
///
/// 为什么"不用 FCM"要讲给用户听：否则用户以为"通知不到 = App 坏了"，
/// 而真相是"本机 ROM 把后台掐了"（AGENTS §2.0.17：失败原因要**可查、可解释**）。
List<String> oemGeneralNotes() => [
  dataText('oemKeepaliveIntro', '本 App 不走系统推送：只有系统允许它在后台运行，聊天与新消息通知才收得到。'),
  dataText('oemKeepaliveNoFcm', '下面的放行项建议全部打开——后台被限制时，通知会静默收不到。'),
];

/// 激进程度 → 提示文案。
String oemKillLevelText(OemKillLevel level) => switch (level) {
  OemKillLevel.aggressive => dataText(
    'oemKillAggressive',
    '该厂商的省电策略较激进，未经设置通常几十分钟内就会被清理',
  ),
  OemKillLevel.moderate => dataText(
    'oemKillModerate',
    '该厂商的省电策略中等，长时间不用可能被清理',
  ),
  OemKillLevel.standard => dataText(
    'oemKillStandard',
    '系统级省电（Doze／待机分桶），正常使用不易被清理',
  ),
};

/// 探不到自启动页时的兜底提示。
String oemAutostartMissingText() => dataText(
  'oemAutostartMissing',
  '本机没找到该厂商的自启动设置页，请按下面的路径手动操作',
);

/// 手动路径前的标签。
String oemPathLabelText() => dataText('oemPathLabel', '手动路径');
