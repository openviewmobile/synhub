// DSM Mock Server 的**核心**（不含 HTTP，纯逻辑 + 目录校验）。
//
// ## 为什么要有它（用户 2026-09-23 新规，原话）
// > 涉及管理员的接口，在电脑上搭建 mock server 模拟测试，**必须通过模拟测试**，
// > 接口定义以及服务端返回数据可以通过反编译 spk 以及 apk 来获取。
// > 改完之后就是所有的客户端功能必须都要实现并验证，**一个都不能遗漏**，
// > 那些无法验证的也都通过模拟服务器来验证。
//
// ## 权威性从哪来
// `tool/mock_dsm/catalog.json` 是 `build_catalog.py` 从**反编译 SPK 的
// `webapi/*.lib`**（Synology 自己发布的方法/版本表 JSON）汇总出来的：
//   * 每个 API 的 `minVersion` / `maxVersion`；
//   * **每个版本里到底有哪几个方法**（Synology 的方法分散在各版本，
//     照 `maxVersion` 协商会吃 `103`）；
//   * `authLevel` + `allowUser` ⇒ 判定 `normal`（普通用户可用）/
//     `adminOnly`（**仅管理员** —— 真机上我们非管理员根本验不了，正是
//     mock 存在的理由）。
//
// ## 它最重要的性质：**会拒绝错的调用**
// 这个 mock 不是"什么都回成功"的假桩 —— 它按权威目录**逐条校验**：
//   * API 不在目录 ⇒ `101`；
//   * `version` 不在这个 API 的版本集合里 ⇒ `103`；
//   * `method` 不在这个版本的**方法清单**里 ⇒ `103`（这就是"只按 maxVersion
//     协商"的经典翻车点，普通假桩测不出来）；
//   * `authLevel > 0` 但没登录 ⇒ `119`；
//   * **仅管理员**的 API 用非管理员会话调 ⇒ `105`。
// 所以用例跑通 = 客户端用的 api/version/method 组合**真的合法**。
//
// ## 管理员怎么办（新规的核心）
// 目录里 `adminOnly: true` 的 API（第 260 轮回算 **409 个**；目录增长会变）在真机上验不了。
// Mock 里用 `loginAsAdmin()` 建一个管理员会话即可调用 —— 于是
// "客户端有没有正确调用管理员接口"变成**可测**的。
import 'dart:convert';
import 'dart:io';

/// 目录里一个 API 的权威定义。
class DsmApiSpec {
  DsmApiSpec({
    required this.name,
    required this.minVersion,
    required this.maxVersion,
    required this.authLevel,
    required this.allowUser,
    required this.normal,
    required this.adminOnly,
    required this.methods,
    required this.methodsVerified,
    required this.source,
    this.requestFormat,
  });

  factory DsmApiSpec.fromJson(String name, Map<String, dynamic> json) {
    final raw = (json['methods'] as Map?) ?? const {};
    return DsmApiSpec(
      name: name,
      minVersion: (json['minVersion'] as num?)?.toInt() ?? 1,
      maxVersion: (json['maxVersion'] as num?)?.toInt() ?? 1,
      authLevel: (json['authLevel'] as num?)?.toInt() ?? 1,
      allowUser: ((json['allowUser'] as List?) ?? const [])
          .map((e) => '$e')
          .toList(),
      normal: json['normal'] == true,
      adminOnly: json['adminOnly'] == true,
      methodsVerified: json['methodsVerified'] != false,
      source: '${json['source'] ?? 'spk'}',
      // 活服务器 `SYNO.API.Info` 里那条 `requestFormat`（`"JSON"` 才给）。
      // App 侧据此决定参数值编码（官方《DS file》规则，见 `_additional`）；
      // mock 必须跟着一起给，否则 mock 与真机的请求形状会不一致。
      requestFormat: json['requestFormat'] == 'JSON' ? 'JSON' : null,
      methods: {
        for (final e in raw.entries)
          int.parse('${e.key}'): ((e.value as List?) ?? const [])
              .map((m) => '$m')
              .toList(),
      },
    );
  }

  final String name;
  final int minVersion;
  final int maxVersion;
  final int authLevel;
  final List<String> allowUser;

  /// `allowUser` 里有 `normal.*` ⇒ 普通用户可用。
  final bool normal;

