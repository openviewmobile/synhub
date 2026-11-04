// 使用日志的**写入端**：把 UI 上的操作变成事件落库。
//
// 设计要点（都是踩过的坑）：
//   * **绝不阻塞 UI**：`record` 同步返回，写入在微任务里排队；任何异常都被
//     吞掉（日志失败不能影响业务）；
//   * **批量写**：事件先攒在内存，满 [kFlushSize] 条或 [kFlushDelay] 后
//     用一次事务写下去 —— 高频操作（切板块、翻页）不会变成高频 IO；
//   * **会话切分**：距上一条超过 5 分钟就算新的一段使用，会话 id 用
//     "开始时间戳"（不引入随机数，测试可预期）；
//   * **裁剪**：每次 flush 后顺手删掉超过 [kRetentionDays] 天的事件，
//     以及超过 [kMaxEvents] 条的最老记录（长期样本也有上限，别把手机塞满）；
//   * **匿名**：账号经 `pseudonymize(账号, 本地盐)` 处理后才落库。
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../data/local/analytics_database.dart';
import 'usage_analysis.dart';
import 'usage_event.dart';

/// 攒够多少条就落库
const int kFlushSize = 20;

/// 最长攒多久（防止"只记了几条就再也不写盘"）
const Duration kFlushDelay = Duration(seconds: 5);

/// 保留天数
const int kRetentionDays = 180;

/// 保留的最大条数（超出后删最老的）
const int kMaxEvents = 50000;

/// 元数据 key
const String kMetaEnabled = 'enabled';
const String kMetaSalt = 'salt';
const String kMetaLastPrune = 'last_prune_ms';

class UsageLog {
  UsageLog(AnalyticsDatabase db) : _db = db;

  /// ★★ 第 338 轮（D36）：**没有任何可用后端**时的"日志关闭"实例。
  ///
  /// `_db` 故意**不赋值**：本类每一处库访问都在自己方法的 `try/catch` 里，
  /// 于是 `LateInitializationError` 会被**就地吞掉** ⇒ 读不到、写不进，
  /// 等价于"使用日志关闭"，业务一个字节都不受影响。
  ///
  /// ⚠️ 试过的另一种写法（`LazyDatabase(() async => throw …)` 当空执行器）**不行**：
  /// drift 会把那次失败报进 zone，变成**未捕获异步异常**（本轮实测 3 条用例全红、
  /// 浏览器探针里也是 `ERR:Uncaught`）。"构造得出来但访问会抛"必须**同步**抛。
  UsageLog.disabled() {
    enabled = false;
  }

  late final AnalyticsDatabase _db;

  /// 兼容既有调用点（`db.xxx`）；无后端实例上取它会抛，但所有调用点都在 try 里。
  AnalyticsDatabase get db => _db;

  final List<UsageEvent> _buffer = [];
  Timer? _timer;
  String? _account;
  String _salt = '';

  /// 当前会话的起点（null = 下一条事件开启新会话）
  DateTime? _sessionStart;

  /// 上次事件时间（用来判断要不要切会话）
  DateTime? _lastAt;

  /// 开关（默认开：本地存储、不上传；用户可在「设置 → 使用分析」关掉）
  bool enabled = true;

  bool get hasPending => _buffer.isNotEmpty;

  /// 从库里读开关与盐（启动时调一次；失败就用默认值）
  Future<void> load() async {
    try {
      final rows = await db.select(db.analyticsMetaRows).get();
      for (final r in rows) {
        switch (r.key) {
          case kMetaEnabled:
            enabled = r.value != '0';
          case kMetaSalt:
            _salt = r.value;
        }
      }
      if (_salt.isEmpty) {
        _salt = _randomSalt();
        await _putMeta(kMetaSalt, _salt);
      }
    } catch (_) {
      // 读不到就用默认（开 + 内存盐）——不影响业务
    }
  }

  /// 当前账号（登录后设置一次，用于多账号区分）
  void setAccount(String? account) {
    _account = account == null || account.isEmpty ? null : account;
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    try {
      await _putMeta(kMetaEnabled, value ? '1' : '0');
    } catch (_) {}
  }

  /// 记录一条事件（同步返回，写入异步）——UI 里可以放心调
  void record(
    UsageModule module,
    UsageAction action, {
    String objectType = '',
    int value = 0,
    Map<String, Object?> detail = const {},
    DateTime? at,
  }) {
    if (!enabled) return;
    final now = at ?? DateTime.now();
    // 会话切分
    if (_lastAt == null || now.difference(_lastAt!) > kSessionGap) {
      _sessionStart = now;
    }
    _lastAt = now;
    final account = _account == null ? '' : pseudonymize(_account!, _salt);
    _buffer.add(
      UsageEvent(
        at: now,
        module: module,
        action: action,
        objectType: objectType,
        value: value,
        detail: detail,
        session: '${_sessionStart!.millisecondsSinceEpoch}',
        account: account,
      ),
    );
    if (_buffer.length >= kFlushSize) {
      unawaited(flush());
    } else {
      _timer ??= Timer(kFlushDelay, () => unawaited(flush()));
    }
  }

