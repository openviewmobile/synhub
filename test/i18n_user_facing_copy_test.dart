// 静态守卫：**内部接口名 / 字段名不许当用户文案**（棘轮，第 340 轮）。
//
// ★ 为什么会有这条：
//   AGENTS §2.0.47 早就立了"诊断串不许当用户文案"。第 308 轮只在 Office 错误面板
//   一条路上加了守卫（`return error.message;`），**ARB 本身是另一条旁路**：
//   第 339 轮真机在加密页看到 `Channel/list 不带 broken_users，这里问 Channel.Member/get`，
//   第 340 轮真机又在 Drive「新建」菜单看到 `Synology Drive · \`Files/create\``
//   （macOS `D7` / Linux `LD-D1` 早就以像素登记过同一个缺陷，**安卓侧一直没改**）。
//   ⇒ 光靠"某一路径有守卫"证明不了"所有文案都干净"（§2.0.47 通式）。
//
// 三条判据（`app_zh.arb` 与 `app_en.arb` 各扫一遍，值里出现即命中）：
//   R1 `\`…\`` 反引号包住的标识符 —— Markdown 记号会**原样画在界面上**；
//   R2 `Api.Method/method` 形状（带点的接口路径）—— 如 `Office.Node/create`；
//   R3 `snake_case` 字段名 —— 如 `broken_users` / `allow_guest`。
//   R4 厂商缩写黑名单 —— `FCM` / `GMS`（我们的实现选型，用户不认识也无法据此操作）。
//
// ★ 两条断言缺一不可：
//   ① **正向**：命中但不在白名单 ⇒ 红（新增泄漏不许静默进仓）；
//   ② **反向**：在白名单里却**已经不再命中** ⇒ 红（防"陈旧条目"把白名单当垃圾桶；
//      同族见 §1.3.0.1「校验 0 条不是成功，是没校验」）。
//
// 白名单 = `tool/i18n_technical_copy.txt`（`key<TAB>类别<TAB>渲染点`），类别三选一：
//   `diag` 诊断/只读渲染内部页专用；`md` Markdown 语法说明（反引号是**正确**的）；
//   `todo` 面向用户但仍带技术字样 —— 这是**待还的债**，改好一条就从表里删一条
//   （反向断言会强制你删，否则红）。
//
// ★ 为什么不用"关键词黑名单"式宽判据：`Upload/Download`、`Date/time`、`WLAN/AP`
//   这类正常中英文都长成 `A/B`，宽判据会把它们全判红（r340 实测：放宽 `[A-Z]\w*/[a-z]\w*`
//   会多出 13 条假阳性）。所以 R2 只认**带点的接口路径**；不带点的 `Channel/list`
//   由同句里的 `broken_users`(R3) / `Channel.Member/get`(R2) 兜住。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// R1：反引号包住的标识符（整段反引号内容算一个标记）。
final RegExp _backtickRe = RegExp(r'`[^`]+`');

/// R2：带点的接口路径 `Api.Method/method`（`/` 后要求小写开头，`Android/iOS` 不算）。
final RegExp _apiPathRe = RegExp(
  r'\b[A-Z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+/[a-z][A-Za-z0-9_]*',
);

/// R3：snake_case 字段名（至少一个下划线，右侧仍是小写/数字/下划线）。
final RegExp _snakeRe = RegExp(r'\b[a-z][a-z0-9]*_[a-z0-9_]+\b');

/// 方法路径形状（**规则 C 专用**，不进 `technicalHitsIn` 的棘轮）：
/// 左边 `Api`/`Event` 这种起首大写的段，右边小写方法名 —— `Event/list_color`、
/// `Cal.Timezone/list`、`Files/create` 命中；`26/26`、`cover/even` 不命中。
final RegExp _methodPathRe = RegExp(
  r'\b[A-Z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)*/[a-z][A-Za-z0-9_]*',
);

/// R5：**裸的接口全名** `SYNO.Xxx.Yyy`（第 348 轮 D60 补）。
/// ★ 为什么 R2 拦不住：R2 要求 `接口/方法`（带 `/` 且方法名小写开头），
///   而真机与 ARB 里的泄漏长这样 —— `SYNO.Cal.Contact 不可用`、
///   `SYNO.NoteStation.Note`、`Universal Search · SYNO.Finder` —— **全都没有 `/`**
///   ⇒ 四条老规则一条都不认（这正是 §2.0.63⑤「静态守卫要清点它认哪些字面形状」的复发）。
final RegExp _synoApiRe = RegExp(r'\bSYNO\.[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)*');

