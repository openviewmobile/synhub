// 工作台的**排序**：按用户自己的使用习惯，把最常用的入口放到第一屏。
//
// 为什么要有这个：工作台是"启动器"，入口只会越来越多（现在 7 个，P3 的
// Drive 版本/共享/标签、Office 原生编辑、以后的更多一级模块都要进来）。
// 一屏放不下时就得分屏左右滑 —— 那"第一屏放什么"就成了体验的关键：
// 与其我们拍一个顺序，不如**统计使用频率**，常用的自然浮上来。
//
// 口径（r661 改：**时段加权** ＋ **分档迟滞**）：
//   * 一次点击不是加 1 分，而是按半衰期衰减后的"等效次数"再 +1
//     （`kUsageHalfLife = 7 天`：7 天前的一次只值今天的一半）；
//     存的是 `{"id": {"s": 分数, "t": 更新时刻 ms}}`，读的时候按到现在的
//     时间再衰一次 —— 所以**不用点击也会自然冷下去**。
//   * 名次按 `log(1+分数)` 的**分档**取整（`kUsageRankStep = 1.25`，即高出
//     25% 才算高一档），同档保持默认顺序 ⇒ 点一下不会整屏乱跳（以前的
//     整数计数：1 次就超过 0 次的全部模块，几格位置立刻变）。
//   * 老格式 `{"id": 次数}` 仍能读（当作"此刻的等分数"），不清用户数据。
//   * 没有记录时（新装/刚清数据）就是默认顺序，行为与以前一致。
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/app_settings.dart';

/// 使用统计的持久化 key
const String kWorkspaceUsageKey = 'workspace_usage';

/// 时段加权的半衰期：这么久以前的一次点击，只值今天的一半
const Duration kUsageHalfLife = Duration(days: 7);

/// 名次的**分档**步长：分数要高出 25% 才算高一档（＝换位置的门槛）
const double kUsageRankStep = 1.25;

/// 一条使用记录：`at` 那一刻的累计等效分数是 `score`
@immutable
class UsageStat {
  const UsageStat({required this.score, required this.at});

  /// 等效次数（已经衰减到 [at] 这个时刻）
  final double score;

  /// 最后一次点击的时刻（老数据没有，用 null 表示"不知道，当作此刻"）
  final DateTime? at;

  /// 到 [now] 为止的等效分数（按半衰期指数衰减）
  double scoreAt(DateTime now) {
    if (at == null) return score;
    final elapsed = now.difference(at!);
    if (elapsed <= Duration.zero) return score;
    final halfLives = elapsed.inMicroseconds / kUsageHalfLife.inMicroseconds;
    return score * math.pow(0.5, halfLives);
  }

  UsageStat bump(DateTime now) =>
      UsageStat(score: scoreAt(now) + 1, at: now);

  @override
  String toString() => 'UsageStat(${score.toStringAsFixed(2)}, $at)';
}

/// 把等效分数折成"档"：同档不换位，只有跨档才可能超过别人。
int usageRank(double scoreAtNow) =>
    (math.log(1 + scoreAtNow) / math.log(kUsageRankStep)).floor();

/// 按"时段加权的使用频率"排序；同档保持原顺序（稳定）。
///
/// [idOf] 把条目映射成统计用的 id；[usage] 是 `{id: 使用记录}`。
List<T> sortByUsage<T>(
  List<T> items,
  String Function(T item) idOf,
  Map<String, UsageStat> usage, {
  DateTime? now,
}) {
  if (usage.isEmpty) return List<T>.of(items);
  final at = now ?? DateTime.now();
  final indexed = <({int index, T item, int rank})>[
    for (var i = 0; i < items.length; i++)
      (
        index: i,
        item: items[i],
        rank: usageRank(usage[idOf(items[i])]?.scoreAt(at) ?? 0.0),
      ),
  ];
  indexed.sort((a, b) {
    final byRank = b.rank.compareTo(a.rank);
    // 同档**只看默认顺序**：差不到 25% 的两个模块不许互换位置，
    // 否则"点一下顺手打开的那个"就会把它顶走一格 —— 这正是以前的漂移。
    return byRank != 0 ? byRank : a.index.compareTo(b.index);
  });
  return [for (final e in indexed) e.item];
}

/// 解析 `{"file": {"s": 2.4, "t": 1761...}}`（也吃老的 `{"file": 12}`）；
/// 坏的/空的都当"没有统计"。
Map<String, UsageStat> decodeWorkspaceUsage(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    final out = <String, UsageStat>{};
    decoded.forEach((k, v) {
      final stat = _usageStatOf(v);
      if (stat != null) out['$k'] = stat;
    });
    return out;
  } catch (_) {
    return const {};
  }
}

