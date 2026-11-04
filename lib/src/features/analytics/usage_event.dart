// 使用日志的**事件分类**（纯 Dart，不依赖 Flutter / 数据库）。
//
// 分类口径是这套分析的"坐标系"：模块 × 动作 × 对象类型。口径定得稳，
// 后面无论用规则还是端侧模型，输入特征都一致，结论也能跨版本比较。
//
// 三个原则：
//   1. **只记"做了什么"，不记"做了什么内容"**：动作名 + 对象类型，绝不含
//      文件名、笔记标题、联系人、消息正文；
//   2. 动作名用**动词短语**（`open`/`preview`/`upload`…），将来加动作是
//      "加常量"，不改表结构；
//   3. 数值一律**分桶或聚合**后使用（大小分桶见 [sizeBucket]），避免把
//      精确尺寸当成指纹。
import 'dart:convert';

import 'package:pointycastle/digests/sha256.dart';

/// 一级模块。id 会直接落库，**不要改名**（改了老数据就对不上了）。
///
/// 第 275 轮补齐了新功能模块（audio/media/ai/downloads/admin/surveillance/
/// mailplus）——在此之前这些模块的动作**根本无处可记**（枚举里没有对应 id）。
enum UsageModule {
  workspace('workspace', '工作台'),
  files('files', '文件'),
  drive('drive', 'Synology Drive'),
  notes('notes', '笔记'),
  photos('photos', '相册'),
  calendar('calendar', '日历'),
  contacts('contacts', '联系人'),
  chat('chat', '聊天'),
  search('search', '搜索'),
  reader('reader', '阅读'),
  office('office', 'Office'),
  settings('settings', '设置'),
  audio('audio', 'Audio Station'),
  media('media', '影音'),
  ai('ai', 'AI 助手'),
  downloads('downloads', '下载'),
  admin('admin', '管理'),
  surveillance('surveillance', '监控'),
  mailplus('mailplus', 'MailPlus'),

  /// **未归属**：网络流量里"没打模块标签"的那一份。
  ///
  /// 它不是功能模块（没有页面、不参与"功能采用率"），但必须存在：
  /// 计量的默认落点就是它 —— 宁可让用户看到"有 N MB 没归属"，
  /// 也不能让未打标签的流量凭空消失（见 `core/net/traffic_meter.dart`）。
  unattributed('unattributed', '未归属');

  const UsageModule(this.id, this.label);

  final String id;
  final String label;

  static UsageModule? byId(String id) {
    for (final m in UsageModule.values) {
      if (m.id == id) return m;
    }
    return null;
  }
}

/// 动作。同样是**落库常量**，只增不改。
enum UsageAction {
  // 注意：常量名不能与下面的字段 `id`/`label` 同名，
  // 否则 Dart 分析器会把常量声明当构造函数调用（`label` 就踩过）
  open('open', '打开'),
  preview('preview', '预览'),
  search('search', '搜索'),
  upload('upload', '上传'),
  download('download', '下载'),
  create('create', '新建'),
  edit('edit', '编辑'),
  delete('delete', '删除'),
  share('share', '共享'),
  addLabel('label', '打标签'),
  star('star', '星标'),
  switchSection('switch_section', '切换板块'),
  openExternal('open_external', '外部打开'),
  bookmark('bookmark', '收藏'),
  play('play', '播放'),
  exportFile('export', '导出'),
  restore('restore', '恢复'),
  move('move', '移动'),
  rename('rename', '重命名'),
  sync('sync', '同步'),
  copy('copy', '复制'),
  failure('error', '失败'),
  // ── 第 275 轮：行为偏好类动作（视图/筛选/排序/模板/播放会话/结果）──
  // 只增不改：id 落库，老数据按 id 读回。
  view('view', '进入页面'),
  switchView('switch_view', '切换视图'),
  filter('filter', '筛选'),
  sort('sort', '排序'),
  select('select', '选择'),
  complete('complete', '完成'),
  abandon('abandon', '中断'),
  start('start', '开始'),
  pause('pause', '暂停'),
  resume('resume', '继续'),
  audition('audition', '试听'),
  vote('vote', '投票'),
  switchLanguage('switch_language', '切换语言');

