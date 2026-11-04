// 结构性守卫：`lib/` 里每个 `MethodChannel(...)` 调用点都必须**先过能力门控**。
//
// 为什么需要它（第 59 轮补）：
//   * 本仓大量桥只有 **Kotlin 一份实现**（抽帧、投屏、流量、SAF、小组件、深链、分享…）。
//     把这类通道交给 macOS / iOS / Linux / Windows 时会抛 `MissingPluginException` ——
//     这是**预期路径**，不是崩溃，但必须变成"能力层给出的明确结论 + 界面写明原因"。
//   * 逐点用例（`test/platform_capability_test.dart`）只能覆盖**已经发现**的通道；
//     以后新加一个通道忘了门控，它抓不到。
//   * 这道守卫扫全仓：新增通道若不过 `capabilityGateAllows(...)`，这里直接红。
//
// ## 判定口径（第 79 轮重写：修掉**泛型盲区**）
//
// 旧版用字面量 `'invokeMethod('` 当调用点标记 ⇒ **带泛型的调用一个都看不见**
// （`invokeMethod<bool>(` / `invokeMethod<Object?>(`）——`video_frame_bridge.dart`
// 因此被扫到 0 个调用点、守卫照样绿，而真机上视频抽帧整条路恒 false（第 76 轮
// 用户可见回归）。这就是"扫到 0 条不是通过"的同族错误。本版改成**正则**：
//
//   `invokeMethod` / `invokeListMethod` / `invokeMapMethod` / `setMethodCallHandler`
//   + **可选的泛型实参**（含嵌套，如 `invokeMapMethod<String, Object?>`）
//   + 可选链式写法（`MethodChannel('x').invokeMethod<void>('y')` 会被当调用点）。
//
// 每个调用点前面 **2000 字符窗口**里，必须出现下列**任意一种**"门"：
//   * `capabilityGateAllows(...)`（统一入口，首选；见 `app_platform.dart`）；
//   * **命名门符号**：同文件里定义了 `X => capabilityGateAllows(...)` /
//     `X = capabilityGateAllows(...)`，且调用点窗口里写了 `!X`。
//     本仓既有惯用法是 `static bool get _allowed => capabilityGateAllows(...)`
//     + 每个方法 `if (!_allowed) { _logBlocked(...); return ...; }`。
//     认它**不等于**放宽：① 符号必须在**同一文件**里由 `capabilityGateAllows`
//     定义；② 调用点必须**自己**写了 `!X`（只定义、不检查的裸调用照样报）。
//   * `gate-exempt: <登记名>` —— 显式豁免，且 `<登记名>` 必须出现在
//     [kGateExemptChannels] 里（逐条写理由）。**不登记一律不算豁免**。
//
// 邻域级（而不是整文件级）是为了防止"文件里有一处门控，就把同文件里另一个
// 裸调用放过"——用例 ②(i) 就是钉这一条的。
//
// ## 实测基准（口径没死掉的证据；每次重写/扩表都要核对）
//   第 79 轮重写时 `lib/`：通道**调用点 116**、`MethodChannel(` **声明 45**、
//   命名门符号定义 **13 处**。判定阈值取"明显低于实测但不为 0"。
//
// 豁免规则：**只有**在紧邻的注释里写了 `gate-exempt: <登记名>` 且该名字已登记才
//   允许 —— allowlist 在下面逐条列出并说明原因。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 允许"没有能力门控"的通道/作用域，**每条都要写理由**。
///
/// 本仓 `lib/` 里所有出站 `MethodChannel` 调用都应经过
/// `lib/src/core/platform/app_platform.dart` 的 `capabilityGateAllows(...)`。
/// 唯一的例外是**能力层自己的探测入口**（"先打一次通道才知道桥在不在"，
/// 给它加门等于用结论证明结论）。
const Map<String, String> kGateExemptChannels = <String, String>{
  'wallpaper-color':
      'lib/src/core/theme/wallpaper_seed.dart 的 `synhub/wallpaper`：'
      '这条通道**天生允许不存在**——非 Android 宿主（桌面/Web/测试）没有壁纸概念，'
      '**"取不到壁纸色"本身就是设计内的正常结果**（按能力门控表分级反而会把'
      '“个性化取色”提升成一项平台能力，与 DA160 的口径冲突）。'
      '`readWallpaperSeed` 用 try/catch 兜住 `MissingPluginException`'
      '⇒ 回 `WallpaperColorSource.none`，界面回退品牌蓝并在设置里写明原因；'
      '用例 `test/wallpaper_seed_test.dart` 专门钉了“通道抛异常不许冒泡”。'
      '（第 231 轮：新增取色桥时该守卫当场变红，故选“显式豁免+理由”而不是造一个假能力。）',
  'capability-prober':
      'app_platform.dart 的 _platformProbe：能力层自身的探测入口，'
      '必须先打通道才能得到结论；对它门控会形成循环。',
  'fold-posture-hinge':
      'lib/src/core/ui/fold_posture.dart 的 PlatformFoldPostureFeed：'
      '铰链角是 **Android 折叠屏的物理量**，非 Android 宿主上这个量**不存在**'
      '（定义域外，不是"能力缺失"）⇒ 不进 AppCapability 表，'
      '与 app_paths.dart 的 `host != AppHost.android` 同一手法；'
      '通道只在构造点 forHost() 判为 Android 时才建，'
      '非 Android 走 NullFoldPostureFeed（不建任何通道）。'
      '（第 295 轮：此前该调用点被判未门控，宿主/容器各自复现 +2 -1。）',
  'browser-back-key':
      'lib/src/features/downloads/download_link_browser.dart 的 `synhub/browser_back`'
      '（DA62，第 409 轮）：它修的是 **Android 的 WebView 把系统返回键吃掉**这个'
      '**物理行为** —— 非 Android 宿主上 WebView 平台视图根本不存在、'
      'Flutter/系统的返回路径本来就是好的 ⇒ 那一档**没有这个缺陷**'
      '（定义域外，不是"能力缺失"），也就没有"不能做"要对用户说明的东西。'
      '调用点只在 `defaultTargetPlatform == TargetPlatform.android` 时 arm，'
      '其它宿主一个字节都不发；缺插件（测试/宿主）走 catch，页面不受影响。',
  'video-pip':
      'lib/src/features/media/video_pip.dart 的 `synhub/video_pip`（DA259，第 654 轮）：'
      '画中画是 **Android Activity 的窗口能力**（`enterPictureInPictureMode` + Manifest '
      '`supportsPictureInPicture`）—— 非 Android 宿主上**根本没有小窗这个概念**'
      '（定义域外，不是"能力缺失"），也就没有"不能做"要对用户说明的东西。'
      '`SystemVideoPip` 先问 `supported`，false 时**按钮根本不渲染**；'
      '所有 invoke 都 `try/catch` 兜 `MissingPluginException`/`PlatformException` '
      '⇒ 宿主/测试环境退化为"这台机器没有画中画"，与今天行为一致。'
      '（判据不是"通道抛没抛"，而是"界面有没有摆假按钮"。）',
  'media-notification-tap':
      'lib/src/features/audio/media_notification_tap_host.dart 的 '
      '`synhub/media_notification_tap`（DA257，第 653 轮）：这条通道传的是 '
      '**Android 媒体通知被点了一下**这件事 —— 非 Android 宿主上**没有媒体通知**'
      '（定义域外，不是"能力缺失"），也就没有"不能做"要对用户说明的东西。'
      '`MediaNotificationTapHost` 只在 Android 上挂（外壳里与迷你条同一处），'
      '`getPending` / 事件回调全部 `try/catch` 兜住 `MissingPluginException`'
      '⇒ 宿主/测试环境退化成"没有人点通知"，界面行为与今天完全一致；'
      '冷启动等不到"真的在播"时也**什么都不开**（不凭空给空播放页）。',
};

