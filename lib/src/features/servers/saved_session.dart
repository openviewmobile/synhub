// "上次登录"的本地快照：服务器 + 账号 + 凭据 + 服务端发的设备令牌(did)。
//
// 为什么需要它：原版（`PreferenceHelper`/`PreferencesHelper.getAccount()`）把
// 「上次连的服务器 + 账号」记在本地，App 冷启动时直接静默重登，用户不用再走
// 一遍 QuickConnect。我们之前把凭据**只放在内存**里（`SessionController` 的
// 注释），于是杀掉进程重开就回到连接页 —— 这一份就是补上落盘那一半。
//
// 两个刻意的设计：
//
// 1. **凭据单独封一层**。`password` / `otp` 打进一个 JSON，整体交给
//    [SecretKeeper]（Android 上是 `KeystoreSecretKeeper`，AES-256-GCM，密钥在
//    Android Keystore 里）；落盘的是密文。测试/桌面/`dart run` 环境没有
//    Keystore → `seal` 返回 null → **退回明文**（老行为，不能因此拒绝保存，
//    否则"记住设备"在测试机上就直接失效了）。`secret_sealed` 记录这次是哪种，
//    读回来时才不会把明文当密文去解。
//
// 2. **解不开 ≠ 没保存**。[load] 在"有记录但密文解不开"（换机/重装/Keystore
//    密钥被清）时**照旧返回记录**，只是 `password == null`：这样上层还能拿
//    服务器地址和账号去预填登录页，而不是让用户重新输一遍 QuickConnect ID。
//
// `did`：官方流程是首次登录带 `otp_code` + `enable_device_token=yes`，服务端回
// 一个 `did`，客户端存下来；下次登录带 `device_id=<did>` + `enable_device_token=yes`
// **不再要验证码**。所以这里必须把 `did` 一起持久化，`SessionController.login`
// 下次才会把它传回去。
import '../../data/e2ee/e2ee_service.dart' show E2eeStore;
import '../../data/e2ee/secret_keeper.dart';
import 'nas_store.dart';
import 'server_profile.dart';

/// 上次成功登录的快照。
///
/// 多 NAS 之后，这一份同时充当「本机保存的某个 NAS/账号」这条记录：
/// [id] 把一条记录钉死（重命名/换地址/重登都不变），[NasStore] 用它在列表里
/// 定位；老的单 NAS 记录没有 id，读回时补一个，见 [NasStore.load]。
class SavedSession {
  const SavedSession({
    this.id,
    required this.profile,
    required this.account,
    this.password,
    this.rememberDevice = false,
    this.deviceId,
    this.lastBaseUrl,
  });

  /// 稳定标识（多 NAS 列表里定位用）；老格式记录读回时由 store 补齐
  final String? id;

  /// 用户当初填的服务器（QuickConnect ID 或直连地址）
  final ServerProfile profile;

  final String account;

  /// 明文密码；`null` = 密文解不开（Keystore 丢了）→ 不能自动登录，但可预填
  final String? password;

  /// 「信任此设备 / 下次登录免验证码」开关
  final bool rememberDevice;

  /// 服务端下发的设备令牌（`SYNO.API.Auth.login` 返回的 `did` / `device_id`）
  final String? deviceId;

  /// 上次真正连上的地址（QuickConnect 会解析到一堆候选，记住探通的那个）
  final String? lastBaseUrl;

  bool get canAutoLogin => password != null && password!.isNotEmpty;

  /// 免验证码是否**真的**生效了：勾了开关 + 拿到了设备令牌
  bool get otpBypassReady =>
      rememberDevice && (deviceId != null && deviceId!.isNotEmpty);

  SavedSession copyWith({
    String? id,
    ServerProfile? profile,
    String? account,
    String? password,
    bool? rememberDevice,
    String? deviceId,
    String? lastBaseUrl,

    /// 明确把密码抹掉（`password: null` 是"不改"的意思，与 copyWith 惯例一致）
    bool clearPassword = false,
  }) {
    return SavedSession(
      id: id ?? this.id,
      profile: profile ?? this.profile,
      account: account ?? this.account,
      password: clearPassword ? null : (password ?? this.password),
      rememberDevice: rememberDevice ?? this.rememberDevice,
      deviceId: deviceId ?? this.deviceId,
      lastBaseUrl: lastBaseUrl ?? this.lastBaseUrl,
    );
  }
}

/// [SavedSession] 的落盘实现（键值表 + [SecretKeeper]）。
///
/// 这是**单条记录**的历史入口（老键 `saved_session`）。多 NAS 之后它仍然
/// 可用，但真正的列表在 [NasStore] 里：本类只负责"当前活动那条"的读写，
/// 每次写都会经 [NasStore] 同步整个列表，避免出现两套不一致的账。
class SavedSessionStore {
  SavedSessionStore(this._store, {SecretKeeper? keeper})
    : _nas = NasStore(_store, keeper: keeper);

  final E2eeStore _store;

  final NasStore _nas;

  /// 多 NAS 列表的读写（同一张键值表 + 同一个封壳）。
  ///
  /// `nasRegistryProvider` 从这里取实例，于是测试只要覆盖
  /// `savedSessionStoreProvider`（换成内存 SecretKeeper），多 NAS 也跟着走同一份。
  NasStore get nas => _nas;

  /// 键值表里的键。改格式时同时抬 [NasStore.formatVersion]。
  static const String storageKey = NasStore.legacyKey;

  /// 读回上次的登录快照；没有/坏掉返回 null。
  Future<SavedSession?> load() async {
    final raw = await _store.setting(storageKey);
    if (raw == null || raw.isEmpty) return null;
    final map = NasStore.decodeMap(raw);
    if (map == null) return null;
    // 坏数据（缺地址）→ 当没保存过，别让启动流程挂在这
    final entry = await _nas.decodeEntry(map);
    // ★ r707：这条老键也可能还是**明文行**（guest 库里实测存在）。
    //   读到的仍是原值；顺手让 `NasStore.load()` 把列表/镜像重封一次
    //   （它内部按 `secret_sealed != true` 判定，幂等且不会把能封的机器写坏）。
    if (entry != null && map['secret_sealed'] != true) {
      await _nas.load();
    }
    return entry;
  }

  /// 覆盖保存（登录成功后调）；同时更新多 NAS 列表里的活动条目。
  Future<void> save(SavedSession s) => _nas.upsertActive(s);

  /// 忘掉上次登录（登出用）：清掉活动条目的凭据，并把"当前"标为空。
  ///
  /// 条目本身留在多 NAS 列表里（用户还能在服务器页看到它、重新登录），
  /// 但 [load] 与冷启动静默重登都不会再拿它自动登。
  Future<void> clear() => _nas.clearActive();
}
