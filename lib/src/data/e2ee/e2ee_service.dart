// E2EE 身份与频道密钥管理（Phase 7）。
//
// 对应原 App 的 `PreferencesHelper.getKeyPair()` + `SodiumHelper` + 内存里的
// 频道密钥表。分工：
//
//   * **身份**（长期）：一对 X25519 密钥。私钥用口令（blake2b-256）加密后
//     自己存一份、也通过 `SYNO.Chat.User / update_key` 传到服务端，
//     换设备时输入口令即可恢复（原 App 就是这个套路）。
//   * **频道密钥**：每个加密频道一把 32 字节对称密钥。服务端为每个成员
//     存一份「用该成员公钥 seal 过的」副本（`channel_key_enc`），
//     本机从 `Channel/list` 拿到自己那一份，用私钥 `seal_open` 出来。
//   * **解锁后的私钥 / 频道密钥只在内存里**，锁屏/退出就丢。
//
// 密钥在水里游的格式见 docs/phase7-protocol.md。
import 'dart:convert';
import 'dart:typed_data';

import '../../core/crypto/sodium_crypto.dart';
import '../../core/i18n/data_text.dart';
import 'secret_keeper.dart';
import '../dto/archive_dto.dart';
import '../dto/channel_dto.dart';

/// 日志：这个文件要保持"能被 `dart run` 加载"，所以不引 `package:flutter`
/// （`debugPrint` 会把 Flutter 拖进来）。
void _log(String message) {
  // ignore: avoid_print
  print('[e2ee] $message');
}

/// [E2eeService] 需要的持久化能力，只三项。
///
/// 抽出来是为了两件事：① `ChatStore`（Drift）只是其中一种实现；
/// ② 探针/脚本可以塞个内存实现，不必把 Flutter 拖进 `dart run`（踩过：
/// 一旦 import 到 drift_flutter，`dart run` 就编不过 Flutter 的包）。
abstract interface class E2eeStore {
  Future<String?> setting(String key);
  Future<void> setSetting(String key, String value);
  Future<void> deleteSetting(String key);
}

/// 本机 E2EE 身份（持久化部分）。
class E2eeIdentity {
  const E2eeIdentity({required this.publicKey, required this.privateKeyEnc});

  /// X25519 公钥（base64），会上传给服务端
  final String publicKey;

  /// 口令加密后的私钥（base64）
  final String privateKeyEnc;

  bool get isEmpty => publicKey.isEmpty;

  Map<String, dynamic> toJson() => {
    'public_key': publicKey,
    'private_key_enc': privateKeyEnc,
  };

  static E2eeIdentity fromJson(Map<String, dynamic> json) => E2eeIdentity(
    publicKey: '${json['public_key'] ?? ''}',
    privateKeyEnc: '${json['private_key_enc'] ?? ''}',
  );
}

/// 一次「换密钥对」的结果：新身份 + 重封好的 7 个字段（[brokenChannelIds] /
/// [brokenArchiveIds] 是本来就解不开、原版也会跳过的那些）
class RenewedKeyPair {
  const RenewedKeyPair({
    required this.publicKey,
    required this.privateKey,
    required this.privateKeyEnc,
    required this.channelIds,
    required this.channelKeyEncs,
    required this.archiveIds,
    required this.archiveKeyEncs,
    this.brokenChannelIds = const [],
    this.brokenArchiveIds = const [],
  });

  final String publicKey;
  final String privateKey;
  final String privateKeyEnc;
  final List<int> channelIds;
  final List<String> channelKeyEncs;
  final List<int> archiveIds;
  final List<String> archiveKeyEncs;
  final List<int> brokenChannelIds;
  final List<int> brokenArchiveIds;
}

/// 频道密钥的可用状态（给 UI 判断「这是个解不开的频道」）。
enum ChannelKeyState { notEncrypted, ready, locked, missing }