/// 会真正碰到平台的调用点（**声明不算**）。
///
/// 用正则而不是字面量：**必须覆盖泛型形态**（见文件头第 79 轮说明）。
final RegExp kChannelCallPattern = RegExp(
  r'\b(?:invokeMethod|invokeListMethod|invokeMapMethod|setMethodCallHandler)'
  r'\s*(?:<[^()<>]*(?:<[^()<>]*>[^()<>]*)*>)?\s*\(',
);

/// 本文件里"命名门符号"的名字集合。
///
/// 形如 `static bool get _allowed => capabilityGateAllows(AppCapability.x);`
/// 或 `final _gate = capabilityGateAllows(...);`。
Set<String> gateSymbolsOf(String source) {
  final out = <String>{};
  final re = RegExp(r'(\w+)\s*(?:=>|=)\s*capabilityGateAllows\s*\(');
  for (final m in re.allMatches(source)) {
    out.add(m.group(1)!);
  }
  return out;
}

/// 窗口里最后一条 `gate-exempt:` 的**登记名**；没登记 ⇒ null。
String? gateExemptReason(String window) {
  final all = RegExp(r'gate-exempt:\s*([^\n]*)').allMatches(window).toList();
  if (all.isEmpty) return null; // 没写 gate-exempt
  final line = all.last.group(1) ?? '';
  for (final entry in kGateExemptChannels.entries) {
    if (line.contains(entry.key)) return entry.value;
  }
  return null; // 写了理由但没登记 ⇒ 不算豁免
}

