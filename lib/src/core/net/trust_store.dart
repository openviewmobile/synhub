// Phase 9：证书信任（对齐原版 `sylibx/sycertificatemanager` 的首连信任流程）。
//
// 原版行为（`AbstractCertificateUtil.java:100-204` + `CertificateStorageManager`）：
//   * TLS 握手失败（`SSLHandshakeException` / `SSLPeerUnverifiedException`）时，
//     按 **用户输入的地址** 去信任库里找证书；
//   * 找不到或指纹对不上 → 弹信任对话框（展示证书详情），用户点"信任"才入库；
//   * 信任库以 `(sha256, userInputAddress)` 为键去重（`getTrustedCertificateItem`）。
//
// Flutter 这边的约束：`HttpClient.badCertificateCallback` 是**同步**回调，弹不了框。
// 所以流程拆成两步：
//   1. 同步回调里只做判断 —— 指纹已信任就放行，否则**记下挑战并拒绝握手**；
//   2. 上层（连接流程）拿到挑战后弹框，用户同意就入库并**重试这一次连接**。
// 这样"首次连接必须经过用户确认"这条语义是真的落地的，不是无条件放行。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pointycastle/digests/sha256.dart';

/// 信任库需要的**最小**存储接口。
///
/// 故意不直接依赖 Drift 的 `ChatStore`：一来 `TrustPolicy` 就成了纯 Dart
/// （probe 脚本能用 `dart run` 跑），二来测试里塞个内存实现就行。
abstract interface class TrustStoreBackend {
  Future<String?> setting(String key);
  Future<void> setSetting(String key, String value);
  Future<void> deleteSetting(String key);
  Future<Map<String, String>> allSettings();
}

/// 一条已信任的证书
class TrustedCert {
  const TrustedCert({
    required this.host,
    required this.sha256,
    required this.savedAt,
    this.subject = '',
    this.issuer = '',
  });

  /// `host:port`（原版的 `userInputAddress`）
  final String host;

  /// 证书 DER 的 SHA-256，**大写十六进制**（跟原版展示一致）
  final String sha256;
  final DateTime savedAt;
  final String subject;
  final String issuer;

  Map<String, dynamic> toJson() => {
    'host': host,
    'sha256': sha256,
    'saved_at': savedAt.millisecondsSinceEpoch,
    'subject': subject,
    'issuer': issuer,
  };

