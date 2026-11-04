// MailPlus（Webmail 客户端）模块的依赖注入、状态与动作（阶段二 A 最后一批）。
//
// 分层与其它模块一致：`DsmWebApi → MailPlusApi（协议）→ providers → 页面`。
// 接口层事实来源：`docs/station-surveillance-mailplus-insight-research.md`
// 的实现回填小节（参数逐字对齐包内 `ui/mailclient.js` 的 registry）。
//
// **只做普通用户功能**：`SYNO.MailPlusServer.*`（域/配额/中继/审核/许可）等
// 管理员面不在这里，也不在 UI 里（见 `mailplus.dart` 顶部注释）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/mailplus_dto.dart';
import '../../data/mailplus.dart';
import '../../dsm/webapi.dart';
import '../servers/session_controller.dart';

/// 邮件模块的 API 层。未连接时为 null（页面显示"未连接"而不是崩）。
final mailApiProvider = Provider<MailPlusApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : MailPlusApi(conn.api);
});

/// 邮箱树（`Mailbox.list` v7）。
final mailMailboxesProvider = FutureProvider<List<MailMailboxDto>>((ref) async {
  final api = ref.watch(mailApiProvider);
  if (api == null || !api.installed) return const [];
  return api.listMailboxes();
});

/// 当前选中的邮箱**路径**（`Thread.list` 的 `mailbox` condition 用路径）。
final mailSelectedMailboxProvider =
    NotifierProvider<MailSelectedMailboxNotifier, String?>(
      MailSelectedMailboxNotifier.new,
    );

class MailSelectedMailboxNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? path) => state = path;
}

/// 邮件列表状态（分页 + 失败大类）。
class MailThreadListState {
  const MailThreadListState({
    this.items = const [],
    this.total = 0,
    this.loading = false,
    this.loadingMore = false,
    this.loaded = false,
    this.failure,
    this.errorText,
    this.apiMissing = false,
  });

  final List<MailThreadDto> items;
  final int total;
  final bool loading;
  final bool loadingMore;
  final bool loaded;

  /// 失败大类（套件未安装 / 无权限 / 网络 / 其它）。
  final MailFailureKind? failure;
  final String? errorText;

  /// 还没连接会话（`mailApiProvider == null`）。
  final bool apiMissing;

  bool get hasMore => items.length < total;

  MailThreadListState copyWith({
    List<MailThreadDto>? items,
    int? total,
    bool? loading,
    bool? loadingMore,
    bool? loaded,
    MailFailureKind? failure,
    String? errorText,
    bool? apiMissing,
    bool clearError = false,
  }) => MailThreadListState(
    items: items ?? this.items,
    total: total ?? this.total,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    loaded: loaded ?? this.loaded,
    failure: clearError ? null : (failure ?? this.failure),
    errorText: clearError ? null : (errorText ?? this.errorText),
    apiMissing: apiMissing ?? this.apiMissing,
  );
}

class MailThreadListController extends Notifier<MailThreadListState> {
  @override
  MailThreadListState build() => const MailThreadListState();

  MailPlusApi? get _api => ref.read(mailApiProvider);

  String? get _mailbox => ref.read(mailSelectedMailboxProvider);

  /// 拉第一页。[silent] 为 true 时不清空旧数据（下拉刷新）。
  Future<void> load({bool silent = false}) async {
    final api = _api;
    if (api == null) {
      state = state.copyWith(
        loading: false,
        apiMissing: true,
        clearError: true,
      );
      return;
    }
    // 能力表已 discover 且里面没有这个 API → 套件未安装，直接给结论。
    if (!api.installed) {
      state = state.copyWith(
        loading: false,
        loaded: true,
        items: const [],
        failure: MailFailureKind.notInstalled,
        errorText: describeMailError(
          DsmApiException(DsmErrorCode.apiNotFound, method: 'MailClient.Info'),
        ),
      );
      return;
    }
    state = state.copyWith(
      loading: true,
      apiMissing: false,
      items: silent ? null : const [],
      clearError: true,
    );
    try {
      final page = await api.listThreads(
        mailboxPath: _mailbox,
        offset: 0,
        limit: MailPlusApi.pageSize,
      );
      state = state.copyWith(
        loading: false,
        loaded: true,
        items: page.items,
        total: page.total,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        loaded: true,
        failure: mailFailureKind(e),
        errorText: describeMailError(e),
      );
    }
  }

  /// 触底加载下一页。
  Future<void> loadMore() async {
    final api = _api;
    if (api == null || state.loadingMore || state.loading) return;
    if (!state.hasMore) return;
    state = state.copyWith(loadingMore: true);
    try {
      final page = await api.listThreads(
        mailboxPath: _mailbox,
        offset: state.items.length,
        limit: MailPlusApi.pageSize,
      );
      state = state.copyWith(
        loadingMore: false,
        items: [...state.items, ...page.items],
        total: page.total,
      );
    } catch (e) {
      state = state.copyWith(
        loadingMore: false,
        failure: mailFailureKind(e),
        errorText: describeMailError(e),
      );
    }
  }

  Future<void> refresh() => load(silent: true);
}

final mailThreadListProvider =
    NotifierProvider<MailThreadListController, MailThreadListState>(
      MailThreadListController.new,
    );

/// 单个会话（`Thread.get` v11）——详情页用。
final mailThreadProvider = FutureProvider.family<MailThreadDto?, String>((
  ref,
  id,
) async {
  final api = ref.watch(mailApiProvider);
  if (api == null || !api.installed) return null;
  return api.getThread(id);
});

/// 单封邮件（`Message.get` v10）。
final mailMessageProvider = FutureProvider.family<MailMessageDto?, String>((
  ref,
  id,
) async {
  final api = ref.watch(mailApiProvider);
  if (api == null || !api.installed) return null;
  return api.getMessage(id);
});

/// 写操作（已读/星标/移动/发信）。
class MailActions {
  const MailActions(this.api);

  final MailPlusApi? api;

  MailPlusApi get _a {
    final a = api;
    if (a == null) throw StateError('未连接');
    return a;
  }

  Future<void> setRead(String id, {required bool read}) =>
      _a.setRead(id, read: read);

  Future<void> setStar(String id, {required bool star}) =>
      _a.setStar(id, star: star);

  Future<void> move(String id, String mailboxId) =>
      _a.setMailbox(id, mailboxId);

  /// 发信 = `Draft.create` v7 再 `Draft.send` v7（官方同一流程）。
  Future<void> send({
    List<String> to = const [],
    List<String> cc = const [],
    String subject = '',
    String body = '',
  }) async {
    final id = await _a.createDraft(
      to: to,
      cc: cc,
      subject: subject,
      body: body,
    );
    if (id.isEmpty) throw StateError('草稿创建失败（回包里没有 id）');
    await _a.sendDraft(id);
  }
}

final mailActionsProvider = Provider<MailActions>(
  (ref) => MailActions(ref.watch(mailApiProvider)),
);
