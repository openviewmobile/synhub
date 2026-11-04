// Office 只读预览的 provider（batch ③ Office L1）。
//
// 两个动作：
//   * `officeApiProvider` —— 从当前连接装配 `OfficeApi`（套件没装时是 null）；
//   * `officeExtractProvider(linkId)` —— 服务端抽取正文，结果进内存缓存
//     （autoDispose + 无重试：断网就老实报错，别转圈）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/office_api.dart';
import '../../data/dto/office_version_dto.dart';
import '../servers/session_controller.dart';

/// 同 `file_providers`/`drive_providers`：失败就报错，不做指数退避
Duration? _noRetry(int retryCount, Object error) => null;

/// 连接上的 Office 协议层（未连接 / 套件缺失 → null）
final officeApiProvider = Provider<OfficeApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : OfficeApi(conn.api);
});

/// `Office.Info/get`：套件是否可用（给"能不能抽取正文"的判断）
final officeInfoProvider = FutureProvider.autoDispose<OfficeInfo?>((ref) async {
  final api = ref.watch(officeApiProvider);
  if (api == null) return null;
  try {
    return await api.info();
  } catch (_) {
    return null;
  }
}, retry: _noRetry);

/// Office 原生文档的版本列表（`Office.Node.Version/list` v1）。
///
/// 只对 `.odoc/.osheet/.oslides` 有意义（普通文件服务端回 `1000`）。
/// 请求形态只有一种（真机验证可用）：`path=id:<file_id>`。写入批次真机
/// （`docs/live-write-verification.md` §4#12/#13）推翻了"独立应用给 `object_id`"
/// 的旧说法：`Node:list` 根本不存在（`103`），`Node:get {object_id}` → `1000`，
/// 真参数是 `path` —— 所以 `object_id` 已从整条链上删掉。
final officeNodeVersionsProvider = FutureProvider.autoDispose
    .family<List<OfficeVersionDto>, String>((ref, fileId) async {
      final api = ref.watch(officeApiProvider);
      if (api == null) throw StateError('未连接');
      return api.nodeVersions(fileId: fileId);
    }, retry: _noRetry);

/// 服务端抽取的文档正文，按 `permanent_link` 缓存。
///
/// 断网 → 直接抛（页面显示"抽取失败 + 重试"），不做离线缓存：
/// 正文来自服务端转换，本地没有等价物，假装有会是错的。
final officeExtractProvider = FutureProvider.autoDispose.family<String, String>(
  (ref, linkId) async {
    final api = ref.watch(officeApiProvider);
    if (api == null) throw StateError('未连接');
    return api.extract(linkId: linkId);
  },
  retry: _noRetry,
);
