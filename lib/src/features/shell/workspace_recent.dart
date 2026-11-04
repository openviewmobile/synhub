// 工作台的「最近常用」：按**最近一次真的打开**的时间倒序排一段横滑条。
//
// 与 [workspaceUsageProvider]（点得多的排第一屏）的分工：
//   * 使用次数 = "长期习惯"，只用来排网格；
//   * 最近使用 = "刚才干了什么"，用来做动态入口 —— 用户从别的模块回工作台时，
//     想找的通常是**刚刚那个**，次数统计给不了这个（刚打开一次的新模块次数很小）。
//
// 存储沿用工作台的老套路：Drift 键值表（key `workspace_recent`，JSON
// `[{"id":"notes","at":1690000000000}, ...]`），不新增插件依赖、离线测试里也能真读写。
//
// 约定：
//   * 上限 [kWorkspaceRecentLimit] 条；同一模块只保留最新一条（去重后再截断）；
//   * 读的时候一律重排 + 去重 + 截断，坏数据当"没有记录"（绝不让 UI 崩）；
//   * 记录点 = 用户真的进了模块（工作台磁贴 / 底栏 tab），不是"渲染过"。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/app_settings.dart';

/// 「最近常用」的持久化 key
const String kWorkspaceRecentKey = 'workspace_recent';

/// 最多留几条（超出丢最旧的）
const int kWorkspaceRecentLimit = 10;

/// 一条"最近使用"记录
class WorkspaceRecent {
  const WorkspaceRecent({required this.id, required this.at});

  /// 入口 id（与 `_WsItem.id` / `AppTab.name` 同一套稳定 id）
  final String id;

  /// 最后打开时间（毫秒）
  final int at;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceRecent && other.id == id && other.at == at;

  @override
  int get hashCode => Object.hash(id, at);
}

/// 记一次使用：去重（同一 id 只留最新）→ 按时间倒序 → 截断到 [limit]。
///
/// [at] 由调用方给（测试里可控），不放函数内部取 `DateTime.now()`。
List<WorkspaceRecent> recordWorkspaceRecent(
  List<WorkspaceRecent> current,
  String id,
  int at, {
  int limit = kWorkspaceRecentLimit,
}) {
  if (id.trim().isEmpty) return List<WorkspaceRecent>.of(current);
  final next = <WorkspaceRecent>[
    WorkspaceRecent(id: id, at: at),
    for (final e in current)
      if (e.id != id) e,
  ];
  return _normalize(next, limit: limit);
}

/// 解析 `[{"id":"notes","at":1}, ...]`。
///
/// 容错：非 JSON / 不是数组 / 条目缺 id 一律丢掉；`at` 认 int 也认数字串。
List<WorkspaceRecent> decodeWorkspaceRecent(
  String? raw, {
  int limit = kWorkspaceRecentLimit,
}) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <WorkspaceRecent>[];
    for (final e in decoded) {
      if (e is! Map) continue;
      final id = '${e['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;
      final v = e['at'];
      final at = v is int ? v : int.tryParse('$v');
      if (at == null || at < 0) continue;
      out.add(WorkspaceRecent(id: id, at: at));
    }
    return _normalize(out, limit: limit);
  } catch (_) {
    return const [];
  }
}

String encodeWorkspaceRecent(
  List<WorkspaceRecent> uses, {
  int limit = kWorkspaceRecentLimit,
}) {
  final normalized = _normalize(uses, limit: limit);
  return jsonEncode([
    for (final e in normalized) {'id': e.id, 'at': e.at},
  ]);
}

/// 倒序 + 去重（保留时间最新的那条）+ 截断。
///
/// 时间相同时按**输入顺序**（稳定）—— `recordWorkspaceRecent` 把新记录放在最前，
/// 所以同一毫秒内连点两个模块也是"后点的在前"。
List<WorkspaceRecent> _normalize(
  List<WorkspaceRecent> input, {
  required int limit,
}) {
  final indexed = [
    for (var i = 0; i < input.length; i++) (index: i, use: input[i]),
  ];
  indexed.sort((a, b) {
    final byTime = b.use.at.compareTo(a.use.at);
    return byTime != 0 ? byTime : a.index.compareTo(b.index);
  });
  final seen = <String>{};
  final out = <WorkspaceRecent>[];
  for (final e in indexed) {
    if (e.use.id.isEmpty || !seen.add(e.use.id)) continue;
    out.add(e.use);
    if (out.length >= limit) break;
  }
  return out;
}

/// 「最近常用」的入口 id 列表（倒序）
final workspaceRecentProvider =
    NotifierProvider<WorkspaceRecentNotifier, List<WorkspaceRecent>>(
      WorkspaceRecentNotifier.new,
    );

class WorkspaceRecentNotifier extends Notifier<List<WorkspaceRecent>> {
  @override
  List<WorkspaceRecent> build() => const [];

  /// 启动时把记录读进内存（`app.dart` 里 preload）
  Future<void> preload() async {
    final raw = await ref.read(settingsServiceProvider).workspaceRecentRaw();
    if (!ref.mounted) return;
    state = decodeWorkspaceRecent(raw);
  }

  /// 记一次"真的打开了这个模块"（先改内存再落库：UI 不等磁盘）
  Future<void> record(String id, {DateTime? now}) async {
    if (id.trim().isEmpty) return;
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    state = recordWorkspaceRecent(state, id, at);
    await ref
        .read(settingsServiceProvider)
        .setWorkspaceRecentRaw(encodeWorkspaceRecent(state));
  }

  /// 清空记录（设置里"清掉最近使用"用；也方便测试）
  Future<void> clear() async {
    if (state.isEmpty) return;
    state = const [];
    await ref.read(settingsServiceProvider).setWorkspaceRecentRaw('');
  }
}
