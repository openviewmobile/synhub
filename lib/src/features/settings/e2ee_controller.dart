// E2EE 的 UI 状态层（Phase 7）。
//
// [E2eeService] 是纯逻辑（身份/密钥/加解密），这里把它挂到 Riverpod 上，
// 负责：启动时载入身份、从频道列表解出频道密钥、给界面提供
// 「这条消息该显示什么」以及设置/解锁/换口令/修复频道的动作。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/archive_dto.dart';
import '../../data/e2ee/e2ee_service.dart';
import '../chat/chat_session_controller.dart';
import '../../core/user_facing_error.dart';

/// 加密频道解不开时界面上显示的占位文案（原 App 是 broken channel 提示）。
///
/// 这里拿不到 widget context（通知栏/后台也会调），统一走 `platformText()`
/// 跟随**平台语言**；`displayMessage` 与老测试取的是同一个来源。
String get kUndecryptableText => platformText().e2eeUndecryptable;

class E2eeState {
  const E2eeState({
    this.ready = false,
    this.configured = false,
    this.unlocked = false,
    this.publicKey = '',
    this.brokenChannels = const [],
    this.busy = false,
    this.error,
  });

  /// 身份是否已经从本地库读出来
  final bool ready;
  final bool configured;
  final bool unlocked;
  final String publicKey;

  /// 服务端有、但本机解不开的加密频道（原 App 的 broken channel）
  final List<int> brokenChannels;
  final bool busy;
  final String? error;

  E2eeState copyWith({
    bool? ready,
    bool? configured,
    bool? unlocked,
    String? publicKey,
    List<int>? brokenChannels,
    bool? busy,
    String? error,
    bool clearError = false,
  }) => E2eeState(
    ready: ready ?? this.ready,
    configured: configured ?? this.configured,
    unlocked: unlocked ?? this.unlocked,
    publicKey: publicKey ?? this.publicKey,
    brokenChannels: brokenChannels ?? this.brokenChannels,
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
  );
}

class E2eeController extends Notifier<E2eeState> {
  E2eeService get _svc => ref.read(e2eeServiceProvider);

  @override
  E2eeState build() {
    // 启动就把本地身份读出来（异步），不阻塞首帧。
    //
    // 注意：这里**不能** `ref.listen(channelsProvider, ...)` —— Riverpod 3 里
    // listen 也是依赖，频道列表一变就会重建本 Notifier，而旧 build 里那个
    // 还没跑完的 `load()` 会拿着已 dispose 的 ref 继续跑，直接抛
    // "Cannot use the Ref ... after it has been disposed"（真踩过）。
    // 频道密钥改成按需同步补（见 `_ensureKey`），不依赖监听。
    Future.microtask(() {
      // 建完就被 dispose（例如只是 read 一下、没有监听者）时别去碰 ref
      if (ref.mounted) load();
    });
    return const E2eeState();
  }

  /// 新设备接入：本地没有身份时，从服务端 `user_props.key_pair` 把身份取回来。
  ///
  /// 这一步很关键 —— 原 App 也是「本地没有就用服务端那份」再要口令，
  /// **绝不能**直接生成新密钥对：那会把服务端记录顶掉，之前加密频道里
  /// 所有消息就永远解不开了（这个坑在原地踩过两次）。
  /// 返回 true 表示拿到了身份（可能还没解锁）。
  Future<bool> adoptServerIdentityIfAny() async {
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    if (api == null) return false;
    final svc = _svc;
    try {
      final me = await api.myUser();
      if (me == null || me.publicKey.isEmpty) return false;
      await svc.adoptServerIdentity(
        E2eeIdentity(publicKey: me.publicKey, privateKeyEnc: me.privateKeyEnc),
      );
      if (!ref.mounted) return true;
      state = state.copyWith(
        configured: true,
        unlocked: false,
        publicKey: me.publicKey,
      );
      return true;
    } catch (e) {
      if (ref.mounted) state = state.copyWith(error: userFacingError(e));
      return false;
    }
  }