  /// 记一条失败事件（`action=failure`，`detail.failed_action` 记原动作，
  /// `detail.reason` 记**可查询的原因码**）。
  ///
  /// [reason] 可以直接传功能自己的原因枚举（如 `MediaUnavailableReason.decodeFailed`），
  /// 由 [reasonCodeOf] 归一成稳定码；[error] 只留类型，绝不留 message。
  void recordFailure(
    UsageModule module,
    UsageAction action, {
    String objectType = '',
    Object? reason,
    Object? error,
    DateTime? at,
  }) => record(
    module,
    UsageAction.failure,
    objectType: objectType,
    at: at,
    detail: {
      UsageDetailKeys.failedAction: action.id,
      if (reason != null) UsageDetailKeys.reason: reasonCodeOf(reason),
      if (error != null) UsageDetailKeys.error: _errorKind(error),
    },
  );

  /// 错误只留**类型**，不留 message（message 可能含文件名/路径）
  static String _errorKind(Object error) {
    final s = error.toString();
    final i = s.indexOf(':');
    final head = i > 0 ? s.substring(0, i) : s;
    return head.length > 40 ? head.substring(0, 40) : head;
  }

  /// 缓冲区写入任务链（**串行**：上一次写完才轮到下一次）。
  ///
  /// ⚠️ 这里以前用 `_flushing` 布尔量做互斥，结果是"自动 flush 正在写 →
  /// 手动 flush 直接 return" → 剩下的数据要等定时器，测试/退出时会丢。
  /// 现在改成任务链：`flush()` 一定等前面写完，再写这一轮剩下的。
  Future<void> _pending = Future<void>.value();

