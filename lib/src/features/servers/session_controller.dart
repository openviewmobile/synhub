import 'dart:async';
import '../../data/auth_extra_api.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/net/trust_store.dart';
import '../../core/net/media_tls_policy.dart';
import '../../core/security/keystore_secret_keeper.dart';
import '../../dsm/webapi.dart';
import '../chat/chat_session_controller.dart';
import 'connection_error_text.dart';
import 'connection_service.dart';
import 'nas_registry.dart';
import '../admin/admin_identity.dart';
import 'nas_store.dart';
import 'saved_session.dart';
import 'server_profile.dart';

/// 会话页面的状态：连接 → 登录 → 已登录。
class SessionState {
  const SessionState({
    this.connection,
    this.session,
    this.busy = false,
    this.steps = const [],
    this.error,
    this.restoring = false,
    this.saved,
    this.autoLoginFailed = false,
    this.otpRequired = false,
    this.activeNasId,
    this.switching = false,
  });

  final DsmConnection? connection;
  final DsmSession? session;
  final bool busy;

  /// 连接过程的逐步日志，直接显示给用户 —— 连不上时能看出卡在哪一步。
  final List<ConnectStep> steps;

  final String? error;

  /// 正在做"冷启动静默重登"（启动页据此显示恢复态，而不是空表单）。
  final bool restoring;

  /// 本地留着的上次登录快照（预填服务器/账号用；凭据可能解不开）。
  final SavedSession? saved;

  /// 静默重登失败过（连接成功但登录没过）：提示用户手动登一次。
  final bool autoLoginFailed;

  /// 上次登录被服务端要求一次性验证码（**与语言无关的判据**）。
  ///
  /// 登录页原先靠 `error.contains('验证码')` 判断，英文环境下错误文案不含
  /// 「验证码」就失效了；这里落到错误码上（`DsmApiException.needsOtp`），
  /// 界面只管读这个布尔值。
  final bool otpRequired;

  /// 当前活动 NAS 的条目 id（多 NAS 用；null = 当前没有已登录的 NAS）。
  ///
  /// 它必须与 [connection] 指向同一个 NAS —— 切换时先把它钉到目标，
  /// 再用**目标自己的**凭据去连，绝不复用上一条会话的 sid/did。
  final String? activeNasId;

  /// 正在切换到另一个 NAS（界面显示切换中，避免把旧列表当成新 NAS 的）。
  final bool switching;

  bool get connected => connection != null;
  bool get loggedIn => session != null;

  SessionState copyWith({
    DsmConnection? connection,
    DsmSession? session,
    bool? busy,
    List<ConnectStep>? steps,
    String? error,
    bool? restoring,
    SavedSession? saved,
    bool? autoLoginFailed,
    bool? otpRequired,
    String? activeNasId,
    bool? switching,
    bool clearError = false,
    bool clearConnection = false,
    bool clearSaved = false,
    bool clearActiveNas = false,
  }) {
    return SessionState(
      connection: clearConnection ? null : (connection ?? this.connection),
      session: session ?? this.session,
      busy: busy ?? this.busy,
      steps: steps ?? this.steps,
      error: clearError ? null : (error ?? this.error),
      restoring: restoring ?? this.restoring,
      saved: clearSaved ? null : (saved ?? this.saved),
      autoLoginFailed: autoLoginFailed ?? this.autoLoginFailed,
      otpRequired: otpRequired ?? this.otpRequired,
      activeNasId: clearActiveNas ? null : (activeNasId ?? this.activeNasId),
      switching: switching ?? this.switching,
    );
  }
}

/// 切换 / 添加 / 移除 NAS 的结果（界面据此决定跳哪一页）。
enum NasSwitchResult {
  /// 已切过去并登录成功
  success,

  /// 本来就是当前 NAS，无需切
  alreadyActive,

  /// 切过去了，但本机没有可用凭据 → 去登录页（地址/账号已预填）
  needLogin,

  /// 服务器连不上 → 留在当前页，显示错误
  connectFailed,

  /// 连上了但登录被拒 → 去登录页补密码
  loginFailed,