/// R4：**厂商推送/服务缩写黑名单**（第 342 轮 D43）。
/// ★ 为什么只放这两个词：`AI` / `PDF` / `URL` / `DSM` 这类缩写用户认识（或本来就该出现），
///   而 `FCM`（Firebase Cloud Messaging）与 `GMS`（Google Mobile Services）
///   是**我们的实现选型**，用户既不认识也无法据此做任何操作（跟 D39/D40「实现说明当文案」同族）。
///   要放行就进白名单，别放宽这条规则。
final RegExp _vendorJargonRe = RegExp(r'\b(?:FCM|GMS)\b');

/// R6：**平台/框架类名黑名单**（第 353 轮 DA8）。
/// ★ 真机逐字：相册休眠备份页把源码注释里的官方事实照搬成了用户文案 ——
///   `Check interval: every 60 min (official PeriodicWorkRequest, flex 10 min); backoff starts at 24h…`。
///   `PeriodicWorkRequest` 是 Android WorkManager 的**类名**，用户既看不懂也无法据此操作
///   （与 R4 的 `FCM/GMS` 同族：**实现选型**不许当文案）。
/// ★ 为什么用黑名单而不是"CamelCase 一律拦"：`SynHub` / `Photo Station` / `Android`
///   这类正常专名都是 CamelCase ⇒ 宽判据会满屏假阳性（r340 已有同类裁定的先例）。
///   要放行某条 `diag` 文案就进白名单，**别放宽这条规则**。
final RegExp _platformJargonRe = RegExp(
  r'\b(?:WorkManager|PeriodicWorkRequest|OneTimeWorkRequest|LiveData|ViewModel|'
  r'JobScheduler|JobIntentService|ForegroundService|ImageReader|SurfaceProducer|'
  r'TextureView|ExoPlayer|MediaCodec|BroadcastReceiver|ContentProvider)\b',
);

/// R7：**把"别的 App"当主语/指引对象**（第 353 轮 DA9）。
/// ★ 真机逐字：`Keep Synology Drive in the foreground to continue.` /
///   `Synology Drive will run tasks while the screen is dimmed.` —— 这几条是从**官方
///   Synology Drive App 的资源逐字照抄**的，而官方那几句里的 "Synology Drive" 是**自指**；
///   移植进 SynHub（本机**没装**那个 App）后，"让 Synology Drive 留在前台"用户**照做不了**。
///   ⇒ §3「照抄官方 ≠ 照抄它的错」。
/// ★ 判据收窄到**"别家 App 名 + 前台/屏幕变暗"同句**：仓库里有 30+ 条合法提到
///   `Synology Photos`/`Synology Drive` 的文案（NAS 套件名、落点名），宽判据会把它们全判红
///   （实测：只写 App 名 = 34 条命中，加上"前台/变暗"上下文 = **恰好这 2 条**）。
final RegExp _selfRefOtherAppRe = RegExp(
  r'Synology\s+(?:Drive|Photos|Chat|Note\s*Station|Calendar)'
  r'[^。.]{0,60}(?:foreground|前台|屏幕变暗|screen is dimmed)',
);

/// R8：**开发侧用语 / 开发进度用语**（第 378 轮：DA7 同族清扫）。
/// ★ 为什么要单开一条：R1–R7 认的是"接口名/类名/别家 App"这些**形状**，
///   而下面这批泄漏**形状上完全正常** —— 是**开发者的口吻**混进了用户文案：
///   `Tap to resend (on a real device this calls resendPost)`（真机逐字前的 ARB 值）、
///   `On-demand download … this repo does not verify it on a device (Kotlin unverified)`、
///   `This round only checks differences …`、`有 NNAPI（可用性未验证）`。
///   ⇒ 用户看到"真机/本仓库/本轮/未验证/Kotlin"**既看不懂也无法据此操作**，
///     而"本轮/未验证"还是**会过期的进度话**（下一轮就变成假话）。
/// ★ 判据只收这几类**无歧义**的开发用语；`尚未实现`/`不支持` 这类**对用户有意义**
///   的能力说明**故意不拦**（否则 `capReasonNotImplemented` 这类诚实文案会满屏假阳性）。
///   要放行就进白名单，别放宽这条规则。
final RegExp _devNoteRe = RegExp(
  r'real device|this repo|this round|unverified|native side|'
  r'真机|本仓库|本轮|未验证|未经验证|未取证|原生侧|Kotlin',
  caseSensitive: false,
);

