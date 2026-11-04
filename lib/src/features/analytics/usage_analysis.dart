// 使用数据的**本地分析引擎**（纯函数，无 IO / 无 Flutter）。
//
// 分两层：
//   1. 规则层（本文件）：把事件聚合成可解释的统计量，产出**结论**（[UsageInsight]）。
//      每条结论都带 `evidence`（口径 + 数字）和可选的 `suggestion`（策略调整建议），
//      这样既能直接显示给人看，也能作为**端侧模型的输入特征**（结构化、可复核）。
//   2. 模型层（以后）：端侧 LLM 读这些统计量 + 结论，写"人话总结/预测/建议"。
//      之所以先做规则层：端侧小模型不擅长数数，数数交给我们，模型负责归纳与表达。
//
// 结论如何**反哺 App 策略**（每条结论的 `strategyKey` 对应一处可调逻辑）：
//   * `workspace.order`   —— 工作台入口排序（已有 `sortByUsage`，可升级为时段加权）
//   * `workspace.pin`     —— 高频入口固定在第一屏
//   * `files.defaultView` —— 文件模块默认列表/缩略图、默认进入的目录
//   * `notes.defaultMode` —— 笔记默认阅读/编辑、模板
//   * `photos.defaultTab` —— 相册默认时间线/相簿
//   * `calendar.defaultView` —— 月/周/日程视图偏好
//   * `search.history`    —— 搜索历史排序 / 建议词
//   * `upload.default`    —— 上传落点目录与并发
//   * `tips.candidates`   —— "你可能没发现的入口"提示候选
import 'dart:convert';
import 'dart:math' as math;

import '../../core/i18n/l10n.dart';
import 'analytics_labels.dart';
import 'usage_event.dart';

/// 结论类型（落库 `kind`，只增不改）
enum InsightKind {
  volume('volume', '数据量'),
  peakHour('peak_hour', '活跃时段'),
  weekdayPattern('weekday_pattern', '作息规律'),
  topModule('top_module', '最常用模块'),
  topAction('top_action', '主要行为'),
  unusedModule('unused_module', '几乎没用的模块'),
  moduleMix('module_mix', '模块分布'),
  fileTypePref('file_type_pref', '文件类型偏好'),
  transferMix('transfer_mix', '上传/下载'),
  sizeMix('size_mix', '文件体量'),
  searchQuality('search_quality', '搜索命中率'),
  editCadence('edit_cadence', '编辑活跃度'),
  sessionLength('session_length', '单次使用时长'),
  failureHotspot('failure_hotspot', '失败集中点'),
  viewPreference('view_preference', '视图偏好'),
  failureReason('failure_reason', '失败原因'),
  featureGap('feature_gap', '功能空白');

  const InsightKind(this.id, this.label);

  final String id;

  /// 中文标签（**回落**：落库/老测试用；界面走 [labelIn]）
  final String label;

  /// 本地化标签
  String labelIn(AppText t) => switch (this) {
    InsightKind.volume => t.usageKindVolume,
    InsightKind.peakHour => t.usageKindPeakHour,
    InsightKind.weekdayPattern => t.usageKindWeekdayPattern,
    InsightKind.topModule => t.usageKindTopModule,
    InsightKind.topAction => t.usageKindTopAction,
    InsightKind.unusedModule => t.usageKindUnusedModule,
    InsightKind.moduleMix => t.usageKindModuleMix,
    InsightKind.fileTypePref => t.usageKindFileTypePref,
    InsightKind.transferMix => t.usageKindTransferMix,
    InsightKind.sizeMix => t.usageKindSizeMix,
    InsightKind.searchQuality => t.usageKindSearchQuality,
    InsightKind.editCadence => t.usageKindEditCadence,
    InsightKind.sessionLength => t.usageKindSessionLength,
    InsightKind.failureHotspot => t.usageKindFailureHotspot,
    InsightKind.viewPreference => t.usageKindViewPref,
    InsightKind.failureReason => t.usageKindFailureReason,
    InsightKind.featureGap => t.usageKindFeatureGap,
  };
}

