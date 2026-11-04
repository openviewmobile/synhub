// 空洞穿透诊断页 —— "深空座舱 · 仪器仪表盘"（二级页面样板）。
//
// ★ 这是一张**调试页**：release 档**入口与路由都不注册**（编译期开关 `kDevTools`，
//   见 `lib/src/core/dev/dev_tools.dart`；r378 起，用户上线要求）。
//   页面本身保留在仓库里，是「不删页面、保 160 分母」的裁定（r378 §S1）。
//
// 依次验证：
//   ① 原生库加载（dart:ffi → libsynochatpunch.so）
//   ② C ABI 调用（synopunch_new / set / stop）
//   ③ 真实 QuickConnect 发现（Dio → Serv.php）
//   ④ 打洞 + 建隧道（需要有效 QuickConnect ID）
//
// 结果同时写 logcat（tag: SYNOPUNCH），便于 adb 抓取。
//
// 打洞当前搁置中，结论见 docs/holepunch-findings.md。
//
// ---------------------------------------------------------------- 界面形态
// 这一版只换皮，不动一行逻辑：`_run()` / FFI 调用 / `SYNOPUNCH` logcat 输出 /
// `autoRun` 语义全部原样。改造点是"把一次诊断呈现成一台仪器的读数"：
//   * 深空底（`HudScaffold`）打底，AppBar 沿用主题里的"HUD 仪表边"；
//   * 上半部分是**仪表盘**：`PUNCH TELEMETRY` 面板用 `TelemetryRow` 排真实读数
//     （原生库加载与否 / 运行态 / 通过·失败 / 上一步 / 目标 ID）——
//     这些字段全部从 `_lines`、`_running`、`_qcId` 推出来，**没有编造字段**；
//   * `PUNCH DIAG` 面板包住原诊断项，每条 `DiagLine` 渲染成一行"仪表读数"：
//     左侧状态**形状 + 图标 + 颜色**三重编码（圆对勾 / 三角叹号，online / warning），
//     中间步骤名走 `TelemetryRow` 的点线引导，下方 `SelectableText` 保留可选中复制；
//   * `QuickConnect ID` 换 `GlassTextField`，主行动换 `EnergyOrb`（文案仍是"重跑诊断"）；
//   * 底部 `DataStrip` 滚动的是同一批真实值（平台 / 原生库 / 项数 / 目标）。
//
// 动效安全：底部的 `DataStrip`、深空背景里的网格与星尘都是**常驻**效果，走
// `AppEffects.ambientAllowed` 闸门（测试与"减少动效"下静止）；`TechFrame.sweep`
// 是**一次性**光扫，且和登录/连接页一样用 `BootSequence.shouldPlay` 门控，
// 测试环境里根本不播（否则它的延迟定时器会干扰只 pump 一小段时长的用例）。
//
// 性能：本页有列表，所以结果行**逐行不用模糊**；`PUNCH DIAG` 这块面板的高度
// 会随诊断项增长，也显式关掉模糊（`blur: 0`，改用高不透明填充）—— 模糊面积
// 跟着列表一起长就是掉帧。模糊只留在两块定高的读数/控制铬部件上。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/log.dart';
import '../../core/platform/app_platform.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/ui/boot_sequence.dart';
import '../../core/ui/energy_orb.dart';
import '../../core/ui/glass_text_field.dart';
import '../../core/ui/tech_frame.dart';
import '../../native/punch_ffi.dart';
import '../../quickconnect/serv_api.dart';
import '../ai/server_ai_channel.dart';

/// 平台能力面板（第 279 轮）：**这台宿主能做哪些事**，逐条三态 + 原因码。
///
/// 为什么放在诊断页：能力结论是"为什么某个功能在这台机器上不出现/不能用"的第一
/// 现场，用户报障时这一屏就能说清。
///
/// 取舍（**故意不用 Riverpod**）：诊断页在既有用例里是
/// `MaterialApp(home: DiagPage(...))` **裸 pump** 的（没有 `ProviderScope`），
/// 所以这里只调纯 Dart 的 `probeAppCapabilities()`；桌面宿主上静态结论已完备
/// ⇒ 零通道调用、零定时器（不会给 widget 用例留下 pending timer）。
///
/// 标签全部是 **ASCII 机器码**
/// （`videoFrameExtraction=unavailable(not-implemented-on-host)`）：
/// 既好 grep，也不进 i18n 硬编码中文守卫的扫描范围。
class PlatformCapabilityPanel extends StatefulWidget {
  const PlatformCapabilityPanel({
    super.key,
    this.probe,
    this.initiallyExpanded = false,
  });