/// 命中细节（供失败信息直接指出是哪条规则、哪个片段）。
class TechnicalHit {
  const TechnicalHit(this.rules, this.samples);

  final List<String> rules;
  final List<String> samples;

  @override
  String toString() => '${rules.join('+')} $samples';
}

TechnicalHit? technicalHitsIn(String value) {
  // URL 里的 `/` 与路径不算技术字样（否则 `https://…` 与 `/home/Drive` 全中）。
  final v = value.contains('://') ? value.replaceAll(RegExp(r'https?://\S+'), '') : value;
  final rules = <String>[];
  final samples = <String>[];
  for (final entry in <String, RegExp>{
    'R1反引号': _backtickRe,
    'R2接口路径': _apiPathRe,
    'R3字段名': _snakeRe,
    'R4厂商缩写': _vendorJargonRe,
    'R5接口全名': _synoApiRe,
    'R6平台类名': _platformJargonRe,
    'R7别家App当指引': _selfRefOtherAppRe,
    'R8开发侧用语': _devNoteRe,
  }.entries) {
    final m = entry.value.allMatches(v).map((e) => e.group(0)!).toList();
    if (m.isNotEmpty) {
      rules.add(entry.key);
      samples.addAll(m.take(2));
    }
  }
  if (rules.isEmpty) return null;
  return TechnicalHit(rules, samples);
}

/// 白名单条目：`key<TAB>类别<TAB>渲染点`；`#` 开头是注释。
class AllowEntry {
  const AllowEntry(this.key, this.category, this.note);

  final String key;
  final String category;
  final String note;
}

List<AllowEntry> parseAllowlist(String text) {
  final out = <AllowEntry>[];
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split('\t').map((e) => e.trim()).toList();
    if (parts.length < 3) continue;
    out.add(AllowEntry(parts[0], parts[1], parts[2]));
  }
  return out;
}

/// 扫一个 ARB：返回 `key -> 命中`（跳过 `@key` 元数据）。
Map<String, TechnicalHit> scanArb(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final out = <String, TechnicalHit>{};
  json.forEach((k, v) {
    if (k.startsWith('@') || v is! String) return;
    final hit = technicalHitsIn(v);
    if (hit != null) out[k] = hit;
  });
  return out;
}

/// 第 342 轮（D43）已去掉 `FCM`/`GMS` 厂商缩写、必须一直保持干净的 key。
/// ★ 这 3 个 key 都**同时**有 ARB 与 `oem_guidance.dart` 里的中文回退字面量，
///   两处必须一起改（D40 的教训）—— 这里钉 ARB，回退字面量由下面那条「回退字面量同步」用例钉。
const List<String> _fixedInR342 = <String>[
  'oemKeepaliveIntro',
  'oemKeepaliveNoFcm',
  'oemNoteHuawei',
];

/// 第 340 轮已改成**用户文案**、因此必须一直保持干净的 key。
/// 它们一旦重新出现技术字样，或被人塞进白名单，下面两条用例都会红。
const List<String> _fixedInR340 = <String>[
  'e2eeSyncMembers',
  'e2eeSyncMembersHint',
  'chatArchiveEmpty',
  'driveGapNewTextFileHint',
  'driveGapNewOfficeDocHint',
  'driveGapNewOfficeSheetHint',
  'driveGapNewOfficeSlidesHint',
  'driveGapNewFromTemplateHint',
  'fileNewFolderHint',
];

/// 第 353 轮（DA8/DA9）已改成**用户文案**、因此必须一直保持干净的 key。
/// ★ 这几条都有 ARB + Dart 兜底字面量**两份生产者**（§2.0.26）：改一处不算改完。
const List<String> _fixedInR353 = <String>[
  'sleepBackupScheduleLine',
  'sleepBackupGuideRunning',
  'sleepBackupGuideForeground',
  'sleepBackupNotificationTitle',
  'sleepBackupWorkerTitle',
];

