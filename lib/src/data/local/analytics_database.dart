// 使用日志库（**独立于业务库**的第二个 Drift 数据库）。
//
// 为什么要单独一个库（而不是塞进 `synhub.sqlite`）：
//   * 生命周期不同：业务缓存可以随"清理缓存"删掉，使用日志是**长期样本**，
//     删了就没法做趋势分析；
//   * 读写特征不同：日志是"只追加 + 定期裁剪"的高频小写，业务库是随机读写；
//   * 送端侧模型分析时，可以只把 `synology_analytics.sqlite` 导出来，边界干净；
//   * 迁移风险隔离：日志表结构将来必然要加列（加特征），不该让业务库的
//     迁移跟着一起冒险。
//
// 三张表：
//   * [UsageEvents]   —— 原始事件（只追加）。**谁在什么时候用了哪个模块的哪个动作**，
//                        不存文件名/标题/消息正文这类内容，只存"类型 + 计数 + 数值"。
//   * [UsageInsights] —— 由本地启发式（以及以后的端侧模型）算出来的**结论**，
//                        带"建议"和"是否已应用"，是"分析 → 反哺策略"的落点。
//   * [AnalyticsMetaRows] —— 开关、匿名盐、上次裁剪时间等键值。
//   * [TrafficBuckets]  —— **网络流量**的小时聚合桶（第 276 轮）：
//                         `模块 × 方向 × 档位 × 接入方式` 的字节数，按小时聚合；
//                         没有 URL/host/path 列（见 `docs/network-traffic-analytics.md`）。
//
// 隐私约定（代码里也要守）：
//   * 账号只存**加盐哈希前 12 位**（[pseudonymize]），不存明文账号；
//   * 文件名/笔记标题/联系人姓名/聊天内容一律不落库，只留扩展名或"类型"；
//   * 全部本地存储，不上传；导出/清空都在「设置 → 使用分析」里一键做。
library;

import 'package:drift/drift.dart';

// ★ 第 334 轮：连接层按平台条件导入 —— `drift/native`/`drift_flutter` 会传递到
// `package:sqlite3` 的 FFI 后端，web 上编不过（`flutter build web` 的 P0）。
// web 桩如实抛（还没有 wasm 后端），见 `analytics_connection_stub.dart`。
import 'analytics_connection_stub.dart'
    if (dart.library.io) 'analytics_connection_io.dart';

part 'analytics_database.g.dart';

/// 原始使用事件（只追加，按时间裁剪）
@TableIndex(name: 'usage_event_at', columns: {#atMs})
@DataClassName('UsageEventRow')
class UsageEvents extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 发生时间（epoch 毫秒）
  IntColumn get atMs => integer()();

  /// 模块：files / notes / photos / calendar / contacts / chat / drive /
  /// workspace / reader / settings / search…（见 `UsageModule`）
  TextColumn get module => text()();

  /// 动作：open / preview / search / upload / download / create / edit /
  /// delete / switch_section / share / label…（见 `UsageAction`）
  TextColumn get action => text()();

  /// "对象类型"，**不含具体名字**：文件扩展名（`.docx`）、条目类型
  /// （`folder`/`note`/`album`/`event`）、板块名等
  TextColumn get object => text().withDefault(const Constant(''))();

  /// 可选数值：大小（字节）、耗时（毫秒）、结果条数、第几页…
  IntColumn get value => integer().withDefault(const Constant(0))();

  /// 其它脱敏上下文（JSON）：如 `{"source":"drive","kind":"image"}`
  TextColumn get detail => text().withDefault(const Constant('{}'))();

  /// 会话 id（同一段连续使用共享一个值；由 UsageLog 按"间隔 > 5 分钟"切分）
  TextColumn get session => text().withDefault(const Constant(''))();

  /// 账号假名（加盐哈希前 12 位），多账号共用一台设备时能分开看
  TextColumn get account => text().withDefault(const Constant(''))();
}

/// 本地分析产出的结论（启发式 or 端侧模型）
@DataClassName('UsageInsightRow')
class UsageInsights extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 生成时间（epoch 毫秒）
  IntColumn get generatedAtMs => integer()();

  /// 结论类型：peak_hour / top_module / unused_module / search_quality /
  /// file_type_pref / transfer_mix / edit_cadence / session_length /
  /// weekday_pattern / feature_gap…（见 `InsightKind`）
  TextColumn get kind => text()();

  TextColumn get title => text()();

  TextColumn get body => text()();
  TextColumn get suggestion => text().withDefault(const Constant(''))();

  /// 可信度 / 重要性（0–1，样本不足会调低）
  RealColumn get score => real().withDefault(const Constant(0))();

  /// 支撑证据（JSON：统计口径 + 数字，便于复核与喂给模型）
  TextColumn get evidence => text().withDefault(const Constant('{}'))();

  /// 来源：`heuristic`（本地规则）/ `on_device_llm`（端侧模型）
  TextColumn get source => text().withDefault(const Constant('heuristic'))();

  /// 模型标识（端侧模型产出的结论才有）
  TextColumn get model => text().withDefault(const Constant(''))();

  /// 这条建议被应用到 App 策略的时间（0 = 还没应用）
  IntColumn get appliedAtMs => integer().withDefault(const Constant(0))();
}