  /// 可注入的探测（用例里换成假的，避免碰平台通道）。
  final CapabilityProbeFn? probe;

  /// 进来就展开整张表。
  ///
  /// 默认**收起**（只给一行汇总）有两个理由：
  ///   ① 诊断页在 800x600 的测试窗口里，11 行展开会把「重跑诊断」挤出
  ///      `ListView` 的构建窗口（既有用例会当场红）；
  ///   ② 能力表是"查原因"时才看的东西，不该盖住主行动。
  final bool initiallyExpanded;

  @override
  State<PlatformCapabilityPanel> createState() =>
      _PlatformCapabilityPanelState();
}

class _PlatformCapabilityPanelState extends State<PlatformCapabilityPanel> {
  late AppPlatformCapabilities _caps = AppPlatformCapabilities.current();
  late bool _open = widget.initiallyExpanded;

  @override
  void initState() {
    super.initState();
    // 有 `unknown` 才探（桌面上一条都没有 ⇒ 这里立刻返回）
    if (_caps.entries.values.any((s) => s.isUnknown)) {
      probeAppCapabilities(base: _caps, probe: widget.probe, timeout: null)
          .then((next) {
            if (mounted) setState(() => _caps = next);
          })
          .catchError((Object _) {
            // 探测整段失败**不**影响面板：保持静态结论（如实显示 PROBING）
          });
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = AppCapability.values;
    int n(CapabilityState s) => all.where((c) => _caps.statusOf(c).state == s).length;
    final summary =
        '${n(CapabilityState.available)} available'
        ' · ${n(CapabilityState.unavailable)} unavailable'
        '${n(CapabilityState.unknown) > 0 ? ' · ${n(CapabilityState.unknown)} probing' : ''}';
    return TechFrame(
      // ★ r343 D49：原文案 `PLATFORM CAPABILITY` 被 `TechFrame` 截断成
      //   `PLATFORM CAPABILI…`（真机像素）⇒ 按 §2.0.18 **改文案**而不是缩字号。
      label: 'PLATFORM CAPS',
      code: _caps.host.tag.toUpperCase(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const Key('platform-caps-toggle'),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      summary,
                      style: AppType.telemetry(size: 12, color: DesignPalette.of(context).dim),
                    ),
                  ),
                  Text(
                    _open ? 'HIDE' : 'SHOW ALL',
                    style: AppType.telemetry(size: 12, color: DesignPalette.of(context).ok),
                  ),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: DesignPalette.of(context).ok,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            for (final c in all)
              TelemetryRow(
                // ★★ r343 D50：真机像素里这一列被**单行省略号**切掉了关键读数 ——
                //   `videoFrameExtracti…` / `networkTrafficCoun…` / `officeOffscreenRen…` /
                //   `downloadNotificati…`，连**判据本身**也被切：`cast UNAVAILABLE · devi…`、
                //   `fsBookmark UNAVAILABLE · brid…` —— 诊断页的意义就是"读到到底是哪条通道、
                //   为什么不可用"，截断后等于没读。
                //   ⇒ 用 `TelemetryRow` **自带的**展开开关（`maxLines`，见 `tech_frame.dart`：
                //   "默认单行省略号；需要完全展开时传更大的值并配 `maxLines`"），
                //   **不改共享组件、不改字号**（§2.0.18）。
                label: c.name,
                value: '${_caps.statusOf(c).label} · ${_caps.reasonOf(c)}',
                maxLines: 3,
                color: switch (_caps.statusOf(c).state) {
                  CapabilityState.available => DesignPalette.of(context).ok,
                  CapabilityState.unavailable => DesignPalette.of(context).danger,
                  CapabilityState.unknown => DesignPalette.of(context).dim,
                },
              ),
        ],
      ),
    );
  }
}

