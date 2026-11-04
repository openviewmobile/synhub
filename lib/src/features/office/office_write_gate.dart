// Office C′ 编辑器 UI 批 1 —— **写权限门控**（纯逻辑，可离线单测）。
//
// 本文件**不含**任何 UI，只把"能不能显示编辑入口"的判定收在一处，供页面与
// 单测共用。门控条件来自已取证事实，不是猜的：
//
//   * `(canWrite || canComment) && schema_mobile >= 2000`
//     —— `docs/office-web-editor-research.md` §5.1（APK
//     `BaseViewerDialogFragment.supportEditor`）＋ §8.1 第 5 条（门禁判断）；
//     `schema_mobile` 由 `SYNO.Office.Info:get` 给，真机 `2003`
//     （`docs/live-office-write-probe.md` §2 原文）。
//   * `canWrite`/`canComment` 取自 `SYNO.Office.Permission:check v1`
//     回包的 `writable`/`commentable`（`docs/office-collab-protocol-spike.md`
//     §2.5 真机探针原文；普通用户可调，同 §5.2）。
//
// 降级纪律（用户明令：门控不许删、不许绕过；与既有
// `lib/src/features/drive/drive_p0_text.dart` 的 DriveEntryGate 同口径）：
//
//   * `105` / `160`（无权限 / 无应用特权）→ **隐藏编辑入口** + 明确原因；
//   * `119` / `106`（会话不存在 / 超时）  → **保留入口**，只提示重新登录
//     （绝不因为会话过期就把整个模块藏起来）；
//   * 其它（网络错 / 认不出的码 / 能力位缺失）→ **fail-open**：保守显示入口，
//     但 `editable=false`，让页面把"门控未能确认"如实说明。
//
// 本批**不做编辑交互**：门控只决定"编辑入口是否显示 + 是否可进入"，
// 真正的编辑在下一批。因此这里没有也不该有"写"的任何动作。
import '../../core/i18n/data_text.dart';
import '../../dsm/webapi.dart';

/// 取本批新文案（key + 中文原文；清单见 `docs/office-editor-ui-1.md`）。
String officeDocText(String key, String zh) => dataText(key, zh);