/// 一条可解释的结论
class UsageInsight {
  const UsageInsight({
    required this.kind,
    required this.title,
    required this.body,
    this.suggestion = '',
    this.strategyKey = '',
    this.score = 0.5,
    this.evidence = const {},
    this.source = 'heuristic',
    this.model = '',
  });

  final InsightKind kind;
  final String title;
  final String body;

  /// 给用户的"可以这样改"建议（可空）
  final String suggestion;

  /// 这条结论对应的**可调策略**（见文件头注释）；空表示纯观察
  final String strategyKey;

  /// 可信度 0–1：样本越多越高，样本不足会显著调低
  final double score;

  /// 统计口径 + 数字（能从 UI 复核，也能喂模型）
  final Map<String, Object?> evidence;

  final String source;
  final String model;

  String get evidenceJson => jsonEncode(evidence);
}

/// 一次分析用的聚合统计（也直接作为端侧模型的输入特征）
class UsageStats {
  UsageStats({
    required this.from,
    required this.to,
    required this.total,
    required this.byModule,
    required this.byAction,
    required this.byHour,
    required this.byWeekday,
    required this.byHourBand,
    required this.byFileType,
    required this.bySizeBucket,
    required this.sessions,
    required this.avgSession,
    required this.maxSession,
    required this.failures,
    required this.byFailureReason,
    required this.byViewMode,
    required this.byScreen,
    required this.durationTotalMs,
    required this.durationCount,
    required this.searchCount,
    required this.searchEmpty,
    required this.uploadCount,
    required this.downloadCount,
    required this.editCount,
    required this.openCount,
    required this.dayCount,
  });

  final DateTime from;
  final DateTime to;
  final int total;
  final Map<String, int> byModule;
  final Map<String, int> byAction;
  final Map<int, int> byHour;
  final Map<int, int> byWeekday; // 1=周一 … 7=周日
  final Map<String, int> byHourBand;
  /// ★ r343 D47 订正注释：键是事件的 **`objectType`**（**混合**取值）——
  /// 真扩展名带点（`.pdf`）、`UsageModule` 的 id（`settings`/`drive`）、
  /// 各功能内部对象码（`task`/`folder`/`snooze_schedule`…）都会进来。
  /// ⇒ 上屏前**必须**过 `objectTypeLabel()`（见 `analytics_labels.dart`）。
  final Map<String, int> byFileType;
  final Map<String, int> bySizeBucket;
  final List<int> sessions; // 每段使用的时长（分钟）
  final int avgSession;
  final int maxSession;
  final Map<String, int> failures; // `module.action` → 次数
  /// `module.reason` → 次数。**可查询的失败原因**（不是 message），
  /// 用来回答"为什么失败"而不只是"失败了多少"。
  final Map<String, int> byFailureReason;
  /// `module.view` → 次数。视图/模式偏好（grid/list/timeline/lyrics/visualizer…）
  final Map<String, int> byViewMode;
  /// `module.screen` → 次数。页面曝光（哪些功能真的被打开过）
  final Map<String, int> byScreen;
  /// `module.action` → 累计时长（毫秒，来自 `complete` 事件）
  final Map<String, int> durationTotalMs;
  /// `module.action` → 有几次带时长的完成
  final Map<String, int> durationCount;
  final int searchCount;
  final int searchEmpty;
  final int uploadCount;
  final int downloadCount;
  final int editCount;
  final int openCount;
  final int dayCount; // 有事件的天数

  /// 端侧模型输入用的紧凑 JSON（**只有聚合数字**，没有原始事件）
  Map<String, Object?> toFeatureJson() => {
    'days': dayCount,
    'events': total,
    'by_module': byModule,
    'by_action': byAction,
    'by_hour_band': byHourBand,
    'by_weekday': {for (final e in byWeekday.entries) '${e.key}': e.value},
    'file_types': byFileType,
    'size_buckets': bySizeBucket,
    'sessions': {
      'count': sessions.length,
      'avg_min': avgSession,
      'max_min': maxSession,
    },
    'failures': failures,
    'failure_reasons': byFailureReason,
    'view_modes': byViewMode,
    'screens': byScreen,
  };

  /// **功能采用**：把模块分成"至少用过一次"和"从没用过"。
  ///
  /// `workspace`/`settings` 是外壳（进 App / 进设置就会碰到），不算"功能采用"，
  /// 否则采用率永远虚高。`unattributed` 也不是功能模块（它是流量计量的默认
  /// 落点），不能算成"有个模块从没用过"。
  static const Set<String> chromeModules = {'workspace', 'settings'};