class DiagLine {
  DiagLine(this.step, this.ok, this.detail);
  final String step;
  final bool ok;
  final String detail;
}

class DiagPage extends ConsumerStatefulWidget {
  const DiagPage({super.key, this.autoRun = true});

  /// 进入页面即自动跑诊断。测试里置 false 以免触发网络与原生调用。
  final bool autoRun;

  @override
  ConsumerState<DiagPage> createState() => _DiagPageState();
}

class _DiagPageState extends ConsumerState<DiagPage> {
  final List<DiagLine> _lines = [];
  final TextEditingController _qcId = TextEditingController();
  bool _running = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoRun) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  @override
  void dispose() {
    _qcId.dispose();
    super.dispose();
  }

  void _add(String step, bool ok, String detail) {
    log('${ok ? "OK  " : "FAIL"} $step | $detail');
    if (!mounted) return;
    setState(() => _lines.add(DiagLine(step, ok, detail)));
  }

  // ---------------------------------------------------------------- ①② 原生
  Future<SynoPunch?> _stepNative() async {
    final t = currentText();
    log(
      '平台: ${defaultTargetPlatform.name}  '
      '${const bool.fromEnvironment("dart.vm.product") ? "release" : "debug"}',
    );
    try {
      final punch = SynoPunch.load();
      _add(
        t.diagStepNativeLoad,
        true,
        t.diagNativeFound(SynoPunch.defaultLibraryName()),
      );

      // 调用一轮 C ABI，确认符号真的可调用
      final before = punch.tcpPort;
      final running = punch.isRunning;
      final err = punch.lastError;
      punch.serverId = 'diag-probe';
      punch.serviceType = SynoServiceType.dsmHttps;
      punch.udtTxMss = 1370;
      punch.addEchoServer('127.0.0.1', 4000);
      punch.clearEchoServers();
      punch.setCandidate('127.0.0.1', 4000);
      punch.clearCandidate();
      punch.punchTimeoutMs = 300;
      punch.stop();

      _add(
        t.diagStepCApi,
        true,
        t.diagCApiDetail(before, '$running', err.isEmpty ? '-' : err),
      );
      return punch;
    } catch (e) {
      _add(t.diagStepNativeLoad, false, '$e');
      return null;
    }
  }

  // ---------------------------------------------------------------- ③ 发现
  Future<void> _stepDiscovery() async {
    final t = currentText();
    // ★ r342 D46：「检测到哪些服务端 AI 能力」是**技术事实** ⇒ 印在这里（诊断页），
    //   不印在面向用户的「设置 → AI 服务」卡上（那一页说的是"能干什么"）。
    final ai = ref.read(serverAiChannelProvider);
    _add(
      t.aiServerChannelTitle,
      ai.generation,
      ai.generation ? ai.detectedApis.join(' · ') : 'not available',
    );
    final api = ServApi();
    try {
      final t0 = DateTime.now();
      final echo = await api.fetchEchoList();
      final ms = DateTime.now().difference(t0).inMilliseconds;
      _add(
        t.diagStepEchoList,
        echo.errno == 0,
        t.diagEchoOk(echo.errno, '${echo.sites}', echo.udtTxMss, ms),
      );
    } catch (e) {
      _add(t.diagStepEchoList, false, '$e');
    }
  }

  // ---------------------------------------------------------------- ④ 打洞
  Future<void> _stepTunnel(SynoPunch? punch) async {
    final t = currentText();
    if (punch == null) {
      _add(t.diagStepTunnel, false, t.diagNativeUnavailable);
      return;
    }
    final qc = _qcId.text.trim();
    if (qc.isEmpty) {
      _add(t.diagStepTunnel, false, t.diagNoQcId);
      return;
    }

    try {
      final api = ServApi();
      final echo = await api.fetchEchoList();
      if (echo.sites.isEmpty) {
        _add(t.diagStepTunnel, false, t.diagEchoEmpty);
        return;
      }

      punch.serverId = qc;
      punch.serviceType = SynoServiceType.dsmHttps;
      if (echo.udtTxMss > 0) punch.udtTxMss = echo.udtTxMss;
      for (final s in echo.sites) {
        punch.addEchoServer(s.host, s.port);
      }
      punch.punchTimeoutMs = 8000;
      punch.connectTimeoutMs = 8000;

      // 从 get_server_info 取打洞候选
      try {
        final info = await api.resolve(serverId: qc, serviceId: 'dsm_https');
        final cands = info.punchCandidates();
        // 候选按优先级排列，但**排在前面的未必能解析**：
        // smartdns.host（DEMO_ADMIN-QQ.direct.quickconnect.cn）只有
        // QuickConnect 自家 DNS 才解得开，普通解析器拿不到。
        // 所以逐个试解析，取第一个可达的；literal IP 直接算可达。
        PunchCandidate? chosen;
        final tried = <String>[];
        for (final c in cands) {
          final isIp = RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(c.host);
          if (isIp) {
            chosen = c;
            tried.add('${c.host} ✓');
            break;
          }
          try {
            final rs = await InternetAddress.lookup(
              c.host,
            ).timeout(const Duration(seconds: 3));
            if (rs.isNotEmpty) {
              chosen = c;
              tried.add('${c.host}→${rs.first.address} ✓');
              break;
            }
            tried.add(t.diagHostNoRecord(c.host));
          } catch (_) {
            tried.add(t.diagHostResolveFailed(c.host));
          }
        }
        final pick = chosen ?? cands.first; // 全解析失败也硬试第一个
        if (chosen == null) tried.add(t.diagAllResolveFailed(pick.host));
        punch.setCandidate(pick.host, pick.port);
        _add(
          t.diagStepCandidates,
          true,
          t.diagCandidatesPicked(
            cands.length,
            pick.host,
            pick.port,
            pick.source,
            tried.join(', '),
          ),
        );
      } catch (e) {
        _add(t.diagStepCandidates, false, '$e');
      }

      final t0 = DateTime.now();
      final rc = punch.start();
      final ms = DateTime.now().difference(t0).inMilliseconds;
      final ok = rc == SynoPunchError.ok;
      _add(
        t.diagStepTunnelUp,
        ok,
        t.diagTunnelStart(
          rc,
          SynoPunchError.name(rc),
          punch.lastError,
          punch.tcpPort,
          ms,
        ),
      );

      if (ok) {
        _add(
          t.diagStepTunnelOk,
          true,
          'https://127.0.0.1:${punch.tcpPort}/  '
          'rx=${punch.rxBytes} tx=${punch.txBytes}',
        );
      }
    } catch (e) {
      _add(t.diagStepTunnel, false, '$e');
    }
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _lines.clear();
    });
    log('===== 诊断开始 =====');

    final punch = await _stepNative();
    await _stepDiscovery();
    await _stepTunnel(punch);
    punch?.dispose();

    log('===== 诊断结束，共 ${_lines.length} 项 =====');
    if (mounted) setState(() => _running = false);
  }

  // ================================================================ 展示层
  // 下面全是"把已有数据摆到仪表上"的只读推导，不新增任何探测。

  /// 进场光扫只在真机播（与登录/连接英雄页同规）。
  bool get _entrance => BootSequence.shouldPlay;

  /// 原生库是否加载：只看诊断结果里 ① 号那一项。null = 还没跑过。
  bool? get _nativeLoaded {
    for (final l in _lines) {
      if (l.step.startsWith('①')) return l.ok;
    }
    return null;
  }

  DiagLine? get _last => _lines.isEmpty ? null : _lines.last;

  int get _passCount => _lines.where((l) => l.ok).length;

  int get _failCount => _lines.length - _passCount;

  String get _target {
    final v = _qcId.text.trim();
    return v.isEmpty ? '—' : v;
  }

  @override
  Widget build(BuildContext context) {
    return DesignScaffold(
      appBar: AppBar(
        title: Text(context.t.diagTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _running ? null : _run,
            tooltip: context.t.diagRerunTooltip,
          ),
        ],
      ),
      body: Column(
        children: [
          // 诊断时长不可预知 —— 用不定量进度条（真实状态，不假装百分比）
          if (_running) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                Gap.lg,
                Gap.md,
                Gap.lg,
                Gap.xl,
              ),
              children: [
                _telemetryPanel(context, DesignPalette.of(context)),
                const SizedBox(height: Gap.lg),
                _diagPanel(context, DesignPalette.of(context)),
                const SizedBox(height: Gap.lg),
                _controlPanel(context, DesignPalette.of(context)),
                const SizedBox(height: Gap.lg),
                // ★ 能力表放在**最后**：它是"参考信息"，不该把
                //   「重跑诊断」这个主行动挤出首屏（既有用例在
                //   800x600 的测试窗口里找得到那个按钮，也证明它确实在首屏）。
                const PlatformCapabilityPanel(),
              ],
            ),
          ),
          _strip(context, DesignPalette.of(context)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 仪表盘
  /// 顶部读数卡：一屏看完"这台仪器现在什么状态"，字段全部真实。
  Widget _telemetryPanel(BuildContext context, DesignPalette p) {
    final scheme = Theme.of(context).colorScheme;
    final native = _nativeLoaded;
    final last = _last;
    final nativeColor = native == null
        ? DesignPalette.of(context).dim
        : (native ? p.ok : DesignPalette.of(context).danger);
    final runLabel = _running ? 'RUNNING' : (_lines.isEmpty ? 'IDLE' : 'DONE');

    return TechFrame(
      label: 'PUNCH TELEMETRY',
      code: '${_lines.length} CHECKS',
      statusDot: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TelemetryRow(
            label: 'NATIVE LIB',
            value: native == null ? 'PENDING' : (native ? 'LOADED' : 'ABSENT'),
            color: nativeColor,
          ),
          TelemetryRow(
            label: 'RUN STATE',
            value: runLabel,
            color: _running ? scheme.primary : DesignPalette.of(context).dim,
          ),
          TelemetryRow(
            label: 'PASS / FAIL',
            value: '$_passCount / $_failCount',
            color: _failCount > 0 ? DesignPalette.of(context).danger : p.ok,
          ),
          TelemetryRow(label: 'LAST STEP', value: last?.step ?? '—'),
          TelemetryRow(label: 'TARGET', value: _target),
        ],
      ),
    );
  }

  /// 诊断结果面板：原诊断项一条不落，只是每条渲染成一行"仪表读数"。
  Widget _diagPanel(BuildContext context, DesignPalette p) {
    return TechFrame(
      label: 'PUNCH DIAG',
      code: _lines.isEmpty ? 'NO DATA' : '${_lines.length}',
      sweep: _entrance,
      // 这一块高度随诊断项增长（且含可选中长文本），**不开模糊**：
      // 模糊面积会跟着列表一起长，中低端机上就是掉帧。模糊只留给上面那块
      // 定高的读数铬部件。
      blur: 0,
      child: _lines.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.md),
              child: Text(
                context.t.diagNotRun,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < _lines.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: Gap.md,
                      thickness: 0.8,
                      color: DesignPalette.of(context).line.withValues(alpha: 0.35),
                    ),
                  _DiagReading(line: _lines[i]),
                ],
              ],
            ),
    );
  }

  /// 控制面板：QuickConnect ID（玻璃输入框）+ 主行动能量核（文案仍是"重跑诊断"）。
  Widget _controlPanel(BuildContext context, DesignPalette p) {
    final failed = _failCount > 0 && !_running;
    return TechFrame(
      label: 'PUNCH CONTROL',
      code: _running ? 'BUSY' : 'READY',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassTextField(
            controller: _qcId,
            enabled: !_running,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _run(),
            // 只为刷新上面的 TARGET 读数与底部遥测带，不改任何逻辑
            onChanged: (_) => setState(() {}),
            labelText: context.t.diagQcIdLabel,
            // ★★★ r349 修 **D76**：原来把「可留空，仅跑前两步」塞在 **label** 里，
            //   整串 `QuickConnect ID（可留空，仅跑前两步）` 在 375dp 宽的输入框里
            //   **放不下** ⇒ Flutter 单行省略成 `QuickConnect ID（可留空…`
            //   （真机像素 `04_diag.png`），**恰好把有信息量的那半句切掉**。
            //   英文串更长（54 字符）⇒ 同缺陷在英文档更明显。
            //   按 §2.0.18：截断只能靠**改文案/给预算**，不许缩字号 ⇒
            //   label 只留控件名，把限定语移进 `helperText`（该组件**本来就支持**），
            //   信息一点不丢。
            helperText: context.t.diagQcIdHelper,
            prefixIcon: const Icon(Icons.cloud_outlined),
          ),
          const SizedBox(height: Gap.lg),
          Center(
            child: Builder(
              builder: (context) {
                // ★ D9（r719）：从没跑过时说「**重跑**诊断」自相矛盾（页面正文
                //   明明写着 `No diagnostics run yet`，按钮却是 Rerun）。
                //   判据只认**已跑过**（`_lines` 非空 = 有真读数）。
                final ranBefore = _lines.isNotEmpty;
                final label = ranBefore
                    ? context.t.diagRerun
                    : context.t.diagRunFirst;
                return EnergyOrb(
                  size: 128,
                  label: label,
                  busy: _running,
                  // 有失败项 → warning；全通过 → online；没跑过 → 主色待机
                  color: failed
                      ? DesignPalette.of(context).danger
                      : (ranBefore ? p.ok : null),
                  onTap: _running ? null : _run,
                  semanticLabel: label,
                  caption: _running
                      ? 'RUNNING'
                      : (ranBefore ? 'RERUN DIAG' : 'RUN DIAG'),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 底部滚动遥测带：与上面读数卡同源（平台 / 原生库 / 项数 / 目标）。
  Widget _strip(BuildContext context, DesignPalette p) {
    final native = _nativeLoaded;
    final items = <String>[
      'PLATFORM ${defaultTargetPlatform.name}',
      'NATIVE ${native == null ? 'PENDING' : (native ? 'LOADED' : 'ABSENT')}',
      'CHECKS ${_lines.length}',
      'PASS $_passCount',
      'FAIL $_failCount',
      'TARGET $_target',
    ];
    return Container(
      decoration: BoxDecoration(
        color: p.bg.withValues(alpha: 0.72),
        border: Border(top: BorderSide(color: DesignPalette.of(context).line, width: 0.8)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
      child: DataStrip(items: items, prefix: 'TELEMETRY'),
    );
  }
}

/// 一条诊断结果的"仪表读数行"。
///
/// 状态三重编码（不靠色相单独承载信息）：
///   * 形状：圆（`check_circle_outline`）对三角（`warning_amber_rounded`）；
///   * 图标：对勾对叹号；
///   * 颜色：`p.ok` 对 `DesignPalette.of(context).danger`；
///   再加上给屏幕阅读器的 `semanticLabel`（通过 / 失败）。
///
/// 步骤名与 PASS/FAIL 走 `TelemetryRow` 的点线引导；`detail` 用 `SelectableText`
/// 并保持等宽 —— 真机抓 logcat / 复制报错全依赖它可选中。
class _DiagReading extends StatelessWidget {
  const _DiagReading({required this.line});

  final DiagLine line;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = line.ok
        ? DesignPalette.of(context).ok
        : DesignPalette.of(context).danger;
    final glyph = line.ok
        ? Icons.check_circle_outline
        : Icons.warning_amber_rounded;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            glyph,
            size: 18,
            color: tint,
            semanticLabel: line.ok
                ? context.t.diagPassed
                : context.t.usageActFailure,
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TelemetryRow(
                  label: line.step,
                  value: line.ok ? 'PASS' : 'FAIL',
                  color: tint,
                ),
                const SizedBox(height: Gap.xs),
                SelectableText(
                  line.detail,
                  style: kCodeStyle.copyWith(
                    fontSize: 11.5,
                    color: scheme.onSurface.withValues(alpha: 0.92),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 等宽读数里塞不下时截断（只影响仪表上的显示，完整值仍在读数行里）。