  /// 只有 `admin.*`、没有 `normal.*` ⇒ **仅管理员**（新规要求也要 mock 验证）。
  final bool adminOnly;

  /// `版本 → 该版本存在的方法名`（可能为空：实况快照没有方法表）。
  final Map<int, List<String>> methods;

  /// `SYNO.API.Info` 的 `requestFormat`（`null` = 表单格式）。
  final String? requestFormat;

  /// 方法名**可不可校验**。
  ///
  /// `false` = 这条来自实况快照（`test/fixtures/api_table.json`，只有
  /// path/minVersion/maxVersion）⇒ mock **不校验方法名**，只校验 API 是否存在
  /// 与版本区间。**不假装能校验没有数据的东西。**
  final bool methodsVerified;

  /// `spk`（有方法表）或 `live`（实况快照）。
  final String source;

  /// 这个 API 在方法表里**列举过**的所有版本（升序）。
  List<int> get versions => methods.keys.toList()..sort();

  /// 把请求版本解析到"方法表里真正列过的、≤ 请求版本的那个版本"。
  ///
  /// ## 为什么需要这一步（**真实数据逼出来的**）
  /// 反编译 SPK 里有 **13 个 API 声明 `maxVersion=2` 但方法表只有 `"1"`**
  /// （`SYNO.ActiveInsight.*`、`SYNO.Backup.Config.*`、`SYNO.Contacts.Info`…）。
  /// 也就是说 `maxVersion` 只是**对外宣称**的版本区间，方法表才是"哪一版真有哪些方法"。
  /// DSM 服务端对 v2 的请求会回落到 v1 的处理函数。
  ///
  /// 所以 mock 的判定必须是：**版本落在 `[minVersion, maxVersion]` 内即合法**，
  /// 方法在这个版本或它以下最近的已列版本里找。直接拿 `methods[version]`
  /// 会在这些 API 上误报 103（我第一版就是这么错的，被自己的自测抓住）。
  int? resolveMethodVersion(int version) {
    int? best;
    for (final v in versions) {
      if (v <= version && (best == null || v > best)) best = v;
    }
    return best;
  }

  bool hasMethod(int version, String method) {
    final v = resolveMethodVersion(version);
    return v != null && (methods[v]?.contains(method) ?? false);
  }

  /// 某版本实际生效的方法清单（解析后的）。
  List<String> methodsAt(int version) {
    final v = resolveMethodVersion(version);
    return v == null ? const [] : (methods[v] ?? const []);
  }

  /// 哪些版本有 [method]（排障/用例里给"候选版本"用）。
  List<int> versionsWith(String method) =>
      versions.where((v) => hasMethod(v, method)).toList();

  /// cgi 路径（`query.cgi` / `auth.cgi` / `entry.cgi`）——与真实 DSM 一致。
  String get path {
    switch (name) {
      case 'SYNO.API.Info':
        return 'query.cgi';
      case 'SYNO.API.Auth':
        return 'auth.cgi';
      case 'SYNO.API.Encryption':
        return 'encryption.cgi';
      default:
        return 'entry.cgi';
    }
  }

  /// `SYNO.API.Info` 回包里的那条记录。
  Map<String, dynamic> toInfoEntry() => {
    'path': path,
    'minVersion': minVersion,
    'maxVersion': maxVersion,
    // 只有真正需要授权的 API 才回 `authLevel`（真实 DSM 也是挑着给）。
    if (authLevel > 0) 'authLevel': authLevel,
    // 同上：真实 DSM 也只挑着给 `requestFormat`（本会话实测
    // `SYNO.Core.ExternalDevice.Storage.USB` 给了、`SYNO.FileStation.List` 没给）。
    if (requestFormat != null) 'requestFormat': requestFormat,
  };
}

/// 整个权威目录。
class DsmCatalog {
  DsmCatalog({required this.apis, required this.apiCount, this.source});

  factory DsmCatalog.fromJson(Map<String, dynamic> json, {String? source}) {
    final raw = (json['apis'] as Map?) ?? const {};
    return DsmCatalog(
      apis: {
        for (final e in raw.entries)
          e.key: DsmApiSpec.fromJson(
            '${e.key}',
            Map<String, dynamic>.from(e.value as Map),
          ),
      },
      apiCount: (json['apiCount'] as num?)?.toInt() ?? raw.length,
      source: source,
    );
  }

