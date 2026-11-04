// 连接方式（`ResolvedEndpoint.source`）→ **用户词汇**。
//
// ★★ r343 D54：真机 `设置 → 关于` 逐字 `https://nas.example.com:5001（direct）`
//   —— `source` 是内部 token（`direct`/`lan`/`ddns`/`external`/`fqdn`/`smartdns`），
//   而它被直接印成了用户文案（D47「运行时值当文案」同族：静态守卫看不见）。
//
// 判据（§2.0.26「钉生产者」）：token 的**全部生产者**在
//   `features/servers/connection_service.dart`（`direct`）与
//   `quickconnect/{address_selector,serv_api}.dart`（`lan`/`ddns`/`external`/`fqdn`/`smartdns`），
//   守卫 `test/server_source_label_test.dart` 拿这三个文件**扫出 token 清单**再逐条断言。
//
// ★ 与 `objectTypeLabel`（D47）同一套写法：能查表就查表，查不到给**用户能懂的兜底**，
//   **永不**把 token 原样返回。原始 token 仍在诊断/日志里（登录页 HUD 的 `SOURCE xxx` 就是
//   仪器风格，**不改**——同 §7.7.1 的裁决）。
import 'package:synhub/src/core/i18n/l10n.dart';

/// token → 用户文案。新增 token 必须在 [kServerSourceTokens] 里登记（守卫会查）。
String connectSourceLabel(String source, AppText t) {
  final s = source.trim().toLowerCase();
  switch (s) {
    case 'direct':
      return t.setSrcDirect;
    case 'lan':
      return t.setSrcLan;
    case 'ddns':
      return t.setSrcDdns;
    case 'external':
      return t.setSrcExternal;
    case 'fqdn':
      return t.setSrcFqdn;
    case 'smartdns':
      return t.setSrcSmartDns;
    case 'relay':
      return t.setSrcRelay;
    default:
      // ★ 兜底是「其它方式」而不是原样 token，也不是「未知」——
      //   「未知」= 真不知道；「其它方式」= 知道有这么个方式但我方还没命名（两句话）。
      return s.isEmpty ? t.setSrcUnknown : t.setSrcOther;
  }
}

/// 已知 token（守卫的非空判据；改这里必须同步 [connectSourceLabel]）。
const List<String> kServerSourceTokens = <String>[
  'direct',
  'lan',
  'ddns',
  'external',
  'fqdn',
  'smartdns',
  'relay',
];