  /// 找不到这条记录（可能已被移除）
  notFound,
}

/// 冷启动静默重登的结果（启动页据此决定跳哪一页）。
enum AutoLoginResult {
  /// 恢复了：已登录，直接进主页
  success,

  /// 本机没有保存过登录（第一次用，或刚登出）—— 正常走连接流程
  none,

  /// 有记录但**凭据解不开**（换机/重装/Keystore 密钥被清）→ 预填后让用户重输
  needCredentials,

  /// 服务器连上了，但登录被拒（密码改了/账号停用/要验证码）→ 去登录页
  loginFailed,

  /// 连服务器都没连上（不在同一网络、NAS 关机）→ 留在连接页
  connectFailed,
}

/// 连接与登录的唯一入口。UI 只跟这个 provider 打交道。
/// 首连信任策略（单例；UI 在 `app.dart` 里注册 `prompt`）
final trustPolicyProvider = Provider<TrustPolicy>((ref) {
  final store = ref.watch(chatStoreProvider);
  return TrustPolicy.of(
    read: (k) => store.setting(k),
    write: (k, v) => store.setSetting(k, v),
    remove: (k) => store.deleteSetting(k),
    all: () => store.allSettings(),
  );
});

/// 连接服务（带信任策略）
final connectionServiceProvider = Provider<ConnectionService>((ref) {
  return ConnectionService(trustPolicy: ref.watch(trustPolicyProvider));
});

/// 「上次登录」的存取（同一张本地键值表；测试可换成内存 SecretKeeper）
final savedSessionStoreProvider = Provider<SavedSessionStore>((ref) {
  return SavedSessionStore(
    ref.watch(chatStoreProvider),
    // 真机走 Android Keystore；测试/桌面自动退回明文
    keeper: const KeystoreSecretKeeper(),
  );
});

class SessionController extends Notifier<SessionState> {
  ConnectionService get _service => ref.read(connectionServiceProvider);

  /// 登录凭据（内存副本）—— 会话过期时自动重登要用（对齐原版
  /// `PreferencesHelper.getAccount()` 那份 MyAccount）。
  ///
  /// 注意：**不是唯一一份**。登录成功后同一套东西会经 [savedSessionStoreProvider]
  /// 落盘（凭据由 Android Keystore 封存），冷启动靠它静默重登。
  String? _account;
  String? _password;
  String? _otp;
  bool _rememberDevice = false;

  /// 服务端下发的设备令牌（`did`）：下次登录带回去才能免验证码。
  String? _did;

  /// 当前活动 NAS 的条目 id（`NasRegistry` 里的 id）。
  ///
  /// 内存里的 [_account]/[_password]/[_did] 永远只属于它 —— 切换时先置空，
  /// 再用目标条目的凭据重新填，从结构上杜绝"A 的 sid/did 用到 B 上"。
  String? _activeNasId;

  /// 正在恢复中（防重入：路由重建会多次调 restore）
  bool _restoring = false;

  NasRegistry get _registry => ref.read(nasRegistryProvider.notifier);

  @override
  SessionState build() => const SessionState();

  /// 拆掉当前 NAS 的一切，确保切走之后不会再有它的请求/重登发生。
  ///
  /// 顺序很重要：**先摘自动重登钩子**，再关传输层，最后清内存凭据。
  /// 摘钩子消除了"A 的 119 触发一次登录、却把结果写进 B 的 state"这条路径。
  void _detachCurrent() {
    final conn = state.connection;
    final api = conn?.api;
    if (api != null) {
      api.onSessionExpired = null;
      api.onSessionLost = null;
    }
    if (conn != null) {
      // 关连接是"顺手做"的：失败也不该卡住切换
      unawaited(conn.api.transport.close().catchError((_) {}));
    }
    _account = null;
    _password = null;
    _otp = null;
    _did = null;
    _rememberDevice = false;
  }

