// 加密 Office 文档的"打开前探测"（P0-11）。
//
// 官方行为原文：
//   * 探测接口 `SYNO.Office.Node.Encrypt:check` v1，参数 `path`(`id:<file_id>`) +
//     `password`（APK `ApiSynoOfficeNodeEncrypt.java`；SPK
//     `/tmp/spk/out/Office.apis.txt:56` `v1: check`）。
//   * 判定靠**错误码 57373**（APK
//     `SynologyDriveExceptionInterpreter.isNeedPasswordException`，`:248-250`）。
//   * ★★ **第 65 轮订正**：这里原先写着"本 App 拿不到能用于解密的凭据通道
//     → 只如实提示，不假装支持"。**那句话是错的**，是我早期未验证的假设。
//     官方 `ApiSynoOfficeSnapshot.setAsGet(linkId, password)` 就是**收密码**的
//     （`:53-64`，**总是** `putParam("password", …)`），
//     服务端 `.lib` 里 `Snapshot` 的 `get` 在 **v1–v4 都有**；
//     配合 `Office.Node.Encrypt:check`（v1）先用密码验一次，
//     再用**同一个密码** `Snapshot/get` 取**已解密**的内容。
//     ⇒ 密码是有用的，只是这条通道以前没有接起来。
//   * 官方 APK 拿到 57373 后弹"输入密码"框再带密码重试
//     （`ShowSynoDocumentFragment.java:1756-1789`），
//     文案 `msg_cannot_open_encrypted_office`。本轮照这个流程实现。
//
// 降级纪律：探测本身失败（102/103 没装 Office、105/160 无权限、网络异常）时
// **fail-open** —— 放行让预览页自己报错，绝不因为探测失败就把文件挡住。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/drive_entry_dto.dart';
import '../../data/office_api.dart' show isOfficeNativeName;
import '../files/drive_providers.dart';
import 'drive_p0_text.dart';

/// 探测 [entry] 是否是"加密的 Office 文档"。
///
/// 返回 `true` 表示**服务端明确说需要密码**（错误码 57373）；其它一切情况
/// （未加密 / 接口不可用 / 无权限 / 网络错）都返回 `false`。
///
/// 只对 **Office 原生文档**（`.odoc/.osheet/.oslides`）探测：官方也是先按
/// 扩展名分流到 Office 编辑器后才做密码校验（`ShowSynoDocumentFragment`），
/// 普通文件根本不会走 `Node.Encrypt`；对它们发探测既是多余请求，也可能因为
/// 服务端对非 Office 节点回其它错误码而误判。
Future<bool> driveIsEncryptedOffice(WidgetRef ref, DriveEntryDto entry) async {
  if (!isOfficeNativeName(entry.name)) return false;
  final drive = ref.read(driveApiProvider);
  if (drive == null) return false;
  try {
    final ok = await drive.officeEncryptCheck(fileId: entry.fileId);
    return !ok;
  } catch (_) {
    // fail-open：探测失败一律当作"未加密"，交给下游正常报错
    return false;
  }
}