  const UsageAction(this.id, this.label);

  final String id;
  final String label;

  static UsageAction? byId(String id) {
    for (final a in UsageAction.values) {
      if (a.id == id) return a;
    }
    return null;
  }
}

/// `UsageEvent.detail` 里**允许出现的键**（集中登记，避免调用点写字符串写错）。
///
/// 规矩（沿用「只记动作 + 类型 + 数字，不记内容」）：
///   * 只允许放**枚举型/分类型**的值（`via=filestation`、`view=grid`、
///     `reason=auth`…），**绝不放**文件名、标题、路径、hostname、账号；
///   * 键也集中在这里，页面/分析/用例三处引用同一组常量；
///   * 新增键 = 在这里加一个常量，并在 `kAnalyticsForbiddenDetailKeys`
///     里确认它不属于禁用类。
abstract final class UsageDetailKeys {
  /// 动作发起来源：`nas` / `drive` / `filestation` / `quickconnect`…
  static const String source = 'source';
  /// 对象更细的类别：`image` / `video` / `audio` / `revisions`…
  static const String kind = 'kind';
  /// 传输通道：`filestation` / `drive`…
  static const String via = 'via';
  /// 失败时的**原动作** id（`failure` 事件必带）
  static const String failedAction = 'failed_action';
  /// 失败**原因码**（可查询、可分组；不是 message）
  static const String reason = 'reason';
  /// 错误**类型**（异常类名，不含 message）
  static const String error = 'error';
  /// 视图模式：`grid` / `list` / `timeline` / `lyrics` / `visualizer`…
  static const String view = 'view';
  /// 版块/标签/分类名（枚举值，不是内容）
  static const String section = 'section';
  /// 语言代码：`zh` / `en`
  static const String lang = 'lang';
  /// 主题/模板/preset 的**稳定编号或键**（不是用户填的标题）
  static const String preset = 'preset';
  /// 播放/阅读会话时长（毫秒）
  static const String durationMs = 'duration_ms';
  /// 结果计数（条数）
  static const String count = 'count';
  /// 是否有结果
  static const String hasResult = 'has_result';

  /// 已知的**禁用键**：一旦出现就说明埋点把内容泄进了日志库。
  /// 用例 `test/analytics_schema_test.dart` 会逐键静态扫描源码。
  static const Set<String> forbidden = {
    'name',
    'filename',
    'file_name',
    'path',
    'title',
    'content',
    'body',
    'message',
    'text',
    'host',
    'hostname',
    'url',
    'server',
    'account',
    'username',
    'password',
    'token',
    'sid',
  };
}

/// **可查询的失败原因码**（跨模块统一口径）。
///
/// 与 AGENTS §2.0.17 ② 一致：失败必须"能说出原因"，而且原因是**稳定的码**，
/// 不是随手的 message（message 可能带文件名/路径）。各功能自己的原因枚举
/// （如 `MediaUnavailableReason`、`BackupSkipReason`）通过 [reasonCodeOf]
/// 归一到这里；认不出的原样保留（`<enum>:<value>`），仍可分组统计。
enum UsageFailureReason {
  unknown('unknown', '未知原因'),
  offline('offline', '离线/未连接'),
  network('network', '网络错误'),
  timeout('timeout', '超时'),
  auth('auth', '认证失败'),
  permission('permission', '无权限'),
  notFound('not_found', '不存在'),
  unsupported('unsupported', '不支持'),
  decode('decode', '解码/渲染失败'),
  tls('tls', '证书/加密失败'),
  storage('storage', '存储不足'),
  conflict('conflict', '冲突'),
  server('server', '服务端错误'),
  cancelled('cancelled', '已取消');

  const UsageFailureReason(this.id, this.label);

  final String id;

  /// 中文回落（落库/分析用；界面走 `analytics_labels.dart`）
  final String label;