  /// 这次登录可以回传的设备令牌（`did`）。
  ///
  /// 只有"当前活动条目就是这个 NAS、就是这个账号"时才复用：否则返回 null，
  /// 绝不把上一个账号的设备令牌带给新账号。
  String? _didForAccount(String account) {
    final active = ref.read(nasRegistryProvider).active;
    final a = account.trim();
    if (active == null || active.account.trim().isEmpty) return _did;
    if (active.account.trim() == a) return _did ?? active.deviceId;
    return null;
  }

  /// 解析地址并建立传输层（还没登录）。
  Future<bool> connect(ServerProfile profile) async {
    // 目标不是当前保存的 NAS → 先把旧会话彻底卸掉（摘自动重登钩子、关连接、
    // 清掉内存里的账号/did）。否则 A 的 did 会被带到 B 的登录请求里。
    await _registry.ensureLoaded();
    final prevActive = ref.read(nasRegistryProvider).active;
    if (prevActive == null ||
        !NasStore.sameServer(prevActive.profile, profile)) {
      _detachCurrent();
      _activeNasId = null;
    }
    final keepActiveId = _activeNasId;

    state = state.copyWith(
      busy: true,
      steps: const [],
      clearError: true,
      clearConnection: true,
      activeNasId: keepActiveId,
      clearActiveNas: keepActiveId == null,
    );
    final steps = <ConnectStep>[];
    try {
      // 信任库读进内存（同步握手回调要用）
      final policy = ref.read(trustPolicyProvider);
      if (!policy.isLoaded) await policy.load();
      final conn = await _service.connect(
        profile,
        onStep: (s) {
          steps.add(s);
          state = state.copyWith(steps: List.of(steps));
        },
      );
      state = state.copyWith(
        connection: conn,
        busy: false,
        steps: List.of(steps),
      );
      // ★ 第 259 轮：把 Dart 侧已采纳的 TLS 政策同步给**原生媒体栈**
      // （ExoPlayer / just_audio 都建在 HttpURLConnection 上，用的是平台默认
      // 的严格主机名校验 ⇒ 真机上"能列目录、一点视频/音频就
      // SSLPeerUnverifiedException"）。见 `media_tls_policy.dart`。
      // ★ r87：**不 await**。下发只是"尽力而为的加固"，而平台消息在
      // "通道没人接"的宿主（flutter test / 老构建）上**永不完成** ⇒
      // await 会把整条连接/恢复流程挂死（r87 真把 3 条路由用例挂红了）。
      // 见 AGENTS §2.0.20⑤。
      unawaited(_syncMediaTlsPolicy(conn, policy));
      return true;
    } catch (e, st) {
      logConnectionErrorForDiagnostics('connect', e, st);
      final msg = connectionUserFacingError(e);
      steps.add(ConnectStep(msg, ok: false));
      state = state.copyWith(busy: false, steps: List.of(steps), error: msg);
      return false;
    }
  }

  /// 登录。成功返回 true。
  Future<bool> login({
    required String account,
    required String password,
    String? otp,
    bool rememberDevice = false,
  }) async {
    final conn = state.connection;
    if (conn == null) {
      state = state.copyWith(error: currentText().srvNotConnected);
      return false;
    }

    state = state.copyWith(busy: true, clearError: true, otpRequired: false);
    try {
      // 设备令牌只在"同一个 NAS 的同一个账号"上复用：换了账号就绝不再带，
      // 否则会拿 A 的 did 去给 B 免验证码（多账号下的串号）。
      final deviceId = _didForAccount(account);
      // 原 App 的 session 名取自 LoggerUtil.TAG == "Chat"，
      // webapi 里已经是默认值，这里显式写出来以免日后误改。
      final session = await conn.api.login(
        account: account,
        password: password,
        otpCode: otp,
        session: 'Chat',
        // 上次拿到的设备令牌：带回去服务端就不再要验证码
        // （对齐原版：`device_id=<did>&enable_device_token=yes`）
        deviceId: deviceId,
        enableDeviceToken: rememberDevice,
      );
      _account = account;
      _password = password;
      _otp = otp;
      _rememberDevice = rememberDevice;
      _did = session.did ?? deviceId;
      // 先落盘（确定 / 新建这一条，拿到它的 id），再装自动重登钩子 ——
      // 钩子里的重登必须知道"自己属于哪个 NAS"。
      await _persist(conn, account: account, password: password);
      _installRelogin(conn);
      state = state.copyWith(
        session: session,
        busy: false,
        restoring: false,
        autoLoginFailed: false,
        otpRequired: false,
        activeNasId: _activeNasId,
        clearActiveNas: _activeNasId == null,
      );
      _loadAdminIdentity();
      return true;
    } on DsmApiException catch (e) {
      // DsmApiException 只带错误码，文案由 DsmErrorCode 统一给出
      state = state.copyWith(
        busy: false,
        error: DsmErrorCode.describe(e.code),
        otpRequired: e.needsOtp,
      );
      return false;
    } catch (e, st) {
      logConnectionErrorForDiagnostics('login', e, st);
      state = state.copyWith(
        busy: false,
        error: connectionUserFacingError(e),
        otpRequired: false,
      );
      return false;
    }
  }