void main() {
  const allowPath = 'tool/i18n_technical_copy.txt';
  const arbs = <String>['lib/l10n/app_zh.arb', 'lib/l10n/app_en.arb'];

  test('白名单文件可解析（防空转：条目数 > 0）', () {
    final entries = parseAllowlist(File(allowPath).readAsStringSync());
    // "解析出 0 条"不是成功，是**没校验**（§1.3.0.1）。
    expect(entries.length, greaterThan(0));
    for (final e in entries) {
      expect(e.category, anyOf('diag', 'md', 'todo'), reason: '${e.key} 类别非法');
      expect(e.note, isNotEmpty, reason: '${e.key} 缺渲染点/理由');
    }
  });

  for (final arb in arbs) {
    /// ★ 正向：命中却不在白名单 ⇒ 新增泄漏。
    test('$arb：技术字样必须已在白名单里（禁止新增泄漏）', () {
      final allowed = parseAllowlist(File(allowPath).readAsStringSync())
          .map((e) => e.key)
          .toSet();
      final hits = scanArb(arb);
      final unlisted = hits.keys.where((k) => !allowed.contains(k)).toList()
        ..sort();
      expect(
        unlisted,
        isEmpty,
        reason:
            '这些 key 的值里有"接口名/字段名/反引号"，但没登记进 $allowPath：\n'
            '${unlisted.map((k) => '  $k -> ${hits[k]}').join('\n')}\n'
            '把它改成用户文案（首选），或按 diag/md/todo 登记并写清渲染点。',
      );
    });
  }

  test('白名单不许有陈旧条目（已不再命中 ⇒ 必须删掉）', () {
    final entries = parseAllowlist(File(allowPath).readAsStringSync());
    final present = <String>{};
    for (final arb in arbs) {
      present.addAll(scanArb(arb).keys);
    }
    final stale = entries
        .map((e) => e.key)
        .where((k) => !present.contains(k))
        .toList()
      ..sort();
    expect(
      stale,
      isEmpty,
      reason: '这些 key 已不再带技术字样，却还留在白名单里（会让守卫悄悄失效）：\n'
          '${stale.map((k) => '  $k').join('\n')}',
    );
  });

  test('R4（厂商缩写）判据有效：抓到 FCM/GMS，放过 AI/PDF/DSM', () {
    expect(technicalHitsIn('我们没有 FCM 这条通道')!.rules, contains('R4厂商缩写'));
    expect(technicalHitsIn('没装 GMS 不影响')!.rules, contains('R4厂商缩写'));
    // 反向：用户认识的缩写与我们的产品名不许误报
    expect(technicalHitsIn('AI 美化已关闭'), isNull);
    expect(technicalHitsIn('导出 PDF'), isNull);
    expect(technicalHitsIn('Synology Drive'), isNull);
  });

  test('D43 的 3 个 key：Dart 回退字面量不许再出现 FCM/GMS（注释不算）', () {
    // ★ 只扫**字符串字面量**：`oem_guidance.dart` 顶部的实现说明注释里
    //   「本 App 故意不用 FCM」是**该留的**（§2.0.48：静态守卫要清点它认哪些字面形状，
    //   别把注释数进去；`datetime_render_guard_test.dart` 同款处理）。
    final raw = File('lib/src/core/device/oem_guidance.dart').readAsStringSync();
    final code = raw
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(code.contains('FCM'), isFalse, reason: '回退字面量又带上 FCM');
    expect(code.contains('GMS'), isFalse, reason: '回退字面量又带上 GMS');
    // 自证：把注释去掉后仍能扫到**别人**的 FCM（证明"剥离注释"没把整文件剥空）
    expect(raw.contains('FCM'), isTrue, reason: '注释里的 FCM 说明不该被删（否则这条断言退化）');
  });

  test('第 340/342 轮改过的 key 必须干净且不许进白名单', () {
    final allowed = parseAllowlist(File(allowPath).readAsStringSync())
        .map((e) => e.key)
        .toSet();
    for (final key in <String>[..._fixedInR340, ..._fixedInR342, ..._fixedInR353]) {
      expect(allowed.contains(key), isFalse, reason: '$key 不许再登记进白名单');
      for (final arb in arbs) {
        final json =
            jsonDecode(File(arb).readAsStringSync()) as Map<String, dynamic>;
        final value = json[key];
        expect(value, isA<String>(), reason: '$arb 里没有 $key');
        expect(
          technicalHitsIn(value as String),
          isNull,
          reason: '$arb 的 $key 又带回技术字样：$value',
        );
      }
    }
  });

  /// ★★ r348 D60：**UI 层的 Dart 兜底字面量**是 ARB 之外的另一条旁路。
  ///   现象（真机像素 + 源码逐字）：`Universal Search · SYNO.Finder` 是**硬编码英文**，
  ///   三条老守卫全都看不见它 —— ARB 守卫只扫 ARB；`i18n_hardcoded_cjk_test` 只认中文；
  ///   `i18n_source_scan_test` 不查技术字样。
  ///   判据（只钉 `lib/src/features/**`，实测**零误报**）：
  ///     ① 中文字面量里夹内部标识符（中文句子 + R1–R5 命中）；
  ///     ② 英文散文（含空格）里夹 `SYNO.`（`'SYNO.Chat.Post'` 这种**纯标识符**不算）。
  test('UI 层 Dart 兜底字面量：不许把内部接口名夹进用户句子（r348 D60）', () {
    final cjk = RegExp(r'[\u4e00-\u9fff]');
    final lit = RegExp(r"'([^'\\\n]{3,300})'");
    // 已登记的 `diag`/`md` 文案：按**值**放行（`{op}` 这类占位符当通配）。
    // ★ 只按文件放行会把 `note_editor_page.dart`（既有 md 登记）整文件豁免 ——
    //   而 D60 那条泄漏恰好就在这个文件里，所以必须按**值**匹配，不能按文件。
    final allowedValue = <RegExp>[
      for (final key in parseAllowlist(File(allowPath).readAsStringSync()))
        for (final arb in arbs)
          if ((jsonDecode(File(arb).readAsStringSync())
                      as Map<String, dynamic>)[key.key]
                  is String)
            RegExp(
              '^${RegExp.escape(
                    (jsonDecode(File(arb).readAsStringSync())
                            as Map<String, dynamic>)[key.key] as String,
                  ).replaceAll(RegExp(r'\\\{[a-zA-Z_]+\\\}'), '.*')}\$',
            ),
    ];
    bool listed(String v) => allowedValue.any((r) => r.hasMatch(v));
    final hits = <String>[];
    for (final e in Directory('lib/src/features').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final lines = e.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        // 剥注释行：注释里**会**写旧写法（§2.0.63⑤）。
        if (lines[i].trimLeft().startsWith('//')) continue;
        for (final m in lit.allMatches(lines[i])) {
          final v = m.group(1)!;
          // ★ 只钉**接口名这一类**：句子里出现「斜杠方法路径」或「接口全名 `SYNO.`」。
          //   为什么不直接复用 `technicalHitsIn`（R1–R5）：那会把**开发者诊断**算进来 ——
          //   `'[enter] 还没有 conn_id…'`、office 的 `'…page_decorate 节点…'`、
          //   ``'…`{op}`…'`` —— 它们都没有 `/`、也不含 `SYNO.`，是另一档。
          //   反过来，`Event/list_color`（无点前缀）只被 R3 抓到，所以判据是
          //   "**R1–R5 任一命中** 且 **句子里真有方法路径/接口全名**"，两头都要。
          if (technicalHitsIn(v) == null) continue;
          // 方法路径形状：`Event/list_color` / `Cal.Timezone/list` / `Files/create`
          // —— 左边以**大写字母**开头、右边小写。这样 `26/26`（比例）、
          // `num-show/place-show`（全小写）、`cover/even`（全小写）都不算。
          if (!_methodPathRe.hasMatch(v) && !v.contains('SYNO.')) continue;
          if (listed(v)) continue;
          if (cjk.hasMatch(v) || (v.contains('SYNO.') && v.contains(' '))) {
            hits.add('${e.path}:${i + 1}  $v');
          }
        }
      }
    }
    expect(
      hits,
      isEmpty,
      reason: '这些**用户句子**里夹着内部接口名/标识符：\n${hits.join('\n')}\n'
          '改成用户能懂的话（别把 `SYNO.Xxx` / `Api.Method` 印给用户）。',
    );
    // 自证：判据不是"永远为空"（§1.3.0.1）。
    expect(
      technicalHitsIn('这台 NAS 没有返回时区表（Cal.Timezone/list）。'),
      isNotNull,
    );
    expect(
      technicalHitsIn('Universal Search · SYNO.Finder'),
      isNotNull,
      reason: 'R5 必须抓到裸接口全名',
    );
  });

  test('R6（平台类名）判据有效：抓 PeriodicWorkRequest，放过专名与套件名', () {
    expect(
      technicalHitsIn(
        'Check interval: every 60 min (official PeriodicWorkRequest, flex 10 min)',
      )!.rules,
      contains('R6平台类名'),
    );
    expect(
      technicalHitsIn('退避由 WorkManager 的 LiveData 驱动')!.rules,
      contains('R6平台类名'),
    );
    // 反向：正常专名/套件名/平台名不许误报
    expect(technicalHitsIn('SynHub 已连接'), isNull);
    expect(technicalHitsIn('Synology Drive 已连接'), isNull);
    expect(technicalHitsIn('这个平台用内置摘要（端侧模型只支持 Android/iOS）'), isNull);
    expect(technicalHitsIn('Synology Photos 的「共享空间」权限由管理员分配'), isNull);
  });

  test('R8（开发侧用语）判据有效：抓本轮真机/仓库原文，放过"尚未支持"这类用户话', () {
    // 本轮**真机/ARB 逐字**抓到的六条（修前原文），一条都不许放过。
    for (final leaked in <String>[
      'Tap to resend (on a real device this calls resendPost)',
      '点击即重发（真机上会直接调 resendPost）',
      'On-demand download is implemented by the native DocumentsProvider; '
          'this repo does not verify it on a device (Kotlin unverified on device).',
      '按需下载由原生 DocumentsProvider 实现，本仓库不做真机验证（Kotlin 真机未验）。',
      'This round only checks differences; file transfer and persistent '
          'background sync are not implemented yet',
      '有 NNAPI（可用性未验证）',
      'Write permission unverified: opened read-only.',
      '这本 LIT …本仓库尚未自研完成',
    ]) {
      expect(
        technicalHitsIn(leaked)?.rules,
        contains('R8开发侧用语'),
        reason: '这条是真机抓到的泄漏，必须判红：$leaked',
      );
    }
    // 反向：说明"能不能用"的用户话**不许**误杀（否则守卫会满屏假阳性）。
    for (final ok in <String>[
      '此平台尚未实现',
      'WebDAV 目前为只读：可以浏览目录、下载文件；上传、新建文件夹、删除、改名暂不支持。',
      '无法确认这个文件的写权限，已按只读方式打开。',
      '这本 LIT 受 DRM3 保护，正文经过 DES+LZX 加密变换，本应用暂不支持打开',
      '在本机相册里选择照片',
    ]) {
      expect(
        technicalHitsIn(ok),
        isNull,
        reason: '这是合法的用户文案，不许误杀：$ok',
      );
    }
  });

  test('R7（别家 App 当指引）判据有效：抓 DA9 原文，放过套件名与落点名', () {
    expect(
      technicalHitsIn('Keep Synology Drive in the foreground to continue.')!.rules,
      contains('R7别家App当指引'),
    );
    expect(
      technicalHitsIn('Synology Drive will run tasks while the screen is dimmed.')!
          .rules,
      contains('R7别家App当指引'),
    );
    expect(
      technicalHitsIn('请让 Synology Drive 保留在前台以继续此流程。')!.rules,
      contains('R7别家App当指引'),
    );
    // 反向：只是**提到**套件名不算（这是合法文案，别误杀）
    expect(technicalHitsIn('Synology Drive upload/download/transfer tasks show up here.'), isNull);
    expect(technicalHitsIn('这台 NAS 没有安装 Synology Chat'), isNull);
    expect(technicalHitsIn('Back up into the Phone Backup album in Synology Photos'), isNull);
    expect(technicalHitsIn('Synology Drive - Offline files'), isNull);
  });

  test('判据本身有效（反向：故意构造的样本必须被抓到）', () {
    // 没有这条，"0 条命中"可能只是正则写错了（§1.3.0.1）。
    expect(technicalHitsIn('Channel/list 不带 broken_users，这里问 Channel.Member/get'),
        isNotNull);
    expect(technicalHitsIn('Synology Drive · `Files/create`（type=file）'), isNotNull);
    expect(technicalHitsIn('服务端未开启下载（settings.enable_download=false）'), isNotNull);
    // 反向的反向：正常中英文的 `A/B` 搭配不许被判红。
    expect(technicalHitsIn('上传/下载'), isNull);
    expect(technicalHitsIn('最大下载速度（KB/s）'), isNull);
    expect(technicalHitsIn('这个平台用内置摘要（端侧模型只支持 Android/iOS）'), isNull);
    expect(technicalHitsIn('访客登录需先在 NAS 上开启访客访问'), isNull);
    // R5 反向：用户认识的缩写不算（`DSM` 不是接口全名）。
    expect(technicalHitsIn('这个平台用 DS file 打开'), isNull);
    expect(technicalHitsIn('Synology Drive 已连接'), isNull);
  });
}