  /// 读本地身份；若已解锁则顺带把频道密钥解出来。
  ///
  /// 注意每个异步方法都**先把 ref 里拿到的东西取出来**再用：Riverpod 3 里
  /// provider 可能在 await 期间被 dispose（测试里 `container.read` 之后没有
  /// 监听者就是这种情况），await 之后再碰 `ref` 会抛
  /// "Cannot use the Ref ... after it has been disposed"。
  Future<void> load() async {
    final svc = _svc;
    final store = ref.read(chatStoreProvider);
    final identity = await svc.load();
    if (!ref.mounted) return;
    state = state.copyWith(
      ready: true,
      configured: svc.isConfigured,
      unlocked: svc.isUnlocked,
      publicKey: identity?.publicKey ?? '',
    );
    if (!svc.isUnlocked) {
      // 本地没有身份 → 试试服务端那份（然后等用户输口令）
      if (!svc.isConfigured) await adoptServerIdentityIfAny();
      return;
    }
    final channels = await store.allChannels();
    if (!ref.mounted) return;
    state = state.copyWith(brokenChannels: svc.loadChannelKeys(channels));
  }

  /// 从当前频道列表里解出所有频道密钥（解锁后必调一次）。
  Future<void> refreshChannelKeys() async {
    final svc = _svc;
    final store = ref.read(chatStoreProvider);
    final channels = await store.allChannels();
    if (!ref.mounted) return;
    state = state.copyWith(brokenChannels: svc.loadChannelKeys(channels));
  }