  static UsageFailureReason? byId(String id) {
    for (final r in UsageFailureReason.values) {
      if (r.id == id) return r;
    }
    return null;
  }
}

/// 把任意"原因"归一成稳定的原因码：
///   * 本枚举 → `id`；
///   * 其它枚举 → 优先它自己的稳定 `id` 字段（如 `MediaUnavailableReason.id`
///     = `empty_url`，改名不影响老数据），没有才用 `name`；
///   * 字符串 → 原样（截断到 40 字符）；
///   * 其它对象 → `unknown`。
///
/// **绝不留 message**：`Exception('.../客户合同.pdf 不存在')` 只会归成 `unknown`。
String reasonCodeOf(Object? reason) {
  if (reason == null) return UsageFailureReason.unknown.id;
  if (reason is UsageFailureReason) return reason.id;
  if (reason is Enum) {
    try {
      final id = (reason as dynamic).id;
      if (id is String && id.isNotEmpty) return id;
    } catch (_) {
      // 该枚举没有 id 字段 → 回落 name
    }
    return reason.name;
  }
  if (reason is String) {
    final s = reason.trim();
    if (s.isEmpty) return UsageFailureReason.unknown.id;
    return s.length > 40 ? s.substring(0, 40) : s;
  }
  return UsageFailureReason.unknown.id;
}

/// 一条使用事件（纯值对象；落库由 `UsageLog` 负责）
class UsageEvent {  const UsageEvent({
    required this.at,
    required this.module,
    required this.action,
    this.objectType = '',
    this.value = 0,
    this.detail = const {},
    this.session = '',
    this.account = '',
  });

  final DateTime at;
  final UsageModule module;
  final UsageAction action;

  /// 对象**类型**：扩展名 / `folder` / `note` / `album` / `event`…
  final String objectType;

  /// 数值：字节数、毫秒、结果条数…
  final int value;

  /// 其它脱敏上下文
  final Map<String, Object?> detail;

  final String session;
  final String account;

  int get atMs => at.millisecondsSinceEpoch;

  String get detailJson => jsonEncode(detail);
}

/// 大小分桶（对数的粗桶）：分析"文件体量偏好"够用，又不会变成指纹。
/// 返回 `1k`/`1M` 这样的短标签。
String sizeBucket(int bytes) {
  if (bytes <= 0) return '0';
  const units = ['B', 'K', 'M', 'G', 'T'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  if (u == 0) return '<1K';
  // 只保留"数量级中的位置"：<2 / 2–5 / 5–10 / ≥10
  final step = v < 2 ? '1' : (v < 5 ? '2' : (v < 10 ? '5' : 'x'));
  return '$step${units[u]}';
}

/// 取扩展名（小写、带点）；没有就当 `none`
String extensionOf(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) return 'none';
  final ext = name.substring(i).toLowerCase();
  // 太长的"扩展名"多半是完整名字的一部分，别拿来当类型
  if (ext.length > 8) return 'none';
  return ext;
}

/// 账号假名：`sha256(盐 + 账号)` 前 12 位。同一台设备上能区分账号，
/// 但反推不出账号（盐是本地随机生成的，只存在本机）。
String pseudonymize(String account, String salt) {
  if (account.isEmpty) return '';
  final digest = SHA256Digest().process(utf8.encode('$salt|$account'));
  final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return hex.substring(0, 12);
}

/// 会话切分：相邻事件间隔超过 [gap] 就算新的一段使用
const Duration kSessionGap = Duration(minutes: 5);

/// 给定时间，返回它属于哪个"时段"（用于作息类结论）
String hourBand(int hour) {
  if (hour < 6) return '深夜(0-6)';
  if (hour < 9) return '早晨(6-9)';
  if (hour < 12) return '上午(9-12)';
  if (hour < 14) return '中午(12-14)';
  if (hour < 18) return '下午(14-18)';
  if (hour < 22) return '晚上(18-22)';
  return '夜里(22-24)';
}