  /// 冷启动静默重登：读上次的服务器 + 账号 + 凭据，连上并登录。
  ///
  /// 三条出口都要给 UI 一个明确的去处（见 [AutoLoginResult]）：
  ///   * 成功 → 直接进主页，用户完全无感；
  ///   * 连上但登录被拒 → 去登录页（服务器/账号已预填，只差密码）；
  ///   * 连接都失败 → 留在连接页，把上次的地址预填好，点一下「连接」即可。
  ///
  /// **连上但登录被拒且是"确定性拒登"**（密码错/账号停用/要改密）时，落盘的
  /// 密码会被清掉 —— 否则每次冷启动都拿一个必然失败的密码去撞一次。
  Future<AutoLoginResult> restore() async {
    if (_restoring) return AutoLoginResult.none;
    _restoring = true;
    try {
      // 冷启动认的是**本机当前活动的那条**记录（多 NAS 下就是上次用的那个）
      await _registry.ensureLoaded();
      final saved = ref.read(nasRegistryProvider).active;
      if (saved == null) {
        _activeNasId = null;
        state = state.copyWith(restoring: false, clearSaved: true);
        return AutoLoginResult.none;
      }
      _activeNasId = saved.id;
      _did = saved.deviceId ?? _did;
      _rememberDevice = saved.rememberDevice;

      if (!saved.canAutoLogin) {
        // 记录还在但凭据解不开（换机/重装）：预填服务器与账号，请用户补密码
        state = state.copyWith(
          restoring: false,
          saved: saved,
          activeNasId: saved.id,
          clearActiveNas: saved.id == null,
          error: currentText().srvSavedCredentialsLocked,
        );
        return AutoLoginResult.needCredentials;
      }

      state = state.copyWith(
        busy: true,
        restoring: true,
        steps: const [],
        clearError: true,
        clearConnection: true,
        saved: saved,
        activeNasId: saved.id,
        clearActiveNas: saved.id == null,
        autoLoginFailed: false,
      );
      final steps = <ConnectStep>[];
      DsmConnection conn;
      try {
        conn = await _service.connect(
          saved.profile,
          onStep: (s) {
            steps.add(s);
            state = state.copyWith(steps: List.of(steps));
          },
        );
      } catch (e, st) {
        logConnectionErrorForDiagnostics('restoreConnect', e, st);
        final msg = connectionUserFacingError(e);
        steps.add(ConnectStep(msg, ok: false));
        state = state.copyWith(
          connection: null,
          busy: false,
          restoring: false,
          steps: List.of(steps),
          saved: saved,
          error: msg,
        );
        return AutoLoginResult.connectFailed;
      }
      state = state.copyWith(connection: conn, steps: List.of(steps));
      unawaited(_syncMediaTlsPolicy(conn, ref.read(trustPolicyProvider)));

      try {
        final session = await conn.api.login(
          account: saved.account,
          password: saved.password!,
          // 不送 OTP：一次性验证码不落盘；免验证码靠上次的 did
          otpCode: null,
          session: 'Chat',
          deviceId: saved.deviceId,
          enableDeviceToken: saved.rememberDevice,
        );
        _account = saved.account;
        _password = saved.password;
        _otp = null; // 冷启动不重放旧验证码（它是一次性的）
        _did = session.did ?? saved.deviceId;
        _installRelogin(conn);
        state = state.copyWith(
          session: session,
          busy: false,
          restoring: false,
          clearError: true,
          autoLoginFailed: false,
        );
        // did 可能是这次才拿到的（第一次勾"信任此设备"），补一次落盘
        await _persist(conn, account: saved.account, password: saved.password!);
        _loadAdminIdentity();
        debugPrint('[session] 冷启动静默重登成功（${conn.endpoint.source}）');
        return AutoLoginResult.success;
      } on DsmApiException catch (e) {
        final fatal = DsmErrorCode.skipRetryLoginCodes.contains(e.code);
        if (fatal) {
          // 密码已经不对了：留下服务器/账号，丢掉密码，别再拿它撞
          await _registry.upsertActive(
            SavedSession(
              id: saved.id,
              profile: saved.profile,
              account: saved.account,
              rememberDevice: saved.rememberDevice,
              deviceId: saved.deviceId,
              lastBaseUrl: conn.endpoint.baseUrl,
            ),
          );
        }
        state = state.copyWith(
          busy: false,
          restoring: false,
          autoLoginFailed: true,
          saved: fatal ? saved.copyWith(clearPassword: true) : saved,
          error: DsmErrorCode.describe(e.code),
        );
        return AutoLoginResult.loginFailed;
      }
    } catch (e, st) {
      logConnectionErrorForDiagnostics('autoLogin', e, st);
      state = state.copyWith(
        busy: false,
        restoring: false,
        error: connectionUserFacingError(e),
      );
      return AutoLoginResult.connectFailed;
    } finally {
      _restoring = false;
    }
  }