  /// 从仓库里的 `catalog.json` 读（用例与 CLI 都用它，保证同一份事实）。
  static DsmCatalog load({String? path}) {
    final p = path ?? '${_repoRoot()}/tool/mock_dsm/catalog.json';
    final f = File(p);
    if (!f.existsSync()) {
      throw StateError('目录不存在：$p\n先跑 `python3 tool/mock_dsm/build_catalog.py`');
    }
    return DsmCatalog.fromJson(
      Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map),
      source: p,
    );
  }

  /// 定位仓库根：从当前工作目录往上找 `pubspec.yaml`。
  static String _repoRoot() {
    var dir = Directory.current;
    for (var i = 0; i < 8; i++) {
      if (File('${dir.path}/pubspec.yaml').existsSync()) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return Directory.current.path;
  }

  final Map<String, DsmApiSpec> apis;
  final int apiCount;
  final String? source;

  DsmApiSpec? operator [](String api) => apis[api];

  /// 方法名**不可校验**的条目（实况快照来的）——报告里要单独列，别混进"已验证"。
  List<DsmApiSpec> get methodUnverifiable =>
      apis.values.where((a) => !a.methodsVerified).toList();

  List<DsmApiSpec> get normalOnly =>
      apis.values.where((a) => a.normal).toList();
  List<DsmApiSpec> get adminOnly =>
      apis.values.where((a) => a.adminOnly).toList();
}

/// 一次请求的处置结果（含"为什么"），便于用例给出可读断言。
class MockDsmResponse {
  const MockDsmResponse(this.json, {this.note});

  /// 给客户端的 JSON 信封（`{success, data}` 或 `{success, error}`）。
  final Map<String, dynamic> json;

  /// 排障说明（不进响应体）。
  final String? note;

  bool get ok => json['success'] == true;
  int? get errorCode => (json['error'] as Map?)?['code'] as int?;

  @override
  String toString() =>
      'MockDsmResponse(${jsonEncode(json)}${note == null ? '' : ' // $note'})';
}

/// Mock Server 的**后端**：目录校验 + 会话 + 夹具。
///
/// 它把真实 DSM 的行为按权威事实复刻到"够用来证明客户端正确"的程度。
class MockDsmBackend {
  MockDsmBackend({
    required this.catalog,
    this.synthesizeSessionIdentity = false,
    this.appPrivilegeProfileKeys,
    this.appPrivilegeDenied = const <String>{},
    this.appPrivilegeOmitted = const <String>{},
    this.appPrivilegeAllowAll = false,
  });

  final DsmCatalog catalog;

  /// ★ r295 修正：**未注册夹具**时，`SYNO.Core.Desktop.Initdata:get` 要不要
  /// 按本 mock 的会话说出身份位（`Session.is_admin`）。
  ///
  /// **默认 `false`（关）**，理由两条：
  /// * 离线用例的契约是"没注册夹具 ⇒ `{'success':true,'data':{}}`"——
  ///   好几句用例正是拿"字段缺失 ⇒ fail-closed / 第一棒没结论 ⇒ 降级问第二棒"
  ///   当判据的（`test/admin_identity_test.dart` AD5/AD6、
  ///   `test/session_entitlement_test.dart` SE4）；
  /// * 只有**真机取证那台 Mock Server**需要"管理员档能在像素上验出来"。
  ///
  /// 顺序很重要：**夹具优先**（注册了就回夹具），本开关只在没有夹具时兜底
  /// —— r295 第一版把这段写在夹具查找**之前**，一次压掉 3 个文件 8 条用例。
  final bool synthesizeSessionIdentity;