UsageStat? _usageStatOf(Object? v) {
  if (v is num) {
    // 老格式：整数次数（没有时间戳 ⇒ 当作此刻的等分数，不额外衰减）
    final n = v.toDouble();
    return n > 0 ? UsageStat(score: n, at: null) : null;
  }
  if (v is Map) {
    final s = v['s'];
    final t = v['t'];
    final score = s is num ? s.toDouble() : double.tryParse('$s');
    if (score == null || !score.isFinite || score <= 0) return null;
    final ms = t is num ? t.toInt() : int.tryParse('$t');
    final at = ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: false);
    return UsageStat(score: score, at: at);
  }
  return null;
}

/// 编码回库：`{"file": {"s": 2.4, "t": 1761...}}`（分数留 3 位小数，够用且短）
String encodeWorkspaceUsage(Map<String, UsageStat> usage) {
  final out = <String, Object?>{
    for (final e in usage.entries)
      if (e.value.score > 0)
        e.key: {
          's': double.parse(e.value.score.toStringAsFixed(3)),
          't': e.value.at?.millisecondsSinceEpoch,
        },
  };
  return jsonEncode(out);
}

/// 工作台入口的使用记录（`{入口 id: 等效次数}`）
final workspaceUsageProvider =
    NotifierProvider<WorkspaceUsageNotifier, Map<String, UsageStat>>(
      WorkspaceUsageNotifier.new,
    );

class WorkspaceUsageNotifier extends Notifier<Map<String, UsageStat>> {
  @override
  Map<String, UsageStat> build() => const {};

  /// 启动时把统计读进内存（`app.dart` 里 preload）
  ///
  /// 顺带做一次**格式迁移**：老的 `{"id": 12}`（只有次数、没有时刻）当作
  /// "最后一次使用就是现在"，补上时刻并回写 —— 否则老数据永远不会衰减，
  /// 一个半年前的热门模块会一直压在新习惯头上。
  Future<void> preload({DateTime? now}) async {
    final raw = await ref.read(settingsServiceProvider).workspaceUsageRaw();
    if (!ref.mounted) return;
    final decoded = decodeWorkspaceUsage(raw);
    if (decoded.isEmpty) {
      state = decoded;
      return;
    }
    final at = now ?? DateTime.now();
    var stamped = false;
    final migrated = <String, UsageStat>{};
    decoded.forEach((id, stat) {
      if (stat.at == null) {
        stamped = true;
        migrated[id] = UsageStat(score: stat.score, at: at);
      } else {
        migrated[id] = stat;
      }
    });
    state = migrated;
    if (stamped) {
      await ref
          .read(settingsServiceProvider)
          .setWorkspaceUsageRaw(encodeWorkspaceUsage(migrated));
    }
  }

  /// 记一次点击（先改内存再落库：UI 不等磁盘）
  ///
  /// 分数按半衰期先衰减到"现在"再加 1 —— 所以"最近常用"才是真的常用，
  /// 上个月用过的热门模块会自己冷下去。
  Future<void> record(String id, {DateTime? now}) async {
    if (id.isEmpty) return;
    final at = now ?? DateTime.now();
    final prev = state[id];
    final next = <String, UsageStat>{
      ...state,
      id: (prev ?? UsageStat(score: 0, at: at)).bump(at),
    };
    state = next;
    await ref
        .read(settingsServiceProvider)
        .setWorkspaceUsageRaw(encodeWorkspaceUsage(next));
  }

  /// 清空统计（"恢复默认顺序"）
  Future<void> reset() async {
    state = const {};
    await ref.read(settingsServiceProvider).setWorkspaceUsageRaw('');
  }
}

/// 被"收进第二屏"的入口（本地偏好；空集 = 都在）
const String kWorkspaceHiddenKey = 'workspace_hidden';

/// 解析 `["photos","office"]`；坏的/空的都当"没隐藏"
Set<String> decodeWorkspaceHidden(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const {};
    return {
      for (final e in decoded)
        if ('$e'.trim().isNotEmpty) '$e'.trim(),
    };
  } catch (_) {
    return const {};
  }
}

/// 隐藏集合（`{入口 id}`）
final workspaceHiddenProvider =
    NotifierProvider<WorkspaceHiddenNotifier, Set<String>>(
      WorkspaceHiddenNotifier.new,
    );

class WorkspaceHiddenNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// 启动时把偏好读进内存（`app.dart` 里 preload）
  Future<void> preload() async {
    final raw = await ref.read(settingsServiceProvider).workspaceHiddenRaw();
    if (!ref.mounted) return;
    state = decodeWorkspaceHidden(raw);
  }

  /// 收起来（并入，不覆盖已有）
  Future<void> hide(Iterable<String> ids) async {
    final next = {...state, ...ids.where((e) => e.isNotEmpty)};
    if (next.length == state.length) return;
    state = next;
    await _persist();
  }

  /// 全部还原
  Future<void> showAll() async {
    if (state.isEmpty) return;
    state = const {};
    await _persist();
  }

  Future<void> _persist() async {
    final raw = jsonEncode(state.toList()..sort());
    await ref.read(settingsServiceProvider).setWorkspaceHiddenRaw(raw);
  }
}