  /// 第一次设置：生成密钥对 + 用口令保护私钥，并把公钥/私钥上传服务端。
  ///
  /// 原 App 是 `PreferencesHelper.getKeyPair()` + `AccountManager.updateKey`。
  Future<bool> setup(String passcode) async {
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    final connId = ref.read(chatSessionControllerProvider).connId;
    final svc = _svc;
    // 服务端已经有身份就不许覆盖（覆盖 = 旧加密频道全部变砖）
    if (!svc.isConfigured && await adoptServerIdentityIfAny()) {
      if (ref.mounted) {
        state = state.copyWith(
          busy: false,
          error: platformText().e2eeServerIdentityExists,
        );
      }
      return false;
    }
    final store = ref.read(chatStoreProvider);
    state = state.copyWith(busy: true, clearError: true);
    try {
      final identity = await svc.setup(passcode);
      if (api != null && connId != null && connId.isNotEmpty) {
        await api.updateKey(
          connId: connId,
          publicKey: identity.publicKey,
          privateKeyEnc: identity.privateKeyEnc,
        );
      }
      if (!ref.mounted) return true;
      state = state.copyWith(
        busy: false,
        configured: true,
        unlocked: true,
        publicKey: identity.publicKey,
      );
      final channels = await store.allChannels();
      if (!ref.mounted) return true;
      state = state.copyWith(brokenChannels: svc.loadChannelKeys(channels));
      return true;
    } catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(busy: false, error: userFacingError(e));
      return false;
    }
  }

  /// 输入口令解锁（换设备/重开后）。
  Future<bool> unlock(String passcode) async {
    final svc = _svc;
    final store = ref.read(chatStoreProvider);
    state = state.copyWith(busy: true, clearError: true);
    try {
      await svc.unlock(passcode);
      if (!ref.mounted) return true;
      state = state.copyWith(busy: false, unlocked: true);
      final channels = await store.allChannels();
      if (!ref.mounted) return true;
      state = state.copyWith(brokenChannels: svc.loadChannelKeys(channels));
      return true;
    } catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(
        busy: false,
        error: platformText().e2eeBadPasscodeOrKey(userFacingError(e)),
      );
      return false;
    }
  }

  /// 锁上（私钥与频道密钥从内存清掉）。
  void lock() {
    _svc.lock();
    state = state.copyWith(unlocked: false);
  }

  /// 换口令：私钥重新加密一遍，并同步到服务端。
  Future<bool> changePasscode({
    required String oldPasscode,
    required String newPasscode,
  }) async {
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    final connId = ref.read(chatSessionControllerProvider).connId;
    final svc = _svc;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final identity = await svc.changePasscode(
        oldPasscode: oldPasscode,
        newPasscode: newPasscode,
      );
      if (api != null && connId != null && connId.isNotEmpty) {
        await api.updateKey(
          connId: connId,
          publicKey: identity.publicKey,
          privateKeyEnc: identity.privateKeyEnc,
        );
      }
      if (!ref.mounted) return true;
      state = state.copyWith(busy: false);
      return true;
    } catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(
        busy: false,
        error: platformText().e2eeWrongOldPasscode,
      );
      return false;
    }
  }

  /// 真正「更换密钥对」（原版 `RenewKeyPresenter` / `RenewKeyActivity` 的
  /// `renew_key`）：造新密钥对 → 用旧对解出所有频道/归档密钥 → 用新公钥重封 →
  /// `update_key` v2 上报 → 本地换身份 + 换本地 `channel_key_enc`。
  ///
  /// 口令只是用来**校验**（原版也只用它 `decryptPrivateKey` 验一下），新私钥
  /// 仍然用同一个口令加密。失败时旧身份一律保持可用。
  Future<bool> renewKeyPair({required String passcode}) async {
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    final connId = ref.read(chatSessionControllerProvider).connId;
    final svc = _svc;
    if (api == null || connId == null || connId.isEmpty) return false;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final store = ref.read(chatStoreProvider);
      final channels = await store.allChannels();
      if (!ref.mounted) return false;
      List<ArchiveDto> archives = const [];
      try {
        archives = await api.listArchives();
      } catch (_) {
        // 归档拿不到不影响换密钥对（原版也允许列表为空）
      }
      if (!ref.mounted) return false;

      final renewed = await svc.renewKeyPair(
        passcode: passcode,
        channels: channels,
        archives: archives,
      );
      if (!ref.mounted) return false;
      await api.updateKey(
        connId: connId,
        publicKey: renewed.publicKey,
        privateKeyEnc: renewed.privateKeyEnc,
        channelIds: renewed.channelIds,
        channelKeyEncs: renewed.channelKeyEncs,
        archiveIds: renewed.archiveIds,
        archiveKeyEncs: renewed.archiveKeyEncs,
      );
      if (!ref.mounted) return false;
      // 服务端收下了才落地新身份，避免"服务端新/本地旧"的半截状态
      await svc.adoptRenewedIdentity(renewed);
      await store.updateChannelEncryptKeys(
        renewed.channelIds,
        renewed.channelKeyEncs,
      );
      // 换密钥对会让服务端把我的频道密钥判成失效（同账号其它会话收到
      // `client.channel.brokenuser`），本机已经重封好了，立刻摘掉自己的 ⚠
      final myId = ref.read(chatSessionControllerProvider).myUserId;
      if (myId > 0) {
        await store.clearChannelBrokenUsers(renewed.channelIds, [myId]);
      }
      if (!ref.mounted) return true;
      state = state.copyWith(
        busy: false,
        publicKey: renewed.publicKey,
        brokenChannels: const [],
      );
      return true;
    } catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(
        busy: false,
        error: platformText().e2eeRenewKeyFailed(userFacingError(e)),
      );
      return false;
    }
  }

  /// 清掉本机身份（服务端那份要重新 setup 覆盖）。
  Future<void> reset() async {
    await _svc.reset();
    state = state.copyWith(
      configured: false,
      unlocked: false,
      publicKey: '',
      brokenChannels: const [],
    );
  }

  /// 把频道密钥重新封给某个成员，修好一个解不开的频道。
  ///
  /// 对应原 App 的 `AccountManager.rescueChannel`。
  Future<bool> rescueChannel({
    required int channelId,
    required int userId,
  }) async {
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    if (api == null) return false;
    final store = ref.read(chatStoreProvider);
    final users = await store.allUsers();
    if (!ref.mounted) return false;
    final target = users.where((u) => u.userId == userId).firstOrNull;
    if (target == null || target.publicKey.isEmpty) {
      state = state.copyWith(error: platformText().e2eeNoRecipientKey);
      return false;
    }
    final svc = _svc;
    try {
      final sealed = svc.sealChannelKey(channelId, target.publicKey);
      await api.rescueChannel(
        userId: userId,
        channelId: channelId,
        channelKeyEnc: sealed,
      );
      // 服务端随后会广播 `channel.rescue`；这里先本地摘掉，界面立刻不显示 ⚠
      await store.removeChannelBrokenUsers(channelId, [userId]);
      return true;
    } catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(error: userFacingError(e));
      return false;
    }
  }

  /// 给「我自己」重新登记某个频道的密钥（本地换过密钥对之后必调）。
  Future<bool> reuploadMyChannelKeys() async {
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    final connId = ref.read(chatSessionControllerProvider).connId;
    final svc = _svc;
    final identity = svc.identity;
    if (api == null || connId == null || identity == null) return false;
    final store = ref.read(chatStoreProvider);
    final channels = await store.allChannels();
    if (!ref.mounted) return false;
    // 先把本地频道密钥都解出来（界面不一定会先调 `_ensureKey`），否则
    // `myKeyEncs` 会是空的 —— 那就等于"重传了个寂寞"
    svc.loadChannelKeys(channels);
    final mine = svc.myKeyEncs(channels);
    // 归档频道（`Archive/list type=encrypted`）单独一组参数上报
    List<ArchiveDto> archives = const [];
    try {
      archives = await api.listArchives();
    } catch (_) {
      // 老 NAS / 没权限：归档拿不到不影响普通频道重传
    }
    if (!ref.mounted) return false;
    if (archives.isNotEmpty) svc.loadArchiveKeys(archives);
    final archived = svc.archiveKeyEncs(archives);
    try {
      await api.updateKey(
        connId: connId,
        publicKey: identity.publicKey,
        privateKeyEnc: identity.privateKeyEnc,
        channelIds: mine.channelIds,
        channelKeyEncs: mine.channelKeyEncs,
        archiveIds: archived.archiveIds,
        archiveKeyEncs: archived.archiveKeyEncs,
      );
      // 真机实测：`update_key` 这个调用本身会让服务端先把我的频道密钥判成失效，
      // 给**同账号其它会话**广播 `client.channel.brokenuser`（还发一条
      // `user.broken` 系统消息）。我们紧接着就把密钥封好传上去了，所以本机
      // 该立刻把自己的 broken 标记摘掉，不然界面会一直给自己挂 ⚠。
      final myId = ref.read(chatSessionControllerProvider).myUserId;
      if (myId > 0) {
        await store.clearChannelBrokenUsers(mine.channelIds, [myId]);
      }
      return true;
    } catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(error: userFacingError(e));
      return false;
    }
  }

  // ------------------------------------------------------------ 给界面用

  bool get isUnlocked => _svc.isUnlocked;

  /// 频道密钥缺失时同步补一份（`seal_open` 是纯 Dart 运算，不涉及 IO）。
  ///
  /// 这样频道列表晚于身份到达、或者后台新建了加密频道，界面一读就能就绪，
  /// 不用挂着监听等状态同步。
  void _ensureKey(ChannelDto channel) {
    final svc = _svc;
    if (!channel.encrypted || !svc.isUnlocked) return;
    if (svc.channelKey(channel.channelId) != null) return;
    svc.loadChannelKey(channel.channelId, channel.channelKeyEnc);
  }

  /// 某个频道的密钥状态（`ready` / `locked` / `missing` / `notEncrypted`）。
  ChannelKeyState keyStateOf(ChannelDto channel) {
    _ensureKey(channel);
    return _svc.keyState(channel);
  }

  /// 加密频道但本机解不开——界面上要提示「修复/换设备」。
  bool isBroken(ChannelDto channel) =>
      channel.encrypted && _svc.keyState(channel) == ChannelKeyState.missing;

  /// 消息该显示成什么：非加密频道原样；加密频道能解就解，不能解给占位。
  String displayMessage(ChannelDto? channel, String raw) {
    if (channel == null || !channel.encrypted || raw.isEmpty) return raw;
    _ensureKey(channel);
    final text = _svc.tryDecryptMessage(channel.channelId, raw);
    return text ?? kUndecryptableText;
  }

  /// 文件名同理（加密频道里文件名是 hex）。
  String displayFileName(ChannelDto? channel, String raw) {
    if (channel == null || !channel.encrypted || raw.isEmpty) return raw;
    _ensureKey(channel);
    return _svc.tryDecryptFileName(channel.channelId, raw) ??
        platformText().e2eeEncryptedFile;
  }

  /// 发消息前加密（非加密频道/没锁时返回原文）。
  String encodeOutgoing(ChannelDto? channel, String text) {
    if (channel == null || !channel.encrypted) return text;
    return _svc.encryptMessage(channel.channelId, text);
  }
}

final e2eeControllerProvider = NotifierProvider<E2eeController, E2eeState>(
  E2eeController.new,
);