  /// ★ r433：**`AppPrivilege` 画像**（模块可见性的实验开关）——
  /// 用来在**真机**上验「某模块的权限键 `false` ⇒ 该模块隐藏」这条
  /// 生产语义（`docs/session-entitlement.md` 铁律②：键不存在**不放行**、
  /// 键存在且 `false` = **明确拒绝**）。
  ///
  /// * `null`（默认）= **旧行为一字不改**：只回通配键
  ///   `SYNO.ALLOW.ALL.APPLICATIONS: true`（r295 起真机取证那台就靠它，
  ///   离线用例的契约也压在这上面）；
  /// * 非 `null` = 按这张**真机形状的键表**回画像：表里的键 = `true`，
  ///   [appPrivilegeDenied] 里的键 = `false`（存在且拒绝），
  ///   [appPrivilegeOmitted] 里的键 = **完全不出现**（"键不存在"这一态）。
  ///
  /// 键名与真机原文见 `docs/capability-fixture-refresh.md` §1 与
  /// `test/support/nas_capability_fixtures.dart` 的 `kLiveNasAppPrivilegeKeys`
  /// （工具层不能 import `test/`，故在 `mock_dsm_server.dart` 里另抄一份）。
  final List<String>? appPrivilegeProfileKeys;
  final Set<String> appPrivilegeDenied;
  final Set<String> appPrivilegeOmitted;
  final bool appPrivilegeAllowAll;

  /// 本 mock 会说的 `AppPrivilege`（测试与真机取证都读它，别在两处各写一遍）。
  Map<String, dynamic> appPrivilegePayload() {
    final keys = appPrivilegeProfileKeys;
    if (keys == null) {
      return <String, dynamic>{'SYNO.ALLOW.ALL.APPLICATIONS': true};
    }
    return <String, dynamic>{
      for (final k in keys)
        if (!appPrivilegeOmitted.contains(k))
          k: !appPrivilegeDenied.contains(k),
      if (appPrivilegeAllowAll) 'SYNO.ALLOW.ALL.APPLICATIONS': true,
    };
  }

  /// 已发出的 sid → 是否管理员。
  final Map<String, bool> _sessions = {};

  /// `method → 夹具`。键用 `api|method`；回 [MockDsmResponse] 或 `Map`。
  final Map<String, MockDsmResponse Function(Map<String, dynamic> params)>
  fixtures = {};

  /// **二进制**夹具：键同样是 `api|method`（`SYNO.SynologyDrive.Files|download` …）。
  final Map<String, MockRawResponse Function(Map<String, dynamic> params)>
  rawFixtures = {};

  /// 处理一次**二进制**接口请求（`download` / `get_thumbnail`）。
  ///
  /// 与 [handle] 共用同一套目录校验（api 存在 / 版本区间 / 方法表 /
  /// authLevel / adminOnly），区别只在"回字节"而不是回 JSON 信封。
  ///
  /// ⚠️ 注意：这个方法**不写 requests 日志吗？写** —— 与 [handle] 一样记录，
  /// 因为"客户端到底调了什么"对二进制接口同样重要。
  MockRawResponse handleRaw(String path, Map<String, dynamic> params) {
    requests.add((path: path, params: Map<String, dynamic>.from(params)));
    final api = '${params['api'] ?? ''}';
    final method = '${params['method'] ?? ''}';
    if (api.isEmpty) return const MockRawResponse.error(114, note: '缺 api');
    if (method.isEmpty) return const MockRawResponse.error(114, note: '缺 method');
    final spec = catalog[api];
    if (spec == null) {
      return const MockRawResponse.error(101, note: 'API 不在权威目录里');
    }
    final version = int.tryParse('${params['version'] ?? ''}');
    if (version == null) {
      return const MockRawResponse.error(114, note: 'version 不是整数');
    }
    if (version < spec.minVersion || version > spec.maxVersion) {
      return MockRawResponse.error(
        103,
        note: '$api 版本区间 ${spec.minVersion}-${spec.maxVersion}，没有 v$version',
      );
    }
    if (spec.methodsVerified && !spec.hasMethod(version, method)) {
      return MockRawResponse.error(
        103,
        note: '$api v$version 没有方法 `$method`',
      );
    }
    final sid = '${params['_sid'] ?? ''}';
    if (spec.authLevel > 0 && !_sessions.containsKey(sid)) {
      return MockRawResponse.error(119, note: '$api 需要登录');
    }
    if (spec.adminOnly && !(_sessions[sid] ?? false)) {
      return MockRawResponse.error(105, note: '$api 仅管理员');
    }
    final fx = rawFixtures['$api|$method'];
    if (fx == null) {
      return MockRawResponse.error(
        103,
        note: '$api.$method 没有注册二进制夹具（rawFixture）',
      );
    }
    return fx(params);
  }