class E2eeService {
  E2eeService(this.store, {SecretKeeper? keeper})
    : keeper = keeper ?? const NoopSecretKeeper();

  final E2eeStore store;

  /// 身份落盘前再包一层（Android 由 `e2eeServiceProvider` 注入 Keystore 实现；
  /// 探针/单测默认 [NoopSecretKeeper] = 明文，跟改造前一致）
  final SecretKeeper keeper;

  static const _identityKey = 'e2ee_identity';

  E2eeIdentity? _identity;
  String? _privateKey;
  final Map<int, Uint8List> _channelKeys = {};

  /// 写入代数：每次身份被改（setup/adopt/changePasscode/reset）+1。
  ///
  /// [load] 是异步读库，可能在一次写入**之后**才返回（真踩过：启动时的
  /// `load()` 比 `setup()` 晚落地，把刚生成的身份冲成了 null）。所以读之前
  /// 记下代数，回来时代数变了就丢弃这次结果。
  int _generation = 0;

  /// 本机身份；没设置过就是 null。
  E2eeIdentity? get identity => _identity;

  bool get isConfigured => _identity != null && !_identity!.isEmpty;

  /// 私钥是否已解锁（口令输入正确、可以解密）。
  bool get isUnlocked => _privateKey != null;

  String? get publicKey => _identity?.publicKey;
  String? get privateKey => _privateKey;

  int get cachedChannelKeyCount => _channelKeys.length;

  /// 从本地库读回身份（App 启动时调）。
  ///
  /// 存储格式两种都认：
  ///   * `{"v":2,"sealed":"…"}` —— 经 [keeper] 包过的（Android Keystore）；
  ///   * `{"public_key":…,"private_key_enc":…}` —— 早期明文格式，读到后
  ///     **顺手升级**成 v2（对齐原版"整对 keypair 一律经 Keystore 落盘"）。
  ///
  /// Keystore 密钥丢了（重装/换机）→ 解不开 → 返回 null，上层会走
  /// 「从服务端取 key_pair + 口令解锁」那条路，而不是拿半个身份继续跑。
  Future<E2eeIdentity?> load() async {
    final gen = _generation;
    final raw = await store.setting(_identityKey);
    if (gen != _generation) return _identity; // 读期间有写入，别覆盖
    if (raw == null || raw.isEmpty) {
      _identity = null;
      return null;
    }

    Map<String, dynamic>? json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      // 白名单：`_log` 只进 stdout/logcat，按 §4.3.1 的「日志串」不翻。
      _log('身份记录不是 JSON，忽略');
      _identity = null;
      return null;
    }

    if (json['sealed'] != null) {
      final opened = await keeper.open('${json['sealed']}');
      if (opened == null) {
        // Keystore 开不了：当作"本机没有身份"，交给上层从服务端恢复
        // 白名单：同上（纯日志）。
        _log('本机身份解封失败（Keystore 密钥丢了？），等待从服务端重新取 key_pair');
        _identity = null;
        return null;
      }
      try {
        _identity = E2eeIdentity.fromJson(
          Map<String, dynamic>.from(jsonDecode(opened) as Map),
        );
      } catch (_) {
        _identity = null;
        return null;
      }
      return _identity;
    }