  /// 把这次的登录信息落盘（下一次冷启动靠它静默重登）。
  ///
  /// 凭据本体交给 [NasStore]（Android Keystore 封存）；`did` 也一起存 ——
  /// 那是"下次免验证码"的钥匙。**顺带确定这条记录的 id 与"当前 NAS"**：
  /// 多 NAS 之后 `_activeNasId` 就是从这里定下来的。
  /// 落盘的**等待上限**。
  ///
  /// ★ r698（Linux 实测）：`flutter_secure_storage` 在 Linux 上走 libsecret；
  /// 钥匙串**没有解锁的默认 keyring** 时，GNOME 会弹一个**模态**的
  /// 「Choose password for new keyring」框 —— 那是**阻塞调用**，不是异常：
  /// 于是 `await` 永不返回，登录按钮一直停在 `AUTHENTICATING`
  /// （容器里无头、没人去关那个框 ⇒ 看起来就是"登录卡死"；真机上用户关掉框才继续）。
  ///
  /// ⇒ 凭据落盘**永远不许挡住"已经登录成功"这件事**：最多等这么久，
  /// 超时就把这次写盘丢到后台继续，界面照常进主页。
  static const Duration persistWaitCap = Duration(seconds: 3);

  Future<void> _persist(
    DsmConnection conn, {
    required String account,
    required String password,
  }) async {
    Future<SavedSession> write() => _registry.upsertActive(
      SavedSession(
        id: _activeNasId,
        profile: conn.profile,
        account: account,
        password: password,
        rememberDevice: _rememberDevice,
        deviceId: _did,
        lastBaseUrl: conn.endpoint.baseUrl,
      ),
    );

    void apply(SavedSession entry) {
      _activeNasId = entry.id;
      state = state.copyWith(saved: entry, activeNasId: entry.id);
    }

    try {
      apply(await write().timeout(persistWaitCap));
    } on TimeoutException {
      // 钥匙串被系统弹窗挡住（见 [persistWaitCap]）。**不能**把它当失败：
      // 后台继续等这次写盘，成功后补状态；界面这一帧就该进主页。
      debugPrint(
        '[session] 保存登录信息超过 ${persistWaitCap.inSeconds}s 仍未完成'
        '（Linux 钥匙串可能被系统「新建 keyring」弹窗挡住）⇒ 后台继续，不挡登录',
      );
      unawaited(
        write().then(apply).catchError((Object e) {
          debugPrint('[session] 保存登录信息失败（后台）：$e');
        }),
      );
    } catch (e) {
      // 落盘失败不该让"已经登录成功"这件事变失败
      debugPrint('[session] 保存登录信息失败：$e');
    }
  }