  /// 请求日志（用例断言"客户端到底调了什么"）。
  final List<({String path, Map<String, dynamic> params})> requests = [];

  /// 已登录的 sid 集合（用例可直接看）。
  Iterable<String> get sessions => _sessions.keys;

  String login({required String username, required bool admin}) {
    final sid = 'mock-sid-${_sessions.length + 1}-${admin ? 'admin' : 'user'}';
    _sessions[sid] = admin;
    _adminUser = admin;
    return sid;
  }

  bool _adminUser = false;
  bool get isAdmin => _adminUser;

  /// 主动作废一个会话（`--drive-demo` 重装夹具后清旧 sid 用）。
  void forgetSession(String sid) => _sessions.remove(sid);

  /// 给某个 `api|method` 注册夹具（真实返回数据可来自 APK 解析代码/样例）。
  /// 注册夹具。`build` 返回的是**整个响应信封**（`{"success":...,"data":...}`）。
  ///
  /// 注意区分：`tool/mock_dsm/fixtures/*.json` 里存的是**响应的 `data`**，
  /// 由 `MockDsmFixtureStore.installInto()` 负责包成信封。
  void fixture(
    String api,
    String method,
    Map<String, dynamic> Function(Map<String, dynamic> params) build,
  ) {
    fixtures['$api|$method'] = (p) => MockDsmResponse(build(p));
  }