    // 旧明文格式 → 升级
    _identity = E2eeIdentity.fromJson(json);
    await _persist(_identity!);
    return _identity;
  }

  /// 身份落盘（统一出口）：能封就封，封不了退回明文（桌面/测试/无 Keystore）
  Future<void> _persist(E2eeIdentity identity) async {
    final plain = jsonEncode(identity.toJson());
    final sealed = await keeper.seal(plain);
    final record = sealed == null
        ? plain
        : jsonEncode({'v': 2, 'sealed': sealed});
    await store.setSetting(_identityKey, record);
  }

  /// 用服务端那份身份覆盖本地缓存（换设备/服务端已有 key_pair 时用）。
  Future<E2eeIdentity> adoptServerIdentity(E2eeIdentity server) async {
    _generation++;
    _identity = server;
    await _persist(server);
    return server;
  }

  /// 第一次设置 E2EE：生成密钥对，用口令保护私钥，存本地。
  ///
  /// 返回的身份要交给 `ChatApi.updateKey` 上传。
  Future<E2eeIdentity> setup(String passcode) async {
    if (passcode.isEmpty) {
      throw SodiumException(dataText('e2eePasscodeRequired', '口令不能为空'));
    }
    _generation++;
    final pair = SodiumCrypto.generateKeyPair();
    final identity = E2eeIdentity(
      publicKey: pair.publicKey,
      privateKeyEnc: SodiumCrypto.encryptPrivateKey(pair.privateKey, passcode),
    );
    _identity = identity;
    await _persist(identity);
    _privateKey = pair.privateKey; // 设置完直接就是解锁状态
    return identity;
  }

  /// 输入口令解锁私钥（口令错了抛 [SodiumException]）。
  Future<String> unlock(String passcode) async {
    final id = _identity;
    if (id == null || id.privateKeyEnc.isEmpty) {
      throw SodiumException(dataText('e2eeNoIdentity', '还没有设置 E2EE 身份'));
    }
    final key = SodiumCrypto.decryptPrivateKey(id.privateKeyEnc, passcode);
    _privateKey = key;
    return key;
  }

  /// 换口令：把私钥重新加密一遍（原 App 的 changePasscode）。
  Future<E2eeIdentity> changePasscode({
    required String oldPasscode,
    required String newPasscode,
  }) async {
    final privateKey = await unlock(oldPasscode);
    _generation++;
    final id = E2eeIdentity(
      publicKey: _identity!.publicKey,
      privateKeyEnc: SodiumCrypto.encryptPrivateKey(privateKey, newPasscode),
    );
    _identity = id;
    await _persist(id);
    return id;
  }

  /// 锁上：私钥与所有频道密钥从内存抹掉。
  void lock() {
    _privateKey = null;
    _channelKeys.clear();
  }

  /// 彻底清掉本机身份（服务端那份要另外处理）。
  Future<void> reset() async {
    _generation++;
    lock();
    _identity = null;
    await store.deleteSetting(_identityKey);
  }

  // ------------------------------------------------------------ 频道密钥

  /// 某个频道的密钥状态。
  ChannelKeyState keyState(ChannelDto channel) {
    if (!channel.encrypted) return ChannelKeyState.notEncrypted;
    if (_channelKeys.containsKey(channel.channelId)) {
      return ChannelKeyState.ready;
    }
    return isUnlocked ? ChannelKeyState.missing : ChannelKeyState.locked;
  }

  Uint8List? channelKey(int channelId) => _channelKeys[channelId];

  /// 把一份 `channel_key_enc`（用我公钥 seal 的）解出来并缓存。
  ///
  /// 解不开（密钥对换了 / 不是封给我的）返回 false，频道就是「broken」。
  bool loadChannelKey(int channelId, String channelKeyEnc) {
    if (channelKeyEnc.isEmpty || !isUnlocked) return false;
    try {
      final plain = SodiumCrypto.sealDecrypt(
        base64Decode(channelKeyEnc),
        publicKeyBase64: _identity!.publicKey,
        privateKeyBase64: _privateKey!,
      );
      final key = _openChannelKey(plain);
      if (key == null) return false;
      _channelKeys[channelId] = key;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 从频道列表里把所有能解的频道密钥解出来。
  ///
  /// 返回「解不开的加密频道 id」（原 App 的 broken channel）。
  List<int> loadChannelKeys(List<ChannelDto> channels) {
    final broken = <int>[];
    for (final c in channels) {
      if (!c.encrypted) continue;
      if (!loadChannelKey(c.channelId, c.channelKeyEnc)) {
        broken.add(c.channelId);
      }
    }
    return broken;
  }

  /// 直接塞一份明文频道密钥（本地新建频道时，钥匙本来就在手里）。
  void putChannelKey(int channelId, List<int> key) {
    _channelKeys[channelId] = Uint8List.fromList(key);
  }

  /// 生成一把新频道密钥，并返回「封给 [recipientPublicKeys] 里每个人的副本」。
  ///
  /// 返回的列表顺序与入参一致，直接就是 `initiate` / `update_key` 要的
  /// `channel_key_encs`。
  ({Uint8List key, List<String> sealedKeys}) newChannelKey(
    List<String> recipientPublicKeys,
  ) {
    final key = SodiumCrypto.randomBytes(kSecretboxKeyBytes);
    final sealed = recipientPublicKeys
        .map((pk) => _sealChannelKey(key, pk))
        .toList();
    return (key: key, sealedKeys: sealed);
  }

  /// 把已有频道密钥封给某个成员（rescue / 邀请新成员用）。
  String sealChannelKey(int channelId, String recipientPublicKey) {
    final key = _channelKeys[channelId];
    if (key == null) {
      throw SodiumException(
        dataText('e2eeNoChannelKeySeal', '本地没有这个频道的密钥，封不了'),
      );
    }
    return _sealChannelKey(key, recipientPublicKey);
  }

  /// 原 App 的**在途格式**：频道密钥先 base64 成 44 字符文本，再 seal 这段文本
  /// （`ChatSodiumUtil.genChannelKey` = `Base64.encodeToString(random32, NO_WRAP)`，
  /// `encryptBase64ChannelKey` 对它 `getBytes(UTF_8)` 之后才 `crypto_box_seal`；
  /// 解密侧 `PostHelper` 也把它当 base64 文本再 decode 回 32 字节）。
  ///
  /// 早期纯 Dart 实现直接 seal 了 32 字节原始密钥 —— 那样只有我们自己能解开，
  /// 官方客户端（或官方 re-key 后的服务端密钥）会解不开，属于互操作 bug。
  /// 现在**发出去的一律是原 App 格式**，读取时两种都认（兼容已分发的老密钥）。
  String _sealChannelKey(List<int> rawKey, String recipientPublicKey) =>
      SodiumCrypto.sealEncrypt(
        utf8.encode(base64Encode(rawKey)),
        recipientPublicKey,
      );

  /// 解开一份频道密钥（原 App 的 base64 文本格式，或我们早期的 32 字节裸格式）
  Uint8List? _openChannelKey(List<int> plain) {
    if (plain.length == kSecretboxKeyBytes) {
      return Uint8List.fromList(plain); // 旧格式（我们自己 re-key 的分支）
    }
    try {
      final decoded = base64Decode(utf8.decode(plain));
      if (decoded.length == kSecretboxKeyBytes) {
        return Uint8List.fromList(decoded);
      }
    } catch (_) {
      // 不是 base64 文本，交给调用方判 broken
    }
    return null;
  }

  // ------------------------------------------------------------ 消息 / 文件

  /// 加密一条消息（频道没解锁/没钥匙时抛 [SodiumException]）。
  String encryptMessage(int channelId, String text) {
    final key = _channelKeys[channelId];
    if (key == null) {
      throw SodiumException(
        dataText('e2eeNoChannelKeyToEncrypt', '没有频道密钥，不能发到加密频道'),
      );
    }
    return SodiumCrypto.secretboxEncrypt(utf8.encode(text), key);
  }

  /// 解密一条消息。解不开时返回 null，调用方好显示「无法解密」。
  String? tryDecryptMessage(int channelId, String message) {
    final key = _channelKeys[channelId];
    if (key == null || message.isEmpty) return null;
    try {
      return utf8.decode(
        SodiumCrypto.secretboxDecryptRaw(message, key),
        allowMalformed: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// 加密文件名（hex）。
  String encryptFileName(int channelId, String name) {
    final key = _channelKeys[channelId];
    if (key == null) {
      throw SodiumException(dataText('e2eeNoChannelKey', '没有频道密钥'));
    }
    return SodiumCrypto.encryptFileNameHex(name, key);
  }

  /// 解密文件名；解不开返回 null（调用方退回穿原始 hex 或占位文案）。
  String? tryDecryptFileName(int channelId, String encodedName) {
    final key = _channelKeys[channelId];
    if (key == null || encodedName.isEmpty) return null;
    try {
      return SodiumCrypto.decryptFileNameHex(encodedName, key);
    } catch (_) {
      return null;
    }
  }

  /// 加密文件体。
  Uint8List encryptFileBytes(int channelId, List<int> body) {
    final key = _channelKeys[channelId];
    if (key == null) {
      throw SodiumException(dataText('e2eeNoChannelKey', '没有频道密钥'));
    }
    return SodiumCrypto.encryptFileBytes(body, key);
  }

  /// 解密文件体；解不开返回 null。
  Uint8List? tryDecryptFileBytes(int channelId, List<int> raw) {
    final key = _channelKeys[channelId];
    if (key == null || raw.isEmpty) return null;
    try {
      return SodiumCrypto.decryptFileBytes(raw, key);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ 上传 / 恢复

  /// `update_key` 要的「我这个成员在加密频道/归档里的密钥副本」。
  ({List<int> channelIds, List<String> channelKeyEncs}) myKeyEncs(
    List<ChannelDto> channels,
  ) {
    final ids = <int>[];
    final encs = <String>[];
    final id = _identity;
    if (id == null) return (channelIds: ids, channelKeyEncs: encs);
    for (final c in channels) {
      final key = _channelKeys[c.channelId];
      if (key == null) continue;
      ids.add(c.channelId);
      encs.add(_sealChannelKey(key, id.publicKey));
    }
    return (channelIds: ids, channelKeyEncs: encs);
  }

  /// 归档频道要的 `archive_ids` / `archive_key_encs`。
  ///
  /// 归档其实是「被归档的加密频道」，钥匙还是那把频道密钥，
  /// 只是换了个 id 字段上报（反编译 `AccountManager.renewKey` 里两段循环
  /// 几乎一样，唯一区别就是 `archive_id` 与 `channel_id`）。
  ({List<int> archiveIds, List<String> archiveKeyEncs}) archiveKeyEncs(
    List<ArchiveDto> archives,
  ) {
    final ids = <int>[];
    final encs = <String>[];
    final id = _identity;
    if (id == null) return (archiveIds: ids, archiveKeyEncs: encs);
    for (final a in archives) {
      final key = _channelKeys[a.channel.channelId];
      if (key == null) continue;
      ids.add(a.archiveId);
      encs.add(_sealChannelKey(key, id.publicKey));
    }
    return (archiveIds: ids, archiveKeyEncs: encs);
  }

  // ------------------------------------------------------ 换密钥对（renew_key）

  /// 生成一对**新**密钥对，并把所有能解的频道/归档密钥改成封给新公钥。
  ///
  /// 对齐原版 `RenewKeyPresenter.renewKey()` + `AccountManager.renewKey()`：
  ///   1. 用口令解开旧私钥（**只是校验口令**，结果不参与重封）；
  ///   2. `generateKeyPair()` 造新对，新私钥仍是同一个口令加密；
  ///   3. 遍历**本地库里的加密频道**：用**旧** keypair 解出频道密钥，
  ///      再用**新**公钥 seal 一份；归档同理（`archive_ids` 一组）；
  ///   4. 返回 7 个字段，调用方交给 `SYNO.Chat.User / update_key` v2 上报，
  ///      成功后再 [adoptRenewedIdentity] 落地新身份。
  ///
  /// ⚠️ 这一步不会自己写库/上报 —— 失败时旧身份必须仍然可用。
  Future<RenewedKeyPair> renewKeyPair({
    required String passcode,
    required List<ChannelDto> channels,
    List<ArchiveDto> archives = const [],
  }) async {
    final id = _identity;
    if (id == null || id.privateKeyEnc.isEmpty) {
      throw SodiumException(dataText('e2eeNoIdentity', '还没有设置 E2EE 身份'));
    }
    final oldPrivateKey = await unlock(passcode); // 口令错 → SodiumException
    if (passcode.isEmpty) {
      throw SodiumException(dataText('e2eePasscodeRequired', '口令不能为空'));
    }

    final pair = SodiumCrypto.generateKeyPair();
    final newPrivateKeyEnc = SodiumCrypto.encryptPrivateKey(
      pair.privateKey,
      passcode,
    );

    final channelIds = <int>[];
    final channelKeyEncs = <String>[];
    final brokenChannels = <int>[];
    for (final c in channels) {
      if (!c.encrypted) continue;
      final raw = _openWithKeyPair(
        c.channelKeyEnc,
        publicKey: id.publicKey,
        privateKey: oldPrivateKey,
      );
      if (raw == null) {
        // 解不开的（本来就是 broken）跳过，别把它写成"已重封"
        brokenChannels.add(c.channelId);
        continue;
      }
      channelIds.add(c.channelId);
      channelKeyEncs.add(_sealChannelKey(raw, pair.publicKey));
    }

    final archiveIds = <int>[];
    final archiveKeyEncs = <String>[];
    final brokenArchives = <int>[];
    for (final a in archives) {
      if (!a.channel.encrypted) continue;
      final raw = _openWithKeyPair(
        a.channel.channelKeyEnc,
        publicKey: id.publicKey,
        privateKey: oldPrivateKey,
      );
      if (raw == null) {
        brokenArchives.add(a.archiveId);
        continue;
      }
      archiveIds.add(a.archiveId);
      archiveKeyEncs.add(_sealChannelKey(raw, pair.publicKey));
    }

    return RenewedKeyPair(
      publicKey: pair.publicKey,
      privateKey: pair.privateKey,
      privateKeyEnc: newPrivateKeyEnc,
      channelIds: channelIds,
      channelKeyEncs: channelKeyEncs,
      archiveIds: archiveIds,
      archiveKeyEncs: archiveKeyEncs,
      brokenChannelIds: brokenChannels,
      brokenArchiveIds: brokenArchives,
    );
  }

  /// 上报成功后落地新身份（原版 `PreferencesHelper.setBase64KeyPair`）：
  /// 内存里的频道密钥不用动（明文没变），私钥换成新的、保持解锁。
  Future<void> adoptRenewedIdentity(RenewedKeyPair renewed) async {
    _generation++;
    final id = E2eeIdentity(
      publicKey: renewed.publicKey,
      privateKeyEnc: renewed.privateKeyEnc,
    );
    _identity = id;
    _privateKey = renewed.privateKey;
    await _persist(id);
  }

  /// 用**指定**的密钥对解一份 `channel_key_enc`（换密钥对时用的是旧对，
  /// 而 [loadChannelKey] 用的是当前身份）
  Uint8List? _openWithKeyPair(
    String channelKeyEnc, {
    required String publicKey,
    required String privateKey,
  }) {
    if (channelKeyEnc.isEmpty) return null;
    try {
      final plain = SodiumCrypto.sealDecrypt(
        base64Decode(channelKeyEnc),
        publicKeyBase64: publicKey,
        privateKeyBase64: privateKey,
      );
      return _openChannelKey(plain);
    } catch (_) {
      return null;
    }
  }

  /// 从归档列表里解出频道密钥；返回解不开的归档 id（对齐 broken channel）。
  List<int> loadArchiveKeys(List<ArchiveDto> archives) {
    final broken = <int>[];
    for (final a in archives) {
      if (!a.channel.encrypted) continue;
      if (!loadChannelKey(a.channel.channelId, a.channel.channelKeyEnc)) {
        broken.add(a.archiveId);
      }
    }
    return broken;
  }
}