  /// 把缓冲区写进库（可并发调用；返回的 Future 完成时**此刻**的事件已落库）
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    _pending = _pending.then((_) => _drain());
    return _pending;
  }

  Future<void> _drain() async {
    if (_buffer.isEmpty) return;
    final batch = List<UsageEvent>.of(_buffer);
    _buffer.clear();
    try {
      await db.batch((b) {
        b.insertAll(db.usageEvents, [for (final e in batch) _companion(e)]);
      });
      await prune();
    } catch (_) {
      // 写失败就当这批丢了（日志不该影响业务）
    }
  }

  UsageEventsCompanion _companion(UsageEvent e) => UsageEventsCompanion.insert(
    atMs: e.atMs,
    module: e.module.id,
    action: e.action.id,
    object: Value(e.objectType),
    value: Value(e.value),
    detail: Value(e.detailJson),
    session: Value(e.session),
    account: Value(e.account),
  );

  /// 裁剪：按天数 + 条数上限（每次 flush 后顺手做，代价很小）
  ///
  /// [maxEvents] 只为测试注入更小的上限用（默认 [kMaxEvents]）；生产永远用默认。
  Future<void> prune({DateTime? now, int? maxEvents}) async {
    final cap = maxEvents ?? kMaxEvents;
    try {
      final cutoff = (now ?? DateTime.now())
          .subtract(const Duration(days: kRetentionDays))
          .millisecondsSinceEpoch;
      await (db.delete(
        db.usageEvents,
      )..where((t) => t.atMs.isSmallerThanValue(cutoff))).go();
      final count = await eventCount();
      if (count > cap) {
        // 删掉最老的 (count - cap) 条：先查出阈值的时间点
        final keepFrom =
            await (db.selectOnly(db.usageEvents)
                  ..addColumns([db.usageEvents.atMs])
                  ..orderBy([OrderingTerm.desc(db.usageEvents.atMs)])
                  ..limit(1, offset: cap - 1))
                .map((r) => r.read(db.usageEvents.atMs))
                .getSingleOrNull();
        if (keepFrom != null) {
          await (db.delete(
            db.usageEvents,
          )..where((t) => t.atMs.isSmallerThanValue(keepFrom))).go();
        }
      }
      await _putMeta(
        kMetaLastPrune,
        '${(now ?? DateTime.now()).millisecondsSinceEpoch}',
      );
    } catch (_) {}
  }

  Future<int> eventCount() async {
    try {
      final c = db.usageEvents.id.count();
      final row = await (db.selectOnly(
        db.usageEvents,
      )..addColumns([c])).getSingle();
      final n = row.read(c) ?? 0;
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// 最近的事件（倒序，最多 [limit] 条）
  Future<List<UsageEvent>> recent({int limit = 200}) async {
    try {
      final rows =
          await (db.select(db.usageEvents)
                ..orderBy([(t) => OrderingTerm.desc(t.atMs)])
                ..limit(limit))
              .get();
      return [for (final r in rows) _toEvent(r)];
    } catch (_) {
      return const [];
    }
  }

  /// 读一段时间窗内的事件（升序；分析用）
  Future<List<UsageEvent>> range({
    Duration window = const Duration(days: 90),
    DateTime? now,
  }) async {
    try {
      final from = (now ?? DateTime.now())
          .subtract(window)
          .millisecondsSinceEpoch;
      final rows =
          await (db.select(db.usageEvents)
                ..where((t) => t.atMs.isBiggerOrEqualValue(from))
                ..orderBy([(t) => OrderingTerm.asc(t.atMs)]))
              .get();
      return [for (final r in rows) _toEvent(r)];
    } catch (_) {
      return const [];
    }
  }

  UsageEvent _toEvent(UsageEventRow r) => UsageEvent(
    at: DateTime.fromMillisecondsSinceEpoch(r.atMs),
    module: UsageModule.byId(r.module) ?? UsageModule.settings,
    action: UsageAction.byId(r.action) ?? UsageAction.open,
    objectType: r.object,
    value: r.value,
    detail: _decodeDetail(r.detail),
    session: r.session,
    account: r.account,
  );

  static Map<String, Object?> _decodeDetail(String raw) {
    try {
      final d = jsonDecode(raw);
      return d is Map ? d.cast<String, Object?>() : const {};
    } catch (_) {
      return const {};
    }
  }

  /// 导出 JSON（给用户自己看 / 以后喂端侧模型）
  Future<String> exportJson({
    Duration window = const Duration(days: 180),
  }) async {
    final events = await range(window: window);
    return const JsonEncoder.withIndent(' ').convert({
      'exported_at': DateTime.now().toIso8601String(),
      'schema': 'synhub.usage/1',
      'privacy': '仅本机使用；不含文件名/标题/正文；账号为加盐哈希前缀。',
      'count': events.length,
      'events': [
        for (final e in events)
          {
            'at': e.at.toIso8601String(),
            'module': e.module.id,
            'action': e.action.id,
            if (e.objectType.isNotEmpty) 'object': e.objectType,
            if (e.value != 0) 'value': e.value,
            if (e.detail.isNotEmpty) 'detail': e.detail,
            if (e.session.isNotEmpty) 'session': e.session,
            if (e.account.isNotEmpty) 'account': e.account,
          },
      ],
    });
  }

  /// 清空所有原始事件（结论保留，可手动再清）
  Future<void> clearEvents() async {
    try {
      await db.delete(db.usageEvents).go();
    } catch (_) {}
  }

  /// 清空结论
  Future<void> clearInsights() async {
    try {
      await db.delete(db.usageInsights).go();
    } catch (_) {}
  }

  /// 落库一批结论（覆盖式：同一批 analysis 产出的结论整批替换）
  Future<void> saveInsights(List<UsageInsight> insights) async {
    try {
      await db.transaction(() async {
        await db.delete(db.usageInsights).go();
        for (final i in insights) {
          await db
              .into(db.usageInsights)
              .insert(
                UsageInsightsCompanion.insert(
                  generatedAtMs: DateTime.now().millisecondsSinceEpoch,
                  kind: i.kind.id,
                  title: i.title,
                  body: i.body,
                  suggestion: Value(i.suggestion),
                  score: Value(i.score),
                  evidence: Value(i.evidenceJson),
                  source: Value(i.source),
                  model: Value(i.model),
                ),
              );
        }
      });
    } catch (_) {}
  }

  /// 读回上次保存的结论（页面首屏先显示缓存，再刷新）
  Future<List<UsageInsight>> savedInsights() async {
    try {
      final rows = await (db.select(
        db.usageInsights,
      )..orderBy([(t) => OrderingTerm.desc(t.score)])).get();
      return [
        for (final r in rows)
          UsageInsight(
            kind: InsightKind.values.firstWhere(
              (k) => k.id == r.kind,
              orElse: () => InsightKind.volume,
            ),
            title: r.title,
            body: r.body,
            suggestion: r.suggestion,
            score: r.score,
            evidence: _decodeDetail(r.evidence),
            source: r.source,
            model: r.model,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _putMeta(String key, String value) async {
    try {
      await db
          .into(db.analyticsMetaRows)
          .insertOnConflictUpdate(
            AnalyticsMetaRowsCompanion.insert(key: key, value: Value(value)),
          );
    } catch (_) {}
  }

  /// 本地盐：24 字节随机
  static String _randomSalt() {
    final rnd = math.Random.secure();
    final bytes = List<int>.generate(24, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// 关掉定时器（测试/退出时用）
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
