import '../../core/i18n/data_text.dart';
import '../../core/user_facing_error.dart';
import '../../data/office_collab/office_collab_client.dart';

/// 把 Office 相关异常翻译成**用户看得懂的话**。
///
/// ## 为什么必须要有这个函数（真机实测缺陷）
///
/// 2026-09-22 真机验证：打开 Drive 里的 `Dynamic.oslides` 时，页面顶部弹出一条
/// **红色横幅**，原文是：
///
/// ```
/// 协作会话未建立：OfficeCollabPermissionDeniedException: Permission denied:
/// {"message":"Permission denied"} (the handshake objectId must be the Office
/// object_id and linkId the Drive permanent_link)
/// ```
///
/// 三个问题，都是**从用户角度不可接受**的：
/// 1. **内部类名**（`OfficeCollabPermissionDeniedException`）出现在界面上；
/// 2. **原始 JSON 报文**（`{"message":"Permission denied"}`）直接甩给用户；
/// 3. 括号里那句是**给实现者看的注释**（"handshake 的 objectId 必须是 Office 的
///    object_id、linkId 必须是 Drive 的 permanent_link"），对用户零价值。
///
/// 根因是三个 Office 页的 `_describeError` 都有一句兜底 `return '$error'` ——
/// **任何没被显式识别的异常都会被整体 `toString()` 进界面**。
///
/// ## 设计原则
///
/// * **用户语言在前**：先说"对你意味着什么"（只读、不可编辑、会失败）；
/// * **不认识的异常也绝不丢原文**：给一句通用人话，原文只进 `debugPrint`；
/// * **权限类异常单独归类**：它最常见，且语义是"你只是没权限"，不是"出错了"。
String officeUserFacingError(Object error) {
  // 权限不足：协作会话建不起来，但这不是"故障"，用户只是没有编辑权限。
  if (error is OfficeCollabPermissionDeniedException) {
    return dataText('officeCollabErrNoPermission', '该账号对此文件没有编辑权限');
  }
  if (error is OfficeCollabNotReadyException) {
    return dataText('officeCollabErrNotReady', '协作服务尚未就绪');
  }
  if (error is OfficeCollabTimeoutException) {
    return dataText('officeCollabErrTimeout', '协作服务响应超时');
  }
  if (error is OfficeCollabDisconnectedException) {
    return dataText('officeCollabErrDisconnected', '协作服务连接已断开');
  }
  if (error is OfficeCollabException) {
    return dataText('officeCollabErrUnavailable', '协作服务暂时不可用');
  }
  // 其余（DSM 错误码 / 系统异常 / 完全不认识的异常）统一走全仓唯一出口
  // `lib/src/core/user_facing_error.dart`，保证各 feature 的说法一致。
  // DSM 码值仍然保留（用户报障时有用），只是不再由本文件重复实现。
  return userFacingError(error);
}

/// 三个 Office 页的**装载失败**（`Office{Doc,Sheet,Slides}LoadException`）→ 用户语言。
///
/// ## ★★ 第 308 轮：这一条曾经绕过本文件（真机 LGE-AN10 实测）
///
/// 三个页面的 `_describeError` 里写着 `if (error is OfficeXLoadException) return error.message;`
/// —— 而 `message` 是**给实现者看的诊断串**，里面带 section 名（`@C_text/content`）等内部术语，
/// 且**只有中文**。真机在**英文环境**下点开一个刚由本 App 新建的 `.odoc`，界面原文是：
///
/// ```
/// Failed to open
/// Snapshot:get 的内容树与 @C_text/content 形态对不上
/// ```
///
/// ⇒ 与 [officeUserFacingError] 的立文相矛盾（"原文只进 debugPrint"），是本文件之外的第二条出口。
/// 现在三个页面同样走本文件：**用户看到本地化人话，原文只进 [logOfficeErrorForDiagnostics]**。
///
/// 不认识的 `reason` 一律落到全仓唯一兜底（[userFacingError]），**不把 reason 原文顶上去**。
String officeLoadFailureText(String reason) {
  switch (reason) {
    case 'no_link_id':
      return dataText(
        'officeLoadErrNoLinkId',
        '打不开这个文档：服务端没有返回它的永久链接。',
      );
    case 'not_connected':
      return dataText(
        'officeLoadErrNotConnected',
        '打不开这个文档：尚未连接到服务器。',
      );
    case 'bad_content_shape':
    case 'bad_sheet_shape':
      return dataText(
        'officeLoadErrShape',
        '打不开这个文档：服务端返回的内容格式无法识别。可以试试「只读预览」。',
      );
    case 'bad_fetch_ack':
      return dataText(
        'officeLoadErrFetchAck',
        '打不开这个文档：服务端回包不完整。',
      );
    case 'no_object_id':
      return dataText(
        'officeLoadErrNoObjectId',
        '打不开这个文档：缺少文档内部 id。',
      );
    default:
      return userFacingError(StateError(reason));
  }
}

/// ★ 只读闸门已判定"以只读方式打开"时，协作会话的**权限拒绝**不算新故障。
///
/// 缺陷（Linux 走查像素，见 `docs/office-readonly-banner-defect.md`）：同一页面
/// 顶部同时出现两条横幅 ——
///
/// 1. 灰色信息：`No write/comment permission: opened read-only.`
///    （`officeDocGate*` 系列，闸门已表达"只读打开"这一**正常终态**）；
/// 2. 红色错误：`Collaboration session unavailable: …`
///    （由本文件 [officeUserFacingError] 的权限分支渲染）。
///
/// 闸门既然判了"无写权限 / 只读打开"，协作客户端的
/// [OfficeCollabPermissionDeniedException] 就是**该结论的必然推论**，
/// 把它再报成红色 `unavailable` 是对同一事实的第二次、且更悲观的陈述。
///
/// ## 静音边界（★ 只静音这一种组合，绝不放宽真正的故障）
///
/// * [gateAllowsEditing] = 闸门判定**可写**（`OfficeWriteGateState.allowed`）时
///   **不**静音 —— 此时权限拒绝是真故障，必须照常报错；
/// * 只读时，**其它**协作故障（超时 / 未就绪 / 断连 / 协议 / 配置）也**不**静音。
///
/// 因此它不是"无条件静音"，也没有删掉 [officeUserFacingError] 的任何分支。
bool officeSessionNoteRedundant(
  Object error, {
  required bool gateAllowsEditing,
}) {
  if (gateAllowsEditing) return false;
  return error is OfficeCollabPermissionDeniedException;
}

/// 供诊断用：把异常原文打到日志（**不**进界面）。
///
/// 用 [debugPrint] 而不是 `print`，release 构建下由 Flutter 自行裁剪。
void logOfficeErrorForDiagnostics(String where, Object error, [StackTrace? st]) {
  // ignore: avoid_print
  print('[office:$where] $error');
  if (st != null) {
    // ignore: avoid_print
    print('[office:$where] $st');
  }
}
