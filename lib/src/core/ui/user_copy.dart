/// 用户可见文案的**运行时**兜底：内部标识符不许直接画到界面上。
///
/// ## 为什么需要它（第 349 轮真机缺陷 D66）
///
/// 真机 `联系人 → 通讯录与标签` 里，`Team Contacts` 那行的副标题原样是：
///
/// ```
/// 4 位联系人 · 团队/公开 · 共享自 Contacts · 共享给 syno.contacts.internal.everyone
/// ```
///
/// `syno.contacts.internal.everyone` 是**服务端内部群组标识**，不是给人看的名字。
/// 这是 AGENTS §2.0.47「诊断串不许当用户文案」家族的第 8 处 —— 但前七处都是
/// **静态字面量**（ARB / Dart 渲染点），有守卫 `test/i18n_user_facing_copy_test.dart` 拦得住；
/// **这里泄漏的是运行时的服务端值**，静态守卫**看不见** ⇒ 只能在**渲染点**兜。
///
/// ## 判据必须**保守**（宁可漏判，不可误判）
///
/// 真实联系人名里**可以**带点 —— 邮箱 `user@example.com` 就带。
/// 所以不能写成"含点即内部"，只认官方内部命名空间：
///   * `syno.` / `SYNO.` 前缀（`syno.contacts.internal.everyone`、`SYNO.Contacts.Contact`）；
///   * 段里出现 `.internal.`。
/// 这两条对邮箱/人名**不会**误命中。
bool looksLikeInternalIdentifier(String value) {
  final v = value.trim();
  if (v.isEmpty) return false;
  if (v.startsWith('syno.') || v.startsWith('SYNO.')) return true;
  if (v.contains('.internal.')) return true;
  return false;
}