  /// 装上"会话过期自动重登"（原版 `RetryInterceptor`）。
  ///
  /// 值得这么做的原因：NAS 重启 / 会话被挤掉之后，一次 119 会让**所有**
  /// 后续请求连带失败；原版是在 OkHttp 拦截器里重登 + 重放，用户无感。
  /// 注意：**只有 119（`sidNotFound`）重登**；`105/160`（无权限）与 `102`（未安装）
  /// 是确定性失败，重登不改变结果（R6 实测 105 会滚成 712 次请求的正反馈），
  /// 已在 `DsmErrorCode.retryLoginCodes` 里熔断。
  ///
  /// 多 NAS 安全：钩子**钉死**在自己所属的那条记录上（[boundNasId]），凭据也从
  /// 那条记录里取，而不是从可能已被别的 NAS 覆盖的内存字段取。切成别的 NAS 时
  /// `_detachCurrent` 会把旧 api 的钩子摘掉，所以 A 的 119 不可能登进 B 的会话。
  void _installRelogin(DsmConnection conn) {
    final api = conn.api;
    final boundNasId = _activeNasId;
    api.onSessionExpired = () async {
      if (boundNasId != _activeNasId) {
        // 已经切走了：这条旧连接不该再动任何状态
        throw DsmApiException(
          DsmErrorCode.sidNotFound,
          method: 'SYNO.API.Auth.login',
        );
      }
      final entry = ref.read(nasRegistryProvider).byId(boundNasId);
      final account = (entry != null && entry.account.trim().isNotEmpty)
          ? entry.account
          : _account;
      final password = entry?.password ?? _password;
      final did = entry?.deviceId ?? _did;
      final remember = entry?.rememberDevice ?? _rememberDevice;
      if (account == null || password == null) {
        // 没有凭据（例如冷启动恢复的旧会话）→ 当作不可恢复，让上层去要求重登
        throw DsmApiException(
          DsmErrorCode.authInvalidPassword,
          method: 'SYNO.API.Auth.login',
        );
      }
      final renewed = await api.login(
        account: account,
        password: password,
        otpCode: _otp,
        session: 'Chat',
        deviceId: did,
        enableDeviceToken: remember,
      );
      _did = renewed.did ?? did;
      state = state.copyWith(session: renewed);
      // sid 变了 → 实时通道必须用新 sid 重连（旧连接在服务端已经失效）
      try {
        ref
            .read(chatSessionControllerProvider.notifier)
            .restartRealtime(renewed);
      } catch (_) {
        // 还没进聊天页 / provider 未就绪：忽略
      }
      debugPrint(
        '[session] 会话过期已自动重登，sid 更新为 '
        '${renewed.sid.length > 6 ? renewed.sid.substring(0, 6) : renewed.sid}…',
      );
    };
    api.onSessionLost = (code) {
      if (boundNasId != _activeNasId) return;
      debugPrint('[session] 自动重登失败（code=$code），不再重试');
      state = state.copyWith(error: DsmErrorCode.describe(code));
    };
  }