/// 带 `{name}` / `{value}` 等占位符的文案填充。
String officeDocFill(String key, String zh, Map<String, String> values) {
  var out = officeDocText(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 服务端移动端 schema 从哪个版本开始支持 doc/sheet 编辑器。
///
/// `docs/office-web-editor-research.md` §5.1：APK `OfficeManager.java:75-76`
/// `MOBILE_SCHEMA_VERSION__SUPPORT_SHEET_DOC_EDITOR = 2000`。
const int kOfficeEditorMinSchemaMobile = 2000;

/// 门控输入：三条已取证事实 + 读取它们时看到的错误码（可空）。
class OfficeWriteGateInputs {
  const OfficeWriteGateInputs({
    required this.canWrite,
    required this.canComment,
    required this.schemaMobile,
    this.loadError,
    this.idsUnresolved = false,
    this.contentMissing = false,
  });

  /// `Permission:check` 的 `writable`。
  final bool canWrite;

  /// `Permission:check` 的 `commentable`。
  final bool canComment;

  /// `Office.Info:get` 的 `schema_mobile`（真机 2003）。
  final int schemaMobile;

  /// 读取门控输入时的错误码（`DsmApiException.code` / DSM 码）；null = 读到。
  final int? loadError;

  /// ★★ 第 311 轮：**我们根本没问到权限** —— `object_id` / `link_id` 没解析出来。
  ///
  /// 真机缺陷（LGE-AN10，新建 `.odoc` 后立刻打开 ×2 次）：`loadGate()` 里
  /// `_resolveObjectId()` / `_resolveLinkId()` 拿不到 id 时会**跳过** `Permission:check`，
  /// 于是 `canWrite=false, canComment=false, loadError=null` ⇒ 被判成
  /// [OfficeWriteGateState.hiddenNoPermission]，界面上写"这个账号对该文件没有写入或
  /// 评论权限"——**这是假话**（我们一次都没问服务端），而且**没有重试入口**。
  /// 用户主诉路径"新建 → 立刻打开"正好落在这条上。
  final bool idsUnresolved;

  /// ★★ 第 312 轮：`Snapshot:get` 取不到内容（这个文件**还没有** Office 内容）。
  ///
  /// 真机证据（同一文件、同一账号、中间没有任何权限变更）：
  /// * 新建后**立刻**打开 → `Permission:check` 回
  ///   `readable=false writable=false commentable=false`；
  /// * 4 分钟后打开 → 回 `readable=true writable=true commentable=true`。
  /// ⇒ "三个 false"在**没有内容**的文件上等于**"Office 对象还没建出来"**，
  /// 不是"这个账号没有权限"：按后者处置会说假话，还会藏掉用户可改的入口。
  final bool contentMissing;

  @override
  String toString() =>
      'OfficeWriteGateInputs(canWrite: $canWrite, canComment: $canComment, '
      'schemaMobile: $schemaMobile, loadError: $loadError, '
      'idsUnresolved: $idsUnresolved, contentMissing: $contentMissing)';
}

/// 门控后的降级状态。
enum OfficeWriteGateState {
  /// `(canWrite||canComment) && schema_mobile>=2000`：入口显示且可进入编辑
  /// （本批只是占位，`editable` 供下一批接线）。
  allowed,

  /// 105 / 160 或权限位为假：**隐藏编辑入口** + 原因。
  hiddenNoPermission,

  /// `schema_mobile < 2000`：服务端不支持移动端编辑器 → **隐藏编辑入口** + 原因。
  hiddenSchemaTooOld,

  /// 119 / 106：**保留入口**，只提示重新登录。
  reloginOnly,

  /// 认不出的失败 / 能力位缺失：fail-open（保守显示入口），如实标注未确认。
  unknownFailOpen,

  /// ★★ 第 311 轮：`object_id` / `link_id` **还没解析出来**（不是"没权限"）。
  ///
  /// 隐藏编辑入口（连 id 都没有，协作会话一定建不起来 —— 第 310 轮真机
  /// `OfficeCollabPermissionDeniedException` 就是这么来的），但原因必须**如实**
  /// 且必须给**重试**入口（§2.0.8 ②：错误态不许吞掉用户可改的入口）。
  unresolvedIds,

  /// ★★ 第 312 轮：`Permission:check` 三个位全 false，但该文件**还没有 Office 内容**
  /// ⇒ 判定为"Office 对象尚未就绪"（服务端要一点时间），**不是**"没有权限"。
  ///
  /// 与 [unresolvedIds] 同样是"还没问到真话"：隐藏编辑入口（此刻握手必然被拒），
  /// 但必须给**重试**入口。
  notProvisioned,
}

/// 门控结论。
///
/// [reasonText] 在判定时一次算好（它依赖输入里的 `schemaMobile`，不能后算）。
class OfficeWriteGateDecision {
  const OfficeWriteGateDecision(
    this.state, {
    required this.reasonKey,
    required this.reasonText,
    this.retryable = false,
  });

  final OfficeWriteGateState state;

  /// 原因文案的 key（见 `docs/office-editor-ui-1.md` 的 ARB 清单）。
  final String reasonKey;

  /// 只读页顶部要如实说明的一句原因；`allowed` 时为 null（无需解释）。
  final String? reasonText;

  /// ★★ 第 311 轮：这个只读原因**是我们这边还没问到**（不是服务端拒绝）⇒
  /// 界面必须给"重新检查"入口。
  final bool retryable;

  /// 编辑入口是否**显示**。
  ///
  /// 只有"明确无权限"与"schema 太旧"两种情况隐藏；会话过期要保留入口；
  /// 认不出的失败 fail-open 也要显示。
  bool get showEditorEntry =>
      state != OfficeWriteGateState.hiddenNoPermission &&
      state != OfficeWriteGateState.hiddenSchemaTooOld &&
      // ★★ 第 311 轮：`object_id`/`link_id` 都没解析出来时，编辑入口一定打不开
      // （协作会话的握手就要这两个 id）——藏掉入口，但横幅必须给"重新检查"。
      state != OfficeWriteGateState.unresolvedIds &&
      // ★★ 第 312 轮：Office 对象还没就绪时同样进不了协作会话。
      state != OfficeWriteGateState.notProvisioned;

  /// 本批恒为只读：只有 [OfficeWriteGateState.allowed] 才是"下一批可编辑"。
  bool get editable => state == OfficeWriteGateState.allowed;

  @override
  String toString() => 'OfficeWriteGateDecision(${state.name}, $reasonKey)';
}

/// 由已取证输入判定门控状态。**纯函数**，无副作用、无 IO。
OfficeWriteGateDecision decideOfficeWriteGate(OfficeWriteGateInputs inputs) {
  final error = inputs.loadError;
  if (error != null) {
    switch (error) {
      // 明确的"没权限"：隐藏入口。
      case DsmErrorCode.noPermission:
      case DsmErrorCode.noAppPrivilege:
        return OfficeWriteGateDecision(
          OfficeWriteGateState.hiddenNoPermission,
          reasonKey: 'officeDocGateNoPermission',
          reasonText: officeDocText(
            'officeDocGateNoPermission',
            '这个账号对该文件没有写入或评论权限：以只读方式打开。',
          ),
        );
      // 会话态：绝不隐藏入口。
      case DsmErrorCode.sessionTimeout:
      case DsmErrorCode.sidNotFound:
        return OfficeWriteGateDecision(
          OfficeWriteGateState.reloginOnly,
          reasonKey: 'officeDocGateRelogin',
          reasonText: officeDocText(
            'officeDocGateRelogin',
            '登录会话已失效：请重新登录后重试（本次仍以只读方式打开）。',
          ),
        );
    }
    // 认不出的失败 → fail-open（保守显示）。
    return OfficeWriteGateDecision(
      OfficeWriteGateState.unknownFailOpen,
      reasonKey: 'officeDocGateUnverified',
      reasonText: officeDocText(
        'officeDocGateUnverified',
        '无法确认写权限（未认定为无权限）：保守地以只读方式打开。',
      ),
    );
  }
  // ★★ 第 311 轮：先判"我们有没有问到"。id 没解析出来时 `canWrite` 恒为 false，
  // 若按下面那条判，用户会看到一句**假话**（"没有写入权限"）。
  if (inputs.idsUnresolved) {
    return OfficeWriteGateDecision(
      OfficeWriteGateState.unresolvedIds,
      reasonKey: 'officeDocGateUnresolved',
      reasonText: officeDocText(
        'officeDocGateUnresolved',
        '还没能解析到这个文档的 Office 标识（新建后服务端可能尚未就绪）：'
            '本次以只读方式打开，可点"重新检查"再试。',
      ),
      retryable: true,
    );
  }
  // ★★ 第 312 轮：三个权限位全 false **且**这个文件还没有 Office 内容 ⇒
  // 是"对象还没建出来"，不是"没有权限"（真机同一文件 4 分钟后三种位全 true）。
  if (!inputs.canWrite && !inputs.canComment && inputs.contentMissing) {
    return OfficeWriteGateDecision(
      OfficeWriteGateState.notProvisioned,
      reasonKey: 'officeDocGateNotProvisioned',
      reasonText: officeDocText(
        'officeDocGateNotProvisioned',
        '这个文档的 Office 数据还没就绪（刚新建的文件服务端需要一点时间）：'
            '本次以只读方式打开，可点"重新检查"再试。',
      ),
      retryable: true,
    );
  }
  if (!inputs.canWrite && !inputs.canComment) {
    return OfficeWriteGateDecision(
      OfficeWriteGateState.hiddenNoPermission,
      reasonKey: 'officeDocGateNoPermission',
      reasonText: officeDocText(
        'officeDocGateNoPermission',
        '这个账号对该文件没有写入或评论权限：以只读方式打开。',
      ),
    );
  }
  if (inputs.schemaMobile < kOfficeEditorMinSchemaMobile) {
    return OfficeWriteGateDecision(
      OfficeWriteGateState.hiddenSchemaTooOld,
      reasonKey: 'officeDocGateSchemaTooOld',
      reasonText: officeDocFill(
        'officeDocGateSchemaTooOld',
        '服务端 Office 移动端 schema 为 {value}，低于编辑器所需的 '
            '$kOfficeEditorMinSchemaMobile：以只读方式打开。',
        <String, String>{'value': '${inputs.schemaMobile}'},
      ),
    );
  }
  return const OfficeWriteGateDecision(
    OfficeWriteGateState.allowed,
    reasonKey: 'officeDocGateAllowed',
    reasonText: null,
  );
}