/// 命名门符号的**定义**形态（`X => capabilityGateAllows(` / `X = capabilityGateAllows(`）。
final RegExp kGateDefinitionPattern = RegExp(
  r'\w+\s*(?:=>|=)\s*capabilityGateAllows\s*\(',
);

/// 去掉 Dart 注释（**长度守恒**：注释字符换成空格/换行，偏移量不变）。
///
/// 为什么必须去注释：门控的判据是"代码里真的调了 `capabilityGateAllows`"。
/// 若把注释也算进去，只要文件头写一句"应该用 capabilityGateAllows"就能
/// 让整个文件的裸调用假绿 —— 第 76 轮的回归文件里恰好就有这种注释。
String stripDartComments(String source) {
  final out = StringBuffer();
  bool line = false;
  bool block = false;
  String? quote;
  bool esc = false;
  for (int i = 0; i < source.length; i++) {
    final String c = source[i];
    final String n = i + 1 < source.length ? source[i + 1] : '';
    if (line) {
      if (c == '\n') {
        line = false;
        out.write(c);
      } else {
        out.write(' ');
      }
      continue;
    }
    if (block) {
      if (c == '*' && n == '/') {
        block = false;
        out.write('  ');
        i++;
      } else {
        out.write(c == '\n' ? '\n' : ' ');
      }
      continue;
    }
    if (quote != null) {
      out.write(c);
      if (esc) {
        esc = false;
      } else if (c == '\\') {
        esc = true;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '/' && n == '/') {
      line = true;
      out.write('  ');
      i++;
      continue;
    }
    if (c == '/' && n == '*') {
      block = true;
      out.write('  ');
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
    }
    out.write(c);
  }
  return out.toString();
}

/// 判定一个调用点是否"被门控"。
///
/// 返回值：`null` = 门控正常；否则返回**未门控的原因**（便于测试直接打印修法）。
String? ungatedReason(String source, int channelIndex) {
  final String stripped = stripDartComments(source);
  return _ungated(stripped, source, channelIndex, gateSymbolsOf(stripped));
}

String? _ungated(
  String stripped,
  String raw,
  int channelIndex,
  Set<String> symbols,
) {
  final int start = channelIndex - 2000 < 0 ? 0 : channelIndex - 2000;
  // 先把"命名门符号的**定义**"掩掉：定义里那个 `capabilityGateAllows(` 只说明
  // 符号是门，**不构成**对当前调用点的门控 —— 否则"文件里定义了 `_allowed`、
  // 但这个方法根本没查"就会假绿（用例 ②(i) 钉的就是这一条）。
  final String window = stripped
      .substring(start, channelIndex)
      .replaceAll(kGateDefinitionPattern, '/*gate-def*/(');
  if (window.contains('capabilityGateAllows')) return null;
  // 豁免理由写在注释里 ⇒ 用**原文**窗口判（去注释后 marker 就没了）。
  if (gateExemptReason(raw.substring(start, channelIndex)) != null) return null;
  for (final symbol in symbols) {
    // 命名门符号必须**在调用点被自己检查过**：`if (!_allowed) …`。
    if (RegExp('!\\s*${RegExp.escape(symbol)}\\b').hasMatch(window)) return null;
  }
  return '前 2000 字符内既没有 capabilityGateAllows、'
      '也没有（同文件定义且在此处 `!X` 检查过的）命名门符号、'
      '也没有登记过的 `gate-exempt:` 理由';
}

/// 从一整份 Dart 源码里挑出所有**未门控**的通道调用点位置。
List<int> ungatedChannelOffsets(String source) {
  final String stripped = stripDartComments(source);
  final Set<String> symbols = gateSymbolsOf(stripped);
  final out = <int>[];
  for (final m in kChannelCallPattern.allMatches(stripped)) {
    if (_ungated(stripped, source, m.start, symbols) != null) out.add(m.start);
  }
  out.sort();
  return out;
}

/// 源码里**任何**会碰平台的调用点（门控与否都算）—— 用于防空转计数。
/// 注释掉的调用**不算**（`stripDartComments` 之后再数）。
int channelCallSites(String source) =>
    kChannelCallPattern.allMatches(stripDartComments(source)).length;

int _lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

void main() {
  final dir = Directory('lib');

  test('① lib/ 里每个 MethodChannel 调用点都先过能力门控（或显式豁免并写理由）', () {
    expect(dir.existsSync(), isTrue, reason: '要在仓库根目录跑（找不到 lib/）');

    final offenders = <String>[];
    int scanned = 0; // 通道**调用点**（危险面）
    int declared = 0; // 通道**声明**（口径是否还成立的第二路信号）
    int gateDefinitions = 0; // 命名门符号定义（第三路信号：门符号识别没死）

    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String src;
      try {
        src = entity.readAsStringSync();
      } catch (_) {
        continue; // 非 UTF-8 / 读不了：不静默算通过，下面用计数兜底
      }
      scanned += channelCallSites(src);
      declared += 'MethodChannel('.allMatches(src).length;
      gateDefinitions += RegExp(r'\w+\s*(?:=>|=)\s*capabilityGateAllows\s*\(')
          .allMatches(src)
          .length;
      for (final int i in ungatedChannelOffsets(src)) {
        offenders.add(
          '${entity.path}:${_lineOf(src, i)}  ${ungatedReason(src, i)}',
        );
      }
    }

    // 防空转（三路信号，缺一不可）：一个都没扫到 = 守卫失效，**不是**"通过"。
    // 实测基准见文件头（第 79 轮：调用点 116 / 声明 45 / 命名门 13）。
    expect(
      declared,
      greaterThanOrEqualTo(40),
      reason: '只扫到 $declared 个 MethodChannel 声明 —— 扫描口径可能已失效，别当通过',
    );
    expect(
      scanned,
      greaterThanOrEqualTo(110),
      reason: '只扫到 $scanned 个通道调用点 —— 扫描口径可能已失效，别当通过',
    );
    expect(
      gateDefinitions,
      greaterThanOrEqualTo(10),
      reason: '只扫到 $gateDefinitions 处 capabilityGateAllows 命名门定义 —— '
          '命名门识别路径可能已失效，别当通过',
    );

    expect(
      offenders,
      isEmpty,
      reason:
          '以下通道在宿主上会抛 MissingPluginException 而**没有**走能力门控：\n'
          '${offenders.join('\n')}\n\n'
          '修法：在调用点前用 capabilityGateAllows(<AppCapability.xxx>) 拦一道，'
          '拿不到能力就降级并写明原因（照 lib/src/features/chat/chat_deep_link.dart:225 的写法）；'
          '确属"所有平台都实现、无需门控"的，在 kGateExemptChannels 里加名字 + 理由。',
    );
  });

  test('② 反向验证：泛型裸调用必须被抓到；声明与已门控不得误伤', () {
    // (a) 字面量裸调用
    expect(
      ungatedChannelOffsets("_ch.invokeMethod('ping');"),
      hasLength(1),
    );

    // (b) ★ 第 79 轮回归：**泛型**裸调用
    //     （旧标记 `'invokeMethod('` 看不见它 ⇒ `video_frame_bridge.dart` 被漏扫）
    expect(
      ungatedChannelOffsets("_ch.invokeMethod<bool>('ping');"),
      hasLength(1),
    );

    // (c) 嵌套泛型
    expect(
      ungatedChannelOffsets("_ch.invokeMethod<Map<Object?, Object?>>('ping');"),
      hasLength(1),
    );

    // (d) 另外两个调用点标记的泛型形态
    expect(
      ungatedChannelOffsets("_ch.invokeListMethod<Object?>('x');"),
      hasLength(1),
    );
    expect(
      ungatedChannelOffsets("_ch.invokeMapMethod<String, Object?>('x');"),
      hasLength(1),
    );
    expect(
      ungatedChannelOffsets("_ch.setMethodCallHandler((c) async => null);"),
      hasLength(1),
    );

    // (e) `MethodChannel(...)` 上的链式调用也算调用点
    expect(
      ungatedChannelOffsets("MethodChannel('synhub/x').invokeMethod<void>('y');"),
      hasLength(1),
    );

    // (f) 只有声明、没有调用 ⇒ **不该**报（声明不碰平台）
    expect(
      ungatedChannelOffsets("const _ch = MethodChannel('synhub/x');"),
      isEmpty,
    );

    // (g) 过了门控的泛型调用 ⇒ 必须放行
    expect(
      ungatedChannelOffsets('''
        if (!capabilityGateAllows(AppCapability.localMediaPlayback)) return;
        _ch.invokeMethod<bool>('x');
      '''),
      isEmpty,
    );

    // (h) 命名门符号 + 调用点自己 `!X` 检查 ⇒ 认
    expect(
      ungatedChannelOffsets('''
        static bool get _allowed =>
            capabilityGateAllows(AppCapability.driveSafSession);
        Future<void> f() async {
          if (!_allowed) return;
          await _ch.invokeMethod<Map<Object?, Object?>>('status');
        }
      '''),
      isEmpty,
    );

    // (i) ★ 只定义了门符号、调用点**没检查** ⇒ 仍要报
    //     （不许"文件里有一处门控就放过同文件另一个裸调用"）
    expect(
      ungatedChannelOffsets('''
        static bool get _allowed =>
            capabilityGateAllows(AppCapability.driveSafSession);
        Future<void> f() async {
          await _ch.invokeMethod<Map<Object?, Object?>>('status');
        }
      '''),
      hasLength(1),
    );

    // (j) 显式豁免：理由行里必须出现**已登记**的名字
    expect(
      ungatedChannelOffsets('''
        // gate-exempt: capability-prober —— 能力层自己的探测入口
        _ch.invokeMethod<Object?>('probe');
      '''),
      isEmpty,
    );

    // (k) 写了 gate-exempt 但名字**没登记** ⇒ 不算豁免
    expect(
      ungatedChannelOffsets('''
        // gate-exempt: synhub/whatever —— 我觉得它很安全
        _ch.invokeMethod<Object?>('probe');
      '''),
      hasLength(1),
    );

    // (l) 防空转：同一段源码，调用点计数与"未门控"计数都用同一正则
    expect(
      channelCallSites("_ch.invokeMethod<bool>('a'); _ch.invokeMethod('b');"),
      2,
    );

    // (m) ★ 注释里出现 `capabilityGateAllows` **不构成**门控 —— 第 76 轮的回归
    //     文件里恰好有这么一句"应该用 capabilityGateAllows"的注释，若把注释
    //     算进门控，整个文件就会假绿。
    expect(
      ungatedChannelOffsets('''
        // 这里应该用 capabilityGateAllows(AppCapability.x) 拦一道
        _ch.invokeMethod<Object?>('probe');
      '''),
      hasLength(1),
    );
  });

  test('③ 门控结论必须能说出原因（不能只有布尔）', () {
    // 与 test/platform_capability_test.dart 的口径一致：能力层要给出 reason，
    // 界面才能"写明原因"而不是静默降级。
    final helper = File('lib/src/core/platform/app_platform.dart').readAsStringSync();
    expect(helper.contains('capabilityGateAllows'), isTrue);
    expect(helper.contains('capabilityGateReason'), isTrue);
    expect(helper.contains('notImplementedOnHost'), isTrue,
        reason: 'AbilityReason.notImplementedOnHost 不见了？宿主上的结论必须能解释');
  });
}