  /// 处理一次 `webapi/<path>` 请求。
  ///
  /// 返回**永远不是异常** —— 错误走 DSM 的 `{success:false,error:{code}}` 信封。
  MockDsmResponse handle(String path, Map<String, dynamic> params) {
    requests.add((path: path, params: Map<String, dynamic>.from(params)));
    final api = '${params['api'] ?? ''}';
    final method = '${params['method'] ?? ''}';

    // ---- 必填参数（真实 DSM：114 noRequiredParam，带 errors.name）----
    if (api.isEmpty) return _missing('api');
    if (method.isEmpty) return _missing('method');

    // ---- 目录校验（**必须在特例之前**）----
    //
    // ⚠️ 我第一版把 API.Info / Auth 的特例放在最前面，结果
    // `SYNO.API.Auth.Login` 用 v1 调时**先撞上 Auth 特例**（缺 account → 114），
    // 永远回不到"v1 没有 Login"的 103。被自己的自测抓住了。
    // 真实 DSM 也是先判 api/version/method 存不存在，再进业务分支。
    final spec = catalog[api];
    if (spec == null) {
      return MockDsmResponse({
        'success': false,
        'error': {'code': 101},
      }, note: '$api 不在权威目录里（101 invalid API）');
    }

    final versionRaw = params['version'];
    if (versionRaw == null) return _missing('version');
    final version = int.tryParse('$versionRaw');
    if (version == null) {
      return MockDsmResponse({
        'success': false,
        'error': {'code': 101},
      }, note: 'version 不是整数');
    }

    // 版本合法性：以**对外宣称的区间**为准（`maxVersion` 可能大于方法表列过的版本）。
    if (version < spec.minVersion || version > spec.maxVersion) {
      return MockDsmResponse({
        'success': false,
        'error': {'code': 103},
      }, note: '$api 版本区间是 ${spec.minVersion}-${spec.maxVersion}，没有 v$version');
    }
    // ⚠️ 这是本 mock 最有价值的一条：**版本里没有这个方法就是 103**。
    if (spec.methodsVerified && !spec.hasMethod(version, method)) {
      return MockDsmResponse(
        {
          'success': false,
          'error': {'code': 103},
        },
        note:
            '$api v$version 没有方法 `$method`'
            '（v$version 生效清单 ${spec.methodsAt(version)}）',
      );
    }

    // ---- 特例：SYNO.API.Info（把目录本身当"服务器能力表"回出去）----
    // ⚠️ 大小写**两种都要认**（第 279 轮实测）：目录里 `methods` 就写着
    // `["query","Query"]`，而客户端（`DsmDirectTransport.describe`，
    // `lib/src/dsm/webapi.dart:741`）发的是**小写** `query`。
    // 只认大写 ⇒ 回一个"校验通过但 data 为空"的 success ⇒ 客户端能力表
    // 为空 ⇒ 登录报 `API not found`（看着像登录坏了，其实是 mock 少认一个拼写）。
    if (api == 'SYNO.API.Info' && (method == 'Query' || method == 'query')) {
      final all = params['query'] == null || params['query'] == 'all';
      final want = all
          ? catalog.apis.keys.toList()
          : '${params['query']}'.split(',').where((s) => s.isNotEmpty).toList();
      return MockDsmResponse({
        'success': true,
        'data': {
          for (final a in want)
            if (catalog[a] != null) a: catalog[a]!.toInfoEntry(),
        },
      }, note: 'query.cgi: ${want.length} 个 API');
    }

    // ---- 特例：`SYNO.API.Encryption.getinfo` ----
    //
    // ⚠️ 少了这个，**登录直接崩**：客户端拿到 `public_key` 会去
    // `parseX509RsaPublicKey`，空串 ⇒ `Uint8List.[]` 的 RangeError。
    // 这是我自己的 M73 用例踩出来的（第一次登录就炸在 cgi_encryption.dart:107）。
    //
    // 公钥是**测试专用**的、随本文件公开，不涉密；后端反正不校验密码。
    if (api == 'SYNO.API.Encryption' && method == 'getinfo') {
      return MockDsmResponse({
        'success': true,
        'data': {
          'cipherkey': '__cIpHeRtExT',
          'ciphertoken': '__cIpHeRtOkEn',
          'public_key': _mockPublicKeyB64,
          'server_time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
      }, note: 'encryption.cgi: getinfo');
    }

    // ---- 特例：登录/登出（**登录本身当然不能要求已登录**）----
    //
    // ⚠️ 大小写**两种都要认**：真实 `.lib` 里 v6 是大写 `Login`、
    // v3-v7 是小写 `login`（同一族两种拼写并存，见 SYNO.API.Auth.lib）。
    // 只认大写的话，客户端用 v7（默认）登录时 mock 会走到夹具分支、
    // 回一个**没有 sid 的 success** —— 后续每个请求都变成 119。
    // 这个坑是我自己的 M73 用例踩出来的。
    if (api == 'SYNO.API.Auth') {
      if (method == 'Login' || method == 'login') {
        // ⚠️ 客户端会**加密** `account`/`passwd`：真实请求里根本没有 `account`，
        // 只有 `__cIpHeRtExT=<密文>`（见 cgi_encryption.dart）。mock 没有私钥、
        // **也不需要**解密 —— 它只按配置发会话，所以认这个形态为"合法登录"。
        // （不认就会拿 114「缺少必需参数」，这是 M73 用例踩出的第二个坑。）
        final cipherField = '${params['__cIpHeRtExT'] ?? ''}';
        final account = '${params['account'] ?? ''}';
        if (account.isEmpty && cipherField.isEmpty) return _missing('account');
        // ⚠️ 加密登录时 `account` 是**空的**（只有 `__cIpHeRtExT` 密文），
        // 而 mock **没有私钥** ⇒ 它根本无从知道是谁登录的。
        // ⇒ 兜底用**用例声明的意图**：`backend.login(..., admin: true/false)`
        // 会把 `_adminUser` 记下来，加密登录就按它发会话。
        //
        // 这是 mock 的**已知局限**（真机当然能解密、能按账号判权限），
        // 但它是**用例可控**的：想测管理员档就 `login(admin: true)`。
        // 第 30 轮的 COV-4 就是踩到"管理员登录后仍是 105"才补的这条。
        final admin =
            params['_mockAdmin'] == true || account == 'admin' || _adminUser;
        final sid = login(username: account, admin: admin);
        return MockDsmResponse({
          'success': true,
          'data': {
            'sid': sid,
            'synotoken': 'mock-token',
            'device_id': 'mock-device',
            'is_portal_port': false,
          },
        }, note: 'auth.cgi: ${admin ? '管理员' : '普通用户'}会话');
      }
      if (method == 'Logout' || method == 'logout') {
        _sessions.remove('${params['_sid'] ?? ''}');
        return const MockDsmResponse({'success': true, 'data': {}});
      }
    }

    // ---- 鉴权 ----
    final sid = '${params['_sid'] ?? ''}';
    final loggedIn = _sessions.containsKey(sid);
    if (spec.authLevel > 0 && !loggedIn) {
      return MockDsmResponse({
        'success': false,
        'error': {'code': 119},
      }, note: '$api 需要登录（authLevel=${spec.authLevel}）');
    }

    // ---- **仅管理员**的 API：非管理员会话一律 105 ----
    if (spec.adminOnly && !(_sessions[sid] ?? false)) {
      return MockDsmResponse({
        'success': false,
        'error': {'code': 105},
      }, note: '$api 仅管理员；当前会话不是管理员');
    }

    // ---- 特例：`SYNO.Entry.Request / request` —— DSM 的**批量（compound）**调用 ----
    //
    // ★ r326 补：Mock 原先**根本不解析 `compound`** ⇒ 任何走 `api.compound([...])`
    //   的代码路径都拿到"没有 `result` 数组"的响应，客户端直接抛
    //   `DsmTransportException`。真机第一次踩是**聊天同步**：
    //   `ChatSessionController._sync` 的第 2 步 `listUsers()` 就是 compound
    //   （`Chat.User/list` human + bot 两段并发）⇒ 抛异常 ⇒ 后面
    //   `listChannels()` **根本没执行** ⇒ 频道列表永远只有本地旧数据、
    //   且 `removeMissing` 剪枝也跑不到（屏上于是显示**别的会话遗留的旧频道**）。
    //   ★ 这是**协议层**能力，所以放核心而不是聊天 demo；每一段子请求都
    //   **重走同一条 `handle()`**（同一 sid、同一目录/版本/方法/authLevel 校验）。
    if (api == 'SYNO.Entry.Request' && method == 'request') {
      return _compound(params, sid);
    }

    // ---- 夹具（**先看夹具**）----
    final fx = fixtures['$api|$method'];
    if (fx != null) return fx(params);

    // ---- 特例：会话权限画像（`Session.is_admin`）----
    //
    // ★ r295：Mock 原先**根本不回** Initdata ⇒ 客户端 `adminIdentityProvider`
    //   的第①棒（`SYNO.Core.Desktop.Initdata:get`）与第②棒
    //   （`SYNO.Core.NormalUser:get`）都拿不到结论 ⇒ 按 fail-closed 判**普通用户**，
    //   于是"管理员档"在 Mock 上**永远推不出来**（iOS 真机实测：`--admin` 起的
    //   mock、会话确实是管理员，`Settings` 里 `set-admin-tools` 仍**不在场**）。
    //
    // 字段形状照客户端真实读取的 `session.is_admin`
    // （`lib/src/core/entitlement/session_entitlement.dart:153`）：
    // ⚠️ **大写 `Session`**（`data['Session']`），小写会被解析成 `isAdmin=null`。
    //
    // ⚠️ 位置：必须在**夹具查找之后**。放在前面会压掉"未注册夹具 ⇒ 空 data"
    //    这份契约（r295 实测一次红 3 文件 8 用例）。
    // ⚠️ 开关：默认关；只有 `mock_dsm_server.dart`（真机取证那台）打开。
    if (synthesizeSessionIdentity &&
        api == 'SYNO.Core.Desktop.Initdata' &&
        method == 'get') {
      final sidNow = '${params['_sid'] ?? ''}';
      final adminNow = _sessions[sidNow] ?? _adminUser;
      return MockDsmResponse({
        'success': true,
        'data': {
          'Session': <String, dynamic>{'is_admin': adminNow, 'user': 'admin'},
          // 真机 Initdata 的其余可用字段：解析器是"任一可用即可"，
          // 这里一并给全，排除"因为缺字段导致整条解析失败"的可能。
          'AppPrivilege': appPrivilegePayload(),
          'ActionPrivilege': <String>[],
          'ServiceStatus': <String, dynamic>{},
          'hostname': 'mock-nas',
          'support_wol': false,
          'support_findme': false,
        },
      }, note: 'initdata（合成）: is_admin=$adminNow');
    }

    return MockDsmResponse({
      'success': true,
      'data': <String, dynamic>{},
    }, note: '$api.$method v$version 通过校验（无夹具）');
  }

  /// 批量调用的**服务端**实现（`SYNO.Entry.Request / request`）。
  ///
  /// 官方信封（`lib/src/data/remote/compound.dart` 的注释里记着实测）：
  /// 请求 `compound` = JSON 数组串，每项 `{api, method, version, ...params}`，
  /// `mode=parallel`；响应 `data = {has_fail, result:[{api,method,version,
  /// success, data|error}]}` —— **每段自带 `success`**，整体成功不代表每段成功。
  MockDsmResponse _compound(Map<String, dynamic> params, String sid) {
    final raw = '${params['compound'] ?? ''}';
    Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      parsed = null;
    }
    if (parsed is! List) return _missing('compound');
    final out = <Map<String, dynamic>>[];
    var fails = 0;
    for (final e in parsed) {
      if (e is! Map) {
        fails++;
        out.add({
          'success': false,
          'error': {'code': 101},
        });
        continue;
      }
      final inner = Map<String, dynamic>.from(e);
      // ★ 子请求把 `api`/`method`/`version` 与参数**平铺在同一层**，
      //   顺序里后出现的同名键会覆盖前面的 —— 与官方 `CompoundJsonable` 一致。
      final r = handle('/entry.cgi', {...inner, '_sid': sid});
      final seg = <String, dynamic>{
        'api': '${inner['api'] ?? ''}',
        'method': '${inner['method'] ?? ''}',
        'version': inner['version'] ?? 1,
        ...r.json,
      };
      if (r.json['success'] != true) fails++;
      out.add(seg);
    }
    return MockDsmResponse({
      'success': true,
      'data': {'has_fail': fails > 0, 'result': out},
    }, note: 'compound: ${out.length} 段（失败 $fails）');
  }