/// 分析用键值（开关 / 盐 / 上次裁剪）
@DataClassName('AnalyticsMetaRow')
class AnalyticsMetaRows extends Table {
  TextColumn get key => text()();
  TextColumn get value => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {key};
}

/// **网络流量**的小时聚合桶（第 276 轮）。
///
/// 为什么是"小时桶"而不是"每请求一行"：
///   * 时段分析（24 小时分布）本来就是按小时看，预聚合后查询是 O(桶数)；
///   * 隐私上**根本没有承载地址的列** —— 只有 `模块 × 方向 × 档位 × 接入方式`；
///   * 有界：一次请求不会写一行，高频轮询/缩略图风暴不会把库写爆。
///
/// 唯一键是 `(hourMs, module, direction, tier, transport)`：写入是
/// `INSERT … ON CONFLICT DO UPDATE SET bytes = bytes + excluded.bytes`，
/// 并发/重放都不会丢也不会重复计（每个字节只在一个桶里加一次）。
///
/// `tier` 见 `core/net/traffic_meter.dart`：`exact`（Dart HTTP 实测）/
/// `estimated`（原生组件绕过 Dart，UID 计数在活动会话窗口内差分）。
@DataClassName('TrafficBucketRow')
@TableIndex(name: 'traffic_bucket_hour', columns: {#hourMs})
class TrafficBuckets extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 小时桶的起点（**本地墙钟**的整点，epoch 毫秒）。
  ///
  /// 用本地墙钟而不是 UTC：用户问的是"我几点用的"，DST 切换时
  /// 会出现某个小时桶变长/变短，这是真实世界的语义（文档有说明）。
  IntColumn get hourMs => integer()();

  /// 模块 id（`UsageModule.id`；未归属是 `unattributed`）
  TextColumn get module => text()();

  /// 方向：`down`（Rx）/ `up`（Tx）
  TextColumn get direction => text()();

  /// 档位：`exact` / `estimated`
  TextColumn get tier => text()();

  /// 接入方式：`wifi` / `mobile` / `other` / `''`（不知道）
  TextColumn get transport => text().withDefault(const Constant(''))();

  /// 累计字节
  IntColumn get bytes => integer().withDefault(const Constant(0))();

  /// 累计样本数（精确档 = 请求次数；估算档 = 会话段数）——只作可信度参考
  IntColumn get samples => integer().withDefault(const Constant(0))();
}

/// 使用日志库。`synology_analytics.sqlite` 落在应用文档目录下。
@DriftDatabase(
  tables: [
    UsageEvents,
    UsageInsights,
    AnalyticsMetaRows,
    TrafficBuckets,
  ],
)
class AnalyticsDatabase extends _$AnalyticsDatabase {
  AnalyticsDatabase(super.e);

  /// 表结构版本。**加列/加表时记得同时写 onUpgrade**（业务库踩过漏写迁移的坑）。
  ///
  /// v2：加 [TrafficBuckets]（网络流量小时聚合桶）。
  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v1 → v2：只加表，老数据（事件/结论/元数据）原样保留。
      if (from < 2) await m.createTable(trafficBuckets);
    },
  );

  /// 打开（或创建）磁盘上的默认库
  ///
  /// ★★ P0-2（Linux 站，第 109 轮）：同 [ChatDatabase.open] —— 默认的
  /// `getApplicationDocumentsDirectory()` 在缺 `xdg-user-dirs` 的 Linux 上抛，
  /// 改走 [AppPaths.documentsDirectory]（Linux 按 XDG 回落，其它平台不变）。
  factory AnalyticsDatabase.open() =>
      AnalyticsDatabase(analyticsConnection());

  /// 内存库：离线测试，以及"磁盘开库失败"时的兜底（日志功能降级但不崩）
  factory AnalyticsDatabase.memory() =>
      AnalyticsDatabase(analyticsMemoryConnection());

}