  /// 不属于"功能采用"统计的模块（外壳 + 未归属）
  static const Set<String> nonFeatureModules = {
    'workspace',
    'settings',
    'unattributed',
  };

  List<String> get adoptedModules => [
    for (final m in UsageModule.values)
      if (!nonFeatureModules.contains(m.id) && (byModule[m.id] ?? 0) > 0) m.id,
  ];

  List<String> get unusedModules => [
    for (final m in UsageModule.values)
      if (!nonFeatureModules.contains(m.id) && (byModule[m.id] ?? 0) == 0) m.id,
  ];

  int get adoptionTotal => adoptedModules.length + unusedModules.length;

  /// 失败原因 Top（`module.reason` → 次数），降序
  List<MapEntry<String, int>> get topFailureReasons {
    final list = byFailureReason.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  /// 视图/模式偏好 Top（`module.view` → 次数），降序
  List<MapEntry<String, int>> get topViewModes {
    final list = byViewMode.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  /// 某个 `module.action` 的平均时长（分钟，四舍五入）；没有则 0
  int avgMinutesOf(String key) {
    final n = durationCount[key] ?? 0;
    if (n == 0) return 0;
    final ms = durationTotalMs[key] ?? 0;
    return (ms / n / 60000).round();
  }
}

/// 把事件流聚合成 [UsageStats]
UsageStats computeUsageStats(List<UsageEvent> events, {DateTime? now}) {
  final sorted = [...events]..sort((a, b) => a.at.compareTo(b.at));
  final byModule = <String, int>{};
  final byAction = <String, int>{};
  final byHour = <int, int>{};
  final byWeekday = <int, int>{};
  final byHourBand = <String, int>{};
  final byFileType = <String, int>{};
  final bySizeBucket = <String, int>{};
  final failures = <String, int>{};
  final byFailureReason = <String, int>{};
  final byViewMode = <String, int>{};
  final byScreen = <String, int>{};
  final durationTotalMs = <String, int>{};
  final durationCount = <String, int>{};
  final sessions = <int>[];

  var searchCount = 0, searchEmpty = 0;
  var upload = 0, download = 0, edit = 0, open = 0;
  final days = <String>{};

  DateTime? prev;
  DateTime? sessionStart;
  final sessionEvents = <UsageEvent>[];

  void closeSession() {
    if (sessionStart == null || sessionEvents.isEmpty) return;
    final last = sessionEvents.last.at;
    final minutes = last.difference(sessionStart!).inMinutes;
    sessions.add(minutes < 1 ? 1 : minutes);
    sessionStart = null;
    sessionEvents.clear();
  }

  for (final e in sorted) {
    byModule[e.module.id] = (byModule[e.module.id] ?? 0) + 1;
    byAction[e.action.id] = (byAction[e.action.id] ?? 0) + 1;
    byHour[e.at.hour] = (byHour[e.at.hour] ?? 0) + 1;
    byWeekday[e.at.weekday] = (byWeekday[e.at.weekday] ?? 0) + 1;
    final band = hourBand(e.at.hour);
    byHourBand[band] = (byHourBand[band] ?? 0) + 1;
    days.add('${e.at.year}-${e.at.month}-${e.at.day}');
    if (e.objectType.isNotEmpty) {
      byFileType[e.objectType] = (byFileType[e.objectType] ?? 0) + 1;
    }
    if (e.value > 0 && e.action == UsageAction.upload) {
      final b = sizeBucket(e.value);
      bySizeBucket[b] = (bySizeBucket[b] ?? 0) + 1;
    }
    if (e.action == UsageAction.failure) {
      final k = '${e.module.id}.${e.detail[UsageDetailKeys.failedAction] ?? '?'}';
      failures[k] = (failures[k] ?? 0) + 1;
      // 失败**原因**：可查询的稳定码（认不出的码也照常分组）
      final reason = '${e.detail[UsageDetailKeys.reason] ?? UsageFailureReason.unknown.id}';
      final rk = '${e.module.id}.$reason';
      byFailureReason[rk] = (byFailureReason[rk] ?? 0) + 1;
    }
    // 视图/模式偏好：`switchView`（objectType 是稳定视图 id）
    if (e.action == UsageAction.switchView && e.objectType.isNotEmpty) {
      final k = '${e.module.id}.${e.objectType}';
      byViewMode[k] = (byViewMode[k] ?? 0) + 1;
    }
    // 页面曝光：`view`（objectType 是稳定页面 id）
    if (e.action == UsageAction.view && e.objectType.isNotEmpty) {
      final k = '${e.module.id}.${e.objectType}';
      byScreen[k] = (byScreen[k] ?? 0) + 1;
    }
    // 时长：`complete`（value = 毫秒；detail.duration_ms 兼容旧值）
    if (e.action == UsageAction.complete) {
      final ms = e.value > 0
          ? e.value
          : (e.detail[UsageDetailKeys.durationMs] is int
                ? e.detail[UsageDetailKeys.durationMs]! as int
                : 0);
      final label = '${e.detail[UsageDetailKeys.preset] ?? e.objectType}';
      final k = '${e.module.id}.$label';
      if (ms > 0) {
        durationTotalMs[k] = (durationTotalMs[k] ?? 0) + ms;
        durationCount[k] = (durationCount[k] ?? 0) + 1;
      }
    }
    switch (e.action) {
      case UsageAction.search:
        searchCount++;
        if ((e.value) == 0) searchEmpty++;
      case UsageAction.upload:
        upload++;
      case UsageAction.download:
        download++;
      case UsageAction.edit:
        edit++;
      case UsageAction.open:
        open++;
      default:
        break;
    }

    // 会话切分：间隔 > 5 分钟 → 上一段结束
    if (prev != null && e.at.difference(prev) > kSessionGap) closeSession();
    sessionStart ??= e.at;
    sessionEvents.add(e);
    prev = e.at;
  }
  closeSession();

  final avg = sessions.isEmpty
      ? 0
      : (sessions.reduce((a, b) => a + b) / sessions.length).round();
  final maxS = sessions.isEmpty ? 0 : sessions.reduce(math.max);

  return UsageStats(
    from: sorted.isEmpty ? (now ?? DateTime.now()) : sorted.first.at,
    to: sorted.isEmpty ? (now ?? DateTime.now()) : sorted.last.at,
    total: sorted.length,
    byModule: byModule,
    byAction: byAction,
    byHour: byHour,
    byWeekday: byWeekday,
    byHourBand: byHourBand,
    byFileType: byFileType,
    bySizeBucket: bySizeBucket,
    sessions: sessions,
    avgSession: avg,
    maxSession: maxS,
    failures: failures,
    byFailureReason: byFailureReason,
    byViewMode: byViewMode,
    byScreen: byScreen,
    durationTotalMs: durationTotalMs,
    durationCount: durationCount,
    searchCount: searchCount,
    searchEmpty: searchEmpty,
    uploadCount: upload,
    downloadCount: download,
    editCount: edit,
    openCount: open,
    dayCount: days.length,
  );
}

/// 样本量 → 可信度（少于 20 条基本别下结论）
double _confidence(int samples) {
  if (samples <= 0) return 0;
  if (samples < 20) return 0.25;
  if (samples < 60) return 0.5;
  if (samples < 200) return 0.7;
  if (samples < 600) return 0.85;
  return 0.95;
}

/// 产出结论。按 `score` 从高到低排序；样本不足的结论会被压低。
///
/// [t] 不传时走 [currentText]（中文回落）；界面侧可传 `context.t`。
List<UsageInsight> buildInsights(UsageStats s, {AppText? t}) {
  final text = t ?? currentText();
  final out = <UsageInsight>[];
  final samples = s.total;

  // 0) 数据量：所有结论的前提，样本少要明说
  out.add(
    UsageInsight(
      kind: InsightKind.volume,
      title: text.usageTitleVolume(samples),
      body: s.dayCount == 0
          ? text.usageBodyNoRecords
          : text.usageBodyVolume(s.dayCount, s.sessions.length, s.avgSession),
      score: samples == 0 ? 0.1 : 0.4,
      evidence: {
        'events': samples,
        'days': s.dayCount,
        'sessions': s.sessions.length,
        'avg_session_min': s.avgSession,
      },
    ),
  );

  if (samples < 20) {
    // 样本太少：只给观察，不给"没用的模块"这类容易误导的结论
    return out;
  }

  final conf = _confidence(samples);

  // 1) 活跃时段
  if (s.byHourBand.isNotEmpty) {
    final top = s.byHourBand.entries.reduce(
      (a, b) => a.value >= b.value ? a : b,
    );
    // ★★★ r349 修 **D75**：`maxHour` 原来取自**全天**的 `s.byHour`，
    //   而句子的主語是 `top`（最忙的**时段**，`byHourBand` 的桶）。
    //   ⇒ 两者可以**互相矛盾**：真机像素 `02_usage.png` 上这张卡写着
    //     「你主要在**深夜(0-6)**用这个 App」，同一张卡的明细却是
    //     「最忙的是 **21:00** 前后」—— **21:00 不在 [0,6) 里**。
    //   （`hourBand(21)` 是 `晚上(18-22)`，见 `usage_event.dart:316`。）
    //   这是 §2.0.26「同一语义被造成两份表示」的同型：把**两种不同的聚合**
    //   当成同一个对象来叙述。修法：`maxHour` **只在 top 时段内**取最大。
    final maxHour = s.byHour.entries
        .where((e) => hourBand(e.key) == top.key)
        .fold<MapEntry<int, int>?>(
            null, (a, e) => a == null || e.value > a.value ? e : a);
    final pct = (top.value * 100 / samples).round();
    final band = usageHourBandLabel(top.key, text);
    out.add(
      UsageInsight(
        kind: InsightKind.peakHour,
        title: text.usageTitlePeakHour(band),
        body: maxHour == null
            ? text.usageBodyPeakHour(pct, band)
            : text.usageBodyPeakHourWithHour(pct, band, maxHour.key),
        suggestion: text.usageSugPeakHour(band),
        strategyKey: 'workspace.order',
        score: conf,
        evidence: {
          'band': top.key,
          'band_events': top.value,
          'share': pct / 100,
          'top_hour': maxHour?.key,
          'by_hour_band': s.byHourBand,
        },
      ),
    );
  }

  // 2) 作息：工作日 vs 周末
  final weekday = s.byWeekday.entries
      .where((e) => e.key <= 5)
      .fold<int>(0, (a, e) => a + e.value);
  final weekend = s.byWeekday.entries
      .where((e) => e.key >= 6)
      .fold<int>(0, (a, e) => a + e.value);
  if (weekday + weekend > 0) {
    final wd = (weekday * 100 / (weekday + weekend)).round();
    out.add(
      UsageInsight(
        kind: InsightKind.weekdayPattern,
        title: wd >= 80
            ? text.usageTitleWeekdayTool
            : (wd <= 40
                  ? text.usageTitleWeekendMore
                  : text.usageTitleWeekdayMixed),
        body: text.usageBodyWeekday(wd, 100 - wd),
        suggestion: wd >= 80 ? text.usageSugWeekend : '',
        strategyKey: 'workspace.order',
        score: conf * 0.8,
        evidence: {
          'weekday': weekday,
          'weekend': weekend,
          'weekday_share': wd / 100,
        },
      ),
    );
  }

  // 3) 最常用模块 + 模块分布
  if (s.byModule.length > 1) {
    final sorted = s.byModule.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.first;
    final share = (top.value * 100 / samples).round();
    out.add(
      UsageInsight(
        kind: InsightKind.topModule,
        title: text.usageTitleTopModule(_moduleLabel(top.key, text), share),
        body: text.usageBodyTopModule(
          sorted
              .take(3)
              .map((e) => '${_moduleLabel(e.key, text)} ${e.value}')
              .join(' · '),
        ),
        suggestion: text.usageSugTopModule(_moduleLabel(top.key, text)),
        strategyKey: 'workspace.pin',
        score: conf,
        evidence: {
          'top': top.key,
          'share': share / 100,
          'distribution': s.byModule,
        },
      ),
    );

    // 4) 几乎没用的模块（有入口但从没用过）
    final unused = <String>[];
    for (final m in UsageModule.values) {
      if (UsageStats.nonFeatureModules.contains(m.id)) continue;
      final n = s.byModule[m.id] ?? 0;
      if (n == 0) unused.add(m.id);
    }
    if (unused.isNotEmpty) {
      out.add(
        UsageInsight(
          kind: InsightKind.unusedModule,
          title: text.usageTitleUnused(unused.length),
          body: text.usageBodyUnused(
            unused.map((id) => _moduleLabel(id, text)).join('、'),
          ),
          suggestion: text.usageSugUnused,
          strategyKey: 'tips.candidates',
          score: 0.6,
          evidence: {'unused': unused, 'events': samples},
        ),
      );
    }
  }

  // 5) 主要行为
  if (s.byAction.length > 1) {
    final sorted = s.byAction.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.first;
    out.add(
      UsageInsight(
        kind: InsightKind.topAction,
        title: text.usageTitleTopAction(_actionLabel(top.key, text)),
        body: sorted
            .take(3)
            .map(
              (e) => text.usageActionCount(_actionLabel(e.key, text), e.value),
            )
            .join(' · '),
        score: conf * 0.8,
        evidence: {'distribution': s.byAction},
      ),
    );
  }

  // 6) 文件类型偏好
  if (s.byFileType.isNotEmpty) {
    final sorted = s.byFileType.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.first;
    final totalTyped = s.byFileType.values.fold<int>(0, (a, b) => a + b);
    final share = (top.value * 100 / totalTyped).round();
    out.add(
      UsageInsight(
        kind: InsightKind.fileTypePref,
        title: text.usageTitleFileType(objectTypeLabel(top.key, text), share),
        body: text.usageBodyFileType(
          sorted
              .skip(1)
              .take(2)
              .map((e) => objectTypeLabel(e.key, text))
              .join('、'),
        ),
        suggestion: text.usageSugFileType(objectTypeLabel(top.key, text)),
        strategyKey: 'files.defaultView',
        score: conf * 0.9,
        evidence: {'distribution': s.byFileType, 'top': top.key},
      ),
    );
  }

  // 7) 上传 / 下载比例
  if (s.uploadCount + s.downloadCount >= 5) {
    final up = s.uploadCount, down = s.downloadCount;
    final ratio = up / (up + down);
    out.add(
      UsageInsight(
        kind: InsightKind.transferMix,
        title: ratio >= 0.6
            ? text.usageTitleUploadMain
            : (ratio <= 0.4
                  ? text.usageTitleDownloadMain
                  : text.usageTitleTransferEven),
        body: text.usageBodyTransfer(up, down),
        suggestion: ratio >= 0.6
            ? text.usageSugUploadMain
            : text.usageSugDownloadMain,
        strategyKey: 'upload.default',
        score: conf * 0.8,
        evidence: {'upload': up, 'download': down, 'upload_share': ratio},
      ),
    );
  }

  // 8) 文件体量
  if (s.bySizeBucket.length >= 2) {
    final sorted = s.bySizeBucket.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    out.add(
      UsageInsight(
        kind: InsightKind.sizeMix,
        title: text.usageTitleSizeMix(sorted.first.key),
        body: sorted
            .map((e) => text.usageSizeEntry(e.key, e.value))
            .join(' · '),
        score: conf * 0.7,
        evidence: {'distribution': s.bySizeBucket},
      ),
    );
  }

  // 9) 搜索命中率
  if (s.searchCount >= 5) {
    final emptyRate = s.searchEmpty / s.searchCount;
    out.add(
      UsageInsight(
        kind: InsightKind.searchQuality,
        title: emptyRate >= 0.3
            ? text.usageTitleSearchLow((emptyRate * 100).round())
            : text.usageTitleSearchGood,
        body: text.usageBodySearch(s.searchCount, s.searchEmpty),
        suggestion: emptyRate >= 0.3 ? text.usageSugSearchLow : '',
        strategyKey: 'search.history',
        score: conf * 0.8,
        evidence: {
          'searches': s.searchCount,
          'empty': s.searchEmpty,
          'empty_rate': emptyRate,
        },
      ),
    );
  }

  // 10) 编辑活跃度（写 vs 读）
  if (samples >= 40) {
    final writeShare = (s.editCount * 100 / samples).round();
    out.add(
      UsageInsight(
        kind: InsightKind.editCadence,
        title: writeShare >= 25
            ? text.usageTitleEditHeavy(writeShare)
            : text.usageTitleEditLight(writeShare),
        body: text.usageBodyEdit(s.openCount, s.editCount),
        suggestion: writeShare >= 25
            ? text.usageSugEditHeavy
            : text.usageSugEditLight,
        score: conf * 0.7,
        evidence: {
          'open': s.openCount,
          'edit': s.editCount,
          'write_share': writeShare / 100,
        },
      ),
    );
  }

  // 11) 单次使用时长
  if (s.sessions.length >= 5) {
    out.add(
      UsageInsight(
        kind: InsightKind.sessionLength,
        title: text.usageTitleSession(s.avgSession),
        body: text.usageBodySession(s.sessions.length, s.maxSession),
        suggestion: s.avgSession >= 15
            ? text.usageSugSessionLong
            : text.usageSugSessionShort,
        strategyKey: 'workspace.order',
        score: conf * 0.7,
        evidence: {
          'sessions': s.sessions.length,
          'avg_min': s.avgSession,
          'max_min': s.maxSession,
        },
      ),
    );
  }

  // 12) 失败集中点（体验坑）
  if (s.failures.isNotEmpty) {
    final sorted = s.failures.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.first;
    out.add(
      UsageInsight(
        kind: InsightKind.failureHotspot,
        title: text.usageTitleFailure(top.key, top.value),
        body: sorted
            .take(3)
            .map((e) => text.usageFailureEntry(e.key, e.value))
            .join(' · '),
        suggestion: text.usageSugFailure,
        score: _confidence(top.value) * 0.9,
        evidence: {'failures': s.failures},
      ),
    );
  }

  // 13) 视图/模式偏好：用户习惯用哪种视图（grid/list/timeline/lyrics/…）
  if (s.byViewMode.isNotEmpty && s.total >= 20) {
    final sorted = s.topViewModes;
    final top = sorted.first;
    final totalViews = s.byViewMode.values.fold<int>(0, (a, b) => a + b);
    final share = (top.value * 100 / totalViews).round();
    out.add(
      UsageInsight(
        kind: InsightKind.viewPreference,
        title: text.usageTitleViewPref(
          usageModuleKeyLabel(top.key, text),
          share,
        ),
        body: text.usageBodyViewPref(
          sorted
              .skip(1)
              .take(3)
              .map((e) => usageModuleKeyLabel(e.key, text))
              .join('、'),
        ),
        suggestion: text.usageSugViewPref,
        strategyKey: 'ui.defaultView',
        score: conf * 0.8,
        evidence: {'distribution': s.byViewMode, 'top': top.key, 'share': share / 100},
      ),
    );
  }

  // 14) 失败**原因**：不只是"失败了多少"，而是"为什么失败"（可查询的原因码）
  if (s.byFailureReason.isNotEmpty && s.total >= 20) {
    final sorted = s.topFailureReasons;
    final top = sorted.first;
    out.add(
      UsageInsight(
        kind: InsightKind.failureReason,
        title: text.usageTitleFailureReason(
          _failureKeyLabel(top.key, text),
          top.value,
        ),
        body: text.usageBodyFailureReason(
          sorted
              .skip(1)
              .take(3)
              .map((e) => _failureKeyLabel(e.key, text))
              .join('、'),
        ),
        score: conf * 0.85,
        evidence: {'reasons': s.byFailureReason, 'top': top.key},
      ),
    );
  }

  out.sort((a, b) => b.score.compareTo(a.score));
  return out;
}

String _moduleLabel(String id, AppText t) =>
    UsageModule.byId(id)?.labelIn(t) ?? id;

String _actionLabel(String id, AppText t) =>
    UsageAction.byId(id)?.labelIn(t) ?? id;

/// 失败原因聚合键 `module.reason` → `相册·证书或加密失败`
String _failureKeyLabel(String key, AppText t) {
  final i = key.indexOf('.');
  if (i <= 0) return key;
  return '${_moduleLabel(key.substring(0, i), t)}·'
      '${usageFailureReasonLabel(key.substring(i + 1), t)}';
}