  MockDsmResponse _missing(String name) => MockDsmResponse({
    'success': false,
    'error': {
      'code': 114,
      'errors': {'name': name, 'reason': 'required'},
    },
  }, note: '缺必填参数 `$name`（114）');
}

/// **二进制**接口的响应（`download` / `get_thumbnail` / `GetBaseURL` 拼出来的直链）。
///
/// 为什么需要它：这些接口**不是 JSON 信封** —— 服务端直接回字节（见
/// `lib/src/data/drive_api.dart` 顶部注释）。只做 JSON 的 mock 覆盖不到它们，
/// 于是 D66「打开那一刻真去下载」就没法用 Mock 验证（246 轮补上）。
class MockRawResponse {
  const MockRawResponse(
    this.bytes, {
    this.contentType = 'application/octet-stream',
    this.note,
    this.errorCode,
  });

  /// 出错时用（不装成"有内容"）
  const MockRawResponse.error(int code, {this.note})
    : bytes = const [],
      contentType = 'application/json',
      errorCode = code;

  final List<int> bytes;
  final String contentType;
  final String? note;

  /// 非空表示这次请求失败（对应 DSM 的 `{success:false,error:{code}}`）
  final int? errorCode;

  bool get ok => errorCode == null;
}

extension MockDsmRaw on MockDsmBackend {
  /// 注册一个**二进制**夹具（`api|method` → 字节 + 类型）。
  void rawFixture(
    String api,
    String method,
    MockRawResponse Function(Map<String, dynamic> params) build,
  ) {
    rawFixtures['$api|$method'] = build;
  }
}

/// **测试专用**的 2048-bit RSA 公钥（X.509 SubjectPublicKeyInfo 的 DER，base64）。
///
/// 配对私钥已丢弃 —— mock 从不解密，它只看 `api`/`method`/`version`。
/// 换公钥不影响任何用例；它存在的唯一理由是"让客户端的
/// `parseX509RsaPublicKey` 有合法输入可解"。
const String _mockPublicKeyB64 =
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAupcFJFp4pyqKrdJOaBqk216W+QkdaMz4INBsCgIiVN520zku7spLfZJbxcsGtIiSlalhlKKgCapyLUmCMeyW9saLhxpHGL4OOGbRUYQXdmaGJlrT3wtnPZuQCM4nYmC/ByDPfdTEYAIBYTBr9Gm3Qa+qFBKV+SqoXa173lxrCxE2yCNhAsXjfAN9rCAeYR1YpzYPcGMyCCFLSY+ZHahnbORpdnfKkNRpNWaU6VzmRcHHALC4L5Putm8Zoaau+wD4xoYI/Dp2jw2U6g8VLyxgDTx0ZE7dk6LLyzr2PDUZ79UlQfm4fn55ZUDCRjWH+u1Ol9g7x0paAyi/lD4Odd+8OQIDAQAB';