  /// 切换到另一个 NAS / 账号。
  ///
  /// 顺序是安全不变量的核心：
  ///   1. **先卸掉当前**（摘自动重登钩子 → 关连接 → 清内存账号/did/sid 上下文）；
  ///   2. 把"当前 NAS"钉到目标（落盘）；
  ///   3. 清空 [state]（上一条会话的 sid 不得残留在 `connection`/`session` 里）；
  ///   4. 用**目标条目自己的**地址与凭据去连、去登。
  ///
  /// 因此任何时刻 `state.connection` 与 `state.activeNasId` 都指向同一个 NAS，
  /// A 的 sid / did 不可能被带到 B 的请求上。
  Future<NasSwitchResult> switchTo(String id) async {
    await _registry.ensureLoaded();
    final target = ref.read(nasRegistryProvider).byId(id);
    if (target == null) return NasSwitchResult.notFound;
    if (id == _activeNasId && state.loggedIn) {
      return NasSwitchResult.alreadyActive;
    }

    // 1. 卸掉当前 NAS 的一切
    _detachCurrent();
    _activeNasId = null;

    // 2. 先钉住"当前"，后续 _persist / 重登都认它
    await _registry.setActive(id);
    _activeNasId = id;
    state = SessionState(activeNasId: id, switching: true, saved: target);

    // 3. 本机没有可用凭据 → 去登录页补（地址/账号已预填）
    if (!target.canAutoLogin) {
      state = state.copyWith(switching: false);
      return NasSwitchResult.needLogin;
    }

    // 4. 用目标自己的地址 + 凭据
    final connected = await connect(target.profile);
    if (!connected) {
      state = state.copyWith(switching: false, activeNasId: id, saved: target);
      return NasSwitchResult.connectFailed;
    }
    final ok = await login(
      account: target.account,
      password: target.password!,
      rememberDevice: target.rememberDevice,
    );
    state = state.copyWith(switching: false, activeNasId: id);
    return ok ? NasSwitchResult.success : NasSwitchResult.loginFailed;
  }

  /// 添加一个新 NAS（只记地址，还没有账号/凭据），并切过去。
  ///
  /// 没有凭据时 [switchTo] 返回 [NasSwitchResult.needLogin]，界面把用户带到
  /// 登录页；登录成功后 [login] 会把账号/凭据补进同一条记录。
  Future<NasSwitchResult> addNas(
    ServerProfile profile, {
    String? displayName,
  }) async {
    final entry = await _registry.add(profile, displayName: displayName);
    return switchTo(entry.id!);
  }

  /// 移除一条记录。
  ///
  /// - 移除的不是当前 NAS → 只删它，当前会话**完全不动**；
  /// - 移除的是当前 NAS → 断开当前会话，并**回落到剩余的第一条**
  ///   （没有剩余就停在未登录态）。
  ///
  /// 无论哪种情况，都只动这一条，绝不连带删除别的 NAS 配置。
  Future<NasSwitchResult> removeNas(String id) async {
    await _registry.ensureLoaded();
    final wasActive = id == _activeNasId;
    final after = await _registry.remove(id);
    if (!wasActive) return NasSwitchResult.success;

    _detachCurrent();
    _activeNasId = null;
    state = const SessionState();

    final next = after.active;
    if (next?.id == null) return NasSwitchResult.success;
    return switchTo(next!.id!);
  }

  /// 重命名（只改展示名）。
  Future<void> renameNas(String id, String? displayName) =>
      _registry.rename(id, displayName);

  /// ★★★ **登录成功后**加载管理员身份（用户 2026-09-23 第 76 轮要求）。
  ///
  /// * **不 await**：登录流程不该为了身份解析多等一个 RTT，
  ///   界面在解析完之前按 fail-closed 隐藏管理入口即可；
  /// * 失败**不冒泡**：身份解析失败绝不能把一次成功的登录变成失败；
  /// * 具体判什么由 [AdminIdentityController] 负责（三棒接力）。
  void _loadAdminIdentity() {
    try {
      // ignore: discarded_futures — 刻意不 await（见上）
      ref.read(adminIdentityProvider.notifier).refresh();
    } catch (_) {
      // provider 未挂载（测试/极端时序）不该影响登录
    }
    _probeAmfaSuggestConn();
  }

