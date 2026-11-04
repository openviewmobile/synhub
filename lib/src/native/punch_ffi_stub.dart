// libsynochatpunch 的 **web 桩**（第 334 轮）。
//
// 事实：web 上没有 `dart:ffi`、没有动态库、也没有 QuickConnect 打洞的实现
// （官方 Web 客户端走的是服务端中继，不走本地 UDT 隧道）。
// ⇒ 这里的每个入口都**如实抛** `UnsupportedError`，绝不返回"看起来成功"的值：
//   静默假成功会让诊断页/隧道路径显示"已连通"，那是比编译不过更坏的结果
//   （§2.0.42「登记了却不产生机制量 = 死功能」/ §2.0.45 同族）。
//
// 与 `punch_ffi_io.dart` 的**表面一致性**由门面保证：两个文件导出同名符号。
// 常量类（[SynoServiceType]/[SynoPunchError]）是纯 Dart，两边**逐字相同**
// （否则调用方按常量做的判断会在 web 上得出不同结论）。

/// 各平台的默认库名 —— web 上没有。
///
/// ★ 第 338 轮：诊断串**内联在 `UnsupportedError(...)` 里**，不再单独抽常量 ——
/// `i18n_hardcoded_cjk_test` 只对"异常实参"里的中文做结构豁免（文件头第 4 条），
/// 抽成顶层常量会被判成"硬编码中文界面文案"（r334 起那条守卫一直是红的）。
Never _noWeb() => throw UnsupportedError(
    'QuickConnect 打洞（libsynochatpunch）在 web 上不可用：'
    '没有 dart:ffi / 动态库；官方 Web 客户端走服务端中继');

/// SERVICE_ID，见官方 `SERVICE_TYPE`
class SynoServiceType {
  static const int noOp = 0;
  static const int dsm = 1;
  static const int dsmHttps = 2; // Synology Chat 用这个
  static const int http = 3;
  static const int https = 4;
  static const int webdav = 5;
  static const int webdavHttps = 6;
  static const int cloudStation = 7;
  static const int vpnPlus = 8;
  static const int beeDriveHttps = 9;
  static const int bsmHttp = 10;
  static const int bsmHttps = 11;
}

/// 错误码 —— 与 io 实现逐字一致（web 上只会由调用方"读常量"，不会真产生这些码）
class SynoPunchError {
  static const int ok = 0;
  static const int earlyExit = 1;
  static const int listenSocket = 3;
  static const int udpPort = 5;
  static const int punchFailed = 6;
  static const int udtChannel = 7;
  static const int udtConnect = 8;
  static const int udtListen = 9;
  static const int acceptFailed = 10;
  static const int engineStart = 12;

  static String name(int code) => switch (code) {
    ok => 'ok',
    earlyExit => 'early-exit',
    listenSocket => 'listen-socket',
    udpPort => 'udp-port',
    punchFailed => 'punch-failed',
    udtChannel => 'udt-channel',
    udtConnect => 'udt-connect',
    udtListen => 'udt-listen',
    acceptFailed => 'accept-failed',
    engineStart => 'engine-start',
    _ => 'unknown($code)',
  };
}

/// echo / relay 服务器地址（纯数据结构，web 上可安全构造）
class SynoEchoServer {
  const SynoEchoServer(this.host, this.port);
  final String host;
  final int port;

  @override
  String toString() => '$host:$port';
}

/// web 桩：**API 表面**与 io 实现一致，任何真正用到它的动作都抛。
class SynoPunch {
  /// web 上无法加载 ⇒ 一律抛（调用方本就用 `try/catch` 包着诊断步骤）。
  factory SynoPunch.load({String? libraryPath}) => _noWeb();

  /// web 上**没有**默认库名；抛而不是返回一个"看起来能用"的名字。
  static String defaultLibraryName() => _noWeb();

  set serverId(String v) => _noWeb();
  set serviceType(int v) => _noWeb();
  void addEchoServer(String host, int port) => _noWeb();
  void addEchoServers(Iterable<SynoEchoServer> servers) => _noWeb();
  void clearEchoServers() => _noWeb();
  set udtTxMss(int v) => _noWeb();
  void setCandidate(String host, int port) => _noWeb();
  void clearCandidate() => _noWeb();
  set rendezvous(bool v) => _noWeb();
  set localServicePort(int v) => _noWeb();
  set punchTimeoutMs(int v) => _noWeb();
  set connectTimeoutMs(int v) => _noWeb();
  int start() => _noWeb();
  // r684 的分段接口（io 实现真做，web 上同样是不支持）
  int prepare() => _noWeb();
  int get udtPort => _noWeb();
  int awaitPeer() => _noWeb();
  int startEngine() => _noWeb();
  int get tcpPort => _noWeb();
  bool get isRunning => _noWeb();
  int pump({int timeoutMs = 10}) => _noWeb();
  String get lastError => _noWeb();
  int get rxBytes => _noWeb();
  int get txBytes => _noWeb();
  void stop() => _noWeb();
  void dispose() => _noWeb();
}