/// ★★ 第 65 轮 D58：加密 Office 文档的**密码输入 + 校验**。
///
/// 返回**用户输入并校验通过的密码**；`null` 表示"未加密 / 用户放弃"——
/// 两种情况对调用方的含义相同：**按无密码继续走**（未加密时本来就走得通，
/// 放弃时下游会照旧报错，不会静默出错）。
///
/// ## 流程（照官方 `ShowSynoDocumentFragment`）
/// ★★ 第 315 轮真机缺陷（已修）：**文案曾把"拒绝语"当"提示语"**。
/// 真机取证：加密 `.osheet` 打开时弹出的口令框标题是
/// `Cannot open file`、正文是 `Cannot open the encrypted Synology Office
/// file. Please access this file on the server.` —— **而框里就是输入密码的地方，
/// 输对之后文件真的打开了** ⇒ 这句"无法打开/请去服务器"是**假话**，
/// 且会让用户直接放弃（以为手机上打不开）。
/// 官方原文（`apktool d` 官方 Drive 3.9.0-1113 APK）：
/// * `enter_password_title` = `Enter Password`（zh-rCN `输入密码`）；
/// * `enter_password_desc` = `This file is encrypted. Please enter the password.`
///   （zh-rCN `此文件已加密。请输入密码。`）—— **提示语**；
/// * `error_decrypt_fail` = `The password is incorrect. Please try again.`
///   （zh-rCN `密码错误。请再试一次。`）—— **错密码语**；
/// * `msg_cannot_open_encrypted_office` = `Cannot open encrypted Synology Office
///   files. Please access this file on the server.` —— **拒绝语**，
///   官方在**真的打不开**时用（`ShowFragment.smali:3459-3490` 的
///   `setTitle(enter_password_title)` + `setMessage(enter_password_desc)`，
///   重试时**整句替换**成 `error_decrypt_fail`）。
/// 我们**能**用口令解密打开（真机已验证带内容的加密 `.osheet` 完整渲染），
/// 所以拒绝语**不使用**；三句改回官方提示语/错误语，逐字一致。
///
/// 1. 无密码探测 → 57373 说明需要密码；
/// 2. 弹输入框（`drive-encrypted-password-input`）；
/// 3. `Office.Node.Encrypt/check` 带密码再验一次（**这一步不省**：
///    不验就把密码写进后续请求，用户会在更深的地方收到一个更难懂的错）；
/// 4. 密码对了就把密码**交回调用方**，由它带着密码取内容
///    （`Office.Snapshot/get` 的 `password`）；
/// 5. 错了**留在框里**重试，不是关掉让人从头再来。
///
/// 放弃时**没有任何副作用** —— 本函数只读 + 本地校验，不写任何东西。
Future<String?> drivePromptOfficePassword(
  BuildContext context,
  WidgetRef ref,
  DriveEntryDto entry,
) async {
  final encrypted = await driveIsEncryptedOffice(ref, entry);
  if (!encrypted) return null;
  if (!context.mounted) return null;
  final drive = ref.read(driveApiProvider);
  if (drive == null) return null;

  final controller = TextEditingController();
  var wrong = false;
  var busy = false;
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        key: const Key('drive-encrypted-password-dialog'),
        title: Text(driveP0(DriveP0TextKeys.encryptedTitle, '输入密码')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              driveP0(
                DriveP0TextKeys.encryptedOfficeBody,
                '此文件已加密。请输入密码。',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('drive-encrypted-password-input'),
              controller: controller,
              autofocus: true,
              obscureText: true,
              enabled: !busy,
              onSubmitted: (_) async {},
              decoration: InputDecoration(
                labelText: driveP0(DriveP0TextKeys.passwordLabel, '密码'),
                errorText: wrong
                    ? driveP0(DriveP0TextKeys.passwordWrong, '密码错误。请再试一次。')
                    : null,
                // ★★ 第 315 轮真机缺陷（已修）：官方错密码语是**一整句**
                // `The password is incorrect. Please try again.`，而
                // `InputDecoration.errorText` 默认 `errorMaxLines = 1`
                // ⇒ 真机被截断成 `The password is incorrect. Pleas…`
                // （截图 `r315_copy2.png`）。**官方文案被吃掉一半**，
                // 用户看不到"请再试一次"这句可操作的话。
                // 官方是整句替换正文（`setMessage(error_decrypt_fail)`），
                // 我们保留"正文提示 + 行内错误"的超集，但必须让整句显示出来。
                errorMaxLines: 3,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('drive-encrypted-password-cancel'),
            onPressed: busy ? null : () => Navigator.of(ctx).pop(),
            child: Text(driveP0(DriveP0TextKeys.infoClose, '取消')),
          ),
          FilledButton(
            key: const Key('drive-encrypted-password-submit'),
            onPressed: busy
                ? null
                : () async {
                    final pw = controller.text;
                    setState(() {
                      busy = true;
                      wrong = false;
                    });
                    var ok = false;
                    try {
                      ok = await drive.officeEncryptCheck(
                        fileId: entry.fileId,
                        password: pw,
                      );
                    } catch (_) {
                      ok = false;
                    }
                    if (!ctx.mounted) return;
                    if (ok) {
                      Navigator.of(ctx).pop(pw);
                    } else {
                      setState(() {
                        busy = false;
                        wrong = true;
                      });
                    }
                  },
            child: Text(driveP0(DriveP0TextKeys.passwordSubmit, '打开')),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  return result;
}

/// 兼容旧调用点：加密时弹密码框，**用户放弃**则返回 `true`（= 拦下打开）。
///
/// 返回 `false` 表示"可以继续打开"（未加密，或用户输对了密码 ——
/// 后者调用方仍应自己带密码去取内容；这里只为不破坏既有调用面的语义）。
Future<bool> driveWarnIfEncryptedOffice(
  BuildContext context,
  WidgetRef ref,
  DriveEntryDto entry,
) async {
  final pw = await drivePromptOfficePassword(context, ref, entry);
  // 未加密 ⇒ 放行；输入成功 ⇒ 也放行（内容侧需要用密码）
  // 这里无法区分两者，所以用一个额外探测把语义说清：
  if (pw != null) return false;
  final encrypted = await driveIsEncryptedOffice(ref, entry);
  return encrypted;
}