  /// ★★★ `SYNO.SecureSignIn.AMFA.SuggestConn:get`（第 92 轮）。
  ///
  /// **为什么在登录后调**：官方 `SynologyChat 2.11.1-607` 的
  /// `com/synology/sylibx/login/LoginManager.smali` 在登录流程里调它
  /// （`LoginHandler.onSuggestConn`）⇒ 这是**官方登录步骤之一**。
  ///
  /// **为什么容错**：
  /// * 不 await —— 不该为它多等一个 RTT；
  /// * 任何异常（含 `103` 老服务端没有此 API）一律吞掉 ⇒
  ///   **绝不能把一次成功的登录变成失败**；
  /// * 只记录，不据此改变登录结果。
  ///
  /// ⚠️ 本机 NAS 未强制 2FA，**因此"强制性"未被真实观察到** ——
  /// 这里只是对齐官方的调用位置，不臆断它的作用。
  void _probeAmfaSuggestConn() {
    final api = state.connection?.api;
    if (api == null) return;
    try {
      // ignore: discarded_futures — 刻意不 await（见上）
      AuthExtraApi(
        api,
      ).suggestConn().then((r) => _amfaSuggestion = r, onError: (_) {});
    } catch (_) {
      // 构造失败也不该影响登录
    }
  }

  AmfaSuggestConn? _amfaSuggestion;

  /// 最近一次登录后取到的 AMFA 连接建议（**可能为 null**：未取到/未支持）。
  ///
  /// ⚠️ 响应字段名未证实（见 `AmfaSuggestConn` 的说明）⇒
  /// **调用方不得据此做任何断言式流程分支**，仅可用于诊断展示。
  AmfaSuggestConn? get amfaSuggestion => _amfaSuggestion;

  /// 把当前会话的 TLS 政策下发给原生媒体栈（`setTlsPolicy`）。
  ///
  /// 指纹取首连信任库里**这台主机**那一枚（没有就只放宽主机名校验，
  /// 证书链照旧由系统 CA 校验）。
  ///
  /// ★ 调用方**不要 await** 这个 Future：`MediaTlsPolicy.install` 里的
  /// `channel.invokeMethod` 在"没人接这条通道"的宿主上**永不完成**
  /// （flutter test 就是；见 AGENTS §2.0.20⑤）⇒ await 会挂死连接流程。
  /// 加固失败不影响连接本身。
  Future<void> _syncMediaTlsPolicy(
    DsmConnection conn,
    TrustPolicy policy,
  ) async {
    final baseUrl = conn.endpoint.baseUrl;
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    if (host.isEmpty) return;
    var fingerprint = policy.trustedInMemory(host);
    if (fingerprint == null) {
      try {
        fingerprint = (await policy.find(host))?.sha256;
      } catch (_) {
        // 读信任库失败不该挡住连接
      }
    }
    await MediaTlsPolicy.install(
      baseUrl: baseUrl,
      fingerprintSha256: fingerprint,
    );
  }

  Future<void> logout() async {
    final conn = state.connection;
    try {
      await conn?.api.logout();
    } catch (_) {
      // 登出失败不该阻塞本地清理
    }
    // 先摘钩子再关连接：登出后旧会话的 119 不该再触发任何登录
    final api = conn?.api;
    if (api != null) {
      api.onSessionExpired = null;
      api.onSessionLost = null;
    }
    try {
      await conn?.api.transport.close();
    } catch (_) {
      // 连接已经断了也不影响本地清理
    }
    // 登出 → 原生媒体栈的 TLS 政策也还原成平台默认（别把放宽留给下一个会话）。
    // 同 connect：**不 await**（通道缺席时它会挂着，登出不能被它拖住）。
    unawaited(MediaTlsPolicy.clear());
    // ★★★ 必须先清身份：否则 A 的管理员身份会留给 B ⇒ 权限泄漏。
    // 放在这里（而不是等 connection 置空）是为了让界面**立刻**收起管理入口，
    // 不用等 provider 的依赖链自己重算。
    try {
      ref.read(adminIdentityProvider.notifier).clear();
    } catch (_) {
      // provider 尚未初始化（例如测试里没挂 scope）也不该阻塞登出
    }
    _account = null;
    _password = null;
    _otp = null;
    _did = null;
    _rememberDevice = false;
    _activeNasId = null;
    // 「登出」= 本机不再保留这次登录（否则冷启动又会静默登回去）。
    // 多 NAS 下只清**当前这一条**的凭据并把"当前"置空，别的 NAS 配置原样保留。
    try {
      await _registry.clearActive();
    } catch (e) {
      debugPrint('[session] 清除本地登录信息失败：$e');
    }
    state = const SessionState();
  }
}

final sessionControllerProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);