  static TrustedCert? tryParse(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final host = '${m['host'] ?? ''}';
      final fp = '${m['sha256'] ?? ''}';
      if (host.isEmpty || fp.isEmpty) return null;
      return TrustedCert(
        host: host,
        sha256: fp,
        savedAt: DateTime.fromMillisecondsSinceEpoch(
          (m['saved_at'] as num?)?.toInt() ?? 0,
        ),
        subject: '${m['subject'] ?? ''}',
        issuer: '${m['issuer'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'TrustedCert($host, $sha256)';
}

/// 一次"要不要信任"的待决挑战
class TrustChallenge {
  const TrustChallenge({
    required this.host,
    required this.sha256,
    required this.subject,
    required this.issuer,
    required this.validFrom,
    required this.validTo,
    this.changedFrom,
    this.isSelfSigned = false,
  });

  final String host;
  final String sha256;
  final String subject;
  final String issuer;
  final DateTime validFrom;
  final DateTime validTo;

  /// 之前信任过的指纹（非空 = **证书换了**，这是最需要警惕的情况）
  final String? changedFrom;

  final bool isSelfSigned;

  bool get isChanged => changedFrom != null;

  bool get isExpired => DateTime.now().isAfter(validTo);

  /// `AB:CD:EF:…` 形式（原版对话框就是按字节展示）
  String get grouped => sha256
      .replaceAllMapped(RegExp(r'.{2}'), (m) => '${m[0]}:')
      .replaceAll(RegExp(r':$'), '');

  @override
  String toString() =>
      'TrustChallenge($host, $sha256${isChanged ? ', changed' : ''})';
}

/// 证书里我们关心的那几个字段（抽出来是为了能脱离真实握手做单测）
class CertInfo {
  const CertInfo({
    required this.der,
    required this.subject,
    required this.issuer,
    required this.validFrom,
    required this.validTo,
  });

  factory CertInfo.fromX509(X509Certificate cert) => CertInfo(
    der: cert.der,
    subject: cert.subject,
    issuer: cert.issuer,
    validFrom: cert.startValidity,
    validTo: cert.endValidity,
  );

  final Uint8List der;
  final String subject;
  final String issuer;
  final DateTime validFrom;
  final DateTime validTo;

  String get sha256 => TrustPolicy.sha256Hex(der);

  bool get isSelfSigned => subject == issuer;
}

/// 谁问用户（UI 层注册；测试里注入假实现）
typedef TrustPrompt = Future<bool> Function(TrustChallenge challenge);

/// 把 `(cert, host)` 变成"放行/不放行"，并记录待决挑战。
class TrustPolicy {
  TrustPolicy(this.store, {this.prompt});

  final TrustStoreBackend store;

  /// 弹框问用户。为 null 时（后台任务、单元测试）一律**拒绝**，安全优先。
  TrustPrompt? prompt;

  final Map<String, TrustChallenge> _pending = {};

  static const String keyPrefix = 'trusted_cert.';

  static String hostKey(String host) => host.toLowerCase();

  /// 从任意键值存储构造（`ChatStore` 结构上就满足 [TrustStoreBackend]）
  factory TrustPolicy.of({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    required Future<void> Function(String key) remove,
    required Future<Map<String, String>> Function() all,
    TrustPrompt? prompt,
  }) => TrustPolicy(
    _FunctionBackend(read: read, write: write, remove: remove, all: all),
    prompt: prompt,
  );

  /// 同步握手回调：已信任且指纹一致 → true；否则记挑战 + false。
  bool evaluate(X509Certificate cert, String host, int port) =>
      evaluateInfo(CertInfo.fromX509(cert), host, port);

  /// [evaluate] 的本体（可脱离真实握手测试）
  bool evaluateInfo(CertInfo info, String host, int port) {
    final address = hostKey('$host:$port');
    final sha = info.sha256;
    final known = _cached[address];
    if (known != null && known == sha) return true;

    _pending[address] = TrustChallenge(
      host: address,
      sha256: sha,
      subject: info.subject,
      issuer: info.issuer,
      validFrom: info.validFrom,
      validTo: info.validTo,
      changedFrom: known,
      isSelfSigned: info.isSelfSigned,
    );
    return false;
  }

  /// 内存里已信任的指纹（测试/诊断用）
  String? trustedInMemory(String host) => _cached[hostKey(host)];

  /// 直接塞一个待决挑战（测试连接层的重试链路用）
  @visibleForTesting
  void noteChallengeForTest(TrustChallenge ch) {
    _pending[hostKey(ch.host)] = ch;
  }

  /// 内存里的指纹表（`load()` 填充；`bytes` 变化时刷新）
  final Map<String, String> _cached = {};

  bool _loaded = false;

  /// 把信任库读进内存（连接前调一次）
  Future<void> load() async {
    _cached.clear();
    for (final c in await trusted()) {
      _cached[hostKey(c.host)] = c.sha256;
    }
    _loaded = true;
  }

  bool get isLoaded => _loaded;

  Future<List<TrustedCert>> trusted() async {
    final all = await store.allSettings();
    final out = <TrustedCert>[];
    for (final e in all.entries) {
      if (!e.key.startsWith(keyPrefix)) continue;
      final c = TrustedCert.tryParse(e.value);
      if (c != null) out.add(c);
    }
    out.sort((a, b) => a.host.compareTo(b.host));
    return out;
  }

  Future<TrustedCert?> find(String host) async {
    final raw = await store.setting('$keyPrefix${hostKey(host)}');
    if (raw == null || raw.isEmpty) return null;
    return TrustedCert.tryParse(raw);
  }

  /// 用户点了"信任"：入库 + 刷新内存缓存
  Future<void> trust(TrustChallenge ch) async {
    final cert = TrustedCert(
      host: hostKey(ch.host),
      sha256: ch.sha256,
      savedAt: DateTime.now(),
      subject: ch.subject,
      issuer: ch.issuer,
    );
    await store.setSetting('$keyPrefix${cert.host}', jsonEncode(cert.toJson()));
    _cached[cert.host] = cert.sha256;
    _pending.remove(hostKey(ch.host));
  }

  /// 删除一条信任（"证书管理"页用）
  Future<void> forget(String host) async {
    await store.setSetting('$keyPrefix${hostKey(host)}', '');
    _cached.remove(hostKey(host));
  }

  TrustChallenge? pendingFor(String host, [int? port]) {
    final key = port == null ? hostKey(host) : hostKey('$host:$port');
    return _pending[key] ?? _pending[hostKey(host)];
  }

  void clearPending() => _pending.clear();

  /// 走一遍"问用户 → 入库/拒绝"，返回是否已信任。
  Future<bool> decide(TrustChallenge ch) async {
    final ask = prompt;
    if (ask == null) return false;
    final ok = await ask(ch);
    if (ok) await trust(ch);
    return ok;
  }

  /// 证书 DER 的 SHA-256（大写十六进制，跟原版 `CertificateItem.sha256` 同构）
  static String fingerprintOf(X509Certificate cert) => sha256Hex(cert.der);

  static String sha256Hex(Uint8List der) {
    final digest = SHA256Digest().process(der);
    final sb = StringBuffer();
    for (final b in digest) {
      sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return sb.toString();
  }
}

/// 用四个函数凑一个 [TrustStoreBackend]（`TrustPolicy.of` 用）
class _FunctionBackend implements TrustStoreBackend {
  _FunctionBackend({
    required this.read,
    required this.write,
    required this.remove,
    required this.all,
  });

  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String value) write;
  final Future<void> Function(String key) remove;
  final Future<Map<String, String>> Function() all;

  @override
  Future<String?> setting(String key) => read(key);

  @override
  Future<void> setSetting(String key, String value) => write(key, value);

  @override
  Future<void> deleteSetting(String key) => remove(key);

  @override
  Future<Map<String, String>> allSettings() => all();
}
